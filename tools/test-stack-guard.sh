#!/usr/bin/env bash
# Drives stack-guard.mjs over a hand-built module shaped like wasm-ld's output.
#
# The fixture has a mutable i32 stack pointer as its first global, an emscripten_stack_init that
# stores the stack end as a constant, and a recursive function whose prologue lowers the pointer
# and writes into its frame. Below the stack end sits "static data". Unguarded, a deep recursion
# writes into it silently; guarded, the same call traps and the static data is unchanged. A stack
# pointer set to a constant must refuse the module.
#
# What it does not prove: that PHP runs on a guarded binary. The worker's specs boot the shipping
# interpreter, so they do once the guarded build is pinned.
#
# Usage:
#   bash tools/test-stack-guard.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

node --input-type=module - "$HERE/src/stack-guard.mjs" << 'JS'
import binaryen from 'binaryen';
const { stackGuard, guardOf, StackGuardRefusal } = await import(process.argv[2]);

const LIMIT = 4096;
const TOP = 12288;
const FRAME = 64;
const PROBE = 4032;

function fixture(constantWrite = false) {
	const mod = new binaryen.Module();
	const i32 = binaryen.i32;
	mod.setMemory(1, 1, 'memory');
	mod.addGlobal('__stack_pointer', i32, true, mod.i32.const(TOP));
	mod.addGlobal('__stack_end', i32, true, mod.i32.const(0));
	mod.addFunction('emscripten_stack_init', binaryen.none, binaryen.none, [],
		mod.global.set('__stack_end', mod.i32.const(LIMIT)));
	mod.addFunction('emscripten_stack_get_end', binaryen.none, i32, [],
		mod.global.get('__stack_end', i32));
	const lowered = constantWrite
		? mod.i32.const(100)
		: mod.local.tee(1, mod.i32.sub(mod.global.get('__stack_pointer', i32), mod.i32.const(FRAME)), i32);
	mod.addFunction('rec', binaryen.createType([i32]), binaryen.none, [i32], mod.block(null, [
		mod.global.set('__stack_pointer', lowered),
		mod.i32.store(0, 4, mod.local.get(1, i32), mod.i32.add(mod.local.get(0, i32), mod.i32.const(1))),
		mod.if(mod.i32.gt_s(mod.local.get(0, i32), mod.i32.const(0)),
			mod.call('rec', [mod.i32.sub(mod.local.get(0, i32), mod.i32.const(1))], binaryen.none)),
		mod.global.set('__stack_pointer', mod.i32.add(mod.local.get(1, i32), mod.i32.const(FRAME)))
	]));
	mod.addFunctionExport('emscripten_stack_init', 'emscripten_stack_init');
	mod.addFunctionExport('emscripten_stack_get_end', 'emscripten_stack_get_end');
	mod.addFunctionExport('rec', 'rec');
	if (!mod.validate()) throw new Error('fixture does not validate');
	const bytes = mod.emitBinary();
	mod.dispose();
	return bytes;
}

async function run(bytes, depth) {
	const { instance } = await WebAssembly.instantiate(bytes);
	const view = new Int32Array(instance.exports.memory.buffer);
	instance.exports.emscripten_stack_init();
	let trapped = false;
	try {
		instance.exports.rec(depth);
	} catch (e) {
		if (!(e instanceof WebAssembly.RuntimeError)) throw e;
		trapped = true;
	}
	return { trapped, probe: view[PROBE / 4] };
}

const check = (ok, what) => {
	if (!ok) {
		console.error(`FAIL ${what}`);
		process.exit(1);
	}
	console.log(`ok   ${what}`);
};

const plain = fixture();
const { bytes: guarded, stats } = stackGuard(plain);
check(stats.limit === LIMIT, `the limit is the module's own stack end (${stats.limit})`);
check(stats.checks === 1 && stats.sites.raise === 1, 'one lowering checked, one raise left alone');
check(guardOf(guarded)?.checks === 1, 'the guarded binary carries its stats section');
check(guardOf(plain) === undefined, 'an unguarded binary carries none');

const shallow = await run(guarded, 10);
check(!shallow.trapped && shallow.probe === 0, 'a shallow call runs and leaves static data alone');

// 130 frames of 64 bytes from 12288 reach 3968, under the stack end at 4096
const deepPlain = await run(plain, 130);
check(!deepPlain.trapped && deepPlain.probe !== 0, 'unguarded, a deep call overwrites static data silently');
const deepGuarded = await run(guarded, 130);
check(deepGuarded.trapped && deepGuarded.probe === 0, 'guarded, the same call traps and static data is unchanged');

let refused = false;
try {
	stackGuard(fixture(true));
} catch (e) {
	refused = e instanceof StackGuardRefusal;
}
check(refused, 'a constant stack pointer write refuses the module');
JS

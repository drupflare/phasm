#!/usr/bin/env bash
# Drives import-stack-pointer.mjs over a hand-built module shaped like wasm-ld's output.
#
# The fixture defines a mutable i32 stack pointer as its first global, a second global after it,
# exports the pointer (the TABLE_GROWTH arm's shape), and carries a bounded table. After the edit,
# a function that sets the pointer must move the Global the host passed in, the second global must
# still answer at its old index, and the table must be growable.
#
# What it does not prove: that PHP runs on the edited binary. `measure:abi-speed` in the worker
# does, because it verifies every case's answer before timing it.
#
# Usage:
#   bash tools/test-import-stack-pointer.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$HERE/src/import-stack-pointer.mjs"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

node --input-type=module - "$SCRIPT" "$WORK" << 'JS'
import { writeFileSync } from 'node:fs';
const [script, work] = process.argv.slice(2);
const { importStackPointer, patchGlue } = await import(script);

const u32 = (v) => { const o = []; do { let b = v & 0x7f; v >>>= 7; if (v) b |= 0x80; o.push(b); } while (v); return o; };
const sec = (id, body) => [id, ...u32(body.length), ...body];
const str = (s) => [...u32(s.length), ...Buffer.from(s)];
const mod = Buffer.from([
	0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
	// types: () -> i32, (i32) -> ()
	...sec(1, [2, 0x60, 0, 1, 0x7f, 0x60, 1, 0x7f, 0]),
	// one imported function, so the import section already exists
	...sec(2, [1, ...str('env'), ...str('f'), 0, 0]),
	// get, set, other
	...sec(3, [3, 0, 1, 0]),
	// a table bounded at min 1 max 1, as a link without ALLOW_TABLE_GROWTH emits it
	...sec(4, [1, 0x70, 1, 1, 1]),
	// global 0: the stack pointer at 65536; global 1: an immutable 7
	...sec(6, [2, 0x7f, 1, 0x41, ...[0x80, 0x80, 0x04], 0x0b, 0x7f, 0, 0x41, 7, 0x0b]),
	...sec(7, [5, ...str('get'), 0, 1, ...str('set'), 0, 2, ...str('other'), 0, 3, ...str('__stack_pointer'), 3, 0, ...str('tab'), 1, 0]),
	...sec(10, [3,
		4, 0, 0x23, 0, 0x0b,
		6, 0, 0x20, 0, 0x24, 0, 0x0b,
		4, 0, 0x23, 1, 0x0b])
]);

const results = [];
const ok = (label, pass) => results.push([label, pass]);
const f = () => 0;

const plain = new WebAssembly.Instance(new WebAssembly.Module(mod), { env: { f } });
ok('the fixture is a valid module that exports its pointer', plain.exports.__stack_pointer instanceof WebAssembly.Global);

const { wasm, initial } = importStackPointer(mod, { growTable: true });
ok('reads the linker\'s initial value', initial === 65536);
const m = new WebAssembly.Module(wasm);
const imports = WebAssembly.Module.imports(m).map((i) => `${i.module}.${i.name}:${i.kind}`);
ok('imports env.__stack_pointer as a global', imports.includes('env.__stack_pointer:global'));
ok('no longer exports it', !WebAssembly.Module.exports(m).some((e) => e.name === '__stack_pointer'));
const sp = new WebAssembly.Global({ value: 'i32', mutable: true }, initial);
const inst = new WebAssembly.Instance(m, { env: { f, __stack_pointer: sp } });
ok('reads the host global', inst.exports.get() === 65536);
inst.exports.set(1024);
ok('writes move the host global', sp.value === 1024 && inst.exports.get() === 1024);
ok('the next global keeps its index', inst.exports.other() === 7);
let grew = true;
try { inst.exports.tab.grow(1); } catch { grew = false; }
ok('--grow-table makes the table growable', grew);

let refused = false;
try { importStackPointer(wasm); } catch { refused = true; }
ok('refuses a binary that already imports it', refused);

const bounded = importStackPointer(mod);
const t = new WebAssembly.Instance(new WebAssembly.Module(bounded.wasm), {
	env: { f, __stack_pointer: new WebAssembly.Global({ value: 'i32', mutable: true }, 0) }
});
let bound = false;
try { t.exports.tab.grow(1); } catch { bound = true; }
ok('leaves the table bounded without --grow-table', bound && t.exports.get() === 0);

const glue = patchGlue('var x=1;var wasmImports={a:b};', initial);
ok('supplies the global in the glue', glue.includes('var wasmImports={__stack_pointer:new WebAssembly.Global({value:"i32",mutable:true},65536),a:b}'));
let twice = false;
try { patchGlue(glue, initial); } catch { twice = true; }
ok('refuses to patch a glue twice', twice);

writeFileSync(`${work}/results.json`, JSON.stringify(results));
JS

node --input-type=module - "$WORK/results.json" << 'JS'
import { readFileSync } from 'node:fs';
const results = JSON.parse(readFileSync(process.argv[2], 'utf8'));
let failed = 0;
for (const [label, pass] of results) {
	console.log(`  ${pass ? 'ok  ' : 'FAIL'} ${label}`);
	if (!pass) failed++;
}
console.log(`${results.length - failed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
JS

/**
 * Fixes emscripten 3.1.68's own MEMORY64 defects in a built glue.
 *
 * SEPARATE FROM `patch-vrzno-lp64.mjs` because these are not vrzno's and they cannot be fixed in
 * source: the glue is EMITTED by emscripten at link time, so this runs after the build rather than
 * before it. Both are the same shape of bug -- a JS Number where the wasm64 API demands a BigInt --
 * and both are silent.
 *
 * 1. `toIndexType` FEATURE-PROBES and workerd fails the probe.
 *    `try { new WebAssembly.Memory({initial:1n, index:"i64"}) } catch { bigintMemoryBounds = 0 }`
 *    workerd refuses that constructor, so the probe concludes the runtime has no 64-bit memory
 *    bounds and `toIndexType` degrades to the identity. Every `wasmTable.get(toIndexType(ptr))`
 *    then passes a Number to an i64-indexed table and throws. The module itself instantiates and
 *    runs fine -- it is the PROBE that is wrong, not the capability.
 *
 * 2. `growMemory` PASSES A NUMBER TO `wasmMemory.grow`, AND SWALLOWS THE ERROR.
 *    `var pages = (size - b.byteLength + 65535) / 65536; try { wasmMemory.grow(pages); ... } catch(e){}`
 *    Under MEMORY64 `grow` takes a BigInt, so this throws on every call and the bare `catch` eats
 *    it. `growMemory` returns undefined, `_emscripten_resize_heap` retries four times and gives up,
 *    PHP's allocator gets NULL, and the process exits(1) with NOTHING on stderr and no `onAbort`.
 *
 * **Defect 2 is why a wasm64 heap looked like it "never grew".** It could not grow at all, so a
 * reading of a flat heap right up to the failure was true and meant the opposite of what it looked
 * like. With it fixed the same workload grows normally and the real peaks are measurable.
 *
 * Idempotent, and keyed on the patched shape rather than on a marker comment. Applying it to a
 * wasm32 glue is a no-op: neither anchor exists there.
 *
 * Usage:
 *   node patch-lp64-glue.mjs <glue.mjs> [--verify]
 */

import { readFileSync, writeFileSync } from 'node:fs';

/** the feature probe, and the unconditional form that replaces it */
const PROBE =
	'var toIndexType=function(){var bigintMemoryBounds=1;try{new WebAssembly.Memory({initial:1n,index:"i64"})}catch(e){bigintMemoryBounds=0}return i=>bigintMemoryBounds?BigInt(i):i}();';
const PROBE_FIXED = 'var toIndexType=i=>BigInt(i);';

/** the grow call, and the widened form; `Math.ceil` because `BigInt` of a fraction throws */
const GROW = 'var pages=(size-b.byteLength+65535)/65536;try{wasmMemory.grow(pages);';
const GROW_FIXED =
	'var pages=Math.ceil((size-b.byteLength+65535)/65536);try{wasmMemory.grow(BigInt(pages));';

export function fixGlue(source) {
	let applied = 0;
	let out = source;
	if (out.includes(PROBE)) {
		out = out.replace(PROBE, PROBE_FIXED);
		applied++;
	}
	if (out.includes(GROW)) {
		out = out.replace(GROW, GROW_FIXED);
		applied++;
	}
	const already = out.includes(PROBE_FIXED) && out.includes(GROW_FIXED);
	return { out, applied, already };
}

function main() {
	const args = process.argv.slice(2);
	const file = args.find((a) => !a.startsWith('--'));
	const verify = args.includes('--verify');
	if (!file) {
		console.error('usage: node patch-lp64-glue.mjs <glue.mjs> [--verify]');
		process.exit(2);
	}

	const source = readFileSync(file, 'utf8');
	const { out, applied, already } = fixGlue(source);

	if (verify) {
		if (!already) {
			console.error(`lp64-glue: ${file} is NOT patched; both fixes must be present`);
			process.exit(1);
		}
		console.log(`lp64-glue: verified, ${file} carries both fixes`);
		return;
	}

	if (applied === 0 && !already) {
		// a wasm32 glue has neither anchor, which is not a failure; a wasm64 glue that has neither
		// means emscripten changed and this script is now describing a build that does not exist
		console.log(
			`lp64-glue: no anchors in ${file}; nothing to do (wasm32 glue, or emscripten moved)`
		);
		return;
	}
	if (out !== source) writeFileSync(file, out);
	console.log(`lp64-glue: ${applied} fix(es) applied to ${file}`);
}

if (import.meta.url === `file://${process.argv[1]}`) main();

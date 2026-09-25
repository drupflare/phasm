/**
 * Turns a linked binary's `__stack_pointer` from a defined global into an `env` import.
 *
 * A side module imports `env.__stack_pointer`, so a host that wants to place one has to be able to
 * hand it the SAME global. `-Wl,--export=__stack_pointer` does that and costs ~8% across the ABI
 * cases: exporting a mutable global stops the linker proving it module-private. An import is the
 * other way to share it, and this produces that arm without relinking: the global is moved, not
 * rewritten, and the glue supplies it.
 *
 * wasm-ld emits `__stack_pointer` as the FIRST defined global. Appended as the LAST global import it
 * keeps its index, and so does every other global, so no instruction in the module changes. The
 * edit is refused unless that first global is a mutable i32 initialised by `i32.const`, and a binary
 * that already imports it is refused rather than edited twice.
 *
 * `--grow-table` also drops the table maximum, which is what `-sALLOW_TABLE_GROWTH=1` emits and what
 * a loader needs to place a library's element segment. It is free: measured separately.
 *
 * Usage:
 *   node import-stack-pointer.mjs <in.wasm> <in-glue.mjs> <out.wasm> <out-glue.mjs> [--grow-table]
 */
import { readFileSync, writeFileSync } from 'node:fs';

const SECTION = { type: 1, import: 2, table: 4, global: 6, export: 7 };
const KIND_GLOBAL = 3;
const I32 = 0x7f;
const I32_CONST = 0x41;
const END = 0x0b;

function readU32(bytes, at) {
	let value = 0;
	let shift = 0;
	let pos = at;
	for (;;) {
		const b = bytes[pos++];
		value |= (b & 0x7f) << shift;
		if ((b & 0x80) === 0) break;
		shift += 7;
	}
	return { value: value >>> 0, next: pos };
}

function readS32(bytes, at) {
	let value = 0;
	let shift = 0;
	let pos = at;
	let b;
	do {
		b = bytes[pos++];
		value |= (b & 0x7f) << shift;
		shift += 7;
	} while (b & 0x80);
	if (shift < 32 && b & 0x40) value |= -1 << shift;
	return { value, next: pos };
}

function u32(value) {
	const out = [];
	let v = value >>> 0;
	do {
		let b = v & 0x7f;
		v >>>= 7;
		if (v !== 0) b |= 0x80;
		out.push(b);
	} while (v !== 0);
	return out;
}

function name(text) {
	const b = Buffer.from(text, 'utf8');
	return [...u32(b.length), ...b];
}

/** the module's sections as byte ranges, in order */
export function sections(bytes) {
	if (bytes.readUInt32LE(0) !== 0x6d736100 || bytes.readUInt32LE(4) !== 1) {
		throw new Error('not a version-1 wasm module');
	}
	const out = [];
	let pos = 8;
	while (pos < bytes.length) {
		const id = bytes[pos];
		const size = readU32(bytes, pos + 1);
		// `head` keeps the original size bytes, which wasm-ld may pad
		out.push({ id, head: pos, start: size.next, end: size.next + size.value });
		pos = size.next + size.value;
	}
	return out;
}

function section(id, content) {
	return Buffer.from([id, ...u32(content.length), ...content]);
}

/** skips one import entry's descriptor and says whether it was a global */
function skipImport(bytes, at) {
	let pos = at;
	for (let i = 0; i < 2; i++) {
		const len = readU32(bytes, pos);
		pos = len.next + len.value;
	}
	const kind = bytes[pos++];
	if (kind === 0) return { next: readU32(bytes, pos).next, global: false, kind };
	if (kind === 1) {
		pos++;
		const flags = readU32(bytes, pos);
		pos = readU32(bytes, flags.next).next;
		if (flags.value & 1) pos = readU32(bytes, pos).next;
		return { next: pos, global: false, kind };
	}
	if (kind === 2) {
		const flags = readU32(bytes, pos);
		pos = readU32(bytes, flags.next).next;
		if (flags.value & 1) pos = readU32(bytes, pos).next;
		return { next: pos, global: false, kind };
	}
	if (kind === KIND_GLOBAL) return { next: pos + 2, global: true, kind };
	if (kind === 4) return { next: readU32(bytes, pos + 1).next, global: false, kind };
	throw new Error(`unknown import kind ${kind}`);
}

function importNames(bytes, sec) {
	const names = [];
	const count = readU32(bytes, sec.start);
	let pos = count.next;
	for (let i = 0; i < count.value; i++) {
		const mod = readU32(bytes, pos);
		const field = readU32(bytes, mod.next + mod.value);
		names.push(
			bytes.toString('utf8', mod.next, mod.next + mod.value) +
				'.' +
				bytes.toString('utf8', field.next, field.next + field.value)
		);
		pos = skipImport(bytes, pos).next;
	}
	return names;
}

/**
 * The binary with `__stack_pointer` imported, and the value the glue must initialise it to.
 *
 * @returns {{ wasm: Buffer, initial: number }}
 */
export function importStackPointer(input, { growTable = false } = {}) {
	const bytes = Buffer.from(input);
	const secs = sections(bytes);
	const imp = secs.find((s) => s.id === SECTION.import);
	const glob = secs.find((s) => s.id === SECTION.global);
	if (!glob) throw new Error('no global section, so no defined __stack_pointer');
	if (imp && importNames(bytes, imp).includes('env.__stack_pointer')) {
		throw new Error('env.__stack_pointer is already imported');
	}

	const globals = readU32(bytes, glob.start);
	let pos = globals.next;
	if (bytes[pos] !== I32 || bytes[pos + 1] !== 1 || bytes[pos + 2] !== I32_CONST) {
		throw new Error('the first defined global is not a mutable i32 set by i32.const');
	}
	const init = readS32(bytes, pos + 3);
	if (bytes[init.next] !== END) throw new Error('the first global has a compound initialiser');
	const firstEnd = init.next + 1;

	const entry = [...name('env'), ...name('__stack_pointer'), KIND_GLOBAL, I32, 1];
	const importContent = imp
		? (() => {
				const count = readU32(bytes, imp.start);
				return Buffer.from([
					...u32(count.value + 1),
					...bytes.subarray(count.next, imp.end),
					...entry
				]);
			})()
		: Buffer.from([...u32(1), ...entry]);
	const globalContent = Buffer.from([
		...u32(globals.value - 1),
		...bytes.subarray(firstEnd, glob.end)
	]);

	const parts = [bytes.subarray(0, 8)];
	let placedImport = Boolean(imp);
	for (const s of secs) {
		const raw = bytes.subarray(s.start, s.end);
		if (!placedImport && s.id > SECTION.import && s.id !== 0) {
			parts.push(section(SECTION.import, importContent));
			placedImport = true;
		}
		if (s.id === SECTION.import) parts.push(section(s.id, importContent));
		else if (s.id === SECTION.global) {
			parts.push(section(s.id, globals.value === 1 ? Buffer.from([0]) : globalContent));
		} else if (s.id === SECTION.export) parts.push(section(s.id, dropGlobalExport(raw)));
		else if (s.id === SECTION.table && growTable) parts.push(section(s.id, unboundTables(raw)));
		else parts.push(bytes.subarray(s.head, s.end));
	}
	return { wasm: Buffer.concat(parts), initial: init.value };
}

/** the export section without an export of `__stack_pointer`, which the import replaces */
function dropGlobalExport(raw) {
	const count = readU32(raw, 0);
	const kept = [];
	let pos = count.next;
	for (let i = 0; i < count.value; i++) {
		const len = readU32(raw, pos);
		const field = raw.toString('utf8', len.next, len.next + len.value);
		const kind = raw[len.next + len.value];
		const idx = readU32(raw, len.next + len.value + 1);
		if (!(kind === KIND_GLOBAL && field === '__stack_pointer'))
			kept.push(raw.subarray(pos, idx.next));
		pos = idx.next;
	}
	return Buffer.concat([Buffer.from(u32(kept.length)), ...kept]);
}

/** every table's maximum removed, as `-sALLOW_TABLE_GROWTH=1` links it */
function unboundTables(raw) {
	const count = readU32(raw, 0);
	const out = [...u32(count.value)];
	let pos = count.next;
	for (let i = 0; i < count.value; i++) {
		const reftype = raw[pos];
		const flags = readU32(raw, pos + 1);
		const min = readU32(raw, flags.next);
		pos = min.next;
		if (flags.value & 1) pos = readU32(raw, pos).next;
		out.push(reftype, ...u32(flags.value & ~1), ...u32(min.value));
	}
	return Buffer.from(out);
}

/** the glue with `env.__stack_pointer` supplied at the value the linker chose */
export function patchGlue(glue, initial) {
	const anchor = 'var wasmImports={';
	if (glue.includes('__stack_pointer:new WebAssembly.Global')) {
		throw new Error('the glue already supplies __stack_pointer');
	}
	if (glue.split(anchor).length !== 2) throw new Error(`expected exactly one "${anchor}"`);
	return glue.replace(
		anchor,
		`${anchor}__stack_pointer:new WebAssembly.Global({value:"i32",mutable:true},${initial}),`
	);
}

if (import.meta.url === `file://${process.argv[1]}`) {
	const [inWasm, inGlue, outWasm, outGlue, ...flags] = process.argv.slice(2);
	if (!outGlue) {
		console.error(
			'usage: node import-stack-pointer.mjs <in.wasm> <in-glue.mjs> <out.wasm> <out-glue.mjs> [--grow-table]'
		);
		process.exit(2);
	}
	const { wasm, initial } = importStackPointer(readFileSync(inWasm), {
		growTable: flags.includes('--grow-table')
	});
	writeFileSync(outWasm, wasm);
	writeFileSync(outGlue, patchGlue(readFileSync(inGlue, 'utf8'), initial));
	console.log(JSON.stringify({ outWasm, outGlue, initial, bytes: wasm.length }));
}

/**
 * Retypes vrzno's `Module.ccall` sites for the LP64 (wasm64) ABI.
 *
 * WHY THIS IS NEEDED AT ALL
 * vrzno's JS lives in `EM_ASM` blocks inside its C sources and reaches back into the interpreter
 * through `Module.ccall(name, returnType, argTypes, args)`. Every site declares its pointers as
 * `'number'`, which is true under ILP32 and a lie under LP64: emscripten's `ccall` builds
 * `toC = {pointer: p => BigInt(p), ...}` and only converts an argument whose declared type has a
 * converter, so a pointer declared `'number'` is handed to an i64 parameter as a JS Number and the
 * call throws `Cannot convert <n> to a BigInt`.
 *
 * THE RETURN DIRECTION IS THE HALF THAT DOES NOT THROW, and it is the reason this rewrites both.
 * `convertReturnValue` returns `Number(ret)` for `'pointer'` and the raw value otherwise, so a
 * pointer declared `'number'` comes back as a **BigInt**. The JS then does `Module.targets.get(zv)`
 * and `ptr >> 2` with it -- and a BigInt key never matches a Number key in a Map. Chasing only the
 * exception would leave that silently wrong.
 *
 * The mapping is DERIVED from the C signatures in the same tree rather than transcribed, so a pin
 * bump cannot desync the table from the code it describes. An arity mismatch between a call site and
 * its signature is a hard error: it means the site is calling something this script did not read.
 *
 * Idempotent, and keyed on the patched shape rather than on a marker comment.
 *
 * Usage:
 *   node patch-vrzno-lp64.mjs <ext/vrzno dir> [--verify] [--extra <file> ...]
 *
 * `--extra` rewrites an already-built emscripten glue with the same table, which is how the
 * transform is proven in seconds against a downloaded artifact instead of in a 12-minute build.
 */

import { readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

/** C types that are 64 bits wide under LP64 but are NOT pointers; they still cross as BigInt */
const WIDE_SCALARS = new Set([
	'long',
	'unsigned long',
	'zend_long',
	'zend_ulong',
	'size_t',
	'ssize_t',
	'intptr_t',
	'uintptr_t',
	'ptrdiff_t'
]);

/**
 * How one C type crosses the ccall boundary.
 *
 * `pointer` is emscripten's own token and is the only one with a converter; `wide` is a 64-bit
 * scalar, which ccall cannot convert at all and which therefore has to be widened at the call site.
 */
function kindOf(type) {
	const t = type
		.replace(/\bconst\b/g, '')
		.replace(/\s+/g, ' ')
		.trim();
	if (t.includes('*')) return 'pointer';
	if (WIDE_SCALARS.has(t.replace(/\s*\*/g, '').trim())) return 'wide';
	return 'number';
}

/** every `EMSCRIPTEN_KEEPALIVE` export in the tree, by name */
export function readSignatures(files) {
	const signatures = new Map();
	// the return type is everything before the keepalive marker; a parameter list ends at the first
	// `)` because none of these takes a function pointer
	const re = /([A-Za-z_][\w\s*]*?)\s*EMSCRIPTEN_KEEPALIVE\s+(\w+)\s*\(([^)]*)\)/g;
	for (const [, source] of files) {
		for (const m of source.matchAll(re)) {
			const [, ret, name, rawParams] = m;
			const params =
				rawParams.trim() === '' || rawParams.trim() === 'void'
					? []
					: rawParams.split(',').map((p) => {
							// strip the parameter NAME, keeping the type and any `*` that clung to it
							const cleaned = p.trim().replace(/\b\w+\s*$/, '');
							return kindOf(cleaned.includes('*') ? cleaned : p.trim().replace(/\s+\w+$/, ''));
						});
			signatures.set(name, { returns: kindOf(ret), params });
		}
	}
	return signatures;
}

const CALL = /Module\.ccall\(\s*(['"])(\w+)\1\s*,\s*(['"])(\w+)\3\s*,\s*\[([^\]]*)\]\s*,/g;

/** an `EM_ASM` block binding one of its `$n` arguments to a name */
const EM_ASM_BIND = /(\bconst\s+\w+\s*=\s*)(\$\d+)(\s*[;,])/g;

/**
 * Coerces every `EM_ASM` argument binding to a Number.
 *
 * **`EM_ASM` IS AFFECTED TOO, AND CHECKING ONLY THE POINTER CASE SAID OTHERWISE.** `readEmAsmArgs`
 * converts a `p` argument with `Number(HEAPU64[...])`, so pointers arrive as Numbers and the first
 * reading of this was that `EM_ASM` needed nothing. It reads a `j` argument as `HEAP64[...]`, which
 * is a **BigInt** -- and under LP64 every `size_t`, `zend_long` and `off_t` becomes `j` where it used
 * to be `i`. `sizeof(zval)`, `self->fpos` and `Z_LVAL_P(offset)` are all in that class, and each one
 * ends up in ordinary arithmetic (`argv + i * size`, `fpos >= target.buffer.length`) that throws
 * `Cannot mix BigInt and other types`.
 *
 * Coercing at the BINDING rather than at each use is what makes this bounded: every block opens by
 * naming its arguments, so one rule covers every later use of them. It is a no-op for a value that
 * is already a Number, and exact for every value here -- these are sizes, counts, offsets, handles
 * and timeouts, none of which reaches 2^53. A cast to `int` in C would be wrong for the ones that
 * are genuinely 64-bit: truncating `Z_LVAL_P` would reintroduce the exact limit wasm64 exists to
 * remove.
 */
export function coerceEmAsmArgs(source) {
	let count = 0;
	const out = source.replace(EM_ASM_BIND, (whole, head, arg, tail) => {
		count++;
		return `${head}Number(${arg})${tail}`;
	});
	return { out, count };
}

/**
 * Rewrites every call site in one source, and reports what it could not account for.
 *
 * A site whose arity disagrees with its signature is collected rather than rewritten -- silently
 * emitting the wrong number of types would produce a build that links and misbehaves.
 */
export function rewrite(source, signatures) {
	const problems = [];
	let changed = 0;
	let wide = 0;

	const out = source.replace(CALL, (whole, q1, name, q2, returnType, argTypes) => {
		const sig = signatures.get(name);
		if (!sig) {
			problems.push(`${name}: no EMSCRIPTEN_KEEPALIVE signature found`);
			return whole;
		}
		// a TRAILING COMMA is legal in a JS array literal and elides, so `['number','number',]` has
		// length 2 rather than 3; counting the split naively made the arity guard fire on a source
		// that was correct, which is the right way round for a guard to be wrong
		const declared = argTypes
			.split(',')
			.map((t) => t.trim())
			.filter((t) => t !== '').length;
		if (declared !== sig.params.length) {
			problems.push(
				`${name}: call site declares ${declared} arg types, signature takes ${sig.params.length}`
			);
			return whole;
		}

		// ONLY `'number'` IS WRONG. `'string'` and `'array'` have their own converters in `toC` and
		// both already return `BigInt(ptr)`, so they are correct under LP64 as they stand -- and one
		// site really does pass a JS string to a `char*`. Rewriting those to `'pointer'` would make
		// `BigInt("someKey")` throw a SyntaxError, which is a regression this script would have
		// introduced while claiming to fix the ABI.
		const declaredTypes = argTypes
			.split(',')
			.map((t) => t.trim().replace(/^['"]|['"]$/g, ''))
			.filter((t) => t !== '');
		// A 64-BIT SCALAR TAKES `'pointer'` TOO, and the name is the only thing wrong with that.
		// `toC` has exactly three converters and `pointer` is `p => BigInt(p)`, which is the precise
		// conversion an i64 parameter needs -- there is no `'i64'` token to reach for. It is exact
		// for negatives, and the one site that hits this (`vrzno_expose_create_long`) is already
		// guarded by `Number.isInteger(value)`, so the `BigInt(1.5)` throw is unreachable.
		const types = sig.params.map((k, i) => {
			const already = declaredTypes[i];
			if (already !== 'number') return already;
			if (k === 'wide') wide++;
			return k === 'pointer' || k === 'wide' ? 'pointer' : 'number';
		});
		// a `'pointer'` RETURN is narrowed by `Number(ret)`, which is exact for an address and
		// lossy for a 64-bit value, so a wide return would need a different treatment than this
		if (sig.returns === 'wide') {
			problems.push(`${name}: returns a 64-bit scalar, which Number(ret) would narrow`);
			return whole;
		}
		const nextReturn =
			returnType === 'number' && sig.returns === 'pointer' ? 'pointer' : returnType;
		const nextArgs = types.map((t) => `${q1}${t}${q1}`).join(',');

		const replaced = `Module.ccall(${q1}${name}${q1},${q2}${nextReturn}${q2},[${nextArgs}],`;
		if (replaced !== whole.replace(/\s+/g, '')) changed++;
		return replaced;
	});

	return { out, changed, wide, problems };
}

function main() {
	const args = process.argv.slice(2);
	const dir = args.find((a) => !a.startsWith('--'));
	const verify = args.includes('--verify');
	const extras = [];
	for (let i = 0; i < args.length; i++) {
		if (args[i] === '--extra' && args[i + 1]) extras.push(args[++i]);
	}
	if (!dir) {
		console.error('usage: node patch-vrzno-lp64.mjs <ext/vrzno dir> [--verify] [--extra <file>]');
		process.exit(2);
	}

	const sources = readdirSync(dir)
		.filter((f) => f.endsWith('.c') || f.endsWith('.h'))
		.map((f) => [join(dir, f), readFileSync(join(dir, f), 'utf8')]);
	const signatures = readSignatures(sources);
	console.log(`vrzno-lp64: ${signatures.size} exported signatures read from ${dir}`);

	const targets = [...sources.filter(([, s]) => s.includes('Module.ccall('))];
	for (const path of extras) targets.push([path, readFileSync(path, 'utf8')]);

	let totalChanged = 0;
	let totalWide = 0;
	const allProblems = [];

	let totalCoerced = 0;
	for (const [path, source] of targets) {
		const { out, changed, wide, problems } = rewrite(source, signatures);
		const coerced = coerceEmAsmArgs(out);
		totalChanged += changed;
		totalWide += wide;
		totalCoerced += coerced.count;
		allProblems.push(...problems.map((p) => `${path}: ${p}`));
		if (!verify && coerced.out !== source) writeFileSync(path, coerced.out);
		console.log(`  ${path}  ${changed} site(s) retyped, ${coerced.count} EM_ASM arg(s) coerced`);
	}

	if (allProblems.length > 0) {
		for (const p of allProblems) console.error(`vrzno-lp64: ${p}`);
		console.error('vrzno-lp64: refusing to claim success with sites unaccounted for');
		process.exit(1);
	}

	if (totalWide > 0) {
		console.log(
			`vrzno-lp64: ${totalWide} argument(s) are 64-bit SCALARS rather than pointers; ccall ` +
				'has no converter for those, so each is widened at its call site by the shell patch'
		);
	}

	if (verify) {
		// after a successful apply BOTH transforms are no-ops, which is the shape this checks --
		// asserting only the ccall half would pass on a tree with the EM_ASM half missing
		process.exit(totalChanged === 0 && totalCoerced === 0 ? 0 : 1);
	}
	console.log(
		`vrzno-lp64: ${totalChanged} ccall site(s) rewritten, ${totalCoerced} EM_ASM arg(s) coerced`
	);
}

if (import.meta.url === `file://${process.argv[1]}`) main();

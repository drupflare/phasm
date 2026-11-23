/**
 * Inserts a stack-limit check before every lowering of `__stack_pointer` in a linked binary.
 *
 * The C stack sits directly above the static data, so a frame that runs past the stack's end writes
 * into PHP's globals with no error. With the 32 MiB stack php-wasm links by default that never
 * happened in practice; with a 4 MiB stack a deep `array_map` recursion of about 2,650 levels does
 * it in every run. This pass makes that a clean trap: `if (sp <u limit) unreachable` between the
 * computation of a lowered stack pointer and the `global.set` that publishes it.
 *
 * The limit is the stack end the module stores itself: `emscripten_stack_init` sets a global to a
 * constant and `emscripten_stack_get_end` returns it. A raise by a constant is not checked. A stack
 * pointer write in any other shape refuses the module rather than leaving a frame unchecked.
 * Measured on the shipping binary's shape: 12,977 checks, +1.30% module size, and 1.000 to 1.013 of
 * the unguarded render time on a quiet rig.
 *
 * The result carries a `phasm.stack-guard` custom section with the stats, which `--verify` reads.
 *
 * Usage:
 *   node stack-guard.mjs <in.wasm> <out.wasm>
 *   node stack-guard.mjs --verify <wasm>
 */
import binaryen from 'binaryen';
import { readFileSync, writeFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

export const SECTION = 'phasm.stack-guard';

const i32 = binaryen.i32;

export class StackGuardRefusal extends Error {
	constructor(reasons) {
		super(`stack-guard refuses this module: ${reasons.join('; ')}`);
		this.name = 'StackGuardRefusal';
		this.reasons = reasons;
	}
}

const leaves = new Set([
	binaryen.ConstId,
	binaryen.LocalGetId,
	binaryen.GlobalGetId,
	binaryen.MemorySizeId,
	binaryen.NopId,
	binaryen.UnreachableId,
	binaryen.RefFuncId,
	binaryen.DataDropId
]);

// every expression kind the walk knows; anything else is recorded and the module refused
function children(e, id, visit, unknown) {
	switch (id) {
		case binaryen.BlockId:
			for (let k = 0, n = binaryen.Block.getNumChildren(e); k < n; k++)
				visit(binaryen.Block.getChildAt(e, k), (x) => binaryen.Block.setChildAt(e, k, x));
			return;
		case binaryen.IfId:
			visit(binaryen.If.getCondition(e), (x) => binaryen.If.setCondition(e, x));
			visit(binaryen.If.getIfTrue(e), (x) => binaryen.If.setIfTrue(e, x));
			if (binaryen.If.getIfFalse(e))
				visit(binaryen.If.getIfFalse(e), (x) => binaryen.If.setIfFalse(e, x));
			return;
		case binaryen.LoopId:
			visit(binaryen.Loop.getBody(e), (x) => binaryen.Loop.setBody(e, x));
			return;
		case binaryen.BreakId:
			if (binaryen.Break.getValue(e))
				visit(binaryen.Break.getValue(e), (x) => binaryen.Break.setValue(e, x));
			if (binaryen.Break.getCondition(e))
				visit(binaryen.Break.getCondition(e), (x) => binaryen.Break.setCondition(e, x));
			return;
		case binaryen.SwitchId:
			if (binaryen.Switch.getValue(e))
				visit(binaryen.Switch.getValue(e), (x) => binaryen.Switch.setValue(e, x));
			visit(binaryen.Switch.getCondition(e), (x) => binaryen.Switch.setCondition(e, x));
			return;
		case binaryen.CallId:
			for (let k = 0, n = binaryen.Call.getNumOperands(e); k < n; k++)
				visit(binaryen.Call.getOperandAt(e, k), (x) => binaryen.Call.setOperandAt(e, k, x));
			return;
		case binaryen.CallIndirectId:
			for (let k = 0, n = binaryen.CallIndirect.getNumOperands(e); k < n; k++)
				visit(binaryen.CallIndirect.getOperandAt(e, k), (x) =>
					binaryen.CallIndirect.setOperandAt(e, k, x)
				);
			visit(binaryen.CallIndirect.getTarget(e), (x) => binaryen.CallIndirect.setTarget(e, x));
			return;
		case binaryen.LocalSetId:
			visit(binaryen.LocalSet.getValue(e), (x) => binaryen.LocalSet.setValue(e, x));
			return;
		case binaryen.GlobalSetId:
			visit(binaryen.GlobalSet.getValue(e), (x) => binaryen.GlobalSet.setValue(e, x));
			return;
		case binaryen.LoadId:
			visit(binaryen.Load.getPtr(e), (x) => binaryen.Load.setPtr(e, x));
			return;
		case binaryen.StoreId:
			visit(binaryen.Store.getPtr(e), (x) => binaryen.Store.setPtr(e, x));
			visit(binaryen.Store.getValue(e), (x) => binaryen.Store.setValue(e, x));
			return;
		case binaryen.UnaryId:
			visit(binaryen.Unary.getValue(e), (x) => binaryen.Unary.setValue(e, x));
			return;
		case binaryen.BinaryId:
			visit(binaryen.Binary.getLeft(e), (x) => binaryen.Binary.setLeft(e, x));
			visit(binaryen.Binary.getRight(e), (x) => binaryen.Binary.setRight(e, x));
			return;
		case binaryen.SelectId:
			visit(binaryen.Select.getIfTrue(e), (x) => binaryen.Select.setIfTrue(e, x));
			visit(binaryen.Select.getIfFalse(e), (x) => binaryen.Select.setIfFalse(e, x));
			visit(binaryen.Select.getCondition(e), (x) => binaryen.Select.setCondition(e, x));
			return;
		case binaryen.DropId:
			visit(binaryen.Drop.getValue(e), (x) => binaryen.Drop.setValue(e, x));
			return;
		case binaryen.ReturnId:
			if (binaryen.Return.getValue(e))
				visit(binaryen.Return.getValue(e), (x) => binaryen.Return.setValue(e, x));
			return;
		case binaryen.MemoryGrowId:
			visit(binaryen.MemoryGrow.getDelta(e), (x) => binaryen.MemoryGrow.setDelta(e, x));
			return;
		// bulk memory carries only plain operands, so a stack pointer write inside one is still found
		case binaryen.MemoryCopyId:
			visit(binaryen.MemoryCopy.getDest(e), (x) => binaryen.MemoryCopy.setDest(e, x));
			visit(binaryen.MemoryCopy.getSource(e), (x) => binaryen.MemoryCopy.setSource(e, x));
			visit(binaryen.MemoryCopy.getSize(e), (x) => binaryen.MemoryCopy.setSize(e, x));
			return;
		case binaryen.MemoryFillId:
			visit(binaryen.MemoryFill.getDest(e), (x) => binaryen.MemoryFill.setDest(e, x));
			visit(binaryen.MemoryFill.getValue(e), (x) => binaryen.MemoryFill.setValue(e, x));
			visit(binaryen.MemoryFill.getSize(e), (x) => binaryen.MemoryFill.setSize(e, x));
			return;
		case binaryen.MemoryInitId:
			visit(binaryen.MemoryInit.getDest(e), (x) => binaryen.MemoryInit.setDest(e, x));
			visit(binaryen.MemoryInit.getOffset(e), (x) => binaryen.MemoryInit.setOffset(e, x));
			visit(binaryen.MemoryInit.getSize(e), (x) => binaryen.MemoryInit.setSize(e, x));
			return;
		default:
			if (leaves.has(id)) return;
			unknown.add(`expression kind ${id}`);
	}
}

function exportedFunction(mod, name) {
	for (let k = 0; k < mod.getNumExports(); k++) {
		const ex = binaryen.getExportInfo(mod.getExportByIndex(k));
		if (ex.name === name && ex.kind === binaryen.ExternalFunction) return mod.getFunction(ex.value);
	}
	return undefined;
}

// the stack end the module stores: get_end returns a global that emscripten_stack_init sets to a constant
function moduleLimit(mod, unknown) {
	const getEnd = exportedFunction(mod, 'emscripten_stack_get_end');
	const init = exportedFunction(mod, 'emscripten_stack_init');
	if (!getEnd || !init) return undefined;
	const read = binaryen.Function.getBody(getEnd);
	if (binaryen.getExpressionId(read) !== binaryen.GlobalGetId) return undefined;
	const endName = binaryen.GlobalGet.getName(read);
	let found;
	const scan = (e) => {
		const id = binaryen.getExpressionId(e);
		if (id === binaryen.GlobalSetId && binaryen.GlobalSet.getName(e) === endName) {
			const v = binaryen.GlobalSet.getValue(e);
			if (binaryen.getExpressionId(v) === binaryen.ConstId)
				found = binaryen.Const.getValueI32(v) >>> 0;
		}
		children(e, id, (c) => scan(c), unknown);
	};
	scan(binaryen.Function.getBody(init));
	return found;
}

/** the guarded binary and what the pass did; `limit` overrides the module's own stack end */
export function stackGuard(input, { limit: requested } = {}) {
	const mod = binaryen.readBinary(input);
	mod.setFeatures(
		binaryen.Features.MVP |
			binaryen.Features.MutableGlobals |
			binaryen.Features.SignExt |
			binaryen.Features.NontrappingFPToInt |
			binaryen.Features.BulkMemory |
			binaryen.Features.Multivalue |
			binaryen.Features.ReferenceTypes
	);
	try {
		return guard(mod, input.length, requested);
	} finally {
		mod.dispose();
	}
}

function guard(mod, bytesIn, requested) {
	const unknown = new Set();
	const reasons = [];
	if (mod.getNumGlobals() === 0) throw new StackGuardRefusal(['no stack pointer global']);
	const sp = binaryen.getGlobalInfo(mod.getGlobalByIndex(0)).name;
	const fromModule = moduleLimit(mod, unknown);
	if (requested !== undefined && fromModule !== undefined && requested !== fromModule)
		throw new StackGuardRefusal([
			`limit ${requested} differs from the module stack end ${fromModule}`
		]);
	const limit = requested ?? fromModule;
	if (limit === undefined)
		throw new StackGuardRefusal(['no stack end in the module and no limit given']);

	const stats = {
		limit,
		functions: 0,
		writers: 0,
		sites: { lowerConst: 0, lowerVar: 0, local: 0, raise: 0 },
		checks: 0,
		locals: 0,
		bytesIn,
		bytesOut: 0
	};
	const constOf = (e) =>
		binaryen.getExpressionId(e) === binaryen.ConstId && binaryen.getExpressionType(e) === i32
			? binaryen.Const.getValueI32(e)
			: undefined;
	// the expression under any local.tee wrappers
	const core = (e) => {
		while (binaryen.getExpressionId(e) === binaryen.LocalSetId) e = binaryen.LocalSet.getValue(e);
		return e;
	};

	for (let index = 0, n = mod.getNumFunctions(); index < n; index++) {
		const fn = mod.getFunctionByIndex(index);
		const body = binaryen.Function.getBody(fn);
		if (!body) continue;
		stats.functions++;
		const label = `function ${index} (${binaryen.Function.getName(fn)})`;
		let wrote = false;

		const site = (e, set) => {
			wrote = true;
			const value = binaryen.GlobalSet.getValue(e);
			const v = core(value);
			const vid = binaryen.getExpressionId(v);
			let kind;
			// a subtraction that can wrap below zero also gets a wrap test on its left operand
			let sub;
			if (vid === binaryen.LocalGetId) kind = 'local';
			else if (vid === binaryen.BinaryId) {
				const op = binaryen.Binary.getOp(v);
				const left = binaryen.Binary.getLeft(v);
				const rc = constOf(binaryen.Binary.getRight(v));
				if (op === binaryen.SubInt32) {
					if (rc !== undefined) {
						kind = rc > 0 ? 'lowerConst' : 'raise';
						if (rc >= limit) sub = v;
					} else {
						kind = 'lowerVar';
						sub = v;
					}
				} else if (op === binaryen.AddInt32) {
					if (rc !== undefined) {
						kind = rc < 0 ? 'lowerConst' : 'raise';
						if (-rc >= limit) sub = v;
					} else reasons.push(`${label}: add of two non-constants`);
				} else if (op === binaryen.AndInt32 && rc !== undefined) {
					const inner = core(left);
					if (
						binaryen.getExpressionId(inner) === binaryen.BinaryId &&
						binaryen.Binary.getOp(inner) === binaryen.SubInt32 &&
						constOf(binaryen.Binary.getRight(inner)) === undefined
					) {
						kind = 'lowerVar';
						sub = inner;
					} else reasons.push(`${label}: and of an expression that is not an alloca`);
				} else reasons.push(`${label}: binary operation ${op} as the new stack pointer`);
			} else if (vid === binaryen.ConstId) reasons.push(`${label}: constant stack pointer`);
			else if (vid === binaryen.CallId) reasons.push(`${label}: stack pointer from a call`);
			else reasons.push(`${label}: expression kind ${vid} as the new stack pointer`);
			if (!kind) return;
			stats.sites[kind]++;
			if (kind === 'raise') return;
			stats.checks++;
			// a prologue that already tees the new pointer into a local keeps that local; a fresh
			// local per check cost recursion depth in the first build of this pass
			const tee =
				binaryen.getExpressionId(value) === binaryen.LocalSetId &&
				binaryen.getExpressionType(value) === i32;
			let t;
			let computed = value;
			if (tee) {
				t = binaryen.LocalSet.getIndex(value);
				computed = binaryen.LocalSet.getValue(value);
			} else {
				t = binaryen._BinaryenFunctionAddVar(fn, i32);
				stats.locals++;
			}
			const get = (k) => mod.local.get(k, i32);
			let bad = mod.i32.lt_u(get(t), mod.i32.const(limit | 0));
			if (sub !== undefined) {
				const tl = binaryen._BinaryenFunctionAddVar(fn, i32);
				stats.locals++;
				binaryen.Binary.setLeft(sub, mod.local.tee(tl, binaryen.Binary.getLeft(sub), i32));
				bad = mod.i32.or(bad, mod.i32.gt_u(get(t), get(tl)));
			}
			binaryen.GlobalSet.setValue(e, get(t));
			set(mod.block(null, [mod.local.set(t, computed), mod.if(bad, mod.unreachable()), e]));
		};

		const rewrite = (e, set) => {
			const id = binaryen.getExpressionId(e);
			children(e, id, (c, s) => rewrite(c, s), unknown);
			if (id === binaryen.GlobalSetId && binaryen.GlobalSet.getName(e) === sp) site(e, set);
		};
		rewrite(body, (x) => binaryen.Function.setBody(fn, x));
		if (wrote) stats.writers++;
	}
	if (unknown.size) reasons.push(...[...unknown].sort().map((u) => `unwalked ${u}`));
	if (reasons.length) throw new StackGuardRefusal(reasons);
	if (stats.checks === 0) throw new StackGuardRefusal(['no stack pointer lowering found']);
	mod.addCustomSection(
		SECTION,
		new TextEncoder().encode(JSON.stringify({ ...stats, bytesOut: 0 }))
	);
	if (!mod.validate()) throw new TypeError('stack-guard produced an invalid module');
	const bytes = mod.emitBinary();
	stats.bytesOut = bytes.length;
	return { bytes, stats };
}

/** the stats a guarded binary carries, or undefined when it was never guarded */
export function guardOf(bytes) {
	const sections = WebAssembly.Module.customSections(new WebAssembly.Module(bytes), SECTION);
	if (!sections.length) return undefined;
	return JSON.parse(new TextDecoder().decode(sections[0]));
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
	const args = process.argv.slice(2);
	if (args[0] === '--verify') {
		const stats = guardOf(readFileSync(args[1]));
		if (!stats) {
			console.error(`${args[1]} carries no ${SECTION} section`);
			process.exit(1);
		}
		console.log(`${args[1]}: ${stats.checks} checks at limit ${stats.limit}`);
	} else if (args.length === 2) {
		const { bytes, stats } = stackGuard(readFileSync(args[0]));
		writeFileSync(args[1], bytes);
		console.log(JSON.stringify(stats));
	} else {
		console.error('usage: node stack-guard.mjs <in.wasm> <out.wasm> | --verify <wasm>');
		process.exit(2);
	}
}

// Gate for the VM signal word. Boots a long64 build like smoke.mjs, but registers the instance
// through a copy of workerd's wasm-instantiate-shim.js find-and-register logic, so the address
// under test is the one the runtime would be handed. Not part of `bun run test`: it needs a built
// artifact. usage: node tools/test-instance-signal.mjs <glue.mjs> <wasm>
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const [glue, wasmPath] = process.argv.slice(2);
if (!glue || !wasmPath) {
	console.error('usage: node tools/test-instance-signal.mjs <glue.mjs> <wasm>');
	process.exit(2);
}

const failures = [];
function check(label, ok) {
	console.log(`${ok ? 'ok  ' : 'FAIL'} ${label}`);
	if (!ok) failures.push(label);
}
function finish() {
	if (failures.length) {
		console.log(`\n${failures.length} failed`);
		process.exit(1);
	}
	console.log('\nall passed');
	process.exit(0);
}

const g = globalThis;
g.location ??= new URL(pathToFileURL(process.cwd() + '/').href);
g.self ??= globalThis;

const module = await WebAssembly.compile(readFileSync(wasmPath));
check(
	'module exports __instance_signal as a global',
	WebAssembly.Module.exports(module).some(
		(e) => e.name === '__instance_signal' && e.kind === 'global'
	)
);

// copied from workerd src/workerd/io/wasm-instantiate-shim.js; registerShutdown becomes a record
const { instantiate: originalInstantiate, Module, Memory, Global } = WebAssembly;
const registered = [];

function findMemory(instance, importObj, mod) {
	const importedMemory = Module.imports(mod).find(({ kind }) => kind === 'memory');
	if (importedMemory) {
		const value = importObj[importedMemory.module][importedMemory.name];
		return value instanceof Memory ? value : undefined;
	}
	const exportedMemory = Module.exports(mod).find(({ kind }) => kind === 'memory');
	if (exportedMemory) return instance.exports[exportedMemory.name];
	return undefined;
}

function checkAndRegisterShutdown(instance, imports, mod) {
	const exports = instance.exports;
	if (!exports) return;
	const terminatedGlobal = exports['__instance_terminated'];
	const signalGlobal = exports['__instance_signal'];
	const hasTerminated = terminatedGlobal instanceof Global;
	const hasSignal = signalGlobal instanceof Global;
	if (!hasTerminated && !hasSignal) return;
	const memory = findMemory(instance, imports, mod);
	if (memory) {
		registered.push({
			memory,
			signal: hasSignal ? signalGlobal.value : -1,
			terminated: hasTerminated ? terminatedGlobal.value : -1
		});
	}
}

WebAssembly.instantiate = function instantiate(moduleOrBytes) {
	const importObj = arguments[1];
	return Reflect.apply(originalInstantiate, this, arguments).then(function (result) {
		try {
			const instance = result.instance || result;
			const mod = result.module || moduleOrBytes;
			checkAndRegisterShutdown(instance, importObj, mod);
		} catch {}
		return result;
	});
};

const factory = (await import(pathToFileURL(resolve(glue)).href)).default;
const out = [];
const php = await factory({
	stdout: (byte) => {
		if (byte !== null && byte !== undefined) out.push(byte);
	},
	stderr: () => {},
	printErr: () => {},
	instantiateWasm(imports, receive) {
		imports.env.memory = new WebAssembly.Memory({ initial: 1024, maximum: 65536 });
		WebAssembly.instantiate(module, imports).then((i) => receive(i, module));
		return {};
	}
});

php.FS.writeFile('/php.ini', 'opcache.enable=0\nmemory_limit=256M\n', { encoding: 'utf8' });
await php.ccall('pib_storage_init', 'number', [], [], { async: true });
await php.ccall('pib_init', 'number', ['string'], ['embed'], { async: true });

async function run(code) {
	out.length = 0;
	const ret = await php.ccall('pib_run', 'number', ['string'], [code], { async: true });
	return { ret, out: Buffer.from(out).toString('utf8') };
}

const echo = await run('echo 1+1;');
check('echo 1+1 prints 2', echo.ret === 0 && echo.out === '2');

check('the shim registered one instance with a signal address', registered.length === 1);
if (registered.length !== 1) finish();
const { memory, signal: address } = registered[0];
console.log(`signal address ${address} (from the __instance_signal global export)`);
check(
	'the signal address is 4-byte aligned and inside memory',
	address >= 0 && address % 4 === 0 && address + 4 <= memory.buffer.byteLength
);

const LOOP = '$s = 0; for ($i = 0; $i < 100000; $i++) { $s += $i; } echo $s;';
const SUM = '4999950000';
const setSignal = (v) => new DataView(memory.buffer).setUint32(address, v, true);
const readSignal = () => new DataView(memory.buffer).getUint32(address, true);
const signalPolls = () => php.ccall('zend_wasm_slice_stat', 'number', ['number'], [7]);

const clearBase = signalPolls();
const clearRun = await run(LOOP);
check('a clear signal word counts no signal polls', signalPolls() === clearBase);
check('loop with a clear signal word prints its sum', clearRun.out === SUM);

setSignal(24);
check('the signal word reads back 24', readSignal() === 24);
const raisedBase = signalPolls();
const raisedRun = await run(LOOP);
check('loop with the signal word at 24 prints its sum', raisedRun.out === SUM);
check('case 7 counts while the signal word is 24', signalPolls() - raisedBase > 0);

setSignal(0);
const stoppedBase = signalPolls();
const stoppedRun = await run(LOOP);
check('case 7 stops counting when the signal word is written 0', signalPolls() === stoppedBase);
check('loop after the signal word is written 0 prints its sum', stoppedRun.out === SUM);

const tickBase = php.ccall('zend_wasm_slice_stat', 'number', ['number'], [0]);
php.ccall('zend_wasm_slice_arm', 'number', ['number', 'number'], [1000, 0]);
const armedBase = php.ccall('zend_wasm_slice_stat', 'number', ['number'], [0]);
await run(LOOP);
const tickFires = php.ccall('zend_wasm_slice_stat', 'number', ['number'], [0]) - armedBase;
php.ccall('zend_wasm_slice_arm', 'number', ['number', 'number'], [0, 0]);
check(`arm(1000,0) still fires on the tick (fires=${tickFires}, base=${tickBase})`, tickFires > 0);

finish();

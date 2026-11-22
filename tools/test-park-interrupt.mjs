// Gate for the interrupt park. Boots a long64 build, arms the poll tick in park mode, and drives
// cfw_park_run / cfw_park_resume_interrupt until the workload finishes. Not part of `bun run test`:
// it needs a built artifact. usage: node tools/test-park-interrupt.mjs <glue.mjs> <wasm>
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const [glue, wasmPath] = process.argv.slice(2);
if (!glue || !wasmPath) {
	console.error('usage: node tools/test-park-interrupt.mjs <glue.mjs> <wasm>');
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
const factory = (await import(pathToFileURL(resolve(glue)).href)).default;

// Nested user calls, a closure called directly, a generator, an array_map callback and a __get.
// The checksum line is the whole output of an unparked run.
const WORK = `class Bag { private $d = ['x' => 3]; public function __get($n) { return $this->d[$n] * 2; } }
function leaf($i) { return ($i * 31 + 7) % 1000003; }
function mid($i) { $s = 0; for ($k = 0; $k < 20; $k++) { $s = ($s + leaf($i + $k)) % 1000003; } return $s; }
function gen($n) { for ($i = 0; $i < $n; $i++) { yield mid($i); } }
$sum = 0; $str = '';
$f = function ($x) use (&$sum) { $sum = ($sum + $x * 3) % 1000003; return $x; };
$bag = new Bag();
for ($i = 0; $i < 3000; $i++) {
	$sum = ($sum + mid($i)) % 1000003;
	$f($i);
	$sum = ($sum + $bag->x) % 1000003;
	if ($i % 100 == 0) { $str .= $i; }
}
foreach (gen(300) as $v) { $sum = ($sum + $v) % 1000003; }
$sum = ($sum + array_sum(array_map(fn($v) => leaf($v), range(1, 200)))) % 1000003;
echo $sum, ':', strlen($str), ':', md5($str), "\\n";
`;
// The generator body polls on every yield and the consumer polls between them. Under a fixed
// 64-poll retry, every retry lands in the generator body and the budget parks once in 200000
// passes; a period-1 retry parks within a few polls of each budget event.
const GEN_WORK = `function g() { $i = 0; for (;;) { yield $i++; } }
$sum = 0; $c = 0;
foreach (g() as $v) { $sum = ($sum + $v) % 1000003; if (++$c >= 200000) { break; } }
echo $sum, "\\n";
`;
const PARKED = 'PARKED_INTERRUPT';
const MAX_PARKS = 1000000;

// Boots one instance. The module exports its own memory and imports none, so the memory is the
// instance's export, not one passed in.
async function boot() {
	const out = [];
	let memory;
	let signal = -1;
	const php = await factory({
		stdout: (byte) => {
			if (byte !== null && byte !== undefined) out.push(byte);
		},
		stderr: () => {},
		printErr: () => {},
		instantiateWasm(imports, receive) {
			WebAssembly.instantiate(module, imports).then((i) => {
				memory = i.exports.memory;
				signal = i.exports.__instance_signal.value;
				receive(i, module);
			});
			return {};
		}
	});
	return { php, out, memory, signal };
}

// The same init sequence on every instance, so the JS side (the function table) matches too.
async function initPhp(b) {
	b.php.FS.writeFile('/php.ini', 'opcache.enable=0\nmemory_limit=256M\n', { encoding: 'utf8' });
	await b.php.ccall('pib_storage_init', 'number', [], [], { async: true });
	await b.php.ccall('pib_init', 'number', ['string'], ['embed'], { async: true });
}

// A booted instance with PHP initialised and the workload in MEMFS.
async function bootReady() {
	const b = await boot();
	await initPhp(b);
	b.php.FS.writeFile('/work.php', WORK, { encoding: 'utf8' });
	return b;
}

const arm = (b, period) =>
	b.php.ccall('zend_wasm_slice_arm', 'number', ['number', 'number'], [period, 0]);
const stat = (b, which) => b.php.ccall('zend_wasm_slice_stat', 'number', ['number'], [which]);
const setSignal = (b, v) => new DataView(b.memory.buffer).setUint32(b.signal, v, true);
const readSignal = (b) => new DataView(b.memory.buffer).getUint32(b.signal, true);

async function run(b, code) {
	b.out.length = 0;
	const ret = await b.php.ccall('pib_run', 'number', ['string'], [code], { async: true });
	return { ret, text: Buffer.from(b.out).toString('utf8') };
}

// The park log as an array; a binary without cfw_park_log prints a PHP error, which reads as none.
const parkLog = (res) => {
	try {
		const v = JSON.parse(res.text);
		return Array.isArray(v) ? v : [];
	} catch {
		return [];
	}
};

// The workload's own output, when the chain has finished; the final resume prints DONE after it.
const finished = (text) => (text.endsWith('DONE') ? text.slice(0, -4) : null);

// Drives one chain to DONE. `beforeResume` may return a replacement instance (the durable case).
async function drive(b, period, beforeResume, file = '/work.php') {
	arm(b, period);
	let res = await run(b, `echo cfw_park_run(file_get_contents('${file}'));`);
	let parks = 0;
	while (res.text === PARKED) {
		parks++;
		if (parks > MAX_PARKS) throw new Error('park loop did not finish');
		if (beforeResume) b = await beforeResume(b, parks);
		setSignal(b, 0);
		arm(b, period);
		res = await run(b, 'echo cfw_park_resume_interrupt();');
	}
	return { text: finished(res.text), ret: res.ret, parks, b };
}

// Every MEMFS regular file. /dev and /proc belong to the runtime.
function snapshotFiles(FS) {
	const files = [];
	const walk = (dir) => {
		for (const name of FS.readdir(dir)) {
			if (name === '.' || name === '..') continue;
			const path = dir === '/' ? `/${name}` : `${dir}/${name}`;
			if (path === '/dev' || path === '/proc') continue;
			const mode = FS.stat(path).mode;
			if (FS.isDir(mode)) walk(path);
			else if (FS.isFile(mode)) files.push([path, FS.readFile(path)]);
		}
	};
	walk('/');
	return files;
}

function restoreFiles(FS, files) {
	for (const [path, data] of files) {
		const parts = path.split('/').slice(1, -1);
		let cur = '';
		for (const p of parts) {
			cur += `/${p}`;
			try {
				FS.mkdir(cur);
			} catch {}
		}
		FS.writeFile(path, data);
	}
}

// Copies the linear memory and the MEMFS into a fresh instance of the same size. The parked chain
// lives only in those two places; the caller drops `old`, which nothing references after this.
async function reincarnate(old) {
	const mem = new Uint8Array(old.memory.buffer).slice();
	const files = snapshotFiles(old.php.FS);
	const fresh = await boot();
	await initPhp(fresh);
	if (fresh.memory.buffer.byteLength !== mem.byteLength) {
		throw new Error(`memory sizes differ: ${fresh.memory.buffer.byteLength} vs ${mem.byteLength}`);
	}
	new Uint8Array(fresh.memory.buffer).set(mem);
	restoreFiles(fresh.php.FS, files);
	return fresh;
}

// Each chain runs on its own instance: the workload declares functions and classes, which PHP
// refuses to declare twice in one process.
const probe = await bootReady();
const echo = await run(probe, 'echo 1+1;');
check('the binary still serves echo 1+1 (prints 2)', echo.ret === 0 && echo.text === '2');

const baseline = await bootReady();
arm(baseline, 0);
const base = await run(baseline, WORK);
check(
	'the unparked workload prints a checksum line',
	base.ret === 0 && /^\d+:\d+:[0-9a-f]{32}\n$/.test(base.text)
);
const EXPECT = base.text;

// Exactness and refusal, for three tick periods on one instance.
let anyRefusal = false;
for (const period of [1000, 10000, 100000]) {
	const inst = await bootReady();
	const res = await drive(inst, period, null);
	const parks = stat(inst, 9);
	const refusals = stat(inst, 8);
	anyRefusal ||= refusals > 0;
	check(
		`period ${period}: parks happen (${parks} parks, ${refusals} refusals)`,
		parks > 0 && parks === res.parks
	);
	check(`period ${period}: output equals the unparked run`, res.text === EXPECT);

	const entries = parkLog(await run(inst, 'echo json_encode(cfw_park_log());'));
	const bad = entries.filter((e) =>
		e.split(/[:>]/).some((seg) => seg === 'gen' || seg === '__get')
	);
	check(
		`period ${period}: no park inside the generator or __get (${entries.length} recorded)`,
		entries.length > 0 && bad.length === 0
	);
}
check('refusals were counted for some period (array_map, __get, generator)', anyRefusal);

// A fixed 64-poll retry can alias with a generator loop: every retry lands in g's body, so the
// budget is refused again and again and the chain parks rarely (i5: 12469 refusals, 1 park). A
// period-1 retry keeps parking through the loop; the bound allows a few refused polls per park.
{
	const genBase = await bootReady();
	arm(genBase, 0);
	const genExpect = (await run(genBase, GEN_WORK)).text;

	const inst = await bootReady();
	inst.php.FS.writeFile('/gen.php', GEN_WORK, { encoding: 'utf8' });
	const res = await drive(inst, 1000, null, '/gen.php');
	const refusals = stat(inst, 8);
	const entries = parkLog(await run(inst, 'echo json_encode(cfw_park_log());'));
	const inConsumer = (e) => e.replace(/^[A-Z]+:/, '').split('>')[0] === '{main}';
	check(
		`generator loop: the budget keeps parking (${res.parks} parks, ${refusals} refusals)`,
		res.parks > 0 && refusals <= 4 * res.parks
	);
	check('generator loop: output equals the unparked run', res.text === genExpect);
	check(
		`generator loop: every park is in the consumer (${entries.length} recorded)`,
		entries.length > 0 && entries.every(inConsumer)
	);
}

// Durable: every 5th park the instance is replaced by a fresh one that took the memory and files.
{
	let restores = 0;
	const durInst = await bootReady();
	const durable = await drive(durInst, 10000, async (b, parks) => {
		if (parks % 5 !== 0) return b;
		restores++;
		return reincarnate(b);
	});
	check(`durable: ${restores} restores into fresh instances`, restores > 0);
	check('durable: the output after the restores equals the unparked run', durable.text === EXPECT);
}

// Signal: a word raised before a resume parks at the next poll with reason SIGNAL. The host clears
// the word before every other resume.
{
	const sig = await bootReady();
	arm(sig, 0);
	const sigBase = stat(sig, 10);
	arm(sig, 1000);
	let res = await run(sig, "echo cfw_park_run(file_get_contents('/work.php'));");
	const reasons = [];
	let raised = false;
	while (res.text === PARKED) {
		const entries = parkLog(await run(sig, 'echo json_encode(cfw_park_log());'));
		reasons.push(...entries.map((e) => e.split(':')[0]));
		if (reasons.length === 3 && !raised) {
			setSignal(sig, 24);
			raised = true;
		} else {
			setSignal(sig, 0);
		}
		arm(sig, 1000);
		res = await run(sig, 'echo cfw_park_resume_interrupt();');
	}
	check(
		'signal: the 4th park after the word was raised has reason SIGNAL',
		reasons[3] === 'SIGNAL'
	);
	check('signal: case 10 counts the signal park', stat(sig, 10) - sigBase >= 1);
	check('signal: the word reads back 0 after the clear', readSignal(sig) === 0);
	check('signal: the chain finishes with the unparked output', finished(res.text) === EXPECT);
}

finish();

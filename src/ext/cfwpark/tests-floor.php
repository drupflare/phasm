<?php
/**
 * THE CASE THE OTHER NATIVE TEST CANNOT SEE.
 *
 * `multitrip.php` calls run and resume from the same scope, so the resume's frame lands in the VM
 * stack slot the run's frame just vacated -- the old floor pointer and the new one are the SAME
 * ADDRESS, the predicate's walk terminates by coincidence, and a broken floor reads as correct. On a
 * Worker the two are separate `_run` invocations with frames in between, and there the walk went
 * past the parked chain into freed memory: a silent refusal, then `memory access out of bounds`.
 *
 * Resuming from a DIFFERENT stack depth than the run reproduces that here.
 */

$pass = 0;
$fail = 0;
function check(string $what, bool $ok, string $detail = ''): void {
	global $pass, $fail;
	$ok ? $pass++ : $fail++;
	printf("%s %s%s\n", $ok ? '  ok  ' : ' FAIL ', $what, $detail === '' ? '' : "  [$detail]");
}

cfw_park_trap('stream_socket_client');

$code = <<<'PHP'
function inner() {
	$a = @stream_socket_client('tcp://a.invalid:1', $e1, $m1, 1);
	$b = @stream_socket_client('tcp://b.invalid:1', $e2, $m2, 1);
	$c = @stream_socket_client('tcp://c.invalid:1', $e3, $m3, 1);
	return [$a, $b, $c];
}
$GLOBALS['GOT'] = inner();
PHP;

/** the run happens three frames deeper than the resumes, so no slot can be shared */
function deep3(string $code) {
	return cfw_park_run($code);
}
function deep2(string $code) {
	return deep3($code);
}
function deep1(string $code) {
	return deep2($code);
}

$state = deep1($code);
check('the chain parked', $state === 'PARKED', $state);

// every resume from {main}, which is a different depth from the run
$trips = 0;
$answers = ['one', 'two', 'three'];
while ($state === 'PARKED' && $trips < 10) {
	$state = cfw_park_resume($answers[$trips] ?? 'extra');
	$trips++;
}

check('it parked once per trapped call', $trips === 3, "trips=$trips");
check('and finished', $state === 'DONE', $state);
check(
	'every host answer reached the call that asked for it',
	($GLOBALS['GOT'] ?? null) === ['one', 'two', 'three'],
	json_encode($GLOBALS['GOT'] ?? null),
);
check('nothing is left parked', cfw_park_pending() === null);
// the interpreter is still usable, which a walk into freed memory does not leave it
check('the host survives', array_sum(range(1, 10)) === 55);

printf("\n%d passed, %d failed\n", $pass, $fail);
exit($fail === 0 ? 0 : 1);

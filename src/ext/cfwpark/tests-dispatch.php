<?php

/**
 * A park under the dispatch a NAMESPACED caller reaches its callback through.
 *
 * `call_user_func_array` leaves no frame when the compiler resolved its name, and an unqualified
 * call inside a namespace is resolved at RUNTIME instead, so the frame is real. Every earlier
 * harness for this was written in the global namespace and could not reproduce it; this one puts the
 * dispatch in a file with a `namespace` declaration, which is the only place it can live.
 *
 *   php -n -d extension=modules/cfwpark.so tests-dispatch.php
 *
 * `-n` matters: Xdebug installs its own execute handler and inverts the whole measurement.
 */

$dir = sys_get_temp_dir() . '/cfwpark-dispatch';
@mkdir($dir);
$module = $dir . '/probe.php';
file_put_contents(
	$module,
	<<<'PHP'
	<?php

	namespace Probe;

	function leaf(string $tag)
	{
		$s = @stream_socket_client('tcp://' . $tag . '.invalid:1', $e, $m, 1);
		return 'leaf<' . (\is_string($s) ? $s : 'refused') . '>';
	}

	/** unqualified inside a namespace, which is what makes the trampoline frame real */
	function dispatch(string $tag)
	{
		return 'dispatch(' . call_user_func_array(__NAMESPACE__ . '\\leaf', [$tag]) . ')';
	}

	function outer(string $tag)
	{
		$mid = dispatch($tag);
		return 'outer[' . $mid . ']';
	}

	/** two trampolines between the park and the floor, to exercise the walk rather than one frame */
	function nested(string $tag)
	{
		return 'nested{' . call_user_func_array(__NAMESPACE__ . '\\outer', [$tag]) . '}';
	}

	/** two parks in ONE chain, both under the trampoline; the resume path is what this checks */
	function twice()
	{
		$a = dispatch('one');
		$b = dispatch('two');
		return 'twice(' . $a . '|' . $b . ')';
	}

	/** the result of the trampolined call is DISCARDED, which used to hand the resume dead C stack */
	function discarded()
	{
		$s = @stream_socket_client('tcp://drop.invalid:1', $e, $m, 1);
		return 'discarded';
	}

	function dropped()
	{
		return 'dropped(' . call_user_func_array(__NAMESPACE__ . '\\discarded', []) . ')';
	}

	function report()
	{
		return ['safe' => \cfw_park_safe(), 'frames' => \cfw_park_frames()];
	}

	function viaTrampoline()
	{
		return call_user_func_array(__NAMESPACE__ . '\\report', []);
	}

	function viaCuf()
	{
		return call_user_func(__NAMESPACE__ . '\\report');
	}

	/** the control: a frame that is genuinely not a trampoline has to stay refused */
	function viaArrayMap()
	{
		$r = \array_map(__NAMESPACE__ . '\\report', [1]);
		return $r[0];
	}

	/** a trampoline dispatching an INTERNAL function relinks nothing, so it must stay refused */
	function viaInternalCallee()
	{
		// silenced on the OUTER call: the refusal runs the real function, which warns twice
		return @call_user_func_array('stream_socket_client', ['tcp://direct.invalid:1']);
	}
	PHP
);

$pass = 0;
$fail = 0;

function check(string $what, $got, $want): void
{
	global $pass, $fail;
	if ($got === $want) {
		$pass++;
		return;
	}
	$fail++;
	echo "FAIL {$what}\n  want: ", var_export($want, true), "\n  got:  ", var_export($got, true), "\n";
}

/**
 * Runs one chain through the host loop and answers what it printed plus how many trips it took.
 *
 * The answer is the target the trapped call was given, so a wrong answer reaching a wrong caller is
 * visible in the output rather than merely as a count.
 */
function drive(string $code): array
{
	$trips = [];
	// a chain that fatals leaves the PREVIOUS chain's value behind, which reads as a pass
	unset($GLOBALS['OUT']);
	$state = cfw_park_run($code);
	while ($state === 'PARKED') {
		$pending = cfw_park_pending();
		$trips[] = $pending['fn'] . ':' . $pending['args'][0];
		$state = cfw_park_resume('ANS(' . $pending['args'][0] . ')');
	}
	return ['state' => $state, 'trips' => $trips, 'out' => $GLOBALS['OUT'] ?? null];
}

if (!function_exists('cfw_park_run')) {
	echo "ext/cfwpark is not loaded\n";
	exit(1);
}
if (!function_exists('cfw_park_frames')) {
	echo "this build predates cfw_park_frames(); nothing here can be measured\n";
	exit(1);
}
check('the trap takes', cfw_park_trap('stream_socket_client'), true);

$boot = "require_once '" . $module . "';";

// #region what the predicate reads

$seen = drive($boot . '$GLOBALS["OUT"] = \\Probe\\viaTrampoline();');
check('the trampoline chain does not park', $seen['state'], 'DONE');
check('a namespaced call_user_func_array is parkable', $seen['out']['safe'] ?? -1, 0);
check(
	'and it is reported as the one internal frame, spliceable',
	$seen['out']['frames'] ?? null,
	[['fn' => 'call_user_func_array', 'transparent' => true]]
);

$seen = drive('$GLOBALS["OUT"] = \\Probe\\viaCuf();');
check('call_user_func is the same shape', $seen['out']['safe'] ?? -1, 0);
check(
	'and names itself',
	$seen['out']['frames'][0]['fn'] ?? null,
	'call_user_func'
);

// THE CONTROL. Without this the three readings above could be a predicate that answers 0 for
// everything, which is the version of this that shipped and corrupted memory.
$seen = drive('$GLOBALS["OUT"] = \\Probe\\viaArrayMap();');
check('array_map is still refused', $seen['out']['safe'] ?? -1, 1);
check(
	'and is reported as not spliceable',
	$seen['out']['frames'] ?? null,
	[['fn' => 'array_map', 'transparent' => false]]
);

// #endregion

// #region what a park under one actually returns

$seen = drive($boot . '$GLOBALS["OUT"] = \\Probe\\outer("a");');
check('a park under a trampoline completes', $seen['state'], 'DONE');
check('and took one trip', $seen['trips'], ['stream_socket_client:tcp://a.invalid:1']);
// THE WHOLE ASSERTION: every layer above the trampoline ran its own post-processing, so the
// answer reached the call that asked rather than terminating the chain at the dispatch
check(
	'and every frame above the dispatch finished',
	$seen['out'],
	'outer[dispatch(leaf<ANS(tcp://a.invalid:1)>)]'
);

$seen = drive('$GLOBALS["OUT"] = \\Probe\\nested("b");');
check('two trampolines in one chain', $seen['state'], 'DONE');
check(
	'and both are spliced out',
	$seen['out'],
	'nested{outer[dispatch(leaf<ANS(tcp://b.invalid:1)>)]}'
);

$seen = drive('$GLOBALS["OUT"] = \\Probe\\twice();');
check('two parks in one chain', $seen['state'], 'DONE');
check('and each asked for its own target', $seen['trips'], [
	'stream_socket_client:tcp://one.invalid:1',
	'stream_socket_client:tcp://two.invalid:1',
]);
check(
	'and each answer reached its own caller',
	$seen['out'],
	'twice(dispatch(leaf<ANS(tcp://one.invalid:1)>)|dispatch(leaf<ANS(tcp://two.invalid:1)>))'
);

$seen = drive('$GLOBALS["OUT"] = \\Probe\\dropped();');
check('a discarded result parks and completes', $seen['state'], 'DONE');
check('and the chain still finishes', $seen['out'], 'dropped(discarded)');

// #endregion

// #region the refusal that has to survive

// `call_user_func_array('stream_socket_client', ...)` has no userland callee to relink, so the
// trampoline is NOT spliceable there and the park falls through to the real function
$seen = drive('$GLOBALS["OUT"] = \\Probe\\viaInternalCallee();');
check('a trampoline over an internal callee does not park', $seen['trips'], []);
check('and the real function answered instead', $seen['out'], false);

// #endregion

echo "\n{$pass} passed, {$fail} failed\n";
exit($fail === 0 ? 0 : 1);

#!/usr/bin/env bash
# Brackets php-wasm's pib_run so an exit() returns control the way a normal end does.
#
# WHY THE UNPATCHED BINARY WEDGES (php-src 8.5.12, read from source)
# exit() throws an UnwindExit object (ZEND_FUNCTION(exit) -> zend_throw_unwind_exit) that the VM
# unwinds through every frame. In a real request php_execute_script() clears it with
# zend_exception_error(), which is silent for an exit. pib_run skips that call for an exit
# (`!(zend_is_graceful_exit(...) || zend_is_unwind_exit(...))`), so the object stays in
# EG(exception) for the life of the instance, and a pending exception does two things:
#   - zend_execute() starts with `if (EG(exception) != NULL) return;`, so every later pib_run
#     compiles its code, runs none of it and still answers 0 with empty output
#   - zend_call_function() returns SUCCESS without calling anything while one is pending, so a
#     shutdown function or output callback could never run even if something invoked them
# Neither is a hang; it is state.
#
# WHAT THE PATCH DOES, and what it deliberately does not
# After zend_eval_string() it clears a pending exit with zend_exception_error(), runs and frees
# the registered shutdown functions, and finalises only the output buffers THIS run opened. It does
# not call php_request_shutdown(), zend_call_destructors() or php_output_end_all(): the instance is
# one long request (php_embed_init runs php_request_startup once), so destructors would mark every
# live object destructed and wreck the booted globals, and end_all would pop buffers the host opened.
#
# It also frees the registered shutdown functions at the start of every pib_run. One long request
# never reaches php_request_shutdown(), so a callback registered by a run that did not exit would
# wait for a later run's exit() and fire under that run's user and request. ext/cfwpark owns the one
# exception: a parked chain resumes in its own pib_run and its request's callbacks must survive, so
# the clear is skipped while cfw_park_held() answers 1. PIB_RUN_EXIT arms must carry cfwpark.
#
# The file is php-wasm's own source/pib/pib.c in the checkout, not php-src, so it is host-writable.
# The Makefile copies it into php-src (`ext/pib/pib.c: source/pib/pib.c`) when it is newer, which
# means the patch has to land BEFORE the first configure of a checkout; a tree already configured
# from the unpatched file is reconfigured by the copy, which costs a full configure.
#
# Idempotent and keyed on the patched shape, never on a marker comment.
#
# MODES
#   (none) / apply   patch the file; a second run is a no-op
#   --verify         exit 0 only if every inserted piece is present and the call sits after the eval
#   --revert         remove the patch, byte-identical to the original
#
# tools/test-patch-verify.sh drives all three modes over a synthetic pib.c.
set -euo pipefail

SRC="${1:-/tmp/phpwasm-build/php-wasm}"
MODE="${2:-apply}"
F="$SRC/source/pib/pib.c"

[ -f "$F" ] || {
	echo "no pib.c at $F"
	exit 1
}

if [ "$MODE" = "--verify" ]; then
	FAILED=0

	grep -qF 'static void pib_settle_exit(int output_level)' "$F" || {
		echo "VERIFY FAIL: no exit bracket in $F -- the patch never ran"
		FAILED=1
	}

	CALLS="$(grep -cF 'pib_settle_exit(output_level);' "$F" || true)"
	if [ "$CALLS" != "1" ]; then
		echo "VERIFY FAIL: expected 1 call site in pib_run, found $CALLS"
		FAILED=1
	fi

	LEVELS="$(grep -cF 'int output_level = php_output_get_level();' "$F" || true)"
	if [ "$LEVELS" != "1" ]; then
		echo "VERIFY FAIL: expected 1 output level snapshot before the eval, found $LEVELS"
		FAILED=1
	fi

	for call in 'zend_exception_error(EG(exception), E_ERROR);' \
		'php_call_shutdown_functions();' 'php_free_shutdown_functions();' 'php_output_end()'; do
		grep -qF "$call" "$F" || {
			echo "VERIFY FAIL: the bracket never calls $call"
			FAILED=1
		}
	done

	grep -qF '#include "ext/standard/basic_functions.h"' "$F" || {
		echo "VERIFY FAIL: basic_functions.h is not included, so the shutdown calls would not compile"
		FAILED=1
	}

	EVAL_LINE="$(grep -nF 'zend_eval_string(code, NULL, "php-wasm run script");' "$F" | head -1 | cut -d: -f1)"
	CALL_LINE="$(grep -nF 'pib_settle_exit(output_level);' "$F" | head -1 | cut -d: -f1)"
	SEND_LINE="$(grep -nF 'sapi_send_headers();' "$F" | head -1 | cut -d: -f1)"
	LEVEL_LINE="$(grep -nF 'int output_level = php_output_get_level();' "$F" | head -1 | cut -d: -f1)"
	CLEAR_LINE="$(grep -nF 'if(!cfw_park_held())' "$F" | head -1 | cut -d: -f1)"
	CLEARS="$(grep -cF 'if(!cfw_park_held())' "$F" || true)"
	if [ "$CLEARS" != "1" ]; then
		echo "VERIFY FAIL: expected 1 guarded shutdown clear in pib_run, found $CLEARS"
		FAILED=1
	fi
	if [ -z "$LEVEL_LINE" ] || [ -z "$CLEAR_LINE" ] || [ -z "$EVAL_LINE" ] \
		|| [ "$CLEAR_LINE" -le "$LEVEL_LINE" ] || [ "$CLEAR_LINE" -ge "$EVAL_LINE" ]; then
		echo "VERIFY FAIL: the clear must sit between the level snapshot (${LEVEL_LINE:-none}) and the eval (${EVAL_LINE:-none}); it is at ${CLEAR_LINE:-none}"
		FAILED=1
	fi
	grep -qF 'int cfw_park_held(void);' "$F" || {
		echo "VERIFY FAIL: cfw_park_held is not declared, so the guard would not compile"
		FAILED=1
	}
	if [ -z "$EVAL_LINE" ] || [ -z "$CALL_LINE" ] || [ -z "$SEND_LINE" ] \
		|| [ "$CALL_LINE" -le "$EVAL_LINE" ] || [ "$CALL_LINE" -ge "$SEND_LINE" ]; then
		echo "VERIFY FAIL: the call must sit between the eval (${EVAL_LINE:-none}) and the header send (${SEND_LINE:-none}); it is at ${CALL_LINE:-none}"
		FAILED=1
	fi

	if [ "$FAILED" != "0" ]; then
		exit 1
	fi
	echo "verified $F: exit bracket present, 1 call site after the eval, output level snapshot taken, shutdown clear guarded before the eval"
	exit 0
fi

if [ "$MODE" = "--revert" ]; then
	grep -qF 'static void pib_settle_exit(int output_level)' "$F" || {
		echo "not patched, nothing to revert: $F"
		exit 0
	}
elif grep -qF 'static void pib_settle_exit(int output_level)' "$F"; then
	# a file patched by an older revision of this script has the bracket and not the clear
	bash "$0" "$SRC" --verify || {
		echo "$F carries an older patch; use a fresh php-wasm checkout"
		exit 1
	}
	echo "already patched: $F"
	exit 0
fi

# one program for apply and revert so both read the same five insertions and cannot drift apart
python3 - "$F" "$MODE" << 'PY'
import sys

path, mode = sys.argv[1], sys.argv[2]
src = open(path).read()

INCLUDE_ANCHOR = '#include "ext/standard/info.h"\n'
INCLUDE_ADD = (
	'#include "ext/standard/basic_functions.h"\n'
	'\n'
	'/* ext/cfwpark answers whether a parked chain is waiting for its resume */\n'
	'int cfw_park_held(void);\n'
)

HELPER_ANCHOR = '/**\n * Run some PHP code and return the exit code.\n'
HELPER = '''/* #region drupflare pib_run exit bracket */
/* a pending exit makes zend_execute return at once and zend_call_function call nothing */
static void pib_settle_exit(int output_level)
{
	if(!EG(exception))
	{
		return;
	}

#if PHP_MAJOR_VERSION >= 8 && PHP_MINOR_VERSION >= 1
	if(!(zend_is_graceful_exit(EG(exception)) || zend_is_unwind_exit(EG(exception))))
#else
	if(!zend_is_unwind_exit(EG(exception)))
#endif
	{
		return;
	}

	/* silent for an exit: it clears EG(exception) and releases the object */
	zend_exception_error(EG(exception), E_ERROR);

	php_call_shutdown_functions();
	php_free_shutdown_functions();

	/* only the buffers this run opened; the request stays up for the next run */
	zend_try
	{
		while(php_output_get_level() > output_level && SUCCESS == php_output_end());
	}
	zend_end_try();
}
/* #endregion */

'''

LEVEL_ANCHOR = '\tint retVal = 255; // Unknown error.\n\n\tzend_try\n'
LEVEL_PATCHED = (
	'\tint retVal = 255; // Unknown error.\n'
	'\tint output_level = php_output_get_level();\n\n\tzend_try\n'
)

EVAL_ANCHOR = '\t\tretVal = zend_eval_string(code, NULL, "php-wasm run script");\n'
EVAL_PATCHED = EVAL_ANCHOR + '\n\t\tpib_settle_exit(output_level);\n'

CLEAR_ANCHOR = LEVEL_PATCHED
CLEAR_PATCHED = (
	'\tint retVal = 255; // Unknown error.\n'
	'\tint output_level = php_output_get_level();\n\n'
	'\t/* a request\'s callbacks die with it, except a parked chain\'s, which resumes in this run */\n'
	'\tif(!cfw_park_held())\n'
	'\t{\n'
	'\t\tphp_free_shutdown_functions();\n'
	'\t}\n\n'
	'\tzend_try\n'
)

# (original, patched) pairs; apply replaces the first with the second, revert the reverse
EDITS = [
	(INCLUDE_ANCHOR, INCLUDE_ANCHOR + INCLUDE_ADD),
	(HELPER_ANCHOR, HELPER + HELPER_ANCHOR),
	(LEVEL_ANCHOR, LEVEL_PATCHED),
	(EVAL_ANCHOR, EVAL_PATCHED),
	(CLEAR_ANCHOR, CLEAR_PATCHED),
]

# the clear edit builds on the level edit, so a revert has to undo them in the opposite order
for original, patched in (EDITS if mode != '--revert' else reversed(EDITS)):
	old, new = (original, patched) if mode != '--revert' else (patched, original)
	if src.count(old) != 1:
		shape = 'the patched shape' if mode == '--revert' else 'the expected shape'
		sys.stderr.write('anchor not in %s (found %d); refusing to edit:\n%s\n' % (shape, src.count(old), old))
		sys.exit(1)
	src = src.replace(old, new, 1)

open(path, 'w').write(src)
print('reverted %s' % path if mode == '--revert' else 'patched %s' % path)
PY

if [ "$MODE" != "--revert" ]; then
	bash "$0" "$SRC" --verify
fi

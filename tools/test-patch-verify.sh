#!/usr/bin/env bash
# Drives patch-vm-interrupt.sh through apply, --verify and --revert over a synthetic tree, then
# does the same for patch-pib-run.sh over a synthetic source/pib/pib.c.
#
# The real target is
# `third_party/php8.5-src/Zend/zend_execute.c`, which arrives from a `make patched` clone that
# needs Docker and a php-src checkout. What this script tests is not php-src: it is the
# script's own state machine -- does apply reach both poll macros, does --verify distinguish
# patched from unpatched from partially patched, does --revert leave no residue. All of that is
# a property of the text transformation, so a fixture carrying the two anchor macros exercises
# it exactly and runs in a second with no toolchain at all.
#
# What it does not prove: that the patched C compiles, or that the exports reach the binary.
# `inspect-build.sh --expect-slice-exports` is the check for that, and it needs a real build.
#
# Usage:
#   bash tools/test-patch-verify.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$HERE/src/patch-vm-interrupt.sh"
PASS=0
FAIL=0

ok() {
	if [ "$2" = "0" ]; then
		PASS=$((PASS + 1))
		echo "  ok   $1"
	else
		FAIL=$((FAIL + 1))
		echo "  FAIL $1"
	fi
}

# asserts a command exits with the code we expect, so a check that stops failing is caught
expect_exit() {
	local want="$1" label="$2"
	shift 2
	local got=0
	"$@" > /dev/null 2>&1 || got=$?
	if [ "$got" = "$want" ]; then
		ok "$label" 0
	else
		ok "$label (wanted exit $want, got $got)" 1
	fi
}

# the XXXXXX is required: GNU mktemp rejects a template without it, and this script had never run
# anywhere but macOS until the lint job started driving it
TREE="$(mktemp -d -t phasmpatch.XXXXXX)"
trap 'rm -rf "$TREE"' EXIT
SRCDIR="$TREE/third_party/php8.5-src/Zend"
mkdir -p "$SRCDIR"
FIXTURE="$SRCDIR/zend_execute.c"

# apply and revert write through the builder container; this stands in for `docker compose run`
# and logs each path it was asked to write, so a write that bypasses the container is caught
DOCKER_LOG="$TREE/docker-writes"
mkdir -p "$TREE/bin"
cat > "$TREE/bin/docker" << 'EOF'
#!/usr/bin/env bash
rel="${*: -1}"
rel="${rel#cat > /src/}"
echo "$rel" >> "$DOCKER_LOG"
cat > "$rel"
EOF
chmod +x "$TREE/bin/docker"
export PATH="$TREE/bin:$PATH" DOCKER_LOG

# the two anchor macros in the exact shape the script refuses to patch without. Taken from the
# shape the script itself asserts, so a change to php-src that breaks the real patch also
# breaks this fixture rather than letting it pass on a stale assumption
write_fixture() {
	cat > "$FIXTURE" << 'EOF'
/* a stand-in for Zend/zend_execute.c, carrying only the two poll macros */

#define ZEND_VM_INTERRUPT_CHECK() do { \
		if (UNEXPECTED(zend_atomic_bool_load_ex(&EG(vm_interrupt)))) { \
			ZEND_VM_DISPATCH_TO_HELPER(zend_interrupt_helper); \
		} \
	} while (0)

#define ZEND_VM_LOOP_INTERRUPT_CHECK() do { \
		if (UNEXPECTED(zend_atomic_bool_load_ex(&EG(vm_interrupt)))) { \
			zend_interrupt_function(execute_data); \
		} \
	} while (0)
EOF
}

echo "patch-vm-interrupt.sh: apply / --verify / --revert"

# #region an unpatched tree
write_fixture
BEFORE="$(md5 -q "$FIXTURE" 2> /dev/null || md5sum "$FIXTURE" | cut -d' ' -f1)"
expect_exit 1 "--verify refuses an unpatched tree" \
	bash "$SCRIPT" "$TREE" --verify
expect_exit 0 "--revert on an unpatched tree is a no-op, not an error" \
	bash "$SCRIPT" "$TREE" --revert
AFTER_NOOP="$(md5 -q "$FIXTURE" 2> /dev/null || md5sum "$FIXTURE" | cut -d' ' -f1)"
ok "the no-op revert changed nothing" "$([ "$BEFORE" = "$AFTER_NOOP" ] && echo 0 || echo 1)"
# #endregion

# #region apply, then verify
expect_exit 0 "apply patches the tree" bash "$SCRIPT" "$TREE"
expect_exit 0 "--verify accepts the patched tree" bash "$SCRIPT" "$TREE" --verify
ok "apply wrote zend_execute.c through the builder container" \
	"$(grep -q 'Zend/zend_execute.c' "$DOCKER_LOG" && echo 0 || echo 1)"
ok "the JSPI yield has a stub for builds without it" \
	"$(grep -q '^static int cfw_vm_yield' "$FIXTURE" && echo 0 || echo 1)"

# the doubled backslash is a BRE matching one literal backslash, which is how the C macro
# continues its line; it is not a botched quote escape
# shellcheck disable=SC1003
TICKS="$(grep -c 'ZEND_WASM_POLL(execute_data, opline); \\' "$FIXTURE" || true)"
ok "the tick reached both poll macros, not one ($TICKS)" \
	"$([ "$TICKS" = "2" ] && echo 0 || echo 1)"
ok "the signal word is declared" \
	"$(grep -qF 'ZEND_API volatile uint32_t __instance_signal' "$FIXTURE" && echo 0 || echo 1)"
ok "the poll expansion tests the signal word and the tick" \
	"$(grep -qF 'if (UNEXPECTED(__instance_signal | zend_wasm_tick_due())) zend_wasm_poll_slow(ed, op)' "$FIXTURE" && echo 0 || echo 1)"
ok "the poll handler takes a writable frame and hands parks to cfwpark" \
	"$(grep -qF 'static zend_never_inline void zend_wasm_poll_slow(zend_execute_data *ed, const zend_op *op)' "$FIXTURE" && grep -qF 'cfw_park_prepare(ed, op, reason)' "$FIXTURE" && grep -qF 'cfw_park_jump();' "$FIXTURE" && echo 0 || echo 1)"
for symbol in zend_wasm_slice_arm zend_wasm_slice_mask zend_wasm_slice_stat; do
	ok "$symbol is exported" \
		"$(grep -q "EMSCRIPTEN_KEEPALIVE.*$symbol" "$FIXTURE" && echo 0 || echo 1)"
done

expect_exit 0 "a second apply is a no-op" bash "$SCRIPT" "$TREE"
# the doubled backslash is a BRE matching one literal backslash, which is how the C macro
# continues its line; it is not a botched quote escape
# shellcheck disable=SC1003
TICKS_AGAIN="$(grep -c 'ZEND_WASM_POLL(execute_data, opline); \\' "$FIXTURE" || true)"
ok "the second apply did not double the tick ($TICKS_AGAIN)" \
	"$([ "$TICKS_AGAIN" = "2" ] && echo 0 || echo 1)"
# #endregion

# #region a PARTIALLY patched tree, which is the case a marker comment would miss
# the block is present and the tick is gone. This compiles cleanly and does nothing, so it is
# the failure --verify exists for rather than an invented edge case
perl -0pi -e 's{\t\tZEND_WASM_POLL\(execute_data, opline\); \\\n}{}g' "$FIXTURE"
expect_exit 1 "--verify catches a block whose tick never reached the poll macros" \
	bash "$SCRIPT" "$TREE" --verify
# and it says which shape is wrong rather than only that something is.
# captured first rather than piped: `set -o pipefail` is on, and --verify exits 1 by design here,
# so a pipeline would report the expected failure as a test failure
PARTIAL_OUT="$(bash "$SCRIPT" "$TREE" --verify 2>&1 || true)"
case "$PARTIAL_OUT" in
	*'found 0'*) ok "the refusal names the count it found" 0 ;;
	*) ok "the refusal names the count it found (said: $PARTIAL_OUT)" 1 ;;
esac
# #endregion

# #region a block without its signal word
write_fixture
bash "$SCRIPT" "$TREE" > /dev/null
perl -0pi -e 's{ZEND_API volatile uint32_t __instance_signal __attribute__\(\(aligned\(4\)\)\) = 0;\n}{}' "$FIXTURE"
expect_exit 1 "--verify catches a block with no signal word" bash "$SCRIPT" "$TREE" --verify
# #endregion

# #region a moved poll macro is refused before anything is written
# a line between the loop macro's head and its body. Before the per-macro count, apply put the tick
# at one site and went on; now it must refuse and leave the file and the container write alone
write_fixture
perl -0pi -e 's{(#define ZEND_VM_LOOP_INTERRUPT_CHECK\(\) do \{ \\\n)}{$1\t\t/* moved */ \\\n}' "$FIXTURE"
DRIFTED="$(md5 -q "$FIXTURE" 2> /dev/null || md5sum "$FIXTURE" | cut -d' ' -f1)"
: > "$DOCKER_LOG"
expect_exit 1 "apply refuses when the loop poll macro moved" bash "$SCRIPT" "$TREE"
ok "the refused apply left the file untouched" \
	"$([ "$DRIFTED" = "$(md5 -q "$FIXTURE" 2> /dev/null || md5sum "$FIXTURE" | cut -d' ' -f1)" ] && echo 0 || echo 1)"
ok "the refused apply wrote nothing through the container" "$([ -s "$DOCKER_LOG" ] && echo 1 || echo 0)"
# #endregion

# #region revert leaves no residue
write_fixture
bash "$SCRIPT" "$TREE" > /dev/null
expect_exit 0 "--revert unpatches a patched tree" bash "$SCRIPT" "$TREE" --revert
ok "no zend_wasm_tick residue is left" \
	"$(grep -q 'zend_wasm_tick' "$FIXTURE" && echo 1 || echo 0)"
ok "no ZEND_WASM_POLL call site is left" \
	"$(grep -q 'ZEND_WASM_POLL' "$FIXTURE" && echo 1 || echo 0)"
ok "no __instance_signal residue is left" \
	"$(grep -q '__instance_signal' "$FIXTURE" && echo 1 || echo 0)"
AFTER_REVERT="$(md5 -q "$FIXTURE" 2> /dev/null || md5sum "$FIXTURE" | cut -d' ' -f1)"
# byte-identical, which is what makes the unpatched control build a real A/B
ok "the reverted file is byte-identical to the original" \
	"$([ "$BEFORE" = "$AFTER_REVERT" ] && echo 0 || echo 1)"
expect_exit 1 "--verify refuses the reverted tree again" bash "$SCRIPT" "$TREE" --verify
# #endregion

# #region a missing tree is named, not silently skipped
expect_exit 1 "a missing zend_execute.c is refused" \
	bash "$SCRIPT" "$TREE/nowhere" --verify
# #endregion

# #region patch-pib-run.sh
# the real target is php-wasm's source/pib/pib.c. The fixture keeps the four anchors in the shape of
# the file at the pinned php-wasm commit: the info.h include, the doc comment of pib_run, its
# retVal line and the eval line, plus a pib_exec with its own zend_try so a loose pattern would
# match the wrong function
PIB_SCRIPT="$HERE/src/patch-pib-run.sh"
PIB_TREE="$TREE/pibwasm"
PIB_DIR="$PIB_TREE/source/pib"
mkdir -p "$PIB_DIR"
PIB_FIXTURE="$PIB_DIR/pib.c"

write_pib_fixture() {
	cat > "$PIB_FIXTURE" << 'EOF'
#include "php.h"
#include "pib.h"
#include "php_ini.h"
#include "ext/standard/info.h"

char *EMSCRIPTEN_KEEPALIVE pib_exec(char *code)
{
	char *retVal = NULL;

	zend_try
	{
		zend_eval_string(code, &retZv, "php-wasm exec expression");
	}
	zend_catch
	{
	}
	zend_end_try();

	return retVal;
}

/**
 * Run some PHP code and return the exit code.
 * 0 = good, >0 = bad.
*/
int EMSCRIPTEN_KEEPALIVE pib_run(char *code)
{
	int retVal = 255; // Unknown error.

	zend_try
	{
		SG(headers_sent) = 0;

		retVal = zend_eval_string(code, NULL, "php-wasm run script");

		if(!SG(headers_sent))
		{
			sapi_send_headers();
			SG(headers_sent) = 1;
		}
	}
	zend_catch
	{
		retVal = 1; // Code died.
	}
	zend_end_try();

	pib_flush();

	return retVal;
}
EOF
}

sum_of() {
	md5 -q "$1" 2> /dev/null || md5sum "$1" | cut -d' ' -f1
}

echo
echo "patch-pib-run.sh: apply / --verify / --revert"

write_pib_fixture
PIB_BEFORE="$(sum_of "$PIB_FIXTURE")"
expect_exit 1 "pib: --verify refuses an unpatched file" bash "$PIB_SCRIPT" "$PIB_TREE" --verify
expect_exit 0 "pib: --revert on an unpatched file is a no-op, not an error" \
	bash "$PIB_SCRIPT" "$PIB_TREE" --revert
ok "pib: the no-op revert changed nothing" \
	"$([ "$PIB_BEFORE" = "$(sum_of "$PIB_FIXTURE")" ] && echo 0 || echo 1)"

expect_exit 0 "pib: apply patches the file" bash "$PIB_SCRIPT" "$PIB_TREE"
expect_exit 0 "pib: --verify accepts the patched file" bash "$PIB_SCRIPT" "$PIB_TREE" --verify
ok "pib: the helper is defined once" \
	"$([ "$(grep -cF 'static void pib_settle_exit(int output_level)' "$PIB_FIXTURE")" = "1" ] && echo 0 || echo 1)"
ok "pib: the call sits in pib_run after the eval" \
	"$([ "$(grep -nF 'pib_settle_exit(output_level);' "$PIB_FIXTURE" | cut -d: -f1)" -gt "$(grep -nF 'php-wasm run script' "$PIB_FIXTURE" | cut -d: -f1)" ] && echo 0 || echo 1)"
ok "pib: pib_exec was not touched" \
	"$([ "$(grep -cF 'pib_settle_exit(output_level);' "$PIB_FIXTURE")" = "1" ] && echo 0 || echo 1)"
ok "pib: basic_functions.h is included" \
	"$(grep -qF '#include "ext/standard/basic_functions.h"' "$PIB_FIXTURE" && echo 0 || echo 1)"
ok "pib: the shutdown clear sits between the level snapshot and the eval" \
	"$(awk '/int output_level = php_output_get_level/ {l=NR} /if\(!cfw_park_held\(\)\)/ {c=NR} /php-wasm run script/ {e=NR} END {exit !(l < c && c < e)}' "$PIB_FIXTURE" && echo 0 || echo 1)"
ok "pib: the clear is skipped through cfw_park_held, which is declared" \
	"$(grep -qF 'int cfw_park_held(void);' "$PIB_FIXTURE" && echo 0 || echo 1)"
ok "pib: pib_exec has no clear" \
	"$([ "$(grep -cF 'if(!cfw_park_held())' "$PIB_FIXTURE")" = "1" ] && echo 0 || echo 1)"
PIB_PATCHED="$(sum_of "$PIB_FIXTURE")"
expect_exit 0 "pib: a second apply is a no-op" bash "$PIB_SCRIPT" "$PIB_TREE"
ok "pib: the second apply changed nothing" \
	"$([ "$PIB_PATCHED" = "$(sum_of "$PIB_FIXTURE")" ] && echo 0 || echo 1)"

# the block is present and the call site is gone: it compiles and never settles an exit, which is
# the shape a marker comment would accept
perl -0pi -e 's{\n\t\tpib_settle_exit\(output_level\);\n}{}' "$PIB_FIXTURE"
expect_exit 1 "pib: --verify catches a helper nothing calls" bash "$PIB_SCRIPT" "$PIB_TREE" --verify
PIB_PARTIAL="$(bash "$PIB_SCRIPT" "$PIB_TREE" --verify 2>&1 || true)"
case "$PIB_PARTIAL" in
	*'found 0'*) ok "pib: the refusal names the call count it found" 0 ;;
	*) ok "pib: the refusal names the call count it found (said: $PIB_PARTIAL)" 1 ;;
esac

write_pib_fixture
bash "$PIB_SCRIPT" "$PIB_TREE" > /dev/null
perl -0pi -e 's{\tif\(!cfw_park_held\(\)\)\n\t\{\n\t\tphp_free_shutdown_functions\(\);\n\t\}\n\n}{}' "$PIB_FIXTURE"
expect_exit 1 "pib: --verify catches a pib_run that never clears shutdown functions" \
	bash "$PIB_SCRIPT" "$PIB_TREE" --verify
expect_exit 1 "pib: apply refuses a file an older patch left without the clear" \
	bash "$PIB_SCRIPT" "$PIB_TREE"

write_pib_fixture
bash "$PIB_SCRIPT" "$PIB_TREE" > /dev/null
perl -0pi -e 's{#include "ext/standard/basic_functions.h"\n}{}' "$PIB_FIXTURE"
expect_exit 1 "pib: --verify catches a missing include" bash "$PIB_SCRIPT" "$PIB_TREE" --verify

write_pib_fixture
bash "$PIB_SCRIPT" "$PIB_TREE" > /dev/null
expect_exit 0 "pib: --revert unpatches a patched file" bash "$PIB_SCRIPT" "$PIB_TREE" --revert
ok "pib: no pib_settle_exit residue is left" \
	"$(grep -q 'pib_settle_exit' "$PIB_FIXTURE" && echo 1 || echo 0)"
ok "pib: no output_level residue is left" \
	"$(grep -q 'output_level' "$PIB_FIXTURE" && echo 1 || echo 0)"
ok "pib: the reverted file is byte-identical to the original" \
	"$([ "$PIB_BEFORE" = "$(sum_of "$PIB_FIXTURE")" ] && echo 0 || echo 1)"
expect_exit 1 "pib: --verify refuses the reverted file again" bash "$PIB_SCRIPT" "$PIB_TREE" --verify

# the eval line changed upstream: apply must refuse and leave the file exactly as it found it, not
# half edited
perl -pi -e 's{zend_eval_string\(code, NULL, "php-wasm run script"\)}{zend_eval_string_ex(code)}' "$PIB_FIXTURE"
PIB_DRIFTED="$(sum_of "$PIB_FIXTURE")"
expect_exit 1 "pib: apply refuses when the eval anchor drifts" bash "$PIB_SCRIPT" "$PIB_TREE"
ok "pib: the refused apply left the file untouched" \
	"$([ "$PIB_DRIFTED" = "$(sum_of "$PIB_FIXTURE")" ] && echo 0 || echo 1)"
expect_exit 1 "pib: --verify refuses the drifted file" bash "$PIB_SCRIPT" "$PIB_TREE" --verify

expect_exit 1 "pib: a missing pib.c is refused" bash "$PIB_SCRIPT" "$PIB_TREE/nowhere" --verify
# #endregion

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ]

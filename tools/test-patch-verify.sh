#!/usr/bin/env bash
# Drives patch-vm-interrupt.sh through apply, --verify and --revert over a synthetic tree.
#
# The real target is
# `third_party/php8.3-src/Zend/zend_execute.c`, which arrives from a `make patched` clone that
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
SRCDIR="$TREE/third_party/php8.3-src/Zend"
mkdir -p "$SRCDIR"
FIXTURE="$SRCDIR/zend_execute.c"

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

# the doubled backslash is a BRE matching one literal backslash, which is how the C macro
# continues its line; it is not a botched quote escape
# shellcheck disable=SC1003
TICKS="$(grep -c 'ZEND_WASM_TICK(); \\' "$FIXTURE" || true)"
ok "the tick reached both poll macros, not one ($TICKS)" \
	"$([ "$TICKS" = "2" ] && echo 0 || echo 1)"
for symbol in zend_wasm_slice_arm zend_wasm_slice_mask zend_wasm_slice_stat; do
	ok "$symbol is exported" \
		"$(grep -q "EMSCRIPTEN_KEEPALIVE.*$symbol" "$FIXTURE" && echo 0 || echo 1)"
done

expect_exit 0 "a second apply is a no-op" bash "$SCRIPT" "$TREE"
# the doubled backslash is a BRE matching one literal backslash, which is how the C macro
# continues its line; it is not a botched quote escape
# shellcheck disable=SC1003
TICKS_AGAIN="$(grep -c 'ZEND_WASM_TICK(); \\' "$FIXTURE" || true)"
ok "the second apply did not double the tick ($TICKS_AGAIN)" \
	"$([ "$TICKS_AGAIN" = "2" ] && echo 0 || echo 1)"
# #endregion

# #region a PARTIALLY patched tree, which is the case a marker comment would miss
# the block is present and the tick is gone. This compiles cleanly and does nothing, so it is
# the failure --verify exists for rather than an invented edge case
perl -0pi -e 's{\t\tZEND_WASM_TICK\(\); \\\n}{}g' "$FIXTURE"
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

# #region revert leaves no residue
write_fixture
bash "$SCRIPT" "$TREE" > /dev/null
expect_exit 0 "--revert unpatches a patched tree" bash "$SCRIPT" "$TREE" --revert
ok "no zend_wasm_tick residue is left" \
	"$(grep -q 'zend_wasm_tick' "$FIXTURE" && echo 1 || echo 0)"
ok "no ZEND_WASM_TICK call site is left" \
	"$(grep -q 'ZEND_WASM_TICK' "$FIXTURE" && echo 1 || echo 0)"
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

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ]

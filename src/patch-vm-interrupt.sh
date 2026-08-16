#!/usr/bin/env bash
# Adds a wasm tick to PHP's VM interrupt mechanism.
#
# WHY THIS WORKS AT ALL
# PHP already has every piece except the thing that fires: EG(vm_interrupt) is
# an atomic bool the VM polls, zend_interrupt_function is the callback the VM
# runs when it is set, and Zend/zend_execute.c defines the poll macros
# ZEND_VM_INTERRUPT_CHECK / ZEND_VM_LOOP_INTERRUPT_CHECK. Natively the flag is
# raised by SIGALRM/SIGPROF; wasm has no signals, so nothing ever raises it and
# the whole mechanism is dead code. This patch raises it from a countdown.
#
# WHERE THE POLL SITES ARE, measured in this tree, ZEND_VM_KIND_CALL with no
# global registers (wasm32 never gets HAVE_GCC_GLOBAL_REGS):
#   Zend/zend_execute.c:5342   ZEND_VM_SET_OPCODE() -- EVERY branch/jump handler,
#                              which is what makes loop back-edges poll
#   Zend/zend_vm_execute.h     ZEND_VM_LOOP_INTERRUPT_CHECK() at execute_ex entry
#                              and after any handler that returns ret>0 (VM_ENTER,
#                              i.e. entering a userland call frame)
# ZEND_VM_ENTER_EX() is `return 1` in this configuration, so its own
# INTERRUPT_CHECK never compiles in; the two above are the live ones.
#
# The patch goes in Zend/zend_execute.c, NOT in the generated
# Zend/zend_vm_execute.h: the macros live in the hand-written file and the
# generated header is #included at its bottom, so one file covers every poll site
# and a `php zend_vm_gen.php` regeneration cannot wipe it.
#
# HOT PATH COST: one global load, one decrement, one store, one branch per poll
# site. zend_wasm_tick_fired() is zend_never_inline so nothing else lands inline.
#
# SAFETY, both rules are enforced in C rather than trusted to the host:
#   - the handler masks itself for the duration of its own yield, so a suspension
#     can never begin inside a suspension
#   - zend_wasm_slice_mask(1)/(0) is exported so the host brackets its SQL bridge
#     call and any transaction replay; a fire during a mask sets no flag at all
#     rather than deferring one
#
# Idempotent: keyed on the patched shape, never on a marker comment. (A `dnl`- or
# `/* */`-style marker inside a macro argument is what broke the opcache config.m4
# patch twice; see src/build-static.sh.)
#
# MODES
#   (none) / apply   patch the tree; a second run is a no-op
#   --verify         exit 0 only if the tree is patched AND the tick reached both poll macros
#   --revert         remove the patch, so the same tree can build the unpatched control
#
# --verify is what makes a skipped patch loud. Run it after apply and before the build;
# tools/test-patch-verify.sh drives all three modes over a synthetic tree.
set -euo pipefail

SRC="${1:-/tmp/phpwasm-build/php-wasm}"
PHP_VERSION="${PHP_VERSION:-8.3}"
F="$SRC/third_party/php${PHP_VERSION}-src/Zend/zend_execute.c"
MODE="${2:-apply}"

[ -f "$F" ] || {
	echo "no zend_execute.c at $F"
	exit 1
}

# --verify answers "is this tree patched, and correctly?" without reading the file by hand.
#
# WHY IT IS NEEDED SEPARATELY FROM THE APPLY CHECK. An apply run on an already-patched tree
# prints "already patched" and exits 0, which is indistinguishable from a fresh successful
# patch -- and neither says anything to a LATER step. The consequence is specific rather than
# vague: an unpatched tree still builds and still boots, so a build that silently skipped this
# step produces a variant with no tick counter, which then reads as a platform limit ("this
# binary cannot be interrupted") rather than as a missing build step.
#
# Three shapes are checked, not one, because a partial patch is the case a marker comment would
# miss: the block can be present while the tick never reached the poll macros, which compiles
# cleanly and does nothing.
if [ "$MODE" = "--verify" ]; then
	FAILED=0

	grep -q 'zend_wasm_tick_countdown' "$F" || {
		echo "VERIFY FAIL: no tick block in $F -- the patch never ran"
		FAILED=1
	}

	# the doubled backslash is a BRE matching one literal backslash, which is how the C macro
	# continues its line; it is not a botched quote escape
	# shellcheck disable=SC1003
	TICKS="$(grep -c 'ZEND_WASM_TICK(); \\' "$F" || true)"
	# exactly two: ZEND_VM_INTERRUPT_CHECK and ZEND_VM_LOOP_INTERRUPT_CHECK. The `# define`
	# lines spell it `ZEND_WASM_TICK() do {` with no semicolon, so they do not count themselves
	if [ "$TICKS" != "2" ]; then
		echo "VERIFY FAIL: expected 2 tick call sites in the poll macros, found $TICKS"
		FAILED=1
	fi

	for symbol in zend_wasm_slice_arm zend_wasm_slice_mask zend_wasm_slice_stat; do
		grep -q "EMSCRIPTEN_KEEPALIVE.*$symbol" "$F" || {
			echo "VERIFY FAIL: $symbol is not exported; the host mask would have nothing to drive"
			FAILED=1
		}
	done

	if [ "$FAILED" != "0" ]; then
		exit 1
	fi
	echo "verified $F: tick block present, $TICKS poll sites, 3 slice exports"
	exit 0
fi

# --revert exists so the SAME tree can build the unpatched control: an interrupt
# overhead number is only meaningful against a binary that differs by this patch
# and nothing else, and reverting in place keeps every other object identical.
if [ "$MODE" = "--revert" ]; then
	grep -q 'zend_wasm_tick_countdown' "$F" || {
		echo "not patched, nothing to revert: $F"
		exit 0
	}
	python3 - "$F" << 'PY'
import sys
path = sys.argv[1]
src = open(path).read()
start = src.index('/* #region drupflare wasm slice interrupts */')
end = src.index('/* #endregion */', start) + len('/* #endregion */')
# consume exactly the newlines the apply step added, never the next line's first byte
while end < len(src) and src[end] == '\n':
	end += 1
src = src[:start] + src[end:]
src = src.replace('\t\tZEND_WASM_TICK(); \\\n', '')
assert 'zend_wasm_tick' not in src, 'revert left residue'
open(path, 'w').write(src)
PY
	echo "reverted $F"
	exit 0
fi

if grep -q 'zend_wasm_tick_countdown' "$F"; then
	echo "already patched: $F"
	exit 0
fi

grep -q '^#define ZEND_VM_INTERRUPT_CHECK() do { \\$' "$F" \
	|| {
		echo "ZEND_VM_INTERRUPT_CHECK not in the expected shape; refusing to patch"
		exit 1
	}

BLOCK="$(
	cat << 'EOF'
/* #region drupflare wasm slice interrupts */
#ifdef __EMSCRIPTEN__
#include <stdint.h>
#include <emscripten/emscripten.h>
#include <emscripten/em_js.h>

/* the suspending import; with -sJSPI the glue wraps this in
   WebAssembly.Suspending (library_async.js:58) because EM_ASYNC_JS names it
   __asyncjs__cfw_vm_yield. returns 0 to continue, nonzero to abort. */
EM_ASYNC_JS(int, cfw_vm_yield, (int seq), {
	var f = (typeof Module !== "undefined" && Module["cfwVmYield"]) || globalThis["cfwVmYield"];
	if (!f) { return 0; }
	var r = await f(seq);
	return r | 0;
});

ZEND_API int32_t zend_wasm_tick_countdown = INT32_MAX;
ZEND_API int32_t zend_wasm_tick_period = 0;
ZEND_API int32_t zend_wasm_tick_mask = 0;
ZEND_API int32_t zend_wasm_tick_yield_mode = 0;
ZEND_API uint32_t zend_wasm_tick_fires = 0;
ZEND_API uint32_t zend_wasm_tick_yields = 0;
ZEND_API uint32_t zend_wasm_tick_aborts = 0;
static void (*zend_wasm_prev_interrupt)(zend_execute_data *) = NULL;

/* never inlined: the poll sites must stay dec-and-branch */
static zend_never_inline void zend_wasm_tick_fired(void)
{
	zend_wasm_tick_fires++;
	if (zend_wasm_tick_period > 0) {
		zend_wasm_tick_countdown = zend_wasm_tick_period;
		if (zend_wasm_tick_mask == 0) {
			zend_atomic_bool_store_ex(&EG(vm_interrupt), true);
		}
	} else {
		zend_wasm_tick_countdown = INT32_MAX;
	}
}

static void zend_wasm_interrupt_handler(zend_execute_data *execute_data)
{
	int rc;

	if (zend_wasm_prev_interrupt) {
		zend_wasm_prev_interrupt(execute_data);
	}
	if (zend_wasm_tick_mask || zend_wasm_tick_period <= 0) {
		return;
	}
	zend_wasm_tick_yields++;
	if (!zend_wasm_tick_yield_mode) {
		return;
	}
	/* masked for the whole yield: no suspension inside a suspension */
	zend_wasm_tick_mask++;
	rc = cfw_vm_yield((int)zend_wasm_tick_yields);
	zend_wasm_tick_mask--;
	if (rc) {
		zend_wasm_tick_aborts++;
		zend_wasm_tick_period = 0;
		zend_wasm_tick_countdown = INT32_MAX;
		zend_throw_error(NULL, "drupflare: execution aborted by host after %u yields", zend_wasm_tick_yields);
	}
}

/* period = poll sites between interrupts, 0 disarms.
   yield_mode 0 counts only (measures the mechanism), 1 suspends via JSPI. */
EMSCRIPTEN_KEEPALIVE int zend_wasm_slice_arm(int period, int yield_mode)
{
	if (period > 0) {
		if (zend_interrupt_function != zend_wasm_interrupt_handler) {
			zend_wasm_prev_interrupt = zend_interrupt_function;
			zend_interrupt_function = zend_wasm_interrupt_handler;
		}
		zend_wasm_tick_yield_mode = yield_mode;
		zend_wasm_tick_period = period;
		zend_wasm_tick_countdown = period;
	} else {
		zend_wasm_tick_period = 0;
		zend_wasm_tick_countdown = INT32_MAX;
	}
	return zend_wasm_tick_period;
}

/* the host MUST bracket its SQL bridge call and any transaction replay */
EMSCRIPTEN_KEEPALIVE int zend_wasm_slice_mask(int on)
{
	if (on) {
		zend_wasm_tick_mask++;
	} else if (zend_wasm_tick_mask > 0) {
		zend_wasm_tick_mask--;
	}
	return zend_wasm_tick_mask;
}

EMSCRIPTEN_KEEPALIVE uint32_t zend_wasm_slice_stat(int which)
{
	switch (which) {
		case 0:  return zend_wasm_tick_fires;
		case 1:  return zend_wasm_tick_yields;
		case 2:  return zend_wasm_tick_aborts;
		case 3:  return (uint32_t)zend_wasm_tick_period;
		case 4:  return (uint32_t)zend_wasm_tick_mask;
		case 5:  return (uint32_t)zend_wasm_tick_yield_mode;
		case 6:  return (uint32_t)zend_wasm_tick_countdown;
		default: return 0;
	}
}

# define ZEND_WASM_TICK() do { \
		if (UNEXPECTED(--zend_wasm_tick_countdown <= 0)) { \
			zend_wasm_tick_fired(); \
		} \
	} while (0)
#else
# define ZEND_WASM_TICK() do { } while (0)
#endif
/* #endregion */

EOF
)"

BLOCK_FILE="$(mktemp -t vmint)"
printf '%s\n' "$BLOCK" > "$BLOCK_FILE"
trap 'rm -f "$BLOCK_FILE"' EXIT

python3 - "$F" "$BLOCK_FILE" << 'PY'
import sys
path, block_file = sys.argv[1], sys.argv[2]
src = open(path).read()
block = open(block_file).read()
anchor = "#define ZEND_VM_INTERRUPT_CHECK() do { \\\n"
assert anchor in src, "anchor missing"
src = src.replace(anchor, block + anchor, 1)
# add the tick to both poll macros
src = src.replace(
	"#define ZEND_VM_INTERRUPT_CHECK() do { \\\n\t\tif (UNEXPECTED(zend_atomic_bool_load_ex(&EG(vm_interrupt)))) { \\",
	"#define ZEND_VM_INTERRUPT_CHECK() do { \\\n\t\tZEND_WASM_TICK(); \\\n\t\tif (UNEXPECTED(zend_atomic_bool_load_ex(&EG(vm_interrupt)))) { \\",
	1)
src = src.replace(
	"#define ZEND_VM_LOOP_INTERRUPT_CHECK() do { \\\n\t\tif (UNEXPECTED(zend_atomic_bool_load_ex(&EG(vm_interrupt)))) { \\",
	"#define ZEND_VM_LOOP_INTERRUPT_CHECK() do { \\\n\t\tZEND_WASM_TICK(); \\\n\t\tif (UNEXPECTED(zend_atomic_bool_load_ex(&EG(vm_interrupt)))) { \\",
	1)
open(path, 'w').write(src)
PY

# the doubled backslash is a BRE matching one literal backslash, which is how the C
# macro continues its line; it is not a botched quote escape
# shellcheck disable=SC1003
grep -q 'ZEND_WASM_TICK(); \\' "$F" || {
	echo "tick did not reach the poll macros"
	exit 1
}
echo "patched $F"
grep -c 'ZEND_WASM_TICK();' "$F"

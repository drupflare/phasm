#!/usr/bin/env bash
# Drops ext/opcache from a PHP 8.5 source tree.
#
# WHY THIS NEEDS A PATCH AT ALL
# PHP 8.5 made OPcache mandatory: ext/opcache/config.m4 declares
# PHP_ARG_ENABLE for huge-code-pages and opcache-jit but NOT for opcache
# itself, so PHP_NEW_EXTENSION([opcache], ...) is unconditional and no
# configure flag can switch it off. Contrast ext/pdo, which still declares
# PHP_ARG_ENABLE([pdo]), which is why nopdo85.rc gets away with appending
# --disable-pdo.
#
# WHY IT IS THE LARGEST UNCOUNTED TERM
# No binary in vendor/ has ever contained opcache: Zend OPcache, accel_startup
# and zend_accel_ are 0 occurrences across static-o2, static-jspisjlj,
# static-o3mbsjlj and static-opcache itself, confirmed including a live probe
# returning zendExtensions: []. So the whole tree -- ZendAccelerator plus the
# ~20 translation units of SSA analysis under Optimizer/ -- is new mass on the
# 8.5 line and 100% delta rather than a difference.
#
# WHY NO SYMBOL STUB IS NEEDED, measured rather than assumed
# Everything under Zend/ and main/ that names an opcache symbol reduces to two,
# and neither survives as a link dependency on this build:
#   zend_accel_schedule_restart_hook -- Zend DEFINES it, Zend/zend.c:97, as
#     `= NULL`. opcache only assigns it, so removing opcache leaves a null hook.
#   zend_accel_globals -- referenced once, main/main.c:2818, as sizeof() on a
#     TYPE inside the TSRM globals size sum, and that block is `#ifdef ZTS`.
#     php_config.h has no `define ZTS 1` and no --enable-zts reaches configure,
#     so it is compiled out and never referenced.
# If a future tree turns ZTS on, this patch stops being sufficient and the link
# will say so.
#
# usage:
#   src/patch-drop-opcache.sh <php-wasm-checkout>
#   src/patch-drop-opcache.sh <php-wasm-checkout> --verify
#
# Keyed on the patched SHAPE, never on a marker comment, and FATAL when the
# shape has moved.
set -euo pipefail

CHECKOUT="${1:?usage: patch-drop-opcache.sh <php-wasm-checkout> [--verify]}"
MODE="${2:-apply}"
PHP_VERSION="${PHP_VERSION:-8.5}"

SRC="$CHECKOUT/third_party/php${PHP_VERSION}-src"
M4="$SRC/ext/opcache/config.m4"
CONFIG_H="$SRC/main/php_config.h"

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

[ -f "$M4" ] || fail "no ext/opcache/config.m4 at $M4"

# the shape: an unconditional PHP_NEW_EXTENSION for opcache
ext_line() { grep -nE "^[[:space:]]*PHP_NEW_EXTENSION\(\[?opcache" "$M4" | head -1 | cut -d: -f1; }
# and the marker this patch leaves behind, which is what --verify reads
patched() { grep -qE "^dnl PHASM: opcache extension removed" "$M4"; }

if [ "$MODE" = '--verify' ]; then
	if patched; then
		ext_still="$(ext_line || true)"
		[ -z "$ext_still" ] || fail "the marker is present but PHP_NEW_EXTENSION(opcache) is still live at line $ext_still"
		echo "ok: ext/opcache is not registered as an extension"
		exit 0
	fi
	fail "not patched: ext/opcache/config.m4 still registers the extension"
fi

patched && fail "already patched; re-running would be a no-op reporting success"

line="$(ext_line || true)"
[ -n "$line" ] || fail "no unconditional PHP_NEW_EXTENSION(opcache) in $M4; the shape moved"

# ZTS would resurrect the zend_accel_globals sizeof in main.c, so refuse rather
# than produce a tree whose link failure looks unrelated to this patch
if [ -f "$CONFIG_H" ] && grep -qE "^#define ZTS 1" "$CONFIG_H"; then
	fail "this tree is ZTS, so main/main.c references sizeof(zend_accel_globals)
      and dropping opcache needs a stub this patch does not provide"
fi

# comment the registration out rather than deleting it, so the diff reads as a
# deliberate removal and --verify has a marker to find
awk -v n="$line" 'NR==n { print "dnl PHASM: opcache extension removed, see src/patch-drop-opcache.sh" } { print }' \
	"$M4" > "$M4.new"
mv "$M4.new" "$M4"
# now neutralise the registration itself
awk 'BEGIN { done = 0 }
	/^[[:space:]]*PHP_NEW_EXTENSION\(\[?opcache/ && !done { print "dnl " $0; done = 1; next }
	{ print }' "$M4" > "$M4.new"
mv "$M4.new" "$M4"

patched || fail "the marker was not written; refusing to report success"
still="$(ext_line || true)"
[ -z "$still" ] || fail "PHP_NEW_EXTENSION(opcache) is still live at line $still after the edit"

echo "commented out PHP_NEW_EXTENSION(opcache) at line $line of ext/opcache/config.m4"
echo "no symbol stub needed: zend_accel_schedule_restart_hook is Zend-defined and"
echo "zend_accel_globals is only referenced under ZTS, which this tree does not set"

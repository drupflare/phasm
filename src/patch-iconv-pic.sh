#!/usr/bin/env bash
# Makes libiconv build position-independent, so it can be linked into a wasm SIDE MODULE.
#
# THE FAILURE. Every `iconv` build dies at the libiconv.so link with, twenty times over:
#   libiconv.a(iconv.o): relocation R_WASM_MEMORY_ADDR_SLEB cannot be used against symbol
#   `.L.str`; recompile with -fPIC
# wasm-ld stops at 20 and prints "too many errors emitted", which is why the real cause was hidden
# behind an error limit for several runs.
#
# WHY IT IS NOT ALREADY PIC. php-wasm passes the flags through the environment:
#   DOCKER_RUN_IN_ICONV = ... -e EMCC_CFLAGS='-fPIC -flto -O${SUB_OPTIMIZE}' ...
# but libiconv compiles through `libtool --mode=compile`, and in CI the flags do not reach the
# object. The CI log's own compile line is the evidence, `-g -O2 -fvisibility=hidden ... -c ./iconv.c`
# with neither -fPIC nor -flto, while PHP's own ext/iconv compile in the same log carries both.
#
# It builds fine on a local machine, which is what made this look intermittent: a locally produced
# libiconv.a has all 3 members as LTO BITCODE, and a bitcode member has no relocations to complain
# about. The archive that fails carries a native non-PIC object instead.
#
# THE FIX, and why it is on configure rather than in the environment. `CFLAGS=` on the configure line
# is recorded in the generated Makefiles, so libtool propagates it into every compile it drives. That
# does not depend on an environment variable surviving a wrapper. The cache file is given its own
# path at the same time, because autoconf caches feature-test results and its own manual warns
# against sharing a cache across different compiler flags -- the shared /tmp/config-cache is used by
# other packages built without these flags.
#
# THIS PATCHES A DEPENDENCY, NOT php-src. The recipe lives in php-wasm's own
# node_modules/php-wasm-iconv/static.mak, so this is an upstream defect and the patch belongs
# upstream too; it is applied here to unblock the variant. node_modules is created by `npm install`
# on the host, so unlike patch-drop-opcache.sh this needs no in-container write.
#
# usage:
#   src/patch-iconv-pic.sh <php-wasm-checkout>
#   src/patch-iconv-pic.sh <php-wasm-checkout> --verify
#
# Keyed on the patched SHAPE and FATAL when the shape has moved.
set -euo pipefail

CHECKOUT="${1:?usage: patch-iconv-pic.sh <php-wasm-checkout> [--verify]}"
MODE="${2:-apply}"

MAK="$CHECKOUT/node_modules/php-wasm-iconv/static.mak"
CFLAGS_ADD="CFLAGS='-fPIC -flto -O\${SUB_OPTIMIZE}'"
CACHE_NEW="--cache-file=/tmp/config-cache-iconv-pic"

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

[ -f "$MAK" ] || fail "no php-wasm-iconv/static.mak at $MAK; was npm install run in the checkout?"

# the shape: libiconv's own configure line, the one libtool inherits from
configure_line() { grep -nE "emconfigure \./configure --prefix=/src/lib/ .*--enable-static=yes" "$MAK" | head -1; }
# anchored to the CONFIGURE line on purpose. A bare `grep -F "CFLAGS='-fPIC..."` matches inside the
# EXISTING `-e EMCC_CFLAGS='-fPIC -flto -O${SUB_OPTIMIZE}'` on the docker line, so it reported
# "already patched" on a virgin tree and would have skipped the fix while exiting 0
patched() { grep -qE "emconfigure \./configure --prefix=/src/lib/ .*CFLAGS=" "$MAK"; }

if [ "$MODE" = '--verify' ]; then
	patched || fail "not patched: libiconv's configure line carries no explicit CFLAGS"
	grep -qF -- "$CACHE_NEW" "$MAK" || fail "the CFLAGS are present but the config cache is still shared"
	echo "ok: libiconv configures with -fPIC -flto and its own config cache"
	exit 0
fi

patched && fail "already patched; re-running would be a no-op reporting success"

line="$(configure_line || true)"
[ -n "$line" ] || fail "no libiconv configure line in $MAK; the shape moved and this patch would do nothing"
lineno="${line%%:*}"

# computed on the host, written in place. A sibling file would be fine here (node_modules is
# host-owned) but an in-place write is the shape the rest of the patches use
NEW="$(awk -v add="$CFLAGS_ADD" -v cache="$CACHE_NEW" '
	/emconfigure \.\/configure --prefix=\/src\/lib\/ .*--enable-static=yes/ && !done {
		sub(/--cache-file=[^ ]*/, cache)
		print $0 " " add
		done = 1
		next
	}
	{ print }
' "$MAK")" || fail "the awk edit failed"

[ -n "$NEW" ] || fail "the awk edit produced nothing"
printf '%s\n' "$NEW" > "$MAK"

patched || fail "the CFLAGS were not written; refusing to report success"
grep -qF -- "$CACHE_NEW" "$MAK" || fail "the cache file was not repointed; refusing to report success"

echo "patched libiconv's configure at line $lineno of node_modules/php-wasm-iconv/static.mak"
echo "added $CFLAGS_ADD and gave it $CACHE_NEW"

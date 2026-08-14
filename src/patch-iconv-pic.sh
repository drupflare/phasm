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
# THE FIX IS `--with-pic`, and the first attempt used the wrong mechanism. libtool DECIDES whether to
# emit PIC: for `--enable-shared=no` it builds only non-PIC objects, because a static archive does not
# need them. So passing `CFLAGS=-fPIC` fights libtool's own logic. `--with-pic` is the standard
# libtool option that says "PIC even for the static library", and it is the mechanism this needs.
# `-flto` is kept alongside it because an LTO member is bitcode, which has no relocations to reject
# at all -- that is why a locally built archive links: all three of its members are bitcode.
#
# THE FIRST ATTEMPT ALSO PATCHED A LINE THE BUILD DID NOT USE. Its regex required
# `--prefix=... .*--enable-static=yes` in that order; CI installs the PUBLISHED php-wasm-iconv, whose
# configure line orders the flags differently. The patch matched a line, `--verify` passed, and the
# configure that actually ran was untouched with the old shared cache. So the matcher is now
# order-independent, it rewrites EVERY libiconv configure invocation it can find, and --verify fails
# if any unpatched one remains anywhere in the checkout.
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

CFLAGS_ADD="--with-pic CFLAGS='-fPIC -flto -O\${SUB_OPTIMIZE}'"
CACHE_NEW="--cache-file=/tmp/config-cache-iconv-pic"

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

# every file in the checkout that configures libiconv. Order-independent: a line that runs
# `./configure` in a libiconv directory and asks for a static build, whatever order the flags are in.
# CI installs the PUBLISHED php-wasm-iconv and the repo carries its own copy under packages/; they do
# not agree on flag order, which is what defeated the first version of this patch.
# DOCKER_RUN_IN_ICONV is on the same line and is what makes this libiconv's configure rather than
# any other package's. A first version matched `emconfigure ./configure .*--enable-static=yes`, which
# also hit libyaml and mbstring -- two packages that build fine and are not this patch's business.
LIBICONV_RE='DOCKER_RUN_IN_ICONV.*emconfigure \./configure'
targets() {
	grep -rlE "$LIBICONV_RE" "$CHECKOUT" --include='*.mak' --include='Makefile' 2> /dev/null | sort -u
}
unpatched() {
	grep -rlE "$LIBICONV_RE" "$CHECKOUT" --include='*.mak' --include='Makefile' 2> /dev/null \
		| xargs -r grep -LE "DOCKER_RUN_IN_ICONV.*--with-pic" | sort -u
}

if [ "$MODE" = '--verify' ]; then
	left="$(unpatched)"
	[ -z "$left" ] || fail "these still configure libiconv without --with-pic:
$left"
	found="$(targets)"
	[ -n "$found" ] || fail "no libiconv configure line anywhere under $CHECKOUT; the shape moved"
	echo "ok: every libiconv configure carries --with-pic"
	printf '%s\n' "$found" | sed 's/^/     /'
	exit 0
fi

found="$(targets)"
[ -n "$found" ] || fail "no libiconv configure line anywhere under $CHECKOUT; the shape moved and this patch would do nothing"

count=0
while IFS= read -r mak; do
	[ -n "$mak" ] || continue
	if grep -qE "DOCKER_RUN_IN_ICONV.*--with-pic" "$mak"; then
		echo "note  already patched, skipping: $mak"
		continue
	fi
	NEW="$(awk -v add="$CFLAGS_ADD" -v cache="$CACHE_NEW" '
		/DOCKER_RUN_IN_ICONV.*emconfigure \.\/configure/ {
			sub(/--cache-file=[^ ]*/, cache)
			print $0 " " add
			next
		}
		{ print }
	' "$mak")" || fail "the awk edit failed on $mak"
	[ -n "$NEW" ] || fail "the awk edit produced nothing for $mak"
	printf '%s\n' "$NEW" > "$mak"
	grep -qE "DOCKER_RUN_IN_ICONV.*--with-pic" "$mak" || fail "the edit did not take in $mak"
	echo "patched $mak"
	count=$((count + 1))
done << EOF
$found
EOF

[ "$count" -gt 0 ] || fail "found libiconv configure lines but patched none; refusing to report success"
left="$(unpatched)"
[ -z "$left" ] || fail "patched $count file(s) but these remain unpatched:
$left"
echo "added --with-pic (plus -flto and a private config cache) to $count libiconv configure line(s)"

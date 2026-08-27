#!/usr/bin/env bash
# Checks that every rc's derived MAKE_EXTRA parses into make VARIABLE ASSIGNMENTS and nothing else.
#
# THIS EXISTS BECAUSE A GREEN MATRIX HID A QUOTING BUG FOR A WHOLE BUILD. build-variant.sh derived
# `EXTRA_CFLAGS=-DZEND_ENABLE_ZVAL_LONG64=1 -mbulk-memory` as a bare string, build-static.sh expanded
# it unquoted, and make received `-mbulk-memory` as an OPTION. It printed its usage and exited 2,
# which in a 4,992-line log reads exactly like a compiler failure -- the emmalloc and bulkmem arms
# both died there while every single-flag arm passed, because a one-word value cannot show the bug.
#
# So the property under test is not "does it build". It is: after the same eval-splitting the real
# consumer does, is every argument of the form NAME=..., with no leading dash anywhere.
#
# Usage:
#   bash tools/test-make-extra.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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

# the derivation, kept in step with build-variant.sh by reading the same rc markers
derive() {
	local rc="$1" compile='' link='' derived=''
	grep -q 'SUPPORT_LONGJMP=wasm' "$rc" && compile="$compile -sSUPPORT_LONGJMP=wasm"
	grep -q 'MEMORY64=1' "$rc" && compile="$compile -sMEMORY64=1"
	grep -q 'ZEND_LONG64=1' "$rc" && compile="$compile -DZEND_ENABLE_ZVAL_LONG64=1"
	grep -q 'BULK_MEMORY=1' "$rc" && {
		compile="$compile -mbulk-memory"
		link="$link -mbulk-memory"
	}
	grep -q 'MALLOC=emmalloc' "$rc" && {
		compile="$compile -sMALLOC=emmalloc"
		link="$link -sMALLOC=emmalloc"
	}
	grep -q 'IMPORTED_MEMORY=1' "$rc" && link="$link -sIMPORTED_MEMORY=1"
	[ -n "$compile" ] && derived="EXTRA_CFLAGS='${compile# }'"
	[ -n "$link" ] && derived="$derived EXTRA_FLAGS='${link# }'"
	printf '%s' "${derived# }"
}

for rc in "$HERE"/src/rc/*.rc "$HERE"/src/rc/*.rc.pending; do
	[ -e "$rc" ] || continue
	name="$(basename "$rc")"
	extra="$(derive "$rc")"
	[ -n "$extra" ] || continue

	# the same expansion src/build-static.sh performs
	args=()
	eval "args=($extra)"
	bad=0
	for a in "${args[@]}"; do
		case "$a" in
			-*) bad=1 ;;
			*=*) ;;
			*) bad=1 ;;
		esac
	done
	ok "$name derives only NAME=value arguments" "$bad"
done

# the regression itself, pinned directly: two compile flags in one assignment stay one argument
args=()
eval "args=(EXTRA_CFLAGS='-DA=1 -mbulk-memory' EXTRA_FLAGS='-mbulk-memory')"
if [ "${#args[@]}" = 2 ] && [ "${args[0]}" = 'EXTRA_CFLAGS=-DA=1 -mbulk-memory' ]; then
	ok "a two-flag EXTRA_CFLAGS stays a single argument" 0
else
	ok "a two-flag EXTRA_CFLAGS stays a single argument" 1
fi

# and the shape that broke it still leaks an option, so the check above is not vacuous
args=()
eval "args=(EXTRA_CFLAGS=-DA=1 -mbulk-memory)"
if [ "${#args[@]}" = 2 ] && [ "${args[1]}" = '-mbulk-memory' ]; then
	ok "the unquoted form still leaks a bare option to make" 0
else
	ok "the unquoted form still leaks a bare option to make" 1
fi

echo
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]

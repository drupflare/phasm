#!/usr/bin/env bash
# Makes libiconv build position-independent, so it can be linked into a wasm SIDE MODULE.
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
# passed to `make`, not to configure: a command-line assignment wins over the makefile's own
MAKE_ADD="CFLAGS='-fPIC -flto -O\${SUB_OPTIMIZE}' CPPFLAGS='-fPIC'"

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

# THE MAKEFILE'S OWN CONTRACT IS THE TARGET LIST, and three attempts failed by using something else.
# php-wasm includes its packages like this, at Makefile:244:
#   -include $(addsuffix /static.mak,$(filter-out ${TOP_LEVEL},$(shell npm ls -p)))
# So the authoritative path is `$(npm ls -p)/static.mak`, and anything else is a guess. What failed:
# release-asset download (the newest release has no assets), a `grep -rl` tree walk (it reported
# packages/iconv while CI's error names node_modules/php-wasm-iconv, and `grep -r` does not follow a
# symlinked directory), and an order-dependent regex (the published package orders the flags
# differently from the repo copy).
#
# LOCALLY THE TWO PATHS ARE ONE FILE -- node_modules/php-wasm-iconv is a symlink to ../packages/iconv
# -- which is why every local validation passed while CI kept failing. That asymmetry is the whole
# reason this step prints what it resolved.
LIBICONV_RE='DOCKER_RUN_IN_ICONV.*emconfigure \./configure'

targets() {
	{
		# what the Makefile includes, resolved the same way it resolves it
		(cd "$CHECKOUT" && npm ls -p 2> /dev/null) | while IFS= read -r dir; do
			[ -n "$dir" ] && [ -f "$dir/static.mak" ] \
				&& grep -lE "$LIBICONV_RE" "$dir/static.mak" 2> /dev/null
		done
		# and anything else with the same shape, symlinks followed, so a second real copy cannot hide
		find "$CHECKOUT" -name 'static.mak' -exec grep -lE "$LIBICONV_RE" {} + 2> /dev/null
	} | sort -u
}

# BOTH edits, because a half-applied patch reporting success is how four runs were spent. A file
# counts as patched only when the configure line carries --with-pic AND the make line carries CFLAGS.
unpatched() {
	found="$(targets)"
	[ -n "$found" ] || return 0
	printf '%s\n' "$found" | while IFS= read -r f; do
		[ -n "$f" ] || continue
		if ! grep -qE "DOCKER_RUN_IN_ICONV.*--with-pic" "$f" \
			|| ! grep -qE "DOCKER_RUN_IN_ICONV.*emmake make -j.*CFLAGS=" "$f"; then
			echo "$f"
		fi
	done | sort -u
}

# printed on every run, because the failure mode of this patch is editing the wrong copy and
# reporting success. An operator reading the log must be able to see WHICH file, whether it is a
# symlink, and what its content hash was before and after
describe() {
	printf '%s\n' "$1" | while IFS= read -r f; do
		[ -n "$f" ] || continue
		real="$(cd "$(dirname "$f")" && pwd -P)/$(basename "$f")"
		link=''
		[ -L "$(dirname "$f")" ] && link=' (parent is a SYMLINK)'
		printf '      %s\n        -> %s%s  md5=%s\n' "$f" "$real" "$link" \
			"$(md5sum "$f" 2> /dev/null | cut -c1-12 || md5 -q "$f" 2> /dev/null | cut -c1-12)"
	done
}

if [ "$MODE" = '--verify' ]; then
	left="$(unpatched)"
	[ -z "$left" ] || fail "these still configure libiconv without --with-pic:
$left"
	found="$(targets)"
	[ -n "$found" ] || fail "no libiconv configure line anywhere under $CHECKOUT; the shape moved"
	echo "ok: every libiconv configure carries --with-pic"
	echo "    resolved targets:"
	describe "$found"
	exit 0
fi

found="$(targets)"
[ -n "$found" ] || fail "no libiconv configure line anywhere under $CHECKOUT; the shape moved and this patch would do nothing"

echo "resolved targets BEFORE patching:"
describe "$found"

count=0
while IFS= read -r mak; do
	[ -n "$mak" ] || continue
	if grep -qE "DOCKER_RUN_IN_ICONV.*--with-pic" "$mak" \
		&& grep -qE "DOCKER_RUN_IN_ICONV.*emmake make -j.*CFLAGS=" "$mak"; then
		echo "note  already patched, skipping: $mak"
		continue
	fi
	NEW="$(awk -v add="$CFLAGS_ADD" -v cache="$CACHE_NEW" -v mk="$MAKE_ADD" '
		/DOCKER_RUN_IN_ICONV.*emconfigure \.\/configure/ {
			sub(/--cache-file=[^ ]*/, cache)
			print $0 " " add
			next
		}
		# THE LEVER THAT ACTUALLY BINDS. A command-line variable assignment to make overrides any
		# assignment inside the makefile, unconditionally -- so `make CFLAGS=...` beats whatever
		# configure decided. The patched line is verifiably the one the Makefile includes (md5 changes, and
		# node_modules/php-wasm-iconv is a symlink to packages/iconv in CI as well as locally), yet
		# libiconv recurses into SUB-configures that drop the added arguments and then read the
		# shared /tmp/config-cache, where the PIC answer arrives as "(cached)".
		/DOCKER_RUN_IN_ICONV.*emmake make -j/ {
			print $0 " " mk
			next
		}
		{ print }
	' "$mak")" || fail "the awk edit failed on $mak"
	[ -n "$NEW" ] || fail "the awk edit produced nothing for $mak"
	printf '%s\n' "$NEW" > "$mak"
	grep -qE "DOCKER_RUN_IN_ICONV.*--with-pic" "$mak" || fail "the configure edit did not take in $mak"
	grep -qE "DOCKER_RUN_IN_ICONV.*emmake make -j.*CFLAGS=" "$mak" \
		|| fail "the make-line CFLAGS override did not take in $mak"
	echo "patched $mak"
	count=$((count + 1))
done << EOF
$found
EOF

[ "$count" -gt 0 ] || fail "found libiconv configure lines but patched none; refusing to report success"
left="$(unpatched)"
[ -z "$left" ] || fail "patched $count file(s) but these remain unpatched:
$left"
echo "resolved targets AFTER patching:"
describe "$found"
echo "added --with-pic (plus -flto and a private config cache) to $count libiconv configure line(s)"

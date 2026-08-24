#!/usr/bin/env bash
# Drives patch-vrzno-lp64.mjs over a synthetic ext/vrzno.
#
# The real target is a php-src tree the builder container owns, so a host-side write to it fails
# with EACCES on a Linux runner and passes on Docker Desktop, which maps the host user. That is
# what --out-dir exists for and what this covers: the transform is a property of the text, so a
# fixture carrying one keepalive signature, one ccall site and one EM_ASM binding exercises it
# with no toolchain at all.
#
# What it does not prove: that the rewritten C compiles, or that vrzno works under LP64. Only a
# wasm64 build says that.
#
# Usage:
#   bash tools/test-vrzno-lp64.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$HERE/src/patch-vrzno-lp64.mjs"
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

expect_exit() {
	local want="$1" label="$2"
	shift 2
	local got=0
	"$@" > /dev/null 2>&1 || got=$?
	ok "$label" "$([ "$got" = "$want" ] && echo 0 || echo 1)"
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
VRZNO="$TMP/vrzno"
STAGE="$TMP/stage"
mkdir -p "$VRZNO" "$STAGE"
FIXTURE="$VRZNO/vrzno.c"

# size_t is the WIDE case: it is not a pointer, ccall has no converter for it, and under LP64 it
# still has to cross as a BigInt -- so 'pointer' is the only token that does the right thing
cat > "$FIXTURE" << 'EOF'
#include "php.h"

zval * EMSCRIPTEN_KEEPALIVE vrzno_fetch(int handle, size_t offset)
{
	EM_ASM({
		const target = $0;
		const size = $1;
		Module.ccall('vrzno_fetch','number',['number','number'],[target,size]);
	}, handle, offset);
	return NULL;
}
EOF
BEFORE="$(md5 -q "$FIXTURE" 2> /dev/null || md5sum "$FIXTURE" | cut -d' ' -f1)"

echo "patch-vrzno-lp64.mjs: --out-dir staging"

# #region an unpatched tree is refused
expect_exit 1 "--verify refuses an unpatched tree" node "$SCRIPT" "$VRZNO" --verify
# #endregion

# #region --out-dir writes the staging copy and leaves the original alone
node "$SCRIPT" "$VRZNO" --out-dir "$STAGE" > /dev/null
AFTER="$(md5 -q "$FIXTURE" 2> /dev/null || md5sum "$FIXTURE" | cut -d' ' -f1)"
ok "the container-owned original is untouched" \
	"$([ "$BEFORE" = "$AFTER" ] && echo 0 || echo 1)"
ok "the rewritten source is staged" "$([ -f "$STAGE/vrzno.c" ] && echo 0 || echo 1)"
# a stage dir mistaken for the positional would read zero signatures and stage nothing, so the
# two assertions below are also what pins the argv parsing
ok "the wide scalar is retyped to 'pointer'" \
	"$(grep -q "\['number','pointer'\]" "$STAGE/vrzno.c" && echo 0 || echo 1)"
ok "the pointer return is retyped to 'pointer'" \
	"$(grep -q "'vrzno_fetch','pointer'" "$STAGE/vrzno.c" && echo 0 || echo 1)"
ok "both EM_ASM bindings are coerced" \
	"$([ "$(grep -c 'Number(\$[01])' "$STAGE/vrzno.c")" = "2" ] && echo 0 || echo 1)"
# #endregion

# #region the staged write is what --verify then accepts
cp "$STAGE/vrzno.c" "$FIXTURE"
expect_exit 0 "--verify accepts the tree once the staged copy lands" \
	node "$SCRIPT" "$VRZNO" --verify
rm -f "$STAGE/vrzno.c"
node "$SCRIPT" "$VRZNO" --out-dir "$STAGE" > /dev/null
ok "a second apply stages nothing" "$([ -f "$STAGE/vrzno.c" ] && echo 1 || echo 0)"
# #endregion

# #region a call site the signatures do not cover is a hard error, not a silent rewrite
printf "\nvoid other(void) { Module.ccall('nosuch','number',['number'],[1]); }\n" >> "$FIXTURE"
expect_exit 1 "an unknown ccall target is refused" node "$SCRIPT" "$VRZNO" --out-dir "$STAGE"
# #endregion

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ]

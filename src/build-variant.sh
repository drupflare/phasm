#!/usr/bin/env bash
# Builds one php-wasm variant into vendor/static-<variant>, driving
# src/build-static.sh with the rc in src/rc/<variant>.rc.
#
# Variants named vmswitch / vmgoto additionally regenerate Zend/zend_vm_execute.h
# with a different ZEND_VM_KIND before building. That regeneration MUST run under
# PHP 8.3 or 8.4, never 8.5: PHP 8.5 predefines ZEND_VM_KIND (as the string
# "ZEND_VM_KIND_TAILCALL"), so the generator's own define() silently fails and it
# emits `#define ZEND_VM_KIND` with an empty value. Hence docker php:8.3-cli.
#
# Never overwrites an existing build: each vendor/static-* directory cost hours.
set -euo pipefail

VARIANT="${1:?usage: build-variant.sh <variant> [php-wasm-checkout]}"
SRC="${2:-/tmp/phpwasm-build/php-wasm}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RC="$ROOT/src/rc/${VARIANT}.rc"
OUT="$ROOT/vendor/static-${VARIANT}"
PRISTINE=/tmp/phpwasm-build/vmgen-pristine

# an unproven arm lives as .rc.pending so the push matrix cannot schedule it; building one
# explicitly by name is how it earns the rename
if [ ! -f "$RC" ] && [ -f "$RC.pending" ]; then
	echo "building the PENDING rc $RC.pending; rename it to $RC once it links"
	RC="$RC.pending"
fi
[ -f "$RC" ] || {
	echo "no rc file at $RC"
	exit 1
}
[ -d "$SRC" ] || {
	echo "no php-wasm checkout at $SRC"
	exit 1
}
compgen -G "$OUT/*.wasm" > /dev/null && {
	echo "refusing to overwrite an existing build at $OUT"
	exit 1
}

cp "$RC" "$SRC/.php-wasm-rc"

PHP_VERSION="$(sed -n 's/^PHP_VERSION=\([0-9][0-9.]*\).*/\1/p' "$RC" | tail -1)"
PHP_VERSION="${PHP_VERSION:-8.3}"
export PHP_VERSION
echo "building $VARIANT at PHP $PHP_VERSION"

case "$VARIANT" in
	vmgoto) VM_KIND=GOTO ;;
	*) VM_KIND= ;;
esac

# Flags that are NOT link-only have to arrive as a make command-line variable: Makefile:209 clears
# EXTRA_CFLAGS after the rc is included, so an rc cannot carry a compile flag at all. Derived here
# rather than in build.yml so a local build is the same build CI runs -- it was only in the workflow,
# which meant a local `build-variant.sh jspisjlj` silently compiled without -sSUPPORT_LONGJMP=wasm.
COMPILE_FLAGS=
LINK_FLAGS=
grep -q 'SUPPORT_LONGJMP=wasm' "$RC" && COMPILE_FLAGS="$COMPILE_FLAGS -sSUPPORT_LONGJMP=wasm"
grep -q 'MEMORY64=1' "$RC" && COMPILE_FLAGS="$COMPILE_FLAGS -sMEMORY64=1"
# Zend/zend_long.h sets ZEND_ENABLE_ZVAL_LONG64 from compiler predefines and derives
# SIZEOF_ZEND_LONG from it; no configure macro is involved, so a -D is the whole mechanism
grep -q 'ZEND_LONG64=1' "$RC" && COMPILE_FLAGS="$COMPILE_FLAGS -DZEND_ENABLE_ZVAL_LONG64=1"
# -mbulk-memory is an LLVM TARGET FEATURE, so it has to be on the compile line for every object;
# putting it only on the link leaves each object already lowered to a libc memcpy call
grep -q 'BULK_MEMORY=1' "$RC" && {
	COMPILE_FLAGS="$COMPILE_FLAGS -mbulk-memory"
	LINK_FLAGS="$LINK_FLAGS -mbulk-memory"
}
# MALLOC picks the allocator implementation, which is compiled INTO the output, so both halves
grep -q 'MALLOC=emmalloc' "$RC" && {
	COMPILE_FLAGS="$COMPILE_FLAGS -sMALLOC=emmalloc"
	LINK_FLAGS="$LINK_FLAGS -sMALLOC=emmalloc"
}
# IMPORTED_MEMORY is link-only: it changes who CREATES the WebAssembly.Memory, not how code
# addresses it
grep -q 'IMPORTED_MEMORY=1' "$RC" && LINK_FLAGS="$LINK_FLAGS -sIMPORTED_MEMORY=1"
if [ -n "$COMPILE_FLAGS" ] || [ -n "$LINK_FLAGS" ]; then
	# each value is QUOTED as one argument: an arm passing two compile flags produces
	# `EXTRA_CFLAGS=-DX=1 -mbulk-memory`, and unquoted that hands make `-mbulk-memory` as an
	# option rather than as part of the assignment. make answers with its usage and exit 2,
	# which looks like a toolchain failure -- it killed the emmalloc and bulkmem arms
	DERIVED=
	[ -n "$COMPILE_FLAGS" ] && DERIVED="EXTRA_CFLAGS='${COMPILE_FLAGS# }'"
	[ -n "$LINK_FLAGS" ] && DERIVED="$DERIVED EXTRA_FLAGS='${LINK_FLAGS# }'"
	# a caller-supplied MAKE_EXTRA wins, so an explicit override is still possible
	MAKE_EXTRA="${MAKE_EXTRA:-${DERIVED# }}"
	export MAKE_EXTRA
	echo "derived flags for $VARIANT: $MAKE_EXTRA"
fi

# wasm64 changes the ABI of every object, so a tree configured for wasm32 cannot be reused: the
# `configured` stamp is a plain file target and would otherwise be honoured across the change.
#
# The stamp lives in the CHECKOUT ROOT, not in php-src: php-src is created by the builder container
# and is not host-writable on a Linux runner, which is the same trap that broke two patch scripts.
ABI=wasm32
grep -q 'MEMORY64=1' "$RC" && ABI=wasm64
# a long64 arm is wasm32 by pointer width and NOT by object layout: zend_long is 8 bytes, so every
# object differs and a tree compiled for plain wasm32 must not be reused
grep -q 'ZEND_LONG64=1' "$RC" && ABI="${ABI}-long64"
# same reasoning one level down: both of these change emitted code in every object, so a tree
# compiled without them cannot be relinked into an arm that has them
grep -q 'BULK_MEMORY=1' "$RC" && ABI="${ABI}-bulkmem"
grep -q 'MALLOC=emmalloc' "$RC" && ABI="${ABI}-emmalloc"
# the allocator is chosen inside php-src rather than by a flag, so a tree patched for it holds
# different objects; without this a zendalloc build could be relinked from a stock tree
grep -q 'ZEND_ALLOC=1' "$RC" && ABI="${ABI}-zendalloc"
ABI_STAMP="$SRC/.php-wasm-abi"
WAS="$(cat "$ABI_STAMP" 2> /dev/null || echo wasm32)"
if [ "$WAS" != "$ABI" ]; then
	echo "the tree was built for $WAS and this is a $ABI build; forcing a reconfigure"
	rm -f "$SRC/third_party/php${PHP_VERSION}-src/configured"
fi
printf '%s\n' "$ABI" > "$ABI_STAMP"
MEMORY64=0
# read from the rc rather than from $ABI, which now carries a long64 suffix as well
grep -q 'MEMORY64=1' "$RC" && MEMORY64=1
export MEMORY64

PHP_SRC="$SRC/third_party/php${PHP_VERSION}-src"
ZEND="$PHP_SRC/Zend"
if [ -n "$VM_KIND" ]; then
	echo "regenerating the VM as ZEND_VM_KIND_${VM_KIND} under php:8.3-cli"
	docker run --rm -v "$PHP_SRC:/w" -w /w/Zend php:8.3-cli \
		php zend_vm_gen.php --with-vm-kind="$VM_KIND"
	grep -q "define ZEND_VM_KIND[[:space:]]*ZEND_VM_KIND_${VM_KIND}" "$ZEND/zend_vm_opcodes.h" \
		|| {
			echo "VM regeneration did not take; refusing to build"
			exit 1
		}
elif [ "$PHP_VERSION" = 8.3 ] && [ -d "$ZEND" ]; then
	# restore the shipped HYBRID/CALL headers in case a vm variant ran before; vmgen-pristine
	# holds 8.3 headers, so it is only ever the right thing to copy into an 8.3 tree
	if [ -f "$PRISTINE/zend_vm_execute.h" ]; then
		cp "$PRISTINE/zend_vm_execute.h" "$PRISTINE/zend_vm_opcodes.h" "$ZEND/"
	fi
fi

OUT="$OUT" JOBS="${JOBS:-8}" bash "$ROOT/src/build-static.sh" "$SRC"

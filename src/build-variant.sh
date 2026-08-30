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
# the MAKEFILE, not the directory. `-d` passes against a tree docker left behind: a `-v` mount of a
# path that does not exist creates it, so one failed regeneration turns $SRC into a stub that every
# later run accepts and then fails inside, several minutes and one image pull later
[ -f "$SRC/Makefile" ] || {
	echo "no php-wasm checkout at $SRC (no Makefile there)"
	echo "clone it first; a directory alone is not a checkout"
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
	# NOT a VM_KIND regeneration; see the TAIL_CALL patch below for why
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
# same shape as -mbulk-memory and for the same reason: -mtail-call is an LLVM TARGET FEATURE, so an
# object compiled without it is already lowered to an ordinary call and no link flag recovers it
grep -q 'TAIL_CALL=1' "$RC" && {
	COMPILE_FLAGS="$COMPILE_FLAGS -mtail-call"
	LINK_FLAGS="$LINK_FLAGS -mtail-call"
	# The SHIPPED zend_vm_execute.h already carries 4,926 _TAILCALL handlers, the macro definitions
	# and 21 `#if ZEND_VM_KIND == ZEND_VM_KIND_TAILCALL` guards: the kind is chosen at COMPILE time,
	# not at generation time. Regenerating with ZEND_VM_GEN_KIND=5 is therefore WRONG and was tried
	# -- the generator's macro-emission switch has cases for HYBRID and CALL only, so kind 5 matches
	# nothing, emits no ZEND_OPCODE_HANDLER_RET / _ARGS / ZEND_VM_TAIL_CALL, and the handlers it
	# does emit reference macros that no longer exist. CI failed with 20 `unknown type name` errors.
	#
	# So: leave the shipped header alone and satisfy the gate instead. Measured against this emcc,
	# HAVE_MUSTTAIL and __clang__ hold while HAVE_PRESERVE_NONE and the arch test do not. Both of
	# those are patched in the gate below rather than defined here: -DHAVE_PRESERVE_NONE=1 would make
	# zend_portability.h define ZEND_PRESERVE_NONE as the attribute and REDEFINE this empty one, which
	# is the opposite of what it was reaching for. Empty selects the default calling convention; it
	# costs the register-pressure win and leaves musttail, the half that emits return_call, untouched.
	COMPILE_FLAGS="$COMPILE_FLAGS -DZEND_PRESERVE_NONE="
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
# the VM regeneration rewrites zend_vm_execute.h into a different handler shape, and -mtail-call
# changes emitted code in every object; a tree compiled as CALL cannot be relinked into this
grep -q 'TAIL_CALL=1' "$RC" && ABI="${ABI}-tailcall"
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
# Both halves of the TAILCALL gate that wasm32 fails. Patched INSIDE the container: php-src is
# created there and is not host-writable on a Linux runner, which is the trap that broke two earlier
# patch scripts. Keyed on the patched SHAPE rather than a marker, so a re-run is a no-op.
if grep -q 'TAIL_CALL=1' "$RC"; then
	# `@` as the delimiter, and the NARROWEST substring that identifies each half. A `|` delimiter
	# collides with the `||` inside the condition -- sed answered "bad option in substitution
	# expression" and the arm failed in 1.5 s. Both patterns occur exactly once in the file.
	docker run --rm -v "$PHP_SRC:/w" -w /w alpine:3 sh -c "
		grep -q 'defined(__aarch64__) || defined(__wasm__)' Zend/zend_vm_opcodes.h ||
			sed -i 's@defined(__aarch64__))@defined(__aarch64__) || defined(__wasm__))@' Zend/zend_vm_opcodes.h
		grep -q 'defined(HAVE_PRESERVE_NONE) || defined(__wasm__)' Zend/zend_vm_opcodes.h ||
			sed -i 's@defined(HAVE_PRESERVE_NONE)@(defined(HAVE_PRESERVE_NONE) || defined(__wasm__))@' Zend/zend_vm_opcodes.h
	"
	# read the gate back and PRINT it on refusal. The first attempt asserted `__wasm__.*__clang__`,
	# which the pinned php-8.5.2 tag cannot satisfy: `&& defined(__clang__)` was appended to that
	# condition after the tag, so the patch had taken and the check was reading the branch head
	GATE="$(docker run --rm -v "$PHP_SRC:/w" -w /w alpine:3 \
		grep -m1 HAVE_MUSTTAIL Zend/zend_vm_opcodes.h || true)"
	for want in 'defined(__aarch64__) || defined(__wasm__)' \
		'(defined(HAVE_PRESERVE_NONE) || defined(__wasm__))'; do
		case "$GATE" in
			*"$want"*) ;;
			*)
				echo "the TAILCALL gate patch did not take: $want"
				echo "  gate reads: $GATE"
				echo "refusing to build a CALL binary named vmtailcall"
				exit 1
				;;
		esac
	done
	echo "patched the TAILCALL gate to admit __wasm__: $GATE"
fi

if [ -n "$VM_KIND" ]; then
	# php-src is cloned BY the build, so on a tree that has never been built there is nothing to
	# regenerate yet. Checked before the docker run rather than after: mounting a missing path
	# CREATES it, so the failure would otherwise leave a stub behind that breaks the next run too
	[ -f "$ZEND/zend_vm_gen.php" ] || {
		echo "no $ZEND/zend_vm_gen.php; php-src is created by the build, so build this variant"
		echo "once without a VM kind (or run the php-wasm 'patched' target) before regenerating"
		exit 1
	}
	echo "regenerating the VM as ZEND_VM_KIND_${VM_KIND} under php:8.3-cli"
	# TAILCALL is NOT reachable through --with-vm-kind: the flag's switch accepts only
	# CALL|SWITCH|GOTO|HYBRID and everything else dies "Invalid vm kind". The generator DOES carry
	# the backend (ZEND_VM_KIND_TAILCALL = 5, with its own codegen branches); only the argument
	# parser omits it. `ZEND_VM_GEN_KIND` is defaulted behind `if (!defined(...))`, so pre-defining
	# it selects the kind without patching php-src at all
	if [ "$VM_KIND" = TAILCALL ]; then
		docker run --rm -v "$PHP_SRC:/w" -w /w/Zend php:8.3-cli \
			php -r 'define("ZEND_VM_GEN_KIND", 5); require "/w/Zend/zend_vm_gen.php";'
	else
		docker run --rm -v "$PHP_SRC:/w" -w /w/Zend php:8.3-cli \
			php zend_vm_gen.php --with-vm-kind="$VM_KIND"
	fi
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

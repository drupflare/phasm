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

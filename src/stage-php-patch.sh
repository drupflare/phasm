#!/usr/bin/env bash
# Replaces php-wasm's patch for a PHP series with the one kept here, when this repository has one.
#
# php-wasm applies patch/php<minor>.patch to php-src after cloning the tag its Makefile names. A
# patch written against 8.5.2 no longer applies to 8.5.12 (two hunks moved), so src/patch/ holds a
# copy rebased onto the release src/php-versions.lock pins. Run it before the `patched` target.
#
# usage: PHP_VERSION=8.5 src/stage-php-patch.sh <php-wasm-checkout>
set -euo pipefail

SRC="${1:?usage: stage-php-patch.sh <php-wasm-checkout>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MINOR="${PHP_VERSION:-8.5}"
OURS="$ROOT/src/patch/php${MINOR}.patch"
THEIRS="$SRC/patch/php${MINOR}.patch"

[ -f "$OURS" ] || {
	echo "no rebased patch for PHP $MINOR; php-wasm's own stays in place"
	exit 0
}
[ -f "$THEIRS" ] || {
	echo "no $THEIRS; is $SRC a php-wasm checkout?"
	exit 1
}
cp "$OURS" "$THEIRS"
echo "staged $OURS over $THEIRS"

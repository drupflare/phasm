#!/usr/bin/env bash
# Checks src/php-pin.sh and the version floor inspect-build.sh enforces with it.
#
# The property under test: a build reporting a PHP below the pinned patch release fails, a build at
# or above it passes, and a build that reports no version at all fails instead of passing by silence.
# The comparison is numeric, because 8.5.9 is below 8.5.12 and a string compare says the opposite.
#
# Usage:
#   bash tools/test-php-pin.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PIN="$HERE/src/php-pin.sh"
INSPECT="$HERE/src/inspect-build.sh"
PASS=0
FAIL=0

# check "<what holds>" <command that succeeds when it does>
check() {
	local what="$1"
	shift
	if "$@" > /dev/null 2>&1; then
		PASS=$((PASS + 1))
		echo "  ok   $what"
	else
		FAIL=$((FAIL + 1))
		echo "  FAIL $what"
	fi
}

# exit status of a command
status() {
	local rc=0
	"$@" > /dev/null 2>&1 || rc=$?
	echo "$rc"
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# a directory shaped like a build: inspect-build.sh reads strings out of the .wasm
fixture() {
	mkdir -p "$TMP/$1"
	printf '%s\n' "$2" > "$TMP/$1/php.wasm"
}
fixture old "PHP/8.5.2 X-Powered-By"
fixture current "PHP/8.5.12 X-Powered-By"
fixture silent "no version string here"

ref_is_sha() { bash "$PIN" php-wasm-ref | grep -Eq '^[0-9a-f]{40}$'; }
names_the_pin() { [[ "$(bash "$INSPECT" "$TMP/old" 2>&1 || true)" == *"below the pinned 8.5.12"* ]]; }

check "the 8.5 series pins 8.5.12" [ "$(bash "$PIN" resolve 8.5)" = "8.5.12" ]
check "a series with no pin resolves to nothing" [ -z "$(bash "$PIN" resolve 8.3)" ]
check "the php-wasm commit is a full SHA" ref_is_sha
check "php-wasm-ref reads the same line resolve does" \
	[ "$(bash "$PIN" resolve php-wasm)" = "$(bash "$PIN" php-wasm-ref)" ]
check "8.5.2 is below the floor" [ "$(status bash "$PIN" check 8.5 8.5.2)" = 1 ]
check "8.5.9 is below 8.5.12, which a string compare gets wrong" \
	[ "$(status bash "$PIN" check 8.5 8.5.9)" = 1 ]
check "8.5.12 meets the floor" [ "$(status bash "$PIN" check 8.5 8.5.12)" = 0 ]
check "8.5.13 is above it" [ "$(status bash "$PIN" check 8.5 8.5.13)" = 0 ]
check "a series with no pin is never refused" [ "$(status bash "$PIN" check 8.3 8.3.11)" = 0 ]
check "inspect-build fails a build reporting 8.5.2" [ "$(status bash "$INSPECT" "$TMP/old")" = 1 ]
check "and names the pin it is below" names_the_pin
check "inspect-build passes a build reporting 8.5.12" \
	[ "$(status bash "$INSPECT" "$TMP/current")" = 0 ]
check "inspect-build fails a build that reports no version" \
	[ "$(status bash "$INSPECT" "$TMP/silent")" = 1 ]

echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]

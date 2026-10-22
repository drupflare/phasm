#!/usr/bin/env bash
# The PHP patch release each minor series builds at, read from src/php-versions.lock.
#
# php-wasm's Makefile hardcodes a patch release per minor (PHP_VERSION_FULL=8.5.2 at the time this
# was written) and an rc cannot move it, because the assignment sits after the rc is included. A
# make command-line variable beats it, so build-variant.sh passes the version this file names.
# inspect-build.sh reads the same file and fails a build whose reported version is below it.
#
# The same file records the php-wasm commit the pinned release builds with. php-wasm master has
# refused every rc here since 554b0627 (it errors on ASYNCIFY=0 for PHP 8.5), and its 8.5 patch is
# the one src/patch/ replaces, so the commit is part of the pin.
#
# usage:
#   src/php-pin.sh resolve <minor>           prints the pinned patch release, or nothing
#   src/php-pin.sh check <minor> <reported>  exits 1 when <reported> is below the pin
#   src/php-pin.sh php-wasm-ref              prints the pinned php-wasm commit, or nothing
set -euo pipefail

LOCK="${PHP_VERSIONS_LOCK:-$(cd "$(dirname "$0")" && pwd)/php-versions.lock}"

resolve() {
	awk -v minor="$1" '$1 == minor { print $2 }' "$LOCK"
}

# numeric compare of dotted versions: 8.5.9 is below 8.5.12, which a string compare gets wrong
at_least() {
	local a b i
	IFS=. read -r -a a <<< "$1"
	IFS=. read -r -a b <<< "$2"
	for i in 0 1 2; do
		if [ "${a[$i]:-0}" -gt "${b[$i]:-0}" ]; then return 0; fi
		if [ "${a[$i]:-0}" -lt "${b[$i]:-0}" ]; then return 1; fi
	done
	return 0
}

case "${1:-}" in
	resolve)
		resolve "${2:?usage: php-pin.sh resolve <minor>}"
		;;
	check)
		minor="${2:?usage: php-pin.sh check <minor> <reported>}"
		reported="${3:?usage: php-pin.sh check <minor> <reported>}"
		floor="$(resolve "$minor")"
		[ -n "$floor" ] || exit 0
		if ! at_least "$reported" "$floor"; then
			echo "php $reported is below the pinned $floor for the $minor series (src/php-versions.lock)"
			exit 1
		fi
		;;
	php-wasm-ref)
		resolve php-wasm
		;;
	*)
		echo "usage: php-pin.sh resolve <minor> | check <minor> <reported> | php-wasm-ref"
		exit 2
		;;
esac

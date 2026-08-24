#!/usr/bin/env bash
# Retypes vrzno's JS<->wasm boundary for the LP64 (wasm64) ABI.
#
# WHY THIS EXISTS
# vrzno's JavaScript lives in EM_ASM blocks inside its C sources, and every one of them was written
# against ILP32. Two separate things break under LP64 and only one of them throws:
#
#   1. Module.ccall(name, 'number', ['number'], [ptr]) -- emscripten's ccall converts an argument
#      only when its declared type has an entry in `toC`, and `pointer` is the only one that yields
#      a BigInt. A pointer declared 'number' reaches an i64 parameter as a JS Number and the call
#      dies with "Cannot convert <n> to a BigInt".
#   2. The RETURN direction, which does NOT throw. convertReturnValue() narrows with Number(ret) for
#      'pointer' and returns the raw value otherwise, so a pointer declared 'number' comes back as a
#      BigInt -- and the JS then uses it as a Map key and in `ptr >> 2` arithmetic. A BigInt key
#      never matches a Number key, so chasing only the exception leaves that silently wrong.
#
# EM_ASM ARGUMENTS ARE AFFECTED TOO, and checking only the pointer case says otherwise.
# readEmAsmArgs() reads a 'p' argument as Number(HEAPU64[..]) -- so pointers arrive as Numbers and
# the first reading of this was that EM_ASM needed nothing. It reads a 'j' argument as HEAP64[..],
# a BigInt, and under LP64 every size_t / zend_long / off_t becomes 'j' where it used to be 'i'.
# sizeof(zval), self->fpos and Z_LVAL_P(offset) are all in that class and all end up in ordinary
# arithmetic that dies with "Cannot mix BigInt and other types".
#
# The mapping is DERIVED from the EMSCRIPTEN_KEEPALIVE signatures in the same tree rather than
# transcribed, so a VRZNO_REF bump cannot desync the table from the code it describes. A call site
# whose arity disagrees with its signature is a hard error rather than a silent rewrite.
#
# Idempotent, and keyed on the patched shape rather than on a marker comment.
#
# Usage:
#   PHP_VERSION=8.5 bash src/patch-vrzno-lp64.sh <php-wasm dir> [--verify]
#
# Only apply it to a wasm64 build. On wasm32 the retyped call sites are harmless but the EM_ASM
# coercions are pure noise, and a control arm should be byte-identical to what upstream ships.

set -euo pipefail

PHP_WASM_DIR="${1:?usage: patch-vrzno-lp64.sh <php-wasm dir> [--verify]}"
MODE="${2:-apply}"
PHP_VERSION="${PHP_VERSION:?PHP_VERSION must be set}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VRZNO_DIR="$PHP_WASM_DIR/third_party/php${PHP_VERSION}-src/ext/vrzno"

if [ ! -d "$VRZNO_DIR" ]; then
	echo "patch-vrzno-lp64: $VRZNO_DIR does not exist; run the source fetch first" >&2
	exit 1
fi

if ! command -v node > /dev/null 2>&1; then
	echo "patch-vrzno-lp64: node is required to rewrite the call sites" >&2
	exit 1
fi

if [ "$MODE" = "--verify" ]; then
	# reads are permitted on the container-owned tree, so verify needs none of the staging below
	node "$HERE/patch-vrzno-lp64.mjs" "$VRZNO_DIR" --verify
	echo "patch-vrzno-lp64: verified, every site is already LP64-correct"
	exit 0
fi

# THE WRITE MUST HAPPEN INSIDE THE BUILDER CONTAINER. php-src is created there, so on a Linux
# runner ext/vrzno is owned by the container's uid and a host-side write dies with EACCES -- which
# is the same reason fetch-deps.sh copies vrzno in from inside. Docker Desktop on macOS maps the
# host user, so a host-side write passes locally and fails in CI.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

node "$HERE/patch-vrzno-lp64.mjs" "$VRZNO_DIR" --out-dir "$STAGE"

REL="third_party/php${PHP_VERSION}-src/ext/vrzno"
wrote=0
for staged in "$STAGE"/*; do
	[ -f "$staged" ] || continue
	name="$(basename "$staged")"
	(
		cd "$PHP_WASM_DIR" || exit 1
		docker compose -p phpwasm run -T --rm \
			-e OUTER_UID="$(id -u)" -w /src \
			emscripten-builder bash -lc "cat > /src/$REL/$name"
	) < "$staged" || {
		echo "patch-vrzno-lp64: the in-container write of $name failed" >&2
		exit 1
	}
	wrote=$((wrote + 1))
done

if [ "$wrote" -eq 0 ]; then
	echo "patch-vrzno-lp64: nothing to write; the tree was already LP64-correct"
else
	echo "patch-vrzno-lp64: wrote $wrote rewritten source(s) into $REL"
fi

# a write that landed nowhere would leave a tree that links and misbehaves, so the apply asserts
# rather than reporting on the strength of the staging step alone
node "$HERE/patch-vrzno-lp64.mjs" "$VRZNO_DIR" --verify

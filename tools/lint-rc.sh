#!/usr/bin/env bash
# Evaluates every rc against php-wasm's own Makefile guards WITHOUT building.
#
# php-wasm's packages/*/static.mak carry $(error ...) checks for impossible
# combinations -- "WITH_DOM=static REQUIRES WITH_LIBXML=static" is one. make
# evaluates those at PARSE time, so a dry-run surfaces them in about a second
# instead of ten minutes into a QEMU link.
#
# usage: tools/lint-rc.sh [php-wasm-checkout]
#
# Skips with a notice when no checkout is available, so CI's lint job stays
# green without one.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECKOUT="${1:-${PHP_WASM_DIR:-/tmp/phpwasm-build/php-wasm}}"

if [ ! -f "$CHECKOUT/Makefile" ]; then
	echo "note: no php-wasm checkout at $CHECKOUT, skipping rc evaluation"
	echo "      pass one as \$1 or set PHP_WASM_DIR to run it"
	exit 0
fi

# the guards live in packages/*/static.mak, which the Makefile includes through
# $(shell npm ls -p); with no node_modules that expands to nothing and every
# guard silently disappears, which is the same defect that shipped binaries
# missing seven extensions
if [ ! -d "$CHECKOUT/node_modules" ]; then
	echo "note: $CHECKOUT has no node_modules, so packages/*/static.mak would not be"
	echo "      included and no guard could fire; skipping rather than passing falsely"
	exit 0
fi

MAKE_BIN="${MAKE_BIN:-make}"
failed=0
checked=0

# .rc.pending is included on purpose: an arm the push matrix cannot schedule is exactly the one
# nothing else checks, and evaluating a guard costs a second where a build costs hours
for rc in "$ROOT"/src/rc/*.rc "$ROOT"/src/rc/*.rc.pending; do
	[ -f "$rc" ] || continue
	name="$(basename "$rc" .pending)"
	name="$(basename "$name" .rc)"
	php_version="$(grep -m1 '^PHP_VERSION=' "$rc" | cut -d= -f2)"
	out=""
	if ! out="$(
		cd "$CHECKOUT" && "$MAKE_BIN" -n --no-print-directory \
			ENV_DIR="$CHECKOUT/" ENV_FILE="$rc" \
			PHP_VERSION="$php_version" IS_TTY=0 \
			__lint_rc_nonexistent_target__ 2>&1
	)"; then
		# a missing target is expected and fine; a $(error) from a guard is not
		# the guard arrives as `<any>.mak:17: *** <message>. Stop.`, so match the marker
		# anywhere rather than anchoring it to the top-level Makefile
		if echo "$out" | grep -q '\*\*\*'; then
			if echo "$out" | grep -qi 'No rule to make target'; then
				: # only the missing sentinel target, so the parse succeeded
			else
				echo "FAIL  $name"
				echo "$out" | grep -iE '\*\*\*|PLEASE CHECK' | head -4 | sed 's/^/      /'
				failed=$((failed + 1))
				checked=$((checked + 1))
				continue
			fi
		fi
	fi

	link_flags="$(grep -vE '^[[:space:]]*#' "$rc" | grep -oE -- '-Wl,[^ ]+' | tr '\n' ' ' || true)"
	if [ -n "$link_flags" ]; then
		if [ -n "${SKIP_LINK_CHECK:-}" ]; then
			echo "note  $name carries $link_flags; link check skipped by SKIP_LINK_CHECK"
		elif ! docker info > /dev/null 2>&1; then
			echo "note  $name carries $link_flags; no docker, so the link check could not run"
		else
			link_out=""
			if ! link_out="$(
				cd "$CHECKOUT" && docker compose -p phpwasm run -T --rm emscripten-builder bash -lc \
					"cd /tmp && printf 'int main(void){return 0;}' > lintrc.c && \
					 /emsdk/upstream/emscripten/emcc -flto -O2 $link_flags lintrc.c -o lintrc.mjs" 2>&1
			)" || echo "$link_out" | grep -qiE "unknown command line argument|unknown -z|unsupported"; then
				echo "FAIL  $name rejects its own link flags: $link_flags"
				echo "$link_out" | grep -iE "unknown|error|did you mean" | head -4 | sed 's/^/      /'
				failed=$((failed + 1))
				checked=$((checked + 1))
				continue
			fi
			echo "ok    $name (PHP $php_version) link flags accepted: $link_flags"
			checked=$((checked + 1))
			continue
		fi
	fi

	echo "ok    $name (PHP $php_version)"
	checked=$((checked + 1))
done

echo
if [ "$failed" -gt 0 ]; then
	echo "$checked rc file(s) evaluated, $failed failed"
	exit 1
fi
echo "$checked rc file(s) evaluated, 0 failed"

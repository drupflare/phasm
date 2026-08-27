#!/usr/bin/env bash
# Flips upstream php-wasm's USE_ZEND_ALLOC=0 to 1 in a php-wasm checkout.
#
# The setting is not ours: PHP on the shipping build answers
# getenv('USE_ZEND_ALLOC') === '0', and the literal is in the .wasm data section,
# so something in the upstream tree puts it in the environment before PHP starts.
# Zend's manager wants 2 MiB-aligned chunks from mmap and emscripten emulates that
# poorly, which is a defensible default and has never been re-scored.
#
# SEARCHES RATHER THAN ASSUMES A PATH, and exits non-zero when it finds nothing.
# A patch that silently matches zero files produces a build identical to the arm it
# is supposed to differ from, which then reads as "the allocator makes no
# difference" -- the exact failure this repository's --verify halves exist to stop.
#
#   bash src/patch-zend-alloc.sh <php-wasm-checkout>
#   bash src/patch-zend-alloc.sh <php-wasm-checkout> --verify
set -euo pipefail

SRC="${1:?usage: patch-zend-alloc.sh <php-wasm-checkout> [--verify]}"
MODE="${2:-apply}"
[ -d "$SRC" ] || {
	echo "no php-wasm checkout at $SRC"
	exit 1
}

# third_party holds the php-src tree, which sets nothing here; the flag is in
# php-wasm's own sources, so search those and keep the list printable
mapfile -t HITS < <(grep -rl 'USE_ZEND_ALLOC' "$SRC" \
	--exclude-dir=.git --exclude-dir=node_modules --exclude-dir=third_party 2> /dev/null || true)

if [ "$MODE" = "--verify" ]; then
	if grep -rq 'USE_ZEND_ALLOC=0' "$SRC" \
		--exclude-dir=.git --exclude-dir=node_modules --exclude-dir=third_party 2> /dev/null; then
		echo "USE_ZEND_ALLOC=0 is still present; the patch did not take"
		exit 1
	fi
	grep -rq 'USE_ZEND_ALLOC=1' "$SRC" \
		--exclude-dir=.git --exclude-dir=node_modules --exclude-dir=third_party 2> /dev/null || {
		echo "no USE_ZEND_ALLOC=1 anywhere; the patch did not take"
		exit 1
	}
	echo "verified: USE_ZEND_ALLOC=1"
	exit 0
fi

[ "${#HITS[@]}" -gt 0 ] || {
	echo "found no USE_ZEND_ALLOC anywhere under $SRC"
	echo "upstream moved it; find it before building this arm rather than shipping a no-op"
	exit 1
}

for f in "${HITS[@]}"; do
	echo "patching $f"
	sed -i 's/USE_ZEND_ALLOC=0/USE_ZEND_ALLOC=1/g' "$f"
done

bash "$0" "$SRC" --verify

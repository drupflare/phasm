#!/usr/bin/env bash
# Checks build-variant.sh's drop_configured. The configured stamp is written by configure as the
# builder's uid inside a php-src the builder created, so a host rm is refused on a rebuild; the
# removal has to go through the container. The function is pulled out of the script and run against
# a stub docker, so this needs no toolchain.
#
# Usage:
#   bash tools/test-build-variant.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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

TREE="$(mktemp -d -t phasmbv.XXXXXX)"
trap 'rm -rf "$TREE"' EXIT
LOG="$TREE/docker.log"
mkdir -p "$TREE/bin"
printf '#!/usr/bin/env bash\necho "$*" >> %s\n' "$LOG" > "$TREE/bin/docker"
chmod +x "$TREE/bin/docker"
export PATH="$TREE/bin:$PATH"

eval "$(sed -n '/^drop_configured() {/,/^}/p' "$HERE/src/build-variant.sh")"

echo "build-variant.sh: drop_configured"

STAMPED="$TREE/php-src"
mkdir -p "$STAMPED"
: > "$STAMPED/configured"
drop_configured "$STAMPED"
ok "a stamp present is removed through the builder image" \
	"$(grep -qF "run --rm -v $STAMPED:/w alpine:3 rm -f /w/configured" "$LOG" && echo 0 || echo 1)"

: > "$LOG"
drop_configured "$TREE/absent"
ok "a missing stamp runs no container" "$([ -s "$LOG" ] && echo 1 || echo 0)"
ok "a missing php-src is not created by the mount" "$([ -e "$TREE/absent" ] && echo 1 || echo 0)"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ]

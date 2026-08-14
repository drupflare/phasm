#!/usr/bin/env bash
# Links src/probes/sjlj-jspi-probe.c once per SjLj mode into assets/sjlj/.
#
# Both links run inside ONE container, and the emscripten cache lives in a
# DEDICATED host directory: with --rm and no cache mount, each emcc invocation
# rebuilds the whole sysroot (libc, libc++, compiler_rt) from scratch under QEMU,
# which costs more than the probe. /tmp/emsdk-cache-probe is deliberately NOT the
# /tmp/emsdk-cache the PHP build mounts - two builds writing one cache is a way to
# corrupt a 40-minute job.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/assets/sjlj"
mkdir -p "$OUT" /tmp/emsdk-cache-probe

# the same digest the PHP build is pinned to, so a probe result and a binary can be compared
BUILDER="$(bash "$ROOT/src/pin-builder-image.sh" --print)"

COMMON='-O2 -s JSPI=1 -s JSPI_EXPORTS=run_with_setjmp,run_plain,main -s MODULARIZE=1 -s EXPORT_ES6=1 -s EXPORT_NAME=SJLJ -s ENVIRONMENT=worker -s INVOKE_RUN=0 -s EXIT_RUNTIME=0 -s ALLOW_MEMORY_GROWTH=1 -s ERROR_ON_UNDEFINED_SYMBOLS=0'

docker run --rm --platform linux/amd64 \
	-v "$ROOT:/work" -v /tmp/emsdk-cache-probe:/emsdk/upstream/emscripten/cache \
	-w /work "$BUILDER" bash -euxo pipefail -c "
	emcc $COMMON -o assets/sjlj/emsjlj.mjs src/probes/sjlj-jspi-probe.c
	emcc $COMMON -s SUPPORT_LONGJMP=wasm -o assets/sjlj/wasmsjlj.mjs src/probes/sjlj-jspi-probe.c
	emcc -O2 -flto -c src/probes/sjlj-jspi-probe.c -o assets/sjlj/probe-lto.o
	emcc $COMMON -flto -s SUPPORT_LONGJMP=wasm -o assets/sjlj/ltolink.mjs assets/sjlj/probe-lto.o
"

for f in "$OUT"/emsjlj.mjs "$OUT"/wasmsjlj.mjs "$OUT"/ltolink.mjs; do
	[ -f "$f" ] || continue
	printf '%s invoke_refs=%s setThrew=%s bytes=%s\n' \
		"$(basename "$f")" \
		"$(grep -o 'invoke_' "$f" | wc -l | tr -d ' ')" \
		"$(grep -o 'setThrew' "$f" | wc -l | tr -d ' ')" \
		"$(stat -f%z "$f")"
done

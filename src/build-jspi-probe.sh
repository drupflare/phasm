#!/usr/bin/env bash
# Builds src/probes/jspi-probe.c into assets/jspi/park.wasm.
#
# clang --target=wasm32 -nostdlib rather than emcc: no emscripten runtime, no glue,
# so the JSPI wrapping in src/jspi-probe.js is the raw WebAssembly.Suspending /
# WebAssembly.promising API and nothing else can be blamed for a failure.
#
# Runs in the emscripten/emsdk image only because that is where a wasm-capable
# clang already lives on this machine; nothing emscripten-specific is used.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/assets/jspi"
mkdir -p "$OUT"

docker run --rm -v "$ROOT:/work" -w /work emscripten/emsdk:latest \
	/emsdk/upstream/bin/clang \
	--target=wasm32 -nostdlib -O2 \
	-Wl,--no-entry \
	-Wl,--export=run_loop \
	-Wl,--export=run_loop_nopark \
	-Wl,--export=run_loop_multi \
	-Wl,--export=memory \
	-Wl,--allow-undefined \
	-o assets/jspi/park.wasm \
	src/probes/jspi-probe.c

ls -la "$OUT/park.wasm"

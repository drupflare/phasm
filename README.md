# 🐘 phasm — a PHP interpreter that runs inside workerd

[![Build](https://github.com/drupflare/phasm/actions/workflows/build.yml/badge.svg)](https://github.com/drupflare/phasm/actions/workflows/build.yml)
[![Prettier](https://github.com/drupflare/phasm/actions/workflows/prettier.yml/badge.svg)](https://github.com/drupflare/phasm/actions/workflows/prettier.yml)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**The build that produces a PHP WebAssembly binary a real CMS can run on Cloudflare
Workers.** workerd forbids the runtime wasm codegen emscripten's dynamic linker needs, so no
shipped php-wasm build works there and every extension has to be statically linked.

---

## 📋 Table of Contents

- [Why Static](#-why-static)
- [What Is Here](#-what-is-here)
- [Variants](#-variants)
- [Prerequisites](#-prerequisites)
- [Building Locally](#-building-locally)
- [Inspecting a Build](#-inspecting-a-build)
- [Consumer Contract](#-consumer-contract)
- [VM Interrupt Patch](#-vm-interrupt-patch)
- [Working on the Scripts](#-working-on-the-scripts)
- [Related Repositories](#-related-repositories)
- [License](#-license)

---

## 🎯 Why Static

Emscripten's dynamic linker loads a side module by compiling wasm **at runtime**. workerd
does not allow that, so a dylink build cannot load a `.so` extension in a Worker at all —
not slowly, not at all. Every extension Drupal requires therefore has to be compiled in,
which makes `MAIN_MODULE=0` the only shape that works and turns the extension set into a
**budget decision** rather than a preference:

- `gd` costs **684,821 bytes**, so images are resized at delivery instead.
- Real `mbstring` costs **586,648 bytes gzipped**, which is more headroom than the consumer has.

The variant list below exists because of that second number. The extension set has moved a
free-tier verdict by 586,923 bytes and a boot figure by 241 ms, so "which extensions" is not a
question you answer once.

**Gzip is a comparator here, not the ceiling test.** The consumer ships the binary as a zstd frame
inflated at module scope, so what Cloudflare measures is a stream it cannot compress further, and a
variant's gzip total no longer decides whether it fits. `inspect-build.sh` reports gzip because it
is the figure every build can be compared on without a compressor in the loop.

`build-static.sh` verifies the outcome rather than trusting the flag: a `dylink.0` section
in the first 16 bytes means `MAIN_MODULE=0` did not take, and it says so.

---

## 🧰 What Is Here

| File                                             | What it does                                                                                                                        |
| ------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------- |
| `src/fetch-deps.sh`                              | fetches and builds the libraries php-wasm's Makefile does not; without it a build silently drops seven extensions and still exits 0 |
| `src/build-static.sh`                            | the real build: a `MAIN_MODULE=0` php-wasm with Drupal's extensions linked in                                                       |
| `src/build-variant.sh`                           | `build-static.sh` once per named variant, using `src/rc/<variant>.rc`                                                               |
| `src/rc/*.rc`                                    | extension and flag selection, one file per variant. Copied to `<checkout>/.php-wasm-rc`                                             |
| `src/patch-vm-interrupt.sh`                      | patches `zend_interrupt_function` to export `zend_wasm_slice_arm` / `_mask` / `_stat`, making a slice boundary possible             |
| `src/pin-builder-image.sh`                       | pulls the builder image **by digest** and tags it locally, so `docker compose` cannot resolve a different `:latest`                 |
| `src/inspect-build.sh`                           | reports what a produced build actually contains, and asserts the parts that can be asserted                                         |
| `src/probes/jspi-probe.c`, `sjlj-jspi-probe.c`   | the C probes that proved a JSPI-suspended wasm stack survives an invocation boundary                                                |
| `src/build-jspi-probe.sh`, `build-sjlj-probe.sh` | link those probes                                                                                                                   |
| `tools/lint-shell.sh`                            | `bash -n` over every script, plus the python embedded in `patch-vm-interrupt.sh`                                                    |
| `tools/test-patch-verify.sh`                     | drives `patch-vm-interrupt.sh` apply / `--verify` / `--revert` over a synthetic tree; wired as `bun run test`                       |

Two patches are applied to the php-wasm checkout rather than committed here, because they
edit upstream files; `build-static.sh`'s header records what and why. Both are idempotent
and keyed on the **patched shape**, never on a marker comment — a `dnl`-style marker inside
a macro argument is what broke the opcache `config.m4` patch twice.

---

## 🔩 Variants

One `.rc` file per variant, listed by `build.yml` rather than counted here. Each is a complete
configuration, not a diff, because the php-wasm
`configured` stamp is a plain file target: **a differing `CONFIGURE_FLAGS` in an rc is
silently ignored once that stamp exists**, so matching the tree's own `config.nice` is
mandatory rather than cosmetic.

**`long64` is the variant that ships.** It is `control85` plus a single compile flag,
`-DZEND_ENABLE_ZVAL_LONG64=1`, which gives `PHP_INT_SIZE` 8 on wasm32 pointers. `Zend/zend_long.h`
sets that macro from compiler predefines and derives `SIZEOF_ZEND_LONG` from it, so no generated
header is patched and no configure variable is involved; on wasm32 none of those predefines fires,
which is why a `-D` on the command line stands. `Makefile:209` clears `EXTRA_CFLAGS` after the rc is
included, so `build-variant.sh` passes it as a make variable and stamps the ABI as its own.

| Variant       | What it is                                      | Note                                                                                               |
| ------------- | ----------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| `long64`      | `control85` with 64-bit `zend_long`             | **the shipping build.** `PHP_INT_SIZE` 8 for +16,181 raw bytes over `control85`                    |
| `control`     | the 8.3 baseline the project started from       | reconstructed from the `CONFIGURE_COMMAND` string PHP compiles into the binary                     |
| `control84`   | `control` at PHP 8.4                            | the midpoint that separates version drift from the 8.5 `ext/uri` + `ext/lexbor` bulk               |
| `control85`   | `control` at PHP 8.5                            | the version Drupal 12 requires; `ext/uri` and `ext/lexbor` cannot be turned off from an rc         |
| `mbstring`    | `control` plus the real mbstring extension      | the actual `mb_substr()` fix, at +586,648 gzipped                                                  |
| `mergefunc85` | `control85` plus LLVM `-mergefunc` at LTO time  | reaches the link through `LTO_FLAG`, the one rc-settable variable that lands there                 |
| `nolto`       | `control` with LTO removed, `-O2` held constant | isolates what LTO is worth; see below                                                              |
| `jspi`        | `control` plus JSPI plus the VM interrupt patch | JSPI is closed as a shipping route; the arm stays because the patch is what it proves              |
| `jspimb`      | `mbstring` plus JSPI                            | carries the mbstring fix and the mbstring cost                                                     |
| `jspisjlj`    | `jspi` plus wasm SjLj                           | the variant that can actually suspend from inside PHP                                              |
| `jspimbsjlj`  | `jspimb` plus wasm SjLj                         | plain `-sJSPI` measured **broken** without it; see below                                           |
| `min85`       | 8.5 with only `dom`, `libxml2` and `vrzno`      | not shippable; it bounds how much of the ceiling the unavoidable extensions leave                  |
| `trim85`      | `control85` minus `yaml` and `zlib`             | needs the fflate bridge in the consumer before it can ship                                         |
| `nopdo85`     | `control85` minus `ext-pdo`                     | there is no `WITH_PDO` knob; php-wasm hardcodes `--enable-pdo`, so this drops it another way       |
| `noopcache85` | `min85` with `ext/opcache` dropped              | 8.5 removed the disable flag, so it takes a source patch; no symbol stub is needed on an NTS build |

Two more exist as `.rc.pending`. The extension is what keeps them out of the matrix: `plan` discovers
variants with `find src/rc -name '*.rc'`, and a subdirectory would not work, since that find recurses.

- **`wasm64`** is `control85` with the ABI changed and nothing else, so pointer width is the only
  variable. It builds and runs, and `long64` reaches the same `PHP_INT_SIZE` for 21x fewer raw bytes
  and four times the heap margin. Measured against `control85` it is also about 3% slower.
- **`nolexbor85`** needs a source patch to `ext/dom/php_dom.c`, its arginfo header and `element.c`;
  the `config.m4` deletions alone leave 21 symbols undefined, so `src/patch-drop-lexbor-html.sh`
  refuses by default rather than producing a tree that cannot link.

**`iconv` was built, measured and removed.** It cost **655,677 gzipped bytes** against `control`,
within 9% of what real `mbstring` costs, and it does not fix `mb_substr()`. Its rc is gone; the
measurement is kept here so it is not proposed again.

**`nolto` carries `LTO_FLAG=-O2` rather than an empty value.** `-O${OPTIMIZE}` reaches only the
link flags, so `LTO_FLAG` is the sole optimization in the compile half (php-wasm `Makefile:404`,
`405`, `408`). Emptying it compiles at `-O0`, and a function then exceeds Binaryen's per-function
locals cap: `wasm-emscripten-finalize` fails with `parse exception: too many locals`. Substituting
`-O2` holds the optimization level constant and removes only LTO.

**Why SjLj matters.** Emscripten's default SjLj
rewrites every call made from a `setjmp`-containing function into an `invoke_*` **JS**
trampoline, and `pib_run` opens a `zend_try` before it calls the VM. JSPI refuses to
suspend across a JS frame, so every `pib_run` on a plain `-sJSPI` build died with
`SuspendError: trying to suspend JS frames` — even `<?php echo PHP_VERSION;`.
`-sSUPPORT_LONGJMP=wasm` routes longjmp through wasm exception handling instead, so no JS
frame is introduced.

That flag is **not link-only**. Linking an LTO object compiled without it while the link
passes `-mllvm -exception-model=wasm` aborts `wasm-ld` with
`LLVM ERROR: Cannot select: ... catchret`, and `Makefile:209` clears `EXTRA_CFLAGS` after
the rc is included — so the compile half has to arrive as a make command-line variable:

```sh
MAKE_EXTRA='EXTRA_CFLAGS=-sSUPPORT_LONGJMP=wasm' bash src/build-variant.sh jspisjlj <checkout>
```

[`build.yml`](.github/workflows/build.yml) derives that automatically from whether the rc
mentions `SUPPORT_LONGJMP=wasm`, because forgetting it is a multi-hour mistake.

---

## 🧱 Prerequisites

- **Docker.** `build-static.sh` runs `make` on the **host**, not inside the builder image,
  because the Makefile shells out to `docker compose run` for the compile steps itself.
  Running it inside a container fails with `docker: command not found`. Run
  `bash src/pin-builder-image.sh` first: php-wasm's `docker-compose.yml` names the image
  with no tag, so without the pin the compiler is whatever `:latest` resolves to that day.
- **GNU make >= 4.4.** php-wasm's `Makefile:16` sets
  `MAKEFLAGS += ... --shuffle=random`, which is a 4.4 feature. macOS ships 3.81, so
  `brew install make` and use `gmake`; Ubuntu images have shipped 4.3 for several releases,
  so the workflow builds 4.4.1 from source when it finds an older one.
- **A php-wasm checkout**, passed as the first argument, from
  <https://github.com/seanmorris/php-wasm>.
- **Hours.** The builder image is x86_64 and runs under QEMU on Apple Silicon. A full
  configure alone is ~13-15 minutes there.

---

## 🚀 Building Locally

The shipping build needs no source patch and no extra make variables:

```sh
# pin the compiler before anything compiles; compose asks for an untagged image name
bash ~/phasm/src/pin-builder-image.sh

git clone https://github.com/seanmorris/php-wasm /tmp/phpwasm-build/php-wasm
cd ~/phasm
bash src/build-variant.sh long64 /tmp/phpwasm-build/php-wasm

bash src/inspect-build.sh vendor/static-long64 --expect-static
```

A variant carrying the VM interrupt patch takes two more steps, and their order is not stylistic:

```sh
cd /tmp/phpwasm-build/php-wasm

# fetch and patch php-src, putting Zend/zend_execute.c on disk
cp ~/phasm/src/rc/jspisjlj.rc .php-wasm-rc
gmake third_party/php8.3-src/patched \
	PHP_BUILDER_DIR="$PWD" IS_TTY=0 ENV_DIR="$PWD/" ENV_FILE="$PWD/.php-wasm-rc"

cd ~/phasm
bash src/patch-vm-interrupt.sh /tmp/phpwasm-build/php-wasm
MAKE_EXTRA='EXTRA_CFLAGS=-sSUPPORT_LONGJMP=wasm' \
	bash src/build-variant.sh jspisjlj /tmp/phpwasm-build/php-wasm

bash src/inspect-build.sh vendor/static-jspisjlj --expect-static --expect-jspi --expect-slice
```

`patch-vm-interrupt.sh` edits `Zend/zend_execute.c` under the source tree the rc's `PHP_VERSION`
selects, so that tree has to exist first. The `patched` target (php-wasm `Makefile:251`) is the step
that clones php-src and applies php-wasm's own patch. If you get the order wrong the patch script
exits 1 with `no zend_execute.c at ...` rather than quietly producing an unpatched binary.

`build-variant.sh` **refuses to overwrite an existing build**. Each `vendor/static-*` directory
takes hours to produce, and a discarded one cannot be reproduced without repeating that.

---

## 🔍 Inspecting a Build

```sh
bash src/inspect-build.sh vendor/static-long64
```

```txt
build:            vendor/static-long64
wasm:             php8.5-worker.mjs.wasm  raw=12234574  gzip=3571885
glue:             php8.5-worker.mjs  raw=865849  gzip=115245
gzip total:       3687130  (free ceiling 3145728, paid 10485760)
statically linked: yes
jspi:             no
slice exports:    none
php version:      8.5.2
configure tail:   '--disable-fiber-asm' ... '--enable-opcache' '--enable-vrzno' ...
```

Everything it prints is read from the artifact, not from the rc, so it reports what was
**built** rather than what was asked for. The extension list is recovered from the
`CONFIGURE_COMMAND` string PHP compiles into the binary; the slice exports are read from
the glue the same way the consumer's `src/runtime/mask.js` reads them at runtime.

Three optional flags turn the report into a gate, and each is derivable from the rc so
nothing is guessed:

| Flag              | Fails when                                                                  |
| ----------------- | --------------------------------------------------------------------------- |
| `--expect-static` | a `dylink` section is present, meaning workerd cannot load the binary       |
| `--expect-jspi`   | the glue wraps nothing in `WebAssembly.Suspending` / `.promising`           |
| `--expect-slice`  | the glue has no `_zend_wasm_slice_*`, meaning the VM interrupt patch missed |

Run over the nine 8.3-generation builds in the consumer's `vendor/`, that is the table
`TECHNICAL_REPORT.md` had to assemble by hand:

| Build                | gzip total (wasm + glue) | JSPI | Slice exports |
| -------------------- | ------------------------ | ---- | ------------- |
| `static-free`        | 2,774,709                | no   | none          |
| `static-jspisjljctl` | 2,865,992                | yes  | none          |
| `static-jspisjlj`    | 2,866,753                | yes  | arm,mask,stat |
| `static-o2`          | **2,876,855**            | no   | none          |
| `static-mbstring`    | 3,463,503                | no   | none          |
| `static-jspimb`      | 3,464,146                | yes  | none          |
| `static-jspimbsjlj`  | 3,455,763                | yes  | arm,mask,stat |
| `static-free-v1`     | 3,732,651                | no   | none          |
| `static`             | 6,345,097                | no   | none          |

Two independent cross-checks that the recovery is right: `static-o2`'s wasm gzip of
**2,757,693** is the figure `src/rc/jspi.rc` records, and its 2,876,855 total is the
figure `src/rc/control.rc` records. `static-jspisjljctl` reading JSPI-yes/slice-none is
also exactly what a control for `jspisjlj` should look like.

---

## 🔗 Consumer Contract

The split is clean because it is **one file plus one release asset**. In
[`drupflare/worker`](https://github.com/drupflare/worker), `src/runtime/php-binary.js` is
the single place the binary is chosen, and a wrangler `alias` swaps it. The site repo
depends on a released artifact and one import, nothing else.

**Mind the alias key.** esbuild matches it against the literal specifier written in the
source, so when `src/site-do.js` changed from `./php-binary.js` to
`./runtime/php-binary.js`, every alias key had to change too. A stale key fails **silently**
by bundling the default binary. Verify a swap by bundle size rather than by whether it
parses: `site-jspi` is 10,215 KiB against `site` at 12,108 KiB.

---

## ⚡ VM Interrupt Patch

`patch-vm-interrupt.sh` is the most valuable and the most fragile thing here, because it
patches PHP's own source.

**Why it works at all.** PHP already has every piece except the thing that fires:
`EG(vm_interrupt)` is an atomic bool the VM polls, `zend_interrupt_function` is the callback
it runs when that is set, and `Zend/zend_execute.c` defines the poll macros. Natively the
flag is raised by `SIGALRM`/`SIGPROF`; wasm has no signals, so nothing ever raises it and
the whole mechanism is dead code. The patch raises it from a countdown.

The patch goes in `Zend/zend_execute.c`, **not** in the generated `Zend/zend_vm_execute.h`:
the macros live in the hand-written file and the generated header is `#include`d at its
bottom, so one file covers every poll site and a `zend_vm_gen.php` regeneration cannot wipe
it.

Two safety rules are enforced in C rather than trusted to the host: the handler masks itself
for the duration of its own yield, so a suspension can never begin inside a suspension; and
`zend_wasm_slice_mask(1)`/`(0)` is exported so the host can bracket its SQL bridge call and
any transaction replay, where a fire during a mask sets no flag at all rather than deferring
one.

`--revert` exists so the same tree can build the unpatched control, because an
interrupt-overhead number is only meaningful against a binary that differs by this patch and
nothing else.

**What still has no assertion:** that the patch produced a _correct_ mechanism.
`--expect-slice` proves the three exports reached the binary, the failure this was
most exposed to, but nothing here calls `zend_wasm_slice_arm()` and checks that a boundary
actually fires. That test needs a workerd host, so it belongs in the consumer.

---

## 🔧 Working on the Scripts

None of this is needed to _run_ a build; it is needed to change one.

```sh
bun install             # prettier, markdownlint, husky
bun run lint            # bash -n over every script, plus the embedded python
bun run lint:shellcheck # needs the shellcheck binary
bun run lint:md
bun run prettier # writes; prettier:check only reports
```

- **Shell is formatted by prettier**, through
  [`prettier-plugin-sh`](https://github.com/un-ts/prettier/tree/master/packages/sh). Run
  `bun run prettier` rather than hand-aligning a continuation.
- **`shellcheck` is a separate binary** (`brew install shellcheck`, or it is already on the
  GitHub runners). `bun run lint` does not need it, so a bare checkout can
  still parse every script.
- **The C probes are formatted by `clang-format`** against [`.clang-format`](.clang-format).
  `SortIncludes` is off there: `sjlj-jspi-probe.c` includes `<setjmp.h>` ahead of
  the emscripten headers, and nothing in this repository can compile the probe to prove a
  reorder is safe.
- **The rc files are not formatted at all.** They are `make` variable assignments read with
  `-include`, so they are in [`.prettierignore`](.prettierignore) despite the shell-looking
  syntax.

The pre-commit hook runs `lint-staged`, then `tools/lint-shell.sh`, then `shellcheck` if the
binary is on `PATH` — so a commit made without it still gets the parse gate, and CI catches
the rest.

---

## 🔗 Related Repositories

| Repository                                                      | What it is                                                                               |
| --------------------------------------------------------------- | ---------------------------------------------------------------------------------------- |
| [`drupflare/worker`](https://github.com/drupflare/worker)       | the consumer: `src/runtime/php-binary.js` selects a binary and a wrangler alias swaps it |
| [`drupflare/rom`](https://github.com/drupflare/rom)             | `composer require drupflare/rom` - the Drupal 11 driver for Durable Object SQLite        |
| [`drupflare/drupflare`](https://github.com/drupflare/drupflare) | `composer require drupflare/drupflare` - mail, HTTP, images and logging over bindings    |
| [`seanmorris/php-wasm`](https://github.com/seanmorris/php-wasm) | upstream. This repository builds it; it does not fork it                                 |

Unlike the two Drupal modules, this repository publishes **no package**. Its output is a
release asset, so consumers pin a release tag rather than a version constraint.

---

## 📄 License

MIT (c) Gregory Mitchell 2026. See [LICENSE](LICENSE).

The interpreter this builds is PHP, under the PHP License, and php-wasm is its own project
under its own license. This repository's MIT terms cover the build scripts here, not the
artifacts they produce.

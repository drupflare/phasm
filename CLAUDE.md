# phasm

The PHP-to-wasm build toolchain: a `MAIN_MODULE=0` PHP 8.3 wasm binary that `workerd` can actually
instantiate. C, shell and Docker. It publishes **no package** - its output is a GitHub Release asset,
so consumers pin a release tag. `drupflare/worker` is the consumer.

## The binaries are the irreplaceable thing, and they are not in this repo

A `.wasm` plus its glue is 9-11 MB and there are nine variants. **Committing one, or reaching for a
submodule, is how this repository becomes unclonable.** `.gitignore` excludes `*.wasm` / `*.o` /
`*.a`, and `build.yml`'s `lint` job fails if any is ever tracked.

The consequence of losing one is permanent, not inconvenient: `worker/vendor/` holds **14 hand-built
binaries, 187 MB, on exactly one machine**, and four variants (`static-nolto`, `static-vmswitch`,
`static-control`, `static-iconv`) were already never kept, so the probe configs naming them cannot be
rebuilt. Three of those four (`nolto`, `control`, `iconv`) are **being rebuilt now** in a separate
session that owns the Docker work; leave their rc files alone while that runs, because even a
comment-only edit changes the sha256 the release body records. `vmswitch` is not being rebuilt and its rc file is deleted - see
the SWITCH A/B section below. Every `vendor/static-*` directory here cost hours of QEMU-emulated compilation.
`build-variant.sh` **refuses to overwrite an existing build** - that refusal is the guard, not an
inconvenience to route around.

## `src/` holds build INPUT, and that is deliberate

The scripts ARE the product here, so they live in `src/`. It was `build/` until 2026-08-12; `build/`
conventionally means build _output_, which this repository writes to `vendor/` and `assets/` (both
gitignored). If you are following an older note that says `build/build-variant.sh`, the path is now
`src/build-variant.sh`.

## SWITCH A/B is CLOSED as not-worth-unblocking, which is not the same as blocked

**Do not re-attempt this without first re-reading the last paragraph.** The distinction is the whole
record: the arms did fail, and that failure is not why the work stopped.

**`src/rc/vmswitch.rc` NO LONGER EXISTS, and that is deliberate rather than an oversight.** The arm
was deleted from `src/rc/`, so `build.yml`'s "all" enumeration (`find src/rc -name '*.rc'`) cannot
schedule it and nobody pays 30 minutes to 2 hours for a number that is already recorded below. The
question it existed to answer is answered: SWITCH dispatch costs **+129,760 gzipped bytes** in the
consuming repo, so it is a measurement artifact rather than a shipping candidate. This section stays
as the arm's provenance; reinstate the rc file only if the question changes.

**What was attempted.** `vmswitch` built `control` against a SWITCH-dispatch
Zend VM instead of the shipped CALL dispatch, to measure what dispatch kind is worth. Three link
configurations were tried to get a binary out of it: **full LTO**, **ThinLTO**, and **no-LTO**.

**All three produced no binary.** Every arm ended in the same place: `wasm-ld` exhausted the memory
available to it and died before emitting anything. The mechanism is specific rather than "it ran out
of RAM":

- SWITCH dispatch regenerates `Zend/zend_vm_execute.h` as ONE enormous function - a single `switch`
  over every opcode handler - where CALL dispatch emits a separate function per handler. The linker's
  peak working set tracks the largest translation unit, so this is not a marginal increase over
  `control`; it is a different shape of input.
- Full LTO makes it worse for the obvious reason: the whole program is one optimisation unit, so the
  giant function is resident alongside everything else.
- **ThinLTO did not help, and that is the informative arm.** Thin's point is to keep per-module
  summaries instead of one monolithic module, which bounds peak memory - but the peak here is driven
  by a SINGLE module that Thin cannot subdivide. So the arm that was supposed to route around the
  wall confirmed the wall is in the wrong place to route around.
- No-LTO removes the whole-program step and still failed, which is what says the cost is the
  translation unit rather than the optimisation strategy.

**Why it is closed rather than parked, and this is the part that decides it.** The measurement cannot
change a decision. Dispatch kind moves raw interpreter CPU and binary size, and **neither is in
either ceiling**: serving is bound by Worker requests and regeneration by rows written
(`worker/scripts/measure/free-envelope.ts`). Boot-directed work is saturated at **~1.01x** - raising
the fill batch 5 -> 100, a 20x cut in boot cost per fill, moved the regeneration ceiling by about 1%.
So a faster or smaller interpreter buys ~1% of a ceiling that is not the binding one. A result that
cannot reorder the work is not worth a build slot, whichever way it comes out.

**How to retest it, if boot ever becomes the binding constraint.** That is the condition, and it is
falsifiable: it holds when rows-per-fill has fallen far enough that `free-envelope.ts` reports
regeneration `boundBy: 'do'` rather than `'rows'`, because DO invocations are where the sliced boot
is charged. If that day comes:

1. Re-run `bun scripts/measure/free-envelope.ts --window` and confirm `boundBy` is `do`. If it still
   says `rows`, stop here - the answer has not changed.
2. Build `vmswitch` no-LTO first, not full LTO. It is the arm with the smallest peak and the one that
   isolates translation-unit size from optimisation strategy.
3. If it still dies, the next lever is splitting the generated `switch` across translation units,
   which is a `zend_vm_gen.php` change rather than a linker flag. **Not** more memory: this note
   deliberately records no memory figure and asks for no bump, because "give the linker more RAM" is
   the kind of workaround that converts a structural finding into an environment secret.

**What is NOT claimed here.** Nothing about whether SWITCH dispatch is faster or smaller than CALL on
wasm32. No arm produced a binary, so there is no measurement in either direction, and any number
attached to this variant later has to come from a build that actually linked.

## The wasm64 arm is `.rc.pending`, and `.rc.pending` now means "dispatch-only" rather than "hidden"

`src/rc/wasm64.rc.pending` is `control85.rc` with `-sMEMORY64=1` and nothing else changed, so the
only variable between the two is pointer width. It has never linked. It answers one question for the
consumer: what a Drupal heap peaks at when `zend_long` is 64 bits, which is the last thing standing
between this project and `PHP_INT_SIZE=8`.

**Score it on the AUTHENTICATED render, never a plain one.** A plain render reads 96.00 MiB on every
arm because the heap never grows past `INITIAL_MEMORY`; the peak lives in the authenticated column.
`worker/scripts/measure/growth-ladder.ts` takes a glue variant and a binary, so the new `.wasm` needs
no new instrument.

**Three mechanical facts, each of which would otherwise cost a multi-hour failure:**

- **`MEMORY64` is not link-only.** `Makefile:209` clears `EXTRA_CFLAGS` after the rc is included, so
  an rc physically cannot carry a compile flag. `build-variant.sh` greps the rc and passes
  `EXTRA_CFLAGS=-sMEMORY64=1` as a make command-line variable. This is the `-sSUPPORT_LONGJMP=wasm`
  trap with a second occupant.
- **The dependency prefix has an ABI and nothing used to check it.** `fetch-deps.sh` answers "already
  built" from a file's existence, so a wasm64 php-src would link a warm wasm32 `libxml2.a` and die at
  `wasm-ld` hours later. There is now an ABI stamp at `lib/.abi`; a change wipes the prefix and the
  dependency source trees. Same prefix either way, because php-wasm hardcodes `/src/lib`.
- **The `configured` stamp survives an ABI change.** `build-variant.sh` drops it when
  `.php-wasm-abi` in the checkout root disagrees. That stamp is in the checkout root rather than in
  php-src deliberately: php-src is container-created and not host-writable on a Linux runner.

**One item the research listed that turned out to already be done:** extending opcache's autoconf
shared-memory allowlist to `wasm64-unknown-emscripten`. `build-static.sh` forces
`php_cv_shm_mmap_anon=yes` by substitution rather than by adding a triple, so it is
triple-independent and already covers wasm64.

**`.rc.pending` changed meaning.** It used to mean an arm nothing could build, which also meant
nothing could check it. Now `build.yml`'s "Check the RC Exists" and `build-variant.sh` both fall back
to `<variant>.rc.pending`, so a pending arm is buildable BY NAME through `workflow_dispatch` while
staying invisible to the push matrix, and `lint-rc.sh` evaluates it against php-wasm's guards like
any other. Rename it to `.rc` the first time it links; that is what puts it in every push.

## Traps that cost hours, not minutes

Every one of these has already been paid for once.

- **The php-wasm `configured` stamp is a plain file target.** A differing `CONFIGURE_FLAGS` in an rc
  is **silently ignored** once that stamp exists, so each `src/rc/*.rc` is a complete configuration
  rather than a diff, and matching the tree's own `config.nice` is mandatory.
- **`-sSUPPORT_LONGJMP=wasm` is not link-only.** `Makefile:209` clears `EXTRA_CFLAGS` after the rc is
  included, so the compile half has to arrive as a make command-line variable
  (`MAKE_EXTRA='EXTRA_CFLAGS=-sSUPPORT_LONGJMP=wasm'`). Linking an LTO object compiled without it
  aborts `wasm-ld` with `LLVM ERROR: Cannot select: ... catchret`, hours in.
- **Order matters between the two patch steps.** `patch-vm-interrupt.sh` edits
  `third_party/php8.3-src/Zend/zend_execute.c`, so php-wasm's own `patched` target (`Makefile:251`)
  has to clone and patch php-src first.
- **The vmswitch regeneration must run under PHP 8.3 or 8.4, never 8.5.** 8.5 predefines
  `ZEND_VM_KIND`, so `zend_vm_gen.php`'s own `define()` silently fails and it emits
  `#define ZEND_VM_KIND` with an empty value. Hence `docker php:8.3-cli`.
- **Patches are keyed on the patched SHAPE, never on a marker comment.** A `dnl`-style marker inside
  a macro argument is what broke the opcache `config.m4` patch twice.
- **`make` runs on the HOST, not inside the builder image** - the Makefile shells out to
  `docker compose run` itself, so a container run dies with `docker: command not found`.
- **GNU make >= 4.4 is required** (`Makefile:16` uses `--shuffle=random`). macOS ships 3.81; Ubuntu
  images have shipped 4.3 for several releases, which is why CI builds 4.4.1 from source. It is
  fetched from ftpmirror.gnu.org, then mirrors.kernel.org, then ftp.gnu.org, verified by sha256,
  because ftp.gnu.org alone hung a job for nine minutes across four retries and then failed it.
- **php-wasm's extension flags come from `packages/*/static.mak`, which are included via
  `$(shell npm ls -p)` (`Makefile:244`), so a checkout with no `node_modules` silently builds a
  binary with NO extensions.** `npm ls -p` returns 41 paths in an installed tree and 1 in a bare
  clone, and `filter-out ${TOP_LEVEL}` strips that one, so zero fragments are included and
  `CONFIGURE_FLAGS` never gains `--enable-dom`, `--with-libxml`, `--enable-simplexml`,
  `--enable-xml`, `--with-yaml`, `--with-zlib` or `--enable-vrzno`. The flags that survive
  (`ctype`, `filter`, `session`, `tokenizer`, `opcache`) are the ones the top-level Makefile adds
  directly at lines 285-301, which is exactly the split observed in the artifacts. **CI must run
  `npm install` in the php-wasm checkout before building**; it did not, and eleven variants per run
  were published missing seven extensions each, `ext-dom` among them.
- **A patch must edit php-src INSIDE the builder container, not from the host.** php-src is created
  in the container, so on a Linux runner it is owned by the container's uid and the host can neither
  create a sibling NOR truncate the file: `awk > .new` and python's `open(path, "w")` both failed in CI
  with Permission denied, at one CI slot each. Route the edit through `docker compose run` exactly as
  `src/build-static.sh` does.
- **You cannot validate this locally without the container.** Docker Desktop on macOS maps the host
  user, so the local tree is host-owned and BOTH broken versions passed a local test. Validate a
  php-src patch by running it through the container against a real tree of the RIGHT PHP VERSION -- the
  opcache `PHP_NEW_EXTENSION` line is indented and bracket-free on 8.3 and unindented with a bracket on
  8.5, so a pattern tested on the wrong tree silently matches nothing.
- **`patch-vm-interrupt.sh` is NOT a proven model for this.** It only runs when the
  `patch_vm_interrupt` input is true, which defaults false on a push, so it has never executed in CI.
  It was cited here as the working example; that was an unverified claim.
- **A knowingly-unbuildable variant must be `.rc.pending`, not `.rc`.** `plan` discovers the matrix
  with `find src/rc -name '*.rc'`, which recurses, so a subdirectory does NOT hide one -- only the
  extension does. `src/rc/nolexbor85.rc` was added complete-but-unbuildable and failed every push
  until it was renamed; the patch script refusing was correct behaviour, and putting it in the matrix
  was the mistake.
- **Both 8.3 and 8.5 resolve to `ZEND_VM_KIND_CALL` on wasm32, so a version comparison is not
  contaminated by the VM.** `Zend/zend_vm_opcodes.h` tries HYBRID (needs `HAVE_GCC_GLOBAL_REGS`, which
  the wasm probe leaves `#undef`), then TAILCALL (gated on `__x86_64__ || __aarch64__`, and wasm32 is
  neither), then falls through to CALL. 8.5's new tailcall VM is unreachable on this target. Read this
  from a BUILT tree's generated header, never by grepping the source: the first attempt matched
  `ZEND_VM_KIND_HYBRID` inside `#if (ZEND_VM_KIND == ZEND_VM_KIND_HYBRID)` and would have recorded the
  opposite of the truth.
- **`WITH_SESSION=0` does not link**: `undefined symbol: ps_globals`, ext/session's globals struct,
  is referenced unconditionally. Core's `composer.json` requires `ext-session` anyway, so a variant
  without it could never ship even if it linked. Same for `filter`, `tokenizer` and `ctype`.
- **Evaluate a new rc with `bun run lint:rc` BEFORE pushing it.** php-wasm's `packages/*/static.mak`
  carry `$(error ...)` guards for impossible combinations and make fires them at PARSE time, so a
  dry-run catches them in about a second where CI takes ten minutes to reach the same conclusion. The
  guard only works against a checkout WITH `node_modules`, because the fragments are included through
  `$(shell npm ls -p)`; the script says it is skipping rather than passing when either is missing.
- **vmswitch needs more memory to LINK than the other variants**, and CI gives it 24 GB of swap for
  that reason. SWITCH dispatch regenerates `zend_vm_execute.h` into one enormous `execute_ex()`, and
  full-LTO codegen over a single function that size exhausted the runner: `wasm-ld` took SIGKILL
  while the other **9 of 11** variants linked fine with identical flags. Fix it with memory, never
  by lowering LTO for this variant alone - the variant exists to isolate SWITCH from CALL dispatch,
  so a second changed variable makes the comparison worthless. `build.yml` dumps `dmesg` on failure
  so the next occurrence proves OOM instead of inferring it.

## A link map does NOT give per-extension attribution on this build, and LTO is why

**MEASURED 2026-08-14, and it corrects what this file said an hour earlier.** The map is easy to get
and it answers nothing about extensions.

Getting one needs no code change. `SYMBOL_FLAGS` defaults to **empty** (`Makefile:351`), is
interpolated into `EXTRA_LDFLAGS_PROGRAM` (`Makefile:408`), and the `EXTRA_FLAGS+=${SYMBOL_FLAGS}`
append at `:355` is guarded by `ifdef SYMBOLS` rather than by `SYMBOL_FLAGS`, so overriding it
replaces nothing:

```sh
MAKE_EXTRA='SYMBOL_FLAGS=-Wl,-Map=/src/link-map.txt' bash src/build-variant.sh control <checkout>
```

That produced a 3,085,283-byte map. Parsed, it attributes **14,344,108 of 14,755,563 raw bytes --
97.2% -- to one object named `lto.tmp`**, across 21,613 of its lines. **Not a single `ext/`, `Zend/`,
`main/` or `sapi/` object name appears anywhere in it.** `LTO_FLAG` defaults to `-flto`
(`Makefile:140`) and reaches the compile half, so `wasm-ld` merges every bitcode unit into one
combined object before codegen and the per-extension provenance is gone before the map is written.

So "one link answers what a dozen builds answered piecemeal" is **false here**. The instrument is
real; LTO is what defeats it.

What is left, in order of usefulness:

- **Map a `nolto` build.** `src/rc/nolto.rc` already sets `LTO_FLAG=-O2`, so provenance survives.
  The bytes then belong to a build that is NOT the shipping one, which makes it triage for
  RELATIVE mass between extensions and nothing more.
- **Do not** try to recover attribution from a shipping artifact. It is stripped at `-O2`, so
  `strings` finds no symbol names and `twiggy`/`wasm-nm` have nothing to group by.
- **Never** subtract a map figure from a gzip budget: the map is **raw** bytes, and `-O3` already
  proved raw and gzipped move in opposite directions here.

## Which numbers here are trustworthy

**Byte sizes are.** Everything `inspect-build.sh` prints is read out of the produced artifact rather
than out of the rc, so it reports what was _built_, not what was asked for. Two independent
cross-checks confirm the recovery: `static-o2`'s wasm gzip of 2,757,693 is the figure
`src/rc/jspi.rc` records, and its 2,876,855 total is the figure `src/rc/control.rc` records.

**Timing figures are not, and never come from here.** An absolute CPU figure comes only from
`cpuTime` in `wrangler tail` on a deployed worker. Any boot or render millisecond quoted about a
variant belongs to the consumer's measurements; label a local number "local wall clock" or do not
state it.

A binary's identity is **the rc PLUS the php-wasm commit PLUS the builder-image digest PLUS the emcc
version**. `build.yml` records all four in the release body. Recording only the rc is how the drift
problem this project already paid for comes back in a new form.

**The builder image is pinned by DIGEST now, not by tag**, which is a change from what this file
used to say. `src/pin-builder-image.sh` holds the digest in one place, pulls it, tags it `:latest`
locally - php-wasm's `docker-compose.yml` names the image untagged, and compose leaves an
already-present tag alone - and then reads the digest back off the tag and fails on a mismatch, so a
pull that no-oped cannot leave the previous `:latest` in place. `build-sjlj-probe.sh` uses the same
reference via `--print`. Moving the pin is one edit; the script header records how the digest was
read out of the registry, and that is the procedure to repeat rather than `docker pull` + eyeball.

**A pin is not reproducibility.** Same rc, same php-wasm commit, same digest means the same
compiler; byte-identical output additionally depends on timestamps, embedded paths and LTO
nondeterminism, none of which has been measured here. Do not upgrade the claim without a build to
compare against a build.

## The patch has a --verify mode, and a skipped patch is now loud

`src/patch-vm-interrupt.sh` takes three modes: apply (default), `--verify`, `--revert`. Run
`--verify` after every apply, which `build.yml` now does as its own step.

**Why it is separate from the apply check.** An apply run on an already-patched tree prints
"already patched" and exits 0, which is indistinguishable from a fresh successful patch, and
neither says anything to a later step. An unpatched tree still builds and still boots, so a
silently skipped patch shows up only as a variant that cannot be interrupted - which reads as a
platform limit rather than as a missing build step.

`--verify` checks three shapes, not one, because a partial patch is what a marker comment would
miss: the tick block, `ZEND_WASM_TICK()` at **exactly two** poll sites, and the three
`EMSCRIPTEN_KEEPALIVE` slice exports. A block present with no tick compiles cleanly and does
nothing.

`build.yml` also asserts the **negative** for an unpatched control variant. Without that, a
deliberate control and an accidentally-skipped step produce identical builds and identical logs.

`bun run test` (`tools/test-patch-verify.sh`) drives all three modes over a synthetic tree with
the two anchor macros: **19 assertions**, no Docker, no php-src. It pins that `--revert` leaves
the file byte-identical, which is what makes the control a real A/B. Two bugs were found writing
it, both in a grep pattern for the C line-continuation backslash - a shell single-quoted pair is
one BRE backslash and a lone trailing one is a grep error - so if you edit those patterns, run
the test.

## Formatting

**Tabs rendered 4 wide, 100-char lines, LF, UTF-8, every language.** If a linter disagrees, turn the
linter rule off. C goes through `clang-format`, everything else through prettier; the tooling
enforces it, so run `bun run prettier` and `bun run format:c` and move on.

Three things the tooling cannot tell you:

- **`SortIncludes` is off on purpose.** `sjlj-jspi-probe.c` includes `<setjmp.h>` ahead of the
  emscripten headers and nothing here can compile the probe to prove a reorder is safe.
- **The `.rc` files are not formatted at all**, despite the shell-looking syntax: they are `make`
  variable assignments read with `-include`. Their content contract is upstream's; only their
  location is ours. Even a comment-only edit changes the sha256 the release body records.
- **Workflow YAML carries no comments.** Where a step needs explaining, the reason goes in the `run:`
  block as a shell comment, or in `README.md`.

Code comments: lowercase, terse, one line, no trailing period, only where the WHY is non-obvious.

## Commands

```sh
bun run lint             # bash -n over every script, plus the embedded python; needs nothing but bash
bun run lint:shellcheck  # needs the shellcheck binary
bun run lint:c           # needs the clang-format binary
bun run lint:md
bun run prettier:check
bun run inspect <dir>    # what a produced build actually contains
```

`bunx`, never `npx`.

## CI

Branch is **`master`**, not `main`.

**`release.yml` is the only workflow anyone presses, and it is a SYMBOLIC tag only.** It reads
`version` from `package.json` and cuts `v<version>` with a generated changelog; it attaches no
binaries (those come from `build.yml`) and it publishes to no registry. There is no `npm publish`,
no `registry-url`, no `NODE_AUTH_TOKEN` and no `packages: write` anywhere in it - do not add any.
`package.json` is `"private": true` with **no `files` field**, and both of those are correct:
people clone this repository and run the scripts, they do not install it. Keep the private flag.

Its shape follows `earth-app/cloud`'s `release.yml`, which is the house pattern, with one
deliberate addition: `git describe --tags --abbrev=0` is guarded with `|| echo ''`. Cloud has tags
and this repository has none, so the unguarded form makes the FIRST release the one release the
workflow can never cut. A `suffix` input and a branch-derived `prerelease` flag were removed on
2026-08-13; they were machinery for a distribution model this repository does not have.

**`build.yml` runs on push, PR and dispatch**, over a matrix of every variant, and it derives that
matrix by listing `src/rc/*.rc` - so adding an rc adds it to every automatic build with no second
edit. On a push it publishes a **prerelease** tagged `snapshot-<short sha>` carrying all nine
binaries; a PR builds and archives but never publishes, because a fork PR has no `contents: write`.
A snapshot is never promoted to a release.

- Assets are staged as `phasm-<variant>-<file>` before upload. Nine jobs uploading a bare
  `php8.3-worker.mjs.wasm` would collide on `merge-multiple`, and the filename is the only thing that
  tells a consumer which binary it holds.
- The `lint` job gates the matrix (`needs`), so a parse error cannot reach a build.
- The 350-minute timeout keeps a variant inside the 6-hour hosted-runner ceiling with room to fail
  cleanly rather than be killed mid-link.
- **The cost is real and deliberate: every push compiles PHP nine times.** The hosted runners are
  x86_64 and so is the builder image, so there is no QEMU tax there -- but if CI minutes become the
  problem, narrowing the automatic trigger is the lever, not dropping the matrix.

**No workflow here has ever run end to end.** Every step is derived from something verified, but the
build needs Docker plus hours, so the first real run is the one that finds whatever is left. Expect
the source-fetch step and the runner's disk headroom to be the first suspects.

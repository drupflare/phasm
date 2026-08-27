#!/usr/bin/env bash
# Build a STATIC (MAIN_MODULE=0) php-wasm with Drupal's required extensions
# linked in, because workerd forbids the runtime wasm codegen that emscripten's
# dynamic linker needs. Dylink builds cannot load .so extensions in Workers at
# all, so every extension Drupal requires must be compiled in.
#
# Extension selection lives in <checkout>/.php-wasm-rc.
#
# This runs make on the HOST, not inside the builder image: the Makefile shells
# out to `docker compose run` for the compile steps itself, so running it inside
# a container fails with "docker: command not found".
#
# Requires GNU make >= 4.4 (MAKEFLAGS uses --shuffle). macOS ships 3.81, so
# `brew install make` and use gmake.
set -euo pipefail

SRC="${1:?usage: build-static.sh <path-to-php-wasm-checkout>}"
OUT="${OUT:-$(cd "$(dirname "$0")/.." && pwd)/vendor/static}"
JOBS="${JOBS:-4}"

MAKE_BIN="$(command -v gmake || echo /opt/homebrew/opt/make/libexec/gnubin/make)"
[ -x "$MAKE_BIN" ] || {
	echo "need GNU make >= 4.4 (brew install make)"
	exit 1
}

cd "$SRC"

# php-src is created BY the builder container, so its tree is not writable by the host user and a
# host-side `perl -i` fails with "Cannot make temp name: Permission denied"
in_builder() {
	docker compose -p phpwasm run -T --rm \
		-e PKG_CONFIG_PATH=/src/lib/lib/pkgconfig \
		-e OUTER_UID="$(id -u)" \
		-w /src emscripten-builder bash -lc "$*"
}

# setjmp.h is the canary rather than an arbitrary header: it is the one PHP 8.4+ needs at CONFIGURE
# time, so a tree that passes this cannot fail that way. Emscripten reinstalls its own headers when
# the stamp is gone, which is a supported operation and adds only files.
sysroot_ok() {
	in_builder 'printf "#include <setjmp.h>\nint main(void){return 0;}\n" > /tmp/preflight.c && emcc -c /tmp/preflight.c -o /tmp/preflight.o' > /dev/null 2>&1
}
if ! sysroot_ok; then
	echo "emsdk sysroot cannot compile #include <setjmp.h>; reinstalling its headers"
	in_builder 'rm -f /emsdk/upstream/emscripten/cache/sysroot_install.stamp'
	sysroot_ok || {
		echo "emsdk sysroot still cannot compile <setjmp.h> after a header reinstall" >&2
		echo "  the mounted /tmp/emsdk-cache is damaged beyond a header reinstall; not building" >&2
		exit 1
	}
	echo "emsdk sysroot headers reinstalled"
fi

# Two local patches are required and are applied to a copy of the Makefile:
#
# 1. PHP_CONFIGURE_DEPS is empty when every extension is static, so
#    `$(MAKE) -j -l ${PHP_CONFIGURE_DEPS}` runs with no target, falls through to
#    the default goal, and recurses forever at 0% CPU. Guard it with $(if).
# 2. MAX_LOAD is nproc*1.5, but the x86_64 image runs under QEMU on Apple
#    Silicon and the emulated load average pegs high enough that make's -l gate
#    never starts a job.
# opcache: opcache's config.m4 detects shared memory with AC_RUN_IFELSE, which
# cannot execute a test binary under cross-compilation, so autoconf takes the
# third (cross-compiling) branch. That branch already carries an allowlist by
# host triple -- `*linux*` yields yes -- and emscripten's triple
# (wasm32-unknown-emscripten) simply is not in it. So the earlier
# "No supported shared memory caching support was found" was a cross-compilation
# artifact, not a statement about emscripten's capabilities.
#
# This matters because opcache.file_cache_only=1 needs no shared memory at
# runtime: ZendAccelerator.c accel_startup() returns SUCCESS before
# zend_shared_alloc_startup() when file_cache_only is set. Only configure has to
# be satisfied.
#
# Wasmer reported ~3x on WordPress from exactly this (620ms -> 205ms).
# Matching on $host_alias does not work here: emconfigure invokes ./configure
# without --host, so host_alias is empty and `case "" in *linux*)` never fires.
#
# That same missing --host is why patching ONLY the AC_RUN_IFELSE cross-compiling
# argument is inert, which cost a full 13-minute configure to learn: with no
# --host autoconf sets cross_compiling=no, so the generated configure takes the
# `ac_fn_c_try_run` branch, links conftest as wasm, cannot execute it, and lands
# on the FAILURE argument. Measured as
# "checking for mmap() using MAP_ANON shared memory support... no" followed by
# AC_MSG_ERROR at ext/opcache/config.m4:318. So the failure argument has to be
# forced too; the cross argument is kept for a future emconfigure that does pass
# --host. Forcing anon rather than posix is deliberate: HAVE_SHM_MMAP_ANON is
# what selects a shared-alloc backend in zend_shared_alloc.c, and with
# file_cache_only=1 that backend is never entered.
#
# The marker must never be `dnl` on a line that still has macro text after it:
# dnl comments to end of line, so an inline `[have_shm_mmap_anon=yes dnl mark]`
# eats the following `],[...` and buildconf then emits a configure that dies with
# "line 102036: syntax error: unexpected end of file". Idempotency is therefore
# keyed on the patched shape, not on a marker string.
OPCACHE_M4=third_party/php${PHP_VERSION:-8.3}-src/ext/opcache/config.m4
CONFIG_CACHE=.cache/config-cache
PATCHED_OPCACHE=0
if [ -f "$OPCACHE_M4" ] && grep -q 'php_cv_shm_mmap_anon' "$OPCACHE_M4"; then
	if grep -q 'php_cv_shm_mmap_anon=no' "$OPCACHE_M4"; then
		PATCHED_OPCACHE=1
		# both the FAILURE argument (the branch a --host-less emconfigure lands on) and the
		# cross argument's non-linux case
		in_builder "perl -pi -e 's/php_cv_shm_mmap_anon=no/php_cv_shm_mmap_anon=yes/g' '$OPCACHE_M4'"
		if grep -q 'php_cv_shm_mmap_anon=no' "$OPCACHE_M4"; then
			echo "opcache config.m4 patch did not apply; the shape it targets has changed" >&2
			grep -n 'php_cv_shm_mmap_anon' "$OPCACHE_M4" >&2 || true
			exit 1
		fi
		echo "patched opcache config.m4 (forced php_cv_shm_mmap_anon = yes, 8.4+ shape)"
	fi
	if [ -f "$CONFIG_CACHE" ] && grep -q 'php_cv_shm_mmap_anon=no' "$CONFIG_CACHE"; then
		perl -ni -e 'print unless /php_cv_shm_mmap_anon=/' "$CONFIG_CACHE"
		PATCHED_OPCACHE=1
		echo "dropped a cached php_cv_shm_mmap_anon=no from $CONFIG_CACHE"
	fi
elif [ -f "$OPCACHE_M4" ] && ! grep -q 'have_shm_mmap_anon=yes\],\[have_shm_mmap_anon=yes\]' "$OPCACHE_M4"; then
	PATCHED_OPCACHE=1
	in_builder "perl -0pi -e 's/\[have_shm_mmap_anon=yes\],\[have_shm_mmap_anon=no\],\[\n.*?\n\]\)/[have_shm_mmap_anon=yes],[have_shm_mmap_anon=no],[have_shm_mmap_anon=yes dnl phpwasm-forced\n])/s' '$OPCACHE_M4'"
	in_builder "perl -0pi -e 's/\[have_shm_mmap_posix=yes\],\[have_shm_mmap_posix=no\],\[have_shm_mmap_posix=no\]/[have_shm_mmap_posix=yes],[have_shm_mmap_posix=no],[have_shm_mmap_posix=yes]/' '$OPCACHE_M4'"
	# the branch autoconf actually takes when cross_compiling is "no"
	in_builder "perl -0pi -e 's/\[have_shm_mmap_anon=no\]/[have_shm_mmap_anon=yes]/' '$OPCACHE_M4'"
	# fatal, not a warning: an unapplied patch surfaces ~8 minutes later as
	# "No supported shared memory caching support" out of configure, which reads as a
	# toolchain problem rather than as this substitution missing
	if grep -q 'have_shm_mmap_anon=yes\],\[have_shm_mmap_anon=yes\]' "$OPCACHE_M4"; then
		echo "patched opcache config.m4 (forced SHM = yes on both the run and cross branches)"
	else
		echo "opcache config.m4 patch did not apply; the shape it targets has changed" >&2
		grep -n 'have_shm_mmap_anon' "$OPCACHE_M4" >&2 || true
		exit 1
	fi
fi
# buildconf regenerates ./configure from config.m4; without this the patch is inert.
# Only when the patch actually changed something, though: dropping the stamp
# unconditionally forces a ~14 min QEMU reconfigure on every resume and throws
# away a compile that only needed its remaining objects.
if [ "$PATCHED_OPCACHE" = 1 ]; then
	rm -f "third_party/php${PHP_VERSION:-8.3}-src/configured"
fi

# the single quotes are the point: this is literal Makefile text, not shell to expand
# shellcheck disable=SC2016
grep -q 'if $(strip ${PHP_CONFIGURE_DEPS})' Makefile || {
	cp Makefile Makefile.orig
	perl -pi -e 's/^\t\$\(MAKE\) -j\$\{CPU_COUNT\} -l\$\{MAX_LOAD\} \$\{PHP_CONFIGURE_DEPS\}$/\t\$(if \$(strip \$\{PHP_CONFIGURE_DEPS\}),\$(MAKE) -j\$\{CPU_COUNT\} -l\$\{MAX_LOAD\} \$\{PHP_CONFIGURE_DEPS\},\@true)/' Makefile
	echo "patched PHP_CONFIGURE_DEPS recursion guard"
}

# worker-mjs builds with ENVIRONMENT_IS_WORKER, which skips emscripten's html5
# library -- no document/window to shim, closer to workerd's globals.
export ENVIRONMENT=worker
export HOST_PROJECT_ROOT="$SRC"

# MAKE_EXTRA overrides an rc setting WITHOUT editing the rc, which matters
# because the Makefile's `configured` target lists ENV_FILE as a prerequisite:
# touching the rc costs a full ~15 min QEMU reconfigure. A command-line make
# variable beats an `-include`d assignment, so `MAKE_EXTRA=OPTIMIZE=3` relinks in
# place. Only safe for link-only settings (OPTIMIZE, LTO_FLAG, EXTRA_FLAGS);
# anything reaching CONFIGURE_FLAGS is silently ignored once the stamp exists.
#
# MAKE_EXTRA has to split into separate arguments, but a value can itself contain spaces
# -- EXTRA_CFLAGS='-DX=1 -mbulk-memory' is one assignment, not two. Plain word splitting
# broke exactly there: make read the second word as an option, printed its usage and
# exited 2, which reads as a compiler failure and is a quoting bug. eval respects the
# quotes the producer wrote; the input is this repo's own build scripts.
eval "MAKE_ARGS=(${MAKE_EXTRA:-})"
"$MAKE_BIN" worker-mjs \
	PHP_BUILDER_DIR="$SRC" \
	BUILD_TYPE=mjs \
	IS_TTY=0 \
	ENV_DIR="$SRC/" \
	ENV_FILE="$SRC/.php-wasm-rc" \
	CPU_COUNT="$JOBS" \
	MAX_LOAD=1000 \
	"${MAKE_ARGS[@]}"

mkdir -p "$OUT"
find . -maxdepth 2 -name '*.wasm' -newer .php-wasm-rc -exec cp {} "$OUT/" \; 2> /dev/null || true
find . -maxdepth 2 -name 'php*-worker.mjs' -newer .php-wasm-rc -exec cp {} "$OUT/" \; 2> /dev/null || true

echo "--- static build output ---"
ls -la "$OUT" || true
for f in "$OUT"/*.wasm; do
	[ -e "$f" ] || continue
	raw=$(stat -f%z "$f" 2> /dev/null || stat -c%s "$f")
	gz=$(gzip -9 -c "$f" | wc -c | tr -d ' ')
	printf '%s raw=%s gzip=%s (free limit 3145728, paid 10485760)\n' "$(basename "$f")" "$raw" "$gz"
	# dylink.0 in the first bytes means the build is still dynamically linked
	if head -c 16 "$f" | grep -qa dylink; then
		echo "  WARNING: still a dylink build -- MAIN_MODULE=0 did not take"
	else
		echo "  OK: no dylink section, statically linked"
	fi
done

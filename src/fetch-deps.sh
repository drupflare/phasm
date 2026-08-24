#!/usr/bin/env bash
# Fetches and builds the libraries php-wasm's Makefile does not fetch.
#
# `build.yml` ran end to end, exited 0, passed --expect-static and produced a binary missing
# seven extensions. php-wasm master's Makefile clones php-src and nothing else:
# `ARCHIVES=` at line 155 is empty with no `ARCHIVES+=` anywhere, though `configured` depends on
# it at line 323. So on a fresh checkout every configure flag that needs a library silently drops
# -- --enable-vrzno, --with-libxml, --enable-dom, --enable-simplexml, --enable-xml, --with-yaml,
# --with-zlib -- while the flags needing none still take, and the result looks healthy.
#
# Provenance: every source, ref and configure line below was recovered from a warm build tree
# that produced a verified binary, not guessed: the git remotes and tags come from each
# dependency's own .git, and the configure invocations come from the `$ ./configure ...` line
# each one records in its config.log. What is inferred rather than recovered is named inline.
#
# usage:
#   src/fetch-deps.sh <php-wasm-checkout> [--with-iconv]
#
# Idempotent: an already-built library is left alone, so a warm tree is not rebuilt.
#
# MEMORY64=1 builds every library for wasm64 instead. The ABI is recorded in a stamp beside the
# prefix, because "already built" is otherwise answered by a file whose ABI nobody checked: a
# wasm64 php-src linked against a warm wasm32 libxml2.a fails at wasm-ld, hours in, with an error
# that reads as a toolchain problem. An ABI change wipes the prefix and rebuilds.
set -euo pipefail

CHECKOUT="${1:?usage: fetch-deps.sh <php-wasm-checkout> [--with-iconv]}"
shift || true

WANT_ICONV=0
for arg in "$@"; do
	case "$arg" in
		--with-iconv) WANT_ICONV=1 ;;
		*)
			echo "unknown option: $arg"
			exit 2
			;;
	esac
done

[ -d "$CHECKOUT" ] || {
	echo "no such php-wasm checkout: $CHECKOUT"
	exit 2
}

PHP_VERSION="${PHP_VERSION:-8.3}"
THIRD="$CHECKOUT/third_party"
mkdir -p "$THIRD"

# every source, ref and configure line lives in deps.lock so the CI cache key can hash the
# dependency facts without hashing this script's logic
# shellcheck source=src/deps.lock
. "$(dirname "$0")/deps.lock"
PREFIX="$DEP_PREFIX"
CACHE="$DEP_CONFIG_CACHE"

# wasm64 changes the ABI of every object, so it is a property of the whole prefix rather than of one
# library. Same prefix either way: php-wasm's Makefile hardcodes /src/lib, so a second prefix would
# need edits in the Makefile, build-static.sh and the pkg-config path.
MEMORY64="${MEMORY64:-0}"
if [ "$MEMORY64" = 1 ]; then
	ABI=wasm64
	DEP_EMCC_CFLAGS="-sMEMORY64=1"
	# --host FORCES AUTOCONF INTO CROSS MODE, and that is the whole reason it is here.
	#
	# emconfigure passes no --host, so autoconf sets cross_compiling=no and answers "checking whether
	# we are cross compiling" by RUNNING a test binary under node. That works on wasm32 and fails on
	# wasm64 -- node cannot execute a memory64 module without a flag -- so libxml2's configure dies
	# with "cannot run C compiled programs" before a single object is built. Measured: run 32685347574.
	#
	# The triple is wasm32's on purpose. It selects which TESTS are skipped, not the ABI, which comes
	# from EMCC_CFLAGS above; every size check autoconf runs is compile-time and stays correct. The
	# honest triple is wasm64-unknown-emscripten and libxml2 2.9.10 ships a 2019 config.sub that
	# predates it, so naming it would trade this failure for "invalid configuration".
	DEP_HOST="--host=${DEP_HOST_TRIPLE:-wasm32-unknown-emscripten}"
else
	ABI=wasm32
	DEP_EMCC_CFLAGS=""
	# deliberately empty on wasm32: that path builds today without it, and adding a --host changes
	# which branches autoconf takes across every dependency
	DEP_HOST=""
fi
ABI_STAMP="$CHECKOUT/lib/.abi"

# Runs a command inside the emscripten builder, which is what makes the output wasm rather than
# native. EMCC_CFLAGS is appended by emcc to every invocation, which is what carries the ABI into
# each dependency's own configure and make without patching any of their build systems.
PKG_CONFIG_PATH_IN_BUILDER=/src/lib/lib/pkgconfig
in_builder() {
	local workdir="$1"
	shift
	(
		cd "$CHECKOUT" || exit 1
		docker compose -p phpwasm run -T --rm \
			-e PKG_CONFIG_PATH="$PKG_CONFIG_PATH_IN_BUILDER" \
			-e EMCC_CFLAGS="$DEP_EMCC_CFLAGS" \
			-e OUTER_UID="$(id -u)" \
			-w "$workdir" emscripten-builder bash -lc "$*"
	)
}

have_lib() { [ -f "$CHECKOUT/lib/lib/$1" ]; }

# Builds the SIDE MODULE php-wasm's own makefiles would build, with the ABI flag they omit.
#
# `packages/php-wasm-{zlib,yaml,libxml}/static.mak` each turn their `.a` into a `.so` through their
# OWN `docker compose run`, so neither this script's EMCC_CFLAGS nor the environment reaches them --
# two of the three even pass `-e EMCC_CFLAGS=...` explicitly and clobber it. On wasm32 that is
# harmless; on wasm64 wasm-ld refuses with `must specify -mwasm64 to process wasm64 object files`,
# measured on run 32687463470.
#
# Building it here first means make finds the target present and newer than its prerequisite and
# skips the recipe. A stub would also satisfy the timestamp and is not what this does: with
# MAIN_MODULE=0 nothing links these, but leaving a real artifact means a future dylink build finds
# a correct one rather than an empty file.
side_module() {
	local lib="$1" extra="$2"
	[ "$MEMORY64" = 1 ] || return 0
	echo "  pre-building ${lib}.so as wasm64, which php-wasm's own recipe would not"
	in_builder /src "emcc -shared -o ${PREFIX}lib/${lib}.so -fPIC ${extra} -sSIDE_MODULE=1 -O2 -sMEMORY64=1 -Wl,--whole-archive ${PREFIX}lib/${lib}.a"
}

# A prefix built for the other ABI is worse than an empty one: have_lib() would answer yes and the
# mismatch surfaces at the final link rather than here. Wipe it, and the dependency source trees
# with it, since their configure output is ABI-specific too.
if [ -d "$CHECKOUT/lib" ] && [ "$(cat "$ABI_STAMP" 2> /dev/null || echo wasm32)" != "$ABI" ]; then
	echo "prefix holds $(cat "$ABI_STAMP" 2> /dev/null || echo wasm32) libraries and this is a $ABI build; rebuilding them"
	rm -rf "${CHECKOUT:?}/lib"
	for dep in libxml2 libyaml zlib "libiconv-$LIBICONV_VERSION"; do
		rm -rf "${THIRD:?}/$dep"
	done
	in_builder /src "rm -f $CACHE" || true
fi
mkdir -p "$CHECKOUT/lib"
printf '%s\n' "$ABI" > "$ABI_STAMP"
echo "building dependencies for $ABI"

# macOS has shasum and no sha256sum; CI is the other way round
sha256_of() {
	if command -v sha256sum > /dev/null 2>&1; then
		sha256sum "$1" | cut -d' ' -f1
	else
		shasum -a 256 "$1" | cut -d' ' -f1
	fi
}

# Downloads $2 to $3, verifying it against sha256 $1, taking the first source in $2 that serves
# the expected bytes. A short connect timeout matters: ftp.gnu.org has hung a CI job for nine
# minutes across four retries before failing.
fetch_verified() {
	local want="$1" urls="$2" out="$3" url got
	for url in $urls; do
		echo "  trying $url"
		if curl -fsSL --connect-timeout 15 --max-time 600 --retry 2 --retry-connrefused \
			"$url" -o "$out"; then
			got="$(sha256_of "$out")"
			if [ "$got" = "$want" ]; then
				return 0
			fi
			echo "  $url served $got, wanted $want" >&2
		fi
		rm -f "$out"
	done
	echo "every source failed for $out" >&2
	return 1
}

# --- libxml2, and dom/simplexml/xml all fail without it -----------------------
if have_lib libxml2.a; then
	echo "libxml2: already built"
else
	echo "libxml2: fetching v2.9.10"
	[ -d "$THIRD/libxml2" ] || git clone --depth 1 --branch "$LIBXML2_REF" \
		"$LIBXML2_REPO" "$THIRD/libxml2"
	# autogen.sh rather than configure: the git checkout ships no configure script, only the
	# autotools inputs. A release TARBALL would have one; the tag does not.
	in_builder /src/third_party/libxml2 "
		[ -f configure ] || ./autogen.sh --help > /dev/null 2>&1 || autoreconf -fi
		emconfigure ./configure $LIBXML2_CONFIGURE $DEP_HOST --prefix=$PREFIX --cache-file=$CACHE
		emmake make -j\"\$(nproc)\" && emmake make install
	"
	side_module libxml2 -flto
fi

# --- libyaml, for the yaml extension -----------------------------------------
if have_lib libyaml.a; then
	echo "libyaml: already built"
else
	echo "libyaml: fetching 0.2.5"
	[ -d "$THIRD/libyaml" ] || git clone --depth 1 --branch "$LIBYAML_REF" \
		"$LIBYAML_REPO" "$THIRD/libyaml"
	in_builder /src/third_party/libyaml "
		[ -f configure ] || ./bootstrap
		emconfigure ./configure $LIBYAML_CONFIGURE $DEP_HOST --prefix=$PREFIX --cache-file=$CACHE
		emmake make -j\"\$(nproc)\" && emmake make install
	"
	side_module libyaml -flto
fi

# --- zlib, which has its own configure rather than autotools ------------------
if have_lib libz.a; then
	echo "zlib: already built"
else
	echo "zlib: fetching v1.3.1"
	[ -d "$THIRD/zlib" ] || git clone --depth 1 --branch "$ZLIB_REF" \
		"$ZLIB_REPO" "$THIRD/zlib"
	# --static is required, not optional: without it zlib builds libz.so AND links two test
	# programs against it, and wasm-ld rejects a .so with "unknown file type". The warm tree's
	# configure.log records `./configure --prefix=/src/lib/ --static`.
	in_builder /src/third_party/zlib "
		emconfigure ./configure $ZLIB_CONFIGURE --prefix=$PREFIX
		emmake make -j\"\$(nproc)\" && emmake make install
	"
	side_module libz ""
fi

# --- libiconv, ONLY for the iconv variant ------------------------------------
# control.rc sets WITH_ICONV=0, so this is off by default. Measured, the iconv variant is
# 386,808 bytes OVER the free ceiling and does not fix mb_substr(), so it is not a default.
if [ "$WANT_ICONV" = 1 ]; then
	if have_lib libiconv.a; then
		echo "libiconv: already built"
	else
		echo "libiconv: fetching $LIBICONV_VERSION"
		[ -d "$THIRD/libiconv-$LIBICONV_VERSION" ] || {
			fetch_verified "$LIBICONV_SHA256" "$LIBICONV_URLS" \
				"/tmp/libiconv-$LIBICONV_VERSION.tar.gz"
			tar -xzf "/tmp/libiconv-$LIBICONV_VERSION.tar.gz" -C "$THIRD"
		}
		in_builder "/src/third_party/libiconv-$LIBICONV_VERSION" "
			emconfigure ./configure $LIBICONV_CONFIGURE $DEP_HOST --prefix=$PREFIX \
				--cache-file=$CACHE
			emmake make -j\"\$(nproc)\" && emmake make install
		"
	fi
fi

# --- the two PHP extensions, which are SOURCE rather than libraries ----------
#
# These are copied into php-src/ext/ rather than linked from third_party: that is how the warm
# tree carries them (both are real directories under ext/, not symlinks), and php-src's configure
# only discovers an extension that is physically in ext/.
SRC="$THIRD/php${PHP_VERSION}-src"
if [ ! -d "$SRC" ]; then
	echo "note: $SRC does not exist yet; run the Makefile's source fetch first, then re-run this"
	echo "      (the extensions below are copied INTO php-src/ext/ and need it present)"
	exit 0
fi

if [ -d "$SRC/ext/vrzno" ]; then
	echo "vrzno: already in ext/"
else
	echo "vrzno: fetching c3aa3b9"
	[ -d "$THIRD/vrzno" ] || git clone "$VRZNO_REPO" "$THIRD/vrzno"
	git -C "$THIRD/vrzno" checkout --quiet "$VRZNO_REF"
	# copied INSIDE the builder: php-src is created by the container, so its ext/ is not
	# writable by the host user and a host-side cp fails with "Permission denied"
	in_builder /src/third_party "cp -R vrzno php${PHP_VERSION}-src/ext/vrzno"
fi

if [ -d "$SRC/ext/yaml" ]; then
	echo "yaml: already in ext/"
else
	echo "yaml: fetching pecl yaml $YAML_EXT_VERSION"
	[ -d "$THIRD/php${PHP_VERSION}-yaml" ] || {
		fetch_verified "$YAML_EXT_SHA256" "$YAML_EXT_URLS" "/tmp/yaml-$YAML_EXT_VERSION.tgz"
		mkdir -p "$THIRD/php${PHP_VERSION}-yaml"
		tar -xzf "/tmp/yaml-$YAML_EXT_VERSION.tgz" -C "$THIRD/php${PHP_VERSION}-yaml" \
			--strip-components=1
	}
	in_builder /src/third_party "cp -R php${PHP_VERSION}-yaml php${PHP_VERSION}-src/ext/yaml"
fi

echo
echo "deps ready under $CHECKOUT/lib/lib and $SRC/ext"
echo "verify with: src/inspect-build.sh <out> --expect-static --expect-rc=src/rc/control.rc"

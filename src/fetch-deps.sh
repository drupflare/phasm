#!/usr/bin/env bash
# Fetches and builds the libraries php-wasm's Makefile does NOT fetch.
#
# WHY THIS EXISTS. `build.yml` ran end to end, exited 0, passed --expect-static and produced a
# binary missing SEVEN extensions. php-wasm master's Makefile clones php-src and nothing else:
# `ARCHIVES=` at line 155 is empty with no `ARCHIVES+=` anywhere, though `configured` depends on
# it at line 323. So on a fresh checkout every configure flag that needs a library silently drops
# -- --enable-vrzno, --with-libxml, --enable-dom, --enable-simplexml, --enable-xml, --with-yaml,
# --with-zlib -- while the flags needing none still take, and the result looks healthy.
#
# PROVENANCE. Every source, ref and configure line below was RECOVERED from a warm build tree
# that produced a verified binary, not guessed: the git remotes and tags come from each
# dependency's own .git, and the configure invocations come from the `$ ./configure ...` line
# each one records in its config.log. What is inferred rather than recovered is named inline.
#
# usage:
#   src/fetch-deps.sh <php-wasm-checkout> [--with-iconv]
#
# Idempotent: an already-built library is left alone, so a warm tree is not rebuilt.
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

# Runs a command inside the emscripten builder, which is what makes the output wasm rather than
# native.
PKG_CONFIG_PATH_IN_BUILDER=/src/lib/lib/pkgconfig
in_builder() {
	local workdir="$1"
	shift
	(
		cd "$CHECKOUT" || exit 1
		docker compose -p phpwasm run -T --rm \
			-e PKG_CONFIG_PATH="$PKG_CONFIG_PATH_IN_BUILDER" \
			-e OUTER_UID="$(id -u)" \
			-w "$workdir" emscripten-builder bash -lc "$*"
	)
}

have_lib() { [ -f "$CHECKOUT/lib/lib/$1" ]; }

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
		emconfigure ./configure $LIBXML2_CONFIGURE --prefix=$PREFIX --cache-file=$CACHE
		emmake make -j\"\$(nproc)\" && emmake make install
	"
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
		emconfigure ./configure $LIBYAML_CONFIGURE --prefix=$PREFIX --cache-file=$CACHE
		emmake make -j\"\$(nproc)\" && emmake make install
	"
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
			emconfigure ./configure $LIBICONV_CONFIGURE --prefix=$PREFIX \
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

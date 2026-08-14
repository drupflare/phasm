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

# the prefix every recovered configure line used; php-src's configure looks here for the .a files
PREFIX=/src/lib/
# a shared cache-file was in every recovered invocation; it is what makes a second configure cheap
CACHE=/tmp/config-cache

# Runs a command inside the emscripten builder, which is what makes the output wasm rather than
# native. INFERRED, not recovered: the config.log records the container's hostname but not the
# `docker run` that produced it. `docker compose run` matches how the Makefile drives the builder.
in_builder() {
	local workdir="$1"
	shift
	docker compose -f "$CHECKOUT/docker-compose.yml" run --rm \
		-w "$workdir" emscripten-builder bash -lc "$*"
}

have_lib() { [ -f "$CHECKOUT/lib/lib/$1" ]; }

# --- libxml2, and dom/simplexml/xml all fail without it -----------------------
if have_lib libxml2.a; then
	echo "libxml2: already built"
else
	echo "libxml2: fetching v2.9.10"
	[ -d "$THIRD/libxml2" ] || git clone --depth 1 --branch v2.9.10 \
		https://gitlab.gnome.org/GNOME/libxml2.git "$THIRD/libxml2"
	# autogen.sh rather than configure: the git checkout ships no configure script, only the
	# autotools inputs. A release TARBALL would have one; the tag does not.
	in_builder /src/third_party/libxml2 "
		[ -f configure ] || ./autogen.sh --help > /dev/null 2>&1 || autoreconf -fi
		emconfigure ./configure --with-http=no --with-ftp=no --with-python=no \
			--with-threads=no --prefix=$PREFIX --cache-file=$CACHE
		emmake make -j\"\$(nproc)\" && emmake make install
	"
fi

# --- libyaml, for the yaml extension -----------------------------------------
if have_lib libyaml.a; then
	echo "libyaml: already built"
else
	echo "libyaml: fetching 0.2.5"
	[ -d "$THIRD/libyaml" ] || git clone --depth 1 --branch 0.2.5 \
		https://github.com/yaml/libyaml.git "$THIRD/libyaml"
	in_builder /src/third_party/libyaml "
		[ -f configure ] || ./bootstrap
		emconfigure ./configure --prefix=$PREFIX --enable-shared=no --enable-static=yes \
			--cache-file=$CACHE
		emmake make -j\"\$(nproc)\" && emmake make install
	"
fi

# --- zlib, which has its own configure rather than autotools ------------------
if have_lib libz.a; then
	echo "zlib: already built"
else
	echo "zlib: fetching v1.3.1"
	[ -d "$THIRD/zlib" ] || git clone --depth 1 --branch v1.3.1 \
		https://github.com/madler/zlib.git "$THIRD/zlib"
	# zlib's configure takes no --enable-static; static is its default and the recovered
	# Makefile records only `prefix =/src/lib/`
	in_builder /src/third_party/zlib "
		emconfigure ./configure --prefix=$PREFIX
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
		echo "libiconv: fetching 1.17"
		[ -d "$THIRD/libiconv-1.17" ] || {
			curl -fsSL https://ftp.gnu.org/pub/gnu/libiconv/libiconv-1.17.tar.gz \
				-o /tmp/libiconv-1.17.tar.gz
			tar -xzf /tmp/libiconv-1.17.tar.gz -C "$THIRD"
		}
		in_builder /src/third_party/libiconv-1.17 "
			emconfigure ./configure --prefix=$PREFIX --enable-shared=no --enable-static=yes \
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
	[ -d "$THIRD/vrzno" ] || git clone https://github.com/seanmorris/vrzno.git "$THIRD/vrzno"
	git -C "$THIRD/vrzno" checkout --quiet c3aa3b9
	cp -R "$THIRD/vrzno" "$SRC/ext/vrzno"
fi

if [ -d "$SRC/ext/yaml" ]; then
	echo "yaml: already in ext/"
else
	echo "yaml: fetching pecl yaml 2.3.0"
	[ -d "$THIRD/php${PHP_VERSION}-yaml" ] || {
		curl -fsSL https://pecl.php.net/get/yaml-2.3.0.tgz -o /tmp/yaml-2.3.0.tgz
		mkdir -p "$THIRD/php${PHP_VERSION}-yaml"
		tar -xzf /tmp/yaml-2.3.0.tgz -C "$THIRD/php${PHP_VERSION}-yaml" --strip-components=1
	}
	cp -R "$THIRD/php${PHP_VERSION}-yaml" "$SRC/ext/yaml"
fi

echo
echo "deps ready under $CHECKOUT/lib/lib and $SRC/ext"
echo "verify with: src/inspect-build.sh <out> --expect-static --expect-rc=src/rc/control.rc"

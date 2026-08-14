#!/usr/bin/env bash
# Reports what a produced build actually contains, and optionally asserts it.
#
# WHY THIS EXISTS. A binary's identity used to be "the .rc plus whatever the
# checkout was that day", and every extension table in TECHNICAL_REPORT.md was
# assembled by hand from `strings`. That is how a whole round of functional numbers
# got measured on a binary that could never ship (RULE 0b). This is the same
# recovery, mechanised, so a release can record what it is shipping.
#
# Everything here reads the artifact rather than the rc, so it reports what was
# BUILT, not what was asked for. Four facts, in the order they change a verdict:
#
#   1. gzipped size, against the 3 MiB free and 10 MiB paid ceilings
#   2. whether MAIN_MODULE=0 took -- a dylink section means it did not, and
#      workerd cannot load the result at all
#   3. whether the glue carries JSPI (WebAssembly.Suspending / .promising)
#   4. which slice exports patch-vm-interrupt.sh left behind, read the same way
#      src/runtime/mask.js's vmFromBinary() reads them in the consumer
#
# The extension list is recovered from the CONFIGURE_COMMAND string PHP compiles
# into the binary, which is the technique src/rc/control.rc documents.
#
# usage:
#   src/inspect-build.sh <build-dir> [--expect-static] [--expect-jspi] [--expect-slice] [--expect-no-opcache]
#
# The --expect flags turn the report into a gate: each one that does not hold is
# printed as FAIL and the script exits 1.
set -euo pipefail

DIR="${1:?usage: inspect-build.sh <build-dir> [--expect-static] [--expect-jspi] [--expect-slice] [--expect-no-opcache]}"
shift || true

EXPECT_STATIC=0
EXPECT_JSPI=0
EXPECT_SLICE=0
EXPECT_NO_OPCACHE=0
EXPECT_RC=""
for arg in "$@"; do
	case "$arg" in
		--expect-static) EXPECT_STATIC=1 ;;
		--expect-jspi) EXPECT_JSPI=1 ;;
		--expect-slice) EXPECT_SLICE=1 ;;
		--expect-no-opcache) EXPECT_NO_OPCACHE=1 ;;
		--expect-rc=*) EXPECT_RC="${arg#--expect-rc=}" ;;
		*)
			echo "unknown option: $arg"
			exit 2
			;;
	esac
done

[ -d "$DIR" ] || {
	echo "no such build directory: $DIR"
	exit 2
}

WASM="$(find "$DIR" -maxdepth 1 -name '*.wasm' | head -1)"
GLUE="$(find "$DIR" -maxdepth 1 -name '*.mjs' | head -1)"
[ -n "$WASM" ] || {
	echo "no .wasm in $DIR"
	exit 2
}

size_of() { stat -f%z "$1" 2> /dev/null || stat -c%s "$1"; }

# LEVEL 6 AND ONE STREAM, because that is what the meter does. wrangler compresses
# the bundle it builds at gzip's default level over a single stream spanning both
# uploaded files. This script used `gzip -9` summed per file, which reported 25,260
# LOW on control85 and 22,475 low on noopcache85 -- optimistic, against a hard cap.
# Measured, the LEVEL is the entire error: two streams versus one differed by 7 and
# 82 bytes, because the wasm compresses to near-incompressible and the glue has
# nothing useful to back-reference in it.
RAW="$(size_of "$WASM")"
GZ="$(gzip -6 -c "$WASM" | wc -c | tr -d ' ')"
GLUE_RAW=0
GLUE_GZ=0
if [ -n "$GLUE" ]; then
	GLUE_RAW="$(size_of "$GLUE")"
	GLUE_GZ="$(gzip -6 -c "$GLUE" | wc -c | tr -d ' ')"
	TOTAL_GZ="$(cat "$WASM" "$GLUE" | gzip -6 -c | wc -c | tr -d ' ')"
else
	TOTAL_GZ="$GZ"
fi

# dylink.0 in the first bytes means the build is still dynamically linked
IS_STATIC=1
head -c 16 "$WASM" | grep -qa dylink && IS_STATIC=0

has_in_glue() { [ -n "$GLUE" ] && grep -qa "$1" "$GLUE"; }

HAS_JSPI=0
if has_in_glue 'WebAssembly.Suspending' || has_in_glue 'WebAssembly.promising'; then
	HAS_JSPI=1
fi

SLICE_EXPORTS=''
for export in arm mask stat raise; do
	if has_in_glue "_zend_wasm_slice_${export}"; then
		SLICE_EXPORTS="${SLICE_EXPORTS}${SLICE_EXPORTS:+,}${export}"
	fi
done

# dumped to a file first, deliberately. `strings ... | grep -m1` makes grep exit on
# the first match, strings then dies of SIGPIPE, and under `pipefail` that turns a
# successful match into a failed pipeline -- nondeterministically, depending on where
# in a 9 MB binary the match lands. It reported "unknown" for one variant and the right
# answer for another from the same code.
# the XXXXXX is required: GNU mktemp rejects a template without it, and this script only ever ran
# on macOS until pipefail stopped tee from swallowing its exit status
STRINGS_DUMP="$(mktemp -t inspectbuild.XXXXXX)"
trap 'rm -f "$STRINGS_DUMP"' EXIT
strings -a "$WASM" > "$STRINGS_DUMP" 2> /dev/null || true

# read from the BINARY, never from the configure string. On 8.5 there is no
# --enable-opcache flag any more, so the rc's inherited copy of it is accepted and
# ignored: the CONFIGURE_COMMAND on a successfully de-opcached build still SAYS
# --enable-opcache. `Zend OPcache` is the extension name the module registers and
# went 7 -> 0 across control85 and noopcache85.
HAS_OPCACHE=0
grep -qa 'Zend OPcache' "$STRINGS_DUMP" && HAS_OPCACHE=1

CONFIGURE="$(grep -m1 -- "'--disable-all'" "$STRINGS_DUMP" || true)"
# only the tail matters: everything before --disable-all is php-wasm's own fixed
# preamble and is identical in every variant
EXTENSIONS="$(printf '%s' "$CONFIGURE" | sed "s/.*'--disable-all'//" | tr -s ' ')"
# the X-Powered-By header PHP compiles in carries the exact patch version, which the
# rc only pins to a minor
PHP_VERSION="$(grep -m1 -oE 'PHP/[0-9]+\.[0-9]+\.[0-9]+' "$STRINGS_DUMP" | cut -d/ -f2 || true)"

echo "build:            $DIR"
echo "wasm:             $(basename "$WASM")  raw=$RAW  gzip=$GZ"
if [ -n "$GLUE" ]; then
	echo "glue:             $(basename "$GLUE")  raw=$GLUE_RAW  gzip=$GLUE_GZ"
fi
# a FLOOR for the deployed bundle, never the deployed figure: the consumer's own
# code and assets land in the same stream
echo "gzip total:       $TOTAL_GZ  one stream at -6  (free ceiling 3145728, paid 10485760)"
echo "statically linked: $([ "$IS_STATIC" = 1 ] && echo yes || echo 'NO -- dylink section present')"
echo "jspi:             $([ "$HAS_JSPI" = 1 ] && echo yes || echo no)"
echo "opcache:          $([ "$HAS_OPCACHE" = 1 ] && echo yes || echo 'no -- not registered')"
echo "slice exports:    ${SLICE_EXPORTS:-none}"
echo "php version:      ${PHP_VERSION:-unknown}"
echo "configure tail:  ${EXTENSIONS:- (not recovered)}"

FAILED=0
if [ "$EXPECT_STATIC" = 1 ] && [ "$IS_STATIC" != 1 ]; then
	echo "FAIL: expected a static build, found a dylink section -- workerd cannot load this"
	FAILED=1
fi
if [ "$EXPECT_JSPI" = 1 ] && [ "$HAS_JSPI" != 1 ]; then
	echo "FAIL: expected JSPI, but the glue wraps nothing in WebAssembly.Suspending/promising"
	FAILED=1
fi
if [ "$EXPECT_SLICE" = 1 ] && [ -z "$SLICE_EXPORTS" ]; then
	echo "FAIL: expected the slice exports, but the glue has no _zend_wasm_slice_* -- patch-vm-interrupt.sh did not reach the binary"
	FAILED=1
fi
# patch-drop-opcache.sh --verify reads config.m4, so it proves the SOURCE was edited
# and not that the extension left the binary
if [ "$EXPECT_NO_OPCACHE" = 1 ] && [ "$HAS_OPCACHE" != 0 ]; then
	echo "FAIL: expected no opcache, but the binary still registers Zend OPcache -- the drop did not reach it"
	FAILED=1
fi

# THE EXTENSION GATE, and it exists because a build EXITED 0 while missing seven of them.
#
# A fresh clone leaves third_party/ holding only php8.3-src, so --enable-vrzno, --with-libxml,
# --enable-dom, --with-zlib, simplexml, xml and yaml all silently DROP: configure cannot find the
# libraries, and the flags that need no library (--enable-opcache, --enable-ctype) still take. The
# result looks like a healthy build, passes --expect-static, and is not the binary anyone asked for.
#
# The rc is the manifest rather than a second list kept beside it. Nothing to drift: this reads the
# WITH_* declarations out of the SAME file the build consumed and checks each one reached the
# configure line PHP compiled into the artifact. `--expect-static` proves the binary loads;
# this proves it is the right binary.
if [ -n "$EXPECT_RC" ]; then
	if [ ! -f "$EXPECT_RC" ]; then
		echo "FAIL: --expect-rc names no such file: $EXPECT_RC"
		FAILED=1
	elif [ -z "$EXTENSIONS" ]; then
		echo "FAIL: --expect-rc given, but no configure line was recoverable from the binary"
		FAILED=1
	else
		MISSING=""
		while IFS= read -r decl; do
			key="${decl%%=*}"
			val="${decl#*=}"
			# 0 means "deliberately out", so only positive declarations are asserted
			case "$val" in 0 | '') continue ;; esac
			case "$key" in
				WITH_VRZNO) flag='--enable-vrzno' ;;
				WITH_LIBXML) flag='--with-libxml' ;;
				WITH_DOM) flag='--enable-dom' ;;
				WITH_SIMPLEXML) flag='--enable-simplexml' ;;
				WITH_XML) flag='--enable-xml' ;;
				WITH_YAML) flag='--with-yaml' ;;
				WITH_ZLIB) flag='--with-zlib' ;;
				WITH_ZIP | WITH_LIBZIP) flag='--with-zip' ;;
				WITH_CTYPE) flag='--enable-ctype' ;;
				WITH_FILTER) flag='--enable-filter' ;;
				WITH_SESSION) flag='--enable-session' ;;
				WITH_TOKENIZER) flag='--enable-tokenizer' ;;
				WITH_ICONV) flag='--with-iconv' ;;
				WITH_MBSTRING) flag='--enable-mbstring' ;;
				WITH_SQLITE) flag='--with-sqlite3' ;;
				WITH_GD) flag='--enable-gd' ;;
				WITH_PHAR) flag='--enable-phar' ;;
				WITH_OPENSSL) flag='--with-openssl' ;;
				WITH_INTL) flag='--enable-intl' ;;
				# an unmapped key is NOT silently passed: it is reported, because a new
				# WITH_* that this case block has not learned would otherwise read as verified
				*)
					echo "note: --expect-rc has no configure flag mapped for $key; not asserted"
					continue
					;;
			esac
			case "$EXTENSIONS" in
				*"$flag"*) ;;
				*) MISSING="$MISSING $flag" ;;
			esac
		done <<< "$(grep -E '^[[:space:]]*WITH_[A-Z0-9_]+=' "$EXPECT_RC" | tr -d '[:blank:]')"

		# THE SECOND MECHANISM, and skipping it would have left the variants that matter
		# unchecked. php-wasm cannot express mbstring through WITH_*: `WITH_MBSTRING=static`
		# emits `--with-mbstring`, which ext/mbstring/config.m4 silently ignores because it
		# declares PHP_ARG_ENABLE with no --with- form. So mbstring.rc sets WITH_MBSTRING=0 and
		# pushes `--enable-mbstring` through CONFIGURE_FLAGS instead -- which the loop above,
		# reading only WITH_*, would pass without checking anything at all.
		#
		# These need no flag mapping: the rc names the literal flag, so it is compared literally.
		while IFS= read -r flag; do
			[ -n "$flag" ] || continue
			# a flag with a value (--with-yaml=/src/lib) is matched on its NAME; the path is a
			# property of the build environment rather than of what was asked for
			name="${flag%%=*}"
			case "$EXTENSIONS" in
				*"$name"*) ;;
				*) MISSING="$MISSING $name" ;;
			esac
		done <<< "$(
			grep -E '^[[:space:]]*CONFIGURE_FLAGS[[:space:]]*\+?=' "$EXPECT_RC" \
				| sed 's/^[^=]*=//' | tr ' ' '\n' | grep -E '^--(enable|with)-' || true
		)"

		if [ -n "$MISSING" ]; then
			echo "FAIL: $(basename "$EXPECT_RC") asks for extensions the binary does not have:$MISSING"
			echo "      either this artifact was built from a different rc, or configure could not"
			echo "      find the libraries -- a third_party/ holding only php<v>-src drops every"
			echo "      flag that needs one, keeps the rest, and still exits 0"
			FAILED=1
		else
			echo "extensions:       every positive WITH_* in $(basename "$EXPECT_RC") reached the build"
		fi
	fi
fi

[ "$FAILED" = 0 ] || exit 1

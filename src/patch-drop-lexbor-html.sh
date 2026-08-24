#!/usr/bin/env bash
# Drops lexbor's HTML half from a PHP 8.5 source tree, keeping its URL half.
#
# WHAT THIS IS FOR
# lexbor entered PHP 8.4 to back Dom\HTMLDocument, the new HTML5 parser, and on
# 8.5 it is 3,109,236 bytes of LTO bitcode -- six times ext/uri, the term the
# version-bump work chased for weeks. Drupal reaches none of it: Html::load()
# calls DOMDocument::loadHTML(), which is libxml2's parser and fifteen years
# older, and a search of Drupal 11.4.5 finds ZERO Dom\* uses in core with only
# four harmless ones in symfony/var-dumper.
#
# What stays, and why the split works:
# lexbor is modular by directory and the two consumers barely overlap:
#   ext/dom's HTMLDocument needs html + css  (removable)
#   ext/uri's WHATWG parser needs url + core + punycode + unicode + encoding
#
# Encoding cannot be removed, and an earlier revision of this script deleted it.
# Symbol analysis over the built bitcode: url/url.o needs 7 real functions from
# encoding (lxb_encoding_res_map, the utf-8 decode/encode length and single
# helpers, encode_iso_2022_jp_eof_single), and so do punycode.o, idna.o and
# unicode.o. Those in turn need 88 codepage-table symbols from multi.c, single.c,
# range.c and encoding.c. url.c is mandatory because main/streams/streams.c calls
# php_uri_get_parser() unconditionally. So all 7 encoding files stay, and the
# 825,364-byte multi.o stays with them.
#
# Measured bitcode actually removable: html 928,468 + css 251,284 + the four
# ext/dom objects (html_document 66,592, html5_parser 21,028,
# inner_outer_html_mixin 28,628, parentnode/css_selectors 10,444) = 1,306,444.
# The 2,247,060 an earlier revision claimed counted encoding and is not reachable.
#
# Bitcode is not gzip. 1,306,444 is the target, never a saving; the ratio runs
# the unhelpful way and only a built-and-gzipped binary settles it.
#
# It is incomplete, and refuses rather than producing a tree
# that cannot link. Removing lexbor/html plus the four ext/dom sources leaves 21
# symbols undefined: 16 wanted by dom/php_dom.o's property and method handler
# tables (dom_html_document_body_read/write, encoding_write, head_read,
# title_read/write, dom_element_inner_html_read/write, outer_html_read/write,
# dom_modern_document_implementation_read, and the five
# zim_Dom_HTMLDocument_* entries), 1 by dom/element.o (dom_parse_fragment), and 4
# more once css goes (dom_element_matches, dom_element_closest,
# dom_parent_node_query_selector, query_selector_all). Those live in php_dom.c,
# its arginfo header and element.c, so the real patch is a source edit there, not
# a build-list deletion.
#
# usage:
#   src/patch-drop-lexbor-html.sh <php-wasm-checkout>
#   src/patch-drop-lexbor-html.sh <php-wasm-checkout> --verify
#
# Keyed on the patched shape, never on a marker comment, and fatal when the shape has moved --
# a patch that silently skips is how this project shipped eleven variants missing seven extensions.
#
# When the apply path is implemented, the `sed -i.orig` below must be replaced by
# an in-place rewrite. php-src is container-created, so the host cannot create a
# sibling in that directory; `sed -i.orig` fails with Permission denied exactly as
# patch-drop-opcache.sh's `awk > .new` did. See patch-vm-interrupt.sh for the model.
set -euo pipefail

CHECKOUT="${1:?usage: patch-drop-lexbor-html.sh <php-wasm-checkout> [--verify]}"
MODE="${2:-apply}"
PHP_VERSION="${PHP_VERSION:-8.5}"

SRC="$CHECKOUT/third_party/php${PHP_VERSION}-src"
LEXBOR_M4="$SRC/ext/lexbor/config.m4"
DOM_M4="$SRC/ext/dom/config.m4"

# the ext/dom sources that call into lexbor's HTML side
DOM_DROP=(html_document.c html5_parser.c inner_outer_html_mixin.c parentnode/css_selectors.c)

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

[ -f "$LEXBOR_M4" ] || fail "no ext/lexbor/config.m4 at $LEXBOR_M4 (PHP $PHP_VERSION has no ext/lexbor?)"
[ -f "$DOM_M4" ] || fail "no ext/dom/config.m4 at $DOM_M4"

# counts of the shape this patch targets, so a moved shape is loud rather than silent
lexbor_lines() { grep -cE "^[[:space:]]*\\\$LEXBOR_DIR/(html|css)/" "$LEXBOR_M4" || true; }
dom_lines() {
	local n=0 f
	for f in "${DOM_DROP[@]}"; do
		if grep -qE "^[[:space:]]*${f}[[:space:]]*$" "$DOM_M4"; then n=$((n + 1)); fi
	done
	echo "$n"
}

if [ "$MODE" = '--verify' ]; then
	lex="$(lexbor_lines)"
	dom="$(dom_lines)"
	if [ "$lex" -eq 0 ] && [ "$dom" -eq 0 ]; then
		echo "ok: lexbor's html and css sources are absent from both config.m4 files"
		# the URL half has to have survived, or ext/uri cannot link
		grep -qE "^[[:space:]]*\\\$LEXBOR_DIR/url/" "$LEXBOR_M4" \
			|| fail "the url sources are gone too; ext/uri will not link"
		echo "ok: the url sources survived, so ext/uri still links"
		exit 0
	fi
	fail "not patched: $lex html/css/encoding source lines and $dom ext/dom files remain"
fi

# apply mode is deliberately unimplemented: the config.m4 deletions alone leave 21
# symbols undefined in dom/php_dom.o, dom/element.o and the handler tables, so a
# real patch has to edit ext/dom/php_dom.c, its arginfo header and element.c.
# Refusing before touching anything beats producing a tree that cannot link.
if [ "$MODE" != '--force-incomplete' ]; then
	fail "INCOMPLETE: config.m4 deletions alone leave 21 undefined symbols (16 in
      php_dom.o's handler tables, 1 dom_parse_fragment in element.o, 4 more once
      css goes). That needs a source patch to ext/dom/php_dom.c, its arginfo and
      element.c, which this script does not implement. Use --verify on a tree
      patched by hand; nothing has been modified. --force-incomplete overrides."
fi

lex_before="$(lexbor_lines)"
dom_before="$(dom_lines)"

# 143 was the count measured on php-8.5.2: html 117, css 19, encoding 7. A different
# number is not automatically wrong, but zero means the shape moved and the patch
# would do nothing while reporting success
[ "$lex_before" -gt 0 ] || fail "no \$LEXBOR_DIR/{html,css}/ source lines in $LEXBOR_M4; the shape moved"
[ "$dom_before" -eq "${#DOM_DROP[@]}" ] \
	|| fail "expected ${#DOM_DROP[@]} ext/dom sources to drop, found $dom_before; the shape moved"

# keep url present as a precondition, so a bad edit cannot quietly break ext/uri
grep -qE "^[[:space:]]*\\\$LEXBOR_DIR/url/" "$LEXBOR_M4" \
	|| fail "no \$LEXBOR_DIR/url/ sources to preserve; this is not the tree this patch expects"

sed -i.orig -E "/^[[:space:]]*\\\$LEXBOR_DIR\/(html|css)\//d" "$LEXBOR_M4"
for f in "${DOM_DROP[@]}"; do
	sed -i.orig -E "/^[[:space:]]*${f}[[:space:]]*$/d" "$DOM_M4"
done
rm -f "$LEXBOR_M4.orig" "$DOM_M4.orig"

lex_after="$(lexbor_lines)"
dom_after="$(dom_lines)"
[ "$lex_after" -eq 0 ] || fail "$lex_after html/css lines survived the edit"
[ "$dom_after" -eq 0 ] || fail "$dom_after ext/dom sources survived the edit"
grep -qE "^[[:space:]]*\\\$LEXBOR_DIR/url/" "$LEXBOR_M4" || fail "the url sources were removed by mistake"

echo "dropped $lex_before lexbor html/css source lines from ext/lexbor/config.m4"
echo "dropped $dom_before sources from ext/dom/config.m4: ${DOM_DROP[*]}"
echo "kept the url, core, punycode and unicode sources so ext/uri still links"

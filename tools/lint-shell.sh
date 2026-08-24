#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

failed=0
count=0

# Explicit paths win over the sweep. The pre-commit hook passes the STAGED files, so a commit
# checks what it is committing; CI passes nothing and gets the whole repository, including the
# presence and pin checks that only make sense repo-wide.
if [ "$#" -gt 0 ]; then
	for path in "$@"; do
		[ -f "$path" ] || continue
		case "$path" in
			*.sh)
				count=$((count + 1))
				if bash -n "$path" 2> /tmp/lint-shell.err; then
					echo "  ok   $path"
				else
					failed=$((failed + 1))
					echo "  FAIL $path -- $(tr '\n' ' ' < /tmp/lint-shell.err)"
				fi
				;;
			*.rc)
				count=$((count + 1))
				if grep -qE '^PHP_VERSION=' "$path"; then
					echo "  ok   $path (PHP_VERSION pinned)"
				else
					failed=$((failed + 1))
					echo "  FAIL $path -- no PHP_VERSION, so the Makefile default decides the interpreter"
				fi
				;;
			*.c)
				count=$((count + 1))
				if [ -s "$path" ]; then
					echo "  ok   $path (present, non-empty)"
				else
					failed=$((failed + 1))
					echo "  FAIL $path -- missing or empty"
				fi
				;;
		esac
	done
	rm -f /tmp/lint-shell.err
	if [ "$count" = 0 ]; then
		echo "nothing to check"
		exit 0
	fi
	printf '\n%d file%s checked, %d failed\n' "$count" "$([ "$count" = 1 ] || echo s)" "$failed"
	[ "$failed" = 0 ] || exit 1
	exit 0
fi
while IFS= read -r script; do
	count=$((count + 1))
	if bash -n "$script" 2> /tmp/lint-shell.err; then
		echo "  ok   $script"
	else
		failed=$((failed + 1))
		echo "  FAIL $script -- $(tr '\n' ' ' < /tmp/lint-shell.err)"
	fi
done < <(find . -name '*.sh' -not -path './node_modules/*' -not -path './.git/*' -not -path './.husky/_/*' | sort)

if command -v python3 > /dev/null; then
	while IFS= read -r script; do
		blocks="$(grep -cE "<<[[:space:]]*'PY'\$" "$script" || true)"
		if [ "$blocks" -eq 0 ]; then
			if grep -qE 'python3 [-] .*<<' "$script"; then
				count=$((count + 1))
				failed=$((failed + 1))
				echo "  FAIL $script -- feeds a heredoc to python3 but no <<'PY' opener matched"
			fi
			continue
		fi
		for index in $(seq 1 "$blocks"); do
			count=$((count + 1))
			awk -v want="$index" "
				/<<[[:space:]]*'PY'\$/ { seen++; if (seen == want) { grab = 1; next } }
				/^PY\$/ { grab = 0 }
				grab { print }
			" "$script" > /tmp/lint-shell.py
			if [ ! -s /tmp/lint-shell.py ]; then
				failed=$((failed + 1))
				echo "  FAIL $script (embedded python #$index) -- extracted nothing; the heredoc shape changed"
			elif python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' /tmp/lint-shell.py 2> /tmp/lint-shell.err; then
				echo "  ok   $script (embedded python #$index)"
			else
				failed=$((failed + 1))
				echo "  FAIL $script (embedded python #$index) -- $(tr '\n' ' ' < /tmp/lint-shell.err)"
			fi
		done
	done < <(find . -name '*.sh' -not -path './node_modules/*' -not -path './.git/*' -not -path './.husky/_/*' | sort)
	rm -f /tmp/lint-shell.py
fi

# the C probes are checked by the compiler that links them, not here, but a missing
# file is worth catching before a build spends an hour finding out
for probe in src/probes/*.c; do
	count=$((count + 1))
	if [ -s "$probe" ]; then
		echo "  ok   $probe (present, non-empty)"
	else
		failed=$((failed + 1))
		echo "  FAIL $probe -- missing or empty"
	fi
done

# every rc must name a PHP version, or the Makefile silently builds the default. .rc.pending is
# included because it is dispatch-buildable, so an unpinned one reaches a real build
for rc in src/rc/*.rc src/rc/*.rc.pending; do
	[ -f "$rc" ] || continue
	count=$((count + 1))
	if grep -qE '^PHP_VERSION=' "$rc"; then
		echo "  ok   $rc (PHP_VERSION pinned)"
	else
		failed=$((failed + 1))
		echo "  FAIL $rc -- no PHP_VERSION, so the Makefile default decides the interpreter"
	fi
done

# macOS mktemp accepts a template with no XXXXXX and GNU mktemp refuses it, so this fails ONLY on a
# runner. It has now bitten inspect-build.sh, patch-vm-interrupt.sh and test-patch-verify.sh, and
# each time it was invisible locally, which is why it is a rule rather than a fourth fix
while IFS= read -r script; do
	count=$((count + 1))
	bad="$(grep -nE 'mktemp[^|;&]*-t[[:space:]]+[^[:space:]|;&)]+' "$script" | grep -v 'XXXXXX' || true)"
	if [ -z "$bad" ]; then
		echo "  ok   $script (no macOS-only mktemp template)"
	else
		failed=$((failed + 1))
		echo "  FAIL $script -- mktemp -t template needs XXXXXX or GNU mktemp refuses it:"
		printf '         %s\n' "$bad"
	fi
done < <(find src tools -name '*.sh')

rm -f /tmp/lint-shell.err
printf '\n%d file%s checked, %d failed\n' "$count" "$([ "$count" = 1 ] || echo s)" "$failed"
[ "$failed" = 0 ] || exit 1

#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

failed=0
count=0
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

# every rc must name a PHP version, or the Makefile silently builds the default
for rc in src/rc/*.rc; do
	count=$((count + 1))
	if grep -qE '^PHP_VERSION=' "$rc"; then
		echo "  ok   $rc (PHP_VERSION pinned)"
	else
		failed=$((failed + 1))
		echo "  FAIL $rc -- no PHP_VERSION, so the Makefile default decides the interpreter"
	fi
done

rm -f /tmp/lint-shell.err
printf '\n%d file%s checked, %d failed\n' "$count" "$([ "$count" = 1 ] || echo s)" "$failed"
[ "$failed" = 0 ] || exit 1

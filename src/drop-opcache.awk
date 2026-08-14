# Comments out the whole PHP_NEW_EXTENSION(opcache) invocation, tracking paren
# balance rather than guessing where it ends.
#
# Commenting only the opening line leaves the source list and the closing
# `[yes])` as bare m4, which generates broken shell: configure died with
# "syntax error near unexpected token ')'" at line 49270. On 8.5 the call spans
# 324-343 and an unrelated `]))` sits at 352, so "next closing paren" is wrong
# too.
#
# Exits nonzero through the trailer check if the invocation never closes.
BEGIN { inblock = 0; depth = 0; done = 0; marked = 0 }

!done && !inblock && /^[[:space:]]*PHP_NEW_EXTENSION\(\[?opcache/ {
	print "dnl PHASM: opcache extension removed, see src/patch-drop-opcache.sh"
	marked = 1
	inblock = 1
}

inblock {
	line = $0
	# strip nothing; count parens across the raw line
	n = gsub(/\(/, "(", line)
	m = gsub(/\)/, ")", line)
	depth += n - m
	print "dnl " $0
	if (depth <= 0) {
		inblock = 0
		done = 1
	}
	next
}

# Post-registration macros that name the extension we just removed. Left live,
# PHP_ADD_EXTENSION_DEP(opcache, ...) declares a dependency for an extension that
# no longer exists, and PHP_INSTALL_HEADERS installs from a directory that is no
# longer built.
done && /^[[:space:]]*(PHP_ADD_EXTENSION_DEP\(opcache|PHP_INSTALL_HEADERS\(\[?ext\/opcache|PHP_ADD_MAKEFILE_FRAGMENT)/ {
	print "dnl " $0
	trailing++
	next
}

{ print }

END {
	if (!marked) {
		print "AWK-FAIL: no PHP_NEW_EXTENSION(opcache) found" > "/dev/stderr"
		exit 3
	}
	if (!done) {
		print "AWK-FAIL: the invocation never closed; paren balance left at " depth > "/dev/stderr"
		exit 4
	}
	if (trailing < 2) {
		print "AWK-FAIL: expected at least 2 post-registration opcache macros, commented " trailing + 0 > "/dev/stderr"
		exit 5
	}
}

# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# csrc_lib.sh - helpers for tests that read C source text.  Source it; it is
# not meant to be executed.  The caller sets TMPD (an existing scratch
# directory) before calling body().

# strip_comments <in> <out>: the C source without its comments, so a check
# for a construct is never confused by the word in a comment.
strip_comments() {
	awk '
	{
		line = $0
		out = ""
		while (length(line) > 0) {
			if (inblock) {
				p = index(line, "*/")
				if (p == 0) { line = ""; break }
				line = substr(line, p + 2)
				inblock = 0
				continue
			}
			p = index(line, "/*")
			q = index(line, "//")
			if (q > 0 && (p == 0 || q < p)) {
				out = out substr(line, 1, q - 1)
				line = ""
				break
			}
			if (p > 0) {
				out = out substr(line, 1, p - 1)
				line = substr(line, p + 2)
				inblock = 1
				continue
			}
			out = out line
			line = ""
		}
		print out
	}
	' "$1" > "$2"
}

# body <file> <function> <out>: the code of one function, comments removed,
# from its definition line to its closing brace (the file's comments are
# stripped first, so a function named in a comment is not a definition).  A prototype or a call (a
# line ending in ";" before any brace) is skipped.  Fails (no output) when
# no definition is found: a function that cannot be extracted must be
# reported, never read as an empty body that has nothing wrong.
body() {
	strip_comments "$1" "$TMPD/nocomment.c"
	awk -v f="$2" '
		!on && $0 ~ ("(^|[^A-Za-z0-9_])" f "[ \t]*(\\(|$)") { on = 1 }
		on {
			if (!opened && $0 ~ /;[ \t]*$/) { on = 0; n = 0; next }
			buf[n++] = $0
			t = $0
			no = gsub(/\{/, "", t)
			t = $0
			nc = gsub(/\}/, "", t)
			if (no > 0) { opened = 1 }
			depth += no - nc
			if (opened && depth <= 0) {
				for (i = 0; i < n; i++) print buf[i]
				exit
			}
		}
	' "$TMPD/nocomment.c" > "$3"
	[ -s "$3" ]
}

# lineno <file> <pattern>: the first line number matching the basic regular
# expression, or nothing.
lineno() {
	grep -n -- "$2" "$1" | head -1 | cut -d: -f1
}

# before <file> <pattern-a> <pattern-b>: true when a line matching a comes
# before the first line matching b (both must exist).
before() {
	_a=$(lineno "$1" "$2")
	_b=$(lineno "$1" "$3")
	[ -n "$_a" ] && [ -n "$_b" ] && [ "$_a" -lt "$_b" ]
}

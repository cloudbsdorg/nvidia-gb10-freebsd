# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# pins_lib.sh - helpers for source-level pin tests (sourced, not run).
# A pin looks at comment-stripped source, so a commented-out call does not
# count, and every pin is tested against planted defects (testing-standard
# rule 6): the pin must pass on the real tree and fail on each mutation.

# strip C comments (block and line), keeping line numbers
pin_strip() {
	awk '
	{ line = $0; out = ""
	  while (length(line) > 0) {
		if (inc) { i = index(line, "*/"); if (i == 0) { line = ""; break } line = substr(line, i + 2); inc = 0; continue }
		i = index(line, "/*"); j = index(line, "//")
		if (j > 0 && (i == 0 || j < i)) { out = out substr(line, 1, j - 1); line = ""; break }
		if (i == 0) { out = out line; line = ""; break }
		out = out substr(line, 1, i - 1); line = substr(line, i + 2); inc = 1
	  }
	  print out }' "$1"
}

# pin_has TEXT REGEX: the text has a line matching the (extended) regex
pin_has() { printf '%s\n' "$1" | grep -Eq -- "$2"; }

# pin_dead TEXT: the text has no disabled-code idiom
pin_dead() {
	! printf '%s\n' "$1" | grep -Eq -- 'if \((0|1|false|true)\b|\(0 &&|\|\| 1\b|^#[[:space:]]*if[[:space:]]+[01]\b'
}

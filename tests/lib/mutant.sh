# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# tests/lib/mutant.sh - the mutant harness of the host unit tests (Track #2363).
# Source it, define build_unit <source file> <out> (build the unit test against
# that source file, leaving cc's stderr in $TMPD/cc.err), then call
# mutant_check <name> <original source> <sed expression>. A mutant that does
# not build is a FAIL ("a compile error is not a caught mutant"); only a
# mutant whose test run fails is caught. Needs TMPD and the counter fails.

mutant_check() {
	sed "$3" "$2" > "$TMPD/mut.src"
	if cmp -s "$TMPD/mut.src" "$2"; then
		echo "FAIL: mutant $1 did not change the file"; fails=$((fails + 1)); return
	fi
	if ! build_unit "$TMPD/mut.src" "$TMPD/mut"; then
		echo "FAIL: mutant $1 does not build ($(head -1 "$TMPD/cc.err")): a compile error is not a caught mutant"; fails=$((fails + 1))
	elif "$TMPD/mut" > "$TMPD/mut.out" 2>&1; then
		echo "FAIL: mutant $1 was not caught"; fails=$((fails + 1))
	else
		echo "PASS: mutant $1 is caught by $(grep -m1 '^FAIL' "$TMPD/mut.out" | cut -c1-70)"
	fi
}

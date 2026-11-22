#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# summarize.sh - read the results of one prime_import_testboot run and say
# whether it passed.  usage: summarize.sh <results.jsonl | run directory>
#
# The run is a FAIL when: there is no final "done" row (the boot died or the
# script was killed; the last "running" row names the step it died in), the
# last row of any name is "running" or "fail", or there are no rows at all.
# Skips and infos are listed, never counted as a pass.  Exit codes: 0 a complete
# run without a failure whose import row passed; 1 a failure (a fail row, a step
# that never finished, no done row, no rows); 2 a usage error or an unreadable
# file; 3 the run finished without a failure but the import row or the
# wire-count-stable row was not a pass (skipped): the import or its wiring was
# not tested.

set -u
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
export PATH

if [ $# -ne 1 ]; then
	echo "usage: summarize.sh <results.jsonl | run directory>" >&2
	exit 2
fi
f=$1
[ -d "$f" ] && f=$f/results.jsonl
if [ ! -r "$f" ]; then
	echo "summarize: cannot read $f" >&2
	exit 2
fi

awk '
function field(line, name,   p, rest) {
	p = index(line, "\"" name "\":\"")
	if (p == 0) return ""
	rest = substr(line, p + length(name) + 4)
	return substr(rest, 1, index(rest, "\"") - 1)
}
{
	r = field($0, "row"); res = field($0, "result")
	if (r == "") next
	n++
	if (!(r in seen)) { seen[r] = 1; order[++k] = r }
	last[r] = res
	if (res == "fail") anyfail[r] = 1
}
END {
	bad = 0
	if (n == 0) { print "FAIL: no rows"; exit 1 }
	for (i = 1; i <= k; i++) {
		r = order[i]
		printf "%-6s %s\n", (r in anyfail) ? "fail" : last[r], r
		if (last[r] == "fail" || (r in anyfail)) { bad++; if (last[r] != "fail") printf "FAIL: row \"%s\" failed earlier in the run, whatever its last result says\n", r }
		if (last[r] == "running") { printf "FAIL: the run stopped in step \"%s\" (a panic or a kill)\n", r; bad++ }
	}
	if (!("done" in seen) || last["done"] != "info") { print "FAIL: no final \"done\" row: the run did not finish"; bad++ }
	if (bad) { print "summary: FAIL"; exit 1 }
	if (last["import"] != "pass") { print "summary: INCOMPLETE: the run finished but the import row is \"" (("import" in seen) ? last["import"] : "missing") "\", not pass: nothing was tested"; exit 3 }
	if (last["wire-count-stable"] != "pass") { print "summary: INCOMPLETE: the run finished but the wire-count-stable row is \"" (("wire-count-stable" in seen) ? last["wire-count-stable"] : "missing") "\", not pass: the wiring was not measured"; exit 3 }
	if (last["guard-order"] != "pass") { print "summary: INCOMPLETE: the run finished but the guard-order row is \"" (("guard-order" in seen) ? last["guard-order"] : "missing") "\", not pass: the place of the guard in the unload order was not shown"; exit 3 }
	print "summary: PASS (skips and infos are listed above and are not passes)"
	exit 0
}' "$f"

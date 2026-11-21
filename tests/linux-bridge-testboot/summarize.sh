#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# summarize.sh RESULTS.jsonl - exit 0 only when the run finished ("done" is the
# last row), no row failed, and at least one pass row exists. A trailing
# "running" row (the machine died in that step) or a missing "done" is a
# failure. The rows A2-no-linux, A4-nvrm-info, B2-nvidia_linux, B4-cuda and
# C1-veto-nvidia must be pass (skip only with SUMMARIZE_ALLOW_SKIP=1). Prints
# one line per non-info row.
f=${1:?usage: summarize.sh RESULTS.jsonl}
[ -f "$f" ] || { echo "no $f" >&2; exit 2; }
last=$(tail -n 1 "$f")
fails=$(grep -c '"result":"fail"' "$f")
passes=$(grep -c '"result":"pass"' "$f")
sed -n 's/^{"row":"\([^"]*\)","result":"\([^"]*\)","detail":"\(.*\)"}$/\2 \1 \3/p' "$f" | grep -v '^info '
case $last in
'{"row":"done"'*) ;;
*) echo "FAIL: the run did not end with a done row: last row is $last"; exit 1 ;;
esac
[ "$fails" -eq 0 ] || { echo "FAIL: $fails failed rows"; exit 1; }
[ "$passes" -gt 0 ] || { echo "FAIL: no pass row"; exit 1; }
# The rows that carry the claim must PASS, not be skipped: a skipped row is a
# test that did not run. SUMMARIZE_ALLOW_SKIP=1 accepts a skip (and says so).
for r in A2-no-linux A4-nvrm-info B2-nvidia_linux B4-cuda C1-veto-nvidia; do
	if ! grep -q "{\"row\":\"$r\",\"result\":\"pass\"" "$f"; then
		if [ "${SUMMARIZE_ALLOW_SKIP:-0}" = 1 ] && grep -q "{\"row\":\"$r\",\"result\":\"skip\"" "$f"; then
			echo "NOTE: $r was skipped and SUMMARIZE_ALLOW_SKIP=1 accepts it"
		else
			echo "FAIL: required row $r did not pass (it is missing, failed or skipped)"
			exit 1
		fi
	fi
done
echo "OK: $passes passed, 0 failed"

#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# summarize.sh RESULTS.jsonl - exit 0 only when the run finished ("done" is the
# last row), no row failed, and at least one pass row exists. A trailing
# "running" row (the machine died in that step) or a missing "done" is a
# failure. The rows A1-modeset, A2-no-linux, A4-nvrm-info, B2-nvidia_linux,
# B2-modeset_linux, B4-cuda, C1-veto-modeset and C1-veto-nvidia must be pass (skip only with SUMMARIZE_ALLOW_SKIP=1). Prints
# one line per non-info row.
# The rows the verdict needs; the kit test builds its fixtures from this list.
REQUIRED_ROWS="A1-modeset A2-no-linux A4-nvrm-info B2-nvidia_linux B2-modeset_linux B4-cuda C1-veto-modeset C1-veto-nvidia"
[ "${1:-}" != --required ] || { echo $REQUIRED_ROWS; exit 0; }
f=${1:?usage: summarize.sh RESULTS.jsonl | --required}
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
# test that did not run. SUMMARIZE_ALLOW_SKIP=1 accepts a skipped row (and says so);
# a failed or missing row is never accepted.
hint() {	# hint <row> <result>
	case $1:$2 in
	A4-nvrm-info:skip) echo "make-be.sh -i and -p stage nvrm-info and its proof" ;;
	B4-cuda:skip) echo "make-be.sh -U, -C and -u stage the Linux CUDA smoke" ;;
	C1-veto-modeset:skip | C1-veto-nvidia:skip) echo "another module holds the native one (the row's detail names it); a nvidia_drm boot cannot prove this" ;;
	esac
}
for r in $REQUIRED_ROWS; do
	res=$(sed -n "s/^{\"row\":\"$r\",\"result\":\"\\([a-z]*\\)\".*/\\1/p" "$f" | tail -n 1)
	[ "$res" = pass ] && continue
	if [ "$res" = skip ] && [ "${SUMMARIZE_ALLOW_SKIP:-0}" = 1 ]; then
		echo "NOTE: $r was skipped and SUMMARIZE_ALLOW_SKIP=1 accepts it"
		continue
	fi
	echo "FAIL: required row $r is ${res:-missing}, not pass"
	[ -z "$(hint "$r" "$res")" ] || echo "      $(hint "$r" "$res")"
	[ "$res" != skip ] || echo "      or set SUMMARIZE_ALLOW_SKIP=1 to accept a skip"
	exit 1
done
echo "OK: $passes passed, 0 failed"

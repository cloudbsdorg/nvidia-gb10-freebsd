#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# native_path_check_test.sh - tests for scripts/native-path-check against the
# fixtures in tests/data/native-path/. Every violation case asserts that the
# list of reported rules is exactly the one rule the fixture is for.
#
#   valid.json                       rc 0, status ok
#   rule-*.json, record/field cases  rc 1, exactly one rule
#   non-JSON, records not a list,
#   bad registries, usage errors     rc 2, status error
#   --jsonl                          every line parses as JSON

PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL

TESTSDIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SCRIPT=$TESTSDIR/../scripts/native-path-check
DATA=$TESTSDIR/data/native-path
REG=$TESTSDIR/../docs/native-paths.json
OUT=$(mktemp -t native-path-check-test.XXXXXXXX) || exit 1

PASSED=0
FAILED=0

# cleanup - remove exactly this run's output file.
# Time:  O(1).
# Space: O(1).
cleanup() {
	rm -f "$OUT" "$OUT.err"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

ok() {
	PASSED=$((PASSED + 1))
	printf 'ok   %s\n' "$1"
}

fail() {
	FAILED=$((FAILED + 1))
	printf 'FAIL %s\n' "$1"
}

# rules_are WANT - succeed when the violation rules in $OUT equal exactly [WANT].
# Time:  O(violations).
# Space: O(violations).
rules_are() {
	python3 -I -c '
import json, sys
d = json.load(open(sys.argv[1]))
assert [v["rule"] for v in d["violations"]] == [sys.argv[2]], d["violations"]
' "$OUT" "$1" 2>/dev/null
}

# run_case NAME RC STATUS RULE FILE [ARGS...]
# RULE "-" asserts no rule list; otherwise the rules must be exactly [RULE].
# Time:  O(records in FILE).
# Space: O(1).
run_case() {
	name=$1 want_rc=$2 want_status=$3 want_rule=$4 file=$5
	shift 5
	"$SCRIPT" --registry "$REG" "$@" "$file" >"$OUT" 2>/dev/null
	rc=$?
	if [ "$rc" != "$want_rc" ]; then
		fail "$name: rc $rc, want $want_rc"
		return
	fi
	if ! grep -q "\"status\": \"$want_status\"" "$OUT"; then
		fail "$name: status $want_status not in output"
		return
	fi
	if [ "$want_rule" != "-" ] && ! rules_are "$want_rule"; then
		fail "$name: rules are not exactly [$want_rule]"
		return
	fi
	ok "$name"
}

# error_case NAME ERRTEXT REGISTRY FILE - rc 2, status error, error has ERRTEXT.
# Time:  O(1).
# Space: O(1).
error_case() {
	name=$1 text=$2 reg=$3 file=$4
	"$SCRIPT" --registry "$reg" "$file" >"$OUT" 2>/dev/null
	rc=$?
	if [ "$rc" = 2 ] && grep -q '"status": "error"' "$OUT" && grep -q "$text" "$OUT"; then
		ok "$name"
	else
		fail "$name: rc $rc, text '$text'"
	fi
}

run_case "valid document" 0 ok - "$DATA/valid.json"
grep -q '"checked": 5' "$OUT" && grep -q '"native": 2' "$OUT" && grep -q '"linuxulator": 3' "$OUT" &&
	ok "valid document: checked and counts" || fail "valid document: checked and counts"

run_case "rule a path-missing" 1 violations path-missing "$DATA/rule-a-missing.json"
run_case "rule a path-invalid" 1 violations path-invalid "$DATA/rule-a-invalid.json"
run_case "rule b unknown-pair" 1 violations unknown-pair "$DATA/rule-b-unknown-pair.json"
run_case "rule c native-without-path" 1 violations native-without-path "$DATA/rule-c-native-without-path.json"
run_case "rule c status-invalid" 1 violations status-invalid "$DATA/rule-c-status-invalid.json"
run_case "rule d linux-where-native" 1 violations linux-where-native "$DATA/rule-d-linux-where-native.json"
run_case "rule d status-invalid" 1 violations status-invalid "$DATA/rule-d-status-invalid.json"
run_case "superseded-without-native" 1 violations superseded-without-native "$DATA/rule-superseded-without-native.json"
run_case "superseded without superseded_by" 1 violations superseded-without-native "$DATA/superseded-no-field.json"
grep -q 'no superseded_by field' "$OUT" && ok "detail names the failed part: field" || fail "detail names the failed part: field"
run_case "superseded_by matches no native source" 1 violations superseded-without-native "$DATA/superseded-mismatch.json"
grep -q 'is not in the source' "$OUT" && ok "detail names the failed part: source" || fail "detail names the failed part: source"
run_case "native record dated earlier" 1 violations superseded-without-native "$DATA/superseded-earlier.json"
grep -q 'dated on or after' "$OUT" && ok "detail names the failed part: date" || fail "detail names the failed part: date"
run_case "unknown path_status" 1 violations status-invalid "$DATA/status-unknown.json"
run_case "missing card and backend" 1 violations field-missing "$DATA/field-missing.json"
grep -q 'no card and no backend' "$OUT" && ! grep -q 'None' "$OUT" && ok "field-missing names both, no None text" || fail "field-missing names both, no None text"
run_case "record is not an object" 1 violations record-invalid "$DATA/record-not-object.json"
run_case "list-valued card" 1 violations field-type "$DATA/field-type.json"
grep -q 'card is list' "$OUT" && ok "field-type names the field" || fail "field-type names the field"
run_case "two bad fields: one violation" 1 violations field-type "$DATA/field-type-two.json"
grep -q 'card is list, backend is dict' "$OUT" && ok "field-type lists every bad field" || fail "field-type lists every bad field"

run_case "non-JSON input" 2 error - "$DATA/not-json.txt"
run_case "missing input" 2 error - "$DATA/does-not-exist.json"
run_case "empty records list" 2 error - "$DATA/records-empty.json"
grep -q 'no records' "$OUT" && ok "empty records says no records" || fail "empty records says no records"
run_case "deeply nested input" 2 error - "$DATA/deep-nesting.json"
run_case "records is not a list" 2 error - "$DATA/records-not-list.json"
error_case "history without records" 'missing key \\"records\\"' "$REG" "$DATA/registry-empty.json"
error_case "registry {}" 'missing key \\"paths\\"' "$DATA/registry-empty.json" "$DATA/valid.json"
error_case "registry native is a string" 'native must be true or false' "$DATA/registry-native-string.json" "$DATA/valid.json"
error_case "registry duplicate pair" 'duplicate registry pair' "$DATA/registry-duplicate.json" "$DATA/valid.json"
error_case "registry version 2" 'version must be 1' "$DATA/registry-version2.json" "$DATA/valid.json"
error_case "registry not JSON" 'cannot read registry' "$DATA/not-json.txt" "$DATA/valid.json"

# Usage errors.
"$SCRIPT" --registry >"$OUT" 2>/dev/null
rc=$?
if [ "$rc" = 2 ] && grep -q -e '--registry needs a FILE' "$OUT"; then
	ok "--registry without a file: rc 2, names --registry"
else
	fail "--registry without a file: rc $rc"
fi
"$SCRIPT" >"$OUT" 2>/dev/null
rc=$?
if [ "$rc" = 2 ] && grep -q 'expected one BENCH_HISTORY_JSON, got 0' "$OUT"; then
	ok "no input file: rc 2"
else
	fail "no input file: rc $rc"
fi
"$SCRIPT" --bogus --jsonl "$DATA/valid.json" >"$OUT" 2>/dev/null
rc=$?
if [ "$rc" = 2 ] && [ "$(wc -l <"$OUT" | tr -d ' ')" = 1 ] && python3 -I -c '
import json, sys
d = json.loads(open(sys.argv[1]).read())
assert d["status"] == "error" and "--bogus" in d["error"] and "violations" not in d
' "$OUT"; then
	ok "--bogus --jsonl: one JSON line, status error, names --bogus"
else
	fail "--bogus --jsonl: rc $rc"
fi

# Usage errors also go to stderr in plain text (not in --jsonl mode); stdout stays JSON.
"$SCRIPT" --bogus >"$OUT" 2>"$OUT.err"
if grep -q 'unknown option --bogus' "$OUT.err" && grep -q '^usage:' "$OUT.err" && grep -q '"status": "error"' "$OUT"; then
	ok "usage error: plain message and usage on stderr, JSON on stdout"
else
	fail "usage error: stderr text"
fi
"$SCRIPT" --bogus --jsonl >"$OUT" 2>"$OUT.err"
if [ ! -s "$OUT.err" ]; then
	ok "usage error with --jsonl: nothing on stderr"
else
	fail "usage error with --jsonl: stderr not empty"
fi
rm -f "$OUT.err"

# Missing default registry: a copy of the script with no ../docs next to it.
COPY=$(mktemp -d -t native-path-check-copy.XXXXXXXX) || exit 1
mkdir "$COPY/scripts"
cp "$SCRIPT" "$COPY/scripts/native-path-check"
"$COPY/scripts/native-path-check" "$DATA/valid.json" >"$OUT" 2>/dev/null
rc=$?
if [ "$rc" = 2 ] && grep -q 'pass --registry FILE' "$OUT"; then
	ok "missing default registry: rc 2, hint to pass --registry"
else
	fail "missing default registry: rc $rc"
fi
rm -rf "$COPY"

# --help prints the resolved default registry path.
"$SCRIPT" --help >"$OUT" 2>/dev/null
rc=$?
if [ "$rc" = 0 ] && grep -q '^usage:' "$OUT" && grep -q "docs/native-paths.json" "$OUT" && ! grep -q '\.\./' "$OUT"; then
	ok "--help: rc 0, usage, resolved registry path"
else
	fail "--help: rc $rc"
fi

# --jsonl: every line parses, violation then summary.
"$SCRIPT" --registry "$REG" --jsonl "$DATA/rule-d-linux-where-native.json" >"$OUT" 2>/dev/null
rc=$?
if [ "$rc" = 1 ] && python3 -I -c '
import json, sys
docs = [json.loads(l) for l in open(sys.argv[1]).read().splitlines()]
assert len(docs) == 2, len(docs)
assert docs[0]["rule"] == "linux-where-native"
assert docs[1]["status"] == "violations" and "violations" not in docs[1]
' "$OUT"; then
	ok "jsonl: every line parses, violation then summary"
else
	fail "jsonl: rc $rc"
fi
"$SCRIPT" --registry "$REG" --jsonl "$DATA/valid.json" >"$OUT" 2>/dev/null
rc=$?
if [ "$rc" = 0 ] && [ "$(wc -l <"$OUT" | tr -d ' ')" = 1 ] && python3 -I -c '
import json, sys
d = json.loads(open(sys.argv[1]).read())
assert d["status"] == "ok"
' "$OUT"; then
	ok "jsonl on valid: one summary line"
else
	fail "jsonl on valid: rc $rc"
fi

printf '%s passed, %s failed\n' "$PASSED" "$FAILED"
[ "$FAILED" = 0 ]

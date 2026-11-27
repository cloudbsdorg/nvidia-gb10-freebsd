#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# gpu_check_coverage_test.sh - the coverage gate of the new library.
#
# The gate of the repository for the C library asks for 100% of the lines and
# of the branches of every file it names, and a plant proves the gate can
# fail (tests/libnvrm_test.sh).  This is the same gate for the new Python
# code: the suite of the tool and the unit tests of the library are run
# under coverage, the report is measured, and every file of the library must
# be at least at its floor (tests/data/gpu-check/coverage-floor.txt).
#
# The plant: a run that covers only part of the library is below the floor,
# and the gate says so.  A gate that cannot fail is not a gate.
#
# Run: sh tests/gpu_check_coverage_test.sh
# Exit: 0 the gate holds, 1 it does not, 77 coverage.py is not installed.

set -u

PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL

TESTSDIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH= cd -- "$TESTSDIR/.." && pwd)
LIB="$REPO/lib/gpu-check/gpu_check"
FLOOR="$REPO/tests/data/gpu-check/coverage-floor.txt"

PASSED=0
FAILED=0

ok() {
	PASSED=$((PASSED + 1))
	printf 'ok   %s\n' "$1"
}

bad() {
	FAILED=$((FAILED + 1))
	printf 'FAIL %s\n' "$1"
}

# Scratch inside the repository (tmp/ is git-ignored), not in the system
# temporary directory and not outside the repository.
mkdir -p "$REPO/tmp" || exit 1
S=$(mktemp -d "$REPO/tmp/gpu-check-coverage.XXXXXXXX") || exit 1
cleanup() {
	rm -rf -- "$S"
}
trap cleanup EXIT INT TERM

if ! python3 -c "import coverage" > /dev/null 2>&1; then
	printf 'note: coverage.py is not installed: the coverage gate did not run\n'
	exit 77
fi

# The settings of the measurement: the branches are measured too, and the
# data of every process is kept apart (the tool runs many processes).
cat > "$S/coveragerc" <<EOF
[run]
branch = True
source = $LIB
data_file = $S/.coverage
parallel = True
EOF

# COVERAGE_CORE=pytrace keeps the pure python tracer: the C tracer is not
# built here, and the warning it prints would land in the output of the tool.
COVERAGE_PROCESS_START="$S/coveragerc"
COVERAGE_CORE=pytrace
export COVERAGE_PROCESS_START COVERAGE_CORE

# 1. The suite of the tool, under coverage.  It has to be green: the
# coverage of a broken run says nothing.
sh "$REPO/tests/gpu_check_test.sh" > "$S/suite.log" 2>&1
_rc=$?
if [ "$_rc" = 0 ]; then
	ok "the suite of the tool is green under coverage"
else
	bad "the suite of the tool failed under coverage: $(grep -c '^FAIL' "$S/suite.log") failure(s), see the log"
	tail -5 "$S/suite.log"
fi

# 2. The unit tests of the library, under coverage.
python3 "$REPO/tests/gpu_check_unit.py" "$REPO/lib/gpu-check" > "$S/unit.log" 2>&1
if [ $? = 0 ]; then
	ok "the unit tests of the library are green under coverage"
else
	bad "the unit tests of the library failed under coverage"
	tail -5 "$S/unit.log"
fi

# 3. The cases of the database, under coverage.  They are the ones that
# reach the library of the database, the commands that read a run back
# and the metrics, so without them the floors of those files would be
# the floors of code nobody runs.
sh "$REPO/tests/gpu_check_db_test.sh" > "$S/db.log" 2>&1
_rc=$?
if [ "$_rc" = 0 ]; then
	ok "the cases of the database are green under coverage"
else
	bad "the cases of the database failed under coverage: $(grep -c '^FAIL' "$S/db.log") failure(s), see the log"
	tail -5 "$S/db.log"
fi

# 4. The report of the measurement.  The suite of the tool ran above as a
# child of this test, so the fake backend of the library (case (tt) of the
# suite) was measured as well.
( cd "$S" && python3 -m coverage combine > /dev/null 2>&1 )
if ( cd "$S" && python3 -m coverage json -o "$S/report.json" > /dev/null 2>&1 ); then
	ok "the coverage report was written"
else
	bad "the coverage report could not be written"
	printf 'passed: %s failed: %s\n' "$PASSED" "$FAILED"
	exit 1
fi

# 5. The gate: every file of the library is at least at its floor.
if python3 "$REPO/tests/gpu_check_coverage_gate.py" "$S/report.json" "$FLOOR" "$LIB" \
	> "$S/gate.out" 2>&1; then
	ok "the coverage gate holds: every file of the library is at its floor"
	sed 's/^/    /' "$S/gate.out"
else
	bad "the coverage gate does not hold:"
	sed 's/^/    /' "$S/gate.out"
fi

# 6. The plant: a run that covers only a part of the library is below the
# floor, and the gate says so.  Without this, the gate might be a gate that
# cannot fail.
mkdir -p "$S/plant"
cat > "$S/plant/coveragerc" <<EOF
[run]
branch = True
source = $LIB
data_file = $S/plant/.coverage
parallel = True
EOF
COVERAGE_PROCESS_START="$S/plant/coveragerc"
export COVERAGE_PROCESS_START
python3 "$REPO/scripts/gpu-check" --list > /dev/null 2>&1
( cd "$S/plant" && python3 -m coverage combine > /dev/null 2>&1 )
if ( cd "$S/plant" && python3 -m coverage json -o "$S/plant/report.json" > /dev/null 2>&1 ); then
	if python3 "$REPO/tests/gpu_check_coverage_gate.py" "$S/plant/report.json" "$FLOOR" "$LIB" \
		> "$S/plant/gate.out" 2>&1; then
		bad "the coverage gate plant: a run that covers a part of the library passed the gate"
	else
		ok "the coverage gate plant: a run that covers a part of the library fails the gate"
		grep -c "BELOW\|not in the coverage data" "$S/plant/gate.out" > /dev/null 2>&1 || true
	fi
else
	bad "the coverage gate plant: the report of the plant could not be written"
fi

printf 'passed: %s failed: %s\n' "$PASSED" "$FAILED"
if [ "$FAILED" -gt 0 ]; then
	exit 1
fi
exit 0

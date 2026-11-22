#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# lib_test.sh - tests for scripts/lib.sh (sources_get, count_missing,
# patch_headers_safe, test_hook).
#
# sources_get cases:
#   (a) key found:                       value printed, rc 0
#   (b) key missing:                     rc 1, nothing printed
#   (c) last line without a newline:     still found
# count_missing cases (fail closed: an unchecked count is an error, never an
# empty success):
#   (d) os dir holds no *.o:             rc 1, error on stderr, nothing printed
#   (e) nm -u fails on <object>:         rc 1, error on stderr
#   (f) nm --defined-only fails:         rc 1, error on stderr
#   (g) happy path (canned nm(1)):       prints the right count, rc 0
#   (h) scratch hygiene:                 no fixed-name scratch files left
#   (i) nm warning on stderr:            stderr is kept out of the symbol
#                                        lists, so a warning line is never
#                                        counted as a missing symbol
#   (s) awk stage fails (canned stub):   rc 1, error on stderr, no count
#                                        printed (pass-3 u02 #3: in a
#                                        pipeline the awk failure was lost
#                                        and the count read as 0)
#   (t) sort stage fails (canned stub):  rc 1, error on stderr, no count
#                                        printed
# patch_headers_safe cases:
#   (j) unified diff:                    accepted, rc 0
#   (k) `Index:` header line:            refused, rc 1 (patch(1) takes file
#                                        names from Index: lines too)
#   (l) `*** ` header line:              refused, rc 1
#   (u) `--- existing dir/../../evil<TAB>date`: refused, rc 1 (pass-3 u02
#                                        #2: the path is cut at the TAB
#                                        only - patch(1) keeps spaces up to
#                                        the TAB - and any blank that
#                                        remains is refused)
#   (v) `--- nvidia/a.c<TAB>timestamp`:  accepted, rc 0 (the TAB cut must
#                                        not break the repo's own headers)
# test_hook cases (direct units for the gate fetch-sources/prepare-tree/
# build-rmcore rely on; pass-2 u02 #9):
#   (m) hooks disabled:                  fixed path printed even when the
#                                        hook variable is set, rc 0, no
#                                        announcement
#   (n) hooks on, variable unset:        fixed path, rc 0
#   (o) hooks on, valid value:           that value printed, rc 0, announced
#   (p) value with a space:              rc 1, nothing printed
#   (q) value beginning with '-':        rc 1, nothing printed
#   (r) value of newlines only:          rc 1, nothing printed (arrives empty
#                                        through the caller's $( ))
#
# Run: sh tests/lib_test.sh

set -eu

PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL

TESTSDIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$TESTSDIR/../scripts/lib.sh"
TESTROOT=$(mktemp -d "$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)/work/tmp/lib-test.XXXXXXXX") || exit 1

PASSED=0
FAILED=0

# cleanup - remove exactly this run's test root on every exit path.
# Time:  O(files created by this test).
# Space: O(1).
cleanup() {
	rm -rf "$TESTROOT"
}
trap cleanup EXIT INT TERM

ok() {
	PASSED=$((PASSED + 1))
	printf 'ok   %s\n' "$1"
}

fail() {
	FAILED=$((FAILED + 1))
	printf 'FAIL %s\n' "$1"
}

printf 'alpha one\nbeta two words\n' > "$TESTROOT/SOURCES"

# (a) key found: value printed (multi-word values keep their spacing),
# rc 0.
rc=0
val=$(sources_get "$TESTROOT/SOURCES" beta) || rc=$?
if [ "$rc" -eq 0 ] && [ "$val" = "two words" ]; then
	ok "(a) key found: value printed, rc 0"
else
	fail "(a) key found: rc=$rc val=$val"
fi

# (b) key missing: rc 1, nothing printed.
rc=0
val=$(sources_get "$TESTROOT/SOURCES" nosuchkey) || rc=$?
if [ "$rc" -eq 1 ] && [ -z "$val" ]; then
	ok "(b) key missing: rc 1, no output"
else
	fail "(b) key missing: rc=$rc val=$val"
fi

# (c) last line without a trailing newline is still read.
printf 'alpha one\ngamma three' > "$TESTROOT/SOURCES-nonl"
rc=0
val=$(sources_get "$TESTROOT/SOURCES-nonl" gamma) || rc=$?
if [ "$rc" -eq 0 ] && [ "$val" = "three" ]; then
	ok "(c) last line without newline: found"
else
	fail "(c) last line without newline: rc=$rc val=$val"
fi

# --- count_missing ---------------------------------------------------------
cm_obj=$TESTROOT/cm-object
cm_osdir_empty=$TESTROOT/cm-osdir-empty
cm_osdir=$TESTROOT/cm-osdir
cm_scratch=$TESTROOT/cm-scratch
cm_err=$TESTROOT/cm-err
mkdir -p "$cm_osdir_empty" "$cm_osdir" "$cm_scratch" || exit 1
printf 'not an ELF object\n' > "$cm_obj"
# A file named *.o is enough for the "os dir holds objects" probe; nm(1) is
# replaced by the canned stub below wherever its behaviour matters.
printf 'not an ELF object\n' > "$cm_osdir/a.o"

# run_fake_nm <fail-mode u|d|w|A|S|none> <count_missing args...>: run
# count_missing with stub tools first on PATH. The nm stub answers nm -u with
# two undefined symbols (foo, bar) and nm --defined-only with one defined
# symbol (foo), so the expected count is 1 (bar); fail mode u/d makes that
# invocation exit 1; mode w makes the -u invocation print a warning line on
# stderr while still succeeding (stderr must not pollute the symbol lists).
# Modes A/S make the stub awk(1)/sort(1) (created further below, pass-3 u02
# #3 cases) fail instead of passing through to the real tool.
# Time:  O(1) in this shell plus count_missing's own cost.
# Space: O(1).
run_fake_nm() {
	_mode=$1
	shift
	(
		PATH="$TESTROOT/bin:$PATH"
		case $_mode in
		u) FAKE_NM_FAIL_U=1; export FAKE_NM_FAIL_U ;;
		d) FAKE_NM_FAIL_D=1; export FAKE_NM_FAIL_D ;;
		w) FAKE_NM_WARN=1; export FAKE_NM_WARN ;;
		A) FAKE_AWK_FAIL=1; export FAKE_AWK_FAIL ;;
		S) FAKE_SORT_FAIL=1; export FAKE_SORT_FAIL ;;
		esac
		count_missing "$@"
	)
}

mkdir -p "$TESTROOT/bin" || exit 1
cat > "$TESTROOT/bin/nm" <<'EOF'
#!/bin/sh
# Stub nm(1) for the count_missing happy/failure paths.
# Time:  O(#args) scan for the mode flag.
# Space: O(1).
mode=
for a in "$@"; do
	case $a in
	-u) mode=u ;;
	--defined-only) mode=d ;;
	esac
done
if [ "$mode" = "u" ]; then
	if [ "${FAKE_NM_FAIL_U:-0}" = 1 ]; then
		echo "nm: stub failure" >&2
		exit 1
	fi
	if [ "${FAKE_NM_WARN:-0}" = 1 ]; then
		echo "nm: warning: stale debug info" >&2
	fi
	printf '                 U bar\n                 U foo\n'
	exit 0
fi
if [ "${FAKE_NM_FAIL_D:-0}" = 1 ]; then
	echo "nm: stub failure" >&2
	exit 1
fi
printf '0000000000000000 T foo\n'
exit 0
EOF
chmod +x "$TESTROOT/bin/nm" || exit 1

# (d) os dir with no *.o: fail closed - rc 1, error on stderr, nothing on
#     stdout (an empty success would read as "nothing is missing").
rc=0
val=$(count_missing "$cm_obj" "$cm_osdir_empty" "$cm_scratch" 2>"$cm_err") || rc=$?
if [ "$rc" -eq 1 ] && [ -z "$val" ] && grep -q "count_missing" "$cm_err"; then
	ok "(d) count_missing: no *.o in os dir: rc 1, error on stderr"
else
	fail "(d) count_missing: no *.o in os dir: rc=$rc val=$val err=$(head -n 1 "$cm_err" 2>/dev/null)"
fi

# (e) nm -u fails on <object> (a text file): rc 1, error on stderr.
rc=0
val=$(count_missing "$cm_obj" "$cm_osdir" "$cm_scratch" 2>"$cm_err") || rc=$?
if [ "$rc" -eq 1 ] && [ -z "$val" ] && grep -q "nm -u failed" "$cm_err"; then
	ok "(e) count_missing: nm -u failure: rc 1, error on stderr"
else
	fail "(e) count_missing: nm -u failure: rc=$rc val=$val err=$(head -n 1 "$cm_err" 2>/dev/null)"
fi

# (f) nm --defined-only fails (stub fail mode d): rc 1, error on stderr.
rc=0
val=$(run_fake_nm d "$cm_obj" "$cm_osdir" "$cm_scratch" 2>"$cm_err") || rc=$?
if [ "$rc" -eq 1 ] && [ -z "$val" ] && grep -q "count_missing" "$cm_err"; then
	ok "(f) count_missing: nm --defined-only failure: rc 1, error on stderr"
else
	fail "(f) count_missing: nm --defined-only failure: rc=$rc val=$val err=$(head -n 1 "$cm_err" 2>/dev/null)"
fi

# (g) happy path with the canned stub: foo defined, bar not -> count 1, rc 0.
#     Regression guard: the fail-closed rewrite must not break the real path.
rc=0
val=$(run_fake_nm none "$cm_obj" "$cm_osdir" "$cm_scratch" 2>"$cm_err") || rc=$?
if [ "$rc" -eq 0 ] && [ "$val" = "1" ]; then
	ok "(g) count_missing: happy path counts bar as missing (1)"
else
	fail "(g) count_missing: happy path: rc=$rc val=$val err=$(head -n 1 "$cm_err" 2>/dev/null)"
fi

# (h) count_missing leaves no fixed-name scratch files behind and uses
#     unpredictable names inside the scratch dir (mktemp): after a run the
#     scratch dir holds no nmu/nmd/undef def leftovers.
if [ ! -e "$cm_scratch/nmu" ] && [ ! -e "$cm_scratch/nmd" ] &&
   [ ! -e "$cm_scratch/undef" ] && [ ! -e "$cm_scratch/def" ]; then
	ok "(h) count_missing: no fixed-name scratch files left in the scratch dir"
else
	fail "(h) count_missing: fixed-name scratch files left behind"
fi

# (i) nm warning on stderr must not pollute the symbol lists: the stub
#     succeeds on -u but prints a warning line to stderr. With stderr merged
#     into the list (2>&1), the warning's last word ("info") is parsed as an
#     undefined symbol and the count inflates to 2; with stderr kept separate
#     the count stays 1 (only bar is missing).
rc=0
val=$(run_fake_nm w "$cm_obj" "$cm_osdir" "$cm_scratch" 2>"$cm_err") || rc=$?
if [ "$rc" -eq 0 ] && [ "$val" = "1" ]; then
	ok "(i) count_missing: nm stderr warning kept out of the symbol lists (count 1)"
else
	fail "(i) count_missing: stderr pollution: rc=$rc val=$val err=$(head -n 1 "$cm_err" 2>/dev/null)"
fi

# --- patch_headers_safe ----------------------------------------------------
ph_ok=$TESTROOT/patch-unified
ph_index=$TESTROOT/patch-index
ph_star=$TESTROOT/patch-star
cat > "$ph_ok" <<'EOF'
--- nvidia/a.c
+++ nvidia/a.c
@@ -1 +1 @@
-int a(void) { return 0; }
+int a(void) { return 1; }
EOF
# patch(1) also takes file names from `Index:` lines (it is what svn-style
# patch sets use); a header path there bypasses the ---/+++ gate, so any
# Index: line must be refused.
cat > "$ph_index" <<'EOF'
Index: ../../etc/evil.c
--- nvidia/a.c
+++ nvidia/a.c
@@ -1 +1 @@
-int a(void) { return 0; }
+int a(void) { return 1; }
EOF
# Likewise the context-diff `*** ` header form.
cat > "$ph_star" <<'EOF'
*** nvidia/a.c
--- nvidia/a.c
***************
*** 1 ****
! int a(void) { return 0; }
--- 1 ----
! int a(void) { return 1; }
EOF

# (j) a plain unified diff with relative, ..-free paths: accepted.
rc=0
patch_headers_safe "$ph_ok" || rc=$?
if [ "$rc" -eq 0 ]; then
	ok "(j) patch_headers_safe: unified diff accepted"
else
	fail "(j) patch_headers_safe: unified diff refused: rc=$rc"
fi

# (k) an `Index:` header line: refused (rc 1).
rc=0
patch_headers_safe "$ph_index" || rc=$?
if [ "$rc" -eq 1 ]; then
	ok "(k) patch_headers_safe: Index: header refused"
else
	fail "(k) patch_headers_safe: Index: header accepted: rc=$rc"
fi

# (l) a `*** ` header line: refused (rc 1).
rc=0
patch_headers_safe "$ph_star" || rc=$?
if [ "$rc" -eq 1 ]; then
	ok "(l) patch_headers_safe: '*** ' header refused"
else
	fail "(l) patch_headers_safe: '*** ' header accepted: rc=$rc"
fi

# --- test_hook -------------------------------------------------------------
# Direct unit cases (pass-2 u02 #9): fetch-sources_test.sh case g can only
# prove the hook stubs are never CALLED; these prove the gate itself -
# disabled hooks ignore the environment, enabled hooks validate and announce.
hook_err=$TESTROOT/hook-err

# (m) hooks disabled (GB10_TEST_HOOKS unset): the fixed path is printed even
#     when the hook variable is set to a valid-looking value; no announcement.
rc=0
val=$(
	unset GB10_TEST_HOOKS
	TH_PROBE=/env/value
	test_hook libtest TH_PROBE /fixed/path 2>"$hook_err"
) || rc=$?
if [ "$rc" -eq 0 ] && [ "$val" = "/fixed/path" ] && [ ! -s "$hook_err" ]; then
	ok "(m) test_hook: hooks disabled: fixed path printed, hook variable ignored"
else
	fail "(m) test_hook: hooks disabled: rc=$rc val=$val err=$(head -n 1 "$hook_err" 2>/dev/null)"
fi

# (n) hooks enabled, hook variable unset: fixed path, rc 0, no announcement.
rc=0
: > "$hook_err"
val=$(
	GB10_TEST_HOOKS=1
	unset TH_PROBE
	test_hook libtest TH_PROBE /fixed/path 2>"$hook_err"
) || rc=$?
if [ "$rc" -eq 0 ] && [ "$val" = "/fixed/path" ] && [ ! -s "$hook_err" ]; then
	ok "(n) test_hook: hooks on, variable unset: fixed path"
else
	fail "(n) test_hook: hooks on, variable unset: rc=$rc val=$val err=$(head -n 1 "$hook_err" 2>/dev/null)"
fi

# (o) hooks enabled, valid value (one word of [A-Za-z0-9_./-]): that value is
#     printed, rc 0, and the use is announced on stderr.
rc=0
: > "$hook_err"
val=$(
	GB10_TEST_HOOKS=1
	TH_PROBE=/usr/bin/tool.x-1_a
	test_hook libtest TH_PROBE /fixed/path 2>"$hook_err"
) || rc=$?
if [ "$rc" -eq 0 ] && [ "$val" = "/usr/bin/tool.x-1_a" ] \
    && grep -q '^libtest: test hook TH_PROBE in use$' "$hook_err"; then
	ok "(o) test_hook: hooks on, valid value: value printed and announced"
else
	fail "(o) test_hook: hooks on, valid value: rc=$rc val=$val err=$(head -n 1 "$hook_err" 2>/dev/null)"
fi

# (p) hooks enabled, value holding a space: refused (rc 1), nothing printed -
#     an unquoted expansion would run a different program with the rest.
rc=0
: > "$hook_err"
val=$(
	GB10_TEST_HOOKS=1
	TH_PROBE='/bad path'
	test_hook libtest TH_PROBE /fixed/path 2>"$hook_err"
) || rc=$?
if [ "$rc" -eq 1 ] && [ -z "$val" ] && grep -q 'refusing test hook TH_PROBE' "$hook_err"; then
	ok "(p) test_hook: value with a space: rc 1, nothing printed"
else
	fail "(p) test_hook: value with a space: rc=$rc val=$val"
fi

# (q) hooks enabled, value beginning with '-': refused (rc 1), nothing printed
#     (whatever command later receives it would read it as an option).
rc=0
: > "$hook_err"
val=$(
	GB10_TEST_HOOKS=1
	TH_PROBE=-evil
	test_hook libtest TH_PROBE /fixed/path 2>"$hook_err"
) || rc=$?
if [ "$rc" -eq 1 ] && [ -z "$val" ] && grep -q 'refusing test hook TH_PROBE' "$hook_err"; then
	ok "(q) test_hook: value beginning with '-': rc 1, nothing printed"
else
	fail "(q) test_hook: value beginning with '-': rc=$rc val=$val"
fi

# (r) hooks enabled, value made only of newlines: looks non-empty to a naive
#     check but arrives EMPTY through the caller's $( ); refused (rc 1).
rc=0
: > "$hook_err"
val=$(
	GB10_TEST_HOOKS=1
	TH_PROBE='
'
	test_hook libtest TH_PROBE /fixed/path 2>"$hook_err"
) || rc=$?
if [ "$rc" -eq 1 ] && [ -z "$val" ] && grep -q 'refusing test hook TH_PROBE' "$hook_err"; then
	ok "(r) test_hook: newlines-only value: rc 1, nothing printed"
else
	fail "(r) test_hook: newlines-only value: rc=$rc val=$val"
fi

# --- count_missing pipeline status (pass-3 u02 #3) -------------------------
# The awk and sort stages must run as separate checked steps: in a pipeline
# only the LAST stage's status is visible, so a failed awk was lost entirely
# and a failed sort left the list empty - either read as a count of 0, i.e.
# "nothing is missing" when nothing was checked. The stubs pass through to
# the real tools unless their fail flag is set.
cat > "$TESTROOT/bin/awk" <<'EOF'
#!/bin/sh
# Stub awk(1) for the count_missing pipeline-status cases.
# Time:  O(1) flag check, then exec.  Space: O(1).
if [ "${FAKE_AWK_FAIL:-0}" = 1 ]; then
	echo "awk: stub failure" >&2
	exit 1
fi
exec /usr/bin/awk "$@"
EOF
cat > "$TESTROOT/bin/sort" <<'EOF'
#!/bin/sh
# Stub sort(1) for the count_missing pipeline-status cases.
# Time:  O(1) flag check, then exec.  Space: O(1).
if [ "${FAKE_SORT_FAIL:-0}" = 1 ]; then
	echo "sort: stub failure" >&2
	exit 1
fi
exec /usr/bin/sort "$@"
EOF
chmod +x "$TESTROOT/bin/awk" "$TESTROOT/bin/sort" || exit 1

# (s) the awk stage fails: rc 1, error on stderr, no count printed. Before
#     the separate-steps fix, awk's failure was invisible (the pipeline's
#     status is sort's) and the count printed as 0.
rc=0
val=$(run_fake_nm A "$cm_obj" "$cm_osdir" "$cm_scratch" 2>"$cm_err") || rc=$?
if [ "$rc" -eq 1 ] && [ -z "$val" ] && grep -q "count_missing" "$cm_err"; then
	ok "(s) count_missing: awk stage failure: rc 1, error on stderr"
else
	fail "(s) count_missing: awk stage failure: rc=$rc val=$val err=$(head -n 1 "$cm_err" 2>/dev/null)"
fi

# (t) the sort stage fails: rc 1, error on stderr, no count printed. Before
#     the fix, sort's failure was not checked either and the empty list
#     read as a count of 0.
rc=0
val=$(run_fake_nm S "$cm_obj" "$cm_osdir" "$cm_scratch" 2>"$cm_err") || rc=$?
if [ "$rc" -eq 1 ] && [ -z "$val" ] && grep -q "count_missing" "$cm_err"; then
	ok "(t) count_missing: sort stage failure: rc 1, error on stderr"
else
	fail "(t) count_missing: sort stage failure: rc=$rc val=$val err=$(head -n 1 "$cm_err" 2>/dev/null)"
fi

# --- patch_headers_safe TAB handling (pass-3 u02 #2) -----------------------
# patch(1) keeps spaces in a header path up to the TAB, so the gate must cut
# a trailing timestamp at the TAB only and refuse any path that still holds
# a blank: cutting at the first blank checked only "existing" of
# "existing dir/../../evil<TAB>date" (rc 0) while `patch -C -p0` reported
# "Creating file existing dir/../../evil" - a path that leaves the tree.
ph_tab_evil=$TESTROOT/patch-tab-evil
ph_tab_ok=$TESTROOT/patch-tab-ok
printf -- '--- existing dir/../../evil\t2026-01-01\n+++ existing dir/../../evil\t2026-01-01\n' > "$ph_tab_evil"
printf -- '--- nvidia/a.c\t2026-11-18 03:47:39.099320000 +0000\n+++ nvidia/a.c\t2026-11-18 03:48:37.282784000 +0000\n' > "$ph_tab_ok"

# (u) a path with a space hiding ../.. before the TAB timestamp: refused.
rc=0
patch_headers_safe "$ph_tab_evil" || rc=$?
if [ "$rc" -eq 1 ]; then
	ok "(u) patch_headers_safe: 'existing dir/../../evil<TAB>date' refused"
else
	fail "(u) patch_headers_safe: TAB-masked .. path accepted: rc=$rc"
fi

# (v) an ordinary header with a TAB timestamp (the repo's own patch format):
#     still accepted - the TAB cut must not over-refuse.
rc=0
patch_headers_safe "$ph_tab_ok" || rc=$?
if [ "$rc" -eq 0 ]; then
	ok "(v) patch_headers_safe: TAB-timestamp header accepted"
else
	fail "(v) patch_headers_safe: TAB-timestamp header refused: rc=$rc"
fi

echo "passed: $PASSED failed: $FAILED"
if [ "$FAILED" -gt 0 ]; then
	exit 1
fi
exit 0

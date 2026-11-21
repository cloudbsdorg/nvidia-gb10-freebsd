#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# linux_bridge_kit_test.sh - the one-shot test-boot kit of Track #2363
# (tests/linux-bridge-testboot): summarize.sh verdicts, the make-be.sh dry run
# and its refusals, and the structure of the recorder (phase A before the
# Linuxulator loads, the veto row, reverse unload). No bectl, no kldload.
set -u
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
export PATH
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
KIT=$HERE/linux-bridge-testboot
WORK=${GB10_WORK:-$HOME/work/gb10}
mkdir -p "$WORK/tmp"
TMPD=$(mktemp -d "$WORK/tmp/linux_bridge_kit_test.XXXXXXXX") || exit 1
trap 'rm -rf "$TMPD"' EXIT
fails=0
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }
pass() { echo "PASS: $*"; }

for f in linux_bridge_testboot summarize.sh make-be.sh; do
	sh -n "$KIT/$f" && pass "$f parses" || fail "$f has a syntax error"
done

row() { printf '{"row":"%s","result":"%s","detail":"%s"}\n' "$1" "$2" "$3"; }
{ row start info x; for r in $(sh "$KIT/summarize.sh" --required); do row "$r" pass ok; done; row done info end; } > "$TMPD/good.jsonl"
sed 's/"row":"C1-veto-nvidia","result":"pass"/"row":"C1-veto-nvidia","result":"fail"/' "$TMPD/good.jsonl" > "$TMPD/fail.jsonl"
{ row start info x; row A1-modeset pass ok; row B4-cuda running cuda; } > "$TMPD/died.jsonl"
{ row start info x; row A1 skip no; row done info end; } > "$TMPD/nopass.jsonl"
sh "$KIT/summarize.sh" "$TMPD/good.jsonl" > /dev/null && pass "a finished clean run is OK" || fail "a good run was refused"
sh "$KIT/summarize.sh" "$TMPD/fail.jsonl" > /dev/null && fail "plant: a failed row was accepted" || pass "plant: a failed row is refused"
sh "$KIT/summarize.sh" "$TMPD/died.jsonl" > /dev/null && fail "plant: a run that died in a step was accepted" || pass "plant: a trailing running row is refused"
grep -v 'C1-veto-modeset\|B2-modeset_linux' "$TMPD/good.jsonl" > "$TMPD/nomodeset.jsonl"
sh "$KIT/summarize.sh" "$TMPD/nomodeset.jsonl" > /dev/null && fail "plant: a run without the modeset provider rows was accepted" || pass "plant: a run without the modeset rows is refused"
sed 's/"row":"A4-nvrm-info","result":"pass"/"row":"A4-nvrm-info","result":"skip"/' "$TMPD/good.jsonl" > "$TMPD/skipped.jsonl"
sh "$KIT/summarize.sh" "$TMPD/skipped.jsonl" 2>&1 | grep -q 'SUMMARIZE_ALLOW_SKIP' && pass "the failure for a skipped row names SUMMARIZE_ALLOW_SKIP and the make-be.sh flags" || fail "the skipped-row failure does not say how to fix it"
sh "$KIT/summarize.sh" "$TMPD/fail.jsonl" 2>&1 | grep -q 'make-be.sh\|SUMMARIZE_ALLOW_SKIP' && fail "a failed C1 row gets a make-be or skip hint" || pass "a failed row gets no skip or make-be hint"
sh "$KIT/summarize.sh" "$TMPD/skipped.jsonl" > /dev/null && fail "plant: a skipped required row was accepted" || pass "plant: a skipped required row is refused"
SUMMARIZE_ALLOW_SKIP=1 sh "$KIT/summarize.sh" "$TMPD/skipped.jsonl" > /dev/null && pass "a skipped row is accepted only with SUMMARIZE_ALLOW_SKIP=1" || fail "SUMMARIZE_ALLOW_SKIP=1 was ignored"
sh "$KIT/summarize.sh" "$TMPD/nopass.jsonl" > /dev/null && fail "plant: a run with no pass row was accepted" || pass "plant: a run with no pass row is refused"

# make-be.sh: the dry run changes nothing and puts no Linux module in kld_list
out=$(sh "$KIT/make-be.sh" -b base --dry-run -t "$TMPD/none" 2>&1) && pass "dry run succeeds" || fail "dry run failed: $out"
case $out in *'linux_enable=NO'*) pass "the clone sets linux_enable=NO" ;; *) fail "no linux_enable=NO in the plan" ;; esac
case $out in *'kld_list="nvidia_gsp_ga10x_fw nvidia nvidia_modeset"'*) pass "kld_list is the native modules only" ;; *) fail "unexpected kld_list in the plan" ;; esac
case $out in *'cp '*nvidia_linux.ko*) pass "nvidia_linux.ko is staged" ;; *) fail "nvidia_linux.ko is not staged" ;; esac
for bad in linux64 linux_common nvidia_linux nvidia_modeset_linux nvidia_uvm; do
	sh "$KIT/make-be.sh" -b base --dry-run -k "nvidia $bad" > /dev/null 2>&1 && fail "plant: -k with $bad was accepted" || pass "plant: -k with $bad is refused"
done
sh "$KIT/make-be.sh" --dry-run > /dev/null 2>&1 && fail "plant: no -b was accepted" || pass "plant: a missing -b is refused"
sh "$KIT/make-be.sh" -b base --dry-run -i /x > /dev/null 2>&1 && fail "plant: -i without -p was accepted" || pass "plant: -i without -p is refused"
sh "$KIT/make-be.sh" -b base --dry-run -V 'a;b' > /dev/null 2>&1 && fail "plant: a bad -V was accepted" || pass "plant: a bad -V is refused"

# recorder structure, as functions that a mutant of the recorder must fail
K=$KIT/linux_bridge_testboot
# order_ok FILE: the no-Linux row precedes the Linuxulator load; the modeset
# veto precedes the modeset provider's unload; the nvidia veto comes after
# nvidia-modeset is unloaded (so nvidia_linux is the only holder of nvidia) and
# before nvidia_linux is unloaded.
order_ok() {
	a=$(grep -n 'row A2-no-linux ' "$1" | head -1 | cut -d: -f1)
	b=$(grep -n 'service linux onestart' "$1" | head -1 | cut -d: -f1)
	vm=$(grep -n 'veto C1-veto-modeset' "$1" | head -1 | cut -d: -f1)
	um=$(grep -n 'kldunload nvidia_modeset_linux' "$1" | head -1 | cut -d: -f1)
	xm=$(grep -n 'kldunload nvidia-modeset' "$1" | head -1 | cut -d: -f1)
	vn=$(grep -n 'veto C1-veto-nvidia nvidia nvidia' "$1" | head -1 | cut -d: -f1)
	un=$(grep -n 'kldunload nvidia_linux' "$1" | head -1 | cut -d: -f1)
	[ -n "$a" ] && [ -n "$b" ] && [ -n "$vm" ] && [ -n "$um" ] && [ -n "$xm" ] && [ -n "$vn" ] && [ -n "$un" ] || return 1
	[ "$a" -lt "$b" ] && [ "$vm" -lt "$um" ] && [ "$xm" -lt "$vn" ] && [ "$vn" -lt "$un" ]
}
order_ok "$K" && pass "the recorder runs phase A before the Linuxulator load and the veto before the provider unload" || fail "recorder order"
# move_line FILE PATTERN AFTER: the first line matching PATTERN is moved to just after the first line matching AFTER
move_line() {
	awk -v pat="$2" -v aft="$3" 'NR == FNR { if (!held && $0 ~ pat) { held = $0; hn = FNR } next }
	    FNR == hn { next } { print } !done && $0 ~ aft { print held; done = 1 }' "$1" "$1"
}
# plant 1: the Linuxulator load moved above the no-Linux row (and the mutant still has the line)
move_line "$K" 'service linux onestart' 'row start info' > "$TMPD/mut1"
grep -q 'service linux onestart' "$TMPD/mut1" && pass "plant 1 really moves the line (it is still there)" || fail "plant 1 deleted the line instead of moving it"
order_ok "$TMPD/mut1" && fail "plant: a recorder that loads linux64 first passed the order check" || pass "plant: loading linux64 first fails the order check"
# plant 2: the nvidia veto moved above the nvidia-modeset unload (nvidia-modeset still holds nvidia)
move_line "$K" 'veto C1-veto-nvidia nvidia nvidia' 'kldunload nvidia_modeset_linux' > "$TMPD/mut2"
grep -q 'veto C1-veto-nvidia nvidia nvidia' "$TMPD/mut2" && pass "plant 2 really moves the line" || fail "plant 2 deleted the line"
order_ok "$TMPD/mut2" && fail "plant: a nvidia veto while nvidia-modeset still holds nvidia passed" || pass "plant: the nvidia veto before the modeset unload fails the order check"
# plant 3: the modeset veto moved below the modeset provider's unload
move_line "$K" 'veto C1-veto-modeset nvidia-modeset' 'kldunload nvidia_modeset_linux' > "$TMPD/mut-veto-modeset"
grep -q 'veto C1-veto-modeset nvidia-modeset' "$TMPD/mut-veto-modeset" && pass "plant 3 really moves the line" || fail "plant 3 deleted the line"
order_ok "$TMPD/mut-veto-modeset" && fail "plant: a modeset veto after the provider unload passed" || pass "plant: the modeset veto after the provider unload fails the order check"
# kldunload takes FILE names: the hyphenated modules must not be named by module name
if grep -Eq 'kldunload (nvidia_modeset|nvidia_uvm)([^_A-Za-z]|$)' "$K"; then fail "the recorder unloads nvidia_modeset or nvidia_uvm by module name (kldunload takes the file name)"; else pass "the recorder unloads by file name"; fi
printf 'kldunload nvidia_modeset > x\n' > "$TMPD/mut3"
grep -Eq 'kldunload (nvidia_modeset|nvidia_uvm)([^_A-Za-z]|$)' "$TMPD/mut3" && pass "plant: the module-name check matches a module-name kldunload" || fail "plant: the module-name check cannot fire"
grep -q 'Device busy' "$K" && pass "the veto row asserts the reason (Device busy)" || fail "the veto row does not assert the reason"
grep -q 'boot_nvrm_info.sh' "$K" && pass "the nvrm-info proof is run in phase A" || fail "no nvrm-info proof"
# no developer home directory or user name in the kit, no mkdir -p on the run directory
if grep -n '/home/\|mlapointe' "$KIT"/linux_bridge_testboot "$KIT"/make-be.sh "$KIT"/summarize.sh; then fail "a home directory or user name is stored in the kit"; else pass "no home directory or user name in the kit"; fi
grep -q 'mkdir -p "$OUT"' "$K" && fail "the run directory is made with mkdir -p (follows a planted symlink)" || pass "the run directory is made with mktemp"
# behavioural plant: a planted symlink in the log root must not be followed
mkdir -p "$TMPD/lr" "$TMPD/bin"
chmod 755 "$TMPD/lr"
for c in kldstat kldunload kldload service sync dmesg shutdown; do printf '#!/bin/sh\nexit 0\n' > "$TMPD/bin/$c"; chmod +x "$TMPD/bin/$c"; done
printf '#!/bin/sh\necho 20260101T000000Z\n' > "$TMPD/bin/date"; chmod +x "$TMPD/bin/date"
echo victim > "$TMPD/victim"
ln -s "$TMPD/victim" "$TMPD/lr/linux-bridge-20260101T000000Z"
run_kit() {	# run_kit <logroot>: source the recorder with rc.subr stubbed out, call its start
	env PATH="$TMPD/bin:$PATH" LINUX_BRIDGE_TESTBOOT_SOURCE_ONLY=1 sh -c '
		. "$2"
		linux_bridge_testboot_logroot="$1"
		linux_bridge_testboot_owner=$(id -u)
		linux_bridge_testboot_nvrm_info=/nonexistent/nvrm-info
		linux_bridge_testboot_nvrm_proof=/nonexistent/boot_nvrm_info.sh
		linux_bridge_testboot_deadman=0
		linux_bridge_testboot_start' sh "$1" "${2:-$K}" 2>&1
}
run_kit "$TMPD/lr" > "$TMPD/run1.out" || true
ls "$TMPD"/lr/linux-bridge-20260101T000000Z.*/results.jsonl > /dev/null 2>&1 && pass "the run directory is a fresh mktemp directory beside the planted name" || fail "no fresh run directory: $(head -2 "$TMPD/run1.out")"
[ "$(cat "$TMPD/victim")" = victim ] && pass "a planted symlink under the log root was not written through" || fail "the recorder wrote through a planted symlink"
# plant: a recorder that names the run directory by the stamp alone writes through the planted link
sed 's|OUT=$(mktemp -d "$_lr/linux-bridge-$STAMP.XXXXXX") \|\| return 1|OUT=$_lr/linux-bridge-$STAMP; mkdir -p "$OUT"; ln -sf "$TMPD/victim" "$OUT/results.jsonl"|' "$K" > "$TMPD/mutk"
export TMPD
rm -rf "$TMPD/lr2"; mkdir -p "$TMPD/lr2"; chmod 755 "$TMPD/lr2"; echo victim > "$TMPD/victim2"
sed -i '' "s|\$TMPD/victim|$TMPD/victim2|" "$TMPD/mutk"
run_kit "$TMPD/lr2" "$TMPD/mutk" > /dev/null 2>&1 || true
[ "$(cat "$TMPD/victim2")" = victim ] && fail "plant: the stamp-named recorder did not write through (the check cannot fire)" || pass "plant: a stamp-named run directory writes through a planted link (the check can fire)"
ln -s "$TMPD/lr" "$TMPD/lrlink"
run_kit "$TMPD/lrlink" > "$TMPD/lrlink.out" || true
grep -q 'refusing log root' "$TMPD/lrlink.out" && pass "a symbolic-link log root is refused" || fail "a symbolic-link log root was accepted: $(head -2 "$TMPD/lrlink.out")"
sh "$KIT/make-be.sh" -b base --dry-run -U x > /dev/null 2>&1 && fail "plant: -U without -C was accepted" || pass "plant: -U without -C is refused"
sh "$KIT/make-be.sh" -b base --dry-run -U x -C /p/run.sh > /dev/null 2>&1 && fail "plant: -U and -C without -u was accepted" || pass "plant: -U and -C without -u is refused"
sh "$KIT/make-be.sh" -b base --dry-run 2>&1 | grep -q 'row A4' && pass "make-be.sh warns that A4 will be a skip without -i and -p" || fail "no warning for the missing nvrm-info"
sh "$KIT/make-be.sh" -b base --dry-run -L 'rel/path' > /dev/null 2>&1 && fail "plant: a relative -L was accepted" || pass "plant: a relative -L is refused"

[ "$fails" -eq 0 ] || { echo "linux_bridge_kit_test: $fails FAILED" >&2; exit 1; }
echo "linux_bridge_kit_test: all passed"

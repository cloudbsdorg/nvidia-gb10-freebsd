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
H1=1111111111111111111111111111111111111111111111111111111111111111
good_rows() {	# good_rows <kit commit> <loaded hash of nvidia.ko>
	row start info "2026-11-22T00:00:00Z host kit $1"
	for m in nvidia.ko nvidia-modeset.ko nvidia_linux.ko nvidia_modeset_linux.ko; do
		row HASH-staged info "$m $H1"
		if [ "$m" = nvidia.ko ]; then row HASH-loaded info "$m $2"; else row HASH-loaded info "$m $H1"; fi
	done
	for r in $(sh "$KIT/summarize.sh" --required); do row "$r" pass ok; done
	row C4-modeset pass ok
	row C4-nvidia pass ok
	row done info end
}
good_rows abc123 "$H1" > "$TMPD/good.jsonl"
for m in nvidia.ko nvidia-modeset.ko nvidia_linux.ko nvidia_modeset_linux.ko; do echo "$H1 $m"; done > "$TMPD/armed.sha256"
sed 's/"row":"C1-veto-nvidia","result":"pass"/"row":"C1-veto-nvidia","result":"fail"/' "$TMPD/good.jsonl" > "$TMPD/fail.jsonl"
{ row start info "x kit abc123"; row A1-modeset pass ok; row B4-cuda running cuda; } > "$TMPD/died.jsonl"
{ row start info "x kit abc123"; row A1 skip no; row done info end; } > "$TMPD/nopass.jsonl"
sh "$KIT/summarize.sh" "$TMPD/good.jsonl" > /dev/null && pass "a finished clean run is OK" || fail "a good run was refused"
sh "$KIT/summarize.sh" "$TMPD/fail.jsonl" > /dev/null && fail "plant: a failed row was accepted" || pass "plant: a failed row is refused"
sh "$KIT/summarize.sh" "$TMPD/died.jsonl" > /dev/null && fail "plant: a run that died in a step was accepted" || pass "plant: a trailing running row is refused"
grep -v 'C1-veto-modeset\|B2-modeset_linux' "$TMPD/good.jsonl" > "$TMPD/nomodeset.jsonl"
sh "$KIT/summarize.sh" "$TMPD/nomodeset.jsonl" > /dev/null && fail "plant: a run without the modeset provider rows was accepted" || pass "plant: a run without the modeset rows is refused"
sed 's/"row":"A4-nvrm-info","result":"pass"/"row":"A4-nvrm-info","result":"skip"/' "$TMPD/good.jsonl" > "$TMPD/skipped.jsonl"
sh "$KIT/summarize.sh" "$TMPD/skipped.jsonl" 2>&1 | grep -q 'cannot be waived' && sh "$KIT/summarize.sh" "$TMPD/skipped.jsonl" 2>&1 | grep -q 'make-be.sh -i and -p' && pass "the failure for a skipped nvrm-info row says it cannot be waived and names the make-be.sh flags" || fail "the skipped-row failure does not say how to fix it"
sed 's/"row":"B4-cuda","result":"pass"/"row":"B4-cuda","result":"skip"/' "$TMPD/good.jsonl" > "$TMPD/cudaskip0.jsonl"
sh "$KIT/summarize.sh" "$TMPD/cudaskip0.jsonl" 2>&1 | grep -q 'SUMMARIZE_ALLOW_SKIP=B4-cuda' && pass "the failure for a skipped B4-cuda names the waiver, by row" || fail "the B4-cuda skip failure does not name the waiver"
sh "$KIT/summarize.sh" "$TMPD/fail.jsonl" 2>&1 | grep -q 'make-be.sh\|SUMMARIZE_ALLOW_SKIP' && fail "a failed C1 row gets a make-be or skip hint" || pass "a failed row gets no skip or make-be hint"
sh "$KIT/summarize.sh" "$TMPD/skipped.jsonl" > /dev/null && fail "plant: a skipped required row was accepted" || pass "plant: a skipped required row is refused"
SUMMARIZE_ALLOW_SKIP=1 sh "$KIT/summarize.sh" "$TMPD/skipped.jsonl" > "$TMPD/w1.out" 2>&1 && fail "plant: SUMMARIZE_ALLOW_SKIP=1 waived a row" || { grep -q 'only B4-cuda may be waived' "$TMPD/w1.out" && pass "SUMMARIZE_ALLOW_SKIP=1 (a blanket waiver) is refused and says which row may be waived" || fail "the blanket waiver is refused without the reason: $(head -2 "$TMPD/w1.out")"; }
SUMMARIZE_ALLOW_SKIP=A4-nvrm-info sh "$KIT/summarize.sh" "$TMPD/skipped.jsonl" > /dev/null 2>&1 && fail "plant: the nvrm-info row was waived" || pass "plant: A4-nvrm-info cannot be waived"
sed 's/"row":"C1-veto-nvidia","result":"pass"/"row":"C1-veto-nvidia","result":"skip"/' "$TMPD/good.jsonl" > "$TMPD/vetoskip.jsonl"
for w in C1-veto-nvidia C1-veto-modeset B2-refs-nvidia "B4-cuda C1-veto-nvidia"; do
	SUMMARIZE_ALLOW_SKIP=$w sh "$KIT/summarize.sh" "$TMPD/vetoskip.jsonl" > /dev/null 2>&1 && fail "plant: a skipped veto row was waived with [$w]" || pass "plant: a skipped veto row cannot be waived with [$w]"
done
sed 's/"row":"B4-cuda","result":"pass"/"row":"B4-cuda","result":"skip"/' "$TMPD/good.jsonl" > "$TMPD/cudaskip.jsonl"
SUMMARIZE_ALLOW_SKIP=B4-cuda sh "$KIT/summarize.sh" "$TMPD/cudaskip.jsonl" > "$TMPD/w2.out" 2>&1 && grep -q '^PARTIAL' "$TMPD/w2.out" && ! grep -q '^OK' "$TMPD/w2.out" && pass "a skipped B4-cuda is waivable by name and the verdict is PARTIAL, not OK" || fail "B4-cuda waiver: $(tail -2 "$TMPD/w2.out")"
sh "$KIT/summarize.sh" "$TMPD/cudaskip.jsonl" > /dev/null 2>&1 && fail "plant: a skipped B4-cuda was accepted with no waiver" || pass "plant: a skipped B4-cuda needs the waiver"
# arguments: --kit and --hashes go together, and nothing may follow the results file
sh "$KIT/summarize.sh" --kit abc123 "$TMPD/good.jsonl" > /dev/null 2>&1 && fail "plant: --kit without --hashes was accepted" || pass "plant: --kit without --hashes is refused"
sh "$KIT/summarize.sh" --hashes "$TMPD/armed.sha256" "$TMPD/good.jsonl" > /dev/null 2>&1 && fail "plant: --hashes without --kit was accepted" || pass "plant: --hashes without --kit is refused"
sh "$KIT/summarize.sh" "$TMPD/good.jsonl" --kit def456 > /dev/null 2>&1 && fail "plant: options after the results file were silently dropped" || pass "plant: arguments after the results file are refused"
sed 's/"row":"B3-nvkms-ioctl","result":"pass"/"row":"B3-nvkms-ioctl","result":"skip"/' "$TMPD/good.jsonl" > "$TMPD/b3skip.jsonl"
sh "$KIT/summarize.sh" "$TMPD/b3skip.jsonl" 2>&1 | grep -q 'nvidia_modeset_linux is not loaded' && pass "a skipped B3-nvkms-ioctl names nvidia_modeset_linux" || fail "the B3 skip hint does not name the provider"
# provenance: kit commit and staged against loaded hashes
sed 's/ kit abc123/ kit unknown/' "$TMPD/good.jsonl" > "$TMPD/nokit.jsonl"
sh "$KIT/summarize.sh" "$TMPD/nokit.jsonl" > /dev/null 2>&1 && fail "plant: a run with no kit commit was accepted" || pass "plant: a run whose start row has no kit commit is refused"
grep -v '^{"row":"start"' "$TMPD/good.jsonl" > "$TMPD/nostart.jsonl"
sh "$KIT/summarize.sh" "$TMPD/nostart.jsonl" > /dev/null 2>&1 && fail "plant: a run with no start row was accepted" || pass "plant: a run with no start row is refused"
H2=2222222222222222222222222222222222222222222222222222222222222222
good_rows abc123 "$H2" > "$TMPD/stale.jsonl"
sh "$KIT/summarize.sh" "$TMPD/stale.jsonl" > "$TMPD/stale.out" 2>&1 && fail "plant: a loaded nvidia.ko that is not the staged one was accepted" || { grep -q 'is not the staged one' "$TMPD/stale.out" && pass "plant: a loaded module that is not the staged one is refused" || fail "stale-module refusal without the reason: $(tail -1 "$TMPD/stale.out")"; }
grep -v 'HASH-loaded' "$TMPD/good.jsonl" > "$TMPD/noloaded.jsonl"
sh "$KIT/summarize.sh" "$TMPD/noloaded.jsonl" > /dev/null 2>&1 && fail "plant: a run with no loaded-module hashes was accepted" || pass "plant: a run with no loaded-module hashes is refused"
sh "$KIT/summarize.sh" --kit abc123 --hashes "$TMPD/armed.sha256" "$TMPD/good.jsonl" > "$TMPD/prov.out" 2>&1 && grep -q '^OK' "$TMPD/prov.out" && pass "--kit and --hashes that match the results give OK" || fail "matching --kit/--hashes: $(tail -2 "$TMPD/prov.out")"
sh "$KIT/summarize.sh" --kit def456 --hashes "$TMPD/armed.sha256" "$TMPD/good.jsonl" > /dev/null 2>&1 && fail "plant: results of another kit were accepted" || pass "plant: results from another kit commit are refused"
sed "s/^$H1 nvidia.ko/$H2 nvidia.ko/" "$TMPD/armed.sha256" > "$TMPD/armed2.sha256"
sh "$KIT/summarize.sh" --kit abc123 --hashes "$TMPD/armed2.sha256" "$TMPD/good.jsonl" > /dev/null 2>&1 && fail "plant: results of other modules were accepted" || pass "plant: results that do not match the armed hash list are refused"
# C4: the unloads after the providers are required unless nvidia_drm holds the core (C4-core skipped)
grep -v 'C4-nvidia' "$TMPD/good.jsonl" > "$TMPD/noc4.jsonl"
sh "$KIT/summarize.sh" "$TMPD/noc4.jsonl" > /dev/null 2>&1 && fail "plant: a run with no C4-nvidia row was accepted" || pass "plant: a run without C4-nvidia is refused when nvidia_drm is absent"
{ grep -v 'C4-nvidia\|C4-modeset\|"row":"done"' "$TMPD/good.jsonl"; row C4-core skip "nvidia_drm is loaded; the core stays"; row done info end; } > "$TMPD/drm.jsonl"
sh "$KIT/summarize.sh" "$TMPD/drm.jsonl" > /dev/null 2>&1 && pass "with nvidia_drm loaded (C4-core skipped) the C4 rows are not required" || fail "a nvidia_drm run was refused for its C4 rows"
sh "$KIT/summarize.sh" "$TMPD/nopass.jsonl" > /dev/null && fail "plant: a run with no pass row was accepted" || pass "plant: a run with no pass row is refused"

# make-be.sh: the dry run changes nothing and puts no Linux module in kld_list
out=$(sh "$KIT/make-be.sh" -b base --dry-run -t "$TMPD/none" 2>&1) && pass "dry run succeeds" || fail "dry run failed: $out"
case $out in *'linux_enable=NO'*) pass "the clone sets linux_enable=NO" ;; *) fail "no linux_enable=NO in the plan" ;; esac
case $out in *'kld_list="nvidia_gsp_ga10x_fw nvidia nvidia-modeset"'*) pass "kld_list is the native modules only, by file name" ;; *) fail "unexpected kld_list in the plan" ;; esac
case $out in *'testboot-return'*) pass "the plan installs testboot-return" ;; *) fail "the plan does not install testboot-return" ;; esac
case $out in *'kldxref'*) pass "the plan runs kldxref on the staged directory" ;; *) fail "the plan has no kldxref" ;; esac
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
# the Refs evidence of the veto: refs_row passes only when the provider added exactly one
# reference (a provider with no MODULE_DEPEND, or one that raced another holder, does not)
refs_case() {	# refs_case <before> <after>: the result word refs_row writes
	: > "$TMPD/refs.jsonl"
	env LINUX_BRIDGE_TESTBOOT_SOURCE_ONLY=1 sh -c '
		. "$1"; OUT=$2; sync() { :; }
		refs_row B2-refs-nvidia nvidia "$3" "$4" nvidia_linux' sh "$K" "$TMPD" "$1" "$2" > /dev/null 2>&1
	mv "$TMPD/results.jsonl" "$TMPD/refs.jsonl" 2> /dev/null
	sed -n 's/^{"row":"B2-refs-nvidia","result":"\([a-z]*\)".*/\1/p' "$TMPD/refs.jsonl"
}
[ "$(refs_case 1 2)" = pass ] && pass "refs_row: one more reference after the provider loads passes" || fail "refs_row: 1 -> 2 is not a pass"
[ "$(refs_case 1 1)" = fail ] && pass "plant: a provider that adds no reference (no MODULE_DEPEND) fails the Refs row" || fail "plant: 1 -> 1 was accepted"
[ "$(refs_case 1 3)" = fail ] && pass "plant: two extra references (another holder) fail the Refs row" || fail "plant: 1 -> 3 was accepted"
[ "$(refs_case "" 2)" = fail ] && pass "plant: an unreadable Refs column fails the row" || fail "plant: an unreadable before value was accepted"
[ "$(refs_case 1 x)" = fail ] && pass "plant: a non-numeric Refs value fails the row" || fail "plant: a non-numeric after value was accepted"
# the recorder reads the count before the provider's kldload and after it, for both providers
refs_struct_ok() {	# refs_struct_ok <recorder>: for each provider the count is read before the rc script runs and its row follows
	for pair in 'r0=\$(refs_of nvidia)|refs_row B2-refs-nvidia ' 'm0=\$(refs_of nvidia-modeset)|refs_row B2-refs-modeset '; do
		_b=$(grep -n "_${pair%%|*}" "$1" | head -1 | cut -d: -f1)
		_l=$(grep -n 'service nvidia_linux onestart' "$1" | head -1 | cut -d: -f1)
		_a=$(grep -n "${pair##*|}" "$1" | awk -F: -v l="${_l:-0}" '$1 > l { print $1; exit }')
		[ -n "$_b" ] && [ -n "$_l" ] && [ -n "$_a" ] && [ "$_b" -lt "$_l" ] && [ "$_l" -lt "$_a" ] || return 1
	done
}
refs_struct_ok "$K" && pass "the recorder reads Refs before and after each provider's kldload" || fail "the recorder does not read Refs around the provider loads"
sed 's/refs_row B2-refs/: B2-refs/' "$K" > "$TMPD/mut-norefs"
refs_struct_ok "$TMPD/mut-norefs" && fail "plant: a recorder without the Refs rows passed the structure check" || pass "plant: a recorder without the Refs rows fails the structure check"
# plant: only the nvidia row deleted (the modeset row after it must not stand in for it)
sed 's/refs_row B2-refs-nvidia /: B2-refs-nvidia /' "$K" > "$TMPD/mut-onerow"
cmp -s "$K" "$TMPD/mut-onerow" && fail "plant: the one-row sed changed nothing" || { refs_struct_ok "$TMPD/mut-onerow" && fail "plant: a recorder without the nvidia Refs row passed the structure check" || pass "plant: deleting only the nvidia Refs row fails the structure check"; }
# the failure detail points at the before/after snapshots, and summarize.sh hints at them
refs_case 1 3 > /dev/null
grep -q 'refs-B2-refs-nvidia' "$TMPD/refs.jsonl" && pass "a failed Refs row names the kldstat snapshots" || fail "a failed Refs row does not name the snapshots"
sed 's/"row":"B2-refs-nvidia","result":"pass","detail":"ok"/"row":"B2-refs-nvidia","result":"fail","detail":"kldstat Refs of nvidia: 1 before, 3 after"/' "$TMPD/good.jsonl" > "$TMPD/refsfail.jsonl"
sh "$KIT/summarize.sh" "$TMPD/refsfail.jsonl" 2>&1 | grep -q 'refs-B2-refs-nvidia-before' && pass "summarize.sh hints at the Refs snapshots for a failed Refs row" || fail "no snapshot hint for a failed Refs row"
sed 's/"row":"B2-modeset_linux","result":"pass"/"row":"B2-modeset_linux","result":"skip"/' "$TMPD/good.jsonl" > "$TMPD/mskip.jsonl"
sh "$KIT/summarize.sh" "$TMPD/mskip.jsonl" 2>&1 | grep -q 'nvidia-modeset (the file name) to kld_list' && pass "a skipped B2-modeset_linux gets the kld_list hint naming the file" || fail "no hint for a skipped B2-modeset_linux"
move_line "$K" '_r0=.*refs_of nvidia[)]' 'service nvidia_linux onestart' > "$TMPD/mut-lateref" 2> /dev/null
grep -q '_r0=.*refs_of nvidia[)]' "$TMPD/mut-lateref" && ! cmp -s "$K" "$TMPD/mut-lateref" && pass "plant: the late-read mutant moved the line and kept it" || fail "plant: the late-read mutant lost or kept the line in place"
refs_struct_ok "$TMPD/mut-lateref" && fail "plant: reading the Refs after the load passed the structure check" || pass "plant: reading the Refs after the load fails the structure check"
# a Refs row that failed because the provider did not load has no snapshots: no snapshot hint
sed 's/"row":"B2-refs-nvidia","result":"pass","detail":"ok"/"row":"B2-refs-nvidia","result":"fail","detail":"nvidia_linux did not load: no reference count"/' "$TMPD/good.jsonl" > "$TMPD/refsnoload.jsonl"
sh "$KIT/summarize.sh" "$TMPD/refsnoload.jsonl" 2>&1 | grep -q 'refs-B2-refs-nvidia-after' && fail "a Refs row that failed on a load failure gets the snapshot hint" || pass "a Refs row that failed on a load failure gets no snapshot hint"
# the verdict needs the Refs rows: a run without them is refused
grep -v 'B2-refs' "$TMPD/good.jsonl" > "$TMPD/norefs.jsonl"
sh "$KIT/summarize.sh" "$TMPD/norefs.jsonl" > /dev/null && fail "plant: a run without the Refs rows was accepted" || pass "plant: a run without the Refs rows is refused"
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
mkdir -p "$TMPD/rcconfd"
echo abc123 > "$TMPD/kit.version"
export TMPD
printf '#!/bin/sh\necho "$@" > "$TMPD/return.args"\nexit 0\n' > "$TMPD/bin/testboot-return"; chmod +x "$TMPD/bin/testboot-return"
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
		linux_bridge_testboot_rcconfd=$TMPD/rcconfd
		linux_bridge_testboot_return=$TMPD/bin/testboot-return
		linux_bridge_testboot_normal_be=normal-be
		linux_bridge_testboot_copyout=$TMPD/copyout
		linux_bridge_testboot_hashes=$TMPD/nohashes
		linux_bridge_testboot_version=$TMPD/kit.version
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
# the start row the recorder really writes is what summarize.sh parses for the kit commit
_real=$(ls -d "$TMPD"/lr/linux-bridge-2026*.*/results.jsonl 2> /dev/null | tail -1)
{ grep '"row":"start"' "$_real"; grep -v '"row":"start"' "$TMPD/good.jsonl"; } > "$TMPD/realstart.jsonl"
sh "$KIT/summarize.sh" --kit abc123 --hashes "$TMPD/armed.sha256" "$TMPD/realstart.jsonl" > "$TMPD/realstart.out" 2>&1 && pass "summarize.sh reads the kit commit from the start row the recorder writes" || fail "summarize.sh does not parse the recorder's start row: $(grep "^FAIL" "$TMPD/realstart.out" | head -1)"
# the last step: results copied out, then testboot-return of the normal BE, and nothing after it
export TMPD
run_kit "$TMPD/lr" > "$TMPD/run2.out" || true
[ "$(cat "$TMPD/return.args" 2> /dev/null)" = normal-be ] && pass "the recorder ends with testboot-return NORMAL_BE" || fail "testboot-return was not called with the normal BE: [$(cat "$TMPD/return.args" 2> /dev/null)]"
ls "$TMPD"/copyout/linux-bridge-*/results.jsonl > /dev/null 2>&1 && pass "the run is copied out before the return" || fail "no copied-out results.jsonl"
_cl=$(grep -n 'copied the run to\|COULD NOT copy' "$TMPD/run2.out" | head -1 | cut -d: -f1)
_tr=$(grep -n 'testboot-return exit' "$TMPD/run2.out" | head -1 | cut -d: -f1)
[ -n "$_cl" ] && [ -n "$_tr" ] && [ "$_cl" -lt "$_tr" ] && pass "the copy-out line precedes the testboot-return line" || fail "copy-out [$_cl] and return [$_tr] are not in that order"
tail -n 12 "$K" | grep -q 'return 0' && ! sed -n '/linux_bridge_testboot_return"/,$p' "$K" | grep -q 'kldunload\|kldload' && pass "nothing loads or unloads after testboot-return" || fail "the recorder acts after testboot-return"
sed 's|^	"$linux_bridge_testboot_return" "$linux_bridge_testboot_normal_be".*|	: no return|' "$K" > "$TMPD/mut-noreturn"
rm -f "$TMPD/return.args"
run_kit "$TMPD/lr" "$TMPD/mut-noreturn" > /dev/null 2>&1 || true
[ -f "$TMPD/return.args" ] && fail "plant: a recorder without the return step still called it" || pass "plant: a recorder without the return step never calls testboot-return"
# root must not write through a copy-out directory that is a symbolic link
mkdir -p "$TMPD/victim-dir"
rm -rf "$TMPD/copyout"
ln -s "$TMPD/victim-dir" "$TMPD/copyout"
run_kit "$TMPD/lr" > "$TMPD/run3.out" || true
[ -z "$(ls "$TMPD/victim-dir")" ] && pass "a copy-out directory that is a symbolic link is not written through" || fail "the recorder wrote into the victim behind a copy-out link: $(ls "$TMPD/victim-dir")"
rm -f "$TMPD/copyout"
# no normal BE named: the return is not called, and a fail row says so
rm -f "$TMPD/return.args"
env PATH="$TMPD/bin:$PATH" LINUX_BRIDGE_TESTBOOT_SOURCE_ONLY=1 sh -c '
	. "$2"
	linux_bridge_testboot_logroot="$1"; linux_bridge_testboot_owner=$(id -u)
	linux_bridge_testboot_nvrm_info=/nonexistent; linux_bridge_testboot_nvrm_proof=/nonexistent
	linux_bridge_testboot_deadman=0; linux_bridge_testboot_rcconfd=$TMPD/rcconfd
	linux_bridge_testboot_return=$TMPD/bin/testboot-return; linux_bridge_testboot_normal_be=
	linux_bridge_testboot_copyout=$TMPD/copyout2; linux_bridge_testboot_hashes=$TMPD/nohashes
	linux_bridge_testboot_start' sh "$TMPD/lr" "$K" > "$TMPD/run4.out" 2>&1 || true
[ ! -f "$TMPD/return.args" ] && grep -q 'no linux_bridge_testboot_normal_be' "$TMPD"/lr/linux-bridge-2026*.*/results.jsonl && pass "with no normal BE named the return is not called and a fail row says so" || fail "an unset normal BE was not refused"
# the return: held (3), failed (1) and a missing copy-out leave rows, and done stays the last row
ret_case() {	# ret_case <return exit status> [copyout dir]: runs the recorder; prints "cancelled" when the dead-man was cancelled
	rm -f "$TMPD/cancelled"
	printf '#!/bin/sh\necho "return said no" >&2\nexit %s\n' "$1" > "$TMPD/bin/testboot-return"
	chmod +x "$TMPD/bin/testboot-return"
	rm -rf "$TMPD/lr3"; mkdir -p "$TMPD/lr3"; chmod 755 "$TMPD/lr3"
	env PATH="$TMPD/bin:$PATH" LINUX_BRIDGE_TESTBOOT_SOURCE_ONLY=1 sh -c '
		. "$2"
		deadman_cancel() { : > "$TMPD/cancelled"; }
		linux_bridge_testboot_logroot="$1"; linux_bridge_testboot_owner=$(id -u)
		linux_bridge_testboot_nvrm_info=/nonexistent; linux_bridge_testboot_nvrm_proof=/nonexistent
		linux_bridge_testboot_deadman=0; linux_bridge_testboot_rcconfd=$TMPD/rcconfd
		linux_bridge_testboot_return=$TMPD/bin/testboot-return; linux_bridge_testboot_normal_be=normal-be
		linux_bridge_testboot_copyout=${3:-$TMPD/copyout3}; linux_bridge_testboot_hashes=$TMPD/nohashes
		linux_bridge_testboot_start' sh "$TMPD/lr3" "$K" "${2:-}" > "$TMPD/ret.out" 2>&1 || true
	_res=$(ls "$TMPD"/lr3/linux-bridge-*/results.jsonl | tail -1)
}
ret_case 3
[ -f "$TMPD/cancelled" ] && grep -q '"row":"return","result":"info"' "$_res" && [ "$(tail -n 1 "$_res" | cut -c1-13)" = '{"row":"done"' ] && pass "a held return (exit 3) cancels the dead-man, leaves a return row and ends with done" || fail "held return: cancelled=$([ -f "$TMPD/cancelled" ] && echo yes || echo no) last=$(tail -n 1 "$_res")"
ret_case 1
[ ! -f "$TMPD/cancelled" ] && grep -q '"row":"return","result":"fail"' "$_res" && [ "$(tail -n 1 "$_res" | cut -c1-13)" = '{"row":"done"' ] && pass "a failed return (exit 1) leaves the dead-man pending, a fail row, and done last" || fail "failed return: cancelled=$([ -f "$TMPD/cancelled" ] && echo yes || echo no) last=$(tail -n 1 "$_res")"
sh "$KIT/summarize.sh" "$_res" 2>&1 | grep -q 'FAIL' && pass "summarize.sh fails a run whose return failed" || fail "summarize.sh does not see the failed return"
grep -q 'return said no' "$TMPD"/copyout3/linux-bridge-*/testboot-return.txt 2> /dev/null && pass "the failed return's output is in the copied-out run" || fail "the return output was not copied out"
ret_case 0
[ ! -f "$TMPD/cancelled" ] && ! grep -q '"row":"return"' "$_res" && pass "a return that exits 0 adds no row and leaves the dead-man alone" || fail "return exit 0 left a row or cancelled the dead-man"
printf 'x\n' > "$TMPD/notadir"
ret_case 0 "$TMPD/notadir/sub"
grep -q '"row":"copyout","result":"fail"' "$_res" && [ "$(tail -n 1 "$_res" | cut -c1-13)" = '{"row":"done"' ] && pass "a copy-out that fails is a row (naming the boot environment), with done last" || fail "copy-out failure: $(tail -n 2 "$_res")"
printf '#!/bin/sh\necho "$@" > "$TMPD/return.args"\nexit 0\n' > "$TMPD/bin/testboot-return"; chmod +x "$TMPD/bin/testboot-return"
grep -q 'linux_enable="YES"' "$TMPD/rcconfd/linux" && grep -q 'nvidia_linux_mode="AUTO"' "$TMPD/rcconfd/nvidia_linux" && pass "phase B turns on the Linuxulator and rc.d/nvidia_linux in AUTO mode, in the rc.conf.d it was given" || fail "phase B did not write the rc.conf.d files"
grep -q 'service nvidia_linux onestart' "$K" && ! grep -q 'kldload nvidia_linux\|kldload nvidia_modeset_linux' "$K" && pass "the providers load through rc.d/nvidia_linux, not by kldload" || fail "the recorder loads a provider by kldload instead of the rc script"
# loaded_proof: the kernel loaded the staged file (path by kldstat -v, sha256 of that file)
ST=$TMPD/staged; mkdir -p "$ST"
echo native > "$ST/nvidia.ko"
HS=$(sha256 -q "$ST/nvidia.ko")
echo "$HS nvidia.ko" > "$TMPD/h.sha256"
proof_case() {	# proof_case <path kldstat prints> <hash list file>: the result of loaded_proof
	printf '#!/bin/sh\necho "Id Refs Address Size Name"\necho " 5 1 0xffff 100 nvidia.ko (%s)"\necho "\tContains modules:"\n' "$1" > "$TMPD/bin/kldstat"
	: > "$TMPD/proof.jsonl"
	env PATH="$TMPD/bin:$PATH" LINUX_BRIDGE_TESTBOOT_SOURCE_ONLY=1 sh -c '
		. "$1"; OUT=$2; sync() { :; }
		linux_bridge_testboot_hashes=$3; linux_bridge_testboot_stagedir=$4
		loaded_proof A1-staged-nvidia nvidia.ko' sh "$K" "$TMPD" "$2" "$ST" > /dev/null 2>&1
	mv "$TMPD/results.jsonl" "$TMPD/proof.jsonl" 2> /dev/null
	sed -n 's/^{"row":"A1-staged-nvidia","result":"\([a-z]*\)".*/\1/p' "$TMPD/proof.jsonl"
}
[ "$(proof_case "$ST/nvidia.ko" "$TMPD/h.sha256")" = pass ] && pass "loaded_proof: the staged file loaded from the staged directory passes" || fail "loaded_proof refused the staged file"
grep -q "HASH-staged.*nvidia.ko $HS" "$TMPD/proof.jsonl" && grep -q "HASH-loaded.*nvidia.ko $HS" "$TMPD/proof.jsonl" && pass "loaded_proof writes the HASH-staged and HASH-loaded rows" || fail "loaded_proof rows: $(cat "$TMPD/proof.jsonl")"
mkdir -p "$TMPD/other"; echo native > "$TMPD/other/nvidia.ko"
[ "$(proof_case "$TMPD/other/nvidia.ko" "$TMPD/h.sha256")" = fail ] && pass "plant: a module loaded from another directory (same bytes) fails loaded_proof" || fail "plant: a module from /boot/modules was accepted"
echo "$(echo different | sha256 -q) nvidia.ko" > "$TMPD/h2.sha256"
[ "$(proof_case "$ST/nvidia.ko" "$TMPD/h2.sha256")" = fail ] && pass "plant: a loaded file whose hash is not the staged one fails loaded_proof" || fail "plant: a hash mismatch was accepted"
[ "$(proof_case "$ST/nvidia.ko" "$TMPD/nohashes")" = fail ] && pass "plant: no staged hash list fails loaded_proof" || fail "plant: a missing hash list was accepted"
[ "$(proof_case "" "$TMPD/h.sha256")" = fail ] && pass "plant: no path from kldstat fails loaded_proof" || fail "plant: an unreadable kldstat path was accepted"
printf '#!/bin/sh\nexit 0\n' > "$TMPD/bin/kldstat"
ln -s "$TMPD/lr" "$TMPD/lrlink"
run_kit "$TMPD/lrlink" > "$TMPD/lrlink.out" || true
grep -q 'refusing log root' "$TMPD/lrlink.out" && pass "a symbolic-link log root is refused" || fail "a symbolic-link log root was accepted: $(head -2 "$TMPD/lrlink.out")"
sh "$KIT/make-be.sh" -b base --dry-run -U x > /dev/null 2>&1 && fail "plant: -U without -C was accepted" || pass "plant: -U without -C is refused"
sh "$KIT/make-be.sh" -b base --dry-run -U x -C /p/run.sh > /dev/null 2>&1 && fail "plant: -U and -C without -u was accepted" || pass "plant: -U and -C without -u is refused"
sh "$KIT/make-be.sh" -b base --dry-run 2>&1 | grep -q 'row A4' && pass "make-be.sh warns that A4 will be a skip without -i and -p" || fail "no warning for the missing nvrm-info"
sh "$KIT/make-be.sh" -b base --dry-run -L 'rel/path' > /dev/null 2>&1 && fail "plant: a relative -L was accepted" || pass "plant: a relative -L is refused"

# ---- the Linux NVKMS probe: its logic on the host against a fake syscall layer (the real one is a raw
# Linux system call and cannot run here). The ioctl command is _IOWR('m', 0, 16 bytes) in Linux's encoding.
PH=$TMPD/probe_host
mkdir -p "$PH"
cat > "$PH/harness.c" <<'EOT'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int probe_main(void);
static long open_ret, ioctl_ret;
static unsigned long seen_cmd;
static unsigned int seen_inner, seen_size;
static unsigned long long seen_addr;
static char seen_path[64];
long probe_sys_openat(long d, const char *path, long f, long m) { strncpy(seen_path, path, sizeof(seen_path) - 1); return (open_ret); }
long probe_sys_ioctl(long fd, unsigned long cmd, void *arg) {
	unsigned int *u = arg;
	seen_cmd = cmd; seen_inner = u[0]; seen_size = u[1];
	memcpy(&seen_addr, u + 2, 8);
	return (ioctl_ret);
}
long probe_sys_write(long fd, const char *b, unsigned long l) { return ((long)fwrite(b, 1, l, stdout)); }
void probe_sys_exit(long s) { exit((int)s); }
int main(int argc, char **argv) {
	int rc;
	open_ret = atol(argv[1]); ioctl_ret = atol(argv[2]);
	rc = probe_main();
	printf("rc=%d path=%s cmd=0x%lx inner=0x%x size=%u addr=%llu\n", rc, seen_path, seen_cmd, seen_inner, seen_size, seen_addr);
	return (0);
}
EOT
if cc -std=gnu11 -Wall -Werror -DNVKMS_PROBE_HOST_TEST -o "$PH/h" "$PH/harness.c" "$KIT/nvkms_ioctl_probe.c" 2> "$PH/cc.err"; then
	probe_case() { "$PH/h" "$1" "$2" | tail -1; }
	_o=$(probe_case 3 0)
	case $_o in 'rc=0 path=/dev/nvidia-modeset cmd=0xc0106d00 inner=0xffffffff size=0 addr=0') pass "probe: the ioctl is 0xc0106d00 on /dev/nvidia-modeset with an inner command NVKMS cannot dispatch" ;; *) fail "probe call shape: $_o" ;; esac
	for _c in "3 0:reached-nvkms:0" "3 -1:reached-nvkms:0" "-2 0:open-failed:2" "3 -22:not-translated:3" "3 -25:not-translated:3" "3 -5:other-answer:4"; do
		_args=${_c%%:*}
		_rest=${_c#*:}
		_o=$("$PH/h" $_args)
		case $_o in
		*"verdict=${_rest%%:*}"*"rc=${_rest##*:} "*) pass "probe: [$_args] says verdict=${_rest%%:*} and exits ${_rest##*:}" ;;
		*) fail "probe: [$_args] want verdict=${_rest%%:*} rc=${_rest##*:}: $_o" ;;
		esac
	done
	case $(probe_case 3 -1) in rc=0*) pass "probe: EPERM from NVKMS means the ioctl reached nvidia-modeset (exit 0)" ;; *) fail "probe: EPERM was not a pass" ;; esac
	case $(probe_case -2 0) in rc=2*) pass "probe: a device that does not open exits 2" ;; *) fail "probe: an open failure was not exit 2" ;; esac
	case $(probe_case 3 -22) in rc=3*) pass "plant: EINVAL (no handler, or a size that did not translate) exits 3, not 0" ;; *) fail "probe: EINVAL was accepted" ;; esac
	case $(probe_case 3 -25) in rc=3*) pass "plant: ENOTTY exits 3, not 0" ;; *) fail "probe: ENOTTY was accepted" ;; esac
	case $(probe_case 3 -5) in rc=4*) pass "probe: any other answer exits 4" ;; *) fail "probe: EIO was not exit 4" ;; esac
	# plant: a probe that sends another command number turns the call-shape row red
	sed 's/0xc0106d00UL/0xc0106d01UL/' "$KIT/nvkms_ioctl_probe.c" > "$PH/probe_bad.c"
	cc -std=gnu11 -DNVKMS_PROBE_HOST_TEST -o "$PH/hb" "$PH/harness.c" "$PH/probe_bad.c" 2> /dev/null
	case $("$PH/hb" 3 0 | tail -1) in *cmd=0xc0106d00*) fail "plant: a probe on 0x6d01 passed the call-shape check" ;; *) pass "plant: a probe that sends another command is told apart" ;; esac
else
	fail "the NVKMS probe does not build for the host test: $(head -3 "$PH/cc.err")"
fi
# the real probe builds as a freestanding static Linux program for both architectures
for _a in aarch64 x86_64; do
	if cc --target="$_a-unknown-linux-gnu" -static -nostdlib -ffreestanding -fuse-ld=lld -O2 -o "$PH/probe-$_a" "$KIT/nvkms_ioctl_probe.c" 2> "$PH/ccl.err"; then
		pass "the NVKMS probe builds as a static Linux program for $_a"
	else
		fail "the NVKMS probe does not build for $_a: $(head -2 "$PH/ccl.err")"
	fi
done

# ---- make-be.sh for real, against a fake boot environment: stub bectl, a mount point that is a plain
# directory (LB_MNT), a real minimal kernel module copied under the five staged names, a kernel file with
# an osreldate, and the stamps build-shim.sh leaves. Nothing is mounted, loaded or armed.
SYSDIR=${SYSDIR:-/usr/src/sys}
FK=$TMPD/fk
mkdir -p "$FK"
cat > "$FK/fake.c" <<'EOT'
#include <sys/param.h>
#include <sys/module.h>
#include <sys/kernel.h>
static int fake_evh(module_t m, int w, void *a) { return (0); }
static moduledata_t fake_mod = { "fake", fake_evh, NULL };
DECLARE_MODULE(fake, fake_mod, SI_SUB_DRIVERS, SI_ORDER_ANY);
MODULE_VERSION(fake, 1);
EOT
printf 'KMOD=\tfake\nSRCS=\tfake.c\nSRCS+=\tbus_if.h device_if.h\nKMODDIR?=\t/boot/modules\n.include <bsd.kmod.mk>\n' > "$FK/Makefile"
if (cd "$FK" && env -u MAKEFLAGS make SYSDIR="$SYSDIR" LD=/usr/bin/ld OBJCOPY=/usr/bin/objcopy all > "$FK/make.out" 2>&1) && [ -s "$FK/fake.ko" ] && readelf -p .comment "$FK/fake.ko" 2> /dev/null | grep -q 'Linker: LLD'; then
	MB=$TMPD/mb
	mb_setup() {	# mb_setup <name> [osreldate of the BE kernel] [stamp version]: a fresh fake tree and BE under $MB/<name>
		_d=$MB/$1
		mkdir -p "$_d/tree/firmware/gsp_ga10x" "$_d/mnt/boot/kernel" "$_d/mnt/etc" "$_d/logs"
		for _m in nvidia/nvidia.ko nvidia-modeset/nvidia-modeset.ko nvidia-linux/nvidia_linux.ko nvidia-modeset-linux/nvidia_modeset_linux.ko firmware/gsp_ga10x/nvidia_gsp_ga10x_fw.ko; do
			mkdir -p "$_d/tree/$(dirname "$_m")"
			cp "$FK/fake.ko" "$_d/tree/$_m"
		done
		for _x in nvidia nvidia-modeset nvidia-linux nvidia-modeset-linux; do printf 'sysdir /usr/src/sys\nversion %s\n' "${3:-1600030}" > "$_d/tree/$_x/.gb10-sysdir"; done
		echo "const int osreldate = ${2:-1600030};" > "$_d/k.c"
		cc -c -o "$_d/mnt/boot/kernel/kernel" "$_d/k.c"
		printf 'kernel="kernel"\n' > "$_d/mnt/boot/loader.conf"
		printf '#!/bin/sh\necho "$@" >> "%s/bectl.log"\ncase "$1" in list) printf "base\\tN\\ncloudbsd-rx7600\\tR\\n" ;; esac\nexit 0\n' "$_d" > "$_d/bectl"
		chmod +x "$_d/bectl"
	}
	mb_run() {	# mb_run <name> [make-be args...]: run the kit's make-be.sh (or $MBKIT/make-be.sh) on the fake
		_n=$1
		shift
		env GB10_WORK="$MB/$_n" BECTL="$MB/$_n/bectl" LB_MNT="$MB/$_n/mnt" LB_NO_GIT_CHECK=1 \
		    sh "${MBKIT:-$KIT}/make-be.sh" -b base -t "$MB/$_n/tree" -V abc123 -i /bin/ls -p /etc/passwd -U nobody -C /bin/sh -u "$FK/fake.ko" "$@" > "$MB/$_n/out" 2>&1
	}
	mb_setup good
	mb_run good && pass "make-be.sh builds a fake BE" || fail "make-be.sh on a fake BE failed: $(tail -3 "$MB/good/out")"
	M=$MB/good/mnt
	grep -q '^module_path="/boot/modules.nvtest;/boot/kernel;' "$M/boot/loader.conf" && pass "make-be.sh put the staged directory first in the clone's module_path" || fail "no module_path in the clone: $(tail -3 "$M/boot/loader.conf")"
	[ -s "$M/boot/modules.nvtest/linker.hints" ] && pass "kldxref ran on the staged directory" || fail "no linker.hints in the staged directory"
	[ "$(sha256 -q "$M/usr/local/sbin/testboot-return")" = "$(sed -n 's/^sha256 *= *//p' "$KIT/VENDOR")" ] && pass "the vendored testboot-return is installed, equal to the pin" || fail "testboot-return is missing or differs from the pin"
	[ "$(cat "$M/usr/local/etc/linux_bridge_testboot.version")" = abc123+unverified ] && pass "a kit that was not checked against git is recorded as +unverified (so --kit abc123 will not match)" || fail "the unchecked kit is not marked: $(cat "$M/usr/local/etc/linux_bridge_testboot.version")"
	cmp -s "$M/usr/local/etc/linux_bridge_testboot.sha256" "$MB/good/logs/linux-bridge-testboot/nvidia-linux-bridge-test-$(date -u +%Y%m%d)-1.sha256" && pass "the staged hash list is in the BE and on the host" || fail "the hash list is missing or differs between the BE and the host"
	[ "$(awk '$2 == "nvidia.ko" { print $1 }' "$M/usr/local/etc/linux_bridge_testboot.sha256")" = "$(sha256 -q "$M/boot/modules.nvtest/nvidia.ko")" ] && pass "the hash list names the staged nvidia.ko hash" || fail "the hash list does not match the staged nvidia.ko"
	grep -q 'linux_bridge_testboot_normal_be="cloudbsd-rx7600"' "$M/etc/rc.conf.d/linux_bridge_testboot" && grep -q 'linux_bridge_testboot_copyout=' "$M/etc/rc.conf.d/linux_bridge_testboot" && pass "the BE names the normal BE and the copy-out directory" || fail "rc.conf.d/linux_bridge_testboot lacks the normal BE or the copy-out"
	grep -q '^kld_list="nvidia_gsp_ga10x_fw nvidia nvidia-modeset"$' "$M/etc/rc.conf.d/kld" && pass "kld_list in the BE loads by file name" || fail "kld_list: $(cat "$M/etc/rc.conf.d/kld")"
	if [ -x "$M/usr/local/libexec/nvkms_ioctl_probe" ]; then
		brandelf "$M/usr/local/libexec/nvkms_ioctl_probe" 2> /dev/null | grep -q "brand 'Linux'" && pass "the NVKMS probe is installed as a Linux-branded program" || fail "the NVKMS probe is not Linux-branded"
	else
		fail "the NVKMS probe was not built and installed: $(grep 'probe' "$MB/good/out" | head -2)"
	fi
	grep -q 'summarize.sh --kit abc123 --hashes' "$MB/good/out" && pass "make-be.sh prints the summarize.sh command with the kit and the hash list" || fail "no summarize.sh command at the end of make-be.sh"
	# an inherited module_path that does not name the staged directory is replaced; one a later file overrides is refused
	mb_setup mp
	printf 'kernel="kernel"\nmodule_path="/boot/kernel;/boot/modules"\n' > "$MB/mp/mnt/boot/loader.conf"
	mb_run mp && grep -q 'modules.nvtest;/boot/kernel' "$MB/mp/mnt/boot/loader.conf" && pass "a module_path without the staged directory is replaced in the clone" || fail "an inherited module_path was left as it was"
	mb_setup mp2
	printf 'module_path="/boot/kernel;/boot/modules"\n' > "$MB/mp2/mnt/boot/loader.conf.local"
	mb_run mp2 && fail "plant: a loader.conf.local that overrides module_path was accepted" || { grep -q 'overrides it' "$MB/mp2/out" && pass "plant: a later loader file that overrides module_path is refused" || fail "the override refusal has no reason: $(tail -2 "$MB/mp2/out")"; }
	# the BE kernel must be the one the modules were built against
	mb_setup kv 1599999
	mb_run kv && fail "plant: a BE kernel of another __FreeBSD_version was accepted" || { grep -q 'built against 1600030' "$MB/kv/out" && pass "plant: a BE kernel that does not match the build is refused" || fail "the kernel refusal has no reason: $(tail -2 "$MB/kv/out")"; }
	grep -q '^destroy' "$MB/kv/bectl.log" && pass "a refused BE is destroyed again" || fail "the refused BE was left behind"
	mb_setup sv 1600030 1600031
	mb_run sv && fail "plant: modules built against another version than the BE kernel were accepted" || pass "plant: build stamps that differ from the BE kernel are refused"
	mb_setup nonorm
	mb_run nonorm -N no-such-be && fail "plant: a normal BE that does not exist was accepted" || { grep -q 'does not exist here' "$MB/nonorm/out" && pass "plant: a -N normal BE that does not exist is refused before the clone is made" || fail "the -N refusal has no reason: $(tail -2 "$MB/nonorm/out")"; }
	! grep -q '^create' "$MB/nonorm/bectl.log" 2> /dev/null && pass "no BE was created for the refused -N" || fail "a BE was created although -N does not exist"
	mb_setup stl
	mkdir -p "$MB/stl/outside"
	ln -s "$MB/stl/outside" "$MB/stl/mnt/boot/modules.nvtest"
	mb_run stl && fail "plant: a staged directory that is a symlink was accepted" || { [ -z "$(ls "$MB/stl/outside")" ] && pass "plant: a symlinked staged directory is refused and nothing is written behind it" || fail "modules were written behind the staged-directory link"; }
	# a loader file that is a symbolic link out of the clone is refused, and nothing is written through it
	mb_setup lnk
	echo victim > "$MB/lnk/victim"
	ln -s "$MB/lnk/victim" "$MB/lnk/mnt/boot/loader.conf.local"
	mb_run lnk && fail "plant: a loader.conf.local symlink was accepted" || { grep -q 'is a symbolic link' "$MB/lnk/out" && [ "$(cat "$MB/lnk/victim")" = victim ] && pass "plant: a symlinked loader file is refused and its target untouched" || fail "symlink refusal: $(tail -2 "$MB/lnk/out")"; }
	mb_setup lnk2
	echo victim > "$MB/lnk2/victim"
	rm -f "$MB/lnk2/mnt/boot/loader.conf"
	ln -s "$MB/lnk2/victim" "$MB/lnk2/mnt/boot/loader.conf"
	mb_run lnk2 && fail "plant: a loader.conf symlink was accepted" || { [ "$(cat "$MB/lnk2/victim")" = victim ] && pass "plant: a symlinked loader.conf is refused and its target untouched" || fail "the loader.conf symlink target was written: $(cat "$MB/lnk2/victim")"; }
	# an assignment followed by a comment counts, so a later override with a comment is seen
	mb_setup cmt
	printf 'module_path="/boot/kernel;/boot/modules" # mine
' > "$MB/cmt/mnt/boot/loader.conf.local"
	mb_run cmt && fail "plant: a module_path override with a trailing comment was accepted" || { grep -q 'overrides it' "$MB/cmt/out" && pass "plant: an override with a trailing comment is seen and refused" || fail "the commented override was not seen: $(tail -2 "$MB/cmt/out")"; }
	# the staged directory is named once in make-be.sh
	[ "$(grep -v '^[[:space:]]*#' "$KIT/make-be.sh" | grep -v 'echo' | grep -c 'modules\.nvtest')" = 1 ] && pass "make-be.sh names the staged directory once (STAGED)" || fail "make-be.sh names the staged directory in several places"
	# -V must be the commit of the kit: a scratch repository, no test hook
	GR=$TMPD/gitrepo
	mkdir -p "$GR/tests" "$GR/rc.d"
	cp -R "$KIT" "$GR/tests/linux-bridge-testboot"
	cp "$HERE/../rc.d/nvidia_linux" "$GR/rc.d/"
	git -C "$GR" init -q 2> /dev/null && git -C "$GR" add -A && _t=$(git -C "$GR" write-tree) && _c=$(GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.org GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.org git -C "$GR" commit-tree "$_t" -m kit) && git -C "$GR" update-ref HEAD "$_c"
	mb_setup vh
	env GB10_WORK="$MB/vh" BECTL="$MB/vh/bectl" LB_MNT="$MB/vh/mnt" sh "$GR/tests/linux-bridge-testboot/make-be.sh" -b base -t "$MB/vh/tree" -V deadbeef -i /bin/ls -p /etc/passwd -U nobody -C /bin/sh -u "$FK/fake.ko" > "$MB/vh/out" 2>&1 && fail "plant: -V naming another commit was accepted" || { grep -q 'is not the commit of the kit' "$MB/vh/out" && pass "plant: -V that is not the commit of the kit is refused" || fail "the -V refusal has no reason: $(tail -2 "$MB/vh/out")"; }
	echo '# edit' >> "$GR/tests/linux-bridge-testboot/summarize.sh"
	HEADSHA=$(git -C "$GR" rev-parse HEAD)
	mb_setup vd
	env GB10_WORK="$MB/vd" BECTL="$MB/vd/bectl" LB_MNT="$MB/vd/mnt" sh "$GR/tests/linux-bridge-testboot/make-be.sh" -b base -t "$MB/vd/tree" -V "$HEADSHA" -i /bin/ls -p /etc/passwd -U nobody -C /bin/sh -u "$FK/fake.ko" > "$MB/vd/out" 2>&1 && fail "plant: a kit with uncommitted changes was accepted" || { grep -q 'uncommitted changes' "$MB/vd/out" && pass "plant: a kit with uncommitted changes is refused" || fail "the dirty-kit refusal has no reason: $(tail -2 "$MB/vd/out")"; }
	# the vendored testboot-return must equal its pin
	MBKIT=$TMPD/kit-copy
	mkdir -p "$MBKIT" "$TMPD/rc.d"
	cp "$KIT"/* "$MBKIT/"
	cp "$HERE/../rc.d/nvidia_linux" "$TMPD/rc.d/"
	mkdir -p "$TMPD/tests"
	rm -rf "$TMPD/tests/linux-bridge-testboot"
	mv "$MBKIT" "$TMPD/tests/linux-bridge-testboot"
	MBKIT=$TMPD/tests/linux-bridge-testboot
	echo '# tampered' >> "$MBKIT/testboot-return"
	mb_setup pin
	mb_run pin && fail "plant: a testboot-return that differs from the pin was accepted" || { grep -q 'VENDOR pins' "$MB/pin/out" && pass "plant: a testboot-return that differs from the VENDOR pin is refused" || fail "the pin refusal has no reason: $(tail -2 "$MB/pin/out")"; }
	MBKIT=
else
	fail "cannot build the fake kernel module for the make-be.sh tests: $(tail -3 "$FK/make.out")"
fi

[ "$fails" -eq 0 ] || { echo "linux_bridge_kit_test: $fails FAILED" >&2; exit 1; }
echo "linux_bridge_kit_test: all passed"

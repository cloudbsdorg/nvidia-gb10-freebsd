#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# prime_import_kit_test.sh - the hardware test kit for the cross-GPU buffer
# import (tests/prime-import-testboot/, Track #2228) is sound without the
# hardware:
#
#   (a) prime_import_probe.c compiles with -Wall -Wextra -Werror; --help
#       exits 0, a usage error exits 2, a missing device exits 3;
#   (b) every JSON row the probe prints (done, refused at import, failed at
#       create, the "none" row) validates against
#       prime-import-probe.schema.json, and a row with an unknown field or a
#       wrong type is refused by the same validator;
#   (c) prime_import_probe.8 is mandoc -T lint clean;
#   (d) make-be.sh: -b is required, the BE is named
#       nvidia-prime-import-test-<date>-<n>, a dry run prints the plan and
#       changes nothing, a run with a fake bectl installs the modules, the
#       rc script, the probe and the rc.conf.d file into the clone, verifies
#       the copies, and arms the boot (bectl activate -t) only with
#       --activate;
#   (e) no file of the kit can load or unload a module, suspend a device,
#       reboot or activate a boot environment other than make-be.sh's
#       one `bectl activate -t`;
#   (f) the rc one-shot is valid sh, records under logs/prime-import-*, and
#       its row() writes valid JSON lines for awkward details;
#   (g) controls: a kit file with a planted kldunload and a make-be.sh that
#       always arms the boot are each refused by the checks above.
#
# Run: sh tests/prime_import_kit_test.sh

set -u
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
KIT=$repo/tests/prime-import-testboot
WORK=${GB10_WORK:-$HOME/work/gb10}
mkdir -p "$WORK/tmp"
TMPD=$(mktemp -d "$WORK/tmp/prime-kit-test.XXXXXXXX") || exit 1
trap 'rm -rf -- "${TMPD:?}"' EXIT INT TERM
export TMPDIR=$TMPD

passed=0
failed=0
ok() { echo "PASS: $1"; passed=$((passed + 1)); }
bad() { echo "FAIL: $1"; failed=$((failed + 1)); }

DRMINC="-I/usr/local/include -I/usr/local/include/libdrm"
DRMLIB="-L/usr/local/lib -ldrm"

# (a)
if cc -Wall -Wextra -Werror -o "$TMPD/probe" "$KIT/prime_import_probe.c" $DRMINC $DRMLIB 2> "$TMPD/cc.err"; then
	ok "(a) the probe compiles with -Wall -Wextra -Werror"
else
	bad "(a) the probe does not compile: $(head -3 "$TMPD/cc.err" | tr '\n' ' ')"
fi
if [ -x "$TMPD/probe" ]; then
	"$TMPD/probe" --help > "$TMPD/help.out" 2>&1; rc=$?
	if [ "$rc" -eq 0 ] && grep -q '^usage:' "$TMPD/help.out"; then
		ok "(a) --help exits 0 and prints usage"
	else
		bad "(a) --help rc=$rc"
	fi
	"$TMPD/probe" > /dev/null 2>&1; rc=$?
	[ "$rc" -eq 2 ] && ok "(a) no arguments exits 2" || bad "(a) no arguments rc=$rc"
	"$TMPD/probe" -s 0x5 /dev/null /dev/null > /dev/null 2>&1; rc=$?
	[ "$rc" -eq 2 ] && ok "(a) a zero-sized buffer exits 2" || bad "(a) -s 0x5 rc=$rc"
	"$TMPD/probe" --json --jsonl /dev/null /dev/null > /dev/null 2>&1; rc=$?
	[ "$rc" -eq 2 ] && ok "(a) --json with --jsonl exits 2" || bad "(a) --json --jsonl rc=$rc"
	"$TMPD/probe" -s 1920X1080 /dev/null /dev/null > /dev/null 2> "$TMPD/s.err"; rc=$?
	if [ "$rc" -eq 2 ] && grep -q "1920X1080" "$TMPD/s.err"; then
		ok "(a) a bad -s operand exits 2 and is named in the message"
	else
		bad "(a) bad -s operand: rc=$rc $(cat "$TMPD/s.err")"
	fi
	"$TMPD/probe" /nonexistent/card0 /nonexistent/card1 > /dev/null 2>&1; rc=$?
	[ "$rc" -eq 3 ] && ok "(a) a missing device exits 3" || bad "(a) missing device rc=$rc"
fi

# (b) rows from the probe's own printer, no DRM device needed
cat > "$TMPD/rows.c" <<'CEOF'
#define main probe_main
#include "prime_import_probe.c"
#undef main
int
main(void)
{
	struct row r;

	memset(&r, 0, sizeof(r));
	r.src = "/dev/dri/card0"; r.dst = "/dev/dri/card1";
	r.w = 1920; r.h = 1080; r.bytes = 8294400;
	r.create = r.map = r.fill = r.export = r.import = r.addfb = 0;
	r.stage = "done";
	print_row(&r, 0);
	r.import = -1; r.addfb = -1; r.stage = "import"; r.err = EINVAL;
	print_row(&r, 0);
	r.create = -1; r.map = r.fill = r.export = -1; r.bytes = 0; r.stage = "create"; r.err = ENOMEM;
	print_row(&r, 0);
	r.create = 0; r.map = -1; r.stage = "map"; r.err = EINVAL;
	print_row(&r, 0);
	memset(&r, 0, sizeof(r));
	r.src = "a\"b"; r.dst = "c"; r.w = 1; r.h = 1; r.stage = "none";
	r.create = r.map = r.fill = r.export = r.import = r.addfb = -1;
	print_row(&r, 0);
	return 0;
}
CEOF
if cc -w -I"$KIT" -o "$TMPD/rows" "$TMPD/rows.c" $DRMINC $DRMLIB 2> "$TMPD/cc2.err"; then
	"$TMPD/rows" > "$TMPD/rows.jsonl"
	cat > "$TMPD/validate.py" <<'PYEOF'
import json, sys
schema = json.load(open(sys.argv[1]))
def check(obj):
    errs = []
    if not isinstance(obj, dict):
        return ["not an object"]
    for k in schema["required"]:
        if k not in obj:
            errs.append("missing " + k)
    for k, v in obj.items():
        spec = schema["properties"].get(k)
        if spec is None:
            errs.append("unknown field " + k)
            continue
        if "const" in spec and v != spec["const"]:
            errs.append(k + " != const")
        if "enum" in spec and v not in spec["enum"]:
            errs.append(k + " not in enum")
        t = spec.get("type")
        if t == "string" and not isinstance(v, str):
            errs.append(k + " not a string")
        if t == "integer":
            if not isinstance(v, int) or isinstance(v, bool):
                errs.append(k + " not an integer")
            elif "minimum" in spec and v < spec["minimum"]:
                errs.append(k + " below minimum")
    return errs
bad = 0
for n, line in enumerate(open(sys.argv[2]), 1):
    try:
        o = json.loads(line)
    except ValueError as e:
        print("line %d: not JSON: %s" % (n, e)); bad += 1; continue
    e = check(o)
    if e:
        print("line %d: %s" % (n, "; ".join(e))); bad += 1
sys.exit(1 if bad else 0)
PYEOF
	if python3 -I "$TMPD/validate.py" "$KIT/prime-import-probe.schema.json" "$TMPD/rows.jsonl" > "$TMPD/val.out" 2>&1; then
		ok "(b) every probe row validates against prime-import-probe.schema.json ($(wc -l < "$TMPD/rows.jsonl" | tr -d ' ') rows)"
	else
		bad "(b) a probe row does not validate: $(head -3 "$TMPD/val.out" | tr '\n' ' ')"
	fi
	sed 's/"stage":"done"/"stage":"done","extra":1/' "$TMPD/rows.jsonl" | head -1 > "$TMPD/rows-bad1.jsonl"
	sed 's/"width":1920/"width":"1920"/' "$TMPD/rows.jsonl" | head -1 > "$TMPD/rows-bad2.jsonl"
	sed 's/"stage":"done"/"stage":"finished"/' "$TMPD/rows.jsonl" | head -1 > "$TMPD/rows-bad3.jsonl"
	_all=1
	for b in 1 2 3; do
		if python3 -I "$TMPD/validate.py" "$KIT/prime-import-probe.schema.json" "$TMPD/rows-bad$b.jsonl" > /dev/null 2>&1; then
			_all=0
		fi
	done
	if [ "$_all" -eq 1 ]; then
		ok "(b) control: an extra field, a wrong type and a bad stage are each refused"
	else
		bad "(b) control: the validator accepted a bad row"
	fi
else
	bad "(b) the row harness does not compile: $(head -3 "$TMPD/cc2.err" | tr '\n' ' ')"
fi

# (c)
if mandoc -T lint "$KIT/prime_import_probe.8" > "$TMPD/lint.out" 2>&1; then
	ok "(c) prime_import_probe.8 is mandoc -T lint clean"
else
	bad "(c) mandoc -T lint: $(head -3 "$TMPD/lint.out" | tr '\n' ' ')"
fi

# (d) make-be.sh, with a fake bectl
cat > "$TMPD/fake-bectl" <<'FEOF'
#!/bin/sh
echo "bectl $*" >> "$FAKE_BECTL_LOG"
exit 0
FEOF
chmod +x "$TMPD/fake-bectl"
mkdir -p "$TMPD/mods/nvidia" "$TMPD/mods/nvidia-modeset" "$TMPD/mods/nvidia-drm"
printf 'a' > "$TMPD/mods/nvidia/nvidia.ko"
printf 'b' > "$TMPD/mods/nvidia-modeset/nvidia-modeset.ko"
printf 'c' > "$TMPD/mods/nvidia-drm/nvidia-drm.ko"
printf 'u' > "$TMPD/uvm.ko"

# run_be <script> <args...>: run a make-be.sh against the fake bectl
run_be() {
	_s=$1
	shift
	rm -rf "${TMPD:?}/mnt"
	: > "$TMPD/bectl.log"
	FAKE_BECTL_LOG="$TMPD/bectl.log" BECTL="$TMPD/fake-bectl" PRIME_MNT="$TMPD/mnt" GB10_WORK="$WORK" \
	    sh "$_s" "$@" 2>&1
}
sh "$KIT/make-be.sh" > "$TMPD/nob.out" 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok "(d) make-be.sh without -b exits 2" || bad "(d) make-be.sh without -b rc=$rc"
out=$(sh "$KIT/make-be.sh" -b base -D 20261120 -n 3 --dry-run 2>&1)
case $out in
*"bectl create -e base nvidia-prime-import-test-20261120-3"*) ok "(d) the BE is named nvidia-prime-import-test-<date>-<n>" ;;
*) bad "(d) dry-run plan lacks the create line: $out" ;;
esac
case $out in
*"bectl activate"*) bad "(d) a dry run without --activate arms a boot" ;;
*) ok "(d) no --activate: the plan does not arm a boot" ;;
esac
out=$(run_be "$KIT/make-be.sh" -b base -D 20261120 -n 7 -m "$TMPD/mods" -u "$TMPD/uvm.ko" --activate)
rc=$?
BEN=nvidia-prime-import-test-20261120-7
if [ "$rc" -eq 0 ] \
    && [ "$(cat "$TMPD/mnt/boot/modules.nvtest/nvidia.ko" 2>/dev/null)" = a ] \
    && [ "$(cat "$TMPD/mnt/boot/modules.nvtest/nvidia-drm.ko" 2>/dev/null)" = c ] \
    && [ "$(cat "$TMPD/mnt/boot/modules.nvtest/nvidia-uvm.ko" 2>/dev/null)" = u ] \
    && [ -x "$TMPD/mnt/usr/local/etc/rc.d/prime_import_testboot" ] \
    && [ -x "$TMPD/mnt/usr/local/bin/prime_import_probe" ] \
    && grep -q 'prime_import_testboot_enable="YES"' "$TMPD/mnt/etc/rc.conf.d/prime_import_testboot"; then
	ok "(d) a run with a fake bectl installs the modules, the rc script, the probe and the rc.conf.d file"
else
	bad "(d) the fake run: rc=$rc out=$(printf '%s' "$out" | tail -3 | tr '\n' ' ')"
fi
if grep -q "bectl activate -t $BEN" "$TMPD/bectl.log"; then
	ok "(d) --activate arms the boot with activate -t"
else
	bad "(d) --activate did not run bectl activate -t: $(tr '\n' ';' < "$TMPD/bectl.log")"
fi
if grep -q "bectl umount $BEN" "$TMPD/bectl.log"; then
	ok "(d) the clone is unmounted before it is armed"
else
	bad "(d) no umount"
fi
out=$(run_be "$KIT/make-be.sh" -b base -D 20261120 -n 8 -m "$TMPD/mods")
if grep -q 'activate' "$TMPD/bectl.log"; then
	bad "(d) a run without --activate armed a boot"
else
	ok "(d) a run without --activate leaves the BE unarmed"
fi
rm -f "$TMPD/mods/nvidia/nvidia.ko"
out=$(run_be "$KIT/make-be.sh" -b base -D 20261120 -n 9 -m "$TMPD/mods"); rc=$?
[ "$rc" -ne 0 ] && ok "(d) a missing module is refused (rc $rc)" || bad "(d) a missing module was accepted"
printf 'a' > "$TMPD/mods/nvidia/nvidia.ko"

sh "$KIT/make-be.sh" -b > "$TMPD/need.out" 2>&1; rc=$?
if [ "$rc" -eq 2 ] && grep -q "needs a value" "$TMPD/need.out"; then
	ok "(d) an option without its value exits 2 with a message"
else
	bad "(d) make-be.sh -b rc=$rc $(head -2 "$TMPD/need.out")"
fi
run_be "$KIT/make-be.sh" -b base -D 20261120 -n 11 -m "$TMPD/mods" --activate > "$TMPD/act.out"
want=$(sed -n 's/^LOGROOT=//p' "$KIT/prime_import_testboot")
if grep -q "results land in $want/prime-import-" "$TMPD/act.out"; then
	ok "(d) the armed message names the rc script's real log directory"
else
	bad "(d) the armed message names another directory: $(tail -1 "$TMPD/act.out")"
fi

# (e) forbidden commands anywhere in the kit
common='kldunload|kldload|devctl|acpiconf|zzz|[^a-z_]reboot|shutdown|halt -|bectl[[:space:]]+destroy'
scan() {	# scan <file>: forbidden commands, comments excluded
	grep -nE "$common|bectl[[:space:]]+activate" "$1" | grep -v '^[0-9]*:[[:space:]]*#' | grep -vE '^[0-9]+:[[:space:]]+shutdown -r "\+\$prime_import_testboot_deadman" "prime_import_testboot dead-man: [^"]*" > /dev/null 2>&1 &$' | grep -vE '^[0-9]+:[[:space:]]+if pkill -f "prime_import_testboot dead-man" > /dev/null 2>&1; then$'
}
_hits=
for f in prime_import_testboot make-be.sh prime_import_probe.c; do
	case $f in
	make-be.sh) h=$(grep -nE "$common" "$KIT/$f" | grep -v '^[0-9]*:[[:space:]]*#') ;;
	*) h=$(scan "$KIT/$f") ;;
	esac
	[ -z "$h" ] || _hits="$_hits $f:$h"
done
if [ -z "$_hits" ]; then
	ok "(e) no kit file loads or unloads a module, suspends, reboots or arms a boot (make-be.sh arms only with --activate)"
else
	bad "(e) forbidden command in the kit:$_hits"
fi
if grep -B3 'activate -t' "$KIT/make-be.sh" | grep -q 'ACTIVATE'; then
	ok "(e) make-be.sh's activate is guarded by --activate"
else
	bad "(e) make-be.sh's activate is not guarded"
fi

# (f) the rc script
if sh -n "$KIT/prime_import_testboot" 2> "$TMPD/rcsyn.err"; then
	ok "(f) the rc one-shot is valid sh"
else
	bad "(f) rc syntax: $(cat "$TMPD/rcsyn.err")"
fi
if grep -Eq '^: "\$\{prime_import_testboot_logroot:=/home/mlapointe/work/gb10/logs\}"$' "$KIT/prime_import_testboot" \
    && grep -Eq '^LOGROOT=\$prime_import_testboot_logroot$' "$KIT/prime_import_testboot" \
    && grep -Eq '^OUT=\$LOGROOT/prime-import-\$STAMP$' "$KIT/prime_import_testboot"; then
	ok "(f) results land under ~/work/gb10/logs/prime-import-<stamp>"
else
	bad "(f) the rc script records elsewhere"
fi
if grep -Eq '(^|[[:space:]"=:])/tmp' "$KIT/prime_import_testboot" "$KIT/make-be.sh"; then
	bad "(f) a kit script uses /tmp"
else
	ok "(f) no kit script uses /tmp"
fi
OUT=$TMPD/rcout; mkdir -p "$OUT"; export OUT
sed -n '/^row()/,/^}/p' "$KIT/prime_import_testboot" > "$TMPD/row.sh"
( . "$TMPD/row.sh"; row t1 pass 'plain'; row t2 fail 'quote " and backslash \ and
newline'; row t3 skip "$(printf 'tab\there')" ) > /dev/null
if python3 -I -c '
import json, sys
n = 0
for line in open(sys.argv[1]):
    o = json.loads(line)
    assert set(o) == {"row", "result", "detail"}
    n += 1
sys.exit(0 if n == 3 else 1)' "$OUT/results.jsonl" 2> "$TMPD/row.err"; then
	ok "(f) row() writes valid JSON lines, quotes, backslashes and newlines included"
else
	bad "(f) row() output is not valid JSON: $(tail -2 "$TMPD/row.err") $(cat "$OUT/results.jsonl")"
fi

if grep -q 'mkdir -p "\$OUT"' "$KIT/prime_import_testboot"; then
	bad "(f) the root rc script creates its output directory with mkdir -p (a planted directory would be reused)"
else
	ok "(f) the rc script creates its output directory itself and fails if it exists"
fi

# (f2) the rc script's decisions, run for real against fakes: a fake probe, sysctl,
# kldstat, dmesg, bectl, su and pgrep first in PATH.  The paths are rc.conf
# variables, so nothing outside TMPD is touched.
FAKE=$TMPD/fake; mkdir -p "$FAKE/bin"
for t in kldstat dmesg bectl pgrep pkill shutdown; do
	printf '#!/bin/sh\ncase "$0" in *kldstat) echo "nvidia-drm.ko amdgpu.ko";; *pgrep) exit 1;; *shutdown|*pkill) echo "$0 $*" >> "%s/dead-man.log";; esac\nexit 0\n' "$FAKE" > "$FAKE/bin/$t"
done
printf '#!/bin/sh\n[ "$1" = -n ] && case "$2" in kern.bootfile) echo /boot/kernel/kernel;; vm.stats.vm.v_wire_count) cat "%s/wired";; hw.nvidia_unlock_dirty_refused) cat "%s/refused" 2>/dev/null;; esac\nexit 0\n' "$FAKE" "$FAKE" > "$FAKE/bin/sysctl"
printf '#!/bin/sh\nexit 0\n' > "$FAKE/bin/su"
chmod +x "$FAKE"/bin/*
echo 1000 > "$FAKE/wired"
echo 0 > "$FAKE/refused"
# rc_run <name> <rc script> <probe>: run the one-shot, print its run directory
rc_run() {
	_n=$1; _rc=$2; _pr=$3
	rm -rf "$FAKE/logs-$_n"; mkdir -p "$FAKE/logs-$_n"
	env PATH="$FAKE/bin:$PATH" prime_import_testboot_logroot="$FAKE/logs-$_n" \
	    prime_import_testboot_probe="$_pr" prime_import_testboot_log="$FAKE/rc-$_n.log" \
	    prime_import_testboot_src=/dev/null prime_import_testboot_dst=/dev/null \
	    prime_import_testboot_loops=4 prime_import_testboot_probe_timeout=${RC_PROBE_TIMEOUT:-60} prime_import_testboot_loop_timeout=${RC_LOOP_TIMEOUT:-20} prime_import_testboot_deadman=${RC_DEADMAN:-45} prime_import_testboot_linuxroot="$FAKE/none" \
	    prime_import_testboot_cudarun="$FAKE/none" timeout 90 sh "$_rc" onestart > "$FAKE/rc-$_n.out" 2>&1
	ls -d "$FAKE/logs-$_n"/prime-import-* 2>/dev/null | head -1
}
rowres() {	# rowres <results.jsonl> <row>: the results of the row, in order
	grep "\"row\":\"$2\"" "$1" | sed 's/.*"result":"\([a-z]*\)".*/\1/' | tr '\n' ' '
}
# a probe that records whether the "running" row was already on disk when it ran
cat > "$FAKE/probe-good" <<PROBEEOF
#!/bin/sh
grep -q '"row":"import","result":"running"' "$FAKE/logs-good"/prime-import-*/results.jsonl && echo seen > "$FAKE/running-seen"
echo '{"import":0,"addfb":0}'
exit 0
PROBEEOF
printf '#!/bin/sh\nexit 1\n' > "$FAKE/probe-bad"
chmod +x "$FAKE/probe-good" "$FAKE/probe-bad"

d=$(rc_run good "$KIT/prime_import_testboot" "$FAKE/probe-good")
if [ -n "$d" ] && [ -f "$d/results.jsonl" ]; then
	r=$(rowres "$d/results.jsonl" import)
	[ "$r" = "running pass " ] && ok "(f2) a good probe: import goes running, then pass" || bad "(f2) good probe: import rows are '$r'"
	[ -f "$FAKE/running-seen" ] && ok "(f2) the running row is on disk before the probe starts (a panic leaves evidence)" || bad "(f2) the running row was not written before the probe"
	[ "$(rowres "$d/results.jsonl" done)" = "info " ] && ok "(f2) a finished run ends with a done row" || bad "(f2) no done row"
	[ "$(rowres "$d/results.jsonl" dirty-refused)" = "pass " ] && ok "(f2) the tripwire counter reads 0: dirty-refused passes" || bad "(f2) dirty-refused rows: $(rowres "$d/results.jsonl" dirty-refused)"
	sh "$KIT/summarize.sh" "$d" > "$TMPD/sum-good.txt" 2>&1; rc=$?
	[ "$rc" -eq 0 ] && ok "(f2) summarize.sh: a complete run passes" || bad "(f2) summarize.sh rc=$rc: $(grep -v "^pass\|^info\|^skip" "$TMPD/sum-good.txt" | tr "\n" " ")"
else
	bad "(f2) the rc script did not record a run: $(head -5 "$FAKE/rc-good.out" | tr '\n' ' ')"
fi
echo 2 > "$FAKE/refused"
d=$(rc_run trip "$KIT/prime_import_testboot" "$FAKE/probe-good")
if [ -n "$d" ] && [ -f "$d/results.jsonl" ]; then
	[ "$(rowres "$d/results.jsonl" dirty-refused)" = "fail " ] && ok "(f2) a nonzero tripwire counter is a fail row" || bad "(f2) dirty-refused with the counter at 2: '$(rowres "$d/results.jsonl" dirty-refused)'"
	sh "$KIT/summarize.sh" "$d" > /dev/null 2>&1; [ $? -eq 1 ] && ok "(f2) summarize.sh: a tripped counter fails the run" || bad "(f2) summarize.sh ignores the tripped counter"
else
	bad "(f2) no results for the tripwire run"
fi
rm -f "$FAKE/refused"
d=$(rc_run blind "$KIT/prime_import_testboot" "$FAKE/probe-good")
[ "$(rowres "$d/results.jsonl" dirty-refused)" = "fail " ] && ok "(f2) an unreadable tripwire after a passed import is a fail row, not a pass" || bad "(f2) unreadable tripwire rows: '$(rowres "$d/results.jsonl" dirty-refused)'"
echo 0 > "$FAKE/refused"
d=$(rc_run nop "$KIT/prime_import_testboot" "$FAKE/no-such-probe")
if [ -n "$d" ] && [ -f "$d/results.jsonl" ]; then
	sh "$KIT/summarize.sh" "$d" > /dev/null 2>&1; [ $? -eq 3 ] && ok "(f2) summarize.sh: a run that skipped the import is incomplete (exit 3), not a pass" || bad "(f2) summarize.sh passes a run that tested nothing"
	r=$(rowres "$d/results.jsonl" import)
	case $r in
	*skip*) ok "(f2) no probe is recorded as skip" ;;
	*) bad "(f2) no probe is recorded as '$r', not skip" ;;
	esac
	case $r in *pass*) bad "(f2) no probe is recorded as a pass" ;; *) ok "(f2) no probe is never a pass" ;; esac
	[ -z "$(rowres "$d/results.jsonl" wire-count-stable | tr -d ' ')" ] && ok "(f2) no wire-count row is made up without a probe" || bad "(f2) a wire-count row exists without a probe"
else
	bad "(f2) no results for the no-probe run: $(head -5 "$FAKE/rc-nop.out" | tr '\n' ' ')"
fi
d=$(rc_run bad "$KIT/prime_import_testboot" "$FAKE/probe-bad")
if [ -n "$d" ] && [ -f "$d/results.jsonl" ]; then
	r=$(rowres "$d/results.jsonl" import)
	[ "$r" = "running fail " ] && ok "(f2) a failing probe is recorded as fail" || bad "(f2) failing probe: import rows '$r'"
	sh "$KIT/summarize.sh" "$d" > /dev/null 2>&1; rc=$?
	[ "$rc" -eq 1 ] && ok "(f2) summarize.sh: a run with a fail is a failure" || bad "(f2) summarize.sh on a failed run: rc=$rc"
else
	bad "(f2) no results for the failing-probe run"
fi
# a run that died (panic): the last row is a running row and there is no done row
printf '%s\n' '{"row":"stack","result":"pass","detail":"x"}' '{"row":"import","result":"running","detail":"x"}' > "$TMPD/died.jsonl"
sh "$KIT/summarize.sh" "$TMPD/died.jsonl" > "$TMPD/sum-died.txt" 2>&1; rc=$?
if [ "$rc" -eq 1 ] && grep -q 'stopped in step "import"' "$TMPD/sum-died.txt" && grep -q 'no final "done" row' "$TMPD/sum-died.txt"; then
	ok "(f2) summarize.sh: a run that died in the import step fails and names the step"
else
	bad "(f2) summarize.sh on a died run: rc=$rc $(cat "$TMPD/sum-died.txt")"
fi
: > "$TMPD/empty.jsonl"
sh "$KIT/summarize.sh" "$TMPD/empty.jsonl" > /dev/null 2>&1; [ $? -eq 1 ] && ok "(f2) summarize.sh: an empty run fails" || bad "(f2) summarize.sh accepts an empty run"
sh "$KIT/summarize.sh" > /dev/null 2>&1; [ $? -eq 2 ] && ok "(f2) summarize.sh: no argument is a usage error" || bad "(f2) summarize.sh usage"
sh "$KIT/summarize.sh" /nonexistent > /dev/null 2>&1; [ $? -eq 2 ] && ok "(f2) summarize.sh: an unreadable file is a usage error" || bad "(f2) summarize.sh unreadable"

# the dead-man reboot: armed before the first probe, cancelled at the done row, off at 0
d=$(rc_run good "$KIT/prime_import_testboot" "$FAKE/probe-good")
if grep -q 'shutdown -r +45' "$FAKE/dead-man.log" 2>/dev/null; then
	ok "(f2) the dead-man timer is armed for 45 minutes"
else
	bad "(f2) no dead-man reboot was armed: $(cat "$FAKE/dead-man.log" 2>/dev/null)"
fi
grep -q 'pkill -f prime_import_testboot dead-man' "$FAKE/dead-man.log" 2>/dev/null && ok "(f2) only this script's dead-man timer is cancelled (by its own message), at the end of a finished run" || bad "(f2) the dead-man reboot is not cancelled"
case $(rowres "$d/results.jsonl" deadman) in "info info ") ok "(f2) the arm and the cancel are both recorded" ;; *) bad "(f2) deadman rows: '$(rowres "$d/results.jsonl" deadman)'" ;; esac
[ "$(grep -c 'dead-man' "$KIT/prime_import_testboot")" -ge 2 ] && [ "$(grep -c '^[[:space:]]*shutdown ' "$KIT/prime_import_testboot")" -eq 1 ] && ok "(f2) the rc script has exactly one shutdown, the dead-man" || bad "(f2) the rc script has another shutdown"
rm -f "$FAKE/dead-man.log"
d=$(RC_DEADMAN=0 rc_run nodead "$KIT/prime_import_testboot" "$FAKE/probe-good")
[ ! -s "$FAKE/dead-man.log" ] && ok "(f2) with the dead-man set to 0 nothing is armed" || bad "(f2) a dead-man was armed with the variable at 0"
# the dead-man outlasts the bounded worst case of the run (the defaults, from the script itself)
_dm=$(sed -n 's/^: "${prime_import_testboot_deadman:=\([0-9]*\)}".*/\1/p' "$KIT/prime_import_testboot")
_pt=$(sed -n 's/^: "${prime_import_testboot_probe_timeout:=\([0-9]*\)}".*/\1/p' "$KIT/prime_import_testboot")
_lt=$(sed -n 's/^: "${prime_import_testboot_loop_timeout:=\([0-9]*\)}".*/\1/p' "$KIT/prime_import_testboot")
_lp=$(sed -n 's/^: "${prime_import_testboot_loops:=\([0-9]*\)}".*/\1/p' "$KIT/prime_import_testboot")
_worst=$((_pt + _lp * _lt + _pt + 300 + 120))
if [ -n "$_dm" ] && [ $((_dm * 60)) -gt "$_worst" ]; then
	ok "(f2) the dead-man timer ($_dm minutes) outlasts the bounded worst case of the run ($((_worst / 60)) minutes, without the Wayfire command)"
else
	bad "(f2) the dead-man timer ('$_dm' minutes) does not outlast the worst case ($_worst s)"
fi
d=$(RC_DEADMAN=abc rc_run baddead "$KIT/prime_import_testboot" "$FAKE/probe-good")
[ "$(rowres "$d/results.jsonl" deadman)" = "fail " ] && ok "(f2) a malformed dead-man value is a fail row, not a silent disable" || bad "(f2) malformed dead-man rows: '$(rowres "$d/results.jsonl" deadman)'"
rm -f "$FAKE/dead-man.log"
d=$(RC_DEADMAN=00 rc_run zerodead2 "$KIT/prime_import_testboot" "$FAKE/probe-good")
[ ! -s "$FAKE/dead-man.log" ] && ok "(f2) a dead-man value of 00 disables the timer like 0, it does not restart the machine at once" || bad "(f2) a dead-man value of 00 armed a timer: $(cat "$FAKE/dead-man.log")"
# the reverse probe (the sixth call of a run with 4 loops) that hangs is stopped and says so
rm -f "$FAKE/count"
printf '#!/bin/sh\nn=$(cat "%s/count" 2>/dev/null || echo 0)\nn=$((n + 1))\necho $n > "%s/count"\necho "{\\"import\\":0,\\"addfb\\":0}"\n[ $n -ge 6 ] && sleep 6\nexit 0\n' "$FAKE" "$FAKE" > "$FAKE/probe-revhang"
chmod +x "$FAKE/probe-revhang"
d=$(RC_PROBE_TIMEOUT=2 rc_run revhang "$KIT/prime_import_testboot" "$FAKE/probe-revhang")
if grep '"row":"reverse"' "$d/results.jsonl" | grep -q 'timed out after 2 seconds'; then
	ok "(f2) a reverse probe that hangs is stopped and the row says it timed out"
else
	bad "(f2) reverse hang: $(grep '"row":"reverse"' "$d/results.jsonl" | tail -1 | cut -c1-160)"
fi
rm -f "$FAKE/count"
_f="$TMPD/ctl-rc-norevtimeout"
sed 's/timeout -k 5 "$prime_import_testboot_probe_timeout" "$PROBE" --jsonl -s 256x256/"$PROBE" --jsonl -s 256x256/' "$KIT/prime_import_testboot" > "$_f"
if cmp -s "$KIT/prime_import_testboot" "$_f"; then
	bad "(f2) control no-reverse-timeout: the mutation changed nothing (stale test)"
else
	_d=$(RC_PROBE_TIMEOUT=2 rc_run mrevhang "$_f" "$FAKE/probe-revhang")
	grep '"row":"reverse"' "$_d/results.jsonl" | grep -q 'timed out' && bad "(f2) control no-reverse-timeout: the mutant still reports a timeout" || ok "(f2) control: a reverse probe without its timeout is seen"
fi
rm -f "$FAKE/count"
# a loop probe that hangs is not a good one, whatever the previous iteration printed
printf '#!/bin/sh\necho "{\\"import\\":0,\\"addfb\\":0}"\n[ $# -eq 5 ] && sleep 6\nexit 0\n' > "$FAKE/probe-loophang"
chmod +x "$FAKE/probe-loophang"
d=$(RC_PROBE_TIMEOUT=30 RC_LOOP_TIMEOUT=2 rc_run loophang "$KIT/prime_import_testboot" "$FAKE/probe-loophang")
if [ "$(rowres "$d/results.jsonl" wire-count-stable)" = "running fail " ] && grep -q 'only 0 of 4 loop probes' "$d/results.jsonl"; then
	ok "(f2) loop probes that hang are not counted as good"
else
	bad "(f2) loop hang: wire-count-stable rows '$(rowres "$d/results.jsonl" wire-count-stable)'"
fi
# a hanging probe is stopped by its timeout and recorded as a fail
printf '#!/bin/sh\nsleep 6\necho "{\\"import\\":0,\\"addfb\\":0}"\nexit 0\n' > "$FAKE/probe-hang"
chmod +x "$FAKE/probe-hang"
d=$(RC_PROBE_TIMEOUT=2 RC_LOOP_TIMEOUT=2 rc_run hang "$KIT/prime_import_testboot" "$FAKE/probe-hang")
if [ -n "$d" ] && [ "$(rowres "$d/results.jsonl" import)" = "running fail " ] && grep -q 'did not finish in 2 seconds' "$d/results.jsonl"; then
	ok "(f2) a probe that hangs is stopped by its timeout and recorded as a fail that says so"
else
	bad "(f2) hanging probe: import rows '$(rowres "$d/results.jsonl" import)'"
fi
# (f2) controls: each planted rc defect must be seen by the runs above
mut_rc() {	# mut_rc <name> <sed> <probe> <import rows that must NOT appear (case pattern)>
	_f="$TMPD/ctl-rc-$1"
	sed -e "$2" "$KIT/prime_import_testboot" > "$_f"
	if cmp -s "$KIT/prime_import_testboot" "$_f"; then bad "(f2) control $1: the mutation changed nothing (stale test)"; return; fi
	_d=$(rc_run "m$1" "$_f" "$3")
	_r=$(rowres "$_d/results.jsonl" import)
	case $_r in
	$4) ok "(f2) control: mutant $1 is seen (import rows '$_r')" ;;
	*) bad "(f2) control $1: the mutant records '$_r', as the good rc would" ;;
	esac
}
mut_rc no-probe-pass 's/row import skip "no prime_import_probe/row import pass "no prime_import_probe/' "$FAKE/no-such-probe" '*pass*'
mut_rc probe-fail-pass 's/row import fail "prime_import_probe exited/row import pass "prime_import_probe exited/' "$FAKE/probe-bad" '*pass*'
mut_hang() {	# mut_hang <name> <sed>: the hanging probe must still be stopped
	_f="$TMPD/ctl-rc-$1"
	sed -e "$2" "$KIT/prime_import_testboot" > "$_f"
	if cmp -s "$KIT/prime_import_testboot" "$_f"; then bad "(f2) control $1: the mutation changed nothing (stale test)"; return; fi
	_d=$(RC_PROBE_TIMEOUT=2 RC_LOOP_TIMEOUT=2 rc_run "m$1" "$_f" "$FAKE/probe-hang")
	case $(rowres "$_d/results.jsonl" import) in
	*fail*) bad "(f2) control $1: the mutant still stops the hanging probe" ;;
	*) ok "(f2) control: mutant $1 is seen (the hanging probe is not stopped)" ;;
	esac
}
mut_hang no-import-timeout 's/timeout -k 5 "$prime_import_testboot_probe_timeout" "$PROBE" --jsonl -s 64x64/"$PROBE" --jsonl -s 64x64/'
rm -f "$FAKE/dead-man.log"
sed 's/^	deadman_arm$/	:/' "$KIT/prime_import_testboot" > "$TMPD/ctl-rc-nodead"
if cmp -s "$KIT/prime_import_testboot" "$TMPD/ctl-rc-nodead"; then
	bad "(f2) control no-deadman-arm: the mutation changed nothing (stale test)"
else
	rc_run mnodead "$TMPD/ctl-rc-nodead" "$FAKE/probe-good" > /dev/null
	grep -q 'shutdown -r' "$FAKE/dead-man.log" 2>/dev/null && bad "(f2) control no-deadman-arm: the mutant still arms it" || ok "(f2) control: a rc without the dead-man arm is seen"
fi
_f="$TMPD/ctl-rc-oldloop"
sed 's/if \[ \$? -eq 0 \] \&\& tail -1 "\$OUT\/probe-loop-one.jsonl"/if tail -1 "$OUT\/probe-loop-one.jsonl"/' "$KIT/prime_import_testboot" > "$_f"
if cmp -s "$KIT/prime_import_testboot" "$_f"; then
	bad "(f2) control loop-ignores-exit: the mutation changed nothing (stale test)"
else
	_d=$(RC_PROBE_TIMEOUT=30 RC_LOOP_TIMEOUT=2 rc_run moldloop "$_f" "$FAKE/probe-loophang")
	[ "$(rowres "$_d/results.jsonl" wire-count-stable)" = "running pass " ] && ok "(f2) control: a loop that counts a timed-out probe as good is seen" || bad "(f2) control loop-ignores-exit: not seen ('$(rowres "$_d/results.jsonl" wire-count-stable)')"
fi
mut_rc no-running-row 's/^	running import .*$/	:/' "$FAKE/probe-good" 'pass '

# (g) controls
mkdir -p "$TMPD/ctl"
cp "$KIT"/* "$TMPD/ctl/"
printf 'kldunload nvidia\n' >> "$TMPD/ctl/prime_import_testboot"
h=$(scan "$TMPD/ctl/prime_import_testboot")
[ -n "$h" ] && ok "(g) control: a planted kldunload is flagged" || bad "(g) control: a planted kldunload passed"
sed 's/^if \[ "\$ACTIVATE" -eq 1 \]; then/if true; then/' "$KIT/make-be.sh" > "$TMPD/ctl/make-be.sh"
if cmp -s "$KIT/make-be.sh" "$TMPD/ctl/make-be.sh"; then
	bad "(g) control: the always-arm mutation changed nothing (stale test)"
else
	run_be "$TMPD/ctl/make-be.sh" -b base -D 20261120 -n 10 -m "$TMPD/mods" > /dev/null
	if grep -q 'activate' "$TMPD/bectl.log"; then
		ok "(g) control: a make-be.sh that always arms the boot is seen by the unarmed check"
	else
		bad "(g) control: the always-arm mutant did not arm"
	fi
fi

echo "passed: $passed failed: $failed"
[ "$failed" -eq 0 ]

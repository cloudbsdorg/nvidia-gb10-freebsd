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
	grep -nE "$common|bectl[[:space:]]+activate" "$1" | grep -v '^[0-9]*:[[:space:]]*#'
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
if grep -Eq '^LOGROOT=/home/mlapointe/work/gb10/logs$' "$KIT/prime_import_testboot" \
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

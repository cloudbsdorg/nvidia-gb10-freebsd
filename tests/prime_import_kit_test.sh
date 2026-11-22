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
# the one shared bare-shutdown detector (also used by check-be.sh in kits that have one)
. "$KIT/bare-shutdown-check.sh"
WORK=${GB10_WORK:-$HOME/work/gb10}
mkdir -p "$WORK/tmp"
TMPD=$(mktemp -d "$WORK/tmp/prime-kit-test.XXXXXXXX") || exit 1
TEST_PIDS=$TMPD/test-pids
: > "$TEST_PIDS"
cleanup() {
	if [ -f "$TEST_PIDS" ]; then
		while IFS= read -r _pid; do
			case $_pid in
			''|*[!0-9]*) ;;
			*)	# only a pid that is still one of our own shutdown copies
				[ "$(ps -o uid= -o comm= -p "$_pid" 2> /dev/null | tr -d ' ')" = "$(id -u)shutdown" ] && kill "$_pid" 2> /dev/null
				: ;;
			esac
		done < "$TEST_PIDS"
	fi
	rm -rf -- "${TMPD:?}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
export TMPDIR=$TMPD TEST_PIDS

passed=0
failed=0
ok() { echo "PASS: $1"; passed=$((passed + 1)); }
bad() { echo "FAIL: $1"; failed=$((failed + 1)); }

# (guard G1) sentinels precede every kit run.  The PATH sentinel can only log
# and exit; the override stub starts a copied sleep named shutdown so the rc's
# exact-pid confirmation exercises the real ps check without shutdown(8).
SENT=$TMPD/sent
SENT2=$TMPD/sent2
TEST_CHILD=$TMPD/child
mkdir -p "$SENT" "$SENT2" "$TEST_CHILD"
cat > "$SENT/shutdown" <<'EOF'
#!/bin/sh
printf 'REACHED %s %s\n' "$0" "$*" >> "$SENT/hits"
exit 99
EOF
cat > "$SENT2/real-shutdown" <<'EOF'
#!/bin/sh
printf 'REAL REACHED %s %s\n' "$0" "$*" >> "$SENT2/hits"
exit 99
EOF
cp /bin/sleep "$TEST_CHILD/shutdown"
cat > "$TMPD/prime-shutdown-stub" <<'EOF'
#!/bin/sh
printf 'shutdown %s\n' "$*" >> "$PRIME_STUB_LOG"
if [ -n "${PRIME_STUB_REFUSE:-}" ] && [ -e "$PRIME_STUB_REFUSE" ]; then
	echo 'shutdown: cannot' >&2
	exit 1
fi
"$TEST_CHILD/shutdown" 300 > /dev/null 2>&1 < /dev/null &
_child=$!
printf '%s\n' "$_child" >> "$TEST_PIDS"
# the pid is announced only once ps says it is a shutdown (bounded, no timer)
_i=0
while [ "$(ps -o comm= -p "$_child" 2> /dev/null | tr -d ' ')" != shutdown ]; do
	_i=$((_i + 1))
	if [ "$_i" -gt 2000 ]; then
		echo 'stub: the child never became a shutdown' >&2
		exit 1
	fi
done
printf 'shutdown: [pid %s]\n' "$_child"
exit 0
EOF
chmod 755 "$SENT/shutdown" "$SENT2/real-shutdown" "$TEST_CHILD/shutdown" "$TMPD/prime-shutdown-stub"
PATH=$SENT:$PATH
prime_import_testboot_shutdown=$TMPD/prime-shutdown-stub
export PATH SENT SENT2 TEST_CHILD prime_import_testboot_shutdown
if [ -n "$prime_import_testboot_shutdown" ] && [ "$prime_import_testboot_shutdown" != /sbin/shutdown ] &&
    [ -x "$prime_import_testboot_shutdown" ] && [ ! -u "$prime_import_testboot_shutdown" ] &&
    [ "${PATH%%:*}" = "$SENT" ]; then
	ok "(guard G1) PATH and absolute non-setuid shutdown stub sentinels are armed before kit code runs"
else
	echo "guard: the harness left prime_import_testboot_shutdown at /sbin/shutdown" >&2
	exit 1
fi

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
# bectl mount <be> <dir>: the base BE's files, when the test provides some
if [ "$1" = mount ] && [ -n "${FAKE_BASE_DIR:-}" ]; then cp -R "$FAKE_BASE_DIR/." "$3/"; fi
# a signal arrives while the clone is mounting (the fake mount signals its parent, the make-be.sh shell)
if [ "$1" = mount ] && [ -n "${FAKE_MOUNT_SIGNAL:-}" ]; then kill -"$FAKE_MOUNT_SIGNAL" "$PPID"; fi
# a failure to order, after the clone exists
case " ${FAKE_BECTL_FAIL:-none} " in *" $1 "*) exit 1 ;; esac
exit 0
FEOF
chmod +x "$TMPD/fake-bectl"
mkdir -p "$TMPD/mods/nvidia" "$TMPD/mods/nvidia-modeset" "$TMPD/mods/nvidia-drm"
printf 'a' > "$TMPD/mods/nvidia/nvidia.ko"
printf 'b' > "$TMPD/mods/nvidia-modeset/nvidia-modeset.ko"
printf 'c' > "$TMPD/mods/nvidia-drm/nvidia-drm.ko"
printf 'u' > "$TMPD/uvm.ko"

# the module order tool of the fake runs: a good order unless a test says otherwise
printf 'import sys\nprint("ok")\n' > "$TMPD/ko-tool-good"
# A shell that is started from a background job inherits SIGINT ignored, and a signal ignored on entry cannot be trapped:
# make-be.sh is started through a launcher that puts the default action back (also SIGPIPE, which Python ignores), as it has in a terminal.
cat > "$TMPD/unignore.py" <<'PYLAUNCH'
import os, signal, sys
for sg in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP, signal.SIGPIPE):
    signal.signal(sg, signal.SIG_DFL)
os.execvp(sys.argv[1], sys.argv[1:])
PYLAUNCH
# run_be <script> <args...>: run a make-be.sh against the fake bectl
run_be() {
	_s=$1
	shift
	rm -rf "${TMPD:?}/mnt"
	: > "$TMPD/bectl.log"
	GB10_TEST_HOOKS=1 PRIME_KO_ORDER_TOOL="${PRIME_KO_TOOL_OVERRIDE:-$TMPD/ko-tool-good}" FAKE_MOUNT_SIGNAL="${FAKE_MOUNT_SIGNAL:-}" PRIME_ALLOW_DIRTY="${PRIME_ALLOW_DIRTY_OVERRIDE-1}" FAKE_BECTL_FAIL="${FAKE_BECTL_FAIL:-none}" FAKE_BASE_DIR="${FAKE_BASE_DIR:-}" FAKE_BECTL_LOG="$TMPD/bectl.log" BECTL="$TMPD/fake-bectl" PRIME_MNT="$TMPD/mnt" GB10_WORK="$WORK" \
	    python3 -I "$TMPD/unignore.py" sh "$_s" "$@" 2>&1
}
# the clone of a base BE that has other kits armed and an old nvidia-uvm.ko
mkdir -p "$TMPD/base/etc/rc.conf.d" "$TMPD/base/boot/modules.nvtest"
printf 'hostname="x"\nother_testboot_enable="YES"\nprime_import_testboot_enable="NO"\n' > "$TMPD/base/etc/rc.conf"
printf 'foo_testboot_enable="YES"\nfoo_testboot_other="keep"\n' > "$TMPD/base/etc/rc.conf.d/foo_testboot"
mkdir -p "$TMPD/base/etc/rc.conf.d/sub"
printf 'bar_testboot_enable="YES"\n' > "$TMPD/base/etc/rc.conf.d/sub/bar"
printf 'local_testboot_enable="YES"\n' > "$TMPD/base/etc/rc.conf.local"
printf 'quiet_testboot_enable="NO"\n' > "$TMPD/base/etc/rc.conf.d/quiet"
printf 'out_testboot_enable="YES"\n' > "$TMPD/outside-kit"
ln -s "$TMPD/outside-kit" "$TMPD/base/etc/rc.conf.d/link"
mkdir -p "$TMPD/base/usr/local/etc/rc.conf.d"
printf 'ports_testboot_enable="YES"\n' > "$TMPD/base/usr/local/etc/rc.conf.d/ports"
printf 'old' > "$TMPD/base/boot/modules.nvtest/nvidia-uvm.ko"
printf 'oldd' > "$TMPD/base/boot/modules.nvtest/nvidia-uvm.ko.debug"
printf 'k' > "$TMPD/base/boot/modules.nvtest/other.ko"
out=$(FAKE_BASE_DIR="$TMPD/base" run_be "$KIT/make-be.sh" -b base -D 20261120 -n 8 -m "$TMPD/mods")
case $out in
*"turned off the other test-boot kits in "*"/etc/rc.conf.d/foo_testboot"*) ok "(d) the message names a file it really changed" ;;
*) bad "(d) no message for a file it changed" ;;
esac
case $out in
*"kits in "*"/etc/rc.conf.d/quiet"*) bad "(d) the message claims it turned off a kit that was already off" ;;
*) ok "(d) a file whose kit was already off is not reported as changed" ;;
esac
M="$TMPD/mnt"
if [ "$(cat "$TMPD/outside-kit")" = 'out_testboot_enable="YES"' ]; then
	ok "(d) a symbolic link in the clone is not written through (the file it points to is untouched)"
else
	bad "(d) make-be.sh wrote through a symbolic link: $(cat "$TMPD/outside-kit")"
fi
if grep -q '^ports_testboot_enable="NO"' "$M/usr/local/etc/rc.conf.d/ports"; then
	ok "(d) a kit armed under /usr/local/etc/rc.conf.d is turned off too"
else
	bad "(d) a kit armed under /usr/local/etc/rc.conf.d survives the clone"
fi
if grep -q '^other_testboot_enable="NO"' "$M/etc/rc.conf" && grep -q '^foo_testboot_enable="NO"' "$M/etc/rc.conf.d/foo_testboot" \
    && grep -q 'foo_testboot_other="keep"' "$M/etc/rc.conf.d/foo_testboot" && grep -q '^hostname="x"' "$M/etc/rc.conf" \
    && grep -q '^bar_testboot_enable="NO"' "$M/etc/rc.conf.d/sub/bar" && grep -q '^local_testboot_enable="NO"' "$M/etc/rc.conf.local" \
    && grep -q 'prime_import_testboot_enable="YES"' "$M/etc/rc.conf.d/prime_import_testboot"; then
	ok "(d) the clone turns off every other test-boot kit, keeps the other settings, and enables only this kit"
else
	bad "(d) the clone still has another kit armed: $(cat "$M/etc/rc.conf" "$M"/etc/rc.conf.d/* 2>&1 | tr '\n' ' ')"
fi
if [ ! -e "$M/boot/modules.nvtest/nvidia-uvm.ko" ] && [ ! -e "$M/boot/modules.nvtest/nvidia-uvm.ko.debug" ] && [ -f "$M/boot/modules.nvtest/other.ko" ]; then
	ok "(d) without -u an nvidia-uvm.ko left by the base BE is removed (and nothing else)"
else
	bad "(d) the base BE's nvidia-uvm.ko survives the clone"
fi
# a symbolic link on the rc.conf path itself (find -type f would not see it): not written through
mkdir -p "$TMPD/base2/etc"
printf 'link_testboot_enable="YES"\n' > "$TMPD/outside-rc"
ln -s "$TMPD/outside-rc" "$TMPD/base2/etc/rc.conf"
out=$(FAKE_BASE_DIR="$TMPD/base2" run_be "$KIT/make-be.sh" -b base -D 20261120 -n 5 -m "$TMPD/mods")
if [ "$(cat "$TMPD/outside-rc")" = 'link_testboot_enable="YES"' ]; then
	ok "(d) a symbolic link on the rc.conf path itself is not written through"
else
	bad "(d) make-be.sh wrote through a symbolic link on the rc.conf path: $(cat "$TMPD/outside-rc")"
fi
case $out in *"is a symbolic link"*) ok "(d) ... and says so" ;; *) bad "(d) a symbolic link is skipped silently" ;; esac
out=$(FAKE_BASE_DIR="$TMPD/base" run_be "$KIT/make-be.sh" -b base -D 20261120 -n 9 -m "$TMPD/mods" -u "$TMPD/uvm.ko")
[ "$(cat "$TMPD/mnt/boot/modules.nvtest/nvidia-uvm.ko" 2>/dev/null)" = u ] && ok "(d) with -u the given nvidia-uvm.ko is the one in the clone" || bad "(d) -u did not give the clone its nvidia-uvm.ko"
# a base BE with neither rc.conf.d directory, and one with only /usr/local/etc/rc.conf.d: the clone still builds
mkdir -p "$TMPD/base3/etc" "$TMPD/base4/etc" "$TMPD/base4/usr/local/etc/rc.conf.d"
printf 'hostname="y"\n' > "$TMPD/base3/etc/rc.conf"
printf 'hostname="z"\n' > "$TMPD/base4/etc/rc.conf"
printf 'only_testboot_enable="YES"\n' > "$TMPD/base4/usr/local/etc/rc.conf.d/only"
out=$(FAKE_BASE_DIR="$TMPD/base3" run_be "$KIT/make-be.sh" -b base -D 20261120 -n 3 -m "$TMPD/mods"); rc=$?
[ "$rc" -eq 0 ] && grep -q 'prime_import_testboot_enable="YES"' "$TMPD/mnt/etc/rc.conf.d/prime_import_testboot" && ok "(d) a base with neither /etc/rc.conf.d nor /usr/local/etc/rc.conf.d: the clone builds" || bad "(d) a base without rc.conf.d directories: rc=$rc $out"
out=$(FAKE_BASE_DIR="$TMPD/base4" run_be "$KIT/make-be.sh" -b base -D 20261120 -n 4 -m "$TMPD/mods"); rc=$?
[ "$rc" -eq 0 ] && grep -q '^only_testboot_enable="NO"' "$TMPD/mnt/usr/local/etc/rc.conf.d/only" && ok "(d) a base with only /usr/local/etc/rc.conf.d: the clone builds and that kit is turned off" || bad "(d) a base with one rc.conf.d directory: rc=$rc $out"
# a failure after the clone exists removes the half-built boot environment
out=$(FAKE_BECTL_FAIL=mount run_be "$KIT/make-be.sh" -b base -D 20261120 -n 6 -m "$TMPD/mods"); rc=$?
if [ "$rc" -ne 0 ] && grep -q 'destroy -F nvidia-prime-import-test-20261120-6' "$TMPD/bectl.log" && grep -q 'umount -f nvidia-prime-import-test-20261120-6' "$TMPD/bectl.log"; then
	ok "(d) a failure after the clone exists unmounts and removes the half-built boot environment"
else
	bad "(d) a failed run left the half-built BE: rc=$rc $(cat "$TMPD/bectl.log" | tr '\n' '|')"
fi
# a failed create leaves nothing to clean up: no umount and no destroy (the clone is not ours until it exists)
out=$(FAKE_BECTL_FAIL=create run_be "$KIT/make-be.sh" -b base -D 20261120 -n 6 -m "$TMPD/mods"); rc=$?
if [ "$rc" -ne 0 ] && grep -q 'create' "$TMPD/bectl.log" && ! grep -q 'umount\|destroy' "$TMPD/bectl.log"; then ok "(d) a failed create runs no umount and no destroy"; else bad "(d) a failed create cleaned up something: rc=$rc $(tr '\n' '|' < "$TMPD/bectl.log")"; fi
# a base equal to the target name is refused before anything runs (a failure would remove the base)
out=$(run_be "$KIT/make-be.sh" -b nvidia-prime-import-test-20261120-7 -D 20261120 -n 7 -m "$TMPD/mods"); rc=$?
if [ "$rc" -eq 2 ] && ! grep -q 'create\|destroy' "$TMPD/bectl.log"; then ok "(d) a base boot environment with the target's name is refused before anything is created or removed"; else bad "(d) base equal to the target: rc=$rc $(tr '\n' '|' < "$TMPD/bectl.log")"; fi
# a signal while mounting (INT, TERM, HUP): the exit code says which, and the half-built BE is removed
for sg in INT:130 TERM:143 HUP:129; do
	out=$(FAKE_MOUNT_SIGNAL="${sg%%:*}" run_be "$KIT/make-be.sh" -b base -D 20261120 -n 6 -m "$TMPD/mods"); rc=$?
	if [ "$rc" -eq "${sg##*:}" ] && grep -q 'destroy -F nvidia-prime-import-test-20261120-6' "$TMPD/bectl.log"; then ok "(d) $sg while mounting: exit ${sg##*:} and the half-built BE is removed"; else bad "(d) $sg while mounting: rc=$rc log: $(tr '\n' '|' < "$TMPD/bectl.log")"; fi
done
# the final umount fails: the BE is not done, so it is removed
out=$(FAKE_BECTL_FAIL=umount run_be "$KIT/make-be.sh" -b base -D 20261120 -n 6 -m "$TMPD/mods"); rc=$?
if [ "$rc" -ne 0 ] && grep -q 'destroy -F nvidia-prime-import-test-20261120-6' "$TMPD/bectl.log"; then ok "(d) a failing final umount removes the half-built BE"; else bad "(d) a failing final umount: rc=$rc log: $(tr '\n' '|' < "$TMPD/bectl.log")"; fi
out=$(run_be "$KIT/make-be.sh" -b base -D 20261120 -n 6 -m "$TMPD/mods"); rc=$?
if [ "$rc" -eq 0 ] && ! grep -q 'destroy' "$TMPD/bectl.log"; then ok "(d) a successful run removes nothing"; else bad "(d) a successful run destroyed something: $(cat "$TMPD/bectl.log" | tr '\n' '|')"; fi
mkdir -p "$TMPD/ctl2"; cp "$KIT"/* "$TMPD/ctl2/"
# bases for the two path guards: a symbolic link INSIDE the clone (only the -L guard stops it), and a
# directory of the clone that is a symbolic link to a directory outside it (only the realpath guard stops it)
mkdir -p "$TMPD/base5/etc" "$TMPD/outside-etc/rc.conf.d" "$TMPD/base5/usr/local"
printf 'hostname="w"\n' > "$TMPD/base5/etc/rc.conf"
printf 'esc_testboot_enable="YES"\n' > "$TMPD/outside-etc/rc.conf.d/esc"
ln -s "$TMPD/outside-etc" "$TMPD/base5/usr/local/etc"
mkdir -p "$TMPD/base6/etc"
printf 'hostname="v"\n' > "$TMPD/base6/etc/rc.conf"
printf 'inl_testboot_enable="YES"\n' > "$TMPD/base6/etc/real-local"
ln -s real-local "$TMPD/base6/etc/rc.conf.local"
out=$(FAKE_BASE_DIR="$TMPD/base5" run_be "$KIT/make-be.sh" -b base -D 20261120 -n 5 -m "$TMPD/mods")
if [ "$(cat "$TMPD/outside-etc/rc.conf.d/esc")" = 'esc_testboot_enable="YES"' ]; then
	ok "(d) a directory of the clone that is a symbolic link out of it is not written through"
else
	bad "(d) make-be.sh wrote outside the clone through a symbolic link directory: $(cat "$TMPD/outside-etc/rc.conf.d/esc")"
fi
case $out in *"resolves outside the clone"*) ok "(d) ... and says so" ;; *) bad "(d) the escaping path is skipped silently" ;; esac
out=$(FAKE_BASE_DIR="$TMPD/base6" run_be "$KIT/make-be.sh" -b base -D 20261120 -n 5 -m "$TMPD/mods")
[ "$(cat "$TMPD/mnt/etc/real-local")" = 'inl_testboot_enable="YES"' ] && case $out in *"is a symbolic link"*) ok "(d) a symbolic link inside the clone is skipped and named" ;; *) bad "(d) the in-clone symbolic link is skipped silently" ;; esac || bad "(d) an in-clone symbolic link was written through"
# mut_be <name> <sed arguments>: the mutated make-be.sh goes to ctl2/make-be.sh; false when the mutation changed nothing
mut_be() {
	_mn=$1; shift
	sed "$@" "$KIT/make-be.sh" > "$TMPD/ctl2/make-be.sh"
	if cmp -s "$KIT/make-be.sh" "$TMPD/ctl2/make-be.sh"; then bad "(d) control $_mn: the mutation changed nothing (stale test)"; return 1; fi
	return 0
}
if mut_be symlink-guard -e '/^	if \[ -L "\$_f" \]; then/s/.*/	:/'; then
	FAKE_BASE_DIR="$TMPD/base6" run_be "$TMPD/ctl2/make-be.sh" -b base -D 20261120 -n 5 -m "$TMPD/mods" > /dev/null 2>&1
	[ "$(cat "$TMPD/mnt/etc/real-local")" = 'inl_testboot_enable="YES"' ] && bad "(d) control symlink-guard: a make-be.sh without the -L guard was not seen" || ok "(d) control: a make-be.sh without the symbolic-link guard writes through an in-clone link, and the test sees it"
fi
if mut_be realpath-guard -e '/^	case \$(realpath/s/.*/	:/'; then
	FAKE_BASE_DIR="$TMPD/base5" run_be "$TMPD/ctl2/make-be.sh" -b base -D 20261120 -n 5 -m "$TMPD/mods" > /dev/null 2>&1
	[ "$(cat "$TMPD/outside-etc/rc.conf.d/esc")" = 'esc_testboot_enable="YES"' ] && bad "(d) control realpath-guard: a make-be.sh without the realpath guard was not seen" || ok "(d) control: a make-be.sh without the realpath guard writes outside the clone, and the test sees it"
	printf 'esc_testboot_enable="YES"\n' > "$TMPD/outside-etc/rc.conf.d/esc"
fi
if mut_be dir-guard -e '/^		\[ -d "\$MNT\/\$_n" \] || continue$/s/.*/		:/' -e 's/ 2>\/dev\/null || :$/ 2>\/dev\/null/'; then
	( FAKE_BASE_DIR="$TMPD/base3" run_be "$TMPD/ctl2/make-be.sh" -b base -D 20261120 -n 3 -m "$TMPD/mods" > /dev/null 2>&1 ) && bad "(d) control dir-guard: a make-be.sh that dies on a missing directory was not seen" || ok "(d) control: a make-be.sh that dies on a missing rc.conf.d directory is seen"
fi
if mut_be no-cleanup-trap -e 's/^trap cleanup EXIT$/:/'; then
	FAKE_BECTL_FAIL=mount run_be "$TMPD/ctl2/make-be.sh" -b base -D 20261120 -n 6 -m "$TMPD/mods" > /dev/null 2>&1
	grep -q 'destroy' "$TMPD/bectl.log" && bad "(d) control no-cleanup-trap: a make-be.sh without the trap was not seen" || ok "(d) control: a make-be.sh without the cleanup trap is seen"
fi
if mut_be be-made-early -e 's/^BE_MADE=0$/BE_MADE=1/'; then
	FAKE_BECTL_FAIL=create run_be "$TMPD/ctl2/make-be.sh" -b base -D 20261120 -n 6 -m "$TMPD/mods" > /dev/null 2>&1
	grep -q 'destroy' "$TMPD/bectl.log" && ok "(d) control: a make-be.sh that counts the BE as made before it exists removes a BE it did not make, and the test above sees it" || bad "(d) control be-made-early: not seen"
fi
if mut_be no-signal-traps -e "/^trap 'exit 1[0-9][0-9]' [A-Z]*\$/s/.*/:/"; then
	FAKE_MOUNT_SIGNAL=TERM run_be "$TMPD/ctl2/make-be.sh" -b base -D 20261120 -n 6 -m "$TMPD/mods" > /dev/null 2>&1
	grep -q 'destroy' "$TMPD/bectl.log" && bad "(d) control no-signal-traps: a make-be.sh without the signal traps was not seen" || ok "(d) control: a make-be.sh without the signal traps leaves the half-built BE, and the test above sees it"
fi
if mut_be done-early -e 's/^run "\$BECTL" umount "\$BE"$/BE_DONE=1; run "$BECTL" umount "$BE"/'; then
	FAKE_BECTL_FAIL=umount run_be "$TMPD/ctl2/make-be.sh" -b base -D 20261120 -n 6 -m "$TMPD/mods" > /dev/null 2>&1
	grep -q 'destroy -F' "$TMPD/bectl.log" && bad "(d) control done-early: a make-be.sh that marks the BE done before the umount was not seen" || ok "(d) control: a make-be.sh that marks the BE done before the final umount keeps a half-built BE, and the test above sees it"
fi
out=$(FAKE_BECTL_FAIL="mount destroy" run_be "$KIT/make-be.sh" -b base -D 20261120 -n 6 -m "$TMPD/mods")
case $out in *"COULD NOT remove the half-built boot environment"*) ok "(d) when the half-built BE cannot be removed, the message says so" ;; *) bad "(d) a failed removal is reported as a success: $out" ;; esac
if mut_be keep-other-kits -e '/^	grep -Eq .*_testboot_enable=.* || return 0$/s/.*/	return 0/'; then
	FAKE_BASE_DIR="$TMPD/base" run_be "$TMPD/ctl2/make-be.sh" -b base -D 20261120 -n 8 -m "$TMPD/mods" > /dev/null
	grep -q '^other_testboot_enable="YES"' "$TMPD/mnt/etc/rc.conf" && ok "(d) control: a make-be.sh that leaves the other kits armed is seen" || bad "(d) control keep-other-kits: not seen"
fi
if mut_be keep-uvm -e '/^	run rm -f "\$MNT"\/boot\/modules.nvtest\/nvidia-uvm.ko /s/.*/	:/'; then
	FAKE_BASE_DIR="$TMPD/base" run_be "$TMPD/ctl2/make-be.sh" -b base -D 20261120 -n 8 -m "$TMPD/mods" > /dev/null
	[ -e "$TMPD/mnt/boot/modules.nvtest/nvidia-uvm.ko" ] && ok "(d) control: a make-be.sh that keeps the base's nvidia-uvm.ko is seen" || bad "(d) control keep-uvm: not seen"
fi
# the kit that boots comes from a committed state: a dirty git work tree is refused, a clean one is recorded, an
# archive carries its commit in KIT-COMMIT (git archive expands it), and -V is checked against it, never trusted
# a copy of the kit with the literal KIT-COMMIT of the work tree (when the suite itself runs from an archive,
# $KIT/KIT-COMMIT is the expanded commit, which must not leak into the fake repositories)
kitcopy() { rm -rf "$1"; mkdir -p "$1"; cp "$KIT"/* "$1/"; printf '%s\n' '$Format:%H$' > "$1/KIT-COMMIT"; }
kitcopy "$TMPD/gitkit"
printf 'KIT-COMMIT export-subst\n' > "$TMPD/gitkit/.gitattributes"
# the order checker that sits in the kit: a stand-in that accepts (the staged module of these tests is not an ELF file)
cp "$TMPD/ko-tool-good" "$TMPD/gitkit/ko_sysinit_order.py"
( cd "$TMPD/gitkit" && git init -q . && git add -A . && git -c core.hooksPath=/dev/null -c user.name=t -c user.email=t@t commit -q --no-verify -m kit ) > /dev/null 2>&1
gsha=$(git -C "$TMPD/gitkit" rev-parse --verify HEAD 2>/dev/null)
case $gsha in ''|*[!0-9a-f]*) bad "(d) the test could not make a git repository of the kit to commit in" ;; esac
bev() { cat "$TMPD/mnt/usr/local/etc/prime_import_testboot.version" 2>/dev/null; }
out=$(PRIME_ALLOW_DIRTY_OVERRIDE=0 run_be "$TMPD/gitkit/make-be.sh" -b base -D 20261120 -n 2 -m "$TMPD/mods"); rc=$?
if [ "$rc" -eq 0 ] && [ "$(bev)" = "$gsha" ]; then ok "(d) a clean git work tree builds the BE and records its HEAD"; else bad "(d) a clean git work tree: rc=$rc version='$(bev)' want '$gsha' $out"; fi
out=$(PRIME_ALLOW_DIRTY_OVERRIDE=0 run_be "$TMPD/gitkit/make-be.sh" -b base -D 20261120 -n 2 -m "$TMPD/mods" -V "$(echo "$gsha" | cut -c1-8)"); rc=$?
[ "$rc" -eq 0 ] && ok "(d) in a git work tree, a -V that is a prefix of HEAD is accepted" || bad "(d) -V prefix of HEAD refused: rc=$rc $out"
out=$(PRIME_ALLOW_DIRTY_OVERRIDE=0 run_be "$TMPD/gitkit/make-be.sh" -b base -D 20261120 -n 2 -m "$TMPD/mods" -V 0123abc); rc=$?
[ "$rc" -eq 2 ] && ok "(d) in a git work tree, a -V that is not HEAD is refused" || bad "(d) -V that is not HEAD: rc=$rc"
echo "# changed" >> "$TMPD/gitkit/make-be.sh"
out=$(PRIME_ALLOW_DIRTY_OVERRIDE=0 run_be "$TMPD/gitkit/make-be.sh" -b base -D 20261120 -n 2 -m "$TMPD/mods"); rc=$?
case $out in *"uncommitted changes"*) [ "$rc" -eq 2 ] && ok "(d) a dirty git work tree is refused (exit 2)" || bad "(d) a dirty tree is refused with rc=$rc" ;; *) bad "(d) a dirty git work tree builds a BE: rc=$rc" ;; esac
git -C "$TMPD/gitkit" checkout -q -- make-be.sh 2>/dev/null
# git state that hides a change from git status does not hide it from the content comparison
git -C "$TMPD/gitkit" update-index --assume-unchanged make-be.sh
echo "# hidden change" >> "$TMPD/gitkit/make-be.sh"
out=$(PRIME_ALLOW_DIRTY_OVERRIDE=0 run_be "$TMPD/gitkit/make-be.sh" -b base -D 20261120 -n 2 -m "$TMPD/mods"); rc=$?
[ "$rc" -eq 2 ] && ok "(d) a change hidden with assume-unchanged is still refused" || bad "(d) assume-unchanged hides a change: rc=$rc"
git -C "$TMPD/gitkit" update-index --no-assume-unchanged make-be.sh
git -C "$TMPD/gitkit" checkout -q -- make-be.sh 2>/dev/null
# a tracked KIT-COMMIT that holds a hex id (forged, or committed expanded) does not make the archive branch run
printf '%s\n' "$gsha" > "$TMPD/gitkit/KIT-COMMIT"
echo "# edited after the forged record" >> "$TMPD/gitkit/make-be.sh"
out=$(PRIME_ALLOW_DIRTY_OVERRIDE=0 run_be "$TMPD/gitkit/make-be.sh" -b base -D 20261120 -n 2 -m "$TMPD/mods"); rc=$?
case $out in *"differs from the committed"*) [ "$rc" -eq 2 ] && ok "(d) a forged hex KIT-COMMIT in a git work tree with an edited make-be.sh is refused" || bad "(d) forged KIT-COMMIT rc=$rc" ;; *) bad "(d) a forged KIT-COMMIT made a dirty work tree build: rc=$rc $out" ;; esac
git -C "$TMPD/gitkit" checkout -q -- make-be.sh KIT-COMMIT 2>/dev/null
# the same with KIT-COMMIT taken out of the index, and with the hex record committed: the work tree is still checked
git -C "$TMPD/gitkit" rm -q --cached KIT-COMMIT; printf '%s\n' "$gsha" > "$TMPD/gitkit/KIT-COMMIT"; echo "# edited" >> "$TMPD/gitkit/make-be.sh"
out=$(PRIME_ALLOW_DIRTY_OVERRIDE=0 run_be "$TMPD/gitkit/make-be.sh" -b base -D 20261120 -n 2 -m "$TMPD/mods"); rc=$?
case $out in *"differs from the committed"* | *"is not tracked"*) [ "$rc" -eq 2 ] && ok "(d) an untracked forged KIT-COMMIT beside a tracked make-be.sh is refused" || bad "(d) un-tracked KIT-COMMIT rc=$rc" ;; *) bad "(d) an index entry removed for KIT-COMMIT made a dirty tree build: rc=$rc $out" ;; esac
git -C "$TMPD/gitkit" reset -q -- KIT-COMMIT; git -C "$TMPD/gitkit" checkout -q -- make-be.sh KIT-COMMIT 2>/dev/null
printf '%s\n' "$gsha" > "$TMPD/gitkit/KIT-COMMIT"; git -C "$TMPD/gitkit" -c core.hooksPath=/dev/null -c user.name=t -c user.email=t@t commit -q --no-verify -am forged
echo "# edited after the hex record was committed" >> "$TMPD/gitkit/make-be.sh"
out=$(PRIME_ALLOW_DIRTY_OVERRIDE=0 run_be "$TMPD/gitkit/make-be.sh" -b base -D 20261120 -n 2 -m "$TMPD/mods"); rc=$?
case $out in *"differs from the committed"*) [ "$rc" -eq 2 ] && ok "(d) a committed hex KIT-COMMIT with an edited make-be.sh is refused" || bad "(d) committed hex KIT-COMMIT rc=$rc" ;; *) bad "(d) a committed hex KIT-COMMIT made a dirty tree build: rc=$rc $out" ;; esac
git -C "$TMPD/gitkit" reset -q --hard HEAD~1
# a repository that git cannot read is refused, never taken for "no repository"
kitcopy "$TMPD/badrepo"; printf '%s\n' "$gsha" > "$TMPD/badrepo/KIT-COMMIT"; printf 'gitdir: %s/nowhere\n' "$TMPD" > "$TMPD/badrepo/.git"
out=$(PRIME_ALLOW_DIRTY_OVERRIDE=0 run_be "$TMPD/badrepo/make-be.sh" -b base -D 20261120 -n 2 -m "$TMPD/mods"); rc=$?
case $out in *"cannot read here"*) [ "$rc" -eq 2 ] && ok "(d) a kit inside a git repository that git cannot read is refused, whatever its KIT-COMMIT says" || bad "(d) unreadable repository rc=$rc" ;; *) bad "(d) an unreadable repository was taken for none: rc=$rc $out" ;; esac
# the hooks are marked: -V under the dirty hook never looks like a checked commit; a replaced order tool needs the hook
out=$(run_be "$KIT/make-be.sh" -b base -D 20261120 -n 2 -m "$TMPD/mods" -V 0123abc); rc=$?
[ "$rc" -eq 0 ] && [ "$(bev)" = "unchecked-0123abc" ] && ok "(d) a -V under the dirty-tree hook is recorded as unchecked" || bad "(d) -V under the hook: rc=$rc version='$(bev)'"
out=$(PRIME_ALLOW_DIRTY_OVERRIDE=0 PRIME_KO_TOOL_OVERRIDE="$TMPD/ko-tool-bad" run_be "$TMPD/gitkit/make-be.sh" -b base -D 20261120 -n 2 -m "$TMPD/mods"); rc=$?
[ "$rc" -eq 0 ] && [ "$(bev)" = "$gsha" ] && ok "(d) a replaced order tool is ignored outside the dirty-tree hook (the kit's own checker ran)" || bad "(d) a replaced order tool was honoured outside the hook: rc=$rc version='$(bev)'"
rm -rf "$TMPD/archkit"; mkdir -p "$TMPD/archkit"
git -C "$TMPD/gitkit" archive HEAD | tar -x -C "$TMPD/archkit"
out=$(PRIME_ALLOW_DIRTY_OVERRIDE=0 run_be "$TMPD/archkit/make-be.sh" -b base -D 20261120 -n 2 -m "$TMPD/mods"); rc=$?
[ "$rc" -eq 0 ] && [ "$(bev)" = "$gsha" ] && ok "(d) a kit from git archive records the commit its KIT-COMMIT carries (no -V needed)" || bad "(d) archive kit: rc=$rc version='$(bev)' $out"
out=$(PRIME_ALLOW_DIRTY_OVERRIDE=0 run_be "$TMPD/archkit/make-be.sh" -b base -D 20261120 -n 2 -m "$TMPD/mods" -V "$(echo "$gsha" | cut -c1-8)"); rc=$?
[ "$rc" -eq 0 ] && ok "(d) a -V that agrees with the archive's commit is accepted" || bad "(d) -V agreeing with the archive refused: rc=$rc $out"
out=$(PRIME_ALLOW_DIRTY_OVERRIDE=0 run_be "$TMPD/archkit/make-be.sh" -b base -D 20261120 -n 2 -m "$TMPD/mods" -V 0123abc); rc=$?
[ "$rc" -eq 2 ] && ok "(d) a -V that differs from the archive's commit is refused" || bad "(d) -V differing from the archive: rc=$rc"
out=$(PRIME_ALLOW_DIRTY_OVERRIDE=0 run_be "$TMPD/archkit/make-be.sh" -b base -D 20261120 -n 2 -m "$TMPD/mods" -V a); rc=$?
[ "$rc" -eq 2 ] && ok "(d) a one-digit -V is refused (at least 7 hex digits)" || bad "(d) one-digit -V: rc=$rc"
out=$(PRIME_ALLOW_DIRTY_OVERRIDE=0 run_be "$TMPD/archkit/make-be.sh" -b base -D 20261120 -n 2 -m "$TMPD/mods" -V "$(echo "$gsha" | cut -c1-8 | tr a-f A-F)"); rc=$?
[ "$rc" -eq 0 ] && ok "(d) an upper-case -V that is the commit is accepted" || bad "(d) upper-case -V refused: rc=$rc $out"
rm -rf "$TMPD/outer2"; mkdir -p "$TMPD/outer2/inner"; cp -R "$TMPD/archkit/." "$TMPD/outer2/inner/"
( cd "$TMPD/outer2" && git init -q . && printf 'junk\n' > junk && git add junk && git -c core.hooksPath=/dev/null -c user.name=t -c user.email=t@t commit -q --no-verify -m x ) > /dev/null 2>&1
out=$(PRIME_ALLOW_DIRTY_OVERRIDE=0 run_be "$TMPD/outer2/inner/make-be.sh" -b base -D 20261120 -n 2 -m "$TMPD/mods"); rc=$?
[ "$rc" -eq 0 ] && ok "(d) a git archive extracted inside some other git work tree is accepted (its KIT-COMMIT decides)" || bad "(d) an archive inside a git tree refused: rc=$rc $out"
out=$(PRIME_ALLOW_DIRTY_OVERRIDE=0 run_be "$TMPD/archkit/make-be.sh" -b base -D 20261120 -n 2 -m "$TMPD/mods" -V 'not hex'); rc=$?
[ "$rc" -eq 2 ] && ok "(d) a -V that is not hex is refused" || bad "(d) -V not hex rc=$rc"
kitcopy "$TMPD/plaink"
out=$(PRIME_ALLOW_DIRTY_OVERRIDE=0 run_be "$TMPD/plaink/make-be.sh" -b base -D 20261120 -n 2 -m "$TMPD/mods" -V 0123abc); rc=$?
[ "$rc" -eq 2 ] && ok "(d) a copied kit (no git, no expanded KIT-COMMIT) is refused even with -V: the commit cannot be checked" || bad "(d) a copied kit with -V built a BE: rc=$rc"
# a kit that sits untracked (here: ignored) inside somebody else's repository is not a committed kit
kitcopy "$TMPD/outer/kit"; cp "$TMPD/ko-tool-good" "$TMPD/outer/kit/ko_sysinit_order.py"
( cd "$TMPD/outer" && git init -q . && printf 'kit/\n' > .gitignore && git add -A . && git -c core.hooksPath=/dev/null -c user.name=t -c user.email=t@t commit -q --no-verify -m x ) > /dev/null 2>&1
out=$(PRIME_ALLOW_DIRTY_OVERRIDE=0 run_be "$TMPD/outer/kit/make-be.sh" -b base -D 20261120 -n 2 -m "$TMPD/mods"); rc=$?
case $out in *"not tracked"*) [ "$rc" -eq 2 ] && ok "(d) a kit that is not tracked by the repository around it is refused" || bad "(d) untracked kit rc=$rc" ;; *) bad "(d) an untracked kit inside another repository builds a BE: rc=$rc" ;; esac
kitcopy "$TMPD/outer3/kit"
( cd "$TMPD/outer3" && git init -q . && printf 'kit/*\n!kit/make-be.sh\n' > .gitignore && git add -A . && git -c core.hooksPath=/dev/null -c user.name=t -c user.email=t@t commit -q --no-verify -m x ) > /dev/null 2>&1
out=$(PRIME_ALLOW_DIRTY_OVERRIDE=0 run_be "$TMPD/outer3/kit/make-be.sh" -b base -D 20261120 -n 2 -m "$TMPD/mods"); rc=$?
case $out in *"prime_import_testboot is not tracked"*) [ "$rc" -eq 2 ] && ok "(d) a kit of which only make-be.sh is tracked is refused, naming the untracked file" || bad "(d) partly tracked kit rc=$rc" ;; *) bad "(d) a partly tracked kit builds a BE: rc=$rc $out" ;; esac
out=$(GB10_TEST_HOOKS=1 PRIME_ALLOW_DIRTY=1 sh "$KIT/make-be.sh" -b base -D 20261120 -n 3 --dry-run 2>&1)
case $out in *"module order"*"NOT checked"*) ok "(d) a dry run says that it does not check the module order" ;; *) bad "(d) a dry run is silent about the module order" ;; esac
# controls: the dirty check, the ls-files check and the -V check each seen when removed
cp "$KIT/prime_import_testboot" "$TMPD/gitkit/"; echo "# dirty" >> "$TMPD/gitkit/prime_import_testboot"
sed -e '/^[[:space:]]*if \[ -n "\$(git -C "\$KITDIR" status --porcelain/s/.*/	if false; then/' -e '/^[[:space:]]*\[ "\$(git -C "\$KITDIR" hash-object/s/.*/		true || {/' "$KIT/make-be.sh" > "$TMPD/gitkit/make-be.sh"
if cmp -s "$KIT/make-be.sh" "$TMPD/gitkit/make-be.sh"; then bad "(d) control dirty-check: the mutation changed nothing (stale test)"; else
	out=$(PRIME_ALLOW_DIRTY_OVERRIDE=0 run_be "$TMPD/gitkit/make-be.sh" -b base -D 20261120 -n 2 -m "$TMPD/mods"); rc=$?
	[ "$rc" -eq 0 ] && ok "(d) control: a make-be.sh without the dirty check builds from a dirty tree, and the test above sees it" || bad "(d) control dirty-check: not seen ($rc)"
fi
sed -e '/^[[:space:]]*git -C "\$KITDIR" ls-files --error-unmatch/s/.*/		true || {/' -e '/^[[:space:]]*\[ "\$(git -C "\$KITDIR" hash-object/s/.*/		true || {/' "$KIT/make-be.sh" > "$TMPD/outer/kit/make-be.sh"
if cmp -s "$KIT/make-be.sh" "$TMPD/outer/kit/make-be.sh"; then bad "(d) control ls-files: the mutation changed nothing (stale test)"; else
	out=$(PRIME_ALLOW_DIRTY_OVERRIDE=0 run_be "$TMPD/outer/kit/make-be.sh" -b base -D 20261120 -n 2 -m "$TMPD/mods"); rc=$?
	[ "$rc" -eq 0 ] && ok "(d) control: a make-be.sh without the tracked-file check builds an untracked kit, and the test above sees it" || bad "(d) control ls-files: not seen ($rc)"
fi
sed 's/^[[:space:]]*if \[ -n "\$COMMIT" \] \&\& ! same_commit "\$COMMIT" "\$ARCHIVE_SHA"; then/if false; then/' "$KIT/make-be.sh" > "$TMPD/archkit/make-be.sh"
if cmp -s "$KIT/make-be.sh" "$TMPD/archkit/make-be.sh"; then bad "(d) control -V check: the mutation changed nothing (stale test)"; else
	out=$(PRIME_ALLOW_DIRTY_OVERRIDE=0 run_be "$TMPD/archkit/make-be.sh" -b base -D 20261120 -n 2 -m "$TMPD/mods" -V 0123abc); rc=$?
	[ "$rc" -eq 0 ] && ok "(d) control: a make-be.sh that takes -V on trust builds with a wrong commit, and the test above sees it" || bad "(d) control -V check: not seen ($rc)"
fi
# the module order of the staged nvidia-drm.ko is checked before anything is created
for kv in bad:order noguard:declare garbage:cannot; do
	_kt="$TMPD/ko-tool-${kv%%:*}"
	case ${kv%%:*} in
	bad) printf 'print("the guard (order 0xf000000) does not load after the driver module (order 0xfffffff): it would unload last")\nraise SystemExit(1)\n' > "$_kt" ;;
	noguard) printf 'print("the file does not declare both nvidia_drm and nvidia_drm_pi_guard")\nraise SystemExit(1)\n' > "$_kt" ;;
	garbage) printf 'import sys\nsys.exit("not an arm64 module")\n' > "$_kt" ;;
	esac
	: > "$TMPD/bectl.log"
	out=$(PRIME_KO_TOOL_OVERRIDE="$_kt" run_be "$KIT/make-be.sh" -b base -D 20261120 -n 2 -m "$TMPD/mods"); rc=$?
	if [ "$rc" -eq 2 ] && [ ! -s "$TMPD/bectl.log" ] && case $out in *"nvidia-drm.ko:"*"rebuild from the committed tree"*) true ;; *) false ;; esac; then ok "(d) a staged nvidia-drm.ko with a module order problem ('${kv%%:*}') is refused before anything runs, with the reason and the next step"; else bad "(d) ko order '${kv%%:*}': rc=$rc out: $out log: $(tr '\n' '|' < "$TMPD/bectl.log")"; fi
done
# the staged module changes after its order was checked: refused (the checked file is the one installed)
printf 'import sys\nopen(sys.argv[-1], "ab").write(b"x")\nprint("ok")\n' > "$TMPD/ko-tool-swap"
cp "$TMPD/mods/nvidia-drm/nvidia-drm.ko" "$TMPD/nvidia-drm.ko.keep"
out=$(PRIME_KO_TOOL_OVERRIDE="$TMPD/ko-tool-swap" run_be "$KIT/make-be.sh" -b base -D 20261120 -n 2 -m "$TMPD/mods"); rc=$?
cp "$TMPD/nvidia-drm.ko.keep" "$TMPD/mods/nvidia-drm/nvidia-drm.ko"
case $out in *"changed after its module order was checked"*) [ "$rc" -ne 0 ] && ok "(d) a module that changes after its order was checked is refused" || bad "(d) swap: rc=$rc" ;; *) bad "(d) a module swapped after the order check was installed: rc=$rc" ;; esac
printf '%s\n' "$gsha" > "$TMPD/gitkit/KIT-COMMIT"
sed 's/^	if \[ "\$_trk" != yes \] \&\& \[ -n "\$ARCHIVE_SHA" \]; then/	if [ -n "$ARCHIVE_SHA" ]; then/' "$KIT/make-be.sh" > "$TMPD/gitkit/make-be.sh"
if cmp -s "$KIT/make-be.sh" "$TMPD/gitkit/make-be.sh"; then bad "(d) control forged KIT-COMMIT: the mutation changed nothing (stale test)"; else
	echo "# edited" >> "$TMPD/gitkit/make-be.sh"
	out=$(PRIME_ALLOW_DIRTY_OVERRIDE=0 run_be "$TMPD/gitkit/make-be.sh" -b base -D 20261120 -n 2 -m "$TMPD/mods"); rc=$?
	[ "$rc" -eq 0 ] && ok "(d) control: a make-be.sh that trusts a tracked KIT-COMMIT builds from a dirty tree, and the test above sees it" || bad "(d) control forged KIT-COMMIT: not seen ($rc)"
fi
git -C "$TMPD/gitkit" checkout -q -- make-be.sh KIT-COMMIT 2>/dev/null
if mut_be ko-swap -e 's/^		if \[ "\$b" = nvidia-drm.ko \] \&\& \[ "\$want" != "\$KO_SHA" \]; then/		if false; then/'; then
	PRIME_KO_TOOL_OVERRIDE="$TMPD/ko-tool-swap" run_be "$TMPD/ctl2/make-be.sh" -b base -D 20261120 -n 2 -m "$TMPD/mods" > /dev/null 2>&1; rc=$?
	cp "$TMPD/nvidia-drm.ko.keep" "$TMPD/mods/nvidia-drm/nvidia-drm.ko"
	[ "$rc" -eq 0 ] && ok "(d) control: a make-be.sh that does not compare the checked file with the installed one installs a swapped module, and the test above sees it" || bad "(d) control ko-swap: not seen ($rc)"
fi
if mut_be ko-order -e 's/^	_ko_out=\$(python3 -I -B "\$KO_TOOL" --check .*$/	_ko_out=ok/'; then
	: > "$TMPD/bectl.log"
	PRIME_KO_TOOL_OVERRIDE="$TMPD/ko-tool-bad" run_be "$TMPD/ctl2/make-be.sh" -b base -D 20261120 -n 2 -m "$TMPD/mods" > /dev/null 2>&1
	grep -q 'create' "$TMPD/bectl.log" && ok "(d) control: a make-be.sh that does not compare the order builds with a guard that unloads last, and the test above sees it" || bad "(d) control ko-order: not seen"
fi
GB10_TEST_HOOKS=1 PRIME_ALLOW_DIRTY=1 sh "$KIT/make-be.sh" > "$TMPD/nob.out" 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok "(d) make-be.sh without -b exits 2" || bad "(d) make-be.sh without -b rc=$rc"
out=$(GB10_TEST_HOOKS=1 PRIME_ALLOW_DIRTY=1 sh "$KIT/make-be.sh" -b base -D 20261120 -n 3 --dry-run 2>&1)
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
want=$(sed -n 's/^: "${prime_import_testboot_logroot:=\(.*\)}"$/\1/p' "$KIT/prime_import_testboot")
if grep -q "results land in $want/prime-import-" "$TMPD/act.out"; then
	ok "(d) the armed message names the rc script's real log directory"
else
	bad "(d) the armed message names another directory: $(tail -1 "$TMPD/act.out")"
fi

# (e) forbidden commands anywhere in the kit.  Shutdown has its own exact
# static checks below: the real path is data, and the only call is quoted via
# prime_import_testboot_shutdown.
common='kldunload|kldload|devctl|acpiconf|zzz|[^a-z_]reboot|halt -|bectl[[:space:]]+destroy'
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
# kldstat, dmesg, bectl and su first in PATH.  The paths are rc.conf variables,
# so nothing outside TMPD is touched.  Shutdown always uses G1's override stub.
FAKE=$TMPD/fake; mkdir -p "$FAKE/bin"
for t in kldstat dmesg bectl sync; do
	printf '#!/bin/sh\ncase "$0" in *kldstat) if [ "$1" = -v ]; then cat "%s/kldv" 2>/dev/null; else echo "nvidia-drm.ko amdgpu.ko"; fi;; *sync) echo s >> "%s/sync.log";; esac\nexit 0\n' "$FAKE" "$FAKE" > "$FAKE/bin/$t"
done
printf '#!/bin/sh\n[ "$1" = -n ] && case "$2" in kern.bootfile) echo /boot/kernel/kernel;; vm.stats.vm.v_wire_count) cat "%s/wired";; hw.nvidia_unlock_dirty_refused) cat "%s/refused" 2>/dev/null;; esac\nexit 0\n' "$FAKE" "$FAKE" > "$FAKE/bin/sysctl"
printf '#!/bin/sh\nexit 0\n' > "$FAKE/bin/su"
chmod +x "$FAKE"/bin/*
echo 1000 > "$FAKE/wired"
echo abcdef0123 > "$FAKE/version"
printf 'Id Refs Address Size Name\n 7 1 0xffff 1 nvidia-drm.ko (/boot/modules/nvidia-drm.ko)\n\tContains modules:\n\t\tId Name\n\t\t 31 nvidia_drm_pi_guard\n\t\t 30 nvidia_drm\n' > "$FAKE/kldv-good"
printf 'Id Refs Address Size Name\n 7 1 0xffff 1 nvidia-drm.ko (/boot/modules/nvidia-drm.ko)\n\tContains modules:\n\t\tId Name\n\t\t 30 nvidia_drm\n\t\t 31 nvidia_drm_pi_guard\n' > "$FAKE/kldv-bad"
printf 'Id Refs Address Size Name\n 7 1 0xffff 1 nvidia-drm.ko (/boot/modules/nvidia-drm.ko)\n\tContains modules:\n\t\tId Name\n\t\t 30 nvidia_drm\n' > "$FAKE/kldv-noguard"
printf 'Id Refs Address Size Name\n 1 4 0xffff 1 kernel\n' > "$FAKE/kldv-none"
cp "$FAKE/kldv-good" "$FAKE/kldv"
echo 0 > "$FAKE/refused"
# rc_run <name> <rc script> <probe>: run the one-shot, print its run directory.
# RC_UNSET_SHUTDOWN=1 omits the override for the safely substituted G3 copy.
rc_run() {
	_n=$1; _rc=$2; _pr=$3
	rm -rf "$FAKE/logs-$_n"; mkdir -p "$FAKE/logs-$_n"
	: > "$FAKE/dead-man.log"
	set --
	if [ "${RC_UNSET_SHUTDOWN:-0}" != 1 ]; then
		set -- prime_import_testboot_shutdown="${RC_STUB:-$prime_import_testboot_shutdown}"
	fi
	if [ -n "${RC_AUTOBOOT:-}" ]; then
		set -- "$@" autoboot="$RC_AUTOBOOT"
	fi
	env -u prime_import_testboot_shutdown PATH="$SENT:$FAKE/bin:$PATH" PRIME_STUB_LOG="$FAKE/dead-man.log" \
	    PRIME_STUB_REFUSE="$FAKE/shutdown-refuse" TEST_CHILD="$TEST_CHILD" TEST_PIDS="$TEST_PIDS" \
	    prime_import_testboot_logroot="$FAKE/logs-$_n" \
	    prime_import_testboot_probe="$_pr" prime_import_testboot_log="$FAKE/rc-$_n.log" \
	    prime_import_testboot_src=/dev/null prime_import_testboot_dst=/dev/null \
	    prime_import_testboot_loops=4 prime_import_testboot_probe_timeout=${RC_PROBE_TIMEOUT:-60} prime_import_testboot_loop_timeout=${RC_LOOP_TIMEOUT:-20} prime_import_testboot_deadman=${RC_DEADMAN:-60} prime_import_testboot_lockfile="$FAKE/noshutdown" prime_import_testboot_version="$FAKE/version" prime_import_testboot_linuxroot="$FAKE/none" \
	    prime_import_testboot_cudarun="$FAKE/none" prime_import_testboot_marker="$FAKE/marker" prime_import_testboot_bectl="$FAKE/bin/bectl" \
	    "$@" timeout 90 sh "$_rc" onestart > "$FAKE/rc-$_n.out" 2>&1
	ls -d "$FAKE/logs-$_n"/prime-import-* 2>/dev/null | head -1
}
pid_is_shutdown() {
	[ "$(ps -o uid= -o comm= -p "$1" 2> /dev/null | tr -d ' ')" = "$(id -u)shutdown" ]
}
rowres() {	# rowres <results.jsonl> <row>: the results of the row, in order
	grep "\"row\":\"$2\"" "$1" | sed 's/.*"result":"\([a-z]*\)".*/\1/' | tr '\n' ' '
}
# a probe that records whether the "running" row was already on disk when it ran
cat > "$FAKE/probe-good" <<PROBEEOF
#!/bin/sh
grep -q '"row":"import","result":"running"' "$FAKE/logs-good"/prime-import-*/results.jsonl && echo seen > "$FAKE/running-seen"
[ -e "$FAKE/sync-at-probe" ] || wc -l < "$FAKE/sync.log" | tr -d ' ' > "$FAKE/sync-at-probe"
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
	grep '"row":"kit-version"' "$d/results.jsonl" | grep -q 'kit commit abcdef0123' && ok "(f2) the run records which kit commit it is (kit-version row)" || bad "(f2) no kit-version row with the commit"
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
printf '%s\n' '{"row":"import","result":"pass","detail":"x"}' '{"row":"wire-count-stable","result":"skip","detail":"x"}' '{"row":"guard-order","result":"pass","detail":"x"}' '{"row":"done","result":"info","detail":"x"}' > "$TMPD/nowire.jsonl"
sh "$KIT/summarize.sh" "$TMPD/nowire.jsonl" > /dev/null 2>&1; [ $? -eq 3 ] && ok "(f2) summarize.sh: a run whose wire row was not a pass is incomplete (exit 3)" || bad "(f2) summarize.sh passes a run that did not measure the wiring"
printf '%s\n' '{"row":"import","result":"pass","detail":"x"}' '{"row":"wire-count-stable","result":"pass","detail":"x"}' '{"row":"guard-order","result":"pass","detail":"x"}' '{"row":"deadman","result":"info","detail":"armed"}' '{"row":"deadman","result":"fail","detail":"not pending"}' '{"row":"deadman","result":"info","detail":"cancelled"}' '{"row":"done","result":"info","detail":"x"}' > "$TMPD/earlyfail.jsonl"
sh "$KIT/summarize.sh" "$TMPD/earlyfail.jsonl" > "$TMPD/sum-early.txt" 2>&1; rc=$?
[ "$rc" -eq 1 ] && grep -q 'failed earlier in the run' "$TMPD/sum-early.txt" && ok "(f2) summarize.sh: a row that failed and was followed by an info row is still a failure" || bad "(f2) summarize.sh passes a row that failed earlier (rc=$rc)"
: > "$TMPD/empty.jsonl"
sh "$KIT/summarize.sh" "$TMPD/empty.jsonl" > /dev/null 2>&1; [ $? -eq 1 ] && ok "(f2) summarize.sh: an empty run fails" || bad "(f2) summarize.sh accepts an empty run"
sh "$KIT/summarize.sh" > /dev/null 2>&1; [ $? -eq 2 ] && ok "(f2) summarize.sh: no argument is a usage error" || bad "(f2) summarize.sh usage"
sh "$KIT/summarize.sh" /nonexistent > /dev/null 2>&1; [ $? -eq 2 ] && ok "(f2) summarize.sh: an unreadable file is a usage error" || bad "(f2) summarize.sh unreadable"

# the dead-man reboot: foreground arm, exact-pid cancel, decoy untouched, off at 0
"$TEST_CHILD/shutdown" 300 &
_decoy=$!
printf '%s\n' "$_decoy" >> "$TEST_PIDS"
d=$(rc_run exact "$KIT/prime_import_testboot" "$FAKE/probe-good")
_armed_pid=$(sed -n 's/.*\[pid \([0-9][0-9]*\)\].*/\1/p' "$d/deadman.txt" 2> /dev/null | head -1)
case $_armed_pid in
''|*[!0-9]*) bad "(f2) the foreground stub printed no exact dead-man pid" ;;
*)
	# the pid was started by the stub (so it was a real child, not a vacuous pass), the row says it was confirmed as a shutdown when armed
	if grep -qx "$_armed_pid" "$TEST_PIDS" && grep '"row":"deadman"' "$d/results.jsonl" | head -1 | grep -q "pending as pid $_armed_pid" &&
	    ! pid_is_shutdown "$_armed_pid" && pid_is_shutdown "$_decoy"; then
		ok "(f2) cancel kills the recorded pid $_armed_pid and leaves same-name decoy $_decoy alive"
	else
		bad "(f2) exact-pid cancel: armed pid '$_armed_pid', decoy '$_decoy'"
	fi
	;;
esac
kill "$_decoy" 2> /dev/null || :
wait "$_decoy" 2> /dev/null || :
if grep -q 'shutdown -r +60' "$FAKE/dead-man.log" 2>/dev/null &&
    grep '"row":"deadman"' "$d/results.jsonl" | head -1 | grep -q "pending as pid $_armed_pid"; then
	ok "(f2) the dead-man timer is armed for 60 minutes in the foreground and confirmed by pid"
else
	bad "(f2) no confirmed dead-man reboot was armed: $(cat "$FAKE/dead-man.log" 2>/dev/null)"
fi
case $(rowres "$d/results.jsonl" deadman) in "info info ") ok "(f2) the arm and the cancel are both recorded" ;; *) bad "(f2) deadman rows: '$(rowres "$d/results.jsonl" deadman)'" ;; esac
grep '"row":"deadman"' "$d/results.jsonl" | head -1 | grep -q 'a stubbed shutdown is used' &&
    ok "(f2) the arm row says that a stubbed shutdown is used" || bad "(f2) the arm row does not identify the stub"
d=$(RC_DEADMAN=0 rc_run nodead "$KIT/prime_import_testboot" "$FAKE/probe-good")
[ ! -s "$FAKE/dead-man.log" ] && ok "(f2) with the dead-man set to 0 nothing is armed" || bad "(f2) a dead-man was armed with the variable at 0"
# the unload order: the guard listed before nvidia_drm passes; after, absent or no driver does not
d=$(rc_run orderok "$KIT/prime_import_testboot" "$FAKE/probe-good")
[ "$(rowres "$d/results.jsonl" guard-order)" = "pass " ] && [ -s "$d/kldstat-v.txt" ] && ok "(f2) the guard listed before nvidia_drm passes the guard-order row, and kldstat -v is kept" || bad "(f2) guard-order with the good listing: '$(rowres "$d/results.jsonl" guard-order)'"
sh "$KIT/summarize.sh" "$d" > /dev/null 2>&1; [ $? -eq 0 ] || bad "(f2) summarize.sh does not pass a run whose unload order is right"
for v in bad:fail noguard:fail none:skip; do
	cp "$FAKE/kldv-${v%%:*}" "$FAKE/kldv"
	d=$(rc_run "order${v%%:*}" "$KIT/prime_import_testboot" "$FAKE/probe-good")
	[ "$(rowres "$d/results.jsonl" guard-order)" = "${v##*:} " ] && ok "(f2) unload order '${v%%:*}': the row is ${v##*:}" || bad "(f2) unload order '${v%%:*}': rows '$(rowres "$d/results.jsonl" guard-order)'"
	sh "$KIT/summarize.sh" "$d" > /dev/null 2>&1; [ $? -ne 0 ] && ok "(f2) summarize.sh does not pass a run with unload order '${v%%:*}'" || bad "(f2) summarize.sh passes a run with unload order '${v%%:*}'"
done
cp "$FAKE/kldv-good" "$FAKE/kldv"
_f="$TMPD/ctl-rc-order"
sed 's/elif \[ "\$gl" -lt "\$dl" \]; then/elif [ "$gl" -gt "$dl" ]; then/' "$KIT/prime_import_testboot" > "$_f"
if cmp -s "$KIT/prime_import_testboot" "$_f"; then
	bad "(f2) control reversed-order-check: the mutation changed nothing (stale test)"
else
	cp "$FAKE/kldv-bad" "$FAKE/kldv"
	_d=$(rc_run morder "$_f" "$FAKE/probe-good")
	[ "$(rowres "$_d/results.jsonl" guard-order)" = "pass " ] && ok "(f2) control: an order check that is reversed passes the bad listing, and is seen by the test above" || bad "(f2) control reversed-order-check: not seen"
	cp "$FAKE/kldv-good" "$FAKE/kldv"
fi
# the dead-man must really be pending: a timer that was requested but is not there is a fail row
touch "$FAKE/shutdown-refuse"
d=$(rc_run nopend "$KIT/prime_import_testboot" "$FAKE/probe-good")
rm -f "$FAKE/shutdown-refuse"
[ "$(rowres "$d/results.jsonl" deadman)" = "fail info " ] && ok "(f2) a dead-man timer that is not pending is one fail row, then the no-pid cancel row" || bad "(f2) not-pending dead-man rows: '$(rowres "$d/results.jsonl" deadman)'"
touch "$FAKE/noshutdown"
d=$(rc_run noshut "$KIT/prime_import_testboot" "$FAKE/probe-good")
rm -f "$FAKE/noshutdown"
[ "$(rowres "$d/results.jsonl" deadman)" = "fail info " ] && ok "(f2) a dead-man timer with the noshutdown lock is a fail row" || bad "(f2) noshutdown dead-man rows: '$(rowres "$d/results.jsonl" deadman)'"
touch "$FAKE/shutdown-refuse"
d=$(rc_run nocancel "$KIT/prime_import_testboot" "$FAKE/probe-good")
rm -f "$FAKE/shutdown-refuse"
grep '"row":"deadman"' "$d/results.jsonl" | tail -1 | grep -q 'no dead-man timer was found to cancel' && ok "(f2) a cancel that finds no timer says so, it does not claim success" || bad "(f2) cancel without a timer: '$(grep '"row":"deadman"' "$d/results.jsonl" | tail -1 | cut -c1-120)'"
# the sync after a running row is real: the sync count at the first probe falls by one without it
rm -f "$FAKE/sync.log" "$FAKE/sync-at-probe"; : > "$FAKE/sync.log"
d=$(rc_run syncgood "$KIT/prime_import_testboot" "$FAKE/probe-good")
_sg=$(cat "$FAKE/sync-at-probe" 2>/dev/null)
rm -f "$FAKE/sync.log" "$FAKE/sync-at-probe"; : > "$FAKE/sync.log"
sed '/^running()/,/^}/s/^\tsync$/\t:/' "$KIT/prime_import_testboot" > "$TMPD/ctl-rc-nosync"
if cmp -s "$KIT/prime_import_testboot" "$TMPD/ctl-rc-nosync"; then
	bad "(f2) control running-without-sync: the mutation changed nothing (stale test)"
else
	d=$(rc_run syncbad "$TMPD/ctl-rc-nosync" "$FAKE/probe-good")
	_sb=$(cat "$FAKE/sync-at-probe" 2>/dev/null)
	if [ -n "$_sg" ] && [ -n "$_sb" ] && [ "$_sb" -lt "$_sg" ]; then
		ok "(f2) control: a running() without its sync is seen (syncs at the first probe: $_sg, without: $_sb)"
	else
		bad "(f2) control running-without-sync: not seen ($_sg vs $_sb)"
	fi
fi
rm -f "$FAKE/sync-at-probe"
# the dead-man outlasts the bounded worst case of the run (the defaults, from the script itself)
_dm=$(sed -n 's/^: "${prime_import_testboot_deadman:=\([0-9]*\)}".*/\1/p' "$KIT/prime_import_testboot")
_pt=$(sed -n 's/^: "${prime_import_testboot_probe_timeout:=\([0-9]*\)}".*/\1/p' "$KIT/prime_import_testboot")
_lt=$(sed -n 's/^: "${prime_import_testboot_loop_timeout:=\([0-9]*\)}".*/\1/p' "$KIT/prime_import_testboot")
_lp=$(sed -n 's/^: "${prime_import_testboot_loops:=\([0-9]*\)}".*/\1/p' "$KIT/prime_import_testboot")
_cu=$(sed -n 's/.*timeout -k 5 \([0-9]*\) sh \$CUDARUN.*/\1/p' "$KIT/prime_import_testboot")
_vk=$(sed -n 's/.*timeout -k 5 \([0-9]*\) \$LINUXROOT.*vulkaninfo.*/\1/p' "$KIT/prime_import_testboot")
_worst=$(( (_pt + 5) + _lp * (_lt + 5) + (_pt + 5) + (_cu + 5) + (_vk + 5) ))
[ -n "$_cu" ] && [ -n "$_vk" ] || bad "(f2) the CUDA and Vulkan timeouts have no -k, or cannot be read from the script"
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
if [ "$(rowres "$d/results.jsonl" reverse)" = "running fail " ] && grep '"row":"reverse"' "$d/results.jsonl" | grep -q 'did not finish in 2 seconds'; then
	ok "(f2) a reverse probe that hangs is stopped and the row is a fail that says so"
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
	[ "$(rowres "$_d/results.jsonl" reverse)" = "running fail " ] && bad "(f2) control no-reverse-timeout: the mutant still reports the hang" || ok "(f2) control: a reverse probe without its timeout is seen"
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

# (guard) no path reaches /sbin/shutdown during host tests.  G1 is at the top,
# G2 is the final assertion, and every mutant below is confined to a sentinel
# (the PATH sentinel, the G3 sentinel copy, or never run at all).

# guard_bare <rc script>: the shared detector (tests/prime-import-testboot/bare-shutdown-check.sh)
# prints every line that calls shutdown by name; empty is clean.
guard_bare() {
	bare_shutdown_lines "$1"
}
# guard_static <rc script>: prints the name of the first rule it breaks and
# returns 1, or prints nothing and returns 0.
guard_static() {
	_gs=$1
	_gs_guard=$(sed -n '/^deadman_allowed()/,/^}/p' "$_gs")
	[ -n "$_gs_guard" ] || { echo guard-function; return 1; }
	[ -n "$(sed -n '/^dm_decide()/,/^}/p' "$_gs")" ] || { echo decide-function; return 1; }
	for _needle in 'id -u' 'autoboot' 'rc_fast' 'rc_arg' 'prime_import_testboot_marker' 'prime_import_testboot_bectl' 'list -H' '$_dm_be' '$_dm_marker' 'dm_decide'; do
		printf '%s\n' "$_gs_guard" | grep -qF "$_needle" || { echo "needle:$_needle"; return 1; }
	done
	[ "$(grep -cF '/sbin/shutdown' "$_gs")" -eq 1 ] || { echo literal-count; return 1; }
	grep -qF 'prime_import_testboot_real_shutdown=/sbin/shutdown' "$_gs" || { echo real-assignment; return 1; }
	grep -qF ': "${prime_import_testboot_shutdown:=$prime_import_testboot_real_shutdown}"' "$_gs" || { echo override-default; return 1; }
	if [ -n "$(guard_bare "$_gs")" ]; then echo bare; return 1; fi
	[ "$(grep -cF '"$prime_import_testboot_shutdown" -r' "$_gs")" -eq 1 ] || { echo call-count; return 1; }
	if grep -F '"$prime_import_testboot_shutdown" -r' "$_gs" | grep -qE '&[[:space:]]*$'; then echo background; return 1; fi
	_gs_deadman=$(sed -n '/^deadman_arm()/,/^prime_import_testboot_start()/p' "$_gs")
	[ -n "$_gs_deadman" ] || { echo deadman-section; return 1; }
	if printf '%s\n' "$_gs_deadman" | grep -qE 'pgrep|pkill'; then echo pkill; return 1; fi
	grep -qF 'dm_confirm "$_dm_pid" "$(id -u)"' "$_gs" || { echo confirm-arm; return 1; }
	grep -qF 'dm_confirm "$DM_CHILD" "$(id -u)"' "$_gs" || { echo confirm-cancel; return 1; }
	grep -qF 'kill "$DM_CHILD"' "$_gs" || { echo kill-exact; return 1; }
	return 0
}
_gs_out=$(guard_static "$KIT/prime_import_testboot")
if [ -z "$_gs_out" ]; then
	ok "(guard G4) fail-closed uid/boot(autoboot, rc_fast, rc_arg)/BE/marker checks, one quoted foreground call, no bare shutdown and exact-pid cancel are present"
else
	bad "(guard G4) the real rc script fails the static shutdown guard rule '$_gs_out'"
fi

# F3: dm_decide is pure; run it over a table of every single failure plus the all-true row.
# Fields: expected status | uid | autoboot | rc_fast | rc_arg | marker | current BE | refusal text must contain
dm_table_wrong() {	# dm_table_wrong <rc script>: the numbers of the table rows that give a wrong answer
	sed -n '/^dm_decide()/,/^}/p' "$1" > "$TMPD/dm-decide.sh"
	_w=
	_n=0
	while IFS='|' read -r _exp _u _ab _rf _ra _mk _be _want; do
		_n=$((_n + 1))
		_out=$( . "$TMPD/dm-decide.sh"; dm_decide "$_u" "$_ab" "$_rf" "$_ra" "$_mk" "$_be" )
		_rc=$?
		if [ "$_rc" != "$_exp" ]; then
			_w="$_w $_n"
		elif [ "$_exp" = 0 ] && [ -n "$_out" ]; then
			_w="$_w $_n"
		else
			case $_out in *"$_want"*) ;; *) _w="$_w $_n" ;; esac
		fi
	done <<'EOF'
0|0|yes|yes|start|BE1|BE1|
1|1001|yes|yes|start|BE1|BE1|uid 1001
1|0||yes|start|BE1|BE1|autoboot
1|0|no|yes|start|BE1|BE1|autoboot
1|0|yes||start|BE1|BE1|rc_fast
1|0|yes|no|start|BE1|BE1|rc_fast
1|0|yes|yes|stop|BE1|BE1|rc_arg
1|0|yes|yes||BE1|BE1|rc_arg
1|0|yes|yes|start||BE1|marker
1|0|yes|yes|start|BE1|BE2|does not match
1|0|yes|yes|start|BE1||no current
EOF
	printf '%s' "$_w"
}
_dtw=$(dm_table_wrong "$KIT/prime_import_testboot")
if [ -z "$_dtw" ]; then
	ok "(guard F3) dm_decide: the all-true row returns 0 and each of 10 single-condition failures is refused with its reason"
else
	bad "(guard F3) dm_decide table rows wrong:$_dtw"
fi
for _mv in uid:'s/^	if \[ "\$1" != 0 \]; then$/	if false; then/' \
    autoboot:'s/^	if \[ "\$2" != yes \]; then$/	if [ "$2" = yes ]; then/' \
    rc_fast:'s/^	if \[ "\$3" != yes \]; then$/	if false; then/' \
    be:'s/^	if \[ "\$6" != "\$5" \]; then$/	if false; then/'; do
	_mvn=${_mv%%:*}
	_mve=${_mv#*:}
	sed "$_mve" "$KIT/prime_import_testboot" > "$TMPD/mdm-$_mvn"
	if cmp -s "$KIT/prime_import_testboot" "$TMPD/mdm-$_mvn"; then
		bad "(guard F3) mutant $_mvn changed nothing (stale test)"
	elif [ -n "$(dm_table_wrong "$TMPD/mdm-$_mvn")" ]; then
		ok "(guard F3) control: mutant '$_mvn test removed' is seen as a wrong table row ($(dm_table_wrong "$TMPD/mdm-$_mvn" | tr -d ' ' | cut -c1-1) first)"
	else
		bad "(guard F3) mutant $_mvn gave the right table: not seen"
	fi
done

# G3: replace the one real-path literal with a second sentinel, then omit the
# override.  A non-root onestart must name uid refusal and make no sentinel hit.
G3_SAFE=0
_g3=$TMPD/g3-sentinel-rc
_real_count=$(grep -cF '/sbin/shutdown' "$KIT/prime_import_testboot")
sed "s|/sbin/shutdown|$SENT2/real-shutdown|" "$KIT/prime_import_testboot" > "$_g3"
_copy_count=$(grep -cF '/sbin/shutdown' "$_g3")
if [ "$_real_count" -eq 1 ] && [ "$_copy_count" -eq 0 ] && [ -x "$SENT2/real-shutdown" ] && [ ! -u "$SENT2/real-shutdown" ]; then
	G3_SAFE=1
	ok "(guard G3) the original has one real-path literal and the run copy has only the second sentinel"
else
	bad "(guard G3) unsafe sentinel substitution: original count $_real_count, copy count $_copy_count"
fi
if [ "$(id -u)" = 0 ]; then
	bad "(guard G3) refusal runtime requires the current user to be non-root"
elif [ "$G3_SAFE" = 1 ]; then
	rm -f "$SENT2/hits"
	d=$(RC_UNSET_SHUTDOWN=1 rc_run g3real "$_g3" "$FAKE/probe-good")
	if [ ! -e "$SENT2/hits" ] && [ -n "$d" ] && [ -f "$d/results.jsonl" ] &&
	    grep -q '"row":"deadman","result":"fail","detail":"REFUSED: not calling shutdown: uid .*this boot is NOT protected against a hang' "$d/results.jsonl"; then
		ok "(guard G3) the unset override is refused as non-root, names uid, says the boot is not protected, and never reaches the real-path sentinel"
	else
		bad "(guard G3) real-default refusal failed: hits=$(cat "$SENT2/hits" 2> /dev/null) rows=$(grep '"row":"deadman"' "$d/results.jsonl" 2> /dev/null)"
	fi
fi

# F1: at an rc boot (autoboot=yes) a stub override is ignored: the real conditions
# apply and the override program is never called.  Run on the G3 sentinel copy.
if [ "$(id -u)" = 0 ] || [ "$G3_SAFE" != 1 ]; then
	bad "(guard F1) needs a non-root user and a proven sentinel copy"
else
	rm -f "$SENT2/hits"
	d=$(RC_AUTOBOOT=yes rc_run f1boot "$_g3" "$FAKE/probe-good")
	if [ ! -s "$FAKE/dead-man.log" ] && [ ! -e "$SENT2/hits" ] && [ ! -s "$SENT/hits" ] &&
	    grep -q '"row":"deadman","result":"fail","detail":"REFUSED: not calling shutdown: uid ' "$d/results.jsonl"; then
		ok "(guard F1) with autoboot=yes the stub override is ignored: refused (uid), the stub and the real-path sentinel are not called"
	else
		bad "(guard F1) a stub override was honoured at an rc boot: stub log '$(cat "$FAKE/dead-man.log" 2> /dev/null)' rows $(grep '"row":"deadman"' "$d/results.jsonl" 2> /dev/null | head -1)"
	fi
	rm -f "$SENT2/hits"
	_mf1=$TMPD/mf1-honour-override
	sed 's/^	if \[ "\${autoboot:-}" != yes \] &&$/	if true \&\&/' "$_g3" > "$_mf1"
	if cmp -s "$_g3" "$_mf1"; then
		bad "(guard F1) mutant honouring the override at boot changed nothing (stale test)"
	else
		RC_AUTOBOOT=yes rc_run mf1 "$_mf1" "$FAKE/probe-good" > /dev/null
		if grep -q 'shutdown -r' "$FAKE/dead-man.log" 2> /dev/null; then
			ok "(guard F1) control: a mutant that honours the override at an rc boot is seen (the stub is called)"
		else
			bad "(guard F1) the override-at-boot mutant was not seen"
		fi
	fi
	rm -f "$SENT2/hits"
fi

# F4: with the lock file present, shutdown is not called at all (the stub log stays empty)
touch "$FAKE/noshutdown"
d=$(rc_run f4lock "$KIT/prime_import_testboot" "$FAKE/probe-good")
rm -f "$FAKE/noshutdown"
if [ ! -s "$FAKE/dead-man.log" ] && grep -q '"row":"deadman","result":"fail","detail":"the dead-man timer was requested but is not pending (the lock file .*shutdown was not called' "$d/results.jsonl"; then
	ok "(guard F4) with the lock file present shutdown is not called and the deadman row is fail"
else
	bad "(guard F4) the lock file case called shutdown or has the wrong row: log '$(cat "$FAKE/dead-man.log" 2> /dev/null)'"
fi

# G5/M1: a bare command must find only the PATH sentinel, and static checks fail.
# F11: the mutant is never run unless the sentinel dir is first in PATH with an executable shutdown.
_m1=$TMPD/m1-bare-shutdown
sed 's|^	"\$prime_import_testboot_shutdown" -r |	shutdown -r |' "$KIT/prime_import_testboot" > "$_m1"
if cmp -s "$KIT/prime_import_testboot" "$_m1"; then
	bad "(guard G5) M1 mutation changed nothing"
elif [ "${PATH%%:*}" != "$SENT" ] || [ ! -x "$SENT/shutdown" ] || [ -u "$SENT/shutdown" ]; then
	bad "(guard F11) M1 not run: the PATH sentinel dir is not first in PATH with an executable shutdown"
else
	_m1_static=$(guard_static "$_m1")
	rm -f "$SENT/hits"
	rc_run m1 "$_m1" "$FAKE/probe-good" > /dev/null
	if [ "$_m1_static" = bare ] && [ -s "$SENT/hits" ] && grep -q '^REACHED ' "$SENT/hits" && grep -qF -- '-r +60' "$SENT/hits"; then
		ok "(guard G5) control: mutant M1 is seen (bare call hits only the PATH sentinel; static rule '$_m1_static')"
	else
		bad "(guard G5) M1 was not seen: static='$_m1_static' hits=$(cat "$SENT/hits" 2> /dev/null)"
	fi
fi
rm -f "$SENT/hits"

# G5/M2: with the refusal call removed, the already-substituted G3 copy must
# hit its second sentinel.  It can never name the host's real shutdown.
_m2=$TMPD/m2-no-refusal
sed 's/^	if ! deadman_allowed; then$/	if false; then/' "$_g3" > "$_m2"
if cmp -s "$_g3" "$_m2" || cmp -s "$KIT/prime_import_testboot" "$_m2"; then
	bad "(guard G5) M2 mutation changed nothing"
elif [ "$G3_SAFE" != 1 ]; then
	bad "(guard G5) M2 was not run because G3's sentinel substitution was not proven safe"
else
	rm -f "$SENT2/hits"
	RC_UNSET_SHUTDOWN=1 rc_run m2 "$_m2" "$FAKE/probe-good" > /dev/null
	if [ -s "$SENT2/hits" ] && grep -q '^REAL REACHED ' "$SENT2/hits"; then
		ok "(guard G5) control: mutant M2 is seen (guard removal hits only the second sentinel)"
	else
		bad "(guard G5) M2 was not seen"
	fi
fi
rm -f "$SENT2/hits"

# G5/M3: pattern cancellation is rejected by the same G4 static guard, and only by its pkill rule
# (the mutant is built from the original, so no other rule can fire).
_m3=$TMPD/m3-pattern-cancel
sed '/^deadman_cancel()$/{n;s/^{$/{\
	pkill -f "prime_import_testboot dead-man"/;}' "$KIT/prime_import_testboot" > "$_m3"
if cmp -s "$KIT/prime_import_testboot" "$_m3"; then
	bad "(guard G5) M3 mutation changed nothing"
else
	_m3_static=$(guard_static "$_m3")
	if [ "$_m3_static" = pkill ]; then
		ok "(guard G5) control: mutant M3 is seen (pattern cancellation fails only the pkill rule of G4)"
	else
		bad "(guard G5) M3 was not seen by the pkill rule alone: rule '$_m3_static'"
	fi
fi

# G5/M4 (F5): the call rewritten behind an if ! is a bare call.  Never run: only the detector looks at it.
_m4=$TMPD/m4-if-bare
sed 's|^	"\$prime_import_testboot_shutdown" -r .*$|	if ! shutdown -r "+$prime_import_testboot_deadman" "m"; then :; fi|' "$KIT/prime_import_testboot" > "$_m4"
if cmp -s "$KIT/prime_import_testboot" "$_m4"; then
	bad "(guard G5) M4 mutation changed nothing"
elif [ "$(guard_static "$_m4")" = bare ]; then
	ok "(guard G5) control: mutant M4 (if ! shutdown -r ...) is seen by the bare-call detector"
else
	bad "(guard G5) M4 was not seen as a bare call: rule '$(guard_static "$_m4")'"
fi

# G3 (FIX3): stub overrides that are not an absolute, executable, non-setuid file are
# not honoured.  Each runs through the sentinel copy of the rc as non-root with onestart:
# the REFUSED row, an empty stub log and no sentinel hit are expected.
_g3_setuid=$TMPD/prime-shutdown-setuid-stub
cp "$TMPD/prime-shutdown-stub" "$_g3_setuid"
chmod 4755 "$_g3_setuid"
if [ "$(id -u)" = 0 ] || [ "$G3_SAFE" != 1 ]; then
	bad "(guard G3) override cases need a non-root user and a proven sentinel copy"
elif [ ! -u "$_g3_setuid" ]; then
	bad "(guard G3) the setuid stub copy is not setuid (stale test)"
else
	for _ov in true:true relative:prime-shutdown-stub setuid:"$_g3_setuid"; do
		_ovn=${_ov%%:*}
		_ovv=${_ov#*:}
		rm -f "$SENT/hits" "$SENT2/hits"
		d=$(cd "$TMPD" && RC_STUB="$_ovv" rc_run "g3ov$_ovn" "$_g3" "$FAKE/probe-good")
		if [ -n "$d" ] && [ ! -s "$FAKE/dead-man.log" ] && [ ! -e "$SENT2/hits" ] && [ ! -e "$SENT/hits" ] &&
		    grep -q '"row":"deadman","result":"fail","detail":"REFUSED: not calling shutdown: uid ' "$d/results.jsonl"; then
			ok "(guard G3) the $_ovn override is refused: REFUSED row, empty stub log, no sentinel hit"
		else
			bad "(guard G3) the $_ovn override was not refused: log '$(cat "$FAKE/dead-man.log" 2> /dev/null)' rows $(grep '"row":"deadman"' "$d/results.jsonl" 2> /dev/null | head -1)"
		fi
	done
fi
rm -f "$SENT/hits" "$SENT2/hits"

# G1 (FIX3) control: the shared detector must not flag the clean rc script, comments,
# the allowlisted lines or row/echo messages that carry the word shutdown.
_bc=$TMPD/bare-clean
cp "$KIT/prime_import_testboot" "$_bc"
printf '%s\n' '# shutdown -r now is only a comment' 'row t pass "shutdown -r now in a message"' 'echo "shutdown now"' >> "$_bc"
if [ -z "$(bare_shutdown_lines "$_bc")" ] && [ -z "$(bare_shutdown_lines "$KIT/prime_import_testboot")" ]; then
	ok "(guard G1) control: the clean rc, comments, the allowlisted lines and row/echo messages are not flagged"
else
	bad "(guard G1) the bare detector flags clean text: $(bare_shutdown_lines "$_bc" | head -3)"
fi

# G5/M6 and M7: quoted shells are bare calls too.  Never run: only the detector looks at them.
for _mq in m6:'sh -c "shutdown -r now"' m7:"eval 'shutdown -r now'"; do
	_mqn=${_mq%%:*}
	_mqt=$TMPD/$_mqn-quoted-bare
	cp "$KIT/prime_import_testboot" "$_mqt"
	printf '%s\n' "${_mq#*:}" >> "$_mqt"
	if cmp -s "$KIT/prime_import_testboot" "$_mqt"; then
		bad "(guard G5) $_mqn mutation changed nothing"
	elif [ "$(guard_static "$_mqt")" = bare ] && [ -n "$(bare_shutdown_lines "$_mqt")" ]; then
		ok "(guard G5) control: mutant $_mqn (${_mq#*:}) is seen by the bare-call detector"
	else
		bad "(guard G5) $_mqn was not seen as a bare call: rule '$(guard_static "$_mqt")'"
	fi
done

# G5/M8: a mutant of the shared detector file itself (it reports nothing) must make
# the M6 line pass unseen, which the test then reports as the control being seen.
_m8=$TMPD/m8-detector
sed "s/grep -nE '.*\$/grep -nE 'ZZZNEVERZZZ'/" "$KIT/bare-shutdown-check.sh" > "$_m8"
if cmp -s "$KIT/bare-shutdown-check.sh" "$_m8"; then
	bad "(guard G5) M8 mutation changed nothing"
else
	_m8out=$( . "$_m8"; bare_shutdown_lines "$TMPD/m6-quoted-bare" )
	if [ -z "$_m8out" ]; then
		ok "(guard G5) control: mutant M8 (broken shared detector) misses M6, so the M6 check above would fail"
	else
		bad "(guard G5) M8 detector still sees M6: $_m8out"
	fi
fi

# G6: a fake make-be run writes the clone's own BE name into a 0444 marker.
make_be_no_shutdown() {
	if grep -nE '^[[:space:]]*(/sbin/)?shutdown([[:space:]]|$)' "$1" > /dev/null; then return 1; fi
	return 0
}
out=$(run_be "$KIT/make-be.sh" -b base -D 20261120 -n 12 -m "$TMPD/mods"); rc=$?
_g6be=nvidia-prime-import-test-20261120-12
_g6marker=$TMPD/mnt/usr/local/etc/prime_import_testboot.marker
if [ "$rc" -eq 0 ] && [ "$(cat "$_g6marker" 2> /dev/null)" = "$_g6be" ] &&
    [ "$(stat -f %Lp "$_g6marker" 2> /dev/null)" = 444 ] && make_be_no_shutdown "$KIT/make-be.sh"; then
	ok "(guard G6) make-be writes the BE marker as 0444 and contains no shutdown command"
else
	bad "(guard G6) marker content/mode or make-be command check failed (rc=$rc)"
fi
_g6cmd=$TMPD/g6-make-command-mutant
cp "$KIT/make-be.sh" "$_g6cmd"
printf 'shutdown -r now\n' >> "$_g6cmd"
if cmp -s "$KIT/make-be.sh" "$_g6cmd"; then
	bad "(guard G6) command mutant changed nothing"
elif make_be_no_shutdown "$_g6cmd"; then
	bad "(guard G6) a planted shutdown command was not seen"
else
	ok "(guard G6) control: a planted shutdown command is seen without running the mutant"
fi
_g6kit=$TMPD/g6kit
mkdir -p "$_g6kit"
cp "$KIT"/* "$_g6kit/"
_g6mark=$_g6kit/make-be.sh
sed 's/"\$BE" > "\$MNT\/usr\/local\/etc\/prime_import_testboot.marker"/"\$BASE" > "\$MNT\/usr\/local\/etc\/prime_import_testboot.marker"/' "$KIT/make-be.sh" > "$_g6mark"
if cmp -s "$KIT/make-be.sh" "$_g6mark"; then
	bad "(guard G6) marker mutant changed nothing"
else
	run_be "$_g6mark" -b base -D 20261120 -n 12 -m "$TMPD/mods" > /dev/null 2>&1
	if [ "$(cat "$_g6marker" 2> /dev/null)" = base ] && [ "$(cat "$_g6marker" 2> /dev/null)" != "$_g6be" ]; then
		ok "(guard G6) control: a marker containing the wrong BE is seen"
	else
		bad "(guard G6) wrong-BE marker mutant was not seen"
	fi
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

if [ ! -s "$SENT/hits" ]; then
	ok "(guard G2) no rc run or mutant reached the PATH shutdown sentinel after its M1 control was cleared"
else
	bad "(guard G2) the PATH shutdown sentinel was reached: $(cat "$SENT/hits")"
fi

echo "passed: $passed failed: $failed"
[ "$failed" -eq 0 ]

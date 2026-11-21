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
# bectl mount <be> <dir>: the base BE's files, when the test provides some
if [ "$1" = mount ] && [ -n "${FAKE_BASE_DIR:-}" ]; then cp -R "$FAKE_BASE_DIR/." "$3/"; fi
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

# run_be <script> <args...>: run a make-be.sh against the fake bectl
run_be() {
	_s=$1
	shift
	rm -rf "${TMPD:?}/mnt"
	: > "$TMPD/bectl.log"
	PRIME_ALLOW_DIRTY="${PRIME_ALLOW_DIRTY_OVERRIDE-1}" FAKE_BECTL_FAIL="${FAKE_BECTL_FAIL:-none}" FAKE_BASE_DIR="${FAKE_BASE_DIR:-}" FAKE_BECTL_LOG="$TMPD/bectl.log" BECTL="$TMPD/fake-bectl" PRIME_MNT="$TMPD/mnt" GB10_WORK="$WORK" \
	    sh "$_s" "$@" 2>&1
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
# the kit that boots comes from a committed state: a dirty git work tree is refused, a clean one is recorded, an archive needs -V
rm -rf "$TMPD/gitkit"; mkdir -p "$TMPD/gitkit"; cp "$KIT"/* "$TMPD/gitkit/"
( cd "$TMPD/gitkit" && git init -q . && git add -A . && git -c core.hooksPath=/dev/null -c user.name=t -c user.email=t@t commit -q --no-verify -m kit ) > /dev/null 2>&1
gsha=$(git -C "$TMPD/gitkit" rev-parse --verify HEAD 2>/dev/null)
case $gsha in ''|*[!0-9a-f]*) bad "(d) the test could not make a git repository of the kit to commit in" ;; esac
out=$(PRIME_ALLOW_DIRTY_OVERRIDE=0 run_be "$TMPD/gitkit/make-be.sh" -b base -D 20261120 -n 2 -m "$TMPD/mods"); rc=$?
if [ "$rc" -eq 0 ] && [ "$(cat "$TMPD/mnt/usr/local/etc/prime_import_testboot.version" 2>/dev/null)" = "$gsha" ]; then
	ok "(d) a clean git work tree builds the BE and records its HEAD"
else
	bad "(d) a clean git work tree: rc=$rc version='$(cat "$TMPD/mnt/usr/local/etc/prime_import_testboot.version" 2>/dev/null)' want '$gsha' $out"
fi
echo "# changed" >> "$TMPD/gitkit/make-be.sh"
out=$(PRIME_ALLOW_DIRTY_OVERRIDE=0 run_be "$TMPD/gitkit/make-be.sh" -b base -D 20261120 -n 2 -m "$TMPD/mods"); rc=$?
case $out in *"uncommitted changes"*) [ "$rc" -eq 2 ] && ok "(d) a dirty git work tree is refused (exit 2)" || bad "(d) a dirty tree is refused with rc=$rc" ;; *) bad "(d) a dirty git work tree builds a BE: rc=$rc" ;; esac
git -C "$TMPD/gitkit" checkout -q -- make-be.sh 2>/dev/null
rm -rf "$TMPD/archkit"; mkdir -p "$TMPD/archkit"; cp "$KIT"/* "$TMPD/archkit/"
out=$(PRIME_ALLOW_DIRTY_OVERRIDE=0 run_be "$TMPD/archkit/make-be.sh" -b base -D 20261120 -n 2 -m "$TMPD/mods"); rc=$?
[ "$rc" -eq 2 ] && ok "(d) a kit that is not in a git work tree needs -V" || bad "(d) an extracted kit without -V built a BE: rc=$rc"
out=$(PRIME_ALLOW_DIRTY_OVERRIDE=0 run_be "$TMPD/archkit/make-be.sh" -b base -D 20261120 -n 2 -m "$TMPD/mods" -V 0123abc); rc=$?
[ "$rc" -eq 0 ] && [ "$(cat "$TMPD/mnt/usr/local/etc/prime_import_testboot.version" 2>/dev/null)" = 0123abc ] && ok "(d) an extracted kit with -V records the named commit" || bad "(d) -V: rc=$rc $out"
out=$(PRIME_ALLOW_DIRTY_OVERRIDE=0 run_be "$TMPD/archkit/make-be.sh" -b base -D 20261120 -n 2 -m "$TMPD/mods" -V 'not hex'); rc=$?
[ "$rc" -eq 2 ] && ok "(d) a -V that is not hex is refused" || bad "(d) -V not hex rc=$rc"
echo "# changed" >> "$TMPD/gitkit/make-be.sh"
sed '/^	if \[ -n "\$(git -C "\$KITDIR" status --porcelain/s/.*/	if false; then/' "$KIT/make-be.sh" > "$TMPD/gitkit/make-be.sh"
cp "$KIT/prime_import_testboot" "$TMPD/gitkit/" ; echo "# dirty" >> "$TMPD/gitkit/prime_import_testboot"
if cmp -s "$KIT/make-be.sh" "$TMPD/gitkit/make-be.sh"; then bad "(d) control dirty-check: the mutation changed nothing (stale test)"; else
	out=$(PRIME_ALLOW_DIRTY_OVERRIDE=0 run_be "$TMPD/gitkit/make-be.sh" -b base -D 20261120 -n 2 -m "$TMPD/mods"); rc=$?
	[ "$rc" -eq 0 ] && ok "(d) control: a make-be.sh without the dirty check builds from a dirty tree, and the test above sees it" || bad "(d) control dirty-check: not seen ($rc)"
fi
PRIME_ALLOW_DIRTY=1 sh "$KIT/make-be.sh" > "$TMPD/nob.out" 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok "(d) make-be.sh without -b exits 2" || bad "(d) make-be.sh without -b rc=$rc"
out=$(PRIME_ALLOW_DIRTY=1 sh "$KIT/make-be.sh" -b base -D 20261120 -n 3 --dry-run 2>&1)
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

# (e) forbidden commands anywhere in the kit
common='kldunload|kldload|devctl|acpiconf|zzz|[^a-z_]reboot|shutdown|halt -|bectl[[:space:]]+destroy'
scan() {	# scan <file>: forbidden commands, comments excluded
	grep -nE "$common|bectl[[:space:]]+activate" "$1" | grep -v '^[0-9]*:[[:space:]]*#' | grep -vE '^[0-9]+:[[:space:]]+shutdown -r "\+\$prime_import_testboot_deadman" "prime_import_testboot dead-man: [^"]*" > /dev/null 2>&1 &$' | grep -vE '^[0-9]+::[[:space:]]"\$\{prime_import_testboot_lockfile:=/var/run/noshutdown\}"$' | grep -vE '^[0-9]+:[[:space:]]+if pkill -f "prime_import_testboot dead-man" > /dev/null 2>&1; then$'
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
for t in kldstat dmesg bectl sync; do
	printf '#!/bin/sh\ncase "$0" in *kldstat) if [ "$1" = -v ]; then cat "%s/kldv" 2>/dev/null; else echo "nvidia-drm.ko amdgpu.ko"; fi;; *sync) echo s >> "%s/sync.log";; esac\nexit 0\n' "$FAKE" "$FAKE" > "$FAKE/bin/$t"
done
# a fake process table: pgrep -f and pkill -f match their pattern against the command lines in it (the rc script's
# own command line is always there, as on the box), and a restart request that is not refused adds its own line
printf '#!/bin/sh\n[ "$1" = -f ] || exit 2\ngrep -Eq -- "$2" "%s/ptable"\n' "$FAKE" > "$FAKE/bin/pgrep"
printf '#!/bin/sh\necho "$0 $*" >> "%s/dead-man.log"\n[ "$1" = -f ] || exit 2\ngrep -Eq -- "$2" "%s/ptable" || exit 1\ngrep -Ev -- "$2" "%s/ptable" > "%s/ptable.new"\nmv "%s/ptable.new" "%s/ptable"\nexit 0\n' "$FAKE" "$FAKE" "$FAKE" "$FAKE" "$FAKE" "$FAKE" > "$FAKE/bin/pkill"
printf '#!/bin/sh\necho "$0 $*" >> "%s/dead-man.log"\n[ -e "%s/shutdown-refuse" ] && exit 0\necho "shutdown $*" >> "%s/ptable"\nexit 0\n' "$FAKE" "$FAKE" "$FAKE" > "$FAKE/bin/shutdown"
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
# rc_run <name> <rc script> <probe>: run the one-shot, print its run directory
rc_run() {
	_n=$1; _rc=$2; _pr=$3
	rm -rf "$FAKE/logs-$_n"; mkdir -p "$FAKE/logs-$_n"
	printf '/usr/sbin/sshd\nsh %s onestart\n' "$_rc" > "$FAKE/ptable"
	env PATH="$FAKE/bin:$PATH" prime_import_testboot_logroot="$FAKE/logs-$_n" \
	    prime_import_testboot_probe="$_pr" prime_import_testboot_log="$FAKE/rc-$_n.log" \
	    prime_import_testboot_src=/dev/null prime_import_testboot_dst=/dev/null \
	    prime_import_testboot_loops=4 prime_import_testboot_probe_timeout=${RC_PROBE_TIMEOUT:-60} prime_import_testboot_loop_timeout=${RC_LOOP_TIMEOUT:-20} prime_import_testboot_deadman=${RC_DEADMAN:-60} prime_import_testboot_lockfile="$FAKE/noshutdown" prime_import_testboot_version="$FAKE/version" prime_import_testboot_linuxroot="$FAKE/none" \
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

# the dead-man reboot: armed before the first probe, cancelled at the done row, off at 0
d=$(rc_run good "$KIT/prime_import_testboot" "$FAKE/probe-good")
if grep -q 'shutdown -r +60' "$FAKE/dead-man.log" 2>/dev/null; then
	ok "(f2) the dead-man timer is armed for 60 minutes"
else
	bad "(f2) no dead-man reboot was armed: $(cat "$FAKE/dead-man.log" 2>/dev/null)"
fi
grep -q 'pkill -f prime_import_testboot dead-man' "$FAKE/dead-man.log" 2>/dev/null && ok "(f2) only this script's dead-man timer is cancelled (by its own message), at the end of a finished run" || bad "(f2) the dead-man reboot is not cancelled"
case $(rowres "$d/results.jsonl" deadman) in "info info ") ok "(f2) the arm and the cancel are both recorded" ;; *) bad "(f2) deadman rows: '$(rowres "$d/results.jsonl" deadman)'" ;; esac
[ "$(grep -c 'dead-man' "$KIT/prime_import_testboot")" -ge 2 ] && [ "$(grep -c '^[[:space:]]*shutdown ' "$KIT/prime_import_testboot")" -eq 1 ] && ok "(f2) the rc script has exactly one shutdown, the dead-man" || bad "(f2) the rc script has another shutdown"
rm -f "$FAKE/dead-man.log"
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
[ "$(rowres "$d/results.jsonl" deadman | cut -d' ' -f2)" = "fail" ] && ok "(f2) a dead-man timer that is not pending is a fail row" || bad "(f2) not-pending dead-man rows: '$(rowres "$d/results.jsonl" deadman)'"
touch "$FAKE/noshutdown"
d=$(rc_run noshut "$KIT/prime_import_testboot" "$FAKE/probe-good")
rm -f "$FAKE/noshutdown"
[ "$(rowres "$d/results.jsonl" deadman | cut -d' ' -f2)" = "fail" ] && ok "(f2) a dead-man timer that shutdown refuses (noshutdown) is a fail row" || bad "(f2) noshutdown dead-man rows: '$(rowres "$d/results.jsonl" deadman)'"
touch "$FAKE/shutdown-refuse"
d=$(rc_run nocancel "$KIT/prime_import_testboot" "$FAKE/probe-good")
rm -f "$FAKE/shutdown-refuse"
grep '"row":"deadman"' "$d/results.jsonl" | tail -1 | grep -q 'no dead-man timer was found to cancel' && ok "(f2) a cancel that finds no timer says so, it does not claim success" || bad "(f2) cancel without a timer: '$(grep '"row":"deadman"' "$d/results.jsonl" | tail -1 | cut -c1-120)'"
# a finished run leaves the rc script alone and the dead-man gone (the cancel pattern is this script's, not a substring of every line)
d=$(rc_run ptfinal "$KIT/prime_import_testboot" "$FAKE/probe-good")
if grep -q 'prime_import_testboot onestart' "$FAKE/ptable" && ! grep -q 'dead-man' "$FAKE/ptable" && grep -q sshd "$FAKE/ptable"; then
	ok "(f2) the cancel removed the dead-man timer and nothing else (not the rc script itself, not other processes)"
else
	bad "(f2) the process table after the cancel: $(tr '\n' '|' < "$FAKE/ptable")"
fi
	mkdir -p "$TMPD/ctl-pg"; _f="$TMPD/ctl-pg/prime_import_testboot"
	sed 's/pgrep -f "prime_import_testboot dead-man"/pgrep -f "prime_import_testboot"/' "$KIT/prime_import_testboot" > "$_f"
	if cmp -s "$KIT/prime_import_testboot" "$_f"; then bad "(f2) control pgrep-pattern: the mutation changed nothing (stale test)"; else
		touch "$FAKE/shutdown-refuse"
		_d=$(rc_run mpgrep "$_f" "$FAKE/probe-good")
		rm -f "$FAKE/shutdown-refuse"
		[ "$(rowres "$_d/results.jsonl" deadman | cut -d' ' -f2)" = "fail" ] && bad "(f2) control pgrep-pattern: a pending check that matches the rc script itself was not seen" || ok "(f2) control: a pending check whose pattern matches the rc script itself never fails, and the test above sees it"
	fi
mkdir -p "$TMPD/ctl-pk"; _f="$TMPD/ctl-pk/prime_import_testboot"
sed 's/pkill -f "prime_import_testboot dead-man"/pkill -f "prime_import_testboot"/' "$KIT/prime_import_testboot" > "$_f"
if cmp -s "$KIT/prime_import_testboot" "$_f"; then bad "(f2) control pkill-pattern: the mutation changed nothing (stale test)"; else
	_d=$(rc_run mpkill "$_f" "$FAKE/probe-good")
	grep -q 'prime_import_testboot onestart' "$FAKE/ptable" && bad "(f2) control pkill-pattern: a cancel that kills the rc script itself was not seen" || ok "(f2) control: a cancel pattern that matches the rc script itself is seen (it removes the script from the table)"
fi
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

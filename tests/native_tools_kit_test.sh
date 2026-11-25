#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-2-Clause
#
# native_tools_kit_test.sh - the native-tools test-boot kit (tests/native-tools-testboot/, Track #2362) is sound
# without a boot:
#   (a) guard_env: a listing with a linux module (linux64, nvidia_linux.ko without linux64, linuxkpi) fails; a
#       compat.linux that answers fails; a kldstat that failed, printed nothing or lacks kernel or a required file is
#       an error; a sysctl failure that is not "unknown oid" is an error; a clean listing passes; guard_env_delta finds
#       a module that appeared; the capture of the 2026-11-23 boot fails, and the failure names the loader it can see
#       (the loader list, an rc.d service with required_modules, devd) and points at check-be.sh; it names no service
#       when it cannot see one; guard_rc_loaders names that service and that devd rule (and stops naming them when
#       the probe only probes), resolves the rcvar built from the name of the script and the defaults of the script,
#       and reports a service it cannot read as unknown; guard_rc_expand keeps the default of ${var-default}; the
#       defaults of a script and the rc.conf are read with the same rule; a service that its own script enables is
#       enabled; a devd rule that starts a service which loads a driver is a loader too; the summary of the capture
#       has the layout summarize.py writes today;
#   (b) guard_brand: /bin/sh passes, a #! script passes, a copy of /bin/echo branded Linux fails, a text file fails, a
#       missing file is an error;
#   (c) guard_trace on real ktrace runs: a script that runs the Linux-branded copy by absolute path (not declared
#       anywhere) fails; a clean script passes; a trace without the tool is an error; an empty trace is an error; a
#       kldload call in the trace fails;
#   (d) summarize.py: a run with skipped rows is incomplete, a failed row is fail, a missing done row is fail, a row
#       left running is an error, a fully passing run is pass, a planned row never written with no earlier failure is
#       an error; summary.json validates against native-tools-summary.schema.json, and a planted wrong status is
#       refused;
#   (e) make-be.sh with the test hooks and a fake clone: amdgpu and linux64 are stripped from kld_list, linux_enable
#       becomes NO, devmatch_blocklist is set in rc.conf and loader.conf, the staged files are installed, the static
#       rows are written; the enabled rc.d service whose required_modules loads amdgpu (drm_ready) is turned off, the
#       service whose rcvar is built from its name is turned off too, a service that cannot be read is refused, the
#       hwprobe service gets the command probe (and the base is refused when another rc.conf file sets it back), a base
#       with a devd rule that starts a service which loads a driver is refused, the
#       owner of the run directory is recorded (and refused when it is not a user of the boot environment), a
#       copy-out whose parent is owned by root is refused; a base whose loader.conf loads linux is refused; an existing
#       BE name is refused with the next free number; check-be.sh -m -U on the fake clone passes every check but the
#       commit comparison, and refuses a clone with drm_ready enabled, with a service it cannot read, with a devd rule
#       that loads a driver or starts a service which loads one, or with the hwprobe command apply (naming the service
#       and the module);
#   (f) the rc one-shot, run in the foreground with stubbed system commands: the rows come out in order, env-before
#       and env-loaded pass, nvrm-info-native passes (the real nvrm-info, traced), the static rows carry their status,
#       testboot-return is called last, the run is copied out and given to the recorded owner (0700, the files 0600);
#       the hand-over of the copy (own_run) gives away only the files of the run, leaves a planted link alone and says
#       which directory it could not give away;
#   (g) every script is valid sh; the rc script (comments left out) has no kldload of a linux module, no kldunload
#       and no bectl activate; the README states the rule of the guard, not the history of the change.
# (e) and (f) make a stage in the test scratch directory, from NVNT_STAGE when set, else by building the modules from
# this checkout (with the already-built RM cores) and building libnvrm/nvrm-info in scratch.  Real Linux-dependent
# control modules are optional: NVNT_PHASE0_KO, NVNT_UVM_KO and NVNT_DRM_KO.  Their absence prints a named skip;
# synthetic plants keep the rules tested.
# Run: sh tests/native_tools_kit_test.sh   (no root; writes only under $GB10_WORK/tmp)

set -u
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
KIT=$repo/tests/native-tools-testboot
. "$repo/tests/libnvrm/board-amp001.env"
WORK=${GB10_WORK:-$repo/work}
mkdir -p "$WORK/tmp"
T=$(mktemp -d "$WORK/tmp/nvnt-kit.XXXXXX") || exit 2

# (guard) no path reaches /sbin/shutdown during host tests.  G1: these sentinels and the override exist before any kit code runs.
SENT=$T/sentinel
SENT2=$T/sentinel-real
mkdir -p "$SENT/shutdown-child" "$SENT2"
cat > "$SENT/shutdown" <<EOF
#!/bin/sh
printf 'REACHED %s %s\n' "\$0" "\$*" >> "$SENT/hits"
exit 99
EOF
cat > "$SENT2/real-shutdown" <<EOF
#!/bin/sh
printf 'REAL REACHED %s\n' "\$*" >> "$SENT2/hits"
exit 99
EOF
cp /bin/sleep "$SENT/shutdown-child/shutdown"
nvidia_native_tools_testboot_shutdown=$T/shutdown-stub
cat > "$nvidia_native_tools_testboot_shutdown" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$T/shutdown-args"
"$SENT/shutdown-child/shutdown" 300 &
_child=\$!
printf '%s\n' "\$_child" >> "$T/shutdown-children"
# F6: the pid is not printed until the child is a process named shutdown (the fork has exec'd); a bounded poll on ps, no sleep
_i=0
while [ "\$(ps -o comm= -p "\$_child" 2> /dev/null | tr -d ' ')" != shutdown ]; do
	_i=\$((_i + 1))
	[ "\$_i" -lt 2000 ] || exit 1
done
printf 'shutdown: [pid %s]\n' "\$_child"
exit 0
EOF
chmod 0755 "$SENT/shutdown" "$SENT2/real-shutdown" "$nvidia_native_tools_testboot_shutdown"
PATH=$SENT:/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
export PATH nvidia_native_tools_testboot_shutdown
DM_DECOY=
reap_stub_children() {
	[ ! -f "$T/shutdown-children" ] || while IFS= read -r _child; do
		case $_child in '' | *[!0-9]*) continue ;; esac
		[ "$(ps -o uid= -o comm= -p "$_child" 2> /dev/null | tr -d ' ')" = "$(id -u)shutdown" ] && kill "$_child" 2> /dev/null || :
	done < "$T/shutdown-children"
	[ ! -e "$T/shutdown-children" ] || : > "$T/shutdown-children"
}
cleanup() {
	reap_stub_children
	case $DM_DECOY in '' | *[!0-9]*) ;; *) kill "$DM_DECOY" 2> /dev/null || :; wait "$DM_DECOY" 2> /dev/null || : ;; esac
	DM_DECOY=
	rm -rf "$T"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if [ -z "$nvidia_native_tools_testboot_shutdown" ] || [ "$nvidia_native_tools_testboot_shutdown" = /sbin/shutdown ]; then
	echo "guard: the harness left nvidia_native_tools_testboot_shutdown at /sbin/shutdown" >&2
	exit 1
fi
if [ ! -f "$nvidia_native_tools_testboot_shutdown" ] || [ ! -x "$nvidia_native_tools_testboot_shutdown" ] || [ -u "$nvidia_native_tools_testboot_shutdown" ]; then
	echo "guard: the nvidia_native_tools_testboot_shutdown stub is not a non-setuid executable file" >&2
	exit 1
fi
if [ "$(id -u)" = 0 ]; then
	echo "guard: the host-only test must run as the current non-root user" >&2
	exit 1
fi
STAGE=$T/stage
SHAFILE=$STAGE/SHA256.txt
pass=0; fail=0
ok() { pass=$((pass + 1)); echo "ok   $*"; }
no() { fail=$((fail + 1)); echo "FAIL $*"; }
skip() { echo "skip $1: $2 not set ($3)"; }
ok "G1 sentinels are first in PATH and the exported shutdown override is a non-setuid executable stub"
expect() {	# expect <want status> <got status> <what>
	if [ "$1" = "$2" ]; then ok "$3"; else no "$3 (exit $2, wanted $1)"; fi
}
. "$KIT/bare-shutdown-check.sh"	# the one detector, shared with check-be.sh: bare_shutdown_lines FILE prints the offending lines
bare_shutdown() {	# bare_shutdown <rc file>: 0 when the file calls shutdown other than through the guarded variable
	[ -n "$(bare_shutdown_lines "$1")" ]
}
guard_static() {	# guard_static <rc copy> <reason log>: the G4 static contract, without running the file
	_gs_file=$1; _gs_log=$2; _gs_bad=0
	: > "$_gs_log"
	_gs_guard=$(sed -n '/^deadman_allowed()/,/^}/p' "$_gs_file")
	_gs_dec=$(sed -n '/^dm_decide()/,/^}/p' "$_gs_file")
	_gs_both=$(printf '%s\n%s\n' "$_gs_dec" "$_gs_guard")
	[ -n "$_gs_guard" ] || { echo "deadman_allowed is missing" >> "$_gs_log"; _gs_bad=1; }
	[ -n "$_gs_dec" ] || { echo "dm_decide is missing" >> "$_gs_log"; _gs_bad=1; }
	printf '%s\n' "$_gs_guard" | grep -qF 'dm_decide' || { echo "deadman_allowed does not call dm_decide" >> "$_gs_log"; _gs_bad=1; }
	printf '%s\n' "$_gs_guard" | grep -qF 'id -u' || { echo "deadman_allowed lacks id -u" >> "$_gs_log"; _gs_bad=1; }
	for _gs_needle in autoboot rc_fast rc_arg nvidia_native_tools_testboot_marker; do
		printf '%s\n' "$_gs_both" | grep -qF "$_gs_needle" || { echo "the guard lacks $_gs_needle" >> "$_gs_log"; _gs_bad=1; }
	done
	printf '%s\n' "$_gs_guard" | grep -q 'nvidia_native_tools_testboot_bectl.*list -H' || { echo "deadman_allowed lacks the bectl list query" >> "$_gs_log"; _gs_bad=1; }
	printf '%s\n' "$_gs_guard" | grep -qF '$2 ~ /N/' || { echo "deadman_allowed lacks the active-BE query" >> "$_gs_log"; _gs_bad=1; }
	printf '%s\n' "$_gs_dec" | grep -qF '[ "$6" != "$5" ]' || { echo "dm_decide lacks the current-BE/marker comparison" >> "$_gs_log"; _gs_bad=1; }
	[ "$(grep -oF '/sbin/shutdown' "$_gs_file" | wc -l | tr -d ' ')" = 1 ] || { echo "the real shutdown path does not occur exactly once" >> "$_gs_log"; _gs_bad=1; }
	[ "$(grep -c '^[[:space:]]*"\$nvidia_native_tools_testboot_shutdown" -r ' "$_gs_file")" = 1 ] || { echo "the quoted shutdown-variable call does not occur exactly once" >> "$_gs_log"; _gs_bad=1; }
	if bare_shutdown "$_gs_file"; then echo "a bare shutdown call remains" >> "$_gs_log"; _gs_bad=1; fi
	grep -Eq 'pgrep|pkill' "$_gs_file" && { echo "pgrep/pkill remains" >> "$_gs_log"; _gs_bad=1; }
	grep -qF 'ps -o uid= -o comm= -p "$1"' "$_gs_file" || { echo "exact-pid ps confirmation is missing" >> "$_gs_log"; _gs_bad=1; }
	grep -qF 'DM_CHILD=$_dm_pid' "$_gs_file" || { echo "the confirmed pid is not recorded" >> "$_gs_log"; _gs_bad=1; }
	grep -qF 'kill "$DM_CHILD"' "$_gs_file" || { echo "exact-pid cancellation is missing" >> "$_gs_log"; _gs_bad=1; }
	return "$_gs_bad"
}
# dm_table <rc file>: the dm_decide result of every single-condition failure and of the all-true row, as one line
dm_table() {
	sed -n '/^dm_decide()/,/^}/p' "$1" > "$T/dm_decide.fn"
	_t=
	for _row in "1001 yes yes start M M" "0 no yes start M M" "0 - yes start M M" "0 yes - start M M" "0 yes yes stop M M" "0 yes yes start - M" "0 yes yes start M OTHER" "0 yes yes start M -" "0 yes yes start M M"; do
		set -- $_row
		_a2=$2; _a3=$3; _a4=$4; _a5=$5; _a6=$6
		[ "$_a2" != - ] || _a2=; [ "$_a3" != - ] || _a3=; [ "$_a5" != - ] || _a5=; [ "$_a6" != - ] || _a6=
		sh -c '. "$1"; shift; dm_decide "$@" > /dev/null' dm "$T/dm_decide.fn" "$1" "$_a2" "$_a3" "$_a4" "$_a5" "$_a6"; _t="$_t $?"
	done
	echo "${_t# }"
}
. "$KIT/guard.sh"

# (e) root must not inherit a work directory under root's home when a defaulted path is needed
(unset GB10_WORK; guard_work_default 0 make-be.sh "-m -s -o") > "$T/root-mb.out" 2>&1
expect 2 $? "make-be.sh: root without GB10_WORK refuses the defaulted paths"
grep -q 'set GB10_WORK or pass -m -s -o' "$T/root-mb.out" && ok "make-be.sh: the root refusal says how to provide the paths" || no "make-be.sh: $(cat "$T/root-mb.out")"
(unset GB10_WORK; guard_work_default 0 check-be.sh -s) > "$T/root-cb.out" 2>&1
expect 2 $? "check-be.sh: root without GB10_WORK refuses the defaulted hash list"
grep -q 'set GB10_WORK or pass -s' "$T/root-cb.out" && ok "check-be.sh: the root refusal says how to provide the hash list" || no "check-be.sh: $(cat "$T/root-cb.out")"
(unset GB10_WORK; guard_work_default 1001 make-be.sh "-m -s -o"); expect 0 $? "make-be.sh: non-root keeps the HOME default"
(GB10_WORK="$WORK"; guard_work_default 0 check-be.sh -s); expect 0 $? "check-be.sh: an explicit GB10_WORK is accepted for root"

# (a) guard_env
cat > "$T/kld-clean" <<'EOF'
Id Refs Address                Size Name
 1  164 0xffff000000000000  1594e28 kernel (/boot/kernel/kernel)
	Contains modules:
		 Id Name
		295 cubic
 2    1 0xffff0005ce600000   993000 nvidia.ko (/boot/modules.nvnative-test/nvidia.ko)
	Contains modules:
		 Id Name
		500 nvidia
EOF
echo "sysctl: unknown oid 'compat.linux'" > "$T/sys-absent"
echo "compat.linux.osrelease: 5.15.0" > "$T/sys-present"
echo "sysctl: Operation not permitted" > "$T/sys-other"
guard_env "$T/kld-clean" 0 "$T/sys-absent" 1 nvidia.ko > /dev/null; expect 0 $? "guard_env: a clean listing passes"
{ cat "$T/kld-clean"; echo ' 3    1 0xffff0005ea000000    63000 linux64.ko (/boot/kernel/linux64.ko)'; } > "$T/kld-l64"
guard_env "$T/kld-l64" 0 "$T/sys-absent" 1 > /dev/null; expect 1 $? "guard_env: linux64.ko fails"
{ cat "$T/kld-clean"; echo ' 3    1 0xffff0005ea000000    63000 nvidia_linux.ko (/boot/modules/nvidia_linux.ko)'; } > "$T/kld-nvl"
guard_env "$T/kld-nvl" 0 "$T/sys-absent" 1 > /dev/null; expect 1 $? "guard_env: nvidia_linux.ko without linux64 fails"
{ cat "$T/kld-clean"; printf ' 4    2 0xffff0005ef000000    26000 drm.ko (/boot/modules/drm.ko)\n\tContains modules:\n\t\t Id Name\n\t\t612 linuxkpi\n'; } > "$T/kld-lkpi"
guard_env "$T/kld-lkpi" 0 "$T/sys-absent" 1 > /dev/null; expect 1 $? "guard_env: a module named linuxkpi inside another file fails"
{ cat "$T/kld-clean"; echo ' 5    1 0xffff0005ef100000    16000 lindebugfs.ko (/boot/modules/lindebugfs.ko)'; } > "$T/kld-ldfs"
guard_env "$T/kld-ldfs" 0 "$T/sys-absent" 1 > /dev/null; expect 1 $? "guard_env: lindebugfs.ko fails"
guard_env "$T/kld-clean" 0 "$T/sys-present" 0 > /dev/null; expect 1 $? "guard_env: compat.linux that answers fails"
guard_env "$T/kld-clean" 0 "$T/sys-other" 1 > /dev/null; expect 2 $? "guard_env: a sysctl failure that is not unknown oid is an error"
guard_env "$T/kld-clean" 1 "$T/sys-absent" 1 > /dev/null; expect 2 $? "guard_env: kldstat that failed is an error"
: > "$T/kld-empty"
guard_env "$T/kld-empty" 0 "$T/sys-absent" 1 > /dev/null; expect 2 $? "guard_env: an empty listing is an error"
sed -n '1,5p' "$T/kld-clean" > "$T/kld-kernel-only"
guard_env "$T/kld-kernel-only" 0 "$T/sys-absent" 1 nvidia.ko > /dev/null; expect 2 $? "guard_env: a listing without the required nvidia.ko is an error"
sed '2,5d' "$T/kld-clean" > "$T/kld-no-kernel"
guard_env "$T/kld-no-kernel" 0 "$T/sys-absent" 1 > /dev/null; expect 2 $? "guard_env: a listing without kernel is an error"
cp "$T/kld-nvl" "$T/after"; guard_env_delta "$T/kld-clean" "$T/after" > /dev/null; expect 1 $? "guard_env_delta: a module that appeared fails"
cp "$T/kld-clean" "$T/after2"; guard_env_delta "$T/kld-clean" "$T/after2" > /dev/null; expect 0 $? "guard_env_delta: no change passes"
# the env-before listing of the 2026-11-22 native-tools boot (stock kernel with COMPAT_LINUXKPI): Linux-named module
# records inside the kernel file are not loaded files; they are listed, and the guard passes
FIX=$repo/tests/data/native-tools-env-before-20261122T072752Z.kldstat
guard_env "$FIX" 0 "$T/sys-absent" 1 > "$T/fix.out"; expect 0 $? "guard_env: the 2026-11-22 boot listing (kernel-built-in lkpi and usb_linux records) passes"
_krec=$(sed -n 's/^records //p' "$T/fix.out")
for _r in uhub/usb_linux lkpi_iic/iicbus lkpi_iicbb/iicbb drm/lkpi_iic drmn/lkpi_iicbb pci/lkpi_mlx5_core_pci_table; do
	case " $_krec " in *" $_r "*) ok "guard_env: kernel record $_r is listed as info" ;; *) no "guard_env: kernel record $_r is not listed ($_krec)" ;; esac
done
_r=sentinel; _name=sentinel; _x=$(guard_env "$FIX" 0 "$T/sys-absent" 1)
[ "$_r $_name" = "sentinel sentinel" ] && ok "guard_env in a command substitution leaves the caller variables alone" || no "guard_env changed _r or _name"
# a Linux-layer module under an innocuous file name: its record gives it away
{ cat "$FIX"; printf '99    1 0xffff0005ea000000    63000 foo.ko (/boot/modules/foo.ko)\n\tContains modules:\n\t\t Id Name\n\t\t700 linux64elf\n'; } > "$T/fix-foo"
guard_env "$T/fix-foo" 0 "$T/sys-absent" 1 > "$T/fix-foo.out"; expect 1 $? "guard_env: a record linux64elf inside foo.ko fails"
grep -q 'foo.ko:linux64elf' "$T/fix-foo.out" && ok "guard_env: the message names foo.ko:linux64elf" || no "guard_env: $(head -1 "$T/fix-foo.out")"
{ cat "$FIX"; printf '99    1 0xffff0005ea000000    63000 foo.ko (/boot/modules/foo.ko)\n\tContains modules:\n\t\t Id Name\n\t\t701 drmn/lkpi_iic\n'; } > "$T/fix-foo2"
guard_env "$T/fix-foo2" 0 "$T/sys-absent" 1 > "$T/fix-foo2.out"; expect 1 $? "guard_env: a record drmn/lkpi_iic inside foo.ko fails"
[ "$(sed -n 's/^records //p' "$T/fix-foo2.out" | tr ' ' '\n' | grep -cx 'drmn/lkpi_iic')" = 1 ] && ok "guard_env: drmn/lkpi_iic is listed once, from the kernel" || no "guard_env: drmn/lkpi_iic is not listed exactly once"
{ cat "$FIX"; echo '99    1 0xffff0005ea000000    63000 drm.ko (/boot/modules/drm.ko)'; } > "$T/fix-drm"
guard_env "$T/fix-drm" 0 "$T/sys-absent" 1 > /dev/null; expect 1 $? "guard_env: the boot listing plus drm.ko fails"
{ cat "$FIX"; echo '99    1 0xffff0005ea000000    63000 linux64.ko (/boot/kernel/linux64.ko)'; } > "$T/fix-l64"
guard_env "$T/fix-l64" 0 "$T/sys-absent" 1 > /dev/null; expect 1 $? "guard_env: the boot listing plus linux64.ko fails"
{ cat "$FIX"; echo '99    1 0xffff0005ea000000    63000 nvidia_modeset_linux.ko (/boot/modules/nvidia_modeset_linux.ko)'; } > "$T/fix-nml"
guard_env "$T/fix-nml" 0 "$T/sys-absent" 1 > /dev/null; expect 1 $? "guard_env: the boot listing plus nvidia_modeset_linux.ko fails"
{ cat "$FIX"; echo '99    1 0xffff0005ea000000    63000 linsysfs.ko (/boot/kernel/linsysfs.ko)'; } > "$T/fix-lsfs"
guard_env "$T/fix-lsfs" 0 "$T/sys-absent" 1 > /dev/null; expect 1 $? "guard_env: the boot listing plus linsysfs.ko fails"
guard_env "$FIX" 0 "$T/sys-present" 0 > /dev/null; expect 1 $? "guard_env: the boot listing with compat.linux answering fails"
# the capture of the 2026-11-23 native-tools boot: the clone had kld_list stripped, yet amdgpu.ko, drm.ko,
# linuxkpi_video.ko, dmabuf.ko, lindebugfs.ko and ttm.ko were loaded (an rc.d service loads them by itself)
FIX23=$repo/tests/data/native-tools-boot-20261123T013024Z/env-before.kldstat
SUM23=$repo/tests/data/native-tools-boot-20261123T013024Z/summary.txt
if [ -f "$FIX23" ]; then ok "the capture of the 2026-11-23 boot is in the tree"; else no "the capture of the 2026-11-23 boot is missing"; fi
guard_env "$FIX23" 0 "$T/sys-absent" 1 > "$T/fix23.out"; expect 1 $? "guard_env: the 2026-11-23 boot listing (amdgpu.ko, drm.ko, linuxkpi_video.ko, dmabuf.ko, lindebugfs.ko, ttm.ko) fails"
_g23=$(head -1 "$T/fix23.out")
# the message points at check-be.sh, it does not blame kld_list alone, and it names no service it cannot see
printf '%s' "$_g23" | grep -q 'check-be.sh' && ok "guard_env: the failure of the 2026-11-23 capture points at check-be.sh" || no "guard_env: the failure does not point at check-be.sh: $_g23"
printf '%s' "$_g23" | grep -q 'not kld_list alone' && no "guard_env: the failure still blames kld_list alone: $_g23" || ok "guard_env: the failure does not blame kld_list alone"
printf '%s' "$_g23" | grep -q 'drm_ready' && no "guard_env: the failure names drm_ready although no tree was read: $_g23" || ok "guard_env: the failure names no service when no tree was read"
# the summary of that boot is a fixture of the capture: it must name the files the capture shows
if [ -f "$SUM23" ]; then
	ok "the summary of the 2026-11-23 boot is in the tree"
	_bad=
	for _f in amdgpu.ko drm.ko linuxkpi_video.ko dmabuf.ko lindebugfs.ko ttm.ko; do
		grep -q "$_f" "$SUM23" || _bad="$_bad (not in the summary)$_f"
		grep -q "$_f" "$FIX23" || _bad="$_bad (not in the capture)$_f"
	done
	[ -z "$_bad" ] && ok "the summary of the 2026-11-23 boot names the files the capture shows" || no "the summary of the 2026-11-23 boot and its capture disagree:$_bad"
	[ "$(tail -1 "$SUM23")" = FAIL ] && ok "the summary of the 2026-11-23 boot ends with FAIL" || no "the summary of the 2026-11-23 boot ends with $(tail -1 "$SUM23")"
	# the summary of the capture has the layout summarize.py writes today: a row line is rendered and the fixture
	# must start with the same prefix, so the fixture cannot drift away from the format
	mkdir -p "$T/fmt23"
	/usr/local/bin/python3 -I -c 'import json,sys; open(sys.argv[1],"w").write(json.dumps({"row":"env-before","status":"fail","detail":"x"})+"\n")' "$T/fmt23/results.jsonl"
	/usr/local/bin/python3 -I "$KIT/summarize.py" "$T/fmt23" > "$T/fmt23.txt" 2>&1
	_pre=$(printf '%s\n' "$(grep '^fail  *env-before' "$T/fmt23.txt" | head -1)" | sed -e 's/.$//')
	case "$(grep '^fail  *env-before' "$SUM23" | head -1)" in
	"$_pre"*) ok "the summary of the 2026-11-23 boot has the layout summarize.py writes today" ;;
	*) no "the summary of the 2026-11-23 boot does not have the layout summarize.py writes today" ;;
	esac
	case "fail env-before x" in
	"$_pre"*) no "the summary layout: the control cannot fail: a row line with another layout is accepted" ;;
	*) ok "control: the summary layout: a row line with another layout is seen (the check can fail)" ;;
	esac
else
	no "the summary of the 2026-11-23 boot is missing"
fi
# a fake root with a service that loads amdgpu by itself, and a devd rule that starts the probe: the guard names them
mkdir -p "$T/fakeroot/etc/rc.d" "$T/fakeroot/usr/local/etc/rc.d" "$T/fakeroot/usr/local/etc/devd"
printf 'drm_ready_enable="YES"\ndrm_ready_modules="amdgpu"\ncloudbsd_hwprobe_enable="YES"\n' > "$T/fakeroot/etc/rc.conf"
cat > "$T/fakeroot/usr/local/etc/rc.d/drm_ready" <<'EOF'
#!/bin/sh
# PROVIDE: drm_ready
name="drm_ready"
rcvar="drm_ready_enable"
load_rc_config $name
required_modules="${drm_ready_modules:-amdgpu}"
run_rc_command "$1"
EOF
cat > "$T/fakeroot/usr/local/etc/rc.d/cloudbsd_hwprobe" <<'EOF'
#!/bin/sh
# PROVIDE: cloudbsd_hwprobe
name="cloudbsd_hwprobe"
rcvar="cloudbsd_hwprobe_enable"
: "${cloudbsd_hwprobe_command:="apply"}"
load_rc_config $name
run_rc_command "$1"
EOF
chmod 0755 "$T/fakeroot/usr/local/etc/rc.d/drm_ready" "$T/fakeroot/usr/local/etc/rc.d/cloudbsd_hwprobe"
cat > "$T/fakeroot/usr/local/etc/devd/cloudbsd-gpu-hotplug.conf" <<'EOF'
attach 100 {
	match "class" "0x03.*";
	match "vendor" "0x1002";
	action "/usr/sbin/service cloudbsd_hwprobe quietstart &";
};
EOF
# a second tree with the idioms a script can use: the rcvar built from the name of the script, the modules as a
# default of the script, a module list that cannot be read, and a Linux-layer module the first list did not hold
mkdir -p "$T/fakeroot-idioms/etc/rc.d" "$T/fakeroot-idioms/usr/local/etc/rc.d"
printf 'drm_named_enable="YES"\ndrm_default_enable="YES"\ndrm_unknown_enable="YES"\ndrm_lsfs_enable="YES"\n' > "$T/fakeroot-idioms/etc/rc.conf"
cat > "$T/fakeroot-idioms/usr/local/etc/rc.d/drm_named" <<'EOF'
#!/bin/sh
# PROVIDE: drm_named
name="drm_named"
rcvar="${name}_enable"
required_modules="amdgpu"
run_rc_command "$1"
EOF
cat > "$T/fakeroot-idioms/usr/local/etc/rc.d/drm_default" <<'EOF'
#!/bin/sh
# PROVIDE: drm_default
name="drm_default"
rcvar="drm_default_enable"
: "${drm_default_modules:=amdgpu}"
required_modules="$drm_default_modules"
run_rc_command "$1"
EOF
cat > "$T/fakeroot-idioms/usr/local/etc/rc.d/drm_unknown" <<'EOF'
#!/bin/sh
# PROVIDE: drm_unknown
name="drm_unknown"
rcvar="drm_unknown_enable"
required_modules="${drm_unknown_modules}"
run_rc_command "$1"
EOF
cat > "$T/fakeroot-idioms/usr/local/etc/rc.d/drm_lsfs" <<'EOF'
#!/bin/sh
# PROVIDE: drm_lsfs
name="drm_lsfs"
rcvar="drm_lsfs_enable"
required_modules="linsysfs"
run_rc_command "$1"
EOF
# a service that its own script enables: the rc.conf says nothing about it
cat > "$T/fakeroot-idioms/usr/local/etc/rc.d/drm_enab" <<'EOF'
#!/bin/sh
# PROVIDE: drm_enab
name="drm_enab"
rcvar="drm_enab_enable"
: "${drm_enab_enable:="YES"}"
required_modules="amdgpu"
run_rc_command "$1"
EOF
chmod 0755 "$T/fakeroot-idioms/usr/local/etc/rc.d/"*
_l23=$(guard_rc_loaders "$T/fakeroot")
printf '%s\n' "$_l23" | grep -q 'rc.d service drm_ready (required_modules amdgpu)' && ok "guard_rc_loaders: the service that loads amdgpu by itself is named" || no "guard_rc_loaders: the service is not named: $_l23"
printf '%s\n' "$_l23" | grep -q 'devd rule cloudbsd-gpu-hotplug.conf starts cloudbsd_hwprobe' && ok "guard_rc_loaders: the devd rule that starts the probe is named" || no "guard_rc_loaders: the devd rule is not named: $_l23"
_l23i=$(guard_rc_loaders "$T/fakeroot-idioms")
# the rcvar built from the name of the script is resolved, so the service is known
printf '%s\n' "$_l23i" | grep -q 'rc.d service drm_named (required_modules amdgpu)' && ok "guard_rc_loaders: a service whose rcvar is built from its name is named" || no "guard_rc_loaders: the service with rcvar=\${name}_enable is not named: $_l23i"
# the default of the script itself is the module list
printf '%s\n' "$_l23i" | grep -q 'rc.d service drm_default (required_modules amdgpu)' && ok "guard_rc_loaders: a service whose modules are a default of the script is named" || no "guard_rc_loaders: the service with a script default is not named: $_l23i"
# the Linux-layer names of the guard list, not only the ones of the first list
printf '%s\n' "$_l23i" | grep -q 'rc.d service drm_lsfs (required_modules linsysfs)' && ok "guard_rc_loaders: a service that loads linsysfs is named" || no "guard_rc_loaders: the service that loads linsysfs is not named: $_l23i"
# a service that its own script enables is enabled: the rc.conf says nothing about it
printf '%s\n' "$(guard_rc_services "$T/fakeroot-idioms")" | grep -q '^drm_enab|drm_enab_enable|yes|amdgpu' \
    && ok "guard_rc_services: a service that its own script enables is enabled" \
    || no "guard_rc_services: the service its own script enables is not enabled: $(guard_rc_services "$T/fakeroot-idioms")"
printf '%s\n' "$_l23i" | grep -q 'rc.d service drm_enab (required_modules amdgpu)' \
    && ok "guard_rc_loaders: the service that its own script enables is named" \
    || no "guard_rc_loaders: the service that its own script enables is not named: $_l23i"
# the control: the reader of the old code, which ignored the defaults of the script, does not know the service
_ct=$( . "$KIT/guard.sh"; guard_rc_service_defaults() { :; }; guard_rc_services "$T/fakeroot-idioms" | grep '^drm_enab|' )
printf '%s' "$_ct" | grep -q '|yes|' \
    && no "guard_rc_services: the check cannot fail: the service is enabled even without the defaults of the script" \
    || ok "control: guard_rc_services: without the defaults of the script the service is not enabled (the check can fail)"
# a service that cannot be read is reported as unknown, not ignored
_l23u=$(guard_rc_offenders "$T/fakeroot-idioms")
printf '%s\n' "$_l23u" | grep -q '^drm_unknown|?|unknown|' && ok "guard_rc_offenders: a service whose modules cannot be read is reported as unknown" || no "guard_rc_offenders: the service that cannot be read is not reported: $_l23u"
printf '%s\n' "$_l23u" | grep -q '^drm_unknown|drm_unknown_enable|' && no "guard_rc_offenders: the service that cannot be read is reported as a known offender" || ok "guard_rc_offenders: the service that cannot be read is not reported as a known offender"
GUARD_ROOT=$T/fakeroot; export GUARD_ROOT
guard_env "$FIX23" 0 "$T/sys-absent" 1 > "$T/fix23-known.out"; expect 1 $? "guard_env with GUARD_ROOT fails the 2026-11-23 capture"
grep -q 'rc.d service drm_ready (required_modules amdgpu)' "$T/fix23-known.out" && ok "guard_env: the failure names the loader it can see" || no "guard_env: the failure names no loader: $(head -1 "$T/fix23-known.out")"
grep -q 'check-be.sh' "$T/fix23-known.out" && ok "guard_env: the failure that names the loader points at check-be.sh" || no "guard_env: the failure does not point at check-be.sh: $(head -1 "$T/fix23-known.out")"
unset GUARD_ROOT
# a tree whose only loader is the loader list: the failure names it, and does not claim the loader list is not the
# loader
mkdir -p "$T/fakeroot-kl/etc"
printf 'kld_list="amdgpu"\n' > "$T/fakeroot-kl/etc/rc.conf"
GUARD_ROOT=$T/fakeroot-kl; export GUARD_ROOT
guard_env "$FIX23" 0 "$T/sys-absent" 1 > "$T/fix23-kl.out"; expect 1 $? "guard_env with a loader list fails the 2026-11-23 capture"
_gkl=$(head -1 "$T/fix23-kl.out")
printf '%s' "$_gkl" | grep -q 'loaded by kld_list amdgpu' && ok "guard_env: the failure names the loader list when it is the loader" || no "guard_env: the loader list is not named: $_gkl"
printf '%s' "$_gkl" | grep -q 'not kld_list alone' && no "guard_env: the failure claims the loader list is not the loader: $_gkl" || ok "guard_env: the failure does not claim the loader list is not the loader"
unset GUARD_ROOT
# the cause comes first: the truncated summary of the failed boot still names the loader and check-be.sh
mkdir -p "$T/sum23"
/usr/local/bin/python3 -I -c 'import json,sys; open(sys.argv[1],"w").write(json.dumps({"row":"env-before","status":"fail","detail":sys.argv[2]})+"\n")' "$T/sum23/results.jsonl" "$(head -1 "$T/fix23-known.out")"
/usr/local/bin/python3 -I "$KIT/summarize.py" "$T/sum23" > "$T/sum23.txt" 2>&1
_sum=$(grep 'env-before' "$T/sum23.txt" | head -1)
printf '%s' "$_sum" | grep -q 'check-be.sh' && ok "summarize: the truncated env-before line still points at check-be.sh" || no "summarize: the truncated env-before line lost the pointer: $_sum"
printf '%s' "$_sum" | grep -q 'drm_ready' && ok "summarize: the truncated env-before line still names the loader" || no "summarize: the truncated env-before line lost the loader: $_sum"
# the same tree with the probe that only probes: the devd rule loads no KMS driver and is not named any more
printf 'cloudbsd_hwprobe_command="probe"\n' >> "$T/fakeroot/etc/rc.conf"
_l23=$(guard_rc_loaders "$T/fakeroot")
printf '%s\n' "$_l23" | grep -q 'devd rule' && no "guard_rc_loaders: the devd rule is named although the probe only probes: $_l23" || ok "guard_rc_loaders: the devd rule is not named when the probe only probes"
printf '%s\n' "$_l23" | grep -q 'rc.d service drm_ready' && ok "guard_rc_loaders: the service that loads amdgpu is still named" || no "guard_rc_loaders: the service is not named any more: $_l23"
# the expansion of a variable reference: a variable that is not set is not one that is set to nothing
printf '' | guard_rc_expand '${x-amdgpu}' | grep -qx 'amdgpu' && ok "guard_rc_expand: \${x-default} takes the default when the variable is not set" || no "guard_rc_expand: \${x-default} gives $(printf '' | guard_rc_expand '${x-amdgpu}')"
printf 'x\t\n' | guard_rc_expand '${x-amdgpu}' | grep -qx '' && ok "guard_rc_expand: \${x-default} keeps the value when the variable is set to nothing" || no "guard_rc_expand: \${x-default} gives $(printf 'x\t\n' | guard_rc_expand '${x-amdgpu}')"
printf '' | guard_rc_expand '${x:=amdgpu}' | grep -qx 'amdgpu' && ok "guard_rc_expand: \${x:=default} takes the default when the variable is not set" || no "guard_rc_expand: \${x:=default} gives $(printf '' | guard_rc_expand '${x:=amdgpu}')"
printf '' | guard_rc_expand '${x+amdgpu}' | grep -qx '' && ok "guard_rc_expand: \${x+word} is empty when the variable is not set" || no "guard_rc_expand: \${x+word} gives $(printf '' | guard_rc_expand '${x+word}')"
# the rc.conf.d file of a service is read for that service, and no other file of rc.conf.d is read at all
mkdir -p "$T/fakeroot/etc/rc.conf.d"
printf 'drm_ready_enable="NO"\n' > "$T/fakeroot/etc/rc.conf.d/drm_ready"
guard_rc_services "$T/fakeroot" | grep -q '^drm_ready|drm_ready_enable|no|' && ok "guard_rc_services: the rc.conf.d file of the service wins" || no "guard_rc_services: the rc.conf.d file of the service is not read: $(guard_rc_services "$T/fakeroot")"
rm "$T/fakeroot/etc/rc.conf.d/drm_ready"
printf 'drm_ready_enable="NO"\n' > "$T/fakeroot/etc/rc.conf.d/other"
guard_rc_services "$T/fakeroot" | grep -q '^drm_ready|drm_ready_enable|yes|' && ok "guard_rc_services: a file of rc.conf.d that is not the file of the service is not read" || no "guard_rc_services: a file of rc.conf.d that is not the file of the service was read: $(guard_rc_services "$T/fakeroot")"
rm "$T/fakeroot/etc/rc.conf.d/other"
# the value of a variable is read the same way by every reader
printf 'drm_ready_modules="amdgpu radeonkms" # x\n' > "$T/rcconf"
_v=$(guard_rcconf_pairs "$T/rcconf" | guard_rcconf_value drm_ready_modules)
_e=$(guard_rcconf_pairs "$T/rcconf" | guard_rc_expand '$drm_ready_modules' '')
[ "$_v" = 'amdgpu radeonkms' ] && ok "guard_rcconf_value: the value of a quoted assignment is read as it is" || no "guard_rcconf_value: the value is '$_v'"
[ "$_e" = "$_v" ] && ok "guard_rcconf_value and guard_rc_expand read the same value" || no "guard_rcconf_value gives '$_v' and guard_rc_expand gives '$_e'"
# the defaults of a script are read with the same rule as the rc.conf: one rule, one reader
printf ': "${drm_ready_modules:="amdgpu radeonkms"}" # x\n' > "$T/scriptdef"
_d=$(guard_rc_service_defaults "$T/scriptdef" | guard_rcconf_value drm_ready_modules)
[ "$_d" = "$_v" ] && ok "guard_rc_service_defaults and guard_rcconf_pairs read the value with the same rule" || no "guard_rcconf_pairs gives '$_v' and guard_rc_service_defaults gives '$_d'"
# the control: another value is another value (the check can fail)
printf ': "${drm_ready_modules:="radeonkms"}"\n' > "$T/scriptdef2"
_d2=$(guard_rc_service_defaults "$T/scriptdef2" | guard_rcconf_value drm_ready_modules)
[ "$_d2" = "$_v" ] \
    && no "guard_rc_service_defaults: the control cannot fail: another value is read like this one" \
    || ok "control: guard_rc_service_defaults: another value is another value (the check can fail)"
_live=$T/kld-live; kldstat -v > "$_live" 2>&1; _ks=$?; sysctl compat.linux > "$T/sys-live" 2>&1; _ss=$?
_l=$(guard_env "$_live" "$_ks" "$T/sys-live" "$_ss"); _s=$?
if kldstat -q -m linux64elf 2> /dev/null || kldstat -q -m linuxkpi 2> /dev/null || kldstat -q -m linux 2> /dev/null; then
	expect 1 "$_s" "guard_env on this host (a Linux or LinuxKPI module is loaded) fails: $_l"
else
	expect 0 "$_s" "guard_env on this host (no Linux module) passes: $_l"
fi

# (b) guard_brand
guard_brand /bin/sh > /dev/null; expect 0 $? "guard_brand: /bin/sh passes"
printf '#!/bin/sh\necho hi\n' > "$T/s.sh"; chmod 0755 "$T/s.sh"
guard_brand "$T/s.sh" > /dev/null; expect 0 $? "guard_brand: a #! script passes"
cp /bin/echo "$T/echo-linux"; chmod u+w "$T/echo-linux"; brandelf -t Linux "$T/echo-linux"
guard_brand "$T/echo-linux" > /dev/null; expect 1 $? "guard_brand: a Linux-branded ELF fails"
echo "plain text" > "$T/text"; guard_brand "$T/text" > /dev/null; expect 1 $? "guard_brand: a text file fails"
guard_brand "$T/missing" > /dev/null; expect 2 $? "guard_brand: a missing file is an error"

# (c) guard_trace, real traces
printf '#!/bin/sh\n"%s" hello > /dev/null 2>&1\n/usr/bin/true\n' "$T/echo-linux" > "$T/bad.sh"; chmod 0755 "$T/bad.sh"
ktrace -i -t cn -f "$T/bad.kt" /bin/sh "$T/bad.sh"; kdump -f "$T/bad.kt" > "$T/bad.kd"
guard_trace "$T/bad.kd" /bin/sh "$T/bad.rep" > /dev/null; expect 1 $? "guard_trace: a script that runs a Linux-branded ELF by absolute path fails"
grep -q "fail $T/echo-linux" "$T/bad.rep" && ok "guard_trace: the report names the Linux-branded file" || no "guard_trace: the report does not name $T/echo-linux"
printf '#!/bin/sh\n/usr/bin/true\nls / > /dev/null\n' > "$T/good.sh"; chmod 0755 "$T/good.sh"
ktrace -i -t cn -f "$T/good.kt" "$T/good.sh"; kdump -f "$T/good.kt" > "$T/good.kd"
guard_trace "$T/good.kd" "$T/good.sh" "$T/good.rep" > /dev/null; expect 0 $? "guard_trace: a clean script (run as a #! file) passes"
grep -q 'pass /bin/sh' "$T/good.rep" && ok "guard_trace: the #! interpreter /bin/sh is checked" || no "guard_trace: /bin/sh is not in the report"
grep -q 'pass /bin/ls' "$T/good.rep" && ok "guard_trace: a command found through PATH (/bin/ls) is checked" || no "guard_trace: /bin/ls is not in the report"
guard_trace "$T/good.kd" /usr/sbin/not-run "$T/x.rep" > /dev/null; expect 2 $? "guard_trace: a trace without the tool is an error"
: > "$T/empty.kd"; guard_trace "$T/empty.kd" /bin/sh "$T/x.rep" > /dev/null; expect 2 $? "guard_trace: an empty trace is an error"
{ cat "$T/good.kd"; echo ' 77777 sh       CALL  kldload(0x123456)'; } > "$T/kl.kd"
guard_trace "$T/kl.kd" "$T/good.sh" "$T/x.rep" > /dev/null; expect 1 $? "guard_trace: a kldload call fails"
{ cat "$T/good.kd"; echo ' 77777 sh       CALL  kldunload(0x3)'; } > "$T/ku.kd"
guard_trace "$T/ku.kd" "$T/good.sh" "$T/x.rep" > /dev/null; expect 1 $? "guard_trace: a kldunload call fails"
# a Linux-branded file that is run, then removed: it cannot be checked afterwards, so the row is an error
cp "$T/echo-linux" "$T/gone"
printf '#!/bin/sh\n"%s" x > /dev/null 2>&1\nrm -f "%s"\n' "$T/gone" "$T/gone" > "$T/rm.sh"; chmod 0755 "$T/rm.sh"
ktrace -i -t cn -f "$T/rm.kt" "$T/rm.sh"; kdump -f "$T/rm.kt" > "$T/rm.kd"
guard_trace "$T/rm.kd" "$T/rm.sh" "$T/x.rep" > /dev/null; _s=$?
[ "$_s" != 0 ] && ok "guard_trace: a file run and then removed is not a pass (exit $_s)" || no "guard_trace: a file run and then removed passes"
# a file run by a relative path after cd: an error, not a skip
mkdir -p "$T/sub"; cp /usr/bin/true "$T/sub/rel"
printf '#!/bin/sh\ncd "%s" && ./rel\n' "$T/sub" > "$T/rel.sh"; chmod 0755 "$T/rel.sh"
ktrace -i -t cn -f "$T/rel.kt" "$T/rel.sh"; kdump -f "$T/rel.kt" > "$T/rel.kd"
guard_trace "$T/rel.kd" "$T/rel.sh" "$T/x.rep" > /dev/null; expect 2 $? "guard_trace: a file run by a relative path is an error"
# a process whose name holds a space: its calls are still seen
cp /bin/sh "$T/x y"; ktrace -i -t cn -f "$T/sp.kt" "$T/x y" -c 'kldload /nonexistent/nvnt-test.ko' > /dev/null 2>&1; kdump -f "$T/sp.kt" > "$T/sp.kd"
grep -q 'x y' "$T/sp.kd" && ok "the trace names the process 'x y'" || no "the trace does not name 'x y'"
guard_trace "$T/sp.kd" "$T/x y" "$T/x.rep" > /dev/null; _s=$?
[ "$_s" != 0 ] && ok "guard_trace: a kldload by a process named with a space is caught (exit $_s)" || no "guard_trace: a process named 'x y' escapes the kldload check"
{ cat "$T/good.kd"; echo ' 77777 sh       CALL  fexecve(0x3,0x4,0x5)'; echo ' 77777 sh       RET   fexecve JUSTRETURN'; } > "$T/fx.kd"
guard_trace "$T/fx.kd" "$T/good.sh" "$T/x.rep" > /dev/null; expect 2 $? "guard_trace: an exec with no path in the trace (fexecve) is an error"
{ cat "$T/good.kd"; echo ' 77777 sh       CALL  fexecve(0x3,0x4,0x5)'; echo ' 77777 sh       NAMI  "/libexec/ld-elf.so.1"'; echo ' 77777 sh       RET   fexecve JUSTRETURN'; } > "$T/fx2.kd"
guard_trace "$T/fx2.kd" "$T/good.sh" "$T/x.rep" > /dev/null; expect 2 $? "guard_trace: an fexecve is an error even when its interpreter has a path"
guard_plain_path /var/a/b > /dev/null; expect 0 $? "guard_plain_path: a plain path passes"
for _bad in relative/x /a/b/ /a//b /a/./b /a/../b /a/b/.. '/a/*/b'; do
	guard_plain_path "$_bad" > /dev/null; expect 1 $? "guard_plain_path: '$_bad' is refused"
done
guard_elf /bin/sh > /dev/null; expect 0 $? "guard_elf: /bin/sh passes"
guard_elf "$T/s.sh" > /dev/null; expect 1 $? "guard_elf: a #! script is not an ELF"
{ cat "$T/good.kd"; echo 'garbage line'; } > "$T/gb.kd"
guard_trace "$T/gb.kd" "$T/good.sh" "$T/x.rep" > /dev/null; expect 2 $? "guard_trace: a line of no known shape is an error"

# (d) summarize.py
SUMM="/usr/local/bin/python3 -I $KIT/summarize.py"
VALID="/usr/local/bin/python3 -I $repo/tests/libnvrm/schema_validate.py $KIT/native-tools-summary.schema.json"
rowf() { /usr/local/bin/python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print([r[sys.argv[3]] for r in d["rows"] if r["name"]==sys.argv[2]][0])' "$1" "$2" "$3" 2> /dev/null; }
planned=$($SUMM --planned)
[ "$(echo $planned | wc -w | tr -d ' ')" = 37 ] && ok "summarize --planned lists the 37 planned rows" || no "summarize --planned lists $(echo $planned | wc -w) rows"
mkrun() {	# mkrun <dir> <status of the static rows>
	mkdir -p "$1"; : > "$1/results.jsonl"
	for _r in $planned; do
		case $_r in
		done) _s=info ;;
		uvm-* | prime-import | render-uapi) _s=$2 ;;
		*) _s=pass ;;
		esac
		printf '{"row":"%s","status":"%s","detail":"d"}\n' "$_r" "$_s" >> "$1/results.jsonl"
	done
}
oneline() { /usr/local/bin/python3 -I -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))))' "$1"; }
mkrun "$T/r1" needs-linux; $SUMM "$T/r1" > "$T/r1.out"; expect 3 $? "summarize: a run with needs-linux rows is incomplete"
[ "$(tail -1 "$T/r1.out")" = INCOMPLETE ] && ok "summarize: the last line is INCOMPLETE" || no "summarize: last line $(tail -1 "$T/r1.out")"
oneline "$T/r1/summary.json" > "$T/r1.l"; $VALID "$T/r1.l" > /dev/null; expect 0 $? "summarize: summary.json validates against the schema"
/usr/local/bin/python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); n=[r["name"] for r in d["rows"]]; sys.exit(0 if all(n.count(p) == 1 for p in d["planned"]) and d["planned"] == sys.argv[2].split() else 1)' "$T/r1/summary.json" "$planned" && ok "summarize: every planned row appears exactly once" || no "summarize: the planned rows are not each present once"
grep -q '"native_verdict": "pass"' "$T/r1/summary.json" && ok "summarize: native_verdict is pass" || no "summarize: native_verdict is not pass"
sed 's/"status": "needs-linux"/"status": "skipped"/' "$T/r1.l" > "$T/r1.bad"; $VALID "$T/r1.bad" > /dev/null 2>&1; expect 1 $? "schema: a wrong status is refused"
mkrun "$T/r8" info; $SUMM "$T/r8" > /dev/null; expect 1 $? "summarize: a planned check that records info is not a pass"
mkrun "$T/r9" pass; grep -v '"row":"env-after"' "$T/r9/results.jsonl" | sed 's/"row":"nvrm-info","status":"pass"/"row":"nvrm-info","status":"info"/' > "$T/r9/x"; mv "$T/r9/x" "$T/r9/results.jsonl"
$SUMM "$T/r9" > /dev/null; [ "$(rowf "$T/r9/summary.json" env-after status)" = not-run ] && ok "summarize: a row missing after a planned info row (now an error) is not-run" || no "summarize: env-after is $(rowf "$T/r9/summary.json" env-after status)"
mkrun "$T/r10" pass; chmod 0555 "$T/r10"; $SUMM "$T/r10" > /dev/null 2>&1; expect 4 $? "summarize: a run it cannot write summary.json into exits 4, not a verdict"; chmod 0755 "$T/r10"
mkrun "$T/r2" pass; $SUMM "$T/r2" > /dev/null; expect 0 $? "summarize: a fully passing run is pass"
mkrun "$T/r3" not-available; printf '{"row":"nvrm-info","status":"fail","detail":"x"}\n' >> "$T/r3/results.jsonl"; $SUMM "$T/r3" > /dev/null; expect 1 $? "summarize: a failed row is fail"
mkrun "$T/r4" pass; grep -v '"row":"done"' "$T/r4/results.jsonl" > "$T/r4/x"; mv "$T/r4/x" "$T/r4/results.jsonl"; $SUMM "$T/r4" > /dev/null; expect 1 $? "summarize: a missing done row is fail"
mkrun "$T/r5" pass; printf '{"row":"nvrm-info","status":"running","detail":"x"}\n' >> "$T/r5/results.jsonl"; $SUMM "$T/r5" > /dev/null; expect 1 $? "summarize: a row left running fails the run"
rowf "$T/r5/summary.json" nvrm-info detail | grep -q 'stopped in this step' && ok "summarize: the running row says the run stopped there" || no "summarize: the running row is not explained"
mkdir -p "$T/r7"; printf '{"row":"deadman","status":"pass","detail":"d"}\n{"row":"preloaded","status":"fail","detail":"nvidia is loaded"}\n{"row":"done","status":"info","detail":"d"}\n' > "$T/r7/results.jsonl"
$SUMM "$T/r7" > /dev/null; [ "$(rowf "$T/r7/summary.json" load-nvidia status)" = not-run ] && ok "summarize: after a failed row that is not planned (preloaded), a missing row is not-run" || no "summarize: load-nvidia is $(rowf "$T/r7/summary.json" load-nvidia status) after preloaded failed"
mkrun "$T/r6" pass; grep -v '"row":"gpu-verify"' "$T/r6/results.jsonl" > "$T/r6/x"; mv "$T/r6/x" "$T/r6/results.jsonl"; $SUMM "$T/r6" > /dev/null; expect 1 $? "summarize: a planned row missing with no earlier failure fails"
[ "$(rowf "$T/r6/summary.json" gpu-verify status)" = error ] && ok "summarize: the missing row is an error" || no "summarize: the missing row is not an error"

# (d2) the S2 memory row of the rc one-shot: the row function itself, driven with a fixture
sed -n '/^row()/,/^}/p; /^s2_memory_row()/,/^}/p' "$KIT/nvidia_native_tools_testboot" > "$T/s2.sh"
if [ -s "$T/s2.sh" ]; then
	s2case() {	# s2case <line of results.txt> [content of mem_probe.txt]
		rm -rf "$T/s2"; mkdir -p "$T/s2/nvrm-info"
		printf '%s\n' "$1" > "$T/s2/nvrm-info/results.txt"
		if [ -n "${2:-}" ]; then printf '%s\n' "$2" > "$T/s2/nvrm-info/mem_probe.txt"; fi
		OUT=$T/s2
		( . "$T/s2.sh"; s2_memory_row ) > "$T/s2.out" 2>&1
	}
	s2summary() {	# the row the one-shot wrote, read through summarize.py like any other run
		rm -rf "$T/s2run"; mkdir -p "$T/s2run"
		mkrun "$T/s2run" pass
		grep -v '"row":"nvrm-s2-memory"' "$T/s2run/results.jsonl" > "$T/s2run/x"
		cat "$T/s2/results.jsonl" >> "$T/s2run/x"
		mv "$T/s2run/x" "$T/s2run/results.jsonl"
		$SUMM "$T/s2run" > "$T/s2run.out" 2>&1
	}
	s2case 'PASS mem_probe: every memory step passed on every GPU' 'PASS gpu 0 (0000:01:00.0) client_open: ok
PASS gpu 0 (0000:01:00.0) nothing_left: ok'
	s2summary
	_s2s=$(rowf "$T/s2run/summary.json" nvrm-s2-memory status)
	[ "$_s2s" = pass ] && ok "the S2 memory row: a probe that passed every step is a pass" || no "the S2 memory row: the pass fixture gave $_s2s"
	_s2d=$(rowf "$T/s2run/summary.json" nvrm-s2-memory detail)
	printf '%s' "$_s2d" | grep -q '2 GPU' && ok "the S2 memory row: the detail counts the GPUs the probe measured" || no "the S2 memory row: the detail does not count the GPUs: $_s2d"
	s2case 'FAIL mem_probe exited 3 (nvrm-info/mem_probe.txt)'
	s2summary
	_s2s=$(rowf "$T/s2run/summary.json" nvrm-s2-memory status)
	[ "$_s2s" = fail ] && ok "the S2 memory row: a probe that failed is a fail" || no "the S2 memory row: the fail fixture gave $_s2s"
	_s2d=$(rowf "$T/s2run/summary.json" nvrm-s2-memory detail)
	printf '%s' "$_s2d" | grep -q 'FAIL mem_probe exited 3' && ok "the S2 memory row: the detail holds the FAIL line" || no "the S2 memory row: the detail does not hold the FAIL line: $_s2d"
else
	no "the S2 memory row: the row function of the rc script could not be read"
fi

# (d3) the S3 channel row of the rc one-shot: the row function itself, driven with a fixture
sed -n '/^row()/,/^}/p; /^s3_channel_row()/,/^}/p' "$KIT/nvidia_native_tools_testboot" > "$T/s3.sh"
if [ -s "$T/s3.sh" ]; then
	s3case() {	# s3case <line of results.txt> [content of chan_probe.txt]
		rm -rf "$T/s3"; mkdir -p "$T/s3/nvrm-info"
		printf '%s\n' "$1" > "$T/s3/nvrm-info/results.txt"
		if [ -n "${2:-}" ]; then printf '%s\n' "$2" > "$T/s3/nvrm-info/chan_probe.txt"; fi
		OUT=$T/s3
		( . "$T/s3.sh"; s3_channel_row ) > "$T/s3.out" 2>&1
	}
	s3summary() {	# the row the one-shot wrote, read through summarize.py like any other run
		rm -rf "$T/s3run"; mkdir -p "$T/s3run"
		mkrun "$T/s3run" pass
		grep -v '"row":"nvrm-s3-channel"' "$T/s3run/results.jsonl" > "$T/s3run/x"
		cat "$T/s3/results.jsonl" >> "$T/s3run/x"
		mv "$T/s3run/x" "$T/s3run/results.jsonl"
		$SUMM "$T/s3run" > "$T/s3run.out" 2>&1
	}
	# every step passed: the row is a pass and the detail holds the latency and the stress
	s3case 'PASS chan_probe: every channel step passed on every GPU' 'INFO gpu 0 (0000:01:00.0) latency_ns: p50 6000 ns, p99 6400 ns, max 9000 ns
PASS gpu 0 (0000:01:00.0) stress: done 100000/100000 in 3 s, every wait returned 0
PASS gpu 0 (0000:01:00.0) isolation: the second channel died (state dead, error 31, gp_get 0, gp_put 2, submitted 1, completed 0)'
	s3summary
	_s3s=$(rowf "$T/s3run/summary.json" nvrm-s3-channel status)
	[ "$_s3s" = pass ] && ok "the S3 channel row: a probe that passed every step is a pass" || no "the S3 channel row: the pass fixture gave $_s3s"
	_s3d=$(rowf "$T/s3run/summary.json" nvrm-s3-channel detail)
	printf '%s' "$_s3d" | grep -q 'p50 6000 ns' && ok "the S3 channel row: the detail holds the latency line" || no "the S3 channel row: the detail does not hold the latency line: $_s3d"
	printf '%s' "$_s3d" | grep -q 'done 100000/100000' && ok "the S3 channel row: the detail holds the stress line" || no "the S3 channel row: the detail does not hold the stress line: $_s3d"
	# a FAIL line of the probe: the row is a fail and the detail holds it
	s3case 'FAIL chan_probe exited 1 (nvrm-info/chan_probe.txt)' 'FAIL gpu 0 (0000:01:00.0) release: wait: the channel is dead (state dead, error 31)'
	s3summary
	_s3s=$(rowf "$T/s3run/summary.json" nvrm-s3-channel status)
	[ "$_s3s" = fail ] && ok "the S3 channel row: a probe that failed is a fail" || no "the S3 channel row: the fail fixture gave $_s3s"
	_s3d=$(rowf "$T/s3run/summary.json" nvrm-s3-channel detail)
	printf '%s' "$_s3d" | grep -q 'FAIL gpu 0' && ok "the S3 channel row: the detail holds the FAIL line" || no "the S3 channel row: the detail does not hold the FAIL line: $_s3d"
	# a channel that timed out: the row is a fail and the status is in the detail
	s3case 'FAIL chan_probe exited 1 (nvrm-info/chan_probe.txt)' 'FAIL gpu 0 (0000:01:00.0) isolation: the second channel is alive (state alive, error 0, gp_get 0, gp_put 2, submitted 1, completed 0)'
	s3summary
	_s3s=$(rowf "$T/s3run/summary.json" nvrm-s3-channel status)
	_s3d=$(rowf "$T/s3run/summary.json" nvrm-s3-channel detail)
	if [ "$_s3s" = fail ] && printf '%s' "$_s3d" | grep -q 'state alive'; then ok "the S3 channel row: a channel that did not die is a fail and the detail holds its status"
	else no "the S3 channel row: the timeout fixture gave $_s3s: $_s3d"; fi
else
	no "the S3 channel row: the row function of the rc script could not be read"
fi

# (e) make-be.sh with the hooks and a fake clone.  The stage belongs to this run, not to a previous build.
stage_error=
stage_file() {
	[ -s "$1" ] || { stage_error="$stage_error missing:$1"; return; }
	cp "$1" "$STAGE/${1##*/}" || stage_error="$stage_error copy:$1"
}
stage_step() {
	_ss_step=$1; shift
	if "$@" > "$T/$_ss_step.log" 2>&1; then return 0; fi
	_ss_keep=$WORK/tmp/nvnt-kit-failed-$_ss_step.log
	if cp "$T/$_ss_step.log" "$_ss_keep"; then
		echo "stage build step $_ss_step failed; log kept at $_ss_keep" >&2
	else
		echo "stage build step $_ss_step failed; could not keep a copy of its log at $_ss_keep" >&2
	fi
	return 1
}
stage_hashes() {
	_sh_out=$1
	: > "$_sh_out" || { echo "cannot write the stage hash list $_sh_out"; return 1; }
	for _sh_f in nvidia.ko nvidia-modeset.ko nvidia_gsp_ga10x_fw.ko nvrm-info libnvrm.so.1 mem_probe chan_probe; do
		_sh_hash=$(sha256 -q "$STAGE/$_sh_f" 2> /dev/null); _sh_s=$?
		[ "$_sh_s" = 0 ] || { echo "sha256 failed for $STAGE/$_sh_f (exit $_sh_s)"; return 1; }
		[ -n "$_sh_hash" ] || { echo "sha256 printed nothing for $STAGE/$_sh_f"; return 1; }
		printf 'SHA256 (%s) = %s\n' "$_sh_f" "$_sh_hash" >> "$_sh_out" || { echo "cannot append $_sh_f to $_sh_out"; return 1; }
	done
}
mkdir -p "$STAGE"
if [ -n "${NVNT_STAGE:-}" ]; then
	for _f in nvidia.ko nvidia-modeset.ko nvidia_gsp_ga10x_fw.ko nvrm-info libnvrm.so.1 mem_probe chan_probe; do stage_file "$NVNT_STAGE/$_f"; done
else
	# A prepared build/tree may predate the checkout.  Prepare and build this checkout in scratch instead; only the
	# expensive, already-built RM core objects and the pinned sources come from GB10_WORK.
	BW=$T/module-build
	if ! (
		mkdir -p "$BW/build" "$BW/logs" "$BW/tmp" &&
		ln -s "$WORK/sources" "$BW/sources" &&
		_nt_arch=$(uname -p)
		case $_nt_arch in
		x86_64) _nt_arch=amd64 ;;
		arm64) _nt_arch=aarch64 ;;
		esac
		cp "$WORK/build/nv-kernel-gb10.o" "$WORK/build/nv-modeset-kernel-${_nt_arch}.o" "$BW/build/" &&
		stage_step prepare-tree env GB10_WORK="$BW" TMPDIR="$BW/tmp" sh "$repo/scripts/prepare-tree.sh" &&
		stage_step build-nvidia env -u NV_CORE_LINUX_COMPAT -u NVKMS_CORE_LINUX_COMPAT GB10_WORK="$BW" TMPDIR="$BW/tmp" sh "$repo/scripts/build-shim.sh" &&
		stage_step build-firmware env GB10_WORK="$BW" TMPDIR="$BW/tmp" sh "$repo/scripts/build-firmware.sh" &&
		stage_step build-modeset env -u NV_CORE_LINUX_COMPAT -u NVKMS_CORE_LINUX_COMPAT GB10_WORK="$BW" TMPDIR="$BW/tmp" sh "$repo/scripts/build-shim.sh" --module=nvidia-modeset
	); then
		stage_error="$stage_error module-build-failed"
	else
		stage_file "$BW/build/tree/nvidia/nvidia.ko"
		stage_file "$BW/build/tree/nvidia-modeset/nvidia-modeset.ko"
		stage_file "$BW/build/tree/firmware/gsp_ga10x/nvidia_gsp_ga10x_fw.ko"
	fi
	_tag=$(awk '$1 == "ogkm_tag" { print $2; exit }' "$repo/SOURCES")
	_ogkm=$WORK/sources/open-gpu-kernel-modules-$_tag
	if [ ! -d "$_ogkm" ]; then
		stage_error="$stage_error missing:$_ogkm"
	else
		mkdir -p "$T/obj/lib" "$T/obj/info"
		if ! stage_step libnvrm-build env MAKEOBJDIR="$T/obj/lib" OGKM="$_ogkm" /usr/bin/make -C "$repo/lib/libnvrm"; then
			stage_error="$stage_error libnvrm-build-failed"
		elif ! stage_step nvrm-info-build env MAKEOBJDIR="$T/obj/info" LIBNVRM_OBJ="$T/obj/lib" /usr/bin/make -C "$repo/lib/libnvrm/nvrm-info"; then
			stage_error="$stage_error nvrm-info-build-failed"
		else
			stage_file "$T/obj/lib/libnvrm.so.1"
			stage_file "$T/obj/info/nvrm-info"
		fi
		# the probes of the S2 and S3 rows, built against the library that was just built: the same line as the suite's
		if ! stage_step probes sh "$repo/tests/libnvrm/build-probes.sh" "$T/obj/lib" "$STAGE"; then
			stage_error="$stage_error probes-build-failed"
		fi
	fi
fi
if [ -z "$stage_error" ]; then
	_sh_msg=$(stage_hashes "$SHAFILE") || stage_error="$stage_error $_sh_msg"
fi
if [ -z "$stage_error" ]; then
	mkdir -p "$T/sha256-fail"; printf '#!/bin/sh\nexit 1\n' > "$T/sha256-fail/sha256"; chmod 0755 "$T/sha256-fail/sha256"
	_sh_msg=$(PATH="$T/sha256-fail:$PATH" stage_hashes "$T/SHA256.fail"); _sh_s=$?
	expect 1 $_sh_s "the stage hash builder fails when sha256 fails"
	printf '%s\n' "$_sh_msg" | grep -q "sha256 failed for $STAGE/nvidia.ko" && ok "the stage hash failure names the file" || no "the stage hash failure is not clear: $_sh_msg"
	printf '#!/bin/sh\nexit 0\n' > "$T/sha256-fail/sha256"
	_sh_msg=$(PATH="$T/sha256-fail:$PATH" stage_hashes "$T/SHA256.empty"); _sh_s=$?
	expect 1 $_sh_s "the stage hash builder fails when sha256 prints nothing"
	printf '%s\n' "$_sh_msg" | grep -q "sha256 printed nothing for $STAGE/nvidia.ko" && ok "the empty stage hash failure names the file" || no "the empty stage hash failure is not clear: $_sh_msg"
fi
if [ -n "$stage_error" ]; then
	no "the test stage could not be made:$stage_error; provide the pinned sources and built RM cores, or set NVNT_STAGE"
else
	mkclone() {
		rm -rf "$1"; mkdir -p "$1/etc/rc.conf.d" "$1/boot/modules" "$1/boot/kernel" "$1/sbin" "$1/usr/local/etc/rc.d"
		printf 'hostname="t"\nlinux_enable="YES"\nkld_list="filemon amdgpu /boot/kernel/linux64.ko"\nother_testboot_enable="YES"\ndrm_ready_enable="YES"\ndrm_ready_modules="amdgpu"\ndrm_named_enable="YES"\ncloudbsd_hwprobe_enable="YES"\n' > "$1/etc/rc.conf"
		printf 'zfs_load="YES"\n' > "$1/boot/loader.conf"
		printf '#!/bin/sh\nexit 0\n' > "$1/sbin/shutdown"; chmod 0755 "$1/sbin/shutdown"
		mkdir -p "$1/usr/local/bin"; printf '#!/bin/sh\n' > "$1/usr/local/bin/python3"; chmod 0755 "$1/usr/local/bin/python3"
		# the users of the clone: the owner of the run directory must be one of them (the one-shot gives the run to
		# it with chown(8)), and the one the tests name
		# the home directories are the one FreeBSD gives system users: no home of a person, so no personal path
		printf 'root:*:0:0:root:/root:/bin/sh\n%s:*:%s:%s:%s:/nonexistent:/bin/sh\nkitowner:*:1002:1002:kitowner:/nonexistent:/bin/sh\n' \
		    "$(id -un)" "$(id -u)" "$(id -g)" "$(id -un)" > "$1/etc/master.passwd"
		# the two services of the base BE that load a driver by themselves: drm_ready through its required_modules
		# entry, the hwprobe through the probe it runs
		cat > "$1/usr/local/etc/rc.d/drm_ready" <<'EOF'
#!/bin/sh
# PROVIDE: drm_ready
# REQUIRE: kld
name="drm_ready"
rcvar="drm_ready_enable"
start_precmd="drm_ready_wait"
start_cmd=":"
stop_cmd=":"
load_rc_config $name
required_modules="${drm_ready_modules:-amdgpu}"
run_rc_command "$1"
EOF
		# the same, with the rcvar built from the name of the script: the common ports idiom
		cat > "$1/usr/local/etc/rc.d/drm_named" <<'EOF'
#!/bin/sh
# PROVIDE: drm_named
name="drm_named"
rcvar="${name}_enable"
load_rc_config $name
required_modules="amdgpu"
run_rc_command "$1"
EOF
		cat > "$1/usr/local/etc/rc.d/cloudbsd_hwprobe" <<'EOF'
#!/bin/sh
# PROVIDE: cloudbsd_hwprobe
name="cloudbsd_hwprobe"
rcvar="cloudbsd_hwprobe_enable"
start_cmd="cloudbsd_hwprobe_start"
stop_cmd=":"
: "${cloudbsd_hwprobe_enable:="NO"}"
: "${cloudbsd_hwprobe_command:="apply"}"
load_rc_config $name
run_rc_command "$1"
EOF
		chmod 0755 "$1/usr/local/etc/rc.d/drm_ready" "$1/usr/local/etc/rc.d/drm_named" "$1/usr/local/etc/rc.d/cloudbsd_hwprobe"
	}
	cat > "$T/bectl" <<EOF
#!/bin/sh
echo "bectl \$*" >> "$T/bectl.log"
case \$1 in list) printf 'cloudbsd-rx7600\tNR\nnvidia-native-tools-test-20990101-1\t-\n' ;; esac
exit 0
EOF
	chmod 0755 "$T/bectl"
	UVMKO=${NVNT_UVM_KO:-}
	DRMKO=${NVNT_DRM_KO:-}
	if [ -n "$UVMKO" ]; then UVM_WANT=needs-linux; else UVM_WANT=not-available; fi
	if [ -n "$DRMKO" ]; then PRIME_WANT=needs-linuxkpi; else PRIME_WANT=not-available; fi
	MB() {
		[ -z "$UVMKO" ] || set -- -u "$UVMKO" "$@"
		[ -z "$DRMKO" ] || set -- -d "$DRMKO" "$@"
		# DOAS_USER and SUDO_USER are unset: the owner of the run directory is then the owner of the copy-out
		# parent, which is what the test checks
		env -u DOAS_USER -u SUDO_USER GB10_TEST_HOOKS=1 NVNT_BECTL="$T/bectl" NVNT_MNT="$T/clone/root" NVNT_NOT_ROOT=1 NVNT_NO_GIT_CHECK=1 GB10_WORK="$WORK" sh "$KIT/make-be.sh" "$@"
	}
	for _opt in u d; do
		env GB10_TEST_HOOKS=1 NVNT_BECTL="$T/bectl" NVNT_MNT="$T/missing-$_opt/root" NVNT_NOT_ROOT=1 NVNT_NO_GIT_CHECK=1 GB10_WORK="$WORK" sh "$KIT/make-be.sh" -$_opt "$T/missing-$_opt.ko" > "$T/missing-$_opt.out" 2>&1
		expect 2 $? "make-be.sh -$_opt: a missing control module is a usage error"
		grep -q "control module $T/missing-$_opt.ko is missing or unreadable" "$T/missing-$_opt.out" && ok "make-be.sh -$_opt: the usage error names the missing control" || no "make-be.sh -$_opt: $(cat "$T/missing-$_opt.out")"
	done
	mkclone "$T/clone/root"
	MB -D 20990102 -m "$STAGE" -o "$WORK/logs/native-tools-testboot" > "$T/mb.out" 2>&1; expect 0 $? "make-be.sh builds the fake clone"
	R=$T/clone/root
	# G6: the clone's marker names the one-shot BE, is read-only, and is checked by check-be.sh.
	_marker=$R/usr/local/etc/nvidia_native_tools_testboot.marker
	[ "$(cat "$_marker" 2> /dev/null)" = nvidia-native-tools-test-20990102-1 ] && [ "$(stat -f %Lp "$_marker" 2> /dev/null)" = 444 ] \
	    && ok "G6 make-be.sh writes the BE marker with mode 0444" || no "G6 make-be.sh marker is '$(cat "$_marker" 2> /dev/null)', mode $(stat -f %Lp "$_marker" 2> /dev/null)"
	[ "$(sysrc -f "$R/etc/rc.conf" -n linux_enable)" = NO ] && ok "make-be.sh: linux_enable is NO" || no "make-be.sh: linux_enable is $(sysrc -f "$R/etc/rc.conf" -n linux_enable)"
	[ "$(sysrc -f "$R/etc/rc.conf" -n kld_list)" = filemon ] && ok "make-be.sh: amdgpu and linux64 are stripped from kld_list" || no "make-be.sh: kld_list is $(sysrc -f "$R/etc/rc.conf" -n kld_list)"
	sysrc -f "$R/etc/rc.conf" -n devmatch_blocklist | grep -q 'amdgpu .*linuxkpi' && ok "make-be.sh: devmatch_blocklist is set in rc.conf" || no "make-be.sh: no devmatch_blocklist in rc.conf"
	grep -q '^devmatch_blocklist=".*amdgpu' "$R/boot/loader.conf" && ok "make-be.sh: devmatch_blocklist kenv in loader.conf" || no "make-be.sh: no devmatch_blocklist kenv"
	grep -q '^other_testboot_enable="NO"' "$R/etc/rc.conf" && ok "make-be.sh: another kit is turned off" || no "make-be.sh: the other kit is still on"
	# an enabled rc.d service that loads a forbidden module by itself must be turned off in the clone
	[ "$(sysrc -f "$R/etc/rc.conf" -n drm_ready_enable)" = NO ] && ok "make-be.sh: the service whose required_modules loads amdgpu is turned off" || no "make-be.sh: drm_ready_enable is $(sysrc -f "$R/etc/rc.conf" -n drm_ready_enable)"
	grep -q '^disabled drm_ready: loads amdgpu' "$T/mb.out" && ok "make-be.sh: the disabled service and the module it loads are printed" || no "make-be.sh: the disabled service is not printed: $(grep -c disabled "$T/mb.out") disabled lines"
	[ "$(sysrc -f "$R/etc/rc.conf" -n drm_named_enable)" = NO ] && ok "make-be.sh: the service whose rcvar is built from its name is turned off" || no "make-be.sh: drm_named_enable is $(sysrc -f "$R/etc/rc.conf" -n drm_named_enable)"
	grep -q '^disabled drm_named: loads amdgpu' "$T/mb.out" && ok "make-be.sh: the service with rcvar=\${name}_enable is disabled and printed" || no "make-be.sh: the service with rcvar=\${name}_enable is not printed: $(grep '^disabled' "$T/mb.out")"
	[ "$(sysrc -f "$R/etc/rc.conf" -n cloudbsd_hwprobe_command)" = probe ] && ok "make-be.sh: the hwprobe service gets the command probe (it loads no KMS driver)" || no "make-be.sh: cloudbsd_hwprobe_command is $(sysrc -f "$R/etc/rc.conf" -n cloudbsd_hwprobe_command)"
	grep -q '^cloudbsd_hwprobe: command=probe' "$T/mb.out" && ok "make-be.sh: the hwprobe command is printed" || no "make-be.sh: the hwprobe command is not printed"
	_own=$(sed -n 's/^nvidia_native_tools_testboot_owner="\(.*\)"$/\1/p' "$R/etc/rc.conf.d/nvidia_native_tools_testboot" 2> /dev/null)
	[ -n "$_own" ] && ok "make-be.sh: the owner of the run directory is recorded ($_own)" || no "make-be.sh: no owner of the run directory is recorded"
	[ "$_own" = "$(stat -f %Su "$WORK/logs" 2> /dev/null)" ] && ok "make-be.sh: the recorded owner is the owner of the copy-out parent ($_own)" || no "make-be.sh: the recorded owner is '$_own', the copy-out parent is owned by $(stat -f %Su "$WORK/logs" 2> /dev/null)"
	# the two channel knobs of the one-shot, with their defaults
	_cst=$(sed -n 's/^nvidia_native_tools_testboot_chan_stress="\(.*\)"$/\1/p' "$R/etc/rc.conf.d/nvidia_native_tools_testboot" 2> /dev/null)
	[ "$_cst" = 100000 ] && ok "make-be.sh: the channel stress count is written to rc.conf.d ($_cst)" || no "make-be.sh: the channel stress count is '${_cst:-unset}', wanted 100000"
	_css=$(sed -n 's/^nvidia_native_tools_testboot_chan_stress_seconds="\(.*\)"$/\1/p' "$R/etc/rc.conf.d/nvidia_native_tools_testboot" 2> /dev/null)
	[ "$_css" = 300 ] && ok "make-be.sh: the channel stress seconds are written to rc.conf.d ($_css)" || no "make-be.sh: the channel stress seconds are '${_css:-unset}', wanted 300"
	for _f in nvidia.ko nvidia-modeset.ko nvidia_gsp_ga10x_fw.ko nvrm-info libnvrm.so.1 mem_probe chan_probe; do
		cmp -s "$STAGE/$_f" "$R/boot/modules.nvnative-test/$_f" && ok "make-be.sh: $_f is installed" || no "make-be.sh: $_f is not installed"
	done
	[ "$(head -1 "$R/usr/local/share/nvidia-native-tools-test/static-rows/uvm-ioctl-suite" 2> /dev/null)" = "$UVM_WANT" ] && ok "make-be.sh: the uvm row is $UVM_WANT" || no "make-be.sh: the uvm row is $(head -1 "$R/usr/local/share/nvidia-native-tools-test/static-rows/uvm-ioctl-suite" 2> /dev/null), wanted $UVM_WANT"
	[ "$(head -1 "$R/usr/local/share/nvidia-native-tools-test/static-rows/prime-import" 2> /dev/null)" = "$PRIME_WANT" ] && ok "make-be.sh: the PRIME row is $PRIME_WANT" || no "make-be.sh: the PRIME row is $(head -1 "$R/usr/local/share/nvidia-native-tools-test/static-rows/prime-import" 2> /dev/null), wanted $PRIME_WANT"
	# Synthetic controls always cover classification, without depending on a historical module or a personal dataset.
	: > "$T/synthetic-uvm.ko"; : > "$T/synthetic-drm.ko"; mkdir -p "$T/classify-stub"
	cat > "$T/classify-stub/kldxref" <<'EOF'
#!/bin/sh
for _d do :; done
for _k in "$_d"/*; do
	_n=${_k##*/}; printf '  module %s\n' "${_n%.ko}"
	case $_n in
	synthetic-uvm.ko) printf '    depends on kernel.\n    depends on linux64elf.\n' ;;
	synthetic-drm.ko) printf '    depends on kernel.\n    depends on linuxkpi.\n' ;;
	*) printf '    depends on kernel.\n' ;;
	esac
done
EOF
	cat > "$T/classify-stub/nm" <<'EOF'
#!/bin/sh
for _k do :; done
case ${_k##*/} in
synthetic-uvm.ko) printf '                 U linux_uvm_synthetic\n' ;;
synthetic-drm.ko) printf '                 U linuxkpi_drm_synthetic\n' ;;
*) printf '                 U printf\n' ;;
esac
EOF
	chmod 0755 "$T/classify-stub/kldxref" "$T/classify-stub/nm"
	mkclone "$T/clone-synthetic/root"
	env GB10_TEST_HOOKS=1 NVNT_BECTL="$T/bectl" NVNT_MNT="$T/clone-synthetic/root" NVNT_NOT_ROOT=1 NVNT_NO_GIT_CHECK=1 NVNT_TEST_PATH="$T/classify-stub" GB10_WORK="$WORK" sh "$KIT/make-be.sh" -u "$T/synthetic-uvm.ko" -d "$T/synthetic-drm.ko" -D 20990106 -m "$STAGE" -s "$SHAFILE" -o "$WORK/logs/native-tools-testboot" > "$T/mb-synthetic.out" 2>&1
	expect 0 $? "make-be.sh classifies synthetic controls with stubbed kldxref and nm"
	_sr=$T/clone-synthetic/root/usr/local/share/nvidia-native-tools-test/static-rows
	[ "$(head -1 "$_sr/uvm-ioctl-suite" 2> /dev/null)" = needs-linux ] && grep -q 'linux64elf' "$_sr/uvm-ioctl-suite" && ok "make-be.sh: a Linux dependency makes the uvm row needs-linux" || no "make-be.sh: the synthetic uvm row is $(head -2 "$_sr/uvm-ioctl-suite" 2> /dev/null)"
	[ "$(head -1 "$_sr/prime-import" 2> /dev/null)" = needs-linuxkpi ] && grep -q 'linuxkpi_drm_synthetic' "$_sr/prime-import" && ok "make-be.sh: a LinuxKPI importer makes the PRIME row needs-linuxkpi" || no "make-be.sh: the synthetic PRIME row is $(head -2 "$_sr/prime-import" 2> /dev/null)"
	grep -q 'bectl activate' "$T/bectl.log" && no "make-be.sh armed the boot without --activate" || ok "make-be.sh does not arm without --activate"
	env TMPDIR="$T" GB10_TEST_HOOKS=1 NVNT_NO_GIT_CHECK=1 sh "$KIT/check-be.sh" -m "$R" -U -s "$SHAFILE" > "$T/cb.out" 2>&1
	# the commit comparisons (the version file, the files of the commit, the VENDOR pins read from the commit) cannot
	# pass for a work tree installed with NVNT_NO_GIT_CHECK; every other check must
	_cbf=$(grep '^FAIL' "$T/cb.out" | grep -v 'differs from the one of commit' | grep -v 'the clone records' | grep -v 'does not equal its VENDOR pin')
	[ -z "$_cbf" ] && ok "check-be.sh: every check but the commit comparison passes on the fake clone ($(grep -c '^ok' "$T/cb.out") ok)" || no "check-be.sh on the fake clone: $_cbf"
	# the clone holds seven staged files: the hash list counts seven and the probes are two of them
	grep -q '^ok   the list holds seven entries' "$T/cb.out" && ok "check-be.sh: the hash list of the clone holds seven entries" || no "check-be.sh: the list of the clone does not hold seven entries: $(grep 'entries' "$T/cb.out")"
	grep -q '^ok   mem_probe is ' "$T/cb.out" && ok "check-be.sh: mem_probe is checked in the clone" || no "check-be.sh: mem_probe is not checked in the clone: $(grep 'mem_probe' "$T/cb.out")"
	grep -q '^ok   chan_probe is ' "$T/cb.out" && ok "check-be.sh: chan_probe is checked in the clone" || no "check-be.sh: chan_probe is not checked in the clone: $(grep 'chan_probe' "$T/cb.out")"
	# a list of six files is refused: the kit stages seven
	head -6 "$SHAFILE" > "$T/SHA256.six"
	env TMPDIR="$T" GB10_TEST_HOOKS=1 NVNT_NO_GIT_CHECK=1 sh "$KIT/check-be.sh" -m "$R" -U -s "$T/SHA256.six" > "$T/cb-six.out" 2>&1
	grep -q 'does not hold exactly seven SHA256 entries' "$T/cb-six.out" && ok "check-be.sh: a hash list of six files is refused" || no "check-be.sh: a hash list of six files is not refused: $(grep 'entries' "$T/cb-six.out")"
	# the clone with the service that loads amdgpu by itself enabled again: check-be.sh must refuse it, naming the
	# service and the module, and the fixed clone must pass
	sysrc -f "$R/etc/rc.conf" drm_ready_enable=YES > /dev/null
	env TMPDIR="$T" GB10_TEST_HOOKS=1 NVNT_NO_GIT_CHECK=1 sh "$KIT/check-be.sh" -m "$R" -U -s "$SHAFILE" > "$T/cb-drm.out" 2>&1
	grep -q '^FAIL the rc.d service drm_ready (drm_ready_enable) is enabled and its required_modules loads amdgpu' "$T/cb-drm.out" \
	    && ok "check-be.sh: a clone with drm_ready enabled is a FAIL that names the service and the module" \
	    || no "check-be.sh: the clone with drm_ready enabled is not refused: $(grep '^FAIL' "$T/cb-drm.out" | head -3)"
	sysrc -f "$R/etc/rc.conf" drm_ready_enable=NO > /dev/null
	env TMPDIR="$T" GB10_TEST_HOOKS=1 NVNT_NO_GIT_CHECK=1 sh "$KIT/check-be.sh" -m "$R" -U -s "$SHAFILE" > "$T/cb-drm-fixed.out" 2>&1
	_cbf2=$(grep '^FAIL' "$T/cb-drm-fixed.out" | grep -v 'differs from the one of commit' | grep -v 'the clone records' | grep -v 'does not equal its VENDOR pin')
	[ -z "$_cbf2" ] && ok "check-be.sh: the clone with drm_ready turned off passes" || no "check-be.sh on the fixed clone: $_cbf2"
	# the hwprobe service loads the KMS driver of the card it finds, unless its command is probe
	sysrc -f "$R/etc/rc.conf" cloudbsd_hwprobe_command=apply > /dev/null
	env TMPDIR="$T" GB10_TEST_HOOKS=1 NVNT_NO_GIT_CHECK=1 sh "$KIT/check-be.sh" -m "$R" -U -s "$SHAFILE" > "$T/cb-hp.out" 2>&1
	grep -q '^FAIL cloudbsd_hwprobe is enabled with command' "$T/cb-hp.out" \
	    && ok "check-be.sh: an enabled cloudbsd_hwprobe without the command probe is a FAIL" \
	    || no "check-be.sh: the clone with the hwprobe command apply is not refused: $(grep '^FAIL' "$T/cb-hp.out" | head -3)"
	sysrc -f "$R/etc/rc.conf" cloudbsd_hwprobe_command=probe > /dev/null
	env TMPDIR="$T" GB10_TEST_HOOKS=1 NVNT_NO_GIT_CHECK=1 sh "$KIT/check-be.sh" -m "$R" -U -s "$SHAFILE" > "$T/cb-hp-fixed.out" 2>&1
	_cbf3=$(grep '^FAIL' "$T/cb-hp-fixed.out" | grep -v 'differs from the one of commit' | grep -v 'the clone records' | grep -v 'does not equal its VENDOR pin')
	[ -z "$_cbf3" ] && ok "check-be.sh: the clone with the hwprobe command probe passes" || no "check-be.sh on the clone with the hwprobe command probe: $_cbf3"
	# a service whose modules cannot be read is a FAIL: a service that is not read is a service that is not known
	cat > "$R/usr/local/etc/rc.d/drm_unknown" <<'EOF'
#!/bin/sh
name="drm_unknown"
rcvar="drm_unknown_enable"
required_modules="${drm_unknown_modules}"
EOF
	chmod 0755 "$R/usr/local/etc/rc.d/drm_unknown"
	env TMPDIR="$T" GB10_TEST_HOOKS=1 NVNT_NO_GIT_CHECK=1 sh "$KIT/check-be.sh" -m "$R" -U -s "$SHAFILE" > "$T/cb-unknown.out" 2>&1
	grep -q '^FAIL the rc.d service drm_unknown has a required_modules entry that could not be read' "$T/cb-unknown.out" \
	    && ok "check-be.sh: a service whose modules cannot be read is a FAIL" \
	    || no "check-be.sh: the service that cannot be read is not refused: $(grep '^FAIL' "$T/cb-unknown.out" | head -3)"
	rm -f "$R/usr/local/etc/rc.d/drm_unknown"
	# a devd rule that loads a driver by itself is a FAIL
	mkdir -p "$R/usr/local/etc/devd"
	cat > "$R/usr/local/etc/devd/cloudbsd-gpu-hotplug.conf" <<'EOF'
attach 100 {
	match "class" "0x03.*";
	match "vendor" "0x1002";
	action "/usr/sbin/kldload -v /boot/kernel/amdgpu.ko";
};
EOF
	env TMPDIR="$T" GB10_TEST_HOOKS=1 NVNT_NO_GIT_CHECK=1 sh "$KIT/check-be.sh" -m "$R" -U -s "$SHAFILE" > "$T/cb-devd.out" 2>&1
	grep -q '^FAIL the devd rule cloudbsd-gpu-hotplug.conf kldloads' "$T/cb-devd.out" \
	    && ok "check-be.sh: a devd rule that loads a driver by itself is a FAIL" \
	    || no "check-be.sh: the devd rule that loads a driver is not refused: $(grep '^FAIL' "$T/cb-devd.out" | head -3)"
	rm -rf "$R/usr/local/etc/devd"
	# a devd rule that starts a service which loads a driver by itself is a loader too: service X onestart runs the
	# service even when its rcvar is NO, so the rule is refused although the service itself is off in the clone
	mkdir -p "$R/usr/local/etc/devd"
	cat > "$R/usr/local/etc/devd/drm-hotplug.conf" <<'EOF'
attach 100 {
	match "class" "0x03.*";
	match "vendor" "0x1002";
	action "/usr/sbin/service drm_ready quietstart &";
};
EOF
	env TMPDIR="$T" GB10_TEST_HOOKS=1 NVNT_NO_GIT_CHECK=1 sh "$KIT/check-be.sh" -m "$R" -U -s "$SHAFILE" > "$T/cb-devd2.out" 2>&1
	grep -q '^FAIL the devd rule drm-hotplug.conf starts drm_ready' "$T/cb-devd2.out" \
	    && ok "check-be.sh: a devd rule that starts a service which loads a driver is a FAIL" \
	    || no "check-be.sh: the devd rule that starts a driver-loading service is not refused: $(grep '^FAIL' "$T/cb-devd2.out" | head -3)"
	rm -rf "$R/usr/local/etc/devd"
	# the owner of the run directory must be a user of the boot environment
	sed -i.bak 's/^nvidia_native_tools_testboot_owner=.*/nvidia_native_tools_testboot_owner="nobodyhere"/' "$R/etc/rc.conf.d/nvidia_native_tools_testboot" 2> /dev/null
	env TMPDIR="$T" GB10_TEST_HOOKS=1 NVNT_NO_GIT_CHECK=1 sh "$KIT/check-be.sh" -m "$R" -U -s "$SHAFILE" > "$T/cb-owner.out" 2>&1
	grep -q '^FAIL the owner of the run directory (nobodyhere) is not a user of this boot environment' "$T/cb-owner.out" \
	    && ok "check-be.sh: an owner that is not a user of the boot environment is a FAIL" \
	    || no "check-be.sh: the owner that is not a user of the boot environment is not refused: $(grep '^FAIL' "$T/cb-owner.out" | head -3)"
	mv "$R/etc/rc.conf.d/nvidia_native_tools_testboot.bak" "$R/etc/rc.conf.d/nvidia_native_tools_testboot"
	chmod u+w "$_marker"; printf 'wrong-be\n' > "$_marker"
	env TMPDIR="$T" GB10_TEST_HOOKS=1 NVNT_NO_GIT_CHECK=1 sh "$KIT/check-be.sh" -m "$R" -U -s "$SHAFILE" > "$T/cb-marker-mutant.out" 2>&1
	grep -q "^FAIL the marker holds 'wrong-be'" "$T/cb-marker-mutant.out" && ok "G6 control: a wrong marker is seen" || no "G6 control: check-be.sh did not reject the wrong marker"
	printf 'nvidia-native-tools-test-20990102-1\n' > "$_marker"; chmod 0444 "$_marker"
	# F1 control: an rc.conf.local that sets the shutdown override is refused by check-be.sh
	printf 'nvidia_native_tools_testboot_shutdown="/usr/bin/true"\n' > "$R/etc/rc.conf.local"
	env TMPDIR="$T" GB10_TEST_HOOKS=1 NVNT_NO_GIT_CHECK=1 sh "$KIT/check-be.sh" -m "$R" -U -s "$SHAFILE" > "$T/cb-ovr-mutant.out" 2>&1
	grep -q "^FAIL dead-man: an rc.conf file of the clone sets nvidia_native_tools_testboot_shutdown" "$T/cb-ovr-mutant.out" && ok "F1 control: a shutdown override in rc.conf.local is seen by check-be.sh" || no "F1 control: check-be.sh did not reject the shutdown override"
	rm -f "$R/etc/rc.conf.local"
	# G2 (fix 3): the shared detector file is used by BOTH check-be.sh and the host test; a blinded copy makes each miss a planted bare call
	_rcins=$R/usr/local/etc/rc.d/nvidia_native_tools_testboot
	if [ -f "$_rcins" ]; then
		cp "$_rcins" "$T/rc-installed.orig"; chmod u+w "$_rcins" "$R/usr/local/etc/rc.d" 2> /dev/null
		printf '%s\n' 'sh -c "shutdown -r now"' >> "$_rcins"
		env TMPDIR="$T" GB10_TEST_HOOKS=1 NVNT_NO_GIT_CHECK=1 sh "$KIT/check-be.sh" -m "$R" -U -s "$SHAFILE" > "$T/cb-m6.out" 2>&1
		grep -q "^FAIL dead-man: the installed rc script contains a bare shutdown call" "$T/cb-m6.out" && ok "check-be.sh sees a planted sh -c shutdown call (shared detector)" || no "check-be.sh does not see a planted sh -c shutdown call"
		mkdir -p "$T/kit-blind/tests"; cp -R "$KIT" "$T/kit-blind/tests/native-tools-testboot"
		_kb=$T/kit-blind/tests/native-tools-testboot
		printf 'bare_shutdown_lines() {\n\treturn 0\n}\n' > "$_kb/bare-shutdown-check.sh"
		if cmp -s "$KIT/bare-shutdown-check.sh" "$_kb/bare-shutdown-check.sh"; then no "control: the blinded shared detector does not differ"; else
			env TMPDIR="$T" GB10_TEST_HOOKS=1 NVNT_NO_GIT_CHECK=1 sh "$_kb/check-be.sh" -m "$R" -U -s "$SHAFILE" > "$T/cb-blind.out" 2>&1
			grep -q "^ok   dead-man: the installed rc script contains no bare shutdown call" "$T/cb-blind.out" && ok "control: a blinded shared detector makes check-be.sh miss the planted call (seen)" || no "control: check-be.sh still saw the call with a blinded shared detector: the file is not what it sources"
			( . "$_kb/bare-shutdown-check.sh"; [ -z "$(bare_shutdown_lines "$_rcins")" ] ) && ok "control: a blinded shared detector makes the host test miss the planted call (seen)" || no "control: the host test still sees the planted call with a blinded shared detector"
			[ -n "$(bare_shutdown_lines "$_rcins")" ] && ok "the real shared detector sees the same planted call in the host test" || no "the real shared detector misses the planted call in the host test"
		fi
		cp "$T/rc-installed.orig" "$_rcins"
	else
		no "G2 the installed rc script is not in the fake clone"
	fi
	for _f in gpu-detect.sh testboot-return; do
		_w=$(awk -v f="$_f" '$1 == "file" && $3 == f { on = 1; next } $1 == "file" { on = 0 } on && $1 == "sha256" { print $3; exit }' "$KIT/VENDOR")
		[ "$(sha256 -q "$KIT/$_f")" = "$_w" ] && ok "$_f of the work tree equals its VENDOR pin" || no "$_f of the work tree differs from its VENDOR pin"
	done
	# controls
	mkclone "$T/clone2/root"; printf 'linux_load="YES"\n' >> "$T/clone2/root/boot/loader.conf"
	env GB10_TEST_HOOKS=1 NVNT_BECTL="$T/bectl" NVNT_MNT="$T/clone2/root" NVNT_NOT_ROOT=1 NVNT_NO_GIT_CHECK=1 sh "$KIT/make-be.sh" -D 20990102 -m "$STAGE" > "$T/mb2.out" 2>&1
	expect 1 $? "make-be.sh refuses a base whose loader.conf loads linux"
	# the copy-out parent is owned by root and nobody says who the user is: the run directory would be root-owned and
	# unreadable by the person who has to read it
	_bcl=$(wc -l < "$T/bectl.log" 2> /dev/null || echo 0)
	mkclone "$T/clone-owner/root"
	env -u DOAS_USER -u SUDO_USER GB10_TEST_HOOKS=1 NVNT_BECTL="$T/bectl" NVNT_MNT="$T/clone-owner/root" NVNT_NOT_ROOT=1 NVNT_NO_GIT_CHECK=1 GB10_WORK="$WORK" sh "$KIT/make-be.sh" -D 20990107 -m "$STAGE" -o /usr/local/etc/nvnt-testboot-owner > "$T/mb-owner.out" 2>&1
	expect 2 $? "make-be.sh refuses a copy-out whose parent is owned by root when nobody says who the user is"
	grep -q 'is root and neither DOAS_USER nor SUDO_USER is set' "$T/mb-owner.out" && ok "make-be.sh: the refusal of the root-owned copy-out parent says why" || no "make-be.sh: the refusal is not clear: $(head -2 "$T/mb-owner.out")"
	[ "$(wc -l < "$T/bectl.log" 2> /dev/null || echo 0)" = "$_bcl" ] && ok "make-be.sh: the refused run created no boot environment" || no "make-be.sh: the refused run still called bectl"
	# the channel knobs of the one-shot: -c and -C reach rc.conf.d
	mkclone "$T/clone-chan/root"
	env -u DOAS_USER -u SUDO_USER GB10_TEST_HOOKS=1 NVNT_BECTL="$T/bectl" NVNT_MNT="$T/clone-chan/root" NVNT_NOT_ROOT=1 NVNT_NO_GIT_CHECK=1 GB10_WORK="$WORK" sh "$KIT/make-be.sh" -D 20990103 -m "$STAGE" -c 500 -C 10 > "$T/mb-chan.out" 2>&1
	expect 0 $? "make-be.sh builds the fake clone with the channel knobs"
	_cst=$(sed -n 's/^nvidia_native_tools_testboot_chan_stress="\(.*\)"$/\1/p' "$T/clone-chan/root/etc/rc.conf.d/nvidia_native_tools_testboot" 2> /dev/null)
	_css=$(sed -n 's/^nvidia_native_tools_testboot_chan_stress_seconds="\(.*\)"$/\1/p' "$T/clone-chan/root/etc/rc.conf.d/nvidia_native_tools_testboot" 2> /dev/null)
	[ "$_cst" = 500 ] && [ "$_css" = 10 ] && ok "make-be.sh: -c and -C reach rc.conf.d ($_cst releases, $_css seconds)" || no "make-be.sh: -c and -C wrote '$_cst' and '$_css' to rc.conf.d, wanted 500 and 10"
	# a later rc.conf file that enables the service again: make-be.sh cannot turn it off and must refuse the base
	mkclone "$T/clone-drmready/root"; printf 'drm_ready_enable="YES"\n' > "$T/clone-drmready/root/etc/rc.conf.local"
	env -u DOAS_USER -u SUDO_USER GB10_TEST_HOOKS=1 NVNT_BECTL="$T/bectl" NVNT_MNT="$T/clone-drmready/root" NVNT_NOT_ROOT=1 NVNT_NO_GIT_CHECK=1 GB10_WORK="$WORK" sh "$KIT/make-be.sh" -D 20990109 -m "$STAGE" > "$T/mb-drmready.out" 2>&1
	expect 1 $? "make-be.sh refuses a base whose rc.conf.local enables a service that loads a forbidden module"
	grep -q 'is still enabled and its required_modules loads amdgpu' "$T/mb-drmready.out" && ok "make-be.sh: the refusal names the service and the module" || no "make-be.sh: the refusal is not clear: $(tail -2 "$T/mb-drmready.out")"
	# with DOAS_USER the owner is the one doas names
	mkclone "$T/clone-owner2/root"
	env DOAS_USER=kitowner GB10_TEST_HOOKS=1 NVNT_BECTL="$T/bectl" NVNT_MNT="$T/clone-owner2/root" NVNT_NOT_ROOT=1 NVNT_NO_GIT_CHECK=1 GB10_WORK="$WORK" sh "$KIT/make-be.sh" -D 20990108 -m "$STAGE" > "$T/mb-owner2.out" 2>&1
	expect 0 $? "make-be.sh builds the clone with the owner doas names"
	_o2=$(sed -n 's/^nvidia_native_tools_testboot_owner="\(.*\)"$/\1/p' "$T/clone-owner2/root/etc/rc.conf.d/nvidia_native_tools_testboot" 2> /dev/null)
	[ "$_o2" = kitowner ] && ok "make-be.sh: DOAS_USER is the recorded owner of the run directory" || no "make-be.sh: the recorded owner is '$_o2', DOAS_USER said kitowner: $(tail -2 "$T/mb-owner2.out")"
	# an owner name that starts with a dash would be read as an option by chown(8)
	mkclone "$T/clone-owner3/root"
	env DOAS_USER=-h GB10_TEST_HOOKS=1 NVNT_BECTL="$T/bectl" NVNT_MNT="$T/clone-owner3/root" NVNT_NOT_ROOT=1 NVNT_NO_GIT_CHECK=1 GB10_WORK="$WORK" sh "$KIT/make-be.sh" -D 20990111 -m "$STAGE" > "$T/mb-owner3.out" 2>&1
	expect 2 $? "make-be.sh refuses an owner name that starts with a dash"
	grep -q 'starts with a dash' "$T/mb-owner3.out" && ok "make-be.sh: the refusal of a dash in the owner name says why" || no "make-be.sh: the refusal is not clear: $(head -2 "$T/mb-owner3.out")"
	# a number is not a user name, and 0 would bypass the root rule
	mkclone "$T/clone-owner4/root"
	env DOAS_USER=0 GB10_TEST_HOOKS=1 NVNT_BECTL="$T/bectl" NVNT_MNT="$T/clone-owner4/root" NVNT_NOT_ROOT=1 NVNT_NO_GIT_CHECK=1 GB10_WORK="$WORK" sh "$KIT/make-be.sh" -D 20990112 -m "$STAGE" > "$T/mb-owner4.out" 2>&1
	expect 2 $? "make-be.sh refuses a number as the owner name"
	grep -q 'a number is not a user name' "$T/mb-owner4.out" && ok "make-be.sh: the refusal of a number as the owner says why" || no "make-be.sh: the refusal is not clear: $(head -2 "$T/mb-owner4.out")"
	# the owner must be a user of the boot environment: the one-shot gives the run to it with chown(8)
	mkclone "$T/clone-owner5/root"
	env DOAS_USER=nobodyhere GB10_TEST_HOOKS=1 NVNT_BECTL="$T/bectl" NVNT_MNT="$T/clone-owner5/root" NVNT_NOT_ROOT=1 NVNT_NO_GIT_CHECK=1 GB10_WORK="$WORK" sh "$KIT/make-be.sh" -D 20990113 -m "$STAGE" > "$T/mb-owner5.out" 2>&1
	expect 1 $? "make-be.sh refuses an owner that is not a user of the boot environment"
	grep -q 'is not a user of this boot environment' "$T/mb-owner5.out" && ok "make-be.sh: the refusal of an unknown owner says why" || no "make-be.sh: the refusal is not clear: $(tail -2 "$T/mb-owner5.out")"
	# a service whose modules cannot be read is refused, not ignored
	mkclone "$T/clone-unknown/root"
	cat > "$T/clone-unknown/root/usr/local/etc/rc.d/drm_unknown" <<'EOF'
#!/bin/sh
name="drm_unknown"
rcvar="drm_unknown_enable"
required_modules="${drm_unknown_modules}"
EOF
	chmod 0755 "$T/clone-unknown/root/usr/local/etc/rc.d/drm_unknown"
	env -u DOAS_USER -u SUDO_USER GB10_TEST_HOOKS=1 NVNT_BECTL="$T/bectl" NVNT_MNT="$T/clone-unknown/root" NVNT_NOT_ROOT=1 NVNT_NO_GIT_CHECK=1 GB10_WORK="$WORK" sh "$KIT/make-be.sh" -D 20990114 -m "$STAGE" > "$T/mb-unknown.out" 2>&1
	expect 1 $? "make-be.sh refuses a base with a service whose required_modules cannot be read"
	grep -q 'drm_unknown has a required_modules entry that could not be read' "$T/mb-unknown.out" && ok "make-be.sh: the refusal names the service that cannot be read" || no "make-be.sh: the refusal is not clear: $(tail -2 "$T/mb-unknown.out")"
	# a devd rule that starts a service which loads a driver by itself is refused: devd runs it when the device
	# appears, and the kit cannot make such a rule safe
	mkclone "$T/clone-devd/root"
	mkdir -p "$T/clone-devd/root/usr/local/etc/devd"
	cat > "$T/clone-devd/root/usr/local/etc/devd/drm-hotplug.conf" <<'EOF'
attach 100 {
	match "class" "0x03.*";
	match "vendor" "0x1002";
	action "/usr/sbin/service drm_ready quietstart &";
};
EOF
	env -u DOAS_USER -u SUDO_USER GB10_TEST_HOOKS=1 NVNT_BECTL="$T/bectl" NVNT_MNT="$T/clone-devd/root" NVNT_NOT_ROOT=1 NVNT_NO_GIT_CHECK=1 GB10_WORK="$WORK" sh "$KIT/make-be.sh" -D 20990117 -m "$STAGE" > "$T/mb-devd.out" 2>&1
	expect 1 $? "make-be.sh refuses a base with a devd rule that starts a service which loads a driver"
	grep -q 'the devd rule drm-hotplug.conf starts drm_ready' "$T/mb-devd.out" && ok "make-be.sh: the refusal names the devd rule and the service" || no "make-be.sh: the refusal is not clear: $(tail -2 "$T/mb-devd.out")"
	# the control: the same base without that rule is built, so the refusal is the rule and nothing else
	mkclone "$T/clone-devd2/root"
	env -u DOAS_USER -u SUDO_USER GB10_TEST_HOOKS=1 NVNT_BECTL="$T/bectl" NVNT_MNT="$T/clone-devd2/root" NVNT_NOT_ROOT=1 NVNT_NO_GIT_CHECK=1 GB10_WORK="$WORK" sh "$KIT/make-be.sh" -D 20990118 -m "$STAGE" > "$T/mb-devd2.out" 2>&1
	expect 0 $? "control: make-be.sh builds the same base without the devd rule"
	# the owner of the copy-out parent cannot be read: the refusal says so, and does not claim the owner is root
	mkdir -p "$T/stub-stat"
	printf '#!/bin/sh\nexit 1\n' > "$T/stub-stat/stat"; chmod 0755 "$T/stub-stat/stat"
	mkclone "$T/clone-owner6/root"
	env -u DOAS_USER -u SUDO_USER GB10_TEST_HOOKS=1 NVNT_BECTL="$T/bectl" NVNT_MNT="$T/clone-owner6/root" NVNT_NOT_ROOT=1 NVNT_NO_GIT_CHECK=1 NVNT_TEST_PATH="$T/stub-stat" GB10_WORK="$WORK" sh "$KIT/make-be.sh" -D 20990116 -m "$STAGE" -o "$T/copyout-owner6/out" > "$T/mb-owner6.out" 2>&1
	expect 2 $? "make-be.sh refuses a copy-out whose parent cannot be read"
	grep -q 'could not be read' "$T/mb-owner6.out" && ok "make-be.sh: the refusal of an unreadable copy-out parent says so" || no "make-be.sh: the refusal is not clear: $(head -2 "$T/mb-owner6.out")"
	grep -q 'is root' "$T/mb-owner6.out" && no "make-be.sh: the refusal claims the parent is root although it could not be read" || ok "make-be.sh: the refusal does not claim the parent is root"
	# the hwprobe command must really be probe: another rc.conf file of the base may set it again
	mkclone "$T/clone-hwprobe/root"; printf 'cloudbsd_hwprobe_command="apply"\n' > "$T/clone-hwprobe/root/etc/rc.conf.local"
	env -u DOAS_USER -u SUDO_USER GB10_TEST_HOOKS=1 NVNT_BECTL="$T/bectl" NVNT_MNT="$T/clone-hwprobe/root" NVNT_NOT_ROOT=1 NVNT_NO_GIT_CHECK=1 GB10_WORK="$WORK" sh "$KIT/make-be.sh" -D 20990115 -m "$STAGE" > "$T/mb-hwprobe.out" 2>&1
	expect 1 $? "make-be.sh refuses a base whose rc.conf.local sets the hwprobe command back to apply"
	grep -q 'cloudbsd_hwprobe_command is' "$T/mb-hwprobe.out" && ok "make-be.sh: the refusal names the hwprobe command" || no "make-be.sh: the refusal is not clear: $(tail -2 "$T/mb-hwprobe.out")"
	sh "$KIT/make-be.sh" -h > "$T/help.out" 2>&1; grep -q 'NVNT_NO_GIT_CHECK (the work tree is installed)' "$T/help.out" && ok "make-be.sh -h prints the whole header" || no "make-be.sh -h is cut short"
	grep -q "logs/native-tools-testboot" "$R/etc/rc.conf.d/nvidia_native_tools_testboot" && grep -q "^nvidia_native_tools_testboot_copyout=\"$WORK/logs/native-tools-testboot\"" "$R/etc/rc.conf.d/nvidia_native_tools_testboot" && ok "make-be.sh: the copy-out is under GB10_WORK by default" || no "make-be.sh: copy-out $(grep copyout "$R/etc/rc.conf.d/nvidia_native_tools_testboot")"
	# the VRAM reserve (make-be.sh -R): written to rc.conf.d (the board default), checked by check-be.sh, malformed refused
	grep -q "^nvidia_native_tools_testboot_vram_reserve=\"$BOARD_VRAM_RESERVE_MAX_BYTES\"\$" "$R/etc/rc.conf.d/nvidia_native_tools_testboot" && ok "make-be.sh: the VRAM reserve is written to rc.conf.d (the board default)" || no "make-be.sh: no default VRAM reserve in rc.conf.d: $(cat "$R/etc/rc.conf.d/nvidia_native_tools_testboot")"
	grep -q 'RESERVE_BYTES' "$T/help.out" && ok "make-be.sh -h documents -R" || no "make-be.sh -h does not document -R"
	MB -D 20990105 -m "$STAGE" -R 12G > "$T/mb7.out" 2>&1; expect 2 $? "make-be.sh refuses a -R that is not a number of bytes"
	MB -D 20990106 -m "$STAGE" -V 268435456 -R 268435456 > "$T/mb8.out" 2>&1; expect 2 $? "make-be.sh refuses a -R that is not below -V (the boot would reject it)"
	grep -q 'must be below -V' "$T/mb8.out" && ok "make-be.sh: the -R refusal says -R must be below -V" || no "make-be.sh: -R refusal text: $(cat "$T/mb8.out")"
	MB -D 20990106 -m "$STAGE" -V 100 -R 100 > "$T/mb9.out" 2>&1; expect 2 $? "make-be.sh refuses -V 100 -R 100"
	MB -D 20990106 -m "$STAGE" -V 0 -R 268435456 --dry-run > "$T/mb10.out" 2>&1; _rc=$?
	if [ "$_rc" -ne 2 ] && ! grep -q 'must be below -V' "$T/mb10.out"; then ok "make-be.sh accepts any -R when -V is 0"; else no "make-be.sh refused -V 0 -R 268435456: $(cat "$T/mb10.out")"; fi
	grep -q '^ok   the board.s nominal VRAM, the largest VRAM reserve and the compute capability are set' "$T/cb.out" && ok "check-be.sh: the VRAM reserve variable is checked and set on the fake clone" || no "check-be.sh: no ok for the VRAM reserve on the fake clone"
	_rcf=$R/etc/rc.conf.d/nvidia_native_tools_testboot
	cp "$_rcf" "$T/rcconf.orig"; grep -v '_vram_reserve=' "$T/rcconf.orig" > "$_rcf"
	env TMPDIR="$T" GB10_TEST_HOOKS=1 NVNT_NO_GIT_CHECK=1 sh "$KIT/check-be.sh" -m "$R" -U -s "$SHAFILE" > "$T/cb-noreserve.out" 2>&1
	grep -q '^FAIL the board.s nominal VRAM, VRAM reserve (make-be.sh -R)' "$T/cb-noreserve.out" && ok "check-be.sh: a clone without the VRAM reserve variable is a FAIL" || no "check-be.sh did not FAIL on a missing VRAM reserve"
	cp "$T/rcconf.orig" "$_rcf"
	printf '#!/bin/sh\nexit 1\n' > "$T/bectl-bad"; chmod 0755 "$T/bectl-bad"
	env GB10_TEST_HOOKS=1 NVNT_BECTL="$T/bectl-bad" NVNT_MNT="$T/clone3/root" NVNT_NOT_ROOT=1 NVNT_NO_GIT_CHECK=1 sh "$KIT/make-be.sh" -D 20990103 -m "$STAGE" > "$T/mb4.out" 2>&1
	expect 2 $? "make-be.sh stops when bectl list fails"
	grep -q 'bectl list failed' "$T/mb4.out" && ok "make-be.sh says bectl list failed" || no "make-be.sh: $(cat "$T/mb4.out" | head -2)"
	MB -D 20990101 -m "$STAGE" > "$T/mb3.out" 2>&1; expect 2 $? "make-be.sh refuses an existing BE name"
	MB -D 20990104 -m "$STAGE" -o "$WORK/logs/x/" > "$T/mb5.out" 2>&1; expect 2 $? "make-be.sh refuses a copy-out with a trailing /"
	MB -D 20990104 -m "$STAGE" -o "$WORK/logs/../x" > "$T/mb6.out" 2>&1; expect 2 $? "make-be.sh refuses a copy-out with a .. component"
	: > "$T/bectl.log"; mkclone "$T/clone4/root"
	env GB10_TEST_HOOKS=1 NVNT_BECTL="$T/bectl" NVNT_MNT="$T/clone4/root" NVNT_NOT_ROOT=1 NVNT_NO_GIT_CHECK=1 GB10_WORK="$WORK" sh "$KIT/make-be.sh" -D 20990105 -m "$STAGE" --activate > "$T/mb8.out" 2>&1
	_s=$?; [ "$_s" = 1 ] && ! grep -q 'bectl activate' "$T/bectl.log" && grep -q 'NOT armed' "$T/mb8.out" && ok "make-be.sh --activate arms nothing when check-be.sh fails" || no "make-be.sh --activate: exit $_s, $(grep activate "$T/bectl.log")"
	sh "$KIT/check-be.sh" -s > "$T/cb-s.out" 2>&1; grep -q -- '-s needs a value' "$T/cb-s.out" && ok "check-be.sh -s without a value says so" || no "check-be.sh -s: $(cat "$T/cb-s.out")"
	MB -D 20990104 -m "$STAGE" --bogus > "$T/mb7.out" 2>&1; [ "$(wc -l < "$T/mb7.out" | tr -d ' ')" = 1 ] && ok "make-be.sh: a usage error is one line" || no "make-be.sh: a usage error prints $(wc -l < "$T/mb7.out") lines"
	grep -q 'with -n 2' "$T/mb3.out" && ok "make-be.sh names the next free number" || no "make-be.sh: $(cat "$T/mb3.out")"
	# an nm that fails, an nm that lists nothing, and a copy-out under a boot environment root of any name are not passes
	mkdir -p "$T/nmstub"; printf '#!/bin/sh\nexit 1\n' > "$T/nmstub/nm"; chmod 0755 "$T/nmstub/nm"
	( PATH="$T/nmstub:$PATH"; guard_undef "$STAGE/nvidia.ko" > /dev/null ); expect 2 $? "guard_undef: an nm that fails is an error"
	printf '#!/bin/sh\nexit 0\n' > "$T/nmstub/nm"
	( PATH="$T/nmstub:$PATH"; guard_undef "$STAGE/nvidia.ko" > /dev/null ); expect 2 $? "guard_undef: an nm that lists no symbol is an error"
	guard_undef "$STAGE/nvidia.ko" > /dev/null; expect 0 $? "guard_undef: the staged nvidia.ko has no Linux symbol"
	_kd=$(dirname "$(sysctl -n kern.bootfile)"); LK=; for _m in "$_kd"/linuxkpi*.ko "$_kd"/lindebugfs.ko; do [ -f "$_m" ] && LK="$LK $_m"; done
	guard_ko_native "$STAGE/nvidia.ko" "$T/kodep" $LK > /dev/null; expect 0 $? "guard_ko_native: the staged nvidia.ko of main is native (compared with$LK)"
	guard_ko_native "$STAGE/nvidia-modeset.ko" "$T/kodep" $LK > /dev/null; expect 0 $? "guard_ko_native: the staged nvidia-modeset.ko of main is native"
	guard_ko_native "$STAGE/nvidia.ko" "$T/kodep" > /dev/null; expect 2 $? "guard_ko_native: no LinuxKPI module to compare with is an error"
	guard_ko_native "$STAGE/nvidia.ko" "$T/elsewhere-dir" $LK > /dev/null; expect 2 $? "guard_ko_native: a scratch directory not ending in /kodep is refused"
	if [ -n "${NVNT_PHASE0_KO:-}" ]; then
		guard_ko_native "$NVNT_PHASE0_KO" "$T/kodep" $LK > /dev/null; expect 1 $? "guard_ko_native: the real phase-0 nvidia.ko control fails"
	else
		skip "guard_ko_native phase-0 module" NVNT_PHASE0_KO "the phase-0 nvidia.ko built with the Linuxulator"
	fi
	if [ -n "${NVNT_UVM_KO:-}" ]; then
		guard_ko_native "$NVNT_UVM_KO" "$T/kodep" $LK > /dev/null; expect 1 $? "guard_ko_native: the real nvidia-uvm.ko control fails"
	else
		skip "guard_ko_native uvm module" NVNT_UVM_KO "a nvidia-uvm.ko built with the Linuxulator"
	fi
	# Synthetic controls make the Linux-dependent cases testable without a historical module or a personal dataset.
	: > "$T/synthetic.ko"
	mkdir -p "$T/kldstub"
	cat > "$T/kldstub/kldxref" <<'EOF'
#!/bin/sh
printf '  module nvidia\n    depends on linux64elf.\n    depends on linux_common.\n'
EOF
	chmod 0755 "$T/kldstub/kldxref"
	( PATH="$T/kldstub:$PATH"; guard_ko_native "$T/synthetic.ko" "$T/kodep" $LK > "$T/synthetic-deps.out" ); expect 1 $? "guard_ko_native: a synthetic module with Linux dependencies fails"
	grep -q 'depends on linux64elf linux_common' "$T/synthetic-deps.out" && ok "guard_ko_native: the synthetic dependency plant is what fails" || no "guard_ko_native: the synthetic dependency plant did not fire"
	# a module calling into LinuxKPI by unprefixed names, with no MODULE_DEPEND on it, is caught by its imports
	guard_lkpi_imports "$STAGE/nvidia.ko" $LK > /dev/null; expect 0 $? "guard_lkpi_imports: nvidia.ko of main imports nothing LinuxKPI defines"
	if [ -n "${NVNT_DRM_KO:-}" ]; then
		guard_lkpi_imports "$NVNT_DRM_KO" $LK > "$T/lki.out"; expect 1 $? "guard_lkpi_imports: the real nvidia-drm.ko control fails: $(cut -c1-90 "$T/lki.out")"
	else
		skip "guard_lkpi_imports drm module" NVNT_DRM_KO "a nvidia-drm.ko built with LinuxKPI"
	fi
	mkdir -p "$T/nmstub2"; printf '#!/bin/sh\ncase "$1" in -u) echo "                 U idr_alloc"; echo "                 U printf" ;; *) echo "0000000000001000 T idr_alloc" ;; esac\n' > "$T/nmstub2/nm"; chmod 0755 "$T/nmstub2/nm"
	( PATH="$T/nmstub2:$PATH"; guard_lkpi_imports /x /y > "$T/synthetic-import.out" ); expect 1 $? "guard_lkpi_imports: an unprefixed LinuxKPI import (idr_alloc) fails"
	grep -q 'idr_alloc' "$T/synthetic-import.out" && ok "guard_lkpi_imports: the failure names the planted idr_alloc import" || no "guard_lkpi_imports: the planted import did not fire: $(cat "$T/synthetic-import.out")"
	if [ -n "${NVNT_UVM_KO:-}" ]; then
		guard_undef "$NVNT_UVM_KO" > /dev/null; expect 1 $? "guard_undef: the real nvidia-uvm.ko control has Linux symbols"
	else
		skip "guard_undef uvm module" NVNT_UVM_KO "a nvidia-uvm.ko built with the Linuxulator"
	fi
	cat > "$T/kldstub/kldxref" <<'EOF'
#!/bin/sh
printf '  module nvidia_uvm\n    depends on kernel.\n'
EOF
	mkdir -p "$T/nmstub3"
	printf '#!/bin/sh\nprintf "                 U linux_synthetic\\n                 U printf\\n"\n' > "$T/nmstub3/nm"; chmod 0755 "$T/nmstub3/nm" "$T/kldstub/kldxref"
	( PATH="$T/kldstub:$T/nmstub3:$PATH"; guard_ko_native "$T/synthetic.ko" "$T/kodep" $LK > "$T/synthetic-native-undef.out" ); expect 1 $? "guard_ko_native: a synthetic module with an undefined Linux symbol fails"
	grep -q 'linux_synthetic' "$T/synthetic-native-undef.out" && ok "guard_ko_native: the failure names the planted linux_synthetic symbol" || no "guard_ko_native: the planted undefined symbol did not fire: $(cat "$T/synthetic-native-undef.out")"
	( PATH="$T/nmstub3:$PATH"; guard_undef "$T/synthetic.ko" > "$T/synthetic-undef.out" ); expect 1 $? "guard_undef: a synthetic undefined Linux symbol fails"
	grep -q 'linux_synthetic' "$T/synthetic-undef.out" && ok "guard_undef: the failure names the planted linux_synthetic symbol" || no "guard_undef: the planted undefined symbol did not fire: $(cat "$T/synthetic-undef.out")"
	guard_copyout_dataset /x zroot/bootenv/cloudbsd-rx7600 zroot/bootenv/cloudbsd-rx7600 > /dev/null; expect 1 $? "guard_copyout_dataset: under a boot environment root named bootenv fails"
	guard_copyout_dataset /x zroot/ROOT zroot/ROOT/cloudbsd-rx7600 > /dev/null; expect 1 $? "guard_copyout_dataset: the boot environment root itself fails"
	guard_copyout_dataset /x tank/ROOT/x zroot/ROOT/cloudbsd-rx7600 > /dev/null; expect 0 $? "guard_copyout_dataset: another pool's ROOT is not a boot environment"
	guard_copyout_dataset /x zroot/home/test zroot/ROOT/cloudbsd-rx7600 > /dev/null; expect 0 $? "guard_copyout_dataset: the home dataset passes"
	guard_copyout_dataset /x zroot/home/test - > /dev/null; expect 2 $? "guard_copyout_dataset: no bootfs is an error"
	guard_copyout_dataset /x tank/results - zroot/ROOT/cloudbsd-rx7600 > /dev/null; expect 0 $? "guard_copyout_dataset: a data pool without bootfs passes"
	guard_copyout_dataset /x tank/ROOT/a zroot/ROOT/b tank/ROOT/c > /dev/null; expect 1 $? "guard_copyout_dataset: under the boot environment root of a second pool fails"
	mkdir -p "$R/etc/rc.conf.d"; : > "$R/etc/rc.conf.d/linux"
	env TMPDIR="$T" GB10_TEST_HOOKS=1 NVNT_NO_GIT_CHECK=1 sh "$KIT/check-be.sh" -m "$R" -U -s "$SHAFILE" > "$T/cb-ov.out" 2>&1
	grep -q '^FAIL etc/rc.conf.d/linux exists' "$T/cb-ov.out" && ! grep -q '^ok   no later rc.conf' "$T/cb-ov.out" && ok "check-be.sh: an rc.conf.d/linux override is a FAIL, with no ok after it" || no "check-be.sh: the rc.conf.d/linux override is not reported cleanly"
	rm -f "$R/etc/rc.conf.d/linux"
	printf 'linux_enable="YES"\n' >> "$R/etc/rc.conf"
	env TMPDIR="$T" GB10_TEST_HOOKS=1 NVNT_NO_GIT_CHECK=1 sh "$KIT/check-be.sh" -m "$R" -U -s "$SHAFILE" > "$T/cb2.out" 2>&1
	grep -q '^FAIL rc.conf: linux_enable' "$T/cb2.out" && ok "check-be.sh catches linux_enable=YES planted in the clone" || no "check-be.sh misses a planted linux_enable=YES"

	# (f) the rc one-shot, foreground, stubbed system commands
	S=$T/stubs; mkdir -p "$S" "$T/dev" "$T/kitroot/static-rows" "$T/mods" "$T/copyout"
	ln -s /dev/null "$T/dev/nvidia1"; ln -s /dev/null "$T/dev/nvidiactl"; ln -s /dev/null "$T/dev/nvidia-modeset"
	for _f in nvidia.ko nvidia-modeset.ko nvidia_gsp_ga10x_fw.ko nvrm-info libnvrm.so.1 mem_probe chan_probe; do cp "$STAGE/$_f" "$T/mods/"; done
	cp "$SHAFILE" "$T/kitroot/SHA256.txt"
	for _f in guard.sh summarize.py gpu-detect.sh; do cp "$KIT/$_f" "$T/kitroot/"; done
	mkdir -p "$T/kitroot/repo"; ( cd "$repo" && tar -cf - tests/libnvrm SOURCES lib/libnvrm/schema ) | tar -xf - -C "$T/kitroot/repo"
	cp "$R"/usr/local/share/nvidia-native-tools-test/static-rows/* "$T/kitroot/static-rows/"
	echo > "$T/loaded"
	cat > "$S/kldstat" <<EOF
#!/bin/sh
case "\$*" in
"-q -m nvidia") grep -qx nvidia "$T/loaded" ;;
"-q -n nvidia_gsp_ga10x_fw") grep -qx nvidia_gsp_ga10x_fw "$T/loaded" ;;
-v)
	echo "Id Refs Address                Size Name"
	echo " 1  164 0xffff000000000000  1594e28 kernel (/boot/kernel/kernel)"
	_i=2; for _m in \$(cat "$T/loaded"); do echo " \$_i    1 0xffff0005ce600000   993000 \$_m.ko (/x/\$_m.ko)"; _i=\$((_i + 1)); done ;;
*) exit 0 ;;
esac
EOF
	cat > "$S/kldload" <<EOF
#!/bin/sh
_b=\${1##*/}; echo "\${_b%.ko}" >> "$T/loaded"
EOF
	cat > "$S/sysctl" <<'EOF'
#!/bin/sh
case "$*" in
"compat.linux") echo "sysctl: unknown oid 'compat.linux'" >&2; exit 1 ;;
"-n kern.panic_reboot_wait_time debug.debugger_on_panic") printf '5\n0\n' ;;
"-n dev.nvidia.1.%parent") echo vgapci1 ;;
"-n dev.vgapci.1.%location") echo "slot=1 function=0 dbsf=pci13:1:0:0" ;;
"-n kern.bootfile") echo /boot/kernel/kernel ;;
*) exit 0 ;;
esac
EOF
	cat > "$S/pciconf" <<'EOF'
#!/bin/sh
case "$*" in
-l) printf 'vgapci0@pci12:3:0:0:\tclass=0x030000 rev=0xc7 hdr=0x00 vendor=0x1002 device=0x7480 subvendor=0x1849 subdevice=0x5313\nvgapci1@pci13:1:0:0:\tclass=0x030000 rev=0xa1 hdr=0x00 vendor=0x10de device=0x2d04 subvendor=0x1462 subdevice=0x5351\nvgapci2@pci14:1:0:0:\tclass=0x030000 rev=0x52 hdr=0x00 vendor=0x1a03 device=0x2000 subvendor=0x1a03 subdevice=0x2000\n' ;;
"-l vgapci1") printf 'vgapci1@pci13:1:0:0:\tclass=0x030000 rev=0xa1 hdr=0x00 vendor=0x10de device=0x2d04 subvendor=0x1462 subdevice=0x5351\n' ;;
*) exit 0 ;;
esac
EOF
	printf '#!/bin/sh\necho "dmesg stub"\n' > "$S/dmesg"; printf '#!/bin/sh\nprintf "t\\tNR\\n"\n' > "$S/bectl"
	printf '#!/bin/sh\n[ "$*" = "-n linux_enable" ] && echo NO\n' > "$S/sysrc"
	printf '#!/bin/sh\necho "chown $*" >> "%s/chown.log"\n[ "${RC_CHOWN_FAIL:-0}" = 1 ] && exit 1\nexit 0\n' "$T" > "$S/chown"
	printf '#!/bin/sh\necho "testboot-return $*" > "%s/returned"\n' "$T" > "$T/return"
	chmod 0755 "$S"/* "$T/return"
	rc_env() {
		if [ "${RC_UNSET_SHUTDOWN:-0}" = 1 ]; then
			env -u nvidia_native_tools_testboot_shutdown "$@"
		else
			env nvidia_native_tools_testboot_shutdown="${RC_SHUTDOWN:-$nvidia_native_tools_testboot_shutdown}" "$@"
		fi
	}
	rcrun() {	# rcrun <work dir> <copy-out dir> <return script> [extra stub dir first in PATH]
		rc_env PATH="${4:+$4:}$S:$PATH" nvidia_native_tools_testboot_enable=YES nvidia_native_tools_testboot_foreground=YES \
		    nvidia_native_tools_testboot_kit="$T/kitroot" nvidia_native_tools_testboot_mods="$T/mods" \
		    nvidia_native_tools_testboot_work="$1" nvidia_native_tools_testboot_fallback="$1.fallback" \
		    nvidia_native_tools_testboot_copyout="$2" nvidia_native_tools_testboot_return="$3" \
		    nvidia_native_tools_testboot_devdir="$T/dev" nvidia_native_tools_testboot_vram=$BOARD_VRAM_BYTES nvidia_native_tools_testboot_vram_reserve=$BOARD_VRAM_RESERVE_MAX_BYTES nvidia_native_tools_testboot_sm=$BOARD_SM \
		    nvidia_native_tools_testboot_lockfile="${RC_LOCK:-$T/nolock}" nvidia_native_tools_testboot_version="$T/nover" nvidia_native_tools_testboot_owner="${RC_OWNER:-}" ${RC_EXTRA:-} \
		    sh "${RC_SCRIPT:-$KIT/nvidia_native_tools_testboot}" onestart > "$1.out" 2>&1
		ls -d "$1"/* 2> /dev/null | head -1
	}
	RC_OWNER=kitowner
	RUN=$(rcrun "$T/work" "$T/copyout" "$T/return")
	reap_stub_children
	grep -q '"row":"deadman","status":"pass","detail":".*stubbed shutdown .* is used' "$RUN/results.jsonl" 2> /dev/null && ok "G3 control: the same stub on a hand run (onestart) is used (decided: a stub cannot reboot)" || no "G3 control: the stub on a hand run was not used: $(grep '"row":"deadman"' "$RUN/results.jsonl" 2> /dev/null)"
	if [ -z "$RUN" ]; then no "the rc one-shot made no run directory: $(cat "$T/work.out")"; else
		st() { /usr/local/bin/python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print([r["status"] for r in d["rows"] if r["name"]==sys.argv[2]][0])' "${2:-$RUN}/summary.json" "$1" 2> /dev/null; }
		for _p in deadman:pass ko-native-nvidia:pass ko-native-nvidia-modeset:pass panic-settings:pass linux-enable:pass env-before:pass load:pass env-loaded:pass gpu-node:pass gpu-detect-native:pass root-open:pass gpu-verify:pass nvidiactl-open:pass modeset-open:pass nvrm-info-native:pass nvrm-info-no-new-module:pass uvm-ioctl-suite:$UVM_WANT prime-import:$PRIME_WANT render-uapi:not-available env-after:pass env-after-delta:pass done:info; do
			_r=${_p%%:*}; _w=${_p#*:}; _g=$(st "$_r")
			[ "$_g" = "$_w" ] && ok "rc one-shot: row $_r is $_w" || no "rc one-shot: row $_r is '${_g:-missing}', wanted $_w"
		done
		_n=$(st nvrm-info); case $_n in pass | fail) ok "rc one-shot: nvrm-info ran (status $_n; no driver on the host, so fail is expected here)" ;; *) no "rc one-shot: nvrm-info is $_n" ;; esac
		_n2=$(st nvrm-s2-memory); case $_n2 in pass | fail) ok "rc one-shot: nvrm-s2-memory ran (status $_n2; the memory probe needs the driver, so fail is expected here)" ;; *) no "rc one-shot: nvrm-s2-memory is $_n2" ;; esac
		_n3=$(st nvrm-s3-channel); case $_n3 in pass | fail) ok "rc one-shot: nvrm-s3-channel ran (status $_n3; the channel probe needs the driver, so fail is expected here)" ;; *) no "rc one-shot: nvrm-s3-channel is $_n3" ;; esac
		grep -q 'pass .*/mods/nvrm-info is a FreeBSD-branded ELF' "$RUN/nvrm-info.execs" && ok "rc one-shot: the trace checked nvrm-info itself" || no "rc one-shot: nvrm-info is not in nvrm-info.execs"
		grep -q 'selected_node": "'"$T"'/dev/nvidia1"' "$RUN/gpu-detect.json" && ok "rc one-shot: gpu-detect chose nvidia1 (the BMC and the AMD card excluded)" || no "rc one-shot: gpu-detect did not choose nvidia1"
		[ "$(cat "$T/returned" 2> /dev/null)" = "testboot-return cloudbsd-current" ] && ok "rc one-shot: testboot-return is called with the normal BE" || no "rc one-shot: testboot-return was not called: $(cat "$T/returned" 2> /dev/null)"
		_c=$T/copyout/$(basename "$RUN")
		[ -f "$_c/summary.json" ] && ok "rc one-shot: the run is copied out" || no "rc one-shot: the run is not copied out"
		[ -f "$_c/testboot-return.txt" ] && grep -q 'testboot-return exit' "$_c/rc.log" && ok "rc one-shot: testboot-return.txt and the full rc.log reach the copy-out" || no "rc one-shot: the return record is not in the copy-out"
		[ "$(stat -f %Lp "$_c")" = 700 ] && ok "rc one-shot: the copy-out directory is 0700" || no "rc one-shot: the copy-out directory is $(stat -f %Lp "$_c")"
		_m=$(stat -f %Lp "$_c/summary.json" 2> /dev/null)
		[ "$_m" = 600 ] && ok "rc one-shot: the files of the copy-out are 0600" || no "rc one-shot: summary.json of the copy-out is mode ${_m:-none}, not 0600"
		grep -q '^chown -h -- kitowner \.$' "$T/chown.log" 2> /dev/null && ok "rc one-shot: the run directory is given to the owner that make-be.sh recorded" || no "rc one-shot: the run directory was not given to the owner: $(head -2 "$T/chown.log" 2> /dev/null)"
		grep -q '^chown -h -- kitowner summary\.json$' "$T/chown.log" 2> /dev/null && ok "rc one-shot: the files of the run are given to the owner" || no "rc one-shot: the files of the run were not given to the owner: $(head -2 "$T/chown.log" 2> /dev/null)"
		grep -q '"verdict": "fail"\|"verdict": "incomplete"' "$RUN/summary.json" && ok "rc one-shot: the verdict is not pass with rows that cannot run natively" || no "rc one-shot: verdict $(grep '"verdict"' "$RUN/summary.json")"
	fi
	# the hand-over of the copy to the owner, on its own: the function of the rc script, taken out of it
	sed -n '/^own_run()/,/^}/p' "$KIT/nvidia_native_tools_testboot" > "$T/own_run.sh"
	if [ -s "$T/own_run.sh" ]; then
		. "$T/own_run.sh"
		nvidia_native_tools_testboot_owner=$(id -un)
		# a run directory that is a link in its place: the directory it points at must not be touched
		mkdir -p "$T/own-target"; chmod 0700 "$T/own-target"
		ln -s "$T/own-target" "$T/own-link"
		own_run "$T/own-link" "1:2" > "$T/own-link.out" 2>&1
		[ "$(stat -f %Lp "$T/own-target")" = 700 ] && ok "own_run: a run directory that is a link is not touched" || no "own_run: the directory the link points at is mode $(stat -f %Lp "$T/own-target")"
		# a file with more than one link is not given away: it is a file the owner could have planted
		printf 'planted\n' > "$T/own-sentinel"; chmod 0644 "$T/own-sentinel"
		mkdir -p "$T/own-dir"; printf 'x\n' > "$T/own-dir/f"; ln "$T/own-sentinel" "$T/own-dir/hard"
		own_run "$T/own-dir" "$(stat -f '%d:%i' "$T/own-dir")" > "$T/own-dir.out" 2>&1
		[ "$(stat -f %Lp "$T/own-sentinel")" = 644 ] && ok "own_run: a file with more than one link is left alone" || no "own_run: the planted link was given away: the sentinel is mode $(stat -f %Lp "$T/own-sentinel")"
		[ "$(stat -f %Lp "$T/own-dir/f")" = 600 ] && ok "own_run: the files of the run are 0600" || no "own_run: the file of the run is mode $(stat -f %Lp "$T/own-dir/f")"
		[ "$(stat -f %Lp "$T/own-dir")" = 700 ] && ok "own_run: the run directory is 0700" || no "own_run: the run directory is mode $(stat -f %Lp "$T/own-dir")"
		# a chown that fails: the message names the directory, and the run stays as it is
		mkdir -m 0700 "$T/own-fail"; printf 'x\n' > "$T/own-fail/f"
		nvidia_native_tools_testboot_owner=nosuchuserhere
		own_run "$T/own-fail" "$(stat -f '%d:%i' "$T/own-fail")" > "$T/own-fail.out" 2>&1
		grep -q "the run directory $T/own-fail could not be given to nosuchuserhere" "$T/own-fail.out" \
		    && ok "own_run: a failed chown says which directory could not be given" \
		    || no "own_run: the failed chown is not reported with the directory: $(cat "$T/own-fail.out")"
		[ "$(stat -f %Lp "$T/own-fail")" = 700 ] && ok "own_run: a failed chown leaves the run directory as it was" || no "own_run: the run directory is mode $(stat -f %Lp "$T/own-fail")"
		nvidia_native_tools_testboot_owner=$(id -un)
	else
		no "own_run: the function of the rc script could not be read"
	fi
	# a copy-out path with a symbolic link in it is refused; the run stays in the boot environment
	mkdir -p "$T/elsewhere"; ln -s "$T/elsewhere" "$T/linked"
	RUN2=$(rcrun "$T/work2" "$T/linked/out" "$T/return")
	reap_stub_children
	[ -z "$(ls "$T/elsewhere")" ] && grep -q 'COULD NOT copy' "$RUN2/rc.log" && ok "rc one-shot: a copy-out through a symbolic link is refused" || no "rc one-shot: the copy went through the symbolic link ($(ls "$T/elsewhere"))"
	# a failed return still leaves its record in the copy-out
	printf '#!/bin/sh\necho "bectl activate failed"\nexit 1\n' > "$T/return-bad"; chmod 0755 "$T/return-bad"
	RUN3=$(rcrun "$T/work3" "$T/copyout3" "$T/return-bad")
	reap_stub_children
	grep -q 'bectl activate failed' "$T/copyout3/$(basename "$RUN3")/testboot-return.txt" 2> /dev/null && ok "rc one-shot: a failed return is recorded in the copy-out" || no "rc one-shot: the failed return is not in the copy-out"
	# the chown of the copy fails: the log says which directory could not be given, and the run stays as it is
	echo > "$T/loaded"
	RC_CHOWN_FAIL=1; export RC_CHOWN_FAIL
	RUN3b=$(rcrun "$T/work3b" "$T/copyout3b" "$T/return")
	unset RC_CHOWN_FAIL
	reap_stub_children
	_c3b=$T/copyout3b/$(basename "$RUN3b")
	grep -q "the run directory $_c3b could not be given to kitowner" "$RUN3b/rc.log" 2> /dev/null \
	    && ok "rc one-shot: a failed chown of the copy says which directory could not be given" \
	    || no "rc one-shot: the failed chown is not reported with the directory: $(grep 'could not be given' "$RUN3b/rc.log" 2> /dev/null)"
	[ "$(stat -f %Lp "$_c3b" 2> /dev/null)" = 700 ] && ok "rc one-shot: a failed chown leaves the copy as it was" || no "rc one-shot: the copy is mode $(stat -f %Lp "$_c3b" 2> /dev/null)"
	# a module that does not load: the rows after it are not-run
	mkdir -p "$T/kfail"; printf '#!/bin/sh\necho "kldload: cannot load $1" >&2\nexit 1\n' > "$T/kfail/kldload"; chmod 0755 "$T/kfail/kldload"
	echo > "$T/loaded"
	RUN4=$(rcrun "$T/work4" "$T/copyout4" "$T/return" "$T/kfail")
	reap_stub_children
	_bad=
	for _r in gpu-node root-open gpu-verify nvidiactl-open modeset-open nvrm-info nvrm-info-native nvrm-info-no-new-module; do
		[ "$(st "$_r" "$RUN4")" = not-run ] || _bad="$_bad $_r=$(st "$_r" "$RUN4")"
	done
	[ -z "$_bad" ] && ok "rc one-shot: after a failed load every later row is not-run" || no "rc one-shot: after a failed load:$_bad"
	# a dead-man timer that is not pending: nothing is loaded
	mkdir -p "$T/dmfail"; printf '#!/bin/sh\nexit 1\n' > "$T/dmfail/shutdown"; chmod 0755 "$T/dmfail/shutdown"
	echo > "$T/loaded"
	RC_SHUTDOWN=$T/dmfail/shutdown
	RUN5=$(rcrun "$T/work5" "$T/copyout5" "$T/return")
	unset RC_SHUTDOWN
	reap_stub_children
	[ -z "$(tr -d '\n' < "$T/loaded")" ] && [ "$(st deadman "$RUN5")" = fail ] && [ "$(st load-nvidia "$RUN5")" = not-run ] && grep -q '"verdict": "fail"' "$RUN5/summary.json" \
	    && ok "rc one-shot: without a pending dead-man timer nothing is loaded and the verdict is fail" || no "rc one-shot: dead-man not pending: loaded '$(tr '\n' ' ' < "$T/loaded")', deadman $(st deadman "$RUN5"), load-nvidia $(st load-nvidia "$RUN5")"
	# an evidence file that claims pass is not trusted
	cp "$T/kitroot/static-rows/render-uapi" "$T/render-uapi.save"; chmod u+w "$T/kitroot/static-rows/render-uapi"; printf 'pass\nplanted\n' > "$T/kitroot/static-rows/render-uapi"
	echo > "$T/loaded"
	RUN6=$(rcrun "$T/work6" "$T/copyout6" "$T/return")
	reap_stub_children
	cp "$T/render-uapi.save" "$T/kitroot/static-rows/render-uapi"
	[ "$(st render-uapi "$RUN6")" = error ] && ok "rc one-shot: a static row whose evidence says pass is an error" || no "rc one-shot: render-uapi with a planted pass is $(st render-uapi "$RUN6")"
	[ "$(st load-nvidia_gsp_ga10x_fw "$RUN4")" = fail ] && ok "rc one-shot: the failed load is a fail row" || no "rc one-shot: load-nvidia_gsp_ga10x_fw is $(st load-nvidia_gsp_ga10x_fw "$RUN4")"

	# Exact-pid cancellation: the recorded child dies, while an earlier same-named decoy stays alive.
	cat > "$T/return-hold" <<EOF
#!/bin/sh
_c=\$(tail -1 "$T/shutdown-children" 2> /dev/null)
printf '%s %s\n' "\$_c" "\$(ps -o uid= -o comm= -p "\$_c" 2> /dev/null | tr -d ' ')" > "$T/hold-seen"
exit 3
EOF
	chmod 0755 "$T/return-hold"; rm -f "$T/hold-seen"
	echo > "$T/loaded"
	"$SENT/shutdown-child/shutdown" 300 &
	DM_DECOY=$!
	RUNC=$(rcrun "$T/work-cancel" "$T/copyout-cancel" "$T/return-hold")
	_cancel_pid=$(sed -n 's/.*\[pid \([0-9][0-9]*\)\].*/\1/p' "$RUNC/deadman.txt" 2> /dev/null | head -1)
	case $_cancel_pid in
	'' | *[!0-9]*) no "exact-pid cancellation: no numeric child pid was recorded" ;;
	*)
		[ "$(cat "$T/hold-seen" 2> /dev/null)" = "$_cancel_pid $(id -u)shutdown" ] && ok "F6 the recorded child $_cancel_pid was a live shutdown of ours just before the cancel" || no "F6 the recorded child was not a live shutdown before the cancel: '$(cat "$T/hold-seen" 2> /dev/null)'"
		[ -z "$(ps -o uid= -o comm= -p "$_cancel_pid" 2> /dev/null | tr -d ' ')" ] && ok "exact-pid cancellation killed the recorded child $_cancel_pid" || no "exact-pid cancellation left child $_cancel_pid alive"
		[ "$(ps -o uid= -o comm= -p "$DM_DECOY" 2> /dev/null | tr -d ' ')" = "$(id -u)shutdown" ] && ok "exact-pid cancellation leaves the same-named decoy $DM_DECOY alive" || no "exact-pid cancellation killed or lost the decoy $DM_DECOY"
		grep -qF "killed only the confirmed dead-man shutdown pid $_cancel_pid" "$RUNC/results.jsonl" && ok "exact-pid cancellation records the confirmed pid" || no "exact-pid cancellation has no exact-pid row"
		;;
	esac
	grep -q 'nvidia_native_tools_testboot dead-man' "$T/shutdown-args" && ok "the foreground stub receives the dead-man wall message" || no "the foreground stub did not receive the dead-man wall message"
	reap_stub_children
	kill "$DM_DECOY" 2> /dev/null || :; wait "$DM_DECOY" 2> /dev/null || :; DM_DECOY=

	# A child that exited before cancellation is named in a fail row, and no other process is killed.
	cat > "$T/return-gone" <<EOF
#!/bin/sh
_gone=\$(tail -1 "$T/shutdown-children" 2> /dev/null)
case \$_gone in '' | *[!0-9]*) ;; *) kill "\$_gone" 2> /dev/null || : ;; esac
exit 3
EOF
	chmod 0755 "$T/return-gone"
	echo > "$T/loaded"
	RUNG=$(rcrun "$T/work-gone" "$T/copyout-gone" "$T/return-gone")
	grep -q '"row":"deadman-cancel","status":"fail","detail":"dead-man pid .* is no longer a shutdown owned by uid .*; killed nothing"' "$RUNG/results.jsonl" \
	    && ok "cancellation of an already-gone pid says so and kills nothing" || no "cancellation of an already-gone pid did not produce the refusal row"
	reap_stub_children

	# G3: replace the sole real-path literal in a copy, then run that copy as non-root with no override.
	RC_G3=$T/rc-g3-sentinel
	_real_count=$(grep -oF '/sbin/shutdown' "$KIT/nvidia_native_tools_testboot" | wc -l | tr -d ' ')
	_g3_ready=1
	if [ "$_real_count" != 1 ]; then
		no "G3 requires exactly one real shutdown path in the original, found $_real_count"
		_g3_ready=0
	else
		sed "s|/sbin/shutdown|$SENT2/real-shutdown|" "$KIT/nvidia_native_tools_testboot" > "$RC_G3"
		_copy_count=$(grep -oF '/sbin/shutdown' "$RC_G3" | wc -l | tr -d ' ')
		if [ "$_copy_count" != 0 ] || cmp -s "$KIT/nvidia_native_tools_testboot" "$RC_G3"; then
			no "G3 sentinel substitution did not make a distinct copy without the real path"
			_g3_ready=0
		else
			ok "G3 control copy has no real shutdown path and differs from the original"
		fi
	fi
	rm -f "$SENT2/hits"
	if [ "$_g3_ready" = 1 ]; then
		RC_SCRIPT=$RC_G3; RC_UNSET_SHUTDOWN=1
		RUN_G3=$(rcrun "$T/work-g3" "$T/copyout-g3" "$T/return-hold")
		unset RC_SCRIPT RC_UNSET_SHUTDOWN
		if [ -n "$RUN_G3" ] && [ -f "$RUN_G3/results.jsonl" ]; then
			grep -q '"row":"deadman","status":"fail","detail":"REFUSED: not calling shutdown: uid [0-9][0-9]* is not 0: this boot is NOT protected against a hang"' "$RUN_G3/results.jsonl" \
			    && ok "G3 non-root onestart refuses the real default, names uid, keeps the suffix (F8)" || no "G3 did not produce the uid refusal row: $(grep '"row":"deadman"' "$RUN_G3/results.jsonl")"
			[ "$(grep -c '"row":"deadman",' "$RUN_G3/results.jsonl")" = 1 ] && ok "G3 refusal writes one deadman row" || no "G3 refusal did not write exactly one deadman row"
			grep -q '"row":"deadman-cancel","status":"fail","detail":"no confirmed dead-man shutdown pid was recorded; killed nothing"' "$RUN_G3/results.jsonl" \
			    && ok "cancellation with no recorded pid says so and kills nothing" || no "cancellation with no recorded pid did not produce the refusal row"
		else
			no "G3 sentinel copy made no run directory"
		fi
		# F1: at an rc boot (autoboot=yes) a stub override is ignored: the real conditions apply (here the uid fails), the stub is not called
		: > "$T/shutdown-args"
		RC_SCRIPT=$RC_G3; RC_EXTRA="autoboot=yes rc_fast=yes"
		RUN_F1=$(rcrun "$T/work-f1" "$T/copyout-f1" "$T/return")
		unset RC_SCRIPT RC_EXTRA
		reap_stub_children
		grep -q '"row":"deadman","status":"fail","detail":"REFUSED: not calling shutdown: uid [0-9][0-9]* is not 0' "$RUN_F1/results.jsonl" 2> /dev/null && [ ! -s "$T/shutdown-args" ] && [ ! -s "$SENT2/hits" ] \
		    && ok "F1 at an rc boot the stub override is ignored: refused by the real conditions, stub never called" || no "F1 the stub override was honoured at an rc boot: $(grep '"row":"deadman"' "$RUN_F1/results.jsonl" 2> /dev/null) args '$(cat "$T/shutdown-args")'"
		# F4: a lock file stops the arm before shutdown is called
		: > "$T/shutdown-args"; : > "$T/lockf"
		RC_LOCK=$T/lockf
		RUN_F4=$(rcrun "$T/work-f4" "$T/copyout-f4" "$T/return")
		unset RC_LOCK
		reap_stub_children
		grep -q '"row":"deadman","status":"fail","detail":"the dead-man timer is not pending (lock file .* exists): shutdown was not called: this boot is NOT protected against a hang"' "$RUN_F4/results.jsonl" 2> /dev/null && [ ! -s "$T/shutdown-args" ] \
		    && ok "F4 a lock file is checked before shutdown is called (stub not called)" || no "F4 lock file: stub called or wrong row: $(grep '"row":"deadman"' "$RUN_F4/results.jsonl" 2> /dev/null) args '$(cat "$T/shutdown-args")'"
		# G3 (fix 3): an override that is not an absolute, executable, non-setuid file is not a stub: the real conditions apply (non-root: refused)
		cp "$nvidia_native_tools_testboot_shutdown" "$T/shutdown-stub-suid"; chmod 4755 "$T/shutdown-stub-suid"	# a file mode on our own copy of the stub
		for _ov in "true:true" "relative:stubs/shutdown-rel" "setuid:$T/shutdown-stub-suid"; do
			_on=${_ov%%:*}; _ow=${_ov#*:}
			: > "$T/shutdown-args"; rm -f "$SENT2/hits"
			RC_SCRIPT=$RC_G3; RC_SHUTDOWN=$_ow
			RUN_OV=$(rcrun "$T/work-ov-$_on" "$T/copyout-ov-$_on" "$T/return")
			unset RC_SCRIPT RC_SHUTDOWN
			reap_stub_children
			grep -q '"row":"deadman","status":"fail","detail":"REFUSED: not calling shutdown: ' "$RUN_OV/results.jsonl" 2> /dev/null && [ ! -s "$T/shutdown-args" ] && [ ! -e "$SENT2/hits" ] && [ ! -e "$SENT/hits" ] \
			    && ok "G3 override '$_ow' ($_on) is refused as non-root: REFUSED row, empty stub log, no sentinel hit" || no "G3 override $_on: wrong row or the stub/sentinel was reached: $(grep '"row":"deadman"' "$RUN_OV/results.jsonl" 2> /dev/null) args '$(cat "$T/shutdown-args")'"
		done
		rm -f "$T/shutdown-stub-suid"
	fi
	[ ! -s "$SENT2/hits" ] && ok "G3 refusal never reaches the substituted real-path sentinel" || no "G3 refusal reached the substituted real-path sentinel"

	# G5/M1: replacing the variable call with a bare command must hit the PATH sentinel.
	RC_M1=$T/rc-m1-bare
	sed 's/^\([[:space:]]*\)"\$nvidia_native_tools_testboot_shutdown" -r /\1shutdown -r /' "$KIT/nvidia_native_tools_testboot" > "$RC_M1"
	# F11: the bare-call mutant runs only when the PATH sentinel is first and the real shutdown cannot be found before it
	_m1_path=$S:$PATH
	if [ "${PATH%%:*}" != "$SENT" ] || [ ! -x "$SENT/shutdown" ] || [ -e "$S/shutdown" ] || [ "$(PATH=$_m1_path command -v shutdown)" != "$SENT/shutdown" ]; then
		no "F11 the PATH sentinel is not first with an executable shutdown: mutant M1 is not run"
	elif cmp -s "$KIT/nvidia_native_tools_testboot" "$RC_M1" || ! sh -n "$RC_M1"; then
		no "control: mutant M1 was not made as a distinct valid shell copy"
	else
		ok "F11 the PATH sentinel is first and holds an executable shutdown before mutant M1 runs"
		: > "$SENT/hits"
		RC_SCRIPT=$RC_M1
		RUN_M1=$(rcrun "$T/work-m1" "$T/copyout-m1" "$T/return")
		unset RC_SCRIPT
		reap_stub_children
		if grep -q '^REACHED .*shutdown -r ' "$SENT/hits"; then
			ok "control: mutant M1 is seen"
		else
			no "control: mutant M1 is not seen"
		fi
		mv "$SENT/hits" "$T/mutant-M1.hits"
	fi

	# G5/M2: the same sentinel-only copy with its refusal block disabled must hit the second sentinel.
	RC_M2=$T/rc-m2-no-guard
	sed 's/if ! deadman_allowed; then/if false; then/' "$RC_G3" > "$RC_M2"
	if cmp -s "$RC_G3" "$RC_M2" || ! sh -n "$RC_M2"; then
		no "control: mutant M2 was not made as a distinct valid shell copy"
	else
		: > "$SENT2/hits"
		RC_SCRIPT=$RC_M2; RC_UNSET_SHUTDOWN=1
		RUN_M2=$(rcrun "$T/work-m2" "$T/copyout-m2" "$T/return")
		unset RC_SCRIPT RC_UNSET_SHUTDOWN
		reap_stub_children
		if grep -q '^REAL REACHED -r ' "$SENT2/hits"; then
			ok "control: mutant M2 is seen"
		else
			no "control: mutant M2 is not seen"
		fi
		mv "$SENT2/hits" "$T/mutant-M2.hits"
	fi

	# G5/M3: a planted pattern kill makes the same G4 static contract fail.  This copy is never run.
	RC_M3=$T/rc-m3-pattern-cancel
	sed '/^deadman_cancel()$/a\
\	pkill -f "nvidia_native_tools_testboot dead-man" > /dev/null 2>\&1 || :' "$KIT/nvidia_native_tools_testboot" > "$RC_M3"
	if cmp -s "$KIT/nvidia_native_tools_testboot" "$RC_M3"; then
		no "control: mutant M3 does not differ from the original"
	elif guard_static "$RC_M3" "$T/m3-static.out"; then
		no "control: mutant M3 survived G4"
	elif [ "$(cat "$T/m3-static.out")" = "pgrep/pkill remains" ]; then
		ok "control: mutant M3 is seen (G4 fails for the pkill rule only)"
	else
		no "control: mutant M3 failed G4 for another reason too: $(tr '\n' ';' < "$T/m3-static.out")"
	fi

	# G5/M4: the call rewritten as a bare call after "if !" is seen by the bare-call detector (and only that rule).  Never run.
	RC_M4=$T/rc-m4-if-bare
	sed 's/^\([[:space:]]*\)"\$nvidia_native_tools_testboot_shutdown" -r .*$/\1if ! shutdown -r "+$N" "m"; then :; fi/' "$KIT/nvidia_native_tools_testboot" > "$RC_M4"
	if cmp -s "$KIT/nvidia_native_tools_testboot" "$RC_M4"; then
		no "control: mutant M4 does not differ from the original"
	elif bare_shutdown "$KIT/nvidia_native_tools_testboot"; then
		no "control: the bare-call detector fires on the real rc script"
	elif bare_shutdown "$RC_M4"; then
		ok "control: mutant M4 is seen"
	else
		no "control: mutant M4 is not seen by the bare-call detector"
	fi

	# G1 (fix 3): quoted and evaluated calls are seen; the allowlisted lines, comments and row/echo/printf messages are not.  Never run.
	RC_M6=$T/rc-m6-sh-c
	{ cat "$KIT/nvidia_native_tools_testboot"; printf '%s\n' 'sh -c "shutdown -r now"'; } > "$RC_M6"
	RC_M7=$T/rc-m7-eval
	{ cat "$KIT/nvidia_native_tools_testboot"; printf '%s\n' "eval 'shutdown -r now'"; } > "$RC_M7"
	for _mm in M6:$RC_M6 M7:$RC_M7; do
		_mn=${_mm%%:*}; _mf=${_mm#*:}
		if cmp -s "$KIT/nvidia_native_tools_testboot" "$_mf"; then
			no "control: mutant $_mn does not differ from the original"
		elif bare_shutdown "$_mf" && [ "$(bare_shutdown_lines "$_mf" | wc -l | tr -d ' ')" = 1 ]; then
			ok "control: mutant $_mn is seen (only the planted line is reported)"
		else
			no "control: mutant $_mn is not seen by the bare-call detector: '$(bare_shutdown_lines "$_mf")'"
		fi
	done
	RC_CLEAN=$T/rc-clean-words
	{
		cat "$KIT/nvidia_native_tools_testboot"
		printf '%s\n' '# a comment: shutdown -r now, then if ! shutdown -r +1' \
		    'row deadman fail "message with shutdown -r now and sh -c shutdown in it"' \
		    'echo "shutdown -r now" >&2' \
		    "printf '%s\\n' 'eval shutdown -r now'"
	} > "$RC_CLEAN"
	if cmp -s "$KIT/nvidia_native_tools_testboot" "$RC_CLEAN"; then
		no "control: the clean-words copy does not differ from the original"
	elif bare_shutdown "$RC_CLEAN"; then
		no "control: the detector flags comments, allowlisted lines or row/echo/printf messages: '$(bare_shutdown_lines "$RC_CLEAN")'"
	else
		ok "control: comments, the allowlisted lines and row/echo/printf messages that hold the word shutdown are not flagged"
	fi
fi

# (g) static checks
for _f in make-be.sh check-be.sh bare-shutdown-check.sh guard.sh nvidia_native_tools_testboot gpu-detect.sh testboot-return; do
	sh -n "$KIT/$_f" && ok "$_f is valid sh" || no "$_f has a syntax error"
done
sh -n "$repo/tests/libnvrm/build-probes.sh" && ok "build-probes.sh is valid sh" || no "build-probes.sh has a syntax error"
/usr/local/bin/python3 -I -c "import sys; compile(open(sys.argv[1]).read(), sys.argv[1], \"exec\")" "$KIT/summarize.py" 2> /dev/null && ok "summarize.py compiles" || no "summarize.py does not compile"
grep -v '^[[:space:]]*#' "$KIT/nvidia_native_tools_testboot" | grep -E 'kldload[^"]*linux|kldunload|bectl activate' > /dev/null && no "the rc script loads a linux module, unloads a module or activates a BE" || ok "the rc script loads no linux module, unloads nothing, activates no BE"
# the README states the rule of the guard, not the history of the change that made it
grep -n '2026-11-23' "$repo/README.md" > /dev/null && no "the README tells the history of the guard instead of its rule" || ok "the README states the rule of the guard, not the history of the change"

# G4: run the complete static contract on the real rc, not on either sentinel copy.
if guard_static "$KIT/nvidia_native_tools_testboot" "$T/g4-static.out"; then
	ok "G4 static real-path, boot/BE/marker, exact-pid and no-pattern-kill checks pass"
else
	no "G4 static checks failed: $(tr '\n' ';' < "$T/g4-static.out")"
fi

# F3: the pure decision function, run as a table; every single-condition failure refuses, only the all-true row passes
_dm_want="1 1 1 1 1 1 1 1 0"
_dm_got=$(dm_table "$KIT/nvidia_native_tools_testboot")
[ "$_dm_got" = "$_dm_want" ] && ok "F3 dm_decide table: every single-condition failure refuses, only the all-true row returns 0 ($_dm_got)" || no "F3 dm_decide table is '$_dm_got', not '$_dm_want'"
_mk_mutant() {	# _mk_mutant <name> <sed expression>: a copy of the rc with one decision condition changed, cmp-checked distinct
	sed "$2" "$KIT/nvidia_native_tools_testboot" > "$T/rc-mut-$1"
	if cmp -s "$KIT/nvidia_native_tools_testboot" "$T/rc-mut-$1"; then no "control: dm_decide mutant $1 does not differ from the original"; return 1; fi
	_got=$(dm_table "$T/rc-mut-$1")
	if [ "$_got" != "$_dm_want" ]; then ok "control: dm_decide mutant $1 is seen as a wrong table ($_got)"; else no "control: dm_decide mutant $1 gives the right table: it is not seen"; fi
}
_mk_mutant uid-dropped 's/if \[ "\$1" != 0 \]; then/if false; then/'
_mk_mutant autoboot-flipped 's/if \[ "\$2" != yes \]; then/if [ "$2" = yes ]; then/'
_mk_mutant rc_fast-dropped 's/if \[ "\$3" != yes \]; then/if false; then/'
_mk_mutant be-dropped 's/if \[ -z "\$6" \] || \[ "\$6" != "\$5" \]; then/if false; then/'

# G6: make-be.sh has no shutdown command; a planted command proves the check can fail.
if grep -v '^[[:space:]]*#' "$KIT/make-be.sh" | sed 's/"[^"]*"//g' | grep -Eq '(^|[;&|()])[[:space:]]*shutdown([[:space:]]|$)'; then
	no "G6 make-be.sh contains a shutdown command"
else
	ok "G6 make-be.sh contains no shutdown command"
fi
{ cat "$KIT/make-be.sh"; printf '\nshutdown -r +1 "planted G6 control"\n'; } > "$T/make-be-shutdown-mutant"
if grep -v '^[[:space:]]*#' "$T/make-be-shutdown-mutant" | sed 's/"[^"]*"//g' | grep -Eq '(^|[;&|()])[[:space:]]*shutdown([[:space:]]|$)'; then
	ok "G6 control: a planted make-be.sh shutdown command is seen"
else
	no "G6 control: a planted make-be.sh shutdown command is not seen"
fi

# G2: M1's deliberate hit was moved aside after its control; any other PATH-sentinel hit is a failure.
if [ ! -s "$SENT/hits" ]; then
	ok "G2 no unexpected path reached the shutdown sentinel"
else
	no "G2 unexpected shutdown sentinel hits: $(cat "$SENT/hits")"
fi

# the boot comparison against the real boot capture of 2026-11-22 (Track #2362): its own result is counted here
_bf=$(sh "$repo/tests/libnvrm/boot_fixture_test.sh" "$T" 2>&1); _bfrc=$?
[ "$_bfrc" = 0 ] && ok "boot_fixture_test.sh: boot_compare.py fails the old capture, passes the derived one, fails every mutation ($(printf '%s\n' "$_bf" | grep -c '^ok') ok)" || no "boot_fixture_test.sh: $_bfrc failure(s): $(printf '%s\n' "$_bf" | grep '^FAIL' | head -3)"

# the documented standalone run (no argument) works on a fresh checkout, which has no tmp/, and says so when it cannot
_fc=$T/fresh-checkout
mkdir -p "$_fc/tests/libnvrm" "$_fc/tests/data"
cp "$repo/tests/libnvrm/boot_fixture_test.sh" "$repo/tests/libnvrm/boot_compare.py" "$repo/tests/libnvrm/board-amp001.env" "$_fc/tests/libnvrm/"
cp -R "$repo/tests/data/nvrm-info-boot-20261122T095018Z" "$_fc/tests/data/"
cp "$repo/SOURCES" "$_fc/"
_fo=$(cd "$_fc" && sh tests/libnvrm/boot_fixture_test.sh 2>&1); _forc=$?
[ "$_forc" = 0 ] && [ -d "$_fc/tmp" ] && printf '%s\n' "$_fo" | grep -q '^== boot_fixture_test: 0 failures' && ok "boot_fixture_test.sh with no argument on a checkout without tmp/ runs and exits 0" || no "boot_fixture_test.sh with no argument on a fresh checkout: rc=$_forc: $(printf '%s\n' "$_fo" | tail -2)"
_fo=$(sh "$repo/tests/libnvrm/boot_fixture_test.sh" /dev/null/nope 2>&1); _forc=$?
[ "$_forc" = 99 ] && printf '%s\n' "$_fo" | grep -q 'cannot create a scratch directory under /dev/null/nope' && ok "boot_fixture_test.sh: a scratch directory that cannot be made exits 99 with a message (not a failure count)" || no "boot_fixture_test.sh with an unusable scratch dir: rc=$_forc: $_fo"

echo "native_tools_kit_test: $pass passed, $fail failed"
[ "$fail" = 0 ]

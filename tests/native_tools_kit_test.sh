#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-2-Clause
#
# native_tools_kit_test.sh - the native-tools test-boot kit (tests/native-tools-testboot/, Track #2362) is sound
# without a boot:
#   (a) guard_env: a listing with a linux module (linux64, nvidia_linux.ko without linux64, linuxkpi) fails; a
#       compat.linux that answers fails; a kldstat that failed, printed nothing or lacks kernel or a required file is
#       an error; a sysctl failure that is not "unknown oid" is an error; a clean listing passes; guard_env_delta finds
#       a module that appeared;
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
#       rows are written; a base whose loader.conf loads linux is refused; an existing BE name is refused with the next
#       free number; check-be.sh -m -U on the fake clone passes every check but the commit comparison;
#   (f) the rc one-shot, run in the foreground with stubbed system commands: the rows come out in order, env-before
#       and env-loaded pass, nvrm-info-native passes (the real nvrm-info, traced), the static rows carry their status,
#       testboot-return is called last, the run is copied out;
#   (g) every script is valid sh; the rc script (comments left out) has no kldload of a linux module, no kldunload
#       and no bectl activate.
# Run: sh tests/native_tools_kit_test.sh   (no root; writes only under $GB10_WORK/tmp)

set -u
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
KIT=$repo/tests/native-tools-testboot
WORK=${GB10_WORK:-$HOME/work/gb10}
STAGE=${NVNT_STAGE:-$WORK/logs/native-tools/stage-a682522}
mkdir -p "$WORK/tmp"
T=$(mktemp -d "$WORK/tmp/nvnt-kit.XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok() { pass=$((pass + 1)); echo "ok   $*"; }
no() { fail=$((fail + 1)); echo "FAIL $*"; }
expect() {	# expect <want status> <got status> <what>
	if [ "$1" = "$2" ]; then ok "$3"; else no "$3 (exit $2, wanted $1)"; fi
}
. "$KIT/guard.sh"

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
guard_plain_path /home/a/b > /dev/null; expect 0 $? "guard_plain_path: a plain path passes"
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
[ "$(echo $planned | wc -w | tr -d ' ')" = 34 ] && ok "summarize --planned lists the 34 planned rows" || no "summarize --planned lists $(echo $planned | wc -w) rows"
mkrun() {	# mkrun <dir> <status of the static rows>
	mkdir -p "$1"; : > "$1/results.jsonl"
	for _r in $planned; do
		case $_r in
		done) _s=info ;;
		uvm-* | prime-import | render-uapi | nvrm-s2-memory) _s=$2 ;;
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

# (e) make-be.sh with the hooks and a fake clone
if [ ! -f "$STAGE/SHA256-native-a682522.txt" ]; then
	no "the staged build $STAGE is missing: (e) and (f) need it (build main, stage it, or set NVNT_STAGE)"
else
	mkclone() {
		rm -rf "$1"; mkdir -p "$1/etc/rc.conf.d" "$1/boot/modules" "$1/boot/kernel" "$1/sbin" "$1/usr/local/etc/rc.d"
		printf 'hostname="t"\nlinux_enable="YES"\nkld_list="filemon amdgpu /boot/kernel/linux64.ko"\nother_testboot_enable="YES"\n' > "$1/etc/rc.conf"
		printf 'zfs_load="YES"\n' > "$1/boot/loader.conf"
		cp /sbin/shutdown "$1/sbin/shutdown"
		mkdir -p "$1/usr/local/bin"; printf '#!/bin/sh\n' > "$1/usr/local/bin/python3"; chmod 0755 "$1/usr/local/bin/python3"
	}
	cat > "$T/bectl" <<EOF
#!/bin/sh
echo "bectl \$*" >> "$T/bectl.log"
case \$1 in list) printf 'cloudbsd-rx7600\tNR\nnvidia-native-tools-test-20990101-1\t-\n' ;; esac
exit 0
EOF
	chmod 0755 "$T/bectl"
	MB() { env GB10_TEST_HOOKS=1 NVNT_BECTL="$T/bectl" NVNT_MNT="$T/clone/root" NVNT_NOT_ROOT=1 NVNT_NO_GIT_CHECK=1 GB10_WORK="$WORK" sh "$KIT/make-be.sh" "$@"; }
	mkclone "$T/clone/root"
	MB -D 20990102 -m "$STAGE" -o "$WORK/logs/native-tools-testboot" > "$T/mb.out" 2>&1; expect 0 $? "make-be.sh builds the fake clone"
	R=$T/clone/root
	[ "$(sysrc -f "$R/etc/rc.conf" -n linux_enable)" = NO ] && ok "make-be.sh: linux_enable is NO" || no "make-be.sh: linux_enable is $(sysrc -f "$R/etc/rc.conf" -n linux_enable)"
	[ "$(sysrc -f "$R/etc/rc.conf" -n kld_list)" = filemon ] && ok "make-be.sh: amdgpu and linux64 are stripped from kld_list" || no "make-be.sh: kld_list is $(sysrc -f "$R/etc/rc.conf" -n kld_list)"
	sysrc -f "$R/etc/rc.conf" -n devmatch_blocklist | grep -q 'amdgpu .*linuxkpi' && ok "make-be.sh: devmatch_blocklist is set in rc.conf" || no "make-be.sh: no devmatch_blocklist in rc.conf"
	grep -q '^devmatch_blocklist=".*amdgpu' "$R/boot/loader.conf" && ok "make-be.sh: devmatch_blocklist kenv in loader.conf" || no "make-be.sh: no devmatch_blocklist kenv"
	grep -q '^other_testboot_enable="NO"' "$R/etc/rc.conf" && ok "make-be.sh: another kit is turned off" || no "make-be.sh: the other kit is still on"
	for _f in nvidia.ko nvidia-modeset.ko nvidia_gsp_ga10x_fw.ko nvrm-info libnvrm.so.1; do
		cmp -s "$STAGE/$_f" "$R/boot/modules.nvnative-test/$_f" && ok "make-be.sh: $_f is installed" || no "make-be.sh: $_f is not installed"
	done
	[ "$(head -1 "$R/usr/local/share/nvidia-native-tools-test/static-rows/uvm-ioctl-suite" 2> /dev/null)" = needs-linux ] && ok "make-be.sh: the uvm row is needs-linux (nvidia-uvm.ko depends on the Linuxulator)" || no "make-be.sh: the uvm row is $(head -1 "$R/usr/local/share/nvidia-native-tools-test/static-rows/uvm-ioctl-suite" 2> /dev/null)"
	grep -q 'bectl activate' "$T/bectl.log" && no "make-be.sh armed the boot without --activate" || ok "make-be.sh does not arm without --activate"
	TMPDIR=$T sh "$KIT/check-be.sh" -m "$R" -U -s "$STAGE/SHA256-native-a682522.txt" > "$T/cb.out" 2>&1
	# the commit comparisons (the version file, the files of the commit, the VENDOR pins read from the commit) cannot
	# pass for a work tree installed with NVNT_NO_GIT_CHECK; every other check must
	_cbf=$(grep '^FAIL' "$T/cb.out" | grep -v 'differs from the one of commit' | grep -v 'the clone records' | grep -v 'does not equal its VENDOR pin')
	[ -z "$_cbf" ] && ok "check-be.sh: every check but the commit comparison passes on the fake clone ($(grep -c '^ok' "$T/cb.out") ok)" || no "check-be.sh on the fake clone: $_cbf"
	for _f in gpu-detect.sh testboot-return; do
		_w=$(awk -v f="$_f" '$1 == "file" && $3 == f { on = 1; next } $1 == "file" { on = 0 } on && $1 == "sha256" { print $3; exit }' "$KIT/VENDOR")
		[ "$(sha256 -q "$KIT/$_f")" = "$_w" ] && ok "$_f of the work tree equals its VENDOR pin" || no "$_f of the work tree differs from its VENDOR pin"
	done
	# controls
	mkclone "$T/clone2/root"; printf 'linux_load="YES"\n' >> "$T/clone2/root/boot/loader.conf"
	env GB10_TEST_HOOKS=1 NVNT_BECTL="$T/bectl" NVNT_MNT="$T/clone2/root" NVNT_NOT_ROOT=1 NVNT_NO_GIT_CHECK=1 sh "$KIT/make-be.sh" -D 20990102 -m "$STAGE" > "$T/mb2.out" 2>&1
	expect 1 $? "make-be.sh refuses a base whose loader.conf loads linux"
	sh "$KIT/make-be.sh" -h > "$T/help.out" 2>&1; grep -q 'NVNT_NO_GIT_CHECK (the work tree is installed)' "$T/help.out" && ok "make-be.sh -h prints the whole header" || no "make-be.sh -h is cut short"
	grep -q "logs/native-tools-testboot" "$R/etc/rc.conf.d/nvidia_native_tools_testboot" && grep -q "^nvidia_native_tools_testboot_copyout=\"$WORK/logs/native-tools-testboot\"" "$R/etc/rc.conf.d/nvidia_native_tools_testboot" && ok "make-be.sh: the copy-out is under GB10_WORK by default" || no "make-be.sh: copy-out $(grep copyout "$R/etc/rc.conf.d/nvidia_native_tools_testboot")"
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
	[ -f "$WORK/logs/uvm-2373/nvidia-v6-phase0.ko" ] && { guard_ko_native "$WORK/logs/uvm-2373/nvidia-v6-phase0.ko" "$T/kodep" $LK > /dev/null; expect 1 $? "guard_ko_native: the v6 nvidia.ko (linux64elf, linux_common) fails"; }
	[ -f "$WORK/logs/uvm-2373/nvidia-uvm-v5.ko" ] && { guard_ko_native "$WORK/logs/uvm-2373/nvidia-uvm-v5.ko" "$T/kodep" $LK > /dev/null; expect 1 $? "guard_ko_native: nvidia-uvm-v5.ko fails"; }
	# a module calling into LinuxKPI by unprefixed names, with no MODULE_DEPEND on it, is caught by its imports
	guard_lkpi_imports "$STAGE/nvidia.ko" $LK > /dev/null; expect 0 $? "guard_lkpi_imports: nvidia.ko of main imports nothing LinuxKPI defines"
	[ -f "$WORK/logs/uvm-2373/nvidia-drm-v5.ko" ] && { guard_lkpi_imports "$WORK/logs/uvm-2373/nvidia-drm-v5.ko" $LK > "$T/lki.out"; expect 1 $? "guard_lkpi_imports: nvidia-drm.ko (a LinuxKPI user) fails: $(cut -c1-90 "$T/lki.out")"; }
	mkdir -p "$T/nmstub2"; printf '#!/bin/sh\ncase "$1" in -u) echo "                 U idr_alloc"; echo "                 U printf" ;; *) echo "0000000000001000 T idr_alloc" ;; esac\n' > "$T/nmstub2/nm"; chmod 0755 "$T/nmstub2/nm"
	( PATH="$T/nmstub2:$PATH"; guard_lkpi_imports /x /y > /dev/null ); expect 1 $? "guard_lkpi_imports: an unprefixed LinuxKPI import (idr_alloc) fails"
	[ -f "$WORK/logs/uvm-2373/nvidia-uvm-v5.ko" ] && { guard_undef "$WORK/logs/uvm-2373/nvidia-uvm-v5.ko" > /dev/null; expect 1 $? "guard_undef: nvidia-uvm-v5.ko has Linux symbols"; }
	guard_copyout_dataset /x zroot/bootenv/cloudbsd-rx7600 zroot/bootenv/cloudbsd-rx7600 > /dev/null; expect 1 $? "guard_copyout_dataset: under a boot environment root named bootenv fails"
	guard_copyout_dataset /x zroot/ROOT zroot/ROOT/cloudbsd-rx7600 > /dev/null; expect 1 $? "guard_copyout_dataset: the boot environment root itself fails"
	guard_copyout_dataset /x tank/ROOT/x zroot/ROOT/cloudbsd-rx7600 > /dev/null; expect 0 $? "guard_copyout_dataset: another pool's ROOT is not a boot environment"
	guard_copyout_dataset /x zroot/home/mlapointe zroot/ROOT/cloudbsd-rx7600 > /dev/null; expect 0 $? "guard_copyout_dataset: the home dataset passes"
	guard_copyout_dataset /x zroot/home/mlapointe - > /dev/null; expect 2 $? "guard_copyout_dataset: no bootfs is an error"
	guard_copyout_dataset /x tank/results - zroot/ROOT/cloudbsd-rx7600 > /dev/null; expect 0 $? "guard_copyout_dataset: a data pool without bootfs passes"
	guard_copyout_dataset /x tank/ROOT/a zroot/ROOT/b tank/ROOT/c > /dev/null; expect 1 $? "guard_copyout_dataset: under the boot environment root of a second pool fails"
	mkdir -p "$R/etc/rc.conf.d"; : > "$R/etc/rc.conf.d/linux"
	TMPDIR=$T sh "$KIT/check-be.sh" -m "$R" -U -s "$STAGE/SHA256-native-a682522.txt" > "$T/cb-ov.out" 2>&1
	grep -q '^FAIL etc/rc.conf.d/linux exists' "$T/cb-ov.out" && ! grep -q '^ok   no later rc.conf' "$T/cb-ov.out" && ok "check-be.sh: an rc.conf.d/linux override is a FAIL, with no ok after it" || no "check-be.sh: the rc.conf.d/linux override is not reported cleanly"
	rm -f "$R/etc/rc.conf.d/linux"
	printf 'linux_enable="YES"\n' >> "$R/etc/rc.conf"
	TMPDIR=$T sh "$KIT/check-be.sh" -m "$R" -U -s "$STAGE/SHA256-native-a682522.txt" > "$T/cb2.out" 2>&1
	grep -q '^FAIL rc.conf: linux_enable' "$T/cb2.out" && ok "check-be.sh catches linux_enable=YES planted in the clone" || no "check-be.sh misses a planted linux_enable=YES"

	# (f) the rc one-shot, foreground, stubbed system commands
	S=$T/stubs; mkdir -p "$S" "$T/dev" "$T/kitroot/static-rows" "$T/mods" "$T/copyout"
	ln -s /dev/null "$T/dev/nvidia1"; ln -s /dev/null "$T/dev/nvidiactl"; ln -s /dev/null "$T/dev/nvidia-modeset"
	for _f in nvidia.ko nvidia-modeset.ko nvidia_gsp_ga10x_fw.ko nvrm-info libnvrm.so.1; do cp "$STAGE/$_f" "$T/mods/"; done
	cp "$STAGE/SHA256-native-a682522.txt" "$T/kitroot/SHA256.txt"
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
	printf '#!/bin/sh\nexit 0\n' > "$S/shutdown"; printf '#!/bin/sh\nexit 0\n' > "$S/pgrep"; printf '#!/bin/sh\nexit 0\n' > "$S/pkill"
	printf '#!/bin/sh\necho "dmesg stub"\n' > "$S/dmesg"; printf '#!/bin/sh\nprintf "t\\tNR\\n"\n' > "$S/bectl"
	printf '#!/bin/sh\n[ "$*" = "-n linux_enable" ] && echo NO\n' > "$S/sysrc"
	printf '#!/bin/sh\necho "testboot-return $*" > "%s/returned"\n' "$T" > "$T/return"
	chmod 0755 "$S"/* "$T/return"
	rcrun() {	# rcrun <work dir> <copy-out dir> <return script> [extra stub dir first in PATH]
		env PATH="${4:+$4:}$S:$PATH" nvidia_native_tools_testboot_enable=YES nvidia_native_tools_testboot_foreground=YES \
		    nvidia_native_tools_testboot_kit="$T/kitroot" nvidia_native_tools_testboot_mods="$T/mods" \
		    nvidia_native_tools_testboot_work="$1" nvidia_native_tools_testboot_fallback="$1.fallback" \
		    nvidia_native_tools_testboot_copyout="$2" nvidia_native_tools_testboot_return="$3" \
		    nvidia_native_tools_testboot_devdir="$T/dev" nvidia_native_tools_testboot_vram=17179869184 nvidia_native_tools_testboot_sm=12.0 \
		    nvidia_native_tools_testboot_lockfile="$T/nolock" nvidia_native_tools_testboot_version="$T/nover" \
		    sh "$KIT/nvidia_native_tools_testboot" onestart > "$1.out" 2>&1
		ls -d "$1"/* 2> /dev/null | head -1
	}
	RUN=$(rcrun "$T/work" "$T/copyout" "$T/return")
	if [ -z "$RUN" ]; then no "the rc one-shot made no run directory: $(cat "$T/work.out")"; else
		st() { /usr/local/bin/python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print([r["status"] for r in d["rows"] if r["name"]==sys.argv[2]][0])' "${2:-$RUN}/summary.json" "$1" 2> /dev/null; }
		for _p in deadman:pass ko-native-nvidia:pass ko-native-nvidia-modeset:pass panic-settings:pass linux-enable:pass env-before:pass load:pass env-loaded:pass gpu-node:pass gpu-detect-native:pass root-open:pass gpu-verify:pass nvidiactl-open:pass modeset-open:pass nvrm-info-native:pass nvrm-info-no-new-module:pass uvm-ioctl-suite:needs-linux render-uapi:not-available nvrm-s2-memory:not-available env-after:pass env-after-delta:pass done:info; do
			_r=${_p%%:*}; _w=${_p#*:}; _g=$(st "$_r")
			[ "$_g" = "$_w" ] && ok "rc one-shot: row $_r is $_w" || no "rc one-shot: row $_r is '${_g:-missing}', wanted $_w"
		done
		_n=$(st nvrm-info); case $_n in pass | fail) ok "rc one-shot: nvrm-info ran (status $_n; no driver on the host, so fail is expected here)" ;; *) no "rc one-shot: nvrm-info is $_n" ;; esac
		grep -q 'pass .*/mods/nvrm-info is a FreeBSD-branded ELF' "$RUN/nvrm-info.execs" && ok "rc one-shot: the trace checked nvrm-info itself" || no "rc one-shot: nvrm-info is not in nvrm-info.execs"
		grep -q 'selected_node": "'"$T"'/dev/nvidia1"' "$RUN/gpu-detect.json" && ok "rc one-shot: gpu-detect chose nvidia1 (the BMC and the AMD card excluded)" || no "rc one-shot: gpu-detect did not choose nvidia1"
		[ "$(cat "$T/returned" 2> /dev/null)" = "testboot-return cloudbsd-rx7600" ] && ok "rc one-shot: testboot-return is called with the normal BE" || no "rc one-shot: testboot-return was not called"
		_c=$T/copyout/$(basename "$RUN")
		[ -f "$_c/summary.json" ] && ok "rc one-shot: the run is copied out" || no "rc one-shot: the run is not copied out"
		[ -f "$_c/testboot-return.txt" ] && grep -q 'testboot-return exit' "$_c/rc.log" && ok "rc one-shot: testboot-return.txt and the full rc.log reach the copy-out" || no "rc one-shot: the return record is not in the copy-out"
		[ "$(stat -f %Lp "$_c")" = 700 ] && ok "rc one-shot: the copy-out directory is 0700" || no "rc one-shot: the copy-out directory is $(stat -f %Lp "$_c")"
		grep -q '"verdict": "fail"\|"verdict": "incomplete"' "$RUN/summary.json" && ok "rc one-shot: the verdict is not pass with rows that cannot run natively" || no "rc one-shot: verdict $(grep '"verdict"' "$RUN/summary.json")"
	fi
	# a copy-out path with a symbolic link in it is refused; the run stays in the boot environment
	mkdir -p "$T/elsewhere"; ln -s "$T/elsewhere" "$T/linked"
	RUN2=$(rcrun "$T/work2" "$T/linked/out" "$T/return")
	[ -z "$(ls "$T/elsewhere")" ] && grep -q 'COULD NOT copy' "$RUN2/rc.log" && ok "rc one-shot: a copy-out through a symbolic link is refused" || no "rc one-shot: the copy went through the symbolic link ($(ls "$T/elsewhere"))"
	# a failed return still leaves its record in the copy-out
	printf '#!/bin/sh\necho "bectl activate failed"\nexit 1\n' > "$T/return-bad"; chmod 0755 "$T/return-bad"
	RUN3=$(rcrun "$T/work3" "$T/copyout3" "$T/return-bad")
	grep -q 'bectl activate failed' "$T/copyout3/$(basename "$RUN3")/testboot-return.txt" 2> /dev/null && ok "rc one-shot: a failed return is recorded in the copy-out" || no "rc one-shot: the failed return is not in the copy-out"
	# a module that does not load: the rows after it are not-run
	mkdir -p "$T/kfail"; printf '#!/bin/sh\necho "kldload: cannot load $1" >&2\nexit 1\n' > "$T/kfail/kldload"; chmod 0755 "$T/kfail/kldload"
	echo > "$T/loaded"
	RUN4=$(rcrun "$T/work4" "$T/copyout4" "$T/return" "$T/kfail")
	_bad=
	for _r in gpu-node root-open gpu-verify nvidiactl-open modeset-open nvrm-info nvrm-info-native nvrm-info-no-new-module; do
		[ "$(st "$_r" "$RUN4")" = not-run ] || _bad="$_bad $_r=$(st "$_r" "$RUN4")"
	done
	[ -z "$_bad" ] && ok "rc one-shot: after a failed load every later row is not-run" || no "rc one-shot: after a failed load:$_bad"
	# a dead-man timer that is not pending: nothing is loaded
	mkdir -p "$T/dmfail"; printf '#!/bin/sh\nexit 1\n' > "$T/dmfail/pgrep"; chmod 0755 "$T/dmfail/pgrep"
	echo > "$T/loaded"
	RUN5=$(rcrun "$T/work5" "$T/copyout5" "$T/return" "$T/dmfail")
	[ -z "$(tr -d '\n' < "$T/loaded")" ] && [ "$(st deadman "$RUN5")" = fail ] && [ "$(st load-nvidia "$RUN5")" = not-run ] && grep -q '"verdict": "fail"' "$RUN5/summary.json" \
	    && ok "rc one-shot: without a pending dead-man timer nothing is loaded and the verdict is fail" || no "rc one-shot: dead-man not pending: loaded '$(tr '\n' ' ' < "$T/loaded")', deadman $(st deadman "$RUN5"), load-nvidia $(st load-nvidia "$RUN5")"
	# an evidence file that claims pass is not trusted
	cp "$T/kitroot/static-rows/render-uapi" "$T/render-uapi.save"; chmod u+w "$T/kitroot/static-rows/render-uapi"; printf 'pass\nplanted\n' > "$T/kitroot/static-rows/render-uapi"
	echo > "$T/loaded"
	RUN6=$(rcrun "$T/work6" "$T/copyout6" "$T/return")
	cp "$T/render-uapi.save" "$T/kitroot/static-rows/render-uapi"
	[ "$(st render-uapi "$RUN6")" = error ] && ok "rc one-shot: a static row whose evidence says pass is an error" || no "rc one-shot: render-uapi with a planted pass is $(st render-uapi "$RUN6")"
	[ "$(st load-nvidia_gsp_ga10x_fw "$RUN4")" = fail ] && ok "rc one-shot: the failed load is a fail row" || no "rc one-shot: load-nvidia_gsp_ga10x_fw is $(st load-nvidia_gsp_ga10x_fw "$RUN4")"
fi

# (g) static checks
for _f in make-be.sh check-be.sh guard.sh nvidia_native_tools_testboot gpu-detect.sh testboot-return; do
	sh -n "$KIT/$_f" && ok "$_f is valid sh" || no "$_f has a syntax error"
done
/usr/local/bin/python3 -I -c "import sys; compile(open(sys.argv[1]).read(), sys.argv[1], \"exec\")" "$KIT/summarize.py" 2> /dev/null && ok "summarize.py compiles" || no "summarize.py does not compile"
grep -v '^[[:space:]]*#' "$KIT/nvidia_native_tools_testboot" | grep -E 'kldload[^"]*linux|kldunload|bectl activate' > /dev/null && no "the rc script loads a linux module, unloads a module or activates a BE" || ok "the rc script loads no linux module, unloads nothing, activates no BE"

echo "native_tools_kit_test: $pass passed, $fail failed"
[ "$fail" = 0 ]

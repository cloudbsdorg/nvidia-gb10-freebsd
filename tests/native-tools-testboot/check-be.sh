#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-2-Clause
#
# check-be.sh - the mount check of a native-tools test boot environment (Track #2362): looks into a built boot
# environment and says whether it will do what the kit says.  Run it on every built boot environment before arming
# it.  It reads only (bectl mounts read-write, so atime may change): nothing is loaded, booted or written.
#
# Usage: check-be.sh [-s SHA256FILE] [-c COMMIT] [-U] [-m MOUNTED_ROOT | BE]
#   BE         a boot environment to mount with bectl (run as root)
#   -m ROOT    check the tree already mounted at ROOT instead
#   -s FILE    the hash list it was built from (default $GB10_WORK/logs/native-tools/stage/SHA256.txt,
#              GB10_WORK defaulting to $HOME/work/gb10)
#   -c COMMIT  the commit the kit must record (default HEAD of this repository)
#   -U         do not check root ownership (the host test installs without root; only with -m)
# Environment: with GB10_TEST_HOOKS=1, not root and NVNT_NO_GIT_CHECK=1, an archive without git metadata is still
# checked; the commit comparisons fail, as the host test already expects, instead of hiding every later check.
#
# Checks, each printed "ok" or "FAIL"; exit 0 when all are ok, 1 when one failed, 2 on a usage error:
#   - staged files: the five files of the list equal their full hashes, are root-owned (0444, nvrm-info 0555), are
#     not symbolic links; no other file is in /boot/modules.nvnative-test; each .ko has no Linuxulator, LinuxKPI or drm
#     dependency (kldxref -d -v) and no undefined linux_, lkpi_ or linuxkpi_ symbol; nvrm-info and libnvrm.so.1 are
#     FreeBSD-branded;
#   - no Linux: rc.conf has linux_enable="NO", kld_list holds no amdgpu, radeonkms, i915kms, drm, dmabuf, nvidia or
#     linux module, devmatch_blocklist (rc.conf and loader.conf) names amdgpu and linuxkpi; no later rc.conf file and
#     no rc.conf.d file for linux, kld or devmatch overrides them; no loader.conf loads such a module; no nvidia
#     module in /boot/modules or /boot/kernel; no enabled rc.d service loads such a module by itself (a
#     required_modules entry: drm_ready loads amdgpu), and cloudbsd_hwprobe, when it is enabled, has the command
#     "probe" (it loads no KMS driver);
#   - the kit: the version file holds the commit; the rc script, guard.sh, summarize.py, gpu-detect.sh, the schema,
#     testboot-return and this script are the commit's; gpu-detect.sh and testboot-return equal their VENDOR pins;
#     every static row has a known status;
#   - dead-man (static): the rc script arms the timer before its first kldload and gates the loads on it, the default
#     is a positive number of minutes, no rc.conf sets it to 0, the marker holds the test BE name, the shutdown call
#     uses only nvidia_native_tools_testboot_shutdown, and shutdown(8) is in the clone; loader.conf has the panic settings;
#   - order: the firmware module is loaded before nvidia.ko, the GPU is opened as root before nvrm-info runs;
#   - the one-shot is enabled, every other *_testboot_enable is NO, the owner of the run directory is recorded, and
#     the copy-out directory is absolute and not on a boot environment dataset (zfs list of its nearest existing
#     parent, on this host).

set -u
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL
KITDIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH= cd -- "$KITDIR/../.." && pwd)
. "$KITDIR/guard.sh"
WORK=${GB10_WORK:-$HOME/work/gb10}
SHAFILE=$WORK/logs/native-tools/stage/SHA256.txt
SHAFILE_GIVEN=0
COMMIT=
MNT=
NOOWNER=0
help() { awk 'NR >= 5 && /^#/ { sub(/^# ?/, ""); print; next } NR >= 5 { exit }' "$0"; exit 0; }
usage() { echo "check-be.sh: ${1:-give a boot environment or -m ROOT} (check-be.sh -h shows every option)" >&2; exit 2; }
while [ $# -gt 0 ]; do
	case $1 in
	-s) [ $# -ge 2 ] || usage "-s needs a value"; SHAFILE=$2; SHAFILE_GIVEN=1; shift 2 ;;
	-c) [ $# -ge 2 ] || usage "-c needs a value"; COMMIT=$2; shift 2 ;;
	-m) [ $# -ge 2 ] || usage "-m needs a value"; MNT=$2; shift 2 ;;
	-U) NOOWNER=1; shift ;;
	-h | --help) help ;;
	-*) usage "unknown argument: $1" ;;
	*) break ;;
	esac
done
BE=${1:-}
[ -n "$MNT" ] || [ -n "$BE" ] || usage
[ -z "$MNT" ] || [ -z "$BE" ] || { echo "check-be.sh: give a boot environment or -m ROOT, not both" >&2; exit 2; }
[ "$NOOWNER" = 0 ] || [ -n "$MNT" ] || { echo "check-be.sh: -U is only for a tree given with -m" >&2; exit 2; }
if [ "$SHAFILE_GIVEN" = 0 ]; then guard_work_default "$(id -u)" check-be.sh -s || exit $?; fi
[ -f "$SHAFILE" ] || { echo "check-be.sh: no hash list $SHAFILE (give -s FILE)" >&2; exit 2; }
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_COMMON_DIR
git_() { git -c safe.directory="$REPO" --no-optional-locks -C "$REPO" "$@"; }
case ${COMMIT:-HEAD} in -*) echo "check-be.sh: the commit must not start with a dash" >&2; exit 2 ;; esac
NO_GIT=0
if [ "${GB10_TEST_HOOKS:-0}" = 1 ] && [ "$(id -u)" != 0 ] && [ "${NVNT_NO_GIT_CHECK:-0}" = 1 ] && ! git_ rev-parse --git-dir > /dev/null 2>&1; then
	# An archive has no commit id: keep COMMIT empty and use NO_GIT to record the deliberate rev-parse bypass.
	NO_GIT=1; COMMIT=${COMMIT:-}
else
	COMMIT=$(git_ rev-parse --verify --end-of-options "${COMMIT:-HEAD}^{commit}" 2> /dev/null) || { echo "check-be.sh: -c names no commit of $REPO" >&2; exit 2; }
fi

MOUNTED=0
MNTBASE=
SCR=
cleanup() {
	[ "$MOUNTED" = 0 ] || bectl umount "$BE" > /dev/null 2>&1
	[ -z "$MNTBASE" ] || { rmdir "$MNT" 2> /dev/null; rmdir "$MNTBASE" 2> /dev/null; }
	[ -z "$SCR" ] || rm -rf "$SCR"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if [ -z "$MNT" ]; then
	[ "$(id -u)" = 0 ] || { echo "check-be.sh: run as root to mount $BE (or use -m ROOT)" >&2; exit 2; }
	MNTBASE=$(mktemp -d /var/run/nvnt-check.XXXXXXXX) || exit 2
	MNT=$MNTBASE/root
	mkdir "$MNT" || exit 2
	MOUNTED=1
	bectl mount "$BE" "$MNT" > /dev/null || { MOUNTED=0; echo "check-be.sh: cannot mount $BE" >&2; exit 2; }
fi
SCR=$(mktemp -d "${TMPDIR:-/var/run}/nvnt-check-scr.XXXXXXXX") || exit 2

# the one bare-shutdown detector (shared with tests/native_tools_kit_test.sh)
. "$(dirname "$0")/bare-shutdown-check.sh" || { echo "check-be.sh: cannot read bare-shutdown-check.sh" >&2; exit 2; }

rc=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; rc=1; }
MODS=$MNT/boot/modules.nvnative-test
KROOT=$MNT/usr/local/share/nvidia-native-tools-test
RCS=$MNT/usr/local/etc/rc.d/nvidia_native_tools_testboot
RCC=$MNT/etc/rc.conf
FILES="nvidia_gsp_ga10x_fw.ko nvidia.ko nvidia-modeset.ko nvrm-info libnvrm.so.1"
# the modules a kld_list, a loader.conf or an rc.d service must not load.  The list is the one of guard.sh
# (GUARD_FORBID_RE), so the guard, make-be.sh and this script agree on it.
FORBID_RE=$GUARD_FORBID_RE
echo "check-be.sh: ${BE:-$MNT}, commit ${COMMIT:-none}, list $SHAFILE"
[ "$NO_GIT" = 0 ] || echo "check-be.sh: no git metadata; the commit comparisons below are expected to FAIL"

linked() { _acc=$MNT; for _c in $(echo "$1" | tr / ' '); do _acc=$_acc/$_c; [ ! -L "$_acc" ] || return 0; done; return 1; }
for _rel in boot/loader.conf boot/modules.nvnative-test usr/local/share/nvidia-native-tools-test usr/local/etc/rc.d/nvidia_native_tools_testboot usr/local/etc/nvidia_native_tools_testboot.version usr/local/etc/nvidia_native_tools_testboot.marker usr/local/sbin/testboot-return etc/rc.conf etc/rc.conf.d/nvidia_native_tools_testboot sbin/shutdown; do
	if linked "$_rel"; then bad "$_rel is, or lies below, a symbolic link of the clone"; fi
done
[ -z "$(find "$MODS" "$KROOT" -type l 2> /dev/null)" ] || bad "a symbolic link lies in the staged or kit directory of the clone"

# staged files
literal() { awk -v n="($1)" '$1 == "SHA256" && $2 == n && $3 == "=" && length($4) == 64 && $4 ~ /^[0-9a-f]+$/ { print $4; c++ } END { exit (c == 1 ? 0 : 1) }' "$SHAFILE"; }
[ "$(grep -c '^SHA256 (' "$SHAFILE")" = 5 ] && ok "the list holds five entries" || bad "the list $SHAFILE does not hold exactly five SHA256 entries"
for _f in $FILES; do
	_w=$(literal "$_f") || { bad "the list has no single full entry for $_f"; continue; }
	[ -f "$MODS/$_f" ] || { bad "$_f is not in /boot/modules.nvnative-test"; continue; }
	_g=$(sha256 -q "$MODS/$_f")
	[ "$_g" = "$_w" ] && ok "$_f is $_g" || bad "$_f is $_g, the list says $_w"
	case $_f in nvrm-info) _wm=555 ;; *) _wm=444 ;; esac
	_m=$(stat -f %Lp "$MODS/$_f"); _o=$(stat -f %u "$MODS/$_f")
	if [ "$NOOWNER" = 1 ]; then [ "$_m" = "$_wm" ] && ok "$_f is mode 0$_m (owner not checked: -U)" || bad "$_f is mode $_m, not 0$_wm"
	else [ "$_m $_o" = "$_wm 0" ] && ok "$_f is root-owned, mode 0$_m" || bad "$_f is mode $_m owner uid $_o: root-owned 0$_wm wanted"; fi
done
_extra=$(ls "$MODS" 2> /dev/null | grep -vxE 'nvidia_gsp_ga10x_fw\.ko|nvidia\.ko|nvidia-modeset\.ko|nvrm-info|libnvrm\.so\.1' | tr '\n' ' ')
[ -z "$_extra" ] && ok "no other file is staged (no nvidia-drm.ko, no Linux bridge)" || bad "other files are staged: $_extra"
for _k in nvidia_gsp_ga10x_fw.ko nvidia.ko nvidia-modeset.ko; do
	[ -f "$MODS/$_k" ] || continue
	rm -rf "$SCR/kd"; mkdir "$SCR/kd"; cp "$MODS/$_k" "$SCR/kd/"
	_d=$(kldxref -d -v "$SCR/kd" 2> /dev/null | sed -n 's/^[[:space:]]*depends on \([^.[:space:]]*\)\..*/\1/p' | sort -u | tr '\n' ' ')
	if [ -z "$_d" ]; then bad "kldxref reports no dependency for $_k: it could not read it"
	elif printf '%s\n' $_d | grep -Eiq 'linux|drm|dmabuf'; then bad "$_k depends on $_d: not native"
	else ok "$_k depends only on $_d"; fi
	_l=$(guard_undef "$MODS/$_k") && ok "${_l#* }" || bad "${_l#* }"
done
for _f in nvrm-info libnvrm.so.1; do
	[ -f "$MODS/$_f" ] || continue
	_l=$(guard_elf "$MODS/$_f") && ok "${_l#* }" || bad "${_l#* }"
done
if [ -f "$KROOT/SHA256.txt" ] && cmp -s "$SHAFILE" "$KROOT/SHA256.txt"; then ok "the installed hash list is the given one"; else bad "the installed hash list is missing or differs from $SHAFILE"; fi

# no Linux layer, no LinuxKPI driver
_v() { sysrc -f "$RCC" -n "$1" 2> /dev/null; }
[ "$(_v linux_enable)" = NO ] && ok "rc.conf: linux_enable=\"NO\"" || bad "rc.conf: linux_enable is '$(_v linux_enable)', not NO"
_badk=
for _k in $(_v kld_list); do _b=${_k##*/}; _b=${_b%.ko}; printf '%s\n' "$_b" | grep -Eiq "$FORBID_RE" && _badk="$_badk $_k"; done
[ -z "$_badk" ] && ok "rc.conf: kld_list is '$(_v kld_list)': no Linux, LinuxKPI, drm or nvidia module" || bad "rc.conf: kld_list loads$_badk"
_bl=" $(_v devmatch_blocklist) "
case $_bl in *" amdgpu "*" linuxkpi "*) ok "rc.conf: devmatch_blocklist names amdgpu and linuxkpi" ;; *) bad "rc.conf: devmatch_blocklist does not name amdgpu and linuxkpi: '$_bl'" ;; esac
grep -Eq '^devmatch_blocklist="(.* )?amdgpu .*linuxkpi.*"' "$MNT/boot/loader.conf" 2> /dev/null && ok "loader.conf: devmatch_blocklist kenv names amdgpu and linuxkpi" || bad "loader.conf: no devmatch_blocklist kenv naming amdgpu and linuxkpi"
_ov=0
for _f in etc/rc.conf.local usr/local/etc/rc.conf usr/local/etc/rc.conf.local; do
	[ -f "$MNT/$_f" ] || continue
	if grep -Eq '^[[:space:]]*(linux_enable|kld_list|devmatch_blocklist)[[:space:]]*=' "$MNT/$_f"; then bad "$_f overrides linux_enable, kld_list or devmatch_blocklist"; _ov=1; fi
done
for _s in linux kld devmatch; do for _d in etc/rc.conf.d usr/local/etc/rc.conf.d; do
	if [ -e "$MNT/$_d/$_s" ]; then bad "$_d/$_s exists and would override rc.conf"; _ov=1; fi
done; done
[ "$_ov" = 1 ] || ok "no later rc.conf file or rc.conf.d file overrides those settings"
_lf=
for _f in boot/loader.conf boot/loader.conf.local; do [ -f "$MNT/$_f" ] && _lf="$_lf $MNT/$_f"; done
[ -d "$MNT/boot/loader.conf.d" ] && _lf="$_lf $(find "$MNT/boot/loader.conf.d" -type f | tr '\n' ' ')"
_hit=
for _f in $_lf; do
	sed -e :a -e '/\\$/N; s/\\\n//; ta' "$_f" | grep -Eiq '^[[:space:]]*[A-Za-z0-9_-]*(linux|amdgpu|radeonkms|i915kms|drm|dmabuf|nvidia)[A-Za-z0-9_-]*_load[[:space:]]*=[[:space:]]*"?[Yy]' && _hit="$_hit $_f"
done
[ -z "$_hit" ] && ok "no loader.conf loads a Linux, LinuxKPI, drm or nvidia module" || bad "these loader files load such a module:$_hit"
_pk=$(ls "$MNT"/boot/modules/nvidia*.ko "$MNT"/boot/kernel/nvidia*.ko 2> /dev/null)
[ -z "$_pk" ] && ok "no nvidia module in /boot/modules or /boot/kernel" || bad "nvidia modules outside the staged directory: $_pk"
# an enabled rc.d service that loads a forbidden module by itself: rc(8) loads the module of its required_modules
# entry after kld_list was stripped (drm_ready loads amdgpu).  The rule is generic: every rc script of the clone is
# read, and the modules its required_modules names are expanded with the rc.conf variables it uses.  A service whose
# rcvar or whose modules cannot be read is a FAIL too: a service that is not read is a service that is not known.
guard_rc_offenders "$MNT" "$FORBID_RE" > "$SCR/rc-offenders.txt"
while IFS='|' read -r _svc _rcvar _mods; do
	if [ "$_rcvar" = '?' ]; then
		bad "the rc.d service $_svc has a required_modules entry that could not be read ($_mods): it cannot be known to load nothing"
		continue
	fi
	bad "the rc.d service $_svc ($_rcvar) is enabled and its required_modules loads $_mods: rc(8) loads it by itself"
done < "$SCR/rc-offenders.txt"
# the hwprobe service loads the KMS driver of the card it finds, unless its command is "probe" (Server).  Its loading
# is not through a required_modules entry, but through the probe it runs.
if guard_hwprobe_loads "$MNT" > "$SCR/hwprobe.txt" 2> /dev/null; then
	_hpc=$(cut -d'|' -f2 "$SCR/hwprobe.txt")
	bad "cloudbsd_hwprobe is enabled with command='$_hpc': it loads the KMS driver of the card it finds; set cloudbsd_hwprobe_command=\"probe\""
else
	ok "cloudbsd_hwprobe loads no KMS driver (it is off, or its command is probe)"
fi
# a devd rule that loads a driver by itself (kldload, or the hwprobe when it applies the driver)
while IFS='|' read -r _f _w; do
	[ -n "$_f" ] || continue
	bad "the devd rule $_f $_w: it loads a driver by itself"
done <<EOF
$(guard_devd_loaders "$MNT" "$FORBID_RE")
EOF

# the kit
_ver=$(cat "$MNT/usr/local/etc/nvidia_native_tools_testboot.version" 2> /dev/null || echo none)
[ "$_ver" = "$COMMIT" ] && ok "the clone records commit $_ver" || bad "the clone records '$_ver', not $COMMIT"
_marker=$MNT/usr/local/etc/nvidia_native_tools_testboot.marker
_marked_be=$(sed -n '1p' "$_marker" 2> /dev/null)
if [ ! -f "$_marker" ]; then
	bad "the test boot environment marker is not installed"
elif [ -n "$BE" ]; then
	[ "$_marked_be" = "$BE" ] && ok "the marker holds the test boot environment name $BE" || bad "the marker holds '$_marked_be', not $BE"
elif printf '%s\n' "$_marked_be" | grep -Eq '^nvidia-native-tools-test-[0-9]{8}-[1-9][0-9]*$'; then
	ok "the marker holds a native-tools test boot environment name ($_marked_be)"
else
	bad "the marker holds '$_marked_be', not a native-tools test boot environment name"
fi
for _p in nvidia_native_tools_testboot:"$RCS" guard.sh:"$KROOT/guard.sh" summarize.py:"$KROOT/summarize.py" gpu-detect.sh:"$KROOT/gpu-detect.sh" native-tools-summary.schema.json:"$KROOT/native-tools-summary.schema.json" testboot-return:"$MNT/usr/local/sbin/testboot-return" check-be.sh:"$KROOT/repo/tests/native-tools-testboot/check-be.sh"; do
	_n=${_p%%:*}; _dst=${_p#*:}
	[ -f "$_dst" ] || { bad "$_n is not installed ($_dst)"; continue; }
	git_ show "$COMMIT:tests/native-tools-testboot/$_n" 2> /dev/null | cmp -s - "$_dst" && ok "$_n is the one of commit $COMMIT" || bad "$_n differs from the one of commit $COMMIT"
done
pin() { git_ show "$COMMIT:tests/native-tools-testboot/VENDOR" 2> /dev/null | awk -v f="$1" '$1 == "file" && $3 == f { on = 1; next } $1 == "file" { on = 0 } on && $1 == "sha256" { print $3; exit }'; }
for _p in gpu-detect.sh:"$KROOT/gpu-detect.sh" testboot-return:"$MNT/usr/local/sbin/testboot-return"; do
	_n=${_p%%:*}; _w=$(pin "$_n")
	[ -n "$_w" ] && [ "$(sha256 -q "${_p#*:}" 2> /dev/null)" = "$_w" ] && ok "$_n equals its VENDOR pin" || bad "$_n does not equal its VENDOR pin ${_w:-none}"
done
for _r in uvm-ioctl-suite uvm-owner-probe uvm-owner-race prime-import render-uapi nvrm-s2-memory; do
	_s=$(head -1 "$KROOT/static-rows/$_r" 2> /dev/null)
	case $_s in needs-linux | needs-linuxkpi | not-available) ok "static row $_r: $_s" ;; *) bad "static row $_r has status '${_s:-none}'" ;; esac
done

# dead-man and order (static)
lineof() { grep -n "$1" "$RCS" 2> /dev/null | grep -v '^[0-9]*:[[:space:]]*#' | head -1 | cut -d: -f1; }
# markof <name>: the line of the "# check-be: <name>" marker the rc script puts on (or just before) each step checked here
markof() { grep -n "# check-be: $1\( \|$\)" "$RCS" 2> /dev/null | head -1 | cut -d: -f1; }
if [ -f "$RCS" ]; then
	_arm=$(markof deadman-arm); _first=$(lineof 'kldload ')
	_gate=$(markof deadman-gate)
	_lrc=$(lineof '^load_rc_config \$name'); _def1=$(lineof '^: "\${nvidia_native_tools_testboot_')
	[ -n "$_lrc" ] && [ -n "$_def1" ] && [ "$_lrc" -lt "$_def1" ] && ok "rc.conf.d is read (line $_lrc) before the defaults (line $_def1)" || bad "load_rc_config (line ${_lrc:-none}) is not before the defaults (line ${_def1:-none}): settings of rc.conf.d would be ignored"
	[ -n "$_arm" ] && [ -n "$_first" ] && [ "$_arm" -lt "$_first" ] && ok "dead-man: armed (line $_arm) before the first kldload (line $_first)" || bad "dead-man: not armed before the first kldload (arm ${_arm:-none}, kldload ${_first:-none})"
	[ -n "$_gate" ] && [ -n "$_first" ] && [ "$_gate" -lt "$_first" ] && ok "dead-man: a timer that is not pending loads nothing (line $_gate)" || bad "dead-man: no gate on the timer before the first kldload"
	grep -q '"\$nvidia_native_tools_testboot_shutdown" -r "+\$nvidia_native_tools_testboot_deadman"' "$RCS" && ok "dead-man: the timer is shutdown -r +N through nvidia_native_tools_testboot_shutdown" || bad "dead-man: no variable-only shutdown -r request"
	grep -q 'nvidia_native_tools_testboot_shutdown' "$RCS" && ok "dead-man: the installed rc script has the shutdown override" || bad "dead-man: the installed rc script has no shutdown override"
	# the one bare-call detector, shared with the host test: bare-shutdown-check.sh (bare_shutdown_lines prints offending lines)
	_bare=$(bare_shutdown_lines "$RCS")
	[ -z "$_bare" ] && ok "dead-man: the installed rc script contains no bare shutdown call" || bad "dead-man: the installed rc script contains a bare shutdown call: $_bare"
	_ovr=$(cat "$RCC" "$MNT"/etc/rc.conf.local "$MNT"/usr/local/etc/rc.conf "$MNT"/usr/local/etc/rc.conf.local 2> /dev/null; find "$MNT/etc/rc.conf.d" "$MNT/usr/local/etc/rc.conf.d" -type f -exec cat {} + 2> /dev/null)
	printf '%s\n' "$_ovr" | grep -Eq '^[[:space:]]*nvidia_native_tools_testboot_(shutdown|marker|bectl)[[:space:]]*=' && bad "dead-man: an rc.conf file of the clone sets nvidia_native_tools_testboot_shutdown, _marker or _bectl" || ok "dead-man: no rc.conf file of the clone overrides the shutdown, marker or bectl variable"
	_def=$(sed -n 's/^: "\${nvidia_native_tools_testboot_deadman:=\([0-9]*\)}"$/\1/p' "$RCS")
	case $_def in '' | 0*) bad "dead-man: the default is '$_def'" ;; *) ok "dead-man: the default is $_def minutes" ;; esac
	_dm=$(cat "$RCC" "$MNT"/etc/rc.conf.d/nvidia_native_tools_testboot 2> /dev/null | sed -n 's/^[[:space:]]*nvidia_native_tools_testboot_deadman[[:space:]]*=[[:space:]]*"\{0,1\}\([^"#[:space:]]*\).*/V\1/p')
	_baddm=; for _x in $_dm; do case ${_x#V} in '' | *[!0-9]* | 0*) _baddm="$_baddm ${_x#V}" ;; esac; done
	[ -z "$_baddm" ] && ok "dead-man: no rc.conf sets the timer to 0 or a non-number" || bad "dead-man: the timer is set to:$_baddm"
	[ -x "$MNT/sbin/shutdown" ] && ok "dead-man: shutdown(8) is in the clone" || bad "dead-man: no shutdown(8) in the clone"
	_lo=$(markof load-order)
	grep -q 'for _k in nvidia_gsp_ga10x_fw nvidia nvidia-modeset; do' "$RCS" || _lo=
	[ -n "$_lo" ] && ok "order: the firmware module is loaded first, then nvidia.ko and nvidia-modeset.ko (line $_lo)" || bad "order: no load loop with the firmware first"
	_ro=$(markof root-open); _ni=$(markof nvrm-info)
	[ -n "$_ro" ] && [ -n "$_ni" ] && [ "$_ro" -lt "$_ni" ] && ok "order: root opens the GPU (line $_ro) before nvrm-info runs (line $_ni)" || bad "order: the root open is not before nvrm-info"
	grep -v '^[[:space:]]*#' "$RCS" | grep -Eq 'kldload[^"]*linux|kldunload|bectl activate' && bad "the rc script loads a linux module, unloads a module or activates a BE" || ok "the rc script loads no linux module, unloads nothing, activates no BE"
else
	bad "the rc script is not installed"
fi
grep -q '^kern.panic_reboot_wait_time="5"$' "$MNT/boot/loader.conf" 2> /dev/null && grep -q '^debug.debugger_on_panic="0"$' "$MNT/boot/loader.conf" 2> /dev/null && ok "loader.conf has the panic settings" || bad "loader.conf lacks the panic settings"

# the one-shot, the other kits, the copy-out directory
_rcd=$MNT/etc/rc.conf.d/nvidia_native_tools_testboot
grep -q '^nvidia_native_tools_testboot_enable="YES"$' "$_rcd" 2> /dev/null && ok "the one-shot is enabled" || bad "the one-shot is not enabled"
_ow=$(sed -n 's/^nvidia_native_tools_testboot_owner="\(.*\)"$/\1/p' "$_rcd" 2> /dev/null)
if [ -z "$_ow" ]; then
	bad "the owner of the run directory is not recorded in $_rcd (nvidia_native_tools_testboot_owner): the one-shot cannot give the results to the person who has to read them"
else
	# the owner must be a user of this boot environment, and must not be root in it: the one-shot gives the run
	# to it with chown(8), which fails for a name the boot environment does not know
	_owu=$(awk -F: -v n="$_ow" '$1 == n { print $3 }' "$MNT/etc/master.passwd" 2> /dev/null)
	if [ -z "$_owu" ]; then
		bad "the owner of the run directory ($_ow) is not a user of this boot environment: the one-shot cannot give the results to it"
	elif [ "$_owu" = 0 ]; then
		bad "the owner of the run directory ($_ow) is root in this boot environment: the results would be root-owned and unreadable by the person who has to read them"
	else
		ok "the owner of the run directory is recorded ($_ow)"
	fi
fi
_on=$(cat "$RCC" "$MNT"/etc/rc.conf.local "$MNT"/usr/local/etc/rc.conf "$MNT"/usr/local/etc/rc.conf.local 2> /dev/null; find "$MNT/etc/rc.conf.d" "$MNT/usr/local/etc/rc.conf.d" -type f -exec cat {} + 2> /dev/null)
_others=$(printf '%s\n' "$_on" | grep -E '^[[:space:]]*[A-Za-z0-9_]+_testboot_enable="?[Yy]' | grep -v '^nvidia_native_tools_testboot_enable=' | tr '\n' ' ')
[ -z "$_others" ] && ok "no other test-boot kit is enabled" || bad "other test-boot kits are enabled: $_others"
_co=$(sed -n 's/^nvidia_native_tools_testboot_copyout="\(.*\)"$/\1/p' "$_rcd" 2> /dev/null)
case $_co in
/*)
	_p=$_co; while [ ! -e "$_p" ] && [ "$_p" != / ]; do _p=$(dirname "$_p"); done
	_ds=$(zfs list -H -o name "$_p" 2> /dev/null)
	_bfs=$(zpool get -H -o value bootfs 2> /dev/null | tr '\n' ' ')
	# the boot environment's own dataset names its root, whatever bootfs says (known when bectl mounted it here)
	_own=; [ "$MOUNTED" = 0 ] || _own=$(zfs list -H -o name "$MNT" 2> /dev/null)
	_l=$(guard_copyout_dataset "$_co" "$_ds" $_bfs $_own) && ok "${_l#* }" || bad "${_l#* }"
	# the one-shot refuses a copy-out with a symbolic link in its path, and one not in plain form: say so now
	if _l=$(guard_plain_path "$_co"); then
		_acc=; _lk=
		set -f
		for _c in $(echo "$_co" | tr / ' '); do _acc=$_acc/$_c; [ ! -L "$_acc" ] || _lk=$_acc; done
		set +f
		[ -z "$_lk" ] && ok "copy-out $_co has no symbolic link in its path" || bad "copy-out $_co: $_lk is a symbolic link, and the one-shot refuses to copy through one: rebuild with make-be.sh -o and the physical path (realpath $_co)"
	else
		bad "copy-out: ${_l#* }: the one-shot would refuse the copy; rebuild with make-be.sh -o and a plain path"
	fi ;;
*) bad "copy-out '$_co' is not an absolute path" ;;
esac
[ -x "$MNT/usr/local/bin/python3" ] && ok "python3 is in the clone (summarize.py needs it)" || bad "no /usr/local/bin/python3 in the clone: summary.json would not be written"
grep -Eq '^nvidia_native_tools_testboot_vram="[0-9]+"$' "$_rcd" 2> /dev/null && grep -Eq '^nvidia_native_tools_testboot_vram_reserve="[0-9]+"$' "$_rcd" 2> /dev/null && grep -Eq '^nvidia_native_tools_testboot_sm="[0-9]+\.[0-9]+"$' "$_rcd" 2> /dev/null && ok "the board's nominal VRAM, the largest VRAM reserve and the compute capability are set: $(grep -E '_(vram|vram_reserve|sm)=' "$_rcd" | tr '\n' ' ')" || bad "the board's nominal VRAM, VRAM reserve (make-be.sh -R) or compute capability is not set in $_rcd"

if [ "$rc" = 0 ]; then echo "check-be.sh: all checks passed"; else echo "check-be.sh: FAILED: do not arm this boot environment; fix what failed above, or remove it (bectl destroy ${BE:-BE}) and build a new one with make-be.sh -n N"; fi
exit $rc

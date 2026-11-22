#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# check-be.sh - check the boot environment make-be.sh built for the
# kernel-patches test boot (Track #2442) before it is armed.  Run as root;
# the boot environment is mounted, read and unmounted, never changed.
#
# Usage: check-be.sh -s SRCDIR -o OBJDIR [-N NORMAL_BE] BE
#
# Prints one "ok" or "FAIL" line per check and "check-be: N failed"; exits 0
# only when nothing failed.  Checks: the BE exists and is not the running
# or the booting one; the normal BE exists; kernel.kpfix/kernel is the build
# (sha256) and the hash list's; it carries the strings of the fixed patches;
# amdgpu, drm, ttm, dmabuf and linker.hints are in kernel.kpfix; the effective
# loader settings (kernel, panic wait 5, no debugger, no module_path); kld_list
# does not load amdgpu; the recorder and testboot-return are installed,
# root-owned, the recorder is the kit's and the only test-boot kit enabled,
# testboot-return matches VENDOR; in the recorder the dead-man timer is armed
# before the kldload of amdgpu and its default is a positive number of
# minutes; the GPU job's llama-bench and model exist.

set -u
PATH=/sbin:/bin:/usr/sbin:/usr/bin
LC_ALL=C
export PATH LC_ALL

KITDIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
NORMAL=
NSET=0
SRC=
OBJ=
KNAME=kernel.kpfix
while [ $# -gt 1 ]; do
	case $1 in
	-s) SRC=$2; shift 2 ;;
	-o) OBJ=$2; shift 2 ;;
	-N) NORMAL=$2; NSET=1; shift 2 ;;
	*) break ;;
	esac
done
[ $# = 1 ] && [ -n "$SRC" ] && [ -n "$OBJ" ] || { echo "usage: check-be.sh -s SRCDIR -o OBJDIR [-N NORMAL_BE] BE" >&2; exit 2; }
BE=$1
case $BE in '' | -* | *[!A-Za-z0-9._-]*) echo "check-be.sh: bad BE name" >&2; exit 2 ;; esac
if [ "$NSET" = 1 ]; then
	case $NORMAL in '' | -* | *[!A-Za-z0-9._-]*) echo "check-be.sh: bad NORMAL_BE name" >&2; exit 2 ;; esac
fi
[ "$(id -u)" = 0 ] || { echo "check-be.sh: run as root (bectl mount)" >&2; exit 2; }
SRC=$(cd "$SRC" && pwd)
KBUILD=$OBJ$SRC/arm64.aarch64/sys/GENERIC

fails=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; fails=$((fails + 1)); }
chk() { _d=$1; shift; if "$@"; then ok "$_d"; else bad "$_d"; fi; }

echo "check-be.sh: $BE"
_row=$(bectl list -H | awk -v b="$BE" '$1 == b')
[ -n "$_row" ] || { bad "the boot environment $BE exists"; echo "check-be: $fails failed"; exit 1; }
ok "the boot environment $BE exists"
_act=$(printf '%s\n' "$_row" | cut -f2)
case $_act in *N* | *R*) bad "$BE is neither running nor the permanent boot choice (active: $_act)" ;; *) ok "$BE is neither running nor the permanent boot choice (active: ${_act:--})" ;; esac

MNTBASE=$(mktemp -d /var/run/kpchk.XXXXXXXX)
MNT=$MNTBASE/root
mkdir "$MNT"
trap 'bectl umount "$BE" > /dev/null 2>&1; rmdir "$MNT" "$MNTBASE" 2> /dev/null' EXIT
bectl mount "$BE" "$MNT" > /dev/null || { bad "bectl mount $BE"; exit 1; }

RC_CONF=$MNT/etc/rc.conf.d/kernel_patches_testboot
_settings=$(sh -c '. "$1" || exit 1; printf "%s\n" "$kernel_patches_testboot_normal_be" "$kernel_patches_testboot_owner" "$kernel_patches_testboot_bench" "$kernel_patches_testboot_model"' sh "$RC_CONF")
_file_normal=$(printf '%s\n' "$_settings" | sed -n 1p)
_cfg_owner=$(printf '%s\n' "$_settings" | sed -n 2p)
_cfg_bench=$(printf '%s\n' "$_settings" | sed -n 3p)
_cfg_model=$(printf '%s\n' "$_settings" | sed -n 4p)
case $_file_normal in '' | -* | *[!A-Za-z0-9._-]*) echo "check-be.sh: bad normal BE name in $RC_CONF" >&2; exit 2 ;; esac
[ "$NSET" = 1 ] || NORMAL=$_file_normal
chk "the normal boot environment $NORMAL exists" sh -c 'bectl list -H | cut -f1 | grep -qx "$1"' sh "$NORMAL"

K=$MNT/boot/$KNAME/kernel
_ks=$(sha256 -q "$K" 2> /dev/null)
chk "/boot/$KNAME/kernel is the build ($_ks)" [ -n "$_ks" -a "$_ks" = "$(sha256 -q "$KBUILD/kernel" 2> /dev/null)" ]
HL=$MNT/usr/local/etc/kernel_patches_testboot.sha256
chk "the hash list in the BE names that kernel" [ "$(awk '$2 == "kernel" {print $1}' "$HL" 2> /dev/null)" = "$_ks" ]
for _s in \
    'arm64: kernel alignment-fault fixup enabled (%s)' \
    'linuxkpi: Ampere Altra erratum 82288: PCIe write-combining mapped as Device (mode %d)' \
    '32-bit config space reads only' \
    'kern_align_fixup_active' \
    'altra_82288_active'; do
	chk "the kernel carries '$_s'" sh -c 'strings "$1" | grep -qF "$2"' sh "$K" "$_s"
done
for _m in amdgpu.ko drm.ko ttm.ko dmabuf.ko linker.hints; do
	chk "/boot/$KNAME/$_m is there" [ -f "$MNT/boot/$KNAME/$_m" ]
done
chk "the amdgpu firmware modules are there" sh -c 'ls "$1"/amdgpu_*_bin.ko > /dev/null 2>&1' sh "$MNT/boot/$KNAME"

# keep in step with make-be.sh
all_conf() {
	cat "$MNT/boot/loader.conf" "$MNT"/boot/loader.conf.d/*.conf "$MNT/boot/loader.conf.local" 2> /dev/null |
	    sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"\{0,1\}\([^\"]*\)\"\{0,1\}[[:space:]]*\(#.*\)\{0,1\}\$/\1/p" | sort -u
}
chk "loader: every kernel= line says $KNAME" [ "$(all_conf kernel)" = "$KNAME" ]
chk "loader: kern.panic_reboot_wait_time=5 is the only value" [ "$(all_conf kern.panic_reboot_wait_time)" = 5 ]
chk "loader: debug.debugger_on_panic=0 is the only value" [ "$(all_conf debug.debugger_on_panic)" = 0 ]
chk "loader: no module_path (the kernel directory comes first)" [ -z "$(all_conf module_path)" ]
_kl=$(sh -c '. "$1" 2> /dev/null; [ ! -f "$2" ] || . "$2"; . "$3" 2> /dev/null; printf "%s\n" "${kld_list-}"' sh "$MNT/etc/rc.conf" "$MNT/etc/rc.conf.local" "$MNT/etc/rc.conf.d/kld")
_bad_kld=
for m in $_kl; do
	case ${m##*/} in amdgpu | amdgpu.ko) _bad_kld=$m ;; esac
done
if [ -n "$_bad_kld" ]; then bad "kld_list ($_kl) loads $_bad_kld"; else ok "kld_list ($_kl) does not load amdgpu"; fi
if { all_conf amdgpu_load; all_conf drm_load; all_conf ttm_load; } | grep -Eq '^(YES|yes|Yes)$'; then
	bad "loader files do not set amdgpu_load, drm_load or ttm_load to YES"
else
	ok "loader files do not set amdgpu_load, drm_load or ttm_load to YES"
fi
if [ -e "$MNT/usr/local/etc/rc.conf.d/kld" ] || [ -L "$MNT/usr/local/etc/rc.conf.d/kld" ]; then
	bad "/usr/local/etc/rc.conf.d/kld cannot autoload amdgpu"
else
	ok "/usr/local/etc/rc.conf.d/kld cannot autoload amdgpu"
fi
_db=$(sh -c '. "$1" || exit 1; [ ! -f "$2" ] || . "$2" || exit 1; [ ! -f "$3" ] || . "$3" || exit 1; [ ! -f "$4" ] || . "$4" || exit 1; printf "%s\n" "${devmatch_blocklist-}"' sh "$MNT/etc/rc.conf" "$MNT/etc/rc.conf.local" "$MNT/etc/rc.conf.d/devmatch" "$MNT/usr/local/etc/rc.conf.d/devmatch")
case " $_db " in *" amdgpu "*) ok "devmatch_blocklist contains amdgpu ($_db)" ;; *) bad "devmatch_blocklist contains amdgpu (${_db:-empty})" ;; esac
if [ -e "$MNT/var/db/testboot-return.hold" ] || [ -L "$MNT/var/db/testboot-return.hold" ]; then
	bad "the stale testboot-return.hold was removed"
else
	ok "the stale testboot-return.hold was removed"
fi

RC=$MNT/usr/local/etc/rc.d/kernel_patches_testboot
MARKER=$MNT/usr/local/etc/kernel_patches_testboot.marker
chk "the dead-man marker exists" [ -f "$MARKER" ]
chk "the dead-man marker names $BE" [ "$(cat "$MARKER" 2> /dev/null)" = "$BE" ]
chk "the dead-man marker is mode 0444" [ "$(stat -f %Lp "$MARKER" 2> /dev/null)" = 444 ]
chk "the recorder is the kit's" cmp -s "$RC" "$KITDIR/kernel_patches_testboot"
chk "the recorder is root-owned, mode 0555" [ "$(stat -f '%Su %Lp' "$RC" 2> /dev/null)" = "root 555" ]
chk "the recorder's hash is in the hash list" [ "$(awk '$2 == "kernel_patches_testboot" {print $1}' "$HL" 2> /dev/null)" = "$(sha256 -q "$RC" 2> /dev/null)" ]
TR=$MNT/usr/local/sbin/testboot-return
_vw=$(sed -n 's/^sha256 *= *\([0-9a-f]\{64\}\)$/\1/p' "$KITDIR/VENDOR")
chk "testboot-return matches the VENDOR pin" [ -n "$_vw" -a "$(sha256 -q "$TR" 2> /dev/null)" = "$_vw" ]
chk "testboot-return is root-owned, mode 0555" [ "$(stat -f '%Su %Lp' "$TR" 2> /dev/null)" = "root 555" ]
chk "the recorder is enabled, returning to $NORMAL" sh -c '. "$1" && [ "$kernel_patches_testboot_enable" = YES ] && [ "$kernel_patches_testboot_normal_be" = "$2" ]' sh "$RC_CONF" "$NORMAL"
_others=$(cat "$MNT/etc/rc.conf" "$MNT/etc/rc.conf.local" "$MNT"/etc/rc.conf.d/* "$MNT/usr/local/etc/rc.conf" "$MNT"/usr/local/etc/rc.conf.d/* 2> /dev/null |
    grep -E '^[[:space:]]*[A-Za-z0-9_]+_testboot_enable=.?[Yy]' | grep -v '^kernel_patches_testboot_enable=' || true)
chk "no other test-boot kit is enabled" [ -z "$_others" ]

_dm=$(grep -nF '"$kernel_patches_testboot_shutdown" -r "+$kernel_patches_testboot_deadman" "kernel_patches_testboot dead-man: restart in $kernel_patches_testboot_deadman minutes unless the run finishes" > "$OUT/deadman.txt" 2>&1' "$RC" | head -1 | cut -d: -f1)
_cancel=$(grep -nF 'kill "$DM_CHILD"' "$RC" | head -1 | cut -d: -f1)
_ld=$(grep -n 'kldload amdgpu >' "$RC" | head -1 | cut -d: -f1)
chk "dead-man: the timer (line ${_dm:-none}) is armed before the kldload of amdgpu (line ${_ld:-none})" [ -n "$_dm" -a -n "$_ld" -a "${_dm:-0}" -lt "${_ld:-0}" ]
chk "dead-man: cancellation uses the confirmed child pid (line ${_cancel:-none})" [ -n "$_cancel" -a -n "$_dm" -a "${_cancel:-0}" -gt "${_dm:-0}" ]
chk "dead-man: host tests can override kernel_patches_testboot_shutdown" grep -qF ': "${kernel_patches_testboot_shutdown:=$kernel_patches_testboot_real_shutdown}"' "$RC"
# the one bare-call detector, shared with the host test (bare_shutdown_lines FILE)
. "$(dirname "$0")/bare-shutdown-check.sh"
# dead-man overrides are for host tests only: no rc.conf file of the clone may set them
dm_override_lines()
{
	cat "$MNT/etc/rc.conf" "$MNT/etc/rc.conf.local" "$MNT"/etc/rc.conf.d/* "$MNT/usr/local/etc/rc.conf" "$MNT"/usr/local/etc/rc.conf.d/* 2> /dev/null |
	    grep -E '^[[:space:]]*(export[[:space:]]+)?kernel_patches_testboot_(shutdown|marker|bectl)=' || true
}
_bare=$(bare_shutdown_lines "$RC")
if [ -n "$_bare" ]; then
	bad "dead-man: the recorder contains a bare shutdown call: $_bare"
else
	ok "dead-man: the recorder contains no bare shutdown call"
fi
_ovr=$(dm_override_lines)
if [ -n "$_ovr" ]; then
	bad "dead-man: an rc.conf file sets a test override: $_ovr"
else
	ok "dead-man: no rc.conf file sets kernel_patches_testboot_shutdown, _marker or _bectl"
fi
chk "dead-man: the real-boot decision function dm_decide is there" grep -q '^dm_decide()' "$RC"
chk "dead-man: a real boot needs rc_fast" grep -qF 'rc_fast' "$RC"
chk "dead-man: no timer, no amdgpu load (the DM_OK gate)" grep -q 'if \[ "$DM_OK" != 1 \]; then' "$RC"
_def=$(sed -n 's/^: "${kernel_patches_testboot_deadman:=\([0-9]*\)}"$/\1/p' "$RC")
chk "dead-man: the default is ${_def:-unset} minutes" [ -n "$_def" -a "${_def:-0}" -gt 0 ]
chk "dead-man: shutdown(8) is in the BE" [ -x "$MNT/sbin/shutdown" ]

chk "the GPU jobs have an owner (${_cfg_owner:-unset}; make-be.sh -U)" [ -n "$_cfg_owner" ]
chk "the GPU job's llama-bench exists ($_cfg_bench; make-be.sh -B)" [ -x "$_cfg_bench" ]
chk "the GPU job's model exists ($_cfg_model; make-be.sh -M)" [ -f "$_cfg_model" ]
chk "the BE has vulkaninfo" [ -x "$MNT/usr/local/bin/vulkaninfo" ]

echo "check-be: $fails failed"
[ "$fails" = 0 ]

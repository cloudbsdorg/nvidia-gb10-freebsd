#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-2-Clause
#
# make-be.sh - assemble the one-shot boot environment that measures the NVIDIA card with native FreeBSD tools only
# (Track #2362): no Linuxulator, no LinuxKPI, no Linux binary.
#
# Usage: make-be.sh [-N NORMAL_BE] [-b BASE_BE] [-D YYYYMMDD] [-n SEQ] [-m STAGEDIR] [-s SHA256FILE] [-o COPYOUT]
#                   [-V VRAM_BYTES] [-R RESERVE_BYTES] [-S SM] [-u UVM_KO] [-d DRM_KO] [-c CHAN_STRESS]
#                   [-C CHAN_STRESS_SECONDS] [--dry-run] [--activate]      (run as root)
#   -N NORMAL_BE  the boot environment the host returns to (default cloudbsd-current)
#   -b BASE_BE    the boot environment to clone (default NORMAL_BE)
#   -D, -n        the name is nvidia-native-tools-test-<DATE>-<SEQ> (today, 1); an existing name is refused with the
#                 next free SEQ
#   -m STAGEDIR   the staged build (default $GB10_WORK/logs/native-tools/stage): nvidia_gsp_ga10x_fw.ko,
#                 nvidia.ko, nvidia-modeset.ko, nvrm-info, libnvrm.so.1, mem_probe and chan_probe, built from
#                 nvidia-gb10-freebsd main
#   -s FILE       the hash list (default STAGEDIR/SHA256.txt): seven lines SHA256 (name) = <64 hex>
#   -o COPYOUT    where the one-shot copies its run (default $GB10_WORK/logs/native-tools-testboot);
#                 an absolute path on a dataset outside the boot environments
#   -V, -R, -S    what the board is, for boot_nvrm_info.sh (defaults: the amp001 board, in
#                 tests/libnvrm/board-amp001.env):
#                 -V the NOMINAL VRAM in bytes (0 for a unified-memory part);
#                 -R the most the driver may reserve of it, in bytes, below -V unless -V is 0 (refused otherwise,
#                 as the boot would); the reported VRAM must lie in [nominal - reserve, nominal];
#                 -S the COMPUTE CAPABILITY major.minor, compared with compute_capability_major/minor, not
#                 with the RM's own SM numbering
#   -u UVM_KO     the nvidia-uvm.ko whose dependencies decide the uvm rows; without it they are not-available;
#                 the module is read, never installed
#   -d DRM_KO     the nvidia-drm.ko whose dependencies decide the PRIME row; without it that row is not-available;
#                 the module is read, never installed
#   -c N          how many semaphore releases the channel probe pushes in its stress loop (default 100000)
#   -C S          how long that stress loop may run, in seconds (default 300); the probe stops earlier when it is done
#   --dry-run     build and check the boot environment, never arm it (the default)
#   --activate    finish with bectl activate -t BE (the orchestrator's decision; never while a Fable agent runs)
#
# What it does, in order (a failure after the clone exists removes the half-built boot environment):
#   1. the kit must be committed (tests/native-tools-testboot, tests/libnvrm, lib/libnvrm, SOURCES); what is
#      installed is git archive of that commit; the vendored gpu-detect.sh and testboot-return equal their pins in
#      VENDOR;
#   2. each staged file equals its full hash; each staged .ko has no dependency and no undefined symbol of the
#      Linuxulator or LinuxKPI (kldxref -d -v, nm -u); nvrm-info, libnvrm.so.1, mem_probe and chan_probe are
#      FreeBSD-branded ELF;
#   3. writes the evidence of the rows that cannot run natively (static-rows/): the uvm rows from UVM_KO's
#      dependencies, PRIME from DRM_KO's, the render uAPI from the commit's tree; the S2 memory row and the S3
#      channel row are not one of them: mem_probe and chan_probe are staged and run, so their rows are measured
#      on the card;
#   4. bectl create -e BASE BE, mounts it under a new root-owned directory of /var/run, refuses a clone with an
#      nvidia module in /boot/modules or /boot/kernel or a loader.conf that loads a Linux, LinuxKPI, drm or nvidia
#      module;
#   5. in the clone only: linux_enable="NO", kld_list without amdgpu, radeonkms, i915kms, drm, dmabuf, nvidia or any
#      name containing linux, devmatch_blocklist (rc.conf and the loader kenv) with those drivers, every other
#      *_testboot_enable="NO", every enabled rc.d service whose required_modules loads one of those drivers turned
#      off (drm_ready loads amdgpu by itself), cloudbsd_hwprobe_command="probe" (the probe loads no KMS driver), the
#      panic settings in loader.conf; a base with a devd rule that loads a driver by itself (a kldload, or the start
#      of a service that loads one) is refused: devd runs it when the device appears, and the kit cannot make it safe;
#   6. installs the staged files into the new directory /boot/modules.nvnative-test (root, 0444; nvrm-info,
#      mem_probe and chan_probe 0555), the kit into /usr/local/share/nvidia-native-tools-test, the rc one-shot and
#      testboot-return;
#   7. unmounts; with --activate arms the one-shot boot.
# The running system is not touched: nothing is loaded, unloaded or rebooted.
#
# The copy-out of the run belongs to the person who runs this script: DOAS_USER, else SUDO_USER, else the owner of
# the copy-out parent directory (root is refused there: a root-owned run directory cannot be read by the person who
# has to read it).  The name is recorded as nvidia_native_tools_testboot_owner, and the one-shot gives the run
# directory to that user.  The name must be a user of this boot environment, and must not be root in it: the one-shot
# gives the run to it with chown(8), which fails for a name the boot environment does not know.
#
# Environment: GB10_WORK (default $HOME/work/gb10).  Test hooks, honoured only with GB10_TEST_HOOKS=1 and
# when not root: NVNT_BECTL (the bectl to run), NVNT_MNT (the clone's mount point), NVNT_NOT_ROOT (no root
# ownership), NVNT_NO_GIT_CHECK (the work tree is installed), NVNT_TEST_PATH (stub tools first on PATH).

set -eu
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL

KITDIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH= cd -- "$KITDIR/../.." && pwd)
. "$KITDIR/guard.sh"
WORK=${GB10_WORK:-$HOME/work/gb10}
BECTL=bectl
HOOKS=0
if [ "${GB10_TEST_HOOKS:-0}" = 1 ] && [ "$(id -u)" != 0 ]; then
	HOOKS=1; BECTL=${NVNT_BECTL:-bectl}
	[ -z "${NVNT_TEST_PATH:-}" ] || { PATH=$NVNT_TEST_PATH:$PATH; export PATH; }
fi
NORMAL=cloudbsd-current
BASE=
DATE=$(date -u +%Y%m%d)
SEQ=1
STAGE=$WORK/logs/native-tools/stage
STAGE_GIVEN=0
SHAFILE=
SHAFILE_GIVEN=0
COPYOUT=$WORK/logs/native-tools-testboot
COPYOUT_GIVEN=0
. "$REPO/tests/libnvrm/board-amp001.env"
VRAM=$BOARD_VRAM_BYTES
RESERVE=$BOARD_VRAM_RESERVE_MAX_BYTES
SM=$BOARD_SM
CHAN_STRESS=100000
CHAN_STRESS_SECONDS=300
UVMKO=
DRMKO=
ACTIVATE=0
FILES="nvidia_gsp_ga10x_fw.ko nvidia.ko nvidia-modeset.ko nvrm-info libnvrm.so.1 mem_probe chan_probe"
# a kld_list or devmatch entry of these names is stripped from the clone (LinuxKPI drivers, the Linux ABI, NVIDIA).
# The list is the one of guard.sh (GUARD_FORBID_RE), so the guard, this script and check-be.sh agree on it.
FORBID_RE=$GUARD_FORBID_RE
BLOCK="amdgpu radeonkms i915kms drm dmabuf linuxkpi linuxkpi_video lindebugfs linux linux64 linux_common nvidia nvidia-modeset nvidia-drm nvidia_linux nvidia_modeset_linux"

help() { awk 'NR >= 5 && /^#/ { sub(/^# ?/, ""); print; next } NR >= 5 { exit }' "$0"; exit 0; }
usage() { echo "make-be.sh: $1 (make-be.sh -h shows every option)" >&2; exit 2; }
need() { [ "$2" -ge 2 ] || usage "$1 needs a value"; }
while [ $# -gt 0 ]; do
	case $1 in
	-N) need "$1" "$#"; NORMAL=$2; shift 2 ;;
	-b) need "$1" "$#"; BASE=$2; shift 2 ;;
	-D) need "$1" "$#"; DATE=$2; shift 2 ;;
	-n) need "$1" "$#"; SEQ=$2; shift 2 ;;
	-m) need "$1" "$#"; STAGE=$2; STAGE_GIVEN=1; shift 2 ;;
	-s) need "$1" "$#"; SHAFILE=$2; SHAFILE_GIVEN=1; shift 2 ;;
	-o) need "$1" "$#"; COPYOUT=$2; COPYOUT_GIVEN=1; shift 2 ;;
	-V) need "$1" "$#"; VRAM=$2; shift 2 ;;
	-R) need "$1" "$#"; RESERVE=$2; shift 2 ;;
	-S) need "$1" "$#"; SM=$2; shift 2 ;;
	-u) need "$1" "$#"; [ -f "$2" ] && [ -r "$2" ] || usage "control module $2 is missing or unreadable"; UVMKO=$2; shift 2 ;;
	-d) need "$1" "$#"; [ -f "$2" ] && [ -r "$2" ] || usage "control module $2 is missing or unreadable"; DRMKO=$2; shift 2 ;;
	-c) need "$1" "$#"; CHAN_STRESS=$2; shift 2 ;;
	-C) need "$1" "$#"; CHAN_STRESS_SECONDS=$2; shift 2 ;;
	--dry-run) ACTIVATE=0; shift ;;
	--activate) ACTIVATE=1; shift ;;
	-h | --help) help ;;
	*) usage "unknown argument: $1" ;;
	esac
done
_root_opts=
[ "$STAGE_GIVEN" = 1 ] || _root_opts="$_root_opts -m"
[ "$SHAFILE_GIVEN" = 1 ] || _root_opts="$_root_opts -s"
[ "$COPYOUT_GIVEN" = 1 ] || _root_opts="$_root_opts -o"
if [ -n "$_root_opts" ]; then guard_work_default "$(id -u)" make-be.sh "${_root_opts# }" || exit $?; fi
[ -n "$BASE" ] || BASE=$NORMAL
[ -n "$SHAFILE" ] || SHAFILE=$STAGE/SHA256.txt
case $DATE in [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) ;; *) echo "make-be.sh: -D must be YYYYMMDD" >&2; exit 2 ;; esac
case $SEQ in '' | *[!0-9]* | 0*) echo "make-be.sh: -n must be a positive number" >&2; exit 2 ;; esac
case $VRAM in '' | *[!0-9]*) echo "make-be.sh: -V must be a number of bytes" >&2; exit 2 ;; esac
case $RESERVE in '' | *[!0-9]*) echo "make-be.sh: -R must be a number of bytes" >&2; exit 2 ;; esac
# the rule boot_compare.py applies at boot: a reserve below the nominal VRAM, unless that is 0
[ "$VRAM" -eq 0 ] || [ "$RESERVE" -lt "$VRAM" ] || { echo "make-be.sh: -R $RESERVE must be below -V $VRAM (unless -V is 0): the boot would reject it" >&2; exit 2; }
case $SM in [0-9]*.[0-9]*) ;; *) echo "make-be.sh: -S must be major.minor" >&2; exit 2 ;; esac
case $SM in *[!0-9.]* | *.*.*) echo "make-be.sh: -S must be major.minor" >&2; exit 2 ;; esac
case $CHAN_STRESS in '' | *[!0-9]*) echo "make-be.sh: -c must be a number of releases" >&2; exit 2 ;; esac
case $CHAN_STRESS_SECONDS in '' | *[!0-9]*) echo "make-be.sh: -C must be a number of seconds" >&2; exit 2 ;; esac
_l=$(guard_plain_path "$COPYOUT") || { echo "make-be.sh: -o: ${_l#* }" >&2; exit 2; }
# The person who runs the kit is the one who has to read the results: record who that is, so the one-shot can give
# the run directory to them.  doas and sudo tell it (DOAS_USER, SUDO_USER); without them the owner of the copy-out
# parent directory is the person the results are for.  Root is refused there: a root-owned run directory cannot be
# read by the person who has to read it.
_OWNER=
if [ -n "${DOAS_USER:-}" ]; then
	_OWNER=$DOAS_USER
elif [ -n "${SUDO_USER:-}" ]; then
	_OWNER=$SUDO_USER
else
	_p=$(dirname "$COPYOUT")
	while [ ! -d "$_p" ] && [ "$_p" != / ]; do _p=$(dirname "$_p"); done
	_u=$(stat -f %u "$_p" 2> /dev/null || echo "")
	if [ -z "$_u" ]; then
		echo "make-be.sh: the owner of $_p (the parent of the copy-out) could not be read: the run directory could not be given to a user; set DOAS_USER or SUDO_USER, or put the copy-out in a directory you own (-o <dir>)" >&2
		exit 2
	fi
	if [ "$_u" = 0 ]; then
		echo "make-be.sh: the owner of $_p (the parent of the copy-out) is root and neither DOAS_USER nor SUDO_USER is set: the run directory would be root-owned and unreadable by the person who has to read it; run this with doas or sudo, set DOAS_USER or SUDO_USER, or put the copy-out in a directory you own (-o <dir>)" >&2
		exit 2
	fi
	_OWNER=$(id -un "$_u" 2> /dev/null || echo "")
	[ -n "$_OWNER" ] || { echo "make-be.sh: the owner of $_p (uid $_u) has no name: the run directory could not be given to a user" >&2; exit 2; }
fi
# the name goes to chown(8) and to the passwd of the boot environment: it must be a user name, and a name that
# starts with a dash would be read as an option
case $_OWNER in
'' | *[!A-Za-z0-9._-]*) echo "make-be.sh: unusable owner name '$_OWNER' for the run directory" >&2; exit 2 ;;
-*) echo "make-be.sh: unusable owner name '$_OWNER' for the run directory: it starts with a dash" >&2; exit 2 ;;
[0-9]*) echo "make-be.sh: unusable owner name '$_OWNER' for the run directory: a number is not a user name" >&2; exit 2 ;;
root) echo "make-be.sh: warning: the recorded owner of the run directory is root: only root can read the results" >&2 ;;
esac
for _n in "$NORMAL" "$BASE"; do
	case $_n in *[!A-Za-z0-9._-]* | -* | '') echo "make-be.sh: unusable boot environment name: $_n" >&2; exit 2 ;; esac
done
if [ "$HOOKS" = 0 ] && [ "$(id -u)" != 0 ]; then echo "make-be.sh: run as root (bectl and the root-owned installs need it)" >&2; exit 2; fi
if [ "$HOOKS" = 1 ] && [ -n "${NVNT_NOT_ROOT:-}" ]; then ROOTOWN=; else ROOTOWN="-o root -g wheel"; fi

BE=nvidia-native-tools-test-$DATE-$SEQ
[ "$BASE" != "$BE" ] && [ "$NORMAL" != "$BE" ] || { echo "make-be.sh: the base or normal boot environment is the target name" >&2; exit 2; }
_raw=$($BECTL list -H 2> /dev/null) || { echo "make-be.sh: bectl list failed: the name could not be checked" >&2; exit 2; }
_list=$(printf '%s\n' "$_raw" | awk '{print $1}')
if printf '%s\n' "$_list" | grep -qx "$BE"; then
	_free=$SEQ
	while printf '%s\n' "$_list" | grep -qx "nvidia-native-tools-test-$DATE-$_free"; do _free=$((_free + 1)); done
	echo "make-be.sh: boot environment $BE exists; run again with -n $_free (the next free number), or remove it with: bectl destroy $BE" >&2
	exit 2
fi

if [ "$HOOKS" = 1 ] && [ -n "${NVNT_MNT:-}" ]; then
	MNT=$NVNT_MNT
	MNTBASE=
else
	MNTBASE=$(mktemp -d /var/run/nvnt.XXXXXXXX)
	MNT=$MNTBASE/root
fi
SCRATCH=$(dirname "$MNT")
mkdir -p "$SCRATCH"
early_cleanup() { rm -rf "$SCRATCH/kit" "$SCRATCH/kit.tar" "$SCRATCH/static-rows" "$SCRATCH/kodep"; [ -z "${MNTBASE:-}" ] || rmdir "$MNTBASE" 2> /dev/null; }
trap early_cleanup EXIT

# 1. the kit: committed; installed from git archive of the commit
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_COMMON_DIR
git_() { git -c safe.directory="$REPO" --no-optional-locks -C "$REPO" "$@"; }
PATHS="tests/native-tools-testboot tests/libnvrm lib/libnvrm SOURCES"
if [ "$HOOKS" = 1 ] && [ -n "${NVNT_NO_GIT_CHECK:-}" ]; then
	COMMIT=unchecked-test-hook
	( cd "$REPO" && tar -cf "$SCRATCH/kit.tar" $PATHS )
else
	git_ rev-parse --git-dir > /dev/null 2>&1 || { echo "make-be.sh: $REPO is not a git checkout (or safe.directory refuses it)" >&2; exit 2; }
	_dirty=$(git_ status --porcelain -- $PATHS 2> /dev/null || echo unreadable)
	[ -z "$_dirty" ] || { echo "make-be.sh: the kit has uncommitted changes (commit them; the commit is what gets installed):
$_dirty" >&2; exit 2; }
	COMMIT=$(git_ rev-parse HEAD)
	git_ archive "$COMMIT" $PATHS > "$SCRATCH/kit.tar" || { echo "make-be.sh: git archive of $COMMIT failed" >&2; exit 1; }
fi
rm -rf "$SCRATCH/kit"; mkdir "$SCRATCH/kit"
tar -xf "$SCRATCH/kit.tar" -C "$SCRATCH/kit" || { echo "make-be.sh: the archive of $COMMIT does not unpack" >&2; exit 1; }
[ -z "$(find "$SCRATCH/kit" ! -type f ! -type d)" ] || { echo "make-be.sh: the commit holds a symbolic link or special file in the kit paths" >&2; exit 1; }
A=$SCRATCH/kit/tests/native-tools-testboot
for _f in nvidia_native_tools_testboot guard.sh summarize.py gpu-detect.sh testboot-return VENDOR check-be.sh native-tools-summary.schema.json; do
	[ -f "$A/$_f" ] || { echo "make-be.sh: commit $COMMIT has no tests/native-tools-testboot/$_f" >&2; exit 1; }
done
[ -f "$SCRATCH/kit/tests/libnvrm/boot_nvrm_info.sh" ] && [ -f "$SCRATCH/kit/tests/libnvrm/boot_compare.py" ] && [ -f "$SCRATCH/kit/tests/libnvrm/schema_validate.py" ] || { echo "make-be.sh: commit $COMMIT lacks tests/libnvrm/boot_nvrm_info.sh, boot_compare.py or schema_validate.py" >&2; exit 1; }
pin() { awk -v f="$1" '$1 == "file" && $3 == f { on = 1; next } $1 == "file" { on = 0 } on && $1 == "sha256" { print $3; exit }' "$A/VENDOR"; }
for _f in gpu-detect.sh testboot-return; do
	_w=$(pin "$_f"); _g=$(sha256 -q "$A/$_f")
	[ -n "$_w" ] && [ "$_g" = "$_w" ] || { echo "make-be.sh: $_f of commit $COMMIT is $_g, VENDOR pins ${_w:-nothing}" >&2; exit 1; }
done
. "$A/guard.sh"

# 2. the staged build
literal() { awk -v n="($1)" '$1 == "SHA256" && $2 == n && $3 == "=" && length($4) == 64 && $4 ~ /^[0-9a-f]+$/ { print $4; c++ } END { exit (c == 1 ? 0 : 1) }' "$SHAFILE"; }
[ -f "$SHAFILE" ] || { echo "make-be.sh: no hash list $SHAFILE" >&2; exit 1; }
[ "$(grep -c '^SHA256 (' "$SHAFILE")" = 7 ] || { echo "make-be.sh: $SHAFILE must hold exactly seven SHA256 lines: $FILES" >&2; exit 1; }
for _f in $FILES; do
	_w=$(literal "$_f") || { echo "make-be.sh: $SHAFILE has no single full sha256 for $_f" >&2; exit 1; }
	[ -f "$STAGE/$_f" ] || { echo "make-be.sh: missing $STAGE/$_f" >&2; exit 1; }
	[ "$(sha256 -q "$STAGE/$_f")" = "$_w" ] || { echo "make-be.sh: $STAGE/$_f differs from the list" >&2; exit 1; }
	echo "checked $_f $_w"
done
# deps <ko>: the dependency names kldxref reads from one module (a copy in its own directory: kldxref reads a directory)
deps() {
	rm -rf "$SCRATCH/kodep"; mkdir "$SCRATCH/kodep"; cp "$1" "$SCRATCH/kodep/" || return 2
	kldxref -d -v "$SCRATCH/kodep" 2> /dev/null | sed -n 's/^[[:space:]]*depends on \([^.[:space:]]*\)\..*/\1/p' | sort -u
}
for _k in nvidia_gsp_ga10x_fw.ko nvidia.ko nvidia-modeset.ko; do
	_d=$(deps "$STAGE/$_k") || { echo "make-be.sh: cannot read the dependencies of $_k" >&2; exit 1; }
	[ -n "$_d" ] || { echo "make-be.sh: kldxref reports no dependency at all for $_k (not even kernel): it could not read it" >&2; exit 1; }
	_bad=$(printf '%s\n' "$_d" | grep -iE 'linux|drm|dmabuf' | tr '\n' ' ')
	[ -z "$_bad" ] || { echo "make-be.sh: $_k depends on $_bad: not a native module; build nvidia.ko and nvidia-modeset.ko from main (no Linux dependency since #2363) and stage them with -m" >&2; exit 1; }
	_l=$(guard_undef "$STAGE/$_k") || { echo "make-be.sh: ${_l#* }" >&2; exit 1; }
	echo "native $_k: depends on $(printf '%s\n' "$_d" | tr '\n' ' ')"
done
for _f in nvrm-info libnvrm.so.1 mem_probe chan_probe; do
	_l=$(guard_elf "$STAGE/$_f") || { echo "make-be.sh: ${_l#* }" >&2; exit 1; }
	echo "native $_f: ${_l#* }"
done

# 3. the rows that cannot run natively, with their evidence: first line the status, then the detail
SR=$SCRATCH/static-rows
rm -rf "$SR"; mkdir "$SR"
classify() {	# classify <ko> <what it is for>: needs-linux, needs-linuxkpi or not-available (native but not loaded by this kit, or not inspectable), with the evidence
	if [ -z "$1" ]; then printf 'not-available\nno control module was supplied for %s\n' "$2"; return; fi
	[ -r "$1" ] || { echo "make-be.sh: control module $1 is missing or unreadable" >&2; return 2; }
	_d=$(deps "$1") || { printf 'not-available\nkldxref could not read %s\n' "$1"; return; }
	if [ -z "$_d" ]; then printf 'not-available\nkldxref reports no dependency for %s: it could not read it\n' "$1"; return; fi
	_us=0; _ul=$(guard_undef "$1") || _us=$?
	case $_us in 0) _u= ;; 1) _u=${_ul##*symbols: } ;; *) printf 'not-available\n%s\n' "${_ul#* }"; return ;; esac
	_lx=$(printf '%s\n' "$_d" | grep -i linux | grep -vi linuxkpi | tr '\n' ' ')
	_kp=$(printf '%s\n' "$_d" | grep -iE 'linuxkpi|^drmn?$|dmabuf' | tr '\n' ' ')
	if ! _h=$(sha256 -q "$1" 2> /dev/null); then echo "make-be.sh: sha256 failed for control module $1" >&2; return 1; fi
	[ -n "$_h" ] || { echo "make-be.sh: sha256 printed nothing for control module $1" >&2; return 1; }
	if [ -n "$_lx" ]; then
		printf 'needs-linux\n%s (%s, sha256 %s) depends on the Linuxulator: %sundefined symbols: %s\n' "$(basename "$1")" "$2" "$_h" "$_lx" "${_u:-none}"
	elif [ -n "$_kp" ]; then
		printf 'needs-linuxkpi\n%s (%s, sha256 %s) depends on LinuxKPI or drm-kmod: %sundefined symbols: %s\n' "$(basename "$1")" "$2" "$_h" "$_kp" "${_u:-none}"
	else
		printf 'not-available\n%s (%s, sha256 %s) has no Linux or LinuxKPI dependency, but this kit does not load it yet: add its rows\n' "$(basename "$1")" "$2" "$_h"
	fi
}
_uvm=$(classify "$UVMKO" "uvm-bsd nvidia-uvm.ko")
for _r in uvm-ioctl-suite uvm-owner-probe uvm-owner-race; do
	{ printf '%s\n' "$_uvm" | head -1; printf 'the uvm-bsd tests open /dev/nvidia-uvm, which only nvidia-uvm.ko provides. '; printf '%s\n' "$_uvm" | sed -n '2,$p'; } > "$SR/$_r"
done
{ _p=$(classify "$DRMKO" "nvidia-drm.ko, the NVIDIA side of PRIME import"); printf '%s\n' "$_p" | head -1
  printf 'PRIME import needs nvidia-drm.ko and the AMD amdgpu driver (drm-kmod, LinuxKPI) on the other side. '; printf '%s\n' "$_p" | sed -n '2,$p'; } > "$SR/prime-import"
if [ "$COMMIT" != unchecked-test-hook ] && git_ ls-tree -r --name-only "$COMMIT" -- src/nvidia-drm-render | grep -q '\.c$'; then
	printf 'not-available\nthe commit has a render uAPI implementation under src/nvidia-drm-render, but this kit has no row for it yet\n' > "$SR/render-uapi"
else
	printf 'not-available\nthe render uAPI is a header and documents only (src/nvidia-drm-render/nvidia-drm-render.h, docs/RENDER-UAPI.md) at commit %s: no kernel module serves it yet\n' "$COMMIT" > "$SR/render-uapi"
fi
# the S2 memory row is not a static row: the kit stages mem_probe and the one-shot runs it (row nvrm-s2-memory)
for _r in uvm-ioctl-suite uvm-owner-probe uvm-owner-race prime-import render-uapi; do echo "static row $_r: $(head -1 "$SR/$_r")"; done

run() { echo "+ $*"; "$@"; }
BE_MADE=0
BE_DONE=0
cleanup() {
	_rc=$?
	trap '' INT TERM HUP
	if [ "$BE_MADE" -eq 1 ] && [ "$BE_DONE" -eq 0 ]; then
		echo "make-be.sh: failed (exit $_rc); removing the half-built boot environment $BE" >&2
		$BECTL umount -f "$BE" > /dev/null 2>&1 || true
		$BECTL destroy -F "$BE" > /dev/null 2>&1 && echo "make-be.sh: $BE is removed" >&2 || echo "make-be.sh: COULD NOT remove $BE: remove it with bectl destroy" >&2
	fi
	rm -rf "$SCRATCH/kit" "$SCRATCH/kit.tar" "$SR" "$SCRATCH/kodep"
	[ -z "${MNTBASE:-}" ] || { rmdir "$MNT" 2> /dev/null; rmdir "$MNTBASE" 2> /dev/null; }
	exit "$_rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# 4. clone and refuse a base that would load what this kit must not have
run $BECTL create -e "$BASE" "$BE"
BE_MADE=1
run mkdir -p "$MNT"
[ ! -L "$MNT" ] || { echo "make-be.sh: the mount point is a symbolic link" >&2; exit 1; }
run $BECTL mount "$BE" "$MNT"
for _d in boot/modules boot/kernel; do
	if ls "$MNT/$_d"/nvidia*.ko > /dev/null 2>&1; then echo "make-be.sh: $_d of $BASE holds an nvidia module" >&2; exit 1; fi
done
_lf=
for _f in boot/loader.conf boot/loader.conf.local; do [ -f "$MNT/$_f" ] && _lf="$_lf $MNT/$_f"; done
[ -d "$MNT/boot/loader.conf.d" ] && _lf="$_lf $(find "$MNT/boot/loader.conf.d" -type f | tr '\n' ' ')"
for _f in $_lf; do
	if sed -e :a -e '/\\$/N; s/\\\n//; ta' "$_f" | grep -Eiq '^[[:space:]]*[A-Za-z0-9_-]*(linux|amdgpu|radeonkms|i915kms|drm|dmabuf|nvidia)[A-Za-z0-9_-]*_load[[:space:]]*=[[:space:]]*"?[Yy]'; then
		echo "make-be.sh: $_f of $BASE loads a Linux, LinuxKPI, drm or nvidia module from the loader: use a base without it" >&2; exit 1
	fi
done
# rc.conf.d files of the services this kit configures must not override what it writes into rc.conf
for _s in linux kld devmatch; do
	for _d in etc/rc.conf.d usr/local/etc/rc.conf.d; do
		[ ! -e "$MNT/$_d/$_s" ] || { echo "make-be.sh: $BASE has $_d/$_s, which would override the settings this kit writes into rc.conf" >&2; exit 1; }
	done
done

# 5. the clone's configuration: no Linux ABI, no LinuxKPI driver, nothing that loads nvidia by itself
RCC=$MNT/etc/rc.conf
# the owner of the run directory must be a user of this boot environment, and must not be root in it: the one-shot
# gives the run to it, and root would leave the results unreadable by the person who has to read them
_owu=$(awk -F: -v n="$_OWNER" '$1 == n { print $3 }' "$MNT/etc/master.passwd" 2> /dev/null)
if [ -z "$_owu" ]; then
	echo "make-be.sh: the owner of the run directory ($_OWNER) is not a user of this boot environment: the one-shot could not give the results to it; create the user in the boot environment, or name another one (DOAS_USER or SUDO_USER)" >&2
	exit 1
fi
if [ "$_owu" = 0 ]; then
	echo "make-be.sh: the owner of the run directory ($_OWNER) is root in this boot environment: the results would be root-owned and unreadable by the person who has to read them; name another user (DOAS_USER or SUDO_USER)" >&2
	exit 1
fi
_kl=$(sysrc -f "$RCC" -n kld_list 2> /dev/null || :)
_keep=
for _k in $_kl; do
	_b=${_k##*/}; _b=${_b%.ko}
	if printf '%s\n' "$_b" | grep -Eiq "$FORBID_RE"; then echo "stripped $_k from kld_list"; else _keep="$_keep $_k"; fi
done
run sysrc -f "$RCC" linux_enable=NO
run sysrc -f "$RCC" kld_list="${_keep# }"
run sysrc -f "$RCC" devmatch_blocklist="$BLOCK"
for _f in etc/rc.conf.local usr/local/etc/rc.conf usr/local/etc/rc.conf.local; do
	[ -f "$MNT/$_f" ] || continue
	if grep -Eq '^[[:space:]]*(linux_enable|kld_list|devmatch_blocklist)[[:space:]]*=' "$MNT/$_f"; then
		echo "make-be.sh: $_f of $BASE sets linux_enable, kld_list or devmatch_blocklist after rc.conf: use a base without it" >&2; exit 1
	fi
done
[ "$(sysrc -f "$RCC" -n linux_enable)" = NO ] || { echo "make-be.sh: linux_enable of the clone is not NO after the change" >&2; exit 1; }
_kl=$(sysrc -f "$RCC" -n kld_list 2> /dev/null || :)
for _k in $_kl; do _b=${_k##*/}; _b=${_b%.ko}; if printf '%s\n' "$_b" | grep -Eiq "$FORBID_RE"; then echo "make-be.sh: kld_list of the clone still has $_k" >&2; exit 1; fi; done
turn_off() {
	_f=$1
	[ -f "$_f" ] && [ ! -L "$_f" ] || return 0
	grep -Eq '^[[:space:]]*[A-Za-z0-9_]+_testboot_enable=' "$_f" || return 0
	sed -E -e '/^[[:space:]]*nvidia_native_tools_testboot_enable=/b' \
	    -e 's/^([[:space:]]*[A-Za-z0-9_]+_testboot_enable)=.*/\1="NO"/' "$_f" > "$_f.nvnt-new" || { rm -f "$_f.nvnt-new"; return 1; }
	if cmp -s "$_f" "$_f.nvnt-new"; then rm -f "$_f.nvnt-new"; else cat "$_f.nvnt-new" > "$_f" && rm -f "$_f.nvnt-new"; echo "turned off the other test-boot kits in $_f"; fi
}
for _n in etc/rc.conf etc/rc.conf.local usr/local/etc/rc.conf usr/local/etc/rc.conf.local; do turn_off "$MNT/$_n"; done
for _n in etc/rc.conf.d usr/local/etc/rc.conf.d; do
	[ -d "$MNT/$_n" ] || continue
	find "$MNT/$_n" -type f | while IFS= read -r _g; do turn_off "$_g"; done
done
# An enabled rc.d service that loads a forbidden module by itself must not run in the clone: rc(8) loads the module of
# its required_modules entry after kld_list was stripped (drm_ready loads amdgpu).  The rule is generic: every rc
# script of the clone is read, and the modules its required_modules names are expanded with the rc.conf variables it
# uses (drm_ready_modules for drm_ready).  A service whose rcvar or whose modules cannot be read is refused, not
# ignored: a service that is not read is a service that is not known.  Only cloudbsd_hwprobe is named: its loading
# is not through a required_modules entry, but through the probe it runs.
guard_rc_offenders "$MNT" "$FORBID_RE" > "$SCRATCH/rc-offenders.txt"
while IFS='|' read -r _svc _rcvar _mods; do
	if [ "$_rcvar" = '?' ]; then
		echo "make-be.sh: the rc.d service $_svc has a required_modules entry that could not be read ($_mods): it cannot be turned off safely; use a base without it" >&2
		exit 1
	fi
	run sysrc -f "$RCC" "$_rcvar=NO"
	echo "disabled $_svc: loads $_mods"
done < "$SCRATCH/rc-offenders.txt"
# the service must really be off now: another rc.conf file of the base may set it again
guard_rc_offenders "$MNT" "$FORBID_RE" > "$SCRATCH/rc-offenders.txt"
while IFS='|' read -r _svc _rcvar _mods; do
	if [ "$_rcvar" = '?' ]; then
		echo "make-be.sh: the rc.d service $_svc has a required_modules entry that could not be read ($_mods): it cannot be turned off safely; use a base without it" >&2
		exit 1
	fi
	echo "make-be.sh: $_svc ($_rcvar) is still enabled and its required_modules loads $_mods: another rc.conf file of the base sets it; use a base without it" >&2
	exit 1
done < "$SCRATCH/rc-offenders.txt"
# the hwprobe service loads the KMS driver of the card it finds, unless its command is "probe" (the Server command).
# Its loading is not through a required_modules entry, but through the probe it runs.
if [ -f "$MNT/usr/local/etc/rc.d/cloudbsd_hwprobe" ]; then
	run sysrc -f "$RCC" cloudbsd_hwprobe_command=probe
	# the value must really be probe: another rc.conf file of the base may set it again (it is read after rc.conf)
	_hpc=$(guard_rc_values "$MNT" cloudbsd_hwprobe | guard_rcconf_value cloudbsd_hwprobe_command)
	if [ "$_hpc" != probe ]; then
		echo "make-be.sh: cloudbsd_hwprobe_command is '$_hpc' after it was set to probe: another rc.conf file of the base sets it; use a base without it" >&2
		exit 1
	fi
	echo "cloudbsd_hwprobe: command=probe (no KMS load)"
fi
# a devd rule that loads a driver by itself must not be in the clone: devd runs it when the device appears, and the
# kit cannot make such a rule safe (a rule that starts a service loads the driver of its required_modules entry even
# when the service is off in the rc.conf)
guard_devd_loaders "$MNT" "$FORBID_RE" > "$SCRATCH/devd-loaders.txt"
while IFS='|' read -r _f _w; do
	[ -n "$_f" ] || continue
	echo "make-be.sh: the devd rule $_f $_w loads a driver by itself: it cannot be made safe in the clone; use a base without it" >&2
	exit 1
done < "$SCRATCH/devd-loaders.txt"
printf '\n# nvidia native tools test boot (Track #2362): a panic restarts in 5 seconds, no debugger; devmatch loads no LinuxKPI, Linux or nvidia driver\nkern.panic_reboot_wait_time="5"\ndebug.debugger_on_panic="0"\ndevmatch_blocklist="%s"\n' "$BLOCK" >> "$MNT/boot/loader.conf"

# 6. the staged files and the kit
MODS=$MNT/boot/modules.nvnative-test
[ ! -e "$MODS" ] || { echo "make-be.sh: $MODS already exists in the clone" >&2; exit 1; }
run install -d $ROOTOWN -m 0755 "$MODS"
for _f in $FILES; do
	case $_f in nvrm-info | mem_probe | chan_probe) _m=0555 ;; *) _m=0444 ;; esac
	run install $ROOTOWN -m "$_m" "$STAGE/$_f" "$MODS/$_f"
	[ "$(sha256 -q "$MODS/$_f")" = "$(literal "$_f")" ] || { echo "make-be.sh: $_f differs after the copy" >&2; exit 1; }
done
KROOT=$MNT/usr/local/share/nvidia-native-tools-test
[ ! -e "$KROOT" ] || { echo "make-be.sh: $KROOT already exists in the clone" >&2; exit 1; }
run install -d $ROOTOWN -m 0755 "$KROOT" "$KROOT/repo" "$KROOT/static-rows" "$MNT/usr/local/sbin" "$MNT/usr/local/etc/rc.d" "$MNT/etc/rc.conf.d" "$MNT/var/db"
tar -xf "$SCRATCH/kit.tar" -C "$KROOT/repo" || { echo "make-be.sh: the kit does not unpack into the clone" >&2; exit 1; }
for _f in guard.sh summarize.py gpu-detect.sh native-tools-summary.schema.json; do run install $ROOTOWN -m 0444 "$A/$_f" "$KROOT/$_f"; done
run install $ROOTOWN -m 0444 "$SHAFILE" "$KROOT/SHA256.txt"
for _r in "$SR"/*; do install $ROOTOWN -m 0444 "$_r" "$KROOT/static-rows/"; done
[ -z "$ROOTOWN" ] || chown -R root:wheel "$KROOT"
chmod -R go-w "$KROOT"
run install $ROOTOWN -m 0555 "$A/testboot-return" "$MNT/usr/local/sbin/testboot-return"
run install $ROOTOWN -m 0555 "$A/nvidia_native_tools_testboot" "$MNT/usr/local/etc/rc.d/nvidia_native_tools_testboot"
printf '%s\n' "$COMMIT" > "$MNT/usr/local/etc/nvidia_native_tools_testboot.version"
printf '%s\n' "$BE" > "$MNT/usr/local/etc/nvidia_native_tools_testboot.marker"
chmod 0444 "$MNT/usr/local/etc/nvidia_native_tools_testboot.marker"
printf 'nvidia_native_tools_testboot_enable="YES"\nnvidia_native_tools_testboot_normal_be="%s"\nnvidia_native_tools_testboot_copyout="%s"\nnvidia_native_tools_testboot_owner="%s"\nnvidia_native_tools_testboot_vram="%s"\nnvidia_native_tools_testboot_vram_reserve="%s"\nnvidia_native_tools_testboot_sm="%s"\nnvidia_native_tools_testboot_chan_stress="%s"\nnvidia_native_tools_testboot_chan_stress_seconds="%s"\n' \
    "$NORMAL" "$COPYOUT" "$_OWNER" "$VRAM" "$RESERVE" "$SM" "$CHAN_STRESS" "$CHAN_STRESS_SECONDS" > "$MNT/etc/rc.conf.d/nvidia_native_tools_testboot"

# 7. done
run $BECTL umount "$BE"
BE_DONE=1
if [ "$ACTIVATE" -eq 1 ]; then
	# never arm a boot environment check-be.sh has not passed
	if ! sh "$KITDIR/check-be.sh" -s "$SHAFILE" -c "$COMMIT" "$BE"; then
		echo "make-be.sh: check-be.sh failed: $BE is built but NOT armed; see its FAIL lines" >&2
		exit 1
	fi
	run $BECTL activate -t "$BE" || { echo "make-be.sh: $BE is built but NOT armed (bectl activate failed)" >&2; exit 1; }
	echo "armed: $BE boots once and returns to $NORMAL by itself; results in $COPYOUT/<stamp>/summary.json and summary.txt"
else
	echo "built, NOT armed (dry run): $BE (commit $COMMIT); the base is $BASE, the host returns to $NORMAL"
	echo "check it with: sh $KITDIR/check-be.sh -s $SHAFILE -c $COMMIT $BE"
	echo "arm it with: bectl activate -t $BE   (only after check-be.sh passed and when no Fable agent runs on this host)"
	echo "the test boot then starts at the next reboot (shutdown -r now); it returns to $NORMAL by itself"
fi

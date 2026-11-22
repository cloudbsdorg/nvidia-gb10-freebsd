#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# make-be.sh - assemble the one-shot test boot environment for Track #2363
# (the Linux ioctl bridges are optional modules).
#
# Usage: make-be.sh -b BASE_BE [-N NORMAL_BE] [-t TREE] [-D YYYYMMDD] [-n SEQ] [-k KLD_LIST]
#                   [-i NVRM_INFO -p NVRM_PROOF] [-u UVM_KO] [-U USER -C CUDARUN]
#                   [-L LOGROOT] [-V COMMIT]
#                   [--dry-run] [--activate]
#   -b BASE_BE  the boot environment to clone (required). The clone's loader
#               configuration is checked: when its module_path does not put
#               /boot/modules.nvtest first, a module_path line that does is
#               written into the clone's /boot/loader.conf and checked again.
#               The clone's kernel must match the SYSDIR the modules were built
#               against (the __FreeBSD_version of the build stamp in the tree),
#               or the script refuses.
#   -N NORMAL_BE the boot environment the host returns to after the run
#               (default cloudbsd-rx7600); the vendored testboot-return brings
#               it back, as the last step of the recorder
#   -t TREE     built working tree (default $GB10_WORK/build/tree) holding
#               nvidia/nvidia.ko, nvidia-modeset/nvidia-modeset.ko,
#               nvidia-linux/nvidia_linux.ko,
#               nvidia-modeset-linux/nvidia_modeset_linux.ko and
#               firmware/gsp_ga10x/nvidia_gsp_ga10x_fw.ko
#   -k KLD_LIST kld_list of the clone: the native modules only, NO Linux layer,
#               by FILE name so that no linker.hints entry decides what loads
#               (default "nvidia_gsp_ga10x_fw nvidia nvidia-modeset")
#   -i, -p      the nvrm-info binary and libnvrm's boot_nvrm_info.sh (Track
#               #2378); both or neither (without them row A4 is a skip)
#   -u UVM_KO   a nvidia-uvm.ko; it is loaded in phase B, after linux64, for
#               the Linux CUDA smoke (it still depends on the Linuxulator)
#   -U, -C      the user and the Linux CUDA runner (run-linux-cuda.sh) for row
#               B4; both or neither (without them B4 is a skip)
#   -L LOGROOT  the log root in the BE (default /var/log/linux_bridge_testboot;
#               it must be root-owned: the recorder refuses another owner)
#   -V COMMIT   the kit commit recorded in the BE (row start); default: HEAD of this
#               repository; -V must name that same commit, and the kit files (this
#               directory and rc.d/nvidia_linux) must be committed (clean), or the
#               script refuses
#   --dry-run   print every command and change nothing
#   --activate  finish with `bectl activate -t`; without it the BE is left
#               unactivated: arming a boot is the orchestrator's decision.
#
# The BE is named nvidia-linux-bridge-test-<date>-<n>. The clone gets
# rc.conf.d/kld (kld_list), rc.conf.d/linux (linux_enable=NO) and
# rc.conf.d/linux_bridge_testboot (enable); every other *_testboot_enable in
# the clone is turned off. kldxref runs on the staged directory, the sha256 list
# of the staged modules goes into the BE (and to $GB10_WORK/logs/linux-bridge-testboot/
# <BE>.sha256 on the host, for summarize.sh --hashes), the Linux NVKMS probe is built
# from nvkms_ioctl_probe.c and branded, and the vendored testboot-return is installed
# after its sha256 matched the pin in VENDOR. The running system is not touched; no
# module is loaded and nothing is rebooted.
#
# Environment: GB10_WORK (default $HOME/work/gb10), BECTL (default bectl). Test hooks of the
# kit test (they change what is checked or where the clone is): LB_MNT (the clone's mount point is
# this plain directory) and LB_NO_GIT_CHECK (no git check of the kit commit).

set -eu

PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL

KITDIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
STAGED=/boot/modules.nvtest
WORK=${GB10_WORK:-$HOME/work/gb10}
BECTL=${BECTL:-bectl}
BASE=
TREE=$WORK/build/tree
DATE=$(date -u +%Y%m%d)
SEQ=1
KLD="nvidia_gsp_ga10x_fw nvidia nvidia-modeset"
NORMAL=cloudbsd-rx7600
NVINFO=
NVPROOF=
UVMKO=
CUDAUSER=
CUDARUN=
LOGROOT=/var/log/linux_bridge_testboot
COMMIT=
DRY=0
ACTIVATE=0

usage() {
	sed -n '5,/^# Environment/p' "$0" | sed 's/^# \{0,1\}//' >&2
	exit 2
}
need() { [ "$2" -ge 2 ] || { echo "make-be.sh: $1 needs a value" >&2; usage; }; }

while [ $# -gt 0 ]; do
	case $1 in
	-b) need "$1" "$#"; BASE=$2; shift 2 ;;
	-N) need "$1" "$#"; NORMAL=$2; shift 2 ;;
	-t) need "$1" "$#"; TREE=$2; shift 2 ;;
	-D) need "$1" "$#"; DATE=$2; shift 2 ;;
	-n) need "$1" "$#"; SEQ=$2; shift 2 ;;
	-k) need "$1" "$#"; KLD=$2; shift 2 ;;
	-i) need "$1" "$#"; NVINFO=$2; shift 2 ;;
	-p) need "$1" "$#"; NVPROOF=$2; shift 2 ;;
	-u) need "$1" "$#"; UVMKO=$2; shift 2 ;;
	-U) need "$1" "$#"; CUDAUSER=$2; shift 2 ;;
	-C) need "$1" "$#"; CUDARUN=$2; shift 2 ;;
	-L) need "$1" "$#"; LOGROOT=$2; shift 2 ;;
	-V) need "$1" "$#"; COMMIT=$2; shift 2 ;;
	--dry-run) DRY=1; shift ;;
	--activate) ACTIVATE=1; shift ;;
	-h | --help) usage ;;
	*) echo "make-be.sh: unknown argument: $1" >&2; usage ;;
	esac
done

[ -n "$BASE" ] || { echo "make-be.sh: -b BASE_BE is required" >&2; usage; }
case $DATE in [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) ;; *) echo "make-be.sh: -D takes YYYYMMDD" >&2; exit 2 ;; esac
case $SEQ in '' | *[!0-9]*) echo "make-be.sh: -n takes a number" >&2; exit 2 ;; esac
case $KLD in *[!A-Za-z0-9_\ -]*) echo "make-be.sh: -k holds a character outside letters, digits, _ and -" >&2; exit 2 ;; esac
# the clone must carry no Linux layer in phase A: refuse a kld_list that loads one
for _m in $KLD; do
	case $_m in linux | linux64 | linux_common | nvidia_linux | nvidia_modeset_linux | nvidia-uvm | nvidia_uvm)
		echo "make-be.sh: -k names $_m: phase A must have no Linux layer (providers and uvm load in phase B)" >&2
		exit 2 ;;
	esac
done
REPO=$(CDPATH= cd -- "$KITDIR/../.." && pwd)
if [ -z "$COMMIT" ]; then
	COMMIT=$(git -C "$REPO" rev-parse HEAD 2> /dev/null) || COMMIT=
fi
if [ -z "$COMMIT" ]; then
	[ "$DRY" -eq 1 ] || { echo "make-be.sh: no kit commit: give -V or run from the repository" >&2; exit 2; }
	COMMIT=dry-run
fi
# the kit that is installed must be the kit that is named: its files are committed and clean
if [ -z "${LB_NO_GIT_CHECK:-}" ] && [ "$DRY" -eq 0 ]; then
	_head=$(git -C "$REPO" rev-parse HEAD 2> /dev/null) || { echo "make-be.sh: cannot read the git state of $REPO: the kit commit cannot be checked" >&2; exit 1; }
	_named=$(git -C "$REPO" rev-parse "$COMMIT^{commit}" 2> /dev/null) || _named=
	[ "$_named" = "$_head" ] || { echo "make-be.sh: -V $COMMIT is not the commit of the kit that would be installed (HEAD is $_head)" >&2; exit 1; }
	_dirty=$(git -C "$REPO" status --porcelain -- tests/linux-bridge-testboot rc.d/nvidia_linux) || { echo "make-be.sh: git status failed in $REPO" >&2; exit 1; }
	[ -z "$_dirty" ] || { echo "make-be.sh: the kit has uncommitted changes (commit them, the results name the kit commit):" >&2; echo "$_dirty" >&2; exit 1; }
fi
case $COMMIT in *[!A-Za-z0-9._-]*) echo "make-be.sh: -V holds a character outside letters, digits, . _ -" >&2; exit 2 ;; esac
case $NORMAL in '' | *[!A-Za-z0-9_.-]*) echo "make-be.sh: -N takes a boot environment name" >&2; exit 2 ;; esac
case $LOGROOT in /*) ;; *) echo "make-be.sh: -L takes an absolute path" >&2; exit 2 ;; esac
case $LOGROOT$CUDAUSER$CUDARUN in *[!A-Za-z0-9_./-]*) echo "make-be.sh: -L, -U and -C take letters, digits and _ . / - only" >&2; exit 2 ;; esac
if [ -n "$CUDAUSER$CUDARUN" ] && { [ -z "$CUDAUSER" ] || [ -z "$CUDARUN" ]; }; then
	echo "make-be.sh: -U and -C go together" >&2
	exit 2
fi
if [ -n "$CUDAUSER" ] && [ -z "$UVMKO" ]; then
	echo "make-be.sh: -U and -C need -u (the CUDA smoke loads nvidia-uvm.ko)" >&2
	exit 2
fi
if [ -n "$NVINFO$NVPROOF" ] && { [ -z "$NVINFO" ] || [ -z "$NVPROOF" ]; }; then
	echo "make-be.sh: -i and -p go together" >&2
	exit 2
fi

[ -n "$NVINFO" ] || echo "make-be.sh: warning: no -i and -p: row A4 (nvrm-info) will be a skip, and summarize.sh refuses it: that row cannot be waived" >&2
[ -n "$CUDAUSER" ] || echo "make-be.sh: warning: no -U and -C: row B4 (Linux CUDA) will be a skip, and summarize.sh will fail it unless SUMMARIZE_ALLOW_SKIP=B4-cuda (the verdict is then PARTIAL)" >&2

# the vendored testboot-return is the one that was pinned
VWANT=$(sed -n 's/^sha256 *= *\([0-9a-f]\{64\}\)$/\1/p' "$KITDIR/VENDOR" 2> /dev/null)
if [ -z "$VWANT" ] || [ ! -f "$KITDIR/testboot-return" ] || [ "$(sha256 -q "$KITDIR/testboot-return")" != "$VWANT" ]; then
	if [ -z "$VWANT" ]; then echo "make-be.sh: VENDOR has no sha256 pin line" >&2
	elif [ ! -f "$KITDIR/testboot-return" ]; then echo "make-be.sh: $KITDIR/testboot-return is missing" >&2
	else echo "make-be.sh: testboot-return is $(sha256 -q "$KITDIR/testboot-return"), VENDOR pins $VWANT: restore the vendored copy (cp from the pinned commit), do not edit the pin" >&2; fi
	exit 1
fi

BE=nvidia-linux-bridge-test-$DATE-$SEQ
MNT=${LB_MNT:-$WORK/tmp/$BE.mnt}

MODS="nvidia/nvidia.ko nvidia-modeset/nvidia-modeset.ko nvidia-linux/nvidia_linux.ko nvidia-modeset-linux/nvidia_modeset_linux.ko firmware/gsp_ga10x/nvidia_gsp_ga10x_fw.ko"
if [ "$DRY" -eq 0 ]; then
	for m in $MODS; do
		[ -f "$TREE/$m" ] || { echo "make-be.sh: missing $TREE/$m: run scripts/prepare-tree.sh, then scripts/build-shim.sh --module=<dir> for nvidia, nvidia-modeset, nvidia-linux and nvidia-modeset-linux, and scripts/build-firmware.sh" >&2; exit 1; }
		# the modules must be linked with base LLD (memory: a GNU ld .ko does not load)
		readelf -p .comment "$TREE/$m" 2>/dev/null | grep -q 'Linker: LLD' || { echo "make-be.sh: $TREE/$m was not linked by LLD; rebuild with the base toolchain" >&2; exit 1; }
	done
	[ -z "$UVMKO" ] || [ -f "$UVMKO" ] || { echo "make-be.sh: no $UVMKO" >&2; exit 1; }
	[ -z "$NVINFO" ] || [ -x "$NVINFO" ] || { echo "make-be.sh: $NVINFO is not executable" >&2; exit 1; }
	[ -z "$NVPROOF" ] || [ -f "$NVPROOF" ] || { echo "make-be.sh: no $NVPROOF" >&2; exit 1; }
	[ -f "$KITDIR/linux_bridge_testboot" ] || { echo "make-be.sh: no kit script beside make-be.sh" >&2; exit 1; }
	# the modules were all built against one SYSDIR (the stamps build-shim.sh leaves in the tree)
	BUILDVER=
	for _d in nvidia nvidia-modeset nvidia-linux nvidia-modeset-linux; do
		_v=$(sed -n 's/^version //p' "$TREE/$_d/.gb10-sysdir" 2> /dev/null)
		case $_v in '' | *[!0-9]*) echo "make-be.sh: $TREE/$_d/.gb10-sysdir has no numeric __FreeBSD_version: build with scripts/build-shim.sh" >&2; exit 1 ;; esac
		[ -z "$BUILDVER" ] || [ "$BUILDVER" = "$_v" ] || { echo "make-be.sh: the modules were built against different __FreeBSD_version values ($BUILDVER and $_v)" >&2; exit 1; }
		BUILDVER=$_v
	done
	# the Linux NVKMS probe: a freestanding static Linux program of the host's architecture
	case $(uname -p) in
	aarch64 | arm64) PROBEARCH=aarch64 ;;
	amd64 | x86_64) PROBEARCH=x86_64 ;;
	*) echo "make-be.sh: no Linux NVKMS probe for architecture $(uname -p): row B3-nvkms-ioctl would be a skip, which summarize.sh refuses; nothing built" >&2; exit 1 ;;
	esac
	mkdir -p "$WORK/tmp"
	PROBEDIR=$(mktemp -d "$WORK/tmp/lb-probe.XXXXXX") || exit 1
	if cc --target="$PROBEARCH-unknown-linux-gnu" -static -nostdlib -ffreestanding -fuse-ld=lld -O2 -o "$PROBEDIR/nvkms_ioctl_probe" "$KITDIR/nvkms_ioctl_probe.c" > "$PROBEDIR/cc.out" 2>&1 \
	    && brandelf -t Linux "$PROBEDIR/nvkms_ioctl_probe"; then
		PROBE=$PROBEDIR/nvkms_ioctl_probe
	else
		echo "make-be.sh: the Linux NVKMS probe did not build ($(tail -1 "$PROBEDIR/cc.out")): row B3-nvkms-ioctl would be a skip, which summarize.sh refuses; nothing built" >&2
		rm -rf "${PROBEDIR:?}"
		exit 1
	fi
fi

run() {
	echo "+ $*"
	[ "$DRY" -eq 1 ] || "$@"
}

BE_MADE=0
BE_DONE=0
cleanup() {
	_rc=$?
	trap '' INT TERM HUP
	if [ "$BE_MADE" -eq 1 ] && [ "$BE_DONE" -eq 0 ] && [ "$DRY" -eq 0 ]; then
		echo "make-be.sh: failed (exit $_rc); removing the half-built boot environment $BE" >&2
		"$BECTL" umount -f "$BE" > /dev/null 2>&1 || true
		"$BECTL" destroy -F "$BE" > /dev/null 2>&1 || echo "make-be.sh: COULD NOT remove $BE: remove it by hand" >&2
	fi
	[ -z "${PROBEDIR:-}" ] || rm -rf "${PROBEDIR:?}"
	exit "$_rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

if [ "$DRY" -eq 0 ]; then
	"$BECTL" list -H 2> /dev/null | cut -f1 | grep -qx "$NORMAL" || { echo "make-be.sh: the normal boot environment $NORMAL (-N) does not exist here: testboot-return could not bring the host back to it" >&2; exit 1; }
fi
run "$BECTL" create -e "$BASE" "$BE"
BE_MADE=1
run mkdir -p "$MNT"
run "$BECTL" mount "$BE" "$MNT"

# loader configuration: the staged directory must come first on the module path, and the
# clone's kernel must be the one the modules were built against
# eff_conf <mount> <variable>: the last assignment of the variable in the loader configuration
# files, in the order the loader reads them (loader.conf, loader.conf.d/*.conf, loader.conf.local)
eff_conf() {
	for _f in "$1/boot/loader.conf" "$1"/boot/loader.conf.d/*.conf "$1/boot/loader.conf.local"; do
		[ -f "$_f" ] && cat "$_f"
	done | sed -n "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*\"\{0,1\}\([^\"]*\)\"\{0,1\}[[:space:]]*\(#.*\)\{0,1\}\$/\1/p" | tail -n 1
}
# a loader file that is a symbolic link points out of the clone (or is hiding something): refuse
for _f in "$MNT/boot" "$MNT/boot/loader.conf" "$MNT/boot/loader.conf.local" "$MNT/boot/loader.conf.d"; do
	if [ "$DRY" -eq 0 ] && [ -L "$_f" ]; then
		echo "make-be.sh: $_f is a symbolic link: the loader configuration of the clone must be plain files inside it" >&2
		exit 1
	fi
done
for _f in "$MNT"/boot/loader.conf.d/*.conf; do
	if [ "$DRY" -eq 0 ] && [ -L "$_f" ]; then
		echo "make-be.sh: $_f is a symbolic link: the loader configuration of the clone must be plain files inside it" >&2
		exit 1
	fi
done
# kernel_osreldate <kernel file>: the __FreeBSD_version compiled into a kernel (osreldate, read from its file)
kernel_osreldate() {
	_ln=$(readelf -sW "$1" 2> /dev/null | awk '$8 == "osreldate" { print $2, $7; exit }')
	[ -n "$_ln" ] || return 1
	_va=${_ln% *}
	_sh=${_ln#* }
	_si=$(readelf -SW "$1" | sed -n "s/^ *\[ *$_sh\] *[^ ]* *[^ ]* *\([0-9a-f]*\) *\([0-9a-f]*\) .*/\1 \2/p")
	[ -n "$_si" ] || return 1
	_pos=$(( 0x$_va - 0x${_si% *} + 0x${_si#* } ))
	od -An -t d4 -j "$_pos" -N 4 "$1" | tr -d ' '
}
if [ "$DRY" -eq 1 ]; then
	echo "+ check the module_path of $MNT/boot/loader.conf*: $STAGED first; write it into loader.conf when it is not"
	echo "+ check the clone kernel's __FreeBSD_version against the build stamps of the tree"
else
	_kern=$(eff_conf "$MNT" kernel)
	_kern=${_kern:-kernel}
	_mp=$(eff_conf "$MNT" module_path)
	case $_mp in
	"$STAGED"\;* | "$STAGED") echo "module_path of the clone: $_mp" ;;
	*)
		_new="$STAGED;/boot/$_kern;/boot/modules;/boot/firmware;/boot/dtb;/boot/dtb/overlays"
		echo "module_path of the clone is [${_mp:-the loader default}]: writing module_path=$_new into $MNT/boot/loader.conf"
		printf '\n# linux bridge test boot: the staged modules come first\nmodule_path="%s"\n' "$_new" >> "$MNT/boot/loader.conf"
		_mp=$(eff_conf "$MNT" module_path)
		case $_mp in
		"$STAGED"\;*) ;;
		*) echo "make-be.sh: the clone's module_path is still [$_mp] after the write: a later loader configuration file overrides it" >&2; exit 1 ;;
		esac
		;;
	esac
	_kf=$MNT/boot/$_kern/kernel
	[ -f "$_kf" ] || { echo "make-be.sh: the clone has no kernel $_kf (kernel=$_kern)" >&2; exit 1; }
	_kv=$(kernel_osreldate "$_kf") || { echo "make-be.sh: cannot read the __FreeBSD_version of $_kf" >&2; exit 1; }
	[ "$_kv" = "$BUILDVER" ] || { echo "make-be.sh: the clone's kernel $_kf is __FreeBSD_version $_kv, the modules were built against $BUILDVER (rebuild them against the kernel's sources, or clone a BE whose kernel matches)" >&2; exit 1; }
	echo "kernel $_kf is __FreeBSD_version $_kv, as built against"
fi

# other kits armed in the clone are turned off: this boot runs this kit alone
for f in etc/rc.conf etc/rc.conf.local usr/local/etc/rc.conf usr/local/etc/rc.conf.local; do
	if [ "$DRY" -eq 1 ]; then
		echo "+ turn off every other *_testboot_enable in $MNT/$f"
	elif [ -f "$MNT/$f" ] && [ ! -L "$MNT/$f" ]; then
		sed -E -e 's/^([[:space:]]*[A-Za-z0-9_]+_testboot_enable)=.*/\1="NO"/' "$MNT/$f" > "$MNT/$f.lb-new" && cat "$MNT/$f.lb-new" > "$MNT/$f" && rm -f "$MNT/$f.lb-new"
	fi
done
if [ "$DRY" -eq 1 ]; then
	echo "+ turn off every other *_testboot_enable under $MNT/etc/rc.conf.d and $MNT/usr/local/etc/rc.conf.d"
else
	for d in etc/rc.conf.d usr/local/etc/rc.conf.d; do
		[ -d "$MNT/$d" ] || continue
		for f in "$MNT/$d"/*; do
			[ -f "$f" ] && [ ! -L "$f" ] || continue
			sed -E -e 's/^([[:space:]]*[A-Za-z0-9_]+_testboot_enable)=.*/\1="NO"/' "$f" > "$f.lb-new" && cat "$f.lb-new" > "$f" && rm -f "$f.lb-new"
		done
	done
fi

if [ "$DRY" -eq 0 ] && [ -L "$MNT$STAGED" ]; then
	echo "make-be.sh: $MNT$STAGED is a symbolic link: the staged modules would be written outside the clone" >&2
	exit 1
fi
run mkdir -p "$MNT$STAGED"
run rm -f "$MNT$STAGED"/nvidia-uvm.ko "$MNT$STAGED"/nvidia_linux.ko "$MNT$STAGED"/nvidia_modeset_linux.ko
for m in $MODS; do
	b=$(basename "$m")
	run cp "$TREE/$m" "$MNT$STAGED/$b"
	if [ "$DRY" -eq 0 ]; then
		[ "$(sha256 -q "$TREE/$m")" = "$(sha256 -q "$MNT$STAGED/$b")" ] || { echo "make-be.sh: $b differs after the copy" >&2; exit 1; }
		echo "$b $(sha256 -q "$MNT$STAGED/$b")"
	fi
done
[ -z "$UVMKO" ] || run cp "$UVMKO" "$MNT$STAGED/nvidia-uvm.ko"
# the sha256 list of the staged modules: into the BE (the recorder proves what the kernel loaded
# against it) and to the host (summarize.sh --hashes compares the results with it)
HASHLIST=$WORK/logs/linux-bridge-testboot/$BE.sha256
if [ "$DRY" -eq 1 ]; then
	echo "+ write the sha256 list of the staged modules to $MNT/usr/local/etc/linux_bridge_testboot.sha256 and $HASHLIST"
	echo "+ kldxref $MNT$STAGED"
else
	mkdir -p "$WORK/logs/linux-bridge-testboot"
	: > "$HASHLIST"
	for m in $MODS; do
		b=$(basename "$m")
		echo "$(sha256 -q "$MNT$STAGED/$b") $b" >> "$HASHLIST"
	done
	# the loader reads the staged directory's own hints: build them now, from the staged files
	rm -f "$MNT$STAGED/linker.hints"
	kldxref "$MNT$STAGED" || { echo "make-be.sh: kldxref failed on the staged directory" >&2; exit 1; }
	[ -s "$MNT$STAGED/linker.hints" ] || { echo "make-be.sh: kldxref left no linker.hints in the staged directory" >&2; exit 1; }
fi

run install -d "$MNT/usr/local/etc/rc.d" "$MNT/usr/local/bin" "$MNT/usr/local/libexec" "$MNT/etc/rc.conf.d"
run install -m 0555 "$KITDIR/linux_bridge_testboot" "$MNT/usr/local/etc/rc.d/linux_bridge_testboot"
run install -m 0555 "$KITDIR/../../rc.d/nvidia_linux" "$MNT/usr/local/etc/rc.d/nvidia_linux"
run install -d "$MNT/usr/local/sbin"
run install -m 0555 "$KITDIR/testboot-return" "$MNT/usr/local/sbin/testboot-return"
if [ "$DRY" -eq 1 ]; then echo "+ build the Linux NVKMS probe and install it as $MNT/usr/local/libexec/nvkms_ioctl_probe"; else run install -m 0555 "$PROBE" "$MNT/usr/local/libexec/nvkms_ioctl_probe"; fi
[ -z "$NVINFO" ] || run install -m 0555 "$NVINFO" "$MNT/usr/local/bin/nvrm-info"
[ -z "$NVPROOF" ] || run install -m 0555 "$NVPROOF" "$MNT/usr/local/libexec/boot_nvrm_info.sh"
if [ "$DRY" -eq 1 ]; then
	echo "+ write $MNT/etc/rc.conf.d/kld: kld_list=\"$KLD\""
	echo "+ write $MNT/etc/rc.conf.d/linux: linux_enable=NO"
	echo "+ write $MNT/etc/rc.conf.d/nvidia_linux: nvidia_linux_mode=NO (the kit loads the providers itself)"
	echo "+ write $MNT/etc/rc.conf.d/linux_bridge_testboot: linux_bridge_testboot_enable=YES, _logroot=$LOGROOT${CUDAUSER:+, _user=$CUDAUSER, _cudarun=$CUDARUN}"
else
	printf 'kld_list="%s"\n' "$KLD" > "$MNT/etc/rc.conf.d/kld"
	printf 'linux_enable="NO"\n' > "$MNT/etc/rc.conf.d/linux"
	printf 'nvidia_linux_mode="NO"\n' > "$MNT/etc/rc.conf.d/nvidia_linux"
	{
		printf 'linux_bridge_testboot_enable="YES"\n'
		printf 'linux_bridge_testboot_logroot="%s"\n' "$LOGROOT"
		printf 'linux_bridge_testboot_normal_be="%s"\n' "$NORMAL"
		printf 'linux_bridge_testboot_copyout="%s"\n' "$WORK/logs/linux-bridge-testboot/runs"
		[ -z "$CUDAUSER" ] || printf 'linux_bridge_testboot_user="%s"\nlinux_bridge_testboot_cudarun="%s"\n' "$CUDAUSER" "$CUDARUN"
	} > "$MNT/etc/rc.conf.d/linux_bridge_testboot"
	mkdir -p "$MNT$LOGROOT" && chmod 755 "$MNT$LOGROOT"
	if [ -n "${LB_NO_GIT_CHECK:-}" ]; then
		# a test hook: the kit was not checked against git, and the record says so
		printf '%s+unverified\n' "$COMMIT" > "$MNT/usr/local/etc/linux_bridge_testboot.version"
	else
		printf '%s\n' "$COMMIT" > "$MNT/usr/local/etc/linux_bridge_testboot.version"
	fi
	cp "$HASHLIST" "$MNT/usr/local/etc/linux_bridge_testboot.sha256"
fi

run "$BECTL" umount "$BE"
BE_DONE=1
if [ "$ACTIVATE" -eq 1 ]; then
	run "$BECTL" activate -t "$BE"
	echo "armed: $BE boots once; results land in $LOGROOT/linux-bridge-<stamp>.<random>/ and are copied to $WORK/logs/linux-bridge-testboot/runs/"
else
	echo "built: $BE (not armed; the orchestrator arms it with bectl activate -t)"
fi
[ "$DRY" -eq 1 ] || echo "after the boot: sh $KITDIR/summarize.sh --kit $COMMIT --hashes $HASHLIST $WORK/logs/linux-bridge-testboot/runs/<run>/results.jsonl   (<run> is the newest linux-bridge-* directory there)"

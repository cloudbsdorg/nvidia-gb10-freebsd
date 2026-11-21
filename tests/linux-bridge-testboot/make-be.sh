#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# make-be.sh - assemble the one-shot test boot environment for Track #2363
# (the Linux ioctl bridges are optional modules).
#
# Usage: make-be.sh -b BASE_BE [-t TREE] [-D YYYYMMDD] [-n SEQ] [-k KLD_LIST]
#                   [-i NVRM_INFO -p NVRM_PROOF] [-u UVM_KO] [-U USER -C CUDARUN]
#                   [-L LOGROOT] [-V COMMIT]
#                   [--dry-run] [--activate]
#   -b BASE_BE  the boot environment to clone (required). Its loader must put
#               /boot/modules.nvtest on the module path, as the earlier test
#               BEs do.
#   -t TREE     built working tree (default $GB10_WORK/build/tree) holding
#               nvidia/nvidia.ko, nvidia-modeset/nvidia-modeset.ko,
#               nvidia-linux/nvidia_linux.ko,
#               nvidia-modeset-linux/nvidia_modeset_linux.ko and
#               firmware/gsp_ga10x/nvidia_gsp_ga10x_fw.ko
#   -k KLD_LIST kld_list of the clone: the native modules only, NO Linux layer
#               (default "nvidia_gsp_ga10x_fw nvidia nvidia_modeset")
#   -i, -p      the nvrm-info binary and libnvrm's boot_nvrm_info.sh (Track
#               #2378); both or neither (without them row A4 is a skip)
#   -u UVM_KO   a nvidia-uvm.ko; it is loaded in phase B, after linux64, for
#               the Linux CUDA smoke (it still depends on the Linuxulator)
#   -U, -C      the user and the Linux CUDA runner (run-linux-cuda.sh) for row
#               B4; both or neither (without them B4 is a skip)
#   -L LOGROOT  the log root in the BE (default /var/log/linux_bridge_testboot;
#               it must be root-owned: the recorder refuses another owner)
#   -V COMMIT   recorded in the BE (row start)
#   --dry-run   print every command and change nothing
#   --activate  finish with `bectl activate -t`; without it the BE is left
#               unactivated: arming a boot is the orchestrator's decision.
#
# The BE is named nvidia-linux-bridge-test-<date>-<n>. The clone gets
# rc.conf.d/kld (kld_list), rc.conf.d/linux (linux_enable=NO) and
# rc.conf.d/linux_bridge_testboot (enable); every other *_testboot_enable in
# the clone is turned off. The running system is not touched; no module is
# loaded and nothing is rebooted.
#
# Environment: GB10_WORK (default $HOME/work/gb10), BECTL (default bectl).

set -eu

PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL

KITDIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
WORK=${GB10_WORK:-$HOME/work/gb10}
BECTL=${BECTL:-bectl}
BASE=
TREE=$WORK/build/tree
DATE=$(date -u +%Y%m%d)
SEQ=1
KLD="nvidia_gsp_ga10x_fw nvidia nvidia_modeset"
NVINFO=
NVPROOF=
UVMKO=
CUDAUSER=
CUDARUN=
LOGROOT=/var/log/linux_bridge_testboot
COMMIT=unknown
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
case $COMMIT in *[!A-Za-z0-9._-]*) echo "make-be.sh: -V holds a character outside letters, digits, . _ -" >&2; exit 2 ;; esac
case $LOGROOT in /*) ;; *) echo "make-be.sh: -L takes an absolute path" >&2; exit 2 ;; esac
case $LOGROOT$CUDAUSER$CUDARUN in *[!A-Za-z0-9_./-]*) echo "make-be.sh: -L, -U and -C take letters, digits and _ . / - only" >&2; exit 2 ;; esac
if [ -n "$CUDAUSER$CUDARUN" ] && { [ -z "$CUDAUSER" ] || [ -z "$CUDARUN" ]; }; then
	echo "make-be.sh: -U and -C go together" >&2
	exit 2
fi
if [ -n "$NVINFO$NVPROOF" ] && { [ -z "$NVINFO" ] || [ -z "$NVPROOF" ]; }; then
	echo "make-be.sh: -i and -p go together" >&2
	exit 2
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
	exit "$_rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

run "$BECTL" create -e "$BASE" "$BE"
BE_MADE=1
run mkdir -p "$MNT"
run "$BECTL" mount "$BE" "$MNT"

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

run mkdir -p "$MNT/boot/modules.nvtest"
run rm -f "$MNT"/boot/modules.nvtest/nvidia-uvm.ko "$MNT"/boot/modules.nvtest/nvidia_linux.ko "$MNT"/boot/modules.nvtest/nvidia_modeset_linux.ko
for m in $MODS; do
	b=$(basename "$m")
	run cp "$TREE/$m" "$MNT/boot/modules.nvtest/$b"
	if [ "$DRY" -eq 0 ]; then
		[ "$(sha256 -q "$TREE/$m")" = "$(sha256 -q "$MNT/boot/modules.nvtest/$b")" ] || { echo "make-be.sh: $b differs after the copy" >&2; exit 1; }
		echo "$b $(sha256 -q "$MNT/boot/modules.nvtest/$b")"
	fi
done
[ -z "$UVMKO" ] || run cp "$UVMKO" "$MNT/boot/modules.nvtest/nvidia-uvm.ko"

run install -d "$MNT/usr/local/etc/rc.d" "$MNT/usr/local/bin" "$MNT/usr/local/libexec" "$MNT/etc/rc.conf.d"
run install -m 0555 "$KITDIR/linux_bridge_testboot" "$MNT/usr/local/etc/rc.d/linux_bridge_testboot"
run install -m 0555 "$KITDIR/../../rc.d/nvidia_linux" "$MNT/usr/local/etc/rc.d/nvidia_linux"
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
		[ -z "$CUDAUSER" ] || printf 'linux_bridge_testboot_user="%s"\nlinux_bridge_testboot_cudarun="%s"\n' "$CUDAUSER" "$CUDARUN"
	} > "$MNT/etc/rc.conf.d/linux_bridge_testboot"
	mkdir -p "$MNT$LOGROOT" && chmod 755 "$MNT$LOGROOT"
	printf '%s\n' "$COMMIT" > "$MNT/usr/local/etc/linux_bridge_testboot.version"
fi

run "$BECTL" umount "$BE"
BE_DONE=1
if [ "$ACTIVATE" -eq 1 ]; then
	run "$BECTL" activate -t "$BE"
	echo "armed: $BE boots once; results land in $LOGROOT/linux-bridge-<stamp>.<random>/ (summarize.sh results.jsonl)"
else
	echo "built: $BE (not armed; the orchestrator arms it with bectl activate -t)"
fi

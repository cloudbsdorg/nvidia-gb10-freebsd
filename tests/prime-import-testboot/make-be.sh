#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# make-be.sh - assemble the one-shot test boot environment for the cross-GPU
# buffer import (Track #2228, docs/PRIME-IMPORT.md, section 5).
#
# Usage: make-be.sh -b BASE_BE [-D YYYYMMDD] [-n SEQ] [-m MODDIR] [-u UVM_KO]
#                   [--dry-run] [--activate]
#   -b BASE_BE  the boot environment to clone (required; it must already load
#               amdgpu and the nvidia stack from /boot/modules.nvtest through
#               kld_list, as the earlier test BEs do)
#   -D DATE     UTC date for the name (default: today)
#   -n SEQ      sequence number for the name (default 1)
#   -m MODDIR   directory holding the built nvidia.ko, nvidia-modeset.ko and
#               nvidia-drm.ko (default $GB10_WORK/build/tree, each in its own
#               subdirectory, as scripts/build-shim.sh leaves them)
#   -u UVM_KO   a nvidia-uvm.ko to put in the BE for the CUDA smoke row
#   --dry-run   print every command and change nothing
#   --activate  finish with `bectl activate -t`.  Without it the BE is left
#               unactivated: arming a boot is the orchestrator's decision.
#
# The BE is named nvidia-prime-import-test-<date>-<n>.  Everything that
# differs from the base BE goes into the clone only; the running system is
# not touched.  No module is loaded or unloaded and nothing is rebooted.
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
DATE=$(date -u +%Y%m%d)
SEQ=1
MODDIR=$WORK/build/tree
UVMKO=
DRY=0
ACTIVATE=0

need() {
	[ "$2" -ge 2 ] || { echo "make-be.sh: $1 needs a value" >&2; usage; }
}

usage() {
	sed -n '5,/^# Environment/p' "$0" | sed 's/^# \{0,1\}//' >&2
	exit 2
}

while [ $# -gt 0 ]; do
	case $1 in
	-b) need "$1" "$#"; BASE=$2; shift 2 ;;
	-D) need "$1" "$#"; DATE=$2; shift 2 ;;
	-n) need "$1" "$#"; SEQ=$2; shift 2 ;;
	-m) need "$1" "$#"; MODDIR=$2; shift 2 ;;
	-u) need "$1" "$#"; UVMKO=$2; shift 2 ;;
	--dry-run) DRY=1; shift ;;
	--activate) ACTIVATE=1; shift ;;
	-h | --help) usage ;;
	*) echo "make-be.sh: unknown argument: $1" >&2; usage ;;
	esac
done

[ -n "$BASE" ] || { echo "make-be.sh: -b BASE_BE is required" >&2; usage; }
case $DATE in
[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) ;;
*) echo "make-be.sh: -D must be YYYYMMDD" >&2; exit 2 ;;
esac
case $SEQ in
'' | *[!0-9]*) echo "make-be.sh: -n must be a number" >&2; exit 2 ;;
esac
case $BASE in
*[!A-Za-z0-9._-]* | -*) echo "make-be.sh: unusable base BE name" >&2; exit 2 ;;
esac

BE=nvidia-prime-import-test-$DATE-$SEQ
MNT=${PRIME_MNT:-$WORK/tmp/$BE.mnt}

run() {
	echo "+ $*"
	[ "$DRY" -eq 1 ] || "$@"
}

modules="nvidia/nvidia.ko nvidia-modeset/nvidia-modeset.ko nvidia-drm/nvidia-drm.ko"
for m in $modules; do
	[ "$DRY" -eq 1 ] || [ -f "$MODDIR/$m" ] || { echo "make-be.sh: missing $MODDIR/$m" >&2; exit 1; }
done
for f in prime_import_testboot prime_import_probe.c prime_import_probe.8; do
	[ -f "$KITDIR/$f" ] || { echo "make-be.sh: missing $KITDIR/$f" >&2; exit 1; }
done

# the probe is built here, on the build host, from the kit's source
PROBE=$WORK/tmp/prime_import_probe.$$
run cc -o "$PROBE" "$KITDIR/prime_import_probe.c" -I/usr/local/include \
    -I/usr/local/include/libdrm -L/usr/local/lib -ldrm

run "$BECTL" create -e "$BASE" "$BE"
run mkdir -p "$MNT"
run "$BECTL" mount "$BE" "$MNT"

# The clone inherits the base BE's rc.conf and module directory, and this boot
# must run the kit alone.  Any other *_testboot_enable in it is turned off
# (a second kit would load other modules, run other probes and reboot on its
# own), and an nvidia-uvm.ko the base left behind is removed unless -u gives
# one: the kit tests the three modules it was built with, nothing else.
if [ "$DRY" -eq 1 ]; then
	echo "+ turn off every other *_testboot_enable in $MNT/etc/rc.conf, $MNT/etc/rc.conf.local and every regular file under $MNT/etc/rc.conf.d"
else
	for _f in "$MNT/etc/rc.conf" "$MNT/etc/rc.conf.local" $(find "$MNT/etc/rc.conf.d" -type f 2>/dev/null); do
		[ -f "$_f" ] || continue
		if [ -L "$_f" ]; then echo "make-be.sh: $_f is a symbolic link; it is not rewritten (it could point outside the clone)" >&2; continue; fi
		grep -Eq '^[[:space:]]*[A-Za-z0-9_]+_testboot_enable=' "$_f" || continue
		sed -E -e '/^[[:space:]]*prime_import_testboot_enable=/b' \
		    -e 's/^([[:space:]]*[A-Za-z0-9_]+_testboot_enable)=.*/\1="NO"/' "$_f" > "$_f.prime-new" \
		    || { rm -f "$_f.prime-new"; echo "make-be.sh: cannot rewrite $_f; the BE is left mounted at $MNT: fix the file by hand or remove the boot environment $BE and start again" >&2; exit 1; }
		if cmp -s "$_f" "$_f.prime-new"; then
			rm -f "$_f.prime-new"
		else
			cat "$_f.prime-new" > "$_f" && rm -f "$_f.prime-new" \
			    || { echo "make-be.sh: cannot write $_f; the BE is left mounted at $MNT: fix the file by hand or remove the boot environment $BE and start again" >&2; exit 1; }
			echo "turned off the other test-boot kits in $_f"
		fi
	done
fi
run mkdir -p "$MNT/boot/modules.nvtest"
if [ -z "$UVMKO" ]; then
	run rm -f "$MNT"/boot/modules.nvtest/nvidia-uvm.ko "$MNT"/boot/modules.nvtest/nvidia-uvm.ko.*
fi
for m in $modules; do
	b=$(basename "$m")
	run cp "$MODDIR/$m" "$MNT/boot/modules.nvtest/$b"
	if [ "$DRY" -eq 0 ]; then
		want=$(sha256 -q "$MODDIR/$m")
		got=$(sha256 -q "$MNT/boot/modules.nvtest/$b")
		if [ "$want" != "$got" ]; then
			echo "make-be.sh: $b differs after the copy ($want, $got); BE left mounted at $MNT" >&2
			exit 1
		fi
		echo "$b $got"
	else
		echo "+ sha256 $MODDIR/$m == $MNT/boot/modules.nvtest/$b"
	fi
done
if [ -n "$UVMKO" ]; then
	run cp "$UVMKO" "$MNT/boot/modules.nvtest/nvidia-uvm.ko"
fi

run install -d "$MNT/usr/local/bin" "$MNT/usr/local/share/man/man8" "$MNT/usr/local/etc/rc.d"
run install -m 0555 "$PROBE" "$MNT/usr/local/bin/prime_import_probe"
run install -m 0444 "$KITDIR/prime_import_probe.8" "$MNT/usr/local/share/man/man8/prime_import_probe.8"
run install -m 0555 "$KITDIR/prime_import_testboot" "$MNT/usr/local/etc/rc.d/prime_import_testboot"
if [ "$DRY" -eq 1 ]; then
	echo "+ write $MNT/etc/rc.conf.d/prime_import_testboot: prime_import_testboot_enable=YES"
else
	mkdir -p "$MNT/etc/rc.conf.d"
	printf 'prime_import_testboot_enable="YES"\n' > "$MNT/etc/rc.conf.d/prime_import_testboot"
fi

run "$BECTL" umount "$BE"
run rm -f "$PROBE"
if [ "$ACTIVATE" -eq 1 ]; then
	run "$BECTL" activate -t "$BE"
	echo "armed: $BE boots once; results land in $(sed -n 's/^LOGROOT=//p' "$KITDIR/prime_import_testboot")/prime-import-<stamp>/"
else
	echo "built: $BE (not armed; the orchestrator arms it with a one-shot boot environment activation)"
fi

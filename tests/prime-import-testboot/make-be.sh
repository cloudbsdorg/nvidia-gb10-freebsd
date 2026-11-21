#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# make-be.sh - assemble the one-shot test boot environment for the cross-GPU
# buffer import (Track #2228, docs/PRIME-IMPORT.md, section 5).
#
# Usage: make-be.sh -b BASE_BE [-D YYYYMMDD] [-n SEQ] [-m MODDIR] [-u UVM_KO]
#                   [-V COMMIT] [--dry-run] [--activate]
#   -b BASE_BE  the boot environment to clone (required; it must already load
#               amdgpu and the nvidia stack from /boot/modules.nvtest through
#               kld_list, as the earlier test BEs do)
#   -D DATE     UTC date for the name (default: today)
#   -n SEQ      sequence number for the name (default 1)
#   -m MODDIR   directory holding the built nvidia.ko, nvidia-modeset.ko and
#               nvidia-drm.ko (default $GB10_WORK/build/tree, each in its own
#               subdirectory, as scripts/build-shim.sh leaves them)
#   -u UVM_KO   a nvidia-uvm.ko to put in the BE for the CUDA smoke row
#   -V COMMIT   the commit this kit was extracted from (hex).  A kit that boots is built from
#               `git archive COMMIT` extracted into a fresh directory, never from a live work
#               tree: inside a git work tree this script refuses to run when the tree has
#               uncommitted changes (and records HEAD); outside one it refuses to run without -V.
#               The commit is recorded in the BE and in the run's results (row kit-version).
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
COMMIT=
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
	-V) need "$1" "$#"; COMMIT=$2; shift 2 ;;
	--dry-run) DRY=1; shift ;;
	--activate) ACTIVATE=1; shift ;;
	-h | --help) usage ;;
	*) echo "make-be.sh: unknown argument: $1" >&2; usage ;;
	esac
done

[ -n "$BASE" ] || { echo "make-be.sh: -b BASE_BE is required" >&2; usage; }
case $COMMIT in
'') ;;
*[!0-9a-fA-F]*) echo "make-be.sh: -V takes a hex commit id" >&2; exit 2 ;;
esac
# the kit must come from a committed state: a clean git work tree (its HEAD), or an extracted archive named by -V
if [ "${PRIME_ALLOW_DIRTY:-0}" = 1 ]; then
	[ -n "$COMMIT" ] || COMMIT=unknown-dirty-allowed
elif git -C "$KITDIR" rev-parse --git-dir > /dev/null 2>&1; then
	if [ -n "$(git -C "$KITDIR" status --porcelain 2>/dev/null)" ]; then
		echo "make-be.sh: the work tree of this kit has uncommitted changes; build from git archive of the reviewed commit extracted into a fresh directory (and name it with -V)" >&2
		exit 2
	fi
	[ -n "$COMMIT" ] || COMMIT=$(git -C "$KITDIR" rev-parse HEAD)
elif [ -z "$COMMIT" ]; then
	echo "make-be.sh: this kit is not in a git work tree; name the commit it was extracted from with -V" >&2
	exit 2
fi
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

# Any failure after the clone exists removes the half-built boot environment
# (unmounted first): a failed run must not leave an unfinished BE that looks like a built one.
BE_MADE=0
BE_DONE=0
cleanup() {
	_rc=$?
	trap '' INT TERM HUP
	[ "$DRY" -eq 0 ] && rm -f "$PROBE"
	if [ "$BE_MADE" -eq 1 ] && [ "$BE_DONE" -eq 0 ] && [ "$DRY" -eq 0 ]; then
		echo "make-be.sh: failed (exit $_rc); removing the half-built boot environment $BE" >&2
		"$BECTL" umount -f "$BE" > /dev/null 2>&1 || true
		if "$BECTL" destroy -F "$BE" > /dev/null 2>&1; then
			echo "make-be.sh: the half-built boot environment $BE is removed" >&2
		else
			echo "make-be.sh: COULD NOT remove the half-built boot environment $BE: remove it by hand with bectl(8) before using the name again" >&2
		fi
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

# The clone inherits the base BE's rc.conf and module directory, and this boot
# must run the kit alone.  Any other *_testboot_enable in it is turned off
# (a second kit would load other modules, run other probes and reboot on its
# own), and an nvidia-uvm.ko the base left behind is removed unless -u gives
# one: the kit tests the three modules it was built with, nothing else.
# the files and directories of the clone that can arm a kit (relative to its root)
RC_FILES="etc/rc.conf etc/rc.conf.local usr/local/etc/rc.conf usr/local/etc/rc.conf.local"
RC_DIRS="etc/rc.conf.d usr/local/etc/rc.conf.d"

# turn_off FILE: turn off every other kit in one file of the clone.  A missing file is nothing to do;
# a symbolic link, or a path that resolves outside the clone, is never written through.
turn_off() {
	_f=$1
	[ -f "$_f" ] || return 0
	if [ -L "$_f" ]; then echo "make-be.sh: $_f is a symbolic link; it is not rewritten (it could point outside the clone)" >&2; return 0; fi
	case $(realpath "$_f" 2>/dev/null) in "$(realpath "$MNT")"/*) ;; *) echo "make-be.sh: $_f resolves outside the clone (a symbolic link in its path); it is not rewritten" >&2; return 0 ;; esac
	grep -Eq '^[[:space:]]*[A-Za-z0-9_]+_testboot_enable=' "$_f" || return 0
	sed -E -e '/^[[:space:]]*prime_import_testboot_enable=/b' \
	    -e 's/^([[:space:]]*[A-Za-z0-9_]+_testboot_enable)=.*/\1="NO"/' "$_f" > "$_f.prime-new" \
	    || { rm -f "$_f.prime-new"; echo "make-be.sh: cannot rewrite $_f" >&2; exit 1; }
	if cmp -s "$_f" "$_f.prime-new"; then
		rm -f "$_f.prime-new"
	else
		cat "$_f.prime-new" > "$_f" && rm -f "$_f.prime-new" \
		    || { echo "make-be.sh: cannot write $_f" >&2; exit 1; }
		echo "turned off the other test-boot kits in $_f"
	fi
}

if [ "$DRY" -eq 1 ]; then
	echo "+ turn off every other *_testboot_enable in the clone's $RC_FILES and in every regular file under $RC_DIRS"
else
	for _n in $RC_FILES; do
		turn_off "$MNT/$_n"
	done
	for _n in $RC_DIRS; do
		[ -d "$MNT/$_n" ] || continue
		find "$MNT/$_n" -type f > "$WORK/tmp/make-be-files.$$" 2>/dev/null || :
		# one file name per line (a name with a newline in it is not supported)
		while IFS= read -r _g; do
			turn_off "$_g"
		done < "$WORK/tmp/make-be-files.$$"
		rm -f "$WORK/tmp/make-be-files.$$"
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
			echo "make-be.sh: $b differs after the copy ($want, $got); the half-built BE is removed" >&2
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
	printf '%s\n' "$COMMIT" > "$MNT/usr/local/etc/prime_import_testboot.version"
fi

run "$BECTL" umount "$BE"
BE_DONE=1
run rm -f "$PROBE"
if [ "$ACTIVATE" -eq 1 ]; then
	run "$BECTL" activate -t "$BE"
	echo "armed: $BE boots once; results land in $(sed -n 's/^: "${prime_import_testboot_logroot:=\(.*\)}"$/\1/p' "$KITDIR/prime_import_testboot")/prime-import-<stamp>/"
else
	echo "built: $BE (not armed; the orchestrator arms it with a one-shot boot environment activation)"
fi

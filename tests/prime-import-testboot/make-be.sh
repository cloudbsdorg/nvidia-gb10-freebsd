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
#               nvidia-drm.ko (default $GB10_WORK/testboot-prime-import/mods, each in
#               its own subdirectory: the staging directory, not a build tree)
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
# Environment: GB10_WORK (default $HOME/work/gb10), BECTL (default bectl), PRIME_MNT (the mount point of
# the clone, default $GB10_WORK/tmp/<BE name>.mnt).  Test hooks, honoured only with GB10_TEST_HOOKS=1:
# PRIME_KO_ORDER_TOOL (the module order checker, default ko_sysinit_order.py beside this script) and
# PRIME_ALLOW_DIRTY=1 (skips the committed-kit checks).

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
MODDIR=$WORK/testboot-prime-import/mods
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
COMMIT=$(printf '%s' "$COMMIT" | tr 'A-F' 'a-f')
case $COMMIT in
'') ;;
*[!0-9a-f]*) echo "make-be.sh: -V takes a hex commit id" >&2; exit 2 ;;
*) [ ${#COMMIT} -ge 7 ] || { echo "make-be.sh: -V needs at least 7 hex digits of the commit" >&2; exit 2; } ;;
esac
# The kit must come from a committed state: a clean git work tree (its HEAD), or the extraction of
# `git archive <commit>` (its KIT-COMMIT file carries the commit through export-subst).  -V, when given,
# must agree with the commit that is found (HEAD, or the one KIT-COMMIT names: KIT-COMMIT is a record, not a proof of content).
ARCHIVE_SHA=
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_COMMON_DIR	# git must look at the kit, not at a repository the environment names
if [ -f "$KITDIR/KIT-COMMIT" ]; then
	_k=$(tr -d ' \n' < "$KITDIR/KIT-COMMIT")
	case $_k in *[!0-9a-f]* | '') ;; *) [ ${#_k} -eq 40 ] && ARCHIVE_SHA=$_k ;; esac
fi
same_commit() {	# same_commit PREFIX FULL
	case $2 in "$1"*) return 0 ;; esac
	return 1
}
if [ "${GB10_TEST_HOOKS:-0}" = 1 ] && [ "${PRIME_ALLOW_DIRTY:-0}" = 1 ]; then
	# a test hook: whatever -V says, the value is marked, so the row never looks like a checked build
	COMMIT=unchecked-${COMMIT:-dirty-allowed}
elif [ -n "$ARCHIVE_SHA" ]; then
	# an extraction of git archive (its KIT-COMMIT is expanded), wherever it was extracted, even inside a git work tree
	if [ -n "$COMMIT" ] && ! same_commit "$COMMIT" "$ARCHIVE_SHA"; then
		echo "make-be.sh: -V $COMMIT is not the commit this kit was archived from ($ARCHIVE_SHA)" >&2
		exit 2
	fi
	COMMIT=$ARCHIVE_SHA
elif git -C "$KITDIR" rev-parse --git-dir > /dev/null 2>&1; then
	# every file of the kit that is installed must be tracked: an untracked or ignored kit inside somebody
	# else's repository is not a committed kit
	for _kf in make-be.sh prime_import_testboot prime_import_probe.c prime_import_probe.8 summarize.sh ko_sysinit_order.py KIT-COMMIT; do
		git -C "$KITDIR" ls-files --error-unmatch -- "$_kf" > /dev/null 2>&1 || {
			echo "make-be.sh: $_kf is not tracked by the git repository around it; build from git archive of the reviewed commit" >&2
			exit 2
		}
	done
	# the content of each installed file is compared with the committed one: assume-unchanged, skip-worktree, ignore
	# rules and status settings cannot hide a difference from git hash-object
	_prefix=$(git -C "$KITDIR" rev-parse --show-prefix)
	for _kf in make-be.sh prime_import_testboot prime_import_probe.c prime_import_probe.8 summarize.sh ko_sysinit_order.py KIT-COMMIT; do
		[ "$(git -C "$KITDIR" hash-object -- "$_kf" 2>/dev/null)" = "$(git -C "$KITDIR" rev-parse "HEAD:$_prefix$_kf" 2>/dev/null)" ] || {
			echo "make-be.sh: $_kf differs from the committed one (uncommitted changes); build from git archive of the reviewed commit extracted into a fresh directory" >&2
			exit 2
		}
	done
	if [ -n "$(git -C "$KITDIR" status --porcelain 2>/dev/null)" ]; then
		echo "make-be.sh: the work tree of this kit has uncommitted changes; build from git archive of the reviewed commit extracted into a fresh directory" >&2
		exit 2
	fi
	_head=$(git -C "$KITDIR" rev-parse HEAD)
	if [ -n "$COMMIT" ] && ! same_commit "$COMMIT" "$_head"; then
		echo "make-be.sh: -V $COMMIT is not the commit of this work tree ($_head)" >&2
		exit 2
	fi
	COMMIT=$_head
else
	echo "make-be.sh: this kit is neither in a git work tree nor from git archive (no expanded KIT-COMMIT), so its commit cannot be checked: run git archive <commit> | tar -x -C <new directory> and use the make-be.sh there" >&2
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
[ "$BASE" != "$BE" ] || { echo "make-be.sh: the base boot environment is the target name: $BE would be cloned onto itself and a failure would remove the base" >&2; exit 2; }
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

# The module order of the staged nvidia-drm.ko, read from the file that is going to boot: the guard must be
# declared in the same subsystem and with a greater order than the driver module (it loads last, so it unloads
# first).  Refused before anything is created.  The tool needs readelf (FreeBSD base: ELF Tool Chain) and python3.
KO_TOOL=$KITDIR/ko_sysinit_order.py
# a replaced checker is a test hook: it needs both hooks and the commit is marked unchecked
if [ "${GB10_TEST_HOOKS:-0}" = 1 ] && [ "${PRIME_ALLOW_DIRTY:-0}" = 1 ] && [ -n "${PRIME_KO_ORDER_TOOL:-}" ]; then
	KO_TOOL=$PRIME_KO_ORDER_TOOL
	case $COMMIT in unchecked-*) ;; *) COMMIT=unchecked-$COMMIT ;; esac
fi
KO_SHA=
if [ "$DRY" -eq 0 ]; then
	[ -f "$KO_TOOL" ] || { echo "make-be.sh: no $KO_TOOL to check the module order with" >&2; exit 2; }
	KO_SHA=$(sha256 -q "$MODDIR/nvidia-drm/nvidia-drm.ko")	# the file that is checked: the copy below must be this one
	_ko_out=$(python3 -I -B "$KO_TOOL" --check "$MODDIR/nvidia-drm/nvidia-drm.ko" 2>&1) || { echo "make-be.sh: $MODDIR/nvidia-drm/nvidia-drm.ko: $_ko_out; rebuild from the committed tree and stage it again" >&2; exit 2; }
else
	echo "+ (dry run: the module order of $MODDIR/nvidia-drm/nvidia-drm.ko is NOT checked here; a real run checks it before the clone is created)"
fi

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
			echo "make-be.sh: the half-built boot environment $BE is removed (the snapshot it was cloned from stays on the base boot environment: bectl list -s shows it; remove it with bectl(8) if you do not need it)" >&2
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
		if [ "$b" = nvidia-drm.ko ] && [ "$want" != "$KO_SHA" ]; then
			echo "make-be.sh: $MODDIR/$m changed after its module order was checked; the half-built BE is removed" >&2
			exit 1
		fi
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

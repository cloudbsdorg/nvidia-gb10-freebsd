#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# build-shim.sh - measure the arm64 compile state of NVIDIA's FreeBSD OS
# layer: build TREE/nvidia for arm64 and summarise the compiler errors.
#
# Usage: scripts/build-shim.sh [--module=nvidia|nvidia-modeset|nvidia-drm] [TREE] [LOG]
#   --module the module directory to build: nvidia (the default),
#            nvidia-modeset or nvidia-drm. The module may also be named by
#            its bare word as the first argument (nvidia-modeset), the form
#            the README's build recipe uses.
#   TREE      prepared working tree (from scripts/prepare-tree.sh); defaults
#             to ${GB10_WORK:-$HOME/work/gb10}/build/tree
#   LOG       build log to write; defaults to
#             ${GB10_WORK:-$HOME/work/gb10}/logs/build-shim-<UTC stamp>.log
#
# Environment:
#   GB10_WORK work root holding the default TREE and logs/
#   SYSDIR    kernel source sys/ directory; defaults to /usr/src/sys
#   RMOBJ     aarch64 RM core object to link in place of NVIDIA's amd64
#             blob (scripts/build-rmcore.sh + build-stubs.sh produce
#             $WORK/build/nv-kernel-gb10.o for the nvidia module and
#             scripts/build-rmcore.sh --core=nvidia-modeset produces
#             $WORK/build/nv-modeset-kernel-aarch64.o for the modeset
#             module); defaults to that path. The nvidia-drm module has no
#             RM core of its own and never copies one.
#   DRMKMODDIR
#             the drm-kmod source tree nvidia-drm is built against: the
#             tree the running drm.ko was built from. Required for
#             --module=nvidia-drm and NOTHING ELSE: there is no default
#             that guesses (the module's own Makefile defaults to
#             ${HOME}/git/drm-kmod, which is right on no other host), and
#             a DRMKMODDIR that is not an absolute path, is not a
#             directory or holds no linuxkpi_version.mk is refused.
#             The stamp in TREE/<module>/.gb10-sysdir records it, so a
#             changed DRMKMODDIR cleans the objects before the build.
#   BSDSRCTOP
#             the top of the FreeBSD source tree nvidia-drm is built
#             against (the Makefile takes its headers from there, not
#             from the installed /usr/src). Defaults to the parent of
#             SYSDIR. Must be an absolute path.
#
# Exit codes: 0 build OK; 1 usage error, or an unsafe LOG (a symlink, or
# its directory does not resolve under $WORK/logs) or an unsafe $WORK/tmp
# (a symlink, not owned by the current user, or group/other writable), or
# a refused DRMKMODDIR/BSDSRCTOP;
# 2 TREE/<module> missing, or TREE/.prepared does not say "state done" (an
# incomplete or interrupted prepare-tree.sh run must never be measured);
# 3 build failed: make's exit status was non-zero, the pre-build
# `make clean` (SYSDIR stamp change, see below) failed, or make returned 0
# but left no non-empty TREE/<module>/<module>.ko - "build: OK" prints only
# when this run's module exists, so an inherited MAKEFLAGS=-i/-n can never
# report a build that did not happen (pass-3 u04 #1). The summary
# ("errors: N" and the sorted unique error lines, file:line: error: ...)
# prints on the OK and FAILED paths alike; "build: OK" or
# "build: FAILED (...)" follows it, and the module's size/sha256 prints
# only on the OK path. A stale module
# is removed before make so a failed build can never be summarised from
# an earlier run's artifact. make runs under
# `env -u MAKEFLAGS -u MFLAGS -u MAKELEVEL -u MAKEOBJDIR
# -u MAKEOBJDIRPREFIX`, so flags or object-directory overrides leaked from
# a parent make or a CI wrapper cannot change what the build does or where
# its objects go.
#
# SYSDIR stamp: the objects in TREE/<module> are compiled against one
# SYSDIR; silently reusing them after SYSDIR (or its sys/param.h
# __FreeBSD_version) changed once produced an identical nvidia.ko sha256
# across a SYSDIR change (2026-11-18). The SYSDIR path and version are
# recorded in TREE/<module>/.gb10-sysdir; when the recorded stamp differs -
# or is absent while objects of unknown origin are present - `make clean`
# runs before the build. The stamp also records the BSDSRCTOP and the
# DRMKMODDIR of the nvidia-drm module, whose objects are built against
# those two trees' headers.
# The log is never /tmp; scratch files stay under $WORK/tmp.

set -eu

PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL

WORK=${GB10_WORK:-$HOME/work/gb10}
SYSDIR=${SYSDIR:-/usr/src/sys}

SCRIPTDIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPTDIR/lib.sh"

# The module directory to build. Both modules come from the same prepared
# tree and are built the same way; they differ in the directory built, the
# module required at the end, the RM core object swapped in and the RM
# core file it replaces.
MODULE=nvidia
usage() {
	echo "usage: build-shim.sh [--module=nvidia|nvidia-modeset|nvidia-drm] [TREE] [LOG]" >&2
}
while [ $# -gt 0 ]; do
	case $1 in
	--module=*)
		MODULE=${1#--module=}
		shift
		;;
	--module)
		if [ $# -lt 2 ]; then
			echo "build-shim: --module needs a module name" >&2
			usage
			exit 1
		fi
		MODULE=$2
		shift 2
		;;
	--)
		shift
		break
		;;
	-*)
		echo "build-shim: unknown option: $1" >&2
		usage
		exit 1
		;;
	*)
		break
		;;
	esac
done
# The module may also be named by its bare word as the first argument: the
# README's build recipe is one line, and "nvidia", "nvidia-modeset" and
# "nvidia-drm" are not plausible TREE paths.
if [ $# -gt 0 ]; then
	case $1 in
	nvidia|nvidia-modeset|nvidia-drm)
		MODULE=$1
		shift
		;;
	esac
fi

if [ $# -gt 2 ]; then
	usage
	exit 1
fi

case $MODULE in
nvidia)
	MODDIR=nvidia
	MODKO=nvidia.ko
	RMOBNAME=nv-kernel.o
	RMOBJDEF=$WORK/build/nv-kernel-gb10.o
	;;
nvidia-modeset)
	MODDIR=nvidia-modeset
	MODKO=nvidia-modeset.ko
	RMOBNAME=nv-modeset-kernel.o
	RMOBJDEF=$WORK/build/nv-modeset-kernel-aarch64.o
	;;
nvidia-drm)
	# The DRM module has no RM core of its own: it is NVIDIA's own
	# FreeBSD code against drm-kmod, so there is no core object to
	# swap in and none is copied (RMOBNAME stays empty).
	MODDIR=nvidia-drm
	MODKO=nvidia-drm.ko
	RMOBNAME=
	RMOBJDEF=
	;;
*)
	echo "build-shim: unknown module: $MODULE (nvidia, nvidia-modeset or nvidia-drm)" >&2
	usage
	exit 1
	;;
esac

TREE=${1:-$WORK/build/tree}
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
LOG=${2:-$WORK/logs/build-shim-$STAMP.log}

# The make variables a module needs beyond MACHINE, MACHINE_ARCH and
# SYSDIR. They are held in the positional parameters (one word each, so a
# path with a space stays one argument) and handed to both make runs -
# the pre-build `make clean` and the build itself - because the module's
# Makefile cannot even be parsed without them: it includes
# ${DRMKMODDIR}/linuxkpi_version.mk.
#
# DRMKMODDIR is REQUIRED for nvidia-drm and has no default that guesses:
# the module's own Makefile defaults to ${HOME}/git/drm-kmod, which is
# right on no other host, and a wrong drm-kmod tree builds headers that
# do not match the running drm.ko. BSDSRCTOP defaults to the parent of
# SYSDIR (the FreeBSD source tree that tree lives in).
if [ "$MODULE" = nvidia-drm ]; then
	if [ -z "${DRMKMODDIR:-}" ]; then
		echo "build-shim: DRMKMODDIR is not set: nvidia-drm is built against the drm-kmod source tree (the one the running drm.ko was built from)" >&2
		exit 1
	fi
	case $DRMKMODDIR in
	/*) ;;
	*)
		echo "build-shim: refusing DRMKMODDIR $DRMKMODDIR: it must be an absolute path" >&2
		exit 1
		;;
	esac
	if [ ! -d "$DRMKMODDIR" ]; then
		echo "build-shim: refusing DRMKMODDIR $DRMKMODDIR: not a directory" >&2
		exit 1
	fi
	if [ ! -f "$DRMKMODDIR/linuxkpi_version.mk" ]; then
		echo "build-shim: refusing DRMKMODDIR $DRMKMODDIR: no linuxkpi_version.mk in it" >&2
		exit 1
	fi
	BSDSRCTOP=${BSDSRCTOP:-$(dirname "$SYSDIR")}
	case $BSDSRCTOP in
	/*) ;;
	*)
		echo "build-shim: refusing BSDSRCTOP $BSDSRCTOP: it must be an absolute path" >&2
		exit 1
		;;
	esac
	if [ ! -d "$BSDSRCTOP" ]; then
		echo "build-shim: refusing BSDSRCTOP $BSDSRCTOP: not a directory" >&2
		exit 1
	fi
	set -- "BSDSRCTOP=$BSDSRCTOP" "DRMKMODDIR=$DRMKMODDIR"
else
	set --
fi

if [ ! -d "$TREE/$MODDIR" ]; then
	echo "build-shim: no $TREE/$MODDIR: run scripts/prepare-tree.sh first" >&2
	exit 2
fi

# The TREE must be a COMPLETED prepare-tree.sh run: line 2 of its .prepared
# marker must say "state done" (line 1 names the script and the resolved
# path that wrote it). A marker still saying "state building" belongs to a
# run in flight or an interrupted one; measuring that tree would report a
# half-built state as the real one. Fail closed: an unreadable or missing
# marker is refused too.
if [ ! -f "$TREE/.prepared" ] \
    || [ "$(sed -n '2p' "$TREE/.prepared" 2>/dev/null)" != "state done" ]; then
	echo "build-shim: refusing TREE $TREE: .prepared does not say 'state done': run scripts/prepare-tree.sh" >&2
	exit 2
fi

# LOG may be any path: refuse a symlink, and refuse anything whose
# directory does not resolve (realpath) under $WORK/logs, so the build
# log can never be written through a symlink or outside the work root.
# The rule is log_path_safe in lib.sh, shared with build-firmware.sh.
log_path_safe build-shim "$LOG" || exit 1

# $WORK/tmp must belong to the current user and must not be writable by
# group or other, or scratch files could be planted by someone else.
# stat(1) uses lstat(2) unless given -L, so a symlink to a directory would
# answer the owner/mode check from the LINK ITSELF (its own 0755 mode and
# this user's uid always pass) while TMPDIR then points at the arbitrary -
# possibly 0777, possibly /tmp - target: refuse a symlink before the stat
# (pass-2 u04 #2, same fix as fetch-sources.sh's DESTDIR).
if [ -L "$WORK/tmp" ]; then
	echo "build-shim: refusing $WORK/tmp: symlink" >&2
	exit 1
fi
mkdir -p "$WORK/tmp"
tmpstat=$(stat -f '%u %Lp' "$WORK/tmp") || {
	echo "build-shim: cannot stat $WORK/tmp" >&2
	exit 1
}
tmpowner=${tmpstat%% *}
tmpmode=${tmpstat##* }
uid=$(id -u)
if [ "$tmpowner" != "$uid" ]; then
	echo "build-shim: refusing $WORK/tmp: owned by uid $tmpowner, not $uid" >&2
	exit 1
fi
if [ $((0$tmpmode & 022)) -ne 0 ]; then
	echo "build-shim: refusing $WORK/tmp: group or other writable (mode $tmpmode)" >&2
	exit 1
fi
TMPDIR=$WORK/tmp
export TMPDIR

# SYSDIR stamp (see the header): record which SYSDIR - and which
# __FreeBSD_version from its sys/param.h - the objects in TREE/$MODDIR are
# built against, and clean them when that changes. Reusing objects built
# against an older SYSDIR silently links stale code: on 2026-11-18 a
# SYSDIR change produced a byte-identical nvidia.ko because only the .ko
# was removed, not the objects it was linked from. The stamp lives in
# TREE/$MODDIR; prepare-tree.sh rebuilds TREE from scratch, so a fresh tree
# starts unstamped (and object-free, so no clean is needed).
STAMPFILE=$TREE/$MODDIR/.gb10-sysdir
sysver=$(awk '$1 == "#define" && $2 == "__FreeBSD_version" { print $3; exit }' \
    "$SYSDIR/sys/param.h" 2>/dev/null) || sysver=
[ -n "$sysver" ] || sysver=unknown
sysstamp="sysdir $SYSDIR
version $sysver"
# The nvidia-drm module's objects are built against the drm-kmod tree's
# headers and against the FreeBSD source tree BSDSRCTOP points at, so
# both belong in the stamp: a changed one must clean the objects (the
# conftest headers are generated from them) before the build reuses them.
if [ "$MODULE" = nvidia-drm ]; then
	sysstamp="$sysstamp
bsdsrctop $BSDSRCTOP
drmkmoddir $DRMKMODDIR"
fi
# A symlinked stamp would be read from, and written through to, somewhere
# else; refuse it like every other path this script writes.
if [ -L "$STAMPFILE" ]; then
	echo "build-shim: refusing $STAMPFILE: symlink" >&2
	exit 1
fi
oldstamp=$(cat "$STAMPFILE" 2>/dev/null) || oldstamp=
need_clean=0
if [ "$sysver" = unknown ]; then
	# An unreadable sys/param.h cannot prove the objects match: clean
	# always, even when an earlier run left the same "unknown" stamp.
	need_clean=1
elif [ -n "$oldstamp" ]; then
	[ "$oldstamp" = "$sysstamp" ] || need_clean=1
else
	# No stamp: any object already in the tree is of unknown origin.
	for _f in "$TREE/$MODDIR"/*.o "$TREE/$MODDIR"/*.kld "$TREE/$MODDIR"/*.ko; do
		if [ -e "$_f" ]; then
			need_clean=1
			break
		fi
	done
fi
: > "$LOG"
if [ "$need_clean" -eq 1 ]; then
	echo "build-shim: SYSDIR ($SYSDIR, __FreeBSD_version $sysver) differs from the stamp; running make clean first"
	crc=0
	env -u MAKEFLAGS -u MFLAGS -u MAKELEVEL -u MAKEOBJDIR -u MAKEOBJDIRPREFIX \
	    make -C "$TREE/$MODDIR" \
	    MACHINE=arm64 MACHINE_ARCH=aarch64 \
	    SYSDIR="$SYSDIR" \
	    "$@" \
	    clean >> "$LOG" 2>&1 || crc=$?
	if [ "$crc" -ne 0 ]; then
		echo "build-shim: FAILED (make clean rc $crc)"
		exit 3
	fi
fi
# Written BEFORE the build: the stamp then always names the SYSDIR the
# objects in the tree - complete or partial - were compiled against.
printf '%s\n' "$sysstamp" > "$STAMPFILE"

# RM core swap - link against the open RM core for aarch64 (plus the
# fail-closed stubs) when it has been built; otherwise link whatever
# core object is already in TREE - and SAY which object that is by sha256,
# because an earlier run's swap may have replaced NVIDIA's blob and "as-is"
# would misreport what gets linked (pass-2 u04 #3). Only the disposable
# TREE copy of the core object is ever touched; NVIDIA's own file under
# src/ stays pristine.
# The nvidia-drm module has no RM core: it is NVIDIA's own FreeBSD code
# against drm-kmod, and no core object is copied into its directory.
if [ "$MODULE" = nvidia-drm ]; then
	echo "note: the nvidia-drm module has no RM core object; none is linked in"
else
	RMOBJ=${RMOBJ:-$RMOBJDEF}
	if [ -f "$RMOBJ" ]; then
		cp "$RMOBJ" "$TREE/$MODDIR/$RMOBNAME"
		echo "rm core: $RMOBJ -> $TREE/$MODDIR/$RMOBNAME sha256 $(sha256 -q "$TREE/$MODDIR/$RMOBNAME")"
	elif [ -f "$TREE/$MODDIR/$RMOBNAME" ]; then
		echo "rm core: no $RMOBJ: linking the $RMOBNAME already in TREE, sha256 $(sha256 -q "$TREE/$MODDIR/$RMOBNAME")"
	else
		echo "rm core: no $RMOBJ and no $TREE/$MODDIR/$RMOBNAME in TREE: the link will have no RM core object"
	fi
fi

# The build itself: cross-compile flags for arm64, -k so every file gets a
# verdict. Build in TREE/$MODDIR itself, not an object directory: with
# MAKEOBJDIR + the obj target, the module's Makefile's stdarg.h symlink and
# the kmod link are made in the object directory, where the compiler does
# not find them (nv_stdarg.h:36: 'stdarg.h' file not found).
# The tree is disposable (prepare-tree.sh rebuilds it from scratch on every
# run), so in-tree objects are fine.
# Remove any stale module first: a failed make must never leave an
# earlier run's artifact behind for the summary to report. Keep make's
# exit status instead of discarding it with "|| true". env -u strips the
# inherited make variables (pass-3 u04 #1): a MAKEFLAGS=-i/-n leaked from
# a parent make or a CI wrapper would otherwise turn a failed or dry-run
# build into an exit 0, and MAKEOBJDIR(PREFIX) would move the objects
# away from the tree that gets summarised.
rm -f "$TREE/$MODDIR/$MODKO"
rc=0
env -u MAKEFLAGS -u MFLAGS -u MAKELEVEL -u MAKEOBJDIR -u MAKEOBJDIRPREFIX \
    make -C "$TREE/$MODDIR" -k \
    MACHINE=arm64 MACHINE_ARCH=aarch64 \
    SYSDIR="$SYSDIR" \
    "$@" \
    all >> "$LOG" 2>&1 || rc=$?

# summarise - print "errors: N" and the sorted unique ' error: ' lines of
# LOG with their file:line prefixes.
# Time:  O(L log L) for L log lines (grep pass, then sort -u).
# Space: O(E) for E error lines held by sort.
summarise() {
	_n=$(grep -c ' error: ' "$LOG" || true)
	printf 'errors: %s\n' "${_n:-0}"
	if [ "${_n:-0}" -gt 0 ]; then
		grep ' error: ' "$LOG" | sort -u
	fi
}

echo "log: $LOG"
summarise
if [ "$rc" -ne 0 ]; then
	echo "build: FAILED (make rc $rc)"
	exit 3
fi
# "build: OK" requires positive evidence: a non-empty module produced by
# THIS run (the stale one was removed before make). Without this gate a
# make that exits 0 while building nothing - an inherited MAKEFLAGS=-i/-n
# that reached it, or a Makefile regression - reports a build that did not
# happen (pass-3 u04 #1).
if [ ! -s "$TREE/$MODDIR/$MODKO" ]; then
	echo "build: FAILED (no $MODKO)"
	exit 3
fi
echo "build: OK"
echo "$MODKO: $(stat -f %z "$TREE/$MODDIR/$MODKO") bytes, sha256 $(sha256 -q "$TREE/$MODDIR/$MODKO")"
exit 0

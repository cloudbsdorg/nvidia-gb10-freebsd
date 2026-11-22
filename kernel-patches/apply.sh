#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-2-Clause
#
# apply.sh - apply the kernel patches in this directory to a FreeBSD source
# tree, in the order of the "series" file.
#
# Usage: sh apply.sh [-n] [-R] SRCDIR [PATCH ...]
#   SRCDIR   top of a FreeBSD source tree (the directory holding sys/).
#   PATCH    only these patches (file names from "series"); default all.
#   -n       dry run only: check every patch, change nothing.
#   -R       revert: take the patches out again, last one first.
#   -h       this help.
#
# Every patch is checked with patch --dry-run first.  If any one of them
# would not apply cleanly (a rejected hunk, or a hunk that only fits with
# fuzz), the script stops before it changes a single file and says which
# patch and which file.  A patch that is already in the tree is reported
# and skipped, so running the script twice is harmless.
#
# The script writes only inside SRCDIR, and only the files the patches
# name: no backup (.orig) files, no reject (.rej) files, nothing in /tmp.
# It needs patch(1) and nothing else; it does not need root.
#
# Exit status: 0 done (or nothing to do), 1 a patch does not apply or the
# tree is not usable, 2 usage error.

set -u

PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
LC_ALL=C
export LC_ALL

me=apply.sh
here=$(cd -- "$(dirname -- "$0")" && pwd) || exit 1
series=$here/series

usage() {
	sed -n '/^# Usage:/,/^#   -h/p' "$0" | sed 's/^# \{0,1\}//'
}

die() {
	printf '%s: %s\n' "$me" "$*" >&2
	exit 1
}

dry=0
reverse=0
while getopts nRh opt; do
	case $opt in
	n) dry=1 ;;
	R) reverse=1 ;;
	h) usage; exit 0 ;;
	*) usage >&2; exit 2 ;;
	esac
done
shift $((OPTIND - 1))
[ $# -ge 1 ] || { usage >&2; exit 2; }
src=$1
shift

command -v patch >/dev/null 2>&1 || die "patch(1) not found"
[ -f "$series" ] || die "no series file next to the script ($series)"
[ -d "$src" ] || die "$src: not a directory"
src=$(cd -- "$src" && pwd) || die "$src: cannot enter"
[ -f "$src/sys/conf/newvers.sh" ] && [ -f "$src/sys/sys/param.h" ] ||
    die "$src: not a FreeBSD source tree (no sys/conf/newvers.sh or sys/sys/param.h)"

# The patch names, in series order.
all=$(sed -e 's/#.*//' -e 's/[[:space:]]*$//' -e '/^$/d' "$series")
[ -n "$all" ] || die "series lists no patches"

if [ $# -gt 0 ]; then
	want=
	for p in "$@"; do
		p=$(basename -- "$p")
		printf '%s\n' "$all" | grep -qxF -- "$p" ||
		    die "$p: not in the series (see $series)"
		want="$want $p"
	done
	list=
	for p in $all; do
		case " $want " in
		*" $p "*) list="$list $p" ;;
		esac
	done
else
	list=$(printf '%s\n' "$all" | tr '\n' ' ')
fi
if [ "$reverse" = 1 ]; then
	r=
	for p in $list; do r="$p $r"; done
	list=$r
fi

# Every path a patch names must stay inside the tree: relative, no "..".
for p in $list; do
	f=$here/$p
	[ -f "$f" ] || die "$p: listed in the series but missing"
	bad=$(sed -n -e 's/^--- \([^	]*\).*/\1/p' -e 's/^+++ \([^	]*\).*/\1/p' "$f" |
	    grep -v -e '^/dev/null$' |
	    sed 's|^[ab]/||' |
	    grep -e '^/' -e '^\.\./' -e '/\.\./' -e '^\.\.$' -e '/\.\.$')
	[ -z "$bad" ] || die "$p: refuses a path outside the tree: $bad"
done

# __FreeBSD_version of the tree, against the running kernel when this is
# FreeBSD.  A mismatch is a warning only: a tree for another machine is
# allowed, but it is usually a mistake.
tv=$(sed -n 's/^#define[[:space:]]*__FreeBSD_version[[:space:]]*\([0-9]*\).*/\1/p' \
    "$src/sys/sys/param.h")
printf '%s: tree %s (__FreeBSD_version %s)\n' "$me" "$src" "${tv:-unknown}"
if [ "$(uname -s)" = FreeBSD ]; then
	kv=$(uname -K)
	if [ "$kv" != "$tv" ]; then
		printf '%s: WARNING: the running kernel is %s (uname -K), the tree is %s;\n' \
		    "$me" "$kv" "${tv:-unknown}" >&2
		printf '%s: WARNING: a kernel built from this tree may not match your installed modules and world.\n' \
		    "$me" >&2
	fi
fi

# patch_run FILE ARGS...: patch from the top of the tree, no backups, no
# fuzz, never interactive.  Prints patch's output; returns its status.
patch_run() {
	_f=$1
	shift
	patch -d "$src" -p1 -F 0 -f -r - -V none "$@" < "$_f" 2>&1
}

# new_files FILE: the paths FILE creates (its "--- /dev/null" entries).
new_files() {
	awk '/^--- \/dev\/null/ { n = 1; next }
	    n && /^\+\+\+ / { sub(/^\+\+\+ [ab]\//, ""); sub(/\t.*/, ""); print }
	    { n = 0 }' "$1"
}

# fresh FILE: every file FILE creates is absent from the tree.  patch(1)
# would happily apply a new-file hunk on top of an existing file (empty
# context always matches), so this is checked by hand.
fresh() {
	for _n in $(new_files "$1"); do
		[ ! -e "$src/$_n" ] || return 1
	done
	return 0
}

# First pass: dry runs only.  Decide for each patch: apply, skip (already
# there; for -R: already out), or fail.
todo=
skip=
fail=0
for p in $list; do
	f=$here/$p
	if [ "$reverse" = 0 ]; then
		fwd="-N"; back="-R"
	else
		fwd="-R"; back="-N"
	fi
	out=
	if { [ "$reverse" = 1 ] || fresh "$f"; } &&
	    out=$(patch_run "$f" $fwd --dry-run) &&
	    ! printf '%s\n' "$out" | grep -v '^|' |
	    grep -qi -e 'fuzz' -e 'failed' -e 'reversed'; then
		printf '%s: %-42s dry run ok\n' "$me" "$p"
		todo="$todo $p"
	elif { [ "$reverse" = 0 ] || fresh "$f"; } &&
	    patch_run "$f" $back --dry-run >/dev/null; then
		if [ "$reverse" = 0 ]; then
			printf '%s: %-42s already applied, skipped\n' "$me" "$p"
		else
			printf '%s: %-42s not applied, nothing to revert\n' "$me" "$p"
		fi
		skip="$skip $p"
	else
		printf '%s: %-42s DOES NOT APPLY\n' "$me" "$p" >&2
		if [ "$reverse" = 0 ] && ! fresh "$f"; then
			for n in $(new_files "$f"); do
				[ ! -e "$src/$n" ] ||
				    printf '    creates %s, which is already in the tree with other contents\n' "$n" >&2
			done
		fi
		printf '%s\n' "$out" | grep -v '^|' | grep -i -e '^Patching file' -e 'failed' -e 'fuzz' \
		    -e "can't find" -e 'No file to patch' | sed "s/^/    /" >&2
		fail=1
	fi
done

if [ "$fail" = 1 ]; then
	printf '%s: stopped before changing anything in %s.\n' "$me" "$src" >&2
	printf '%s: Check that the tree is a clean FreeBSD tree of a version listed in the series file\n' "$me" >&2
	if [ -d "$src/.git" ]; then
		printf '%s: (git -C %s status shows local changes),\n' "$me" "$src" >&2
	else
		printf '%s: (compare it with a freshly unpacked src.txz of the same version),\n' "$me" >&2
	fi
	printf '%s: then see "Troubleshooting" in %s/README.md.\n' "$me" "$here" >&2
	exit 1
fi

if [ "$dry" = 1 ]; then
	printf '%s: dry run: every patch checked, nothing changed\n' "$me"
	exit 0
fi
if [ -z "$todo" ]; then
	printf '%s: nothing to do\n' "$me"
	exit 0
fi

# Second pass: for real, in the same order.  The dry run passed, so a
# failure here means the tree changed under us; stop at once.
for p in $todo; do
	f=$here/$p
	if [ "$reverse" = 0 ]; then dir="-N"; else dir="-R"; fi
	if ! out=$(patch_run "$f" $dir); then
		printf '%s\n' "$out" >&2
		die "$p: failed after a clean dry run; the tree changed while this ran. The patches before it in this run are applied: take them out with sh $0 -R $src, then run again."
	fi
	if [ "$reverse" = 0 ]; then
		printf '%s: %-42s applied\n' "$me" "$p"
	else
		printf '%s: %-42s reverted\n' "$me" "$p"
	fi
done
printf '%s: done\n' "$me"
exit 0

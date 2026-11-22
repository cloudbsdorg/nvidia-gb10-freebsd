#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# fetch-trees.sh - fetch the two source trees the modules build against,
# when they are missing, into the work root (make install-prereqs runs it):
#
#   - the FreeBSD source tree of the running kernel, into WORK/src:
#       a RELEASE (15.1-RELEASE, 15.1-RELEASE-p2): src.txz of that release
#         from download.freebsd.org, checked against the release MANIFEST
#         (a patch level builds against its release: a module records the
#         __FreeBSD_version it was built with as the oldest kernel it loads
#         on, and patch levels keep the kernel interface);
#       a CURRENT, STABLE, BETA or RC kernel: the git commit uname -v names
#         (main-n283000-0123456789ab), from git.freebsd.org;
#       anything else (a kernel built from a local tree, whose uname -v
#         names no commit): refused, with SYSDIR= as the way out.
#   - the drm-kmod sources nvidia-drm.ko builds against, into WORK/drm-kmod:
#       the tag and commit pinned in SOURCES for the running kernel's
#       __FreeBSD_version (drm_kmod_612_* from 1500509 on, and from 1600018
#       on 16; drm_kmod_66_* from 1500031), from github.com/freebsd/drm-kmod.
#       FreeBSD's drm-kmod packages are amd64-only, so on arm64 make build
#       also builds drm.ko and dmabuf.ko from this tree.
#
# Usage: scripts/fetch-trees.sh --work WORK [--sysdir DIR] [--drmkmoddir DIR]
#   --sysdir and --drmkmoddir name the trees the build will use; a tree
#   given there that is not under WORK is only checked, never fetched.
#
# Output: one line per tree, "fetch-trees: <tree> <state> <path>", state one
# of present, fetched or refused.  Exit 0 when both trees are there, 1 when
# a fetch or check failed, 2 on a usage error.  Nothing is written outside
# WORK; /tmp is never used.

set -eu
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$script_dir/lib.sh"
sources=$script_dir/../SOURCES

die() {
	echo "fetch-trees: $*" >&2
	exit 1
}

work=
sysdir=
drmdir=
while [ $# -gt 0 ]; do
	case $1 in
	--work) work=${2:?}; shift ;;
	--sysdir) sysdir=${2:?}; shift ;;
	--drmkmoddir) drmdir=${2:?}; shift ;;
	-h|--help) sed -n '2,32p' "$0"; exit 0 ;;
	*) echo "fetch-trees: unknown argument $1" >&2; exit 2 ;;
	esac
	shift
done
case $work in
/*) ;;
*) echo "fetch-trees: --work must be an absolute path" >&2; exit 2 ;;
esac
[ -n "$sysdir" ] || sysdir=$work/src/sys
[ -n "$drmdir" ] || drmdir=$work/drm-kmod

GIT=/usr/local/bin/git
[ -x "$GIT" ] || die "git is not installed (make install-prereqs installs it)"
osreldate=$(sysctl -n kern.osreldate)
release=$(uname -r)
kident=$(uname -v | sed -n 1p)
march=$(uname -m)
parch=$(uname -p)
dist_base=https://download.freebsd.org/releases
src_git=https://git.freebsd.org/src.git
# Test hooks, honoured only with GB10_TEST_HOOKS=1 and announced on stderr:
# FT_OSRELDATE, FT_UNAME_R, FT_UNAME_V (the kernel to fetch for),
# FT_DIST_BASE, FT_SRC_GIT (where from), FT_SOURCES (another pin file).
if [ "${GB10_TEST_HOOKS:-0}" = 1 ]; then
	for _h in FT_OSRELDATE FT_UNAME_R FT_UNAME_V FT_DIST_BASE FT_SRC_GIT FT_SOURCES; do
		eval "_v=\${$_h:-}"
		[ -n "$_v" ] && echo "fetch-trees: test hook $_h in use" >&2
	done
	osreldate=${FT_OSRELDATE:-$osreldate}
	release=${FT_UNAME_R:-$release}
	kident=${FT_UNAME_V:-$kident}
	dist_base=${FT_DIST_BASE:-$dist_base}
	src_git=${FT_SRC_GIT:-$src_git}
	sources=${FT_SOURCES:-$sources}
fi

version_of() {
	tree_version "$1"
}

# the version rule shared with scripts/make.sh (scripts/lib.sh)
fits() {
	tree_fits_osrel "$1" "$osreldate"
}

# path_plain PATH: an absolute path with no . or .. component, so the
# under-WORK test below cannot be walked out of
path_plain() {
	case $1 in
	/*) ;;
	*) return 1 ;;
	esac
	case "$1/" in
	*/./*|*/../*|*//*) return 1 ;;
	esac
	return 0
}

under_work() {
	case $1 in
	"$work"/*) return 0 ;;
	esac
	return 1
}

# fresh_dir DIR: an empty directory DIR under WORK (a previous partial
# fetch is removed first); DIR must not be a symlink.
fresh_dir() {
	under_work "$1" || die "refusing to replace $1: not under $work"
	[ ! -L "$1" ] || die "refusing $1: symlink"
	rm -rf -- "$1"
	mkdir -p -- "$1"
}

for _p in "$work" "$sysdir" "$drmdir"; do
	path_plain "$_p" || { echo "fetch-trees: refusing $_p: not an absolute path without . or .. components" >&2; exit 2; }
done

# --- the FreeBSD source tree ---------------------------------------------

fetch_release_src() {
	_rel=${release%%-p[0-9]*}
	_base=$dist_base/$march/$parch/$_rel
	_dl=$work/distfiles/freebsd-$_rel-$parch
	mkdir -p -- "$_dl"
	fetch -q -o "$_dl/MANIFEST" "$_base/MANIFEST" || die "cannot fetch $_base/MANIFEST"
	_want=$(awk '$1 == "src.txz" { print $2 }' "$_dl/MANIFEST")
	case $_want in
	????????????????????????????????????????????????????????????????) ;;
	*) die "no src.txz sha256 in $_base/MANIFEST" ;;
	esac
	if [ ! -f "$_dl/src.txz" ] || [ "$(sha256 -q "$_dl/src.txz")" != "$_want" ]; then
		rm -f -- "$_dl/src.txz.part"
		fetch -o "$_dl/src.txz.part" "$_base/src.txz" || die "cannot fetch $_base/src.txz"
		[ "$(sha256 -q "$_dl/src.txz.part")" = "$_want" ] || {
			rm -f -- "$_dl/src.txz.part"
			die "src.txz sha256 does not match $_base/MANIFEST"
		}
		mv -f -- "$_dl/src.txz.part" "$_dl/src.txz"
	fi
	_top=$(dirname -- "$sysdir")
	fresh_dir "$_top"
	tar -xf "$_dl/src.txz" -C "$_top" --strip-components 2 usr/src \
	    || die "cannot extract src.txz into $_top"
}

fetch_git_src() {
	_hash=$(printf '%s\n' "$kident" | sed -n 's/.*-n[0-9][0-9]*-\([0-9a-f]\{7,40\}\).*/\1/p')
	[ -n "$_hash" ] || die "the running kernel ($kident) names no git commit: set SYSDIR= to its source tree"
	case $release in
	*-CURRENT) _branch=main ;;
	*-STABLE) _branch=stable/${release%%.*} ;;
	*-BETA*|*-RC*|*-PRERELEASE) _branch=releng/${release%%-*} ;;
	*) die "no branch known for $release" ;;
	esac
	_top=$(dirname -- "$sysdir")
	fresh_dir "$_top"
	git_safe "$GIT" -C "$_top" init -q --template= || die "git init failed in $_top"
	git_safe "$GIT" -C "$_top" remote add origin "$src_git"
	# Depth grows until the commit is in the fetched history (a kernel a
	# few weeks old is within the first fetch; blobs come on checkout).
	for _depth in 2000 8000 30000; do
		git_safe "$GIT" -C "$_top" fetch -q --depth "$_depth" --filter=blob:none origin "$_branch" \
		    || die "git fetch of $_branch failed"
		if _full=$(git_safe "$GIT" -C "$_top" rev-parse -q --verify "$_hash^{commit}" 2>/dev/null); then
			git_safe "$GIT" -C "$_top" -c advice.detachedHead=false checkout -q "$_full" \
			    || die "git checkout $_full failed"
			return 0
		fi
	done
	die "commit $_hash is not in the last 30000 commits of $_branch"
}

if [ -f "$sysdir/sys/param.h" ] && fits "$sysdir"; then
	echo "fetch-trees: src present $sysdir"
elif ! under_work "$sysdir"; then
	echo "fetch-trees: src refused $sysdir (not the running kernel's version $osreldate; not under WORK, so not fetched)"
	exit 1
else
	case $release in
	*-RELEASE|*-RELEASE-p[0-9]*) fetch_release_src ;;
	*) fetch_git_src ;;
	esac
	fits "$sysdir" || die "the fetched tree $sysdir is __FreeBSD_version $(version_of "$sysdir"), the running kernel $osreldate"
	echo "fetch-trees: src fetched $sysdir"
fi

# --- drm-kmod -------------------------------------------------------------

if [ "$osreldate" -ge 1600018 ] || { [ "$osreldate" -ge 1500509 ] && [ "$osreldate" -lt 1600000 ]; }; then
	pin=drm_kmod_612
elif [ "$osreldate" -ge 1500031 ]; then
	pin=drm_kmod_66
else
	die "no drm-kmod pin for __FreeBSD_version $osreldate (FreeBSD 15.0 or later is needed)"
fi
repo_url=$(sources_get "$sources" drm_kmod_repo) || die "SOURCES: no drm_kmod_repo"
tag=$(sources_get "$sources" "${pin}_tag") || die "SOURCES: no ${pin}_tag"
commit=$(sources_get "$sources" "${pin}_commit") || die "SOURCES: no ${pin}_commit"
case $tag in
''|*[!A-Za-z0-9._-]*) die "SOURCES: ${pin}_tag is not one word of [A-Za-z0-9._-]" ;;
esac
case $commit in
????????????????????????????????????????) ;;
*) die "SOURCES: ${pin}_commit is not 40 hex digits" ;;
esac
case $commit in
*[!0-9a-f]*) die "SOURCES: ${pin}_commit is not 40 hex digits" ;;
esac

have=
if [ -d "$drmdir/.git" ]; then
	have=$(git_safe "$GIT" -C "$drmdir" rev-parse HEAD 2>/dev/null || true)
fi
if [ -f "$drmdir/linuxkpi_version.mk" ] && { [ "$have" = "$commit" ] || ! under_work "$drmdir"; }; then
	echo "fetch-trees: drm-kmod present $drmdir"
else
	fresh_dir "$drmdir"
	rmdir -- "$drmdir"
	git_safe "$GIT" clone -q --depth 1 --branch "$tag" --template= -- "$repo_url" "$drmdir" \
	    || die "clone of $repo_url $tag failed"
	have=$(git_safe "$GIT" -C "$drmdir" rev-parse HEAD)
	[ "$have" = "$commit" ] || die "drm-kmod $tag is commit $have, SOURCES pins $commit"
	echo "fetch-trees: drm-kmod fetched $drmdir ($tag)"
fi

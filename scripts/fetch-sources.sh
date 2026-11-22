#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# Checksum-verified fetch of the two NVIDIA source sets the arm64 port is
# built from, as pinned in SOURCES at the repo root:
#   - the NVIDIA FreeBSD x86_64 driver tarball (sha256-verified)
#   - NVIDIA open-gpu-kernel-modules at a pinned tag and commit
#
# Usage: scripts/fetch-sources.sh [DESTDIR]
#   DESTDIR defaults to ${GB10_WORK:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)/work}/sources.
#   Nothing is written outside DESTDIR; /tmp is never used.
#   DESTDIR must not be a symlink, must be owned by this user and must not
#   be writable by group or other, and neither the tarball nor its .part may
#   already be a symlink.
#   Every pin read from SOURCES is format-checked before it is used (sha256
#   64 lowercase hex, commit 40 lowercase hex, tag one word of
#   [A-Za-z0-9._-], URLs https://, and the URL's last path segment a usable
#   file name - not empty, "." or "..", only [A-Za-z0-9._+-]): a SOURCES
#   mistake - this repo's threat model - fails closed instead of comparing
#   "" = "" or building a path out of a tag.
#
# Test hooks: FETCH, GIT, SHA256. They are honoured ONLY when
# GB10_TEST_HOOKS=1, and then only as a single word of [A-Za-z0-9_./-]; each
# one in use is announced on stderr. Without that variable the fixed tools
# below are used and the environment is ignored, so nobody who can set the
# environment can replace the verifier or point the pins elsewhere.

set -eu

# Base system tools only (sha256(1) lives in /sbin on FreeBSD, git(1) in
# /usr/local/bin); nothing in ~/.local/bin may shadow the tools this script
# trusts for verification, so no user dirs and no inherited PATH.
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
# LC_ALL=C pins the character ranges of the pin format checks below.
LC_ALL=C
export PATH LC_ALL

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
sources=$script_dir/../SOURCES
# fetch-sources.sh names its script directory variable script_dir; lib.sh
# is sourced from the same directory this script lives in.
. "$script_dir/lib.sh"

destdir=${1:-${GB10_WORK:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)/work}/sources}

die() {
    echo "fetch-sources: $*" >&2
    exit 1
}

# The fixed tools this script trusts. A test hook replaces one only with
# GB10_TEST_HOOKS=1 (see the header); test_hook validates and announces it.
FETCH=$(test_hook fetch-sources FETCH /usr/bin/fetch) || exit 1
GIT=$(test_hook fetch-sources GIT /usr/local/bin/git) || exit 1
# The tool and its -q flag are kept apart so the tool is always quoted.
SHA256=$(test_hook fetch-sources SHA256 /sbin/sha256) || exit 1

[ -f "$sources" ] || die "missing SOURCES file: $sources"

url=$(sources_get "$sources" nvidia_freebsd_url) || die "SOURCES: no nvidia_freebsd_url"
want_sha=$(sources_get "$sources" nvidia_freebsd_sha256) || die "SOURCES: no nvidia_freebsd_sha256"
ogkm_repo=$(sources_get "$sources" ogkm_repo) || die "SOURCES: no ogkm_repo"
ogkm_tag=$(sources_get "$sources" ogkm_tag) || die "SOURCES: no ogkm_tag"
want_commit=$(sources_get "$sources" ogkm_commit) || die "SOURCES: no ogkm_commit"

# check_hex - check_hex <value> <length>: return 0 only when <value> is
# exactly <length> lowercase hex digits. An EMPTY pin must not pass: it
# would make the cached-tarball comparison below succeed against an empty
# sha256 answer ("" = "").
# Time:  O(len) one case-pattern scan. Space: O(1).
check_hex() {
    _ch_v=$1
    _ch_n=$2
    if [ ${#_ch_v} -ne "$_ch_n" ]; then
        return 1
    fi
    case $_ch_v in
    *[!0-9a-f]*) return 1 ;;
    esac
    return 0
}

# Every pin is format-checked before anything is fetched, cloned or written
# (pass-2 u02 #5): a SOURCES mistake - this repo's threat model - fails
# closed here instead of comparing "" = "" or letting a tag with a / or ..
# steer the ogkm directory path.
check_hex "$want_sha" 64 \
    || die "SOURCES: nvidia_freebsd_sha256 is not 64 lowercase hex digits"
check_hex "$want_commit" 40 \
    || die "SOURCES: ogkm_commit is not 40 lowercase hex digits"
case $ogkm_tag in
''|*[!A-Za-z0-9._-]*)
    die "SOURCES: ogkm_tag is not one word of [A-Za-z0-9._-]: $ogkm_tag"
    ;;
esac
case $ogkm_tag in
.|..) die "SOURCES: ogkm_tag is a path dot: $ogkm_tag" ;;
esac
case $url in
https://?*) ;;
*) die "SOURCES: nvidia_freebsd_url is not an https:// URL: $url" ;;
esac
# The tarball path below is built as $destdir/${url##*/}, so the URL's last
# path segment must be a usable file name (pass-3 u02 #4): with a basename
# of "..", the .part path becomes $destdir/...part and the final
# `mv -- part "$destdir/.."` puts the download into DESTDIR's PARENT,
# contradicting the header's "nothing is written outside DESTDIR". One
# case refuses an empty basename (a URL ending in /), the path dots "." and
# "..", and any character outside [A-Za-z0-9._+-] (LC_ALL=C is exported
# above, so the ranges are ASCII); a '/' cannot survive ${url##*/} but is
# outside the charset anyway.
case ${url##*/} in
''|.|..|*[!A-Za-z0-9._+-]*)
    die "SOURCES: nvidia_freebsd_url has no usable file name: $url"
    ;;
esac
case $ogkm_repo in
https://?*) ;;
*) die "SOURCES: ogkm_repo is not an https:// URL: $ogkm_repo" ;;
esac

# A symlink at DESTDIR would answer the owner/mode check below from the
# LINK ITSELF (stat(1) uses lstat unless -L: the link's own 0755 mode and
# this user's uid always pass) while every write goes through it to the
# target, so it is refused before the stat (pass-2 u04 #2).
if [ -L "$destdir" ]; then
    die "refusing DESTDIR $destdir: symlink"
fi
mkdir -p -- "$destdir"
[ -d "$destdir" ] || die "refusing DESTDIR $destdir: not a directory"
# DESTDIR must be this user's own directory and must not be writable by group
# or other: anything else lets a second account plant or swap the tarball this
# script verifies and a later build runs on. stat(1) prints the owner uid and
# the mode in octal without a leading zero.
dst_stat=$(stat -f '%u %Lp' -- "$destdir" 2>/dev/null) \
    || die "refusing DESTDIR $destdir: cannot stat it"
dst_uid=${dst_stat%% *}
dst_perm=${dst_stat##* }
if [ "$dst_uid" != "$(id -u)" ]; then
    die "refusing DESTDIR $destdir: owned by uid $dst_uid, not $(id -u)"
fi
# 0$dst_perm makes the shell read the mode as octal; 0022 masks group-write
# and other-write.
if [ $((0$dst_perm & 0022)) -ne 0 ]; then
    die "refusing DESTDIR $destdir: mode $dst_perm is writable by group or other"
fi

# --- NVIDIA FreeBSD driver tarball ---------------------------------------
tarball=$destdir/${url##*/}
part=$tarball.part

# A symlink at either path would send the download, the rename or the
# checksum read somewhere else entirely, so both are refused up front.
if [ -L "$tarball" ]; then
    die "refusing $tarball: symlink"
fi
if [ -L "$part" ]; then
    die "refusing $part: symlink"
fi

if [ -f "$tarball" ] && [ "$("$SHA256" -q -- "$tarball")" = "$want_sha" ]; then
    echo "ok (cached): ${url##*/}"
else
    if ! "$FETCH" -o "$part" "$url"; then
        rm -f -- "$part"
        die "download failed: $url"
    fi
    got=$("$SHA256" -q -- "$part")
    if [ "$got" != "$want_sha" ]; then
        rm -f -- "$part"
        echo "sha256 mismatch: expected $want_sha got $got" >&2
        exit 1
    fi
    mv -- "$part" "$tarball"
    echo "fetched: ${url##*/}"
fi

# --- open-gpu-kernel-modules ----------------------------------------------
# Every git(1) run below goes through lib.sh's git_safe: EVERY inherited
# GIT_* variable is removed (the env -u list is derived from `env` itself,
# never a fixed denylist), so no inherited environment can steer the clone,
# the rev-parse or the clean-tree check to a different repository than the
# checkout being verified. `--template=` keeps clone from consulting any
# template directory, and `--` ends the option list so a repo or directory
# value beginning with '-' can never be read as an option (pass-2 u02 #5).
ogkm_dir=$destdir/open-gpu-kernel-modules-$ogkm_tag

if [ ! -d "$ogkm_dir" ]; then
    git_safe "$GIT" clone --depth 1 --branch "$ogkm_tag" --template= -- \
        "$ogkm_repo" "$ogkm_dir" \
        || die "clone failed: $ogkm_repo tag $ogkm_tag"
fi
got_commit=$(git_safe "$GIT" -C "$ogkm_dir" rev-parse HEAD) \
    || die "rev-parse failed in $ogkm_dir"
if [ "$got_commit" != "$want_commit" ]; then
    echo "commit mismatch: expected $want_commit got $got_commit ($ogkm_dir left for inspection)" >&2
    exit 1
fi
# The pinned commit alone is not evidence: the tracked tree must also match
# HEAD, or what gets built is not the pin.
git_tree_is_clean fetch-sources "$GIT" "$ogkm_dir" || exit 1
echo "ok: open-gpu-kernel-modules-$ogkm_tag at $got_commit"

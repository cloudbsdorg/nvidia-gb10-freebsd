#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# fetch-trees_test.sh - scripts/fetch-trees.sh offline, with its test hooks
# (GB10_TEST_HOOKS=1) pointing at local file:// sources:
#   (a) a CURRENT kernel whose uname -v names no commit: refused, exit 1,
#       the message names SYSDIR=, nothing fetched
#   (b) a RELEASE-p2 kernel: src.txz of the release, checked against its
#       MANIFEST, extracted to WORK/src; drm-kmod cloned at the pinned tag and
#       commit; exit 0; a second run says present for both
#   (c) a src.txz whose sha256 differs from the MANIFEST: refused, exit 1
#   (d) a drm-kmod tag at another commit than the pin: refused, exit 1
#   (e) a tree newer than the running kernel: refused
#   (f) a CURRENT kernel naming a commit: the commit is fetched from git
#   (g) a kernel too old for any drm-kmod pin: refused
# Scratch lives under WORK/tmp (never /tmp).

set -u
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
export PATH
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
base=${GB10_WORK:-$repo/work}
mkdir -p -- "$base/tmp"
S=$(mktemp -d "$base/tmp/fetch-trees.XXXXXX") || exit 1
trap 'rm -rf -- "$S"' EXIT
fail=0
ok() { printf 'ok    %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1"; fail=$((fail + 1)); }
G="git -c user.name=t -c user.email=t@t -c init.defaultBranch=main"
# snap_commit DIR MSG: commit the whole of DIR on main with plumbing
# (write-tree and commit-tree), the way a scratch fixture repository is
# built without the porcelain commit
snap_commit() {
	(cd "$1" && $G add -A . && _t=$($G write-tree) && { _p=$($G rev-parse -q --verify HEAD 2>/dev/null) || _p=; } \
	    && _c=$(printf '%s\n' "$2" | $G commit-tree "$_t" ${_p:+-p "$_p"}) && $G update-ref refs/heads/main "$_c")
}
FT=$repo/scripts/fetch-trees.sh
# ft VAR=VALUE... sh "$FT" ARGS: run fetch-trees.sh with the test hooks on
ft() { env GB10_TEST_HOOKS=1 "$@"; }

# a release "distribution": usr/src with param.h and include/
mkdir -p "$S/rel/usr/src/sys/sys" "$S/rel/usr/src/include"
printf '#define __FreeBSD_version 1501000\n' > "$S/rel/usr/src/sys/sys/param.h"
D=$S/dist/arm64/aarch64/15.1-RELEASE
mkdir -p "$D"
tar -cJf "$D/src.txz" -C "$S/rel" usr
printf 'src.txz\t%s\t10\tsrc\t"System source tree"\toff\n' "$(sha256 -q "$D/src.txz")" > "$D/MANIFEST"

# a drm-kmod repository with the pinned tag, and a pin file
mkdir -p "$S/drm"
(cd "$S/drm" && $G init -q && printf 'X=1\n' > linuxkpi_version.mk) || exit 1
snap_commit "$S/drm" one || exit 1
git -C "$S/drm" tag drm_v6.12.110_1 main || exit 1
c612=$(git -C "$S/drm" rev-parse HEAD)
mkpins() {
	printf '%s\n' "drm_kmod_repo file://$S/drm" "drm_kmod_612_tag drm_v6.12.110_1" "drm_kmod_612_commit $1" \
	    "drm_kmod_66_tag drm_v6.12.110_1" "drm_kmod_66_commit $1"
}
mkpins "$c612" > "$S/pins"

hooks_rel="FT_OSRELDATE=1501000 FT_UNAME_R=15.1-RELEASE-p2 FT_DIST_BASE=file://$S/dist FT_SOURCES=$S/pins"

# (a)
W=$S/wa
ft FT_OSRELDATE=1600031 FT_UNAME_R=16.0-CURRENT "FT_UNAME_V=FreeBSD 16.0-CURRENT #2: Fri Nov 13 user@host:/obj/GENERIC" \
    FT_SOURCES="$S/pins" sh "$FT" --work "$W" > "$S/a.out" 2>&1
rc=$?
[ "$rc" = 1 ] && grep -q 'names no git commit: set SYSDIR=' "$S/a.out" && [ ! -e "$W/src/sys/sys/param.h" ] \
    && ok "a kernel naming no commit is refused" || bad "(a) rc $rc: $(tail -n 1 "$S/a.out")"

# (b)
W=$S/wb
# shellcheck disable=SC2086
ft $hooks_rel sh "$FT" --work "$W" > "$S/b.out" 2>&1
rc=$?
if [ "$rc" = 0 ] && grep -q '^fetch-trees: src fetched ' "$S/b.out" && grep -q '^fetch-trees: drm-kmod fetched ' "$S/b.out" \
    && [ -f "$W/src/sys/sys/param.h" ] && [ -d "$W/src/include" ] && [ "$(git -C "$W/drm-kmod" rev-parse HEAD)" = "$c612" ]; then
	ok "a RELEASE patch level gets its release src.txz and the pinned drm-kmod"
else
	bad "(b) rc $rc: $(tail -n 3 "$S/b.out")"
fi
# shellcheck disable=SC2086
ft $hooks_rel sh "$FT" --work "$W" > "$S/b2.out" 2>&1
grep -q '^fetch-trees: src present ' "$S/b2.out" && grep -q '^fetch-trees: drm-kmod present ' "$S/b2.out" \
    && ok "a second run finds both present" || bad "(b2) $(tail -n 2 "$S/b2.out")"

# (c) a corrupt src.txz
cp "$D/MANIFEST" "$S/MANIFEST.good"
printf 'src.txz\t%s\t10\tsrc\t"x"\toff\n' "0000000000000000000000000000000000000000000000000000000000000000" > "$D/MANIFEST"
W=$S/wc
# shellcheck disable=SC2086
ft $hooks_rel sh "$FT" --work "$W" > "$S/c.out" 2>&1
rc=$?
[ "$rc" = 1 ] && grep -q 'sha256 does not match' "$S/c.out" && [ ! -e "$W/src/sys" ] \
    && ok "a src.txz that does not match the MANIFEST is refused" || bad "(c) rc $rc: $(tail -n 1 "$S/c.out")"
cp "$S/MANIFEST.good" "$D/MANIFEST"

# (d) the tag moved to another commit
mkpins 0123456789abcdef0123456789abcdef01234567 > "$S/pins-bad"
W=$S/wd
ft FT_OSRELDATE=1501000 FT_UNAME_R=15.1-RELEASE "FT_DIST_BASE=file://$S/dist" FT_SOURCES="$S/pins-bad" sh "$FT" --work "$W" > "$S/d.out" 2>&1
rc=$?
[ "$rc" = 1 ] && grep -q 'SOURCES pins 0123456789abcdef' "$S/d.out" \
    && ok "a drm-kmod tag at another commit is refused" || bad "(d) rc $rc: $(tail -n 1 "$S/d.out")"

# (e) a given tree newer than the kernel, outside WORK: refused, not fetched
mkdir -p "$S/newer/sys/sys"
printf '#define __FreeBSD_version 1501500\n' > "$S/newer/sys/sys/param.h"
W=$S/we
# shellcheck disable=SC2086
ft $hooks_rel sh "$FT" --work "$W" --sysdir "$S/newer/sys" > "$S/e.out" 2>&1
rc=$?
[ "$rc" = 1 ] && grep -q 'src refused' "$S/e.out" && ok "a tree newer than the kernel is refused" || bad "(e) rc $rc: $(tail -n 1 "$S/e.out")"

# (f) a CURRENT kernel naming a commit: fetched from a local src repository
mkdir -p "$S/srcgit/sys/sys" "$S/srcgit/include"
printf '#define __FreeBSD_version 1600031\n' > "$S/srcgit/sys/sys/param.h"
touch "$S/srcgit/include/.keep"
$G -C "$S/srcgit" init -q || exit 1
snap_commit "$S/srcgit" k || exit 1
printf 'x\n' > "$S/srcgit/later"
snap_commit "$S/srcgit" later || exit 1
kc=$(git -C "$S/srcgit" rev-parse --short=12 HEAD~1)
W=$S/wf
ft FT_OSRELDATE=1600031 FT_UNAME_R=16.0-CURRENT "FT_UNAME_V=FreeBSD 16.0-CURRENT main-n291235-$kc GENERIC" \
    "FT_SRC_GIT=file://$S/srcgit" FT_SOURCES="$S/pins" sh "$FT" --work "$W" > "$S/f.out" 2>&1
rc=$?
if [ "$rc" = 0 ] && [ "$(git -C "$W/src" rev-parse --short=12 HEAD)" = "$kc" ] && [ ! -e "$W/src/later" ]; then
	ok "a CURRENT kernel gets the exact commit its uname -v names"
else
	bad "(f) rc $rc: $(tail -n 3 "$S/f.out")"
fi

# (g) too old for any drm-kmod pin
mkdir -p "$S/old/usr/src/sys/sys" "$S/old/usr/src/include"
printf '#define __FreeBSD_version 1403000\n' > "$S/old/usr/src/sys/sys/param.h"
D2=$S/dist/arm64/aarch64/14.3-RELEASE
mkdir -p "$D2"
tar -cJf "$D2/src.txz" -C "$S/old" usr
printf 'src.txz\t%s\t10\tsrc\t"x"\toff\n' "$(sha256 -q "$D2/src.txz")" > "$D2/MANIFEST"
W=$S/wg
ft FT_OSRELDATE=1403000 FT_UNAME_R=14.3-RELEASE "FT_DIST_BASE=file://$S/dist" FT_SOURCES="$S/pins" sh "$FT" --work "$W" > "$S/g.out" 2>&1
rc=$?
[ "$rc" = 1 ] && grep -q 'no drm-kmod pin' "$S/g.out" && ok "a kernel too old for drm-kmod is refused" || bad "(g) rc $rc: $(tail -n 1 "$S/g.out")"

if [ "$fail" = 0 ]; then
	echo "fetch-trees_test: PASS"
	exit 0
fi
echo "fetch-trees_test: $fail FAILED"
exit 1

#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# kernel_patches_test.sh - checks for kernel-patches/: the series, the
# README, the manual page and apply.sh.
#
# Usage: sh tests/kernel_patches_test.sh [SRCDIR]
#   SRCDIR (or KERNEL_PATCHES_SRC in the environment): a FreeBSD source
#   tree; every patch in the series must pass apply.sh -n against it.
#   Without one that check is skipped (make test runs without a tree).
#
# Always checked:
#   (a) the series names at least one patch, every name is a file in
#       kernel-patches/, and every *.diff there is in the series;
#   (b) README.md names every patch in the series;
#   (c) every sysctl or tunable a patch adds (SYSCTL_INT/ULONG lines with a
#       parent and a name) is named in README.md and in kernel-patches.7;
#   (d) every path a patch names is relative with no "..";
#   (e) no two patches touch the same file, so each applies on its own;
#   (f) mandoc -T lint passes on kernel-patches.7 (when mandoc exists);
#   (g) apply.sh on a scratch tree with its own series: a dry run changes
#       nothing; apply, a second apply (skips), revert (back to the
#       original bytes); a patch with a bad hunk stops the whole run with
#       status 1 before any file changes, and leaves no .rej or .orig;
#       a new-file patch over an existing file is refused; a path outside
#       the tree is refused; the failure hint names git only for a git tree;
#   (h) README.md runs no git clean or checkout . on an unguarded $SRC;
#   (i) 0002 and 0003 both have the Ampere/Altra strncmp predicate;
#   (j) 0001 uses VM_MEMATTR_UNCACHEABLE at all three arm64 write-combining
#       sites;
#   (k) 0001 adds no pgprot_noncached definition, and 0003 diagnoses a build
#       without DEV_ACPI;
#   (l) README.md step 9 selects the stock kernel with -x kernel;
#   (m) README.md does not tie Mode `2` to corruption without SIGBUS in the
#       same paragraph.
#
# Scratch files go under an mktemp(1) directory in
# ${GB10_WORK:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)/work}/tmp, removed on exit; never /tmp.

set -u
LC_ALL=C
export LC_ALL

repo=$(cd -- "$(dirname -- "$0")/.." && pwd) || exit 1
kp=$repo/kernel-patches
fails=0
ok() { printf 'ok    %s\n' "$*"; }
bad() { printf 'FAIL  %s\n' "$*"; fails=$((fails + 1)); }

list=$(sed -e 's/#.*//' -e 's/[[:space:]]*$//' -e '/^$/d' "$kp/series")

# (a)
if [ -n "$list" ]; then ok "series lists $(printf '%s\n' "$list" | wc -l | tr -d ' ') patches"
else bad "series lists no patches"; fi
for p in $list; do
	[ -f "$kp/$p" ] || bad "series names $p, which is missing"
done
for f in "$kp"/*.diff; do
	[ -e "$f" ] || continue
	b=$(basename "$f")
	printf '%s\n' "$list" | grep -qxF -- "$b" || bad "$b is not in the series"
done

# (b)
for p in $list; do
	if grep -qF -- "$p" "$kp/README.md"; then ok "README names $p"
	else bad "README does not name $p"; fi
done

# (c) SYSCTL_<type>(_parent_path, OID_AUTO, name, ...) -> parent.path.name
names=$(for p in $list; do
	sed -n 's/^+SYSCTL_[A-Z]*(_\([a-z0-9_]*\), *OID_AUTO, *\([a-z0-9_]*\),.*/\1 \2/p' "$kp/$p"
done | while read -r parent leaf; do
	printf '%s.%s\n' "$(printf '%s' "$parent" | tr _ .)" "$leaf"
done)
[ -n "$names" ] || bad "found no sysctls in the patches (the parser is broken)"
for n in $names; do
	grep -qF -- "$n" "$kp/README.md" && ok "README documents $n" ||
	    bad "README does not document $n"
	grep -qF -- "$(printf '%s' "$n" | sed 's/_/\\_/g')" "$kp/kernel-patches.7" ||
	    grep -qF -- "$n" "$kp/kernel-patches.7" ||
	    bad "kernel-patches.7 does not document $n"
done

# (d) and (e)
seen=
for p in $list; do
	paths=$(sed -n -e 's/^--- \([^	]*\).*/\1/p' -e 's/^+++ \([^	]*\).*/\1/p' "$kp/$p" |
	    grep -v '^/dev/null$' | sed 's|^[ab]/||' | sort -u)
	[ -n "$paths" ] || bad "$p names no files"
	for f in $paths; do
		case $f in
		/*|..|../*|*/../*|*/..) bad "$p names $f, outside the tree" ;;
		esac
		case " $seen " in
		*" $f "*) bad "$f is touched by two patches (the second is $p)" ;;
		esac
		seen="$seen $f"
	done
done
ok "patch paths checked"

# (f)
if command -v mandoc >/dev/null 2>&1; then
	if out=$(mandoc -T lint -W warning "$kp/kernel-patches.7" 2>&1) && [ -z "$out" ]; then
		ok "mandoc -T lint kernel-patches.7"
	else
		bad "mandoc -T lint kernel-patches.7: $out"
	fi
else
	printf 'skip  mandoc not installed\n'
fi

# (g) apply.sh against a scratch tree and a scratch series.
base=${GB10_WORK:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)/work}/tmp
mkdir -p -- "$base" || exit 1
t=$(mktemp -d "$base/kernel_patches_test.XXXXXX") || exit 1
trap 'rm -rf -- "$t"' EXIT
mkdir -p "$t/kp" "$t/src/sys/conf" "$t/src/sys/sys" "$t/src/sys/dev"
cp -- "$kp/apply.sh" "$t/kp/apply.sh"
: > "$t/src/sys/conf/newvers.sh"
printf '#define __FreeBSD_version 1600000\n' > "$t/src/sys/sys/param.h"
printf 'one\ntwo\nthree\nfour\n' > "$t/src/sys/dev/a.c"
cat > "$t/kp/01-good.diff" <<'EOF'
Subject: a header line that says failed and fuzz, which apply.sh must ignore

--- a/sys/dev/a.c
+++ b/sys/dev/a.c
@@ -1,4 +1,4 @@
 one
-two
+TWO
 three
 four
--- /dev/null
+++ b/sys/dev/new.c
@@ -0,0 +1,1 @@
+new
EOF
cat > "$t/kp/02-bad.diff" <<'EOF'
--- a/sys/dev/a.c
+++ b/sys/dev/a.c
@@ -2,3 +2,3 @@
 TWO
-not-there
+x
 four
EOF
printf '01-good.diff\n' > "$t/kp/series"
orig=$(cat "$t/src/sys/dev/a.c")
snap() { (cd "$t/src" && find . -type f | sort | xargs cat | cksum); }
s0=$(snap)

sh "$t/kp/apply.sh" -n "$t/src" > "$t/out" 2>&1; rc=$?
[ "$rc" = 0 ] && [ "$(snap)" = "$s0" ] && ok "apply.sh -n changes nothing" ||
    bad "apply.sh -n: rc $rc or the tree changed: $(cat "$t/out")"

sh "$t/kp/apply.sh" "$t/src" > "$t/out" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -qx TWO "$t/src/sys/dev/a.c" && [ -f "$t/src/sys/dev/new.c" ] &&
    ok "apply.sh applies" || bad "apply.sh apply: rc $rc: $(cat "$t/out")"
s1=$(snap)

sh "$t/kp/apply.sh" "$t/src" > "$t/out" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q 'already applied' "$t/out" && [ "$(snap)" = "$s1" ] &&
    ok "apply.sh twice skips" || bad "apply.sh second run: rc $rc: $(cat "$t/out")"

sh "$t/kp/apply.sh" -R "$t/src" > "$t/out" 2>&1; rc=$?
[ "$rc" = 0 ] && [ "$(cat "$t/src/sys/dev/a.c")" = "$orig" ] && [ ! -e "$t/src/sys/dev/new.c" ] &&
    ok "apply.sh -R reverts" || bad "apply.sh -R: rc $rc: $(cat "$t/out")"

# The good patch first, then the bad one: nothing may change at all.
printf '01-good.diff\n02-bad.diff\n' > "$t/kp/series"
s0=$(snap)
sh "$t/kp/apply.sh" "$t/src" > "$t/out" 2>&1; rc=$?
[ "$rc" = 1 ] && grep -q '02-bad.diff.*DOES NOT APPLY' "$t/out" && [ "$(snap)" = "$s0" ] &&
    ok "apply.sh stops on a reject before changing anything" ||
    bad "apply.sh with a reject: rc $rc: $(cat "$t/out")"
left=$(find "$t/src" -name '*.rej' -o -name '*.orig')
[ -z "$left" ] && ok "no .rej or .orig files" || bad "left behind: $left"
sed -n '/^patch_run()/,/^}/p' "$t/kp/apply.sh" | grep -qF -- '-r -' &&
    ok "patch_run sends rejects to its output with -r -" ||
    bad "patch_run does not pass -r - to patch"

printf '01-good.diff\n' > "$t/kp/series"
printf 'other\n' > "$t/src/sys/dev/new.c"
sh "$t/kp/apply.sh" "$t/src" > "$t/out" 2>&1; rc=$?
[ "$rc" = 1 ] && grep -q 'already in the tree' "$t/out" && grep -qx two "$t/src/sys/dev/a.c" &&
    [ "$(cat "$t/src/sys/dev/new.c")" = other ] &&
    ok "apply.sh refuses a new file over an existing one" ||
    bad "apply.sh new file over existing: rc $rc: $(cat "$t/out")"
rm -f -- "$t/src/sys/dev/new.c"

sh "$t/kp/apply.sh" "$t/src" 03-missing.diff > "$t/out" 2>&1; rc=$?
[ "$rc" = 1 ] && ok "apply.sh refuses a patch not in the series" ||
    bad "apply.sh unknown patch: rc $rc"

# A patch that names a path outside the tree is refused before anything runs.
mkdir -p "$t/outside"
printf 'keep\n' > "$t/outside/escape"
cat > "$t/kp/04-escape.diff" <<'EOF'
--- a/../outside/escape
+++ b/../outside/escape
@@ -1 +1 @@
-keep
+changed
EOF
printf '04-escape.diff\n' > "$t/kp/series"
s0=$(snap)
sh "$t/kp/apply.sh" "$t/src" > "$t/out" 2>&1; rc=$?
[ "$rc" = 1 ] && grep -q 'refuses a path outside the tree' "$t/out" && [ "$(snap)" = "$s0" ] &&
    [ "$(cat "$t/outside/escape")" = keep ] &&
    ok "apply.sh refuses a path outside the tree" ||
    bad "apply.sh path escape: rc $rc: $(cat "$t/out")"

# The failure hint names git only for a git tree (the scratch tree has no .git).
printf '02-bad.diff\n' > "$t/kp/series"
sh "$t/kp/apply.sh" "$t/src" > "$t/out" 2>&1
if grep -q 'git -C' "$t/out"; then bad "apply.sh suggests git for a tree without .git"
else ok "apply.sh gives the src.txz hint for a tree without .git"; fi
mkdir "$t/src/.git"
sh "$t/kp/apply.sh" "$t/src" > "$t/out" 2>&1
grep -q 'git -C' "$t/out" && ok "apply.sh gives the git hint for a git tree" ||
    bad "apply.sh gives no git hint for a git tree: $(cat "$t/out")"
rmdir "$t/src/.git"

# README: every command that throws local changes away is guarded against an
# unset SRC (git -C "" runs in the current directory).
if grep -nE 'git -C "\$SRC" (clean|checkout \.)' "$kp/README.md" > "$t/out"; then
	bad "README runs git clean or checkout . on an unguarded \$SRC: $(cat "$t/out")"
else
	ok "README guards git clean and checkout . with \${SRC:?}"
fi

# (i) The same Altra predicate is compiled into both patches.
for p in 0002-linuxkpi-altra-erratum-82288.diff 0003-arm64-kernel-alignment-fixup.diff; do
	if grep -qF -- 'strncmp(hdr->OemId, "Ampere", 6) == 0 &&' "$kp/$p" &&
	    grep -qF -- 'strncmp(hdr->OemTableId, "Altra", 5) == 0' "$kp/$p"; then
		ok "$p has the Ampere/Altra strncmp predicate"
	else
		bad "$p lacks the Ampere/Altra strncmp predicate"
	fi
done

# (j) Count the added uses, and check each site so another use cannot hide drift.
p=$kp/0001-linuxkpi-arm64-write-combining.diff
wc=$(grep -c '^+.*VM_MEMATTR_UNCACHEABLE' "$p" | tr -d ' ')
if [ "$wc" -ge 3 ] &&
    grep -q '^+.*mapping->attr = VM_MEMATTR_UNCACHEABLE' "$p" &&
    sed -n '/^+#define[[:space:]]ioremap_wc/,/^+#elif/p' "$p" |
	grep -q '^+.*_ioremap_attr.*VM_MEMATTR_UNCACHEABLE' &&
    sed -n '/^+#define[[:space:]]pgprot_writecombine/,/^+#else/p' "$p" |
	grep -q 'cachemode2protval(VM_MEMATTR_UNCACHEABLE)'; then
	ok "0001 maps all three arm64 write-combining sites with VM_MEMATTR_UNCACHEABLE"
else
	bad "0001 arm64 write-combining check: $wc added VM_MEMATTR_UNCACHEABLE lines or a site drifted"
fi

# (k) Device on managed RAM would also change its DMAP alias; warn when ACPI
# detection was not built into the alignment fixup.
if grep '^+#define[[:space:]]*pgprot_noncached' "$p"; then
	bad "0001 adds a pgprot_noncached definition"
else
	ok "0001 adds no pgprot_noncached definition"
fi
p=$kp/0003-arm64-kernel-alignment-fixup.diff
if grep -qF 'built without DEV_ACPI' "$p"; then
	ok "0003 contains the built without DEV_ACPI diagnostic"
else
	bad "0003 lacks the built without DEV_ACPI diagnostic"
fi

# (l) An update starts by selecting the stock kernel.
if sed -n '/^### 9\./,/^## /p' "$kp/README.md" | grep -qF -- '-x kernel'; then
	ok "README step 9 selects the stock kernel"
else
	bad "README step 9 lacks -x kernel"
fi

# (m) Mode 2 is a test, not a corruption fix; the SIGBUS warning must be near it.
awk 'BEGIN { RS = ""; ORS = "\n\n" }
    /Mode `2`/ && /corruption/ && !/SIGBUS/ { print }' "$kp/README.md" > "$t/mode2"
if [ -s "$t/mode2" ]; then
	bad "README ties Mode \`2\` to corruption without SIGBUS: $(grep -nE 'Mode `2`|corruption' "$t/mode2")"
else
	ok "README ties Mode \`2\` to corruption only with a SIGBUS warning"
fi

# Optional: the real series against a real tree.
tree=${1:-${KERNEL_PATCHES_SRC:-}}
if [ -n "$tree" ]; then
	if sh "$kp/apply.sh" -n "$tree" > "$t/out" 2>&1; then
		ok "every patch passes apply.sh -n on $tree"
	else
		bad "apply.sh -n $tree: $(cat "$t/out")"
	fi
else
	printf 'skip  no source tree given (sh %s SRCDIR, or KERNEL_PATCHES_SRC=)\n' "$0"
fi

printf 'kernel_patches_test: %s failed\n' "$fails"
[ "$fails" = 0 ]

#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# kit_work_guard_test.sh - the work-root guard of the test-boot kits.
#
# The kits build boot environments with bectl, so they run as root.  The default
# work root is the checkout's work directory, which belongs to the developer
# account that cloned the repository: root must not write into it silently.
# The rule is one file, tests/native-tools-testboot/guard.sh, that every kit
# sources by path and calls; the kit checks the guard before it sources it, and
# computes and checks the root of its checkout instead of assuming it from the
# depth of its own directory.
#
# This test is safe.  It never builds a boot environment, never calls the real
# bectl, never arms a boot and never reboots: it sources the guard (which only
# defines functions), and it runs the kits only where they refuse before they
# touch anything (the bectl of the host is replaced by a sentinel that only
# logs, and the only writable place a kit is given is a scratch of this test).
#
#   (a) guard_work_default 0 without GB10_WORK: refuses (rc 2), says how to fix it
#   (b) guard_work_default 0 with GB10_WORK:    accepts (rc 0)
#   (c) guard_work_default 1001 without GB10_WORK: accepts (rc 0)
#   (d) guard_work_root: the checkout's work directory when GB10_WORK is unset,
#       whatever HOME says; the canonical GB10_WORK otherwise (symbolic links
#       resolved); a GB10_WORK that is relative, in no plain form, "/" or holds a
#       newline is refused; root with a GB10_WORK inside the checkout is refused;
#       no GB10_WORK and no checkout is refused and says what to set
#   (e) guard_repo_root accepts only a git work tree whose top level is the
#       candidate and whose tests directory holds the kit: an empty ".git"
#       file, a nested fake inside the real checkout, a kit outside tests/ are
#       refused; guard_archive_root accepts an extracted archive (no ".git")
#       and refuses a tree with one; guard_trusted_file refuses a symbolic
#       link, a missing file and a file writable by others
#   (f) every kit script computes its directory and the root with a checked cd in
#       canonical form, checks the root with guard_repo_root, and refuses an
#       explicitly empty path option
#   (g) every kit RUNS the shared guard, and runs it before it takes the work
#       root: the kit runs in a synthetic checkout whose guard is the real one
#       with a shim that writes down every call and its answer
#   (h) a kit whose shared guard is missing refuses, names the file and says
#       how to restore it; so does one whose guard does not parse or fails
#   (i) a GB10_WORK that is not an absolute path is refused (and -h still prints
#       the usage); an absolute one is accepted (the guard answered it)
#   (j) a relative path option that names a place the kit writes or reads is
#       refused before anything is written
#   (k) the guard is checked before it is sourced: a guard writable by others,
#       a guard that is a symbolic link and a guard that differs from the
#       committed one are refused, and nothing in them runs
#   (l) a directory with a fake ".git" is no checkout; a kit under an unrelated
#       repository does not take that repository's commit
#   (m) the native-tools kit runs from an extracted archive under its documented
#       hooks, and from nowhere else
#   (n) this test writes nothing into the checkout's work root: its scratch
#       comes from TMPDIR, outside the checkout; a TMPDIR inside the checkout is
#       refused before the scratch is made; a run with no TMPDIR reaches the
#       assertions (not as root: that is reported as a skip, never a pass)
#   (o) a kit that was extracted on its own lies in no checkout: it refuses
#       before it writes anything, and it names the work root it needs
#
# A check that cannot run (it needs root, or must not run as root) is printed as
# SKIP with the reason, never as ok.  Run: sh tests/kit_work_guard_test.sh

set -u

PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P) || exit 2
[ -n "$repo" ] || { echo "kit_work_guard_test.sh: the repository root could not be found" >&2; exit 2; }
ME=$(id -u) || exit 2
# The scratch of this test: it is created under TMPDIR, never under the
# checkout's work root (that directory belongs to the developer account, and a
# root run would leave root-owned files in it).  A root run without TMPDIR
# would write into the checkout: it is refused.  A run that is not root falls
# back to the system temporary directory, so the test is usable without any
# setup.
base=${TMPDIR:-}
if [ -z "$base" ]; then
	if [ "$ME" = 0 ]; then
		echo "kit_work_guard_test.sh: set TMPDIR (a root run must not write into the checkout)" >&2
		exit 2
	fi
	base=/tmp
fi
# The scratch root is checked and canonicalized: a TMPDIR that lies inside the
# checkout would put the scratch in the developer's work root, which is the
# write this test says it never does.  The refusal comes before mktemp, so
# nothing is created there.
case $base in
"$repo" | "$repo"/*)
	echo "kit_work_guard_test.sh: the scratch root $base is inside the checkout: the scratch would be written into the checkout; set TMPDIR to a directory outside it" >&2
	exit 2 ;;
esac
basec=$(CDPATH= cd -- "$base" 2> /dev/null && pwd -P) || {
	echo "kit_work_guard_test.sh: the scratch root $base cannot be used" >&2
	exit 2
}
case $basec in
"$repo" | "$repo"/*)
	echo "kit_work_guard_test.sh: the scratch root $basec is inside the checkout: the scratch would be written into the checkout; set TMPDIR to a directory outside it" >&2
	exit 2 ;;
esac
S=$(mktemp -d "$basec/kit-work-guard.XXXXXX") || exit 1
trap 'chmod -R u+w "$S" 2>/dev/null; rm -rf -- "$S"' EXIT
fail=0
skipped=0
ok() { printf 'ok    %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1"; fail=$((fail + 1)); }
skip() { printf 'SKIP  %s\n' "$1"; skipped=$((skipped + 1)); }
# scratch NAME: a fresh directory under the scratch of this run (every scratch of
# this test lies under $S, so the trap removes it all)
scratch() { mktemp -d "$S/$1.XXXXXX"; }

# The guard is one file for every kit (the kits source it by path).  It only
# defines functions: sourcing it runs nothing.
GUARD=$repo/tests/native-tools-testboot/guard.sh
if [ ! -r "$GUARD" ]; then
	bad "the work-root guard is missing: ${GUARD#$repo/}"
	echo "kit_work_guard_test: $fail FAILED"
	exit 1
fi
. "$GUARD"
ok "the work-root guard is readable: ${GUARD#$repo/}"

# (a) root without an explicit work root refuses.
( unset GB10_WORK; guard_work_default 0 make-be.sh "-m DIR and -o DIR" ) > "$S/root.out" 2>&1
rc=$?
if [ "$rc" = 2 ] && grep -q 'set GB10_WORK=/absolute/path or pass -m DIR and -o DIR' "$S/root.out"; then
	ok "root without GB10_WORK refuses the defaulted work paths, and says what to set or pass"
else
	bad "root without GB10_WORK returned $rc, want 2 with the remedy: $(cat "$S/root.out")"
fi

# (b) root with an explicit work root is accepted.
( GB10_WORK="$S/work"; guard_work_default 0 make-be.sh "-m DIR and -o DIR" ) > "$S/root-ok.out" 2>&1
rc=$?
if [ "$rc" = 0 ]; then
	ok "root with an explicit GB10_WORK is accepted"
else
	bad "root with an explicit GB10_WORK returned $rc, want 0: $(cat "$S/root-ok.out")"
fi

# (c) a caller that is not root keeps the default of the checkout.
( unset GB10_WORK; guard_work_default 1001 make-be.sh "-m DIR and -o DIR" ) > "$S/user.out" 2>&1
rc=$?
if [ "$rc" = 0 ]; then
	ok "a caller that is not root keeps the checkout default"
else
	bad "a caller that is not root returned $rc, want 0: $(cat "$S/user.out")"
fi

# (d) the work root.  The helper is the one every kit calls.
tmprepo=$(scratch repo) || exit 1
w=$(HOME=/some/other/home GB10_WORK= guard_work_root 1001 "$tmprepo" "$tmprepo/tests/k" 2>&1)
if [ "$w" = "$tmprepo/work" ]; then
	ok "the work root of a kit without GB10_WORK is the checkout's work directory"
else
	bad "the work root of a kit without GB10_WORK is '$w', want '$tmprepo/work'"
fi
w=$(HOME=/some/other/home GB10_WORK="$tmprepo/other" guard_work_root 1001 "$tmprepo" "$tmprepo/tests/k" 2>&1)
if [ "$w" = "$tmprepo/other" ]; then
	ok "the work root of a kit with GB10_WORK is the given one"
else
	bad "the work root of a kit with GB10_WORK is '$w', want '$tmprepo/other'"
fi
# the canonical spelling: a symbolic link in the part that exists is resolved,
# the part that does not exist yet is kept
mkdir -p "$S/real-work" && ln -s "$S/real-work" "$S/link-work"
w=$(GB10_WORK="$S/link-work/deeper/new" guard_work_root 1001 "$tmprepo" "$tmprepo/tests/k" 2>&1)
if [ "$w" = "$S/real-work/deeper/new" ]; then
	ok "the work root is canonical: a symbolic link in GB10_WORK is resolved"
else
	bad "the work root through a symbolic link is '$w', want '$S/real-work/deeper/new'"
fi
for bad_w in work ./work "$S/a//b" "$S/a/../b" "$S/a/" / "$S/a/./b"; do
	if ( GB10_WORK="$bad_w" guard_work_root 1001 "$tmprepo" "$tmprepo/tests/k" ) > "$S/bad-w.out" 2>&1; then
		bad "a GB10_WORK of '$bad_w' is accepted: $(cat "$S/bad-w.out")"
	elif grep -q 'GB10_WORK must' "$S/bad-w.out"; then
		ok "a GB10_WORK of '$bad_w' is refused, and the refusal names GB10_WORK and what it must be"
	else
		bad "a GB10_WORK of '$bad_w' is refused without naming it: $(cat "$S/bad-w.out")"
	fi
done
nl_w="$S/a
b"
if ( GB10_WORK="$nl_w" guard_work_root 1001 "$tmprepo" "$tmprepo/tests/k" ) > "$S/bad-w.out" 2>&1; then
	bad "a GB10_WORK with a newline is accepted: $(cat "$S/bad-w.out")"
else
	ok "a GB10_WORK with a newline is refused"
fi
# root may not name a work root inside the checkout, whichever spelling names it
ln -s "$tmprepo" "$S/link-repo"
if ( GB10_WORK="$S/link-repo/work" guard_work_root 0 "$tmprepo" "$tmprepo/tests/k" ) > "$S/inside.out" 2>&1; then
	bad "root with a GB10_WORK inside the checkout (through a link) is accepted: $(cat "$S/inside.out")"
elif grep -q 'inside the checkout' "$S/inside.out"; then
	ok "root with a GB10_WORK inside the checkout is refused, whatever spelling names it"
else
	bad "root with a GB10_WORK inside the checkout is refused without the reason: $(cat "$S/inside.out")"
fi
if w=$(GB10_WORK="$S/link-repo/work" guard_work_root 1001 "$tmprepo" "$tmprepo/tests/k" 2>&1) && [ "$w" = "$tmprepo/work" ]; then
	ok "a caller that is not root may name a work root inside the checkout"
else
	bad "a caller that is not root with a GB10_WORK inside the checkout: $w"
fi
# Without a repository root there is no work root to take from a checkout: the
# helper refuses instead of naming an unrelated directory (a kit that was
# extracted on its own would otherwise write into "/work"), and it says what to set.
if ( unset GB10_WORK; guard_work_root 1001 "" "$S/some/kit" ) > "$S/no-repo.out" 2>&1; then
	bad "the work root helper answered without a repository root: $(cat "$S/no-repo.out")"
elif grep -q 'lies in no checkout' "$S/no-repo.out" && grep -q 'set GB10_WORK=/absolute/path' "$S/no-repo.out" && grep -q "$S/some/kit" "$S/no-repo.out"; then
	ok "the work root helper refuses to answer without a repository root, names the kit and says what to set"
else
	bad "the refusal without a repository root does not say what to set: $(cat "$S/no-repo.out")"
fi

# (e) the checks of a checkout, an archive and a trusted file.
if guard_repo_root "$repo" "$repo/tests/native-tools-testboot"; then
	ok "the repository root of the checkout is recognized"
else
	bad "the repository root of the checkout is not recognized"
fi
if guard_repo_root "$tmprepo" "$tmprepo/tests/linux-bridge-testboot"; then
	bad "a directory that is not a checkout is taken for a repository root: $tmprepo"
else
	ok "a directory that is not a checkout is refused as a repository root"
fi
# an empty file called .git is not a checkout: git is asked, the entry is not believed
fakegit=$(scratch fakegit) || exit 1
mkdir -p "$fakegit/tests/k" && : > "$fakegit/.git"
if guard_repo_root "$fakegit" "$fakegit/tests/k"; then
	bad "a directory with an empty .git file is taken for a repository root"
else
	ok "a directory with an empty .git file is refused as a repository root"
fi
# kwg_commit DIR: make DIR a git repository with everything in it committed
# (plumbing only: no hook runs, no identity of the account is needed)
kwg_commit() {
	git -C "$1" init -q 2> /dev/null || return 1
	git -C "$1" add -A 2> /dev/null || return 1
	_kt=$(git -C "$1" write-tree 2> /dev/null) || return 1
	_kc=$(GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.org GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.org \
	    git -C "$1" commit-tree "$_kt" -m kit 2> /dev/null) || return 1
	git -C "$1" update-ref HEAD "$_kc" 2> /dev/null || return 1
	return 0
}
realgit=$(scratch realgit) || exit 1
mkdir -p "$realgit/tests/k" && : > "$realgit/tests/k/f" && kwg_commit "$realgit" || { bad "a scratch repository could not be made"; }
if guard_repo_root "$realgit" "$realgit/tests/k"; then
	ok "a git work tree whose tests directory holds the kit is recognized"
else
	bad "a git work tree whose tests directory holds the kit is not recognized"
fi
# a nested directory with a fake .git inside a real repository: its top level is
# the real repository, not the nested directory
mkdir -p "$realgit/nested/tests/k" && : > "$realgit/nested/.git"
if guard_repo_root "$realgit/nested" "$realgit/nested/tests/k"; then
	bad "a nested directory with a fake .git inside a repository is taken for a repository root"
else
	ok "a nested directory with a fake .git inside a repository is refused as a repository root"
fi
if guard_repo_root "$repo" "$repo/lib/libnvrm"; then
	bad "a kit that lies in no tests directory is taken for a repository root"
else
	ok "a kit that lies in no tests directory is refused as a repository root"
fi
if guard_repo_root "" ""; then
	bad "an empty directory is taken for a repository root"
else
	ok "an empty directory is refused as a repository root"
fi
arch=$(scratch arch) || exit 1
mkdir -p "$arch/tests/k"
if guard_archive_root "$arch" "$arch/tests/k"; then
	ok "an extracted archive (tests directory, no .git) is recognized as an archive root"
else
	bad "an extracted archive is not recognized as an archive root"
fi
if guard_archive_root "$realgit" "$realgit/tests/k"; then
	bad "a tree with git metadata is taken for an archive root"
else
	ok "a tree with git metadata is not an archive root"
fi
if guard_archive_root "$arch" "$arch/elsewhere/k"; then
	bad "a kit outside the tests directory is taken for an archive kit"
else
	ok "a kit outside the tests directory of an archive is refused"
fi
cp "$GUARD" "$S/g-ww" && chmod 666 "$S/g-ww"
if guard_trusted_file "$ME" "$S/g-ww" 2> "$S/tf.out"; then
	bad "a file writable by everyone is trusted"
elif grep -q 'writable by the group or by everyone' "$S/tf.out"; then
	ok "a file writable by everyone is not trusted, and the reason is said"
else
	bad "a file writable by everyone is refused without the reason: $(cat "$S/tf.out")"
fi
ln -s "$GUARD" "$S/g-link"
if guard_trusted_file "$ME" "$S/g-link" 2> "$S/tf.out"; then
	bad "a symbolic link is trusted"
elif grep -q 'symbolic link' "$S/tf.out"; then
	ok "a symbolic link is not trusted, and the reason is said"
else
	bad "a symbolic link is refused without the reason: $(cat "$S/tf.out")"
fi
if guard_trusted_file "$ME" "$S/g-none" 2> "$S/tf.out"; then
	bad "a missing file is trusted"
else
	ok "a missing file is not trusted"
fi
if guard_trusted_file "$ME" "$GUARD" 2> "$S/tf.out"; then
	ok "the guard of the checkout is trusted (a regular file of this account, not writable by others)"
else
	bad "the guard of the checkout is not trusted: $(cat "$S/tf.out")"
fi

# (f) the kit scripts.  What the source must hold: a checked cd in canonical
# form for the kit directory and the root, the check of the checkout, and an
# empty path option refused.  What the kit must DO is checked below by running
# it, not by reading it.
KITS="tests/native-tools-testboot/make-be.sh
tests/native-tools-testboot/check-be.sh
tests/linux-bridge-testboot/make-be.sh
tests/prime-import-testboot/make-be.sh"
CHECKED_KITDIR='KITDIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P) || exit 2'
CHECKED_ROOT='ROOT=$(CDPATH= cd -- "$KITDIR/../.." && pwd -P) || exit 2'
for k in $KITS; do
	f=$repo/$k
	if [ ! -r "$f" ]; then
		bad "the kit script is missing: $k"
		continue
	fi
	if awk -v pat="$CHECKED_ROOT" 'index($0, pat) == 1 { found = 1 } END { exit found ? 0 : 1 }' "$f"; then
		ok "$k computes the root of its tree with a checked cd, in canonical form"
	else
		bad "$k does not compute the root with a checked cd: $CHECKED_ROOT"
	fi
	if awk -v pat="$CHECKED_KITDIR" 'index($0, pat) == 1 { found = 1 } END { exit found ? 0 : 1 }' "$f"; then
		ok "$k computes its kit directory with a checked cd, in canonical form"
	else
		bad "$k does not compute its kit directory with a checked cd: $CHECKED_KITDIR"
	fi
	if grep -q 'guard_repo_root' "$f"; then
		ok "$k checks that the computed directory is the root of a checkout"
	else
		bad "$k does not check the repository root (the depth of the kit directory says nothing)"
	fi
	case $k in
	*native-tools-testboot/make-be.sh) opts="-m -s -o" ;;
	*native-tools-testboot/check-be.sh) opts="-s" ;;
	*linux-bridge-testboot/make-be.sh) opts="-t" ;;
	*prime-import-testboot/make-be.sh) opts="-m" ;;
	*) opts="" ;;
	esac
	for o in $opts; do
		oline=$(grep -nE "^[[:space:]]*${o}\)" "$f" | head -1 | cut -d: -f1)
		if [ -z "$oline" ]; then
			bad "$k has no $o option"
			continue
		fi
		obody=$(sed -n "${oline}p" "$f")
		case $obody in
		*'-n "$2"'*) ok "$k refuses an empty $o" ;;
		*) bad "$k does not refuse an empty $o: $obody" ;;
		esac
	done
done

# (g) and on: the kits are run, not read.  The harness is a synthetic checkout
# (a real git repository, everything committed) that holds the kit and the
# guard.  The guard of the harness is the REAL guard with a shim: the four
# functions a kit decides with are renamed and wrapped by functions of the same
# name that write down the call and its answer, then hand back exactly what the
# real function said.  The policy is not copied into the test: a kit that
# passes here passes with the real rule.
#
# The bectl of the host is replaced by a sentinel that only logs: a kit that
# got that far would be seen, and nothing would be built.
SENT=$(scratch sentinel) || exit 1
cat > "$SENT/bectl" <<'EOF'
#!/bin/sh
echo "bectl $*" >> "$GB10_KWG_SENTINEL_LOG"
exit 1
EOF
chmod 755 "$SENT/bectl"
: > "$SENT/log"
TRACED=$S/traced-guard.sh
sed -e 's/^guard_work_default()$/_kwg_real_guard_work_default()/' \
    -e 's/^guard_work_root()$/_kwg_real_guard_work_root()/' \
    -e 's/^guard_repo_root()$/_kwg_real_guard_repo_root()/' \
    -e 's/^guard_archive_root()$/_kwg_real_guard_archive_root()/' "$GUARD" > "$TRACED"
if cmp -s "$GUARD" "$TRACED"; then
	bad "the traced guard is the guard itself: the functions to trace were not found (stale test)"
fi
cat >> "$TRACED" <<'SHIMEOF'
_kwg_log=${GB10_KWG_GUARD_LOG:-/dev/null}
guard_work_default() {
	_kwg_rc=0
	_kwg_real_guard_work_default "$@" || _kwg_rc=$?
	printf 'guard_work_default rc=%s\n' "$_kwg_rc" >> "$_kwg_log"
	return $_kwg_rc
}
guard_work_root() {
	_kwg_rc=0
	_kwg_out=$(_kwg_real_guard_work_root "$@") || _kwg_rc=$?
	printf 'guard_work_root rc=%s out=%s\n' "$_kwg_rc" "$_kwg_out" >> "$_kwg_log"
	[ -z "$_kwg_out" ] || printf '%s\n' "$_kwg_out"
	return $_kwg_rc
}
guard_repo_root() {
	_kwg_rc=0
	_kwg_real_guard_repo_root "$@" || _kwg_rc=$?
	printf 'guard_repo_root rc=%s\n' "$_kwg_rc" >> "$_kwg_log"
	return $_kwg_rc
}
guard_archive_root() {
	_kwg_rc=0
	_kwg_real_guard_archive_root "$@" || _kwg_rc=$?
	printf 'guard_archive_root rc=%s\n' "$_kwg_rc" >> "$_kwg_log"
	return $_kwg_rc
}
SHIMEOF
if sh -n "$TRACED" 2> /dev/null; then
	ok "the traced guard of the harness parses (the real guard with a shim)"
else
	bad "the traced guard of the harness does not parse"
fi

# kwg_canon PATH: one spelling of a path: the directory part is resolved with
# realpath(1) and the last component is kept as it is written, so a path that
# does not exist yet names the same place as its absolute spelling.
kwg_canon() {
	_kc_d=$(dirname -- "$1")
	_kc_b=$(basename -- "$1")
	_kc_r=$(realpath -- "$_kc_d" 2> /dev/null) || return 1
	case $_kc_r in
	/) printf '/%s\n' "$_kc_b" ;;
	*) printf '%s/%s\n' "$_kc_r" "$_kc_b" ;;
	esac
}
# kwg_has_entry DIR NAME: the directory holds an entry of that name (compared in
# the spelling kwg_canon gives, so a relative path the kit used and the absolute
# one the test knows name the same place).  Returns 2 when DIR cannot be read:
# "could not look" is not "found nothing".
kwg_has_entry() {
	[ -d "$1" ] && [ -r "$1" ] && [ -x "$1" ] || return 2
	_kh_want=$(kwg_canon "$1/$2") || return 2
	for _kh_e in "$1"/* "$1"/.[!.]*; do
		[ -e "$_kh_e" ] || [ -L "$_kh_e" ] || continue
		_kh_c=$(kwg_canon "$_kh_e") || continue
		[ "$_kh_c" = "$_kh_want" ] && return 0
	done
	return 1
}

# harness <kit directory> <kit file> <guard mode> <GB10_WORK> <cwd> [<override kit file>] [<arguments>]:
# build a synthetic checkout that holds the kit and a guard, commit it, run the
# kit in it, and leave what happened in the files of $S: h.rc (the exit
# status), h.out (the output), h.log (what the guard recorded), h.sent (what
# the kit asked of the bectl) and h.co (the checkout it ran in).  The guard
# modes: real (the guard as it is), traced (the real guard with the shim), none
# (no guard), ww (a guard writable by everyone that would mark a file when it
# runs), link (the guard is a symbolic link to such a file), dirty (the guard
# differs from the committed one and would mark a file), fails (a guard that
# returns a failure when it is read), noparse (a guard that does not parse).
# The marker file is $S/sourced: a guard that ran would create it.
harness() {
	_hk=$1; _hf=$2; _hg=$3; _hw=$4; _hcwd=$5; _hover=${6:-}; _hargs=${7:--b somebase}
	_hco=$(scratch harness) || return 1
	( cd "$repo" && tar -cf - "$_hk" tests/native-tools-testboot/guard.sh tests/libnvrm/board-amp001.env rc.d/nvidia_linux 2> /dev/null ) |
		tar -xf - -C "$_hco" 2> /dev/null || return 1
	_hgp=$_hco/tests/native-tools-testboot/guard.sh
	rm -f "$S/sourced"
	case $_hg in
	traced) cp "$TRACED" "$_hgp" ;;
	none) rm -f "$_hgp" ;;
	ww)
		{ cat "$GUARD"; printf '\n: > "$GB10_KWG_SOURCED"\n'; } > "$_hgp" ;;
	link)
		{ cat "$GUARD"; printf '\n: > "$GB10_KWG_SOURCED"\n'; } > "$_hco/planted.sh"
		rm -f "$_hgp" && ln -s "$_hco/planted.sh" "$_hgp" ;;
	fails)
		{ cat "$GUARD"; printf '\nfalse\n'; } > "$_hgp" ;;
	noparse)
		{ cat "$GUARD"; printf '\nif then\n'; } > "$_hgp" ;;
	esac
	[ -z "$_hover" ] || cp "$_hover" "$_hco/$_hk/$_hf"
	kwg_commit "$_hco" || return 1
	case $_hg in
	ww) chmod 666 "$_hgp" ;;
	dirty) printf '\n: > "$GB10_KWG_SOURCED"\n' >> "$_hgp" ;;
	esac
	: > "$S/h.log"
	: > "$S/h.sent"
	( cd "$_hcwd" && GB10_WORK="$_hw" GB10_KWG_GUARD_LOG="$S/h.log" GB10_KWG_SOURCED="$S/sourced" \
		GB10_KWG_SENTINEL_LOG="$S/h.sent" BECTL="$SENT/bectl" NVNT_BECTL="$SENT/bectl" TMPDIR="$S" \
		GB10_TEST_HOOKS=1 sh "$_hco/$_hk/$_hf" $_hargs ) > "$S/h.out" 2>&1
	printf '%s\n' "$?" > "$S/h.rc"
	printf '%s\n' "$_hco" > "$S/h.co"
	return 0
}

# kit_args <kit>: the arguments the kit needs to get as far as the work-root
# rule: the check script takes a mount point, the other three a base BE.
mkdir -p "$S/mnt"
kit_args() {
	case $1 in
	*native-tools-testboot/check-be.sh) printf '%s\n' "-m $S/mnt" ;;
	*) printf '%s\n' "-b somebase" ;;
	esac
}

# (g) the guard runs, in order, and the work root comes from the shared helper.
# The record is what the real guard saw and answered, not what the source of
# the kit says.
for k in $KITS; do
	kd=${k%/*}
	kf=${k##*/}
	KARGS=$(kit_args "$k")
	_cwd=$(scratch cwd) || exit 1
	rm -rf "${S:?}/work-abs"
	if ! harness "$kd" "$kf" traced "$S/work-abs" "$_cwd" "" "$KARGS"; then
		bad "the harness of $k could not be made"
		continue
	fi
	_log=$(cat "$S/h.log")
	if printf '%s\n' "$_log" | grep -q '^guard_repo_root rc=0$'; then
		ok "$k asks the shared guard whether its root is a checkout (the guard recorded the call and said yes)"
	else
		bad "$k did not ask the shared guard about its root: the guard recorded [$(printf '%s' "$_log" | tr '\n' ' ')]"
	fi
	if printf '%s\n' "$_log" | grep -q '^guard_work_default rc=0$'; then
		ok "$k runs the shared guard (the guard recorded the call)"
	else
		bad "$k did not run the shared guard: the guard recorded [$(printf '%s' "$_log" | tr '\n' ' ')]"
	fi
	if printf '%s\n' "$_log" | grep -q "^guard_work_root rc=0 out=$S/work-abs\$"; then
		ok "$k takes its work root from the shared helper (the helper answered the absolute GB10_WORK)"
	else
		bad "$k did not take its work root from the shared helper: the guard recorded [$(printf '%s' "$_log" | tr '\n' ' ')]"
	fi
	_d=$(printf '%s\n' "$_log" | grep -n '^guard_work_default' | head -1 | cut -d: -f1)
	_r=$(printf '%s\n' "$_log" | grep -n '^guard_work_root' | head -1 | cut -d: -f1)
	if [ -n "$_d" ] && [ -n "$_r" ] && [ "$_d" -lt "$_r" ]; then
		ok "$k runs the guard before it takes the work root"
	else
		bad "$k takes the work root before it runs the guard: the guard recorded [$(printf '%s' "$_log" | tr '\n' ' ')]"
	fi
	if [ -e "$S/work-abs" ]; then
		bad "$k wrote into the work root before it refused: $(ls -d "$S/work-abs" 2> /dev/null)"
	else
		ok "$k wrote nothing into the work root"
	fi
done

# The control of the harness: a kit whose guard call sits behind a branch that
# is never taken looks the same to a source check, and the harness must see
# that the guard did not run.
_ctl=$(scratch control) || exit 1
awk '
{
	if ($0 ~ /guard_work_default/ && $0 !~ /^[[:space:]]*#/) {
		print "\tif false; then guard_work_default \"$ME\" make-be.sh \"\" || exit $?; fi"
		next
	}
	print
}' "$repo/tests/linux-bridge-testboot/make-be.sh" > "$_ctl/make-be.sh"
if cmp -s "$repo/tests/linux-bridge-testboot/make-be.sh" "$_ctl/make-be.sh"; then
	bad "the control of the harness changed nothing (stale test)"
else
	_cwd=$(scratch cwd) || exit 1
	if harness tests/linux-bridge-testboot make-be.sh traced "$S/work-abs" "$_cwd" "$_ctl/make-be.sh"; then
		_log=$(cat "$S/h.log")
		if printf '%s\n' "$_log" | grep -q '^guard_work_default'; then
			bad "the harness does not see a kit that does not run the guard"
		else
			ok "the harness sees a kit whose guard call is behind a branch that is never taken"
		fi
	else
		bad "the harness of the control could not be made"
	fi
fi

# (h) the shared guard is not optional: a kit that cannot find it refuses, names
# the file and says how to restore it; a guard that fails when it is read, or
# that does not parse, is refused the same way.
for k in $KITS; do
	kd=${k%/*}
	kf=${k##*/}
	KARGS=$(kit_args "$k")
	for mode in none fails noparse; do
		_cwd=$(scratch cwd) || exit 1
		rm -rf "${S:?}/work-abs"
		if ! harness "$kd" "$kf" "$mode" "$S/work-abs" "$_cwd" "" "$KARGS"; then
			bad "the harness of $k ($mode) could not be made"
			continue
		fi
		rc=$(cat "$S/h.rc")
		out=$(cat "$S/h.out")
		if [ "$rc" = 2 ] && printf '%s\n' "$out" | grep -q 'guard\.sh' && printf '%s\n' "$out" | grep -q 'copy tests/native-tools-testboot/guard.sh'; then
			ok "$k refuses a guard that is $mode (rc 2), names the file and says to copy the committed one"
		else
			bad "$k with a guard that is $mode: rc=$rc out=[$(printf '%s' "$out" | tr '\n' ' ')]"
		fi
		if [ -e "$S/work-abs" ]; then
			bad "$k wrote into the work root although the guard was $mode"
		elif [ -s "$S/h.sent" ]; then
			bad "$k called bectl although the guard was $mode: $(cat "$S/h.sent")"
		else
			ok "$k writes nothing and calls nothing when the guard is $mode"
		fi
	done
done

# (i) GB10_WORK must be an absolute path: a relative one names a different
# directory in every directory the kit is started in.  The usage is printed
# whatever GB10_WORK says: the options are read first.
for k in $KITS; do
	kd=${k%/*}
	kf=${k##*/}
	KARGS=$(kit_args "$k")
	_cwd=$(scratch cwd) || exit 1
	if ! harness "$kd" "$kf" real work "$_cwd" "" "$KARGS"; then
		bad "the harness of $k could not be made"
		continue
	fi
	rc=$(cat "$S/h.rc")
	out=$(cat "$S/h.out")
	if [ "$rc" = 2 ] && printf '%s\n' "$out" | grep -q 'GB10_WORK must be an absolute path: work'; then
		ok "$k refuses a GB10_WORK that is not an absolute path, with the guard's own words"
	else
		bad "$k with a relative GB10_WORK: rc=$rc out=[$(printf '%s' "$out" | tr '\n' ' ')]"
	fi
	kwg_has_entry "$_cwd" work
	case $? in
	0) bad "$k wrote into a relative work root: $_cwd/work" ;;
	1) ok "$k writes nothing into a relative work root" ;;
	*) bad "the directory the kit was started in cannot be read: $_cwd" ;;
	esac
	# -h prints the usage before any check: a relative GB10_WORK does not hide it
	_cwd=$(scratch cwd) || exit 1
	if harness "$kd" "$kf" real work "$_cwd" "" "-h"; then
		rc=$(cat "$S/h.rc")
		out=$(cat "$S/h.out")
		if printf '%s\n' "$out" | grep -q '^Usage:' && ! printf '%s\n' "$out" | grep -q 'GB10_WORK must be an absolute path' && { [ "$rc" = 0 ] || [ "$rc" = 2 ]; }; then
			ok "$k -h prints the usage whatever GB10_WORK says"
		else
			bad "$k -h with a relative GB10_WORK: rc=$rc out=[$(printf '%s' "$out" | head -3 | tr '\n' ' ')]"
		fi
	else
		bad "the harness of $k -h could not be made"
	fi
	# an absolute work root is accepted: the real guard, traced, answered it
	# with rc 0 (the kit went past the work-root rule; what stops it later is
	# the synthetic checkout, not the guard)
	_cwd=$(scratch cwd) || exit 1
	if harness "$kd" "$kf" traced "$S/work-abs" "$_cwd" "" "$KARGS"; then
		out=$(cat "$S/h.out")
		if grep -q "^guard_work_root rc=0 out=$S/work-abs\$" "$S/h.log" && ! printf '%s\n' "$out" | grep -q 'absolute path'; then
			ok "$k accepts an absolute GB10_WORK (the guard answered it)"
		else
			bad "$k with an absolute GB10_WORK: log=[$(tr '\n' ' ' < "$S/h.log")] out=[$(printf '%s' "$out" | tr '\n' ' ')]"
		fi
	else
		bad "the harness of $k could not be made"
	fi
done

# The control of the comparison: a work root in the directory the kit was
# started in is seen, whatever spelling the test knows it by.  A comparison
# that finds nothing would pass every kit; one that cannot look says so.
_cwd=$(scratch cwd) || exit 1
: > "$_cwd/work"
kwg_has_entry "$_cwd" work
case $? in
0) ok "the comparison of the work root sees the work root of the directory the kit was started in" ;;
*) bad "the comparison of the work root sees nothing: it would pass every kit" ;;
esac
kwg_has_entry "$S/no-such-dir" work
case $? in
2) ok "the comparison of the work root reports a directory it cannot read, instead of finding nothing" ;;
*) bad "the comparison of the work root read a directory that does not exist" ;;
esac

# (j) a relative path option is refused before anything is written: the kit
# would otherwise read or write relative to the directory it was started in.
for k in $KITS; do
	kd=${k%/*}
	kf=${k##*/}
	case $k in
	*native-tools-testboot/make-be.sh) relopt="-m stage -o $S/co"; relname=stage; what="-m" ;;
	*native-tools-testboot/check-be.sh) relopt="-m $S/mnt -s rel.txt"; relname=rel.txt; what="-s" ;;
	*linux-bridge-testboot/make-be.sh) relopt="-b somebase -t build"; relname=build; what="-t" ;;
	*prime-import-testboot/make-be.sh) relopt="-b somebase -m mods"; relname=mods; what="-m" ;;
	esac
	_cwd=$(scratch cwd) || exit 1
	if ! harness "$kd" "$kf" real "$S/work-abs" "$_cwd" "" "$relopt"; then
		bad "the harness of $k could not be made"
		continue
	fi
	rc=$(cat "$S/h.rc")
	out=$(cat "$S/h.out")
	if [ "$rc" = 2 ] && printf '%s\n' "$out" | grep -q -- "$what must be an absolute path: $relname"; then
		ok "$k refuses a relative $what, and says it must be absolute"
	else
		bad "$k with a relative $what: rc=$rc out=[$(printf '%s' "$out" | tr '\n' ' ')]"
	fi
	kwg_has_entry "$_cwd" "$relname"
	case $? in
	0) bad "$k created the relative path $relname in the directory it was started in" ;;
	1) ok "$k created nothing at the relative path" ;;
	*) bad "the directory the kit was started in cannot be read: $_cwd" ;;
	esac
done

# (k) the guard is checked before it is sourced: a guard that is writable by
# others, a guard that is a symbolic link and a guard that differs from the
# committed one are refused, and nothing in them runs (the planted line would
# create $S/sourced).
for k in $KITS; do
	kd=${k%/*}
	kf=${k##*/}
	KARGS=$(kit_args "$k")
	for mode in ww link dirty; do
		case $mode in
		ww) want='writable by the group or by everyone' ;;
		link) want='symbolic link' ;;
		dirty) want='differs from the one committed' ;;
		esac
		_cwd=$(scratch cwd) || exit 1
		if ! harness "$kd" "$kf" "$mode" "$S/work-abs" "$_cwd" "" "$KARGS"; then
			bad "the harness of $k ($mode) could not be made"
			continue
		fi
		rc=$(cat "$S/h.rc")
		out=$(cat "$S/h.out")
		if [ "$rc" = 2 ] && printf '%s\n' "$out" | grep -q "$want" && printf '%s\n' "$out" | grep -q 'guard\.sh'; then
			ok "$k refuses a guard that is $mode before it sources it, and says why"
		else
			bad "$k with a guard that is $mode: rc=$rc out=[$(printf '%s' "$out" | tr '\n' ' ')]"
		fi
		if [ -e "$S/sourced" ]; then
			bad "$k ran a guard that is $mode (the planted line left its mark)"
		else
			ok "$k did not run the guard that is $mode"
		fi
	done
done
skip "a guard owned by another account is refused: making a file of another account needs root, and this test does not run as root"

# (l) a fake checkout and an unrelated repository.
for k in $KITS; do
	kd=${k%/*}
	kf=${k##*/}
	KARGS=$(kit_args "$k")
	_hco=$(scratch fake) || exit 1
	( cd "$repo" && tar -cf - "$kd" tests/native-tools-testboot/guard.sh tests/libnvrm/board-amp001.env 2> /dev/null ) |
		tar -xf - -C "$_hco" 2> /dev/null || { bad "the fake checkout of $k could not be made"; continue; }
	: > "$_hco/.git"
	( unset GB10_WORK; GB10_KWG_SENTINEL_LOG="$SENT/log" BECTL="$SENT/bectl" NVNT_BECTL="$SENT/bectl" TMPDIR="$S" GB10_TEST_HOOKS=1 \
		sh "$_hco/$kd/$kf" $KARGS ) > "$S/fake.out" 2>&1
	rc=$?
	# the .git entry is not believed: git is asked for the top level, before the guard is sourced
	if [ "$rc" = 2 ] && grep -q 'is not the root of a checkout' "$S/fake.out" && [ ! -e "$_hco/work" ]; then
		ok "$k does not take a directory with an empty .git file for a checkout"
	else
		bad "$k in a directory with an empty .git file: rc=$rc out=[$(tr '\n' ' ' < "$S/fake.out")]"
	fi
done
# a checkout reached through a symbolic link is still the checkout: the kit
# directory and the root are both canonical, so the kit gets past the checkout
# check (the traced guard says the root is one) instead of comparing a logical
# path with a physical one
_cwd=$(scratch cwd) || exit 1
if harness tests/linux-bridge-testboot make-be.sh traced "$S/work-abs" "$_cwd" "" "-b somebase"; then
	_hco=$(cat "$S/h.co")
	ln -s "$_hco" "$S/link-co"
	: > "$S/h.log"
	( cd "$_cwd" && GB10_WORK="$S/work-abs" GB10_KWG_GUARD_LOG="$S/h.log" GB10_KWG_SENTINEL_LOG="$S/h.sent" BECTL="$SENT/bectl" TMPDIR="$S" \
		sh "$S/link-co/tests/linux-bridge-testboot/make-be.sh" -b somebase ) > "$S/link.out" 2>&1
	if grep -q '^guard_repo_root rc=0$' "$S/h.log" && ! grep -q 'not the root of a checkout\|lies in no checkout' "$S/link.out"; then
		ok "a checkout reached through a symbolic link is recognized (the kit directory and the root are canonical)"
	else
		bad "a checkout reached through a symbolic link: log=[$(tr '\n' ' ' < "$S/h.log")] out=[$(tr '\n' ' ' < "$S/link.out")]"
	fi
	rm -f "$S/link-co"
else
	bad "the harness of the symbolic-link case could not be made"
fi
# a kit copied under an unrelated repository, outside its tests directory layout:
# the kit lies in no checkout, and git is not asked (an upward search would find
# the unrelated repository and take its commit for the kit's)
unrel=$(scratch unrel) || exit 1
mkdir -p "$unrel/tests/x/y" "$unrel/tests/x/native-tools-testboot" && : > "$unrel/junk"
cp "$repo"/tests/linux-bridge-testboot/* "$unrel/tests/x/y/"
cp "$GUARD" "$unrel/tests/x/native-tools-testboot/guard.sh"
if kwg_commit "$unrel"; then
	uhead=$(git -C "$unrel" rev-parse HEAD)
	( GB10_WORK="$S/unrel-work" GB10_KWG_SENTINEL_LOG="$SENT/log" BECTL="$SENT/bectl" TMPDIR="$S" \
		sh "$unrel/tests/x/y/make-be.sh" -b somebase -V "$uhead" ) > "$S/unrel.out" 2>&1
	rc=$?
	if [ "$rc" = 2 ] && grep -q 'lies in no checkout' "$S/unrel.out" && grep -q 'cannot be checked' "$S/unrel.out" && [ ! -e "$S/unrel-work" ]; then
		ok "the linux-bridge kit under an unrelated repository refuses: the unrelated commit is not taken for the kit's"
	else
		bad "the linux-bridge kit under an unrelated repository: rc=$rc out=[$(tr '\n' ' ' < "$S/unrel.out")]"
	fi
else
	bad "the unrelated repository could not be made"
fi

# (m) the native-tools kit runs from an extracted archive of the repository
# under its documented hooks (GB10_TEST_HOOKS=1 NVNT_NO_GIT_CHECK=1, not root),
# with GB10_WORK (an archive has no work directory to take a default from), and
# from nowhere else.  The kit gets past the checkout check and reaches the
# sentinel bectl, which only logs.
if [ "$ME" = 0 ]; then
	skip "the native-tools kit from an extracted archive is not run as root: its hooks are for non-root runs only, and a root kit builds a boot environment"
else
	archroot=$(scratch archroot) || exit 1
	( cd "$repo" && tar -cf - tests/native-tools-testboot tests/libnvrm/board-amp001.env 2> /dev/null ) | tar -xf - -C "$archroot" 2> /dev/null
	: > "$SENT/log"
	( GB10_TEST_HOOKS=1 NVNT_NO_GIT_CHECK=1 NVNT_BECTL="$SENT/bectl" GB10_KWG_SENTINEL_LOG="$SENT/log" GB10_WORK="$S/arch-work" TMPDIR="$S" \
		sh "$archroot/tests/native-tools-testboot/make-be.sh" -b somebase ) > "$S/arch.out" 2>&1
	rc=$?
	if ! grep -q 'not the root of a checkout' "$S/arch.out" && grep -q 'bectl list' "$SENT/log"; then
		ok "the native-tools make-be.sh runs from an extracted archive under its hooks (it reached the bectl sentinel)"
	else
		bad "the native-tools make-be.sh from an archive: rc=$rc sentinel=[$(tr '\n' ' ' < "$SENT/log")] out=[$(tr '\n' ' ' < "$S/arch.out")]"
	fi
	( unset GB10_WORK; GB10_TEST_HOOKS=1 NVNT_NO_GIT_CHECK=1 NVNT_BECTL="$SENT/bectl" GB10_KWG_SENTINEL_LOG="$SENT/log" TMPDIR="$S" \
		sh "$archroot/tests/native-tools-testboot/make-be.sh" -b somebase ) > "$S/arch2.out" 2>&1
	rc=$?
	if [ "$rc" = 2 ] && grep -q 'lies in no checkout' "$S/arch2.out" && [ ! -e "$archroot/work" ]; then
		ok "the native-tools make-be.sh from an archive without GB10_WORK refuses: an archive has no default work root"
	else
		bad "the native-tools make-be.sh from an archive without GB10_WORK: rc=$rc out=[$(tr '\n' ' ' < "$S/arch2.out")]"
	fi
	( GB10_WORK="$S/arch-work" NVNT_BECTL="$SENT/bectl" GB10_KWG_SENTINEL_LOG="$SENT/log" TMPDIR="$S" \
		sh "$archroot/tests/native-tools-testboot/make-be.sh" -b somebase ) > "$S/arch3.out" 2>&1
	rc=$?
	if [ "$rc" = 2 ] && grep -q 'not the root of a checkout' "$S/arch3.out"; then
		ok "the native-tools make-be.sh from an archive without the hooks refuses: an archive is not a checkout"
	else
		bad "the native-tools make-be.sh from an archive without the hooks: rc=$rc out=[$(tr '\n' ' ' < "$S/arch3.out")]"
	fi
	printf 'SHA256 (x) = 0000000000000000000000000000000000000000000000000000000000000000\n' > "$S/sha.txt"
	( GB10_TEST_HOOKS=1 NVNT_NO_GIT_CHECK=1 TMPDIR="$S" sh "$archroot/tests/native-tools-testboot/check-be.sh" -m "$S/mnt" -U -s "$S/sha.txt" ) > "$S/arch-cb.out" 2>&1
	rc=$?
	if grep -q 'no git metadata; the commit comparisons below are expected to FAIL' "$S/arch-cb.out" && [ "$rc" = 1 ]; then
		ok "the native-tools check-be.sh checks an extracted archive under its hooks, and says the commit comparisons will fail"
	else
		bad "the native-tools check-be.sh from an archive: rc=$rc out=[$(head -3 "$S/arch-cb.out" | tr '\n' ' ')]"
	fi
	( TMPDIR="$S" sh "$archroot/tests/native-tools-testboot/check-be.sh" -m "$S/mnt" -U -s "$S/sha.txt" ) > "$S/arch-cb2.out" 2>&1
	rc=$?
	if [ "$rc" = 2 ] && grep -q 'not the root of a checkout' "$S/arch-cb2.out"; then
		ok "the native-tools check-be.sh from an archive without the hooks refuses"
	else
		bad "the native-tools check-be.sh from an archive without the hooks: rc=$rc out=[$(head -3 "$S/arch-cb2.out" | tr '\n' ' ')]"
	fi
fi

# The NVIDIA firmware dependency kit has no script yet: its ROWS.md is the
# specification of the kit that will be written.  The rule it must follow is
# stated there, and the check keeps that statement.
fw=$repo/tests/nvidia-fw-depend-testboot/ROWS.md
if [ ! -r "$fw" ]; then
	bad "the NVIDIA firmware dependency kit has no ROWS.md"
elif grep -q 'guard_work_default' "$fw"; then
	ok "the NVIDIA firmware dependency kit states the work-root guard rule"
else
	bad "the NVIDIA firmware dependency kit does not state the work-root guard rule"
fi

# (n) this test writes nothing into the checkout's work root.  The claim is
# made true by where the scratch is made (under the canonical TMPDIR, which is
# not inside the checkout) and it is checked here: the scratch of this run is
# outside the checkout, and the checkout's work root holds no entry of it.  A
# work root that cannot be inspected is a failure, not a clean result.
case $S in
"$repo" | "$repo"/*)
	bad "the scratch of this test was created inside the checkout: $S" ;;
*)
	ok "the scratch of this test is outside the checkout: $S" ;;
esac
# kwg_left DIR: the entries of DIR named kit-work-guard.*, one per line; returns
# 2 when DIR exists but cannot be read
kwg_left() {
	[ -d "$1" ] || return 0
	[ -r "$1" ] && [ -x "$1" ] || return 2
	for _kl in "$1"/kit-work-guard.*; do
		[ -e "$_kl" ] && printf '%s\n' "$_kl"
	done
	return 0
}
_left=$(kwg_left "$repo/work")
case $? in
0)
	if [ -n "$_left" ]; then
		bad "the guard test left an entry in the checkout's work root: $(printf '%s' "$_left" | tr '\n' ' ')"
	else
		ok "the guard test wrote nothing into the checkout's work root"
	fi ;;
*) bad "the checkout's work root cannot be inspected: $repo/work" ;;
esac
if grep -nE '^[^#]*[[:space:]]m[k]dir' "$0" | grep -vE 'm[k]dir -p "\$S/' > "$S/mkdir-work.txt" 2>/dev/null; then
	bad "the guard test creates a directory outside its scratch: $(cat "$S/mkdir-work.txt")"
else
	ok "every directory the guard test creates lies under its scratch"
fi
# every scratch of this test comes from mktemp under $S (the scratch function)
# or is $S itself: a mktemp with a template of its own could name any directory
if grep -nE 'm[k]temp[[:space:]]+-d[[:space:]]+"' "$0" | grep -v 'grep' | grep -vE 'mktemp -d "\$(basec/kit-work-guard|S/\$1|_ext/k)\.' > "$S/mktemp-work.txt" 2>/dev/null; then
	bad "the guard test makes a scratch outside its scratch root: $(cat "$S/mktemp-work.txt")"
else
	ok "every scratch of the guard test comes from mktemp under the scratch root"
fi

# The TMPDIR of this test itself.  The child runs of this test are marked, so
# they do not run the children of the children.
if [ "${GB10_KWG_CHILD:-0}" != 1 ]; then
	# a TMPDIR inside the checkout is refused before the scratch is made: the
	# scratch would be written into the developer's work root
	GB10_KWG_CHILD=1 TMPDIR="$repo/work" sh "$0" > "$S/hostile.out" 2>&1
	rc=$?
	_hostile_left=$(kwg_left "$repo/work")
	_hrc=$?
	if [ "$rc" = 2 ] && grep -q 'inside the checkout' "$S/hostile.out" && [ "$_hrc" = 0 ] && [ -z "$_hostile_left" ]; then
		ok "a TMPDIR inside the checkout is refused before the scratch is created"
	else
		bad "a TMPDIR inside the checkout: rc=$rc out=[$(cat "$S/hostile.out")] left=[$_hostile_left] inspect=$_hrc"
	fi
	# a run with no TMPDIR at all: the scratch falls back to the system
	# temporary directory, and the test reaches its assertions.  As root the
	# test refuses that run (it must not write into the checkout), so the case
	# cannot be exercised: that is a skip, not a pass.
	if [ "$ME" = 0 ]; then
		skip "a run without TMPDIR is refused for root (it must not write into the checkout), so it cannot be exercised as root"
	else
		env -u TMPDIR GB10_KWG_CHILD=1 sh "$0" > "$S/notmp.out" 2>&1
		rc=$?
		if [ "$rc" = 0 ] && grep -q '^kit_work_guard_test: PASS' "$S/notmp.out"; then
			ok "a run without TMPDIR reaches the assertions and passes them"
		else
			bad "a run without TMPDIR: rc=$rc out=[$(grep '^FAIL' "$S/notmp.out" | tr '\n' ';')]"
		fi
	fi
fi

# (o) a kit that was extracted on its own lies in no checkout.  The depth of
# the kit directory would name an unrelated ancestor ("/work" for a kit one
# directory below the root of the filesystem), so the kit must refuse and name
# the work root it needs.
#
# The shared guard is not optional: a kit that was copied on its own has no
# guard beside it, and it refuses (naming the guard) before it looks at the
# checkout.  A kit that carries the guard with it (an archive must) refuses
# for the other reason: it lies in no checkout.
# kit_run <kit file in the checkout> <layout> <guard: with|without>: copy the
# kit where it lies in no checkout, run it without GB10_WORK, and print the
# exit status, the output, the sentinel log and the work directories it would
# have written into.
kit_run() {
	_kd=${1%/*}
	_file=${1##*/}
	_ext=$(scratch kit) || return 1
	case "${3:-without}" in
	with)
		( cd "$repo" && tar -cf - "$_kd" tests/native-tools-testboot/guard.sh 2> /dev/null ) |
			tar -xf - -C "$_ext" 2> /dev/null || return 1
		_dir=$_ext/$_kd
		;;
	*)
		case $2 in
		one) _dir=$_ext ;;
		two) _dir=$(mktemp -d "$_ext/k.XXXXXX") || return 1 ;;
		esac
		cp "$repo/$1" "$_dir/"
		;;
	esac
	: > "$SENT/log"
	( unset GB10_WORK
	  export GB10_KWG_SENTINEL_LOG=$SENT/log
	  export BECTL=$SENT/bectl
	  TMPDIR=$S sh "$_dir/$_file" -b somebase ) > "$_ext/out" 2>&1
	_krc=$?
	_kout=$(cat "$_ext/out")
	_klog=$(cat "$SENT/log")
	_kwork=
	for _d in "$_dir" "$_dir/.." "$_dir/../.."; do
		[ -d "$_d/work" ] && _kwork="$_kwork $_d/work"
	done
	printf '%s\n' "$_krc"
	printf '%s\n' "$_kout"
	printf 'SENTINEL:%s\n' "$_klog"
	printf 'WORKDIRS:%s\n' "$_kwork"
}

for kit in tests/linux-bridge-testboot/make-be.sh tests/prime-import-testboot/make-be.sh; do
	for layout in one two; do
		out=$(kit_run "$kit" "$layout" without) || { bad "the standalone run of $kit could not be made"; continue; }
		rc=$(printf '%s\n' "$out" | sed -n 1p)
		body=$(printf '%s\n' "$out" | sed -n '2,$p')
		sent=$(printf '%s\n' "$body" | sed -n 's/^SENTINEL://p')
		wrk=$(printf '%s\n' "$body" | sed -n 's/^WORKDIRS://p')
		if [ "$rc" = 2 ] && printf '%s\n' "$body" | grep -q 'guard\.sh' && [ -z "$sent" ] && [ -z "$wrk" ]; then
			ok "$kit, extracted on its own (layout $layout), refuses: the shared guard is not there"
		else
			bad "$kit, extracted on its own (layout $layout): rc=$rc sentinel=[$sent] workdirs=[$wrk] out=[$body]"
		fi
		out=$(kit_run "$kit" "$layout" with) || { bad "the standalone run of $kit could not be made"; continue; }
		rc=$(printf '%s\n' "$out" | sed -n 1p)
		body=$(printf '%s\n' "$out" | sed -n '2,$p')
		sent=$(printf '%s\n' "$body" | sed -n 's/^SENTINEL://p')
		wrk=$(printf '%s\n' "$body" | sed -n 's/^WORKDIRS://p')
		if [ "$rc" = 2 ] && printf '%s\n' "$body" | grep -q 'lies in no checkout' && printf '%s\n' "$body" | grep -q 'set GB10_WORK=/absolute/path' &&
			[ -z "$sent" ] && [ -z "$wrk" ]; then
			ok "$kit, extracted on its own with the guard (layout $layout), refuses before it writes anything and names the work root"
		else
			bad "$kit, extracted on its own with the guard (layout $layout): rc=$rc sentinel=[$sent] workdirs=[$wrk] out=[$body]"
		fi
	done
	# with a work root named, the kit still refuses: the shared guard is not
	# optional, and naming a work root does not replace it
	ext2=$(scratch kit) || exit 1
	cp "$repo/$kit" "$ext2/"
	( export GB10_WORK=$ext2/work
	  export GB10_KWG_SENTINEL_LOG=$SENT/log
	  export BECTL=$SENT/bectl
	  TMPDIR=$S sh "$ext2/make-be.sh" -b somebase ) > "$ext2/out" 2>&1
	rc2=$?
	if [ "$rc2" = 2 ] && grep -q 'guard\.sh' "$ext2/out" && [ ! -e "$ext2/work" ]; then
		ok "$kit, with a named work root, still refuses: the shared guard is not there"
	else
		bad "$kit, with a named work root: rc=$rc2 out=[$(cat "$ext2/out")]"
	fi
done

# The native-tools kit keeps its guard beside it, so it is checked the same
# way: it refuses because the directory it computed is not a checkout.  It is
# run only when the caller is not root: a kit that got past the check would
# build a boot environment, and this test never does that.
nt=$repo/tests/native-tools-testboot
ext3=$(scratch kit) || exit 1
cp -R "$nt/." "$ext3/"
if [ "$ME" = 0 ]; then
	skip "the native-tools kit, extracted on its own, is not run as root: it would build a boot environment"
else
	( unset GB10_WORK
	  GB10_TEST_HOOKS=1
	  GB10_KWG_SENTINEL_LOG=$SENT/log
	  NVNT_BECTL=$SENT/bectl
	  TMPDIR=$S
	  sh "$ext3/make-be.sh" ) > "$ext3/out" 2>&1
	rc=$?
	sent=$(cat "$SENT/log")
	if [ "$rc" = 2 ] && grep -q 'is not the root of a checkout' "$ext3/out" && [ -z "$sent" ]; then
		ok "the native-tools kit, extracted on its own, refuses before it writes anything"
	else
		bad "the native-tools kit, extracted on its own: rc=$rc sentinel=[$sent] out=[$(cat "$ext3/out")]"
	fi
fi

if [ "$fail" = 0 ]; then
	if [ "$skipped" = 0 ]; then
		echo "kit_work_guard_test: PASS"
	else
		echo "kit_work_guard_test: PASS ($skipped check(s) SKIPPED, each with its reason above)"
	fi
	exit 0
fi
echo "kit_work_guard_test: $fail FAILED ($skipped skipped)"
exit 1

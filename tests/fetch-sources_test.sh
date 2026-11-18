#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# Offline tests for scripts/fetch-sources.sh (the checksum-verified fetch
# of the NVIDIA source sets pinned in SOURCES).  fetch(1), git(1) and
# sha256(1) are replaced by stub scripts through the FETCH, GIT and SHA256
# test hooks, which the script honours only when GB10_TEST_HOOKS=1; nothing
# touches the network.  The pinned sha256, commit, tag and tarball name are
# read from SOURCES through scripts/lib.sh's sources_get, so a pin bump
# needs no edit here.  Stubs and scratch files live in a mktemp(1)
# directory under $HOME/work/gb10/tmp — /tmp is never used.
#
# Usage: sh tests/fetch-sources_test.sh
# Exit:  0 when every case passes, 1 otherwise.  Each case prints
#        PASS/FAIL.  Run before scripts/fetch-sources.sh exists, every
#        case fails (that is the red run).

set -u

# Base system tools only (sha256(1) lives in /sbin, git(1) in /usr/local/bin);
# no ~/.local/bin, so nothing there can shadow the tools under test.
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
script=$repo/scripts/fetch-sources.sh
. "$repo/scripts/lib.sh"

# Unpredictable scratch directory, removed by the trap on every exit path.
test_dir=$(mktemp -d "$HOME/work/gb10/tmp/fetch-test.XXXXXXXX") || exit 1
# cleanup - remove exactly this run's scratch directory.
# Time:  O(files created under test_dir), once per run.
# Space: O(1).
trap 'rm -rf "$test_dir"' EXIT INT TERM

# The pins come from SOURCES, never from literals in this file: stubs
# answer with these, or with the bad variants below.
sources_file=$repo/SOURCES
good_sha=$(sources_get "$sources_file" nvidia_freebsd_sha256) || exit 1
good_commit=$(sources_get "$sources_file" ogkm_commit) || exit 1
ogkm_tag=$(sources_get "$sources_file" ogkm_tag) || exit 1
ogkm_repo=$(sources_get "$sources_file" ogkm_repo) || exit 1
url=$(sources_get "$sources_file" nvidia_freebsd_url) || exit 1
tarball_name=${url##*/}
ogkm_name=open-gpu-kernel-modules-$ogkm_tag
bad_sha=0000000000000000000000000000000000000000000000000000000000000000
bad_commit=ffffffffffffffffffffffffffffffffffffffff

call_log=$test_dir/calls.log
sha_call_log=$test_dir/sha-calls.log
sha_answer=$test_dir/sha-answer
git_answer=$test_dir/git-answer
git_env_dump=$test_dir/git-env-dump
out=$test_dir/stdout.log
err=$test_dir/stderr.log
: > "$call_log"
: > "$sha_call_log"
: > "$git_env_dump"

export CALL_LOG=$call_log
export SHA_CALL_LOG=$sha_call_log
export SHA_ANSWER=$sha_answer
# Not named GIT_*: git_safe strips EVERY inherited GIT_* variable from the
# child's environment (pass-2 u02 #2), so a stub answer delivered through a
# GIT_-prefixed name would never reach the stub.
export FAKE_GIT_ANSWER=$git_answer
export FAKE_GIT_ENV_DUMP=$git_env_dump

# The FETCH/GIT/SHA256 overrides below are test hooks: the script must
# ignore them unless this is set (case g proves it).
GB10_TEST_HOOKS=1
export GB10_TEST_HOOKS

cat > "$test_dir/make-repo" <<'EOF'
#!/bin/sh
# make-repo <dir>: turn <dir> into a real one-commit git repository, so the
# clean-tree check in the script under test is answered by real git(1).
# Time:  O(1) git runs (init, add, commit) for one file.
# Space: O(1).
set -e
d=$1
mkdir -p "$d"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
printf 'fake\n' > "$d/README"
/usr/local/bin/git -C "$d" init -q
/usr/local/bin/git -C "$d" add README
/usr/local/bin/git -C "$d" -c core.hooksPath=/dev/null \
    -c user.email=test@example.invalid -c user.name=test \
    -c commit.gpgsign=false commit -q --no-verify -m fake
EOF

cat > "$test_dir/fake-fetch" <<'EOF'
#!/bin/sh
# Fake fetch(1): log the call, then write a fixed payload to the -o target.
echo "fetch $*" >> "$CALL_LOG"
dest=
while [ $# -gt 0 ]; do # Time: O(#args) (3 for this script's call); Space: O(1).
    if [ "$1" = "-o" ] && [ $# -ge 2 ]; then
        dest=$2
    fi
    shift
done
[ -n "$dest" ] || exit 1
printf 'fake tarball payload\n' > "$dest"
# FAKE_FETCH_FAIL=1 simulates a real fetch(1) failure: partial bytes already
# written to the -o target, then a non-zero exit.
if [ "${FAKE_FETCH_FAIL:-0}" = "1" ]; then
    exit 1
fi
EOF

cat > "$test_dir/fake-sha256" <<'EOF'
#!/bin/sh
# Fake sha256(1): record that it ran, then print the canned answer whatever
# file is asked about.  Recording matters: case g asserts this stub is never
# reached when GB10_TEST_HOOKS is unset.
echo "sha256 $*" >> "$SHA_CALL_LOG"
cat "$SHA_ANSWER"
EOF

cat > "$test_dir/fake-git" <<'EOF'
#!/bin/sh
# Fake git(1):
#   clone ... <dir>          <dir> becomes a real one-commit repository
#   [-c opt] -C <dir> rev-parse HEAD   print the canned answer
#   [-c opt] -C <dir> status|diff ...  passed through to the real git(1), so
#                            a real repository answers the clean-tree check
# Leading "-c <value>" pairs (the hardened options the script passes) are
# dropped; "-C <dir>" is remembered for the pass-through.
# Every invocation appends the inherited GIT_* environment (as seen by this
# stub) to $FAKE_GIT_ENV_DUMP, and clone invocations are logged verbatim to
# $CALL_LOG, so the test can assert git_safe stripped the environment and
# that clone got `--` before its positionals.
REAL_GIT=/usr/local/bin/git
if [ -n "${FAKE_GIT_ENV_DUMP:-}" ]; then
    env | grep '^GIT_' >> "$FAKE_GIT_ENV_DUMP" 2>/dev/null || :
fi
dir=
while [ $# -gt 0 ]; do # Time: O(#leading -c/-C options); Space: O(1).
    case $1 in
    -c) shift 2 ;;
    -C) dir=$2; shift 2 ;;
    *)  break ;;
    esac
done
case ${1:-} in
clone)
    echo "git $*" >> "$CALL_LOG"
    dest=
    for a in "$@"; do dest=$a; done # Time: O(#args) (9 for a clone); Space: O(1).
    exec "$(dirname "$0")/make-repo" "$dest"
    ;;
rev-parse)
    cat "$FAKE_GIT_ANSWER"
    ;;
status|diff)
    if [ -n "$dir" ]; then
        exec env GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
            "$REAL_GIT" -C "$dir" "$@"
    fi
    exec env GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null "$REAL_GIT" "$@"
    ;;
*)
    echo "fake-git: unsupported invocation: $*" >&2
    exit 1
    ;;
esac
EOF

chmod +x "$test_dir/make-repo" "$test_dir/fake-fetch" \
	"$test_dir/fake-sha256" "$test_dir/fake-git"

export FETCH=$test_dir/fake-fetch
export GIT=$test_dir/fake-git
export SHA256=$test_dir/fake-sha256

fails=0
report() { # report <name> <status>; status 0 passes, anything else fails
    if [ "$2" -eq 0 ]; then
        echo "PASS: $1"
    else
        echo "FAIL: $1"
        fails=$((fails + 1))
    fi
}

rc=0
run() { # run <destdir>: run the fetch script, capture stdout/stderr and rc
    rc=0
    sh "$script" "$1" > "$out" 2> "$err" || rc=$?
}

# run_nohooks <destdir>: same, with GB10_TEST_HOOKS removed from the
# environment, so the script must fall back to the fixed base tools.
run_nohooks() {
    rc=0
    env -u GB10_TEST_HOOKS sh "$script" "$1" > "$out" 2> "$err" || rc=$?
}

# a. good checksum: final tarball exists, no .part left, exit 0.
dest=$test_dir/dest-a
printf '%s\n' "$good_sha" > "$sha_answer"
printf '%s\n' "$good_commit" > "$git_answer"
: > "$call_log"
run "$dest"
st=0
[ "$rc" -eq 0 ] || st=1
[ -f "$dest/$tarball_name" ] || st=1
[ ! -e "$dest/$tarball_name.part" ] || st=1
grep -q "^fetch " "$call_log" || st=1
report "a: good checksum: downloaded, verified, renamed, exit 0" "$st"

# b. bad checksum: exit 1, no tarball and no .part left, stderr reports it.
dest=$test_dir/dest-b
printf '%s\n' "$bad_sha" > "$sha_answer"
run "$dest"
st=0
[ "$rc" -eq 1 ] || st=1
[ ! -e "$dest/$tarball_name" ] || st=1
[ ! -e "$dest/$tarball_name.part" ] || st=1
grep -q "sha256 mismatch" "$err" || st=1
report "b: bad checksum: exit 1, .part removed, 'sha256 mismatch' on stderr" "$st"

# c. second run with a good cached tarball: fetch is NOT called again.
dest=$test_dir/dest-c
printf '%s\n' "$good_sha" > "$sha_answer"
printf '%s\n' "$good_commit" > "$git_answer"
run "$dest"
rc1=$rc
: > "$call_log"
run "$dest"
st=0
[ "$rc1" -eq 0 ] || st=1
[ "$rc" -eq 0 ] || st=1
grep -q "^fetch " "$call_log" && st=1
grep -q "ok (cached)" "$out" || st=1
report "c: cached tarball: second run exit 0 without calling fetch" "$st"

# d. wrong commit from git rev-parse: exit 1, stderr reports it, dir kept.
dest=$test_dir/dest-d
printf '%s\n' "$good_sha" > "$sha_answer"
printf '%s\n' "$bad_commit" > "$git_answer"
run "$dest"
st=0
[ "$rc" -eq 1 ] || st=1
grep -q "commit mismatch" "$err" || st=1
[ -d "$dest/$ogkm_name" ] || st=1
report "d: wrong commit: exit 1, 'commit mismatch' on stderr, dir left" "$st"

# e. good commit, clean checkout: exit 0.
dest=$test_dir/dest-e
printf '%s\n' "$good_sha" > "$sha_answer"
printf '%s\n' "$good_commit" > "$git_answer"
run "$dest"
st=0
[ "$rc" -eq 0 ] || st=1
[ -d "$dest/$ogkm_name" ] || st=1
grep -q "^ok: $ogkm_name at $good_commit\$" "$out" || st=1
report "e: good commit, clean tree: exit 0" "$st"

# f. download fails (fetch wrote a partial .part, then exited 1): exit 1,
#    "download failed" on stderr, no .part and no tarball left.
dest=$test_dir/dest-f
printf '%s\n' "$good_sha" > "$sha_answer"
printf '%s\n' "$good_commit" > "$git_answer"
FAKE_FETCH_FAIL=1
export FAKE_FETCH_FAIL
run "$dest"
unset FAKE_FETCH_FAIL
st=0
[ "$rc" -eq 1 ] || st=1
grep -q "download failed" "$err" || st=1
[ ! -e "$dest/$tarball_name.part" ] || st=1
[ ! -e "$dest/$tarball_name" ] || st=1
report "f: download failed: exit 1, 'download failed' on stderr, no .part, no tarball" "$st"

# g. GB10_TEST_HOOKS unset: an override in the environment is ignored.  A
#    bad tarball sits in DESTDIR and SHA256 points at a stub that prints the
#    PINNED hash, so honouring the hook would make the bad tarball pass as
#    "ok (cached)".  With the hooks off the script would use the real
#    /sbin/sha256 and see the mismatch, but that mismatch is NOT what this
#    case observes: the .part symlink is refused first (the symlink checks
#    run before any checksum), so the run dies before either sha256 - real
#    or stub - is reached.  What the case proves is the gating itself: no
#    "ok (cached)" anywhere, neither stub is ever called, and no hook is
#    announced.  Direct unit tests of test_hook (hooks off/on, valid and
#    invalid values) live in tests/lib_test.sh cases (m)-(r).
dest=$test_dir/dest-g
printf '%s\n' "$good_sha" > "$sha_answer"
printf '%s\n' "$good_commit" > "$git_answer"
mkdir -p "$dest" || exit 1
printf 'not the real tarball\n' > "$dest/$tarball_name"
printf 'symlink target\n' > "$test_dir/g-target"
ln -s "$test_dir/g-target" "$dest/$tarball_name.part" || exit 1
: > "$call_log"
: > "$sha_call_log"
run_nohooks "$dest"
st=0
[ "$rc" -eq 1 ] || st=1
grep -q "ok (cached)" "$out" && st=1
grep -q "ok (cached)" "$err" && st=1
[ -s "$sha_call_log" ] && st=1
[ -s "$call_log" ] && st=1
grep -q "test hook" "$err" && st=1
report "g: GB10_TEST_HOOKS unset: SHA256 override ignored, bad tarball not accepted, stub never called" "$st"

# h. an existing checkout whose HEAD matches the pin but whose tracked tree
#    is modified: exit 1 with "tree modified".  The checkout is a real git
#    repository with one commit; only rev-parse is stubbed, status/diff are
#    answered by real git(1).
dest=$test_dir/dest-h
printf '%s\n' "$good_sha" > "$sha_answer"
printf '%s\n' "$good_commit" > "$git_answer"
mkdir -p "$dest" || exit 1
"$test_dir/make-repo" "$dest/$ogkm_name" || exit 1
printf 'locally modified\n' > "$dest/$ogkm_name/README"
run "$dest"
st=0
[ "$rc" -eq 1 ] || st=1
grep -q "tree modified" "$err" || st=1
[ -d "$dest/$ogkm_name" ] || st=1
report "h: pinned commit but modified tree: exit 1, 'tree modified' on stderr, dir left" "$st"

# i. the .part path exists as a symlink: refused, and the symlink is left
#    alone (a fetch through it would write wherever it points).
dest=$test_dir/dest-i
printf '%s\n' "$good_sha" > "$sha_answer"
printf '%s\n' "$good_commit" > "$git_answer"
mkdir -p "$dest" || exit 1
printf 'symlink target\n' > "$test_dir/i-target"
ln -s "$test_dir/i-target" "$dest/$tarball_name.part" || exit 1
: > "$call_log"
run "$dest"
st=0
[ "$rc" -eq 1 ] || st=1
grep -q "symlink" "$err" || st=1
[ -L "$dest/$tarball_name.part" ] || st=1
[ "$(cat "$test_dir/i-target")" = "symlink target" ] || st=1
grep -q "^fetch " "$call_log" && st=1
report "i: .part is a symlink: exit 1, refused, target untouched, no fetch" "$st"

# j. the tarball path itself exists as a symlink: refused, target intact.
dest=$test_dir/dest-j
printf '%s\n' "$good_sha" > "$sha_answer"
printf '%s\n' "$good_commit" > "$git_answer"
mkdir -p "$dest" || exit 1
printf 'symlink target\n' > "$test_dir/j-target"
ln -s "$test_dir/j-target" "$dest/$tarball_name" || exit 1
run "$dest"
st=0
[ "$rc" -eq 1 ] || st=1
grep -q "symlink" "$err" || st=1
[ -L "$dest/$tarball_name" ] || st=1
[ "$(cat "$test_dir/j-target")" = "symlink target" ] || st=1
report "j: tarball is a symlink: exit 1, refused, target untouched" "$st"

# k. DESTDIR is group-writable or other-writable: refused before anything is
#    written into it.
dest=$test_dir/dest-k1
mkdir -p "$dest" || exit 1
chmod 775 "$dest"
run "$dest"
rc_k1=$rc
err_k1=$(cat "$err")
dest=$test_dir/dest-k2
mkdir -p "$dest" || exit 1
chmod 757 "$dest"
run "$dest"
st=0
[ "$rc_k1" -eq 1 ] || st=1
[ "$rc" -eq 1 ] || st=1
printf '%s\n' "$err_k1" | grep -q "refusing DESTDIR" || st=1
grep -q "refusing DESTDIR" "$err" || st=1
[ ! -e "$test_dir/dest-k1/$tarball_name" ] || st=1
report "k: DESTDIR writable by group or other: exit 1, 'refusing DESTDIR' on stderr, nothing written" "$st"

# l. with GB10_TEST_HOOKS=1 every hook in use is announced on stderr.
dest=$test_dir/dest-l
printf '%s\n' "$good_sha" > "$sha_answer"
printf '%s\n' "$good_commit" > "$git_answer"
run "$dest"
st=0
[ "$rc" -eq 0 ] || st=1
grep -q "^fetch-sources: test hook FETCH in use\$" "$err" || st=1
grep -q "^fetch-sources: test hook GIT in use\$" "$err" || st=1
grep -q "^fetch-sources: test hook SHA256 in use\$" "$err" || st=1
report "l: GB10_TEST_HOOKS=1: 'test hook <NAME> in use' printed for FETCH, GIT and SHA256" "$st"

# m. a hook value that is not one word of [A-Za-z0-9_./-] is refused, not
#    run: this one holds a space, so an unquoted expansion would execute a
#    different program with the rest as an argument.
dest=$test_dir/dest-m
printf '%s\n' "$good_sha" > "$sha_answer"
printf '%s\n' "$good_commit" > "$git_answer"
rc=0
env SHA256="$test_dir/fake sha256" sh "$script" "$dest" > "$out" 2> "$err" || rc=$?
st=0
[ "$rc" -eq 1 ] || st=1
grep -q "refusing test hook SHA256" "$err" || st=1
report "m: hook value with a space: exit 1, 'refusing test hook SHA256' on stderr" "$st"

# n. inherited GIT_DIR must not steer the clean-tree check away from the
#    checkout: a clean decoy repository cloned from the pinned checkout (so
#    its HEAD equals the pin) with core.worktree pointing at itself is
#    exported as GIT_DIR while the checkout's tracked tree is modified.
#    A script that runs `git -C <checkout>` under that inherited GIT_DIR
#    inspects the CLEAN DECOY and exits 0; the script must strip it and
#    exit 1 with "tree modified".
dest=$test_dir/dest-n
printf '%s\n' "$good_sha" > "$sha_answer"
printf '%s\n' "$good_commit" > "$git_answer"
mkdir -p "$dest" || exit 1
"$test_dir/make-repo" "$dest/$ogkm_name" || exit 1
decoy=$test_dir/decoy-n
env GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
    /usr/local/bin/git clone -q "$dest/$ogkm_name" "$decoy" || exit 1
env GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
    /usr/local/bin/git -C "$decoy" config core.worktree "$decoy" || exit 1
printf 'locally modified\n' > "$dest/$ogkm_name/README"
rc=0
env GIT_DIR="$decoy/.git" sh "$script" "$dest" > "$out" 2> "$err" || rc=$?
st=0
[ "$rc" -eq 1 ] || st=1
grep -q "tree modified" "$err" || st=1
[ -d "$dest/$ogkm_name" ] || st=1
report "n: inherited GIT_DIR (clean decoy at the pin): modified checkout still exit 1, 'tree modified'" "$st"

# o. DESTDIR is a symlink: refused before the owner/mode check, which
#    stat(1) would answer from the LINK ITSELF (lstat by default: the link's
#    own 0755 mode and this user's uid always pass) while every write goes
#    through it to the target - here a 0777 directory (pass-2 u04 #2).
dest=$test_dir/dest-o
mkdir -p "$test_dir/real-o" || exit 1
chmod 0777 "$test_dir/real-o" || exit 1
ln -s "$test_dir/real-o" "$dest" || exit 1
printf '%s\n' "$good_sha" > "$sha_answer"
printf '%s\n' "$good_commit" > "$git_answer"
run "$dest"
st=0
[ "$rc" -eq 1 ] || st=1
grep -q "refusing DESTDIR" "$err" || st=1
grep -q "symlink" "$err" || st=1
[ ! -e "$test_dir/real-o/$tarball_name" ] || st=1
report "o: DESTDIR is a symlink to a 0777 dir: exit 1, refused, target not written" "$st"

# p. the clone call must place `--` between its options and its positionals
#    (an r14 u02 sec4 fix that was never applied), and pass --template= so
#    no template directory can be consulted (pass-2 u02 #5/#2). Asserted on
#    the invocation the fake git logs.
dest=$test_dir/dest-p
printf '%s\n' "$good_sha" > "$sha_answer"
printf '%s\n' "$good_commit" > "$git_answer"
: > "$call_log"
run "$dest"
st=0
[ "$rc" -eq 0 ] || st=1
grep -Eq "^git clone .* --template= -- $ogkm_repo " "$call_log" || st=1
report "p: clone called with --template= and -- before repo/dir" "$st"

# q. a SOURCES mistake - an EMPTY nvidia_freebsd_sha256 pin - must fail
#    closed on format, not read as "" = "": with a sha256 stub that prints
#    nothing and a bad cached tarball, the unfixed script reports
#    "ok (cached)" (pass-2 u02 #5). Runs a private copy of the scripts with
#    a bad SOURCES; hooks stay on so the stubs answer.
mkdir -p "$test_dir/badrepo-q/scripts" || exit 1
cp "$repo/scripts/fetch-sources.sh" "$repo/scripts/lib.sh" \
	"$test_dir/badrepo-q/scripts/" || exit 1
{
	printf 'nvidia_freebsd_url https://example.invalid/%s\n' "$tarball_name"
	printf 'nvidia_freebsd_sha256\n'
	printf 'ogkm_repo %s\n' "$ogkm_repo"
	printf 'ogkm_tag %s\n' "$ogkm_tag"
	printf 'ogkm_commit %s\n' "$good_commit"
} > "$test_dir/badrepo-q/SOURCES"
dest=$test_dir/dest-q
mkdir -p "$dest" || exit 1
printf 'bad payload\n' > "$dest/$tarball_name"
: > "$sha_answer"
rc=0
sh "$test_dir/badrepo-q/scripts/fetch-sources.sh" "$dest" > "$out" 2> "$err" || rc=$?
st=0
[ "$rc" -eq 1 ] || st=1
grep -q "ok (cached)" "$out" && st=1
grep -q "nvidia_freebsd_sha256" "$err" || st=1
report "q: empty sha256 pin: exit 1 on format, never 'ok (cached)'" "$st"

# r. an ogkm_tag outside [A-Za-z0-9._-] (here holding a /, which would make
#    open-gpu-kernel-modules-<tag> a PATH that mkdir -p resolves through
#    ..) must be refused before anything is created (pass-2 u02 #5).
mkdir -p "$test_dir/badrepo-r/scripts" || exit 1
cp "$repo/scripts/fetch-sources.sh" "$repo/scripts/lib.sh" \
	"$test_dir/badrepo-r/scripts/" || exit 1
{
	printf 'nvidia_freebsd_url https://example.invalid/%s\n' "$tarball_name"
	printf 'nvidia_freebsd_sha256 %s\n' "$good_sha"
	printf 'ogkm_repo %s\n' "$ogkm_repo"
	printf 'ogkm_tag ../evil\n'
	printf 'ogkm_commit %s\n' "$good_commit"
} > "$test_dir/badrepo-r/SOURCES"
printf '%s\n' "$good_sha" > "$sha_answer"
dest=$test_dir/dest-r
rc=0
sh "$test_dir/badrepo-r/scripts/fetch-sources.sh" "$dest" > "$out" 2> "$err" || rc=$?
st=0
[ "$rc" -eq 1 ] || st=1
grep -q "ogkm_tag" "$err" || st=1
[ ! -e "$dest" ] || st=1
report "r: ogkm_tag with a / (../evil): exit 1 before anything is created" "$st"

# s. git_safe strips EVERY inherited GIT_* variable, not a fixed denylist:
#    GIT_COMMON_DIR (absent from the old 10-name list) must not reach the
#    git child (pass-2 u02 #2). The dump is taken by the fake git itself;
#    GIT_CONFIG_NOSYSTEM=1 in it proves the dump mechanism ran, so an empty
#    dump cannot pass the absence check by accident.
dest=$test_dir/dest-s
printf '%s\n' "$good_sha" > "$sha_answer"
printf '%s\n' "$good_commit" > "$git_answer"
: > "$git_env_dump"
mkdir -p "$test_dir/decoy-common" || exit 1
rc=0
env GIT_COMMON_DIR="$test_dir/decoy-common" sh "$script" "$dest" \
	> "$out" 2> "$err" || rc=$?
st=0
[ "$rc" -eq 0 ] || st=1
grep -q '^GIT_CONFIG_NOSYSTEM=1$' "$git_env_dump" || st=1
grep -q '^GIT_COMMON_DIR=' "$git_env_dump" && st=1
report "s: inherited GIT_COMMON_DIR stripped by git_safe before the git child" "$st"

if [ "$fails" -gt 0 ]; then
    echo "$fails of 19 cases failed"
    echo "--- last stdout ---"
    cat "$out"
    echo "--- last stderr ---"
    cat "$err"
    exit 1
fi
echo "all 19 cases passed"
exit 0

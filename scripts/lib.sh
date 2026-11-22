#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# lib.sh - shared helpers for the gb10 scripts (fetch-sources.sh,
# prepare-tree.sh, build-rmcore.sh, build-stubs.sh, build-shim.sh,
# build-firmware.sh). Source this file; it is not meant to be executed
# directly.

# sources_get - sources_get <file> <key>: print <key>'s value from a
# SOURCES-format file ("<key> <value>" per line, the format
# scripts/fetch-sources.sh reads); fail if the key is absent.
# Time:  O(n) in the number of <file> lines (one pass).
# Space: O(1).
sources_get() {
	_file=$1
	_key=$2
	_rc=1
	while read -r _k _v || [ -n "${_k:-}" ]; do
		if [ "$_k" = "$_key" ]; then
			printf '%s\n' "${_v:-}"
			_rc=0
			break
		fi
		_k=
	done < "$_file"
	return "$_rc"
}

# count_missing - count_missing <object> <os-obj-dir> <scratch-dir>:
# print the number of symbols undefined in <object> that no object in
# <os-obj-dir> defines. Fails closed: when <os-obj-dir> holds no *.o, when
# either nm(1) run fails, or when comm(1) itself fails, print an error to
# stderr and return 1 - an empty success would read as "nothing is missing"
# when in fact nothing was checked. nm's stderr goes to its own scratch file,
# never into the symbol lists (a warning line merged with 2>&1 would be
# parsed as a symbol name). Scratch files live in one mktemp(1) directory
# inside <scratch-dir> (never fixed names, which collide between concurrent
# runs and can be pre-planted) and are removed on every return path. The two
# symbol lists are produced by separate awk and sort steps, each with its
# status checked (a pipeline would hide every stage's status but the last
# one's), and comm(1) then writes the set difference to a file whose status
# is checked; the count is wc -l of that file, so a failed step can never
# read as a count of 0. `--` ends the option list for comm(1) and sort(1)
# (FreeBSD nm(1) rejects `--`, so its paths are given without it).
# Time:  O(U log U + D log D) to sort U undefined and D defined symbols,
#        then O(U + D) for the comm scan; one nm(1) run per side.
# Space: O(U + D) lines in the scratch lists.
count_missing() {
	_out=$1
	_osdir=$2
	_scratch=$3
	_have=0
	for _o in "$_osdir"/*.o; do
		if [ -e "$_o" ]; then
			_have=1
			break
		fi
	done
	if [ "$_have" -eq 0 ]; then
		echo "count_missing: no *.o objects in $_osdir; cannot count defined symbols" >&2
		return 1
	fi
	if ! _t=$(mktemp -d "$_scratch/count.XXXXXX"); then
		echo "count_missing: cannot create a scratch directory in $_scratch" >&2
		return 1
	fi
	if ! nm -u "$_out" > "$_t/nmu" 2> "$_t/nm.err"; then
		rm -rf -- "$_t"
		echo "count_missing: nm -u failed on $_out; cannot count undefined symbols" >&2
		return 1
	fi
	if ! nm --defined-only "$_osdir"/*.o > "$_t/nmd" 2>> "$_t/nm.err"; then
		rm -rf -- "$_t"
		echo "count_missing: nm failed on $_osdir objects; cannot count defined symbols" >&2
		return 1
	fi
	# The awk and sort stages run as SEPARATE steps writing files, each
	# with its own status checked (pass-3 u02 #3): in a pipeline only
	# the last stage's status is visible, so a failed awk would be lost
	# completely and a failed sort (ENOSPC) would leave the list empty
	# or short - either reads as a count that is too low or 0, i.e.
	# "nothing is missing" when in fact nothing was checked. Same rule
	# as the comm fix below.
	if ! awk '{ print $NF }' < "$_t/nmu" > "$_t/u.raw"; then
		rm -rf -- "$_t"
		echo "count_missing: awk failed on the undefined-symbol list" >&2
		return 1
	fi
	if ! sort -u -o "$_t/undef" -- "$_t/u.raw"; then
		rm -rf -- "$_t"
		echo "count_missing: sort failed on the undefined-symbol list" >&2
		return 1
	fi
	if ! awk 'NF == 3 { print $3 }' < "$_t/nmd" > "$_t/d.raw"; then
		rm -rf -- "$_t"
		echo "count_missing: awk failed on the defined-symbol list" >&2
		return 1
	fi
	if ! sort -u -o "$_t/def" -- "$_t/d.raw"; then
		rm -rf -- "$_t"
		echo "count_missing: sort failed on the defined-symbol list" >&2
		return 1
	fi
	# comm's status must be checked: piped straight into `awk END{print NR}`
	# a failed comm (unreadable scratch, ENOSPC) would print "0" and read
	# as "nothing is missing". Write the difference to a file, check the
	# status, then count the file's lines.
	if ! comm -23 -- "$_t/undef" "$_t/def" > "$_t/miss"; then
		rm -rf -- "$_t"
		echo "count_missing: comm failed; cannot count missing symbols" >&2
		return 1
	fi
	# wc -l pads its count with spaces on FreeBSD; awk prints a clean
	# integer. comm's status was already checked above, so counting the
	# file here cannot mask a failure.
	_n=$(awk 'END { print NR }' < "$_t/miss")
	rm -rf -- "$_t"
	printf '%s\n' "$_n"
}

# test_hook - test_hook <script> <NAME> <fixed-path>: resolve the environment
# variable <NAME>, a test hook, to the command or path <script> should use.
# Threat model, plainly: this gate protects against a MISTAKEN environment - a
# stale export, a test variable leaked into a real run - not against an
# attacker who controls the environment; whoever can set the environment for
# the process can set GB10_TEST_HOOKS=1 itself and needs none of this.
# Hooks are honoured only when GB10_TEST_HOOKS=1; otherwise <fixed-path> is
# printed and the environment is ignored entirely, so a stray hook variable
# cannot replace the verifier (a SHA256 that prints the pinned
# hash) or the pins (a SOURCES of their own). A hook that is honoured must be
# one word of [A-Za-z0-9_./-]: callers quote the value, and a value holding a
# space or a shell metacharacter would otherwise run a different program with
# the rest of it as an argument. A value that begins with '-' (an option to
# whatever command later receives it) or that command substitution would hand
# back empty (trailing newlines only) is refused too. An invalid value is
# refused (nothing printed, return 1). An accepted hook prints
# "<script>: test hook <NAME> in use" to
# stderr, so a run using a hook can never be mistaken for a real one.
# Time:  O(1) - one tr(1) run over a single word.
# Space: O(1).
test_hook() {
	_th_script=$1
	_th_name=$2
	_th_fixed=$3
	if [ "${GB10_TEST_HOOKS:-0}" != 1 ]; then
		printf '%s\n' "$_th_fixed"
		return 0
	fi
	# <NAME> is a literal from the calling script, never user input.
	eval "_th_val=\${$_th_name:-}"
	if [ -z "$_th_val" ]; then
		printf '%s\n' "$_th_fixed"
		return 0
	fi
	# Fail closed on two shapes that survive naive validation: a value
	# beginning with '-' would be read as an option by whatever command
	# later receives it, and a value made only of trailing newlines looks
	# non-empty here but arrives EMPTY through the caller's $( ) command
	# substitution, silently becoming an empty path.
	case $_th_val in
	-*)
		echo "$_th_script: refusing test hook $_th_name: value begins with '-'" >&2
		return 1
		;;
	esac
	_th_cs=$(printf '%s' "$_th_val")
	if [ -z "$_th_cs" ]; then
		echo "$_th_script: refusing test hook $_th_name: value is empty after command substitution" >&2
		return 1
	fi
	# LC_ALL=C applies to tr(1) alone, so the ranges are ASCII whatever
	# locale the caller runs in: anything outside [A-Za-z0-9_./-] survives
	# the delete and means "refuse". The value itself is never echoed back
	# (it may hold control characters).
	if [ -n "$(printf '%s' "$_th_val" | LC_ALL=C tr -d 'A-Za-z0-9_./-')" ]; then
		echo "$_th_script: refusing test hook $_th_name: not one word of [A-Za-z0-9_./-]" >&2
		return 1
	fi
	echo "$_th_script: test hook $_th_name in use" >&2
	printf '%s\n' "$_th_val"
}

# git_safe - git_safe <git> [args...]: run the git(1) binary <git> with
# [args...] under an environment that cannot be steered. env(1) removes
# EVERY inherited variable whose name matches GIT_* (the list is derived
# from `env` itself at call time, never a fixed denylist - a denylist can
# never be complete, and names like GIT_COMMON_DIR, GIT_NAMESPACE,
# GIT_EXEC_PATH, GIT_TEMPLATE_DIR or GIT_SSH* would slip through and reach
# clone/fetch), then sets GIT_CONFIG_NOSYSTEM=1 and
# GIT_CONFIG_GLOBAL=/dev/null, and git runs with -c core.fsmonitor=false
# -c core.hooksPath=/dev/null: no system or user configuration, filesystem
# monitor or repository hook can run, and no inherited GIT_* can make
# `git -C <dir>` inspect a different repository than <dir>. Callers pass
# `--template=` to clone so GIT_TEMPLATE_DIR cannot have been consulted
# even in principle. Like every gate in this file, this protects against a
# MISTAKEN environment (a stale or leaked GIT_DIR), not an attacker who
# controls it.
# Time:  O(E) in the number of environment variables E (one env|sed scan),
#        plus O(#args) in this shell; the git(1) run itself dominates.
# Space: O(G) for the G GIT_* names collected.
git_safe() {
	_gs_git=$1
	shift
	# Collect every inherited GIT_* name. Variable names cannot hold
	# whitespace, '=' or glob characters, so splitting the sed output on
	# whitespace yields exactly the names, and building "-u <name>" pairs
	# from them is safe. A multi-line variable VALUE whose embedded line
	# looks like "GIT_x=..." only adds a harmless -u for a name env(1)
	# then ignores when absent.
	_gs_unsets=
	for _gs_name in $(LC_ALL=C env | LC_ALL=C sed -n 's/^\(GIT_[A-Za-z0-9_]*\)=.*/\1/p'); do
		_gs_unsets="$_gs_unsets -u $_gs_name"
	done
	# $_gs_unsets is intentionally unquoted (word-split into -u/name
	# pairs); every token is "-u" or a [A-Za-z0-9_]+ name.
	env $_gs_unsets \
	    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
	    "$_gs_git" -c core.fsmonitor=false -c core.hooksPath=/dev/null "$@"
}

# git_tree_is_clean - git_tree_is_clean <script> <git> <dir>: return 0 only
# when <dir> is a git checkout whose tracked files match HEAD exactly, i.e.
# `status --porcelain --untracked-files=no` prints nothing AND
# `diff --quiet HEAD` succeeds. A pinned commit is not evidence on its own: a
# tree with a change in it is not the pin whatever sha it reports, so both are
# required and either failure means "refuse". On a modified or uncheckable
# tree, print "<script>: tree modified: ..." (or "tree check failed") to
# stderr and return 1. Every git(1) run here goes through git_safe: the
# inherited GIT_* environment is removed, GIT_CONFIG_NOSYSTEM=1 and
# GIT_CONFIG_GLOBAL=/dev/null are set, and -c core.fsmonitor=false
# -c core.hooksPath=/dev/null is passed, so no inherited environment, system
# or user configuration, filesystem monitor or repository hook can steer the
# check to another repository or change what git reports.
# Time:  O(T) in the number of tracked files T (git's own scan), two git runs.
# Space: O(T) for the captured status lines.
git_tree_is_clean() {
	_gtc_script=$1
	_gtc_git=$2
	_gtc_dir=$3
	_gtc_st=$(git_safe "$_gtc_git" \
	    -C "$_gtc_dir" status --porcelain --untracked-files=no 2>/dev/null) || {
		echo "$_gtc_script: tree check failed: git status could not run in $_gtc_dir" >&2
		return 1
	}
	if [ -n "$_gtc_st" ]; then
		echo "$_gtc_script: tree modified: $_gtc_dir: $(printf '%s\n' "$_gtc_st" | head -n 1)" >&2
		return 1
	fi
	if ! git_safe "$_gtc_git" \
	    -C "$_gtc_dir" diff --quiet HEAD 2>/dev/null; then
		echo "$_gtc_script: tree modified: $_gtc_dir: tracked content differs from HEAD" >&2
		return 1
	fi
	return 0
}

# git_tree_has_no_extra_files - git_tree_has_no_extra_files <script> <git>
# <dir>: return 0 only when `status --porcelain --ignored` in <dir> prints
# nothing, i.e. the checkout holds no modified tracked file, no untracked
# file and no ignored file, so a recursive copy of it is exactly the pinned
# commit and nothing rides along. Prints "<script>: tree has extra files:
# <dir>: <first status line>" (or "tree check failed") to stderr and returns
# 1 otherwise. Same hardening (git_safe) as git_tree_is_clean: inherited
# GIT_* removed, GIT_CONFIG_NOSYSTEM=1, GIT_CONFIG_GLOBAL=/dev/null, plus
# -c core.fsmonitor=false -c core.hooksPath=/dev/null.
# Time:  O(T + U + I) in tracked, untracked and ignored entries (one git scan).
# Space: O(U + I) for the captured status lines.
git_tree_has_no_extra_files() {
	_gxf_script=$1
	_gxf_git=$2
	_gxf_dir=$3
	_gxf_st=$(git_safe "$_gxf_git" \
	    -C "$_gxf_dir" status --porcelain --ignored 2>/dev/null) || {
		echo "$_gxf_script: tree check failed: git status --ignored could not run in $_gxf_dir" >&2
		return 1
	}
	if [ -n "$_gxf_st" ]; then
		echo "$_gxf_script: tree has extra files: $_gxf_dir: $(printf '%s\n' "$_gxf_st" | head -n 1)" >&2
		return 1
	fi
	return 0
}

# patch_headers_safe - patch_headers_safe <patch-file>: return 0 only when
# every --- / +++ header path in <patch-file> is safe to hand to
# `patch -p0`: relative (never absolute) and holding no `..` component, so
# the patch cannot reach a file outside the directory patch(1) runs in.
# A header path is cut off at the first TAB - where patch(1) itself ends
# the file name and the timestamp begins - and any blank that remains
# after that cut is refused: patch(1) keeps spaces in a name up to the
# TAB, so a name like "existing dir/../../evil<TAB>date" would hide its
# .. components from a first-blank cut (pass-3 u02 #2).
# Any other header path (including /dev/null) is refused, and so is any
# `*** ` or `Index:` header line: patch(1) takes file names from those two
# forms as well, so a path in them would bypass the ---/+++ gate. None of
# this repo's patches is a context diff or carries an Index: line (they are
# all unified diffs), so refusing is the fail-closed default and breaks
# nothing.
# Time:  O(L) in the patch file's lines L (one pass, no early exit).
# Space: O(1) - one line held at a time.
patch_headers_safe() {
	_ph_file=$1
	_ph_bad=0
	_ph_tab=$(printf '\t')
	while IFS= read -r _ph_line || [ -n "${_ph_line:-}" ]; do
		_ph_p=
		case $_ph_line in
		'*** '*|'Index:'*) _ph_bad=1 ;;
		'--- '*) _ph_p=${_ph_line#--- } ;;
		'+++ '*) _ph_p=${_ph_line#+++ } ;;
		esac
		[ -n "$_ph_p" ] || continue
		# Cut a trailing timestamp ("--- a/b.c<TAB>2026-...") off at
		# the TAB ONLY: patch(1) keeps spaces in a file name up to
		# the TAB, so cutting at the first blank would check only
		# the first word of "existing dir/../../evil<TAB>date" and
		# miss the .. components patch(1) would then follow out of
		# the tree (pass-3 u02 #2). Any blank that remains after the
		# TAB cut is part of the path patch(1) uses; refuse it -
		# fail closed (none of this repo's patches has a space in a
		# header path).
		_ph_p=${_ph_p%%"$_ph_tab"*}
		case $_ph_p in
		*[[:blank:]]*) _ph_bad=1 ;;
		esac
		case $_ph_p in
		/*) _ph_bad=1 ;;
		esac
		case /$_ph_p/ in
		*/../*) _ph_bad=1 ;;
		esac
	done < "$_ph_file"
	if [ "$_ph_bad" -ne 0 ]; then
		return 1
	fi
	return 0
}

# safe_build_dir - safe_build_dir <path> <marker-name>: validate a directory
# a gb10 build script is about to create, reuse or rm -rf and rebuild, using
# $WORK from the calling script. All checks must pass (fail closed):
#   1. <path>'s last component is a real name - not empty, ".", ".." or "/";
#   2. <path> is not a symlink;
#   3. <path>'s parent resolves with realpath(1) and the resolved <path> is
#      strictly under the resolved $WORK/build - never equal to it - so a
#      string-match bypass ('//'), the build root itself or anything
#      reachable through a symlinked parent can never be deleted;
#   4. if <path> exists, it is a directory holding a regular file
#      <marker-name> - the marker written by the script that made it, whose
#      CONTENT the caller must still verify before deleting.
# The $WORK/build anchor is created when missing so it can be resolved;
# nothing else is created. Prints "refusing to replace <path>: <reason>" to
# stderr and returns 1 on any refusal; the caller must not rm -rf when this
# returns non-zero.
# Time:  O(1) - a handful of basename/dirname/realpath/mkdir runs, no loop.
# Space: O(1).
safe_build_dir() {
	_sbd_path=$1
	_sbd_marker=$2
	case $(basename "$_sbd_path") in
	''|.|..|/)
		echo "refusing to replace $_sbd_path: last component is not a real name" >&2
		return 1
		;;
	esac
	if [ -L "$_sbd_path" ]; then
		echo "refusing to replace $_sbd_path: symlink" >&2
		return 1
	fi
	if ! mkdir -p "$WORK/build" 2>/dev/null; then
		echo "refusing to replace $_sbd_path: cannot create build root $WORK/build" >&2
		return 1
	fi
	_sbd_anchor=$(realpath "$WORK/build" 2>/dev/null) || {
		echo "refusing to replace $_sbd_path: cannot resolve build root $WORK/build" >&2
		return 1
	}
	_sbd_parent=$(dirname "$_sbd_path")
	_sbd_parent_r=$(realpath "$_sbd_parent" 2>/dev/null) || {
		echo "refusing to replace $_sbd_path: parent directory $_sbd_parent does not resolve" >&2
		return 1
	}
	if [ -e "$_sbd_path" ]; then
		_sbd_res=$(realpath "$_sbd_path" 2>/dev/null) || {
			echo "refusing to replace $_sbd_path: does not resolve" >&2
			return 1
		}
	else
		_sbd_res=$_sbd_parent_r/$(basename "$_sbd_path")
	fi
	case $_sbd_res in
	"$_sbd_anchor"/*) ;;
	*)
		echo "refusing to replace $_sbd_path: resolves to $_sbd_res, not strictly under $_sbd_anchor" >&2
		return 1
		;;
	esac
	if [ -e "$_sbd_path" ]; then
		if [ ! -d "$_sbd_path" ]; then
			echo "refusing to replace $_sbd_path: not a directory" >&2
			return 1
		fi
		if [ ! -f "$_sbd_path/$_sbd_marker" ]; then
			echo "refusing to replace $_sbd_path: no $_sbd_marker marker (not made by this repo's scripts)" >&2
			return 1
		fi
	fi
	return 0
}

# log_path_safe - log_path_safe <script> <log>: validate the build-log path
# <log> a gb10 build script is about to write, using $WORK from the calling
# script. The rule build-shim.sh got in r14 u04, shared with
# build-firmware.sh (r14e-c pass-2 u13 #2): refuse a symlink, and refuse
# anything whose directory does not resolve (realpath) under $WORK/logs, so
# a build log can never be written through a symlink or outside the work
# root - in particular never /tmp. $WORK/logs is created when missing so it
# can be resolved; nothing else is created. Prints
# "<script>: refusing LOG <log>: <reason>" to stderr and returns 1 on any
# refusal; the caller must not write the log and should exit 1.
# Time:  O(1) - a handful of dirname/realpath/mkdir runs.
# Space: O(1).
log_path_safe() {
	_lps_script=$1
	_lps_log=$2
	if [ -L "$_lps_log" ]; then
		echo "$_lps_script: refusing LOG $_lps_log: symlink" >&2
		return 1
	fi
	if ! mkdir -p "$WORK/logs"; then
		echo "$_lps_script: cannot create $WORK/logs" >&2
		return 1
	fi
	_lps_worklogs=$(realpath "$WORK/logs") || {
		echo "$_lps_script: cannot resolve $WORK/logs" >&2
		return 1
	}
	_lps_dir=$(realpath "$(dirname "$_lps_log")" 2>/dev/null) || {
		echo "$_lps_script: refusing LOG $_lps_log: directory does not resolve" >&2
		return 1
	}
	case "$_lps_dir/" in
	"$_lps_worklogs"/*) ;;
	*)
		echo "$_lps_script: refusing LOG $_lps_log: directory $_lps_dir is not under $_lps_worklogs" >&2
		return 1
		;;
	esac
	return 0
}

# tree_version TREE: __FreeBSD_version from TREE/sys/param.h (TREE is a
# kernel sys/ directory), or nothing when there is none.
# Time: O(n) in the lines of param.h.  Space: O(1).
tree_version() {
	[ -f "$1/sys/param.h" ] || return 0
	sed -n 's/^#define[[:space:]]*__FreeBSD_version[[:space:]]*\([0-9]*\).*/\1/p' "$1/sys/param.h"
}

# tree_fits_osrel TREE OSRELDATE: the one version rule for the kernel source
# a module is built against (scripts/make.sh and scripts/fetch-trees.sh both
# use it): the tree's __FreeBSD_version has the same major as OSRELDATE
# (the value divided by 100000) and is not newer, because a module records
# the version it was built with as the oldest kernel it loads on.
# Time: O(1) beyond tree_version.  Space: O(1).
tree_fits_osrel() {
	_tf_v=$(tree_version "$1")
	_tf_r=$2
	[ -n "$_tf_v" ] && [ -n "$_tf_r" ] && [ $((_tf_v / 100000)) = $((_tf_r / 100000)) ] && [ "$_tf_v" -le "$_tf_r" ]
}

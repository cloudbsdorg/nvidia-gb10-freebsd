#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
# The driver with no GPU present: hw.nvidia.device_count, the control
# device's lifetime, and the paths the zero-device load and unload touch.
# Run: sh tests/no_gpu_test.sh
#
# The kernel side is tested with the driver's own state and a fake sysctl:
# the count of GPUs the driver reports with none, with one, and with one
# that comes and goes, the lifetime of the control device, and the
# message the driver prints when it cannot create the control device.  The
# test drives the same functions the driver calls, so a broken count or a
# broken lifetime cannot pass.  The patches are checked for the paths they
# changed, and each check is run against a mutated patch to prove that it
# can fail: a statement that was commented out is not there, even though
# its text is.

set -u
ulimit -c 0
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL

TESTSDIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH= cd -- "$TESTSDIR/.." && pwd)
WORK=${GB10_WORK:-$REPO/work}
mkdir -p "$WORK/tmp" || exit 1
TESTROOT=$(mktemp -d "$WORK/tmp/no-gpu-test.XXXXXXXX") || exit 1
cleanup() { rm -rf "$TESTROOT"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

SOURCE=$REPO/src/gb10-device/nv_device_sysctl.c
ERROR_SOURCE=$REPO/src/gb10-device/nv_ctl_error.c
STATE_SOURCE=$REPO/src/gb10-device/nv_ctl_state.c
HEADER=$REPO/src/gb10-device/nv_device_sysctl.h
ERROR_HEADER=$REPO/src/gb10-device/nv_ctl_error.h
STATE_HEADER=$REPO/src/gb10-device/nv_ctl_state.h
FAKE=$TESTSDIR/no_gpu
TESTC=$FAKE/no_gpu_test.c
CC=${CC:-cc}
FAILED=0
KILLED=0

ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; FAILED=$((FAILED + 1)); }

# build_and_run OUTPUT SOURCE...: compile the sources and the test with the
# fake KPI and run them.  Returns 2 when a compile fails, else the test's
# own status.
build_and_run() {
	_output=$1
	shift
	_objs=''
	for _s in "$@"; do
		_o=$_output.$(basename "$_s").o
		# shellcheck disable=SC2086
		if ! "$CC" -std=c99 -Wall -Werror -I"$FAKE" \
		    -I"$REPO/src/gb10-device" -c "$_s" -o "$_o"; then
			return 2
		fi
		_objs="$_objs $_o"
	done
	# shellcheck disable=SC2086
	if ! "$CC" -std=gnu99 -Wall -Werror -I"$FAKE" \
	    -I"$REPO/src/gb10-device" -c "$TESTC" -o "$_output.test.o"; then
		return 2
	fi
	# shellcheck disable=SC2086
	if ! "$CC" $_objs "$_output.test.o" -o "$_output"; then
		return 2
	fi
	"$_output"
}

printf '%s\n' '--- the device count ---'
if ! build_and_run "$TESTROOT/pass" "$SOURCE" "$ERROR_SOURCE" "$STATE_SOURCE"; then
	echo 'no_gpu_test.sh: FAIL (the normal source)' >&2
	exit 1
fi

# run_mutant NAME FILE EXPRESSION: change the source, and the mutant must
# fail.  A mutant that fails to compile is killed too (the compiler is the
# judge).
run_mutant() {
	_name=$1
	_file=$2
	_expression=$3
	_source=$TESTROOT/$_name.c
	_output=$TESTROOT/$_name
	_log=$TESTROOT/$_name.log

	sed -e "$_expression" "$_file" > "$_source"
	if cmp -s "$_file" "$_source"; then
		bad "mutant $_name: the substitution did not change the source"
		return
	fi
	_args=''
	for _s in "$SOURCE" "$ERROR_SOURCE" "$STATE_SOURCE"; do
		if [ "$_s" = "$_file" ]; then
			_args="$_args $_source"
		else
			_args="$_args $_s"
		fi
	done
	_rc=0
	# shellcheck disable=SC2086
	build_and_run "$_output" $_args > "$_log" 2>&1 || _rc=$?
	if [ "$_rc" -eq 0 ]; then
		bad "mutant $_name survived"
		sed -n '1,10p' "$_log" >&2
		return
	fi
	KILLED=$((KILLED + 1))
	ok "mutant killed: $_name"
	sed -n '/^FAIL /p' "$_log" | sed -n '1,3p'
}

# The count is the driver's own count of the GPUs it has attached.
run_mutant count-zero "$SOURCE" \
	's/count = nv_ctl_state_gpu_count();/count = 0;/'
# The count is the count, not the count and one.
run_mutant count-plus-one "$SOURCE" \
	's/count = nv_ctl_state_gpu_count();/count = nv_ctl_state_gpu_count() + 1;/'
# The node hands the count to the kernel.
run_mutant count-not-out "$SOURCE" \
	's/return (SYSCTL_OUT(req, \&count, sizeof(count)));/return (0);/'
# A GPU that attaches is counted.
run_mutant state-no-attach "$STATE_SOURCE" \
	's/gpu_count++;/gpu_count += 0;/'
# A GPU that detaches is forgotten.
run_mutant state-no-detach "$STATE_SOURCE" \
	's/gpu_count--;/gpu_count -= 0;/'
# The count never goes below zero.
run_mutant state-no-floor "$STATE_SOURCE" \
	's/if (gpu_count > 0)/if (1)/'
# The loaded module's control device may be used.
run_mutant state-not-alive "$STATE_SOURCE" \
	's/device_alive = 1;/device_alive = 0;/'
# The unloaded module's control device may not be used.
run_mutant state-always-alive "$STATE_SOURCE" \
	's/device_alive = 0;/device_alive = 1;/'
# The message names the device that could not be made.
run_mutant error-no-resource "$ERROR_SOURCE" \
	's|cannot create /dev/nvidiactl: |cannot create: |'
# The message says what to do about it.
run_mutant error-no-recovery "$ERROR_SOURCE" \
	's/what = "check the available memory and load nvidia.ko again";/what = "check the available memory";/'
# Every reason is its own reason.
run_mutant error-same-reason "$ERROR_SOURCE" \
	's/reason = "the device node was refused";/reason = "out of memory";/'

# ---- the patches ----------------------------------------------------------
# Each check names a line the patch must carry.  The checks run against a
# copy of the patch with that line removed, so a check that cannot fail is
# caught here.

# patch_code_line FILE PATTERN: the patch carries the pattern as a line of
# code.  The line must be the pattern once the spaces around it are taken
# off, and it must not be a comment: a statement that was commented out
# keeps its text but is not there.
patch_code_line() {
	awk -v pat="$2" '
	{
		marker = substr($0, 1, 1)
		if (marker == "-")
			next
		line = substr($0, 2)
		sub(/^[ \t]+/, "", line)
		sub(/[ \t]+$/, "", line)
		if (line != pat)
			next
		if (line ~ /^\/\*/ || line ~ /^\*\// || line ~ /^\/\//)
			next
		found = 1
	}
	END { exit (found ? 0 : 1) }
	' "$1"
}

# patch_has_text FILE PATTERN: the file carries the text somewhere.
patch_has_text() {
	grep -qF -- "$2" "$1"
}

# patch_line_removed FILE PATTERN: the file without the lines that carry
# the pattern.
patch_line_removed() {
	awk -v pat="$2" '
	{
		if (index($0, pat) > 0)
			next
		print
	}
	' "$1"
}

# patch_line_commented FILE PATTERN: the file with the line commented out
# and its text kept.
patch_line_commented() {
	awk -v pat="$2" '
	{
		marker = substr($0, 1, 1)
		line = substr($0, 2)
		stripped = line
		sub(/^[ \t]+/, "", stripped)
		sub(/[ \t]+$/, "", stripped)
		if (marker != "-" && stripped == pat) {
			printf "%s/* %s */\n", marker, line
			next
		}
		print
	}
	' "$1"
}

# patch_new_file PATCH OUT: the file the patch produces, from the lines it
# adds and keeps.  The lines it removes are not there.
patch_new_file() {
	awk '
	/^--- / { next }
	/^\+\+\+ / { next }
	/^@@/ { next }
	/^\\ No newline/ { next }
	{
		marker = substr($0, 1, 1)
		if (marker == "-")
			next
		print substr($0, 2)
	}
	' "$1" > "$2"
}

# patch_function_body FILE FUNCTION OUT: the body of FUNCTION in the file,
# from its definition line to the closing brace in column one.
patch_function_body() {
	awk -v f="$2" '
	!on && $0 ~ ("^[A-Za-z_].*" f "\\(") { on = 1 }
	on { print }
	on && /^}/ { exit }
	' "$1" > "$3"
	[ -s "$3" ]
}

# check_code_has FILE PATTERN WHAT: the patch must carry the pattern as a
# line of code.
check_code_has() {
	if patch_code_line "$1" "$2"; then
		ok "$3"
		return 0
	fi
	bad "$3"
	return 1
}

# check_text_has FILE PATTERN WHAT: the file must carry the text.
check_text_has() {
	if patch_has_text "$1" "$2"; then
		ok "$3"
		return 0
	fi
	bad "$3"
	return 1
}

# check_code_lost NAME FILE PATTERN DESCRIPTION: the same check against a
# patch with the line removed: the check must fail on it.
check_code_lost() {
	_name=$1
	_file=$2
	_pattern=$3
	_what=$4
	_copy=$TESTROOT/$_name.patch

	patch_line_removed "$_file" "$_pattern" > "$_copy"
	if cmp -s "$_file" "$_copy"; then
		bad "mutant $_name: the removal did not change the patch"
		return
	fi
	if patch_code_line "$_copy" "$_pattern"; then
		bad "mutant $_name: the check still passes on the mutant"
		return
	fi
	KILLED=$((KILLED + 1))
	ok "mutant killed: $_name"
}

# check_text_lost NAME FILE PATTERN DESCRIPTION: the same check against a
# file with the text removed: the check must fail on it.
check_text_lost() {
	_name=$1
	_file=$2
	_pattern=$3
	_what=$4
	_copy=$TESTROOT/$_name.patch

	patch_line_removed "$_file" "$_pattern" > "$_copy"
	if cmp -s "$_file" "$_copy"; then
		bad "mutant $_name: the removal did not change the file"
		return
	fi
	if patch_has_text "$_copy" "$_pattern"; then
		bad "mutant $_name: the check still passes on the mutant"
		return
	fi
	KILLED=$((KILLED + 1))
	ok "mutant killed: $_name"
}

# check_code_commented NAME FILE PATTERN DESCRIPTION: a mutant that
# comments the line out and keeps its text: the check must fail on it too.
check_code_commented() {
	_name=$1
	_file=$2
	_pattern=$3
	_what=$4
	_copy=$TESTROOT/$_name.patch

	patch_line_commented "$_file" "$_pattern" > "$_copy"
	if cmp -s "$_file" "$_copy"; then
		bad "mutant $_name: the commenting did not change the patch"
		return
	fi
	if patch_code_line "$_copy" "$_pattern"; then
		bad "mutant $_name: the check still passes on the mutant"
		return
	fi
	KILLED=$((KILLED + 1))
	ok "mutant killed: $_name"
}

# check_code_hasnt FILE PATTERN DESCRIPTION: the patch must not carry the
# line at all.
check_code_hasnt() {
	if patch_code_line "$1" "$2"; then
		bad "$3"
		return 1
	fi
	ok "$3"
	return 0
}

# check_code_added NAME FILE PATTERN DESCRIPTION: a mutant that adds the
# line: the check must fail on it.
check_code_added() {
	_name=$1
	_file=$2
	_pattern=$3
	_what=$4
	_copy=$TESTROOT/$_name.patch

	{
		printf '%s\n' '--- a/a' '+++ b/b'
		printf '+%s\n' "$_pattern"
		cat "$_file"
	} > "$_copy"
	if ! patch_code_line "$_copy" "$_pattern"; then
		bad "mutant $_name: the mutant does not carry the line"
		return
	fi
	KILLED=$((KILLED + 1))
	ok "mutant killed: $_name"
}

SYSCTL_PATCH=$REPO/patches/patch-nvidia_nvidia_sysctl.c
CTL_PATCH=$REPO/patches/patch-zzz-2464-no-gpu_ctl.c
SUBR_PATCH=$REPO/patches/patch-zzz-2464-no-gpu_subr.c
FREEBSD_PATCH=$REPO/patches/patch-zzz-2464-no-gpu_nv-freebsd.h
MAKEFILE_PATCH=$REPO/patches/patch-nvidia_Makefile
PREPARE=$REPO/scripts/prepare-tree.sh

# The node is registered with the module, not with a GPU: it exists with no
# GPU at all.
check_code_has "$SYSCTL_PATCH" 'nv_device_sysctl_init(&sysctl_ctx, oid_nvidia);' \
    'the device count is registered with the module'
check_code_lost sysctl-no-node "$SYSCTL_PATCH" 'nv_device_sysctl_init(&sysctl_ctx, oid_nvidia);' \
    'the device count is registered with the module'

# The message buffer of the registry node is freed on unload: without it
# every load and unload leaks it.
check_code_has "$SYSCTL_PATCH" 'free((void *)rm_msg_string, M_NVIDIA);' \
    'the registry message buffer is freed on unload'
check_code_lost sysctl-leak "$SYSCTL_PATCH" 'free((void *)rm_msg_string, M_NVIDIA);' \
    'the registry message buffer is freed on unload'

# ... and the pointer is cleared, so a later load cannot free it twice.
check_code_has "$SYSCTL_PATCH" 'rm_msg_string = NULL;' \
    'the registry message buffer pointer is cleared'
check_code_lost sysctl-msg-not-cleared "$SYSCTL_PATCH" 'rm_msg_string = NULL;' \
    'the registry message buffer pointer is cleared'
check_code_commented sysctl-msg-not-cleared-commented "$SYSCTL_PATCH" \
    'rm_msg_string = NULL;' \
    'the registry message buffer pointer is cleared'

# The control device is created when the module loads: a host with no GPU
# still has /dev/nvidiactl.
check_code_has "$SUBR_PATCH" 'status = nvidia_ctl_module_attach();' \
    'the module creates the control device'
check_code_lost ctl-not-created "$SUBR_PATCH" 'status = nvidia_ctl_module_attach();' \
    'the module creates the control device'
check_code_commented ctl-not-created-commented "$SUBR_PATCH" \
    'status = nvidia_ctl_module_attach();' \
    'the module creates the control device'

# ... and destroyed when it unloads.
check_code_has "$SUBR_PATCH" 'nvidia_ctl_module_detach();' \
    'the module destroys the control device'
check_code_lost ctl-not-destroyed "$SUBR_PATCH" 'nvidia_ctl_module_detach();' \
    'the module destroys the control device'
check_code_commented ctl-not-destroyed-commented "$SUBR_PATCH" \
    'nvidia_ctl_module_detach();' \
    'the module destroys the control device'

# The control device goes before the API lock is released: an open of it
# waits for that lock, so it cannot slip in between the check and the
# destroy.  The hunk is the one that refuses the unload.
_unload_part=$(awk '
	/^@@/ { n++; cur = n; part[n] = "" }
	{ part[cur] = part[cur] $0 "\n" }
	/return EBUSY;/ { hit = cur }
	END { printf "%s", part[hit] }
' "$SUBR_PATCH")
_detach=$(printf '%s\n' "$_unload_part" | grep -nF 'nvidia_ctl_module_detach();' | head -1 | cut -d: -f1)
_unlock=$(printf '%s\n' "$_unload_part" | grep -nF 'nv_unlock_api(nv);' | head -1 | cut -d: -f1)
_mtx=$(printf '%s\n' "$_unload_part" | grep -nF 'mtx_destroy(&snapshot_timer_mutex);' | head -1 | cut -d: -f1)
if [ -n "$_detach" ] && [ -n "$_unlock" ] && [ -n "$_mtx" ] && \
    [ "$_detach" -lt "$_unlock" ] && [ "$_detach" -lt "$_mtx" ]; then
	ok 'the control device is destroyed before the API lock is released'
else
	bad 'the control device is destroyed before the API lock is released'
fi

# An open that was in flight when the unload began must not reach a
# resource manager that is gone.
check_code_has "$SUBR_PATCH" 'if (!nvidia_ctl_module_alive()) {' \
    'an open refuses a control device that is on its way out'
check_code_lost ctl-open-not-refused "$SUBR_PATCH" \
    'if (!nvidia_ctl_module_alive()) {' \
    'an open refuses a control device that is on its way out'

# The device is created once: the helper refuses to make a second one.
check_code_has "$CTL_PATCH" 'if (nvidia_ctl_cdev != NULL)' \
    'the control device is created once'
check_code_lost ctl-twice "$CTL_PATCH" 'if (nvidia_ctl_cdev != NULL)' \
    'the control device is created once'

# The device is made with the call that keeps the reason: the code the
# kernel returns is the cause, and the driver hands it back unchanged.
check_code_has "$CTL_PATCH" \
    'error = make_dev_s(&args, &cdev, "%s", nvidia_ctl_cdevsw.d_name);' \
    'the control device is made with the reason kept'
check_code_lost ctl-no-reason "$CTL_PATCH" \
    'error = make_dev_s(&args, &cdev, "%s", nvidia_ctl_cdevsw.d_name);' \
    'the control device is made with the reason kept'
check_code_has "$CTL_PATCH" 'return (error);' \
    'the reason the kernel gave is handed back unchanged'
check_code_lost ctl-lost-reason "$CTL_PATCH" 'return (error);' \
    'the reason the kernel gave is handed back unchanged'

# ... and no failure is reported as a memory failure the driver never
# heard of.
check_code_hasnt "$CTL_PATCH" 'return (ENOMEM);' \
    'no control device failure is reported as a memory failure'

# The driver says what went wrong when it cannot make the device: the
# message names the resource, the reason and the way out.
check_code_has "$SUBR_PATCH" 'nv_ctl_create_error(status, msg, sizeof(msg));' \
    'the driver explains why the control device could not be made'
check_code_lost ctl-no-error-message "$SUBR_PATCH" \
    'nv_ctl_create_error(status, msg, sizeof(msg));' \
    'the driver explains why the control device could not be made'

# The count and the lifetime of the control device live in our own file,
# so the test can drive the real transitions.
check_code_has "$CTL_PATCH" 'nv_ctl_state_gpu_attach();' \
    'a GPU that attaches is counted by the driver own state'
check_code_lost ctl-no-attach-state "$CTL_PATCH" 'nv_ctl_state_gpu_attach();' \
    'a GPU that attaches is counted by the driver own state'
check_code_has "$CTL_PATCH" 'nv_ctl_state_gpu_detach();' \
    'a GPU that detaches is forgotten by the driver own state'
check_code_lost ctl-no-detach-state "$CTL_PATCH" 'nv_ctl_state_gpu_detach();' \
    'a GPU that detaches is forgotten by the driver own state'
check_code_has "$CTL_PATCH" 'nv_ctl_state_device_created();' \
    'the control device is usable once the module has made it'
check_code_lost ctl-not-created-state "$CTL_PATCH" 'nv_ctl_state_device_created();' \
    'the control device is usable once the module has made it'
check_code_has "$CTL_PATCH" 'nv_ctl_state_device_destroyed();' \
    'the control device is not usable once the module is unloading'
check_code_lost ctl-not-destroyed-state "$CTL_PATCH" 'nv_ctl_state_device_destroyed();' \
    'the control device is not usable once the module is unloading'

# The module is the only owner of the control device: a GPU that attaches
# does not create it, whatever the call looks like.  The check reads the
# body of nvidia_ctl_attach() in the file the patch produces.
patch_new_file "$CTL_PATCH" "$TESTROOT/ctl.new"
if patch_function_body "$TESTROOT/ctl.new" 'nvidia_ctl_attach' \
    "$TESTROOT/attach.body"; then
	if grep -q 'nvidia_ctl_dev_create' "$TESTROOT/attach.body"; then
		bad 'a GPU that attaches does not create the control device'
	else
		ok 'a GPU that attaches does not create the control device'
	fi
else
	bad 'a GPU that attaches does not create the control device (no body)'
fi

# The new file is compiled into the module.
check_text_has "$MAKEFILE_PATCH" 'nv_device_sysctl.c' \
    'the module compiles the device count'
check_text_lost makefile-no-src "$MAKEFILE_PATCH" 'nv_device_sysctl.c' \
    'the module compiles the device count'
check_text_has "$MAKEFILE_PATCH" 'nv_ctl_error.c' \
    'the module compiles the control device error message'
check_text_lost makefile-no-error-src "$MAKEFILE_PATCH" 'nv_ctl_error.c' \
    'the module compiles the control device error message'
check_text_has "$MAKEFILE_PATCH" 'nv_ctl_state.c' \
    'the module compiles the control device state'
check_text_lost makefile-no-state-src "$MAKEFILE_PATCH" 'nv_ctl_state.c' \
    'the module compiles the control device state'

# ... and it is copied into the tree.
check_text_has "$PREPARE" 'src/gb10-device/nv_device_sysctl.c' \
    'the tree gets the device count source'
check_text_lost prepare-no-copy "$PREPARE" 'src/gb10-device/nv_device_sysctl.c' \
    'the tree gets the device count source'
check_text_has "$PREPARE" 'src/gb10-device/nv_ctl_error.c' \
    'the tree gets the control device error message source'
check_text_lost prepare-no-error-copy "$PREPARE" 'src/gb10-device/nv_ctl_error.c' \
    'the tree gets the control device error message source'
check_text_has "$PREPARE" 'src/gb10-device/nv_ctl_state.c' \
    'the tree gets the control device state source'
check_text_lost prepare-no-state-copy "$PREPARE" 'src/gb10-device/nv_ctl_state.c' \
    'the tree gets the control device state source'

# The declarations the module patch uses are in the driver's own header.
check_text_has "$FREEBSD_PATCH" 'nvidia_ctl_module_attach' \
    'the module functions are declared'
check_text_lost freebsd-no-decl "$FREEBSD_PATCH" 'nvidia_ctl_module_attach' \
    'the module functions are declared'

# ---- the manual page ------------------------------------------------------
# The node is user-visible: the manual page says what it is.
if grep -q 'device_count' "$REPO/man/nvidia.4"; then
	ok 'nvidia(4) documents hw.nvidia.device_count'
else
	bad 'nvidia(4) documents hw.nvidia.device_count'
fi

# The journal says how many mutants this script has: the two must agree, or
# the journal describes a run that never happened.
_journal_line=$(grep 'no_gpu_test\.sh' "$REPO/JOURNAL.md" | head -1)
_journal_mutants=$(printf '%s\n' "$_journal_line" |
    sed -n 's/.*[^0-9]\([0-9][0-9]*\) mutants.*/\1/p')
_script_mutants=$(( $(grep -c '^run_mutant ' "$0") +
    $(grep -c '^check_code_lost ' "$0") +
    $(grep -c '^check_text_lost ' "$0") +
    $(grep -c '^check_code_commented ' "$0") +
    $(grep -c '^check_code_added ' "$0") ))
if [ -n "$_journal_mutants" ] && [ "$_journal_mutants" -eq "$_script_mutants" ]; then
	ok "the journal and the script agree on the mutants ($_script_mutants)"
else
	bad "the journal says ${_journal_mutants:-none} mutants, the script has $_script_mutants"
fi

if [ "$FAILED" -ne 0 ]; then
	echo "no_gpu_test.sh: FAIL ($FAILED failures)" >&2
	exit 1
fi
echo "no_gpu_test.sh: PASS ($KILLED mutants killed)"

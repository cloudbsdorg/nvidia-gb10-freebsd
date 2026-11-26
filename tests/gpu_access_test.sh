#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# gpu_access_test.sh - Track #2374 and #2376: the behaviour of the REAL
# GPU access check and of the REAL wired memory accounting.
#
# src/gb10-gpu-access/nvga_policy.h (the rules), nvga_glue.h (the interface)
# and nvga_glue.c (the kernel glue) are compiled in userland against fakes
# of the kernel (tests/data/nvga_fakes.h) and run: a user without access
# cannot attach a GPU, a jail with only one GPU cannot attach another one,
# and an allocation over a limit is refused cleanly while the host stays up.
# Mutants of the code (a check turned off, a limit not looked at, a charge
# not taken, a charge not given back, ...) must each make the harness fail.
#
# The pins then hold the call sites: the check runs before the RM sees the
# attach, the accounting runs inside the RM's allocation path, and the RM
# nodes are 0660 and owned by a group.
#
# Run: sh tests/gpu_access_test.sh

set -eu
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL
TESTSDIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH= cd -- "$TESTSDIR/.." && pwd)
mkdir -p "${TMPDIR:-$REPO/tmp}"
T=$(mktemp -d "${TMPDIR:-$REPO/tmp}/gpu-access.XXXXXXXX")
trap 'rm -rf "$T"' EXIT HUP INT QUIT TERM
. "$TESTSDIR/pins_lib.sh"
rc=0

SRC=$REPO/src/gb10-gpu-access
HARNESS=$REPO/tests/data/gpu_access_harness.c
SCENARIOS="access jail wired wired-jail rctl nodes kernel bigbytes format"

# run_harness <glue source> <policy header>: compile and run every scenario;
# 0 ok, 1 a scenario failed, 2 it did not build.
run_harness() {
	mkdir -p "$T/b"
	cp "$1" "$T/b/nvga_glue.c"
	cp "$2" "$T/b/nvga_policy.h"
	cp "$SRC/nvga_glue.h" "$T/b/nvga_glue.h"
	cc -std=gnu11 -Wall -Wextra -Wno-unused-function -Wno-unused-parameter \
	    -Wno-unused-but-set-variable -Werror -DNVGA_FAKE_KERNEL \
	    -I "$T/b" -I "$SRC" -I "$REPO/tests/data" \
	    -o "$T/b/h" "$HARNESS" "$T/b/nvga_glue.c" >"$T/b/out" 2>&1 || return 2
	for s in $SCENARIOS; do
		"$T/b/h" "$s" >>"$T/b/out" 2>&1 || return 1
	done
	return 0
}

if run_harness "$SRC/nvga_glue.c" "$SRC/nvga_policy.h"; then
	echo "ok   the real policy and glue pass every scenario"
else
	cat "$T/b/out" 2>/dev/null || true
	echo "FAIL the real policy and glue fail the harness"
	rc=1
fi

# a mutant of the glue: sed on nvga_glue.c
mutant() {	# mutant <name> <sed expression>
	sed -e "$2" "$SRC/nvga_glue.c" > "$T/mut.c"
	if cmp -s "$SRC/nvga_glue.c" "$T/mut.c"; then
		echo "FAIL mutant $1 changed nothing"; rc=1; return
	fi
	run_harness "$T/mut.c" "$SRC/nvga_policy.h" && r=0 || r=$?
	case $r in
	1) echo "ok   mutant $1 is red" ;;
	2) echo "FAIL mutant $1 did not build: $(head -3 "$T/b/out" | tr '\n' ' ')"; rc=1 ;;
	*) echo "FAIL mutant $1 stays green"; rc=1 ;;
	esac
}

# a mutant of the policy: sed on nvga_policy.h
pmutant() {	# pmutant <name> <sed expression>
	sed -e "$2" "$SRC/nvga_policy.h" > "$T/mut.policy"
	if cmp -s "$SRC/nvga_policy.h" "$T/mut.policy"; then
		echo "FAIL policy mutant $1 changed nothing"; rc=1; return
	fi
	run_harness "$SRC/nvga_glue.c" "$T/mut.policy" && r=0 || r=$?
	case $r in
	1) echo "ok   policy mutant $1 is red" ;;
	2) echo "FAIL policy mutant $1 did not build: $(head -3 "$T/b/out" | tr '\n' ' ')"; rc=1 ;;
	*) echo "FAIL policy mutant $1 stays green"; rc=1 ;;
	esac
}

# the access check
pmutant access-always-allows 's/^\([[:space:]]*\)if (unit < 0)$/\1if (1)/'
pmutant jail-grant-ignored 's/^\([[:space:]]*\)if (nvga_jail_granted(rules, cred->jail_id, unit))$/\1if (1)/'
pmutant group-check-skipped 's/^\([[:space:]]*\)if (nvga_cred_in_group(cred, rules->node_gid))$/\1if (1)/'
pmutant root-not-allowed 's/^\([[:space:]]*\)if (rules->allow_root \&\& cred->uid == 0)$/\1if (0)/'
pmutant wrong-group-allowed 's/nvga_cred_in_group(cred, rules->node_gid)/nvga_cred_in_group(cred, rules->node_gid + 1)/'

# the accounting
pmutant limit-not-checked 's/^\([[:space:]]*\)if (nvga_over(cred_total, bytes, limits->per_credential))$/\1if (0)/'
pmutant jail-limit-not-checked 's/^\([[:space:]]*\)if (in_jail \&\& nvga_over(jail_total, bytes, limits->per_credential))$/\1if (0)/'
pmutant total-limit-not-checked 's/^\([[:space:]]*\)if (nvga_over(total, bytes, limits->total))$/\1if (0)/'
pmutant rctl-limit-not-checked 's/^\([[:space:]]*\)if (nvga_over(cred_total, bytes, limits->rctl))$/\1if (0)/'
pmutant over-returns-no 's/^\([[:space:]]*\)if (total > limit)$/\1if (0)/'

# the glue
mutant check-always-allows 's/^\([[:space:]]*\)decision = nvga_may_use_unit(unit);$/\1decision = NVGA_ALLOW;/'
mutant attach-refusal-dropped 's/^\([[:space:]]*\)return (EPERM);$/\1return (0);/'
mutant charge-not-taken 's/^\([[:space:]]*\)nvga_uid_totals\[slot\].bytes += bytes;$/\1(void)bytes;/'
mutant total-not-taken 's/^\([[:space:]]*\)nvga_wired_total += bytes;$/\1(void)bytes;/'
mutant charge-not-given-back 's/^\([[:space:]]*\)if (nvga_wired_total >= bytes)$/\1if (0)/'
mutant rctl-cap-ignored 's/^\([[:space:]]*\)limits.rctl = rctl_limit;$/\1limits.rctl = 0;/'
mutant rctl-cap-not-asked 's/^\([[:space:]]*\)rctl_limit = nvga_rctl_limit(cred);$/\1rctl_limit = 0;/'
mutant jail-total-not-tracked 's/^\([[:space:]]*\)jail_total = nvga_jail_totals\[jslot\].bytes;$/\1jail_total = 0;/'
mutant kernel-not-charged 's/^\([[:space:]]*\)racct_add_cred(cred, RACCT_MEMLOCK, bytes);$/\1(void)bytes;/'
mutant unit-not-looked-up 's/^\([[:space:]]*\)unit = nvga_unit_of_gpu(gpu_id);$/\1unit = 0;/'
mutant size-overflow-allowed 's/^\([[:space:]]*\)if (count > UINT64_MAX \/ page_size)$/\1if (0)/'
mutant rules-not-initialized 's/^\([[:space:]]*\)nvga_rules.node_gid = (uint32_t)nvga_device_gid();$/\1(void)0;/'
mutant system-limit-not-exempt 's/^\([[:space:]]*\)limits.per_credential = 0;$/\1limits.per_credential = nvga_wired_limit;/'
mutant bytes-truncated 's/^\([[:space:]]*\)value = (int64_t)nvga_wired_total;$/\1value = (int64_t)(int)nvga_wired_total;/'
# the string sysctls: a formatter that does not check that the text fits
# writes past the end of its buffer, and one that reports more than it
# wrote hands the reader the bytes behind the string.
pmutant fmt-fits-not-checked 's/if (slen + 1 > len - off) {/if (0) {/'
pmutant fmt-length-not-clamped 's/^\([[:space:]]*\)return (off + slen);$/\1return (off + slen + 8);/'

# ---- the pins: the call sites in the patches ----

PATCH_ACCESS=$REPO/patches/patch-zzz-2374-nvidia_gpu_access_subr.c
PATCH_WIRED=$REPO/patches/patch-zzz-2376-nvidia_gpu_wired_subr.c
PATCH_DEV=$REPO/patches/patch-zzz-2376-nvidia_gpu_modes_nvidia_dev.c
PATCH_CTL=$REPO/patches/patch-zzz-2376-nvidia_gpu_modes_nvidia_ctl.c
PATCH_MODESET=$REPO/patches/patch-zzz-2376-nvidia_gpu_modes_modeset.c
PATCH_SYSCTL=$REPO/patches/patch-zzz-2376-nvidia_gpu_access_sysctl.c
PATCH_MAKEFILE=$REPO/patches/patch-zzz-2376-nvidia_gpu_access_Makefile

# the added text of a patch (the leading + removed)
added() { awk '/^\+/ && !/^\+\+\+/ { print substr($0, 2) }' "$1"; }

for p in "$PATCH_ACCESS" "$PATCH_WIRED" "$PATCH_DEV" "$PATCH_CTL" \
    "$PATCH_MODESET" "$PATCH_SYSCTL" "$PATCH_MAKEFILE"; do
	if [ ! -f "$p" ]; then
		echo "FAIL a patch is missing: $p"
		rc=1
	fi
done

if [ -f "$PATCH_ACCESS" ]; then
	added "$PATCH_ACCESS" > "$T/pa.c"
	pin_strip "$T/pa.c" > "$T/pa.stripped"
	pa=$(cat "$T/pa.stripped")
	pin_dead "$pa" || { echo "the access patch has a disabled-code form"; rc=1; }
	# the check runs before the RM is asked to attach the GPU
	pin_has "$pa" 'nvga_check_attach\(' || { echo "the access patch does not call the check"; rc=1; }
	pin_has "$pa" 'EPERM' || { echo "the access patch does not refuse with EPERM"; rc=1; }
	# the RM's own gate is answered with the same rule
	pin_has "$pa" 'nvga_may_use_unit\(' || { echo "the access patch does not ask the policy about the RM gate"; rc=1; }
	# the patch does not open a GPU itself
	printf '%s\n' "$pa" | grep -qF 'nvidia_open_dev_kernel' && {
		echo "the access patch touches the open path itself"; rc=1; }
fi

if [ -f "$PATCH_WIRED" ]; then
	added "$PATCH_WIRED" > "$T/pw.c"
	pin_strip "$T/pw.c" > "$T/pw.stripped"
	pw=$(cat "$T/pw.stripped")
	pin_dead "$pw" || { echo "the accounting patch has a disabled-code form"; rc=1; }
	# the accounting runs in the RM's allocation path
	pin_has "$pw" 'nvga_wired_alloc\(' || { echo "the accounting patch does not charge"; rc=1; }
	pin_has "$pw" 'nvga_wired_free\(' || { echo "the accounting patch does not give the memory back"; rc=1; }
	pin_has "$pw" 'NV_ERR_NO_MEMORY' || { echo "the accounting patch does not fail the allocation cleanly"; rc=1; }
fi

if [ -f "$PATCH_DEV" ] && [ -f "$PATCH_CTL" ]; then
	for p in "$PATCH_DEV" "$PATCH_CTL"; do
		added "$p" > "$T/pm.c"
		pin_strip "$T/pm.c" > "$T/pm.stripped"
		pm=$(cat "$T/pm.stripped")
		pin_dead "$pm" || { echo "the node mode patch has a disabled-code form: $p"; rc=1; }
		pin_has "$pm" 'nvga_device_mode\(\)' || { echo "the node mode patch does not ask for the mode: $p"; rc=1; }
		pin_has "$pm" 'nvga_device_gid\(\)' || { echo "the node mode patch does not ask for the group: $p"; rc=1; }
		pin_has "$pm" 'UID_ROOT' || { echo "the node mode patch does not keep the nodes owned by root: $p"; rc=1; }
		printf '%s\n' "$pm" | grep -qE '0666' && {
			echo "the node mode patch still makes a node 0666: $p"; rc=1; }
	done
fi

# the modeset node is an RM node too: it is made by nvidia-modeset.ko, which
# has no symbol of ours, so it asks the shared header for the mode and the
# group.
if [ -f "$PATCH_MODESET" ]; then
	added "$PATCH_MODESET" > "$T/pms.c"
	pin_strip "$T/pms.c" > "$T/pms.stripped"
	pms=$(cat "$T/pms.stripped")
	pin_dead "$pms" || { echo "the modeset node patch has a disabled-code form"; rc=1; }
	pin_has "$pms" 'nvga_nodes_gid\(\)' || { echo "the modeset node patch does not ask for the group"; rc=1; }
	pin_has "$pms" 'NVGA_NODES_MODE' || { echo "the modeset node patch does not ask for the mode"; rc=1; }
	pin_has "$pms" 'UID_ROOT' || { echo "the modeset node patch does not keep the node owned by root"; rc=1; }
	printf '%s\n' "$pms" | grep -qE '0666' && {
		echo "the modeset node patch still makes the node 0666"; rc=1; }
fi

# ---- the tree: the patches applied, and the code they make ----
#
# The pins above hold on the text of the patches; these hold on the code
# the patches make: the check before the RM opens the GPU, the accounting in
# the allocation path, and the nodes at 0660.  The sources are needed; the
# check is skipped without them (the text pins above still run).
GB10_WORK=${GB10_WORK:-}
NVSRC=${GB10_WORK:+$GB10_WORK/sources/NVIDIA-FreeBSD-x86_64-580.178.04/src}
if [ -n "$NVSRC" ] && [ -d "$NVSRC" ]; then
	TT=$(mktemp -d "$T/tree.XXXXXXXX")
	cp -R "$NVSRC" "$TT/src"
	ok=1
	for p in "$REPO"/patches/patch-*; do
		if ! patch -d "$TT/src" -p0 -E -s -i "$p"; then
			echo "FAIL the patch does not apply: $p"
			ok=0
			rc=1
		fi
	done
	if [ "$ok" = 1 ]; then
		S=$TT/src/nvidia
		# the check runs before the GPU is opened
		_a=$(grep -n 'nvga_check_attach' "$S/nvidia_subr.c" | head -1 | cut -d: -f1)
		_o=$(grep -n 'nvidia_open_dev_kernel' "$S/nvidia_subr.c" | head -1 | cut -d: -f1)
		[ -n "$_a" ] && [ -n "$_o" ] && [ "$_a" -lt "$_o" ] || {
			echo "the check does not run before the GPU is opened"; rc=1; }
		# the RM's own gate asks the policy
		grep -q 'nvga_may_use_unit' "$S/nvidia_subr.c" || {
			echo "the RM gate does not ask the policy"; rc=1; }
		# the accounting is in the allocation path and in the free path
		grep -q 'nvga_wired_alloc' "$S/nvidia_subr.c" || {
			echo "the allocation path does not charge"; rc=1; }
		grep -q 'nvga_wired_free' "$S/nvidia_subr.c" || {
			echo "the free path does not give the memory back"; rc=1; }
		# the nodes are 0660 and owned by a group
		for f in nvidia_dev.c nvidia_ctl.c; do
			grep -q '0666' "$S/$f" && {
				echo "$f still makes a node 0666"; rc=1; }
			grep -q 'nvga_device_mode()' "$S/$f" || {
				echo "$f does not ask for the mode"; rc=1; }
			grep -q 'nvga_device_gid()' "$S/$f" || {
				echo "$f does not ask for the group"; rc=1; }
		done
		# the modeset node is an RM node too: it is made by
		# nvidia-modeset.ko, so it asks the shared header
		M=$TT/src/nvidia-modeset/nvidia-modeset-freebsd.c
		grep -q '0666' "$M" && {
			echo "the modeset node is still 0666"; rc=1; }
		grep -q 'nvga_nodes_gid()' "$M" || {
			echo "the modeset node does not ask for the group"; rc=1; }
		grep -q 'NVGA_NODES_MODE' "$M" || {
			echo "the modeset node does not ask for the mode"; rc=1; }
		# the state sysctls are registered under the hw.nvidia node
		grep -q 'nvga_sysctl_init(&sysctl_ctx, oid_nvidia)' "$S/nvidia_sysctl.c" || {
			echo "the state sysctls are not registered under the hw.nvidia node"; rc=1; }
		# our own source is in the module
		grep -q 'SRCS+=.*nvga_glue.c' "$S/Makefile" || {
			echo "the glue is not in the module"; rc=1; }
		echo "ok   the patches apply and the code they make is where it must be"
	fi
else
	echo "skip the tree pins: no NVIDIA sources (set GB10_WORK to the work root)"
fi

# the glue itself: no disabled-code form
for f in "$SRC/nvga_policy.h" "$SRC/nvga_glue.h" "$SRC/nvga_glue.c" \
    "$SRC/nvga_nodes.h"; do
	pin_strip "$f" > "$T/g.stripped"
	g=$(cat "$T/g.stripped")
	pin_dead "$g" || { echo "$f has a disabled-code form"; rc=1; }
done

if [ "$rc" = 0 ]; then
	echo "gpu_access_test: all checks passed"
else
	echo "gpu_access_test: FAILURES"
fi
exit $rc

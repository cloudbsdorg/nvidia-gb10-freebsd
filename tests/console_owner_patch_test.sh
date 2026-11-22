#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-2-Clause
#
# console_owner_patch_test.sh - apply the NVKMS console-owner patches to the
# pinned MIT sources and check the ownership hand-off contract (Track #2448).

set -u
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$repo/scripts/lib.sh"
WORK=${GB10_WORK:-$HOME/work/gb10}
ver=$(sources_get "$repo/SOURCES" ogkm_tag) || { echo "FAIL: no ogkm_tag in SOURCES"; exit 1; }
OGKMSRC=$WORK/sources/open-gpu-kernel-modules-$ver

mkdir -p "$repo/tmp"
TMPD=$(mktemp -d "$repo/tmp/console-owner-patch-test.XXXXXXXX") || exit 1
trap 'rm -rf -- "$TMPD"' EXIT INT TERM
SRC=$TMPD/src

passed=0
failed=0
ok() { echo "PASS: $1"; passed=$((passed + 1)); }
bad() { echo "FAIL: $1"; failed=$((failed + 1)); }

API=src/nvidia-modeset/interface/nvkms-api.h
TYPES=src/nvidia-modeset/include/nvkms-types.h
CORE=src/nvidia-modeset/src/nvkms.c
KAPI_H=src/nvidia-modeset/kapi/interface/nvkms-kapi.h
KAPI_C=src/nvidia-modeset/kapi/src/nvkms-kapi.c

for f in "$API" "$TYPES" "$CORE" "$KAPI_H" "$KAPI_C"; do
	[ -f "$OGKMSRC/$f" ] || { echo "FAIL: missing $OGKMSRC/$f"; exit 1; }
	mkdir -p "$SRC/$(dirname "$f")"
	cp "$OGKMSRC/$f" "$SRC/$f"
done

apply_one() {
	if [ ! -f "$1" ]; then
		echo "missing $1"
		return 1
	fi
	patch -d "$2" -p0 -E -s -i "$1"
}

for p in \
    patch-src_nvidia-modeset_interface_nvkms-api.h \
    patch-src_nvidia-modeset_include_nvkms-types.h \
    patch-src_nvidia-modeset_src_nvkms.c; do
	[ -f "$repo/patches/ogkm/$p" ] || bad "the required patch $p is missing"
done

patched=1
for p in "$repo"/patches/ogkm/patch-*; do
	case ${p##*/} in
	patch-src_nvidia-modeset_interface_nvkms-api.h|\
	patch-src_nvidia-modeset_include_nvkms-types.h|\
	patch-src_nvidia-modeset_src_nvkms.c|\
	patch-src_nvidia-modeset_kapi_interface_nvkms-kapi.h|\
	patch-src_nvidia-modeset_kapi_src_nvkms-kapi.c)
		apply_one "$p" "$SRC" || patched=0
		;;
	esac
done
[ "$patched" -eq 1 ] && ok "the console-owner OGKM patches apply" \
    || bad "a console-owner OGKM patch does not apply"

# Remove C comments before source grep checks, so a commented-out call cannot
# satisfy one.  Strings are not parsed; none of the checked tokens occurs in a
# string in these functions.
# Time: O(n^2) worst case for n input bytes because base awk substr copies the
#       remaining line after each comment delimiter; linear without comments.
# Space: O(n) for the largest input line and its stripped copy.
strip_comments() {
	awk '
	BEGIN { block = 0 }
	{
		text = $0
		out = ""
		while (length(text) > 0) {
			if (block) {
				if (!match(text, /\*\//)) {
					text = ""
					break
				}
				text = substr(text, RSTART + RLENGTH)
				block = 0
				continue
			}
			if (!match(text, /\/\*/))
				break
			out = out substr(text, 1, RSTART - 1)
			text = substr(text, RSTART + RLENGTH)
			block = 1
		}
		out = out text
		sub(/\/\/.*/, "", out)
		print out
	}'
}

function_text() {
	awk -v name="$2" '
	BEGIN {
		re = "^([A-Za-z_][A-Za-z0-9_]*[[:space:]*]+)*" name "\\("
	}
	!on && $0 ~ re { on = 1 }
	on { print }
	on && /^}/ { exit }
	' "$1" | strip_comments | tr '\n' ' '
}

check_kernel_only() {
	[ -f "$1/$CORE" ] && [ -f "$1/$API" ] || return 2
	function_text "$1/$CORE" CbsdSetConsoleOwner |
	    grep -Eq 'pOpen->clientType[[:space:]]*!=[[:space:]]*NVKMS_CLIENT_KERNEL_SPACE' || return 1
	tr '\n' ' ' < "$1/$API" |
	    grep -Eq 'NVKMS_IOCTL_FRAMEBUFFER_CONSOLE_DISABLED,[[:space:]]*NVKMS_IOCTL_CBSD_SET_CONSOLE_OWNER,' || return 1
	grep -q 'struct NvKmsCbsdSetConsoleOwnerRequest' "$1/$API" || return 1
	function_text "$1/$CORE" nvKmsIoctl |
	    grep -Eq 'ENTRY\(NVKMS_IOCTL_FRAMEBUFFER_CONSOLE_DISABLED, FramebufferConsoleDisabled\),[[:space:]]*ENTRY\(NVKMS_IOCTL_CBSD_SET_CONSOLE_OWNER, CbsdSetConsoleOwner\),' || return 1
}

check_drop_owner_helper() {
	[ -f "$1/$CORE" ] || return 2
	_t=$(function_text "$1/$CORE" CbsdDropModesetOwner)
	printf '%s\n' "$_t" | grep -Eq 'FreeSwapGroups\(pOpenDev\);.*pDevEvo->modesetOwner[[:space:]]*=[[:space:]]*NULL;.*pDevEvo->modesetOwnerOrSubOwnerChanged[[:space:]]*=[[:space:]]*TRUE;' || return 1
	printf '%s\n' "$_t" | grep -Eq 'RevokePermissionsInternal\(NVBIT\(NV_KMS_PERMISSIONS_TYPE_FLIPPING\)[[:space:]]*\|[[:space:]]*NVBIT\(NV_KMS_PERMISSIONS_TYPE_MODESET\)[[:space:]]*\|[[:space:]]*NVBIT\(NV_KMS_PERMISSIONS_TYPE_SUB_OWNER\),[[:space:]]*pDevEvo,[[:space:]]*pOpenDevExclude\);' || return 1
	function_text "$1/$CORE" GrabModesetOwnership |
	    grep -Eq 'cbsdConsoleYield\([[:space:]]*pDevEvo->cbsdConsoleArg\);.*CbsdDropModesetOwner\(pDevEvo->cbsdConsoleOwner,[[:space:]]*pOpenDev\);' || return 1
	function_text "$1/$CORE" ReleaseModesetOwnership |
	    grep -Eq 'CbsdDropModesetOwner\(pOpenDev,[[:space:]]*NULL' || return 1
}

check_grab_yield() {
	[ -f "$1/$CORE" ] || return 2
	function_text "$1/$CORE" GrabModesetOwnership |
	    grep -Eq 'if[[:space:]]*\(\(pDevEvo->modesetOwner[[:space:]]*==[[:space:]]*pDevEvo->cbsdConsoleOwner\)[[:space:]]*&&[[:space:]]*\(pOpenDev[[:space:]]*!=[[:space:]]*pDevEvo->cbsdConsoleOwner\)\)[[:space:]]*\{.*pDevEvo->cbsdConsoleYield\([[:space:]]*pDevEvo->cbsdConsoleArg\);.*CbsdDropModesetOwner\(pDevEvo->cbsdConsoleOwner,[[:space:]]*pOpenDev\);'
}

check_release_reclaim() {
	[ -f "$1/$CORE" ] || return 2
	_t=$(function_text "$1/$CORE" ReleaseModesetOwnership)
	printf '%s\n' "$_t" |
	    grep -Eq 'if[[:space:]]*\(pOpenDev[[:space:]]*==[[:space:]]*pDevEvo->cbsdConsoleOwner\)[[:space:]]*\{.*CbsdClearConsoleOwner\(pDevEvo\);.*\}[[:space:]]*else[[:space:]]+if[[:space:]]*\(pDevEvo->cbsdConsoleOwner[[:space:]]*!=[[:space:]]*NULL\)[[:space:]]*\{.*pDevEvo->cbsdConsoleReclaim\(pDevEvo->cbsdConsoleArg\);.*\}[[:space:]]*else[[:space:]]*\{.*pDevEvo->handleConsoleHotplugs[[:space:]]*=[[:space:]]*TRUE;.*RestoreConsole\(pDevEvo\);' || return 1
	[ "$(printf '%s\n' "$_t" | grep -c 'RestoreConsole(pDevEvo);')" -eq 1 ] || return 1
	[ "$(printf '%s\n' "$_t" | grep -c 'cbsdConsoleReclaim(pDevEvo->cbsdConsoleArg);')" -eq 1 ] || return 1
}

check_clear_hotplugs() {
	[ -f "$1/$CORE" ] || return 2
	function_text "$1/$CORE" CbsdClearConsoleOwner |
	    grep -Eq 'cbsdConsoleArg[[:space:]]*=[[:space:]]*NULL;.*if[[:space:]]*\(pDevEvo->modesetOwner[[:space:]]*==[[:space:]]*NULL\)[[:space:]]*\{[[:space:]]*pDevEvo->handleConsoleHotplugs[[:space:]]*=[[:space:]]*TRUE;[[:space:]]*RestoreConsole\(pDevEvo\);[[:space:]]*\}[[:space:]]*else[[:space:]]*\{[[:space:]]*pDevEvo->handleConsoleHotplugs[[:space:]]*=[[:space:]]*FALSE;' || return 1
	_t=$(function_text "$1/$CORE" CbsdSetConsoleOwner)
	printf '%s\n' "$_t" | grep -Eq 'CbsdClearConsoleOwner\(pDevEvo\);' || return 1
	! printf '%s\n' "$_t" | grep -Eq 'CbsdClearConsoleOwner\(pDevEvo\);.*handleConsoleHotplugs[[:space:]]*='
}

check_owner_reset_sites() {
	[ -f "$1/$CORE" ] || return 2
	_t=$(strip_comments < "$1/$CORE" | tr '\n' ' ')
	[ "$(printf '%s\n' "$_t" | grep -Eo 'pDevEvo->modesetOwner[[:space:]]*=[[:space:]]*NULL' | wc -l | tr -d ' ')" -eq 1 ] || return 1
	function_text "$1/$CORE" CbsdDropModesetOwner |
	    grep -Eq 'pDevEvo->modesetOwner[[:space:]]*=[[:space:]]*NULL' || return 1
	function_text "$1/$CORE" FreeDeviceReference |
	    grep -Eq 'CbsdClearConsoleOwner\(pOpenDev->pDevEvo\);.*ReleaseModesetOwnership\(pOpenDev\);'
}

check_reclaim_paths() {
	[ -f "$1/$CORE" ] || return 2
	function_text "$1/$CORE" ConsoleRestoreTimerFired |
	    grep -Eq 'if \(pDevEvo->modesetOwner == NULL[[:space:]]*&&[[:space:]]*\(pDevEvo->handleConsoleHotplugs[[:space:]]*\|\|[[:space:]]*pDevEvo->cbsdConsoleOwner != NULL\)\).*if \(pDevEvo->cbsdConsoleOwner != NULL\).*cbsdConsoleReclaim\(pDevEvo->cbsdConsoleArg\);.*\} else \{.*nvEvoRestoreConsole' || return 1
	function_text "$1/$CORE" nvKmsResume |
	    grep -Eq 'if \(pDevEvo->modesetOwner == NULL\).*if \(pDevEvo->cbsdConsoleOwner != NULL\).*cbsdConsoleReclaim\(pDevEvo->cbsdConsoleArg\);.*\} else \{.*RestoreConsole\(pDevEvo\);'
}

check_free_clears() {
	[ -f "$1/$CORE" ] || return 2
	function_text "$1/$CORE" CbsdClearConsoleOwner |
	    grep -Eq 'cbsdConsoleOwner = NULL;.*cbsdConsoleYield = NULL;.*cbsdConsoleReclaim = NULL;.*cbsdConsoleArg = NULL;' || return 1
	function_text "$1/$CORE" FreeDeviceReference |
	    grep -Eq '\{[[:space:]]*if[[:space:]]*\(pOpenDev->pDevEvo->cbsdConsoleOwner[[:space:]]*==[[:space:]]*pOpenDev\)[[:space:]]*\{[[:space:]]*CbsdClearConsoleOwner\(pOpenDev->pDevEvo\);[[:space:]]*\}' || return 1
	function_text "$1/$CORE" FreeDeviceReference |
	    grep -Eq 'CbsdClearConsoleOwner\(pOpenDev->pDevEvo\);[[:space:]]*\}[[:space:]]*DisableRemainingVblankSyncObjects'
}

check_table_fill() {
	[ -f "$1/$KAPI_C" ] || return 2
	function_text "$1/$KAPI_C" SetConsoleOwner |
	    grep -Eq 'nvkms_ioctl_from_kapi\(device->pKmsOpen,[[:space:]]*NVKMS_IOCTL_CBSD_SET_CONSOLE_OWNER' || return 1
	tr '\n' ' ' < "$1/$KAPI_C" |
	    grep -Eq 'funcsTable->setConsoleOwner[[:space:]]*=[[:space:]]*SetConsoleOwner;'
}

# Time: O(n), for n bytes in the two callback-contract comments.
# Space: O(n), for one normalized header at a time.
check_callback_contract() {
	[ -f "$1/$KAPI_H" ] && [ -f "$1/$API" ] || return 2
	for _f in "$1/$KAPI_H" "$1/$API"; do
		_t=$(sed 's/^[[:space:]]*\*//' "$_f" | tr '\n' ' ' | tr -s ' ')
		printf '%s\n' "$_t" | grep -Eq 'Both callbacks run with the NVKMS lock held' || return 1
		printf '%s\n' "$_t" | grep -Eq 'must not call into the KAPI table' || return 1
		printf '%s\n' "$_t" | grep -Eq 'or take a lock that a KAPI caller holds' || return 1
		printf '%s\n' "$_t" | grep -Eq 'reclaim may be called more than once for one release' || return 1
		printf '%s\n' "$_t" | grep -Eq 'it must be idempotent' || return 1
		printf '%s\n' "$_t" | grep -Eq 'yield is called once per grab' || return 1
	done
}

check_setconsole_logging() {
	[ -f "$1/$KAPI_C" ] || return 2
	_t=$(function_text "$1/$KAPI_C" SetConsoleOwner | sed 's/"[[:space:]]*"//g')
	printf '%s\n' "$_t" | grep -Eq 'nvKmsKapiLogDevice\(device,[[:space:]]*"NVKMS SetConsoleOwner: the KAPI device has no NVKMS device handle' || return 1
	printf '%s\n' "$_t" | grep -Eq 'nvKmsKapiLogDevice\(device,[[:space:]]*"NVKMS SetConsoleOwner: the ioctl was refused' || return 1
	printf '%s\n' "$_t" | grep -Eq 'not a kernel client, not the modeset owner, or mismatched callbacks' || return 1
	! printf '%s\n' "$_t" | grep -q 'nvKmsKapiLogDeviceDebug'
}

run_check() {
	if "$2" "$1"; then
		ok "$3"
	else
		bad "$3 (check status $?)"
	fi
}

plant() {
	_t=$TMPD/plant-$1
	rm -rf "$_t"
	mkdir -p "$_t"
	cp -R "$SRC"/. "$_t"/
	sed -e "$3" "$SRC/$2" > "$_t/$2"
	if cmp -s "$SRC/$2" "$_t/$2"; then
		bad "control $1: the planted change changed nothing (stale test)"
		return
	fi
	"$4" "$_t"
	_r=$?
	[ "$_r" -eq 1 ] && ok "control: $1 is detected" \
	    || bad "control: $1 was not detected cleanly (status $_r)"
}

plant_pass() {
	_t=$TMPD/plant-$1
	rm -rf "$_t"
	mkdir -p "$_t"
	cp -R "$SRC"/. "$_t"/
	sed -e "$3" "$SRC/$2" > "$_t/$2"
	if cmp -s "$SRC/$2" "$_t/$2"; then
		bad "control $1: the planted change changed nothing (stale test)"
		return
	fi
	"$4" "$_t"
	_r=$?
	[ "$_r" -eq 0 ] && ok "control: $1 still passes" \
	    || bad "control: $1 changed the result (status $_r)"
}

run_check "$SRC" check_kernel_only "the console-owner ioctl is kernel-only and last"
run_check "$SRC" check_drop_owner_helper "one helper drops ownership for both release and yield"
run_check "$SRC" check_grab_yield "Grab yields only for a different client while the console owns modeset"
run_check "$SRC" check_release_reclaim "Release reclaims without RestoreConsole only for another releaser"
run_check "$SRC" check_clear_hotplugs "clearing the console owner owns the hotplug rule and restores an unowned display"
run_check "$SRC" check_owner_reset_sites "every modeset-owner reset is in the helper and close clears before release"
run_check "$SRC" check_reclaim_paths "resume and the console timer reclaim instead of restoring"
run_check "$SRC" check_free_clears "the per-open free path clears all console-owner fields first"
run_check "$SRC" check_table_fill "the KAPI wrapper issues the ioctl and fills setConsoleOwner"
run_check "$SRC" check_callback_contract "the KAPI and ioctl comments state the synchronous callback contract"
run_check "$SRC" check_setconsole_logging "SetConsoleOwner logs normal-level failure reasons"

plant user-space-console-owner "$CORE" \
    's/pOpen->clientType != NVKMS_CLIENT_KERNEL_SPACE/0/' check_kernel_only
plant drop-helper-without-free "$CORE" \
    '/^CbsdDropModesetOwner/,/^}/s/FreeSwapGroups(pOpenDev);/ /' check_drop_owner_helper
plant grab-yields-for-non-console "$CORE" \
    's/pDevEvo->modesetOwner == pDevEvo->cbsdConsoleOwner/NV_TRUE/' check_grab_yield
plant release-without-releaser-guard "$CORE" \
    '/^static NvBool ReleaseModesetOwnership/,/^}/s/if (pOpenDev == pDevEvo->cbsdConsoleOwner)/if (NV_FALSE)/' check_release_reclaim
plant clear-without-restore "$CORE" \
    '/^CbsdClearConsoleOwner/,/^}/s/RestoreConsole(pDevEvo);/ /' check_clear_hotplugs
plant owner-reset-outside-helper "$CORE" \
    '/ReleaseModesetOwnership(pOpenDev);/i\
        pOpenDev->pDevEvo->modesetOwner = NULL;' check_owner_reset_sites
plant timer-hotplug-gates-reclaim "$CORE" \
    's/pDevEvo->handleConsoleHotplugs || pDevEvo->cbsdConsoleOwner != NULL/pDevEvo->handleConsoleHotplugs/' check_reclaim_paths
plant resume-without-reclaim "$CORE" \
    '/^void nvKmsResume/,/^}/s/if (pDevEvo->cbsdConsoleOwner != NULL)/if (NV_FALSE)/' check_reclaim_paths
plant free-without-clear "$CORE" \
    '/CbsdClearConsoleOwner(pOpenDev->pDevEvo);/d' check_free_clears
plant kapi-without-console-owner-fill "$KAPI_C" \
    '/funcsTable->setConsoleOwner = SetConsoleOwner;/d' check_table_fill
plant callback-contract-without-idempotence "$KAPI_H" \
    's/it must be idempotent/it must be repeatable/' check_callback_contract
plant setconsole-debug-only-logging "$KAPI_C" \
    's/nvKmsKapiLogDevice(/nvKmsKapiLogDeviceDebug(/g' check_setconsole_logging
plant_pass grab-yield-split-over-two-lines "$CORE" \
    's/pDevEvo->cbsdConsoleYield(pDevEvo->cbsdConsoleArg);/pDevEvo->cbsdConsoleYield(\
            pDevEvo->cbsdConsoleArg);/' check_grab_yield

echo "passed: $passed failed: $failed"
[ "$failed" -eq 0 ]

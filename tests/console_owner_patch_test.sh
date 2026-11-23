#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-2-Clause
#
# console_owner_patch_test.sh - apply the NVKMS console-owner patches to the
# pinned MIT sources and check the ownership hand-off contract (Track #2448).
#
# Besides the ownership contract it checks that SetConsoleOwner logs its
# failure reasons through nvKmsKapiLogDevice and that the header patch
# defines that macro once, unconditionally, as a warning-level log of the
# GPU id taken from its own device argument, with the same prefix as the
# pinned Debug macro. A missing macro would be an undefined symbol at module
# load: in this build clang reports -Wimplicit-function-declaration only as a
# warning for nvidia-modeset, so the object still links and the .ko ends up
# with an undefined nvKmsKapiLogDevice; nothing but a check like these sees
# it before kldload.

set -u
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$repo/scripts/lib.sh"
WORK=${GB10_WORK:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)/work}
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
KAPI_I=src/nvidia-modeset/kapi/include/nvkms-kapi-internal.h

for f in "$API" "$TYPES" "$CORE" "$KAPI_H" "$KAPI_C" "$KAPI_I"; do
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

# Every OGKM patch this test applies, in lexical order; the one list for
# both the presence check and the apply loop.
OGKM_PATCHES="
patch-src_nvidia-modeset_include_nvkms-types.h
patch-src_nvidia-modeset_interface_nvkms-api.h
patch-src_nvidia-modeset_kapi_include_nvkms-kapi-internal.h
patch-src_nvidia-modeset_kapi_interface_nvkms-kapi.h
patch-src_nvidia-modeset_kapi_src_nvkms-kapi.c
patch-src_nvidia-modeset_src_nvkms.c
"
for p in $OGKM_PATCHES; do
	[ -f "$repo/patches/ogkm/$p" ] || bad "the required patch $p is missing"
done

patched=1
for p in $OGKM_PATCHES; do
	apply_one "$repo/patches/ogkm/$p" "$SRC" || patched=0
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

# The text of the #define of the macro named $2 (a name followed by "("),
# continuation lines joined and comments removed, tabs and runs of blanks
# squeezed; empty when it is not defined.
# Time: O(n) for the header's n bytes. Space: O(n).
macro_define() {
	strip_comments < "$1" | sed -e ':a' -e '/\\$/{N;s/\\\n/ /;ba' -e '}' |
	    grep -E "^[[:space:]]*#[[:space:]]*define[[:space:]]+$2\\(" | tr -s ' \t' '  '
}

logdevice_define() {
	macro_define "$1" nvKmsKapiLogDevice
}

# The call is in SetConsoleOwner, which must log its failure reasons.
check_logdevice_called() {
	[ -f "$1/$KAPI_C" ] || return 2
	function_text "$1/$KAPI_C" SetConsoleOwner |
	    grep -Eq '(^|[^A-Za-z0-9_])nvKmsKapiLogDevice\('
}

# The header defines the name the .c file calls (the patched header only;
# the pinned one defines just the Debug variants).
check_logdevice_defined() {
	[ -f "$1/$KAPI_I" ] || return 2
	[ -n "$(logdevice_define "$1/$KAPI_I")" ]
}

# Release builds: the body calls nvEvoLog at exactly warning level (the docs
# promise that level) and never a Debug logger, which a non-DEBUG build
# compiles away.
check_logdevice_macro() {
	[ -f "$1/$KAPI_I" ] || return 2
	_d=$(logdevice_define "$1/$KAPI_I")
	[ -n "$_d" ] || return 1
	printf '%s\n' "$_d" | grep -Eq '[^A-Za-z_]nvEvoLog\(EVO_LOG_WARN,' || return 1
	! printf '%s\n' "$_d" | grep -Eq 'nvEvoLogDebug|nvEvoLogDevDebug'
}

# The parameter name __device is pinned here so that a capture of the
# caller's outer variable "device" (what the pinned Debug macro does) can be
# told apart from the macro's own parameter: the body must read
# (__device)->gpuId and no other "device->gpuId".
check_logdevice_own_arg() {
	[ -f "$1/$KAPI_I" ] || return 2
	_d=$(logdevice_define "$1/$KAPI_I")
	[ -n "$_d" ] || return 1
	printf '%s\n' "$_d" | grep -Eq 'define nvKmsKapiLogDevice\(__device, __format, \.\.\.\)' || return 1
	printf '%s\n' "$_d" | grep -Fq '(__device)->gpuId' || return 1
	! printf '%s\n' "$_d" | grep -Eq '[^_(]device->gpuId'
}

# One #define, no #undef, and the define sits at conditional depth 1: inside
# only the include guard (#ifndef __NVKMS_KAPI_INTERNAL_H__, which the pinned
# header has), so no #if DEBUG wraps it and no later define shadows it.
check_logdevice_unconditional() {
	[ -f "$1/$KAPI_I" ] || return 2
	grep -q '^#ifndef __NVKMS_KAPI_INTERNAL_H__' "$1/$KAPI_I" || return 1
	strip_comments < "$1/$KAPI_I" | awk '
	BEGIN { d = 0; n = 0; u = 0; bad = 0 }
	/^[ \t]*#[ \t]*(if|ifdef|ifndef)([ \t(]|$)/ { d++; next }
	/^[ \t]*#[ \t]*endif/ { d--; next }
	/^[ \t]*#[ \t]*define[ \t]+nvKmsKapiLogDevice\(/ { n++; if (d != 1) bad = 1 }
	/^[ \t]*#[ \t]*undef[ \t]+nvKmsKapiLogDevice([ \t]|$)/ { u++ }
	END { exit !(n == 1 && u == 0 && !bad) }'
}

# The string literal that precedes __format in a joined define.
macro_prefix() {
	sed -n 's/.*\("[^"]*"\)[[:space:]]*__format.*/\1/p'
}

check_logdevice_prefix() {
	[ -f "$1/$KAPI_I" ] || return 2
	_a=$(logdevice_define "$1/$KAPI_I" | macro_prefix)
	_b=$(macro_define "$1/$KAPI_I" nvKmsKapiLogDeviceDebug | macro_prefix)
	[ -n "$_a" ] && [ -n "$_b" ] && [ "$_a" = "$_b" ]
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
run_check "$SRC" check_logdevice_called "nvkms-kapi.c (SetConsoleOwner) calls nvKmsKapiLogDevice"
run_check "$SRC" check_logdevice_defined "the patched header defines nvKmsKapiLogDevice, which nvkms-kapi.c calls"
run_check "$SRC" check_logdevice_macro "nvKmsKapiLogDevice logs at warning level in release builds"
run_check "$SRC" check_logdevice_own_arg "nvKmsKapiLogDevice reads the GPU id from its own device argument"
run_check "$SRC" check_logdevice_unconditional "nvKmsKapiLogDevice is defined once, unconditionally, and never undefined"
run_check "$SRC" check_logdevice_prefix "nvKmsKapiLogDevice uses the same prefix as nvKmsKapiLogDeviceDebug"

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
plant logdevice-not-called "$KAPI_C" \
    's/nvKmsKapiLogDevice(/nvKmsKapiLogX(/g' check_logdevice_called
plant logdevice-macro-deleted "$KAPI_I" \
    '/define nvKmsKapiLogDevice(/,/gpuId/d' check_logdevice_defined
plant logdevice-uses-debug-log "$KAPI_I" \
    '/define nvKmsKapiLogDevice(/,/gpuId/s/nvEvoLog(/nvEvoLogDebug(/' check_logdevice_macro
plant logdevice-error-level "$KAPI_I" \
    '/define nvKmsKapiLogDevice(/,/gpuId/s/EVO_LOG_WARN/EVO_LOG_ERROR/' check_logdevice_macro
plant logdevice-extra-debug-call "$KAPI_I" \
    '/define nvKmsKapiLogDevice(/,/gpuId/s/##__VA_ARGS__)/##__VA_ARGS__); nvEvoLogDebug(EVO_LOG_INFO, "x")/' check_logdevice_macro
plant logdevice-uses-outer-device "$KAPI_I" \
    '/define nvKmsKapiLogDevice(/,/gpuId/s/(__device)->gpuId/device->gpuId/' check_logdevice_own_arg
plant logdevice-reads-outer-device-too "$KAPI_I" \
    '/define nvKmsKapiLogDevice(/,/gpuId/s/(__device)->gpuId, ##/(__device)->gpuId, device->gpuId, ##/' check_logdevice_own_arg
plant logdevice-under-ifdef-debug "$KAPI_I" \
    '/define nvKmsKapiLogDevice(/i\
#ifdef DEBUG
/define nvKmsKapiLogDevice(/,/gpuId/{
/gpuId/a\
#endif
}' check_logdevice_unconditional
plant logdevice-undefined-after-define "$KAPI_I" \
    '/define nvKmsKapiLogDevice(/,/gpuId/{
/gpuId/a\
#undef nvKmsKapiLogDevice
}' check_logdevice_unconditional
plant logdevice-second-define "$KAPI_I" \
    '/define nvKmsKapiLogDevice(/,/gpuId/{
/gpuId/a\
#define nvKmsKapiLogDevice(__device, __format, ...)
}' check_logdevice_unconditional
plant logdevice-prefix-drift "$KAPI_I" \
    '/define nvKmsKapiLogDevice(/,/gpuId/s/\[kapi\]\[GPU Id/[kapi][GPU/' check_logdevice_prefix
plant_pass grab-yield-split-over-two-lines "$CORE" \
    's/pDevEvo->cbsdConsoleYield(pDevEvo->cbsdConsoleArg);/pDevEvo->cbsdConsoleYield(\
            pDevEvo->cbsdConsoleArg);/' check_grab_yield

echo "passed: $passed failed: $failed"
[ "$failed" -eq 0 ]

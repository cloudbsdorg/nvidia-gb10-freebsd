#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# kernel_patches_testboot_kit_test.sh - static checks of the test-boot kit in
# tests/kernel-patches-testboot/ (Track #2442); no root, no boot environment:
#   (a) every kit script parses (sh -n);
#   (b) testboot-return matches the sha256 pin in VENDOR;
#   (c) the recorder arms the dead-man timer before it loads amdgpu, loads
#       nothing without it, and its default is a positive number of minutes;
#   (d) the recorder checks every sysctl the patches add: each SYSCTL_* name
#       in kernel-patches/000*.diff appears in the recorder;
#   (e) the recorder's dmesg strings are the ones the patches print (the
#       printf format with %s / %d filled the way the recorder expects), and
#       every strings(1) needle in make-be.sh/check-be.sh comes from them;
#   (f) make-be.sh never activates a boot environment (no "bectl activate");
#   (g) the recorder has no /home/ path and runs both GPU jobs through su -m;
#   (h) make-be.sh writes devmatch_blocklist and removes testboot-return.hold;
#   (i) check-be.sh rejects a malformed -N before checking for root.

set -u
LC_ALL=C
PATH=/sbin:/bin:/usr/sbin:/usr/bin:$PATH
export LC_ALL PATH

repo=$(cd -- "$(dirname -- "$0")/.." && pwd) || exit 1
kit=$repo/tests/kernel-patches-testboot
rc=$kit/kernel_patches_testboot
fails=0
ok() { printf 'ok    %s\n' "$*"; }
bad() { printf 'FAIL  %s\n' "$*"; fails=$((fails + 1)); }

for f in make-be.sh check-be.sh kernel_patches_testboot testboot-return; do
	if sh -n "$kit/$f" 2> /dev/null; then ok "sh -n $f"; else bad "sh -n $f"; fi
done

want=$(sed -n 's/^sha256 *= *\([0-9a-f]\{64\}\)$/\1/p' "$kit/VENDOR")
got=$(sha256 -q "$kit/testboot-return" 2> /dev/null || sha256sum "$kit/testboot-return" | cut -d' ' -f1)
[ -n "$want" ] && [ "$got" = "$want" ] && ok "testboot-return matches VENDOR" || bad "testboot-return is $got, VENDOR pins $want"

dm=$(grep -n 'shutdown -r "+$kernel_patches_testboot_deadman"' "$rc" | head -1 | cut -d: -f1)
ld=$(grep -n 'kldload amdgpu >' "$rc" | head -1 | cut -d: -f1)
gate=$(grep -n 'if \[ "$DM_OK" != 1 \]; then' "$rc" | head -1 | cut -d: -f1)
[ -n "$dm" ] && [ -n "$ld" ] && [ "$dm" -lt "$ld" ] && ok "dead-man (line $dm) before kldload amdgpu (line $ld)" ||
    bad "dead-man ${dm:-none}, kldload amdgpu ${ld:-none}"
[ -n "$gate" ] && [ -n "$ld" ] && [ "$gate" -lt "$ld" ] && ok "no dead-man, no load (line $gate)" || bad "no DM_OK gate before the load"
def=$(sed -n 's/^: "${kernel_patches_testboot_deadman:=\([0-9]*\)}"$/\1/p' "$rc")
[ -n "$def" ] && [ "$def" -gt 0 ] && ok "dead-man default $def minutes" || bad "dead-man default '${def}'"
if grep -qF 'pgrep -f' "$rc" || grep -qF 'pkill -f' "$rc"; then
	bad "dead-man uses a full-command process match"
else
	ok "dead-man never uses pgrep -f or pkill -f"
fi
grep -qF 'pgrep -u 0 -x shutdown' "$rc" && ok "dead-man confirmation falls back to root's shutdown process" ||
    bad "dead-man confirmation does not use pgrep -u 0 -x shutdown"
grep -qF 'pkill -u 0 -x shutdown' "$rc" && ok "dead-man cancellation targets root's shutdown process" ||
    bad "dead-man cancellation does not use pkill -u 0 -x shutdown"

names=$(sed -n 's/^+SYSCTL_[A-Z]*(_\([a-z0-9_]*\), *OID_AUTO, *\([a-z0-9_]*\),.*/\1 \2/p' "$repo"/kernel-patches/000*.diff |
    while read -r p l; do printf '%s.%s\n' "$(printf '%s' "$p" | tr _ .)" "$l"; done)
[ -n "$names" ] || bad "no sysctls found in the patches"
for n in $names; do
	grep -qF -- "$n" "$rc" && ok "the recorder reads $n" || bad "the recorder does not read $n"
done

row_names=$(awk '/^[[:space:]]*#/ { next } { for (i = 1; i <= NF; i++) if (($i == "row" || $i == "running" || $i == "expect") && $(i + 1) ~ /^[a-z0-9-]+$/) print $(i + 1) }' "$rc" | sort -u)
row_header=$(sed -n '/^# Rows go to results/,/^# Then the run/p' "$rc")
missing_rows=
for n in $row_names; do
	printf '%s\n' "$row_header" | grep -qF "#   $n" || missing_rows="$missing_rows $n"
done
if [ -n "$row_names" ] && [ -z "$missing_rows" ]; then
	ok "the recorder header lists every literal row, running and expect name"
else
	bad "recorder header is missing:${missing_rows:- row-name extraction failed}"
fi

# the format strings in the patches, filled as the recorder greps them
in_patch() {
	grep -qF -- "$1" "$repo"/kernel-patches/0002-linuxkpi-altra-erratum-82288.diff \
	    "$repo"/kernel-patches/0003-arm64-kernel-alignment-fixup.diff \
	    "$repo"/kernel-patches/0004-pci-host-generic-altra-ecam.diff && return 0
	# 0002 splits this one printf format into two adjacent C string literals.
	[ "$1" = 'linuxkpi: Ampere Altra erratum 82288: PCIe write-combining mapped as Device (mode %d)' ] || return 1
	grep -qF '"linuxkpi: Ampere Altra erratum 82288: PCIe "' "$repo"/kernel-patches/0002-linuxkpi-altra-erratum-82288.diff &&
	    grep -qF '"write-combining mapped as Device (mode %d)\n", mode);' "$repo"/kernel-patches/0002-linuxkpi-altra-erratum-82288.diff
}
chk_fmt() {	# chk_fmt <printf format in the patch> <filled string the recorder greps>
	if in_patch "$1" && grep -qF -- "$2" "$rc"; then ok "dmesg: $2"
	else bad "dmesg string: patch has '$1'? recorder has '$2'?"; fi
}
chk_fmt 'arm64: kernel alignment-fault fixup enabled (%s)' 'arm64: kernel alignment-fault fixup enabled (Ampere Altra)'
chk_fmt 'linuxkpi: Ampere Altra erratum 82288: PCIe write-combining mapped as Device (mode %d)' \
    'linuxkpi: Ampere Altra erratum 82288: PCIe write-combining mapped as Device (mode 1)'
chk_fmt '32-bit config space reads only' '32-bit config space reads only'

# Every strings(1) needle in the root-side scripts must come from the patches;
# both scripts must check all three complete printf formats.
chk_kernel_strings() {
	_ks_file=$1
	_ks_list=$(sed -n '/for _s in/,/; do$/p' "$_ks_file" | sed -n "s/^[[:space:]]*'\([^']*\)'.*/\1/p")
	[ -n "$_ks_list" ] || bad "no strings(1) list found in $_ks_file"
	while IFS= read -r _ks; do
		in_patch "$_ks" && ok "$(basename "$_ks_file"): patch string: $_ks" || bad "$(basename "$_ks_file"): string not in patches: $_ks"
	done <<EOF
$_ks_list
EOF
	while IFS= read -r _want; do
		if printf '%s\n' "$_ks_list" | grep -qxF -- "$_want"; then
			ok "$(basename "$_ks_file") checks the complete patch format: $_want"
		else
			bad "$(basename "$_ks_file") lacks the complete patch format: $_want"
		fi
	done <<'EOF'
arm64: kernel alignment-fault fixup enabled (%s)
linuxkpi: Ampere Altra erratum 82288: PCIe write-combining mapped as Device (mode %d)
32-bit config space reads only
EOF
}
chk_kernel_strings "$kit/make-be.sh"
chk_kernel_strings "$kit/check-be.sh"

if grep -q '/home/' "$rc"; then
	bad "the recorder contains a /home/ path"
else
	ok "the recorder contains no /home/ path"
fi
if grep -q '/home/' "$kit/make-be.sh"; then
	bad "make-be.sh contains a /home/ path"
else
	ok "make-be.sh contains no /home/ path"
fi

if grep -qF 'as_owner timeout 120 vulkaninfo --summary' "$rc" &&
    grep -qF 'as_owner timeout 600 "$kernel_patches_testboot_bench"' "$rc" &&
    grep -qF 'tar -C "$OUT" -cf - . | as_owner /bin/sh -c' "$rc" &&
    grep -qF 'as_owner /bin/sh -c' "$kit/make-be.sh"; then
	ok "GPU jobs, copy-out and hash-list write run through as_owner and /bin/sh"
else
	bad "as_owner is not used for the GPU jobs, copy-out and hash-list write"
fi
if grep -nF 'su -m' "$rc" "$kit/make-be.sh" | grep -vF '/bin/sh' | grep -q .; then
	bad "a su -m line does not name /bin/sh"
else
	ok "every su -m line names /bin/sh"
fi
_quoted=$(sh -c '/bin/sh -c '\''exec "$0" "$@"'\'' "$0" "$@"' printf '%s|' a 'b c')
[ "$_quoted" = 'a|b c|' ] && ok "as_owner quoting preserves positional parameters" ||
    bad "as_owner quoting test returned '$_quoted'"

_filtered=$(
	{
		sed -n '/^filter_kld_list()$/,/^}/p' "$kit/make-be.sh"
		printf '%s\n' 'filter_kld_list "if_aq /boot/modules/amdgpu.ko vmm"'
	} | sh
)
if [ "$_filtered" = 'if_aq vmm' ] && grep -qF 'case ${m##*/} in' "$kit/check-be.sh"; then
	ok "kld_list filters amdgpu by basename: $_filtered"
else
	bad "kld_list basename filter returned '$_filtered' or check-be.sh does not use it"
fi

if grep -qF 'devmatch_blocklist="%s amdgpu"' "$kit/make-be.sh" &&
    grep -qF '> "$MNT/etc/rc.conf.d/devmatch"' "$kit/make-be.sh" &&
    grep -qF 'rm -f "$MNT/var/db/testboot-return.hold"' "$kit/make-be.sh"; then
	ok "make-be.sh blocks devmatch amdgpu and removes testboot-return.hold"
else
	bad "make-be.sh does not write devmatch_blocklist and remove testboot-return.hold"
fi

if grep -nE '(^|[[:space:]])for[[:space:]]+(_cfg_owner|_cfg_bench|_cfg_model)[[:space:]]+in([[:space:]]|$)' "$kit/check-be.sh" | grep -q . ||
    ! grep -qF 'model exists ($_cfg_model; make-be.sh -M)" [ -f "$_cfg_model" ]' "$kit/check-be.sh"; then
	bad "check-be.sh can clobber a saved GPU setting or does not check the saved model"
else
	ok "check-be.sh keeps GPU settings out of loop variables and checks the saved model"
fi

if grep -nF 'sysrc -R "$MNT" -n devmatch_blocklist' "$kit/check-be.sh" "$kit/make-be.sh" | grep -q .; then
	bad "a test-boot script still reads devmatch_blocklist with sysrc"
else
	ok "test-boot scripts do not read devmatch_blocklist with sysrc"
fi

_out=$(cd "$kit" && env -u GB10_WORK sh make-be.sh -s . -o . 2>&1)
_rc=$?
if [ "$_rc" = 2 ] && [ "$_out" = 'make-be.sh: give -w WORK or set GB10_WORK' ]; then
	ok "make-be.sh requires -w WORK or GB10_WORK before the root check"
else
	bad "make-be.sh missing WORK: status $_rc, output: $_out"
fi

_out=$(sh "$kit/check-be.sh" -s . -o . -N "a'b" x 2>&1)
_rc=$?
if [ "$_rc" = 2 ] && printf '%s\n' "$_out" | grep -qF 'bad NORMAL_BE name'; then
	ok "check-be.sh refuses a bad -N before the root check"
else
	bad "check-be.sh bad -N: status $_rc, output: $_out"
fi

if grep -n 'bectl activate' "$kit/make-be.sh" | grep -v 'echo' | grep -v '^[0-9]*:#' | grep -q .; then
	bad "make-be.sh runs bectl activate"
else
	ok "make-be.sh never activates"
fi

printf 'kernel_patches_testboot_kit_test: %s failed\n' "$fails"
[ "$fails" = 0 ]

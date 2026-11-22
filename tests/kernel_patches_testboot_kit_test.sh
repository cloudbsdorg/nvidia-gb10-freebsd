#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# kernel_patches_testboot_kit_test.sh - static and unprivileged runtime checks in
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
#   (g) the recorder has no personal home path and runs both GPU jobs through su -m;
#   (h) make-be.sh writes devmatch_blocklist and removes testboot-return.hold;
#   (i) check-be.sh rejects a malformed -N before checking for root;
#   (j) dead-man runtime fakes use GB10_WORK (default <repo>/work) for
#       their mktemp directory under its tmp subdirectory, never /tmp.

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

dm=$(grep -nF 'shutdown -r "+$kernel_patches_testboot_deadman" "kernel_patches_testboot dead-man: restart in $kernel_patches_testboot_deadman minutes unless the run finishes" > "$OUT/deadman.txt" 2>&1' "$rc" | head -1 | cut -d: -f1)
ld=$(grep -n 'kldload amdgpu >' "$rc" | head -1 | cut -d: -f1)
gate=$(grep -n 'if \[ "$DM_OK" != 1 \]; then' "$rc" | head -1 | cut -d: -f1)
[ -n "$dm" ] && [ -n "$ld" ] && [ "$dm" -lt "$ld" ] && ok "dead-man (line $dm) before kldload amdgpu (line $ld)" ||
    bad "dead-man ${dm:-none}, kldload amdgpu ${ld:-none}"
[ -n "$gate" ] && [ -n "$ld" ] && [ "$gate" -lt "$ld" ] && ok "no dead-man, no load (line $gate)" || bad "no DM_OK gate before the load"
def=$(sed -n 's/^: "${kernel_patches_testboot_deadman:=\([0-9]*\)}"$/\1/p' "$rc")
[ -n "$def" ] && [ "$def" -gt 0 ] && ok "dead-man default $def minutes" || bad "dead-man default '${def}'"
if grep -qF 'pgrep' "$rc" || grep -qF 'pkill' "$rc"; then
	bad "the recorder still uses pgrep or pkill"
else
	ok "the recorder has no pgrep or pkill"
fi
grep -qF 'dm_confirm "$_dm_pid" 0' "$rc" && grep -qF 'DM_CHILD=$_dm_pid' "$rc" &&
    ok "dead-man confirmation and DM_CHILD use shutdown's exact pid" ||
    bad "dead-man confirmation does not use the exact pid"
grep -qF 'kill "$DM_CHILD"' "$rc" && ok "dead-man cancellation targets only DM_CHILD" ||
    bad "dead-man cancellation does not kill the exact confirmed pid"
if grep -qF 'ps -o uid=,comm=' "$rc"; then
	bad "the recorder still uses the comma-form ps output selector"
else
	ok "the recorder has no comma-form ps output selector"
fi

# Exercise the extracted functions without invoking shutdown(8).  All fakes
# live under GB10_WORK (default <repo>/work), never /tmp, and cleanup only
# kills exact pids started by this test.
_dm_test_root=${GB10_WORK:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)/work}/tmp
if [ "$(id -u)" = 0 ]; then
	printf 'skip  dead-man runtime cases: refuse to run as root\n'
elif ! mkdir -p "$_dm_test_root"; then
	bad "cannot create dead-man test parent $_dm_test_root"
elif _dm_test_dir=$(mktemp -d "$_dm_test_root/dm-exact.XXXXXX"); then
	_dm_test_pid=
	_dm_test_gone=
	cleanup() {
		case $_dm_test_pid in
		''|*[!0-9]*) ;;
		*) kill "$_dm_test_pid" 2> /dev/null || : ;;
		esac
		case $_dm_test_gone in
		''|*[!0-9]*) ;;
		*) kill "$_dm_test_gone" 2> /dev/null || : ;;
		esac
		_dm_test_pid=
		_dm_test_gone=
		rm -rf -- "$_dm_test_dir"
	}
	trap cleanup 0
	trap 'cleanup; exit 130' 1 2 15
	mkdir -p "$_dm_test_dir/bin" "$_dm_test_dir/child"
	cp /bin/sleep "$_dm_test_dir/child/shutdown"
	cat > "$_dm_test_dir/bin/shutdown-ok" <<'EOF'
#!/bin/sh
dir=${0%/*}/..
"$dir/child/shutdown" 30 &
printf 'shutdown: [pid %s]\n' "$!" >&2
exit 0
EOF
	cat > "$_dm_test_dir/bin/shutdown-fail" <<'EOF'
#!/bin/sh
printf 'shutdown: cannot\n' >&2
exit 1
EOF
	chmod 755 "$_dm_test_dir/bin/shutdown-ok" "$_dm_test_dir/bin/shutdown-fail"
	_dm_test_pid_def=$(sed -n '/^dm_child_pid()/,/^}$/p' "$rc")
	_dm_test_confirm_def=$(sed -n '/^dm_confirm()/,/^}$/p' "$rc")
	if [ -z "$_dm_test_pid_def" ] || [ -z "$_dm_test_confirm_def" ] ||
	    ! eval "$_dm_test_pid_def
$_dm_test_confirm_def"; then
		bad "could not extract and evaluate dm_child_pid and dm_confirm"
	else
		_dm_test_uid=$(id -u)

		# Case 1: the fake shutdown prints the exact child pid and exits 0.
		"$_dm_test_dir/bin/shutdown-ok" > "$_dm_test_dir/ok.txt" 2>&1
		_dm_test_ok_status=$?
		[ "$_dm_test_ok_status" = 0 ] && ok "dead-man case 1: shutdown-ok exits 0" ||
		    bad "dead-man case 1: expected status 0, got $_dm_test_ok_status"
		_dm_test_pid=$(dm_child_pid "$_dm_test_dir/ok.txt")
		case $_dm_test_pid in
		''|*[!0-9]*)
			bad "dead-man case 1 did not print a numeric child pid"
			_dm_test_pid=
			;;
		esac
		if [ -n "$_dm_test_pid" ]; then
			_dm_test_i=0
			while [ "$(ps -o comm= -p "$_dm_test_pid" 2> /dev/null | tr -d ' ')" != shutdown ] &&
			    [ "$_dm_test_i" -lt 50 ]; do
				sleep 0.1
				_dm_test_i=$((_dm_test_i + 1))
			done
			if [ "$(ps -o comm= -p "$_dm_test_pid" 2> /dev/null | tr -d ' ')" != shutdown ]; then
				printf 'skip  dead-man case 1: child did not exec after 50 tries\n'
			elif dm_confirm "$_dm_test_pid" "$_dm_test_uid"; then
				ok "dead-man case 1: the exact live child is confirmed"
			else
				bad "dead-man case 1: the exact live child was not confirmed"
			fi
		fi

		if [ -n "$_dm_test_pid" ] &&
		    [ "$(ps -o comm= -p "$_dm_test_pid" 2> /dev/null | tr -d ' ')" = shutdown ]; then
			# Case 2: case 1's live child is a decoy; this arming must still fail.
			"$_dm_test_dir/bin/shutdown-fail" > "$_dm_test_dir/fail.txt" 2>&1
			_dm_test_fail_status=$?
			_dm_test_fail_pid=$(dm_child_pid "$_dm_test_dir/fail.txt")
			_dm_test_armed=0
			if [ "$_dm_test_fail_status" -eq 0 ] && [ -n "$_dm_test_fail_pid" ] &&
			    dm_confirm "$_dm_test_fail_pid" 0; then
				_dm_test_armed=1
			fi
			if [ "$_dm_test_fail_status" = 1 ] && [ -z "$_dm_test_fail_pid" ] &&
			    [ "$_dm_test_armed" = 0 ]; then
				ok "dead-man case 2: failed arming is rejected with a live decoy"
			else
				bad "dead-man case 2: status $_dm_test_fail_status, pid '${_dm_test_fail_pid}', armed $_dm_test_armed"
			fi

			/bin/sleep 0 &
			_dm_test_gone=$!
			wait "$_dm_test_gone" 2> /dev/null || :
			if dm_confirm "$_dm_test_gone" "$_dm_test_uid"; then
				bad "dead-man case 2: a gone pid passed while the decoy was running"
			else
				ok "dead-man case 2: a gone pid returns 1 despite the live decoy"
			fi
			if [ "$(uname -s)" = FreeBSD ]; then
				# FreeBSD ps prints the ",comm=" header for a gone pid with this
				# comma form; two -o options avoid that non-empty false positive.
				_dm_test_comma=$(ps -o uid=,comm= -p "$_dm_test_gone" 2> /dev/null)
				if [ -n "$_dm_test_comma" ]; then
					ok "FreeBSD comma-form ps prints a header for a gone pid"
				else
					bad "FreeBSD comma-form ps did not reproduce its header quirk"
				fi
			fi

			# Case 3: the same exact child must not confirm as root's process.
			if dm_confirm "$_dm_test_pid" 0; then
				bad "dead-man case 3: the test user's child passed as uid 0"
			else
				ok "dead-man case 3: the test user's child is rejected for uid 0"
			fi
		fi
	fi
	cleanup
	trap - 0 1 2 15
else
	bad "mktemp -d failed under $_dm_test_root"
fi

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

_home_pattern=/$(printf 'home')/
if grep -q "$_home_pattern" "$rc"; then
	bad "the recorder contains a personal home path"
else
	ok "the recorder contains no personal home path"
fi
if grep -q "$_home_pattern" "$kit/make-be.sh"; then
	bad "make-be.sh contains a personal home path"
else
	ok "make-be.sh contains no personal home path"
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

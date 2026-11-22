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
#   (j) dead-man runtime fakes and all other output stay under TMPDIR (default under
#       the checkout, or GB10_WORK/tmp), never /tmp;
#   (guard) no host-test path can reach the real shutdown(8).

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

# (guard) G1: install sentinels and the stub before any kit code runs.  The
# sentinels are deliberately first in PATH for every subsequent command.
# TMPDIR unset: use a directory under the checkout (never /tmp), removed at exit.
unset autoboot rc_fast rc_arg
_tmpdir_made=0
if [ -z "${TMPDIR:-}" ]; then
	TMPDIR=$repo/tmp-test
	mkdir -p "$TMPDIR" || exit 1
	_tmpdir_made=1
	export TMPDIR
fi
case $TMPDIR in /*) ;; *) printf 'guard: TMPDIR is not absolute\n' >&2; exit 1 ;; esac
TMPD=$(mktemp -d "$TMPDIR/kernel-patches-guard.XXXXXX") || exit 1
SENT=$TMPD/sent
# t_confirm PID: 0 only when that exact pid is a process named shutdown owned by us
t_confirm() { [ "$(ps -o uid= -o comm= -p "$1" 2> /dev/null | tr -d ' ')" = "$(id -u)shutdown" ]; }
# t_kill PID: kill that exact pid only after it is re-confirmed as our shutdown
t_kill()
{
	case $1 in ''|*[!0-9]*) return 0 ;; esac
	if t_confirm "$1"; then kill "$1" 2> /dev/null || :; fi
}
SENT2=$TMPD/sent2
mkdir -p "$SENT" "$SENT2" "$TMPD/child" || exit 1
cat > "$SENT/shutdown" <<'EOF'
#!/bin/sh
printf 'REACHED %s %s\n' "$0" "$*" >> "$SENT/hits"
exit 99
EOF
cat > "$SENT2/real-shutdown" <<'EOF'
#!/bin/sh
printf 'REAL REACHED %s\n' "$*" >> "$SENT2/hits"
exit 99
EOF
cp /bin/sleep "$TMPD/child/shutdown" || exit 1
cat > "$TMPD/shutdown-stub" <<'EOF'
#!/bin/sh
dir=${0%/*}
printf '%s\n' "$*" >> "$dir/stub-args"
"$dir/child/shutdown" 30 &
pid=$!
c=
i=0
while [ "$i" -lt 2000 ]; do
	c=$(ps -o comm= -p "$pid" 2> /dev/null | tr -d ' ')
	[ "$c" = shutdown ] && break
	i=$((i + 1))
done
if [ "$c" != shutdown ]; then
	kill "$pid" 2> /dev/null
	exit 1
fi
printf 'shutdown: [pid %s]\n' "$pid"
exit 0
EOF
chmod 755 "$SENT/shutdown" "$SENT2/real-shutdown" "$TMPD/shutdown-stub" "$TMPD/child/shutdown" || exit 1
export SENT SENT2
PATH=$SENT:$PATH
kernel_patches_testboot_shutdown=$TMPD/shutdown-stub
export kernel_patches_testboot_shutdown
if [ -z "$kernel_patches_testboot_shutdown" ] || [ "$kernel_patches_testboot_shutdown" = /sbin/shutdown ]; then
	printf 'guard: the harness left kernel_patches_testboot_shutdown at /sbin/shutdown\n' >&2
	exit 1
fi
if [ ! -x "$kernel_patches_testboot_shutdown" ] || [ -u "$kernel_patches_testboot_shutdown" ]; then
	printf 'guard: the shutdown stub is not a non-setuid executable\n' >&2
	exit 1
fi
ok "(guard) G1 PATH sentinel and non-setuid shutdown stub are installed"
export LC_ALL PATH

for f in make-be.sh check-be.sh kernel_patches_testboot testboot-return bare-shutdown-check.sh; do
	if sh -n "$kit/$f" 2> /dev/null; then ok "sh -n $f"; else bad "sh -n $f"; fi
done

want=$(sed -n 's/^sha256 *= *\([0-9a-f]\{64\}\)$/\1/p' "$kit/VENDOR")
got=$(sha256 -q "$kit/testboot-return" 2> /dev/null || sha256sum "$kit/testboot-return" | cut -d' ' -f1)
[ -n "$want" ] && [ "$got" = "$want" ] && ok "testboot-return matches VENDOR" || bad "testboot-return is $got, VENDOR pins $want"

dm=$(grep -nF '"$kernel_patches_testboot_shutdown" -r "+$kernel_patches_testboot_deadman" "kernel_patches_testboot dead-man: restart in $kernel_patches_testboot_deadman minutes unless the run finishes" > "$OUT/deadman.txt" 2>&1' "$rc" | head -1 | cut -d: -f1)
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
grep -qF 'dm_confirm "$_dm_pid" "$(id -u)"' "$rc" && grep -qF 'DM_CHILD=$_dm_pid' "$rc" &&
    ok "dead-man confirmation and DM_CHILD use shutdown's exact pid" ||
    bad "dead-man confirmation does not use the exact current-uid pid"
grep -qF 'dm_confirm "$DM_CHILD" "$(id -u)"' "$rc" && grep -qF 'kill "$DM_CHILD"' "$rc" &&
    ok "dead-man cancellation reconfirms and targets only DM_CHILD" ||
    bad "dead-man cancellation does not reconfirm and kill the exact confirmed pid"
if grep -qF 'ps -o uid=,comm=' "$rc"; then
	bad "the recorder still uses the comma-form ps output selector"
else
	ok "the recorder has no comma-form ps output selector"
fi

# Exercise the extracted functions without invoking shutdown(8).  All fakes
# live under TMPD (hence TMPDIR), and cleanup only kills exact pids started by
# this test.
_dm_test_root=$TMPD/dm-exact
if [ "$(id -u)" = 0 ]; then
	printf 'skip  dead-man runtime cases: refuse to run as root\n'
elif ! mkdir -p "$_dm_test_root"; then
	bad "cannot create dead-man test parent $_dm_test_root"
elif _dm_test_dir=$(mktemp -d "$_dm_test_root/dm-exact.XXXXXX"); then
	_dm_test_pid=
	_dm_test_gone=
	cleanup() {
		t_kill "$_dm_test_pid"
		t_kill "$_dm_test_gone"
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
pid=$!
c=
i=0
while [ "$i" -lt 2000 ]; do
	c=$(ps -o comm= -p "$pid" 2> /dev/null | tr -d ' ')
	[ "$c" = shutdown ] && break
	i=$((i + 1))
done
if [ "$c" != shutdown ]; then
	kill "$pid" 2> /dev/null
	exit 1
fi
printf 'shutdown: [pid %s]\n' "$pid" >&2
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
			if dm_confirm "$_dm_test_pid" "$_dm_test_uid" && t_confirm "$_dm_test_pid"; then
				ok "dead-man case 1: the exact live child is a numeric pid, still a shutdown, and confirmed"
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
			    dm_confirm "$_dm_test_fail_pid" "$_dm_test_uid"; then
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

# (guard) no path reaches /sbin/shutdown during host tests.  The helpers below
# execute only the dead-man definitions from a recorder copy, never the kit's
# top-level rc command.  Every real-default copy has its one real path replaced
# by SENT2 before it can run.

# has_bare_shutdown FILE: 0 when a bare shutdown command word remains.  The one
# detector lives in the kit's bare-shutdown-check.sh (bare_shutdown_lines), which
# check-be.sh dot-sources too; an unreadable file counts as bare.
. "$kit/bare-shutdown-check.sh"
has_bare_shutdown()
{
	[ -n "$(bare_shutdown_lines "$1")" ]
}

: > "$TMPD/stub-args"
stub_calls() { wc -l < "$TMPD/stub-args" | tr -d ' '; }

make_deadman_harness()
{
	_mh_src=$1
	_mh_dst=$2
	{
		grep -E '^kernel_patches_testboot_real_shutdown=|^: "\$\{kernel_patches_testboot_(deadman|shutdown|marker|lockfile|bectl):=' "$_mh_src" || :
		for _mh_fn in row dm_child_pid dm_confirm dm_decide deadman_allowed deadman_arm deadman_cancel; do
			sed -n "/^${_mh_fn}()/,/^}/p" "$_mh_src"
		done
	} > "$_mh_dst"
	for _mh_fn in row dm_child_pid dm_confirm dm_decide deadman_allowed deadman_arm deadman_cancel; do
		grep -q "^${_mh_fn}()" "$_mh_dst" || return 1
	done
	sh -n "$_mh_dst"
}

# run_deadman_copy COPY NAME MODE; MODE is default (onestart, no boot variables),
# boot (every boot variable set, still the real non-root uid), bootstub (the boot
# variables AND a stub override: the override must be ignored), or stub (G1's
# safe stub, outside a boot).
run_deadman_copy()
{
	_rd_src=$1
	_rd_name=$2
	_rd_mode=${3:-default}
	_rd_ovr=${4:-}
	_rd_dir=$TMPD/$_rd_name
	mkdir -p "$_rd_dir/out" || return 1
	: > "$_rd_dir/out/results.jsonl"
	make_deadman_harness "$_rd_src" "$_rd_dir/harness" || return 1
	(
		OUT=$_rd_dir/out
		DM_OK=0
		DM_CHILD=
		kernel_patches_testboot_deadman=45
		kernel_patches_testboot_marker=$_rd_dir/marker
		kernel_patches_testboot_lockfile=$_rd_dir/noshutdown
		kernel_patches_testboot_bectl=$_rd_dir/bectl-must-not-run
		unset autoboot rc_fast
		rc_arg=onestart
		case $_rd_mode in
		stub)
			kernel_patches_testboot_shutdown=$TMPD/shutdown-stub
			export kernel_patches_testboot_shutdown
			;;
		boot)
			unset kernel_patches_testboot_shutdown
			autoboot=yes
			rc_fast=yes
			rc_arg=start
			;;
		bootstub)
			kernel_patches_testboot_shutdown=$TMPD/shutdown-stub
			export kernel_patches_testboot_shutdown
			autoboot=yes
			rc_fast=yes
			rc_arg=start
			;;
		ovr)
			kernel_patches_testboot_shutdown=$_rd_ovr
			export kernel_patches_testboot_shutdown
			;;
		*)
			unset kernel_patches_testboot_shutdown
			;;
		esac
		. "$_rd_dir/harness"
		sync() { :; }
		deadman_arm
	) > "$_rd_dir/run.log" 2>&1
}

_guard_pid=
_guard_decoy=
guard_cleanup()
{
	trap '' 1 2 15
	t_kill "$_guard_pid"
	t_kill "$_guard_decoy"
	case $_guard_pid in ''|*[!0-9]*) ;; *) wait "$_guard_pid" 2> /dev/null || : ;; esac
	case $_guard_decoy in ''|*[!0-9]*) ;; *) wait "$_guard_decoy" 2> /dev/null || : ;; esac
	rm -rf -- "$TMPD"
	if [ "$_tmpdir_made" = 1 ]; then rmdir "$TMPDIR" 2> /dev/null || :; fi
}
trap guard_cleanup 0
trap 'exit 130' 1 2 15

# F5: the bare-call detector sees a bare shutdown after every command prefix
# and does not see comments, quoted text or the variable call.
_bare_bad=
for _pre in '' 'if' 'if !' 'then' 'else' 'do' 'while' 'until' '!' '{' '(' ';' '&&' '||' '|' 'exec' 'command' 'nohup' 'time' 'x=1'; do
	printf '%s shutdown -r +1 x\n' "$_pre" > "$TMPD/bare.t"
	has_bare_shutdown "$TMPD/bare.t" || _bare_bad="$_bare_bad [$_pre]"
done
for _line in 'sh -c "shutdown -r now"' "eval 'shutdown -r now'" 'bash -c "x; shutdown now"' 'x=$(shutdown -h now)' 'env shutdown -p now' 'xargs shutdown -r'; do
	printf '%s\n' "$_line" > "$TMPD/bare.t"
	has_bare_shutdown "$TMPD/bare.t" || _bare_bad="$_bare_bad [$_line]"
done
[ -z "$_bare_bad" ] && ok "(guard) F5 the detector sees a bare shutdown after every command prefix and inside quoted sh -c and eval text" ||
    bad "(guard) F5 the detector missed:$_bare_bad"
_bare_bad=
for _line in '# shutdown -r +1 x' '	# if shutdown -r +1' '"$kernel_patches_testboot_shutdown" -r "+1" "x"' 'row deadman fail "not calling shutdown: x"' "echo 'shutdown'" 'x=$kernel_patches_testboot_real_shutdown' 'kernel_patches_testboot_real_shutdown=/sbin/shutdown'; do
	printf '%s\n' "$_line" > "$TMPD/bare.t"
	if has_bare_shutdown "$TMPD/bare.t"; then _bare_bad="$_bare_bad [$_line]"; fi
done
[ -z "$_bare_bad" ] && ok "(guard) F5 control: comments, quoted text, the variable call and the assignment are not bare calls" ||
    bad "(guard) F5 false positive:$_bare_bad"

# G3: the one real-path literal is replaceable, and the resulting real default
# refuses as the current non-root user without reaching its sentinel.
_g3_copy=$TMPD/g3-rc
_g3_count=$(grep -oF '/sbin/shutdown' "$rc" | wc -l | tr -d ' ')
if [ "$_g3_count" != 1 ]; then
	bad "(guard) G3 expected one real shutdown literal, found $_g3_count"
elif ! sed "s|/sbin/shutdown|$SENT2/real-shutdown|" "$rc" > "$_g3_copy" ||
    cmp -s "$rc" "$_g3_copy" || grep -qF '/sbin/shutdown' "$_g3_copy"; then
	bad "(guard) G3 sentinel substitution did not produce a distinct path-free copy"
else
	ok "(guard) G3 substituted the single real path with SENT2"
	for _g3_mode in default boot bootstub; do
		_g3_dir=$TMPD/g3-$_g3_mode
		mkdir -p "$_g3_dir"
		printf 'guard-be\n' > "$_g3_dir/marker"
		: > "$SENT2/hits"
		_g3_before=$(stub_calls)
		run_deadman_copy "$_g3_copy" "g3-$_g3_mode" "$_g3_mode"
		_g3_status=$?
		_g3_row=$(grep -F '== row deadman: fail: REFUSED: not calling shutdown: ' "$_g3_dir/run.log" | head -1)
		_g3_want='uid '
		[ "$(id -u)" = 0 ] && _g3_want=
		if [ "$_g3_status" = 0 ] && [ ! -s "$SENT2/hits" ] && [ "$(stub_calls)" = "$_g3_before" ] &&
		    [ -n "$_g3_row" ] && case $_g3_row in *"calling shutdown: ${_g3_want}"*"this boot is NOT protected against a hang") true ;; *) false ;; esac; then
			ok "(guard) G3 $_g3_mode real default refuses at the first failed condition (${_g3_want:-not an rc boot}) and calls nothing"
		else
			bad "(guard) G3 $_g3_mode refusal status=$_g3_status; sentinel, stub call or refusal row is wrong: $_g3_row"
		fi
	done
fi
: > "$SENT2/hits"

# G3 overrides: through the sentinel-substituted copy, as the current non-root user
# with onestart, an override that is not a safe absolute stub is refused: the REFUSED
# row, an empty stub log, no sentinel hit.  The setuid file is only a mode on a copy
# of our own stub; the real shutdown is never touched.
cp "$TMPD/shutdown-stub" "$TMPD/shutdown-suid" && chmod u+s "$TMPD/shutdown-suid"
if [ -f "$_g3_copy" ] && [ -u "$TMPD/shutdown-suid" ]; then
	for _g3o in true relative setuid; do
		case $_g3o in
		true) _g3v=true ;;
		relative) _g3v=shutdown-stub ;;
		setuid) _g3v=$TMPD/shutdown-suid ;;
		esac
		: > "$SENT2/hits"
		_g3_before=$(stub_calls)
		run_deadman_copy "$_g3_copy" "g3o-$_g3o" ovr "$_g3v"
		_g3_status=$?
		_g3_row=$(grep -F '== row deadman: fail: REFUSED: not calling shutdown: ' "$TMPD/g3o-$_g3o/run.log" | head -1)
		if [ "$_g3_status" = 0 ] && [ ! -s "$SENT2/hits" ] && [ "$(stub_calls)" = "$_g3_before" ] && [ -n "$_g3_row" ]; then
			ok "(guard) G3 override '$_g3o' is refused: REFUSED row, empty stub log, no sentinel hit"
		else
			bad "(guard) G3 override '$_g3o' status=$_g3_status, stub calls or sentinel wrong, row: $_g3_row"
		fi
	done
	# the decided hand-run stub case: an absolute non-setuid stub is used outside a boot
	: > "$SENT2/hits"
	_g3_before=$(stub_calls)
	run_deadman_copy "$_g3_copy" g3o-hand stub
	if [ "$(stub_calls)" -gt "$_g3_before" ] && [ ! -s "$SENT2/hits" ] && grep -qF 'stubbed shutdown' "$TMPD/g3o-hand/out/results.jsonl"; then
		ok "(guard) G3 control: same stub on a hand run is used (decided: a stub cannot reboot)"
	else
		bad "(guard) G3 control: the stub on a hand run was not used"
	fi
	_g3h=$(sed -n 's/^shutdown: \[pid \([0-9]*\)\].*/\1/p' "$TMPD/g3o-hand/out/deadman.txt" 2> /dev/null | head -1)
	if [ -n "$_g3h" ] && t_confirm "$_g3h"; then t_kill "$_g3h"; wait "$_g3h" 2> /dev/null || :; fi
else
	bad "(guard) G3 override tests could not be set up"
fi
: > "$SENT2/hits"

# F3: dm_decide is a pure function; run it as a table, then plant mutants.
_dd_orig=$TMPD/dm-decide.fn
sed -n '/^dm_decide()/,/^}/p' "$rc" > "$_dd_orig"
if [ -s "$_dd_orig" ] && sh -n "$_dd_orig"; then
	ok "(guard) F3 dm_decide is extracted from the recorder"
else
	bad "(guard) F3 could not extract dm_decide"
fi
dd_table()	# dd_table FILE: prints the numbers of the table rows with a wrong result
{
	_dt_file=$1
	_dt_i=0
	_dt_wrong=
	while IFS='|' read -r _dt_u _dt_ab _dt_rf _dt_ra _dt_mk _dt_be _dt_want _dt_why; do
		_dt_i=$((_dt_i + 1))
		_dt_got=$( . "$_dt_file"; dm_decide "$_dt_u" "$_dt_ab" "$_dt_rf" "$_dt_ra" "$_dt_mk" "$_dt_be" > "$TMPD/dd.out" 2>&1; echo $? )
		_dt_msg=$(cat "$TMPD/dd.out")
		if [ "$_dt_got" != "$_dt_want" ]; then
			_dt_wrong="$_dt_wrong $_dt_i"
		elif [ -n "$_dt_why" ]; then
			case $_dt_msg in *"$_dt_why"*) ;; *) _dt_wrong="$_dt_wrong $_dt_i" ;; esac
		elif [ -n "$_dt_msg" ]; then
			_dt_wrong="$_dt_wrong $_dt_i"
		fi
	done <<'DDEOF'
0|yes|yes|start|m|m|0|
1001|yes|yes|start|m|m|1|uid 1001
1001|||stop|||1|uid 1001
0||yes|start|m|m|1|not an rc boot
0|no|yes|start|m|m|1|not an rc boot
0|yes||start|m|m|1|not an rc boot
0|yes|no|start|m|m|1|not an rc boot
0|yes|yes|stop|m|m|1|not an rc boot
0|yes|yes||m|m|1|not an rc boot
0|yes|yes|start||m|1|marker
0|yes|yes|start|m|other|1|does not match
0|yes|yes|start|m||1|no BE
DDEOF
	printf '%s' "$_dt_wrong"
}
_dd_wrong=$(dd_table "$_dd_orig")
if [ -z "$_dd_wrong" ]; then
	ok "(guard) F3 dm_decide table: the all-true row returns 0 and every single-condition failure returns 1 with its reason"
else
	bad "(guard) F3 dm_decide table has wrong rows:$_dd_wrong"
fi
dd_mutant()	# dd_mutant NAME SED-EXPRESSION
{
	if ! sed "$2" "$_dd_orig" > "$TMPD/dd-$1.fn" || cmp -s "$_dd_orig" "$TMPD/dd-$1.fn"; then
		bad "(guard) control: mutant dm_decide-$1 did not differ from the original"
		return 0
	fi
	_dm_w=$(dd_table "$TMPD/dd-$1.fn")
	if [ -n "$_dm_w" ]; then
		ok "(guard) control: mutant dm_decide-$1 is seen (wrong table rows:$_dm_w)"
	else
		bad "(guard) control: mutant dm_decide-$1 survived the table"
	fi
}
dd_mutant uid-dropped 's/if \[ "\$1" != 0 \]; then/if false; then/'
dd_mutant autoboot-flipped 's/\[ "\$2" != yes \]/[ "$2" = yes ]/'
dd_mutant rc_fast-dropped 's/ || \[ "\$3" != yes \]//'
dd_mutant be-compare-dropped 's/if \[ "\$6" != "\$5" \]; then/if false; then/'

# G4: one static oracle is used for both the real recorder and the planted mutants.
# It collects every failed rule in _gs_reason (separated by "; ").
gs_add() { _gs_reason="${_gs_reason:+$_gs_reason; }$1"; }
guard_static()
{
	_gs_src=$1
	_gs_reason=
	_gs_allowed=$(sed -n '/^deadman_allowed()/,/^}/p' "$_gs_src")
	_gs_decide=$(sed -n '/^dm_decide()/,/^}/p' "$_gs_src")
	[ -n "$_gs_allowed" ] || gs_add 'deadman_allowed is missing'
	[ -n "$_gs_decide" ] || gs_add 'dm_decide is missing'
	_gs_guard=$(printf '%s\n%s\n' "$_gs_allowed" "$_gs_decide")
	for _gs_token in 'id -u' 'autoboot' 'rc_arg' 'rc_fast' 'kernel_patches_testboot_marker' 'kernel_patches_testboot_bectl" list -H' 'awk' 'dm_decide "'; do
		printf '%s\n' "$_gs_guard" | grep -qF -- "$_gs_token" || gs_add "the guard lacks $_gs_token"
	done
	printf '%s\n' "$_gs_decide" | grep -qF '"$6" != "$5"' || gs_add 'the active BE is not compared with the marker'
	_gs_literals=$(grep -oF '/sbin/shutdown' "$_gs_src" | wc -l | tr -d ' ')
	[ "$_gs_literals" = 1 ] || gs_add "real path literal count $_gs_literals"
	grep -qF 'kernel_patches_testboot_real_shutdown=/sbin/shutdown' "$_gs_src" || gs_add 'the literal is not in the fixed real-path assignment'
	_gs_calls=$(sed 's/#.*//' "$_gs_src" | grep -cF '"$kernel_patches_testboot_shutdown" -r "+$kernel_patches_testboot_deadman"')
	[ "$_gs_calls" = 1 ] || gs_add "variable shutdown call count $_gs_calls"
	if has_bare_shutdown "$_gs_src"; then gs_add 'a bare shutdown call remains'; fi
	if grep -qE 'pgrep|pkill' "$_gs_src"; then gs_add 'pgrep/pkill remains'; fi
	grep -qF 'dm_confirm "$_dm_pid" "$(id -u)"' "$_gs_src" || gs_add 'arming does not confirm the current uid exact pid'
	_gs_cancel=$(sed -n '/^deadman_cancel()/,/^}/p' "$_gs_src")
	{ printf '%s\n' "$_gs_cancel" | grep -qF 'dm_confirm "$DM_CHILD" "$(id -u)"' &&
	    printf '%s\n' "$_gs_cancel" | grep -qF 'kill "$DM_CHILD"'; } || gs_add 'cancel does not reconfirm and kill only DM_CHILD'
	[ -z "$_gs_reason" ]
}
if guard_static "$rc"; then
	ok "(guard) G4 guard, rc_fast, marker/BE comparison, one literal/call, no bare call and exact-PID cancel are present"
else
	bad "(guard) G4 $_gs_reason"
fi

# G1's exported stub drives the actual arm/cancel functions.  A same-name decoy
# proves that cancellation is by the recorded pid rather than by process name.
_live=$TMPD/live
mkdir -p "$_live/out"
: > "$_live/out/results.jsonl"
if ! make_deadman_harness "$rc" "$_live/harness"; then
	bad "(guard) G1 could not build the live arm/cancel harness"
else
	OUT=$_live/out
	DM_OK=0
	DM_CHILD=
	kernel_patches_testboot_lockfile=$_live/noshutdown
	. "$_live/harness"
	deadman_arm > "$_live/arm.log" 2>&1
	_guard_pid=$(dm_child_pid "$_live/out/deadman.txt" 2> /dev/null)
	case $_guard_pid in ''|*[!0-9]*) _guard_pid= ;; esac
	if [ "$DM_OK" = 1 ] && [ -n "$_guard_pid" ] && t_confirm "$_guard_pid" && [ "$DM_CHILD" = "$_guard_pid" ] &&
	    grep -qF 'stubbed shutdown' "$_live/out/results.jsonl"; then
		ok "(guard) G1 the foreground stub arms and records its exact child, a numeric pid that is a shutdown"
	else
		bad "(guard) G1 foreground stub arming failed, started no shutdown child, or did not identify the stub"
	fi
	if [ -n "$_guard_pid" ] && [ "$DM_OK" = 1 ] && t_confirm "$_guard_pid"; then
		"$TMPD/child/shutdown" 30 &
		_guard_decoy=$!
		deadman_cancel > "$_live/cancel.log" 2>&1
		_guard_state=$(ps -o stat= -p "$_guard_pid" 2> /dev/null | tr -d ' ')
		case $_guard_state in
		''|Z*) ok "(guard) G1 cancellation killed the recorded child" ; _guard_pid= ;;
		*) bad "(guard) G1 recorded child is still alive in state $_guard_state" ;;
		esac
		if t_confirm "$_guard_decoy"; then
			ok "(guard) G1 the same-name decoy survived exact-PID cancellation"
		else
			bad "(guard) G1 the same-name decoy is not alive after cancellation"
		fi
		t_kill "$_guard_decoy"
		wait "$_guard_decoy" 2> /dev/null || :
		_guard_decoy=
		DM_CHILD=
		deadman_cancel > "$_live/cancel-empty.log" 2>&1
		grep -qF 'no confirmed shutdown pid' "$_live/cancel-empty.log" &&
		    ok "(guard) G1 empty-pid cancellation refuses to kill" ||
		    bad "(guard) G1 empty-pid cancellation did not fail closed"
		_before=$(stub_calls)
		: > "$kernel_patches_testboot_lockfile"
		deadman_arm > "$_live/arm-lock.log" 2>&1
		_after=$(stub_calls)
		rm -f "$kernel_patches_testboot_lockfile"
		[ "$_before" = "$_after" ] && grep -qF 'noshutdown exists' "$_live/arm-lock.log" &&
		    grep -qF 'this boot is NOT protected against a hang' "$_live/arm-lock.log" &&
		    ok "(guard) G1 the lockfile refuses arming before calling the stub" ||
		    bad "(guard) G1 lockfile arming reached the stub or lacked its fail row"
	else
		bad "(guard) G1 no confirmed stub child: the cancel checks cannot run"
	fi
fi

# G5 M1: removing the variable from the call must hit the PATH sentinel.  The
# mutant is only run when the sentinel is first in PATH and executable (F11).
_m1=$TMPD/m1-rc
if [ "${PATH%%:*}" != "$SENT" ] || [ ! -x "$SENT/shutdown" ] || [ -u "$SENT/shutdown" ]; then
	bad "(guard) M1 refused to run: the PATH sentinel is not first in PATH with an executable shutdown"
elif sed 's/"\$kernel_patches_testboot_shutdown" -r/shutdown -r/' "$rc" > "$_m1" && ! cmp -s "$rc" "$_m1"; then
	: > "$SENT/hits"
	run_deadman_copy "$_m1" m1 stub
	if [ -s "$SENT/hits" ]; then
		ok "(guard) control: mutant M1 is seen (the PATH sentinel was hit)"
	else
		bad "(guard) control: mutant M1 survived (the PATH sentinel was not hit)"
	fi
	: > "$SENT/hits"
else
	bad "(guard) control: mutant M1 did not differ from the original"
fi

# G5 M2: removing the refusal from the sentinel-substituted copy must hit SENT2.
_m2=$TMPD/m2-rc
if [ -f "$_g3_copy" ] && sed 's/if ! deadman_allowed; then/if false; then/' "$_g3_copy" > "$_m2" &&
    ! cmp -s "$_g3_copy" "$_m2"; then
	: > "$SENT2/hits"
	run_deadman_copy "$_m2" m2 default
	if [ -s "$SENT2/hits" ]; then
		ok "(guard) control: mutant M2 is seen (the real-path sentinel was hit)"
	else
		bad "(guard) control: mutant M2 survived (the real-path sentinel was not hit)"
	fi
	: > "$SENT2/hits"
else
	bad "(guard) control: mutant M2 did not differ from the sentinel-substituted original"
fi

# G5 M3: a pattern kill is rejected by the same static oracle, without running
# it; only the pgrep/pkill rule may be violated by this mutant.
_m3=$TMPD/m3-rc
if sed '/^deadman_cancel()$/,/^}$/{
/^{$/a\
	pkill -f kernel_patches_testboot_deadman
}' "$rc" > "$_m3" && ! cmp -s "$rc" "$_m3"; then
	if guard_static "$_m3"; then
		bad "(guard) control: mutant M3 survived G4"
	elif [ "$_gs_reason" = 'pgrep/pkill remains' ]; then
		ok "(guard) control: mutant M3 is seen ($_gs_reason)"
	else
		bad "(guard) control: mutant M3 failed G4 for more than the pkill rule: $_gs_reason"
	fi
else
	bad "(guard) control: mutant M3 did not differ from the original"
fi

# G5 M4: the call rewritten as an if-negated bare call (never run).  M4a
# replaces the call; M4b keeps it and adds the bare call, so only the bare-call
# rule fires.
_m4=$TMPD/m4-rc
if sed '/^[[:space:]]*"\$kernel_patches_testboot_shutdown" -r /c\
	if ! shutdown -r "+$N" "m"; then :; fi' "$rc" > "$_m4" && ! cmp -s "$rc" "$_m4"; then
	if guard_static "$_m4"; then
		bad "(guard) control: mutant M4 survived G4"
	else
		case $_gs_reason in
		*'a bare shutdown call remains'*) ok "(guard) control: mutant M4 is seen ($_gs_reason)" ;;
		*) bad "(guard) control: mutant M4 was not seen as a bare call: $_gs_reason" ;;
		esac
	fi
else
	bad "(guard) control: mutant M4 did not differ from the original"
fi
_m4b=$TMPD/m4b-rc
if sed '/^[[:space:]]*"\$kernel_patches_testboot_shutdown" -r /a\
	if ! shutdown -r "+$N" "m"; then :; fi' "$rc" > "$_m4b" && ! cmp -s "$rc" "$_m4b"; then
	if guard_static "$_m4b"; then
		bad "(guard) control: mutant M4b survived G4"
	elif [ "$_gs_reason" = 'a bare shutdown call remains' ]; then
		ok "(guard) control: mutant M4b is seen (only the bare-call rule: $_gs_reason)"
	else
		bad "(guard) control: mutant M4b failed G4 for more than the bare-call rule: $_gs_reason"
	fi
else
	bad "(guard) control: mutant M4b did not differ from the original"
fi

# G5 M6/M7: a bare call hidden in quoted text (sh -c, eval), appended on a line of
# its own; never run.  Only the bare-call rule may fire.
_m6=$TMPD/m6-rc
_m7=$TMPD/m7-rc
{ cat "$rc"; printf '%s\n' 'sh -c "shutdown -r now"'; } > "$_m6"
{ cat "$rc"; printf '%s\n' "eval 'shutdown -r now'"; } > "$_m7"
for _mx in m6 m7; do
	eval "_mxf=\$_$_mx"
	if cmp -s "$rc" "$_mxf"; then
		bad "(guard) control: mutant $_mx did not differ from the original"
	elif guard_static "$_mxf"; then
		bad "(guard) control: mutant $_mx survived G4"
	elif [ "$_gs_reason" = 'a bare shutdown call remains' ]; then
		ok "(guard) control: mutant $_mx is seen (only the bare-call rule: $_gs_reason)"
	else
		bad "(guard) control: mutant $_mx failed G4 for more than the bare-call rule: $_gs_reason"
	fi
done

# G6: dry-run the exact marker block from make-be.sh against a fake clone.
_g6_block=$TMPD/make-marker-block
sed -n '/^# The marker ties use of the real shutdown/,/^$/p' "$kit/make-be.sh" > "$_g6_block"
if ! grep -qF 'kernel_patches_testboot.marker' "$_g6_block"; then
	bad "(guard) G6 make-be.sh marker block is missing"
else
	mkdir -p "$TMPD/fake-clone"
	if (MNT=$TMPD/fake-clone; BE=guard-be; export MNT BE; sh "$_g6_block") > "$TMPD/g6.log" 2>&1 &&
	    [ "$(cat "$TMPD/fake-clone/usr/local/etc/kernel_patches_testboot.marker" 2> /dev/null)" = guard-be ] &&
	    [ "$(stat -f %Lp "$TMPD/fake-clone/usr/local/etc/kernel_patches_testboot.marker" 2> /dev/null)" = 444 ]; then
		ok "(guard) G6 make-be.sh writes the BE marker with mode 0444"
	else
		bad "(guard) G6 marker dry-run failed; see $TMPD/g6.log"
	fi
fi
if has_bare_shutdown "$kit/make-be.sh"; then
	bad "(guard) G6 make-be.sh contains a bare shutdown call"
else
	ok "(guard) G6 make-be.sh never calls shutdown"
fi
if grep -qF 'kernel_patches_testboot.marker' "$kit/check-be.sh" &&
    grep -qF 'kernel_patches_testboot_shutdown' "$kit/check-be.sh"; then
	ok "(guard) G6 check-be.sh verifies the marker and overridable shutdown"
else
	bad "(guard) G6 check-be.sh lacks marker or shutdown checks"
fi

# F1/F5 in check-be.sh: its detector and its rc.conf override scan, extracted
# and run on fakes.  The detector must agree with the test's on the mutants.
sed -n '/^dm_override_lines()/,/^}/p' "$kit/check-be.sh" > "$TMPD/cb-ovr.fn"
_cb_src=$(grep -F '. "$(dirname "$0")/bare-shutdown-check.sh"' "$kit/check-be.sh" | head -1)
if [ -s "$TMPD/cb-ovr.fn" ] && sh -n "$TMPD/cb-ovr.fn" && [ -n "$_cb_src" ]; then
	# G2: run check-be.sh's own source line from a copy of its directory, so a
	# broken shared file reaches check-be.sh exactly as it reaches the test.
	cb_detect() # cb_detect KITCOPYDIR FILE
	{
		sh -c "$_cb_src"'
bare_shutdown_lines "$1"' "$1/check-be.sh" "$2"
	}
	_cbk=$TMPD/cb-kit
	mkdir -p "$_cbk"
	cp "$kit/check-be.sh" "$kit/bare-shutdown-check.sh" "$_cbk/"
	_cb_clean=$(cb_detect "$_cbk" "$rc")
	_cb_m1=$(cb_detect "$_cbk" "$_m1")
	_cb_m4=$(cb_detect "$_cbk" "$_m4")
	_cb_m6=$(cb_detect "$_cbk" "$_m6")
	_cb_m7=$(cb_detect "$_cbk" "$_m7")
	if [ -z "$_cb_clean" ] && [ -n "$_cb_m1" ] && [ -n "$_cb_m4" ] && [ -n "$_cb_m6" ] && [ -n "$_cb_m7" ]; then
		ok "(guard) F5 check-be.sh detector (sourced from its directory): clean recorder passes, M1, M4, M6 and M7 are seen"
	else
		bad "(guard) F5 check-be.sh detector: clean='$_cb_clean' m1='$_cb_m1' m4='$_cb_m4' m6='$_cb_m6' m7='$_cb_m7'"
	fi
	# G2 mutant of the shared file: the function never reports anything.  Both users
	# must then fail to see M1 (their own control turns red).
	sed 's/^bare_shutdown_lines()$/bare_shutdown_lines_orig()/' "$kit/bare-shutdown-check.sh" > "$_cbk/bare-shutdown-check.sh"
	printf 'bare_shutdown_lines() { :; }\n' >> "$_cbk/bare-shutdown-check.sh"
	if ! cmp -s "$kit/bare-shutdown-check.sh" "$_cbk/bare-shutdown-check.sh"; then
		_cbm_cb=$(cb_detect "$_cbk" "$_m1")
		_cbm_t=$(. "$_cbk/bare-shutdown-check.sh"; bare_shutdown_lines "$_m1")
		if [ -z "$_cbm_cb" ] && [ -z "$_cbm_t" ]; then
			ok "(guard) control: mutant shared-detector is seen by check-be.sh and by the host test (M1 goes undetected in both)"
		else
			bad "(guard) control: mutant shared-detector survived (check-be.sh='$_cbm_cb' test='$_cbm_t')"
		fi
	else
		bad "(guard) control: mutant shared-detector did not differ from the original"
	fi
	_ov_bad=
	_ov_clean=$TMPD/fake-mnt-clean
	mkdir -p "$_ov_clean/etc/rc.conf.d" "$_ov_clean/usr/local/etc/rc.conf.d"
	printf 'kernel_patches_testboot_enable="YES"\nkernel_patches_testboot_normal_be="x"\n' > "$_ov_clean/etc/rc.conf.d/kernel_patches_testboot"
	[ -z "$(MNT=$_ov_clean; . "$TMPD/cb-ovr.fn"; dm_override_lines)" ] || _ov_bad="$_ov_bad clean-flagged"
	for _ov_file in etc/rc.conf etc/rc.conf.local etc/rc.conf.d/zz usr/local/etc/rc.conf usr/local/etc/rc.conf.d/zz; do
		for _ov_name in shutdown marker bectl; do
			_ov_mnt=$TMPD/fake-mnt-$_ov_name
			rm -rf -- "$_ov_mnt"
			mkdir -p "$_ov_mnt/etc/rc.conf.d" "$_ov_mnt/usr/local/etc/rc.conf.d"
			printf 'kernel_patches_testboot_%s="/x"\n' "$_ov_name" > "$_ov_mnt/$_ov_file"
			[ -n "$(MNT=$_ov_mnt; . "$TMPD/cb-ovr.fn"; dm_override_lines)" ] || _ov_bad="$_ov_bad $_ov_file:$_ov_name"
		done
	done
	[ -z "$_ov_bad" ] && ok "(guard) F1 check-be.sh flags _shutdown, _marker and _bectl in every rc.conf location and passes a clean clone" ||
	    bad "(guard) F1 check-be.sh override scan wrong for:$_ov_bad"
else
	bad "(guard) F1 could not extract check-be.sh dm_override_lines or its bare-shutdown-check.sh source line"
fi

# G2 is deliberately last, after all mutant hits have been checked and cleared.
if [ -s "$SENT/hits" ]; then
	bad "(guard) G2 PATH sentinel hits remain: $(cat "$SENT/hits")"
else
	ok "(guard) G2 PATH sentinel was never reached outside the M1 control"
fi
if [ -s "$SENT2/hits" ]; then
	bad "(guard) G2 real-path sentinel hits remain: $(cat "$SENT2/hits")"
else
	ok "(guard) G2 real-path sentinel was never reached outside the M2 control"
fi

printf 'kernel_patches_testboot_kit_test: %s failed\n' "$fails"
[ "$fails" = 0 ]

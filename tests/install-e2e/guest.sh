#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# guest.sh - the stock-install test, run INSIDE a fresh stock FreeBSD
# machine (a VM made by run.sh, or any machine you are willing to install
# on) as a normal user.  It knows nothing about the repository it tests
# beyond the project Makefile contract (skill project-makefile-contract):
#
#   git clone REPO; make preflight; make install-prereqs YES=1;
#   make install YES=1; make configure YES=1 (when the repo has it);
#   checks; make deinstall YES=1
#
# and fails on anything that needs a hand: a step that exits non-zero, a
# file left behind, a manifest that does not match.
#
# Usage: sh guest.sh --repo-url URL [--ref REF] --results DIR
#            [--installed-manifest PATH] [--expected-manifest REL]
#            [--load MODULE] [--no-load] [--watch DIR]... [--make-arg VAR=VALUE]...
#   --repo-url            what to clone (https://... or git@...); a private
#                         repository needs read access set up for this user
#                         before (an ssh deploy key in ~/.ssh, or a git
#                         credential helper); never pass a token here
#   --ref                 branch, tag or commit to test (default: the
#                         repository's default branch)
#   --results             where steps.jsonl, summary.json and the logs go
#   --installed-manifest  the manifest make install writes (path mode
#                         owner:group sha256 / path link -> target / path
#                         dir; @prefix PREFIX is metadata, not a path);
#                         checked against the files on disk
#   --expected-manifest   the manifest the repository commits (path mode
#                         owner:group [type], path relative to the
#                         checkout); compared with the installed one
#   --load MODULE         kldload MODULE after install and kldunload after
#                         (a VM only: never on a machine you care about);
#                         the load must succeed or be refused cleanly
#   --no-load             skip the load step
#   --make-arg VAR=VALUE  added to every make command line (for example
#                         ACCEPT_NVIDIA_LICENSE=1, when the person running
#                         the test accepts that licence); repeatable
#   --watch DIR           one more directory for the nothing-left check
#                         (beside /boot/modules, /boot/loader.conf,
#                         /etc/rc.conf, /usr/local and /var/db)
#
# Test-only load hook: with --load, GUEST_TEST_HOOKS=1 and
# GUEST_KLD_TEST_DIR=DIR use DIR/kldstat, DIR/kldload, DIR/kldunload and
# DIR/doas by full path for the load step only; DIR is never added to PATH.
# DIR must be a real directory owned by the invoking user, not writable by
# group or other.  guest.sh always refuses to run as root.
#
# Output: one JSON object per line in RESULTS/steps.jsonl (schema
# schema/stock-install-step-1.schema.json):
#   {"schema":"stock-install-step/1","index":N,"step":"...","pass":true,
#    "rc":0,"seconds":12,"detail":"...","log":"logs/<step>.log"}
# then RESULTS/summary.json (schema stock-install-summary/1), and the same
# summary on stdout.  Exit 0 when every step passed, 1 otherwise, 2 usage.
# Nothing is written outside RESULTS, the clone, and what the repository's
# own make targets write; /tmp is not used.

set -u
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin
export PATH

repo_url=
ref=
results=
inst_man=
exp_man=
load_mod=
noload=0
watch=
margs=
while [ $# -gt 0 ]; do
	case $1 in
	--repo-url) repo_url=${2:?}; shift ;;
	--ref) ref=${2:?}; shift ;;
	--results) results=${2:?}; shift ;;
	--installed-manifest) inst_man=${2:?}; shift ;;
	--expected-manifest) exp_man=${2:?}; shift ;;
	--load) load_mod=${2:?}; shift ;;
	--no-load) noload=1 ;;
	--watch) watch="$watch ${2:?}"; shift ;;
	--make-arg)
		case ${2:?} in
		[A-Za-z_]*=*) ;;
		*) echo "guest.sh: --make-arg takes VAR=VALUE" >&2; exit 2 ;;
		esac
		case ${2%%=*} in
		*[!A-Za-z0-9_]*) echo "guest.sh: --make-arg: bad name ${2%%=*}" >&2; exit 2 ;;
		esac
		margs="$margs
$2"
		shift
		;;
	-h|--help) sed -n '2,45p' "$0"; exit 0 ;;
	*) echo "guest.sh: unknown argument $1" >&2; exit 2 ;;
	esac
	shift
done
[ -n "$repo_url" ] && [ -n "$results" ] || { echo "guest.sh: --repo-url and --results are required" >&2; exit 2; }
[ "$(id -u)" != 0 ] || { echo "guest.sh: run it as a normal user, not root" >&2; exit 2; }
kldstat_cmd=kldstat
kldload_cmd=kldload
kldunload_cmd=kldunload
doas_cmd=doas
if [ "$noload" = 0 ] && [ -n "$load_mod" ] \
    && [ "${GUEST_TEST_HOOKS:-0}" = 1 ] && [ -n "${GUEST_KLD_TEST_DIR:-}" ]; then
	_hd=$GUEST_KLD_TEST_DIR
	[ -d "$_hd" ] && [ ! -L "$_hd" ] \
	    || { echo "guest.sh: GUEST_KLD_TEST_DIR is not a real directory" >&2; exit 2; }
	_hs=$(stat -f '%u %Lp' "$_hd") || exit 2
	_hu=${_hs%% *}
	_hm=${_hs##* }
	[ "$_hu" = "$(id -u)" ] && [ $((0$_hm & 022)) = 0 ] \
	    || { echo "guest.sh: GUEST_KLD_TEST_DIR must be owned by the invoking user and not writable by group or other" >&2; exit 2; }
	for _c in kldstat kldload kldunload doas; do
		[ -f "$_hd/$_c" ] && [ ! -L "$_hd/$_c" ] && [ -x "$_hd/$_c" ] \
		    || { echo "guest.sh: GUEST_KLD_TEST_DIR/$_c is not a safe executable" >&2; exit 2; }
	done
	_hd=$(CDPATH= cd -- "$_hd" && pwd -P)
	kldstat_cmd=$_hd/kldstat
	kldload_cmd=$_hd/kldload
	kldunload_cmd=$_hd/kldunload
	doas_cmd=$_hd/doas
fi
mkdir -p -- "$results/logs" || exit 2
results=$(cd "$results" && pwd -P)
J=$results/steps.jsonl
: > "$J"
idx=0
nfail=0

json_str() {
	printf '%s' "$1" | tr '\n\t' '  ' | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# record STEP PASS RC SECONDS DETAIL
record() {
	printf '{"schema":"stock-install-step/1","index":%s,"step":"%s","pass":%s,"rc":%s,"seconds":%s,"detail":"%s","log":"logs/%s.log"}\n' \
	    "$idx" "$1" "$2" "$3" "$4" "$(json_str "$5")" "$1" >> "$J"
	[ "$2" = true ] || nfail=$((nfail + 1))
	printf '%s %-22s rc=%s %ss %s\n' "$([ "$2" = true ] && echo PASS || echo FAIL)" "$1" "$3" "$4" "$5"
	idx=$((idx + 1))
}

# run STEP CMD...: run CMD with its output in logs/STEP.log; sets RC, SECS
run() {
	_st=$1
	shift
	_t0=$(date +%s)
	RC=0
	"$@" > "$results/logs/$_st.log" 2>&1 < /dev/null || RC=$?
	SECS=$(($(date +%s) - _t0))
}

# The files a stock install has where an install writes: compared before
# install and after deinstall ("nothing left behind").
snapshot() {
	# one stat(1) run per many files: path, type, size, mode and a link's
	# target show a file added, removed, resized or re-moded (an mtime is
	# left out: configure and deinstall rewrite rc.conf and loader.conf
	# with the same content); the content of the two config files and of
	# /boot/modules is compared by sha256
	for _d in /boot/modules /boot/loader.conf /etc/rc.conf /usr/local/etc /usr/local/lib \
	    /usr/local/include /usr/local/sbin /usr/local/bin /usr/local/share/man /usr/local/share/licenses \
	    /usr/local/share /var/db $watch; do
		[ -e "$_d" ] || continue
		find "$_d" \( -type f -o -type l -o -type d \) -exec stat -f '%N|%HT|%z|%Lp|%Y' {} + 2>/dev/null
	done | grep -v -E '^/var/db/(pkg|freebsd-update|etcupdate|ports|entropy|dhclient)|^/var/db/[^|]*\.(db|tmp)[|]|^/usr/local/share/(doc|examples)/' \
	    | awk -F'|' '{ if ($2 == "Directory") print $1 "|dir|" $4; else print }' | sort -u
	for _f in /boot/loader.conf /etc/rc.conf /boot/modules/*.ko; do
		[ -f "$_f" ] && printf '%s|sha256|%s\n' "$_f" "$(sha256 -q "$_f")"
	done
}

# 0 environment
{
	uname -a
	echo "osreldate $(sysctl -n kern.osreldate)"
	echo "freebsd-version $(freebsd-version -k) / $(freebsd-version -u)"
	echo "user $(id)"
	echo "pkg $(ls /usr/local/sbin/pkg 2>/dev/null || echo not-bootstrapped)"
	pkg info 2>/dev/null | head -50
} > "$results/logs/env.log" 2>&1
record env true 0 0 "$(uname -srmp) osreldate $(sysctl -n kern.osreldate)"

# 1 clone, fresh
W=$results/checkout
rm -rf -- "$W"
if [ -n "$ref" ]; then
	run clone git clone -q "$repo_url" "$W"
	[ "$RC" = 0 ] && run clone-ref git -C "$W" checkout -q "$ref"
else
	run clone git clone -q "$repo_url" "$W"
fi
[ "$RC" = 0 ] && record clone true 0 "$SECS" "$(git -C "$W" rev-parse HEAD 2>/dev/null)" \
    || { record clone false "$RC" "$SECS" "git clone failed"; }
[ -d "$W" ] || {
	printf '{"schema":"stock-install-summary/1","pass":false,"steps":%s,"failed":%s}\n' "$idx" "$nfail" | tee "$results/summary.json"
	exit 1
}
cd "$W" || exit 1

# mk ARGS...: make ARGS with the --make-arg settings added, each its own
# argument (a value may hold spaces)
mk() {
	_IFS=$IFS
	IFS='
'
	# shellcheck disable=SC2086
	set -- "$@" $margs
	IFS=$_IFS
	make "$@"
}

# preflight JSON from make -s preflight JSON=1: the JSON object only (BSD
# make may add its error lines after it)
pf_json() {
	awk 'BEGIN { p = 0 } /^\{/ { p = 1 } p { print } /^\}/ { if (p) exit }' "$1"
}

# 2 preflight before anything is installed: must produce valid JSON
run preflight-before mk -s preflight JSON=1
pf_json "$results/logs/preflight-before.log" > "$results/preflight-before.json"
# a stock system has no JSON parser: the object must open and close and
# carry the contract's schema_version and status fields
if grep -q '"schema_version"' "$results/preflight-before.json" && grep -q '"status"' "$results/preflight-before.json" \
    && [ "$(sed -n '$p' "$results/preflight-before.json")" = "}" ]; then
	record preflight-before true "$RC" "$SECS" "JSON contract printed; exit $RC before install-prereqs"
else
	record preflight-before false "$RC" "$SECS" "no JSON object in make preflight JSON=1"
fi

# 3 install-prereqs
run install-prereqs mk install-prereqs YES=1
record install-prereqs "$([ "$RC" = 0 ] && echo true || echo false)" "$RC" "$SECS" "$(tail -n 1 "$results/logs/install-prereqs.log")"

# 4 preflight after: exit 0; the device line is recorded
run preflight-after mk -s preflight JSON=1
pf_json "$results/logs/preflight-after.log" > "$results/preflight-after.json"
dev=$(sed -n 's/.*"device": *"\([^"]*\)".*/\1/p' "$results/preflight-after.json" | sed -n 1p)
miss=$(sed -n 's/.*"name": *"\([^"]*\)", *"state": *"missing".*/\1/p' "$results/preflight-after.json" | tr '\n' ' ')
record preflight-after "$([ "$RC" = 0 ] && echo true || echo false)" "$RC" "$SECS" "device: ${dev:-none reported}; missing: ${miss:-none}"

# 5 the system before install (after prereqs: packages are not ours)
snapshot > "$results/before.snapshot"

# 6 install
run install mk install YES=1
record install "$([ "$RC" = 0 ] && echo true || echo false)" "$RC" "$SECS" "$(tail -n 1 "$results/logs/install.log")"

# 7 the installed manifest: every file as recorded (mode, owner, sha256)
if [ -n "$inst_man" ]; then
	_bad=
	if [ -f "$inst_man" ]; then
		cp "$inst_man" "$results/installed.manifest"
		_bad=$(awk '$1 !~ /^@/ && $2 != "dir" && $2 != "link"' "$inst_man" | while read -r p m o h; do
			[ -f "$p" ] || { echo "missing:$p"; continue; }
			[ "$(stat -f '%Lp' "$p")" = "$m" ] || echo "mode:$p"
			[ "$(stat -f '%Su:%Sg' "$p")" = "$o" ] || echo "owner:$p"
			[ "$h" = - ] || [ "$(sha256 -q "$p")" = "$h" ] || echo "sha256:$p"
		done)
		_n=$(awk '$1 !~ /^@/ && $2 != "dir"' "$inst_man" | wc -l | tr -d ' ')
		[ -z "$_bad" ] && record manifest-on-disk true 0 0 "$_n entries match the files on disk" \
		    || record manifest-on-disk false 1 0 "$(printf '%s ' $_bad)"
	else
		record manifest-on-disk false 1 0 "no installed manifest at $inst_man"
	fi
fi

# 8 the installed manifest against the one the repository commits
if [ -n "$exp_man" ] && [ -n "$inst_man" ]; then
	if [ -f "$W/$exp_man" ] && [ -f "$inst_man" ]; then
		awk '$1 ~ /^@/ || $2 == "dir" || $1 ~ /installed\.manifest$/ { next } { if ($2 == "link") print $1, "link", $4; else print $1, $2, $3 }' "$inst_man" | sort > "$results/installed.norm"
		grep -v '^#' "$W/$exp_man" | awk 'NF' | sort > "$results/expected.norm"
		if cmp -s "$results/installed.norm" "$results/expected.norm"; then
			record manifest-expected true 0 0 "$(wc -l < "$results/expected.norm" | tr -d ' ') entries equal $exp_man"
		else
			diff "$results/expected.norm" "$results/installed.norm" > "$results/logs/manifest-expected.log"
			record manifest-expected false 1 0 "differs from $exp_man: $(head -n 4 "$results/logs/manifest-expected.log" | tr '\n' ' ')"
		fi
	else
		record manifest-expected false 1 0 "missing $exp_man or the installed manifest"
	fi
fi

# 9 kldxref and module dependencies: every dependency of an installed
# module is provided by a module in /boot/kernel or /boot/modules
mods=
[ -n "$inst_man" ] && [ -f "$inst_man" ] && mods=$(awk '$1 ~ /^\/boot\/modules\/.*\.ko$/ { print $1 }' "$inst_man")
if [ -n "$mods" ]; then
	# providers: every module and interface kldxref lists for /boot/kernel
	# and /boot/modules, and the modules compiled into the kernel (kldstat
	# -v lists them under kernel); needs: the depends lines of our modules
	{ kldxref -d /boot/kernel; kldxref -d /boot/modules; } > "$results/logs/kldxref.log" 2>&1
	kldstat -v > "$results/logs/kldstat-v.log" 2>&1
	_unres=$(awk -v ours="$(printf '%s ' $mods)" '
		FNR == 1 { f++ }
		f == 1 && /^\// { cur = $1; mine = (index(ours, cur " ") > 0); next }
		f == 1 && $1 == "module" { have[$2] = 1; next }
		f == 1 && $1 == "interface" { m = $2; sub(/\.[0-9]+$/, "", m); have[m] = 1; next }
		f == 1 && /depends on / && mine { d = $3; sub(/\.[0-9]+$/, "", d); need[d] = 1; next }
		f == 2 && /^[[:space:]]+[0-9]+ / { m = $2; sub(/^[^\/]*\//, "", m); have[m] = 1 }
		END { for (d in need) if (!(d in have) && d != "kernel") print d }' \
	    "$results/logs/kldxref.log" "$results/logs/kldstat-v.log" | sort | tr '\n' ' ')
	_prov=$(grep -c -E '^  (module|interface) ' "$results/logs/kldxref.log")
	[ -f /boot/modules/linker.hints ] && [ -z "$_unres" ] \
	    && record kldxref true 0 0 "linker.hints present; every dependency resolves ($_prov records)" \
	    || record kldxref false 1 0 "unresolved: ${_unres:-none}; linker.hints $([ -f /boot/modules/linker.hints ] && echo present || echo missing)"
fi

# 10 load in the VM: succeed, or be refused cleanly (no panic: this script
# is still running afterwards), then unload
if [ "$noload" = 0 ] && [ -n "$load_mod" ]; then
	_t0=$(date +%s)
	_load_error=
	_load_rc=0
	_lrc=0
	"$kldstat_cmd" > "$results/kld.before.raw" 2> "$results/logs/load.log"
	_brc=$?
	if [ "$_brc" != 0 ]; then
		_load_rc=$_brc
		_load_error="kldstat before load failed (rc $_brc)"
	else
		awk 'NR > 1 { print $1, $5 }' "$results/kld.before.raw" > "$results/kld.before"
		"$doas_cmd" "$kldload_cmd" -v "$load_mod" > "$results/logs/load.log" 2>&1
		_lrc=$?
		"$kldstat_cmd" > "$results/kld.after.raw" 2>> "$results/logs/load.log"
		_arc=$?
		if [ "$_arc" != 0 ]; then
			_load_rc=$_arc
			_load_error="kldstat after load failed (rc $_arc)"
		else
			cat "$results/kld.after.raw" >> "$results/logs/load.log"
			dmesg | tail -n 40 >> "$results/logs/load.log" 2>&1
			# Unload what this load added (and nothing else), newest id first.
			awk 'NR > 1 { print $1, $5 }' "$results/kld.after.raw" > "$results/kld.after"
			_added=$(awk 'FILENAME == ARGV[1] { had[$2] = 1; next } !($2 in had) { print $1, $2 }' \
			    "$results/kld.before" "$results/kld.after" | sort -rn | awk '{ print $2 }')
			for _m in $_added; do
				"$doas_cmd" "$kldunload_cmd" -v -n "${_m%.ko}" >> "$results/logs/load.log" 2>&1 || true
			done
			"$kldstat_cmd" > "$results/kld.unloaded.raw" 2>> "$results/logs/load.log"
			_urc=$?
			if [ "$_urc" != 0 ]; then
				_load_rc=$_urc
				_load_error="kldstat after unload failed (rc $_urc)"
			else
				awk 'NR > 1 { print $5 }' "$results/kld.unloaded.raw" > "$results/kld.unloaded"
			fi
		fi
	fi
	if [ -n "$_load_error" ]; then
		record load false "$_load_rc" "$(($(date +%s) - _t0))" "$_load_error"
	else
		_left=
		for _m in $_added; do
			if grep -qxF -- "$_m" "$results/kld.unloaded"; then
				_left="$_left $_m"
			fi
		done
		_left=${_left# }
		_pass=false
		if [ "$_lrc" = 0 ]; then
			[ -n "$_left" ] || _pass=true
			_detail="kldload $load_mod loaded"
		else
			[ -n "$_added" ] || _pass=true
			_detail="kldload $load_mod refused (rc $_lrc), no panic"
			[ -z "$_added" ] || _detail="$_detail; modules added: $(printf '%s' "$_added" | tr '\n' ' ')"
		fi
		[ -z "$_left" ] || _detail="$_detail; leftover modules: $_left"
		record load "$_pass" "$_lrc" "$(($(date +%s) - _t0))" "$_detail"
	fi
fi

# 11 rc.d scripts and devd files the install wrote
if [ -n "$inst_man" ] && [ -f "$inst_man" ]; then
	_bad=
	for _f in $(awk '$1 ~ /\/etc\/rc\.d\// { print $1 }' "$inst_man"); do
		sh -n "$_f" || _bad="$_bad syntax:$_f"
		service "$(basename "$_f")" rcvar > /dev/null 2>&1 || _bad="$_bad rcvar:$_f"
	done
	for _f in $(awk '$1 ~ /\/etc\/devd\/.*\.conf$/ { print $1 }' "$inst_man"); do
		_o=$(tr -cd '{' < "$_f" | wc -c); _c=$(tr -cd '}' < "$_f" | wc -c)
		[ "$_o" = "$_c" ] && [ "$_o" -gt 0 ] || _bad="$_bad braces:$_f"
	done
	[ -z "$_bad" ] && record rcd-devd true 0 0 "rc.d and devd files in place and well formed" || record rcd-devd false 1 0 "$_bad"
fi

# 12 manual pages: mandoc -T lint passes, and man(1) finds each
if [ -n "$inst_man" ] && [ -f "$inst_man" ]; then
	_bad=
	_n=0
	for _f in $(awk '$1 ~ /\/man\/man[1-9]\/[^/]*\.[1-9]$/ && $2 != "link" { print $1 }' "$inst_man"); do
		_n=$((_n + 1))
		mandoc -T lint -W error "$_f" >> "$results/logs/man.log" 2>&1 || _bad="$_bad lint:${_f##*/}"
		_page=${_f##*/}
		man -w "${_page##*.}" "${_page%.*}" > /dev/null 2>&1 || _bad="$_bad man-w:$_page"
	done
	[ -z "$_bad" ] && record man true 0 0 "$_n pages lint clean and found by man -w" || record man false 1 0 "$_bad"
fi

# 13 configure, when the repository has it (its change is undone by deinstall)
if make -n configure > /dev/null 2>&1; then
	run configure mk configure YES=1
	record configure "$([ "$RC" = 0 ] && echo true || echo false)" "$RC" "$SECS" "$(tail -n 1 "$results/logs/configure.log")"
fi

# 14 deinstall, then nothing left behind
run deinstall mk deinstall YES=1
record deinstall "$([ "$RC" = 0 ] && echo true || echo false)" "$RC" "$SECS" "$(tail -n 1 "$results/logs/deinstall.log")"
snapshot > "$results/after.snapshot"
if cmp -s "$results/before.snapshot" "$results/after.snapshot"; then
	record nothing-left true 0 0 "the system after deinstall equals the system before install"
else
	diff "$results/before.snapshot" "$results/after.snapshot" > "$results/logs/nothing-left.log"
	record nothing-left false 1 0 "$(grep -c '^[<>]' "$results/logs/nothing-left.log") differences: $(head -n 4 "$results/logs/nothing-left.log" | tr '\n' ' ')"
fi

pass=$([ "$nfail" = 0 ] && echo true || echo false)
printf '{"schema":"stock-install-summary/1","pass":%s,"steps":%s,"failed":%s,"os":"%s","arch":"%s","osreldate":%s,"repo_url":"%s","commit":"%s"}\n' \
    "$pass" "$idx" "$nfail" "$(json_str "$(uname -r)")" "$(uname -p)" "$(sysctl -n kern.osreldate)" \
    "$(json_str "$repo_url")" "$(git -C "$W" rev-parse HEAD 2>/dev/null)" | tee "$results/summary.json"
[ "$nfail" = 0 ]

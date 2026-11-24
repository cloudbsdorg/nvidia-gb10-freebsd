# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-2-Clause
#
# guard.sh - the no-Linux guard of the native-tools test boot (Track #2362), sourced by the rc one-shot
# nvidia_native_tools_testboot and by tests/native_tools_kit_test.sh.  It only reads: kldstat output, a sysctl
# answer, ELF headers and ktrace dumps.  Each function prints one line "<status> <detail>" on standard output, with
# status pass, fail or error, and returns 0 for pass, 1 for fail, 2 for error.  error means the guard could not look:
# it is never read as "found nothing".
#
# The rule (Mark, 2026-11-22: native test results, not going through Linux):
#   - modules: no loaded kld FILE other than the kernel whose name contains "linux" (the Linuxulator linux.ko,
#     linux64.ko, linux_common.ko; LinuxKPI linuxkpi.ko, linuxkpi_video.ko; the optional NVIDIA bridges nvidia_linux.ko
#     and nvidia_modeset_linux.ko; any future one) or has a part that starts with lkpi, lindebugfs, linsysfs,
#     linprocfs, drm, dmabuf, ttm, amdgpu, radeonkms or i915kms (guard_layer_name); no module record of such a name
#     inside a loaded file other than the kernel; and the Linux ABI not in the kernel (sysctl compat.linux answers
#     only "unknown oid").  Module records compiled into the kernel file itself are not loaded files: the stock kernel
#     holds records such as uhub/usb_linux, lkpi_iic/iicbus, drm/lkpi_iicbb and pci/lkpi_mlx5_core_pci_table (the
#     2026-11-22 boot, tests/data/native-tools-env-before-*.kldstat).  They are listed (guard_env prints a "records"
#     line), never a failure.  What closes the gap they leave is guard_ko_native: a module to be loaded may not import
#     any symbol that LinuxKPI defines (guard_lkpi_imports), whatever its name;
#   - binaries: every file a row executes (from its ktrace: the image and the interpreters the kernel opened for each
#     execve, which covers a #! script's interpreter and the ELF run-time linker) is a FreeBSD-branded ELF, or a #!
#     script; a row that calls kldload or kldunload fails (the trace names a file id for kldunload, not a module).

# The work-root rule of the test-boot kits (one design, in this file, for every kit; the kits source
# this file by path and call it, they do not copy it):
#   - the kits run as root (bectl), and every path they write lies under one WORK ROOT: GB10_WORK when
#     it is set, the work directory of the checkout the kit lies in (<repo>/work) otherwise;
#   - the checkout belongs to the account that cloned it, so root must name the work root (GB10_WORK)
#     and may not name one inside the checkout (guard_work_default, guard_work_root);
#   - GB10_WORK is an absolute path in plain form, and the work root the kit uses is its canonical
#     spelling: the symbolic links of the part that exists are resolved (guard_work_canon), so the
#     place root writes into is the place that is named, whatever directory the kit was started in;
#   - the checkout is checked, never assumed from the depth of the kit directory: it is a git work tree
#     whose top level is the computed root and whose tests directory holds the kit (guard_repo_root);
#     an extracted archive (no git metadata) is recognised as such (guard_archive_root), and the kit
#     decides whether it may run from one (the native-tools kit does, under its test hooks);
#   - a kit checks this file before it sources it (a regular file, no symbolic link, owned by root or
#     by the account that runs the kit, not writable by the group or by everyone, at its expected place
#     and, in a checkout, equal to the committed one): a guard that is not trusted is not run.  The
#     check is in the kit, before the source line, because a sourced file runs; guard_trusted_file is
#     the same rule for the other files a kit sources after this one.
# Every function prints the reason of a refusal on standard error and returns 2 (1 where the caller
# falls back, which is said in its comment); a refusal is never silent and never falls through.

# guard_work_abs <what> <value>: the value must be an absolute path that holds no newline.  The work
# root is the root of every path a kit writes, and a relative one depends on the directory the kit
# was started in: the same kit started in two directories writes in two places, and root writes into
# whichever of them happens to hold the name.  A value with a newline is cut by the command
# substitution that carries it (an empty work root would name "/logs" and "/build").  Prints "<what>
# must be an absolute path: <value>" and returns 2 when the value is not one.
guard_work_abs()
{
	case $2 in
	*'
'*) echo "$1 must be an absolute path without a newline" >&2; return 2 ;;
	/*) return 0 ;;
	esac
	echo "$1 must be an absolute path: $2" >&2
	return 2
}

# guard_work_canon <what> <value>: prints the canonical spelling of an absolute path a kit writes
# into, or refuses (2).  The value must be absolute (guard_work_abs), must not be the root of the
# filesystem, and must be in plain form: no trailing /, no //, no . or .. component (a path with a ..
# component names a place its text does not show).  The part of the path that exists is resolved
# through its symbolic links (pwd -P of the nearest existing ancestor); the part that does not exist
# yet is kept as written.  A nearest ancestor that cannot be entered is a refusal: the place cannot be
# told.
guard_work_canon()
{
	guard_work_abs "$1" "$2" || return 2
	case $2 in
	/) echo "$1 must not be the root of the filesystem: $2" >&2; return 2 ;;
	*/ | *//* | */./* | */../* | */. | */..)
		echo "$1 must be a plain absolute path (no trailing /, no //, no . or .. component): $2" >&2
		return 2 ;;
	esac
	_gc_p=$2
	_gc_rest=
	while [ ! -d "$_gc_p" ]; do
		_gc_rest=${_gc_p##*/}${_gc_rest:+/$_gc_rest}
		_gc_p=${_gc_p%/*}
		[ -n "$_gc_p" ] || _gc_p=/
	done
	_gc_r=$(CDPATH= cd -- "$_gc_p" 2> /dev/null && pwd -P) || {
		echo "$1 cannot be resolved: $2 ($_gc_p cannot be entered)" >&2
		return 2
	}
	[ -n "$_gc_r" ] || { echo "$1 cannot be resolved: $2" >&2; return 2; }
	case $_gc_r in /) _gc_r= ;; esac
	if [ -n "$_gc_rest" ]; then
		printf '%s/%s\n' "$_gc_r" "$_gc_rest"
	else
		printf '%s\n' "$_gc_r"
	fi
}

# guard_work_default <effective uid> <program> <defaulted options>: root must not silently use the
# checkout's work directory for these paths: it belongs to the developer account that cloned the
# repository, and root must not write into it.  The caller exits with this function's status.  A
# non-root caller and a caller that set GB10_WORK keep the default of guard_work_root.  The third
# argument names the options whose default the work root holds, each with the value it needs
# ("-m DIR and -o DIR"): the refusal must tell the operator what to write, not only which letters
# to pass.  When it is empty the work root is used whatever the options say, and the message only
# says to set GB10_WORK.
#
# A GB10_WORK that is not an absolute path is refused for every caller, root or not: the value is
# the root of every path the kit writes, and a relative one names a different directory in every
# directory the kit is started in.  The refusal names the variable and says what it must be.
guard_work_default()
{
	if [ -n "${GB10_WORK:-}" ]; then
		guard_work_abs "$2: GB10_WORK" "$GB10_WORK" || return 2
		return 0
	fi
	[ "$1" = 0 ] || return 0
	if [ -n "$3" ]; then
		echo "$2: running as root without GB10_WORK; set GB10_WORK=/absolute/path or pass $3 (see $2 -h)" >&2
	else
		echo "$2: running as root without GB10_WORK; set GB10_WORK=/absolute/path (see $2 -h)" >&2
	fi
	return 2
}

# guard_work_options <stage given> <copy-out given>: the options whose default the work root
# holds, with the value each needs: "-m DIR and -o DIR".  The hash list (-s) is never named: it is
# derived from the stage ($STAGE/SHA256.txt), so a stage that is given takes the hash list with it
# and naming -s would only make the operator invent a file he does not need.  One function for every
# kit, so the refusal names the same options everywhere.
guard_work_options()
{
	_o=
	[ "$1" = 1 ] || _o="-m DIR"
	[ "$2" = 1 ] || _o="${_o:+$_o and }-o DIR"
	printf '%s\n' "$_o"
}

# guard_work_root <effective uid> <repository root or empty> <kit directory>: prints the work root
# of a test-boot kit, canonical: GB10_WORK (guard_work_canon) when it is set, the work directory of
# the checkout otherwise.  It is one function for every kit, so the default is one rule and not four
# copies of it, and the work root a kit uses never comes from anywhere else.  Refusals, each with its
# reason on standard error:
#   - a GB10_WORK that is not a plain absolute path (2): it would name a different directory in
#     every directory the kit is started in;
#   - root with a GB10_WORK inside the checkout (2): the checkout belongs to the account that cloned
#     it, and root must not write into it, whichever spelling names it;
#   - no GB10_WORK and no checkout (1): a kit that lies in no checkout has no work root to take from
#     one, and the depth of its directory says nothing (it would name "/work" for a kit one directory
#     below the root of the filesystem).  The kit directory is named so the operator knows which kit.
guard_work_root()
{
	if [ -n "${GB10_WORK:-}" ]; then
		_gr_w=$(guard_work_canon GB10_WORK "$GB10_WORK") || return 2
		if [ "$1" = 0 ] && [ -n "$2" ]; then
			case $_gr_w in
			"$2" | "$2"/*)
				echo "GB10_WORK must not lie inside the checkout when the kit runs as root: $_gr_w is under $2, which belongs to the account that cloned it; set GB10_WORK to a directory outside the checkout" >&2
				return 2 ;;
			esac
		fi
		printf '%s\n' "$_gr_w"
	elif [ -n "$2" ]; then
		printf '%s/work\n' "$2"
	else
		echo "this kit lies in no checkout (${3:-its directory} is not under the tests directory of a git work tree): the work directory of a checkout is the only default; set GB10_WORK=/absolute/path" >&2
		return 1
	fi
}

# guard_repo_root <candidate root> <kit directory>: succeeds when the candidate is the root of the
# checkout the kit lies in: a git work tree whose top level is the candidate itself and whose tests
# directory holds the kit.  The depth of the kit directory is not the proof: the same arithmetic
# names "/" for a kit that was extracted on its own one directory below the root of the filesystem,
# and the work root of the checkout would then be "/work".  A ".git" entry is not the proof either:
# an empty file called .git, or a nested directory with a .git of its own inside a larger repository,
# is not a work tree whose top level is the candidate, and git says so (rev-parse --show-toplevel,
# compared with the candidate in canonical form).  Returns 1 when the candidate is not that root (the
# caller decides what a kit outside a checkout may do); it prints nothing.
guard_repo_root()
{
	_r=$1
	_kd=$2
	[ -n "$_r" ] && [ -n "$_kd" ] || return 1
	[ -e "$_r/.git" ] || return 1
	[ -d "$_r/tests" ] || return 1
	case $_kd in
	"$_r"/tests/*) ;;
	*) return 1 ;;
	esac
	_t=$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_INDEX_FILE -u GIT_OBJECT_DIRECTORY \
	    git -c safe.directory="$_r" --no-optional-locks -C "$_r" rev-parse --show-toplevel 2> /dev/null) || return 1
	[ -n "$_t" ] || return 1
	_t=$(CDPATH= cd -- "$_t" 2> /dev/null && pwd -P) || return 1
	[ "$_t" = "$_r" ] || return 1
	return 0
}

# guard_archive_root <candidate root> <kit directory>: succeeds when the candidate is the root of an
# extracted archive of the repository (git archive <commit> -- tests/...): no git metadata at the
# candidate, a tests directory, and the kit under it.  It says what the directory is, not whether the
# kit may run from it: that is the kit's decision (the native-tools kit installs an archive only
# under its documented test hooks, and no kit takes a work root from an archive).  Returns 1 when the
# candidate is not an archive root; it prints nothing.
guard_archive_root()
{
	_r=$1
	_kd=$2
	[ -n "$_r" ] && [ -n "$_kd" ] || return 1
	[ ! -e "$_r/.git" ] || return 1
	[ -d "$_r/tests" ] || return 1
	case $_kd in
	"$_r"/tests/*) ;;
	*) return 1 ;;
	esac
	return 0
}

# guard_trusted_file <effective uid> <path>: the file a kit is about to source (or read as its
# configuration) is a regular file, not a symbolic link, owned by root or by the account that runs
# the kit, and not writable by the group or by everyone.  A file that fails this is not run: it could
# have been put there, or changed, by another account.  Prints the reason and returns 2.  The kits
# apply the same rule to guard.sh itself before they source it (inline: nothing of this file runs
# before that check).
guard_trusted_file()
{
	_tf=$2
	[ -e "$_tf" ] || { echo "$_tf is missing" >&2; return 2; }
	[ ! -L "$_tf" ] || { echo "$_tf is a symbolic link" >&2; return 2; }
	[ -f "$_tf" ] || { echo "$_tf is not a regular file" >&2; return 2; }
	_ts=$(stat -f '%u %Lp' "$_tf" 2> /dev/null) || { echo "$_tf cannot be examined (stat failed)" >&2; return 2; }
	_to=${_ts%% *}
	_tm=${_ts##* }
	case $_to$_tm in '' | *[!0-9]*) echo "$_tf cannot be examined (stat printed [$_ts])" >&2; return 2 ;; esac
	[ "$_to" = 0 ] || [ "$_to" = "$1" ] || { echo "$_tf belongs to another account (uid $_to)" >&2; return 2; }
	[ $(( 0$_tm & 022 )) -eq 0 ] || { echo "$_tf is writable by the group or by everyone (mode $_tm)" >&2; return 2; }
	return 0
}

# guard_kld_names <kldstat -v file>: every file and module name of the listing, one per line
guard_kld_names()
{
	awk '
	/^Id Refs/ { next }
	/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+0x/ { print $5; next }
	/^[[:space:]]+[0-9]+[[:space:]]+/ { print $2 }
	' "$1" 2> /dev/null
}

# guard_layer_name <name>: succeeds when the name, or any /-separated part of a module record name, belongs to the
# Linux layer (the Linuxulator, LinuxKPI and its filesystems, and the drm-kmod drivers that run on LinuxKPI)
guard_layer_name()
{
	printf '%s\n' "$1" | grep -Eiq 'linux|(^|/)(lkpi|lindebugfs|linsysfs|linprocfs|drm|dmabuf|ttm|amdgpu|radeonkms|i915kms)'
}

# guard_env <kldstat -v file> <kldstat exit status> <sysctl answer file> <sysctl exit status> [<required file>...]
# The required files are the positive control: the listing must name each of them (kernel, and nvidia.ko once the
# kit loaded it), or it is not a real listing.  Prints the result line, then a line "records <list>" of the
# Linux-layer module records compiled into the kernel file (the caller reports them as info).
guard_env()
{
	_kf=$1; _ks=$2; _sf=$3; _ss=$4; shift 4
	if [ "$_ks" != 0 ]; then echo "error kldstat -v exited $_ks: the module list could not be read"; return 2; fi
	if [ ! -s "$_kf" ]; then echo "error kldstat -v printed nothing: the module list could not be read"; return 2; fi
	for _req in kernel "$@"; do
		if ! awk -v r="$_req" '/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+0x/ && $5 == r { f = 1 } END { exit f ? 0 : 1 }' "$_kf"; then
			echo "error the kldstat -v listing does not name $_req (positive control): it is not a complete listing"
			return 2
		fi
	done
	# file|name for every file (record "F") and every module record ("M"), the file it lies in first
	_recs=$(awk '
	/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+0x/ { f = $5; print "F|" f "|" f; next }
	/^[[:space:]]+[0-9]+[[:space:]]+/ && f != "" { print "M|" f "|" $2 }
	' "$_kf")
	_badf=; _badm=; _krec=
	_oifs=$IFS; IFS='
'
	for _r in $_recs; do
		_t=${_r%%|*}; _rest=${_r#*|}; _file=${_rest%%|*}; _name=${_rest#*|}

		guard_layer_name "$_name" || continue
		if [ "$_file" = kernel ]; then
			[ "$_t" = M ] && _krec="$_krec $_name"
		elif [ "$_t" = F ]; then
			_badf="$_badf $_name"
		else
			_badm="$_badm $_file:$_name"
		fi
	done
	IFS=$_oifs
	_krec=${_krec# }
	if [ -n "$_badf" ] || [ -n "$_badm" ]; then
		echo "fail loaded Linux-layer files:${_badf:- none}; Linux-layer module records in loaded files:${_badm:- none}; build the boot environment from a base that loads none of them (make-be.sh strips amdgpu, drm and the Linux ABI from kld_list, and check-be.sh shows what still loads)"
		echo "records $_krec"
		return 1
	fi
	if [ "$_ss" = 0 ]; then
		echo "fail sysctl compat.linux answers ($(head -c 120 "$_sf" | tr '\n' ' ')): the Linux ABI is present (compiled into the kernel, or loaded); boot a kernel without COMPAT_LINUX"
		echo "records $_krec"
		return 1
	fi
	if ! grep -q 'unknown oid' "$_sf" 2> /dev/null; then
		echo "error sysctl compat.linux failed (exit $_ss) without unknown oid: $(head -c 120 "$_sf" | tr '\n' ' '): the probe could not look; run it as root"
		echo "records $_krec"
		return 2
	fi
	echo "pass no Linux-layer file is loaded and compat.linux is an unknown oid; Linux-layer module records compiled into the kernel (not loaded files): ${_krec:-none}"
	echo "records $_krec"
	return 0
}

# guard_lkpi_imports <ko> <LinuxKPI module>...: the undefined symbols of the module that a LinuxKPI module defines
# (nm -u against nm -g --defined-only), the linker-set bounds __start_set_* and __stop_set_* left out (every module
# has them).  This catches a call into LinuxKPI by any name (idr_alloc, kasprintf), with or without a MODULE_DEPEND:
# the kernel may carry LinuxKPI built in.  No LinuxKPI module given, or one nm cannot read, is an error.
guard_lkpi_imports()
{
	_ko=$1; shift
	[ $# -gt 0 ] || { echo "error no LinuxKPI module to compare $_ko with (linuxkpi.ko beside the kernel)"; return 2; }
	_def=
	for _m in "$@"; do
		_o=$(nm -g --defined-only "$_m" 2> /dev/null) && [ -n "$_o" ] || { echo "error nm could not read the symbols of $_m"; return 2; }
		_def="$_def
$(printf '%s\n' "$_o" | awk 'NF >= 3 { print $3 }')"
	done
	_und=$(nm -u "$_ko" 2> /dev/null) && [ -n "$_und" ] || { echo "error nm -u could not read $_ko"; return 2; }
	_hit=$( { printf '%s\n' "$_def" | sort -u; printf '%s\n' "$_und" | awk '{ print $NF }' | sort -u; } | sort | uniq -d | grep -Ev '^__(start|stop)_set_' | tr '\n' ' ')
	if [ -n "$_hit" ]; then echo "fail ${_ko##*/} imports symbols LinuxKPI defines: ${_hit% }"; return 1; fi
	echo "pass ${_ko##*/} imports nothing LinuxKPI defines (compared with $*)"
	return 0
}

# guard_ko_native <ko> <scratch dir> <LinuxKPI module>...: the module declares no dependency on the Linux layer
# (kldxref -d -v, guard_layer_name), has no undefined linux_, lkpi_ or linuxkpi_ symbol (guard_undef) and imports
# nothing a LinuxKPI module defines (guard_lkpi_imports).  The positive control for kldxref is the module record of
# the file itself ("module <name>"): without it kldxref did not read the file, an error.  No dependency is a pass.
guard_ko_native()
{
	_k=$1; _sd=$2; shift 2
	case $_sd in */kodep) ;; *) echo "error the scratch directory $_sd must end in /kodep (it is removed)"; return 2 ;; esac
	rm -rf "$_sd"; mkdir -p "$_sd" && cp "$_k" "$_sd/" || { echo "error $_k could not be copied to $_sd for kldxref"; return 2; }
	kldxref -d -v "$_sd" > "$_sd.out" 2>&1; _xs=$?
	rm -rf "$_sd"
	if [ "$_xs" != 0 ] || ! grep -q '^[[:space:]]*module ' "$_sd.out"; then
		echo "error kldxref -d -v exited $_xs and printed no module record for $_k: $(head -c 160 "$_sd.out" | tr '\n' ' ')"
		rm -f "$_sd.out"; return 2
	fi
	_d=$(sed -n 's/^[[:space:]]*depends on \([^.[:space:]]*\)\..*/\1/p' "$_sd.out" | sort -u | tr '\n' ' ')
	rm -f "$_sd.out"
	_bad=
	for _x in $_d; do if guard_layer_name "$_x"; then _bad="$_bad $_x"; fi; done
	if [ -n "$_bad" ]; then echo "fail ${_k##*/} depends on$_bad: it needs the Linux layer; build nvidia.ko and nvidia-modeset.ko from main (no Linux dependency since #2363) and stage them with -m"; return 1; fi
	_ul=$(guard_undef "$_k"); _us=$?
	[ "$_us" = 0 ] || { echo "$_ul"; return "$_us"; }
	_ll=$(guard_lkpi_imports "$_k" "$@"); _ls=$?
	[ "$_ls" = 0 ] || { echo "$_ll"; return "$_ls"; }
	echo "pass ${_k##*/} depends only on ${_d:-nothing}, has no undefined Linux or LinuxKPI symbol, and imports nothing LinuxKPI defines"
	return 0
}

# guard_env_delta <kldstat -v before> <kldstat -v after>: names in the second listing that the first does not have
guard_env_delta()
{
	guard_kld_names "$1" | sort -u > "$2.names-before"
	guard_kld_names "$2" | sort -u > "$2.names-after"
	_new=$(comm -13 "$2.names-before" "$2.names-after" | tr '\n' ' ')
	rm -f "$2.names-before" "$2.names-after"
	if [ -n "$_new" ]; then echo "fail modules appeared during the row: ${_new% }"; return 1; fi
	echo "pass no module appeared during the row"
	return 0
}

# guard_brand <path>: a FreeBSD-branded ELF, or a #! script; anything else fails, an unreadable file is an error
guard_brand()
{
	if [ ! -r "$1" ]; then echo "error $1 cannot be read"; return 2; fi
	_magic=$(head -c 4 "$1" | od -An -tx1 | tr -d ' \n')
	case $_magic in
	7f454c46)
		_b=$(brandelf "$1" 2>&1 | sed -n "s/.* is of brand '\([^']*\)'.*/\1/p")
		if [ "$_b" = FreeBSD ]; then echo "pass $1 is a FreeBSD-branded ELF"; return 0; fi
		# an ELF with no OS/ABI byte is still FreeBSD when it carries the FreeBSD ABI note
		if [ "$_b" = SVR4 ] && readelf -n "$1" 2> /dev/null | grep -q 'FreeBSD.*NT_FREEBSD_ABI_TAG'; then
			echo "pass $1 is an ELF with the FreeBSD ABI note"; return 0
		fi
		echo "fail $1 is an ELF of brand '${_b:-unknown}', not FreeBSD"
		return 1 ;;
	2321*)
		echo "pass $1 is a #! script (its interpreter is checked as its own exec)"
		return 0 ;;
	*)
		echo "fail $1 is neither an ELF nor a #! script (magic $_magic)"
		return 1 ;;
	esac
}


# guard_elf <path>: a FreeBSD-branded ELF only (the staged nvrm-info and libnvrm.so.1: a #! script is not one)
guard_elf()
{
	if [ ! -r "$1" ]; then echo "error $1 cannot be read"; return 2; fi
	[ "$(head -c 4 "$1" | od -An -tx1 | tr -d ' \n')" = 7f454c46 ] || { echo "fail $1 is not an ELF file"; return 1; }
	guard_brand "$1"
}

# guard_trace <kdump text> <tool path> <report file>: every exec of the traced row.  kdump prints "pid comm EVENT ..."
# and comm may hold spaces, so the event is found by its name, not by a field number; a line of no known shape is an
# error.  The paths the kernel looked up between an execve call and its return (the image, a #! interpreter, the ELF
# interpreter) are the files that ran when the call returned success (JUSTRETURN or 0); after a failed execve (a
# PATH search miss) they are dropped.  Every file that ran must still exist at an absolute path and pass guard_brand:
# a relative or a vanished path is an error (it cannot be checked).  The tool itself must be among them (positive
# control).  Any kldload or kldunload call fails (kldunload names a file id, not a module, so any one fails).  The
# report file gets one line per file checked.
guard_trace()
{
	_dump=$1; _tool=$2; _rep=$3
	: > "$_rep"
	if [ ! -s "$_dump" ]; then echo "error the trace is empty: the row was not traced"; return 2; fi
	awk '
	function flush(p) { if (buf[p] == "") print "unresolved " p; else { n = split(buf[p], a, "\n"); for (i = 1; i <= n; i++) if (a[i] != "") print "exec " a[i] } delete buf[p] }
	{
		pid = $1
		if (!match($0, / (CALL|RET|NAMI) +/)) { print "unparsed " $0; next }
		ev = substr($0, RSTART + 1, RLENGTH - 1); sub(/ +$/, "", ev)
		arg = substr($0, RSTART + RLENGTH)
	}
	ev == "CALL" && arg ~ /^kldload\(/ { print "kldload " arg }
	ev == "CALL" && arg ~ /^kldunload/ { print "kldunload " arg }
	ev == "CALL" && arg ~ /^fexecve\(/ { print "unresolved " pid; inexec[pid] = 1; buf[pid] = ""; next }
	ev == "CALL" && arg ~ /^execve\(/ { inexec[pid] = 1; buf[pid] = ""; next }
	ev == "CALL" { if (inexec[pid]) { flush(pid); inexec[pid] = 0 } next }
	ev == "NAMI" && inexec[pid] { p = arg; sub(/^"/, "", p); sub(/"$/, "", p); buf[pid] = buf[pid] p "\n"; next }
	ev == "RET" && arg ~ /^f?execve / {
		if (arg ~ /^f?execve (JUSTRETURN|0)( |$)/) flush(pid); else delete buf[pid]
		inexec[pid] = 0
	}
	END { for (p in inexec) if (inexec[p]) flush(p) }
	' "$_dump" > "$_rep.raw"
	_rc=0; _err=0; _seen_tool=0; _n=0
	if grep -q '^unparsed ' "$_rep.raw"; then
		echo "error a trace line has no CALL, RET or NAMI: $(grep '^unparsed ' "$_rep.raw" | head -1 | cut -c10-90)" >> "$_rep"
		_err=1
	fi
	if grep -q '^unresolved ' "$_rep.raw"; then
		echo "error process $(grep '^unresolved ' "$_rep.raw" | head -1 | cut -c12-) ran an exec whose image has no path in the trace (fexecve of a descriptor, or lost NAMI records): it cannot be checked" >> "$_rep"
		_err=1
	fi
	if grep -qE '^(kldload|kldunload) ' "$_rep.raw"; then
		grep -E '^(kldload|kldunload) ' "$_rep.raw" | head -3 >> "$_rep"
		_rc=1
	fi
	while IFS= read -r _l; do
		case $_l in exec\ *) ;; *) continue ;; esac
		_p=${_l#exec }
		case $_p in
		/*) ;;
		*) echo "error a file ran by the relative path $_p: it cannot be checked" >> "$_rep"; _err=1; continue ;;
		esac
		if [ ! -e "$_p" ]; then echo "error $_p ran but no longer exists: it cannot be checked" >> "$_rep"; _err=1; continue; fi
		[ "$_p" != "$_tool" ] || _seen_tool=1
		_n=$((_n + 1))
		_r=$(guard_brand "$_p"); _s=$?
		echo "$_r" >> "$_rep"
		case $_s in 0) ;; 1) _rc=1 ;; *) _err=1 ;; esac
	done < "$_rep.raw"
	rm -f "$_rep.raw"
	if [ "$_rc" = 1 ]; then
		echo "fail the row ran a file that is not FreeBSD-native, or called kldload or kldunload: $(grep -E '^(fail|kldload|kldunload)' "$_rep" | head -3 | tr '\n' ';')"
		return 1
	fi
	if [ "$_err" = 1 ]; then echo "error the trace could not be checked completely: $(grep '^error' "$_rep" | head -1 | cut -c7-)"; return 2; fi
	if [ "$_seen_tool" != 1 ]; then echo "error the trace has no exec of $_tool (positive control): the row was not traced"; return 2; fi
	echo "pass $_n executed file(s), each FreeBSD-native; no kldload or kldunload"
	return 0
}

# guard_undef <module>: the undefined symbols of a .ko that belong to the Linuxulator or LinuxKPI (linux_, lkpi_,
# linuxkpi_).  pass with none, fail with the names, error when nm fails or lists no undefined symbol at all (every
# module needs some kernel symbol: an empty list means nm did not read it).
guard_undef()
{
	_nm=$(nm -u "$1" 2> /dev/null); _ns=$?
	if [ "$_ns" != 0 ]; then echo "error nm -u $1 exited $_ns: its symbols could not be read"; return 2; fi
	if [ -z "$_nm" ]; then echo "error nm -u $1 lists no undefined symbol: it could not be read"; return 2; fi
	_lx=$(printf '%s\n' "$_nm" | awk '$NF ~ /^(linux_|lkpi_|linuxkpi_)/ { print $NF }' | sort -u | tr '\n' ' ')
	if [ -n "$_lx" ]; then echo "fail $1 has undefined Linux or LinuxKPI symbols: ${_lx% }"; return 1; fi
	echo "pass $1 has no undefined Linux or LinuxKPI symbol"
	return 0
}

# guard_plain_path <path>: an absolute path of letters, numbers and / . _ - in plain form (no trailing /, //, . or ..
# component): the one-shot compares the physical path of the directory it makes with this text
guard_plain_path()
{
	case $1 in /*) ;; *) echo "fail $1 is not an absolute path"; return 1 ;; esac
	case $1 in *[!A-Za-z0-9/._-]*) echo "fail $1 may hold letters, numbers and / . _ - only"; return 1 ;; esac
	case $1 in */ | *//* | */./* | */../* | */. | */..) echo "fail $1 is not in plain form (no trailing /, //, . or .. component)"; return 1 ;; esac
	echo "pass $1 is a plain absolute path"
	return 0
}

# guard_copyout_dataset <copy-out path> <its dataset> <bootfs of every pool, one per word>: the copy-out must lie
# outside every boot environment root (the parent of a pool's bootfs, whatever its name: zroot/ROOT, zroot/bootenv,
# ...), or the run is written into the test boot environment and lost on the return.  A pool without bootfs ("-") has
# no boot environments.  No dataset, or no pool with a bootfs at all, is an error.
guard_copyout_dataset()
{
	_co=$1; _ds=$2; shift 2
	if [ -z "$_ds" ]; then echo "error copy-out $_co: no dataset found for it: it cannot be told whether it survives the return"; return 2; fi
	_roots=
	for _bf in "$@"; do
		case $_bf in '' | -) continue ;; */*) ;; *) echo "error copy-out $_co: bootfs '$_bf' is not a dataset below a pool"; return 2 ;; esac
		_br=${_bf%/*}
		_roots="$_roots $_br"
		case $_ds in
		"$_br" | "$_br"/*) echo "fail copy-out $_co is on $_ds, under the boot environment root $_br: the run would be lost on the return"; return 1 ;;
		esac
	done
	if [ -z "$_roots" ]; then echo "error copy-out $_co: no pool has a bootfs: the boot environment root cannot be told"; return 2; fi
	echo "pass copy-out $_co is on $_ds, outside the boot environment root(s)$_roots"
	return 0
}

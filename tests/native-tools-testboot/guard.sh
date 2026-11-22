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
#   - modules: no loaded kld file or module whose name contains "linux" (the Linuxulator linux, linux64,
#     linux_common; LinuxKPI linuxkpi, linuxkpi_video and lindebugfs (which is matched by name too); the optional NVIDIA bridges nvidia_linux and
#     nvidia_modeset_linux; any future one), and the Linux ABI not compiled into the kernel (sysctl compat.linux
#     answers only "unknown oid");
#   - binaries: every file a row executes (from its ktrace: the image and the interpreters the kernel opened for each
#     execve, which covers a #! script's interpreter and the ELF run-time linker) is a FreeBSD-branded ELF, or a #!
#     script; a row that calls kldload or kldunload fails (the trace names a file id for kldunload, not a module).

# guard_kld_names <kldstat -v file>: every file and module name of the listing, one per line
guard_kld_names()
{
	awk '
	/^Id Refs/ { next }
	/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+0x/ { print $5; next }
	/^[[:space:]]+[0-9]+[[:space:]]+/ { print $2 }
	' "$1" 2> /dev/null
}

# guard_env <kldstat -v file> <kldstat exit status> <sysctl answer file> <sysctl exit status> [<required file>...]
# The required files are the positive control: the listing must name each of them (kernel, and nvidia.ko once the
# kit loaded it), or it is not a real listing.
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
	_bad=$(guard_kld_names "$_kf" | grep -iE 'linux|lindebugfs|^lkpi' | sort -u | tr '\n' ' ')
	if [ -n "$_bad" ]; then
		echo "fail loaded modules whose name contains linux: ${_bad% }; build the boot environment from a base that loads none of them (make-be.sh strips amdgpu, drm and the Linux ABI from kld_list)"
		return 1
	fi
	if [ "$_ss" = 0 ]; then
		echo "fail sysctl compat.linux answers ($(head -c 120 "$_sf" | tr '\n' ' ')): the Linux ABI is present (compiled into the kernel, or loaded)"
		return 1
	fi
	if ! grep -q 'unknown oid' "$_sf" 2> /dev/null; then
		echo "error sysctl compat.linux failed (exit $_ss) without unknown oid: $(head -c 120 "$_sf" | tr '\n' ' '): the probe could not look"
		return 2
	fi
	echo "pass no loaded module name contains linux, and compat.linux is an unknown oid"
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

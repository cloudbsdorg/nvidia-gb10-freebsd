# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-2-Clause
#
# guard.sh - the no-Linux guard of the native-tools test boot (Track #2362), sourced by the rc one-shot
# nvidia_native_tools_testboot and by tests/native_tools_kit_test.sh.  It only reads: kldstat output, a sysctl
# answer, ELF headers and ktrace dumps.  Each function prints one line "<status> <detail>" on standard output, with
# status pass, fail or error, and returns 0 for pass, 1 for fail, 2 for error.  error means the guard could not look:
# it is never read as "found nothing".
#
# The rc.conf and rc.d helpers (guard_rcconf_values, guard_rcconf_value, guard_rcconf_isset, guard_rc_expand,
# guard_rc_modules, guard_rc_services, guard_rc_offenders, guard_rc_forbidden, guard_hwprobe_loads,
# guard_devd_loaders, guard_rc_loaders) read the configuration of a tree as well: which service is enabled, and
# which module an enabled service loads by itself (a required_modules entry).  make-be.sh and check-be.sh use them
# for the clone, and the guard uses them (with GUARD_ROOT set) to name the loader it can see.  The rule is one list
# (GUARD_FORBID_RE) and one reader (guard_rcconf_pairs), so every caller reads the configuration the same way.
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

# guard_work_default <effective uid> <program> <defaulted options>: root must not silently use root's home for these
# paths; the caller exits with this function's status.  Non-root and an explicitly set GB10_WORK keep the old default.
guard_work_default()
{
	[ "$1" = 0 ] && [ -z "${GB10_WORK:-}" ] || return 0
	echo "$2: running as root without GB10_WORK; set GB10_WORK or pass $3" >&2
	return 2
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
	printf '%s\n' "$1" | grep -Eiq "$GUARD_LINUX_RE"
}

# The module names the kit refuses in a boot environment without the driver.  One list, used by the guard, by
# make-be.sh (which turns off the service that loads one) and by check-be.sh (which refuses a clone that has one):
# the Linux layer (the Linuxulator, LinuxKPI, the DRM modules and the KMS drivers) and the nvidia modules (the kit
# loads its own nvidia.ko, nothing else may).
GUARD_FORBID_RE='linux|(^|/)(lkpi|lindebugfs|linsysfs|linprocfs|drm|dmabuf|ttm|amdgpu|radeonkms|i915kms)|^nvidia'
# The Linux-layer names alone: the nvidia modules are not Linux-layer names, the kit loads its own nvidia.ko.
GUARD_LINUX_RE='linux|(^|/)(lkpi|lindebugfs|linsysfs|linprocfs|drm|dmabuf|ttm|amdgpu|radeonkms|i915kms)'
# The service that loads a driver without a required_modules entry: the hwprobe runs a probe that loads the KMS
# driver of the card it finds.  Its command "probe" loads nothing.  It is the only service the kit names.
GUARD_HWPROBE=cloudbsd_hwprobe

# guard_kld_deps <scratch dir> <module file>: the names of the modules this file depends on, one per line.  kldxref
# reads a directory, so the file is copied into one of its own.  A file that cannot be copied is an error (2).
guard_kld_deps()
{
	_gd=$1; _gf=$2
	rm -rf "$_gd"; mkdir -p "$_gd" 2> /dev/null || return 2
	cp "$_gf" "$_gd/" 2> /dev/null || return 2
	kldxref -d -v "$_gd" 2> /dev/null | sed -n 's/^[[:space:]]*depends on \([^.[:space:]]*\)\..*/\1/p' | sort -u
}

# guard_linux_modules <scratch dir> <module dir>...: the names (without .ko) of the modules of these directories that
# depend on the Linux layer, one per line.  devmatch loads a driver of its own when it sees the device of it (a Wi-Fi
# card in the host brings a LinuxKPI driver with it), so a module that pulls the Linux layer in has to be blocked in
# a boot environment without the driver.  The modules of the kit (nvidia*) are never named: the kit loads its own
# nvidia.ko and refuses every other one.
guard_linux_modules()
{
	_gd=$1; shift
	for _gdir in "$@"; do
		[ -d "$_gdir" ] || continue
		for _gko in "$_gdir"/*.ko; do
			[ -f "$_gko" ] || continue
			_gname=${_gko##*/}; _gname=${_gname%.ko}
			case $_gname in nvidia*) continue ;; esac
			for _gdep in $(guard_kld_deps "$_gd" "$_gko"); do
				if guard_layer_name "$_gdep"; then
					printf '%s\n' "$_gname"
					break
				fi
			done
		done
	done
	rm -rf "$_gd"
}

# The loader of a module is not always the loader list: an enabled rc.d service with a required_modules entry loads a
# module by itself (drm_ready loads amdgpu, and the base BE has it enabled), and a devd hotplug rule can start such a
# service (cloudbsd_hwprobe loads the KMS driver of the card it finds).  The helpers below read the rc.conf of a tree
# and the rc.d scripts of a tree, so make-be.sh (which turns such a service off in the clone), check-be.sh (which
# refuses a clone that still has one) and this guard (which names the loader it can see) all say the same thing.

# The one rule for the value of an assignment: a value in quotes is taken as it is; an unquoted one up to the
# first space, with the comment after it left out.  Every reader of a value uses it, so a value is read the
# same way everywhere: the rc.conf (guard_rcconf_pairs) and the defaults of a script
# (guard_rc_service_defaults) are read with the same function.
GUARD_RC_STRIP_AWK='
function strip(v) {
	if (substr(v, 1, 1) == "\"") {
		r = substr(v, 2); e = index(r, "\"")
		if (e > 0) return substr(r, 1, e - 1)
	}
	if (substr(v, 1, 1) == "\047") {
		r = substr(v, 2); e = index(r, "\047")
		if (e > 0) return substr(r, 1, e - 1)
	}
	sub(/[ \t]+#.*/, "", v); sub(/[ \t].*$/, "", v)
	return v
}
'

# guard_rcconf_pairs [<file> ...]: the assignments of the files, one "name<TAB>value" per line, in the order the
# files are given.  The value is read with the one rule (GUARD_RC_STRIP_AWK).  Every reader of an rc.conf value
# uses this one reader, so a value is read the same way everywhere (guard_rcconf_value, guard_rcconf_isset,
# guard_rc_expand).
guard_rcconf_pairs()
{
	awk "$GUARD_RC_STRIP_AWK"'
	{
		line = $0
		sub(/^[ \t]+/, "", line)
		if (line !~ /^[A-Za-z_][A-Za-z0-9_]*=/) next
		eq = index(line, "=")
		name = substr(line, 1, eq - 1)
		print name "\t" strip(substr(line, eq + 1))
	}
	' "$@" 2> /dev/null
}

# guard_rcconf_values <root> [<service>]: the assignments in effect for a service, in the order rc(8) reads them:
# /etc/rc.conf, /etc/rc.conf.local, /usr/local/etc/rc.conf, /usr/local/etc/rc.conf.local, then the file of the
# service itself (/etc/rc.conf.d/<service> and /usr/local/etc/rc.conf.d/<service>, which rc.subr reads last, so
# they win).  Only the file of the service is read from rc.conf.d: load_rc_config in rc.subr reads
# rc.conf.d/<name> for the service it loads and no other file of rc.conf.d.  One "name<TAB>value" per line.
guard_rcconf_values()
{
	_root=$1; _svc=$2
	for _f in "$_root/etc/rc.conf" "$_root/etc/rc.conf.local" "$_root/usr/local/etc/rc.conf" "$_root/usr/local/etc/rc.conf.local"; do
		[ -f "$_f" ] || continue
		guard_rcconf_pairs "$_f"
	done
	[ -n "$_svc" ] || return 0
	for _d in "$_root/etc/rc.conf.d" "$_root/usr/local/etc/rc.conf.d"; do
		[ -d "$_d" ] || continue
		if [ -f "$_d/$_svc" ]; then
			guard_rcconf_pairs "$_d/$_svc"
		elif [ -d "$_d/$_svc" ]; then
			for _g in $(find "$_d/$_svc" -type f 2> /dev/null | LC_ALL=C sort); do
				guard_rcconf_pairs "$_g"
			done
		fi
	done
}

# guard_rcconf_value <name>: the value of a variable; the last assignment wins.  The assignments come on standard
# input (guard_rcconf_pairs).
guard_rcconf_value()
{
	awk -F'\t' -v n="$1" '$1 == n { v = $2 } END { print v }'
}

# guard_rcconf_isset <name>: succeeds when the variable is set (it may be set to nothing).  The assignments come on
# standard input (guard_rcconf_pairs).
guard_rcconf_isset()
{
	awk -F'\t' -v n="$1" '$1 == n { f = 1 } END { exit f ? 0 : 1 }'
}

# guard_rc_service_defaults <rc script>: the assignments the script itself makes, one "name<TAB>value" per line:
# the ": ${var:=default}" idiom (the first one wins, as in the shell) and the plain assignments.  The name of the
# script, its rcvar and its module list are left out: they are not configuration.  rc(8) reads the script before the
# rc.conf of the service, so these values are the ones the rc.conf overrides.  The value is read with the one rule
# (GUARD_RC_STRIP_AWK), the rule the rc.conf is read with.
guard_rc_service_defaults()
{
	awk "$GUARD_RC_STRIP_AWK"'
	{
		line = $0
		sub(/^[ \t]+/, "", line)
		# the ": ${var:=default}" idiom: the default of a variable that is not set yet
		if (match(line, /:[[:space:]]*"?\$[{][A-Za-z_][A-Za-z0-9_]*(:=|=)[^}]*[}]"?/)) {
			s = substr(line, RSTART, RLENGTH)
			sub(/^:?[[:space:]]*"?\$[{]/, "", s)
			sub(/[}]"?$/, "", s)
			p = index(s, ":=")
			if (p > 0) { name = substr(s, 1, p - 1); val = substr(s, p + 2) }
			else { p = index(s, "="); name = substr(s, 1, p - 1); val = substr(s, p + 1) }
			if (!(name in seen)) { seen[name] = 1; print name "\t" strip(val) }
			next
		}
		# a plain assignment
		if (line !~ /^[A-Za-z_][A-Za-z0-9_]*=/) next
		eq = index(line, "=")
		name = substr(line, 1, eq - 1)
		if (name == "required_modules" || name == "name" || name == "rcvar") next
		print name "\t" strip(substr(line, eq + 1))
	}
	' "$1" 2> /dev/null
}

# guard_rc_values <root> <service>: the values in effect for a service: the ones the script itself sets (its
# defaults) and then the ones of the rc.conf of the tree, the rc.conf.d file of the service last.  rc(8) reads the
# script before the rc.conf, so the rc.conf wins.  One "name<TAB>value" per line.
guard_rc_values()
{
	_root=$1; _svc=$2
	_s=
	for _d in "$_root/etc/rc.d" "$_root/usr/local/etc/rc.d"; do
		if [ -f "$_d/$_svc" ]; then _s=$_d/$_svc; break; fi
	done
	[ -z "$_s" ] || guard_rc_service_defaults "$_s"
	guard_rcconf_values "$_root" "$_svc"
}

# guard_rc_expand <raw string> [<value of required_modules so far>]: the string with its ${var}, ${var:-default},
# ${var-default}, ${var:=default}, ${var=default}, ${var:+word} and $var references expanded; the assignments come on
# standard input (guard_rcconf_pairs).  A variable that is not set is different from one that is set to nothing:
# ${var-default} and ${var=default} take the default when the variable is not set, ${var:-default} and
# ${var:=default} when it is empty or not set.
guard_rc_expand()
{
	awk -F'\t' -v raw="$1" -v acc="${2:-}" '
	function val(n) {
		if (n == "required_modules") return acc
		return (n in V) ? V[n] : ""
	}
	function isset(n) {
		if (n == "required_modules") return (acc != "")
		return (n in V)
	}
	function expand(inner,   p, op, rest, name, v, has) {
		op = ""; rest = ""
		p = index(inner, ":-")
		if (p > 0) { op = ":-"; rest = substr(inner, p + 2) }
		else {
			p = index(inner, ":=")
			if (p > 0) { op = ":="; rest = substr(inner, p + 2) }
			else {
				p = index(inner, ":+")
				if (p > 0) { op = ":+"; rest = substr(inner, p + 2) }
				else {
					p = index(inner, "-")
					if (p > 1) { op = "-"; rest = substr(inner, p + 1) }
					else {
						p = index(inner, "=")
						if (p > 1) { op = "="; rest = substr(inner, p + 1) }
					}
				}
			}
		}
		name = (op == "") ? inner : substr(inner, 1, p - 1)
		v = val(name)
		has = isset(name)
		if (op == "") return v
		if (op == ":-" || op == ":=") return (v == "") ? rest : v
		if (op == ":+") return (v == "") ? "" : rest
		if (op == "-" || op == "=") return has ? v : rest
		return v
	}
	{
		V[$1] = $2
	}
	END {
		s = raw
		if (substr(s, 1, 1) == "\"" && substr(s, length(s), 1) == "\"") s = substr(s, 2, length(s) - 2)
		else if (substr(s, 1, 1) == "\047" && substr(s, length(s), 1) == "\047") s = substr(s, 2, length(s) - 2)
		out = ""; i = 1; n = length(s)
		while (i <= n) {
			c = substr(s, i, 1)
			if (c == "$" && i < n) {
				j = i + 1
				if (substr(s, j, 1) == "{") {
					k = index(substr(s, j), "}")
					if (k > 0) {
						out = out expand(substr(s, j + 1, k - 2))
						i = j + k
						continue
					}
				}
				if (match(substr(s, j), /^[A-Za-z_][A-Za-z0-9_]*/)) {
					out = out val(substr(s, j, RLENGTH))
					i = j + RLENGTH
					continue
				}
			}
			out = out c
			i++
		}
		print out
	}
	'
}

# guard_rc_refs <raw string>: the variable references of the string, one "<name>|<bare|op>" per line.  A bare
# reference ($var or ${var}) needs the variable to be set; a reference with an operator (${var:-x} and the like)
# takes its default when it is not set, so it does not.
guard_rc_refs()
{
	printf '%s' "$1" | awk '
	function split_ref(inner,   p, nm) {
		p = index(inner, ":-")
		if (p == 0) p = index(inner, ":=")
		if (p == 0) p = index(inner, ":+")
		if (p == 0) { p = index(inner, "-"); if (p <= 1) p = 0 }
		if (p == 0) { p = index(inner, "="); if (p <= 1) p = 0 }
		if (p == 0) { nm = inner; kind = "bare" }
		else {
			nm = substr(inner, 1, p - 1)
			kind = "op"
			if (index(inner, ":-") || index(inner, ":=") || index(inner, ":+")) kind = "op"
		}
		return nm "|" kind
	}
	{
		s = $0; n = length(s); i = 1
		while (i <= n) {
			c = substr(s, i, 1)
			if (c == "$" && i < n) {
				j = i + 1
				if (substr(s, j, 1) == "{") {
					k = index(substr(s, j), "}")
					if (k > 0) {
						print split_ref(substr(s, j + 1, k - 2))
						i = j + k
						continue
					}
				}
				if (match(substr(s, j), /^[A-Za-z_][A-Za-z0-9_]*/)) {
					print substr(s, j, RLENGTH) "|bare"
					i = j + RLENGTH
					continue
				}
			}
			i++
		}
	}
	'
}

# guard_rc_service_raw <rc script>: the raw required_modules assignments of an rc script, one per line
guard_rc_service_raw()
{
	grep -E '^[[:space:]]*required_modules=' "$1" 2> /dev/null | sed -e 's/^[[:space:]]*required_modules=//' -e 's/;.*$//' -e 's/[[:space:]]*$//'
}

# guard_rc_service_name <rc script>: the name of the script (its name= line)
guard_rc_service_name()
{
	sed -n 's/^[[:space:]]*name=//p' "$1" 2> /dev/null | head -1 | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'\$//" -e 's/[[:space:]]*#.*$//' -e 's/[[:space:]]*$//'
}

# guard_rc_service_rcvar <rc script> [<name of the script>]: the rcvar of the script, or nothing when it cannot be
# read.  The common idiom "rcvar=${name}_enable" is resolved with the name of the script.
guard_rc_service_rcvar()
{
	_s=$1; _n=${2:-}
	_rv=$(sed -n 's/^[[:space:]]*rcvar=//p' "$_s" 2> /dev/null | head -1)
	_rv=$(printf '%s' "$_rv" | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'\$//" -e 's/[[:space:]]*#.*$//' -e 's/[[:space:]]*$//')
	[ -n "$_n" ] || { printf '%s' "$_rv"; return 0; }
	_rv=$(printf '%s' "$_rv" | awk -v n="$_n" '{ gsub(/[$][{]name[}]/, n); gsub(/[$]name/, n); print }')
	case $_rv in
	[A-Za-z_][A-Za-z0-9_]*) printf '%s' "$_rv" ;;
	*) printf '' ;;
	esac
}

# guard_rc_modules <raw>: the modules of a required_modules entry, expanded with the values in effect for the
# service (the values come on standard input, as for guard_rc_expand).  The entry may be more than one line: the
# modules of the lines are accumulated, as rc(8) reads them.  Prints the modules and returns 0; prints nothing and
# returns 1 when the modules cannot be read: a variable the entry names without an operator is not set, or a
# reference is left after the expansion.  A service whose modules cannot be read is a service that is not known.
guard_rc_modules()
{
	_raw=$1
	_vals=$(cat)
	_acc=; _unknown=
	while IFS= read -r _r; do
		[ -n "$_r" ] || continue
		# every variable the entry names without an operator must be set, or the modules are unknown
		while IFS='|' read -r _rn _rk; do
			[ "$_rk" = bare ] || continue
			[ "$_rn" = required_modules ] && continue
			printf '%s\n' "$_vals" | guard_rcconf_isset "$_rn" || _unknown=1
		done <<EOF
$(guard_rc_refs "$_r")
EOF
		_exp=$(printf '%s\n' "$_vals" | guard_rc_expand "$_r" "$_acc")
		case $_exp in
		*'$'*) _unknown=1 ;;
		esac
		_acc="$_acc $_exp"
	done <<EOF
$_raw
EOF
	[ -z "$_unknown" ] || return 1
	printf '%s' "$_acc" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

# guard_rc_services <root>: one line per rc script of the tree that has a required_modules entry:
# "<service>|<rcvar>|<state>|<modules>".
#   - the rcvar of the script is read from its rcvar= line; the common "rcvar=${name}_enable" idiom is resolved with
#     the name= of the script;
#   - the modules of the entry are expanded with the values of the script (its own defaults) and of the rc.conf of
#     the tree, the rc.conf.d file of the service last;
#   - the state of the service is yes when it is enabled, no when it is disabled, unknown when the enable state
#     cannot be read (the script has no rcvar: devd starts such a service per device) and unreadable when the
#     modules cannot be read (the entry names a variable that is not set).  A service that is not read is a service
#     that is not known: the caller must refuse it, not ignore it.
guard_rc_services()
{
	_root=$1
	for _d in "$_root/etc/rc.d" "$_root/usr/local/etc/rc.d"; do
		[ -d "$_d" ] || continue
		for _s in "$_d"/*; do
			[ -f "$_s" ] || continue
			_svc=${_s##*/}
			_raw=$(guard_rc_service_raw "$_s")
			[ -n "$_raw" ] || continue
			_name=$(guard_rc_service_name "$_s")
			_rv=$(guard_rc_service_rcvar "$_s" "$_name")
			_vals=$(guard_rc_values "$_root" "$_svc")
			if ! _mods=$(printf '%s\n' "$_vals" | guard_rc_modules "$_raw"); then
				# the modules cannot be read: the caller must refuse the service
				printf '%s|%s|unreadable|%s\n' "$_svc" "$_rv" "$_raw"
				continue
			fi
			if [ -z "$_rv" ]; then
				# the enable state cannot be read: the service has no rcvar
				printf '%s|?|unknown|%s\n' "$_svc" "$_mods"
				continue
			fi
			_rcval=$(printf '%s\n' "$_vals" | guard_rcconf_value "$_rv")
			case $_rcval in [Yy][Ee][Ss]) _en=yes ;; *) _en=no ;; esac
			printf '%s|%s|%s|%s\n' "$_svc" "$_rv" "$_en" "$_mods"
		done
	done
}

# guard_rc_forbidden <modules> <regex>: the modules that match the regex, one per line (a path and the .ko suffix are
# stripped first: /boot/kernel/amdgpu.ko is amdgpu)
guard_rc_forbidden()
{
	printf '%s\n' "$1" | tr ' ' '\n' | grep -v '^$' | while IFS= read -r _m; do
		_b=${_m##*/}; _b=${_b%.ko}
		printf '%s\n' "$_b" | grep -Eiq "$2" && printf '%s\n' "$_m"
	done
}

# guard_rc_offenders <root> [<regex>]: the rc.d services of the tree that load a forbidden module by themselves, one
# per line: "<service>|<rcvar>|<modules>".  A service whose modules could not be read is a line of its own:
# "<service>|?|unknown|<raw modules>": the caller must refuse it, not ignore it (a service that is not read is a
# service that is not known).  A service whose enable state could not be read (its script has no rcvar: devd starts
# it per device) cannot be turned off, so it is an offender only when the modules it loads are forbidden; it is then
# a line of its own too: "<service>|?|unknown-enable|<modules>".
guard_rc_offenders()
{
	_root=$1; _re=${2:-$GUARD_FORBID_RE}
	guard_rc_services "$_root" | while IFS='|' read -r _svc _rcvar _en _mods; do
		case $_en in
		unreadable)
			# the modules cannot be read: the caller must refuse the service
			printf '%s|?|unknown|%s\n' "$_svc" "$_mods"
			continue
			;;
		unknown)
			# the enable state cannot be read, so the service may run: it is an offender only when the modules
			# it loads are forbidden.  One that loads no forbidden driver is skipped like any other.
			_bad=$(guard_rc_forbidden "$_mods" "$_re" | tr '\n' ' ')
			[ -z "$_bad" ] || printf '%s|?|unknown-enable|%s\n' "$_svc" "${_bad% }"
			continue
			;;
		esac
		[ "$_en" = yes ] || continue
		_bad=$(guard_rc_forbidden "$_mods" "$_re" | tr '\n' ' ')
		[ -z "$_bad" ] || printf '%s|%s|%s\n' "$_svc" "$_rcvar" "${_bad% }"
	done
}

# guard_hwprobe_loads <root>: the hwprobe service loads the KMS driver of the card it finds, unless its command is
# "probe" (the Server command, which only writes the report).  Its loading is not through a required_modules entry,
# so it is a rule of its own.  Prints "<service>|<command>" and succeeds when it would load a driver.
guard_hwprobe_loads()
{
	_root=$1
	_s=
	for _d in "$_root/etc/rc.d" "$_root/usr/local/etc/rc.d"; do
		if [ -f "$_d/$GUARD_HWPROBE" ]; then _s=$_d/$GUARD_HWPROBE; break; fi
	done
	[ -n "$_s" ] || return 1
	_vals=$(guard_rc_values "$_root" "$GUARD_HWPROBE")
	_en=$(printf '%s\n' "$_vals" | guard_rcconf_value "${GUARD_HWPROBE}_enable")
	case $_en in [Yy][Ee][Ss]) ;; *) return 1 ;; esac
	_cmd=$(printf '%s\n' "$_vals" | guard_rcconf_value "${GUARD_HWPROBE}_command")
	case $_cmd in probe) return 1 ;; esac
	printf '%s|%s\n' "$GUARD_HWPROBE" "${_cmd:-apply}"
	return 0
}

# guard_devd_loaders <root> [<regex>]: the devd rules of the tree that load a driver by themselves, one per line:
# "<file>|kldloads <module>" for a rule that loads a module by itself, "<file>|starts <service>" for a rule that
# starts the hwprobe (which loads the KMS driver of the card it finds), and "<file>|starts <service>
# (required_modules <modules>)" for a rule that starts a service which loads a driver by itself.  A rule that starts
# a service is a loader whether the service is enabled or not: service X onestart runs it even when its rcvar is NO.
guard_devd_loaders()
{
	_root=$1; _re=${2:-$GUARD_FORBID_RE}
	_dload=$(guard_rc_services "$_root" | while IFS='|' read -r _s4 _rv4 _en4 _m4; do
		case $_en4 in
		unknown|unreadable) continue ;;
		esac
		_b4=$(guard_rc_forbidden "$_m4" "$_re" | tr '\n' ' ')
		[ -z "$_b4" ] || printf '%s|%s\n' "$_s4" "${_b4% }"
	done)
	for _d in "$_root/etc/devd" "$_root/usr/local/etc/devd"; do
		[ -d "$_d" ] || continue
		for _c in "$_d"/*.conf; do
			[ -f "$_c" ] || continue
			grep -Eio 'kldload[[:space:]]+[^"'"'"';]*' "$_c" 2> /dev/null | while IFS= read -r _kl; do
				_kl=${_kl#* }
				for _w in $_kl; do
					case $_w in -*) continue ;; esac
					_b=${_w##*/}; _b=${_b%.ko}
					printf '%s\n' "$_b" | grep -Eiq "$_re" && printf '%s|kldloads %s\n' "${_c##*/}" "$_w"
				done
			done
			grep -E '^[[:space:]]*action[[:space:]]' "$_c" 2> /dev/null |
				sed -n 's/.*service[[:space:]]\{1,\}\([A-Za-z_][A-Za-z0-9_]*\).*/\1/p' | sort -u |
				while IFS= read -r _svc2; do
					# the hwprobe loads a driver through the probe it runs, not through a required_modules entry
					if [ "$_svc2" = "$GUARD_HWPROBE" ]; then
						guard_hwprobe_loads "$_root" > /dev/null && printf '%s|starts %s\n' "${_c##*/}" "$_svc2"
						continue
					fi
					# a rule that starts a service which loads a driver by itself: service X onestart runs it even
					# when its rcvar is NO, so the rule is a loader whether the service is enabled or not
					printf '%s\n' "$_dload" | while IFS='|' read -r _s5 _m5; do
						[ "$_s5" = "$_svc2" ] || continue
						printf '%s|starts %s (required_modules %s)\n' "${_c##*/}" "$_s5" "$_m5"
					done
				done
		done
	done
}

# guard_rc_loaders <root> [<regex>]: the loaders of a tree that can load a forbidden module by themselves, one per
# line: "kld_list <module>", "rc.d service <service> (required_modules <modules>)" and "devd rule <file> starts
# <service>" (or "devd rule <file> kldloads <module>").  The devd rules are read by guard_devd_loaders, the one
# reader of them, so the guard, make-be.sh and check-be.sh name the same rules.
guard_rc_loaders()
{
	_root=$1; _re=${2:-$GUARD_FORBID_RE}
	_vals=$(guard_rcconf_values "$_root" "")
	_kl=$(printf '%s\n' "$_vals" | guard_rcconf_value kld_list)
	_ifs=$IFS; IFS=' '
	for _m in $_kl; do
		_bad=$(guard_rc_forbidden "$_m" "$_re")
		[ -z "$_bad" ] || printf 'kld_list %s\n' "$_bad"
	done
	IFS=$_ifs
	guard_rc_offenders "$_root" "$_re" | while IFS='|' read -r _svc _rcvar _mods; do
		case $_mods in
		unknown-enable\|*)
			# the enable state of the service cannot be read, but the modules it loads are forbidden: it is a
			# loader whatever its rcvar says
			printf 'rc.d service %s (required_modules %s)\n' "$_svc" "${_mods#unknown-enable|}"
			continue
			;;
		esac
		[ "$_rcvar" = '?' ] && continue
		printf 'rc.d service %s (required_modules %s)\n' "$_svc" "$_mods"
	done
	guard_devd_loaders "$_root" "$_re" | while IFS='|' read -r _df _dw; do
		[ -n "$_df" ] || continue
		printf 'devd rule %s %s\n' "$_df" "$_dw"
	done
}

# guard_env <kldstat -v file> <kldstat exit status> <sysctl answer file> <sysctl exit status> [<required file>...]
# The required files are the positive control: the listing must name each of them (kernel, and nvidia.ko once the
# kit loaded it), or it is not a real listing.  Prints the result line, then a line "records <list>" of the
# Linux-layer module records compiled into the kernel file (the caller reports them as info).  With GUARD_ROOT set to
# the root of the running system, the failure names the loader it can see (guard_rc_loaders).
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
		# the cause comes first: the loader it can see (an enabled rc.d service with a required_modules entry, a
		# devd hotplug rule, the loader list) and the pointer at check-be.sh, which names the service and the module.
		# A loader that cannot be seen is not guessed: nothing is named but the pointer.
		_loaders=
		if [ -n "${GUARD_ROOT:-}" ]; then
			_loaders=$(guard_rc_loaders "$GUARD_ROOT" 2> /dev/null | tr '\n' ';')
			_loaders=${_loaders%;}
		fi
		if [ -n "$_loaders" ]; then
			_why="run check-be.sh on the clone to see every loader; loaded by $_loaders"
		else
			_why="no loader found in rc.conf, rc.d or devd; check loader.conf and devmatch, and run check-be.sh on the clone"
		fi
		echo "fail loaded Linux-layer files: $_why; the Linux-layer files are:${_badf:- none}; the Linux-layer module records in loaded files are:${_badm:- none}"
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

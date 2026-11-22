#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# make.sh - the logic behind the root Makefile (skill
# project-makefile-contract).  The Makefile passes its switches as MK_*
# variables and one target name; this script does the work in sh(1), so the
# Makefile stays portable between bmake and GNU make.  It is written for any
# user on a stock FreeBSD arm64 install: nothing on the machine is assumed
# beyond the base system.
#
# Usage: sh scripts/make.sh TARGET
#   preflight [--json] [--purpose NAME]
#                    report what is missing (--json or MK_JSON=1: the JSON
#                    contract, schema/make-preflight-1.schema.json); exit 1
#                    when something is missing
#   install-prereqs  install the missing packages (pkg), fetch the NVIDIA
#                    sources (showing the NVIDIA licence first), the FreeBSD
#                    source tree of the running kernel and drm-kmod
#   configure        show the boot configuration change (loader.conf and
#                    rc.conf), back the files up, ask, apply
#   build            build every module, drm.ko and dmabuf.ko when no other
#                    drm.ko is installed, libnvrm and nvrm-info
#   test             run the repository unit tests
#   install          block before writing when a prerequisite cannot be fixed;
#                    otherwise ask once, up front, for everything that runs as
#                    root (YES=1 answers; no terminal and no YES=1 is a
#                    blocker), then install prerequisites, build if needed,
#                    stage, then install; English, JSON=1 or JSONL=1 output.
#                    Outcome: installed, blocked, or interrupted (a signal
#                    during the install step: exit 1, and the rollback result
#                    is stated, never assumed)
#   deinstall        remove exactly what install wrote and what configure set
#   test-install     the stock-install end-to-end run (tests/install-e2e)
#   clean            remove WORK/build and WORK/stage (keeps the downloads)
#
# Environment (set by the Makefile; all optional):
#   MK_WORK       downloads and build; default <repo>/work
#   MK_PREFIX     user-space install root; default /usr/local
#   MK_DESTDIR    staging root for install, configure and deinstall
#   MK_SYSDIR MK_BSDSRCTOP MK_DRMKMODDIR   trees to use instead of the
#                 detected or fetched ones
#   MK_YES MK_ASSUME_YES   1: do not ask (never accepts a licence)
#   MK_ACCEPT_NVIDIA_LICENSE  1: accept NVIDIA's driver licence
#   MK_ACCEPT_ALL_LICENSES    1: accept every licence the install meets
#   MK_JSON       1: preflight or install prints one JSON summary object
#   MK_JSONL      1: install prints one JSON object per event, then a summary;
#                 with MK_JSON=1 as well, JSONL wins and one line on stderr
#                 says JSON=1 is ignored
#   MK_PURPOSE    the Makefile REPO_PURPOSE, echoed by preflight
#
# Kernel modules install to $DESTDIR/boot/modules, everything else under
# $DESTDIR$PREFIX.  install records every file it wrote (path, mode, owner,
# sha256) and every directory it created in
# $DESTDIR/var/db/nvidia-gb10-freebsd/installed.manifest; deinstall removes
# those and nothing else.  Nothing uses /tmp.
#
# Exit status: 0 done, 1 failed or something is missing, 2 usage.

set -eu

# Base tools first: /usr/local/bin may hold GNU ld, which links a .ko that
# builds but does not load (skill freebsd-kmod-base-toolchain).
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin
LC_ALL=C
LD=/usr/bin/ld
OBJCOPY=/usr/bin/objcopy
export PATH LC_ALL LD OBJCOPY

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
name=nvidia-gb10-freebsd
# lib.sh holds the version rule fetch-trees.sh uses too (tree_version,
# tree_fits_osrel); sourcing it only defines functions
. "$repo/scripts/lib.sh"
STATEDIR=/var/db/$name

die() {
	printf 'make.sh: %s\n' "$*" >&2
	exit 1
}

note() {
	printf 'make.sh: %s\n' "$*"
}

yes_set() {
	[ "${MK_YES:-0}" = 1 ] || [ "${MK_ASSUME_YES:-0}" = 1 ]
}

# ask QUESTION: return 0 when the user answers yes, or when YES=1.  Without
# a terminal and without YES=1 the answer is no.
ask() {
	if yes_set; then
		return 0
	fi
	if [ ! -t 0 ]; then
		note "$1"
		note "no terminal to ask on: refusing; rerun with YES=1 if you mean it"
		return 1
	fi
	printf '%s [y/N] ' "$1"
	read -r _ans || return 1
	case $_ans in
	y|Y|yes|YES|Yes) return 0 ;;
	esac
	return 1
}

# --- paths ----------------------------------------------------------------

# work_path: the absolute work root, resolved without creating anything.
work_path() {
	_w=${MK_WORK:-}
	[ -n "$_w" ] || _w=$repo/work
	case $_w in
	/*) ;;
	*) _w=$(pwd -P)/$_w ;;
	esac
	[ "$_w" != / ] || die "WORK must not be /"
	# an existing WORK is named by its real path, so the trees derived
	# from it (WORK/src, WORK/drm-kmod) match what fetch-trees.sh checks
	if [ -d "$_w" ]; then
		_w=$(CDPATH= cd -- "$_w" && pwd -P)
	fi
	printf '%s\n' "$_w"
}

# ensure_work: create WORK (mode 755) when it does not exist; an existing
# WORK must be this user's and not writable by group or other (it holds the
# sources the build trusts, and build and clean remove WORK/build and
# WORK/stage).  An existing directory's mode is never changed.
ensure_work() {
	if [ ! -e "$WORK" ]; then
		mkdir -p -m 755 -- "$WORK"
	fi
	[ -d "$WORK" ] && [ ! -L "$WORK" ] || die "WORK $WORK is not a directory"
	_st=$(stat -f '%u %Lp' "$WORK")
	[ "${_st%% *}" = "$(id -u)" ] || die "refusing WORK $WORK: owned by uid ${_st%% *}, not $(id -u)"
	[ $((0${_st##* } & 022)) = 0 ] || die "refusing WORK $WORK: writable by group or other (mode ${_st##* })"
	WORK=$(CDPATH= cd -- "$WORK" && pwd -P)
	mkdir -p -- "$WORK/tmp"
}

prefix() {
	_p=${MK_PREFIX:-}
	[ -n "$_p" ] || _p=/usr/local
	case $_p in
	/*) printf '%s\n' "$_p" ;;
	*) die "PREFIX must be an absolute path: $_p" ;;
	esac
}

destdir() {
	_d=${MK_DESTDIR:-}
	case $_d in
	''|/*) printf '%s\n' "$_d" ;;
	*) die "DESTDIR must be an absolute path: $_d" ;;
	esac
}

running_osreldate() {
	sysctl -n kern.osreldate 2>/dev/null || true
}

os_version_of() {
	tree_version "$1"
}

# tree_fits SYSDIR: the one version rule (scripts/lib.sh tree_fits_osrel;
# fetch-trees.sh uses the same function) against the running kernel.
tree_fits() {
	tree_fits_osrel "$1" "$(running_osreldate)"
}

# The kernel tree: MK_SYSDIR, else /usr/src/sys when it fits the running
# kernel, else WORK/src/sys (make install-prereqs fetches it there).
resolve_sysdir() {
	if [ -n "${MK_SYSDIR:-}" ]; then
		printf '%s\n' "$MK_SYSDIR"
	elif tree_fits /usr/src/sys && [ -d /usr/src/include ]; then
		printf '%s\n' /usr/src/sys
	else
		printf '%s\n' "$WORK/src/sys"
	fi
}

setup() {
	WORK=$(work_path)
	PREFIX=$(prefix)
	DESTDIR=$(destdir)
	SYSDIR=$(resolve_sysdir)
	BSDSRCTOP=${MK_BSDSRCTOP:-$(dirname -- "$SYSDIR")}
	DRMKMODDIR=${MK_DRMKMODDIR:-$WORK/drm-kmod}
	TREE=$WORK/build/tree
	STAGE=$WORK/stage
	LIBOBJ=$WORK/build/libnvrm-obj
	DRMOBJ=$WORK/build/drm-obj
	GB10_WORK=$WORK
	TMPDIR=$WORK/tmp
	export GB10_WORK TMPDIR SYSDIR BSDSRCTOP DRMKMODDIR
	ogkm_tag=$(awk '$1 == "ogkm_tag" { print $2 }' "$repo/SOURCES")
	tarball=$WORK/sources/$(awk '$1 == "nvidia_freebsd_url" { n = split($2, p, "/"); print p[n] }' "$repo/SOURCES")
	ogkm_dir=$WORK/sources/open-gpu-kernel-modules-$ogkm_tag
	licence_ok=$WORK/sources/nvidia-licence.accepted
	MANIFEST=$DESTDIR$STATEDIR/installed.manifest
}

# --- root -----------------------------------------------------------------

# root_method: how this user becomes root: root, doas (a doas.conf rule
# permits this user), sudo, su (on a terminal, for a member of wheel; su
# asks for the root password) or none.
root_method() {
	# test hook (GB10_TEST_HOOKS=1 only): pin the answer
	_rm_hook=$(test_hook make.sh GB10_TEST_ROOT_METHOD "" 2>/dev/null) || _rm_hook=
	case $_rm_hook in
	root|doas|sudo|su|none) echo "$_rm_hook"; return 0 ;;
	esac
	if [ "$(id -u)" = 0 ]; then
		echo root
	elif command -v doas >/dev/null 2>&1 && [ -r /usr/local/etc/doas.conf ] \
	    && [ "$(doas -C /usr/local/etc/doas.conf sh 2>/dev/null | cut -d ' ' -f 1)" = permit ]; then
		echo doas
	elif command -v sudo >/dev/null 2>&1; then
		echo sudo
	elif [ -t 0 ] && id -Gn | tr ' ' '\n' | grep -qx wheel; then
		echo su
	else
		echo none
	fi
}

# destdir_user_owned: 0 when DESTDIR is set and this user may write it as
# themselves: it exists and is this user's real directory, or it does not
# exist yet and the nearest existing parent is this user's.  A DESTDIR owned
# by anyone else (root's, say) needs root, whoever runs make.
destdir_user_owned() {
	[ -n "$DESTDIR" ] || return 1
	[ "$(id -u)" != 0 ] || return 1
	_du=$DESTDIR
	while [ ! -e "$_du" ] && [ ! -L "$_du" ] && [ "$_du" != / ]; do
		_du=$(dirname -- "$_du")
	done
	[ -d "$_du" ] && [ ! -L "$_du" ] || return 1
	[ "$(stat -f '%u' "$_du")" = "$(id -u)" ]
}

# as_root CMD...: run CMD as root, the way root_method names.
as_root() {
	case $(root_method) in
	root) "$@" ;;
	doas) doas "$@" ;;
	sudo) sudo "$@" ;;
	su)
		note "neither doas nor sudo is set up: asking su for the root password"
		# root's shell is sh(1) on FreeBSD 14 and later; the arguments
		# reach it as "$0" "$@", each one word, never re-split
		su root -c 'exec "$0" "$@"' "$@"
		;;
	*) die "this step needs root: set up doas or sudo for $(id -un), or run make as root" ;;
	esac
}

# --- the tool table -------------------------------------------------------

# tool_table: "command source" per line; source is a package name, or base
# for a base-system command (a stock install has it; nothing to install).
tool_table() {
	printf '%s\n' "cc base" "fetch base" "sha256 base" "tar base" "kldxref base" \
	    "mandoc base" "readelf base" "pciconf base" "git git" "gmake gmake"
}

pkgs_needed() {
	tool_table | while read -r _t _src; do
		[ "$_src" = base ] && continue
		command -v "$_t" >/dev/null 2>&1 || printf '%s\n' "$_src"
	done
	# test hook (GB10_TEST_HOOKS=1 only): one more package to install
	_pk_hook=$(test_hook make.sh GB10_TEST_PKG_NEEDED "" 2>/dev/null) || _pk_hook=
	[ -z "$_pk_hook" ] || printf '%s\n' "$_pk_hook"
}

# --- preflight ------------------------------------------------------------

# Items are kept as lines "name|state|reason|fix" in $items.
items=
add_item() {
	items="$items$1|$2|$3|$4
"
}

json_str() {
	printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# nvidia_devices: one line "selector vendor device class" per NVIDIA display
# device pciconf(8) reports (vendor 0x10de, class 0x03); never a guessed
# device node.  Fails when pciconf itself fails.
nvidia_devices() {
	_pci=$(pciconf -l 2>/dev/null) || return 1
	printf '%s\n' "$_pci" | awk '
		{
			sel = $1; sub(/:$/, "", sel); v = ""; d = ""; c = ""
			for (i = 2; i <= NF; i++) {
				if ($i ~ /^vendor=/) v = substr($i, 8)
				else if ($i ~ /^device=/) d = substr($i, 8)
				else if ($i ~ /^class=/) c = substr($i, 7)
			}
			if (v == "0x10de" && c ~ /^0x03/) print sel, v, d, c
		}'
}

# foreign_drm DESTDIR: 0 when DESTDIR/boot/modules/drm.ko exists and our
# manifest does not list it (someone else's drm-kmod is installed).
foreign_drm() {
	[ -f "$1/boot/modules/drm.ko" ] || return 1
	[ -f "$1$STATEDIR/installed.manifest" ] && awk '$1 == "/boot/modules/drm.ko"' "$1$STATEDIR/installed.manifest" | grep -q . && return 1
	return 0
}

# mcfg_is_altra: yes, no or unknown.  The ACPI MCFG table names an Ampere
# Altra (OEM ID Ampere, OEM table ID starting with Altra: the rule the
# driver and the kernel patches use).  Reading it needs /dev/mem, so a
# normal user gets unknown.
mcfg_is_altra() {
	_t=$(acpidump -t 2>/dev/null) || { echo unknown; return 0; }
	printf '%s\n' "$_t" | awk '
		/MCFG: Length/ { m = 1; next }
		m && /OEM ID=/ { id = $0; sub(/.*OEM ID=/, "", id) }
		m && /OEM Table ID=/ { t = $0; sub(/.*OEM Table ID=/, "", t); m = 0 }
		END { if (id ~ /^Ampere/ && t ~ /^Altra/) print "yes"; else print "no" }'
}

# kernel_patch_items: the kernel changes in kernel-patches/ (users apply
# them; make install never patches or rebuilds a kernel).  They are
# reported as warn: the build and install work without them.
#   compat.linuxkpi.altra_82288  LinuxKPI arm64 write-combining: needed on
#                                any arm64 for drm-kmod write-combining
#   machdep.kern_align_fixup     the arm64 kernel alignment fixup (Altra)
#   the Altra PCIe ECAM quirk    Altra only
kernel_patch_items() {
	_kp="see kernel-patches/README.md"
	[ "$(uname -p 2>/dev/null)" = aarch64 ] || return 0
	if sysctl -n compat.linuxkpi.altra_82288 >/dev/null 2>&1; then
		add_item "kernel:linuxkpi-arm64-wc" ok "compat.linuxkpi.altra_82288 present" ""
	else
		add_item "kernel:linuxkpi-arm64-wc" warn "the running kernel lacks the LinuxKPI arm64 write-combining change (no compat.linuxkpi.altra_82288): drm-kmod maps write-combining memory wrongly on arm64" "$_kp"
	fi
	_altra=$(mcfg_is_altra)
	if sysctl -n machdep.kern_align_fixup >/dev/null 2>&1; then
		add_item "kernel:align-fixup" ok "machdep.kern_align_fixup present" ""
	elif [ "$_altra" = no ]; then
		add_item "kernel:align-fixup" ok "not needed: the ACPI MCFG table names no Ampere Altra" ""
	else
		add_item "kernel:align-fixup" warn "no machdep.kern_align_fixup; needed on an Ampere Altra (MCFG says altra=$_altra)" "$_kp"
	fi
	case $_altra in
	yes) add_item "kernel:altra" warn "an Ampere Altra (ACPI MCFG): it needs the PCIe ECAM quirk and the alignment fixup kernel patches" "$_kp" ;;
	no) add_item "kernel:altra" ok "not an Ampere Altra (ACPI MCFG)" "" ;;
	*) add_item "kernel:altra" warn "cannot read the ACPI MCFG table as $(id -un): an Ampere Altra needs the ECAM quirk patch" "$_kp; check with: doas acpidump -t | grep -A 8 MCFG" ;;
	esac
}

collect_preflight() {
	setup
	items=
	_os=$(uname -s)
	_arch=$(uname -p 2>/dev/null || uname -m)
	_run=$(running_osreldate)
	if [ "$_os" = FreeBSD ] && [ "$_arch" = aarch64 ]; then
		add_item platform ok "FreeBSD $(uname -r) $_arch" ""
	else
		add_item platform missing "$_os $_arch: this repository builds the FreeBSD arm64 (aarch64) driver" "on amd64, NVIDIA's FreeBSD driver: pkg install nvidia-driver"
	fi
	_tt=$(tool_table)
	while read -r _t _src; do
		if command -v "$_t" >/dev/null 2>&1; then
			add_item "tool:$_t" ok "$(command -v "$_t")" ""
		elif [ "$_src" = base ]; then
			add_item "tool:$_t" missing "not on PATH: part of the FreeBSD base system" "reinstall the base system component that holds $_t"
		else
			add_item "tool:$_t" missing "not on PATH" "make install-prereqs (pkg $_src)"
		fi
	done <<EOF
$_tt
EOF
	if /usr/bin/ld --version 2>/dev/null | grep -q LLD; then
		add_item "tool:ld" ok "/usr/bin/ld is LLD" ""
	else
		add_item "tool:ld" missing "/usr/bin/ld is not LLD: a module linked by GNU ld does not load" "restore the base system linker (/usr/bin/ld from the base toolchain)"
	fi
	if [ -f "$tarball" ] && [ -d "$ogkm_dir" ]; then
		add_item sources ok "$WORK/sources" ""
	else
		add_item sources missing "NVIDIA sources not fetched into $WORK/sources" "make install-prereqs"
	fi
	if licence_current; then
		add_item licence ok "NVIDIA driver licence $(sed -n 2p "$licence_ok")" ""
	elif [ -f "$licence_ok" ] && [ -f "$tarball" ]; then
		add_item licence missing "the NVIDIA driver licence in the tarball changed since it was accepted" "make install-prereqs ACCEPT_NVIDIA_LICENSE=1 (or ACCEPT_ALL_LICENSES=1), or run it on a terminal and answer"
	elif [ -n "$(licence_setting)" ]; then
		add_item licence warn "NVIDIA driver licence: $(licence_setting) is set; make install-prereqs records the acceptance" "make install-prereqs"
	else
		add_item licence missing "NVIDIA's terms ask you to read and accept the driver licence before install; YES=1 alone does not accept it" "make install-prereqs ACCEPT_NVIDIA_LICENSE=1 (or ACCEPT_ALL_LICENSES=1), or run make install-prereqs on a terminal and answer"
	fi
	_have=$(os_version_of "$SYSDIR")
	if tree_fits "$SYSDIR"; then
		add_item sysdir ok "$SYSDIR (__FreeBSD_version $_have, kernel $_run)" ""
	elif [ -n "$_have" ]; then
		add_item sysdir missing "$SYSDIR is __FreeBSD_version $_have, the running kernel is $_run" "make install-prereqs, or SYSDIR= a tree of the running kernel"
	else
		add_item sysdir missing "no kernel sources at $SYSDIR" "make install-prereqs"
	fi
	if [ -d "$BSDSRCTOP/include" ] && [ -d "$BSDSRCTOP/sys" ]; then
		add_item bsdsrctop ok "$BSDSRCTOP" ""
	else
		add_item bsdsrctop missing "no FreeBSD source top (include/ and sys/) at $BSDSRCTOP" "make install-prereqs, or BSDSRCTOP="
	fi
	if [ -f "$DRMKMODDIR/linuxkpi_version.mk" ]; then
		add_item drmkmoddir ok "$DRMKMODDIR" ""
	else
		add_item drmkmoddir missing "no drm-kmod sources at $DRMKMODDIR" "make install-prereqs, or DRMKMODDIR= the tree of the installed drm.ko"
	fi
	if foreign_drm "$DESTDIR"; then
		add_item drm.ko ok "$DESTDIR/boot/modules/drm.ko is installed by someone else: nvidia-drm builds against DRMKMODDIR, which must be its source" ""
	else
		add_item drm.ko ok "make install installs drm.ko and dmabuf.ko built from $DRMKMODDIR (FreeBSD's drm-kmod packages are amd64-only)" ""
	fi
	kernel_patch_items
	_rm=$(root_method)
	case $_rm in
	none)
		if destdir_user_owned; then
			add_item root ok "no root helper needed for a user-owned DESTDIR install" ""
		elif [ -n "$DESTDIR" ]; then
			add_item root missing "DESTDIR $DESTDIR is not owned by $(id -un): installing there needs root, and there is no doas rule or sudo for $(id -un)" "pkg install doas, then a permit line for $(id -un) in /usr/local/etc/doas.conf, or use a DESTDIR you own"
		else
			add_item root missing "no doas rule or sudo for $(id -un), and su needs a terminal and membership of wheel" "pkg install doas, then a permit line for $(id -un) in /usr/local/etc/doas.conf"
		fi
		;;
	su) add_item root ok "su (asks for the root password)" "" ;;
	*) add_item root ok "$_rm" "" ;;
	esac
	# pciconf failing is "could not look", never "no device"; it is
	# reported, and it does not fail preflight (the build needs no GPU)
	_pcierr=0
	_devs=$(nvidia_devices) || _pcierr=1
	if [ "$_pcierr" = 1 ]; then
		_device="device check unavailable"
	elif [ -n "$_devs" ]; then
		_device="NVIDIA device present"
	else
		_device="no NVIDIA device"
	fi
	_missing=$(printf '%s' "$items" | awk -F'|' '$2 == "missing"' | wc -l | tr -d ' ')
}

# render_preflight renders only what collect_preflight found.  Keeping collection
# separate lets make install inspect the same items without printing a second,
# incompatible report in its JSON and JSONL modes.
render_preflight() {
	if [ "${MK_JSON:-0}" = 1 ]; then
		printf '{\n  "schema_version": "1.0",\n  "tool": "preflight",\n'
		printf '  "purpose": "%s",\n' "$(json_str "${MK_PURPOSE:-application}")"
		printf '  "metadata": {"os": "%s", "arch": "%s", "release": "%s", "osreldate": "%s", "work": "%s"},\n' \
		    "$(json_str "$_os")" "$(json_str "$_arch")" "$(json_str "$(uname -r)")" "$(json_str "$_run")" "$(json_str "$WORK")"
		printf '  "status": ['
		_i=0
		printf '%s' "$items" | while IFS='|' read -r _n _s _r _f; do
			[ "$_i" = 0 ] || printf ','
			printf '\n    {"index": %s, "name": "%s", "state": "%s", "available": %s, "reason": "%s", "fix": "%s"}' \
			    "$_i" "$(json_str "$_n")" "$_s" "$([ "$_s" = ok ] && echo true || echo false)" \
			    "$(json_str "$_r")" "$(json_str "$_f")"
			_i=$((_i + 1))
		done
		printf '\n  ],\n  "items": ['
		_i=0
		printf '%s\n' "$_devs" | while read -r _sel _v _d _c; do
			[ -n "$_sel" ] || continue
			[ "$_i" = 0 ] || printf ','
			printf '\n    {"index": %s, "selector": "%s", "vendor": "%s", "device": "%s", "class": "%s"}' \
			    "$_i" "$(json_str "$_sel")" "$_v" "$_d" "$_c"
			_i=$((_i + 1))
		done
		printf '\n  ],\n  "device": "%s",\n  "missing": %s\n}\n' "$_device" "$_missing"
	else
		printf 'preflight: purpose=%s os=%s arch=%s work=%s\n' "${MK_PURPOSE:-application}" "$_os" "$_arch" "$WORK"
		printf '%s' "$items" | while IFS='|' read -r _n _s _r _f; do
			if [ "$_s" = ok ]; then
				printf 'ok    %s: %s\n' "$_n" "$_r"
			elif [ "$_s" = warn ]; then
				printf 'warn  %s: %s%s\n' "$_n" "$_r" "${_f:+ ($_f)}"
			else
				printf 'miss  %s: %s%s\n' "$_n" "$_r" "${_f:+ (fix: $_f)}"
			fi
		done
		if [ -n "$_devs" ]; then
			printf '%s\n' "$_devs" | sed 's/^/gpu   /'
		fi
		if [ "$_pcierr" = 1 ]; then
			printf 'gpu   %s: pciconf -l failed (the build and install need no GPU)\n' "$_device"
		else
			printf 'gpu   %s (the build and install need no GPU)\n' "$_device"
		fi
		printf 'preflight: %s missing\n' "$_missing"
	fi
	[ "$_missing" = 0 ]
}

do_preflight() {
	collect_preflight
	render_preflight
}

# --- install-prereqs ------------------------------------------------------

# licence_explain: why we ask, and how to answer without a terminal.
licence_explain() {
	cat <<EOF
make.sh: NVIDIA's driver licence must be accepted before this install uses NVIDIA's
make.sh: files (the GSP firmware and the driver sources come from NVIDIA's driver
make.sh: tarball).  NVIDIA's terms ask everyone who installs the driver to read and
make.sh: agree to them first, so we cannot accept them for you, and YES=1 alone does
make.sh: not do it.  The licence is in $1
make.sh: To accept it:
make.sh:   on a terminal: run make install-prereqs without YES=1 and answer the question;
make.sh:   or add ACCEPT_NVIDIA_LICENSE=1 (this licence only), for example
make.sh:     make install-prereqs YES=1 ACCEPT_NVIDIA_LICENSE=1
make.sh:   or add ACCEPT_ALL_LICENSES=1: you accept every licence this install meets
make.sh:   (today the NVIDIA driver licence is the only one) and it never asks.
EOF
}

licence_setting() {
	if [ "${MK_ACCEPT_ALL_LICENSES:-0}" = 1 ]; then
		echo ACCEPT_ALL_LICENSES=1
	elif [ "${MK_ACCEPT_NVIDIA_LICENSE:-0}" = 1 ]; then
		echo ACCEPT_NVIDIA_LICENSE=1
	fi
}

# licence_current: 0 when the recorded acceptance is for the licence in
# the tarball now in WORK/sources (a new tarball brings a new licence text,
# which must be accepted again).
licence_current() {
	[ -f "$licence_ok" ] && [ -f "$tarball" ] || return 1
	_top=$(basename "$tarball" .tar.xz)
	_now=$(tar -xOf "$tarball" "$_top/doc/license.txt" 2>/dev/null | sha256 -q) || return 1
	[ "$(sed -n 1p "$licence_ok")" = "$_now" ]
}

# show_licence: NVIDIA's driver licence (doc/license.txt of the fetched
# tarball) must be accepted before the build uses NVIDIA's files (skill
# firmware-shipping-policy: the GSP firmware is fetched, not shipped, and
# the licence asks to be read and agreed first).  Accepted by
# ACCEPT_NVIDIA_LICENSE=1 or ACCEPT_ALL_LICENSES=1, or by answering on a
# terminal after it is shown; YES=1 alone never accepts it.  The acceptance
# is recorded with the licence's sha256, so a changed licence asks again.
show_licence() {
	_lic=$WORK/sources/nvidia-license.txt
	_top=$(basename "$tarball" .tar.xz)
	tar -xOf "$tarball" "$_top/doc/license.txt" > "$_lic.new" || die "cannot read $_top/doc/license.txt from $tarball"
	mv -f -- "$_lic.new" "$_lic"
	_sum=$(sha256 -q "$_lic")
	if [ -f "$licence_ok" ] && [ "$(sed -n 1p "$licence_ok")" = "$_sum" ]; then
		note "NVIDIA driver licence: accepted earlier ($_lic)"
		return 0
	fi
	_set=$(licence_setting)
	if [ -n "$_set" ]; then
		printf '%s\n%s\n' "$_sum" "accepted by $_set" > "$licence_ok"
		note "NVIDIA driver licence ($_lic) accepted by $_set"
		return 0
	fi
	if yes_set || [ ! -t 0 ]; then
		licence_explain "$_lic" >&2
		die "stopped: the NVIDIA driver licence is not accepted yet"
	fi
	# The explanation and the question go to the terminal itself: the
	# standard streams of a make install phase are captured in a log the
	# user would not see until the phase ended.  install_run_phase hands
	# over the real standard output (fd 3) and standard error (fd 4).
	_lic_answer=
	if [ -t 3 ]; then
		licence_ask_terminal "$_lic" >&3
	elif [ -t 4 ]; then
		licence_ask_terminal "$_lic" >&4
	elif ( : > /dev/tty ) 2>/dev/null; then
		licence_ask_terminal "$_lic" > /dev/tty
	else
		licence_ask_terminal "$_lic"
	fi
	case $_lic_answer in
	y|Y|yes|YES|Yes) ;;
	*)
		licence_explain "$_lic" >&2
		die "the NVIDIA driver licence was not accepted; nothing NVIDIA ships is used"
		;;
	esac
	printf '%s\n%s\n' "$_sum" "accepted on a terminal by $(id -un)" > "$licence_ok"
	return 0
}

# licence_ask_terminal LICENCE: show why we ask, the licence, and the question
# on this function's standard output (the caller points it at the terminal);
# the answer is left in _lic_answer.  It runs in the calling shell.
licence_ask_terminal() {
	licence_explain "$1"
	printf 'Press Enter to read the licence.' && read -r _x
	${PAGER:-more} "$1" || true
	printf 'Do you accept the NVIDIA driver licence? [yes/no] '
	read -r _lic_answer || _lic_answer=
}

do_install_prereqs() {
	_auto=${1:-}
	setup
	ensure_work
	_need=$(pkgs_needed | sort -u | tr '\n' ' ')
	if [ -n "$_need" ]; then
		note "packages to install: $_need"
		# The one-command install has already asked for the installation by
		# being invoked.  Its automatic package step never accepts a licence;
		# show_licence below still requires its own explicit answer.
		if [ "$_auto" != auto ]; then
			ask "Install these packages with pkg(8) as root?" || die "packages not installed: $_need"
		fi
		if [ ! -x /usr/local/sbin/pkg ]; then
			note "pkg(8) is not bootstrapped yet: bootstrapping it first"
			as_root env ASSUME_ALWAYS_YES=yes /usr/sbin/pkg bootstrap -f
		fi
		# shellcheck disable=SC2086
		as_root env ASSUME_ALWAYS_YES=yes /usr/local/sbin/pkg install -y $_need
	else
		note "packages: all present"
	fi
	sh "$repo/scripts/fetch-sources.sh" "$WORK/sources"
	show_licence
	sh "$repo/scripts/fetch-trees.sh" --work "$WORK" --sysdir "$SYSDIR" --drmkmoddir "$DRMKMODDIR"
	if [ ! -d "$BSDSRCTOP/include" ]; then
		die "no FreeBSD source top at $BSDSRCTOP (include/ is missing): set BSDSRCTOP= to the tree SYSDIR lives in"
	fi
	note "install-prereqs: done; next: make install"
}

# --- configure ------------------------------------------------------------

# kv_get FILE KEY, kv_set FILE KEY VALUE, kv_unset FILE KEY: KEY="VALUE"
# lines in loader.conf(5) and rc.conf(5) syntax.  sysrc(8) refuses the
# dotted loader tunables, so both files are edited here: the new file is
# written next to the old one and moved into place.
kv_get() {
	[ -f "$1" ] || return 0
	awk -v k="$2" '
		index($0, k "=") == 1 { v = substr($0, length(k) + 2); sub(/[[:space:]]*#.*$/, "", v); gsub(/^"|"$/, "", v) }
		END { if (v != "") print v }' "$1"
}

kv_set() {
	awk -v k="$2" -v v="$3" '
		index($0, k "=") == 1 { if (!done) print k "=\"" v "\""; done = 1; next }
		{ print }
		END { if (!done) print k "=\"" v "\"" }' "$1" > "$1.new"
	chmod "$(stat -f '%Lp' "$1")" "$1.new"
	mv -f -- "$1.new" "$1"
}

kv_unset() {
	awk -v k="$2" 'index($0, k "=") != 1' "$1" > "$1.new"
	chmod "$(stat -f '%Lp' "$1")" "$1.new"
	mv -f -- "$1.new" "$1"
}

# The boot configuration: GSP firmware on in loader.conf (the open RM core
# runs the GPU through GSP), and nvidia_gb10_autoload in rc.conf, which the
# installed devd rule reads before it loads nvidia-drm when an NVIDIA
# display device appears.
config_lines() {
	printf '%s\n' "/boot/loader.conf hw.nvidia.registry.EnableGpuFirmware 1" \
	    "/etc/rc.conf nvidia_gb10_autoload YES"
}

do_configure() {
	setup
	_changes=
	_cl=$(config_lines)
	while read -r _f _k _v; do
		_cur=$(kv_get "$DESTDIR$_f" "$_k")
		[ "$_cur" = "$_v" ] && continue
		_changes="$_changes$_f $_k $_v
"
		printf 'proposed: %s: %s="%s" (now: %s)\n' "$DESTDIR$_f" "$_k" "$_v" "${_cur:-unset}"
	done <<EOF
$_cl
EOF
	if [ -z "$_changes" ]; then
		note "configure: nothing to configure (every setting is already in place)"
		return 0
	fi
	note "each file is backed up next to itself (.bak-<UTC time>) before the change"
	if [ -n "$DESTDIR" ] && [ "$(id -u)" != 0 ]; then
		ask "Apply these changes in $DESTDIR?" || die "configure: nothing changed"
		apply_config "$DESTDIR" user
	else
		ask "Apply these changes as root?" || die "configure: nothing changed"
		as_root sh "$repo/scripts/make.sh" _configure "$DESTDIR"
	fi
}

# apply_config DESTDIR [user]: back up, then set each config line with
# kv_set, and record in STATEDIR/configured what was set, so deinstall can
# put the file back exactly:
#   FILE KEY OLD-VALUE|unset new|old BACKUP|- SHA256-AFTER
# As root, every directory on the way to FILE must be a real root-owned
# directory (safe_parents), like the install's.
apply_config() {
	_d=$1
	_mode=${2:-root}
	[ "$_mode" = user ] || [ -z "$_d" ] || [ "$(stat -f '%u' "$_d")" = 0 ] || die "refusing DESTDIR $_d as root: not owned by root"
	_stamp=$(date -u +%Y%m%dT%H%M%SZ)
	[ -d "$_d$(dirname "$STATEDIR")" ] || die "configure: no directory $_d$(dirname "$STATEDIR")"
	safe_parents "$_d" "$STATEDIR/configured" "$_mode" || die "configure: refusing $_d$STATEDIR: a directory on the way is a symbolic link or not root's"
	if [ ! -d "$_d$STATEDIR" ]; then
		mkdir -p -- "$_d$STATEDIR"
		# configure made it: deinstall removes it when it is empty
		: > "$_d$STATEDIR/.made-by-configure"
	fi
	_cl=$(config_lines)
	while read -r _f _k _v; do
		_cur=$(kv_get "$_d$_f" "$_k")
		[ "$_cur" = "$_v" ] && continue
		[ -d "$(dirname -- "$_d$_f")" ] || die "configure: no directory $(dirname -- "$_d$_f")"
		safe_parents "$_d" "$_f" "$_mode" || die "configure: refusing $_d$_f: a directory on the way is a symbolic link or not root's"
		[ ! -L "$_d$_f" ] || die "configure: refusing $_d$_f: symbolic link"
		if [ -f "$_d$_f" ]; then
			_new=old
			_bak=$_f.bak-$_stamp
			cp -p -- "$_d$_f" "$_d$_bak"
		else
			_new=new
			_bak=-
			: > "$_d$_f"
		fi
		kv_set "$_d$_f" "$_k" "$_v"
		printf '%s %s %s %s %s %s\n' "$_f" "$_k" "${_cur:-unset}" "$_new" "$_bak" "$(sha256 -q "$_d$_f")" >> "$_d$STATEDIR/configured"
		note "configure: $_d$_f: $_k=\"$_v\" (backup ${_bak#-})"
	done <<EOF
$_cl
EOF
}

# unconfigure DESTDIR [user]: put back what configure changed.  When the
# file is still exactly what configure left (same sha256), the backup is
# moved back (or a file configure created is removed): the file is then
# byte for byte what it was.  When someone changed it since, only the key
# is put back (an unset key removed, an earlier value restored) and the
# backup is kept and reported.  The record and an empty STATEDIR that
# configure made go too.
unconfigure() {
	_d=$1
	_mode=${2:-root}
	[ -f "$_d$STATEDIR/configured" ] || return 0
	[ ! -L "$_d$STATEDIR/configured" ] || die "refusing $_d$STATEDIR/configured: symbolic link"
	# newest change first, so two changes to one file unwind in order
	_rec=$(sed -n '1!G;h;$p' "$_d$STATEDIR/configured")
	while read -r _f _k _old _new _bak _sum; do
		case $_f in
		/boot/loader.conf|/etc/rc.conf) ;;
		*) continue ;;
		esac
		case $_bak in
		-|"$_f".bak-[0-9]*Z) ;;
		*) continue ;;
		esac
		safe_parents "$_d" "$_f" "$_mode" || { note "deinstall: refusing $_d$_f: a directory on the way is a symbolic link or not root's"; continue; }
		[ -f "$_d$_f" ] && [ ! -L "$_d$_f" ] || continue
		_reason="changed since make configure"
		_backup_note=
		[ "$_bak" = - ] || _backup_note="; backup kept: $_d$_bak"
		if [ -n "$_sum" ] && [ "$(sha256 -q "$_d$_f")" = "$_sum" ]; then
			if [ "$_new" = new ]; then
				rm -f -- "$_d$_f"
				note "deinstall: removed $_d$_f (make configure created it)"
				continue
			elif [ -f "$_d$_bak" ] && [ ! -L "$_d$_bak" ]; then
				mv -f -- "$_d$_bak" "$_d$_f"
				note "deinstall: $_d$_f restored from $_d$_bak"
				continue
			fi
			_reason="unchanged, but backup $_d$_bak is missing or unsafe"
			_backup_note=
		fi
		if [ "$_old" = unset ]; then
			kv_unset "$_d$_f" "$_k"
		else
			kv_set "$_d$_f" "$_k" "$_old"
		fi
		note "deinstall: $_d$_f $_reason: only $_k put back (to $_old)$_backup_note"
	done <<EOF
$_rec
EOF
	rm -f -- "$_d$STATEDIR/configured"
	if [ -f "$_d$STATEDIR/.made-by-configure" ]; then
		rm -f -- "$_d$STATEDIR/.made-by-configure"
		# deinstall_manifest removes it once the manifest is gone too
		_statedir_ours=1
		rmdir -- "$_d$STATEDIR" 2>/dev/null || true
	fi
}

# --- build ----------------------------------------------------------------

LOGDIR=
step() {
	_label=$1
	shift
	_log=$LOGDIR/$_label.log
	note "build: $_label"
	_rc=0
	"$@" > "$_log" 2>&1 || _rc=$?
	[ "$_rc" = 0 ] && return 0
	tail -n 20 "$_log" >&2
	die "build step $_label failed (rc $_rc); log $_log"
}

# Modules: "label|tree path" in load order.  The build loop, the install
# list and the checks all read this one table.
module_table() {
	printf '%s\n' "firmware|firmware/gsp_ga10x/nvidia_gsp_ga10x_fw.ko" \
	    "nvidia|nvidia/nvidia.ko" "nvidia-modeset|nvidia-modeset/nvidia-modeset.ko" \
	    "nvidia-drm|nvidia-drm/nvidia-drm.ko" "nvidia-linux|nvidia-linux/nvidia_linux.ko" \
	    "nvidia-modeset-linux|nvidia-modeset-linux/nvidia_modeset_linux.ko"
}

module_list() {
	module_table | cut -d '|' -f 2
}

# drm_wanted: build and install our drm.ko and dmabuf.ko unless someone
# else's drm.ko is installed.
drm_wanted() {
	! foreign_drm "$DESTDIR"
}

do_build() {
	setup
	ensure_work
	LOGDIR=$WORK/logs/make-build
	rm -rf -- "$LOGDIR"
	mkdir -p -- "$LOGDIR"
	[ -f "$tarball" ] && [ -d "$ogkm_dir" ] || sh "$repo/scripts/fetch-sources.sh" "$WORK/sources"
	licence_current || die "the NVIDIA driver licence in $tarball has not been accepted: run make install-prereqs ACCEPT_NVIDIA_LICENSE=1 (or on a terminal)"
	tree_fits "$SYSDIR" || die "no kernel sources of the running kernel at $SYSDIR ($(os_version_of "$SYSDIR"), kernel $(running_osreldate)): run make install-prereqs"
	[ -d "$BSDSRCTOP/include" ] || die "no FreeBSD source top at $BSDSRCTOP: run make install-prereqs"
	[ -f "$DRMKMODDIR/linuxkpi_version.mk" ] || die "no drm-kmod sources at $DRMKMODDIR: run make install-prereqs"
	# Every build starts from an empty build directory: with an RM core
	# object left from an earlier build, shim pass 1 would link and the
	# exit-3 check below would mean nothing.
	rm -rf -- "$WORK/build"
	mkdir -p -- "$WORK/build"
	step prepare-tree sh "$repo/scripts/prepare-tree.sh"
	_mt=$(module_table)
	while IFS='|' read -r _label _ko; do
		case $_label in
		firmware)
			step firmware sh "$repo/scripts/build-firmware.sh"
			;;
		nvidia)
			step rmcore sh "$repo/scripts/build-rmcore.sh"
			# Pass 1 compiles the OS layer; it must fail at the
			# link with exit 3 (no aarch64 RM core linked yet).
			note "build: shim pass 1 (expected exit 3)"
			_rc=0
			sh "$repo/scripts/build-shim.sh" > "$LOGDIR/shim-pass1.log" 2>&1 || _rc=$?
			[ "$_rc" = 3 ] || { tail -n 20 "$LOGDIR/shim-pass1.log" >&2; die "shim pass 1 exited $_rc, not 3; log $LOGDIR/shim-pass1.log"; }
			step stubs sh "$repo/scripts/build-stubs.sh"
			step nvidia sh "$repo/scripts/build-shim.sh"
			;;
		nvidia-modeset)
			step rmcore-modeset sh "$repo/scripts/build-rmcore.sh" --core=nvidia-modeset
			step nvidia-modeset sh "$repo/scripts/build-shim.sh" --module=nvidia-modeset
			;;
		*)
			step "$_label" sh "$repo/scripts/build-shim.sh" --module="$_label"
			;;
		esac
	done <<EOF
$_mt
EOF
	build_drm
	build_libnvrm
	for _ko in $(module_list); do
		[ -f "$TREE/$_ko" ] || die "missing after the build: $TREE/$_ko"
		readelf -p .comment "$TREE/$_ko" 2>/dev/null | grep -q 'Linker: LLD' \
		    || die "$TREE/$_ko was not linked by LLD"
	done
	build_stamp > "$WORK/build/stamp"
	note "build: OK (logs in $LOGDIR)"
}

# drm.ko and dmabuf.ko from DRMKMODDIR (only those two of drm-kmod: the
# GPU drivers in it are not needed), objects under WORK.  They are always
# built (nvidia-drm.ko is built against the same tree); stage() leaves them
# out when someone else's drm.ko is installed where make install writes.
build_drm() {
	mkdir -p -- "$DRMOBJ"
	step drm-obj env MAKEOBJDIRPREFIX="$DRMOBJ" /usr/bin/make -C "$DRMKMODDIR" \
	    SYSDIR="$SYSDIR" KMODS="dmabuf drm" WITHOUT_CTF=yes DEBUG_FLAGS= obj
	step drm env MAKEOBJDIRPREFIX="$DRMOBJ" /usr/bin/make -C "$DRMKMODDIR" \
	    SYSDIR="$SYSDIR" KMODS="dmabuf drm" WITHOUT_CTF=yes DEBUG_FLAGS= -j "$(sysctl -n hw.ncpu)" all
	for _k in drm dmabuf; do
		_f=$(find "$DRMOBJ" -name "$_k.ko" -type f | sed -n 1p)
		[ -n "$_f" ] || die "build: $_k.ko not found under $DRMOBJ"
		readelf -p .comment "$_f" 2>/dev/null | grep -q 'Linker: LLD' || die "$_f was not linked by LLD"
		cp -- "$_f" "$WORK/build/$_k.ko"
	done
}

# libnvrm and nvrm-info build with their objects under WORK (MAKEOBJDIR),
# so the checkout stays clean.
build_libnvrm() {
	rm -rf -- "$LIBOBJ"
	mkdir -p -- "$LIBOBJ/lib" "$LIBOBJ/info"
	step libnvrm env MAKEOBJDIR="$LIBOBJ/lib" OGKM="$ogkm_dir" /usr/bin/make -C "$repo/lib/libnvrm"
	step nvrm-info env MAKEOBJDIR="$LIBOBJ/info" LIBNVRM_OBJ="$LIBOBJ/lib" /usr/bin/make -C "$repo/lib/libnvrm/nvrm-info"
}

# Build stamp: what the modules were built from.  install rebuilds when it
# differs: another kernel tree or source top, other drm-kmod sources, new
# patches or scripts.
build_stamp() {
	printf 'sysdir %s %s\n' "$SYSDIR" "$(os_version_of "$SYSDIR")"
	printf 'bsdsrctop %s\n' "$BSDSRCTOP"
	_drm=
	[ -f "$DRMKMODDIR/linuxkpi_version.mk" ] && _drm=$(sha256 -q "$DRMKMODDIR/linuxkpi_version.mk")
	[ -d "$DRMKMODDIR/.git" ] && _drm="$_drm $(git -C "$DRMKMODDIR" rev-parse HEAD 2>/dev/null || true)"
	printf 'drmkmoddir %s %s\n' "$DRMKMODDIR" "$_drm"
	printf 'tree %s\n' "$(cd "$repo" && find SOURCES patches scripts src lib rc.d man devd -type f | sort | xargs sha256 -q | sha256 -q)"
}

# --- test -----------------------------------------------------------------

do_test() {
	setup
	ensure_work
	_d=$WORK/logs/make-test
	rm -rf -- "$_d"
	mkdir -p -- "$_d"
	_fail=0
	_n=0
	for _t in "$repo"/tests/*_test.sh; do
		_b=$(basename "$_t" .sh)
		_n=$((_n + 1))
		if (cd "$repo" && sh "$_t") > "$_d/$_b.log" 2>&1; then
			printf 'ok    %s\n' "$_b"
		else
			printf 'FAIL  %s (log %s)\n' "$_b" "$_d/$_b.log"
			_fail=$((_fail + 1))
		fi
	done
	note "test: $_n run, $_fail failed"
	[ "$_fail" = 0 ]
}

# --- install / deinstall --------------------------------------------------

# stage_files ROOT: every file and symbolic link under ROOT, one path per
# line ("/boot/modules/nvidia.ko"), sorted.  The one list install, the
# manifest and deinstall all use.
stage_files() {
	(cd "$1" && find . \( -type f -o -type l \) | sed 's|^\.||' | sort)
}

# stage: lay every file out under STAGE exactly as it installs, modes set.
stage() {
	rm -rf -- "$STAGE"
	_m=$STAGE/boot/modules
	_p=$STAGE$PREFIX
	mkdir -p -- "$_m" "$_p/etc/rc.d" "$_p/etc/devd" "$_p/share/man/man4" "$_p/share/man/man3" \
	    "$_p/share/man/man7" "$_p/share/man/man8" "$_p/lib" "$_p/include/nvrm" \
	    "$_p/sbin" "$_p/share/nvrm/schema" "$_p/share/licenses/$name"
	for _ko in $(module_list); do
		install -m 555 -- "$TREE/$_ko" "$_m/"
	done
	if drm_wanted; then
		install -m 555 -- "$WORK/build/drm.ko" "$_m/drm.ko"
		install -m 555 -- "$WORK/build/dmabuf.ko" "$_m/dmabuf.ko"
	fi
	install -m 555 -- "$repo/rc.d/nvidia_linux" "$_p/etc/rc.d/nvidia_linux"
	install -m 444 -- "$repo/devd/nvidia_gb10.conf" "$_p/etc/devd/nvidia_gb10.conf"
	for _man in "$repo"/man/*.4; do
		install -m 444 -- "$_man" "$_p/share/man/man4/"
	done
	install -m 444 -- "$WORK/sources/nvidia-license.txt" "$_p/share/licenses/$name/NVIDIA-LICENSE"
	install -m 444 -- "$repo/LICENSE" "$_p/share/licenses/$name/LICENSE"
	_l=$repo/lib/libnvrm
	install -m 444 -- "$LIBOBJ/lib/libnvrm.so.1" "$_p/lib/libnvrm.so.1"
	ln -s libnvrm.so.1 "$_p/lib/libnvrm.so"
	install -m 444 -- "$LIBOBJ/lib/libnvrm.a" "$_p/lib/libnvrm.a"
	install -m 444 -- "$_l/include/nvrm/nvrm.h" "$_p/include/nvrm/nvrm.h"
	install -m 444 -- "$_l/man/nvrm.3" "$_p/share/man/man3/nvrm.3"
	install -m 444 -- "$_l/man/nvrm.7" "$_p/share/man/man7/nvrm.7"
	# A failing make -V would leave the list empty inside a for word list,
	# where set -e does not fire: check it first.
	_funcs=$(MAKEOBJDIR="$LIBOBJ/lib" /usr/bin/make -C "$_l" -V NVRM_FUNCS OGKM="$ogkm_dir") \
	    || die "stage: make -V NVRM_FUNCS failed in $_l"
	[ -n "$_funcs" ] || die "stage: NVRM_FUNCS is empty in $_l/Makefile"
	for _f in $_funcs; do
		ln -s nvrm.3 "$_p/share/man/man3/$_f.3"
	done
	install -m 555 -- "$LIBOBJ/info/nvrm-info" "$_p/sbin/nvrm-info"
	install -m 444 -- "$_l/nvrm-info/nvrm-info.8" "$_p/share/man/man8/nvrm-info.8"
	install -m 444 -- "$_l/schema/nvrm-info-1.schema.json" "$_p/share/nvrm/schema/"
}

# allowed_path PATH PREFIX: the fixed set of paths make install may write.
# The root install step checks every staged path against it, so a file
# planted in the user-owned stage never lands as root.
allowed_path() {
	_ap=$1
	_pp=$2
	case $_ap in
	/boot/modules/drm.ko|/boot/modules/dmabuf.ko) return 0 ;;
	/boot/modules/*)
		# the modules of module_table, and nothing else
		module_list | sed 's|.*/|/boot/modules/|' | grep -qxF -- "$_ap"
		return ;;
	esac
	case ${_ap#"$_pp"} in
	"$_ap") return 1 ;;
	/etc/rc.d/nvidia_linux|/etc/devd/nvidia_gb10.conf|/lib/libnvrm.so.1|/lib/libnvrm.so|/lib/libnvrm.a|\
	/include/nvrm/nvrm.h|/sbin/nvrm-info|/share/man/man7/nvrm.7|/share/man/man8/nvrm-info.8|\
	/share/nvrm/schema/nvrm-info-1.schema.json|/share/licenses/$name/NVIDIA-LICENSE|/share/licenses/$name/LICENSE)
		return 0 ;;
	/share/man/man4/nvidia*.4|/share/man/man3/nvrm*.3)
		case ${_ap##*/} in
		*[!A-Za-z0-9_.-]*) return 1 ;;
		esac
		return 0 ;;
	esac
	return 1
}

# manifest_line ROOT PATH: the manifest line of ROOT/PATH as it is on disk:
#   path MODE owner:group SHA256    a file
#   path link -> TARGET             a symbolic link
#   path dir                        a directory install created
#   path pending SHA256|->TARGET    a file being written (before the copy)
manifest_line() {
	if [ -L "$1$2" ]; then
		printf '%s link -> %s\n' "$2" "$(readlink "$1$2")"
	else
		printf '%s %s %s %s\n' "$2" "$(stat -f '%Lp %Su:%Sg' "$1$2")" "$(sha256 -q "$1$2")"
	fi
}

# pending_line ROOT PATH: the pending line of a staged file.
pending_line() {
	if [ -L "$1$2" ]; then
		printf '%s pending ->%s\n' "$2" "$(readlink "$1$2")"
	else
		printf '%s pending %s\n' "$2" "$(sha256 -q "$1$2")"
	fi
}

# path_ok PATH: an absolute manifest path with no . or .. component.
path_ok() {
	case $1 in
	/*) ;;
	*) return 1 ;;
	esac
	case "$1/" in
	*/./*|*/../*|*//*) return 1 ;;
	esac
	return 0
}

# safe_parents ROOT PATH [user]: every existing directory from ROOT (or /)
# down to the parent of ROOT/PATH is a real directory, not a symbolic link,
# and (as root, without "user") owned by root, so a user cannot redirect a
# root write or remove through a directory they control.
safe_parents() {
	_sr=$1
	_sp=$(dirname -- "$2")
	_acc=$_sr
	[ -n "$_acc" ] || _acc=/
	for _c in $(printf '%s\n' "$_sp" | tr '/' ' '); do
		_acc=${_acc%/}/$_c
		[ -e "$_acc" ] || [ -L "$_acc" ] || return 0
		[ -d "$_acc" ] && [ ! -L "$_acc" ] || return 1
		[ "${3:-}" = user ] || [ "$(stat -f '%u' "$_acc")" = 0 ] || return 1
	done
	return 0
}

# line_matches ROOT LINE: ROOT holds what the manifest LINE records (a file
# line or a pending line: the same sha256 or link target).
line_matches() {
	_r=$1
	set -- $2
	[ -e "$_r$1" ] || [ -L "$_r$1" ] || return 1
	case $2 in
	link) [ -L "$_r$1" ] && [ "$(readlink "$_r$1")" = "$4" ] ;;
	dir) return 1 ;;
	pending)
		case $3 in
		-\>*) [ -L "$_r$1" ] && [ "->$(readlink "$_r$1")" = "$3" ] ;;
		*) [ -f "$_r$1" ] && [ ! -L "$_r$1" ] && [ "$(sha256 -q "$_r$1")" = "$3" ] ;;
		esac
		;;
	*) [ -f "$_r$1" ] && [ ! -L "$_r$1" ] && [ "$4" != - ] && [ "$(sha256 -q "$_r$1")" = "$4" ] ;;
	esac
}

# still_ours ROOT MANIFEST PATH: some line of MANIFEST for PATH (an earlier
# install's, or this install's pending one) matches what ROOT holds.
still_ours() {
	_so=1
	_lines=$(awk -v p="$3" '$1 == p && $2 != "dir"' "$2")
	[ -n "$_lines" ] || return 1
	while read -r _ln; do
		if line_matches "$1" "$_ln"; then
			_so=0
			break
		fi
	done <<EOF
$_lines
EOF
	return "$_so"
}

# One install report feeds all three output modes.  Blockers and installed
# paths are collected once; English, JSON and JSONL never invent separate
# explanations or file lists.
install_blockers=
install_records=
install_add_blocker() {
	install_blockers="$install_blockers$1|$2|$3
"
}

# install_collect_blockers [remaining]: before prerequisites run, only items
# that install-prereqs cannot fix are blockers.  Afterwards every missing item
# is a blocker.  A licence without an accepting setting is immediately
# unfixable when there is no terminal on which to show and accept it.
install_collect_blockers() {
	_remaining=${1:-initial}
	_install_items=$items
	# stdin of the loop below is its here-document: look at it out here
	_have_tty=0
	[ ! -t 0 ] || _have_tty=1
	while IFS='|' read -r _n _s _r _f; do
		[ "$_s" = missing ] || continue
		if [ "$_remaining" != remaining ]; then
			case $_n in
			tool:git|tool:gmake|sources|sysdir|bsdsrctop|drmkmoddir) continue ;;
			licence)
				if [ -n "$(licence_setting)" ] || { ! yes_set && [ "$_have_tty" = 1 ]; }; then
					continue
				fi
				;;
			esac
		fi
		install_add_blocker "$_n" "$_r" "$_f"
	done <<EOF
$_install_items
EOF
}

install_progress() {
	if [ "${MK_JSONL:-0}" = 1 ]; then
		printf '{"schema_version":"1.0","tool":"install","kind":"progress","phase":"%s","message":"%s"}\n' \
		    "$(json_str "$1")" "$(json_str "$2")"
	elif [ "${MK_JSON:-0}" != 1 ]; then
		printf 'install: %s: %s\n' "$1" "$2"
	fi
}

install_outcome=blocked
install_logdir=
install_signalled=0

# install_failure_blockers RC LOG: the blockers of a failed install step, and
# the outcome.  A status above 128 (a signal) or a signal the parent saw is
# "interrupted"; every other failure is "blocked".  What the rollback did is
# read from the step's own log ("rollback: restored", or one
# "rollback-failed PATH: WHY" line per path left alone), never assumed.
install_failure_blockers() {
	_ifr=$1
	_ifl=$2
	_what="install failed with exit $_ifr"
	install_outcome=blocked
	if [ "$_ifr" -gt 128 ] || [ "$install_signalled" = 1 ]; then
		install_outcome=interrupted
		_what="install interrupted (exit $_ifr)"
	fi
	_failed=$(sed -n 's/^rollback-failed //p' "$_ifl")
	if [ -n "$_failed" ]; then
		install_add_blocker install "$_what; the previous state was NOT fully restored (the paths are listed next); full output: $_ifl" "check the listed paths by hand, then rerun make install"
		while read -r _fl; do
			[ -n "$_fl" ] || continue
			install_add_blocker rollback "$_fl" "inspect it and restore or remove it by hand"
		done <<EOT
$_failed
EOT
	elif grep -q '^rollback: restored$' "$_ifl"; then
		install_add_blocker install "$_what; every replaced file and new file was restored; full output: $_ifl" "rerun make install"
	else
		install_add_blocker install "$_what; the rollback did not report, so the destination state is unknown; full output: $_ifl" "check the destination, run make deinstall, then rerun make install"
	fi
}

# install_next_steps: what to do after a good install, one step per line.
# With a DESTDIR the files are only staged: nothing is loaded from there.
# Otherwise the module is loaded with the root tool this user has.
install_next_steps() {
	if [ -n "$DESTDIR" ]; then
		printf 'the files are staged under %s; nothing was loaded: install that tree on the target system to use it\n' "$DESTDIR"
	else
		case $(root_method) in
		root) printf 'kldload nvidia-drm\n' ;;
		doas) printf 'doas kldload nvidia-drm\n' ;;
		sudo) printf 'sudo kldload nvidia-drm\n' ;;
		su) printf "su root -c 'kldload nvidia-drm'\n" ;;
		*) printf 'kldload nvidia-drm (as root: this user has no doas, sudo or su)\n' ;;
		esac
	fi
	printf 'kldstat\nnvrm-info --json\n'
}

# install_root_plan: the steps this install runs as root, one per line;
# nothing when it needs no root at all.
install_root_plan() {
	_pn=$(pkgs_needed | sort -u | tr '\n' ' ')
	_pn=${_pn% }
	[ -z "$_pn" ] || printf 'install these packages with pkg(8): %s\n' "$_pn"
	if ! destdir_user_owned; then
		printf 'install the driver, libraries and tools into %s as root (owner root:wheel)\n' "${DESTDIR:-/}"
	fi
}

# install_confirm PLAN: the one question, asked before any root step.
install_confirm() {
	_q="These steps run as root, in this order:
$(printf '%s\n' "$1" | awk '{ printf "  %d. %s\n", NR, $0 }')
Go ahead? [y/N] "
	if [ "${MK_JSON:-0}" = 1 ] || [ "${MK_JSONL:-0}" = 1 ]; then
		printf '%s' "$_q" >&2
	else
		printf '%s' "$_q"
	fi
	read -r _ans || return 1
	case $_ans in
	y|Y|yes|YES|Yes) return 0 ;;
	esac
	return 1
}

# Run a phase in a new sh so its set -e and die paths stay active even though
# the parent captures its status.  Machine modes keep the log out of stdout;
# English shows exactly the same phase output after the phase ends.
install_run_phase() {
	_phase=$1
	_fix=$2
	shift 2
	# the log lives in this run's own private directory (install_logdir)
	_log=$install_logdir/$_phase.log
	install_progress "$_phase" started
	_rc=0
	# fd 3 and 4 keep the real standard output and error for a question that
	# must reach the terminal (the licence); the phase itself is captured.
	# The subshell traps the termination signals (a trap is not inherited by
	# the command it starts) so it waits for the phase, which rolls back.
	( trap : HUP INT TERM; "$@" ) 3>&1 4>&2 > "$_log" 2>&1 || _rc=$?
	if [ "${MK_JSON:-0}" != 1 ] && [ "${MK_JSONL:-0}" != 1 ]; then
		if [ "$_rc" = 0 ]; then cat "$_log"; else cat "$_log" >&2; fi
	fi
	if [ "$_rc" != 0 ]; then
		if [ "$_phase" = install ]; then
			install_failure_blockers "$_rc" "$_log"
		else
			install_add_blocker "$_phase" "$_phase failed with exit $_rc; full output: $_log" "$_fix"
		fi
		return 1
	fi
	install_progress "$_phase" done
}

install_collect_records() {
	install_records=
	_stage_list=$(stage_files "$STAGE")
	while read -r _f; do
		[ -n "$_f" ] || continue
		if [ -L "$STAGE$_f" ]; then _mode=link; else _mode=$(stat -f '%Lp' "$STAGE$_f"); fi
		install_records="$install_records$_f|$_mode
"
	done <<EOF
$_stage_list
EOF
}

install_summary() {
	_outcome=$1
	if [ "${MK_JSON:-0}" = 1 ] || [ "${MK_JSONL:-0}" = 1 ]; then
		printf '{"schema_version":"1.0","tool":"install","outcome":"%s","blockers":[' "$_outcome"
		_i=0
		printf '%s' "$install_blockers" | while IFS='|' read -r _n _r _f; do
			[ "$_i" = 0 ] || printf ','
			printf '{"index":%s,"name":"%s","reason":"%s","fix":"%s"}' \
			    "$_i" "$(json_str "$_n")" "$(json_str "$_r")" "$(json_str "$_f")"
			_i=$((_i + 1))
		done
		printf '],"installed":['
		_i=0
		printf '%s' "$install_records" | while IFS='|' read -r _p _m; do
			[ -n "$_p" ] || continue
			[ "$_i" = 0 ] || printf ','
			printf '{"path":"%s","mode":"%s"}' "$(json_str "$_p")" "$(json_str "$_m")"
			_i=$((_i + 1))
		done
		printf '],"next":['
		if [ "$_outcome" = installed ]; then
			_i=0
			install_next_steps | while read -r _ns; do
				[ "$_i" = 0 ] || printf ','
				printf '"%s"' "$(json_str "$_ns")"
				_i=$((_i + 1))
			done
		fi
		printf ']}\n'
		return 0
	fi
	printf '%s' "$install_blockers" | while IFS='|' read -r _n _r _f; do
		printf 'blocked %s: %s\n' "$_n" "$_r"
		[ -z "$_f" ] || printf 'fix: %s\n' "$_f"
	done
	if [ "$_outcome" = installed ]; then
		printf '%s' "$install_records" | while IFS='|' read -r _p _m; do
			[ -n "$_p" ] && printf 'installed %s %s\n' "$_p" "$_m"
		done
		install_next_steps | while read -r _ns; do
			printf 'next: %s\n' "$_ns"
		done
	fi
	printf 'install: %s\n' "$_outcome"
}

do_install() {
	install_blockers=
	install_records=
	install_outcome=blocked
	if [ "${MK_JSON:-0}" = 1 ] && [ "${MK_JSONL:-0}" = 1 ]; then
		printf 'make.sh: JSON=1 is ignored: JSONL=1 wins (one object per line)\n' >&2
		MK_JSON=0
	fi
	# Collection performs no writes.  In particular, an unaccepted licence or
	# an unusable platform cannot create WORK, STATEDIR or a destination file.
	collect_preflight
	install_collect_blockers
	if [ -n "$install_blockers" ]; then
		install_summary blocked
		return 1
	fi
	# One question, before any privileged step: everything that runs as root,
	# in order.  YES=1 answers it; without a terminal and without YES=1 it
	# is a blocker and nothing has been done.
	_plan=$(install_root_plan)
	if [ -n "$_plan" ] && ! yes_set; then
		if [ ! -t 0 ]; then
			install_add_blocker confirm "this install runs steps as root ($(printf '%s' "$_plan" | tr '\n' ';')) and there is no terminal to ask on" "run with YES=1 or on a terminal"
			install_summary blocked
			return 1
		fi
		if ! install_confirm "$_plan"; then
			install_add_blocker confirm "the root steps were not confirmed; nothing was done" "rerun on a terminal and answer yes, or add YES=1"
			install_summary blocked
			return 1
		fi
	fi
	ensure_work
	# Phase logs go in a fresh private directory made here, so a name planted
	# beforehand (a symbolic link, say) is never written through.
	for _lp in "$WORK/logs" "$WORK/logs/make-install"; do
		if [ -L "$_lp" ]; then
			install_add_blocker logs "$_lp is a symbolic link; refusing to write the phase logs through it" "remove the symbolic link"
			install_summary blocked
			return 1
		fi
		[ -d "$_lp" ] || mkdir -m 755 -- "$_lp"
	done
	install_logdir=$(mktemp -d "$WORK/logs/make-install/run.XXXXXX") || die "cannot create a private log directory in $WORK/logs/make-install"
	if ! install_run_phase prereqs "rerun make install after correcting the prerequisite error" \
	    sh "$repo/scripts/make.sh" _install-prereqs-auto; then
		install_summary blocked
		return 1
	fi
	collect_preflight
	install_collect_blockers remaining
	if [ -n "$install_blockers" ]; then
		install_summary blocked
		return 1
	fi
	_ok=1
	for _ko in $(module_list); do
		[ -f "$TREE/$_ko" ] || _ok=0
	done
	[ -f "$LIBOBJ/info/nvrm-info" ] || _ok=0
	if [ "$_ok" = 1 ] && [ -f "$WORK/build/stamp" ] && [ "$(build_stamp)" = "$(cat "$WORK/build/stamp")" ]; then
		install_progress build "the build is current"
	else
		if ! install_run_phase build "rerun make install after correcting the build error" \
		    sh "$repo/scripts/make.sh" build; then
			install_summary blocked
			return 1
		fi
	fi
	if ! install_run_phase stage "rerun make install after correcting the staging error" \
	    sh "$repo/scripts/make.sh" _stage; then
		install_summary blocked
		return 1
	fi
	_n=$(stage_files "$STAGE" | wc -l | tr -d ' ')
	install_progress install "$_n staged files: modules to $DESTDIR/boot/modules, the rest under $DESTDIR$PREFIX"
	# The install step is the only one that may be cut short by a signal: this
	# process notes it, the step rolls itself back, and the outcome follows
	# what the step reports, never what was planned.
	install_signalled=0
	trap 'install_signalled=1' HUP INT TERM
	_irc=0
	if destdir_user_owned; then
		install_run_phase install "" \
		    sh "$repo/scripts/make.sh" _install-stage "$STAGE" "$DESTDIR" "$PREFIX" || _irc=1
	else
		install_run_phase install "" \
		    as_root sh "$repo/scripts/make.sh" _install-stage "$STAGE" "$DESTDIR" "$PREFIX" || _irc=1
	fi
	trap - HUP INT TERM
	if [ "$_irc" != 0 ]; then
		install_summary "$install_outcome"
		return 1
	fi
	install_collect_records
	install_summary installed
}

# migrate_manifest DESTDIR PREFIX [user|root]: commit 23c18da kept the
# manifest in PREFIX/share/nvidia-gb10-freebsd; it is moved to STATEDIR (its
# paths are absolute, only its own line changes), so deinstall and a reinstall
# still know the files that install wrote.  A root migration trusts only a
# root-owned manifest below root-owned, non-link directories, and every mode
# copies only paths install could have written.
migrate_manifest() {
	_d=$1
	_mp=${2:-/usr/local}
	_mode=${3:-root}
	_old=$_d$_mp/share/$name/installed.manifest
	_man=$_d$STATEDIR/installed.manifest
	[ -f "$_old" ] && [ ! -L "$_old" ] || return 0
	[ ! -e "$_man" ] && [ ! -L "$_man" ] || return 0
	if ! safe_parents "$_d" "$STATEDIR/installed.manifest" "$_mode"; then
		note "not migrating $_old: a destination directory is a symbolic link or not root's"
		return 1
	fi
	if [ "$_mode" = root ]; then
		if ! safe_parents "$_d" "$_mp/share/$name/installed.manifest" root \
		    || [ "$(stat -f '%u' "$_old")" != 0 ]; then
			note "not migrating $_old: not root's"
			return 1
		fi
	fi
	mkdir -p -- "$_d$STATEDIR"
	: > "$_man"
	printf '@prefix %s\n' "$_mp" >> "$_man"
	while read -r _f _rest; do
		[ -n "$_f" ] || continue
		case $_f in @*) continue ;; esac
		if [ "$_f" = "$_mp/share/$name/installed.manifest" ] || [ "$_f" = "$STATEDIR/installed.manifest" ]; then
			printf '%s%s%s\n' "$STATEDIR/installed.manifest" "${_rest:+ }" "$_rest" >> "$_man"
		elif [ "$_rest" = dir ]; then
			# Recreate only the directory records needed below; never copy
			# a directory path from an untrusted manifest verbatim.
			continue
		elif allowed_path "$_f" "$_mp"; then
			printf '%s%s%s\n' "$_f" "${_rest:+ }" "$_rest" >> "$_man"
		else
			note "refusing manifest path $_f: not a file make install writes"
		fi
	done < "$_old"
	# Preserve cleanup of directories an earlier install created, but only
	# when they are parents of an authorized path retained above.
	awk '$1 !~ /^@/ && $2 != "dir" { print $1 }' "$_man" | while read -r _f; do
		_dir=$(dirname -- "$_f")
		while [ "$_dir" != / ]; do
			if awk -v d="$_dir" '$1 == d && $2 == "dir" { found = 1 } END { exit !found }' "$_old"; then
				printf '%s dir\n' "$_dir"
			fi
			_dir=$(dirname -- "$_dir")
		done
	done | awk '!seen[$0]++' >> "$_man"
	printf '%s dir\n' "$STATEDIR" >> "$_man"
	rm -f -- "$_old"
	rmdir -- "$(dirname -- "$_old")" 2>/dev/null || true
	note "moved the manifest of an earlier install from $_old to $_man"
}

# install_stage STAGE DESTDIR PREFIX [user]
# Copy STAGE onto DESTDIR.  The stage (owned by the building user) is first
# copied with tar(1), which never follows a symbolic link, into a private
# directory created here, and everything is read from that copy, so the
# user cannot swap a file between the checks and the copy.  Every staged
# path must be in the fixed set allowed_path names, and every directory on
# the way must be a real directory (root-owned for a root install).  A file
# is replaced only when the manifest lists it AND it still holds what was
# written.  The manifest gets pending lines (with the sha256 about to be
# written) before the copy, so an interrupted install or upgrade can be
# rerun and deinstalled; at the end it is rewritten from the files on disk,
# and files of the previous install that this stage no longer has are
# removed when they are still ours.  With "user" (a non-root DESTDIR run)
# the files keep this user as owner.
# Transaction backups hold the original bytes, modes and link targets of
# every path this install can replace or remove.  The manifest and an old-place
# manifest are included, as is linker.hints (kldxref rewrites it last).
txn_backup() {
	_tb_path=$1
	if awk -v p="$_tb_path" '$3 == p { found = 1 } END { exit !found }' "$_txn_records"; then
		return 0
	fi
	_tb_dest=$_txn_root$_tb_path
	_tb_kind=absent
	if [ -L "$_tb_dest" ]; then
		_tb_kind=link
		readlink "$_tb_dest" > "$_txn_dir/$_txn_n.target" || die "cannot save the link at $_tb_dest"
	elif [ -e "$_tb_dest" ]; then
		[ -f "$_tb_dest" ] || die "refusing to replace $_tb_dest: not a file or symbolic link"
		_tb_kind=file
		cp -p -- "$_tb_dest" "$_txn_dir/$_txn_n.file" || die "cannot back up $_tb_dest"
	fi
	printf '%s %s %s\n' "$_txn_n" "$_tb_kind" "$_tb_path" >> "$_txn_records"
	_txn_n=$((_txn_n + 1))
}

# txn_state PATH: what PATH holds now, as one line: "A" nothing, "F:SHA256" a
# file, "L:TARGET" a symbolic link, "O" anything else.
txn_state() {
	if [ -L "$1" ]; then
		printf 'L:%s\n' "$(readlink "$1")"
	elif [ -f "$1" ]; then
		printf 'F:%s\n' "$(sha256 -q "$1")"
	elif [ -e "$1" ]; then
		printf 'O\n'
	else
		printf 'A\n'
	fi
}

# txn_intend PATH STATE: record, before it is written, what this install is
# about to leave at PATH.  The rollback touches a path only when it holds
# its original state or one of these; anything else was changed by another
# process and is left alone and reported.
txn_intend() {
	printf '%s %s\n' "$1" "$2" >> "$_txn_intents"
}

# txn_orig_state N KIND: the state txn_backup saved as backup N.
txn_orig_state() {
	case $2 in
	file) printf 'F:%s\n' "$(sha256 -q "$_txn_dir/$1.file")" ;;
	link) printf 'L:%s\n' "$(cat "$_txn_dir/$1.target")" ;;
	*) printf 'A\n' ;;
	esac
}

# txn_signal NUMBER: a signal during the install.  The exit status (128 plus
# the number) is how make install learns it was interrupted; the EXIT trap
# then rolls back.
txn_signal() {
	exit $((128 + $1))
}

# txn_rollback_fail PATH WHY: a path the rollback left as it found it.
txn_rollback_fail() {
	printf 'rollback-failed %s: %s\n' "$1" "$2"
	_txn_failed=1
}

# EXIT is deliberate: die, an interrupted copy, a failed install(1), and a
# failed kldxref all take the same restoration path.  Restoration is best
# effort after an I/O error, but every path is attempted and the original
# failure status is retained.  A path is removed or restored only while it
# still holds what this run wrote (or its original); otherwise it is left
# and printed as "rollback-failed PATH: WHY".  The last line says
# "rollback: restored" only when every path was put back.
txn_exit() {
	_txn_rc=$?
	trap '' HUP INT TERM
	trap - EXIT
	if [ "${_txn_active:-0}" = 1 ]; then
		[ "$_txn_rc" != 0 ] || _txn_rc=1
		_txn_failed=0
		note "install: failed; restoring every replaced file and removing new files"
		if [ "${_txn_hints:-0}" = 1 ]; then
			# kldxref ran (or was cut short) under this install
			txn_intend /boot/modules/linker.hints "$(txn_state "$_txn_root/boot/modules/linker.hints")"
		fi
		if [ -n "$_txn_records" ] && [ -f "$_txn_records" ]; then
			while read -r _tb_n _tb_kind _tb_path; do
				[ -n "$_tb_path" ] || continue
				_tb_dest=$_txn_root$_tb_path
				rm -f -- "$_tb_dest.new" "$_tb_dest.rollback" 2>/dev/null || true
				_tb_cur=$(txn_state "$_tb_dest")
				_tb_orig=$(txn_orig_state "$_tb_n" "$_tb_kind")
				if [ "$_tb_cur" = "$_tb_orig" ]; then
					continue
				fi
				if ! grep -qxF -- "$_tb_path $_tb_cur" "$_txn_intents" 2>/dev/null; then
					txn_rollback_fail "$_tb_path" "not restored: changed by another process since this install wrote it"
					continue
				fi
				case $_tb_kind in
				absent)
					rm -f -- "$_tb_dest" 2>/dev/null || txn_rollback_fail "$_tb_path" "not restored: could not remove it"
					;;
				file)
					if cp -p -- "$_txn_dir/$_tb_n.file" "$_tb_dest.rollback" 2>/dev/null \
					    && mv -f -- "$_tb_dest.rollback" "$_tb_dest" 2>/dev/null; then :
					else
						txn_rollback_fail "$_tb_path" "not restored: could not put the original back"
					fi
					;;
				link)
					rm -f -- "$_tb_dest" 2>/dev/null || true
					ln -s "$(cat "$_txn_dir/$_tb_n.target")" "$_tb_dest" 2>/dev/null \
					    || txn_rollback_fail "$_tb_path" "not restored: could not put the original link back"
					;;
				esac
			done < "$_txn_records"
		fi
		# The transaction lives below STATEDIR.  Remove it after the backups
		# have been used but before the new directories, or STATEDIR and its
		# new parents cannot be empty when their turn comes.
		[ -z "$_w" ] || rm -rf -- "$_w" 2>/dev/null || true
		printf '%s\n' "$_newdirs" | awk 'NF' | sort -r | while read -r _dir; do
			rmdir -- "$_txn_root$_dir" 2>/dev/null || true
		done
		[ "$_txn_failed" = 1 ] || printf 'rollback: restored\n'
	fi
	exit "$_txn_rc"
}

install_stage() {
	_src=$1
	_d=$2
	_pfx=$3
	_mode=${4:-root}
	_own="-o root -g wheel"
	[ "$_mode" = user ] && _own=
	_man=$_d$STATEDIR/installed.manifest
	if [ "$_mode" = root ] && [ -n "$_d" ]; then
		[ "$(stat -f '%u' "$_d")" = 0 ] || die "refusing DESTDIR $_d as root: not owned by root"
	fi
	safe_parents "$_d" "$STATEDIR/x" "$_mode" || die "refusing $_d$STATEDIR: a directory on the way is a symbolic link or not root's"
	_manifest_pfx=$_pfx
	if [ -e "$_man" ] || [ -L "$_man" ]; then
		[ ! -L "$_man" ] || die "refusing $_man: symbolic link"
		_recorded=$(awk '$1 == "@prefix" { print $2; exit }' "$_man")
		[ -z "$_recorded" ] || _manifest_pfx=$_recorded
		[ "$_manifest_pfx" = "$_pfx" ] \
		    || die "install: PREFIX $_pfx differs from the recorded $_manifest_pfx; make deinstall PREFIX=$_manifest_pfx first"
	fi
	_newdirs=
	_dir=$STATEDIR
	while [ "$_dir" != / ] && [ ! -d "$_d$_dir" ]; do
		_newdirs="$_dir
$_newdirs"
		_dir=$(dirname -- "$_dir")
	done
	# The rollback is armed before anything is created, so a failure at any
	# later point (including making the private directory) cannot leak it.
	_w=
	_txn_root=$_d
	_txn_dir=
	_txn_records=
	_txn_intents=
	_txn_hints=0
	_txn_n=0
	_txn_active=1
	trap txn_exit EXIT
	trap 'txn_signal 1' HUP
	trap 'txn_signal 2' INT
	trap 'txn_signal 15' TERM
	mkdir -p -- "$_d$STATEDIR"
	_w=$(mktemp -d "$_d$STATEDIR/.install.XXXXXX") || die "cannot create a private directory in $_d$STATEDIR"
	_txn_dir=$_w/backups
	_txn_records=$_w/backup.list
	_txn_intents=$_w/intents
	mkdir -- "$_txn_dir"
	: > "$_txn_records"
	: > "$_txn_intents"
	# Save manifests before migration, which is itself rolled back if any
	# later validation or copy fails.
	txn_backup "$STATEDIR/installed.manifest"
	_old_manifest=$_pfx/share/$name/installed.manifest
	if [ -f "$_d$_old_manifest" ] && [ ! -L "$_d$_old_manifest" ]; then
		txn_backup "$_old_manifest"
	fi
	txn_backup /boot/modules/linker.hints
	migrate_manifest "$_d" "$_pfx" "$_mode" \
	    || die "install: migration refused; remove the planted file or check its owner"
	# migration wrote the new manifest and removed the old-place one
	txn_intend "$STATEDIR/installed.manifest" "$(txn_state "$_man")"
	txn_intend "$_old_manifest" "$(txn_state "$_d$_old_manifest")"
	_s=$_w/stage
	mkdir -- "$_s"
	tar -C "$_src" -cf - . | tar -C "$_s" -xpf - || die "cannot copy the stage"
	stage_files "$_s" > "$_w/list"
	[ -s "$_w/list" ] || die "the stage $_src is empty"
	_prev=$_w/prev
	: > "$_prev"
	if [ -f "$_man" ]; then
		[ ! -L "$_man" ] || die "refusing $_man: symbolic link"
		cp -- "$_man" "$_prev"
	fi
	while read -r _f; do
		path_ok "$_f" && allowed_path "$_f" "$_pfx" || die "refusing staged path $_f: not a file make install writes"
		if [ -L "$_s$_f" ]; then
			case $(readlink "$_s$_f") in
			''|*/*|*[!A-Za-z0-9._-]*) die "refusing staged link $_f -> $(readlink "$_s$_f")" ;;
			esac
		fi
		safe_parents "$_d" "$_f" "$_mode" || die "refusing $_d$_f: a directory on the way is a symbolic link or not root's"
		if [ -e "$_d$_f" ] || [ -L "$_d$_f" ]; then
			awk -v p="$_f" '$1 == p' "$_prev" | grep -q . || die "refusing to replace $_d$_f: make install did not write it"
			still_ours "$_d" "$_prev" "$_f" || die "refusing to replace $_d$_f: it changed since make install wrote it"
		fi
		txn_backup "$_f"
	done < "$_w/list"
	# Save files which a smaller stage would remove before creating anything.
	_stale=$(awk '$1 !~ /^@/ && $2 != "dir" { print $1 }' "$_prev" | sort -u)
	while read -r _f; do
		[ -n "$_f" ] || continue
		[ "$_f" = "$STATEDIR/installed.manifest" ] && continue
		grep -qxF -- "$_f" "$_w/list" && continue
		path_ok "$_f" && allowed_path "$_f" "$_manifest_pfx" && safe_parents "$_d" "$_f" "$_mode" || continue
		txn_backup "$_f"
	done <<EOF
$_stale
EOF
	# Directories this install creates are recorded ("path dir").
	while read -r _f; do
		_dir=$(dirname -- "$_f")
		while [ "$_dir" != / ] && [ ! -d "$_d$_dir" ]; do
			_newdirs="$_newdirs
$_dir"
			_dir=$(dirname -- "$_dir")
		done
		mkdir -p -- "$(dirname -- "$_d$_f")"
	done < "$_w/list"
	# Pending manifest: the previous lines plus a pending line (with the
	# sha256 or link target about to be written) for every staged path.
	{
		printf '@prefix %s\n' "$_pfx"
		cat "$_prev"
		while read -r _f; do
			pending_line "$_s" "$_f"
		done < "$_w/list"
		printf '%s\n' "$_newdirs" | awk 'NF { print $0 " dir" }'
	} | awk '!seen[$0]++' > "$_man.new"
	txn_intend "$STATEDIR/installed.manifest" "$(txn_state "$_man.new")"
	mv -f -- "$_man.new" "$_man"
	while read -r _f; do
		txn_intend "$_f" "$(txn_state "$_s$_f")"
		if [ -L "$_s$_f" ]; then
			ln -sfh "$(readlink "$_s$_f")" "$_d$_f" || die "install: cannot replace the link $_d$_f"
		else
			# shellcheck disable=SC2086
			install $_own -m "$(stat -f '%Lp' "$_s$_f")" -- "$_s$_f" "$_d$_f.new" \
			    || die "install: cannot write $_d$_f"
			mv -f -- "$_d$_f.new" "$_d$_f" || die "install: cannot replace $_d$_f"
		fi
	done < "$_w/list"
	# Files of the previous install that this stage no longer has.
	while read -r _f; do
		[ -n "$_f" ] || continue
		[ "$_f" = "$STATEDIR/installed.manifest" ] && continue
		grep -qxF -- "$_f" "$_w/list" && continue
		if ! path_ok "$_f"; then
			note "install: refusing manifest path $_f"
			continue
		fi
		if ! allowed_path "$_f" "$_manifest_pfx"; then
			note "install: refusing manifest path $_f: not a file make install writes"
			continue
		fi
		safe_parents "$_d" "$_f" "$_mode" || continue
		rm -f -- "$_d$_f.new"
		if still_ours "$_d" "$_prev" "$_f"; then
			txn_intend "$_f" A
			rm -f -- "$_d$_f" || die "install: cannot remove the obsolete $_d$_f"
		fi
	done <<EOF
$_stale
EOF
	{
		printf '@prefix %s\n' "$_pfx"
		while read -r _f; do
			manifest_line "$_d" "$_f"
		done < "$_w/list"
		printf '%s 444 %s -\n' "$STATEDIR/installed.manifest" "$(stat -f '%Su:%Sg' "$_d$STATEDIR")"
		awk '$2 == "dir"' "$_prev"
		printf '%s\n' "$_newdirs" | awk 'NF { print $0 " dir" }'
	} | awk '!seen[$0]++' > "$_man.new"
	txn_intend "$STATEDIR/installed.manifest" "$(txn_state "$_man.new")"
	mv -f -- "$_man.new" "$_man"
	chmod 444 "$_man"
	# kldxref refreshes linker.hints; in a DESTDIR its failure (for example
	# a staging tree without other modules) is reported, not fatal.  A live
	# kldxref failure is an install failure and therefore rolls back too.
	_kldxref=$(test_hook make.sh GB10_TEST_KLDXREF /usr/sbin/kldxref) || die "install: refused the kldxref test hook"
	_txn_hints=1
	if [ -z "$_d" ]; then
		"$_kldxref" /boot/modules || die "install: kldxref /boot/modules failed"
	else
		"$_kldxref" "$_d/boot/modules" || note "kldxref $_d/boot/modules failed (DESTDIR staging)"
	fi
	_txn_hints=0
	_txn_active=0
	trap - EXIT HUP INT TERM
	rm -rf -- "$_w"
}

# kernel module names (as kldstat -n takes them) of every module we install
module_names() {
	module_list | while read -r _ko; do
		basename "$_ko" .ko
	done
}

do_deinstall() {
	setup
	if [ ! -f "$MANIFEST" ] && [ ! -f "$DESTDIR$STATEDIR/configured" ] && [ ! -f "$DESTDIR$PREFIX/share/$name/installed.manifest" ]; then
		note "deinstall: nothing installed (no $MANIFEST)"
		return 0
	fi
	if [ -z "$DESTDIR" ]; then
		_ours=$(module_names)
		for _k in drm dmabuf; do
			[ -f "$MANIFEST" ] && awk -v p="/boot/modules/$_k.ko" '$1 == p' "$MANIFEST" | grep -q . && _ours="$_ours $_k"
		done
		for _k in $_ours; do
			if kldstat -q -n "$_k" 2>/dev/null; then
				die "deinstall: $_k is loaded; unload it first (or reboot)"
			fi
		done
	fi
	[ ! -f "$MANIFEST" ] || note "deinstall: removing the $(awk '$1 !~ /^@/ && $2 != "dir"' "$MANIFEST" | awk '{ print $1 }' | sort -u | wc -l | tr -d ' ') files listed in $MANIFEST"
	[ ! -f "$DESTDIR$STATEDIR/configured" ] || note "deinstall: and taking out what make configure set ($DESTDIR$STATEDIR/configured)"
	if [ -n "$DESTDIR" ] && [ "$(id -u)" != 0 ]; then
		ask "Remove them from $DESTDIR?" || die "deinstall: nothing removed"
		deinstall_manifest "$DESTDIR" user "$PREFIX"
	else
		ask "Remove them as root?" || die "deinstall: nothing removed"
		as_root sh "$repo/scripts/make.sh" _deinstall "$DESTDIR" "$PREFIX"
	fi
}

# deinstall_manifest DESTDIR [user|root [PREFIX]]: remove each manifest path that still
# holds what install wrote; a changed file is kept, reported, and left in a
# shortened manifest (exit 1).  Then the directories install created,
# deepest first, and what configure set.
deinstall_manifest() {
	_d=$1
	_mode=${2:-root}
	_pfx=${3:-/usr/local}
	if [ "$_mode" = root ] && [ -n "$_d" ]; then
		[ "$(stat -f '%u' "$_d")" = 0 ] || die "refusing DESTDIR $_d as root: not owned by root"
	fi
	_man=$_d$STATEDIR/installed.manifest
	unconfigure "$_d" "$_mode"
	migrate_manifest "$_d" "$_pfx" "$_mode" \
	    || die "deinstall: migration refused; remove the planted file or check its owner"
	[ ! -L "$_man" ] || die "refusing $_man: symbolic link"
	[ -f "$_man" ] || return 0
	safe_parents "$_d" "$STATEDIR/installed.manifest" "$_mode" || die "refusing $_man: a directory on the way is a symbolic link or not root's"
	_recorded=$(awk '$1 == "@prefix" { print $2; exit }' "$_man")
	[ -z "$_recorded" ] || _pfx=$_recorded
	_kept=$_man.kept
	: > "$_kept"
	awk '$1 !~ /^@/ && $2 != "dir" { print $1 }' "$_man" | sort -u | while read -r _f; do
		[ "$_f" = "$STATEDIR/installed.manifest" ] && continue
		if ! path_ok "$_f"; then
			note "deinstall: refusing manifest path $_f"
			continue
		fi
		if ! allowed_path "$_f" "$_pfx"; then
			note "deinstall: refusing manifest path $_f: not a file make install writes"
			continue
		fi
		if ! safe_parents "$_d" "$_f" "$_mode"; then
			note "deinstall: refusing $_d$_f: a directory on the way is a symbolic link or not root's"
			continue
		fi
		rm -f -- "$_d$_f.new"
		if [ ! -e "$_d$_f" ] && [ ! -L "$_d$_f" ]; then
			continue
		fi
		if still_ours "$_d" "$_man" "$_f"; then
			rm -f -- "$_d$_f"
		else
			note "deinstall: kept $_d$_f (changed since make install wrote it)"
			awk -v p="$_f" '$1 == p' "$_man" >> "$_kept"
		fi
	done
	_dirs=$(awk '$2 == "dir" { print $1 }' "$_man" | sort -r)
	_rc=0
	if [ -s "$_kept" ]; then
		# the kept files stay listed, with the directories, so a later
		# install or deinstall still knows them
		awk '$2 == "dir"' "$_man" >> "$_kept"
		printf '@prefix %s\n' "$_pfx" >> "$_kept"
		mv -f -- "$_kept" "$_man"
		chmod 444 "$_man"
		_rc=1
	else
		rm -f -- "$_kept" "$_man"
	fi
	printf '%s\n' "$_dirs" | while read -r _dir; do
		[ -n "$_dir" ] || continue
		path_ok "$_dir" && safe_parents "$_d" "$_dir/x" "$_mode" || continue
		rmdir -- "$_d$_dir" 2>/dev/null || note "deinstall: kept $_d$_dir (not empty)"
	done
	if [ -z "$_d" ]; then
		kldxref /boot/modules
	elif [ -d "$_d/boot/modules" ]; then
		kldxref "$_d/boot/modules" || note "kldxref $_d/boot/modules failed (DESTDIR staging)"
	fi
	[ "${_statedir_ours:-0}" = 1 ] && rmdir -- "$_d$STATEDIR" 2>/dev/null
	[ "$_rc" = 0 ] && note "deinstall: done" || note "deinstall: done, with changed files kept (listed in $_man)"
	return "$_rc"
}

do_clean() {
	setup
	[ -d "$WORK" ] || { note "clean: nothing to clean ($WORK does not exist)"; return 0; }
	ensure_work
	rm -rf -- "$WORK/build" "$WORK/stage"
	note "clean: removed $WORK/build and $WORK/stage (downloads kept)"
}

# test-install: the stock-install test (tests/install-e2e/run.sh) for this
# repository.  E2E_REPO_URL is what the guest clones (a mirror the test
# host serves; the GitHub URL is the default for a real user), E2E_REF
# overrides the default checkout HEAD (the mirror must carry that commit),
# and E2E_OS, E2E_ARCH, E2E_BACKEND and E2E_SSH choose the machine.
do_test_install() {
	setup
	_url=${MK_E2E_REPO_URL:-}
	[ -n "$_url" ] || _url=$(git -C "$repo" remote get-url origin 2>/dev/null || echo https://github.com/cloudbsdorg/nvidia-gb10-freebsd.git)
	_ref=${MK_E2E_REF:-}
	[ -n "$_ref" ] || _ref=$(git -C "$repo" rev-parse HEAD) || die "test-install: cannot resolve checkout HEAD"
	set -- --repo-url "$_url" \
	    --installed-manifest "$STATEDIR/installed.manifest" \
	    --expected-manifest tests/install-e2e/expected.manifest --load nvidia-drm \
	    --os "${MK_E2E_OS:-16.0-CURRENT}" --arch "${MK_E2E_ARCH:-aarch64}" --backend "${MK_E2E_BACKEND:-vmm}"
	set -- "$@" --ref "$_ref"
	[ -z "${MK_E2E_SSH:-}" ] || set -- "$@" --ssh "$MK_E2E_SSH"
	# the licence settings reach the guest's make install-prereqs only when
	# the person running the test gave them (make test-install
	# ACCEPT_NVIDIA_LICENSE=1); without them the guest stops at the licence
	[ "${MK_ACCEPT_NVIDIA_LICENSE:-0}" != 1 ] || set -- "$@" --make-arg ACCEPT_NVIDIA_LICENSE=1
	[ "${MK_ACCEPT_ALL_LICENSES:-0}" != 1 ] || set -- "$@" --make-arg ACCEPT_ALL_LICENSES=1
	sh "$repo/tests/install-e2e/run.sh" "$@"
}

target=${1:-}
case $target in
preflight)
	shift
	while [ $# -gt 0 ]; do
		case $1 in
		--json) MK_JSON=1 ;;
		--purpose)
			[ $# -ge 2 ] || { echo "make.sh: --purpose needs a value" >&2; exit 2; }
			MK_PURPOSE=$2
			shift
			;;
		*) echo "make.sh: preflight: unknown argument $1" >&2; exit 2 ;;
		esac
		shift
	done
	do_preflight
	;;
install-prereqs) do_install_prereqs ;;
_install-prereqs-auto) do_install_prereqs auto ;;
_stage)
	setup
	stage
	;;
configure) do_configure ;;
build) do_build ;;
test) do_test ;;
install) do_install ;;
deinstall) do_deinstall ;;
test-install) do_test_install ;;
clean) do_clean ;;
_install-stage)
	# as root: the install step of make install; as a user: only into a
	# DESTDIR, the files keeping this user as owner (the tests use this)
	[ $# = 4 ] || die "usage: make.sh _install-stage STAGE DESTDIR PREFIX"
	if [ "$(id -u)" = 0 ]; then
		install_stage "$2" "$3" "$4"
	elif [ -n "$3" ]; then
		install_stage "$2" "$3" "$4" user
	else
		die "_install-stage without a DESTDIR runs as root"
	fi
	;;
_deinstall)
	[ $# = 3 ] || die "usage: make.sh _deinstall DESTDIR PREFIX"
	[ "$(id -u)" = 0 ] || die "_deinstall runs as root"
	deinstall_manifest "$2" root "$3"
	;;
_configure)
	[ $# = 2 ] || die "usage: make.sh _configure DESTDIR"
	[ "$(id -u)" = 0 ] || die "_configure runs as root"
	apply_config "$2"
	;;
_module-list) module_list ;;
_next-steps)
	setup
	install_next_steps
	;;
_licence)
	setup
	ensure_work
	show_licence
	;;
_build-stamp)
	setup
	build_stamp
	;;
*)
	printf 'usage: sh scripts/make.sh preflight|install-prereqs|configure|build|test|install|deinstall|test-install|clean\n' >&2
	exit 2
	;;
esac

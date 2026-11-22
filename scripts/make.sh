#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# make.sh - the logic behind the root Makefile (skill
# project-makefile-contract).  The Makefile passes its switches as MK_*
# variables and one target name; this script does the work in sh(1), so the
# Makefile stays portable between bmake and GNU make.
#
# Usage: sh scripts/make.sh TARGET
#   preflight [--json] [--purpose NAME]  report what is missing (--json or MK_JSON=1: the
#                    JSON contract; exit 1 when something is missing)
#   install-prereqs  install the missing packages and fetch the sources
#   configure        print the trees and paths the build would use
#   build            prepare the tree, build every module and libnvrm
#   test             run the repository unit tests
#   install          build if needed, stage, then install as root
#   deinstall        remove exactly what install wrote
#   test-install     the clean-install end-to-end run (tests/install-e2e)
#   clean            remove WORK/build and WORK/stage (keeps the downloads)
#
# Environment (set by the Makefile; all optional):
#   MK_WORK       downloads and build; default <repo>/work
#   MK_PREFIX     user-space install root; default /usr/local
#   MK_DESTDIR    staging root for install and deinstall; default empty
#   MK_SYSDIR MK_BSDSRCTOP MK_DRMKMODDIR   trees to use instead of the
#                 detected or fetched ones
#   MK_YES MK_ASSUME_YES   1: do not ask
#   MK_JSON       1: preflight prints JSON
#   MK_PURPOSE    the Makefile REPO_PURPOSE, echoed by preflight
#
# Kernel modules install to $DESTDIR/boot/modules, everything else under
# $DESTDIR$PREFIX.  install records every file it wrote (path, mode, owner,
# sha256) in $DESTDIR$PREFIX/share/nvidia-gb10-freebsd/installed.manifest;
# deinstall removes those files and nothing else.  Nothing uses /tmp.
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

die() {
	printf 'make: %s\n' "$*" >&2
	exit 1
}

note() {
	printf 'make: %s\n' "$*"
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

# Absolute work root, created on demand; build-rmcore.sh and build-stubs.sh
# need it absolute.
work_root() {
	_w=${MK_WORK:-}
	[ -n "$_w" ] || _w=$repo/work
	case $_w in
	/*) ;;
	*) _w=$(pwd -P)/$_w ;;
	esac
	mkdir -p -- "$_w"
	# fetch-sources.sh refuses a sources directory writable by group or
	# other; WORK holds it
	chmod go-w "$_w"
	CDPATH= cd -- "$_w" && pwd -P
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

# os_version_of SYSDIR: __FreeBSD_version from SYSDIR/sys/param.h, or empty.
os_version_of() {
	[ -f "$1/sys/param.h" ] || return 0
	sed -n 's/^#define[[:space:]]*__FreeBSD_version[[:space:]]*\([0-9]*\).*/\1/p' "$1/sys/param.h"
}

# The kernel tree: MK_SYSDIR, else /usr/src/sys when it matches the running
# kernel, else WORK/src/sys (make install-prereqs fetches it there).
resolve_sysdir() {
	if [ -n "${MK_SYSDIR:-}" ]; then
		printf '%s\n' "$MK_SYSDIR"
		return 0
	fi
	_run=$(sysctl -n kern.osreldate 2>/dev/null || true)
	if [ -n "$_run" ] && [ "$(os_version_of /usr/src/sys)" = "$_run" ]; then
		printf '%s\n' /usr/src/sys
		return 0
	fi
	printf '%s\n' "$WORK/src/sys"
}

resolve_bsdsrctop() {
	if [ -n "${MK_BSDSRCTOP:-}" ]; then
		printf '%s\n' "$MK_BSDSRCTOP"
	else
		dirname -- "$SYSDIR"
	fi
}

resolve_drmkmoddir() {
	if [ -n "${MK_DRMKMODDIR:-}" ]; then
		printf '%s\n' "$MK_DRMKMODDIR"
	else
		printf '%s\n' "$WORK/drm-kmod"
	fi
}

setup() {
	WORK=$(work_root)
	PREFIX=$(prefix)
	DESTDIR=$(destdir)
	SYSDIR=$(resolve_sysdir)
	BSDSRCTOP=$(resolve_bsdsrctop)
	DRMKMODDIR=$(resolve_drmkmoddir)
	TREE=$WORK/build/tree
	STAGE=$WORK/stage
	LIBOBJ=$WORK/build/libnvrm-obj
	GB10_WORK=$WORK
	TMPDIR=$WORK/tmp
	mkdir -p -- "$TMPDIR"
	export GB10_WORK TMPDIR SYSDIR BSDSRCTOP DRMKMODDIR
	ogkm_tag=$(awk '$1 == "ogkm_tag" { print $2 }' "$repo/SOURCES")
	tarball=$WORK/sources/$(awk '$1 == "nvidia_freebsd_url" { n = split($2, p, "/"); print p[n] }' "$repo/SOURCES")
	ogkm_dir=$WORK/sources/open-gpu-kernel-modules-$ogkm_tag
}

# root_method: how this user becomes root: root, doas, sudo, su (asks for
# the root password on the terminal) or none.
root_method() {
	if [ "$(id -u)" = 0 ]; then
		echo root
	elif command -v doas >/dev/null 2>&1; then
		echo doas
	elif command -v sudo >/dev/null 2>&1; then
		echo sudo
	elif [ -t 0 ]; then
		echo su
	else
		echo none
	fi
}

# as_root CMD...: run CMD as root, the way root_method names.
as_root() {
	case $(root_method) in
	root) "$@" ;;
	doas) doas "$@" ;;
	sudo) sudo "$@" ;;
	su)
		note "neither doas nor sudo is installed: asking su for the root password"
		# root's shell is sh(1) on FreeBSD 14 and later; the arguments
		# reach it as "$0" "$@", each one word, never re-split
		su root -c 'exec "$0" "$@"' "$@"
		;;
	*) die "this step needs root: install doas or sudo, or run make on a terminal (su asks for the root password)" ;;
	esac
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
# device node.
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

do_preflight() {
	setup
	_os=$(uname -s)
	_arch=$(uname -p 2>/dev/null || uname -m)
	if [ "$_os" = FreeBSD ] && [ "$_arch" = aarch64 ]; then
		add_item platform ok "FreeBSD $(uname -r) $_arch" ""
	else
		add_item platform missing "$_os $_arch: this repository builds the FreeBSD arm64 (aarch64) driver; on amd64 use NVIDIA's own FreeBSD driver" ""
	fi
	for _t in cc fetch sha256 tar kldxref mandoc git gmake; do
		if command -v "$_t" >/dev/null 2>&1; then
			add_item "tool:$_t" ok "$(command -v "$_t")" ""
		else
			add_item "tool:$_t" missing "not on PATH" "make install-prereqs"
		fi
	done
	if /usr/bin/ld --version 2>/dev/null | grep -q LLD; then
		add_item "tool:ld" ok "/usr/bin/ld is LLD" ""
	else
		add_item "tool:ld" missing "/usr/bin/ld is not LLD: a module linked by GNU ld does not load" ""
	fi
	if [ -f "$tarball" ] && [ -d "$ogkm_dir" ]; then
		add_item sources ok "$WORK/sources" ""
	else
		add_item sources missing "NVIDIA sources not fetched into $WORK/sources" "make install-prereqs"
	fi
	_run=$(sysctl -n kern.osreldate 2>/dev/null || true)
	_have=$(os_version_of "$SYSDIR")
	if [ -n "$_have" ] && [ "$_have" = "$_run" ]; then
		add_item sysdir ok "$SYSDIR (__FreeBSD_version $_have)" ""
	elif [ -n "$_have" ]; then
		add_item sysdir missing "$SYSDIR is __FreeBSD_version $_have, the running kernel is $_run" "make install-prereqs, or SYSDIR=<matching sys/>"
	else
		add_item sysdir missing "no kernel sources at $SYSDIR" "make install-prereqs"
	fi
	if [ -d "$BSDSRCTOP/include" ]; then
		add_item bsdsrctop ok "$BSDSRCTOP" ""
	else
		add_item bsdsrctop missing "no FreeBSD source top (include/) at $BSDSRCTOP" "make install-prereqs"
	fi
	if [ -f "$DRMKMODDIR/linuxkpi_version.mk" ]; then
		add_item drmkmoddir ok "$DRMKMODDIR" ""
	else
		add_item drmkmoddir missing "no drm-kmod sources at $DRMKMODDIR" "make install-prereqs"
	fi
	_rm=$(root_method)
	case $_rm in
	none) add_item root missing "no doas or sudo, and no terminal for su to ask the root password on" "pkg install doas, or run make on a terminal" ;;
	su) add_item root ok "su (asks for the root password; no doas or sudo)" "" ;;
	*) add_item root ok "$_rm" "" ;;
	esac
	# pciconf failing is "could not look", never "no device"
	_pcierr=0
	_devs=$(nvidia_devices) || _pcierr=1
	if [ "$_pcierr" = 1 ]; then
		add_item pci missing "pciconf -l failed: cannot tell whether an NVIDIA device is present" ""
	fi
	_missing=$(printf '%s' "$items" | awk -F'|' '$2 == "missing"' | wc -l | tr -d ' ')
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
		printf '\n  ],\n'
		if [ "$_pcierr" = 1 ]; then
			printf '  "device": "device check unavailable",\n'
		elif [ -n "$_devs" ]; then
			printf '  "device": "NVIDIA device present",\n'
		else
			printf '  "device": "no NVIDIA device",\n'
		fi
		printf '  "missing": %s\n}\n' "$_missing"
	else
		printf 'preflight: purpose=%s os=%s arch=%s work=%s\n' "${MK_PURPOSE:-application}" "$_os" "$_arch" "$WORK"
		printf '%s' "$items" | while IFS='|' read -r _n _s _r _f; do
			if [ "$_s" = ok ]; then
				printf 'ok    %s: %s\n' "$_n" "$_r"
			else
				printf 'miss  %s: %s%s\n' "$_n" "$_r" "${_f:+ (fix: $_f)}"
			fi
		done
		if [ "$_pcierr" = 1 ]; then
			printf 'gpu   device check unavailable (pciconf -l failed)\n'
		elif [ -n "$_devs" ]; then
			printf '%s\n' "$_devs" | sed 's/^/gpu   /'
		else
			printf 'gpu   no NVIDIA device (the build and install still work)\n'
		fi
		printf 'preflight: %s missing\n' "$_missing"
	fi
	[ "$_missing" = 0 ]
}

# --- install-prereqs ------------------------------------------------------

# drm-kmod is not here: the FreeBSD packages of it are amd64-only.
PKGS="git gmake"

do_install_prereqs() {
	setup
	_need=
	_boot=0
	if [ -x /usr/local/sbin/pkg ]; then
		for _p in $PKGS; do
			/usr/local/sbin/pkg info -e "$_p" 2>/dev/null || _need="$_need $_p"
		done
	else
		_boot=1
		_need=" $PKGS"
	fi
	if [ -n "$_need" ]; then
		[ "$_boot" = 0 ] || note "pkg(8) is not bootstrapped yet: it is bootstrapped first"
		note "packages to install:$_need"
		ask "Install these packages with pkg(8) as root?" || die "packages not installed"
		[ "$_boot" = 0 ] || as_root env ASSUME_ALWAYS_YES=yes pkg bootstrap -f
		# shellcheck disable=SC2086
		as_root env ASSUME_ALWAYS_YES=yes pkg install -y $_need
	else
		note "packages: all present ($PKGS)"
	fi
	sh "$repo/scripts/fetch-sources.sh" "$WORK/sources"
	if [ -f "$SYSDIR/sys/param.h" ] && [ -f "$DRMKMODDIR/linuxkpi_version.mk" ]; then
		note "kernel sources $SYSDIR and drm-kmod sources $DRMKMODDIR: present"
	elif [ -f "$repo/scripts/fetch-trees.sh" ]; then
		sh "$repo/scripts/fetch-trees.sh" --work "$WORK" --sysdir "$SYSDIR" --drmkmoddir "$DRMKMODDIR"
	else
		die "the kernel or drm-kmod sources are missing and this checkout cannot fetch them yet: set SYSDIR= and DRMKMODDIR="
	fi
}

# --- configure ------------------------------------------------------------

do_configure() {
	setup
	printf '%s\n' "WORK=$WORK" "PREFIX=$PREFIX" "DESTDIR=$DESTDIR" "SYSDIR=$SYSDIR" \
	    "BSDSRCTOP=$BSDSRCTOP" "DRMKMODDIR=$DRMKMODDIR" "modules -> $DESTDIR/boot/modules"
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

do_build() {
	setup
	LOGDIR=$WORK/logs/make-build
	rm -rf -- "$LOGDIR"
	mkdir -p -- "$LOGDIR" "$WORK/logs"
	[ -f "$tarball" ] && [ -d "$ogkm_dir" ] || sh "$repo/scripts/fetch-sources.sh" "$WORK/sources"
	[ -f "$SYSDIR/sys/param.h" ] || die "no kernel sources at $SYSDIR: run make install-prereqs"
	[ -f "$DRMKMODDIR/linuxkpi_version.mk" ] || die "no drm-kmod sources at $DRMKMODDIR: run make install-prereqs"
	# Every build starts from an empty build directory: with an RM core
	# object left from an earlier build, shim pass 1 would link and the
	# exit-3 check below would mean nothing.
	rm -rf -- "$WORK/build"
	mkdir -p -- "$WORK/build"
	step prepare-tree sh "$repo/scripts/prepare-tree.sh"
	step rmcore sh "$repo/scripts/build-rmcore.sh"
	# Pass 1 compiles the OS layer; it must fail at the link with exit 3
	# (no aarch64 RM core linked yet).  Anything else is a real failure.
	note "build: shim pass 1 (expected exit 3)"
	_rc=0
	sh "$repo/scripts/build-shim.sh" > "$LOGDIR/shim-pass1.log" 2>&1 || _rc=$?
	[ "$_rc" = 3 ] || { tail -n 20 "$LOGDIR/shim-pass1.log" >&2; die "shim pass 1 exited $_rc, not 3; log $LOGDIR/shim-pass1.log"; }
	step stubs sh "$repo/scripts/build-stubs.sh"
	step nvidia sh "$repo/scripts/build-shim.sh"
	step firmware sh "$repo/scripts/build-firmware.sh"
	step rmcore-modeset sh "$repo/scripts/build-rmcore.sh" --core=nvidia-modeset
	step nvidia-modeset sh "$repo/scripts/build-shim.sh" --module=nvidia-modeset
	step nvidia-drm sh "$repo/scripts/build-shim.sh" --module=nvidia-drm
	step nvidia-linux sh "$repo/scripts/build-shim.sh" --module=nvidia-linux
	step nvidia-modeset-linux sh "$repo/scripts/build-shim.sh" --module=nvidia-modeset-linux
	build_libnvrm
	for _ko in $(module_list); do
		[ -f "$TREE/$_ko" ] || die "missing after the build: $TREE/$_ko"
		readelf -p .comment "$TREE/$_ko" 2>/dev/null | grep -q 'Linker: LLD' \
		    || die "$TREE/$_ko was not linked by LLD"
	done
	build_stamp > "$WORK/build/stamp"
	note "build: OK (logs in $LOGDIR)"
}

# libnvrm and nvrm-info build with their objects under WORK (MAKEOBJDIR),
# so the checkout stays clean.
build_libnvrm() {
	rm -rf -- "$LIBOBJ"
	mkdir -p -- "$LIBOBJ/lib" "$LIBOBJ/info"
	step libnvrm env MAKEOBJDIR="$LIBOBJ/lib" OGKM="$ogkm_dir" /usr/bin/make -C "$repo/lib/libnvrm"
	step nvrm-info env MAKEOBJDIR="$LIBOBJ/info" LIBNVRM_OBJ="$LIBOBJ/lib" /usr/bin/make -C "$repo/lib/libnvrm/nvrm-info"
}

# Paths of the modules under TREE, in load order.
module_list() {
	printf '%s\n' firmware/gsp_ga10x/nvidia_gsp_ga10x_fw.ko nvidia/nvidia.ko \
	    nvidia-modeset/nvidia-modeset.ko nvidia-drm/nvidia-drm.ko \
	    nvidia-linux/nvidia_linux.ko nvidia-modeset-linux/nvidia_modeset_linux.ko
}

# --- test -----------------------------------------------------------------

do_test() {
	setup
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
	mkdir -p -- "$_m" "$_p/etc/rc.d" "$_p/share/man/man4" "$_p/share/man/man3" \
	    "$_p/share/man/man7" "$_p/share/man/man8" "$_p/lib" "$_p/include/nvrm" \
	    "$_p/sbin" "$_p/share/nvrm/schema"
	for _ko in $(module_list); do
		install -m 555 -- "$TREE/$_ko" "$_m/"
	done
	install -m 555 -- "$repo/rc.d/nvidia_linux" "$_p/etc/rc.d/nvidia_linux"
	for _man in "$repo"/man/*.4; do
		install -m 444 -- "$_man" "$_p/share/man/man4/"
	done
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

# manifest_line ROOT PATH: the manifest line of ROOT/PATH as it is on disk:
#   path mode owner:group sha256      (a file)
#   path link -> target               (a symbolic link)
manifest_line() {
	if [ -L "$1$2" ]; then
		printf '%s link -> %s\n' "$2" "$(readlink "$1$2")"
	else
		printf '%s %s %s %s\n' "$2" "$(stat -f '%Lp %Su:%Sg' "$1$2")" "$(sha256 -q "$1$2")"
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

# still_ours ROOT LINE: ROOT holds exactly what the manifest LINE recorded
# (same sha256 for a file, same target for a link).
still_ours() {
	_r=$1
	set -- $2
	[ -e "$_r$1" ] || [ -L "$_r$1" ] || return 1
	case $2 in
	link)
		[ -L "$_r$1" ] && [ "$(readlink "$_r$1")" = "$4" ]
		;;
	dir) return 1 ;;
	*)
		[ -f "$_r$1" ] && [ ! -L "$_r$1" ] && [ "$4" != - ] && [ "$(sha256 -q "$_r$1")" = "$4" ]
		;;
	esac
}

# Build stamp: what the modules were built from.  install rebuilds when it
# differs (a new kernel, new patches or scripts, another SYSDIR).
build_stamp() {
	printf 'sysdir %s %s\n' "$SYSDIR" "$(os_version_of "$SYSDIR")"
	printf 'drmkmoddir %s\n' "$DRMKMODDIR"
	printf 'tree %s\n' "$(cd "$repo" && find SOURCES patches scripts src lib rc.d man -type f | sort | xargs sha256 -q | sha256 -q)"
}

do_install() {
	setup
	_ok=1
	for _ko in $(module_list); do
		[ -f "$TREE/$_ko" ] || _ok=0
	done
	[ -f "$LIBOBJ/info/nvrm-info" ] || _ok=0
	if [ "$_ok" = 1 ] && [ -f "$WORK/build/stamp" ] && [ "$(build_stamp)" = "$(cat "$WORK/build/stamp")" ]; then
		note "install: the build is current"
	else
		do_build
	fi
	stage
	_n=$(stage_files "$STAGE" | wc -l | tr -d ' ')
	note "install: $_n files: modules to $DESTDIR/boot/modules, the rest under $DESTDIR$PREFIX"
	ask "Install them as root (owner root:wheel)?" || die "not installed"
	if [ -n "$DESTDIR" ] && [ "$(id -u)" != 0 ]; then
		install_stage "$STAGE" "$DESTDIR" "$PREFIX" user
	else
		as_root sh "$repo/scripts/make.sh" _install-stage "$STAGE" "$DESTDIR" "$PREFIX"
	fi
	note "install: done; manifest $DESTDIR$PREFIX/share/$name/installed.manifest"
}

# install_stage STAGE DESTDIR PREFIX [user]
# Copy STAGE onto DESTDIR.  As root the stage (owned by the building user)
# is first copied with tar(1), which never follows a symbolic link, into a
# private directory root creates, and everything is read from that copy, so
# the user cannot swap a file between the checks and the copy.  A file is
# replaced only when the previous manifest lists it AND it still holds what
# that install wrote.  The manifest is written before the copy as the union
# of the previous one and this stage (an interrupted install can be rerun
# and deinstalled), and rewritten at the end from the files on disk; files
# of the previous install that this stage no longer has are removed when
# they are still ours.  With "user" (a non-root DESTDIR run) the files keep
# this user as owner.
install_stage() {
	_src=$1
	_d=$2
	_pfx=$3
	_own="-o root -g wheel"
	[ "${4:-}" = user ] && _own=
	_mdir=$_pfx/share/$name
	_man=$_d$_mdir/installed.manifest
	if [ -z "${4:-}" ] && [ -n "$_d" ]; then
		[ "$(stat -f '%u' "$_d")" = 0 ] || die "refusing DESTDIR $_d as root: not owned by root"
	fi
	_newdirs=
	_dir=$_mdir
	while [ "$_dir" != / ] && [ ! -d "$_d$_dir" ]; do
		_newdirs="$_dir
$_newdirs"
		_dir=$(dirname -- "$_dir")
	done
	mkdir -p -- "$_d$_mdir"
	_w=$(mktemp -d "$_d$_mdir/.install.XXXXXX") || die "cannot create a private directory in $_d$_mdir"
	trap 'rm -rf -- "$_w"' EXIT
	_s=$_w/stage
	mkdir -- "$_s"
	tar -C "$_src" -cf - . | tar -C "$_s" -xpf - || die "cannot copy the stage"
	stage_files "$_s" > "$_w/list"
	_prev=$_w/prev
	: > "$_prev"
	if [ -f "$_man" ]; then
		[ ! -L "$_man" ] || die "refusing $_man: symbolic link"
		cp -- "$_man" "$_prev"
	fi
	while read -r _f; do
		path_ok "$_f" || die "refusing staged path $_f"
		if [ -e "$_d$_f" ] || [ -L "$_d$_f" ]; then
			_line=$(awk -v p="$_f" '$1 == p' "$_prev")
			[ -n "$_line" ] || die "refusing to replace $_d$_f: make install did not write it"
			# pending: an interrupted install of ours was writing it
			[ "$(printf '%s\n' "$_line" | awk '{ print $3 }')" = pending ] && continue
			still_ours "$_d" "$_line" || die "refusing to replace $_d$_f: it changed since make install wrote it"
		fi
	done < "$_w/list"
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
	# Pending manifest: the previous lines plus every path about to be written.
	{
		cat "$_prev"
		awk '{ print $0 " 0 pending -" }' "$_w/list"
		printf '%s\n' "$_newdirs" | awk 'NF { print $0 " dir" }'
	} | awk '!seen[$1 " " ($2 == "dir")]++' > "$_man.new"
	mv -f -- "$_man.new" "$_man"
	while read -r _f; do
		if [ -L "$_s$_f" ]; then
			ln -sfh "$(readlink "$_s$_f")" "$_d$_f"
		else
			# shellcheck disable=SC2086
			install $_own -m "$(stat -f '%Lp' "$_s$_f")" -- "$_s$_f" "$_d$_f.new"
			mv -f -- "$_d$_f.new" "$_d$_f"
		fi
	done < "$_w/list"
	# Files of the previous install that this stage no longer has.
	awk '$2 != "dir"' "$_prev" | while read -r _line; do
		set -- $_line
		[ "$1" = "$_mdir/installed.manifest" ] && continue
		grep -qxF -- "$1" "$_w/list" && continue
		path_ok "$1" || continue
		if [ "$3" = pending ]; then
			rm -f -- "$_d$1" "$_d$1.new"
		elif still_ours "$_d" "$_line"; then
			rm -f -- "$_d$1"
		fi
	done
	{
		while read -r _f; do
			manifest_line "$_d" "$_f"
		done < "$_w/list"
		printf '%s 444 %s -\n' "$_mdir/installed.manifest" "$(stat -f '%Su:%Sg' "$_d$_mdir")"
		awk '$2 == "dir"' "$_prev"
		printf '%s\n' "$_newdirs" | awk 'NF { print $0 " dir" }'
	} | awk '!seen[$0]++' > "$_man.new"
	mv -f -- "$_man.new" "$_man"
	chmod 444 "$_man"
	rm -rf -- "$_w"
	trap - EXIT
	# kldxref refreshes linker.hints; in a DESTDIR its failure (for example
	# a staging tree without other modules) is reported, not fatal.
	if [ -z "$_d" ]; then
		kldxref /boot/modules
	else
		kldxref "$_d/boot/modules" || note "kldxref $_d/boot/modules failed (DESTDIR staging)"
	fi
}

# kernel module names (as kldstat -n takes them) of every module we install
module_names() {
	module_list | while read -r _ko; do
		basename "$_ko" .ko
	done
}

do_deinstall() {
	setup
	_man=$DESTDIR$PREFIX/share/$name/installed.manifest
	[ -f "$_man" ] || { note "deinstall: nothing installed (no $_man)"; return 0; }
	if [ -z "$DESTDIR" ]; then
		for _k in $(module_names); do
			if kldstat -q -n "$_k" 2>/dev/null; then
				die "deinstall: $_k is loaded; unload it first"
			fi
		done
	fi
	note "deinstall: removing the $(awk '$2 != "dir"' "$_man" | wc -l | tr -d ' ') files listed in $_man"
	ask "Remove them as root?" || die "not removed"
	if [ -n "$DESTDIR" ] && [ "$(id -u)" != 0 ]; then
		deinstall_manifest "$DESTDIR" "$PREFIX"
	else
		as_root sh "$repo/scripts/make.sh" _deinstall "$DESTDIR" "$PREFIX"
	fi
	note "deinstall: done"
}

# deinstall_manifest DESTDIR PREFIX: remove each manifest path that still
# holds what install wrote (a changed file is kept and reported), then the
# directories install created, deepest first.
deinstall_manifest() {
	_d=$1
	_pfx=$2
	_mdir=$_pfx/share/$name
	_man=$_d$_mdir/installed.manifest
	[ ! -L "$_man" ] || die "refusing $_man: symbolic link"
	_lines=$(cat "$_man")
	_dirs=$(printf '%s\n' "$_lines" | awk '$2 == "dir" { print $1 }' | sort -r)
	printf '%s\n' "$_lines" | awk '$2 != "dir"' | while read -r _line; do
		set -- $_line
		path_ok "$1" || { note "deinstall: refusing manifest path $1"; continue; }
		[ "$1" = "$_mdir/installed.manifest" ] && continue
		if [ ! -e "$_d$1" ] && [ ! -L "$_d$1" ]; then
			[ "$3" != pending ] || rm -f -- "$_d$1.new"
			continue
		fi
		if [ "$3" = pending ] || still_ours "$_d" "$_line"; then
			# a pending line is a file an interrupted install was writing
			rm -f -- "$_d$1"
			[ "$3" != pending ] || rm -f -- "$_d$1.new"
		else
			note "deinstall: kept $_d$1 (changed since make install wrote it)"
		fi
	done
	rm -f -- "$_man"
	printf '%s\n' "$_dirs" | while read -r _dir; do
		[ -n "$_dir" ] || continue
		path_ok "$_dir" || continue
		rmdir -- "$_d$_dir" 2>/dev/null || note "deinstall: kept $_d$_dir (not empty)"
	done
	if [ -z "$_d" ]; then
		kldxref /boot/modules
	elif [ -d "$_d/boot/modules" ]; then
		kldxref "$_d/boot/modules" || note "kldxref $_d/boot/modules failed (DESTDIR staging)"
	fi
}

do_clean() {
	setup
	rm -rf -- "$WORK/build" "$WORK/stage" "$WORK/stage.manifest"
	note "clean: removed $WORK/build and $WORK/stage (downloads kept)"
}

do_test_install() {
	setup
	[ -f "$repo/tests/install-e2e/run.sh" ] || die "test-install: tests/install-e2e/run.sh is not in this checkout yet"
	sh "$repo/tests/install-e2e/run.sh" --repo "$repo" --work "$WORK"
}

target=${1:-}
case $target in
preflight)
	# --json: the same contract as make preflight JSON=1, without the
	# "*** Error code 1" lines bmake adds to stdout when something is missing
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
	[ "$(id -u)" = 0 ] || die "_deinstall runs as root"
	deinstall_manifest "$2" "$3"
	;;
_module-list) module_list ;;
_build-stamp)
	setup
	build_stamp
	;;
*)
	printf 'usage: sh scripts/make.sh preflight|install-prereqs|configure|build|test|install|deinstall|test-install|clean\n' >&2
	exit 2
	;;
esac

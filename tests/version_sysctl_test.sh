#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
# User-space tests of the real NVIDIA version sysctl source and its fake KPI.
# Run: sh tests/version_sysctl_test.sh

set -u
ulimit -c 0
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL

TESTSDIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH= cd -- "$TESTSDIR/.." && pwd)
WORK=${GB10_WORK:-$HOME/work/gb10}
mkdir -p "$WORK/tmp"
TESTROOT=$(mktemp -d "$WORK/tmp/version-sysctl-test.XXXXXXXX") || exit 1
cleanup() { rm -rf "$TESTROOT"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

SOURCE=$REPO/src/gb10-version/nv_version_sysctl.c
FAKE=$TESTSDIR/version_sysctl
TESTC=$FAKE/version_sysctl_test.c
VERSION_HEADER=$REPO/lib/libnvrm/include/nvrm
CC=${CC:-cc}
FAILED=0
KILLED=0

# Compile SOURCE (strict warnings, as the kernel build treats them) and the
# test main for one variant: "gpu" (nvidia.ko) or "modeset" (-DNV_VERSION_SYSCTL_
# MODESET, the nvidia-modeset.ko configuration).  The test main's helpers that
# one variant does not use are allowed to be unused; the source is not.
# Returns 2 when a compile fails, else the test's own status.
build_variant() {
	_variant=$1
	_source=$2
	_output=$3
	_defs=
	_relax=
	if [ "$_variant" = modeset ]; then
		_defs=-DNV_VERSION_SYSCTL_MODESET
		_relax='-Wno-unused-function -Wno-unused-variable'
	fi
	# shellcheck disable=SC2086
	if ! "$CC" -std=c99 -Wall -Werror $_defs \
	    -I"$FAKE" -I"$REPO/src/gb10-version" -I"$VERSION_HEADER" \
	    -c "$_source" -o "$_output.src.o"; then
		return 2
	fi
	# shellcheck disable=SC2086
	if ! "$CC" -std=gnu99 -Wall -Werror $_defs $_relax \
	    -I"$FAKE" -I"$REPO/src/gb10-version" -I"$VERSION_HEADER" \
	    -c "$TESTC" -o "$_output.test.o"; then
		return 2
	fi
	if ! "$CC" "$_output.src.o" "$_output.test.o" -o "$_output"; then
		return 2
	fi
	"$_output"
}

build_and_run() {
	_source=$1
	_output=$2
	build_variant gpu "$_source" "$_output" || return $?
	build_variant modeset "$_source" "$_output-modeset" || return $?
}

printf '%s\n' '--- normal source ---'
if ! build_and_run "$SOURCE" "$TESTROOT/pass"; then
	echo 'version_sysctl_test.sh: FAIL (normal source)' >&2
	exit 1
fi

# Each module carries only its own entry points: the modeset functions must not
# be linked into nvidia.ko, nor the GPU functions into nvidia-modeset.ko.
has_symbol() {
	nm "$1" | grep -q " [TtDdBbRr] $2\$"
}
if has_symbol "$TESTROOT/pass.src.o" nv_version_sysctl_gpu_init \
    && has_symbol "$TESTROOT/pass.src.o" nv_version_sysctl_init \
    && ! has_symbol "$TESTROOT/pass.src.o" nv_version_sysctl_modeset_init \
    && ! has_symbol "$TESTROOT/pass.src.o" nv_version_sysctl_modeset_exit; then
	echo 'ok   nvidia.ko variant: GPU entry points only'
else
	echo 'FAIL nvidia.ko variant defines the wrong entry points' >&2
	FAILED=$((FAILED + 1))
fi
if has_symbol "$TESTROOT/pass-modeset.src.o" nv_version_sysctl_modeset_init \
    && has_symbol "$TESTROOT/pass-modeset.src.o" nv_version_sysctl_modeset_exit \
    && ! nm "$TESTROOT/pass-modeset.src.o" | grep -q 'nv_version_sysctl_gpu'; then
	echo 'ok   nvidia-modeset.ko variant: modeset entry points only'
else
	echo 'FAIL nvidia-modeset.ko variant defines the wrong entry points' >&2
	FAILED=$((FAILED + 1))
fi

# Documentation facts the interface promises (man/nvidia.4 is the reference).
MAN=$REPO/man/nvidia.4
check_man() {
	if grep -q -e "$1" "$MAN"; then
		printf 'ok   nvidia(4): %s\n' "$2"
	else
		printf 'FAIL nvidia(4) does not say: %s\n' "$2" >&2
		FAILED=$((FAILED + 1))
	fi
}
check_man 'fetched from the resource manager anew' \
    'each read fetches the value anew'
check_man 'again after the parts' 'retry recipe'
check_man 'same unit number' 'hw.nvidia.gpus.N and dev.nvidia.N are one unit'
check_man 'EIO' 'a failed uuid read gives EIO and a next step'
check_man 'at least four' 'pci_bus_id domain width'
if sed -n '/^.Sh SYSCTL VARIABLES/,/^.Sh LOADER TUNABLES/p' "$MAN" | grep -q -E 'existing|unchanged|siblings'; then
	echo 'FAIL nvidia(4) describes the change ("existing", "unchanged", "siblings")' >&2
	FAILED=$((FAILED + 1))
fi

run_mutant() {
	_name=$1
	_expression=$2
	_mode=${3:-assert}
	_source=$TESTROOT/$_name.c
	_output=$TESTROOT/$_name
	_log=$TESTROOT/$_name.log

	sed -e "$_expression" "$SOURCE" > "$_source"
	if cmp -s "$SOURCE" "$_source"; then
		echo "FAIL mutant $_name: substitution did not change the source" >&2
		FAILED=$((FAILED + 1))
		return
	fi
	_rc=0
	build_and_run "$_source" "$_output" > "$_log" 2>&1 || _rc=$?
	if [ "$_rc" -eq 0 ]; then
		echo "FAIL mutant $_name survived" >&2
		FAILED=$((FAILED + 1))
		return
	fi
	if [ "$_mode" = build ]; then
		# a build-mode mutant must be stopped by the compiler
		if [ "$_rc" -ne 2 ] || ! grep -q "$4" "$_log"; then
			echo "FAIL mutant $_name was not stopped by the compiler" >&2
			sed -n '1,20p' "$_log" >&2
			FAILED=$((FAILED + 1))
			return
		fi
	elif ! grep -q '^version_sysctl_test: FAIL ' "$_log"; then
		echo "FAIL mutant $_name did not fail by assertion" >&2
		sed -n '1,20p' "$_log" >&2
		FAILED=$((FAILED + 1))
		return
	fi
	KILLED=$((KILLED + 1))
	printf 'ok   mutant killed: %s\n' "$_name"
	sed -n '/^FAIL /p' "$_log" | sed -n '1,3p'
}

run_mutant vbios-base-10 \
	's/vbios_version, 16)/vbios_version, 10)/'
run_mutant available-forced \
	's/value = v\.available;/value = 1;/'
run_mutant pci-domain-width \
	's/%04x:%02x:%02x\.%x/%02x:%02x:%02x.%x/'
run_mutant pci-buffer-small \
	's/char pci_bus_id\[NV_PCI_BUS_ID_LEN\]/char pci_bus_id[16]/'
run_mutant vbios-uninitialized \
	's/char vbios_version\[NV_VBIOS_VERSION_LEN + 1\] = { };/char vbios_version[NV_VBIOS_VERSION_LEN + 1];/'
run_mutant suffix-registered-as-int \
	's/CTLTYPE_STRING | CTLFLAG_RD | CTLFLAG_DYN, nv,$/CTLTYPE_INT | CTLFLAG_RD | CTLFLAG_DYN, nv,/'
run_mutant string-format-wrong \
	's/handler, "A", table\[i\].descr/handler, "I", table[i].descr/'
run_mutant einval-removed \
	's/if (arg2 < 0 || arg2 >= NVRM_VERSION_MAX_PARTS)/if (0)/'
run_mutant uuid-eio-lost \
	's/return (EIO);/return (0);/'
run_mutant modeset-null-node-unchecked \
	's/if (parent == NULL) {/if (0) {/'
run_mutant init-shared-state \
	's/^	nv_version_sysctl_parse_banner(banner, state);/	static struct nv_version_sysctl_state shared;\
	state = \&shared;\
	nv_version_sysctl_parse_banner(banner, state);/'
run_mutant modeset-leaks-gpu-type \
	'/^#endif \/\* !NV_VERSION_SYSCTL_MODESET \*\//a\
extern nv_state_t *nv_version_sysctl_bad;' \
	build "unknown type name 'nv_state_t'"

if [ "$FAILED" -ne 0 ]; then
	echo "version_sysctl_test.sh: FAIL ($FAILED mutation failures)" >&2
	exit 1
fi
echo "version_sysctl_test.sh: PASS ($KILLED mutants killed)"

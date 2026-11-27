#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
# User-space tests of the real architecture floor source (Track #2457)
# against a fake kernel interface, in the default build, an amd64 build and
# an arm64 build of the GA100 firmware condition, plus mutants of the real
# source.
# Run: sh tests/arch_floor_test.sh

set -u
ulimit -c 0
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL

TESTSDIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH= cd -- "$TESTSDIR/.." && pwd)
WORK=${GB10_WORK:-$REPO/work}
mkdir -p "$WORK/tmp"
TESTROOT=$(mktemp -d "$WORK/tmp/arch-floor-test.XXXXXXXX") || exit 1
cleanup() { rm -rf "$TESTROOT"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

SRCDIR=${ARCH_FLOOR_SRC:-$REPO/src/gb10-archfloor}
FAKE=$TESTSDIR/arch_floor
TESTC=$FAKE/arch_floor_test.c
FWPATCH=$REPO/patches/patch-zz-nvidia_fw_depend_pci.c
CC=${CC:-cc}
FAILED=0
KILLED=0

# build_variant SRCDIR MACHINE OUTPUT: compile the real source (strict
# warnings, as the kernel build treats them) and the test main, link, run.
# MACHINE is the machine architecture of the build under test; empty means
# the default of <machine/param.h>, which the fake machine/param.h gives.
# Returns 2 when a compile fails, else the test's own status.
build_variant() {
	_dir=$1
	_machine=$2
	_output=$3
	set -- -std=c11 -Wall -Werror -D_KERNEL
	if [ -n "$_machine" ]; then
		set -- "$@" "-DNV_ARCH_FLOOR_MACHINE=\"$_machine\""
	fi
	set -- "$@" -I"$FAKE" -I"$_dir"
	if ! "$CC" "$@" -c "$_dir/nv_arch_floor.c" -o "$_output.src.o"; then
		return 2
	fi
	if ! "$CC" "$@" -c "$TESTC" -o "$_output.test.o"; then
		return 2
	fi
	if ! "$CC" "$_output.src.o" "$_output.test.o" -o "$_output"; then
		return 2
	fi
	"$_output"
}

build_and_run() {
	build_variant "$1" "" "$2-default" || return $?
	build_variant "$1" amd64 "$2-amd64" || return $?
	build_variant "$1" aarch64 "$2-arm64" || return $?
}

printf '%s\n' '--- normal source ---'
if ! build_and_run "$SRCDIR" "$TESTROOT/pass"; then
	echo 'arch_floor_test.sh: FAIL (normal source)' >&2
	exit 1
fi

has_symbol() {
	nm "$1" | grep -q " [TtDdBbRr] $2\$"
}
for _sym in nv_arch_floor_probe nv_arch_floor_decide nv_arch_floor_format \
    nv_arch_floor_keyword nv_arch_floor_sysctl_init; do
	if has_symbol "$TESTROOT/pass-arm64.src.o" "$_sym"; then
		printf 'ok   defines %s\n' "$_sym"
	else
		printf 'FAIL the source does not define %s\n' "$_sym" >&2
		FAILED=$((FAILED + 1))
	fi
done

# Documentation facts the interface promises (man/nvidia.4 is the reference):
# the four sysctls, every verdict keyword and every message the source logs.
MAN=$REPO/man/nvidia.4
check_man() {
	if grep -q -F -e "$1" "$MAN"; then
		printf 'ok   nvidia(4): %s\n' "$2"
	else
		printf 'FAIL nvidia(4) does not say: %s\n' "$2" >&2
		FAILED=$((FAILED + 1))
	fi
}
for _v in hw.nvidia.min_architecture hw.nvidia.min_architecture_name \
    hw.nvidia.refused_count hw.nvidia.refused; do
	check_man "$_v" "the sysctl $_v"
done
for _k in below-floor unknown no-firmware not-responding unreadable; do
	check_man ".Qq $_k" "the verdict keyword $_k"
done
check_man 'is Ar architecture ; this driver supports GA10x (RTX 30) and later' 'the architecture message'
check_man 'is architecture 0x Ns Ar NN , older than GA10x; this driver supports GA10x (RTX 30) and later' 'the unnamed older message'
check_man 'reports unknown architecture 0x Ns Ar NN ; this driver supports GA10x (RTX 30) and later' 'the unknown architecture message'
check_man 'TU10x, GV11x, GV10x, GP10x, GM20x and GM10x' 'the names of the older architectures'
check_man 'which needs the gsp_tu10x firmware; only the amd64 build carries it' 'the missing firmware message'
check_man 'only the amd64 build carries it' 'the build that carries the image'
check_man 'Use an amd64 machine for that card' 'the action for a missing image'
check_man 'Reseat or power-cycle the card, and check its power connectors' 'the action for a card that does not respond'
check_man '-r for another owner of the memory range' 'the action for an unreadable card'
check_man 'does not respond (PMC_BOOT_0 and PMC_BOOT_42 read 0xffffffff); not attaching' 'the not responding message'
check_man 'cannot read PMC_BOOT_42 (BAR0 not available); not attaching' 'the unreadable message'
check_man 'The driver attaches to GA10x (RTX 30) and later GPUs (the architecture named by' 'the architecture the driver attaches to'
check_man 'kldunload' 'the idle nvidia.ko on a machine with only refused GPUs'
if sed -n '/^.Sh SYSCTL VARIABLES/,/^.Sh LOADER TUNABLES/p' "$MAN" | grep -q -E 'existing|unchanged|siblings'; then
	echo 'FAIL nvidia(4) describes the change ("existing", "unchanged", "siblings")' >&2
	FAILED=$((FAILED + 1))
fi

# The row tables are read by make preflight with awk: one row per line.  The
# third field is the chip key: the prefix of the chip and its two digits.
for _row in 0x11 0x12 0x13 0x14 0x15 0x16 0x17 0x18 0x19 0x1a 0x1b; do
	if [ "$(grep -c "^	ROW($_row, \"[A-Za-z0-9]*\", \"[A-Z][A-Z][0-9][0-9]\")" \
	    "$SRCDIR/nv_arch_floor.h")" -eq 1 ]; then
		printf 'ok   table row %s is on one line\n' "$_row"
	else
		printf 'FAIL table row %s is not on one line\n' "$_row" >&2
		FAILED=$((FAILED + 1))
	fi
done
if [ "$(grep -c '^	ROW(0x17, 0x0, "GA100", "gsp_tu10x", "amd64")' \
    "$SRCDIR/nv_arch_floor.h")" -eq 1 ]; then
	echo 'ok   firmware row is on one line'
else
	echo 'FAIL firmware row is not on one line' >&2
	FAILED=$((FAILED + 1))
fi

# The docs name every family the code recognises below the floor: a family
# the table has and the manual does not name is a family a reader cannot
# look up.
_floorhex=$(sed -n 's/^#define NV_ARCH_FLOOR_MIN_ARCHITECTURE[ 	]*\(0x[0-9a-fA-F]*\).*/\1/p' \
    "$SRCDIR/nv_arch_floor.h")
_floordec=$(printf '%d' "$_floorhex")
_below=$(sed -n 's/^	ROW(\(0x[0-9a-fA-F]*\), "\([^"]*\)".*/\1 \2/p' \
    "$SRCDIR/nv_arch_floor.h" | while read -r _v _n; do
	if [ "$(printf '%d' "$_v")" -lt "$_floordec" ]; then
		printf '%s\n' "$_n"
	fi
done)
for _f in $_below; do
	if grep -q "$_f" "$MAN"; then
		printf 'ok   nvidia(4) names the family below the floor: %s\n' "$_f"
	else
		echo "FAIL nvidia(4) does not name the family below the floor: $_f" >&2
		FAILED=$((FAILED + 1))
	fi
	if grep -q "$_f" "$REPO/README.md"; then
		printf 'ok   the README names the family below the floor: %s\n' "$_f"
	else
		echo "FAIL the README does not name the family below the floor: $_f" >&2
		FAILED=$((FAILED + 1))
	fi
done

# the legend: every family the code knows is in the legend of the README and
# of nvidia(4), so that a family code a reader meets can be looked up
_all=$(sed -n 's/^	ROW(0x[0-9a-fA-F]*, "\([^"]*\)".*/\1/p' \
    "$SRCDIR/nv_arch_floor.h" | sort -u)
for _f in $_all; do
	if grep -q "$_f" "$MAN"; then
		printf 'ok   nvidia(4) names the family: %s\n' "$_f"
	else
		echo "FAIL nvidia(4) does not name the family: $_f" >&2
		FAILED=$((FAILED + 1))
	fi
	if grep -q "$_f" "$REPO/README.md"; then
		printf 'ok   the README names the family: %s\n' "$_f"
	else
		echo "FAIL the README does not name the family: $_f" >&2
		FAILED=$((FAILED + 1))
	fi
done

# the manual build prerequisites name the image the GA100 needs: the build
# does not carry it, so it refuses a GA100
if grep -q 'GA100 requires `gsp_tu10x`' "$REPO/docs/MANUAL-BUILD.md" &&
    ! grep -q 'TU10x needs `gsp_tu10x`' "$REPO/docs/MANUAL-BUILD.md"; then
	printf 'ok   the manual build prerequisites name the GA100 image\n'
else
	echo 'FAIL the manual build prerequisites do not name the GA100 image' >&2
	FAILED=$((FAILED + 1))
fi

# The image's rule lives in the row: the machines whose build carries it.
# The MODULE_DEPEND that makes the image's firmware module a dependency of
# nvidia.ko carries the same condition, and the two must agree.
row_machines() {
	sed -n 's/^	ROW(0x17, 0x0, "GA100", "gsp_tu10x", "\([^"]*\)").*/\1/p' "$1"
}
patch_machines() {
	awk '/MODULE_DEPEND\(nvidia, nvidia_gsp_tu10x_fw_fw/ { print last; exit }
	     /#if/ { last = $0 }' "$1" |
	    sed -n 's/.*defined(__\([a-z0-9_]*\)__).*/\1/p'
}
check_fw_rule() {
	_r=$(row_machines "$1")
	_p=$(patch_machines "$2")
	[ "$_r" = amd64 ] && [ "$_p" = amd64 ]
}
if check_fw_rule "$SRCDIR/nv_arch_floor.h" "$FWPATCH"; then
	printf 'ok   the GA100 image: the row says amd64 and the patch guards it on amd64\n'
else
	echo "FAIL the GA100 image: the row says '$(row_machines "$SRCDIR/nv_arch_floor.h")' and the patch guards it on '$(patch_machines "$FWPATCH")'" >&2
	FAILED=$((FAILED + 1))
fi

# run_mutant NAME FILE SED-EXPRESSION: apply the expression to FILE (one of
# the two source files) in a private copy of the source directory.  A mutant
# must still compile and be killed by an assertion of the test.
run_mutant() {
	_name=$1
	_file=$2
	_expression=$3
	_dir=$TESTROOT/mutant-$_name
	_log=$TESTROOT/$_name.log

	mkdir -p "$_dir"
	cp "$SRCDIR/nv_arch_floor.c" "$SRCDIR/nv_arch_floor.h" "$_dir/"
	sed -e "$_expression" "$SRCDIR/$_file" > "$_dir/$_file"
	if cmp -s "$SRCDIR/$_file" "$_dir/$_file"; then
		echo "FAIL mutant $_name: substitution did not change $_file" >&2
		FAILED=$((FAILED + 1))
		return
	fi
	_rc=0
	build_and_run "$_dir" "$_dir/out" > "$_log" 2>&1 || _rc=$?
	if [ "$_rc" -eq 0 ]; then
		echo "FAIL mutant $_name survived" >&2
		FAILED=$((FAILED + 1))
		return
	fi
	if [ "$_rc" -eq 2 ] || ! grep -q '^FAIL ' "$_log"; then
		echo "FAIL mutant $_name did not fail by assertion" >&2
		sed -n '1,20p' "$_log" >&2
		FAILED=$((FAILED + 1))
		return
	fi
	KILLED=$((KILLED + 1))
	printf 'ok   mutant killed: %s\n' "$_name"
	sed -n '/^FAIL /p' "$_log" | sed -n '1,2p'
}

run_mutant floor-0x16 nv_arch_floor.h \
	's/^\(#define NV_ARCH_FLOOR_MIN_ARCHITECTURE[ 	]*\)0x17/\10x16/'
run_mutant floor-0x13 nv_arch_floor.h \
	's/^\(#define NV_ARCH_FLOOR_MIN_ARCHITECTURE[ 	]*\)0x17/\10x13/'
run_mutant floor-exclusive nv_arch_floor.c \
	's/architecture < NV_ARCH_FLOOR_MIN_ARCHITECTURE/architecture <= NV_ARCH_FLOOR_MIN_ARCHITECTURE/'
run_mutant row-ad10x-dropped nv_arch_floor.h '/^	ROW(0x19, /d'
run_mutant row-gb20x-dropped nv_arch_floor.h '/^	ROW(0x1b, /d'
run_mutant row-gb10x-dropped nv_arch_floor.h '/^	ROW(0x1a, /d'
run_mutant row-ga10x-dropped nv_arch_floor.h '/^	ROW(0x17, "GA10x"/d'
run_mutant firmware-row-dropped nv_arch_floor.h '/^	ROW(0x17, 0x0, "GA100"/d'
run_mutant vendor-guard-removed nv_arch_floor.c \
	's/if (pci_get_vendor(dev) != NV_ARCH_FLOOR_NVIDIA_VENDOR)/if (0)/'
run_mutant boot42-offset nv_arch_floor.h \
	's/^\(#define NV_ARCH_FLOOR_PMC_BOOT_42[ 	]*\)0xA00/\10x0/'
run_mutant arch-shift nv_arch_floor.h \
	's/^\(#define NV_ARCH_FLOOR_ARCH_SHIFT[ 	]*\)24/\120/'
run_mutant impl-shift nv_arch_floor.h \
	's/^\(#define NV_ARCH_FLOOR_IMPL_SHIFT[ 	]*\)20/\116/'
run_mutant resource-not-released nv_arch_floor.c \
	'/bus_release_resource(dev, SYS_RES_MEMORY, rid, res);/d'
run_mutant mapping-not-unmapped nv_arch_floor.c '/pmap_unmapdev(va, PAGE_SIZE);/d'
run_mutant map-length nv_arch_floor.c \
	's/pmap_mapdev(rman_get_start(res), PAGE_SIZE)/pmap_mapdev(rman_get_start(res), 2 * PAGE_SIZE)/'
run_mutant decode-not-restored nv_arch_floor.c \
	's/pci_disable_io(dev, SYS_RES_MEMORY);/(void)command;/'
run_mutant decode-not-enabled nv_arch_floor.c \
	's/pci_enable_io(dev, SYS_RES_MEMORY);/(void)command;/'
run_mutant dedupe-removed nv_arch_floor.c \
	's/if (strcmp(nv_arch_floor_locations\[i\], location) == 0)/if (0)/'
run_mutant alloc-rf-active nv_arch_floor.c \
	's/SYS_RES_MEMORY, &rid, 0)/SYS_RES_MEMORY, \&rid, RF_ACTIVE)/'
run_mutant lock-removed nv_arch_floor.c '/mtx_lock(&nv_arch_floor_mtx);/d'
run_mutant overflow-not-counted nv_arch_floor.c \
	's/^		nv_arch_floor_refused_count++;//'
run_mutant keyword-wrong nv_arch_floor.c \
	's/"below-floor"/"below_floor"/'
run_mutant keyword-bound-pointer nv_arch_floor.c \
	's|^#define NV_ARCH_FLOOR_KEYWORD_MAX.*$|#define NV_ARCH_FLOOR_KEYWORD_MAX (sizeof(nv_arch_floor_keywords[NV_ARCH_FLOOR_NOT_RESPONDING]))|'
run_mutant accept-count-not-down nv_arch_floor.c \
	's/if (nv_arch_floor_refused_count > 0)/if (0)/'
run_mutant accept-entry-kept nv_arch_floor.c \
	's/^\t\tnv_arch_floor_nrefused--;$/\t\t;/'
run_mutant verdict-not-replaced nv_arch_floor.c \
	's/changed = 1;/changed = 0;/'
run_mutant location-not-decimal nv_arch_floor.c \
	's/"pci%u:%u:%u:%u"/"pci%02x:%02x:%02x.%x"/'
run_mutant log-not-against-parent nv_arch_floor.c \
	's/device_printf(pdev != NULL ? pdev : dev, "nvidia: %s\\n", line);/device_printf(dev, "%s\\n", line);/'

# The rule that carries the image has a plant for each side: the machine
# list of the row, and the condition in the patch.
PLANT=$TESTROOT/plant-fw
mkdir -p "$PLANT"
sed -e 's/^	ROW(0x17, 0x0, "GA100", "gsp_tu10x", "amd64")/	ROW(0x17, 0x0, "GA100", "gsp_tu10x", "amd64 aarch64")/' \
    "$SRCDIR/nv_arch_floor.h" > "$PLANT/row.h"
sed -e 's/#if defined(__amd64__)/#if defined(__aarch64__)/' "$FWPATCH" > "$PLANT/patch.c"
if check_fw_rule "$PLANT/row.h" "$FWPATCH"; then
	echo 'FAIL plant row-machines survived' >&2
	FAILED=$((FAILED + 1))
else
	KILLED=$((KILLED + 1))
	printf 'ok   plant killed: row-machines\n'
fi
if check_fw_rule "$SRCDIR/nv_arch_floor.h" "$PLANT/patch.c"; then
	echo 'FAIL plant patch-condition survived' >&2
	FAILED=$((FAILED + 1))
else
	KILLED=$((KILLED + 1))
	printf 'ok   plant killed: patch-condition\n'
fi

if [ "$FAILED" -ne 0 ]; then
	echo "arch_floor_test.sh: FAIL ($FAILED failures)" >&2
	exit 1
fi
echo "arch_floor_test.sh: PASS ($KILLED mutants killed)"

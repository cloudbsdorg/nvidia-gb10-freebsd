#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# memattr_policy_test.sh - userland policy test for
# src/gb10-memattr/gb10_memattr.h, the arm64 PCIe BAR memory-attribute
# policy header used by the patched nvidia_os.c (os_map_kernel_space) and
# nvidia_subr.c (nvidia_mmap_dev_single).
#
# The header is pure (no kernel includes), so this test compiles it into a
# small C program under an unpredictable mktemp(1) directory in
# ${GB10_WORK:-$HOME/work/gb10}/tmp and checks:
#   (a) every cell of the BAR policy table, both altra values:
#         request          BAR, not Altra  BAR, Altra
#         CACHED           DEVICE          DEVICE  (a BAR is never cacheable)
#         UNCACHED         DEVICE          DEVICE
#         DEFAULT (a BAR)  DEVICE          DEVICE
#         WRITECOMBINED    NORMAL_NC       DEVICE
#   (b) unknown caching values (3, 5=WRITEBACK, 7=UNCACHED_WEAK, 99) ->
#       GB10_ATTR_INVALID, so callers error out as they do today;
#   (c) gb10_mcfg_is_altra() for the ACPI MCFG header identifications:
#       Ampere/"Altra   " yes, Ampere/"AltraMax" yes, "Ampere"/"AmpOne  "
#       no, "NVIDIA"/"GB10    " no, "ARMLTD"/"ARMN1SDP" no, all-zero no;
#   (d) the gb10_range_action() choice table, driven by the caller's
#       per-page predicate (kernel side: vm_phys_paddr_to_vm_page() !=
#       NULL): every page managed system RAM -> system-memory policy;
#       no managed RAM page -> BAR policy; a range mixing RAM and
#       non-RAM -> refuse the mapping (a BAR attribute on a RAM page is
#       the Track #1908 hazard);
#   (e) the gb10_ram_memattr() system-RAM policy: CACHED/DEFAULT ->
#       WRITE_BACK, UNCACHED/WRITECOMBINED -> NORMAL_NC (never DEVICE on
#       RAM), anything else -> INVALID so os_map_kernel_space() keeps
#       rejecting the modes it rejects on x86 (5=WRITEBACK,
#       7=UNCACHED_WEAK); nvidia_subr.c's RAM path keeps using its own
#       _convert_caching_to_attr();
#   (f) gb10_range_class(), the pure two-count classifier the kernel-side
#       walkers feed (ram_pages = pages whose vm_phys_paddr_to_vm_page()
#       is non-NULL, pages = PAGE_SIZE steps walked): ram_pages == 0 ->
#       GB10_RANGE_BAR, ram_pages == pages -> GB10_RANGE_RAM, anything
#       else -> GB10_RANGE_MIXED, including an over-count (ram_pages >
#       pages, a caller bug) so it fails closed to the refuse action;
#       pages == 0 (an empty range) -> GB10_RANGE_BAR, because an empty
#       range maps nothing as RAM and keeps the attribute such a request
#       gets today.
#
# Run: sh tests/memattr_policy_test.sh
# Exit 0 and a final PASS line when every check passes; exit 1 otherwise.

set -eu

PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL

TESTSDIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH= cd -- "$TESTSDIR/.." && pwd)
WORK=${GB10_WORK:-$HOME/work/gb10}
export TMPDIR="$WORK/tmp"
HEADER=$REPO/src/gb10-memattr/gb10_memattr.h

# Unpredictable scratch directory under $WORK/tmp (never /tmp), removed by
# the trap on every exit path.
mkdir -p "$WORK/tmp"
TESTROOT=$(mktemp -d "$WORK/tmp/memattr-policy-test.XXXXXXXX") || exit 1

PASSED=0
FAILED=0

# cleanup - remove exactly this run's scratch files on every exit path.
# Time:  O(files created by this test).
# Space: O(1).
cleanup() {
	rm -rf "$TESTROOT"
}
# EXIT cleans up; INT/TERM exit with the conventional 128+n status, which
# then runs the EXIT trap.
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

ok() {
	PASSED=$((PASSED + 1))
	printf 'ok   %s\n' "$1"
}

fail() {
	FAILED=$((FAILED + 1))
	printf 'FAIL %s\n' "$1"
}

if [ ! -f "$HEADER" ]; then
	fail "missing policy header: $HEADER"
	echo "memattr_policy_test: FAIL (passed $PASSED, failed $FAILED)"
	exit 1
fi

# The C program asserts every table cell and returns the number of failed
# checks as its exit status (0 = all passed).
# Time:  O(C) for C checks, each O(1) (the policy functions are constant
#        time; gb10_mcfg_is_altra compares at most 11 bytes).
# Space: O(1) beyond the fixed case table.
cat > "$TESTROOT/policy.c" <<'EOF'
#include <stdio.h>
#include <string.h>
#include "gb10_memattr.h"

static int failures;

static void
check(const char *what, int got, int want)
{
	if (got == want) {
		printf("ok   %s = %d\n", what, got);
	} else {
		printf("FAIL %s: got %d, want %d\n", what, got, want);
		failures++;
	}
}

int
main(void)
{
	static const char zero_oemid[6] = { 0 };
	static const char zero_tableid[8] = { 0 };

	/* (a) policy table, both altra values */
	check("CACHED/altra=0",        gb10_bar_memattr(GB10_CACHING_CACHED, 0),
	    GB10_ATTR_DEVICE);
	check("CACHED/altra=1",        gb10_bar_memattr(GB10_CACHING_CACHED, 1),
	    GB10_ATTR_DEVICE);
	check("UNCACHED/altra=0",      gb10_bar_memattr(GB10_CACHING_UNCACHED, 0),
	    GB10_ATTR_DEVICE);
	check("UNCACHED/altra=1",      gb10_bar_memattr(GB10_CACHING_UNCACHED, 1),
	    GB10_ATTR_DEVICE);
	check("DEFAULT/altra=0",       gb10_bar_memattr(GB10_CACHING_DEFAULT, 0),
	    GB10_ATTR_DEVICE);
	check("DEFAULT/altra=1",       gb10_bar_memattr(GB10_CACHING_DEFAULT, 1),
	    GB10_ATTR_DEVICE);
	check("WRITECOMBINED/altra=0", gb10_bar_memattr(GB10_CACHING_WRITECOMBINED, 0),
	    GB10_ATTR_NORMAL_NC);
	check("WRITECOMBINED/altra=1", gb10_bar_memattr(GB10_CACHING_WRITECOMBINED, 1),
	    GB10_ATTR_DEVICE);

	/* (b) unknown caching values are invalid for a BAR mapping */
	check("caching 3/altra=0",       gb10_bar_memattr(3u, 0),  GB10_ATTR_INVALID);
	check("WRITEBACK 5/altra=0",     gb10_bar_memattr(5u, 0),  GB10_ATTR_INVALID);
	check("UNCACHED_WEAK 7/altra=0", gb10_bar_memattr(7u, 0),  GB10_ATTR_INVALID);
	check("caching 99/altra=1",      gb10_bar_memattr(99u, 1), GB10_ATTR_INVALID);

	/* (c) MCFG OEM ID / OEM table ID identification */
	check("Ampere/Altra-padded", gb10_mcfg_is_altra("Ampere", "Altra   "), 1);
	check("Ampere/AltraMax",     gb10_mcfg_is_altra("Ampere", "AltraMax"), 1);
	check("Ampere/AmpOne",       gb10_mcfg_is_altra("Ampere", "AmpOne  "), 0);
	check("NVIDIA/GB10",         gb10_mcfg_is_altra("NVIDIA", "GB10    "), 0);
	check("ARMLTD/ARMN1SDP",     gb10_mcfg_is_altra("ARMLTD", "ARMN1SDP"), 0);
	check("all-zero header",     gb10_mcfg_is_altra(zero_oemid, zero_tableid), 0);

	/* (d) range choice table: which policy a mapping range takes */
	check("RAM range -> system policy", gb10_range_action(GB10_RANGE_RAM),
	    GB10_MAP_SYSTEM_POLICY);
	check("BAR range -> BAR policy",    gb10_range_action(GB10_RANGE_BAR),
	    GB10_MAP_BAR_POLICY);
	check("mixed range -> refuse",      gb10_range_action(GB10_RANGE_MIXED),
	    GB10_MAP_REFUSE);

	/* (e) system-RAM policy: never a BAR attribute on managed RAM */
	check("RAM CACHED",          gb10_ram_memattr(GB10_CACHING_CACHED),
	    GB10_ATTR_WRITE_BACK);
	check("RAM DEFAULT",         gb10_ram_memattr(GB10_CACHING_DEFAULT),
	    GB10_ATTR_WRITE_BACK);
	check("RAM UNCACHED",        gb10_ram_memattr(GB10_CACHING_UNCACHED),
	    GB10_ATTR_NORMAL_NC);
	check("RAM WRITECOMBINED",   gb10_ram_memattr(GB10_CACHING_WRITECOMBINED),
	    GB10_ATTR_NORMAL_NC);
	check("RAM WRITEBACK 5",     gb10_ram_memattr(5u),  GB10_ATTR_INVALID);
	check("RAM UNCACHED_WEAK 7", gb10_ram_memattr(7u),  GB10_ATTR_INVALID);
	check("RAM caching 99",      gb10_ram_memattr(99u), GB10_ATTR_INVALID);

	/* (f) gb10_range_class(): pure two-count range classification */
	check("range ram=0 of 16 -> BAR", gb10_range_class(0, 16),
	    GB10_RANGE_BAR);
	check("range ram=16 of 16 -> RAM", gb10_range_class(16, 16),
	    GB10_RANGE_RAM);
	check("range ram=4 of 16 -> MIXED", gb10_range_class(4, 16),
	    GB10_RANGE_MIXED);
	check("empty range ram=0 of 0 -> BAR", gb10_range_class(0, 0),
	    GB10_RANGE_BAR);
	check("range ram=15 of 16 -> MIXED", gb10_range_class(15, 16),
	    GB10_RANGE_MIXED);
	check("range ram=1 of 1 -> RAM", gb10_range_class(1, 1),
	    GB10_RANGE_RAM);
	check("over-count ram=20 of 16 -> MIXED (fail closed)",
	    gb10_range_class(20, 16), GB10_RANGE_MIXED);

	printf("checks failed: %d\n", failures);
	return (failures != 0);
}
EOF

crc=0
cc -std=c99 -Wall -Wextra -I "$REPO/src/gb10-memattr" \
	-o "$TESTROOT/policy" "$TESTROOT/policy.c" >"$TESTROOT/cc.log" 2>&1 || crc=$?
if [ "$crc" -ne 0 ]; then
	fail "compile of gb10_memattr.h into a userland program (cc rc=$crc):"
	cat "$TESTROOT/cc.log"
	echo "memattr_policy_test: FAIL (passed $PASSED, failed $FAILED)"
	exit 1
fi
ok "gb10_memattr.h compiles standalone as userland C99 with -Wall -Wextra"

prc=0
"$TESTROOT/policy" >"$TESTROOT/run.log" 2>&1 || prc=$?
cat "$TESTROOT/run.log"
if [ "$prc" -ne 0 ] || grep -q '^FAIL' "$TESTROOT/run.log"; then
	fail "policy checks: program rc=$prc"
	echo "memattr_policy_test: FAIL (passed $PASSED, failed $FAILED)"
	exit 1
fi
ok "all policy-table, invalid-caching and MCFG-identification checks"

echo "memattr_policy_test: PASS (passed $PASSED, failed $FAILED)"

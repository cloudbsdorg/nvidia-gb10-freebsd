/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-3-Clause
 *
 * gb10smmu_gpu_test - the rules the module of ours uses to recognise the
 * GPU it programs the SMMU of, run outside the kernel.
 *
 * The rules are in src/gb10-smmu/gb10smmu_gpu.h, the same header the
 * module builds; this test builds them with the module and says what they
 * must answer.
 *
 * Cases:
 *   (a) the GB10 GPU is the GB10 and nothing else
 *   (b) the requester ID of a PCI device is the PCI's own layout
 *
 * Run: sh tests/gb10smmu_test.sh (this file is built and run by it)
 */
#include <stdio.h>

#include "gb10smmu_gpu.h"

static int passed;
static int failed;

static void
ok(const char *what)
{
	passed++;
	printf("ok   %s\n", what);
}

static void
bad(const char *what, const char *why)
{
	failed++;
	printf("FAIL %s: %s\n", what, why);
}

#define	CHECK(cond, what)						\
	do {								\
		if (cond)						\
			ok(what);					\
		else							\
			bad(what, #cond);				\
	} while (0)

/*
 * case_is_gb10 - (a) the GB10 GPU is the GB10 and nothing else.
 *
 * The module programs the SMMU in front of that GPU and of no other
 * device: a device of another vendor, or of NVIDIA but another model, is
 * not the GPU.
 */
static void
case_is_gb10(void)
{
	CHECK(gb10smmu_is_gb10(0x10de, 0x2e12),
	    "(a) the GB10 is recognised");
	CHECK(!gb10smmu_is_gb10(0x10de, 0x2d04),
	    "(a) another NVIDIA device is not the GB10");
	CHECK(!gb10smmu_is_gb10(0x1002, 0x2e12),
	    "(a) the GB10 device ID of another vendor is not the GB10");
	CHECK(!gb10smmu_is_gb10(0x0000, 0x0000),
	    "(a) nothing at all is not the GB10");
}

/*
 * case_requester_id - (b) the requester ID of a PCI device is the PCI's
 * own layout: the bus in the upper eight bits, the slot in the next five
 * and the function in the last three.
 */
static void
case_requester_id(void)
{
	CHECK(gb10smmu_requester_id(0, 0, 0) == 0x000,
	    "(b) the requester ID of 00:00.0 is zero");
	CHECK(gb10smmu_requester_id(0, 1, 0) == 0x008,
	    "(b) the requester ID of 00:01.0 is 0x008");
	CHECK(gb10smmu_requester_id(1, 0, 0) == 0x100,
	    "(b) the requester ID of 01:00.0 is 0x100");
	CHECK(gb10smmu_requester_id(1, 2, 3) == 0x113,
	    "(b) the requester ID of 01:02.3 is 0x113");
	CHECK(gb10smmu_requester_id(0xff, 0x1f, 0x07) == 0xffff,
	    "(b) the requester ID of the last device is 0xffff");
}

int
main(void)
{
	printf("# (a) the GB10 and nothing else\n");
	case_is_gb10();
	printf("# (b) the requester ID of a PCI device\n");
	case_requester_id();
	printf("passed: %d failed: %d\n", passed, failed);
	return (failed == 0 ? 0 : 1);
}

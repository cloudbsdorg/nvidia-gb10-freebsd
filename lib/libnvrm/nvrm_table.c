/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * nvrm_table.c - the chip family table.  This is data: every row is keyed by
 * the pair (cls_gpfifo, cls_compute) and every class number is taken from the
 * class headers of open-gpu-kernel-modules 580.178.04 (src/common/sdk/nvidia/
 * inc/class/).  Rows are ordered newest first; the first row whose two key
 * classes the GPU lists wins.  A GPU that matches no row is still reported,
 * with the family-supplied values unavailable.
 *
 * The name of a row is the chip family it covers, never a marketing name,
 * and it is the same name the driver publishes (the architecture table of
 * src/gb10-archfloor/nv_arch_floor.h): the preflight JSON and
 * hw.nvidia.min_architecture_name carry the same spelling, so a consumer
 * compares the two as they are.
 *
 * The GA100 row is a profile of the GA10x family: the architecture value
 * 0x17 is the GA10x family whatever the chip is.  The product identity is
 * in chip_id and implementation, not in the family.
 *
 * AD10x has no copy class of its own in the headers: its copy engines are
 * the ones of the generation before (0xC7B5), as the RM class lists show.
 *
 * Board decorators are PCI-subsystem entries that only add or override
 * options and never decide support.  No decorator goes in without a real
 * board that needs it, so the table is empty today.
 */
#include "nvrm_internal.h"

#define KiB(x)	((uint64_t)(x) << 10)
#define MiB(x)	((uint64_t)(x) << 20)

const nvrm_family nvrm_family_table[] = {
	{ "GB20x", 0xCA6F, 0xCEC0, 0xCE97, 0xCAB5,
	    { KiB(4), KiB(64), MiB(2), MiB(512) } },
	{ "GB10x", 0xC96F, 0xCDC0, 0xCD97, 0xC9B5,
	    { KiB(4), KiB(64), MiB(2), MiB(512) } },
	{ "GH100", 0xC86F, 0xCBC0, 0xCB97, 0xC8B5,
	    { KiB(4), KiB(64), MiB(2), MiB(512) } },
	{ "AD10x", 0xC56F, 0xC9C0, 0xC997, 0xC7B5,
	    { KiB(4), KiB(64), MiB(2) } },
	{ "GA10x", 0xC56F, 0xC7C0, 0xC797, 0xC7B5,
	    { KiB(4), KiB(64), MiB(2) } },
	{ "GA10x", 0xC56F, 0xC6C0, 0xC697, 0xC6B5,
	    { KiB(4), KiB(64), MiB(2) } },
	{ "TU10x", 0xC46F, 0xC5C0, 0xC597, 0xC5B5,
	    { KiB(4), KiB(64), MiB(2) } },
};

const unsigned nvrm_family_count =
    sizeof(nvrm_family_table) / sizeof(nvrm_family_table[0]);

/* CUDA compute capability, keyed by ctrl2080mc.h architecture and
 * implementation (lines 70-155).  UINT64_MAX means every implementation of
 * that architecture. */
typedef struct nvrm_compute_row {
	uint64_t	architecture, implementation;
	uint32_t	major, minor;
} nvrm_compute_row;

static const nvrm_compute_row compute_table[] = {
	{ 0x160, UINT64_MAX, 7, 5 },		/* TU100 */
	{ 0x170, 0x00, 8, 0 },			/* GA100 */
	{ 0x170, 0x02, 8, 6 },			/* GA102 */
	{ 0x170, 0x03, 8, 6 },			/* GA103 */
	{ 0x170, 0x04, 8, 6 },			/* GA104 */
	{ 0x170, 0x06, 8, 6 },			/* GA106 */
	{ 0x170, 0x07, 8, 6 },			/* GA107 */
	{ 0x170, 0x0b, 8, 7 },			/* GA10B */
	{ 0x190, UINT64_MAX, 8, 9 },		/* AD100 */
	{ 0x180, 0x00, 9, 0 },			/* GH100 */
	{ 0x180, 0x01, 9, 0 },			/* GH100_SOC */
	{ 0x1a0, 0x00, 10, 0 },			/* GB100 */
	{ 0x1a0, 0x02, 10, 0 },			/* GB102 */
	{ 0x1b0, 0x02, 12, 0 },			/* GB202 */
	{ 0x1b0, 0x03, 12, 0 },			/* GB203 */
	{ 0x1b0, 0x05, 12, 0 },			/* GB205 */
	{ 0x1b0, 0x06, 12, 0 },			/* GB206 */
	{ 0x1b0, 0x07, 12, 0 },			/* GB207 */
	{ 0x1b0, 0x0b, 12, 1 },			/* GB20B */
};

int
nvrm_compute_capability_for(uint64_t architecture, uint64_t implementation,
    uint32_t *major, uint32_t *minor)
{
	unsigned i;

	for (i = 0; i < sizeof(compute_table) / sizeof(compute_table[0]); i++) {
		if (compute_table[i].architecture != architecture ||
		    (compute_table[i].implementation != UINT64_MAX &&
		    compute_table[i].implementation != implementation))
			continue;
		*major = compute_table[i].major;
		*minor = compute_table[i].minor;
		return (1);
	}
	return (0);
}

/* No board needs a decorator yet; the terminator keeps the table non-empty. */
const nvrm_decorator nvrm_decorator_table[] = {
	{ NULL, 0, 0, { { -1, 0 } } },
};

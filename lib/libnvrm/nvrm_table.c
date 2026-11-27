/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * nvrm_table.c - the generation table.  This is data: every row is keyed by
 * the pair (cls_gpfifo, cls_compute) and every class number is taken from the
 * class headers of open-gpu-kernel-modules 580.178.04 (src/common/sdk/nvidia/
 * inc/class/).  Rows are ordered newest first; the first row whose two key
 * classes the GPU lists wins.  A GPU that matches no row is still reported,
 * with the family-supplied values unavailable.
 *
 * A row is named after the chip family, never after an architecture: the
 * family names are the ones the RM's own header uses for the architectures
 * (ctrl2080mc.h: "valid ARCHITECTURE_... implementation values" names the
 * families TU10x, GA10x, GH10x, AD10x, GB10x and GB20x).
 *
 * The classes of a row: the GPFIFO, the compute, the 3D and the copy class
 * are the ones the chip uses.  The 2D class (FERMI_TWOD_A, 0x902d) is the
 * same on every generation.  The memory-to-memory (inline to memory) class
 * is only known for the families whose class header is in the SDK headers
 * (the inline-to-memory class of GB100, 0xcd40); where it is not known the
 * row says zero, and the value is reported as unavailable.  The video
 * decoder class is the one of the same group as the compute class.
 *
 * The limits of a row (the thread blocks a multiprocessor holds, the shared
 * memory a work group may use and the sizes a multiprocessor may be given)
 * are the per-compute-capability limits of the CUDA C++ programming guide
 * ("Technical Specifications per Compute Capability"), which is where the
 * numbers come from.
 *
 * Ada has no copy class of its own in the headers: its copy engines are the
 * ones of the generation before (0xC7B5), as the RM class lists show.
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
	  0x902D, 0, 0xCEB0,
	  24, KiB(99), { KiB(8), KiB(16), KiB(32), KiB(64), KiB(100) },
	  { KiB(4), KiB(64), MiB(2), MiB(512) } },
	{ "GB10x", 0xC96F, 0xCDC0, 0xCD97, 0xC9B5,
	  0x902D, 0xCD40, 0xCDB0,
	  24, KiB(99), { KiB(8), KiB(16), KiB(32), KiB(64), KiB(100) },
	  { KiB(4), KiB(64), MiB(2), MiB(512) } },
	{ "GH10x", 0xC86F, 0xCBC0, 0xCB97, 0xC8B5,
	  0x902D, 0, 0,
	  32, KiB(227),
	  { KiB(8), KiB(16), KiB(32), KiB(64), KiB(100), KiB(128), KiB(228) },
	  { KiB(4), KiB(64), MiB(2), MiB(512) } },
	{ "AD10x", 0xC56F, 0xC9C0, 0xC997, 0xC7B5,
	  0x902D, 0, 0xC9B0,
	  24, KiB(99), { KiB(8), KiB(16), KiB(32), KiB(64), KiB(100) },
	  { KiB(4), KiB(64), MiB(2) } },
	{ "GA10x", 0xC56F, 0xC7C0, 0xC797, 0xC7B5,
	  0x902D, 0, 0xC7B0,
	  24, KiB(99), { KiB(8), KiB(16), KiB(32), KiB(64), KiB(100) },
	  { KiB(4), KiB(64), MiB(2) } },
	{ "GA10x", 0xC56F, 0xC6C0, 0xC697, 0xC6B5,
	  0x902D, 0, 0xC6B0,
	  32, KiB(163),
	  { KiB(8), KiB(16), KiB(32), KiB(64), KiB(128), KiB(164) },
	  { KiB(4), KiB(64), MiB(2) } },
	{ "TU10x", 0xC46F, 0xC5C0, 0xC597, 0xC5B5,
	  0x902D, 0, 0,
	  32, KiB(64), { KiB(8), KiB(16), KiB(32), KiB(64) },
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

/* The name of the chipset, keyed by the same architecture and
 * implementation.  The names are the ones ctrl2080mc.h gives for the
 * architectures and their implementations.  The chips of one architecture
 * are one array, and the table below says which array belongs to which
 * architecture: a chipset is always one of the chips of its architecture.
 */
typedef struct nvrm_chipset_chip {
	uint64_t	implementation;
	const char	*name;
} nvrm_chipset_chip;

typedef struct nvrm_chipset_arch {
	uint64_t		architecture;
	const nvrm_chipset_chip *chips;
	unsigned		count;
} nvrm_chipset_arch;

#define NVRM_CHIPSET_COUNT(chips)	\
	(sizeof(chips) / sizeof((chips)[0]))

static const nvrm_chipset_chip chipset_tu[] = {
	{ 0x00, "TU100" },
	{ 0x02, "TU102" },
	{ 0x04, "TU104" },
	{ 0x06, "TU106" },
	{ 0x07, "TU117" },
	{ 0x08, "TU116" },
};

static const nvrm_chipset_chip chipset_ga[] = {
	{ 0x00, "GA100" },
	{ 0x02, "GA102" },
	{ 0x03, "GA103" },
	{ 0x04, "GA104" },
	{ 0x06, "GA106" },
	{ 0x07, "GA107" },
	{ 0x0b, "GA10B" },
};

static const nvrm_chipset_chip chipset_gh[] = {
	{ 0x00, "GH100" },
	{ 0x01, "GH100" },
};

static const nvrm_chipset_chip chipset_ad[] = {
	{ 0x00, "AD100" },
	{ 0x01, "AD101" },
	{ 0x02, "AD102" },
	{ 0x03, "AD103" },
	{ 0x04, "AD104" },
	{ 0x06, "AD106" },
	{ 0x07, "AD107" },
	{ 0x0b, "AD10B" },
};

static const nvrm_chipset_chip chipset_gb100[] = {
	{ 0x00, "GB100" },
	{ 0x02, "GB102" },
	{ 0x03, "GB110" },
	{ 0x04, "GB112" },
};

static const nvrm_chipset_chip chipset_gb200[] = {
	{ 0x00, "GB200" },
	{ 0x02, "GB202" },
	{ 0x03, "GB203" },
	{ 0x05, "GB205" },
	{ 0x06, "GB206" },
	{ 0x07, "GB207" },
	{ 0x0b, "GB20B" },
	{ 0x0c, "GB20C" },
};

static const nvrm_chipset_arch chipset_archs[] = {
	{ 0x160, chipset_tu, NVRM_CHIPSET_COUNT(chipset_tu) },
	{ 0x170, chipset_ga, NVRM_CHIPSET_COUNT(chipset_ga) },
	{ 0x180, chipset_gh, NVRM_CHIPSET_COUNT(chipset_gh) },
	{ 0x190, chipset_ad, NVRM_CHIPSET_COUNT(chipset_ad) },
	{ 0x1a0, chipset_gb100, NVRM_CHIPSET_COUNT(chipset_gb100) },
	{ 0x1b0, chipset_gb200, NVRM_CHIPSET_COUNT(chipset_gb200) },
};

const char *
nvrm_chipset_name_for(uint64_t architecture, uint64_t implementation)
{
	unsigned a, i;

	for (a = 0; a < sizeof(chipset_archs) / sizeof(chipset_archs[0]); a++) {
		if (chipset_archs[a].architecture != architecture)
			continue;
		for (i = 0; i < chipset_archs[a].count; i++)
			if (chipset_archs[a].chips[i].implementation == implementation)
				return (chipset_archs[a].chips[i].name);
		return (NULL);
	}
	return (NULL);
}

/* No board needs a decorator yet; the terminator keeps the table non-empty. */
const nvrm_decorator nvrm_decorator_table[] = {
	{ NULL, 0, 0, { { -1, 0 } } },
};

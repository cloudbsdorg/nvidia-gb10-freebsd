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
 * Board decorators are PCI-subsystem entries that only add or override
 * options and never decide support.  No decorator goes in without a real
 * board that needs it, so the table is empty today.
 */
#include "nvrm_internal.h"

#define KiB(x)	((uint64_t)(x) << 10)
#define MiB(x)	((uint64_t)(x) << 20)

const nvrm_family nvrm_family_table[] = {
	{ "blackwell-b", 0xCA6F, 0xCEC0, 0xCE97, 0xCAB5,
	    { KiB(4), KiB(64), MiB(2), MiB(512) } },
	{ "blackwell-a", 0xC96F, 0xCDC0, 0xCD97, 0xC9B5,
	    { KiB(4), KiB(64), MiB(2), MiB(512) } },
	{ "hopper", 0xC86F, 0xCBC0, 0xCB97, 0xC8B5,
	    { KiB(4), KiB(64), MiB(2), MiB(512) } },
	{ "ada", 0xC56F, 0xC9C0, 0xC997, 0,
	    { KiB(4), KiB(64), MiB(2) } },
	{ "ampere-ga10x", 0xC56F, 0xC7C0, 0xC797, 0xC7B5,
	    { KiB(4), KiB(64), MiB(2) } },
	{ "ampere-ga100", 0xC56F, 0xC6C0, 0xC697, 0xC6B5,
	    { KiB(4), KiB(64), MiB(2) } },
	{ "turing", 0xC46F, 0xC5C0, 0xC597, 0xC5B5,
	    { KiB(4), KiB(64), MiB(2) } },
};

const unsigned nvrm_family_count =
    sizeof(nvrm_family_table) / sizeof(nvrm_family_table[0]);

/* No board needs a decorator yet; the terminator keeps the table non-empty. */
const nvrm_decorator nvrm_decorator_table[] = {
	{ NULL, 0, 0, { { -1, 0 } } },
};

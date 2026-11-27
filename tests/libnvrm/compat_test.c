/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * compat_test.c - a program bound to NVRM_1.0 walks the field table with
 * nvrm_info_nfields() and nvrm_info_field().  Resolve the 1.0 versions in the
 * BUILT shared library with dlvsym and check that it meets exactly the rows
 * and kinds libnvrm had at 8702134, at the same indexes; the default (1.2)
 * versions return the whole table, the rows added later last.
 *
 * Usage: compat_test /path/to/libnvrm.so.1
 * Exit 0 all checks held, 1 a row check failed, 2 usage, 3 the library or a
 * versioned symbol could not be loaded (no verdict).
 */
#include <dlfcn.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>

#include <nvrm/nvrm.h>

#include "t.h"

typedef unsigned (*nfields_fn)(void);
typedef const nvrm_field *(*field_fn)(unsigned);

/* nvrm_fields.c at 8702134, in order (git show 8702134:lib/libnvrm/nvrm_fields.c) */
static const char *const v10[] = {
	"pci_domain", "pci_bus", "pci_slot", "pci_function", "pci_vendor",
	"pci_device", "pci_subsystem_vendor", "pci_subsystem_device",
	"pci_revision", "rm_gpu_id", "uuid", "architecture", "implementation",
	"chip_id", "sm_version_major", "sm_version_minor", "gpc_count",
	"tpc_count", "sm_count", "cls_gpfifo", "cls_compute", "cls_eng3d",
	"cls_copy", "classes", "family", "vram_size", "bar1_size",
	"max_page_size", "numa_node", "page_sizes",
};
#define N10 (sizeof(v10) / sizeof(v10[0]))

static const char *const later[] = {
	"rm_sm_version", "compute_capability_major",
	"compute_capability_minor", "vbios", "gsp_firmware",
	"device_name", "chipset_name", "mp_per_tpc", "max_warps_per_mp",
	"max_blocks_per_mp", "cls_eng2d", "cls_m2mf", "cls_vdec",
	"nc_atom_size", "max_smem_per_wg", "sm_smem_sizes",
	"zcull_width_align_pixels", "zcull_height_align_pixels",
	"zcull_aliquot_total", "zcull_region_bytes",
	"zcull_region_header_bytes", "zcull_subregion_header_bytes",
	"vram_used", "vram_free",
};
#define NLATER (sizeof(later) / sizeof(later[0]))

int
main(int argc, char **argv)
{
	void *h;
	nfields_fn n10fn, n12fn;
	field_fn f10fn, f12fn;
	unsigned i;

	if (argc != 2)
		return (2);
	h = dlopen(argv[1], RTLD_NOW);
	CHECK(h != NULL);
	if (h == NULL)
		return (3);
	n10fn = (nfields_fn)(uintptr_t)dlvsym(h, "nvrm_info_nfields", "NVRM_1.0");
	f10fn = (field_fn)(uintptr_t)dlvsym(h, "nvrm_info_field", "NVRM_1.0");
	n12fn = (nfields_fn)(uintptr_t)dlvsym(h, "nvrm_info_nfields", "NVRM_1.2");
	f12fn = (field_fn)(uintptr_t)dlvsym(h, "nvrm_info_field", "NVRM_1.2");
	CHECK(n10fn != NULL && f10fn != NULL && n12fn != NULL && f12fn != NULL);
	if (t_fails != 0 || n10fn == NULL || f10fn == NULL || n12fn == NULL ||
	    f12fn == NULL)
		return (3);		/* not loaded: no verdict on the rows */

	/* NVRM_1.0: the 1.0 rows, in 1.0 order, no row of a later kind */
	CHECK_EQ(n10fn(), N10);
	for (i = 0; i < N10; i++) {
		const nvrm_field *f = f10fn(i);

		CHECK(f != NULL);
		if (f == NULL)
			continue;
		CHECK_STR(f->name, v10[i]);
		CHECK(f->kind != NVRM_K_VERSION);
		CHECK(f->kind == NVRM_K_U64 || f->kind == NVRM_K_STR ||
		    f->kind == NVRM_K_LIST);
	}
	CHECK(f10fn(N10) == NULL);
	CHECK(f10fn(N10 + 1) == NULL);
	CHECK(f10fn(n10fn()) == NULL);

	/* NVRM_1.2: all of it; the 1.0 rows at the same indexes, then the new */
	CHECK_EQ(n12fn(), N10 + NLATER);
	for (i = 0; i < N10; i++)
		CHECK(f12fn(i) != NULL && strcmp(f12fn(i)->name, v10[i]) == 0);
	for (i = 0; i < NLATER; i++)
		CHECK(f12fn(N10 + i) != NULL &&
		    strcmp(f12fn(N10 + i)->name, later[i]) == 0);
	CHECK(f12fn(N10 + NLATER) == NULL);
	/* the unversioned name binds to the default */
	CHECK((nfields_fn)(uintptr_t)dlsym(h, "nvrm_info_nfields") == n12fn);
	CHECK((field_fn)(uintptr_t)dlsym(h, "nvrm_info_field") == f12fn);

	printf("compat_test: %d checks, %d failures\n", t_checks, t_fails);
	return (t_fails != 0);
}

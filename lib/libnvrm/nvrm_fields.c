/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * nvrm_fields.c - the one definition of what nvrm_device_info holds.  The JSON
 * emitter and the JSON schema generator both read these tables, so the output
 * and the schema cannot drift apart; the build compares the generated schema
 * with the committed one.
 */
#include <stddef.h>
#include <stdlib.h>

/*
 * In the shared library the two table accessors are versioned twice: this
 * file's (the whole table) is NVRM_1.2, nvrm_compat.c's (the 1.0 rows) is
 * NVRM_1.0.  The unit tests link the sources straight into the test, where a
 * symbol version cannot exist, so they keep the plain names.
 */
#ifdef NVRM_SHLIB
#define nvrm_info_nfields nvrm_info_nfields_1_2
#define nvrm_info_field nvrm_info_field_1_2
#endif

#include "nvrm_internal.h"

#define F(g, n, k, d) { g, #n, k, offsetof(nvrm_device_info, n), 0, d }
#define FH(g, n, k, d) { g, #n, k, offsetof(nvrm_device_info, n), 1, d }

/* CPD-OFF -- the field table: one row per field */
const nvrm_field nvrm_fields[] = {
	F("identity", pci_domain, NVRM_K_U64, "PCI domain"),
	F("identity", pci_bus, NVRM_K_U64, "PCI bus"),
	F("identity", pci_slot, NVRM_K_U64, "PCI slot"),
	F("identity", pci_function, NVRM_K_U64, "PCI function"),
	FH("identity", pci_vendor, NVRM_K_U64, "PCI vendor id"),
	FH("identity", pci_device, NVRM_K_U64, "PCI device id"),
	FH("identity", pci_subsystem_vendor, NVRM_K_U64,
	    "PCI subsystem vendor id"),
	FH("identity", pci_subsystem_device, NVRM_K_U64,
	    "PCI subsystem device id"),
	FH("identity", pci_revision, NVRM_K_U64, "PCI revision id"),
	FH("identity", rm_gpu_id, NVRM_K_U64, "opaque RM id of the GPU"),
	F("identity", uuid, NVRM_K_STR, "GPU UUID"),
	FH("gpu", architecture, NVRM_K_U64, "RM architecture id"),
	FH("gpu", implementation, NVRM_K_U64, "RM implementation id"),
	FH("gpu", chip_id, NVRM_K_U64, "architecture plus implementation"),
	F("gpu", sm_version_major, NVRM_K_U64, "RM SM version, major"),
	F("gpu", sm_version_minor, NVRM_K_U64, "RM SM version, minor"),
	F("gpu", gpc_count, NVRM_K_U64, "enabled GPCs"),
	F("gpu", tpc_count, NVRM_K_U64, "enabled TPCs"),
	F("gpu", sm_count, NVRM_K_U64, "enabled SMs"),
	FH("gpu", cls_gpfifo, NVRM_K_U64, "GPFIFO channel class"),
	FH("gpu", cls_compute, NVRM_K_U64, "compute class"),
	FH("gpu", cls_eng3d, NVRM_K_U64, "3D class"),
	FH("gpu", cls_copy, NVRM_K_U64, "copy engine class"),
	FH("gpu", classes, NVRM_K_LIST, "every class the GPU supports"),
	F("gpu", family, NVRM_K_STR, "the chip family of the GPU"),
	F("memory", vram_size, NVRM_K_U64,
	    "local video memory in bytes (0 on unified-memory parts)"),
	F("memory", bar1_size, NVRM_K_U64, "BAR1 virtual range in bytes"),
	F("memory", max_page_size, NVRM_K_U64,
	    "largest page size the GPU MMU supports here, in bytes"),
	F("memory", numa_node, NVRM_K_U64, "NUMA node of the GPU"),
	F("memory", page_sizes, NVRM_K_LIST, "page sizes in bytes"),
	/* Added after NVRM_1.0: last, so the 1.0 rows keep their indexes. */
	FH("gpu", rm_sm_version, NVRM_K_U64, "raw RM SM version code"),
	F("gpu", compute_capability_major, NVRM_K_U64,
	    "CUDA compute capability, major"),
	F("gpu", compute_capability_minor, NVRM_K_U64,
	    "CUDA compute capability, minor"),
	F("versions", vbios, NVRM_K_VERSION, "VBIOS version"),
	F("versions", gsp_firmware, NVRM_K_VERSION, "GSP firmware version"),
	/* Added after NVRM_1.3: the device and engine limits, and what the
	 * video memory holds. */
	F("gpu", device_name, NVRM_K_STR, "the marketing name of the GPU"),
	F("gpu", chipset_name, NVRM_K_STR, "the name of the chipset"),
	F("gpu", mp_per_tpc, NVRM_K_U64, "multiprocessors per TPC"),
	F("gpu", max_warps_per_mp, NVRM_K_U64, "warps per multiprocessor"),
	F("gpu", max_blocks_per_mp, NVRM_K_U64,
	    "thread blocks per multiprocessor"),
	FH("gpu", cls_eng2d, NVRM_K_U64, "2D class"),
	FH("gpu", cls_m2mf, NVRM_K_U64, "memory to memory class"),
	FH("gpu", cls_vdec, NVRM_K_U64, "video decode class"),
	F("gpu", nc_flush_granularity, NVRM_K_U64,
	    "flush granularity in bytes: the host cache line size, or the "
	    "host page size when the cache line size is not reported"),
	F("gpu", max_smem_per_wg, NVRM_K_U64,
	    "shared memory a work group may use, in bytes"),
	F("gpu", sm_smem_sizes, NVRM_K_LIST,
	    "shared memory sizes a multiprocessor may be given, in bytes"),
	F("gpu", zcull_width_align_pixels, NVRM_K_U64,
	    "zcull width alignment in pixels"),
	F("gpu", zcull_height_align_pixels, NVRM_K_U64,
	    "zcull height alignment in pixels"),
	F("gpu", zcull_aliquot_total, NVRM_K_U64,
	    "zcull aliquots the GPU has"),
	F("gpu", zcull_region_bytes, NVRM_K_U64,
	    "bytes per zcull aliquot"),
	F("gpu", zcull_region_header_bytes, NVRM_K_U64,
	    "zcull region header size in bytes"),
	F("gpu", zcull_subregion_header_bytes, NVRM_K_U64,
	    "zcull subregion header size in bytes"),
	F("memory", vram_used, NVRM_K_U64, "video memory in use, in bytes"),
	F("memory", vram_free, NVRM_K_U64, "video memory still free, in bytes"),
};

/* CPD-ON */

/* the 1.0 view must fit inside the table */
_Static_assert(sizeof(nvrm_fields) / sizeof(nvrm_fields[0]) >=
    NVRM_NFIELDS_1_0, "NVRM_NFIELDS_1_0 is larger than the field table");

const unsigned nvrm_nfields = sizeof(nvrm_fields) / sizeof(nvrm_fields[0]);

const char *const nvrm_group_names[] = {
	"identity", "gpu", "memory", "versions"
};
const unsigned nvrm_ngroups =
    sizeof(nvrm_group_names) / sizeof(nvrm_group_names[0]);

unsigned
nvrm_info_nfields(void)
{
	return (nvrm_nfields);
}

const nvrm_field *
nvrm_info_field(unsigned index)
{
	return (index < nvrm_nfields ? &nvrm_fields[index] : NULL);
}

int *
nvrm_field_reason(nvrm_device_info *info, const nvrm_field *f)
{
	char *base = (char *)info + f->offset;

	switch (f->kind) {
	case NVRM_K_U64:
		return (&((nvrm_u64 *)base)->reason);
	case NVRM_K_STR:
		return (&((nvrm_str *)base)->reason);
	case NVRM_K_LIST:
		return (&((nvrm_list *)base)->reason);
	default:
		abort();	/* a new kind needs a case here, not a guess */
	}
}

#ifdef NVRM_SHLIB
__asm__(".symver nvrm_info_nfields_1_2, nvrm_info_nfields@@NVRM_1.2");
__asm__(".symver nvrm_info_field_1_2, nvrm_info_field@@NVRM_1.2");
#endif

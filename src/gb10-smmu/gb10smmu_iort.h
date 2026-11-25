/*
 * Copyright (c) 2026 Dave Cottlehuber
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The IORT parser of gb10smmu, kept apart from the module so that it can be
 * built and run outside the kernel: the unit test builds this file with the
 * same source the module builds.
 *
 * Where the offsets come from
 * ---------------------------
 * Arm DEN 0049 (IORT) and FreeBSD's own reader, sys/arm64/acpica/acpi_iort.c,
 * agree on these, and every read below is bounded by them:
 *
 *   ACPI_TABLE_IORT.NodeOffset
 *       the offset of the first node from the start of the table.
 *   ACPI_IORT_NODE.MappingOffset
 *       the offset of the node's ID mapping array from the start of that
 *       node (acpi_iort.c: ACPI_ADD_PTR(ACPI_IORT_ID_MAPPING, node_entry,
 *       node_entry->MappingOffset)).
 *   ACPI_IORT_RMR.RmrOffset
 *       the offset of the RMR descriptor array from the start of the RMR
 *       node, the same rule as MappingOffset.
 *   ACPI_IORT_ID_MAPPING.OutputReference
 *       the offset of the referenced node from the start of the IORT table
 *       (acpi_iort.c compares it with the node offset in the table).
 *   ACPI_IORT_NODE.NodeData
 *       the node-specific data.  It is not an offset stored in the node: in
 *       the ACPICA headers (contrib/dev/acpica/include/actbl2.h) NodeData is
 *       the flexible array member at the end of the common node header, so
 *       it sits at node + sizeof(ACPI_IORT_NODE) (16 bytes), a fixed offset
 *       from the start of the node.  The parser still checks that the
 *       structure it reads fits inside the node before it reads it.
 */
#ifndef _GB10SMMU_IORT_H_
#define _GB10SMMU_IORT_H_

#include <contrib/dev/acpica/include/acpi.h>

/*
 * How many stream-ID ranges the GPU may have.  More than this is an error
 * the caller must report, never a silent truncation: the module refuses to
 * attach when the table holds more.
 */
#define	GB10SMMU_MAX_SIDRANGE	64

/* What the parser returns. */
#define	GB10SMMU_IORT_OK	0	/* the table describes the GPU */
#define	GB10SMMU_IORT_EFORMAT	1	/* the table is not a usable IORT */
#define	GB10SMMU_IORT_ENODE	2	/* the table has no node for the GPU */
#define	GB10SMMU_IORT_EAMBIG	3	/* the table says two different things */
#define	GB10SMMU_IORT_ETOOBIG	4	/* more of something than the caller holds */

/* One range of stream IDs: the GPU's, or one of the GPU's. */
struct gb10smmu_sidrange {
	uint32_t	lo;	/* the first stream ID, inclusive */
	uint32_t	hi;	/* the last stream ID, inclusive */
};

/* One memory region the firmware reserves for the GPU. */
struct gb10smmu_rmr {
	uint64_t	base;
	uint64_t	length;
};

/* Where the GPU is.  The parser looks for the node that covers it. */
struct gb10smmu_iort_query {
	uint32_t	seg;	/* the PCI segment number of the GPU */
	uint32_t	rid;	/* the PCI requester ID of the GPU */
};

/* Where a parse error happened, so the message can name the node. */
struct gb10smmu_iort_error {
	const char	*what;	/* what went wrong */
	uint32_t	node;	/* the node's offset in the table */
	uint32_t	node_len;	/* the length the node claims */
	uint32_t	node_type;	/* the type of the node */
	uint64_t	value;	/* the value that was wrong */
};

/* What the parser found. */
struct gb10smmu_iort {
	uint64_t	smmu_base;	/* the SMMUv3 base address */
	uint32_t	smmu_model;	/* the SMMU model */
	uint32_t	smmu_flags;	/* the SMMU flags */
	uint32_t	smmu_node;	/* the SMMUv3 node's offset in the table */
	uint32_t	holder_node;	/* the node that holds the GPU's mappings */
	uint32_t	holder_type;	/* the type of that node */
	uint32_t	rid_lo;		/* the requester IDs the mappings cover */
	uint32_t	rid_hi;		/* the last of them */
	int		nsid;		/* the number of stream-ID ranges */
	struct gb10smmu_sidrange sid[GB10SMMU_MAX_SIDRANGE];
	int		nrmr;		/* the descriptors stored below */
	int		nrmr_total;	/* the descriptors the IORT holds */
	int		nrmr_max;	/* the size of the caller's array */
	struct gb10smmu_rmr	*rmr;	/* the caller's array */
};

int gb10smmu_iort_parse(const void *table, size_t tablelen,
    const struct gb10smmu_iort_query *query, struct gb10smmu_iort *out,
    struct gb10smmu_iort_error *err);

#endif /* _GB10SMMU_IORT_H_ */

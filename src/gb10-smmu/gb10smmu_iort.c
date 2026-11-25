/*
 * Copyright (c) 2026 Dave Cottlehuber
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The IORT parser of gb10smmu.
 *
 * It answers one question: which SMMU stands in front of the GPU, which
 * stream IDs of that SMMU the GPU's requester IDs become, and which memory
 * the firmware reserves for the GPU.  Everything it reads comes from the
 * table the firmware wrote; nothing is guessed and nothing is assumed.
 *
 * Every read is bounded twice: by the length of the table and by the length
 * of the node the read belongs to, and the bounds are checked before the
 * read happens.  A table that does not make sense is an error the caller
 * must act on: the parser never returns a partial answer.
 *
 * The offsets are the ones of Arm DEN 0049 and of FreeBSD's own reader,
 * sys/arm64/acpica/acpi_iort.c; gb10smmu_iort.h says which is which.
 */
#ifdef _KERNEL
#include <sys/param.h>
#include <sys/systm.h>
#else
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#endif

#include "gb10smmu_iort.h"

/* How many nodes may hold the GPU's mappings. */
#define	MAX_HOLDERS	8

/*
 * How many bytes of node-specific data each kind of node carries.  These
 * are the extents of the fields, not sizeof(): the C structures in
 * actbl2.h end in a flexible array member and in tail padding, and the
 * fields themselves are what the node has to hold.
 */
#define	IORT_RC_DATASIZE	20	/* root complex: to PasidCapabilities */
#define	IORT_NC_DATASIZE	17	/* named component: to the limit */
#define	IORT_SMMUV3_DATASIZE	52	/* SMMUv3: to IdMappingIndex */
#define	IORT_RMR_DATASIZE	12	/* RMR: to RmrOffset */

struct iort_ctx {
	char		*base;		/* the table */
	size_t		len;		/* the bytes of the table we may read */
	uint32_t	first;		/* the offset of the first node */
	uint32_t	count;		/* the nodes the table claims */
	uint32_t	seen;		/* the nodes we walked */
};

/*
 * iort_err - record what went wrong, where, and say so.
 */
static int
iort_err(struct gb10smmu_iort_error *err, int code, const char *what,
    uint32_t node, uint32_t node_len, uint32_t node_type, uint64_t value)
{
	if (err != NULL) {
		err->what = what;
		err->node = node;
		err->node_len = node_len;
		err->node_type = node_type;
		err->value = value;
	}
	return (code);
}

/*
 * iort_node_at - the node at an offset, if it is a node.
 *
 * The node must start inside the table and must end inside it, and it must
 * be at least as long as its own header.
 */
static int
iort_node_at(const struct iort_ctx *c, uint32_t off, ACPI_IORT_NODE **nodep,
    struct gb10smmu_iort_error *err)
{
	ACPI_IORT_NODE *n;

	if (off > c->len || c->len - off < sizeof(ACPI_IORT_NODE))
		return (iort_err(err, GB10SMMU_IORT_EFORMAT,
		    "the node starts outside the table", off, 0, 0,
		    (uint64_t)c->len));
	n = (ACPI_IORT_NODE *)(c->base + off);
	if (n->Length < sizeof(ACPI_IORT_NODE))
		return (iort_err(err, GB10SMMU_IORT_EFORMAT,
		    "the node is shorter than its header", off, n->Length,
		    n->Type, n->Length));
	if (c->len - off < n->Length)
		return (iort_err(err, GB10SMMU_IORT_EFORMAT,
		    "the node ends outside the table", off, n->Length,
		    n->Type, n->Length));
	*nodep = n;
	return (0);
}

/*
 * iort_maps_at - the ID mapping array of a node, if it is inside the node.
 *
 * The array sits at MappingOffset from the start of the node and must fit
 * in the node: the count times the size of an entry, added to the offset,
 * must not pass the end of the node.
 */
static int
iort_maps_at(ACPI_IORT_NODE *node, uint32_t off,
    ACPI_IORT_ID_MAPPING **mapsp, struct gb10smmu_iort_error *err)
{
	uint64_t need;

	*mapsp = NULL;
	if (node->MappingCount == 0)
		return (0);
	if (node->MappingOffset < sizeof(ACPI_IORT_NODE))
		return (iort_err(err, GB10SMMU_IORT_EFORMAT,
		    "the mapping array overlaps the node header", off,
		    node->Length, node->Type, node->MappingOffset));
	need = (uint64_t)node->MappingCount * sizeof(ACPI_IORT_ID_MAPPING);
	if ((uint64_t)node->MappingOffset + need > (uint64_t)node->Length)
		return (iort_err(err, GB10SMMU_IORT_EFORMAT,
		    "the mapping array does not fit in the node", off,
		    node->Length, node->Type, need));
	*mapsp = (ACPI_IORT_ID_MAPPING *)((char *)node + node->MappingOffset);
	return (0);
}

/*
 * iort_nodedata - the node-specific data of a node, if it fits in the node.
 *
 * NodeData is the flexible array member at the end of the common node
 * header, so it sits at node + sizeof(ACPI_IORT_NODE).  The structure to
 * read must be inside the node's own length.
 */
static int
iort_nodedata(ACPI_IORT_NODE *node, uint32_t off, size_t size,
    const void **datap, struct gb10smmu_iort_error *err)
{
	if ((size_t)node->Length < sizeof(ACPI_IORT_NODE) + size)
		return (iort_err(err, GB10SMMU_IORT_EFORMAT,
		    "the node data does not fit in the node", off,
		    node->Length, node->Type, (uint64_t)size));
	*datap = node->NodeData;
	return (0);
}

/*
 * iort_resolve - the SMMUv3 node an ID mapping leads to, and the stream ID
 * it leads to.
 *
 * A mapping of a root complex names the SMMU it feeds.  When it names an
 * SMMU (v2) node, that node's own mapping carries the stream ID on, the
 * way FreeBSD's iort_smmu_trymap() follows it.
 */
static int
iort_resolve(const struct iort_ctx *c, uint32_t ref, uint32_t id,
    uint32_t *smmu_off, uint32_t *out_id, int depth,
    struct gb10smmu_iort_error *err)
{
	ACPI_IORT_NODE *node;
	ACPI_IORT_ID_MAPPING *maps;
	uint32_t i;
	int error;

	if (depth > 2)
		return (iort_err(err, GB10SMMU_IORT_EFORMAT,
		    "the mapping chain is too deep", ref, 0, 0, ref));
	error = iort_node_at(c, ref, &node, err);
	if (error != 0)
		return (error);
	if (node->Type == ACPI_IORT_NODE_SMMU_V3) {
		*smmu_off = ref;
		*out_id = id;
		return (0);
	}
	if (node->Type != ACPI_IORT_NODE_SMMU)
		return (GB10SMMU_IORT_ENODE);	/* not an SMMU at all */
	error = iort_maps_at(node, ref, &maps, err);
	if (error != 0)
		return (error);
	for (i = 0; maps != NULL && i < node->MappingCount; i++) {
		uint64_t lo = maps[i].InputBase;
		uint64_t hi = lo + maps[i].IdCount;
		uint32_t next;

		if ((uint64_t)id < lo || (uint64_t)id > hi)
			continue;
		next = maps[i].OutputBase;
		if ((maps[i].Flags & ACPI_IORT_ID_SINGLE_MAPPING) == 0)
			next += id - maps[i].InputBase;
		return (iort_resolve(c, maps[i].OutputReference, next, smmu_off,
		    out_id, depth + 1, err));
	}
	return (GB10SMMU_IORT_ENODE);
}

/*
 * iort_holder - is this node one of the nodes that hold the GPU's mappings?
 */
static int
iort_holder(const uint32_t *holders, int nholders, uint32_t off)
{
	int i;

	for (i = 0; i < nholders; i++) {
		if (holders[i] == off)
			return (1);
	}
	return (0);
}

/*
 * iort_map_range - the requester IDs and the stream IDs of a mapping.
 */
static void
iort_map_range(ACPI_IORT_ID_MAPPING *map, uint64_t *in_lo, uint64_t *in_hi,
    uint64_t *sid_lo, uint64_t *sid_hi)
{
	*in_lo = map->InputBase;
	*in_hi = (uint64_t)map->InputBase + map->IdCount;
	*sid_lo = map->OutputBase;
	if (map->Flags & ACPI_IORT_ID_SINGLE_MAPPING)
		*sid_hi = map->OutputBase;
	else
		*sid_hi = (uint64_t)map->OutputBase + map->IdCount;
}

/*
 * What one parse carries: the table, the question, the answer, and the
 * nodes that hold the GPU's mappings.
 */
struct iort_parse {
	struct iort_ctx			c;
	const struct gb10smmu_iort_query *query;
	struct gb10smmu_iort		*out;
	struct gb10smmu_iort_error	*err;
	uint32_t			holders[MAX_HOLDERS];
	int				nholders;
	uint32_t			gpu_smmu;
	int				have_smmu;
	uint64_t			rid_lo;
	uint64_t			rid_hi;
	int				have_rid;
};

/*
 * iort_read_root_complex - the data of a root complex node.
 *
 * The data is bounded by the node's own length, and the caller acts on the
 * error: a node that claims more than it holds is a table that does not
 * make sense.
 */
static int
iort_read_root_complex(ACPI_IORT_NODE *node, uint32_t off,
    const ACPI_IORT_ROOT_COMPLEX **rcp, struct gb10smmu_iort_error *err)
{
	const void *data;
	int error;

	error = iort_nodedata(node, off, IORT_RC_DATASIZE, &data, err);
	if (error != 0)
		return (error);
	*rcp = data;
	return (0);
}

/*
 * iort_read_named_component - the data of a named component node.
 *
 * The data is bounded like every other node's.  What it holds is of no
 * interest to the parser, so only the error is of interest to the caller.
 */
static int
iort_read_named_component(ACPI_IORT_NODE *node, uint32_t off,
    const void **datap, struct gb10smmu_iort_error *err)
{
	return (iort_nodedata(node, off, IORT_NC_DATASIZE, datap, err));
}

/*
 * iort_read_smmuv3 - the data of an SMMUv3 node.
 */
static int
iort_read_smmuv3(ACPI_IORT_NODE *node, uint32_t off,
    const ACPI_IORT_SMMU_V3 **smmup, struct gb10smmu_iort_error *err)
{
	const void *data;
	int error;

	error = iort_nodedata(node, off, IORT_SMMUV3_DATASIZE, &data, err);
	if (error != 0)
		return (error);
	*smmup = data;
	return (0);
}

/*
 * iort_read_rmr - the data of an RMR node.
 */
static int
iort_read_rmr(ACPI_IORT_NODE *node, uint32_t off,
    const ACPI_IORT_RMR **rmrp, struct gb10smmu_iort_error *err)
{
	const void *data;
	int error;

	error = iort_nodedata(node, off, IORT_RMR_DATASIZE, &data, err);
	if (error != 0)
		return (error);
	*rmrp = data;
	return (0);
}

/*
 * iort_read_rmr_descs - the RMR descriptor array of an RMR node.
 *
 * The array sits at RmrOffset from the start of the node and must fit in
 * the node: the count times the size of a descriptor, added to the offset,
 * must not pass the end of the node.
 */
static int
iort_read_rmr_descs(ACPI_IORT_NODE *node, uint32_t off,
    const ACPI_IORT_RMR *rmr, const ACPI_IORT_RMR_DESC **descp,
    struct gb10smmu_iort_error *err)
{
	if (rmr->RmrOffset < sizeof(ACPI_IORT_NODE))
		return (iort_err(err, GB10SMMU_IORT_EFORMAT,
		    "the RMR array overlaps the node header", off, node->Length,
		    node->Type, rmr->RmrOffset));
	if ((uint64_t)rmr->RmrOffset + (uint64_t)rmr->RmrCount *
	    sizeof(ACPI_IORT_RMR_DESC) > (uint64_t)node->Length)
		return (iort_err(err, GB10SMMU_IORT_EFORMAT,
		    "the RMR array does not fit in the node", off, node->Length,
		    node->Type, rmr->RmrCount));
	*descp = (const ACPI_IORT_RMR_DESC *)((const char *)node +
	    rmr->RmrOffset);
	return (0);
}

/*
 * iort_read_node - the node at an offset, and its ID mapping array.
 *
 * Every node's mapping array is checked, whether the node is one we use.
 */
static int
iort_read_node(struct iort_ctx *c, uint32_t off, ACPI_IORT_NODE **nodep,
    ACPI_IORT_ID_MAPPING **mapsp, struct gb10smmu_iort_error *err)
{
	ACPI_IORT_NODE *node;
	int error;

	error = iort_node_at(c, off, &node, err);
	if (error != 0)
		return (error);
	c->seen++;
	error = iort_maps_at(node, off, mapsp, err);
	if (error != 0)
		return (error);
	*nodep = node;
	return (0);
}

/*
 * What one ID mapping says.
 */
struct iort_mapinfo {
	uint64_t	lo;		/* the first requester ID */
	uint64_t	hi;		/* the last requester ID */
	uint64_t	sid_lo;		/* the first stream ID */
	uint64_t	sid_hi;		/* the last stream ID */
	uint32_t	next;		/* the stream ID it leads to */
	int		covers;		/* does it cover the GPU's ID? */
};

/*
 * iort_map_info - read one ID mapping.
 *
 * The mapping says which requester IDs it covers and which stream IDs they
 * become, whether it covers the GPU's requester ID, and the stream ID it
 * leads to: the output base, plus the offset of the GPU's requester ID
 * unless the mapping is a single one.
 */
static void
iort_map_info(ACPI_IORT_ID_MAPPING *map,
    const struct gb10smmu_iort_query *query, struct iort_mapinfo *info)
{
	iort_map_range(map, &info->lo, &info->hi, &info->sid_lo,
	    &info->sid_hi);
	info->covers = ((uint64_t)query->rid >= info->lo &&
	    (uint64_t)query->rid <= info->hi);
	info->next = (uint32_t)info->sid_lo;
	if ((map->Flags & ACPI_IORT_ID_SINGLE_MAPPING) == 0 && info->covers)
		info->next += query->rid - map->InputBase;
}

/*
 * iort_add_holder - remember a node that holds the GPU's mappings.
 */
static int
iort_add_holder(struct iort_parse *p, uint32_t off, ACPI_IORT_NODE *node)
{
	if (iort_holder(p->holders, p->nholders, off))
		return (0);
	if (p->nholders == MAX_HOLDERS)
		return (iort_err(p->err, GB10SMMU_IORT_ETOOBIG,
		    "too many nodes hold the mappings", off, node->Length,
		    node->Type, p->nholders));
	p->holders[p->nholders++] = off;
	return (0);
}

/*
 * What one node of the table is handed to.
 */
typedef int iort_walk_fn(struct iort_parse *p, uint32_t off,
    ACPI_IORT_NODE *node, ACPI_IORT_ID_MAPPING *maps);

/*
 * iort_walk - walk the table's nodes, one at a time.
 *
 * Every node's mapping array is checked, whether the node is one the
 * callback uses.  An error from the callback stops the walk: the table is
 * not walked past what does not make sense.
 */
static int
iort_walk(struct iort_parse *p, iort_walk_fn *fn)
{
	uint32_t off = p->c.first;
	int error;

	p->c.seen = 0;
	while (p->c.seen < p->c.count && off < p->c.len) {
		ACPI_IORT_NODE *node;
		ACPI_IORT_ID_MAPPING *maps;

		error = iort_read_node(&p->c, off, &node, &maps, p->err);
		if (error != 0)
			return (error);
		error = fn(p, off, node, maps);
		if (error != 0)
			return (error);
		off += node->Length;
	}
	return (0);
}

static int iort_pass1_mappings(struct iort_parse *p, uint32_t off,
    ACPI_IORT_NODE *node, ACPI_IORT_ID_MAPPING *maps);

/*
 * iort_pass1_node - what one node says about the GPU.
 *
 * A root complex holds the GPU's mappings when it is on the GPU's PCI
 * segment; a named component holds them wherever it is.  Every other node
 * holds nothing.
 */
static int
iort_pass1_node(struct iort_parse *p, uint32_t off, ACPI_IORT_NODE *node,
    ACPI_IORT_ID_MAPPING *maps)
{
	const ACPI_IORT_ROOT_COMPLEX *rc;
	const void *data;
	int is_holder = 0;
	int error;

	if (node->Type == ACPI_IORT_NODE_PCI_ROOT_COMPLEX) {
		error = iort_read_root_complex(node, off, &rc, p->err);
		if (error != 0)
			return (error);
		if (rc->PciSegmentNumber != p->query->seg)
			return (0);	/* another segment's GPU */
		is_holder = 1;
	} else if (node->Type == ACPI_IORT_NODE_NAMED_COMPONENT) {
		error = iort_read_named_component(node, off, &data, p->err);
		if (error != 0)
			return (error);
		is_holder = 1;
	}
	if (!is_holder)
		return (0);
	return (iort_pass1_mappings(p, off, node, maps));
}

/*
 * iort_pass1_mappings - the mappings of a holder that cover the GPU.
 *
 * The first mapping that covers the GPU's requester ID says which SMMU the
 * GPU is behind.  A second mapping that says something else is a table
 * that contradicts itself, and the parser says so instead of choosing.
 */
static int
iort_pass1_mappings(struct iort_parse *p, uint32_t off, ACPI_IORT_NODE *node,
    ACPI_IORT_ID_MAPPING *maps)
{
	uint32_t i;

	for (i = 0; maps != NULL && i < node->MappingCount; i++) {
		struct iort_mapinfo info;
		uint32_t smmu_off, out_id;
		int error;

		iort_map_info(&maps[i], p->query, &info);
		if (!info.covers)
			continue;
		error = iort_resolve(&p->c, maps[i].OutputReference, info.next,
		    &smmu_off, &out_id, 0, p->err);
		if (error == GB10SMMU_IORT_ENODE)
			continue;	/* it leads elsewhere */
		if (error != 0)
			return (error);
		if (!p->have_smmu) {
			p->have_smmu = 1;
			p->gpu_smmu = smmu_off;
			p->out->holder_node = off;
			p->out->holder_type = node->Type;
		} else if (p->gpu_smmu != smmu_off) {
			return (iort_err(p->err, GB10SMMU_IORT_EAMBIG,
			    "the requester ID leads to two SMMUs", off,
			    node->Length, node->Type, smmu_off));
		}
		error = iort_add_holder(p, off, node);
		if (error != 0)
			return (error);
	}
	return (0);
}

/*
 * iort_pass1 - the node that covers the GPU, and the SMMU it leads to.
 */
static int
iort_pass1(struct iort_parse *p)
{
	int error;

	error = iort_walk(p, iort_pass1_node);
	if (error != 0)
		return (error);
	if (!p->have_smmu)
		return (iort_err(p->err, GB10SMMU_IORT_ENODE,
		    "no mapping covers the GPU's requester ID", p->query->rid, 0,
		    0, p->query->rid));
	return (0);
}

/*
 * iort_read_smmu - the SMMU the GPU's requester ID leads to.
 */
static int
iort_read_smmu(struct iort_parse *p)
{
	ACPI_IORT_NODE *smmu_node;
	const ACPI_IORT_SMMU_V3 *smmu;
	int error;

	error = iort_node_at(&p->c, p->gpu_smmu, &smmu_node, p->err);
	if (error != 0)
		return (error);
	error = iort_read_smmuv3(smmu_node, p->gpu_smmu, &smmu, p->err);
	if (error != 0)
		return (error);
	memcpy(&p->out->smmu_base, &smmu->BaseAddress,
	    sizeof(p->out->smmu_base));
	p->out->smmu_model = smmu->Model;
	p->out->smmu_flags = smmu->Flags;
	p->out->smmu_node = p->gpu_smmu;
	return (0);
}

/*
 * iort_pass2_mappings - the stream-ID ranges of the GPU's mappings.
 *
 * Every mapping of a holder that leads to the GPU's SMMU is the GPU's:
 * its requester IDs can be split over several mappings, and all of them
 * are counted.
 */
static int
iort_pass2_mappings(struct iort_parse *p, uint32_t off, ACPI_IORT_NODE *node,
    ACPI_IORT_ID_MAPPING *maps)
{
	uint32_t i;

	for (i = 0; maps != NULL && i < node->MappingCount; i++) {
		struct iort_mapinfo info;
		uint32_t smmu_off, out_id;
		int error;

		iort_map_info(&maps[i], p->query, &info);
		error = iort_resolve(&p->c, maps[i].OutputReference, info.next,
		    &smmu_off, &out_id, 0, p->err);
		if (error == GB10SMMU_IORT_ENODE)
			continue;
		if (error != 0)
			return (error);
		if (smmu_off != p->gpu_smmu)
			continue;

		if (!p->have_rid) {
			p->rid_lo = info.lo;
			p->rid_hi = info.hi;
			p->have_rid = 1;
		} else {
			if (info.lo < p->rid_lo)
				p->rid_lo = info.lo;
			if (info.hi > p->rid_hi)
				p->rid_hi = info.hi;
		}
		if (p->out->nsid == GB10SMMU_MAX_SIDRANGE)
			return (iort_err(p->err, GB10SMMU_IORT_ETOOBIG,
			    "too many stream-ID ranges for the GPU", off,
			    node->Length, node->Type, p->out->nsid));
		p->out->sid[p->out->nsid].lo = maps[i].OutputBase;
		if (maps[i].Flags & ACPI_IORT_ID_SINGLE_MAPPING)
			p->out->sid[p->out->nsid].hi = maps[i].OutputBase;
		else
			p->out->sid[p->out->nsid].hi = (uint32_t)info.sid_hi;
		p->out->nsid++;
	}
	return (0);
}

/*
 * iort_pass2_node - one node's mappings, if the node holds the GPU's.
 */
static int
iort_pass2_node(struct iort_parse *p, uint32_t off, ACPI_IORT_NODE *node,
    ACPI_IORT_ID_MAPPING *maps)
{
	if (!iort_holder(p->holders, p->nholders, off))
		return (0);
	return (iort_pass2_mappings(p, off, node, maps));
}

/*
 * iort_pass2 - every mapping that leads to the GPU's SMMU.
 */
static int
iort_pass2(struct iort_parse *p)
{
	int error;

	error = iort_walk(p, iort_pass2_node);
	if (error != 0)
		return (error);
	if (p->out->nsid == 0)
		return (iort_err(p->err, GB10SMMU_IORT_ENODE,
		    "the GPU has no mapping to its SMMU", p->out->holder_node, 0,
		    p->out->holder_type, 0));
	p->out->rid_lo = (uint32_t)p->rid_lo;
	p->out->rid_hi = (uint32_t)p->rid_hi;
	return (0);
}

/*
 * iort_pass3_rmr - the RMR node's regions, if they are the GPU's.
 *
 * An RMR node names the node the reservation is for in its ID mapping: the
 * output reference is the root complex (or named component) the reserved
 * memory belongs to.
 */
static int
iort_pass3_rmr(struct iort_parse *p, uint32_t off, ACPI_IORT_NODE *node,
    ACPI_IORT_ID_MAPPING *maps)
{
	const ACPI_IORT_RMR *rmr;
	const ACPI_IORT_RMR_DESC *desc;
	uint32_t i;
	int error;

	error = iort_read_rmr(node, off, &rmr, p->err);
	if (error != 0)
		return (error);
	if (maps == NULL)
		return (0);
	for (i = 0; i < node->MappingCount; i++) {
		if (iort_holder(p->holders, p->nholders,
		    maps[i].OutputReference))
			break;
	}
	if (i == node->MappingCount)
		return (0);	/* the memory is not the GPU's */
	error = iort_read_rmr_descs(node, off, rmr, &desc, p->err);
	if (error != 0)
		return (error);
	for (i = 0; i < rmr->RmrCount; i++) {
		uint64_t base, len;

		if (desc[i].Length == 0)
			continue;
		memcpy(&base, &desc[i].BaseAddress, sizeof(base));
		memcpy(&len, &desc[i].Length, sizeof(len));
		p->out->nrmr_total++;
		if (p->out->nrmr < p->out->nrmr_max) {
			p->out->rmr[p->out->nrmr].base = base;
			p->out->rmr[p->out->nrmr].length = len;
			p->out->nrmr++;
		}
	}
	return (0);
}

/*
 * iort_pass3_node - one RMR node's regions, if the node is the GPU's.
 */
static int
iort_pass3_node(struct iort_parse *p, uint32_t off, ACPI_IORT_NODE *node,
    ACPI_IORT_ID_MAPPING *maps)
{
	if (node->Type != ACPI_IORT_NODE_RMR)
		return (0);
	return (iort_pass3_rmr(p, off, node, maps));
}

/*
 * iort_pass3 - the memory the firmware reserves for the GPU.
 */
static int
iort_pass3(struct iort_parse *p)
{
	int error;

	error = iort_walk(p, iort_pass3_node);
	if (error != 0)
		return (error);
	/*
	 * More RMR regions than the caller can hold is not something to
	 * swallow: the caller is told how many there are and parses again
	 * with room for them.  Nothing is mapped from a truncated list.
	 */
	if (p->out->nrmr_total > p->out->nrmr_max)
		return (iort_err(p->err, GB10SMMU_IORT_ETOOBIG,
		    "more RMR regions than the caller can hold", 0, 0, 0,
		    (uint64_t)p->out->nrmr_total));
	return (0);
}

/*
 * gb10smmu_iort_parse - read the GPU's facts out of an ACPI IORT table.
 *
 * The table is walked three times:
 *
 *   1. the node that covers the GPU's segment and requester ID, and the
 *      SMMUv3 node its mappings lead to;
 *   2. every mapping of that node (and of every other node that covers the
 *      GPU's requester ID) that leads to that SMMU: the GPU's stream IDs,
 *      all of them, not the first one found;
 *   3. the RMR nodes that reserve memory for the GPU's node.
 *
 * The table is small (about a kilobyte), so three passes are cheaper than
 * building a list of nodes.
 */
int
gb10smmu_iort_parse(const void *table, size_t tablelen,
    const struct gb10smmu_iort_query *query, struct gb10smmu_iort *out,
    struct gb10smmu_iort_error *err)
{
	const ACPI_TABLE_HEADER *hdr = table;
	const ACPI_TABLE_IORT *iort = table;
	struct gb10smmu_rmr *rmr_store = out->rmr;
	int rmr_max = out->nrmr_max;
	struct iort_parse p;
	int error;

	memset(out, 0, sizeof(*out));
	out->rmr = rmr_store;
	out->nrmr_max = rmr_max;

	if (tablelen < sizeof(ACPI_TABLE_HEADER) ||
	    hdr->Length < sizeof(ACPI_TABLE_IORT) ||
	    hdr->Length > tablelen)
		return (iort_err(err, GB10SMMU_IORT_EFORMAT,
		    "the table is not a usable IORT", 0, hdr->Length, 0,
		    (uint64_t)tablelen));
	if (memcmp(hdr->Signature, ACPI_SIG_IORT,
	    sizeof(hdr->Signature)) != 0)
		return (iort_err(err, GB10SMMU_IORT_EFORMAT,
		    "the table is not an IORT", 0, hdr->Length, 0, 0));
	if (iort->NodeCount == 0)
		return (iort_err(err, GB10SMMU_IORT_ENODE,
		    "the IORT has no nodes", 0, hdr->Length, 0, 0));
	if (iort->NodeOffset < sizeof(ACPI_TABLE_IORT) ||
	    iort->NodeOffset > hdr->Length)
		return (iort_err(err, GB10SMMU_IORT_EFORMAT,
		    "the first node is outside the table", iort->NodeOffset,
		    hdr->Length, 0, iort->NodeOffset));

	memset(&p, 0, sizeof(p));
	p.query = query;
	p.out = out;
	p.err = err;
	p.c.base = (char *)(uintptr_t)table;
	p.c.len = hdr->Length;
	p.c.first = iort->NodeOffset;
	p.c.count = iort->NodeCount;

	/*
	 * Pass 1: the node that covers the GPU's segment and requester ID,
	 * and the SMMUv3 node its mappings lead to.
	 */
	error = iort_pass1(&p);
	if (error != 0)
		return (error);
	error = iort_read_smmu(&p);
	if (error != 0)
		return (error);

	/*
	 * Pass 2: every mapping that leads to the GPU's SMMU, from the nodes
	 * that hold them.  The GPU may have more than one: its requester IDs
	 * can be split over several mappings, and all of them are the GPU's.
	 */
	error = iort_pass2(&p);
	if (error != 0)
		return (error);

	/*
	 * Pass 3: the memory the firmware reserves for the GPU.  An RMR node
	 * names the node the reservation is for in its ID mapping: the output
	 * reference is the root complex (or named component) the reserved
	 * memory belongs to.
	 */
	error = iort_pass3(&p);
	if (error != 0)
		return (error);
	return (0);
}

/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-3-Clause
 *
 * gb10smmu_iort_test - the IORT parser of gb10smmu, run outside the kernel.
 *
 * The parser is the same source the module builds (src/gb10-smmu/gb10smmu_iort.c);
 * this test builds hand-made IORT tables and says what the parser must do
 * with them.  Every case that guards a fix fails against the parser that
 * fix was made for.
 *
 * Cases:
 *   (a) a valid table: the SMMU, the stream IDs and the RMR regions
 *   (b) a node that ends outside the table
 *   (c) a mapping array that does not fit in its node
 *   (d) two SMMUv3 nodes, the GPU on the second one
 *   (e) two mappings for the GPU: both are the GPU's
 *   (f) more RMR regions than the caller can hold, and with room for them
 *   (g) an RMR descriptor array that does not fit in its node
 *   (h) a malformed node before the RMR node: the error is not swallowed
 *   (i) a requester ID that leads to two SMMUs: refused, not guessed
 *   (j) a table that claims more nodes than it holds: refused, not used
 *   (k) a table that holds more nodes than it claims: refused, not used
 *   (l) a mapping whose count leaves the ID space: refused
 *   (m) the count is the number of IDs minus one: the range and the IDs
 *       that are not in it
 *   (n) a chain of root complex and SMMU: the stream ID of the SMMUv3
 *   (o) the requester ID of the GPU picks the SMMU
 *
 * Run: sh tests/gb10smmu_test.sh (this file is built and run by it)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "gb10smmu_iort.h"

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
 * A table under construction.
 */
struct tbl {
	unsigned char	buf[8192];
	size_t		len;
	uint32_t	nodes;
};

static void
tbl_init(struct tbl *t)
{
	ACPI_TABLE_IORT *iort = (ACPI_TABLE_IORT *)t->buf;

	memset(t, 0, sizeof(*t));
	memcpy(iort->Header.Signature, ACPI_SIG_IORT,
	    sizeof(iort->Header.Signature));
	iort->Header.Length = sizeof(ACPI_TABLE_IORT);
	iort->Header.Revision = 1;
	memcpy(iort->Header.OemId, "TEST    ", 8);
	memcpy(iort->Header.OemTableId, "TESTIORT", 8);
	iort->NodeCount = 0;
	iort->NodeOffset = sizeof(ACPI_TABLE_IORT);
	iort->Reserved = 0;
	t->len = sizeof(ACPI_TABLE_IORT);
}

/* The offset of a new node; the node is empty until it is filled in. */
static uint32_t
node_new(struct tbl *t, uint8_t type)
{
	uint32_t off = (uint32_t)t->len;

	memset(t->buf + t->len, 0, sizeof(ACPI_IORT_NODE));
	t->buf[off] = type;
	t->buf[off + 3] = 1;			/* Revision */
	t->len += sizeof(ACPI_IORT_NODE);
	t->nodes++;
	return (off);
}

/* Append n bytes of node-specific data; the offset of the data is returned. */
static size_t
node_data(struct tbl *t, size_t n)
{
	size_t at = t->len;

	memset(t->buf + t->len, 0, n);
	t->len += n;
	return (at);
}

/* Append an ID mapping to the node that starts at off. */
static uint32_t
node_map(struct tbl *t, uint32_t off, uint32_t in_base, uint32_t id_count,
    uint32_t out_base, uint32_t out_ref)
{
	ACPI_IORT_ID_MAPPING *m = (ACPI_IORT_ID_MAPPING *)(t->buf + t->len);
	uint32_t at = (uint32_t)t->len;

	m->InputBase = in_base;
	m->IdCount = id_count;
	m->OutputBase = out_base;
	m->OutputReference = out_ref;
	m->Flags = 0;
	t->len += sizeof(ACPI_IORT_ID_MAPPING);
	/* The mapping array is the last thing in the node, so its offset is
	 * where the first mapping went. */
	{
		ACPI_IORT_NODE *n = (ACPI_IORT_NODE *)(t->buf + off);
		uint32_t count = n->MappingCount + 1;

		if (count == 1)
			n->MappingOffset = at - off;
		n->MappingCount = count;
	}
	return (at);
}

/* Close the node: its length is what it grew to. */
static void
node_end(struct tbl *t, uint32_t off)
{
	ACPI_IORT_NODE *n = (ACPI_IORT_NODE *)(t->buf + off);
	uint16_t len = (uint16_t)(t->len - off);

	n->Length = len;
}

/* Close the table. */
static void
tbl_end(struct tbl *t)
{
	ACPI_TABLE_IORT *iort = (ACPI_TABLE_IORT *)t->buf;

	iort->Header.Length = (uint32_t)t->len;
	iort->NodeCount = t->nodes;
}

/* An SMMUv3 node; the offset of the node is returned. */
static uint32_t
add_smmuv3(struct tbl *t, uint64_t base)
{
	uint32_t off = node_new(t, ACPI_IORT_NODE_SMMU_V3);
	ACPI_IORT_SMMU_V3 *s;

	s = (ACPI_IORT_SMMU_V3 *)(t->buf + node_data(t, 52));
	s->BaseAddress = base;
	s->Flags = 0;
	s->Model = 0;
	node_end(t, off);
	return (off);
}

/* A PCI root complex node with one mapping; the offset is returned. */
static uint32_t
add_root_complex(struct tbl *t, uint32_t seg, uint32_t in_base,
    uint32_t id_count, uint32_t out_base, uint32_t out_ref)
{
	uint32_t off = node_new(t, ACPI_IORT_NODE_PCI_ROOT_COMPLEX);
	ACPI_IORT_ROOT_COMPLEX *rc;

	rc = (ACPI_IORT_ROOT_COMPLEX *)(t->buf + node_data(t, 20));
	rc->PciSegmentNumber = seg;
	rc->MemoryAddressLimit = 40;
	node_map(t, off, in_base, id_count, out_base, out_ref);
	node_end(t, off);
	return (off);
}

/* An RMR node for the node at holder; the offset is returned. */
static uint32_t
add_rmr(struct tbl *t, uint32_t holder, uint32_t count)
{
	uint32_t off = node_new(t, ACPI_IORT_NODE_RMR);
	ACPI_IORT_RMR *rmr;
	uint32_t i;

	rmr = (ACPI_IORT_RMR *)(t->buf + node_data(t, 12));
	rmr->Flags = 0;
	rmr->RmrCount = count;
	node_map(t, off, 0, 0, 0, holder);
	rmr->RmrOffset = (uint32_t)(t->len - off);
	for (i = 0; i < count; i++) {
		ACPI_IORT_RMR_DESC *d =
		    (ACPI_IORT_RMR_DESC *)(t->buf + t->len);

		d->BaseAddress = 0x300000000ULL + (uint64_t)i * 0x1000000ULL;
		d->Length = 0x1000000ULL;
		d->Reserved = 0;
		t->len += sizeof(ACPI_IORT_RMR_DESC);
	}
	node_end(t, off);
	return (off);
}

/*
 * An SMMU (v2) node with one mapping; the offset of the node is returned.
 *
 * The node is the one in the middle of a chain: the root complex maps the
 * GPU's requester ID onto it, and it maps that ID on to the SMMUv3.
 */
static uint32_t
add_smmuv2(struct tbl *t, uint32_t in_base, uint32_t id_count,
    uint32_t out_base, uint32_t out_ref)
{
	uint32_t off = node_new(t, ACPI_IORT_NODE_SMMU);
	ACPI_IORT_SMMU *smmu;

	smmu = (ACPI_IORT_SMMU *)(t->buf + node_data(t, 32));
	smmu->BaseAddress = 0x12000000;
	smmu->Span = 0x1000;
	smmu->Model = 0;
	smmu->Flags = 0;
	node_map(t, off, in_base, id_count, out_base, out_ref);
	node_end(t, off);
	return (off);
}

static const struct gb10smmu_iort_query gpu_query = { 0, 0x00 };

/* What the parser is given, and what it said about it. */
static struct gb10smmu_iort out;
static struct gb10smmu_iort_error err;
static struct gb10smmu_rmr rmrs[64];

/*
 * parse - the parser's answer to a table.
 *
 * The caller says how much room it gives the parser for the RMR regions.
 * The parser gets a clean output and a clean error every time, so one case
 * cannot see what another one left behind.
 */
static int
parse_rid(struct tbl *t, int nrmr_max, uint32_t rid)
{
	struct gb10smmu_iort_query query = { 0, rid };

	memset(&out, 0, sizeof(out));
	memset(&err, 0, sizeof(err));
	out.rmr = rmrs;
	out.nrmr_max = nrmr_max;
	return (gb10smmu_iort_parse(t->buf, t->len, &query, &out, &err));
}

static int
parse(struct tbl *t, int nrmr_max)
{
	return (parse_rid(t, nrmr_max, gpu_query.rid));
}

/*
 * case_valid - (a) a valid table: the SMMU, the stream IDs and the RMR
 * regions.
 */
static void
case_valid(void)
{
	struct tbl t;
	uint32_t smmu, rc;

	tbl_init(&t);
	smmu = add_smmuv3(&t, 0x13000000);
	rc = add_root_complex(&t, 0, 0x000, 0x1ff, 0x000, smmu);
	add_rmr(&t, rc, 3);
	tbl_end(&t);
	CHECK(parse(&t, 64) == GB10SMMU_IORT_OK, "(a) a valid table parses");
	CHECK(out.smmu_base == 0x13000000, "(a) the SMMU base address is read");
	CHECK(out.smmu_node == smmu, "(a) the SMMU node is found");
	CHECK(out.nsid == 1, "(a) the GPU has one stream-ID range");
	CHECK(out.nsid == 1 && out.sid[0].lo == 0x000 &&
	    out.sid[0].hi == 0x1ff, "(a) the stream IDs are the mapping's");
	CHECK(out.nrmr == 3, "(a) the three RMR regions are read");
	CHECK(out.nrmr == 3 && out.rmr[0].base == 0x300000000ULL &&
	    out.rmr[0].length == 0x1000000ULL, "(a) the RMR regions are right");
	CHECK(out.holder_node == rc, "(a) the node that holds the mapping");
}

/*
 * case_bad_node - (b) a node that ends outside the table.
 */
static void
case_bad_node(void)
{
	struct tbl t;
	uint32_t smmu, rc;

	tbl_init(&t);
	smmu = add_smmuv3(&t, 0x13000000);
	rc = add_root_complex(&t, 0, 0x000, 0x1ff, 0x000, smmu);
	add_rmr(&t, rc, 1);
	tbl_end(&t);
	/* The last node claims to be longer than the table is. */
	{
		ACPI_IORT_NODE *n = (ACPI_IORT_NODE *)(t.buf + rc);

		n->Length = 0x4000;
	}
	CHECK(parse(&t, 64) == GB10SMMU_IORT_EFORMAT,
	    "(b) a node that ends outside the table is refused");
	CHECK(err.node == rc, "(b) the error names the node");
}

/*
 * case_bad_mapping - (c) a mapping array that does not fit in its node.
 */
static void
case_bad_mapping(void)
{
	struct tbl t;
	uint32_t smmu, rc;

	tbl_init(&t);
	smmu = add_smmuv3(&t, 0x13000000);
	rc = add_root_complex(&t, 0, 0x000, 0x1ff, 0x000, smmu);
	tbl_end(&t);
	{
		ACPI_IORT_NODE *n = (ACPI_IORT_NODE *)(t.buf + rc);

		/* Four mappings are claimed; the node holds one. */
		n->MappingCount = 4;
	}
	CHECK(parse(&t, 64) == GB10SMMU_IORT_EFORMAT,
	    "(c) a mapping array past the end of its node is refused");
	CHECK(err.node == rc, "(c) the error names the node");
}

/*
 * case_two_smmus - (d) two SMMUv3 nodes, the GPU on the second one.
 */
static void
case_two_smmus(void)
{
	struct tbl t;
	uint32_t other, smmu, rc;

	tbl_init(&t);
	other = add_smmuv3(&t, 0x11111000);
	smmu = add_smmuv3(&t, 0x13000000);
	rc = add_root_complex(&t, 0, 0x000, 0x1ff, 0x000, smmu);
	add_rmr(&t, rc, 1);
	tbl_end(&t);
	CHECK(parse(&t, 64) == GB10SMMU_IORT_OK,
	    "(d) the table with two SMMUs parses");
	CHECK(out.smmu_node == smmu,
	    "(d) the SMMU of the GPU is the one the mapping names");
	CHECK(out.smmu_base == 0x13000000,
	    "(d) the base address is the second SMMU's");
	CHECK(other != out.smmu_node,
	    "(d) the first SMMU is not the one that is programmed");
}

/*
 * case_two_mappings - (e) two mappings for the GPU: both are the GPU's.
 */
static void
case_two_mappings(void)
{
	struct tbl t;
	uint32_t smmu;

	tbl_init(&t);
	smmu = add_smmuv3(&t, 0x13000000);
	{
		uint32_t off = node_new(&t, ACPI_IORT_NODE_PCI_ROOT_COMPLEX);
		ACPI_IORT_ROOT_COMPLEX *r;

		r = (ACPI_IORT_ROOT_COMPLEX *)(t.buf + node_data(&t, 20));
		r->PciSegmentNumber = 0;
		r->MemoryAddressLimit = 40;
		node_map(&t, off, 0x000, 0x00f, 0x100, smmu);
		node_map(&t, off, 0x010, 0x00f, 0x200, smmu);
		node_end(&t, off);
	}
	tbl_end(&t);
	CHECK(parse(&t, 64) == GB10SMMU_IORT_OK,
	    "(e) the table with two GPU mappings parses");
	CHECK(out.nsid == 2, "(e) both mappings of the GPU are found");
	CHECK(out.nsid == 2 && out.sid[0].lo == 0x100 && out.sid[0].hi == 0x10f &&
	    out.sid[1].lo == 0x200 && out.sid[1].hi == 0x20f,
	    "(e) the two stream-ID ranges are the mapping's");
}

/*
 * case_too_many_rmrs - (f) more RMR regions than the caller can hold, and
 * with room for them.
 */
static void
case_too_many_rmrs(void)
{
	struct tbl t;
	uint32_t smmu, rc;

	tbl_init(&t);
	smmu = add_smmuv3(&t, 0x13000000);
	rc = add_root_complex(&t, 0, 0x000, 0x1ff, 0x000, smmu);
	add_rmr(&t, rc, 33);
	tbl_end(&t);
	CHECK(parse(&t, 32) == GB10SMMU_IORT_ETOOBIG,
	    "(f) 33 RMR regions do not fit in 32: the parser says so");
	CHECK(out.nrmr_total == 33, "(f) the parser says how many there are");
	CHECK(parse(&t, 33) == GB10SMMU_IORT_OK,
	    "(f) with room for 33 the table parses");
	CHECK(out.nrmr == 33, "(f) all 33 RMR regions are read");
}

/*
 * case_bad_rmr_array - (g) an RMR descriptor array that does not fit in its
 * node.
 */
static void
case_bad_rmr_array(void)
{
	struct tbl t;
	uint32_t smmu, rc;

	tbl_init(&t);
	smmu = add_smmuv3(&t, 0x13000000);
	rc = add_root_complex(&t, 0, 0x000, 0x1ff, 0x000, smmu);
	{
		uint32_t rmr = add_rmr(&t, rc, 4);
		ACPI_IORT_RMR *r = (ACPI_IORT_RMR *)(t.buf + rmr + 16);

		r->RmrCount = 64;		/* more than the node holds */
	}
	tbl_end(&t);
	CHECK(parse(&t, 64) == GB10SMMU_IORT_EFORMAT,
	    "(g) an RMR array past the end of its node is refused");
}

/*
 * case_bad_node_before_rmr - (h) a malformed node before the RMR node: the
 * error is not swallowed.
 */
static void
case_bad_node_before_rmr(void)
{
	struct tbl t;
	uint32_t smmu, rc;

	tbl_init(&t);
	smmu = add_smmuv3(&t, 0x13000000);
	rc = add_root_complex(&t, 0, 0x000, 0x1ff, 0x000, smmu);
	{
		uint32_t broken = node_new(&t, ACPI_IORT_NODE_NAMED_COMPONENT);

		node_data(&t, 17);
		/* A mapping array that does not fit in the node. */
		node_map(&t, broken, 0, 0, 0, smmu);
		node_end(&t, broken);
		/* The mapping array is claimed to be past the end of the node. */
		((ACPI_IORT_NODE *)(t.buf + broken))->MappingOffset = 0x1000;
	}
	add_rmr(&t, rc, 2);
	tbl_end(&t);
	CHECK(parse(&t, 64) == GB10SMMU_IORT_EFORMAT,
	    "(h) a malformed node before the RMR node is refused, not skipped");
	CHECK(out.nrmr == 0, "(h) no RMR region is read from a bad table");
}

/*
 * add_two_smmus - a table with two SMMUv3 nodes and a root complex node
 * that has no mappings yet; the caller adds the mappings it needs.
 *
 * The offset of the root complex node is returned.
 */
static uint32_t
add_two_smmus(struct tbl *t, uint32_t *first, uint32_t *second)
{
	uint32_t rc;

	*first = add_smmuv3(t, 0x11111000);
	*second = add_smmuv3(t, 0x22222000);
	rc = node_new(t, ACPI_IORT_NODE_PCI_ROOT_COMPLEX);
	{
		ACPI_IORT_ROOT_COMPLEX *r;

		r = (ACPI_IORT_ROOT_COMPLEX *)(t->buf + node_data(t, 20));
		r->PciSegmentNumber = 0;
		r->MemoryAddressLimit = 40;
	}
	return (rc);
}

/*
 * case_two_smmus_one_rid - (i) a requester ID that leads to two SMMUs:
 * refused, not guessed.
 */
static void
case_two_smmus_one_rid(void)
{
	struct tbl t;
	uint32_t first, second, rc;

	tbl_init(&t);
	rc = add_two_smmus(&t, &first, &second);
	node_map(&t, rc, 0x000, 0x01f, 0x000, first);
	node_map(&t, rc, 0x000, 0x01f, 0x100, second);
	node_end(&t, rc);
	tbl_end(&t);
	CHECK(parse(&t, 64) == GB10SMMU_IORT_EAMBIG,
	    "(i) a requester ID that leads to two SMMUs is refused, not guessed");
}

/*
 * case_short_node_list - (j) a table that claims more nodes than it holds:
 * refused, not used.  The parser never answers from half a table.
 */
static void
case_short_node_list(void)
{
	struct tbl t;
	uint32_t smmu, rc;
	ACPI_TABLE_IORT *iort;

	tbl_init(&t);
	smmu = add_smmuv3(&t, 0x13000000);
	rc = add_root_complex(&t, 0, 0x000, 0x1ff, 0x000, smmu);
	add_rmr(&t, rc, 1);
	tbl_end(&t);
	/* The header claims one node more than the table holds. */
	iort = (ACPI_TABLE_IORT *)t.buf;
	iort->NodeCount = t.nodes + 1;
	CHECK(parse(&t, 64) == GB10SMMU_IORT_EFORMAT,
	    "(j) a table that claims more nodes than it holds is refused");
	CHECK(err.seen == t.nodes,
	    "(j) the error says how many nodes the table held");
	CHECK(err.value == t.nodes + 1,
	    "(j) the error says how many nodes the table claimed");
	CHECK(err.node != 0, "(j) the error names the offset it stopped at");
}

/*
 * case_long_node_list - (k) a table that holds more nodes than it claims:
 * refused, not used.  The node the header does not count may be the one
 * that matters.
 */
static void
case_long_node_list(void)
{
	struct tbl t;
	uint32_t smmu, rc;
	ACPI_TABLE_IORT *iort;

	tbl_init(&t);
	smmu = add_smmuv3(&t, 0x13000000);
	rc = add_root_complex(&t, 0, 0x000, 0x1ff, 0x000, smmu);
	add_rmr(&t, rc, 1);
	tbl_end(&t);
	/* The header claims one node fewer than the table holds. */
	iort = (ACPI_TABLE_IORT *)t.buf;
	iort->NodeCount = t.nodes - 1;
	CHECK(parse(&t, 64) == GB10SMMU_IORT_EFORMAT,
	    "(k) a table that holds more nodes than it claims is refused");
	CHECK(err.seen == t.nodes - 1,
	    "(k) the error says how many nodes the walk did see");
}

/*
 * case_bad_count - (l) a mapping whose count leaves the ID space: the
 * mapping describes no range at all, and it is refused.
 */
static void
case_bad_count(void)
{
	struct tbl t;
	uint32_t smmu, rc;

	tbl_init(&t);
	smmu = add_smmuv3(&t, 0x13000000);
	/* The range would end above the largest ID there is. */
	rc = add_root_complex(&t, 0, 0x000, 0x00f, 0x000, smmu);
	{
		ACPI_IORT_ID_MAPPING *m =
		    (ACPI_IORT_ID_MAPPING *)(t.buf + rc +
		    ((ACPI_IORT_NODE *)(t.buf + rc))->MappingOffset);

		m->InputBase = 0x00000100;
		m->IdCount = 0xffffff00;
	}
	tbl_end(&t);
	CHECK(parse(&t, 64) == GB10SMMU_IORT_EFORMAT,
	    "(l) a mapping whose range leaves the ID space is refused");
	CHECK(err.node == rc, "(l) the error names the node");
}

/*
 * case_count_range - (m) the count is the number of IDs minus one, as Arm
 * DEN 0049D defines it and as FreeBSD's own reader reads it: the last ID
 * of the range is InputBase + IdCount, and a count of zero is a range of
 * one ID.  The IDs that are not in the range are not in it.
 */
static void
case_count_range(void)
{
	struct tbl t;
	uint32_t smmu, rc;

	tbl_init(&t);
	smmu = add_smmuv3(&t, 0x13000000);
	rc = add_root_complex(&t, 0, 0x000, 0x1ff, 0x000, smmu);
	tbl_end(&t);
	/* The count is 0x1ff, so the range is 0x000-0x1ff: 0x200 IDs. */
	CHECK(parse_rid(&t, 64, 0x1ff) == GB10SMMU_IORT_OK,
	    "(m) the last ID of the range is the one the count names");
	CHECK(out.nsid == 1 && out.sid[0].lo == 0x000 &&
	    out.sid[0].hi == 0x1ff, "(m) the range is the one the count names");
	CHECK(out.holder_node == rc, "(m) the node that holds the mapping");
	CHECK(parse_rid(&t, 64, 0x200) == GB10SMMU_IORT_ENODE,
	    "(m) the ID after the range is not in the range");
	/* A count of zero is a range of one ID, not a range of none. */
	{
		uint32_t one = add_root_complex(&t, 0, 0x300, 0x000, 0x300,
		    smmu);

		tbl_end(&t);
		CHECK(parse_rid(&t, 64, 0x300) == GB10SMMU_IORT_OK,
		    "(m) a count of zero is a range of one ID");
		CHECK(out.nsid == 1 && out.sid[0].lo == 0x300 &&
		    out.sid[0].hi == 0x300,
		    "(m) a count of zero covers exactly one ID");
		CHECK(parse_rid(&t, 64, 0x301) == GB10SMMU_IORT_ENODE,
		    "(m) the ID after a one-ID range is not in it");
		(void)one;
	}
}

/*
 * case_nested_chain - (n) a chain of root complex and SMMU: the stream ID
 * that is programmed is the one the SMMUv3 has, not the one of the node in
 * between.
 */
static void
case_nested_chain(void)
{
	struct tbl t;
	uint32_t smmu, smmu2, rc;

	tbl_init(&t);
	smmu = add_smmuv3(&t, 0x13000000);
	/* The SMMU (v2) maps the ID 0x40 onto the stream ID 0x100. */
	smmu2 = add_smmuv2(&t, 0x040, 0x000, 0x100, smmu);
	/* The root complex maps the requester ID 0 onto the ID 0x40. */
	rc = add_root_complex(&t, 0, 0x000, 0x000, 0x040, smmu2);
	tbl_end(&t);
	CHECK(parse(&t, 64) == GB10SMMU_IORT_OK,
	    "(n) the table with a chain parses");
	CHECK(out.smmu_node == smmu,
	    "(n) the SMMU of the GPU is the one the chain ends at");
	CHECK(out.holder_node == rc, "(n) the node that holds the mapping");
	CHECK(out.nsid == 1, "(n) the GPU has one stream-ID range");
	CHECK(out.nsid == 1 && out.sid[0].lo == 0x100 &&
	    out.sid[0].hi == 0x100,
	    "(n) the stream ID is the one the chain resolves to");
	CHECK(out.nsid == 1 && out.sid[0].lo != 0x040,
	    "(n) the stream ID is not the one of the node in between");
}

/*
 * case_rid_picks_smmu - (o) the requester ID of the GPU picks the SMMU:
 * the SMMU of the mapping that covers it, and no other.
 */
static void
case_rid_picks_smmu(void)
{
	struct tbl t;
	uint32_t first, second, rc;

	tbl_init(&t);
	rc = add_two_smmus(&t, &first, &second);
	node_map(&t, rc, 0x000, 0x00f, 0x000, first);
	node_map(&t, rc, 0x100, 0x00f, 0x100, second);
	node_end(&t, rc);
	tbl_end(&t);
	CHECK(parse_rid(&t, 64, 0x008) == GB10SMMU_IORT_OK,
	    "(o) the table with two mappings parses");
	CHECK(out.smmu_node == first,
	    "(o) the requester ID in the first mapping gets the first SMMU");
	CHECK(out.smmu_base == 0x11111000,
	    "(o) the base address is the first SMMU's");
	CHECK(parse_rid(&t, 64, 0x108) == GB10SMMU_IORT_OK,
	    "(o) the requester ID in the second mapping parses");
	CHECK(out.smmu_node == second,
	    "(o) the requester ID in the second mapping gets the second SMMU");
	CHECK(out.smmu_base == 0x22222000,
	    "(o) the base address is the second SMMU's");
	CHECK(out.nsid == 1 && out.sid[0].lo == 0x100 &&
	    out.sid[0].hi == 0x10f,
	    "(o) the stream IDs are the ones of the mapping that covers it");
}

/*
 * The cases, in the order the file's comment lists them.
 */
static const struct {
	const char	*what;		/* what the case is about */
	void		(*run)(void);	/* what it does */
} cases[] = {
	{ "(a) a valid table", case_valid },
	{ "(b) a node that ends outside the table", case_bad_node },
	{ "(c) a mapping array that does not fit in its node",
	    case_bad_mapping },
	{ "(d) two SMMUv3 nodes, the GPU on the second one", case_two_smmus },
	{ "(e) two mappings for the GPU: both are the GPU's",
	    case_two_mappings },
	{ "(f) more RMR regions than the caller can hold",
	    case_too_many_rmrs },
	{ "(g) an RMR descriptor array that does not fit in its node",
	    case_bad_rmr_array },
	{ "(h) a malformed node before the RMR node",
	    case_bad_node_before_rmr },
	{ "(i) a requester ID that leads to two SMMUs",
	    case_two_smmus_one_rid },
	{ "(j) a table that claims more nodes than it holds",
	    case_short_node_list },
	{ "(k) a table that holds more nodes than it claims",
	    case_long_node_list },
	{ "(l) a mapping whose count leaves the ID space",
	    case_bad_count },
	{ "(m) the count is the number of IDs minus one", case_count_range },
	{ "(n) a chain of root complex and SMMU", case_nested_chain },
	{ "(o) the requester ID of the GPU picks the SMMU",
	    case_rid_picks_smmu },
};

int
main(void)
{
	size_t i;

	for (i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
		printf("# %s\n", cases[i].what);
		cases[i].run();
	}
	printf("passed: %d failed: %d\n", passed, failed);
	return (failed == 0 ? 0 : 1);
}

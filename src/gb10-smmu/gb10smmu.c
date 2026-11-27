/*
 * Copyright (c) 2026 SkunkWerks, GmbH
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * gb10smmu: minimal bring-up of the SMMUv3 in front of the GB10 GPU
 * (SMMU base 0x13000000, PCI segment 0xf, StreamID = PCI RID), for
 * diagnosis.  FreeBSD leaves this SMMU disabled (global bypass); Linux
 * enables it.  This module programs it by hand, without interrupts:
 *
 *   - linear stream table, 2^11 entries; every STE is BYPASS except
 *     StreamIDs sid_lo..sid_hi (default 0x000-0x1ff: buses 0 and 1 of the
 *     segment, i.e. the root port and the GPU), which use stage-2 translation;
 *   - gb10smmu.mode=1 "trap": the stage-2 table identity-maps only the
 *     firmware RMR regions (gb10smmu.rmr=0 leaves even those out); every
 *     other access is terminated and recorded in the event queue;
 *   - gb10smmu.mode=2 "ident": the stage-2 table identity-maps 0-512 GiB
 *     with 1 GiB blocks.
 *
 * The event queue is polled from a callout.  sysctl debug.gb10smmu.dump=1
 * prints the state and the saved events.  Unloading disables the SMMU again
 * (back to global bypass).
 *
 * Tunables (kenv, before kldload): gb10smmu.mode (required, 1 or 2),
 * gb10smmu.base, gb10smmu.sid_lo, gb10smmu.sid_hi, gb10smmu.rmr,
 * gb10smmu.eats (STE.EATS of the stage-2 SIDs: 0 refuse ATS translation
 * requests, 1 full ATS (default); BOOT 106 showed that the GPU's FWSEC sends
 * ATS translation requests for the GSP-FMC image).
 *
 * Register and structure layouts follow the Arm SMMUv3 specification
 * (IHI 0070); names as in sys/arm64/iommu/smmureg.h.
 */
#include <sys/param.h>
#include <sys/systm.h>
#include <sys/kernel.h>
#include <sys/module.h>
#include <sys/malloc.h>
#include <sys/callout.h>
#include <sys/sysctl.h>
#include <vm/vm.h>
#include <vm/pmap.h>
#include <machine/atomic.h>
#include <machine/vmparam.h>

#define	R_IDR0		0x000
#define	R_IDR1		0x004
#define	R_IDR5		0x014
#define	R_CR0		0x020
#define	 CR0_SMMUEN	(1u << 0)
#define	 CR0_EVENTQEN	(1u << 2)
#define	 CR0_CMDQEN	(1u << 3)
#define	R_CR0ACK	0x024
#define	R_CR1		0x028
#define	R_CR2		0x02c
#define	R_GBPA		0x044
#define	R_IRQ_CTRL	0x050
#define	R_GERROR	0x060
#define	R_GERRORN	0x064
#define	R_STRTAB_BASE	0x080
#define	R_STRTAB_CFG	0x088
#define	R_CMDQ_BASE	0x090
#define	R_CMDQ_PROD	0x098
#define	R_CMDQ_CONS	0x09c
#define	R_EVENTQ_BASE	0x0a0
#define	R_EVENTQ_PROD	0x100a8
#define	R_EVENTQ_CONS	0x100ac
#define	MAPSIZE		0x20000

#define	STRTAB_LOG2	11		/* SIDs 0-0x7ff (HDA0 is 0x500) */
#define	CMDQ_LOG2	5
#define	EVTQ_LOG2	10
#define	NSAVED		256

#define	GIB		(1ULL << 30)
#define	MIB2		(1ULL << 21)

/* Stage-2 descriptors, 4K granule. */
#define	S2_BLOCK	0x1ULL
#define	S2_TABLE	0x3ULL
#define	S2_AF		(1ULL << 10)
#define	S2_SH_IS	(3ULL << 8)
#define	S2_AP_RW	(3ULL << 6)
#define	S2_MEM_WB	(0xfULL << 2)	/* Normal, write-back */
#define	S2_MEM_DEV	(0x1ULL << 2)	/* Device-nGnRE */
#define	S2_XN		(1ULL << 54)

static MALLOC_DEFINE(M_GB10SMMU, "gb10smmu", "gb10smmu tables");

static struct {
	char		*va;
	u_long		base;
	int		mode, rmr, eats, enabled;
	u_long		sid_lo, sid_hi;
	uint64_t	*strtab, *cmdq, *evtq, *l1, *l2a, *l2b;
	uint32_t	cmd_prod;
	struct callout	co;
	uint64_t	nevents, noverflow;
	u_int		nsaved, nprinted;
	uint64_t	saved[NSAVED][4];
	sbintime_t	saved_t[NSAVED];
} sc;

static const struct { uint64_t start, size; } rmrs[] = {
	{ 0x300000000ULL, 0x3000000ULL },	/* iGPU _CRS range, 48 MiB */
	{ 0x280000000ULL, 0x80000000ULL },	/* 2 GiB */
	{ 0x0a1600000ULL, 0x18200000ULL },	/* WPR carveout, 386 MiB */
};

static uint32_t
rd4(u_int off)
{
	return (*(volatile uint32_t *)(sc.va + off));
}

static void
wr4(u_int off, uint32_t v)
{
	*(volatile uint32_t *)(sc.va + off) = v;
}

static void
wr8(u_int off, uint64_t v)
{
	*(volatile uint64_t *)(sc.va + off) = v;
}

static void *
alloc_tbl(size_t size)
{
	/* Naturally aligned, zeroed, below the SMMU's 40-bit output size. */
	return (contigmalloc(size, M_GB10SMMU, M_WAITOK | M_ZERO, 0,
	    (1ULL << 40) - 1, MAX(size, PAGE_SIZE), 0));
}

static int
cr0_set(uint32_t v)
{
	int i;

	wr4(R_CR0, v);
	for (i = 0; i < 100000; i++) {
		if (rd4(R_CR0ACK) == v)
			return (0);
		DELAY(1);
	}
	printf("gb10smmu: CR0 %#x not acknowledged (CR0ACK %#x)\n", v,
	    rd4(R_CR0ACK));
	return (ETIMEDOUT);
}

static void
cmd_put(uint64_t w0, uint64_t w1)
{
	u_int idx = sc.cmd_prod & ((1u << CMDQ_LOG2) - 1);

	sc.cmdq[idx * 2] = w0;
	sc.cmdq[idx * 2 + 1] = w1;
	sc.cmd_prod = (sc.cmd_prod + 1) & ((1u << (CMDQ_LOG2 + 1)) - 1);
}

static int
cmd_flush(void)
{
	uint32_t cons;
	int i;

	cmd_put(0x46, 0);			/* CMD_SYNC, no signal */
	wmb();
	wr4(R_CMDQ_PROD, sc.cmd_prod);
	for (i = 0; i < 100000; i++) {
		cons = rd4(R_CMDQ_CONS);
		if ((cons & ((1u << (CMDQ_LOG2 + 1)) - 1)) == sc.cmd_prod &&
		    ((rd4(R_GERROR) ^ rd4(R_GERRORN)) & 1) == 0)
			return (0);
		DELAY(1);
	}
	printf("gb10smmu: command queue stuck: PROD %#x CONS %#x GERROR %#x "
	    "GERRORN %#x\n", rd4(R_CMDQ_PROD), rd4(R_CMDQ_CONS),
	    rd4(R_GERROR), rd4(R_GERRORN));
	return (ETIMEDOUT);
}

static void
print_event(u_int i)
{
	uint64_t *e = sc.saved[i];

	printf("gb10smmu: ev[%u] t=%jd.%06jd type %#x sid %#x %s%s addr "
	    "%#018jx ipa %#018jx raw %016jx %016jx\n", i,
	    (intmax_t)(sc.saved_t[i] / SBT_1S),
	    (intmax_t)((sc.saved_t[i] % SBT_1S) / SBT_1US),
	    (u_int)(e[0] & 0xff), (u_int)(e[0] >> 32),
	    (e[0] & 0xff) == 0x05 ? "ATS-TREQ" :
	    (e[1] & (1ULL << 35)) ? "read" : "write",
	    (e[1] & (1ULL << 39)) ? " S2" : "",
	    (uintmax_t)e[2], (uintmax_t)e[3], (uintmax_t)e[0],
	    (uintmax_t)e[1]);
}

static void
evtq_poll(void *arg)
{
	const uint32_t imask = (1u << EVTQ_LOG2) - 1;
	const uint32_t wmask = (1u << (EVTQ_LOG2 + 1)) - 1;
	uint32_t prod, cons;
	uint64_t *e;
	u_int n = 0;

	prod = rd4(R_EVENTQ_PROD);
	cons = rd4(R_EVENTQ_CONS);
	if ((prod ^ cons) & 0x80000000u)
		sc.noverflow++;
	while ((prod & wmask) != (cons & wmask)) {
		e = &sc.evtq[(cons & imask) * 4];
		sc.nevents++;
		if (sc.nsaved < NSAVED) {
			memcpy(sc.saved[sc.nsaved], e, 32);
			sc.saved_t[sc.nsaved] = sbinuptime();
			sc.nsaved++;
		}
		cons = (cons + 1) & wmask;
		n++;
	}
	if (n != 0 || ((prod ^ rd4(R_EVENTQ_CONS)) & 0x80000000u))
		wr4(R_EVENTQ_CONS, cons | (prod & 0x80000000u));
	/* Print the first few as they arrive; the rest on demand. */
	while (sc.nprinted < sc.nsaved && sc.nprinted < 48)
		print_event(sc.nprinted++);
	if (sc.enabled)
		callout_schedule(&sc.co, 1);
}

static void
dump_state(void)
{
	u_int i;

	printf("gb10smmu: mode %d CR0 %#x CR0ACK %#x GBPA %#x GERROR %#x "
	    "GERRORN %#x CMDQ P/C %#x/%#x EVQ P/C %#x/%#x\n", sc.mode,
	    rd4(R_CR0), rd4(R_CR0ACK), rd4(R_GBPA), rd4(R_GERROR),
	    rd4(R_GERRORN), rd4(R_CMDQ_PROD), rd4(R_CMDQ_CONS),
	    rd4(R_EVENTQ_PROD), rd4(R_EVENTQ_CONS));
	printf("gb10smmu: events %ju (saved %u), overflows seen %ju\n",
	    (uintmax_t)sc.nevents, sc.nsaved, (uintmax_t)sc.noverflow);
	for (i = 0; i < sc.nsaved; i++)
		print_event(i);
}

static int
sysctl_dump(SYSCTL_HANDLER_ARGS)
{
	int error, v = 0;

	error = sysctl_handle_int(oidp, &v, 0, req);
	if (error != 0 || req->newptr == NULL)
		return (error);
	if (v != 0 && sc.va != NULL)
		dump_state();
	return (0);
}

static SYSCTL_NODE(_debug, OID_AUTO, gb10smmu, CTLFLAG_RD | CTLFLAG_MPSAFE, 0,
    "gb10smmu");
SYSCTL_PROC(_debug_gb10smmu, OID_AUTO, dump,
    CTLTYPE_INT | CTLFLAG_RW | CTLFLAG_MPSAFE, NULL, 0, sysctl_dump, "I",
    "write 1 to print the SMMU state and the saved events");
SYSCTL_U64(_debug_gb10smmu, OID_AUTO, events, CTLFLAG_RD, &sc.nevents, 0,
    "events taken from the event queue");
SYSCTL_INT(_debug_gb10smmu, OID_AUTO, mode, CTLFLAG_RD, &sc.mode, 0,
    "1 = trap, 2 = identity");

static void
build_s2(void)
{
	const uint64_t blk = S2_BLOCK | S2_AF | S2_SH_IS | S2_AP_RW;
	uint64_t a;
	u_int i, r;

	sc.l1 = alloc_tbl(PAGE_SIZE);
	if (sc.mode == 2) {
		/* 0-2 GiB is MMIO (MSI doorbell included): device attributes. */
		for (i = 0; i < 512; i++)
			sc.l1[i] = (i * GIB) | blk |
			    (i < 2 ? (S2_MEM_DEV | S2_XN) : S2_MEM_WB);
		return;
	}
	if (!sc.rmr)
		return;
	sc.l2a = alloc_tbl(PAGE_SIZE);		/* GiB 2: 0x80000000 */
	sc.l2b = alloc_tbl(PAGE_SIZE);		/* GiB 12: 0x300000000 */
	sc.l1[2] = vtophys(sc.l2a) | S2_TABLE;
	sc.l1[12] = vtophys(sc.l2b) | S2_TABLE;
	for (r = 0; r < nitems(rmrs); r++) {
		for (a = rmrs[r].start; a < rmrs[r].start + rmrs[r].size; ) {
			if ((a & (GIB - 1)) == 0 &&
			    a + GIB <= rmrs[r].start + rmrs[r].size) {
				sc.l1[a / GIB] = a | blk | S2_MEM_WB;
				a += GIB;
				continue;
			}
			KASSERT((a & (MIB2 - 1)) == 0, ("rmr alignment"));
			i = (a & (GIB - 1)) / MIB2;
			if (a / GIB == 2)
				sc.l2a[i] = a | blk | S2_MEM_WB;
			else if (a / GIB == 12)
				sc.l2b[i] = a | blk | S2_MEM_WB;
			else
				printf("gb10smmu: no L2 table for %#jx\n",
				    (uintmax_t)a);
			a += MIB2;
		}
	}
}

static int
gb10smmu_start(void)
{
	uint64_t ste0, ste1, ste2, ste3;
	u_long sid;
	int error;

	sc.base = 0x13000000;
	sc.sid_lo = 0x000;
	sc.sid_hi = 0x1ff;
	sc.rmr = 1;
	sc.eats = 1;
	TUNABLE_ULONG_FETCH("gb10smmu.base", &sc.base);
	TUNABLE_ULONG_FETCH("gb10smmu.sid_lo", &sc.sid_lo);
	TUNABLE_ULONG_FETCH("gb10smmu.sid_hi", &sc.sid_hi);
	TUNABLE_INT_FETCH("gb10smmu.rmr", &sc.rmr);
	TUNABLE_INT_FETCH("gb10smmu.eats", &sc.eats);
	TUNABLE_INT_FETCH("gb10smmu.mode", &sc.mode);
	if (sc.mode != 1 && sc.mode != 2) {
		printf("gb10smmu: set kenv gb10smmu.mode=1 (trap) or 2 "
		    "(identity) first\n");
		return (EINVAL);
	}
	if (sc.sid_hi >= (1u << STRTAB_LOG2) || sc.sid_lo > sc.sid_hi ||
	    sc.eats < 0 || sc.eats > 2)
		return (EINVAL);

	sc.va = pmap_mapdev(sc.base, MAPSIZE);
	if (sc.va == NULL)
		return (ENOMEM);
	printf("gb10smmu: base %#lx IDR0 %08x IDR1 %08x IDR5 %08x CR0 %08x "
	    "GBPA %08x\n", sc.base, rd4(R_IDR0), rd4(R_IDR1), rd4(R_IDR5),
	    rd4(R_CR0), rd4(R_GBPA));
	if (rd4(R_CR0) != 0 || (rd4(R_IDR0) & 1) == 0 ||
	    (rd4(R_IDR1) & (3u << 29)) != 0) {
		printf("gb10smmu: SMMU already enabled, no stage 2, or preset "
		    "tables/queues; not touching it\n");
		pmap_unmapdev(sc.va, MAPSIZE);
		sc.va = NULL;
		return (EBUSY);
	}

	sc.strtab = alloc_tbl((size_t)64 << STRTAB_LOG2);
	sc.cmdq = alloc_tbl(PAGE_SIZE);
	sc.evtq = alloc_tbl((size_t)32 << EVTQ_LOG2);
	build_s2();

	ste0 = 1 | (0x6ULL << 1);		/* V, stage-2 translation */
	ste1 = 1ULL << 44;			/* SHCFG = incoming */
	ste1 |= (uint64_t)sc.eats << 28;	/* EATS: 0 refuse, 1 full ATS */
	ste2 = 1 |				/* S2VMID 1 */
	    (25ULL << 32) |			/* S2T0SZ: 39-bit IPA */
	    (1ULL << 38) |			/* S2SL0: start at level 1 */
	    (1ULL << 40) | (1ULL << 42) |	/* S2IR0/S2OR0: WB */
	    (3ULL << 44) |			/* S2SH0: inner shareable */
	    (2ULL << 48) |			/* S2PS: 40 bits */
	    (1ULL << 51) |			/* S2AA64 */
	    (1ULL << 58);			/* S2R: record faults; no stall */
	ste3 = vtophys(sc.l1) & 0x000ffffffffffff0ULL;
	for (sid = 0; sid < (1u << STRTAB_LOG2); sid++) {
		uint64_t *s = &sc.strtab[sid * 8];

		if (sid >= sc.sid_lo && sid <= sc.sid_hi) {
			s[0] = ste0; s[1] = ste1; s[2] = ste2; s[3] = ste3;
		} else {
			s[0] = 1 | (0x4ULL << 1);	/* V, bypass */
			s[1] = 1ULL << 44;
		}
	}
	wmb();

	wr4(R_IRQ_CTRL, 0);
	/* Tables and queues: inner shareable, write-back cacheable. */
	wr4(R_CR1, (3u << 10) | (1u << 8) | (1u << 6) | (3u << 4) | (1u << 2) |
	    (1u << 0));
	wr4(R_CR2, (1u << 2) | (1u << 1));	/* PTM, RECINVSID */
	wr8(R_STRTAB_BASE, vtophys(sc.strtab) | (1ULL << 62));
	wr4(R_STRTAB_CFG, STRTAB_LOG2);		/* linear */
	wr8(R_CMDQ_BASE, vtophys(sc.cmdq) | (1ULL << 62) | CMDQ_LOG2);
	wr4(R_CMDQ_PROD, 0);
	wr4(R_CMDQ_CONS, 0);
	wr8(R_EVENTQ_BASE, vtophys(sc.evtq) | (1ULL << 62) | EVTQ_LOG2);
	wr4(R_EVENTQ_PROD, 0);
	wr4(R_EVENTQ_CONS, 0);

	error = cr0_set(CR0_CMDQEN);
	if (error == 0) {
		cmd_put(0x04, 31);		/* CMD_CFGI_STE_RANGE, all */
		cmd_put(0x30, 0);		/* CMD_TLBI_NSNH_ALL */
		error = cmd_flush();
	}
	if (error == 0)
		error = cr0_set(CR0_CMDQEN | CR0_EVENTQEN);
	if (error == 0)
		error = cr0_set(CR0_CMDQEN | CR0_EVENTQEN | CR0_SMMUEN);
	if (error != 0) {
		/* Back to global bypass; keep the memory, it may be in use. */
		wr4(R_CR0, 0);
		printf("gb10smmu: enable failed (%d), SMMU left disabled, "
		    "CR0ACK %#x\n", error, rd4(R_CR0ACK));
		return (error);
	}
	sc.enabled = 1;
	callout_init(&sc.co, 1);
	callout_reset(&sc.co, 1, evtq_poll, NULL);
	printf("gb10smmu: enabled, mode %s%s, stage-2 SIDs %#lx-%#lx EATS %d, others "
	    "bypass; strtab %#jx l1 %#jx evtq %#jx\n",
	    sc.mode == 1 ? "trap" : "identity",
	    sc.mode == 1 ? (sc.rmr ? " (RMR regions mapped)" : " (nothing "
	    "mapped)") : "", sc.sid_lo, sc.sid_hi, sc.eats,
	    (uintmax_t)vtophys(sc.strtab), (uintmax_t)vtophys(sc.l1),
	    (uintmax_t)vtophys(sc.evtq));
	dump_state();
	return (0);
}

static int
gb10smmu_stop(void)
{
	if (sc.va == NULL)
		return (0);
	if (sc.enabled) {
		sc.enabled = 0;
		callout_drain(&sc.co);
		evtq_poll(NULL);
		dump_state();
		/* SMMUEN off first: streams return to global bypass. */
		if (cr0_set(CR0_CMDQEN | CR0_EVENTQEN) != 0 ||
		    cr0_set(0) != 0) {
			printf("gb10smmu: could not disable the SMMU; refusing "
			    "to unload\n");
			sc.enabled = 1;
			callout_reset(&sc.co, 1, evtq_poll, NULL);
			return (EBUSY);
		}
		wr8(R_STRTAB_BASE, 0);
		wr4(R_STRTAB_CFG, 0);
		wr8(R_CMDQ_BASE, 0);
		wr8(R_EVENTQ_BASE, 0);
		wr4(R_CR1, 0);
		wr4(R_CR2, 0);
		free(sc.strtab, M_GB10SMMU);
		free(sc.cmdq, M_GB10SMMU);
		free(sc.evtq, M_GB10SMMU);
		free(sc.l1, M_GB10SMMU);
		free(sc.l2a, M_GB10SMMU);
		free(sc.l2b, M_GB10SMMU);
	}
	pmap_unmapdev(sc.va, MAPSIZE);
	sc.va = NULL;
	return (0);
}

static int
gb10smmu_modevent(module_t mod, int type, void *data)
{
	switch (type) {
	case MOD_LOAD:
		return (gb10smmu_start());
	case MOD_UNLOAD:
		return (gb10smmu_stop());
	default:
		return (EOPNOTSUPP);
	}
}

static moduledata_t gb10smmu_mod = { "gb10smmu", gb10smmu_modevent, NULL };
DECLARE_MODULE(gb10smmu, gb10smmu_mod, SI_SUB_DRIVERS, SI_ORDER_ANY);
MODULE_VERSION(gb10smmu, 1);

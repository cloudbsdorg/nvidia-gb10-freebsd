/*
 * Copyright (c) 2026 SkunkWerks, GmbH
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * gb10smmu: minimal bring-up of the SMMUv3 in front of the GB10 GPU.
 * FreeBSD leaves this SMMU disabled (global bypass); Linux enables it.
 * This module programs it by hand, without interrupts:
 *
 *   - linear stream table, 2^11 entries; every STE is BYPASS except the
 *     stream IDs the IORT gives for the GPU, which use stage-2 translation;
 *   - gb10smmu.mode=1 "trap": the stage-2 table maps only the RMR regions
 *     the IORT reserves for the GPU (gb10smmu.rmr=0 leaves even those out);
 *     every other access is terminated and recorded in the event queue;
 *   - gb10smmu.mode=2 "ident": the stage-2 table identity-maps 0-512 GiB
 *     with 1 GiB blocks.
 *
 * Every fact the module programs comes from the device, not from a
 * constant: the SMMU base address, the stream IDs and the RMR regions are
 * read from the ACPI IORT table (AcpiGetTable("IORT", ...)), which is
 * where the firmware says where the SMMU is, which PCI requester IDs map
 * to which stream IDs and which memory ranges are reserved for the GPU.
 * The IORT is read by gb10smmu_iort.c, which bounds every read against the
 * table and against the node it belongs to, and which fails on anything it
 * cannot make sense of.  There is no best effort in it: a table that does
 * not add up means the module does not attach.
 *
 * The addresses the first version of this module hardcoded are kept only
 * as a cross-check: when the IORT says something else, the module says so
 * and programs what the IORT says.  A hardcoded address belongs to one
 * board; the IORT belongs to the machine the module runs on.
 *
 * When the IORT has no SMMUv3 node for the GPU, the module refuses to
 * attach and says why: there is nothing to program, and another board's
 * constants are not a substitute for the machine's own description.
 *
 * The module must be loaded before the nvidia(4) driver: the GPU
 * translates its addresses while its firmware starts, which is before the
 * driver opens the device.  The module refuses to attach while the nvidia
 * driver is attached to a device, and refuses to unload while it is.
 *
 * The event queue is polled from a callout.  sysctl debug.gb10smmu.dump=1
 * prints the state and the saved events.  Unloading disables the SMMU again
 * (back to global bypass).
 *
 * Tunables (kenv, before kldload): gb10smmu.mode (required, 1 or 2),
 * gb10smmu.rmr (map the RMR regions in mode 1), gb10smmu.eats (STE.EATS of
 * the stage-2 SIDs: 0 refuse ATS translation requests, 1 full ATS (default);
 * BOOT 106 showed that the GPU's FWSEC sends ATS translation requests for
 * the GSP-FMC image), gb10smmu.seg and gb10smmu.rid (the PCI segment and
 * requester ID of the GPU, which say which node of the IORT is the GPU's;
 * they default to 0, which is where a single-segment machine has it).
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
#include <sys/bus.h>
#include <sys/mutex.h>
#include <vm/vm.h>
#include <vm/pmap.h>
#include <machine/atomic.h>
#include <machine/vmparam.h>
#include <contrib/dev/acpica/include/acpi.h>

#include "gb10smmu_iort.h"
#include "gb10smmu_gpu.h"

/*
 * The PCI ivars the module reads.  They are named in dev/pci/pcivar.h, a
 * header a module cannot include (it pulls in the generated PCI interface
 * header of the kernel build), so the ones the module reads are named
 * here: they are the third, the fourth and the twelfth to the fifteenth
 * of the list that starts at BUS_IVARS_PRIVATE.
 */
#define	GB10_PCI_IVAR_VENDOR	(BUS_IVARS_PRIVATE + 2)
#define	GB10_PCI_IVAR_DEVICE	(BUS_IVARS_PRIVATE + 3)
#define	GB10_PCI_IVAR_DOMAIN	(BUS_IVARS_PRIVATE + 11)
#define	GB10_PCI_IVAR_BUS	(BUS_IVARS_PRIVATE + 12)
#define	GB10_PCI_IVAR_SLOT	(BUS_IVARS_PRIVATE + 13)
#define	GB10_PCI_IVAR_FUNCTION	(BUS_IVARS_PRIVATE + 14)

/*
 * Is this device on a PCI bus?  The kernel declares it in
 * sys/dev/pci/pcivar.h, a header a module cannot include.
 */
extern bool is_pci_device(device_t dev);

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

/* The stage-2 table covers 512 GiB; one L1 entry per GiB. */
#define	L1_ENTRIES	512

/*
 * The facts the first version of this module hardcoded.  They are the
 * facts of one board (an ASUS Ascent GX10) and are kept only to say when
 * the IORT says something else; the module always programs what the IORT
 * says.
 */
#define	XCHECK_BASE	0x13000000UL
#define	XCHECK_SID_LO	0x000UL
#define	XCHECK_SID_HI	0x1ffUL
static const struct { uint64_t start, size; } xcheck_rmrs[] = {
	{ 0x300000000ULL, 0x3000000ULL },	/* iGPU _CRS range, 48 MiB */
	{ 0x280000000ULL, 0x80000000ULL },	/* 2 GiB */
	{ 0x0a1600000ULL, 0x18200000ULL },	/* WPR carveout, 386 MiB */
};

/*
 * The GPU the module programs the SMMU of is an NVIDIA GB10 (GB20B): the
 * module finds that device in the device tree of the running machine
 * before it touches anything, and the SMMU it programs is the one the
 * machine says stands in front of that GPU.  The identity of the device
 * and the rules about it are in gb10smmu_gpu.h.
 */
static MALLOC_DEFINE(M_GB10SMMU, "gb10smmu", "gb10smmu tables");

static struct {
	char		*va;
	u_long		base;
	int		mode, rmr, eats, enabled;
	uint64_t	*strtab, *cmdq, *evtq, *l1, **l2;
	uint32_t	cmd_prod;
	struct callout	co;
	uint64_t	nevents, noverflow;
	u_int		nsaved, nprinted;
	uint64_t	saved[NSAVED][4];
	sbintime_t	saved_t[NSAVED];

	/* What the IORT says. */
	uint64_t	iort_base;		/* the SMMUv3 base address */
	uint32_t	iort_model;
	uint32_t	iort_flags;
	uint32_t	iort_node;		/* the SMMUv3 node */
	uint32_t	iort_holder;		/* the node that holds them */
	uint32_t	iort_holder_type;	/* and what kind of node */
	uint32_t	iort_rid_lo;		/* the requester IDs of it */
	uint32_t	iort_rid_hi;
	int		nsid;			/* the stream-ID ranges */
	struct gb10smmu_sidrange sid[GB10SMMU_MAX_SIDRANGE];
	struct gb10smmu_rmr	*rmrs;		/* the memory reserved for it */
	int		nrmrs;

	/* The GPU in the machine, found in the device tree. */
	device_t	gpu_dev;		/* the GPU itself */
	uint32_t	gpu_vendor;		/* its PCI vendor ID */
	uint32_t	gpu_device;		/* its PCI device ID */
	uint32_t	gpu_seg;		/* its PCI segment number */
	uint32_t	gpu_rid;		/* its PCI requester ID */
	char		gpu_name[64];		/* its name in the device tree */
} sc;

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

/*
 * nvidia_attached - is the nvidia driver attached to a device?
 *
 * The module must be loaded before the nvidia driver and must not be
 * unloaded while it is: the GPU translates its addresses while its
 * firmware starts and keeps translating them afterwards, so an SMMU that
 * goes back to global bypass under a running driver leaves the GPU with a
 * translation table it can no longer answer.
 *
 * The device tree is walked for a device the nvidia driver has claimed.
 */
static int
nvidia_dev_attached(device_t dev)
{
	device_t *children;
	const char *name;
	int n, i, found = 0;

	name = device_get_name(dev);
	if (name != NULL && strncmp(name, "nvidia", 6) == 0)
		return (1);
	if (device_get_children(dev, &children, &n) != 0)
		return (0);
	for (i = 0; i < n; i++) {
		if (nvidia_dev_attached(children[i]))
			found = 1;
	}
	/* The list of the children is the kernel's own allocation. */
	free(children, M_DEVBUF);
	return (found);
}

static int
nvidia_attached(void)
{
	/* The GPU's own device says who drives it. */
	if (sc.gpu_dev != NULL && device_get_driver(sc.gpu_dev) != NULL)
		return (1);
	return (nvidia_dev_attached(root_bus));
}

/*
 * gb10smmu_gpu_pci - the PCI facts of a device.
 *
 * The facts are read from the PCI bus the device is on, which is where the
 * kernel keeps them: its vendor and device ID, its segment (domain)
 * number, and where it sits on the bus.  The requester ID of a PCI device
 * is the bus it is on, its slot and its function, in the PCI's own layout.
 */
struct gb10smmu_pci {
	uint32_t	vendor;
	uint32_t	device;
	uint32_t	domain;
	uint32_t	rid;
};

static int
gb10smmu_gpu_pci(device_t dev, struct gb10smmu_pci *pci)
{
	uintptr_t vendor, deviceid, domain, bus, slot, func;
	device_t parent = device_get_parent(dev);

	if (parent == NULL)
		return (EINVAL);
	if (BUS_READ_IVAR(parent, dev, GB10_PCI_IVAR_VENDOR, &vendor) != 0 ||
	    BUS_READ_IVAR(parent, dev, GB10_PCI_IVAR_DEVICE, &deviceid) != 0 ||
	    BUS_READ_IVAR(parent, dev, GB10_PCI_IVAR_DOMAIN, &domain) != 0 ||
	    BUS_READ_IVAR(parent, dev, GB10_PCI_IVAR_BUS, &bus) != 0 ||
	    BUS_READ_IVAR(parent, dev, GB10_PCI_IVAR_SLOT, &slot) != 0 ||
	    BUS_READ_IVAR(parent, dev, GB10_PCI_IVAR_FUNCTION, &func) != 0)
		return (EINVAL);
	pci->vendor = (uint32_t)vendor;
	pci->device = (uint32_t)deviceid;
	pci->domain = (uint32_t)domain;
	pci->rid = gb10smmu_requester_id((uint32_t)bus, (uint32_t)slot,
	    (uint32_t)func);
	return (0);
}

/*
 * gb10smmu_find_gpu - the GB10 GPU in the running machine.
 *
 * The module programs the SMMU of one device: the NVIDIA GB10.  It finds
 * that device in the device tree of the running machine and takes its PCI
 * identity from there, so the SMMU the module programs is the one the
 * machine says stands in front of that GPU.  A machine without the GPU has
 * no SMMU of ours to program: the module refuses to attach rather than
 * program an SMMU that belongs to another device.
 */
static int
gb10smmu_find_gpu(device_t dev)
{
	device_t *children;
	struct gb10smmu_pci pci;
	int n, i, found;

	if (is_pci_device(dev) && gb10smmu_gpu_pci(dev, &pci) == 0 &&
	    gb10smmu_is_gb10(pci.vendor, pci.device)) {
		sc.gpu_dev = dev;
		sc.gpu_vendor = pci.vendor;
		sc.gpu_device = pci.device;
		sc.gpu_seg = pci.domain;
		sc.gpu_rid = pci.rid;
		strlcpy(sc.gpu_name, device_get_name(dev), sizeof(sc.gpu_name));
		return (1);
	}
	if (device_get_children(dev, &children, &n) != 0)
		return (0);
	found = 0;
	for (i = 0; i < n; i++) {
		if (gb10smmu_find_gpu(children[i]))
			found = 1;
	}
	/* The list of the children is the kernel's own allocation. */
	free(children, M_DEVBUF);
	return (found);
}

/*
 * gb10smmu_hold - the holds that keep the nvidia driver out.
 *
 * The check for the nvidia driver and the change of the SMMU have to be
 * one thing: if the driver can attach between the check and the change,
 * the module programs an SMMU under a running driver, or takes the tables
 * away from one.  The module's own lock and the bus-level hold are taken
 * before the check and given up after the change, so a device that comes
 * in at that moment waits for the module and not the other way round.
 */
static struct mtx sc_lock;

static void
gb10smmu_hold(void)
{
	mtx_lock(&sc_lock);
	bus_topo_lock();
}

static void
gb10smmu_unhold(void)
{
	bus_topo_unlock();
	mtx_unlock(&sc_lock);
}

/*
 * read_iort - the GPU's facts, out of the ACPI IORT table.
 *
 * The table is read by the parser in gb10smmu_iort.c, which bounds every
 * read and fails on anything it cannot make sense of.  Every failure here
 * stops the module: it does not attach with half an answer.
 *
 * The question the table is asked is about the GPU the machine has: its
 * PCI segment number and its PCI requester ID come from the device tree,
 * so the table is read for that device and for no other.  The loader
 * variables override them for a machine whose firmware describes the GPU
 * somewhere else.
 */
static int
read_iort(void)
{
	ACPI_TABLE_HEADER *hdr = NULL;
	struct gb10smmu_iort out;
	struct gb10smmu_iort_error err;
	struct gb10smmu_iort_query query;
	int error, i;
	int seg, rid;

	seg = (int)sc.gpu_seg;
	rid = (int)sc.gpu_rid;
	TUNABLE_INT_FETCH("gb10smmu.seg", &seg);
	TUNABLE_INT_FETCH("gb10smmu.rid", &rid);
	if (seg < 0 || rid < 0) {
		printf("gb10smmu: the segment and requester ID of the GPU must "
		    "not be negative\n");
		return (EINVAL);
	}
	query.seg = (uint32_t)seg;
	query.rid = (uint32_t)rid;

	if (!ACPI_SUCCESS(AcpiGetTable(ACPI_SIG_IORT, 1, &hdr)) ||
	    hdr == NULL) {
		printf("gb10smmu: refusing to attach: this firmware does not "
		    "expose the ACPI IORT the SMMU facts come from; use "
		    "firmware that exposes it before loading nvidia.ko\n");
		return (ENXIO);
	}

	/*
	 * The number of RMR regions comes from the table, so the array they
	 * go into is sized from it: the first pass counts them and says how
	 * many there are, the second one fills them.
	 */
	memset(&out, 0, sizeof(out));
	for (;;) {
		memset(&err, 0, sizeof(err));
		error = gb10smmu_iort_parse(hdr, hdr->Length, &query,
		    &out, &err);
		if (error != GB10SMMU_IORT_ETOOBIG || out.nrmr_total == 0)
			break;
		free(sc.rmrs, M_GB10SMMU);
		sc.rmrs = malloc(sizeof(struct gb10smmu_rmr) * out.nrmr_total,
		    M_GB10SMMU, M_WAITOK | M_ZERO);
		if (sc.rmrs == NULL) {
			printf("gb10smmu: no memory for the %d memory regions "
			    "the IORT reserves for the GPU\n", out.nrmr_total);
			AcpiPutTable(hdr);
			return (ENOMEM);
		}
		out.rmr = sc.rmrs;
		out.nrmr_max = out.nrmr_total;
	}
	if (error != GB10SMMU_IORT_OK) {
		printf("gb10smmu: refusing to attach: the IORT cannot be used: "
		    "%s (node %#x, type %#x, length %u, value %ju, seen %u)\n",
		    err.what != NULL ? err.what : "it does not make sense",
		    err.node, err.node_type, err.node_len,
		    (uintmax_t)err.value, err.seen);
		free(sc.rmrs, M_GB10SMMU);
		sc.rmrs = NULL;
		AcpiPutTable(hdr);
		return (EINVAL);
	}

	sc.iort_base = out.smmu_base;
	sc.iort_model = out.smmu_model;
	sc.iort_flags = out.smmu_flags;
	sc.iort_node = out.smmu_node;
	sc.iort_holder = out.holder_node;
	sc.iort_holder_type = out.holder_type;
	sc.iort_rid_lo = out.rid_lo;
	sc.iort_rid_hi = out.rid_hi;
	sc.nsid = out.nsid;
	for (i = 0; i < out.nsid; i++)
		sc.sid[i] = out.sid[i];
	sc.nrmrs = out.nrmr;

	printf("gb10smmu: IORT SMMUv3 node at %#x: base %#lx model %#x "
	    "flags %#x\n", sc.iort_node, (u_long)sc.iort_base,
	    sc.iort_model, sc.iort_flags);
	printf("gb10smmu: IORT node at %#x (type %#x) holds the GPU: "
	    "requester IDs %#x-%#x\n", sc.iort_holder, sc.iort_holder_type,
	    sc.iort_rid_lo, sc.iort_rid_hi);
	for (i = 0; i < sc.nsid; i++)
		printf("gb10smmu: IORT ID mapping %d: stream IDs %#x-%#x\n", i,
		    sc.sid[i].lo, sc.sid[i].hi);
	for (i = 0; i < sc.nrmrs; i++)
		printf("gb10smmu: IORT RMR %d: %#jx+%#jx\n", i,
		    (uintmax_t)sc.rmrs[i].base, (uintmax_t)sc.rmrs[i].length);
	if (sc.nrmrs == 0)
		printf("gb10smmu: the IORT reserves no memory for the GPU\n");

	AcpiPutTable(hdr);
	return (0);
}

/*
 * cross_check - say when the IORT says something else than the values the
 * first version of this module hardcoded.  The IORT wins.
 */
static void
cross_check(void)
{
	uint32_t i, r;
	int found;

	if (sc.iort_base != XCHECK_BASE)
		printf("gb10smmu: the IORT puts the SMMU at %#lx, the "
		    "hardcoded address was %#lx: using the IORT\n",
		    (u_long)sc.iort_base, XCHECK_BASE);
	if (sc.nsid != 1 || sc.sid[0].lo != XCHECK_SID_LO ||
	    sc.sid[0].hi != XCHECK_SID_HI)
		printf("gb10smmu: the IORT maps the GPU onto %d stream-ID "
		    "range(s), the hardcoded one was %#lx-%#lx: using the "
		    "IORT\n", sc.nsid, XCHECK_SID_LO, XCHECK_SID_HI);
	for (r = 0; r < nitems(xcheck_rmrs); r++) {
		found = 0;
		for (i = 0; i < (uint32_t)sc.nrmrs; i++) {
			if (sc.rmrs[i].base == xcheck_rmrs[r].start &&
			    sc.rmrs[i].length == xcheck_rmrs[r].size) {
				found = 1;
				break;
			}
		}
		if (!found)
			printf("gb10smmu: the IORT does not reserve %#jx+%#jx "
			    "for the GPU (the hardcoded list had it)\n",
			    (uintmax_t)xcheck_rmrs[r].start,
			    (uintmax_t)xcheck_rmrs[r].size);
	}
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
	printf("gb10smmu: IORT: base %#lx, SMMU node %#x, holder node %#x "
	    "type %#x, requester IDs %#x-%#x, %d RMR regions\n",
	    (u_long)sc.iort_base, sc.iort_node, sc.iort_holder,
	    sc.iort_holder_type, sc.iort_rid_lo, sc.iort_rid_hi, sc.nrmrs);
	for (i = 0; i < (u_int)sc.nsid; i++)
		printf("gb10smmu: IORT ID mapping %u: stream IDs %#x-%#x\n", i,
		    sc.sid[i].lo, sc.sid[i].hi);
	for (i = 0; i < (u_int)sc.nrmrs; i++)
		printf("gb10smmu: IORT RMR %u: %#jx+%#jx\n", i,
		    (uintmax_t)sc.rmrs[i].base, (uintmax_t)sc.rmrs[i].length);
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

/*
 * l2_get - the second-level table for one GiB of the stage-2 address
 * space.  The IORT says which ranges are reserved; they are not always
 * the same GiB, so the tables are made as they are needed.
 */
static int
l2_get(u_int gib)
{
	if (gib >= L1_ENTRIES)
		return (EINVAL);
	if (sc.l2[gib] == NULL) {
		sc.l2[gib] = alloc_tbl(PAGE_SIZE);
		if (sc.l2[gib] == NULL)
			return (ENOMEM);
		sc.l1[gib] = vtophys(sc.l2[gib]) | S2_TABLE;
	}
	return (0);
}

/*
 * build_s2 - the stage-2 table.
 *
 * In the trap mode the table maps the memory the IORT reserves for the
 * GPU and nothing else, so that every other access of the GPU terminates
 * and is recorded.  That means the mapping has to be exact: a block that
 * is only partly reserved must not be mapped, because the rest of it is
 * memory the firmware did not reserve for the GPU.
 *
 * The stage-2 table maps in blocks of 2 MiB, so a region the firmware
 * reserves has to be a whole number of 2 MiB blocks.  A region that is
 * not one cannot be mapped exactly, and the module refuses to attach
 * rather than map memory the firmware did not reserve.
 *
 * Every failure is reported and stops the caller: the SMMU is never
 * enabled with a table that is not the one the IORT describes.
 */
static int
build_s2(void)
{
	const uint64_t blk = S2_BLOCK | S2_AF | S2_SH_IS | S2_AP_RW;
	uint64_t a, end, start, size;
	u_int i, r, gib;
	int error;

	sc.l1 = alloc_tbl(PAGE_SIZE);
	if (sc.l1 == NULL) {
		printf("gb10smmu: no memory for the stage-2 table\n");
		return (ENOMEM);
	}
	if (sc.mode == 2) {
		/* 0-2 GiB is MMIO (the MSI doorbell too): device. */
		for (i = 0; i < L1_ENTRIES; i++)
			sc.l1[i] = (i * GIB) | blk |
			    (i < 2 ? (S2_MEM_DEV | S2_XN) : S2_MEM_WB);
		return (0);
	}
	if (!sc.rmr)
		return (0);
	for (r = 0; r < (u_int)sc.nrmrs; r++) {
		start = sc.rmrs[r].base;
		size = sc.rmrs[r].length;
		if (size == 0)
			continue;
		if ((start & (MIB2 - 1)) != 0 || (size & (MIB2 - 1)) != 0) {
			printf("gb10smmu: the IORT RMR %#jx+%#jx is not a "
			    "whole number of %ju MiB blocks: it cannot be "
			    "mapped exactly, refusing to attach\n",
			    (uintmax_t)start, (uintmax_t)size,
			    (uintmax_t)(MIB2 >> 20));
			return (EINVAL);
		}
		if (start + size > (uint64_t)L1_ENTRIES * GIB) {
			printf("gb10smmu: the IORT RMR %#jx+%#jx is above the "
			    "%d GiB stage-2 table: refusing to attach\n",
			    (uintmax_t)start, (uintmax_t)size, L1_ENTRIES);
			return (EINVAL);
		}
		a = start;
		end = start + size;
		for (; a < end; ) {
			gib = (u_int)(a / GIB);
			/* The whole GiB is reserved: map it as one block. */
			if ((a & (GIB - 1)) == 0 && a + GIB <= end) {
				sc.l1[gib] = a | blk | S2_MEM_WB;
				a += GIB;
				continue;
			}
			/* Only part of it is: map the 2 MiB blocks of it. */
			error = l2_get(gib);
			if (error != 0) {
				printf("gb10smmu: no table for GiB %u: the "
				    "RMR region %#jx+%#jx cannot be mapped, "
				    "refusing to attach\n", gib,
				    (uintmax_t)start, (uintmax_t)size);
				return (error);
			}
			sc.l2[gib][(a & (GIB - 1)) / MIB2] = a | blk |
			    S2_MEM_WB;
			a += MIB2;
		}
	}
	return (0);
}

/*
 * sid_is_gpu - is this stream ID one of the GPU's?
 */
static int
sid_is_gpu(u_long sid)
{
	int i;

	for (i = 0; i < sc.nsid; i++) {
		if (sid >= sc.sid[i].lo && sid <= sc.sid[i].hi)
			return (1);
	}
	return (0);
}

static void
free_tables(void)
{
	u_int i;

	free(sc.strtab, M_GB10SMMU);
	free(sc.cmdq, M_GB10SMMU);
	free(sc.evtq, M_GB10SMMU);
	free(sc.l1, M_GB10SMMU);
	sc.strtab = NULL;
	sc.cmdq = NULL;
	sc.evtq = NULL;
	sc.l1 = NULL;
	if (sc.l2 != NULL) {
		for (i = 0; i < L1_ENTRIES; i++)
			free(sc.l2[i], M_GB10SMMU);
		free(sc.l2, M_GB10SMMU);
		sc.l2 = NULL;
	}
}

/*
 * free_rmrs - the memory regions the IORT gave us, when the module does
 * not load after all.
 */
static void
free_rmrs(void)
{
	free(sc.rmrs, M_GB10SMMU);
	sc.rmrs = NULL;
	sc.nrmrs = 0;
}

/*
 * gb10smmu_tunables - the tunables, and whether they make sense.
 */
static int
gb10smmu_tunables(void)
{
	sc.rmr = 1;
	sc.eats = 1;
	TUNABLE_INT_FETCH("gb10smmu.rmr", &sc.rmr);
	TUNABLE_INT_FETCH("gb10smmu.eats", &sc.eats);
	TUNABLE_INT_FETCH("gb10smmu.mode", &sc.mode);
	if (sc.mode != 1 && sc.mode != 2) {
		printf("gb10smmu: refusing to attach: set "
		    "gb10smmu.mode=\"2\" in loader.conf before loading "
		    "gb10smmu.ko (1 is the trap mode, 2 the identity mode)\n");
		return (EINVAL);
	}
	if (sc.eats < 0 || sc.eats > 2) {
		printf("gb10smmu: refusing to attach: gb10smmu.eats must be "
		    "0, 1 or 2\n");
		return (EINVAL);
	}
	return (0);
}

/*
 * gb10smmu_before_nvidia - the module must be in front of the GPU.
 *
 * The GPU translates its addresses while its firmware starts, so the
 * module has to be attached before the nvidia driver is.
 */
static int
gb10smmu_before_nvidia(void)
{
	if (nvidia_attached()) {
		printf("gb10smmu: refusing to attach: the nvidia driver is "
		    "already attached to the GPU; load gb10smmu.ko before "
		    "nvidia.ko\n");
		return (EBUSY);
	}
	return (0);
}

/*
 * gb10smmu_facts - the facts come from the device.
 */
static int
gb10smmu_facts(void)
{
	int error;

	error = read_iort();
	if (error != 0)
		return (error);
	cross_check();
	return (0);
}

/*
 * gb10smmu_check_facts - the stream IDs and the base address.
 *
 * The stream IDs the IORT gives the GPU must fit in the stream table, and
 * the SMMU must have a base address to be mapped at.
 */
static int
gb10smmu_check_facts(void)
{
	int i;

	for (i = 0; i < sc.nsid; i++) {
		if (sc.sid[i].lo > sc.sid[i].hi ||
		    sc.sid[i].hi >= (1u << STRTAB_LOG2)) {
			printf("gb10smmu: the IORT maps the GPU onto stream "
			    "IDs %#x-%#x, which do not fit in a %d-entry "
			    "stream table: refusing to attach\n",
			    sc.sid[i].lo, sc.sid[i].hi, 1 << STRTAB_LOG2);
			return (EINVAL);
		}
	}
	if (sc.iort_base == 0) {
		printf("gb10smmu: the IORT gives the SMMU no base address: "
		    "refusing to attach\n");
		return (EINVAL);
	}
	sc.base = (u_long)sc.iort_base;
	return (0);
}

/*
 * gb10smmu_unmap_regs - the SMMU's register window.
 */
static void
gb10smmu_unmap_regs(void)
{
	if (sc.va == NULL)
		return;
	pmap_unmapdev(sc.va, MAPSIZE);
	sc.va = NULL;
}

/*
 * gb10smmu_free_l2 - the level-2 table's index.
 */
static void
gb10smmu_free_l2(void)
{
	if (sc.l2 == NULL)
		return;
	free(sc.l2, M_GB10SMMU);
	sc.l2 = NULL;
}

/*
 * gb10smmu_fail_early - the facts are in, nothing else is.
 */
static void
gb10smmu_fail_early(void)
{
	free_rmrs();
}

/*
 * gb10smmu_fail_l2 - the level-2 index is there, the tables are not.
 */
static void
gb10smmu_fail_l2(void)
{
	gb10smmu_free_l2();
	free_rmrs();
}

/*
 * gb10smmu_fail_tables - the tables are there; give them, the mapping and
 * the memory back.
 */
static void
gb10smmu_fail_tables(void)
{
	free_tables();
	gb10smmu_unmap_regs();
	free_rmrs();
}

/*
 * gb10smmu_alloc_l2 - the level-2 table's index.
 */
static int
gb10smmu_alloc_l2(void)
{
	sc.l2 = malloc(sizeof(uint64_t *) * L1_ENTRIES, M_GB10SMMU,
	    M_WAITOK | M_ZERO);
	if (sc.l2 == NULL)
		return (ENOMEM);
	return (0);
}

/*
 * gb10smmu_map_regs - the SMMU's registers.
 */
static int
gb10smmu_map_regs(void)
{
	sc.va = pmap_mapdev(sc.base, MAPSIZE);
	if (sc.va == NULL)
		return (ENOMEM);
	return (0);
}

/*
 * gb10smmu_check_fresh - the SMMU must be off and idle.
 *
 * An SMMU that is already enabled, that has no stage-2 translation, or
 * that has preset tables and queues is not ours to touch.
 */
static int
gb10smmu_check_fresh(void)
{
	if (rd4(R_CR0) != 0 || (rd4(R_IDR0) & 1) == 0 ||
	    (rd4(R_IDR1) & (3u << 29)) != 0) {
		printf("gb10smmu: SMMU already enabled, no stage 2, or preset "
		    "tables/queues; not touching it\n");
		return (EBUSY);
	}
	return (0);
}

/*
 * gb10smmu_alloc_tables - the stream table and the queues.
 */
static int
gb10smmu_alloc_tables(void)
{
	sc.strtab = alloc_tbl((size_t)64 << STRTAB_LOG2);
	sc.cmdq = alloc_tbl(PAGE_SIZE);
	sc.evtq = alloc_tbl((size_t)32 << EVTQ_LOG2);
	if (sc.strtab == NULL || sc.cmdq == NULL || sc.evtq == NULL) {
		printf("gb10smmu: no memory for the stream table or the "
		    "queues: refusing to attach\n");
		return (ENOMEM);
	}
	return (0);
}

/*
 * gb10smmu_stage2 - the stage-2 table.
 */
static int
gb10smmu_stage2(void)
{
	int error;

	error = build_s2();
	if (error != 0) {
		printf("gb10smmu: the stage-2 table could not be built: the "
		    "SMMU is left disabled\n");
		return (error);
	}
	return (0);
}

/*
 * gb10smmu_fill_strtab - one entry per stream.
 *
 * The GPU's streams are translated; every other stream is bypassed.
 */
static void
gb10smmu_fill_strtab(void)
{
	uint64_t ste0, ste1, ste2, ste3;
	u_long sid;

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
	    (1ULL << 58);			/* S2R: record the faults */
	ste3 = vtophys(sc.l1) & 0x000ffffffffffff0ULL;
	for (sid = 0; sid < (1u << STRTAB_LOG2); sid++) {
		uint64_t *s = &sc.strtab[sid * 8];

		if (sid_is_gpu(sid)) {
			s[0] = ste0; s[1] = ste1; s[2] = ste2; s[3] = ste3;
		} else {
			s[0] = 1 | (0x4ULL << 1);	/* V, bypass */
			s[1] = 1ULL << 44;
		}
	}
	wmb();
}

/*
 * gb10smmu_program - the tables and the queues.
 */
static void
gb10smmu_program(void)
{
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
}

/*
 * gb10smmu_enable - turn the SMMU on.
 *
 * The command queue first, then the event queue, then the SMMU itself:
 * each step waits for the one before it.  A step that fails leaves the
 * SMMU in global bypass.
 */
static int
gb10smmu_enable(void)
{
	int error;

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
		/* Back to global bypass.  The module does not load, so the
		 * tables and the mapping go with it. */
		wr4(R_CR0, 0);
		printf("gb10smmu: enable failed (%d), SMMU left disabled, "
		    "CR0ACK %#x\n", error, rd4(R_CR0ACK));
		return (error);
	}
	return (0);
}

/*
 * gb10smmu_start_held - the attach, with the holds taken.
 *
 * The nvidia driver is checked for and the SMMU is changed under the same
 * holds, so nothing comes in between them.
 */
static int
gb10smmu_start_held(void)
{
	int error;

	/*
	 * The enable path, one step at a time.  Every step that fails stops
	 * the enable: the module does not load and the SMMU stays off.
	 */
	error = gb10smmu_before_nvidia();
	if (error != 0)
		return (error);
	error = gb10smmu_facts();
	if (error != 0)
		return (error);
	error = gb10smmu_check_facts();
	if (error != 0) {
		gb10smmu_fail_early();
		return (error);
	}
	error = gb10smmu_alloc_l2();
	if (error != 0) {
		gb10smmu_fail_early();
		return (error);
	}
	error = gb10smmu_map_regs();
	if (error != 0) {
		gb10smmu_fail_l2();
		return (error);
	}
	printf("gb10smmu: base %#lx IDR0 %08x IDR1 %08x IDR5 %08x CR0 %08x "
	    "GBPA %08x\n", sc.base, rd4(R_IDR0), rd4(R_IDR1), rd4(R_IDR5),
	    rd4(R_CR0), rd4(R_GBPA));
	error = gb10smmu_check_fresh();
	if (error != 0) {
		gb10smmu_unmap_regs();
		gb10smmu_fail_l2();
		return (error);
	}

	error = gb10smmu_alloc_tables();
	if (error != 0) {
		gb10smmu_fail_tables();
		return (error);
	}
	error = gb10smmu_stage2();
	if (error != 0) {
		gb10smmu_fail_tables();
		return (error);
	}
	gb10smmu_fill_strtab();

	gb10smmu_program();
	error = gb10smmu_enable();
	if (error != 0) {
		gb10smmu_fail_tables();
		return (error);
	}
	sc.enabled = 1;
	callout_init(&sc.co, 1);
	callout_reset(&sc.co, 1, evtq_poll, NULL);
	printf("gb10smmu: enabled, mode %s%s, %d stream-ID range(s) of the "
	    "GPU translated, others bypass; strtab %#jx l1 %#jx evtq %#jx\n",
	    sc.mode == 1 ? "trap" : "identity",
	    sc.mode == 1 ? (sc.rmr ? " (RMR regions mapped)" : " (nothing "
	    "mapped)") : "", sc.nsid,
	    (uintmax_t)vtophys(sc.strtab), (uintmax_t)vtophys(sc.l1),
	    (uintmax_t)vtophys(sc.evtq));
	dump_state();
	return (0);
}

static int
gb10smmu_start(void)
{
	int error;

	mtx_init(&sc_lock, "gb10smmu", "gb10smmu", 0);
	error = gb10smmu_tunables();
	if (error != 0) {
		mtx_destroy(&sc_lock);
		return (error);
	}

	/*
	 * The GPU has to be in the machine before anything else: the module
	 * programs the SMMU of that GPU and of no other device.  A machine
	 * without it has no SMMU of ours to program, and the module says so
	 * instead of programming one that belongs to something else.
	 */
	if (!gb10smmu_find_gpu(root_bus)) {
		printf("gb10smmu: refusing to attach: this machine has no "
		    "NVIDIA GB10 GPU (PCI %04x:%04x); the module programs the "
		    "SMMU in front of that GPU and nothing else\n",
		    GB10SMMU_PCI_VENDOR, GB10SMMU_PCI_DEVICE);
		mtx_destroy(&sc_lock);
		return (ENXIO);
	}
	printf("gb10smmu: GPU %s: PCI %04x:%04x segment %u requester ID "
	    "%#x\n", sc.gpu_name, sc.gpu_vendor, sc.gpu_device, sc.gpu_seg,
	    sc.gpu_rid);

	/*
	 * From here on the module's own lock and the bus topology are held:
	 * the check for the nvidia driver and the change of the SMMU are one
	 * thing, and a device that comes in between them waits for the
	 * module.
	 */
	gb10smmu_hold();
	error = gb10smmu_start_held();
	gb10smmu_unhold();
	if (error != 0)
		mtx_destroy(&sc_lock);
	return (error);
}

/*
 * gb10smmu_stop_held - the unload, with the holds taken.
 */
static int
gb10smmu_stop_held(void)
{
	/*
	 * Unloading puts the SMMU back into global bypass.  A GPU that runs
	 * with a translation table it can no longer answer faults, so the
	 * module refuses to unload while the nvidia driver is attached.
	 */
	if (nvidia_attached()) {
		printf("gb10smmu: refusing to unload: the nvidia driver is "
		    "still attached to the GPU\n");
		return (EBUSY);
	}
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
		free_tables();
	}
	pmap_unmapdev(sc.va, MAPSIZE);
	sc.va = NULL;
	free(sc.rmrs, M_GB10SMMU);
	sc.rmrs = NULL;
	sc.nrmrs = 0;
	return (0);
}

static int
gb10smmu_stop(void)
{
	int error;

	if (sc.va == NULL)
		return (0);
	/* The check for the nvidia driver and the change of the SMMU are
	 * one thing, under the same holds as the load path. */
	gb10smmu_hold();
	error = gb10smmu_stop_held();
	gb10smmu_unhold();
	/*
	 * A refused unload keeps the module loaded: the kernel does not
	 * unload a module whose unload handler returns an error.  The lock
	 * the module holds is then still in use, and the next unload
	 * attempt takes it again, so it must not be destroyed here.  Only
	 * an unload that was not refused really takes the module away.
	 */
	if (error != 0)
		return (error);
	mtx_destroy(&sc_lock);
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

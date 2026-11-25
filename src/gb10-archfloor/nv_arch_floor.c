/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The architecture floor of nvidia.ko (Track #2457).  nvidia_pci_probe()
 * calls nv_arch_floor_probe(), which reads PMC_BOOT_0 and PMC_BOOT_42 from
 * BAR0 the way NVIDIA's own attach path does a little later, and refuses
 * every GPU older than GA10x (RTX 30) with ENXIO, so the device stays unattached and
 * has no dev.nvidia tree.  Each refused device is recorded once and listed in
 * hw.nvidia.refused; the decision itself is a pure function (see the header).
 */
#include <sys/param.h>
#include <sys/systm.h>
#include <sys/bus.h>
#include <sys/kernel.h>
#include <sys/lock.h>
#include <sys/malloc.h>
#include <sys/mutex.h>
#include <sys/rman.h>
#include <sys/sysctl.h>

#include <dev/pci/pcireg.h>
#include <dev/pci/pcivar.h>

#include <vm/vm.h>
#include <vm/pmap.h>

#include "nv_arch_floor.h"

#define NV_ARCH_FLOOR_NVIDIA_VENDOR	0x10de

struct nv_arch_floor_arch {
	unsigned value;
	const char *name;
	const char *prefix;
};

struct nv_arch_floor_fw {
	unsigned architecture;
	unsigned implementation;
	const char *chip;
	const char *image;
	const char *machines;
};

#define NV_ARCH_FLOOR_ARCH_ROW(value, name, prefix)	{ (value), (name), (prefix) },
#define NV_ARCH_FLOOR_FW_ROW(arch, impl, chip, image, machines)	\
	{ (arch), (impl), (chip), (image), (machines) },

static const struct nv_arch_floor_arch nv_arch_floor_arches[] = {
	NV_ARCH_FLOOR_TABLE(NV_ARCH_FLOOR_ARCH_ROW)
	{ 0, NULL, NULL }
};

static const struct nv_arch_floor_fw nv_arch_floor_fws[] = {
	NV_ARCH_FLOOR_FIRMWARE(NV_ARCH_FLOOR_FW_ROW)
	{ 0, 0, NULL, NULL, NULL }
};

/*
 * The keywords of the verdicts, as string macros: the size of a keyword is
 * the size of its text and not the size of a pointer to it.
 */
#define NV_ARCH_FLOOR_KW_ACCEPT		"accept"
#define NV_ARCH_FLOOR_KW_BELOW_FLOOR	"below-floor"
#define NV_ARCH_FLOOR_KW_UNKNOWN		"unknown"
#define NV_ARCH_FLOOR_KW_NO_FIRMWARE	"no-firmware"
#define NV_ARCH_FLOOR_KW_NOT_RESPONDING	"not-responding"
#define NV_ARCH_FLOOR_KW_UNREADABLE	"unreadable"

/*
 * No keyword is longer than not-responding, which is what makes it the
 * bound of the keyword field of the refused buffer.  The asserts name the
 * longest keyword and not the bound (NV_ARCH_FLOOR_KEYWORD_MAX) on purpose:
 * a bound that is too small has to fail the test, which sees the truncated
 * list, and not the build, so that the test can prove it.
 */
_Static_assert(sizeof(NV_ARCH_FLOOR_KW_ACCEPT) <=
    sizeof(NV_ARCH_FLOOR_KW_NOT_RESPONDING),
    "the keyword accept is longer than not-responding");
_Static_assert(sizeof(NV_ARCH_FLOOR_KW_BELOW_FLOOR) <=
    sizeof(NV_ARCH_FLOOR_KW_NOT_RESPONDING),
    "the keyword below-floor is longer than not-responding");
_Static_assert(sizeof(NV_ARCH_FLOOR_KW_UNKNOWN) <=
    sizeof(NV_ARCH_FLOOR_KW_NOT_RESPONDING),
    "the keyword unknown is longer than not-responding");
_Static_assert(sizeof(NV_ARCH_FLOOR_KW_NO_FIRMWARE) <=
    sizeof(NV_ARCH_FLOOR_KW_NOT_RESPONDING),
    "the keyword no-firmware is longer than not-responding");
_Static_assert(sizeof(NV_ARCH_FLOOR_KW_UNREADABLE) <=
    sizeof(NV_ARCH_FLOOR_KW_NOT_RESPONDING),
    "the keyword unreadable is longer than not-responding");
_Static_assert(sizeof(NV_ARCH_FLOOR_KW_NOT_RESPONDING) >=
    sizeof(NV_ARCH_FLOOR_KW_ACCEPT) &&
    sizeof(NV_ARCH_FLOOR_KW_NOT_RESPONDING) >=
    sizeof(NV_ARCH_FLOOR_KW_BELOW_FLOOR) &&
    sizeof(NV_ARCH_FLOOR_KW_NOT_RESPONDING) >=
    sizeof(NV_ARCH_FLOOR_KW_UNKNOWN) &&
    sizeof(NV_ARCH_FLOOR_KW_NOT_RESPONDING) >=
    sizeof(NV_ARCH_FLOOR_KW_NO_FIRMWARE) &&
    sizeof(NV_ARCH_FLOOR_KW_NOT_RESPONDING) >=
    sizeof(NV_ARCH_FLOOR_KW_UNREADABLE),
    "not-responding is not the longest keyword");

static const char *const nv_arch_floor_keywords[] = {
	[NV_ARCH_FLOOR_ACCEPT] = NV_ARCH_FLOOR_KW_ACCEPT,
	[NV_ARCH_FLOOR_BELOW_FLOOR] = NV_ARCH_FLOOR_KW_BELOW_FLOOR,
	[NV_ARCH_FLOOR_UNKNOWN] = NV_ARCH_FLOOR_KW_UNKNOWN,
	[NV_ARCH_FLOOR_NO_FIRMWARE] = NV_ARCH_FLOOR_KW_NO_FIRMWARE,
	[NV_ARCH_FLOOR_NOT_RESPONDING] = NV_ARCH_FLOOR_KW_NOT_RESPONDING,
	[NV_ARCH_FLOOR_UNREADABLE] = NV_ARCH_FLOOR_KW_UNREADABLE,
};

const char *
nv_arch_floor_keyword(enum nv_arch_floor_verdict verdict)
{
	if ((unsigned)verdict >=
	    sizeof(nv_arch_floor_keywords) / sizeof(nv_arch_floor_keywords[0]))
		return ("unknown");
	return (nv_arch_floor_keywords[verdict]);
}

/*
 * Whether MACHINE is one of the space-separated machine architectures of a
 * firmware row: the row says which builds carry the image.
 */
static int
nv_arch_floor_machine_in(const char *machines, const char *machine)
{
	const char *p = machines;

	while (*p != '\0') {
		const char *start;
		size_t len;

		while (*p == ' ')
			p++;
		if (*p == '\0')
			break;
		start = p;
		while (*p != '\0' && *p != ' ')
			p++;
		len = (size_t)(p - start);
		if (len == strlen(machine) &&
		    strncmp(start, machine, len) == 0)
			return (1);
	}
	return (0);
}

/* Whether this build carries the image a firmware row names. */
static int
nv_arch_floor_build_has(const struct nv_arch_floor_fw *fw)
{
	return (nv_arch_floor_machine_in(fw->machines, NV_ARCH_FLOOR_MACHINE));
}

void
nv_arch_floor_decide(uint32_t boot_0, uint32_t boot_42,
    struct nv_arch_floor_decision *decision)
{
	const struct nv_arch_floor_arch *arch;
	const struct nv_arch_floor_fw *fw;

	memset(decision, 0, sizeof(*decision));
	decision->verdict = NV_ARCH_FLOOR_ACCEPT;
	if (boot_0 == NV_ARCH_FLOOR_ALL_ONES &&
	    boot_42 == NV_ARCH_FLOOR_ALL_ONES) {
		decision->verdict = NV_ARCH_FLOOR_NOT_RESPONDING;
		return;
	}
	decision->architecture =
	    (boot_42 >> NV_ARCH_FLOOR_ARCH_SHIFT) & NV_ARCH_FLOOR_ARCH_MASK;
	decision->implementation =
	    (boot_42 >> NV_ARCH_FLOOR_IMPL_SHIFT) & NV_ARCH_FLOOR_IMPL_MASK;
	for (arch = nv_arch_floor_arches; arch->name != NULL; arch++) {
		if (arch->value == decision->architecture) {
			decision->architecture_name = arch->name;
			break;
		}
	}
	if (decision->architecture < NV_ARCH_FLOOR_MIN_ARCHITECTURE) {
		decision->verdict = NV_ARCH_FLOOR_BELOW_FLOOR;
		return;
	}
	if (decision->architecture_name == NULL) {
		decision->verdict = NV_ARCH_FLOOR_UNKNOWN;
		return;
	}
	for (fw = nv_arch_floor_fws; fw->image != NULL; fw++) {
		if (fw->architecture == decision->architecture &&
		    fw->implementation == decision->implementation &&
		    !nv_arch_floor_build_has(fw)) {
			decision->verdict = NV_ARCH_FLOOR_NO_FIRMWARE;
			decision->chip = fw->chip;
			decision->missing_image = fw->image;
			decision->machines = fw->machines;
			return;
		}
	}
}

/*
 * The architecture name as the messages print it.  Every name in the table
 * is a chip family (GA10x, GH100, GB20x), never a marketing name, so a
 * message prints the same string the values carry: there is one name per
 * row and no second name for the floor.
 */
void
nv_arch_floor_format(const struct nv_arch_floor_decision *decision,
    const char *name, uint16_t device_id, char *buf, size_t len)
{
	const char *who = name != NULL ? name : "NVIDIA GPU";

	if (len == 0)
		return;
	switch (decision->verdict) {
	case NV_ARCH_FLOOR_BELOW_FLOOR:
		if (decision->architecture_name != NULL)
			snprintf(buf, len, "%s (0x%04x) is %s; "
			    "this driver supports %s and later", who,
			    (unsigned)device_id,
			    decision->architecture_name,
			    NV_ARCH_FLOOR_MIN_ARCHITECTURE_LABEL);
		else
			snprintf(buf, len, "%s (0x%04x) is architecture "
			    "0x%02x, older than %s; this driver supports %s "
			    "and later", who, (unsigned)device_id,
			    decision->architecture,
			    NV_ARCH_FLOOR_MIN_ARCHITECTURE_NAME,
			    NV_ARCH_FLOOR_MIN_ARCHITECTURE_LABEL);
		break;
	case NV_ARCH_FLOOR_UNKNOWN:
		snprintf(buf, len, "%s (0x%04x) reports unknown "
		    "architecture 0x%02x; this driver supports %s and later",
		    who, (unsigned)device_id, decision->architecture,
		    NV_ARCH_FLOOR_MIN_ARCHITECTURE_LABEL);
		break;
	case NV_ARCH_FLOOR_NO_FIRMWARE:
		snprintf(buf, len, "%s (0x%04x) is %s %s, which needs the %s "
		    "firmware; only the %s build carries it", who,
		    (unsigned)device_id,
		    decision->architecture_name != NULL ?
		    decision->architecture_name : "an architecture",
		    decision->chip != NULL ? decision->chip : "chip",
		    decision->missing_image != NULL ?
		    decision->missing_image : "GSP",
		    decision->machines != NULL ?
		    decision->machines : "supported");
		break;
	case NV_ARCH_FLOOR_NOT_RESPONDING:
		snprintf(buf, len, "%s (0x%04x) does not respond "
		    "(PMC_BOOT_0 and PMC_BOOT_42 read 0xffffffff); "
		    "not attaching", who, (unsigned)device_id);
		break;
	case NV_ARCH_FLOOR_UNREADABLE:
		snprintf(buf, len, "%s (0x%04x): cannot read PMC_BOOT_42 "
		    "(BAR0 not available); not attaching", who,
		    (unsigned)device_id);
		break;
	case NV_ARCH_FLOOR_ACCEPT:
	default:
		snprintf(buf, len, "%s (0x%04x) is supported", who,
		    (unsigned)device_id);
		break;
	}
}

/*
 * The refused devices, for hw.nvidia.refused.  A fixed array: a probe can
 * run at any time and must not allocate.  A device that does not fit is
 * still refused and logged, and counted in refused_count.
 */
struct nv_arch_floor_refused {
	char location[NV_ARCH_FLOOR_LOCATION_SIZE];
	char parent[NV_ARCH_FLOOR_NAME_SIZE];
	uint16_t device_id;
	enum nv_arch_floor_verdict verdict;
	char line[NV_ARCH_FLOOR_LINE_SIZE];
};

static struct mtx nv_arch_floor_mtx;
/* MTX_SYSINIT also registers the matching mtx_destroy for module unload. */
MTX_SYSINIT(nv_arch_floor_mtx, &nv_arch_floor_mtx, "nv_arch_floor", MTX_DEF);

static struct nv_arch_floor_refused nv_arch_floor_refused[NV_ARCH_FLOOR_MAX_REFUSED];
static int nv_arch_floor_nrefused;
static int nv_arch_floor_refused_count;	/* recorded plus overflow */

/*
 * The locations of the refused devices, for the dedupe alone: a device that
 * did not fit the list above is still counted once and logged once.  Past
 * NV_ARCH_FLOOR_MAX_LOCATIONS locations a refusal is logged again every
 * time it is probed.
 */
static char nv_arch_floor_locations[NV_ARCH_FLOOR_MAX_LOCATIONS]
    [NV_ARCH_FLOOR_LOCATION_SIZE];
static int nv_arch_floor_nlocations;

/*
 * Record a refusal.  Returns 1 when the refusal must be logged, 0 when this
 * location was already recorded with the same verdict.  A re-probe with a
 * different verdict replaces the entry and is logged again.
 */
static int
nv_arch_floor_record(const char *location, const char *parent,
    uint16_t device_id, enum nv_arch_floor_verdict verdict, const char *line)
{
	struct nv_arch_floor_refused *entry;
	int changed, i, known;

	changed = 0;
	mtx_lock(&nv_arch_floor_mtx);
	for (i = 0; i < nv_arch_floor_nlocations; i++)
		if (strcmp(nv_arch_floor_locations[i], location) == 0)
			break;
	known = (i < nv_arch_floor_nlocations);
	if (!known) {
		nv_arch_floor_refused_count++;
		if (nv_arch_floor_nlocations < NV_ARCH_FLOOR_MAX_LOCATIONS) {
			strlcpy(nv_arch_floor_locations[nv_arch_floor_nlocations++],
			    location, sizeof(nv_arch_floor_locations[0]));
		}
		if (nv_arch_floor_nrefused < NV_ARCH_FLOOR_MAX_REFUSED) {
			entry = &nv_arch_floor_refused[nv_arch_floor_nrefused++];
			strlcpy(entry->location, location,
			    sizeof(entry->location));
			strlcpy(entry->parent, parent, sizeof(entry->parent));
			entry->device_id = device_id;
			entry->verdict = verdict;
			strlcpy(entry->line, line, sizeof(entry->line));
		}
	} else {
		for (i = 0; i < nv_arch_floor_nrefused; i++) {
			entry = &nv_arch_floor_refused[i];
			if (strcmp(entry->location, location) != 0)
				continue;
			if (entry->verdict != verdict) {
				entry->verdict = verdict;
				entry->device_id = device_id;
				strlcpy(entry->parent, parent,
				    sizeof(entry->parent));
				strlcpy(entry->line, line, sizeof(entry->line));
				changed = 1;
			}
			break;
		}
	}
	mtx_unlock(&nv_arch_floor_mtx);
	return (!known || changed);
}

/*
 * Forget a location that attached: it is not a refused GPU any more.  It
 * leaves both tables and refused_count goes down by one.  A location that
 * is not in the locations table (past NV_ARCH_FLOOR_MAX_LOCATIONS) is not
 * forgotten and does not count down.
 */
static void
nv_arch_floor_forget(const char *location)
{
	int i, j;

	mtx_lock(&nv_arch_floor_mtx);
	for (i = 0; i < nv_arch_floor_nrefused; i++) {
		if (strcmp(nv_arch_floor_refused[i].location, location) != 0)
			continue;
		for (j = i; j + 1 < nv_arch_floor_nrefused; j++)
			nv_arch_floor_refused[j] = nv_arch_floor_refused[j + 1];
		nv_arch_floor_nrefused--;
		break;
	}
	for (i = 0; i < nv_arch_floor_nlocations; i++) {
		if (strcmp(nv_arch_floor_locations[i], location) != 0)
			continue;
		for (j = i; j + 1 < nv_arch_floor_nlocations; j++)
			memcpy(nv_arch_floor_locations[j],
			    nv_arch_floor_locations[j + 1],
			    sizeof(nv_arch_floor_locations[0]));
		nv_arch_floor_nlocations--;
		if (nv_arch_floor_refused_count > 0)
			nv_arch_floor_refused_count--;
		break;
	}
	mtx_unlock(&nv_arch_floor_mtx);
}

/*
 * Read PMC_BOOT_0 and PMC_BOOT_42 from BAR0.  The sequence is NVIDIA's own
 * (nvidia_alloc_hardware, nvidia_attach and rm_is_supported_device): BAR0 is
 * allocated without RF_ACTIVE, memory decode is switched on, one page is
 * mapped uncached and read.  Everything taken is given back, and decode is
 * switched off again when it was off, so attach finds the device as it was.
 * Returns ENXIO when BAR0 cannot be allocated.
 */
static int
nv_arch_floor_read(device_t dev, uint32_t *boot_0, uint32_t *boot_42)
{
	struct resource *res;
	void *va;
	uint16_t command;
	int rid;

	rid = PCIR_BAR(0);
	res = bus_alloc_resource_any(dev, SYS_RES_MEMORY, &rid, 0);
	if (res == NULL)
		return (ENXIO);
	command = pci_read_config(dev, PCIR_COMMAND, 2);
	pci_enable_io(dev, SYS_RES_MEMORY);
	va = pmap_mapdev(rman_get_start(res), PAGE_SIZE);
	*boot_0 = *(volatile uint32_t *)((char *)va + NV_ARCH_FLOOR_PMC_BOOT_0);
	*boot_42 = *(volatile uint32_t *)((char *)va + NV_ARCH_FLOOR_PMC_BOOT_42);
	pmap_unmapdev(va, PAGE_SIZE);
	if ((command & PCIM_CMD_MEMEN) == 0)
		pci_disable_io(dev, SYS_RES_MEMORY);
	bus_release_resource(dev, SYS_RES_MEMORY, rid, res);
	return (0);
}

int
nv_arch_floor_probe(device_t dev, const char *name)
{
	struct nv_arch_floor_decision decision;
	char location[NV_ARCH_FLOOR_LOCATION_SIZE];
	char parent[NV_ARCH_FLOOR_NAME_SIZE];
	char line[NV_ARCH_FLOOR_LINE_SIZE];
	uint32_t boot_0, boot_42;
	uint16_t device_id;
	device_t pdev;

	if (pci_get_vendor(dev) != NV_ARCH_FLOOR_NVIDIA_VENDOR)
		return (ENXIO);
	device_id = pci_get_device(dev);
	/*
	 * The parent of the device is the PCI device the driver sits on; its
	 * name unit ("vgapci1") is what pciconf(8) and the devd rule call it,
	 * and it does not change when the probe fails and the unit is freed.
	 */
	parent[0] = '\0';
	pdev = device_get_parent(dev);
	if (pdev != NULL) {
		const char *pname;

		pname = device_get_nameunit(pdev);
		if (pname != NULL)
			strlcpy(parent, pname, sizeof(parent));
	}
	snprintf(location, sizeof(location), "pci%u:%u:%u:%u",
	    (unsigned)pci_get_domain(dev), (unsigned)pci_get_bus(dev),
	    (unsigned)pci_get_slot(dev), (unsigned)pci_get_function(dev));
	if (nv_arch_floor_read(dev, &boot_0, &boot_42) != 0) {
		memset(&decision, 0, sizeof(decision));
		decision.verdict = NV_ARCH_FLOOR_UNREADABLE;
	} else {
		nv_arch_floor_decide(boot_0, boot_42, &decision);
	}
	/* An accepted device is logged by the attach path that follows. */
	if (decision.verdict == NV_ARCH_FLOOR_ACCEPT) {
		/* it is not a refused GPU any more */
		nv_arch_floor_forget(location);
		return (0);
	}
	nv_arch_floor_format(&decision, name, device_id, line, sizeof(line));
	if (nv_arch_floor_record(location, parent, device_id, decision.verdict,
	    line))
		device_printf(pdev != NULL ? pdev : dev, "nvidia: %s\n", line);
	return (ENXIO);
}

static int nv_arch_floor_min_architecture = NV_ARCH_FLOOR_MIN_ARCHITECTURE;
static char nv_arch_floor_min_architecture_name[] =
    NV_ARCH_FLOOR_MIN_ARCHITECTURE_NAME;

/*
 * The buffer for hw.nvidia.refused: one line per refused device, each
 * "<location> <parent> 0x<id> <keyword> <message>".  The prefix is bounded
 * by the location, the parent name, the device id and the longest keyword,
 * and the message has a size of its own.  The bound of the keyword field is
 * the size of the longest keyword string: sizeof of the keyword macro, and
 * not sizeof of a pointer to it.
 */
#define NV_ARCH_FLOOR_KEYWORD_MAX	sizeof(NV_ARCH_FLOOR_KW_NOT_RESPONDING)

#define NV_ARCH_FLOOR_REFUSED_BUF \
	((size_t)NV_ARCH_FLOOR_MAX_REFUSED * \
	    (NV_ARCH_FLOOR_LOCATION_SIZE + NV_ARCH_FLOOR_NAME_SIZE + \
	    sizeof(" 0x0000 ") + NV_ARCH_FLOOR_KEYWORD_MAX + 1 + \
	    NV_ARCH_FLOOR_LINE_SIZE + 1))

static int
nv_arch_floor_sysctl_refused(SYSCTL_HANDLER_ARGS)
{
	const struct nv_arch_floor_refused *entry;
	char *buf;
	size_t used, room;
	int error, i, n;

	buf = malloc(NV_ARCH_FLOOR_REFUSED_BUF, M_TEMP, M_WAITOK | M_ZERO);
	used = 0;
	mtx_lock(&nv_arch_floor_mtx);
	for (i = 0; i < nv_arch_floor_nrefused; i++) {
		entry = &nv_arch_floor_refused[i];
		room = NV_ARCH_FLOOR_REFUSED_BUF - used;
		n = snprintf(buf + used, room, "%s%s %s 0x%04x %s %s",
		    used > 0 ? "\n" : "", entry->location, entry->parent,
		    (unsigned)entry->device_id,
		    nv_arch_floor_keyword(entry->verdict), entry->line);
		if (n < 0 || (size_t)n >= room) {
			used = NV_ARCH_FLOOR_REFUSED_BUF - 1;
			break;
		}
		used += n;
	}
	mtx_unlock(&nv_arch_floor_mtx);
	error = SYSCTL_OUT(req, buf, used + 1);
	free(buf, M_TEMP);
	return (error);
}

void
nv_arch_floor_sysctl_init(struct sysctl_ctx_list *ctx,
    struct sysctl_oid *parent)
{
	SYSCTL_ADD_INT(ctx, SYSCTL_CHILDREN(parent), OID_AUTO,
	    "min_architecture", CTLTYPE_INT | CTLFLAG_RD | CTLFLAG_DYN,
	    &nv_arch_floor_min_architecture, 0,
	    "Lowest PMC_BOOT_42 NVIDIA GPU architecture value the driver "
	    "attaches to");
	SYSCTL_ADD_STRING(ctx, SYSCTL_CHILDREN(parent), OID_AUTO,
	    "min_architecture_name", CTLTYPE_STRING | CTLFLAG_RD | CTLFLAG_DYN,
	    nv_arch_floor_min_architecture_name,
	    sizeof(nv_arch_floor_min_architecture_name),
	    "Name of the oldest NVIDIA GPU architecture the driver attaches "
	    "to");
	SYSCTL_ADD_INT(ctx, SYSCTL_CHILDREN(parent), OID_AUTO,
	    "refused_count", CTLTYPE_INT | CTLFLAG_RD | CTLFLAG_DYN,
	    &nv_arch_floor_refused_count, 0,
	    "GPUs refused at probe, including any that did not fit the list");
	SYSCTL_ADD_PROC(ctx, SYSCTL_CHILDREN(parent), OID_AUTO,
	    "refused", CTLTYPE_STRING | CTLFLAG_RD | CTLFLAG_MPSAFE |
	    CTLFLAG_DYN, NULL, 0, nv_arch_floor_sysctl_refused, "A",
	    "GPUs refused at probe: location, device id, verdict, reason");
}

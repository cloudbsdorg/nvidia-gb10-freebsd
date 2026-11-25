/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * nvrm_rm_mem.c - the RM backend's memory and VA calls (Track #2419).  Like nvrm_rm.c it speaks only the RM escape ioctls of the
 * NVIDIA kernel module, with structures and constants from NVIDIA's
 * open-gpu-kernel-modules 580.178.04 (MIT).  No foreign-OS layer is involved.
 *
 * One nvrm_client is one RM session of its own (a new /dev/nvidiactl
 * descriptor and RM client, opened the same way enumeration does it), with
 * only this GPU attached, one NV01_DEVICE_0 and one FERMI_VASPACE_A:
 *
 *   VA reservation   NV50_MEMORY_VIRTUAL at a fixed address inside the VA
 *                    space (sparse with NVOS32_ALLOC_FLAGS_SPARSE)
 *   VRAM             NV01_MEMORY_LOCAL_USER, location video memory, write
 *                    combined
 *   system memory    NV01_MEMORY_SYSTEM, location PCI, cached
 *   user pages       NV01_MEMORY_SYSTEM_OS_DESCRIPTOR, a virtual address
 *   GPU map          NV_ESC_RM_MAP_MEMORY_DMA at a fixed DMA offset
 *   CPU map          NV_ESC_RM_MAP_MEMORY with the descriptor the mapping is
 *                    made on, then mmap(2) of that descriptor.  The OS layer
 *                    keeps one mapping context per descriptor
 *                    (nvidia_mmap_dev_single), so every CPU mapping consumes
 *                    one descriptor; the core keeps spares for capability mode.
 *                    The descriptor's kind follows the memory: a video-memory
 *                    mapping is made on /dev/nvidiaN (the RM maps it through
 *                    the GPU's BAR aperture), a system-memory mapping on
 *                    /dev/nvidiactl, because the RM associates a
 *                    system-memory mapping with the control device and
 *                    refuses any other descriptor with NV_ERR_INVALID_ARGUMENT
 *                    (nvrm_internal.h, NVRM_DESC_MAP).
 *   export / import  NV0000_CTRL_CMD_OS_UNIX_EXPORT_OBJECT_TO_FD with the
 *                    descriptor of a second /dev/nvidiactl (the spare), and
 *                    ..._IMPORT_OBJECT_FROM_FD on the receiving client
 *
 * The CPU attribute of a mapping is the OS layer's decision (the README, "Memory
 * attributes on arm64"); this file asks for write-combined video memory and
 * cached system memory and the core applies the rule to what it reports.
 *
 * Fork: the core refuses calls from a child that would act on the parent's
 * objects, and passes an owner flag to backend releases so they drop only
 * child-local records.  The RM client itself is still freed only by its owner
 * (nvrm_rm_owner).
 */
#include <sys/param.h>
#include <sys/ioctl.h>
#include <sys/mman.h>

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <nvmisc.h>
#include <nv-unix-nvos-params-wrappers.h>
#include <class/cl003e.h>
#include <class/cl0040.h>
#include <class/cl0070.h>
#include <class/cl0071.h>
#include <class/cl0080.h>
#include <class/cl50a0.h>
#include <class/cl90f1.h>
#include <ctrl/ctrl0000/ctrl0000client.h>
#include <ctrl/ctrl0000/ctrl0000gpu.h>
#include <ctrl/ctrl0000/ctrl0000unix.h>
#include <ctrl/ctrl0041.h>

#include "nvrm_rm_priv.h"

#define IOC_MAP_MEMORY		_IOWR(NV_IOCTL_MAGIC, NV_ESC_RM_MAP_MEMORY, \
				    nv_ioctl_nvos33_parameters_with_fd)
#define IOC_UNMAP_MEMORY	_IOWR(NV_IOCTL_MAGIC, NV_ESC_RM_UNMAP_MEMORY, \
				    NVOS34_PARAMETERS)
#define IOC_MAP_DMA		_IOWR(NV_IOCTL_MAGIC, NV_ESC_RM_MAP_MEMORY_DMA, \
				    NVOS46_PARAMETERS)
#define IOC_UNMAP_DMA		_IOWR(NV_IOCTL_MAGIC, \
				    NV_ESC_RM_UNMAP_MEMORY_DMA, \
				    NVOS47_PARAMETERS)

#define DEVICE_PATH_FMT		"/dev/nvidia%u"
#define OWNER_ID		0x6e76726du	/* "nvrm" */

struct nvrm_bres {
	nvrm_bclient	*c;
	NvHandle	h;
	struct nvrm_bres *next;		/* in nvrm_bclient.res */
};

struct nvrm_bmem {
	nvrm_bclient	*c;
	NvHandle	h;
	uint64_t	bytes;
	int		place;
	NvP64		cookie;		/* the CPU mapping's RM address */
};

#define SYS	(nvrm_rm_get_sys())

/* Say what failed: an RM status, or the system call. */
int
nvrm_rmm_status_fail(char *err, size_t errlen, const char *what, NvU32 st)
{
	if (st == IOCTL_FAILED) {
		snprintf(err, errlen, "%s: the system call failed: %s", what,
		    strerror(errno));
		return (NVRM_E_IO);
	}
	snprintf(err, errlen, "%s failed (RM status 0x%x)", what,
	    (unsigned)st);
	return (NVRM_E_RM);
}

/* ---- client -------------------------------------------------------------- */

static int
attach_one(nvrm_backend *s, uint32_t id, char *err, size_t errlen)
{
	NV0000_CTRL_GPU_ATTACH_IDS_PARAMS a;
	NvU32 ids[1] = { id };
	unsigned i;
	NvU32 st;

	if (SYS->ioctl(s->fd, IOC_ATTACH(1), ids) != 0) {
		snprintf(err, errlen, "NV_ESC_ATTACH_GPUS_TO_FD failed: %s",
		    strerror(errno));
		return (NVRM_E_IO);
	}
	memset(&a, 0, sizeof(a));
	for (i = 0; i < NV0000_CTRL_GPU_MAX_PROBED_GPUS; i++)
		a.gpuIds[i] = NV0000_CTRL_GPU_INVALID_ID;
	a.gpuIds[0] = id;
	st = nvrm_rm_control(s, s->client, NV0000_CTRL_CMD_GPU_ATTACH_IDS, &a,
	    sizeof(a));
	return (st == NV_OK ? NVRM_OK : nvrm_rmm_status_fail(err, errlen,
	    "NV0000_CTRL_CMD_GPU_ATTACH_IDS", st));
}

static int
alloc_device_and_vaspace(nvrm_bclient *c, uint32_t id, nvrm_vainfo *va,
    char *err, size_t errlen)
{
	NV0000_CTRL_GPU_GET_ID_INFO_V2_PARAMS info;
	NV0080_ALLOC_PARAMETERS dp;
	NV_VASPACE_ALLOCATION_PARAMETERS vp;
	nvrm_backend *s = c->s;
	NvU32 st;

	memset(&info, 0, sizeof(info));
	info.gpuId = id;
	st = nvrm_rm_control(s, s->client, NV0000_CTRL_CMD_GPU_GET_ID_INFO_V2,
	    &info, sizeof(info));
	if (st != NV_OK)
		return (nvrm_rmm_status_fail(err, errlen,
		    "NV0000_CTRL_CMD_GPU_GET_ID_INFO_V2", st));
	memset(&dp, 0, sizeof(dp));
	dp.deviceId = info.deviceInstance;
	dp.vaMode = NV_DEVICE_ALLOCATION_VAMODE_MULTIPLE_VASPACES;
	c->device = nvrm_rm_new_handle(s);
	st = nvrm_rm_alloc(s, s->client, &c->device, NV01_DEVICE_0, &dp,
	    sizeof(dp));
	if (st != NV_OK)
		return (nvrm_rmm_status_fail(err, errlen, "NV01_DEVICE_0 allocation",
		    st));
	memset(&vp, 0, sizeof(vp));
	vp.index = NV_VASPACE_ALLOCATION_INDEX_GPU_NEW;
	vp.flags = NV_VASPACE_ALLOCATION_FLAGS_NONE;
	c->vaspace = nvrm_rm_new_handle(s);
	st = nvrm_rm_alloc(s, c->device, &c->vaspace, FERMI_VASPACE_A, &vp,
	    sizeof(vp));
	if (st != NV_OK)
		return (nvrm_rmm_status_fail(err, errlen, "FERMI_VASPACE_A allocation",
		    st));
	/* On output vaSize is the VA limit plus one, not a length: nvos.h,
	 * NV_VASPACE_ALLOCATION_PARAMETERS, "This corresponds to the
	 * VA_LIMIT + 1, so the usable size is (vaSize - vaBase)". */
	if (vp.vaSize == 0 || vp.vaBase >= vp.vaSize) {
		snprintf(err, errlen, "the RM reported an empty VA space");
		return (NVRM_E_RM);
	}
	va->base = vp.vaBase;
	va->end = vp.vaSize;
	return (NVRM_OK);
}

/* The calls a client needs after the limit: one list, the CPU mapping
 * escapes last (SESSION_CPU_MAP of them), kept only with the opt-in.  A new
 * escape goes above them, and both kinds of client get it. */
#define SESSION_CPU_MAP	2
static const unsigned long session_ioctls[] = {
	IOC_RM_ALLOC, IOC_RM_CONTROL, IOC_RM_FREE, IOC_MAP_DMA, IOC_UNMAP_DMA,
	/* CPU mapping: */
	IOC_MAP_MEMORY, IOC_UNMAP_MEMORY
};

static int
limit_session(nvrm_backend *s, int allow_map)
{
	return (nvrm_cap_limit_fd(s->fd, session_ioctls,
	    nitems(session_ioctls) - (allow_map ? 0 : SESSION_CPU_MAP)));
}

static int
rmm_client_open(nvrm_backend *be, nvrm_gpu *g, const nvrm_open_cfg *cfg,
    nvrm_bclient **bcp, nvrm_vainfo *va, char *err, size_t errlen)
{
	nvrm_bclient *c;
	int rc;

	(void)be;
	if (cfg->allow_map && !g->have_card) {
		snprintf(err, errlen, "the OS layer did not report the "
		    "device node of this GPU, so nothing can be mapped by the "
		    "CPU; open without NVRM_OPEN_ALLOW_MAP to use GPU mappings "
		    "only");
		return (NVRM_E_NOTSUP);
	}
	c = NVRM_CALLOC(1, sizeof(*c));
	if (c == NULL) {
		snprintf(err, errlen, "out of memory");
		return (NVRM_E_NOMEM);
	}
	rc = nvrm_rm_open(&c->s, err, errlen);
	if (rc != NVRM_OK) {
		free(c);
		return (rc);
	}
	c->have_minor = g->have_card;
	c->minor = g->card.minor_number;
	rc = attach_one(c->s, g->id, err, errlen);
	if (rc == NVRM_OK)
		rc = alloc_device_and_vaspace(c, g->id, va, err, errlen);
	if (rc == NVRM_OK && limit_session(c->s, cfg->allow_map) != NVRM_OK) {
		snprintf(err, errlen, "cannot limit the descriptors for "
		    "capability mode");
		rc = NVRM_E_CAPSICUM;
	}
	if (rc != NVRM_OK) {
		nvrm_rm_close(c->s);
		free(c);
		return (rc);
	}
	*bcp = c;
	return (NVRM_OK);
}

static void
rmm_client_close(nvrm_bclient *c)
{
	nvrm_bres *r;

	/* The channel backend's own objects (the subdevice and the usermode
	 * object) go back to the RM first. */
	nvrm_rm_chan_client_close(c);
	/* Reservations whose release the RM refused: the client's free below
	 * takes them in the RM; here only the records go. */
	while ((r = c->res) != NULL) {
		c->res = r->next;
		free(r);
	}
	nvrm_rm_close(c->s);
	free(c);
}

/* The spare descriptors: a mapping one is /dev/nvidiaN, a control-device
 * mapping one is another /dev/nvidiactl, an export one is another
 * /dev/nvidiactl.  Each is limited at once to what it is for. */
static int
rmm_desc_open(nvrm_bclient *c, int kind, int *fd, char *err, size_t errlen)
{
	char path[32];
	const char *p = NVRM_CTL_PATH;

	if (kind == NVRM_DESC_MAP) {
		snprintf(path, sizeof(path), DEVICE_PATH_FMT, c->minor);
		p = path;
	}
	*fd = SYS->open(p, O_RDWR | O_CLOEXEC);
	if (*fd < 0) {
		snprintf(err, errlen, "cannot open %s: %s", p, strerror(errno));
		return (NVRM_E_OPEN);
	}
	if (nvrm_cap_limit_desc(*fd, kind) != NVRM_OK) {
		SYS->close(*fd);
		snprintf(err, errlen, "cannot limit %s for capability mode", p);
		return (NVRM_E_CAPSICUM);
	}
	return (NVRM_OK);
}

/* ---- VA ------------------------------------------------------------------ */

static void
fill_alloc(NV_MEMORY_ALLOCATION_PARAMS *p, uint64_t bytes)
{
	memset(p, 0, sizeof(*p));
	p->owner = OWNER_ID;
	p->type = NVOS32_TYPE_IMAGE;
	p->size = bytes;
}

static int
rmm_va_reserve(nvrm_bclient *c, uint64_t va, uint64_t bytes, int sparse,
    nvrm_bres **rp, char *err, size_t errlen)
{
	NV_MEMORY_ALLOCATION_PARAMS p;
	nvrm_bres *r;
	NvU32 st;

	r = NVRM_CALLOC(1, sizeof(*r));
	if (r == NULL) {
		snprintf(err, errlen, "out of memory");
		return (NVRM_E_NOMEM);
	}
	fill_alloc(&p, bytes);
	p.flags = NVOS32_ALLOC_FLAGS_VIRTUAL |
	    NVOS32_ALLOC_FLAGS_FIXED_ADDRESS_ALLOCATE |
	    (sparse ? NVOS32_ALLOC_FLAGS_SPARSE : 0);
	p.offset = va;
	p.hVASpace = c->vaspace;
	r->c = c;
	r->h = nvrm_rm_new_handle(c->s);
	st = nvrm_rm_alloc(c->s, c->device, &r->h, NV50_MEMORY_VIRTUAL, &p,
	    sizeof(p));
	if (st != NV_OK) {
		free(r);
		return (nvrm_rmm_status_fail(err, errlen, "NV50_MEMORY_VIRTUAL "
		    "allocation", st));
	}
	r->next = c->res;
	c->res = r;
	*rp = r;
	return (NVRM_OK);
}

/* Free an RM object, or only acknowledge the child's local record release. */
static int
free_object(nvrm_bclient *c, NvHandle h, int owner, const char *what,
    char *err, size_t errlen)
{
	NvU32 st;

	if (!owner)
		return (NVRM_OK);
	st = nvrm_rm_free(c->s, c->device, h);
	return (st == NV_OK ? NVRM_OK : nvrm_rmm_status_fail(err, errlen, what, st));
}

/* On a refusal the reservation is kept, so the core can retry it. */
static int
rmm_va_release(nvrm_bres *r, int owner, char *err, size_t errlen)
{
	nvrm_bres **pp;
	int rc;

	rc = free_object(r->c, r->h, owner, "freeing the VA reservation", err,
	    errlen);
	if (rc != NVRM_OK)
		return (rc);
	for (pp = &r->c->res; *pp != r; pp = &(*pp)->next)
		;
	*pp = r->next;
	free(r);
	return (NVRM_OK);
}

/* ---- memory -------------------------------------------------------------- */

/*
 * Page sizes and the RM's attribute fields: one table, used both ways.  The
 * big page is 64 KiB on every GPU generation that has huge pages (nvos.h,
 * NVOS32_ATTR_PAGE_SIZE), which the generation table's page sizes imply; the
 * huge page is chosen by ATTR2.
 */
static const struct page_attr {
	uint64_t	bytes;
	NvU32		size, huge;	/* NVOS32_ATTR_PAGE_SIZE_*, ATTR2 _HUGE_* */
} page_attrs[] = {
	{ 4096, NVOS32_ATTR_PAGE_SIZE_4KB, 0 },
	{ 65536, NVOS32_ATTR_PAGE_SIZE_BIG, 0 },
	{ 2097152, NVOS32_ATTR_PAGE_SIZE_HUGE, NVOS32_ATTR2_PAGE_SIZE_HUGE_2MB },
	{ 536870912, NVOS32_ATTR_PAGE_SIZE_HUGE,
	    NVOS32_ATTR2_PAGE_SIZE_HUGE_512MB },
};

static int
page_size_attrs(uint64_t ps, NvU32 *attr, NvU32 *attr2)
{
	unsigned i;

	for (i = 0; i < nitems(page_attrs); i++)
		if (page_attrs[i].bytes == ps) {
			*attr = FLD_SET_DRF_NUM(OS32, _ATTR, _PAGE_SIZE,
			    page_attrs[i].size, *attr);
			*attr2 = FLD_SET_DRF_NUM(OS32, _ATTR2,
			    _PAGE_SIZE_HUGE, page_attrs[i].huge, *attr2);
			return (NVRM_OK);
		}
	return (NVRM_E_NOTSUP);
}

/* The page size the attribute fields name; 0 when they do not name one
 * (DEFAULT, or a huge size the table does not have). */
static uint64_t
page_size_of(NvU32 attr, NvU32 attr2)
{
	NvU32 size = DRF_VAL(OS32, _ATTR, _PAGE_SIZE, attr);
	NvU32 huge = DRF_VAL(OS32, _ATTR2, _PAGE_SIZE_HUGE, attr2);
	unsigned i;

	for (i = 0; i < nitems(page_attrs); i++)
		if (page_attrs[i].size == size &&
		    (size != NVOS32_ATTR_PAGE_SIZE_HUGE ||
		    page_attrs[i].huge == huge))
			return (page_attrs[i].bytes);
	return (0);
}

/*
 * The page size of an imported object.  Surface info reports the ATTR word
 * only, not ATTR2, so a huge page is 2 MiB or 512 MiB: 2 MiB is reported,
 * the granularity every huge-page object has.  A mapping that fits 2 MiB but
 * not a 512 MiB object's pages is refused by the RM (NVRM_E_RM), never made
 * wrong.  DEFAULT names no size at all; the import is refused, not guessed.
 */
static int
import_page_size(NvU32 attr, uint64_t *ps)
{
	switch (DRF_VAL(OS32, _ATTR, _PAGE_SIZE, attr)) {
	case NVOS32_ATTR_PAGE_SIZE_4KB:
		*ps = 4096;
		return (NVRM_OK);
	case NVOS32_ATTR_PAGE_SIZE_BIG:
		*ps = 65536;
		return (NVRM_OK);
	case NVOS32_ATTR_PAGE_SIZE_HUGE:
		*ps = 2097152;
		return (NVRM_OK);
	default:
		return (NVRM_E_NOTSUP);
	}
}

/* The CPU side of imported system memory, from the coherency the RM keeps. */
static int
import_coherency(NvU32 attr)
{
	switch (DRF_VAL(OS32, _ATTR, _COHERENCY, attr)) {
	case NVOS32_ATTR_COHERENCY_CACHED:
	case NVOS32_ATTR_COHERENCY_WRITE_BACK:
		return (NVRM_COH_CACHED);
	case NVOS32_ATTR_COHERENCY_WRITE_COMBINE:
		return (NVRM_COH_WC);
	default:		/* uncached, write-through, write-protect */
		return (NVRM_COH_UNCACHED);
	}
}

typedef struct surface_raw {
	uint64_t	bytes;
	NvU32		attr, space;
} surface_raw;

/* Query without interpreting DEFAULT, so allocation can tell it from an RM
 * control failure without looking at an error message. */
static int
surface_query(nvrm_bclient *c, NvHandle h, surface_raw *out, char *err,
    size_t errlen)
{
	NV0041_CTRL_GET_SURFACE_INFO_PARAMS p;
	NV0041_CTRL_SURFACE_INFO list[4];
	NvU32 st;

	memset(list, 0, sizeof(list));
	list[0].index = NV0041_CTRL_SURFACE_INFO_INDEX_PHYS_SIZE_LO;
	list[1].index = NV0041_CTRL_SURFACE_INFO_INDEX_PHYS_SIZE_HI;
	list[2].index = NV0041_CTRL_SURFACE_INFO_INDEX_PHYS_ATTR;
	list[3].index = NV0041_CTRL_SURFACE_INFO_INDEX_ADDR_SPACE_TYPE;
	memset(&p, 0, sizeof(p));
	p.surfaceInfoListSize = 4;
	p.surfaceInfoList = NV_PTR_TO_NvP64(list);
	st = nvrm_rm_control(c->s, h, NV0041_CTRL_CMD_GET_SURFACE_INFO, &p,
	    sizeof(p));
	if (st != NV_OK)
		return (nvrm_rmm_status_fail(err, errlen,
		    "NV0041_CTRL_CMD_GET_SURFACE_INFO", st));
	out->bytes = (uint64_t)list[1].data << 32 | list[0].data;
	out->attr = list[2].data;
	out->space = list[3].data;
	return (NVRM_OK);
}

/* Size, page size, place and CPU coherency of an imported object. */
static int
surface_info(nvrm_bclient *c, NvHandle h, nvrm_bmem_info *out, char *err,
    size_t errlen)
{
	surface_raw raw;
	int rc;

	rc = surface_query(c, h, &raw, err, errlen);
	if (rc != NVRM_OK)
		return (rc);
	out->bytes = raw.bytes;
	if (import_page_size(raw.attr, &out->page_size) != NVRM_OK) {
		snprintf(err, errlen, "the imported object does not say its "
		    "page size, so its mappings cannot be checked");
		return (NVRM_E_NOTSUP);
	}
	out->coherency = import_coherency(raw.attr);
	/* ctrl0041.h, NV0041_CTRL_SURFACE_INFO_INDEX_ADDR_SPACE_TYPE: "Returned
	 * values are described by NV0000_CTRL_CMD_CLIENT_GET_ADDR_SPACE_TYPE". */
	if (raw.space == NV0000_CTRL_CMD_CLIENT_GET_ADDR_SPACE_TYPE_VIDMEM)
		out->place = NVRM_PLACE_VIDMEM;
	else if (raw.space == NV0000_CTRL_CMD_CLIENT_GET_ADDR_SPACE_TYPE_SYSMEM)
		out->place = NVRM_PLACE_SYSMEM;
	else {
		snprintf(err, errlen, "the imported object is neither video "
		    "nor system memory");
		return (NVRM_E_RM);
	}
	return (NVRM_OK);
}

/* Hand a just-allocated object back to the RM and drop its record. */
static void
give_back(nvrm_bclient *c, nvrm_bmem *m)
{
	(void)nvrm_rm_free(c->s, c->device, m->h);
	free(m);
}

static int
rmm_mem_alloc(nvrm_bclient *c, const nvrm_balloc *a, nvrm_bmem **mp,
    nvrm_bmem_info *out, char *err, size_t errlen)
{
	NV_MEMORY_ALLOCATION_PARAMS p;
	nvrm_bmem *m;
	surface_raw surface;
	NvU32 st, cls;
	uint64_t got;
	int vid = a->place == NVRM_PLACE_VIDMEM;
	int rc;

	m = NVRM_CALLOC(1, sizeof(*m));
	if (m == NULL) {
		snprintf(err, errlen, "out of memory");
		return (NVRM_E_NOMEM);
	}
	fill_alloc(&p, a->bytes);
	p.attr = DRF_DEF(OS32, _ATTR, _FORMAT, _PITCH) |
	    (vid ? DRF_DEF(OS32, _ATTR, _LOCATION, _VIDMEM) |
		DRF_DEF(OS32, _ATTR, _COHERENCY, _WRITE_COMBINE) :
		DRF_DEF(OS32, _ATTR, _LOCATION, _PCI) |
		DRF_DEF(OS32, _ATTR, _COHERENCY, _CACHED));
	if (page_size_attrs(a->page_size, &p.attr, &p.attr2) != NVRM_OK) {
		free(m);
		snprintf(err, errlen, "a page size of %ju bytes cannot be "
		    "asked of the RM", (uintmax_t)a->page_size);
		return (NVRM_E_NOTSUP);
	}
	if (a->alignment != 0) {
		p.flags |= NVOS32_ALLOC_FLAGS_ALIGNMENT_FORCE;
		p.alignment = a->alignment;
	}
	cls = vid ? NV01_MEMORY_LOCAL_USER : NV01_MEMORY_SYSTEM;
	m->c = c;
	m->h = nvrm_rm_new_handle(c->s);
	st = nvrm_rm_alloc(c->s, c->device, &m->h, cls, &p, sizeof(p));
	if (st != NV_OK) {
		free(m);
		return (nvrm_rmm_status_fail(err, errlen, vid ? "video memory "
		    "allocation" : "system memory allocation", st));
	}
	/* attr and attr2 are IN/OUT: the RM writes back what it allocated.
	 * DEFAULT names no size, so ask the new object's surface info instead of
	 * assuming that the RM used the requested size. */
	got = page_size_of(p.attr, p.attr2);
	if (got == 0 && DRF_VAL(OS32, _ATTR, _PAGE_SIZE, p.attr) ==
	    NVOS32_ATTR_PAGE_SIZE_DEFAULT) {
		rc = surface_query(c, m->h, &surface, err, errlen);
		if (rc != NVRM_OK) {
			give_back(c, m);
			return (rc);
		} else if (DRF_VAL(OS32, _ATTR, _PAGE_SIZE, surface.attr) ==
		    NVOS32_ATTR_PAGE_SIZE_DEFAULT) {
			give_back(c, m);
			/* The core always passes a page size (the caller's or
			 * its default), so 0 never reaches this backend. */
			snprintf(err, errlen, "the RM did not say which page "
			    "size it used for the requested %ju KiB page; the "
			    "object was freed: this RM version cannot be used "
			    "for that allocation",
			    (uintmax_t)(a->page_size >> 10));
			return (NVRM_E_NOTSUP);
		} else
			(void)import_page_size(surface.attr, &got);
	}
	/* A size the table does not have means the RM used a page this library
	 * cannot check mappings against, so the object is given back. */
	if (got == 0) {
		give_back(c, m);
		snprintf(err, errlen, "the RM allocated with a page size this "
		    "library does not know");
		return (NVRM_E_NOTSUP);
	}
	m->bytes = p.size;
	m->place = a->place;
	out->bytes = p.size;
	out->page_size = got;
	out->place = a->place;
	out->coherency = NVRM_COH_CACHED;
	*mp = m;
	return (NVRM_OK);
}

static int
rmm_mem_register(nvrm_bclient *c, void *addr, uint64_t bytes, nvrm_bmem **mp,
    nvrm_bmem_info *out, char *err, size_t errlen)
{
	NV_OS_DESC_MEMORY_ALLOCATION_PARAMS p;
	nvrm_bmem *m;
	NvU32 st;

	m = NVRM_CALLOC(1, sizeof(*m));
	if (m == NULL) {
		snprintf(err, errlen, "out of memory");
		return (NVRM_E_NOMEM);
	}
	memset(&p, 0, sizeof(p));
	p.type = NVOS32_TYPE_IMAGE;
	p.attr = DRF_DEF(OS32, _ATTR, _LOCATION, _PCI) |
	    DRF_DEF(OS32, _ATTR, _FORMAT, _PITCH) |
	    DRF_DEF(OS32, _ATTR, _COHERENCY, _CACHED);
	p.descriptor = NV_PTR_TO_NvP64(addr);
	p.limit = bytes - 1;
	p.descriptorType = NVOS32_DESCRIPTOR_TYPE_VIRTUAL_ADDRESS;
	m->c = c;
	m->h = nvrm_rm_new_handle(c->s);
	st = nvrm_rm_alloc(c->s, c->device, &m->h,
	    NV01_MEMORY_SYSTEM_OS_DESCRIPTOR, &p, sizeof(p));
	if (st != NV_OK) {
		free(m);
		return (nvrm_rmm_status_fail(err, errlen, "registering user pages",
		    st));
	}
	m->bytes = bytes;
	m->place = NVRM_PLACE_SYSMEM;
	out->bytes = bytes;
	out->page_size = 4096;
	out->place = NVRM_PLACE_SYSMEM;
	out->coherency = NVRM_COH_CACHED;
	*mp = m;
	return (NVRM_OK);
}

/* The core has no handle left after this, so the record goes either way; a
 * refused free leaves the object with the RM client until it closes. */
static int
rmm_mem_free(nvrm_bmem *m, int owner, char *err, size_t errlen)
{
	int rc;

	rc = free_object(m->c, m->h, owner, "freeing the memory object", err,
	    errlen);
	free(m);
	return (rc);
}

/* ---- GPU mappings -------------------------------------------------------- */

static int
rmm_map_gpu(nvrm_bmem *m, nvrm_bres *r, uint64_t va, uint64_t offset,
    uint64_t length, int read_only, char *err, size_t errlen)
{
	NVOS46_PARAMETERS p;
	nvrm_bclient *c = m->c;

	memset(&p, 0, sizeof(p));
	p.hClient = c->s->client;
	p.hDevice = c->device;
	p.hDma = r->h;
	p.hMemory = m->h;
	p.offset = offset;
	p.length = length;
	p.flags = DRF_DEF(OS46, _FLAGS, _DMA_OFFSET_FIXED, _TRUE) |
	    (read_only ? DRF_DEF(OS46, _FLAGS, _ACCESS, _READ_ONLY) :
		DRF_DEF(OS46, _FLAGS, _ACCESS, _READ_WRITE)) |
	    (m->place == NVRM_PLACE_SYSMEM ?
		DRF_DEF(OS46, _FLAGS, _CACHE_SNOOP, _ENABLE) : 0);
	p.dmaOffset = va;
	if (SYS->ioctl(c->s->fd, IOC_MAP_DMA, &p) != 0)
		return (nvrm_rmm_status_fail(err, errlen, "NV_ESC_RM_MAP_MEMORY_DMA",
		    IOCTL_FAILED));
	return (p.status == NV_OK ? NVRM_OK : nvrm_rmm_status_fail(err, errlen,
	    "NV_ESC_RM_MAP_MEMORY_DMA", p.status));
}

static int
rmm_unmap_gpu(nvrm_bmem *m, nvrm_bres *r, uint64_t va, uint64_t length,
    int owner, char *err, size_t errlen)
{
	NVOS47_PARAMETERS p;
	nvrm_bclient *c = m->c;

	if (!owner)
		return (NVRM_OK);
	memset(&p, 0, sizeof(p));
	p.hClient = c->s->client;
	p.hDevice = c->device;
	p.hDma = r->h;
	p.hMemory = m->h;
	p.dmaOffset = va;
	p.size = length;
	if (SYS->ioctl(c->s->fd, IOC_UNMAP_DMA, &p) != 0)
		return (nvrm_rmm_status_fail(err, errlen, "NV_ESC_RM_UNMAP_MEMORY_DMA",
		    IOCTL_FAILED));
	return (p.status == NV_OK ? NVRM_OK : nvrm_rmm_status_fail(err, errlen,
	    "NV_ESC_RM_UNMAP_MEMORY_DMA", p.status));
}

/* ---- CPU mappings -------------------------------------------------------- */

/* The RM's name for a memory object. */
NvHandle
nvrm_rmm_handle(const nvrm_bmem *m)
{
	return (m->h);
}

/* A CPU mapping of an RM object by handle: the RM names the address, the
 * OS layer maps the descriptor.  The cookie is the RM's address for the
 * mapping. */
int
nvrm_rmm_map_handle(nvrm_bclient *c, NvHandle h, uint64_t bytes,
    unsigned prot, int fd, struct nvrm_rm_map *map, char *err, size_t errlen)
{
	nv_ioctl_nvos33_parameters_with_fd p;
	char scratch[8];
	void *a;

	memset(&p, 0, sizeof(p));
	p.params.hClient = c->s->client;
	p.params.hDevice = c->device;
	p.params.hMemory = h;
	p.params.offset = 0;
	p.params.length = bytes;
	p.fd = fd;
	if (SYS->ioctl(c->s->fd, IOC_MAP_MEMORY, &p) != 0)
		return (nvrm_rmm_status_fail(err, errlen, "NV_ESC_RM_MAP_MEMORY",
		    IOCTL_FAILED));
	if (p.params.status != NV_OK)
		return (nvrm_rmm_status_fail(err, errlen, "NV_ESC_RM_MAP_MEMORY",
		    p.params.status));
	map->cookie = p.params.pLinearAddress;
	/* The OS layer set the mapping context on this descriptor; the
	 * offset is not used (nvidia_mmap_dev_single). */
	a = mmap(NULL, bytes, ((prot & NVRM_CPU_READ) ? PROT_READ : 0) |
	    ((prot & NVRM_CPU_WRITE) ? PROT_WRITE : 0), MAP_SHARED, fd, 0);
	if (a == MAP_FAILED) {
		snprintf(err, errlen, "mmap of the device failed: %s",
		    strerror(errno));
		/* The mmap error is the one to report. */
		(void)nvrm_rmm_unmap_handle(c, h, map->cookie, NULL, bytes,
		    scratch, sizeof(scratch));
		return (NVRM_E_IO);
	}
	map->addr = a;
	return (NVRM_OK);
}

/* The RM's unmap of a CPU mapping: the address it gave, and the mapping
 * itself when the caller had one (NULL when it never came about). */
int
nvrm_rmm_unmap_handle(nvrm_bclient *c, NvHandle h, NvP64 cookie, void *addr,
    uint64_t bytes, char *err, size_t errlen)
{
	NVOS34_PARAMETERS p;

	if (addr != NULL)
		munmap(addr, bytes);
	memset(&p, 0, sizeof(p));
	p.hClient = c->s->client;
	p.hDevice = c->device;
	p.hMemory = h;
	p.pLinearAddress = cookie;
	if (SYS->ioctl(c->s->fd, IOC_UNMAP_MEMORY, &p) != 0)
		return (nvrm_rmm_status_fail(err, errlen, "NV_ESC_RM_UNMAP_MEMORY",
		    IOCTL_FAILED));
	return (p.status == NV_OK ? NVRM_OK : nvrm_rmm_status_fail(err, errlen,
	    "NV_ESC_RM_UNMAP_MEMORY", p.status));
}

static int
rm_unmap_memory(nvrm_bmem *m, int owner, char *err, size_t errlen)
{
	if (!owner)
		return (NVRM_OK);
	return (nvrm_rmm_unmap_handle(m->c, m->h, m->cookie, NULL, m->bytes,
	    err, errlen));
}

static int
rmm_map_cpu(nvrm_bmem *m, int fd, unsigned prot, void **addr, char *err,
    size_t errlen)
{
	struct nvrm_rm_map map;
	int rc;

	rc = nvrm_rmm_map_handle(m->c, m->h, m->bytes, prot, fd, &map, err,
	    errlen);
	if (rc == NVRM_OK) {
		m->cookie = map.cookie;
		*addr = map.addr;
	}
	return (rc);
}

static int
rmm_unmap_cpu(nvrm_bmem *m, void *addr, int owner, char *err, size_t errlen)
{
	munmap(addr, m->bytes);
	return (rm_unmap_memory(m, owner, err, errlen));
}

/* ---- sharing ------------------------------------------------------------- */

static int
rmm_export_fd(nvrm_bmem *m, int fd, char *err, size_t errlen)
{
	NV0000_CTRL_OS_UNIX_EXPORT_OBJECT_TO_FD_PARAMS p;
	nvrm_bclient *c = m->c;
	NvU32 st;

	memset(&p, 0, sizeof(p));
	p.object.type = NV0000_CTRL_OS_UNIX_EXPORT_OBJECT_TYPE_RM;
	p.object.data.rmObject.hDevice = c->device;
	p.object.data.rmObject.hParent = c->device;
	p.object.data.rmObject.hObject = m->h;
	p.fd = fd;
	st = nvrm_rm_control(c->s, c->s->client,
	    NV0000_CTRL_CMD_OS_UNIX_EXPORT_OBJECT_TO_FD, &p, sizeof(p));
	return (st == NV_OK ? NVRM_OK : nvrm_rmm_status_fail(err, errlen,
	    "NV0000_CTRL_CMD_OS_UNIX_EXPORT_OBJECT_TO_FD", st));
}

static int
rmm_import_fd(nvrm_bclient *c, int fd, nvrm_bmem **mp, nvrm_bmem_info *out,
    char *err, size_t errlen)
{
	NV0000_CTRL_OS_UNIX_IMPORT_OBJECT_FROM_FD_PARAMS p;
	nvrm_bmem *m;
	char scratch[8];
	NvU32 st;
	int rc;

	m = NVRM_CALLOC(1, sizeof(*m));
	if (m == NULL) {
		snprintf(err, errlen, "out of memory");
		return (NVRM_E_NOMEM);
	}
	memset(&p, 0, sizeof(p));
	p.fd = fd;
	p.object.type = NV0000_CTRL_OS_UNIX_EXPORT_OBJECT_TYPE_RM;
	p.object.data.rmObject.hDevice = c->device;
	p.object.data.rmObject.hParent = c->device;
	p.object.data.rmObject.hObject = nvrm_rm_new_handle(c->s);
	st = nvrm_rm_control(c->s, c->s->client,
	    NV0000_CTRL_CMD_OS_UNIX_IMPORT_OBJECT_FROM_FD, &p, sizeof(p));
	if (st != NV_OK) {
		free(m);
		return (nvrm_rmm_status_fail(err, errlen,
		    "NV0000_CTRL_CMD_OS_UNIX_IMPORT_OBJECT_FROM_FD", st));
	}
	m->c = c;
	m->h = p.object.data.rmObject.hObject;
	rc = surface_info(c, m->h, out, err, errlen);
	if (rc != NVRM_OK) {
		/* The surface-info error is the one to report. */
		(void)free_object(c, m->h, 1, "freeing the import", scratch,
		    sizeof(scratch));
		free(m);
		return (rc);
	}
	m->bytes = out->bytes;
	m->place = out->place;
	*mp = m;
	return (NVRM_OK);
}

static int
rmm_host_arm64(void)
{
#ifdef __aarch64__
	return (1);
#else
	return (0);
#endif
}

const nvrm_mem_ops nvrm_rm_mem_ops = {
	.client_open = rmm_client_open,
	.client_close = rmm_client_close,
	.desc_open = rmm_desc_open,
	.va_reserve = rmm_va_reserve,
	.va_release = rmm_va_release,
	.mem_alloc = rmm_mem_alloc,
	.mem_register = rmm_mem_register,
	.mem_free = rmm_mem_free,
	.map_gpu = rmm_map_gpu,
	.unmap_gpu = rmm_unmap_gpu,
	.map_cpu = rmm_map_cpu,
	.unmap_cpu = rmm_unmap_cpu,
	.export_fd = rmm_export_fd,
	.import_fd = rmm_import_fd,
	.host_arm64 = rmm_host_arm64,
	.cpu_access = NULL,
};

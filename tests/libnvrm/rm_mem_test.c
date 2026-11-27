/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * rm_mem_test.c - the RM backend's memory and VA calls (nvrm_rm_mem.c, Track
 * #2419) against a scripted kernel.  The discovery escapes are the ones of
 * scripted_rm.h (rm_test.c); this file stands a memory model in front of
 * them: several RM sessions (one per descriptor, as the RM has them), the
 * VA space, virtual and physical memory objects, GPU and CPU mappings and
 * export and import by descriptor, built from NVIDIA's own structures and
 * checking every request.  Each error path of the backend is driven by
 * making one step of the scripted kernel fail.  No driver and no hardware.
 *
 * The device node of the GPU comes from the card list (minor 1 here, as on
 * amp001, where a BMC display chip is the minor 0): nothing here or in the
 * library names /dev/nvidia0.
 */
#include <sys/param.h>
#include <sys/capsicum.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <sys/wait.h>

#include <errno.h>
#include <fcntl.h>
#include <malloc_np.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <nvtypes.h>
#include <nvstatus.h>
#include <nvmisc.h>
#include <nvos.h>
#include <nv-ioctl.h>
#include <nv_escape.h>
#include <nv-unix-nvos-params-wrappers.h>
#include <class/cl0000.h>
#include <class/cl003e.h>
#include <class/cl0040.h>
#include <class/cl0070.h>
#include <class/cl0071.h>
#include <class/cl0080.h>
#include <class/cl2080.h>
#include <class/cl50a0.h>
#include <class/cl90f1.h>
#include <ctrl/ctrl0000/ctrl0000client.h>
#include <ctrl/ctrl0000/ctrl0000gpu.h>
#include <ctrl/ctrl0000/ctrl0000unix.h>
#include <ctrl/ctrl0041.h>
#include <ctrl/ctrl0080/ctrl0080gpu.h>
#include <ctrl/ctrl2080/ctrl2080bios.h>
#include <ctrl/ctrl2080/ctrl2080bus.h>
#include <ctrl/ctrl2080/ctrl2080fb.h>
#include <ctrl/ctrl2080/ctrl2080gpu.h>
#include <ctrl/ctrl2080/ctrl2080gr.h>
#include <ctrl/ctrl2080/ctrl2080gsp.h>
#include <ctrl/ctrl2080/ctrl2080mc.h>

#include "nvrm_rm_priv.h"	/* struct nvrm_gpu: the card-list test below */
#include "nvrm_rm_sys.h"
#include "t.h"

#include "fault_calloc.h"

#include "scripted_rm.h"

static void
fail_calloc_at(int n)
{
	calloc_calls = 0;
	calloc_fail_at = n;
}

#define KiB		1024ULL
#define MiB		(1024ULL * KiB)
#define GPU_MINOR	1
#define COOKIE		0x7000000000ULL
#define MOBJ		256
#define NOVERRIDE	0xffffffffu

/* ---- the memory model of the scripted kernel ---------------------------- */

typedef struct mobj {
	int		fd;		/* the session */
	NvHandle	h;
	NvU32		cls;
	uint64_t	size, offset;
	NvU32		attr, attr2, flags;
	int		live;		/* not freed yet */
	int		explicit_free;	/* freed by RM_FREE of the object itself */
} mobj;

static struct {
	int		enum_fd;	/* the enumeration's session */
	mobj		o[MOBJ];
	int		n;
	/* configuration */
	NvU64		va_base, va_size;
	NvU32		wb_page, wb_huge;	/* page size written back, or NOVERRIDE */
	NvU32		surf_attr, surf_space;	/* surface info answers, or NOVERRIDE */
	uint64_t	surf_size;
	int		map_dev_null;	/* /dev/nvidiaN is a node that cannot be mapped */
	int		fail_map_open;	/* opening /dev/nvidiaN fails */
	/* hand out a descriptor limited already to less than the library
	 * limits it to, so that its limit fails (rights only narrow) */
	int		prelimit_session, prelimit_map;
	/* failure injection: the next escape nr fails; its ioctl(2) or its
	 * RM status */
	int		fail_nr;
	int		status_nr;
	NvU32		status_val;
	NvU32		fail_cls;	/* allocation of this class fails */
	NvU32		fail_ctl;	/* this control fails with status_val */
	/* record */
	int		session_fd;	/* the last session's descriptor */
	int		nversion, ndevice, nvaspace, nvirtual, nvid, nsys, nos;
	int		nmapdma, nunmapdma, nmapmem, nunmapmem, nmunmap;
	int		nexport, nimport, nsurf, nmine_free, map_opens, open_calls;
	NVOS46_PARAMETERS last46;
	NV_MEMORY_ALLOCATION_PARAMS last_alloc;
	char		last_map_path[64];
	struct { int fd; int obj; } ex[32];
	int		nex;
} M;

static void
reset_all(void)
{
	reset_kernel();
	K.have_card[0] = 1;
	memset(&M, 0, sizeof(M));
	M.enum_fd = -1;
	M.va_base = 0x100000;
	M.va_size = 1ULL << 40;
	M.wb_page = M.wb_huge = NOVERRIDE;
	M.surf_attr = M.surf_space = NOVERRIDE;
	M.fail_nr = M.status_nr = -1;
	M.fail_cls = NOVERRIDE;
	M.fail_ctl = NOVERRIDE;
}

/* Interpose the memory backend's process-local unmap as part of mem_sys. */
int
munmap(void *addr, size_t len)
{
	M.nmunmap++;
	return (syscall(SYS_munmap, addr, len));
}

static mobj *
find(int fd, NvHandle h)
{
	int i;

	for (i = 0; i < M.n; i++)
		if (M.o[i].fd == fd && M.o[i].h == h && M.o[i].live)
			return (&M.o[i]);
	return (NULL);
}

/* How many objects of a session are still live in the scripted kernel. */
static int
live_in_session(int fd)
{
	int i, n = 0;

	for (i = 0; i < M.n; i++)
		n += M.o[i].fd == fd && M.o[i].live;
	return (n);
}

static mobj *
add(int fd, NvHandle h, NvU32 cls)
{
	mobj *o;

	if (find(fd, h) != NULL)
		bad("a handle allocated twice in one session");
	if (M.n == MOBJ) {
		bad("too many objects");
		return (&M.o[0]);
	}
	o = &M.o[M.n++];
	memset(o, 0, sizeof(*o));
	o->fd = fd;
	o->h = h;
	o->cls = cls;
	o->live = 1;
	return (o);
}

/* Objects of the memory classes still live, explicitly or not freed. */
static int
live_memory(void)
{
	int i, n = 0;

	for (i = 0; i < M.n; i++)
		if (M.o[i].live && M.o[i].cls != NV01_DEVICE_0 &&
		    M.o[i].cls != FERMI_VASPACE_A)
			n++;
	return (n);
}

/* Memory objects the library let the client's free take with it. */
static int
not_freed_explicitly(void)
{
	int i, n = 0;

	for (i = 0; i < M.n; i++)
		if (!M.o[i].explicit_free && M.o[i].cls != NV01_DEVICE_0 &&
		    M.o[i].cls != FERMI_VASPACE_A)
			n++;
	return (n);
}

static int
fails_now(int nr)
{
	if (M.fail_nr != nr)
		return (0);
	M.fail_nr = -1;
	errno = EIO;
	return (1);
}

static NvU32
status_now(int nr)
{
	if (M.status_nr != nr)
		return (NV_OK);
	M.status_nr = -1;
	return (M.status_val);
}

static int
m_open(const char *path, int flags)
{
	char want[32];
	int fd;

	M.open_calls++;
	if (strcmp(path, "/dev/nvidiactl") == 0) {
		fd = k_open(path, flags);
		if (M.enum_fd < 0)
			M.enum_fd = fd;
		else if (M.prelimit_session && fd >= 0) {
			cap_rights_t r;

			M.prelimit_session = 0;
			cap_rights_init(&r, CAP_READ);
			if (cap_rights_limit(fd, &r) != 0)
				bad("cannot pre-limit a session descriptor");
		}
		return (fd);
	}
	snprintf(want, sizeof(want), "/dev/nvidia%u", GPU_MINOR);
	snprintf(M.last_map_path, sizeof(M.last_map_path), "%s", path);
	if (strcmp(path, want) != 0)
		bad("opened a device node that is not the GPU's");
	if ((flags & O_RDWR) == 0)
		bad("device node not opened read-write");
	if (M.fail_map_open) {
		errno = EACCES;
		return (-1);
	}
	M.map_opens++;
	if (M.map_dev_null)
		return (open("/dev/null", O_RDWR | O_CLOEXEC));
	fd = shm_open(SHM_ANON, O_RDWR | O_CLOEXEC, 0600);
	if (fd >= 0 && ftruncate(fd, 64 * MiB) != 0)
		bad("cannot size the stand-in device node");
	if (M.prelimit_map && fd >= 0) {
		cap_rights_t r;

		M.prelimit_map = 0;
		cap_rights_init(&r, CAP_READ);
		if (cap_rights_limit(fd, &r) != 0)
			bad("cannot pre-limit a device node");
	}
	return (fd);
}

/* ---- allocations ---------------------------------------------------------- */

static void
check_memory_class(int fd, NVOS21_PARAMETERS *p,
    NV_MEMORY_ALLOCATION_PARAMS *a)
{
	mobj *vas;

	if (p->hClass == NV50_MEMORY_VIRTUAL) {
		vas = find(fd, a->hVASpace);
		if (vas == NULL || vas->cls != FERMI_VASPACE_A)
			bad("virtual memory not in the session's VA space");
		if ((a->flags & NVOS32_ALLOC_FLAGS_VIRTUAL) == 0 ||
		    (a->flags & NVOS32_ALLOC_FLAGS_FIXED_ADDRESS_ALLOCATE) == 0)
			bad("virtual memory not at a fixed address");
		M.nvirtual++;
	} else if (p->hClass == NV01_MEMORY_LOCAL_USER) {
		if (DRF_VAL(OS32, _ATTR, _LOCATION, a->attr) !=
		    NVOS32_ATTR_LOCATION_VIDMEM)
			bad("video memory without the video memory location");
		M.nvid++;
	} else {
		if (DRF_VAL(OS32, _ATTR, _LOCATION, a->attr) !=
		    NVOS32_ATTR_LOCATION_PCI)
			bad("system memory without the PCI location");
		M.nsys++;
	}
}

static void
alloc_memory(int fd, NVOS21_PARAMETERS *p)
{
	NV_MEMORY_ALLOCATION_PARAMS *a = NvP64_VALUE(p->pAllocParms);
	mobj *o;

	if (p->paramsSize != sizeof(*a)) {
		bad("memory allocation parameter size");
		p->status = NV_ERR_INVALID_PARAM_STRUCT;
		return;
	}
	M.last_alloc = *a;
	if (find(fd, p->hObjectParent) == NULL ||
	    find(fd, p->hObjectParent)->cls != NV01_DEVICE_0)
		bad("memory not allocated under the session's device");
	if (a->owner == 0 || a->size == 0)
		bad("memory allocation without owner or size");
	check_memory_class(fd, p, a);
	if (M.wb_page != NOVERRIDE)
		a->attr = FLD_SET_DRF_NUM(OS32, _ATTR, _PAGE_SIZE, M.wb_page,
		    a->attr);
	if (M.wb_huge != NOVERRIDE)
		a->attr2 = FLD_SET_DRF_NUM(OS32, _ATTR2, _PAGE_SIZE_HUGE,
		    M.wb_huge, a->attr2);
	o = add(fd, p->hObjectNew, p->hClass);
	o->size = a->size;
	o->offset = a->offset;
	o->attr = a->attr;
	o->attr2 = a->attr2;
	o->flags = a->flags;
}

static void
m_alloc_device(int fd, NVOS21_PARAMETERS *p)
{
	NV0080_ALLOC_PARAMETERS *a = NvP64_VALUE(p->pAllocParms);

	if (p->hRoot != CLIENT || p->hObjectParent != CLIENT)
		bad("device not under the session's client");
	if (p->paramsSize != sizeof(*a) || a->deviceId != 0 ||
	    a->vaMode != NV_DEVICE_ALLOCATION_VAMODE_MULTIPLE_VASPACES)
		bad("device allocation parameters");
	add(fd, p->hObjectNew, p->hClass);
	M.ndevice++;
}

static void
m_alloc_vaspace(int fd, NVOS21_PARAMETERS *p)
{
	NV_VASPACE_ALLOCATION_PARAMETERS *v = NvP64_VALUE(p->pAllocParms);

	if (p->paramsSize != sizeof(*v) ||
	    v->index != NV_VASPACE_ALLOCATION_INDEX_GPU_NEW)
		bad("VA space allocation parameters");
	if (find(fd, p->hObjectParent) == NULL)
		bad("VA space not under the session's device");
	v->vaBase = M.va_base;
	v->vaSize = M.va_size;
	add(fd, p->hObjectNew, p->hClass);
	M.nvaspace++;
}

static void
m_alloc_osdesc(int fd, NVOS21_PARAMETERS *p)
{
	NV_OS_DESC_MEMORY_ALLOCATION_PARAMS *d =
	    NvP64_VALUE(p->pAllocParms);
	mobj *o;

	if (p->paramsSize != sizeof(*d) ||
	    d->descriptorType != NVOS32_DESCRIPTOR_TYPE_VIRTUAL_ADDRESS ||
	    NvP64_VALUE(d->descriptor) == NULL)
		bad("user pages allocation parameters");
	o = add(fd, p->hObjectNew, p->hClass);
	o->size = d->limit + 1;
	o->attr = d->attr;
	M.nos++;
}

static void
m_alloc(int fd, NVOS21_PARAMETERS *p)
{
	p->status = NV_OK;
	if (p->hClass == M.fail_cls) {
		M.fail_cls = NOVERRIDE;
		p->status = NV_ERR_NO_MEMORY;
		return;
	}
	switch (p->hClass) {
	case NV01_DEVICE_0:
		m_alloc_device(fd, p);
		return;
	case FERMI_VASPACE_A:
		m_alloc_vaspace(fd, p);
		return;
	case NV50_MEMORY_VIRTUAL:
	case NV01_MEMORY_LOCAL_USER:
	case NV01_MEMORY_SYSTEM:
		alloc_memory(fd, p);
		return;
	case NV01_MEMORY_SYSTEM_OS_DESCRIPTOR:
		m_alloc_osdesc(fd, p);
		return;
	default:
		bad("a class the memory backend should not allocate");
		p->status = NV_ERR_INVALID_CLASS;
	}
}

/* ---- controls --------------------------------------------------------------- */

/* #lizard forgives -- the scripted kernel mirrors the RM control switch, one case per control (as scripted_rm.h) */
static int
m_control(int fd, NVOS54_PARAMETERS *p)
{
	mobj *o;
	int i;

	if (p->cmd == M.fail_ctl) {
		M.fail_ctl = NOVERRIDE;
		p->status = M.status_val;
		return (1);
	}
	p->status = NV_OK;
	switch (p->cmd) {
	case NV0000_CTRL_CMD_OS_UNIX_EXPORT_OBJECT_TO_FD: {
		NV0000_CTRL_OS_UNIX_EXPORT_OBJECT_TO_FD_PARAMS *a =
		    NvP64_VALUE(p->params);

		if (p->paramsSize != sizeof(*a) || p->hObject != CLIENT ||
		    a->object.type != NV0000_CTRL_OS_UNIX_EXPORT_OBJECT_TYPE_RM)
			bad("export parameters");
		o = find(fd, a->object.data.rmObject.hObject);
		if (o == NULL || a->fd < 0) {
			bad("export of an object that is not live");
			p->status = NV_ERR_INVALID_OBJECT_HANDLE;
			return (1);
		}
		M.ex[M.nex].fd = a->fd;
		M.ex[M.nex++].obj = (int)(o - M.o);
		M.nexport++;
		return (1);
	}
	case NV0000_CTRL_CMD_OS_UNIX_IMPORT_OBJECT_FROM_FD: {
		NV0000_CTRL_OS_UNIX_IMPORT_OBJECT_FROM_FD_PARAMS *a =
		    NvP64_VALUE(p->params);
		mobj *src, *n;

		if (p->paramsSize != sizeof(*a) || p->hObject != CLIENT)
			bad("import parameters");
		for (i = M.nex - 1; i >= 0 && M.ex[i].fd != a->fd; i--)
			;
		if (i < 0) {
			p->status = NV_ERR_INVALID_ARGUMENT;
			return (1);
		}
		src = &M.o[M.ex[i].obj];
		n = add(fd, a->object.data.rmObject.hObject, src->cls);
		n->size = src->size;
		n->attr = src->attr;
		n->attr2 = src->attr2;
		M.nimport++;
		return (1);
	}
	case NV0041_CTRL_CMD_GET_SURFACE_INFO: {
		NV0041_CTRL_GET_SURFACE_INFO_PARAMS *a = NvP64_VALUE(p->params);
		NV0041_CTRL_SURFACE_INFO *l = NvP64_VALUE(a->surfaceInfoList);
		uint64_t size;

		o = find(fd, p->hObject);
		if (p->paramsSize != sizeof(*a) || o == NULL) {
			bad("surface info parameters, or not on a live object");
			p->status = NV_ERR_INVALID_OBJECT_HANDLE;
			return (1);
		}
		M.nsurf++;
		size = M.surf_size != 0 ? M.surf_size : o->size;
		for (i = 0; i < (int)a->surfaceInfoListSize; i++)
			switch (l[i].index) {
			case NV0041_CTRL_SURFACE_INFO_INDEX_PHYS_SIZE_LO:
				l[i].data = (NvU32)size;
				break;
			case NV0041_CTRL_SURFACE_INFO_INDEX_PHYS_SIZE_HI:
				l[i].data = (NvU32)(size >> 32);
				break;
			case NV0041_CTRL_SURFACE_INFO_INDEX_PHYS_ATTR:
				l[i].data = M.surf_attr != NOVERRIDE ?
				    M.surf_attr : o->attr;
				break;
			case NV0041_CTRL_SURFACE_INFO_INDEX_ADDR_SPACE_TYPE:
				l[i].data = M.surf_space != NOVERRIDE ?
				    M.surf_space : o->cls ==
				    NV01_MEMORY_LOCAL_USER ?
				    NV0000_CTRL_CMD_CLIENT_GET_ADDR_SPACE_TYPE_VIDMEM :
				    NV0000_CTRL_CMD_CLIENT_GET_ADDR_SPACE_TYPE_SYSMEM;
				break;
			default:
				bad("a surface info index not asked for");
			}
		return (1);
	}
	default:
		return (0);	/* discovery: scripted_rm.h */
	}
}

/* ---- the escapes ------------------------------------------------------------- */

/* #lizard forgives -- the scripted kernel mirrors the escape switch, one case per escape */
static int
m_ioctl(int fd, unsigned long cmd, void *arg)
{
	int nr = cmd & 0xff;
	int mine = fd != M.enum_fd;

	if (fails_now(nr))
		return (-1);
	switch (nr) {
	case NV_ESC_CHECK_VERSION_STR:
		if (mine) {
			nv_ioctl_rm_api_version_t *v = arg;

			if (v->cmd == NV_RM_API_VERSION_CMD_QUERY) {
				/* the RM API version query of the session
				 * (nvrm_rm_api_version(3)): not the check */
				v->reply = NV_RM_API_VERSION_REPLY_RECOGNIZED;
				snprintf(v->versionString,
				    sizeof(v->versionString), "%s",
				    NVRM_RM_VERSION);
				return (0);
			}
			if (v->cmd != NV_RM_API_VERSION_CMD_STRICT ||
			    strcmp(v->versionString, NVRM_RM_VERSION) != 0)
				bad("session version check");
			v->reply = NV_RM_API_VERSION_REPLY_RECOGNIZED;
			M.nversion++;
			M.session_fd = fd;
			return (0);
		}
		break;
	case NV_ESC_IOCTL_XFER_CMD: {
		nv_ioctl_xfer_t *x = arg;
		nv_ioctl_card_info_t *ci;
		int rc = k_ioctl(fd, cmd, arg);

		ci = NvP64_VALUE(x->ptr);
		if (rc == 0 && ci[0].valid)
			ci[0].minor_number = GPU_MINOR;
		return (rc);
	}
	case NV_ESC_RM_ALLOC: {
		NVOS21_PARAMETERS *p = arg;

		if (mine && p->hClass != NV01_ROOT &&
		    p->hClass != NV01_ROOT_CLIENT) {
			m_alloc(fd, p);
			return (0);
		}
		break;
	}
	case NV_ESC_RM_CONTROL:
		if (mine && m_control(fd, arg))
			return (0);
		break;
	case NV_ESC_RM_FREE: {
		NVOS00_PARAMETERS *p = arg;
		mobj *o;
		int i;

		if (!mine)
			break;
		if (p->hObjectOld == CLIENT) {
			/* the client takes everything of its session */
			for (i = 0; i < M.n; i++)
				if (M.o[i].fd == fd)
					M.o[i].live = 0;
			break;
		}
		o = find(fd, p->hObjectOld);
		if (o == NULL) {
			bad("free of a handle that is not live in the session");
			p->status = NV_ERR_INVALID_OBJECT_HANDLE;
			return (0);
		}
		if (p->hRoot != CLIENT)
			bad("free without the session's client");
		p->status = status_now(nr);
		if (p->status == NV_OK) {
			o->live = 0;
			o->explicit_free = 1;
		}
		M.nmine_free++;
		return (0);
	}
	case NV_ESC_RM_MAP_MEMORY_DMA: {
		NVOS46_PARAMETERS *p = arg;
		mobj *dma = find(fd, p->hDma), *mem = find(fd, p->hMemory);

		if (IOCPARM_LEN(cmd) != sizeof(*p) || p->hClient != CLIENT ||
		    dma == NULL || dma->cls != NV50_MEMORY_VIRTUAL ||
		    mem == NULL || mem->cls == NV50_MEMORY_VIRTUAL)
			bad("GPU map parameters");
		if (DRF_VAL(OS46, _FLAGS, _DMA_OFFSET_FIXED, p->flags) !=
		    NVOS46_FLAGS_DMA_OFFSET_FIXED_TRUE)
			bad("GPU map not at a fixed address");
		if (dma != NULL && (p->dmaOffset < dma->offset ||
		    p->dmaOffset + p->length > dma->offset + dma->size))
			bad("GPU map outside its reservation");
		M.last46 = *p;
		M.nmapdma++;
		p->status = status_now(nr);
		return (0);
	}
	case NV_ESC_RM_UNMAP_MEMORY_DMA: {
		NVOS47_PARAMETERS *p = arg;

		if (IOCPARM_LEN(cmd) != sizeof(*p) || p->hClient != CLIENT ||
		    find(fd, p->hDma) == NULL || find(fd, p->hMemory) == NULL)
			bad("GPU unmap parameters");
		M.nunmapdma++;
		p->status = status_now(nr);
		return (0);
	}
	case NV_ESC_RM_MAP_MEMORY: {
		nv_ioctl_nvos33_parameters_with_fd *p = arg;

		if (IOCPARM_LEN(cmd) != sizeof(*p) || p->params.hClient !=
		    CLIENT || find(fd, p->params.hMemory) == NULL ||
		    p->fd < 0 || p->params.length == 0)
			bad("CPU map parameters");
		M.nmapmem++;
		p->params.status = status_now(nr);
		p->params.pLinearAddress = NV_PTR_TO_NvP64((void *)(uintptr_t)
		    (COOKIE + M.nmapmem));
		return (0);
	}
	case NV_ESC_RM_UNMAP_MEMORY: {
		NVOS34_PARAMETERS *p = arg;

		if (IOCPARM_LEN(cmd) != sizeof(*p) || p->hClient != CLIENT ||
		    find(fd, p->hMemory) == NULL ||
		    (uintptr_t)NvP64_VALUE(p->pLinearAddress) <= COOKIE)
			bad("CPU unmap parameters");
		M.nunmapmem++;
		p->status = status_now(nr);
		return (0);
	}
	default:
		break;
	}
	return (k_ioctl(fd, cmd, arg));
}

static const nvrm_rm_sys mem_sys = { m_open, k_close, m_ioctl, k_sysctl,
    k_access };

/* The escapes a session descriptor may issue after its limit. */
static int
session_allows(int fd, unsigned long cmd)
{
	unsigned long cmds[16];
	ssize_t n;
	int i;

	n = cap_ioctls_get(fd, cmds, nitems(cmds));
	for (i = 0; i < n; i++)
		if (cmds[i] == cmd)
			return (1);
	return (0);
}

#define IOC_MAP_MEMORY_T	_IOWR(NV_IOCTL_MAGIC, NV_ESC_RM_MAP_MEMORY, \
				    nv_ioctl_nvos33_parameters_with_fd)
#define IOC_MAP_DMA_T		_IOWR(NV_IOCTL_MAGIC, NV_ESC_RM_MAP_MEMORY_DMA, \
				    NVOS46_PARAMETERS)
#define IOC_UNMAP_MEMORY_T	_IOWR(NV_IOCTL_MAGIC, NV_ESC_RM_UNMAP_MEMORY, \
				    NVOS34_PARAMETERS)
#define IOC_UNMAP_DMA_T		_IOWR(NV_IOCTL_MAGIC, \
				    NV_ESC_RM_UNMAP_MEMORY_DMA, NVOS47_PARAMETERS)

/* What every client keeps, with or without the CPU mapping opt-in. */
static const unsigned long base_escapes[] = {
	IOC_RM_ALLOC, IOC_RM_CONTROL, IOC_RM_FREE, IOC_MAP_DMA_T, IOC_UNMAP_DMA_T
};

/* ---- helpers ------------------------------------------------------------------ */

static nvrm_ctx *ctx;

static void
up(void)
{
	nvrm_enum_opts o = { "rm" };
	char err[300];

	reset_all();
	CHECK_EQ(nvrm_enumerate(&ctx, &o, err, sizeof(err)), NVRM_OK);
	if (ctx == NULL) {
		printf("fatal: enumerate failed: %s (kernel: %s)\n", err,
		    K.badmsg);
		exit(1);
	}
}

static void
down(const char *what)
{
	nvrm_close(ctx);
	ctx = NULL;
	if (K.bad || live_memory() != 0)
		printf("FAIL after %s: kernel refused %d requests (last: %s), "
		    "%d memory objects live\n", what, K.bad, K.badmsg,
		    live_memory());
	CHECK_EQ(K.bad, 0);
	CHECK_EQ(live_memory(), 0);
}

static int
open_cl(unsigned flags, nvrm_client **cl, char *err, size_t errlen)
{
	nvrm_open_opts o = { 0, flags, 2, 2 };

	*cl = NULL;
	return (nvrm_client_open(nvrm_device_get(ctx, 0), &o, cl, err, errlen));
}

static nvrm_client *
client(unsigned flags)
{
	char err[300];
	nvrm_client *cl;

	CHECK_EQ(open_cl(flags, &cl, err, sizeof(err)), NVRM_OK);
	if (cl == NULL) {
		printf("fatal: device open failed: %s (kernel: %s)\n", err,
		    K.badmsg);
		exit(1);
	}
	return (cl);
}

static int
alloc(nvrm_client *cl, int kind, uint64_t bytes, uint64_t ps, nvrm_mem **m)
{
	nvrm_mem_params p = { 0, (uint32_t)kind, 0, 0, bytes, 0, ps };

	*m = NULL;
	return (nvrm_mem_alloc(cl, &p, m));
}

static uint64_t
reserve(nvrm_client *cl, uint64_t bytes, uint32_t flags)
{
	nvrm_va_params p = { 0, flags, bytes, 0, 0 };
	uint64_t va = 0;

	CHECK_EQ(nvrm_va_reserve(cl, &p, &va), NVRM_OK);
	return (va);
}

static int
map_gpu(nvrm_mem *m, uint64_t va, uint32_t flags)
{
	nvrm_gpu_map_params p = { 0, flags, va, 0, 0 };

	return (nvrm_mem_map_gpu(m, &p));
}

static uint64_t
page_of(nvrm_mem *m)
{
	nvrm_mem_info mi = { 0 };

	CHECK_EQ(nvrm_mem_info_get(m, &mi), NVRM_OK);
	return (mi.page_size);
}

static nvrm_mem_info
info_of(nvrm_mem *m)
{
	nvrm_mem_info mi = { 0 };

	CHECK_EQ(nvrm_mem_info_get(m, &mi), NVRM_OK);
	return (mi);
}

static uint64_t
failed(nvrm_client *cl)
{
	nvrm_client_stats st = { 0 };

	nvrm_client_stats_get(cl, &st);
	return (st.failed_releases);
}

#define HAS(cl, s)	CHECK(strstr(nvrm_client_errmsg(cl), (s)) != NULL)

static void
has_surface_error(nvrm_client *cl)
{
	char want[128];

	snprintf(want, sizeof(want), "NV0041_CTRL_CMD_GET_SURFACE_INFO failed "
	    "(RM status 0x%x)", (unsigned)NV_ERR_INVALID_OBJECT);
	CHECK_STR(nvrm_client_errmsg(cl), want);
}

/* ---- the client ------------------------------------------------------------- */

static void
test_open(void)
{
	nvrm_vaspace_info vi = { 0 };
	nvrm_client *cl;
	unsigned i;

	up();
	cl = client(NVRM_OPEN_ALLOW_MAP);
	/* a session of its own: its own version check, client, device and
	 * VA space; the VA range is [vaBase, vaSize): vaSize is the limit
	 * plus one (nvos.h) */
	CHECK_EQ(M.nversion, 1);
	CHECK_EQ(M.ndevice, 1);
	CHECK_EQ(M.nvaspace, 1);
	CHECK_EQ(nvrm_vaspace_info_get(cl, &vi), NVRM_OK);
	CHECK_EQ(vi.base, 0x100000);
	CHECK_EQ(vi.end, 1ULL << 40);
	/* the spare mapping descriptors are the GPU's node from the card list */
	CHECK_EQ(M.map_opens, 2);
	CHECK_STR(M.last_map_path, "/dev/nvidia1");
	/* the session keeps the CPU mapping escapes only with the opt-in, and
	 * every other escape in both kinds of client */
	CHECK(session_allows(M.session_fd, IOC_MAP_MEMORY_T));
	CHECK(session_allows(M.session_fd, IOC_UNMAP_MEMORY_T));
	for (i = 0; i < nitems(base_escapes); i++)
		CHECK(session_allows(M.session_fd, base_escapes[i]));
	nvrm_client_close(cl);
	cl = client(0);
	CHECK(!session_allows(M.session_fd, IOC_MAP_MEMORY_T));
	CHECK(!session_allows(M.session_fd, IOC_UNMAP_MEMORY_T));
	for (i = 0; i < nitems(base_escapes); i++)
		CHECK(session_allows(M.session_fd, base_escapes[i]));
	nvrm_client_close(cl);
	/* a small window above a nonzero base: the end is vaSize itself */
	M.va_base = 0x100000;
	M.va_size = 0x200000;
	cl = client(0);
	CHECK_EQ(nvrm_vaspace_info_get(cl, &vi), NVRM_OK);
	CHECK_EQ(vi.base, 0x100000);
	CHECK_EQ(vi.end, 0x200000);
	CHECK_EQ(vi.free_bytes, 0x100000);
	nvrm_client_close(cl);
	down("open");
}

static void
test_open_failures(void)
{
	nvrm_client *cl;
	char err[300];
	int n;

	up();
	/* the RM's VA space is empty, or inverted */
	M.va_size = 0;
	CHECK_EQ(open_cl(0, &cl, err, sizeof(err)), NVRM_E_RM);
	CHECK(cl == NULL && strstr(err, "empty VA space") != NULL);
	M.va_base = 0x200000;
	M.va_size = 0x200000;
	CHECK_EQ(open_cl(0, &cl, err, sizeof(err)), NVRM_E_RM);
	M.va_base = 0x100000;
	M.va_size = 1ULL << 40;
	/* each allocation of the open refused by the RM */
	M.fail_cls = NV01_DEVICE_0;
	CHECK_EQ(open_cl(0, &cl, err, sizeof(err)), NVRM_E_RM);
	CHECK(strstr(err, "NV01_DEVICE_0 allocation failed (RM status") != NULL);
	M.fail_cls = FERMI_VASPACE_A;
	CHECK_EQ(open_cl(0, &cl, err, sizeof(err)), NVRM_E_RM);
	CHECK(strstr(err, "FERMI_VASPACE_A") != NULL);
	/* the GPU's id info, and attaching it to the session */
	K.fail_ctl_cmd = NV0000_CTRL_CMD_GPU_GET_ID_INFO_V2;
	K.fail_ctl_status = NV_ERR_INVALID_ARGUMENT;
	CHECK_EQ(open_cl(0, &cl, err, sizeof(err)), NVRM_E_RM);
	CHECK(strstr(err, "GET_ID_INFO_V2") != NULL);
	K.fail_ctl_cmd = NV0000_CTRL_CMD_GPU_ATTACH_IDS;
	CHECK_EQ(open_cl(0, &cl, err, sizeof(err)), NVRM_E_RM);
	CHECK(strstr(err, "GPU_ATTACH_IDS") != NULL);
	K.fail_ctl_cmd = -1;
	M.fail_nr = NV_ESC_ATTACH_GPUS_TO_FD;
	CHECK_EQ(open_cl(0, &cl, err, sizeof(err)), NVRM_E_IO);
	CHECK(strstr(err, "NV_ESC_ATTACH_GPUS_TO_FD failed") != NULL);
	/* a failed ioctl(2) is an I/O error, not an RM status */
	M.fail_nr = NV_ESC_RM_CONTROL;
	CHECK_EQ(open_cl(0, &cl, err, sizeof(err)), NVRM_E_IO);
	CHECK(strstr(err, "the system call failed") != NULL);
	/* the session's control device cannot be opened */
	K.fail_open = 1;
	CHECK_EQ(open_cl(0, &cl, err, sizeof(err)), NVRM_E_OPEN);
	K.fail_open = 0;
	/* the spare device nodes cannot be opened */
	M.fail_map_open = 1;
	CHECK_EQ(open_cl(NVRM_OPEN_ALLOW_MAP, &cl, err, sizeof(err)), NVRM_E_OPEN);
	CHECK(strstr(err, "cannot open /dev/nvidia1") != NULL);
	M.fail_map_open = 0;
	/* the session descriptor, or a spare, cannot be limited */
	M.prelimit_session = 1;
	CHECK_EQ(open_cl(0, &cl, err, sizeof(err)), NVRM_E_CAPSICUM);
	CHECK(strstr(err, "cannot limit the descriptors") != NULL);
	M.prelimit_map = 1;
	CHECK_EQ(open_cl(NVRM_OPEN_ALLOW_MAP, &cl, err, sizeof(err)), NVRM_E_CAPSICUM);
	CHECK(strstr(err, "cannot limit /dev/nvidia1") != NULL);
	/* a GPU the OS layer gave no device node: GPU mappings only */
	nvrm_device_get(ctx, 0)->gpu->have_card = 0;
	CHECK_EQ(open_cl(NVRM_OPEN_ALLOW_MAP, &cl, err, sizeof(err)), NVRM_E_NOTSUP);
	CHECK(strstr(err, "open without NVRM_OPEN_ALLOW_MAP") != NULL);
	CHECK_EQ(open_cl(0, &cl, err, sizeof(err)), NVRM_OK);
	nvrm_client_close(cl);
	nvrm_device_get(ctx, 0)->gpu->have_card = 1;
	/* every allocation of the open in turn */
	for (n = 1; n < 30; n++) {
		fail_calloc_at(n);
		if (open_cl(NVRM_OPEN_ALLOW_MAP, &cl, err, sizeof(err)) == NVRM_OK) {
			fail_calloc_at(0);
			nvrm_client_close(cl);
			break;
		}
		fail_calloc_at(0);
		CHECK(cl == NULL);
	}
	CHECK(n > 1 && n < 30);
	down("open failures");
}

/* ---- VA and memory --------------------------------------------------------------- */

/* Bytes this thread holds on the heap now (allocated minus freed). */
static int64_t
heap_held(void)
{
	uint64_t a = 0, d = 0;
	size_t sz = sizeof(a);

	mallctl("thread.allocated", &a, &sz, NULL, 0);
	sz = sizeof(d);
	mallctl("thread.deallocated", &d, &sz, NULL, 0);
	return ((int64_t)(a - d));
}

/* Open, reserve, close; with refuse set the RM refuses the release that the
 * close makes.  Returns what the round left on the heap. */
static int64_t
close_round(int refuse)
{
	int64_t before;
	nvrm_client *cl;

	before = heap_held();
	cl = client(0);
	(void)reserve(cl, 1 * MiB, 0);
	if (refuse) {
		M.status_nr = NV_ESC_RM_FREE;
		M.status_val = NV_ERR_STATE_IN_USE;
	}
	nvrm_client_close(cl);
	M.status_nr = -1;
	return (heap_held() - before);
}

static void
test_reserve(void)
{
	nvrm_va_params p = { 0, 0, 2 * MiB, 0, 0 };
	nvrm_client *cl;
	uint64_t va;

	up();
	cl = client(0);
	va = reserve(cl, 1 * MiB, NVRM_VA_SPARSE);
	CHECK_EQ(M.nvirtual, 1);
	CHECK_EQ(M.last_alloc.offset, va);
	CHECK_EQ(M.last_alloc.size, 1 * MiB);
	CHECK((M.last_alloc.flags & NVOS32_ALLOC_FLAGS_SPARSE) != 0);
	CHECK_EQ(nvrm_va_release(cl, va), NVRM_OK);
	va = reserve(cl, 1 * MiB, 0);
	CHECK((M.last_alloc.flags & NVOS32_ALLOC_FLAGS_SPARSE) == 0);
	CHECK_EQ(nvrm_va_release(cl, va), NVRM_OK);
	/* refused, or the call fails: nothing is left behind */
	M.fail_cls = NV50_MEMORY_VIRTUAL;
	CHECK_EQ(nvrm_va_reserve(cl, &p, &va), NVRM_E_RM);
	HAS(cl, "NV50_MEMORY_VIRTUAL allocation failed");
	M.fail_nr = NV_ESC_RM_ALLOC;
	CHECK_EQ(nvrm_va_reserve(cl, &p, &va), NVRM_E_IO);
	fail_calloc_at(1);
	CHECK_EQ(nvrm_va_reserve(cl, &p, &va), NVRM_E_NOMEM);
	fail_calloc_at(2);
	CHECK_EQ(nvrm_va_reserve(cl, &p, &va), NVRM_E_NOMEM);
	fail_calloc_at(0);
	/* a release the RM refuses keeps the reservation; a retry frees it */
	va = reserve(cl, 1 * MiB, 0);
	M.status_nr = NV_ESC_RM_FREE;
	M.status_val = NV_ERR_STATE_IN_USE;
	CHECK_EQ(nvrm_va_release(cl, va), NVRM_E_RM);
	HAS(cl, "freeing the VA reservation failed (RM status");
	CHECK_EQ(failed(cl), 1);
	M.fail_nr = NV_ESC_RM_FREE;
	CHECK_EQ(nvrm_va_release(cl, va), NVRM_E_IO);
	CHECK_EQ(failed(cl), 2);
	CHECK_EQ(nvrm_va_release(cl, va), NVRM_OK);
	CHECK_EQ(not_freed_explicitly(), 0);
	nvrm_client_close(cl);
	/* the older of two reservations released first */
	cl = client(0);
	va = reserve(cl, 1 * MiB, 0);
	CHECK(reserve(cl, 1 * MiB, 0) != 0);
	CHECK_EQ(nvrm_va_release(cl, va), NVRM_OK);
	nvrm_client_close(cl);
	/* a release refused while the client closes leaves no record behind:
	 * the round leaves on the heap what a round with no refusal leaves */
	(void)close_round(0);
	CHECK_EQ(close_round(1), close_round(0));
	down("reserve");
}

static void
test_alloc(void)
{
	nvrm_client *cl;
	nvrm_mem *m;

	up();
	cl = client(0);
	/* video memory: location, write-combined, the page size asked for */
	CHECK_EQ(alloc(cl, NVRM_MEM_VRAM, 1 * MiB, 64 * KiB, &m), NVRM_OK);
	CHECK_EQ(M.nvid, 1);
	CHECK_EQ(DRF_VAL(OS32, _ATTR, _COHERENCY, M.last_alloc.attr),
	    NVOS32_ATTR_COHERENCY_WRITE_COMBINE);
	CHECK_EQ(DRF_VAL(OS32, _ATTR, _PAGE_SIZE, M.last_alloc.attr),
	    NVOS32_ATTR_PAGE_SIZE_BIG);
	CHECK_EQ(page_of(m), 64 * KiB);
	CHECK_EQ(info_of(m).place, NVRM_PLACE_VIDMEM);
	nvrm_mem_free(m);
	/* the library's own choice is asked of the RM explicitly */
	CHECK_EQ(alloc(cl, NVRM_MEM_VRAM, 1 * MiB, 0, &m), NVRM_OK);
	CHECK_EQ(DRF_VAL(OS32, _ATTR, _PAGE_SIZE, M.last_alloc.attr),
	    NVOS32_ATTR_PAGE_SIZE_BIG);
	CHECK_EQ(page_of(m), 64 * KiB);
	nvrm_mem_free(m);
	/* huge pages name their size in ATTR2 */
	CHECK_EQ(alloc(cl, NVRM_MEM_VRAM, 4 * MiB, 2 * MiB, &m), NVRM_OK);
	CHECK_EQ(DRF_VAL(OS32, _ATTR2, _PAGE_SIZE_HUGE, M.last_alloc.attr2),
	    NVOS32_ATTR2_PAGE_SIZE_HUGE_2MB);
	CHECK_EQ(page_of(m), 2 * MiB);
	nvrm_mem_free(m);
	CHECK_EQ(alloc(cl, NVRM_MEM_VRAM, 512 * MiB, 512 * MiB, &m), NVRM_OK);
	CHECK_EQ(DRF_VAL(OS32, _ATTR2, _PAGE_SIZE_HUGE, M.last_alloc.attr2),
	    NVOS32_ATTR2_PAGE_SIZE_HUGE_512MB);
	CHECK_EQ(page_of(m), 512 * MiB);
	nvrm_mem_free(m);
	nvrm_client_close(cl);
	down("alloc");
}

static void
test_alloc_page_writeback(void)
{
	nvrm_client *cl;
	nvrm_mem *m;
	int frees;

	up();
	cl = client(0);
	/* the page size the RM writes back is the one reported */
	M.wb_page = NVOS32_ATTR_PAGE_SIZE_HUGE;
	M.wb_huge = NVOS32_ATTR2_PAGE_SIZE_HUGE_2MB;
	CHECK_EQ(alloc(cl, NVRM_MEM_VRAM, 4 * MiB, 64 * KiB, &m), NVRM_OK);
	CHECK_EQ(page_of(m), 2 * MiB);
	nvrm_mem_free(m);
	/* DEFAULT is not the requested size: surface info names the real one. */
	M.wb_page = NVOS32_ATTR_PAGE_SIZE_DEFAULT;
	M.wb_huge = NOVERRIDE;
	M.surf_attr = DRF_NUM(OS32, _ATTR, _PAGE_SIZE,
	    NVOS32_ATTR_PAGE_SIZE_BIG);
	CHECK_EQ(alloc(cl, NVRM_MEM_VRAM, 64 * KiB, 4 * KiB, &m), NVRM_OK);
	CHECK_EQ(page_of(m), 64 * KiB);
	nvrm_mem_free(m);
	/* If neither answer names a size, the allocation is undone. */
	M.surf_attr = DRF_NUM(OS32, _ATTR, _PAGE_SIZE,
	    NVOS32_ATTR_PAGE_SIZE_DEFAULT);
	frees = M.nmine_free;
	CHECK_EQ(alloc(cl, NVRM_MEM_VRAM, 64 * KiB, 4 * KiB, &m),
	    NVRM_E_NOTSUP);
	HAS(cl, "requested 4 KiB page");
	HAS(cl, "the object was freed");
	HAS(cl, "this RM version cannot be used for that allocation");
	CHECK(strstr(nvrm_client_errmsg(cl), "given back") == NULL);
	CHECK(strstr(nvrm_client_errmsg(cl), "ask for an explicit") == NULL);
	CHECK(m == NULL);
	CHECK_EQ(M.nmine_free, frees + 1);
	CHECK_EQ(not_freed_explicitly(), 0);
	/* A failed surface-info control keeps its own status and message. */
	M.surf_attr = NOVERRIDE;
	M.fail_ctl = NV0041_CTRL_CMD_GET_SURFACE_INFO;
	M.status_val = NV_ERR_INVALID_OBJECT;
	frees = M.nmine_free;
	CHECK_EQ(alloc(cl, NVRM_MEM_VRAM, 64 * KiB, 4 * KiB, &m),
	    NVRM_E_RM);
	has_surface_error(cl);
	CHECK(m == NULL);
	CHECK_EQ(M.nmine_free, frees + 1);
	CHECK_EQ(not_freed_explicitly(), 0);
	M.surf_attr = NOVERRIDE;
	M.wb_page = M.wb_huge = NOVERRIDE;
	/* a page the table does not have: the object is freed */
	M.wb_page = NVOS32_ATTR_PAGE_SIZE_HUGE;
	M.wb_huge = NVOS32_ATTR2_PAGE_SIZE_HUGE_256GB;
	CHECK_EQ(alloc(cl, NVRM_MEM_VRAM, 4 * MiB, 2 * MiB, &m), NVRM_E_NOTSUP);
	HAS(cl, "page size this library does not know");
	CHECK(m == NULL);
	CHECK_EQ(not_freed_explicitly(), 0);
	M.wb_page = M.wb_huge = NOVERRIDE;
	nvrm_client_close(cl);
	down("alloc page writeback");
}

static void
test_alloc_sysmem(void)
{
	nvrm_client *cl;
	nvrm_mem *m;
	nvrm_balloc ba;
	nvrm_bmem *bm;
	nvrm_bmem_info bi;
	char err[200];
	static char pages[2 * 65536] __attribute__((aligned(65536)));

	up();
	cl = client(0);
	/* system memory: PCI, cached, 4 KiB; an alignment is forced */
	{
		nvrm_mem_params p = { 0, NVRM_MEM_SYSMEM, 0, 0, 8192, 1 * MiB, 0 };

		CHECK_EQ(nvrm_mem_alloc(cl, &p, &m), NVRM_OK);
	}
	CHECK_EQ(M.nsys, 1);
	CHECK_EQ(DRF_VAL(OS32, _ATTR, _COHERENCY, M.last_alloc.attr),
	    NVOS32_ATTR_COHERENCY_CACHED);
	CHECK((M.last_alloc.flags & NVOS32_ALLOC_FLAGS_ALIGNMENT_FORCE) != 0);
	CHECK_EQ(M.last_alloc.alignment, 1 * MiB);
	CHECK_EQ(page_of(m), 4 * KiB);
	CHECK_EQ(info_of(m).cpu_attr, NVRM_ATTR_CACHED);
	nvrm_mem_free(m);
	/* refusals */
	M.fail_cls = NV01_MEMORY_LOCAL_USER;
	CHECK_EQ(alloc(cl, NVRM_MEM_VRAM, 1 * MiB, 0, &m), NVRM_E_RM);
	HAS(cl, "video memory allocation failed");
	M.fail_cls = NV01_MEMORY_SYSTEM;
	CHECK_EQ(alloc(cl, NVRM_MEM_SYSMEM, 1 * MiB, 0, &m), NVRM_E_RM);
	HAS(cl, "system memory allocation failed");
	fail_calloc_at(1);
	CHECK_EQ(alloc(cl, NVRM_MEM_SYSMEM, 1 * MiB, 0, &m), NVRM_E_NOMEM);
	fail_calloc_at(0);
	/* a page size the RM interface cannot express (the core lets through
	 * only listed ones; the backend is asked directly) */
	ba = (nvrm_balloc){ NVRM_MEM_VRAM, NVRM_PLACE_VIDMEM, 1 * MiB, 0,
	    128 * KiB };
	CHECK_EQ(nvrm_rm_mem_ops.mem_alloc(cl->bc, &ba, &bm, &bi, err,
	    sizeof(err)), NVRM_E_NOTSUP);
	CHECK(strstr(err, "cannot be asked of the RM") != NULL);
	/* user pages */
	CHECK_EQ(nvrm_mem_register_user(cl, pages, 65536, &m), NVRM_OK);
	CHECK_EQ(M.nos, 1);
	CHECK_EQ(info_of(m).place, NVRM_PLACE_SYSMEM);
	nvrm_mem_free(m);
	M.fail_cls = NV01_MEMORY_SYSTEM_OS_DESCRIPTOR;
	CHECK_EQ(nvrm_mem_register_user(cl, pages, 65536, &m), NVRM_E_RM);
	HAS(cl, "registering user pages failed");
	fail_calloc_at(1);
	CHECK_EQ(nvrm_mem_register_user(cl, pages, 65536, &m), NVRM_E_NOMEM);
	fail_calloc_at(0);
	/* a free the RM refuses is counted */
	CHECK_EQ(alloc(cl, NVRM_MEM_SYSMEM, 4096, 0, &m), NVRM_OK);
	M.status_nr = NV_ESC_RM_FREE;
	M.status_val = NV_ERR_STATE_IN_USE;
	nvrm_mem_free(m);
	HAS(cl, "freeing the memory object failed");
	CHECK_EQ(failed(cl), 1);
	CHECK_EQ(not_freed_explicitly(), 1);	/* the refused one */
	nvrm_client_close(cl);
	down("alloc sysmem");
}

/* ---- mappings ------------------------------------------------------------------ */

static void
test_map_gpu(void)
{
	nvrm_client *cl;
	nvrm_mem *v, *s;
	uint64_t va;

	up();
	cl = client(0);
	va = reserve(cl, 16 * MiB, 0);
	CHECK_EQ(alloc(cl, NVRM_MEM_VRAM, 1 * MiB, 64 * KiB, &v), NVRM_OK);
	CHECK_EQ(alloc(cl, NVRM_MEM_SYSMEM, 1 * MiB, 0, &s), NVRM_OK);
	/* fixed address, read-write, no snoop for video memory */
	CHECK_EQ(map_gpu(v, va, 0), NVRM_OK);
	CHECK_EQ(M.last46.dmaOffset, va);
	CHECK_EQ(M.last46.length, 1 * MiB);
	CHECK_EQ(DRF_VAL(OS46, _FLAGS, _ACCESS, M.last46.flags),
	    NVOS46_FLAGS_ACCESS_READ_WRITE);
	CHECK_EQ(DRF_VAL(OS46, _FLAGS, _CACHE_SNOOP, M.last46.flags),
	    NVOS46_FLAGS_CACHE_SNOOP_DISABLE);
	/* read-only, snooped for system memory */
	CHECK_EQ(map_gpu(s, va + 2 * MiB, NVRM_MAP_READ_ONLY), NVRM_OK);
	CHECK_EQ(DRF_VAL(OS46, _FLAGS, _ACCESS, M.last46.flags),
	    NVOS46_FLAGS_ACCESS_READ_ONLY);
	CHECK_EQ(DRF_VAL(OS46, _FLAGS, _CACHE_SNOOP, M.last46.flags),
	    NVOS46_FLAGS_CACHE_SNOOP_ENABLE);
	/* refused by the RM, or the call fails */
	M.status_nr = NV_ESC_RM_MAP_MEMORY_DMA;
	M.status_val = NV_ERR_INVALID_OFFSET;
	CHECK_EQ(map_gpu(s, va + 4 * MiB, 0), NVRM_E_RM);
	HAS(cl, "NV_ESC_RM_MAP_MEMORY_DMA failed (RM status");
	M.fail_nr = NV_ESC_RM_MAP_MEMORY_DMA;
	CHECK_EQ(map_gpu(s, va + 4 * MiB, 0), NVRM_E_IO);
	/* an unmap the RM refuses, or whose call fails: the mapping stays */
	M.status_nr = NV_ESC_RM_UNMAP_MEMORY_DMA;
	M.status_val = NV_ERR_INVALID_OBJECT;
	CHECK_EQ(nvrm_mem_unmap_gpu(v, va), NVRM_E_RM);
	HAS(cl, "NV_ESC_RM_UNMAP_MEMORY_DMA failed (RM status");
	M.fail_nr = NV_ESC_RM_UNMAP_MEMORY_DMA;
	CHECK_EQ(nvrm_mem_unmap_gpu(v, va), NVRM_E_IO);
	CHECK_EQ(failed(cl), 2);
	CHECK_EQ(nvrm_mem_unmap_gpu(v, va), NVRM_OK);
	CHECK_EQ(M.nunmapdma, 2);	/* the refused one and this one */
	nvrm_mem_free(v);
	nvrm_mem_free(s);	/* takes its mapping with it */
	CHECK_EQ(M.nunmapdma, 3);
	CHECK_EQ(nvrm_va_release(cl, va), NVRM_OK);
	CHECK_EQ(not_freed_explicitly(), 0);
	nvrm_client_close(cl);
	down("map gpu");
}

static void
test_map_cpu(void)
{
	nvrm_client *cl;
	nvrm_mem *m;
	void *p;
	uint32_t v = 0x12345678, back = 0;

	up();
	cl = client(NVRM_OPEN_ALLOW_MAP);
	CHECK_EQ(alloc(cl, NVRM_MEM_SYSMEM, 64 * KiB, 0, &m), NVRM_OK);
	CHECK_EQ(nvrm_mem_map_cpu(m, NVRM_CPU_READ | NVRM_CPU_WRITE, &p), NVRM_OK);
	CHECK_EQ(M.nmapmem, 1);
	CHECK_EQ(nvrm_mem_write(m, 128, &v, sizeof(v)), NVRM_OK);
	CHECK_EQ(nvrm_mem_read(m, 128, &back, sizeof(back)), NVRM_OK);
	CHECK_EQ(back, v);
	CHECK_EQ(nvrm_mem_unmap_cpu(m), NVRM_OK);
	CHECK_EQ(M.nunmapmem, 1);
	/* read-only, and write-only */
	CHECK_EQ(nvrm_mem_map_cpu(m, NVRM_CPU_READ, &p), NVRM_OK);
	CHECK_EQ(nvrm_mem_unmap_cpu(m), NVRM_OK);
	CHECK_EQ(nvrm_mem_map_cpu(m, NVRM_CPU_WRITE, &p), NVRM_OK);
	CHECK_EQ(nvrm_mem_write(m, 0, &v, sizeof(v)), NVRM_OK);
	CHECK_EQ(nvrm_mem_read(m, 0, &back, sizeof(back)), NVRM_E_DENIED);
	CHECK_EQ(nvrm_mem_unmap_cpu(m), NVRM_OK);
	/* the RM refuses the mapping, or the call fails */
	M.status_nr = NV_ESC_RM_MAP_MEMORY;
	M.status_val = NV_ERR_INVALID_ARGUMENT;
	CHECK_EQ(nvrm_mem_map_cpu(m, NVRM_CPU_READ, &p), NVRM_E_RM);
	HAS(cl, "NV_ESC_RM_MAP_MEMORY failed (RM status");
	M.fail_nr = NV_ESC_RM_MAP_MEMORY;
	CHECK_EQ(nvrm_mem_map_cpu(m, NVRM_CPU_READ, &p), NVRM_E_IO);
	/* the RM side mapped but the mmap(2) fails: the RM side is undone,
	 * and the mmap error is the one reported */
	M.map_dev_null = 1;
	nvrm_client_close(cl);
	cl = client(NVRM_OPEN_ALLOW_MAP);
	CHECK_EQ(alloc(cl, NVRM_MEM_SYSMEM, 64 * KiB, 0, &m), NVRM_OK);
	M.nunmapmem = 0;
	CHECK_EQ(nvrm_mem_map_cpu(m, NVRM_CPU_READ | NVRM_CPU_WRITE, &p), NVRM_E_IO);
	HAS(cl, "mmap of the device failed");
	CHECK_EQ(M.nunmapmem, 1);
	M.status_nr = NV_ESC_RM_UNMAP_MEMORY;	/* the undo refused too */
	M.status_val = NV_ERR_INVALID_OBJECT;
	CHECK_EQ(nvrm_mem_map_cpu(m, NVRM_CPU_READ | NVRM_CPU_WRITE, &p), NVRM_E_IO);
	HAS(cl, "mmap of the device failed");
	M.map_dev_null = 0;
	nvrm_client_close(cl);
	/* an unmap the RM refuses, or whose call fails */
	cl = client(NVRM_OPEN_ALLOW_MAP);
	CHECK_EQ(alloc(cl, NVRM_MEM_SYSMEM, 64 * KiB, 0, &m), NVRM_OK);
	CHECK_EQ(nvrm_mem_map_cpu(m, NVRM_CPU_READ, &p), NVRM_OK);
	M.status_nr = NV_ESC_RM_UNMAP_MEMORY;
	M.status_val = NV_ERR_INVALID_OBJECT;
	CHECK_EQ(nvrm_mem_unmap_cpu(m), NVRM_E_RM);
	HAS(cl, "NV_ESC_RM_UNMAP_MEMORY failed (RM status");
	CHECK_EQ(nvrm_mem_map_cpu(m, NVRM_CPU_READ, &p), NVRM_OK);
	M.fail_nr = NV_ESC_RM_UNMAP_MEMORY;
	CHECK_EQ(nvrm_mem_unmap_cpu(m), NVRM_E_IO);
	CHECK_EQ(failed(cl), 2);
	nvrm_mem_free(m);
	CHECK_EQ(not_freed_explicitly(), 0);
	nvrm_client_close(cl);
	down("map cpu");
}

/* ---- sharing ------------------------------------------------------------------- */

static int
import_with(nvrm_client *b, int fd, NvU32 attr, NvU32 space, uint64_t size,
    nvrm_mem **im)
{
	M.surf_attr = attr;
	M.surf_space = space;
	M.surf_size = size;
	*im = NULL;
	return (nvrm_mem_import_fd(b, fd, im));
}

#define ATTR(page, coh)	(DRF_NUM(OS32, _ATTR, _PAGE_SIZE, (page)) | \
			 DRF_NUM(OS32, _ATTR, _COHERENCY, (coh)))
#define VID	NV0000_CTRL_CMD_CLIENT_GET_ADDR_SPACE_TYPE_VIDMEM
#define SYSM	NV0000_CTRL_CMD_CLIENT_GET_ADDR_SPACE_TYPE_SYSMEM

/* #lizard forgives -- one scripted scenario, steps share state; split tracked as DEBT on #2419 */
static void
test_share(void)
{
	nvrm_client *a, *b;
	nvrm_mem *m, *im;
	nvrm_mem_info mi;
	int fd;

	up();
	a = client(0);
	b = client(NVRM_OPEN_ALLOW_MAP);
	CHECK_EQ(alloc(a, NVRM_MEM_VRAM, 1 * MiB, 64 * KiB, &m), NVRM_OK);
	CHECK_EQ(nvrm_mem_export_fd(m, &fd), NVRM_OK);
	CHECK_EQ(M.nexport, 1);
	/* as the RM reports it: size, page size, place */
	CHECK_EQ(nvrm_mem_import_fd(b, fd, &im), NVRM_OK);
	CHECK_EQ(M.nimport, 1);
	CHECK_EQ(M.nsurf, 1);
	mi = info_of(im);
	CHECK_EQ(mi.kind, NVRM_MEM_IMPORTED);
	CHECK_EQ(mi.bytes, 1 * MiB);
	CHECK_EQ(mi.page_size, 64 * KiB);
	CHECK_EQ(mi.place, NVRM_PLACE_VIDMEM);
	nvrm_mem_free(im);
	/* page sizes: 4 KiB; huge is 2 MiB unless the size allows 512 MiB */
	CHECK_EQ(import_with(b, fd, ATTR(NVOS32_ATTR_PAGE_SIZE_4KB, 1), VID, 0, &im), NVRM_OK);
	CHECK_EQ(info_of(im).page_size, 4 * KiB);
	nvrm_mem_free(im);
	CHECK_EQ(import_with(b, fd, ATTR(NVOS32_ATTR_PAGE_SIZE_HUGE, 1), VID, 6 * MiB, &im), NVRM_OK);
	CHECK_EQ(info_of(im).page_size, 2 * MiB);
	nvrm_mem_free(im);
	/* a size 512 MiB pages would fit: still 2 MiB, the page every huge
	 * object has; the RM refuses a map a real 512 MiB page would not take */
	CHECK_EQ(import_with(b, fd, ATTR(NVOS32_ATTR_PAGE_SIZE_HUGE, 1), VID, 1024 * MiB, &im), NVRM_OK);
	CHECK_EQ(info_of(im).page_size, 2 * MiB);
	nvrm_mem_free(im);
	/* no page size named: refused, and the imported handle freed */
	CHECK_EQ(import_with(b, fd, ATTR(NVOS32_ATTR_PAGE_SIZE_DEFAULT, 1), VID, 0, &im), NVRM_E_NOTSUP);
	HAS(b, "does not say its page size");
	CHECK(im == NULL);
	/* system memory: the CPU attribute follows the coherency the RM keeps */
	CHECK_EQ(import_with(b, fd, ATTR(NVOS32_ATTR_PAGE_SIZE_4KB, NVOS32_ATTR_COHERENCY_CACHED), SYSM, 0, &im), NVRM_OK);
	CHECK_EQ(info_of(im).place, NVRM_PLACE_SYSMEM);
	CHECK_EQ(info_of(im).cpu_attr, NVRM_ATTR_CACHED);
	nvrm_mem_free(im);
	CHECK_EQ(import_with(b, fd, ATTR(NVOS32_ATTR_PAGE_SIZE_4KB, NVOS32_ATTR_COHERENCY_WRITE_BACK), SYSM, 0, &im), NVRM_OK);
	CHECK_EQ(info_of(im).cpu_attr, NVRM_ATTR_CACHED);
	nvrm_mem_free(im);
	CHECK_EQ(import_with(b, fd, ATTR(NVOS32_ATTR_PAGE_SIZE_4KB, NVOS32_ATTR_COHERENCY_WRITE_COMBINE), SYSM, 0, &im), NVRM_OK);
	CHECK_EQ(info_of(im).cpu_attr, NVRM_ATTR_WC);
	nvrm_mem_free(im);
	CHECK_EQ(import_with(b, fd, ATTR(NVOS32_ATTR_PAGE_SIZE_4KB, NVOS32_ATTR_COHERENCY_UNCACHED), SYSM, 0, &im), NVRM_OK);
	CHECK_EQ(info_of(im).cpu_attr, NVRM_ATTR_DEVICE);
	nvrm_mem_free(im);
	CHECK_EQ(import_with(b, fd, ATTR(NVOS32_ATTR_PAGE_SIZE_4KB, NVOS32_ATTR_COHERENCY_WRITE_THROUGH), SYSM, 0, &im), NVRM_OK);
	CHECK_EQ(info_of(im).cpu_attr, NVRM_ATTR_DEVICE);
	nvrm_mem_free(im);
	/* neither video nor system memory */
	CHECK_EQ(import_with(b, fd, ATTR(NVOS32_ATTR_PAGE_SIZE_4KB, 1),
	    NV0000_CTRL_CMD_CLIENT_GET_ADDR_SPACE_TYPE_FABRIC, 0, &im), NVRM_E_RM);
	HAS(b, "neither video nor system memory");
	M.surf_attr = M.surf_space = NOVERRIDE;
	M.surf_size = 0;
	/* the surface info refused: the import is undone */
	M.fail_ctl = NV0041_CTRL_CMD_GET_SURFACE_INFO;
	M.status_val = NV_ERR_INVALID_OBJECT;
	CHECK_EQ(nvrm_mem_import_fd(b, fd, &im), NVRM_E_RM);
	has_surface_error(b);
	/* the import refused, and allocation failures */
	M.fail_ctl = NV0000_CTRL_CMD_OS_UNIX_IMPORT_OBJECT_FROM_FD;
	CHECK_EQ(nvrm_mem_import_fd(b, fd, &im), NVRM_E_RM);
	HAS(b, "IMPORT_OBJECT_FROM_FD failed");
	fail_calloc_at(1);
	CHECK_EQ(nvrm_mem_import_fd(b, fd, &im), NVRM_E_NOMEM);
	fail_calloc_at(0);
	close(fd);
	/* the export refused */
	M.fail_ctl = NV0000_CTRL_CMD_OS_UNIX_EXPORT_OBJECT_TO_FD;
	CHECK_EQ(nvrm_mem_export_fd(m, &fd), NVRM_E_RM);
	HAS(a, "EXPORT_OBJECT_TO_FD failed");
	nvrm_mem_free(m);
	CHECK_EQ(not_freed_explicitly(), 0);
	nvrm_client_close(a);
	nvrm_client_close(b);
	down("share");
}

/* ---- fork ---------------------------------------------------------------------- */

static pid_t
other_pid(void)
{
	return (getpid() + 1);
}

/* A forked child shares the descriptor, and with it the RM client: every
 * call that would act on it is refused; releases stay local to the child. */
static void
test_fork_child(void)
{
	nvrm_client *cl, *cl2;
	NVOS00_PARAMETERS parent_free;
	nvrm_mem *m, *m2, *x;
	nvrm_va_params vp = { 0, 0, 1 * MiB, 0, 0 };
	nvrm_mem_params mp = { 0, NVRM_MEM_SYSMEM, 0, 0, 4096, 0, 0 };
	nvrm_gpu_map_params gp;
	static char pages[65536] __attribute__((aligned(65536)));
	uint64_t va, va2;
	int fd, frees, opens, parent_fd, munmaps;
	void *p;

	up();
	cl = client(NVRM_OPEN_ALLOW_MAP);
	va = reserve(cl, 2 * MiB, 0);
	CHECK_EQ(alloc(cl, NVRM_MEM_SYSMEM, 64 * KiB, 0, &m), NVRM_OK);
	CHECK_EQ(map_gpu(m, va, 0), NVRM_OK);
	CHECK_EQ(nvrm_mem_map_cpu(m, NVRM_CPU_READ, &p), NVRM_OK);
	/* Leave a second client's memory and reservation for the close loops. */
	cl2 = client(0);
	parent_fd = M.session_fd;
	(void)reserve(cl2, 2 * MiB, 0);
	CHECK_EQ(alloc(cl2, NVRM_MEM_SYSMEM, 64 * KiB, 0, &m2), NVRM_OK);
	frees = M.nmine_free;
	opens = M.open_calls;
	nvrm_getpid_hook = other_pid;
	CHECK_EQ(nvrm_va_reserve(cl, &vp, &va2), NVRM_E_DENIED);
	HAS(cl, "fork() child");
	CHECK_EQ(nvrm_mem_alloc(cl, &mp, &x), NVRM_E_DENIED);
	CHECK_EQ(nvrm_mem_register_user(cl, pages, 65536, &x), NVRM_E_DENIED);
	gp = (nvrm_gpu_map_params){ 0, 0, va + 1 * MiB, 0, 0 };
	CHECK_EQ(nvrm_mem_map_gpu(m, &gp), NVRM_E_DENIED);
	CHECK_EQ(nvrm_mem_export_fd(m, &fd), NVRM_E_DENIED);
	CHECK_EQ(nvrm_mem_import_fd(cl, 0, &x), NVRM_E_DENIED);
	munmaps = M.nmunmap;
	CHECK_EQ(nvrm_mem_unmap_cpu(m), NVRM_OK);
	CHECK_EQ(M.nmunmap, munmaps + 1); /* the child's own mapping is removed */
	CHECK_EQ(M.nunmapmem, 0);	/* but the parent's RM mapping is not */
	CHECK_EQ(nvrm_mem_map_cpu(m, NVRM_CPU_READ, &p), NVRM_E_DENIED);
	CHECK_EQ(nvrm_mem_unmap_gpu(m, va), NVRM_OK);
	nvrm_mem_free(m);
	CHECK_EQ(nvrm_va_release(cl, va), NVRM_OK);
	CHECK_EQ(failed(cl), 0);
	CHECK_EQ(M.nmine_free, frees);	/* the child freed nothing */
	CHECK_EQ(M.nunmapdma, 0);
	CHECK_EQ(M.nunmapmem, 0);
	/* The core refuses every create/act call before desc_open: the child
	 * makes no descriptor open, whether from a spare or directly. */
	CHECK_EQ(M.open_calls, opens);
	/* Closing another child client releases its records without an RM free. */
	nvrm_client_close(cl2);
	CHECK_EQ(M.nmine_free, frees);
	CHECK_EQ(M.nunmapdma, 0);
	CHECK_EQ(M.nunmapmem, 0);
	/* This in-process simulation must also close the second RM session as
	 * its parent; a real fork parent still has its own client core. */
	nvrm_getpid_hook = NULL;
	/* The second session's client must still be there: the child close
	 * freed none of it, so the hand free below frees it and not nothing. */
	CHECK(live_in_session(parent_fd) > 0);
	memset(&parent_free, 0, sizeof(parent_free));
	parent_free.hObjectOld = CLIENT;
	CHECK_EQ(m_ioctl(parent_fd, IOC_RM_FREE, &parent_free), 0);
	CHECK_EQ(live_in_session(parent_fd), 0);
	nvrm_client_close(cl);
	down("fork child");
}

/* The page kind, the compression, the handle of the object, a CPU
 * mapping at a fixed address and the overmap of a client mapping. */
static void
test_extended_mem(void)
{
	nvrm_client *cl;
	nvrm_mem *m;
	nvrm_mem_params p = { 0, NVRM_MEM_SYSMEM, 0, 0, 64 * 1024, 0, 0 };
	nvrm_cpu_map_params mp = { sizeof(mp) };
	void *area, *a;

	up();
	cl = client(NVRM_OPEN_ALLOW_MAP);

	/* the page kind of the object reaches the RM */
	{
		static const struct {
			uint32_t	pte_kind;
			uint32_t	format;
		} kinds[] = {
			{ NVRM_PTE_KIND_DEFAULT, NVOS32_ATTR_FORMAT_PITCH },
			{ NVRM_PTE_KIND_PITCH, NVOS32_ATTR_FORMAT_PITCH },
			{ NVRM_PTE_KIND_BLOCK_LINEAR,
			    NVOS32_ATTR_FORMAT_BLOCK_LINEAR },
			{ NVRM_PTE_KIND_SWIZZLED, NVOS32_ATTR_FORMAT_SWIZZLED },
		};
		unsigned i;

		for (i = 0; i < sizeof(kinds) / sizeof(kinds[0]); i++) {
			p.pte_kind = kinds[i].pte_kind;
			CHECK_EQ(nvrm_mem_alloc(cl, &p, &m), NVRM_OK);
			CHECK_EQ(DRF_VAL(OS32, _ATTR, _FORMAT, M.last_alloc.attr),
			    kinds[i].format);
			nvrm_mem_free(m);
		}
	}

	/* the compression of the object reaches the RM */
	p.pte_kind = NVRM_PTE_KIND_DEFAULT;
	{
		static const struct {
			uint32_t	compress;
			uint32_t	compr;
		} compressions[] = {
			{ NVRM_COMPRESS_NONE, NVOS32_ATTR_COMPR_NONE },
			{ NVRM_COMPRESS_REQUIRED, NVOS32_ATTR_COMPR_REQUIRED },
			{ NVRM_COMPRESS_ANY, NVOS32_ATTR_COMPR_ANY },
		};
		unsigned i, n = sizeof(compressions) / sizeof(compressions[0]);

		for (i = 0; i < n; i++) {
			p.compress = compressions[i].compress;
			CHECK_EQ(nvrm_mem_alloc(cl, &p, &m), NVRM_OK);
			CHECK_EQ(DRF_VAL(OS32, _ATTR, _COMPR, M.last_alloc.attr),
			    compressions[i].compr);
			/* the last object stays: the handle of it is checked below */
			if (i + 1 < n)
				nvrm_mem_free(m);
		}
	}
	/* the handle of the object is the one the RM gave it */
	CHECK(info_of(m).handle != 0);
	CHECK_EQ(info_of(m).pte_kind, NVRM_PTE_KIND_DEFAULT);
	CHECK_EQ(info_of(m).compress, NVRM_COMPRESS_ANY);
	nvrm_mem_free(m);

	/* a CPU mapping at a fixed address */
	area = mmap(NULL, 64 * 1024, PROT_READ | PROT_WRITE,
	    MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	CHECK(area != MAP_FAILED);
	munmap(area, 64 * 1024);
	mp.prot = NVRM_CPU_READ | NVRM_CPU_WRITE;
	mp.fixed = (uint64_t)(uintptr_t)area;
	CHECK_EQ(nvrm_mem_alloc(cl, &p, &m), NVRM_OK);
	CHECK_EQ(nvrm_mem_map_cpu_at(m, &mp, &a), NVRM_OK);
	CHECK_EQ((uint64_t)(uintptr_t)a, mp.fixed);
	CHECK_EQ(M.nmapmem, 1);

	/* the overmap: the range stays mapped and the RM forgets the mapping */
	CHECK_EQ(nvrm_mem_overmap_cpu(m, mp.fixed, 0), NVRM_OK);
	CHECK_EQ(M.nunmapmem, 1);
	memset(a, 0x5a, 16);
	CHECK_EQ(((unsigned char *)a)[0], 0x5a);
	/* the call to the driver fails */
	area = mmap(NULL, 64 * 1024, PROT_READ | PROT_WRITE,
	    MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	CHECK(area != MAP_FAILED);
	munmap(area, 64 * 1024);
	mp.fixed = (uint64_t)(uintptr_t)area;
	CHECK_EQ(nvrm_mem_alloc(cl, &p, &m), NVRM_OK);
	CHECK_EQ(nvrm_mem_map_cpu_at(m, &mp, &a), NVRM_OK);
	M.fail_nr = NV_ESC_RM_UNMAP_MEMORY;
	CHECK_EQ(nvrm_mem_overmap_cpu(m, mp.fixed, 0), NVRM_E_IO);
	M.fail_nr = 0;
	/* the anonymous mapping cannot be made */
	{
		char err[160];

		CHECK_EQ(cl->mops->overmap_cpu(m->b, (void *)0x1001, 4096, 0,
		    err, sizeof(err)), NVRM_E_IO);
	}
	CHECK_EQ(nvrm_mem_unmap_cpu_at(m, mp.fixed), NVRM_OK);
	nvrm_mem_free(m);

	/* the RM refuses the unmap of the overmap: the range stays as it is */
	area = mmap(NULL, 64 * 1024, PROT_READ | PROT_WRITE,
	    MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	CHECK(area != MAP_FAILED);
	munmap(area, 64 * 1024);
	mp.fixed = (uint64_t)(uintptr_t)area;
	CHECK_EQ(nvrm_mem_alloc(cl, &p, &m), NVRM_OK);
	CHECK_EQ(nvrm_mem_map_cpu_at(m, &mp, &a), NVRM_OK);
	M.status_nr = NV_ESC_RM_UNMAP_MEMORY;
	M.status_val = NV_ERR_INVALID_OBJECT;
	CHECK_EQ(nvrm_mem_overmap_cpu(m, mp.fixed, 0), NVRM_E_RM);
	M.status_nr = 0;
	/* the mapping is still there: the caller unmaps it */
	CHECK_EQ(nvrm_mem_unmap_cpu_at(m, mp.fixed), NVRM_OK);
	nvrm_mem_free(m);

	nvrm_client_close(cl);
	down("extended mem");
}

int
main(void)
{
	setvbuf(stdout, NULL, _IOLBF, 0);
	nvrm_rm_set_sys(&mem_sys);
	test_open();
	test_open_failures();
	test_reserve();
	test_alloc();
	test_alloc_page_writeback();
	test_alloc_sysmem();
	test_map_gpu();
	test_map_cpu();
	test_extended_mem();
	test_share();
	test_fork_child();
	return (t_done("rm_mem_test"));
}

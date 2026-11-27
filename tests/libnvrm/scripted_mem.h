/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * scripted_mem.h - the memory model of the scripted kernel: several RM
 * sessions (one per descriptor, as the RM has them), the VA space, virtual
 * and physical memory objects, GPU and CPU mappings and export and import by
 * descriptor, built from NVIDIA's own structures and checking every
 * request.  The discovery escapes are the ones of scripted_rm.h.
 *
 * The model is shared: the RM memory test drives it, and the libcuda test
 * stands the same kernel in front of libnvrm so that the native provider of
 * libcuda is tested against the resource manager and not against hardware.
 * Include it once, after the NVIDIA and libnvrm headers and after
 * scripted_rm.h.
 */
#ifndef _SCRIPTED_MEM_H_
#define _SCRIPTED_MEM_H_

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

#endif /* _SCRIPTED_MEM_H_ */

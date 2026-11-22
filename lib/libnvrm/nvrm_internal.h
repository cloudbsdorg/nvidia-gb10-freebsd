/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * nvrm_internal.h - the backend provider table and the library's internals.
 */
#ifndef _NVRM_INTERNAL_H_
#define _NVRM_INTERNAL_H_

#include <sys/types.h>

#include <nvrm/nvrm.h>

/*
 * Properties a backend can report.  A backend returns 0 and sets *out, or a
 * nonzero enum nvrm_reason.  Properties are RM-shaped but backend-neutral:
 * the core decides how to combine them.
 */
enum nvrm_prop {
	NVRM_P_PCI_DOMAIN,
	NVRM_P_PCI_BUS,
	NVRM_P_PCI_SLOT,
	NVRM_P_PCI_FUNCTION,
	NVRM_P_PCI_VENDOR,
	NVRM_P_PCI_DEVICE,
	NVRM_P_PCI_SUBSYSTEM_VENDOR,
	NVRM_P_PCI_SUBSYSTEM_DEVICE,
	NVRM_P_PCI_REVISION,
	NVRM_P_RM_GPU_ID,
	NVRM_P_ARCHITECTURE,
	NVRM_P_IMPLEMENTATION,
	NVRM_P_SM_VERSION,		/* raw RM encoding: major << 8 | minor */
	NVRM_P_SM_PER_TPC,
	NVRM_P_GPC_MASK,
	NVRM_P_TPC_MASK,		/* arg: GPC index */
	NVRM_P_VRAM_KB,
	NVRM_P_BAR1_KB,
	NVRM_P_MAX_PAGE_SIZE,
	NVRM_P_NUMA_NODE,		/* -1 reported as NVRM_R_NO_NUMA */
	NVRM_P_CAP_DMABUF,		/* capability flags: value 0 or 1 */
	NVRM_P_CAP_ATS,
	NVRM_P_CAP_SELF_HOSTED,
	NVRM_P_CAP_DISPLAY,
	NVRM_P_CAP_SOC,
	NVRM_P_CAP_COHERENT_MEMORY,
	NVRM_P_CAP_OS_DEVICE_WC,
	NVRM_P_COUNT
};

enum nvrm_sprop {
	NVRM_SP_UUID,
	NVRM_SP_COUNT
};

/* The order of the properties is part of the code: the capability flags are
 * the last NVRM_NCAPS properties, in the order of nvrm_cap_name(), and
 * rm_gpu_u64() dispatches on ranges (pci, gpu, memory, capabilities). */
_Static_assert(NVRM_P_CAP_OS_DEVICE_WC - NVRM_P_CAP_DMABUF + 1 == NVRM_NCAPS,
    "NVRM_NCAPS must equal the number of capability properties");
_Static_assert(NVRM_P_CAP_OS_DEVICE_WC + 1 == NVRM_P_COUNT,
    "the capability properties must come last");

typedef struct nvrm_backend nvrm_backend;	/* backend private */
typedef struct nvrm_gpu nvrm_gpu;		/* one GPU, backend private */

typedef struct nvrm_backend_ops {
	const char *name;
	int	score;			/* higher wins among usable backends */
	/* 1 when this backend can run on this host. */
	int	(*probe)(void);
	/* Open, check the version, attach.  Returns enum nvrm_error. */
	int	(*open)(nvrm_backend **be, char *err, size_t errlen);
	void	(*close)(nvrm_backend *be);
	/* The running kernel module's version, as it reports it. */
	void	(*running_version)(nvrm_backend *be, nvrm_str *out);
	/* Probed GPU ids, attached.  Returns enum nvrm_error. */
	int	(*list_gpus)(nvrm_backend *be, uint32_t *ids, unsigned max,
		    unsigned *n, char *err, size_t errlen);
	int	(*gpu_open)(nvrm_backend *be, uint32_t id, nvrm_gpu **gpu,
		    char *err, size_t errlen);
	void	(*gpu_close)(nvrm_gpu *gpu);
	int	(*gpu_u64)(nvrm_gpu *gpu, enum nvrm_prop p, uint32_t arg,
		    uint64_t *out);
	int	(*gpu_str)(nvrm_gpu *gpu, enum nvrm_sprop p, char *buf,
		    size_t len);
	/* Class ids the GPU supports; returns 0 or an enum nvrm_reason. */
	int	(*gpu_classes)(nvrm_gpu *gpu, uint32_t *list, unsigned max,
		    unsigned *n);
	/* Limit the descriptors for Capsicum.  Returns enum nvrm_error. */
	int	(*limit)(nvrm_backend *be, int allow_alloc);
	/* Memory and VA (S2); NULL when the backend has none. */
	const struct nvrm_mem_ops *mem;
} nvrm_backend_ops;

/* Registry. */
int	nvrm_backend_register(const nvrm_backend_ops *ops);
const nvrm_backend_ops *nvrm_backend_select(const char *name);
void	nvrm_registry_reset(void);	/* tests: drop every provider */
void	nvrm_registry_builtin(void);	/* the two built-in providers */
unsigned nvrm_registry_count(void);	/* tests: providers registered */
/* Fake backend: what its memory model needs from a GPU of its own. */
uint64_t nvrm_fake_gpu_vram_kb(const nvrm_gpu *g);
uint32_t nvrm_fake_gpu_id(const nvrm_gpu *g);
/* Test seam: runs between the two built-in registrations. */
extern void (*nvrm_registry_pause_hook)(void);
extern const nvrm_backend_ops nvrm_backend_rm_ops;
extern const nvrm_backend_ops nvrm_backend_fake_ops;
/* The process and fork generation that own backend objects. */
typedef struct nvrm_owner {
	pid_t		pid;
	unsigned long	generation;
} nvrm_owner;
void	nvrm_owner_set(nvrm_owner *o);
int	nvrm_owner_is_me(const nvrm_owner *o);
/* Test seam: stands in for getpid(); NULL = the real one. */
extern pid_t (*nvrm_getpid_hook)(void);
/* Test seam: runs the pthread_atfork(3) child handler. */
void	nvrm_owner_fork_seam(void);
/* Test seam: stands in for issetugid(); NULL = the real one. */
extern int (*nvrm_issetugid_hook)(void);

/* Generation table (nvrm_table.c). */
typedef struct nvrm_family {
	const char	*name;
	uint32_t	cls_gpfifo, cls_compute, cls_eng3d, cls_copy;
	uint64_t	page_sizes[NVRM_MAX_PAGE_SIZES];	/* 0 ends */
} nvrm_family;
extern const nvrm_family nvrm_family_table[];
extern const unsigned nvrm_family_count;

/* Board decorators: add or override options, never decide support. */
typedef struct nvrm_decorator {
	const char	*name;
	uint16_t	subsystem_vendor, subsystem_device;
	struct { int index; int value; } caps[NVRM_NCAPS];	/* index -1 ends */
} nvrm_decorator;
extern const nvrm_decorator nvrm_decorator_table[];

/* Core steps, split so the tests drive each one (nvrm.c). */
void	nvrm_info_init(nvrm_device_info *info);
const nvrm_family *nvrm_family_match(const nvrm_family *table, unsigned n,
	    const uint64_t *classes, uint32_t nclasses);
void	nvrm_apply_family(nvrm_device_info *info, const nvrm_family *table,
	    unsigned n);
void	nvrm_apply_decorators(nvrm_device_info *info,
	    const nvrm_decorator *table);
void	nvrm_query_device(const nvrm_backend_ops *ops, nvrm_gpu *g,
	    nvrm_device_info *info);

struct nvrm_device {
	nvrm_ctx	*ctx;
	unsigned	index;
	nvrm_gpu	*gpu;
	nvrm_device_info info;
};

struct nvrm_ctx {
	const nvrm_backend_ops *ops;
	nvrm_backend	*be;
	unsigned	ndev;
	nvrm_str	running;
	nvrm_device	dev[NVRM_MAX_GPUS];
};


/* ---- memory and VA (nvrm_mem.c, nvrm_va.c) ------------------------------ */

typedef struct nvrm_bclient nvrm_bclient;	/* backend: one client on one GPU */
typedef struct nvrm_bmem nvrm_bmem;		/* backend: one memory object */
typedef struct nvrm_bres nvrm_bres;		/* backend: one VA reservation */

/* The kinds of spare descriptor a client pre-opens. */
enum { NVRM_DESC_MAP = 1, NVRM_DESC_EXPORT, NVRM_DESC__COUNT };

typedef struct nvrm_open_cfg {
	int		allow_map;
	unsigned	map_slots, export_slots;
} nvrm_open_cfg;

typedef struct nvrm_vainfo {
	uint64_t	base, end;
} nvrm_vainfo;

/* What the core asks for; the core has chosen the place already. */
typedef struct nvrm_balloc {
	int		kind;		/* NVRM_MEM_VRAM or NVRM_MEM_SYSMEM */
	int		place;		/* enum nvrm_place */
	uint64_t	bytes, alignment, page_size;
} nvrm_balloc;

/* How the CPU side of system memory is mapped, as the backend learned it
 * (the allocation asked for it, or the RM reports it for an import). */
enum { NVRM_COH_CACHED = 0, NVRM_COH_WC, NVRM_COH_UNCACHED };

/* What the backend reports back about an object. */
typedef struct nvrm_bmem_info {
	uint64_t	bytes, page_size;
	int		place;
	int		coherency;	/* NVRM_COH_*; system memory only */
} nvrm_bmem_info;

/*
 * Every call that can fail returns an enum nvrm_error and, with a message of
 * its own, says why in err.  The core owns the bookkeeping (VA allocator,
 * lists, argument rules); a backend only talks to the GPU.  A release (unmap,
 * free) that the GPU side refuses returns an error too, so the core can keep
 * what is still held out of reuse.  A release gets owner == 0 in a fork
 * child: the backend releases its own records and does process-local work,
 * but does not act on the parent's RM client or fake GPU.
 */
typedef struct nvrm_mem_ops {
	int	(*client_open)(nvrm_backend *be, nvrm_gpu *g,
		    const nvrm_open_cfg *cfg, nvrm_bclient **bc,
		    nvrm_vainfo *va, char *err, size_t errlen);
	void	(*client_close)(nvrm_bclient *bc);
	int	(*desc_open)(nvrm_bclient *bc, int kind, int *fd, char *err,
		    size_t errlen);
	int	(*va_reserve)(nvrm_bclient *bc, uint64_t va, uint64_t bytes,
		    int sparse, nvrm_bres **r, char *err, size_t errlen);
	int	(*va_release)(nvrm_bres *r, int owner, char *err, size_t errlen);
	int	(*mem_alloc)(nvrm_bclient *bc, const nvrm_balloc *a,
		    nvrm_bmem **m, nvrm_bmem_info *out, char *err,
		    size_t errlen);
	int	(*mem_register)(nvrm_bclient *bc, void *addr, uint64_t bytes,
		    nvrm_bmem **m, nvrm_bmem_info *out, char *err,
		    size_t errlen);
	int	(*mem_free)(nvrm_bmem *m, int owner, char *err, size_t errlen);
	int	(*map_gpu)(nvrm_bmem *m, nvrm_bres *r, uint64_t va,
		    uint64_t offset, uint64_t length, int read_only, char *err,
		    size_t errlen);
	int	(*unmap_gpu)(nvrm_bmem *m, nvrm_bres *r, uint64_t va,
		    uint64_t length, int owner, char *err, size_t errlen);
	/* The descriptor is consumed, mapped or not (the OS layer lets one
	 * descriptor carry one mapping); the core closes it on unmap. */
	int	(*map_cpu)(nvrm_bmem *m, int fd, unsigned prot, void **addr,
		    char *err, size_t errlen);
	int	(*unmap_cpu)(nvrm_bmem *m, void *addr, int owner, char *err,
		    size_t errlen);
	int	(*export_fd)(nvrm_bmem *m, int fd, char *err, size_t errlen);
	int	(*import_fd)(nvrm_bclient *bc, int fd, nvrm_bmem **m,
		    nvrm_bmem_info *out, char *err, size_t errlen);
	/* 1 when the host is arm64 (the memory attribute rule differs). */
	int	(*host_arm64)(void);
	/* NULL, or a check of each primitive CPU access (the fake traps). */
	int	(*cpu_access)(int attr, const volatile void *p, unsigned width,
		    int write);
} nvrm_mem_ops;

extern const nvrm_mem_ops nvrm_fake_mem_ops;
extern const nvrm_mem_ops nvrm_rm_mem_ops;

/* The VA range allocator (nvrm_va.c). */
typedef struct nvrm_va nvrm_va;
nvrm_va	*nvrm_va_new(uint64_t base, uint64_t end);
void	nvrm_va_destroy(nvrm_va *va);
int	nvrm_va_alloc(nvrm_va *va, uint64_t size, uint64_t align,
	    int have_fixed, uint64_t fixed, uint64_t *out);
int	nvrm_va_free(nvrm_va *va, uint64_t addr, uint64_t size);
uint64_t nvrm_va_free_bytes(const nvrm_va *va);
unsigned nvrm_va_extents(const nvrm_va *va);

/* The CPU memory attribute rule (nvrm_mem.c).  wc is the capability flag
 * os_device_wc_active as the device reports it; coherency is NVRM_COH_*. */
int	nvrm_cpu_attr_rule(int place, int coherency, int host_arm64,
	    const nvrm_u64 *wc);

typedef struct nvrm_reserve {
	struct nvrm_reserve *next;
	uint64_t	va, bytes;
	int		sparse;
	nvrm_bres	*b;
	unsigned	nmaps;
} nvrm_reserve;

typedef struct nvrm_gmap {
	struct nvrm_gmap *next;
	uint64_t	va, length;
	nvrm_reserve	*res;
	nvrm_mem	*mem;
} nvrm_gmap;

struct nvrm_mem {
	nvrm_client	*cl;
	struct nvrm_mem	*next;
	nvrm_bmem	*b;
	int		kind, place, cpu_attr;
	uint64_t	bytes, page_size;
	unsigned	ngmaps;
	void		*cpu_addr;
	int		cpu_fd;		/* the descriptor carrying the mapping */
	unsigned	cpu_prot;
};

typedef struct nvrm_pool {
	int		*fd;
	unsigned	n, cap;
} nvrm_pool;

struct nvrm_client {
	const nvrm_backend_ops *ops;
	const nvrm_mem_ops *mops;
	nvrm_bclient	*bc;
	nvrm_va		*va;
	uint64_t	va_base, va_end;
	nvrm_reserve	*reserves;
	nvrm_gmap	*gmaps;
	nvrm_mem	*mems;
	nvrm_u64	vram_size;	/* from the device, as enumerated */
	nvrm_u64	wc_cap;
	nvrm_list	page_sizes;
	nvrm_u64	max_page_size;
	int		host_arm64;
	int		allow_map;
	nvrm_owner	owner;
	nvrm_pool	pool[NVRM_DESC__COUNT];	/* indexed by NVRM_DESC_* */
	nvrm_client_stats st;
	char		errmsg[160];
};

/* Index of the os_device_wc_active flag in nvrm_device_info.caps[]. */
#define NVRM_CAPIDX_OS_DEVICE_WC (NVRM_P_CAP_OS_DEVICE_WC - NVRM_P_CAP_DMABUF)

/* Test seam: nonzero stands for "this process is in capability mode". */
extern int (*nvrm_capmode_hook)(void);

/* The fake backend's software GPU: read or write through a GPU address, as
 * the GPU would (tests).  Returns 0, or NVRM_FAKE_FAULT_*. */
#define NVRM_FAKE_FAULT_UNMAPPED	1
#define NVRM_FAKE_FAULT_READONLY	2
int	nvrm_fake_gpu_access(nvrm_client *cl, uint64_t va, void *buf,
	    size_t len, int write);

/* Capsicum helper shared by the backends (nvrm_cap.c). */
int	nvrm_cap_limit_fd(int fd, const unsigned long *cmds, unsigned ncmds);
/* Limit a spare descriptor (mapping or export) to what it is for. */
int	nvrm_cap_limit_desc(int fd, int kind);

/* Field and capability descriptors (nvrm_fields.c); one definition. */
/* Most GPCs an enabled-unit mask can describe (the masks are 32 bits). */
#define NVRM_MAX_GPCS	32

/* The reason member of a field, by kind; aborts on a kind it does not know. */
int	*nvrm_field_reason(nvrm_device_info *info, const nvrm_field *f);

extern const nvrm_field nvrm_fields[];
extern const unsigned nvrm_nfields;
extern const char *const nvrm_group_names[];
extern const unsigned nvrm_ngroups;

/* The device emitter over a given field table (tests pass their own). */
int	nvrm_json_device_fields(const nvrm_device *dev, FILE *fp,
	    const nvrm_field *tab, unsigned n);

/* Allocation seam: the tests make the Nth allocation fail. */
#ifdef NVRM_FAULT_INJECT
void	*nvrm_test_calloc(size_t n, size_t sz);
#define NVRM_CALLOC(n, sz)	nvrm_test_calloc((n), (sz))
#else
#define NVRM_CALLOC(n, sz)	calloc((n), (sz))
#endif

#endif /* _NVRM_INTERNAL_H_ */

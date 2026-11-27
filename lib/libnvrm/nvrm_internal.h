/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * nvrm_internal.h - the backend provider table and the library's internals.
 */
#ifndef _NVRM_INTERNAL_H_
#define _NVRM_INTERNAL_H_

#include <sys/types.h>

#include <pthread.h>
#include <stdarg.h>

#include <nvrm/nvrm.h>
#include <nvrm/nvrm_chan.h>

#include "nvrm_methods.h"

#include "nvrm_fake.h"

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
	/* The warps of one multiprocessor, and the video memory heap. */
	NVRM_P_MAX_WARPS_PER_MP,
	NVRM_P_VRAM_HEAP,		/* the video memory heap, in bytes */
	NVRM_P_VRAM_FREE,		/* the video memory still free, in bytes */
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
	NVRM_SP_VBIOS,
	NVRM_SP_GSP_FIRMWARE,
	NVRM_SP_DEVICE_NAME,		/* the marketing name of the GPU */
	NVRM_SP_COUNT
};

/* The zcull (zero cull) information of the graphics engine: what the
 * driver needs to allocate and manage the zcull regions. */
typedef struct nvrm_zcull_info {
	uint64_t	width_align_pixels;
	uint64_t	height_align_pixels;
	uint64_t	aliquot_total;
	uint64_t	region_bytes;		/* per aliquot */
	uint64_t	region_header_bytes;
	uint64_t	subregion_header_bytes;
} nvrm_zcull_info;

/* The order of the properties is part of the code: the capability flags are
 * the last NVRM_NCAPS properties, in the order of nvrm_cap_name(), and
 * rm_gpu_u64() dispatches on ranges (pci, gpu, memory, engine, memory
 * heap, capabilities). */
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
	/* The running kernel module's legacy short version and parsed versions. */
	void	(*running_version)(nvrm_backend *be, nvrm_str *out);
	void	(*driver_version)(nvrm_backend *be, nvrm_version *out);
	void	(*rm_api_version)(nvrm_backend *be, nvrm_version *out);
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
	/* The zcull information of the graphics engine; returns 0 or an
	 * enum nvrm_reason. */
	int	(*gpu_zcull)(nvrm_gpu *gpu, nvrm_zcull_info *out);
	/* The host's cache line size in bytes; returns 0 or a reason. */
	int	(*host_atom_size)(nvrm_gpu *gpu, uint64_t *out);
	/* Limit the descriptors for Capsicum.  Returns enum nvrm_error. */
	int	(*limit)(nvrm_backend *be, int allow_alloc);
	/* Memory and VA (S2); NULL when the backend has none. */
	const struct nvrm_mem_ops *mem;
	/* GPFIFO channels (S3); NULL when the backend has none. */
	const struct nvrm_chan_ops *chan;
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

/* Generation table (nvrm_table.c).  The name of a row is the name of the
 * chip family; the library core names no chip and no architecture. */
typedef struct nvrm_family {
	const char	*name;
	uint32_t	cls_gpfifo, cls_compute, cls_eng3d, cls_copy;
	uint32_t	cls_eng2d, cls_m2mf, cls_vdec;
	/* The thread blocks a multiprocessor may hold, and the shared
	 * memory a work group may use and a multiprocessor may be given
	 * (in bytes).  A zero class means the family has no such class. */
	uint64_t	max_blocks_per_mp;
	uint64_t	max_smem_per_wg;
	uint64_t	sm_smem_sizes[NVRM_MAX_SMEM];	/* 0 ends */
	uint64_t	page_sizes[NVRM_MAX_PAGE_SIZES];	/* 0 ends */
} nvrm_family;
extern const nvrm_family nvrm_family_table[];
extern const unsigned nvrm_family_count;
int	nvrm_compute_capability_for(uint64_t architecture,
	    uint64_t implementation, uint32_t *major, uint32_t *minor);
/* The name of the chipset for an architecture and an implementation; 0
 * when the table has no row for the pair. */
const char *nvrm_chipset_name_for(uint64_t architecture,
	    uint64_t implementation);
/* The (architecture, implementation) pairs the chipset table and the compute
 * capability table know, two numbers per pair (the test walks them). */
unsigned nvrm_chipset_pairs(uint64_t *pairs, unsigned max);
unsigned nvrm_compute_pairs(uint64_t *pairs, unsigned max);

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
	nvrm_version	driver, rm_api;
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
	uint32_t	pte_kind;	/* enum nvrm_pte_kind */
	uint32_t	compress;	/* enum nvrm_compress */
} nvrm_balloc;

/* How the CPU side of system memory is mapped, as the backend learned it
 * (the allocation asked for it, or the RM reports it for an import). */
enum { NVRM_COH_CACHED = 0, NVRM_COH_WC, NVRM_COH_UNCACHED };

/* What the backend reports back about an object. */
typedef struct nvrm_bmem_info {
	uint64_t	bytes, page_size;
	int		place;
	int		coherency;	/* NVRM_COH_*; system memory only */
	uint64_t	handle;		/* the driver's handle of the object */
	/* The page kind the object has, and the compression policy it was
	 * made with.  A request of NVRM_PTE_KIND_DEFAULT is resolved by
	 * the backend to the layout the object really has (the pitch
	 * layout).  An object this client did not allocate (registered
	 * user pages, an imported object) reports NVRM_PTE_KIND_DEFAULT
	 * and NVRM_COMPRESS_NONE: this client made no request for it. */
	uint32_t	pte_kind;	/* enum nvrm_pte_kind */
	uint32_t	compress;	/* enum nvrm_compress */
} nvrm_bmem_info;

/* What the backend needs to know about a CPU mapping it replaces: the
 * descriptor that carries it, the protection it was made with, its length
 * and the cookie the backend needs to unmap it. */
typedef struct nvrm_cmap_info {
	int		fd;
	unsigned	prot;
	uint64_t	length;
	uint64_t	cookie;
} nvrm_cmap_info;

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
	 * descriptor carry one mapping); the core closes it on unmap.
	 * A fixed address asks for the mapping to be made at that address;
	 * 0 lets the backend pick one.
	 *
	 * A fixed address must never replace another mapping: the backend
	 * maps it atomically, so that the kernel refuses an occupied range
	 * (MAP_FIXED|MAP_EXCL) and answers NVRM_E_BUSY.  A backend that
	 * checked the range first and mapped it afterwards would let two
	 * clients take the same address. */
	int	(*map_cpu)(nvrm_bmem *m, int fd, unsigned prot, uint64_t fixed,
		    void **addr, uint64_t *cookie, char *err, size_t errlen);
	int	(*unmap_cpu)(nvrm_bmem *m, void *addr, uint64_t cookie, int owner,
		    char *err, size_t errlen);
	/* Replace the mapping at addr with anonymous memory, in place, and
	 * tell the driver to forget the mapping it made.  The range is not
	 * unmapped: the caller may map over it again at once.
	 *
	 * The backend restores the original mapping when the driver refuses
	 * to forget it, so a refused overmap leaves the range as it was.
	 * *replaced says whether the range holds anonymous memory now: a
	 * backend that could not restore says 1, and the caller then drops
	 * the record of the mapping (the range is no longer the object's). */
	int	(*overmap_cpu)(nvrm_bmem *m, const nvrm_cmap_info *cm,
		    void *addr, int *replaced, char *err, size_t errlen);
	int	(*export_fd)(nvrm_bmem *m, int fd, char *err, size_t errlen);
	int	(*import_fd)(nvrm_bclient *bc, int fd, nvrm_bmem **m,
		    nvrm_bmem_info *out, char *err, size_t errlen);
	/* 1 when the host is arm64 (the memory attribute rule differs). */
	int	(*host_arm64)(void);
	/* NULL, or a check of each primitive CPU access (the fake traps). */
	int	(*cpu_access)(int attr, const volatile void *p, unsigned width,
		    int write);
} nvrm_mem_ops;

/*
 * The layout of a channel's memory object, named once.  The ring and the
 * release segments come first and are mapped read-only for the GPU; the
 * progress semaphore has a page of its own, mapped read-write, so the GPU
 * can write nothing but the semaphore.  e is the entry count.
 */
#define NVRM_CHAN_PAGE		4096ULL
#define NVRM_CHAN_RING_OFF(e)	0ULL
#define NVRM_CHAN_RELEASE_OFF(e) ((uint64_t)(e) * 8)
#define NVRM_CHAN_SEG_BYTES	(NVRM_RELEASE_SEG_DWORDS * 4ULL)
#define NVRM_CHAN_SEG_OFF(e, i)	(NVRM_CHAN_RELEASE_OFF(e) + \
				    (uint64_t)(i) * NVRM_CHAN_SEG_BYTES)
#define NVRM_CHAN_SEM_OFF(e)	((NVRM_CHAN_SEG_OFF(e, e) + \
				    NVRM_CHAN_PAGE - 1) & ~(NVRM_CHAN_PAGE - 1))
#define NVRM_CHAN_BYTES(e)	(NVRM_CHAN_SEM_OFF(e) + NVRM_CHAN_PAGE)

/* The default sleep slice of a waiter, in nanoseconds. */
#define NVRM_CHAN_SLICE_DEFAULT_NS	100000000ULL

/* Trace and barrier event codes: the barrier hook reports the first two, the
 * fake backend the others (tests). */
enum nvrm_chan_event {
	NVRM_CHAN_EV_BARRIER_NORMAL = 1,
	NVRM_CHAN_EV_BARRIER_DEVICE,
	NVRM_CHAN_EV_GP_PUT,
	NVRM_CHAN_EV_DOORBELL
};

/* A backend channel owns only the GPU-side operations; the core owns every
 * ring, ordering, validation and lifetime rule.  core is opaque to ordinary
 * backends and lets the fake find the client whose software GPU it runs. */
typedef struct nvrm_bchan nvrm_bchan;
typedef struct nvrm_bchan_cfg {
	uint32_t	engines, entries, runlist;
	uint64_t	ring_va;	/* GPU VA of the ring (entries*8 bytes) */
	nvrm_chan	*core;
} nvrm_bchan_cfg;
typedef struct nvrm_bchan_info {
	uint32_t	cls_gpfifo;
	uint32_t	subch_class[8];
} nvrm_bchan_info;
typedef struct nvrm_chan_ops {
	int	copy_on_graphics;
	int	(*create)(nvrm_bclient *bc, const nvrm_bchan_cfg *cfg,
		    nvrm_bchan **b, nvrm_bchan_info *out, char *err,
		    size_t errlen);
	int	(*destroy)(nvrm_bchan *b, char *err, size_t errlen);
	/* Drop the backend record of a channel whose destroy was refused,
	 * without touching device state: the client is closing and the core
	 * is about to free the memory the record refers to. */
	void	(*forget)(nvrm_bchan *b);
	uint32_t (*gp_get)(nvrm_bchan *b);
	void	(*gp_put)(nvrm_bchan *b, uint32_t put);
	void	(*doorbell)(nvrm_bchan *b);
	uint32_t (*error)(nvrm_bchan *b);
	/* A count that changes whenever any channel of the client makes
	 * progress.  The core reads it before it checks, and wait() sleeps
	 * only while it still has that value, so progress between the check
	 * and the sleep is never lost. */
	uint64_t (*progress_gen)(nvrm_bclient *bc);
	int	(*wait)(nvrm_bclient *bc, uint64_t slice_ns, uint64_t gen);
} nvrm_chan_ops;

/* One queued submitter; the queue is a FIFO under the channel lock. */
typedef struct nvrm_chan_waiter {
	struct nvrm_chan_waiter *next;
} nvrm_chan_waiter;

struct nvrm_chan {
	nvrm_client	*cl;
	struct nvrm_chan *next;
	nvrm_bchan	*b;
	nvrm_mem	*mem;
	void		*cpu;
	uint64_t	ring_va, sem_va;
	uint32_t	engines, entries, runlist;
	nvrm_bchan_info	info;
	pthread_mutex_t	lock;
	pthread_cond_t	turn;		/* the queue head changed or a waiter left */
	nvrm_chan_waiter *q_head, *q_tail;
	uint64_t	*slot_point;	/* per ring slot: the release written
					 * there, 0 for a caller entry */
	uint32_t	gp_put;
	uint32_t	gp_get;		/* atomic: waiters refresh peer channels */
	uint32_t	state, error;	/* atomic for the same reason */
	uint64_t	submitted, completed;
	int		kick_pending;
};

extern const nvrm_mem_ops nvrm_fake_mem_ops;
extern const nvrm_mem_ops nvrm_rm_mem_ops;
extern nvrm_chan_ops nvrm_fake_chan_ops;
/* Test seam: the next nth GPU reads of the fake channel fail (0 disarms
 * it).  A read error is not a fault: the channel stays alive. */
extern void nvrm_fake_chan_read_fail(unsigned nth);
/* Client close: forget and free the channels whose destroy was refused. */
void	nvrm_chan_release_held(nvrm_client *cl);
extern uint64_t nvrm_chan_slice_ns;
/* Test seam: runs between the unlock and the sleep of a waiter. */
extern void (*nvrm_chan_presleep_hook)(void);

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

/* One CPU mapping of an object: the address, the descriptor that carries
 * it and the protection it was made with. */
typedef struct nvrm_cmap {
	struct nvrm_cmap	*next;
	uint64_t	addr;		/* the address the mapping has */
	uint64_t	length;
	int		fd;		/* the descriptor carrying the mapping */
	unsigned	prot;
	uint64_t	cookie;		/* what the backend needs to unmap it */
} nvrm_cmap;

struct nvrm_mem {
	nvrm_client	*cl;
	struct nvrm_mem	*next;
	nvrm_bmem	*b;
	int		kind, place, cpu_attr;
	uint64_t	bytes, page_size;
	unsigned	ngmaps;
	/* The CPU mappings of the object: there may be more than one, and
	 * each has its own descriptor. */
	nvrm_cmap	*cmaps;
	unsigned	ncmaps;
	uint64_t	handle;		/* the driver's handle of the object */
	uint32_t	pte_kind;		/* enum nvrm_pte_kind the object got */
	uint32_t	compress;		/* enum nvrm_compress the object got */
};

typedef struct nvrm_pool {
	int		*fd;
	unsigned	n, cap;
} nvrm_pool;

struct nvrm_client {
	const nvrm_backend_ops *ops;
	const nvrm_mem_ops *mops;
	/* The client's own lock: every call of nvrm_mem(3) takes it, so
	 * several threads may use one client at the same time. */
	pthread_mutex_t lock;
	nvrm_bclient	*bc;
	nvrm_va		*va;
	uint64_t	va_base, va_end;
	nvrm_reserve	*reserves;
	nvrm_gmap	*gmaps;
	nvrm_mem	*mems;
	nvrm_chan	*channels;
	nvrm_chan	*held;		/* destroy refused: kept until close */
	nvrm_u64	vram_size;	/* from the device, as enumerated */
	nvrm_u64	wc_cap;
	nvrm_list	page_sizes;
	nvrm_u64	max_page_size;
	int		host_arm64;
	int		allow_map;
	nvrm_owner	owner;
	nvrm_pool	pool[NVRM_DESC__COUNT];	/* indexed by NVRM_DESC_* */
	nvrm_client_stats st;
	/* Guards every clear and write of errmsg that a channel call makes:
	 * channel calls may run on several threads of one client. */
	pthread_mutex_t	errlock;
	char		errmsg[160];
};

/*
 * The client's message.  Every clear and every write of it goes through the
 * client's error lock, so that two threads of one client cannot write the
 * buffer at the same time.  The lock is recursive (the channel calls hold
 * it across the memory calls they make) and it is always the inner lock.
 */
static inline void
nvrm_client_clear_err(nvrm_client *cl)
{
	(void)pthread_mutex_lock(&cl->errlock);
	cl->errmsg[0] = '\0';
	(void)pthread_mutex_unlock(&cl->errlock);
}

static inline int
nvrm_client_fail(nvrm_client *cl, int rc, const char *fmt, ...)
{
	va_list ap;

	(void)pthread_mutex_lock(&cl->errlock);
	va_start(ap, fmt);
	(void)vsnprintf(cl->errmsg, sizeof(cl->errmsg), fmt, ap);
	va_end(ap);
	(void)pthread_mutex_unlock(&cl->errlock);
	return (rc);
}

/* Index of the os_device_wc_active flag in nvrm_device_info.caps[]. */
#define NVRM_CAPIDX_OS_DEVICE_WC (NVRM_P_CAP_OS_DEVICE_WC - NVRM_P_CAP_DMABUF)

/* Test seam: nonzero stands for "this process is in capability mode". */
extern int (*nvrm_capmode_hook)(void);
/* Test seam: runs at the start of the adoption of a new object, before the
 * client's list of objects is changed.  The client lock is held there: the
 * test uses the seam to hold the threads at the same point, and to see that
 * the lock keeps them apart. */
extern void (*nvrm_mem_adopt_hook)(void);

/* The fake backend's software GPU: read or write through a GPU address, as
 * the GPU would (tests).  Returns 0, or NVRM_FAKE_FAULT_*. */
#define NVRM_FAKE_FAULT_UNMAPPED	1
#define NVRM_FAKE_FAULT_READONLY	2
int	nvrm_fake_gpu_access(nvrm_client *cl, uint64_t va, void *buf,
	    size_t len, int write);

/* Fake channel faults and its test controls. */
#define NVRM_FAKE_CHAN_ERR_UNSUPPORTED	13
#define NVRM_FAKE_CHAN_ERR_MMU		31
void	nvrm_fake_chan_manual(int on);
/* Test seam: GP_GET moves when an entry is fetched, up to two entries ahead
 * of the pushbuffer that runs (a step is one fetch or one pushbuffer). */
void	nvrm_fake_chan_lag(int on);
int	nvrm_fake_chan_step(nvrm_chan *ch, unsigned max_entries);
void	nvrm_fake_chan_fault(nvrm_chan *ch, uint32_t code);
typedef struct nvrm_fake_chan_counts {
	uint64_t	entries, methods, nops, releases, acquires;
	uint64_t	copies, bytes_copied, ignored, doorbells;
} nvrm_fake_chan_counts_t;
nvrm_fake_chan_counts_t nvrm_fake_chan_counts(nvrm_chan *ch);
/* Test trace: gp_put and doorbell report their enum nvrm_chan_event codes. */
extern void (*nvrm_fake_chan_event_hook)(int);

/* The fake memory test seam: the public counters plus the objects the
 * last-close sweep found leaked (more references held than the wrappers a
 * fork child released). */
typedef struct nvrm_fake_mem_test_stats {
	nvrm_fake_mem_stats	base;
	unsigned		leaked_objects;
} nvrm_fake_mem_test_stats;
void	nvrm_fake_mem_test_stats_get(nvrm_fake_mem_test_stats *st);
/* Plant a leak: hold a reference on the object of a wrapper that nothing
 * releases (tests). */
void	nvrm_fake_mem_test_leak_ref(nvrm_bmem *m);

/* Capsicum helper shared by the backends (nvrm_cap.c). */
int	nvrm_cap_limit_fd(int fd, const unsigned long *cmds, unsigned ncmds);
/* Limit a spare descriptor (mapping or export) to what it is for. */
int	nvrm_cap_limit_desc(int fd, int kind);

/* Field and capability descriptors (nvrm_fields.c); one definition. */
#define NVRM_STRINGIFY_(x)	#x
#define NVRM_STRINGIFY(x)	NVRM_STRINGIFY_(x)
/* Most GPCs an enabled-unit mask can describe (the masks are 32 bits). */
#define NVRM_MAX_GPCS	32

/* The reason member of a field, by kind; aborts on a kind it does not know. */
int	*nvrm_field_reason(nvrm_device_info *info, const nvrm_field *f);

extern const nvrm_field nvrm_fields[];
extern const unsigned nvrm_nfields;
/* The rows nvrm_info_field() returned at NVRM_1.0 (the table's first rows, in
 * their 1.0 order; every later row is after them).  nvrm_compat.c serves
 * exactly these to a caller bound to the NVRM_1.0 symbols. */
#define NVRM_NFIELDS_1_0	30
/* The one definition of "added after NVRM_1.0": a row whose member sits at or
 * after rm_sm_version in nvrm_device_info.  nvrm_compat.c and core_test both
 * use it; core_test ties NVRM_NFIELDS_1_0 to it (the first NVRM_NFIELDS_1_0
 * rows are not added after 1.0, every later row is). */
#define NVRM_ADDED_AFTER_1_0(off)					\
	((off) >= offsetof(nvrm_device_info, rm_sm_version))
/* The NVRM_1.0 versions of the field-table calls (nvrm_compat.c, shared
 * library only). */
unsigned nvrm_info_nfields_1_0(void);
const nvrm_field *nvrm_info_field_1_0(unsigned index);
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

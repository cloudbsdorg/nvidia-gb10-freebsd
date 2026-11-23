/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * <nvrm/nvrm.h> - libnvrm: device discovery, GPU memory and virtual address
 * space over the NVIDIA Resource Manager.  See nvrm(3), nvrm_mem(3) and
 * nvrm(7).
 *
 * The library never names a chip: values come from the RM, and the chip
 * specific numbers (class ids, page sizes) from a generation table keyed by
 * class ids.  Backends are providers in a registry: "rm" (the kernel driver)
 * and "fake" (no hardware; NVRM_BACKEND=fake).
 *
 * Every value is either available or carries a reason it is not: nothing is
 * ever reported as a made-up number.
 *
 * Threads and fork: a context and its devices are not safe for concurrent
 * use (nvrm_device_refresh rewrites in place the information that
 * nvrm_device_info_get handed out); use one context per thread, or your own
 * lock.  Only the registry of backends is shared by every context: it is
 * filled once, however many threads reach it first; nothing else is promised
 * across threads.
 * The fake backend keeps process-wide test state: use it from one thread.
 * After
 * fork() the child must not use a context except to call nvrm_close(), which
 * then releases only the child's copy of the descriptor and the memory: the
 * RM client belongs to the parent.
 */
#ifndef _NVRM_NVRM_H_
#define _NVRM_NVRM_H_

#include <sys/cdefs.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

#include <nvrm/nvrm_version.h>

/* The RM version this library is built against (open-gpu-kernel-modules). */
#define NVRM_RM_VERSION		"580.178.04"
/* Library API version (shared object nvrm.so.1; symbol versions NVRM_1.0 for
 * discovery, NVRM_1.1 for memory and VA, NVRM_1.2 for version numbers,
 * NVRM_1.3 for channels).
 * PROVISIONAL: the interface and the structures below are frozen at the first
 * package release and not before; a future version may still reshape them. */
#define NVRM_API_MAJOR		1
#define NVRM_API_MINOR		3

#define NVRM_MAX_GPUS		32
#define NVRM_MAX_CLASSES	200
#define NVRM_MAX_PAGE_SIZES	8
#define NVRM_STR_MAX		96
#define NVRM_MAX_DECORATORS	4
#define NVRM_NCAPS		7

/* Return values.  0 is success. */
enum nvrm_error {
	NVRM_OK = 0,
	NVRM_E_NOBACKEND,	/* no backend usable, or the named one unknown */
	NVRM_E_OPEN,		/* the control device could not be opened */
	NVRM_E_VERSION,		/* the kernel module is not the built-for RM */
	NVRM_E_IO,		/* an RM call failed */
	NVRM_E_NOMEM,
	NVRM_E_INVAL,
	NVRM_E_NODEV,		/* no longer returned: no GPU is a success with 0 devices */
	NVRM_E_CAPSICUM,	/* the descriptors could not be limited */
	/* Appended, never reordered (the numbers are stable identifiers). */
	NVRM_E_RM,		/* the RM refused a call (the status is in the message) */
	NVRM_E_DENIED,		/* not allowed: the client lacks the open flag, the
				   mapping lacks the access, or this process did
				   not open the client (a fork child) */
	NVRM_E_NOSLOT,		/* no pre-opened spare descriptor is left */
	NVRM_E_RANGE,		/* out of VA space, overlap, or outside the object */
	NVRM_E_NOTSUP,		/* the backend does not provide the operation */
	NVRM_E_BUSY,		/* still in use: unmap or free what depends on it */
	NVRM_E_TIMEOUT,		/* the operation reached its deadline */
	NVRM_E_LOST,		/* the channel is dead */
	NVRM_E__COUNT
};

/* Why a value is not available (0 = it is). */
enum nvrm_reason {
	NVRM_R_NONE = 0,
	NVRM_R_NOT_QUERIED,
	NVRM_R_RM_FAILED,
	NVRM_R_RM_UNSUPPORTED,
	NVRM_R_OS_NOT_REPORTED,
	NVRM_R_FAMILY_UNKNOWN,	/* the GPU matched no generation table row */
	NVRM_R_INPUT_MISSING,
	NVRM_R_NO_NUMA,
	NVRM_R_BACKEND_NONE,
	NVRM_R_CLASS_ABSENT,
	NVRM_R_OS_CALL_FAILED,	/* the system call to the driver failed */
	NVRM_R_VALUE_UNUSABLE,	/* the RM answered; the library cannot verify it */
	NVRM_R_FAMILY_NO_CLASS,	/* the family is known and has no class of this kind */
	NVRM_R_VERSION_UNPARSED,	/* a version has no readable numeric scheme */
	NVRM_R_VERSION_INCONSISTENT,	/* the version sysctls disagree */
	NVRM_R__COUNT
};

/* Which layer supplied (or failed to supply) a value. */
enum nvrm_source {
	NVRM_S_RM = 0,		/* an RM control */
	NVRM_S_OS,		/* the OS layer (sysctl, card info) */
	NVRM_S_DERIVED,		/* computed from RM values */
	NVRM_S_FAMILY,		/* the generation table */
	NVRM_S_BOARD,		/* a PCI-subsystem decorator */
	NVRM_S__COUNT
};

typedef struct nvrm_u64 {
	uint64_t	value;
	int		reason;		/* enum nvrm_reason; NVRM_R_NONE = ok */
	int		source;		/* enum nvrm_source */
} nvrm_u64;

typedef struct nvrm_str {
	char		value[NVRM_STR_MAX];
	int		reason;
	int		source;
} nvrm_str;

typedef struct nvrm_list {
	uint32_t	count;
	uint64_t	value[NVRM_MAX_CLASSES];
	int		reason;
	int		source;
} nvrm_list;

/* A parsed version and the layer which supplied its source string. */
typedef struct nvrm_version_field {
	nvrm_version	version;
	int		source;
} nvrm_version_field;

#define NVRM_HAVE(f)	((f).reason == NVRM_R_NONE)

/*
 * Device model: abstract device (identity), then class (gpu), then family
 * (generation table), then board decorators.  Each layer fills or overrides
 * only what it knows; the rest stays unavailable with a reason.  Callers use
 * the abstract and class members only.  The list of members is one definition
 * (nvrm_fields.h) that also generates the JSON schema.
 */
typedef struct nvrm_device_info {
	/* abstract device */
	nvrm_u64	pci_domain, pci_bus, pci_slot, pci_function;
	nvrm_u64	pci_vendor, pci_device;
	nvrm_u64	pci_subsystem_vendor, pci_subsystem_device, pci_revision;
	nvrm_u64	rm_gpu_id;
	nvrm_str	uuid;
	/* class: gpu */
	nvrm_u64	architecture, implementation, chip_id;
	/* sm_version is the RM's numbering, not necessarily CUDA's. */
	nvrm_u64	sm_version_major, sm_version_minor;
	nvrm_u64	gpc_count, tpc_count, sm_count;
	nvrm_u64	cls_gpfifo, cls_compute, cls_eng3d, cls_copy;
	nvrm_list	classes;
	/* family (generation table) */
	nvrm_str	family;
	/* memory */
	nvrm_u64	vram_size, bar1_size, max_page_size, numa_node;
	nvrm_list	page_sizes;
	/* capabilities: stable index + name (nvrm_cap_name()) */
	nvrm_u64	caps[NVRM_NCAPS];
	/* board decorators that matched (names, static strings) */
	unsigned	ndecorators;
	const char	*decorators[NVRM_MAX_DECORATORS];
	/* NVRM_1.1: appended so every NVRM_1.0 member keeps its offset. */
	nvrm_u64	rm_sm_version;
	nvrm_u64	compute_capability_major, compute_capability_minor;
	/* firmware versions reported by the RM */
	nvrm_version_field vbios, gsp_firmware;
} nvrm_device_info;

/* Describes one member of nvrm_device_info (the one definition that drives
 * the JSON output, the schema and the text view). */
enum nvrm_kind { NVRM_K_U64, NVRM_K_STR, NVRM_K_LIST, NVRM_K_VERSION };
typedef struct nvrm_field {
	const char	*group;
	const char	*name;
	int		kind;		/* enum nvrm_kind */
	size_t		offset;		/* into nvrm_device_info */
	int		hex;		/* text mode prints it in hex */
	const char	*desc;
} nvrm_field;

typedef struct nvrm_ctx nvrm_ctx;
typedef struct nvrm_device nvrm_device;

#define NVRM_ENUM_ALLOW_ALLOC		0x2	/* bit 0 was a retired flag: refused */
#define NVRM_ENUM_KNOWN_FLAGS		NVRM_ENUM_ALLOW_ALLOC

typedef struct nvrm_enum_opts {
	const char	*backend;	/* NULL: NVRM_BACKEND, else best probe */
	/*
	 * Zero-initialize the structure: nvrm_enum_opts o = { 0 };.  With no
	 * flag set, or with opts NULL, the descriptors keep only the RM control
	 * and free escapes and no mapping right (least privilege), which is all
	 * that reading device information needs.  A caller that will allocate
	 * RM objects after cap_enter() must set NVRM_ENUM_ALLOW_ALLOC before
	 * the limit is applied: Capsicum rights can only be narrowed, so they
	 * cannot be asked for later.  The descriptor never has a mapping right,
	 * with or without this flag: this version of libnvrm
	 * has no call that maps device memory, inside or outside capability mode.
	 * A bit this library does not know is refused with NVRM_E_INVAL, so a
	 * caller built for an older meaning of the member cannot silently get
	 * other rights.
	 */
	unsigned	flags;
	/* Room for later options.  Must be zero: a nonzero value is refused
	 * with NVRM_E_INVAL, so a caller built for a later meaning of these
	 * members cannot silently get this version's behaviour.  Part of the
	 * NVRM_1.0 layout, which is provisional until the first package
	 * release (see above): nothing built against another layout was ever
	 * released. */
	uint32_t	reserved[4];
} nvrm_enum_opts;

/*
 * ---- Memory and virtual address space (nvrm_mem(3)) -----------------------
 *
 * nvrm_client_open() makes one RM client for one GPU: its own descriptors, its
 * own VA space (the library hands out the addresses; the RM maps at exactly
 * the ones asked for) and every memory object made through it.  The client is
 * independent of the nvrm_ctx it was opened from and may outlive it.  Closing
 * the client frees every object, mapping and reservation still in it.
 *
 * Capsicum: all descriptors are opened and limited here; after cap_enter() the
 * client keeps working.  CPU mapping needs NVRM_OPEN_ALLOW_MAP: without it
 * nvrm_mem_map_cpu() is refused with NVRM_E_DENIED, and no descriptor that
 * could be mapped exists.
 *
 * CPU access follows the memory attribute rule (nvrm(7), Memory attributes):
 * the attribute a mapping gets is nvrm_mem_info.cpu_attr.  Through NVRM_ATTR_DEVICE only
 * aligned accesses of 1, 2, 4 or 8 bytes are safe; use nvrm_mem_read() and
 * nvrm_mem_write(), which obey the rule, or follow it in your own code.
 *
 * A client is not safe for concurrent use; use one thread per client or a lock.
 * After fork() the RM client still belongs to the parent.  In the child, a
 * call that would create or act on RM objects is refused with NVRM_E_DENIED;
 * a release (unmap, free, VA release, close) succeeds and drops only the
 * child's records; the getters and nvrm_mem_read()/nvrm_mem_write() are not
 * checked, and CPU mappings the child inherited still reach the memory: a
 * caller that wants the child kept out unmaps them before fork(), or marks
 * them with minherit(2) INHERIT_NONE.
 *
 * Structures with a size member: set it to sizeof the structure, or to 0,
 * which means the same; any other value is refused with NVRM_E_INVAL.
 */
typedef struct nvrm_client nvrm_client;
typedef struct nvrm_mem nvrm_mem;

#define NVRM_OPEN_ALLOW_MAP	0x1	/* CPU mapping (and the descriptors it needs) */
#define NVRM_OPEN_KNOWN_FLAGS	NVRM_OPEN_ALLOW_MAP

typedef struct nvrm_open_opts {
	uint32_t	size;		/* sizeof(nvrm_open_opts); 0 means that */
	uint32_t	flags;		/* NVRM_OPEN_* */
	/* Spare descriptors opened at once, for use after cap_enter(): each CPU
	 * mapping or export consumes one for good (the count is a budget over
	 * the client's life in capability mode, not a pool that refills). */
	uint32_t	map_slots;	/* with ALLOW_MAP: mapping descriptors (0 means 16) */
	uint32_t	export_slots;	/* export descriptors (0 means 4) */
} nvrm_open_opts;

#define NVRM_MAP_SLOTS_DEFAULT		16
#define NVRM_EXPORT_SLOTS_DEFAULT	4
#define NVRM_SLOTS_MAX			1024

enum nvrm_mem_kind {
	NVRM_MEM_VRAM = 1,	/* the GPU's own memory (system memory where it has none) */
	NVRM_MEM_SYSMEM,	/* system memory the GPU can reach, CPU-coherent */
	NVRM_MEM_USER,		/* registered pages of the caller's address space */
	NVRM_MEM_IMPORTED	/* imported from a descriptor */
};

enum nvrm_place {
	NVRM_PLACE_VIDMEM = 1,
	NVRM_PLACE_SYSMEM
};

enum nvrm_cpu_attr {
	NVRM_ATTR_CACHED = 1,	/* write-back: any access */
	NVRM_ATTR_WC,		/* write-combining (arm64: Normal non-cacheable) */
	NVRM_ATTR_DEVICE	/* arm64 Device-nGnRE: aligned 1/2/4/8 byte accesses only */
};

#define NVRM_CPU_READ		0x1
#define NVRM_CPU_WRITE		0x2

typedef struct nvrm_vaspace_info {
	uint32_t	size;
	uint64_t	base;		/* lowest usable address */
	uint64_t	end;		/* one past the highest */
	uint64_t	free_bytes;	/* not reserved */
} nvrm_vaspace_info;

#define NVRM_VA_SPARSE		0x1	/* unmapped addresses read as zero, not fault */
#define NVRM_VA_KNOWN_FLAGS	NVRM_VA_SPARSE

typedef struct nvrm_va_params {
	uint32_t	size;		/* sizeof(nvrm_va_params); 0 means that */
	uint32_t	flags;		/* NVRM_VA_* */
	uint64_t	bytes;
	uint64_t	alignment;	/* a power of two (0 means 4 KiB); at least
					   the page size of what is mapped there */
	uint64_t	fixed;		/* 0 means the library picks; else the address */
} nvrm_va_params;

typedef struct nvrm_mem_params {
	uint32_t	size;		/* sizeof(nvrm_mem_params); 0 means that */
	uint32_t	kind;		/* NVRM_MEM_VRAM or NVRM_MEM_SYSMEM */
	uint32_t	flags;		/* none yet: must be 0 */
	uint32_t	reserved;	/* must be 0 */
	uint64_t	bytes;		/* rounded up to the page size */
	uint64_t	alignment;	/* a power of two (0 means the page size) */
	/* One of 4 KiB, 64 KiB, 2 MiB or 512 MiB that the GPU lists; or 0,
	 * for which the library picks 64 KiB when the object is video memory
	 * of at least 64 KiB and the GPU lists 64 KiB, and 4 KiB otherwise.
	 * nvrm_mem_info.page_size is the page size mappings are checked
	 * against: what the object got, or for an import the smallest page
	 * the RM's answer allows (nvrm_mem(3)). */
	uint64_t	page_size;
} nvrm_mem_params;

#define NVRM_MAP_READ_ONLY	0x1	/* the GPU may only read through this mapping */
#define NVRM_MAP_KNOWN_FLAGS	NVRM_MAP_READ_ONLY

typedef struct nvrm_gpu_map_params {
	uint32_t	size;		/* sizeof(nvrm_gpu_map_params); 0 means that */
	uint32_t	flags;		/* NVRM_MAP_* */
	uint64_t	va;		/* the address, inside a reservation */
	uint64_t	offset;		/* into the object; a multiple of its page size */
	uint64_t	length;		/* 0 means to the end of the object */
} nvrm_gpu_map_params;

typedef struct nvrm_mem_info {
	uint32_t	size;
	uint32_t	kind;		/* enum nvrm_mem_kind */
	uint32_t	place;		/* enum nvrm_place */
	uint32_t	cpu_attr;	/* enum nvrm_cpu_attr a CPU mapping gets */
	uint64_t	bytes;
	uint64_t	page_size;
	uint32_t	cpu_mapped;
	uint32_t	gpu_maps;
} nvrm_mem_info;

/* What a client holds now and what it has done: leak checks read this.
 * size is 0, sizeof(nvrm_client_stats), or offsetof(nvrm_client_stats,
 * live_channels) for a caller built against NVRM_1.1 (that much is filled). */
typedef struct nvrm_client_stats {
	uint32_t	size;
	uint32_t	reserved;
	uint64_t	allocs, frees;		/* memory objects, ever */
	uint64_t	live_mem, live_bytes;
	uint64_t	live_reservations, live_gpu_maps, live_cpu_maps;
	uint64_t	spare_descriptors;	/* pre-opened and unused */
	/* Releases the RM refused (an unmap or a free): what they held stays
	 * with the RM client until it closes, and its VA is never handed out
	 * again. */
	uint64_t	failed_releases;
	uint64_t	live_channels, channels_created;
} nvrm_client_stats;

__BEGIN_DECLS
/*
 * Open the control device, check the RM version, list the probed GPUs, attach
 * them, query each one, and limit the descriptors for Capsicum.  On failure
 * *ctxp is NULL and err (if not NULL) holds a one-line message.  No GPU is not
 * a failure: it returns NVRM_OK with nvrm_device_count() 0.
 */
int		nvrm_enumerate(nvrm_ctx **ctxp, const nvrm_enum_opts *opts,
		    char *err, size_t errlen);
void		nvrm_close(nvrm_ctx *ctx);

const char	*nvrm_backend_name(const nvrm_ctx *ctx);
const nvrm_str	*nvrm_rm_running_version(const nvrm_ctx *ctx);
const nvrm_version *nvrm_driver_version(const nvrm_ctx *ctx);
const nvrm_version *nvrm_rm_api_version(const nvrm_ctx *ctx);
const nvrm_version *nvrm_built_for_version(void);
const nvrm_version *nvrm_library_version(void);
const nvrm_version *nvrm_symbol_version(void);
const nvrm_version *nvrm_schema_version(void);
unsigned	nvrm_device_count(const nvrm_ctx *ctx);
nvrm_device	*nvrm_device_get(const nvrm_ctx *ctx, unsigned index);
const nvrm_device_info *nvrm_device_info_get(const nvrm_device *dev);
/* Query again through the already open descriptors (works in capability mode). */
int		nvrm_device_refresh(nvrm_device *dev);


/* ---- Memory and virtual address space: nvrm_mem(3) ---- */
int		nvrm_client_open(const nvrm_device *dev,
		    const nvrm_open_opts *opts, nvrm_client **clp, char *err,
		    size_t errlen);
void		nvrm_client_close(nvrm_client *cl);
/* One line about the most recent call on the client: "" when it succeeded. */
const char	*nvrm_client_errmsg(const nvrm_client *cl);
int		nvrm_client_stats_get(nvrm_client *cl,
		    nvrm_client_stats *st);
int		nvrm_vaspace_info_get(nvrm_client *cl,
		    nvrm_vaspace_info *info);
int		nvrm_va_reserve(nvrm_client *cl, const nvrm_va_params *p,
		    uint64_t *va);
int		nvrm_va_release(nvrm_client *cl, uint64_t va);
int		nvrm_mem_alloc(nvrm_client *cl, const nvrm_mem_params *p,
		    nvrm_mem **memp);
int		nvrm_mem_register_user(nvrm_client *cl, void *addr,
		    uint64_t bytes, nvrm_mem **memp);
void		nvrm_mem_free(nvrm_mem *mem);
int		nvrm_mem_info_get(const nvrm_mem *mem, nvrm_mem_info *info);
int		nvrm_mem_map_gpu(nvrm_mem *mem, const nvrm_gpu_map_params *p);
int		nvrm_mem_unmap_gpu(nvrm_mem *mem, uint64_t va);
int		nvrm_mem_map_cpu(nvrm_mem *mem, unsigned prot, void **addr);
int		nvrm_mem_unmap_cpu(nvrm_mem *mem);
int		nvrm_mem_read(nvrm_mem *mem, uint64_t offset, void *buf,
		    size_t len);
int		nvrm_mem_write(nvrm_mem *mem, uint64_t offset, const void *buf,
		    size_t len);
int		nvrm_mem_export_fd(nvrm_mem *mem, int *fd);
int		nvrm_mem_import_fd(nvrm_client *cl, int fd, nvrm_mem **memp);

const char	*nvrm_strerror(int error);
const char	*nvrm_error_id(int error);	/* stable machine id */
const char	*nvrm_reason_id(int reason);
const char	*nvrm_reason_text(int reason);
const char	*nvrm_source_name(int source);
/* Capability flag name for a stable index, NULL when out of range. */
const char	*nvrm_cap_name(unsigned index);
/* The member descriptors; NULL when index is out of range. */
unsigned	nvrm_info_nfields(void);
const nvrm_field *nvrm_info_field(unsigned index);

/* JSON (schema nvrm-info/1).  Each returns 0, or -1 when the stream failed. */
int		nvrm_json_document(const nvrm_ctx *ctx, FILE *fp);
int		nvrm_json_header(const nvrm_ctx *ctx, FILE *fp);
int		nvrm_json_device(const nvrm_device *dev, FILE *fp);
int		nvrm_json_end(unsigned count, FILE *fp);
int		nvrm_json_error(const char *code, const char *message, FILE *fp);
/* The schema, generated from the same definition as the emitter. */
int		nvrm_json_schema(FILE *fp);
__END_DECLS

#endif /* _NVRM_NVRM_H_ */

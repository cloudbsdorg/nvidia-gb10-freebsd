/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * <nvrm/nvrm.h> - libnvrm: device discovery over the NVIDIA Resource Manager
 * (Track #2378).  See nvrm(3) and nvrm(7).
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

/* The RM version this library is built against (open-gpu-kernel-modules). */
#define NVRM_RM_VERSION		"580.178.04"
/* Library API version (shared object nvrm.so.1, symbol version NVRM_1.0).
 * PROVISIONAL: the interface and the structures below are frozen at the first
 * package release and not before; a future version may still reshape them. */
#define NVRM_API_MAJOR		1
#define NVRM_API_MINOR		0

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
} nvrm_device_info;

/* Describes one member of nvrm_device_info (the one definition that drives
 * the JSON output, the schema and the text view). */
enum nvrm_kind { NVRM_K_U64, NVRM_K_STR, NVRM_K_LIST };
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
} nvrm_enum_opts;

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
unsigned	nvrm_device_count(const nvrm_ctx *ctx);
nvrm_device	*nvrm_device_get(const nvrm_ctx *ctx, unsigned index);
const nvrm_device_info *nvrm_device_info_get(const nvrm_device *dev);
/* Query again through the already open descriptors (works in capability mode). */
int		nvrm_device_refresh(nvrm_device *dev);

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

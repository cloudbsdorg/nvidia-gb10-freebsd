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
} nvrm_backend_ops;

/* Registry. */
int	nvrm_backend_register(const nvrm_backend_ops *ops);
const nvrm_backend_ops *nvrm_backend_select(const char *name);
void	nvrm_registry_reset(void);	/* tests: drop every provider */
void	nvrm_registry_builtin(void);	/* the two built-in providers */
unsigned nvrm_registry_count(void);	/* tests: providers registered */
/* Test seam: runs between the two built-in registrations. */
extern void (*nvrm_registry_pause_hook)(void);
extern const nvrm_backend_ops nvrm_backend_rm_ops;
extern const nvrm_backend_ops nvrm_backend_fake_ops;
/* Test seam: stands in for getpid() where the RM backend asks who owns a
 * descriptor; NULL = the real one. */
extern pid_t (*nvrm_getpid_hook)(void);
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

/* Capsicum helper shared by the backends (nvrm_cap.c). */
int	nvrm_cap_limit_fd(int fd, const unsigned long *cmds, unsigned ncmds);

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

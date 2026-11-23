/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * nvrm_fake.c - the fake backend (NVRM_BACKEND=fake): same ops as the RM
 * backend, over synthetic data, for the hardware-free test suite and for CI
 * on machines without a GPU.  The profiles are made-up examples shaped like
 * parts we have seen; they are not measurements.
 *
 * Environment:
 *   NVRM_FAKE_PROFILE  comma list of profiles, one GPU each (default
 *                      "discrete"): discrete, unified, untabled, unknown, sparse
 *   NVRM_FAKE_FAIL     open, version, list, gpu_open, limit: make that step
 *                      fail, so callers' error paths run without hardware;
 *                      nogpu: list no GPU (a success with zero devices).
 *
 * Every query makes one real ioctl round trip on a descriptor the backend
 * owns, so the Capsicum limits (rights and the ioctl allow list) are
 * exercised exactly like the RM backend's.
 */
#include <sys/types.h>
#include <sys/filio.h>
#include <sys/ioctl.h>

#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "nvrm_internal.h"
#include "nvrm_fake.h"

#define NO_REASON	0

typedef struct fake_profile {
	const char	*name;
	uint64_t	val[NVRM_P_COUNT];
	uint64_t	tpc_mask[NVRM_MAX_GPCS];
	int		fail[NVRM_P_COUNT];	/* reason, or 0 */
	const char	*uuid;
	const char	*vbios;
	const char	*gsp_firmware;
	int		sfail[NVRM_SP_COUNT];
	const uint32_t	*classes;
	unsigned	nclasses;
	int		classes_fail;
} fake_profile;

static const uint32_t classes_b[] = { 0x0080, 0x2080, 0xcec0, 0xce97, 0xcab5,
    0xca6f };
static const uint32_t classes_unknown[] = { 0x0080, 0x2080, 0x1234, 0x5678 };

#define PCI(dom, bus, slot, ven, dev, sven, sdev, rev) \
	[NVRM_P_PCI_DOMAIN] = (dom), [NVRM_P_PCI_BUS] = (bus), \
	[NVRM_P_PCI_SLOT] = (slot), [NVRM_P_PCI_FUNCTION] = 0, \
	[NVRM_P_PCI_VENDOR] = (ven), [NVRM_P_PCI_DEVICE] = (dev), \
	[NVRM_P_PCI_SUBSYSTEM_VENDOR] = (sven), \
	[NVRM_P_PCI_SUBSYSTEM_DEVICE] = (sdev), [NVRM_P_PCI_REVISION] = (rev)

/* CPD-OFF -- profile data: tables of synthetic values, one row per property */
static fake_profile profiles[] = {
	{
		.name = "discrete",
		.val = {
			PCI(0, 13, 0, 0x10de, 0x2d04, 0x1462, 0x5351, 0xa1),
			[NVRM_P_ARCHITECTURE] = 0x1b0,
			[NVRM_P_IMPLEMENTATION] = 6,
			[NVRM_P_SM_VERSION] = 0x0a04,
			[NVRM_P_SM_PER_TPC] = 2,
			[NVRM_P_GPC_MASK] = 0x7,
			[NVRM_P_VRAM_KB] = 16ULL * 1024 * 1024,
			[NVRM_P_BAR1_KB] = 16ULL * 1024 * 1024,
			[NVRM_P_MAX_PAGE_SIZE] = 512ULL << 20,
			[NVRM_P_CAP_DMABUF] = 1,
			[NVRM_P_CAP_DISPLAY] = 1,
		},
		.tpc_mask = { 0x3f, 0x3f, 0x3f },
		.fail = { [NVRM_P_NUMA_NODE] = NVRM_R_NO_NUMA,
		    [NVRM_P_CAP_OS_DEVICE_WC] = NVRM_R_OS_NOT_REPORTED },
		.uuid = "GPU-00000000-0000-4000-8000-0000000000a1",
		.vbios = "96.06.1e.00.4a",
		.gsp_firmware = "580.178.04",
		.classes = classes_b,
		.nclasses = sizeof(classes_b) / sizeof(classes_b[0]),
	},
	{
		.name = "unified",
		.val = {
			PCI(0, 1, 0, 0x10de, 0x2e12, 0x10de, 0x0000, 0xa1),
			[NVRM_P_ARCHITECTURE] = 0x1b0,
			[NVRM_P_IMPLEMENTATION] = 0xb,
			[NVRM_P_SM_VERSION] = 0x0c01,
			[NVRM_P_SM_PER_TPC] = 2,
			[NVRM_P_GPC_MASK] = 0x3,
			[NVRM_P_VRAM_KB] = 0,
			[NVRM_P_BAR1_KB] = 0,
			[NVRM_P_MAX_PAGE_SIZE] = 2ULL << 20,
			[NVRM_P_NUMA_NODE] = 0,
			[NVRM_P_CAP_DMABUF] = 1,
			[NVRM_P_CAP_SOC] = 1,
			[NVRM_P_CAP_COHERENT_MEMORY] = 1,
			[NVRM_P_CAP_OS_DEVICE_WC] = 1,
		},
		.tpc_mask = { 0x1ff, 0xff },
		.uuid = "GPU-00000000-0000-4000-8000-0000000000b2",
		.vbios = "97.06.1e.00.4a",
		.gsp_firmware = "580.178.04",
		.classes = classes_b,
		.nclasses = sizeof(classes_b) / sizeof(classes_b[0]),
	},
	{
		/* GB20C: architecture and implementation known, no compute table
		 * row, so compute capability is family_unknown. */
		.name = "untabled",
		.val = {
			PCI(0, 2, 0, 0x10de, 0x2e13, 0x10de, 0x0000, 0xa1),
			[NVRM_P_ARCHITECTURE] = 0x1b0,
			[NVRM_P_IMPLEMENTATION] = 0xc,
			[NVRM_P_SM_VERSION] = 0x0a04,
			[NVRM_P_SM_PER_TPC] = 2,
			[NVRM_P_GPC_MASK] = 0x1,
			[NVRM_P_MAX_PAGE_SIZE] = 2ULL << 20,
		},
		.tpc_mask = { 0x1 },
		.uuid = "GPU-00000000-0000-4000-8000-0000000000c2",
		.classes = classes_b,
		.nclasses = sizeof(classes_b) / sizeof(classes_b[0]),
	},
	{
		/* A GPU the generation table does not know. */
		.name = "unknown",
		.val = {
			PCI(0, 14, 0, 0x10de, 0x9999, 0x10de, 0x0001, 0x01),
			[NVRM_P_ARCHITECTURE] = 0xfff0,
			[NVRM_P_IMPLEMENTATION] = 1,
			[NVRM_P_SM_VERSION] = 0x0d02,
			[NVRM_P_SM_PER_TPC] = 1,
			[NVRM_P_GPC_MASK] = 0x1,
			[NVRM_P_VRAM_KB] = 1024,
			[NVRM_P_BAR1_KB] = 256 * 1024,
			[NVRM_P_MAX_PAGE_SIZE] = 64ULL << 10,
		},
		.tpc_mask = { 0x1 },
		.uuid = "GPU-00000000-0000-4000-8000-0000000000c3",
		.classes = classes_unknown,
		.nclasses = sizeof(classes_unknown) / sizeof(classes_unknown[0]),
	},
	{
		/* Everything optional is missing: the reasons are the output. */
		.name = "sparse",
		.val = { 0 },
		.fail = {
			[NVRM_P_PCI_DOMAIN] = NVRM_R_OS_NOT_REPORTED,
			[NVRM_P_PCI_BUS] = NVRM_R_OS_NOT_REPORTED,
			[NVRM_P_PCI_SLOT] = NVRM_R_OS_NOT_REPORTED,
			[NVRM_P_PCI_FUNCTION] = NVRM_R_OS_NOT_REPORTED,
			[NVRM_P_PCI_VENDOR] = NVRM_R_OS_NOT_REPORTED,
			[NVRM_P_PCI_DEVICE] = NVRM_R_OS_NOT_REPORTED,
			[NVRM_P_PCI_SUBSYSTEM_VENDOR] = NVRM_R_RM_FAILED,
			[NVRM_P_PCI_SUBSYSTEM_DEVICE] = NVRM_R_RM_FAILED,
			[NVRM_P_PCI_REVISION] = NVRM_R_RM_FAILED,
			[NVRM_P_ARCHITECTURE] = NVRM_R_RM_FAILED,
			[NVRM_P_IMPLEMENTATION] = NVRM_R_RM_FAILED,
			[NVRM_P_SM_VERSION] = NVRM_R_RM_UNSUPPORTED,
			[NVRM_P_SM_PER_TPC] = NVRM_R_RM_FAILED,
			[NVRM_P_GPC_MASK] = NVRM_R_RM_FAILED,
			[NVRM_P_TPC_MASK] = NVRM_R_RM_FAILED,
			[NVRM_P_VRAM_KB] = NVRM_R_RM_FAILED,
			[NVRM_P_BAR1_KB] = NVRM_R_RM_FAILED,
			[NVRM_P_MAX_PAGE_SIZE] = NVRM_R_RM_UNSUPPORTED,
			[NVRM_P_NUMA_NODE] = NVRM_R_NO_NUMA,
			[NVRM_P_CAP_DMABUF] = NVRM_R_BACKEND_NONE,
			[NVRM_P_CAP_ATS] = NVRM_R_BACKEND_NONE,
			[NVRM_P_CAP_SELF_HOSTED] = NVRM_R_BACKEND_NONE,
			[NVRM_P_CAP_DISPLAY] = NVRM_R_BACKEND_NONE,
			[NVRM_P_CAP_SOC] = NVRM_R_BACKEND_NONE,
			[NVRM_P_CAP_COHERENT_MEMORY] = NVRM_R_BACKEND_NONE,
			[NVRM_P_CAP_OS_DEVICE_WC] = NVRM_R_BACKEND_NONE,
		},
		.uuid = NULL,
		.sfail = {
			[NVRM_SP_GSP_FIRMWARE] = NVRM_R_RM_UNSUPPORTED,
		},
		.classes = NULL, .nclasses = 0,
		.classes_fail = NVRM_R_RM_FAILED,
	},
};
/* CPD-ON */
#define NPROFILES	(sizeof(profiles) / sizeof(profiles[0]))

/* Per-run injection for the tests (property reasons override the profile). */
static int inject_fail[NVRM_P_COUNT];
static int inject_tpc_fail_gpc = -1;
static int inject_uuid_fail;
static int inject_str_fail[NVRM_SP_COUNT];
static int inject_has_val[NVRM_P_COUNT];
static uint64_t inject_val[NVRM_P_COUNT];
static int last_fd = -1;
static const uint32_t *inject_classes;
static unsigned inject_nclasses;
static int inject_classes_fail;

void
nvrm_fake_inject(int prop, int reason)
{
	inject_fail[prop] = reason;
}

void
nvrm_fake_inject_value(int prop, uint64_t value)
{
	inject_has_val[prop] = 1;
	inject_val[prop] = value;
}

void
nvrm_fake_inject_tpc_fail(int gpc)
{
	inject_tpc_fail_gpc = gpc;
}

void
nvrm_fake_inject_uuid_fail(int reason)
{
	inject_uuid_fail = reason;
}

void
nvrm_fake_inject_str_fail(int prop, int reason)
{
	inject_str_fail[prop] = reason;
}

void
nvrm_fake_inject_classes(const uint32_t *list, unsigned n)
{
	inject_classes = list;
	inject_nclasses = n;
}

void
nvrm_fake_inject_classes_fail(int reason)
{
	inject_classes_fail = reason;
}

void
nvrm_fake_inject_clear(void)
{
	inject_classes_fail = 0;
	inject_classes = NULL;
	inject_nclasses = 0;
	memset(inject_fail, 0, sizeof(inject_fail));
	memset(inject_has_val, 0, sizeof(inject_has_val));
	inject_tpc_fail_gpc = -1;
	inject_uuid_fail = 0;
	memset(inject_str_fail, 0, sizeof(inject_str_fail));
}

int
nvrm_fake_fd(void)
{
	return (last_fd);
}

struct nvrm_backend {
	int		fd;
	const char	*fail;		/* NVRM_FAKE_FAIL, or "" */
	unsigned	nprofiles;
	const fake_profile *sel[NVRM_MAX_GPUS];
};

struct nvrm_gpu {
	nvrm_backend		*be;
	const fake_profile	*p;
	uint32_t		id;
};

static int
fake_probe(void)
{
	return (0);	/* only ever chosen by name */
}

static int
fake_open(nvrm_backend **bep, char *err, size_t errlen)
{
	nvrm_backend *be;
	const char *env, *p, *q;
	int pfd[2];
	size_t len;
	unsigned i;

	*bep = NULL;
	be = NVRM_CALLOC(1, sizeof(*be));
	if (be == NULL) {
		snprintf(err, errlen, "out of memory");
		return (NVRM_E_NOMEM);
	}
	env = getenv("NVRM_FAKE_FAIL");
	be->fail = env != NULL ? env : "";
	if (strcmp(be->fail, "open") == 0) {
		snprintf(err, errlen, "fake backend: open failed (injected)");
		free(be);
		return (NVRM_E_OPEN);
	}
	if (strcmp(be->fail, "version") == 0) {
		snprintf(err, errlen, "fake backend: version mismatch "
		    "(injected): module 0.0.0, libnvrm built for %s",
		    NVRM_RM_VERSION);
		free(be);
		return (NVRM_E_VERSION);
	}
	env = getenv("NVRM_FAKE_PROFILE");
	p = env != NULL && env[0] != '\0' ? env : "discrete";
	while (*p != '\0') {
		q = strchr(p, ',');
		len = q != NULL ? (size_t)(q - p) : strlen(p);
		for (i = 0; i < NPROFILES; i++)
			if (strlen(profiles[i].name) == len &&
			    strncmp(profiles[i].name, p, len) == 0)
				break;
		if (i == NPROFILES) {
			snprintf(err, errlen, "fake backend: unknown profile "
			    "\"%.*s\" in NVRM_FAKE_PROFILE (known: discrete, "
			    "unified, untabled, unknown, sparse)", (int)len, p);
			free(be);
			return (NVRM_E_INVAL);
		}
		if (be->nprofiles == NVRM_MAX_GPUS) {
			snprintf(err, errlen, "fake backend: NVRM_FAKE_PROFILE "
			    "lists more than %d GPUs", NVRM_MAX_GPUS);
			free(be);
			return (NVRM_E_INVAL);
		}
		be->sel[be->nprofiles++] = &profiles[i];
		p += len;
		if (*p == ',')
			p++;
	}
	if (pipe2(pfd, O_CLOEXEC) != 0) {
		snprintf(err, errlen, "fake backend: pipe2 failed");
		free(be);
		return (NVRM_E_OPEN);
	}
	close(pfd[1]);
	be->fd = pfd[0];
	last_fd = be->fd;
	*bep = be;
	return (NVRM_OK);
}

static void
fake_close(nvrm_backend *be)
{
	close(be->fd);
	last_fd = -1;
	free(be);
}

static void
fake_running_version(nvrm_backend *be, nvrm_str *out)
{
	(void)be;
	snprintf(out->value, sizeof(out->value), "%s", NVRM_RM_VERSION);
	out->reason = NVRM_R_NONE;
	out->source = NVRM_S_OS;
}

static void
fake_parsed_version(nvrm_backend *be, nvrm_version *out)
{
	(void)be;
	(void)nvrm_version_parse(NVRM_RM_VERSION, 10, out);
}

static int
fake_list_gpus(nvrm_backend *be, uint32_t *ids, unsigned max, unsigned *n,
    char *err, size_t errlen)
{
	unsigned i;

	if (strcmp(be->fail, "list") == 0) {
		snprintf(err, errlen, "fake backend: listing failed (injected)");
		return (NVRM_E_IO);
	}
	*n = 0;
	if (strcmp(be->fail, "nogpu") == 0)
		return (NVRM_OK);
	for (i = 0; i < be->nprofiles && i < max; i++)
		ids[(*n)++] = ((i + 1) << 8) | (uint32_t)(be->sel[i] - profiles);
	return (NVRM_OK);
}

static int
fake_gpu_open(nvrm_backend *be, uint32_t id, nvrm_gpu **gpu, char *err,
    size_t errlen)
{
	nvrm_gpu *g;

	if (strcmp(be->fail, "gpu_open") == 0) {
		snprintf(err, errlen, "fake backend: attaching the GPU "
		    "failed (injected)");
		return (NVRM_E_IO);
	}
	g = NVRM_CALLOC(1, sizeof(*g));
	if (g == NULL) {
		snprintf(err, errlen, "out of memory");
		return (NVRM_E_NOMEM);
	}
	g->be = be;
	g->id = id;
	g->p = &profiles[id & 0xff];
	*gpu = g;
	return (NVRM_OK);
}

static void
fake_gpu_close(nvrm_gpu *g)
{
	free(g);
}

/* One real ioctl on the owned descriptor: the Capsicum canary. */
static int
roundtrip(nvrm_gpu *g)
{
	int n;

	return (ioctl(g->be->fd, FIONREAD, &n) == 0 ? 0 : NVRM_R_OS_CALL_FAILED);
}

static int
fake_gpu_u64(nvrm_gpu *g, enum nvrm_prop p, uint32_t arg, uint64_t *out)
{
	const fake_profile *fp = g->p;

	if (roundtrip(g) != 0)
		return (NVRM_R_OS_CALL_FAILED);
	if (inject_fail[p] != 0)
		return (inject_fail[p]);
	if (fp->fail[p] != 0)
		return (fp->fail[p]);
	if (p == NVRM_P_RM_GPU_ID) {
		*out = g->id;
		return (0);
	}
	if (p == NVRM_P_TPC_MASK) {
		if (arg >= NVRM_MAX_GPCS || (int)arg == inject_tpc_fail_gpc)
			return (NVRM_R_RM_FAILED);
		*out = fp->tpc_mask[arg];
		return (0);
	}
	*out = inject_has_val[p] ? inject_val[p] : fp->val[p];
	return (0);
}

static int
fake_gpu_str(nvrm_gpu *g, enum nvrm_sprop p, char *buf, size_t len)
{
	const char *value;

	buf[0] = '\0';
	if (roundtrip(g) != 0)
		return (NVRM_R_OS_CALL_FAILED);
	switch (p) {
	case NVRM_SP_UUID:
		value = g->p->uuid;
		break;
	case NVRM_SP_VBIOS:
		value = g->p->vbios;
		break;
	case NVRM_SP_GSP_FIRMWARE:
		value = g->p->gsp_firmware;
		break;
	default:
		return (NVRM_R_BACKEND_NONE);
	}
	if (p == NVRM_SP_UUID && inject_uuid_fail != 0)
		return (inject_uuid_fail);
	if (inject_str_fail[p] != 0)
		return (inject_str_fail[p]);
	if (g->p->sfail[p] != 0)
		return (g->p->sfail[p]);
	if (value == NULL)
		return (NVRM_R_RM_FAILED);
	snprintf(buf, len, "%s", value);
	return (0);
}

static int
fake_gpu_classes(nvrm_gpu *g, uint32_t *list, unsigned max, unsigned *n)
{
	const uint32_t *cls;
	unsigned i, nc;

	if (roundtrip(g) != 0)
		return (NVRM_R_OS_CALL_FAILED);
	if (inject_classes_fail != 0)
		return (inject_classes_fail);
	if (g->p->classes_fail != 0 && inject_classes == NULL)
		return (g->p->classes_fail);
	cls = inject_classes != NULL ? inject_classes : g->p->classes;
	nc = inject_classes != NULL ? inject_nclasses : g->p->nclasses;
	*n = 0;
	for (i = 0; i < nc && i < max; i++)
		list[(*n)++] = cls[i];
	return (0);
}

uint64_t
nvrm_fake_gpu_vram_kb(const nvrm_gpu *g)
{
	return (g->p->fail[NVRM_P_VRAM_KB] != 0 ? 0 :
	    g->p->val[NVRM_P_VRAM_KB]);
}

uint32_t
nvrm_fake_gpu_id(const nvrm_gpu *g)
{
	return (g->id);
}

static int
fake_limit(nvrm_backend *be, int allow_alloc)
{
	static const unsigned long cmds[] = { FIONREAD };

	if (strcmp(be->fail, "limit") == 0)
		return (NVRM_E_CAPSICUM);
	return (nvrm_cap_limit_fd(be->fd, cmds, 1));
}

const nvrm_backend_ops nvrm_backend_fake_ops = {
	.name = "fake",
	.score = 0,
	.probe = fake_probe,
	.open = fake_open,
	.close = fake_close,
	.running_version = fake_running_version,
	.driver_version = fake_parsed_version,
	.rm_api_version = fake_parsed_version,
	.list_gpus = fake_list_gpus,
	.gpu_open = fake_gpu_open,
	.gpu_close = fake_gpu_close,
	.gpu_u64 = fake_gpu_u64,
	.gpu_str = fake_gpu_str,
	.gpu_classes = fake_gpu_classes,
	.limit = fake_limit,
	.mem = &nvrm_fake_mem_ops,
};

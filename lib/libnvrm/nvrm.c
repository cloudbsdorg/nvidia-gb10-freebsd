/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * nvrm.c - the core: backend registry, enumeration, and the layered device
 * model (abstract device, class, family, board decorators).  Nothing here
 * names a chip or a vendor's board: the generation table and the decorator
 * table (nvrm_table.c) hold the data.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "nvrm_internal.h"

/* ---- registry ---------------------------------------------------------- */

#define MAX_BACKENDS	8

static const nvrm_backend_ops *registry[MAX_BACKENDS];
static unsigned nregistered;
static int builtins_done;
int (*nvrm_issetugid_hook)(void);

int
nvrm_backend_register(const nvrm_backend_ops *ops)
{
	if (nregistered == MAX_BACKENDS)
		return (NVRM_E_INVAL);
	registry[nregistered++] = ops;
	return (NVRM_OK);
}

void
nvrm_registry_reset(void)
{
	nregistered = 0;
	builtins_done = 1;	/* a reset registry stays empty until filled */
}

void
nvrm_registry_builtin(void)
{
	nvrm_backend_register(&nvrm_backend_rm_ops);
	nvrm_backend_register(&nvrm_backend_fake_ops);
	builtins_done = 1;
}

const nvrm_backend_ops *
nvrm_backend_select(const char *name)
{
	const nvrm_backend_ops *best = NULL;
	unsigned i;

	if (!builtins_done)
		nvrm_registry_builtin();
	for (i = 0; i < nregistered; i++) {
		if (name != NULL) {
			if (strcmp(registry[i]->name, name) == 0)
				return (registry[i]);
			continue;
		}
		if (!registry[i]->probe())
			continue;
		if (best == NULL || registry[i]->score > best->score)
			best = registry[i];
	}
	return (best);
}

/* ---- context ----------------------------------------------------------- */

static void
set_err(char *err, size_t errlen, const char *msg)
{
	if (err != NULL && errlen > 0)
		snprintf(err, errlen, "%s", msg);
}

/* ---- the layered device model ----------------------------------------- */

static void
unavail(nvrm_u64 *f, int reason, int source)
{
	f->value = 0;
	f->reason = reason;
	f->source = source;
}

static void
avail(nvrm_u64 *f, uint64_t value, int source)
{
	f->value = value;
	f->reason = NVRM_R_NONE;
	f->source = source;
}

void
nvrm_info_init(nvrm_device_info *info)
{
	unsigned i;

	memset(info, 0, sizeof(*info));
	for (i = 0; i < nvrm_nfields; i++)
		*nvrm_field_reason(info, &nvrm_fields[i]) = NVRM_R_NOT_QUERIED;
	for (i = 0; i < NVRM_NCAPS; i++)
		info->caps[i].reason = NVRM_R_NOT_QUERIED;
}

/* CPD-OFF -- a table of one entry per property, like the fake's profile data */
static const int prop_source[NVRM_P_COUNT] = {
	[NVRM_P_PCI_DOMAIN] = NVRM_S_OS,
	[NVRM_P_PCI_BUS] = NVRM_S_OS,
	[NVRM_P_PCI_SLOT] = NVRM_S_OS,
	[NVRM_P_PCI_FUNCTION] = NVRM_S_OS,
	[NVRM_P_PCI_VENDOR] = NVRM_S_OS,
	[NVRM_P_PCI_DEVICE] = NVRM_S_OS,
	[NVRM_P_PCI_SUBSYSTEM_VENDOR] = NVRM_S_RM,
	[NVRM_P_PCI_SUBSYSTEM_DEVICE] = NVRM_S_RM,
	[NVRM_P_PCI_REVISION] = NVRM_S_RM,
	[NVRM_P_RM_GPU_ID] = NVRM_S_OS,
	[NVRM_P_ARCHITECTURE] = NVRM_S_RM,
	[NVRM_P_IMPLEMENTATION] = NVRM_S_RM,
	[NVRM_P_SM_VERSION] = NVRM_S_RM,
	[NVRM_P_SM_PER_TPC] = NVRM_S_RM,
	[NVRM_P_GPC_MASK] = NVRM_S_RM,
	[NVRM_P_TPC_MASK] = NVRM_S_RM,
	[NVRM_P_VRAM_KB] = NVRM_S_RM,
	[NVRM_P_BAR1_KB] = NVRM_S_RM,
	[NVRM_P_MAX_PAGE_SIZE] = NVRM_S_RM,
	[NVRM_P_NUMA_NODE] = NVRM_S_RM,
	[NVRM_P_CAP_DMABUF] = NVRM_S_RM,
	[NVRM_P_CAP_ATS] = NVRM_S_RM,
	[NVRM_P_CAP_SELF_HOSTED] = NVRM_S_RM,
	[NVRM_P_CAP_DISPLAY] = NVRM_S_RM,
	[NVRM_P_CAP_SOC] = NVRM_S_RM,
	[NVRM_P_CAP_COHERENT_MEMORY] = NVRM_S_RM,
	[NVRM_P_CAP_OS_DEVICE_WC] = NVRM_S_OS,
};
/* CPD-ON */

static void
get_u64(const nvrm_backend_ops *ops, nvrm_gpu *g, nvrm_u64 *f,
    enum nvrm_prop p, uint32_t arg, uint64_t scale)
{
	uint64_t v;
	int r;

	r = ops->gpu_u64(g, p, arg, &v);
	if (r != 0)
		unavail(f, r, prop_source[p]);
	else
		avail(f, v * scale, prop_source[p]);
}

/* Layer 0, the abstract device: identity. */
static void
query_identity(const nvrm_backend_ops *ops, nvrm_gpu *g,
    nvrm_device_info *info)
{
	int r;

	get_u64(ops, g, &info->pci_domain, NVRM_P_PCI_DOMAIN, 0, 1);
	get_u64(ops, g, &info->pci_bus, NVRM_P_PCI_BUS, 0, 1);
	get_u64(ops, g, &info->pci_slot, NVRM_P_PCI_SLOT, 0, 1);
	get_u64(ops, g, &info->pci_function, NVRM_P_PCI_FUNCTION, 0, 1);
	get_u64(ops, g, &info->pci_vendor, NVRM_P_PCI_VENDOR, 0, 1);
	get_u64(ops, g, &info->pci_device, NVRM_P_PCI_DEVICE, 0, 1);
	get_u64(ops, g, &info->pci_subsystem_vendor,
	    NVRM_P_PCI_SUBSYSTEM_VENDOR, 0, 1);
	get_u64(ops, g, &info->pci_subsystem_device,
	    NVRM_P_PCI_SUBSYSTEM_DEVICE, 0, 1);
	get_u64(ops, g, &info->pci_revision, NVRM_P_PCI_REVISION, 0, 1);
	get_u64(ops, g, &info->rm_gpu_id, NVRM_P_RM_GPU_ID, 0, 1);
	r = ops->gpu_str(g, NVRM_SP_UUID, info->uuid.value,
	    sizeof(info->uuid.value));
	info->uuid.reason = r;
	info->uuid.source = NVRM_S_RM;
}

/* Layer 1, the gpu class: what any compute or graphics GPU reports. */
static void
query_gpu_class(const nvrm_backend_ops *ops, nvrm_gpu *g,
    nvrm_device_info *info)
{
	uint64_t mask, tpc_mask;
	uint32_t ids[NVRM_MAX_CLASSES];
	unsigned n, gpc, tpcs, k;
	nvrm_u64 raw_sm;
	int r, bad;

	get_u64(ops, g, &info->architecture, NVRM_P_ARCHITECTURE, 0, 1);
	get_u64(ops, g, &info->implementation, NVRM_P_IMPLEMENTATION, 0, 1);
	if (NVRM_HAVE(info->architecture) && NVRM_HAVE(info->implementation))
		avail(&info->chip_id, info->architecture.value +
		    info->implementation.value, NVRM_S_DERIVED);
	else
		unavail(&info->chip_id, NVRM_R_INPUT_MISSING, NVRM_S_DERIVED);

	get_u64(ops, g, &raw_sm, NVRM_P_SM_VERSION, 0, 1);
	if (NVRM_HAVE(raw_sm) && raw_sm.value == 0)
		unavail(&raw_sm, NVRM_R_RM_UNSUPPORTED, NVRM_S_RM);
	info->sm_version_major = raw_sm;
	info->sm_version_minor = raw_sm;
	info->sm_version_major.value >>= 8;
	info->sm_version_minor.value &= 0xff;

	/* GPC, TPC and SM counts from the enabled-unit masks. */
	r = ops->gpu_u64(g, NVRM_P_GPC_MASK, 0, &mask);
	if (r == 0 && (mask >> NVRM_MAX_GPCS) != 0)
		r = NVRM_R_VALUE_UNUSABLE; /* more GPCs than the TPC walk covers */
	if (r != 0) {
		unavail(&info->gpc_count, r, NVRM_S_RM);
		unavail(&info->tpc_count, NVRM_R_INPUT_MISSING, NVRM_S_DERIVED);
		unavail(&info->sm_count, NVRM_R_INPUT_MISSING, NVRM_S_DERIVED);
	} else {
		avail(&info->gpc_count, __builtin_popcountll(mask), NVRM_S_RM);
		tpcs = 0;
		bad = 0;
		for (gpc = 0; gpc < NVRM_MAX_GPCS; gpc++) {
			if ((mask & (1ULL << gpc)) == 0)
				continue;
			r = ops->gpu_u64(g, NVRM_P_TPC_MASK, gpc, &tpc_mask);
			if (r != 0) {
				bad = r;
				break;
			}
			tpcs += __builtin_popcountll(tpc_mask);
		}
		if (bad != 0) {
			unavail(&info->tpc_count, bad, NVRM_S_RM);
			unavail(&info->sm_count, NVRM_R_INPUT_MISSING,
			    NVRM_S_DERIVED);
		} else {
			uint64_t per_tpc;

			avail(&info->tpc_count, tpcs, NVRM_S_RM);
			r = ops->gpu_u64(g, NVRM_P_SM_PER_TPC, 0, &per_tpc);
			if (r != 0)
				unavail(&info->sm_count, r, NVRM_S_RM);
			else
				avail(&info->sm_count, tpcs * per_tpc,
				    NVRM_S_DERIVED);
		}
	}

	/* The class list. */
	info->classes.source = NVRM_S_RM;
	info->classes.count = 0;
	r = ops->gpu_classes(g, ids, NVRM_MAX_CLASSES, &n);
	info->classes.reason = r;
	if (r == 0) {
		info->classes.count = n;
		for (k = 0; k < n; k++)
			info->classes.value[k] = ids[k];
	}
}

static int
class_listed(const nvrm_list *classes, uint32_t cls)
{
	uint32_t i;

	for (i = 0; i < classes->count; i++)
		if (classes->value[i] == cls)
			return (1);
	return (0);
}

const nvrm_family *
nvrm_family_match(const nvrm_family *table, unsigned n,
    const uint64_t *classes, uint32_t nclasses)
{
	unsigned i;
	uint32_t j;
	int gpfifo, compute;

	for (i = 0; i < n; i++) {
		gpfifo = compute = 0;
		for (j = 0; j < nclasses; j++) {
			if (classes[j] == table[i].cls_gpfifo)
				gpfifo = 1;
			if (classes[j] == table[i].cls_compute)
				compute = 1;
		}
		if (gpfifo && compute)
			return (&table[i]);
	}
	return (NULL);
}

static void
family_class(nvrm_u64 *f, const nvrm_device_info *info, uint32_t cls)
{
	if (cls == 0)
		unavail(f, NVRM_R_FAMILY_NO_CLASS, NVRM_S_FAMILY);
	else if (!class_listed(&info->classes, cls))
		unavail(f, NVRM_R_CLASS_ABSENT, NVRM_S_FAMILY);
	else
		avail(f, cls, NVRM_S_FAMILY);
}

/* Layer 2, the family: values only the generation table knows. */
void
nvrm_apply_family(nvrm_device_info *info, const nvrm_family *table,
    unsigned n)
{
	const nvrm_family *fam = NULL;
	int reason;
	unsigned i, k;

	if (!NVRM_HAVE(info->classes))
		reason = NVRM_R_INPUT_MISSING;
	else {
		fam = nvrm_family_match(table, n, info->classes.value,
		    info->classes.count);
		reason = NVRM_R_FAMILY_UNKNOWN;
	}

	info->family.source = NVRM_S_FAMILY;
	info->page_sizes.source = NVRM_S_FAMILY;
	info->page_sizes.count = 0;
	if (fam == NULL) {
		info->family.reason = reason;
		info->family.value[0] = '\0';
		unavail(&info->cls_gpfifo, reason, NVRM_S_FAMILY);
		unavail(&info->cls_compute, reason, NVRM_S_FAMILY);
		unavail(&info->cls_eng3d, reason, NVRM_S_FAMILY);
		unavail(&info->cls_copy, reason, NVRM_S_FAMILY);
		info->page_sizes.reason = reason;
		return;
	}
	info->family.reason = NVRM_R_NONE;
	snprintf(info->family.value, sizeof(info->family.value), "%s",
	    fam->name);
	family_class(&info->cls_gpfifo, info, fam->cls_gpfifo);
	family_class(&info->cls_compute, info, fam->cls_compute);
	family_class(&info->cls_eng3d, info, fam->cls_eng3d);
	family_class(&info->cls_copy, info, fam->cls_copy);

	/* Page sizes: the row's sizes, capped by what the RM says is usable. */
	if (!NVRM_HAVE(info->max_page_size)) {
		info->page_sizes.reason = NVRM_R_INPUT_MISSING;
		return;
	}
	info->page_sizes.reason = NVRM_R_NONE;
	for (i = 0, k = 0; i < NVRM_MAX_PAGE_SIZES && fam->page_sizes[i] != 0;
	    i++)
		if (fam->page_sizes[i] <= info->max_page_size.value)
			info->page_sizes.value[k++] = fam->page_sizes[i];
	info->page_sizes.count = k;
}

/* Layer 3, board decorators: options only, never support. */
void
nvrm_apply_decorators(nvrm_device_info *info, const nvrm_decorator *table)
{
	const nvrm_decorator *d;
	unsigned i;

	info->ndecorators = 0;
	if (!NVRM_HAVE(info->pci_subsystem_vendor) ||
	    !NVRM_HAVE(info->pci_subsystem_device))
		return;
	for (d = table; d->name != NULL; d++) {
		if (d->subsystem_vendor != info->pci_subsystem_vendor.value ||
		    d->subsystem_device != info->pci_subsystem_device.value)
			continue;
		if (info->ndecorators == NVRM_MAX_DECORATORS)
			break;
		info->decorators[info->ndecorators++] = d->name;
		for (i = 0; i < NVRM_NCAPS && d->caps[i].index >= 0; i++) {
			if ((unsigned)d->caps[i].index >= NVRM_NCAPS)
				continue;	/* a bad row must not write past caps[] */
			avail(&info->caps[d->caps[i].index],
			    d->caps[i].value != 0, NVRM_S_BOARD);
		}
	}
}

void
nvrm_query_device(const nvrm_backend_ops *ops, nvrm_gpu *g,
    nvrm_device_info *info)
{
	unsigned i;

	nvrm_info_init(info);
	query_identity(ops, g, info);
	query_gpu_class(ops, g, info);

	get_u64(ops, g, &info->vram_size, NVRM_P_VRAM_KB, 0, 1024);
	get_u64(ops, g, &info->bar1_size, NVRM_P_BAR1_KB, 0, 1024);
	get_u64(ops, g, &info->max_page_size, NVRM_P_MAX_PAGE_SIZE, 0, 1);
	get_u64(ops, g, &info->numa_node, NVRM_P_NUMA_NODE, 0, 1);
	for (i = 0; i < NVRM_NCAPS; i++)
		get_u64(ops, g, &info->caps[i], NVRM_P_CAP_DMABUF + i, 0, 1);

	nvrm_apply_family(info, nvrm_family_table, nvrm_family_count);
	nvrm_apply_decorators(info, nvrm_decorator_table);
}

/* ---- enumeration ------------------------------------------------------- */

/* 1 when any value failed because the system call itself failed. */
static int
info_has_call_failure(nvrm_device_info *info)
{
	unsigned i;

	for (i = 0; i < nvrm_nfields; i++)
		if (*nvrm_field_reason(info, &nvrm_fields[i]) ==
		    NVRM_R_OS_CALL_FAILED)
			return (1);
	for (i = 0; i < NVRM_NCAPS; i++)
		if (info->caps[i].reason == NVRM_R_OS_CALL_FAILED)
			return (1);
	return (0);
}

static void
free_ctx(nvrm_ctx *ctx)
{
	unsigned i;

	for (i = 0; i < ctx->ndev; i++)
		ctx->ops->gpu_close(ctx->dev[i].gpu);
	ctx->ops->close(ctx->be);
	free(ctx);
}

/* The backend named by the options, else NVRM_BACKEND (not in a set-id
 * process), else the best usable one.  NULL, with err set, when none. */
static const nvrm_backend_ops *
choose_backend(const nvrm_enum_opts *opts, char *err, size_t errlen)
{
	const nvrm_backend_ops *ops;
	const char *name;
	int tainted;

	name = opts != NULL ? opts->backend : NULL;
	if (name == NULL) {
		tainted = nvrm_issetugid_hook != NULL ?
		    nvrm_issetugid_hook() : issetugid();
		if (!tainted)
			name = getenv("NVRM_BACKEND");
	}
	if (name != NULL && name[0] == '\0')
		name = NULL;
	ops = nvrm_backend_select(name);
	if (ops == NULL)
		set_err(err, errlen, name != NULL ?
		    "no such backend (known: rm, fake)" :
		    "no usable backend: /dev/nvidiactl is missing, so the "
		    "NVIDIA kernel module is not loaded (kldload nvidia); for "
		    "tests without hardware select the fake backend "
		    "(opts->backend = \"fake\", or NVRM_BACKEND=fake unless "
		    "the process is set-user-ID)");
	return (ops);
}

/* Attach the GPUs the backend lists and query each one. */
static int
open_devices(nvrm_ctx *ctx, char *err, size_t errlen)
{
	uint32_t ids[NVRM_MAX_GPUS];
	char msg[96];
	unsigned n, i;
	int rc;

	rc = ctx->ops->list_gpus(ctx->be, ids, NVRM_MAX_GPUS, &n, err, errlen);
	if (rc == NVRM_OK && n == 0) {
		set_err(err, errlen, "no GPU is attached");
		rc = NVRM_E_NODEV;
	}
	for (i = 0; rc == NVRM_OK && i < n; i++) {
		rc = ctx->ops->gpu_open(ctx->be, ids[i], &ctx->dev[i].gpu, err,
		    errlen);
		if (rc != NVRM_OK)
			break;
		ctx->dev[i].ctx = ctx;
		ctx->dev[i].index = i;
		ctx->ndev = i + 1;
		nvrm_query_device(ctx->ops, ctx->dev[i].gpu, &ctx->dev[i].info);
		if (info_has_call_failure(&ctx->dev[i].info)) {
			snprintf(msg, sizeof(msg), "a system call to the "
			    "driver failed while reading GPU %u", i);
			set_err(err, errlen, msg);
			rc = NVRM_E_IO;
		}
	}
	return (rc);
}

int
nvrm_enumerate(nvrm_ctx **ctxp, const nvrm_enum_opts *opts, char *err,
    size_t errlen)
{
	const nvrm_backend_ops *ops;
	nvrm_ctx *ctx;
	int rc;

	*ctxp = NULL;
	set_err(err, errlen, "");
	if (opts != NULL && (opts->flags & ~NVRM_ENUM_KNOWN_FLAGS) != 0) {
		set_err(err, errlen, "unknown enumeration flags: the options "
		    "were built for another version of libnvrm");
		return (NVRM_E_INVAL);
	}
	ops = choose_backend(opts, err, errlen);
	if (ops == NULL)
		return (NVRM_E_NOBACKEND);
	ctx = NVRM_CALLOC(1, sizeof(*ctx));
	if (ctx == NULL) {
		set_err(err, errlen, "out of memory");
		return (NVRM_E_NOMEM);
	}
	ctx->ops = ops;
	rc = ops->open(&ctx->be, err, errlen);
	if (rc != NVRM_OK) {
		free(ctx);
		return (rc);
	}
	ops->running_version(ctx->be, &ctx->running);
	rc = open_devices(ctx, err, errlen);
	if (rc == NVRM_OK)
		rc = ops->limit(ctx->be, opts != NULL && (opts->flags & NVRM_ENUM_ALLOW_ALLOC_MAP) != 0);
	if (rc == NVRM_E_CAPSICUM)
		set_err(err, errlen,
		    "cannot limit the descriptors for capability mode");
	if (rc != NVRM_OK) {
		free_ctx(ctx);
		return (rc);
	}
	*ctxp = ctx;
	return (NVRM_OK);
}

void
nvrm_close(nvrm_ctx *ctx)
{
	if (ctx != NULL)
		free_ctx(ctx);
}

const char *
nvrm_backend_name(const nvrm_ctx *ctx)
{
	return (ctx->ops->name);
}

const nvrm_str *
nvrm_rm_running_version(const nvrm_ctx *ctx)
{
	return (&ctx->running);
}

unsigned
nvrm_device_count(const nvrm_ctx *ctx)
{
	return (ctx->ndev);
}

nvrm_device *
nvrm_device_get(const nvrm_ctx *ctx, unsigned index)
{
	if (index >= ctx->ndev)
		return (NULL);
	return ((nvrm_device *)&ctx->dev[index]);
}

const nvrm_device_info *
nvrm_device_info_get(const nvrm_device *dev)
{
	return (&dev->info);
}

int
nvrm_device_refresh(nvrm_device *dev)
{
	nvrm_query_device(dev->ctx->ops, dev->gpu, &dev->info);
	return (info_has_call_failure(&dev->info) ? NVRM_E_IO : NVRM_OK);
}

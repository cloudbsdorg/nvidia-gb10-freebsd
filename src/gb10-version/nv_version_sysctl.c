/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Numeric version siblings and newbus identity sysctls for NVIDIA's FreeBSD
 * modules.  All parsing goes through the one freestanding nvrm_version parser.
 */
#include <sys/types.h>
#include <sys/systm.h>

#include "nv_version_sysctl.h"
#include "nvrm_version.h"

/*
 * The handler's arg2 selects what to report.  Values 0 to
 * NVRM_VERSION_MAX_PARTS - 1 are version part indices; the two special
 * selectors follow directly after them.
 */
enum {
	NV_VERSION_SYSCTL_AVAILABLE = NVRM_VERSION_MAX_PARTS,
	NV_VERSION_SYSCTL_SUFFIX
};

/* Parse a module banner once and populate the int-typed leaves of STATE. */
static void
nv_version_sysctl_parse_banner(const char *banner,
    struct nv_version_sysctl_state *state)
{
	unsigned i;

	nvrm_version_find(banner, &state->parsed);
	for (i = 0; i < NV_VERSION_SYSCTL_STATE_PARTS; i++) {
		state->parts[i] = state->parsed.available ?
		    (int)state->parsed.parts[i] : 0;
	}
}

/*
 * Register the module version leaves under PARENT.  The leaves read STATE,
 * which the caller owns and keeps alive until CTX is freed; each caller
 * passes its own STATE, so several callers never share parsed values.
 */
void
nv_version_sysctl_init(struct sysctl_ctx_list *ctx, struct sysctl_oid *parent,
    const char *banner, struct nv_version_sysctl_state *state)
{
	nv_version_sysctl_parse_banner(banner, state);

	SYSCTL_ADD_STRING(ctx, SYSCTL_CHILDREN(parent), OID_AUTO,
	    "version_string", CTLTYPE_STRING | CTLFLAG_RD | CTLFLAG_DYN,
	    state->parsed.string,
	    sizeof(state->parsed.string),
	    "NVIDIA numeric version string");
	SYSCTL_ADD_INT(ctx, SYSCTL_CHILDREN(parent), OID_AUTO,
	    "version_major", CTLTYPE_INT | CTLFLAG_RD | CTLFLAG_DYN,
	    &state->parts[0], 0, "NVIDIA version major part");
	SYSCTL_ADD_INT(ctx, SYSCTL_CHILDREN(parent), OID_AUTO,
	    "version_minor", CTLTYPE_INT | CTLFLAG_RD | CTLFLAG_DYN,
	    &state->parts[1], 0, "NVIDIA version minor part");
	SYSCTL_ADD_INT(ctx, SYSCTL_CHILDREN(parent), OID_AUTO,
	    "version_patch", CTLTYPE_INT | CTLFLAG_RD | CTLFLAG_DYN,
	    &state->parts[2], 0, "NVIDIA version patch part");
	SYSCTL_ADD_STRING(ctx, SYSCTL_CHILDREN(parent), OID_AUTO,
	    "version_suffix", CTLTYPE_STRING | CTLFLAG_RD | CTLFLAG_DYN,
	    state->parsed.suffix,
	    sizeof(state->parsed.suffix), "NVIDIA version suffix");
	SYSCTL_ADD_INT(ctx, SYSCTL_CHILDREN(parent), OID_AUTO,
	    "version_available", CTLTYPE_INT | CTLFLAG_RD | CTLFLAG_DYN,
	    &state->parsed.available, 0,
	    "NVIDIA version parsed successfully");
}

#ifndef NV_VERSION_SYSCTL_MODESET
/*
 * Return one field of a version retrieved at sysctl access time.  Every read
 * of every leaf fetches the version from RM anew and parses it; no two leaves
 * share a fetch.
 */
static int
nv_version_sysctl_gpu_out(SYSCTL_HANDLER_ARGS, const char *raw, unsigned base)
{
	nvrm_version v;
	int value;

	nvrm_version_parse(raw, base, &v);
	if (arg2 == NV_VERSION_SYSCTL_SUFFIX)
		return (SYSCTL_OUT(req, v.suffix, strlen(v.suffix) + 1));
	if (arg2 == NV_VERSION_SYSCTL_AVAILABLE) {
		value = v.available;
	} else {
		if (arg2 < 0 || arg2 >= NVRM_VERSION_MAX_PARTS)
			return (EINVAL);
		value = v.available ? (int)v.parts[arg2] : 0;
	}
	return (SYSCTL_OUT(req, &value, sizeof(value)));
}

int
nv_version_sysctl_gpu_vbios(SYSCTL_HANDLER_ARGS)
{
	nv_state_t *nv = arg1;
	nvidia_stack_t *sp;
	/* One byte beyond what RM writes, so the string is always terminated. */
	char vbios_version[NV_VBIOS_VERSION_LEN + 1] = { };

	NV_UMA_ZONE_ALLOC_STACK(sp);
	if (sp == NULL)
		return (ENOMEM);

	rm_get_vbios_version(sp, nv, vbios_version);

	NV_UMA_ZONE_FREE_STACK(sp);

	return (nv_version_sysctl_gpu_out(oidp, arg1, arg2, req,
	    vbios_version, 16));
}

int
nv_version_sysctl_gpu_firmware(SYSCTL_HANDLER_ARGS)
{
	nv_state_t *nv = arg1;
	nvidia_stack_t *sp;
	char firmware_version[64] = { };

	NV_UMA_ZONE_ALLOC_STACK(sp);
	if (sp == NULL)
		return (ENOMEM);

	rm_get_firmware_version(sp, nv, firmware_version, sizeof(firmware_version));

	NV_UMA_ZONE_FREE_STACK(sp);

	return (nv_version_sysctl_gpu_out(oidp, arg1, arg2, req,
	    firmware_version, 10));
}

#define NV_VERSION_SYSCTL_COUNT(t) (sizeof(t) / sizeof((t)[0]))

struct nv_version_sysctl_entry {
	const char *name;
	int arg2;
	bool is_string;
	const char *descr;
};

static const struct nv_version_sysctl_entry nv_version_sysctl_vbios_table[] = {
	{ "vbios_major", 0, false,
	    "VBIOS major part (hex field, shown in decimal)" },
	{ "vbios_minor", 1, false,
	    "VBIOS minor part (hex field, shown in decimal)" },
	{ "vbios_patch", 2, false,
	    "VBIOS patch part (hex field, shown in decimal)" },
	{ "vbios_build", 3, false,
	    "VBIOS build part (hex field, shown in decimal)" },
	{ "vbios_revision", 4, false,
	    "VBIOS revision part (hex field, shown in decimal)" },
	{ "vbios_available", NV_VERSION_SYSCTL_AVAILABLE, false,
	    "VBIOS version parsed successfully" },
	{ "vbios_suffix", NV_VERSION_SYSCTL_SUFFIX, true,
	    "VBIOS version suffix" },
};

static const struct nv_version_sysctl_entry nv_version_sysctl_firmware_table[] = {
	{ "firmware_major", 0, false, "Firmware major part (decimal)" },
	{ "firmware_minor", 1, false, "Firmware minor part (decimal)" },
	{ "firmware_patch", 2, false, "Firmware patch part (decimal)" },
	{ "firmware_available", NV_VERSION_SYSCTL_AVAILABLE, false,
	    "Firmware version parsed successfully" },
	{ "firmware_suffix", NV_VERSION_SYSCTL_SUFFIX, true,
	    "Firmware version suffix" },
};

static void
nv_version_sysctl_gpu_table_add(struct sysctl_ctx_list *ctx,
    struct sysctl_oid *parent, nv_state_t *nv,
    const struct nv_version_sysctl_entry *table, size_t count,
    int (*handler)(SYSCTL_HANDLER_ARGS))
{
	size_t i;

	for (i = 0; i < count; i++) {
		/* SYSCTL_ADD_PROC needs a constant type, the table is not. */
		if (table[i].is_string)
			SYSCTL_ADD_PROC(ctx, SYSCTL_CHILDREN(parent), OID_AUTO,
			    table[i].name,
			    CTLTYPE_STRING | CTLFLAG_RD | CTLFLAG_DYN, nv,
			    table[i].arg2, handler, "A", table[i].descr);
		else
			SYSCTL_ADD_PROC(ctx, SYSCTL_CHILDREN(parent), OID_AUTO,
			    table[i].name,
			    CTLTYPE_INT | CTLFLAG_RD | CTLFLAG_DYN, nv,
			    table[i].arg2, handler, "I", table[i].descr);
	}
}

static void
nv_version_sysctl_gpu_vbios_add(struct sysctl_ctx_list *ctx,
    struct sysctl_oid *parent, nv_state_t *nv)
{
	nv_version_sysctl_gpu_table_add(ctx, parent, nv,
	    nv_version_sysctl_vbios_table,
	    NV_VERSION_SYSCTL_COUNT(nv_version_sysctl_vbios_table),
	    nv_version_sysctl_gpu_vbios);
}

static void
nv_version_sysctl_gpu_firmware_add(struct sysctl_ctx_list *ctx,
    struct sysctl_oid *parent, nv_state_t *nv)
{
	nv_version_sysctl_gpu_table_add(ctx, parent, nv,
	    nv_version_sysctl_firmware_table,
	    NV_VERSION_SYSCTL_COUNT(nv_version_sysctl_firmware_table),
	    nv_version_sysctl_gpu_firmware);
}

int
nv_version_sysctl_gpu_uuid(SYSCTL_HANDLER_ARGS)
{
	nv_state_t *nv = arg1;
	nvidia_stack_t *sp;
	char *uuid;
	int ret;

	NV_UMA_ZONE_ALLOC_STACK(sp);
	if (sp == NULL)
		return (ENOMEM);

	uuid = rm_get_gpu_uuid(sp, nv);

	NV_UMA_ZONE_FREE_STACK(sp);

	/* The GPU is not initialized yet: a later read can succeed. */
	if (uuid == NULL)
		return (EIO);

	ret = SYSCTL_OUT(req, uuid, strlen(uuid) + 1);
	os_free_mem(uuid);

	return (ret);
}

int
nv_version_sysctl_gpu_pci_bus_id(SYSCTL_HANDLER_ARGS)
{
	nv_state_t *nv = arg1;
	char pci_bus_id[NV_PCI_BUS_ID_LEN];

	snprintf(pci_bus_id, sizeof(pci_bus_id), "%04x:%02x:%02x.%x",
	    (unsigned)nv->pci_info.domain, (unsigned)nv->pci_info.bus,
	    (unsigned)nv->pci_info.slot, (unsigned)nv->pci_info.function);
	return (SYSCTL_OUT(req, pci_bus_id, strlen(pci_bus_id) + 1));
}

void
nv_version_sysctl_gpu_init(nv_state_t *nv, struct sysctl_oid *parent)
{
	struct nvidia_softc *sc = nv->os_state;
	struct sysctl_oid *dev_tree;

	nv_version_sysctl_gpu_vbios_add(&sc->sysctl_ctx, parent, nv);
	nv_version_sysctl_gpu_firmware_add(&sc->sysctl_ctx, parent, nv);

	/*
	 * nv_sysctl_exit() frees the softc context during detach.  The newbus
	 * context lives longer, so using it could let a read dereference nv after
	 * the driver's own teardown has freed that state.
	 */
	dev_tree = device_get_sysctl_tree(sc->dev);
	SYSCTL_ADD_PROC(&sc->sysctl_ctx, SYSCTL_CHILDREN(dev_tree), OID_AUTO,
	    "uuid", CTLTYPE_STRING | CTLFLAG_RD | CTLFLAG_DYN, nv, 0,
	    nv_version_sysctl_gpu_uuid, "A", "NVIDIA GPU UUID");
	SYSCTL_ADD_PROC(&sc->sysctl_ctx, SYSCTL_CHILDREN(dev_tree), OID_AUTO,
	    "pci_bus_id", CTLTYPE_STRING | CTLFLAG_RD | CTLFLAG_DYN, nv, 0,
	    nv_version_sysctl_gpu_pci_bus_id, "A",
	    "NVIDIA GPU PCI bus ID (domain:bus:slot.function)");
}
#endif /* !NV_VERSION_SYSCTL_MODESET */

#ifdef NV_VERSION_SYSCTL_MODESET
static struct sysctl_ctx_list nv_version_sysctl_modeset_ctx;
static struct nv_version_sysctl_state nv_version_sysctl_modeset_state;

/*
 * Version sysctls are informational: when the parent node cannot be created
 * the module still loads, without them.
 */
void
nv_version_sysctl_modeset_init(const char *banner)
{
	struct sysctl_oid *parent;

	sysctl_ctx_init(&nv_version_sysctl_modeset_ctx);
	parent = SYSCTL_ADD_NODE(&nv_version_sysctl_modeset_ctx,
	    SYSCTL_STATIC_CHILDREN(_hw), OID_AUTO, "nvidiamodeset",
	    CTLFLAG_RD | CTLFLAG_DYN, 0, "NVIDIA modeset SYSCTL parent node");
	if (parent == NULL) {
		sysctl_ctx_free(&nv_version_sysctl_modeset_ctx);
		return;
	}
	SYSCTL_ADD_STRING(&nv_version_sysctl_modeset_ctx, SYSCTL_CHILDREN(parent),
	    OID_AUTO, "version", CTLTYPE_STRING | CTLFLAG_RD | CTLFLAG_DYN,
	    (char *)(uintptr_t)banner, 0, "NVIDIA modeset version");
	nv_version_sysctl_init(&nv_version_sysctl_modeset_ctx, parent, banner,
	    &nv_version_sysctl_modeset_state);
}

void
nv_version_sysctl_modeset_exit(void)
{
	sysctl_ctx_free(&nv_version_sysctl_modeset_ctx);
}
#endif /* NV_VERSION_SYSCTL_MODESET */

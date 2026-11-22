/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 */
#ifndef _NV_VERSION_SYSCTL_H_
#define _NV_VERSION_SYSCTL_H_

#include <sys/types.h>
#include <sys/sysctl.h>

#include "nvrm_version.h"

#ifndef NV_VERSION_SYSCTL_MODESET
#include "os-interface.h"
#include "nv.h"
#include "nv-freebsd.h"
#endif

/* Parts exposed as int leaves: major, minor, patch. */
#define NV_VERSION_SYSCTL_STATE_PARTS	3

/* Bytes RM writes for a VBIOS version string: "xx.xx.xx.xx.xx" and NUL. */
#define NV_VBIOS_VERSION_LEN		15

/*
 * Longest PCI bus ID: an 8 hex digit domain, ':', bus, ':', slot, '.',
 * function (two digits each at most) and NUL.
 */
#define NV_PCI_BUS_ID_LEN		32

/* Parsed module version; the caller owns one per nv_version_sysctl_init(). */
struct nv_version_sysctl_state {
	nvrm_version parsed;
	int parts[NV_VERSION_SYSCTL_STATE_PARTS];
};

void nv_version_sysctl_init(struct sysctl_ctx_list *, struct sysctl_oid *,
    const char *, struct nv_version_sysctl_state *);

#ifndef NV_VERSION_SYSCTL_MODESET
void nv_version_sysctl_gpu_init(nv_state_t *, struct sysctl_oid *);
int nv_version_sysctl_gpu_vbios(SYSCTL_HANDLER_ARGS);
int nv_version_sysctl_gpu_firmware(SYSCTL_HANDLER_ARGS);
int nv_version_sysctl_gpu_uuid(SYSCTL_HANDLER_ARGS);
int nv_version_sysctl_gpu_pci_bus_id(SYSCTL_HANDLER_ARGS);
#else
void nv_version_sysctl_modeset_init(const char *);
void nv_version_sysctl_modeset_exit(void);
#endif

#endif /* _NV_VERSION_SYSCTL_H_ */

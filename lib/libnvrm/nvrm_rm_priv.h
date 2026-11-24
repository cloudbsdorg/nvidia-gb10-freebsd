/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * nvrm_rm_priv.h - what the two halves of the RM backend share: nvrm_rm.c
 * (discovery) and nvrm_rm_mem.c (memory and VA).  Not installed.
 */
#ifndef _NVRM_RM_PRIV_H_
#define _NVRM_RM_PRIV_H_

#include <nvtypes.h>
#include <nvstatus.h>
#include <nvos.h>
#include <nv-ioctl.h>
#include <nv_escape.h>

#include "nvrm_internal.h"
#include "nvrm_rm_sys.h"

/* ---- ioctl numbers ----------------------------------------------------- */

#define IOC_CHECK_VERSION	_IOWR(NV_IOCTL_MAGIC, NV_ESC_CHECK_VERSION_STR, \
				    nv_ioctl_rm_api_version_t)
#define IOC_XFER		_IOWR(NV_IOCTL_MAGIC, NV_ESC_IOCTL_XFER_CMD, \
				    nv_ioctl_xfer_t)
#define IOC_RM_ALLOC		_IOWR(NV_IOCTL_MAGIC, NV_ESC_RM_ALLOC, \
				    NVOS21_PARAMETERS)
#define IOC_RM_CONTROL		_IOWR(NV_IOCTL_MAGIC, NV_ESC_RM_CONTROL, \
				    NVOS54_PARAMETERS)
#define IOC_RM_FREE		_IOWR(NV_IOCTL_MAGIC, NV_ESC_RM_FREE, \
				    NVOS00_PARAMETERS)
/* ATTACH_GPUS_TO_FD carries 4 bytes per GPU: its size is the GPU count. */
#define IOC_ATTACH(n)		_IOC(IOC_INOUT, NV_IOCTL_MAGIC, \
				    NV_ESC_ATTACH_GPUS_TO_FD, \
				    (n) * sizeof(NvU32))

#define HANDLE_BASE		0xd1a00000u
/* Status of a call whose ioctl(2) itself failed: not an RM status. */
#define IOCTL_FAILED		0xfffffff0u

/* ---- backend state ----------------------------------------------------- */

struct nvrm_backend {
	nvrm_owner		owner;		/* the process that opened it */
	int			fd;
	NvHandle		client;
	uint32_t		next_handle;
	nv_ioctl_card_info_t	cards[NV_MAX_DEVICES];
	nvrm_str		running;
	nvrm_version		driver, rm_api;
	int			wc, wc_reason;
};

/* Derive the running version (nvrm_rm_running_version) from the driver one. */
void	nvrm_rm_sync_running_version(nvrm_backend *be);

struct nvrm_gpu {
	nvrm_backend		*be;
	uint32_t		id;
	NvHandle		device, subdevice;
	nv_ioctl_card_info_t	card;
	int			have_card;
};

/* RM calls on a session (a descriptor and its RM client). */
NvU32	nvrm_rm_alloc(nvrm_backend *be, NvHandle parent, NvHandle *hnew,
	    NvU32 cls, void *params, NvU32 size);
NvU32	nvrm_rm_free(nvrm_backend *be, NvHandle parent, NvHandle obj);
NvU32	nvrm_rm_control(nvrm_backend *be, NvHandle obj, NvU32 cmd,
	    void *params, NvU32 size);
NvHandle nvrm_rm_new_handle(nvrm_backend *be);
int	nvrm_rm_open(nvrm_backend **bep, char *err, size_t errlen);
void	nvrm_rm_close(nvrm_backend *be);
int	nvrm_rm_owner(const nvrm_backend *be);
const nvrm_rm_sys *nvrm_rm_get_sys(void);

#endif

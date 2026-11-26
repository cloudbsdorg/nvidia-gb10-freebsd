/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * hw.nvidia.device_count: how many NVIDIA GPUs the driver has attached.
 *
 * The node is there whenever nvidia.ko is loaded, so a machine with no
 * NVIDIA GPU answers "0" instead of having no answer at all.  The count
 * is the driver's own count of the GPUs it has attached: the driver
 * counts a GPU when it attaches and forgets it when it detaches.  There
 * is no device list to walk here, so there is no lock to take and no
 * device whose softc can go away while it is read.
 */
#include <sys/types.h>
#include <sys/systm.h>
#include <sys/sysctl.h>

#include "os-interface.h"
#include "nv.h"
#include "nv-freebsd.h"

#include "nv_device_sysctl.h"
#include "nv_ctl_state.h"

/*
 * The count is read when the node is read, not when it is registered:
 * a GPU that the driver attaches or detaches while the module stays
 * loaded is counted, or not, the next time the node is read.
 */
static int
nv_device_sysctl_count(SYSCTL_HANDLER_ARGS)
{
	int count;

	count = nv_ctl_state_gpu_count();
	return (SYSCTL_OUT(req, &count, sizeof(count)));
}

void
nv_device_sysctl_init(struct sysctl_ctx_list *ctx, struct sysctl_oid *parent)
{

	SYSCTL_ADD_PROC(ctx, SYSCTL_CHILDREN(parent), OID_AUTO,
	    "device_count", CTLTYPE_INT | CTLFLAG_RD | CTLFLAG_DYN, NULL, 0,
	    nv_device_sysctl_count, "I",
	    "Number of NVIDIA GPUs the driver has attached");
}

/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 */
#ifndef _NV_DEVICE_SYSCTL_H_
#define _NV_DEVICE_SYSCTL_H_

#include <sys/types.h>
#include <sys/sysctl.h>

/*
 * Register hw.nvidia.device_count under PARENT: the number of NVIDIA GPUs
 * the driver has attached.  The node exists for as long as the module is
 * loaded, so a host with no NVIDIA GPU answers "0" instead of having no
 * node to ask.
 */
void nv_device_sysctl_init(struct sysctl_ctx_list *, struct sysctl_oid *);

#endif /* _NV_DEVICE_SYSCTL_H_ */

/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-3-Clause
 *
 * gpu_rm_ioctl.h - the RM escape ioctls, by number.
 *
 * The numbers are NVIDIA's own (open-gpu-kernel-modules 580.178.04, MIT):
 * the OS layer's ioctl headers of src/nvidia/arch/nvalloc/unix/include and
 * the RM's escape numbers of nv_escape.h.  The engine (gpu_rm.c) and the
 * daemon (gpu_daemon.c) both need them: the engine answers them, the daemon
 * carries them over CUSE, where the pointers inside the arguments are the
 * client's addresses.
 */
#ifndef _GPU_RM_IOCTL_H_
#define _GPU_RM_IOCTL_H_

#include <sys/ioctl.h>
#include <sys/ioccom.h>

#include <nvtypes.h>
#include <nvstatus.h>
#include <nvmisc.h>
#include <nvos.h>
#include <nv-ioctl.h>
#include <nv_escape.h>

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
#define IOC_MAP_MEMORY		_IOWR(NV_IOCTL_MAGIC, NV_ESC_RM_MAP_MEMORY, \
				    nv_ioctl_nvos33_parameters_with_fd)
#define IOC_UNMAP_MEMORY	_IOWR(NV_IOCTL_MAGIC, NV_ESC_RM_UNMAP_MEMORY, \
				    NVOS34_PARAMETERS)
#define IOC_MAP_DMA		_IOWR(NV_IOCTL_MAGIC, NV_ESC_RM_MAP_MEMORY_DMA, \
				    NVOS46_PARAMETERS)
#define IOC_UNMAP_DMA		_IOWR(NV_IOCTL_MAGIC, NV_ESC_RM_UNMAP_MEMORY_DMA, \
				    NVOS47_PARAMETERS)

#endif /* _GPU_RM_IOCTL_H_ */

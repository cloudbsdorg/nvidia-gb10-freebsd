/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * nvrm_rm_sys.h - the system calls the RM backend makes, as a table, so the
 * test suite can stand a scripted kernel in front of the backend (not
 * installed).
 */
#ifndef _NVRM_RM_SYS_H_
#define _NVRM_RM_SYS_H_

#include <stddef.h>

typedef struct nvrm_rm_sys {
	int	(*open)(const char *path, int flags);
	int	(*close)(int fd);
	int	(*ioctl)(int fd, unsigned long cmd, void *arg);
	int	(*sysctlbyname)(const char *name, void *old, size_t *oldlen);
	int	(*access)(const char *path);
} nvrm_rm_sys;

extern const nvrm_rm_sys nvrm_rm_real_sys;

/* NULL restores the real system calls. */
void	nvrm_rm_set_sys(const nvrm_rm_sys *sys);

#define NVRM_CTL_PATH		"/dev/nvidiactl"
#define NVRM_SYSCTL_VERSION	"hw.nvidia.version"
#define NVRM_SYSCTL_WC		"hw.nvidia.altra_device_wc_active"

#endif

/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * nvrm_cap.c - Capsicum limits shared by the backends.  A descriptor limited
 * here keeps working after the process enters capability mode, for exactly
 * the ioctls on the allow list and nothing else.
 */
#include <sys/types.h>
#include <sys/capsicum.h>

#include "nvrm_internal.h"

int
nvrm_cap_limit_fd(int fd, const unsigned long *cmds, unsigned ncmds)
{
	cap_rights_t rights;

	/* Ioctl and event only.  There is no mapping right: S1 maps nothing. */
	cap_rights_init(&rights, CAP_IOCTL, CAP_EVENT);
	if (cap_rights_limit(fd, &rights) != 0)
		return (NVRM_E_CAPSICUM);
	if (cap_ioctls_limit(fd, cmds, ncmds) != 0)
		return (NVRM_E_CAPSICUM);
	return (NVRM_OK);
}

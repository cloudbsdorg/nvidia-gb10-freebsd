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

/*
 * A spare descriptor, limited to what it is for.  A mapping descriptor keeps
 * only the right to be mapped (read and write); an export descriptor only the
 * right the RM needs to find it by number (read).  Neither can issue an ioctl.
 */
int
nvrm_cap_limit_desc(int fd, int kind)
{
	cap_rights_t rights;

	if (kind == NVRM_DESC_MAP)
		cap_rights_init(&rights, CAP_MMAP_RW);
	else
		cap_rights_init(&rights, CAP_READ);
	return (cap_rights_limit(fd, &rights) == 0 ? NVRM_OK : NVRM_E_CAPSICUM);
}

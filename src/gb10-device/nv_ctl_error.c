/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * nv_ctl_error.c - the message the driver prints when it cannot create
 * /dev/nvidiactl.
 *
 * The message names the resource, says what went wrong, and says what the
 * person at the console can do about it.  A message that only says
 * "nvidia_ctl_module_attach() failed!" names an internal function and
 * leaves the reader guessing.
 *
 * The driver passes the code the kernel gave it, unchanged: the code is
 * the cause, and every cause has its own words here.  A cause the
 * kernel did not name is not turned into another cause: it gets the
 * honest answer, that the node could not be made.
 */
#include <sys/types.h>
#include <sys/errno.h>
#include <sys/systm.h>

#include "nv_ctl_error.h"

/*
 * What the reason is, and what to do about it.  Every reason says the
 * same three things, so no failure is reported as some other failure.
 *
 * The reasons are the ones the kernel can return when it cannot make
 * the device node: ENOMEM when the memory for the device could not be
 * had, and EINVAL when the node itself, or the registration behind it,
 * was refused.  Every other code gets the honest answer: the node could
 * not be made, and the kernel did not say why.
 */
void
nv_ctl_create_error(int err, char *buf, size_t len)
{
	const char *reason;
	const char *what;

	switch (err) {
	case ENOMEM:
		reason = "out of memory";
		what = "check the available memory and load nvidia.ko again";
		break;
	case EINVAL:
		reason = "the device node was refused";
		what = "check that the module and the kernel match and that "
		    "/dev is writable, then load nvidia.ko again";
		break;
	default:
		reason = "the device node could not be made";
		what = "check that devfs is mounted and that /dev is writable, "
		    "then load nvidia.ko again";
		break;
	}

	snprintf(buf, len, "cannot create /dev/nvidiactl: %s; %s", reason,
	    what);
}

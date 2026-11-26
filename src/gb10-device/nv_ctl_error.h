/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 */
#ifndef _NV_CTL_ERROR_H_
#define _NV_CTL_ERROR_H_

#include <sys/types.h>

/*
 * The message the driver prints when it cannot create /dev/nvidiactl.
 *
 * The driver cannot load without the control device, so the person at the
 * console has to be told what is missing, why, and what to do about it.
 * ERR is the reason the device could not be made; BUF gets the message
 * and LEN its size.
 */
void nv_ctl_create_error(int err, char *buf, size_t len);

#endif /* _NV_CTL_ERROR_H_ */

/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-3-Clause
 *
 * gpu_rm.h - the RM engine of the mock: the RM escape ioctls, answered from
 * the model.  The daemon puts it behind the CUSE device nodes; the tests put
 * it behind the seam of libnvrm's rm backend.
 */
#ifndef _GPU_RM_H_
#define _GPU_RM_H_

#include <stdint.h>

struct gpu_model;

/* The limits of the engine. */
#define GPU_RM_MAX_OBJECTS	512
#define GPU_RM_MAX_MAPS		64
#define GPU_RM_MAX_CARDS	16
#define GPU_RM_MAX_GPCS		32
#define GPU_RM_MAX_FAULTS	16

/* No card: an object that belongs to no GPU. */
#define GPU_RM_NO_CARD		0xffffffffu

/* The cookie of a mapping: the address the mock gives it. */
#define GPU_RM_MAP_COOKIE_BASE	0x0000000000100000ull

/* The work submit token the mock hands out. */
#define GPU_RM_SUBMIT_TOKEN	0x0000000000001234ull

struct gpu_rm;

/* The engine of one model.  NULL when there is no memory for it. */
struct gpu_rm *gpu_rm_new(const struct gpu_model *model);
void	gpu_rm_free(struct gpu_rm *rm);

/*
 * One ioctl.  Returns 0 when the call succeeded and -1 with errno set when
 * the call itself failed (the same contract as ioctl(2)).
 */
int	gpu_rm_ioctl(struct gpu_rm *rm, unsigned long cmd, void *arg);

#endif /* _GPU_RM_H_ */

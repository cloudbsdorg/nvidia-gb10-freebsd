/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * nv_ctl_state.c - the state of the control device and of the GPUs the
 * driver has attached.
 *
 * The driver counts a GPU when it attaches and forgets it when it
 * detaches; hw.nvidia.device_count reads the count.  The control device
 * belongs to the module: it exists from the module load to the module
 * unload, whether a GPU is attached or not.
 *
 * The state is here, in a file of our own, so that the test can drive
 * the real transitions: the driver and the test call the same
 * functions, so the test cannot pass while the driver does something
 * else.
 */
#include <sys/types.h>

#include "nv_ctl_state.h"

/*
 * The GPUs the driver has attached.  The count is the driver's own: it
 * is not a guess made by walking the device list.
 */
static int gpu_count;

/*
 * Whether the control device may still be used.  The module owns the
 * device from its load to its unload.  The unload clears this before
 * the device is destroyed, so an open that was already in flight cannot
 * reach the resource manager after it is gone.
 */
static int device_alive;

void
nv_ctl_state_gpu_attach(void)
{

	gpu_count++;
}

void
nv_ctl_state_gpu_detach(void)
{

	/*
	 * The count never goes below zero.  A detach without an attach is
	 * a bug in the caller, and the number of GPUs the driver has is
	 * not a negative number.
	 */
	if (gpu_count > 0)
		gpu_count--;
}

int
nv_ctl_state_gpu_count(void)
{

	return (gpu_count);
}

void
nv_ctl_state_device_created(void)
{

	device_alive = 1;
}

void
nv_ctl_state_device_destroyed(void)
{

	device_alive = 0;
}

int
nv_ctl_state_device_alive(void)
{

	return (device_alive);
}

/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 */
#ifndef _NV_CTL_STATE_H_
#define _NV_CTL_STATE_H_

/*
 * The state of the control device and of the GPUs the driver has
 * attached.
 *
 * The driver counts a GPU when it attaches and forgets it when it
 * detaches, and hw.nvidia.device_count reads that count.  The control
 * device belongs to the module: it exists from the module load to the
 * module unload, whether a GPU is attached or not, and it may not be
 * used once the unload has begun.
 *
 * The state lives in one file of our own so that it can be tested
 * without a GPU and without a kernel: the driver calls these
 * functions, and the test calls the same ones.
 */

/* A GPU attached: the driver has one GPU more. */
void nv_ctl_state_gpu_attach(void);

/*
 * A GPU detached: the driver has one GPU less.  The count never goes
 * below zero: a detach without an attach is a bug in the caller, and
 * the number of GPUs the driver has is not a negative number.
 */
void nv_ctl_state_gpu_detach(void);

/* How many GPUs the driver has attached. */
int nv_ctl_state_gpu_count(void);

/* The control device was made: it may be used. */
void nv_ctl_state_device_created(void);

/* The control device is on its way out: it may not be used. */
void nv_ctl_state_device_destroyed(void);

/* Whether the control device may still be used. */
int nv_ctl_state_device_alive(void);

#endif /* _NV_CTL_STATE_H_ */

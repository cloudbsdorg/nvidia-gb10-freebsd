/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * nvrm_barrier.h - the two stores barriers used to publish GPFIFO work.
 */
#ifndef _NVRM_BARRIER_H_
#define _NVRM_BARRIER_H_

#include "nvrm_internal.h"

/* Test seam: reports NVRM_CHAN_EV_BARRIER_NORMAL or _DEVICE (the codes are
 * enum nvrm_chan_event in nvrm_internal.h). */
extern void (*nvrm_barrier_hook)(int);

static inline void
nvrm_barrier_normal(void)
{
	if (nvrm_barrier_hook != NULL) {
		nvrm_barrier_hook(NVRM_CHAN_EV_BARRIER_NORMAL);
		return;
	}
#if defined(__aarch64__)
	__asm__ __volatile__("dmb oshst" ::: "memory");
#elif defined(__amd64__)
	__asm__ __volatile__("sfence" ::: "memory");
#else
	__atomic_thread_fence(__ATOMIC_SEQ_CST);
#endif
}

static inline void
nvrm_barrier_device(void)
{
	if (nvrm_barrier_hook != NULL) {
		nvrm_barrier_hook(NVRM_CHAN_EV_BARRIER_DEVICE);
		return;
	}
#if defined(__aarch64__)
	__asm__ __volatile__("dsb st" ::: "memory");
#elif defined(__amd64__)
	__asm__ __volatile__("sfence" ::: "memory");
#else
	__atomic_thread_fence(__ATOMIC_SEQ_CST);
#endif
}

#endif /* _NVRM_BARRIER_H_ */

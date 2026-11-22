/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * nvrm_fake.h - test controls of the fake backend (not installed).
 */
#ifndef _NVRM_FAKE_H_
#define _NVRM_FAKE_H_

#include <stdint.h>

void	nvrm_fake_inject(int prop, int reason);
void	nvrm_fake_inject_value(int prop, uint64_t value);
void	nvrm_fake_inject_tpc_fail(int gpc);
void	nvrm_fake_inject_uuid_fail(int reason);
void	nvrm_fake_inject_classes(const uint32_t *list, unsigned n);
void	nvrm_fake_inject_classes_fail(int reason);
void	nvrm_fake_inject_clear(void);
int	nvrm_fake_fd(void);

/*
 * The memory model (nvrm_fake_mem.c).  A software GPU: video and system memory
 * are regions of one anonymous shared object per GPU, the VA space is a table
 * of reservations and mappings, and nvrm_fake_gpu_access() reads or writes
 * through it as the GPU would.  The fake keeps process-wide state: use one
 * thread.
 */
enum {
	NVRM_FAKE_OP_CLIENT_OPEN = 1, NVRM_FAKE_OP_DESC, NVRM_FAKE_OP_VA_RESERVE,
	NVRM_FAKE_OP_ALLOC, NVRM_FAKE_OP_REGISTER, NVRM_FAKE_OP_MAP_GPU,
	NVRM_FAKE_OP_MAP_CPU, NVRM_FAKE_OP_EXPORT, NVRM_FAKE_OP_IMPORT,
	NVRM_FAKE_OP_LIMIT, NVRM_FAKE_OP_SIZE, NVRM_FAKE_OP_WRITE,
	NVRM_FAKE_OP_RIGHTS,
	NVRM_FAKE_OP__COUNT
};

typedef struct nvrm_fake_mem_stats {
	unsigned	clients, objects, reservations, gpu_maps;
	uint64_t	vram_free, sys_free;	/* bytes not allocated */
	unsigned	vram_extents, sys_extents;
	uint64_t	traps, checked;		/* Device accesses refused / checked */
} nvrm_fake_mem_stats;

/* Fail the nth next call of an operation with NVRM_E_RM (0 clears). */
void	nvrm_fake_mem_fail(int op, unsigned nth);
void	nvrm_fake_mem_stats_get(nvrm_fake_mem_stats *st);
#endif

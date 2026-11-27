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
void	nvrm_fake_inject_str_fail(int prop, int reason);
void	nvrm_fake_inject_classes(const uint32_t *list, unsigned n);
void	nvrm_fake_inject_classes_fail(int reason);
void	nvrm_fake_inject_zcull_fail(int reason);
void	nvrm_fake_inject_atom_size(uint64_t bytes, int reason);
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
	NVRM_FAKE_OP_LIMIT, NVRM_FAKE_OP_APERTURE_SIZE, NVRM_FAKE_OP_WRITE,
	NVRM_FAKE_OP_RIGHTS, NVRM_FAKE_OP_DESC_SIZE,
	/* releases the "RM" refuses: what they hold stays until client close */
	NVRM_FAKE_OP_VA_RELEASE, NVRM_FAKE_OP_FREE, NVRM_FAKE_OP_UNMAP_GPU,
	NVRM_FAKE_OP_UNMAP_CPU, NVRM_FAKE_OP_OVERMAP_CPU,
	NVRM_FAKE_OP__COUNT
};

typedef struct nvrm_fake_mem_stats {
	unsigned	clients, objects, reservations, gpu_maps;
	uint64_t	vram_free, sys_free;	/* bytes not allocated */
	unsigned	vram_extents, sys_extents;
	uint64_t	traps, checked;		/* Device accesses refused / checked */
} nvrm_fake_mem_stats;

/* Fail the nth next call of an operation with NVRM_E_RM (nth 0 disarms
 * it; an op out of range is ignored); _clear disarms every one. */
void	nvrm_fake_mem_fail(int op, unsigned nth);
void	nvrm_fake_mem_fail_clear(void);
/* The host page size the fake aligns objects to (0: sysconf's). */
void	nvrm_fake_mem_host_page(uint64_t bytes);
void	nvrm_fake_mem_stats_get(nvrm_fake_mem_stats *st);

/*
 * The fake channel engine (nvrm_fake_chan.c): the class numbers it reports,
 * the copy-engine methods it executes (offsets in bytes) and the launch bits
 * it understands.  Tests build pushbuffers from these names.
 */
#define NVRM_FAKE_CLASS_3D		0xcd97
#define NVRM_FAKE_CLASS_COMPUTE		0xcdc0
#define NVRM_FAKE_CLASS_I2M		0xcd40
#define NVRM_FAKE_CLASS_2D		0x902d
#define NVRM_FAKE_CLASS_COPY		0xcab5
#define NVRM_FAKE_CLASS_GPFIFO		0xca6f

#define NVRM_FAKE_COPY_OFFSET_IN_UPPER	0x400
#define NVRM_FAKE_COPY_OFFSET_IN_LOWER	0x404
#define NVRM_FAKE_COPY_OFFSET_OUT_UPPER	0x408
#define NVRM_FAKE_COPY_OFFSET_OUT_LOWER	0x40c
#define NVRM_FAKE_COPY_PITCH_IN		0x410
#define NVRM_FAKE_COPY_PITCH_OUT	0x414
#define NVRM_FAKE_COPY_LINE_LENGTH_IN	0x418
#define NVRM_FAKE_COPY_LINE_COUNT	0x41c
#define NVRM_FAKE_COPY_LAUNCH_DMA	0x300

/* The data transfer type is the low two bits of the launch word. */
#define NVRM_FAKE_COPY_TYPE_MASK	0x3U
#define NVRM_FAKE_COPY_TYPE_NONE	0U
#define NVRM_FAKE_COPY_TYPE_PIPELINED	1U
#define NVRM_FAKE_COPY_TYPE_INVALID	3U
#define NVRM_FAKE_COPY_LAUNCH_SEMAPHORE	(0x3U << 3)
#define NVRM_FAKE_COPY_LAUNCH_SRC_PITCH	(1U << 7)
#define NVRM_FAKE_COPY_LAUNCH_DST_PITCH	(1U << 8)
#define NVRM_FAKE_COPY_LAUNCH_MULTI_LINE (1U << 9)
#define NVRM_FAKE_COPY_LAUNCH_REMAP	(1U << 10)
#define NVRM_FAKE_COPY_LAUNCH_SRC_PHYSICAL (1U << 12)
#define NVRM_FAKE_COPY_LAUNCH_DST_PHYSICAL (1U << 13)
#define NVRM_FAKE_COPY_LAUNCH_SCRUB	(1U << 23)
#endif

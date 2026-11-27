/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * nvrm_chan.h - GPFIFO channels, ordered submission and progress semaphores.
 */
#ifndef _NVRM_NVRM_CHAN_H_
#define _NVRM_NVRM_CHAN_H_

#include <nvrm/nvrm.h>

__BEGIN_DECLS

typedef struct nvrm_chan nvrm_chan;

#define NVRM_ENG_3D		0x01	/* graphics runlist */
#define NVRM_ENG_COMPUTE	0x02	/* graphics runlist */
#define NVRM_ENG_I2M		0x04	/* graphics runlist (inline to memory) */
#define NVRM_ENG_2D		0x08	/* graphics runlist */
#define NVRM_ENG_COPY		0x10	/* copy runlist, or its graphics partner */
#define NVRM_ENG_KNOWN		0x1f

enum nvrm_runlist {
	NVRM_RUNLIST_GRAPHICS = 1,
	NVRM_RUNLIST_COPY
};

#define NVRM_CHAN_ENTRIES_DEFAULT	1024	/* 0 means this */
#define NVRM_CHAN_ENTRIES_MIN		8
#define NVRM_CHAN_ENTRIES_MAX		32768	/* powers of two only */

/*
 * The timeout a wait takes when the caller names none: two seconds.  Every
 * wait has a deadline: a wait that names UINT64_MAX waits without one, and
 * that is the caller's own choice.
 */
#define NVRM_CHAN_WAIT_DEFAULT_NS	2000000000ULL

typedef struct nvrm_chan_params {
	uint32_t	size;		/* sizeof(nvrm_chan_params); 0 means that */
	uint32_t	engines;	/* NVRM_ENG_* */
	uint32_t	entries;	/* a power of two; 0 means the default */
	uint32_t	flags;		/* none yet: must be 0 */
} nvrm_chan_params;

/*
 * One GPFIFO element: a pushbuffer segment in GPU memory.
 *
 * The two flags are the bits of the GPFIFO entry the MIT sources name
 * (cla16f.h, clc86f.h): bit 31 of the entry's second word is the SYNC
 * field (0: the fetch proceeds, 1: the fetch waits for the work before it),
 * and the entry's first word carries the "fetch conditional" bit.  The name
 * NVRM_GP_SYNC_WAIT says what the bit does; NVRM_GP_NO_PREFETCH is the name
 * it had before and means the same thing.
 */
#define NVRM_GP_SYNC_WAIT	0x1	/* fetch only after prior work is done */
#define NVRM_GP_NO_PREFETCH	NVRM_GP_SYNC_WAIT
#define NVRM_GP_INCOMPLETE	0x2	/* keep this element with the next one */
#define NVRM_GP_KNOWN		0x3

typedef struct nvrm_gp_entry {
	uint64_t	va;
	uint32_t	dwords;
	uint32_t	flags;		/* NVRM_GP_* */
} nvrm_gp_entry;

#define NVRM_SUBMIT_NO_KICK	0x1	/* publish GP_PUT without a doorbell */

typedef struct nvrm_submit_opts {
	uint32_t	size;		/* sizeof(nvrm_submit_opts); 0 means that */
	uint32_t	flags;		/* NVRM_SUBMIT_* */
	uint64_t	timeout_ns;	/* 0: never wait; UINT64_MAX: no limit */
} nvrm_submit_opts;

typedef struct nvrm_submit_result {
	uint32_t	size;		/* sizeof(nvrm_submit_result); 0 means that */
	uint32_t	accepted;	/* caller elements placed */
	uint64_t	point;		/* last batch's progress point, or 0 */
} nvrm_submit_result;

enum nvrm_chan_state {
	NVRM_CHAN_ALIVE = 1,
	NVRM_CHAN_DEAD
};

/*
 * Error notifier values in nvrm_chan_status.error are the backend's own.  The
 * core reports one itself: the progress semaphore, which the GPU can write,
 * held a value above the submitted point or below the completed point.  The
 * value is above any code a backend reports.
 */
#define NVRM_CHAN_ERR_SEMAPHORE	0xffff0001U

typedef struct nvrm_chan_status {
	uint32_t	size;		/* sizeof(nvrm_chan_status); 0 means that */
	uint32_t	state;		/* enum nvrm_chan_state */
	uint32_t	error;		/* error notifier or NVRM_CHAN_ERR_*; 0 none */
	uint32_t	gp_get, gp_put;
	uint32_t	reserved;
	uint64_t	submitted, completed;
} nvrm_chan_status;

typedef struct nvrm_chan_info {
	uint32_t	size;		/* sizeof(nvrm_chan_info); 0 means that */
	uint32_t	engines;
	uint32_t	entries;
	uint32_t	runlist;	/* enum nvrm_runlist */
	uint32_t	cls_gpfifo;
	uint32_t	subch_class[8];	/* bound class on each subchannel, 0 none */
	uint64_t	sem_va;		/* 64-bit progress semaphore, GPU read-write */
} nvrm_chan_info;

/*
 * The parameters the RM was given for a channel allocation.  The names are
 * the RM's own (NV_CHANNEL_ALLOC_PARAMS) and the types are plain, so a
 * caller can print every field without NVIDIA's headers.  A handle is the
 * RM's own number; 0 is the RM's null handle.
 */
#define NVRM_CHAN_ALLOC_USERDS	8	/* the RM's own count */

typedef struct nvrm_chan_alloc {
	uint32_t	size;		/* sizeof(nvrm_chan_alloc), or 0 when the
				   caller does not know it yet; on return it
				   is sizeof(nvrm_chan_alloc) */
	uint32_t	h_object_error;	/* the error notifier */
	uint32_t	h_object_ecc_error;
	uint32_t	h_object_buffer;
	uint64_t	gp_fifo_offset;
	uint32_t	gp_fifo_entries;
	uint32_t	flags;
	uint32_t	h_context_share;
	uint32_t	h_vaspace;
	uint32_t	h_userd_memory[NVRM_CHAN_ALLOC_USERDS];
	uint64_t	userd_offset[NVRM_CHAN_ALLOC_USERDS];
	uint32_t	engine_type;
	uint32_t	cid;
	uint32_t	sub_device_id;
	uint32_t	internal_flags;
} nvrm_chan_alloc;

int	nvrm_chan_create(nvrm_client *cl, const nvrm_chan_params *p,
	    nvrm_chan **chp);
int	nvrm_chan_submit(nvrm_chan *ch, const nvrm_gp_entry *e, unsigned n,
	    const nvrm_submit_opts *o, nvrm_submit_result *r);
int	nvrm_chan_kick(nvrm_chan *ch);
int	nvrm_chan_gp_space(nvrm_chan *ch, unsigned *n);
/*
 * Wait until the channel's progress semaphore has reached the point.  The
 * timeout_ns is the time the wait may take: 0 means the library's default
 * (NVRM_CHAN_WAIT_DEFAULT_NS) and UINT64_MAX means no limit.  A wait that
 * runs out of time returns NVRM_E_TIMEOUT, and the client's message names
 * what it waited for: the semaphore's address, the point it was waiting
 * for, the value the semaphore holds and the ring's get and put offsets.
 */
int	nvrm_chan_wait(nvrm_chan *ch, uint64_t point, uint64_t timeout_ns);
int	nvrm_chan_status_get(nvrm_chan *ch, nvrm_chan_status *st);
int	nvrm_chan_info_get(const nvrm_chan *ch, nvrm_chan_info *info);
int	nvrm_chan_alloc_get(nvrm_client *cl, nvrm_chan_alloc *out);
void	nvrm_chan_destroy(nvrm_chan *ch);

__END_DECLS

#endif /* _NVRM_NVRM_CHAN_H_ */

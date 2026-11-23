/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * nvrm_fake_chan.c - a software GPFIFO engine for the fake backend.  It reads
 * entries and pushbuffers through the fake software GPU, executes host
 * semaphore methods and pitch copies, and isolates faults to their channel.
 */
#include <sys/types.h>

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "nvrm_internal.h"
#include "nvrm_methods.h"
#include "nvrm_fake.h"

#define RUN_OK		0
#define RUN_WAIT	1
#define RUN_BAD		2

/* Lag mode: entries fetched ahead of the pushbuffer that is running. */
#define LAG_DEPTH	2

typedef struct fake_copy {
	uint64_t	in, out;
	uint32_t	pitch_in, pitch_out, line_length, line_count;
} fake_copy;

struct nvrm_bchan {
	struct nvrm_bchan	*next;
	nvrm_chan	*core;
	uint64_t	ring_va;
	uint32_t	entries, index;
	uint32_t	gp_get, gp_put, error;
	uint32_t	sem_lo, sem_hi, payload_lo, payload_hi;
	uint32_t	granted[8];	/* class granted on each subchannel */
	uint32_t	*pb;
	uint32_t	pb_dwords, pb_pos, pb_next;
	uint32_t	lag_entry[LAG_DEPTH][2]; /* fetched, oldest first */
	unsigned	fetched;	/* lag mode: entries fetched, not run */
	fake_copy	copy;
	nvrm_fake_chan_counts_t counts;
};

static pthread_mutex_t fake_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t fake_cond = PTHREAD_COND_INITIALIZER;
static nvrm_bchan *channels;
static unsigned next_index;
static int manual, lag;
static unsigned read_fail;
static uint64_t progress_count;
void (*nvrm_fake_chan_event_hook)(int);

/* Progress is announced with fake_lock held. */
static void
progress(void)
{
	progress_count++;
	pthread_cond_broadcast(&fake_cond);
}

static void
trace(int event)
{
	if (nvrm_fake_chan_event_hook != NULL)
		nvrm_fake_chan_event_hook(event);
}

static void
fault(nvrm_bchan *b, uint32_t code)
{
	if (b->error == 0) {
		b->error = code;
		progress();
	}
}

static int
gpu_read(nvrm_bchan *b, uint64_t va, void *buf, size_t len)
{
	if (read_fail != 0) {
		read_fail--;
		return (-1);
	}
	if (nvrm_fake_gpu_access(b->core->cl, va, buf, len, 0) == 0)
		return (0);
	fault(b, NVRM_FAKE_CHAN_ERR_MMU);
	return (-1);
}

static int
gpu_write(nvrm_bchan *b, uint64_t va, const void *buf, size_t len)
{
	if (nvrm_fake_gpu_access(b->core->cl, va, (void *)buf, len, 1) == 0)
		return (0);
	fault(b, NVRM_FAKE_CHAN_ERR_MMU);
	return (-1);
}

static int
fake_create(nvrm_bclient *bc, const nvrm_bchan_cfg *cfg, nvrm_bchan **bp,
    nvrm_bchan_info *out, char *err, size_t errlen)
{
	nvrm_bchan *b;

	*bp = NULL;
	b = NVRM_CALLOC(1, sizeof(*b));
	if (b == NULL) {
		snprintf(err, errlen, "out of memory");
		return (NVRM_E_NOMEM);
	}
	memset(out, 0, sizeof(*out));
	out->cls_gpfifo = NVRM_FAKE_CLASS_GPFIFO;
	if ((cfg->engines & NVRM_ENG_3D) != 0)
		out->subch_class[0] = NVRM_FAKE_CLASS_3D;
	if ((cfg->engines & NVRM_ENG_COMPUTE) != 0)
		out->subch_class[1] = NVRM_FAKE_CLASS_COMPUTE;
	if ((cfg->engines & NVRM_ENG_I2M) != 0)
		out->subch_class[2] = NVRM_FAKE_CLASS_I2M;
	if ((cfg->engines & NVRM_ENG_2D) != 0)
		out->subch_class[3] = NVRM_FAKE_CLASS_2D;
	if ((cfg->engines & NVRM_ENG_COPY) != 0)
		out->subch_class[4] = NVRM_FAKE_CLASS_COPY;
	memcpy(b->granted, out->subch_class, sizeof(b->granted));
	b->core = cfg->core;
	b->ring_va = cfg->ring_va;
	b->entries = cfg->entries;
	pthread_mutex_lock(&fake_lock);
	b->index = next_index++;
	b->next = channels;
	channels = b;
	pthread_mutex_unlock(&fake_lock);
	*bp = b;
	return (NVRM_OK);
}

static void
fake_forget(nvrm_bchan *b)
{
	nvrm_bchan **pp;

	pthread_mutex_lock(&fake_lock);
	for (pp = &channels; *pp != b; pp = &(*pp)->next)
		;
	*pp = b->next;
	free(b->pb);
	b->pb = NULL;
	progress();
	pthread_mutex_unlock(&fake_lock);
	free(b);
}

static int
fake_destroy(nvrm_bchan *b, char *err, size_t errlen)
{
	fake_forget(b);
	return (NVRM_OK);
}

static uint32_t
fake_gp_get(nvrm_bchan *b)
{
	uint32_t get;

	pthread_mutex_lock(&fake_lock);
	get = b->gp_get;
	pthread_mutex_unlock(&fake_lock);
	return (get);
}

static void
fake_gp_put(nvrm_bchan *b, uint32_t put)
{
	pthread_mutex_lock(&fake_lock);
	trace(NVRM_CHAN_EV_GP_PUT);
	b->gp_put = put;
	pthread_mutex_unlock(&fake_lock);
}

static uint32_t
fake_error(nvrm_bchan *b)
{
	uint32_t error;

	pthread_mutex_lock(&fake_lock);
	error = b->error;
	pthread_mutex_unlock(&fake_lock);
	return (error);
}

static uint64_t
fake_progress_gen(nvrm_bclient *bc)
{
	uint64_t gen;

	pthread_mutex_lock(&fake_lock);
	gen = progress_count;
	pthread_mutex_unlock(&fake_lock);
	return (gen);
}

static int
fake_wait(nvrm_bclient *bc, uint64_t slice_ns, uint64_t gen)
{
	struct timespec ts;

	(void)clock_gettime(CLOCK_REALTIME, &ts);
	ts.tv_sec += (time_t)(slice_ns / 1000000000ULL);
	ts.tv_nsec += (long)(slice_ns % 1000000000ULL);
	if (ts.tv_nsec >= 1000000000L) {
		ts.tv_sec++;
		ts.tv_nsec -= 1000000000L;
	}
	pthread_mutex_lock(&fake_lock);
	if (progress_count == gen)
		(void)pthread_cond_timedwait(&fake_cond, &fake_lock, &ts);
	pthread_mutex_unlock(&fake_lock);
	return (0);
}

static uint64_t
sem_address(const nvrm_bchan *b)
{
	return ((uint64_t)(b->sem_lo & 0xfffffffcU) |
	    ((uint64_t)(b->sem_hi & 0x1ffffffU) << 32));
}

static uint64_t
sem_payload(const nvrm_bchan *b)
{
	return ((uint64_t)b->payload_lo | ((uint64_t)b->payload_hi << 32));
}

static int
sem_readback(nvrm_bchan *b, int wide, uint64_t *value)
{
	uint32_t lo = 0;

	*value = 0;
	if (wide) {
		if (gpu_read(b, sem_address(b), value, sizeof(*value)) != 0)
			return (RUN_BAD);
	} else {
		if (gpu_read(b, sem_address(b), &lo, sizeof(lo)) != 0)
			return (RUN_BAD);
		*value = lo;
	}
	return (RUN_OK);
}

static int
sem_execute(nvrm_bchan *b, uint32_t data)
{
	uint64_t value, payload = sem_payload(b);
	int wide = (data & NVRM_SEM_PAYLOAD_64) != 0;
	int rc;

	switch (data & 7U) {
	case NVRM_SEM_RELEASE:
		rc = wide ? gpu_write(b, sem_address(b), &payload,
		    sizeof(payload)) : gpu_write(b, sem_address(b), &payload,
		    sizeof(uint32_t));
		if (rc != 0)
			return (RUN_BAD);
		b->counts.releases++;
		progress();
		break;
	case NVRM_SEM_ACQUIRE:
		b->counts.acquires++;
		rc = sem_readback(b, wide, &value);
		if (rc != RUN_OK)
			return (rc);
		if (wide ? value != payload :
		    (uint32_t)value != (uint32_t)payload)
			return (RUN_WAIT);
		break;
	case NVRM_SEM_ACQ_CIRC_GEQ:
		b->counts.acquires++;
		rc = sem_readback(b, wide, &value);
		if (rc != RUN_OK)
			return (rc);
		if (wide) {
			if ((int64_t)(value - payload) < 0)
				return (RUN_WAIT);
		} else if ((int32_t)((uint32_t)value - (uint32_t)payload) < 0)
			return (RUN_WAIT);
		break;
	default:
		b->counts.ignored++;
		break;
	}
	return (RUN_OK);
}

static int
host_method(nvrm_bchan *b, unsigned subch, unsigned off, uint32_t data)
{
	switch (off) {
	case NVRM_MTHD_SET_OBJECT:
		if (data != 0 && data != b->granted[subch]) {
			fault(b, NVRM_FAKE_CHAN_ERR_UNSUPPORTED);
			return (RUN_BAD);
		}
		break;
	case NVRM_MTHD_NOP:
		b->counts.nops++;
		break;
	case NVRM_MTHD_SEM_ADDR_LO:
		b->sem_lo = data;
		break;
	case NVRM_MTHD_SEM_ADDR_HI:
		b->sem_hi = data;
		break;
	case NVRM_MTHD_SEM_PAYLOAD_LO:
		b->payload_lo = data;
		break;
	case NVRM_MTHD_SEM_PAYLOAD_HI:
		b->payload_hi = data;
		break;
	case NVRM_MTHD_SEM_EXECUTE:
		return (sem_execute(b, data));
	case NVRM_MTHD_WFI:
		break;
	default:
		b->counts.ignored++;
		break;
	}
	return (RUN_OK);
}

static int
copy_line(nvrm_bchan *b, uint64_t in, uint64_t out, uint32_t bytes)
{
	uint8_t buf[4096];
	uint32_t n;

	while (bytes != 0) {
		n = bytes > sizeof(buf) ? sizeof(buf) : bytes;
		if (gpu_read(b, in, buf, n) != 0 || gpu_write(b, out, buf, n) != 0)
			return (-1);
		in += n;
		out += n;
		bytes -= n;
		b->counts.bytes_copied += n;
	}
	return (0);
}

#define COPY_UNSUPPORTED_BITS	(NVRM_FAKE_COPY_LAUNCH_SEMAPHORE | \
	NVRM_FAKE_COPY_LAUNCH_REMAP | NVRM_FAKE_COPY_LAUNCH_SRC_PHYSICAL | \
	NVRM_FAKE_COPY_LAUNCH_DST_PHYSICAL | NVRM_FAKE_COPY_LAUNCH_SCRUB)
#define COPY_PITCH_BITS		(NVRM_FAKE_COPY_LAUNCH_SRC_PITCH | \
	NVRM_FAKE_COPY_LAUNCH_DST_PITCH)

static int
copy_launch(nvrm_bchan *b, uint32_t data)
{
	uint32_t type = data & NVRM_FAKE_COPY_TYPE_MASK;
	uint32_t lines, i;
	uint64_t in, out;

	if ((data & COPY_UNSUPPORTED_BITS) != 0 ||
	    (data & COPY_PITCH_BITS) != COPY_PITCH_BITS ||
	    type == NVRM_FAKE_COPY_TYPE_INVALID) {
		fault(b, NVRM_FAKE_CHAN_ERR_UNSUPPORTED);
		return (RUN_BAD);
	}
	b->counts.copies++;
	if (type == NVRM_FAKE_COPY_TYPE_NONE)
		return (RUN_OK);
	lines = (data & NVRM_FAKE_COPY_LAUNCH_MULTI_LINE) != 0 ?
	    b->copy.line_count : 1;
	for (i = 0; i < lines; i++) {
		in = b->copy.in + (uint64_t)i * b->copy.pitch_in;
		out = b->copy.out + (uint64_t)i * b->copy.pitch_out;
		if (copy_line(b, in, out, b->copy.line_length) != 0)
			return (RUN_BAD);
	}
	return (RUN_OK);
}

static int
copy_method(nvrm_bchan *b, unsigned off, uint32_t data)
{
	switch (off) {
	case NVRM_FAKE_COPY_OFFSET_IN_UPPER:
		b->copy.in = (b->copy.in & 0xffffffffULL) |
		    ((uint64_t)(data & 0x1ffffffU) << 32);
		break;
	case NVRM_FAKE_COPY_OFFSET_IN_LOWER:
		b->copy.in = (b->copy.in & ~0xffffffffULL) | data;
		break;
	case NVRM_FAKE_COPY_OFFSET_OUT_UPPER:
		b->copy.out = (b->copy.out & 0xffffffffULL) |
		    ((uint64_t)(data & 0x1ffffffU) << 32);
		break;
	case NVRM_FAKE_COPY_OFFSET_OUT_LOWER:
		b->copy.out = (b->copy.out & ~0xffffffffULL) | data;
		break;
	case NVRM_FAKE_COPY_PITCH_IN:
		b->copy.pitch_in = data;
		break;
	case NVRM_FAKE_COPY_PITCH_OUT:
		b->copy.pitch_out = data;
		break;
	case NVRM_FAKE_COPY_LINE_LENGTH_IN:
		b->copy.line_length = data;
		break;
	case NVRM_FAKE_COPY_LINE_COUNT:
		b->copy.line_count = data;
		break;
	case NVRM_FAKE_COPY_LAUNCH_DMA:
		return (copy_launch(b, data));
	default:
		b->counts.ignored++;
		break;
	}
	return (RUN_OK);
}

static int
run_method(nvrm_bchan *b, unsigned subch, unsigned off, uint32_t data)
{
	b->counts.methods++;
	if (off < 0x100)
		return (host_method(b, subch, off, data));
	if (subch == 4 && b->granted[4] == NVRM_FAKE_CLASS_COPY)
		return (copy_method(b, off, data));
	b->counts.ignored++;
	return (RUN_OK);
}

/* Run one header.  A waiting acquire leaves pb_pos on its header, so the
 * acquire is retried after another channel makes progress. */
static int
run_frame(nvrm_bchan *b)
{
	uint32_t hdr = b->pb[b->pb_pos];
	unsigned pos = b->pb_pos;
	unsigned op = nvrm_method_op(hdr);
	unsigned subch = nvrm_method_subch(hdr);
	unsigned off = nvrm_method_address(hdr);
	unsigned count = nvrm_method_count(hdr);
	unsigned i, at;
	int rc = RUN_OK;

	if (op == NVRM_MTHD_OP_IMMD) {
		rc = run_method(b, subch, off, count);
		b->pb_pos = rc == RUN_WAIT ? pos : pos + 1;
		return (rc);
	}
	if (op != NVRM_MTHD_OP_INC && op != NVRM_MTHD_OP_NON_INC &&
	    op != NVRM_MTHD_OP_ONE_INC) {
		fault(b, NVRM_FAKE_CHAN_ERR_UNSUPPORTED);
		return (RUN_BAD);
	}
	if (count > b->pb_dwords - pos - 1) {
		fault(b, NVRM_FAKE_CHAN_ERR_UNSUPPORTED);
		return (RUN_BAD);
	}
	for (i = b->pb_next; i < count; i++) {
		at = op == NVRM_MTHD_OP_NON_INC ? off :
		    off + 4 * (op == NVRM_MTHD_OP_ONE_INC ? (i != 0) : i);
		rc = run_method(b, subch, at, b->pb[pos + 1 + i]);
		if (rc != RUN_OK) {
			b->pb_pos = rc == RUN_WAIT ? pos : pos + 1 + i;
			b->pb_next = rc == RUN_WAIT ? i : 0;
			return (rc);
		}
	}
	b->pb_next = 0;
	b->pb_pos = pos + 1 + count;
	return (RUN_OK);
}

static int
load_entry(nvrm_bchan *b)
{
	uint32_t entry[2];
	uint64_t va;
	uint32_t dwords;
	size_t bytes;

	if (b->fetched)
		memcpy(entry, b->lag_entry[0], sizeof(entry));
	else if (gpu_read(b, b->ring_va + (uint64_t)b->gp_get * 8, entry,
	    sizeof(entry)) != 0)
		return (NVRM_E_RM);
	va = nvrm_gp_decode_va(entry[0], entry[1]);
	dwords = nvrm_gp_decode_dwords(entry[1]);
	bytes = (size_t)dwords * sizeof(uint32_t);
	b->pb = NVRM_CALLOC(1, bytes);
	if (b->pb == NULL)
		return (NVRM_E_NOMEM);
	if (gpu_read(b, va, b->pb, bytes) != 0) {
		free(b->pb);
		b->pb = NULL;
		return (NVRM_E_RM);
	}
	b->pb_dwords = dwords;
	b->pb_pos = 0;
	return (NVRM_OK);
}

/* Lag mode: GP_GET moves when an entry is fetched, and the pushbuffer runs
 * later, as on hardware that fetches ahead of the engine.  A read that fails
 * leaves the entry where it is: the fetch is retried and the ring position
 * does not move past an entry the GPU never saw. */
static int
fetch_entry(nvrm_bchan *b)
{
	if (gpu_read(b, b->ring_va + (uint64_t)b->gp_get * 8,
	    b->lag_entry[b->fetched], sizeof(b->lag_entry[0])) != 0)
		return (NVRM_E_RM);
	b->fetched++;
	b->gp_get = (b->gp_get + 1) & (b->entries - 1);
	return (NVRM_OK);
}

/* The entry is finished: the ring position moves now, unless lag mode moved
 * it at the fetch. */
static void
finish_entry(nvrm_bchan *b)
{
	free(b->pb);
	b->pb = NULL;
	if (b->fetched != 0) {
		b->fetched--;
		memmove(b->lag_entry[0], b->lag_entry[1],
		    sizeof(b->lag_entry) - sizeof(b->lag_entry[0]));
	} else
		b->gp_get = (b->gp_get + 1) & (b->entries - 1);
	b->counts.entries++;
}

/* Run the pushbuffer that is loaded, frame by frame.  A wait or a fault on
 * the channel ends the run. */
static int
run_loaded(nvrm_bchan *b)
{
	int rc;

	while (b->pb_pos < b->pb_dwords) {
		rc = run_frame(b);
		if (rc == RUN_WAIT)
			return (RUN_WAIT);
		if (rc == RUN_BAD)
			return (RUN_BAD);
	}
	return (RUN_OK);
}

static int
run_entries(nvrm_bchan *b, unsigned max_entries)
{
	unsigned done = 0;
	int rc;

	/* The engine of a client this process does not own is not run: a fork
	 * child must not touch the parent's channel. */
	if (!nvrm_owner_is_me(&b->core->cl->owner))
		return (NVRM_E_DENIED);
	while (done < max_entries && (b->gp_get != b->gp_put || b->fetched) &&
	    b->error == 0) {
		if (lag && b->fetched < LAG_DEPTH && b->gp_get != b->gp_put) {
			rc = fetch_entry(b);
			if (rc != NVRM_OK)	/* a fault is on the channel */
				return (NVRM_OK);
			done++;
			progress();
			continue;
		}
		if (b->pb == NULL) {
			rc = load_entry(b);
			if (rc != NVRM_OK)	/* a fault is on the channel */
				return (rc == NVRM_E_NOMEM ? rc : NVRM_OK);
		}
		rc = run_loaded(b);
		if (rc != RUN_OK)	/* a wait or a fault on the channel */
			return (NVRM_OK);
		finish_entry(b);
		done++;
		progress();
	}
	return (NVRM_OK);
}

/* Where a channel stands: one value that changes on every step. */
static uint64_t
position(const nvrm_bchan *b)
{
	return ((uint64_t)b->gp_get * (LAG_DEPTH + 1) + b->fetched);
}

/* Run every channel until none moves.  A channel of a client this process
 * does not own is not run: run_entries refuses it. */
static void
run_auto(void)
{
	nvrm_bchan *b;
	uint64_t before;
	int again;

	do {
		again = 0;
		for (b = channels; b != NULL; b = b->next) {
			before = position(b);
			(void)run_entries(b, b->entries);
			if (before != position(b))
				again = 1;
		}
	} while (again != 0);
}

static void
fake_doorbell(nvrm_bchan *b)
{
	pthread_mutex_lock(&fake_lock);
	trace(NVRM_CHAN_EV_DOORBELL);
	b->counts.doorbells++;
	if (!manual)
		run_auto();
	pthread_mutex_unlock(&fake_lock);
}

void
nvrm_fake_chan_manual(int on)
{
	pthread_mutex_lock(&fake_lock);
	manual = on;
	pthread_mutex_unlock(&fake_lock);
}

void
nvrm_fake_chan_lag(int on)
{
	pthread_mutex_lock(&fake_lock);
	lag = on;
	pthread_mutex_unlock(&fake_lock);
}

int
nvrm_fake_chan_step(nvrm_chan *ch, unsigned max_entries)
{
	int rc;

	pthread_mutex_lock(&fake_lock);
	rc = run_entries(ch->b, max_entries);
	pthread_mutex_unlock(&fake_lock);
	return (rc);
}

/* Make the next nth GPU reads fail (0 disarms it).  A read error is not a
 * fault: the channel stays alive and the work is read again. */
void
nvrm_fake_chan_read_fail(unsigned nth)
{
	pthread_mutex_lock(&fake_lock);
	read_fail = nth;
	pthread_mutex_unlock(&fake_lock);
}

void
nvrm_fake_chan_fault(nvrm_chan *ch, uint32_t code)
{
	pthread_mutex_lock(&fake_lock);
	fault(ch->b, code);
	pthread_mutex_unlock(&fake_lock);
}

nvrm_fake_chan_counts_t
nvrm_fake_chan_counts(nvrm_chan *ch)
{
	nvrm_fake_chan_counts_t counts;

	pthread_mutex_lock(&fake_lock);
	counts = ch->b->counts;
	pthread_mutex_unlock(&fake_lock);
	return (counts);
}

nvrm_chan_ops nvrm_fake_chan_ops = {
	.copy_on_graphics = 1,
	.create = fake_create,
	.destroy = fake_destroy,
	.forget = fake_forget,
	.gp_get = fake_gp_get,
	.gp_put = fake_gp_put,
	.doorbell = fake_doorbell,
	.error = fake_error,
	.progress_gen = fake_progress_gen,
	.wait = fake_wait,
};

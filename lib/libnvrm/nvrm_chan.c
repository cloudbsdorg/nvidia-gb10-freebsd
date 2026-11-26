/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * nvrm_chan.c - backend-neutral GPFIFO channels.  The core validates and
 * orders submissions, owns the ring and progress semaphore, and publishes
 * each batch with a fixed barrier sequence.  A backend only operates USERD,
 * rings the doorbell, reports errors and provides a timed sleep.
 */
#include <sys/types.h>

#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "nvrm_internal.h"
#include "nvrm_barrier.h"
#include "nvrm_methods.h"

void (*nvrm_barrier_hook)(int);
void (*nvrm_chan_presleep_hook)(void);
uint64_t nvrm_chan_slice_ns = NVRM_CHAN_SLICE_DEFAULT_NS;

/*
 * The client's message belongs to its most recent call.  Channel calls on
 * several threads may all clear and write it, so every clear and write goes
 * through the client's errlock.  The *_locked forms are for code that
 * already holds it (create and destroy hold it for the whole call, because
 * the memory calls they make write the message without a lock).  Lock order:
 * a channel's lock, then the client's errlock.
 */
static int
fail_locked(nvrm_client *cl, int rc, const char *fmt, ...)
{
	va_list ap;

	va_start(ap, fmt);
	vsnprintf(cl->errmsg, sizeof(cl->errmsg), fmt, ap);
	va_end(ap);
	return (rc);
}

static int
fail(nvrm_client *cl, int rc, const char *fmt, ...)
{
	va_list ap;

	(void)pthread_mutex_lock(&cl->errlock);
	va_start(ap, fmt);
	vsnprintf(cl->errmsg, sizeof(cl->errmsg), fmt, ap);
	va_end(ap);
	(void)pthread_mutex_unlock(&cl->errlock);
	return (rc);
}

static void
clear_err(nvrm_client *cl)
{
	(void)pthread_mutex_lock(&cl->errlock);
	cl->errmsg[0] = '\0';
	(void)pthread_mutex_unlock(&cl->errlock);
}

static int
size_ok(uint32_t size, size_t want)
{
	return (size == 0 || size == want);
}

#define DENIED_FMT "this process did not open the client (it is a fork() " \
	"child): it may only release what it holds and close the client"

static int
owner_check(nvrm_client *cl)
{
	if (nvrm_owner_is_me(&cl->owner))
		return (NVRM_OK);
	return (fail(cl, NVRM_E_DENIED, DENIED_FMT));
}

static int
owner_check_locked(nvrm_client *cl)
{
	if (nvrm_owner_is_me(&cl->owner))
		return (NVRM_OK);
	return (fail_locked(cl, NVRM_E_DENIED, DENIED_FMT));
}

static uint64_t
now_ns(void)
{
	struct timespec ts;

	(void)clock_gettime(CLOCK_MONOTONIC, &ts);
	return ((uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec);
}

static uint64_t
make_deadline(uint64_t timeout_ns)
{
	uint64_t now;

	if (timeout_ns == UINT64_MAX)
		return (UINT64_MAX);
	now = now_ns();
	return (timeout_ns > UINT64_MAX - now ? UINT64_MAX : now + timeout_ns);
}

static int
deadline_reached(uint64_t deadline)
{
	return (deadline != UINT64_MAX && now_ns() >= deadline);
}

/* The turn condition runs on the monotonic clock, like every deadline here. */
static void
init_turn(nvrm_chan *ch)
{
	pthread_condattr_t attr;

	(void)pthread_condattr_init(&attr);
	(void)pthread_condattr_setclock(&attr, CLOCK_MONOTONIC);
	(void)pthread_cond_init(&ch->turn, &attr);
	(void)pthread_condattr_destroy(&attr);
}

static void
queue_join(nvrm_chan *ch, nvrm_chan_waiter *w)
{
	w->next = NULL;
	if (ch->q_tail == NULL)
		ch->q_head = w;
	else
		ch->q_tail->next = w;
	ch->q_tail = w;
}

/* Remove a record wherever it stands and wake every queued submitter. */
static void
queue_leave(nvrm_chan *ch, nvrm_chan_waiter *w)
{
	nvrm_chan_waiter *prev = NULL, *it;

	for (it = ch->q_head; it != w; it = it->next)
		prev = it;
	if (prev == NULL)
		ch->q_head = w->next;
	else
		prev->next = w->next;
	if (ch->q_tail == w)
		ch->q_tail = prev;
	(void)pthread_cond_broadcast(&ch->turn);
}

/* A queued submitter waits on the turn condition up to its own deadline. */
static int
wait_turn(nvrm_chan *ch, uint64_t deadline)
{
	struct timespec ts;

	if (deadline_reached(deadline))
		return (fail(ch->cl, NVRM_E_TIMEOUT, "timed out waiting for "
		    "earlier submits on the channel"));
	if (deadline == UINT64_MAX)
		(void)pthread_cond_wait(&ch->turn, &ch->lock);
	else {
		ts.tv_sec = (time_t)(deadline / 1000000000ULL);
		ts.tv_nsec = (long)(deadline % 1000000000ULL);
		(void)pthread_cond_timedwait(&ch->turn, &ch->lock, &ts);
	}
	return (NVRM_OK);
}

/* How long to sleep: a slice, but never past a finite deadline. */
static uint64_t
sleep_ns(uint64_t deadline)
{
	uint64_t now, left;

	if (deadline == UINT64_MAX)
		return (nvrm_chan_slice_ns);
	now = now_ns();
	/* zero when the deadline has passed since the caller looked */
	left = (deadline - now) & -(uint64_t)(now < deadline);
	return (left < nvrm_chan_slice_ns ? left : nvrm_chan_slice_ns);
}

/* Sleep until progress or the slice ends.  gen is the backend's progress
 * count as read before the caller's check: a change since then returns at
 * once, so a wakeup between the check and the sleep is not lost. */
static void
sleep_for_progress(nvrm_chan *ch, uint64_t gen, uint64_t deadline)
{
	(void)pthread_mutex_unlock(&ch->lock);
	if (nvrm_chan_presleep_hook != NULL)
		nvrm_chan_presleep_hook();
	(void)ch->cl->ops->chan->wait(ch->cl->bc, sleep_ns(deadline), gen);
	(void)pthread_mutex_lock(&ch->lock);
}

static uint64_t
sem_read(const nvrm_chan *ch)
{
	const uint64_t *p = (const uint64_t *)((const char *)ch->cpu +
	    NVRM_CHAN_SEM_OFF(ch->entries));

	return (__atomic_load_n(p, __ATOMIC_ACQUIRE));
}

/* The first error wins; the state follows it. */
static void
mark_dead(nvrm_chan *ch, uint32_t error)
{
	uint32_t none = 0;

	if (__atomic_compare_exchange_n(&ch->error, &none, error, 0,
	    __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE))
		__atomic_store_n(&ch->state, NVRM_CHAN_DEAD, __ATOMIC_RELEASE);
}

/* Refresh a live channel.  Peer refreshes use atomics because each channel's
 * own calls are serialized by its own mutex, not by the caller's mutex. */
static void
refresh(nvrm_chan *ch)
{
	const nvrm_chan_ops *ops = ch->cl->ops->chan;
	uint32_t error;

	if (__atomic_load_n(&ch->state, __ATOMIC_ACQUIRE) != NVRM_CHAN_ALIVE)
		return;
	__atomic_store_n(&ch->gp_get, ops->gp_get(ch->b), __ATOMIC_RELEASE);
	error = ops->error(ch->b);
	if (error != 0)
		mark_dead(ch, error);
}

/* The progress semaphore is GPU-writable: a value above the submitted point
 * or below the completed one cannot be progress, and kills the channel. */
static void
sem_update(nvrm_chan *ch)
{
	uint64_t value = sem_read(ch);

	if (value == ch->completed)
		return;
	if (value > ch->submitted || value < ch->completed)
		mark_dead(ch, NVRM_CHAN_ERR_SEMAPHORE);
	else
		ch->completed = value;
}

/* A fork child keeps the state it has: it makes no backend call and reads no
 * mapping of the parent's. */
static void
refresh_all(nvrm_chan *ch)
{
	nvrm_chan *it;

	if (!nvrm_owner_is_me(&ch->cl->owner))
		return;
	for (it = ch->cl->channels; it != NULL; it = it->next)
		refresh(it);
	sem_update(ch);
}

static int
is_dead(nvrm_chan *ch)
{
	return (__atomic_load_n(&ch->state, __ATOMIC_ACQUIRE) ==
	    NVRM_CHAN_DEAD);
}

static int
lost(nvrm_chan *ch)
{
	return (fail(ch->cl, NVRM_E_LOST, "the channel is dead (error "
	    "notifier %u): destroy it and create a new channel",
	    __atomic_load_n(&ch->error, __ATOMIC_ACQUIRE)));
}

/* The ring slots GP_GET has passed, less the E-2 rule. */
static unsigned
ring_space(nvrm_chan *ch)
{
	uint32_t get = __atomic_load_n(&ch->gp_get, __ATOMIC_ACQUIRE);
	unsigned pending = (ch->gp_put - get) & (ch->entries - 1);

	if (pending >= ch->entries - 1)
		return (0);
	return (ch->entries - 2 - pending);
}

/*
 * The caller entries a batch may place.  GP_GET moves when the GPU fetches a
 * ring entry, which can be before it reads the pushbuffer that entry names,
 * so the slot of a core release is free again only when the progress
 * semaphore has reached that release.  The slots a batch of ring_space()
 * entries and its release would write are checked from GP_PUT on, and the
 * batch ends before the first slot whose release has not run.
 */
static unsigned
space_locked(nvrm_chan *ch)
{
	unsigned space = ring_space(ch), run, slot;

	for (run = 0; run <= space; run++) {
		slot = (ch->gp_put + run) & (ch->entries - 1);
		if (ch->slot_point[slot] > ch->completed)
			break;
	}
	return (run - (run != 0));
}

static int
check_create(nvrm_chan *ch, const nvrm_chan_params *p)
{
	nvrm_client *cl = ch->cl;
	uint32_t entries;

	if (!size_ok(p->size, sizeof(*p)))
		return (fail_locked(cl, NVRM_E_INVAL, "nvrm_chan_params.size "
		    "must be 0 or sizeof(nvrm_chan_params)"));
	if (p->engines == 0 || (p->engines & ~NVRM_ENG_KNOWN) != 0)
		return (fail_locked(cl, NVRM_E_INVAL, "engines must be a "
		    "nonzero subset of NVRM_ENG_KNOWN"));
	if (p->flags != 0)
		return (fail_locked(cl, NVRM_E_INVAL, "unknown channel flags"));
	entries = p->entries != 0 ? p->entries : NVRM_CHAN_ENTRIES_DEFAULT;
	if (entries < NVRM_CHAN_ENTRIES_MIN ||
	    entries > NVRM_CHAN_ENTRIES_MAX || (entries & (entries - 1)) != 0)
		return (fail_locked(cl, NVRM_E_INVAL, "entries must be a "
		    "power of two between %u and %u", NVRM_CHAN_ENTRIES_MIN,
		    NVRM_CHAN_ENTRIES_MAX));
	ch->engines = p->engines;
	ch->entries = entries;
	ch->runlist = (p->engines & (NVRM_ENG_3D | NVRM_ENG_COMPUTE |
	    NVRM_ENG_I2M | NVRM_ENG_2D)) != 0 ? NVRM_RUNLIST_GRAPHICS :
	    NVRM_RUNLIST_COPY;
	return (NVRM_OK);
}

static void
create_unwind(nvrm_chan *ch)
{
	if (ch->cpu != NULL)
		(void)nvrm_mem_unmap_cpu(ch->mem);
	if (ch->mem != NULL)
		nvrm_mem_free(ch->mem);
	if (ch->ring_va != 0)
		(void)nvrm_va_release(ch->cl, ch->ring_va);
}

/*
 * The ring and the release segments are read-only for the GPU: a pushbuffer
 * that writes there faults the channel instead of rewriting later work.  The
 * progress semaphore is a mapping of its own page of the same object,
 * read-write.
 */
static int
create_memory(nvrm_chan *ch)
{
	nvrm_client *cl = ch->cl;
	uint64_t bytes = NVRM_CHAN_BYTES(ch->entries);
	uint64_t sem_off = NVRM_CHAN_SEM_OFF(ch->entries);
	nvrm_va_params vp = { .bytes = bytes };
	nvrm_mem_params mp = { .kind = NVRM_MEM_SYSMEM, .bytes = bytes };
	nvrm_gpu_map_params gp;
	int rc;

	rc = nvrm_va_reserve(cl, &vp, &ch->ring_va);
	if (rc == NVRM_OK)
		rc = nvrm_mem_alloc(cl, &mp, &ch->mem);
	if (rc != NVRM_OK)
		return (rc);
	gp = (nvrm_gpu_map_params){ .va = ch->ring_va, .length = sem_off,
	    .flags = NVRM_MAP_READ_ONLY };
	rc = nvrm_mem_map_gpu(ch->mem, &gp);
	if (rc != NVRM_OK)
		return (rc);
	ch->sem_va = ch->ring_va + sem_off;
	gp = (nvrm_gpu_map_params){ .va = ch->sem_va, .offset = sem_off,
	    .length = NVRM_CHAN_PAGE };
	rc = nvrm_mem_map_gpu(ch->mem, &gp);
	if (rc != NVRM_OK)
		return (rc);
	rc = nvrm_mem_map_cpu(ch->mem, NVRM_CPU_READ | NVRM_CPU_WRITE,
	    &ch->cpu);
	if (rc != NVRM_OK)
		return (rc);
	memset(ch->cpu, 0, bytes);
	return (NVRM_OK);
}

/* Free the core record: the memory it owned is already released. */
static void
chan_free(nvrm_chan *ch)
{
	(void)pthread_cond_destroy(&ch->turn);
	(void)pthread_mutex_destroy(&ch->lock);
	free(ch->slot_point);
	free(ch);
}

static int
create_locked(nvrm_client *cl, const nvrm_chan_params *p, nvrm_chan **chp)
{
	nvrm_bchan_cfg cfg;
	nvrm_chan *ch;
	char saved[sizeof(cl->errmsg)];
	int rc;

	cl->errmsg[0] = '\0';
	rc = owner_check_locked(cl);
	if (rc != NVRM_OK)
		return (rc);
	if (cl->ops->chan == NULL)
		return (fail_locked(cl, NVRM_E_NOTSUP, "the backend has no "
		    "channels"));
	if (cl->ops->chan->destroy == NULL || cl->ops->chan->forget == NULL)
		return (fail_locked(cl, NVRM_E_NOTSUP, "the backend has no "
		    "channel destroy or forget operation"));
	ch = NVRM_CALLOC(1, sizeof(*ch));
	if (ch == NULL)
		return (fail_locked(cl, NVRM_E_NOMEM, "out of memory"));
	ch->cl = cl;
	(void)pthread_mutex_init(&ch->lock, NULL);
	init_turn(ch);
	rc = check_create(ch, p);
	if (rc != NVRM_OK)
		goto bad;
	ch->slot_point = NVRM_CALLOC(ch->entries, sizeof(*ch->slot_point));
	if (ch->slot_point == NULL) {
		rc = fail_locked(cl, NVRM_E_NOMEM, "out of memory");
		goto bad;
	}
	if (!cl->allow_map) {
		rc = fail_locked(cl, NVRM_E_DENIED, "open the client with "
		    "NVRM_OPEN_ALLOW_MAP to create a channel");
		goto bad;
	}
	if (ch->runlist == NVRM_RUNLIST_GRAPHICS &&
	    (ch->engines & NVRM_ENG_COPY) != 0 &&
	    !cl->ops->chan->copy_on_graphics) {
		rc = fail_locked(cl, NVRM_E_NOTSUP, "the backend cannot bind "
		    "the copy class on a graphics-runlist channel");
		goto bad;
	}
	rc = create_memory(ch);
	if (rc != NVRM_OK)
		goto bad;
	cfg = (nvrm_bchan_cfg){ .engines = ch->engines, .entries = ch->entries,
	    .runlist = ch->runlist, .ring_va = ch->ring_va, .core = ch };
	rc = cl->ops->chan->create(cl->bc, &cfg, &ch->b, &ch->info,
	    cl->errmsg, sizeof(cl->errmsg));
	if (rc != NVRM_OK)
		goto bad;
	ch->state = NVRM_CHAN_ALIVE;
	ch->next = cl->channels;
	cl->channels = ch;
	cl->st.live_channels++;
	cl->st.channels_created++;
	*chp = ch;
	return (NVRM_OK);

bad:
	strlcpy(saved, cl->errmsg, sizeof(saved));
	create_unwind(ch);
	chan_free(ch);
	strlcpy(cl->errmsg, saved, sizeof(cl->errmsg));
	return (rc);
}

int
nvrm_chan_create(nvrm_client *cl, const nvrm_chan_params *p, nvrm_chan **chp)
{
	int rc;

	*chp = NULL;
	(void)pthread_mutex_lock(&cl->errlock);
	rc = create_locked(cl, p, chp);
	(void)pthread_mutex_unlock(&cl->errlock);
	return (rc);
}

static int
check_submit_opts(nvrm_chan *ch, const nvrm_submit_opts *o, uint32_t *flags,
    uint64_t *timeout)
{
	if (o == NULL) {
		*flags = 0;
		*timeout = UINT64_MAX;
		return (NVRM_OK);
	}
	if (!size_ok(o->size, sizeof(*o)))
		return (fail(ch->cl, NVRM_E_INVAL, "nvrm_submit_opts.size "
		    "must be 0 or sizeof(nvrm_submit_opts)"));
	if ((o->flags & ~NVRM_SUBMIT_NO_KICK) != 0)
		return (fail(ch->cl, NVRM_E_INVAL, "unknown submit flags"));
	*flags = o->flags;
	*timeout = o->timeout_ns;
	return (NVRM_OK);
}

/* The length of the indivisible unit that starts at pos: an INCOMPLETE run
 * and its terminator. */
static unsigned
unit_len(const nvrm_gp_entry *e, unsigned n, unsigned pos)
{
	unsigned len = 1;

	while (pos + len < n &&
	    (e[pos + len - 1].flags & NVRM_GP_INCOMPLETE) != 0)
		len++;
	return (len);
}

static int
check_elements(nvrm_chan *ch, const nvrm_gp_entry *e, unsigned n)
{
	unsigned i, run;

	if (n == 0)
		return (fail(ch->cl, NVRM_E_INVAL, "a submit needs at least "
		    "one element"));
	for (i = 0; i < n; i++) {
		if (e[i].va == 0 || (e[i].va & 3) != 0 ||
		    e[i].va >= (1ULL << 40))
			return (fail(ch->cl, NVRM_E_INVAL, "element %u has "
			    "an invalid GPU address", i));
		if (e[i].dwords == 0 || e[i].dwords >= (1U << 21))
			return (fail(ch->cl, NVRM_E_INVAL, "element %u has "
			    "an invalid dword count", i));
		if ((e[i].flags & ~NVRM_GP_KNOWN) != 0)
			return (fail(ch->cl, NVRM_E_INVAL, "element %u has "
			    "unknown flags", i));
	}
	if ((e[n - 1].flags & NVRM_GP_INCOMPLETE) != 0)
		return (fail(ch->cl, NVRM_E_INVAL, "element %u is INCOMPLETE "
		    "without a terminator", n - 1));
	for (i = 0; i < n; i += run) {
		run = unit_len(e, n, i);
		if (run > ch->entries - 2)
			return (fail(ch->cl, NVRM_E_INVAL, "the INCOMPLETE "
			    "run starting at element %u needs %u slots; at "
			    "most %u fit in a batch", i, run, ch->entries - 2));
	}
	return (NVRM_OK);
}

static unsigned
batch_len(const nvrm_gp_entry *e, unsigned n, unsigned pos, unsigned limit)
{
	unsigned len = 0, unit;

	while (pos + len < n) {
		unit = unit_len(e, n, pos + len);
		if (len + unit > limit)
			break;
		len += unit;
	}
	return (len);
}

/* Publish one batch.  Its last ring entry runs the host release segment. */
static void
place_batch(nvrm_chan *ch, const nvrm_gp_entry *e, unsigned n,
    uint32_t flags, nvrm_submit_result *r)
{
	uint32_t *ring = (uint32_t *)((char *)ch->cpu +
	    NVRM_CHAN_RING_OFF(ch->entries));
	uint32_t idx, put;
	uint64_t point, seg_va;
	unsigned i, dwords;

	for (i = 0; i < n; i++) {
		idx = (ch->gp_put + i) & (ch->entries - 1);
		ring[idx * 2] = nvrm_gp_entry0(e[i].va);
		ring[idx * 2 + 1] = nvrm_gp_entry1(e[i].va, e[i].dwords,
		    (e[i].flags & NVRM_GP_NO_PREFETCH) != 0);
		ch->slot_point[idx] = 0;
	}
	idx = (ch->gp_put + n) & (ch->entries - 1);
	put = (idx + 1) & (ch->entries - 1);
	point = ++ch->submitted;
	dwords = nvrm_release_segment((uint32_t *)((char *)ch->cpu +
	    NVRM_CHAN_SEG_OFF(ch->entries, idx)), ch->sem_va, point);
	seg_va = ch->ring_va + NVRM_CHAN_SEG_OFF(ch->entries, idx);
	ring[idx * 2] = nvrm_gp_entry0(seg_va);
	ring[idx * 2 + 1] = nvrm_gp_entry1(seg_va, dwords, 0);
	ch->slot_point[idx] = point;
	ch->gp_put = put;
	nvrm_barrier_normal();
	ch->cl->ops->chan->gp_put(ch->b, put);
	nvrm_barrier_device();
	if ((flags & NVRM_SUBMIT_NO_KICK) != 0)
		ch->kick_pending = 1;
	else {
		ch->cl->ops->chan->doorbell(ch->b);
		ch->kick_pending = 0;
	}
	r->accepted += n;
	r->point = point;
	refresh_all(ch);
}

/* Ring the doorbell for work published without one. */
static void
kick_locked(nvrm_chan *ch)
{
	nvrm_barrier_device();
	ch->cl->ops->chan->doorbell(ch->b);
	ch->kick_pending = 0;
}

/* The state of one submit call, under the channel lock. */
typedef struct submit_ctx {
	nvrm_chan_waiter w;
	const nvrm_gp_entry *e;
	nvrm_submit_result *r;
	uint64_t	deadline;
	unsigned	n, pos;
	uint32_t	flags;
} submit_ctx;

enum { STEP_DONE, STEP_AGAIN, STEP_SLEEP };

/* One pass of a submit: place what fits when this call heads the queue.
 * STEP_DONE ends the call with *rc; STEP_SLEEP waits for progress. */
static int
submit_step(nvrm_chan *ch, submit_ctx *sc, int *rc)
{
	unsigned count, space, limit;

	if (is_dead(ch)) {
		*rc = lost(ch);
		return (STEP_DONE);
	}
	if (ch->q_head != &sc->w) {
		*rc = wait_turn(ch, sc->deadline);
		return (*rc == NVRM_OK ? STEP_AGAIN : STEP_DONE);
	}
	*rc = NVRM_OK;
	if (sc->pos == sc->n)
		return (STEP_DONE);
	space = space_locked(ch);
	limit = space < ch->entries - 2 ? space : ch->entries - 2;
	count = batch_len(sc->e, sc->n, sc->pos, limit);
	if (count != 0) {
		place_batch(ch, sc->e + sc->pos, count, sc->flags, sc->r);
		sc->pos += count;
		return (STEP_AGAIN);
	}
	if (ch->kick_pending) {
		/* Work published without a doorbell is what holds the ring:
		 * ring it before waiting, or nothing will ever drain it. */
		kick_locked(ch);
		return (STEP_AGAIN);
	}
	if (!deadline_reached(sc->deadline))
		return (STEP_SLEEP);
	*rc = fail(ch->cl, NVRM_E_TIMEOUT, "timed out waiting for GPFIFO "
	    "ring space");
	return (STEP_DONE);
}

int
nvrm_chan_submit(nvrm_chan *ch, const nvrm_gp_entry *e, unsigned n,
    const nvrm_submit_opts *o, nvrm_submit_result *r)
{
	submit_ctx sc = { .e = e, .n = n, .r = r };
	uint64_t timeout, gen;
	int rc, step;

	clear_err(ch->cl);
	rc = owner_check(ch->cl);
	if (rc != NVRM_OK)
		return (rc);
	rc = check_submit_opts(ch, o, &sc.flags, &timeout);
	if (rc != NVRM_OK)
		return (rc);
	if (!size_ok(r->size, sizeof(*r)))
		return (fail(ch->cl, NVRM_E_INVAL, "nvrm_submit_result.size "
		    "must be 0 or sizeof(nvrm_submit_result)"));
	r->size = sizeof(*r);
	r->accepted = 0;
	r->point = 0;
	rc = check_elements(ch, e, n);
	if (rc != NVRM_OK)
		return (rc);
	sc.deadline = make_deadline(timeout);
	(void)pthread_mutex_lock(&ch->lock);
	queue_join(ch, &sc.w);
	do {
		gen = ch->cl->ops->chan->progress_gen(ch->cl->bc);
		refresh_all(ch);
		step = submit_step(ch, &sc, &rc);
		if (step == STEP_SLEEP)
			sleep_for_progress(ch, gen, sc.deadline);
	} while (step != STEP_DONE);
	queue_leave(ch, &sc.w);
	(void)pthread_mutex_unlock(&ch->lock);
	return (rc);
}

int
nvrm_chan_kick(nvrm_chan *ch)
{
	int rc;

	clear_err(ch->cl);
	rc = owner_check(ch->cl);
	if (rc != NVRM_OK)
		return (rc);
	(void)pthread_mutex_lock(&ch->lock);
	refresh_all(ch);
	if (is_dead(ch))
		rc = lost(ch);
	else {
		rc = NVRM_OK;
		if (ch->kick_pending) {
			kick_locked(ch);
			refresh_all(ch);
		}
	}
	(void)pthread_mutex_unlock(&ch->lock);
	return (rc);
}

int
nvrm_chan_gp_space(nvrm_chan *ch, unsigned *n)
{
	int rc = NVRM_OK;

	clear_err(ch->cl);
	(void)pthread_mutex_lock(&ch->lock);
	refresh_all(ch);
	if (is_dead(ch))
		rc = lost(ch);
	else
		*n = space_locked(ch);
	(void)pthread_mutex_unlock(&ch->lock);
	return (rc);
}

/* The checks of a wait that is not already satisfied, in order: a fork child
 * may not wait, a dead channel is lost, a point never submitted is invalid. */
static int
wait_check(nvrm_chan *ch, uint64_t point)
{
	if (!nvrm_owner_is_me(&ch->cl->owner))
		return (owner_check(ch->cl));
	if (is_dead(ch))
		return (lost(ch));
	if (point > ch->submitted)
		return (fail(ch->cl, NVRM_E_INVAL, "point %ju exceeds "
		    "submitted point %ju", (uintmax_t)point, ch->submitted));
	return (NVRM_OK);
}

static int
wait_loop(nvrm_chan *ch, uint64_t point, uint64_t deadline)
{
	uint64_t gen;

	for (;;) {
		gen = ch->cl->ops->chan->progress_gen(ch->cl->bc);
		refresh_all(ch);
		if (point <= ch->completed)
			return (NVRM_OK);
		if (is_dead(ch))
			return (lost(ch));
		if (deadline_reached(deadline))
			return (fail(ch->cl, NVRM_E_TIMEOUT, "timed out "
			    "waiting for progress point %ju",
			    (uintmax_t)point));
		sleep_for_progress(ch, gen, deadline);
	}
}

int
nvrm_chan_wait(nvrm_chan *ch, uint64_t point, uint64_t timeout_ns)
{
	uint64_t deadline = make_deadline(timeout_ns);
	int rc = NVRM_OK;

	clear_err(ch->cl);
	(void)pthread_mutex_lock(&ch->lock);
	refresh_all(ch);
	if (point != 0 && point > ch->completed) {
		rc = wait_check(ch, point);
		if (rc == NVRM_OK)
			rc = wait_loop(ch, point, deadline);
	}
	(void)pthread_mutex_unlock(&ch->lock);
	return (rc);
}

int
nvrm_chan_status_get(nvrm_chan *ch, nvrm_chan_status *st)
{
	clear_err(ch->cl);
	if (!size_ok(st->size, sizeof(*st)))
		return (fail(ch->cl, NVRM_E_INVAL, "nvrm_chan_status.size "
		    "must be 0 or sizeof(nvrm_chan_status)"));
	(void)pthread_mutex_lock(&ch->lock);
	refresh_all(ch);
	st->size = sizeof(*st);
	st->state = __atomic_load_n(&ch->state, __ATOMIC_ACQUIRE);
	st->error = __atomic_load_n(&ch->error, __ATOMIC_ACQUIRE);
	st->gp_get = __atomic_load_n(&ch->gp_get, __ATOMIC_ACQUIRE);
	st->gp_put = ch->gp_put;
	st->reserved = 0;
	st->submitted = ch->submitted;
	st->completed = ch->completed;
	(void)pthread_mutex_unlock(&ch->lock);
	return (NVRM_OK);
}

int
nvrm_chan_info_get(const nvrm_chan *ch, nvrm_chan_info *info)
{
	clear_err(ch->cl);
	if (!size_ok(info->size, sizeof(*info)))
		return (fail(ch->cl, NVRM_E_INVAL, "nvrm_chan_info.size "
		    "must be 0 or sizeof(nvrm_chan_info)"));
	info->size = sizeof(*info);
	info->engines = ch->engines;
	info->entries = ch->entries;
	info->runlist = ch->runlist;
	info->cls_gpfifo = ch->info.cls_gpfifo;
	memcpy(info->subch_class, ch->info.subch_class,
	    sizeof(info->subch_class));
	info->sem_va = ch->sem_va;
	return (NVRM_OK);
}

/*
 * The parameters the RM was given for the last channel allocation this
 * client submitted, whether the RM took them or refused them: the caller
 * prints them when the RM refused, so the boot log says what the RM was
 * given.  The parameters do not say which field the RM refused: only the
 * status of the allocation does, and the caller has it.
 *
 * The backend holds them; a backend that keeps none says so, and a client
 * that submitted none is told so too (NVRM_E_NOENT), so that "nothing was
 * submitted" and "everything was submitted" are not the same answer.
 */
#define ALLOC_NOSUP_MSG "this backend does not record the parameters of a " \
	"channel allocation: run against the RM backend to see them"

int
nvrm_chan_alloc_get(nvrm_client *cl, nvrm_chan_alloc *out)
{
	int rc;

	clear_err(cl);
	if (out == NULL)
		return (fail(cl, NVRM_E_INVAL, "nvrm_chan_alloc_get() wants a "
		    "structure to fill"));
	if (!size_ok(out->size, sizeof(*out)))
		return (fail(cl, NVRM_E_INVAL, "nvrm_chan_alloc.size "
		    "must be 0 or sizeof(nvrm_chan_alloc)"));
	if (cl->ops->chan == NULL || cl->ops->chan->alloc_get == NULL)
		return (fail(cl, NVRM_E_NOTSUP, ALLOC_NOSUP_MSG));
	rc = cl->ops->chan->alloc_get(cl->bc, out);
	if (rc == NVRM_E_NOENT)
		return (fail(cl, rc, "this client submitted no channel "
		    "allocation to the RM"));
	if (rc == NVRM_E_NOTSUP)
		return (fail(cl, rc, ALLOC_NOSUP_MSG));
	if (rc != NVRM_OK)
		return (fail(cl, rc, "the backend did not give the parameters "
		    "of the last channel allocation"));
	return (NVRM_OK);
}

/*
 * Destroy a channel.  When the backend refuses to destroy its channel, the
 * ring memory and VA stay held (the backend may still use them) and so does
 * the core record, which the backend may still point to: the failure is
 * counted and its message kept, the channel moves to the client's held list,
 * and the client's close forgets the backend record, then frees them.
 */
void
nvrm_chan_destroy(nvrm_chan *ch)
{
	nvrm_client *cl;
	nvrm_chan **pp;
	int held = 0;

	if (ch == NULL)
		return;
	cl = ch->cl;
	(void)pthread_mutex_lock(&cl->errlock);
	if (nvrm_owner_is_me(&cl->owner) &&
	    cl->ops->chan->destroy(ch->b, cl->errmsg, sizeof(cl->errmsg)) !=
	    NVRM_OK) {
		cl->st.failed_releases++;
		held = 1;
	}
	if (!held)
		create_unwind(ch);
	for (pp = &cl->channels; *pp != ch; pp = &(*pp)->next)
		;
	*pp = ch->next;
	cl->st.live_channels--;
	if (held) {
		ch->next = cl->held;
		cl->held = ch;
	}
	(void)pthread_mutex_unlock(&cl->errlock);
	if (held)
		return;
	chan_free(ch);
}

/* Client close: the channels whose destroy was refused.  The backend record
 * goes first, because it points to the core record and the ring memory that
 * are freed here.  A fork child owns no backend record: it forgets nothing,
 * drops the record and lets the memory go through the public memory calls,
 * which pass owner 0 there. */
void
nvrm_chan_release_held(nvrm_client *cl)
{
	nvrm_chan *ch;

	while ((ch = cl->held) != NULL) {
		cl->held = ch->next;
		if (nvrm_owner_is_me(&cl->owner))
			cl->ops->chan->forget(ch->b);
		ch->b = NULL;
		create_unwind(ch);
		chan_free(ch);
	}
}

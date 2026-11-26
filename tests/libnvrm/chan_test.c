/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * chan_test.c - channel core and fake GPFIFO: ring capacity, the ordered
 * submit queue, semaphore methods, copies, faults, lifetime and concurrency.
 */
#include <sys/types.h>

#include <inttypes.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <nvrm/nvrm_chan.h>

#include "nvtypes.h"
#include "class/cl906f.h"
#include "class/clc86f.h"
#include "nvmisc.h"

#include "nvrm_internal.h"
#include "nvrm_barrier.h"
#include "nvrm_methods.h"
#include "nvrm_fake.h"
#include "t.h"
#include "fault_calloc.h"

#define KIB	1024ULL

#define LAUNCH_PITCH	(NVRM_FAKE_COPY_LAUNCH_SRC_PITCH | \
	NVRM_FAKE_COPY_LAUNCH_DST_PITCH)
#define LAUNCH_PIPELINED_PITCH	(NVRM_FAKE_COPY_TYPE_PIPELINED | LAUNCH_PITCH)

static nvrm_ctx *ctx;

typedef struct test_buf {
	nvrm_mem	*mem;
	uint64_t	va;
	void		*cpu;
	size_t		bytes;
} test_buf;

typedef struct submit_arg {
	nvrm_chan	*ch;
	const nvrm_gp_entry *e;
	unsigned	n;
	const nvrm_submit_opts *o;
	nvrm_submit_result r;
	volatile unsigned phase;
	int		rc;
} submit_arg;

static void
fail_calloc_at(int n)
{
	calloc_calls = 0;
	calloc_fail_at = n;
}

static pid_t
other_pid(void)
{
	return (getpid() + 1);
}

static unsigned destroy_calls, backend_calls, forget_calls;
static int destroy_fails;

static int
counting_destroy(nvrm_bchan *b, char *err, size_t errlen)
{
	destroy_calls++;
	if (destroy_fails) {
		snprintf(err, errlen, "injected destroy failure");
		return (NVRM_E_RM);
	}
	return (nvrm_fake_chan_ops.destroy(b, err, errlen));
}

static void
counting_forget(nvrm_bchan *b)
{
	forget_calls++;
	backend_calls++;
	nvrm_fake_chan_ops.forget(b);
}

/* Every other backend call is counted: a fork child must make none. */
static uint32_t
counting_gp_get(nvrm_bchan *b)
{
	backend_calls++;
	return (nvrm_fake_chan_ops.gp_get(b));
}

static uint32_t
counting_error(nvrm_bchan *b)
{
	backend_calls++;
	return (nvrm_fake_chan_ops.error(b));
}

static uint64_t
counting_gen(nvrm_bclient *bc)
{
	backend_calls++;
	return (nvrm_fake_chan_ops.progress_gen(bc));
}

static int
counting_wait(nvrm_bclient *bc, uint64_t slice_ns, uint64_t gen)
{
	backend_calls++;
	return (nvrm_fake_chan_ops.wait(bc, slice_ns, gen));
}

static int
reject_create(nvrm_bclient *bc, const nvrm_bchan_cfg *cfg, nvrm_bchan **bp,
    nvrm_bchan_info *out, char *err, size_t errlen)
{
	*bp = NULL;
	snprintf(err, errlen, "injected channel create failure");
	return (NVRM_E_RM);
}

static int
miswired_create(nvrm_bclient *bc, const nvrm_bchan_cfg *cfg, nvrm_bchan **bp,
    nvrm_bchan_info *out, char *err, size_t errlen)
{
	nvrm_bchan_cfg copy = *cfg;

	copy.ring_va = 0x1000;
	return (nvrm_fake_chan_ops.create(bc, &copy, bp, out, err, errlen));
}

static nvrm_client_stats
client_stats(nvrm_client *cl)
{
	nvrm_client_stats st = { .size = sizeof(st) };

	CHECK_EQ(nvrm_client_stats_get(cl, &st), NVRM_OK);
	return (st);
}

static void
check_live_stats(nvrm_client *cl, const nvrm_client_stats *want)
{
	nvrm_client_stats st = client_stats(cl);

	CHECK_EQ(st.live_mem, want->live_mem);
	CHECK_EQ(st.live_reservations, want->live_reservations);
	CHECK_EQ(st.live_gpu_maps, want->live_gpu_maps);
	CHECK_EQ(st.live_cpu_maps, want->live_cpu_maps);
	CHECK_EQ(st.live_channels, want->live_channels);
}

static uint64_t
monotime(void)
{
	struct timespec ts;

	(void)clock_gettime(CLOCK_MONOTONIC, &ts);
	return ((uint64_t)ts.tv_sec * 1000000000ULL + ts.tv_nsec);
}

static void
setup(void)
{
	nvrm_enum_opts o = { .backend = "fake" };
	char err[200];

	setenv("NVRM_BACKEND", "fake", 1);
	setenv("NVRM_FAKE_PROFILE", "discrete", 1);
	CHECK_EQ(nvrm_enumerate(&ctx, &o, err, sizeof(err)), NVRM_OK);
	nvrm_fake_chan_ops.copy_on_graphics = 1;
	nvrm_fake_chan_manual(0);
	nvrm_fake_chan_lag(0);
	nvrm_fake_chan_event_hook = NULL;
	nvrm_barrier_hook = NULL;
	nvrm_chan_slice_ns = NVRM_CHAN_SLICE_DEFAULT_NS;
	nvrm_chan_presleep_hook = NULL;
	nvrm_getpid_hook = NULL;
}

static nvrm_client *
open_client_flags(uint32_t flags)
{
	nvrm_open_opts o = { .flags = flags };
	nvrm_client *cl = NULL;
	char err[200];

	CHECK_EQ(nvrm_client_open(nvrm_device_get(ctx, 0), &o, &cl, err,
	    sizeof(err)), NVRM_OK);
	return (cl);
}

static nvrm_client *
open_client(void)
{
	return (open_client_flags(NVRM_OPEN_ALLOW_MAP));
}

static void
teardown(nvrm_client *cl)
{
	if (cl != NULL)
		nvrm_client_close(cl);
	if (ctx != NULL)
		nvrm_close(ctx);
	ctx = NULL;
	nvrm_fake_mem_fail_clear();
	nvrm_fake_chan_manual(0);
	nvrm_fake_chan_lag(0);
	nvrm_fake_chan_read_fail(0);
	nvrm_fake_chan_event_hook = NULL;
	nvrm_barrier_hook = NULL;
	nvrm_chan_slice_ns = NVRM_CHAN_SLICE_DEFAULT_NS;
	nvrm_chan_presleep_hook = NULL;
	nvrm_getpid_hook = NULL;
	fail_calloc_at(0);
}

static nvrm_chan *
make_chan(nvrm_client *cl, uint32_t engines, uint32_t entries)
{
	nvrm_chan_params p = { .engines = engines, .entries = entries };
	nvrm_chan *ch = NULL;

	CHECK_EQ(nvrm_chan_create(cl, &p, &ch), NVRM_OK);
	CHECK(ch != NULL);
	return (ch);
}

static int
buf_init_flags(nvrm_client *cl, test_buf *b, size_t bytes, uint32_t map_flags)
{
	nvrm_va_params vp = { .bytes = bytes };
	nvrm_mem_params mp = { .kind = NVRM_MEM_SYSMEM, .bytes = bytes };
	nvrm_gpu_map_params gp = { .flags = map_flags };
	int rc;

	memset(b, 0, sizeof(*b));
	rc = nvrm_va_reserve(cl, &vp, &b->va);
	if (rc != NVRM_OK)
		return (rc);
	rc = nvrm_mem_alloc(cl, &mp, &b->mem);
	if (rc != NVRM_OK)
		goto bad;
	gp.va = b->va;
	rc = nvrm_mem_map_gpu(b->mem, &gp);
	if (rc != NVRM_OK)
		goto bad;
	rc = nvrm_mem_map_cpu(b->mem, NVRM_CPU_READ | NVRM_CPU_WRITE, &b->cpu);
	if (rc != NVRM_OK)
		goto bad;
	memset(b->cpu, 0, bytes);
	b->bytes = bytes;
	return (NVRM_OK);
bad:
	if (b->mem != NULL)
		nvrm_mem_free(b->mem);
	(void)nvrm_va_release(cl, b->va);
	return (rc);
}

static int
buf_init(nvrm_client *cl, test_buf *b, size_t bytes)
{
	return (buf_init_flags(cl, b, bytes, 0));
}

static void
buf_release(nvrm_client *cl, test_buf *b)
{
	if (b->cpu != NULL)
		(void)nvrm_mem_unmap_cpu(b->mem);
	if (b->mem != NULL)
		nvrm_mem_free(b->mem);
	if (b->va != 0)
		(void)nvrm_va_release(cl, b->va);
	memset(b, 0, sizeof(*b));
}

static void
put_word(test_buf *b, unsigned pos, uint32_t word)
{
	((uint32_t *)b->cpu)[pos] = word;
}

static void
put_inc(test_buf *b, unsigned pos, unsigned subch, unsigned off,
    unsigned count)
{
	put_word(b, pos, nvrm_method_header(subch, off, count, NVRM_MTHD_OP_INC));
}

static unsigned
put_sem_frame(test_buf *b, unsigned pos, uint64_t sem_va, uint64_t payload,
    uint32_t execute)
{
	put_inc(b, pos, 0, NVRM_MTHD_SEM_ADDR_LO, 5);
	put_word(b, pos + 1, (uint32_t)sem_va & 0xfffffffcU);
	put_word(b, pos + 2, (uint32_t)(sem_va >> 32));
	put_word(b, pos + 3, (uint32_t)payload);
	put_word(b, pos + 4, (uint32_t)(payload >> 32));
	put_word(b, pos + 5, execute);
	return (pos + 6);
}

typedef struct copy_frame {
	uint64_t	in;
	uint64_t	out;
	uint32_t	pitch_in;
	uint32_t	pitch_out;
	uint32_t	length;
	uint32_t	lines;
	uint32_t	launch;
} copy_frame;

static unsigned
put_copy_frame(test_buf *b, unsigned pos, const copy_frame *f)
{
	uint64_t in = f->in, out = f->out;
	uint32_t pitch_in = f->pitch_in, pitch_out = f->pitch_out;
	uint32_t length = f->length, lines = f->lines, launch = f->launch;

	put_inc(b, pos, 4, NVRM_FAKE_COPY_OFFSET_IN_UPPER, 4);
	put_word(b, pos + 1, (uint32_t)(in >> 32));
	put_word(b, pos + 2, (uint32_t)in);
	put_word(b, pos + 3, (uint32_t)(out >> 32));
	put_word(b, pos + 4, (uint32_t)out);
	put_inc(b, pos + 5, 4, NVRM_FAKE_COPY_PITCH_IN, 4);
	put_word(b, pos + 6, pitch_in);
	put_word(b, pos + 7, pitch_out);
	put_word(b, pos + 8, length);
	put_word(b, pos + 9, lines);
	put_word(b, pos + 10, nvrm_method_immd(4, NVRM_FAKE_COPY_LAUNCH_DMA,
	    launch));
	return (pos + 11);
}

static void
make_nops(test_buf *b, unsigned n)
{
	unsigned i;

	for (i = 0; i < n; i++)
		put_word(b, i * 4, nvrm_method_immd(0, NVRM_MTHD_NOP, 0));
}

static nvrm_gp_entry
buf_entry(const test_buf *b, unsigned element, uint32_t flags)
{
	nvrm_gp_entry e = { .va = b->va + element * 16, .dwords = 1,
	    .flags = flags };

	return (e);
}

/* A fresh client with an 8-entry compute channel, and a buffer of n nop
 * pushbuffer elements described by e. */
static nvrm_chan *
setup_nops(nvrm_client **cl, test_buf *pb, unsigned n, nvrm_gp_entry *e)
{
	nvrm_chan *ch;
	unsigned i;

	setup();
	*cl = open_client();
	ch = make_chan(*cl, NVRM_ENG_COMPUTE, 8);
	CHECK_EQ(buf_init(*cl, pb, 4096), NVRM_OK);
	make_nops(pb, n);
	for (i = 0; i < n; i++)
		e[i] = buf_entry(pb, i, 0);
	return (ch);
}

typedef struct fake_action {
	nvrm_chan	*ch;
	unsigned	entries;
	uint32_t	fault_code;
	int		rc;
} fake_action;

static void *
fake_action_thread(void *arg)
{
	fake_action *a = arg;

	usleep(20000);
	if (a->fault_code != 0) {
		nvrm_fake_chan_fault(a->ch, a->fault_code);
		a->rc = NVRM_OK;
	} else {
		a->rc = nvrm_fake_chan_step(a->ch, a->entries);
	}
	return (NULL);
}

static void *
submit_thread(void *arg)
{
	submit_arg *a = arg;

	__atomic_store_n(&a->phase, 1, __ATOMIC_RELEASE);
	a->rc = nvrm_chan_submit(a->ch, a->e, a->n, a->o, &a->r);
	__atomic_store_n(&a->phase, 2, __ATOMIC_RELEASE);
	return (NULL);
}

static void
submit_start(pthread_t *tid, submit_arg *a)
{
	memset(&a->r, 0, sizeof(a->r));
	a->r.size = sizeof(a->r);
	a->phase = 0;
	a->rc = NVRM_E_BUSY;
	CHECK_EQ(pthread_create(tid, NULL, submit_thread, a), 0);
	while (__atomic_load_n(&a->phase, __ATOMIC_ACQUIRE) == 0)
		usleep(1000);
}

static void
submit_join(pthread_t tid, submit_arg *a)
{
	unsigned i;

	for (i = 0; i < 10000 &&
	    __atomic_load_n(&a->phase, __ATOMIC_ACQUIRE) != 2; i++)
		usleep(1000);
	CHECK_EQ(__atomic_load_n(&a->phase, __ATOMIC_ACQUIRE), 2);
	CHECK_EQ(pthread_join(tid, NULL), 0);
}

static unsigned
queue_len(nvrm_chan *ch)
{
	const nvrm_chan_waiter *it;
	unsigned n = 0;

	(void)pthread_mutex_lock(&ch->lock);
	for (it = ch->q_head; it != NULL; it = it->next)
		n++;
	(void)pthread_mutex_unlock(&ch->lock);
	return (n);
}

/* Wait until exactly want submitters stand in the channel queue. */
static void
wait_queued(nvrm_chan *ch, unsigned want)
{
	unsigned i;

	for (i = 0; i < 10000; i++) {
		if (queue_len(ch) == want)
			return;
		usleep(1000);
	}
	CHECK_EQ(queue_len(ch), want);
}

/* Step the fake channel, wait for the submitter to reach phase 2, and
 * return the time that took. */
static uint64_t
step_and_wait(nvrm_chan *ch, unsigned steps, unsigned polls,
    const submit_arg *a)
{
	uint64_t began;
	unsigned i;

	began = monotime();
	CHECK_EQ(nvrm_fake_chan_step(ch, steps), NVRM_OK);
	for (i = 0; i < polls && a->phase != 2; i++)
		usleep(1000);
	return (monotime() - began);
}

static void
drain(nvrm_chan *ch, unsigned entries)
{
	unsigned i;

	for (i = 0; i < entries * 3 + 4; i++)
		(void)nvrm_fake_chan_step(ch, 1);
}

static void
test_create_smoke(void)
{
	nvrm_chan_info info = { .size = sizeof(info) };
	nvrm_client *cl;
	nvrm_chan *ch;

	setup();
	cl = open_client();
	ch = make_chan(cl, NVRM_ENG_COMPUTE, 8);
	CHECK_EQ(nvrm_chan_info_get(ch, &info), NVRM_OK);
	CHECK_EQ(info.entries, 8);
	CHECK_EQ(info.runlist, NVRM_RUNLIST_GRAPHICS);
	CHECK_EQ(info.cls_gpfifo, NVRM_FAKE_CLASS_GPFIFO);
	CHECK_EQ(info.subch_class[1], NVRM_FAKE_CLASS_COMPUTE);
	CHECK(info.sem_va != 0);
	nvrm_chan_destroy(ch);
	nvrm_chan_destroy(NULL);
	teardown(cl);
}

/* With one caller slot free, an indivisible pair waits for two ring entries. */
static void
test_incomplete_waits(void)
{
	nvrm_gp_entry first[4], pair[2];
	nvrm_submit_result r = { .size = sizeof(r) };
	nvrm_chan_status st = { .size = sizeof(st) };
	submit_arg a;
	pthread_t tid;
	test_buf pb;
	nvrm_client *cl;
	nvrm_chan *ch;
	unsigned space, i;

	setup();
	cl = open_client();
	ch = make_chan(cl, NVRM_ENG_COMPUTE, 8);
	CHECK_EQ(buf_init(cl, &pb, 4096), NVRM_OK);
	make_nops(&pb, 6);
	for (i = 0; i < 4; i++)
		first[i] = buf_entry(&pb, i, 0);
	pair[0] = buf_entry(&pb, 4, NVRM_GP_INCOMPLETE);
	pair[1] = buf_entry(&pb, 5, 0);
	nvrm_fake_chan_manual(1);
	CHECK_EQ(nvrm_chan_submit(ch, first, 4, NULL, &r), NVRM_OK);
	CHECK_EQ(nvrm_chan_gp_space(ch, &space), NVRM_OK);
	CHECK_EQ(space, 1);
	a.ch = ch;
	a.e = pair;
	a.n = 2;
	a.o = NULL;
	submit_start(&tid, &a);
	usleep(20000);
	CHECK_EQ(a.phase, 1);
	CHECK_EQ(nvrm_chan_status_get(ch, &st), NVRM_OK);
	CHECK_EQ(st.gp_put, 5);
	CHECK_EQ(nvrm_fake_chan_step(ch, 2), NVRM_OK);
	submit_join(tid, &a);
	CHECK_EQ(a.rc, NVRM_OK);
	CHECK_EQ(a.r.accepted, 2);
	drain(ch, 8);
	CHECK_EQ(nvrm_chan_wait(ch, a.r.point, 0), NVRM_OK);
	nvrm_chan_destroy(ch);
	buf_release(cl, &pb);
	teardown(cl);
}

static void
decode_ring(nvrm_chan *ch, unsigned index, uint64_t *va, uint32_t *dwords)
{
	const uint32_t *ring = (const uint32_t *)((const char *)ch->cpu +
	    NVRM_CHAN_RING_OFF(ch->entries));

	*va = nvrm_gp_decode_va(ring[index * 2], ring[index * 2 + 1]);
	*dwords = nvrm_gp_decode_dwords(ring[index * 2 + 1]);
}

/* Six caller elements occupy six slots; the core release is the seventh. */
static void
test_one_batch(void)
{
	nvrm_gp_entry e[6];
	nvrm_submit_result r = { .size = sizeof(r) };
	nvrm_chan_status st = { .size = sizeof(st) };
	test_buf pb;
	nvrm_client *cl;
	nvrm_chan *ch;
	uint64_t va;
	uint32_t dwords;
	unsigned i;

	setup();
	cl = open_client();
	ch = make_chan(cl, NVRM_ENG_COMPUTE, 8);
	CHECK_EQ(buf_init(cl, &pb, 4096), NVRM_OK);
	make_nops(&pb, 6);
	for (i = 0; i < 6; i++)
		e[i] = buf_entry(&pb, i, i == 0 ? NVRM_GP_NO_PREFETCH : 0);
	nvrm_fake_chan_manual(1);
	CHECK_EQ(nvrm_chan_submit(ch, e, 6, NULL, &r), NVRM_OK);
	CHECK_EQ(r.accepted, 6);
	CHECK_EQ(r.point, 1);
	for (i = 0; i < 6; i++) {
		decode_ring(ch, i, &va, &dwords);
		CHECK_EQ(va, e[i].va);
		CHECK_EQ(dwords, 1);
	}
	decode_ring(ch, 6, &va, &dwords);
	CHECK_EQ(va, ch->ring_va + NVRM_CHAN_SEG_OFF(ch->entries, 6));
	CHECK_EQ(dwords, NVRM_RELEASE_DWORDS);
	CHECK(nvrm_gp_decode_no_prefetch(((uint32_t *)ch->cpu)[1]) != 0);
	CHECK_EQ(nvrm_chan_wait(ch, 1, 0), NVRM_E_TIMEOUT);
	drain(ch, 7);
	CHECK_EQ(nvrm_chan_status_get(ch, &st), NVRM_OK);
	CHECK_EQ(nvrm_chan_wait(ch, 1, 0), NVRM_OK);
	CHECK_EQ(st.submitted, 1);
	CHECK_EQ(st.completed, 1);
	nvrm_chan_destroy(ch);
	buf_release(cl, &pb);
	teardown(cl);
}

/* Record the caller elements as the fake consumes each ring slot. */
static void
step_and_record(nvrm_chan *ch, const test_buf *pb, unsigned *seen)
{
	nvrm_chan_status st = { .size = sizeof(st) };
	uint64_t va;
	uint32_t dwords;

	CHECK_EQ(nvrm_chan_status_get(ch, &st), NVRM_OK);
	if (st.gp_get != st.gp_put) {
		decode_ring(ch, st.gp_get, &va, &dwords);
		if (va >= pb->va && va < pb->va + pb->bytes) {
			CHECK_EQ(va, pb->va + *seen * 16);
			(*seen)++;
		}
		(void)nvrm_fake_chan_step(ch, 1);
	}
}

static void
test_split_in_order(void)
{
	nvrm_gp_entry e[24];
	submit_arg a;
	pthread_t tid;
	test_buf pb;
	nvrm_client *cl;
	nvrm_chan *ch;
	unsigned i, seen = 0;

	setup();
	cl = open_client();
	ch = make_chan(cl, NVRM_ENG_COMPUTE, 8);
	CHECK_EQ(buf_init(cl, &pb, 4096), NVRM_OK);
	make_nops(&pb, 24);
	for (i = 0; i < 24; i++)
		e[i] = buf_entry(&pb, i, 0);
	nvrm_fake_chan_manual(1);
	a.ch = ch;
	a.e = e;
	a.n = 24;
	a.o = NULL;
	submit_start(&tid, &a);
	for (i = 0; i < 10000 &&
	    __atomic_load_n(&a.phase, __ATOMIC_ACQUIRE) != 2; i++) {
		step_and_record(ch, &pb, &seen);
		usleep(1000);
	}
	submit_join(tid, &a);
	for (i = 0; i < 8; i++)
		step_and_record(ch, &pb, &seen);
	CHECK_EQ(a.rc, NVRM_OK);
	CHECK_EQ(a.r.accepted, 24);
	CHECK(a.r.point >= 4 && a.r.point <= 24);
	CHECK_EQ(seen, 24);
	CHECK_EQ(nvrm_chan_wait(ch, a.r.point, 0), NVRM_OK);
	nvrm_chan_destroy(ch);
	buf_release(cl, &pb);
	teardown(cl);
}

static void
test_incomplete_limits(void)
{
	nvrm_gp_entry e[7];
	nvrm_submit_opts o = { .timeout_ns = 0 };
	nvrm_submit_result r = { .size = sizeof(r) };
	nvrm_chan_status st = { .size = sizeof(st) };
	test_buf pb;
	nvrm_client *cl;
	nvrm_chan *ch;
	unsigned i;

	setup();
	cl = open_client();
	ch = make_chan(cl, NVRM_ENG_COMPUTE, 8);
	CHECK_EQ(buf_init(cl, &pb, 4096), NVRM_OK);
	make_nops(&pb, 7);
	for (i = 0; i < 7; i++)
		e[i] = buf_entry(&pb, i, i < 6 ? NVRM_GP_INCOMPLETE : 0);
	nvrm_fake_chan_manual(1);
	CHECK_EQ(nvrm_chan_submit(ch, e, 7, &o, &r), NVRM_E_INVAL);
	CHECK(strstr(nvrm_client_errmsg(cl), "starting at element 0") != NULL);
	CHECK_EQ(r.accepted, 0);
	CHECK_EQ(r.point, 0);
	CHECK_EQ(nvrm_chan_status_get(ch, &st), NVRM_OK);
	CHECK_EQ(st.gp_put, 0);
	CHECK_EQ(st.submitted, 0);
	CHECK(((uint32_t *)ch->cpu)[0] == 0);

	for (i = 0; i < 6; i++)
		e[i] = buf_entry(&pb, i, i < 5 ? NVRM_GP_INCOMPLETE : 0);
	CHECK_EQ(nvrm_chan_submit(ch, e, 6, NULL, &r), NVRM_OK);
	CHECK_EQ(r.accepted, 6);
	decode_ring(ch, 6, &e[6].va, &e[6].dwords);
	CHECK_EQ(e[6].dwords, NVRM_RELEASE_DWORDS);
	drain(ch, 7);
	CHECK_EQ(nvrm_chan_wait(ch, 1, 0), NVRM_OK);
	nvrm_chan_destroy(ch);
	buf_release(cl, &pb);
	teardown(cl);
}

typedef struct order_watch {
	nvrm_chan	*ch;
	const test_buf	*a_buf, *b_buf;
	const submit_arg *a, *b;
	unsigned	seen_a, seen_b;
	int		b_before_a;
} order_watch;

static void
order_step(order_watch *w)
{
	nvrm_chan_status st = { .size = sizeof(st) };
	uint64_t va;
	uint32_t dwords;

	CHECK_EQ(nvrm_chan_status_get(w->ch, &st), NVRM_OK);
	if (st.gp_get == st.gp_put)
		return;
	decode_ring(w->ch, st.gp_get, &va, &dwords);
	if (va >= w->a_buf->va && va < w->a_buf->va + w->a_buf->bytes) {
		CHECK_EQ(va, w->a_buf->va + w->seen_a * 16);
		w->seen_a++;
	}
	if (va >= w->b_buf->va && va < w->b_buf->va + w->b_buf->bytes) {
		if (__atomic_load_n(&w->a->phase, __ATOMIC_ACQUIRE) != 2)
			w->b_before_a = 1;
		CHECK_EQ(va, w->b_buf->va + w->seen_b * 16);
		w->seen_b++;
	}
	CHECK_EQ(nvrm_fake_chan_step(w->ch, 1), NVRM_OK);
}

static void
require_two_done(submit_arg *a, submit_arg *b)
{
	if (__atomic_load_n(&a->phase, __ATOMIC_ACQUIRE) != 2 ||
	    __atomic_load_n(&b->phase, __ATOMIC_ACQUIRE) != 2) {
		CHECK(0 && "both ticketed submits must finish");
		exit(1);
	}
}

/* f: a later one-element submit cannot pass an earlier six-element waiter. */
static void
test_ticket_order(void)
{
	nvrm_gp_entry first[4], ea[6], eb[1];
	nvrm_chan_status st = { .size = sizeof(st) };
	submit_arg a = { .n = 6 }, b = { .n = 1 };
	pthread_t ta, tb;
	test_buf initial, abuf, bbuf;
	nvrm_client *cl;
	order_watch w;
	unsigned i;

	setup();
	cl = open_client();
	w.ch = make_chan(cl, NVRM_ENG_COMPUTE, 8);
	CHECK_EQ(buf_init(cl, &initial, 4096), NVRM_OK);
	CHECK_EQ(buf_init(cl, &abuf, 4096), NVRM_OK);
	CHECK_EQ(buf_init(cl, &bbuf, 4096), NVRM_OK);
	make_nops(&initial, 6);
	make_nops(&abuf, 6);
	make_nops(&bbuf, 1);
	for (i = 0; i < 4; i++)
		first[i] = buf_entry(&initial, i, 0);
	for (i = 0; i < 6; i++)
		ea[i] = buf_entry(&abuf, i, i == 0 ? NVRM_GP_INCOMPLETE : 0);
	eb[0] = buf_entry(&bbuf, 0, 0);
	nvrm_fake_chan_manual(1);
	CHECK_EQ(nvrm_chan_submit(w.ch, first, 4, NULL, &(nvrm_submit_result){
	    .size = sizeof(nvrm_submit_result) }), NVRM_OK);
	a = (submit_arg){ .ch = w.ch, .e = ea, .n = 6 };
	b = (submit_arg){ .ch = w.ch, .e = eb, .n = 1 };
	submit_start(&ta, &a);
	wait_queued(w.ch, 1);
	submit_start(&tb, &b);
	wait_queued(w.ch, 2);
	usleep(20000);
	CHECK_EQ(__atomic_load_n(&a.phase, __ATOMIC_ACQUIRE), 1);
	CHECK_EQ(__atomic_load_n(&b.phase, __ATOMIC_ACQUIRE), 1);
	CHECK_EQ(nvrm_chan_status_get(w.ch, &st), NVRM_OK);
	CHECK_EQ(st.gp_put, 5);
	w.a_buf = &abuf;
	w.b_buf = &bbuf;
	w.a = &a;
	w.b = &b;
	w.seen_a = w.seen_b = 0;
	w.b_before_a = 0;
	for (i = 0; i < 10000 && (a.phase != 2 || b.phase != 2); i++) {
		order_step(&w);
		usleep(1000);
	}
	require_two_done(&a, &b);
	submit_join(ta, &a);
	submit_join(tb, &b);
	for (i = 0; i < 32 && (w.seen_a < 6 || w.seen_b < 1); i++)
		order_step(&w);
	CHECK_EQ(a.rc, NVRM_OK);
	CHECK_EQ(b.rc, NVRM_OK);
	CHECK_EQ(w.seen_a, 6);
	CHECK_EQ(w.seen_b, 1);
	CHECK_EQ(w.b_before_a, 0);
	drain(w.ch, 8);
	nvrm_chan_destroy(w.ch);
	buf_release(cl, &bbuf);
	buf_release(cl, &abuf);
	buf_release(cl, &initial);
	teardown(cl);
}

/* g: fake progress broadcasts wake a waiter even with a ten-second slice. */
static void
test_waiter_wake(void)
{
	nvrm_gp_entry first[6], next[1];
	nvrm_submit_result r = { .size = sizeof(r) };
	submit_arg a;
	pthread_t tid;
	test_buf pb;
	nvrm_client *cl;
	nvrm_chan *ch;
	uint64_t elapsed;
	unsigned i;

	setup();
	cl = open_client();
	ch = make_chan(cl, NVRM_ENG_COMPUTE, 8);
	CHECK_EQ(buf_init(cl, &pb, 4096), NVRM_OK);
	make_nops(&pb, 7);
	for (i = 0; i < 6; i++)
		first[i] = buf_entry(&pb, i, 0);
	next[0] = buf_entry(&pb, 6, 0);
	nvrm_fake_chan_manual(1);
	nvrm_chan_slice_ns = 10000000000ULL;
	CHECK_EQ(nvrm_chan_submit(ch, first, 6, NULL, &r), NVRM_OK);
	a = (submit_arg){ .ch = ch, .e = next, .n = 1 };
	submit_start(&tid, &a);
	wait_queued(ch, 1);
	usleep(20000);
	elapsed = step_and_wait(ch, 2, 2000, &a);
	if (a.phase != 2) {
		CHECK(0 && "the waiter did not wake");
		exit(1);
	}
	submit_join(tid, &a);
	CHECK_EQ(a.rc, NVRM_OK);
	CHECK(elapsed < 2000000000ULL);
	drain(ch, 8);
	nvrm_chan_destroy(ch);
	buf_release(cl, &pb);
	teardown(cl);
}

static int events[64];
static unsigned nevents;
static uint32_t *event_ring;
static uint64_t event_va;
static unsigned event_index;

static void
record_event(int event)
{
	if (event == NVRM_CHAN_EV_BARRIER_NORMAL) {
		CHECK_EQ(event_ring[event_index * 2], nvrm_gp_entry0(event_va));
		CHECK_EQ(nvrm_gp_decode_va(event_ring[event_index * 2],
		    event_ring[event_index * 2 + 1]), event_va);
	}
	if (nevents < sizeof(events) / sizeof(events[0]))
		events[nevents] = event;
	nevents++;
}

static void
check_events(const int *want, unsigned n)
{
	unsigned i;

	CHECK_EQ(nevents, n);
	for (i = 0; i < n && i < nevents; i++)
		CHECK_EQ(events[i], want[i]);
}

static void
reset_events(nvrm_chan *ch, uint64_t va, unsigned index)
{
	nevents = 0;
	event_ring = (uint32_t *)((char *)ch->cpu +
	    NVRM_CHAN_RING_OFF(ch->entries));
	event_va = va;
	event_index = index;
}

/* h: stores precede barrier 1, USERD, barrier 2 and the doorbell. */
static void
test_flush_order(void)
{
	nvrm_gp_entry e[1];
	nvrm_submit_opts o = { .size = sizeof(o), .flags = NVRM_SUBMIT_NO_KICK,
	    .timeout_ns = UINT64_MAX };
	nvrm_submit_result r = { .size = sizeof(r) };
	nvrm_fake_chan_counts_t counts;
	test_buf pb;
	nvrm_client *cl;
	nvrm_chan *ch;
	uint32_t *release;
	static const int submit_seq[] = { NVRM_CHAN_EV_BARRIER_NORMAL,
	    NVRM_CHAN_EV_GP_PUT, NVRM_CHAN_EV_BARRIER_DEVICE,
	    NVRM_CHAN_EV_DOORBELL };
	static const int no_kick_seq[] = { NVRM_CHAN_EV_BARRIER_NORMAL,
	    NVRM_CHAN_EV_GP_PUT, NVRM_CHAN_EV_BARRIER_DEVICE };
	static const int kick_seq[] = { NVRM_CHAN_EV_BARRIER_DEVICE,
	    NVRM_CHAN_EV_DOORBELL };

	setup();
	cl = open_client();
	ch = make_chan(cl, NVRM_ENG_COMPUTE, 8);
	CHECK_EQ(buf_init(cl, &pb, 4096), NVRM_OK);
	make_nops(&pb, 2);
	e[0] = buf_entry(&pb, 0, 0);
	nvrm_fake_chan_manual(1);
	nvrm_barrier_hook = record_event;
	nvrm_fake_chan_event_hook = record_event;
	reset_events(ch, e[0].va, 0);
	CHECK_EQ(nvrm_chan_submit(ch, e, 1, NULL, &r), NVRM_OK);
	check_events(submit_seq, 4);
	release = (uint32_t *)((char *)ch->cpu +
	    NVRM_CHAN_SEG_OFF(ch->entries, 1));
	CHECK_EQ(release[5] & NVRM_SEM_WFI, NVRM_SEM_WFI);
	CHECK_EQ(release[5] & NVRM_SEM_PAYLOAD_64, NVRM_SEM_PAYLOAD_64);
	drain(ch, 2);
	CHECK_EQ(nvrm_chan_wait(ch, r.point, 0), NVRM_OK);

	e[0] = buf_entry(&pb, 1, 0);
	reset_events(ch, e[0].va, 2);
	CHECK_EQ(nvrm_chan_submit(ch, e, 1, &o, &r), NVRM_OK);
	check_events(no_kick_seq, 3);
	CHECK_EQ(nvrm_fake_chan_step(ch, 1), NVRM_OK);
	CHECK_EQ(nvrm_fake_chan_counts(ch).entries, 3);
	reset_events(ch, e[0].va, 2);
	CHECK_EQ(nvrm_chan_kick(ch), NVRM_OK);
	check_events(kick_seq, 2);
	CHECK_EQ(nvrm_chan_kick(ch), NVRM_OK);
	check_events(kick_seq, 2);
	counts = nvrm_fake_chan_counts(ch);
	CHECK_EQ(counts.doorbells, 2);
	drain(ch, 2);
	nvrm_chan_destroy(ch);
	buf_release(cl, &pb);
	teardown(cl);
}

/* i: host releases and acquires synchronize two channels in both directions. */
static void
test_semaphores(void)
{
	nvrm_gp_entry ea[2], eb[2];
	nvrm_submit_result ra = { .size = sizeof(ra) };
	nvrm_submit_result rb = { .size = sizeof(rb) };
	nvrm_fake_chan_counts_t ca, cb;
	test_buf pba, pbb, sem;
	nvrm_client *cl;
	nvrm_chan *a, *b;
	uint64_t value;
	uint32_t pos;

	setup();
	cl = open_client();
	a = make_chan(cl, NVRM_ENG_COMPUTE, 8);
	b = make_chan(cl, NVRM_ENG_COMPUTE, 8);
	CHECK_EQ(buf_init(cl, &pba, 4096), NVRM_OK);
	CHECK_EQ(buf_init(cl, &pbb, 4096), NVRM_OK);
	CHECK_EQ(buf_init(cl, &sem, 4096), NVRM_OK);
	pos = put_sem_frame(&pba, 0, sem.va, 0x100000001ULL,
	    NVRM_SEM_RELEASE | NVRM_SEM_PAYLOAD_64);
	pos = put_sem_frame(&pba, pos, sem.va, 2, NVRM_SEM_RELEASE);
	pos = put_sem_frame(&pba, pos, sem.va, 0x100000002ULL,
	    NVRM_SEM_ACQUIRE | NVRM_SEM_PAYLOAD_64);
	/* A narrow acquire compares only the low payload word. */
	pos = put_sem_frame(&pba, pos, sem.va, 0xdeadbeef00000002ULL,
	    NVRM_SEM_ACQUIRE);
	pos = put_sem_frame(&pba, pos, sem.va, 0x100000002ULL,
	    NVRM_SEM_ACQ_CIRC_GEQ | NVRM_SEM_PAYLOAD_64);
	pos = put_sem_frame(&pba, pos, sem.va, 0x100000003ULL,
	    NVRM_SEM_ACQ_CIRC_GEQ | NVRM_SEM_PAYLOAD_64);
	CHECK_EQ(pos, 36);
	(void)put_sem_frame(&pba, pos, sem.va, 0x100000004ULL,
	    NVRM_SEM_RELEASE | NVRM_SEM_PAYLOAD_64);
	(void)put_sem_frame(&pbb, 0, sem.va, 0x100000003ULL,
	    NVRM_SEM_RELEASE | NVRM_SEM_PAYLOAD_64);
	(void)put_sem_frame(&pbb, 6, sem.va, 0x100000004ULL,
	    NVRM_SEM_ACQUIRE | NVRM_SEM_PAYLOAD_64);
	ea[0] = (nvrm_gp_entry){ .va = pba.va, .dwords = 36 };
	ea[1] = (nvrm_gp_entry){ .va = pba.va + 36 * 4, .dwords = 6 };
	eb[0] = (nvrm_gp_entry){ .va = pbb.va, .dwords = 6 };
	eb[1] = (nvrm_gp_entry){ .va = pbb.va + 6 * 4, .dwords = 6 };
	nvrm_fake_chan_manual(1);
	CHECK_EQ(nvrm_chan_submit(a, ea, 2, NULL, &ra), NVRM_OK);
	CHECK_EQ(nvrm_chan_submit(b, eb, 2, NULL, &rb), NVRM_OK);
	CHECK_EQ(nvrm_fake_chan_step(a, 1), NVRM_OK);
	CHECK_EQ(nvrm_fake_chan_counts(a).acquires, 4);
	CHECK_EQ(nvrm_mem_read(sem.mem, 0, &value, sizeof(value)), NVRM_OK);
	CHECK_EQ(value, 0x100000002ULL);
	CHECK_EQ(nvrm_fake_chan_step(b, 1), NVRM_OK);
	CHECK_EQ(nvrm_fake_chan_step(b, 1), NVRM_OK);
	CHECK_EQ(nvrm_fake_chan_counts(b).acquires, 1);
	CHECK_EQ(nvrm_fake_chan_step(a, 2), NVRM_OK);
	CHECK_EQ(nvrm_fake_chan_step(b, 1), NVRM_OK);
	drain(a, 4);
	drain(b, 4);
	CHECK_EQ(nvrm_chan_wait(a, ra.point, 0), NVRM_OK);
	CHECK_EQ(nvrm_chan_wait(b, rb.point, 0), NVRM_OK);
	CHECK_EQ(nvrm_mem_read(sem.mem, 0, &value, sizeof(value)), NVRM_OK);
	CHECK_EQ(value, 0x100000004ULL);
	ca = nvrm_fake_chan_counts(a);
	cb = nvrm_fake_chan_counts(b);
	CHECK_EQ(ca.releases, 4); /* three host releases plus the core release */
	CHECK_EQ(cb.releases, 2); /* one host release plus the core release */
	CHECK_EQ(ca.methods, 8 * 5 + 1); /* only the waiting acquire is retried */
	CHECK_EQ(cb.methods, 3 * 5 + 1);
	CHECK(ca.acquires >= 4);
	CHECK(cb.acquires >= 1);
	nvrm_chan_destroy(a);
	nvrm_chan_destroy(b);
	buf_release(cl, &sem);
	buf_release(cl, &pbb);
	buf_release(cl, &pba);
	teardown(cl);
}

static void
expect_bad_create(nvrm_client *cl, nvrm_chan_params p, const char *message)
{
	nvrm_chan *ch = (nvrm_chan *)(uintptr_t)1;

	CHECK_EQ(nvrm_chan_create(cl, &p, &ch), NVRM_E_INVAL);
	CHECK(ch == NULL);
	CHECK(strstr(nvrm_client_errmsg(cl), message) != NULL);
}

static void
test_create_arguments(void)
{
	nvrm_chan_params p = { .engines = NVRM_ENG_COMPUTE, .entries = 8 };
	nvrm_chan_info info = { .size = sizeof(info) };
	const nvrm_backend_ops *saved;
	nvrm_backend_ops be;
	nvrm_client *cl, *plain;
	nvrm_chan *ch;

	setup();
	cl = open_client();
	p.size = 1;
	expect_bad_create(cl, p, "params.size");
	p.size = 0;
	p.engines = 0;
	expect_bad_create(cl, p, "engines");
	p.engines = 0x20;
	expect_bad_create(cl, p, "engines");
	p.engines = NVRM_ENG_COMPUTE;
	p.flags = 1;
	expect_bad_create(cl, p, "flags");
	p.flags = 0;
	p.entries = 7;
	expect_bad_create(cl, p, "entries");
	p.entries = 9;
	expect_bad_create(cl, p, "entries");
	p.entries = 65536;
	expect_bad_create(cl, p, "entries");
	p.entries = 0;
	ch = make_chan(cl, NVRM_ENG_COMPUTE, 0);
	CHECK_EQ(nvrm_chan_info_get(ch, &info), NVRM_OK);
	CHECK_EQ(info.entries, NVRM_CHAN_ENTRIES_DEFAULT);
	nvrm_chan_destroy(ch);
	ch = make_chan(cl, NVRM_ENG_3D | NVRM_ENG_COMPUTE | NVRM_ENG_I2M |
	    NVRM_ENG_2D | NVRM_ENG_COPY, 8);
	CHECK_EQ(nvrm_chan_info_get(ch, &info), NVRM_OK);
	CHECK_EQ(info.subch_class[0], NVRM_FAKE_CLASS_3D);
	CHECK_EQ(info.subch_class[1], NVRM_FAKE_CLASS_COMPUTE);
	CHECK_EQ(info.subch_class[2], NVRM_FAKE_CLASS_I2M);
	CHECK_EQ(info.subch_class[3], NVRM_FAKE_CLASS_2D);
	CHECK_EQ(info.subch_class[4], NVRM_FAKE_CLASS_COPY);
	nvrm_chan_destroy(ch);

	plain = open_client_flags(0);
	ch = (nvrm_chan *)(uintptr_t)1;
	CHECK_EQ(nvrm_chan_create(plain, &p, &ch), NVRM_E_DENIED);
	CHECK(ch == NULL);
	CHECK(strstr(nvrm_client_errmsg(plain), "NVRM_OPEN_ALLOW_MAP") != NULL);
	nvrm_client_close(plain);

	saved = cl->ops;
	be = *saved;
	be.chan = NULL;
	cl->ops = &be;
	ch = (nvrm_chan *)(uintptr_t)1;
	CHECK_EQ(nvrm_chan_create(cl, &p, &ch), NVRM_E_NOTSUP);
	CHECK(ch == NULL);
	CHECK(strstr(nvrm_client_errmsg(cl), "no channels") != NULL);
	cl->ops = saved;
	teardown(cl);
}

static void
expect_bad_submit(nvrm_chan *ch, const nvrm_gp_entry *e, unsigned n,
    const nvrm_submit_opts *o, const char *message)
{
	nvrm_submit_result r = { .size = sizeof(r) };

	CHECK_EQ(nvrm_chan_submit(ch, e, n, o, &r), NVRM_E_INVAL);
	CHECK_EQ(r.accepted, 0);
	CHECK_EQ(r.point, 0);
	CHECK(strstr(nvrm_client_errmsg(ch->cl), message) != NULL);
}

static void
test_submit_arguments(void)
{
	nvrm_gp_entry e[8] = { { .va = 0x1000, .dwords = 1 } };
	nvrm_submit_opts o = { .size = sizeof(o), .timeout_ns = 0 };
	nvrm_submit_result r = { .size = sizeof(r) };
	nvrm_chan_status st = { .size = sizeof(st) };
	nvrm_chan_info info = { .size = sizeof(info) };
	test_buf pb;
	nvrm_client *cl;
	nvrm_chan *ch;
	unsigned space = 0, i;

	setup();
	cl = open_client();
	ch = make_chan(cl, NVRM_ENG_COMPUTE, 8);
	CHECK_EQ(buf_init(cl, &pb, 4096), NVRM_OK);
	make_nops(&pb, 8);
	for (i = 0; i < 8; i++)
		e[i] = buf_entry(&pb, i, 0);
	CHECK_EQ(nvrm_chan_gp_space(ch, &space), NVRM_OK);
	CHECK_EQ(space, 6);
	o.size = 1;
	expect_bad_submit(ch, e, 1, &o, "opts.size");
	o.size = sizeof(o);
	o.flags = 2;
	expect_bad_submit(ch, e, 1, &o, "flags");
	o.flags = 0;
	r.size = 1;
	CHECK_EQ(nvrm_chan_submit(ch, e, 1, &o, &r), NVRM_E_INVAL);
	CHECK(strstr(nvrm_client_errmsg(cl), "result.size") != NULL);
	expect_bad_submit(ch, NULL, 0, &o, "at least one");
	e[0].va = 0;
	expect_bad_submit(ch, e, 1, &o, "element 0");
	e[0].va = 2;
	expect_bad_submit(ch, e, 1, &o, "element 0");
	e[0].va = 1ULL << 40;
	expect_bad_submit(ch, e, 1, &o, "element 0");
	e[0] = buf_entry(&pb, 0, 0);
	e[0].dwords = 0;
	expect_bad_submit(ch, e, 1, &o, "dword count");
	e[0].dwords = 1U << 21;
	expect_bad_submit(ch, e, 1, &o, "dword count");
	e[0].dwords = 1;
	e[0].flags = 4;
	expect_bad_submit(ch, e, 1, &o, "unknown flags");
	e[0].flags = NVRM_GP_INCOMPLETE;
	expect_bad_submit(ch, e, 1, &o, "without a terminator");
	e[0].flags = 0;
	st.size = 1;
	CHECK_EQ(nvrm_chan_status_get(ch, &st), NVRM_E_INVAL);
	CHECK(strstr(nvrm_client_errmsg(cl), "status.size") != NULL);
	info.size = 1;
	CHECK_EQ(nvrm_chan_info_get(ch, &info), NVRM_E_INVAL);
	CHECK(strstr(nvrm_client_errmsg(cl), "info.size") != NULL);

	nvrm_fake_chan_manual(1);
	r.size = sizeof(r);
	CHECK_EQ(nvrm_chan_submit(ch, e, 8, &o, &r), NVRM_E_TIMEOUT);
	CHECK_EQ(r.accepted, 6);
	CHECK_EQ(r.point, 1);
	CHECK(strstr(nvrm_client_errmsg(cl), "ring space") != NULL);
	drain(ch, 7);
	CHECK_EQ(nvrm_chan_wait(ch, r.point, 0), NVRM_OK);
	r.size = sizeof(r);
	CHECK_EQ(nvrm_chan_submit(ch, e + 6, 2, &o, &r), NVRM_OK);
	CHECK_EQ(r.accepted, 2);
	CHECK_EQ(r.point, 2);
	drain(ch, 3);
	CHECK_EQ(nvrm_chan_wait(ch, r.point, 0), NVRM_OK);
	nvrm_chan_destroy(ch);
	buf_release(cl, &pb);
	teardown(cl);
}

static void
swap_destroy_ops(nvrm_client *cl, nvrm_backend_ops *be, nvrm_chan_ops *co,
    const nvrm_backend_ops **saved)
{
	*saved = cl->ops;
	*co = nvrm_fake_chan_ops;
	co->destroy = counting_destroy;
	co->forget = counting_forget;
	co->gp_get = counting_gp_get;
	co->error = counting_error;
	co->progress_gen = counting_gen;
	co->wait = counting_wait;
	*be = **saved;
	be->chan = co;
	cl->ops = be;
	destroy_calls = 0;
	backend_calls = 0;
	forget_calls = 0;
	destroy_fails = 0;
}

/* m: a child drops records only; client close destroys a live channel. */
static void
test_fork_and_close(void)
{
	nvrm_chan_params p = { .engines = NVRM_ENG_COMPUTE, .entries = 8 };
	const nvrm_backend_ops *saved;
	nvrm_backend_ops be;
	nvrm_chan_ops co;
	nvrm_client_stats before, after;
	nvrm_submit_result r = { .size = sizeof(r) };
	nvrm_bchan *backend;
	test_buf pb;
	nvrm_client *cl;
	nvrm_chan *ch, *extra;
	char err[160];

	setup();
	cl = open_client();
	swap_destroy_ops(cl, &be, &co, &saved);
	ch = make_chan(cl, NVRM_ENG_COMPUTE, 8);
	CHECK_EQ(buf_init(cl, &pb, 4096), NVRM_OK);
	make_nops(&pb, 1);
	backend = ch->b;
	before = client_stats(cl);
	nvrm_getpid_hook = other_pid;
	extra = (nvrm_chan *)(uintptr_t)1;
	CHECK_EQ(nvrm_chan_create(cl, &p, &extra), NVRM_E_DENIED);
	CHECK(extra == NULL);
	CHECK(strstr(nvrm_client_errmsg(cl), "it may only release what it "
	    "holds and close the client") != NULL);
	CHECK_EQ(nvrm_chan_submit(ch, &(nvrm_gp_entry){ .va = pb.va,
	    .dwords = 1 }, 1, NULL, &r), NVRM_E_DENIED);
	CHECK_EQ(nvrm_chan_kick(ch), NVRM_E_DENIED);
	nvrm_chan_destroy(ch);
	CHECK_EQ(destroy_calls, 0);
	after = client_stats(cl);
	CHECK_EQ(after.live_channels, before.live_channels - 1);
	CHECK_EQ(after.live_mem, before.live_mem - 1);
	CHECK_EQ(after.live_reservations, before.live_reservations - 1);
	CHECK_EQ(after.live_gpu_maps, before.live_gpu_maps - 2);
	CHECK_EQ(after.live_cpu_maps, before.live_cpu_maps - 1);
	nvrm_getpid_hook = NULL;
	CHECK_EQ(co.destroy(backend, err, sizeof(err)), NVRM_OK);
	CHECK_EQ(destroy_calls, 1);
	cl->ops = saved;
	buf_release(cl, &pb);
	teardown(cl);

	setup();
	cl = open_client();
	swap_destroy_ops(cl, &be, &co, &saved);
	(void)make_chan(cl, NVRM_ENG_COMPUTE, 8);
	nvrm_client_close(cl);
	CHECK_EQ(destroy_calls, 1);
	teardown(NULL);
}

/* n: every create failure, including the backend itself, unwinds fully. */
static void
test_create_failures(void)
{
	nvrm_chan_params p = { .engines = NVRM_ENG_COMPUTE, .entries = 8 };
	const nvrm_backend_ops *saved;
	nvrm_client_stats baseline;
	nvrm_backend_ops be;
	nvrm_chan_ops co;
	nvrm_client *cl;
	nvrm_chan *ch;
	unsigned n;
	int op, rc;

	setup();
	cl = open_client();
	baseline = client_stats(cl);
	for (n = 1; n < 24; n++) {
		ch = (nvrm_chan *)(uintptr_t)1;
		fail_calloc_at(n);
		rc = nvrm_chan_create(cl, &p, &ch);
		fail_calloc_at(0);
		if (rc == NVRM_OK) {
			CHECK(ch != NULL);
			nvrm_chan_destroy(ch);
			break;
		}
		CHECK_EQ(rc, NVRM_E_NOMEM);
		CHECK(ch == NULL);
		CHECK(nvrm_client_errmsg(cl)[0] != '\0');
		check_live_stats(cl, &baseline);
	}
	CHECK(n > 1 && n < 24);
	check_live_stats(cl, &baseline);

	for (op = NVRM_FAKE_OP_VA_RESERVE; op <= NVRM_FAKE_OP_MAP_CPU; op++) {
		if (op == NVRM_FAKE_OP_REGISTER)
			continue;
		ch = (nvrm_chan *)(uintptr_t)1;
		nvrm_fake_mem_fail(op, 1);
		CHECK_EQ(nvrm_chan_create(cl, &p, &ch), NVRM_E_RM);
		CHECK(ch == NULL);
		CHECK(strstr(nvrm_client_errmsg(cl), "injected") != NULL);
		check_live_stats(cl, &baseline);
	}

	saved = cl->ops;
	co = nvrm_fake_chan_ops;
	co.create = reject_create;
	be = *saved;
	be.chan = &co;
	cl->ops = &be;
	ch = (nvrm_chan *)(uintptr_t)1;
	CHECK_EQ(nvrm_chan_create(cl, &p, &ch), NVRM_E_RM);
	CHECK(ch == NULL);
	CHECK(strstr(nvrm_client_errmsg(cl), "channel create") != NULL);
	check_live_stats(cl, &baseline);
	cl->ops = saved;

	/* the fake backend's own injected refusal: the create is refused
	 * with a message of its own, so a caller that reads the reason sees
	 * it */
	setenv("NVRM_FAKE_FAIL", "chancreate", 1);
	ch = (nvrm_chan *)(uintptr_t)1;
	CHECK_EQ(nvrm_chan_create(cl, &p, &ch), NVRM_E_RM);
	unsetenv("NVRM_FAKE_FAIL");
	CHECK(ch == NULL);
	CHECK(strstr(nvrm_client_errmsg(cl), "the channel create failed "
	    "(injected)") != NULL);
	check_live_stats(cl, &baseline);

	/* another injected failure does not refuse the create: only the
	 * channel-create mode does */
	setenv("NVRM_FAKE_FAIL", "nogpu", 1);
	ch = NULL;
	CHECK_EQ(nvrm_chan_create(cl, &p, &ch), NVRM_OK);
	unsetenv("NVRM_FAKE_FAIL");
	CHECK(ch != NULL);
	nvrm_chan_destroy(ch);
	check_live_stats(cl, &baseline);
	teardown(cl);
}

/* o: repeated publication, execution, waiting and teardown do not leak. */
static void
test_lifetime(void)
{
	nvrm_gp_entry e;
	nvrm_submit_result r = { .size = sizeof(r) };
	nvrm_chan_status st = { .size = sizeof(st) };
	nvrm_client_stats baseline, final;
	nvrm_fake_chan_counts_t counts;
	test_buf pb;
	nvrm_client *cl;
	nvrm_chan *ch;
	unsigned i;

	setup();
	cl = open_client();
	CHECK_EQ(buf_init(cl, &pb, 4096), NVRM_OK);
	baseline = client_stats(cl);
	ch = make_chan(cl, NVRM_ENG_COMPUTE, 8);
	make_nops(&pb, 1);
	e = buf_entry(&pb, 0, 0);
	for (i = 0; i < 100000; i++) {
		CHECK_EQ(nvrm_chan_submit(ch, &e, 1, NULL, &r), NVRM_OK);
		CHECK_EQ(nvrm_chan_wait(ch, r.point, 0), NVRM_OK);
	}
	CHECK_EQ(r.accepted, 1);
	CHECK_EQ(r.point, 100000);
	CHECK_EQ(nvrm_chan_status_get(ch, &st), NVRM_OK);
	CHECK_EQ(st.submitted, 100000);
	CHECK_EQ(st.completed, 100000);
	counts = nvrm_fake_chan_counts(ch);
	CHECK_EQ(counts.entries, 200000);
	CHECK_EQ(counts.nops, 100000);
	CHECK_EQ(counts.releases, 100000);
	nvrm_chan_destroy(ch);
	check_live_stats(cl, &baseline);
	buf_release(cl, &pb);
	final = client_stats(cl);
	CHECK_EQ(final.live_mem, 0);
	CHECK_EQ(final.live_reservations, 0);
	CHECK_EQ(final.live_gpu_maps, 0);
	CHECK_EQ(final.live_cpu_maps, 0);
	CHECK_EQ(final.live_channels, 0);
	CHECK_EQ(final.channels_created, 1);
	teardown(cl);
}

static void check_dead(nvrm_chan *ch, uint32_t error);

static void
test_ticket_timeout(void)
{
	nvrm_gp_entry initial[6], ea[6], eb[1];
	nvrm_submit_opts oa = { .size = sizeof(oa), .timeout_ns = 300000000 };
	nvrm_submit_opts ob = { .size = sizeof(ob), .timeout_ns = 0 };
	nvrm_submit_result r = { .size = sizeof(r) };
	submit_arg a, b;
	pthread_t ta, tb;
	test_buf pb;
	nvrm_client *cl;
	nvrm_chan *ch;
	unsigned i;

	setup();
	cl = open_client();
	ch = make_chan(cl, NVRM_ENG_COMPUTE, 8);
	CHECK_EQ(buf_init(cl, &pb, 4096), NVRM_OK);
	make_nops(&pb, 7);
	for (i = 0; i < 6; i++)
		initial[i] = ea[i] = buf_entry(&pb, i, 0);
	eb[0] = buf_entry(&pb, 6, 0);
	nvrm_fake_chan_manual(1);
	nvrm_chan_slice_ns = 1000000ULL;
	CHECK_EQ(nvrm_chan_submit(ch, initial, 6, NULL, &r), NVRM_OK);
	a = (submit_arg){ .ch = ch, .e = ea, .n = 6, .o = &oa };
	b = (submit_arg){ .ch = ch, .e = eb, .n = 1, .o = &ob };
	submit_start(&ta, &a);
	wait_queued(ch, 1);
	submit_start(&tb, &b);
	submit_join(ta, &a);
	submit_join(tb, &b);
	CHECK_EQ(a.rc, NVRM_E_TIMEOUT);
	CHECK_EQ(b.rc, NVRM_E_TIMEOUT);
	CHECK_EQ(a.r.accepted, 0);
	CHECK_EQ(b.r.accepted, 0);
	CHECK_EQ(a.r.point, 0);
	CHECK_EQ(b.r.point, 0);
	CHECK_EQ(queue_len(ch), 0);
	drain(ch, 7);
	CHECK_EQ(nvrm_chan_submit(ch, eb, 1, &ob, &b.r), NVRM_OK);
	CHECK_EQ(b.r.accepted, 1);
	CHECK_EQ(b.r.point, 2);
	drain(ch, 2);
	CHECK_EQ(nvrm_chan_wait(ch, b.r.point, 0), NVRM_OK);
	nvrm_chan_destroy(ch);
	buf_release(cl, &pb);
	teardown(cl);
}

/* Fill the ring of an 8-entry channel; the next 6-element submit must wait. */
static void
queue_fill(nvrm_client *cl, nvrm_chan **ch, test_buf *pb)
{
	nvrm_gp_entry initial[6];
	nvrm_submit_result r = { .size = sizeof(r) };
	unsigned i;

	*ch = make_chan(cl, NVRM_ENG_COMPUTE, 8);
	CHECK_EQ(buf_init(cl, pb, 4096), NVRM_OK);
	make_nops(pb, 7);
	for (i = 0; i < 6; i++)
		initial[i] = buf_entry(pb, i, 0);
	nvrm_fake_chan_manual(1);
	CHECK_EQ(nvrm_chan_submit(*ch, initial, 6, NULL, &r), NVRM_OK);
}

static void
six_entries(nvrm_gp_entry *e, const test_buf *b)
{
	unsigned i;

	for (i = 0; i < 6; i++)
		e[i] = buf_entry(b, i, 0);
}

/* A queued submit honours its own timeout and does not break the order. */
static void
test_queued_deadline(void)
{
	nvrm_gp_entry ea[6], eb[1], ec[1];
	nvrm_submit_opts ob = { .size = sizeof(ob), .timeout_ns = 50000000 };
	nvrm_chan_status st = { .size = sizeof(st) };
	submit_arg a, b, c;
	pthread_t ta, tb, tc;
	test_buf pb, abuf, cbuf;
	nvrm_client *cl;
	nvrm_chan *ch;
	uint64_t began, va;
	uint32_t dwords;
	unsigned i, seen_a = 0, seen_c = 0, c_after_a = 0;

	setup();
	cl = open_client();
	queue_fill(cl, &ch, &pb);
	CHECK_EQ(buf_init(cl, &abuf, 4096), NVRM_OK);
	CHECK_EQ(buf_init(cl, &cbuf, 4096), NVRM_OK);
	make_nops(&abuf, 6);
	make_nops(&cbuf, 1);
	six_entries(ea, &abuf);
	eb[0] = buf_entry(&pb, 6, 0);
	ec[0] = buf_entry(&cbuf, 0, 0);
	nvrm_chan_slice_ns = 1000000ULL;
	a = (submit_arg){ .ch = ch, .e = ea, .n = 6 };
	submit_start(&ta, &a);
	wait_queued(ch, 1);
	b = (submit_arg){ .ch = ch, .e = eb, .n = 1, .o = &ob };
	began = monotime();
	submit_start(&tb, &b);
	for (i = 0; i < 2000 && b.phase != 2; i++)
		usleep(1000);
	if (b.phase != 2) {
		CHECK(0 && "the queued submit ignored its timeout");
		exit(1);
	}
	submit_join(tb, &b);
	CHECK(monotime() - began < 1000000000ULL);
	CHECK_EQ(b.rc, NVRM_E_TIMEOUT);
	CHECK_EQ(b.r.accepted, 0);
	CHECK_EQ(b.r.point, 0);
	CHECK(strstr(nvrm_client_errmsg(cl), "earlier submits") != NULL);
	CHECK_EQ(queue_len(ch), 1);
	CHECK_EQ(__atomic_load_n(&a.phase, __ATOMIC_ACQUIRE), 1);
	CHECK_EQ(nvrm_fake_chan_step(ch, 7), NVRM_OK);
	submit_join(ta, &a);
	CHECK_EQ(a.rc, NVRM_OK);
	c = (submit_arg){ .ch = ch, .e = ec, .n = 1 };
	submit_start(&tc, &c);
	for (i = 0; i < 400 && (seen_a < 6 || seen_c < 1); i++) {
		CHECK_EQ(nvrm_chan_status_get(ch, &st), NVRM_OK);
		if (st.gp_get != st.gp_put) {
			decode_ring(ch, st.gp_get, &va, &dwords);
			if (va >= abuf.va && va < abuf.va + abuf.bytes)
				seen_a++;
			if (va >= cbuf.va && va < cbuf.va + cbuf.bytes) {
				c_after_a = seen_a == 6;
				seen_c++;
			}
			CHECK_EQ(nvrm_fake_chan_step(ch, 1), NVRM_OK);
		}
		usleep(2000);
	}
	submit_join(tc, &c);
	CHECK_EQ(c.rc, NVRM_OK);
	CHECK_EQ(seen_a, 6);
	CHECK_EQ(seen_c, 1);
	CHECK_EQ(c_after_a, 1);
	drain(ch, 9);
	nvrm_chan_destroy(ch);
	buf_release(cl, &cbuf);
	buf_release(cl, &abuf);
	buf_release(cl, &pb);
	teardown(cl);
}

/* The next submitter takes over when the head leaves, even with a ten-second
 * slice: two elements wait for space, and the one behind them then fits. */
static void
test_queue_handoff(void)
{
	nvrm_gp_entry ea[2], eb[1];
	submit_arg a, b;
	pthread_t ta, tb;
	test_buf pb, abuf;
	nvrm_client *cl;
	nvrm_chan *ch;
	uint64_t elapsed;

	setup();
	cl = open_client();
	queue_fill(cl, &ch, &pb);
	CHECK_EQ(buf_init(cl, &abuf, 4096), NVRM_OK);
	make_nops(&abuf, 2);
	nvrm_chan_slice_ns = 10000000000ULL;
	ea[0] = buf_entry(&abuf, 0, 0);
	ea[1] = buf_entry(&abuf, 1, 0);
	eb[0] = buf_entry(&pb, 6, 0);
	a = (submit_arg){ .ch = ch, .e = ea, .n = 2 };
	b = (submit_arg){ .ch = ch, .e = eb, .n = 1 };
	submit_start(&ta, &a);
	wait_queued(ch, 1);
	usleep(20000);
	submit_start(&tb, &b);
	wait_queued(ch, 2);
	usleep(20000);
	elapsed = step_and_wait(ch, 7, 4000, &b);
	if (b.phase != 2) {
		CHECK(0 && "the queued submit did not take its turn");
		exit(1);
	}
	submit_join(ta, &a);
	submit_join(tb, &b);
	CHECK_EQ(a.rc, NVRM_OK);
	CHECK_EQ(b.rc, NVRM_OK);
	CHECK(elapsed < 2000000000ULL);
	drain(ch, 9);
	nvrm_chan_destroy(ch);
	buf_release(cl, &abuf);
	buf_release(cl, &pb);
	teardown(cl);
}

/* A channel that dies releases the head and every queued submitter. */
static void
test_queue_death(void)
{
	nvrm_gp_entry ea[6], eb[1];
	submit_arg a, b;
	pthread_t ta, tb;
	test_buf pb, abuf;
	nvrm_client *cl;
	nvrm_chan *ch;

	setup();
	cl = open_client();
	queue_fill(cl, &ch, &pb);
	CHECK_EQ(buf_init(cl, &abuf, 4096), NVRM_OK);
	make_nops(&abuf, 6);
	six_entries(ea, &abuf);
	eb[0] = buf_entry(&pb, 6, 0);
	nvrm_chan_slice_ns = 10000000000ULL;
	a = (submit_arg){ .ch = ch, .e = ea, .n = 6 };
	b = (submit_arg){ .ch = ch, .e = eb, .n = 1 };
	submit_start(&ta, &a);
	wait_queued(ch, 1);
	usleep(20000);
	submit_start(&tb, &b);
	wait_queued(ch, 2);
	usleep(20000);
	nvrm_fake_chan_fault(ch, 77);
	submit_join(ta, &a);
	submit_join(tb, &b);
	CHECK_EQ(a.rc, NVRM_E_LOST);
	CHECK_EQ(b.rc, NVRM_E_LOST);
	CHECK_EQ(queue_len(ch), 0);
	check_dead(ch, 77);
	nvrm_chan_destroy(ch);
	buf_release(cl, &abuf);
	buf_release(cl, &pb);
	teardown(cl);
}

static void
test_wait_concurrency(void)
{
	nvrm_submit_result r = { .size = sizeof(r) };
	nvrm_gp_entry e;
	fake_action action;
	pthread_t tid;
	test_buf pb;
	nvrm_client *cl;
	nvrm_chan *ch;
	uint64_t began, elapsed;

	setup();
	cl = open_client();
	ch = make_chan(cl, NVRM_ENG_COMPUTE, 8);
	CHECK_EQ(buf_init(cl, &pb, 4096), NVRM_OK);
	make_nops(&pb, 1);
	e = buf_entry(&pb, 0, 0);
	nvrm_fake_chan_manual(1);
	CHECK_EQ(nvrm_chan_submit(ch, &e, 1, NULL, &r), NVRM_OK);
	action = (fake_action){ .ch = ch, .entries = 2 };
	CHECK_EQ(pthread_create(&tid, NULL, fake_action_thread, &action), 0);
	nvrm_chan_slice_ns = 10000000000ULL + 999999999ULL;
	began = monotime();
	CHECK_EQ(nvrm_chan_wait(ch, r.point, UINT64_MAX), NVRM_OK);
	elapsed = monotime() - began;
	CHECK_EQ(pthread_join(tid, NULL), 0);
	CHECK_EQ(action.rc, NVRM_OK);
	CHECK(elapsed < 2000000000ULL);

	CHECK_EQ(nvrm_chan_submit(ch, &e, 1, NULL, &r), NVRM_OK);
	nvrm_chan_slice_ns = 1000000ULL;
	began = monotime();
	CHECK_EQ(nvrm_chan_wait(ch, r.point, 20000000), NVRM_E_TIMEOUT);
	elapsed = monotime() - began;
	CHECK(elapsed >= 1000000ULL && elapsed < 2000000000ULL);
	action = (fake_action){ .ch = ch, .fault_code = 91 };
	CHECK_EQ(pthread_create(&tid, NULL, fake_action_thread, &action), 0);
	CHECK_EQ(nvrm_chan_wait(ch, r.point, UINT64_MAX), NVRM_E_LOST);
	CHECK_EQ(pthread_join(tid, NULL), 0);
	CHECK_EQ(action.rc, NVRM_OK);
	check_dead(ch, 91);
	CHECK_EQ(nvrm_chan_wait(ch, 1, 0), NVRM_OK);
	nvrm_chan_destroy(ch);
	buf_release(cl, &pb);
	teardown(cl);
}

static void
test_auto_rescan(void)
{
	nvrm_gp_entry ea, eb;
	nvrm_submit_result ra = { .size = sizeof(ra) };
	nvrm_submit_result rb = { .size = sizeof(rb) };
	nvrm_fake_chan_counts_t counts;
	test_buf pba, pbb, sem;
	nvrm_client *cl;
	nvrm_chan *a, *b;
	uint32_t value;

	setup();
	cl = open_client();
	a = make_chan(cl, NVRM_ENG_COMPUTE, 8);
	b = make_chan(cl, NVRM_ENG_COMPUTE, 8);
	CHECK_EQ(buf_init(cl, &pba, 4096), NVRM_OK);
	CHECK_EQ(buf_init(cl, &pbb, 4096), NVRM_OK);
	CHECK_EQ(buf_init(cl, &sem, 4096), NVRM_OK);
	*(uint32_t *)sem.cpu = 2;
	(void)put_sem_frame(&pbb, 0, sem.va, 2, NVRM_SEM_ACQ_CIRC_GEQ);
	put_inc(&pbb, 6, 0, NVRM_MTHD_SEM_ADDR_LO, 4);
	put_word(&pbb, 7, (uint32_t)sem.va & 0xfffffffcU);
	put_word(&pbb, 8, (uint32_t)(sem.va >> 32));
	put_word(&pbb, 9, 3);
	put_word(&pbb, 10, 0);
	put_word(&pbb, 11, nvrm_method_immd(0, NVRM_MTHD_SEM_EXECUTE,
	    NVRM_SEM_ACQ_CIRC_GEQ));
	(void)put_sem_frame(&pba, 0, sem.va, 3, NVRM_SEM_RELEASE);
	eb = (nvrm_gp_entry){ .va = pbb.va, .dwords = 12 };
	ea = (nvrm_gp_entry){ .va = pba.va, .dwords = 6 };

	CHECK_EQ(nvrm_chan_submit(b, &eb, 1, NULL, &rb), NVRM_OK);
	counts = nvrm_fake_chan_counts(b);
	CHECK_EQ(counts.entries, 0);
	CHECK_EQ(counts.acquires, 2);
	CHECK_EQ(nvrm_chan_wait(b, rb.point, 0), NVRM_E_TIMEOUT);
	CHECK_EQ(nvrm_chan_submit(a, &ea, 1, NULL, &ra), NVRM_OK);
	CHECK_EQ(nvrm_chan_wait(a, ra.point, 0), NVRM_OK);
	CHECK_EQ(nvrm_chan_wait(b, rb.point, 0), NVRM_OK);
	CHECK_EQ(nvrm_mem_read(sem.mem, 0, &value, sizeof(value)), NVRM_OK);
	CHECK_EQ(value, 3);
	counts = nvrm_fake_chan_counts(b);
	CHECK_EQ(counts.entries, 2);
	CHECK_EQ(counts.acquires, 4); /* one retry before A's release, one after */
	counts = nvrm_fake_chan_counts(a);
	CHECK_EQ(counts.entries, 2);
	CHECK_EQ(counts.releases, 2);
	nvrm_chan_destroy(b);
	nvrm_chan_destroy(a);
	buf_release(cl, &sem);
	buf_release(cl, &pbb);
	buf_release(cl, &pba);
	teardown(cl);
}

static void
check_dead(nvrm_chan *ch, uint32_t error)
{
	nvrm_chan_status st = { .size = sizeof(st) };

	CHECK_EQ(nvrm_chan_status_get(ch, &st), NVRM_OK);
	CHECK_EQ(st.state, NVRM_CHAN_DEAD);
	CHECK_EQ(st.error, error);
}

static void
expect_words_fault(nvrm_client *cl, uint32_t engines, const uint32_t *words,
    unsigned nwords, uint32_t error)
{
	nvrm_submit_result r = { .size = sizeof(r) };
	nvrm_gp_entry e;
	test_buf pb;
	nvrm_chan *ch;

	ch = make_chan(cl, engines, 8);
	CHECK_EQ(buf_init(cl, &pb, 4096), NVRM_OK);
	memcpy(pb.cpu, words, nwords * sizeof(*words));
	e = (nvrm_gp_entry){ .va = pb.va, .dwords = nwords };
	CHECK_EQ(nvrm_chan_submit(ch, &e, 1, NULL, &r), NVRM_OK);
	CHECK_EQ(nvrm_fake_chan_step(ch, 1), NVRM_OK);
	check_dead(ch, error);
	nvrm_chan_destroy(ch);
	buf_release(cl, &pb);
}

static void
test_method_faults(void)
{
	uint32_t storage[11];
	test_buf words = { .cpu = storage };
	nvrm_client *cl;
	uint32_t word;

	setup();
	cl = open_client();
	nvrm_fake_chan_manual(1);
	word = nvrm_method_header(0, NVRM_MTHD_NOP, 0, 0);
	expect_words_fault(cl, NVRM_ENG_COMPUTE, &word, 1,
	    NVRM_FAKE_CHAN_ERR_UNSUPPORTED);
	word = nvrm_method_header(0, NVRM_MTHD_NOP, 1, NVRM_MTHD_OP_INC);
	expect_words_fault(cl, NVRM_ENG_COMPUTE, &word, 1,
	    NVRM_FAKE_CHAN_ERR_UNSUPPORTED);

	(void)put_sem_frame(&words, 0, 0x1000, 1,
	    NVRM_SEM_RELEASE | NVRM_SEM_PAYLOAD_64);
	expect_words_fault(cl, NVRM_ENG_COMPUTE, storage, 6,
	    NVRM_FAKE_CHAN_ERR_MMU);
	(void)put_sem_frame(&words, 0, 0x1000, 1,
	    NVRM_SEM_ACQUIRE | NVRM_SEM_PAYLOAD_64);
	expect_words_fault(cl, NVRM_ENG_COMPUTE, storage, 6,
	    NVRM_FAKE_CHAN_ERR_MMU);
	(void)put_sem_frame(&words, 0, 0x1000, 1, NVRM_SEM_ACQUIRE);
	expect_words_fault(cl, NVRM_ENG_COMPUTE, storage, 6,
	    NVRM_FAKE_CHAN_ERR_MMU);
	(void)put_sem_frame(&words, 0, 0x1000, 1,
	    NVRM_SEM_ACQ_CIRC_GEQ | NVRM_SEM_PAYLOAD_64);
	expect_words_fault(cl, NVRM_ENG_COMPUTE, storage, 6,
	    NVRM_FAKE_CHAN_ERR_MMU);

	(void)put_copy_frame(&words, 0, &(copy_frame){
	    .launch = LAUNCH_PIPELINED_PITCH | NVRM_FAKE_COPY_LAUNCH_SEMAPHORE });
	expect_words_fault(cl, NVRM_ENG_COPY, storage, 11,
	    NVRM_FAKE_CHAN_ERR_UNSUPPORTED);
	(void)put_copy_frame(&words, 0, &(copy_frame){
	    .launch = NVRM_FAKE_COPY_TYPE_PIPELINED });
	expect_words_fault(cl, NVRM_ENG_COPY, storage, 11,
	    NVRM_FAKE_CHAN_ERR_UNSUPPORTED);
	(void)put_copy_frame(&words, 0, &(copy_frame){
	    .launch = NVRM_FAKE_COPY_TYPE_INVALID | LAUNCH_PITCH });
	expect_words_fault(cl, NVRM_ENG_COPY, storage, 11,
	    NVRM_FAKE_CHAN_ERR_UNSUPPORTED);
	(void)put_copy_frame(&words, 0, &(copy_frame){ .in = 0x1000,
	    .pitch_in = 64, .pitch_out = 64, .length = 64, .lines = 1,
	    .launch = LAUNCH_PIPELINED_PITCH });
	expect_words_fault(cl, NVRM_ENG_COPY, storage, 11,
	    NVRM_FAKE_CHAN_ERR_MMU);
	teardown(cl);
}

static void
test_method_matrix(void)
{
	nvrm_gp_entry e;
	nvrm_submit_result r = { .size = sizeof(r) };
	nvrm_fake_chan_counts_t counts;
	nvrm_chan_info info = { .size = sizeof(info) };
	test_buf pb, copy_pb;
	nvrm_client *cl;
	nvrm_chan *ch, *copy;
	unsigned pos;

	setup();
	cl = open_client();
	ch = make_chan(cl, NVRM_ENG_COMPUTE, 8);
	copy = make_chan(cl, NVRM_ENG_COPY, 8);
	CHECK_EQ(buf_init(cl, &pb, 4096), NVRM_OK);
	CHECK_EQ(buf_init(cl, &copy_pb, 4096), NVRM_OK);
	put_word(&pb, 0, nvrm_method_immd(2, NVRM_MTHD_SET_OBJECT, 0));
	put_word(&pb, 1, nvrm_method_immd(0, NVRM_MTHD_WFI, 0));
	put_word(&pb, 2, nvrm_method_immd(0, 0x7c, 0));
	put_word(&pb, 3, nvrm_method_immd(1, 0x400, 0));
	put_word(&pb, 4, nvrm_method_immd(4, 0x400, 0));
	put_inc(&pb, 5, 0, NVRM_MTHD_NOP, 2);
	((uint32_t *)pb.cpu)[5] = nvrm_method_header(0, NVRM_MTHD_NOP, 2,
	    NVRM_MTHD_OP_NON_INC);
	put_word(&pb, 6, 0x11);
	put_word(&pb, 7, 0x22);
	((uint32_t *)pb.cpu)[8] = nvrm_method_header(0, NVRM_MTHD_NOP, 2,
	    NVRM_MTHD_OP_ONE_INC);
	put_word(&pb, 9, 0x33);
	put_word(&pb, 10, 0x44);
	pos = put_sem_frame(&pb, 11, 0, 0, 2);
	CHECK_EQ(pos, 17);
	/* SET_OBJECT accepts the class granted on its subchannel. */
	put_inc(&pb, pos, 1, NVRM_MTHD_SET_OBJECT, 1);
	put_word(&pb, pos + 1, NVRM_FAKE_CLASS_COMPUTE);
	pos += 2;
	e = (nvrm_gp_entry){ .va = pb.va, .dwords = pos };
	CHECK_EQ(nvrm_chan_submit(ch, &e, 1, NULL, &r), NVRM_OK);
	CHECK_EQ(nvrm_chan_wait(ch, r.point, 0), NVRM_OK);
	CHECK_EQ(nvrm_chan_info_get(ch, &info), NVRM_OK);
	CHECK_EQ(info.subch_class[1], NVRM_FAKE_CLASS_COMPUTE);
	CHECK_EQ(info.subch_class[2], 0);
	counts = nvrm_fake_chan_counts(ch);
	CHECK_EQ(counts.entries, 2);
	CHECK_EQ(counts.methods, 20);
	CHECK_EQ(counts.nops, 3);
	CHECK_EQ(counts.ignored, 5);
	CHECK_EQ(counts.releases, 1);

	put_word(&copy_pb, 0, nvrm_method_immd(4, 0x500, 0));
	pos = put_copy_frame(&copy_pb, 1, &(copy_frame){ .length = 4096,
	    .lines = 4, .launch = LAUNCH_PITCH });
	e = (nvrm_gp_entry){ .va = copy_pb.va, .dwords = pos };
	CHECK_EQ(nvrm_chan_submit(copy, &e, 1, NULL, &r), NVRM_OK);
	CHECK_EQ(nvrm_chan_wait(copy, r.point, 0), NVRM_OK);
	counts = nvrm_fake_chan_counts(copy);
	CHECK_EQ(counts.copies, 1);
	CHECK_EQ(counts.bytes_copied, 0);
	CHECK_EQ(counts.ignored, 1);
	CHECK_EQ(counts.entries, 2);
	nvrm_chan_destroy(copy);
	nvrm_chan_destroy(ch);
	buf_release(cl, &copy_pb);
	buf_release(cl, &pb);
	teardown(cl);
}

static void
test_load_entry_failures(void)
{
	const nvrm_backend_ops *saved;
	nvrm_backend_ops be;
	nvrm_chan_ops co;
	nvrm_submit_result r = { .size = sizeof(r) };
	nvrm_chan_status st = { .size = sizeof(st) };
	nvrm_gp_entry e;
	test_buf pb;
	nvrm_client *cl;
	nvrm_chan *ch;

	setup();
	cl = open_client();
	ch = make_chan(cl, NVRM_ENG_COMPUTE, 8);
	CHECK_EQ(buf_init(cl, &pb, 4096), NVRM_OK);
	make_nops(&pb, 1);
	e = buf_entry(&pb, 0, 0);
	fail_calloc_at(1);
	CHECK_EQ(nvrm_chan_submit(ch, &e, 1, NULL, &r), NVRM_OK);
	fail_calloc_at(0);
	CHECK_EQ(nvrm_chan_status_get(ch, &st), NVRM_OK);
	CHECK_EQ(st.state, NVRM_CHAN_ALIVE);
	CHECK_EQ(st.submitted, 1);
	CHECK_EQ(st.completed, 0);
	CHECK_EQ(st.gp_get, 0);
	nvrm_fake_chan_manual(1);
	fail_calloc_at(1);
	CHECK_EQ(nvrm_fake_chan_step(ch, 2), NVRM_E_NOMEM);
	fail_calloc_at(0);
	CHECK_EQ(nvrm_fake_chan_step(ch, 2), NVRM_OK);
	CHECK_EQ(nvrm_chan_wait(ch, r.point, 0), NVRM_OK);
	nvrm_chan_destroy(ch);
	nvrm_fake_chan_manual(0);

	saved = cl->ops;
	co = nvrm_fake_chan_ops;
	co.create = miswired_create;
	be = *saved;
	be.chan = &co;
	cl->ops = &be;
	ch = make_chan(cl, NVRM_ENG_COMPUTE, 8);
	nvrm_fake_chan_manual(1);
	CHECK_EQ(nvrm_chan_submit(ch, &e, 1, NULL, &r), NVRM_OK);
	CHECK_EQ(nvrm_fake_chan_step(ch, 1), NVRM_OK);
	check_dead(ch, NVRM_FAKE_CHAN_ERR_MMU);
	nvrm_chan_destroy(ch);
	cl->ops = saved;
	buf_release(cl, &pb);
	teardown(cl);
}

/* k: fetch and copy MMU faults kill only the channel that caused them. */
static void
test_faults(void)
{
	nvrm_gp_entry bad_e = { .va = 0x1000, .dwords = 1 };
	nvrm_gp_entry copy_e, survivor_e;
	nvrm_submit_result r = { .size = sizeof(r) };
	nvrm_submit_result survivor_r = { .size = sizeof(survivor_r) };
	nvrm_fake_chan_counts_t counts;
	test_buf copy_pb, survivor_pb, src, dst;
	nvrm_client *cl;
	nvrm_chan *bad, *copy, *survivor;
	uint64_t began, elapsed;
	unsigned space = 99;

	setup();
	cl = open_client();
	bad = make_chan(cl, NVRM_ENG_COMPUTE, 8);
	copy = make_chan(cl, NVRM_ENG_COPY, 8);
	survivor = make_chan(cl, NVRM_ENG_COMPUTE, 8);
	CHECK_EQ(buf_init(cl, &copy_pb, 4096), NVRM_OK);
	CHECK_EQ(buf_init(cl, &survivor_pb, 4096), NVRM_OK);
	CHECK_EQ(buf_init(cl, &src, 4096), NVRM_OK);
	CHECK_EQ(buf_init_flags(cl, &dst, 4096, NVRM_MAP_READ_ONLY), NVRM_OK);
	make_nops(&survivor_pb, 1);
	survivor_e = buf_entry(&survivor_pb, 0, 0);
	(void)put_copy_frame(&copy_pb, 0, &(copy_frame){ .in = src.va,
	    .out = dst.va, .pitch_in = 64, .pitch_out = 64, .length = 64,
	    .lines = 1, .launch = LAUNCH_PIPELINED_PITCH });
	copy_e = (nvrm_gp_entry){ .va = copy_pb.va, .dwords = 11 };
	nvrm_fake_chan_manual(1);
	nvrm_chan_slice_ns = 50000000ULL;

	CHECK_EQ(nvrm_chan_submit(bad, &bad_e, 1, NULL, &r), NVRM_OK);
	CHECK_EQ(nvrm_fake_chan_step(bad, 1), NVRM_OK);
	check_dead(bad, NVRM_FAKE_CHAN_ERR_MMU);
	began = monotime();
	CHECK_EQ(nvrm_chan_wait(bad, r.point, UINT64_MAX), NVRM_E_LOST);
	elapsed = monotime() - began;
	CHECK(elapsed < 2 * nvrm_chan_slice_ns);
	CHECK_EQ(nvrm_chan_wait(bad, 0, 0), NVRM_OK);
	CHECK_EQ(nvrm_chan_submit(bad, &bad_e, 1, NULL, &r), NVRM_E_LOST);
	CHECK_EQ(r.accepted, 0);
	CHECK(strstr(nvrm_client_errmsg(cl), "the channel is dead (error "
	    "notifier 31): destroy it and create a new channel") != NULL);
	CHECK_EQ(nvrm_chan_kick(bad), NVRM_E_LOST);
	CHECK_EQ(nvrm_chan_gp_space(bad, &space), NVRM_E_LOST);
	CHECK_EQ(space, 99);

	CHECK_EQ(nvrm_chan_submit(survivor, &survivor_e, 1, NULL,
	    &survivor_r), NVRM_OK);
	CHECK_EQ(nvrm_fake_chan_step(survivor, 2), NVRM_OK);
	CHECK_EQ(nvrm_chan_wait(survivor, survivor_r.point, 0), NVRM_OK);

	CHECK_EQ(nvrm_chan_submit(copy, &copy_e, 1, NULL, &r), NVRM_OK);
	CHECK_EQ(nvrm_fake_chan_step(copy, 1), NVRM_OK);
	check_dead(copy, NVRM_FAKE_CHAN_ERR_MMU);
	counts = nvrm_fake_chan_counts(copy);
	CHECK_EQ(counts.copies, 1);
	CHECK_EQ(counts.bytes_copied, 0);
	CHECK_EQ(nvrm_chan_wait(copy, r.point, 0), NVRM_E_LOST);
	CHECK_EQ(nvrm_fake_chan_step(copy, 2), NVRM_OK);

	CHECK_EQ(nvrm_chan_submit(survivor, &survivor_e, 1, NULL,
	    &survivor_r), NVRM_OK);
	CHECK_EQ(nvrm_fake_chan_step(survivor, 2), NVRM_OK);
	CHECK_EQ(nvrm_chan_wait(survivor, survivor_r.point, 0), NVRM_OK);
	nvrm_fake_chan_fault(survivor, 77);
	check_dead(survivor, 77);
	nvrm_fake_chan_fault(survivor, 88);
	check_dead(survivor, 77);

	nvrm_chan_destroy(bad);
	nvrm_chan_destroy(copy);
	nvrm_chan_destroy(survivor);
	buf_release(cl, &dst);
	buf_release(cl, &src);
	buf_release(cl, &survivor_pb);
	buf_release(cl, &copy_pb);
	teardown(cl);
}

/* l: completed, impossible, pending and zero-point waits are distinct. */
static void
test_wait_rules(void)
{
	nvrm_gp_entry e;
	nvrm_submit_result r = { .size = sizeof(r) };
	test_buf pb;
	nvrm_client *cl;
	nvrm_chan *ch;

	setup();
	cl = open_client();
	ch = make_chan(cl, NVRM_ENG_COMPUTE, 8);
	CHECK_EQ(buf_init(cl, &pb, 4096), NVRM_OK);
	make_nops(&pb, 1);
	e = buf_entry(&pb, 0, 0);
	nvrm_fake_chan_manual(1);
	CHECK_EQ(nvrm_chan_wait(ch, 0, 0), NVRM_OK);
	CHECK_EQ(nvrm_chan_wait(ch, 0, UINT64_MAX - 1), NVRM_OK);
	CHECK_EQ(nvrm_chan_wait(ch, 1, 0), NVRM_E_INVAL);
	CHECK(strstr(nvrm_client_errmsg(cl), "exceeds submitted") != NULL);
	CHECK_EQ(nvrm_chan_submit(ch, &e, 1, NULL, &r), NVRM_OK);
	CHECK_EQ(nvrm_chan_wait(ch, r.point, 0), NVRM_E_TIMEOUT);
	CHECK(strstr(nvrm_client_errmsg(cl), "progress point") != NULL);
	drain(ch, 2);
	CHECK_EQ(nvrm_chan_wait(ch, r.point, UINT64_MAX), NVRM_OK);
	CHECK_EQ(nvrm_chan_wait(ch, r.point + 1, 0), NVRM_E_INVAL);
	nvrm_fake_chan_fault(ch, NVRM_FAKE_CHAN_ERR_MMU);
	CHECK_EQ(nvrm_chan_wait(ch, r.point + 5, 0), NVRM_E_LOST);
	nvrm_chan_destroy(ch);
	buf_release(cl, &pb);
	teardown(cl);
}

static void
check_copy_results(const test_buf *src, const test_buf *dst)
{
	static uint8_t expected[64 * KIB], back[64 * KIB];
	const uint8_t *s = src->cpu;
	unsigned line;

	CHECK_EQ(nvrm_mem_read(dst->mem, 0, back, sizeof(back)), NVRM_OK);
	CHECK(memcmp(back, s, sizeof(back)) == 0);
	for (line = 0; line < 16; line++)
		memcpy(expected + line * 4096, s + 128 * KIB + line * 8192,
		    4096);
	CHECK_EQ(nvrm_mem_read(dst->mem, 128 * KIB, back, sizeof(back)),
	    NVRM_OK);
	CHECK(memcmp(back, expected, sizeof(back)) == 0);
}

/* j: the copy class handles linear and pitched transfers of 64 KiB each. */
static void
test_copy(void)
{
	nvrm_gp_entry e[2];
	nvrm_submit_result r = { .size = sizeof(r) };
	nvrm_chan_params p = { .engines = NVRM_ENG_3D | NVRM_ENG_COPY,
	    .entries = 8 };
	nvrm_chan_info info = { .size = sizeof(info) };
	nvrm_fake_chan_counts_t counts;
	test_buf src, dst, pb;
	nvrm_client *cl;
	nvrm_chan *ch, *graphics, *refused = NULL;
	uint8_t *s;
	unsigned i, line, pos;

	setup();
	cl = open_client();
	ch = make_chan(cl, NVRM_ENG_COPY, 8);
	CHECK_EQ(nvrm_chan_info_get(ch, &info), NVRM_OK);
	CHECK_EQ(info.runlist, NVRM_RUNLIST_COPY);
	CHECK_EQ(info.subch_class[4], NVRM_FAKE_CLASS_COPY);
	CHECK_EQ(buf_init(cl, &src, 256 * KIB), NVRM_OK);
	CHECK_EQ(buf_init(cl, &dst, 256 * KIB), NVRM_OK);
	CHECK_EQ(buf_init(cl, &pb, 4096), NVRM_OK);
	s = src.cpu;
	for (i = 0; i < 64 * KIB; i++)
		s[i] = (uint8_t)(i * 13 + 7);
	for (line = 0; line < 16; line++)
		for (i = 0; i < 4096; i++)
			s[128 * KIB + line * 8192 + i] =
			    (uint8_t)(line * 29 + i * 3);
	pos = put_copy_frame(&pb, 0, &(copy_frame){ .in = src.va,
	    .out = dst.va, .pitch_in = 64 * KIB, .pitch_out = 64 * KIB,
	    .length = 64 * KIB, .lines = 1,
	    .launch = LAUNCH_PIPELINED_PITCH });
	pos = put_copy_frame(&pb, pos, &(copy_frame){
	    .in = src.va + 128 * KIB, .out = dst.va + 128 * KIB,
	    .pitch_in = 8192, .pitch_out = 4096, .length = 4096, .lines = 16,
	    .launch = LAUNCH_PIPELINED_PITCH | NVRM_FAKE_COPY_LAUNCH_MULTI_LINE });
	CHECK_EQ(pos, 22);
	e[0] = (nvrm_gp_entry){ .va = pb.va, .dwords = 11 };
	e[1] = (nvrm_gp_entry){ .va = pb.va + 11 * 4, .dwords = 11 };
	CHECK_EQ(nvrm_chan_submit(ch, e, 2, NULL, &r), NVRM_OK);
	CHECK_EQ(r.accepted, 2);
	CHECK_EQ(nvrm_chan_wait(ch, r.point, 0), NVRM_OK);
	counts = nvrm_fake_chan_counts(ch);
	CHECK_EQ(counts.copies, 2);
	CHECK_EQ(counts.bytes_copied, 128 * KIB);
	CHECK_EQ(counts.entries, 3);
	check_copy_results(&src, &dst);

	graphics = make_chan(cl, NVRM_ENG_3D | NVRM_ENG_COPY, 8);
	CHECK_EQ(nvrm_chan_info_get(graphics, &info), NVRM_OK);
	CHECK_EQ(info.runlist, NVRM_RUNLIST_GRAPHICS);
	CHECK_EQ(info.subch_class[4], NVRM_FAKE_CLASS_COPY);
	nvrm_fake_chan_ops.copy_on_graphics = 0;
	CHECK_EQ(nvrm_chan_create(cl, &p, &refused), NVRM_E_NOTSUP);
	CHECK(refused == NULL);
	CHECK(strstr(nvrm_client_errmsg(cl), "copy class") != NULL);
	nvrm_fake_chan_ops.copy_on_graphics = 1;
	nvrm_chan_destroy(graphics);
	nvrm_chan_destroy(ch);
	buf_release(cl, &pb);
	buf_release(cl, &dst);
	buf_release(cl, &src);
	teardown(cl);
}

/* ---- review round 1: wire format, kicks, wakeups, forks, GPU writes ---- */

static uint32_t
gold_header(unsigned subch, unsigned method, unsigned count, unsigned op)
{
	switch (op) {
	case NVRM_MTHD_OP_INC:
		return (DRF_NUM(906F, _DMA_INCR, _ADDRESS, method >> 2) |
		    DRF_NUM(906F, _DMA_INCR, _SUBCHANNEL, subch) |
		    DRF_NUM(906F, _DMA_INCR, _COUNT, count) |
		    DRF_DEF(906F, _DMA_INCR, _OPCODE, _VALUE));
	case NVRM_MTHD_OP_NON_INC:
		return (DRF_NUM(906F, _DMA_NONINCR, _ADDRESS, method >> 2) |
		    DRF_NUM(906F, _DMA_NONINCR, _SUBCHANNEL, subch) |
		    DRF_NUM(906F, _DMA_NONINCR, _COUNT, count) |
		    DRF_DEF(906F, _DMA_NONINCR, _OPCODE, _VALUE));
	case NVRM_MTHD_OP_ONE_INC:
		return (DRF_NUM(906F, _DMA_ONEINCR, _ADDRESS, method >> 2) |
		    DRF_NUM(906F, _DMA_ONEINCR, _SUBCHANNEL, subch) |
		    DRF_NUM(906F, _DMA_ONEINCR, _COUNT, count) |
		    DRF_DEF(906F, _DMA_ONEINCR, _OPCODE, _VALUE));
	default:
		return (DRF_NUM(906F, _DMA_IMMD, _ADDRESS, method >> 2) |
		    DRF_NUM(906F, _DMA_IMMD, _SUBCHANNEL, subch) |
		    DRF_NUM(906F, _DMA_IMMD, _DATA, count) |
		    DRF_DEF(906F, _DMA_IMMD, _OPCODE, _VALUE));
	}
}

static void
check_header_words(void)
{
	static const unsigned ops[] = { NVRM_MTHD_OP_INC, NVRM_MTHD_OP_NON_INC,
	    NVRM_MTHD_OP_IMMD, NVRM_MTHD_OP_ONE_INC };
	uint32_t hdr;
	unsigned i;

	for (i = 0; i < sizeof(ops) / sizeof(ops[0]); i++) {
		hdr = nvrm_method_header(5, NVRM_MTHD_SEM_EXECUTE, 0x123,
		    ops[i]);
		CHECK_EQ(hdr, gold_header(5, NVRM_MTHD_SEM_EXECUTE, 0x123,
		    ops[i]));
		CHECK_EQ(nvrm_method_op(hdr), ops[i]);
		CHECK_EQ(nvrm_method_subch(hdr), 5);
		CHECK_EQ(nvrm_method_address(hdr), NVRM_MTHD_SEM_EXECUTE);
		CHECK_EQ(nvrm_method_count(hdr), 0x123);
	}
	CHECK_EQ(nvrm_method_immd(3, NVRM_MTHD_WFI, 0x1abc),
	    gold_header(3, NVRM_MTHD_WFI, 0x1abc, NVRM_MTHD_OP_IMMD));
}

static void
check_method_numbers(void)
{
	CHECK_EQ(NVRM_MTHD_SET_OBJECT, NVC86F_SET_OBJECT);
	CHECK_EQ(NVRM_MTHD_NOP, NV906F_NOP);
	CHECK_EQ(NVRM_MTHD_SEM_ADDR_LO, NVC86F_SEM_ADDR_LO);
	CHECK_EQ(NVRM_MTHD_SEM_ADDR_HI, NVC86F_SEM_ADDR_HI);
	CHECK_EQ(NVRM_MTHD_SEM_PAYLOAD_LO, NVC86F_SEM_PAYLOAD_LO);
	CHECK_EQ(NVRM_MTHD_SEM_PAYLOAD_HI, NVC86F_SEM_PAYLOAD_HI);
	CHECK_EQ(NVRM_MTHD_SEM_EXECUTE, NVC86F_SEM_EXECUTE);
	CHECK_EQ(NVRM_MTHD_WFI, NVC86F_WFI);
	CHECK_EQ(NVRM_SEM_ACQUIRE, DRF_DEF(C86F, _SEM_EXECUTE, _OPERATION,
	    _ACQUIRE));
	CHECK_EQ(NVRM_SEM_RELEASE, DRF_DEF(C86F, _SEM_EXECUTE, _OPERATION,
	    _RELEASE));
	CHECK_EQ(NVRM_SEM_ACQ_CIRC_GEQ, DRF_DEF(C86F, _SEM_EXECUTE,
	    _OPERATION, _ACQ_CIRC_GEQ));
	CHECK_EQ(NVRM_SEM_WFI, DRF_NUM(C86F, _SEM_EXECUTE, _RELEASE_WFI, 1));
	CHECK_EQ(NVRM_SEM_PAYLOAD_64, DRF_NUM(C86F, _SEM_EXECUTE,
	    _PAYLOAD_SIZE, 1));
}

/* The words of the host release and of a GP entry, built from the class
 * headers' own field macros: SEM_ADDR_LO holds va >> 2 in bits 31:2. */
static void
test_golden_words(void)
{
	const uint64_t sem_va = 0x12cdef1234ULL, point = 0x1122334455667788ULL;
	uint32_t seg[NVRM_RELEASE_SEG_DWORDS];
	uint32_t e0, e1;
	unsigned n, i;

	check_header_words();
	check_method_numbers();
	memset(seg, 0xee, sizeof(seg));
	n = nvrm_release_segment(seg, sem_va, point);
	CHECK_EQ(n, NVRM_RELEASE_DWORDS);
	CHECK_EQ(seg[0], gold_header(0, NVC86F_SEM_ADDR_LO, 5,
	    NVRM_MTHD_OP_INC));
	CHECK_EQ(seg[1], DRF_NUM(C86F, _SEM_ADDR_LO, _OFFSET,
	    (uint32_t)(sem_va >> 2)));
	CHECK_EQ(seg[1], 0xcdef1234);
	CHECK_EQ(seg[2], DRF_NUM(C86F, _SEM_ADDR_HI, _OFFSET,
	    (uint32_t)(sem_va >> 32)));
	CHECK_EQ(seg[3], 0x55667788);
	CHECK_EQ(seg[4], 0x11223344);
	CHECK_EQ(seg[5], DRF_DEF(C86F, _SEM_EXECUTE, _OPERATION, _RELEASE) |
	    DRF_NUM(C86F, _SEM_EXECUTE, _RELEASE_WFI, 1) |
	    DRF_NUM(C86F, _SEM_EXECUTE, _PAYLOAD_SIZE, 1));
	for (i = n; i < NVRM_RELEASE_SEG_DWORDS; i++)
		CHECK_EQ(seg[i], 0);

	e0 = nvrm_gp_entry0(sem_va);
	e1 = nvrm_gp_entry1(sem_va, 0x1234, 0);
	CHECK_EQ(e0, DRF_DEF(C86F, _GP_ENTRY0, _FETCH, _UNCONDITIONAL) |
	    DRF_NUM(C86F, _GP_ENTRY0, _GET, (uint32_t)(sem_va >> 2)));
	CHECK_EQ(e1, DRF_NUM(C86F, _GP_ENTRY1, _GET_HI,
	    (uint32_t)(sem_va >> 32)) | DRF_NUM(C86F, _GP_ENTRY1, _LENGTH,
	    0x1234) | DRF_DEF(C86F, _GP_ENTRY1, _SYNC, _PROCEED));
	CHECK_EQ(nvrm_gp_decode_va(e0, e1), sem_va);
	CHECK_EQ(nvrm_gp_decode_dwords(e1), 0x1234);
	CHECK_EQ(nvrm_gp_decode_no_prefetch(e1), 0);
	e1 = nvrm_gp_entry1(sem_va, 0x1234, 1);
	CHECK_EQ(e1, DRF_NUM(C86F, _GP_ENTRY1, _GET_HI,
	    (uint32_t)(sem_va >> 32)) | DRF_NUM(C86F, _GP_ENTRY1, _LENGTH,
	    0x1234) | DRF_DEF(C86F, _GP_ENTRY1, _SYNC, _WAIT));
	CHECK_EQ(nvrm_gp_decode_no_prefetch(e1), 1);
}

/* A NO_KICK submit that must wait for ring space rings the doorbell first:
 * in auto mode nothing else would ever drain the ring. */
static void
test_no_kick_space(void)
{
	nvrm_gp_entry e[12];
	nvrm_submit_opts o = { .size = sizeof(o), .flags = NVRM_SUBMIT_NO_KICK,
	    .timeout_ns = 1000000000ULL };
	nvrm_submit_opts ob = { .size = sizeof(ob), .timeout_ns = 1000000000ULL };
	nvrm_submit_result r = { .size = sizeof(r) };
	submit_arg a, b;
	pthread_t ta, tb;
	test_buf pb;
	nvrm_client *cl;
	nvrm_chan *ch;

	ch = setup_nops(&cl, &pb, 12, e);
	CHECK_EQ(nvrm_chan_submit(ch, e, 12, &o, &r), NVRM_OK);
	CHECK_EQ(r.accepted, 12);
	CHECK_EQ(r.point, 2);
	CHECK_EQ(nvrm_chan_kick(ch), NVRM_OK);
	CHECK_EQ(nvrm_chan_wait(ch, r.point, 0), NVRM_OK);

	/* a head that finds the ring held by unkicked work kicks it too */
	a = (submit_arg){ .ch = ch, .e = e, .n = 6, .o = &o };
	submit_start(&ta, &a);
	submit_join(ta, &a);
	CHECK_EQ(a.rc, NVRM_OK);
	CHECK_EQ(a.r.accepted, 6);
	b = (submit_arg){ .ch = ch, .e = e + 6, .n = 1, .o = &ob };
	submit_start(&tb, &b);
	submit_join(tb, &b);
	CHECK_EQ(b.rc, NVRM_OK);
	CHECK_EQ(b.r.accepted, 1);
	CHECK_EQ(nvrm_chan_wait(ch, b.r.point, 0), NVRM_OK);
	nvrm_chan_destroy(ch);
	buf_release(cl, &pb);
	teardown(cl);
}

static nvrm_chan *hook_chan;
static unsigned hook_calls;

/* Runs between the unlock and the sleep: the fake makes progress there. */
static void
step_in_hook(void)
{
	hook_calls++;
	nvrm_chan_presleep_hook = NULL;
	(void)nvrm_fake_chan_step(hook_chan, 2);
}

/* Progress between the check and the sleep is not lost, even with a slice
 * ten times longer than the test allows. */
static void
test_lost_wakeup(void)
{
	nvrm_gp_entry e[7];
	nvrm_submit_opts o = { .size = sizeof(o), .timeout_ns = 3000000000ULL };
	nvrm_submit_result r = { .size = sizeof(r) };
	test_buf pb;
	nvrm_client *cl;
	nvrm_chan *ch;
	uint64_t began;

	ch = setup_nops(&cl, &pb, 7, e);
	nvrm_fake_chan_manual(1);
	nvrm_chan_slice_ns = 10000000000ULL;
	CHECK_EQ(nvrm_chan_submit(ch, e, 6, NULL, &r), NVRM_OK);
	hook_chan = ch;
	hook_calls = 0;
	nvrm_chan_presleep_hook = step_in_hook;
	began = monotime();
	CHECK_EQ(nvrm_chan_submit(ch, e + 6, 1, &o, &r), NVRM_OK);
	CHECK(monotime() - began < 1000000000ULL);
	CHECK_EQ(hook_calls, 1);
	CHECK_EQ(r.accepted, 1);

	/* the same for a wait: the element and its release run in the hook */
	drain(ch, 8);
	CHECK_EQ(nvrm_chan_submit(ch, e, 1, NULL, &r), NVRM_OK);
	hook_calls = 0;
	nvrm_chan_presleep_hook = step_in_hook;
	began = monotime();
	CHECK_EQ(nvrm_chan_wait(ch, r.point, 3000000000ULL), NVRM_OK);
	CHECK(monotime() - began < 1000000000ULL);
	CHECK_EQ(hook_calls, 1);
	drain(ch, 8);
	nvrm_chan_destroy(ch);
	buf_release(cl, &pb);
	teardown(cl);
}

/* With a finite deadline a sleep never runs past it, whatever the slice. */
static void
test_deadline_sleep(void)
{
	nvrm_gp_entry e[7];
	nvrm_submit_opts o = { .size = sizeof(o), .timeout_ns = 5000000ULL };
	nvrm_submit_result r = { .size = sizeof(r) };
	test_buf pb;
	nvrm_client *cl;
	nvrm_chan *ch;
	uint64_t began;

	ch = setup_nops(&cl, &pb, 7, e);
	nvrm_fake_chan_manual(1);
	CHECK_EQ(nvrm_chan_submit(ch, e, 1, NULL, &r), NVRM_OK);
	CHECK_EQ(nvrm_chan_slice_ns, NVRM_CHAN_SLICE_DEFAULT_NS);
	began = monotime();
	CHECK_EQ(nvrm_chan_wait(ch, r.point, 5000000ULL), NVRM_E_TIMEOUT);
	CHECK(monotime() - began < 50000000ULL);

	CHECK_EQ(nvrm_chan_submit(ch, e + 1, 4, NULL, &r), NVRM_OK);
	began = monotime();
	CHECK_EQ(nvrm_chan_submit(ch, e + 5, 1, &o, &r), NVRM_E_TIMEOUT);
	CHECK(monotime() - began < 50000000ULL);
	CHECK(strstr(nvrm_client_errmsg(cl), "ring space") != NULL);
	drain(ch, 8);
	nvrm_chan_destroy(ch);
	buf_release(cl, &pb);
	teardown(cl);
}

/* A channel whose entry cannot be loaded does not strand the others: C waits
 * on a semaphore, B releases it and then faults, and C still completes. */
static void
test_auto_fault_scan(void)
{
	nvrm_gp_entry ec, eb[2];
	nvrm_submit_result rc_ = { .size = sizeof(rc_) };
	nvrm_submit_result rb = { .size = sizeof(rb) };
	test_buf pbc, pbb, sem;
	nvrm_client *cl;
	nvrm_chan *c, *b;

	setup();
	cl = open_client();
	c = make_chan(cl, NVRM_ENG_COMPUTE, 8);
	b = make_chan(cl, NVRM_ENG_COMPUTE, 8);
	CHECK_EQ(buf_init(cl, &pbc, 4096), NVRM_OK);
	CHECK_EQ(buf_init(cl, &pbb, 4096), NVRM_OK);
	CHECK_EQ(buf_init(cl, &sem, 4096), NVRM_OK);
	(void)put_sem_frame(&pbc, 0, sem.va, 1,
	    NVRM_SEM_ACQ_CIRC_GEQ | NVRM_SEM_PAYLOAD_64);
	(void)put_sem_frame(&pbb, 0, sem.va, 1,
	    NVRM_SEM_RELEASE | NVRM_SEM_PAYLOAD_64);
	ec = (nvrm_gp_entry){ .va = pbc.va, .dwords = 6 };
	eb[0] = (nvrm_gp_entry){ .va = pbb.va, .dwords = 6 };
	eb[1] = (nvrm_gp_entry){ .va = 0x1000, .dwords = 1 };
	CHECK_EQ(nvrm_chan_submit(c, &ec, 1, NULL, &rc_), NVRM_OK);
	CHECK_EQ(nvrm_chan_wait(c, rc_.point, 0), NVRM_E_TIMEOUT);
	/* the batch is placed; B dies while the doorbell runs it */
	CHECK_EQ(nvrm_chan_submit(b, eb, 2, NULL, &rb), NVRM_E_LOST);
	CHECK_EQ(rb.accepted, 2);
	check_dead(b, NVRM_FAKE_CHAN_ERR_MMU);
	CHECK_EQ(nvrm_chan_wait(c, rc_.point, 0), NVRM_OK);
	nvrm_chan_destroy(b);
	nvrm_chan_destroy(c);
	buf_release(cl, &sem);
	buf_release(cl, &pbb);
	buf_release(cl, &pbc);
	teardown(cl);
}

/* A fork child makes no backend call: it reads the state it has. */
static void
test_fork_no_backend(void)
{
	const nvrm_backend_ops *saved;
	nvrm_backend_ops be;
	nvrm_chan_ops co;
	nvrm_chan_status st = { .size = sizeof(st) };
	nvrm_gp_entry e;
	nvrm_submit_result r = { .size = sizeof(r) };
	test_buf pb;
	nvrm_client *cl;
	nvrm_chan *ch;
	unsigned space = 99;

	setup();
	cl = open_client();
	swap_destroy_ops(cl, &be, &co, &saved);
	ch = make_chan(cl, NVRM_ENG_COMPUTE, 8);
	CHECK_EQ(buf_init(cl, &pb, 4096), NVRM_OK);
	make_nops(&pb, 1);
	e = buf_entry(&pb, 0, 0);
	nvrm_fake_chan_manual(1);
	CHECK_EQ(nvrm_chan_submit(ch, &e, 1, NULL, &r), NVRM_OK);
	drain(ch, 2);
	CHECK_EQ(nvrm_chan_wait(ch, r.point, 0), NVRM_OK);
	CHECK_EQ(nvrm_chan_submit(ch, &e, 1, NULL, &r), NVRM_OK);
	CHECK(backend_calls > 0);
	backend_calls = 0;
	nvrm_getpid_hook = other_pid;
	CHECK_EQ(nvrm_chan_gp_space(ch, &space), NVRM_OK);
	CHECK_EQ(space, 4);
	CHECK_EQ(nvrm_chan_status_get(ch, &st), NVRM_OK);
	CHECK_EQ(st.state, NVRM_CHAN_ALIVE);
	CHECK_EQ(st.submitted, 2);
	CHECK_EQ(st.completed, 1);
	CHECK_EQ(nvrm_chan_wait(ch, 0, 0), NVRM_OK);
	CHECK_EQ(nvrm_chan_wait(ch, 1, UINT64_MAX), NVRM_OK);
	CHECK_EQ(nvrm_chan_wait(ch, 2, 0), NVRM_E_DENIED);
	CHECK(strstr(nvrm_client_errmsg(cl), "fork() child") != NULL);
	CHECK_EQ(nvrm_chan_wait(ch, 3, UINT64_MAX), NVRM_E_DENIED);
	CHECK_EQ(backend_calls, 0);
	nvrm_getpid_hook = NULL;
	drain(ch, 2);
	CHECK_EQ(nvrm_chan_wait(ch, 2, 0), NVRM_OK);
	nvrm_chan_destroy(ch);
	cl->ops = saved;
	buf_release(cl, &pb);
	teardown(cl);
}

/* Copy 64 bytes of src into dst_va on a fresh copy channel; the GPU may not
 * write the ring or the release segments. */
static void
expect_copy_refused(nvrm_client *cl, uint64_t (*where)(const nvrm_chan *))
{
	nvrm_submit_result r = { .size = sizeof(r) };
	nvrm_fake_chan_counts_t counts;
	uint32_t before[40], after[40];
	test_buf pb, src;
	nvrm_gp_entry e;
	nvrm_chan *ch;

	ch = make_chan(cl, NVRM_ENG_COPY, 8);
	CHECK_EQ(buf_init(cl, &pb, 4096), NVRM_OK);
	CHECK_EQ(buf_init(cl, &src, 4096), NVRM_OK);
	memset(src.cpu, 0xa5, 64);
	(void)put_copy_frame(&pb, 0, &(copy_frame){ .in = src.va,
	    .out = where(ch), .pitch_in = 64, .pitch_out = 64, .length = 64,
	    .lines = 1, .launch = LAUNCH_PIPELINED_PITCH });
	e = (nvrm_gp_entry){ .va = pb.va, .dwords = 11 };
	nvrm_fake_chan_manual(1);
	CHECK_EQ(nvrm_chan_submit(ch, &e, 1, NULL, &r), NVRM_OK);
	memcpy(before, (char *)ch->cpu + NVRM_CHAN_RING_OFF(ch->entries),
	    sizeof(before));
	memcpy(before + 16, (char *)ch->cpu + NVRM_CHAN_SEG_OFF(ch->entries,
	    0), 8 * sizeof(uint32_t));
	CHECK_EQ(nvrm_fake_chan_step(ch, 1), NVRM_OK);
	check_dead(ch, NVRM_FAKE_CHAN_ERR_MMU);
	counts = nvrm_fake_chan_counts(ch);
	CHECK_EQ(counts.copies, 1);
	CHECK_EQ(counts.bytes_copied, 0);
	memcpy(after, (char *)ch->cpu + NVRM_CHAN_RING_OFF(ch->entries),
	    sizeof(after));
	memcpy(after + 16, (char *)ch->cpu + NVRM_CHAN_SEG_OFF(ch->entries,
	    0), 8 * sizeof(uint32_t));
	CHECK(memcmp(before, after, sizeof(before)) == 0);
	nvrm_chan_destroy(ch);
	buf_release(cl, &src);
	buf_release(cl, &pb);
}

static uint64_t
ring_where(const nvrm_chan *ch)
{
	return (ch->ring_va + NVRM_CHAN_RING_OFF(ch->entries));
}

static uint64_t
release_where(const nvrm_chan *ch)
{
	return (ch->ring_va + NVRM_CHAN_SEG_OFF(ch->entries, 0));
}

static void
test_ring_read_only(void)
{
	nvrm_client *cl;

	setup();
	cl = open_client();
	expect_copy_refused(cl, ring_where);
	expect_copy_refused(cl, release_where);
	teardown(cl);
}

/* Run the host release of value to the channel's semaphore, one entry only
 * (the core's own release has not run), and look at the channel. */
static void
expect_sem_corruption(nvrm_client *cl, uint64_t value, uint64_t first)
{
	nvrm_chan_info info = { .size = sizeof(info) };
	nvrm_submit_result r = { .size = sizeof(r) };
	nvrm_chan_status st = { .size = sizeof(st) };
	test_buf pb;
	nvrm_gp_entry e;
	nvrm_chan *ch;

	ch = make_chan(cl, NVRM_ENG_COMPUTE, 8);
	CHECK_EQ(nvrm_chan_info_get(ch, &info), NVRM_OK);
	CHECK_EQ(buf_init(cl, &pb, 4096), NVRM_OK);
	(void)put_sem_frame(&pb, 0, info.sem_va, value,
	    NVRM_SEM_RELEASE | NVRM_SEM_PAYLOAD_64);
	e = (nvrm_gp_entry){ .va = pb.va, .dwords = 6 };
	nvrm_fake_chan_manual(1);
	if (first != 0) {
		CHECK_EQ(nvrm_chan_submit(ch, &e, 1, NULL, &r), NVRM_OK);
		drain(ch, 4);
		CHECK_EQ(nvrm_chan_wait(ch, first, 0), NVRM_OK);
	}
	CHECK_EQ(nvrm_chan_submit(ch, &e, 1, NULL, &r), NVRM_OK);
	CHECK_EQ(nvrm_fake_chan_step(ch, 1), NVRM_OK);
	CHECK_EQ(nvrm_chan_status_get(ch, &st), NVRM_OK);
	CHECK_EQ(st.state, NVRM_CHAN_DEAD);
	CHECK_EQ(st.error, NVRM_CHAN_ERR_SEMAPHORE);
	CHECK_EQ(nvrm_chan_wait(ch, r.point, 0), NVRM_E_LOST);
	CHECK_EQ(nvrm_chan_wait(ch, r.point, 2000000000ULL), NVRM_E_LOST);
	CHECK_EQ(nvrm_chan_wait(ch, first, 0), NVRM_OK);
	nvrm_chan_destroy(ch);
	buf_release(cl, &pb);
}

/* The semaphore is GPU-writable: a value no submission can have produced
 * kills the channel and never counts as progress. */
static void
test_semaphore_sanity(void)
{
	nvrm_client *cl;

	setup();
	cl = open_client();
	expect_sem_corruption(cl, UINT64_MAX, 0);	/* above submitted */
	expect_sem_corruption(cl, 0, 1);		/* below completed */
	teardown(cl);
}

/* SET_OBJECT binds only the class granted on its subchannel. */
static void
test_set_object_grant(void)
{
	nvrm_chan_info info = { .size = sizeof(info) };
	nvrm_submit_result r = { .size = sizeof(r) };
	nvrm_fake_chan_counts_t counts;
	uint8_t back[64];
	test_buf pb, src, dst;
	nvrm_gp_entry e;
	nvrm_client *cl;
	nvrm_chan *ch;
	unsigned pos;

	setup();
	cl = open_client();
	ch = make_chan(cl, NVRM_ENG_COMPUTE, 8);
	CHECK_EQ(buf_init(cl, &pb, 4096), NVRM_OK);
	CHECK_EQ(buf_init(cl, &src, 4096), NVRM_OK);
	CHECK_EQ(buf_init(cl, &dst, 4096), NVRM_OK);
	memset(src.cpu, 0x5a, 64);
	put_inc(&pb, 0, 4, NVRM_MTHD_SET_OBJECT, 1);
	put_word(&pb, 1, NVRM_FAKE_CLASS_COPY);
	pos = put_copy_frame(&pb, 2, &(copy_frame){ .in = src.va,
	    .out = dst.va, .pitch_in = 64, .pitch_out = 64, .length = 64,
	    .lines = 1, .launch = LAUNCH_PIPELINED_PITCH });
	e = (nvrm_gp_entry){ .va = pb.va, .dwords = pos };
	nvrm_fake_chan_manual(1);
	CHECK_EQ(nvrm_chan_submit(ch, &e, 1, NULL, &r), NVRM_OK);
	CHECK_EQ(nvrm_fake_chan_step(ch, 1), NVRM_OK);
	check_dead(ch, NVRM_FAKE_CHAN_ERR_UNSUPPORTED);
	counts = nvrm_fake_chan_counts(ch);
	CHECK_EQ(counts.copies, 0);
	CHECK_EQ(counts.bytes_copied, 0);
	CHECK_EQ(nvrm_mem_read(dst.mem, 0, back, sizeof(back)), NVRM_OK);
	CHECK_EQ(back[0], 0);
	CHECK_EQ(nvrm_chan_info_get(ch, &info), NVRM_OK);
	CHECK_EQ(info.subch_class[4], 0);
	CHECK_EQ(info.subch_class[1], NVRM_FAKE_CLASS_COMPUTE);
	nvrm_chan_destroy(ch);
	buf_release(cl, &dst);
	buf_release(cl, &src);
	buf_release(cl, &pb);
	teardown(cl);
}

/* A backend that refuses to destroy its channel keeps the ring memory and VA
 * held: the failure is counted, and the client's close frees them. */
static void
test_destroy_failure(void)
{
	const nvrm_backend_ops *saved;
	nvrm_backend_ops be;
	nvrm_chan_ops co;
	nvrm_client_stats before, after;
	nvrm_fake_mem_stats bs;
	nvrm_client *cl;
	nvrm_chan *ch;
	uint64_t ring_va, again = 0;

	setup();
	cl = open_client();
	swap_destroy_ops(cl, &be, &co, &saved);
	ch = make_chan(cl, NVRM_ENG_COMPUTE, 8);
	ring_va = ch->ring_va;
	before = client_stats(cl);
	destroy_fails = 1;
	nvrm_chan_destroy(ch);
	CHECK_EQ(destroy_calls, 1);
	CHECK(strstr(nvrm_client_errmsg(cl), "injected destroy failure") !=
	    NULL);
	after = client_stats(cl);
	CHECK_EQ(after.failed_releases, before.failed_releases + 1);
	CHECK_EQ(after.live_channels, before.live_channels - 1);
	CHECK_EQ(after.live_mem, before.live_mem);
	CHECK_EQ(after.live_reservations, before.live_reservations);
	CHECK_EQ(after.live_gpu_maps, before.live_gpu_maps);
	CHECK_EQ(after.live_cpu_maps, before.live_cpu_maps);
	CHECK_EQ(nvrm_va_reserve(cl, &(nvrm_va_params){
	    .bytes = NVRM_CHAN_BYTES(8) }, &again), NVRM_OK);
	CHECK(again != ring_va);
	CHECK_EQ(nvrm_va_release(cl, again), NVRM_OK);
	destroy_fails = 0;
	CHECK_EQ(forget_calls, 0);
	nvrm_client_close(cl);
	CHECK_EQ(forget_calls, 1);
	CHECK_EQ(destroy_calls, 1);
	nvrm_fake_mem_stats_get(&bs);
	CHECK_EQ(bs.objects, 0);
	CHECK_EQ(bs.reservations, 0);
	teardown(NULL);
}

/* A refused destroy while the engine still runs.  Another channel waits on
 * an acquire, so the fake scans every channel: the refused one must still be
 * readable (its core record lives until the client closes), and the close
 * forgets it before the memory goes. */
static void
test_refused_destroy_running(void)
{
	const nvrm_backend_ops *saved;
	nvrm_backend_ops be;
	nvrm_chan_ops co;
	nvrm_gp_entry e, ea;
	nvrm_submit_result r = { .size = sizeof(r) };
	nvrm_fake_mem_stats bs;
	test_buf pb, pba, sem;
	nvrm_client *cl;
	nvrm_chan *ch, *other;
	uint32_t value = 9;

	setup();
	cl = open_client();
	swap_destroy_ops(cl, &be, &co, &saved);
	ch = make_chan(cl, NVRM_ENG_COMPUTE, 8);
	other = make_chan(cl, NVRM_ENG_COMPUTE, 8);
	CHECK_EQ(buf_init(cl, &pb, 4096), NVRM_OK);
	CHECK_EQ(buf_init(cl, &pba, 4096), NVRM_OK);
	CHECK_EQ(buf_init(cl, &sem, 4096), NVRM_OK);
	make_nops(&pb, 1);
	e = buf_entry(&pb, 0, 0);
	(void)put_sem_frame(&pba, 0, sem.va, 7, NVRM_SEM_ACQ_CIRC_GEQ);
	ea = (nvrm_gp_entry){ .va = pba.va, .dwords = 6 };
	nvrm_fake_chan_manual(1);
	CHECK_EQ(nvrm_chan_submit(ch, &e, 1, NULL, &r), NVRM_OK);
	destroy_fails = 1;
	nvrm_chan_destroy(ch);
	CHECK_EQ(destroy_calls, 1);
	destroy_fails = 0;
	nvrm_fake_chan_manual(0);
	CHECK_EQ(nvrm_chan_submit(other, &ea, 1, NULL, &r), NVRM_OK);
	CHECK_EQ(nvrm_chan_wait(other, r.point, 0), NVRM_E_TIMEOUT);
	CHECK_EQ(nvrm_mem_write(sem.mem, 0, &value, sizeof(value)), NVRM_OK);
	CHECK_EQ(nvrm_chan_submit(other, &e, 1, NULL, &r), NVRM_OK);
	CHECK_EQ(nvrm_chan_wait(other, r.point, UINT64_MAX), NVRM_OK);
	nvrm_chan_destroy(other);
	buf_release(cl, &sem);
	buf_release(cl, &pba);
	buf_release(cl, &pb);
	CHECK_EQ(forget_calls, 0);
	nvrm_client_close(cl);
	CHECK_EQ(forget_calls, 1);
	CHECK_EQ(destroy_calls, 2);
	nvrm_fake_mem_stats_get(&bs);
	CHECK_EQ(bs.objects, 0);
	CHECK_EQ(bs.reservations, 0);
	teardown(NULL);
}

/* Submit n entries with a zero timeout: a ring without room returns
 * NVRM_E_TIMEOUT with the accepted count in r. */
static int
submit_now(nvrm_chan *ch, const nvrm_gp_entry *e, unsigned n,
    nvrm_submit_result *r)
{
	nvrm_submit_opts o = { .size = sizeof(o), .timeout_ns = 0 };

	r->size = sizeof(*r);
	return (nvrm_chan_submit(ch, e, n, &o, r));
}

static void
read_segment(const nvrm_chan *ch, unsigned slot, uint32_t *words)
{
	memcpy(words, (const char *)ch->cpu +
	    NVRM_CHAN_SEG_OFF(ch->entries, slot), NVRM_CHAN_SEG_BYTES);
}

/* A release segment is read by the GPU after GP_GET passes its ring slot.
 * With GP_GET moving at the fetch and the pushbuffer running later, a full
 * ring of single-element batches must not hand the segment of a release that
 * has not run to a new batch. */
static void
test_release_segment_reuse(void)
{
	nvrm_gp_entry e[3];
	nvrm_submit_result r = { .size = sizeof(r) };
	nvrm_chan_status st = { .size = sizeof(st) };
	uint32_t before[NVRM_RELEASE_SEG_DWORDS], after[NVRM_RELEASE_SEG_DWORDS];
	unsigned i, space = 99;
	test_buf pb;
	nvrm_client *cl;
	nvrm_chan *ch;

	ch = setup_nops(&cl, &pb, 3, e);
	nvrm_fake_chan_manual(1);
	nvrm_fake_chan_lag(1);
	for (i = 0; i < 3; i++)
		CHECK_EQ(submit_now(ch, e, 1, &r), NVRM_OK);
	CHECK_EQ(r.point, 3);
	for (i = 0; i < 4; i++)
		CHECK_EQ(nvrm_fake_chan_step(ch, 1), NVRM_OK);
	CHECK_EQ(nvrm_chan_status_get(ch, &st), NVRM_OK);
	CHECK_EQ(st.gp_get, 3);
	CHECK_EQ(st.completed, 0);
	read_segment(ch, 1, before);
	CHECK_EQ(nvrm_chan_gp_space(ch, &space), NVRM_OK);
	CHECK_EQ(space, 2);
	CHECK_EQ(submit_now(ch, e, 3, &r), NVRM_E_TIMEOUT);
	CHECK_EQ(r.accepted, 2);
	read_segment(ch, 1, after);
	CHECK(memcmp(before, after, sizeof(before)) == 0);
	CHECK_EQ(nvrm_chan_gp_space(ch, &space), NVRM_OK);
	CHECK_EQ(space, 0);
	drain(ch, 12);
	CHECK_EQ(nvrm_chan_wait(ch, r.point, 0), NVRM_OK);
	CHECK_EQ(nvrm_chan_gp_space(ch, &space), NVRM_OK);
	CHECK_EQ(space, 6);
	CHECK_EQ(submit_now(ch, e, 3, &r), NVRM_OK);
	CHECK_EQ(r.accepted, 3);
	drain(ch, 12);
	CHECK_EQ(nvrm_chan_wait(ch, r.point, 0), NVRM_OK);
	nvrm_chan_destroy(ch);
	buf_release(cl, &pb);
	teardown(cl);
}

/* A read of the ring that fails leaves the entry where it is: the ring
 * position does not move past an entry the GPU never saw, and the entry
 * runs once the read works again. */
static void
test_fetch_read_failure(void)
{
	nvrm_gp_entry e[2];
	nvrm_submit_result r = { .size = sizeof(r) };
	nvrm_chan_status st = { .size = sizeof(st) };
	nvrm_fake_chan_counts_t counts;
	test_buf pb;
	nvrm_client *cl;
	nvrm_chan *ch;

	ch = setup_nops(&cl, &pb, 2, e);
	nvrm_fake_chan_manual(1);
	nvrm_fake_chan_lag(1);
	CHECK_EQ(submit_now(ch, e, 2, &r), NVRM_OK);
	CHECK_EQ(r.accepted, 2);
	/* the read of the ring fails: the entry stays in the ring */
	nvrm_fake_chan_read_fail(1);
	CHECK_EQ(nvrm_fake_chan_step(ch, 1), NVRM_OK);
	CHECK_EQ(nvrm_chan_status_get(ch, &st), NVRM_OK);
	CHECK_EQ(st.gp_get, 0);
	counts = nvrm_fake_chan_counts(ch);
	CHECK_EQ(counts.entries, 0);
	/* the read works again: every ring entry runs, once */
	nvrm_fake_chan_read_fail(0);
	drain(ch, 8);
	counts = nvrm_fake_chan_counts(ch);
	CHECK_EQ(counts.entries, 3);
	CHECK_EQ(nvrm_chan_status_get(ch, &st), NVRM_OK);
	CHECK_EQ(st.gp_get, 3);
	nvrm_chan_destroy(ch);
	buf_release(cl, &pb);
	teardown(cl);
}

/* The space a batch may use depends on the releases that have run, so a
 * submit that waits for space waits for the progress semaphore: it wakes
 * when the semaphore advances. */
static void
test_submit_waits_for_space(void)
{
	nvrm_gp_entry e[3];
	nvrm_submit_opts o = { .size = sizeof(o), .timeout_ns = UINT64_MAX };
	nvrm_submit_result r = { .size = sizeof(r) };
	submit_arg a;
	pthread_t tid;
	test_buf pb;
	nvrm_client *cl;
	nvrm_chan *ch;
	unsigned i;

	ch = setup_nops(&cl, &pb, 3, e);
	nvrm_fake_chan_manual(1);
	nvrm_fake_chan_lag(1);
	for (i = 0; i < 3; i++)
		CHECK_EQ(submit_now(ch, e, 1, &r), NVRM_OK);
	CHECK_EQ(r.point, 3);
	for (i = 0; i < 4; i++)
		CHECK_EQ(nvrm_fake_chan_step(ch, 1), NVRM_OK);
	/* the ring is full of the three batches: the submit below waits for
	 * the releases to run */
	a.ch = ch;
	a.e = e;
	a.n = 3;
	a.o = &o;
	submit_start(&tid, &a);
	wait_queued(ch, 1);
	/* the fake runs the releases: the semaphore advances and the waiter
	 * wakes with room for the rest */
	drain(ch, 12);
	submit_join(tid, &a);
	CHECK_EQ(a.rc, NVRM_OK);
	CHECK_EQ(a.r.accepted, 3);
	drain(ch, 12);
	CHECK_EQ(nvrm_chan_wait(ch, a.r.point, 0), NVRM_OK);
	nvrm_chan_destroy(ch);
	buf_release(cl, &pb);
	teardown(cl);
}

/* A backend that cannot forget a channel cannot take one: the core would
 * have no way to drop the record of a channel whose destroy was refused. */
static void
test_create_without_forget(void)
{
	nvrm_backend_ops be;
	nvrm_chan_ops co;
	const nvrm_backend_ops *saved;
	nvrm_chan_params p = { .engines = NVRM_ENG_COMPUTE, .entries = 8 };
	nvrm_chan *ch = (nvrm_chan *)(uintptr_t)1;
	nvrm_client *cl;

	setup();
	cl = open_client();
	saved = cl->ops;
	co = nvrm_fake_chan_ops;
	co.forget = NULL;
	be = *saved;
	be.chan = &co;
	cl->ops = &be;
	CHECK_EQ(nvrm_chan_create(cl, &p, &ch), NVRM_E_NOTSUP);
	CHECK(ch == NULL);
	CHECK(strstr(nvrm_client_errmsg(cl), "forget") != NULL);
	co.forget = nvrm_fake_chan_ops.forget;
	co.destroy = NULL;
	cl->ops = &be;
	CHECK_EQ(nvrm_chan_create(cl, &p, &ch), NVRM_E_NOTSUP);
	CHECK(ch == NULL);
	CHECK(strstr(nvrm_client_errmsg(cl), "destroy") != NULL);
	cl->ops = saved;
	teardown(cl);
}

/* A fork child owns no backend record: the close of a client whose channel
 * destroy was refused makes no backend call at all. */
static void
test_fork_child_release_held(void)
{
	const nvrm_backend_ops *saved;
	nvrm_backend_ops be;
	nvrm_chan_ops co;
	nvrm_client *cl;
	nvrm_chan *ch;
	unsigned calls;

	setup();
	cl = open_client();
	swap_destroy_ops(cl, &be, &co, &saved);
	ch = make_chan(cl, NVRM_ENG_COMPUTE, 8);
	destroy_fails = 1;
	nvrm_chan_destroy(ch);
	destroy_fails = 0;
	CHECK_EQ(destroy_calls, 1);
	CHECK_EQ(forget_calls, 0);
	calls = backend_calls;
	nvrm_getpid_hook = other_pid;
	nvrm_client_close(cl);
	CHECK_EQ(backend_calls, calls);
	CHECK_EQ(forget_calls, 0);
	nvrm_getpid_hook = NULL;
	teardown(NULL);
}

/* The fake engine runs the channels of the calling process only: another
 * process's client opened under a different pid is not scanned or stepped. */
static void
test_fork_child_scan(void)
{
	nvrm_gp_entry e, ec;
	nvrm_submit_result r = { .size = sizeof(r) };
	nvrm_fake_chan_counts_t counts;
	test_buf pb, pbc;
	nvrm_client *cl, *child;
	nvrm_chan *ch, *cch;

	ch = setup_nops(&cl, &pb, 1, &e);
	nvrm_fake_chan_manual(1);
	CHECK_EQ(nvrm_chan_submit(ch, &e, 1, NULL, &r), NVRM_OK);
	nvrm_fake_chan_manual(0);
	nvrm_getpid_hook = other_pid;
	child = open_client();
	cch = make_chan(child, NVRM_ENG_COMPUTE, 8);
	CHECK_EQ(buf_init(child, &pbc, 4096), NVRM_OK);
	make_nops(&pbc, 1);
	ec = buf_entry(&pbc, 0, 0);
	CHECK_EQ(nvrm_chan_submit(cch, &ec, 1, NULL, &r), NVRM_OK);
	CHECK_EQ(nvrm_chan_wait(cch, r.point, 0), NVRM_OK);
	counts = nvrm_fake_chan_counts(ch);
	CHECK_EQ(counts.entries, 0);
	CHECK_EQ(nvrm_fake_chan_step(ch, 4), NVRM_E_DENIED);
	counts = nvrm_fake_chan_counts(ch);
	CHECK_EQ(counts.entries, 0);
	nvrm_chan_destroy(cch);
	buf_release(child, &pbc);
	nvrm_client_close(child);
	nvrm_getpid_hook = NULL;
	CHECK_EQ(nvrm_fake_chan_step(ch, 4), NVRM_OK);
	counts = nvrm_fake_chan_counts(ch);
	CHECK_EQ(counts.entries, 2);
	nvrm_chan_destroy(ch);
	buf_release(cl, &pb);
	teardown(cl);
}

typedef struct race_arg {
	nvrm_chan	*ch;
	int		kind;
} race_arg;

/* Failing waits and failing status queries: each clears and writes the
 * client's message.  Run under ThreadSanitizer, no race may be reported. */
static void *
race_thread(void *arg)
{
	race_arg *a = arg;
	nvrm_chan_status st = { .size = 1 };
	nvrm_chan_info info = { .size = 1 };
	unsigned i, space;

	for (i = 0; i < 3000; i++) {
		if (a->kind == 0) {
			(void)nvrm_chan_wait(a->ch, 99, 0);
			(void)nvrm_chan_info_get(a->ch, &info);
		} else {
			(void)nvrm_chan_status_get(a->ch, &st);
			(void)nvrm_chan_gp_space(a->ch, &space);
		}
	}
	return (NULL);
}

static void
test_errmsg_race(void)
{
	race_arg a[2];
	pthread_t tid[2];
	nvrm_client *cl;
	nvrm_chan *ch;
	unsigned i;

	setup();
	cl = open_client();
	ch = make_chan(cl, NVRM_ENG_COMPUTE, 8);
	for (i = 0; i < 2; i++) {
		a[i] = (race_arg){ .ch = ch, .kind = (int)i };
		CHECK_EQ(pthread_create(&tid[i], NULL, race_thread, &a[i]), 0);
	}
	for (i = 0; i < 2; i++)
		CHECK_EQ(pthread_join(tid[i], NULL), 0);
	nvrm_chan_destroy(ch);
	teardown(cl);
}

/* NVRM_TEST_ONLY=name runs the one test test_name (the ThreadSanitizer run
 * of the message lock uses errmsg_race); without it every test runs. */
#define RUN(fn) do { \
	if (only == NULL || strcmp(only, &#fn[5]) == 0) \
		fn(); \
} while (0)

static void
run_queue_tests(const char *only)
{
	RUN(test_create_smoke);
	RUN(test_golden_words);
	RUN(test_incomplete_waits);
	RUN(test_one_batch);
	RUN(test_split_in_order);
	RUN(test_incomplete_limits);
	RUN(test_ticket_order);
	RUN(test_ticket_timeout);
	RUN(test_queued_deadline);
	RUN(test_queue_handoff);
	RUN(test_queue_death);
	RUN(test_waiter_wake);
	RUN(test_wait_concurrency);
}

static void
run_semantic_tests(const char *only)
{
	RUN(test_auto_rescan);
	RUN(test_auto_fault_scan);
	RUN(test_no_kick_space);
	RUN(test_lost_wakeup);
	RUN(test_deadline_sleep);
	RUN(test_flush_order);
	RUN(test_semaphores);
	RUN(test_create_arguments);
	RUN(test_submit_arguments);
	RUN(test_fork_and_close);
	RUN(test_fork_no_backend);
	RUN(test_create_failures);
}

/*
 * A backend that keeps the parameters of a channel allocation.
 */
static int
alloc_get_ok(nvrm_bclient *bc, nvrm_chan_alloc *out)
{
	(void)bc;
	memset(out, 0, sizeof(*out));
	out->size = sizeof(*out);
	out->gp_fifo_entries = 512;
	out->h_vaspace = 0;
	return (NVRM_OK);
}

/*
 * A backend that has nothing to report: the client submitted nothing.
 */
static int
alloc_get_none(nvrm_bclient *bc, nvrm_chan_alloc *out)
{
	(void)bc;
	(void)out;
	return (NVRM_E_NOENT);
}

/*
 * A backend that fails for another reason.
 */
static int
alloc_get_failed(nvrm_bclient *bc, nvrm_chan_alloc *out)
{
	(void)bc;
	(void)out;
	return (NVRM_E_IO);
}

/*
 * The parameters of a channel allocation: the core asks the backend for
 * them, and a backend that keeps none says so.
 */
static void
test_chan_alloc(void)
{
	const nvrm_backend_ops *saved;
	nvrm_backend_ops be;
	nvrm_chan_ops co;
	nvrm_chan_alloc al = { 0 };
	nvrm_client *cl;

	setup();
	cl = open_client();

	/* the size of the structure is checked */
	al.size = sizeof(al) + 1;
	CHECK_EQ(nvrm_chan_alloc_get(cl, &al), NVRM_E_INVAL);
	CHECK(strstr(nvrm_client_errmsg(cl), "nvrm_chan_alloc.size") != NULL);

	/* a null structure is refused, not a crash */
	CHECK_EQ(nvrm_chan_alloc_get(cl, NULL), NVRM_E_INVAL);
	CHECK(strstr(nvrm_client_errmsg(cl), "wants a structure") != NULL);

	/* the fake backend talks to no RM: it has no parameters to give */
	al.size = 0;
	CHECK_EQ(nvrm_chan_alloc_get(cl, &al), NVRM_E_NOTSUP);
	CHECK(strstr(nvrm_client_errmsg(cl), "does not record") != NULL);

	/* a backend without the operation, and one without channels */
	saved = cl->ops;
	co = nvrm_fake_chan_ops;
	co.alloc_get = NULL;
	be = *saved;
	be.chan = &co;
	cl->ops = &be;
	al.size = 0;
	CHECK_EQ(nvrm_chan_alloc_get(cl, &al), NVRM_E_NOTSUP);
	CHECK(strstr(nvrm_client_errmsg(cl), "does not record") != NULL);
	be.chan = NULL;
	cl->ops = &be;
	CHECK_EQ(nvrm_chan_alloc_get(cl, &al), NVRM_E_NOTSUP);

	/* a backend that has nothing to report says so, and the caller's
	 * structure is left alone */
	co = nvrm_fake_chan_ops;
	co.alloc_get = alloc_get_none;
	be.chan = &co;
	cl->ops = &be;
	al.size = 0;
	CHECK_EQ(nvrm_chan_alloc_get(cl, &al), NVRM_E_NOENT);
	CHECK(strstr(nvrm_client_errmsg(cl), "submitted no channel allocation")
	    != NULL);
	CHECK_EQ(al.size, 0);

	/* a backend that fails for another reason says so too */
	co.alloc_get = alloc_get_failed;
	be.chan = &co;
	cl->ops = &be;
	al.size = 0;
	CHECK_EQ(nvrm_chan_alloc_get(cl, &al), NVRM_E_IO);
	CHECK(strstr(nvrm_client_errmsg(cl), "did not give the parameters")
	    != NULL);

	/* a backend that keeps them */
	co = nvrm_fake_chan_ops;
	co.alloc_get = alloc_get_ok;
	be.chan = &co;
	cl->ops = &be;
	al.size = 0;
	CHECK_EQ(nvrm_chan_alloc_get(cl, &al), NVRM_OK);
	CHECK_EQ(al.gp_fifo_entries, 512);
	CHECK_EQ(al.h_vaspace, 0);
	CHECK_EQ(al.size, sizeof(al));
	cl->ops = saved;
	teardown(cl);
}

static void
run_review_tests(const char *only)
{
	RUN(test_method_faults);
	RUN(test_method_matrix);
	RUN(test_set_object_grant);
	RUN(test_load_entry_failures);
	RUN(test_faults);
	RUN(test_ring_read_only);
	RUN(test_semaphore_sanity);
	RUN(test_destroy_failure);
	RUN(test_refused_destroy_running);
	RUN(test_release_segment_reuse);
	RUN(test_fetch_read_failure);
	RUN(test_submit_waits_for_space);
	RUN(test_create_without_forget);
	RUN(test_fork_child_release_held);
	RUN(test_fork_child_scan);
	RUN(test_wait_rules);
	RUN(test_copy);
	RUN(test_lifetime);
	RUN(test_errmsg_race);
	RUN(test_chan_alloc);
}

int
main(void)
{
	const char *only = getenv("NVRM_TEST_ONLY");

	run_queue_tests(only);
	run_semantic_tests(only);
	run_review_tests(only);
	return (t_done("chan_test"));
}

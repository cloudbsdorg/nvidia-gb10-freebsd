/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * chan_probe.c - the live check of the libnvrm channel calls (Track #2437)
 * for a test boot: on every GPU the library enumerates (no index is assumed;
 * each line names the GPU by its PCI address), open a client, create a
 * compute GPFIFO channel and push a semaphore release through it: the GPU
 * writes a payload into a memory object of ours, the wait returns, and the
 * payload is read back.  Then the latency of a thousand releases, a stress
 * loop, the isolation of a dead channel from a live one, and the cleanup.
 * It needs the driver and nothing else (no Linux layer); with NVRM_BACKEND=fake
 * it runs on the software GPU (the suite does that).
 *
 * Output: one line per step, "PASS gpu N (dddd:bb:ss.f) STEP: detail" or
 * "FAIL ...", for results.txt of the boot kit.  Exit status: the number of
 * FAIL lines (capped at 100); 101 when nothing could be enumerated.  With
 * --json the same facts are one JSON document on stdout instead of the lines.
 */
#include <sys/types.h>

#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <nvrm/nvrm.h>
#include <nvrm/nvrm_chan.h>

#define KiB	(1024ULL * 1024)

#define FRAME_BYTES		(4 * KiB)	/* the semaphore, the pushbuffer */
#define FRAME_DWORDS		6	/* the words of a semaphore release */
#define ISOLATION_VA_BYTES	(64 * KiB)	/* reserved, never mapped */
#define ISOLATION_DWORDS	8
#define SUBMIT_TIMEOUT_NS	(10ULL * 1000 * 1000 * 1000)
#define WAIT_TIMEOUT_NS		(10ULL * 1000 * 1000 * 1000)
#define LATENCY_SAMPLES		1000
#define STRESS_DEFAULT		100000ULL
#define STRESS_SECONDS_DEFAULT	300ULL
#define RELEASE_PAYLOAD		0x0000600d0000600dULL
#define MAX_GPUS		16
#define MAX_STEPS		12
#define DETAIL_LEN		256

/*
 * The wire format of the pushbuffer: the values of nvrm_methods.h, which is a
 * private header of the library.  The probe is built against the public
 * headers alone, so it carries the few it needs.
 */
#define MTHD_SEM_ADDR_LO	0x5c
#define MTHD_OP_INC		1U
#define SEM_RELEASE		1U
#define SEM_WFI			(1U << 20)
#define SEM_PAYLOAD_64		(1U << 24)

/* One memory object of ours: the VA it is mapped at and its CPU mapping. */
typedef struct probe_mem {
	nvrm_mem	*mem;
	uint64_t	va;
	void		*cpu;
} probe_mem;

/* One step of the probe: its name, its verdict and the detail of the line. */
typedef struct step_rec {
	char	name[24];
	char	status[8];
	char	detail[DETAIL_LEN];
} step_rec;

/* What one GPU was measured: the steps, the latency and the stress. */
typedef struct gpu_rec {
	char	pci[32];
	step_rec	steps[MAX_STEPS];
	unsigned	nsteps;
	uint64_t	lat_p50, lat_p99, lat_max;
	uint64_t	st_done, st_planned, st_seconds;
} gpu_rec;

/* What is open while one GPU is measured. */
typedef struct gpu_ctx {
	nvrm_client	*cl;
	nvrm_chan	*ch[4];	/* the channel of the steps and the
					   isolation channel */
	unsigned	nch;
	probe_mem	sem;	/* the semaphore the GPU writes */
	probe_mem	pb;	/* the pushbuffer the GPU reads */
	uint64_t	bad_va;	/* reserved, never mapped */
} gpu_ctx;

static const char *const step_names[] = {
	"create", "release", "latency", "stress", "isolation", "cleanup"
};

static const uint8_t zeros[FRAME_BYTES];

static int fails;
static int json_mode;
static char gpu_name[64];
static gpu_rec gpus[MAX_GPUS];
static unsigned ngpus;
static gpu_rec *cur;

/* The monotonic clock, in nanoseconds. */
static uint64_t
now_ns(void)
{
	struct timespec ts;

	(void)clock_gettime(CLOCK_MONOTONIC, &ts);
	return ((uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec);
}

/* A number from the environment, or the default when it is not one. */
static uint64_t
env_u64(const char *name, uint64_t dflt)
{
	const char *v = getenv(name);
	char *end;
	uint64_t n;

	if (v == NULL || *v == '\0')
		return (dflt);
	n = (uint64_t)strtoull(v, &end, 10);
	if (end == v || *end != '\0' || n == 0)
		return (dflt);
	return (n);
}

/* Order of the samples, for the percentiles. */
static int
cmp_u64(const void *a, const void *b)
{
	uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;

	return (x < y ? -1 : x > y ? 1 : 0);
}

/* One step of the probe, kept for the JSON document. */
static void
record(const char *name, const char *status, const char *detail)
{
	step_rec *s;

	if (cur == NULL || cur->nsteps >= MAX_STEPS)
		return;
	s = &cur->steps[cur->nsteps++];
	snprintf(s->name, sizeof(s->name), "%s", name);
	snprintf(s->status, sizeof(s->status), "%s", status);
	snprintf(s->detail, sizeof(s->detail), "%s", detail);
}

/* One line of the output: the verdict of a step and its detail. */
static int
step(int ok, const char *what, const char *fmt, ...)
{
	va_list ap;
	char detail[DETAIL_LEN];

	va_start(ap, fmt);
	(void)vsnprintf(detail, sizeof(detail), fmt, ap);
	va_end(ap);
	if (!json_mode)
		printf("%s %s %s: %s\n", ok ? "PASS" : "FAIL", gpu_name, what,
		    detail);
	record(what, ok ? "pass" : "fail", detail);
	fails += !ok;
	return (ok);
}

/* One line of the output that tells, it does not judge. */
static void
info_line(const char *what, const char *fmt, ...)
{
	va_list ap;
	char detail[DETAIL_LEN];

	va_start(ap, fmt);
	(void)vsnprintf(detail, sizeof(detail), fmt, ap);
	va_end(ap);
	if (!json_mode)
		printf("INFO %s %s: %s\n", gpu_name, what, detail);
	record(what, "info", detail);
}

/* The steps after the one that failed: they are not reached. */
static void
not_reached(const char *from, int cleanup_too)
{
	unsigned i;
	int seen = 0;

	/* Time: O(1) (six names); Space: O(1). */
	for (i = 0; i < sizeof(step_names) / sizeof(step_names[0]); i++) {
		if (seen && (cleanup_too || strcmp(step_names[i], "cleanup") != 0))
			step(0, step_names[i], "not reached");
		if (!seen && strcmp(step_names[i], from) == 0)
			seen = 1;
	}
}

/* The header of a method: the subchannel, the method, the count and the op. */
static uint32_t
method_header(unsigned subch, unsigned method, unsigned count, unsigned op)
{
	return (((method >> 2) & 0xfffU) | ((subch & 7U) << 13) |
	    ((count & 0x1fffU) << 16) | ((op & 7U) << 29));
}

/* The class bound to each subchannel, the nonzero ones only: "1=3 2=5". */
static const char *
subch_classes(const nvrm_chan_info *info)
{
	static char buf[128];
	size_t n = 0;
	unsigned i;

	/* Time: O(1) (eight subchannels); Space: O(1) (a fixed buffer). */
	for (i = 0; i < 8 && n < sizeof(buf); i++) {
		if (info->subch_class[i] == 0)
			continue;
		n += (size_t)snprintf(buf + n, sizeof(buf) - n, "%s%u=%u",
		    n != 0 ? " " : "", i, info->subch_class[i]);
	}
	return (buf[0] == '\0' ? "none" : buf);
}

/* The channel status, in one string: the fields nvrm_chan_status holds. */
static const char *
chan_status_text(nvrm_chan *ch, nvrm_chan_status *st)
{
	static char buf[192];

	if (nvrm_chan_status_get(ch, st) != NVRM_OK) {
		snprintf(buf, sizeof(buf), "the status is not readable");
		return (buf);
	}
	snprintf(buf, sizeof(buf), "state %s, error %u, gp_get %u, gp_put %u, "
	    "submitted %ju, completed %ju",
	    st->state == NVRM_CHAN_DEAD ? "dead" : "alive", st->error,
	    st->gp_get, st->gp_put, (uintmax_t)st->submitted,
	    (uintmax_t)st->completed);
	return (buf);
}

/* Reserve the VA of an object, allocate it, map it for the GPU and the CPU. */
static int
mem_setup(nvrm_client *cl, probe_mem *m, uint64_t bytes, uint32_t map_flags)
{
	nvrm_va_params vp = { 0, 0, bytes, 0, 0 };
	nvrm_mem_params mp = { 0, NVRM_MEM_SYSMEM, 0, 0, bytes, 0, 0 };
	nvrm_gpu_map_params gp = { 0 };
	int rc;

	memset(m, 0, sizeof(*m));
	rc = nvrm_va_reserve(cl, &vp, &m->va);
	if (rc != NVRM_OK)
		return (rc);
	rc = nvrm_mem_alloc(cl, &mp, &m->mem);
	if (rc != NVRM_OK)
		goto bad;
	gp.flags = map_flags;
	gp.va = m->va;
	rc = nvrm_mem_map_gpu(m->mem, &gp);
	if (rc != NVRM_OK)
		goto bad;
	rc = nvrm_mem_map_cpu(m->mem, NVRM_CPU_READ | NVRM_CPU_WRITE, &m->cpu);
	if (rc != NVRM_OK)
		goto bad;
	return (NVRM_OK);
bad:
	if (m->mem != NULL)
		nvrm_mem_free(m->mem);
	m->mem = NULL;
	(void)nvrm_va_release(cl, m->va);
	m->va = 0;
	return (rc);
}

/* Free an object and release its VA. */
static void
mem_release(nvrm_client *cl, probe_mem *m)
{
	if (m->mem != NULL) {
		nvrm_mem_free(m->mem);
		m->mem = NULL;
	}
	if (m->va != 0) {
		(void)nvrm_va_release(cl, m->va);
		m->va = 0;
	}
	m->cpu = NULL;
}

/*
 * The six words of a semaphore release, in the wire format of the
 * pushbuffer: an incrementing header, the address of the semaphore (two
 * words), the payload (two words) and the word that executes the release.
 */
static int
write_frame(nvrm_mem *mem, uint64_t sem_va, uint64_t payload)
{
	uint32_t w[FRAME_DWORDS];

	w[0] = method_header(0, MTHD_SEM_ADDR_LO, FRAME_DWORDS - 1,
	    MTHD_OP_INC);
	w[1] = (uint32_t)sem_va & 0xfffffffcU;
	w[2] = (uint32_t)(sem_va >> 32);
	w[3] = (uint32_t)payload;
	w[4] = (uint32_t)(payload >> 32);
	w[5] = SEM_RELEASE | SEM_WFI | SEM_PAYLOAD_64;
	return (nvrm_mem_write(mem, 0, w, sizeof(w)));
}

/* Push one entry and wait for it: the error code of the submit or of the wait. */
static int
push_wait(nvrm_chan *ch, nvrm_gp_entry *e, nvrm_submit_opts *o,
    nvrm_submit_result *r)
{
	int rc;

	rc = nvrm_chan_submit(ch, e, 1, o, r);
	if (rc != NVRM_OK)
		return (rc);
	return (nvrm_chan_wait(ch, r->point, WAIT_TIMEOUT_NS));
}

/*
 * Push one semaphore release through the channel of the context and wait for
 * it.  The payload must come back: the reason is in why.  Returns 0 when it
 * did, the error code otherwise.
 */
static int
release_once(gpu_ctx *g, uint64_t payload, char *why, size_t whylen)
{
	nvrm_gp_entry e;
	nvrm_submit_opts o;
	nvrm_submit_result r;
	nvrm_chan_status st = { 0 };
	uint64_t value = 0;
	int rc;

	rc = write_frame(g->pb.mem, g->sem.va, payload);
	if (rc != NVRM_OK) {
		snprintf(why, whylen, "the frame: %s", nvrm_client_errmsg(g->cl));
		return (rc);
	}
	e.va = g->pb.va;
	e.dwords = FRAME_DWORDS;
	e.flags = 0;
	o.size = sizeof(o);
	o.flags = 0;
	o.timeout_ns = SUBMIT_TIMEOUT_NS;
	r.size = sizeof(r);
	rc = nvrm_chan_submit(g->ch[0], &e, 1, &o, &r);
	if (rc != NVRM_OK) {
		snprintf(why, whylen, "submit: %s", nvrm_client_errmsg(g->cl));
		return (rc);
	}
	rc = nvrm_chan_wait(g->ch[0], r.point, WAIT_TIMEOUT_NS);
	if (rc != NVRM_OK) {
		snprintf(why, whylen, "wait: %s (%s)", nvrm_strerror(rc),
		    chan_status_text(g->ch[0], &st));
		return (rc);
	}
	rc = nvrm_mem_read(g->sem.mem, 0, &value, sizeof(value));
	if (rc != NVRM_OK) {
		snprintf(why, whylen, "read back: %s",
		    nvrm_client_errmsg(g->cl));
		return (rc);
	}
	if (value != payload) {
		snprintf(why, whylen, "the semaphore holds 0x%016jx, not "
		    "0x%016jx", (uintmax_t)value, (uintmax_t)payload);
		return (NVRM_E_RM);
	}
	return (0);
}

/* a: create the channel and tell what it is. */
static int
step_create(gpu_ctx *g)
{
	nvrm_chan_params p = { 0, NVRM_ENG_COMPUTE, 0, 0 };
	nvrm_chan_info info;
	nvrm_chan *ch = NULL;
	int rc;

	rc = nvrm_chan_create(g->cl, &p, &ch);
	if (!step(rc == NVRM_OK, "create", "%s", rc == NVRM_OK ?
	    "a compute GPFIFO channel with the default entry count" :
	    nvrm_client_errmsg(g->cl)))
		return (0);
	g->ch[g->nch++] = ch;
	rc = nvrm_chan_info_get(ch, &info);
	if (rc != NVRM_OK) {
		info_line("chan_info", "%s", nvrm_client_errmsg(g->cl));
		return (1);
	}
	info_line("chan_info", "cls_gpfifo %u, runlist %s, subch_class %s, "
	    "sem_va 0x%jx", info.cls_gpfifo,
	    info.runlist == NVRM_RUNLIST_GRAPHICS ? "graphics" : "copy",
	    subch_classes(&info), (uintmax_t)info.sem_va);
	return (1);
}

/* b: one semaphore release through the channel, and the payload read back. */
static int
step_release(gpu_ctx *g)
{
	char why[DETAIL_LEN];

	if (release_once(g, RELEASE_PAYLOAD, why, sizeof(why)) != 0) {
		step(0, "release", "%s", why);
		return (0);
	}
	step(1, "release", "the GPU wrote the payload 0x%016jx into the "
	    "semaphore and the wait returned", (uintmax_t)RELEASE_PAYLOAD);
	return (1);
}

/* c: a thousand releases, and the time each of them took. */
static int
step_latency(gpu_ctx *g)
{
	uint64_t samples[LATENCY_SAMPLES];
	uint64_t t0, t1;
	nvrm_gp_entry e;
	nvrm_submit_opts o;
	nvrm_submit_result r;
	unsigned i, failed = 0;
	char why[DETAIL_LEN], err[DETAIL_LEN];
	int rc;

	e.va = g->pb.va;
	e.dwords = FRAME_DWORDS;
	e.flags = 0;
	o.size = sizeof(o);
	o.flags = 0;
	o.timeout_ns = SUBMIT_TIMEOUT_NS;
	r.size = sizeof(r);
	snprintf(err, sizeof(err), "none");
	/* Time: O(LATENCY_SAMPLES) submissions; Space: O(LATENCY_SAMPLES). */
	for (i = 0; i < LATENCY_SAMPLES; i++) {
		rc = write_frame(g->pb.mem, g->sem.va, (uint64_t)i + 1);
		t0 = now_ns();
		if (rc == NVRM_OK)
			rc = push_wait(g->ch[0], &e, &o, &r);
		t1 = now_ns();
		samples[i] = t1 - t0;
		if (rc != NVRM_OK) {
			failed++;
			if (failed == 1)
				snprintf(err, sizeof(err), "%s",
				    nvrm_client_errmsg(g->cl));
		}
	}
	qsort(samples, LATENCY_SAMPLES, sizeof(samples[0]), cmp_u64);
	cur->lat_p50 = samples[(LATENCY_SAMPLES - 1) / 2];
	cur->lat_p99 = samples[(LATENCY_SAMPLES * 99) / 100];
	cur->lat_max = samples[LATENCY_SAMPLES - 1];
	if (failed != 0)
		snprintf(why, sizeof(why), "%u of %u waits failed: %s", failed,
		    LATENCY_SAMPLES, err);
	else
		snprintf(why, sizeof(why), "%u waits returned 0",
		    LATENCY_SAMPLES);
	step(failed == 0, "latency", "%s", why);
	info_line("latency_ns", "p50 %ju ns, p99 %ju ns, max %ju ns",
	    (uintmax_t)cur->lat_p50, (uintmax_t)cur->lat_p99,
	    (uintmax_t)cur->lat_max);
	return (failed == 0);
}

/* d: the stress loop, as long as the environment asks for. */
static int
step_stress(gpu_ctx *g)
{
	uint64_t planned = env_u64("BOOT_CHAN_STRESS", STRESS_DEFAULT);
	uint64_t seconds = env_u64("BOOT_CHAN_STRESS_SECONDS",
	    STRESS_SECONDS_DEFAULT);
	uint64_t deadline, start, done = 0, failed = 0;
	nvrm_gp_entry e;
	nvrm_submit_opts o;
	nvrm_submit_result r;
	char why[DETAIL_LEN];
	int rc;

	e.va = g->pb.va;
	e.dwords = FRAME_DWORDS;
	e.flags = 0;
	o.size = sizeof(o);
	o.flags = 0;
	o.timeout_ns = SUBMIT_TIMEOUT_NS;
	r.size = sizeof(r);
	start = now_ns();
	deadline = start + seconds * 1000000000ULL;
	/* Time: O(planned) submissions; Space: O(1). */
	while (done < planned && now_ns() < deadline) {
		rc = write_frame(g->pb.mem, g->sem.va, RELEASE_PAYLOAD);
		if (rc == NVRM_OK)
			rc = push_wait(g->ch[0], &e, &o, &r);
		done++;
		if (rc != NVRM_OK)
			failed++;
	}
	cur->st_done = done;
	cur->st_planned = planned;
	cur->st_seconds = (now_ns() - start) / 1000000000ULL;
	if (failed != 0)
		snprintf(why, sizeof(why), "%ju of %ju waits failed",
		    (uintmax_t)failed, (uintmax_t)done);
	else
		snprintf(why, sizeof(why), "every wait returned 0");
	step(failed == 0, "stress", "done %ju/%ju in %ju s, %s",
	    (uintmax_t)done, (uintmax_t)planned, (uintmax_t)cur->st_seconds,
	    why);
	return (failed == 0);
}

/* e: a bad push kills one channel, the other one keeps working. */
static int
step_isolation(gpu_ctx *g)
{
	nvrm_chan_params p = { 0, NVRM_ENG_COMPUTE, 0, 0 };
	nvrm_va_params vp = { 0, 0, ISOLATION_VA_BYTES, 0, 0 };
	nvrm_gp_entry e;
	nvrm_submit_opts o;
	nvrm_submit_result r;
	nvrm_chan_status st = { 0 };
	nvrm_chan *ch2 = NULL, *ch3 = NULL;
	char dead_text[DETAIL_LEN], live_text[DETAIL_LEN], detail[DETAIL_LEN];
	char why[DETAIL_LEN];
	uint64_t bad_va = 0;
	int rc, wrc, dead, live, third;

	rc = nvrm_chan_create(g->cl, &p, &ch2);
	if (rc != NVRM_OK) {
		step(0, "isolation", "the second channel: %s",
		    nvrm_client_errmsg(g->cl));
		return (0);
	}
	g->ch[g->nch++] = ch2;
	rc = nvrm_va_reserve(g->cl, &vp, &bad_va);
	if (rc != NVRM_OK) {
		step(0, "isolation", "the reservation: %s",
		    nvrm_client_errmsg(g->cl));
		return (0);
	}
	g->bad_va = bad_va;
	e.va = bad_va;
	e.dwords = ISOLATION_DWORDS;
	e.flags = 0;
	o.size = sizeof(o);
	o.flags = 0;
	o.timeout_ns = SUBMIT_TIMEOUT_NS;
	r.size = sizeof(r);
	rc = nvrm_chan_submit(ch2, &e, 1, &o, &r);
	wrc = nvrm_chan_wait(ch2, r.point, WAIT_TIMEOUT_NS);
	(void)nvrm_chan_status_get(ch2, &st);
	/* The channel is dead when the wait says so, or when it timed out and
	 * the status says the channel died with an error.  A backend that
	 * reports the loss at the submit is the same death. */
	dead = (wrc == NVRM_E_LOST) ||
	    (wrc == NVRM_E_TIMEOUT && st.state == NVRM_CHAN_DEAD &&
	    st.error != 0) ||
	    (rc == NVRM_E_LOST && st.state == NVRM_CHAN_DEAD &&
	    st.error != 0);
	snprintf(dead_text, sizeof(dead_text), "%s (%s)",
	    dead ? "the second channel died" :
	    "the second channel is alive", chan_status_text(ch2, &st));
	if (release_once(g, RELEASE_PAYLOAD, why, sizeof(why)) == 0) {
		live = 1;
		snprintf(live_text, sizeof(live_text), "%s",
		    "the first channel still released the payload");
	} else {
		live = 0;
		snprintf(live_text, sizeof(live_text),
		    "the first channel failed: %s", why);
	}
	third = 0;
	if (nvrm_chan_create(g->cl, &p, &ch3) == NVRM_OK) {
		nvrm_chan_destroy(ch3);
		third = 1;
	}
	snprintf(detail, sizeof(detail), "%s; %s; %s", dead_text, live_text,
	    third ? "a third channel was created and destroyed" :
	    "the third channel was refused");
	return (step(dead && live && third, "isolation", "%s", detail));
}

/* f: nothing left behind. */
static int
step_cleanup(gpu_ctx *g)
{
	nvrm_client_stats st = { 0 };
	unsigned i;
	int rc;

	/* Time: O(channels); Space: O(1). */
	for (i = 0; i < g->nch; i++) {
		if (g->ch[i] != NULL) {
			nvrm_chan_destroy(g->ch[i]);
			g->ch[i] = NULL;
		}
	}
	mem_release(g->cl, &g->sem);
	mem_release(g->cl, &g->pb);
	if (g->bad_va != 0) {
		(void)nvrm_va_release(g->cl, g->bad_va);
		g->bad_va = 0;
	}
	rc = nvrm_client_stats_get(g->cl, &st);
	return (step(rc == NVRM_OK && st.live_channels == 0 &&
	    st.live_mem == 0 && st.live_bytes == 0 &&
	    st.live_reservations == 0 && st.live_gpu_maps == 0 &&
	    st.live_cpu_maps == 0 && st.failed_releases == 0, "cleanup",
	    "live_channels %ju, live_mem %ju, live_bytes %ju, "
	    "live_reservations %ju, live_gpu_maps %ju, live_cpu_maps %ju, "
	    "failed_releases %ju", (uintmax_t)st.live_channels,
	    (uintmax_t)st.live_mem, (uintmax_t)st.live_bytes,
	    (uintmax_t)st.live_reservations, (uintmax_t)st.live_gpu_maps,
	    (uintmax_t)st.live_cpu_maps, (uintmax_t)st.failed_releases));
}

/* The whole probe of one GPU. */
static void
run_gpu(nvrm_device *dev, gpu_rec *rec)
{
	nvrm_open_opts o = { 0, NVRM_OPEN_ALLOW_MAP, 4, 4 };
	gpu_ctx g;
	char err[200];
	int rc;

	memset(&g, 0, sizeof(g));
	cur = rec;
	rc = nvrm_client_open(dev, &o, &g.cl, err, sizeof(err));
	if (rc != NVRM_OK) {
		step(0, "client_open", "%s", err);
		not_reached("create", 1);
		return;
	}
	if (!step_create(&g)) {
		not_reached("create", 0);
		goto out;
	}
	if (mem_setup(g.cl, &g.sem, FRAME_BYTES, 0) != NVRM_OK ||
	    mem_setup(g.cl, &g.pb, FRAME_BYTES, NVRM_MAP_READ_ONLY) !=
	    NVRM_OK) {
		step(0, "release", "the objects of the release: %s",
		    nvrm_client_errmsg(g.cl));
		not_reached("release", 0);
		goto out;
	}
	if (nvrm_mem_write(g.sem.mem, 0, zeros, sizeof(zeros)) != NVRM_OK) {
		step(0, "release", "the semaphore is not zeroed: %s",
		    nvrm_client_errmsg(g.cl));
		not_reached("release", 0);
		goto out;
	}
	if (!step_release(&g)) {
		not_reached("release", 0);
		goto out;
	}
	if (!step_latency(&g)) {
		not_reached("latency", 0);
		goto out;
	}
	if (!step_stress(&g)) {
		not_reached("stress", 0);
		goto out;
	}
	if (!step_isolation(&g)) {
		not_reached("isolation", 0);
		goto out;
	}
out:
	(void)step_cleanup(&g);
	nvrm_client_close(g.cl);
}

/* One JSON string, with the escapes the document needs. */
static void
json_string(const char *s)
{
	const unsigned char *p = (const unsigned char *)s;

	putchar('"');
	/* Time: O(len(s)); Space: O(1). */
	for (; *p != '\0'; p++) {
		switch (*p) {
		case '"':
			fputs("\\\"", stdout);
			break;
		case '\\':
			fputs("\\\\", stdout);
			break;
		case '\n':
			fputs("\\n", stdout);
			break;
		case '\r':
			fputs("\\r", stdout);
			break;
		case '\t':
			fputs("\\t", stdout);
			break;
		default:
			if (*p < 0x20)
				(void)printf("\\u%04x", *p);
			else
				(void)putchar(*p);
		}
	}
	putchar('"');
}

/* The whole probe as one JSON document. */
static void
print_json(void)
{
	unsigned i, s;

	(void)printf("{\"schema\":\"chan-probe/1\",\"version\":1,\"gpus\":[");
	/* Time: O(gpus x steps); Space: O(1) beyond the records. */
	for (i = 0; i < ngpus; i++) {
		if (i != 0)
			(void)printf(",");
		(void)printf("{\"pci\":");
		json_string(gpus[i].pci);
		(void)printf(",\"steps\":[");
		for (s = 0; s < gpus[i].nsteps; s++) {
			if (s != 0)
				(void)printf(",");
			(void)printf("{\"name\":");
			json_string(gpus[i].steps[s].name);
			(void)printf(",\"status\":");
			json_string(gpus[i].steps[s].status);
			(void)printf(",\"detail\":");
			json_string(gpus[i].steps[s].detail);
			(void)printf("}");
		}
		(void)printf("],\"latency_ns\":{\"p50\":%ju,\"p99\":%ju,"
		    "\"max\":%ju},\"stress\":{\"done\":%ju,\"planned\":%ju,"
		    "\"seconds\":%ju}}", (uintmax_t)gpus[i].lat_p50,
		    (uintmax_t)gpus[i].lat_p99, (uintmax_t)gpus[i].lat_max,
		    (uintmax_t)gpus[i].st_done, (uintmax_t)gpus[i].st_planned,
		    (uintmax_t)gpus[i].st_seconds);
	}
	(void)printf("]}\n");
}

int
main(int argc, char **argv)
{
	nvrm_ctx *ctx;
	const nvrm_device_info *i;
	char err[300];
	unsigned n, k;

	if (argc > 2 || (argc == 2 && strcmp(argv[1], "--json") != 0)) {
		fprintf(stderr, "usage: %s [--json]\n", argv[0]);
		return (2);
	}
	json_mode = argc == 2;
	setvbuf(stdout, NULL, _IOLBF, 0);
	if (nvrm_enumerate(&ctx, NULL, err, sizeof(err)) != NVRM_OK) {
		if (!json_mode)
			printf("FAIL enumerate: %s\n", err);
		else
			print_json();
		return (101);
	}
	n = nvrm_device_count(ctx);
	if (!json_mode)
		printf("INFO backend %s, %u GPU(s)\n", nvrm_backend_name(ctx), n);
	if (n == 0) {
		if (!json_mode)
			printf("FAIL enumerate: no GPU\n");
		else
			print_json();
		nvrm_close(ctx);
		return (101);
	}
	/* Time: O(gpus x steps); Space: O(gpus x steps). */
	for (k = 0; k < n && k < MAX_GPUS; k++) {
		i = nvrm_device_info_get(nvrm_device_get(ctx, k));
		snprintf(gpu_name, sizeof(gpu_name),
		    "gpu %u (%04jx:%02jx:%02jx.%jx %04jx:%04jx)", k,
		    (uintmax_t)i->pci_domain.value, (uintmax_t)i->pci_bus.value,
		    (uintmax_t)i->pci_slot.value,
		    (uintmax_t)i->pci_function.value,
		    (uintmax_t)i->pci_vendor.value, (uintmax_t)i->pci_device.value);
		snprintf(gpus[ngpus].pci, sizeof(gpus[ngpus].pci),
		    "%04jx:%02jx:%02jx.%jx", (uintmax_t)i->pci_domain.value,
		    (uintmax_t)i->pci_bus.value, (uintmax_t)i->pci_slot.value,
		    (uintmax_t)i->pci_function.value);
		ngpus++;
		run_gpu(nvrm_device_get(ctx, k), &gpus[ngpus - 1]);
	}
	nvrm_close(ctx);
	if (json_mode)
		print_json();
	return (fails > 100 ? 100 : fails);
}

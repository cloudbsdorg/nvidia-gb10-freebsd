/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * mem_test.c - libnvrm S2 (Track #2419): the VA allocator, the memory
 * attribute rule, and the memory core on the fake backend's software GPU.
 * Built with the library sources and coverage; the gate demands 100% line
 * and branch coverage of nvrm_va.c, nvrm_mem.c and nvrm_fake_mem.c.  No
 * hardware and no driver: everything runs on the fake memory model.
 *
 * Acceptance of the plan row S2: read-back of VRAM and system memory through
 * both the CPU and the GPU model, a sparse map, and a 100k allocate/free loop
 * that leaves nothing behind (client counters and the backend's own).
 */
#include <sys/types.h>
#include <sys/capsicum.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/sysctl.h>
#include <sys/user.h>

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "nvrm_internal.h"
#include "nvrm_fake.h"
#include "t.h"

#include "fault_calloc.h"

#define KiB	1024ULL
#define MiB	(1024ULL * KiB)

static void
fail_calloc_at(int n)
{
	calloc_calls = 0;
	calloc_fail_at = n;
}

static int
stats_get(nvrm_client *cl, nvrm_client_stats *st)
{
	return (nvrm_client_stats_get(cl, st));
}

static nvrm_fake_mem_test_stats
tstats(void)
{
	nvrm_fake_mem_test_stats st;

	nvrm_fake_mem_test_stats_get(&st);
	return (st);
}

static nvrm_fake_mem_stats
bstats(void)
{
	return (tstats().base);
}

/* Leaks the last-close sweep has found, since the process began. */
static unsigned
leaked(void)
{
	return (tstats().leaked_objects);
}

/* The count at the start of the running test: a test that plants a leak
 * must not fail the clean checks of the tests after it. */
static unsigned leaked_base;

/* ---- the VA allocator ---------------------------------------------------- */

static void
test_va_basic(void)
{
	nvrm_va *va;
	uint64_t a, b, c;

	CHECK(nvrm_va_new(10, 10) == NULL);
	CHECK(nvrm_va_new(11, 10) == NULL);
	va = nvrm_va_new(0x1000, 0x100000);
	CHECK(va != NULL);
	CHECK_EQ(nvrm_va_extents(va), 1);
	CHECK_EQ(nvrm_va_free_bytes(va), 0x100000 - 0x1000);
	/* first fit, lowest first */
	CHECK_EQ(nvrm_va_alloc(va, 0x2000, 0x1000, 0, 0, &a), NVRM_OK);
	CHECK_EQ(a, 0x1000);
	CHECK_EQ(nvrm_va_alloc(va, 0x1000, 0, 0, 0, &b), NVRM_OK);
	CHECK_EQ(b, 0x3000);
	/* alignment: the next 64 KiB boundary */
	CHECK_EQ(nvrm_va_alloc(va, 0x1000, 0x10000, 0, 0, &c), NVRM_OK);
	CHECK_EQ(c, 0x10000);
	CHECK_EQ(nvrm_va_extents(va), 2);	/* a hole 0x4000..0x10000 */
	/* the hole is used before the top */
	CHECK_EQ(nvrm_va_alloc(va, 0x6000, 0x1000, 0, 0, &a), NVRM_OK);
	CHECK_EQ(a, 0x4000);
	/* arguments */
	CHECK_EQ(nvrm_va_alloc(va, 0, 0x1000, 0, 0, &a), NVRM_E_INVAL);
	CHECK_EQ(nvrm_va_alloc(va, 0x1000, 3, 0, 0, &a), NVRM_E_INVAL);
	/* nothing big enough */
	CHECK_EQ(nvrm_va_alloc(va, 0x200000, 0x1000, 0, 0, &a), NVRM_E_RANGE);
	nvrm_va_destroy(va);
	nvrm_va_destroy(NULL);
}

static void
test_va_fixed_and_free(void)
{
	nvrm_va *va = nvrm_va_new(0x1000, 0x20000);
	uint64_t a;

	/* fixed in the middle splits the extent in two */
	CHECK_EQ(nvrm_va_alloc(va, 0x2000, 0x1000, 1, 0x8000, &a), NVRM_OK);
	CHECK_EQ(a, 0x8000);
	CHECK_EQ(nvrm_va_extents(va), 2);
	/* the same range again is not free */
	CHECK_EQ(nvrm_va_alloc(va, 0x1000, 0x1000, 1, 0x9000, &a), NVRM_E_RANGE);
	/* overlapping its start */
	CHECK_EQ(nvrm_va_alloc(va, 0x2000, 0x1000, 1, 0x7000, &a), NVRM_E_RANGE);
	/* below the space */
	CHECK_EQ(nvrm_va_alloc(va, 0x1000, 0x1000, 1, 0x0, &a), NVRM_E_RANGE);
	/* above the space */
	CHECK_EQ(nvrm_va_alloc(va, 0x1000, 0x1000, 1, 0x30000, &a), NVRM_E_RANGE);
	/* a fixed address that breaks the alignment */
	CHECK_EQ(nvrm_va_alloc(va, 0x1000, 0x10000, 1, 0x11000, &a), NVRM_E_INVAL);
	/* head of an extent, tail of an extent, the whole of an extent */
	CHECK_EQ(nvrm_va_alloc(va, 0x1000, 0x1000, 1, 0x1000, &a), NVRM_OK);
	CHECK_EQ(nvrm_va_alloc(va, 0x1000, 0x1000, 1, 0x7000, &a), NVRM_OK);
	CHECK_EQ(nvrm_va_alloc(va, 0x5000, 0x1000, 1, 0x2000, &a), NVRM_OK);
	CHECK_EQ(nvrm_va_extents(va), 1);	/* only 0xa000..0x20000 is left */
	/* free arguments */
	CHECK_EQ(nvrm_va_free(va, 0x8000, 0), NVRM_E_INVAL);
	CHECK_EQ(nvrm_va_free(va, 0x0, 0x1000), NVRM_E_INVAL);
	CHECK_EQ(nvrm_va_free(va, 0x20000, 0x1000), NVRM_E_INVAL);
	CHECK_EQ(nvrm_va_free(va, 0x1f000, 0x2000), NVRM_E_INVAL);
	/* free of space that is free */
	CHECK_EQ(nvrm_va_free(va, 0xb000, 0x1000), NVRM_E_RANGE);
	CHECK_EQ(nvrm_va_free(va, 0x9000, 0x2000), NVRM_E_RANGE);
	/* a hole with nothing next to it: a new extent, then both neighbours */
	CHECK_EQ(nvrm_va_free(va, 0x8000, 0x2000), NVRM_OK);	/* touches the top extent at 0xa000 */
	CHECK_EQ(nvrm_va_extents(va), 1);
	CHECK_EQ(nvrm_va_free(va, 0x2000, 0x1000), NVRM_OK);	/* alone */
	CHECK_EQ(nvrm_va_extents(va), 2);
	CHECK_EQ(nvrm_va_free(va, 0x4000, 0x1000), NVRM_OK);	/* alone, after it */
	CHECK_EQ(nvrm_va_extents(va), 3);
	CHECK_EQ(nvrm_va_free(va, 0x3000, 0x1000), NVRM_OK);	/* joins both */
	CHECK_EQ(nvrm_va_extents(va), 2);
	CHECK_EQ(nvrm_va_free(va, 0x1000, 0x1000), NVRM_OK);	/* extends the first at its start */
	CHECK_EQ(nvrm_va_free(va, 0x5000, 0x3000), NVRM_OK);	/* the rest of the hole */
	CHECK_EQ(nvrm_va_extents(va), 1);
	CHECK_EQ(nvrm_va_free_bytes(va), 0x20000 - 0x1000);
	nvrm_va_destroy(va);
}

static void
test_va_edges(void)
{
	nvrm_va *va;
	uint64_t a;

	/* an alignment that wraps past the top of the 64-bit range skips the
	 * extent instead of wrapping to a low address */
	va = nvrm_va_new(0x8000000000000001ULL, 0xfffffffffffff000ULL);
	CHECK(va != NULL);
	CHECK_EQ(nvrm_va_alloc(va, 0x1000, 1ULL << 63, 0, 0, &a), NVRM_E_RANGE);
	CHECK_EQ(nvrm_va_alloc(va, 0x1000, 0x1000, 0, 0, &a), NVRM_OK);
	CHECK_EQ(a, 0x8000000000001000ULL);
	nvrm_va_destroy(va);
	/* an aligned start that lands at or beyond the end of its extent */
	va = nvrm_va_new(0x1100, 0x1800);
	CHECK_EQ(nvrm_va_alloc(va, 0x100, 0x1000, 0, 0, &a), NVRM_E_RANGE);
	nvrm_va_destroy(va);
}

static void
test_va_oom(void)
{
	nvrm_va *va;
	uint64_t a;

	fail_calloc_at(1);
	CHECK(nvrm_va_new(0, 0x10000) == NULL);
	fail_calloc_at(2);
	CHECK(nvrm_va_new(0, 0x10000) == NULL);
	fail_calloc_at(0);
	va = nvrm_va_new(0, 0x10000);
	/* the split needs a node: it fails and the allocator is unchanged */
	fail_calloc_at(1);
	CHECK_EQ(nvrm_va_alloc(va, 0x1000, 0x1000, 1, 0x4000, &a), NVRM_E_NOMEM);
	fail_calloc_at(0);
	CHECK_EQ(nvrm_va_extents(va), 1);
	CHECK_EQ(nvrm_va_free_bytes(va), 0x10000);
	CHECK_EQ(nvrm_va_alloc(va, 0x1000, 0x1000, 1, 0x4000, &a), NVRM_OK);
	/* a free of space with used neighbours needs a node */
	CHECK_EQ(nvrm_va_alloc(va, 0x3000, 0x1000, 1, 0x8000, &a), NVRM_OK);
	fail_calloc_at(1);
	CHECK_EQ(nvrm_va_free(va, 0x9000, 0x1000), NVRM_E_NOMEM);
	fail_calloc_at(0);
	CHECK_EQ(nvrm_va_extents(va), 3);
	CHECK_EQ(nvrm_va_free(va, 0x9000, 0x1000), NVRM_OK);
	CHECK_EQ(nvrm_va_extents(va), 4);
	nvrm_va_destroy(va);
}

/* A shadow bitmap against 20000 random operations: after every one, the
 * allocator's free bytes and extent count are those of the shadow. */
#define SHADOW_PAGES	512

static void
test_va_shadow(void)
{
	static unsigned char used[SHADOW_PAGES];
	static uint64_t start[SHADOW_PAGES], len[SHADOW_PAGES];
	nvrm_va *va = nvrm_va_new(0, SHADOW_PAGES * 4096ULL);
	unsigned live = 0, i, j, free_pages, extents, op;
	uint64_t a, n, al;
	int rc, bad = 0;

	srandom(7);
	for (i = 0; i < 20000 && !bad; i++) {
		op = random() % 3;
		if (op != 0 && live > 0) {
			j = random() % live;
			rc = nvrm_va_free(va, start[j], len[j]);
			bad |= rc != NVRM_OK;
			memset(used + start[j] / 4096, 0, len[j] / 4096);
			start[j] = start[live - 1];
			len[j] = len[live - 1];
			live--;
		} else if (live < SHADOW_PAGES) {
			n = (1 + random() % 8) * 4096ULL;
			al = 4096ULL << (random() % 4);
			rc = nvrm_va_alloc(va, n, al, 0, 0, &a);
			if (rc == NVRM_OK) {
				for (j = 0; j < n / 4096; j++)
					bad |= used[a / 4096 + j] != 0;
				memset(used + a / 4096, 1, n / 4096);
				start[live] = a;
				len[live++] = n;
				bad |= (a & (al - 1)) != 0;
			} else
				bad |= rc != NVRM_E_RANGE;
		}
		free_pages = extents = 0;
		for (j = 0; j < SHADOW_PAGES; j++) {
			free_pages += !used[j];
			extents += !used[j] && (j == 0 || used[j - 1]);
		}
		bad |= nvrm_va_free_bytes(va) != free_pages * 4096ULL;
		bad |= nvrm_va_extents(va) != extents;
	}
	CHECK(bad == 0);
	nvrm_va_destroy(va);
}

/* ---- the memory attribute rule ----------------------------------------- */

static void
test_attr_rule(void)
{
	nvrm_u64 unk = { 0, NVRM_R_OS_NOT_REPORTED, NVRM_S_OS };
	nvrm_u64 on = { 1, NVRM_R_NONE, NVRM_S_OS };
	nvrm_u64 off = { 0, NVRM_R_NONE, NVRM_S_OS };

	const int C = NVRM_COH_CACHED;

	/* cached system memory is write-back everywhere, whatever the flag says */
	CHECK_EQ(nvrm_cpu_attr_rule(NVRM_PLACE_SYSMEM, C, 1, &on), NVRM_ATTR_CACHED);
	CHECK_EQ(nvrm_cpu_attr_rule(NVRM_PLACE_SYSMEM, C, 1, &unk), NVRM_ATTR_CACHED);
	CHECK_EQ(nvrm_cpu_attr_rule(NVRM_PLACE_SYSMEM, C, 0, &off), NVRM_ATTR_CACHED);
	/* system memory its owner made write-combined, or uncached (an import):
	 * write-combining, and the Device rule on every host */
	CHECK_EQ(nvrm_cpu_attr_rule(NVRM_PLACE_SYSMEM, NVRM_COH_WC, 1, &off), NVRM_ATTR_WC);
	CHECK_EQ(nvrm_cpu_attr_rule(NVRM_PLACE_SYSMEM, NVRM_COH_WC, 0, &off), NVRM_ATTR_WC);
	CHECK_EQ(nvrm_cpu_attr_rule(NVRM_PLACE_SYSMEM, NVRM_COH_UNCACHED, 1, &off), NVRM_ATTR_DEVICE);
	CHECK_EQ(nvrm_cpu_attr_rule(NVRM_PLACE_SYSMEM, NVRM_COH_UNCACHED, 0, &off), NVRM_ATTR_DEVICE);
	/* video memory off arm64: write-combined, whatever the flag says */
	CHECK_EQ(nvrm_cpu_attr_rule(NVRM_PLACE_VIDMEM, C, 0, &on), NVRM_ATTR_WC);
	CHECK_EQ(nvrm_cpu_attr_rule(NVRM_PLACE_VIDMEM, C, 0, &unk), NVRM_ATTR_WC);
	/* arm64: Device where the OS layer falls back, or does not say */
	CHECK_EQ(nvrm_cpu_attr_rule(NVRM_PLACE_VIDMEM, C, 1, &on), NVRM_ATTR_DEVICE);
	CHECK_EQ(nvrm_cpu_attr_rule(NVRM_PLACE_VIDMEM, C, 1, &unk), NVRM_ATTR_DEVICE);
	/* arm64 where write-combining is Normal non-cacheable */
	CHECK_EQ(nvrm_cpu_attr_rule(NVRM_PLACE_VIDMEM, C, 1, &off), NVRM_ATTR_WC);
}

/* ---- helpers for the memory core --------------------------------------- */

static nvrm_ctx *ctx;

static void
setup(const char *profile, const char *host)
{
	char err[200];

	leaked_base = leaked();
	setenv("NVRM_FAKE_PROFILE", profile, 1);
	if (host != NULL)
		setenv("NVRM_FAKE_HOST", host, 1);
	else
		unsetenv("NVRM_FAKE_HOST");
	nvrm_enum_opts o = { "fake" };
	CHECK_EQ(nvrm_enumerate(&ctx, &o, err, sizeof(err)), NVRM_OK);
}

static void
teardown(void)
{
	nvrm_close(ctx);
	ctx = NULL;
	nvrm_fake_mem_fail_clear();
}

static nvrm_client *
open_client(unsigned flags, unsigned map_slots, unsigned export_slots)
{
	nvrm_open_opts o = { 0, flags, map_slots, export_slots };
	nvrm_client *cl = NULL;
	char err[200];

	CHECK_EQ(nvrm_client_open(nvrm_device_get(ctx, 0), &o, &cl, err,
	    sizeof(err)), NVRM_OK);
	return (cl);
}

static nvrm_mem *
alloc_mem(nvrm_client *cl, int kind, uint64_t bytes, uint64_t page_size)
{
	nvrm_mem_params p = { 0, (uint32_t)kind, 0, 0, bytes, 0, page_size };
	nvrm_mem *m = NULL;

	CHECK_EQ(nvrm_mem_alloc(cl, &p, &m), NVRM_OK);
	return (m);
}

static uint64_t
reserve(nvrm_client *cl, uint64_t bytes, uint32_t flags, uint64_t fixed)
{
	nvrm_va_params p = { 0, flags, bytes, 0, fixed };
	uint64_t va = 0;

	CHECK_EQ(nvrm_va_reserve(cl, &p, &va), NVRM_OK);
	return (va);
}

static int
map_gpu(nvrm_mem *m, uint64_t va, uint64_t off, uint64_t len, uint32_t flags)
{
	nvrm_gpu_map_params p = { 0, flags, va, off, len };

	return (nvrm_mem_map_gpu(m, &p));
}

static void
fill(uint8_t *b, size_t n, unsigned seed)
{
	size_t i;

	for (i = 0; i < n; i++)
		b[i] = (uint8_t)((i * 131 + seed) ^ (i >> 8));
}

static void
expect_clean(const char *what)
{
	nvrm_fake_mem_stats st = bstats();
	unsigned lk = leaked() - leaked_base;

	if (st.clients != 0 || st.objects != 0 || st.reservations != 0 ||
	    st.gpu_maps != 0 || lk != 0)
		printf("FAIL leak after %s: %u clients, %u objects, %u "
		    "reservations, %u GPU mappings, %u leaked objects\n", what,
		    st.clients, st.objects, st.reservations, st.gpu_maps, lk);
	CHECK_EQ(st.clients, 0);
	CHECK_EQ(st.objects, 0);
	CHECK_EQ(st.reservations, 0);
	CHECK_EQ(st.gpu_maps, 0);
	CHECK_EQ(lk, 0);
}

/* ---- the client ---------------------------------------------------------- */

static void
test_client_open_failures(nvrm_device *d)
{
	nvrm_open_opts o;
	nvrm_client *cl;
	char err[200];
	int n;

	/* each injected failure of the open leaves nothing behind */
	for (n = NVRM_FAKE_OP_CLIENT_OPEN; n <= NVRM_FAKE_OP_DESC; n++) {
		nvrm_fake_mem_fail(n, 1);
		cl = NULL;
		o = (nvrm_open_opts){ 0, NVRM_OPEN_ALLOW_MAP, 2, 2 };
		CHECK_EQ(nvrm_client_open(d, &o, &cl, err, sizeof(err)), NVRM_E_RM);
		CHECK(cl == NULL);
		CHECK(strstr(err, "injected") != NULL);
		expect_clean("injected open");
	}
	/* the export descriptors fail after the mapping ones: both pools unwind */
	nvrm_fake_mem_fail(NVRM_FAKE_OP_DESC, 3);
	o = (nvrm_open_opts){ 0, NVRM_OPEN_ALLOW_MAP, 2, 2 };
	CHECK_EQ(nvrm_client_open(d, &o, &cl, err, sizeof(err)), NVRM_E_RM);
	expect_clean("late injected");
	nvrm_fake_mem_fail(NVRM_FAKE_OP_LIMIT, 1);
	CHECK_EQ(nvrm_client_open(d, &o, &cl, err, sizeof(err)), NVRM_E_CAPSICUM);
	expect_clean("limit failed");
	nvrm_fake_mem_fail_clear();

	/* allocation failures: every nth allocation in turn */
	for (n = 1; n < 60; n++) {
		o = (nvrm_open_opts){ 0, NVRM_OPEN_ALLOW_MAP, 9, 1 };
		cl = NULL;
		fail_calloc_at(n);
		if (nvrm_client_open(d, &o, &cl, err, sizeof(err)) == NVRM_OK) {
			fail_calloc_at(0);
			nvrm_client_close(cl);
			break;
		}
		fail_calloc_at(0);
		CHECK(cl == NULL);
		expect_clean("oom open");
	}
	CHECK(n > 5 && n < 60);
}

static void
test_client_open(void)
{
	nvrm_open_opts o;
	nvrm_client *cl = NULL;
	nvrm_client_stats st;
	nvrm_vaspace_info vi;
	char err[200];
	nvrm_device *d;

	setup("discrete", NULL);
	d = nvrm_device_get(ctx, 0);
	/* defaults: no mapping descriptors, the default export ones */
	CHECK_EQ(nvrm_client_open(d, NULL, &cl, err, sizeof(err)), NVRM_OK);
	st.size = sizeof(st);
	CHECK_EQ(stats_get(cl, &st), NVRM_OK);
	CHECK_EQ(st.spare_descriptors, NVRM_EXPORT_SLOTS_DEFAULT);
	/* an output structure takes 0 or its size, like the input ones; a
	 * wrong size says so in the message, and the next good call clears it */
	st.size = 3;
	CHECK_EQ(stats_get(cl, &st), NVRM_E_INVAL);
	CHECK(strstr(nvrm_client_errmsg(cl), "nvrm_client_stats.size") != NULL);
	st.size = 0;
	CHECK_EQ(stats_get(cl, &st), NVRM_OK);
	CHECK_EQ(st.size, sizeof(st));
	CHECK_STR(nvrm_client_errmsg(cl), "");
	vi.size = 0;
	CHECK_EQ(nvrm_vaspace_info_get(cl, &vi), NVRM_OK);
	CHECK_EQ(vi.size, sizeof(vi));
	CHECK(vi.base > 0 && vi.end > vi.base);
	CHECK_EQ(vi.free_bytes, vi.end - vi.base);
	vi.size = 1;
	CHECK_EQ(nvrm_vaspace_info_get(cl, &vi), NVRM_E_INVAL);
	CHECK(strstr(nvrm_client_errmsg(cl), "nvrm_vaspace_info.size") != NULL);
	vi.size = sizeof(vi);
	CHECK_EQ(nvrm_vaspace_info_get(cl, &vi), NVRM_OK);
	CHECK_STR(nvrm_client_errmsg(cl), "");
	nvrm_client_close(cl);
	nvrm_client_close(NULL);
	/* the opt-in brings the mapping descriptors */
	o = (nvrm_open_opts){ sizeof(o), NVRM_OPEN_ALLOW_MAP, 0, 2 };
	CHECK_EQ(nvrm_client_open(d, &o, &cl, err, sizeof(err)), NVRM_OK);
	CHECK_EQ(stats_get(cl, &st), NVRM_OK);
	CHECK_EQ(st.spare_descriptors, NVRM_MAP_SLOTS_DEFAULT + 2);
	nvrm_client_close(cl);
	st.size = sizeof(st);
	o = (nvrm_open_opts){ 0, NVRM_OPEN_ALLOW_MAP, 3, 0 };
	CHECK_EQ(nvrm_client_open(d, &o, &cl, err, sizeof(err)), NVRM_OK);
	CHECK_EQ(stats_get(cl, &st), NVRM_OK);
	CHECK_EQ(st.spare_descriptors, 3 + NVRM_EXPORT_SLOTS_DEFAULT);
	nvrm_client_close(cl);
	/* a pool bigger than one growth step (8 descriptors) */
	o = (nvrm_open_opts){ 0, NVRM_OPEN_ALLOW_MAP, 20, 0 };
	CHECK_EQ(nvrm_client_open(d, &o, &cl, err, sizeof(err)), NVRM_OK);
	nvrm_client_close(cl);
	expect_clean("open");

	/* refusals, each with a message and no client */
	cl = (nvrm_client *)1;
	o = (nvrm_open_opts){ 12345, 0, 0, 0 };
	CHECK_EQ(nvrm_client_open(d, &o, &cl, err, sizeof(err)), NVRM_E_INVAL);
	CHECK(cl == NULL && strstr(err, "another version") != NULL);
	o = (nvrm_open_opts){ 0, 0x80, 0, 0 };
	CHECK_EQ(nvrm_client_open(d, &o, &cl, err, sizeof(err)), NVRM_E_INVAL);
	CHECK(strstr(err, "unknown open flags") != NULL);
	o = (nvrm_open_opts){ 0, 0, NVRM_SLOTS_MAX + 1, 0 };
	CHECK_EQ(nvrm_client_open(d, &o, &cl, err, sizeof(err)), NVRM_E_INVAL);
	CHECK(strstr(err, "map_slots is 1025, above the limit of 1024") != NULL);
	o = (nvrm_open_opts){ 0, 0, 0, NVRM_SLOTS_MAX + 1 };
	CHECK_EQ(nvrm_client_open(d, &o, &cl, err, sizeof(err)), NVRM_E_INVAL);
	CHECK(strstr(err, "export_slots is 1025") != NULL);
	CHECK_EQ(nvrm_client_open(d, &o, &cl, NULL, 0), NVRM_E_INVAL);
	CHECK_EQ(nvrm_client_open(d, &o, &cl, err, 0), NVRM_E_INVAL);
	CHECK_EQ(nvrm_client_open(d, NULL, &cl, NULL, 0), NVRM_OK);
	nvrm_client_close(cl);

	test_client_open_failures(d);
	teardown();
}

/* A backend whose VA space comes back empty. */
static int
emptyva_open(nvrm_backend *be, nvrm_gpu *g, const nvrm_open_cfg *cfg,
    nvrm_bclient **bc, nvrm_vainfo *va, char *err, size_t errlen)
{
	int rc = nvrm_fake_mem_ops.client_open(be, g, cfg, bc, va, err, errlen);

	va->end = va->base;
	return (rc);
}

/* the same client after the context that listed it is closed, a backend
 * whose VA space is empty, and a backend with no memory support */
static void
test_client_independent(void)
{
	nvrm_client *cl;
	nvrm_mem *m;
	char err[200];
	static const nvrm_backend_ops nomem = { .name = "nomem", .score = -1 };
	static nvrm_mem_ops emptyva_mem;
	static nvrm_backend_ops emptyva;
	nvrm_ctx fake_ctx;
	nvrm_device dev;

	setup("discrete", NULL);
	cl = open_client(0, 0, 0);
	nvrm_close(ctx);
	ctx = NULL;
	/* the page sizes the client checks against are its own copy */
	m = alloc_mem(cl, NVRM_MEM_VRAM, 128 * KiB, 64 * KiB);
	CHECK(m != NULL);
	nvrm_mem_free(m);
	m = alloc_mem(cl, NVRM_MEM_SYSMEM, 4096, 0);
	CHECK(m != NULL);
	nvrm_mem_free(m);
	nvrm_client_close(cl);
	expect_clean("independent");

	/* an empty VA space is a range error, not out of memory */
	setup("discrete", NULL);
	emptyva = *nvrm_device_get(ctx, 0)->ctx->ops;
	emptyva_mem = *emptyva.mem;
	emptyva_mem.client_open = emptyva_open;
	emptyva.mem = &emptyva_mem;
	memset(&fake_ctx, 0, sizeof(fake_ctx));
	memset(&dev, 0, sizeof(dev));
	fake_ctx.ops = &emptyva;
	fake_ctx.be = nvrm_device_get(ctx, 0)->ctx->be;
	dev = *nvrm_device_get(ctx, 0);
	dev.ctx = &fake_ctx;
	CHECK_EQ(nvrm_client_open(&dev, NULL, &cl, err, sizeof(err)), NVRM_E_RANGE);
	CHECK(cl == NULL && strstr(err, "empty VA space") != NULL);
	teardown();
	expect_clean("empty VA");

	memset(&fake_ctx, 0, sizeof(fake_ctx));
	memset(&dev, 0, sizeof(dev));
	fake_ctx.ops = &nomem;
	dev.ctx = &fake_ctx;
	cl = (nvrm_client *)1;
	CHECK_EQ(nvrm_client_open(&dev, NULL, &cl, err, sizeof(err)), NVRM_E_NOTSUP);
	CHECK(cl == NULL);
}

/* ---- VA reservations ----------------------------------------------------- */

static void
test_reserve_release_oom(nvrm_client *cl, uint64_t va2)
{
	uint64_t ra, rb, rc2;
	nvrm_va_params q;

	/* a release whose free-list node cannot be had: the RM side is
	 * released, and the addresses are lost to the allocator for good (never
	 * handed out twice), which the message says */
	q = (nvrm_va_params){ 0, 0, 4096, 0, va2 + 1 * MiB };
	CHECK_EQ(nvrm_va_reserve(cl, &q, &ra), NVRM_OK);
	q.fixed = va2 + 1 * MiB + 4096;
	CHECK_EQ(nvrm_va_reserve(cl, &q, &rb), NVRM_OK);
	q.fixed = va2 + 1 * MiB + 8192;
	CHECK_EQ(nvrm_va_reserve(cl, &q, &rc2), NVRM_OK);
	fail_calloc_at(1);
	CHECK_EQ(nvrm_va_release(cl, rb), NVRM_E_NOMEM);
	fail_calloc_at(0);
	CHECK(strstr(nvrm_client_errmsg(cl), "lost to the allocator") != NULL);
	CHECK_EQ(nvrm_va_release(cl, rb), NVRM_E_INVAL);
	CHECK_EQ(nvrm_va_reserve(cl, &q, &rb), NVRM_E_RANGE);	/* q.fixed: rc2 */
	q.fixed = rb;
	CHECK_EQ(nvrm_va_reserve(cl, &q, &rb), NVRM_E_RANGE);
	CHECK_EQ(nvrm_va_release(cl, ra), NVRM_OK);
	CHECK_EQ(nvrm_va_release(cl, rc2), NVRM_OK);
}

static void
test_reserve(void)
{
	nvrm_client *cl;
	nvrm_va_params p;
	nvrm_vaspace_info vi = { sizeof(vi) };
	uint64_t va, va2, free0;
	int n;

	setup("discrete", NULL);
	cl = open_client(0, 0, 0);
	nvrm_vaspace_info_get(cl, &vi);
	free0 = vi.free_bytes;
	va = reserve(cl, 1 * MiB, 0, 0);
	CHECK(va != 0 && (va & 4095) == 0);
	nvrm_vaspace_info_get(cl, &vi);
	CHECK_EQ(vi.free_bytes, free0 - 1 * MiB);
	/* alignment and fixed placement */
	p = (nvrm_va_params){ 0, 0, 64 * KiB, 2 * MiB, 0 };
	CHECK_EQ(nvrm_va_reserve(cl, &p, &va2), NVRM_OK);
	CHECK_EQ(va2 % (2 * MiB), 0);
	p = (nvrm_va_params){ sizeof(p), NVRM_VA_SPARSE, 64 * KiB, 0, va2 + 4 * MiB };
	CHECK_EQ(nvrm_va_reserve(cl, &p, &va), NVRM_OK);
	CHECK_EQ(va, va2 + 4 * MiB);
	/* the same fixed range again */
	CHECK_EQ(nvrm_va_reserve(cl, &p, &va), NVRM_E_RANGE);
	CHECK(strstr(nvrm_client_errmsg(cl), "no free range of 0x10000 bytes at the fixed address") != NULL);
	/* argument errors, each with its message */
	p = (nvrm_va_params){ 7, 0, 4096, 0, 0 };
	CHECK_EQ(nvrm_va_reserve(cl, &p, &va), NVRM_E_INVAL);
	CHECK(strstr(nvrm_client_errmsg(cl), "nvrm_va_params.size must be 0 or sizeof(nvrm_va_params)") != NULL);
	p = (nvrm_va_params){ 0, 0x8, 4096, 0, 0 };
	CHECK_EQ(nvrm_va_reserve(cl, &p, &va), NVRM_E_INVAL);
	p = (nvrm_va_params){ 0, 0, 4096, 3, 0 };
	CHECK_EQ(nvrm_va_reserve(cl, &p, &va), NVRM_E_INVAL);
	p = (nvrm_va_params){ 0, 0, 4096, 2048, 0 };
	CHECK_EQ(nvrm_va_reserve(cl, &p, &va), NVRM_E_INVAL);
	p = (nvrm_va_params){ 0, 0, 0, 0, 0 };
	CHECK_EQ(nvrm_va_reserve(cl, &p, &va), NVRM_E_INVAL);
	p = (nvrm_va_params){ 0, 0, 5000, 0, 0 };
	CHECK_EQ(nvrm_va_reserve(cl, &p, &va), NVRM_E_INVAL);
	p = (nvrm_va_params){ 0, 0, 4096, 65536, 0x10000 + 4096 };
	CHECK_EQ(nvrm_va_reserve(cl, &p, &va), NVRM_E_INVAL);
	/* more than the whole space */
	p = (nvrm_va_params){ 0, 0, 1ULL << 50, 0, 0 };
	CHECK_EQ(nvrm_va_reserve(cl, &p, &va), NVRM_E_RANGE);
	/* releasing */
	CHECK_EQ(nvrm_va_release(cl, 0x12345000), NVRM_E_INVAL);
	CHECK_EQ(nvrm_va_release(cl, va2 + 4 * MiB), NVRM_OK);
	CHECK_EQ(nvrm_va_release(cl, va2 + 4 * MiB), NVRM_E_INVAL);
	CHECK_EQ(nvrm_va_release(cl, va2), NVRM_OK);
	/* what was released can be reserved again at the same place */
	p = (nvrm_va_params){ 0, 0, 64 * KiB, 0, va2 };
	CHECK_EQ(nvrm_va_reserve(cl, &p, &va), NVRM_OK);
	CHECK_EQ(va, va2);
	/* injected backend failure and allocation failures leave the VA space as it was */
	nvrm_vaspace_info_get(cl, &vi);
	free0 = vi.free_bytes;
	p = (nvrm_va_params){ 0, 0, 1 * MiB, 0, 0 };
	nvrm_fake_mem_fail(NVRM_FAKE_OP_VA_RESERVE, 1);
	CHECK_EQ(nvrm_va_reserve(cl, &p, &va), NVRM_E_RM);
	nvrm_vaspace_info_get(cl, &vi);
	CHECK_EQ(vi.free_bytes, free0);
	for (n = 1; n < 10; n++) {
		fail_calloc_at(n);
		if (nvrm_va_reserve(cl, &p, &va) == NVRM_OK) {
			fail_calloc_at(0);
			nvrm_va_release(cl, va);
			break;
		}
		fail_calloc_at(0);
		nvrm_vaspace_info_get(cl, &vi);
		CHECK_EQ(vi.free_bytes, free0);
	}
	CHECK(n > 1 && n < 10);
	/* the allocator itself refuses to give a node (the split of a fixed one) */
	p = (nvrm_va_params){ 0, 0, 4096, 0, va2 + 1 * MiB };
	fail_calloc_at(1);
	CHECK_EQ(nvrm_va_reserve(cl, &p, &va), NVRM_E_NOMEM);
	fail_calloc_at(0);
	test_reserve_release_oom(cl, va2);
	nvrm_client_close(cl);
	expect_clean("reserve");
	teardown();
}

/* ---- memory objects ------------------------------------------------------ */

/* #lizard forgives -- one scripted scenario, steps share state; split tracked as DEBT on #2419 */
static void
test_alloc(void)
{
	nvrm_client *cl;
	nvrm_mem *m, *m2;
	nvrm_mem_params p;
	nvrm_mem_info mi = { sizeof(mi) };
	nvrm_client_stats st = { sizeof(st) };
	int n;

	setup("discrete", "amd64");
	cl = open_client(0, 0, 0);
	/* VRAM on a card with video memory is video memory, write-combined */
	m = alloc_mem(cl, NVRM_MEM_VRAM, 5000, 0);
	CHECK_EQ(nvrm_mem_info_get(m, &mi), NVRM_OK);
	CHECK_EQ(mi.kind, NVRM_MEM_VRAM);
	CHECK_EQ(mi.place, NVRM_PLACE_VIDMEM);
	CHECK_EQ(mi.cpu_attr, NVRM_ATTR_WC);
	CHECK_EQ(mi.bytes, 8192);		/* rounded up to 4 KiB */
	CHECK_EQ(mi.page_size, 4096);
	CHECK_EQ(mi.cpu_mapped, 0);
	CHECK_EQ(mi.gpu_maps, 0);
	mi.size = 2;
	CHECK_EQ(nvrm_mem_info_get(m, &mi), NVRM_E_INVAL);
	mi.size = sizeof(mi);
	m2 = alloc_mem(cl, NVRM_MEM_SYSMEM, 1 * MiB, 64 * KiB);
	CHECK_EQ(nvrm_mem_info_get(m2, &mi), NVRM_OK);
	CHECK_EQ(mi.place, NVRM_PLACE_SYSMEM);
	CHECK_EQ(mi.cpu_attr, NVRM_ATTR_CACHED);
	CHECK_EQ(mi.page_size, 64 * KiB);
	CHECK_EQ(stats_get(cl, &st), NVRM_OK);
	CHECK_EQ(st.live_mem, 2);
	CHECK_EQ(st.live_bytes, 8192 + 1 * MiB);
	CHECK_EQ(st.allocs, 2);
	nvrm_mem_free(m);
	nvrm_mem_free(m2);
	stats_get(cl, &st);
	CHECK(st.live_mem == 0 && st.live_bytes == 0 && st.frees == 2);
	/* a 2 MiB page object is rounded to it and aligned to it */
	m = alloc_mem(cl, NVRM_MEM_VRAM, 100, 2 * MiB);
	nvrm_mem_info_get(m, &mi);
	CHECK_EQ(mi.bytes, 2 * MiB);
	CHECK_EQ(mi.page_size, 2 * MiB);
	nvrm_mem_free(m);
	p = (nvrm_mem_params){ 0, NVRM_MEM_SYSMEM, 0, 0, 4096, 1 * MiB, 0 };
	CHECK_EQ(nvrm_mem_alloc(cl, &p, &m), NVRM_OK);
	nvrm_mem_free(m);

	/* refusals */
	m = NULL;
	p = (nvrm_mem_params){ 3, NVRM_MEM_VRAM, 0, 0, 4096, 0, 0 };
	CHECK_EQ(nvrm_mem_alloc(cl, &p, &m), NVRM_E_INVAL);
	p = (nvrm_mem_params){ 0, NVRM_MEM_USER, 0, 0, 4096, 0, 0 };
	CHECK_EQ(nvrm_mem_alloc(cl, &p, &m), NVRM_E_INVAL);
	p = (nvrm_mem_params){ 0, 0, 0, 0, 4096, 0, 0 };
	CHECK_EQ(nvrm_mem_alloc(cl, &p, &m), NVRM_E_INVAL);
	p = (nvrm_mem_params){ 0, NVRM_MEM_VRAM, 1, 0, 4096, 0, 0 };
	CHECK_EQ(nvrm_mem_alloc(cl, &p, &m), NVRM_E_INVAL);
	p = (nvrm_mem_params){ 0, NVRM_MEM_VRAM, 0, 1, 4096, 0, 0 };
	CHECK_EQ(nvrm_mem_alloc(cl, &p, &m), NVRM_E_INVAL);
	p = (nvrm_mem_params){ 0, NVRM_MEM_VRAM, 0, 0, 0, 0, 0 };
	CHECK_EQ(nvrm_mem_alloc(cl, &p, &m), NVRM_E_INVAL);
	p = (nvrm_mem_params){ 0, NVRM_MEM_VRAM, 0, 0, 4096, 3, 0 };
	CHECK_EQ(nvrm_mem_alloc(cl, &p, &m), NVRM_E_INVAL);
	p = (nvrm_mem_params){ 0, NVRM_MEM_VRAM, 0, 0, 4096, 0, 8192 };
	CHECK_EQ(nvrm_mem_alloc(cl, &p, &m), NVRM_E_INVAL);
	CHECK(strstr(nvrm_client_errmsg(cl), "page size") != NULL);
	p = (nvrm_mem_params){ 0, NVRM_MEM_VRAM, 0, 0, UINT64_MAX - 100, 0, 2 * MiB };
	CHECK_EQ(nvrm_mem_alloc(cl, &p, &m), NVRM_E_INVAL);
	CHECK(strstr(nvrm_client_errmsg(cl), "too large") != NULL);
	/* the card's video memory runs out (capped at 64 MiB in the fake) */
	p = (nvrm_mem_params){ 0, NVRM_MEM_VRAM, 0, 0, 65 * MiB, 0, 0 };
	CHECK_EQ(nvrm_mem_alloc(cl, &p, &m), NVRM_E_NOMEM);
	CHECK(strstr(nvrm_client_errmsg(cl), "video memory") != NULL);
	p = (nvrm_mem_params){ 0, NVRM_MEM_SYSMEM, 0, 0, 300 * MiB, 0, 0 };
	CHECK_EQ(nvrm_mem_alloc(cl, &p, &m), NVRM_E_NOMEM);
	CHECK(strstr(nvrm_client_errmsg(cl), "system memory") != NULL);
	/* an injected failure and every allocation failure leave nothing live */
	p = (nvrm_mem_params){ 0, NVRM_MEM_VRAM, 0, 0, 4096, 0, 0 };
	nvrm_fake_mem_fail(NVRM_FAKE_OP_ALLOC, 1);
	CHECK_EQ(nvrm_mem_alloc(cl, &p, &m), NVRM_E_RM);
	for (n = 1; n < 10; n++) {
		fail_calloc_at(n);
		if (nvrm_mem_alloc(cl, &p, &m) == NVRM_OK) {
			fail_calloc_at(0);
			nvrm_mem_free(m);
			break;
		}
		fail_calloc_at(0);
		stats_get(cl, &st);
		CHECK_EQ(st.live_mem, 0);
		CHECK_EQ(bstats().objects, 0);
	}
	CHECK(n > 2 && n < 10);
	nvrm_client_close(cl);
	teardown();

	/* a card with no video memory (unified): VRAM is system memory */
	setup("unified", "amd64");
	cl = open_client(0, 0, 0);
	m = alloc_mem(cl, NVRM_MEM_VRAM, 4096, 0);
	nvrm_mem_info_get(m, &mi);
	CHECK_EQ(mi.kind, NVRM_MEM_VRAM);
	CHECK_EQ(mi.place, NVRM_PLACE_SYSMEM);
	CHECK_EQ(mi.cpu_attr, NVRM_ATTR_CACHED);
	nvrm_mem_free(m);
	nvrm_client_close(cl);
	teardown();

	/* a GPU the generation table does not know: only 4 KiB pages */
	setup("unknown", "amd64");
	cl = open_client(0, 0, 0);
	p = (nvrm_mem_params){ 0, NVRM_MEM_SYSMEM, 0, 0, 4096, 0, 64 * KiB };
	CHECK_EQ(nvrm_mem_alloc(cl, &p, &m), NVRM_E_INVAL);
	p.page_size = 4096;
	CHECK_EQ(nvrm_mem_alloc(cl, &p, &m), NVRM_OK);
	nvrm_mem_free(m);
	nvrm_client_close(cl);
	teardown();

	/* a GPU whose video memory size is not reported: VRAM is tried as video memory,
	 * and the fake has none to give */
	setup("sparse", "amd64");
	cl = open_client(0, 0, 0);
	p = (nvrm_mem_params){ 0, NVRM_MEM_VRAM, 0, 0, 4096, 0, 0 };
	CHECK_EQ(nvrm_mem_alloc(cl, &p, &m), NVRM_E_NOMEM);
	nvrm_client_close(cl);
	teardown();
	expect_clean("alloc");
}

static void
test_register_user(void)
{
	nvrm_client *cl;
	nvrm_mem *m;
	nvrm_mem_info mi = { sizeof(mi) };
	nvrm_gpu_map_params gp;
	long pg = sysconf(_SC_PAGESIZE);
	char *buf = mmap(NULL, 4 * pg, PROT_READ | PROT_WRITE,
	    MAP_ANON | MAP_PRIVATE, -1, 0);
	uint8_t got[16];
	void *addr;
	uint64_t va;
	int n;

	setup("discrete", NULL);
	cl = open_client(NVRM_OPEN_ALLOW_MAP, 0, 0);
	CHECK_EQ(nvrm_mem_register_user(cl, buf, 4 * pg, &m), NVRM_OK);
	nvrm_mem_info_get(m, &mi);
	CHECK_EQ(mi.kind, NVRM_MEM_USER);
	CHECK_EQ(mi.place, NVRM_PLACE_SYSMEM);
	CHECK_EQ(mi.bytes, 4 * pg);
	/* the GPU sees the caller's pages through a mapping */
	va = reserve(cl, 1 * MiB, 0, 0);
	gp = (nvrm_gpu_map_params){ 0, 0, va, 0, 0 };
	CHECK_EQ(nvrm_mem_map_gpu(m, &gp), NVRM_OK);
	memset(buf + 100, 0x5a, 16);
	CHECK_EQ(nvrm_fake_gpu_access(cl, va + 100, got, 16, 0), 0);
	CHECK_EQ(got[0], 0x5a);
	memset(got, 0x77, 16);
	CHECK_EQ(nvrm_fake_gpu_access(cl, va + 200, got, 16, 1), 0);
	CHECK_EQ((uint8_t)buf[200], 0x77);
	/* the caller already has the pages: no CPU mapping, no export */
	CHECK_EQ(nvrm_mem_map_cpu(m, NVRM_CPU_READ, &addr), NVRM_E_INVAL);
	CHECK_EQ(nvrm_mem_export_fd(m, &n), NVRM_E_INVAL);
	nvrm_mem_free(m);
	/* refusals and failures */
	CHECK_EQ(nvrm_mem_register_user(cl, buf + 1, pg, &m), NVRM_E_INVAL);
	CHECK_EQ(nvrm_mem_register_user(cl, buf, pg + 1, &m), NVRM_E_INVAL);
	CHECK_EQ(nvrm_mem_register_user(cl, buf, 0, &m), NVRM_E_INVAL);
	nvrm_fake_mem_fail(NVRM_FAKE_OP_REGISTER, 1);
	CHECK_EQ(nvrm_mem_register_user(cl, buf, pg, &m), NVRM_E_RM);
	for (n = 1; n < 10; n++) {
		fail_calloc_at(n);
		if (nvrm_mem_register_user(cl, buf, pg, &m) == NVRM_OK) {
			fail_calloc_at(0);
			nvrm_mem_free(m);
			break;
		}
		fail_calloc_at(0);
		CHECK_EQ(bstats().objects, 0);
	}
	CHECK(n > 1 && n < 10);
	nvrm_client_close(cl);
	munmap(buf, 4 * pg);
	teardown();
	expect_clean("register");
}

/* ---- GPU mappings -------------------------------------------------------- */

static void
test_map_gpu(void)
{
	nvrm_client *cl;
	nvrm_mem *m, *m2;
	nvrm_mem_info mi = { sizeof(mi) };
	nvrm_client_stats st = { sizeof(st) };
	nvrm_gpu_map_params gp;
	uint64_t va;
	int n;

	setup("discrete", NULL);
	cl = open_client(0, 0, 0);
	m = alloc_mem(cl, NVRM_MEM_SYSMEM, 256 * KiB, 64 * KiB);
	m2 = alloc_mem(cl, NVRM_MEM_SYSMEM, 64 * KiB, 64 * KiB);
	va = reserve(cl, 1 * MiB, 0, 0);
	/* a mapping inside the reservation, whole object */
	CHECK_EQ(map_gpu(m, va, 0, 0, 0), NVRM_OK);
	nvrm_mem_info_get(m, &mi);
	CHECK_EQ(mi.gpu_maps, 1);
	/* overlaps: whole, partial, the start, the last byte */
	CHECK_EQ(map_gpu(m2, va, 0, 0, 0), NVRM_E_RANGE);
	CHECK_EQ(map_gpu(m2, va + 128 * KiB, 0, 0, 0), NVRM_E_RANGE);
	CHECK_EQ(map_gpu(m2, va + 256 * KiB - 64 * KiB, 0, 0, 0), NVRM_E_RANGE);
	CHECK(strstr(nvrm_client_errmsg(cl), "overlaps") != NULL);
	/* adjacent is fine */
	CHECK_EQ(map_gpu(m2, va + 256 * KiB, 0, 0, 0), NVRM_OK);
	/* outside every reservation, and straddling the end of one */
	CHECK_EQ(map_gpu(m2, va + 1 * MiB, 0, 0, 0), NVRM_E_RANGE);
	CHECK(strstr(nvrm_client_errmsg(cl), "inside one reservation") != NULL);
	CHECK_EQ(map_gpu(m, va + 1 * MiB - 64 * KiB, 0, 0, 0), NVRM_E_RANGE);	/* starts inside, ends past */
	CHECK(strstr(nvrm_client_errmsg(cl), "inside one reservation") != NULL);
	CHECK_EQ(map_gpu(m2, UINT64_MAX - 0xfff, 0, 0, 0), NVRM_E_INVAL);	/* not aligned to the object's pages */
	CHECK_EQ(map_gpu(m2, 0xffffffffffff0000ULL, 0, 0, 0), NVRM_E_RANGE);	/* wraps */
	/* argument errors */
	gp = (nvrm_gpu_map_params){ 5, 0, va + 512 * KiB, 0, 0 };
	CHECK_EQ(nvrm_mem_map_gpu(m2, &gp), NVRM_E_INVAL);
	CHECK_EQ(map_gpu(m2, va + 512 * KiB, 0, 0, 0x10), NVRM_E_INVAL);
	CHECK_EQ(map_gpu(m2, va + 512 * KiB, 64 * KiB, 0, 0), NVRM_E_RANGE);	/* offset past the end */
	CHECK_EQ(map_gpu(m2, va + 512 * KiB, 0, 128 * KiB, 0), NVRM_E_RANGE);	/* length past the end */
	CHECK_EQ(map_gpu(m2, va + 512 * KiB + 4096, 0, 0, 0), NVRM_E_INVAL);	/* va not page aligned */
	CHECK_EQ(map_gpu(m, va + 512 * KiB, 4096, 0, 0), NVRM_E_INVAL);		/* offset */
	CHECK_EQ(map_gpu(m, va + 512 * KiB, 0, 4096, 0), NVRM_E_INVAL);		/* length */
	/* a partial map: the second 64 KiB of m */
	CHECK_EQ(map_gpu(m, va + 512 * KiB, 64 * KiB, 64 * KiB, NVRM_MAP_READ_ONLY), NVRM_OK);
	stats_get(cl, &st);
	CHECK_EQ(st.live_gpu_maps, 3);
	/* the reservation is busy while it has mappings */
	CHECK_EQ(nvrm_va_release(cl, va), NVRM_E_BUSY);
	/* unmapping */
	CHECK_EQ(nvrm_mem_unmap_gpu(m, va + 4096), NVRM_E_INVAL);
	CHECK_EQ(nvrm_mem_unmap_gpu(m2, va), NVRM_E_INVAL);	/* the address is m's */
	CHECK_EQ(nvrm_mem_unmap_gpu(m, va), NVRM_OK);
	CHECK_EQ(nvrm_mem_unmap_gpu(m, va), NVRM_E_INVAL);
	CHECK_EQ(map_gpu(m2, va, 0, 0, 0), NVRM_OK);	/* the range is free again */
	/* freeing an object takes its mappings with it */
	nvrm_mem_free(m);
	stats_get(cl, &st);
	CHECK_EQ(st.live_gpu_maps, 2);
	CHECK_EQ(bstats().gpu_maps, 2);
	nvrm_mem_free(m2);
	CHECK_EQ(bstats().gpu_maps, 0);
	CHECK_EQ(nvrm_va_release(cl, va), NVRM_OK);
	/* injected failure and allocation failures */
	m = alloc_mem(cl, NVRM_MEM_SYSMEM, 64 * KiB, 64 * KiB);
	va = reserve(cl, 1 * MiB, 0, 0);
	nvrm_fake_mem_fail(NVRM_FAKE_OP_MAP_GPU, 1);
	CHECK_EQ(map_gpu(m, va, 0, 0, 0), NVRM_E_RM);
	for (n = 1; n < 10; n++) {
		fail_calloc_at(n);
		if (map_gpu(m, va, 0, 0, 0) == NVRM_OK) {
			fail_calloc_at(0);
			break;
		}
		fail_calloc_at(0);
		stats_get(cl, &st);
		CHECK_EQ(st.live_gpu_maps, 0);
		CHECK_EQ(bstats().gpu_maps, 0);
	}
	CHECK(n > 1 && n < 10);
	nvrm_mem_free(m);
	nvrm_client_close(cl);
	teardown();
	expect_clean("map gpu");
}

/* ---- the software GPU ---------------------------------------------------- */

static void
test_gpu_model(void)
{
	nvrm_client *cl;
	nvrm_mem *m;
	uint64_t va;
	uint8_t buf[64], zero[64];
	int rc;

	setup("discrete", NULL);
	cl = open_client(0, 0, 0);
	m = alloc_mem(cl, NVRM_MEM_VRAM, 64 * KiB, 0);
	va = reserve(cl, 1 * MiB, 0, 0);
	CHECK_EQ(map_gpu(m, va + 64 * KiB, 0, 0, 0), NVRM_OK);
	fill(buf, sizeof(buf), 1);
	/* through the mapping: the GPU writes, the GPU reads */
	CHECK_EQ(nvrm_fake_gpu_access(cl, va + 64 * KiB + 10, buf, 64, 1), 0);
	memset(zero, 0, sizeof(zero));
	CHECK_EQ(nvrm_fake_gpu_access(cl, va + 64 * KiB + 10, zero, 64, 0), 0);
	CHECK(memcmp(buf, zero, 64) == 0);
	/* a hole in an ordinary reservation faults, before and after the mapping */
	CHECK_EQ(nvrm_fake_gpu_access(cl, va, zero, 4, 0), NVRM_FAKE_FAULT_UNMAPPED);
	CHECK_EQ(nvrm_fake_gpu_access(cl, va + 128 * KiB, zero, 4, 1), NVRM_FAKE_FAULT_UNMAPPED);
	/* an access that starts mapped and runs into the hole faults */
	CHECK_EQ(nvrm_fake_gpu_access(cl, va + 128 * KiB - 8, buf, 64, 0), NVRM_FAKE_FAULT_UNMAPPED);
	/* outside every reservation faults */
	CHECK_EQ(nvrm_fake_gpu_access(cl, va + 4 * MiB, zero, 4, 0), NVRM_FAKE_FAULT_UNMAPPED);
	CHECK_EQ(nvrm_fake_gpu_access(cl, 0x10, zero, 4, 0), NVRM_FAKE_FAULT_UNMAPPED);
	/* zero length is nothing */
	CHECK_EQ(nvrm_fake_gpu_access(cl, 0x10, zero, 0, 0), 0);
	nvrm_mem_free(m);
	/* a read-only mapping refuses a GPU write and still reads */
	m = alloc_mem(cl, NVRM_MEM_SYSMEM, 64 * KiB, 0);
	CHECK_EQ(map_gpu(m, va, 0, 0, NVRM_MAP_READ_ONLY), NVRM_OK);
	rc = nvrm_fake_gpu_access(cl, va, buf, 4, 1);
	CHECK_EQ(rc, NVRM_FAKE_FAULT_READONLY);
	CHECK_EQ(nvrm_fake_gpu_access(cl, va, buf, 4, 0), 0);
	nvrm_mem_free(m);
	nvrm_client_close(cl);
	teardown();
}

/* ---- sparse -------------------------------------------------------------- */

static void
test_sparse(void)
{
	nvrm_client *cl;
	nvrm_mem *m;
	nvrm_gpu_map_params gp;
	uint64_t va, o;
	uint8_t buf[256], back[256];
	unsigned i;

	setup("discrete", NULL);
	cl = open_client(0, 0, 0);
	/* a 1 GiB sparse range with four 64 KiB pieces of one object in it */
	va = reserve(cl, 1ULL << 30, NVRM_VA_SPARSE, 0);
	m = alloc_mem(cl, NVRM_MEM_VRAM, 256 * KiB, 64 * KiB);
	for (i = 0; i < 4; i++) {
		gp = (nvrm_gpu_map_params){ 0, 0, va + (i * 10 + 1) * 64 * KiB * 16,
		    i * 64 * KiB, 64 * KiB };
		CHECK_EQ(nvrm_mem_map_gpu(m, &gp), NVRM_OK);
	}
	/* each piece holds its own bytes */
	for (i = 0; i < 4; i++) {
		o = va + (i * 10 + 1) * 64 * KiB * 16;
		fill(buf, sizeof(buf), 10 + i);
		CHECK_EQ(nvrm_fake_gpu_access(cl, o + 100, buf, sizeof(buf), 1), 0);
	}
	for (i = 0; i < 4; i++) {
		o = va + (i * 10 + 1) * 64 * KiB * 16;
		fill(buf, sizeof(buf), 10 + i);
		CHECK_EQ(nvrm_fake_gpu_access(cl, o + 100, back, sizeof(back), 0), 0);
		CHECK(memcmp(buf, back, sizeof(buf)) == 0);
	}
	/* a hole reads as zero, whatever was in the buffer, and is not touched by a write */
	memset(back, 0xee, sizeof(back));
	CHECK_EQ(nvrm_fake_gpu_access(cl, va, back, sizeof(back), 0), 0);
	for (i = 0; i < sizeof(back); i++)
		if (back[i] != 0)
			break;
	CHECK_EQ(i, sizeof(back));
	memset(buf, 0x99, sizeof(buf));
	CHECK_EQ(nvrm_fake_gpu_access(cl, va + 7 * MiB, buf, sizeof(buf), 1), 0);
	CHECK_EQ(nvrm_fake_gpu_access(cl, va + 7 * MiB, back, sizeof(back), 0), 0);
	CHECK_EQ(back[0], 0);
	/* one access that starts in a hole and runs into the first piece:
	 * the hole part reads as zeros, the piece part as the bytes written */
	o = va + 64 * KiB * 16;		/* the first piece */
	{
		uint8_t span[3 * 4096], want[256];

		fill(want, sizeof(want), 10);
		memset(span, 0xee, sizeof(span));
		CHECK_EQ(nvrm_fake_gpu_access(cl, o - 4096, span, sizeof(span), 0), 0);
		for (i = 0; i < 4096; i++)
			if (span[i] != 0)
				break;
		CHECK_EQ(i, 4096);
		CHECK(memcmp(span + 4096 + 100, want, sizeof(want)) == 0);
	}
	/* sparse stops at the end of the reservation */
	CHECK_EQ(nvrm_fake_gpu_access(cl, va + (1ULL << 30) - 8, back, 64, 0), NVRM_FAKE_FAULT_UNMAPPED);
	nvrm_mem_free(m);
	nvrm_client_close(cl);
	teardown();
	expect_clean("sparse");
}

/* ---- CPU mappings and the memory attribute rule -------------------------- */

static int capmode;

static int
hook_capmode(void)
{
	return (capmode);
}

/* #lizard forgives -- one scripted scenario, steps share state; split tracked as DEBT on #2419 */
static void
test_cpu_map(void)
{
	nvrm_client *cl;
	nvrm_mem *m, *m2, *m3;
	nvrm_mem_info mi = { sizeof(mi) };
	nvrm_client_stats st = { sizeof(st) };
	void *addr, *addr2;
	uint8_t buf[4096], back[4096];
	uint64_t va;
	int n;

	setup("discrete", "amd64");
	/* the default client refuses */
	cl = open_client(0, 0, 0);
	m = alloc_mem(cl, NVRM_MEM_SYSMEM, 8192, 0);
	CHECK_EQ(nvrm_mem_map_cpu(m, NVRM_CPU_READ, &addr), NVRM_E_DENIED);
	CHECK(strstr(nvrm_client_errmsg(cl), "NVRM_OPEN_ALLOW_MAP") != NULL);
	CHECK_EQ(nvrm_mem_read(m, 0, buf, 4), NVRM_E_INVAL);	/* not mapped */
	nvrm_mem_free(m);
	nvrm_client_close(cl);

	cl = open_client(NVRM_OPEN_ALLOW_MAP, 2, 1);
	m = alloc_mem(cl, NVRM_MEM_SYSMEM, 8192, 0);
	/* protection errors, then a mapping */
	CHECK_EQ(nvrm_mem_map_cpu(m, 0, &addr), NVRM_E_INVAL);
	CHECK_EQ(nvrm_mem_map_cpu(m, 8, &addr), NVRM_E_INVAL);
	CHECK_EQ(nvrm_mem_map_cpu(m, NVRM_CPU_READ | NVRM_CPU_WRITE, &addr), NVRM_OK);
	CHECK(addr != NULL);
	nvrm_mem_info_get(m, &mi);
	CHECK_EQ(mi.cpu_mapped, 1);
	CHECK_EQ(nvrm_mem_map_cpu(m, NVRM_CPU_READ, &addr2), NVRM_E_BUSY);
	stats_get(cl, &st);
	CHECK_EQ(st.live_cpu_maps, 1);
	/* the accessors: bounds, and the bytes arrive */
	fill(buf, sizeof(buf), 3);
	CHECK_EQ(nvrm_mem_write(m, 5, buf, 4096), NVRM_OK);
	CHECK_EQ(nvrm_mem_read(m, 5, back, 4096), NVRM_OK);
	CHECK(memcmp(buf, back, 4096) == 0);
	CHECK(memcmp((char *)addr + 5, buf, 4096) == 0);	/* a raw pointer sees them too */
	CHECK_EQ(nvrm_mem_write(m, 8192, buf, 1), NVRM_E_RANGE);
	CHECK_EQ(nvrm_mem_write(m, 8190, buf, 3), NVRM_E_RANGE);
	CHECK_EQ(nvrm_mem_write(m, UINT64_MAX, buf, 1), NVRM_E_RANGE);
	CHECK_EQ(nvrm_mem_read(m, 8191, back, 1), NVRM_OK);
	CHECK_EQ(nvrm_mem_read(m, 8192, back, 0), NVRM_OK);
	/* the GPU sees what the CPU wrote */
	va = reserve(cl, 1 * MiB, 0, 0);
	CHECK_EQ(map_gpu(m, va, 0, 0, 0), NVRM_OK);
	CHECK_EQ(nvrm_fake_gpu_access(cl, va + 5, back, 4096, 0), 0);
	CHECK(memcmp(buf, back, 4096) == 0);
	CHECK_EQ(nvrm_mem_unmap_cpu(m), NVRM_OK);
	CHECK_EQ(nvrm_mem_unmap_cpu(m), NVRM_E_INVAL);
	stats_get(cl, &st);
	CHECK_EQ(st.live_cpu_maps, 0);
	/* a read-only mapping refuses the write accessor, a write-only the read */
	CHECK_EQ(nvrm_mem_map_cpu(m, NVRM_CPU_READ, &addr), NVRM_OK);
	CHECK_EQ(nvrm_mem_write(m, 0, buf, 1), NVRM_E_DENIED);
	CHECK_EQ(nvrm_mem_read(m, 0, back, 1), NVRM_OK);
	nvrm_mem_unmap_cpu(m);
	CHECK_EQ(nvrm_mem_map_cpu(m, NVRM_CPU_WRITE, &addr), NVRM_OK);
	CHECK_EQ(nvrm_mem_read(m, 0, back, 1), NVRM_E_DENIED);
	nvrm_mem_free(m);	/* freed while mapped: the mapping and the GPU map go too */
	stats_get(cl, &st);
	CHECK_EQ(st.live_cpu_maps, 0);
	CHECK_EQ(st.live_gpu_maps, 0);

	/* two descriptors were pre-opened (map_slots 2): a third mapping is opened on
	 * demand when the process is not in capability mode, and refused when it is */
	m = alloc_mem(cl, NVRM_MEM_SYSMEM, 4096, 0);
	m2 = alloc_mem(cl, NVRM_MEM_SYSMEM, 4096, 0);
	m3 = alloc_mem(cl, NVRM_MEM_SYSMEM, 4096, 0);
	CHECK_EQ(nvrm_mem_map_cpu(m, NVRM_CPU_READ, &addr), NVRM_OK);
	CHECK_EQ(nvrm_mem_map_cpu(m2, NVRM_CPU_READ, &addr), NVRM_OK);
	stats_get(cl, &st);
	CHECK_EQ(st.spare_descriptors, 1);	/* only the export one is left */
	CHECK_EQ(nvrm_mem_map_cpu(m3, NVRM_CPU_READ, &addr), NVRM_OK);	/* opened on demand */
	nvrm_mem_unmap_cpu(m3);
	capmode = 1;
	nvrm_capmode_hook = hook_capmode;
	CHECK_EQ(nvrm_mem_map_cpu(m3, NVRM_CPU_READ, &addr), NVRM_E_NOSLOT);
	CHECK(strstr(nvrm_client_errmsg(cl), "raise nvrm_open_opts.map_slots") != NULL);
	CHECK(strstr(nvrm_client_errmsg(cl), "capability mode") != NULL);
	capmode = 0;
	nvrm_capmode_hook = NULL;
	nvrm_mem_free(m);
	nvrm_mem_free(m2);
	nvrm_mem_free(m3);

	/* a failed mapping consumes its descriptor and leaves the object unmapped */
	m = alloc_mem(cl, NVRM_MEM_SYSMEM, 4096, 0);
	nvrm_fake_mem_fail(NVRM_FAKE_OP_MAP_CPU, 1);
	CHECK_EQ(nvrm_mem_map_cpu(m, NVRM_CPU_READ, &addr), NVRM_E_RM);
	nvrm_mem_info_get(m, &mi);
	CHECK_EQ(mi.cpu_mapped, 0);
	nvrm_mem_free(m);
	nvrm_client_close(cl);

	/* the same with an on-demand descriptor that cannot be opened */
	cl = open_client(NVRM_OPEN_ALLOW_MAP, 1, 1);
	m = alloc_mem(cl, NVRM_MEM_SYSMEM, 4096, 0);
	CHECK_EQ(nvrm_mem_map_cpu(m, NVRM_CPU_READ, &addr), NVRM_OK);
	nvrm_mem_unmap_cpu(m);			/* the descriptor is gone: single use */
	nvrm_fake_mem_fail(NVRM_FAKE_OP_DESC, 1);
	CHECK_EQ(nvrm_mem_map_cpu(m, NVRM_CPU_READ, &addr), NVRM_E_RM);
	nvrm_mem_free(m);
	nvrm_client_close(cl);

	/* the fake's own mmap can fail: with the address space limited */
	cl = open_client(NVRM_OPEN_ALLOW_MAP, 1, 1);
	{
		struct rlimit old, lim;
		struct kinfo_proc kp;
		size_t len = sizeof(kp);
		int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid() };

		m = alloc_mem(cl, NVRM_MEM_SYSMEM, 128 * MiB, 0);
		CHECK_EQ(sysctl(mib, 4, &kp, &len, NULL, 0), 0);
		getrlimit(RLIMIT_AS, &old);
		lim = old;
		lim.rlim_cur = kp.ki_size + 2 * MiB;
		CHECK_EQ(setrlimit(RLIMIT_AS, &lim), 0);
		n = nvrm_mem_map_cpu(m, NVRM_CPU_READ, &addr);
		setrlimit(RLIMIT_AS, &old);
		CHECK_EQ(n, NVRM_E_IO);
		CHECK(strstr(nvrm_client_errmsg(cl), "mmap failed") != NULL);
		nvrm_mem_free(m);
	}
	nvrm_client_close(cl);
	/* a descriptor the fake cannot limit */
	nvrm_fake_mem_fail(NVRM_FAKE_OP_LIMIT, 1);
	{
		nvrm_open_opts o = { 0, NVRM_OPEN_ALLOW_MAP, 1, 1 };
		char err[100];

		CHECK_EQ(nvrm_client_open(nvrm_device_get(ctx, 0), &o, &cl, err,
		    sizeof(err)), NVRM_E_CAPSICUM);
	}
	teardown();
	expect_clean("cpu map");
}

static int refuse;

static int
hook_check(int a, const volatile void *p, unsigned w, int wr)
{
	(void)a; (void)p; (void)w; (void)wr;
	return (refuse ? -1 : 0);
}

/* The rule on an arm64 host with the Altra fallback: Device memory.  Every
 * access the library makes is aligned and at most 8 bytes wide, for every
 * start and every length, and the fake checks each one the way the hardware
 * would. */
static void
test_device_attr(void)
{
	nvrm_client *cl;
	nvrm_mem *m;
	nvrm_mem_info mi = { sizeof(mi) };
	nvrm_fake_mem_stats before, after;
	uint8_t src[40], dst[40];
	void *addr;
	unsigned off, len;
	int bad = 0;

	/* on arm64: the unified GPU's VRAM is system memory, so cached, whatever
	 * os_device_wc_active says; the discrete GPU's VRAM is a BAR, and its
	 * profile does not report the flag, so Device */
	setup("unified", "arm64");
	cl = open_client(NVRM_OPEN_ALLOW_MAP, 1, 1);
	m = alloc_mem(cl, NVRM_MEM_VRAM, 4096, 0);
	nvrm_mem_info_get(m, &mi);
	/* the unified GPU has no video memory: its VRAM is system memory, cached */
	CHECK_EQ(mi.cpu_attr, NVRM_ATTR_CACHED);
	nvrm_mem_free(m);
	nvrm_client_close(cl);
	teardown();

	setup("discrete", "arm64");
	cl = open_client(NVRM_OPEN_ALLOW_MAP, 1, 1);
	m = alloc_mem(cl, NVRM_MEM_VRAM, 4096, 0);
	nvrm_mem_info_get(m, &mi);
	CHECK_EQ(mi.place, NVRM_PLACE_VIDMEM);
	CHECK_EQ(mi.cpu_attr, NVRM_ATTR_DEVICE);
	CHECK_EQ(nvrm_mem_map_cpu(m, NVRM_CPU_READ | NVRM_CPU_WRITE, &addr), NVRM_OK);
	before = bstats();
	for (off = 0; off < 17; off++)
		for (len = 0; len < 33; len++) {
			fill(src, len, off * 7 + len);
			memset(dst, 0, sizeof(dst));
			if (nvrm_mem_write(m, 100 + off, src, len) != NVRM_OK ||
			    nvrm_mem_read(m, 100 + off, dst, len) != NVRM_OK ||
			    memcmp(src, dst, len) != 0)
				bad++;
		}
	after = bstats();
	CHECK_EQ(bad, 0);
	CHECK_EQ(after.traps, before.traps);
	CHECK(after.checked > before.checked + 1000);
	/* the check itself can fail: an unaligned or odd-width primitive access is trapped,
	 * a cached or write-combined one is never checked against the rule */
	CHECK_EQ(nvrm_fake_mem_ops.cpu_access(NVRM_ATTR_DEVICE, (void *)((uintptr_t)addr + 2), 4, 0), -1);
	CHECK_EQ(nvrm_fake_mem_ops.cpu_access(NVRM_ATTR_DEVICE, (void *)((uintptr_t)addr + 1), 2, 1), -1);
	CHECK_EQ(nvrm_fake_mem_ops.cpu_access(NVRM_ATTR_DEVICE, addr, 3, 0), -1);
	CHECK_EQ(nvrm_fake_mem_ops.cpu_access(NVRM_ATTR_DEVICE, addr, 16, 0), -1);
	CHECK_EQ(nvrm_fake_mem_ops.cpu_access(NVRM_ATTR_DEVICE, addr, 0, 0), -1);
	CHECK_EQ(nvrm_fake_mem_ops.cpu_access(NVRM_ATTR_DEVICE, addr, 8, 0), 0);
	CHECK_EQ(nvrm_fake_mem_ops.cpu_access(NVRM_ATTR_WC, (void *)((uintptr_t)addr + 1), 8, 0), 0);
	CHECK_EQ(bstats().traps, after.traps + 5);
	/* an access the trap refuses is an error of the call, with the reason */
	{
		static nvrm_mem_ops patched;

		patched = *cl->mops;
		patched.cpu_access = hook_check;
		cl->mops = &patched;
		refuse = 1;
		CHECK_EQ(nvrm_mem_write(m, 0, src, 8), NVRM_E_INVAL);
		CHECK(strstr(nvrm_client_errmsg(cl), "trapped") != NULL);
		refuse = 0;
		patched.cpu_access = NULL;
		CHECK_EQ(nvrm_mem_write(m, 0, src, 8), NVRM_OK);	/* a backend with no check */
		cl->mops = &nvrm_fake_mem_ops;
	}
	nvrm_mem_free(m);
	nvrm_client_close(cl);
	teardown();

	/* amd64 host, and arm64 where write-combining is Normal memory: unaligned is fine */
	setup("discrete", "amd64");
	cl = open_client(NVRM_OPEN_ALLOW_MAP, 1, 1);
	m = alloc_mem(cl, NVRM_MEM_VRAM, 4096, 0);
	nvrm_mem_info_get(m, &mi);
	CHECK_EQ(mi.cpu_attr, NVRM_ATTR_WC);
	nvrm_mem_free(m);
	nvrm_client_close(cl);
	teardown();
	/* the compiled-in default of the host when nothing says otherwise */
	setup("discrete", NULL);
	cl = open_client(0, 0, 0);
	m = alloc_mem(cl, NVRM_MEM_VRAM, 4096, 0);
	nvrm_mem_info_get(m, &mi);
#ifdef __aarch64__
	CHECK_EQ(mi.cpu_attr, NVRM_ATTR_DEVICE);
#else
	CHECK_EQ(mi.cpu_attr, NVRM_ATTR_WC);
#endif
	nvrm_mem_free(m);
	nvrm_client_close(cl);
	teardown();
}

/* ---- read-back ------------------------------------------------------------ */

/* The acceptance read-back: 1 MiB of a pseudo-random pattern into video
 * memory and into system memory by the CPU, read back by the CPU and by the
 * GPU model through its VA mapping, and the other way round. */
static void
test_readback(void)
{
	static const struct { int kind; const char *profile; } cases[] = {
		{ NVRM_MEM_VRAM, "discrete" },
		{ NVRM_MEM_SYSMEM, "discrete" },
		{ NVRM_MEM_VRAM, "unified" },
	};
	static const char *hosts[] = { "amd64", "arm64" };
	nvrm_client *cl;
	nvrm_mem *m;
	uint8_t *want = malloc(1 * MiB), *got = malloc(1 * MiB);
	uint64_t va, traps0 = bstats().traps;
	unsigned c, h;

	for (h = 0; h < 2; h++)
		for (c = 0; c < 3; c++) {
			setup(cases[c].profile, hosts[h]);
			cl = open_client(NVRM_OPEN_ALLOW_MAP, 0, 0);
			m = alloc_mem(cl, cases[c].kind, 1 * MiB, 64 * KiB);
			va = reserve(cl, 4 * MiB, 0, 0);
			CHECK_EQ(map_gpu(m, va + 1 * MiB, 0, 0, 0), NVRM_OK);
			CHECK_EQ(nvrm_mem_map_cpu(m, NVRM_CPU_READ | NVRM_CPU_WRITE,
			    (void *[]){ NULL }), NVRM_OK);
			/* CPU writes, CPU and GPU read */
			fill(want, 1 * MiB, 21 + c);
			CHECK_EQ(nvrm_mem_write(m, 0, want, 1 * MiB), NVRM_OK);
			memset(got, 0, 1 * MiB);
			CHECK_EQ(nvrm_mem_read(m, 0, got, 1 * MiB), NVRM_OK);
			CHECK(memcmp(want, got, 1 * MiB) == 0);
			memset(got, 0, 1 * MiB);
			CHECK_EQ(nvrm_fake_gpu_access(cl, va + 1 * MiB, got, 1 * MiB, 0), 0);
			CHECK(memcmp(want, got, 1 * MiB) == 0);
			/* GPU writes, CPU reads */
			fill(want, 1 * MiB, 90 + c);
			CHECK_EQ(nvrm_fake_gpu_access(cl, va + 1 * MiB, want, 1 * MiB, 1), 0);
			memset(got, 0, 1 * MiB);
			CHECK_EQ(nvrm_mem_read(m, 0, got, 1 * MiB), NVRM_OK);
			CHECK(memcmp(want, got, 1 * MiB) == 0);
			nvrm_mem_free(m);
			nvrm_client_close(cl);
			teardown();
		}
	CHECK_EQ(bstats().traps, traps0);
	free(want);
	free(got);
	expect_clean("readback");
}

/* ---- the 100k loop ---------------------------------------------------------- */

static void
test_loop(void)
{
	nvrm_client *cl;
	nvrm_mem *m;
	nvrm_client_stats st = { sizeof(st) };
	nvrm_fake_mem_stats b0, b1;
	nvrm_gpu_map_params gp;
	uint64_t va;
	unsigned i;
	int bad = 0;

	setup("discrete", NULL);
	cl = open_client(0, 0, 0);
	va = reserve(cl, 4 * MiB, 0, 0);
	b0 = bstats();
	for (i = 0; i < 100000; i++) {
		nvrm_mem_params p = { 0, i % 2 ? NVRM_MEM_VRAM : NVRM_MEM_SYSMEM,
		    0, 0, 4096 * (1 + i % 16), 0, 0 };

		if (nvrm_mem_alloc(cl, &p, &m) != NVRM_OK) {
			bad++;
			break;
		}
		if (i % 4 == 0) {
			gp = (nvrm_gpu_map_params){ 0, 0, va, 0, 0 };
			bad += nvrm_mem_map_gpu(m, &gp) != NVRM_OK;
		}
		nvrm_mem_free(m);
	}
	CHECK_EQ(bad, 0);
	stats_get(cl, &st);
	CHECK_EQ(st.allocs, 100000);
	CHECK_EQ(st.frees, 100000);
	CHECK(st.live_mem == 0 && st.live_bytes == 0 && st.live_gpu_maps == 0);
	b1 = bstats();
	CHECK_EQ(b1.objects, b0.objects);
	CHECK_EQ(b1.gpu_maps, 0);
	CHECK_EQ(b1.vram_free, b0.vram_free);
	CHECK_EQ(b1.sys_free, b0.sys_free);
	CHECK_EQ(b1.vram_extents, 1);
	CHECK_EQ(b1.sys_extents, 1);
	nvrm_client_close(cl);
	teardown();
	expect_clean("loop");
}

/* ---- sharing ------------------------------------------------------------- */

/* #lizard forgives -- one scripted scenario, steps share state; split tracked as DEBT on #2419 */
static void
test_share(void)
{
	nvrm_client *a, *b;
	nvrm_mem *m, *im;
	nvrm_mem_info mi = { sizeof(mi) };
	uint8_t buf[4096], back[4096];
	cap_rights_t rights;
	nvrm_open_opts o = { 0, NVRM_OPEN_ALLOW_MAP, 0, 0 };
	char err[100];
	void *addr;
	int fd, p[2], n;

	setup("discrete", "amd64");
	CHECK_EQ(nvrm_client_open(nvrm_device_get(ctx, 0), &o, &a, err, sizeof(err)), NVRM_OK);
	CHECK_EQ(nvrm_client_open(nvrm_device_get(ctx, 0), &o, &b, err, sizeof(err)), NVRM_OK);
	m = alloc_mem(a, NVRM_MEM_VRAM, 64 * KiB, 64 * KiB);
	CHECK_EQ(nvrm_mem_map_cpu(m, NVRM_CPU_READ | NVRM_CPU_WRITE, &addr), NVRM_OK);
	fill(buf, sizeof(buf), 5);
	CHECK_EQ(nvrm_mem_write(m, 4096, buf, sizeof(buf)), NVRM_OK);
	CHECK_EQ(nvrm_mem_export_fd(m, &fd), NVRM_OK);
	/* the descriptor can only be read */
	CHECK_EQ(cap_rights_get(fd, &rights), 0);
	CHECK(cap_rights_is_set(&rights, CAP_READ));
	CHECK(!cap_rights_is_set(&rights, CAP_WRITE));
	CHECK(!cap_rights_is_set(&rights, CAP_IOCTL));
	CHECK(!cap_rights_is_set(&rights, CAP_MMAP_RW));
	/* the other client imports it and sees the same memory */
	CHECK_EQ(nvrm_mem_import_fd(b, fd, &im), NVRM_OK);
	CHECK_EQ(nvrm_mem_info_get(im, &mi), NVRM_OK);
	CHECK_EQ(mi.kind, NVRM_MEM_IMPORTED);
	CHECK_EQ(mi.place, NVRM_PLACE_VIDMEM);
	CHECK_EQ(mi.bytes, 64 * KiB);
	CHECK_EQ(mi.page_size, 64 * KiB);
	CHECK_EQ(nvrm_mem_map_cpu(im, NVRM_CPU_READ, &addr), NVRM_OK);
	CHECK_EQ(nvrm_mem_read(im, 4096, back, sizeof(back)), NVRM_OK);
	CHECK(memcmp(buf, back, sizeof(buf)) == 0);
	/* importing again gives another object on the same memory */
	{
		nvrm_mem *im2;

		CHECK_EQ(nvrm_mem_import_fd(b, fd, &im2), NVRM_OK);
		nvrm_mem_free(im2);
	}
	/* the exporter may free its object: the memory lives while an import does */
	nvrm_mem_free(m);
	CHECK_EQ(nvrm_mem_read(im, 4096, back, sizeof(back)), NVRM_OK);
	CHECK(memcmp(buf, back, sizeof(buf)) == 0);
	nvrm_mem_free(im);
	close(fd);
	/* not an export descriptor */
	CHECK_EQ(pipe(p), 0);
	CHECK_EQ(nvrm_mem_import_fd(b, p[0], &im), NVRM_E_RM);
	CHECK(strstr(nvrm_client_errmsg(b), "not an export") != NULL);
	{
		/* a record that names no object (the exporter's client is closed) */
		nvrm_mem *m2;
		int fd2;

		m2 = alloc_mem(a, NVRM_MEM_SYSMEM, 4096, 0);
		CHECK_EQ(nvrm_mem_export_fd(m2, &fd2), NVRM_OK);
		nvrm_mem_free(m2);
		nvrm_client_close(a);	/* drops the export's hold */
		a = NULL;
		CHECK_EQ(nvrm_mem_import_fd(b, fd2, &im), NVRM_E_RM);
		CHECK(strstr(nvrm_client_errmsg(b), "gone") != NULL);
		close(fd2);
	}
	close(p[0]);
	close(p[1]);
	nvrm_client_close(b);
	teardown();
	expect_clean("share");

	/* a record for another GPU is refused */
	setup("discrete,unified", "amd64");
	{
		nvrm_client *c1, *c2;
		nvrm_mem *m1;
		int f;

		CHECK_EQ(nvrm_client_open(nvrm_device_get(ctx, 0), NULL, &c1, err, sizeof(err)), NVRM_OK);
		CHECK_EQ(nvrm_client_open(nvrm_device_get(ctx, 1), NULL, &c2, err, sizeof(err)), NVRM_OK);
		m1 = alloc_mem(c1, NVRM_MEM_SYSMEM, 4096, 0);
		CHECK_EQ(nvrm_mem_export_fd(m1, &f), NVRM_OK);
		CHECK_EQ(nvrm_mem_import_fd(c2, f, &im), NVRM_E_RM);
		CHECK(strstr(nvrm_client_errmsg(c2), "not on this GPU") != NULL);
		close(f);
		nvrm_mem_free(m1);
		nvrm_client_close(c1);
		nvrm_client_close(c2);
	}
	teardown();

	/* failures: the backend's, the descriptors', allocation */
	setup("discrete", "amd64");
	b = open_client(0, 0, 2);
	m = alloc_mem(b, NVRM_MEM_SYSMEM, 4096, 0);
	nvrm_fake_mem_fail(NVRM_FAKE_OP_EXPORT, 1);
	CHECK_EQ(nvrm_mem_export_fd(m, &fd), NVRM_E_RM);
	nvrm_fake_mem_fail(NVRM_FAKE_OP_IMPORT, 1);
	CHECK_EQ(nvrm_mem_export_fd(m, &fd), NVRM_OK);
	CHECK_EQ(nvrm_mem_import_fd(b, fd, &im), NVRM_E_RM);
	for (n = 1; n < 10; n++) {
		fail_calloc_at(n);
		if (nvrm_mem_import_fd(b, fd, &im) == NVRM_OK) {
			fail_calloc_at(0);
			nvrm_mem_free(im);
			break;
		}
		fail_calloc_at(0);
	}
	CHECK(n > 1 && n < 10);
	close(fd);
	/* the export's own bookkeeping cannot allocate */
	fail_calloc_at(1);
	CHECK_EQ(nvrm_mem_export_fd(m, &fd), NVRM_E_NOMEM);
	fail_calloc_at(0);
	/* two exports, so the list grows past one entry */
	CHECK_EQ(nvrm_mem_export_fd(m, &fd), NVRM_OK);
	close(fd);
	/* the descriptors: export slots are single use (2 here) */
	{
		nvrm_client_stats st = { sizeof(st) };

		stats_get(b, &st);
		CHECK_EQ(st.spare_descriptors, 0);
	}
	nvrm_mem_free(m);
	nvrm_client_close(b);
	teardown();
	expect_clean("share failures");
}

/* ---- the device interplay of the fake itself -------------------------------- */

static void
test_fake_device(void)
{
	nvrm_client *c1, *c2;
	struct rlimit old, lim;
	nvrm_open_opts o = { 0, 0, 0, 1 };
	char err[200];
	int fd, probe, n;

	setup("discrete,discrete", NULL);
	/* two clients on one GPU share the aperture; a client on another GPU does not */
	CHECK_EQ(nvrm_client_open(nvrm_device_get(ctx, 0), NULL, &c1, err, sizeof(err)), NVRM_OK);
	CHECK_EQ(nvrm_client_open(nvrm_device_get(ctx, 0), NULL, &c2, err, sizeof(err)), NVRM_OK);
	CHECK_EQ(bstats().clients, 2);
	nvrm_client_close(c1);
	nvrm_client_close(c2);
	CHECK_EQ(nvrm_client_open(nvrm_device_get(ctx, 0), NULL, &c1, err, sizeof(err)), NVRM_OK);
	CHECK_EQ(nvrm_client_open(nvrm_device_get(ctx, 1), NULL, &c2, err, sizeof(err)), NVRM_OK);
	nvrm_client_close(c1);
	nvrm_client_close(c2);
	/* the aperture cannot be made when the process has no descriptor to spare */
	probe = open("/dev/null", O_RDONLY);
	getrlimit(RLIMIT_NOFILE, &old);
	lim = old;
	lim.rlim_cur = probe;
	CHECK_EQ(setrlimit(RLIMIT_NOFILE, &lim), 0);
	CHECK_EQ(nvrm_client_open(nvrm_device_get(ctx, 0), NULL, &c1, err, sizeof(err)), NVRM_E_IO);
	CHECK(strstr(err, "cannot make the aperture") != NULL);
	setrlimit(RLIMIT_NOFILE, &old);
	close(probe);
	/* ... or sized */
	nvrm_fake_mem_fail(NVRM_FAKE_OP_APERTURE_SIZE, 1);
	CHECK_EQ(nvrm_client_open(nvrm_device_get(ctx, 0), NULL, &c1, err, sizeof(err)), NVRM_E_IO);
	CHECK(strstr(err, "cannot size the aperture") != NULL);
	expect_clean("aperture size");
	/* an export descriptor that cannot be sized, with the aperture in place */
	nvrm_fake_mem_fail(NVRM_FAKE_OP_DESC_SIZE, 1);
	CHECK_EQ(nvrm_client_open(nvrm_device_get(ctx, 0), &o, &c1, err, sizeof(err)), NVRM_E_IO);
	CHECK(strstr(err, "cannot size a spare") != NULL);
	expect_clean("descriptor size");
	nvrm_fake_mem_fail_clear();
	CHECK_EQ(nvrm_client_open(nvrm_device_get(ctx, 0), &o, &c1, err, sizeof(err)), NVRM_OK);
	nvrm_client_close(c1);
	/* an export descriptor made when descriptors run out */
	CHECK_EQ(nvrm_client_open(nvrm_device_get(ctx, 0), NULL, &c1, err, sizeof(err)), NVRM_OK);
	probe = open("/dev/null", O_RDONLY);
	getrlimit(RLIMIT_NOFILE, &old);
	lim = old;
	lim.rlim_cur = probe;
	CHECK_EQ(setrlimit(RLIMIT_NOFILE, &lim), 0);
	{
		nvrm_mem *m = NULL;
		nvrm_mem_params p = { 0, NVRM_MEM_SYSMEM, 0, 0, 4096, 0, 0 };

		CHECK_EQ(nvrm_mem_alloc(c1, &p, &m), NVRM_OK);
		int held[NVRM_EXPORT_SLOTS_DEFAULT];

		for (n = 0; n < NVRM_EXPORT_SLOTS_DEFAULT; n++)
			CHECK_EQ(nvrm_mem_export_fd(m, &held[n]), NVRM_OK);
		/* the pool is empty: the on-demand open has no descriptor to use */
		CHECK_EQ(nvrm_mem_export_fd(m, &fd), NVRM_E_IO);
		CHECK(strstr(nvrm_client_errmsg(c1), "spare descriptor") != NULL);
		for (n = 0; n < NVRM_EXPORT_SLOTS_DEFAULT; n++)
			close(held[n]);
		nvrm_mem_free(m);
	}
	setrlimit(RLIMIT_NOFILE, &old);
	close(probe);
	nvrm_client_close(c1);
	teardown();
	expect_clean("fake device");
}


/* ---- cases that close the remaining branches ------------------------------- */

static void
test_va_gaps(void)
{
	nvrm_va *va = nvrm_va_new(0x1000, 0x5000);
	uint64_t a;

	/* a fully used space has no extent: a free then finds the end of the list */
	CHECK_EQ(nvrm_va_alloc(va, 0x4000, 0x1000, 1, 0x1000, &a), NVRM_OK);
	CHECK_EQ(nvrm_va_extents(va), 0);
	CHECK_EQ(nvrm_va_free(va, 0x2000, 0x1000), NVRM_OK);
	/* it extends the last extent when nothing follows it */
	CHECK_EQ(nvrm_va_free(va, 0x3000, 0x1000), NVRM_OK);
	CHECK_EQ(nvrm_va_extents(va), 1);
	/* it starts a new one after the last, not touching */
	CHECK_EQ(nvrm_va_free(va, 0x4800, 0x100), NVRM_OK);
	CHECK_EQ(nvrm_va_extents(va), 2);
	nvrm_va_destroy(va);
}

/* #lizard forgives -- one scripted scenario, steps share state; split tracked as DEBT on #2419 */
static void
test_gaps(void)
{
	nvrm_client *cl, *cl2;
	nvrm_mem *m, *m2;
	nvrm_mem_params mp;
	nvrm_va_params vp;
	nvrm_gpu_map_params gp;
	nvrm_device *d;
	nvrm_open_opts oo = { 0, 0x80, 0, 0 };
	nvrm_fake_mem_stats st;
	uint64_t va, va2, vb;
	uint8_t buf[64];
	char err[100];
	int fd, zfd;

	setup("discrete,unified", "amd64");
	d = nvrm_device_get(ctx, 0);
	/* an error buffer of no length is accepted */
	cl = NULL;
	CHECK_EQ(nvrm_client_open(d, &oo, &cl, err, 0), NVRM_E_INVAL);
	cl = open_client(NVRM_OPEN_ALLOW_MAP, 1, 1);
	/* parameter structures that carry their own size */
	vp = (nvrm_va_params){ sizeof(vp), 0, 1 * MiB, 0, 0 };
	CHECK_EQ(nvrm_va_reserve(cl, &vp, &va), NVRM_OK);
	vp = (nvrm_va_params){ sizeof(vp), 0, 1 * MiB, 0, 0 };
	CHECK_EQ(nvrm_va_reserve(cl, &vp, &va2), NVRM_OK);
	mp = (nvrm_mem_params){ sizeof(mp), NVRM_MEM_SYSMEM, 0, 0, 4096, 0, 0 };
	CHECK_EQ(nvrm_mem_alloc(cl, &mp, &m), NVRM_OK);
	gp = (nvrm_gpu_map_params){ sizeof(gp), 0, va, 0, 0 };
	CHECK_EQ(nvrm_mem_map_gpu(m, &gp), NVRM_OK);
	/* an address below every reservation */
	m2 = alloc_mem(cl, NVRM_MEM_SYSMEM, 4096, 0);
	CHECK_EQ(map_gpu(m2, va - 4096, 0, 0, 0), NVRM_E_RANGE);
	CHECK_EQ(map_gpu(m2, va2 + 1 * MiB, 0, 0, 0), NVRM_E_RANGE);
	/* a client closed with objects, mappings, reservations and a CPU map in it */
	CHECK_EQ(nvrm_mem_map_cpu(m2, NVRM_CPU_READ, (void *[]){ NULL }), NVRM_OK);
	nvrm_client_close(cl);
	expect_clean("close with live objects");

	/* the export pool, in capability mode, with none left */
	cl = open_client(0, 0, 1);
	m = alloc_mem(cl, NVRM_MEM_SYSMEM, 4096, 0);
	CHECK_EQ(nvrm_mem_export_fd(m, &fd), NVRM_OK);
	close(fd);
	capmode = 1;
	nvrm_capmode_hook = hook_capmode;
	CHECK_EQ(nvrm_mem_export_fd(m, &fd), NVRM_E_NOSLOT);
	CHECK(strstr(nvrm_client_errmsg(cl), "raise nvrm_open_opts.export_slots") != NULL);
	CHECK(strstr(nvrm_client_errmsg(cl), "export") != NULL);
	nvrm_capmode_hook = NULL;
	capmode = 0;
	nvrm_mem_free(m);
	nvrm_client_close(cl);

	/* a descriptor that is not an export record: right size, wrong content */
	cl = open_client(0, 0, 0);
	zfd = shm_open(SHM_ANON, O_RDWR, 0600);
	CHECK_EQ(ftruncate(zfd, 4096), 0);
	memset(buf, 0, sizeof(buf));
	CHECK_EQ(write(zfd, buf, sizeof(buf)), (ssize_t)sizeof(buf));
	CHECK_EQ(nvrm_mem_import_fd(cl, zfd, &m), NVRM_E_RM);
	CHECK(strstr(nvrm_client_errmsg(cl), "not an export") != NULL);
	close(zfd);
	/* an import finds its object when it is not the first in the device's list */
	m = alloc_mem(cl, NVRM_MEM_SYSMEM, 4096, 0);
	m2 = alloc_mem(cl, NVRM_MEM_SYSMEM, 4096, 0);
	{
		nvrm_mem *m3, *im;

		m3 = alloc_mem(cl, NVRM_MEM_SYSMEM, 4096, 0);
		CHECK_EQ(nvrm_mem_export_fd(m, &fd), NVRM_OK);	/* the oldest object */
		CHECK_EQ(nvrm_mem_import_fd(cl, fd, &im), NVRM_OK);
		nvrm_mem_free(im);
		close(fd);
		nvrm_mem_free(m3);
	}
	/* write and rights failures of the export, with the slot consumed and nothing held */
	nvrm_fake_mem_fail(NVRM_FAKE_OP_WRITE, 1);
	CHECK_EQ(nvrm_mem_export_fd(m, &fd), NVRM_E_IO);
	nvrm_fake_mem_fail(NVRM_FAKE_OP_RIGHTS, 1);
	CHECK_EQ(nvrm_mem_export_fd(m, &fd), NVRM_E_CAPSICUM);
	nvrm_mem_free(m);
	nvrm_mem_free(m2);
	nvrm_client_close(cl);

	/* a hole of a sparse reservation next to a mapping of another one */
	cl = open_client(0, 0, 0);
	va = reserve(cl, 1 * MiB, NVRM_VA_SPARSE, 0);
	vb = reserve(cl, 1 * MiB, 0, 0);
	m = alloc_mem(cl, NVRM_MEM_SYSMEM, 4096, 0);
	CHECK_EQ(map_gpu(m, vb + 4096, 0, 0, 0), NVRM_OK);
	memset(buf, 0xee, sizeof(buf));
	CHECK_EQ(nvrm_fake_gpu_access(cl, va, buf, sizeof(buf), 0), 0);
	CHECK_EQ(buf[0], 0);
	nvrm_mem_free(m);
	nvrm_client_close(cl);

	/* the backend's counters with a GPU that has no video memory in it */
	CHECK_EQ(nvrm_client_open(nvrm_device_get(ctx, 1), NULL, &cl2, err, sizeof(err)), NVRM_OK);
	st = bstats();
	CHECK_EQ(st.vram_extents, 0);
	nvrm_client_close(cl2);
	/* an unknown host name falls back to the compiled-in one */
	setenv("NVRM_FAKE_HOST", "riscv", 1);
	cl = open_client(0, 0, 0);
	nvrm_client_close(cl);
	/* the descriptor limit helper on a descriptor that cannot widen */
	{
		cap_rights_t r;
		int p2[2];

		CHECK_EQ(pipe(p2), 0);
		cap_rights_init(&r, CAP_READ);
		CHECK_EQ(cap_rights_limit(p2[0], &r), 0);
		CHECK_EQ(nvrm_cap_limit_desc(p2[0], NVRM_DESC_MAP), NVRM_E_CAPSICUM);
		CHECK_EQ(nvrm_cap_limit_desc(p2[0], NVRM_DESC_EXPORT), NVRM_OK);
		close(p2[0]);
		close(p2[1]);
	}
	teardown();
	expect_clean("gaps");
}

/* ---- the main program -------------------------------------------------------- */

/* ---- releases the RM refuses ---------------------------------------------- */

static uint64_t
failed_releases(nvrm_client *cl)
{
	nvrm_client_stats st = { 0 };

	CHECK_EQ(stats_get(cl, &st), NVRM_OK);
	return (st.failed_releases);
}

/* #lizard forgives -- one scripted scenario, steps share state; split tracked as DEBT on #2419 */
static void
test_release_failures(void)
{
	nvrm_client *cl;
	nvrm_client_stats st = { 0 };
	nvrm_mem_info mi = { 0 };
	nvrm_va_params p;
	nvrm_mem *m, *m2, *m3;
	uint64_t va, va2, got;
	void *cpu;

	setup("discrete", NULL);
	cl = open_client(NVRM_OPEN_ALLOW_MAP, 2, 0);
	va = reserve(cl, 1 * MiB, 0, 0);
	m = alloc_mem(cl, NVRM_MEM_SYSMEM, 64 * KiB, 64 * KiB);
	CHECK_EQ(map_gpu(m, va, 0, 0, 0), NVRM_OK);
	/* an unmap the RM refuses: the mapping stays, and a retry works */
	nvrm_fake_mem_fail(NVRM_FAKE_OP_UNMAP_GPU, 1);
	CHECK_EQ(nvrm_mem_unmap_gpu(m, va), NVRM_E_RM);
	CHECK(strstr(nvrm_client_errmsg(cl), "injected") != NULL);
	CHECK_EQ(failed_releases(cl), 1);
	stats_get(cl, &st);
	CHECK_EQ(st.live_gpu_maps, 1);
	CHECK_EQ(map_gpu(m, va, 0, 0, 0), NVRM_E_RANGE);
	CHECK_EQ(nvrm_mem_unmap_gpu(m, va), NVRM_OK);
	stats_get(cl, &st);
	CHECK_EQ(st.live_gpu_maps, 0);
	/* a reservation release the RM refuses: it stays, its addresses are
	 * not handed out again, and a retry works */
	nvrm_fake_mem_fail(NVRM_FAKE_OP_VA_RELEASE, 1);
	CHECK_EQ(nvrm_va_release(cl, va), NVRM_E_RM);
	CHECK_EQ(failed_releases(cl), 2);
	stats_get(cl, &st);
	CHECK_EQ(st.live_reservations, 1);
	p = (nvrm_va_params){ 0, 0, 64 * KiB, 0, va };
	CHECK_EQ(nvrm_va_reserve(cl, &p, &got), NVRM_E_RANGE);
	CHECK_EQ(nvrm_va_release(cl, va), NVRM_OK);
	CHECK_EQ(nvrm_va_reserve(cl, &p, &got), NVRM_OK);
	CHECK_EQ(nvrm_va_release(cl, got), NVRM_OK);
	/* an unmap refused while the object is freed: the mapping is kept as
	 * an orphan, so its addresses stay out of use and the reservation busy */
	va2 = reserve(cl, 1 * MiB, 0, 0);
	CHECK_EQ(map_gpu(m, va2, 0, 0, 0), NVRM_OK);
	nvrm_fake_mem_fail(NVRM_FAKE_OP_UNMAP_GPU, 1);
	nvrm_mem_free(m);
	CHECK_EQ(failed_releases(cl), 3);
	stats_get(cl, &st);
	CHECK_EQ(st.live_gpu_maps, 0);
	CHECK_EQ(st.live_mem, 0);
	m2 = alloc_mem(cl, NVRM_MEM_SYSMEM, 64 * KiB, 64 * KiB);
	CHECK_EQ(map_gpu(m2, va2, 0, 0, 0), NVRM_E_RANGE);
	CHECK_EQ(map_gpu(m2, va2 + 64 * KiB, 0, 0, 0), NVRM_OK);
	CHECK_EQ(nvrm_mem_unmap_gpu(m2, va2 + 64 * KiB), NVRM_OK);
	CHECK_EQ(nvrm_va_release(cl, va2), NVRM_E_BUSY);
	CHECK(strstr(nvrm_client_errmsg(cl), "failed_releases") != NULL);
	/* a free the RM refuses: counted, the object stays with the client */
	nvrm_fake_mem_fail(NVRM_FAKE_OP_FREE, 1);
	nvrm_mem_free(m2);
	CHECK(strstr(nvrm_client_errmsg(cl), "injected") != NULL);
	CHECK_EQ(failed_releases(cl), 4);
	CHECK(bstats().objects >= 2);
	/* ... registered user pages too */
	{
		static char pages[2 * 65536] __attribute__((aligned(65536)));
		nvrm_mem *u = NULL;

		CHECK_EQ(nvrm_mem_register_user(cl, pages, 65536, &u), NVRM_OK);
		nvrm_fake_mem_fail(NVRM_FAKE_OP_FREE, 1);
		nvrm_mem_free(u);
		CHECK_EQ(failed_releases(cl), 5);
	}
	/* a CPU unmap the RM refuses: the CPU side is gone either way */
	m3 = alloc_mem(cl, NVRM_MEM_SYSMEM, 64 * KiB, 0);
	CHECK_EQ(nvrm_mem_map_cpu(m3, NVRM_CPU_READ | NVRM_CPU_WRITE, &cpu), NVRM_OK);
	nvrm_fake_mem_fail(NVRM_FAKE_OP_UNMAP_CPU, 1);
	CHECK_EQ(nvrm_mem_unmap_cpu(m3), NVRM_E_RM);
	CHECK_EQ(failed_releases(cl), 6);
	CHECK_EQ(nvrm_mem_info_get(m3, &mi), NVRM_OK);
	CHECK_EQ(mi.cpu_mapped, 0);
	stats_get(cl, &st);
	CHECK_EQ(st.live_cpu_maps, 0);
	/* ... and inside a free */
	CHECK_EQ(nvrm_mem_map_cpu(m3, NVRM_CPU_READ, &cpu), NVRM_OK);
	nvrm_fake_mem_fail(NVRM_FAKE_OP_UNMAP_CPU, 1);
	nvrm_mem_free(m3);
	CHECK_EQ(failed_releases(cl), 7);
	/* an object the core cannot record, whose free is refused as well */
	{
		nvrm_mem_params mp = { 0, NVRM_MEM_SYSMEM, 0, 0, 4096, 0, 0 };
		nvrm_mem *x = NULL;
		int n;

		for (n = 1; n < 10; n++) {
			fail_calloc_at(n);
			nvrm_fake_mem_fail(NVRM_FAKE_OP_FREE, 1);
			if (nvrm_mem_alloc(cl, &mp, &x) == NVRM_OK) {
				fail_calloc_at(0);
				nvrm_fake_mem_fail(NVRM_FAKE_OP_FREE, 0);
				nvrm_mem_free(x);
				break;
			}
			fail_calloc_at(0);
			CHECK(strstr(nvrm_client_errmsg(cl), "out of") != NULL);
		}
		CHECK(n > 2 && n < 10);
		CHECK(failed_releases(cl) >= 8);
	}
	/* the close releases what is left, a refusal among it: the fake, like
	 * the RM, frees the client with everything still in it */
	(void)reserve(cl, 64 * KiB, 0, 0);
	nvrm_fake_mem_fail(NVRM_FAKE_OP_VA_RELEASE, 1);
	nvrm_client_close(cl);
	expect_clean("release failures");
	teardown();
}

/* ---- page sizes the library picks ------------------------------------------ */

static void
test_default_page(void)
{
	nvrm_client *cl;
	nvrm_mem_info mi = { 0 };
	nvrm_mem *m;
	nvrm_fake_mem_stats b0, b1;
	nvrm_mem *a, *b;

	setup("discrete", NULL);
	cl = open_client(0, 0, 0);
	/* video memory of at least 64 KiB: 64 KiB pages; smaller: 4 KiB */
	m = alloc_mem(cl, NVRM_MEM_VRAM, 100 * KiB, 0);
	nvrm_mem_info_get(m, &mi);
	CHECK_EQ(mi.page_size, 64 * KiB);
	CHECK_EQ(mi.bytes, 128 * KiB);
	nvrm_mem_free(m);
	m = alloc_mem(cl, NVRM_MEM_VRAM, 60 * KiB, 0);
	nvrm_mem_info_get(m, &mi);
	CHECK_EQ(mi.page_size, 4 * KiB);
	nvrm_mem_free(m);
	/* the default video memory page needs a reservation aligned to it: a
	 * 4 KiB aligned one may start off a 64 KiB boundary, a 64 KiB aligned
	 * one (the nvrm_mem(3) example) never does */
	{
		nvrm_va_params small = { 0, 0, 4 * KiB, 0, 0 };
		nvrm_va_params vp4 = { 0, 0, 1 * MiB, 0, 0 };
		nvrm_va_params vp64 = { 0, 0, 1 * MiB, 64 * KiB, 0 };
		uint64_t a0, a4, a64;

		CHECK_EQ(nvrm_va_reserve(cl, &small, &a0), NVRM_OK);
		CHECK_EQ(nvrm_va_reserve(cl, &vp4, &a4), NVRM_OK);
		CHECK_EQ(nvrm_va_reserve(cl, &vp64, &a64), NVRM_OK);
		m = alloc_mem(cl, NVRM_MEM_VRAM, 1 * MiB, 0);
		CHECK((a4 & (64 * KiB - 1)) != 0);
		CHECK_EQ(map_gpu(m, a4, 0, 0, 0), NVRM_E_INVAL);
		CHECK_EQ(map_gpu(m, a64, 0, 0, 0), NVRM_OK);
		nvrm_mem_free(m);
		nvrm_va_release(cl, a0);
		nvrm_va_release(cl, a4);
		nvrm_va_release(cl, a64);
	}
	/* system memory: 4 KiB, whatever the size */
	m = alloc_mem(cl, NVRM_MEM_SYSMEM, 1 * MiB, 0);
	nvrm_mem_info_get(m, &mi);
	CHECK_EQ(mi.page_size, 4 * KiB);
	nvrm_mem_free(m);
	/* a host with 16 KiB pages: objects are placed host page aligned, so
	 * that a CPU mapping of each is an mmap at an aligned offset */
	b0 = bstats();
	nvrm_fake_mem_host_page(16 * KiB);
	a = alloc_mem(cl, NVRM_MEM_SYSMEM, 4 * KiB, 4 * KiB);
	b = alloc_mem(cl, NVRM_MEM_SYSMEM, 4 * KiB, 4 * KiB);
	b1 = bstats();
	CHECK_EQ(b1.sys_extents, b0.sys_extents + 1);	/* a 12 KiB hole */
	nvrm_mem_free(a);
	nvrm_mem_free(b);
	nvrm_fake_mem_host_page(0);
	a = alloc_mem(cl, NVRM_MEM_SYSMEM, 4 * KiB, 4 * KiB);
	b = alloc_mem(cl, NVRM_MEM_SYSMEM, 4 * KiB, 4 * KiB);
	b1 = bstats();
	CHECK_EQ(b1.sys_extents, b0.sys_extents);
	nvrm_mem_free(a);
	nvrm_mem_free(b);
	nvrm_client_close(cl);
	expect_clean("default page");
	teardown();
	/* a GPU with no video memory of its own: VRAM is system memory, 4 KiB */
	setup("unified", NULL);
	cl = open_client(0, 0, 0);
	m = alloc_mem(cl, NVRM_MEM_VRAM, 1 * MiB, 0);
	nvrm_mem_info_get(m, &mi);
	CHECK_EQ(mi.place, NVRM_PLACE_SYSMEM);
	CHECK_EQ(mi.page_size, 4 * KiB);
	nvrm_mem_free(m);
	nvrm_client_close(cl);
	teardown();
	/* a GPU whose page sizes are not known: 4 KiB, the one size always valid */
	setup("unknown", NULL);
	cl = open_client(0, 0, 0);
	m = alloc_mem(cl, NVRM_MEM_VRAM, 128 * KiB, 0);
	nvrm_mem_info_get(m, &mi);
	CHECK_EQ(mi.place, NVRM_PLACE_VIDMEM);
	CHECK_EQ(mi.page_size, 4 * KiB);
	nvrm_mem_free(m);
	nvrm_client_close(cl);
	teardown();
}

/* ---- an import names only an exported object ------------------------------ */

static void
test_import_unexported(void)
{
	struct { uint64_t magic, dev, serial; } rec;
	nvrm_client *cl;
	nvrm_mem *m1, *m2, *im = NULL;
	int fd, forged;

	setup("discrete", NULL);
	cl = open_client(0, 0, 2);
	m1 = alloc_mem(cl, NVRM_MEM_SYSMEM, 4096, 0);
	m2 = alloc_mem(cl, NVRM_MEM_SYSMEM, 4096, 0);	/* the next serial */
	CHECK_EQ(nvrm_mem_export_fd(m1, &fd), NVRM_OK);
	CHECK_EQ(pread(fd, &rec, sizeof(rec), 0), (ssize_t)sizeof(rec));
	close(fd);
	/* the record of m1, pointed at m2, which was never exported */
	rec.serial++;
	forged = shm_open(SHM_ANON, O_RDWR, 0600);
	CHECK_EQ(ftruncate(forged, 64), 0);
	CHECK_EQ(pwrite(forged, &rec, sizeof(rec), 0), (ssize_t)sizeof(rec));
	CHECK_EQ(nvrm_mem_import_fd(cl, forged, &im), NVRM_E_RM);
	CHECK(strstr(nvrm_client_errmsg(cl), "never exported") != NULL);
	/* the true record still imports */
	rec.serial--;
	CHECK_EQ(pwrite(forged, &rec, sizeof(rec), 0), (ssize_t)sizeof(rec));
	CHECK_EQ(nvrm_mem_import_fd(cl, forged, &im), NVRM_OK);
	close(forged);
	nvrm_mem_free(im);
	nvrm_mem_free(m1);
	nvrm_mem_free(m2);
	nvrm_client_close(cl);
	expect_clean("import unexported");
	teardown();
}

/* ---- the spares a client holds, and the fault switches -------------------- */

static void
test_spare_rights(void)
{
	nvrm_client *cl;
	nvrm_mem_params mp = { 0, NVRM_MEM_SYSMEM, 0, 0, 4096, 0, 0 };
	nvrm_mem *m;
	cap_rights_t r;
	unsigned i;
	int fd;

	setup("discrete", NULL);
	/* no ALLOW_MAP: no mapping spare, and the export spares carry no
	 * mapping right and cannot be mapped */
	cl = open_client(0, 0, 0);
	CHECK_EQ(cl->pool[NVRM_DESC_MAP].n, 0);
	CHECK_EQ(cl->pool[NVRM_DESC_EXPORT].n, NVRM_EXPORT_SLOTS_DEFAULT);
	for (i = 0; i < cl->pool[NVRM_DESC_EXPORT].n; i++) {
		fd = cl->pool[NVRM_DESC_EXPORT].fd[i];
		CHECK_EQ(cap_rights_get(fd, &r), 0);
		CHECK(!cap_rights_is_set(&r, CAP_MMAP_R));
		CHECK(!cap_rights_is_set(&r, CAP_MMAP_W));
		CHECK(!cap_rights_is_set(&r, CAP_IOCTL));
		CHECK(mmap(NULL, 64, PROT_READ, MAP_SHARED, fd, 0) == MAP_FAILED);
	}
	/* an export narrows its spare to read only */
	CHECK_EQ(nvrm_mem_alloc(cl, &mp, &m), NVRM_OK);
	CHECK_EQ(nvrm_mem_export_fd(m, &fd), NVRM_OK);
	CHECK_EQ(cap_rights_get(fd, &r), 0);
	CHECK(!cap_rights_is_set(&r, CAP_PWRITE));
	CHECK(cap_rights_is_set(&r, CAP_PREAD));
	close(fd);
	nvrm_mem_free(m);
	nvrm_client_close(cl);
	/* an armed fault that was never reached is disarmed by the clear, and
	 * an operation out of range is ignored */
	cl = open_client(0, 0, 0);
	nvrm_fake_mem_fail(NVRM_FAKE_OP_ALLOC, 1);
	nvrm_fake_mem_fail(0, 1);
	nvrm_fake_mem_fail(NVRM_FAKE_OP__COUNT, 1);
	nvrm_fake_mem_fail(-1, 1);
	nvrm_fake_mem_fail_clear();
	CHECK_EQ(nvrm_mem_alloc(cl, &mp, &m), NVRM_OK);
	nvrm_mem_free(m);
	nvrm_client_close(cl);
	expect_clean("spare rights");
	teardown();
}

/* A client closed with an object still allocated: the close frees it, and
 * the sweep finds nothing left (no object, no leak). */
static void
test_close_frees_mem(void)
{
	nvrm_client *cl;
	nvrm_mem *m;

	setup("discrete", "amd64");
	cl = open_client(0, 0, 0);
	m = alloc_mem(cl, NVRM_MEM_SYSMEM, 4096, 0);
	CHECK(m != NULL);
	nvrm_client_close(cl);
	teardown();
	expect_clean("close sweep");
}

/* ---- fork children ------------------------------------------------------- */

static pid_t
other_pid(void)
{
	return (getpid() + 1);
}

static pid_t
this_pid(void)
{
	return (getpid());
}

static void
test_fork_child(void)
{
	nvrm_client *cl;
	nvrm_mem *m, *unmapped, *x = NULL;
	nvrm_va_params vp = { 0, 0, 1 * MiB, 0, 0 };
	nvrm_mem_params mp = { 0, NVRM_MEM_SYSMEM, 0, 0, 4096, 0, 0 };
	nvrm_gpu_map_params gp;
	nvrm_client_stats st = { 0 };
	nvrm_fake_mem_stats before;
	static char pages[65536] __attribute__((aligned(65536)));
	uint64_t va, va2, spare;
	unsigned char back[4];
	int fd, fd2;
	void *p;

	setup("discrete", "amd64");
	cl = open_client(NVRM_OPEN_ALLOW_MAP, 1, 1);
	va = reserve(cl, 2 * MiB, 0, 0);
	m = alloc_mem(cl, NVRM_MEM_SYSMEM, 64 * KiB, 0);
	CHECK_EQ(map_gpu(m, va, 0, 0, 0), NVRM_OK);
	CHECK_EQ(nvrm_mem_map_cpu(m, NVRM_CPU_READ, &p), NVRM_OK);
	CHECK_EQ(nvrm_mem_export_fd(m, &fd), NVRM_OK);
	/* An unmapped object keeps the child free check independent of the
	 * fake backend's rule that a live GPU mapping holds its object. */
	unmapped = alloc_mem(cl, NVRM_MEM_SYSMEM, 4096, 0);
	CHECK_EQ(stats_get(cl, &st), NVRM_OK);
	spare = st.spare_descriptors;
	before = bstats();
	nvrm_getpid_hook = other_pid;
#define CHILD_DENIED(call) do { \
	CHECK_EQ((call), NVRM_E_DENIED); \
	CHECK(strstr(nvrm_client_errmsg(cl), "fork() child") != NULL); \
	CHECK(strstr(nvrm_client_errmsg(cl), "release") != NULL); \
} while (0)
	CHILD_DENIED(nvrm_va_reserve(cl, &vp, &va2));
	CHILD_DENIED(nvrm_mem_alloc(cl, &mp, &x));
	CHILD_DENIED(nvrm_mem_register_user(cl, pages, 65536, &x));
	gp = (nvrm_gpu_map_params){ 0, 0, va + 1 * MiB, 0, 0 };
	CHILD_DENIED(nvrm_mem_map_gpu(m, &gp));
	CHILD_DENIED(nvrm_mem_export_fd(m, &fd2));
	CHILD_DENIED(nvrm_mem_import_fd(cl, fd, &x));
	CHECK_EQ(stats_get(cl, &st), NVRM_OK);
	CHECK_EQ(st.spare_descriptors, spare);
	CHECK_EQ(nvrm_mem_unmap_cpu(m), NVRM_OK);
	CHILD_DENIED(nvrm_mem_map_cpu(m, NVRM_CPU_READ, &p));
#undef CHILD_DENIED
	CHECK_EQ(nvrm_mem_unmap_gpu(m, va), NVRM_OK);
	nvrm_mem_free(unmapped);
	nvrm_mem_free(m);
	CHECK_EQ(nvrm_va_release(cl, va), NVRM_OK);
	CHECK_EQ(stats_get(cl, &st), NVRM_OK);
	CHECK_EQ(st.live_mem, 0);
	CHECK_EQ(st.live_reservations, 0);
	CHECK_EQ(st.live_gpu_maps, 0);
	CHECK_EQ(st.live_cpu_maps, 0);
	CHECK_EQ(st.failed_releases, 0);
	/* Child releases free only their own backend records: the parent's fake
	 * GPU objects, including the still-valid GPU mapping, are untouched. */
	CHECK_EQ(bstats().clients, before.clients);
	CHECK_EQ(bstats().objects, before.objects);
	CHECK_EQ(bstats().reservations, before.reservations);
	CHECK_EQ(bstats().gpu_maps, before.gpu_maps);
	CHECK_EQ(nvrm_fake_gpu_access(cl, va, back, sizeof(back), 0), 0);
	close(fd);
	nvrm_getpid_hook = NULL;
	/* A new wrapper is not taken as mapped, whatever address the allocator
	 * gives it: its free reaches the backend at once and the object goes. */
	m = alloc_mem(cl, NVRM_MEM_SYSMEM, 64 * KiB, 0);
	x = alloc_mem(cl, NVRM_MEM_SYSMEM, 64 * KiB, 0);
	CHECK(x != NULL);
	nvrm_mem_free(x);
	CHECK_EQ(bstats().objects, before.objects + 1);
	nvrm_mem_free(m);
	CHECK_EQ(bstats().objects, before.objects);
	CHECK_EQ(failed_releases(cl), 0);
	nvrm_client_close(cl);
	teardown();
	expect_clean("fork child");
}

/* Registered user pages carry no fake object: GPU maps of two of them are
 * told apart by their pages, and a fork child frees such a wrapper locally. */
static void
test_fork_user_pages(void)
{
	nvrm_client *cl;
	nvrm_mem *a, *b, *c, *d;
	static char pages[4 * 65536] __attribute__((aligned(65536)));
	nvrm_client_stats st = { 0 };
	uint64_t va;

	setup("discrete", "amd64");
	cl = open_client(NVRM_OPEN_ALLOW_MAP, 1, 1);
	va = reserve(cl, 2 * MiB, 0, 0);
	CHECK_EQ(nvrm_mem_register_user(cl, pages, 65536, &a), NVRM_OK);
	CHECK_EQ(nvrm_mem_register_user(cl, pages + 65536, 65536, &b), NVRM_OK);
	CHECK_EQ(nvrm_mem_register_user(cl, pages + 2 * 65536, 65536, &c),
	    NVRM_OK);
	CHECK_EQ(nvrm_mem_register_user(cl, pages + 3 * 65536, 65536, &d),
	    NVRM_OK);
	CHECK_EQ(map_gpu(a, va, 0, 0, 0), NVRM_OK);
	CHECK_EQ(map_gpu(b, va + 65536, 0, 0, 0), NVRM_OK);
	/* The newest map (b) is searched first and must be skipped for a. */
	CHECK_EQ(nvrm_mem_unmap_gpu(a, va), NVRM_OK);
	/* An unmapped wrapper is not held by b's map: its free reaches the
	 * backend, where an injected failure is seen (a held one would not). */
	nvrm_fake_mem_fail(NVRM_FAKE_OP_FREE, 1);
	nvrm_mem_free(c);
	CHECK_EQ(failed_releases(cl), 1);
	nvrm_getpid_hook = other_pid;
	nvrm_mem_free(d);			/* a child: its wrapper only */
	nvrm_getpid_hook = NULL;
	CHECK_EQ(nvrm_mem_unmap_gpu(b, va + 65536), NVRM_OK);
	nvrm_mem_free(b);
	nvrm_mem_free(a);
	CHECK_EQ(nvrm_va_release(cl, va), NVRM_OK);
	CHECK_EQ(stats_get(cl, &st), NVRM_OK);
	CHECK_EQ(st.failed_releases, 1);
	nvrm_client_close(cl);
	teardown();
	expect_clean("fork user pages");
}

/* One child release on a shared object (exported, imported by a second
 * client) must not hide a leak of the owner's: the sweep counts the
 * references the child released against the references still held. */
static void
test_orphan_count(void)
{
	nvrm_client *a, *b;
	nvrm_mem *m, *im = NULL;
	nvrm_device *d;
	nvrm_open_opts oa = { 0, 0, 0, 1 };
	char err[200];
	int fd;

	setup("discrete", "amd64");
	d = nvrm_device_get(ctx, 0);
	CHECK_EQ(nvrm_client_open(d, &oa, &a, err, sizeof(err)), NVRM_OK);
	b = open_client(0, 0, 0);
	m = alloc_mem(a, NVRM_MEM_SYSMEM, 4096, 0);
	CHECK_EQ(nvrm_mem_export_fd(m, &fd), NVRM_OK);
	CHECK_EQ(nvrm_mem_import_fd(b, fd, &im), NVRM_OK);
	close(fd);
	nvrm_fake_mem_test_leak_ref(m->b);	/* the owner's leak */
	nvrm_getpid_hook = other_pid;
	nvrm_mem_free(im);			/* a child: its wrapper only */
	nvrm_getpid_hook = NULL;
	nvrm_mem_free(m);
	nvrm_client_close(a);
	nvrm_client_close(b);
	/* counted as a leak, and still gone from the live count */
	CHECK_EQ(leaked() - leaked_base, 1);
	CHECK_EQ(bstats().objects, 0);
	CHECK_EQ(bstats().clients, 0);
	teardown();
}

/* Two wrappers of one object in one client (an import of its own export):
 * a GPU map of one is not a map of the other. */
static void
test_same_client_import(void)
{
	nvrm_client *cl;
	nvrm_mem *m1, *m2 = NULL;
	uint64_t va;
	int fd;

	setup("discrete", "amd64");
	cl = open_client(NVRM_OPEN_ALLOW_MAP, 1, 1);
	va = reserve(cl, 1 * MiB, 0, 0);
	m1 = alloc_mem(cl, NVRM_MEM_SYSMEM, 4096, 0);
	CHECK_EQ(nvrm_mem_export_fd(m1, &fd), NVRM_OK);
	CHECK_EQ(nvrm_mem_import_fd(cl, fd, &m2), NVRM_OK);
	close(fd);
	CHECK_EQ(map_gpu(m1, va, 0, 0, 0), NVRM_OK);
	/* m2 has no map at m1's address, and m1's map is still there */
	CHECK(nvrm_mem_unmap_gpu(m2, va) != NVRM_OK);
	CHECK_EQ(bstats().gpu_maps, 1);
	/* m2 is not mapped: its refused free is seen and counted, for m2 only */
	nvrm_fake_mem_fail(NVRM_FAKE_OP_FREE, 1);
	nvrm_mem_free(m2);
	CHECK_EQ(failed_releases(cl), 1);
	CHECK_EQ(bstats().gpu_maps, 1);
	CHECK_EQ(nvrm_mem_unmap_gpu(m1, va), NVRM_OK);
	CHECK_EQ(bstats().gpu_maps, 0);
	nvrm_mem_free(m1);
	CHECK_EQ(nvrm_va_release(cl, va), NVRM_OK);
	nvrm_client_close(cl);
	teardown();
	expect_clean("same-client import");
}

/* The same user pages registered twice: a GPU map of one wrapper is not a
 * map of the other. */
static void
test_user_pages_twice(void)
{
	static char pages[65536] __attribute__((aligned(65536)));
	nvrm_client *cl;
	nvrm_mem *u1, *u2;
	uint64_t va;

	setup("discrete", "amd64");
	cl = open_client(NVRM_OPEN_ALLOW_MAP, 1, 1);
	va = reserve(cl, 1 * MiB, 0, 0);
	CHECK_EQ(nvrm_mem_register_user(cl, pages, 65536, &u1), NVRM_OK);
	CHECK_EQ(nvrm_mem_register_user(cl, pages, 65536, &u2), NVRM_OK);
	CHECK_EQ(map_gpu(u1, va, 0, 0, 0), NVRM_OK);
	nvrm_fake_mem_fail(NVRM_FAKE_OP_FREE, 1);
	nvrm_mem_free(u2);
	CHECK_EQ(failed_releases(cl), 1);
	CHECK_EQ(nvrm_mem_unmap_gpu(u1, va), NVRM_OK);
	nvrm_mem_free(u1);
	CHECK_EQ(nvrm_va_release(cl, va), NVRM_OK);
	nvrm_client_close(cl);
	teardown();
	expect_clean("user pages twice");
}

static void
test_fork_generation(void)
{
	nvrm_client *cl;
	nvrm_mem *m = NULL;
	nvrm_mem_params mp = { 0, NVRM_MEM_SYSMEM, 0, 0, 4096, 0, 0 };

	setup("discrete", NULL);
	cl = open_client(0, 0, 0);
	(void)reserve(cl, 1 * MiB, 0, 0);	/* close drops this child record */
	nvrm_getpid_hook = this_pid;
	nvrm_owner_fork_seam();
	CHECK_EQ(nvrm_mem_alloc(cl, &mp, &m), NVRM_E_DENIED);
	CHECK(strstr(nvrm_client_errmsg(cl), "fork() child") != NULL);
	nvrm_getpid_hook = NULL;
	if (m != NULL)
		nvrm_mem_free(m);
	nvrm_client_close(cl);
	teardown();
	expect_clean("fork generation");
}

static const struct t_entry tests[] = {
	T_TEST("va", test_va_basic)
	T_TEST("va", test_va_fixed_and_free)
	T_TEST("va", test_va_edges)
	T_TEST("va", test_va_oom)
	T_TEST("va", test_va_shadow)
	T_TEST("attr", test_attr_rule)
	T_TEST("client", test_client_open)
	T_TEST("client", test_client_independent)
	T_TEST("reserve", test_reserve)
	T_TEST("alloc", test_alloc)
	T_TEST("alloc", test_register_user)
	T_TEST("gpu", test_map_gpu)
	T_TEST("gpu", test_gpu_model)
	T_TEST("sparse", test_sparse)
	T_TEST("cpu", test_cpu_map)
	T_TEST("cpu", test_device_attr)
	T_TEST("readback", test_readback)
	T_TEST("loop", test_loop)
	T_TEST("share", test_share)
	T_TEST("share", test_fake_device)
	T_TEST("va", test_va_gaps)
	T_TEST("gaps", test_gaps)
	T_TEST("release", test_release_failures)
	T_TEST("alloc", test_default_page)
	T_TEST("share", test_import_unexported)
	T_TEST("client", test_spare_rights)
	T_TEST("close-sweep", test_close_frees_mem)
	T_TEST("fork", test_fork_child)
	T_TEST("fork", test_fork_user_pages)
	T_TEST("fork", test_orphan_count)
	T_TEST("share", test_same_client_import)
	T_TEST("share", test_user_pages_twice)
	T_TEST("fork", test_fork_generation)
};

int
main(void)
{
	unsetenv("NVRM_BACKEND");
	setenv("NVRM_BACKEND", "fake", 1);
	t_run(tests, sizeof(tests) / sizeof(tests[0]));
	return (t_done("mem_test"));
}

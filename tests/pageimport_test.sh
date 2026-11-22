#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# pageimport_test.sh - fake-driven userland test of
# src/gb10-pageimport/gb10_pageimport.h, the pure core of the cross-GPU
# buffer import (PRIME, Track #2228, docs/PRIME-IMPORT.md).
#
# The header turns a foreign buffer's scatter list into the array of
# vm_page pointers the RM's page-array descriptor wants, wires the pages
# for the RM, and backs the SGT entry points of the OS layer.  It has no
# kernel includes, so this test compiles it with a fake VM (an array of
# fake pages with a wire count and a "is managed RAM" flag) and checks:
#
#   (a) scatter-list to page-array conversion: whole pages (one entry,
#       several entries, an entry that spans several pages is expanded
#       page by page), a partial page, a non-zero offset, a page that is
#       not managed RAM (the first page, a later page of a multi-page
#       entry, a missing page pointer: the VRAM case), an empty list, an
#       empty size, a size over the KAPI's 32-bit limit, a size that
#       disagrees with the entries (both ways), a length sum that would
#       wrap, a too-small output array, bad arguments;
#   (b) wire and unwire balance: every wire count is back at its start
#       after the RM's teardown (the model of os_unlock_user_pages: one
#       unwire per page of the array); a wire that fails halfway leaves
#       no page wired; two registrations of one buffer wire twice and
#       unwire twice; an unwire of a page that is not wired is caught by
#       the fake;
#   (c) the SGT path (nv_dma_import_sgt, nv_register_sgt,
#       nv_unregister_sgt, nv_dma_release_sgt): a descriptor with a wrong
#       magic, a page count that disagrees with the RM's, or no pages is
#       refused; a registration fills EVERY physical address of the
#       output array, and a refused or failed one leaves it untouched
#       (the old nv_register_sgt returned success with nothing filled);
#       the hold/release of the owner is balanced on the success path,
#       on a registration that fails, and on a failure after a
#       registration.
#
# Controls: the same program is run against mutants of the header (no
# overflow check, no unwire, no rollback of a failed wire, a register
# that fills nothing, a release that is never called, ...); every mutant
# must fail it.  A control that passes means the test cannot see the
# defect.
#
# Run: sh tests/pageimport_test.sh
# Exit 0 and a final PASS line when every check passes; 1 otherwise.

set -u
ulimit -c 0

PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL

TESTSDIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH= cd -- "$TESTSDIR/.." && pwd)
WORK=${GB10_WORK:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)/work}
mkdir -p "$WORK/tmp"
export TMPDIR="$WORK/tmp"
HEADER=$REPO/src/gb10-pageimport/gb10_pageimport.h

TESTROOT=$(mktemp -d "$WORK/tmp/pageimport-test.XXXXXXXX") || exit 1
cleanup() { rm -rf "$TESTROOT"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

PASSED=0
FAILED=0
ok() { PASSED=$((PASSED + 1)); printf 'ok   %s\n' "$1"; }
fail() { FAILED=$((FAILED + 1)); printf 'FAIL %s\n' "$1"; }

if [ ! -f "$HEADER" ]; then
	fail "missing core header: $HEADER"
	echo "pageimport_test: FAIL (passed $PASSED, failed $FAILED)"
	exit 1
fi

cat > "$TESTROOT/pi_test.c" <<'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "gb10_pageimport.h"

#define PS 4096ULL
#define NFAKE 64

struct fake_page {
	int wired;		/* wire count */
	int ram;		/* managed RAM */
	int object;		/* belongs to a VM object (the noobj pages of a GPU driver: 0) */
	int valid;		/* 0 none, 1 partly, 2 all valid (vm_page_all_valid()); a noobj page: 0 */
	int fict;		/* PG_FICTITIOUS */
	int busy;		/* exclusively busied by the importer */
	int busy_other;		/* somebody else holds the busy lock */
	int dirty;
	unsigned long long pa;
};

static struct fake_page vm[NFAKE];
static int wire_calls, unwire_calls, bad_unwire, fail_wire_at = -1;
static int held;
static int unwire_saw_refs, dmabuf_refs, pool_reused;
/* the fake VM's KASSERTs: a wire of a page that is not busied by us or has an
 * object, a dirty of a page that is not valid, a busy left behind */
static int kassert_wire, kassert_dirty, alias_first, refused_dirty;
static int fallback_dirty, d_dirty_unbusied, delay_calls, pager_lets_go_at, unlock_budget;

static void
vm_reset(void)
{
	int i;

	memset(vm, 0, sizeof(vm));
	for (i = 0; i < NFAKE; i++) {
		vm[i].ram = 1;
		vm[i].pa = 0x80000000ULL + (unsigned long long)i * PS;
	}
	wire_calls = unwire_calls = bad_unwire = held = 0;
	kassert_wire = kassert_dirty = alias_first = refused_dirty = 0;
	delay_calls = 0;
	pager_lets_go_at = 3;	/* by default a pager holds a page for 3 delays, then lets go */
	unlock_budget = GB10_PI_DIRTY_SPIN_BUDGET;
	fallback_dirty = d_dirty_unbusied = 0;
	fail_wire_at = -1;
}

static void *
f_page_at(void *ctx, void *first, unsigned long long index)
{
	long base = (struct fake_page *)first - vm;
	unsigned long long at;

	(void)ctx;
	at = (unsigned long long)base + index;
	if (base < 0 || at >= NFAKE)
		return NULL;
	if (!gb10_pi_page_claimable(vm[at].ram, vm[at].fict, vm[at].object != 0))
		return NULL;
	if (alias_first && index == 0)	/* the physical lookup finds another page */
		return &vm[at + 1];
	return &vm[at];
}

static int
f_try_busy(void *ctx, void *page)
{
	struct fake_page *p = page;

	(void)ctx;
	if (p->busy_other || p->busy)
		return -1;
	p->busy = 1;
	return 0;
}

static void
f_unbusy(void *ctx, void *page)
{
	(void)ctx;
	((struct fake_page *)page)->busy = 0;
	((struct fake_page *)page)->busy_other = 0;	/* an unbusy of a page we do not hold would drop somebody else's lock */
}

/* what the OS layer re-checks under the busy lock */
static int
f_claimable(void *ctx, void *page)
{
	struct fake_page *p = page;

	(void)ctx;
	/* the re-check is only meaningful with the page busied (a check made before the busy proves nothing) */
	return p->busy == 1 && gb10_pi_page_claimable(p->ram, p->fict, p->object != 0);
}

static int
f_wire(void *ctx, void *page)
{
	struct fake_page *p = page;

	(void)ctx;
	if (fail_wire_at >= 0 && wire_calls == fail_wire_at) {
		wire_calls++;
		return -1;
	}
	wire_calls++;
	if (!p->busy || (p->object && p->wired == 0))	/* vm_page_wire() asserts the object lock for a page with an object that is not busied by us or already wired */
		kassert_wire++;
	p->wired++;
	return 0;
}

static void
f_unwire(void *ctx, void *page)
{
	struct fake_page *p = page;

	(void)ctx;
	unwire_calls++;
	unwire_saw_refs = dmabuf_refs;
	if (p->wired <= 0)
		bad_unwire++;
	else
		p->wired--;
}

static unsigned long long
f_phys(void *ctx, void *page)
{
	(void)ctx;
	return ((struct fake_page *)page)->pa;
}

/* the second wiring of an imported buffer (the SGT export): wired by us, may have an object by now */
static int
f_rewire_ok(void *ctx, void *page)
{
	struct fake_page *p = page;

	(void)ctx;
	return p->busy == 1 && p->ram && !p->fict && p->wired > 0;
}

static const struct gb10_pi_ops ops = {
	.page_at = f_page_at, .wire = f_wire, .unwire = f_unwire, .phys = f_phys,
	.try_busy = f_try_busy, .unbusy = f_unbusy, .claimable = f_claimable,
	.rewire_ok = f_rewire_ok,
};

/*
 * The model of the dirty step of os_unlock_user_pages(): the REAL core
 * (gb10_pi_dirty_page) driven by fake VM operations.  A writable teardown
 * busies the page, spins for a pager that holds it (the fake lets go
 * within the wait or not at all), asks at the dirty site (object and all valid), dirties, unbusies,
 * then unwires.  vm_page_dirty() asserts that the page is all valid
 * (INVARIANTS) and a noobj page of another driver never is; a wired page
 * can also be invalidated after the wiring (a truncate), so a check at wire
 * time is not enough.
 */
static int d_try_busy(void *c, void *pg) { return f_try_busy(c, pg); }
static void d_delay(void *c, void *pg)
{
	int i;

	(void)c; (void)pg;
	delay_calls++;
	if (pager_lets_go_at >= 0 && delay_calls == pager_lets_go_at)
		for (i = 0; i < NFAKE; i++)
			vm[i].busy_other = 0;	/* the pager let go */
}
static void d_unbusy(void *c, void *pg) { f_unbusy(c, pg); }
static int d_has_object(void *c, void *pg) { (void)c; return ((struct fake_page *)pg)->object != 0; }
static int d_all_valid(void *c, void *pg) { (void)c; return ((struct fake_page *)pg)->valid == 2; }
static void d_dirty(void *c, void *pg)
{
	struct fake_page *p = pg;

	(void)c;
	if (p->valid != 2)
		kassert_dirty++;
	if (!p->busy)
		d_dirty_unbusied++;
	p->dirty = 1;
}
static const struct gb10_pi_dirty_ops dirty_ops = {
	.try_busy = d_try_busy, .delay = d_delay, .unbusy = d_unbusy,
	.has_object = d_has_object, .all_valid = d_all_valid, .dirty = d_dirty,
};

static void
f_rm_unlock_pages(void **pages, unsigned long long n, int write)
{
	unsigned long long i;
	struct fake_page *p;
	int budget = unlock_budget;	/* one budget for the whole teardown */

	for (i = 0; i < n; i++) {
		p = pages[i];
		if (write) {
			switch (gb10_pi_dirty_page(p, &dirty_ops, NULL, &budget)) {
			case GB10_PI_DIRTY_REFUSE:
				refused_dirty++;
				break;
			case GB10_PI_DIRTY_FALLBACK:
				fallback_dirty++;
				break;
			default:
				break;
			}
		}
		f_unwire(NULL, p);
	}
}

static int
none_busy(void)
{
	int i;

	for (i = 0; i < NFAKE; i++)
		if (vm[i].busy)
			return 0;
	return 1;
}

/* a fake exporter whose buffer is freed with the last GEM reference. */
static int gem_refs, src_freed;
static int g_hold(void *ctx) { (void)ctx; gem_refs++; return 0; }
static void g_release(void *ctx) { (void)ctx; if (--gem_refs == 0) src_freed = 1; }

/*
 * The unload gate, driven as nvidia-drm does: the owner's hold goes through
 * the gate (under the module's lock, which a single-threaded model needs no
 * more than the order of the calls), the owner's release is the module's
 * and sees the count still up, and the core counts down after it returned.
 */
static struct gb10_pi_gate G;
static int owner_refs, live_seen_in_release;
static int gate_hold(void *ctx) { (void)ctx; if (gb10_pi_gate_hold(&G) != 0) return -1; owner_refs++; return 0; }
/* a release that frees the descriptor, as the last GEM reference does (the descriptor is inside the object): poison it */
static void poison_release(void *ctx) { memset(ctx, 0xa5, sizeof(struct gb10_pi_desc)); }
static void gate_release(void *ctx) { (void)ctx; live_seen_in_release = gb10_pi_gate_live(&G); owner_refs--; }

/* the exporter's dma-buf: when nobody holds it, its page pool may reuse the pages */
static void x_hold(void *ctx) { (void)ctx; dmabuf_refs++; }
static int xd_hold(void *ctx) { (void)ctx; dmabuf_refs++; return 0; }
static void x_release(void *ctx) { (void)ctx; if (--dmabuf_refs == 0) pool_reused = 1; }

static int f_hold(void *ctx) { (void)ctx; held++; return 0; }
static void f_release(void *ctx) { (void)ctx; held--; }

static int failures;
static void
check(const char *what, long long got, long long want)
{
	if (got == want) {
		printf("ok   %s = %lld\n", what, got);
	} else {
		printf("FAIL %s: got %lld, want %lld\n", what, got, want);
		failures++;
	}
}

static int
all_unwired(void)
{
	int i;

	for (i = 0; i < NFAKE; i++)
		if (vm[i].wired != 0)
			return 0;
	return bad_unwire == 0;
}

static struct gb10_pi_seg
seg(int first, unsigned long long off, unsigned long long len)
{
	struct gb10_pi_seg s;

	s.first = first < 0 ? NULL : &vm[first];
	s.offset = off;
	s.length = len;
	return s;
}

int
main(void)
{
	struct gb10_pi_seg s[4];
	void *pages[NFAKE + 1];
	unsigned long long n;
	unsigned long long phys[NFAKE + 1];
	struct gb10_pi_desc d;
	int i, rc;

	/* (a) conversion */
	vm_reset();
	s[0] = seg(3, 0, 4 * PS);
	n = 0;
	check("one entry of 4 pages: count rc", gb10_pi_count(s, 1, 4 * PS, PS, &n), GB10_PI_OK);
	check("one entry of 4 pages: npages", (long long)n, 4);
	rc = gb10_pi_fill(s, 1, 4 * PS, PS, &ops, NULL, pages, NFAKE, &n);
	check("one entry of 4 pages: fill rc", rc, GB10_PI_OK);
	check("one entry of 4 pages: npages", (long long)n, 4);
	check("one entry of 4 pages: page 0 is vm[3]", pages[0] == &vm[3], 1);
	check("one entry of 4 pages: page 3 is vm[6] (expanded)", pages[3] == &vm[6], 1);
	check("fill alone wires nothing", wire_calls, 0);

	vm_reset();
	s[0] = seg(10, 0, 2 * PS);
	s[1] = seg(40, 0, PS);
	s[2] = seg(20, 0, 2 * PS);
	rc = gb10_pi_fill(s, 3, 5 * PS, PS, &ops, NULL, pages, NFAKE, &n);
	check("three entries: rc", rc, GB10_PI_OK);
	check("three entries: npages", (long long)n, 5);
	check("three entries: order 10 11 40 20 21",
	    pages[0] == &vm[10] && pages[1] == &vm[11] && pages[2] == &vm[40] &&
	    pages[3] == &vm[20] && pages[4] == &vm[21], 1);

	vm_reset();
	s[0] = seg(3, 0, PS + 512);
	check("partial page (length 4608): rc", gb10_pi_count(s, 1, PS + 512, PS, &n), GB10_PI_NOT_WHOLE_PAGES);
	s[0] = seg(3, 0, 100);
	check("partial page (length 100): rc", gb10_pi_count(s, 1, 100, PS, &n), GB10_PI_NOT_WHOLE_PAGES);
	s[0] = seg(3, 512, PS);
	check("non-zero offset: rc", gb10_pi_count(s, 1, PS, PS, &n), GB10_PI_NOT_WHOLE_PAGES);
	s[0] = seg(3, 0, 2 * PS);
	check("size not a whole number of pages: rc", gb10_pi_count(s, 1, 2 * PS + 1, PS, &n), GB10_PI_NOT_WHOLE_PAGES);

	vm_reset();
	vm[3].ram = 0;
	s[0] = seg(3, 0, PS);
	check("first page not RAM: rc", gb10_pi_fill(s, 1, PS, PS, &ops, NULL, pages, NFAKE, &n), GB10_PI_NOT_RAM);
	vm_reset();
	vm[5].ram = 0;
	s[0] = seg(3, 0, 4 * PS);
	check("third page of an entry not RAM: rc", gb10_pi_fill(s, 1, 4 * PS, PS, &ops, NULL, pages, NFAKE, &n), GB10_PI_NOT_RAM);
	vm_reset();
	s[0] = seg(3, 0, PS);
	s[1] = seg(-1, 0, PS);
	check("entry without a page (VRAM): rc", gb10_pi_fill(s, 2, 2 * PS, PS, &ops, NULL, pages, NFAKE, &n), GB10_PI_NOT_RAM);
	check("entry without a page: count alone refuses it", gb10_pi_count(s, 2, 2 * PS, PS, &n), GB10_PI_NOT_RAM);

	vm_reset();
	check("empty list: rc", gb10_pi_count(s, 0, PS, PS, &n), GB10_PI_EMPTY);
	s[0] = seg(3, 0, PS);
	check("empty size: rc", gb10_pi_count(s, 1, 0, PS, &n), GB10_PI_EMPTY);
	s[0] = seg(3, 0, 0);
	check("zero-length entry: rc", gb10_pi_count(s, 1, PS, PS, &n), GB10_PI_NOT_WHOLE_PAGES);

	s[0] = seg(3, 0, (1ULL << 32) + PS);
	check("size over the 32-bit limit: rc", gb10_pi_count(s, 1, (1ULL << 32) + PS, PS, &n), GB10_PI_OVERSIZE);
	s[0] = seg(3, 0, (1ULL << 32));
	check("size exactly 4 GiB: rc", gb10_pi_count(s, 1, (1ULL << 32), PS, &n), GB10_PI_OK);
	check("size exactly 4 GiB: npages", (long long)n, (1LL << 20));

	s[0] = seg(3, 0, 2 * PS);
	check("size larger than the entries: rc", gb10_pi_count(s, 1, 3 * PS, PS, &n), GB10_PI_SIZE_MISMATCH);
	check("size smaller than the entries: rc", gb10_pi_count(s, 1, PS, PS, &n), GB10_PI_SIZE_MISMATCH);
	s[0] = seg(3, 0, 1ULL << 63);
	s[1] = seg(4, 0, 1ULL << 63);
	rc = gb10_pi_count(s, 2, PS, PS, &n);
	check("length sum that wraps is refused", rc != GB10_PI_OK, 1);
	s[0] = seg(3, 0, 0xFFFFFFFFFFFFF000ULL);
	s[1] = seg(4, 0, 2 * PS);
	rc = gb10_pi_count(s, 2, PS, PS, &n);
	check("length sum that wraps to a small size is refused", rc != GB10_PI_OK, 1);

	s[0] = seg(3, 0, 4 * PS);
	memset(pages, 0, sizeof(pages));
	rc = gb10_pi_fill(s, 1, 4 * PS, PS, &ops, NULL, pages, 3, &n);
	check("output array too small: rc", rc, GB10_PI_CAPACITY);
	check("output array too small: nothing written", pages[0] == NULL, 1);
	check("NULL segments: rc", gb10_pi_count(NULL, 1, PS, PS, &n), GB10_PI_BAD_ARG);
	check("NULL result: rc", gb10_pi_count(s, 1, PS, PS, NULL), GB10_PI_BAD_ARG);
	check("page size 0: rc", gb10_pi_count(s, 1, PS, 0, &n), GB10_PI_BAD_ARG);
	check("page size not a power of two: rc", gb10_pi_count(s, 1, PS, 3000, &n), GB10_PI_BAD_ARG);
	check("NULL ops: rc", gb10_pi_fill(s, 1, 4 * PS, PS, NULL, NULL, pages, NFAKE, &n), GB10_PI_BAD_ARG);
	check("error strings exist", gb10_pi_str(GB10_PI_NOT_RAM) != NULL && gb10_pi_str(999) != NULL, 1);
	check("only the allocation failure is ENOMEM-class", gb10_pi_is_nomem(GB10_PI_NOMEM) && !gb10_pi_is_nomem(GB10_PI_NOT_RAM), 1);

	/* (b) wire and unwire balance: the RM's teardown unwires every page of the array */
	vm_reset();
	s[0] = seg(8, 0, 6 * PS);
	rc = gb10_pi_fill(s, 1, 6 * PS, PS, &ops, NULL, pages, NFAKE, &n);
	rc = gb10_pi_wire(pages, n, &ops, NULL);
	check("wire 6 pages: rc", rc, GB10_PI_OK);
	check("wire 6 pages: every page wired once", vm[8].wired == 1 && vm[13].wired == 1 && vm[14].wired == 0, 1);
	f_rm_unlock_pages(pages, n, 1);	/* the RM's teardown: the descriptor is writable */
	check("after the RM's teardown every page is unwired", all_unwired(), 1);
	check("the teardown of noobj (never valid) pages dirties none: no panic", kassert_dirty == 0 && vm[8].dirty == 0, 1);
	check("a wire of a plain noobj page is done under its busy lock", kassert_wire == 0 && none_busy(), 1);

	/* the dirty guard is "has an object and is all valid", tested at the dirty site */
	vm_reset();
	s[0] = seg(8, 0, PS);
	gb10_pi_fill(s, 1, PS, PS, &ops, NULL, pages, NFAKE, &n);
	vm[8].object = 1;	/* the exporter's mapping faulted the page in after the import */
	vm[8].valid = 2;
	vm[8].wired = 1;
	f_rm_unlock_pages(pages, n, 1);
	check("a page with an object that is all valid is dirtied by a writable teardown", vm[8].dirty, 1);
	vm_reset();
	vm[8].object = 1;
	vm[8].valid = 1;	/* partially valid object page: vm_page_dirty() would assert */
	vm[8].wired = 1;
	pages[0] = &vm[8];
	f_rm_unlock_pages(pages, 1, 1);
	check("a partially valid object page is not dirtied", vm[8].dirty == 0 && kassert_dirty == 0, 1);
	check("... the refusal is reported, not silent", refused_dirty, 1);
	vm_reset();
	s[0] = seg(8, 0, 3 * PS);
	gb10_pi_fill(s, 1, 3 * PS, PS, &ops, NULL, pages, NFAKE, &n);
	vm[9].valid = 2;	/* valid when it was wired ... */
	gb10_pi_wire(pages, n, &ops, NULL);
	vm[9].valid = 0;	/* ... invalidated later (vm_object_page_remove on a truncate) */
	f_rm_unlock_pages(pages, n, 1);
	check("a page invalidated after the wiring is not dirtied", kassert_dirty == 0 && vm[9].dirty == 0, 1);
	check("... and it is still unwired", all_unwired(), 1);
	vm_reset();
	s[0] = seg(8, 0, PS);
	gb10_pi_fill(s, 1, PS, PS, &ops, NULL, pages, NFAKE, &n);
	vm[8].valid = 2;
	gb10_pi_wire(pages, n, &ops, NULL);
	f_rm_unlock_pages(pages, n, 0);
	check("a read-only teardown dirties nothing", vm[8].dirty == 0 && kassert_dirty == 0, 1);
	check("the dirty rule: no object, skipped", gb10_pi_dirty_action(0, 1), GB10_PI_DIRTY_SKIP);
	check("the dirty rule: no object and not valid, skipped", gb10_pi_dirty_action(0, 0), GB10_PI_DIRTY_SKIP);
	check("the dirty rule: object but not all valid, refused", gb10_pi_dirty_action(1, 0), GB10_PI_DIRTY_REFUSE);
	check("the dirty rule: an all-valid object page is dirtied", gb10_pi_dirty_action(1, 1), GB10_PI_DIRTY_DO);

	/* the busy lock held by a pager at the release: wait for it, never skip the dirty bit */
	vm_reset();
	s[0] = seg(8, 0, PS);
	gb10_pi_fill(s, 1, PS, PS, &ops, NULL, pages, NFAKE, &n);
	gb10_pi_wire(pages, n, &ops, NULL);
	vm[8].object = 1;
	vm[8].valid = 2;
	vm[8].busy_other = 1;		/* the laundry thread has it busied for a write */
	f_rm_unlock_pages(pages, n, 1);
	check("a pager holds the page at the release and lets go within the wait: dirtied after the wait", vm[8].dirty == 1 && d_dirty_unbusied == 0, 1);
	check("... nothing is counted and nothing is left busied", fallback_dirty == 0 && refused_dirty == 0 && none_busy(), 1);
	vm_reset();
	gb10_pi_fill(s, 1, PS, PS, &ops, NULL, pages, NFAKE, &n);
	gb10_pi_wire(pages, n, &ops, NULL);
	vm[8].object = 1;
	vm[8].valid = 2;
	vm[8].busy_other = 1;
	pager_lets_go_at = -1;			/* the pager holds the lock through the whole budget */
	f_rm_unlock_pages(pages, n, 1);
	check("a pager holds the page through the whole wait: dirtied the stock way", vm[8].dirty, 1);
	check("... and counted, never silent", fallback_dirty, 1);
	check("... nothing of the pager's busy lock is dropped", vm[8].busy_other, 1);
	vm_reset();
	gb10_pi_fill(s, 1, PS, PS, &ops, NULL, pages, NFAKE, &n);
	gb10_pi_wire(pages, n, &ops, NULL);
	vm[8].object = 1;
	vm[8].valid = 1;		/* partly valid */
	vm[8].busy_other = 1;
	pager_lets_go_at = -1;
	f_rm_unlock_pages(pages, n, 1);
	check("busy through the wait, not all valid: refused, not dirtied", vm[8].dirty == 0 && refused_dirty == 1 && fallback_dirty == 0 && kassert_dirty == 0, 1);
	vm_reset();
	gb10_pi_fill(s, 1, PS, PS, &ops, NULL, pages, NFAKE, &n);
	gb10_pi_wire(pages, n, &ops, NULL);
	vm[8].busy_other = 1;
	pager_lets_go_at = -1;
	f_rm_unlock_pages(pages, n, 1);
	check("busy through the wait, no object: skipped without a count", vm[8].dirty == 0 && refused_dirty == 0 && fallback_dirty == 0, 1);
	{
		int b = GB10_PI_DIRTY_SPIN_BUDGET;

		check("... the result is SKIP", gb10_pi_dirty_page(&vm[8], &dirty_ops, NULL, &b), GB10_PI_DIRTY_SKIP);
		check("... the foreign busy lock is still the foreigner's (not taken, not dropped)", vm[8].busy_other == 1 && vm[8].busy == 0, 1);
	}
	check("the dirty step with missing operations is refused (and so counted), never skipped silently", gb10_pi_dirty_page(&vm[8], NULL, NULL, NULL), GB10_PI_DIRTY_REFUSE);

	/* the spin: one budget per teardown, pinned, at the cap and one past it, never for a page without an object */
	check("the spin budget is 100 delays", GB10_PI_DIRTY_SPIN_BUDGET, 100);
	check("a delay is 10 microseconds", GB10_PI_DIRTY_SPIN_US, 10);
	vm_reset();
	s[0] = seg(8, 0, 5 * PS);
	gb10_pi_fill(s, 1, 5 * PS, PS, &ops, NULL, pages, NFAKE, &n);
	gb10_pi_wire(pages, n, &ops, NULL);
	for (i = 8; i < 13; i++) { vm[i].object = 1; vm[i].valid = 2; vm[i].busy_other = 1; }
	unlock_budget = 3;
	pager_lets_go_at = -1;		/* never */
	f_rm_unlock_pages(pages, n, 1);
	check("five busy pages, budget 3: the teardown spins exactly 3 times in all", delay_calls, 3);
	check("... every page is still dirtied (the stock way) and counted", fallback_dirty == 5 && vm[8].dirty && vm[12].dirty, 1);
	vm_reset();
	gb10_pi_fill(s, 1, 5 * PS, PS, &ops, NULL, pages, NFAKE, &n);
	gb10_pi_wire(pages, n, &ops, NULL);
	for (i = 8; i < 13; i++) { vm[i].object = 1; vm[i].valid = 2; vm[i].busy_other = 1; }
	unlock_budget = 3;
	pager_lets_go_at = 3;		/* the pager lets go at the last delay of the budget: the cap */
	f_rm_unlock_pages(pages, n, 1);
	check("the pager lets go at delay 3 of a budget of 3: dirtied with the lock, nothing counted", fallback_dirty == 0 && vm[8].dirty == 1 && d_dirty_unbusied == 0, 1);
	vm_reset();
	gb10_pi_fill(s, 1, 5 * PS, PS, &ops, NULL, pages, NFAKE, &n);
	gb10_pi_wire(pages, n, &ops, NULL);
	for (i = 8; i < 13; i++) { vm[i].object = 1; vm[i].valid = 2; vm[i].busy_other = 1; }
	unlock_budget = 3;
	pager_lets_go_at = 4;		/* one past the cap: the budget is gone first */
	f_rm_unlock_pages(pages, n, 1);
	check("the pager lets go at delay 4 of a budget of 3: all five pages fall back (the budget is spent on the first)", fallback_dirty, 5);
	check("... and the budget is not exceeded", delay_calls, 3);
	vm_reset();
	gb10_pi_fill(s, 1, 5 * PS, PS, &ops, NULL, pages, NFAKE, &n);
	gb10_pi_wire(pages, n, &ops, NULL);
	for (i = 8; i < 13; i++) vm[i].busy_other = 1;	/* busy, but no object */
	pager_lets_go_at = -1;
	f_rm_unlock_pages(pages, n, 1);
	check("busy pages without an object are never waited for", delay_calls == 0 && fallback_dirty == 0 && refused_dirty == 0, 1);
	vm_reset();
	gb10_pi_fill(s, 1, PS, PS, &ops, NULL, pages, NFAKE, &n);
	gb10_pi_wire(pages, 1, &ops, NULL);
	vm[8].object = 1; vm[8].valid = 2; vm[8].busy_other = 1;
	{
		struct gb10_pi_dirty_ops nodelay = dirty_ops;
		int b = GB10_PI_DIRTY_SPIN_BUDGET;

		nodelay.delay = NULL;
		check("no delay operation: a busy object page falls back at once", gb10_pi_dirty_page(&vm[8], &nodelay, NULL, &b), GB10_PI_DIRTY_FALLBACK);
		check("... without spending the budget", b, GB10_PI_DIRTY_SPIN_BUDGET);
		check("no budget at all: the same, no spin", gb10_pi_dirty_page(&vm[8], &dirty_ops, NULL, NULL), GB10_PI_DIRTY_FALLBACK);
	}

	/* the unload gate: two holds, one release, the quiesce is still refused; a closed gate gives no hold */
	{
		struct gb10_pi_desc d1, d2;

		memset(&G, 0, sizeof(G));
		owner_refs = 0;
		live_seen_in_release = 0;
		memset(&d1, 0, sizeof(d1));
		d1.magic = GB10_PI_DESC_MAGIC; d1.count = 1; d1.pages = pages; d1.hold = gate_hold; d1.release = gate_release; d1.gate = &G;
		d2 = d1;
		check("a first export: the hold is taken", gb10_pi_import(&d1), GB10_PI_OK);
		check("a second export: the hold is taken", gb10_pi_import(&d2), GB10_PI_OK);
		check("two holds are live", gb10_pi_gate_live(&G), 2);
		gb10_pi_release(&d1);
		check("one release: one hold is still live", gb10_pi_gate_live(&G), 1);
		check("... and the release saw the count still up (it is counted down after the module's release returned)", live_seen_in_release, 2);
		check("the unload is refused while a hold is live", gb10_pi_gate_quiesce(&G), -1);
		check("... a refused quiesce does not close the gate", G.closing, 0);
		check("... so a new export is still given", gb10_pi_import(&d1), GB10_PI_OK);
		gb10_pi_release(&d1);
		gb10_pi_release(&d2);
		check("every hold released: none is live", gb10_pi_gate_live(&G), 0);
		check("... and the owner has no reference left", owner_refs, 0);
		check("the unload is agreed once none is live", gb10_pi_gate_quiesce(&G), 0);
		check("... and it closes the gate", G.closing, 1);
		check("a closed gate refuses a new export", gb10_pi_import(&d1), GB10_PI_CLOSING);
		check("... without taking a reference on the owner", owner_refs, 0);
		check("... and without counting a hold", gb10_pi_gate_live(&G), 0);
		{
			struct gb10_pi_desc dp;
			struct gb10_pi_gate G2;

			memset(&G2, 0, sizeof(G2));
			memset(&dp, 0, sizeof(dp));
			dp.magic = GB10_PI_DESC_MAGIC; dp.count = 1; dp.pages = pages; dp.hold = xd_hold; dp.release = poison_release; dp.gate = &G2;
			dp.ctx = &dp;
			gb10_pi_gate_hold(&G2);
			check("the import of the poisoned descriptor succeeds", gb10_pi_import(&dp), GB10_PI_OK);
			check("a release that frees the descriptor: the core never reads it afterwards (the gate was read first)", (gb10_pi_release(&dp), G2.holds), 0);
		}
		check("a gate whose teardown kept the devices refuses the quiesce for good", (memset(&G, 0, sizeof(G)), gb10_pi_gate_keep(&G), gb10_pi_gate_quiesce(&G)), -1);
		check("... and a kept gate is closed: no new export on a driver whose devices are gone", G.closing, 1);
		check("the closing result has a message", gb10_pi_str(GB10_PI_CLOSING) != NULL && strcmp(gb10_pi_str(GB10_PI_CLOSING), "unknown error") != 0, 1);
		/* one GEM object exported twice: two holds on one descriptor, two releases, a third does nothing */
		memset(&G, 0, sizeof(G));
		d1.gate = &G;
		d1.held = 0;
		gb10_pi_import(&d1);
		gb10_pi_import(&d1);
		check("two exports of one object: two holds are live", gb10_pi_gate_live(&G), 2);
		gb10_pi_release(&d1);
		check("the first release leaves one hold (the descriptor counts holds, not a flag)", gb10_pi_gate_live(&G), 1);
		gb10_pi_release(&d1);
		gb10_pi_release(&d1);
		check("the third release does nothing: no underflow", gb10_pi_gate_live(&G), 0);
		owner_refs = 0;
		check("a release without a hold (an import that was refused) does nothing: no underflow", (gb10_pi_release(&d1), gb10_pi_gate_live(&G)), 0);
		check("... and the owner is not released either", owner_refs, 0);
		memset(&G, 0, sizeof(G));
		d1.gate = NULL;
		gb10_pi_import(&d1);		/* G is not d1's gate any more: its count must not move */
		G.holds = 5;
		gb10_pi_release(&d1);
		check("a descriptor without a gate is released without counting anything", G.holds, 5);
	}

	/* a zero-length entry among good ones is refused wherever it sits */
	vm_reset();
	s[0] = seg(3, 0, PS);
	s[1] = seg(4, 0, 0);
	check("a zero-length entry after a good one: refused", gb10_pi_count(s, 2, PS, PS, &n), GB10_PI_NOT_WHOLE_PAGES);
	s[0] = seg(4, 0, 0);
	s[1] = seg(3, 0, PS);
	check("a zero-length entry before a good one: refused", gb10_pi_count(s, 2, PS, PS, &n), GB10_PI_NOT_WHOLE_PAGES);

	/* import, then the exporter's own mmap faults the wired page into an object, then close */
	vm_reset();
	s[0] = seg(8, 0, 2 * PS);
	gb10_pi_fill(s, 1, 2 * PS, PS, &ops, NULL, pages, NFAKE, &n);
	gb10_pi_wire(pages, n, &ops, NULL);
	vm[8].object = 1;	/* the fault path inserts the page ... */
	vm[8].valid = 2;	/* ... and validates it (a user-mmap fault does) */
	vm[9].object = 1;	/* a second page inserted but never validated */
	f_rm_unlock_pages(pages, n, 1);
	check("a page the exporter faulted in (object, valid) is dirtied correctly", vm[8].dirty, 1);
	check("... and it did not move the tripwire counters (only the invalid page counts)", refused_dirty + fallback_dirty, 1);
	check("a page inserted but not valid is not dirtied", vm[9].dirty, 0);
	check("... and the refusal is reported once", refused_dirty, 1);
	check("... no assertion fires and both pages are unwired", kassert_dirty == 0 && all_unwired(), 1);

	/*
	 * The exporter's mapping, in the three orders: a page it faulted in BEFORE
	 * the import is refused at the conversion; one it faults in DURING the
	 * import (after the check, before the wire) is refused at the wire; one it
	 * faults in AFTER the wiring (valid) is dirtied correctly at the release,
	 * see below.
	 */
	vm_reset();
	vm[10].object = 1;	/* mapped and touched before the import */
	vm[10].valid = 2;
	s[0] = seg(8, 0, 6 * PS);
	check("a page the exporter faulted in before the import: the conversion refuses the buffer",
	    gb10_pi_fill(s, 1, 6 * PS, PS, &ops, NULL, pages, NFAKE, &n), GB10_PI_NOT_RAM);
	check("... and nothing was wired", wire_calls, 0);
	check("... the tripwire counters did not move (refused at the conversion)", refused_dirty + fallback_dirty, 0);

	/* no check-then-wire race */
	vm_reset();
	s[0] = seg(8, 0, 6 * PS);
	gb10_pi_fill(s, 1, 6 * PS, PS, &ops, NULL, pages, NFAKE, &n);	/* all checked: no object */
	vm[11].object = 1;			/* a first-touch fault inserts page 11 into an object now */
	vm[11].valid = 1;
	rc = gb10_pi_wire(pages, n, &ops, NULL);
	check("a page that gained an object after the check: the wire is refused", rc, GB10_PI_PAGE_CHANGED);
	check("... without a wire of that page (no VM_OBJECT assertion)", kassert_wire, 0);
	check("... and the pages before it are unwired again", all_unwired(), 1);
	check("... and nothing is left busied", none_busy(), 1);
	check("... the tripwire counters did not move (refused at the wire)", refused_dirty + fallback_dirty, 0);
	vm_reset();
	gb10_pi_fill(s, 1, 6 * PS, PS, &ops, NULL, pages, NFAKE, &n);
	vm[10].busy_other = 1;			/* a fault holds the page busy: do not wait, refuse */
	rc = gb10_pi_wire(pages, n, &ops, NULL);
	check("a page busied by somebody else: the wire is refused as busy (retry)", rc, GB10_PI_PAGE_BUSY);
	check("... pages before it are unwired again", all_unwired() && wire_calls == 2, 1);
	check("... and the busy lock of a refused page is not ours to drop", none_busy() && vm[10].busy_other == 1, 1);
	vm_reset();
	gb10_pi_fill(s, 1, 6 * PS, PS, &ops, NULL, pages, NFAKE, &n);
	vm[9].fict = 1;				/* became fictitious: refused the same way */
	check("a page that became fictitious is refused at the wire", gb10_pi_wire(pages, n, &ops, NULL), GB10_PI_PAGE_CHANGED);
	vm_reset();
	gb10_pi_fill(s, 1, 6 * PS, PS, &ops, NULL, pages, NFAKE, &n);
	check("a wire without the busy and recheck ops is refused", gb10_pi_wire(pages, n, &(struct gb10_pi_ops){ .wire = f_wire, .unwire = f_unwire }, NULL), GB10_PI_BAD_ARG);
	check("... and wires nothing", wire_calls, 0);

	/* the single import check both modules call */
	check("claimable: plain managed RAM", gb10_pi_page_claimable(1, 0, 0), 1);
	check("claimable: not managed RAM (video memory)", gb10_pi_page_claimable(0, 0, 0), 0);
	check("claimable: fictitious", gb10_pi_page_claimable(1, 1, 0), 0);
	check("claimable: has a VM object", gb10_pi_page_claimable(1, 0, 1), 0);

	/*
	 * The export of an imported buffer wires it again, after the exporter's
	 * mapping may have faulted pages in: a wired page with an object is
	 * fine the second time, a fictitious one or one held busy is not.
	 */
	vm_reset();
	s[0] = seg(8, 0, 4 * PS);
	gb10_pi_fill(s, 1, 4 * PS, PS, &ops, NULL, pages, NFAKE, &n);
	memset(&d, 0, sizeof(d));
	d.magic = GB10_PI_DESC_MAGIC; d.count = n; d.pages = pages; d.hold = xd_hold; d.release = x_release;
	d.imported = 1;			/* the page-array import wired them for the RM */
	gb10_pi_wire(pages, n, &ops, NULL);	/* the first wiring, by the page-array import */
	vm[9].object = 1;			/* the exporter's mapping faulted page 9 in, validated */
	vm[9].valid = 2;
	for (i = 0; i < NFAKE; i++)
		phys[i] = 0xdeadbeefULL;
	rc = gb10_pi_register(&d, 4, phys, &ops, NULL);
	check("the export of a buffer a page of which the exporter faulted in: registers (not a retry, not a refusal)", rc, GB10_PI_OK);
	check("... every page wired twice and no assertion fired", vm[8].wired == 2 && vm[9].wired == 2 && kassert_wire == 0, 1);
	d.imported = 0;		/* a buffer that was never wired by us: the first-wiring rule applies, the object page is refused */
	rc = gb10_pi_register(&d, 4, phys, &ops, NULL);
	check("a buffer that was never imported is exported under the first-wiring rule: a page with an object is refused", rc, GB10_PI_PAGE_CHANGED);
	d.imported = 1;
	vm[10].fict = 1;
	rc = gb10_pi_register(&d, 4, phys, &ops, NULL);
	check("a page that went fictitious is refused for good (PAGE_CHANGED, not a retry)", rc, GB10_PI_PAGE_CHANGED);
	vm[10].fict = 0;
	vm[11].busy_other = 1;
	rc = gb10_pi_register(&d, 4, phys, &ops, NULL);
	check("a page the exporter holds busy: a retry (PAGE_BUSY)", rc, GB10_PI_PAGE_BUSY);

	/* the first page of an entry must be the page the entry names */
	vm_reset();
	alias_first = 1;
	s[0] = seg(8, 0, 2 * PS);
	check("a physical lookup that finds another page for index 0 is refused",
	    gb10_pi_fill(s, 1, 2 * PS, PS, &ops, NULL, pages, NFAKE, &n), GB10_PI_NOT_RAM);

	/* the page-count cap of nv_import_pages(), at the exact boundary */
	check("array cap: 1 page ok", gb10_pi_array_ok(1, PS), 1);
	check("array cap: exactly 4 GiB of 4 KiB pages ok", gb10_pi_array_ok(1ULL << 20, PS), 1);
	check("array cap: one page more is refused", gb10_pi_array_ok((1ULL << 20) + 1, PS), 0);
	check("array cap: 0 pages refused", gb10_pi_array_ok(0, PS), 0);
	check("array cap: 16 KiB pages, exactly 4 GiB ok", gb10_pi_array_ok(1ULL << 18, 16384), 1);
	check("array cap: 16 KiB pages, one more refused", gb10_pi_array_ok((1ULL << 18) + 1, 16384), 0);
	check("array cap: page size 0 refused", gb10_pi_array_ok(1, 0), 0);

	/* the exporter buffer lives as long as the RM maps it (SGT export) */
	vm_reset();
	gem_refs = 1;			/* the GEM handle's reference */
	src_freed = 0;
	s[0] = seg(8, 0, 6 * PS);
	gb10_pi_fill(s, 1, 6 * PS, PS, &ops, NULL, pages, NFAKE, &n);
	memset(&d, 0, sizeof(d));
	d.magic = GB10_PI_DESC_MAGIC;
	d.count = n;
	d.pages = pages;
	d.hold = g_hold;
	d.release = g_release;
	gb10_pi_import(&d);
	gb10_pi_register(&d, 6, phys, &ops, NULL);	/* the RM maps the export */
	g_release(NULL);		/* the process closes the GEM handle ... */
	check("handle and fd closed, source freed: the RM's reference keeps the buffer", src_freed, 0);
	check("... the pages are still wired for the RM", vm[8].wired == 1 && vm[13].wired == 1, 1);
	gb10_pi_unregister(&d, &ops, NULL);
	gb10_pi_release(&d);		/* the RM FD closes */
	check("the RM FD closed: the buffer is released exactly then", src_freed, 1);
	check("... and the pages are unwired", all_unwired(), 1);

	/*
	 * The whole lifetime of the import: B imports A's buffer and never
	 * re-exports it.  A closes its GEM handle and fd.  The exporter's pool
	 * reuses the pages once nobody holds the dma-buf.  B's GPU must not
	 * see a reused page while B's handle exists.
	 */
	vm_reset();
	dmabuf_refs = 1;		/* A's own reference (its handle, its fd) */
	pool_reused = 0;
	{
		struct gb10_pi_life life;

		memset(&life, 0, sizeof(life));
		life.hold = x_hold;
		life.release = x_release;
		s[0] = seg(8, 0, 4 * PS);
		gb10_pi_fill(s, 1, 4 * PS, PS, &ops, NULL, pages, NFAKE, &n);
		gb10_pi_wire(pages, n, &ops, NULL);	/* the page-array import: the RM has them */
		gb10_pi_life_take(&life);		/* taken at import, whatever happens to the handle later */
		check("the import holds the exporter's dma-buf", dmabuf_refs, 2);
		gb10_pi_life_take(&life);
		check("a second take does not hold twice", dmabuf_refs, 2);
		x_release(NULL);	/* A closes its handle and its fd, and frees the source */
		check("A is gone: the exporter's pool has not reused the pages", pool_reused, 0);
		/* B's handle is freed: the RM handle first (unlock), then the reference */
		unwire_saw_refs = -1;
		f_rm_unlock_pages(pages, n, 1);
		check("the last page is unwired while the exporter's dma-buf is still held", unwire_saw_refs > 0, 1);
		check("the RM handle is gone: pages unwired", all_unwired(), 1);
		check("... the exporter has not reused them before B lets go", pool_reused, 0);
		gb10_pi_life_drop(&life);
		check("B's handle freed: now the exporter may reuse the pages", pool_reused, 1);
		gb10_pi_life_drop(&life);
		check("a second drop releases nothing more", dmabuf_refs, 0);
		gb10_pi_life_drop(NULL);
		gb10_pi_life_take(NULL);
		memset(&life, 0, sizeof(life));
		gb10_pi_life_take(&life);
		check("a life without hold ops takes nothing and does not crash", life.held, 0);
	}

	vm_reset();
	fail_wire_at = 3;
	rc = gb10_pi_wire(pages, 0, &ops, NULL);
	check("wire of 0 pages: rc", rc, GB10_PI_BAD_ARG);
	s[0] = seg(8, 0, 6 * PS);
	gb10_pi_fill(s, 1, 6 * PS, PS, &ops, NULL, pages, NFAKE, &n);
	rc = gb10_pi_wire(pages, n, &ops, NULL);
	check("wire that fails at page 3: rc", rc, GB10_PI_WIRE_FAILED);
	check("wire that fails halfway leaves no page wired", all_unwired(), 1);
	check("wire that fails halfway: unwired exactly what it wired", unwire_calls, 3);

	vm_reset();
	gb10_pi_fill(s, 1, 6 * PS, PS, &ops, NULL, pages, NFAKE, &n);
	gb10_pi_wire(pages, n, &ops, NULL);
	gb10_pi_wire(pages, n, &ops, NULL);
	check("wired twice: count 2", vm[8].wired, 2);
	gb10_pi_unwire(pages, n, &ops, NULL);
	check("unwired once: count 1", vm[8].wired, 1);
	gb10_pi_unwire(pages, n, &ops, NULL);
	check("unwired twice: balanced", all_unwired(), 1);
	gb10_pi_unwire(pages, n, &ops, NULL);
	check("an unwire of an unwired page is caught by the fake", bad_unwire > 0, 1);

	/* (c) the SGT path */
	vm_reset();
	gb10_pi_fill(s, 1, 6 * PS, PS, &ops, NULL, pages, NFAKE, &n);
	memset(&d, 0, sizeof(d));
	d.magic = GB10_PI_DESC_MAGIC;
	d.count = n;
	d.pages = pages;
	d.hold = f_hold;
	d.release = f_release;
	check("a good descriptor is valid", gb10_pi_desc_valid(&d, 6), 1);
	d.magic ^= 1;
	check("a wrong magic is refused", gb10_pi_desc_valid(&d, 6), 0);
	d.magic = GB10_PI_DESC_MAGIC;
	check("a page count that disagrees with the RM is refused", gb10_pi_desc_valid(&d, 7), 0);
	d.pages = NULL;
	check("no pages is refused", gb10_pi_desc_valid(&d, 6), 0);
	d.pages = pages;
	d.hold = NULL;
	check("no hold is refused", gb10_pi_desc_valid(&d, 6), 0);
	d.hold = f_hold;
	d.release = NULL;
	check("no release is refused", gb10_pi_desc_valid(&d, 6), 0);
	d.release = f_release;
	check("NULL descriptor is refused", gb10_pi_desc_valid(NULL, 6), 0);

	for (i = 0; i < NFAKE + 1; i++)
		phys[i] = 0xdeadbeefULL;
	rc = gb10_pi_register(&d, 6, phys, &ops, NULL);
	check("register: rc", rc, GB10_PI_OK);
	check("register: pages wired", vm[8].wired == 1 && vm[13].wired == 1, 1);
	rc = 1;
	for (i = 0; i < 6; i++)
		if (phys[i] != 0x80000000ULL + (unsigned long long)(8 + i) * PS)
			rc = 0;
	check("register filled every physical address", rc, 1);
	check("register wrote nothing past the page count", phys[6] == 0xdeadbeefULL, 1);
	gb10_pi_unregister(&d, &ops, NULL);
	check("unregister unwires exactly what register wired", all_unwired(), 1);

	vm_reset();
	for (i = 0; i < NFAKE + 1; i++)
		phys[i] = 0xdeadbeefULL;
	rc = gb10_pi_register(&d, 7, phys, &ops, NULL);
	check("register with a page count mismatch: refused", rc != GB10_PI_OK, 1);
	check("register that is refused leaves the output untouched", phys[0] == 0xdeadbeefULL, 1);
	check("register that is refused wires nothing", wire_calls == 0 && all_unwired(), 1);

	vm_reset();
	fail_wire_at = 2;
	rc = gb10_pi_register(&d, 6, phys, &ops, NULL);
	check("register whose wire fails: rc", rc, GB10_PI_WIRE_FAILED);
	check("register whose wire fails leaves the output untouched", phys[0] == 0xdeadbeefULL, 1);
	check("register whose wire fails leaves nothing wired", all_unwired(), 1);
	fail_wire_at = -1;

	/* hold/release of the owner, in the sequences the RM runs */
	vm_reset();
	check("import (hold): rc", gb10_pi_import(&d), GB10_PI_OK);
	check("import holds the owner once", held, 1);
	rc = gb10_pi_register(&d, 6, phys, &ops, NULL);
	gb10_pi_unregister(&d, &ops, NULL);
	gb10_pi_release(&d);
	check("success path: hold and release balance", held, 0);
	check("success path: wire and unwire balance", all_unwired(), 1);

	vm_reset();
	gb10_pi_import(&d);
	fail_wire_at = 0;
	rc = gb10_pi_register(&d, 6, phys, &ops, NULL);
	gb10_pi_release(&d);	/* the RM calls nv_dma_release_sgt after a failed registration */
	check("register fails: hold and release balance", held, 0);
	check("register fails: nothing wired", all_unwired(), 1);
	fail_wire_at = -1;

	vm_reset();
	gb10_pi_import(&d);
	rc = gb10_pi_register(&d, 6, phys, &ops, NULL);
	gb10_pi_unregister(&d, &ops, NULL);	/* the IOMMU mapping failed after the registration */
	gb10_pi_release(&d);
	check("failure after the registration: hold and release balance", held, 0);
	check("failure after the registration: wire and unwire balance", all_unwired(), 1);

	vm_reset();
	d.magic ^= 1;
	check("import of a descriptor with a wrong magic is refused", gb10_pi_import(&d) != GB10_PI_OK, 1);
	check("a refused import holds nothing", held, 0);
	d.magic = GB10_PI_DESC_MAGIC;
	d.count = 0;
	check("import of a descriptor without pages is refused", gb10_pi_import(&d) != GB10_PI_OK, 1);
	check("a refused import holds nothing (no pages)", held, 0);
	check("import of NULL is refused", gb10_pi_import(NULL) != GB10_PI_OK, 1);
	check("release of NULL does nothing", (gb10_pi_release(NULL), held), 0);

	/* argument guards (coverage: every line of the header runs) */
	{
		int r, distinct = 1;

		int q;

		for (r = GB10_PI_OK; r < GB10_PI_RC_END; r++) {
			if (strcmp(gb10_pi_str(r), "unknown error") == 0)
				distinct = 0;
			for (q = r + 1; q < GB10_PI_RC_END; q++)
				if (strcmp(gb10_pi_str(r), gb10_pi_str(q)) == 0)
					distinct = 0;
		}
		check("every result code has its own, different message", distinct, 1);
	}
	gb10_pi_unwire(NULL, 1, &ops, NULL);
	gb10_pi_unregister(NULL, &ops, NULL);
	check("register with no output array is refused", gb10_pi_register(&d, 6, NULL, &ops, NULL), GB10_PI_BAD_ARG);
	check("register with no ops is refused", gb10_pi_register(&d, 6, phys, NULL, NULL), GB10_PI_BAD_ARG);
	{
		struct gb10_pi_life l;
		int before = dmabuf_refs;

		memset(&l, 0, sizeof(l));
		l.hold = x_hold;
		l.release = x_release;	/* ctx stays NULL */
		gb10_pi_life_take(&l);
		check("a life with a NULL ctx holds once", dmabuf_refs, before + 1);
		gb10_pi_life_drop(&l);
		check("... and balances on the drop", dmabuf_refs, before);
	}

	printf("failures: %d\n", failures);
	return failures ? 1 : 0;
}
EOF

cc_prog() {
	# cc_prog <header-dir> <out>
	cc -std=c99 -Wall -Wextra -Wno-unused-parameter -Werror -O1 -I"$1" -o "$2" "$TESTROOT/pi_test.c" 2> "$TESTROOT/cc.err"
}

mkdir -p "$TESTROOT/good"
cp "$HEADER" "$TESTROOT/good/gb10_pageimport.h"
if cc_prog "$TESTROOT/good" "$TESTROOT/pi_good"; then
	ok "the test program compiles against the header (-Wall -Wextra -Werror)"
else
	fail "the test program does not compile: $(head -5 "$TESTROOT/cc.err" | tr '\n' ' ')"
	echo "pageimport_test: FAIL (passed $PASSED, failed $FAILED)"
	exit 1
fi

if "$TESTROOT/pi_good" > "$TESTROOT/good.out" 2>&1; then
	ok "every conversion, balance and SGT check passes ($(grep -c '^ok' "$TESTROOT/good.out") checks)"
else
	fail "the header fails its own tests:"
	grep '^FAIL' "$TESTROOT/good.out" | head -20
fi

# --- controls: each mutant of the header must fail the program ------------
# mutate <name> <sed-script>: apply the script to a copy of the header, make
# sure the copy differs, build the program against it and expect a failure.
mutate() {
	_n=$1
	_d="$TESTROOT/m-$_n"
	mkdir -p "$_d"
	sed -e "$2" "$HEADER" > "$_d/gb10_pageimport.h"
	if cmp -s "$HEADER" "$_d/gb10_pageimport.h"; then
		fail "control $_n: the mutation did not change the header (stale test)"
		return
	fi
	if ! cc_prog "$_d" "$_d/prog"; then
		fail "control $_n: the mutant does not compile: $(head -3 "$TESTROOT/cc.err" | tr '\n' ' ')"
		return
	fi
	if "$_d/prog" > "$_d/out" 2>&1; then
		fail "control $_n: the mutant PASSED - the test cannot see this defect"
	else
		ok "control $_n: the mutant is caught ($(grep -c '^FAIL' "$_d/out") checks fail)"
	fi
}

mutate no-overflow-check       's/if (segs\[i\].length > size - sum)/if (0)/'
mutate no-oversize-limit       's/if (size > GB10_PI_MAX_BYTES)/if (0)/'
mutate no-offset-check         's/if (segs\[i\].offset != 0)/if (0)/'
mutate no-sum-check            's/if (sum != size)/if (0)/'
mutate no-ram-check            's/if (pg == NULL)/if (0)/'
mutate no-page-check           's/if (segs\[i\].first == NULL)/if (0)/'
mutate no-capacity-check       's/if (cap < total)/if (0)/'
mutate no-rollback             's/while (i-- > 0)/while (0)/'
mutate unwire-is-noop          's/ops->unwire(ctx, pages\[k\]);/;/'
mutate register-fills-nothing  's/phys_out\[i\] = ops->phys(ctx, d->pages\[i\]);/;/'
mutate register-skips-count    's/d->count != page_count/0/'
mutate register-skips-magic    's/d->magic != GB10_PI_DESC_MAGIC)$/0)/'
mutate import-skips-validation 's/if (!gb10_pi_desc_ok(d))$/if (0)/'
mutate release-never-called    's/\td->release(d->ctx);/\t;/'
mutate release-without-hold-counts 's/		if (h <= 0)/		if (0)/'
mutate held-is-a-flag          's/__atomic_add_fetch(&d->held, 1, __ATOMIC_SEQ_CST);/d->held = 1;/'
mutate import-does-not-mark-held 's/^	__atomic_add_fetch(&d->held, 1, __ATOMIC_SEQ_CST);$/	;/'
mutate hold-never-called       's/if (d->hold(d->ctx) != 0)/if (0)/'
mutate register-wires-nothing  's/rc = gb10_pi_wire_mode(d->pages, d->count, ops, ctx, d->imported != 0);/rc = GB10_PI_OK;/'
mutate register-always-first-wire-rule 's/gb10_pi_wire_mode(d->pages, d->count, ops, ctx, d->imported != 0)/gb10_pi_wire_mode(d->pages, d->count, ops, ctx, 0)/'
mutate register-ignores-imported-flag 's/gb10_pi_wire_mode(d->pages, d->count, ops, ctx, d->imported != 0)/gb10_pi_wire_mode(d->pages, d->count, ops, ctx, 1)/'
mutate rewire-ignores-fictitious 's/if (!(rewire ? ops->rewire_ok(ctx, pages\[i\]) :/if (!(rewire ? 1 :/'
mutate claimable-ignores-object 's/return (is_managed_ram \&\& !is_fictitious \&\& !has_object);/return (is_managed_ram \&\& !is_fictitious);/'
mutate claimable-ignores-fictitious 's/return (is_managed_ram \&\& !is_fictitious \&\& !has_object);/return (is_managed_ram \&\& !has_object);/'
mutate claimable-ignores-ram   's/return (is_managed_ram \&\& !is_fictitious \&\& !has_object);/return (!is_fictitious \&\& !has_object);/'
mutate dirty-unbusies-foreign-lock 's/^\tif (busied)$/\tif (busied || !obj)/'
mutate dirty-budget-cap-plus-one 's/\*budget > 0 \&\&/*budget >= 0 \&\&/'
mutate dirty-budget-cap-minus-one 's/\*budget > 0 \&\&/*budget > 1 \&\&/'
mutate dirty-spins-without-object 's/obj = o->has_object(ctx, page);/obj = 1;/'
mutate recheck-before-busy 's/if (ops->try_busy(ctx, pages\[i\]) != 0) {/if (!(rewire ? ops->rewire_ok(ctx, pages[i]) : ops->claimable(ctx, pages[i]))) { rc = GB10_PI_PAGE_CHANGED; goto undo; } if (ops->try_busy(ctx, pages[i]) != 0) {/'
mutate dirty-fallback-uncounted 's/act = GB10_PI_DIRTY_FALLBACK;/;/'
mutate dirty-never-unbusies    's/^\t\to->unbusy(ctx, page);$/\t\t;/'
mutate dirty-needs-busy-to-dirty 's/^\tif (act == GB10_PI_DIRTY_DO)$/\tif (act == GB10_PI_DIRTY_DO \&\& busied)/'
mutate wire-unbusies-foreign-busy 's/^\t\tif (ops->try_busy(ctx, pages\[i\]) != 0) {$/\t\tif (ops->try_busy(ctx, pages[i]) != 0) { ops->unbusy(ctx, pages[i]);/'
mutate messages-duplicated     's/"out of memory"/"empty buffer"/'
mutate life-ignores-held       's/if (l == NULL || l->held || l->hold == NULL/if (l == NULL || l->hold == NULL/'
mutate gate-drop-sets-one      's/__atomic_sub_fetch(&g->holds, 1, __ATOMIC_SEQ_CST);/__atomic_store_n(\&g->holds, 1, __ATOMIC_SEQ_CST);/'
mutate gate-quiesce-ignores-holds 's/if (__atomic_load_n(&g->holds, __ATOMIC_SEQ_CST) > 0 ||/if (0 ||/'
mutate release-reads-descriptor-after 's/^\tg = d->gate;.*$/\tg = NULL;/;s/^\td->release(d->ctx);$/\td->release(d->ctx); g = d->gate;/'
mutate gate-keep-is-ignored    's/\t    __atomic_load_n(&g->kept, __ATOMIC_SEQ_CST))/\t    0)/'
mutate gate-keep-sets-nothing  's/__atomic_store_n(&g->kept, 1, __ATOMIC_SEQ_CST);/;/'
mutate gate-quiesce-never-closes 's/__atomic_store_n(&g->closing, 1, __ATOMIC_SEQ_CST);/;/'
mutate gate-hold-ignores-closing 's/if (__atomic_load_n(&g->closing, __ATOMIC_SEQ_CST))/if (0)/'
mutate gate-hold-not-counted   's/__atomic_add_fetch(&g->holds, 1, __ATOMIC_SEQ_CST);/;/'
mutate gate-counts-down-before-release 's/^\td->release(d->ctx);$/\tif (g != NULL) gb10_pi_gate_drop(g); d->release(d->ctx); g = NULL;/'
mutate gate-refused-hold-imports 's/if (d->hold(d->ctx) != 0)/if (d->hold(d->ctx) != 0 \&\& 0)/'
mutate wire-no-recheck         's/ops->claimable(ctx, pages\[i\])/1/'
mutate wire-no-busy            's/if (ops->try_busy(ctx, pages\[i\]) != 0) {/if (0) {/'
mutate busy-reported-as-changed 's/rc = GB10_PI_PAGE_BUSY;/rc = GB10_PI_PAGE_CHANGED;/'
mutate wire-leaves-busy        's/^\t\tops->unbusy(ctx, pages\[i\]);$/\t\t;/'
mutate wire-no-wire-fail-unbusy 's/if (ops->wire(ctx, pages\[i\]) != 0) {/if (0) {/'
mutate dirty-always            's/return (all_valid ? GB10_PI_DIRTY_DO : GB10_PI_DIRTY_REFUSE);/return (GB10_PI_DIRTY_DO);/'
mutate dirty-no-object-check   's/if (!has_object)/if (0)/'
mutate dirty-refuse-is-skip     's/GB10_PI_DIRTY_DO : GB10_PI_DIRTY_REFUSE/GB10_PI_DIRTY_DO : GB10_PI_DIRTY_SKIP/'
mutate array-cap-plus-one      's/count <= GB10_PI_MAX_BYTES \/ page_size/count <= GB10_PI_MAX_BYTES \/ page_size + 1/'
mutate array-cap-minus-one     's/count <= GB10_PI_MAX_BYTES \/ page_size/count < GB10_PI_MAX_BYTES \/ page_size/'
mutate array-accepts-zero      's/page_size == 0 || count == 0/page_size == 0/'
mutate no-index0-check         's/if (j == 0 \&\& pg != segs\[i\].first)/if (0)/'
mutate index0-check-every-page 's/if (j == 0 \&\& pg != segs\[i\].first)/if (pg != segs[i].first)/'
mutate life-never-takes        's/^\tl->hold(l->ctx);$/\t;/'
mutate life-never-drops        's/^\tl->release(l->ctx);$/\t;/'
mutate life-drops-twice        's/^\tl->held = 0;$/\t;/'

# --- coverage gate: every line of the pure core must run (testing standard, rule 4) ---
# Branch coverage is reported and not gated, on purpose (docs/PRIME-IMPORT.md
# 7.7): the argument guards test several pointers on one line, and the
# mutants above (one per decision of the core) cover what a branch gate
# would.  Lines are gated at 100 percent, and the gate has a self-test: a
# header with a line that never runs must fail it.
# cov_missed <header dir> <program source>: print the number of lines of
# gb10_pageimport.h that never ran, or "error".
cov_missed() {
	_cd=$1
	rm -f "$_cd/p.profraw" "$_cd/p.profdata" "$_cd/report"
	if cc -std=c99 -O0 -fprofile-instr-generate -fcoverage-mapping -I"$_cd" -o "$_cd/prog" "$TESTROOT/pi_test.c" 2> "$_cd/cc.err" \
	    && LLVM_PROFILE_FILE="$_cd/p.profraw" "$_cd/prog" > /dev/null 2>&1 \
	    && llvm-profdata merge -o "$_cd/p.profdata" "$_cd/p.profraw" 2>> "$_cd/cc.err" \
	    && llvm-cov report "$_cd/prog" -instr-profile="$_cd/p.profdata" "$_cd/gb10_pageimport.h" > "$_cd/report" 2>> "$_cd/cc.err"; then
		awk '$1 ~ /gb10_pageimport\.h$/ { print $9 }' "$_cd/report"
	else
		echo error
	fi
}
if command -v llvm-cov > /dev/null 2>&1 && command -v llvm-profdata > /dev/null 2>&1; then
	_c="$TESTROOT/cov"
	mkdir -p "$_c"
	cp "$HEADER" "$_c/gb10_pageimport.h"
	_missed=$(cov_missed "$_c")
	if [ "$_missed" = 0 ]; then
		ok "coverage gate: every line of gb10_pageimport.h runs ($(awk '$1 ~ /gb10_pageimport\.h$/ { print $10 " lines, " $13 " branches" }' "$_c/report"))"
	else
		case $_missed in
		error) fail "coverage gate: the instrumented build or run failed: $(head -2 "$_c/cc.err" | tr '\n' ' ')" ;;
		*) fail "coverage gate: ${_missed:-?} lines of gb10_pageimport.h never run" ;;
		esac
		llvm-cov show "$_c/prog" -instr-profile="$_c/p.profdata" "$_c/gb10_pageimport.h" 2>/dev/null | grep -E '^ +[0-9]+\| +0\|' | head -10
	fi
	# self-test: a header with a function nothing calls must be caught
	_d="$TESTROOT/cov-plant"
	mkdir -p "$_d"
	sed -e 's|^#endif /\* _GB10_PAGEIMPORT_H_ \*/|static inline int gb10_pi_planted_dead(int x)\n{\n\tif (x)\n\t\treturn (1);\n\treturn (0);\n}\n\n#endif /* _GB10_PAGEIMPORT_H_ */|' "$HEADER" > "$_d/gb10_pageimport.h"
	if cmp -s "$HEADER" "$_d/gb10_pageimport.h"; then
		fail "coverage gate self-test: the planted header equals the original (stale test)"
	else
		_pm=$(cov_missed "$_d")
		case $_pm in
		error) fail "coverage gate self-test: the planted header did not build or run: $(head -2 "$_d/cc.err" | tr '\n' ' ')" ;;
		''|0) fail "coverage gate self-test: a header with a line that never runs passed the gate ($_pm)" ;;
		*) ok "coverage gate self-test: a planted line that never runs is caught ($_pm lines)" ;;
		esac
	fi
else
	fail "coverage gate: llvm-cov and llvm-profdata are required"
fi

echo "pageimport_test: passed $PASSED, failed $FAILED"
[ "$FAILED" -eq 0 ] && echo "PASS"
[ "$FAILED" -eq 0 ]

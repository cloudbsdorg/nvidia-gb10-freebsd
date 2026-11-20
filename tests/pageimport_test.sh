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
WORK=${GB10_WORK:-$HOME/work/gb10}
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
	int wire_fail_after;	/* -1: never; else fail the wire call when count hits it */
	unsigned long long pa;
};

static struct fake_page vm[NFAKE];
static int wire_calls, unwire_calls, bad_unwire, fail_wire_at = -1;
static int held;

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
	fail_wire_at = -1;
}

static void *
f_page_at(void *ctx, void *first, unsigned long long index)
{
	long base = (struct fake_page *)first - vm;
	unsigned long long at;

	(void)ctx;
	at = (unsigned long long)base + index;
	if (base < 0 || at >= NFAKE || !vm[at].ram)
		return NULL;
	return &vm[at];
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
	p->wired++;
	return 0;
}

static void
f_unwire(void *ctx, void *page)
{
	struct fake_page *p = page;

	(void)ctx;
	unwire_calls++;
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

static const struct gb10_pi_ops ops = {
	.page_at = f_page_at, .wire = f_wire, .unwire = f_unwire, .phys = f_phys,
};

static void f_hold(void *ctx) { (void)ctx; held++; }
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
	for (i = 0; (unsigned long long)i < n; i++)	/* the model of os_unlock_user_pages */
		f_unwire(NULL, pages[i]);
	check("after the RM's teardown every page is unwired", all_unwired(), 1);

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
mutate hold-never-called       's/\td->hold(d->ctx);/\t;/'
mutate register-wires-nothing  's/rc = gb10_pi_wire(d->pages, d->count, ops, ctx);/rc = GB10_PI_OK;/'

echo "pageimport_test: passed $PASSED, failed $FAILED"
[ "$FAILED" -eq 0 ] && echo "PASS"
[ "$FAILED" -eq 0 ]

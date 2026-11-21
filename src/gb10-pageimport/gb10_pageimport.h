/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-3-Clause
 *
 * gb10_pageimport.h - the pure core of the cross-GPU buffer import (PRIME)
 * on FreeBSD (Track #2228, docs/PRIME-IMPORT.md).
 *
 * A buffer rendered on another GPU reaches nvidia-drm as a scatter list of
 * pages.  The RM's page-array memory descriptor wants an array of vm_page
 * pointers, one per page, wired for as long as the RM holds them.  This
 * header holds the three pieces of logic between the two, with no kernel
 * includes and no globals, so tests/pageimport_test.sh compiles it into a
 * userland program with a fake VM and checks it:
 *
 *   1. conversion: gb10_pi_count() and gb10_pi_fill() turn scatter-list
 *      entries into the page array, and refuse anything that is not a whole
 *      number of managed RAM pages (partial pages, a buffer whose pages are
 *      video memory, an empty or oversized buffer, entries that disagree
 *      with the size).  An entry may span several pages; each is expanded.
 *   2. wiring: gb10_pi_wire() wires every page or none of them, and
 *      gb10_pi_unwire() undoes exactly that.  Each page is busied, checked
 *      again (no VM object, not fictitious: a check made earlier, in another
 *      module, can be stale by now), wired, then unbusied; one page that
 *      fails refuses the whole array.  The RM's own teardown of a page-array
 *      descriptor (os_unlock_user_pages) unwires one reference per page of
 *      the array it was given, so what is handed over must have been wired
 *      once per page here.  The same teardown dirties a page only when
 *      gb10_pi_dirty_action() allows it, checked at the dirty site.
 *      gb10_pi_life_take()/gb10_pi_life_drop() hold the exporter's object
 *      (the dma-buf) for the whole life of the import.
 *   3. the SGT entry points of the OS layer, for a buffer that is already
 *      imported and is exported again: gb10_pi_import(),
 *      gb10_pi_register(), gb10_pi_unregister() and gb10_pi_release() are
 *      the logic of nv_dma_import_sgt(), nv_register_sgt(),
 *      nv_unregister_sgt() and nv_dma_release_sgt().  The "sg_table" the RM
 *      passes through is a struct gb10_pi_desc.
 *
 * The kernel side supplies the ops table: page_at() (the page `index` pages
 * after `first`, or NULL when it is not a managed RAM page: kernel side
 * vm_phys_paddr_to_vm_page() and not fictitious), wire() (vm_page_wire()),
 * unwire() (vm_page_unwire(m, PQ_ACTIVE), the call os_unlock_user_pages()
 * makes) and phys() (VM_PAGE_TO_PHYS()).
 *
 * Types are unsigned long long and void pointers on purpose: this file must
 * compile in nvidia.ko, in nvidia-drm.ko (linuxkpi) and in a userland test.
 */

#ifndef _GB10_PAGEIMPORT_H_
#define	_GB10_PAGEIMPORT_H_

#ifndef NULL
#define	NULL	((void *)0)
#endif

/*
 * The KAPI takes the size as "limit", an NvU32 equal to size - 1, so a
 * buffer of more than 4 GiB cannot be described to it.
 */
#define	GB10_PI_MAX_BYTES	(1ULL << 32)

/*
 * The OS layer entry points nvidia-drm.ko takes from nvidia.ko (exported by
 * EXPORT_SYMS).  Declared here once, with the types nvidia.ko defines them
 * with (NV_STATUS is NvU32, NvU64 is unsigned long long), so that a change
 * to either side fails to compile in nvidia.ko instead of at run time.
 */
unsigned int nv_import_pages(void **pages, unsigned long long count, void **array);
void nv_unimport_pages(void *array, unsigned long long count);

/*
 * The same, for nvidia_subr.c and nvidia_os.c, which call into
 * gb10_pageimport_os.c (the FreeBSD side) rather than carry the code.
 */
#define	GB10_PI_STATUS_RETRY	3U	/* NV_ERR_BUSY_RETRY; gb10_pageimport_os.c asserts it */
#define	GB10_PI_STATUS_REFUSED	0x56U	/* NV_ERR_NOT_SUPPORTED: a page changed for good */

unsigned int gb10_pi_os_register(void *import_sgt, unsigned long long page_count,
    unsigned long long *phys_addr, void **priv_data, int is_peer_mmio);
void gb10_pi_os_unregister(void *priv_data, void **import_sgt,
    void **import_priv);
unsigned int gb10_pi_os_import(void *sgt);
void gb10_pi_os_release(void *sgt);
void gb10_pi_os_dirty(void *page, int *spin_budget);

/* Not a kernel address (the top bits are clear), so it cannot be a pointer. */
#define	GB10_PI_DESC_MAGIC	0x0000474232305049ULL	/* "IP02BG": the layout and the hold signature of version 2 */

enum gb10_pi_rc {
	GB10_PI_OK = 0,
	GB10_PI_BAD_ARG,		/* a NULL or an impossible argument */
	GB10_PI_EMPTY,			/* no entries or no bytes */
	GB10_PI_NOT_WHOLE_PAGES,	/* an entry or the size is not whole pages */
	GB10_PI_NOT_RAM,		/* a page is missing or not managed RAM */
	GB10_PI_SIZE_MISMATCH,		/* the entries do not add up to the size */
	GB10_PI_OVERSIZE,		/* more than the KAPI's 32-bit limit */
	GB10_PI_CAPACITY,		/* the output array is too small */
	GB10_PI_WIRE_FAILED,		/* a page could not be wired */
	GB10_PI_NOMEM,			/* an allocation failed (the caller's) */
	GB10_PI_PAGE_CHANGED,		/* a page got an object or went fictitious since the check: permanent for this import */
	GB10_PI_PAGE_BUSY,		/* somebody else holds a page's busy lock right now: transient, retry */
	GB10_PI_CLOSING,		/* the module is being unloaded: no new hold */
	GB10_PI_RC_END			/* not a result: one past the last, for loops */
};

/*
 * One scatter-list entry: its first page, the offset into it, the length.
 * (Not named "page": linuxkpi defines page as vm_page.)
 */
struct gb10_pi_seg {
	void			*first;
	unsigned long long	offset;
	unsigned long long	length;
};

struct gb10_pi_ops {
	void *(*page_at)(void *ctx, void *first, unsigned long long index);
	int (*wire)(void *ctx, void *page);		/* 0 on success */
	void (*unwire)(void *ctx, void *page);
	unsigned long long (*phys)(void *ctx, void *page);
	/* gb10_pi_wire() only: busy the page without waiting (0 on success) ... */
	int (*try_busy)(void *ctx, void *page);
	void (*unbusy)(void *ctx, void *page);
	/* ... and, with the page busied, is it still one we may wire the first time? (the same decision in both modules: gb10_pi_page_claimable()) */
	int (*claimable)(void *ctx, void *page);
	/*
	 * ... or wire again (the SGT export of a buffer already imported): the
	 * page is wired by us, so it may have gained an object since (the
	 * exporter's own mapping faults pages in, and validates them); it must
	 * still be wired and not fictitious.  Busied, a wired page with an
	 * object can be wired once more.
	 */
	int (*rewire_ok)(void *ctx, void *page);
};

/*
 * The unload gate of a module whose functions the RM calls back into (the
 * hold and release of an export live in nvidia-drm.ko, the RM file descriptor
 * that holds the export can outlive everything else).  `holds` counts the
 * exports the RM holds; `closing` is set by the first quiesce that finds
 * none, and from then on no new hold is given.  The caller serialises
 * gb10_pi_gate_hold() and gb10_pi_gate_quiesce() with one lock (the check
 * of `closing` and the increment, and the check of `holds` and the setting
 * of `closing`, must not interleave); the drop is a plain atomic decrement,
 * done by gb10_pi_release() in the text of nvidia.ko after the module's
 * own release function has returned, so that no instruction of the module
 * runs after the count reaches zero.
 */
struct gb10_pi_gate {
	int	holds;
	int	closing;
	int	kept;		/* the driver was torn down while an export was held and the devices were kept (only if it unloads before the guard): no new export, and every later quiesce refuses */
};

/* take a hold: 0, or -1 when the gate is closing (nothing is counted) */
static inline int
gb10_pi_gate_hold(struct gb10_pi_gate *g)
{
	if (__atomic_load_n(&g->closing, __ATOMIC_SEQ_CST))
		return (-1);
	__atomic_add_fetch(&g->holds, 1, __ATOMIC_SEQ_CST);
	return (0);
}

/* the unload asks: -1 (busy) while any hold is live, else close the gate and 0 */
static inline int
gb10_pi_gate_quiesce(struct gb10_pi_gate *g)
{
	if (__atomic_load_n(&g->holds, __ATOMIC_SEQ_CST) > 0 ||
	    __atomic_load_n(&g->kept, __ATOMIC_SEQ_CST))
		return (-1);
	__atomic_store_n(&g->closing, 1, __ATOMIC_SEQ_CST);
	return (0);
}

/* the teardown kept the devices (the driver unloaded before the guard): close the gate, and the guard's own unload and every later quiesce refuse */
static inline void
gb10_pi_gate_keep(struct gb10_pi_gate *g)
{
	__atomic_store_n(&g->kept, 1, __ATOMIC_SEQ_CST);
	__atomic_store_n(&g->closing, 1, __ATOMIC_SEQ_CST);	/* and no new export on a driver whose devices are gone */
}

static inline int
gb10_pi_gate_live(const struct gb10_pi_gate *g)
{
	return (__atomic_load_n(&g->holds, __ATOMIC_SEQ_CST));
}

static inline void
gb10_pi_gate_drop(struct gb10_pi_gate *g)
{
	__atomic_sub_fetch(&g->holds, 1, __ATOMIC_SEQ_CST);
}

/*
 * What the OS layer receives in place of a Linux struct sg_table: the
 * pages of a buffer that nvidia-drm imported, and the owner that keeps the
 * buffer alive while the RM holds it (hold/release take and drop a
 * reference on the GEM object, as the Linux driver does).
 */
struct gb10_pi_desc {
	unsigned long long	magic;		/* GB10_PI_DESC_MAGIC */
	unsigned long long	count;		/* number of pages */
	void			**pages;
	void			*ctx;		/* the owner, given to hold/release */
	int			(*hold)(void *ctx);	/* 0, or non-zero to refuse (the module is closing) */
	void			(*release)(void *ctx);
	struct gb10_pi_gate	*gate;		/* counted by gb10_pi_release(); may be NULL */
	int			held;		/* holds taken by successful gb10_pi_import() calls minus releases (one GEM object can be exported twice): a release with none held does nothing */
	/*
	 * Set once the pages were wired for the RM by the page-array import.
	 * Only then may the SGT export wire them again under the second-wiring
	 * rule (a page may have an object by now); a buffer that was never
	 * wired by us is checked like a first wiring.
	 */
	int			imported;
};

static inline const char *
gb10_pi_str(int rc)
{
	switch (rc) {
	case GB10_PI_OK:		return "ok";
	case GB10_PI_BAD_ARG:		return "bad argument";
	case GB10_PI_EMPTY:		return "empty buffer";
	case GB10_PI_NOT_WHOLE_PAGES:	return "not a whole number of pages";
	case GB10_PI_NOT_RAM:		return "a page is not system memory this driver can wire (video memory or a VM-object page)";
	case GB10_PI_SIZE_MISMATCH:	return "scatter list does not match the buffer size";
	case GB10_PI_OVERSIZE:		return "buffer larger than 4 GiB";
	case GB10_PI_CAPACITY:		return "output array too small";
	case GB10_PI_WIRE_FAILED:	return "a page could not be wired";
	case GB10_PI_NOMEM:		return "out of memory";
	case GB10_PI_PAGE_CHANGED:	return "a page changed while it was being imported (it got a VM object or became fictitious)";
	case GB10_PI_PAGE_BUSY:		return "a page is busy (the exporter's mapping holds it); retry";
	case GB10_PI_CLOSING:		return "this display driver refuses new exports until the next boot, because an unload was started (reboot, or do not unload it)";
	default:			return "unknown error";
	}
}

/* Only an allocation failure is ENOMEM; every refusal is EINVAL. */
static inline int
gb10_pi_is_nomem(int rc)
{
	return (rc == GB10_PI_NOMEM);
}

/*
 * gb10_pi_array_ok - may `count` pages of `page_size` bytes be handed to the
 * KAPI?  The limit is 4 GiB, exactly (GB10_PI_MAX_BYTES), and at least one page.
 */
static inline int
gb10_pi_array_ok(unsigned long long count, unsigned long long page_size)
{
	if (page_size == 0 || count == 0)
		return (0);
	return (count <= GB10_PI_MAX_BYTES / page_size);
}

/*
 * gb10_pi_page_claimable - the one place that decides whether a page may be
 * imported: it must be managed RAM, not fictitious and have no VM object (a
 * page that belongs to one can only be wired with the object locked, and
 * can be renamed or freed under us; the pages of a GPU driver's buffers,
 * which linuxkpi allocates without an object, are the ones we take).
 * nvidia-drm.ko asks it when it converts the scatter list, nvidia.ko again
 * with the page busied just before it wires it.
 */
static inline int
gb10_pi_page_claimable(int is_managed_ram, int is_fictitious, int has_object)
{
	return (is_managed_ram && !is_fictitious && !has_object);
}

/*
 * What the RM's teardown does with the dirty bit of one imported page
 * (gb10_pi_dirty_action()).
 */
enum gb10_pi_dirty {
	GB10_PI_DIRTY_SKIP = 0,		/* no VM object: no pager, nothing to write back */
	GB10_PI_DIRTY_DO,		/* object and all valid: vm_page_dirty() is correct */
	GB10_PI_DIRTY_REFUSE,		/* object but not all valid: refuse, and say so */
	GB10_PI_DIRTY_FALLBACK		/* the busy lock could not be had and the page was dirtied without it, the way the stock code did; counted */
};

/*
 * gb10_pi_dirty_action - decide the dirty step of os_unlock_user_pages().
 * vm_page_dirty() asserts that the page is all valid (INVARIANTS; without
 * the assertion it would silently mark an invalid page dirty).  A page with
 * no object (the noobj pages of another GPU driver) has no pager and is
 * skipped quietly.  A page that has an object but is not all valid is not
 * dirtied either, and the OS layer logs the refusal rather than panic: it
 * can only mean the exporter's own mapping faulted the page into an object
 * and a truncate or a partial fill left it invalid, the exporter's data is
 * not ours to mark.  The caller asks at the dirty site, with the page
 * busied: a wired page can gain an object after the wiring, and can be
 * invalidated, so an earlier check proves nothing.
 */
static inline int
gb10_pi_dirty_action(int has_object, int all_valid)
{
	if (!has_object)
		return (GB10_PI_DIRTY_SKIP);
	return (all_valid ? GB10_PI_DIRTY_DO : GB10_PI_DIRTY_REFUSE);
}

/*
 * The spin of the dirty step: GB10_PI_DIRTY_SPIN_BUDGET delays of
 * GB10_PI_DIRTY_SPIN_US microseconds in all, for the whole teardown of one
 * descriptor (the caller owns the budget and passes it for every page), so
 * that a descriptor of many busy pages costs about a millisecond and not a
 * millisecond per page, under the RM API lock.
 */
#define	GB10_PI_DIRTY_SPIN_BUDGET	100
#define	GB10_PI_DIRTY_SPIN_US		10

/*
 * The OS operations of the dirty step.  The step runs for every page of every
 * writable RM user-page descriptor (the RM's own pinned user memory too, not
 * only imported pages), so it must not lose a dirty bit the stock code would
 * have set.
 */
struct gb10_pi_dirty_ops {
	int (*try_busy)(void *ctx, void *page);		/* 0 on success, no wait */
	void (*delay)(void *ctx, void *page);		/* one short busy-wait (never a sleep); NULL for none */
	void (*unbusy)(void *ctx, void *page);
	int (*has_object)(void *ctx, void *page);
	int (*all_valid)(void *ctx, void *page);
	void (*dirty)(void *ctx, void *page);
};

/*
 * gb10_pi_dirty_page - the dirty step for one page: busy it, ask
 * gb10_pi_dirty_action() at the dirty site, dirty, unbusy.  When the busy lock
 * is held by somebody else and the page has an object, spin (ops->delay) while
 * *budget lasts, one unit per delay; a page without an object is never
 * waited for (the step skips it anyway).  When the lock stays held, the
 * question is asked without it and an all-valid object page is dirtied the way
 * the stock code did, and the result says so (GB10_PI_DIRTY_FALLBACK), so the
 * caller can count it: a dirty bit is never dropped silently.
 */
static inline int
gb10_pi_dirty_page(void *page, const struct gb10_pi_dirty_ops *o, void *ctx,
    int *budget)
{
	int busied, act, obj;

	if (o == NULL || o->try_busy == NULL || o->unbusy == NULL ||
	    o->has_object == NULL || o->all_valid == NULL || o->dirty == NULL)
		return (GB10_PI_DIRTY_REFUSE);	/* never a silent skip: it is counted */
	busied = (o->try_busy(ctx, page) == 0);
	/* only to decide whether waiting is worth it; the dirty decision below asks again, at the dirty site */
	obj = o->has_object(ctx, page);
	while (!busied && obj && budget != NULL && *budget > 0 &&
	    o->delay != NULL) {
		(*budget)--;
		o->delay(ctx, page);
		busied = (o->try_busy(ctx, page) == 0);
	}
	act = gb10_pi_dirty_action(o->has_object(ctx, page),
	    o->all_valid(ctx, page));
	if (act == GB10_PI_DIRTY_DO)
		o->dirty(ctx, page);
	if (busied)
		o->unbusy(ctx, page);
	else if (act == GB10_PI_DIRTY_DO)
		act = GB10_PI_DIRTY_FALLBACK;
	return (act);
}

/*
 * gb10_pi_count - check a scatter list and count its pages.
 *
 * Every entry must start at offset 0, be a non-zero whole number of pages
 * long and have a page; the lengths must add up to `size`, which must be a
 * non-zero whole number of pages of at most GB10_PI_MAX_BYTES.  No entry is
 * added to the running total before it is known to fit, so the sum cannot
 * wrap.  Whether the pages are RAM is gb10_pi_fill()'s question.
 *
 * Time O(nsegs), space O(1).
 */
static inline int
gb10_pi_count(const struct gb10_pi_seg *segs, unsigned long long nsegs,
    unsigned long long size, unsigned long long page_size,
    unsigned long long *npages)
{
	unsigned long long i, sum;

	if (segs == NULL || npages == NULL || page_size == 0 ||
	    (page_size & (page_size - 1)) != 0)
		return (GB10_PI_BAD_ARG);
	if (nsegs == 0 || size == 0)
		return (GB10_PI_EMPTY);
	if (size > GB10_PI_MAX_BYTES)
		return (GB10_PI_OVERSIZE);
	if ((size & (page_size - 1)) != 0)
		return (GB10_PI_NOT_WHOLE_PAGES);
	sum = 0;
	for (i = 0; i < nsegs; i++) {
		if (segs[i].first == NULL)
			return (GB10_PI_NOT_RAM);
		if (segs[i].offset != 0)
			return (GB10_PI_NOT_WHOLE_PAGES);
		if (segs[i].length == 0 ||
		    (segs[i].length & (page_size - 1)) != 0)
			return (GB10_PI_NOT_WHOLE_PAGES);
		if (segs[i].length > size - sum)
			return (GB10_PI_SIZE_MISMATCH);
		sum += segs[i].length;
	}
	if (sum != size)
		return (GB10_PI_SIZE_MISMATCH);
	*npages = size / page_size;
	return (GB10_PI_OK);
}

/*
 * gb10_pi_fill - expand a scatter list into `pages` (capacity `cap`
 * entries) and return the number of pages in *npages.  Every page must be
 * managed RAM (ops->page_at() returns NULL for one that is not).  Nothing
 * is written when the list is refused by gb10_pi_count() or does not fit.
 * No page is wired here.
 *
 * Time O(npages), space O(1).
 */
/* #lizard forgives -- the list, its size, the page size, the ops and the output array are one call's inputs */
static inline int
gb10_pi_fill(const struct gb10_pi_seg *segs, unsigned long long nsegs,
    unsigned long long size, unsigned long long page_size,
    const struct gb10_pi_ops *ops, void *ctx, void **pages,
    unsigned long long cap, unsigned long long *npages)
{
	unsigned long long i, j, n, total;
	void *pg;
	int rc;

	if (ops == NULL || ops->page_at == NULL || pages == NULL ||
	    npages == NULL)
		return (GB10_PI_BAD_ARG);
	rc = gb10_pi_count(segs, nsegs, size, page_size, &total);
	if (rc != GB10_PI_OK)
		return (rc);
	if (cap < total)
		return (GB10_PI_CAPACITY);
	n = 0;
	for (i = 0; i < nsegs; i++) {
		for (j = 0; j < segs[i].length / page_size; j++) {
			pg = ops->page_at(ctx, segs[i].first, j);
			if (pg == NULL)
				return (GB10_PI_NOT_RAM);
			/* the page the entry names must be the first one found */
			if (j == 0 && pg != segs[i].first)
				return (GB10_PI_NOT_RAM);
			pages[n++] = pg;
		}
	}
	*npages = n;
	return (GB10_PI_OK);
}

/*
 * gb10_pi_wire - wire every page of the array, once each, or none: a page
 * that cannot be wired makes the pages wired before it be unwired again.
 * Each page is busied without waiting, checked again with ops->claimable()
 * and only then wired, so a page that gained a VM object since it was
 * checked (a first-touch fault of the exporter's mapping) is never wired
 * (vm_page_wire() asserts the object lock of such a page), and the busy lock
 * keeps the fault from inserting it between the check and the wire.
 */
static inline int
gb10_pi_wire_mode(void **pages, unsigned long long n,
    const struct gb10_pi_ops *ops, void *ctx, int rewire)
{
	unsigned long long i;
	int rc;

	if (pages == NULL || n == 0 || ops == NULL || ops->wire == NULL ||
	    ops->unwire == NULL || ops->try_busy == NULL ||
	    ops->unbusy == NULL || ops->claimable == NULL ||
	    ops->rewire_ok == NULL)
		return (GB10_PI_BAD_ARG);
	for (i = 0; i < n; i++) {
		if (ops->try_busy(ctx, pages[i]) != 0) {
			rc = GB10_PI_PAGE_BUSY;
			goto undo;
		}
		if (!(rewire ? ops->rewire_ok(ctx, pages[i]) :
		    ops->claimable(ctx, pages[i]))) {
			ops->unbusy(ctx, pages[i]);
			rc = GB10_PI_PAGE_CHANGED;
			goto undo;
		}
		if (ops->wire(ctx, pages[i]) != 0) {
			ops->unbusy(ctx, pages[i]);
			rc = GB10_PI_WIRE_FAILED;
			goto undo;
		}
		ops->unbusy(ctx, pages[i]);
	}
	return (GB10_PI_OK);
undo:
	while (i-- > 0)
		ops->unwire(ctx, pages[i]);
	return (rc);
}

/* gb10_pi_wire - the first wiring of an imported array: pages without a VM object only. */
static inline int
gb10_pi_wire(void **pages, unsigned long long n, const struct gb10_pi_ops *ops,
    void *ctx)
{
	return (gb10_pi_wire_mode(pages, n, ops, ctx, 0));
}

/* gb10_pi_unwire - drop the one wiring gb10_pi_wire() took on each page. */
static inline void
gb10_pi_unwire(void **pages, unsigned long long n,
    const struct gb10_pi_ops *ops, void *ctx)
{
	unsigned long long k;

	if (pages == NULL || ops == NULL || ops->unwire == NULL)
		return;
	for (k = 0; k < n; k++)
		ops->unwire(ctx, pages[k]);
}

/* gb10_pi_desc_ok - is `d` one of ours, with pages and an owner? */
static inline int
gb10_pi_desc_ok(const struct gb10_pi_desc *d)
{
	if (d == NULL)
		return (0);
	if (d->magic != GB10_PI_DESC_MAGIC)
		return (0);
	if (d->pages == NULL || d->count == 0)
		return (0);
	if (d->hold == NULL || d->release == NULL)
		return (0);
	return (1);
}

/* gb10_pi_desc_valid - is `d` a descriptor of exactly `page_count` pages? */
static inline int
gb10_pi_desc_valid(const struct gb10_pi_desc *d, unsigned long long page_count)
{
	if (!gb10_pi_desc_ok(d))
		return (0);
	if (d->count != page_count)
		return (0);
	return (1);
}

/*
 * gb10_pi_import - nv_dma_import_sgt(): take the owner's reference.  The
 * RM calls gb10_pi_release() exactly once afterwards, whatever happens to
 * the registration, so a refused descriptor takes nothing.  The page count
 * is the RM's to check, at the registration.
 */
static inline int
gb10_pi_import(struct gb10_pi_desc *d)
{
	if (!gb10_pi_desc_ok(d))
		return (GB10_PI_BAD_ARG);
	if (d->hold(d->ctx) != 0)
		return (GB10_PI_CLOSING);
	__atomic_add_fetch(&d->held, 1, __ATOMIC_SEQ_CST);
	return (GB10_PI_OK);
}

/* gb10_pi_release - nv_dma_release_sgt(): drop the owner's reference. */
static inline void
gb10_pi_release(struct gb10_pi_desc *d)
{
	struct gb10_pi_gate *g;
	int h;

	if (d == NULL || d->magic != GB10_PI_DESC_MAGIC || d->release == NULL)
		return;
	/* one release per hold, also when two exports of one object release at once */
	h = __atomic_load_n(&d->held, __ATOMIC_SEQ_CST);
	do {
		if (h <= 0)
			return;
	} while (!__atomic_compare_exchange_n(&d->held, &h, h - 1, 0,
	    __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST));
	g = d->gate;		/* d may be freed by the release */
	d->release(d->ctx);
	if (g != NULL)
		gb10_pi_gate_drop(g);
}

/*
 * gb10_pi_register - nv_register_sgt(): wire the pages and fill the RM's
 * physical-address array, one entry per page.  All or nothing: a refused
 * descriptor or a failed wire leaves `phys_out` untouched and nothing wired.
 */
static inline int
gb10_pi_register(const struct gb10_pi_desc *d, unsigned long long page_count,
    unsigned long long *phys_out, const struct gb10_pi_ops *ops, void *ctx)
{
	unsigned long long i;
	int rc;

	if (phys_out == NULL || ops == NULL || ops->phys == NULL)
		return (GB10_PI_BAD_ARG);
	if (!gb10_pi_desc_valid(d, page_count))
		return (GB10_PI_BAD_ARG);
	rc = gb10_pi_wire_mode(d->pages, d->count, ops, ctx, d->imported != 0);
	if (rc != GB10_PI_OK)
		return (rc);
	for (i = 0; i < d->count; i++)
		phys_out[i] = ops->phys(ctx, d->pages[i]);
	return (GB10_PI_OK);
}

/* gb10_pi_unregister - nv_unregister_sgt(): undo gb10_pi_register(). */
static inline void
gb10_pi_unregister(const struct gb10_pi_desc *d, const struct gb10_pi_ops *ops,
    void *ctx)
{
	if (d == NULL || d->magic != GB10_PI_DESC_MAGIC)
		return;
	gb10_pi_unwire(d->pages, d->count, ops, ctx);
}

/*
 * The exporter's object, held for the whole life of an imported buffer.  An
 * imported GEM handle owns pages another driver allocated; nothing but a
 * reference on its dma-buf keeps that driver's page pool from reusing them
 * once the exporter closes its own handle and fd, whether or not the
 * buffer is ever exported again.  Taken once at import, dropped once after
 * the RM handle was freed.
 */
struct gb10_pi_life {
	void	(*hold)(void *ctx);
	void	(*release)(void *ctx);
	void	*ctx;
	int	held;
};

static inline void
gb10_pi_life_take(struct gb10_pi_life *l)
{
	if (l == NULL || l->held || l->hold == NULL || l->release == NULL)
		return;
	l->hold(l->ctx);
	l->held = 1;
}

static inline void
gb10_pi_life_drop(struct gb10_pi_life *l)
{
	if (l == NULL || !l->held)
		return;
	l->held = 0;
	l->release(l->ctx);
}

#endif /* _GB10_PAGEIMPORT_H_ */

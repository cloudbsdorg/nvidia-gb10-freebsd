/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-3-Clause
 *
 * gb10_pageimport_os.c - the FreeBSD side of the cross-GPU buffer import
 * (PRIME), Track #2228, docs/PRIME-IMPORT.md.  Our own file, not part of
 * NVIDIA's proprietary nvidia_subr.c/nvidia_os.c, which only call the
 * functions below.  scripts/prepare-tree.sh copies it into TREE/nvidia/ and
 * the nvidia/Makefile patch adds it to SRCS.
 *
 * A buffer another GPU rendered into reaches nvidia-drm.ko as a Linux
 * scatter list, which this module cannot read.  nvidia-drm turns it into an
 * array of vm_page pointers (gb10_pi_fill) and the logic of
 * gb10_pageimport.h, driven by the ops table below, wires and unwires the
 * pages.  Entry points:
 *
 *  - nv_import_pages()/nv_unimport_pages(): the array the RM's page-array
 *    descriptor takes (NVOS32_DESCRIPTOR_TYPE_OS_PAGE_ARRAY).  The RM's
 *    teardown (osDestroyOsDescriptorPageArray) calls os_unlock_user_pages(),
 *    which unwires one reference per page, dirties a page only when
 *    gb10_pi_os_dirty() allows it, and frees the array with os_free_mem():
 *    so the array is allocated with os_alloc_mem() and every page is wired
 *    exactly once here.
 *  - gb10_pi_os_register()/gb10_pi_os_unregister(): the SGT path
 *    (nv_register_sgt() and nv_unregister_sgt() in nvidia_subr.c).  The
 *    "sg_table" the RM passes through is a struct gb10_pi_desc.
 *  - gb10_pi_os_dirty(): the dirty step of os_unlock_user_pages().
 */

#include "os-interface.h"
#include "nv.h"
#include "nv-freebsd.h"

#include <sys/sysctl.h>

#include "gb10_pageimport.h"

/*
 * The tripwires of the dirty step of os_unlock_user_pages() (docs/PRIME-IMPORT.md,
 * "The release path"): a page of an RM user-page descriptor found with a VM
 * object that is not all valid, and a page whose busy lock stayed held
 * through a short spin.  The analysis there says the first cannot be reached; the counters make a mistake in it visible.  Read-only; a
 * nonzero value is a driver defect, see docs/PRIME-IMPORT.md section 7.6.
 */
static unsigned long gb10_pi_dirty_refused;
static unsigned long gb10_pi_dirty_busy_fallback;
static struct timeval gb10_pi_lasttime;
static int gb10_pi_curpps;
SYSCTL_ULONG(_hw, OID_AUTO, nvidia_unlock_dirty_refused, CTLFLAG_RD,
    &gb10_pi_dirty_refused, 0,
    "Pages with a VM object that were not all valid when the RM unpinned them (not marked dirty); nonzero is a driver defect, see docs/PRIME-IMPORT.md 7.6");
SYSCTL_ULONG(_hw, OID_AUTO, nvidia_unlock_dirty_busy_fallback, CTLFLAG_RD,
    &gb10_pi_dirty_busy_fallback, 0,
    "Pages the RM unpinned while their busy lock stayed held through a short spin (marked dirty without the lock, as the stock code did)");

/* Asked with the page busied, by gb10_pi_wire(); the decision is the core's. */
static int
nv_pi_claimable(void *ctx, void *page)
{
	vm_page_t m = page;

	return (gb10_pi_page_claimable(1, (m->flags & PG_FICTITIOUS) != 0,
	    m->object != NULL));
}

/*
 * Asked with the page busied, by gb10_pi_wire() when an imported buffer is
 * wired again (the SGT export): the page is wired by us, so it may have an
 * object by now (the exporter's own mapping faulted it in), which is fine
 * for a busied, wired page; it must still not be fictitious.
 */
static int
nv_pi_rewire_ok(void *ctx, void *page)
{
	vm_page_t m = page;

	return ((m->flags & PG_FICTITIOUS) == 0 && vm_page_wired(m));
}

/* The busy lock, for the wiring and for the dirty step alike. */
static int
nv_busy_try(void *ctx, void *page)
{
	return (vm_page_tryxbusy((vm_page_t)page) != 0 ? 0 : -1);
}

static void
nv_busy_release(void *ctx, void *page)
{
	vm_page_xunbusy((vm_page_t)page);
}

static int
nv_pi_wire(void *ctx, void *page)
{
	vm_page_wire((vm_page_t)page);
	return (0);
}

/* The call os_unlock_user_pages() makes, so the RM's teardown balances it. */
static void
nv_pi_unwire(void *ctx, void *page)
{
	vm_page_unwire((vm_page_t)page, PQ_ACTIVE);
}

static unsigned long long
nv_pi_phys(void *ctx, void *page)
{
	return (VM_PAGE_TO_PHYS((vm_page_t)page));
}

static const struct gb10_pi_ops nv_pi_ops = {
	.wire      = nv_pi_wire,
	.unwire    = nv_pi_unwire,
	.phys      = nv_pi_phys,
	.try_busy  = nv_busy_try,
	.unbusy    = nv_busy_release,
	.claimable = nv_pi_claimable,
	.rewire_ok = nv_pi_rewire_ok,
};

_Static_assert(NV_ERR_BUSY_RETRY == GB10_PI_STATUS_RETRY,
    "nvidia-drm reports this status as a retry");
_Static_assert(NV_ERR_NOT_SUPPORTED == GB10_PI_STATUS_REFUSED,
    "nvidia-drm reports this status as a page that changed for good");

/*
 * The one mapping from the core's result to the RM's status: a page the
 * exporter holds busy right now is a retry, a page that changed for good
 * (an object, fictitious) is not a retry.
 */
static NV_STATUS
nv_pi_status(int rc)
{
	switch (rc) {
	case GB10_PI_OK:
		return (NV_OK);
	case GB10_PI_PAGE_BUSY:
		return (NV_ERR_BUSY_RETRY);
	case GB10_PI_PAGE_CHANGED:
		return (NV_ERR_NOT_SUPPORTED);
	case GB10_PI_WIRE_FAILED:
		return (NV_ERR_INSUFFICIENT_RESOURCES);
	default:
		return (NV_ERR_INVALID_ARGUMENT);
	}
}

/*
 * Wire `count` pages and hand back the array the RM's page-array descriptor
 * wants.  On success the array and the wiring belong to the caller until it
 * gives them to the RM (which then unwires and frees them) or back to
 * nv_unimport_pages().  On failure nothing is wired and nothing is
 * allocated.  Exported to nvidia-drm.ko through EXPORT_SYMS.
 */
NV_STATUS NV_API_CALL
nv_import_pages(void **pages, NvU64 count, void **array)
{
	vm_page_t *copy;
	NvU64 i;
	int rc;

	if (pages == NULL || array == NULL ||
	    !gb10_pi_array_ok(count, PAGE_SIZE))
		return (NV_ERR_INVALID_ARGUMENT);

	*array = NULL;

	if (os_alloc_mem((void **)&copy, count * sizeof(*copy)) != NV_OK)
		return (NV_ERR_NO_MEMORY);

	for (i = 0; i < count; i++)
		copy[i] = pages[i];

	rc = gb10_pi_wire((void **)copy, count, &nv_pi_ops, NULL);
	if (rc != GB10_PI_OK) {
		os_free_mem(copy);
		return (nv_pi_status(rc));
	}

	*array = copy;
	return (NV_OK);
}

/* Give back an array nv_import_pages() made and the RM did not take. */
void NV_API_CALL
nv_unimport_pages(void *array, NvU64 count)
{
	if (array == NULL)
		return;

	gb10_pi_unwire((void **)array, count, &nv_pi_ops, NULL);
	os_free_mem(array);
}

/*
 * nv_register_sgt(): wire the pages of the descriptor and fill the RM's
 * physical-address array.  *priv_data is set to the descriptor on success.
 * A page that changed since the check (the exporter's mapping faulted it in,
 * or holds it busy) is a transient refusal: the caller may retry.
 */
NV_STATUS NV_API_CALL
gb10_pi_os_register(void *import_sgt, NvU64 page_count, NvU64 *phys_addr,
    void **priv_data, int is_peer_mmio)
{
	int rc;

	if (priv_data == NULL || phys_addr == NULL)
		return (NV_ERR_INVALID_ARGUMENT);

	*priv_data = NULL;

	if (is_peer_mmio)
		return (NV_ERR_NOT_SUPPORTED);

	rc = gb10_pi_register(import_sgt, page_count,
	    (unsigned long long *)phys_addr, &nv_pi_ops, NULL);
	if (rc != GB10_PI_OK)
		return (nv_pi_status(rc));

	*priv_data = import_sgt;
	return (NV_OK);
}

/* nv_unregister_sgt(): undo gb10_pi_os_register(), hand back the descriptor and its owner. */
void NV_API_CALL
gb10_pi_os_unregister(void *priv_data, void **import_sgt, void **import_priv)
{
	struct gb10_pi_desc *desc = priv_data;

	if (desc == NULL)
		return;

	gb10_pi_unregister(desc, &nv_pi_ops, NULL);

	*import_sgt = desc;
	*import_priv = desc->ctx;
}

/* nv_dma_import_sgt(): take the owner's reference. */
NV_STATUS NV_API_CALL
gb10_pi_os_import(void *sgt)
{
	return (gb10_pi_import(sgt) == GB10_PI_OK ? NV_OK : NV_ERR_NOT_SUPPORTED);
}

/* nv_dma_release_sgt(): last use of the descriptor, dropping the owner may free it. */
void NV_API_CALL
gb10_pi_os_release(void *sgt)
{
	gb10_pi_release(sgt);
}

/*
 * The OS operations of the dirty step (gb10_pi_dirty_page()).  The wait for
 * a busy page spins for a short, fixed time and never sleeps: the RM's
 * teardown may run with locks held that THREAD_CAN_SLEEP() does not know
 * about.  Whoever holds a wired page busy (a pager, the exporter's fault)
 * holds it for microseconds; when it is still held after the spin the core
 * dirties the page without the lock, the way the stock code did, and the
 * result is counted in hw.nvidia_unlock_dirty_busy_fallback.
 */
#define	GB10_PI_BUSY_SPINS	100
#define	GB10_PI_BUSY_SPIN_US	10

static int
nv_dirty_wait_busy(void *ctx, void *page)
{
	int tries;

	for (tries = 0; tries < GB10_PI_BUSY_SPINS; tries++) {
		if (vm_page_tryxbusy((vm_page_t)page) != 0)
			return (0);
		DELAY(GB10_PI_BUSY_SPIN_US);
	}
	return (-1);
}

static int
nv_dirty_has_object(void *ctx, void *page)
{
	return (((vm_page_t)page)->object != NULL);
}

static int
nv_dirty_all_valid(void *ctx, void *page)
{
	return (vm_page_all_valid((vm_page_t)page) != 0);
}

static void
nv_dirty_dirty(void *ctx, void *page)
{
	vm_page_dirty((vm_page_t)page);
}

static const struct gb10_pi_dirty_ops nv_dirty_ops = {
	.try_busy   = nv_busy_try,
	.wait_busy  = nv_dirty_wait_busy,
	.unbusy     = nv_busy_release,
	.has_object = nv_dirty_has_object,
	.all_valid  = nv_dirty_all_valid,
	.dirty      = nv_dirty_dirty,
};

/*
 * The dirty step of os_unlock_user_pages(), for every page of every writable
 * RM user-page descriptor.  The decision is the core's (gb10_pi_dirty_page()):
 * the page is busied (waiting for a pager that holds it) and the question
 * asked at the dirty site, because vm_page_dirty() asserts that the page is
 * all valid (INVARIANTS; on any other kernel it would mark an invalid page
 * dirty) and a wired page can gain an object after it was wired (the
 * exporter's own mapping faults it in; the importer cannot map it, see
 * __nv_drm_gem_dma_buf_mmap()) and can be invalidated.  A page with an object
 * that is not all valid is not dirtied and is counted and logged, not made a
 * panic.  With the busy lock held by
 * somebody else after a short spin, the page is dirtied the stock way and counted.
 */
void NV_API_CALL
gb10_pi_os_dirty(void *page)
{
	switch (gb10_pi_dirty_page(page, &nv_dirty_ops, NULL)) {
	case GB10_PI_DIRTY_REFUSE:
		atomic_add_long(&gb10_pi_dirty_refused, 1);
		if (ppsratecheck(&gb10_pi_lasttime, &gb10_pi_curpps, 1))
			printf("nvidia: a page the RM unpinned has a VM object "
			    "but is not all valid: not marked dirty.  This "
			    "should not happen: report it with this line and "
			    "the whole dmesg to the cloudbsdorg/nvidia-gb10-freebsd "
			    "repository, Track #2228 (see section 7.6 of "
			    "docs/PRIME-IMPORT.md in that repository)\n");
		break;
	case GB10_PI_DIRTY_FALLBACK:
		atomic_add_long(&gb10_pi_dirty_busy_fallback, 1);
		break;
	default:
		break;
	}
}

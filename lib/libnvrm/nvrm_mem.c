/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * nvrm_mem.c - the libnvrm memory core (Track #2419): the per-device client, the VA
 * reservations, memory objects, GPU and CPU mappings and buffer sharing.
 * Everything here is backend neutral: the core owns the bookkeeping and the
 * argument rules, a backend (nvrm_mem_ops) only talks to the GPU.  The core
 * never names a chip or a vendor.
 *
 * Rules the core enforces for every backend:
 *   - one RM client, one VA space and one allocator per nvrm_client;
 *   - every address a mapping uses lies inside a reservation, and no two GPU
 *     mappings overlap;
 *   - CPU mapping needs NVRM_OPEN_ALLOW_MAP, consumes one pre-opened spare
 *     descriptor (the OS layer lets a descriptor carry one mapping), and
 *     obeys the memory attribute rule;
 *   - only the process that opened a client may create or act on its objects;
 *     a fork child releases only its own records;
 *   - closing a client frees everything still in it.
 */
#include <sys/types.h>
#include <sys/capsicum.h>

#include <errno.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "nvrm_internal.h"

#define MIN_PAGE	4096ULL

int (*nvrm_capmode_hook)(void);

static int
fail(nvrm_client *cl, int rc, const char *fmt, ...)
{
	va_list ap;

	va_start(ap, fmt);
	vsnprintf(cl->errmsg, sizeof(cl->errmsg), fmt, ap);
	va_end(ap);
	return (rc);
}

/* Only the process that opened the client may create or act on its objects. */
static int
owner_check(nvrm_client *cl)
{
	if (nvrm_owner_is_me(&cl->owner))
		return (NVRM_OK);
	return (fail(cl, NVRM_E_DENIED, "this process did not open the client "
	    "(it is a fork() child): it may only release what it holds and "
	    "close the client"));
}

/* A size member: 0 or the structure's size. */
static int
size_ok(uint32_t size, size_t want)
{
	return (size == 0 || size == want);
}

static int
in_capmode(void)
{
	unsigned mode = 0;

	if (nvrm_capmode_hook != NULL)
		return (nvrm_capmode_hook());
	cap_getmode(&mode);
	return (mode != 0);
}

/* ---- the memory attribute rule ------------------------------------------ */

/*
 * What a CPU mapping of memory in this place gets (README, "Memory attributes
 * on arm64").  System memory is ordinary RAM: write-back.  Video memory is a
 * PCIe BAR: write-combining, which on arm64 is Normal non-cacheable, except
 * where the OS layer reports that it falls back to Device-nGnRE for write
 * combining (the Altra, hw.nvidia.altra_device_wc_active).  When the OS layer
 * does not say, the safe answer on arm64 is Device, which every access
 * pattern of the aligned kind survives.  Off arm64 the BAR is write-combined
 * and the MTRR or PAT policy keeps register pages safe.
 *
 * System memory that is not mapped cached (an import of an object its owner
 * made write-combined or uncached) gets what it is: write-combining, or for
 * uncached the Device rule on every host, which is the access pattern that is
 * safe for uncached memory everywhere.
 */
int
nvrm_cpu_attr_rule(int place, int coherency, int host_arm64,
    const nvrm_u64 *wc)
{
	if (place != NVRM_PLACE_VIDMEM) {
		if (coherency == NVRM_COH_UNCACHED)
			return (NVRM_ATTR_DEVICE);
		return (coherency == NVRM_COH_WC ? NVRM_ATTR_WC :
		    NVRM_ATTR_CACHED);
	}
	if (!host_arm64)
		return (NVRM_ATTR_WC);
	if (!NVRM_HAVE(*wc) || wc->value != 0)
		return (NVRM_ATTR_DEVICE);
	return (NVRM_ATTR_WC);
}

/* ---- spare descriptors --------------------------------------------------- */

static int
pool_push(nvrm_pool *p, int fd)
{
	int *n;

	if (p->n == p->cap) {
		n = NVRM_CALLOC(p->cap + 8, sizeof(int));
		if (n == NULL)
			return (NVRM_E_NOMEM);
		if (p->n > 0)
			memcpy(n, p->fd, p->n * sizeof(int));
		free(p->fd);
		p->fd = n;
		p->cap += 8;
	}
	p->fd[p->n++] = fd;
	return (NVRM_OK);
}

static int
pool_fill(nvrm_client *cl, int kind, unsigned count)
{
	unsigned i;
	int fd, rc;

	for (i = 0; i < count; i++) {
		rc = cl->mops->desc_open(cl->bc, kind, &fd, cl->errmsg,
		    sizeof(cl->errmsg));
		if (rc != NVRM_OK)
			return (rc);
		rc = pool_push(&cl->pool[kind], fd);
		if (rc != NVRM_OK) {
			close(fd);
			return (fail(cl, rc, "out of memory"));
		}
	}
	return (NVRM_OK);
}

/*
 * A spare descriptor.  Before capability mode a missing one is simply opened;
 * in capability mode nothing can be opened, so the pre-opened ones are all
 * there is.
 */
static int
pool_take(nvrm_client *cl, int kind, int *fd)
{
	nvrm_pool *p = &cl->pool[kind];

	if (p->n > 0) {
		*fd = p->fd[--p->n];
		return (NVRM_OK);
	}
	if (in_capmode())
		return (fail(cl, NVRM_E_NOSLOT, "no spare %s descriptor is "
		    "left and none can be opened in capability mode (raise "
		    "nvrm_open_opts.%s)", kind == NVRM_DESC_EXPORT ? "export" :
		    "mapping", kind == NVRM_DESC_EXPORT ? "export_slots" :
		    "map_slots"));
	return (cl->mops->desc_open(cl->bc, kind, fd, cl->errmsg,
	    sizeof(cl->errmsg)));
}

/*
 * The descriptor a CPU mapping of memory in this place is made on: the RM
 * maps video memory through the GPU's device node and system memory through
 * the control device (nvrm_internal.h, NVRM_DESC_MAP).
 */
static int
map_desc_kind(int place)
{
	return (place == NVRM_PLACE_SYSMEM ? NVRM_DESC_MAP_CTL : NVRM_DESC_MAP);
}

/* ---- client -------------------------------------------------------------- */

static void
set_err(char *err, size_t errlen, const char *msg)
{
	if (err != NULL && errlen > 0)
		snprintf(err, errlen, "%s", msg);
}

static int
check_open_opts(const nvrm_open_opts *o, nvrm_open_cfg *cfg, char *err,
    size_t errlen)
{
	memset(cfg, 0, sizeof(*cfg));
	cfg->export_slots = NVRM_EXPORT_SLOTS_DEFAULT;
	if (o == NULL)
		return (NVRM_OK);
	if (!size_ok(o->size, sizeof(*o))) {
		set_err(err, errlen, "nvrm_open_opts has the wrong size: it "
		    "was built for another version of libnvrm");
		return (NVRM_E_INVAL);
	}
	if ((o->flags & ~NVRM_OPEN_KNOWN_FLAGS) != 0) {
		set_err(err, errlen, "unknown open flags: the options were "
		    "built for another version of libnvrm");
		return (NVRM_E_INVAL);
	}
	if (o->map_slots > NVRM_SLOTS_MAX || o->export_slots > NVRM_SLOTS_MAX) {
		if (err != NULL && errlen > 0)
			snprintf(err, errlen, "nvrm_open_opts.%s is %u, above "
			    "the limit of %u spare descriptors (NVRM_SLOTS_MAX)",
			    o->map_slots > NVRM_SLOTS_MAX ? "map_slots" :
			    "export_slots", o->map_slots > NVRM_SLOTS_MAX ?
			    o->map_slots : o->export_slots, NVRM_SLOTS_MAX);
		return (NVRM_E_INVAL);
	}
	cfg->allow_map = (o->flags & NVRM_OPEN_ALLOW_MAP) != 0;
	if (cfg->allow_map)
		cfg->map_slots = o->map_slots != 0 ? o->map_slots :
		    NVRM_MAP_SLOTS_DEFAULT;
	if (o->export_slots != 0)
		cfg->export_slots = o->export_slots;
	return (NVRM_OK);
}

static void
free_pools(nvrm_client *cl)
{
	unsigned k, i;

	for (k = 0; k < NVRM_DESC__COUNT; k++) {
		for (i = 0; i < cl->pool[k].n; i++)
			close(cl->pool[k].fd[i]);
		free(cl->pool[k].fd);
	}
}

static void
client_free(nvrm_client *cl)
{
	(void)pthread_mutex_destroy(&cl->errlock);
	free(cl);
}

int
nvrm_client_open(const nvrm_device *dev, const nvrm_open_opts *opts,
    nvrm_client **clp, char *err, size_t errlen)
{
	const nvrm_device_info *info;
	const nvrm_mem_ops *mops;
	nvrm_open_cfg cfg;
	nvrm_vainfo vi;
	nvrm_client *cl;
	int rc;

	*clp = NULL;
	set_err(err, errlen, "");
	rc = check_open_opts(opts, &cfg, err, errlen);
	if (rc != NVRM_OK)
		return (rc);
	mops = dev->ctx->ops->mem;
	if (mops == NULL) {
		set_err(err, errlen, "the backend has no memory support");
		return (NVRM_E_NOTSUP);
	}
	cl = NVRM_CALLOC(1, sizeof(*cl));
	if (cl == NULL) {
		set_err(err, errlen, "out of memory");
		return (NVRM_E_NOMEM);
	}
	nvrm_owner_set(&cl->owner);
	(void)pthread_mutex_init(&cl->errlock, NULL);
	info = &dev->info;
	cl->ops = dev->ctx->ops;
	cl->mops = mops;
	cl->vram_size = info->vram_size;
	cl->wc_cap = info->caps[NVRM_CAPIDX_OS_DEVICE_WC];
	cl->page_sizes = info->page_sizes;
	cl->host_arm64 = mops->host_arm64();
	cl->allow_map = cfg.allow_map;
	rc = mops->client_open(dev->ctx->be, dev->gpu, &cfg, &cl->bc, &vi, err,
	    errlen);
	if (rc != NVRM_OK) {
		client_free(cl);
		return (rc);
	}
	cl->va = vi.base < vi.end ? nvrm_va_new(vi.base, vi.end) : NULL;
	if (cl->va == NULL) {
		rc = vi.base < vi.end ? NVRM_E_NOMEM : NVRM_E_RANGE;
		set_err(err, errlen, rc == NVRM_E_NOMEM ? "out of memory" :
		    "the backend reported an empty VA space");
		mops->client_close(cl->bc);
		client_free(cl);
		return (rc);
	}
	cl->va_base = vi.base;
	cl->va_end = vi.end;
	rc = pool_fill(cl, NVRM_DESC_MAP, cfg.map_slots);
	if (rc == NVRM_OK)
		rc = pool_fill(cl, NVRM_DESC_MAP_CTL, cfg.map_slots);
	if (rc == NVRM_OK)
		rc = pool_fill(cl, NVRM_DESC_EXPORT, cfg.export_slots);
	if (rc != NVRM_OK) {
		set_err(err, errlen, cl->errmsg);
		nvrm_client_close(cl);
		return (rc);
	}
	*clp = cl;
	return (NVRM_OK);
}

/* A release the backend refused: counted, and the message kept. */
static void
count_failed(nvrm_client *cl, int rc)
{
	if (rc != NVRM_OK)
		cl->st.failed_releases++;
}

void
nvrm_client_close(nvrm_client *cl)
{
	nvrm_reserve *r;
	nvrm_gmap *g;

	if (cl == NULL)
		return;
	while (cl->channels != NULL)
		nvrm_chan_destroy(cl->channels);
	nvrm_chan_release_held(cl);
	while (cl->mems != NULL)
		nvrm_mem_free(cl->mems);
	/* Mappings whose unmap was refused while their object was freed: the
	 * RM client goes away with everything in it below. */
	while ((g = cl->gmaps) != NULL) {
		cl->gmaps = g->next;
		free(g);
	}
	while ((r = cl->reserves) != NULL) {
		cl->reserves = r->next;
		count_failed(cl, cl->mops->va_release(r->b,
		    nvrm_owner_is_me(&cl->owner), cl->errmsg,
		    sizeof(cl->errmsg)));
		free(r);
	}
	free_pools(cl);
	nvrm_va_destroy(cl->va);
	cl->mops->client_close(cl->bc);
	client_free(cl);
}

const char *
nvrm_client_errmsg(const nvrm_client *cl)
{
	return (cl->errmsg);
}

/* The structure grew after NVRM_1.1 (live_channels, channels_created): a
 * caller built against NVRM_1.1 passes the size up to live_channels and gets
 * only that much back.  A size of 0 means this version's structure, so a
 * caller that zero-inits the structure and asks for the stats gets every
 * member. */
int
nvrm_client_stats_get(nvrm_client *cl, nvrm_client_stats *st)
{
	const size_t v11 = offsetof(nvrm_client_stats, live_channels);
	nvrm_client_stats full = cl->st;
	size_t want = st->size == 0 ? sizeof(full) : st->size;

	if (want != sizeof(full) && want != v11)
		return (fail(cl, NVRM_E_INVAL, "nvrm_client_stats.size must "
		    "be 0 (the full size), sizeof(nvrm_client_stats) or the "
		    "NVRM_1.1 size (offsetof live_channels)"));
	cl->errmsg[0] = '\0';
	full.size = (uint32_t)want;
	full.spare_descriptors = cl->pool[NVRM_DESC_MAP].n +
	    cl->pool[NVRM_DESC_MAP_CTL].n + cl->pool[NVRM_DESC_EXPORT].n;
	memcpy(st, &full, want);
	return (NVRM_OK);
}

int
nvrm_vaspace_info_get(nvrm_client *cl, nvrm_vaspace_info *info)
{
	if (!size_ok(info->size, sizeof(*info)))
		return (fail(cl, NVRM_E_INVAL, "nvrm_vaspace_info.size must "
		    "be 0 or sizeof(nvrm_vaspace_info)"));
	cl->errmsg[0] = '\0';
	info->size = sizeof(*info);
	info->base = cl->va_base;
	info->end = cl->va_end;
	info->free_bytes = nvrm_va_free_bytes(cl->va);
	return (NVRM_OK);
}

/* ---- VA reservations ----------------------------------------------------- */

static int
check_va_params(nvrm_client *cl, const nvrm_va_params *p, uint64_t *align)
{
	if (!size_ok(p->size, sizeof(*p)))
		return (fail(cl, NVRM_E_INVAL, "nvrm_va_params.size must be 0 or "
		    "sizeof(nvrm_va_params)"));
	if ((p->flags & ~NVRM_VA_KNOWN_FLAGS) != 0)
		return (fail(cl, NVRM_E_INVAL, "unknown VA flags"));
	*align = p->alignment != 0 ? p->alignment : MIN_PAGE;
	if ((*align & (*align - 1)) != 0 || *align < MIN_PAGE)
		return (fail(cl, NVRM_E_INVAL, "the alignment is not a power "
		    "of two of at least 4 KiB"));
	if (p->bytes == 0 || (p->bytes & (MIN_PAGE - 1)) != 0)
		return (fail(cl, NVRM_E_INVAL, "the size is not a multiple of "
		    "4 KiB"));
	if (p->fixed != 0 && (p->fixed & (*align - 1)) != 0)
		return (fail(cl, NVRM_E_INVAL, "the fixed address is not "
		    "aligned"));
	return (NVRM_OK);
}

int
nvrm_va_reserve(nvrm_client *cl, const nvrm_va_params *p, uint64_t *va)
{
	nvrm_reserve *r;
	uint64_t align, addr;
	int rc;

	cl->errmsg[0] = '\0';
	rc = owner_check(cl);
	if (rc != NVRM_OK)
		return (rc);
	rc = check_va_params(cl, p, &align);
	if (rc != NVRM_OK)
		return (rc);
	rc = nvrm_va_alloc(cl->va, p->bytes, align, p->fixed != 0, p->fixed,
	    &addr);
	if (rc != NVRM_OK)
		return (rc == NVRM_E_RANGE ? fail(cl, rc, "the VA space has no "
		    "free range of 0x%jx bytes%s", (uintmax_t)p->bytes,
		    p->fixed != 0 ? " at the fixed address" : "") :
		    fail(cl, rc, "out of memory"));
	r = NVRM_CALLOC(1, sizeof(*r));
	if (r == NULL) {
		nvrm_va_free(cl->va, addr, p->bytes);
		return (fail(cl, NVRM_E_NOMEM, "out of memory"));
	}
	rc = cl->mops->va_reserve(cl->bc, addr, p->bytes,
	    (p->flags & NVRM_VA_SPARSE) != 0, &r->b, cl->errmsg,
	    sizeof(cl->errmsg));
	if (rc != NVRM_OK) {
		nvrm_va_free(cl->va, addr, p->bytes);
		free(r);
		return (rc);
	}
	r->va = addr;
	r->bytes = p->bytes;
	r->sparse = (p->flags & NVRM_VA_SPARSE) != 0;
	r->next = cl->reserves;
	cl->reserves = r;
	cl->st.live_reservations++;
	*va = addr;
	return (NVRM_OK);
}

int
nvrm_va_release(nvrm_client *cl, uint64_t va)
{
	nvrm_reserve **pp, *r;
	int rc;

	cl->errmsg[0] = '\0';
	for (pp = &cl->reserves; *pp != NULL && (*pp)->va != va;
	    pp = &(*pp)->next)
		;
	r = *pp;
	if (r == NULL)
		return (fail(cl, NVRM_E_INVAL, "no reservation starts at 0x%jx",
		    (uintmax_t)va));
	if (r->nmaps != 0)
		return (fail(cl, NVRM_E_BUSY, "the reservation still has "
		    "mappings (or a mapping the RM would not unmap: see "
		    "failed_releases)"));
	/* The backend goes first: if the RM refuses, the reservation stays
	 * (the call can be retried).  A child releases only its own record. */
	rc = cl->mops->va_release(r->b, nvrm_owner_is_me(&cl->owner),
	    cl->errmsg, sizeof(cl->errmsg));
	if (rc != NVRM_OK) {
		count_failed(cl, rc);
		return (rc);
	}
	*pp = r->next;
	cl->st.live_reservations--;
	/* A child cannot reserve again, so its private allocator need not be
	 * changed (and an allocation failure cannot turn this release into an
	 * error).  Closing the client destroys that allocator. */
	if (!nvrm_owner_is_me(&cl->owner)) {
		free(r);
		return (NVRM_OK);
	}
	rc = nvrm_va_free(cl->va, r->va, r->bytes);
	free(r);
	if (rc != NVRM_OK)
		return (fail(cl, rc, "the reservation is released, but its "
		    "addresses are lost to the allocator (%s): they are never "
		    "handed out again", nvrm_strerror(rc)));
	return (NVRM_OK);
}

/* ---- memory objects ------------------------------------------------------ */

static int
page_size_ok(const nvrm_client *cl, uint64_t ps)
{
	unsigned i;

	if (ps == 0)
		return (1);
	if (!NVRM_HAVE(cl->page_sizes))
		return (ps == MIN_PAGE);
	for (i = 0; i < cl->page_sizes.count; i++)
		if (cl->page_sizes.value[i] == ps)
			return (1);
	return (0);
}

static int
check_mem_params(nvrm_client *cl, const nvrm_mem_params *p)
{
	if (!size_ok(p->size, sizeof(*p)))
		return (fail(cl, NVRM_E_INVAL, "nvrm_mem_params.size must be 0 or "
		    "sizeof(nvrm_mem_params)"));
	if (p->kind != NVRM_MEM_VRAM && p->kind != NVRM_MEM_SYSMEM)
		return (fail(cl, NVRM_E_INVAL, "the kind is not VRAM or "
		    "SYSMEM"));
	if (p->flags != 0 || p->reserved != 0)
		return (fail(cl, NVRM_E_INVAL, "flags and reserved must be "
		    "zero in this version"));
	if (p->bytes == 0)
		return (fail(cl, NVRM_E_INVAL, "the size is zero"));
	if ((p->alignment & (p->alignment - 1)) != 0)
		return (fail(cl, NVRM_E_INVAL, "the alignment is not a power "
		    "of two"));
	if (!page_size_ok(cl, p->page_size))
		return (fail(cl, NVRM_E_INVAL, "the page size is not one this "
		    "GPU supports (nvrm_device_info.page_sizes)"));
	return (NVRM_OK);
}

/* Where an allocation of this kind lands.  A GPU with no video memory of its
 * own (vram_size known to be 0) places VRAM in system memory. */
static int
place_for(const nvrm_client *cl, int kind)
{
	if (kind == NVRM_MEM_SYSMEM)
		return (NVRM_PLACE_SYSMEM);
	if (NVRM_HAVE(cl->vram_size) && cl->vram_size.value == 0)
		return (NVRM_PLACE_SYSMEM);
	return (NVRM_PLACE_VIDMEM);
}

/*
 * The page size of an allocation that did not name one: 64 KiB for video
 * memory of at least that size when the GPU lists 64 KiB, else 4 KiB.  The
 * backend then asks the RM for exactly that, so the size the core checks
 * mappings against is the one the RM uses.
 */
static uint64_t
default_page(const nvrm_client *cl, int place, uint64_t bytes)
{
	if (place == NVRM_PLACE_VIDMEM && bytes >= 65536 &&
	    page_size_ok(cl, 65536))
		return (65536);
	return (MIN_PAGE);
}

static nvrm_mem *
mem_new(nvrm_client *cl, int kind, nvrm_bmem *b, const nvrm_bmem_info *bi)
{
	nvrm_mem *m;

	m = NVRM_CALLOC(1, sizeof(*m));
	if (m == NULL)
		return (NULL);
	m->cl = cl;
	m->b = b;
	m->kind = kind;
	m->place = bi->place;
	m->bytes = bi->bytes;
	m->page_size = bi->page_size;
	m->cpu_attr = nvrm_cpu_attr_rule(bi->place, bi->coherency,
	    cl->host_arm64, &cl->wc_cap);
	m->cpu_fd = -1;
	m->next = cl->mems;
	cl->mems = m;
	cl->st.allocs++;
	cl->st.live_mem++;
	cl->st.live_bytes += m->bytes;
	return (m);
}

/* Make the core's object for what the backend made, or give it back. */
static int
adopt(nvrm_client *cl, int kind, nvrm_bmem *b, const nvrm_bmem_info *bi,
    nvrm_mem **memp)
{
	char scratch[sizeof(cl->errmsg)];

	*memp = mem_new(cl, kind, b, bi);
	if (*memp != NULL)
		return (NVRM_OK);
	count_failed(cl, cl->mops->mem_free(b, nvrm_owner_is_me(&cl->owner),
	    scratch, sizeof(scratch)));
	return (fail(cl, NVRM_E_NOMEM, "out of memory"));
}

int
nvrm_mem_alloc(nvrm_client *cl, const nvrm_mem_params *p, nvrm_mem **memp)
{
	nvrm_balloc a;
	nvrm_bmem_info bi = { .coherency = NVRM_COH_CACHED };
	nvrm_bmem *b;
	uint64_t unit;
	int rc;

	cl->errmsg[0] = '\0';
	rc = owner_check(cl);
	if (rc != NVRM_OK)
		return (rc);
	rc = check_mem_params(cl, p);
	if (rc != NVRM_OK)
		return (rc);
	a.kind = (int)p->kind;
	a.place = place_for(cl, a.kind);
	unit = p->page_size != 0 ? p->page_size : default_page(cl, a.place,
	    p->bytes);
	if (p->bytes > UINT64_MAX - (unit - 1))
		return (fail(cl, NVRM_E_INVAL, "the size is too large"));
	a.bytes = (p->bytes + unit - 1) & ~(unit - 1);
	a.alignment = p->alignment;
	a.page_size = unit;
	rc = cl->mops->mem_alloc(cl->bc, &a, &b, &bi, cl->errmsg,
	    sizeof(cl->errmsg));
	if (rc != NVRM_OK)
		return (rc);
	return (adopt(cl, a.kind, b, &bi, memp));
}

int
nvrm_mem_register_user(nvrm_client *cl, void *addr, uint64_t bytes,
    nvrm_mem **memp)
{
	nvrm_bmem_info bi = { .coherency = NVRM_COH_CACHED };
	nvrm_bmem *b;
	long page = sysconf(_SC_PAGESIZE);
	int rc;

	cl->errmsg[0] = '\0';
	rc = owner_check(cl);
	if (rc != NVRM_OK)
		return (rc);
	if (bytes == 0 || ((uintptr_t)addr & (page - 1)) != 0 ||
	    (bytes & (page - 1)) != 0)
		return (fail(cl, NVRM_E_INVAL, "the pages are not whole host "
		    "pages"));
	rc = cl->mops->mem_register(cl->bc, addr, bytes, &b, &bi, cl->errmsg,
	    sizeof(cl->errmsg));
	if (rc != NVRM_OK)
		return (rc);
	return (adopt(cl, NVRM_MEM_USER, b, &bi, memp));
}

/*
 * Unmap one GPU mapping.  If the RM refuses, the mapping is still there: with
 * keep set (an unmap the caller asked for) nothing changes and the call can
 * be retried; without it (the object is being freed) the record stays as an
 * orphan that keeps its addresses out of use and its reservation busy.
 */
static int
gmap_drop(nvrm_client *cl, nvrm_gmap **pp, int keep)
{
	nvrm_gmap *g = *pp;
	int rc;

	rc = cl->mops->unmap_gpu(g->mem->b, g->res->b, g->va, g->length,
	    nvrm_owner_is_me(&cl->owner), cl->errmsg, sizeof(cl->errmsg));
	count_failed(cl, rc);
	if (rc != NVRM_OK && keep)
		return (rc);
	g->mem->ngmaps--;
	cl->st.live_gpu_maps--;
	if (rc != NVRM_OK) {
		g->mem = NULL;
		return (rc);
	}
	g->res->nmaps--;
	*pp = g->next;
	free(g);
	return (NVRM_OK);
}

static int
cpu_drop(nvrm_mem *m)
{
	nvrm_client *cl = m->cl;
	int rc;

	rc = cl->mops->unmap_cpu(m->b, m->cpu_addr,
	    nvrm_owner_is_me(&cl->owner), cl->errmsg, sizeof(cl->errmsg));
	count_failed(cl, rc);
	close(m->cpu_fd);
	m->cpu_addr = NULL;
	m->cpu_fd = -1;
	cl->st.live_cpu_maps--;
	return (rc);
}

void
nvrm_mem_free(nvrm_mem *m)
{
	nvrm_client *cl = m->cl;
	nvrm_mem **pp;
	nvrm_gmap **gp;

	cl->errmsg[0] = '\0';
	if (m->cpu_addr != NULL)
		(void)cpu_drop(m);
	for (gp = &cl->gmaps; *gp != NULL;) {
		if ((*gp)->mem == m && gmap_drop(cl, gp, 0) == NVRM_OK)
			continue;	/* *gp is the next one now */
		gp = &(*gp)->next;
	}
	count_failed(cl, cl->mops->mem_free(m->b,
	    nvrm_owner_is_me(&cl->owner), cl->errmsg, sizeof(cl->errmsg)));
	for (pp = &cl->mems; *pp != m; pp = &(*pp)->next)
		;
	*pp = m->next;
	cl->st.frees++;
	cl->st.live_mem--;
	cl->st.live_bytes -= m->bytes;
	free(m);
}

int
nvrm_mem_info_get(const nvrm_mem *m, nvrm_mem_info *info)
{
	if (!size_ok(info->size, sizeof(*info)))
		return (fail(m->cl, NVRM_E_INVAL, "nvrm_mem_info.size must be "
		    "0 or sizeof(nvrm_mem_info)"));
	m->cl->errmsg[0] = '\0';
	info->size = sizeof(*info);
	info->kind = m->kind;
	info->place = m->place;
	info->cpu_attr = m->cpu_attr;
	info->bytes = m->bytes;
	info->page_size = m->page_size;
	info->cpu_mapped = m->cpu_addr != NULL;
	info->gpu_maps = m->ngmaps;
	return (NVRM_OK);
}

/* ---- GPU mappings -------------------------------------------------------- */

static nvrm_reserve *
find_reserve(nvrm_client *cl, uint64_t va, uint64_t len)
{
	nvrm_reserve *r;

	for (r = cl->reserves; r != NULL; r = r->next)
		if (va >= r->va && va - r->va < r->bytes &&
		    len <= r->bytes - (va - r->va))
			return (r);
	return (NULL);
}

static int
overlaps(const nvrm_client *cl, uint64_t va, uint64_t len)
{
	const nvrm_gmap *g;

	for (g = cl->gmaps; g != NULL; g = g->next)
		if (va < g->va + g->length && g->va < va + len)
			return (1);
	return (0);
}

static int
check_map_params(nvrm_mem *m, const nvrm_gpu_map_params *p, uint64_t *len)
{
	nvrm_client *cl = m->cl;
	uint64_t pg = m->page_size;

	if (!size_ok(p->size, sizeof(*p)))
		return (fail(cl, NVRM_E_INVAL, "nvrm_gpu_map_params.size must "
		    "be 0 or sizeof(nvrm_gpu_map_params)"));
	if ((p->flags & ~NVRM_MAP_KNOWN_FLAGS) != 0)
		return (fail(cl, NVRM_E_INVAL, "unknown mapping flags"));
	if (p->offset >= m->bytes)
		return (fail(cl, NVRM_E_RANGE, "the offset is outside the "
		    "object"));
	*len = p->length != 0 ? p->length : m->bytes - p->offset;
	if (*len > m->bytes - p->offset)
		return (fail(cl, NVRM_E_RANGE, "the range runs past the end "
		    "of the object"));
	if ((p->va & (pg - 1)) != 0 || (p->offset & (pg - 1)) != 0 ||
	    (*len & (pg - 1)) != 0)
		return (fail(cl, NVRM_E_INVAL, "the address, offset and "
		    "length must be multiples of the object's page size"));
	return (NVRM_OK);
}

int
nvrm_mem_map_gpu(nvrm_mem *m, const nvrm_gpu_map_params *p)
{
	nvrm_client *cl = m->cl;
	nvrm_reserve *r;
	nvrm_gmap *g;
	uint64_t len;
	int rc;

	cl->errmsg[0] = '\0';
	rc = owner_check(cl);
	if (rc != NVRM_OK)
		return (rc);
	rc = check_map_params(m, p, &len);
	if (rc != NVRM_OK)
		return (rc);
	if (p->va > UINT64_MAX - len || (r = find_reserve(cl, p->va, len)) == NULL)
		return (fail(cl, NVRM_E_RANGE, "0x%jx+0x%jx is not inside one "
		    "reservation", (uintmax_t)p->va, (uintmax_t)len));
	if (overlaps(cl, p->va, len))
		return (fail(cl, NVRM_E_RANGE, "0x%jx+0x%jx overlaps another "
		    "mapping", (uintmax_t)p->va, (uintmax_t)len));
	g = NVRM_CALLOC(1, sizeof(*g));
	if (g == NULL)
		return (fail(cl, NVRM_E_NOMEM, "out of memory"));
	rc = cl->mops->map_gpu(m->b, r->b, p->va, p->offset, len,
	    (p->flags & NVRM_MAP_READ_ONLY) != 0, cl->errmsg,
	    sizeof(cl->errmsg));
	if (rc != NVRM_OK) {
		free(g);
		return (rc);
	}
	g->va = p->va;
	g->length = len;
	g->res = r;
	g->mem = m;
	g->next = cl->gmaps;
	cl->gmaps = g;
	r->nmaps++;
	m->ngmaps++;
	cl->st.live_gpu_maps++;
	return (NVRM_OK);
}

int
nvrm_mem_unmap_gpu(nvrm_mem *m, uint64_t va)
{
	nvrm_client *cl = m->cl;
	nvrm_gmap **pp;

	cl->errmsg[0] = '\0';
	for (pp = &cl->gmaps; *pp != NULL; pp = &(*pp)->next)
		if ((*pp)->mem == m && (*pp)->va == va)
			return (gmap_drop(cl, pp, 1));
	return (fail(cl, NVRM_E_INVAL, "the object has no mapping at 0x%jx",
	    (uintmax_t)va));
}

/* ---- CPU mappings and access --------------------------------------------- */

int
nvrm_mem_map_cpu(nvrm_mem *m, unsigned prot, void **addr)
{
	nvrm_client *cl = m->cl;
	int fd, rc;

	cl->errmsg[0] = '\0';
	rc = owner_check(cl);
	if (rc != NVRM_OK)
		return (rc);
	if (m->kind == NVRM_MEM_USER)
		return (fail(cl, NVRM_E_INVAL, "registered user pages are "
		    "already in the caller's address space"));
	if (!cl->allow_map)
		return (fail(cl, NVRM_E_DENIED, "the client was not opened "
		    "with NVRM_OPEN_ALLOW_MAP"));
	if (prot == 0 || (prot & ~(NVRM_CPU_READ | NVRM_CPU_WRITE)) != 0)
		return (fail(cl, NVRM_E_INVAL, "the protection is not "
		    "NVRM_CPU_READ and/or NVRM_CPU_WRITE"));
	if (m->cpu_addr != NULL)
		return (fail(cl, NVRM_E_BUSY, "the object is mapped already"));
	rc = pool_take(cl, map_desc_kind(m->place), &fd);
	if (rc != NVRM_OK)
		return (rc);
	rc = cl->mops->map_cpu(m->b, fd, prot, &m->cpu_addr, cl->errmsg,
	    sizeof(cl->errmsg));
	if (rc != NVRM_OK) {
		close(fd);
		m->cpu_addr = NULL;
		return (rc);
	}
	m->cpu_fd = fd;
	m->cpu_prot = prot;
	cl->st.live_cpu_maps++;
	*addr = m->cpu_addr;
	return (NVRM_OK);
}

int
nvrm_mem_unmap_cpu(nvrm_mem *m)
{
	m->cl->errmsg[0] = '\0';
	if (m->cpu_addr == NULL)
		return (fail(m->cl, NVRM_E_INVAL, "the object is not mapped"));
	return (cpu_drop(m));
}

/* One primitive access of w (1, 2, 4 or 8) bytes at p, to or from buf. */
static void
dev_access(volatile void *p, unsigned w, void *buf, int write)
{
	uint64_t v = 0;

	if (write)
		memcpy(&v, buf, w);
	switch (w) {
	case 8:
		if (write)
			*(volatile uint64_t *)p = v;
		else
			v = *(volatile uint64_t *)p;
		break;
	case 4:
		if (write)
			*(volatile uint32_t *)p = (uint32_t)v;
		else
			v = *(volatile uint32_t *)p;
		break;
	case 2:
		if (write)
			*(volatile uint16_t *)p = (uint16_t)v;
		else
			v = *(volatile uint16_t *)p;
		break;
	default:
		if (write)
			*(volatile uint8_t *)p = (uint8_t)v;
		else
			v = *(volatile uint8_t *)p;
		break;
	}
	if (!write)
		memcpy(buf, &v, w);
}

/* Aligned accesses, the widest that fit: the rule for Device memory. */
static int
dev_copy(nvrm_mem *m, uint8_t *p, uint8_t *buf, size_t len, int write)
{
	nvrm_client *cl = m->cl;
	unsigned w;

	while (len > 0) {
		w = 8;
		while (w > len || ((uintptr_t)p & (w - 1)) != 0)
			w >>= 1;
		if (cl->mops->cpu_access != NULL &&
		    cl->mops->cpu_access(m->cpu_attr, p, w, write) != 0)
			return (fail(cl, NVRM_E_INVAL, "trapped: an access "
			    "the memory attribute does not allow"));
		dev_access(p, w, buf, write);
		p += w;
		buf += w;
		len -= w;
	}
	return (NVRM_OK);
}

static int
cpu_rw(nvrm_mem *m, uint64_t off, void *buf, size_t len, int write)
{
	nvrm_client *cl = m->cl;
	uint8_t *p;

	cl->errmsg[0] = '\0';
	if (m->cpu_addr == NULL)
		return (fail(cl, NVRM_E_INVAL, "the object is not mapped"));
	if ((m->cpu_prot & (write ? NVRM_CPU_WRITE : NVRM_CPU_READ)) == 0)
		return (fail(cl, NVRM_E_DENIED, "the mapping does not allow "
		    "this access"));
	if (off > m->bytes || len > m->bytes - off)
		return (fail(cl, NVRM_E_RANGE, "the access is outside the "
		    "object"));
	p = (uint8_t *)m->cpu_addr + off;
	if (m->cpu_attr != NVRM_ATTR_DEVICE) {
		if (write)
			memcpy(p, buf, len);
		else
			memcpy(buf, p, len);
		return (NVRM_OK);
	}
	return (dev_copy(m, p, buf, len, write));
}

int
nvrm_mem_read(nvrm_mem *m, uint64_t off, void *buf, size_t len)
{
	return (cpu_rw(m, off, buf, len, 0));
}

int
nvrm_mem_write(nvrm_mem *m, uint64_t off, const void *buf, size_t len)
{
	return (cpu_rw(m, off, (void *)(uintptr_t)buf, len, 1));
}

/* ---- sharing ------------------------------------------------------------- */

int
nvrm_mem_export_fd(nvrm_mem *m, int *fdp)
{
	nvrm_client *cl = m->cl;
	int fd, rc;

	cl->errmsg[0] = '\0';
	rc = owner_check(cl);
	if (rc != NVRM_OK)
		return (rc);
	if (m->kind == NVRM_MEM_USER)
		return (fail(cl, NVRM_E_INVAL, "registered user pages cannot "
		    "be exported"));
	rc = pool_take(cl, NVRM_DESC_EXPORT, &fd);
	if (rc != NVRM_OK)
		return (rc);
	rc = cl->mops->export_fd(m->b, fd, cl->errmsg, sizeof(cl->errmsg));
	if (rc != NVRM_OK) {
		close(fd);
		return (rc);
	}
	*fdp = fd;
	return (NVRM_OK);
}

int
nvrm_mem_import_fd(nvrm_client *cl, int fd, nvrm_mem **memp)
{
	nvrm_bmem_info bi = { .coherency = NVRM_COH_CACHED };
	nvrm_bmem *b;
	int rc;

	cl->errmsg[0] = '\0';
	rc = owner_check(cl);
	if (rc != NVRM_OK)
		return (rc);
	rc = cl->mops->import_fd(cl->bc, fd, &b, &bi, cl->errmsg,
	    sizeof(cl->errmsg));
	if (rc != NVRM_OK)
		return (rc);
	return (adopt(cl, NVRM_MEM_IMPORTED, b, &bi, memp));
}

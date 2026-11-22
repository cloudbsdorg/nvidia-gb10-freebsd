/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * nvrm_fake_mem.c - the fake backend's software GPU memory model (libnvrm S2,
 * Track #2419).  No hardware, no driver: every memory test runs anywhere.
 *
 *   - Per GPU one anonymous shared object is the whole "video memory plus
 *     system memory" aperture: the first part is video memory (sized from the
 *     profile, capped), the rest system memory.  An object is a region of it,
 *     so a CPU mapping (a real mmap of the aperture at the region's offset,
 *     through a descriptor limited to the mapping right) and the software GPU
 *     see the same bytes, as a coherent machine would.
 *   - The GPU's virtual address space is a table: reservations (sparse or
 *     not) and mappings of objects into them.  nvrm_fake_gpu_access() reads or
 *     writes through it as the GPU would: an unmapped address faults, except
 *     in a sparse reservation, where it reads zeros and drops writes.
 *   - The memory attribute rule is checked: a primitive access to memory whose
 *     attribute is Device must be aligned and 1, 2, 4 or 8 bytes wide, like
 *     the hardware (NVRM_FAKE_HOST=arm64 or amd64 sets the host the rule sees).
 *   - A sharing descriptor is a small anonymous object holding a record that
 *     names the memory object; an import finds the object by it.  The export
 *     keeps its object alive until the exporting client closes (the fake does
 *     not see a descriptor being closed).
 *
 * Process-wide state: use one thread.  After fork() the child shares the
 * aperture and has its own copy of the tables.
 */
#include <sys/types.h>
#include <sys/capsicum.h>
#include <sys/mman.h>

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "nvrm_internal.h"
#include "nvrm_fake.h"

#define FAKE_VRAM_MAX	(64ULL << 20)
#define FAKE_SYS_BYTES	(256ULL << 20)
#define FAKE_VA_BASE	0x10000ULL
#define FAKE_VA_END	(1ULL << 49)
#define EXPORT_MAGIC	0x6e76726d65787030ULL

typedef struct fake_obj {
	struct fake_obj	*next;
	struct fake_dev	*dev;
	uint64_t	serial, off, bytes, page_size;
	int		place;
	unsigned	refs;
} fake_obj;

typedef struct fake_dev {
	struct fake_dev	*next;
	uint32_t	id;
	int		fd;
	uint64_t	vram_bytes;
	nvrm_va		*region[2];	/* [0] video, [1] system; offsets */
	fake_obj	*objs;
	unsigned	nclients;
} fake_dev;

typedef struct fake_res {
	struct fake_res	*next;
	uint64_t	va, bytes;
	int		sparse;
} fake_res;

struct nvrm_bmem {
	nvrm_bclient	*c;
	fake_obj	*o;		/* NULL for registered user pages */
	void		*user;
	uint64_t	bytes;
};

typedef struct fake_map {
	struct fake_map	*next;
	uint64_t	va, length, offset;
	nvrm_bmem	*m;
	int		read_only;
} fake_map;

struct nvrm_bres {
	nvrm_bclient	*c;
	fake_res	r;
};

struct nvrm_bclient {
	fake_dev	*dev;
	fake_res	*res;
	fake_map	*maps;
	fake_obj	**exports;	/* references held for exports */
	unsigned	nexports;
};

static fake_dev *devs;
static unsigned fail_nth[NVRM_FAKE_OP__COUNT];
static uint64_t n_traps, n_checked;
static uint64_t next_serial = 1;
static unsigned live_objects, live_res, live_maps, live_clients;

void
nvrm_fake_mem_fail(int op, unsigned nth)
{
	fail_nth[op] = nth;
}

/* 1 when this call of the operation is to fail. */
static int
injected(int op)
{
	if (fail_nth[op] == 0 || --fail_nth[op] != 0)
		return (0);
	return (1);
}

#define INJECT(op, err, errlen) do {					\
	if (injected(op)) {						\
		snprintf(err, errlen, "fake backend: operation %d failed "\
		    "(injected)", op);					\
		return (NVRM_E_RM);					\
	}								\
} while (0)

/* ---- devices ------------------------------------------------------------- */

static fake_dev *
dev_get(const nvrm_gpu *g, char *err, size_t errlen)
{
	fake_dev *d;
	uint64_t vram;
	uint32_t id = nvrm_fake_gpu_id(g);
	int rc;

	for (d = devs; d != NULL; d = d->next)
		if (d->id == id) {
			d->nclients++;
			return (d);
		}
	d = NVRM_CALLOC(1, sizeof(*d));
	if (d == NULL) {
		snprintf(err, errlen, "out of memory");
		return (NULL);
	}
	vram = nvrm_fake_gpu_vram_kb(g) * 1024;
	d->vram_bytes = vram < FAKE_VRAM_MAX ? vram : FAKE_VRAM_MAX;
	d->fd = shm_open(SHM_ANON, O_RDWR, 0600);
	if (d->fd < 0) {
		snprintf(err, errlen, "fake backend: cannot make the "
		    "aperture: %s", strerror(errno));
		free(d);
		return (NULL);
	}
	rc = ftruncate(d->fd, d->vram_bytes + FAKE_SYS_BYTES);
	if (injected(NVRM_FAKE_OP_SIZE))
		rc = -1;
	if (rc != 0) {
		snprintf(err, errlen, "fake backend: cannot size the "
		    "aperture: %s", strerror(errno));
		close(d->fd);
		free(d);
		return (NULL);
	}
	d->id = id;
	d->region[1] = nvrm_va_new(d->vram_bytes,
	    d->vram_bytes + FAKE_SYS_BYTES);
	if (d->vram_bytes != 0)
		d->region[0] = nvrm_va_new(0, d->vram_bytes);
	if (d->region[1] == NULL || (d->vram_bytes != 0 &&
	    d->region[0] == NULL)) {
		snprintf(err, errlen, "out of memory");
		nvrm_va_destroy(d->region[0]);
		nvrm_va_destroy(d->region[1]);
		close(d->fd);
		free(d);
		return (NULL);
	}
	d->nclients = 1;
	d->next = devs;
	devs = d;
	return (d);
}

static void
dev_put(fake_dev *d)
{
	fake_dev **pp;

	if (--d->nclients != 0)
		return;
	for (pp = &devs; *pp != d; pp = &(*pp)->next)
		;
	*pp = d->next;
	nvrm_va_destroy(d->region[0]);
	nvrm_va_destroy(d->region[1]);
	close(d->fd);
	free(d);
}

/* ---- objects ------------------------------------------------------------- */

static void
obj_unref(fake_obj *o)
{
	fake_dev *d = o->dev;
	fake_obj **pp;

	if (--o->refs != 0)
		return;
	nvrm_va_free(d->region[o->place == NVRM_PLACE_VIDMEM ? 0 : 1], o->off,
	    o->bytes);
	for (pp = &d->objs; *pp != o; pp = &(*pp)->next)
		;
	*pp = o->next;
	live_objects--;
	free(o);
}

static fake_obj *
obj_new(fake_dev *d, int place, uint64_t bytes, uint64_t align,
    uint64_t page_size)
{
	fake_obj *o;
	nvrm_va *region = d->region[place == NVRM_PLACE_VIDMEM ? 0 : 1];
	uint64_t off, host = (uint64_t)sysconf(_SC_PAGESIZE);

	if (region == NULL)
		return (NULL);
	align += (host > align) * (host - align);	/* branch-free max */
	o = NVRM_CALLOC(1, sizeof(*o));
	if (o == NULL)
		return (NULL);
	if (nvrm_va_alloc(region, bytes, align, 0, 0, &off) != NVRM_OK) {
		free(o);
		return (NULL);
	}
	o->dev = d;
	o->serial = next_serial++;
	o->off = off;
	o->bytes = bytes;
	o->page_size = page_size;
	o->place = place;
	o->refs = 1;
	o->next = d->objs;
	d->objs = o;
	live_objects++;
	return (o);
}

/* ---- client -------------------------------------------------------------- */

static int
fk_client_open(nvrm_backend *be, nvrm_gpu *g, const nvrm_open_cfg *cfg,
    nvrm_bclient **bcp, nvrm_vainfo *va, char *err, size_t errlen)
{
	nvrm_bclient *c;

	INJECT(NVRM_FAKE_OP_CLIENT_OPEN, err, errlen);
	c = NVRM_CALLOC(1, sizeof(*c));
	if (c == NULL) {
		snprintf(err, errlen, "out of memory");
		return (NVRM_E_NOMEM);
	}
	c->dev = dev_get(g, err, errlen);
	if (c->dev == NULL) {
		free(c);
		return (NVRM_E_NOMEM);
	}
	live_clients++;
	va->base = FAKE_VA_BASE;
	va->end = FAKE_VA_END;
	*bcp = c;
	return (NVRM_OK);
}

static void
fk_client_close(nvrm_bclient *c)
{
	unsigned i;

	for (i = 0; i < c->nexports; i++)
		obj_unref(c->exports[i]);
	free(c->exports);
	live_clients--;
	dev_put(c->dev);
	free(c);
}

static int
fk_desc_open(nvrm_bclient *c, int kind, int *fd, char *err, size_t errlen)
{
	int rc;

	INJECT(NVRM_FAKE_OP_DESC, err, errlen);
	if (kind == NVRM_DESC_MAP)
		*fd = dup(c->dev->fd);
	else
		*fd = shm_open(SHM_ANON, O_RDWR, 0600);
	if (*fd < 0) {
		snprintf(err, errlen, "fake backend: cannot make a spare "
		    "descriptor: %s", strerror(errno));
		return (NVRM_E_IO);
	}
	rc = kind == NVRM_DESC_EXPORT ? ftruncate(*fd, 64) : 0;
	if (injected(NVRM_FAKE_OP_SIZE))
		rc = -1;
	if (rc != 0) {
		snprintf(err, errlen, "fake backend: cannot size a spare "
		    "descriptor: %s", strerror(errno));
		close(*fd);
		return (NVRM_E_IO);
	}
	rc = kind == NVRM_DESC_MAP ? nvrm_cap_limit_desc(*fd, kind) : NVRM_OK;
	if (injected(NVRM_FAKE_OP_LIMIT))
		rc = NVRM_E_CAPSICUM;
	if (rc != NVRM_OK) {
		snprintf(err, errlen, "fake backend: cannot limit a spare "
		    "descriptor");
		close(*fd);
		return (NVRM_E_CAPSICUM);
	}
	return (NVRM_OK);
}

/* ---- VA ------------------------------------------------------------------ */

static int
fk_va_reserve(nvrm_bclient *c, uint64_t va, uint64_t bytes, int sparse,
    nvrm_bres **rp, char *err, size_t errlen)
{
	nvrm_bres *r;

	INJECT(NVRM_FAKE_OP_VA_RESERVE, err, errlen);
	r = NVRM_CALLOC(1, sizeof(*r));
	if (r == NULL) {
		snprintf(err, errlen, "out of memory");
		return (NVRM_E_NOMEM);
	}
	r->c = c;
	r->r.va = va;
	r->r.bytes = bytes;
	r->r.sparse = sparse;
	r->r.next = c->res;
	c->res = &r->r;
	live_res++;
	*rp = r;
	return (NVRM_OK);
}

static void
fk_va_release(nvrm_bres *r)
{
	fake_res **pp;

	for (pp = &r->c->res; *pp != &r->r; pp = &(*pp)->next)
		;
	*pp = r->r.next;
	live_res--;
	free(r);
}

/* ---- memory -------------------------------------------------------------- */

static int
fk_mem_alloc(nvrm_bclient *c, const nvrm_balloc *a, nvrm_bmem **mp,
    nvrm_bmem_info *out, char *err, size_t errlen)
{
	nvrm_bmem *m;
	fake_obj *o;
	uint64_t ps = a->page_size != 0 ? a->page_size : 4096;

	INJECT(NVRM_FAKE_OP_ALLOC, err, errlen);
	m = NVRM_CALLOC(1, sizeof(*m));
	if (m == NULL) {
		snprintf(err, errlen, "out of memory");
		return (NVRM_E_NOMEM);
	}
	o = obj_new(c->dev, a->place, a->bytes,
	    a->alignment > ps ? a->alignment : ps, ps);
	if (o == NULL) {
		snprintf(err, errlen, "fake backend: out of %s memory",
		    a->place == NVRM_PLACE_VIDMEM ? "video" : "system");
		free(m);
		return (NVRM_E_NOMEM);
	}
	m->c = c;
	m->o = o;
	m->bytes = o->bytes;
	out->bytes = o->bytes;
	out->page_size = ps;
	out->place = a->place;
	*mp = m;
	return (NVRM_OK);
}

static int
fk_mem_register(nvrm_bclient *c, void *addr, uint64_t bytes, nvrm_bmem **mp,
    nvrm_bmem_info *out, char *err, size_t errlen)
{
	nvrm_bmem *m;

	INJECT(NVRM_FAKE_OP_REGISTER, err, errlen);
	m = NVRM_CALLOC(1, sizeof(*m));
	if (m == NULL) {
		snprintf(err, errlen, "out of memory");
		return (NVRM_E_NOMEM);
	}
	m->c = c;
	m->user = addr;
	m->bytes = bytes;
	out->bytes = bytes;
	out->page_size = 4096;
	out->place = NVRM_PLACE_SYSMEM;
	*mp = m;
	return (NVRM_OK);
}

static void
fk_mem_free(nvrm_bmem *m)
{
	if (m->o != NULL)
		obj_unref(m->o);
	free(m);
}

static int
fk_map_gpu(nvrm_bmem *m, nvrm_bres *r, uint64_t va, uint64_t offset,
    uint64_t length, int read_only, char *err, size_t errlen)
{
	fake_map *g;

	INJECT(NVRM_FAKE_OP_MAP_GPU, err, errlen);
	g = NVRM_CALLOC(1, sizeof(*g));
	if (g == NULL) {
		snprintf(err, errlen, "out of memory");
		return (NVRM_E_NOMEM);
	}
	g->va = va;
	g->length = length;
	g->offset = offset;
	g->m = m;
	g->read_only = read_only;
	g->next = r->c->maps;
	r->c->maps = g;
	live_maps++;
	return (NVRM_OK);
}

static void
fk_unmap_gpu(nvrm_bmem *m, nvrm_bres *r, uint64_t va, uint64_t length)
{
	(void)length;
	fake_map **pp, *g;

	for (pp = &r->c->maps; (*pp)->m != m || (*pp)->va != va;
	    pp = &(*pp)->next)
		;
	g = *pp;
	*pp = g->next;
	live_maps--;
	free(g);
}

static int
fk_map_cpu(nvrm_bmem *m, int fd, unsigned prot, void **addr, char *err,
    size_t errlen)
{
	void *p;
	int pr = ((prot & NVRM_CPU_READ) ? PROT_READ : 0) |
	    ((prot & NVRM_CPU_WRITE) ? PROT_WRITE : 0);

	INJECT(NVRM_FAKE_OP_MAP_CPU, err, errlen);
	p = mmap(NULL, m->o->bytes, pr, MAP_SHARED, fd, (off_t)m->o->off);
	if (p == MAP_FAILED) {
		snprintf(err, errlen, "fake backend: mmap failed: %s",
		    strerror(errno));
		return (NVRM_E_IO);
	}
	*addr = p;
	return (NVRM_OK);
}

static void
fk_unmap_cpu(nvrm_bmem *m, void *addr)
{
	munmap(addr, m->o->bytes);
}

/* ---- sharing ------------------------------------------------------------- */

typedef struct export_rec {
	uint64_t magic, dev, serial;
} export_rec;

static int
fk_export_fd(nvrm_bmem *m, int fd, char *err, size_t errlen)
{
	export_rec rec = { EXPORT_MAGIC, 0, 0 };
	cap_rights_t rights;
	nvrm_bclient *c = m->c;
	fake_obj **n;
	ssize_t wr;
	int r;

	INJECT(NVRM_FAKE_OP_EXPORT, err, errlen);
	rec.dev = m->o->dev->id;
	rec.serial = m->o->serial;
	wr = pwrite(fd, &rec, sizeof(rec), 0);
	if (injected(NVRM_FAKE_OP_WRITE))
		wr = -1;
	if (wr != (ssize_t)sizeof(rec)) {
		snprintf(err, errlen, "fake backend: cannot write the export "
		    "record: %s", strerror(errno));
		return (NVRM_E_IO);
	}
	cap_rights_init(&rights, CAP_READ, CAP_PREAD, CAP_FSTAT);
	r = cap_rights_limit(fd, &rights);
	if (injected(NVRM_FAKE_OP_RIGHTS))
		r = -1;
	if (r != 0) {
		snprintf(err, errlen, "fake backend: cannot limit the export "
		    "descriptor");
		return (NVRM_E_CAPSICUM);
	}
	n = NVRM_CALLOC(c->nexports + 1, sizeof(*n));
	if (n == NULL) {
		snprintf(err, errlen, "out of memory");
		return (NVRM_E_NOMEM);
	}
	if (c->nexports > 0)
		memcpy(n, c->exports, c->nexports * sizeof(*n));
	free(c->exports);
	c->exports = n;
	c->exports[c->nexports++] = m->o;
	m->o->refs++;
	return (NVRM_OK);
}

static int
fk_import_fd(nvrm_bclient *c, int fd, nvrm_bmem **mp, nvrm_bmem_info *out,
    char *err, size_t errlen)
{
	export_rec rec;
	fake_obj *o;
	nvrm_bmem *m;

	INJECT(NVRM_FAKE_OP_IMPORT, err, errlen);
	if (pread(fd, &rec, sizeof(rec), 0) != (ssize_t)sizeof(rec) ||
	    rec.magic != EXPORT_MAGIC) {
		snprintf(err, errlen, "fake backend: not an export descriptor");
		return (NVRM_E_RM);
	}
	for (o = c->dev->objs; o != NULL && o->serial != rec.serial;
	    o = o->next)
		;
	if (rec.dev != c->dev->id || o == NULL) {
		snprintf(err, errlen, "fake backend: the exported object is "
		    "not on this GPU, or is gone");
		return (NVRM_E_RM);
	}
	m = NVRM_CALLOC(1, sizeof(*m));
	if (m == NULL) {
		snprintf(err, errlen, "out of memory");
		return (NVRM_E_NOMEM);
	}
	o->refs++;
	m->c = c;
	m->o = o;
	m->bytes = o->bytes;
	out->bytes = o->bytes;
	out->page_size = o->page_size;
	out->place = o->place;
	*mp = m;
	return (NVRM_OK);
}

/* ---- the host and the attribute check ------------------------------------ */

static int
fk_host_arm64(void)
{
	const char *h = getenv("NVRM_FAKE_HOST");

	if (h != NULL && strcmp(h, "arm64") == 0)
		return (1);
	if (h != NULL && strcmp(h, "amd64") == 0)
		return (0);
#ifdef __aarch64__
	return (1);
#else
	return (0);
#endif
}

static int
fk_cpu_access(int attr, const volatile void *p, unsigned w, int write)
{
	(void)write;
	n_checked++;
	if (attr != NVRM_ATTR_DEVICE)
		return (0);
	if (w == 0 || w > 8 || (w & (w - 1)) != 0 ||
	    ((uintptr_t)p & (w - 1)) != 0) {
		n_traps++;
		return (-1);
	}
	return (0);
}

const nvrm_mem_ops nvrm_fake_mem_ops = {
	.client_open = fk_client_open,
	.client_close = fk_client_close,
	.desc_open = fk_desc_open,
	.va_reserve = fk_va_reserve,
	.va_release = fk_va_release,
	.mem_alloc = fk_mem_alloc,
	.mem_register = fk_mem_register,
	.mem_free = fk_mem_free,
	.map_gpu = fk_map_gpu,
	.unmap_gpu = fk_unmap_gpu,
	.map_cpu = fk_map_cpu,
	.unmap_cpu = fk_unmap_cpu,
	.export_fd = fk_export_fd,
	.import_fd = fk_import_fd,
	.host_arm64 = fk_host_arm64,
	.cpu_access = fk_cpu_access,
};

/* ---- the software GPU ------------------------------------------------------ */

static const fake_res *
res_at(const nvrm_bclient *c, uint64_t va)
{
	const fake_res *r;

	for (r = c->res; r != NULL; r = r->next)
		if (va >= r->va && va - r->va < r->bytes)
			return (r);
	return (NULL);
}

static const fake_map *
map_at(const nvrm_bclient *c, uint64_t va)
{
	const fake_map *g;

	for (g = c->maps; g != NULL; g = g->next)
		if (va >= g->va && va - g->va < g->length)
			return (g);
	return (NULL);
}

/* The next address after va where something starts: a mapping of the
 * reservation, or its end. */
static uint64_t
next_boundary(const nvrm_bclient *c, const fake_res *r, uint64_t va)
{
	const fake_map *g;
	uint64_t b = r->va + r->bytes;

	for (g = c->maps; g != NULL; g = g->next)
		if (g->va > va && g->va < b)
			b = g->va;
	return (b);
}

static void
gpu_copy(const nvrm_bclient *c, const fake_map *g, uint64_t va, void *buf,
    size_t n, int write)
{
	uint64_t off = g->offset + (va - g->va);
	nvrm_bmem *m = g->m;

	if (m->user != NULL) {
		if (write)
			memcpy((char *)m->user + off, buf, n);
		else
			memcpy(buf, (char *)m->user + off, n);
	} else if (write)
		(void)pwrite(c->dev->fd, buf, n, (off_t)(m->o->off + off));
	else
		(void)pread(c->dev->fd, buf, n, (off_t)(m->o->off + off));
}

int
nvrm_fake_gpu_access(nvrm_client *cl, uint64_t va, void *buf, size_t len,
    int write)
{
	const nvrm_bclient *c = cl->bc;
	const fake_res *r;
	const fake_map *g;
	char *p = buf;
	uint64_t n;

	while (len > 0) {
		r = res_at(c, va);
		if (r == NULL)
			return (NVRM_FAKE_FAULT_UNMAPPED);
		g = map_at(c, va);
		if (g == NULL) {
			if (!r->sparse)
				return (NVRM_FAKE_FAULT_UNMAPPED);
			n = next_boundary(c, r, va) - va;
			if (n > len)
				n = len;
			if (!write)
				memset(p, 0, n);	/* sparse: zeros */
		} else {
			if (write && g->read_only)
				return (NVRM_FAKE_FAULT_READONLY);
			n = g->length - (va - g->va);
			if (n > len)
				n = len;
			gpu_copy(c, g, va, p, n, write);
		}
		va += n;
		p += n;
		len -= n;
	}
	return (0);
}

/* ---- test controls --------------------------------------------------------- */

void
nvrm_fake_mem_stats_get(nvrm_fake_mem_stats *st)
{
	const fake_dev *d;

	memset(st, 0, sizeof(*st));
	st->clients = live_clients;
	st->objects = live_objects;
	st->reservations = live_res;
	st->gpu_maps = live_maps;
	st->traps = n_traps;
	st->checked = n_checked;
	for (d = devs; d != NULL; d = d->next) {
		if (d->region[0] != NULL) {
			st->vram_free += nvrm_va_free_bytes(d->region[0]);
			st->vram_extents += nvrm_va_extents(d->region[0]);
		}
		st->sys_free += nvrm_va_free_bytes(d->region[1]);
		st->sys_extents += nvrm_va_extents(d->region[1]);
	}
}

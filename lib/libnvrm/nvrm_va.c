/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * nvrm_va.c - the GPU virtual address range allocator (libnvrm S2, Track
 * #2419).  Pure bookkeeping, no system calls: the library decides which
 * addresses a client uses and the RM maps at exactly those, so one allocator
 * serves every backend.  Free space is a sorted list of extents [start, end);
 * the end is exclusive and may be 2^64 - 1 at most (a space that ends at the
 * top of the 64-bit range is not representable and is refused).
 *
 * Every operation leaves the allocator unchanged when it fails.
 */
#include <stdlib.h>

#include "nvrm_internal.h"

typedef struct extent {
	struct extent	*next;
	uint64_t	start, end;
} extent;

struct nvrm_va {
	uint64_t	base, end;
	extent		*free_list;
};

nvrm_va *
nvrm_va_new(uint64_t base, uint64_t end)
{
	nvrm_va *va;

	if (end <= base)
		return (NULL);
	va = NVRM_CALLOC(1, sizeof(*va));
	if (va == NULL)
		return (NULL);
	va->free_list = NVRM_CALLOC(1, sizeof(extent));
	if (va->free_list == NULL) {
		free(va);
		return (NULL);
	}
	va->base = base;
	va->end = end;
	va->free_list->start = base;
	va->free_list->end = end;
	return (va);
}

void
nvrm_va_destroy(nvrm_va *va)
{
	extent *e, *n;

	if (va == NULL)
		return;
	for (e = va->free_list; e != NULL; e = n) {
		n = e->next;
		free(e);
	}
	free(va);
}

/* The first address at or above a that is a multiple of align (a power of
 * two), or 0 with *ok = 0 when that wraps. */
static uint64_t
align_up(uint64_t a, uint64_t align, int *ok)
{
	uint64_t m = align - 1;

	*ok = a <= UINT64_MAX - m;
	return (*ok ? (a + m) & ~m : 0);
}

/* Remove [s, e) from the extent *pp points at (which must contain it). */
static int
carve(extent **pp, uint64_t s, uint64_t e)
{
	extent *x = *pp, *tail;

	if (x->start == s && x->end == e) {
		*pp = x->next;
		free(x);
		return (NVRM_OK);
	}
	if (x->start == s) {
		x->start = e;
		return (NVRM_OK);
	}
	if (x->end == e) {
		x->end = s;
		return (NVRM_OK);
	}
	tail = NVRM_CALLOC(1, sizeof(*tail));
	if (tail == NULL)
		return (NVRM_E_NOMEM);
	tail->start = e;
	tail->end = x->end;
	tail->next = x->next;
	x->end = s;
	x->next = tail;
	return (NVRM_OK);
}

int
nvrm_va_alloc(nvrm_va *va, uint64_t size, uint64_t align, int have_fixed,
    uint64_t fixed, uint64_t *out)
{
	extent **pp;
	uint64_t s;
	int ok;

	if (size == 0 || (align & (align - 1)) != 0)
		return (NVRM_E_INVAL);
	if (align == 0)
		align = 1;
	for (pp = &va->free_list; *pp != NULL; pp = &(*pp)->next) {
		if (have_fixed) {
			if (fixed < (*pp)->start)
				break;		/* sorted: it is not free */
			s = fixed;
			if ((s & (align - 1)) != 0)
				return (NVRM_E_INVAL);
		} else {
			s = align_up((*pp)->start, align, &ok);
			if (!ok)
				continue;
		}
		if (s >= (*pp)->end || size > (*pp)->end - s)
			continue;
		if (carve(pp, s, s + size) != NVRM_OK)
			return (NVRM_E_NOMEM);
		*out = s;
		return (NVRM_OK);
	}
	return (NVRM_E_RANGE);
}

int
nvrm_va_free(nvrm_va *va, uint64_t addr, uint64_t size)
{
	extent **pp, *prev, *n;
	uint64_t e;

	if (size == 0 || addr < va->base || addr >= va->end ||
	    size > va->end - addr)
		return (NVRM_E_INVAL);
	e = addr + size;
	prev = NULL;
	for (pp = &va->free_list; *pp != NULL && (*pp)->end <= addr;
	    pp = &(*pp)->next)
		prev = *pp;
	if (*pp != NULL && (*pp)->start < e)
		return (NVRM_E_RANGE);		/* part of it is free already */
	if (prev != NULL && prev->end == addr) {
		prev->end = e;
		if (prev->next != NULL && prev->next->start == e) {
			n = prev->next;
			prev->end = n->end;
			prev->next = n->next;
			free(n);
		}
		return (NVRM_OK);
	}
	if (*pp != NULL && (*pp)->start == e) {
		(*pp)->start = addr;
		return (NVRM_OK);
	}
	n = NVRM_CALLOC(1, sizeof(*n));
	if (n == NULL)
		return (NVRM_E_NOMEM);
	n->start = addr;
	n->end = e;
	n->next = *pp;
	*pp = n;
	return (NVRM_OK);
}

uint64_t
nvrm_va_free_bytes(const nvrm_va *va)
{
	const extent *e;
	uint64_t n = 0;

	for (e = va->free_list; e != NULL; e = e->next)
		n += e->end - e->start;
	return (n);
}

unsigned
nvrm_va_extents(const nvrm_va *va)
{
	const extent *e;
	unsigned n = 0;

	for (e = va->free_list; e != NULL; e = e->next)
		n++;
	return (n);
}

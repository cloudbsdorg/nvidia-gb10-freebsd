/* host stub: kernel malloc(9) on top of calloc; counts live allocations */
#ifndef _STUB_MALLOC_H
#define _STUB_MALLOC_H
#include <stdlib.h>
extern int stub_live_allocs;
#define MALLOC_DEFINE(a, b, c) int stub_mtype_##a __attribute__((unused))
#define M_WAITOK 0
#define M_ZERO 0
static inline void *stub_malloc(size_t n) { stub_live_allocs++; return calloc(1, n); }
static inline void stub_free(void *p) { if (p != NULL) { stub_live_allocs--; free(p); } }
#define malloc(sz, t, f) stub_malloc(sz)
#define free(p, t) stub_free(p)
#endif

/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-3-Clause
 *
 * open_dev_harness.c - Track #2417: nvidia_open_dev() and nvidia_close_dev()
 * of the OS layer, compiled as the driver compiles them (the test extracts
 * the two functions from a prepared nvidia_subr.c into OPEN_DEV_SRC and this
 * file includes that text), against stubs for the resource manager.
 *
 * The stubs model the one fact the 2026-11-22 panic turned on: when
 * rm_init_adapter() fails, RmInitAdapter's own cleanup has already cleared
 * the private state's pGpu, so rm_disable_adapter() - which dereferences
 * pGpu - must never run after a failed init.  The stub for
 * rm_init_adapter() clears pGpu and returns false; the stub for
 * rm_disable_adapter() records a violation when pGpu is NULL (the real code
 * faults at NULL+0x19f8 there); rm_shutdown_adapter() is NULL-safe as in
 * the resource manager and only records its call.
 *
 * Scenarios (each prints "case <n> <what>: ok|FAIL"; exit 1 on any FAIL):
 *   1 init fails      -> EIO, disable never runs with a NULL pGpu (at all),
 *                        shutdown runs once with the stack, stacks freed,
 *                        api lock released, refcnt unchanged, not open
 *   2 stack alloc fails (sp NULL) -> ENOMEM, no RM call of either kind,
 *                        lock released
 *   3 init succeeds   -> 0, refcnt 1, NV_FLAG_OPEN, no RM teardown
 *   4 last close      -> disable then shutdown, once each, pGpu live for
 *                        the disable, stacks freed
 *   5 a failed open and then a good one on the SAME softc and state (no
 *                        reset between): the second open succeeds, takes
 *                        exactly one stack set (the failed open left none
 *                        behind), shutdown ran once in all, disable never
 *
 * Every RM stub also counts a call made with a NULL or a stale stack
 * pointer: sc->sp[] is poisoned before case 2, so a failed:-path that used
 * a stack the allocation never produced is seen.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define ENOMEM 12
#define EIO 5
typedef int NvBool;
typedef unsigned int NvU32;
#define NV_FLAG_OPEN 0x1
#define NV_DEV_STACK_API 0
#define NV_DEV_STACK_COUNT 1

typedef struct nvidia_stack { int tag; } nvidia_stack_t;
typedef struct nv_state { void *pGpu; unsigned flags; void *os_state; } nv_state_t;
typedef struct nv_freebsd_file_private { nvidia_stack_t *fops_sp; int nvfp; } nv_freebsd_file_private_t;
struct nvidia_softc {
	int refcnt;
	void *dev;
	nvidia_stack_t *sp[NV_DEV_STACK_COUNT];
};

/* the driver's macro, taken from the tree under test (OPEN_DEV_MACRO) */
#include OPEN_DEV_MACRO

static int g_alloc_fail, g_init_fail;
static int n_disable, n_disable_nullgpu, n_shutdown, n_free, n_lock, n_unlock;
static int n_rm_with_null_sp, n_shutdown_before_disable_order, n_live;
static nvidia_stack_t *const g_poison = (nvidia_stack_t *)0x1;
static nvidia_stack_t g_stack;
static int g_gpu_obj;

#define device_printf(d, ...) ((void)(d))
static void nv_lock_api(nv_state_t *nv) { (void)nv; n_lock++; }
static void nv_unlock_api(nv_state_t *nv) { (void)nv; n_unlock++; }
static int nv_dev_alloc_stacks(struct nvidia_softc *sc)
{
	if (g_alloc_fail)
		return ENOMEM;
	sc->sp[NV_DEV_STACK_API] = &g_stack;
	n_live++;
	return 0;
}
static void nv_dev_free_stacks(struct nvidia_softc *sc)
{
	n_free++;
	if (sc->sp[NV_DEV_STACK_API] == &g_stack)
		n_live--;
	sc->sp[NV_DEV_STACK_API] = NULL;
}
static void rm_set_rm_firmware_requested(nvidia_stack_t *sp, nv_state_t *nv)
{
	(void)sp; (void)nv;
}
static int rm_init_adapter(nvidia_stack_t *sp, nv_state_t *nv)
{
	if (sp == NULL || sp == g_poison)
		n_rm_with_null_sp++;
	if (g_init_fail) {
		nv->pGpu = NULL;	/* RmInitAdapter's cleanup (RmClearPrivateState) */
		return 0;
	}
	nv->pGpu = &g_gpu_obj;
	return 1;
}
static void rm_disable_adapter(nvidia_stack_t *sp, nv_state_t *nv)
{
	if (sp == NULL || sp == g_poison)
		n_rm_with_null_sp++;
	n_disable++;
	if (nv->pGpu == NULL)
		n_disable_nullgpu++;	/* the real RmDisableAdapter faults here */
}
static void rm_shutdown_adapter(nvidia_stack_t *sp, nv_state_t *nv)
{
	if (sp == NULL || sp == g_poison)
		n_rm_with_null_sp++;
	if (n_disable == 0)
		n_shutdown_before_disable_order++;
	n_shutdown++;
	(void)nv;
}
static void rm_cleanup_file_private(nvidia_stack_t *sp, nv_state_t *nv, int *nvfp)
{
	(void)sp; (void)nv; (void)nvfp;
}

#include OPEN_DEV_SRC

static int fails;
static void check(const char *name, int cond)
{
	printf("case %s: %s\n", name, cond ? "ok" : "FAIL");
	if (!cond)
		fails++;
}
static void reset(struct nvidia_softc *sc, nv_state_t *nv, int refcnt)
{
	n_disable = n_disable_nullgpu = n_shutdown = n_free = 0;
	n_lock = n_unlock = n_rm_with_null_sp = n_shutdown_before_disable_order = 0;
	n_live = 0;
	g_alloc_fail = g_init_fail = 0;
	memset(sc, 0, sizeof(*sc));
	memset(nv, 0, sizeof(*nv));
	sc->refcnt = refcnt;
	nv->os_state = sc;
	nv->pGpu = &g_gpu_obj;
}

static struct nvidia_softc sc;
static nv_state_t nv;

static void case1_init_fails(void)
{
	int st;

	reset(&sc, &nv, 0);
	g_init_fail = 1;
	st = nvidia_open_dev(&nv, NULL);
	check("1 init fails: EIO", st == EIO);
	check("1 init fails: rm_disable_adapter never sees a NULL pGpu", n_disable_nullgpu == 0);
	check("1 init fails: rm_disable_adapter not called at all", n_disable == 0);
	check("1 init fails: rm_shutdown_adapter called once, with a real stack",
	    n_shutdown == 1 && n_rm_with_null_sp == 0);
	check("1 init fails: no stack left behind", n_live == 0 && sc.sp[NV_DEV_STACK_API] == NULL);
	check("1 init fails: stacks freed, lock released, not open",
	    n_free == 1 && n_lock == 1 && n_unlock == 1 &&
	    sc.refcnt == 0 && (nv.flags & NV_FLAG_OPEN) == 0);
}

static void case2_alloc_fails(void)
{
	int st;

	reset(&sc, &nv, 0);
	g_alloc_fail = 1;
	sc.sp[NV_DEV_STACK_API] = g_poison;	/* what a stale slot would hold */
	st = nvidia_open_dev(&nv, NULL);
	check("2 stack alloc fails: ENOMEM", st == ENOMEM);
	check("2 stack alloc fails: no RM call at all (sp is NULL)",
	    n_disable == 0 && n_shutdown == 0 && n_rm_with_null_sp == 0);
	check("2 stack alloc fails: lock released", n_lock == 1 && n_unlock == 1);
}

static void case3_and_4_open_close(void)
{
	int st;

	reset(&sc, &nv, 0);
	st = nvidia_open_dev(&nv, NULL);
	check("3 init succeeds: 0, refcnt 1, open",
	    st == 0 && sc.refcnt == 1 && (nv.flags & NV_FLAG_OPEN) != 0);
	check("3 init succeeds: no teardown", n_disable == 0 && n_shutdown == 0 && n_free == 0);

	/* last close: the stack the open took is still there */
	sc.sp[NV_DEV_STACK_API] = &g_stack;
	n_disable = n_disable_nullgpu = n_shutdown = n_free = 0;
	n_shutdown_before_disable_order = 0;
	nvidia_close_dev(&nv, NULL);
	check("4 last close: disable then shutdown, once each, pGpu live",
	    n_disable == 1 && n_shutdown == 1 && n_disable_nullgpu == 0 &&
	    n_shutdown_before_disable_order == 0);
	check("4 last close: stacks freed, not open",
	    n_free == 1 && sc.refcnt == 0 && (nv.flags & NV_FLAG_OPEN) == 0);
}

/* 5: a failed open, then a good one, on the same state */
static void case5_retry(void)
{
	int st;

	reset(&sc, &nv, 0);
	g_init_fail = 1;
	st = nvidia_open_dev(&nv, NULL);
	check("5 retry: the first open fails with EIO", st == EIO);
	g_init_fail = 0;
	st = nvidia_open_dev(&nv, NULL);
	check("5 retry: the second open succeeds, refcnt 1, open",
	    st == 0 && sc.refcnt == 1 && (nv.flags & NV_FLAG_OPEN) != 0);
	check("5 retry: one stack set live, shutdown once in all, disable never, lock balanced",
	    n_live == 1 && n_shutdown == 1 && n_disable == 0 &&
	    n_lock == 2 && n_unlock == 2 && n_rm_with_null_sp == 0);
	nvidia_close_dev(&nv, NULL);
	check("5 retry: the close tears down once and leaves no stack",
	    n_disable == 1 && n_disable_nullgpu == 0 && n_live == 0 && sc.refcnt == 0);
}

int main(void)
{
	case1_init_fails();
	case2_alloc_fails();
	case3_and_4_open_close();
	case5_retry();
	printf("%s\n", fails == 0 ? "HARNESS PASS" : "HARNESS FAIL");
	return fails == 0 ? 0 : 1;
}

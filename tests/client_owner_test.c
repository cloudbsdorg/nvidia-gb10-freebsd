/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-3-Clause
 *
 * client_owner_test.c - the client ownership table of
 * src/gb10-client-owner/nv_client_owner.h (Track #2373): which file a
 * client was allocated on, through the ioctls that allocate and free one.
 * With -DWITH_NVOS the layouts of the header's structures are compared to
 * the real nvos.h (MIT).
 */

#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define	NVCO_MALLOC(n)	malloc(n)
#define	NVCO_FREE(p)	free(p)
#include "nv_client_owner.h"

#ifdef WITH_NVOS
#include "nvtypes.h"
#include "nvos.h"
#include "nv_escape.h"
#define	SAME(mine, real, field) \
	_Static_assert(offsetof(struct mine, field) == offsetof(real, field), #mine "." #field " offset differs from nvos.h")
_Static_assert(sizeof(struct nvco_free_params) == sizeof(NVOS00_PARAMETERS), "NVOS00 size");
_Static_assert(sizeof(struct nvco_alloc_object_params) == sizeof(NVOS05_PARAMETERS), "NVOS05 size");
_Static_assert(sizeof(struct nvco_alloc_params) == sizeof(NVOS21_PARAMETERS), "NVOS21 size");
_Static_assert(sizeof(struct nvco_alloc64_params) == sizeof(NVOS64_PARAMETERS), "NVOS64 size");
SAME(nvco_free_params, NVOS00_PARAMETERS, hRoot);
SAME(nvco_free_params, NVOS00_PARAMETERS, hObjectOld);
SAME(nvco_free_params, NVOS00_PARAMETERS, status);
SAME(nvco_alloc_object_params, NVOS05_PARAMETERS, hObjectNew);
SAME(nvco_alloc_object_params, NVOS05_PARAMETERS, hClass);
SAME(nvco_alloc_object_params, NVOS05_PARAMETERS, status);
SAME(nvco_alloc_params, NVOS21_PARAMETERS, hObjectNew);
SAME(nvco_alloc_params, NVOS21_PARAMETERS, hClass);
SAME(nvco_alloc_params, NVOS21_PARAMETERS, status);
SAME(nvco_alloc64_params, NVOS64_PARAMETERS, hObjectNew);
SAME(nvco_alloc64_params, NVOS64_PARAMETERS, hClass);
SAME(nvco_alloc64_params, NVOS64_PARAMETERS, status);
_Static_assert(NVCO_ESC_RM_ALLOC == NV_ESC_RM_ALLOC, "NV_ESC_RM_ALLOC");
_Static_assert(NVCO_ESC_RM_ALLOC_OBJECT == NV_ESC_RM_ALLOC_OBJECT, "NV_ESC_RM_ALLOC_OBJECT");
_Static_assert(NVCO_ESC_RM_FREE == NV_ESC_RM_FREE, "NV_ESC_RM_FREE");
_Static_assert(NVCO_CLASS_ROOT == NV01_ROOT, "NV01_ROOT");
_Static_assert(NVCO_CLASS_ROOT_NON_PRIV == NV01_ROOT_NON_PRIV, "NV01_ROOT_NON_PRIV");
_Static_assert(NVCO_CLASS_ROOT_CLIENT == NV01_ROOT_CLIENT, "NV01_ROOT_CLIENT");
#endif

static int fails;

#define	CHECK(cond, ...) do {						\
	if (!(cond)) {							\
		fails++;						\
		printf("FAIL %s:%d: ", __FILE__, __LINE__);		\
		printf(__VA_ARGS__);					\
		printf("\n");						\
	}								\
} while (0)

#define	A_FILE	((const void *)0x1000)
#define	B_FILE	((const void *)0x2000)
#define	A_FP	((const void *)0x1001)	/* the open file the owner's hold is taken on */
#define	B_FP	((const void *)0x2001)
#define	C_FILE	((const void *)0x3000)
#define	CA	0xC1D00000u
#define	CB	0xC1D00001u

static struct nvco_table t;
static int unl;	/* nvco_begin_free's out parameter, kept for the matching end */

/* a record with no free in flight (the model tests of a quiet table); the kernel always passes the mark it took */
static int
nvco_after_ioctl(struct nvco_table *tt, const void *owner, unsigned nr, size_t size, const void *args)
{
	return (nvco_after_ioctl_marked(tt, owner, nr, size, args, nvco_alloc_mark(tt)));
}

static void
alloc21(const void *f, uint32_t h, uint32_t cls, uint32_t status)
{
	struct nvco_alloc_params p;

	memset(&p, 0, sizeof(p));
	p.hRoot = p.hObjectParent = p.hObjectNew = h;
	p.hClass = cls;
	p.status = status;
	nvco_after_ioctl(&t, f, NVCO_ESC_RM_ALLOC, sizeof(p), &p);
}

static void
alloc64(const void *f, uint32_t h, uint32_t cls, uint32_t status)
{
	struct nvco_alloc64_params p;

	memset(&p, 0, sizeof(p));
	p.hRoot = p.hObjectParent = p.hObjectNew = h;
	p.hClass = cls;
	p.status = status;
	nvco_after_ioctl(&t, f, NVCO_ESC_RM_ALLOC, sizeof(p), &p);
}

static void
free_obj(const void *f, uint32_t root, uint32_t old, uint32_t status)
{
	struct nvco_free_params p = { root, root, old, status };

	nvco_after_ioctl(&t, f, NVCO_ESC_RM_FREE, sizeof(p), &p);
}

/* a fresh table: A owns CA (NVOS64, NV01_ROOT), B owns CB (NVOS21, NV01_ROOT_NON_PRIV) */
static void
fresh(void)
{
	nvco_destroy(&t);
	alloc64(A_FILE, CA, NVCO_CLASS_ROOT, 0);
	alloc21(B_FILE, CB, NVCO_CLASS_ROOT_NON_PRIV, 0);
}

static void
test_recording(void)
{
	struct nvco_alloc_object_params ao;

	nvco_destroy(&t);

	/* two users, each with a client on their own file */
	alloc64(A_FILE, CA, NVCO_CLASS_ROOT, 0);
	alloc21(B_FILE, CB, NVCO_CLASS_ROOT_NON_PRIV, 0);
	CHECK(nvco_owns(&t, A_FILE, CA), "A owns its client (NVOS64, NV01_ROOT)");
	CHECK(nvco_owns(&t, B_FILE, CB), "B owns its client (NVOS21, NV01_ROOT_NON_PRIV)");
	CHECK(!nvco_owns(&t, B_FILE, CA), "B does not own A's client");
	CHECK(!nvco_owns(&t, A_FILE, CB), "A does not own B's client");
	CHECK(!nvco_owns(&t, A_FILE, CA + 2), "an unallocated handle is owned by nobody");
	CHECK(!nvco_owns(&t, NULL, CA), "a NULL owner owns no client");

	/* NV01_ROOT_CLIENT, the class new client code allocates */
	alloc64(A_FILE, 0xCAFE0010u, NVCO_CLASS_ROOT_CLIENT, 0);
	CHECK(nvco_owns(&t, A_FILE, 0xCAFE0010u), "NV01_ROOT_CLIENT makes a client");
	{
		struct nvco_alloc64_params p64;

		memset(&p64, 0, sizeof(p64));
		p64.hClass = NVCO_CLASS_ROOT_CLIENT;
		CHECK(nvco_is_client_op(NVCO_ESC_RM_ALLOC, sizeof(p64), &p64), "NV01_ROOT_CLIENT alloc is a client op");
	}
	nvco_remove_handle(&t, 0xCAFE0010u);

	/* only root classes make a client; a device (0x80) or a memory object is not one */
	alloc64(A_FILE, 0xCAFE0001u, 0x80, 0);
	CHECK(!nvco_owns(&t, A_FILE, 0xCAFE0001u), "a non-root class is not a client");
	/* failed allocations are not recorded */
	alloc64(A_FILE, 0xCAFE0002u, NVCO_CLASS_ROOT, 0x1B);
	alloc21(A_FILE, 0xCAFE0003u, NVCO_CLASS_ROOT, 0x1B);
	CHECK(!nvco_owns(&t, A_FILE, 0xCAFE0002u) && !nvco_owns(&t, A_FILE, 0xCAFE0003u),
	    "a failed allocation (params status) is not recorded");
	/* a wrong argument size is ignored, not guessed */
	{
		struct nvco_alloc64_params p;

		memset(&p, 0, sizeof(p));
		p.hObjectNew = 0xCAFE0004u;
		nvco_after_ioctl(&t, A_FILE, NVCO_ESC_RM_ALLOC, sizeof(p) - 1, &p);
		CHECK(!nvco_owns(&t, A_FILE, 0xCAFE0004u), "an ALLOC with an odd size is ignored");
	}
	/* the legacy allocation ioctl */
	memset(&ao, 0, sizeof(ao));
	ao.hObjectNew = 0xCAFE0005u;
	ao.hClass = NVCO_CLASS_ROOT;
	nvco_after_ioctl(&t, A_FILE, NVCO_ESC_RM_ALLOC_OBJECT, sizeof(ao), &ao);
	CHECK(nvco_owns(&t, A_FILE, 0xCAFE0005u), "NV_ESC_RM_ALLOC_OBJECT with NV01_ROOT makes a client");
	/* another escape code is ignored */
	{
		struct nvco_alloc_params p;

		memset(&p, 0, sizeof(p));
		p.hObjectNew = 0xCAFE0006u;
		nvco_after_ioctl(&t, A_FILE, 0x2A, sizeof(p), &p);
		CHECK(!nvco_owns(&t, A_FILE, 0xCAFE0006u), "another escape code records nothing");
	}

	/* a file that is not an nvidiactl file (owner NULL) owns nothing */
	{
		size_t before = t.n;

		alloc64(NULL, 0xCAFE0007u, NVCO_CLASS_ROOT, 0);
		CHECK(t.n == before, "an ownerless allocation adds no entry");
	}
	CHECK(!nvco_owns(&t, NULL, 0xCAFE0007u) && !nvco_owns(&t, A_FILE, 0xCAFE0007u),
	    "an add with no owner records nothing");

	/* the operations that must be serialised with the table (decoded before the RM call) */
	{
		struct nvco_alloc64_params p64;
		struct nvco_alloc_params p21;
		struct nvco_free_params fr = { CA, CA, CA, 0 }, fc = { CA, CA, CA + 5, 0 };

		memset(&p64, 0, sizeof(p64));
		memset(&p21, 0, sizeof(p21));
		CHECK(nvco_is_client_op(NVCO_ESC_RM_ALLOC, sizeof(p64), &p64), "NVOS64 root alloc is a client op");
		p21.hClass = NVCO_CLASS_ROOT_NON_PRIV;
		CHECK(nvco_is_client_op(NVCO_ESC_RM_ALLOC, sizeof(p21), &p21), "NVOS21 non-priv root alloc is a client op");
		p64.hClass = 0x80;
		CHECK(!nvco_is_client_op(NVCO_ESC_RM_ALLOC, sizeof(p64), &p64), "a device alloc is not");
		CHECK(!nvco_is_client_op(NVCO_ESC_RM_ALLOC, sizeof(p64) - 1, &p64), "an odd size is not");
		CHECK(nvco_is_client_op(NVCO_ESC_RM_FREE, sizeof(fr), &fr), "freeing the client is a client op");
		CHECK(!nvco_is_client_op(NVCO_ESC_RM_FREE, sizeof(fc), &fc), "freeing a child is not");
		CHECK(!nvco_is_client_op(0x2A, sizeof(p21), &p21), "a control call is not");
	}

}

static void
test_decoding_and_holds(void)
{
	fresh();
	/* NV_ESC_RM_ALLOC_OBJECT is decoded too (a legacy root client must take the lock and be recorded) */
	{
		struct nvco_alloc_object_params o;

		memset(&o, 0, sizeof(o));
		o.hClass = NVCO_CLASS_ROOT;
		CHECK(nvco_is_client_op(NVCO_ESC_RM_ALLOC_OBJECT, sizeof(o), &o), "NV_ESC_RM_ALLOC_OBJECT with NV01_ROOT is a client op");
		o.hClass = 0x80;
		CHECK(!nvco_is_client_op(NVCO_ESC_RM_ALLOC_OBJECT, sizeof(o), &o), "NV_ESC_RM_ALLOC_OBJECT with a device class is not");
	}
	/* one decoder: a request that is not a client op changes nothing, whatever the layout says */
	{
		struct nvco_alloc64_params p64;
		size_t before = t.n;

		memset(&p64, 0, sizeof(p64));
		p64.hObjectNew = 0xCAFE0008u;
		p64.hClass = NVCO_CLASS_ROOT;
		nvco_after_ioctl(&t, A_FILE, 0x2A, sizeof(p64), &p64);
		nvco_after_ioctl(&t, A_FILE, NVCO_ESC_RM_ALLOC, sizeof(p64) + 8, &p64);
		CHECK(t.n == before, "a non-client op records nothing");
	}
	/* a client allocated where nothing can own it evicts a stale entry for its handle (the RM reused it) */
	alloc64(A_FILE, 0xCAFE0009u, NVCO_CLASS_ROOT, 0);
	CHECK(nvco_owns(&t, A_FILE, 0xCAFE0009u), "stale entry listed");
	alloc64(NULL, 0xCAFE0009u, NVCO_CLASS_ROOT, 0);
	CHECK(!nvco_owns(&t, A_FILE, 0xCAFE0009u), "an ownerless allocation of the handle evicts the stale entry");
	/* holds: per client, only for the owner, and a free waits for them */
	{
		int ok;
		struct nvco_free_params fr = { CB, CB, CB, 0 }, fc = { CB, CB, CB + 1, 0 };

		CHECK(!nvco_hold(&t, A_FILE, A_FP, CB), "A cannot hold B's client");
		CHECK(!nvco_hold(&t, NULL, B_FP, CB), "no file holds anything");
		CHECK(!nvco_hold(&t, B_FILE, B_FP, CB + 77), "an unlisted handle cannot be held");
		CHECK(!nvco_busy(&t, CB), "nothing in flight");
		CHECK(nvco_hold(&t, B_FILE, B_FP, CB), "B holds its client");
		CHECK(nvco_hold(&t, B_FILE, B_FP, CB), "holds nest per client");
		CHECK(nvco_busy(&t, CB), "busy while held");
		CHECK(!nvco_busy(&t, CA + 9), "another client is not busy");
		CHECK(nvco_unhold(&t, B_FP, CB) && nvco_busy(&t, CB), "one of two holds dropped: still busy");
		CHECK(nvco_unhold(&t, B_FP, CB) && !nvco_busy(&t, CB), "second drop: free to go");
		CHECK(!nvco_unhold(&t, B_FP, CB), "an unmatched release changes nothing and says so");
		CHECK(!nvco_busy(&t, CB), "an unmatched release does not underflow");
		(void)nvco_client_free_handle(NVCO_ESC_RM_FREE, sizeof(fr), &fr, &ok);
		CHECK(ok && nvco_client_free_handle(NVCO_ESC_RM_FREE, sizeof(fr), &fr, &ok) == CB, "a client free names its handle");
		(void)nvco_client_free_handle(NVCO_ESC_RM_FREE, sizeof(fc), &fc, &ok);
		CHECK(!ok, "a child free names none");
	}

	/* freeing a child object is not freeing the client */
	free_obj(A_FILE, CA, CA + 100, 0);
	CHECK(nvco_owns(&t, A_FILE, CA), "freeing a child leaves the client");
	/* a failed free leaves it */
	free_obj(A_FILE, CA, CA, 0x1B);
	CHECK(nvco_owns(&t, A_FILE, CA), "a failed free leaves the client");

	/* B frees A's client through B's file (RM may allow it): the handle leaves the table for everyone */
	free_obj(B_FILE, CA, CA, 0);
	CHECK(!nvco_owns(&t, A_FILE, CA), "a freed client is gone from its owner");
	/* the RM reuses the handle for B: B owns it, A cannot claim it */
	alloc64(B_FILE, CA, NVCO_CLASS_ROOT, 0);
	CHECK(nvco_owns(&t, B_FILE, CA) && !nvco_owns(&t, A_FILE, CA), "a reused handle belongs to its new owner");
	/* an add for a listed handle by the same owner changes nothing */
	alloc64(B_FILE, CA, NVCO_CLASS_ROOT, 0);
	CHECK(nvco_owns(&t, B_FILE, CA) && !nvco_owns(&t, A_FILE, CA), "a re-add for the same owner changes nothing");
	/* another file's client under a listed handle (the table and the RM disagree) is never handed over */
	{
		struct nvco_alloc64_params p64;

		memset(&p64, 0, sizeof(p64));
		p64.hRoot = p64.hObjectParent = p64.hObjectNew = CA;
		p64.hClass = NVCO_CLASS_ROOT;
		CHECK(nvco_after_ioctl(&t, A_FILE, NVCO_ESC_RM_ALLOC, sizeof(p64), &p64) == -1, "the collision is reported");
		CHECK(!nvco_owns(&t, A_FILE, CA) && !nvco_owns(&t, B_FILE, CA), "a collision leaves the handle unowned");
	}

}

static void
test_hold_lifecycle(void)
{
	struct nvco_free_params refused = { CB, CB, CB, 0x1B }, done = { CB, CB, CB, 0 };
	uint64_t tk;

	fresh();
	/* a release names the owner: another file's release changes nothing */
	CHECK(nvco_hold(&t, B_FILE, B_FP, CB), "B holds");
	CHECK(!nvco_unhold(&t, A_FP, CB) && nvco_busy(&t, CB), "A cannot release B's hold");
	CHECK(!nvco_unhold(&t, NULL, CB) && nvco_busy(&t, CB), "no file releases it either");
	CHECK(nvco_unhold(&t, B_FP, CB) && !nvco_busy(&t, CB), "B releases it");
	/* an eviction while held revokes, and the holder can still release; the entry then goes */
	CHECK(nvco_hold(&t, B_FILE, B_FP, CB), "B holds again");
	alloc64(NULL, CB, NVCO_CLASS_ROOT, 0);
	CHECK(nvco_busy(&t, CB) && !nvco_owns(&t, B_FILE, CB), "revoked: still held, no longer owned");
	CHECK(!nvco_hold(&t, B_FILE, B_FP, CB), "a revoked client cannot be held again");
	CHECK(nvco_unhold(&t, B_FP, CB), "the holder releases a revoked client");
	CHECK(nvco_find(&t, CB) == NULL, "the revoked entry goes with its last hold");
	/* a new client under a handle that is still held is refused, and the old one is revoked */
	CHECK(nvco_hold(&t, A_FILE, A_FP, CA), "A holds");
	CHECK(nvco_add(&t, CA, B_FILE) == -1 && !nvco_owns(&t, B_FILE, CA) && !nvco_owns(&t, A_FILE, CA),
	    "an add over a held handle fails closed");
	CHECK(nvco_unhold(&t, A_FP, CA) && nvco_find(&t, CA) == NULL, "A releases; the entry goes");
	/* a re-add for the same owner while holds are in flight revokes (the table and the RM disagree) */
	alloc64(A_FILE, CA, NVCO_CLASS_ROOT, 0);
	CHECK(nvco_hold(&t, A_FILE, A_FP, CA) && nvco_add(&t, CA, A_FILE) == -1 && !nvco_owns(&t, A_FILE, CA),
	    "a same-owner re-add under a hold revokes");
	CHECK(nvco_unhold(&t, A_FP, CA), "released");
	CHECK(nvco_alloc_handle(&(struct nvco_alloc64_params){ .hObjectNew = 0x1234 }) == 0x1234, "the new handle is read from the shared offset");
	/* a free in progress (by any file) refuses new holds so that the holds drain */
	fresh();
	CHECK(nvco_hold(&t, B_FILE, B_FP, CB), "B holds");
	tk = nvco_begin_free(&t, CB, &unl);
	CHECK(tk != 0, "a free of a listed client begins");
	CHECK(!nvco_hold(&t, B_FILE, B_FP, CB), "no new hold while a free waits");
	CHECK(nvco_busy(&t, CB), "the hold in flight still counts");
	CHECK(nvco_unhold(&t, B_FP, CB) && !nvco_busy(&t, CB), "it drains");
	nvco_end_free(&t, CB, tk, unl, 0);
	CHECK(nvco_hold(&t, B_FILE, B_FP, CB), "a free that did not happen lets holds in again");
	CHECK(nvco_unhold(&t, B_FP, CB), "released");
	tk = nvco_begin_free(&t, CB + 50, &unl);
	CHECK(tk != 0 && unl && nvco_find(&t, CB + 50) != NULL && nvco_find(&t, CB + 50)->tomb, "a free of an unlisted handle leaves a tombstone");
	nvco_end_free(&t, CB + 50, tk, unl, 0);
	CHECK(nvco_find(&t, CB + 50) == NULL, "a refused free of an unlisted handle leaves nothing");
	/* a refused free (params status): the kernel ends the count whatever the result */
	tk = nvco_begin_free(&t, CB, &unl);
	nvco_after_ioctl(&t, B_FILE, NVCO_ESC_RM_FREE, sizeof(refused), &refused);
	nvco_end_free(&t, CB, tk, unl, 0);
	CHECK(nvco_owns(&t, B_FILE, CB), "the RM refused the free: owned again");
	tk = nvco_begin_free(&t, CB, &unl);
	nvco_after_ioctl(&t, B_FILE, NVCO_ESC_RM_FREE, sizeof(done), &done);
	CHECK(nvco_find(&t, CB) == NULL, "the free happened: gone");
}

static void
test_free_counts_and_decoders(void)
{
	struct nvco_free_params done = { CB, CB, CB, 0 };
	struct nvco_free_params fc = { CB, CB, CB + 1, 0 };
	uint64_t tk, tk2;
	int ok;

	/* frees are counted: one interrupted free must not let holds in while another still waits */
	fresh();
	tk = nvco_begin_free(&t, CB, &unl);
	tk2 = nvco_begin_free(&t, CB, &unl);
	CHECK(tk != 0 && tk == tk2, "two frees wait on the same client");
	nvco_end_free(&t, CB, tk, unl, 0);
	CHECK(!nvco_hold(&t, B_FILE, B_FP, CB), "one free is still waiting: no new hold");
	nvco_end_free(&t, CB, tk2, unl, 0);
	CHECK(nvco_hold(&t, B_FILE, B_FP, CB), "both ended: holds are allowed again");
	CHECK(nvco_unhold(&t, B_FP, CB), "released");
	nvco_end_free(&t, CB, tk, unl, 0);
	CHECK(nvco_owns(&t, B_FILE, CB), "an unmatched end_free does not underflow the count");
	/* a stranger's free is counted too: the RM frees in the window after the lock drops */
	tk = nvco_begin_free(&t, CB, &unl);
	CHECK(tk != 0 && !nvco_hold(&t, B_FILE, B_FP, CB), "a free by any file keeps new holds out until it ends");
	nvco_end_free(&t, CB, tk, unl, 0);
	/* a hold must come from one open file */
	CHECK(nvco_hold(&t, B_FILE, B_FP, CB) && !nvco_hold(&t, B_FILE, A_FP, CB), "a second file cannot share the hold");
	CHECK(!nvco_unhold(&t, A_FP, CB) && nvco_unhold(&t, B_FP, CB), "only the file that held can release");
	/* a closing file revokes a held entry instead of leaving it attributed to a freed owner */
	CHECK(nvco_hold(&t, B_FILE, B_FP, CB), "B holds");
	nvco_remove_owner(&t, B_FILE);
	CHECK(!nvco_owns(&t, B_FILE, CB) && !nvco_hold(&t, B_FILE, B_FP, CB), "close revokes a held entry");
	CHECK(nvco_unhold(&t, B_FP, CB) && nvco_find(&t, CB) == NULL, "the holder can still release it, and it goes");
	/* a count is only given back to the client its token names: the handle was freed and reused meanwhile */
	fresh();
	tk = nvco_begin_free(&t, CA, &unl);
	free_obj(B_FILE, CA, CA, 0);
	alloc64(C_FILE, CA, NVCO_CLASS_ROOT, 0);
	tk2 = nvco_begin_free(&t, CA, &unl);
	CHECK(tk2 != 0 && tk2 != tk, "the reused handle is a different client (token %llu vs %llu)", (unsigned long long)tk2, (unsigned long long)tk);
	nvco_end_free(&t, CA, tk, unl, 0);
	CHECK(!nvco_hold(&t, C_FILE, C_FILE, CA), "the old free's end must not release the new client's free");
	/* the two free decoders agree */
	(void)nvco_client_free_handle(NVCO_ESC_RM_FREE, sizeof(done), &done, &ok);
	CHECK(ok == nvco_is_client_op(NVCO_ESC_RM_FREE, sizeof(done), &done), "decoders agree on a client free");
	(void)nvco_client_free_handle(NVCO_ESC_RM_FREE, sizeof(fc), &fc, &ok);
	CHECK(ok == nvco_is_client_op(NVCO_ESC_RM_FREE, sizeof(fc), &fc), "decoders agree on a child free");
	(void)nvco_client_free_handle(NVCO_ESC_RM_FREE, sizeof(fc) - 1, &fc, &ok);
	CHECK(ok == nvco_is_client_op(NVCO_ESC_RM_FREE, sizeof(fc) - 1, &fc), "decoders agree on an odd size");
}

static void
test_rm_lag(void)
{
	struct nvco_free_params done = { CB, CB, CB, 0 };
	struct nvco_alloc64_params a64;
	uint64_t tk;

	/* the table is updated after the RM call returned (nothing is locked across it): every lag fails closed */
	fresh();
	/* (a) a new client the RM created but the table has not recorded yet is unknown: refused */
	CHECK(!nvco_hold(&t, A_FILE, A_FP, CA + 0x300), "RM returned, not yet recorded: no hold");
	/* (b) the owner's free is in flight (counted): holds are refused until it ends */
	tk = nvco_begin_free(&t, CB, &unl);
	CHECK(tk != 0, "B's free begins");
	CHECK(!nvco_hold(&t, B_FILE, B_FP, CB), "RM free in flight: no new hold");
	/* (c) the RM freed CB and another file's alloc reused the handle before B's free was recorded */
	memset(&a64, 0, sizeof(a64));
	a64.hObjectNew = CB;
	a64.hClass = NVCO_CLASS_ROOT;
	CHECK(nvco_after_ioctl(&t, A_FILE, NVCO_ESC_RM_ALLOC, sizeof(a64), &a64) == -1, "the reuse collides with the unrecorded free");
	CHECK(!nvco_owns(&t, A_FILE, CB) && !nvco_owns(&t, B_FILE, CB), "both parties are unowned");
	nvco_after_ioctl(&t, B_FILE, NVCO_ESC_RM_FREE, sizeof(done), &done);
	nvco_end_free(&t, CB, tk, unl, 0);
	CHECK(!nvco_owns(&t, B_FILE, CB) && !nvco_owns(&t, A_FILE, CB), "the late record of the free changes nothing");
	/* (d) a reuse that is recorded cleanly after the free is recorded is owned by the new file */
	alloc64(A_FILE, CB, NVCO_CLASS_ROOT, 0);
	CHECK(nvco_owns(&t, A_FILE, CB) && !nvco_owns(&t, B_FILE, CB), "a clean reuse belongs to the new owner");
	/* (e) a hold taken before the RM free was recorded keeps the entry: the late free cannot drop it under the holder */
	fresh();
	CHECK(nvco_hold(&t, A_FILE, A_FP, CA), "A holds CA");
	nvco_after_ioctl(&t, A_FILE, NVCO_ESC_RM_FREE, sizeof((struct nvco_free_params){ CA, CA, CA, 0 }),
	    &(struct nvco_free_params){ CA, CA, CA, 0 });
	CHECK(nvco_busy(&t, CA) && !nvco_owns(&t, A_FILE, CA), "late free under a hold: revoked, still held");
	CHECK(nvco_unhold(&t, A_FP, CA) && nvco_find(&t, CA) == NULL, "the holder releases; the entry goes");
}

static void
test_late_record_stranger_gen(void)
{
	struct nvco_alloc64_params a64;
	struct nvco_free_params fr = { CA + 0x40, CA + 0x40, CA + 0x40, 0 };
	uint64_t tk, mark;
	size_t i;

	/* late record, case 1: the free of the unlisted handle is still IN FLIGHT when the allocation's record lands */
	fresh();
	mark = nvco_alloc_mark(&t);
	memset(&a64, 0, sizeof(a64));
	a64.hObjectNew = CA + 0x40;
	a64.hClass = NVCO_CLASS_ROOT;
	tk = nvco_begin_free(&t, CA + 0x40, &unl);
	CHECK(tk != 0 && unl && nvco_find(&t, CA + 0x40) != NULL && nvco_find(&t, CA + 0x40)->tomb, "a free of an unlisted handle leaves a tombstone");
	CHECK(!nvco_hold(&t, A_FILE, A_FP, CA + 0x40), "a tombstone cannot be held");
	CHECK(nvco_after_ioctl_marked(&t, A_FILE, NVCO_ESC_RM_ALLOC, sizeof(a64), &a64, mark) == -1, "a record that lands under a tombstone collides");
	CHECK(!nvco_owns(&t, A_FILE, CA + 0x40), "and owns nothing");
	/* the free then ENDS having freed a client: logged, and a later record of the same handle is refused */
	nvco_after_ioctl_marked(&t, A_FILE, NVCO_ESC_RM_FREE, sizeof(fr), &fr, mark);
	nvco_end_free(&t, CA + 0x40, tk, unl, 1);
	CHECK(nvco_find(&t, CA + 0x40) == NULL, "the tombstone goes with its free");
	CHECK(nvco_after_ioctl_marked(&t, A_FILE, NVCO_ESC_RM_ALLOC, sizeof(a64), &a64, mark) == -1 && !nvco_owns(&t, A_FILE, CA + 0x40),
	    "case 2: a record that lands AFTER such a free ended, for an allocation that took its mark before, is refused");
	/* a free that ended before the allocation's mark cannot have taken its client */
	tk = nvco_begin_free(&t, CA + 0x41, &unl);
	nvco_end_free(&t, CA + 0x41, tk, unl, 1);
	mark = nvco_alloc_mark(&t);
	a64.hObjectNew = CA + 0x41;
	CHECK(nvco_after_ioctl_marked(&t, A_FILE, NVCO_ESC_RM_ALLOC, sizeof(a64), &a64, mark) == 0 && nvco_owns(&t, A_FILE, CA + 0x41),
	    "a free that ended before the mark does not refuse the record");
	/* a free that began before the mark but ended after it is caught (it may have reached the RM after the allocation) */
	fresh();
	tk = nvco_begin_free(&t, CA + 0x44, &unl);
	mark = nvco_alloc_mark(&t);
	nvco_end_free(&t, CA + 0x44, tk, unl, 1);
	a64.hObjectNew = CA + 0x44;
	CHECK(nvco_after_ioctl_marked(&t, A_FILE, NVCO_ESC_RM_ALLOC, sizeof(a64), &a64, mark) == -1 && !nvco_owns(&t, A_FILE, CA + 0x44),
	    "a free that began before the mark and ended after it refuses the record");
	/* junk frees (the RM refuses them) cost nothing: any number of them leaves other records alone */
	fresh();
	mark = nvco_alloc_mark(&t);
	for (i = 0; i < 4 * NVCO_FREELOG; i++) {
		tk = nvco_begin_free(&t, 0x77000000u + (uint32_t)i, &unl);
		nvco_end_free(&t, 0x77000000u + (uint32_t)i, tk, unl, 0);
	}
	a64.hObjectNew = CA + 0x45;
	CHECK(nvco_after_ioctl_marked(&t, A_FILE, NVCO_ESC_RM_ALLOC, sizeof(a64), &a64, mark) == 0 && nvco_owns(&t, A_FILE, CA + 0x45),
	    "a flood of refused frees of junk handles does not make allocations unrecordable");
	CHECK(t.n == 3, "and leaves no entries behind (%zu)", t.n);
	/* the log of successful unlisted frees overflowing during an allocation fails closed */
	mark = nvco_alloc_mark(&t);
	for (i = 0; i < NVCO_FREELOG; i++) {
		tk = nvco_begin_free(&t, 0x78000000u + (uint32_t)i, &unl);
		nvco_end_free(&t, 0x78000000u + (uint32_t)i, tk, unl, 1);
	}
	a64.hObjectNew = CA + 0x46;
	CHECK(nvco_after_ioctl_marked(&t, A_FILE, NVCO_ESC_RM_ALLOC, sizeof(a64), &a64, mark) == -1 && !nvco_owns(&t, A_FILE, CA + 0x46),
	    "a log that overflowed with real frees during the allocation refuses the record");
	/* an ownerless record (a device file) under a tombstone: nothing is owned and the tombstone stays for its free */
	fresh();
	mark = nvco_alloc_mark(&t);
	tk = nvco_begin_free(&t, CA + 0x47, &unl);
	a64.hObjectNew = CA + 0x47;
	CHECK(nvco_after_ioctl_marked(&t, NULL, NVCO_ESC_RM_ALLOC, sizeof(a64), &a64, mark) == 0 && nvco_find(&t, CA + 0x47) != NULL
	    && nvco_find(&t, CA + 0x47)->tomb && !nvco_hold(&t, NULL, A_FP, CA + 0x47), "an ownerless record leaves the tombstone to its free and owns nothing");
	nvco_end_free(&t, CA + 0x47, tk, unl, 0);
	CHECK(nvco_find(&t, CA + 0x47) == NULL, "the tombstone goes");

	/* stranger: a free of a listed client by a file that does not own it is not permitted; the owner's is; an unlisted handle's is */
	fresh();
	CHECK(!nvco_free_permitted(&t, B_FILE, CA) && !nvco_free_permitted(&t, NULL, CA) && !nvco_free_permitted(&t, C_FILE, CA),
	    "a stranger (another control file, a device file, a third file) may not free A's client");
	CHECK(nvco_free_permitted(&t, A_FILE, CA), "the owner may free it");
	CHECK(nvco_free_permitted(&t, B_FILE, CA + 0x500) && nvco_free_permitted(&t, NULL, CA + 0x500), "an unlisted handle may be freed by anyone (the RM decides)");

	/* generation: 64 bits, never 0, even at the wrap */
	fresh();
	t.next_gen = UINT64_MAX - 1;
	alloc64(A_FILE, CA + 0x60, NVCO_CLASS_ROOT, 0);
	alloc64(A_FILE, CA + 0x61, NVCO_CLASS_ROOT, 0);
	alloc64(A_FILE, CA + 0x62, NVCO_CLASS_ROOT, 0);
	for (i = 0; i < t.n; i++)
		CHECK(t.e[i].gen != 0, "entry %zu has a nonzero generation", i);
	tk = nvco_begin_free(&t, CA + 0x61, &unl);
	CHECK(tk != 0, "a token is nonzero at the wrap");
	nvco_end_free(&t, CA + 0x61, tk, unl, 0);
	CHECK(nvco_hold(&t, A_FILE, A_FP, CA + 0x61), "the count came back: holds work after the free at the wrap");
	CHECK(nvco_unhold(&t, A_FP, CA + 0x61), "released");
}

static void
test_close_and_growth(void)
{
	fresh();
	/* closing a file forgets exactly its handles, all of them */
	alloc64(A_FILE, CA + 0x100, NVCO_CLASS_ROOT, 0);
	alloc64(A_FILE, CA + 0x101, NVCO_CLASS_ROOT, 0);
	nvco_remove_owner(&t, A_FILE);
	CHECK(!nvco_owns(&t, A_FILE, CA) && !nvco_owns(&t, A_FILE, CA + 0x100) && !nvco_owns(&t, A_FILE, CA + 0x101),
	    "close forgets all of the file's clients");
	CHECK(nvco_owns(&t, B_FILE, CB), "close leaves other files' clients");

	/* growth: many clients, all kept */
	{
		uint32_t i;

		for (i = 0; i < 1000; i++)
			alloc64(A_FILE, 0xD0000000u + i, NVCO_CLASS_ROOT, 0);
		for (i = 0; i < 1000; i++)
			CHECK(nvco_owns(&t, A_FILE, 0xD0000000u + i), "client %u kept after growth", i);
		nvco_remove_owner(&t, A_FILE);
		CHECK(t.n == 1, "only B's client is left (n = %zu)", t.n);
	}
}

int
main(void)
{
	test_recording();
	test_decoding_and_holds();
	test_hold_lifecycle();
	test_free_counts_and_decoders();
	test_rm_lag();
	test_late_record_stranger_gen();
	test_close_and_growth();
	nvco_destroy(&t);

	if (fails != 0)
		return (1);
	printf("client_owner_test: ok\n");
	return (0);
}

/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-3-Clause
 *
 * nv_client_owner.h - which open /dev/nvidiactl file an RM client was
 * allocated on (Track #2373).  The RM resolves a client handle with kernel
 * privilege and never asks who is calling, so a module that takes a handle
 * from a user (nvidia-uvm.ko does: nvUvmInterfaceDupAddressSpace,
 * nvUvmInterfaceDupMemory, nvUvmInterfaceRetainChannel) must ask this table
 * first.  Handles are predictable (the first client of a boot is
 * 0xC1D00000), so a handle is a name, not a secret.
 *
 * The table is one global list of (handle, owning file) pairs, filled from
 * the ioctls that create a client and emptied from the ones that free it:
 *   - NV_ESC_RM_ALLOC (0x2B, NVOS21 or NVOS64) and NV_ESC_RM_ALLOC_OBJECT
 *     (0x28, NVOS05) with hClass NV01_ROOT (0x0), NV01_ROOT_NON_PRIV
 *     (0x1) or NV01_ROOT_CLIENT (0x41) allocate a client; hObjectNew is its handle on success;
 *   - NV_ESC_RM_FREE (0x29, NVOS00) with hRoot == hObjectOld frees one;
 *   - closing the file forgets every handle it owns (RM frees them in
 *     rm_cleanup_file_private).
 * Only an nvidiactl file may own a client: the includer passes owner NULL
 * for any other file; a client allocated there owns nothing and evicts any
 * stale entry for its handle.
 * A handle freed through any file leaves the table, so a handle the RM reuses
 * cannot stay attributed to its first owner; an add for a handle that is
 * already listed for another file drops the entry and reports -1, so neither
 * file owns it (fail closed); a re-add for the same owner changes nothing
 * unless holds are in flight, then it revokes the entry. An ioctl that did not
 * succeed (the ioctl itself or the params status) changes nothing.
 *
 * The structures below repeat the layouts of nvos.h (open-gpu-kernel-
 * modules, MIT: NVOS00_PARAMETERS, NVOS05_PARAMETERS, NVOS21_PARAMETERS,
 * NVOS64_PARAMETERS) for the fields read here; tests/client_owner_test.sh
 * compiles them against the real header and compares every offset and size.
 *
 * The includer defines NVCO_MALLOC(bytes) and NVCO_FREE(ptr), and includes
 * the type definitions (uint32_t, size_t) first.  The kernel uses
 * malloc(9) with M_WAITOK, the test uses malloc.  The table is not
 * locked: the includer serialises calls (nvidia_subr.c holds an sx lock,
 * nvco_sx, because the add may sleep in malloc(M_WAITOK); a mutex would be
 * wrong).  The includer also holds that lock across the RM call of every
 * operation nvco_is_client_op names, so the table changes in RM's order.
 * A lookup is a linear scan: a process has a handful of clients.
 */

#ifndef NV_CLIENT_OWNER_H
#define NV_CLIENT_OWNER_H

#define	NVCO_ESC_RM_ALLOC_OBJECT	0x28
#define	NVCO_ESC_RM_FREE		0x29
#define	NVCO_ESC_RM_ALLOC		0x2B

#define	NVCO_CLASS_ROOT			0x0u	/* NV01_ROOT */
#define	NVCO_CLASS_ROOT_NON_PRIV	0x1u	/* NV01_ROOT_NON_PRIV */
#define	NVCO_CLASS_ROOT_CLIENT		0x41u	/* NV01_ROOT_CLIENT (nvos.h: the class new client code allocates) */

struct nvco_free_params {		/* NVOS00_PARAMETERS */
	uint32_t	hRoot;
	uint32_t	hObjectParent;
	uint32_t	hObjectOld;
	uint32_t	status;
};

struct nvco_alloc_object_params {	/* NVOS05_PARAMETERS */
	uint32_t	hRoot;
	uint32_t	hObjectParent;
	uint32_t	hObjectNew;
	uint32_t	hClass;
	uint32_t	status;
};

struct nvco_alloc_params {		/* NVOS21_PARAMETERS */
	uint32_t	hRoot;
	uint32_t	hObjectParent;
	uint32_t	hObjectNew;
	uint32_t	hClass;
	uint64_t	pAllocParms;
	uint32_t	paramsSize;
	uint32_t	status;
};

struct nvco_alloc64_params {		/* NVOS64_PARAMETERS */
	uint32_t	hRoot;
	uint32_t	hObjectParent;
	uint32_t	hObjectNew;
	uint32_t	hClass;
	uint64_t	pAllocParms;
	uint64_t	pRightsRequested;
	uint32_t	paramsSize;
	uint32_t	flags;
	uint32_t	status;
};

struct nvco_entry {
	uint32_t	handle;
	const void	*owner;
	uint32_t	refs;	/* holds in flight (nvco_hold); a free of the client waits for zero */
	uint32_t	freeing;	/* frees by the owner waiting for refs to reach zero (a count): no new holds */
	const void	*file;	/* the open file the holds in flight were taken on (struct file *), for the release */
	uint32_t	revoked;	/* ownership withdrawn while holds were in flight: kept only until they end */
};

struct nvco_table {
	struct nvco_entry	*e;
	size_t			n;
	size_t			cap;
};

static inline struct nvco_entry *
nvco_find(const struct nvco_table *t, uint32_t handle)
{
	size_t i;

	for (i = 0; i < t->n; i++) {
		if (t->e[i].handle == handle)
			return (&t->e[i]);
	}
	return (NULL);
}

static inline void
nvco_drop_entry(struct nvco_table *t, struct nvco_entry *e)
{
	*e = t->e[--t->n];
}

/*
 * Take the handle out of the table.  An entry with holds in flight stays,
 * revoked (nobody owns it any more), until the last hold ends: the holders
 * must still find their entry to release it.
 */
static inline void
nvco_remove_handle(struct nvco_table *t, uint32_t handle)
{
	struct nvco_entry *e = nvco_find(t, handle);

	if (e == NULL)
		return;
	if (e->refs != 0)
		e->revoked = 1;
	else
		nvco_drop_entry(t, e);
}

/*
 * 0, or -1 when the handle could not be recorded: no memory; the old entry
 * still has holds in flight (it is revoked); or the handle is listed for
 * another file (the entry is dropped).  A refused add leaves the handle
 * unowned: fail closed.  A re-add for the same owner changes nothing.
 */
static inline int
nvco_add(struct nvco_table *t, uint32_t handle, const void *owner)
{
	struct nvco_entry *grown, *old;
	size_t i, cap;

	old = nvco_find(t, handle);
	if (old != NULL) {
		if (old->refs != 0) {
			old->revoked = 1;
			return (-1);
		}
		if (old->owner != owner) {
			/*
			 * Another file's client under a handle that is already listed:
			 * the table and the RM disagree.  Never hand a client over; both
			 * parties end up unowned and refused (fail closed).
			 */
			nvco_drop_entry(t, old);
			return (-1);
		}
		return (0);
	}
	if (t->n == t->cap) {
		cap = t->cap == 0 ? 16 : t->cap * 2;
		grown = NVCO_MALLOC(cap * sizeof(*grown));
		if (grown == NULL)
			return (-1);
		for (i = 0; i < t->n; i++)
			grown[i] = t->e[i];
		if (t->e != NULL)
			NVCO_FREE(t->e);
		t->e = grown;
		t->cap = cap;
	}
	t->e[t->n].handle = handle;
	t->e[t->n].owner = owner;
	t->e[t->n].refs = 0;
	t->e[t->n].freeing = 0;
	t->e[t->n].file = NULL;
	t->e[t->n].revoked = 0;
	t->n++;
	return (0);
}

/*
 * forget every handle a closing file owns.  A held entry should not be here
 * (the hold keeps the file open); if one is, it is revoked, never left
 * attributed to a file that is going away.
 */
static inline void
nvco_remove_owner(struct nvco_table *t, const void *owner)
{
	size_t i = 0;

	while (i < t->n) {
		if (t->e[i].owner == owner && t->e[i].refs == 0) {
			nvco_drop_entry(t, &t->e[i]);
		} else {
			if (t->e[i].owner == owner)
				t->e[i].revoked = 1;
			i++;
		}
	}
}

/* does the entry grant `owner` the client: listed for it, not revoked, not being freed */
static inline int
nvco_grants(const struct nvco_entry *e, const void *owner)
{
	return (e != NULL && owner != NULL && e->owner == owner && !e->revoked && e->freeing == 0);
}

/* 1 only when the handle is listed and listed for this file (the same rule nvco_hold applies) */
static inline int
nvco_owns(const struct nvco_table *t, const void *owner, uint32_t handle)
{
	return (nvco_grants(nvco_find(t, handle), owner));
}

/*
 * A hold: 1 and a reference on the entry only when nvco_owns says so.  While
 * an entry has references the client is not freed (the includer's free path
 * waits, see nvco_busy and nvco_begin_free) and, because the holder also
 * keeps the file open, the file cannot close.  The reference is per client,
 * so a hold delays only a free of that one client.
 */
static inline int
nvco_hold(struct nvco_table *t, const void *owner, const void *file, uint32_t handle)
{
	struct nvco_entry *e = nvco_find(t, handle);

	if (!nvco_grants(e, owner) || file == NULL)
		return (0);
	if (e->refs != 0 && e->file != file)
		return (0);	/* one open file per owner: anything else is a caller bug */
	e->file = file;
	e->refs++;
	return (1);
}

/*
 * Drop a hold taken by nvco_hold on the same file.  1 on success; 0 when
 * there is no such hold (another file, no hold in flight): nothing changes.
 * The entry of a revoked client goes with its last hold.  The file is the
 * open file the hold took (not looked up again: it may be going away).
 */
static inline int
nvco_unhold(struct nvco_table *t, const void *file, uint32_t handle)
{
	struct nvco_entry *e = nvco_find(t, handle);

	if (e == NULL || file == NULL || e->file != file || e->refs == 0)
		return (0);
	e->refs--;
	if (e->refs == 0 && e->revoked)
		nvco_drop_entry(t, e);
	return (1);
}

/* 1 while a hold on the handle is in flight */
static inline int
nvco_busy(const struct nvco_table *t, uint32_t handle)
{
	const struct nvco_entry *e = nvco_find(t, handle);

	return (e != NULL && e->refs != 0);
}

/*
 * A free of the client is starting on `owner`'s file.  It waits for the holds
 * in flight; if the freeing file is the client's owner it also stops new
 * holds (a count: several frees may wait), so the holds drain.  A stranger's
 * free waits without blocking the owner (the owner must not be starved by
 * someone else's request).  Returns 1 when it was counted: pass the same to
 * nvco_end_free.  0 when the client is not listed or the file is not its owner.
 */
static inline int
nvco_begin_free(struct nvco_table *t, const void *owner, uint32_t handle)
{
	struct nvco_entry *e = nvco_find(t, handle);

	if (e == NULL || owner == NULL || e->owner != owner)
		return (0);
	e->freeing++;
	return (1);
}

/*
 * The free is over (done, interrupted or refused by the RM); counted is
 * nvco_begin_free's answer for the same owner.  The count is only given back
 * to an entry that still belongs to that owner: the handle may have been freed
 * and reused by another file while the free slept.
 */
static inline void
nvco_end_free(struct nvco_table *t, uint32_t handle, const void *owner, int counted)
{
	struct nvco_entry *e = nvco_find(t, handle);

	if (e != NULL && counted && e->owner == owner && e->freeing != 0)
		e->freeing--;
}

static inline void
nvco_destroy(struct nvco_table *t)
{
	if (t->e != NULL)
		NVCO_FREE(t->e);
	t->e = NULL;
	t->n = t->cap = 0;
}

/* the handle an allocation request names or returns (hObjectNew sits at the same offset in all three layouts) */
static inline uint32_t
nvco_alloc_handle(const void *args)
{
	return (((const struct nvco_alloc_object_params *)args)->hObjectNew);
}

static inline int
nvco_is_root_class(uint32_t hClass)
{
	return (hClass == NVCO_CLASS_ROOT || hClass == NVCO_CLASS_ROOT_NON_PRIV ||
	    hClass == NVCO_CLASS_ROOT_CLIENT);
}

/* the handle a client-freeing request frees, with ok = 1; a request that frees none sets ok = 0 */
static inline uint32_t
nvco_client_free_handle(unsigned nr, size_t size, const void *args, int *ok)
{
	const struct nvco_free_params *f = args;

	*ok = (nr == NVCO_ESC_RM_FREE && size == sizeof(*f) && f->hRoot == f->hObjectOld);
	return (*ok ? f->hObjectOld : 0);
}

/*
 * Decoded before rm_ioctl: does this request allocate a root client or free
 * a client (hRoot == hObjectOld)?  Only these operations change the table,
 * so only these are serialised with it.  Sizes that match no layout say no.
 */
static inline int
nvco_is_client_op(unsigned nr, size_t size, const void *args)
{
	int ok;

	switch (nr) {
	case NVCO_ESC_RM_ALLOC:
		if (size == sizeof(struct nvco_alloc_params))
			return (nvco_is_root_class(((const struct nvco_alloc_params *)args)->hClass));
		if (size == sizeof(struct nvco_alloc64_params))
			return (nvco_is_root_class(((const struct nvco_alloc64_params *)args)->hClass));
		return (0);
	case NVCO_ESC_RM_ALLOC_OBJECT:
		return (size == sizeof(struct nvco_alloc_object_params) &&
		    nvco_is_root_class(((const struct nvco_alloc_object_params *)args)->hClass));
	case NVCO_ESC_RM_FREE:
		(void)nvco_client_free_handle(nr, size, args, &ok);
		return (ok);
	default:
		return (0);
	}
}

/*
 * After rm_ioctl returned success on the file `owner` (arguments as the
 * ioctl left them, `size` the argument size): record a new client or drop a
 * freed one.  Any other request, a wrong size and a failed params status
 * are ignored.  Returns -1 only when a new client could not be recorded.
 */
static inline int
nvco_after_ioctl(struct nvco_table *t, const void *owner, unsigned nr, size_t size, const void *args)
{
	const struct nvco_alloc_params *a;
	const struct nvco_alloc64_params *a64;
	const struct nvco_alloc_object_params *ao;
	const struct nvco_free_params *f;
	uint32_t h;
	int ok;

	/* one decoder: what nvco_is_client_op says no to changes nothing here either */
	if (!nvco_is_client_op(nr, size, args))
		return (0);
	switch (nr) {
	case NVCO_ESC_RM_ALLOC:
		if (size == sizeof(*a)) {
			a = args;
			ok = a->status == 0;
			h = a->hObjectNew;
		} else {
			a64 = args;
			ok = a64->status == 0;
			h = a64->hObjectNew;
		}
		break;
	case NVCO_ESC_RM_ALLOC_OBJECT:
		ao = args;
		ok = ao->status == 0;
		h = ao->hObjectNew;
		break;
	default:	/* NVCO_ESC_RM_FREE */
		f = args;
		if (f->status == 0)
			nvco_remove_handle(t, f->hObjectOld);
		return (0);
	}
	if (!ok)
		return (0);
	/*
	 * A new client.  A file that cannot own one (not an nvidiactl file)
	 * still evicts a stale entry for the handle: the RM has reused it.
	 */
	if (owner == NULL) {
		nvco_remove_handle(t, h);
		return (0);
	}
	return (nvco_add(t, h, owner));
}

#endif /* NV_CLIENT_OWNER_H */

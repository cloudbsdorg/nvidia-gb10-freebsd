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
 * The table is one global list of (handle, owning file) pairs, filled (after
 * the RM call returned) from
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
 * locked: the includer serialises calls with a LEAF lock (nvidia_subr.c: an
 * sx lock, nvco_sx, because the add may sleep in malloc(M_WAITOK); a mutex
 * would be wrong).  The lock is never held across the RM call: RM can run the
 * file's close destructor, which takes it, from inside an RM call.  So the
 * table is updated AFTER the RM call returns and may lag the RM by that
 * window; every lag fails closed: a new client not yet recorded is unknown
 * and refused; a freed handle that the RM reuses before the free is recorded
 * collides in nvco_add (both parties unowned); the owner's free count keeps
 * new holds out while the free is in flight.
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
	uint32_t	freeing;	/* frees of the client in flight (a count; any file's): no new holds */
	uint64_t	gen;	/* which client this entry is (never 0): a reused handle gets a new one */
	uint32_t	tomb;	/* not a client: a free of an unlisted handle is in flight (see nvco_begin_free) */
	const void	*file;	/* the open file the holds in flight were taken on (struct file *), for the release */
	uint32_t	revoked;	/* ownership withdrawn while holds were in flight: kept only until they end */
};

#define	NVCO_FREELOG	64

struct nvco_free_record {		/* a free of an UNLISTED handle that the RM did free */
	uint32_t	handle;
	uint64_t	seq;
};

struct nvco_table {
	struct nvco_entry	*e;
	size_t			n;
	size_t			cap;
	uint64_t		next_gen;
	uint64_t		seq;	/* successful frees of unlisted handles so far */
	struct nvco_free_record	frees[NVCO_FREELOG];	/* the last NVCO_FREELOG of them */
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

	if (e == NULL || e->tomb)
		return;		/* a tombstone is not a client: its free removes it */
	if (e->refs != 0)
		e->revoked = 1;
	else
		nvco_drop_entry(t, e);
}

/* a fresh generation: never 0 (0 means "not listed" in a token), 64 bits so that it does not wrap */
static inline uint64_t
nvco_new_gen(struct nvco_table *t)
{
	if (++t->next_gen == 0)
		++t->next_gen;
	return (t->next_gen);
}

/* a new entry for the handle (NULL when memory ran out); the caller sets what is not zero */
static inline struct nvco_entry *
nvco_new_entry(struct nvco_table *t, uint32_t handle, const void *owner)
{
	struct nvco_entry *grown, *e;
	size_t i, cap;

	if (t->n == t->cap) {
		cap = t->cap == 0 ? 16 : t->cap * 2;
		grown = NVCO_MALLOC(cap * sizeof(*grown));
		if (grown == NULL)
			return (NULL);
		for (i = 0; i < t->n; i++)
			grown[i] = t->e[i];
		if (t->e != NULL)
			NVCO_FREE(t->e);
		t->e = grown;
		t->cap = cap;
	}
	e = &t->e[t->n++];
	e->handle = handle;
	e->owner = owner;
	e->refs = 0;
	e->freeing = 0;
	e->gen = nvco_new_gen(t);
	e->tomb = 0;
	e->file = NULL;
	e->revoked = 0;
	return (e);
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
	struct nvco_entry *old;

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
	if (nvco_new_entry(t, handle, owner) == NULL)
		return (-1);
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
		return (0);	/* tripwire: one nvffp is one open file, so this cannot happen */
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
 * May this file free this handle?  A listed client can be
 * freed only by the file that owns it: another file gets EPERM from the
 * includer before the RM is called, so a stranger cannot raise the free count
 * of a predictable handle or reach the RM in the lag window.  The refusal does
 * not depend on whether the RM would refuse.  An unlisted handle (a client the
 * table has not recorded yet, or none) may be freed by anyone: the RM decides,
 * and the free is logged (nvco_begin_free) so that a record that lands late is refused.
 */
static inline int
nvco_free_permitted(const struct nvco_table *t, const void *who, uint32_t handle)
{
	const struct nvco_entry *e = nvco_find(t, handle);

	return (e == NULL || e->owner == who);
}

/*
 * A free of a handle is starting, by whichever file.  A listed client gets a
 * count: the holds in flight drain and no new one is granted until the free
 * ends, because the RM will free the client in the window after the includer
 * drops the table lock.  A handle that is NOT listed gets a TOMBSTONE (owner
 * NULL, never held or owned): the client of that handle may exist in the RM and
 * not be recorded yet, and an allocation record that lands while the tombstone
 * stands is a collision (neither party owned).  A tombstone lives only as long
 * as its free, so junk frees cost nothing once the RM refuses them.  Returns a
 * token (nonzero) naming the entry (0 only when memory ran out), and sets
 * *unlisted; pass both to nvco_end_free.
 */
static inline uint64_t
nvco_begin_free(struct nvco_table *t, uint32_t handle, int *unlisted)
{
	struct nvco_entry *e = nvco_find(t, handle);

	*unlisted = (e == NULL);
	if (e == NULL) {
		e = nvco_new_entry(t, handle, NULL);
		if (e == NULL)
			return (0);
		e->tomb = 1;
	}
	e->freeing++;
	return (e->gen);
}

/*
 * The free is over.  rm_freed: the RM really freed a client (the ioctl and the
 * params status both succeeded).  A free of an unlisted handle that freed a
 * client is logged with a sequence number: an allocation that took its mark
 * before that, and records the same handle, is refused (nvco_alloc_stale).  The
 * count is given back only to the entry the token names, and a tombstone goes
 * with its last free.
 */
static inline void
nvco_end_free(struct nvco_table *t, uint32_t handle, uint64_t token, int unlisted, int rm_freed)
{
	struct nvco_entry *e = nvco_find(t, handle);
	uint64_t seq;

	if (unlisted && rm_freed) {
		seq = ++t->seq;
		t->frees[seq % NVCO_FREELOG].handle = handle;
		t->frees[seq % NVCO_FREELOG].seq = seq;
	}
	if (e == NULL || token == 0 || e->gen != token || e->freeing == 0)
		return;
	e->freeing--;
	if (e->tomb && e->freeing == 0 && e->refs == 0)
		nvco_drop_entry(t, e);
}

/* the mark an allocation takes before its RM call */
static inline uint64_t
nvco_alloc_mark(const struct nvco_table *t)
{
	return (t->seq);
}

/*
 * 1 when a free of an unlisted handle that freed a client ended after the
 * allocation took its mark and named this handle (the free may have taken the
 * very client being recorded), or when so many such frees ended that the log
 * can no longer say (fail closed).  A free that ended before the mark cannot
 * have taken a client created after it, and one still in flight is a tombstone.
 */
static inline int
nvco_alloc_stale(const struct nvco_table *t, uint32_t handle, uint64_t mark)
{
	size_t i;

	if (t->seq - mark >= NVCO_FREELOG)
		return (1);
	for (i = 0; i < NVCO_FREELOG; i++) {
		if (t->frees[i].seq > mark && t->frees[i].handle == handle)
			return (1);
	}
	return (0);
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

/* did the RM free a client: the ioctl and the params status both succeeded */
static inline int
nvco_free_succeeded(unsigned nr, size_t size, const void *args, int status)
{
	int ok;

	(void)nvco_client_free_handle(nr, size, args, &ok);
	return (ok && status == 0 && ((const struct nvco_free_params *)args)->status == 0);
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
nvco_after_ioctl_marked(struct nvco_table *t, const void *owner, unsigned nr, size_t size, const void *args,
    uint64_t mark)
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
	if (nvco_alloc_stale(t, h, mark)) {
		/* a free of this handle began while the allocation was in flight: unowned, fail closed */
		nvco_remove_handle(t, h);
		return (-1);
	}
	return (nvco_add(t, h, owner));
}

#endif /* NV_CLIENT_OWNER_H */

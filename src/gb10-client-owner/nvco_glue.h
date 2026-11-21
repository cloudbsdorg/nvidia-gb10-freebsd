/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-3-Clause
 *
 * nvco_glue.h - the kernel glue of the RM client ownership table (Track
 * #2373), included by the patched nvidia_subr.c before nvidia_handle_ioctl.
 * tests/client_owner_glue_test.sh compiles this very file in userland against
 * fakes of the kernel and runs it.
 *
 * Which /dev/nvidiactl file owns each RM client.
 */
/*
 * The RM resolves a client handle with kernel privilege and never asks who is
 * calling, so nvidia-uvm.ko must ask here first (nv_client_owner.h has the
 * table and its rules).  Locking: nvco_sx is a LEAF lock.  It is taken only
 * around table operations and around the interruptible "nvcobusy" sleep that
 * drops it; it is never held across rm_ioctl, never taken while sleeping on
 * anything else, and nothing is waited for under it.  fops_sx is not held
 * across the sleep either (the wait runs before the ioctl takes it).  So the
 * RM, which can run the file's close destructor from inside an RM call, can
 * always take nvco_sx.
 */
#define NVCO_MALLOC(n)  malloc((n), M_NVIDIA, M_WAITOK)
#define NVCO_FREE(p)    free((p), M_NVIDIA)
#include "nv_client_owner.h"

static struct sx nvco_sx;
static struct nvco_table nvco_table;
static struct timeval nvco_rec_lasttime, nvco_rel_lasttime;	/* one rate limiter per diagnostic */
static int nvco_rec_curpps, nvco_rel_curpps;
SX_SYSINIT(nvco_sx, &nvco_sx, "nvco_sx");

static void
nvco_unload(void *arg __unused)
{
    sx_xlock(&nvco_sx);
    nvco_destroy(&nvco_table);
    sx_xunlock(&nvco_sx);
}
SYSUNINIT(nvco_unload, SI_SUB_DRIVERS, SI_ORDER_ANY, nvco_unload, NULL);

/*
 * nvco_file_owner - the table's name for an open file: the file's private
 * data when fp is a /dev/nvidiactl file of this module, else NULL.  The file
 * must be a character device node of devfs: only then does f_cdevpriv exist
 * (on a regular file the same union member is the fadvise state).  The
 * destructor is the identity: only nvidia_ctl_open sets nvidia_ctl_dtor.
 */
static const void *
nvco_file_owner(struct file *fp)
{
    struct cdev_privdata *p;
    struct vnode *vp;

    if (fp == NULL || fp->f_type != DTYPE_VNODE)
        return NULL;
    vp = fp->f_vnode;
    if (vp == NULL || vp->v_type != VCHR)
        return NULL;
    p = fp->f_cdevpriv;
    if (p == NULL || p->cdpd_dtr != nvidia_ctl_dtor)
        return NULL;
    return p->cdpd_data;
}

/*
 * nvUvmInterfaceClientHold - NV_OK only when fp is an open /dev/nvidiactl
 * file of this module and hClient is an RM client allocated on that very
 * file; NV_ERR_INSUFFICIENT_PERMISSIONS otherwise (nothing taken).  On
 * NV_OK the client is held: a free of it waits and the file cannot close
 * (the hold keeps its own reference on fp) until
 * nvUvmInterfaceClientRelease(fp, hClient) with the same fp and handle,
 * which the caller calls exactly once per NV_OK and never after a refusal.
 * Holds nest per client.  A hold delays only a free of that client.
 * Context: sleepable, no RM lock held, never from an RM callback (a hold
 * from a thread that holds the table lock is refused; a release from one
 * is a bug and asserts on a debug kernel).  The caller holds a reference
 * on fp of its own across this call.
 */
NV_STATUS nvUvmInterfaceClientHold(struct file *fp, NvHandle hClient);
void nvUvmInterfaceClientRelease(struct file *fp, NvHandle hClient);

NV_STATUS
nvUvmInterfaceClientHold(struct file *fp, NvHandle hClient)
{
    const void *owner = nvco_file_owner(fp);
    int held;

    if (owner == NULL || sx_xlocked(&nvco_sx))
        return NV_ERR_INSUFFICIENT_PERMISSIONS;
    sx_xlock(&nvco_sx);
    held = nvco_hold(&nvco_table, owner, fp, hClient);
    sx_xunlock(&nvco_sx);
    if (!held)
        return NV_ERR_INSUFFICIENT_PERMISSIONS;
    /* the hold's own reference: the file cannot close under it */
    if (!fhold(fp)) {
        sx_xlock(&nvco_sx);
        (void)nvco_unhold(&nvco_table, fp, hClient);
        sx_xunlock(&nvco_sx);
        wakeup(&nvco_table);
        return NV_ERR_INSUFFICIENT_PERMISSIONS;
    }
    return NV_OK;
}

void
nvUvmInterfaceClientRelease(struct file *fp, NvHandle hClient)
{
    int was_held;

    /* same context rule as the hold: not from an RM callback, not under the table lock */
    KASSERT(!sx_xlocked(&nvco_sx), ("nvidia: client release under the table lock"));
    sx_xlock(&nvco_sx);
    was_held = nvco_unhold(&nvco_table, fp, hClient);   /* matched on the file the hold took */
    sx_xunlock(&nvco_sx);
    wakeup(&nvco_table);
    KASSERT(was_held, ("nvidia: client release without a matching hold"));
    if (was_held)
        fdrop(fp, curthread);    /* last: its close needs the table */
    else if (ppsratecheck(&nvco_rel_lasttime, &nvco_rel_curpps, 1))
        printf("NVRM: nvUvmInterfaceClientRelease: no hold on client 0x%x for this file (nvidia-uvm bug)\n",
            (unsigned)hClient);
}

struct nvco_ioctl_ctx {
    int client_op;      /* a root-client allocation or free */
    int free_ok;        /* ... a free */
    NvHandle free_h;
    uint32_t counted;   /* token of this free's count on the client (0: not listed) */
};

/*
 * nvco_ioctl_begin - before the ioctl takes fops_sx and calls the RM.  A free
 * of a client waits (interruptibly) until no hold on it is in flight; the
 * sleep drops nvco_sx and no other lock is held.  Returns 0, or the sleep's
 * error (EINTR, ERESTART): nothing was freed and nothing is held.
 */
static int
nvco_ioctl_begin(struct nvco_ioctl_ctx *c, unsigned nr, size_t size, const void *args)
{
    int wait_error = 0;

    c->client_op = nvco_is_client_op(nr, size, args);
    c->counted = 0;
    c->free_h = nvco_client_free_handle(nr, size, args, &c->free_ok);
    if (!c->free_ok)
        return 0;
    sx_xlock(&nvco_sx);
    c->counted = nvco_begin_free(&nvco_table, c->free_h);
    while (wait_error == 0 && nvco_busy(&nvco_table, c->free_h))
        wait_error = sx_sleep(&nvco_table, &nvco_sx, PCATCH, "nvcobusy", 0);
    if (wait_error != 0)
        nvco_end_free(&nvco_table, c->free_h, c->counted);
    sx_xunlock(&nvco_sx);
    return wait_error;
}

/*
 * nvco_ioctl_end - after the RM call returned, still under the file's fops_sx
 * (so one file's records follow its RM order; the lock order is fops_sx then
 * nvco_sx, and nvco_sx is a leaf).  No table lock was held across the RM call,
 * so the table may lag the RM by this window: an unrecorded new client is
 * unowned and refused, a handle the RM reuses before this runs collides in
 * nvco_add and leaves both parties unowned, and the free's count keeps new
 * holds out meanwhile; all fail closed.
 */
static void
nvco_ioctl_end(struct nvco_ioctl_ctx *c, const void *who, int status, unsigned nr, size_t size,
    const void *args)
{
    int recorded = 0;

    if (!c->client_op && !c->free_ok)
        return;
    sx_xlock(&nvco_sx);
    if (status == 0)
        recorded = nvco_after_ioctl(&nvco_table, who, nr, size, args);
    if (c->free_ok)
        nvco_end_free(&nvco_table, c->free_h, c->counted);
    if (recorded != 0 && ppsratecheck(&nvco_rec_lasttime, &nvco_rec_curpps, 1))
        printf("NVRM: RM client 0x%x could not be recorded for nvidia-uvm (its handle is "
            "already listed for another file, or memory ran out): nvidia-uvm will refuse "
            "its requests until the client is freed and allocated again\n",
            (unsigned)nvco_alloc_handle(args));
    sx_xunlock(&nvco_sx);
}

/* the file is closing: forget its clients (a held entry is revoked, never left attributed) */
static void
nvco_forget_owner(const void *nvffp)
{
    sx_xlock(&nvco_sx);
    nvco_remove_owner(&nvco_table, nvffp);
    sx_xunlock(&nvco_sx);
}


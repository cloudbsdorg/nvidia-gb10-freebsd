/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-3-Clause
 *
 * nvidia_glue_harness.c - runs the REAL glue of patches/patch-zz-nvidia_client_owner_subr.c
 * (src/gb10-client-owner/nvco_glue.h, or a mutant of it) in userland against fakes
 * of the kernel: sx locks that refuse recursion and know who holds them, a
 * file with a reference count, sx_sleep that runs a scripted "other thread",
 * KASSERT that counts.  The ioctl hook is driven the way nvidia_handle_ioctl
 * drives it (begin, the RM call, end), with a fake RM that asserts the table
 * lock is not held.  Exit 0 only when every scenario holds.
 */
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <sys/time.h>

typedef uint32_t NvHandle;
typedef uint32_t NV_STATUS;
#define	NV_OK				0
#define	NV_ERR_INSUFFICIENT_PERMISSIONS	0x1B
#define	PCATCH				0x100
#define	M_NVIDIA			0
#define	M_WAITOK			0
#define	DTYPE_VNODE			1
#define	DTYPE_SOCKET			2
#define	VCHR				2
#define	VREG				1
#define	SI_SUB_DRIVERS			0
#define	SI_ORDER_ANY			0
#define	curthread			((void *)0)

static void *fake_malloc(size_t n) { return (calloc(1, n)); }
static void fake_free(void *p) { free(p); }
#define	malloc(n, t, f)	fake_malloc(n)
#define	free(p, t)	fake_free(p)

struct sx { int x; };
static int sx_trouble;			/* recursion, unlock of an unlocked lock */
static void sx_xlock(struct sx *s) { if (s->x) { printf("FAIL sx recursion on %p\n", (void *)s); sx_trouble++; } s->x = 1; }
static void sx_xunlock(struct sx *s) { if (!s->x) { printf("FAIL sx unlock of an unlocked lock\n"); sx_trouble++; } s->x = 0; }
static int sx_xlocked(struct sx *s) { return (s->x); }
#define	SX_SYSINIT(a, b, c)
#define	SYSUNINIT(a, b, c, d, e)

static int sleeps, runaway;
static int (*sleep_hook)(int n);	/* the scripted other thread: returns the sleep's result */
static int sx_sleep(void *chan, struct sx *s, int pri, const char *wmesg, int timo)
{
	int r;

	(void)chan; (void)pri; (void)wmesg; (void)timo;
	sx_xunlock(s);
	sleeps++;
	if (sleeps > 50 || sleep_hook == NULL) {
		/* nobody will ever end the hold: a wait that never ends is a failure, not a hang */
		sx_xlock(s);
		runaway++;
		return (EINTR);
	}
	r = sleep_hook(sleeps);
	sx_xlock(s);
	return (r);
}
static int wakeups;
static void wakeup(void *chan) { (void)chan; wakeups++; }
static int kassert_fail;
#define	KASSERT(c, m)	do { if (!(c)) kassert_fail++; } while (0)
static int pps_allow = 1, pps_asked;
static int ppsratecheck(struct timeval *t, int *c, int m) { (void)t; (void)c; (void)m; pps_asked++; return (pps_allow); }

struct vnode { int v_type; };
struct cdev_privdata { void *cdpd_data; void (*cdpd_dtr)(void *); };
struct file {
	int f_type;
	struct vnode *f_vnode;
	struct cdev_privdata *f_cdevpriv;
	int refs;
	int closed;
};
static void nvidia_ctl_dtor(void *arg);
static void nvidia_dev_dtor(void *arg) { (void)arg; }
static int fhold_fails;
static int fhold(struct file *fp) { if (fhold_fails) return (0); fp->refs++; return (1); }
static void nvco_forget_owner(const void *nvffp);
static void fdrop(struct file *fp, void *td)
{
	(void)td;
	if (--fp->refs == 0) {
		fp->closed = 1;
		nvidia_ctl_dtor(fp->f_cdevpriv->cdpd_data);	/* the cdevpriv destructor runs at the last reference */
	}
}
/* nvidia_ctl_dtor of the OS layer: nvidia_close_ctl forgets the file's clients */
static void nvidia_ctl_dtor(void *arg) { nvco_forget_owner(arg); }

#include "nvco_glue.h"

static int fails;
#define	CHECK(c, ...) do { if (!(c)) { fails++; printf("FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

static struct vnode vn_chr = { VCHR }, vn_reg = { VREG };
static struct cdev_privdata pd_a, pd_b, pd_dev, pd_alias;
static int ffA = 1, ffB = 2;	/* stand-ins for the nv_freebsd_file_private pointers */
static struct file fa, fb, fdev, freg, fsock;

static void
setup_files(void)
{
	nvco_destroy(&nvco_table);	/* every scenario starts with an empty table */
	pd_a = (struct cdev_privdata){ &ffA, nvidia_ctl_dtor };
	pd_b = (struct cdev_privdata){ &ffB, nvidia_ctl_dtor };
	pd_dev = (struct cdev_privdata){ &ffA, nvidia_dev_dtor };	/* private data that equals an owner's: only the destructor tells it apart */
	pd_alias = (struct cdev_privdata){ &ffA, nvidia_ctl_dtor };	/* what a fadvise union could look like */
	fa = (struct file){ DTYPE_VNODE, &vn_chr, &pd_a, 1, 0 };
	fb = (struct file){ DTYPE_VNODE, &vn_chr, &pd_b, 1, 0 };
	fdev = (struct file){ DTYPE_VNODE, &vn_chr, &pd_dev, 1, 0 };
	freg = (struct file){ DTYPE_VNODE, &vn_reg, &pd_alias, 1, 0 };	/* regular file whose union member looks like cdevpriv */
	fsock = (struct file){ DTYPE_SOCKET, &vn_chr, &pd_alias, 1, 0 };
}

/*
 * the ioctl hook as nvidia_handle_ioctl runs it: begin (no lock), the RM call (the fake asserts the table
 * lock is free and runs rm_step_hook, the "other thread" that acts while the RM works), end.  The layouts
 * and numbers are the header's, not a second copy.
 */
static int rm_calls, rm_saw_lock, rm_freed_while_busy;
static void (*rm_step_hook)(void);

static int
rm_ioctl_alloc(const void *who, uint32_t h, uint32_t cls, int rm_status, uint32_t params_status)
{
	struct nvco_alloc64_params a;
	struct nvco_ioctl_ctx c;
	int e;

	memset(&a, 0, sizeof(a));
	a.hObjectNew = h;
	a.hClass = cls;
	e = nvco_ioctl_begin(&c, who, NVCO_ESC_RM_ALLOC, sizeof(a), &a);
	if (e != 0)
		return (e);
	rm_calls++;
	if (nvco_sx.x)
		rm_saw_lock++;
	if (rm_step_hook != NULL)
		rm_step_hook();
	a.status = params_status;
	nvco_ioctl_end(&c, who, rm_status, NVCO_ESC_RM_ALLOC, sizeof(a), &a);
	return (rm_status);
}

static int
rm_ioctl_free(const void *who, uint32_t h, int rm_status, uint32_t params_status)
{
	struct nvco_free_params f = { h, h, h, 0 };
	struct nvco_ioctl_ctx c;
	int e;

	e = nvco_ioctl_begin(&c, who, NVCO_ESC_RM_FREE, sizeof(f), &f);
	if (e != 0)
		return (e);
	rm_calls++;
	if (nvco_sx.x)
		rm_saw_lock++;
	if (nvco_busy(&nvco_table, h))
		rm_freed_while_busy++;
	if (rm_step_hook != NULL)
		rm_step_hook();
	f.status = params_status;
	nvco_ioctl_end(&c, who, rm_status, NVCO_ESC_RM_FREE, sizeof(f), &f);
	return (rm_status);
}

#define	H1	0xC1D00000u
#define	H2	0xC1D00001u

static int hold_other_thread_count;
static int sleep_release_one(int n)
{
	(void)n;
	/* the other thread ends one of two holds per wakeup; while the owner's free waits, a new hold must be refused */
	if (nvUvmInterfaceClientHold(&fa, H1) == NV_OK) {
		hold_other_thread_count++;
		nvUvmInterfaceClientRelease(&fa, H1);
	}
	nvUvmInterfaceClientRelease(&fa, H1);
	return (0);
}
static int sleep_eintr(int n) { (void)n; return (EINTR); }

static void
scenario_hold_release(void)
{
	NV_STATUS st;

	setup_files();
	rm_ioctl_alloc(&ffA, H1, NVCO_CLASS_ROOT_CLIENT, 0, 0);
	rm_ioctl_alloc(&ffB, H2, 0, 0, 0);
	CHECK(nvUvmInterfaceClientHold(&fa, H1) == NV_OK, "the owner holds its client");
	CHECK(fa.refs == 2, "the hold keeps a file reference (refs %d)", fa.refs);
	nvUvmInterfaceClientRelease(&fa, H1);
	CHECK(fa.refs == 1 && !fa.closed && kassert_fail == 0, "release drops exactly the hold's reference (refs %d)", fa.refs);
	CHECK(nvUvmInterfaceClientHold(&fb, H1) == NV_ERR_INSUFFICIENT_PERMISSIONS, "another nvidiactl file is refused");
	CHECK(nvUvmInterfaceClientHold(&fa, H2) == NV_ERR_INSUFFICIENT_PERMISSIONS, "a handle of another file is refused");
	CHECK(nvUvmInterfaceClientHold(&fdev, H1) == NV_ERR_INSUFFICIENT_PERMISSIONS, "a device file (other destructor) is refused");
	CHECK(nvUvmInterfaceClientHold(&freg, H1) == NV_ERR_INSUFFICIENT_PERMISSIONS, "a regular file that aliases cdevpriv is refused");
	CHECK(nvUvmInterfaceClientHold(&fsock, H1) == NV_ERR_INSUFFICIENT_PERMISSIONS, "a non-vnode file that aliases cdevpriv is refused");
	CHECK(nvUvmInterfaceClientHold(NULL, H1) == NV_ERR_INSUFFICIENT_PERMISSIONS, "no file is refused");
	CHECK(nvUvmInterfaceClientHold(&fa, 0) == NV_ERR_INSUFFICIENT_PERMISSIONS, "handle 0 is refused");
	CHECK(fa.refs == 1 && fb.refs == 1, "refusals take no reference");
	fhold_fails = 1;
	st = nvUvmInterfaceClientHold(&fa, H1);
	fhold_fails = 0;
	CHECK(st == NV_ERR_INSUFFICIENT_PERMISSIONS && !nvco_busy(&nvco_table, H1), "a failed fhold refuses and leaves no hold");
	/* an unmatched or wrong-file release changes nothing */
	nvUvmInterfaceClientRelease(&fa, H1);
	CHECK(fa.refs == 1 && kassert_fail == 1, "a release without a hold is flagged and drops no reference");
	kassert_fail = 0;
	CHECK(nvUvmInterfaceClientHold(&fa, H1) == NV_OK, "hold again");
	nvUvmInterfaceClientRelease(&fb, H1);
	CHECK(fa.refs == 2 && kassert_fail == 1 && nvco_busy(&nvco_table, H1), "a release from another file leaves the hold");
	kassert_fail = 0;
	nvUvmInterfaceClientRelease(&fa, H1);
	CHECK(fa.refs == 1 && !nvco_busy(&nvco_table, H1), "the right release ends it");
	CHECK(sx_trouble == 0 && nvco_sx.x == 0, "no lock trouble, no lock left (trouble %d)", sx_trouble);
}

static void
scenario_recording(void)
{
	setup_files();
	rm_ioctl_alloc(&ffA, H1, NVCO_CLASS_ROOT_CLIENT, 0, 0);
	CHECK(rm_saw_lock == 0, "the RM was called with no table lock held");
	rm_ioctl_alloc(&ffA, H2, 0, 22, 0);		/* ioctl itself failed */
	CHECK(nvUvmInterfaceClientHold(&fa, H2) != NV_OK, "a failed ioctl records nothing");
	rm_ioctl_alloc(&ffA, H2 + 1, 0, 0, 0x1B);	/* params status says refused */
	CHECK(nvUvmInterfaceClientHold(&fa, H2 + 1) != NV_OK, "a refused allocation records nothing");
	rm_ioctl_alloc(NULL, H2 + 2, NVCO_CLASS_ROOT_CLIENT, 0, 0);	/* allocated on a device file: owner NULL */
	CHECK(nvUvmInterfaceClientHold(&fdev, H2 + 2) != NV_OK && nvUvmInterfaceClientHold(&fa, H2 + 2) != NV_OK,
	    "a client allocated on a device file is owned by nobody");
	rm_ioctl_alloc(&ffA, H2 + 3, 0x80, 0, 0);	/* not a root class */
	CHECK(nvUvmInterfaceClientHold(&fa, H2 + 3) != NV_OK, "a non-root class is not a client");
}

static void
scenario_free_waits(void)
{
	setup_files();
	rm_calls = rm_freed_while_busy = 0; sleeps = 0;
	rm_ioctl_alloc(&ffA, H1, NVCO_CLASS_ROOT_CLIENT, 0, 0);
	CHECK(nvUvmInterfaceClientHold(&fa, H1) == NV_OK && nvUvmInterfaceClientHold(&fa, H1) == NV_OK, "two holds");
	sleep_hook = sleep_release_one;
	hold_other_thread_count = 0;
	CHECK(rm_ioctl_free(&ffA, H1, 0, 0) == 0, "the owner's free completes");
	sleep_hook = NULL;
	CHECK(sleeps == 2, "the free slept until BOTH holds ended (sleeps %d)", sleeps);
	CHECK(rm_freed_while_busy == 0, "the RM was not called while a hold was in flight");
	CHECK(hold_other_thread_count == 0, "no new hold was granted while the owner's free waited");
	CHECK(nvUvmInterfaceClientHold(&fa, H1) != NV_OK, "the freed client is gone");
	CHECK(fa.refs == 1 && kassert_fail == 0, "file references balance (refs %d)", fa.refs);
	CHECK(nvco_sx.x == 0 && sx_trouble == 0, "no lock left, no lock trouble");
}

static void
scenario_free_interrupted(void)
{
	setup_files();
	rm_calls = 0;
	rm_ioctl_alloc(&ffA, H1, NVCO_CLASS_ROOT_CLIENT, 0, 0);
	rm_calls = 0;
	CHECK(nvUvmInterfaceClientHold(&fa, H1) == NV_OK, "hold");
	sleep_hook = sleep_eintr;
	CHECK(rm_ioctl_free(&ffA, H1, 0, 0) == EINTR && rm_calls == 0, "an interrupted wait frees nothing and returns EINTR");
	sleep_hook = NULL;
	nvUvmInterfaceClientRelease(&fa, H1);
	CHECK(nvUvmInterfaceClientHold(&fa, H1) == NV_OK, "the interrupted free left the client usable (its count was undone)");
	nvUvmInterfaceClientRelease(&fa, H1);
	/* the RM refuses the free: the client lives on and holds work */
	CHECK(rm_ioctl_free(&ffA, H1, 0, 0x1B) == 0, "RM refused the free in its params");
	CHECK(nvUvmInterfaceClientHold(&fa, H1) == NV_OK, "a refused free does not leave holds blocked");
	nvUvmInterfaceClientRelease(&fa, H1);
	CHECK(rm_ioctl_free(&ffA, H1, 22, 0) == 22 && nvUvmInterfaceClientHold(&fa, H1) == NV_OK, "a failed free ioctl leaves holds possible");
	nvUvmInterfaceClientRelease(&fa, H1);
}

static int hold_during_rm_granted;
static void try_hold_in_rm(void) { if (nvUvmInterfaceClientHold(&fa, H1) == NV_OK) { hold_during_rm_granted++; nvUvmInterfaceClientRelease(&fa, H1); } }

static void
scenario_stranger_free(void)
{
	setup_files();
	rm_ioctl_alloc(&ffA, H1, NVCO_CLASS_ROOT_CLIENT, 0, 0);
	/* a free of A's client through a device file (who == NULL) or a second control file is refused with EPERM
	 * before the RM is called: a stranger neither reaches the RM nor raises the count */
	rm_calls = 0;
	hold_during_rm_granted = 0;
	rm_step_hook = try_hold_in_rm;
	CHECK(rm_ioctl_free(NULL, H1, 0, 0) == EPERM && rm_ioctl_free(&ffB, H1, 0, 0) == EPERM, "a stranger's free of a listed client is EPERM");
	rm_step_hook = NULL;
	CHECK(rm_calls == 0, "the RM was not called for a stranger's free (%d calls)", rm_calls);
	CHECK(nvUvmInterfaceClientHold(&fa, H1) == NV_OK, "a stranger's frees leave the owner's holds possible");
	nvUvmInterfaceClientRelease(&fa, H1);
	/* the owner's own free: no hold is granted while the RM frees */
	hold_during_rm_granted = 0;
	rm_step_hook = try_hold_in_rm;
	CHECK(rm_ioctl_free(&ffA, H1, 0, 0) == 0 && rm_calls == 1, "the owner's free completes");
	rm_step_hook = NULL;
	CHECK(hold_during_rm_granted == 0, "no hold is granted on a handle the RM is freeing");
	/* if the RM refused that free, the client is usable again */
	rm_ioctl_alloc(&ffA, H1, NVCO_CLASS_ROOT_CLIENT, 0, 0);
	CHECK(rm_ioctl_free(&ffA, H1, 0, 0x1B) == 0 && nvUvmInterfaceClientHold(&fa, H1) == NV_OK, "a refused free of the client leaves holds possible");
	nvUvmInterfaceClientRelease(&fa, H1);
}

static void free_unlisted_in_rm(void) { rm_step_hook = NULL; rm_ioctl_free(NULL, H1, 0, 0); }

static void
scenario_late_record(void)
{
	setup_files();
	/* an allocation returns from the RM; before its record lands, a free of that (still unlisted) handle runs to the
	 * RM and back: the late record must not give A a hold on a client the free may have taken */
	rm_step_hook = free_unlisted_in_rm;
	rm_ioctl_alloc(&ffA, H1, NVCO_CLASS_ROOT_CLIENT, 0, 0);
	rm_step_hook = NULL;
	CHECK(nvUvmInterfaceClientHold(&fa, H1) != NV_OK, "a late allocation record after a free of the unlisted handle grants no hold");
	
	/* a refused free of an unlisted handle leaves nothing and the next allocation is owned */
	rm_ioctl_free(NULL, H2, 0, 0x1B);
	CHECK(nvco_find(&nvco_table, H2) == NULL, "a refused free of an unlisted handle leaves no entry");
	rm_ioctl_alloc(&ffA, H2, NVCO_CLASS_ROOT_CLIENT, 0, 0);
	CHECK(nvUvmInterfaceClientHold(&fa, H2) == NV_OK, "the allocation after it is owned");
	nvUvmInterfaceClientRelease(&fa, H2);
}

static int junk_i;
static void junk_frees_in_rm(void)
{
	rm_step_hook = NULL;
	for (junk_i = 0; junk_i < 300; junk_i++)
		rm_ioctl_free(NULL, 0x77000000u + (uint32_t)junk_i, 0, 0x1B);	/* the RM refuses every one */
}

static void
scenario_junk_frees(void)
{
	setup_files();
	/* a device file floods refused frees of junk handles while A's allocation is in the RM: the record is not lost */
	rm_step_hook = junk_frees_in_rm;
	rm_ioctl_alloc(&ffA, H1, NVCO_CLASS_ROOT_CLIENT, 0, 0);
	rm_step_hook = NULL;
	CHECK(nvUvmInterfaceClientHold(&fa, H1) == NV_OK, "a flood of refused frees does not make A's allocation unrecordable");
	nvUvmInterfaceClientRelease(&fa, H1);
	CHECK(nvco_table.n == 1, "and leaves no tombstones (%zu entries)", nvco_table.n);
}

static void
scenario_leaf_and_diagnostics(void)
{
	int before;

	setup_files();
	/* the refusal of a hold made while the thread holds the table lock */
	rm_ioctl_alloc(&ffA, H1, NVCO_CLASS_ROOT_CLIENT, 0, 0);
	nvco_sx.x = 1;
	CHECK(nvUvmInterfaceClientHold(&fa, H1) == NV_ERR_INSUFFICIENT_PERMISSIONS, "a hold from under the table lock is refused");
	nvco_sx.x = 0;
	CHECK(sx_trouble == 0, "that refusal took no lock");
	/* the table is updated whatever the rate limiter says; a collision prints only when allowed */
	pps_allow = 0;
	before = pps_asked;
	rm_ioctl_alloc(&ffB, H1, NVCO_CLASS_ROOT_CLIENT, 0, 0);	/* the handle is listed for A: collision */
	CHECK(nvUvmInterfaceClientHold(&fa, H1) != NV_OK && nvUvmInterfaceClientHold(&fb, H1) != NV_OK,
	    "a collision leaves both parties unowned even when the message is suppressed");
	CHECK(pps_asked > before, "the collision message asked the rate limiter");
	pps_allow = 1;
	rm_ioctl_alloc(&ffA, H2, NVCO_CLASS_ROOT_CLIENT, 0, 0);
	pps_allow = 0;
	CHECK(nvUvmInterfaceClientHold(&fa, H2) == NV_OK, "a clean allocation is recorded with the rate limiter closed");
	nvUvmInterfaceClientRelease(&fa, H2);
	pps_allow = 1;
}

static void
scenario_close(void)
{
	setup_files();
	rm_ioctl_alloc(&ffA, H1, NVCO_CLASS_ROOT_CLIENT, 0, 0);
	/* closing the file forgets its clients */
	fa.refs = 1;
	nvco_forget_owner(&ffA);
	CHECK(nvUvmInterfaceClientHold(&fa, H1) != NV_OK, "a closed file's client is no longer held out");
	/* the last reference dropped by a release runs the close with no table lock held */
	setup_files();
	rm_ioctl_alloc(&ffA, H1, NVCO_CLASS_ROOT_CLIENT, 0, 0);
	CHECK(nvUvmInterfaceClientHold(&fa, H1) == NV_OK, "hold");
	fa.refs--;			/* the process closes the descriptor: the hold's reference remains */
	CHECK(!fa.closed, "close(2) does not release the file while a request holds it");
	nvUvmInterfaceClientRelease(&fa, H1);
	CHECK(fa.closed && sx_trouble == 0, "the release's fdrop ran the close destructor, with the table lock free");
	CHECK(nvUvmInterfaceClientHold(&fa, H1) != NV_OK, "the closed file's client is gone");
}

int
main(void)
{
	scenario_hold_release();
	scenario_recording();
	scenario_free_waits();
	scenario_stranger_free();
	scenario_late_record();
	scenario_junk_frees();
	scenario_leaf_and_diagnostics();
	scenario_free_interrupted();
	scenario_close();
	CHECK(sx_trouble == 0, "no lock trouble overall (%d)", sx_trouble);
	CHECK(runaway == 0, "no wait ran away (%d)", runaway);
	if (fails != 0)
		return (1);
	printf("nvidia_glue_harness: ok\n");
	return (0);
}

/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-3-Clause
 *
 * nvga_fakes.h - the kernel, as far as src/gb10-gpu-access/nvga_glue.c
 * needs it, for the userland test (tests/gpu_access_test.sh).
 *
 * The file is compiled with -DNVGA_FAKE_KERNEL, so it includes this instead
 * of the kernel headers.  The state the fakes share with the harness is
 * declared here and defined by the harness.
 */
#ifndef NVGA_FAKES_H_
#define NVGA_FAKES_H_

#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <sys/types.h>

#define	GID_VIDEO	44
#define	M_NVIDIA	0
#define	M_WAITOK	0
#define	RACCT_MEMLOCK	5

#define	TUNABLE_INT_FETCH(path, var)	nvga_fake_tunable(path, var)

/* the state the fakes share with the harness */
extern uint64_t nvga_fake_racct_uid_bytes;
extern uint64_t nvga_fake_racct_jail_bytes;
extern uint64_t nvga_fake_racct_limit;
extern int nvga_fake_racct_add_calls;
extern int nvga_fake_racct_sub_calls;
extern int nvga_fake_gid;

struct prison { int pr_id; };

struct ucred {
	uid_t		cr_uid;
	uid_t		cr_ruid;
	gid_t		cr_gid;
	int		cr_ngroups;
	gid_t		cr_groups[16];
	struct prison	*cr_prison;
	int		refs;
};

struct thread { struct ucred *td_ucred; };
struct proc { int id; };

extern struct thread nvga_fake_thread;
extern struct proc nvga_fake_proc;
#define	curthread	(&nvga_fake_thread)
#define	curproc		(&nvga_fake_proc)

static inline struct ucred *
crhold(struct ucred *cr)
{
	cr->refs++;
	return (cr);
}

static inline void
crfree(struct ucred *cr)
{
	cr->refs--;
}

static inline void
racct_add_cred(struct ucred *cred, int resource, uint64_t amount)
{
	(void)resource;
	nvga_fake_racct_add_calls++;
	if (cred->cr_prison != NULL)
		nvga_fake_racct_jail_bytes += amount;
	else
		nvga_fake_racct_uid_bytes += amount;
}

static inline void
racct_sub_cred(struct ucred *cred, int resource, uint64_t amount)
{
	(void)resource;
	nvga_fake_racct_sub_calls++;
	if (cred->cr_prison != NULL)
		nvga_fake_racct_jail_bytes -= amount;
	else
		nvga_fake_racct_uid_bytes -= amount;
}

static inline uint64_t
racct_get_limit(struct proc *p, int resource)
{
	(void)p;
	(void)resource;
	return (nvga_fake_racct_limit);
}

struct mtx { int held; };

/*
 * How many fake mutexes are held, and how many allocations were made
 * while one was held.  An allocation that can wait (M_WAITOK) sleeps, and
 * a thread that sleeps while it holds a mutex panics the kernel: the
 * fake counts it, so the harness can see it.
 */
extern int nvga_fake_mtx_held;
extern int nvga_fake_malloc_under_lock;

static inline void
mtx_lock(struct mtx *m)
{
	m->held++;
	nvga_fake_mtx_held++;
}

static inline void
mtx_unlock(struct mtx *m)
{
	m->held--;
	nvga_fake_mtx_held--;
}

/* the device class: the units of the GPUs */
struct device { int unit; };
struct nv_state { uint32_t gpu_id; };
struct nvidia_softc { struct device *dev; struct nv_state *nv_state; };
struct devclass { unsigned int dc_nunits; struct nvidia_softc *softc[8]; };

extern struct devclass *nvidia_devclass;

static inline struct nvidia_softc *
devclass_get_softc(struct devclass *dc, unsigned int unit)
{
	if (dc == NULL || unit >= dc->dc_nunits)
		return (NULL);
	return (dc->softc[unit]);
}

static inline int
devclass_get_maxunit(struct devclass *dc)
{
	if (dc == NULL || dc->dc_nunits == 0)
		return (-1);
	return ((int)dc->dc_nunits - 1);
}

static inline int
device_get_unit(struct device *dev)
{
	return (dev->unit);
}

/* the sysctls */
struct sysctl_oid { unsigned int oid_name; };
struct sysctl_ctx_list { int dummy; };
struct sysctl_req {
	char	*oldbuf;
	size_t	oldlen;
	size_t	oldidx;
	char	*newbuf;
	size_t	newlen;
	size_t	newidx;
	void	*newptr;
};

/* the sysctls the glue registered, so the harness can read the state the
 * way a user reads it: through the sysctls */
struct nvga_fake_sysctl {
	const char	*name;
	int		type;		/* CTLTYPE_INT or CTLTYPE_LONG */
	int		(*handler)(struct sysctl_oid *, void *, intmax_t,
			    struct sysctl_req *);
};
#define	NVGA_FAKE_SYSCTL_MAX	16
extern struct nvga_fake_sysctl nvga_fake_sysctls[NVGA_FAKE_SYSCTL_MAX];
extern int nvga_fake_nsysctls;

/*
 * The number of bytes the last read copied.  A handler that hands over
 * more bytes than its own string holds has read past the end of that
 * string: the harness compares the two.
 */
extern size_t nvga_fake_out_len;

#define	SYSCTL_HANDLER_ARGS	struct sysctl_oid *oidp, void *arg1, \
		    intmax_t arg2, struct sysctl_req *req
#define	SYSCTL_OUT(req, buf, len)	nvga_fake_out(req, buf, len)
#define	SYSCTL_IN(req, buf, len)	nvga_fake_in(req, buf, len)
#define	SYSCTL_CHILDREN(parent)	(parent)
#define	SYSCTL_ADD_PROC(ctx, oid, oidname, name, type, arg, flags, handler, fmt, desc) \
	nvga_fake_sysctl_add(name, type, handler)
#define	OID_AUTO		0
#define	CTLTYPE_INT		1
#define	CTLTYPE_LONG		2
#define	CTLTYPE_STRING		3
/* the type lives in the low bits; the flags are above them, as in the
 * kernel's own sysctl.h */
#define	CTLTYPE_MASK		0xf
#define	CTLFLAG_RD		0x10
#define	CTLFLAG_RW		0x20
#define	CTLFLAG_DYN		0x40

int nvga_fake_sysctl_add(const char *name, int type,
    int (*handler)(struct sysctl_oid *, void *, intmax_t,
    struct sysctl_req *));
int nvga_fake_out(struct sysctl_req *req, const void *buf, size_t len);
int nvga_fake_in(struct sysctl_req *req, void *buf, size_t len);
int nvga_fake_tunable(const char *path, int *var);

/* malloc/free with the kernel's shape */
static inline void *
nvga_fake_malloc(size_t n)
{
	if (nvga_fake_mtx_held > 0)
		nvga_fake_malloc_under_lock++;
	return (calloc(1, n));
}

static inline void
nvga_fake_free(void *p)
{
	free(p);
}

#define	malloc(n, t, f)	nvga_fake_malloc(n)
#define	free(p, t)	nvga_fake_free(p)

#endif /* NVGA_FAKES_H_ */

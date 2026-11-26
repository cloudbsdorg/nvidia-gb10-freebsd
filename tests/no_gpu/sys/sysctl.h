/* Tiny user-space sysctl KPI fake for no_gpu_test.sh. */
#ifndef _FAKE_SYS_SYSCTL_H_
#define _FAKE_SYS_SYSCTL_H_

#include <stddef.h>
#include <stdbool.h>

#define CTLTYPE		0xf
#define CTLTYPE_INT	2
#define CTLFLAG_RD	0x80000000
#define CTLFLAG_DYN	0x00010000
#define OID_AUTO	0

struct sysctl_ctx_list {
	int freed;
};

struct sysctl_req {
	void *oldptr;
	size_t oldlen;
	const void *newptr;
};

struct sysctl_oid;
typedef int (*sysctl_handler)(struct sysctl_oid *, void *, int,
    struct sysctl_req *);

struct sysctl_oid {
	const char *name;
	struct sysctl_ctx_list *ctx;
	struct sysctl_oid *parent;
	void *arg1;
	int arg2;
	sysctl_handler handler;
	int flags;
	const char *fmt;
	const char *description;
};

#define SYSCTL_HANDLER_ARGS \
	struct sysctl_oid *oidp, void *arg1, int arg2, struct sysctl_req *req

struct sysctl_oid *fake_children(struct sysctl_oid *);
#define SYSCTL_CHILDREN(oid)	fake_children(oid)

/*
 * What the kernel's SYSCTL_ADD_PROC takes.  The fake takes it as one
 * struct, so the fake's own function does not grow a parameter for every
 * field the kernel's macro carries.
 */
struct fake_sysctl_node {
	struct sysctl_ctx_list *ctx;
	struct sysctl_oid *parent;
	const char *name;
	int flags;
	void *arg1;
	int arg2;
	sysctl_handler handler;
	const char *fmt;
	const char *desc;
};

struct sysctl_oid *fake_sysctl_add_proc(const struct fake_sysctl_node *);
int fake_sysctl_out(struct sysctl_req *, const void *, size_t);

#define SYSCTL_ADD_PROC(ctx, parent, nbr, name, flags, arg1, arg2, handler, \
    fmt, desc) \
	fake_sysctl_add_proc(&(const struct fake_sysctl_node){ \
	    (ctx), (parent), (name), (flags), (arg1), (arg2), (handler), \
	    (fmt), (desc) })
#define SYSCTL_OUT(req, buf, len)	fake_sysctl_out((req), (buf), (len))

#endif

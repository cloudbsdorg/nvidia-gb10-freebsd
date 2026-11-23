/* Tiny user-space sysctl KPI fake for version_sysctl_test.sh. */
#ifndef _FAKE_SYS_SYSCTL_H_
#define _FAKE_SYS_SYSCTL_H_

#include <stddef.h>
#include <stdbool.h>

#define CTLTYPE		0xf
#define CTLTYPE_INT	2
#define CTLTYPE_STRING	3
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
#define SYSCTL_CHILDREN(oid)		fake_children(oid)
#define SYSCTL_STATIC_CHILDREN(oid)	(oid)

extern struct sysctl_oid fake_hw;
#define _hw	(&fake_hw)

struct sysctl_oid *fake_sysctl_add_node(struct sysctl_ctx_list *,
    struct sysctl_oid *, const char *, int, const char *);
struct sysctl_oid *fake_sysctl_add_string(struct sysctl_ctx_list *,
    struct sysctl_oid *, const char *, int, char *, size_t, const char *);
struct sysctl_oid *fake_sysctl_add_int(struct sysctl_ctx_list *,
    struct sysctl_oid *, const char *, int, int *, const char *);
struct fake_proc_args {
	int flags;
	void *arg1;
	int arg2;
	sysctl_handler handler;
	const char *fmt;
	const char *desc;
};
struct sysctl_oid *fake_sysctl_add_proc(struct sysctl_ctx_list *,
    struct sysctl_oid *, const char *, const struct fake_proc_args *);
int fake_sysctl_out(struct sysctl_req *, const void *, size_t);
void fake_sysctl_ctx_free(struct sysctl_ctx_list *);

#define SYSCTL_ADD_NODE(ctx, parent, nbr, name, flags, arg, desc) \
	fake_sysctl_add_node((ctx), (parent), (name), (flags), (desc))
#define SYSCTL_ADD_STRING(ctx, parent, nbr, name, flags, arg, len, desc) \
	fake_sysctl_add_string((ctx), (parent), (name), (flags), (arg), (len), \
	    (desc))
#define SYSCTL_ADD_INT(ctx, parent, nbr, name, flags, arg, len, desc) \
	fake_sysctl_add_int((ctx), (parent), (name), (flags), (arg), (desc))
#define SYSCTL_ADD_PROC(ctx, parent, nbr, name, flags, arg1, arg2, handler, \
    fmt, desc) \
	fake_sysctl_add_proc((ctx), (parent), (name), \
	    &(const struct fake_proc_args){ (flags), (arg1), (arg2), (handler), \
	    (fmt), (desc) })
#define SYSCTL_OUT(req, ptr, len)	fake_sysctl_out((req), (ptr), (len))
#define sysctl_ctx_init(ctx)		((ctx)->freed = 0)
#define sysctl_ctx_free(ctx)		fake_sysctl_ctx_free(ctx)

#endif /* _FAKE_SYS_SYSCTL_H_ */

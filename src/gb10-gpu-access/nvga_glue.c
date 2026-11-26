/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-3-Clause
 *
 * nvga_glue.c - the GPU access check (Track #2374) and the wired GPU memory
 * accounting (Track #2376).  Our own file, compiled into nvidia.ko; the
 * rules are in nvga_policy.h and the interface is in nvga_glue.h.
 *
 * The access check answers two questions:
 *   - may this credential use this GPU?  (nvga_may_use_unit())
 *   - may this caller attach this GPU?  (nvga_check_attach())
 * The credential is the one of the calling thread, and the answer is per
 * credential and per jail: outside a jail the group that owns the device
 * nodes decides, in a jail the grant the administrator gave that jail
 * decides.  A jail is granted nothing by default.
 *
 * The accounting charges the memory the RM takes to the credential that
 * asked for it.  On this board the GPU has no memory of its own: every
 * allocation is wired system RAM, so an allocation without a limit lets one
 * user take the host's memory.  The bytes are charged per uid and per jail,
 * the kernel's own racct containers are charged too (so the uid and the jail
 * see the wired memory of the GPU), and an allocation over a limit is
 * refused before the memory is handed out.
 *
 * Locking: nvga_mtx is a leaf lock.  It is taken around the tables and the
 * counters only; it is never held across an RM call, and it is never held
 * while the racct lock is taken (the racct calls are made with it dropped).
 */
#ifdef NVGA_FAKE_KERNEL
/*
 * The userland test (tests/gpu_access_test.sh) compiles this file against
 * fakes of the kernel: tests/data/nvga_fakes.h stands in for the kernel
 * headers below and for the kernel calls this file makes.
 */
#include "nvga_fakes.h"
#else
#include "nv.h"
#include "nv-freebsd.h"

#include <sys/param.h>
#include <sys/bus.h>
#include <sys/conf.h>
#include <sys/jail.h>
#include <sys/kernel.h>
#include <sys/mutex.h>
#include <sys/racct.h>
#include <sys/sysctl.h>
#include <sys/systm.h>
#include <sys/ucred.h>
#endif

#include "nvga_glue.h"
#include "nvga_nodes.h"

/*
 * The mode and the group of the RM nodes are in nvga_nodes.h, so
 * nvidia-modeset.ko, which makes a node of its own, carries the same rule
 * without needing a symbol of ours.
 */
gid_t
nvga_device_gid(void)
{
	return (nvga_nodes_gid());
}

mode_t
nvga_device_mode(void)
{
	return (NVGA_NODES_MODE);
}

/* the state of the check and of the accounting */
static struct mtx nvga_mtx;
static struct nvga_rules nvga_rules;
static struct nvga_counter nvga_uid_totals[NVGA_UID_SLOTS];
static struct nvga_counter nvga_jail_totals[NVGA_UID_SLOTS];
static uint64_t nvga_wired_total;
static uint64_t nvga_wired_limit;		/* per credential, 0: unlimited */
static uint64_t nvga_wired_total_limit;	/* host wide, 0: unlimited */
static uint64_t nvga_denied_attaches;
static uint64_t nvga_refused_allocs;

/*
 * The size of the buffer the two string sysctls are read into.
 *
 * The form of the grants (NVGA_MAX_JAILS jails, each of them NVGA_MAX_UNITS
 * units) and the list of the users that hold memory (NVGA_UID_SLOTS of
 * them) are both longer than a page, so the buffer is not on the stack:
 * it is taken from the kernel's memory for the time of the read.  8192
 * holds the longest of the two, so a read never cuts a string in half.
 */
#define	NVGA_FMT_SIZE	8192

/* one charged allocation: what the memory was charged to, and to how much */
struct nvga_charge {
	void		*private;
	uint64_t	bytes;
	struct ucred	*cred;		/* a reference: the release needs it */
	uint32_t	uid;
	int		jail_id;
	struct nvga_charge *next;
};

static struct nvga_charge *nvga_charges;

/*
 * nvga_init - the rules in force: the group that owns the RM nodes and the
 * host root's right to use every GPU.  Called when the driver attaches,
 * before any client can ask for a GPU.
 */
void
nvga_init(void)
{
	mtx_lock(&nvga_mtx);
	nvga_rules.node_gid = (uint32_t)nvga_device_gid();
	nvga_rules.allow_root = 1;
	nvga_rules.njails = 0;
	mtx_unlock(&nvga_mtx);
}

/*
 * nvga_cred_snapshot - the facts about a credential that the policy needs.
 *
 * The effective uid decides the access (it is the uid the kernel checks the
 * nodes against); the real uid decides the accounting, because that is the
 * uid whose racct container the kernel charges.  The effective group counts
 * as a group of its own: the kernel's own access check counts it too.
 */
static void
nvga_cred_snapshot(const struct ucred *cred, struct nvga_cred *out)
{
	int i, n;

	memset(out, 0, sizeof(*out));
	if (cred == NULL) {
		/*
		 * A thread of the kernel has no credential: this is the
		 * driver's own work, not a user's.  It is allowed, and it is
		 * charged to the system.
		 */
		out->uid = 0;
		out->jail_id = -1;
		return;
	}
	out->uid = cred->cr_uid;
	out->jail_id = (cred->cr_prison != NULL) ? cred->cr_prison->pr_id : -1;
	n = cred->cr_ngroups;
	if (n > NVGA_MAX_GROUPS)
		n = NVGA_MAX_GROUPS;
	for (i = 0; i < n; i++)
		out->groups[i] = cred->cr_groups[i];
	out->ngroups = n;
	if (out->ngroups < NVGA_MAX_GROUPS)
		out->groups[out->ngroups++] = cred->cr_gid;
}

/*
 * nvga_unit_of_gpu - the unit of the device node of this RM GPU, or -1 when
 * there is no such GPU.  The unit is the number of the device node
 * (/dev/nvidiaN); it is never assumed, it is looked up in the device class.
 */
static int
nvga_unit_of_gpu(uint32_t gpu_id)
{
	int i, max;

	if (nvidia_devclass == NULL)
		return (-1);
	max = devclass_get_maxunit(nvidia_devclass);
	for (i = 0; i <= max; i++) {
		struct nvidia_softc *sc;

		sc = devclass_get_softc(nvidia_devclass, i);
		if (sc == NULL || sc->nv_state == NULL)
			continue;
		if (sc->nv_state->gpu_id == gpu_id)
			return (device_get_unit(sc->dev));
	}
	return (-1);
}

/*
 * nvga_may_use_unit - may the calling credential use this GPU unit?
 *
 * The answer is NVGA_ALLOW when it may, and the reason it may not otherwise.
 * The credential is the one of the calling thread: the check runs where the
 * caller asks for the GPU, not where the RM happens to run.
 */
int
nvga_may_use_unit(int unit)
{
	struct nvga_cred cred;
	int decision;

	nvga_cred_snapshot(curthread->td_ucred, &cred);
	mtx_lock(&nvga_mtx);
	decision = nvga_may_use(&cred, unit, &nvga_rules);
	mtx_unlock(&nvga_mtx);
	return (decision);
}

/*
 * nvga_check_attach - may the caller attach this RM GPU?
 *
 * 0 when it may, EPERM when it may not.  A GPU that cannot be found is
 * refused too: without the unit there is no right to prove, and the check
 * fails closed.
 */
int
nvga_check_attach(uint32_t gpu_id)
{
	int unit, decision;

	unit = nvga_unit_of_gpu(gpu_id);
	if (unit < 0) {
		mtx_lock(&nvga_mtx);
		nvga_denied_attaches++;
		mtx_unlock(&nvga_mtx);
		return (EPERM);
	}
	decision = nvga_may_use_unit(unit);
	if (decision != NVGA_ALLOW) {
		mtx_lock(&nvga_mtx);
		nvga_denied_attaches++;
		mtx_unlock(&nvga_mtx);
		return (EPERM);
	}
	return (0);
}

/*
 * nvga_rctl_limit - the cap an rctl rule puts on the wired memory of this
 * process' subject, or 0 when no rule caps it.  The rule is the kernel's
 * own (rctl -r user:... memorylocked:deny=...), and it is asked for the
 * process of the caller, so a rule on the uid or on the jail applies.
 */
static uint64_t
nvga_rctl_limit(const struct ucred *cred)
{
	uint64_t limit;

	(void)cred;
	if (curproc == NULL)
		return (0);
	limit = racct_get_limit(curproc, RACCT_MEMLOCK);
	if (limit == UINT64_MAX)
		return (0);
	return (limit);
}

/*
 * nvga_wired_alloc - charge this many bytes of wired GPU memory to the
 * calling credential.
 *
 * 0 when the memory may be handed out, ENOMEM when it may not: the caller
 * must then give the memory back and fail the allocation.  The bytes are
 * charged to the uid, and to the jail when the caller is in one, and they
 * are charged to the kernel's racct containers too, so the uid and the jail
 * see the wired memory of the GPU in the kernel's own accounting.
 *
 * A thread of the kernel has no credential: its memory is the driver's own
 * work, so a user's limit does not hold it (the host's own limit does).
 */
int
nvga_wired_alloc(uint64_t count, uint64_t page_size, void *private)
{
	struct ucred *cred = curthread->td_ucred;
	struct nvga_cred facts;
	struct nvga_limits limits;
	struct nvga_charge *ch;
	uint64_t bytes, cred_total, jail_total, total, rctl_limit;
	uint32_t uid;
	int jail_id, slot, jslot;

	if (count == 0 || page_size == 0)
		return (0);
	if (count > UINT64_MAX / page_size)
		return (ENOMEM);	/* the size does not fit: refuse it */
	bytes = count * page_size;

	nvga_cred_snapshot(cred, &facts);
	uid = (cred != NULL) ? cred->cr_ruid : 0;
	jail_id = facts.jail_id;

	/*
	 * The rctl cap is asked for before the lock is taken: the kernel's
	 * racct lock is never taken under ours.
	 */
	rctl_limit = nvga_rctl_limit(cred);

	/*
	 * The record of the charge is taken before the lock: an allocation
	 * that can wait sleeps, and a thread that sleeps while it holds a
	 * mutex panics the kernel.  The record is freed again (outside the
	 * lock) when the charge is refused.
	 */
	ch = malloc(sizeof(*ch), M_NVIDIA, M_WAITOK);
	if (ch == NULL)
		return (ENOMEM);

	mtx_lock(&nvga_mtx);
	slot = nvga_counter_find(nvga_uid_totals, NVGA_UID_SLOTS, uid, 1);
	if (slot < 0) {
		mtx_unlock(&nvga_mtx);
		free(ch, M_NVIDIA);
		return (ENOMEM);
	}
	cred_total = nvga_uid_totals[slot].bytes;
	jail_total = 0;
	jslot = -1;
	if (jail_id >= 0) {
		jslot = nvga_counter_find(nvga_jail_totals, NVGA_UID_SLOTS,
		    (uint32_t)jail_id, 1);
		if (jslot < 0) {
			mtx_unlock(&nvga_mtx);
			free(ch, M_NVIDIA);
			return (ENOMEM);
		}
		jail_total = nvga_jail_totals[jslot].bytes;
	}
	total = nvga_wired_total;
	limits.per_credential = nvga_wired_limit;
	limits.total = nvga_wired_total_limit;
	limits.rctl = rctl_limit;
	if (cred == NULL) {
		/*
		 * A thread of the kernel: the driver's own work, not a
		 * user's.  A user's limit must not refuse it, or the system
		 * would stop working when a user is at their limit.  The
		 * host's own limit still holds it.
		 */
		limits.per_credential = 0;
		limits.rctl = 0;
	}
	if (!nvga_wired_allowed(cred_total, jail_total, jail_id >= 0, total,
	    bytes, &limits)) {
		nvga_refused_allocs++;
		mtx_unlock(&nvga_mtx);
		free(ch, M_NVIDIA);
		return (ENOMEM);
	}
	ch->private = private;
	ch->bytes = bytes;
	ch->cred = (cred != NULL) ? crhold(cred) : NULL;
	ch->uid = uid;
	ch->jail_id = jail_id;
	ch->next = nvga_charges;
	nvga_charges = ch;
	nvga_uid_totals[slot].bytes += bytes;
	if (jslot >= 0)
		nvga_jail_totals[jslot].bytes += bytes;
	nvga_wired_total += bytes;
	mtx_unlock(&nvga_mtx);

	/* the kernel's own accounting: the uid and the jail see the memory */
	if (cred != NULL)
		racct_add_cred(cred, RACCT_MEMLOCK, bytes);
	return (0);
}

/*
 * nvga_wired_free - give the wired memory back.
 *
 * The charge is taken off the uid, off the jail and off the host's total,
 * and the kernel's racct containers are credited with the same bytes.  A
 * memory that was never charged (a charge that failed, an allocation that
 * the RM gave back) changes nothing.
 */
void
nvga_wired_free(void *private)
{
	struct nvga_charge *ch, **pp;
	struct ucred *cred;
	uint64_t bytes;
	int slot;

	mtx_lock(&nvga_mtx);
	pp = &nvga_charges;
	ch = NULL;
	while ((ch = *pp) != NULL) {
		if (ch->private == private) {
			*pp = ch->next;
			break;
		}
		pp = &ch->next;
	}
	if (ch == NULL) {
		mtx_unlock(&nvga_mtx);
		return;
	}
	bytes = ch->bytes;
	slot = nvga_counter_find(nvga_uid_totals, NVGA_UID_SLOTS, ch->uid, 0);
	if (slot >= 0 && nvga_uid_totals[slot].bytes >= bytes)
		nvga_uid_totals[slot].bytes -= bytes;
	if (ch->jail_id >= 0) {
		slot = nvga_counter_find(nvga_jail_totals, NVGA_UID_SLOTS,
		    (uint32_t)ch->jail_id, 0);
		if (slot >= 0 && nvga_jail_totals[slot].bytes >= bytes)
			nvga_jail_totals[slot].bytes -= bytes;
	}
	if (nvga_wired_total >= bytes)
		nvga_wired_total -= bytes;
	cred = ch->cred;
	mtx_unlock(&nvga_mtx);

	/* the record is freed with the lock dropped */
	free(ch, M_NVIDIA);

	if (cred != NULL) {
		racct_sub_cred(cred, RACCT_MEMLOCK, bytes);
		crfree(cred);
	}
}

/*
 * nvga_jails_format - the jail grants in the string form the sysctl shows.
 */
static int
nvga_jails_format(char *buf, size_t len)
{
	struct nvga_jail_grant *g;
	char tmp[32];
	size_t off = 0;
	int j, u, n, full = 0;

	if (len == 0)
		return (0);
	buf[0] = '\0';
	mtx_lock(&nvga_mtx);
	for (j = 0; j < nvga_rules.njails && !full; j++) {
		g = &nvga_rules.jails[j];
		n = snprintf(tmp, sizeof(tmp), "%s%d:", j ? ";" : "",
		    g->jail_id);
		if (n < 0 || (size_t)n >= sizeof(tmp))
			break;
		off = nvga_fmt_add(buf, len, off, &full, tmp);
		for (u = 0; u < g->nunits && !full; u++) {
			n = snprintf(tmp, sizeof(tmp), "%s%d", u ? "," : "",
			    g->units[u]);
			if (n < 0 || (size_t)n >= sizeof(tmp))
				break;
			off = nvga_fmt_add(buf, len, off, &full, tmp);
		}
	}
	mtx_unlock(&nvga_mtx);
	return ((int)off);
}

/*
 * the two tables of totals, and the mark each of them is written with:
 * "u1001:524288" for a uid, "j3:1048576" for a jail.
 */
static const struct nvga_counter *const nvga_total_tables[2] = {
	nvga_uid_totals, nvga_jail_totals
};
static const char nvga_total_marks[2] = { 'u', 'j' };

/*
 * nvga_totals_format - the totals of the users and of the jails, in the
 * string form the sysctl shows.
 *
 * The two are the same walk over the same kind of table, with a different
 * mark in front of the number, so one function does both.
 *
 * The walk stops when the buffer is full (*full) or when every slot is
 * empty.  *first is cleared when the first total is written, so that the
 * totals are separated by one comma and there is none in front.
 */
static void
nvga_totals_format(char *buf, size_t len, size_t *off, int *full, int *first)
{
	char tmp[64];
	const struct nvga_counter *tab;
	int t, i, n;

	for (t = 0; t < 2 && !*full; t++) {
		tab = nvga_total_tables[t];
		for (i = 0; i < NVGA_UID_SLOTS && !*full; i++) {
			if (!tab[i].used || tab[i].bytes == 0)
				continue;
			n = snprintf(tmp, sizeof(tmp), "%s%c%u:%llu",
			    *first ? "" : ",", nvga_total_marks[t], tab[i].uid,
			    (unsigned long long)tab[i].bytes);
			if (n < 0 || (size_t)n >= sizeof(tmp))
				break;
			*off = nvga_fmt_add(buf, len, *off, full, tmp);
			*first = 0;
		}
	}
}

/*
 * nvga_uids_format - the wired memory of each uid that holds some, and of
 * each jail that holds some, in the string form the sysctl shows.
 */
static int
nvga_uids_format(char *buf, size_t len)
{
	size_t off = 0;
	int first = 1, full = 0;

	if (len == 0)
		return (0);
	buf[0] = '\0';
	mtx_lock(&nvga_mtx);
	nvga_totals_format(buf, len, &off, &full, &first);
	mtx_unlock(&nvga_mtx);
	return ((int)off);
}

/* ---- the sysctls: the state of the check and of the accounting ---- */

static int
nvga_sysctl_access(SYSCTL_HANDLER_ARGS)
{
	int value = 1;

	(void)oidp;
	(void)arg1;
	(void)arg2;
	SYSCTL_OUT(req, &value, sizeof(value));
	return (0);
}

static int
nvga_sysctl_group(SYSCTL_HANDLER_ARGS)
{
	int value = (int)nvga_device_gid();

	(void)oidp;
	(void)arg1;
	(void)arg2;
	SYSCTL_OUT(req, &value, sizeof(value));
	return (0);
}

static int
nvga_sysctl_denied(SYSCTL_HANDLER_ARGS)
{
	int64_t value;

	(void)oidp;
	(void)arg1;
	(void)arg2;
	mtx_lock(&nvga_mtx);
	value = (int64_t)nvga_denied_attaches;
	mtx_unlock(&nvga_mtx);
	SYSCTL_OUT(req, &value, sizeof(value));
	return (0);
}

static int
nvga_sysctl_wired_bytes(SYSCTL_HANDLER_ARGS)
{
	int64_t value;

	(void)oidp;
	(void)arg1;
	(void)arg2;
	mtx_lock(&nvga_mtx);
	value = (int64_t)nvga_wired_total;
	mtx_unlock(&nvga_mtx);
	SYSCTL_OUT(req, &value, sizeof(value));
	return (0);
}

static int
nvga_sysctl_wired_refused(SYSCTL_HANDLER_ARGS)
{
	int64_t value;

	(void)oidp;
	(void)arg1;
	(void)arg2;
	mtx_lock(&nvga_mtx);
	value = (int64_t)nvga_refused_allocs;
	mtx_unlock(&nvga_mtx);
	SYSCTL_OUT(req, &value, sizeof(value));
	return (0);
}

/*
 * nvga_sysctl_wired_limit - the limit of one credential, in bytes.  0 is
 * no limit.  The limit is asked of the allocation that comes next; a limit
 * that is set under the total that is already held does not take the memory
 * back.
 */
static int
nvga_sysctl_wired_limit(SYSCTL_HANDLER_ARGS)
{
	int64_t value;
	int error;

	(void)oidp;
	(void)arg1;
	(void)arg2;
	if (req->newptr == NULL) {
		mtx_lock(&nvga_mtx);
		value = (int64_t)nvga_wired_limit;
		mtx_unlock(&nvga_mtx);
		SYSCTL_OUT(req, &value, sizeof(value));
		return (0);
	}
	error = SYSCTL_IN(req, &value, sizeof(value));
	if (error)
		return (error);
	if (value < 0)
		return (EINVAL);
	mtx_lock(&nvga_mtx);
	nvga_wired_limit = (uint64_t)value;
	mtx_unlock(&nvga_mtx);
	return (0);
}

/*
 * nvga_sysctl_wired_total_limit - the limit of the whole host, in bytes.
 */
static int
nvga_sysctl_wired_total_limit(SYSCTL_HANDLER_ARGS)
{
	int64_t value;
	int error;

	(void)oidp;
	(void)arg1;
	(void)arg2;
	if (req->newptr == NULL) {
		mtx_lock(&nvga_mtx);
		value = (int64_t)nvga_wired_total_limit;
		mtx_unlock(&nvga_mtx);
		SYSCTL_OUT(req, &value, sizeof(value));
		return (0);
	}
	error = SYSCTL_IN(req, &value, sizeof(value));
	if (error)
		return (error);
	if (value < 0)
		return (EINVAL);
	mtx_lock(&nvga_mtx);
	nvga_wired_total_limit = (uint64_t)value;
	mtx_unlock(&nvga_mtx);
	return (0);
}

/*
 * nvga_sysctl_jails - the jail grants, in the string form the policy reads:
 * "3:0" grants unit 0 to jail 3, "3:0,1" grants units 0 and 1, "3:all"
 * grants every unit.  A string that does not parse is refused whole: the
 * grants in force stay the ones that were there.
 *
 * The buffer is taken from the kernel's memory, not from the stack: the
 * form of the grants is longer than a page, and a read must bring all of
 * it, or a read followed by a write would drop the grants that did not
 * fit.
 */
static int
nvga_sysctl_jails(SYSCTL_HANDLER_ARGS)
{
	char *buf;
	struct nvga_rules parsed;
	int error;
	size_t len, newlen;

	(void)oidp;
	(void)arg1;
	(void)arg2;
	buf = malloc(NVGA_FMT_SIZE, M_NVIDIA, M_WAITOK);
	if (buf == NULL)
		return (ENOMEM);
	len = (size_t)nvga_jails_format(buf, NVGA_FMT_SIZE);
	error = SYSCTL_OUT(req, buf, len + 1);
	if (error != 0 || req->newptr == NULL) {
		free(buf, M_NVIDIA);
		return (error);
	}

	if (req->newidx > req->newlen) {		/* no length to read */
		free(buf, M_NVIDIA);
		return (EINVAL);
	}
	newlen = req->newlen - req->newidx;
	if (newlen >= NVGA_FMT_SIZE) {
		free(buf, M_NVIDIA);
		return (EINVAL);
	}
	memset(buf, 0, NVGA_FMT_SIZE);
	error = SYSCTL_IN(req, buf, newlen);
	if (error != 0) {
		free(buf, M_NVIDIA);
		return (error);
	}
	buf[newlen] = '\0';

	mtx_lock(&nvga_mtx);
	parsed = nvga_rules;
	mtx_unlock(&nvga_mtx);
	if (nvga_parse_jails(buf, &parsed) != 0) {
		free(buf, M_NVIDIA);
		return (EINVAL);
	}
	mtx_lock(&nvga_mtx);
	nvga_rules = parsed;
	mtx_unlock(&nvga_mtx);
	free(buf, M_NVIDIA);
	return (0);
}

/*
 * nvga_sysctl_uids - the wired memory per uid and per jail, as text.
 */
static int
nvga_sysctl_uids(SYSCTL_HANDLER_ARGS)
{
	char *buf;
	int len, error;

	(void)oidp;
	(void)arg1;
	(void)arg2;
	buf = malloc(NVGA_FMT_SIZE, M_NVIDIA, M_WAITOK);
	if (buf == NULL)
		return (ENOMEM);
	len = nvga_uids_format(buf, NVGA_FMT_SIZE);
	error = SYSCTL_OUT(req, buf, (size_t)len + 1);
	free(buf, M_NVIDIA);
	return (error);
}

/*
 * nvga_sysctl_init - the state sysctls, under the hw.nvidia node.
 */
void
nvga_sysctl_init(struct sysctl_ctx_list *ctx, struct sysctl_oid *parent)
{
	SYSCTL_ADD_PROC(ctx, SYSCTL_CHILDREN(parent), OID_AUTO, "gpu_access",
	    CTLTYPE_INT | CTLFLAG_RD | CTLFLAG_DYN, NULL, 0,
	    nvga_sysctl_access, "I",
	    "GPU access check: 1 when the check is in force");
	SYSCTL_ADD_PROC(ctx, SYSCTL_CHILDREN(parent), OID_AUTO,
	    "gpu_access_group", CTLTYPE_INT | CTLFLAG_RD | CTLFLAG_DYN, NULL, 0,
	    nvga_sysctl_group, "I",
	    "The group that owns the RM device nodes");
	SYSCTL_ADD_PROC(ctx, SYSCTL_CHILDREN(parent), OID_AUTO,
	    "gpu_access_denied", CTLTYPE_LONG | CTLFLAG_RD | CTLFLAG_DYN, NULL, 0,
	    nvga_sysctl_denied, "L",
	    "The number of GPU attaches that were refused");
	SYSCTL_ADD_PROC(ctx, SYSCTL_CHILDREN(parent), OID_AUTO,
	    "gpu_access_jails", CTLTYPE_STRING | CTLFLAG_RW | CTLFLAG_DYN,
	    NULL, 0, nvga_sysctl_jails, "A",
	    "The GPUs each jail may use, as jailid:unit[,unit] separated by ';'");
	SYSCTL_ADD_PROC(ctx, SYSCTL_CHILDREN(parent), OID_AUTO,
	    "gpu_wired_bytes", CTLTYPE_LONG | CTLFLAG_RD | CTLFLAG_DYN, NULL, 0,
	    nvga_sysctl_wired_bytes, "L",
	    "The wired memory of the GPU charged to the users, in bytes");
	SYSCTL_ADD_PROC(ctx, SYSCTL_CHILDREN(parent), OID_AUTO,
	    "gpu_wired_limit", CTLTYPE_LONG | CTLFLAG_RW | CTLFLAG_DYN, NULL, 0,
	    nvga_sysctl_wired_limit, "L",
	    "The wired memory of the GPU one user (or one jail) may hold, in "
	    "bytes; 0 is no limit");
	SYSCTL_ADD_PROC(ctx, SYSCTL_CHILDREN(parent), OID_AUTO,
	    "gpu_wired_total_limit", CTLTYPE_LONG | CTLFLAG_RW | CTLFLAG_DYN,
	    NULL, 0, nvga_sysctl_wired_total_limit, "L",
	    "The wired memory of the GPU the whole host may hold, in bytes; "
	    "0 is no limit");
	SYSCTL_ADD_PROC(ctx, SYSCTL_CHILDREN(parent), OID_AUTO,
	    "gpu_wired_refused", CTLTYPE_LONG | CTLFLAG_RD | CTLFLAG_DYN, NULL, 0,
	    nvga_sysctl_wired_refused, "L",
	    "The number of GPU allocations that were refused");
	SYSCTL_ADD_PROC(ctx, SYSCTL_CHILDREN(parent), OID_AUTO,
	    "gpu_wired_uids", CTLTYPE_STRING | CTLFLAG_RD | CTLFLAG_DYN, NULL, 0,
	    nvga_sysctl_uids, "A",
	    "The wired memory of the GPU per user and per jail, in bytes");
}

/*
 * nvga_sysctl_exit - the state is gone with the node.
 */
void
nvga_sysctl_exit(void)
{
	mtx_lock(&nvga_mtx);
	nvga_rules.njails = 0;
	mtx_unlock(&nvga_mtx);
}

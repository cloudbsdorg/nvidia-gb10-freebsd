/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-3-Clause
 *
 * gpu_access_harness.c - runs the REAL GPU access check and the REAL wired
 * memory accounting (src/gb10-gpu-access/nvga_glue.c, or a mutant of it)
 * in userland against fakes of the kernel (tests/data/nvga_fakes.h).
 *
 * The state is read the way a user reads it: through the sysctls the glue
 * registered.  One scenario per run, so every scenario starts with a clean
 * state.
 *
 * Run: gpu_access_harness <scenario>
 * Exit 0 only when the scenario holds.
 */
#include "nvga_fakes.h"

#undef malloc
#undef free

#include "nvga_glue.h"

/* ---- the shared state of the fakes ---- */

uint64_t nvga_fake_racct_uid_bytes;
uint64_t nvga_fake_racct_jail_bytes;
uint64_t nvga_fake_racct_limit;
int nvga_fake_racct_add_calls;
int nvga_fake_racct_sub_calls;
int nvga_fake_gid = -1;
struct thread nvga_fake_thread;
struct proc nvga_fake_proc;
struct devclass *nvidia_devclass;
struct nvga_fake_sysctl nvga_fake_sysctls[NVGA_FAKE_SYSCTL_MAX];
int nvga_fake_nsysctls;
size_t nvga_fake_out_len;
int nvga_fake_mtx_held;
int nvga_fake_malloc_under_lock;

int
nvga_fake_sysctl_add(const char *name, int type,
    int (*handler)(struct sysctl_oid *, void *, intmax_t,
    struct sysctl_req *))
{
	if (nvga_fake_nsysctls >= NVGA_FAKE_SYSCTL_MAX)
		return (-1);
	nvga_fake_sysctls[nvga_fake_nsysctls].name = name;
	nvga_fake_sysctls[nvga_fake_nsysctls].type = type;
	nvga_fake_sysctls[nvga_fake_nsysctls].handler = handler;
	nvga_fake_nsysctls++;
	return (0);
}

int
nvga_fake_out(struct sysctl_req *req, const void *buf, size_t len)
{
	if (req->oldbuf == NULL)
		return (0);
	if (req->oldlen - req->oldidx < len)
		return (EINVAL);
	memcpy(req->oldbuf + req->oldidx, buf, len);
	req->oldidx += len;
	nvga_fake_out_len = len;
	return (0);
}

int
nvga_fake_in(struct sysctl_req *req, void *buf, size_t len)
{
	size_t have;

	if (req->newbuf == NULL)
		return (EINVAL);
	have = req->newlen - req->newidx;
	if (have > len)
		have = len;
	memcpy(buf, req->newbuf + req->newidx, have);
	req->newidx += have;
	return (0);
}

int
nvga_fake_tunable(const char *path, int *var)
{
	(void)path;
	if (nvga_fake_gid >= 0)
		*var = nvga_fake_gid;
	return (0);
}

/* ---- the scenarios ---- */

static int fails;

#define	CHECK(c, ...) do { if (!(c)) { fails++; printf("FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

static struct device dev0, dev1;
static struct nv_state nv0, nv1;
static struct nvidia_softc sc0, sc1;
static struct devclass dc;
static struct ucred cred_plain, cred_group, cred_jail, cred_jailroot;
static struct prison jail3, jail4;

/* the sysctls, read and written the way a user does */
static int
sysctl_handler(const char *name)
{
	int i;

	for (i = 0; i < nvga_fake_nsysctls; i++) {
		if (strcmp(nvga_fake_sysctls[i].name, name) == 0)
			return (i);
	}
	return (-1);
}

static int64_t
sysctl_read_int(const char *name, int width)
{
	char buf[1024];
	struct sysctl_req req;
	int64_t value = 0;
	int32_t v32;
	int i, real_width;

	i = sysctl_handler(name);
	if (i < 0)
		return (-1);
	/*
	 * The value is read with the width the sysctl was registered with:
	 * a 32-bit sysctl that holds a byte count is cut at 2 GiB, and the
	 * harness must see that.
	 */
	real_width = ((nvga_fake_sysctls[i].type & CTLTYPE_MASK) == CTLTYPE_LONG) ?
	    8 : 4;
	if (real_width != width) {
		fails++;
		printf("FAIL %s: the width of %s is %d, not %d\n",
		    __FILE__, name, real_width, width);
	}
	memset(&req, 0, sizeof(req));
	memset(buf, 0, sizeof(buf));
	req.oldbuf = buf;
	req.oldlen = sizeof(buf);
	nvga_fake_sysctls[i].handler(NULL, NULL, 0, &req);
	if (real_width == 8)
		memcpy(&value, buf, sizeof(int64_t));
	else {
		memcpy(&v32, buf, sizeof(int32_t));
		value = v32;
	}
	return (value);
}

static int
sysctl_write_int(const char *name, int64_t value)
{
	char buf[1024];
	struct sysctl_req req;
	int i;

	i = sysctl_handler(name);
	if (i < 0)
		return (EINVAL);
	memset(&req, 0, sizeof(req));
	memset(buf, 0, sizeof(buf));
	memcpy(buf, &value, sizeof(value));
	req.newbuf = buf;
	req.newlen = sizeof(value);
	req.newidx = 0;
	req.newptr = (void *)1;
	return (nvga_fake_sysctls[i].handler(NULL, NULL, 0, &req));
}

static int
sysctl_write_string(const char *name, const char *s)
{
	char buf[1024];
	struct sysctl_req req;
	int i;

	i = sysctl_handler(name);
	if (i < 0)
		return (EINVAL);
	memset(&req, 0, sizeof(req));
	memset(buf, 0, sizeof(buf));
	memcpy(buf, s, strlen(s));
	req.newbuf = buf;
	req.newlen = strlen(s);
	req.newidx = 0;
	req.newptr = (void *)1;
	return (nvga_fake_sysctls[i].handler(NULL, NULL, 0, &req));
}

static int
sysctl_read_string(const char *name, char *out, size_t len)
{
	struct sysctl_req req;
	int i;

	i = sysctl_handler(name);
	if (i < 0)
		return (EINVAL);
	memset(&req, 0, sizeof(req));
	memset(out, 0, len);
	req.oldbuf = out;
	req.oldlen = len;
	nvga_fake_out_len = 0;
	return (nvga_fake_sysctls[i].handler(NULL, NULL, 0, &req));
}

static void
setup(void)
{
	memset(&dc, 0, sizeof(dc));
	dev0.unit = 0;
	dev1.unit = 1;
	nv0.gpu_id = 0xC1D00000;
	nv1.gpu_id = 0xC1D00001;
	sc0.dev = &dev0;
	sc0.nv_state = &nv0;
	sc1.dev = &dev1;
	sc1.nv_state = &nv1;
	dc.dc_nunits = 2;
	dc.softc[0] = &sc0;
	dc.softc[1] = &sc1;
	nvidia_devclass = &dc;

	memset(&cred_plain, 0, sizeof(cred_plain));
	cred_plain.cr_uid = 1000;
	cred_plain.cr_ruid = 1000;
	cred_plain.cr_gid = 1000;

	memset(&cred_group, 0, sizeof(cred_group));
	cred_group.cr_uid = 1001;
	cred_group.cr_ruid = 1001;
	cred_group.cr_gid = 1000;
	cred_group.cr_ngroups = 1;
	cred_group.cr_groups[0] = GID_VIDEO;

	memset(&cred_jail, 0, sizeof(cred_jail));
	jail3.pr_id = 3;
	cred_jail.cr_uid = 1002;
	cred_jail.cr_ruid = 1002;
	cred_jail.cr_gid = 1002;
	cred_jail.cr_ngroups = 1;
	cred_jail.cr_groups[0] = GID_VIDEO;
	cred_jail.cr_prison = &jail3;

	memset(&cred_jailroot, 0, sizeof(cred_jailroot));
	jail4.pr_id = 4;
	cred_jailroot.cr_uid = 0;
	cred_jailroot.cr_ruid = 0;
	cred_jailroot.cr_gid = 0;
	cred_jailroot.cr_prison = &jail4;

	nvga_fake_thread.td_ucred = &cred_group;
	nvga_fake_racct_uid_bytes = 0;
	nvga_fake_racct_jail_bytes = 0;
	nvga_fake_racct_limit = UINT64_MAX;
	nvga_fake_racct_add_calls = 0;
	nvga_fake_racct_sub_calls = 0;
	nvga_fake_gid = -1;
	nvga_fake_mtx_held = 0;
	nvga_fake_malloc_under_lock = 0;

	nvga_init();
	nvga_sysctl_init(NULL, NULL);
}

static void
scenario_access(void)
{
	/* a user in the group may attach a GPU */
	nvga_fake_thread.td_ucred = &cred_group;
	CHECK(nvga_check_attach(0xC1D00000) == 0, "a user in the group may attach a GPU");
	CHECK(nvga_check_attach(0xC1D00001) == 0, "a user in the group may attach the second GPU");

	/* a user without access may not */
	nvga_fake_thread.td_ucred = &cred_plain;
	CHECK(nvga_check_attach(0xC1D00000) == EPERM, "a user outside the group is refused");
	CHECK(nvga_check_attach(0xC1D00001) == EPERM, "a user outside the group is refused the second GPU too");

	/* the host root may */
	nvga_fake_thread.td_ucred = &(struct ucred){ .cr_uid = 0, .cr_ruid = 0 };
	CHECK(nvga_check_attach(0xC1D00000) == 0, "the host root may attach a GPU");

	/* a GPU that is not there is refused: no unit, no right to prove */
	CHECK(nvga_check_attach(0xDEAD0000) == EPERM, "a GPU that is not there is refused");

	/* the refusals are counted, and the state shows it */
	CHECK(sysctl_read_int("gpu_access", 4) == 1, "the access check is in force");
	CHECK(sysctl_read_int("gpu_access_group", 4) == GID_VIDEO,
	    "the group that owns the nodes is shown");
	CHECK(sysctl_read_int("gpu_access_denied", 8) == 3,
	    "the refused attaches are counted (%lld)",
	    (long long)sysctl_read_int("gpu_access_denied", 8));
}

static void
scenario_jail(void)
{
	char buf[1024];

	/* a jail is granted nothing by default */
	nvga_fake_thread.td_ucred = &cred_jail;
	CHECK(nvga_check_attach(0xC1D00000) == EPERM, "a jail with no grant is refused");

	/* the grant is set the way the sysctl sets it */
	CHECK(sysctl_write_string("gpu_access_jails", "3:0") == 0, "the jail grant is accepted");
	nvga_fake_thread.td_ucred = &cred_jail;
	CHECK(nvga_check_attach(0xC1D00000) == 0, "the jail may attach the GPU it was granted");
	CHECK(nvga_check_attach(0xC1D00001) == EPERM, "the jail may not attach another GPU");

	/* the grant is shown */
	CHECK(sysctl_read_string("gpu_access_jails", buf, sizeof(buf)) == 0 &&
	    strcmp(buf, "3:0") == 0, "the grant in force is shown (%s)", buf);

	/* a malformed grant is refused whole: the grants in force stay */
	CHECK(sysctl_write_string("gpu_access_jails", "3:x") != 0, "a malformed grant is refused");
	nvga_fake_thread.td_ucred = &cred_jail;
	CHECK(nvga_check_attach(0xC1D00000) == 0, "the grant in force survives a malformed one");

	/* the jailed root is not the host root */
	nvga_fake_thread.td_ucred = &cred_jailroot;
	CHECK(nvga_check_attach(0xC1D00000) == EPERM, "the jailed root is not the host root");

	/* a second jail is a second grant */
	CHECK(sysctl_write_string("gpu_access_jails", "3:0;5:1") == 0, "two jail grants are accepted");
	nvga_fake_thread.td_ucred = &cred_jail;
	CHECK(nvga_check_attach(0xC1D00000) == 0, "the first jail keeps its grant");
	CHECK(nvga_check_attach(0xC1D00001) == EPERM, "the first jail is not granted the second GPU");

	/* "all" grants every unit */
	CHECK(sysctl_write_string("gpu_access_jails", "4:all") == 0, "an all grant is accepted");
	nvga_fake_thread.td_ucred = &cred_jailroot;
	CHECK(nvga_check_attach(0xC1D00000) == 0, "the all grant covers the first GPU");
	CHECK(nvga_check_attach(0xC1D00001) == 0, "the all grant covers the second GPU");
}

static void
scenario_wired(void)
{
	char buf[1024];

	/* an allocation is charged to the uid */
	nvga_fake_thread.td_ucred = &cred_group;
	CHECK(nvga_wired_alloc(512, 1024, (void *)0x1000) == 0, "the first allocation is charged");
	CHECK(sysctl_read_int("gpu_wired_bytes", 8) == 512 * 1024,
	    "the host total holds the charge (%lld)",
	    (long long)sysctl_read_int("gpu_wired_bytes", 8));
	CHECK(sysctl_read_string("gpu_wired_uids", buf, sizeof(buf)) == 0 &&
	    strstr(buf, "u1001:524288") != NULL, "the uid total is shown (%s)", buf);
	CHECK(nvga_fake_racct_add_calls == 1, "the kernel's accounting was charged once (%d)",
	    nvga_fake_racct_add_calls);
	CHECK(nvga_fake_racct_uid_bytes == 512 * 1024, "the uid container holds the charge (%llu)",
	    (unsigned long long)nvga_fake_racct_uid_bytes);

	/* a second allocation adds up */
	CHECK(nvga_wired_alloc(256, 1024, (void *)0x2000) == 0, "the second allocation is charged");
	CHECK(sysctl_read_int("gpu_wired_bytes", 8) == 768 * 1024,
	    "the host total holds both charges (%lld)",
	    (long long)sysctl_read_int("gpu_wired_bytes", 8));

	/* a size that does not fit is refused (no limit is in force yet) */
	CHECK(nvga_wired_alloc(UINT64_MAX, 2, (void *)0xb000) == ENOMEM,
	    "an allocation whose size does not fit is refused");
	CHECK(sysctl_read_int("gpu_wired_bytes", 8) == 768 * 1024,
	    "a refused size charges nothing");

	/* over the limit of one credential: refused, and nothing is charged */
	CHECK(sysctl_write_int("gpu_wired_limit", 1024 * 1024) == 0, "the limit is set");
	CHECK(nvga_wired_alloc(512, 1024, (void *)0x3000) == ENOMEM,
	    "an allocation over the limit is refused");
	CHECK(sysctl_read_int("gpu_wired_bytes", 8) == 768 * 1024,
	    "a refused allocation charges nothing");
	CHECK(nvga_fake_racct_add_calls == 2, "a refused allocation does not charge the kernel (%d)",
	    nvga_fake_racct_add_calls);
	CHECK(sysctl_read_int("gpu_wired_refused", 8) == 1, "the refused allocations are counted (%lld)",
	    (long long)sysctl_read_int("gpu_wired_refused", 8));

	/* the memory comes back */
	nvga_wired_free((void *)0x1000);
	CHECK(sysctl_read_int("gpu_wired_bytes", 8) == 256 * 1024,
	    "the host total falls when the memory comes back (%lld)",
	    (long long)sysctl_read_int("gpu_wired_bytes", 8));
	CHECK(nvga_fake_racct_sub_calls == 1, "the kernel's accounting was credited back once (%d)",
	    nvga_fake_racct_sub_calls);
	CHECK(nvga_fake_racct_uid_bytes == 256 * 1024, "the uid container holds what is left (%llu)",
	    (unsigned long long)nvga_fake_racct_uid_bytes);

	/* a memory that was never charged changes nothing */
	nvga_wired_free((void *)0x9999);
	CHECK(sysctl_read_int("gpu_wired_bytes", 8) == 256 * 1024, "an uncharged memory changes nothing");
	CHECK(nvga_fake_racct_sub_calls == 1, "an uncharged memory credits nothing back");

	/* the host's own limit */
	CHECK(sysctl_write_int("gpu_wired_limit", 0) == 0, "the limit of one user is taken away");
	CHECK(sysctl_write_int("gpu_wired_total_limit", 1024 * 1024) == 0, "the host limit is set");
	CHECK(nvga_wired_alloc(256, 1024, (void *)0x8000) == 0,
	    "an allocation under the host limit is charged");
	CHECK(nvga_wired_alloc(1024, 1024, (void *)0x9000) == ENOMEM,
	    "an allocation over the host limit is refused");

	/* a limit set under the total that is already held */
	CHECK(sysctl_write_int("gpu_wired_total_limit", 0) == 0, "the host limit is taken away");
	CHECK(sysctl_write_int("gpu_wired_limit", 1024) == 0, "a limit under the total is set");
	CHECK(nvga_wired_alloc(1, 1024, (void *)0xa000) == ENOMEM,
	    "an allocation is refused when the total already stands over the limit");
}

static void
scenario_wired_jail(void)
{
	char buf[1024];
	struct ucred plain, other;

	/* the charge of a jail is the jail's own */
	nvga_fake_thread.td_ucred = &cred_jail;
	CHECK(nvga_wired_alloc(1024, 1024, (void *)0x4000) == 0, "the jail's allocation is charged");
	CHECK(nvga_fake_racct_jail_bytes == 1024 * 1024, "the jail container holds the charge (%llu)",
	    (unsigned long long)nvga_fake_racct_jail_bytes);
	CHECK(nvga_fake_racct_uid_bytes == 0, "the uid container does not hold the jail's charge");
	CHECK(sysctl_read_string("gpu_wired_uids", buf, sizeof(buf)) == 0 &&
	    strstr(buf, "j3:1048576") != NULL, "the jail total is shown (%s)", buf);

	/* the jail's limit is the jail's own */
	CHECK(sysctl_write_int("gpu_wired_limit", 2 * 1024 * 1024) == 0, "the limit is set");
	CHECK(nvga_wired_alloc(2048, 1024, (void *)0x5000) == ENOMEM,
	    "the jail's allocation over the limit is refused");
	nvga_wired_free((void *)0x4000);
	CHECK(sysctl_read_int("gpu_wired_bytes", 8) == 0, "the jail's charge comes back (%lld)",
	    (long long)sysctl_read_int("gpu_wired_bytes", 8));

	/*
	 * The limit of one user holds inside a jail too: the limit is about
	 * the user, and what the user holds outside the jail is the user's
	 * own memory as well.
	 */
	memset(&plain, 0, sizeof(plain));
	plain.cr_uid = cred_jail.cr_uid;
	plain.cr_ruid = cred_jail.cr_ruid;
	nvga_fake_thread.td_ucred = &plain;
	CHECK(nvga_wired_alloc(512, 1024, (void *)0x6000) == 0,
	    "the user's own allocation is charged");
	nvga_fake_thread.td_ucred = &cred_jail;
	CHECK(sysctl_write_int("gpu_wired_limit", 768 * 1024) == 0,
	    "the limit of one user is set");
	CHECK(nvga_wired_alloc(512, 1024, (void *)0x7000) == ENOMEM,
	    "the limit of the user holds inside a jail too");
	nvga_wired_free((void *)0x6000);
	/* the charge of the refused allocation, if the rule let it through */
	nvga_wired_free((void *)0x7000);

	/*
	 * The limit of one jail holds as well: two users of one jail may
	 * not hold between them more than the limit, even when neither of
	 * them is over it on its own.
	 */
	memset(&other, 0, sizeof(other));
	other.cr_uid = 1003;
	other.cr_ruid = 1003;
	other.cr_prison = &jail3;
	CHECK(sysctl_write_int("gpu_wired_limit", 1024 * 1024) == 0,
	    "the limit is set again");
	nvga_fake_thread.td_ucred = &cred_jail;
	CHECK(nvga_wired_alloc(600, 1024, (void *)0x8000) == 0,
	    "the first user of the jail is charged");
	nvga_fake_thread.td_ucred = &other;
	CHECK(nvga_wired_alloc(512, 1024, (void *)0x9000) == ENOMEM,
	    "the second user of the jail is refused: the jail holds enough");
	nvga_fake_thread.td_ucred = &cred_jail;
	nvga_wired_free((void *)0x8000);
	CHECK(sysctl_write_int("gpu_wired_limit", 0) == 0, "the limit is taken away");
}

static void
scenario_rctl(void)
{
	/* the rctl cap is honoured */
	nvga_fake_racct_limit = 1024 * 1024;
	nvga_fake_thread.td_ucred = &cred_group;
	CHECK(nvga_wired_alloc(512, 1024, (void *)0x6000) == 0, "the first allocation is under the rctl cap");
	CHECK(nvga_wired_alloc(1024, 1024, (void *)0x7000) == ENOMEM,
	    "an allocation over the rctl cap is refused");
	nvga_fake_racct_limit = UINT64_MAX;
}

static void
scenario_nodes(void)
{
	/* the nodes are 0660 and owned by the group */
	CHECK(nvga_device_mode() == 0660, "the nodes are 0660 (%o)", (unsigned)nvga_device_mode());
	CHECK(nvga_device_gid() == GID_VIDEO, "the nodes are owned by the video group by default (%u)",
	    (unsigned)nvga_device_gid());
	nvga_fake_gid = 1234;
	CHECK(nvga_device_gid() == 1234, "the tunable moves the group (%u)",
	    (unsigned)nvga_device_gid());
	nvga_fake_gid = -1;
}

static void
scenario_kernel(void)
{
	/* a thread of the kernel has no credential: the driver's own work */
	nvga_fake_thread.td_ucred = NULL;
	CHECK(nvga_check_attach(0xC1D00000) == 0, "the driver's own work may attach a GPU");
	CHECK(nvga_wired_alloc(64, 1024, (void *)0xc000) == 0, "the driver's own memory is charged");
	CHECK(sysctl_read_int("gpu_wired_bytes", 8) == 64 * 1024,
	    "the system's charge is held (%lld)",
	    (long long)sysctl_read_int("gpu_wired_bytes", 8));
	CHECK(nvga_fake_racct_add_calls == 0,
	    "a charge with no credential does not touch the kernel's containers");
	nvga_wired_free((void *)0xc000);
	CHECK(sysctl_read_int("gpu_wired_bytes", 8) == 0, "the system's charge comes back");

	/* a user's limit does not hold the driver's own work */
	CHECK(sysctl_write_int("gpu_wired_limit", 1024) == 0, "a limit is set");
	nvga_fake_thread.td_ucred = NULL;
	CHECK(nvga_wired_alloc(64, 1024, (void *)0xc100) == 0,
	    "the driver's own memory is not held by a user's limit");
	nvga_wired_free((void *)0xc100);
	CHECK(sysctl_write_int("gpu_wired_limit", 0) == 0, "the limit is taken away");

	/* but the host's own limit does */
	CHECK(sysctl_write_int("gpu_wired_total_limit", 1024) == 0,
	    "the host limit is set");
	nvga_fake_thread.td_ucred = NULL;
	CHECK(nvga_wired_alloc(64, 1024, (void *)0xc200) == ENOMEM,
	    "the driver's own memory is held by the host's limit");
	CHECK(sysctl_write_int("gpu_wired_total_limit", 0) == 0,
	    "the host limit is taken away");
}

/*
 * scenario_bigbytes - the byte count is not cut at 2 GiB.  The wired memory
 * of the GPU is larger than that on a board with this much RAM, so a count
 * that fits in 32 bits would show the wrong number.
 */
static void
scenario_bigbytes(void)
{
	nvga_fake_thread.td_ucred = &cred_group;
	CHECK(nvga_wired_alloc(3 * 1024 * 1024, 1024, (void *)0xd000) == 0,
	    "a charge of more than 2 GiB is taken");
	CHECK(sysctl_read_int("gpu_wired_bytes", 8) == 3LL * 1024 * 1024 * 1024,
	    "the byte count holds more than 2 GiB (%lld)",
	    (long long)sysctl_read_int("gpu_wired_bytes", 8));
	nvga_wired_free((void *)0xd000);
	CHECK(sysctl_read_int("gpu_wired_bytes", 8) == 0, "the big charge comes back");
}

/*
 * scenario_format - the two string sysctls must hand over the whole
 * string they hold.
 *
 * The grants of sixteen jails, each of them every unit, and the list of a
 * hundred users that hold some of the memory of the GPU, are both longer
 * than a page.  A read that cuts the string short would be a lie twice
 * over: the reader would see a grant that is not there, and a read
 * followed by a write would drop the grants that did not fit.  A read that
 * hands over more bytes than the string holds has read past the end of
 * its own buffer, which is worse.
 */
static void
scenario_format(void)
{
	char buf[16384];
	char grants[512];
	struct ucred c;
	int i, n, off;

	/*
	 * The fit check itself: a buffer that is too small takes nothing,
	 * and nothing is written past the end of it.
	 */
	{
		char small[8];
		size_t soff;
		int full = 0;

		memset(small, 'x', sizeof(small));
		soff = nvga_fmt_add(small, sizeof(small), 0, &full, "abc");
		CHECK(soff == 3 && !full, "the text that fits is added");
		soff = nvga_fmt_add(small, sizeof(small), soff, &full, "de");
		CHECK(soff == 5 && !full, "the text that fits is added too");
		soff = nvga_fmt_add(small, sizeof(small), soff, &full, "fghi");
		CHECK(full == 1 && soff == 5,
		    "the text that does not fit is not added (%d, %zu)", full, soff);
		CHECK(strcmp(small, "abcde") == 0, "the string is whole (%s)", small);
		CHECK(small[6] == 'x' && small[7] == 'x',
		    "nothing was written past the end of the buffer");
	}

	off = 0;
	grants[0] = '\0';
	for (i = 1; i <= NVGA_MAX_JAILS; i++) {
		n = snprintf(grants + off, sizeof(grants) - (size_t)off,
		    "%s%d:all", i > 1 ? ";" : "", i);
		CHECK(n > 0 && (size_t)n < sizeof(grants) - (size_t)off,
		    "the grant of jail %d is built", i);
		if (n <= 0)
			break;
		off += n;
	}
	CHECK(sysctl_write_string("gpu_access_jails", grants) == 0,
	    "the grants of every jail are accepted");

	CHECK(sysctl_read_string("gpu_access_jails", buf, sizeof(buf)) == 0,
	    "the grants are read");
	CHECK(nvga_fake_out_len == strlen(buf) + 1,
	    "the read handed over exactly the string (%zu bytes, %zu in it)",
	    nvga_fake_out_len, strlen(buf) + 1);
	CHECK(strlen(buf) > 1024,
	    "the whole form of the grants came back (%zu bytes)", strlen(buf));
	CHECK(strstr(buf, ";") != NULL, "the grants are in the string");

	/* many users hold some of the memory of the GPU */
	for (i = 0; i < 100; i++) {
		memset(&c, 0, sizeof(c));
		c.cr_uid = 2000 + i;
		c.cr_ruid = 2000 + i;
		nvga_fake_thread.td_ucred = &c;
		CHECK(nvga_wired_alloc(1, 4096,
		    (void *)(uintptr_t)(0x10000 + i)) == 0,
		    "the allocation of user %d is charged", 2000 + i);
	}
	nvga_fake_thread.td_ucred = &cred_group;
	CHECK(sysctl_read_string("gpu_wired_uids", buf, sizeof(buf)) == 0,
	    "the list of the users is read");
	CHECK(nvga_fake_out_len == strlen(buf) + 1,
	    "the read handed over exactly the list (%zu bytes, %zu in it)",
	    nvga_fake_out_len, strlen(buf) + 1);
	CHECK(strlen(buf) > 1024,
	    "the whole list came back (%zu bytes)", strlen(buf));
}

int
main(int argc, char **argv)
{
	const char *name;

	if (argc < 2) {
		printf("usage: %s <scenario>\n", argv[0]);
		return (2);
	}
	name = argv[1];
	setup();
	if (strcmp(name, "access") == 0)
		scenario_access();
	else if (strcmp(name, "jail") == 0)
		scenario_jail();
	else if (strcmp(name, "wired") == 0)
		scenario_wired();
	else if (strcmp(name, "wired-jail") == 0)
		scenario_wired_jail();
	else if (strcmp(name, "rctl") == 0)
		scenario_rctl();
	else if (strcmp(name, "nodes") == 0)
		scenario_nodes();
	else if (strcmp(name, "kernel") == 0)
		scenario_kernel();
	else if (strcmp(name, "bigbytes") == 0)
		scenario_bigbytes();
	else if (strcmp(name, "format") == 0)
		scenario_format();
	else {
		printf("unknown scenario %s\n", name);
		return (2);
	}

	/*
	 * An allocation that can wait sleeps, and a thread that sleeps while
	 * it holds a mutex panics the kernel.  Nothing may be allocated while
	 * the driver's lock is held.
	 */
	CHECK(nvga_fake_malloc_under_lock == 0,
	    "%d allocation(s) were made while the lock was held",
	    nvga_fake_malloc_under_lock);
	CHECK(nvga_fake_mtx_held == 0, "the lock was not released (%d)",
	    nvga_fake_mtx_held);

	if (fails != 0) {
		printf("FAIL %d check(s) in %s\n", fails, name);
		return (1);
	}
	printf("ok %s\n", name);
	return (0);
}

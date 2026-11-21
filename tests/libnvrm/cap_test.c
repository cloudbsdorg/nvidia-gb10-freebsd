/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * cap_test.c - libnvrm works in Capsicum capability mode after enumeration.
 * Each case runs in a child process: enumerate, cap_enter(), then query
 * again through the descriptors the library already holds.  Cases:
 *   fake    the fake backend: queries are real ioctls on a library-owned
 *           descriptor; the rights and the ioctl allow list are checked, with
 *           a control showing capability mode alone does not forbid the
 *           ioctl the allow list refuses;
 *   rm      the RM backend over the scripted kernel with a real descriptor:
 *           the RM escapes get through the allow list in capability mode, an
 *           ioctl outside the list is refused (ENOTCAPABLE), and a new
 *           enumeration is impossible (open fails with ECAPMODE).
 * The child's exit status carries the verdict.
 */
#include <sys/param.h>
#include <sys/capsicum.h>
#include <sys/filio.h>
#include <sys/ioctl.h>
#include <sys/wait.h>

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <nvtypes.h>
#include <nvstatus.h>
#include <nvmisc.h>
#include <nvos.h>
#include <nv-ioctl.h>
#include <nv_escape.h>
#include <class/cl0000.h>
#include <class/cl0080.h>
#include <class/cl2080.h>
#include <ctrl/ctrl0000/ctrl0000gpu.h>
#include <ctrl/ctrl0080/ctrl0080gpu.h>
#include <ctrl/ctrl2080/ctrl2080bus.h>
#include <ctrl/ctrl2080/ctrl2080fb.h>
#include <ctrl/ctrl2080/ctrl2080gpu.h>
#include <ctrl/ctrl2080/ctrl2080gr.h>
#include <ctrl/ctrl2080/ctrl2080mc.h>

#include "nvrm_internal.h"
#include "nvrm_fake.h"
#include "nvrm_rm_sys.h"
#include "t.h"

#include "fault_calloc.h"

#include "scripted_rm.h"

static void
fake_case(void)
{
	nvrm_ctx *ctx;
	nvrm_enum_opts o = { "fake" };
	char err[200];
	cap_rights_t have;
	const nvrm_device_info *i;
	int fd, n, ctl_before;

	setenv("NVRM_FAKE_PROFILE", "discrete", 1);
	CHECK_EQ(nvrm_enumerate(&ctx, &o, err, sizeof(err)), NVRM_OK);
	fd = nvrm_fake_fd();
	CHECK(fd >= 0);
	/* the descriptor's rights: ioctl, mmap and event only */
	CHECK_EQ(cap_rights_get(fd, &have), 0);
	CHECK(cap_rights_is_set(&have, CAP_IOCTL));
	CHECK(cap_rights_is_set(&have, CAP_MMAP_RW));
	CHECK(cap_rights_is_set(&have, CAP_EVENT));
	CHECK(!cap_rights_is_set(&have, CAP_FCHMOD));	/* controls */
	CHECK(!cap_rights_is_set(&have, CAP_BIND));
	CHECK(!cap_rights_is_set(&have, CAP_CONNECT));

	/* the control: a plain pipe in capability mode may FIONBIO */
	{
		int pp[2], on = 1;

		CHECK_EQ(pipe(pp), 0);
		ctl_before = pp[0];
		CHECK_EQ(ioctl(ctl_before, FIONBIO, &on), 0);
		close(pp[1]);
	}
	CHECK_EQ(cap_enter(), 0);
	/* the control: capability mode alone does not refuse that ioctl */
	n = 1;
	CHECK_EQ(ioctl(ctl_before, FIONBIO, &n), 0);

	/* capability mode: no new descriptors */
	CHECK_EQ(open("/dev/null", O_RDWR), -1);
	CHECK_EQ(errno, ECAPMODE);
	/* the library's descriptor: an ioctl off the allow list is refused ... */
	n = 1;
	CHECK_EQ(ioctl(fd, FIONBIO, &n), -1);
	CHECK_EQ(errno, ENOTCAPABLE);
	/* ... and the one on it works */
	CHECK_EQ(ioctl(fd, FIONREAD, &n), 0);
	/* and the library keeps answering: refresh reads through it */
	CHECK_EQ(nvrm_device_refresh(nvrm_device_get(ctx, 0)), NVRM_OK);
	i = nvrm_device_info_get(nvrm_device_get(ctx, 0));
	CHECK(NVRM_HAVE(i->sm_count));
	CHECK_EQ(i->sm_count.value, 36);
	CHECK(NVRM_HAVE(i->uuid));
	CHECK(NVRM_HAVE(i->classes));
}

static void
rm_case(void)
{
	nvrm_ctx *ctx;
	nvrm_enum_opts o = { "rm" };
	char err[200];
	const nvrm_device_info *i;
	int rc;

	reset_kernel();
	K.use_pipe = 1;
	K.real_first = 1;
	nvrm_rm_set_sys(&scripted);
	rc = nvrm_enumerate(&ctx, &o, err, sizeof(err));
	CHECK_EQ(rc, NVRM_OK);
	if (rc != NVRM_OK) {
		printf("  enumerate: %s (real errno %d)\n", err, K.real_errno);
		return;
	}
	CHECK_EQ(K.bad, 0);
	CHECK_EQ(cap_enter(), 0);
	/* a refresh in capability mode: all controls pass the allow list */
	K.real_errno = 0;
	CHECK_EQ(nvrm_device_refresh(nvrm_device_get(ctx, 0)), NVRM_OK);
	CHECK_EQ(K.real_errno, 0);
	i = nvrm_device_info_get(nvrm_device_get(ctx, 0));
	CHECK(NVRM_HAVE(i->architecture));
	CHECK(NVRM_HAVE(i->sm_count));
	CHECK_EQ(i->sm_count.value, 36);
	CHECK(NVRM_HAVE(i->uuid));
	CHECK(NVRM_HAVE(i->classes));
	/* the OS-layer values were cached before capability mode */
	CHECK(NVRM_HAVE(i->pci_vendor));
	CHECK(NVRM_HAVE(i->caps[6]));
	/* an escape that is not on the list is refused by the kernel */
	{
		int fdn = K.last_fd;
		nv_ioctl_card_info_t ci[NV_MAX_DEVICES];
		nv_ioctl_xfer_t x;

		CHECK(fdn >= 0);
		memset(&x, 0, sizeof(x));
		x.cmd = NV_ESC_CARD_INFO;
		x.size = sizeof(ci);
		x.ptr = NV_PTR_TO_NvP64(ci);
		CHECK_EQ(ioctl(fdn, _IOWR(NV_IOCTL_MAGIC, NV_ESC_IOCTL_XFER_CMD,
		    nv_ioctl_xfer_t), &x), -1);
		CHECK_EQ(errno, ENOTCAPABLE);
	}
	/* with the full list the allocation escape reaches the driver (a pipe
	 * answers ENOTTY once the allow list let it through) */
	{
		NVOS21_PARAMETERS ap;

		memset(&ap, 0, sizeof(ap));
		CHECK_EQ(ioctl(K.last_fd, _IOWR(NV_IOCTL_MAGIC, NV_ESC_RM_ALLOC,
		    NVOS21_PARAMETERS), &ap), -1);
		CHECK_EQ(errno, ENOTTY);
	}
	/* a new enumeration cannot open the control device: the real open
	 * is refused in capability mode, and the library says so */
	nvrm_rm_set_sys(NULL);
	CHECK_EQ(nvrm_enumerate(&ctx, &o, err, sizeof(err)), NVRM_E_OPEN);
	CHECK(strstr(err, "capability mode") != NULL);
}

/* A query-only enumeration keeps only the RM controls and frees and no
 * mapping right: the allocation escape is refused after cap_enter. */
static void
query_only_cases(void)
{
	nvrm_ctx *ctx;
	nvrm_enum_opts o = { "rm", 1 };
	char err[200];
	cap_rights_t have;
	NVOS21_PARAMETERS ap;
	NVOS54_PARAMETERS cp;
	const nvrm_device_info *i;

	reset_kernel();
	K.use_pipe = 1;
	K.real_first = 1;
	nvrm_rm_set_sys(&scripted);
	CHECK_EQ(nvrm_enumerate(&ctx, &o, err, sizeof(err)), NVRM_OK);
	CHECK_EQ(cap_rights_get(K.last_fd, &have), 0);
	CHECK(cap_rights_is_set(&have, CAP_IOCTL));
	CHECK(!cap_rights_is_set(&have, CAP_MMAP_RW));	/* no mapping */
	CHECK_EQ(cap_enter(), 0);
	memset(&ap, 0, sizeof(ap));
	CHECK_EQ(ioctl(K.last_fd, _IOWR(NV_IOCTL_MAGIC, NV_ESC_RM_ALLOC,
	    NVOS21_PARAMETERS), &ap), -1);
	CHECK_EQ(errno, ENOTCAPABLE);			/* no allocation */
	memset(&cp, 0, sizeof(cp));
	CHECK_EQ(ioctl(K.last_fd, _IOWR(NV_IOCTL_MAGIC, NV_ESC_RM_CONTROL,
	    NVOS54_PARAMETERS), &cp), -1);
	CHECK_EQ(errno, ENOTTY);			/* controls pass */
	K.real_errno = 0;
	CHECK_EQ(nvrm_device_refresh(nvrm_device_get(ctx, 0)), NVRM_OK);
	CHECK_EQ(K.real_errno, 0);
	i = nvrm_device_info_get(nvrm_device_get(ctx, 0));
	CHECK(NVRM_HAVE(i->sm_count));
	nvrm_rm_set_sys(NULL);
}

static void
fake_query_only(void)
{
	nvrm_ctx *ctx;
	nvrm_enum_opts o = { "fake", 1 };
	char err[200];
	cap_rights_t have;

	setenv("NVRM_FAKE_PROFILE", "discrete", 1);
	CHECK_EQ(nvrm_enumerate(&ctx, &o, err, sizeof(err)), NVRM_OK);
	CHECK_EQ(cap_rights_get(nvrm_fake_fd(), &have), 0);
	CHECK(cap_rights_is_set(&have, CAP_IOCTL));
	CHECK(!cap_rights_is_set(&have, CAP_MMAP_RW));
	CHECK_EQ(cap_enter(), 0);
	CHECK_EQ(nvrm_device_refresh(nvrm_device_get(ctx, 0)), NVRM_OK);
}

static int
run_child(const char *name, void (*fn)(void))
{
	pid_t pid;
	int st;

	fflush(stdout);
	pid = fork();
	if (pid == 0) {
		fn();
		t_done(name);
		_exit(t_fails == 0 ? 0 : 1);
	}
	waitpid(pid, &st, 0);
	return (WIFEXITED(st) && WEXITSTATUS(st) == 0 ? 0 : 1);
}

int
main(void)
{
	int bad = 0;

	setvbuf(stdout, NULL, _IOLBF, 0);
	bad += run_child("cap_test fake", fake_case);
	bad += run_child("cap_test rm", rm_case);
	bad += run_child("cap_test rm query-only", query_only_cases);
	bad += run_child("cap_test fake query-only", fake_query_only);
	printf("cap_test: %s\n", bad == 0 ? "all passed" : "FAILED");
	return (bad == 0 ? 0 : 1);
}

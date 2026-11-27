/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-3-Clause
 *
 * node_ioctl_test.c - the RM escape ioctls over a real device node: the
 * daemon publishes /dev/nvidiactl with cuse(3) and this program opens it
 * and asks it the questions a client asks, with the real ioctl(2).
 *
 * This is the path the in-process tests cannot take: the node is a device,
 * the ioctl is a system call and the answer comes from the model that the
 * daemon was started with.
 *
 * What CUSE can carry: the argument of the ioctl is copied into the shared
 * window, so the ioctls whose argument holds no pointer are answered
 * (the version check of the RM).  The ioctls whose argument names the
 * client's address space (the card list, the control parameters) are
 * refused with EINVAL: the daemon says it cannot carry them instead of
 * answering with a wrong answer.  The seam shim answers them in the
 * client's own process.
 *
 * usage: node_ioctl_test [control-node]
 *   The control node is /dev/nvidiactl by default; the name comes from the
 *   argument when the mock publishes its nodes under another prefix.
 */
#include <sys/param.h>
#include <sys/ioctl.h>

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
#include <ctrl/ctrl0000/ctrl0000gpu.h>

static int failures;

#define CHECK(cond, ...)						\
	do {								\
		if (!(cond)) {						\
			failures++;					\
			printf("FAIL %s:%d: ", __FILE__, __LINE__);	\
			printf(__VA_ARGS__);				\
			printf("\n");					\
		}							\
	} while (0)

#define IOC_CHECK_VERSION	_IOWR(NV_IOCTL_MAGIC, NV_ESC_CHECK_VERSION_STR, \
				    nv_ioctl_rm_api_version_t)
#define IOC_XFER		_IOWR(NV_IOCTL_MAGIC, NV_ESC_IOCTL_XFER_CMD, \
				    nv_ioctl_xfer_t)
#define IOC_RM_CONTROL		_IOWR(NV_IOCTL_MAGIC, NV_ESC_RM_CONTROL, \
				    NVOS54_PARAMETERS)
/* The attach ioctl: the number of GPUs is the size of its argument. */
#define IOC_ATTACH		_IOWR(NV_IOCTL_MAGIC, NV_ESC_ATTACH_GPUS_TO_FD, \
				    uint32_t)
#define IOC_ATTACH_MANY		_IOWR(NV_IOCTL_MAGIC, NV_ESC_ATTACH_GPUS_TO_FD, \
				    uint32_t[1024])
/* A command the RM does not know, and one whose argument does not fit the
 * window the mechanism carries. */
#define IOC_UNKNOWN		_IOWR(NV_IOCTL_MAGIC, NV_IOCTL_BASE + 100, \
				    uint32_t)
#define IOC_TOO_LONG		_IOWR(NV_IOCTL_MAGIC, NV_IOCTL_BASE + 101, \
				    uint32_t[4095])

/*
 * The version query, again: the daemon that is alive and sane answers it.
 * Every check below sends a command the RM does not want and then asks
 * this: a daemon that died, or that was corrupted by the command, does
 * not answer.
 */
static int
still_answers(int fd)
{
	nv_ioctl_rm_api_version_t v;

	memset(&v, 0, sizeof(v));
	v.cmd = NV_RM_API_VERSION_CMD_QUERY;
	if (ioctl(fd, IOC_CHECK_VERSION, &v) != 0)
		return (0);
	return (v.reply == NV_RM_API_VERSION_REPLY_RECOGNIZED &&
	    strcmp(v.versionString, "580.178.04") == 0);
}

int
main(int argc, char **argv)
{
	nv_ioctl_rm_api_version_t v;
	nv_ioctl_xfer_t xfer;
	NVOS54_PARAMETERS p;
	NV0000_CTRL_GPU_GET_PROBED_IDS_PARAMS probed;
	const char *node = argc > 1 ? argv[1] : "/dev/nvidiactl";
	int fd;

	fd = open(node, O_RDWR);
	CHECK(fd >= 0, "cannot open %s: %s", node, strerror(errno));
	if (fd < 0)
		return (1);
	/* The version check: the RM of the model answers. */
	memset(&v, 0, sizeof(v));
	v.cmd = NV_RM_API_VERSION_CMD_QUERY;
	CHECK(ioctl(fd, IOC_CHECK_VERSION, &v) == 0, "the version query "
	    "failed: %s", strerror(errno));
	CHECK(v.reply == NV_RM_API_VERSION_REPLY_RECOGNIZED, "the RM does "
	    "not recognize the version query");
	CHECK(strcmp(v.versionString, "580.178.04") == 0, "the RM reports "
	    "the version \"%s\", the model says \"580.178.04\"",
	    v.versionString);
	/* The strict check: the RM the library speaks. */
	memset(&v, 0, sizeof(v));
	v.cmd = NV_RM_API_VERSION_CMD_STRICT;
	snprintf(v.versionString, sizeof(v.versionString), "%s", "580.178.04");
	CHECK(ioctl(fd, IOC_CHECK_VERSION, &v) == 0, "the strict version "
	    "check failed: %s", strerror(errno));
	CHECK(v.reply == NV_RM_API_VERSION_REPLY_RECOGNIZED, "the RM does "
	    "not recognize the strict version check");
	/* The card list: the argument names the client's address space, and
	 * CUSE carries the argument alone.  The daemon says so. */
	memset(&xfer, 0, sizeof(xfer));
	xfer.cmd = NV_ESC_CARD_INFO;
	xfer.size = sizeof(nv_ioctl_card_info_t) * NV_MAX_DEVICES;
	xfer.ptr = (NvP64)(uintptr_t)&xfer;
	errno = 0;
	CHECK(ioctl(fd, IOC_XFER, &xfer) != 0, "the card list must be "
	    "refused over CUSE");
	CHECK(errno == EINVAL, "the card list was refused with %s, the "
	    "daemon must say EINVAL", strerror(errno));
	/* The control: the parameters name the client's address space. */
	memset(&p, 0, sizeof(p));
	p.cmd = NV0000_CTRL_CMD_GPU_GET_PROBED_IDS;
	p.params = (NvP64)(uintptr_t)&probed;
	p.paramsSize = sizeof(probed);
	errno = 0;
	CHECK(ioctl(fd, IOC_RM_CONTROL, &p) != 0, "the control must be "
	    "refused over CUSE");
	CHECK(errno == EINVAL, "the control was refused with %s, the daemon "
	    "must say EINVAL", strerror(errno));
	/*
	 * What a client may send that the RM does not want.
	 *
	 * One GPU: the RM attaches it and answers.
	 */
	{
		uint32_t id = 1;

		errno = 0;
		CHECK(ioctl(fd, IOC_ATTACH, &id) == 0, "the attach of one GPU "
		    "must be answered: %s", strerror(errno));
	}
	/*
	 * More GPUs than the RM can attach: the RM refuses it, and the
	 * list of the attached GPUs is never written past its end.
	 */
	{
		uint32_t ids[1024];

		memset(ids, 0, sizeof(ids));
		errno = 0;
		CHECK(ioctl(fd, IOC_ATTACH_MANY, ids) != 0, "the attach of "
		    "more GPUs than the RM can hold must be refused");
		CHECK(errno == EINVAL, "the attach of too many GPUs was "
		    "refused with %s, the RM must say EINVAL",
		    strerror(errno));
	}
	/* A command the RM does not know: it fails, it does not answer. */
	{
		uint32_t arg[4];

		memset(arg, 0, sizeof(arg));
		errno = 0;
		CHECK(ioctl(fd, IOC_UNKNOWN, arg) != 0, "a command the RM "
		    "does not know must be refused");
		CHECK(errno == ENXIO, "a command the RM does not know was "
		    "refused with %s: the mechanism has no ENOTTY, so the "
		    "client sees ENXIO", strerror(errno));
	}
	/* An argument that does not fit the window: the kernel refuses it
	 * before the daemon sees it. */
	{
		static uint32_t big[4095];

		memset(big, 0, sizeof(big));
		errno = 0;
		CHECK(ioctl(fd, IOC_TOO_LONG, big) != 0, "an argument that "
		    "does not fit the window must be refused");
		CHECK(errno == ENOMEM, "an argument that does not fit the "
		    "window was refused with %s, the window is 4096 bytes",
		    strerror(errno));
	}
	/* The daemon is still there after all of it. */
	CHECK(still_answers(fd), "the daemon does not answer the version "
	    "after the commands it does not want");
	close(fd);
	if (failures == 0)
		printf("ok node_ioctl_test\n");
	return (failures == 0 ? 0 : 1);
}

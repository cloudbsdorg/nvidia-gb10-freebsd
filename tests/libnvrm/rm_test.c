/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * rm_test.c - tests of the RM backend against a scripted kernel: a stand-in
 * for /dev/nvidiactl that implements the RM escapes with NVIDIA's own
 * structures, checks every request (ioctl number, object handle and class,
 * parameter size, field values) and answers from a table shaped like the
 * RTX 5060 Ti (values as read from pciconf).  It proves the
 * marshalling and the call order without a driver; the live proof is
 * nvrm-info on the real driver.  Every error path of the backend is driven by making
 * the scripted kernel fail that one step.
 */
#include <sys/param.h>
#include <sys/ioctl.h>
#include <sys/filio.h>

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
#include "nvrm_rm_sys.h"
#include "t.h"

#include "fault_calloc.h"

#include "scripted_rm.h"

static nvrm_ctx *
enum_rm(int *rc, char *err, size_t errlen)
{
	nvrm_enum_opts o = { "rm" };
	nvrm_ctx *ctx;

	*rc = nvrm_enumerate(&ctx, &o, err, errlen);
	return (ctx);
}

static const nvrm_device_info *
info0(nvrm_ctx *ctx)
{
	if (ctx == NULL) {
		printf("fatal: enumerate failed\n");
		exit(1);
	}
	return (nvrm_device_info_get(nvrm_device_get(ctx, 0)));
}

/* ---- tests -------------------------------------------------------------- */

static void
test_happy(void)
{
	nvrm_ctx *ctx;
	const nvrm_device_info *i;
	char err[300];
	int rc;

	reset_kernel();
	ctx = enum_rm(&rc, err, sizeof(err));
	CHECK_EQ(rc, NVRM_OK);
	if (rc != NVRM_OK)
		printf("  enumerate: %s (kernel: %s)\n", err, K.badmsg);
	CHECK(ctx != NULL);
	CHECK_EQ(K.bad, 0);
	if (K.bad)
		printf("  kernel refused: %s\n", K.badmsg);
	CHECK(K.saw_version && K.saw_card && K.saw_attach_fd && K.saw_client);
	CHECK_EQ(K.cmds_seen[0], 1);		/* ATTACH_IDS once */
	i = info0(ctx);
	CHECK_EQ(i->pci_vendor.value, 0x10de);
	CHECK_EQ(i->pci_device.value, 0x2d04);
	CHECK_EQ(i->pci_bus.value, 13);
	CHECK(!NVRM_HAVE(i->pci_function));	/* the OS layer does not say */
	CHECK_EQ(i->pci_function.reason, NVRM_R_OS_NOT_REPORTED);
	CHECK_EQ(i->pci_subsystem_vendor.value, 0x1462);
	CHECK_EQ(i->pci_subsystem_device.value, 0x5351);
	CHECK_EQ(i->pci_revision.value, 0xa1);
	CHECK_EQ(i->rm_gpu_id.value, 0x0d00);
	CHECK_STR(i->uuid.value, "GPU-11111111-2222-4333-8444-555555555555");
	CHECK_EQ(i->chip_id.value, 0x1b6);
	CHECK_EQ(i->sm_version_major.value, 12);
	CHECK_EQ(i->sm_version_minor.value, 0);
	CHECK_EQ(i->gpc_count.value, 3);
	CHECK_EQ(i->tpc_count.value, 18);
	CHECK_EQ(i->sm_count.value, 36);
	CHECK_EQ(i->vram_size.value, 16ULL << 30);	/* KiB -> bytes */
	CHECK_EQ(i->bar1_size.value, 8ULL << 30);
	CHECK_EQ(i->max_page_size.value, 512ULL << 20);
	CHECK_EQ(i->numa_node.reason, NVRM_R_NO_NUMA);
	CHECK_STR(i->family.value, "blackwell-b");
	CHECK_EQ(i->classes.count, 3);
	CHECK(i->caps[0].value == 1 && NVRM_HAVE(i->caps[0]));
	CHECK(i->caps[1].value == 0 && NVRM_HAVE(i->caps[1]));
	CHECK(i->caps[3].value == 1);
	CHECK(NVRM_HAVE(i->caps[4]) && i->caps[4].value == 0);	/* soc */
	CHECK(NVRM_HAVE(i->caps[5]) && i->caps[5].value == 0);
	CHECK(NVRM_HAVE(i->caps[6]) && i->caps[6].value == 1);
	CHECK(i->caps[6].source == NVRM_S_OS);
	CHECK(strstr(nvrm_rm_running_version(ctx)->value, NVRM_RM_VERSION));
	/* refresh queries again; every object is freed at close */
	CHECK_EQ(nvrm_device_refresh(nvrm_device_get(ctx, 0)), NVRM_OK);
	CHECK_EQ(K.bad, 0);
	nvrm_close(ctx);
	CHECK_EQ(K.nlive, 0);			/* nothing leaked in the RM */
	CHECK_EQ(K.nalloc, K.nfree);
	CHECK_EQ(K.bad, 0);

	/* a unified-memory part: NUMA node, SoC and coherent memory flags */
	reset_kernel();
	K.numa = 3;
	K.soc = 1;
	ctx = enum_rm(&rc, err, sizeof(err));
	CHECK_EQ(rc, NVRM_OK);
	i = info0(ctx);
	CHECK(NVRM_HAVE(i->numa_node));
	CHECK_EQ(i->numa_node.value, 3);
	CHECK(i->caps[4].value == 1 && i->caps[5].value == 1);
	nvrm_close(ctx);

	/* two GPUs; one has no card record (the OS layer lost it) */
	reset_kernel();
	K.ngpus = 2;
	K.have_card[1] = 0;
	ctx = enum_rm(&rc, err, sizeof(err));
	CHECK_EQ(rc, NVRM_OK);
	CHECK_EQ(nvrm_device_count(ctx), 2);
	CHECK(!NVRM_HAVE(nvrm_device_info_get(nvrm_device_get(ctx, 1))->pci_bus));
	CHECK_EQ(nvrm_device_info_get(nvrm_device_get(ctx, 1))->pci_bus.reason,
	    NVRM_R_OS_NOT_REPORTED);
	CHECK(NVRM_HAVE(nvrm_device_info_get(nvrm_device_get(ctx, 0))->pci_bus));
	/* with no card record there is nothing to check the PCI id layout
	 * against, so the subsystem ids are withheld too */
	CHECK(!NVRM_HAVE(nvrm_device_info_get(nvrm_device_get(ctx, 1))->pci_subsystem_vendor));
	CHECK(NVRM_HAVE(nvrm_device_info_get(nvrm_device_get(ctx, 0))->pci_subsystem_vendor));
	nvrm_close(ctx);
	CHECK_EQ(K.nlive, 0);
	CHECK_EQ(K.bad, 0);
}

static void
test_open_failures(void)
{
	nvrm_ctx *ctx;
	char err[300];
	int rc;

	reset_kernel();
	K.fail_open = 1;
	ctx = enum_rm(&rc, err, sizeof(err));
	CHECK_EQ(rc, NVRM_E_OPEN);
	CHECK(ctx == NULL && strstr(err, "/dev/nvidiactl") != NULL);

	/* a kernel module of another RM version: refused, and says which */
	reset_kernel();
	K.version = "580.99.01";
	ctx = enum_rm(&rc, err, sizeof(err));
	CHECK_EQ(rc, NVRM_E_VERSION);
	CHECK(strstr(err, "580.99.01") != NULL);
	CHECK(strstr(err, "built for RM " NVRM_RM_VERSION) != NULL);
	CHECK(strstr(err, "refuses to run") != NULL);
	CHECK_EQ(K.nalloc, 0);			/* nothing past the check */
	/* control: the same module version is accepted */
	reset_kernel();
	ctx = enum_rm(&rc, err, sizeof(err));
	CHECK_EQ(rc, NVRM_OK);
	nvrm_close(ctx);
	/* the module cannot be asked for its version: the message says so */
	reset_kernel();
	K.version = "other";
	K.fn_ver = 0;
	ctx = enum_rm(&rc, err, sizeof(err));
	CHECK_EQ(rc, NVRM_E_VERSION);
	CHECK(strstr(err, "unknown (hw.nvidia.version") != NULL);
	CHECK(strstr(err, "\"no version\"") == NULL);
	CHECK(strstr(err, "install the " NVRM_RM_VERSION) != NULL);

	/* the version ioctl itself fails: an I/O error, not a mismatch */
	reset_kernel();
	K.fail_ioctl_nr = NV_ESC_CHECK_VERSION_STR;
	ctx = enum_rm(&rc, err, sizeof(err));
	CHECK_EQ(rc, NVRM_E_IO);
	CHECK(strstr(err, "version check") != NULL);
	CHECK(strstr(err, "does not match") == NULL);
	CHECK_EQ(K.nalloc, 0);

	/* the ioctl succeeds but the module does not recognise the request */
	reset_kernel();
	K.reply_unrecognized = 1;
	ctx = enum_rm(&rc, err, sizeof(err));
	CHECK_EQ(rc, NVRM_E_VERSION);
	CHECK_EQ(K.nalloc, 0);

	/* the RM client cannot be allocated */
	reset_kernel();
	K.fail_alloc_class = NV01_ROOT;
	ctx = enum_rm(&rc, err, sizeof(err));
	CHECK_EQ(rc, NVRM_E_IO);
	CHECK(strstr(err, "RM client") != NULL);
}

static void
test_list_failures(void)
{
	nvrm_ctx *ctx;
	char err[300];
	int rc;

	reset_kernel();
	K.fail_ioctl_nr = NV_ESC_IOCTL_XFER_CMD;
	ctx = enum_rm(&rc, err, sizeof(err));
	CHECK_EQ(rc, NVRM_E_IO);
	CHECK(strstr(err, "NV_ESC_CARD_INFO") != NULL);
	CHECK_EQ(K.nlive, 0);

	/* the OS layer has no GPU: the core says so */
	reset_kernel();
	K.ngpus = 0;
	ctx = enum_rm(&rc, err, sizeof(err));
	CHECK_EQ(rc, NVRM_E_NODEV);
	CHECK_EQ(K.nlive, 0);

	reset_kernel();
	K.fail_ioctl_nr = NV_ESC_ATTACH_GPUS_TO_FD;
	ctx = enum_rm(&rc, err, sizeof(err));
	CHECK_EQ(rc, NVRM_E_IO);
	CHECK(strstr(err, "ATTACH_GPUS_TO_FD") != NULL);

	reset_kernel();
	K.fail_probed = 1;
	ctx = enum_rm(&rc, err, sizeof(err));
	CHECK_EQ(rc, NVRM_E_IO);
	CHECK(strstr(err, "GET_PROBED_IDS") != NULL);

	reset_kernel();
	K.fail_ctl_cmd = NV0000_CTRL_CMD_GPU_ATTACH_IDS;
	K.fail_ctl_status = NV_ERR_GENERIC;
	ctx = enum_rm(&rc, err, sizeof(err));
	CHECK_EQ(rc, NVRM_E_IO);
	CHECK(strstr(err, "ATTACH_IDS") != NULL);
	CHECK_EQ(K.nlive, 0);
}

static void
test_gpu_failures(void)
{
	nvrm_ctx *ctx;
	char err[300];
	int rc;

	reset_kernel();
	K.fail_ctl_cmd = NV0000_CTRL_CMD_GPU_GET_ID_INFO_V2;
	K.fail_ctl_status = NV_ERR_GENERIC;
	ctx = enum_rm(&rc, err, sizeof(err));
	CHECK_EQ(rc, NVRM_E_IO);
	CHECK(strstr(err, "GET_ID_INFO_V2") != NULL);
	CHECK_EQ(K.nlive, 0);

	reset_kernel();
	K.fail_alloc_class = NV01_DEVICE_0;
	ctx = enum_rm(&rc, err, sizeof(err));
	CHECK_EQ(rc, NVRM_E_IO);
	CHECK(strstr(err, "NV01_DEVICE_0") != NULL);
	CHECK_EQ(K.nlive, 0);

	/* a failed subdevice frees the device it hung from */
	reset_kernel();
	K.fail_alloc_class = NV20_SUBDEVICE_0;
	ctx = enum_rm(&rc, err, sizeof(err));
	CHECK_EQ(rc, NVRM_E_IO);
	CHECK(strstr(err, "NV20_SUBDEVICE_0") != NULL);
	CHECK_EQ(K.nlive, 0);
	CHECK_EQ(K.bad, 0);
}

/* #lizard forgives -- one block per RM control that can fail, kept flat on purpose */
static void
test_property_failures(void)
{
	nvrm_ctx *ctx;
	const nvrm_device_info *i;
	char err[300];
	int rc;

	/* each RM control that fails makes only its own values unavailable;
	 * "not supported" and "failed" are told apart */
	reset_kernel();
	K.fail_ctl_cmd = NV2080_CTRL_CMD_BUS_GET_PCI_INFO;
	K.fail_ctl_status = NV_ERR_NOT_SUPPORTED;
	ctx = enum_rm(&rc, err, sizeof(err));
	i = info0(ctx);
	CHECK(!NVRM_HAVE(i->pci_subsystem_vendor));
	CHECK_EQ(i->pci_subsystem_vendor.reason, NVRM_R_RM_UNSUPPORTED);
	CHECK(NVRM_HAVE(i->pci_vendor));		/* OS layer value is fine */
	nvrm_close(ctx);

	reset_kernel();
	K.fail_ctl_cmd = NV2080_CTRL_CMD_MC_GET_ARCH_INFO;
	K.fail_ctl_status = NV_ERR_GENERIC;
	ctx = enum_rm(&rc, err, sizeof(err));
	i = info0(ctx);
	CHECK_EQ(i->architecture.reason, NVRM_R_RM_FAILED);
	CHECK_EQ(i->chip_id.reason, NVRM_R_INPUT_MISSING);
	nvrm_close(ctx);

	reset_kernel();
	K.fail_ctl_cmd = NV2080_CTRL_CMD_GR_GET_INFO_V2;
	K.fail_ctl_status = NV_ERR_GENERIC;
	ctx = enum_rm(&rc, err, sizeof(err));
	i = info0(ctx);
	CHECK(!NVRM_HAVE(i->sm_version_major) && !NVRM_HAVE(i->sm_count));
	nvrm_close(ctx);

	reset_kernel();
	K.fail_ctl_cmd = NV2080_CTRL_CMD_GR_GET_GPC_MASK;
	K.fail_ctl_status = NV_ERR_GENERIC;
	ctx = enum_rm(&rc, err, sizeof(err));
	CHECK(!NVRM_HAVE(info0(ctx)->gpc_count));
	nvrm_close(ctx);

	reset_kernel();
	K.fail_ctl_cmd = NV2080_CTRL_CMD_GR_GET_TPC_MASK;
	K.fail_ctl_status = NV_ERR_GENERIC;
	ctx = enum_rm(&rc, err, sizeof(err));
	CHECK(!NVRM_HAVE(info0(ctx)->tpc_count));
	nvrm_close(ctx);

	reset_kernel();
	K.fail_ctl_cmd = NV2080_CTRL_CMD_FB_GET_INFO_V2;
	K.fail_ctl_status = NV_ERR_GENERIC;
	ctx = enum_rm(&rc, err, sizeof(err));
	CHECK(!NVRM_HAVE(info0(ctx)->vram_size));
	CHECK(!NVRM_HAVE(info0(ctx)->bar1_size));
	nvrm_close(ctx);

	reset_kernel();
	K.fail_ctl_cmd = NV2080_CTRL_CMD_GPU_GET_MAX_SUPPORTED_PAGE_SIZE;
	K.fail_ctl_status = NV_ERR_NOT_SUPPORTED;
	ctx = enum_rm(&rc, err, sizeof(err));
	CHECK(!NVRM_HAVE(info0(ctx)->max_page_size));
	CHECK(!NVRM_HAVE(info0(ctx)->page_sizes));
	nvrm_close(ctx);

	reset_kernel();
	K.fail_ctl_cmd = NV2080_CTRL_CMD_GPU_GET_GID_INFO;
	K.fail_ctl_status = NV_ERR_GENERIC;
	ctx = enum_rm(&rc, err, sizeof(err));
	CHECK(!NVRM_HAVE(info0(ctx)->uuid));
	CHECK_STR(info0(ctx)->uuid.value, "");
	nvrm_close(ctx);

	reset_kernel();
	K.fail_ctl_cmd = NV0080_CTRL_CMD_GPU_GET_CLASSLIST_V2;
	K.fail_ctl_status = NV_ERR_GENERIC;
	ctx = enum_rm(&rc, err, sizeof(err));
	CHECK(!NVRM_HAVE(info0(ctx)->classes));
	CHECK(!NVRM_HAVE(info0(ctx)->family));
	nvrm_close(ctx);

	/* the PCI id layout is not the assumed one: the subsystem ids are
	 * withheld instead of being reported swapped */
	reset_kernel();
	K.swap_pci = 1;
	ctx = enum_rm(&rc, err, sizeof(err));
	i = info0(ctx);
	CHECK(!NVRM_HAVE(i->pci_subsystem_vendor));
	CHECK(!NVRM_HAVE(i->pci_subsystem_device));
	CHECK(!NVRM_HAVE(i->pci_revision));
	CHECK(NVRM_HAVE(i->pci_vendor));
	nvrm_close(ctx);

	/* only the vendor half of pciDeviceId disagrees with the card list */
	reset_kernel();
	K.bad_pci_vendor = 1;
	ctx = enum_rm(&rc, err, sizeof(err));
	CHECK(!NVRM_HAVE(info0(ctx)->pci_subsystem_vendor));
	nvrm_close(ctx);

	/* only the device half of pciDeviceId disagrees with the card list */
	reset_kernel();
	K.bad_pci_device = 1;
	ctx = enum_rm(&rc, err, sizeof(err));
	CHECK(!NVRM_HAVE(info0(ctx)->pci_subsystem_vendor));
	nvrm_close(ctx);

	/* a class list longer than the buffer is cut */
	reset_kernel();
	K.classes_over = 1;
	ctx = enum_rm(&rc, err, sizeof(err));
	CHECK_EQ(info0(ctx)->classes.count, 200);
	nvrm_close(ctx);

	/* one rejected GPU info index loses one flag, not the others */
	reset_kernel();
	K.gpu_info_fail_index = NV2080_CTRL_GPU_INFO_INDEX_GPU_ATS_CAPABILITY;
	ctx = enum_rm(&rc, err, sizeof(err));
	i = info0(ctx);
	CHECK(!NVRM_HAVE(i->caps[1]));
	CHECK_EQ(i->caps[1].reason, NVRM_R_RM_UNSUPPORTED);
	CHECK(NVRM_HAVE(i->caps[0]) && NVRM_HAVE(i->caps[2]));
	nvrm_close(ctx);

	/* coherent memory mode rejected */
	reset_kernel();
	K.gpu_info_fail_index = NV2080_CTRL_GPU_INFO_INDEX_COHERENT_GPU_MEMORY_MODE;
	ctx = enum_rm(&rc, err, sizeof(err));
	CHECK(!NVRM_HAVE(info0(ctx)->caps[5]));
	nvrm_close(ctx);

	/* ID_INFO fails after attach (NUMA and SoC): both unavailable */
	reset_kernel();
	ctx = enum_rm(&rc, err, sizeof(err));
	K.fail_ctl_cmd = NV0000_CTRL_CMD_GPU_GET_ID_INFO_V2;
	K.fail_ctl_status = NV_ERR_GENERIC;
	nvrm_device_refresh(nvrm_device_get(ctx, 0));
	CHECK(!NVRM_HAVE(info0(ctx)->numa_node));
	CHECK_EQ(info0(ctx)->numa_node.reason, NVRM_R_RM_FAILED);
	CHECK(!NVRM_HAVE(info0(ctx)->caps[4]));
	nvrm_close(ctx);

	/* the sysctl is missing or answers with the wrong length */
	reset_kernel();
	K.fn_wc = -1;
	ctx = enum_rm(&rc, err, sizeof(err));
	CHECK_EQ(info0(ctx)->caps[6].reason, NVRM_R_OS_NOT_REPORTED);
	nvrm_close(ctx);
	reset_kernel();
	K.fn_wc_short = 1;
	ctx = enum_rm(&rc, err, sizeof(err));
	CHECK_EQ(info0(ctx)->caps[6].reason, NVRM_R_OS_NOT_REPORTED);
	nvrm_close(ctx);
	reset_kernel();
	K.fn_wc = 0;
	ctx = enum_rm(&rc, err, sizeof(err));
	CHECK(NVRM_HAVE(info0(ctx)->caps[6]) && info0(ctx)->caps[6].value == 0);
	nvrm_close(ctx);

	/* an ioctl that fails outright is a failed system call, not an RM
	 * error, and a refresh says so */
	reset_kernel();
	ctx = enum_rm(&rc, err, sizeof(err));
	K.fail_ioctl_nr = NV_ESC_RM_CONTROL;
	CHECK_EQ(nvrm_device_refresh(nvrm_device_get(ctx, 0)), NVRM_E_IO);
	CHECK(!NVRM_HAVE(info0(ctx)->architecture));
	CHECK_EQ(info0(ctx)->architecture.reason, NVRM_R_OS_CALL_FAILED);
	CHECK_EQ(nvrm_device_refresh(nvrm_device_get(ctx, 0)), NVRM_E_IO);
	K.fail_ioctl_nr = -1;
	nvrm_close(ctx);
	CHECK_EQ(K.nlive, 0);
	CHECK_EQ(K.bad, 0);
}

static void
test_alloc_and_real_calls(void)
{
	const nvrm_backend_ops *o = &nvrm_backend_rm_ops;
	nvrm_backend *be;
	nvrm_gpu *g;
	nvrm_ctx *ctx;
	nvrm_enum_opts opt = { "rm" };
	char err[200], buf[64];
	uint32_t ids[1];
	unsigned n;
	size_t len;
	int fd;

	/* out of memory: the backend, then the GPU (the client is freed) */
	reset_kernel();
	calloc_calls = 0;
	calloc_fail_at = 2;			/* ctx is 1, the backend is 2 */
	CHECK_EQ(nvrm_enumerate(&ctx, &opt, err, sizeof(err)), NVRM_E_NOMEM);
	CHECK_EQ(K.nalloc, 0);
	calloc_calls = 0;
	calloc_fail_at = 3;			/* ... and the GPU is 3 */
	CHECK_EQ(nvrm_enumerate(&ctx, &opt, err, sizeof(err)), NVRM_E_NOMEM);
	CHECK_EQ(K.nlive, 0);
	calloc_fail_at = 0;

	/* ioctl errors on alloc and on free */
	reset_kernel();
	K.fail_ioctl_nr = NV_ESC_RM_ALLOC;
	CHECK_EQ(nvrm_enumerate(&ctx, &opt, err, sizeof(err)), NVRM_E_IO);
	reset_kernel();
	CHECK_EQ(nvrm_enumerate(&ctx, &opt, err, sizeof(err)), NVRM_OK);
	K.fail_ioctl_nr = NV_ESC_RM_FREE;
	nvrm_close(ctx);			/* frees fail; close still ends */
	CHECK(K.nlive > 0);

	/* the room limit on the probed list: two GPUs, room for one; the
	 * kernel accepts the prefix and sees no bad request */
	reset_kernel();
	K.ngpus = 2;
	CHECK_EQ(o->open(&be, err, sizeof(err)), NVRM_OK);
	CHECK_EQ(o->list_gpus(be, ids, 1, &n, err, sizeof(err)), NVRM_OK);
	CHECK_EQ(n, 1);
	CHECK_EQ(K.bad, 0);
	CHECK_EQ(o->gpu_open(be, ids[0], &g, err, sizeof(err)), NVRM_OK);
	o->gpu_close(g);
	o->close(be);

	/* the real system call wrappers, on harmless targets */
	fd = nvrm_rm_real_sys.open("/dev/null", O_RDWR);
	CHECK(fd >= 0);
	CHECK_EQ(nvrm_rm_real_sys.close(fd), 0);
	{
		int pp[2], avail;

		CHECK_EQ(pipe(pp), 0);
		CHECK_EQ(nvrm_rm_real_sys.ioctl(pp[0], FIONREAD, &avail), 0);
		nvrm_rm_real_sys.close(pp[0]);
		nvrm_rm_real_sys.close(pp[1]);
	}
	len = sizeof(buf);
	CHECK_EQ(nvrm_rm_real_sys.sysctlbyname("kern.ostype", buf, &len), 0);
	CHECK_STR(buf, "FreeBSD");
	CHECK_EQ(nvrm_rm_real_sys.access("/dev/null"), 0);
	CHECK(nvrm_rm_real_sys.access("/dev/no-such-device-nvrm") != 0);
}

static void
test_query_only(void)
{
	nvrm_enum_opts o = { "rm", 1 };
	nvrm_ctx *ctx;
	char err[200];

	reset_kernel();
	CHECK_EQ(nvrm_enumerate(&ctx, &o, err, sizeof(err)), NVRM_OK);
	CHECK_EQ(nvrm_device_refresh(nvrm_device_get(ctx, 0)), NVRM_OK);
	nvrm_close(ctx);
	CHECK_EQ(K.nlive, 0);
}

static void
test_misc(void)
{
	const nvrm_backend_ops *o = &nvrm_backend_rm_ops;
	nvrm_backend *be;
	nvrm_gpu *g;
	uint64_t v;
	char err[200];
	uint32_t id;
	unsigned n;

	reset_kernel();
	/* a property the backend does not know */
	CHECK_EQ(o->open(&be, err, sizeof(err)), NVRM_OK);
	CHECK_EQ(o->list_gpus(be, &id, 1, &n, err, sizeof(err)), NVRM_OK);
	CHECK_EQ(o->gpu_open(be, id, &g, err, sizeof(err)), NVRM_OK);
	CHECK_EQ(o->gpu_u64(g, NVRM_P_COUNT, 0, &v), NVRM_R_BACKEND_NONE);
	o->gpu_close(g);
	o->close(be);
	CHECK_EQ(K.nlive, 0);
	/* the caller's room limits the class list */
	reset_kernel();
	K.classes_over = 1;
	{
		uint32_t cl[2];

		CHECK_EQ(o->open(&be, err, sizeof(err)), NVRM_OK);
		CHECK_EQ(o->list_gpus(be, &id, 1, &n, err, sizeof(err)), NVRM_OK);
		CHECK_EQ(o->gpu_open(be, id, &g, err, sizeof(err)), NVRM_OK);
		CHECK_EQ(o->gpu_classes(g, cl, 2, &n), 0);
		CHECK_EQ(n, 2);
		o->gpu_close(g);
		o->close(be);
	}
	/* the probe follows the control device */
	CHECK_EQ(o->probe(), 1);
	/* NULL restores the real system calls */
	nvrm_rm_set_sys(NULL);
	CHECK_EQ(o->probe(), access("/dev/nvidiactl", F_OK) == 0);
	nvrm_rm_set_sys(&scripted);
}

int
main(void)
{
	setvbuf(stdout, NULL, _IOLBF, 0);
	nvrm_rm_set_sys(&scripted);
	test_happy();
	test_open_failures();
	test_list_failures();
	test_gpu_failures();
	test_property_failures();
	test_alloc_and_real_calls();
	test_query_only();
	test_misc();
	return (t_done("rm_test"));
}

/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * nvrm_rm.c - the RM backend: talks to the NVIDIA kernel module through
 * /dev/nvidiactl with the RM escape ioctls, and nothing else.  There is no
 * foreign-OS compatibility layer anywhere in this path.
 *
 * Every structure and constant comes from NVIDIA's open-gpu-kernel-modules
 * 580.178.04 (MIT): nvos.h, the class and control headers of
 * src/common/sdk/nvidia/inc and the OS-layer ioctl headers of
 * src/nvidia/arch/nvalloc/unix/include.
 *
 * Flow of nvrm_enumerate(): open the control device, NV_ESC_CHECK_VERSION_STR
 * (strict: the kernel module must be the RM this library was built for),
 * NV_ESC_CARD_INFO, NV_ESC_ATTACH_GPUS_TO_FD, allocate the RM client,
 * NV0000_CTRL_CMD_GPU_GET_PROBED_IDS and ..._ATTACH_IDS; per GPU: GET_ID_INFO_V2,
 * a device (NV01_DEVICE_0) and a subdevice (NV20_SUBDEVICE_0); then every
 * property is one RM control on the client, device or subdevice.
 *
 * The values only the OS layer knows (PCI location from the card list, the
 * hw.nvidia.* sysctls) are read once at attach and cached: sysctl and open are
 * not available once the process is in capability mode.
 */
#include <sys/param.h>
#include <sys/ioctl.h>
#include <sys/sysctl.h>

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
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
#include <class/cla06c.h>
#include <class/clca6f.h>
#include <class/clc96f.h>
#include <class/clcab5.h>
#include <class/clcdc0.h>
#include <class/clcd40.h>
#include <class/clcec0.h>
#include <class/clce97.h>
#include <class/clc761.h>
#include <class/cl902d.h>
#include <ctrl/ctrl0000/ctrl0000gpu.h>
#include <ctrl/ctrl0080/ctrl0080gpu.h>
#include <ctrl/ctrl2080/ctrl2080bios.h>
#include <ctrl/ctrl2080/ctrl2080bus.h>
#include <ctrl/ctrl2080/ctrl2080fb.h>
#include <ctrl/ctrl2080/ctrl2080gpu.h>
#include <ctrl/ctrl2080/ctrl2080gr.h>
#include <ctrl/ctrl2080/ctrl2080gsp.h>
#include <ctrl/ctrl2080/ctrl2080mc.h>

#include "nvrm_internal.h"
#include "nvrm_rm_sys.h"
#include "nvrm_rm_priv.h"

/* ---- system call table ------------------------------------------------- */

static int
real_open(const char *path, int flags)
{
	return (open(path, flags));
}

static int
real_close(int fd)
{
	return (close(fd));
}

static int
real_ioctl(int fd, unsigned long cmd, void *arg)
{
	return (ioctl(fd, cmd, arg));
}

static int
real_sysctlbyname(const char *name, void *old, size_t *oldlen)
{
	return (sysctlbyname(name, old, oldlen, NULL, 0));
}

static int
real_access(const char *path)
{
	return (access(path, F_OK));
}

const nvrm_rm_sys nvrm_rm_real_sys = {
	real_open, real_close, real_ioctl, real_sysctlbyname, real_access
};
static const nvrm_rm_sys *sys = &nvrm_rm_real_sys;

const nvrm_rm_sys *
nvrm_rm_get_sys(void)
{
	return (sys);
}

void
nvrm_rm_set_sys(const nvrm_rm_sys *s)
{
	sys = s != NULL ? s : &nvrm_rm_real_sys;
}

/* ---- RM calls ---------------------------------------------------------- */

/* Returns the RM status; a failed ioctl(2) is IOCTL_FAILED. */
NvU32
nvrm_rm_alloc(nvrm_backend *be, NvHandle parent, NvHandle *hnew, NvU32 cls,
    void *params, NvU32 size)
{
	NVOS21_PARAMETERS p;

	memset(&p, 0, sizeof(p));
	p.hRoot = parent == 0 ? 0 : be->client;
	p.hObjectParent = parent;
	p.hObjectNew = *hnew;
	p.hClass = cls;
	p.pAllocParms = NV_PTR_TO_NvP64(params);
	p.paramsSize = size;
	if (sys->ioctl(be->fd, IOC_RM_ALLOC, &p) != 0)
		return (IOCTL_FAILED);
	*hnew = p.hObjectNew;
	return (p.status);
}

NvU32
nvrm_rm_free(nvrm_backend *be, NvHandle parent, NvHandle obj)
{
	NVOS00_PARAMETERS p;

	memset(&p, 0, sizeof(p));
	p.hRoot = be->client;
	p.hObjectParent = parent;
	p.hObjectOld = obj;
	if (sys->ioctl(be->fd, IOC_RM_FREE, &p) != 0)
		return (IOCTL_FAILED);
	return (p.status);
}

NvU32
nvrm_rm_control(nvrm_backend *be, NvHandle obj, NvU32 cmd, void *params,
    NvU32 size)
{
	NVOS54_PARAMETERS p;

	memset(&p, 0, sizeof(p));
	p.hClient = be->client;
	p.hObject = obj;
	p.cmd = cmd;
	p.params = NV_PTR_TO_NvP64(params);
	p.paramsSize = size;
	if (sys->ioctl(be->fd, IOC_RM_CONTROL, &p) != 0)
		return (IOCTL_FAILED);
	return (p.status);
}

static int
status_reason(NvU32 st)
{
	if (st == IOCTL_FAILED)
		return (NVRM_R_OS_CALL_FAILED);
	return (st == NV_ERR_NOT_SUPPORTED ? NVRM_R_RM_UNSUPPORTED :
	    NVRM_R_RM_FAILED);
}

NvHandle
nvrm_rm_new_handle(nvrm_backend *be)
{
	return (HANDLE_BASE + be->next_handle++);
}

/* ---- backend ops ------------------------------------------------------- */

static int
rm_probe(void)
{
	return (sys->access(NVRM_CTL_PATH) == 0);
}

static int
read_int_sysctl(const char *name, int *value)
{
	size_t len = sizeof(*value);

	if (sys->sysctlbyname(name, value, &len) != 0)
		return (-1);
	return (len == sizeof(*value) ? 0 : -1);
}

static int
read_text_sysctl(const char *name, char *value, size_t size)
{
	size_t len = size;

	memset(value, 0, size);
	if (sys->sysctlbyname(name, value, &len) != 0)
		return (-1);
	value[size - 1] = '\0';
	return (0);
}

void
nvrm_rm_sync_running_version(nvrm_backend *be)
{
	int reason;

	be->running.source = NVRM_S_OS;
	snprintf(be->running.value, sizeof(be->running.value), "%s",
	    be->driver.string);
	if (be->driver.available) {
		be->running.reason = NVRM_R_NONE;
		return;
	}
	/* the driver version carries its reason as an id; the one helper maps it */
	reason = nvrm_reason_from_id(be->driver.reason);
	be->running.reason = reason > 0 ? reason : NVRM_R_OS_NOT_REPORTED;
}

/* Return 1 when the complete set of numeric version sysctls was read. */
static int
read_version_sysctls(nvrm_backend *be)
{
	char string[NVRM_VERSION_STRING_MAX + 1];
	char suffix[NVRM_VERSION_SUFFIX_MAX + 1];
	int major, minor, patch, available;
	int ok;

	ok = read_text_sysctl("hw.nvidia.version_string", string,
	    sizeof(string)) == 0;
	if (read_int_sysctl("hw.nvidia.version_major", &major) != 0)
		ok = 0;
	if (read_int_sysctl("hw.nvidia.version_minor", &minor) != 0)
		ok = 0;
	if (read_int_sysctl("hw.nvidia.version_patch", &patch) != 0)
		ok = 0;
	if (read_text_sysctl("hw.nvidia.version_suffix", suffix,
	    sizeof(suffix)) != 0)
		ok = 0;
	if (read_int_sysctl("hw.nvidia.version_available", &available) != 0)
		ok = 0;
	if (!ok)
		return (0);
	if (!available) {
		memset(&be->driver, 0, sizeof(be->driver));
		snprintf(be->driver.string, sizeof(be->driver.string), "%s", string);
		snprintf(be->driver.suffix, sizeof(be->driver.suffix), "%s", suffix);
		be->driver.reason = nvrm_reason_id(NVRM_R_VERSION_UNPARSED);
		return (1);
	}
	if (nvrm_version_parse(string, 10, &be->driver) != 0)
		return (1);
	if ((uint32_t)major != be->driver.parts[0] ||
	    (uint32_t)minor != be->driver.parts[1] ||
	    (uint32_t)patch != be->driver.parts[2] ||
	    strcmp(be->driver.suffix, suffix) != 0) {
		(void)nvrm_version__unparsed(&be->driver);
		be->driver.reason =
		    nvrm_reason_id(NVRM_R_VERSION_INCONSISTENT);
	}
	return (1);
}

static void
read_banner_version(nvrm_backend *be)
{
	char banner[64 * 1024];
	size_t len = 0;

	memset(&be->driver, 0, sizeof(be->driver));
	if (sys->sysctlbyname(NVRM_SYSCTL_VERSION, NULL, &len) != 0) {
		be->driver.reason = nvrm_reason_id(NVRM_R_OS_NOT_REPORTED);
		return;
	}
	if (len == 0 || len > sizeof(banner)) {
		be->driver.reason = nvrm_reason_id(NVRM_R_VERSION_UNPARSED);
		return;
	}
	if (read_text_sysctl(NVRM_SYSCTL_VERSION, banner, len) != 0) {
		be->driver.reason = nvrm_reason_id(NVRM_R_OS_NOT_REPORTED);
		return;
	}
	if (nvrm_version_find(banner, &be->driver) != 0)
		be->driver.reason = nvrm_reason_id(NVRM_R_VERSION_UNPARSED);
}

static void
read_sysctls(nvrm_backend *be)
{
	int wc;

	if (read_version_sysctls(be)) {
		nvrm_rm_sync_running_version(be);
	} else {
		read_banner_version(be);
		nvrm_rm_sync_running_version(be);
	}
	if (read_int_sysctl(NVRM_SYSCTL_WC, &wc) == 0) {
		be->wc = wc != 0;
		be->wc_reason = NVRM_R_NONE;
	} else {
		be->wc = 0;
		be->wc_reason = NVRM_R_OS_NOT_REPORTED;
	}
}

static void
read_rm_api_version(nvrm_backend *be)
{
	nv_ioctl_rm_api_version_t v;

	memset(&v, 0, sizeof(v));
	v.cmd = NV_RM_API_VERSION_CMD_QUERY;
	if (sys->ioctl(be->fd, IOC_CHECK_VERSION, &v) != 0) {
		be->rm_api.reason = nvrm_reason_id(NVRM_R_OS_CALL_FAILED);
		return;
	}
	v.versionString[sizeof(v.versionString) - 1] = '\0';
	if (v.reply != NV_RM_API_VERSION_REPLY_RECOGNIZED) {
		be->rm_api.reason = nvrm_reason_id(NVRM_R_RM_UNSUPPORTED);
		return;
	}
	(void)nvrm_version_parse(v.versionString, 10, &be->rm_api);
}

int
nvrm_rm_open(nvrm_backend **bep, char *err, size_t errlen)
{
	nvrm_backend *be;
	nv_ioctl_rm_api_version_t v;
	NvHandle client = 0;
	char found[NVRM_STR_MAX * 2];
	NvU32 st;
	int rc;

	*bep = NULL;
	be = NVRM_CALLOC(1, sizeof(*be));
	if (be == NULL) {
		snprintf(err, errlen, "out of memory");
		return (NVRM_E_NOMEM);
	}
	nvrm_owner_set(&be->owner);
	be->fd = sys->open(NVRM_CTL_PATH, O_RDWR | O_CLOEXEC);
	if (be->fd < 0) {
		snprintf(err, errlen, "cannot open %s: %s", NVRM_CTL_PATH,
		    strerror(errno));
		free(be);
		return (NVRM_E_OPEN);
	}
	read_sysctls(be);

	/* The kernel module must be exactly the RM this library speaks. */
	memset(&v, 0, sizeof(v));
	v.cmd = NV_RM_API_VERSION_CMD_STRICT;
	snprintf(v.versionString, sizeof(v.versionString), "%s",
	    NVRM_RM_VERSION);
	rc = sys->ioctl(be->fd, IOC_CHECK_VERSION, &v);
	if (rc != 0 && errno != EINVAL) {
		/* the call itself failed: that is not a version mismatch */
		snprintf(err, errlen, "the version check of %s failed: %s",
		    NVRM_CTL_PATH, strerror(errno));
		sys->close(be->fd);
		free(be);
		return (NVRM_E_IO);
	}
	if (rc != 0 || v.reply != NV_RM_API_VERSION_REPLY_RECOGNIZED) {
		if (be->running.reason == NVRM_R_NONE)
			snprintf(found, sizeof(found), "it reports \"%s\"",
			    be->running.value);
		else
			snprintf(found, sizeof(found), "its version is "
			    "unknown (hw.nvidia.version is not readable)");
		snprintf(err, errlen, "the kernel module does not match "
		    "libnvrm: %s; libnvrm was built for RM %s and refuses to "
		    "run (install the %s NVIDIA kernel module, or rebuild "
		    "libnvrm against the running one)", found,
		    NVRM_RM_VERSION, NVRM_RM_VERSION);
		sys->close(be->fd);
		free(be);
		return (NVRM_E_VERSION);
	}
	read_rm_api_version(be);
	/* The RM client of this process: one per enumerate. */
	st = nvrm_rm_alloc(be, 0, &client, NV01_ROOT, NULL, 0);
	if (st != NV_OK) {
		snprintf(err, errlen, "cannot allocate the RM client "
		    "(status 0x%x)", (unsigned)st);
		sys->close(be->fd);
		free(be);
		return (NVRM_E_IO);
	}
	be->client = client;
	*bep = be;
	return (NVRM_OK);
}

/*
 * The RM client belongs to the open file, which a forked child shares with
 * its parent.  Only the process that opened the descriptor may free the
 * client and the objects under it: a child that calls nvrm_close() only
 * releases its own copy of the descriptor and the memory.  The process id
 * alone is not enough (a grandchild can be given the id of a parent that has
 * exited), so every fork() of this process also counts a generation, in an
 * atfork handler of the child, and the owner must have both.
 */
int
nvrm_rm_owner(const nvrm_backend *be)
{
	return (nvrm_owner_is_me(&be->owner));
}

void
nvrm_rm_close(nvrm_backend *be)
{
	if (nvrm_rm_owner(be))
		nvrm_rm_free(be, 0, be->client);
	sys->close(be->fd);
	free(be);
}

static void
rm_running_version(nvrm_backend *be, nvrm_str *out)
{
	*out = be->running;
}

static void
rm_driver_version(nvrm_backend *be, nvrm_version *out)
{
	*out = be->driver;
}

static void
rm_api_version(nvrm_backend *be, nvrm_version *out)
{
	*out = be->rm_api;
}

static int
rm_list_gpus(nvrm_backend *be, uint32_t *ids, unsigned max, unsigned *n,
    char *err, size_t errlen)
{
	nv_ioctl_xfer_t xfer;
	NV0000_CTRL_GPU_GET_PROBED_IDS_PARAMS probed;
	NV0000_CTRL_GPU_ATTACH_IDS_PARAMS attach;
	NvU32 attach_ids[NV_MAX_DEVICES];
	unsigned i, nattach;
	NvU32 st;

	*n = 0;
	/* Card list: PCI location and the ids the OS layer attached. */
	memset(be->cards, 0, sizeof(be->cards));
	memset(&xfer, 0, sizeof(xfer));
	xfer.cmd = NV_ESC_CARD_INFO;
	xfer.size = sizeof(be->cards);
	xfer.ptr = NV_PTR_TO_NvP64(be->cards);
	if (sys->ioctl(be->fd, IOC_XFER, &xfer) != 0) {
		snprintf(err, errlen, "NV_ESC_CARD_INFO failed: %s",
		    strerror(errno));
		return (NVRM_E_IO);
	}
	nattach = 0;
	for (i = 0; i < NV_MAX_DEVICES; i++)
		if (be->cards[i].valid)
			attach_ids[nattach++] = be->cards[i].gpu_id;
	if (nattach == 0)
		return (NVRM_OK);	/* the core reports "no GPU" */
	if (sys->ioctl(be->fd, IOC_ATTACH(nattach), attach_ids) != 0) {
		snprintf(err, errlen, "NV_ESC_ATTACH_GPUS_TO_FD failed: %s",
		    strerror(errno));
		return (NVRM_E_IO);
	}

	/* The RM's own list of probed GPUs, then attach them in the RM. */
	memset(&probed, 0, sizeof(probed));
	st = nvrm_rm_control(be, be->client, NV0000_CTRL_CMD_GPU_GET_PROBED_IDS,
	    &probed, sizeof(probed));
	if (st != NV_OK) {
		snprintf(err, errlen, "NV0000_CTRL_CMD_GPU_GET_PROBED_IDS "
		    "failed (status 0x%x)", (unsigned)st);
		return (NVRM_E_IO);
	}
	memset(&attach, 0, sizeof(attach));
	for (i = 0; i < NV0000_CTRL_GPU_MAX_PROBED_GPUS; i++)
		attach.gpuIds[i] = NV0000_CTRL_GPU_INVALID_ID;
	/* max is at most NVRM_MAX_GPUS, which is the RM's own limit */
	_Static_assert(NVRM_MAX_GPUS <= NV0000_CTRL_GPU_MAX_PROBED_GPUS,
	    "the probed list must hold every GPU the library can");
	for (i = 0; *n < max &&
	    probed.gpuIds[i] != NV0000_CTRL_GPU_INVALID_ID; i++) {
		attach.gpuIds[i] = probed.gpuIds[i];
		ids[(*n)++] = probed.gpuIds[i];
	}
	st = nvrm_rm_control(be, be->client, NV0000_CTRL_CMD_GPU_ATTACH_IDS,
	    &attach, sizeof(attach));
	if (st != NV_OK) {
		snprintf(err, errlen, "NV0000_CTRL_CMD_GPU_ATTACH_IDS failed "
		    "(status 0x%x, GPU id 0x%x)", (unsigned)st,
		    (unsigned)attach.failedId);
		return (NVRM_E_IO);
	}
	return (NVRM_OK);
}

static int
rm_gpu_open(nvrm_backend *be, uint32_t id, nvrm_gpu **gpup, char *err,
    size_t errlen)
{
	NV0000_CTRL_GPU_GET_ID_INFO_V2_PARAMS info;
	NV0080_ALLOC_PARAMETERS dp;
	NV2080_ALLOC_PARAMETERS sp;
	nvrm_gpu *g;
	NvU32 st;
	unsigned i;

	g = NVRM_CALLOC(1, sizeof(*g));
	if (g == NULL) {
		snprintf(err, errlen, "out of memory");
		return (NVRM_E_NOMEM);
	}
	g->be = be;
	g->id = id;
	for (i = 0; i < NV_MAX_DEVICES; i++)
		if (be->cards[i].valid && be->cards[i].gpu_id == id) {
			g->card = be->cards[i];
			g->have_card = 1;
		}

	memset(&info, 0, sizeof(info));
	info.gpuId = id;
	st = nvrm_rm_control(be, be->client, NV0000_CTRL_CMD_GPU_GET_ID_INFO_V2,
	    &info, sizeof(info));
	if (st != NV_OK) {
		snprintf(err, errlen, "NV0000_CTRL_CMD_GPU_GET_ID_INFO_V2 "
		    "failed for GPU id 0x%x (status 0x%x)", (unsigned)id,
		    (unsigned)st);
		free(g);
		return (NVRM_E_IO);
	}
	memset(&dp, 0, sizeof(dp));
	dp.deviceId = info.deviceInstance;
	g->device = nvrm_rm_new_handle(be);
	st = nvrm_rm_alloc(be, be->client, &g->device, NV01_DEVICE_0, &dp,
	    sizeof(dp));
	if (st != NV_OK) {
		snprintf(err, errlen, "NV01_DEVICE_0 allocation failed for "
		    "GPU id 0x%x (status 0x%x)", (unsigned)id, (unsigned)st);
		free(g);
		return (NVRM_E_IO);
	}
	memset(&sp, 0, sizeof(sp));
	sp.subDeviceId = info.subDeviceInstance;
	g->subdevice = nvrm_rm_new_handle(be);
	st = nvrm_rm_alloc(be, g->device, &g->subdevice, NV20_SUBDEVICE_0, &sp,
	    sizeof(sp));
	if (st != NV_OK) {
		snprintf(err, errlen, "NV20_SUBDEVICE_0 allocation failed for "
		    "GPU id 0x%x (status 0x%x)", (unsigned)id, (unsigned)st);
		nvrm_rm_free(be, be->client, g->device);
		free(g);
		return (NVRM_E_IO);
	}
	*gpup = g;
	return (NVRM_OK);
}

static void
rm_gpu_close(nvrm_gpu *g)
{
	if (nvrm_rm_owner(g->be)) {
		nvrm_rm_free(g->be, g->device, g->subdevice);
		nvrm_rm_free(g->be, g->be->client, g->device);
	}
	free(g);
}

/* One entry of an NVXXXX_CTRL_XXX_INFO list, by itself so that a GPU that
 * rejects one index does not lose the others.  The three parameter blocks
 * (GPU, GR, FB) start with the list size followed by the list. */
static int
info_one(nvrm_gpu *g, NvU32 cmd, void *params, NvU32 size, NvU32 *list_size,
    NVXXXX_CTRL_XXX_INFO *entry, NvU32 index, uint64_t *out)
{
	NvU32 st;

	memset(params, 0, size);
	*list_size = 1;
	entry->index = index;
	st = nvrm_rm_control(g->be, g->subdevice, cmd, params, size);
	if (st != NV_OK)
		return (status_reason(st));
	*out = entry->data;
	return (0);
}

static int
info_one_gpu(nvrm_gpu *g, NvU32 index, uint64_t *out)
{
	NV2080_CTRL_GPU_GET_INFO_V2_PARAMS p;

	return (info_one(g, NV2080_CTRL_CMD_GPU_GET_INFO_V2, &p, sizeof(p),
	    &p.gpuInfoListSize, &p.gpuInfoList[0], index, out));
}

static int
info_one_gr(nvrm_gpu *g, NvU32 index, uint64_t *out)
{
	NV2080_CTRL_GR_GET_INFO_V2_PARAMS p;

	return (info_one(g, NV2080_CTRL_CMD_GR_GET_INFO_V2, &p, sizeof(p),
	    &p.grInfoListSize, &p.grInfoList[0], index, out));
}

static int
info_one_fb(nvrm_gpu *g, NvU32 index, uint64_t *out)
{
	NV2080_CTRL_FB_GET_INFO_V2_PARAMS p;

	return (info_one(g, NV2080_CTRL_CMD_FB_GET_INFO_V2, &p, sizeof(p),
	    &p.fbInfoListSize, &p.fbInfoList[0], index, out));
}

static int
info_one_bios(nvrm_gpu *g, NvU32 index, uint64_t *out)
{
	NV2080_CTRL_BIOS_GET_INFO_V2_PARAMS p;

	return (info_one(g, NV2080_CTRL_CMD_BIOS_GET_INFO_V2, &p, sizeof(p),
	    &p.biosInfoListSize, &p.biosInfoList[0], index, out));
}

static int
card_value(nvrm_gpu *g, uint64_t v, uint64_t *out)
{
	if (!g->have_card)
		return (NVRM_R_OS_NOT_REPORTED);
	*out = v;
	return (0);
}

static int
pci_info(nvrm_gpu *g, enum nvrm_prop p, uint64_t *out)
{
	NV2080_CTRL_BUS_GET_PCI_INFO_PARAMS b;
	NvU32 st;

	memset(&b, 0, sizeof(b));
	st = nvrm_rm_control(g->be, g->subdevice, NV2080_CTRL_CMD_BUS_GET_PCI_INFO,
	    &b, sizeof(b));
	if (st != NV_OK)
		return (status_reason(st));
	/* pciDeviceId and pciSubSystemId are assumed to have the layout of PCI
	 * config space (vendor in the low half, device in the high half).
	 * Only pciDeviceId can be checked: its two halves must equal the card
	 * list's vendor and device ids, and without a card record there is
	 * nothing to check against.  When the check fails or cannot be made
	 * the values are withheld, not reported under an unchecked assumption
	 * (the live run on a real driver confirms the subsystem half). */
	if (!g->have_card)
		return (NVRM_R_OS_NOT_REPORTED);
	if ((b.pciDeviceId & 0xffff) != g->card.pci_info.vendor_id ||
	    (b.pciDeviceId >> 16) != g->card.pci_info.device_id)
		return (NVRM_R_VALUE_UNUSABLE);
	if (p == NVRM_P_PCI_SUBSYSTEM_VENDOR)
		*out = b.pciSubSystemId & 0xffff;
	else if (p == NVRM_P_PCI_SUBSYSTEM_DEVICE)
		*out = b.pciSubSystemId >> 16;
	else
		*out = b.pciRevisionId;
	return (0);
}

static int
id_info(nvrm_gpu *g, enum nvrm_prop p, uint64_t *out)
{
	NV0000_CTRL_GPU_GET_ID_INFO_V2_PARAMS i;
	NvU32 st;

	memset(&i, 0, sizeof(i));
	i.gpuId = g->id;
	st = nvrm_rm_control(g->be, g->be->client,
	    NV0000_CTRL_CMD_GPU_GET_ID_INFO_V2, &i, sizeof(i));
	if (st != NV_OK)
		return (status_reason(st));
	if (p == NVRM_P_CAP_SOC) {
		*out = DRF_VAL(0000, _CTRL_GPU_ID_INFO, _SOC, i.gpuFlags);
		return (0);
	}
	if (i.numaId == NV0000_CTRL_NO_NUMA_NODE)
		return (NVRM_R_NO_NUMA);
	*out = (uint64_t)i.numaId;
	return (0);
}

/* PCI identity and the RM id. */
static int
prop_pci(nvrm_gpu *g, enum nvrm_prop p, uint64_t *out)
{
	switch (p) {
	case NVRM_P_PCI_DOMAIN:
		return (card_value(g, g->card.pci_info.domain, out));
	case NVRM_P_PCI_BUS:
		return (card_value(g, g->card.pci_info.bus, out));
	case NVRM_P_PCI_SLOT:
		return (card_value(g, g->card.pci_info.slot, out));
	case NVRM_P_PCI_FUNCTION:
		/* The FreeBSD OS layer does not fill the function number. */
		return (NVRM_R_OS_NOT_REPORTED);
	case NVRM_P_PCI_VENDOR:
		return (card_value(g, g->card.pci_info.vendor_id, out));
	case NVRM_P_PCI_DEVICE:
		return (card_value(g, g->card.pci_info.device_id, out));
	case NVRM_P_PCI_SUBSYSTEM_VENDOR:
	case NVRM_P_PCI_SUBSYSTEM_DEVICE:
	case NVRM_P_PCI_REVISION:
		return (pci_info(g, p, out));
	default:	/* NVRM_P_RM_GPU_ID */
		*out = g->id;
		return (0);
	}
}

/* The gpu class: architecture, SM version, enabled units. */
static int
prop_gpu(nvrm_gpu *g, enum nvrm_prop p, uint32_t arg, uint64_t *out)
{
	NV2080_CTRL_MC_GET_ARCH_INFO_PARAMS a;
	NV2080_CTRL_GR_GET_GPC_MASK_PARAMS gm;
	NV2080_CTRL_GR_GET_TPC_MASK_PARAMS tm;
	NvU32 st;

	switch (p) {
	case NVRM_P_ARCHITECTURE:
	case NVRM_P_IMPLEMENTATION:
		memset(&a, 0, sizeof(a));
		st = nvrm_rm_control(g->be, g->subdevice,
		    NV2080_CTRL_CMD_MC_GET_ARCH_INFO, &a, sizeof(a));
		if (st != NV_OK)
			return (status_reason(st));
		*out = p == NVRM_P_ARCHITECTURE ? a.architecture :
		    a.implementation;
		return (0);
	case NVRM_P_SM_VERSION:
		return (info_one_gr(g, NV2080_CTRL_GR_INFO_INDEX_SM_VERSION,
		    out));
	case NVRM_P_SM_PER_TPC:
		return (info_one_gr(g,
		    NV2080_CTRL_GR_INFO_INDEX_LITTER_NUM_SM_PER_TPC, out));
	case NVRM_P_GPC_MASK:
		memset(&gm, 0, sizeof(gm));
		st = nvrm_rm_control(g->be, g->subdevice,
		    NV2080_CTRL_CMD_GR_GET_GPC_MASK, &gm, sizeof(gm));
		if (st != NV_OK)
			return (status_reason(st));
		*out = gm.gpcMask;
		return (0);
	default:	/* NVRM_P_TPC_MASK */
		memset(&tm, 0, sizeof(tm));
		tm.gpcId = arg;
		st = nvrm_rm_control(g->be, g->subdevice,
		    NV2080_CTRL_CMD_GR_GET_TPC_MASK, &tm, sizeof(tm));
		if (st != NV_OK)
			return (status_reason(st));
		*out = tm.tpcMask;
		return (0);
	}
}

/* Memory: sizes, the largest page, the NUMA node. */
static int
prop_memory(nvrm_gpu *g, enum nvrm_prop p, uint64_t *out)
{
	NV2080_CTRL_GPU_GET_MAX_SUPPORTED_PAGE_SIZE_PARAMS ps;
	NvU32 st;

	switch (p) {
	case NVRM_P_VRAM_KB:
		return (info_one_fb(g, NV2080_CTRL_FB_INFO_INDEX_RAM_SIZE,
		    out));
	case NVRM_P_BAR1_KB:
		return (info_one_fb(g, NV2080_CTRL_FB_INFO_INDEX_BAR1_SIZE,
		    out));
	case NVRM_P_MAX_PAGE_SIZE:
		memset(&ps, 0, sizeof(ps));
		st = nvrm_rm_control(g->be, g->subdevice,
		    NV2080_CTRL_CMD_GPU_GET_MAX_SUPPORTED_PAGE_SIZE, &ps,
		    sizeof(ps));
		if (st != NV_OK)
			return (status_reason(st));
		*out = ps.maxSupportedPageSize;
		return (0);
	default:	/* NVRM_P_NUMA_NODE */
		return (id_info(g, p, out));
	}
}

/* GPU info index behind each capability flag that has one. */
static const NvU32 cap_gpu_index[] = {
	[NVRM_P_CAP_DMABUF - NVRM_P_CAP_DMABUF] =
	    NV2080_CTRL_GPU_INFO_INDEX_DMABUF_CAPABILITY,
	[NVRM_P_CAP_ATS - NVRM_P_CAP_DMABUF] =
	    NV2080_CTRL_GPU_INFO_INDEX_GPU_ATS_CAPABILITY,
	[NVRM_P_CAP_SELF_HOSTED - NVRM_P_CAP_DMABUF] =
	    NV2080_CTRL_GPU_INFO_INDEX_GPU_SELF_HOSTED_CAPABILITY,
	[NVRM_P_CAP_DISPLAY - NVRM_P_CAP_DMABUF] =
	    NV2080_CTRL_GPU_INFO_INDEX_DISPLAY_ENABLED,
};

/* Capability flags: the RM's yes or no, the OS layer's sysctl. */
static int
prop_cap(nvrm_gpu *g, enum nvrm_prop p, uint64_t *out)
{
	uint64_t v = 0;
	int r;

	if (p == NVRM_P_CAP_SOC)
		return (id_info(g, p, out));
	if (p == NVRM_P_CAP_OS_DEVICE_WC) {
		if (g->be->wc_reason != NVRM_R_NONE)
			return (g->be->wc_reason);
		*out = g->be->wc;
		return (0);
	}
	if (p == NVRM_P_CAP_COHERENT_MEMORY) {
		r = info_one_gpu(g,
		    NV2080_CTRL_GPU_INFO_INDEX_COHERENT_GPU_MEMORY_MODE, &v);
		v = v != NV2080_CTRL_GPU_INFO_INDEX_COHERENT_GPU_MEMORY_MODE_NONE;
	} else
		r = info_one_gpu(g, cap_gpu_index[p - NVRM_P_CAP_DMABUF], &v);
	if (r == 0)
		*out = v != 0;
	return (r);
}

static int
rm_gpu_u64(nvrm_gpu *g, enum nvrm_prop p, uint32_t arg, uint64_t *out)
{
	if (p <= NVRM_P_RM_GPU_ID)
		return (prop_pci(g, p, out));
	if (p <= NVRM_P_TPC_MASK)
		return (prop_gpu(g, p, arg, out));
	if (p <= NVRM_P_NUMA_NODE)
		return (prop_memory(g, p, out));
	if (p <= NVRM_P_CAP_OS_DEVICE_WC)
		return (prop_cap(g, p, out));
	return (NVRM_R_BACKEND_NONE);
}

static int
rm_gpu_vbios(nvrm_gpu *g, char *buf, size_t len)
{
	uint64_t revision, oem;
	int r;

	r = info_one_bios(g, NV2080_CTRL_BIOS_INFO_INDEX_REVISION, &revision);
	if (r != 0)
		return (r);
	r = info_one_bios(g, NV2080_CTRL_BIOS_INFO_INDEX_OEM_REVISION, &oem);
	if (r != 0)
		return (r);
	snprintf(buf, len, "%02x.%02x.%02x.%02x.%02x",
	    (unsigned)((revision >> 24) & 0xff),
	    (unsigned)((revision >> 16) & 0xff),
	    (unsigned)((revision >> 8) & 0xff),
	    (unsigned)(revision & 0xff), (unsigned)(oem & 0xff));
	return (0);
}

static int
rm_gpu_gsp(nvrm_gpu *g, char *buf, size_t len)
{
	NV2080_CTRL_GSP_GET_FEATURES_PARAMS gsp;
	NvU32 st;

	memset(&gsp, 0, sizeof(gsp));
	st = nvrm_rm_control(g->be, g->subdevice,
	    NV2080_CTRL_CMD_GSP_GET_FEATURES, &gsp, sizeof(gsp));
	if (st != NV_OK)
		return (status_reason(st));
	if (!gsp.bValid)
		return (NVRM_R_RM_UNSUPPORTED);
	gsp.firmwareVersion[sizeof(gsp.firmwareVersion) - 1] = 0;
	snprintf(buf, len, "%s", (const char *)gsp.firmwareVersion);
	return (0);
}

static int
rm_gpu_str(nvrm_gpu *g, enum nvrm_sprop p, char *buf, size_t len)
{
	NV2080_CTRL_GPU_GET_GID_INFO_PARAMS gid;
	NvU32 st;

	buf[0] = '\0';
	if (p == NVRM_SP_VBIOS)
		return (rm_gpu_vbios(g, buf, len));
	if (p == NVRM_SP_GSP_FIRMWARE)
		return (rm_gpu_gsp(g, buf, len));
	if (p != NVRM_SP_UUID)
		return (NVRM_R_BACKEND_NONE);
	memset(&gid, 0, sizeof(gid));
	gid.flags = DRF_DEF(2080_GPU_CMD, _GPU_GET_GID_FLAGS, _FORMAT, _ASCII) |
	    DRF_DEF(2080_GPU_CMD, _GPU_GET_GID_FLAGS, _TYPE, _SHA1);
	st = nvrm_rm_control(g->be, g->subdevice, NV2080_CTRL_CMD_GPU_GET_GID_INFO,
	    &gid, sizeof(gid));
	if (st != NV_OK)
		return (status_reason(st));
	gid.data[sizeof(gid.data) - 1] = 0;
	snprintf(buf, len, "%s", (const char *)gid.data);
	return (0);
}

/* The class list of the device: the RM's answer to the class-list control.
 * The storage is the caller's (it says how much room it has); the list
 * itself is the RM's own, and the control holds at most
 * NV0080_CTRL_GPU_CLASSLIST_MAX_SIZE classes (NVIDIA's number).  An RM that
 * claims more is refused, never cut: the answer cannot be trusted and the
 * classes past the cut would be missing ones. */
static int
rm_gpu_classes(nvrm_gpu *g, uint32_t *list, unsigned max, unsigned *n)
{
	NV0080_CTRL_GPU_GET_CLASSLIST_V2_PARAMS c;
	NvU32 st;
	unsigned i, lim;

	memset(&c, 0, sizeof(c));
	st = nvrm_rm_control(g->be, g->device, NV0080_CTRL_CMD_GPU_GET_CLASSLIST_V2,
	    &c, sizeof(c));
	if (st != NV_OK)
		return (status_reason(st));
	if (c.numClasses > NV0080_CTRL_GPU_CLASSLIST_MAX_SIZE)
		return (NVRM_R_VALUE_UNUSABLE);
	lim = max < NV0080_CTRL_GPU_CLASSLIST_MAX_SIZE ? max :
	    NV0080_CTRL_GPU_CLASSLIST_MAX_SIZE;
	*n = 0;
	for (i = 0; i < c.numClasses && i < lim; i++)
		list[(*n)++] = c.classList[i];
	return (0);
}

/* Descriptors: rights and the escape allow list.  After this the process may
 * enter capability mode and keep querying through the same descriptor. */
static int
rm_limit(nvrm_backend *be, int allow_alloc)
{
	static const unsigned long full[] = {
		IOC_RM_ALLOC, IOC_RM_CONTROL, IOC_RM_FREE
	};
	static const unsigned long query[] = { IOC_RM_CONTROL, IOC_RM_FREE };

	/* The default keeps only the controls and the frees; allocation needs
	 * the caller's explicit request.  No mapping right is ever granted:
	 * nothing in S1 maps memory (CPU mapping goes through descriptors a
	 * later step opens before the limit). */
	if (!allow_alloc)
		return (nvrm_cap_limit_fd(be->fd, query, 2));
	return (nvrm_cap_limit_fd(be->fd, full, 3));
}

/* ---- the classes the channel backend binds (nvrm_rm_chan.c) ------------- */

/*
 * The RM's names for the classes a channel is made of.  They are in NVIDIA's
 * own headers, and this table is the only place in the library that names
 * them: the rest of it does not have to know which chip it talks to.  Each
 * slot has two candidates and the first the device lists wins.
 */
static const uint32_t chan_class_tab[NVRM_RM_CLS__COUNT][2] = {
	{ BLACKWELL_B, 0 },
	{ BLACKWELL_COMPUTE_B, BLACKWELL_COMPUTE_A },
	{ BLACKWELL_INLINE_TO_MEMORY_A, 0 },
	{ FERMI_TWOD_A, 0 },
	{ BLACKWELL_DMA_COPY_B, 0 },
	{ BLACKWELL_CHANNEL_GPFIFO_B, BLACKWELL_CHANNEL_GPFIFO_A }
};

/* The class of a slot: the first of its candidates the device lists, or 0
 * when the device lists none of them.  The slot is one of NVRM_RM_CLS_*. */
uint32_t
nvrm_rm_chan_class(const nvrm_bclient *c, unsigned slot)
{
	unsigned i, j;

	/* Time: O(the candidates and the classes of the device).  Space:
	 * O(1). */
	for (i = 0; i < 2; i++) {
		uint32_t cls = chan_class_tab[slot][i];

		if (cls == 0)
			continue;
		for (j = 0; j < c->nclasses; j++)
			if (c->classes[j] == cls)
				return (cls);
	}
	return (0);
}

/* The class of the channel group (one per channel). */
uint32_t
nvrm_rm_chan_group_class(void)
{
	return (KEPLER_CHANNEL_GROUP_A);
}

/* The class of the usermode object: the one the library allocates, and the
 * one the channel backend names when a step of it fails. */
uint32_t
nvrm_rm_usermode_class(void)
{
	return (BLACKWELL_USERMODE_A);
}

/* The client's own objects for the channel backend: a subdevice of the
 * device and the usermode object under it, where the doorbell is written.
 * The class and the parameters are the RM backend's own. */
int
nvrm_rm_usermode_alloc(nvrm_bclient *c, char *err, size_t errlen)
{
	NV2080_ALLOC_PARAMETERS sp;
	NV_HOPPER_USERMODE_A_PARAMS up;
	NvU32 st;

	memset(&sp, 0, sizeof(sp));
	sp.subDeviceId = 0;
	c->subdevice = nvrm_rm_new_handle(c->s);
	st = nvrm_rm_alloc(c->s, c->device, &c->subdevice, NV20_SUBDEVICE_0, &sp,
	    sizeof(sp));
	if (st != NV_OK) {
		c->subdevice = 0;
		return (nvrm_rmm_status_fail(err, errlen,
		    "the subdevice allocation", st));
	}
	memset(&up, 0, sizeof(up));
	up.bBar1Mapping = NV_FALSE;
	up.bPriv = NV_FALSE;
	c->usermode = nvrm_rm_new_handle(c->s);
	st = nvrm_rm_alloc(c->s, c->subdevice, &c->usermode,
	    nvrm_rm_usermode_class(), &up, sizeof(up));
	if (st != NV_OK) {
		c->usermode = 0;
		return (nvrm_rmm_status_fail(err, errlen,
		    "the usermode object allocation", st));
	}
	return (NVRM_OK);
}

const nvrm_backend_ops nvrm_backend_rm_ops = {
	.name = "rm",
	.score = 100,
	.probe = rm_probe,
	.open = nvrm_rm_open,
	.close = nvrm_rm_close,
	.running_version = rm_running_version,
	.driver_version = rm_driver_version,
	.rm_api_version = rm_api_version,
	.list_gpus = rm_list_gpus,
	.gpu_open = rm_gpu_open,
	.gpu_close = rm_gpu_close,
	.gpu_u64 = rm_gpu_u64,
	.gpu_str = rm_gpu_str,
	.gpu_classes = rm_gpu_classes,
	.limit = rm_limit,
	.mem = &nvrm_rm_mem_ops,
	.chan = &nvrm_rm_chan_ops,
};

/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * scripted_rm.h - a stand-in for /dev/nvidiactl: the RM escapes implemented
 * with NVIDIA's own structures, checking every request and answering from a
 * table shaped like the RTX 5060 Ti.  Shared by rm_test.c and cap_test.c.
 * Include once, after the NVIDIA and libnvrm headers.
 */
#ifndef _SCRIPTED_RM_H_
#define _SCRIPTED_RM_H_

#define CLIENT		0xc1100001u
#define MAXOBJ		64

static struct {
	/* configuration */
	const char	*version;	/* strict-check module version */
	const char	*banner;	/* hw.nvidia.version */
	const char	*version_string; /* hw.nvidia.version_string */
	const char	*version_suffix; /* hw.nvidia.version_suffix */
	const char	*rm_api_version; /* query reply versionString */
	const char	*gsp_firmware;	/* GSP GET_FEATURES firmwareVersion */
	uint32_t	vbios_revision, vbios_oem_revision;
	int		gsp_valid;	/* GSP GET_FEATURES bValid */
	int		fail_vbios_oem;	/* fail only the OEM-revision control */
	int		version_major, version_minor, version_patch;
	int		version_available;
	int		version_parts;	/* 1 = the version_* sysctls exist */
	int		ngpus;
	uint32_t	gpu_id[2];
	int		have_card[2];
	int		fn_wc;		/* sysctl wc value; -1 = sysctl fails */
	int		fn_ver;		/* 1 = hw.nvidia.version works */
	int		fail_banner_read; /* probe succeeds, data read fails */
	int		banner_probe_zero; /* probe reports a zero length */
	int		fn_wc_short;	/* answer with the wrong length */
	int		numa;
	int		soc;
	int		gpu_info_fail_index;	/* an index the RM rejects */
	int		classes_over;	/* report more classes than fit */
	/* failure injection: nth call of kind fails */
	int		fail_open, fail_alloc_class, fail_ctl_cmd;
	int		fail_ctl_status;	/* RM status to return, or 0 */
	int		fail_ioctl_nr;		/* ioctl fails with errno */
	int		fail_probed;
	/* record */
	int		order_ok;
	int		saw_version, saw_version_query;
	int		saw_version_probe, banner_reads;
	int		saw_vbios_revision, saw_vbios_oem_revision, saw_gsp;
	int		saw_card, saw_attach_fd, saw_client;
	int		nalloc, nfree, nctl;
	NvHandle	live[MAXOBJ];
	int		nlive;
	NvHandle	device[2], subdevice[2];
	int		next_dev;
	int		bad;		/* a request the kernel had to refuse */
	char		badmsg[200];
	int		cmds_seen[8];
	int		real_first;	/* run the real ioctl(2) first */
	int		use_pipe;	/* the control fd is a pipe */
	int		real_errno;	/* errno of a refused real ioctl */
	int		last_fd;	/* the control descriptor handed out */
	int		nfd;		/* descriptors opened and not closed */
	int		reply_unrecognized;	/* strict check is not recognized */
	int		query_unrecognized;	/* RM version query is not recognized */
	int		fail_version_query;	/* only the query ioctl fails */
	int		bad_pci_vendor;	/* pciDeviceId vendor half differs from the card */
	int		bad_pci_device;	/* pciDeviceId device half differs from the card */
	int		swap_pci;	/* pciDeviceId with vendor and device swapped */
} K;

static void
bad(const char *msg)
{
	K.bad++;
	snprintf(K.badmsg, sizeof(K.badmsg), "%s", msg);
}

static void
reset_kernel(void)
{
	memset(&K, 0, sizeof(K));
	K.version = NVRM_RM_VERSION;
	K.banner = "NVIDIA UNIX Open Kernel Module for aarch64  "
	    "580.178.04  Release Build  (cloudbsd@build)  "
	    "Sun Nov 22 06:36:44 UTC 2026";
	K.version_string = NVRM_RM_VERSION;
	K.version_suffix = "";
	K.rm_api_version = NVRM_RM_VERSION;
	K.gsp_firmware = NVRM_RM_VERSION;
	K.vbios_revision = 0x96061e00;
	K.vbios_oem_revision = 0x4a;
	K.gsp_valid = 1;
	K.version_major = 580;
	K.version_minor = 178;
	K.version_patch = 4;
	K.version_available = 1;
	K.ngpus = 1;
	K.gpu_id[0] = 0x0d00;
	K.gpu_id[1] = 0x0e00;
	K.have_card[0] = K.have_card[1] = 1;
	K.fn_wc = 1;
	K.fn_ver = 1;
	K.numa = -1;
	K.gpu_info_fail_index = -1;
	K.fail_alloc_class = -1;
	K.fail_ctl_cmd = -1;
	K.fail_ioctl_nr = -1;
}

static int
k_open(const char *path, int flags)
{
	int fd;

	if (K.fail_open) {
		errno = ENOENT;
		return (-1);
	}
	if (strcmp(path, "/dev/nvidiactl") != 0)
		bad("opened something other than /dev/nvidiactl");
	if ((flags & O_RDWR) == 0)
		bad("control device not opened read-write");
	if (K.use_pipe) {
		int pp[2];

		if (pipe2(pp, O_CLOEXEC) != 0)
			return (-1);
		close(pp[1]);
		K.last_fd = pp[0];
		K.nfd++;
		return (pp[0]);
	}
	fd = open("/dev/null", O_RDWR | O_CLOEXEC);
	if (fd >= 0)
		K.nfd++;
	return (fd);
}

/* Counts results, not calls: a failed open is no descriptor, and a close that
 * fails (a double close, -1) neither frees one nor hides a leak. */
static int
k_close(int fd)
{
	int r = close(fd);

	if (r == 0 && --K.nfd < 0)
		bad("closed a descriptor that was not open");
	return (r);
}

static int
k_access(const char *path)
{
	return (strcmp(path, "/dev/nvidiactl") == 0 ? 0 : -1);
}

static int
k_sysctl_string(void *old, size_t *len, const char *value)
{
	size_t need = strlen(value) + 1;

	if (old == NULL) {
		*len = need;
		return (0);
	}
	if (*len < need) {
		*len = need;
		errno = ENOMEM;
		return (-1);
	}
	memcpy(old, value, need);
	*len = need;
	return (0);
}

static int
k_sysctl_int(void *old, size_t *len, int value)
{
	if (old == NULL) {
		*len = sizeof(value);
		return (0);
	}
	if (*len < sizeof(value)) {
		*len = sizeof(value);
		errno = ENOMEM;
		return (-1);
	}
	memcpy(old, &value, sizeof(value));
	*len = sizeof(value);
	return (0);
}

static int
k_sysctl(const char *name, void *old, size_t *len)
{
	if (strcmp(name, "hw.nvidia.version") == 0) {
		if (!K.fn_ver) {
			errno = ENOENT;
			return (-1);
		}
		if (old == NULL) {
			K.saw_version_probe++;
			if (K.banner_probe_zero) {
				*len = 0;
				return (0);
			}
		} else {
			K.banner_reads++;
			if (K.fail_banner_read) {
				errno = EIO;
				return (-1);
			}
		}
		return (k_sysctl_string(old, len, K.banner));
	}
	if (strncmp(name, "hw.nvidia.version_", 18) == 0) {
		if (!K.version_parts) {
			errno = ENOENT;
			return (-1);
		}
		if (strcmp(name, "hw.nvidia.version_string") == 0)
			return (k_sysctl_string(old, len, K.version_string));
		if (strcmp(name, "hw.nvidia.version_major") == 0)
			return (k_sysctl_int(old, len, K.version_major));
		if (strcmp(name, "hw.nvidia.version_minor") == 0)
			return (k_sysctl_int(old, len, K.version_minor));
		if (strcmp(name, "hw.nvidia.version_patch") == 0)
			return (k_sysctl_int(old, len, K.version_patch));
		if (strcmp(name, "hw.nvidia.version_suffix") == 0)
			return (k_sysctl_string(old, len, K.version_suffix));
		if (strcmp(name, "hw.nvidia.version_available") == 0)
			return (k_sysctl_int(old, len, K.version_available));
	}
	if (strcmp(name, "hw.nvidia.altra_device_wc_active") == 0) {
		if (K.fn_wc < 0) {
			errno = ENOENT;
			return (-1);
		}
		if (K.fn_wc_short) {
			int v = K.fn_wc;

			memcpy(old, &v, *len < sizeof(v) ? *len : sizeof(v));
			*len = 2;
			return (0);
		}
		return (k_sysctl_int(old, len, K.fn_wc));
	}
	bad("unexpected sysctl");
	return (-1);
}

static int
inst(NvHandle h, NvHandle *list, int n)
{
	int i;

	for (i = 0; i < n; i++)
		if (list[i] == h)
			return (i);
	return (-1);
}

/* #lizard forgives -- the scripted kernel mirrors the RM control switch, one case per control */
static void
handle_control(NVOS54_PARAMETERS *p)
{
	NvU32 cmd = p->cmd;
	int g;

	K.nctl++;
	p->status = NV_OK;
	if (p->hClient != CLIENT) {
		bad("control with a wrong client handle");
		p->status = NV_ERR_INVALID_CLIENT;
		return;
	}
	if (K.fail_ctl_cmd == (int)cmd && K.fail_ctl_status != 0) {
		p->status = K.fail_ctl_status;
		return;
	}
#define NEED(obj, T)	do {						\
	if (p->paramsSize != sizeof(T)) {				\
		bad("wrong parameter size for " #T);			\
		p->status = NV_ERR_INVALID_PARAM_STRUCT;		\
		return;							\
	}								\
	(void)(obj);							\
} while (0)
	switch (cmd) {
	case NV0000_CTRL_CMD_GPU_GET_PROBED_IDS: {
		NV0000_CTRL_GPU_GET_PROBED_IDS_PARAMS *a = NvP64_VALUE(p->params);
		int i;

		NEED(0, NV0000_CTRL_GPU_GET_PROBED_IDS_PARAMS);
		if (p->hObject != CLIENT)
			bad("PROBED_IDS not on the client");
		if (K.fail_probed) {
			p->status = NV_ERR_GENERIC;
			return;
		}
		for (i = 0; i < NV0000_CTRL_GPU_MAX_PROBED_GPUS; i++)
			a->gpuIds[i] = NV0000_CTRL_GPU_INVALID_ID;
		for (i = 0; i < K.ngpus; i++)
			a->gpuIds[i] = K.gpu_id[i];
		return;
	}
	case NV0000_CTRL_CMD_GPU_ATTACH_IDS: {
		NV0000_CTRL_GPU_ATTACH_IDS_PARAMS *a = NvP64_VALUE(p->params);
		int i;

		NEED(0, NV0000_CTRL_GPU_ATTACH_IDS_PARAMS);
		/* a prefix of the probed list is legal (the caller had less
		 * room); it must be terminated and start with the probed ids */
		for (i = 0; i < NV0000_CTRL_GPU_MAX_PROBED_GPUS &&
		    a->gpuIds[i] != NV0000_CTRL_GPU_INVALID_ID; i++)
			if (i >= K.ngpus || a->gpuIds[i] != K.gpu_id[i])
				bad("ATTACH_IDS list differs from probed");
		if (i == 0)
			bad("ATTACH_IDS list is empty");
		K.cmds_seen[0]++;
		return;
	}
	case NV0000_CTRL_CMD_GPU_GET_ID_INFO_V2: {
		NV0000_CTRL_GPU_GET_ID_INFO_V2_PARAMS *a = NvP64_VALUE(p->params);

		NEED(0, NV0000_CTRL_GPU_GET_ID_INFO_V2_PARAMS);
		g = a->gpuId == K.gpu_id[0] ? 0 : 1;
		a->deviceInstance = g;
		a->subDeviceInstance = 0;
		a->numaId = K.numa;
		a->gpuFlags = K.soc ? (1u << 5) : 0;
		return;
	}
	default:
		break;
	}

	/* everything else is on a device or subdevice */
	g = inst(p->hObject, K.subdevice, 2);
	if (cmd == NV0080_CTRL_CMD_GPU_GET_CLASSLIST_V2) {
		NV0080_CTRL_GPU_GET_CLASSLIST_V2_PARAMS *a = NvP64_VALUE(p->params);

		NEED(0, NV0080_CTRL_GPU_GET_CLASSLIST_V2_PARAMS);
		if (inst(p->hObject, K.device, 2) < 0)
			bad("classlist not on the device");
		a->numClasses = K.classes_over ? 500 : 3;
		a->classList[0] = 0xcec0;
		a->classList[1] = 0xca6f;
		a->classList[2] = 0x2080;
		return;
	}
	if (g < 0) {
		bad("subdevice control on a handle that is not a subdevice");
		p->status = NV_ERR_INVALID_OBJECT_HANDLE;
		return;
	}
	switch (cmd) {
	case NV2080_CTRL_CMD_BIOS_GET_INFO_V2: {
		NV2080_CTRL_BIOS_GET_INFO_V2_PARAMS *a = NvP64_VALUE(p->params);

		NEED(0, NV2080_CTRL_BIOS_GET_INFO_V2_PARAMS);
		if (a->biosInfoListSize != 1)
			bad("BIOS info asked for more than one index");
		switch (a->biosInfoList[0].index) {
		case NV2080_CTRL_BIOS_INFO_INDEX_REVISION:
			K.saw_vbios_revision++;
			a->biosInfoList[0].data = K.vbios_revision;
			break;
		case NV2080_CTRL_BIOS_INFO_INDEX_OEM_REVISION:
			K.saw_vbios_oem_revision++;
			if (K.fail_vbios_oem) {
				p->status = NV_ERR_GENERIC;
				return;
			}
			a->biosInfoList[0].data = K.vbios_oem_revision;
			break;
		default:
			p->status = NV_ERR_INVALID_ARGUMENT;
		}
		return;
	}
	case NV2080_CTRL_CMD_GSP_GET_FEATURES: {
		NV2080_CTRL_GSP_GET_FEATURES_PARAMS *a = NvP64_VALUE(p->params);

		NEED(0, NV2080_CTRL_GSP_GET_FEATURES_PARAMS);
		K.saw_gsp++;
		a->bValid = K.gsp_valid ? NV_TRUE : NV_FALSE;
		if (a->bValid)
			snprintf((char *)a->firmwareVersion,
			    sizeof(a->firmwareVersion), "%s", K.gsp_firmware);
		return;
	}
	case NV2080_CTRL_CMD_BUS_GET_PCI_INFO: {
		NV2080_CTRL_BUS_GET_PCI_INFO_PARAMS *a = NvP64_VALUE(p->params);

		NEED(0, NV2080_CTRL_BUS_GET_PCI_INFO_PARAMS);
		a->pciDeviceId = K.swap_pci ? 0x10de2d04 :
		    K.bad_pci_device ? 0x111110de :
		    K.bad_pci_vendor ? 0x2d041111 : 0x2d0410de;
		a->pciSubSystemId = 0x53511462;
		a->pciRevisionId = 0xa1;
		return;
	}
	case NV2080_CTRL_CMD_MC_GET_ARCH_INFO: {
		NV2080_CTRL_MC_GET_ARCH_INFO_PARAMS *a = NvP64_VALUE(p->params);

		NEED(0, NV2080_CTRL_MC_GET_ARCH_INFO_PARAMS);
		a->architecture = NV2080_CTRL_MC_ARCH_INFO_ARCHITECTURE_GB200;
		a->implementation = NV2080_CTRL_MC_ARCH_INFO_IMPLEMENTATION_GB206;
		return;
	}
	case NV2080_CTRL_CMD_GR_GET_INFO_V2: {
		NV2080_CTRL_GR_GET_INFO_V2_PARAMS *a = NvP64_VALUE(p->params);

		NEED(0, NV2080_CTRL_GR_GET_INFO_V2_PARAMS);
		if (a->grInfoListSize != 1)
			bad("GR info asked for more than one index");
		switch (a->grInfoList[0].index) {
		case NV2080_CTRL_GR_INFO_INDEX_SM_VERSION:
			a->grInfoList[0].data = NV2080_CTRL_GR_INFO_SM_VERSION_12_00;
			break;
		case NV2080_CTRL_GR_INFO_INDEX_LITTER_NUM_SM_PER_TPC:
			a->grInfoList[0].data = 2;
			break;
		default:
			p->status = NV_ERR_INVALID_ARGUMENT;
		}
		return;
	}
	case NV2080_CTRL_CMD_GR_GET_GPC_MASK: {
		NV2080_CTRL_GR_GET_GPC_MASK_PARAMS *a = NvP64_VALUE(p->params);

		NEED(0, NV2080_CTRL_GR_GET_GPC_MASK_PARAMS);
		a->gpcMask = 0x7;
		return;
	}
	case NV2080_CTRL_CMD_GR_GET_TPC_MASK: {
		NV2080_CTRL_GR_GET_TPC_MASK_PARAMS *a = NvP64_VALUE(p->params);

		NEED(0, NV2080_CTRL_GR_GET_TPC_MASK_PARAMS);
		a->tpcMask = 0x3f;
		return;
	}
	case NV2080_CTRL_CMD_FB_GET_INFO_V2: {
		NV2080_CTRL_FB_GET_INFO_V2_PARAMS *a = NvP64_VALUE(p->params);

		NEED(0, NV2080_CTRL_FB_GET_INFO_V2_PARAMS);
		if (a->fbInfoListSize != 1)
			bad("FB info asked for more than one index");
		switch (a->fbInfoList[0].index) {
		case NV2080_CTRL_FB_INFO_INDEX_RAM_SIZE:
			a->fbInfoList[0].data = 16 * 1024 * 1024;	/* KiB */
			break;
		case NV2080_CTRL_FB_INFO_INDEX_BAR1_SIZE:
			a->fbInfoList[0].data = 8 * 1024 * 1024;
			break;
		default:
			p->status = NV_ERR_INVALID_ARGUMENT;
		}
		return;
	}
	case NV2080_CTRL_CMD_GPU_GET_MAX_SUPPORTED_PAGE_SIZE: {
		NV2080_CTRL_GPU_GET_MAX_SUPPORTED_PAGE_SIZE_PARAMS *a =
		    NvP64_VALUE(p->params);

		NEED(0, NV2080_CTRL_GPU_GET_MAX_SUPPORTED_PAGE_SIZE_PARAMS);
		a->maxSupportedPageSize = 512ULL << 20;
		return;
	}
	case NV2080_CTRL_CMD_GPU_GET_INFO_V2: {
		NV2080_CTRL_GPU_GET_INFO_V2_PARAMS *a = NvP64_VALUE(p->params);
		NvU32 idx;

		NEED(0, NV2080_CTRL_GPU_GET_INFO_V2_PARAMS);
		if (a->gpuInfoListSize != 1)
			bad("GPU info asked for more than one index");
		idx = a->gpuInfoList[0].index;
		if ((int)idx == K.gpu_info_fail_index) {
			p->status = NV_ERR_NOT_SUPPORTED;
			return;
		}
		switch (idx) {
		case NV2080_CTRL_GPU_INFO_INDEX_DMABUF_CAPABILITY:
			a->gpuInfoList[0].data = 1;
			break;
		case NV2080_CTRL_GPU_INFO_INDEX_GPU_ATS_CAPABILITY:
		case NV2080_CTRL_GPU_INFO_INDEX_GPU_SELF_HOSTED_CAPABILITY:
			a->gpuInfoList[0].data = 0;
			break;
		case NV2080_CTRL_GPU_INFO_INDEX_DISPLAY_ENABLED:
			a->gpuInfoList[0].data = 1;
			break;
		case NV2080_CTRL_GPU_INFO_INDEX_COHERENT_GPU_MEMORY_MODE:
			a->gpuInfoList[0].data = K.soc ?
			    NV2080_CTRL_GPU_INFO_INDEX_COHERENT_GPU_MEMORY_MODE_NUMA :
			    NV2080_CTRL_GPU_INFO_INDEX_COHERENT_GPU_MEMORY_MODE_NONE;
			break;
		default:
			bad("GPU info index not expected");
			p->status = NV_ERR_INVALID_ARGUMENT;
		}
		return;
	}
	case NV2080_CTRL_CMD_GPU_GET_GID_INFO: {
		NV2080_CTRL_GPU_GET_GID_INFO_PARAMS *a = NvP64_VALUE(p->params);

		NEED(0, NV2080_CTRL_GPU_GET_GID_INFO_PARAMS);
		if (a->flags != (NV2080_GPU_CMD_GPU_GET_GID_FLAGS_FORMAT_ASCII |
		    NV2080_GPU_CMD_GPU_GET_GID_FLAGS_TYPE_SHA1))
			bad("GID flags are not ascii sha1");
		snprintf((char *)a->data, sizeof(a->data),
		    "GPU-11111111-2222-4333-8444-555555555555");
		a->length = 41;
		return;
	}
	default:
		bad("an RM control the backend should not send");
		p->status = NV_ERR_NOT_SUPPORTED;
	}
}

static void
handle_alloc(NVOS21_PARAMETERS *p)
{
	K.nalloc++;
	p->status = NV_OK;
	if (K.fail_alloc_class == (int)p->hClass) {
		p->status = NV_ERR_GENERIC;
		return;
	}
	switch (p->hClass) {
	case NV01_ROOT_CLIENT:
	case NV01_ROOT:
		if (p->hRoot != 0 || p->hObjectParent != 0)
			bad("client allocated under a parent");
		p->hObjectNew = CLIENT;
		K.saw_client = 1;
		break;
	case NV01_DEVICE_0: {
		NV0080_ALLOC_PARAMETERS *a = NvP64_VALUE(p->pAllocParms);

		if (p->hRoot != CLIENT || p->hObjectParent != CLIENT)
			bad("device not under the client");
		if (p->paramsSize != sizeof(*a))
			bad("device alloc parameter size");
		if (a->deviceId != (NvU32)K.next_dev)
			bad("device instance is not the one from ID_INFO");
		K.device[K.next_dev] = p->hObjectNew;
		break;
	}
	case NV20_SUBDEVICE_0: {
		NV2080_ALLOC_PARAMETERS *a = NvP64_VALUE(p->pAllocParms);

		if (p->hObjectParent != K.device[K.next_dev])
			bad("subdevice not under its device");
		if (p->paramsSize != sizeof(*a) || a->subDeviceId != 0)
			bad("subdevice alloc parameters");
		K.subdevice[K.next_dev] = p->hObjectNew;
		K.next_dev++;
		break;
	}
	default:
		bad("unexpected class allocated");
		p->status = NV_ERR_INVALID_CLASS;
		return;
	}
	if (K.nlive < MAXOBJ)
		K.live[K.nlive++] = p->hObjectNew;
}

/* #lizard forgives -- the scripted kernel mirrors the escape switch, one case per escape */
static int
k_ioctl(int fd, unsigned long cmd, void *arg)
{
	int nr = cmd & 0xff;
	size_t size = IOCPARM_LEN(cmd);

	if (K.real_first) {
		/* The kernel's Capsicum check comes before the driver: a
		 * pipe answers ENOTTY to an unknown command once the check
		 * passes, ENOTCAPABLE when the allow list refuses it. */
		if (ioctl(fd, cmd, arg) == 0 || errno != ENOTTY) {
			K.real_errno = errno;
			return (-1);
		}
	}

	if (K.fail_ioctl_nr == nr) {
		errno = EIO;
		return (-1);
	}
	if ((cmd >> 8 & 0xff) != 'F')
		bad("ioctl group is not 'F'");
	if (!(cmd & IOC_IN) || !(cmd & IOC_OUT))
		bad("ioctl is not read-write");
	switch (nr) {
	case NV_ESC_CHECK_VERSION_STR: {
		nv_ioctl_rm_api_version_t *v = arg;

		if (size != sizeof(*v))
			bad("version ioctl size");
		if (v->cmd == NV_RM_API_VERSION_CMD_QUERY) {
			if (!K.saw_version || K.nalloc != 0 || K.saw_card)
				bad("version query was not after the strict check");
			K.saw_version_query++;
			if (K.fail_version_query) {
				errno = EIO;
				return (-1);
			}
			v->reply = K.query_unrecognized ?
			    NV_RM_API_VERSION_REPLY_UNRECOGNIZED :
			    NV_RM_API_VERSION_REPLY_RECOGNIZED;
			snprintf(v->versionString, sizeof(v->versionString), "%s",
			    K.rm_api_version);
			return (0);
		}
		if (v->cmd != NV_RM_API_VERSION_CMD_STRICT)
			bad("version check is not strict or a query");
		if (K.nalloc != 0 || K.saw_card)
			bad("version check was not the first call");
		K.saw_version = 1;
		if (strcmp(v->versionString, K.version) != 0) {
			errno = EINVAL;
			return (-1);
		}
		v->reply = K.reply_unrecognized ?
		    NV_RM_API_VERSION_REPLY_UNRECOGNIZED :
		    NV_RM_API_VERSION_REPLY_RECOGNIZED;
		return (0);
	}
	case NV_ESC_IOCTL_XFER_CMD: {
		nv_ioctl_xfer_t *x = arg;
		nv_ioctl_card_info_t *ci;
		int i;

		if (size != sizeof(*x))
			bad("xfer size");
		if (x->cmd != NV_ESC_CARD_INFO ||
		    x->size < sizeof(*ci) * NV_MAX_DEVICES)
			bad("xfer is not a full card info request");
		ci = NvP64_VALUE(x->ptr);
		memset(ci, 0, x->size);
		for (i = 0; i < K.ngpus; i++) {
			if (!K.have_card[i])
				continue;
			ci[i].valid = NV_TRUE;
			ci[i].gpu_id = K.gpu_id[i];
			ci[i].pci_info.domain = 0;
			ci[i].pci_info.bus = 13;
			ci[i].pci_info.slot = 0;
			ci[i].pci_info.vendor_id = 0x10de;
			ci[i].pci_info.device_id = 0x2d04;
		}
		K.saw_card = 1;
		return (0);
	}
	case NV_ESC_ATTACH_GPUS_TO_FD: {
		NvU32 *ids = arg;
		size_t n = size / sizeof(NvU32), i, want = 0;

		for (i = 0; i < (size_t)K.ngpus; i++)
			want += K.have_card[i];
		if (n != want || size % sizeof(NvU32) != 0)
			bad("ATTACH_GPUS_TO_FD size is not the card count");
		for (i = 0; i < n && i < 2; i++)
			if (ids[i] != K.gpu_id[i])
				bad("ATTACH_GPUS_TO_FD id");
		K.saw_attach_fd = 1;
		return (0);
	}
	case NV_ESC_RM_ALLOC:
		if (size != sizeof(NVOS21_PARAMETERS))
			bad("alloc ioctl size");
		handle_alloc(arg);
		return (0);
	case NV_ESC_RM_CONTROL:
		if (size != sizeof(NVOS54_PARAMETERS))
			bad("control ioctl size");
		handle_control(arg);
		return (0);
	case NV_ESC_RM_FREE: {
		NVOS00_PARAMETERS *p = arg;
		int i;

		if (size != sizeof(*p))
			bad("free ioctl size");
		K.nfree++;
		i = inst(p->hObjectOld, K.live, K.nlive);
		if (i < 0)
			bad("free of a handle that is not live");
		else
			K.live[i] = K.live[--K.nlive];
		p->status = NV_OK;
		return (0);
	}
	default:
		bad("unexpected ioctl number");
		errno = ENOTTY;
		return (-1);
	}
}

static const nvrm_rm_sys scripted = { k_open, k_close, k_ioctl, k_sysctl,
    k_access };


#endif

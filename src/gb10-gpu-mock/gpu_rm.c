/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-3-Clause
 *
 * gpu_rm.c - the RM escape ioctls of libnvrm's rm backend, answered from the
 * model.  This is the ABI the real driver speaks: alloc, control, map, free
 * and the channel calls.
 *
 * The structures and the constants are NVIDIA's own (open-gpu-kernel-modules
 * 580.178.04, MIT): nvos.h, nv-ioctl.h, nv_escape.h and the class and
 * control headers.  Nothing here reads a Linux source.
 *
 * The engine keeps the RM's own state: the objects a client allocated, the
 * GPUs attached to a descriptor, the memory that was mapped.  It is the same
 * engine behind the CUSE device nodes of the daemon and behind the seam the
 * tests use, so a test and a jail see the same answers.
 */
#include <sys/param.h>
#include <sys/ioctl.h>
#include <sys/ioccom.h>

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <nvtypes.h>
#include <nvstatus.h>
#include <nvmisc.h>
#include <nvos.h>
#include <nv-ioctl.h>
#include <nv_escape.h>
#include <nv-unix-nvos-params-wrappers.h>
#include <class/cl0000.h>
#include <class/cl003e.h>
#include <class/cl0040.h>
#include <class/cl0070.h>
#include <class/cl0071.h>
#include <class/cl0080.h>
#include <class/cl2080.h>
#include <class/cl50a0.h>
#include <class/cl90f1.h>
#include <class/cla06c.h>
#include <class/clc361.h>
#include <ctrl/ctrl0000/ctrl0000client.h>
#include <ctrl/ctrl0000/ctrl0000gpu.h>
#include <ctrl/ctrl0000/ctrl0000unix.h>
#include <ctrl/ctrla06c.h>
#include <ctrl/ctrlc36f.h>
#include <ctrl/ctrl0041.h>
#include <ctrl/ctrl0080/ctrl0080gpu.h>
#include <ctrl/ctrl2080/ctrl2080bios.h>
#include <ctrl/ctrl2080/ctrl2080bus.h>
#include <ctrl/ctrl2080/ctrl2080fb.h>
#include <ctrl/ctrl2080/ctrl2080gpu.h>
#include <ctrl/ctrl2080/ctrl2080gr.h>
#include <ctrl/ctrl2080/ctrl2080gsp.h>
#include <ctrl/ctrl2080/ctrl2080mc.h>

#include "gpu_mock.h"
#include "gpu_rm.h"
#include "gpu_rm_ioctl.h"

/* The ioctl numbers are in gpu_rm_ioctl.h: the daemon numbers them the same
 * way, because it carries them over CUSE. */

/* The handle the RM picks when the client does not propose one. */
#define GPU_RM_HANDLE_BASE	0x2a000000u

/* ---- the engine's state --------------------------------------------------- */

enum gpu_rm_kind {
	GPU_RM_CLIENT = 1,
	GPU_RM_DEVICE,
	GPU_RM_SUBDEVICE,
	GPU_RM_CHANNEL_GROUP,
	GPU_RM_CHANNEL,
	GPU_RM_ENGINE,
	GPU_RM_MEMORY,
	GPU_RM_VASPACE,
	GPU_RM_USERMODE
};

struct gpu_rm_object {
	NvHandle	handle;
	NvU32		class;
	NvHandle	parent;
	unsigned	kind;
	unsigned	card;		/* the card, or GPU_RM_NO_CARD */
	uint64_t	size;		/* a memory object: its size */
	int		have_size;
};

	struct gpu_rm {
	const struct gpu_model *model;
	struct gpu_rm_object objects[GPU_RM_MAX_OBJECTS];
	unsigned	nobjects;
	NvHandle	next_handle;
	uint32_t	attached[NV_MAX_DEVICES];
	unsigned	nattached;
	/* How many times each scripted fault has fired. */
	unsigned	fault_count[GPU_RM_MAX_FAULTS];
	/* The memory the client mapped, by cookie. */
	struct {
		NvP64		cookie;
		uint64_t	bytes;
		int		used;
	} maps[GPU_RM_MAX_MAPS];
};

/* ---- helpers -------------------------------------------------------------- */

static const struct gpu_card *
card_of_gpu(struct gpu_rm *rm, uint32_t gpu_id)
{
	unsigned i;

	for (i = 0; i < rm->model->ncards; i++) {
		const struct gpu_card *c = &rm->model->cards[i];

		if (c->rm_gpu_id == gpu_id)
			return (c);
	}
	return (NULL);
}

/* 1 when a scripted fault of this kind fires now. */
static int
fault_fires(struct gpu_rm *rm, enum gpu_fault_kind kind, const char *card,
    const char *object)
{
	unsigned i;

	for (i = 0; i < rm->model->nfaults; i++) {
		const struct gpu_fault *f = &rm->model->faults[i];

		if (f->kind != kind)
			continue;
		if (f->card[0] != '\0' && card != NULL &&
		    strcmp(f->card, card) != 0)
			continue;
		if (f->object[0] != '\0' && object != NULL &&
		    strcmp(f->object, object) != 0)
			continue;
		rm->fault_count[i]++;
		if (f->nth == 0 || rm->fault_count[i] == f->nth)
			return (1);
	}
	return (0);
}

/* The card a fault names, or NULL when the fault names no card. */
static const char *
fault_card(struct gpu_rm *rm, enum gpu_fault_kind kind)
{
	unsigned i;

	for (i = 0; i < rm->model->nfaults; i++)
		if (rm->model->faults[i].kind == kind &&
		    rm->model->faults[i].card[0] != '\0')
			return (rm->model->faults[i].card);
	return (NULL);
}

/* The NVIDIA cards of the model, minus the ones a fault says are gone. */
static unsigned
live_cards(struct gpu_rm *rm, const struct gpu_card **cards, unsigned max)
{
	unsigned i, n = 0;

	for (i = 0; i < rm->model->ncards && n < max; i++) {
		const struct gpu_card *c = &rm->model->cards[i];
		unsigned p, v;

		for (p = 0; p < rm->model->nproviders; p++) {
			for (v = 0; v < rm->model->providers[p].nvendor_ids;
			    v++)
				if (rm->model->providers[p].vendor_ids[v] ==
				    c->vendor_id)
					break;
			if (v < rm->model->providers[p].nvendor_ids)
				break;
		}
		if (p >= rm->model->nproviders)
			continue;	/* not a card of a provider */
		if (fault_fires(rm, GPU_FAULT_DEVICE_LOST, c->name, NULL))
			continue;
		cards[n++] = c;
	}
	return (n);
}

/* The card an object belongs to: the device or subdevice under it. */
static unsigned
card_of_object(struct gpu_rm *rm, NvHandle handle)
{
	unsigned i;

	for (i = 0; i < rm->nobjects; i++)
		if (rm->objects[i].handle == handle)
			return (rm->objects[i].card);
	return (GPU_RM_NO_CARD);
}

/* The index of the card of a GPU id, or GPU_RM_NO_CARD. */
static unsigned
card_index_by_gpu_id(struct gpu_rm *rm, uint32_t gpu_id)
{
	unsigned i;

	for (i = 0; i < rm->model->ncards; i++)
		if (rm->model->cards[i].rm_gpu_id == gpu_id)
			return (i);
	return (GPU_RM_NO_CARD);
}

static struct gpu_rm_object *
find_object(struct gpu_rm *rm, NvHandle handle)
{
	unsigned i;

	for (i = 0; i < rm->nobjects; i++)
		if (rm->objects[i].handle == handle)
			return (&rm->objects[i]);
	return (NULL);
}

static int
add_object(struct gpu_rm *rm, NvHandle handle, NvU32 cls, NvHandle parent,
    unsigned kind, unsigned card, uint64_t size, int have_size)
{
	struct gpu_rm_object *o;

	if (rm->nobjects >= GPU_RM_MAX_OBJECTS) {
		errno = ENOMEM;
		return (-1);
	}
	o = &rm->objects[rm->nobjects++];
	memset(o, 0, sizeof(*o));
	o->handle = handle;
	o->class = cls;
	o->parent = parent;
	o->kind = kind;
	o->card = card;
	o->size = size;
	o->have_size = have_size;
	return (0);
}

/* ---- the ioctls ----------------------------------------------------------- */

struct gpu_rm *
gpu_rm_new(const struct gpu_model *model)
{
	struct gpu_rm *rm = calloc(1, sizeof(*rm));

	if (rm == NULL)
		return (NULL);
	rm->model = model;
	rm->next_handle = GPU_RM_HANDLE_BASE;
	return (rm);
}

void
gpu_rm_free(struct gpu_rm *rm)
{
	free(rm);
}

/* The card list of the RM: one entry per live card. */
static void
card_list(struct gpu_rm *rm, nv_ioctl_card_info_t *cards)
{
	const struct gpu_card *live[GPU_RM_MAX_CARDS];
	unsigned n, i;

	memset(cards, 0, sizeof(nv_ioctl_card_info_t) * NV_MAX_DEVICES);
	n = live_cards(rm, live, GPU_RM_MAX_CARDS);
	for (i = 0; i < n && i < NV_MAX_DEVICES; i++) {
		const struct gpu_card *c = live[i];

		cards[i].valid = NV_TRUE;
		cards[i].gpu_id = c->rm_gpu_id;
		cards[i].pci_info.domain = c->pci_domain;
		cards[i].pci_info.bus = c->pci_bus;
		cards[i].pci_info.slot = c->pci_slot;
		cards[i].pci_info.vendor_id = c->vendor_id;
		cards[i].pci_info.device_id = c->device_id;
		cards[i].interrupt_line = (NvU16)c->irq;
		cards[i].minor_number = i;
	}
}

/*
 * The GPUs attached to a descriptor.  The list has the RM's own size, so a
 * client that attaches more GPUs than the RM can hold gets the ones that
 * fit and no more: the list is never written past its end, whatever the
 * client sends.
 */
static void
attach_ids(struct gpu_rm *rm, const uint32_t *ids, unsigned n)
{
	unsigned i;

	for (i = 0; i < n && rm->nattached < NV_MAX_DEVICES; i++)
		rm->attached[rm->nattached++] = ids[i];
}

static int
do_check_version(struct gpu_rm *rm, nv_ioctl_rm_api_version_t *v)
{
	const char *want = rm->model->driver_version.string;

	if (v->cmd == NV_RM_API_VERSION_CMD_QUERY) {
		v->reply = NV_RM_API_VERSION_REPLY_RECOGNIZED;
		snprintf(v->versionString, sizeof(v->versionString), "%s", want);
		return (0);
	}
	if (v->cmd != NV_RM_API_VERSION_CMD_STRICT) {
		v->reply = NV_RM_API_VERSION_REPLY_UNRECOGNIZED;
		return (0);
	}
	/* The strict check: the RM must be the one the library speaks. */
	if (strcmp(v->versionString, want) != 0) {
		v->reply = NV_RM_API_VERSION_REPLY_UNRECOGNIZED;
		return (0);
	}
	v->reply = NV_RM_API_VERSION_REPLY_RECOGNIZED;
	snprintf(v->versionString, sizeof(v->versionString), "%s", want);
	return (0);
}

/* The kind of an object, from the class the client asks for. */
static unsigned
alloc_kind(NvU32 cls)
{
	if (cls == NV01_ROOT)
		return (GPU_RM_CLIENT);
	if (cls == NV01_DEVICE_0)
		return (GPU_RM_DEVICE);
	if (cls == NV20_SUBDEVICE_0)
		return (GPU_RM_SUBDEVICE);
	if (cls == KEPLER_CHANNEL_GROUP_A)
		return (GPU_RM_CHANNEL_GROUP);
	if (cls == NV50_MEMORY_VIRTUAL || cls == NV01_MEMORY_LOCAL_USER ||
	    cls == NV01_MEMORY_SYSTEM || cls == NV01_MEMORY_SYSTEM_OS_DESCRIPTOR)
		return (GPU_RM_MEMORY);
	if (cls == FERMI_VASPACE_A)
		return (GPU_RM_VASPACE);
	/* A channel or an engine: the class comes from the card. */
	return (GPU_RM_CHANNEL);
}

/* The allocation of one object. */
static int
do_alloc(struct gpu_rm *rm, NVOS21_PARAMETERS *p)
{
	const char *cardname = NULL;
	unsigned kind;
	unsigned card = GPU_RM_NO_CARD;
	uint64_t size = 0;
	int have_size = 0;
	NvHandle handle;

	kind = alloc_kind(p->hClass);
	if (kind == GPU_RM_CLIENT) {
		cardname = fault_card(rm, GPU_FAULT_ALLOC_REFUSED);
	} else if (p->hObjectParent != 0) {
		card = card_of_object(rm, p->hObjectParent);
	}
	/* A device handle belongs to the GPU that was attached: the RM gives
	 * the device to the first attached GPU. */
	if (card == GPU_RM_NO_CARD && kind == GPU_RM_DEVICE &&
	    rm->nattached > 0)
		card = card_index_by_gpu_id(rm, rm->attached[0]);
	if (card != GPU_RM_NO_CARD && card < rm->model->ncards)
		cardname = rm->model->cards[card].name;
	if (fault_fires(rm, GPU_FAULT_ALLOC_REFUSED, cardname, NULL)) {
		p->status = NV_ERR_INSUFFICIENT_RESOURCES;
		return (0);
	}
	if (kind == GPU_RM_MEMORY && p->paramsSize > 0 &&
	    p->pAllocParms != 0) {
		/* The size of a memory object is in its parameters. */
		NV_MEMORY_ALLOCATION_PARAMS *mp =
		    (NV_MEMORY_ALLOCATION_PARAMS *)(uintptr_t)p->pAllocParms;

		size = mp->size;
		have_size = 1;
	}
	handle = p->hObjectNew;
	if (handle == 0) {
		handle = rm->next_handle++;
		p->hObjectNew = handle;
	}
	if (add_object(rm, handle, p->hClass, p->hObjectParent, kind, card,
	    size, have_size) != 0) {
		p->status = NV_ERR_INSUFFICIENT_RESOURCES;
		return (0);
	}
	p->status = NV_OK;
	return (0);
}

static int
do_free(struct gpu_rm *rm, NVOS00_PARAMETERS *p)
{
	unsigned i;

	for (i = 0; i < rm->nobjects; i++) {
		if (rm->objects[i].handle != p->hObjectOld)
			continue;
		/* The objects under it go with it. */
		for (unsigned j = rm->nobjects; j > i + 1; j--)
			if (rm->objects[j - 1].parent == p->hObjectOld) {
				rm->objects[j - 1] =
				    rm->objects[rm->nobjects - 1];
				rm->nobjects--;
				j--;
			}
		rm->objects[i] = rm->objects[rm->nobjects - 1];
		rm->nobjects--;
		p->status = NV_OK;
		return (0);
	}
	p->status = NV_ERR_OBJECT_NOT_FOUND;
	return (0);
}

/* ---- the controls --------------------------------------------------------- */

static void
fill_info_entry(NVXXXX_CTRL_XXX_INFO *entry, unsigned index, uint64_t data)
{
	memset(entry, 0, sizeof(*entry));
	entry->index = index;
	entry->data = data;
}

/* The card of the object a control names, or NULL when there is none. */
static const struct gpu_card *
card_of_handle(struct gpu_rm *rm, NvHandle handle)
{
	unsigned card = card_of_object(rm, handle);

	if (card >= rm->model->ncards)
		return (NULL);
	return (&rm->model->cards[card]);
}

/* The card of the object a control names, when the card has a base. */
static const struct gpu_card *
card_base_of_handle(struct gpu_rm *rm, NvHandle handle)
{
	const struct gpu_card *c = card_of_handle(rm, handle);

	if (c == NULL || c->base == NULL)
		return (NULL);
	return (c);
}

/* The card of the object a control names, or NULL when there is none. */
static const struct gpu_card *
ctrl_card(struct gpu_rm *rm, NVOS54_PARAMETERS *p)
{
	return (card_of_handle(rm, p->hObject));
}

/* The card of the object a control names, when the card has a base. */
static const struct gpu_card *
ctrl_base_card(struct gpu_rm *rm, NVOS54_PARAMETERS *p)
{
	return (card_base_of_handle(rm, p->hObject));
}

/* The answer of a control that names no object: there is no such object. */
static int
ctrl_no_object(NVOS54_PARAMETERS *p)
{
	p->status = NV_ERR_OBJECT_NOT_FOUND;
	return (0);
}

/* The answer of a control the mock does not know. */
static int
ctrl_not_supported(NVOS54_PARAMETERS *p)
{
	p->status = NV_ERR_NOT_SUPPORTED;
	return (0);
}

/* The answer of a control that went well. */
static int
ctrl_ok(NVOS54_PARAMETERS *p)
{
	p->status = NV_OK;
	return (0);
}

/* The answer of a control with an info list: its one entry and its status. */
static int
ctrl_info_entry(NVOS54_PARAMETERS *p, NVXXXX_CTRL_XXX_INFO *entry,
    unsigned index, uint64_t data)
{
	fill_info_entry(entry, index, data);
	p->status = NV_OK;
	return (0);
}

/*
 * The controls that answer from the card of an object: the parameters of
 * the control and the card itself.
 */
#define CTRL_CARD(type, helper)						\
	type *q = p->params;						\
	const struct gpu_card *c = helper(rm, p);

/*
 * The controls that answer with an info list: the parameters of the
 * control, the index the client asked for and the value that goes with it.
 */
#define CTRL_INFO(type, field)						\
	type *q = p->params;						\
	unsigned index = q->field[0].index;				\
	uint64_t data = 0;						\
	const struct gpu_card *c = ctrl_card(rm, p);

/* The probed GPUs: the list ends with the invalid id, as the RM's does. */
static int
ctrl_probed_ids(struct gpu_rm *rm, NVOS54_PARAMETERS *p)
{
	NV0000_CTRL_GPU_GET_PROBED_IDS_PARAMS *q = p->params;
	const struct gpu_card *live[GPU_RM_MAX_CARDS];
	unsigned nlive, i;

	memset(q, 0, sizeof(*q));
	for (i = 0; i < NV0000_CTRL_GPU_MAX_PROBED_GPUS; i++)
		q->gpuIds[i] = NV0000_CTRL_GPU_INVALID_ID;
	nlive = live_cards(rm, live, GPU_RM_MAX_CARDS);
	for (i = 0; i < nlive && i < NV0000_CTRL_GPU_MAX_PROBED_GPUS; i++)
		q->gpuIds[i] = live[i]->rm_gpu_id;
	return (ctrl_ok(p));
}

/* The attach: every GPU that is listed is attached. */
static int
ctrl_attach_ids(struct gpu_rm *rm, NVOS54_PARAMETERS *p)
{
	NV0000_CTRL_GPU_ATTACH_IDS_PARAMS *q = p->params;
	const struct gpu_card *live[GPU_RM_MAX_CARDS];
	unsigned nlive, i;

	memset(q, 0, sizeof(*q));
	for (i = 0; i < NV0000_CTRL_GPU_MAX_PROBED_GPUS; i++)
		q->gpuIds[i] = NV0000_CTRL_GPU_INVALID_ID;
	nlive = live_cards(rm, live, GPU_RM_MAX_CARDS);
	for (i = 0; i < nlive; i++) {
		q->gpuIds[i] = live[i]->rm_gpu_id;
		attach_ids(rm, &live[i]->rm_gpu_id, 1);
	}
	q->failedId = NV0000_CTRL_GPU_INVALID_ID;
	return (ctrl_ok(p));
}

/* The identity of a GPU. */
static int
ctrl_id_info(struct gpu_rm *rm, NVOS54_PARAMETERS *p)
{
	NV0000_CTRL_GPU_GET_ID_INFO_V2_PARAMS *q = p->params;
	const struct gpu_card *c = card_of_gpu(rm, q->gpuId);

	if (c == NULL)
		return (ctrl_no_object(p));
	memset(q, 0, sizeof(*q));
	q->gpuId = c->rm_gpu_id;
	q->deviceInstance = 0x00000001u;
	q->subDeviceInstance = 0x00000001u;
	q->gpuFlags = c->caps[GPU_CAP_SOC] ?
	    DRF_NUM(0000, _CTRL_GPU_ID_INFO, _SOC, 1) : 0;
	q->numaId = NV0000_CTRL_NO_NUMA_NODE;
	return (ctrl_ok(p));
}

/* The class list of a GPU: the classes of its base. */
static int
ctrl_classlist(struct gpu_rm *rm, NVOS54_PARAMETERS *p)
{
	CTRL_CARD(NV0080_CTRL_GPU_GET_CLASSLIST_V2_PARAMS, ctrl_base_card);
	unsigned i;

	if (c == NULL)
		return (ctrl_no_object(p));
	memset(q, 0, sizeof(*q));
	q->numClasses = c->base->nclasses;
	for (i = 0; i < c->base->nclasses &&
	    i < NV0080_CTRL_GPU_CLASSLIST_MAX_SIZE; i++)
		q->classList[i] = (NvU32)c->base->classes[i];
	return (ctrl_ok(p));
}

/* The architecture and the implementation of a GPU. */
static int
ctrl_arch_info(struct gpu_rm *rm, NVOS54_PARAMETERS *p)
{
	CTRL_CARD(NV2080_CTRL_MC_GET_ARCH_INFO_PARAMS, ctrl_base_card);

	if (c == NULL)
		return (ctrl_no_object(p));
	memset(q, 0, sizeof(*q));
	q->architecture = c->base->architecture;
	q->implementation = c->base->implementation;
	return (ctrl_ok(p));
}

/* One entry of the info list of the GPCs. */
static int
ctrl_gr_info(struct gpu_rm *rm, NVOS54_PARAMETERS *p)
{
	NV2080_CTRL_GR_GET_INFO_V2_PARAMS *q = p->params;
	const struct gpu_card *c = ctrl_base_card(rm, p);
	unsigned index = q->grInfoList[0].index;
	uint64_t data = 0;

	if (c == NULL)
		return (ctrl_no_object(p));
	memset(q, 0, sizeof(*q));
	q->grInfoListSize = 1;
	if (index == NV2080_CTRL_GR_INFO_INDEX_SM_VERSION)
		data = ((uint64_t)c->base->sm_version.major << 8) |
		    c->base->sm_version.minor;
	else if (index == NV2080_CTRL_GR_INFO_INDEX_LITTER_NUM_SM_PER_TPC)
		data = c->base->sm_per_tpc;
	return (ctrl_info_entry(p, &q->grInfoList[0], index, data));
}

/* The mask of the enabled GPCs. */
static int
ctrl_gpc_mask(struct gpu_rm *rm, NVOS54_PARAMETERS *p)
{
	CTRL_CARD(NV2080_CTRL_GR_GET_GPC_MASK_PARAMS, ctrl_base_card);

	if (c == NULL)
		return (ctrl_no_object(p));
	memset(q, 0, sizeof(*q));
	q->gpcMask = c->base->gpc_mask;
	return (ctrl_ok(p));
}

/* The mask of the TPCs of one GPC. */
static int
ctrl_tpc_mask(struct gpu_rm *rm, NVOS54_PARAMETERS *p)
{
	CTRL_CARD(NV2080_CTRL_GR_GET_TPC_MASK_PARAMS, ctrl_base_card);
	/* The client names the GPC it asks about: keep it. */
	uint32_t gpcId = q->gpcId;

	if (c == NULL)
		return (ctrl_no_object(p));
	memset(q, 0, sizeof(*q));
	q->gpcId = gpcId;
	q->tpcMask = gpcId < GPU_RM_MAX_GPCS &&
	    gpcId < c->base->ntpc_masks ?
	    c->base->tpc_masks[gpcId] : 0;
	return (ctrl_ok(p));
}

/* One entry of the info list of the GPU: the capability it names. */
static int
ctrl_gpu_info(struct gpu_rm *rm, NVOS54_PARAMETERS *p)
{
	CTRL_INFO(NV2080_CTRL_GPU_GET_INFO_V2_PARAMS, gpuInfoList);
	if (c == NULL)
		return (ctrl_no_object(p));
	memset(q, 0, sizeof(*q));
	q->gpuInfoListSize = 1;
	switch (index) {
	case NV2080_CTRL_GPU_INFO_INDEX_DMABUF_CAPABILITY:
		data = c->caps[GPU_CAP_DMABUF_EXPORT];
		break;
	case NV2080_CTRL_GPU_INFO_INDEX_GPU_ATS_CAPABILITY:
		data = c->caps[GPU_CAP_ATS];
		break;
	case NV2080_CTRL_GPU_INFO_INDEX_GPU_SELF_HOSTED_CAPABILITY:
		data = c->caps[GPU_CAP_SELF_HOSTED];
		break;
	case NV2080_CTRL_GPU_INFO_INDEX_DISPLAY_ENABLED:
		data = c->caps[GPU_CAP_DISPLAY_ENABLED];
		break;
	case NV2080_CTRL_GPU_INFO_INDEX_COHERENT_GPU_MEMORY_MODE:
		data = c->caps[GPU_CAP_COHERENT_GPU_MEMORY] ?
		    NV2080_CTRL_GPU_INFO_INDEX_COHERENT_GPU_MEMORY_MODE_NONE
		    + 1 : 0;
		break;
	default:
		data = 0;
		break;
	}
	return (ctrl_info_entry(p, &q->gpuInfoList[0], index, data));
}

/* One entry of the info list of the frame buffer: its size in KiB. */
static int
ctrl_fb_info(struct gpu_rm *rm, NVOS54_PARAMETERS *p)
{
	CTRL_INFO(NV2080_CTRL_FB_GET_INFO_V2_PARAMS, fbInfoList);
	if (c == NULL)
		return (ctrl_no_object(p));
	memset(q, 0, sizeof(*q));
	q->fbInfoListSize = 1;
	/*
	 * The RM's info entry carries 32 bits (NVXXXX_CTRL_XXX_INFO),
	 * so the sizes are in KiB, as the RM reports them.
	 */
	if (index == NV2080_CTRL_FB_INFO_INDEX_RAM_SIZE)
		data = c->vram_bytes / 1024;
	else if (index == NV2080_CTRL_FB_INFO_INDEX_BAR1_SIZE)
		data = c->bar1_bytes / 1024;
	return (ctrl_info_entry(p, &q->fbInfoList[0], index, data));
}

/* One entry of the info list of the BIOS: its revision. */
static int
ctrl_bios_info(struct gpu_rm *rm, NVOS54_PARAMETERS *p)
{
	CTRL_INFO(NV2080_CTRL_BIOS_GET_INFO_V2_PARAMS, biosInfoList);
	if (c == NULL)
		return (ctrl_no_object(p));
	memset(q, 0, sizeof(*q));
	q->biosInfoListSize = 1;
	if (index == NV2080_CTRL_BIOS_INFO_INDEX_REVISION)
		data = c->base->bios_revision;
	else if (index == NV2080_CTRL_BIOS_INFO_INDEX_OEM_REVISION)
		data = c->base->bios_oem_revision;
	return (ctrl_info_entry(p, &q->biosInfoList[0], index, data));
}

/* The PCI identity of a GPU. */
static int
ctrl_pci_info(struct gpu_rm *rm, NVOS54_PARAMETERS *p)
{
	CTRL_CARD(NV2080_CTRL_BUS_GET_PCI_INFO_PARAMS, ctrl_card);

	if (c == NULL)
		return (ctrl_no_object(p));
	memset(q, 0, sizeof(*q));
	q->pciDeviceId = (uint32_t)c->vendor_id |
	    ((uint32_t)c->device_id << 16);
	q->pciSubSystemId = (uint32_t)c->subsystem_vendor_id |
	    ((uint32_t)c->subsystem_device_id << 16);
	q->pciRevisionId = c->revision;
	return (ctrl_ok(p));
}

/* The identity of a GPU: the uuid of the model. */
static int
ctrl_gid_info(struct gpu_rm *rm, NVOS54_PARAMETERS *p)
{
	CTRL_CARD(NV2080_CTRL_GPU_GET_GID_INFO_PARAMS, ctrl_card);

	if (c == NULL)
		return (ctrl_no_object(p));
	memset(q, 0, sizeof(*q));
	q->flags = DRF_DEF(2080_GPU_CMD, _GPU_GET_GID_FLAGS, _FORMAT,
	    _ASCII) | DRF_DEF(2080_GPU_CMD, _GPU_GET_GID_FLAGS, _TYPE,
	    _SHA1);
	snprintf((char *)q->data, sizeof(q->data), "%s", c->uuid);
	return (ctrl_ok(p));
}

/* The largest page size a GPU supports. */
static int
ctrl_max_page_size(struct gpu_rm *rm, NVOS54_PARAMETERS *p)
{
	CTRL_CARD(NV2080_CTRL_GPU_GET_MAX_SUPPORTED_PAGE_SIZE_PARAMS,
	    ctrl_card);

	if (c == NULL)
		return (ctrl_no_object(p));
	memset(q, 0, sizeof(*q));
	q->maxSupportedPageSize = c->max_page_size;
	return (ctrl_ok(p));
}

/* The features of the GSP: the firmware of the base. */
static int
ctrl_gsp_features(struct gpu_rm *rm, NVOS54_PARAMETERS *p)
{
	CTRL_CARD(NV2080_CTRL_GSP_GET_FEATURES_PARAMS, ctrl_card);

	if (c == NULL)
		return (ctrl_no_object(p));
	memset(q, 0, sizeof(*q));
	q->bValid = NV_TRUE;
	snprintf((char *)q->firmwareVersion,
	    sizeof(q->firmwareVersion), "%s",
	    c->base->firmware_version);
	return (ctrl_ok(p));
}

/* The address space of a client: the system memory. */
static int
ctrl_addr_space(struct gpu_rm *rm, NVOS54_PARAMETERS *p)
{
	NV0000_CTRL_CLIENT_GET_ADDR_SPACE_TYPE_PARAMS *q = p->params;

	memset(q, 0, sizeof(*q));
	q->addrSpaceType = NV0000_CTRL_CMD_CLIENT_GET_ADDR_SPACE_TYPE_SYSMEM;
	return (ctrl_ok(p));
}

/* The work submit token: the one the mock hands out. */
static int
ctrl_submit_token(struct gpu_rm *rm, NVOS54_PARAMETERS *p)
{
	NVC36F_CTRL_CMD_GPFIFO_GET_WORK_SUBMIT_TOKEN_PARAMS *q = p->params;

	memset(q, 0, sizeof(*q));
	q->workSubmitToken = GPU_RM_SUBMIT_TOKEN;
	return (ctrl_ok(p));
}

/* The schedule of the GPFIFO: nothing to schedule in a mock. */
static int
ctrl_gpfifo_schedule(struct gpu_rm *rm, NVOS54_PARAMETERS *p)
{
	NVA06C_CTRL_GPFIFO_SCHEDULE_PARAMS *q = p->params;

	memset(q, 0, sizeof(*q));
	return (ctrl_ok(p));
}

/* The controls the mock answers, and the handler of each. */
struct ctrl_handler {
	NvV32	cmd;
	int	(*run)(struct gpu_rm *rm, NVOS54_PARAMETERS *p);
};

static const struct ctrl_handler ctrl_handlers[] = {
	{ NV0000_CTRL_CMD_GPU_GET_PROBED_IDS, ctrl_probed_ids },
	{ NV0000_CTRL_CMD_GPU_ATTACH_IDS, ctrl_attach_ids },
	{ NV0000_CTRL_CMD_GPU_GET_ID_INFO_V2, ctrl_id_info },
	{ NV0080_CTRL_CMD_GPU_GET_CLASSLIST_V2, ctrl_classlist },
	{ NV2080_CTRL_CMD_MC_GET_ARCH_INFO, ctrl_arch_info },
	{ NV2080_CTRL_CMD_GR_GET_INFO_V2, ctrl_gr_info },
	{ NV2080_CTRL_CMD_GR_GET_GPC_MASK, ctrl_gpc_mask },
	{ NV2080_CTRL_CMD_GR_GET_TPC_MASK, ctrl_tpc_mask },
	{ NV2080_CTRL_CMD_GPU_GET_INFO_V2, ctrl_gpu_info },
	{ NV2080_CTRL_CMD_FB_GET_INFO_V2, ctrl_fb_info },
	{ NV2080_CTRL_CMD_BIOS_GET_INFO_V2, ctrl_bios_info },
	{ NV2080_CTRL_CMD_BUS_GET_PCI_INFO, ctrl_pci_info },
	{ NV2080_CTRL_CMD_GPU_GET_GID_INFO, ctrl_gid_info },
	{ NV2080_CTRL_CMD_GPU_GET_MAX_SUPPORTED_PAGE_SIZE,
	    ctrl_max_page_size },
	{ NV2080_CTRL_CMD_GSP_GET_FEATURES, ctrl_gsp_features },
	{ NV0000_CTRL_CMD_CLIENT_GET_ADDR_SPACE_TYPE, ctrl_addr_space },
	{ NVC36F_CTRL_CMD_GPFIFO_GET_WORK_SUBMIT_TOKEN, ctrl_submit_token },
	{ NVA06C_CTRL_CMD_GPFIFO_SCHEDULE, ctrl_gpfifo_schedule },
	{ 0, NULL }
};

static int
do_control(struct gpu_rm *rm, NVOS54_PARAMETERS *p)
{
	const struct ctrl_handler *h;

	for (h = ctrl_handlers; h->cmd != 0; h++)
		if (h->cmd == p->cmd)
			return (h->run(rm, p));
	return (ctrl_not_supported(p));
}

/* ---- the map and unmap ---------------------------------------------------- */

/*
 * The mapping of one memory object.  The mock has no BAR to map, so it
 * hands out a cookie: the address the RM would have given, made of the
 * index of the mapping.
 */
static int
do_map_memory(struct gpu_rm *rm, nv_ioctl_nvos33_parameters_with_fd *p)
{
	unsigned i;

	if (p->params.hMemory != 0 &&
	    find_object(rm, p->params.hMemory) == NULL) {
		p->params.status = NV_ERR_OBJECT_NOT_FOUND;
		return (0);
	}
	for (i = 0; i < sizeof(rm->maps) / sizeof(rm->maps[0]); i++) {
		if (rm->maps[i].used)
			continue;
		rm->maps[i].used = 1;
		rm->maps[i].cookie =
		    (NvP64)(uintptr_t)(GPU_RM_MAP_COOKIE_BASE + i);
		rm->maps[i].bytes = p->params.length;
		p->params.pLinearAddress = rm->maps[i].cookie;
		p->params.status = NV_OK;
		return (0);
	}
	p->params.status = NV_ERR_INSUFFICIENT_RESOURCES;
	return (0);
}

static int
do_unmap_memory(struct gpu_rm *rm, NVOS34_PARAMETERS *p)
{
	unsigned i;

	for (i = 0; i < sizeof(rm->maps) / sizeof(rm->maps[0]); i++)
		if (rm->maps[i].used && rm->maps[i].cookie == p->pLinearAddress) {
			rm->maps[i].used = 0;
			p->status = NV_OK;
			return (0);
		}
	p->status = NV_ERR_OBJECT_NOT_FOUND;
	return (0);
}

/* ---- the dispatch --------------------------------------------------------- */

int
gpu_rm_ioctl(struct gpu_rm *rm, unsigned long cmd, void *arg)
{
	unsigned long nr = cmd;

	if (rm == NULL || arg == NULL) {
		errno = EINVAL;
		return (-1);
	}
	if (fault_fires(rm, GPU_FAULT_IOCTL_FAILED, NULL, NULL)) {
		errno = EIO;
		return (-1);
	}
	switch (nr) {
	case IOC_CHECK_VERSION:
		return (do_check_version(rm, arg));
	case IOC_XFER: {
		nv_ioctl_xfer_t *x = arg;

		if (x->cmd != NV_ESC_CARD_INFO) {
			errno = EINVAL;
			return (-1);
		}
		if (x->size != sizeof(nv_ioctl_card_info_t) * NV_MAX_DEVICES ||
		    x->ptr == 0) {
			errno = EINVAL;
			return (-1);
		}
		card_list(rm, (nv_ioctl_card_info_t *)(uintptr_t)x->ptr);
		return (0);
	}
	case IOC_RM_ALLOC:
		return (do_alloc(rm, arg));
	case IOC_RM_CONTROL:
		return (do_control(rm, arg));
	case IOC_RM_FREE:
		return (do_free(rm, arg));
	case IOC_MAP_MEMORY:
		return (do_map_memory(rm, arg));
	case IOC_UNMAP_MEMORY:
		return (do_unmap_memory(rm, arg));
	default:
		break;
	}
	/* The attach ioctl: its size is the number of GPUs. */
	if ((nr & 0xff) == NV_ESC_ATTACH_GPUS_TO_FD &&
	    IOCGROUP(nr) == NV_IOCTL_MAGIC) {
		unsigned long len = IOCPARM_LEN(nr);
		uint32_t *ids = arg;
		unsigned n;

		if (len % sizeof(uint32_t) != 0) {
			errno = EINVAL;
			return (-1);
		}
		n = len / sizeof(uint32_t);
		if (n > NV_MAX_DEVICES) {
			/* More GPUs than the RM can attach: refused, so the
			 * list is never written past its end. */
			errno = EINVAL;
			return (-1);
		}
		attach_ids(rm, ids, n);
		return (0);
	}
	errno = ENOTTY;
	return (-1);
}

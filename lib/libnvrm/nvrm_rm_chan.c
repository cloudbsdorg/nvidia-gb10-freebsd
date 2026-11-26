/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * nvrm_rm_chan.c - the RM backend's channel operations (Track #2437).  It
 * talks to the RM and nothing else: no DRM, no interface of another
 * operating system.
 *
 * One channel is:
 *
 *   a channel group (one per channel, the parent of the channel) that
 *   names the engine of the runlist,
 *   the channel itself, of the GPFIFO class, with the ring the core
 *   allocated and mapped for the GPU,
 *   one engine object per engine the mask asks for, under the channel,
 *   a userd page in system memory (4 KiB) that the GPU reads and the CPU
 *   writes: the GPFIFO control words (the get and the put offsets) are in
 *   it,
 *   an error notifier page in system memory, read-only for the CPU: the
 *   RM writes the channel's error there.
 *
 * The usermode object of the client (under a subdevice of the device) is
 * the only device mapping the backend makes: the doorbell is one aligned
 * 32-bit store of the work submit token in it.
 *
 * The class of every part is the first of its candidates the device lists
 * (nvrm_rm.c holds the classes; this file names no chip).  The client asks
 * for the class list once and keeps it.
 */
#include <sys/param.h>

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <nvtypes.h>
#include <nvstatus.h>
#include <nvos.h>
#include <nvgputypes.h>
#include <alloc/alloc_channel.h>
#include <class/cl2080_notification.h>
#include <class/clc361.h>
#include <ctrl/ctrl0080/ctrl0080gpu.h>
#include <ctrl/ctrlc36f.h>
#include <ctrl/ctrla06c.h>

#include "nvrm_internal.h"
#include "nvrm_rm_priv.h"

/* The GPFIFO control words of the channel, in the userd page: the get and
 * the put offsets.  The control structure of the GPFIFO class has them at
 * these offsets (the same in both classes the backend binds). */
#define GP_GET_OFF	0x88
#define GP_PUT_OFF	0x8c

/* A page of system memory: the userd page and the error notifier. */
#define PAGE_BYTES	4096ULL

/* The engines the mask asks for, and the class slot of each: the slots
 * are the subchannels in the RM's own order. */
static const struct {
	uint32_t	mask;	/* NVRM_ENG_* */
	unsigned	slot;	/* NVRM_RM_CLS_* */
	const char	*name;
} engine_tab[] = {
	{ NVRM_ENG_3D, NVRM_RM_CLS_3D, "3D" },
	{ NVRM_ENG_COMPUTE, NVRM_RM_CLS_COMPUTE, "compute" },
	{ NVRM_ENG_I2M, NVRM_RM_CLS_I2M, "I2M" },
	{ NVRM_ENG_2D, NVRM_RM_CLS_2D, "2D" },
	{ NVRM_ENG_COPY, NVRM_RM_CLS_COPY, "copy" }
};

/* What the backend holds of one channel. */
struct nvrm_bchan {
	nvrm_bclient	*c;
	NvHandle	tsg, chan;	/* the group and the channel */
	NvHandle	eng[8];		/* one per engine slot */
	nvrm_bmem	*userd, *notif;
	void		*userd_cpu, *notif_cpu;
	int		userd_fd, notif_fd;
	uint32_t	token, last_get;
};

/* ---- the client ---------------------------------------------------------- */

/* The classes the device lists: the RM's answer, asked once per client. */
static int
fetch_classes(nvrm_bclient *c, char *err, size_t errlen)
{
	NV0080_CTRL_GPU_GET_CLASSLIST_V2_PARAMS p;
	unsigned i;
	NvU32 st;

	memset(&p, 0, sizeof(p));
	st = nvrm_rm_control(c->s, c->device,
	    NV0080_CTRL_CMD_GPU_GET_CLASSLIST_V2, &p, sizeof(p));
	if (st != NV_OK)
		return (nvrm_rmm_status_fail(err, errlen,
		    "NV0080_CTRL_CMD_GPU_GET_CLASSLIST_V2", st));
	c->nclasses = p.numClasses;
	if (c->nclasses > nitems(c->classes))
		c->nclasses = nitems(c->classes);
	/* Time: O(the classes the device lists).  Space: O(1). */
	for (i = 0; i < c->nclasses; i++)
		c->classes[i] = p.classList[i];
	return (NVRM_OK);
}

/* The usermode page: the only device mapping the backend makes.  The
 * doorbell is one aligned store in it. */
static int
map_usermode(nvrm_bclient *c, char *err, size_t errlen)
{
	struct nvrm_rm_map map;
	int rc;

	c->usermode_fd = -1;
	rc = nvrm_rm_mem_ops.desc_open(c, NVRM_DESC_MAP, &c->usermode_fd, err,
	    errlen);
	if (rc != NVRM_OK)
		return (rc);
	rc = nvrm_rmm_map_handle(c, c->usermode, NVC361_NV_USERMODE__SIZE,
	    NVRM_CPU_READ | NVRM_CPU_WRITE, c->usermode_fd, &map, err, errlen);
	if (rc != NVRM_OK)
		return (rc);
	c->usermode_cpu = map.addr;
	c->usermode_cookie = map.cookie;
	return (NVRM_OK);
}

/* What the client needs before the first channel: the class list of the
 * device, a subdevice of it and the usermode object under that. */
static int
client_init(nvrm_bclient *c, char *err, size_t errlen)
{
	int rc;

	if (!c->have_classes) {
		rc = fetch_classes(c, err, errlen);
		if (rc != NVRM_OK)
			return (rc);
		c->have_classes = 1;
	}
	if (c->usermode != 0)
		return (NVRM_OK);
	rc = nvrm_rm_usermode_alloc(c, err, errlen);
	if (rc != NVRM_OK)
		return (rc);
	rc = map_usermode(c, err, errlen);
	if (rc != NVRM_OK)
		return (rc);
	return (NVRM_OK);
}

/* ---- the channel --------------------------------------------------------- */

/* The engine the group is for: the runlist's own engine. */
static uint32_t
engine_type(uint32_t runlist)
{
	return (runlist == NVRM_RUNLIST_COPY ? NV2080_ENGINE_TYPE_COPY0 :
	    NV2080_ENGINE_TYPE_GRAPHICS);
}

/* The classes the mask asks for: the first candidate of each slot the
 * device lists.  An engine the device has no class for is refused. */
static int
pick_class(nvrm_bchan *b, const nvrm_bchan_cfg *cfg, nvrm_bchan_info *out,
    char *err, size_t errlen)
{
	unsigned i;
	uint32_t cls;

	cls = nvrm_rm_chan_class(b->c, NVRM_RM_CLS_GPFIFO);
	if (cls == 0) {
		snprintf(err, errlen, "class for gpfifo not in the class list");
		return (NVRM_E_NOTSUP);
	}
	out->cls_gpfifo = cls;
	/* Time: O(the engines the mask asks for).  Space: O(1). */
	for (i = 0; i < nitems(engine_tab); i++) {
		if ((cfg->engines & engine_tab[i].mask) == 0)
			continue;
		cls = nvrm_rm_chan_class(b->c, engine_tab[i].slot);
		if (cls == 0) {
			snprintf(err, errlen, "class for %s not in the class "
			    "list", engine_tab[i].name);
			return (NVRM_E_NOTSUP);
		}
		out->subch_class[engine_tab[i].slot] = cls;
	}
	return (NVRM_OK);
}

/* A page of system memory the GPU reads: the userd page of the channel or
 * the error notifier.  The page is mapped on a descriptor of its own. */
static int
alloc_page(nvrm_bchan *b, nvrm_bmem **mp, int *fdp, void **cp, unsigned prot,
    char *err, size_t errlen)
{
	nvrm_balloc a;
	nvrm_bmem_info bi;
	int fd, rc;

	memset(&a, 0, sizeof(a));
	a.kind = NVRM_MEM_SYSMEM;
	a.place = NVRM_PLACE_SYSMEM;
	a.bytes = PAGE_BYTES;
	a.page_size = PAGE_BYTES;
	rc = nvrm_rm_mem_ops.mem_alloc(b->c, &a, mp, &bi, err, errlen);
	if (rc != NVRM_OK)
		return (rc);
	rc = nvrm_rm_mem_ops.desc_open(b->c, NVRM_DESC_MAP, &fd, err, errlen);
	if (rc != NVRM_OK)
		return (rc);
	rc = nvrm_rm_mem_ops.map_cpu(*mp, fd, prot, cp, err, errlen);
	if (rc != NVRM_OK) {
		close(fd);
		return (rc);
	}
	*fdp = fd;
	return (NVRM_OK);
}
/* The channel group: one per channel, the parent of the channel. */
static int
alloc_tsg(nvrm_bchan *b, uint32_t engine, char *err, size_t errlen)
{
	NV_CHANNEL_GROUP_ALLOCATION_PARAMETERS p;
	NvU32 st;

	memset(&p, 0, sizeof(p));
	p.hObjectError = nvrm_rmm_handle(b->notif);
	p.hObjectEccError = 0;
	p.hVASpace = b->c->vaspace;
	p.engineType = engine;
	b->tsg = nvrm_rm_new_handle(b->c->s);
	st = nvrm_rm_alloc(b->c->s, b->c->device, &b->tsg,
	    nvrm_rm_chan_group_class(), &p, sizeof(p));
	if (st != NV_OK) {
		b->tsg = 0;
		return (nvrm_rmm_status_fail(err, errlen,
		    "the channel group allocation", st));
	}
	return (NVRM_OK);
}

/* The channel itself: the GPFIFO object under the group, with the ring
 * the core mapped for the GPU and the userd page it reads. */
static int
alloc_channel(nvrm_bchan *b, const nvrm_bchan_cfg *cfg, uint32_t engine,
    char *err, size_t errlen)
{
	NV_CHANNEL_ALLOC_PARAMS p;
	NvU32 st;

	memset(&p, 0, sizeof(p));
	p.hObjectError = nvrm_rmm_handle(b->notif);
	p.gpFifoOffset = cfg->ring_va;
	p.gpFifoEntries = cfg->entries;
	p.hVASpace = b->c->vaspace;
	p.hUserdMemory[0] = nvrm_rmm_handle(b->userd);
	p.userdOffset[0] = 0;
	p.engineType = engine;
	b->chan = nvrm_rm_new_handle(b->c->s);
	st = nvrm_rm_alloc(b->c->s, b->tsg, &b->chan,
	    nvrm_rm_chan_class(b->c, NVRM_RM_CLS_GPFIFO), &p, sizeof(p));
	if (st != NV_OK) {
		b->chan = 0;
		return (nvrm_rmm_status_fail(err, errlen,
		    "the channel allocation", st));
	}
	return (NVRM_OK);
}

/* The engine objects: one per engine the mask asks for, under the
 * channel.  Their own parameters are not in the headers this library
 * uses, so they are allocated without any. */
static int
alloc_engines(nvrm_bchan *b, const nvrm_bchan_cfg *cfg, char *err,
    size_t errlen)
{
	unsigned i;
	NvU32 st;

	/* Time: O(the engines the mask asks for).  Space: O(1). */
	for (i = 0; i < nitems(engine_tab); i++) {
		if ((cfg->engines & engine_tab[i].mask) == 0)
			continue;
		b->eng[engine_tab[i].slot] = nvrm_rm_new_handle(b->c->s);
		st = nvrm_rm_alloc(b->c->s, b->chan, &b->eng[engine_tab[i].slot],
		    nvrm_rm_chan_class(b->c, engine_tab[i].slot), NULL, 0);
		if (st != NV_OK) {
			b->eng[engine_tab[i].slot] = 0;
			return (nvrm_rmm_status_fail(err, errlen,
			    "the engine object allocation", st));
		}
	}
	return (NVRM_OK);
}

/* The work submit token of the channel: the value the doorbell rings
 * with. */
static int
get_token(nvrm_bchan *b, char *err, size_t errlen)
{
	NVC36F_CTRL_CMD_GPFIFO_GET_WORK_SUBMIT_TOKEN_PARAMS p;
	NvU32 st;

	memset(&p, 0, sizeof(p));
	st = nvrm_rm_control(b->c->s, b->chan,
	    NVC36F_CTRL_CMD_GPFIFO_GET_WORK_SUBMIT_TOKEN, &p, sizeof(p));
	if (st != NV_OK)
		return (nvrm_rmm_status_fail(err, errlen,
		    "NVC36F_CTRL_CMD_GPFIFO_GET_WORK_SUBMIT_TOKEN", st));
	b->token = p.workSubmitToken;
	return (NVRM_OK);
}

/* Enable the group: the RM starts the channel's engines on it. */
static int
schedule(nvrm_bchan *b, char *err, size_t errlen)
{
	NVA06C_CTRL_GPFIFO_SCHEDULE_PARAMS p;
	NvU32 st;

	memset(&p, 0, sizeof(p));
	p.bEnable = NV_TRUE;
	st = nvrm_rm_control(b->c->s, b->tsg, NVA06C_CTRL_CMD_GPFIFO_SCHEDULE, &p,
	    sizeof(p));
	if (st != NV_OK)
		return (nvrm_rmm_status_fail(err, errlen,
		    "NVA06C_CTRL_CMD_GPFIFO_SCHEDULE", st));
	return (NVRM_OK);
}

/* ---- giving things back -------------------------------------------------- */

/* Free one RM object. */
static int
rm_free(nvrm_bclient *c, NvHandle h, NvHandle parent, const char *what,
    char *err, size_t errlen)
{
	NvU32 st;

	st = nvrm_rm_free(c->s, parent, h);
	if (st != NV_OK)
		return (nvrm_rmm_status_fail(err, errlen, what, st));
	return (NVRM_OK);
}

/* Give back a page the backend mapped: the mapping first, then the
 * object.  A page that was never mapped (the descriptor could not be
 * opened) has no mapping to give back. */
static int
free_page(nvrm_bmem **mp, int *fdp, void **cp, char *err, size_t errlen)
{
	nvrm_bmem *m = *mp;
	int rc;

	if (m == NULL)
		return (NVRM_OK);
	if (*cp != NULL) {
		rc = nvrm_rm_mem_ops.unmap_cpu(m, *cp, 1, err, errlen);
		if (rc != NVRM_OK)
			return (rc);
	}
	rc = nvrm_rm_mem_ops.mem_free(m, 1, err, errlen);
	if (rc != NVRM_OK)
		return (rc);
	if (*fdp >= 0)
		close(*fdp);
	*mp = NULL;
	*fdp = -1;
	*cp = NULL;
	return (NVRM_OK);
}

/* Give back what the record holds, in the order the RM wants: the engine
 * objects, the channel, the group, the notifier, the userd page.  The
 * first refusal stops the unwind and leaves the record alone; the core
 * keeps it until the client closes. */
static int
chan_unwind(nvrm_bchan *b, char *err, size_t errlen)
{
	unsigned i;
	int rc;

	/* Time: O(the engine slots and the objects of the record).  Space:
	 * O(1). */
	for (i = 0; i < nitems(b->eng); i++) {
		if (b->eng[i] == 0)
			continue;
		rc = rm_free(b->c, b->eng[i], b->chan, "the engine object", err,
		    errlen);
		if (rc != NVRM_OK)
			return (rc);
		b->eng[i] = 0;
	}
	if (b->chan != 0) {
		rc = rm_free(b->c, b->chan, b->tsg, "the channel", err, errlen);
		if (rc != NVRM_OK)
			return (rc);
		b->chan = 0;
	}
	if (b->tsg != 0) {
		rc = rm_free(b->c, b->tsg, b->c->device, "the channel group", err,
		    errlen);
		if (rc != NVRM_OK)
			return (rc);
		b->tsg = 0;
	}
	rc = free_page(&b->notif, &b->notif_fd, &b->notif_cpu, err, errlen);
	if (rc != NVRM_OK)
		return (rc);
	return (free_page(&b->userd, &b->userd_fd, &b->userd_cpu, err, errlen));
}

/* The client's own objects go back to the RM: the usermode object, then
 * the subdevice under it. */
static void
client_release(nvrm_bclient *c)
{
	char err[64];

	if (c->usermode != 0) {
		/* The mapping is given back only when it came about. */
		if (c->usermode_cpu != NULL)
			(void)nvrm_rmm_unmap_handle(c, c->usermode,
			    c->usermode_cookie, c->usermode_cpu,
			    NVC361_NV_USERMODE__SIZE, err, sizeof(err));
		if (c->usermode_fd >= 0)
			close(c->usermode_fd);
		(void)rm_free(c, c->usermode, c->subdevice,
		    "the usermode object", err, sizeof(err));
		c->usermode = 0;
		c->usermode_cpu = NULL;
	}
	if (c->subdevice != 0) {
		(void)rm_free(c, c->subdevice, c->device, "the subdevice", err,
		    sizeof(err));
		c->subdevice = 0;
	}
}

/* ---- the operations ------------------------------------------------------ */

static int
rm_create(nvrm_bclient *bc, const nvrm_bchan_cfg *cfg, nvrm_bchan **bp,
    nvrm_bchan_info *out, char *err, size_t errlen)
{
	nvrm_bchan *b;
	char scratch[128];
	uint32_t engine;
	int made, rc;

	*bp = NULL;
	memset(out, 0, sizeof(*out));
	b = NVRM_CALLOC(1, sizeof(*b));
	if (b == NULL) {
		snprintf(err, errlen, "out of memory");
		return (NVRM_E_NOMEM);
	}
	b->c = bc;
	b->userd_fd = -1;
	b->notif_fd = -1;
	made = (bc->usermode == 0);
	engine = engine_type(cfg->runlist);
	rc = client_init(bc, err, errlen);
	if (rc == NVRM_OK)
		rc = pick_class(b, cfg, out, err, errlen);
	if (rc == NVRM_OK)
		rc = alloc_page(b, &b->userd, &b->userd_fd, &b->userd_cpu,
		    NVRM_CPU_READ | NVRM_CPU_WRITE, err, errlen);
	if (rc == NVRM_OK)
		rc = alloc_page(b, &b->notif, &b->notif_fd, &b->notif_cpu,
		    NVRM_CPU_READ, err, errlen);
	if (rc == NVRM_OK)
		rc = alloc_tsg(b, engine, err, errlen);
	if (rc == NVRM_OK)
		rc = alloc_channel(b, cfg, engine, err, errlen);
	if (rc == NVRM_OK)
		rc = alloc_engines(b, cfg, err, errlen);
	if (rc == NVRM_OK)
		rc = get_token(b, err, errlen);
	if (rc == NVRM_OK)
		rc = schedule(b, err, errlen);
	if (rc != NVRM_OK) {
		(void)chan_unwind(b, scratch, sizeof(scratch));
		if (made)
			client_release(bc);
		free(b);
		return (rc);
	}
	*bp = b;
	return (NVRM_OK);
}

static int
rm_destroy(nvrm_bchan *b, char *err, size_t errlen)
{
	int rc;

	rc = chan_unwind(b, err, errlen);
	if (rc != NVRM_OK)
		return (rc);
	free(b);
	return (NVRM_OK);
}

/* The channel is gone from the core's point of view: the record goes
 * too, and nothing is given back to the RM. */
static void
rm_forget(nvrm_bchan *b)
{
	free(b);
}

/* The get offset of the channel: the RM's word in the userd page.  A
 * change is progress, and the client's progress count follows it. */
static uint32_t
rm_gp_get(nvrm_bchan *b)
{
	const volatile uint32_t *p;
	uint32_t get;

	p = (const volatile uint32_t *)((const char *)b->userd_cpu + GP_GET_OFF);
	get = *p;
	if (get != b->last_get) {
		b->last_get = get;
		b->c->progress++;
	}
	return (get);
}

/* The put offset of the channel: the CPU publishes the work it wrote. */
static void
rm_gp_put(nvrm_bchan *b, uint32_t put)
{
	volatile uint32_t *p;

	p = (volatile uint32_t *)((char *)b->userd_cpu + GP_PUT_OFF);
	*p = put;
}

/* The doorbell: one aligned store of the token in the usermode page. */
static void
rm_doorbell(nvrm_bchan *b)
{
	volatile uint32_t *p;

	p = (volatile uint32_t *)((char *)b->c->usermode_cpu +
	    NVC361_NOTIFY_CHANNEL_PENDING);
	*p = b->token;
}

/* The error of the channel: the status of the first notification of the
 * notifier page.  Zero means alive. */
static uint32_t
rm_error(nvrm_bchan *b)
{
	const volatile NvNotification *n;

	n = (const volatile NvNotification *)b->notif_cpu;
	return ((uint32_t)n->status);
}

/* The progress count of the client: it changes when any of its channels
 * made progress. */
static uint64_t
rm_progress_gen(nvrm_bclient *bc)
{
	return (bc->progress);
}

/* Sleep for a slice: the RM's own event replaces this (TODO #2438). */
static int
rm_wait(nvrm_bclient *bc, uint64_t slice_ns, uint64_t gen)
{
	struct timespec ts;

	(void)bc;
	(void)gen;
	ts.tv_sec = (time_t)(slice_ns / 1000000000ULL);
	ts.tv_nsec = (long)(slice_ns % 1000000000ULL);
	(void)clock_nanosleep(CLOCK_MONOTONIC, 0, &ts, NULL);
	return (0);
}

/* The client closes: its own objects go back to the RM.  A child of a
 * fork owns no RM object: it drops its records and the parent's session
 * stays as it is. */
void
nvrm_rm_chan_client_close(nvrm_bclient *c)
{
	if (!nvrm_rm_owner(c->s)) {
		c->usermode = 0;
		c->usermode_cpu = NULL;
		c->subdevice = 0;
		return;
	}
	client_release(c);
}

const nvrm_chan_ops nvrm_rm_chan_ops = {
	.copy_on_graphics = 0,
	.create = rm_create,
	.destroy = rm_destroy,
	.forget = rm_forget,
	.gp_get = rm_gp_get,
	.gp_put = rm_gp_put,
	.doorbell = rm_doorbell,
	.error = rm_error,
	.progress_gen = rm_progress_gen,
	.wait = rm_wait,
};

/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * nvrm_rm_priv.h - what the two halves of the RM backend share: nvrm_rm.c
 * (discovery) and nvrm_rm_mem.c (memory and VA).  Not installed.
 */
#ifndef _NVRM_RM_PRIV_H_
#define _NVRM_RM_PRIV_H_

#include <nvtypes.h>
#include <nvstatus.h>
#include <nvos.h>
#include <nv-ioctl.h>
#include <nv_escape.h>

#include "nvrm_internal.h"
#include "nvrm_rm_sys.h"

/* ---- ioctl numbers ----------------------------------------------------- */

#define IOC_CHECK_VERSION	_IOWR(NV_IOCTL_MAGIC, NV_ESC_CHECK_VERSION_STR, \
				    nv_ioctl_rm_api_version_t)
#define IOC_XFER		_IOWR(NV_IOCTL_MAGIC, NV_ESC_IOCTL_XFER_CMD, \
				    nv_ioctl_xfer_t)
#define IOC_RM_ALLOC		_IOWR(NV_IOCTL_MAGIC, NV_ESC_RM_ALLOC, \
				    NVOS21_PARAMETERS)
#define IOC_RM_CONTROL		_IOWR(NV_IOCTL_MAGIC, NV_ESC_RM_CONTROL, \
				    NVOS54_PARAMETERS)
#define IOC_RM_FREE		_IOWR(NV_IOCTL_MAGIC, NV_ESC_RM_FREE, \
				    NVOS00_PARAMETERS)
/* ATTACH_GPUS_TO_FD carries 4 bytes per GPU: its size is the GPU count. */
#define IOC_ATTACH(n)		_IOC(IOC_INOUT, NV_IOCTL_MAGIC, \
				    NV_ESC_ATTACH_GPUS_TO_FD, \
				    (n) * sizeof(NvU32))

#define HANDLE_BASE		0xd1a00000u
/* Status of a call whose ioctl(2) itself failed: not an RM status. */
#define IOCTL_FAILED		0xfffffff0u

/* ---- backend state ----------------------------------------------------- */

struct nvrm_backend {
	nvrm_owner		owner;		/* the process that opened it */
	int			fd;
	NvHandle		client;
	uint32_t		next_handle;
	nv_ioctl_card_info_t	cards[NV_MAX_DEVICES];
	nvrm_str		running;
	nvrm_version		driver, rm_api;
	int			wc, wc_reason;
};

/* Derive the running version (nvrm_rm_running_version) from the driver one. */
void	nvrm_rm_sync_running_version(nvrm_backend *be);

struct nvrm_gpu {
	nvrm_backend		*be;
	uint32_t		id;
	NvHandle		device, subdevice;
	nv_ioctl_card_info_t	card;
	int			have_card;
};

struct nvrm_bres;

/* One client on one GPU: the RM session, the device and the VA space of the
 * client, and what the channel backend adds to them. */
struct nvrm_bclient {
	nvrm_backend	*s;		/* the RM session: descriptor and client */
	NvHandle	device, vaspace;
	unsigned	minor;
	int		have_minor;
	struct nvrm_bres *res;		/* every reservation not yet released */
	/* the channel backend (nvrm_rm_chan.c) */
	NvHandle	subdevice;	/* the subdevice of this client */
	NvHandle	usermode;	/* the usermode object under it */
	void		*usermode_cpu;	/* its CPU mapping (the doorbell) */
	int		usermode_fd;	/* the descriptor it was mapped on */
	NvP64		usermode_cookie;	/* the RM's address for it */
	uint32_t	classes[64];	/* the class list of the device */
	unsigned	nclasses;
	int		have_classes;	/* the list was asked for already */
	uint64_t	progress;	/* the progress count of the client */
};

/* RM calls on a session (a descriptor and its RM client). */
NvU32	nvrm_rm_alloc(nvrm_backend *be, NvHandle parent, NvHandle *hnew,
	    NvU32 cls, void *params, NvU32 size);
NvU32	nvrm_rm_free(nvrm_backend *be, NvHandle parent, NvHandle obj);
NvU32	nvrm_rm_control(nvrm_backend *be, NvHandle obj, NvU32 cmd,
	    void *params, NvU32 size);
NvHandle nvrm_rm_new_handle(nvrm_backend *be);
int	nvrm_rm_open(nvrm_backend **bep, char *err, size_t errlen);
void	nvrm_rm_close(nvrm_backend *be);
int	nvrm_rm_owner(const nvrm_backend *be);
/* The RM client of a session: allocated when the session needs one.  A
 * driver with no GPU needs none, so a session that only counts the GPUs
 * never allocates one.  One client per session: asking for it again
 * returns the client the session already has. */
int	nvrm_rm_client_ensure(nvrm_backend *be, char *err, size_t errlen);
const nvrm_rm_sys *nvrm_rm_get_sys(void);

/* ---- what the two halves of the RM backend share ------------------------- */

/* The RM's name for a memory object. */
NvHandle nvrm_rmm_handle(const nvrm_bmem *m);

/* A CPU mapping of an RM object: the address the CPU sees and the address
 * the RM gave it. */
struct nvrm_rm_map {
	void	*addr;
	NvP64	cookie;
};

/* A CPU mapping of an RM object by handle: the RM names the address, the OS
 * layer maps the descriptor.  The cookie is the RM's address for the
 * mapping; the unmap gives it back. */
int	nvrm_rmm_map_handle(nvrm_bclient *c, NvHandle h, uint64_t bytes,
	    unsigned prot, int fd, struct nvrm_rm_map *map, char *err,
	    size_t errlen);
int	nvrm_rmm_unmap_handle(nvrm_bclient *c, NvHandle h, NvP64 cookie,
	    void *addr, uint64_t bytes, char *err, size_t errlen);

/* Say what an RM call failed with: an RM status, or the system call. */
int	nvrm_rmm_status_fail(char *err, size_t errlen, const char *what,
	    NvU32 st);

/* The class slots the channel backend binds: the subchannels first, in the
 * order of the RM's own subchannel numbers, then the channel itself.  The
 * classes are the RM backend's own (nvrm_rm.c); the core names no chip. */
enum {
	NVRM_RM_CLS_3D = 0,
	NVRM_RM_CLS_COMPUTE,
	NVRM_RM_CLS_I2M,
	NVRM_RM_CLS_2D,
	NVRM_RM_CLS_COPY,
	NVRM_RM_CLS_GPFIFO,
	NVRM_RM_CLS__COUNT
};

/* The class of a slot: the first of its candidates the device lists, or 0
 * when the device lists none of them. */
uint32_t nvrm_rm_chan_class(const nvrm_bclient *c, unsigned slot);

/* The class of the channel group (one per channel). */
uint32_t nvrm_rm_chan_group_class(void);

/* The client's own objects for the channel backend: a subdevice and the
 * usermode object under it. */
int	nvrm_rm_usermode_alloc(nvrm_bclient *c, char *err, size_t errlen);

/* The channel backend: give back what the client holds when it closes. */
void	nvrm_rm_chan_client_close(nvrm_bclient *c);

/* The RM backend's channel operations. */
extern const nvrm_chan_ops nvrm_rm_chan_ops;

#endif

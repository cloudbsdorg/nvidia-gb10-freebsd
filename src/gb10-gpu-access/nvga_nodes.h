/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-3-Clause
 *
 * nvga_nodes.h - the mode and the group of the RM device nodes
 * (Track #2376), in one place.
 *
 * nvidia.ko makes /dev/nvidiactl and /dev/nvidiaN, nvidia-modeset.ko makes
 * /dev/nvidia-modeset, and all of them must be owned by the same group and
 * carry the same mode: the rule the driver enforces (a credential may use a
 * GPU when it is in the group that owns the nodes) and the rule the nodes
 * carry must not drift apart.
 *
 * The file is a header of one inline function: both modules compile it into
 * themselves, so neither needs a symbol from the other.  The group is read
 * from the loader tunable hw.nvidia.gpu_gid; the default is the video group.
 */
#ifndef NVGA_NODES_H_
#define NVGA_NODES_H_

#include <sys/types.h>

#ifdef __KERNEL__
#include <sys/param.h>
#include <sys/conf.h>		/* GID_VIDEO */
#include <sys/sysctl.h>		/* TUNABLE_INT_FETCH */
#endif

/* the mode of every RM device node: the group may read and write it */
#define	NVGA_NODES_MODE	0660

/*
 * nvga_nodes_gid - the group that owns the RM device nodes.
 *
 * The loader tunable hw.nvidia.gpu_gid names the group; a tunable that is
 * not there (or one that is not a gid) leaves the default, the video group,
 * in place.  The tunable is read when the node is made, so a change takes
 * effect after the driver is loaded again.
 */
static inline gid_t
nvga_nodes_gid(void)
{
	gid_t gid = GID_VIDEO;
	int tunable_gid = -1;

	TUNABLE_INT_FETCH("hw.nvidia.gpu_gid", &tunable_gid);
	if (tunable_gid >= 0)
		gid = (gid_t)tunable_gid;
	return (gid);
}

#endif /* NVGA_NODES_H_ */

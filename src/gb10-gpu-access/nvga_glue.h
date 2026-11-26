/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-3-Clause
 *
 * nvga_glue.h - the interface of the GPU access check (Track #2374) and of
 * the wired GPU memory accounting (Track #2376).
 *
 * The rules are in nvga_policy.h (no kernel type appears there); the
 * implementation is in nvga_glue.c, which is compiled into nvidia.ko.
 * scripts/prepare-tree.sh copies these files into TREE/nvidia/.
 *
 * The callers:
 *   - nvidia_subr.c asks nvga_check_attach() before the RM attaches a GPU,
 *     and asks nvga_may_use_unit() when the RM asks whether it may use a
 *     GPU.
 *   - nvidia_subr.c asks nvga_wired_alloc() and nvga_wired_free() in the
 *     RM's allocation path, where the size of the memory is known.
 *   - nvidia_dev.c and nvidia_ctl.c ask nvga_device_gid() and
 *     nvga_device_mode() for the group and the mode of the RM nodes.
 *   - nvidia_sysctl.c asks nvga_sysctl_init() and nvga_sysctl_exit() for
 *     the state sysctls.
 */
#ifndef NVGA_GLUE_H_
#define NVGA_GLUE_H_

#include <sys/types.h>

#include "nvga_policy.h"

/*
 * nvga_init - the rules in force: the group that owns the RM nodes and the
 * host root's right to use every GPU.  Called when the driver attaches.
 */
void nvga_init(void);

/*
 * nvga_check_attach - may the caller attach this RM GPU?
 *
 * 0 when it may, EPERM when it may not.  The GPU is named by the id the RM
 * gave it; the unit of its device node is looked up, never assumed.
 */
int nvga_check_attach(uint32_t gpu_id);

/*
 * nvga_may_use_unit - may the calling credential use this GPU unit?
 *
 * NVGA_ALLOW when it may, the reason it may not otherwise.  The credential
 * is the one of the calling thread.
 */
int nvga_may_use_unit(int unit);

/*
 * nvga_wired_alloc - charge the wired memory of this many pages of this
 * size to the calling credential.
 *
 * 0 when the memory may be handed out, ENOMEM when it may not: the caller
 * must then give the memory back and fail the allocation.
 */
int nvga_wired_alloc(uint64_t count, uint64_t page_size, void *private);

/*
 * nvga_wired_free - give the wired memory back.
 */
void nvga_wired_free(void *private);

/*
 * nvga_device_gid - the group that owns the RM device nodes.
 */
gid_t nvga_device_gid(void);

/*
 * nvga_device_mode - the mode of the RM device nodes.
 */
mode_t nvga_device_mode(void);

/*
 * nvga_sysctl_init - the state sysctls, under the hw.nvidia node.
 */
void nvga_sysctl_init(struct sysctl_ctx_list *ctx, struct sysctl_oid *parent);

/*
 * nvga_sysctl_exit - the state is gone with the node.
 */
void nvga_sysctl_exit(void);

#endif /* NVGA_GLUE_H_ */

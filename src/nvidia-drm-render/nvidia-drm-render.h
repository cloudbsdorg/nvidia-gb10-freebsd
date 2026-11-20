/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: MIT
 *
 * nvidia-drm-render.h - the render uAPI of nvidia-drm (Track #2314, "NVR").
 *
 * One contract, two consumers: the kernel work packages (nvidia-drm and the
 * nvidia-modeset KAPI, N3-N8c) implement it, and the private Mesa backend
 * ("nvdrm", N9) calls it.  The semantics of every ioctl, the error codes,
 * ordering, lifetime, concurrency and limits are in docs/RENDER-UAPI.md and
 * nvidia_drm_render(4); this header is the layout and the numbers only.
 *
 * The structures are shaped like the render interface of Mesa's nouveau uAPI
 * header (include/drm-uapi/nouveau_drm.h, MIT, Copyright 2005 Stephane
 * Marchesin) so that a Mesa backend can be a small fork of the nouveau one.
 * The numbers are our own and the model is the same: GETPARAM, channels, GEM
 * buffers, a user-managed VA space with VM_BIND (synchronous and asynchronous
 * with syncobjs, sparse) and EXEC.  Differences are deliberate and listed in
 * docs/RENDER-UAPI.md section "What differs from nouveau".
 *
 * Rules every structure follows (checked by tests/render_uapi_layout_test.sh):
 *   - fixed-width types only, no pointers: a user pointer is a uint64_t;
 *   - every uint64_t member sits at an offset that is a multiple of 8, and
 *     every structure size is a multiple of 8, so the layout is identical
 *     for 32-bit and 64-bit callers (no compat translation needed);
 *   - no implicit padding: every pad byte is a named member, and a pad,
 *     reserved or unknown-flag bit that is not zero is refused with EINVAL;
 *   - a structure never changes once released.  New behaviour is a new
 *     GETPARAM value, a new flag bit (minor version) or a new ioctl.
 *
 * Header contract: define nothing but NVR_* and DRM_NVR_*, DRM_IOCTL_NVR_*,
 * struct drm_nvr_*.  It includes <sys/types.h> (kernel) or <stdint.h> (user
 * space), and <sys/ioccom.h> (FreeBSD) or <sys/ioctl.h> (anything else, for a
 * Linux build of the same Mesa).  It builds the request codes with its own
 * NVR_IOW/NVR_IOWR and never defines DRM_IOWR, DRM_IOW or DRM_COMMAND_BASE, so
 * it can be included before or after drm.h.
 */

#ifndef _NVIDIA_DRM_RENDER_H_
#define	_NVIDIA_DRM_RENDER_H_

#ifdef _KERNEL
#include <sys/types.h>
#else
#include <stdint.h>
#endif

#if defined(__FreeBSD__)
#include <sys/ioccom.h>
#else
#include <sys/ioctl.h>
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* ---- Version ------------------------------------------------------------ */

/*
 * GETPARAM(NVR_PARAM_UAPI_VERSION) and GETINFO report major and minor.  A
 * major change is a new header with new ioctl numbers kept alongside; a minor
 * change only adds GETPARAM values, flag bits and ioctls.
 */
#define	NVR_UAPI_VERSION_MAJOR	1
#define	NVR_UAPI_VERSION_MINOR	0

/* ---- Ioctl numbers ------------------------------------------------------ */

/*
 * Command numbers are relative to DRM_COMMAND_BASE (NVR_COMMAND_BASE, 0x40).  Three sets are
 * kept apart:
 *   0x00-0x18  NVIDIA's own DRM_NVIDIA_* (driver 580.178.04), which grows
 *              upward one number at a time, so 0x19-0x3f stay free for it;
 *   0x40-0x44  nouveau's GEM ioctls: NVR never uses them, so a stale nouveau
 *              request code on this driver reaches no NVR handler;
 *   0x45-0x5f  NVR (0x5f is the last number before DRM_COMMAND_END).
 * 0x50-0x5f are reserved for NVR minor versions.
 */
#define	DRM_NVR_FIRST			0x45
#define	DRM_NVR_LAST			0x5f

#define	DRM_NVR_GETPARAM		0x45
#define	DRM_NVR_GETINFO			0x46
#define	DRM_NVR_CHANNEL_ALLOC		0x47
#define	DRM_NVR_CHANNEL_FREE		0x48
#define	DRM_NVR_GEM_NEW			0x49
#define	DRM_NVR_GEM_INFO		0x4a
#define	DRM_NVR_GEM_CPU_PREP		0x4b
#define	DRM_NVR_GEM_CPU_FINI		0x4c
#define	DRM_NVR_VM_INIT			0x4d
#define	DRM_NVR_VM_BIND			0x4e
#define	DRM_NVR_EXEC			0x4f

/* ---- Limits ------------------------------------------------------------- */

/*
 * Minimums (suffix _MIN): a device may allow more and says so through
 * GETPARAM (and GETINFO for the push limit); it never allows less.  Use the
 * GETPARAM value as the limit, never these.  Every define of this block ends
 * in a "docs:" tag: the label of its row in docs/RENDER-UAPI.md section 8,
 * and for a minimum the GETPARAM name ("param:") the row's last cell must
 * show; tests/render_uapi_docs_test.sh compares both with the document.  A value with
 * a ULL suffix is a size in bytes (shown as MiB or KiB when it divides evenly).
 */
#define	NVR_EXEC_PUSH_MAX_MIN		256	/* docs: pushes per EXEC; param: EXEC_PUSH_MAX */
#define	NVR_MAX_SYNCS_MIN		128	/* docs: wait or signal entries per EXEC or VM_BIND; param: MAX_SYNCS */
#define	NVR_MAX_BIND_OPS_MIN		1024	/* docs: operations per VM_BIND; param: MAX_BIND_OPS */
#define	NVR_MAX_CHANNELS_MIN		32	/* docs: channels per DRM file, live or draining; param: MAX_CHANNELS */
#define	NVR_MAX_QUEUED_MIN		1024	/* docs: unstarted async binds and jobs per DRM file; param: MAX_QUEUED */
#define	NVR_MAX_RESERVED_MIN		0x4000000ULL	/* docs: reserved page-table bytes per DRM file; param: MAX_RESERVED */
#define	NVR_KERNEL_VA_SIZE_MIN		0x1000000ULL	/* docs: VM_INIT kernel range; param: KERNEL_VA_MIN_SIZE */

/* Fixed values and maxima: no device changes them. */
#define	NVR_CHANNEL_OBJ_MAX		8	/* docs: subchannel objects per channel */
#define	NVR_GETINFO_NAME_LEN		64	/* docs: device name length in bytes */
#define	NVR_PAGE_ALIGN			0x1000ULL	/* docs: smallest alignment of addr, bo_offset, range */
#define	NVR_SPARSE_ALIGN		0x10000ULL	/* docs: sparse region alignment */
#define	NVR_KERNEL_VA_ALIGN		0x200000ULL	/* docs: VM_INIT alignment */
#define	NVR_GEM_ALIGN_MAX		0x200000ULL	/* docs: largest GEM_NEW align */
#define	NVR_EXEC_PUSH_LEN_MAX		0x7ffffcULL	/* docs: largest push in bytes (va_len) */

/* ---- GETPARAM ------------------------------------------------------------ */

#define	NVR_PARAM_UAPI_VERSION		1	/* (major << 16) | minor */
#define	NVR_PARAM_PCI_DEVICE		2	/* PCI device id */
#define	NVR_PARAM_EXEC_PUSH_MAX		3	/* max push_count per EXEC */
#define	NVR_PARAM_VRAM_SIZE		4	/* usable video memory, bytes; 0 with NO_VRAM */
#define	NVR_PARAM_VRAM_BAR_SIZE		5	/* BAR1 size, bytes; 0 with NO_VRAM */
#define	NVR_PARAM_VRAM_USED		6	/* video memory held by this DRM file's BOs, bytes */
#define	NVR_PARAM_PTIMER_TIME		7	/* GPU global timer, nanoseconds */
#define	NVR_PARAM_GRAPH_UNITS		8	/* GPC count bits 0-7, TPC count bits 8-23 */
#define	NVR_PARAM_HAS_VMA_TILEMODE	9	/* always 1: tile_mode and pte_kind accepted */
#define	NVR_PARAM_VA_BITS		10	/* GPU virtual address bits */
#define	NVR_PARAM_MAX_CHANNELS		11	/* channels per DRM file */
#define	NVR_PARAM_MAX_BIND_OPS		12	/* operations per VM_BIND */
#define	NVR_PARAM_MAX_SYNCS		13	/* wait or signal entries per call */
#define	NVR_PARAM_PAGE_SIZES		14	/* bitmask of GPU page sizes in bytes */
#define	NVR_PARAM_FEATURES		15	/* NVR_INFO_FLAG_* bits (same as GETINFO flags) */
#define	NVR_PARAM_VRAM_FREE		16	/* free video memory on the GPU, rounded down to 16 MiB */
#define	NVR_PARAM_VA_LIMIT		17	/* first GPU address past the usable VA space */
#define	NVR_PARAM_KERNEL_VA_MIN_SIZE	18	/* smallest VM_INIT kernel range this device accepts */
#define	NVR_PARAM_MAX_QUEUED		19	/* unstarted async binds plus jobs per DRM file */
#define	NVR_PARAM_MAX_RESERVED		20	/* bytes of page-table memory reserved by unstarted binds per DRM file */

struct drm_nvr_getparam {
	uint64_t param;		/* in: NVR_PARAM_* */
	uint64_t value;		/* out */
};

/* ---- GETINFO ------------------------------------------------------------- */

/* Engine selectors for CHANNEL_ALLOC and the class list. */
#define	NVR_ENGINE_GR			1	/* graphics, compute, copy, 2D, inline-to-memory */
#define	NVR_ENGINE_CE			2	/* copy engine */
#define	NVR_ENGINE_NVDEC		3	/* video decode */
#define	NVR_ENGINE_NVENC		4	/* video encode */

/* drm_nvr_getinfo.flags (and GETPARAM NVR_PARAM_FEATURES) */
#define	NVR_INFO_FLAG_NO_VRAM		(1U << 0)	/* unified memory: no video memory (GB10) */
#define	NVR_INFO_FLAG_CPU_COHERENT	(1U << 1)	/* CPU caches are coherent with GPU access to system memory */
#define	NVR_INFO_FLAG_BAR_DEVICE_MEM	(1U << 2)	/* CPU mappings of video memory are Device-nGnRE: aligned accesses only */
#define	NVR_INFO_FLAG_COMPRESSION	(1U << 3)	/* compressed PTE kinds are accepted */

struct drm_nvr_class {
	uint32_t class_id;	/* RM class number, e.g. 0xcdc0 */
	uint32_t engine;	/* NVR_ENGINE_* */
};

struct drm_nvr_getinfo {
	uint32_t uapi_major;	/* out */
	uint32_t uapi_minor;	/* out */
	uint32_t flags;		/* out: NVR_INFO_FLAG_* */
	uint32_t chipset;	/* out: RM architecture | implementation: GB206 0x1b6, GB10 (GB20B) 0x1bb */
	uint32_t pci_vendor;	/* out */
	uint32_t pci_device;	/* out */
	uint32_t pci_domain;	/* out */
	uint32_t pci_bus;	/* out */
	uint32_t pci_slot;	/* out */
	uint32_t pci_func;	/* out */
	uint32_t pci_revision;	/* out */
	uint32_t sm_version;	/* out: (major << 8) | minor, 0x0c00 is SM 12.0 */
	uint32_t gpc_count;	/* out */
	uint32_t tpc_count;	/* out: total over all GPCs */
	uint32_t mp_per_tpc;	/* out */
	uint32_t max_warps_per_mp;	/* out */
	uint32_t ce_count;	/* out: copy engine instances */
	uint32_t va_bits;	/* out */
	uint32_t page_sizes;	/* out: bitmask of GPU page sizes in bytes */
	uint32_t exec_push_max;	/* out: the other limits are GETPARAM only */
	uint64_t vram_size;	/* out: bytes, 0 with NO_VRAM */
	uint64_t vram_bar_size;	/* out: bytes, 0 with NO_VRAM */
	uint64_t classes_ptr;	/* in: user pointer to struct drm_nvr_class[classes_cap]; 0 iff classes_cap is 0 */
	uint32_t classes_cap;	/* in: entries available at classes_ptr */
	uint32_t classes_count;	/* out: entries the device has (may exceed classes_cap) */
	char	 name[NVR_GETINFO_NAME_LEN];	/* out: device name, NUL terminated */
};

/* ---- Channels ------------------------------------------------------------ */

struct drm_nvr_channel_obj {
	uint32_t class_id;	/* out: RM class of the engine object */
	uint32_t subchan;	/* out: subchannel number the object is bound to */
};

struct drm_nvr_channel_alloc {
	uint32_t engine;	/* in: NVR_ENGINE_* */
	uint32_t engine_instance;	/* in: 0 = driver's choice; 1..ce_count picks a copy engine; 0 for other engines */
	uint32_t flags;		/* in: must be 0 */
	uint32_t channel;	/* out: channel id, per DRM file, never reused */
	uint32_t nr_obj;	/* out: entries filled in objs[] */
	uint32_t pad;		/* must be 0 */
	struct drm_nvr_channel_obj objs[NVR_CHANNEL_OBJ_MAX];	/* out */
};

struct drm_nvr_channel_free {
	uint32_t channel;	/* in */
	uint32_t pad;		/* must be 0 */
};

/* ---- GEM buffers --------------------------------------------------------- */

/* drm_nvr_gem_info.domain; the same bit values as nouveau's GEM domains */
#define	NVR_GEM_DOMAIN_VRAM		(1U << 1)	/* video memory */
#define	NVR_GEM_DOMAIN_GART		(1U << 2)	/* system memory the GPU reaches */
#define	NVR_GEM_DOMAIN_MAPPABLE		(1U << 3)	/* the CPU may mmap it */
#define	NVR_GEM_DOMAIN_COHERENT		(1U << 4)	/* CPU writes need no flush for the GPU */
#define	NVR_GEM_DOMAIN_NO_SHARE		(1U << 5)	/* never exported or imported */
#define	NVR_GEM_DOMAIN_MASK		(NVR_GEM_DOMAIN_VRAM | NVR_GEM_DOMAIN_GART | \
					 NVR_GEM_DOMAIN_MAPPABLE | NVR_GEM_DOMAIN_COHERENT | \
					 NVR_GEM_DOMAIN_NO_SHARE)

/* PTE kinds every supported GPU accepts (the RM's NV_MMU_PTE_KIND_* values) */
#define	NVR_PTE_KIND_PITCH		0x00
#define	NVR_PTE_KIND_GENERIC_MEMORY	0x06

struct drm_nvr_gem_info {
	uint32_t handle;	/* GEM_NEW out, GEM_INFO in */
	uint32_t domain;	/* in: NVR_GEM_DOMAIN_*, out: the placement made */
	uint64_t size;		/* in (GEM_NEW): bytes, out: size after rounding */
	uint64_t map_handle;	/* out: mmap offset on the DRM fd, 0 if not MAPPABLE */
	uint32_t tile_mode;	/* in (GEM_NEW), stored and returned, never interpreted */
	uint32_t pte_kind;	/* in (GEM_NEW), validated, returned */
	uint32_t flags;		/* in: must be 0 (GEM_INFO too) */
	uint32_t pad;		/* must be 0 (GEM_INFO too) */
};

struct drm_nvr_gem_new {
	struct drm_nvr_gem_info info;
	uint32_t align;		/* in: placement alignment in bytes, power of 2, 0 = 4 KiB */
	uint32_t pad;		/* must be 0 */
};

/* nouveau's values: bit 1 (0x2) is deliberately unused. */
#define	NVR_GEM_CPU_PREP_NOWAIT		0x00000001U
#define	NVR_GEM_CPU_PREP_WRITE		0x00000004U
#define	NVR_GEM_CPU_PREP_MASK		(NVR_GEM_CPU_PREP_NOWAIT | NVR_GEM_CPU_PREP_WRITE)

struct drm_nvr_gem_cpu_prep {
	uint32_t handle;
	uint32_t flags;		/* NVR_GEM_CPU_PREP_* */
};

struct drm_nvr_gem_cpu_fini {
	uint32_t handle;
	uint32_t pad;		/* must be 0 */
};

/* ---- Synchronisation objects --------------------------------------------- */

#define	NVR_SYNC_SYNCOBJ		0x0
#define	NVR_SYNC_TIMELINE_SYNCOBJ	0x1
#define	NVR_SYNC_TYPE_MASK		0xf

struct drm_nvr_sync {
	uint32_t flags;		/* NVR_SYNC_* type in the low 4 bits, other bits 0 */
	uint32_t handle;	/* DRM syncobj handle */
	uint64_t timeline_value;	/* timeline point; 0 for a binary syncobj */
};

/* ---- VM_INIT and VM_BIND ------------------------------------------------- */

struct drm_nvr_vm_init {
	uint64_t kernel_managed_addr;	/* in: start of the kernel's VA range */
	uint64_t kernel_managed_size;	/* in: size of the kernel's VA range */
	uint32_t flags;		/* in: must be 0 */
	uint32_t pad;		/* must be 0 */
	uint64_t va_limit;	/* out: first address past the usable VA space */
};

#define	NVR_VM_BIND_OP_MAP		0x0
#define	NVR_VM_BIND_OP_UNMAP		0x1

/* drm_nvr_vm_bind_op.flags (bit 8 is nouveau's SPARSE; bits 0-7 are unused, not reusable) */
#define	NVR_VM_BIND_SPARSE		(1U << 8)	/* the op creates or removes a sparse region */
#define	NVR_VM_BIND_PTE_KIND		(1U << 9)	/* MAP: use the op's pte_kind, not the BO's */
#define	NVR_VM_BIND_OP_FLAGS_MASK	(NVR_VM_BIND_SPARSE | NVR_VM_BIND_PTE_KIND)

struct drm_nvr_vm_bind_op {
	uint32_t op;		/* NVR_VM_BIND_OP_* */
	uint32_t flags;		/* NVR_VM_BIND_SPARSE | NVR_VM_BIND_PTE_KIND */
	uint32_t handle;	/* MAP: GEM handle, 0 for a sparse region; UNMAP: 0 */
	uint32_t pte_kind;	/* MAP with NVR_VM_BIND_PTE_KIND, else 0 */
	uint64_t addr;		/* GPU virtual address */
	uint64_t bo_offset;	/* MAP: offset into the BO */
	uint64_t range;		/* bytes */
};

/* drm_nvr_vm_bind.flags; any bit outside the mask is EINVAL */
#define	NVR_VM_BIND_RUN_ASYNC		0x1
#define	NVR_VM_BIND_FLAGS_MASK		NVR_VM_BIND_RUN_ASYNC

struct drm_nvr_vm_bind {
	uint32_t op_count;	/* in: 1 .. max_bind_ops */
	uint32_t flags;		/* NVR_VM_BIND_RUN_ASYNC or 0 */
	uint32_t wait_count;	/* in: async only */
	uint32_t sig_count;	/* in: async only */
	uint64_t wait_ptr;	/* in: user pointer to struct drm_nvr_sync[wait_count] */
	uint64_t sig_ptr;	/* in: user pointer to struct drm_nvr_sync[sig_count] */
	uint64_t op_ptr;	/* in: user pointer to struct drm_nvr_vm_bind_op[op_count] */
};

/* ---- EXEC ---------------------------------------------------------------- */

/*
 * drm_nvr_exec_push.flags.  NO_PREFETCH marks the GPFIFO entry "wait": the GPU
 * fetches this push only after every earlier entry of the channel has finished,
 * so the push may be written by an earlier push of the same channel.
 */
#define	NVR_EXEC_PUSH_NO_PREFETCH	0x1
#define	NVR_EXEC_PUSH_FLAGS_MASK	NVR_EXEC_PUSH_NO_PREFETCH

struct drm_nvr_exec_push {
	uint64_t va;		/* GPU VA of the push buffer, 4-byte aligned */
	uint32_t va_len;	/* bytes, multiple of 4, 4 .. NVR_EXEC_PUSH_LEN_MAX */
	uint32_t flags;		/* NVR_EXEC_PUSH_NO_PREFETCH or 0 */
};

struct drm_nvr_exec {
	uint32_t channel;	/* in */
	uint32_t push_count;	/* in: 0 .. exec_push_max */
	uint32_t wait_count;	/* in */
	uint32_t sig_count;	/* in */
	uint64_t wait_ptr;	/* in: user pointer to struct drm_nvr_sync[wait_count] */
	uint64_t sig_ptr;	/* in: user pointer to struct drm_nvr_sync[sig_count] */
	uint64_t push_ptr;	/* in: user pointer to struct drm_nvr_exec_push[push_count] */
};

/* ---- ioctl request codes ------------------------------------------------- */

/* DRM_COMMAND_BASE and the DRM ioctl group, spelled here so drm.h is not needed. */
#define	NVR_COMMAND_BASE		0x40
#define	NVR_IOCTL_GROUP			'd'
#define	NVR_IOW(nr, type)		_IOW(NVR_IOCTL_GROUP, NVR_COMMAND_BASE + (nr), type)
#define	NVR_IOWR(nr, type)		_IOWR(NVR_IOCTL_GROUP, NVR_COMMAND_BASE + (nr), type)

#define	DRM_IOCTL_NVR_GETPARAM		NVR_IOWR(DRM_NVR_GETPARAM, struct drm_nvr_getparam)
#define	DRM_IOCTL_NVR_GETINFO		NVR_IOWR(DRM_NVR_GETINFO, struct drm_nvr_getinfo)
#define	DRM_IOCTL_NVR_CHANNEL_ALLOC	NVR_IOWR(DRM_NVR_CHANNEL_ALLOC, struct drm_nvr_channel_alloc)
#define	DRM_IOCTL_NVR_CHANNEL_FREE	NVR_IOW(DRM_NVR_CHANNEL_FREE, struct drm_nvr_channel_free)
#define	DRM_IOCTL_NVR_GEM_NEW		NVR_IOWR(DRM_NVR_GEM_NEW, struct drm_nvr_gem_new)
#define	DRM_IOCTL_NVR_GEM_INFO		NVR_IOWR(DRM_NVR_GEM_INFO, struct drm_nvr_gem_info)
#define	DRM_IOCTL_NVR_GEM_CPU_PREP	NVR_IOW(DRM_NVR_GEM_CPU_PREP, struct drm_nvr_gem_cpu_prep)
#define	DRM_IOCTL_NVR_GEM_CPU_FINI	NVR_IOW(DRM_NVR_GEM_CPU_FINI, struct drm_nvr_gem_cpu_fini)
#define	DRM_IOCTL_NVR_VM_INIT		NVR_IOWR(DRM_NVR_VM_INIT, struct drm_nvr_vm_init)
#define	DRM_IOCTL_NVR_VM_BIND		NVR_IOWR(DRM_NVR_VM_BIND, struct drm_nvr_vm_bind)
#define	DRM_IOCTL_NVR_EXEC		NVR_IOWR(DRM_NVR_EXEC, struct drm_nvr_exec)

#ifdef __cplusplus
}
#endif

#endif /* _NVIDIA_DRM_RENDER_H_ */

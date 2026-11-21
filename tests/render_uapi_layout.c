/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-3-Clause
 *
 * render_uapi_layout.c - compile-time layout probe for
 * src/nvidia-drm-render/nvidia-drm-render.h, driven by
 * tests/render_uapi_layout_test.sh.  Built several times: -D_KERNEL against a
 * FreeBSD source tree (compile only, _Static_assert does the checking) and
 * for user space, with and without a drm.h in play (compiled and run to print
 * the ioctl table).
 *
 * For every structure the table below states the size and, per member, the
 * offset, size and natural alignment.  The checks:
 *   - sizeof and every offsetof/member size match the table;
 *   - the member sizes add up to sizeof: no implicit padding anywhere;
 *   - the offset of every member is a multiple of its alignment, and
 *     alignment-8 members sit on multiples of 8, so a 32-bit caller (where a
 *     64-bit integer aligns to 4) sees the same layout;
 *   - the structure size is a multiple of 8.
 * For every ioctl: group 'd', nr = DRM_COMMAND_BASE + command, direction, and
 * the encoded size equals sizeof the structure.  Command numbers are inside
 * DRM_NVR_FIRST..LAST, above every nvidia-drm ioctl (0x00-0x18, plus the
 * 0x19-0x3f growth gap) and above nouveau's (0x00-0x13, 0x40-0x44), and
 * pairwise different.
 *
 * Adding a structure or an ioctl to the header without a row here fails the
 * shell test (it diffs the header's struct names against the CHK() list and
 * its DRM_IOCTL_NVR_* names against the Y() list).
 */
#include "nvidia-drm-render.h"

/* DRM_COMMAND_END from drm.h: driver commands are DRM_COMMAND_BASE .. +0x5f. */
#define	PROBE_DRM_COMMAND_END	0xa0

/* When a drm.h is in play it must agree with the header's own spelling. */
#ifdef DRM_COMMAND_BASE
_Static_assert(DRM_COMMAND_BASE == NVR_COMMAND_BASE, "DRM_COMMAND_BASE differs");
#endif
#ifdef DRM_IOCTL_BASE
_Static_assert(DRM_IOCTL_BASE == NVR_IOCTL_GROUP, "DRM_IOCTL_BASE differs");
#endif

/* X(struct, member, offset, size, alignment) */
#define	L_getparam(X, s) \
	X(s, param, 0, 8, 8) X(s, value, 8, 8, 8)
#define	L_class(X, s) \
	X(s, class_id, 0, 4, 4) X(s, engine, 4, 4, 4)
#define	L_getinfo(X, s) \
	X(s, uapi_major, 0, 4, 4) X(s, uapi_minor, 4, 4, 4) \
	X(s, flags, 8, 4, 4) X(s, chipset, 12, 4, 4) \
	X(s, pci_vendor, 16, 4, 4) X(s, pci_device, 20, 4, 4) \
	X(s, pci_domain, 24, 4, 4) X(s, pci_bus, 28, 4, 4) \
	X(s, pci_slot, 32, 4, 4) X(s, pci_func, 36, 4, 4) \
	X(s, pci_revision, 40, 4, 4) X(s, sm_version, 44, 4, 4) \
	X(s, gpc_count, 48, 4, 4) X(s, tpc_count, 52, 4, 4) \
	X(s, mp_per_tpc, 56, 4, 4) X(s, max_warps_per_mp, 60, 4, 4) \
	X(s, ce_count, 64, 4, 4) X(s, va_bits, 68, 4, 4) \
	X(s, page_sizes, 72, 4, 4) X(s, exec_push_max, 76, 4, 4) \
	X(s, vram_size, 80, 8, 8) X(s, vram_bar_size, 88, 8, 8) \
	X(s, classes_ptr, 96, 8, 8) X(s, classes_cap, 104, 4, 4) \
	X(s, classes_count, 108, 4, 4) X(s, name, 112, 64, 1)
#define	L_channel_obj(X, s) \
	X(s, class_id, 0, 4, 4) X(s, subchan, 4, 4, 4)
#define	L_channel_alloc(X, s) \
	X(s, engine, 0, 4, 4) X(s, engine_instance, 4, 4, 4) \
	X(s, flags, 8, 4, 4) X(s, channel, 12, 4, 4) \
	X(s, nr_obj, 16, 4, 4) X(s, pad, 20, 4, 4) X(s, objs, 24, 64, 4)
#define	L_channel_free(X, s) \
	X(s, channel, 0, 4, 4) X(s, pad, 4, 4, 4)
#define	L_gem_info(X, s) \
	X(s, handle, 0, 4, 4) X(s, domain, 4, 4, 4) \
	X(s, size, 8, 8, 8) X(s, map_handle, 16, 8, 8) \
	X(s, tile_mode, 24, 4, 4) X(s, pte_kind, 28, 4, 4) \
	X(s, flags, 32, 4, 4) X(s, pad, 36, 4, 4)
#define	L_gem_new(X, s) \
	X(s, info, 0, 40, 8) X(s, align, 40, 4, 4) X(s, pad, 44, 4, 4)
#define	L_gem_cpu_prep(X, s) \
	X(s, handle, 0, 4, 4) X(s, flags, 4, 4, 4)
#define	L_gem_cpu_fini(X, s) \
	X(s, handle, 0, 4, 4) X(s, pad, 4, 4, 4)
#define	L_sync(X, s) \
	X(s, flags, 0, 4, 4) X(s, handle, 4, 4, 4) \
	X(s, timeline_value, 8, 8, 8)
#define	L_vm_init(X, s) \
	X(s, kernel_managed_addr, 0, 8, 8) X(s, kernel_managed_size, 8, 8, 8) \
	X(s, flags, 16, 4, 4) X(s, pad, 20, 4, 4) X(s, va_limit, 24, 8, 8)
#define	L_vm_bind_op(X, s) \
	X(s, op, 0, 4, 4) X(s, flags, 4, 4, 4) \
	X(s, handle, 8, 4, 4) X(s, pte_kind, 12, 4, 4) \
	X(s, addr, 16, 8, 8) X(s, bo_offset, 24, 8, 8) X(s, range, 32, 8, 8)
#define	L_vm_bind(X, s) \
	X(s, op_count, 0, 4, 4) X(s, flags, 4, 4, 4) \
	X(s, wait_count, 8, 4, 4) X(s, sig_count, 12, 4, 4) \
	X(s, wait_ptr, 16, 8, 8) X(s, sig_ptr, 24, 8, 8) X(s, op_ptr, 32, 8, 8)
#define	L_exec_push(X, s) \
	X(s, va, 0, 8, 8) X(s, va_len, 8, 4, 4) X(s, flags, 12, 4, 4)
#define	L_exec(X, s) \
	X(s, channel, 0, 4, 4) X(s, push_count, 4, 4, 4) \
	X(s, wait_count, 8, 4, 4) X(s, sig_count, 12, 4, 4) \
	X(s, wait_ptr, 16, 8, 8) X(s, sig_ptr, 24, 8, 8) X(s, push_ptr, 32, 8, 8)

#define	F_OFF(s, f, off, sz, al) \
	_Static_assert(__builtin_offsetof(struct s, f) == (off), #s "." #f " offset");
#define	F_SZ(s, f, off, sz, al) \
	_Static_assert(sizeof(((struct s *)0)->f) == (sz), #s "." #f " size");
#define	F_AL(s, f, off, sz, al) \
	_Static_assert((off) % (al) == 0, #s "." #f " alignment");
#define	F_SUM(s, f, off, sz, al)	+ (sz)

#define	CHK(name, size) \
	_Static_assert(sizeof(struct drm_nvr_##name) == (size), #name " size"); \
	_Static_assert((size) % 8 == 0, #name " size not a multiple of 8"); \
	_Static_assert(0 L_##name(F_SUM, drm_nvr_##name) == (size), \
	    #name " has implicit padding or a missing member row"); \
	L_##name(F_OFF, drm_nvr_##name) \
	L_##name(F_SZ, drm_nvr_##name) \
	L_##name(F_AL, drm_nvr_##name)

CHK(getparam, 16)
CHK(class, 8)
CHK(getinfo, 176)
CHK(channel_obj, 8)
CHK(channel_alloc, 88)
CHK(channel_free, 8)
CHK(gem_info, 40)
CHK(gem_new, 48)
CHK(gem_cpu_prep, 8)
CHK(gem_cpu_fini, 8)
CHK(sync, 16)
CHK(vm_init, 32)
CHK(vm_bind_op, 40)
CHK(vm_bind, 40)
CHK(exec_push, 16)
CHK(exec, 40)

/* The existing nvidia-drm ioctl numbers, driver 580.178.04 (0x07 is unused). */
#define	NV_MAX_EXISTING		0x18
#define	NV_GROWTH_END		0x3f
/* nouveau's own driver ioctls end at 0x44 (GEM_INFO); NVR stays clear of them. */
#define	NOUVEAU_LAST		0x44

/* Y(name, nr, struct, direction) */
#define	IOCTLS(Y) \
	Y(GETPARAM, 0x45, getparam, IOC_INOUT) \
	Y(GETINFO, 0x46, getinfo, IOC_INOUT) \
	Y(CHANNEL_ALLOC, 0x47, channel_alloc, IOC_INOUT) \
	Y(CHANNEL_FREE, 0x48, channel_free, IOC_IN) \
	Y(GEM_NEW, 0x49, gem_new, IOC_INOUT) \
	Y(GEM_INFO, 0x4a, gem_info, IOC_INOUT) \
	Y(GEM_CPU_PREP, 0x4b, gem_cpu_prep, IOC_IN) \
	Y(GEM_CPU_FINI, 0x4c, gem_cpu_fini, IOC_IN) \
	Y(VM_INIT, 0x4d, vm_init, IOC_INOUT) \
	Y(VM_BIND, 0x4e, vm_bind, IOC_INOUT) \
	Y(EXEC, 0x4f, exec, IOC_INOUT)

#define	Y_CHECK(n, nr, st, dir) \
	_Static_assert(DRM_NVR_##n == (nr), #n " command number"); \
	_Static_assert((nr) >= DRM_NVR_FIRST && (nr) <= DRM_NVR_LAST, #n " outside the NVR range"); \
	_Static_assert((nr) > NV_GROWTH_END, #n " inside NVIDIA's own range"); \
	_Static_assert((nr) > NOUVEAU_LAST, #n " inside nouveau's range"); \
	_Static_assert(NVR_COMMAND_BASE + (nr) < PROBE_DRM_COMMAND_END, #n " beyond DRM_COMMAND_END"); \
	_Static_assert((DRM_IOCTL_NVR_##n & 0xff) == NVR_COMMAND_BASE + (nr), #n " encoded nr"); \
	_Static_assert(((DRM_IOCTL_NVR_##n >> 8) & 0xff) == 'd', #n " encoded group"); \
	_Static_assert(IOCPARM_LEN(DRM_IOCTL_NVR_##n) == sizeof(struct drm_nvr_##st), #n " encoded size"); \
	_Static_assert((DRM_IOCTL_NVR_##n & IOC_DIRMASK) == (dir), #n " encoded direction");
IOCTLS(Y_CHECK)

/* Pairwise different: the sum of the bits equals their union only without a repeat. */
#define	Y_BIT(n, nr, st, dir)	| (1ULL << ((nr) - DRM_NVR_FIRST))
#define	Y_ADD(n, nr, st, dir)	+ (1ULL << ((nr) - DRM_NVR_FIRST))
_Static_assert((0ULL IOCTLS(Y_BIT)) == (0ULL IOCTLS(Y_ADD)), "duplicate NVR command number");
_Static_assert(DRM_NVR_LAST - DRM_NVR_FIRST < 64, "range too wide for the duplicate check");
_Static_assert(NVR_EXEC_PUSH_LEN_MAX / 4 <= 0x1fffff, "push length does not fit a GPFIFO entry's 21-bit dword length");
_Static_assert(NVR_EXEC_PUSH_LEN_MAX % 4 == 0, "push length is not a multiple of 4");
_Static_assert((NVR_GEM_CPU_PREP_NOWAIT & NVR_GEM_CPU_PREP_WRITE) == 0 && (NVR_VM_BIND_SPARSE & NVR_VM_BIND_PTE_KIND) == 0, "flag bits overlap");
_Static_assert(NVR_GEM_CPU_PREP_MASK == 0x5, "cpu_prep mask: nouveau's NOWAIT 0x1 and WRITE 0x4");
_Static_assert((NVR_VM_BIND_OP_FLAGS_MASK & 0xff) == 0, "bind op flags use the low byte (nouveau: unused)");
_Static_assert(NV_MAX_EXISTING < NV_GROWTH_END && NV_GROWTH_END < NOUVEAU_LAST && NOUVEAU_LAST < DRM_NVR_FIRST, "ranges overlap");

/*
 * ABI freeze: every NVR_* / DRM_NVR_* value of the header has an exact-value row.
 * The shell test diffs this list against the header's defines, so a new constant
 * without a row fails, and a changed value fails here.
 */
#define	V(name, val)	_Static_assert((unsigned long long)(name) == (val##ULL), "value of " #name);
/* CPD-OFF -- a table of exact-value rows, similar by construction */
V(NVR_UAPI_VERSION_MAJOR, 1)
V(NVR_UAPI_VERSION_MINOR, 0)
V(DRM_NVR_FIRST, 69)
V(DRM_NVR_LAST, 95)
V(DRM_NVR_GETPARAM, 69)
V(DRM_NVR_GETINFO, 70)
V(DRM_NVR_CHANNEL_ALLOC, 71)
V(DRM_NVR_CHANNEL_FREE, 72)
V(DRM_NVR_GEM_NEW, 73)
V(DRM_NVR_GEM_INFO, 74)
V(DRM_NVR_GEM_CPU_PREP, 75)
V(DRM_NVR_GEM_CPU_FINI, 76)
V(DRM_NVR_VM_INIT, 77)
V(DRM_NVR_VM_BIND, 78)
V(DRM_NVR_EXEC, 79)
V(NVR_EXEC_PUSH_MAX_MIN, 256)
V(NVR_MAX_SYNCS_MIN, 128)
V(NVR_MAX_BIND_OPS_MIN, 1024)
V(NVR_MAX_CHANNELS_MIN, 32)
V(NVR_MAX_QUEUED_MIN, 1024)
V(NVR_MAX_RESERVED_MIN, 67108864)
V(NVR_KERNEL_VA_SIZE_MIN, 16777216)
V(NVR_CHANNEL_OBJ_MAX, 8)
V(NVR_GETINFO_NAME_LEN, 64)
V(NVR_PAGE_ALIGN, 4096)
V(NVR_SPARSE_ALIGN, 65536)
V(NVR_KERNEL_VA_ALIGN, 2097152)
V(NVR_GEM_ALIGN_MAX, 2097152)
V(NVR_EXEC_PUSH_LEN_MAX, 8388604)
V(NVR_PARAM_UAPI_VERSION, 1)
V(NVR_PARAM_PCI_DEVICE, 2)
V(NVR_PARAM_EXEC_PUSH_MAX, 3)
V(NVR_PARAM_VRAM_SIZE, 4)
V(NVR_PARAM_VRAM_BAR_SIZE, 5)
V(NVR_PARAM_VRAM_USED, 6)
V(NVR_PARAM_PTIMER_TIME, 7)
V(NVR_PARAM_GRAPH_UNITS, 8)
V(NVR_PARAM_HAS_VMA_TILEMODE, 9)
V(NVR_PARAM_VA_BITS, 10)
V(NVR_PARAM_MAX_CHANNELS, 11)
V(NVR_PARAM_MAX_BIND_OPS, 12)
V(NVR_PARAM_MAX_SYNCS, 13)
V(NVR_PARAM_PAGE_SIZES, 14)
V(NVR_PARAM_FEATURES, 15)
V(NVR_PARAM_VRAM_FREE, 16)
V(NVR_PARAM_VA_LIMIT, 17)
V(NVR_PARAM_KERNEL_VA_MIN_SIZE, 18)
V(NVR_PARAM_MAX_QUEUED, 19)
V(NVR_PARAM_MAX_RESERVED, 20)
V(NVR_ENGINE_GR, 1)
V(NVR_ENGINE_CE, 2)
V(NVR_ENGINE_NVDEC, 3)
V(NVR_ENGINE_NVENC, 4)
V(NVR_INFO_FLAG_NO_VRAM, 1)
V(NVR_INFO_FLAG_CPU_COHERENT, 2)
V(NVR_INFO_FLAG_BAR_DEVICE_MEM, 4)
V(NVR_INFO_FLAG_COMPRESSION, 8)
V(NVR_GEM_DOMAIN_VRAM, 2)
V(NVR_GEM_DOMAIN_GART, 4)
V(NVR_GEM_DOMAIN_MAPPABLE, 8)
V(NVR_GEM_DOMAIN_COHERENT, 16)
V(NVR_GEM_DOMAIN_NO_SHARE, 32)
V(NVR_GEM_DOMAIN_MASK, 62)
V(NVR_PTE_KIND_PITCH, 0)
V(NVR_PTE_KIND_GENERIC_MEMORY, 6)
V(NVR_GEM_CPU_PREP_NOWAIT, 1)
V(NVR_GEM_CPU_PREP_WRITE, 4)
V(NVR_GEM_CPU_PREP_MASK, 5)
V(NVR_SYNC_SYNCOBJ, 0)
V(NVR_SYNC_TIMELINE_SYNCOBJ, 1)
V(NVR_SYNC_TYPE_MASK, 15)
V(NVR_VM_BIND_OP_MAP, 0)
V(NVR_VM_BIND_OP_UNMAP, 1)
V(NVR_VM_BIND_SPARSE, 256)
V(NVR_VM_BIND_PTE_KIND, 512)
V(NVR_VM_BIND_OP_FLAGS_MASK, 768)
V(NVR_VM_BIND_RUN_ASYNC, 1)
V(NVR_VM_BIND_FLAGS_MASK, 1)
V(NVR_EXEC_PUSH_NO_PREFETCH, 1)
V(NVR_EXEC_PUSH_FLAGS_MASK, 1)
V(NVR_COMMAND_BASE, 64)
V(NVR_IOCTL_GROUP, 100)
/* CPD-ON */

_Static_assert(NVR_COMMAND_BASE + DRM_NVR_LAST < PROBE_DRM_COMMAND_END, "DRM_NVR_LAST reaches DRM_COMMAND_END");

#ifndef _KERNEL
#include <stdio.h>
#include <stdlib.h>

struct row {
	const char *name;
	unsigned nr;
	unsigned long cmd;
	unsigned size;
};

#define	Y_ROW(n, nr, st, dir) \
	{ "DRM_IOCTL_NVR_" #n, nr, (unsigned long)DRM_IOCTL_NVR_##n, (unsigned)sizeof(struct drm_nvr_##st) },
static const struct row rows[] = { IOCTLS(Y_ROW) };

int
main(void)
{
	size_t i, n = sizeof(rows) / sizeof(rows[0]);

	/* Uniqueness and ranges are proved at compile time above; this prints the table. */
	for (i = 0; i < n; i++)
		printf("%-30s nr 0x%02x  cmd 0x%08lx  struct size %u\n",
		    rows[i].name, rows[i].nr, rows[i].cmd, rows[i].size);
	printf("NV_GROWTH_END %d\n", NV_GROWTH_END);
	printf("%zu ioctls, numbers unique and outside the nvidia-drm and nouveau ranges\n", n);
	return (0);
}
#endif

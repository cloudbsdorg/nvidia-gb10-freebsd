# Provenance: nvidia-drm render uAPI (Track #2314, N2)

Date: 2026-11-20. Applies to `src/nvidia-drm-render/`,
`docs/RENDER-UAPI.md`, `man/nvidia_drm_render.4`, `tests/render_uapi_*`.

## Consulted (read)

| Source | Licence checked | Used for |
|---|---|---|
| Mesa `include/drm-uapi/nouveau_drm.h`, local checkout `~/work/gpu/tmp/mesa-src/mesa-26.3-branchpoint-1934-g6d4d60f15c9/` | MIT/X11 notice in the file header (Copyright 2005 Stephane Marchesin and others) | the shape of GETPARAM, CHANNEL_ALLOC, GEM_NEW/GEM_INFO, `drm_nouveau_sync`, VM_INIT, VM_BIND and its operations, EXEC and its pushes, the GEM domain bit values and the `NO_SHARE` idea. Our structures follow that model; numbers, member sets and every semantic are ours. |
| `docs/NATIVE-NVIDIA-RENDERING.md` (our design study) sections 2.1, 3.1, 3.3, 3.5, 10, 11 | ours | what NVK needs, the placement, the section 3.5 points |
| open-gpu-kernel-modules 580.178.04, `kernel-open/nvidia-drm/nvidia-drm-ioctl.h` | MIT text in the file header (NVIDIA) | the existing `DRM_NVIDIA_*` command numbers 0x00-0x18 (the collision table) |
| open-gpu-kernel-modules 580.178.04, `kernel-open/nvidia-drm/nvidia-drm-drv.c` (the `DRM_IOCTL_DEF_DRV` table and driver features only) | MIT | all NVIDIA ioctls are `DRM_RENDER_ALLOW` and `DRM_UNLOCKED`; the driver has `DRIVER_RENDER` and `DRIVER_SYNCOBJ` |
| open-gpu-kernel-modules 580.178.04, `kernel-open/nvidia-uvm/hwref/*/dev_mmu.h` (grep of `NV_MMU_PTE_KIND_*` only) | SPDX MIT | PTE kind 0x00 (PITCH) and 0x06 (GENERIC_MEMORY) valid on Turing and Hopper; 0xfe (GENERIC_16BX2) on older GPUs |
| this repository's `src/gb10-memattr/gb10_memattr.h` and README | ours (BSD-3-Clause) | the attribute rule of section 5 of the document |
| open-gpu-kernel-modules 580.178.04, `src/common/sdk/nvidia/inc/ctrl/ctrl2080/ctrl2080mc.h` (the `NV2080_CTRL_MC_ARCH_INFO_*` values only) | SPDX MIT | architecture and implementation values: GB206 `0x1b6`, GB20B `0x1bb` (the GB10 SoC), datacenter GB10x `0x1a0`-`0x1af` |
| open-gpu-kernel-modules 580.178.04, `src/common/sdk/nvidia/inc/class/clc36f.h` (the `GP_ENTRY1_LENGTH` and `SYNC` fields only) | SPDX MIT | the 21-bit dword length of a GPFIFO entry (8 MiB push maximum) and the SYNC_WAIT bit behind NO_PREFETCH |
| FreeBSD `sys/sys/ioccom.h` in `~/src/csrc-90dcf68/sys` | BSD | ioctl encoding, kernel compile of the layout probe |

The comparison table in section 7 of the document rests on the Mesa header above (member
lists, the `VM_INIT` -ENOSYS comment, the `NO_SHARE` comment, the sparse flag) and on the
design study's table of what NVK calls (the empty-push liveness probe). The runtime behaviour
of the Linux nouveau driver is not stated anywhere in the document.

## Not consulted

- No Linux kernel source, local or online: no file of `drivers/gpu/drm/nouveau`, no `sync_file.c`, no
  other file of the Linux tree. The tree-wide `find` that located Mesa's header also printed the
  paths of drm-kmod's copy of `nouveau_drm.h`; those files were not opened.
- No drm-kmod file was read in this work package (decision D6 of the design study, the rule on reading drm-kmod's MIT and BSD files, is not exercised here).
- No `cleanroom/dirty-notes`.
- No GPL file of any kind.

## Licence of the result

`nvidia-drm-render.h` is MIT (SPDX line in the file): its layouts follow Mesa's MIT header and it is
meant to be included by NVIDIA's MIT nvidia-drm sources and by Mesa. The document, man page and
tests are BSD-3-Clause like the repository.

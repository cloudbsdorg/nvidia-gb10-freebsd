# Provenance: GPU access confinement and the wired memory of the GPU (Track #2374, #2376)

Date: 2026-11-26.  Applies to `src/gb10-gpu-access/`, the patches
`patches/patch-zzz-2374-nvidia_gpu_access_subr.c`,
`patches/patch-zzz-2376-nvidia_gpu_wired_subr.c`,
`patches/patch-zzz-2376-nvidia_gpu_modes_nvidia_dev.c`,
`patches/patch-zzz-2376-nvidia_gpu_modes_nvidia_ctl.c`,
`patches/patch-zzz-2376-nvidia_gpu_modes_modeset.c`,
`patches/patch-zzz-2376-nvidia_gpu_access_sysctl.c`,
`patches/patch-zzz-2376-nvidia_gpu_access_Makefile`, `devd/nvidia_gb10.rules`,
and `tests/gpu_access_test.sh`.

## Consulted (read)

| Source | Licence checked | Used for |
|---|---|---|
| NVIDIA's FreeBSD driver 580.178.04 (`~/work/gb10/sources/NVIDIA-FreeBSD-x86_64-580.178.04/src/nvidia`): `nvidia_subr.c`, `nvidia_dev.c`, `nvidia_ctl.c`, `nvidia_sysctl.c`, `nv-freebsd.h`, `nv.h` | NVIDIA's FreeBSD package (the repo already patches these files; permitted by the brief) | the attach ioctl (`NV_ESC_ATTACH_GPUS_TO_FD`), the RM's own gate (`nv_is_gpu_accessible()`), the RM's allocation path (`nv_alloc_pages()`, `nv_free_pages()`, `nv_alloc_system_pages()`), the device nodes (`make_dev()`), the sysctl node (`oid_nvidia`), the credential and the device class types |
| NVIDIA's modeset module, same tarball (`.../src/nvidia-modeset/nvidia-modeset-freebsd.c`) | NVIDIA's FreeBSD package (the repo already patches this file; permitted by the brief) | the third RM node, `/dev/nvidia-modeset`, which `nvidia-modeset.ko` makes and which was 0666 as well |
| open-gpu-kernel-modules 580.178.04 (`~/work/gb10/sources/open-gpu-kernel-modules-580.178.04`): `src/nvidia/arch/nvalloc/unix/src/os.c` (the `osAllocPagesInternal()`, `osAllocPagesNode()` and `osIsGpuAccessible()` calls), `src/nvidia/arch/nvalloc/unix/src/osmemdesc.c` | MIT (the SPDX line of each file was checked before reading) | who calls the OS layer's allocation entry point, and who asks the OS layer whether a GPU is accessible |
| FreeBSD `sys/` (`/usr/src/sys`): `sys/racct.h`, `kern/kern_racct.c`, `kern/kern_rctl.c`, `kern/kern_sysctl.c`, `vm/vm_unix.c`, `vm/vm_mmap.c`, `sys/ucred.h`, `kern/kern_prot.c`, `sys/jail.h`, `sys/bus.h`, `sys/sysctl.h`, `sys/conf.h`, `fs/devfs/devfs_vnops.c`, `fs/devfs/devfs_rule.c` | BSD-2-Clause | the racct containers and their rules (`racct_add_cred()`, `racct_sub_cred()`, `racct_get_limit()`, `RACCT_MEMLOCK`), the credential reference counting (`crhold()`, `crfree()`), the jail id, the device class (`devclass_get_softc()`, `devclass_get_maxunit()`, `device_get_unit()`), the sysctl handler shape and the write path (`sysctl_new_kernel()`, `sysctl_handle_int()`, `sysctl_handle_long()`), the `video` group (`GID_VIDEO`), and the devfs rules that decide which nodes a jail sees |
| this repository (`src/`, `patches/`, `tests/`, `docs/`) and the kernel headers of the tree the module is built against | BSD-3-Clause | everything else, and the patterns the work follows (the client ownership table of `src/gb10-client-owner/`, the fake-kernel harness of `tests/client_owner_glue_test.sh`) |

## Not consulted

- No Linux kernel source, local or online: no file of `drivers/gpu/drm`, no
  `nouveau` file, no other file of a GPL tree.
- No GPL file of any kind, and no `cleanroom/dirty-notes`.
- NVIDIA's closed `nv-kernel.o` was not disassembled; the RM core was built
  from the pinned open-gpu-kernel-modules checkout.
- The Linux driver's own device and memory accounting was not consulted:
  the rules here are FreeBSD's (ucred, jail, devfs rules, racct/rctl).

## Licence of the files

Everything under `src/gb10-gpu-access/` is ours and carries the repository
header (`Copyright (c) 2026 REVYTECH, Inc.`, `SPDX-License-Identifier:
BSD-3-Clause`); so do `tests/gpu_access_test.sh`,
`tests/data/gpu_access_harness.c`, `tests/data/nvga_fakes.h` and
`devd/nvidia_gb10.rules`.  The patches to NVIDIA's files are diffs and keep
NVIDIA's notices in the files they patch.

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
# Provenance: cross-GPU buffer import (PRIME), Track #2228

What was consulted to write this work. **No Linux kernel source was opened** (nothing under
drivers/dma-buf, drivers/gpu/drm or any other GPL tree, local or online), and no file of the
clean-room dirty-notes.

## Permitted sources that were read

| Source | Licence | Used for |
|---|---|---|
| open-gpu-kernel-modules 580.178.04 (`~/work/gb10/sources/open-gpu-kernel-modules-580.178.04`): `src/nvidia/arch/nvalloc/unix/src/osmemdesc.c`, `escape.c`, `src/nvidia/src/kernel/mem_mgr/os_desc_mem.c`, `src/nvidia-modeset/kapi/src/nvkms-kapi.c`, `src/nvidia-modeset/kapi/interface/nvkms-kapi.h` | MIT (the SPDX line of each file was checked before reading) | how the RM builds a memory descriptor from a page array, who owns the array on success and on failure, the kernel-client restriction, the KAPI table and the SGT helper |
| NVIDIA's FreeBSD driver 580.178.04 (`~/work/gb10/sources/NVIDIA-FreeBSD-x86_64-580.178.04/src`): `nvidia/nvidia_subr.c`, `nvidia/nvidia_os.c`, `nvidia/nv.h`, `nvidia-drm/*`, `common/inc/nvkms-kapi.h` | NVIDIA's FreeBSD package (the repo already patches these files; permitted by the brief) | the OS layer entry points the RM calls, the FreeBSD wiring in `os_lock_user_pages`/`os_unlock_user_pages`, the nvidia-drm import and export paths |
| FreeBSD source, cloudbsd-src `~/src/csrc-90dcf68/sys` | BSD | `vm_page_wire()`/`vm_page_unwire()` semantics (`vm/vm_page.c`), linuxkpi `scatterlist.h` and `page.h` (a `struct page` is a `vm_page`) |
| this repository (`src/`, `patches/`, `tests/`, `docs/`) and the design note `.round/proposed-prime-import.md` | BSD-3-Clause | everything else |

## Not consulted

- Linux kernel source of any kind (dma-buf, drm, scatterlist, TTM): no.
- Linux `nvidia-uvm`, the clean-room dirty-notes: no.
- NVIDIA's closed `nv-kernel.o`: not disassembled.

## Notes on derived files

Patches to NVIDIA's files keep NVIDIA's notices (the patch is a diff; the file keeps its header).
New files of ours carry the repository header (`Copyright (c) 2026 REVYTECH, Inc.`,
`SPDX-License-Identifier: BSD-3-Clause`).

## Licence of the files

The new FreeBSD-side code of the import (`nv_import_pages()` and its siblings, the busy/wire/unwire
ops and the guarded dirty step) is BSD-3-Clause in our own file `src/gb10-pageimport/gb10_pageimport_os.c`.
NVIDIA's `nvidia_subr.c` and `nvidia_os.c` carry NVIDIA's proprietary notice, not MIT. For this feature
the patches to them add an include and one-line calls into our file (`nvidia_os.c` also carries our earlier
arm64 memory-attribute patches, which predate this work and use `gb10_memattr.h`). `tests/prime_import_test.sh` fails when
logic of ours appears in the lines the patch adds to `nvidia_subr.c`.
The files of the open-gpu-kernel-modules and nvidia-drm that the patches touch are MIT (SPDX or MIT text
checked). Sources read for this round: FreeBSD's `sys/compat/linuxkpi/common/src/linux_page.c` and
`sys/vm` (BSD) for the fault path. No Linux kernel source was read, and no GPL header text: the
`get_dma_buf()` and `dma_buf_put()` calls are the public API names.

# Provenance: cuda-native SDK tree (Track #2380, stage C1.1 #2425)

## Consulted (read)

- The CUDA headers of clang 23 in `/usr/local/llvm23/lib/clang/23/include/` (`__clang_cuda_runtime_wrapper.h`,
  `__clang_cuda_intrinsics.h`, `__clang_cuda_device_functions.h`, `__clang_cuda_texture_intrinsics.h`,
  `__clang_cuda_math.h`; Apache-2.0 with LLVM exception), for the header names the wrapper includes and
  the types and helper functions it expects from them.
- The behaviour of the clang 23 driver, by experiment: which files make a `--cuda-path` tree an
  installation, and where it takes the SDK version from.
- The public CUDA documentation, for API names, signatures and documented values:
  - the Runtime API reference: the `cudaError_t` values, `cudaLaunchKernel`, the texture read modes
    and the surface boundary modes;
  - the Driver API reference: `cuuint32_t` and `cuuint64_t`;
  - the Math API reference: the host math functions;
  - the CUDA C++ Programming Guide: the execution and memory space keywords, the vector types and
    their alignment, the `make_<type>` constructors, and the `__cvta_generic_to_*` conversions.

## Not consulted

No file of NVIDIA's CUDA toolkit was opened, copied or diffed: no header, no `libdevice.bc`, no
binary. The Linux CUDA tree used for the Linuxulator comparison path was not read. No GPL source.

## Licence of the files

Everything under `lib/cuda-native/` is ours, and so are `tests/cuda-native/` and
`tests/cuda_native_toolchain_test.sh`. All of it is BSD-2-Clause, like `lib/libnvrm`, and every
file carries the licence header. The `version.json` of a built tree carries none, because JSON has
no comments; `mksdk.sh` generates it from `cuda.h`.

The test checks this. It fails if any file under `lib/cuda-native` or `tests/cuda-native` lacks
the header, names NVIDIA Corporation, or carries another copyright line in any spelling. Two
planted mutants prove that the check works.

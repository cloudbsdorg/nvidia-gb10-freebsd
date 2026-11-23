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

# Provenance: nvidia.ko architecture floor (Track #2457)

Applies to `src/gb10-archfloor/`, `patches/patch-zz-2457-arch-floor_*`, the preflight support
verdict in `scripts/make.sh`, `devd/nvidia_gb10.conf`, `tests/arch_floor*`,
`tests/devd_rule_test.sh` and `tests/preflight_support_test.sh`.

## Consulted (read)

| Source | Licence checked | Used for |
|---|---|---|
| open-gpu-kernel-modules 580.178.04, `src/common/inc/swref/published/nv_ref.h` (`NV_PMC_BOOT_0`, `NV_PMC_BOOT_42` and its `ARCHITECTURE` and `IMPLEMENTATION` fields, the architecture values only) | SPDX MIT | `PMC_BOOT_0` at 0x0, `PMC_BOOT_42` at 0xA00, architecture in bits 29:24 and implementation in bits 23:20; the values GM100 0x11, GM200 0x12, GP100 0x13, GV100 0x14, GV110 0x15, TU100 0x16, GA100 0x17, GH100 0x18, AD100 0x19, GB100 0x1A, GB200 0x1B, AMODEL 0x1F. They are not chronological, but every Ampere or later value is at least 0x17 and every older one is below it, so the floor is the integer 0x17 |
| open-gpu-kernel-modules 580.178.04, `src/common/inc/swref/published/nv_arch.h` (the implementation values only) | SPDX MIT | implementations GA100 0x0, GA102 0x2, AD102 0x2, GB206 0x6, GB20B 0xB (the DGX GB10 SoC; the render uAPI provenance above records 0x1bb for it), TU104 0x4, GP104 0x4: the test cases |
| open-gpu-kernel-modules 580.178.04, `kernel-open/common/inc/nv-firmware.h` and `src/nvidia/arch/nvalloc/common/inc/nv-firmware-chip-family-select.h` | SPDX MIT | GA100 uses the `gsp_tu10x` GSP image; GA10x, AD10x, GH100, GB10x and GB20x use `gsp_ga10x` |
| NVIDIA FreeBSD driver 580.178.04, `src/nvidia/nvidia_pci.c` (`nvidia_pci_probe`, `nvidia_pci_identify`) | NVIDIA's licence in the tarball, the file the patch edits | the probe flow: `rm_is_supported_pci_device()`, `rm_get_device_name()`, `device_set_desc_copy()`; where the check goes |
| NVIDIA FreeBSD driver 580.178.04, `src/nvidia/nvidia_subr.c` (`nvidia_alloc_hardware`), `src/nvidia/nvidia_sysctl.c`, `src/nvidia/Makefile` | same | BAR0 is allocated with flags 0 (not `RF_ACTIVE`); where the `hw.nvidia` node is created; the `SRCS` list |
| open-gpu-kernel-modules 580.178.04, `src/nvidia/arch/nvalloc/unix/src/osapi.c` (`rm_is_supported_device`) | SPDX MIT | the attach path maps one page of BAR0 uncached, reads BOOT_0, BOOT_1 and BOOT_42, unmaps, and treats BOOT_0 equal to BOOT_42 equal to 0xffffffff as a device that fell off the bus; our probe does the same sequence earlier |
| FreeBSD `sys/dev/pci/vga_pci.c`, `sys/dev/pci/pcivar.h`, `sys/sys/bus.h`, `sys/sys/mutex.h`, `sys/sys/sysctl.h`, `sys/arm64/include/pmap.h` (a FreeBSD 16.0-CURRENT source tree (/usr/src/sys)) | BSD | vgapci caches BAR resources and releases them when the last child reference goes, so a probe that allocates and releases BAR0 leaves nothing for attach; `pci_enable_io`, `pci_disable_io`, `pmap_mapdev`, `pmap_unmapdev`, the resource calls and the sysctl macros; `MTX_SYSINIT` registers the matching destroy |
| FreeBSD `devd.conf(5)` (installed manual page) | BSD | variable expansion: `$name` becomes `$'value'`, which is wrong inside single quotes, so `$device-name` sits outside them in the rule |
| this repository: `patches/patch-zz-nvidia_fw_depend_pci.c`, `src/gb10-version/nv_version_sysctl.c`, `tests/version_sysctl_test.sh`, `docs/DEVICE-DECISION.md` of the provider-registry branch (sections 8 and 8.2) | ours | `gsp_tu10x` is depended on for amd64 only; the code and test style; where the floor goes when the registry lands (the named constant moves to a generated value) |

## Not consulted

- No Linux kernel source, no GPL source and no nouveau source, local or online, not even a grep.
- Nothing of NVIDIA's Linux driver beyond the MIT files of open-gpu-kernel-modules named above.

## Licence of the result

`src/gb10-archfloor/` is ours, BSD-2-Clause (SPDX line in each file); the tests are BSD-3-Clause
like the repository. The patches apply to NVIDIA's FreeBSD OS layer files and keep NVIDIA's
licence for those files; they add two small calls and one `SRCS` line. The register offsets and
field positions are facts of the MIT `nv_ref.h`; no NVIDIA header is included or copied.

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

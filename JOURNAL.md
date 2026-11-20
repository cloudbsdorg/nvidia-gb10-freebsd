# JOURNAL - nvidia-prime-import (agent branch agent/2228-prime-import)

Brief: ~/work/gb10/agents/briefs/nvidia-prime-import.md. Track #2228. Resume: read this file bottom-up.

## 2026-11-20T18:00:12Z start
- Read PROTOCOL, COMMON, the design (.round/proposed-prime-import.md), README, tests.
- Worktree exists at 18fa11d, clean. Track children for items 5 and 6 filed under #2228.
- FINDINGS that change the design (verified in the pinned MIT sources):
  1. osmemdesc.c (RM core) refuses OS_PAGE_ARRAY for kernel RM clients (NVKMS is one):
     "kernel clients may use only PHYS_ADDR, FILE_HANDLE, DMA_BUF_PTR, SGT_PTR".
     So the KAPI page-array entry needs a one-line RM patch (patches/ogkm).
  2. A page-array descriptor is owned by the RM only once the alloc got past osCreateMemFromOsDescriptor
     (os_desc_mem.c sets pUserParams->descriptor = NULL); escape.c uses that to decide who unwires on failure.
     The KAPI entry reports it with an out parameter.
  3. linuxkpi scatterlist entries can span several pages; the design sketch (one page per entry) would
     under-fill the array. The converter expands each entry.
- Plan: pure core header src/gb10-pageimport/gb10_pageimport.h (conversion, wire/unwire with ops), tests
  first (red), then KAPI + nvidia-drm (item 2), nv_import_pages/nv_unimport_pages (item 3),
  nv_register_sgt/nv_dma_import_sgt real + export from the descriptor (item 4).
- Next: PROVENANCE.md, docs/PRIME-IMPORT.md, first commit; then red tests.

## 2026-11-20T18:09:33Z red tests written
- src/gb10-pageimport/gb10_pageimport.h (pure core) and tests/pageimport_test.sh: header-first because the
  fake-driven test needs the API; test is green with 15 mutant controls, each caught (red evidence: before the header
  existed the test printed "FAIL missing core header").
- tests/kapi_table_test.sh: RED (patches missing). tests/prime_import_test.sh: RED (patches missing). Both have controls.
- Next: scratch GB10_WORK=~/work/gb10/prime-import-work (sources symlinked), prepare-tree, edit, generate patches
  (nvidia-drm gem-dma-buf .c/.h, nvidia_subr.c, nvidia/Makefile, common/inc/nvkms-kapi.h, ogkm: osmemdesc.c,
  nvkms-kapi.c, interface header); prepare-tree.sh copy of the header into TREE/common/inc.

## 2026-11-20T18:29:09Z items 2-4 implemented, tests green, modules build
- Patches: ogkm (osmemdesc.c, nvkms-kapi.c, kapi header), common/inc header, nvidia-drm gem-dma-buf .c/.h, nvidia_subr.c, nvidia/Makefile; prepare-tree.sh installs the core header; build-rmcore_test fake checkout gets pre-images for the new ogkm patches.
- Tests green with GB10_WORK=~/work/gb10/prime-import-work: pageimport, kapi_table, prime_import, prime_import_kit, plus all older tests. nvidia.ko, nvidia-modeset.ko, nvidia-drm.ko build (LLD), kmod_symbols_test PASS.
- Kit: tests/prime-import-testboot (make-be.sh, prime_import_testboot rc, prime_import_probe + man page + schema).
- Next: wait for final rebuild, copy modules to ~/work/gb10/testboot-prime-import, queue row, commits via gate, push branch, Track comment, Honcho lesson.
- Open: Wayfire seat test command unknown (rc var prime_import_testboot_wayfire_cmd); modules built against csrc-90dcf68 (queue says test kernel base 6830a3b).

## 2026-11-20T18:53:26Z review round 1 fixes
- Gate voices: refuse object pages, check modeset member NULL, shared prototypes, import/wire-balance rows no longer vacuous, rc dir creation, probe errno/stage, make-be option values, doc fixes, R2 pin of RM in-place params. Modules rebuilt; all tests green.
- Next: gate, commit, push agent/2228-prime-import, Track comment, Honcho.

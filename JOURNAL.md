# Journal render-uapi (Track #2314)

## 2026-11-20T18:32:12Z start
Read protocol, study, Mesa nouveau_drm.h (MIT), nvidia-drm-ioctl.h (existing table 0x00-0x18). Plan: header at src/nvidia-drm-render/, ioctl base nr 0x40.. (NVIDIA grows from 0x19; 0x40+ is ours), docs, man, tests.
Next: write header.
2026-11-20T18:36:07Z header + layout test written and green (10 PASS incl. 8 mutations). Next: docs/RENDER-UAPI.md, man page, PROVENANCE.md, README, gate.
2026-11-20T18:40:25Z docs/RENDER-UAPI.md, man page (lint clean), tests (layout, docs), PROVENANCE, README done. Next: gate, commit, push, Track comment, Honcho.
2026-11-20T18:48:30Z Gate round 1: 5 Opus voices, ~40 findings; fixed: renumbered to 0x45-0x4f (clear of nouveau 0x40-0x44), wrap rules (bo_offset, VM_INIT, GEM size, mmap), fence integrity + memory-lifetime rules, VRAM_USED per file + VRAM_FREE/VA_LIMIT/KERNEL_VA_MIN_SIZE params, GEM_INFO flags/pad, engine_instance 1-based, tests hardened (ioctl coverage, digit structs, skip=exit 2, docs param rows). Next: gate round 2, commit, push, Track comment, Honcho.
2026-11-20T18:57:12Z Gate round 2 (Opus, ~35 findings) fixed: private NVR_IOW macros (no DRM_IOWR clash), *_MIN limit names, EXEC push wrap and 8 MiB len, draining channels count, id exhaustion ENOSPC, close cancels unstarted waits, teardown after RM destroy, poisoned VM after GPU loss, foreign import kinds, VRAM_FREE is device-wide, GB10 = GB20B 0x1bb, docs tests derive from the header. Layout test 12 plus 3 mutations, docs test 9 mutations, all green. Next: gate round 3, commit, push, Track comment, Honcho.
2026-11-20T19:06:10Z Gate round 3 (Opus) fixed: push len 8 MiB-4, flag masks, privileged kernel-range rule, TLB invalidate before reuse, FLINK EPERM, MAX_QUEUED cap, sync-bind lock rule, compression vs NO_VRAM, header-contract macro check, header docs: tags drive the docs test. JOURNAL.md stays: PROTOCOL.md requires it in every worktree. Next: gate round 4, then commit and push, Track comment, Honcho.
2026-11-20T19:16:24Z Gate round 4 fixed: sync-bind recheck under lock, mmap EACCES rule, MAX_RESERVED byte quota, kernel range wholly privileged (fences cannot be forged), CPU_PREP ENODEV, COHERENT per placement, man page limits, docs test checks identifiers, mutations check the reason. Next: gate round 5, then commit, push, Track comment, Honcho.
2026-11-20T19:26:02Z Gate round 5 fixed zero-on-allocate, per-credential caps, bind error propagation, sticky CPU_PREP ENODEV, COHERENT rule, CHANNEL_FREE cancellation, man page remedies.
2026-11-20T19:40:00Z Gate round 6 findings addressed (CHANNEL_FREE wording, ENOSPC row, CPU_PREP precedence and clear rule, GEM_NEW EINVAL rules in the man page, digit-safe seds, README env vars). Deliberately not changed, listed for the kernel WPs and Mark: rename NVR_SYNC_TYPE_MASK / split param-minimum names (cosmetic); DRM_COMMAND_END check for LAST; a major-version number plan; brace-on-next-line struct style (the header is ours and fixed); one helper for man page prose checks. Commit follows this entry; nothing else is pending except the Track comment and Honcho lesson. Resume: if this branch head is pushed, only the Track comment and Honcho remain.
2026-11-20T20:00:00Z Gate round 7: dropped the sticky per-BO CPU_PREP error (a faulted job is reported by CPU_PREP waits, the job's signal fences and the lost channel), fixed "three ways" and the dangling map_handle sentence. Left open for the kernel WPs (decisions, not defects): union members in the pointer check, sync-bind retry progress, blocked EXEC racing CHANNEL_FREE, per-credential caps versus the per-file minimums, ENOSPC remedies, major-version number plan, and whether per-BO access info for implicit sync belongs in EXEC (N11).
2026-11-20T21:00:00Z Merge-review fixes (9475983): B1 GR channel gets the copy class, B2 UNMAP holes are no-ops and a sparse-region MAP replaces mappings, B3 no $HOME defaults, NVIDIA header pinned to 580.178.04, a missing input fails under CI or REQUIRE_INPUTS, B4 exact-value V() row for every NVR_ constant plus a coverage diff, Q9 DRM_NVR_LAST < DRM_COMMAND_END, N9 notes (section 11). Q3, Q5, Q7 stay open for Mark. New nit-level gate findings are not iterated: mutations for the new docs checks, wording of the CI failure message and SYSDIR skip text, NVIDIA_IOCTL_H documentation, scratch dir inside the tree, internal labels in the section 11 heading.
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

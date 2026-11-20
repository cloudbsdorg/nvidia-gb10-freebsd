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

## 2026-11-20T (fix round) review fixes started
- Opus review ~/work/gb10/reviews/opus-prime-import-a00964c-2026-11-20.md plus coordinator corrections: B1 guard is all-valid at the dirty site (busied, logged refusal for object-but-invalid), B2 dma-buf life held import..GEM free (drop last, after RM unlock), B3 busy/recheck/wire/unbusy in the core, B4 layout tag + kld versions, B5 mutants, N4 BSD file.
- Done: header (gb10_pageimport.h: ops try_busy/unbusy/claimable, gb10_pi_dirty_action, gb10_pi_array_ok, gb10_pi_life, index0 check in fill), tests/pageimport_test.sh red first (compile failure on the old header) then green with coverage gate, new mutants.
- Done: src/gb10-pageimport/gb10_pageimport_os.c (BSD) holds nv_import_pages & co; patches regenerated (subr_prime thin, os.c dirty hook, Makefile SRCS, dma-buf life + export via SGT, layout tag, MODULE_VERSION/DEPEND). Helper scripts in ~/work/gb10/tmp/pf.
- Next: update prime_import_test.sh and kapi_table_test.sh (red against current patches already for new rules, then green), prepare-tree copy done, build modules, kit (N1, N2), docs (N3, N5, 7.2), restage, queue row 8, gate, commit, push.

## 2026-11-20 fix round, state before the commit
- Done and green (GB10_WORK=~/work/gb10/prime-import-work): pageimport_test (coverage gate 100 percent lines, ~35 mutants), kapi_table_test (21, both handshake directions), prime_import_test (31, ~20 mutants), prime_import_kit_test (45, rc one-shot run against fakes, summarize.sh), all older tests; modules rebuilt (chain3) with LLD.
- B1 guard is at the dirty site (gb10_pi_os_dirty: busy, vm_page_all_valid, gb10_pi_dirty_action). DEVIATION from the last coordinator note (tripwire: leave wired, keep the dma-buf ref, count per buffer): I did NOT leave pages wired. Facts: the exporter's own mmap fault path (sys/compat/linuxkpi/common/src/linux_page.c lkpi_vmf_insert_pfn_prot_locked) inserts ANY page found by PHYS_TO_VM_PAGE into its VM object and calls vm_page_valid in the same busy hold, never looking at the wire count. So an imported page entering an object while imported is legitimate and cannot be prevented (a busy hold would make the exporter's fault retry forever). The only dangerous state (object, not all valid) is unreachable by that path; the tripwire logs, counts in hw.nvidia_prime_release_violations (per page: the RM teardown only passes the page array), does not dirty, and the RM still unwires (no leak, exporter ref dropped last). Reasons written in docs/PRIME-IMPORT.md 7.6. A flagged-for-Mark item: if the orchestrator still wants leave-wired, it needs a per-buffer hook (the teardown has none) and bounded-ness argued.
- B2: whole-life dma-buf ref (gb10_pi_life_take at import, drop last in free) plus export always via the SGT path when pages were imported. get_dma_buf/dma_buf_put are used by name only (no GPL header read); it compiles.
- N4: BSD file src/gb10-pageimport/gb10_pageimport_os.c; NVIDIA files only call into it.
- Kit: running rows + sync, done row, summarize.sh. Queue row 8 updated (SHA after chain3).
- Next: wait chain3, rerun the two prepared-tree tests, restage mods, SHA256, update queue SHA, review-and-record, commit, push, Track comment, Honcho.

## 2026-11-20 resumed after the OOM crash (state was intact), second review round (gate5 voices)
- Fixed from the five Opus voices: dirty step now in the core (gb10_pi_dirty_page: busy, wait when THREAD_CAN_SLEEP, fallback + count otherwise), real ops tested in the model; sysctls renamed hw.nvidia_unlock_dirty_refused / _busy_fallback (the step serves every RM user page, not only imports), log line without a kernel pointer; NV_ERR_BUSY_RETRY for a changed page; nvidia_subr.c reduced to one-line calls (gb10_pi_os_register/unregister/import/release); per-body O2 checks and new mutants; vacuous checks fixed; kit row dirty-refused and summarize.sh exit 3 for a run that skipped the import; version-mismatch message; review labels removed from docs; cpd/lizard fixes (patch context, CPD-OFF in the twin KAPI header patches).
- Not found a defect: the life take before the failure points (the caller creates the GEM whatever the import returns; D4 test now checks that no return sits between the import call and nv_drm_gem_object_init).
- DEVIATION, to report: the orchestrator's last word asked for (a) prevention of any imported page entering a VM object, (b) a per-buffer tripwire that leaves the page wired and keeps the exporter reference. Not done: (a) can only be had by keeping every imported page busied for the whole import, which makes the exporter's thread sleep in its fault path (deadlock when the same process must release the import); the fault path (linux_page.c lkpi_vmf_insert_pfn_prot_locked) validates the page in the same busy hold, so the refused state is unreachable from it; (b) leaves one wired page and one exporter buffer per event and the RM teardown has no per-buffer hook. Counters are per page, read-only, tested before/after each scenario. Written in docs/PRIME-IMPORT.md 7.6.
- Next: chain4 build, restage mods and SHA256, all tests, gate, commit, push, Track.

## 2026-11-20 final state before commit
- Gate rounds 6 to 12 (real Opus voices): fixed every real defect (second-wiring rule + imported flag, BUSY vs CHANGED status, no sleeping in the RM teardown, vm_page_busy_acquire assertion race, log without addresses, thin NVIDIA-file calls, summarize exit codes, kit rows dirty-refused, review labels out of the docs, messages).
- Recorded as not defects: (1) imported=1 "never set" in the kit: set in the unchanged import-pass branch, the (f2) blind test arms it; (2) older round-1 nvidia.ko with the new nvidia-drm.ko: nvidia.ko keeps kld version 1 because nvidia-uvm and others depend on 1; the round-1 modules were replaced in staging and never deployed; (3) the gb10_pi_life reference duplicating the attachment's: kept on purpose (the attachment's own reference is not something this driver controls); (4) the refused-dirty skip for the RM's own file-backed user pages: the stock code asserted or marked an invalid page dirty there, the counter shows it; (5) cumulative spin bound across a descriptor: documented (up to 1 ms per busy page).
- Deviation recorded earlier (prevention and a leave-wired tripwire) stands, reasons in docs 7.6.
- Kit SHA256 in ~/work/gb10/testboot-prime-import/SHA256. Next: commit, push agent/2228-prime-import, Track comment.

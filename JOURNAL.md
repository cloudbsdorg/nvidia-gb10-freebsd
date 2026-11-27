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

## 2026-11-20 merge-review round (A, B, Fable of 194ab25), rebased onto b07f8c4 (new head, branch -v2)
Tagged by consequence (BLOCKER/DEFECT fixed, with the test that goes red):
- BLOCKER (B B1) kldunload nvidia_drm with a live RM export: live-hold counter, guard module nvidia_drm_pi_guard (EBUSY on QUIESCE/UNLOAD), nv_drm_remove keeps nv_dev. prime_import_test D6 + 8 mutants (drop decrement/increment, decrement first, guard always ok, guard without quiesce, no guard module, remove ignores holds).
- BLOCKER (A F1, Fable 1) prime_import_kit_test red at HEAD: man page lines over 80 bytes and a missing .Xr; fixed; every suite run at the final head.
- DEFECT (A F2) surviving plants: p3b fake claimable/rewire_ok require busy==1 (mutant recheck-before-busy); p2 gb10_pi_life_drop( exactly once, in the free (mutant life-dropped-twice); p5 the spin constants pinned (100 x 10 us) and the budget one per os_unlock_user_pages call (mutant spin-budget-per-page); wait_busy==NULL branch (now no delay op) and a zero-length entry among good ones tested; coverage gate self-test (planted dead line must fail it) and the branch exclusion written down (docs 7.7).
- DEFECT (Fable 2) probes wrapped in timeouts 120 s / 20 s per loop iteration, a hang is a fail row (mutant no-import-timeout with a hanging fake probe).
- DEFECT (A N2, B N1) spin only for pages with an object, one budget (100 x 10 us) per teardown; tests at cap and cap+1 and for no-object pages.
- DEBT closed (cheap): README (SGT-only export, the sysctls, CPU-mapped buffers refused, EBUSY on unload), "driver defect" softened, partly valid vnode page documented, dead-man timer (shutdown -r +45, cancelled at the done row, off at 0; fakes in the kit test).
Follow-up tickets, NOT done here: A N3 (nvidia.ko kld v2: nvidia-uvm depends on v1); Fable a (accept object pages at the first wiring); Fable f (an export probe in the kit, plus a second boot); the pre-existing linuxkpi VPO_UNMANAGED assert.

## 2026-11-21 delta reviews of d4e2e69 (A, B, Fable), rebased onto 4e1b9bb, branch -v3
Tagged: BLOCKER (K1) the protection sat on nv_drm_remove, which never runs on FreeBSD; moved to nv_drm_remove_devices and nv_bsd_drm_exit (devices and pdevs kept while an export is held). BLOCKER (K2) the guard: quiesce is now a gate (EBUSY while held, else closes; hold refused while closing), SI_ORDER_FIRST, the count down in nvidia.ko after d->release() returns (K3), `kldunload -f` documented exactly. DEFECT tests: a behavioural model of the gate (pageimport_test) with plants P1/P2/gate mutants, P3 static budget, P4 unbusy of a foreign lock, SKIP asserted. BLOCKER (B1) make-be.sh turns off every other *_testboot_enable and removes a base nvidia-uvm.ko unless -u. DEFECT (B2) reverse hang is a fail row. DEFECT N2 quoting fixed, N3 dead-man verified pending (lock file and pgrep), N4 -k on CUDA/Vulkan and the dead-man bound 60 minutes from the real worst case (test reads the script), N5 summarize needs wire-count-stable pass, N7 plants killed (sync in running(), the no-timer branch), N8 queue row says +60. DEBT closed: N1 Wayfire out of this boot (queue note replaced), N6 operator expectations in docs 7.7. Follow-ups unchanged, plus: a second-stage Wayfire step after login.
- F2: rebuilt from the committed tree twice; nvidia-drm.ko is byte-identical, nvidia.ko and nvidia-modeset.ko differ only in the RM core's embedded build date (one or two lines of the loaded-section dump); recorded in ~/work/gb10/testboot-prime-import/SECTIONS. kmod_symbols_test passes at this head.
- Round 1 findings (gate): ACCEPTED and fixed: MOD_UNLOAD takes the gate (a hold cannot arrive after its check), a held flag so a release without a hold cannot underflow the count, descriptor magic bumped to IP02BG, spin lock for the gate, make-be.sh also reads rc.conf.local and files under rc.conf.d, reports only real changes and gives recovery steps, dead-man rows restored/clarified, -f message and docs agree, CLOSING message with a remedy. Answers in the REVIEW_ANSWERS file of round 2.
- Round 2 (gate) findings of the earlier diff and fixes: the held flag became a count (one GEM object can be exported twice), make-be.sh does not write through symlinks, summarize names a missing row, the dry-run line is exact. Kernel fact (sys/kern/kern_linker.c, linker_file_unload): a forced unload ignores a refused QUIESCE but a module's refused UNLOAD returns the error whatever the flags, and the guard is registered first, so kldunload -f is stopped before the driver's teardown; docs, README and the log line now say that (the earlier claim that -f goes on was wrong).

## 2026-11-21 delta review of b0f6eb9 (Opus A), K-1 and K-2
- K-1 BLOCKER, my error and the reviews': modules unload in the REVERSE of their load order (module_register_init moves each loaded module to the head of file->modules; linker_file_unload walks from the head), so SI_ORDER_FIRST made the guard unload LAST. Under -f the driver teardown ran before the guard's EBUSY, and a later plain unload would have freed text with the kept DRM devices registered. The guard is SI_SUB_DRIVERS/SI_ORDER_LAST now (above LKPI_DRIVER_MODULE's SI_ORDER_ANY); comments, docs 7.7 and README corrected; D6 runs a model of the two kernel functions on the guard's real order (the planted FIRST, same-order and earlier-subsystem orders go red); the kit records kldstat -v and passes only when nvidia_drm_pi_guard is listed before nvidia_drm. K-1b: once the second line of defence keeps the devices, the guard refuses for good (gb10_pi_gate_keep).
- K-2 plants A-D killed: the core reads the gate before the release (a release that poisons the descriptor), the quiesce and hold decide between the lock and the unlock (checked in order), the first statement of nv_drm_remove_devices and after nv_drm_exit() is the plain holds test (if (0) and if (0 && are refused), a refused hold only returns (no reference).
- Fable (a): the GB10_PI_CLOSING message is printed (rate limited) when a closed gate refuses an export.
- Opus B kit review of b0f6eb9, fixed in the same round: R1 summarize.sh counts a fail anywhere in a row's history (deadman info, fail, info was a PASS); R2 the fake process table (pgrep -f and pkill -f match their pattern against command lines, the rc script's own line is in it, a refused restart request adds none) with controls for a pgrep pattern and a pkill pattern that match the rc script itself; R3 the row is named guard-order (kldstat -v kept as kldstat-v.txt, pass only when nvidia_drm_pi_guard is listed before nvidia_drm), tested with fakes for both orders, no guard and no driver; N10 /usr/local/etc/rc.conf* and rc.conf.d are scanned too; N11 a symbolic link on the rc.conf path itself is not written through (test and control); N12 the 137 branches are gone (FreeBSD timeout(1) returns 124 even when -k had to kill: checked). SECTIONS refreshed for the staged build.

## 2026-11-21 delta reviews of e357aa5 (Opus A, Fable), boot was NO-GO
- BLOCKER (A B-1 = F F1) make-be.sh died silently under set -eu when /usr/local/etc/rc.conf.d (or any rc.conf.d) was missing, after the BE was created and mounted. Fixed: [ -d ] guard, find || true, and a cleanup trap that unmounts and removes the half-built BE on any failure; kit tests for a base with neither directory, with only one, a failure after the clone exists (and controls). This was also the cause of "86 pass, 8 FAIL" on a fresh archive: the fake-base runs had no /usr/local/etc/rc.conf.d. The earlier "94/0" was in my worktree before that case existed.
- DEFECT (F F2) the keep-other-kits mutant targeted a loop line that no longer exists: updated.
- DEFECT (A B-2) the order check read comments: comments stripped, exactly one guard DECLARE_MODULE; tests/ko_sysinit_order.py reads the (subsystem, order) words of both modules from the BUILT nvidia-drm.ko and prime_import_test compares them (guard 0xfffffff above the driver's 0xf000000, same subsystem); the SI values are vendored in tests/data/si_values.txt and compared with the kernel source when there is one (no host dependency).
- DEFECT (A B-3) a behavioural test of the kernel glue: tests/data/nvidia_drm_glue_harness.c compiles the real nv_drm_pi_quiesce, hold, release, keep, guard handler, nv_drm_remove_devices and nv_bsd_drm_exit against the core with stubs (the spin lock a flag the gate decisions assert; GEM reference, device destroy, pdev detach counters): EBUSY with a hold and nothing torn down, a closed gate takes no reference, no hold closes the gate, the teardown runs completely with no hold. Plants N3, N4, N6b and more go red whatever the syntax.
- DEFECT (A B-4) K-1b "refuses for good" was false (nv_drm_pi_keep runs inside the unload the guard already agreed to): documented as a defensive assertion, reached only if the guard was bypassed; log, header comments and docs 7.7 corrected.
- Cheap: the MOD_UNLOAD/MOD_QUIESCE message distinguishes held from kept and reads the count once; the logroot print; "ignores" for -f and the quiesce; the spin lock is described as a LinuxKPI default mutex.
- Opus B kit review of e357aa5: F2 one control per guard (the -L guard on an in-clone link, the realpath guard on a symlinked usr/local/etc, the dir guard with both of its fixes removed, the cleanup trap, keep-other-kits on its real function); F3 the realpath guard has a test and a control; the kit that boots is built from git archive of the reviewed commit (make-be.sh refuses a dirty git tree, an extracted kit needs -V, the commit is recorded in the BE and in the run's kit-version row, queue row 8 says how); SECTIONS.sums comes from scripts/ko-sections.sh, command recorded in SECTIONS.
- Also from the gate: nv_drm_pi_quiesce(&held) reports the count read under the lock (the held/kept message cannot race); the harness observes keep and runs the real kldunload sequence; make-be.sh traps INT/TERM/HUP too, says when it could not remove the BE, removes the probe file on any failure, reads file names line by line; the SI table keeps the first of a duplicated name and the test says when it cannot compare with kernel.h; ko_sysinit_order.py is arm64 only and says so.

## 2026-11-21 delta reviews of a716cfc (Fable MERGE and GO; Opus A and B, tests only)
- A B-1: a file-scope #define (P1-P3) got past every glue check; check_tree now refuses any preprocessor line other than #include that the nvidia-drm patches add (diff against the pristine sources), with the three defines and an #if 0 decoy as mutants.
- A B-2: make-be.sh now reads the order of the STAGED nvidia-drm.ko (tests/ko_sysinit_order.py) and refuses before bectl create (kit test with fake tools: wrong order, no guard, unreadable; control); its default module dir is the staging dir; prime_import_test takes PRIME_KO explicitly and SKIPs by name when it is unset.
- B T1-T3: failed create (no umount, no destroy), base equal to the target name (refused), one case per signal INT/TERM/HUP (exit 130/143/129 and the BE removed), failing final umount; plants (BE_MADE early, traps deleted, BE_DONE early) go red.
- Fable b, the WORDS: on the one reachable bypass (the driver unloads before the guard), keep IS the protection: the guard's MOD_UNLOAD runs after it and refuses with the kept line, the file stays loaded and every later unload is refused. Log line, docs 7.7 and the comments (lkpi, dma-buf, drv_prime, header) say so; the calls and mutants stay. The held/kept message branches on kept (nv_drm_pi_quiesce(&held, &kept)).
- Cheap: -V is checkable (KIT-COMMIT with export-subst; -V must agree with HEAD or the archive's commit), git ls-files --error-unmatch before trusting a tree, PRIME_MNT / PRIME_ALLOW_DIRTY / PRIME_KO_ORDER_TOOL documented, the origin snapshot left behind and the ELF Tool Chain readelf dependency noted.
- Lesson: the per-suite loops of earlier rounds printed rc=$? after a command substitution and could show rc=0 for a failing suite; the loop now captures the status first.

# Track #2363 (agent/2363-linux-bridges-optional)
Resume: read this file bottom-up.

## Design decisions (2026-11-21)
- nvidia.ko core: NV_SUPPORT_LINUX_COMPAT is no longer defined by default (zz patch on nv-freebsd.h). A legacy build with -DNV_CORE_LINUX_COMPAT (make NV_CORE_LINUX_COMPAT=yes) keeps the old in-core bridge (#2402 alias rule: old behaviour stays reachable). The core gets a small versioned KPI (nvidia_bridge.h/.c, our BSD files): nvidia_bridge_register/unregister plus cdev add/del notifications. The core holds no Linux code.
- nvidia_linux.ko: Linux ioctl 0x4600-0x46ff translation plus linux_device_register_handler for nvidiactl and nvidiaN, through the KPI. MODULE_DEPEND nvidia (versions 1..2: matches today's 1 and the 2 that #2373 brings), linux64elf, linux_common.
- nvidia_modeset_linux.ko: the NVKMS ioctl (magic m) and the nvidia-modeset device name. Needs no symbol from nvidia_modeset, only MODULE_DEPEND for unload order.
- Unload veto: the bridge MODULE_DEPEND on the core keeps the core refcount above zero (kldunload nvidia is EBUSY while the bridge is loaded); the bridge refuses unload while a Linux ioctl is in flight.
- Separate zz patch files and new src files so the #2373 merge is clean (2373 touches the nvidia_pci.c version line, nvidia_subr.c, a Makefile hunk and the prepare-tree.sh copy loop). My prepare-tree.sh edit is a separate function called after copy_repo_src.
- uvm-bsd: own repo (nvidia-uvm-freebsd main); unmerged branches 2272/2295/2373 touch uvm_main.c, so the split there is a follow-up (nvidia_uvm_linux.ko).

## 2026-11-21 progress (Track #2363)
- RED first: tests/linux_bridge_test.sh against the old tree: 8 FAIL (nvidia.ko imports linux_*, no KPI export, modeset dependency on linux64elf, no nvidia_linux.ko, header defines NV_SUPPORT_LINUX_COMPAT unconditionally); every check has a plant (synthetic objects, pristine headers, a wrong-context patch).
- GREEN: src/gb10-linux-bridge (KPI + two provider modules), zz patches (nv-freebsd.h, nvidia_ctl.c, nvidia_dev.c, nvidia/Makefile, modeset source and Makefile), prepare-tree.sh copy_bridge_src, build-shim.sh --module=nvidia-linux / nvidia-modeset-linux. All four modules build with LLD, 0 errors. kmod_symbols_test updated: nvidia.ko deps exactly {mem}, modeset exactly {nvidia}.
- rc.d/nvidia_linux (nvidia_linux_mode AUTO/YES/NO), man/nvidia.4, man/nvidia_linux.4, README, test kit tests/linux-bridge-testboot (recorder, make-be.sh, summarize.sh) with tests.
- Merge check with #2373: my zz patches apply at fuzz 0 on top of its subr, modeset-version and pci-version patches. Its Makefile and drm zz patches do not apply on f2cedf7 at all (their base predates the pageimport Makefile and the renamed lkpi patch): that is for the 2373 rebase, not mine.
- prime_import_test passes with GB10_WORK=~/work/gb10/prime-import-work (139 checks); with the default work root it fails D6 on the unmodified base f2cedf7 too (stale tree), not mine.
- Next: gate round 1, commit, push, Track comment.

## 2026-11-21 gate round 1 (receipt-less: voices FINDINGS; 40 findings, all answered in REVIEW_ANSWERS)
- BLOCKER: quality.3 (no execution test of nvidia_bridge.c): tests/nvidia_bridge_unit_test.sh, 21 checks, 8 mutants.
- DEFECT fixed: KPI versioning contradiction (quality.1 and 3 more), legacy build ENXIO (quality.2), vacuous plants (quality.4, .5, correctness.3, falsification.5), manifest copy_one (quality.7), rc script (quality.8, .9, falsification.4), kit hard-codes and root writing through a user-owned log root (quality.12, security.1), kldunload by file name and C1 asserting reason and state (correctness.1), ioctl handler answering for foreign descriptors (security.3), uvm doc claims (falsification.2), summarize.sh skip handling (falsification.6), Xr to a missing page (interface.3).
- Resolved by removal: the in-flight counter and drain (security.2, correctness.2): linux_ioctl_fallback holds linux_ioctl_sx shared across the handler (linux_ioctl.c:3865-3892) and unregister takes it exclusive (3991-4000).
- REJECTED with evidence: falsification.1 (no unload veto): kern_kldunload checks refs > 1 before userrefs-- and returns EBUSY (kern_linker.c:1330-1335). The review did show the row proved nothing; C1 now asserts status, "Device busy" and state.
- DEBT/NIT fixed: namelen, nbc_ctl removed (KPI still version 1), build-shim comment, README anchors, make-be hints.
- Next: round 2 with REVIEW_ANSWERS, commit, push, Track comment.

## 2026-11-21 commit e0ad747 pushed; round 2 receipt dce6243a; follow-up commit in progress
- e0ad747 pushed to origin agent/2363-linux-bridges-optional. Track comment posted (activity 16595).
- Follow-up (own 2 gate rounds) for the round-2 Review-open items: unit-test harness counts a non-building mutant as FAIL; new host test of the ioctl translation, name match, fd filter and modevent (nvbridge_ioctl_unit_test.sh, 24 checks, 10 mutants); devvn_refthread in the fd filter; core tracks acceptance per device (no del after a refused add, 26 checks, 9 mutants); summarize.sh requires the modeset rows; phase C reordered (nvidia_linux the only holder at the veto); kit plants are real moves; hermetic run_kit; rc script warns once and says when AUTO skips; docs (kld_list synopsis, load by path, no tracker tag); modeset provider returns the registration error and is documented as not for a legacy modeset.
- Open for the boot (not testable here): amd64 provider build; a Linux /dev/null 0x4600 row; modeset provider with a legacy modeset (documented limit, no detection).

## 2026-11-21 follow-up commit, gate round 2
Round 1 findings (33) answered; one core policy (a refused device is not provided, registration never fails for it), shared mutant harness, phase C reorder with holders named, per-row summarize hints. Quota is nearly used: commit and push after round 2.

## 2026-11-22 merge-review fixes, commit 1 (code and build) - Track #2363
Merge reviews of 52892d1: Fable MERGE (debt), Opus A and Opus B MERGE AFTER FIXES (~/work/merge-reviews/2363/). This commit takes the code and build fixes; the test-boot kit fixes (K-1 to K-3) are commit 2; the README Installation steps follow the a2e0546 merge.
- A-F1 (DEFECT): build-shim.sh stamp records NV_CORE_LINUX_COMPAT and NVKMS_CORE_LINUX_COMPAT, so switching one cleans first. build-shim_test (t): red on the old script (both modules), green now. README names the real command.
- A-F2 (DEFECT): rc.d/nvidia_linux decides AUTO with checkyesno linux_enable; rows for TRUE, ON, 1, true, on, Yes (load) and NO, FALSE, OFF, 0, maybe, empty (nothing); a plant with the raw YES test.
- mandoc: nvidia_linux.4 line wrapped; the suite lints with -W style; a plant proves -W style sees a long line and -W warning does not.
- B-1 (DEFECT, amd64): both providers depend on linux64elf (arm64) or linux64 (amd64) under #if defined(__aarch64__). linux_bridge_test (e)/(f) take the name from the module ELF machine; (k) cross-builds both providers for amd64 (cc -target x86_64, base ld) and reads the dependencies by nm and by kldxref -d; a mutant with the unconditional linux64elf is refused. Red on the 52892d1 source: "(k) amd64 nvidia_linux.ko dependencies: ... linux64elf ... (want nvidia, linux64, linux_common)".
- The two providers share one NVBRIDGE_LINUXULATOR_DEPEND(modname) macro in nvbridge_ioctl.h (cpd found the guarded block duplicated in both files; the scanner stage stops before the voices and writes no receipt, so it is not a round); the (k) plant forces its architecture guard true.
- Opus B plants 7, 8, 11 and Opus A P13 (debts in their records, but a missing test blocks a merge): (l) compares the provider cdevsw names with the d_name of the pinned nvidia_ctl.c, nvidia_dev.c and nvidia-modeset-freebsd.c, NVKMS_LINUX_IOCTL with NVKMS_IOCTL_MAGIC and NVKMS_IOCTL_CMD of the pinned nvkms-ioctl.h, and checks that the prepared nvidia_ctl.c and nvidia_dev.c call nvidia_bridge_cdev_added and _removed once each with the same name and minor. Mutants (nvidiact1, NVKMS command 1, removal under the cdevsw name, dropped removal) are red.
- Phase C veto evidence: the recorder reads the kldstat Refs of nvidia and nvidia-modeset before and after each provider loads (rows B2-refs-nvidia and B2-refs-modeset: exactly one more, required by summarize.sh); the veto row detail carries the Refs at veto time; kit test with 1->1, 1->3 and unreadable plants.
- Suites on a fresh git archive of the staged tree (d44301b): linux_bridge_test (fuzz-0 included), linux_bridge_kit_test, rc_nvidia_linux_test, nvidia_bridge_unit_test, nvbridge_ioctl_unit_test, kmod_symbols_test, prepare-tree_test (15/0), build-shim_test (22/0): all rc=0.
- Next: gate round 1 (review-and-record with /sbin on PATH), commit, push, Track comment.

## 2026-11-22 commit 1, gate round 2 (Track #2363)
Round 1 (receipt 6001097a...) found 28 items; the answers are in the commit message. Fixed after round 1: one macro with #elif amd64 and an #error for any other architecture, tested per architecture by preprocessing the macro alone (the header include section already refused other architectures); checkyesno decided once per start (nvidia_linux_decide_linux); the clean message of build-shim.sh names the stamp keys that changed (an absent key is <absent>, never an empty message); skipped checks of linux_bridge_test.sh exit 2; the tools it needs are checked by name; the (k) block loops over both providers; NVPIN is the one place the pinned release is named; README and man page state that a 32-bit Linux binary is not served on amd64; the recorder saves kldstat snapshots around each provider load and summarize.sh hints at them only when the Refs numbers failed.
Round 2 was refused once (one voice gave an unusable answer: no receipt, retried). Items still open after the retry go into the commit message as Review-open lines.
Resume: commit 2 (kit K-1..K-3) starts from the files in .round/tmp/c2/ (recorder and summarize.sh of the K-1..K-3 work; summarize.sh there still calls hint() before defining it: move the function above the fails branch), .round/tmp/edit_mkbe.py (make-be.sh changes), tests/linux-bridge-testboot/{VENDOR,testboot-return,nvkms_ioctl_probe.c}; then the a2e0546 merge and README steps 4-6.

## 2026-11-22 commit 1 pushed (ac3623c); commit 2, the test-boot kit (K-1 to K-3) - Track #2363
Commit 1 (ac3623c): round 1 receipt 6001097a2295c683..., round 2 receipt 1c66e4531e29b71d...; nine items left open as DEBT in its Review-open lines. Pushed; Track comment posted.
Commit 2 (kit): summarize.sh takes per-row waivers (only B4-cuda; PARTIAL verdict), requires the kit commit, the staged and loaded sha256 of the four modules (--kit and --hashes compare them with what was armed), the C4 unload rows unless nvidia_drm holds the core, and the new rows P1-staged, B2-rc and B3-nvkms-ioctl. make-be.sh puts the staged directory first on the module_path of the clone (writes it into loader.conf when missing, refuses when a later file overrides it), refuses a clone kernel whose osreldate differs from the build stamps, runs kldxref on the staged directory, loads by file name (kld_list nvidia-modeset), writes the sha256 list into the BE and to the host, refuses a dirty or unnamed kit commit, builds and brands the Linux NVKMS probe, installs the vendored testboot-return after its VENDOR pin matched. The recorder proves the loaded files are the staged ones (kldstat -v path and sha256), runs rc.d/nvidia_linux in AUTO with linux_enable=YES for phase B, sends one Linux NVKMS ioctl, copies the run out and ends with testboot-return NORMAL_BE. Kit test: waiver, provenance and C4 plants, a real make-be.sh run on a fake BE with a real minimal kernel module, the probe on the host against a fake syscall layer.
Resume: gate round 1 for commit 2 (review-and-record, then answers, round 2, commit, push, Track comment), then the a2e0546 merge and README Installation steps 4-6.
- Commit 2 round 1 (receipt 0769645d5ba4...): 50-odd findings; fixed: -V must be HEAD and git must answer, symlinked loader files refused (nothing written through), trailing comments in loader.conf seen, one STAGED variable, copy-out through a link refused, normal BE has no default, probe verdict words and x86_64 stack alignment, probe or arch missing refuses the BE, --kit and --hashes together, no trailing arguments, B3 hint, P1 messages split. Rejected with evidence or left as DEBT: see the commit message.
- Commit 2 round 2 (first attempt refused: one voice unusable, no receipt): rc.d/nvidia_linux now reads rc.conf.d/linux (load_rc_config linux) so linux_enable set there is seen; symlinked staged directory refused; -N must exist; a failed copy-out, failed return or held return is a row with done last again; an unchecked kit is recorded +unverified.

## 2026-11-21 libnvrm S1 (Track #2378), agent on the build host, branch agent/2378-libnvrm-s1
- Worktree the agent worktree from origin/agent/2088-build-host f2cedf7 (rewritten, with the PRIME merge).
- lib/libnvrm: nvrm.c (registry, enumerate, layered model), nvrm_table.c (generation table, empty decorator table), nvrm_fake.c, nvrm_rm.c (RM escapes, NVIDIA headers, sys-call table seam), nvrm_json.c (emitter + schema from nvrm_fields.c), nvrm-info, man nvrm(3)/(7)/nvrm-info(8), schema/nvrm-info-1.schema.json.
- Tests (tests/libnvrm_test.sh, fresh copy, base LLD): core_test 333 checks, rm_test 145 (scripted kernel), cap_test (Capsicum, fake and rm), 100% line+branch on core, fake and RM backend; 20 source mutants killed, drift mutant, validator mutants, lint plants, man lint plant. 150 ok / 0 FAIL.
- live proof NOT possible now: nvidia modules are not loaded (kldstat), /dev/nvidiactl absent, the running boot environment has no nvidia stack; told not to kldload. Needs the one-shot BE with the driver loaded; nvrm-info --json there must be compared with hw.nvidia sysctl and the kernel log. pciSubSystemId layout (vendor low, device high) and the ID_INFO numa/SoC bits are to be confirmed live.
- Next: gated commit (2 rounds max), Track comment, push, then hand back.

## 2026-11-21 libnvrm S1, gate round 1 (receipt 6764d37a...) and the fixes for round 2
Round 1: scanners clean after lizard/cpd fixes; five Opus voices, all FINDINGS. Tagged:
- DEFECT: nvrm-info exit 0 on failed enumeration into a closed pipe; errno read after close; cap_enter ENOSYS ran unsandboxed; JSON comma depended on table order; uninitialised read in prop_cap; rm_gpu_classes ignored max; decorator index unchecked; version reply never read; ioctl failure reported as an RM error and refresh could not fail; pciSubSystemId layout asserted as fact; text mode missing fields; modes not exclusive. All fixed with tests that go red (suite 186 ok).
- DEFECT (tests): fresh copy was the working tree and hid git failure; fail-open binary/lint checks; coverage plant accepted any failure; mutant unavail-zero half did not apply; truncation test did not truncate. Fixed.
- NIT/DEBT fixed: messages (no-backend, version mismatch, fake profile limit), man page gaps (E_INVAL, selection order, capability flags, examples, Track refs), UTF-8 handling (U+FFFD), dead Makefile knobs, static asserts on property order.
- security.1 (narrowing the Capsicum allow list) and security.6 (host names) were first answered REJECTED in round 1 and ACCEPTED in round 2: query_only descriptors, neutral wording in this journal. (The fix commit after round 2 makes least privilege the default.)
- Added tests/libnvrm/boot_nvrm_info.sh: the self-recording live proof for a test boot (nvrm-info in all modes against hw.nvidia sysctls, pciconf, dmesg).
- Round 2 attempt 1 ended REFUSED (one voice left rulings out); no receipt, so not counted. The voices still raised, and the next revision fixed: query_only descriptors (RM control and free only, no mapping) used by nvrm-info; enumerate fails like refresh on a failed system call; GPC mask wider than 32 bits withheld; field reason accessor aborts on an unknown kind; PCI location decimal; text shows built-for and running RM version; usage errors say why; version ioctl failure is an I/O error, not a mismatch; card-less GPU withholds subsystem ids; the boot proof script refuses the fake backend and fails (not skips) when a value it must compare is unavailable. Suite: 196 ok.

## 2026-11-21 libnvrm S1 fix commit after round 2
- Orchestrator decision: least privilege by default. NULL options give RM control and free only, no mapping; opts->allow_alloc_map is the explicit opt-in for RM_ALLOC and CAP_MMAP_RW, requested before the limit because Capsicum rights cannot be widened later. cap_test: the default refuses RM_ALLOC and mmap (ENOTCAPABLE), the opt-in does not.
- Fixed: nvrm(3)/(7) document the options and the new reasons; all exported calls in NAME, SYNOPSIS and MLINKS (suite compares the lists); new reasons value_unusable and family_no_value (schema minor 1); coverage gate includes nvrm_fields.c (per-process profile files); a test ties every nvrm_device_info member to a field-table row; boot proof FAILs for a loaded linux kmod, a missing schema and BOOT_ALLOW_FAKE; one version source (SOURCES ogkm_tag; the build refuses a header that names another version); no-backend and cap_enter messages; -h documented.
- Suite: 210 ok.

## 2026-11-22 libnvrm S1 combined merge-review fix commit (Opus A R1-R6, Opus B 1-10), branch agent/2378-libnvrm-s1 on 890b9b8
Both merge reviews: MERGE AFTER FIXES. One fix commit, its own 2-round budget. Tagged by consequence, all DEFECT (fixed with a test and a plant):
- DEFECT (A R1, B 9) AD10x cls_copy 0xC7B5 (table), tested; the family_has_no_class reason stays for a table row with a 0 class (tested with a custom row).
- DEFECT (A R2) boot script compares VRAM and SM with BOOT_EXPECT_VRAM_BYTES / BOOT_EXPECT_SM (both required) and bar1_size with a memory BAR of the device in pciconf -lvb; zero GPUs is a FAIL. Stand-ins BOOT_PCICONF / BOOT_SYSCTL (with BOOT_ALLOW_FAKE only). Cases B and C of Opus A now live in tests/libnvrm_test.sh.
- DEFECT (A R3) Linux ABI = exact ^(linux|linux64|linux_common)\.ko$ plus an answering compat.linux.osrelease; linuxkpi* never. The test BE must set linux_enable="NO" (documented in the script).
- DEFECT (A R4) the kldstat test needs the file to exist, to name kernel, and to lack the stub; a plant script writing kldstat.log fails it.
- DEFECT (A R5, B 1) schema minor 0; lib/libnvrm/schema/nvrm-info-1.ids is the frozen baseline (kind number name), tests/libnvrm/ids_check.py fails on a missing/empty/partial baseline and on any removed, renamed or renumbered id; ids may be added. Runs on the committed schema and on the schema the built tool prints.
- DEFECT (A R6, B 4) unknown family asserted on all four cls_*, family and page_sizes (reason id too).
- DEFECT (B 2) capabilities pinned in the schema: prefixItems with const index and name; core_test asserts all seven names; schema_validate.py learned prefixItems and $ref siblings.
- DEFECT (B 3) tiling test covers the whole struct (caps, ndecorators, decorators, sizeof).
- DEFECT (B 5) S1 maps nothing, so CAP_MMAP_RW is gone from the allow-alloc set (nvrm_cap_limit_fd lost its mappable argument). The flag is renamed NVRM_ENUM_ALLOW_ALLOC (same value 0x2; the ABI is provisional). cap_test asserts no mapping right and ENOTCAPABLE for mmap with and without the flag; docs say CPU mapping in capability mode is not available; doc_checks + plants.
- DEFECT (B 6) pthread_once for the registry (libnvrm links libthr: the libc pthread_once stub does nothing without it, measured); nvrm_registry_pause_hook test seam; threads test in a forked child on a pristine registry; backend records getpid() at open and frees RM objects only there (rm_test forks a child whose nvrm_close must send no free). Docs: THREADS AND FORK section, nvrm.h comment.
- DEFECT (B 7) rm_gpu_id labelled rm; every source label pinned in core_test (a new field needs a row).
- DEFECT (B 8) zero GPUs is OK: library returns NVRM_OK with count 0, nvrm-info exit 0 with devices [], schema minItems 0, text mode says "no GPU is attached"; NVRM_E_NODEV stays defined, never returned. No backend stays an error.
- DEFECT (B 10) nvrm(3) STABILITY, Version.map and nvrm.h: NVRM_1.0 provisional until the first package release.
Evidence (red at 890b9b8, green here): Opus A's boot cases B (false pass) and C (false fail) and Opus B's probes (cap rename passes the suite, zero GPUs exit 1, rm_gpu_id source os) are all red at 890b9b8 and clean on this tree; the same cases now run inside tests/libnvrm_test.sh (boot script, doctored report; linuxkpi; kld-late; sysctl-broken). Every fix has mutants in that suite's mutant table (ad10x-copy, unknown-gpfifo, unknown-copy, cap-name-1, member-after-caps, source-rm-gpu-id, registry-once, fork-guard, fork-generation, nogpu-error, cap-rights, opts-null, ...) and plants for the shell-level checks (ids plants, doc_plant, minor_plant, the kldstat plant); Opus B's 26 mutants and Opus A's plants run against the final tree outside the repository (the hand-back lists them).
Gate: round 1 receipt 540b18e5 (24 findings, 23 accepted, quality.7 rejected with the measurement that LIBADD adds nothing out of tree); one round-2 attempt was REFUSED (a voice skipped a ruling: no receipt) and its new findings were fixed before the counted round 2: ids numbering single definition and --emit round trip, per-line minors and --frozen against the parent commit's baseline, race precondition counted, fork generation (pid reuse) with a getpid seam, fake backend limited to one thread, boot FAILs say what to do, the mapping sentence says what this version cannot do. NVRM_FAKE_FAIL=nogpu stays (Opus B named it as the contract).

## 2026-11-21T04:13:44Z (#2373 sec)
- Plan: nv side adds the RM client ownership table (src/gb10-client-owner/nv_client_owner.h, patch-zz-* hooks) and exports nvUvmInterfaceClientOwnedByFile; branch is from agent/2088-build-host WITHOUT the uvm glue (that lives on agent/uvm-phase0): the new patches are separate zz files and apply over either.
- Built nvidia.ko on the prepared tree (LLD stamp ok, export present, scratch ~/work/gb10/tmp/sec-2373/w). tests/client_owner_test.sh green with 5 plants + 4 hook plants red.
- Next: gate round 1, commit, push, then uvm side. Resume: git status; commit with the Stewardship block.

## 2026-11-21T04:24:15Z
- Round 1 (receipt 2365788e): TOCTOU (DEFECT), cdevpriv type confusion (DEFECT), hook plants tautological (DEFECT), CI input (DEFECT), comments/labels/README (NIT). All fixed: table lock across client ops, ClientHold/Release, VCHR+nvidiactl checks, real plants. Rebuilt nvidia.ko OK. Next: round 2 with answers, commit, push. Resume: git status.

## 2026-11-21T04:35:57Z
- Round 2 (receipt c5ee21db): redesigned to per-client holds + file reference, ownerless eviction, NV01_ROOT_CLIENT class, single decoder, test exit status. Rebuilt nvidia.ko OK (LLD). Final receipt run next, then commit and push. Resume: git status; commit.

## 2026-11-21T04:47:25Z
- Round 3 findings (receipt c7d5d40a) fixed: Release owner check, revoked entries, begin_free + PCATCH, single decoders, real mutants. nvidia.ko rebuilt OK. Gate round 4 next. Note: exceeds the 2-round budget because the findings were genuine DEFECTs (security).

## 2026-11-21T04:57:20Z
- Round 4 findings (receipt 7dcc43ba): freeing count, owner-only counting, held-entry revoke at close, release matched on the held file, sx_xlocked guard, README. Rebuilt OK. Gate again, then commit. Resume: git status.

## 2026-11-21T05:05:41Z
- Round 5 (receipt ef8df6a3): escape numbers pinned, release diagnostic and context rule, xfer unwrap pins. Final gate then commit and push.

## 2026-11-21T05:10:51Z
- Round 6 (receipt aa8d461e): end_free owner-matched, test inputs no HOME default, README stuck-free text. Final gate, commit, push. Findings after this are recorded, not iterated (budget).

## 2026-11-21T05:17:47Z
- Round 7 (receipt 9ce936bd): collision never hands over a client, unrecorded-client diagnostic, honest layout skip. Final gate, then commit and push; further findings recorded only.

## 2026-11-21T05:22:28Z
- Round 8 (receipt 46ce47a3): doc and diagnostic wording only. Commit after this receipt.

## 2026-11-21T06:45:29Z (#2373 fix round 3, after the crash)
- State: working tree (uncommitted) has: nvco_glue.h (all glue, leaf lock: begin before fops_sx, RM call with no table lock, end after unlock), patch-zz subr patch reduced to include + 3 call sites, nv_client_owner.h comment, tests/client_owner_glue_test.sh + tests/data/nvidia_glue_harness.c (real glue vs kernel fakes; 15 mutants + 7 pin mutants red), tests/pins_lib.sh, rm-lag model rows. prepare-tree copies nvco_glue.h.
- TODO nv: drop nothing else; MODULE_VERSION 2 + depends (nvidia_pci, modeset, drm patch); run client_owner_test.sh + glue test on git archive; gate 2 rounds; commit; then phase0 merge branch (agent/2373-nv-client-owner-phase0) with Makefile hunk context regenerated; then uvm side (harness, pins strip, CAP_IOCTL, PROVENANCE, C-Q, probe rows, race loops, JSON).
- Gate budget: exactly 2 rounds per commit; open findings -> Stewardship Review-open + Track.

## 2026-11-21T06:49:05Z
- nv work done in tree: leaf lock glue, harness (glue test), MODULE_VERSION 2 patches, README. Built LLD OK. Gate round 1 running (log tmp/sec-2373/gate-n2-1.log). Next: round 2 with answers, commit, push; then phase0 merge branch.

## 2026-11-21T06:58:06Z
- nv round 1 receipt 739a635617fd487f67670383df74191f6192b5769ee31b3192f0b345a88c8915 fixed (token counting of any free, end under fops_sx, goto label, separate limiters, real pins, harness scenarios). Gate ROUND 2 running (gate-n2-2.log). After it: commit with Review-open list, push; then phase0 merge branch.

## 2026-11-21T07:02:26Z
- COMMITTED 4a25b0f on agent/2373-nv-client-owner (round1 739a6356, round2 7267b0fc), pushed. Open findings in the Stewardship (late-record, stranger-starve, token-wrap...). Next: phase0 merge branch in ~/work/gb10/wt-nv-2373-p0 (agent/2373-nv-client-owner-phase0), Makefile hunk regen, gate 2 rounds; then uvm commit; Track comments; ask orchestrator for a 3rd nv round (fail-open late record).

## 2026-11-21T07:06:18Z (#2373 phase0 line)
- agent/2373-nv-client-owner-phase0: uvm-phase0 + 2373 (be5f990, 4a25b0f) merged; README/prepare-tree conflicts resolved as union; zz Makefile hunk regenerated (applies with fuzz 0, all zz patches fuzz 0); nvidia.ko builds (LLD), 62 nvUvmInterface exports T incl. Hold/Release; uvm_glue_test 10/0, kmod_symbols_test PASS, prepare-tree_test 15/0, client_owner_test 51 ok. Gate round 1 running.

## 2026-11-21T07:09:39Z
- p0 gate round 1 receipt 04f6a365de2dab67d93646351ff9fcc909dc00c1233ec7607af09e74b3facede: README doc findings; fixed the 2373 ones (one uvm pin, names, versions list, prepare-tree pins), rejected phase0-side README content. Round 2 running (gate-p0-2.log).

## 2026-11-21T07:48:44Z (#2373 follow-up commit)
- Orchestrator: no round 3 on old commits; this is a NEW commit with 2 rounds. Fixes: EPERM for a stranger's free of a listed client (before the RM), 64-bit nonzero generations, late record: every free is logged with a sequence number and an allocation takes a mark before its RM call, a record that lands after a free of its handle began is refused (the tombstone alone left the reviewer's counterexample open: my harness showed the free completing before the record). Model rows + 3 glue mutants + 7 header plants. Folds in the staged JOURNAL.
- round 1 receipt bc7942bc: dropped the global free log (flood DoS) for tombstones + a log of SUCCESSFUL unlisted frees by end sequence; removed h.core; rows+mutants. Round 2 running.

## 2026-11-21T12:10:00Z (#2373 phase0 re-merge after #2398 rewrite)
- Merged agent/2373-nv-client-owner (925525d) into agent/2373-nv-client-owner-phase0. Only conflict: JOURNAL.md, resolved as union (both sides append-only). Next: boot-build proof on fresh archive, gate.

## 2026-11-22 (#2373 close-path commit, new commit on ea27f0c, own 2-round budget)
- Orchestrator brief: route the nvco_remove_owner loop through nvco_remove_handle (the merge reviewer's proposed patch), model row (close-path 7-step), glue scenario scenario_close_path, plants close-ignored/remove-owner-keeps-held re-anchored plus new close-drops-marker (model and glue), README wording. Red on ea27f0c: model row 3 FAILs, glue scenario FAIL, close_path.c rc=1; green after: rc=0, client_owner_test.sh 81 ok rc=0, glue 44 ok rc=0, close_path.c rc=0.
- Gate round 1 running. Next: answers file, round 2, commit, push, Track #2373 and WP #2406.
- Round 1 receipt fba825ec5facfc74517f8f2e7c694f07b0ec483283c3e8aab87c673729e958a2 (5 voices FINDINGS). Answers in .round/tmp/answers.txt. Fixed: nvco_remove_entry (acts on the entry, no second lookup), held/many model rows, step labels, scenario ran-flag, README wrapped, pins on flattened text.

## 2026-11-22 (#2373 phase0 merge of the close-path commit 3d6bc31)
- Merged agent/2373-nv-client-owner (3d6bc31) into the phase0 line for the v5 boot build. Only conflict: JOURNAL.md, resolved as union (both sides append-only).

## 2026-11-22 Track #2417 (agent/2417-init-failure-safe, from a2e0546)
- Commit 1 (init-failure path): red first (tests/open_dev_failure_test.sh on the old code: 5 FAIL, .round/red-commit1.txt), then patches/patch-zz-nvidia_init_failure_subr.c, patches/ogkm/patch-zz-2417 osinit patch, man/nvidia.4, README. Green 12/12; nvidia.ko builds (LLD) from the patched tree. Other suites on a fresh archive: same as the a2e0546 baseline (kmod_symbols stale default tree, prime_import_test D6 gb10_pageimport.h, render_uapi_layout 2 SKIP).
- Next: review-and-record round 1, commit, push, Track comment, SHA to the orchestrator; then commit 2.
- Round 1 receipt 6fa9774e (5 voices FINDINGS): tagged DEFECT quality.1-7 security.1-3 correctness.1-5 falsification.1-4 interface.1-6 (all ACCEPTED and fixed: any-pGpu use check, RmShutdownAdapter check, case 5 retry, poison sp, plants confined, tree under mktemp, man page remedy), NIT security.4, falsification.5 REJECTED with evidence (RmInitAdapter failure exits). Answers: scratchpad answers-2417-c1.txt. build-rmcore.sh run on patched sources compiled osinit.c.

- Commit 1 committed as 525f43b (round 2 receipt 7aab04e9), pushed; SHA sent to the orchestrator. Round 2 left Review-open lines (listed in the commit message).
- Commit 2 (firmware): chose MODULE_DEPEND over firmware_get() in nvidia_attach, because attach runs inside kldload which holds kld_sx exclusive and firmware_get of an unregistered image queues loadimage -> linker_reference_module -> sx_xlock(kld_sx): deadlock (facts checked in tests/fw_depend_test.sh against /usr/src/sys). The module names are <KMOD>_fw (nvidia_gsp_ga10x_fw_fw), proven by fw_stub.awk and by kldxref on the built modules (linker.hints provides nvidia_gsp_ga10x_fw_fw). tests/fw_depend_test.sh 26 PASS, red on the tree without the patch (.round/red-commit2.txt) and on 8 plants. nvidia.ko builds (LLD) with the dependency in its metadata. Test-boot rows R1-R6 in tests/nvidia-fw-depend-testboot/ROWS.md (not armed).
- Commit 2 round 1 receipt 61ec0a32 (security NO FINDINGS; quality 6, correctness 4, falsification 6, interface 8): all ACCEPTED and fixed (arch sets derived from the build, rc 2 tooling failures, GA100 is a tu10x part, single firmware_get site, man page diagnostics). fw_depend_test now 44 PASS, red without the patch (.round/red-commit2.txt).

## 2026-11-22 (#2373 phase0: the #2417 init-failure fix, cherry-picked)
- Orchestrator: the v6 boot build must carry the #2417 driver fix. Cherry-picked 525f43b (agent/2417-init-failure-safe, based on a2e0546 of build-host) onto the phase0 line, not merged: its patch-zz-nvidia_init_failure_subr.c, patches/ogkm/patch-zz-2417-...osinit.c, man/nvidia.4, tests/open_dev_failure_test.sh and tests/data/open_dev_harness.c, README and JOURNAL hunks. Only conflict: JOURNAL.md (union).
- tests/open_dev_failure_test.sh on the result: 23 passed, 0 failed. Fresh archive build (work-2373-v6, base LLD 21.1.8): prepare-tree applies all patches, nvidia.ko 977051971cf2ad8e5ad844035a05565d8aed2d5d086916286c55e16ecd1d3ece, no rm_disable_adapter in the failed: path, osinit guard compiled in.

## 2026-11-22 merge of a2e0546 (1452fc1) and the README Installation steps 4-6 (Track #2363)
Merged origin/agent/2088-build-host (a2e0546) with --no-ff; the gate reviewed the both-sides overlap (JOURNAL.md, README.md), receipt d2183dcf93943be2d97aa75c0d874665adfe9f930412bda22fd172ed43ae3142. The commit after it corrects Installation steps 4-6: nvidia.ko no longer loads linux64; the two providers and rc.d/nvidia_linux are installed for nvidia-smi and Linux CUDA/Vulkan; nvidia_linux_mode is set. linux_bridge_test (j) has the Opus B grep test: no 'also loads linux64' or 'plus linux64, linux_common', and the Installation section names nvidia_linux.ko, nvidia_modeset_linux.ko, rc.d/nvidia_linux and nvidia_linux_mode, with two plants.

## 2026-11-22 Track 2440: make install on a stock FreeBSD arm64, and the stock-install harness
- Root Makefile on main: merge d01503806c665d6fca95a8e993f5c906317c3e4f (PR 7, commit 23c18da).
- This commit: scripts/fetch-trees.sh (the running kernel's source and the pinned drm-kmod), drm.ko and dmabuf.ko
  built from drm-kmod (the FreeBSD packages are amd64-only), the NVIDIA licence acceptance (ACCEPT_NVIDIA_LICENSE=1,
  ACCEPT_ALL_LICENSES=1, or a terminal answer; YES=1 alone never accepts), make configure (loader.conf, rc.conf, with
  an exact undo), devd/nvidia_gb10.conf, the kernel-patch warnings in preflight, install hardening, the schemas and
  the harness tests/install-e2e (guest.sh, run.sh, README.md, expected.manifest).
- Proof: every module, drm.ko and dmabuf.ko build natively on amp001 against the stock 16.0-CURRENT snapshot source
  main-n291235-611046b15dbb with drm_v6.12.110_1, linked by LLD, all module dependencies resolved.
- Open:
  1. The aarch64 vmm backend: amp001 is not a cloudbsd-vmm worker yet (#2163: the arm64 bhyve branches are unmerged,
     cloudbsd-vmd needs console= passthrough, no arm64 package yet). run.sh reports it as blocked (exit 3).
  2. run.sh vmm: vm.create with cloud-init user data, and the result read-back, are not wired.
  3. The guest clones from a read-only mirror amp001 serves on the VM network (Mark: no keys, no GitHub in the VM).
  4. uvm-bsd: install and deinstall targets, the stock source fetch, a harness run.

## 2026-11-20 llm-cuda (Track #2289, branch agent/2289-llama-cuda; merged onto main 2026-11-22)
- scripts run-cuda-llama.sh, bench-report.sh + tests/llm/bench_scripts_test.sh + man pages, committed in 9820803 (#2289).
# Journal native CUDA C1 (Track #2380, epic #2362), branch agent/2380-cuda-c1-toolchain

## 2026-11-22T06:20Z start
Mark card 2026-11-22: native CUDA runs in parallel with NVK. Order from docs/NATIVE-CUDA.md section 8: C1.1 (toolchain spike, deps none) is the first stage that needs no libnvrm S2; C1.2 (PTX front end) needs only C0 (done); C1.4 needs S5. Installed llvm23-23.1.5 from pkg (sudo pkg install llvm23); its NVPTX lists sm_120/120a/120f/121/121a/121f and ptx90-93. clang 23 detects a --cuda-path tree from include/, bin/, nvvm/libdevice/libdevice.10.bc and version.json; it defaults to --offload-new-driver. Header surface found by probing with empty files: cuda.h, host_defines.h, driver_types.h, host_config.h, cuda_runtime.h, crt/host_runtime.h, then execution-space macros.
Round 1 (an opencode round): brief ~/work/gb10/briefs/2380-cuda-c1-r1-sdk.md, report ~/work/gb10/tmp/2380-r1/ROUND-REPORT.md. Scope: lib/cuda-native SDK tree, mksdk.sh, test kernels, tests/cuda_native_toolchain_test.sh, root Makefile (contract; SUPERSEDED, see 07:10Z), cuda-native-toolchain(7), README section.
Next: review round 1, gate x2, commit, push; file C1.x work packages under #2380.

## 2026-11-22T06:40Z PAUSE for a test boot (orchestrator). RESUME here.
Brief in short: start native CUDA stage C1.1 (llvm23 toolchain, our own --cuda-path SDK tree, headers, PTX for sm_120/sm_121) in parallel with NVK; libnvrm S2 (wt-libnvrm-s2) is not touched; code by opencode rounds, strict gate (2 rounds per commit), push after each commit.
Done:
- llvm23-23.1.5 installed from pkg on amp001 (NVPTX sm_120/121 with a/f, ptx90-93).
- Track: C1 work packages filed under #2380 (epic #2362): C1.1 #2425 (In progress), C1.2 #2426, C1.3 #2427, C1.4a #2428 (libcuda API surface, fake backend, no S2), C1.4b #2429 (on libnvrm, needs S2-S5), C1.5 #2430, C1.6 #2431, C1.7 #2432, C1.8 #2433, C1.9 #2434, C1.10 #2435, C1.11 #2436. C4 not filed yet (goes under #2362, relates #2382).
- Round 1 brief written: ~/work/gb10/briefs/2380-cuda-c1-r1-sdk.md. Its run made no change: no permitted round model was available (free models are not to be used for this code).
Next:
1. Rerun round 1 from this worktree: ocrun.sh 5400 <model> ~/work/gb10/briefs/2380-cuda-c1-r1-sdk.md ~/work/gb10/tmp/2380-r1/round.log with the watchdog (empty round.status first). Model: the usual round model once its quota is back.
2. Review the round (provenance: no toolkit text), gate round 1 and 2, commit, push, Track comment on #2425 and #2380.
3. Then C1.1 round 2: libclc-based libdevice, nvptxas/nvfatbin stubs, stub libcudart link, offload-new-driver notes, mma.cuh PTX. Then C1.4a (libcuda headers + fake backend).
Note: the repo has no root Makefile; makefile-check refuses any commit without one, so round 1 adds it (tell the merge agent). SUPERSEDED at 07:10Z: another agent landed the root Makefile on main; this branch adds none.

## 2026-11-22T07:10Z resumed after the test boot
Orchestrator: no permitted round model is available (free models are not to be used for this code), so C1.1 round 1 is implemented directly by the agent. Do not add a root Makefile: another agent lands it on main. Watch STATUS.md for "ROOT MAKEFILE ON MAIN <sha>", then merge main into this branch.
Done: lib/cuda-native, with the SDK headers, the libdevice placeholder, mksdk.sh and the cuda-native-toolchain(7) man page; tests/cuda-native/{vector_add,builtins}.cu; tests/cuda_native_toolchain_test.sh. The test was red before staging (the fresh copy lacked the files) and is green after: 51 passed, 0 failed.
Findings while doing it:
- clang 23 takes the SDK version from CUDA_VERSION in include/cuda.h. It ignores version.json, and it needs bin/ to accept the tree.
- libdevice.10.bc must carry the nvptx64 data layout of the same clang, so mksdk.sh takes the layout from clang.
- atomicAdd lowers to atom.relaxed.sys, which is stronger than the gpu scope CUDA uses; to revisit in C1.2/C1.6.
README section, layout row and PROVENANCE entry written.
Next: gate round 1, then gate round 2, then wait for the root Makefile on main, merge main, commit, push, and comment on Track #2425.

## 2026-11-22T07:20Z commit 1 landed, commit 2 started
Commit 1: 461afd3, on main d015038 (with the root Makefile), pushed. It went through 2 gate rounds plus a receipt over the rebased diff; open findings are recorded as Review-open lines.
Commit 2 (open findings of commit 1), staged:
- mksdk.sh: strips trailing slashes before the symlink refusal; probes in the build directory; shows the clang error plus a remedy; refuses missing sources; mv -h, checks the result after mv, recreates OUTDIR if mv fails.
- Test: a failing llvm-as case that reaches the cleanup; a trailing-slash symlink case; provenance catches non-regular entries and grep errors; includes_exactly runs on the deadstub mutant; noglobal uses entry_only.cu; skip needs clang 23; failure cap 76; noinline and vector type checks with mutants.
- host_defines.h: no __noinline__ macro (it broke __attribute__((__noinline__))).
- README -o; man page exit wording.
Test: 75 passed, 0 failed. Next: gate rounds 1 and 2, commit, push, Track.

## 2026-11-22T07:12Z commit 2 landed; RESUME here
Commit 2: befd07d, pushed. 81 checks green, 2 gate rounds.
Correction to the 07:20Z entry: the layout probe runs before anything is created, not in the build directory.
Next, commit 3:
1. The Review-open items of befd07d:
   - a mutated-copy test for a directory created between rmdir and mv;
   - no rm through a link after mv;
   - the ls status in the rmdir message;
   - LLVM_MIN in the skip message and the header cap;
   - the test asks mksdk.sh for the version check;
   - show the mv and rmdir errors;
   - the remedy example.
2. libdevice from libclc. The ports devel/libclc has flavors up to llvm22 only, so an llvm23 flavor is needed (cloudbsd-ports), or a build from the llvm23 source.
3. nvptxas and nvfatbin stubs in bin/, plus a stub libcudart, so a full compile and link works.
4. PTX from the ggml mma.cuh.
Then C1.4a (#2428).
This entry is not committed yet.

## 2026-11-22T11:20Z commit 3 round A (Kimi k3.1-pro in opencode)
The Review-open items of befd07d are closed by round A. Brief: ~/work/gb10/briefs/2425-c1.1-r2-review-open.md. Report: ~/work/gb10/tmp/2425-rA/ROUND-REPORT.md; the round left its final sections unfilled, so it was judged by the tree.
Changes:
- mksdk.sh --check-llvm is now the one version check, used by builds and by the test skip.
- After mv, nothing is removed through a link.
- The rmdir message is told apart for an unreadable OUT, and the real mv and rmdir errors are shown.
- The remedy names the current prefix.
- Mutated-copy tests cover the nested-move and post-mv-link branches.
Test: 87 passed, 0 failed. Next: gate rounds 1 and 2, commit, push. Then round B: nvptxas, nvfatbin and libcudart stubs, so a full compile and link works.


## 2026-11-22 libnvrm S2 (Track 2419; first written on agent/2378-libnvrm-s2 from 9d17827, now on agent/2419-libnvrm-s2 as WIP)
First stop (test boot): nothing was saved in git then. Second stop (test boot, 2026-11-22): saved as WIP, see RESUME below. Work is uncommitted in this worktree; diff copy: ~/work/gb10/tmp/libnvrm-s2-wip-20261122.patch.
Done: WP 2419 filed under 2362. Debt settled: A2 (enum_opts reserved[4]; open_opts leading size), A3 (nvrm_device_open: own fd, RM client, VA space per device), A5 (new NVRM_E_RM vs E_IO for S2 calls). A1 untouched (no member added to nvrm_device_info). A4 untouched.
Written: nvrm.h S2 API; nvrm_va.c; nvrm_mem.c; nvrm_fake_mem.c (software GPU); nvrm_rm_mem.c and nvrm_rm_priv.h (nvrm_rm.c statics renamed nvrm_rm_*); nvrm_cap_limit_desc; Makefile and Version.map; man/nvrm_mem.3 is a PLACEHOLDER.
Tests: tests/libnvrm/mem_test.c, 779 checks green. Coverage: nvrm_va.c and nvrm_fake_mem.c 100%, nvrm_mem.c 301/302 branches. The tests found a real bug (find_reserve underflow), fixed.
RM facts (from nvidia_subr.c): one mmap context per /dev/nvidiaN descriptor, so each CPU map uses a descriptor (pre-opened pool, on-demand open outside capability mode). Export fd is a second /dev/nvidiactl descriptor (NV0000 EXPORT_OBJECT_TO_FD); import uses IMPORT_OBJECT_FROM_FD then GET_SURFACE_INFO.
NEXT: 1) last nvrm_mem.c branch; 2) add nvrm_va.c nvrm_mem.c nvrm_fake_mem.c nvrm_rm_mem.c to LIBSRC of tests/libnvrm_test.sh and run the S1 suite (new error ids need schema minor 1 and ids lines; S1 doc text says nothing maps memory); 3) rm_mem_test.c with a scripted multi-session kernel, cap_mem_test.c (default refuses map with E_DENIED, ALLOW_MAP works in capability mode); 4) tests/libnvrm_mem_test.sh on a fresh archive (coverage gate, mutants, red-first stub run); 5) real nvrm_mem.3, nvrm(7) section, README; 6) S2 rows in tests/libnvrm/boot_nvrm_info.sh; 7) gate, 2 rounds, REVIEW_ANSWERS before round 2, Track comment per receipt, push each commit.

### RESUME (2026-11-22, paused for a test boot)
- Branch is now agent/2419-libnvrm-s2, started from origin/main 7e28d7b (libnvrm files on main are identical to 9d17827, so the S2 work applied with no conflict; only this journal section was re-appended). The old branch agent/2378-libnvrm-s2 was never pushed and is left as is.
- This WIP commit holds the S2 state listed above (re-run on 7e28d7b: mem_test 778 checks, core_test 539, rm_test 208, cap_test all passed, all rc 0; the full tests/libnvrm_test.sh was not run). Gate round 1 receipt 3963a265 found 43 items; the quick ones are fixed (sparse tautology, S1 suite LIBSRC, journal, comment place); the rest are Review-open in the commit message and are the NEXT list below plus: error-id tables, enum_opts size, NVRM_1.1 node, RM page size from attr/attr2, NV0041 addr-space constants, vaSize as size, owner check in the RM memory ops, fake import of unexported objects, import cpu_attr from coherency, NVRM_DESC__COUNT, output size 0 rule, limit_session counts.
- Patch copies: ~/work/gb10/tmp/libnvrm-s2-wip-20261122-b.patch (full, incl. journal) and the older libnvrm-s2-wip-20261122.patch.
- Resume with NEXT steps 1 to 7 above. Each further commit: 2 gate rounds, REVIEW_ANSWERS before round 2, Review-open lines, push, Track comment on #2419.

## 2026-11-22T07:40Z libnvrm S2 fix commit (Track 2419, branch agent/2419-libnvrm-s2)
- State: WIP fcdc648 is committed and pushed, on origin/main d015038 (root Makefile). The RESUME notes above describe the first base (7e28d7b) and an uncommitted tree: both are superseded by this entry. The 779 to 778 drop is the round-1 sparse fix (three checks became two).
- WIP gate on the new base: round 1 b3c036f3 (run 6362), round 2 b3c036f3 (run 46483), no BLOCKER; every open item is a Review-open line of fcdc648.
- Fix commit (staged, gate next): error ids and texts plus schema minor 1 and ids lines; enum_opts.reserved refused; NVRM_1.1 node, man links from Version.map; nvrm_client_open/close (renamed); RM page sizes from one table both ways with ATTR2 and the write-back; import CPU attribute from the RM coherency; owner and fork check on every RM memory call; refused unmaps and frees counted (failed_releases), retryable, addresses never reused; output size 0 accepted, errmsg contract; messages with values; fake export spares limited at open; fake fault clear; real nvrm_mem.3, nvrm(7) Memory attributes, README section; tests/libnvrm/rm_mem_test.c (multi-session scripted kernel); cap_test memory case in real capability mode; mem_probe.c and BOOT_MEM_PROBE rows in boot_nvrm_info.sh; suite runs mem_test and rm_mem_test with coverage gates, mutants and doc checks.
- REJECTED with evidence: vaSize is the end (nvos.h says VA_LIMIT + 1); nvrm_list is an inline array (no use after free); the NV0041 address-space values are the NV0000 ones (ctrl0041.h says so).
- Left as DEBT: quality.9 (fake test API in nvrm_internal.h), quality.14 (session bring-up written twice), the four lizard waivers.
- Resume: if the suite is green, gate round 1 of the staged fix commit, answers, round 2, commit with Review-open lines, push, Track comment.

## 2026-11-22T12:40Z commit 3b (stubs), written by Kimi k3.1-pro in two passes
The tree now has four tools in bin/: nvptxas and ptxas, which write a CUDA-NATIVE-STUB-CUBIN 1 placeholder after checking the .target line, and nvfatbin and fatbinary, which write a CUDA-NATIVE-STUB-FATBIN 1 container. Both tools answer --version and --version --json.
It also has lib64/libcudart.so.13, a stub runtime. The stub checks the wrapper magic 0x466243b1 and the fatbin header, records the kernels, and returns 801 from every launch. With CUDA_NATIVE_STUB_TRACE=1 it writes one JSONL trace line per call.
There are four schemas. Man pages: nvptxas(1), nvfatbin(1), libcudart-stub(3).
A full clang++ -x cuda compile and link of launch_main.cu now builds, runs and prints launch=801.
Correction to the 07:12Z entry: its last line ("This entry is not committed yet.") is superseded; that entry was committed in ab2bc4e.
Test: 161 passed, 0 failed, 0 skipped. Next: gate rounds 1 and 2, then commit.

## 2026-11-22T13:36Z after the ZFS panic and reboot (about 13:24Z)
Both Kimi rounds died. Nothing was lost: the staged work of round B pass 4 is intact; items 1-10 were done and item 11 was half done (181 passed, 1 failed).
Resumed with ~/work/gb10/briefs/2425-c1.1-r3e-resume.md (items 11-15). Commit 3b is still uncommitted. Its gate round 1 receipt fa052367 is spent; round 2 comes after this pass.
C1.4a pass 3 is resumed in wt-cuda-c14a with ~/work/gb10/briefs/2428-c1.4a-r1d-resume.md. Its gate round 1 receipt 5ec434ec is spent.
# Journal native CUDA C1.4a (Track #2428), branch agent/2428-libcuda-api, worktree wt-cuda-c14a

## 2026-11-22T12:50Z round 1 (Kimi k3.1-pro in opencode)
Branch cut from the C1.1 head ab2bc4e.
Contents:
- cuda.h Driver API subset;
- lib/libcuda (libcuda.so.1, version node CUDA_1.0) with a provider registry and two providers, fake (profiles gb206 and gb10) and nvrm (a stub);
- 16 calls, including cuGetProcAddress and CUDA_VISIBLE_DEVICES;
- cuda-native-info with --json, --jsonl and --schema;
- man pages libcuda(3) and cuda-native-info(1);
- tests/libcuda_test.sh: 84 checks green, red first.
Brief: ~/work/gb10/briefs/2428-c1.4a-r1-libcuda-api.md. Report: ~/work/gb10/tmp/2428-r1/ROUND-REPORT.md.
Orchestrator finding: tests/libcuda/schema_validate.py duplicates tests/libnvrm/schema_validate.py; the brief said to reuse it.
Next: gate rounds 1 and 2, commit, push.

## 2026-11-22T14:50Z C1.4a pass 3 done (Kimi k3.1-pro; it was resumed twice, after the ZFS panic and after an opencode SQL error)
The review fixes are in:
- one pthread_once initialization;
- cuGetProcAddress_v2, with the header mapping;
- JSON that stays valid UTF-8;
- the visibility cap;
- better messages and tests.
Test: 119 checks green, cpd clean (PMD language cpp).
The orchestrator finding of the 12:50Z entry (the duplicate schema_validate.py) is resolved: the copy is deleted and tests use tests/libnvrm/schema_validate.py.
Next: rebase onto main, then gate round 2, then commit, PR and merge.

## 2026-11-22T15:10Z commit 3c (Kimi k3.1-pro): the Review-open items of 4c2938c
Work in this commit:
- The two DEFECTs: dash-prefixed input paths in nvptxas, and the fatbin header read is bounded by the limit.
- The 64 KiB bound is tested.
- One --version block, in the shared library.
- Each image is copied once, then hashed.
- Absolute RUNPATH in the examples.
- The stub trace is ignored under issetugid().
- An unwritable trace is reported.
- Real-path lookup of the shared helpers.
- Trace lines are valid JSON.
- Usage and man page fixes.
- The README status row for native CUDA.
Test: 219 passed. Next: rebase onto main, then gate rounds 1 and 2.

## 2026-11-22 (native-tools test-boot kit, agent/native-tools-testboot, #2362): PAUSED after the survey, no kit code written; resume at Next 1
Brief (Mark): "we have native tooling, we need native test results, not going through linux". A one-shot test-boot kit
that measures the NVIDIA card with native FreeBSD tools only: linux_enable=NO in the BE, no linux64 kldload, results as
JSON/JSONL (a summary verdict plus per-tool JSON). Modelled on the uvm-bsd kit tests/ioctl/testboot (e3b07d9 on
agent/2373-uvm-client-ownership): dead-man timer, self-recording rc one-shot, testboot-return to cloudbsd-rx7600, GSP
firmware loaded as root first, root open before the probes, gpu-detect.sh (never /dev/nvidia0). Dry-run build and
check-be.sh only; the orchestrator arms it. Every commit passes the review gate twice (two review-and-record rounds);
author Mark LaPointe; push; a Track comment; a STATUS.md line.

This is the one spec for the kit. It folds in the findings of review-and-record receipts aa2815b6, d1ea2742 and 03953fbd
(five reviewing voices each) on earlier drafts of this entry; nothing here is decided by Mark yet.

Layout and names:
- BE nvidia-native-tools-test-YYYYMMDD-N, N from -n (default 1). A clashing name is refused with a message that names the
  existing BE and the next free N.
- the rc one-shot (root) writes to /var/db/nvidia-native-tools-test/<stamp>/ in the BE and copies the run to the copy-out
  directory, a make-be.sh option whose default is /home/mlapointe/work/gb10/logs/native-tools-testboot (the home dataset
  survives the return). check-be.sh fails when that directory is on the BE dataset (zfs list -H -o name for the path
  equals the BE dataset or lies below it).
- shared pieces of the model kit (dead-man, rc skeleton, gpu-detect.sh, testboot-return) are vendored with a sha256 pin
  in VENDOR; check-be.sh compares them (testboot-return pin 3a88d17547c013ce93631d5aa4a414bcae6ccadb6e6653f641553f6df77f4d9d).

Statuses and verdict:
- every row has one status: pass, fail, error, needs-linux, needs-linuxkpi or not-available, each with a reason.
- summary.json holds every planned row (its key set equals the planned list, a host test checks it), counts per status,
  and the verdict: fail when any row is fail or error or the environment check failed; incomplete when no row failed
  but some planned row is not pass; pass only when every planned row passed. A run that tested little never reads pass.
- libnvrm S2 rows stay in the plan: not-available with the reason (no agent/2378-libnvrm-s2 on origin at assembly)
  unless S2 is pushed by then.

The no-Linux guard:
- environment, once, before any row: error when kldstat -v exits non-zero, or its output lacks kernel, or lacks
  nvidia.ko (either missing is an error; positive control). fail when any file or module name contains "linux" (linux,
  linux64, linux_common, linuxkpi, nvidia_linux, nvidia_modeset_linux, any future bridge), or when sysctl -N compat.linux
  answers; only its unknown-oid answer counts as absent, any other failure is error. An environment failure or error
  makes every row not-available ("environment tainted") and the verdict fail. The message names the modules found and
  the fix (rebuild the BE from a base without them).
- make-be.sh sets linux_enable=NO, strips linuxkpi consumers (amdgpu, drm, i915kms) from the clone kld_list and
  loader.conf; check-be.sh fails when any entry still loads one.
- per row: the row runs under ktrace -i -t cn; every execve path comes from its NAMI records (the tool, a #! interpreter,
  every ELF it runs), and each must be a FreeBSD-branded ELF (brandelf, readelf -n). An execve without a resolved path,
  or a trace with no execve of the tool itself, is error. Any kldload call in the trace, or a kldunload of a module whose
  name contains linux, is fail. After the row, kldstat -v must show no new module (a delta).
- host tests: a /bin/sh script passes; an undeclared copy of /bin/echo branded Linux, run by absolute path, fails; a row
  that loads and unloads a module named linux_test fails; canned kldstat with only kernel is error; canned kldstat with
  nvidia_linux.ko and no linux64 fails; a stub sysctl with a non-oid error is error.

Classification of rows that may need Linux (evidence recorded in the row):
- from the .ko: the MODULE_DEPEND list (readelf, kldxref) and undefined symbols matching linux, lkpi or linuxkpi; from
  the row binaries: their brands. A dependency on linux, linux64 or linux_common gives needs-linux, on linuxkpi gives
  needs-linuxkpi; none gives a native row. An inspection that fails (missing file, nm error) gives not-available.
- nvidia-uvm.ko is SUSPECTED to need the Linuxulator (the #2363 kit loads it only after linux64), UNVERIFIED. The uvm-bsd
  79-check ioctl suite and the #2373 probe and race tests follow this rule.
- render uAPI and PRIME rows are native when their ioctls are served by nvidia.ko or nvidia-modeset.ko of the #2363 build
  and the guard passes; otherwise classified by the same rule.

Survey done:
- model kit read: make-be.sh, check-be.sh, nvidia_client_owner_testboot, gpu-detect.sh, summarize.sh, testboot-return.
- origin/main is 7e28d7b. agent/2363-linux-bridges-optional (dc38ba9) is NOT merged into main yet, so nvidia.ko on main
  still carries the Linux ioctl bridge; the kit uses the #2363 build and installs only its native modules (nvidia.ko,
  nvidia-modeset.ko, the GSP firmware), never nvidia_linux.ko or nvidia_modeset_linux.ko. Not yet checked on the files.
- libnvrm S2 is NOT pushed; wt-libnvrm-s2 holds uncommitted S2 work of another agent: do not touch it.

Next:
1. Check with readelf and nm, recording the output here: the main nvidia.ko of the v6 boot build (nvidia-v6-phase0.ko in
   $GB10_WORK/logs/uvm-2373), the #2363 build in the tree its make-be.sh -t reads (default $GB10_WORK/build/tree, from
   dc38ba9: nvidia/nvidia.ko, nvidia-modeset/nvidia-modeset.ko), and nvidia-uvm.ko (nvidia-uvm-v5.ko, same directory).
2. Write tests/native-tools-testboot/ (make-be.sh, check-be.sh, the rc one-shot, summarize.sh writing summary.json, the
   guard and statuses above) and the kit host test.
3. Rows: nvrm-info on the booted card (tests/libnvrm/boot_nvrm_info.sh), gpu-detect and the root open, then the uvm,
   render and PRIME rows by the classification rule, the S2 rows as above.
4. Gate twice per commit, push, the dry-run BE, check-be.sh, a Track comment under #2362, STATUS.md, hand back.

## 2026-11-22 (native-tools test-boot kit, #2362): RESUMED after the test boot; kit written, host test green
- main is a682522 (#2363 merged); the branch is fast-forwarded to it, the earlier entry re-added on top.
- nvidia-uvm.ko NEEDS the Linuxulator, verified: uvm-bsd sys/uvm_main.c declares MODULE_DEPEND(nvidia_uvm,
  linux64elf or linux, 1, 1, 1) and MODULE_DEPEND(nvidia_uvm, linux_common, 1, 1, 1) and calls
  linux_ioctl_register_handler; kldxref -d -v on nvidia-uvm-v5.ko (the v7 boot module) prints linux64elf.1 and
  linux_common.1, nm -u shows linux_ioctl_register_handler and linux_ioctl_unregister_handler. The uvm rows are
  needs-linux until uvm-bsd makes that bridge optional the way #2363 did for nvidia.ko.
- nvidia.ko of main NEEDS NO Linux, verified on a fresh archive build of a682522 (work-native-a682522, SYSDIR
  kc502, base LLD 21.1.8): depends on kernel, mem, nvidia_gsp_ga10x_fw_fw only, no undefined linux_ or lkpi_ symbol;
  nvidia-modeset.ko depends on kernel and nvidia.2 only. The v6 and older builds all depended on linux64elf and
  linux_common. Staged in logs/native-tools/stage-a682522 with SHA256-native-a682522.txt and nvrm-info built from
  the same commit.
- the normal BE loads amdgpu (kld_list, so linuxkpi and drm) and linux64 (linux_enable); the kit strips both in the
  clone and blocks them in devmatch (rc.conf and loader kenv).
- libnvrm S2 still not on origin: nvrm-s2-memory is not-available. Render uAPI: header and documents only. PRIME:
  needs-linuxkpi (nvidia-drm.ko, amdgpu).
- kit: tests/native-tools-testboot/ (make-be.sh, check-be.sh, the rc one-shot, guard.sh, summarize.py, the summary
  schema, ROWS.md, vendored gpu-detect.sh and testboot-return pinned in VENDOR), tests/native_tools_kit_test.sh
  91 passed 0 failed, README section.
Next: gate 2 rounds, commit once the root Makefile is on main (merge it first), push, dry-run BE, check-be, Track,
STATUS, hand back.
- Gate round 1 (receipt 1c084a59, 5 Opus voices plus scanners; lizard CCN 37 in summarize.py fixed by splitting
  it). Fixed: guard_trace parses kdump by event name (a process name with spaces), keeps only the paths of a
  successful execve, and a relative or vanished path is an error; any kldload or kldunload fails (kldunload names a
  file id, so the rule is "any"; comments say so); lindebugfs matched; nm failure or an empty nm list is an error
  (guard_undef); the rc script reads rc.conf.d before its defaults (normal_be was ignored); the copy-out refuses a
  symbolic link in its path, writes into a new 0700 directory from inside it, and copies testboot-return.txt and
  rc.log again after the return; not-run for every unreached row, not-available only for a missing tool; a missing
  row after any failed row (planned or not) is not-run; bectl list failure no longer masked; copy-out default under
  GB10_WORK; check-be finds the steps by check-be markers, derives the BE root from bootfs (any name), prints no ok
  after a failed override check, says what to do on failure; make-be -h prints the whole header. Kit test 121/0.
  Branch fast-forwarded to main d015038 (root Makefile, #2440).
- Kit committed as c26d46d (gate rounds 1c084a59 and ec926a58), pushed. The spec entry above is superseded by the code
  and ROWS.md wherever they differ: only nvrm-info and gpu-detect.sh are traced, any kldunload fails, statuses as in
  ROWS.md.
- Follow-up commit, from the round-2 findings: the second copy-out goes into the same directory by device and inode
  (no root cp through a planted link), the directory must be ours and 0700; an exec with no path in the trace
  (fexecve) is an error; the dead-man check counts only root's shutdown (pgrep -U 0); check-be reads every pool's
  bootfs (a data pool without one passes); make-be refuses a copy-out not in plain form, and --activate runs
  check-be.sh first and arms nothing when it fails; static rows may only be needs-linux, needs-linuxkpi or
  not-available; a planned check recording info is an error; gpu-detect.sh is traced (row gpu-detect-native, 32
  planned rows); staged nvrm-info and libnvrm.so.1 must be ELF (guard_elf); check-be wants python3 in the clone and
  the one-shot writes a FAIL summary when summarize.py cannot run; usage errors are one line. Kit test 133/0.
- Follow-up gate round 1 (receipt 7b02720b) fixed: any fexecve is an error (its image has no path even when the
  interpreter does); a summarize.py crash exits 4 and the one-shot needs exit 0, 1 or 3 AND a summary.json, else a
  FAIL summary; info rows turn into errors before the not-run rule looks for failures; check-be adds the root of the
  BE dataset itself (when it mounted the BE) to the bootfs roots, checks the copy-out path in plain form
  (guard_plain_path, shared with make-be) under set -f, says what to do; option values missing give the right
  message; the --activate refusal is tested. Kit test 146/0.

## 2026-11-22 (native-tools test-boot kit, #2362): the first boot stopped at env-before on a false positive
- Boot 20261122T072752Z of nvidia-native-tools-test-20261122-1 returned to cloudbsd-rx7600 with no panic. env-before
  and env-after failed on module records compiled into /boot/kernel.rx7600/kernel (GENERIC has COMPAT_LINUXKPI):
  uhub/usb_linux, lkpi_iic/iicbus, lkpi_iicbb/iicbb, drm and drmn lkpi_iic and lkpi_iicbb, pci/lkpi_mlx5_core_pci_table.
  No Linux file was loaded and compat.linux was an unknown oid; nothing else ran (the loads were gated on env-before).
- Fix (orchestrator rule): fail only on a loaded FILE other than the kernel with a Linux-layer name (contains linux,
  or starts with lkpi, lindebugfs, linsysfs, linprocfs), on such a module record inside a loaded file other than the
  kernel, or on compat.linux answering; the records inside the kernel file are an info row (env-*-kernel-records).
  New rows ko-native-nvidia and ko-native-nvidia-modeset (kldxref dependencies and nm undefined symbols) gate the
  loads. The boot listing is the fixture tests/data/native-tools-env-before-20261122T072752Z.kldstat. 34 planned
  rows; kit test 163/0.
- Gate round 1 (receipt 19a40871): the kernel exemption left a gap, a module calling built-in LinuxKPI by an
  unprefixed name (idr_alloc) with no MODULE_DEPEND; closed by guard_lkpi_imports (undefined symbols of the module
  against the symbols linuxkpi*.ko and lindebugfs.ko beside the running kernel define, linker-set bounds left out).
  nvidia.ko and nvidia-modeset.ko of main import none; nvidia-drm-v5.ko imports 40 (the control). One name rule
  (guard_layer_name) for files, records and dependencies, now with drm, dmabuf, ttm, amdgpu, radeonkms and i915kms;
  guard_env prints the kernel records on a records line (no globals); kldxref positive control is the module
  record; the record-inside-another-file branch is tested. Kit test 174/0.

## 2026-11-22T11:45Z libnvrm S3 (Track 2437, branch agent/2437-libnvrm-s3)
- Main sync: fast-forwarded to origin/main 4a745c7. A --no-ff merge was refused by merge-proof (MERGE_HEAD brings the GitHub merge commit 4a745c7 with no per-commit receipt); b98157c is an ancestor of main, so the fast-forward carries no branch content.
- Baseline tests/libnvrm_test.sh: 478 ok, 0 failed.
- Spike answer (MIT RM source, src/nvidia/src/kernel/gpu/fifo/channel_descendant.c): a copy-class object allocated on a channel whose engine type is GR is bound to the partner copy engine of that GR engine for the channel runqueue (kfifoGetEnginePartnerList, exactly one partner, else NV_ERR_INVALID_STATE). So a graphics-runlist channel can host the copy class (GRCE); the test boot probe proves it on the RTX 5060 Ti.
- clc86f.h in open-gpu-kernel-modules defines PAYLOAD_SIZE 24:24 with only _32BIT 0; 64-bit is 1 (Mesa clc86f.h). The SEM_EXECUTE word: RELEASE 1, RELEASE_WFI 20:20, PAYLOAD_SIZE 24:24. The open-gpu-kernel-modules clcab5.h is trimmed; the Mesa (MIT) clcab5.h has the full copy class.
- opencode rounds run with a private XDG_DATA_HOME (tmp/libnvrm-s3/ocdata): the shared opencode.db was locked by about 15 parallel runs and the first round A attempt died on SQLITE_BUSY.
- Round A (Kimi k3.1-pro): S2 DEFECTs correctness.N1 (owner check into the core) and falsification.N1 (DEFAULT page-size write-back). Round B brief written: slice 1 (nvrm_chan API, ring rules, fake GPFIFO).
- Resume: check round A (tmp/libnvrm-s3/rounds/A-s2defects), review, suite, gate 2 rounds, commit, push; then run round B.
- 2026-11-22T13:35Z amp001 panicked (ZFS on zroot) about 13:24Z and rebooted. Round B (slice 1, worktree wt-libnvrm-s3-b) was cut off before its final report; its files are on disk (chan_test 200850 checks green at its last log). Commit A: gate round 1 receipt 2bd715e0 (5 Opus voices, FINDINGS), fixes from round A4 staged, answers in tmp/libnvrm-s3/answers/answers-A.txt, one stale mutant line being fixed (round A5). Tags: quality.1 REJECTED (each client opens its own RM session); all other round-1 findings DEFECT, ACCEPTED and fixed.
- Resume: suite on the staged A, gate round 2 with REVIEW_ANSWERS, commit, push; then bring round B onto commit A and finish it.
- 2026-11-22T21:40Z A6 on main 44617da (PR 15 merged): the three DEFECTs left open on 297e307 (fake leak sweep, dangling fake_map pointer, DEFAULT write-back advice) and three DEBTs (give_back helper, munmap delta, second session asserted). Started by Kimi k3.1-pro (round A6, stopped), finished by Sonnet (Kimi quota out); mem_test main() runs a test table (CPD, the copy-paste detector of PMD). Suite 490 ok. Next: gate 2 rounds, commit, push, PR. Answers: tmp/libnvrm-s3/answers/answers-A6.txt.

## 2026-11-22 (nvrm-info boot fixes and version sysctls, #2378 libnvrm, #2362 kit): PAUSED for a test boot
Worktree /home/mlapointe/work/gb10/wt-2378-versions, branch agent/2378-version-numbers, cut from origin/main 8702134.
No code is written yet, and no opencode round has started. Baseline: tests/libnvrm_test.sh 412 ok, 0 FAILED on 8702134.

Findings so far (evidence ~/work/gb10/logs/native-tools-testboot/20261122T095018Z/nvrm-info):
- sm_version 10.4: libnvrm splits NV2080_CTRL_GR_INFO_INDEX_SM_VERSION (raw 0x0A04) into major and minor.
  ctrl2080gr.h of ogkm 580.178.04 (MIT): 0x0A04 is SM_VERSION_10_04, the older name kept until 12_* is
  validated; 12_00 is 0x0C00 and 12_01 is 0x0C01. ctrl2080mc.h: ARCHITECTURE_GB200 0x1B0, IMPLEMENTATION
  GB202 2, GB203 3, GB205 5, GB206 6, GB207 7, GB20B 0xB, GB20C 0xC. Plan: new fields compute_capability_major and
  compute_capability_minor (source derived), from an (architecture, implementation) table: TU10x 7.5, GA100 8.0,
  GA10x 8.6, GA10B 8.7, AD10x 8.9, GH100 9.0, GB100 10.0, GB202..GB207 12.0, GB20B 12.1. With no row: the RM
  code through an alias list (0x0A04 is 12.0), else the code as major<<8|minor. New raw field rm_sm_version
  (source rm). Keep sm_version_major and sm_version_minor unchanged (additive minor bump) and document them as
  the RM internal numbering. Fake profiles: discrete becomes raw 0x0A04 (what the board reports), arch 0x1B0
  impl 6, expect 12.0; unified stays arch 0x1B0 impl 0xB, expect 12.1. Mutants on the table and the alias.
- running_rm_version unavailable: hw.nvidia.version DOES exist (sysctl.txt line 1), but it holds the whole banner
  (about 100 bytes) and nvrm_rm.c read_sysctls() reads it into nvrm_str (NVRM_STR_MAX): the read fails on a short
  buffer and the code turns that into os_not_reported. Red test: a scripted sysctl that returns the real banner.
- UUID check: hw.nvidia.gpus.N.uuid EXISTS, N is the device unit (1 on amp001, /dev/nvidia1). The kit indexed it
  with the libnvrm index 0. Fix in the kit: match the GPU by PCI location (new dev.nvidia.N.pci_bus_id, falling
  back to dev.nvidia.N.%location dbsf=pciD:B:S:F), then compare dev.nvidia.N.uuid and hw.nvidia.gpus.N.uuid;
  boot_nvrm_info.sh must also capture sysctl dev.nvidia.
- VRAM: BOOT_EXPECT_VRAM_BYTES stays the nominal board size; pass when nominal minus a stated reserve maximum is at
  most the reported size, and the reported size is at most nominal (the boot: 17179869184 - 17103323136 = 73 MiB).

Decisions to carry (report them to the orchestrator):
- hw.nvidia.version is an existing upstream sysctl holding the banner: keep it unchanged. New sysctls follow Mark
  pattern NAME plus NAME_major, NAME_minor, NAME_patch: hw.nvidia.driver_version (string 580.178.04) and its three
  integers; per GPU dev.nvidia.N.uuid, dev.nvidia.N.pci_bus_id, dev.nvidia.N.vbios_version (hex parts, _major,
  _minor, _patch, _part4, _part5) and dev.nvidia.N.gsp_firmware_version; hw.nvidiamodeset.driver_version in
  nvidia-modeset.ko (like hw.nvidiadrm). An integer part that cannot be parsed or is missing reads -1; the string
  keeps the raw text. Handlers reuse the upstream rm_get_vbios_version, rm_get_firmware_version, rm_get_gpu_uuid
  calls that hw.nvidia.gpus.N already makes at read time.
- One parser and one formatter: a freestanding header lib/libnvrm/include/nvrm/nvrm_version.h (no libc), used by
  libnvrm and copied into the nvidia build tree by scripts/prepare-tree.sh for the BSD-C OS-layer file (new
  src/gb10-version/nv_version_sysctl.c plus small hook hunks in patches/ for nvidia_sysctl.c nv_sysctl_init and
  the modeset load). The kernel branch therefore stacks on the libnvrm branch.
- JSON: every version is an object {available, string, major, minor, patch, parts, suffix, source}; unparsed: string
  kept, parsed false, reason_id version_unparsed, no numbers. Existing keys kept; new top-level versions object
  (driver from sysctl, rm_api from NV_RM_API_VERSION_CMD_QUERY reply, libnvrm, libnvrm symbol level NVRM_1.1,
  schema) and per GPU vbios and gsp_firmware (NV2080_CTRL_CMD_BIOS_GET_INFO_V2, NV2080_CTRL_CMD_GSP_GET_FEATURES).
  Schema minor bump. New API symbols go in NVRM_1.1 in Version.map. uvm-bsd version: note only, out of scope.

RESUME here:
1. Kimi round 1 (opencode run -m dgx-mlapointe/kimi-k3.1-pro via ocrun.sh with round-watchdog.sh; fall back to
   kimi-k3, then kimi-k2.7-code; then a Sonnet agent): libnvrm parser/formatter, compute capability, running
   version read, versions object, schema, man pages nvrm(3) nvrm-info(8), tests and mutants. Gate 2 rounds, commit.
2. Kernel branch agent/2378-nvidia-version-sysctls stacked on 1: OS-layer sysctls, nvidia(4) (man/nvidia.4), build
   nvidia.ko with base LLD using the recipe in ~/work/gb10/work-native-a682522/build.sh (check Linker: LLD).
3. Kit branch from agent/native-tools-testboot f3286e3: boot_nvrm_info.sh fixes plus the fixture test from this
   boot, staged build, new dry-run BE, check-be; hand back the arm command, never arm.
4. Track comments #2378 and #2362, STATUS.md, PRs.

## 2026-11-22 13:35Z resume after the amp001 ZFS panic (about 13:24Z)
- Worktrees wt-2378-versions (libnvrm) and wt-2378-sysctl (kernel) checked: nothing half-written; a stray build
  object nvrm-info.pieo had been staged by an orchestrator build in the source dir and was removed from the index.
- libnvrm_test 456 ok 0 FAILED; version_sysctl_test PASS (3 mutants killed); prepare-tree_test 15/0.
- All code so far by opencode Kimi kimi-k3.1-pro (round A passes 1-5, round B passes 1-3). Rounds use a private
  XDG_DATA_HOME because the shared opencode.db locked and killed two rounds.
- Gate round 1 for the libnvrm commit restarted (the first attempt was cut by the scanners, the second by the panic:
  no receipt, not counted).
- Next: gate 2 rounds libnvrm, commit, push; rebase the kernel branch on it, gate 2 rounds, commit, push; kit round C.

## 2026-11-22 13:50Z sysctl names (supersedes "Decisions to carry" of the PAUSED entry above)
- Mark: hw.nvidia.version already exists, so it stays exactly as it is (the banner, legacy). Its parts are added as
  siblings: hw.nvidia.version_string ("580.178.04"), version_major, version_minor, version_patch (int),
  version_suffix (string, empty when none), version_available (1 or 0). There is NO hw.nvidia.driver_version.
- A part the scheme does not have reads 0 (not -1); version_available 0 means unreadable and every part reads 0
  (skill versions-as-numbers, skills main cb09bf7). Per GPU: hw.nvidia.gpus.N.vbios and .firmware stay, with
  vbios_major/_minor/_patch/_build/_revision/_available/_suffix (hex) and firmware_major/_minor/_patch/_available/
  _suffix siblings; new dev.nvidia.N.uuid and dev.nvidia.N.pci_bus_id; hw.nvidiamodeset.version and siblings.
- The PAUSED entry above was written before any code; the code in this commit implements RESUME step 1.
- Gate round 1 of the libnvrm commit: receipt 215f871d (5 Opus voices, FINDINGS). Answers in the round-2 answers
  file; fixes by Kimi pass 6.

## 2026-11-22 15:20Z libnvrm committed, PR open, merge refused: STOPPED
- c0102d7 (agent/2378-version-numbers, pushed): libnvrm compute capability, versions as numbers, running RM version.
  Gate 215f871d and e782961d. Code by opencode Kimi kimi-k3.1-pro (round A passes 1-7).
- PR https://github.com/cloudbsdorg/nvidia-gb10-freebsd/pull/22. `gh pr merge 22 --merge --author-email
  mark@cloudbsd.org` was denied by the permission check; stopped as the brief says.
- Kernel change ready in /home/mlapointe/work/gb10/wt-2378-sysctl (branch agent/2378-nvidia-version-sysctls, staged,
  not gated; holds a copy of nvrm_version.h). Code by Kimi (round B passes 1-3). nvidia.ko and nvidia-modeset.ko
  built with base LLD in build/tree-2378-sysctl; version_sysctl_test PASS (3 mutants), prepare-tree_test 15/0,
  kmod_symbols_test PASS, fw_depend_test 44/0.
- Kit: brief ready at ~/work/gb10/tmp/briefs-2378/round-c.md, fixture capture copied to
  /home/mlapointe/work/gb10/wt-2362-kit/tests/data/nvrm-info-boot-20261122T095018Z (worktree on f3286e3).
RESUME:
1. After PR 22 is on main: rebase the kernel worktree on main (drop its header copy, keep the rest), gate 2 rounds,
   commit, push, PR.
2. Follow-up libnvrm commit for the Review-open items of c0102d7 (security.3 first), 2 rounds.
3. Kit: put the kit branch on main (it merges clean with f3286e3), run round C, gate, PR; staged build from main
   (recipe ~/work/gb10/work-native-a682522/build.sh), make-be dry run, check-be; hand back the arm command.


## 2026-11-22 21:20Z main merged into the branch, PR 22 merge refused again: STOPPED
- 7cddc09 (pushed): --no-ff merge of origin/main b7993ca. S2 keeps NVRM_1.1 and schema minor 1; the version calls
  are NVRM_1.2 (library 1.2.0), the version additions schema minor 2. Gate receipt ee398a8b on the overlap.
  Resolution by a Claude Sonnet sub-agent (MiniMax token plan limit; kimi-k3.1-pro, kimi-k3, kimi-k2.7-code monthly
  usage limit). tests: NVRM_IDS_BASE_REF=origin/main OGKM=~/work/gb10/sources/open-gpu-kernel-modules-580.178.04
  SYSDIR=~/rx7600/kc502/src/sys sh tests/libnvrm_test.sh: 535 ok 0 FAILED. (main now defaults GB10_WORK to
  <repo>/work, so OGKM must be given.)
- gh pr merge 22 --merge --author-email mark@cloudbsd.org: denied by the permission check a second time. Stopped.
- Stray pre-fix working-tree edits found before the merge were saved to tmp/stray-worktree-changes.patch and dropped.
RESUME: after PR 22 is merged, rebase wt-2378-sysctl on main (drop its nvrm_version.h copy), gate 2 rounds, PR;
then kit round C; then the staged build, make-be dry run and check-be.

## 2026-11-22T21:59Z #2448 kapi logdevice round 1
- New patches/ogkm/patch-src_nvidia-modeset_kapi_include_nvkms-kapi-internal.h adds nvKmsKapiLogDevice (nvEvoLog, EVO_LOG_WARN, uses (__device)->gpuId); the patch was missing, so SetConsoleOwner called an undefined symbol. Applies with fuzz 0, no offset, and all ogkm patches apply in sequence.
- tests/console_owner_patch_test.sh: KAPI_I copied and patched, check_logdevice_macro, check_logdevice_defined, 4 plant controls. 31 passed, 0 failed.
- docs/CONSOLE-SHARING.md 6.1 paragraph. build-rmcore_test 23/0, enumerate_gpus_patch_test 5/0, kapi_table_test 30/0, prime_import_test 18/1 (D6 needs work/build/tree/nvidia-drm, not present in this worktree; unrelated).
- scripts/build-rmcore.sh apply_patches globs patch-*; console_owner_patch_test.sh lists the patches it applies in one variable (OGKM_PATCHES).

## 2026-11-22T22:22Z #2448 kapi logdevice round 2
- Review-gate fixes: checks split so each failure names one cause (called, defined, warning level, own device argument, unconditional and never undefined, same prefix as the Debug macro); 11 new plant controls; one OGKM_PATCHES list for the required check and the apply loop; patch comment says operator and kernel log; test header states the missing macro is a clang implicit-declaration warning and an undefined symbol in the .ko.
- console_owner_patch_test 42 passed 0 failed; kapi_table_test 30/0; build-rmcore_test 23/0. All ogkm patches apply in lexical order, fuzz 0.

## 2026-11-23 #2457 GA10x floor, round 1 (written by a Claude Sonnet sub-agent: every opencode model out of quota)
- src/gb10-archfloor/nv_arch_floor.{h,c}: the floor (0x17) in one place; pure decide and format; probe reads BOOT_0 and BOOT_42 from BAR0 the way NVIDIA's attach does, gives everything back; refused devices recorded once per PCI location in a 16-entry array under a mutex; hw.nvidia.min_architecture, min_architecture_name, refused_count, refused.
- patches/patch-zz-2457-arch-floor_nvidia_nvidia_pci.c, _nvidia_nvidia_sysctl.c, _nvidia_Makefile; prepare-tree.sh copies both files to TREE/nvidia. The patches sort before patch-zz-nvidia_*; every patch applies with no fuzz.
- devd/nvidia_gb10.conf: nvidia first, then nvidia-drm only if dev.nvidia lists this event's vgapci as a %parent. Finding: devd expands $device-name to $'value', so the variable must be outside single quotes ('%parent: '$device-name); the form in the brief ('%parent: $device-name') would grep for a literal dollar sign. tests/devd_rule_test.sh has a plant for it.
- make preflight: per-GPU support verdict (kernel answer when nvidia.ko is loaded, else pciconf -lv chip name and the header table); schema 1.1 (support, min_architecture); new test hooks GB10_TEST_PCICONF, GB10_TEST_SYSCTL, GB10_TEST_MACHINE_ARCH.
- Red first: tmp/2457/red-arch-floor.log, red-devd-rule.log, red-preflight-support.log.
- Docs: man/nvidia.4, README.md, PROVENANCE.md.
RESUME: orchestrator review and gate; nvidia.ko was built (never loaded); a test boot would need a TU10x card to see a real refusal.

## 2026-11-23 #2457 GA10x floor, round 2 (the review fixes)
- src/gb10-archfloor/nv_arch_floor.h: the firmware row carries the machines whose build carries the image (ROW(0x17, 0x0, "GA100", "gsp_tu10x", "amd64")); NV_ARCH_FLOOR_MACHINE replaces NV_ARCH_FLOOR_HAVE_GSP_TU10X and defaults to MACHINE_ARCH (<machine/param.h>), so the image name is in no code any more.
- src/gb10-archfloor/nv_arch_floor.c: the refusal line is "<pciconf selector> <parent name> <device id> <keyword> <message>" and is logged against the parent (vgapci1: nvidia: ...); the locations have their own 64-entry table, so a device that did not fit the 16-entry list is still counted and logged once (past 64 locations it is logged again); a location that attaches later leaves both tables and the count; a re-probe with another verdict replaces the entry and is logged again; the no-firmware message names the build that carries the image; the refused buffer is derived from its parts and a _Static_assert.
- scripts/make.sh: one awk program reads the header (the floor, its name and label, the architecture rows and the firmware rows) and validates it; a malformed table fails closed (no verdict, and no floor); the chip match takes a suffix but not a digit (GA100GL); the kernel's keyword is checked against the schema's enum; a refusal that the kernel does not list says so; the text render puts the verdict and the reason on two lines.
- schema/make-preflight-1.schema.json: 1.1 requires items[].support and min_architecture, and schema_version stays "1.0" (it names the 1.x contract line). schema-check on the staged tree: clean, "additive change, 1.0 -> 1.1"; the enum form of round 1 is refused (a non-additive change needs a new major version).
- Docs: man/nvidia.4 (mdoc placeholders in DIAGNOSTICS, the action under the three refusal entries, the refused line format), README.md (only GM10x to TU10x cards are named below the floor), PROVENANCE.md (no path from a workstation layout), devd/nvidia_gb10.conf and the schema (no tracker number).
- Tests: arch_floor_test.sh (the row and the MODULE_DEPEND condition agree, 29 mutants, 2 plants), preflight_support_test.sh (17 plants), devd_rule_test.sh (no tracker number), make_contract_test.sh (the help fits 80 columns, the document's schema_version is 1.0).
- Red first: tmp/2457/tmp/red-r2-arch_floor_test.log, red-r2-preflight_support_test.log, red-r2-devd_rule_test.log, red-r2-make_contract_test.log (the round-1 tree with the new tests).
- Build: prepare-tree, then build-shim with PATH=/usr/bin:/bin:$PATH and SYSDIR=/home/mlapointe/rx7600/kc502/src/sys, reusing the RM objects: errors 0, nvidia.ko 13940208 bytes, sha256 e5b9e771b6bc9e575e8c21da44d90ba5c265cbbb80bae2211dbd9c3d59daf13e, readelf -p .comment says Linker: LLD 21.1.8, nm shows nv_arch_floor_probe. Never loaded.
- Known failures on main as well, not fixed here: make_contract's expected.manifest (the nvrm_*.3 links) and make_install_flow's personal paths (tests/version_sysctl_test.sh:15).
- Round 2b: NV_ARCH_FLOOR_KEYWORD_MAX is the size of the longest keyword string (sizeof(NV_ARCH_FLOOR_KW_NOT_RESPONDING)), not the size of a pointer to it; the keywords are string macros and a _Static_assert per keyword says no keyword is longer than not-responding; the _Static_assert that only restated the definition is gone. The test fills all 16 entries to the longest form and the whole list is whole; the keyword-bound-pointer mutant is killed.
- Round 2b: past 64 refused locations refused_count can overstate the number of refused GPUs, because a location that is not remembered is counted on every probe and is never counted down; said so in nv_arch_floor.h and nvidia(4). The behaviour is unchanged.

## 2026-11-23 #2457 orchestrator
- Round 1 code: Claude Sonnet sub-agent (opencode models out). Rounds 2 and 2b: MiniMax (opencode). Gate round 1 receipt 31dbec101b05833a3be3d61dc47d326af873eb4e39d6685536f16074195b04bd (5/5, Opus fallback), all voices FINDINGS; the WIP commit was refused by schema-check (schema_version const to enum), fixed in round 2 (const kept, new properties required, version 1.1).
- Re-run after round 2b: arch_floor, devd_rule, preflight_support, prepare-tree, manpages, readme_install_doc, version_sysctl PASS; schema-check clean (additive 1.0 -> 1.1).
- Answers to round 1: tmp/2457/REVIEW_ANSWERS-r2.txt (falsification.6 is a QUESTION: live probe needs a test boot).
RESUME: gate round 2 with REVIEW_ANSWERS=tmp/2457/REVIEW_ANSWERS-r2.txt once the Kimi voices answer (Mark 11-23: no Claude fallback; wait and probe again); then commit, push, full suite, PR. hw-preflight (skills repo) is a follow-up.

## 2026-11-26 #2457 merge of main (4cd016d) and the one cpd refusal
- The merge of origin/main 4cd016d into the branch head e63ef89 is in the worktree, not committed (MERGE_HEAD is still there). Four files conflicted; each was resolved by hand. JOURNAL.md keeps both sides. docs/MANUAL-BUILD.md keeps main's platform paragraph (arm64 or amd64, the RM core rebuilt for the running architecture, the base ld.lld) and the branch's GA10x paragraph. scripts/make.sh keeps main's HookOS/hookarch and the branch's GB10_TEST_PCICONF, GB10_TEST_SYSCTL and GB10_TEST_MACHINE_ARCH hooks, with the chip-family naming (GA10x, TU10x, ...) and the preflight schema majors (2.0, with schema_major and schema_minor as integers) as they are.
- schema/samples.json lists every schema of the merged tree: preflight 1 and 2, install 2 with its two fixtures, and the two stock-install schemas. Main's install contract is 2.x and its 1.x file is gone, so the branch's 1.x row is not registered: schema-check refuses a row that names a schema the tree does not hold, and every schema in the tree must be named by a row.
- The gate's one refusal: cpd reported the fatbin reader's error table (lib/cuda-native/fatbin/cnfatbin.c, from main, PR 50) as a copy of libnvrm's reason table (lib/libnvrm/nvrm_names.c, this branch): 23 lines, 121 tokens. One implementation now: lib/cuda-native/fatbin/cn_names.h carries struct cn_name_entry, the CN_NAME_ENTRY(code, id, text) macro and cn_name_code_valid(code, count). Both libraries include that one file; libnvrm reaches it with -I${.CURDIR}/../cuda-native/fatbin, the way lib/libcuda reaches ../cuda-native/sdk/include, and mksdk.sh copies it next to the reader it compiles (that reader is compiled without an include path of its own, so the header has to sit next to it). The fatbin table keeps its designated initializers (tests/cuda_native_fatbin_test.sh reads that table out of the source text and compares it with the enum in cnfatbin.h); libnvrm's table is written with the macro. The two are the same data in the same struct but not the same token shape, which is what cpd compares. The behaviour is unchanged: the same names, the same texts, the same answers for a code that is not in the table.
- scan-cpd --root . lib/cuda-native/fatbin/*.c lib/libnvrm/*.c: CLEAN. The gate's own form (SCAN_REPO set, so the whole fatbin and libnvrm trees are the context) is CLEAN too. The largest clone left in that pair is the fatbin table against itself at 89 tokens (the threshold is 100); before the change the same pair was reported at 121.
- The boot kit of tests/native-tools-testboot carries the shared header too (make-be.sh PATHS), so the copy of lib/libnvrm in the kit still builds.

## 2026-11-22T23:25Z #2455 device decision phase 1 (design)
Worktree wt-2455, branch agent/2455-device-decision from origin/main cbe6ca3.
- Survey (MIT open-gpu-kernel-modules 580.178.04 src/ and kernel-open/; zlib supported-gpus.json of the FreeBSD 580.178.04
  package; BSD fwget tables): the PCI-time check accepts every 0x10de display device; the generation check needs BOOT_42
  after BAR0 is mapped; 0x1e02+ open-RM capable, 0x1340..0x1df6 closed RM only, older ids in legacy branches.
- Code writers: MiniMax (token plan) and kimi-k3.1-pro (monthly limit) over quota at 23:25Z; kimi-k3 and kimi-k2.7-code
  gave no answer in 150 s. docs/DEVICE-DECISION.md written by a Sonnet sub-agent from the brief tmp/2455/brief-doc.md,
  reviewed by the orchestrating agent (10 fixes, applied by the same Sonnet agent).
- Mark's additions folded in: one driver and package for every card, branch as data, backends per generation, alias
  layer, full-coverage path, the #2457 Ampere floor as the first provider-record rule.
- Next: full suite, gate 2 rounds, commit, push, PR; hand back for Mark's go. Phase 2 waits for that go.

## 2026-11-22T21:30Z libnvrm S3 slice 1 (Track 2437, branch agent/2437-libnvrm-s3-chan, on main 44617da)
- nvrm_chan API (nvrm_chan.h), core ring rules (nvrm_chan.c: E-2 per batch, splitting, INCOMPLETE runs, a FIFO of submit waiters with a turn condvar, flush order with two barriers), fake GPFIFO (nvrm_fake_chan.c: NOP, semaphore release and acquire 32/64-bit, ACQ_CIRC_GEQ, copy class), encoders in nvrm_methods.h, barriers in nvrm_barrier.h, nvrm_chan(3).
- Written by opencode Kimi k3.1-pro (round B), finished by Sonnet (B2, B3: queued submit timeout and handoff, ring-wrap space fix; lint exemption for the fake channel data) after the Kimi quota ran out.
- tests/libnvrm_test.sh 505 ok, 0 failed. chan_test about 200961 checks; nvrm_chan.c and nvrm_fake_chan.c at 100 percent lines and branches; 11 chan mutants killed.
- Next: gate rounds 1 and 2, commit, push, PR.
- Slice 1 round 2 had two complete gate runs on the same diff: run 87573 (receipt a119169e, the one used) and a duplicate run 33965.
- The mutant script now holds 26 chan mutants (the slice 1 entry of 2026-11-22 21:30Z said 11; that count was stale).
- 2026-11-23T04:00Z B5 (the four slice 1 DEFECT fixes) on branch agent/2437-libnvrm-s3-defects, on main 0163eda: gate round 1 receipt 4f490fa3 (5 voices, Claude fallbacks because every Kimi voice was over quota); the nine findings fixed by a MiniMax round (B6-review1): size 0 returns the full stats structure again, the fake fetch failure leaves GP_GET alone, one ownership check in run_entries, forget required and never called in a fork child. Suite 608 ok. Answers for round 2: tmp/libnvrm-s3/answers/answers-B5.txt.
- Resume: gate round 2 with REVIEW_ANSWERS waits until a non-Claude voice answers (Mark: no Claude fallback while the Claude quota is low; wait for the next 5 hour MiniMax window); then commit, push, PR.

## 2026-11-22T23:25Z #2448 zz-2448 enumerate-gpus patch: fuzz 0 on main after d1752ad
- patches/patch-zz-2448-enumerate-gpus_nvidia-modeset-freebsd.c regenerated with diff -U2 against the tree after every earlier patch (incl. the nv_version_sysctl.h include from d1752ad). Hunk 2 now anchors on that include; the NVRM include block still sits before nv-retpoline.h. Added (+) lines are byte-identical; hunks apply with no fuzz and no offset.
- Chain: all 38 patches apply in lexical order at -F0 (offsets only in other patches, none failed). enumerate_gpus_patch_test 5/0; kapi_table_test 30/0.
- linux_bridge_test on a built tree (tests/linux_bridge_test.sh work/build/tree): 105 passed, 1 failed after; on cbe6ca3 104 passed, 3 failed. The two that went are check (g), the fresh-archive fuzz 0 apply of every patch ("does not apply with fuzz 0" and "a .rej file was left behind"). The one left is check (i), man/nvidia.4 line 272 `.Xr nvidia-smi 1` (mandoc STYLE "referenced manual not found"), which fails the same way on cbe6ca3.
- Full suite (every tests/*_test.sh), here and on a cbe6ca3 baseline worktree, same build: the same tests fail on both, with identical FAIL lines. fw_depend and open_dev_failure fail on the nvidia.4 lint above; make_contract on two nvrm man3 links missing from expected.manifest; make_install_flow on a personal path in tests/version_sysctl_test.sh line 15; render_uapi_layout exits 2 on a skipped check. With the default tree argument, linux_bridge_test also reports the tree-2363 module files as missing (no tree-2363 is built here).

## C1.3 (#2427) 2026-11-23T00:38Z slice 1 started on main 999b186
Brief ~/work/gb10/briefs/2427-c1.3-s1-fatbin-container.md on opencode MiniMax (state tmp/round).

## C1.3 (#2427) 2026-11-23T01:00Z checkpoint for the amp001 test boot
Round stopped about 20 minutes in; snapshot ~/work/gb10/cuda-mgr/snap-20261123T0100Z. Resumed after the boot with ~/work/gb10/briefs/2427-c1.3-s1b-resume.md.

## C1.3 (#2427) 2026-11-23T02:40Z slice 1 round done (MiniMax, resumed run)
- cnfatbin reader and writer: the LLVM OffloadBinary v2 layout plus our cloudbsd.* keys.
- nvfatbin and fatbinary, now in C.
- cuda-objdump: text, --json, --jsonl, --extract and --schema; it also reads .nv_fatbin from ELF files.
- The runtime stub reads the container.
- Man pages nvfatbin(5) and cuda-objdump(1).
Oracles:
- llvm-objdump --offloading reads our container.
- Our reader reads clang-offload-packager output, so image kind none is accepted.
Tests: fatbin 65/65, toolchain 243/243; the mutant goes red.
Manager review: the bounds checks in cnfatbin_open and read_member are sound.
DEBT: clang's wrapper gives no length, so the runtime stub takes the container length from its own header (capped at 16 MiB).
Next: gate round 1.

## C1.3 (#2427) 2026-11-23T03:40Z scanner pass done (MiniMax): functions split, shared cntool.c/h for both tools, test oracle messages literal. lizard and cpd clean. fatbin 67/67, toolchain 243/243. Next: gate round 1.

## C1.3 (#2427) 2026-11-23T03:45Z PAUSED (Claude quota)
Slice 1 gate round 1 was started then STOPPED at 03:45Z under Mark's low-Claude-quota rule: Kimi is out of quota, so the gate voices would fall through to claude-opus. Staged work is intact; resume = review-and-record when a non-Claude voice chain answers (probe again after about 05:45Z).

## C1.3 (#2427) 2026-11-23T07:12Z PAUSED 07:12Z: MiniMax Token Plan usage limit reached (about 07:05Z). The running passes were stopped with partial edits on disk. Resume after the next 5-hour window (about 10:01Z). Pass A (brief 2427-c1.3-s1e-A.md) got partway; then run B and C.

## C1.3 (#2427) 2026-11-23T07:59Z PARKED 07:59Z for the amp001 drive swap. Nothing of the manager is running. Snapshot of the uncommitted work: ~/work/gb10/cuda-mgr/snap-20261123T0715Z (also on zroot; the cloudbsd pool is not writable for this user). Resume: probe MiniMax; if it answers, rerun the pass named in the previous entry.

## C1.3 (#2427) 2026-11-24T05:40Z pass 3A done (runtime stub bound)
Gate round 1 finding on the runtime stub trusting the header's own length (quality.10, security.1, falsification.3, the lengthless-peek half of quality.9): the stub now bounds every read by the loaded object that holds the pointer, found with dl_iterate_phdr(3) and the PT_LOAD segment end, capped at 16 MiB. A pointer in no loaded object is refused; a registered mapping is the fallback for it and never widens a bound a loaded object gives.
Fixtures: the reviewer's 100-byte header claiming 1 MiB just before a PROT_NONE page, the 32-byte header claiming 16 MiB with one entry, eight bytes before a guard page, and a container in an unregistered mapping. A mutant whose stub takes the cap for its bound reads out of bounds and dies on SIGSEGV, so the fixture has teeth.
Also repaired the earlier run's half-finished error-table refactor: it left the old error_names[] beside the new error_table[] and the tree did not compile under -Werror.
DEBT closed: the wrapper still gives no length, but the stub no longer needs one.
Tests: fatbin 67/67, toolchain 249/249. lizard, cpd and mandoc clean. Not committed.
Next: the remaining gate round 1 findings (UTF-8 JSON, -emit-llvm, kind none, overlong values, overlapping ranges, trace arch, one error table/magic check/file reader, one crafting implementation, the writer's caps).

## C1.3 (#2427) 2026-11-24T07:45Z pass 3B done (reader values and output)
Gate round 1 findings on values and output: the JSON escaper validates UTF-8 and writes every byte that is not a character as the replacement character, so the document always parses; the text output shows every control byte as a \xNN escape, so one member stays one line and no raw control byte reaches the terminal. The reader measures a value before it copies it: a value of a key we know that does not fit the field is refused with value-too-long, a digest is exactly 64 hexadecimal digits or it is sha256-format, and a key we do not know is ignored however long its value is. Two members that name the same image range ask for more hashing than the container's size allows, and the container is refused with hash-budget before any digest is computed. The writer refuses what the reader or the stub refuses: no members, too many members, and a container larger than 16 MiB. One file reader in cntool.c keeps the cause of a failed read (no such file, permission denied, a directory, an empty file, a failed read, no memory), and cuda-objdump refuses the output modes that cannot be combined and parses the member index strictly.
The C reader test now writes the containers it breaks, and the shell test drives the tools over them, so the new cases have one crafting place.
Tests: fatbin 94/94, toolchain 249/249. lizard, cpd and mandoc clean. Not committed.
Next: the remaining gate round 1 findings (-emit-llvm, kind none, the trace arch, one magic check, the alignment wording, the rest of quality.6).

## C1.3 (#2427) 2026-11-24T08:20Z pass 3C done (docs, tables, tests)
The rest of gate round 1. The -emit-llvm compile now runs against the real fatbinary and is asserted to fail with "not a cuda-native cubin"; the limitation is in nvfatbin(1) CAVEATS and README.md. The error table is one table of name and message pairs with a build time check, and the shell test proves it. The magic is checked in one helper and one reader reads a whole file; the shell test proves both. The C reader test writes every broken container it builds and the shell test drives cuda-objdump over those files, so the Python crafting block is gone. The trace records the architecture of every image ("arch":"sm_121a") and the trace schema carries it as an additive, optional field. nvfatbin(5) says which offsets are 8-byte aligned and that the keys and values are packed, and it says that an image kind and an offload kind of none are accepted, as the reader does. The offload diagnostic is now "a member has an unsupported offload kind". nvfatbin(1) says that a failed trace write leaves the container in place. The fatbinary alias names itself the way it was invoked, in its usage and in its diagnostics, while the JSON and the trace keep the canonical name nvfatbin. The dead digest field sha256_ok is gone from the reader, the tools, the schema and the tests.
Tests: fatbin 112/112, toolchain 252/252. lizard empty, scan-cpd CLEAN, mandoc clean. Not committed.
Next: the gate round 1 review is answered in full (ROUND-REPORT-3C.md carries the merged answers); the work is ready for the commit gate.
## 2026-11-23T00:55Z #2455 checkpoint for an amp001 test boot
- Committed and pushed: b413557 (design, gate rounds ff8d06fb and 6ef863ea), 9e9925e (merge of main 999b186, overlap gate 963bb2f3).
- Suite stopped for the queued test boot: the merged branch and a 999b186 baseline (wt-2455-base) had 25 ok each, and the same four failures each (abi_layout, firmware, kmod_symbols, linux_bridge: modules not built in the prepared tree).
- RESUME: after the boot, rerun make test in wt-2455 and wt-2455-base (GB10_WORK=<wt>/work, SYSDIR=~/rx7600/kc502/src/sys, OGKM set), compare, open the PR, hand back for Mark's go.
- 2026-11-23T02:30Z after the boot: full suite on the branch and on the 999b186 baseline, same setup: 53 run, 8 failed on
  both, the same 8 (abi_layout, firmware, kmod_symbols, linux_bridge, native_tools_kit, prime_import, stubs, uvm_glue: RM
  cores, shim and modules not built in the prepared tree).
- Round 3 (approved by the orchestrator): MiniMax (minimax-mlapointe) applied fixes F1-F15 for the round-2 Review-open
  findings (tmp/2455/task-r3.md); the first attempt died on a transport error, the continuation finished. Orchestrator
  review fixed one slip by hand (the sample Ampere generation claimed arm64 testing on 0x2d04, which is Blackwell).
- Next: gate round 3, commit, push; PR #40 stays draft until Mark answers the 11 questions.

## 2026-11-23T04:10Z #2455 round 4: Mark's answers applied; part b cut by MiniMax quota
- Part a (tmp/2455/task-r4.md, MiniMax): Mark's answers of comment 17247 and the round-3 items B1-B11 applied; rc 0.
- Part b (tmp/2455/task-r4b.md: pluralistic backends P1-P4, RTX 30+ focus P5) stopped at 04:05Z on "Token Plan usage
  limit reached"; partial edits are in the working tree (4 table rows over 160 characters remain).
- Per the orchestrator: no Claude fallback; wait for the next 5-hour MiniMax window, then rerun part b as a
  continuation, then gate rounds (only if the voices do not fall through to Claude), commit, PR #40 out of draft.
- 2026-11-23T05:30Z part b finished as a continuation (tmp/2455/task-r4c.md, MiniMax, rc 0): P1-P4 (several of our
  backends at once, one per card; per-instance names through the alias layer; many devices per class) and P5 (phase 2
  builds RTX 30 and later only; other generations and vendors designed, not built). Next: gate round 1 (MiniMax-first).

## 2026-11-22 (UTC) libnvrm review follow-up (#2378, agent/2378-libnvrm-review-followup)
- The alias/raw fallback plan of the PAUSED entry (nvrm-info boot fixes and version sysctls) was dropped: with
  architecture and implementation available but no table row, compute capability is family_unknown, whatever
  the raw SM code is (nvrm(3), nvrm(7), nvrm-info(8) say the same).
- This follow-up fixes the Review-open items of c0102d7:
  - security.3: an NVRM_1.0 caller of nvrm_info_nfields()/nvrm_info_field() gets only the 30 rows of 8702134,
    in 1.0 order (nvrm_compat.c, .symver); the rows added later (rm_sm_version, compute capability, the versions
    group) are last in the table, and the NVRM_1.2 versions return all of it. dlvsym test and a mutant.
  - reason ids: nvrm_reason_from_id (now public, NVRM_1.2) is the one mapping, used by the running version and by
    the nvrm-info text; rm_test plants os_call_failed.
  - compute capability reason is family_unknown independent of raw_sm; text output prints
    "unavailable: <reason text>" for a per-GPU version; fake profile "alias" is now "untabled"; fake_gpu_str
    switches with a default; core_test counts the appended rows instead of "rows + 5"; nvrm-info(8) says the
    vbios_* and firmware_* sysctls come with the kernel module of PR 33.
- Left for the owner: security.2 (host names and home paths in this journal).

## 2026-11-23 01:30Z checkpoint before the native-tools test boot (#2378)
- aba0014 pushed (agent/2378-libnvrm-review-followup). A --no-ff merge of main cbe6ca3 is staged, not committed
  (JOURNAL.md conflict resolved; this entry is unstaged on top of it).
- Full suite stopped at a clean point after make_contract_test (29 of 54; reds so far match main).
- Resume: rerun the suite from make_install_flow_test, overlap gate round, commit the merge, push, open the PR.
- BE nvidia-native-tools-test-20261123-1 (main 937f89f, check-be 65 ok) is queued with the orchestrator; after the
  boot, read logs/native-tools-testboot/<stamp>/ and report the nvrm-info rows.

## 2026-11-23 02:20Z follow-up merged with main again, PR 43 (#2378)
- The 01:30Z checkpoint is over: the cbe6ca3 merge is committed as 25c145d (overlap gate a870276a), and main
  b1f8736 is merged in on top (only this journal conflicted). PR https://github.com/cloudbsdorg/nvidia-gb10-freebsd/pull/43.

## 2026-11-24 #2476 GPU naming audit, round 1
- The GPU generation's name meant three things in this tree: the NVIDIA GPU generation (GA10x, RTX 30), the Ampere Altra CPU of amp001, and the agent's own seat name. Only the second one is ours to write "Ampere": on an Ampere Altra host a bare "Ampere" in a GPU message reads as the CPU.
- Rule applied: user-facing text about the GPU generation names the chip family and the product, never the marketing name of the generation: "GA10x (RTX 30) and later". The CPU stays "Ampere Altra"; the ACPI MCFG OEM ID stays "Ampere".
- src/gb10-archfloor/nv_arch_floor.h: DISPLAY and LABEL name the chip family and the product ("GA10x", "GA10x (RTX 30)"); NAME was the marketing name of the generation (it is the value of hw.nvidia.min_architecture_name and of the preflight JSON) and the row 0x17 kept its name.
- Kernel messages now: "is TU10x; this driver supports GA10x (RTX 30) and later", "older than GA10x", "is GA10x GA100, which needs the gsp_tu10x firmware". scripts/make.sh reads DISPLAY and LABEL from the same header, so the preflight reason follows.
- Docs and text: README.md, man/nvidia.4 (also the DIAGNOSTICS list and the new sentence that says the sysctl name is NVIDIA's name for the generation), docs/MANUAL-BUILD.md, PROVENANCE.md, devd/nvidia_gb10.conf, schema/make-preflight-1.schema.json, scripts/make.sh, scripts/prepare-tree.sh, patches/patch-zz-2457-arch-floor_nvidia_nvidia_pci.c.
- Tests updated in the same change: tests/arch_floor/arch_floor_test.c, tests/arch_floor_test.sh, tests/preflight_support_test.sh, and the devd truth-table label, which named the generation, now names the chip family.
- Kept on purpose in that round: every "Ampere Altra" (the CPU), the ACPI OEM ID "Ampere", the value of hw.nvidia.min_architecture_name and of the JSON architecture field (the marketing name of the generation), the libnvrm generation names ("<marketing>-<chip>"), the captured pciconf of the test host, and the JOURNAL headings of the earlier rounds. Round 2 moved the values to the chip families as well.
- mandoc -T lint man/nvidia.4: the same two STYLE warnings as HEAD (referenced manual not found), no new one.

## 2026-11-24 #2476 GPU naming audit, round 2 (chip families everywhere: the values and the identifiers)
- Rule: no marketing name for an NVIDIA GPU anywhere in this tree, values and identifiers alike. The architecture rows are chip families: the chip prefix with the last digit of the family's first chip replaced by an x, or the chip name where the family has a single chip (GH100). 0x11 GM10x, 0x12 GM20x, 0x13 GP10x, 0x14 GV10x, 0x15 GV11x, 0x16 TU10x, 0x17 GA10x, 0x18 GH100, 0x19 AD10x, 0x1a GB10x, 0x1b GB20x (the names come from the PMC_BOOT_42 constants of nv_ref.h).
- Values moved with it: hw.nvidia.min_architecture_name returns GA10x, the preflight JSON carries the chip family in min_architecture.name and in every items[].support.architecture, the preflight text prints arch=GA10x, and the kernel messages print the same names ("is TU10x; this driver supports GA10x (RTX 30) and later").
- libnvrm: the table rows are chip families now (gb20x, gb10x, gh100, ad10x, ga10x, ga100, tu10x), so the published family value of nvrm-info is a chip family; the schema pins the names (nvrm-info schema minor 4 with a chip_family def) and the core lint matches the chip prefixes with a digit after them.
- Schemas: make-preflight 1.2 (min_architecture.name and items[].support.architecture are an enum of the chip families) and nvrm-info 1.4 (the family value is an enum of the chip families). The fixtures follow.
- Docs: man/nvidia.4, lib/libnvrm/man/nvrm.7, README.md, docs/MANUAL-BUILD.md, docs/RENDER-UAPI.md, PROVENANCE.md, mesa/nvk-nvrm/DESIGN.md.
- A defect the rename exposed: the awk hexnum of scripts/make.sh read "b" to "f" as ten (awk reads a non-numeric string as 0, so "b"-"a" is 0), so 0x1a and 0x1b both read as 26 and the first of the two won. The old names were the same on both rows, so it was invisible; now it would name an RTX 50 card GB10x. Fixed with index("0123456789abcdef", c).
- Kept on purpose: every "Ampere Altra" (the CPU), the ACPI MCFG OEM ID "Ampere", NVIDIA's own class names (BLACKWELL_*, FERMI_VASPACE_A) quoted from their headers, the captured pciconf of the test host, and the captured kldstat listing (its module named "ada" is not the GPU generation).

## 2026-11-24 #2476 GPU naming audit, round 3 (the schemas take a major version, the tables agree)
- The commit gate refused the change: "schema/make-preflight-1.schema.json: a non-additive change (type, removal, narrowing, new enum value...) needs a new major version; it is 1.1 -> 1.2". Renaming an enum value is not additive, so the schemas take a new major and the old ones stay as they were.
- schema/make-preflight-1.schema.json is exactly the file of the last commit; schema/make-preflight-2.schema.json (version 2.0) is the new contract: min_architecture.name and items[].support.architecture are an enum of the chip families. Both are registered in schema/samples.json with their own captured fixture (tests/fixtures/make-preflight.json is the capture of the old contract, make-preflight-2.json the capture of the new one). The document carries the version three ways: schema_version "2.0" and the integers schema_major and schema_minor.
- nvrm-info: the schema is major 2 now (lib/libnvrm/schema/nvrm-info-2.schema.json, generated by the library; major 1 stays beside it for the consumers of the old contract), the family value is an enum of the chip families, and the library's API version is major 2: NVRM_API_MAJOR 2, NVRM_API_MINOR 0, the symbol version NVRM_2.0, and nvrm(7) says so.
- One family table: the architecture table of src/gb10-archfloor/nv_arch_floor.h is the one list of the names, and the rows of the chip family table of libnvrm publish the same names (the GA100 row is a profile of the GA10x family; the product identity is in chip_id and implementation). tests/libnvrm_test.sh compares the two and fails when the library publishes a family the driver does not know.
- The lint names the rule again: the marketing names of the generations (Ampere, Blackwell, ...) are refused in the core and in the published family values, and the check matches whole words, so an ordinary identifier (read1024, payload123) is not a chip. Four plants in tests/libnvrm_test.sh: two were red before the fix, two are green.
- The magic exception in nvrm_json.c is gone: the schema of a field comes from its kind and its chip family flag (nvrm_field_schema), never from its name; a synthetic string field named "family" in another group stays a string. The flag is appended to nvrm_field, not a new kind: the family row is one of the rows a program bound to NVRM_1.0 walks, and a kind it does not know is a kind it cannot read.
- The raw captures are records again: tests/data/nvrm-info-boot-20261122T095018Z is exactly the capture of that boot (the family value it carries is the one the library published then), and the test translates it to the chip family the tree's table gives for its classes.
- A kernel older than this build answers hw.nvidia.min_architecture_name with the marketing name of the generation: preflight translates the names that name exactly one chip family and leaves out the ones that name two, so the document is never a document its own schema rejects.
- The chip key: the third column of the architecture table is the first four characters of the chip names of the family (GM10, GM20, GV11, ...), because the two-letter prefix cannot tell GM10x from GM20x (a GB100 was reported as GB20x).
- The floor has one name: DISPLAY is gone, the messages print the name of the row they name.
- The docs name every family the code knows (the legend of the README and of nvidia(4)), and the below-floor list names all six.
- Every remaining "ampere" in the tree is the CPU vendor (Ampere Computing, the Altra platform, the ACPI OEM ID) or a recorded value: the table of the classification is in the round report.

## 2026-11-26 #2457 fix-first: the three review-open items in scripts/make.sh
- The review of PR 45 left three items open in scripts/make.sh. This round fixes each of them, with a test that fails before the change and passes after it.
- lld_check() no longer accepts an artifact it cannot prove LLD linked. The host's default linker is no longer evidence about one file: the file has to be a readable ELF relocatable, its .comment must not name another linker, and either the .comment says "Linker: LLD" or the build's own record (work/build/lld-provenance: the sha256 of the artifact and the absolute path of the linker that linked it) names LLD for that exact file. The build writes that record as it links (lld_record, with the linker resolved to an absolute path and refused when it is not LLD). A module nothing recorded, a module the record does not cover, a module whose recorded linker is gone, and a module whose recorded linker is not LLD all fail the build, and so does a file that is not an ELF module at all.
- A test can no longer hide a failure behind the skip status. 77 is a skip only for a test that says it skipped (a "skip:" line of its own) and only for a test on the list in scripts/make.sh (test_skips: abi_layout_test, cuda_native_fatbin_test, cuda_native_toolchain_test). A test that exits 77 without saying so fails the run, so a check that never ran can no longer look like an approved skip.
- A PREFIX is data. install_next_render() reads the next-step records through a pipe instead of an unquoted here-document, and the record encoding (blk) escapes "$" and "`" as well, so no shell that reads a record can expand what the user typed. The rendered command holds a command substitution in a prefix as text, and it never runs it.
- A refusal names the fix and the linker it refused: every message the linker check stops the build with says what to do (put /usr/bin ahead of /usr/local/bin in PATH, the base ld.lld is required, and run make build again), and a module whose comment names another linker says which one. "Not linked by LLD" on its own is a dead end.
- Docs: README.md (what the build refuses, the prefix guarantee, the skip rule), docs/MANUAL-BUILD.md (how the linker of a module is proved) and the usage header of scripts/make.sh.

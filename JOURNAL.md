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

## 2026-11-21T07:48:44Z (#2373 follow-up commit)
- Orchestrator: no round 3 on old commits; this is a NEW commit with 2 rounds. Fixes: EPERM for a stranger's free of a listed client (before the RM), 64-bit nonzero generations, late record: every free is logged with a sequence number and an allocation takes a mark before its RM call, a record that lands after a free of its handle began is refused (the tombstone alone left the reviewer's counterexample open: my harness showed the free completing before the record). Model rows + 3 glue mutants + 7 header plants. Folds in the staged JOURNAL.

- round 1 receipt bc7942bc: dropped the global free log (flood DoS) for tombstones + a log of SUCCESSFUL unlisted frees by end sequence; removed h.core; rows+mutants. Round 2 running.

## 2026-11-22 (#2373 close-path commit, new commit on ea27f0c, own 2-round budget)
- Orchestrator brief: route the nvco_remove_owner loop through nvco_remove_handle (the merge reviewer's proposed patch), model row (close-path 7-step), glue scenario scenario_close_path, plants close-ignored/remove-owner-keeps-held re-anchored plus new close-drops-marker (model and glue), README wording. Red on ea27f0c: model row 3 FAILs, glue scenario FAIL, close_path.c rc=1; green after: rc=0, client_owner_test.sh 81 ok rc=0, glue 44 ok rc=0, close_path.c rc=0.
- Gate round 1 running. Next: answers file, round 2, commit, push, Track #2373 and WP #2406.
- Round 1 receipt fba825ec5facfc74517f8f2e7c694f07b0ec483283c3e8aab87c673729e958a2 (5 voices FINDINGS). Answers in .round/tmp/answers.txt. Fixed: nvco_remove_entry (acts on the entry, no second lookup), held/many model rows, step labels, scenario ran-flag, README wrapped, pins on flattened text.

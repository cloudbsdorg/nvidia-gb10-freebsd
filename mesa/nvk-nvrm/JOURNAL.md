# NVK on libnvrm (Track #2379, epic #2362): journal

Paths: $W = /home/mlapointe/work/gb10 and $GPU = /home/mlapointe/work/gpu, both
on amp001 (the arm64 build host with the RTX 5060 Ti; this repo is private).
"GB10" below always means the DGX Spark chip, never a path. The stage names
(libnvrm S1 to S5) and the pins are defined once, in DESIGN.md (Terms and
section 1); this journal only refers to them. WP = a Track work package
(https://track.cloudbsd.org/work_packages/NNNN). review-and-record is the
commit review gate (skill commit-review-gate). An opencode round is one
implementation run of the opencode agent (skills opencode-round-rules and
opencode-briefing).

## Brief

Round 1 is the work that does not wait for libnvrm S2:

1. Pin a current stable Mesa. Study the nvkmd layer of NVK
   (src/nouveau/vulkan/nvkmd) and what NVK needs from it. Mesa is MIT. Its
   nouveau backend may be read for nvkmd op semantics only: no nouveau ioctl
   structures, layouts or op grouping go into the nvrm backend. The nouveau
   drm-shim patches in $GPU/wt-mesa-nvk are not read or reused.
2. Write DESIGN.md, an nvkmd "nvrm" backend on libnvrm, op by op: TSG, GPFIFO,
   USERD, doorbell, semaphores, and the fence model in place of DRM syncobj.
   File the libnvrm S3 and S4 gaps as WPs under #2362.
3. Build Mesa on FreeBSD arm64 with -Dvulkan-drivers=nouveau and an nvrm stub
   backend:
   - it enumerates through libnvrm and reports VkPhysicalDevice properties
     (vulkaninfo --summary with a native ICD);
   - allocation and submit return VK_ERROR_FEATURE_NOT_PRESENT, plainly
     marked as a stub;
   - CI runs on the libnvrm fake backend (NVRM_BACKEND=fake);
   - the test-boot rows are prepared (a kit step running vulkaninfo --summary
     under the nvidia driver); never kldload here.
4. Keep the patch series, a Makefile per the project-makefile-contract skill and
   the build scripts here in mesa/nvk-nvrm/.

Rules: every commit gets two review rounds (review-and-record) even if the
diff changes between them. Author Mark LaPointe <mark@cloudbsd.org>, push every
commit, code by opencode rounds. No /tmp, no stash, no --no-verify, no tool
trailers, no kldload, no reboot. Never read Linux, GPL or nouveau kernel source.

Done:
- Read docs/NATIVE-NVIDIA-SUBMISSION.md (sections 2-4, 6, 10, 11) and the memory
  rules (nouveau-must-go, native-nvidia-decisions, everything-must-be-native).
- Track: read #2379 (activity 16753, the blocker record). Children of #2362:
  2363 (Linux bridges optional), 2364 (native GPU monitor), 2365 (GB10 profile
  with no Linux), 2371 (native harness workloads), 2378 (libnvrm S1-S5
  umbrella), 2379 (this), 2380 (CUDA C0/C1), 2381 (native DRM/KMS on NVKMS),
  2382 (dirty-room encodings), 2419 (libnvrm S2). No libnvrm S3 or S4 WP exists
  yet. Plan: new WPs for them under #2362, shaped like #2419, whose Track
  parent is #2362 (the stage WPs are siblings of the #2378 umbrella, as #2419
  already is).
- Worktree $W/wt-nvk-nvrm, branch agent/2379-nvk-nvrm from origin/main
  7e28d7b (libnvrm S1 is on main).
- Mesa pin chosen and its tarball checked against the release notes; the pin
  itself (version, SHA256) is in DESIGN.md section 1. Tarball in
  `$W/build/nvk-nvrm/distfiles/`, extracted later (below).
- Prior art: $GPU/wt-mesa-nvk graphics/mesa-devel (#2309, 26.3 branchpoint, NVK
  builds on arm64; dependencies in $GPU/depsroot set up by $GPU/mesa-env.sh).
  The Makefile here should carry its own dependency setup, not point at that
  script.
- Gate note: review-and-record needs /sbin in PATH (it calls sha256).
- Log: 2026-11-22 paused for a test boot at the request of the orchestrator.
- Log: 2026-11-22 resumed after the test boot. Orchestrator: wait for
  "ROOT MAKEFILE ON MAIN <sha>" in $W/STATUS.md, merge main, then commit; no
  exemption file; opencode is out of quota, so implement directly.
- Mesa extracted to $W/build/nvk-nvrm/src/mesa-26.3.1. nvkmd studied;
  DESIGN.md written (op map, channels, fence model, device info, build
  layout, test-boot rows, estimate) and revised over review rounds. The
  libnvrm S2 header was read from the uncommitted wt-libnvrm-s2 tree; its
  pin is in DESIGN.md section 1.
- Track: filed #2437 (libnvrm S3), #2438 (libnvrm S4), #2439 (S1/S2
  extensions for NVK), all under #2362.
- BLOCKER: the Mesa tarball AGENTS.md says AI agents must not change
  src/nouveau (nouveau.freedesktop.org/Humanity.html). The stub backend lives
  there, so it was not written. DESIGN.md section 0 has the decision for Mark.

- Paths and host names in this journal: kept on purpose. The repository is
  private (Mark 2026-11-20: repos stay private until he says otherwise), and
  the resume notes need the real locations. Reviewers raised it; recorded
  here as the decision.

- Log: 2026-11-22 06:54Z "ROOT MAKEFILE ON MAIN d01503806c66" appeared in
  $W/STATUS.md (#2440). The branch had no commits yet, so it was
  fast-forwarded to origin/main d015038; the design commit sits on top.

- Log: 2026-11-22 Mark answered section 0: our own fork (Track #2379,
  comment 16854; memory mesa-own-fork). Agents write src/nouveau in the
  private fork; Mesa AGENTS.md and CLAUDE.md unedited; FORK-NOTES.md added;
  no Generated-by trailers.
- Who writes code (the one place this is recorded): opencode Kimi rounds
  (dgx-mlapointe/kimi-k3.1-pro; on a quota error kimi-k3, then
  kimi-k2.7-code). When opencode cannot do it, a Sonnet or Haiku sub-agent.
  Never the Opus orchestrator, which briefs, reviews, tests and gates.
  Exception on record: the first version of the stub (nvkmd nvrm backend,
  enumerate hook, probe, Makefile, cloudbsd/) was written by the Opus
  orchestrator under the earlier "or write directly" instruction, before
  this rule arrived. It is disclosed on Track (comment 16858) and in the
  fork commit message.
- Fork: private repo cloudbsdorg/mesa-cloudbsd. upstream/26.3.1 and tag
  mesa-26.3.1 pushed unchanged (fec8830e9c9). Worktree
  $W/mesa-fork/mesa-cloudbsd, branch cloudbsd/26.3. Build area
  $W/build/nvk-nvrm (fork-build, rounds/).
- The old open items, now settled:
  - Single source of the stub message: done. nvkmd_nvrm_msg.h is the only
    copy; the backend logs it, and the probe includes it and prints it.
    make test takes the expected text from the probe output.
  - Privilege split: done in make.sh of the fork (only install-deps needs
    root; build, test and clean refuse root; the clean path is guarded).
  - mesa/nvk-nvrm/SOURCES: superseded. The pin is the upstream/26.3.1
    branch and mesa-26.3.1 tag of the fork.
  - Fake-backend CI: make test in the fork does it. Wiring it into a
    Jenkins job is still open (Next 2).
- make build test passes 21 checks on the fake backend. vulkaninfo --summary
  creates a device before printing, so on the stub it stops at the refusal;
  the probe prints the summary fields instead.
- Fork commit 01f36b0a84f on cloudbsd/26.3, pushed to the private repo
  (visibility checked: PRIVATE).
  - Gate round 1: lizard blocked (fill_dev_info CCN 35, the upstream create
    function, the probe main length).
  - Kimi r1 declined because of the Mesa AGENTS.md. Kimi r2, with the
    FORK-NOTES context, split the probe main and declined src/nouveau.
  - A Sonnet sub-agent split nvkmd_nvrm_fill_dev_info and added one lizard
    suppression. Its scope is nvk_create_physical_device_for_nvkmd only:
    the upstream NVK body, renamed and not otherwise changed. No suppression
    covers our own code.
  - Gate round 2 (the second and last round for this commit): all voices
    reached, receipt on the exact diff. Committed, with the findings deferred
    to a follow-up commit and listed here (Next 1) and in the commit message.
  - make build test passes 21/21; the probe output is byte-identical across
    the refactor.

- Log: 2026-11-22 later the same day, three more decisions by Mark, three
  fork commits (all pushed to cloudbsd/26.3, each with two gate rounds):
  - 084b498fbbe "highjack agents.md for every agent": our AGENTS.md governs
    every agent in the fork (CLAUDE.md and GEMINI.md link to it). Mesa text
    kept byte for byte as UPSTREAM-AGENTS.md, with UPSTREAM-CLAUDE.md and
    UPSTREAM-GEMINI.md as byte copies (regular files: the gate does not scan
    links). Since then Kimi accepts src/nouveau work (r3 step 0: "Yes.
    AGENTS.md explicitly permits changes throughout this private fork").
  - 019a93c8543 no "nouveau" in what users see: libvulkan_nvk_nvrm.so,
    nvk_nvrm_icd.<arch>.json, driverName "NVK (CloudBSD, libnvrm)",
    -Dvulkan-drivers=nvk alias, install into WORK/prefix, leak test.
    make build test 30/30. Authors: Mesa-tree renames by a Sonnet
    sub-agent; the rest by Kimi r3 and r5.
  - The nouveau kernel-driver removal ("delete everything that talks to the
    nouveau kernel driver; keep NVK, NAK and nvrm"): NOT done yet. Kimi r4
    was started with the brief $W/build/nvk-nvrm/rounds/r4/task.md and
    stopped by exact PID for the test-boot pause before it changed any file
    (the working tree is clean at 019a93c8543).

## RESUME (paused 2026-11-22 about 09:40Z for test boots)

State: fork cloudbsd/26.3 at 019a93c8543, pushed, clean tree. This branch
(agent/2379-nvk-nvrm) carries the docs. No round or watchdog is running.

Resume order:
1. Rerun Kimi r4 (the deletion) from the brief above, unchanged:
   sh $W/build/nvk-nvrm/rounds/start-round.sh $W/build/nvk-nvrm/rounds/r4 dgx-mlapointe/kimi-k3.1-pro
   then /bin/pwait on the watchdog pid it prints. Empty r4/round.status
   first is done by the script. Review the diff, run make build test (30
   checks plus the new "no nouveau uAPI in the build" check), two gate
   rounds, commit as its own commit, push, Track comment.
2. Fold in the open round 2 findings of 019a93c8543 (mesa_opts unquoted, so
   a WORK with spaces breaks meson setup; the regular-file rule for the
   UPSTREAM copies is not enforced; failing name checks do not list files;
   help line width; README placeholders; usage string).
3. Update DESIGN.md and this journal for the renames (libvulkan_nvk_nvrm,
   -Dvulkan-drivers=nvk, the ICD names) once the deletion lands.
4. Then the older items below.

Next (open work only):
1. Follow-up fork commit for the gate round 2 findings (Kimi for the
   cloudbsd/ files, Sonnet for src/nouveau; two review rounds):
   - make.sh: the vulkaninfo crash check cannot fail. The host-visible VRAM
     check matches one exact value instead of the flag bits. do_clean
     compares strings, not resolved directories. A relative WORK breaks the
     build. build_mesa ignores changed options after the first meson setup.
     The die "run make build first" ignores WORK.
   - nvkmd_nvrm_pdev.c: the smem memcpy size comes from the destination.
     libnvrm values are narrowed without bounds checks. caps[4] and caps[6]
     are magic indices. An enumeration failure looks the same as no GPU.
   - The lizard marker wording. The README probe command. preflight versus
     install-deps (the tool lists differ). The stub message accuracy. The
     meson error text. The help text.
2. Wire the fork make test into a Jenkins job (arm64 builder).
3. When #2419 is committed, re-pin S2 in DESIGN.md section 1 and re-check the
   S2 rows of section 3.
4. Open review findings carried to the next design revision (gate round 5,
   interface and quality voices): make the cross-process stall log line
   traceable (sync id, peer pid where known); give the Makefile root refusal
   an exact message; say what an operator can report on device loss (Xid,
   channel, devd event); state the wait and device-loss rules once and refer
   to them.

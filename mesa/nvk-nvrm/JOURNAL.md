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

Next (open work only):
1. Wait for the answer of Mark on DESIGN.md section 0, on Track #2379
   (`section 0: (a)` or `(b)`). Until then no Mesa patch is written by an
   agent.
2. Not policy-bound, can be done directly: mesa/nvk-nvrm/SOURCES, the
   Makefile with the targets and privilege split of DESIGN.md section 7, and
   the fake-backend CI target.
3. When #2419 is committed, re-pin S2 in DESIGN.md section 1 and re-check the
   S2 rows of section 3.
4. Open review findings carried to the next design revision (gate round 5,
   interface and quality voices): make the cross-process stall log line
   traceable (sync id, peer pid where known); give the Makefile root refusal
   an exact message; say what an operator can report on device loss (Xid,
   channel, devd event); state the wait and device-loss rules once and refer
   to them; confirm that the stub message macro is the only source the probe
   and CI read.

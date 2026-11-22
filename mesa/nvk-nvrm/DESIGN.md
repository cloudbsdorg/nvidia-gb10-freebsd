# NVK on libnvrm: the nvkmd "nvrm" backend

Track #2379 (epic #2362). Status: design, round 1. Nothing here is built yet.

This design is for a Mesa NVK kernel-mode-driver backend that submits directly
to NVIDIA's open RM through `libnvrm`. It uses no nouveau driver, no
nouveau-shaped uAPI and no DRM render node (Mark, 2026-11-21: the nouveau driver
and anything shaped like its uAPI must go). It is the Vulkan half of the shared
layer in `docs/NATIVE-NVIDIA-SUBMISSION.md` (section 4, WP S7). Native CUDA
reuses the same libnvrm.

Terms used below:

- **RM**: NVIDIA's resource manager in `nvidia.ko`, driven by the ioctls of
  open-gpu-kernel-modules (MIT).
- **libnvrm**: our C library over those ioctls, in `lib/libnvrm/`.
- **S1 to S5**: the libnvrm stages in section 10 of the submission document.
  S1 is enumeration (on main), S2 memory and VA (#2419), S3 channels and submit
  (#2437), S4 sync and events (#2438), S5 compute dispatch for CUDA.
- **S6'** and **S8'**: cross-vendor buffer sharing and the native display seat
  on NVKMS (#2381).
- **V0 / V1**: NVK enumeration / NVK compute (section 6.1 of the same
  document).
- **uvm-bsd**: our BSD nvidia-uvm, which already runs kernel GPFIFO channels.
- **Memory attribute rule**: on the Ampere Altra host (amp001), CPU mappings
  of GPU BAR memory are Device-nGnRE, where only aligned 1, 2, 4 or 8 byte
  accesses are safe (`nvrm_mem(7)`, `src/gb10-memattr/`).
- **Heavy tier**: the review level for kernel changes (two Opus voices plus
  Fable).
- **Test-boot kit**: the self-recording one-shot boot environment that runs
  rows with the nvidia driver loaded.

## 0. The AI policy of Mesa and nouveau on src/nouveau (answered)

**Answered 2026-11-22 by Mark (Track #2379, comment 16854): our own fork.**
Mesa is MIT. CloudBSD keeps a private fork, `cloudbsdorg/mesa-cloudbsd`
(branch `cloudbsd/26.3` on top of the unchanged `upstream/26.3.1`), and never
submits it upstream. Mesa's `AGENTS.md` governs contributions to the Mesa
project, not this fork. In the fork, agents write the nvkmd nvrm backend and
any `src/nouveau` change, including the `graphics/mesa-devel` patches (#2309)
and the NAK work for native CUDA. No `Generated-by` trailers are added: our
no-tool-trailers rule stands. Who writes the code (which models, and the
fallback) is recorded once, in `JOURNAL.md`.

Later the same day, Mark made two more decisions for the fork:
- **Our own `AGENTS.md`** (fork commit 084b498fbbe). It governs every agent
  in the fork. Mesa's text is kept as `UPSTREAM-AGENTS.md`, for any patch
  that would ever leave the fork. `FORK-NOTES.md` records why.
- **No "nouveau" in anything a user sees** (fork commit 019a93c8543): the
  library, the ICD, the driver name and the reports.
- **The nouveau kernel-driver code goes** (fork commits 4b21c1c37f2 and
  00e288210ac). Deleted: the nvkmd nouveau backend, the nouveau winsys,
  `src/nouveau/drm`, the drm-shim, the NAK and MME hardware tests, the
  loader's nouveau GL selection and `nouveau_drm.h`. The gallium nouveau
  driver and winsys are out of the build, but their files are not deleted
  in a commit yet (see the journal). NVK, NAK, nil and the hardware headers
  stay, and so does the directory name `src/nouveau`.

The analysis below is kept for the record. It recommended option (a), a
person writing the `src/nouveau` patches. Mark chose otherwise: agents write
them in a private fork, which is option (b) without the trailer. Option (a)
is not being pursued.

The Mesa 26.3.1 tarball ships an `AGENTS.md` (also as `CLAUDE.md`) at its root.
It says that AI agents must not make changes in `src/nouveau`, and it refers to
<https://nouveau.freedesktop.org/Humanity.html>. The same `AGENTS.md` also asks
that AI-written Mesa commits carry a `Generated-by: LLM` trailer, and that no
AI-generated code comments or commit messages go into Mesa.

Every Mesa file the backend changes is listed in section 2's table, plus the
new `nvkmd/nvrm/` directory, `nvkmd/nvkmd.h` (the new pdev entry point and
the `copy_sync_payloads` member) and `src/nouveau/vulkan/meson.build`. All of them
are under `src/nouveau/vulkan/`. The one exception is the new `nvk-kmd` option
in the root `meson.options`, which is outside `src/nouveau`. It is a one-line
build option, but it only makes sense together with the `src/nouveau` patches,
so it follows the same decision.

No patch under `src/nouveau` exists, and none is written until this decision
is made. This document is private design text in our repository, not Mesa
text, and the libnvrm side is our own code. Neither is affected by the
policy. The options:

- **(a), recommended:** a person writes the patches under `src/nouveau`, with
  this document as the spec. The libnvrm stages (#2437, #2438, #2439) and the
  build scaffolding in this directory (Makefile, fetch, verify, CI on the fake
  backend) stay with agents.
- **(b):** Mark decides that the policy, which is aimed at contributions to the
  Mesa community, does not bind a private fork that is never submitted
  upstream. Agents then write the code with `Generated-by: LLM` on each patch
  and no generated code comments, and Mark writes the patch commit messages.
  This also needs an exception to our own no-tool-trailers commit rule for
  `mesa/nvk-nvrm/patches/`, because the two rules conflict on that trailer.
  (b) is not recommended: `AGENTS.md` states the wishes of the Mesa and
  nouveau authors for the tree as a whole, and an agent should not decide on
  its own that a private fork is exempt.

Related finding: `graphics/mesa-devel` (#2309) already carries agent-written
patches under `src/nouveau` (`patch-src_nouveau_*`). Under the same policy they
need the same decision (section 9).

## 1. Pins and provenance

| Input | Version | Evidence |
|---|---|---|
| Mesa | **26.3.1** (2026-11-18), the newest release on archive.mesa3d.org when checked live on 2026-11-22 | SHA256 `4e4e438eac7b840a9383988cbb7c08dad8041da544b9319fc26d319fa7348961`, the same as in the release notes |
| libnvrm S1 | origin/main `7e28d7b` | `lib/libnvrm/include/nvrm/nvrm.h` |
| libnvrm S2 | merged to main: PR #11, merge commit `4a745c7` (#2419) | `lib/libnvrm/include/nvrm/nvrm.h` at `4a745c7` has SHA256 `85cb8807ecda8a815fd3593f324baa05646f6e1cf264fefe815eeaa6c0a1152f`. The S2 rows of section 3 were checked against it: the client calls are `nvrm_client_open` and `nvrm_client_close` (named `nvrm_device_open` and `nvrm_device_close` in the earlier working tree); every other call the op map names is unchanged, and the gaps for #2439 (PTE kind, fixed or second CPU mapping, `nvrm_mem_info.handle`, unmap by VA range) are still gaps |
| RM headers | open-gpu-kernel-modules `580.178.04` (MIT) | the `ogkm_tag` line of the repository root `SOURCES` |
| Class and method headers for push buffers | Mesa `src/nouveau/headers/nvidia/classes/` (MIT, from open-gpu-doc) | see section 5 for the trimmed `clc96f.h` |

Sources read: Mesa `src/nouveau/vulkan/nvkmd/nvkmd.{h,c}`, the NVK callers
(`nvk_instance.c`, `nvk_physical_device.c`, `nvk_device.c`, `nvk_queue.c`,
`nvk_mem_stream.c`, `nvk_wsi.c`), `src/vulkan/runtime/vk_instance.h` and
`vk_sync.h`, `src/nouveau/headers/nv_device_info.h`, and the MIT RM headers. No
nouveau kernel source and no Linux or GPL source were read. The nouveau nvkmd
backend was used only for its op names. Its ioctl structures, its layout and
its op grouping are not used here.

## 2. What NVK needs: nvkmd and the DRM assumptions around it

nvkmd (`nvkmd.h`) has five objects, each with an ops table: `pdev`, `dev`,
`mem`, `va` and `ctx`. The nvkmd core (`nvkmd.c`) keeps the list that maps a
device's memory by VA, map refcounting and the helpers.

NVK assumes DRM in four places outside nvkmd, and in the nvkmd core's
dispatch. Line numbers in this document are for Mesa 26.3.1.

| Where | Assumption | nvrm backend |
|---|---|---|
| `nvk_instance.c`: `physical_devices.try_create_for_drm = nvk_create_drm_physical_device` | GPUs are found only by walking DRM devices | set `physical_devices.enumerate` (the runtime hook in `vk_instance.h:158`) to an nvrm enumerator that calls `nvrm_enumerate()` and creates one pdev per GPU. A host with no `/dev/dri` still lists the GPU. If both backends are ever built, DRM stays the fallback |
| `nvk_device.c:264`: `copy_sync_payloads = vk_drm_syncobj_copy_payloads` | DRM syncobj | take it from the pdev (`nvkmd_pdev` gets a `copy_sync_payloads` member). Section 5 defines it |
| `nvk_device.c:260`, `nvk_wsi.c:24`: DRM fds for WSI and `VK_EXT_physical_device_drm` | a DRM fd exists | return -1, and do not advertise `VK_EXT_physical_device_drm`. Direct-to-display goes through NVKMS later (S8', #2381) |
| `nvk_physical_device.c`: the DRM render/primary `dev_t` in `pdev->drm` | DRM device numbers | zero. The device UUID comes from the RM UUID (`nvrm_device_info.uuid`) |
| nvkmd core, `nvkmd.c`: `nvkmd_try_create_pdev_for_drm` calls only nouveau | one backend | add `nvkmd_try_create_pdev_for_nvrm(nvrm_device *, ...)` and build `nvkmd/nouveau/` off for this target (meson option, section 7) |

## 3. Op map

### 3.1 Locking

`cl` is the backend's `nvrm_client` (one per `nvkmd_dev`). A client is not safe
for concurrent use (`nvrm.h`), and NVK calls nvkmd from several threads (the
queue submit thread, the application and the upload queue). The locking rule
is: **no call that can block waiting on another thread is made under the client
lock.**

- The client mutex covers only RM object create, free, map, unmap and control
  calls, which return without waiting on the GPU or on another thread.
- Each channel has its own submit lock for GPFIFO writes and the doorbell.
  When the ring is full, the lock is dropped while waiting for space.
- CPU waits (section 5) take no client lock. They use per-thread event
  descriptors, described next.


**Event descriptors** (one model, used by sections 4 and 5):

- Each pair (waiting thread, `nvkmd_dev`) has its own event descriptor. It is
  its own open of the nvidia device with its own `NV01_EVENT_OS_EVENT`.
- The event is bound **at device level**, on the subdevice, with
  `NV2080_CTRL_CMD_EVENT_SET_NOTIFICATION`, to two notifications:
  - the semaphore-release notification that every channel raises together
    with its releases (the non-stall interrupt);
  - `NV2080_NOTIFIERS_RC_ERROR`.

  The exact notifier indices are verified in S4. Because these bindings are
  not per channel, a channel created after the descriptor was opened is
  covered without rebinding.
- **The one per-object exception:** a sync shared with another process
  (exported or imported) is an `NV_SEMAPHORE_SURFACE` (section 5). A waiter on
  it also binds a value waiter of that surface to its descriptor for the
  length of the wait. A peer signals through the surface, not through our
  subdevice, so without this binding a cross-process signal would only be
  seen at the next slice.
- A CPU signal of a shared sync goes through the RM control of its
  `NV_SEMAPHORE_SURFACE` that sets the value, so that the value waiters in
  other processes fire; a plain store would wake no one there (#2438).
- A CPU signal of a pool sync within the process wakes waiters with
  `NV2080_CTRL_CMD_EVENT_SET_TRIGGER` on the device notification.
- **Ownership:** a descriptor is opened, used and closed only by its own
  thread. It is cached in a thread-specific key (`pthread_key_create`). Each
  `nvkmd_dev` has a generation number, and `dev.destroy` only bumps it; it
  never closes another thread's descriptor. The owning thread closes a stale
  descriptor (generation changed) on its next wait, or in the key destructor
  at thread exit. So no thread can close a descriptor number that has since
  been reused for something else, and no descriptor is closed under a thread
  blocked in `poll` on it.
- A wake is never consumed by another waiter, and draining an event touches
  only that thread's descriptor.
- **The wait loop is fixed:** read the values; if they are not reached, drain
  the descriptor, then read the values again, then sleep only if they are
  still not reached. Draining after a read but before the sleep, without that
  second read, could swallow a signal and sleep a whole slice.
- On every wake, including the slice timeout, the waiter also reads the mapped
  error notifier of every live channel of the device directly (section 4). No
  flag that another thread must set is involved.

**Test knobs:** the sleep slice is `nvrm_open_opts.wait_slice_ms` (new in
#2438; the default is 100 ms), and in the fake backend also
`NVRM_FAKE_SLICE_MS`. One bound, **T_wake = 20 ms**, is used by every wake
test below. It must be far below the slice used in the test (10 s), so that
passing shows a wake by event and not by slice timeout. On a loaded CI runner
the bound is relaxed through `NVRM_FAKE_T_WAKE_MS`, never the slice.

Fake-backend CI tests (slice 10 s):

- Thread A waits on a timeline value and thread B signals it from the CPU. A
  returns within T_wake of B's signal.
- Negative variant: a fake-backend knob suppresses the wake. The same test
  must then time out, which shows that the test can fail.
- Two waiters on two syncs: signal one, and only that waiter returns within
  T_wake. Then the same for the other.
- Lost-wake window: a knob injects the signal between the first read and the
  drain. The waiter still returns within T_wake.
- Device re-creation: create a device, wait, destroy it, create another, then
  wait again from the same thread. It returns within T_wake of a CPU signal.
- Descriptor reuse: thread T waits on device D1, and the test records the
  descriptor number N that T cached. The main thread destroys D1, then opens
  `/dev/null` up to N + 8 times. Getting N while T is alive is a **failure**,
  because it means destroy closed T's descriptor. Then T exits and closes its
  own stale descriptor, and every `/dev/null` descriptor opened must still be
  valid (`fcntl(F_GETFD)`).
- Two processes: a peer CPU-signals a shared sync, and the waiter returns
  within T_wake.
- Thread churn: 10,000 threads each do one CPU wait and exit. The number of
  open nvidia descriptors in the process must not grow.

### 3.2 Table

The last column is the **planned** stub behaviour. None of it is written yet.
Longer reasoning is in section 3.3.

| nvkmd op | libnvrm call (stage) | RM class or control | Planned stub behaviour |
|---|---|---|---|
| `try_create_pdev_for_nvrm` | `nvrm_device_get`, `nvrm_device_info_get` (S1) | `NV0000_CTRL_CMD_GPU_*`, `GPU_GET_INFO_V2`, `GR_GET_INFO`, class list | to work: fills `nv_device_info` (section 6) |
| `pdev.destroy` | `nvrm_close` (S1) | free the root client | to work |
| `pdev.get_vram_used` | none yet: `has_get_vram_used = false` | `FB_GET_INFO_V2` (#2439) | returns 0 |
| `pdev.get_drm_primary_fd` | none | none | NULL op (returns -1) |
| `pdev.create_dev` | `nvrm_client_open(NVRM_OPEN_ALLOW_MAP)`, `nvrm_vaspace_info_get` (S2) | `NV01_DEVICE_0`, `NV20_SUBDEVICE_0`, `FERMI_VASPACE_A` | every `vkCreateDevice` returns `VK_ERROR_FEATURE_NOT_PRESENT` and logs the stub line (3.3) |
| `dev.get_gpu_timestamp` | `nvrm_gpu_timestamp` (**S3**) | `NVC361_TIME_0/1` in USERMODE (3.3) | returns 0 |
| `dev.alloc_mem` | `nvrm_mem_alloc` (S2): `LOCAL`/`VRAM` to `NVRM_MEM_VRAM`, `GART` to `NVRM_MEM_SYSMEM` (GB10: always system memory) | `NV01_MEMORY_LOCAL_USER` / `NV01_MEMORY_SYSTEM` via `NVOS32` | not reached |
| `dev.alloc_tiled_mem` | **gap (#2439)**: no PTE kind or compression in `nvrm_mem_params` | `NVOS32_ATTR_*` | `has_alloc_tiled = false` |
| `dev.import_dma_buf` | `nvrm_mem_import_fd` (S2) for RM export fds; real dma-buf is S6' | `NV_ESC_RM_IMPORT_OBJECT_FROM_FD` | `has_dma_buf = false` |
| `dev.alloc_va` | `nvrm_va_reserve` (S2): `SPARSE`, `ALLOC_FIXED`; `REPLAY` from a range the backend reserves at the top | `NV50_MEMORY_VIRTUAL` | not reached |
| `dev.create_ctx` | `nvrm_chan_create` (**S3**) | section 4 | not reached |
| `mem.free` | `nvrm_mem_free` (S2) | free | n/a |
| `mem.map` | `nvrm_mem_map_cpu` (S2); **gaps (#2439)**: fixed address, a second mapping | `NV_ESC_RM_MAP_MEMORY` + mmap | n/a |
| `mem.overmap` | **gap (#2439)**: replace-first order (3.3) | none (CPU side) | `has_overmap = false` |
| `mem.sync_to_gpu`, `sync_from_gpu` | cached sysmem: cache clean/invalidate by range (`util/cache_ops.h`); WC or Device: no-op | none | n/a |
| `mem.export_dma_buf` | `nvrm_mem_export_fd` (S2): an RM export fd (OPAQUE_FD), not a dma-buf | `NV_ESC_RM_EXPORT_OBJECT_TO_FD` | n/a |
| `mem.log_handle` | RM handle (**#2439**: `nvrm_mem_info.handle`) | none | n/a |
| `va.free` | `nvrm_va_release` (S2) | free | n/a |
| `va.bind_mem` | `nvrm_mem_map_gpu` (S2) at `va->addr + va_offset_B` | `NV_ESC_RM_MAP_MEMORY_DMA`, `DMA_OFFSET_FIXED` | n/a |
| `va.unbind` | `nvrm_mem_unmap_gpu` (S2); **gap (#2439)**: unmap by VA range | `NVOS47` | n/a |
| `ctx.exec` | `nvrm_chan_submit` (**S3**) | GPFIFO, `GP_PUT`, doorbell | not reached |
| `ctx.bind` | `bind_mem`/`unbind` on a worker thread (3.3) | as above | not reached |
| `ctx.wait` | GPU: semaphore acquire, except on an imported sync, which goes to the CPU-side worker (3.3); bind ctx: the worker | section 5 | not reached |
| `ctx.signal` | GPU: semaphore release, then flush; bind ctx: the worker | section 5 | not reached |
| `ctx.flush` | `GP_PUT` and doorbell (section 4) | `BLACKWELL_USERMODE_A` 0xc761 | not reached |
| `ctx.sync` | flush, then a CPU wait on the channel's progress semaphore | section 5 | not reached |

### 3.3 Notes on the table

- **The stub's result and log line.** The stub implements enumeration and
  nothing else. Every later operation needs a device, so `vkCreateDevice`
  returns `VK_ERROR_FEATURE_NOT_PRESENT`: the device supports no feature that
  a queue needs. Because that code alone reads like "a requested feature is
  missing", the stub also logs one line, defined once as a macro in the patch
  (`NVK_NVRM_STUB_MSG`) that the probe's check is generated from:
  `nvk-nvrm: this build can list NVIDIA GPUs but cannot create a Vulkan device yet (queues are not implemented); to use another driver, set VK_LOADER_DRIVERS_SELECT or VK_ICD_FILENAMES`.
  The test-boot row in section 8 greps for this literal string, and so does
  the CI row on the fake backend, so a generic NVK failure with the same
  `VkResult` does not pass, and a reworded message fails CI.
- **GPU timestamp:** `TIME_0` and `TIME_1` are two 32-bit registers on a
  Device-nGnRE mapping, read as aligned 4-byte loads. The read is hi, lo, hi
  again, retried until both hi values match, so a wrap of `TIME_0` between the
  loads cannot make the value jump by 2^32 ns. Fake test: a register pair that
  wraps between reads must still give a monotonic value.
- **`mem.map`:** NVK needs an internal mapping and a client mapping of the same
  object at the same time, and `NVKMD_MEM_MAP_FIXED` for the client mapping.
  S2 has one CPU mapping per object and no fixed address. Unless BAR mappings
  are known to be Normal memory, `mem.map` of an `NVRM_MEM_VRAM`
  object is refused with `VK_ERROR_MEMORY_MAP_FAILED` (note 6.2).
- **`mem.overmap`:**
  1. Replace the client mapping with anonymous memory **first**:
     `mmap(MAP_FIXED|MAP_ANON)` directly over the still-mapped range, which
     is atomic. Unmapping first would leave the range free for another
     thread's `mmap`, which the `MAP_FIXED` would then silently replace.
  2. Then libnvrm still issues the RM-side unmap (`NV_ESC_RM_UNMAP_MEMORY`)
     for the original linear address, so the kernel's mapping record is not
     leaked. This goes through **its own libnvrm entry point**, which issues
     only the ioctl and never calls `munmap` on the client range; the plain
     `nvrm_mem_unmap_cpu` must not be used here, because its `munmap` would
     free the range again and reopen the race. #2439 has to read the MIT
     unmap path in open-gpu-kernel-modules first, to confirm what RM checks
     when the VMA has already been replaced. If RM refuses, the fallback is an
     RM-side "forget mapping" call.

  Tests: while a second thread loops `mmap(NULL, len)`, overmap in a loop;
  assert that no address the second thread gets falls inside the overmapped
  range, and that the whole range stays mapped (`mincore()` succeeds on every
  page) and reads back as zero-filled memory. A 10^5-iteration overmap loop
  on one object must leave the client's
  RM mapping count where it started.
- **`va.unbind`:** the S2 call takes the mem object, and nvkmd `unbind` gives
  only a VA range. Either libnvrm unmaps by range, or the backend keeps a VA
  to (mem, offset) interval map per va.
- **The CPU-side worker.** Each queue has one worker thread, which does the
  work that must not be put on the GPU or must not block the caller:
  - **`ctx.bind`:** RM maps are synchronous, so a bind context is a CPU queue
    served by the worker. The worker waits on the context's waits, applies
    the binds in order, then signals. A bind that waits on a value the same
    application thread signals later (`vkQueueBindSparse` and then
    `vkQueueSubmit`) cannot then deadlock. Test: that single-thread sequence
    must complete.
  - **Waits on imported syncs** (section 4, "Another process"): the worker
    holds the waiting batch until the value is reached.
  - **`copy_sync_payloads` from an imported source** (section 5): the same.

## 4. Channels (libnvrm S3, #2437)

One `nvkmd_ctx` with any of `COPY`, `2D`, `3D`, `M2MF` or `COMPUTE` becomes:

- a **TSG** (`KEPLER_CHANNEL_GROUP_A`, 0xa06c) on the client's VA space, with
  engine type graphics (which covers 3D, compute, 2D and I2M) or copy;
- one **GPFIFO channel** in it (`BLACKWELL_CHANNEL_GPFIFO_B` 0xca6f on GB20x, `_A`
  0xc96f on GB10; libnvrm picks it from `cls_gpfifo` in its generation table).
  The channel has:
  - `NV_CHANNEL_ALLOC_PARAMS` with `hVASpace`;
  - `hUserdMemory` in system memory, CPU-mapped (uvm-bsd already uses sysmem USERD);
  - a ring of 2^n 8-byte GPFIFO entries in sysmem, mapped to the GPU and CPU;
  - `hObjectError` (an error notifier) and `hObjectEccError`;
- the **engine objects** bound to fixed subchannels, the way NVK's push code
  expects: 3D `BLACKWELL_B` 0xce97, compute `BLACKWELL_COMPUTE_B` 0xcec0, I2M
  `BLACKWELL_INLINE_TO_MEMORY_A` 0xcd40 and 2D (class from the class list),
  each `_A` on GB10. NVK already emits the `SET_OBJECT` methods in its init
  push, so libnvrm only allocates the RM objects;
- **copy** (`BLACKWELL_DMA_COPY_B` 0xcab5, `_A` on GB10): a context that asks
  for `COPY` only gets a TSG and channel on a copy engine. Whether a channel
  on the graphics runlist can also host the copy class, which NVK's graphics
  queue uses in the same push stream, is **not known**. The S3 spike answers
  it (#2437). If it cannot, the backend must not offer `COPY` on a graphics
  context. NVK's copies on that queue then need another path, and that is a
  design decision to record in #2437 before the backend is written. Fake
  test: create a `3D|COPY` context and check which channel the copy
  subchannel lands on;
- the **work-submit token** (`NVC36F_CTRL_CMD_GPFIFO_GET_WORK_SUBMIT_TOKEN`,
  0xc36f0108) and the per-device CPU mapping of `BLACKWELL_USERMODE_A`, whose
  `NOTIFY_CHANNEL_PENDING` register (0x90) is the doorbell.


`exec` takes an array of `n` `nvkmd_ctx_exec` elements and writes one GPFIFO
entry per element: address, length in dwords, and `no_prefetch` to the entry's
fetch and sync bits. This matches `nvrm_chan_submit(ch, entries, n)`.

**Capacity.** A ring of `E` entries holds at most `E - 1` pending entries,
because `GP_PUT == GP_GET` means empty. Every batch the backend submits ends
with one entry of its own: the release of the channel's progress semaphore
(ring space, below), a small push segment the backend owns. So one batch
carries at most `E - 2` NVK elements, and `nvrm_chan_gp_space` reports space
for NVK elements with that entry already subtracted.

**Splitting.** nvkmd does not bound `n`, and a command buffer can have more
push chunks than the ring has entries. So a call with a large `n` is split
into batches of at most `E - 2` elements, all under one ticket (below), in
order.

- An element with `incomplete` set and the element after it always go in the
  same batch.
- A run of `k` `incomplete` elements needs `k + 1` slots, with its
  terminating element. So a run longer than `E - 3` cannot be placed and is
  refused with an error.
- A last element with `incomplete` set breaks the nvkmd contract and is
  refused.

Fake tests, on an 8-entry ring:

- with space for one NVK element, an incomplete pair completes once the fake
  `GP_GET` advances;
- `n = 6` on an empty ring goes in one batch, with the release in the seventh
  slot;
- `n = 24` completes in order as the fake `GP_GET` advances, and the decoded
  order matches the input;
- a run of 6 `incomplete` elements and its terminator is refused at once;
- a run of 5 `incomplete` elements and its terminator goes in one batch, with
  the release in the seventh slot.


**Memory types:** the GPFIFO ring and USERD are system memory, mapped cached on
a coherent platform and WC (arm64 Normal non-cacheable) otherwise. Neither is
ever a Device-nGnRE mapping. The doorbell is the only device-memory write on
the submit path.

**Flush ordering:**

1. Write the GPFIFO entries.
2. Store barrier for normal memory (`dmb oshst` on arm64, `sfence` on amd64),
   so the GPU cannot see the new `GP_PUT` with a stale entry. On WC memory both
   stores could otherwise reach the GPU out of order.
3. Store `GP_PUT` in USERD.
4. A store barrier that also orders normal memory against device memory
   (`dsb st` on arm64, `sfence` on amd64). A store-release on `GP_PUT` alone
   does not order it against the later Device-nGnRE doorbell write, so the GPU
   could see the doorbell and read a stale `GP_PUT`: a lost kick.
5. Write the token to the doorbell.

The same sequence goes into the shared encoder path used by uvm-bsd. A unit
test checks the barrier sequence in the encoder output, because a hardware
stress row may never hit the window. No syscall is needed per submit. The S3
test boot has a stress row: 10^6 single-entry submits, each followed by a
wait, with no timeout allowed.

**Ring space:**

- libnvrm tracks `GP_GET` from USERD.
- Submitters are served in arrival order. A per-channel ticket is taken under
  the submit lock, and a waiter re-checks space under the lock when its turn
  comes. So a later small `exec` cannot slip in ahead of an earlier one that
  is waiting, and the in-order channel keeps the order of the calls.
- When the ring is full, the waiter drops the lock and waits.
- The wake source is the channel's **progress semaphore**. The backend
  appends a release of it to every submitted batch (the same semaphore
  `ctx.sync` uses), and the release raises the device notification that the
  per-thread event descriptors listen to (section 3.1). So a ring full of
  batches without releases of their own still wakes the waiter.
- Each slice timeout also re-reads `GP_GET` and the error notifiers.

Fake test: fill the ring with NOP-only batches, set the slice to 10 s, then
advance `GP_GET`. The waiter must proceed within T_wake (section 3.1).

**Device loss:**

- The error notifier of a channel is mapped into the CPU and read on every
  flush.
- `NV2080_NOTIFIERS_RC_ERROR` is bound at device level to every per-thread
  event descriptor (section 3.1). There is no per-channel event.
- Every CPU sleep is capped at a slice (100 ms to start, configurable for
  tests). On every wake, including the slice timeout, the waiter reads the
  mapped error notifier of **every live channel** of the `nvkmd_dev` directly.
  If any of them reports an error, the device is lost.
- A timeline sync is not bound to one channel, and the signalling submit may
  not exist yet when the wait starts. So the waiter checks all channels of the
  device rather than "its" channel. This covers channels created after the
  wait began.
- So a `UINT64_MAX` wait whose signaller faulted returns
  `VK_ERROR_DEVICE_LOST` instead of hanging. Fake tests:
  - open the thread's descriptor with one wait; create a new channel; submit
    and flush once; fault the channel with no further flushes. A `UINT64_MAX`
    wait must return `DEVICE_LOST` within two slices;
  - the same with the slice set to 10 s must return within T_wake, through
    the RC-error notification.
- **Another process.** An imported sync whose signaller is in another
  process is the exception. This process cannot see that device loss.
  - A **CPU wait** on such a sync logs once per sync, after 5 s without
    progress:
    `nvk-nvrm: no progress for 5 s on a semaphore shared by another process; this process cannot see that process's GPU loss, so the wait ends only at its timeout (never, if the timeout is infinite); check that the other process is still running`.
    The wait then ends at its timeout. The limitation is written in the
    known-limitations section of the planned `mesa/nvk-nvrm/README.md`. Fake
    test: a finite timeout with a peer that never signals returns
    `VK_TIMEOUT`, and the line is logged once.
  - A **GPU wait** on an imported sync is never put on a channel as an
    acquire, because a channel blocked on it would stay blocked with no
    limit. The queue's **CPU-side worker** (section 3.3) holds the waiting
    batch, and every later batch of that queue, until the capped CPU wait
    sees the value. Only then does it submit them. The queue still waits, as
    it would on any driver: a `vkWaitForFences` or `vkWaitSemaphores` with a
    finite timeout on its work returns `VK_TIMEOUT`. What this gains is that
    no channel is ever wedged, so other queues, other contexts and the device
    stay healthy. `ctx.destroy` and `dev.destroy` cancel the worker's wait and
    drop the held batches, so `vkDestroyDevice` returns. (Destroying a device
    with pending work is outside the Vulkan rules, but it must not hang the
    process.) Fake test: import a sync, submit a GPU wait on it, never signal
    from the peer. Then work on a second queue completes, a fence wait on the
    first queue's work with a finite timeout returns `VK_TIMEOUT`, and device
    destroy returns within T_wake with the worker thread joined.
- Once a context is dead, every later op on it returns `VK_ERROR_DEVICE_LOST`.


API shape (proposal, final in #2437):
`nvrm_chan_create(cl, &nvrm_chan_params{engines, gpfifo_entries}, &ch)`,
`nvrm_chan_submit(ch, const nvrm_gp_entry *, n)`, `nvrm_chan_kick(ch)`,
`nvrm_chan_gp_space(ch)`, `nvrm_chan_status(ch)` and `nvrm_chan_destroy(ch)`.
The method encoder is shared with uvm-bsd's `uvm_hal_methods.h`. NVK keeps
`nv_push.h`, and a test checks that both produce the same words.

The fake backend runs the GPFIFO: it decodes entries, runs NOP, semaphore
release and acquire, and copy methods, and records the rest. CI drives NVK's
own init push through it.

## 5. Fences: one RM semaphore model in place of DRM syncobj (libnvrm S4, #2438)

NVK hands its sync types to the Vulkan runtime (`pdev->sync_types`;
`nvk_mem_stream.c` uses `sync_types[0]`). The nvrm backend provides **one
native timeline sync type**, `nvkmd_nvrm_sync`:

- **Storage:** a 64-bit value. Syncs that are never exported live in a
  per-device semaphore pool of system memory. The pool is mapped CPU-cached
  where the platform is coherent and WC otherwise. It is never a Device-nGnRE
  BAR mapping, because CPU waits read it constantly. The pool has one slot per
  sync, with a slot allocator in libnvrm (`nvrm_sem_pool_*`).
- **Exportable syncs** (created with `VkExportSemaphoreCreateInfo` or
  `VkExportFenceCreateInfo`) each get **their own object**, which holds only
  that value. An export never hands out the pool, so another process can never
  read or write this process's other fences. The object is an
  `NV_SEMAPHORE_SURFACE` (0xda), not general memory, so that an import can
  check its class (below).
- **GPU signal:** host-class semaphore release in the channel (`SEM_ADDR_LO/HI`,
  `SEM_PAYLOAD_LO/HI`, `SEM_EXECUTE` with operation `RELEASE`, a 64-bit
  payload and `RELEASE_WFI` enabled), **followed by the host-class non-stall
  interrupt method**, which raises the semaphore-release notification that
  CPU waiters and ring-space waiters sleep on (section 3.1). Without it, every
  GPU-signalled CPU wait would wake only at the slice timeout. The method's
  name and encoding are verified in the S3 spike (section 9). A fake decode
  test asserts that the backend's release segment contains it, and a hardware
  row checks that a GPU release wakes a CPU waiter within T_wake with the
  slice at 10 s. Mesa's copy of `clc96f.h` and the RM copy
  are both trimmed: they carry no `ACQ_CIRC_GEQ` and no 64-bit payload value.
  Both are in `clc86f.h`, and the Blackwell values are **to be verified** in the
  S3 spike (a fake-backend decode test plus one hardware release).
- **GPU wait:** semaphore acquire on the 64-bit value. The acquire in
  `clc86f.h` is `ACQ_CIRC_GEQ`, a wraparound compare: it passes when
  `(int64_t)(current - wanted) >= 0`, which is not a plain `>=`. The design
  keeps that compare and makes every side agree with it:
  - the CPU wait uses the same signed difference;
  - `maxTimelineSemaphoreValueDifference` is reported as at most `2^63 - 1`.

  If the S3 spike finds a strict (non-circular) 64-bit GEQ acquire on
  Blackwell, it may replace this, with the CPU side changed to match. Fake
  decode tests, with the GPU acquire and the CPU wait checked separately:
  - `current = 0`, `wanted = 2^63 - 1` (inside the advertised difference):
    both must **not** pass (the in-range check);
  - `current = 0`, `wanted = 2^63 + 1` (outside it): both **pass** under the
    circular compare, while an unsigned compare would not pass. This is the
    case that catches an unsigned compare on either side;
  - `current = 2^63`, `wanted = 1`: the difference is `2^63 - 1`, so both
    pass (the in-range positive side);
  - `current = 2^63 + 1`, `wanted = 1`: the difference is `2^63`, which reads
    as negative, so both must **not** pass (the boundary).

  The acquire works across channels in one client. A sync imported from
  another process is never acquired on the GPU (section 4, device loss); its
  waits go through the CPU-side worker.
- **CPU wait:** spin on the mapped value for a short bounded time, then sleep
  on the waiting thread's event descriptor (section 3.1). The wake comes from
  `NV01_EVENT_OS_EVENT` on the device's semaphore-release notification (a
  channel non-stall interrupt raised together with each release), or, for a
  sync shared with another process, from the value waiter of its
  `NV_SEMAPHORE_SURFACE` (the exception in section 3.1). Every sleep is
  capped and reads the mapped error notifiers of every live channel
  (section 4). The FreeBSD way to wait is `kevent(2)` on the device fd, which
  needs `d_kqfilter` in `nvidia_dev.c` (S4, a kernel change, heavy tier, test
  boot). Until then, `poll(2)` works, because the cdev already has `d_poll`.
- **CPU signal:** a store-release of the value, then a wake with
  `NV2080_CTRL_CMD_EVENT_SET_TRIGGER` on the device notification (section 3.1).
- **vk_sync features for V1:** `TIMELINE | GPU_WAIT | GPU_MULTI_WAIT |
  CPU_WAIT | CPU_SIGNAL | WAIT_ANY | WAIT_BEFORE_SIGNAL`. The GPU acquire just
  waits, so GPU-side wait-before-signal comes for free, and the bind context's
  worker thread (section 3) covers the CPU side. `WAIT_PENDING` is **not**
  claimed: a bare value records only completed signals, not submitted ones, so
  it cannot tell "submitted" from "not yet submitted". Adding a submitted
  high-water mark per sync, shared across processes, is a later design.
  Binary semaphores and fences use the runtime's `vk_sync_binary` over this
  type. Before implementation, check against `vk_queue.c` that this feature
  set selects immediate submit and needs no `vk_sync_timeline` emulation.
- **copy_sync_payloads** (used by WSI and by semaphore export with a pending
  source): queued on a GPU context as an acquire on the source value followed
  by a release on the destination. It does not block, and the destination is
  not signalled before the source. Reading the source value on the CPU would
  copy a stale value while rendering is still running. If the source is an
  **imported** sync, the acquire is not put on the GPU (section 4); the
  queue's CPU-side worker (section 3.3) waits for the source and then
  signals the destination. Fake tests: with the source pending, the
  destination must not read as signalled until the source is released; with
  an imported source whose peer never signals, unrelated work on another
  queue still completes.
- **External semaphores:** `OPAQUE_FD` is the RM export fd of the sync's own
  `NV_SEMAPHORE_SURFACE` object. On import, libnvrm checks the **RM class** of
  the imported object, which RM reports and which a `vkAllocateMemory`
  allocation cannot have. A size check alone would accept any one-page buffer.
  Anything that is not a semaphore surface is refused with
  `VK_ERROR_INVALID_EXTERNAL_HANDLE`. Fake test: export a one-page
  `VkDeviceMemory` and import it as a semaphore; it must be refused. If the S4
  spike finds that 0xda objects cannot be exported, the fallback is a weaker
  check, and the documentation then says plainly that a shared value is only
  as trustworthy as its exporter. `SYNC_FD` is not
  advertised: it needs the cross-vendor `gpusync(9)` bridge. The compositor's
  explicit sync on the native seat uses the same 64-bit semaphores (S8').
- **Device loss:** a wait that finds an error in the mapped error notifier of
  any live channel of the device returns `VK_ERROR_DEVICE_LOST` (section 4).

The kernel has no scheduler and no syncobj: ordering is in-order channels plus
semaphore acquires. This is the model NVIDIA's own user space uses on RM. Its
goal is to reach the submit latency Linux has. That is not measured yet; the
S3 exit measures it.

## 6. Device information: `nvrm_device_info` to `nv_device_info`

| `nv_device_info` | Source (S1 unless marked) |
|---|---|
| `type` | `SOC` only on a positive signal, otherwise `DIS` (note 6.1) |
| `pci.{domain,bus,dev,func,revision_id}`, `device_id` | `pci_*` |
| `chipset` | `architecture` + `implementation` (e.g. 0x1b0 + 0x6 = GB206). Check against the NVK chipset table |
| `device_name`, `chipset_name` | **gap (#2439)**: the RM marketing name (`NV2080_CTRL_CMD_GPU_GET_NAME_STRING`) and a family name from the generation table |
| `sm` | `sm_version_major * 10 + minor` (120 / 121) |
| `gpc_count`, `tpc_count` | `gpc_count`, `tpc_count` |
| `mp_per_tpc`, `max_warps_per_mp`, `max_blocks_per_mp` | **gap (#2439)**: `NV2080_CTRL_CMD_GR_GET_INFO` indices, or the generation table |
| `cls_gpfifo`, `cls_compute`, `cls_eng3d`, `cls_copy` | as is |
| `cls_eng2d`, `cls_m2mf`, `cls_vdec` | **gap (#2439)**: pick from `classes` (2D `FERMI_TWOD_A` 0x902d, I2M 0xcd40, NVDEC) in the generation table |
| `has_transfer_queue` | `cls_copy != 0` |
| `has_video` | false in V0/V1 |
| `nc_atom_size_B` | **gap (#2439)**: the host CPU cache line size, read at run time (note 6.3) |
| `vram_size_B` | `vram_size` |
| `bar_size_B` | `bar1_size` only where BAR mappings are known to be Normal memory; otherwise 0 (note 6.2) |
| `max_smem_per_wg_kB`, `sm_smem_sizes_kB[]` | **gap (#2439)**: generation table |
| `zcull_info` | **gap (#2439)**: `NV2080_CTRL_CMD_GR_GET_ZCULL_INFO`; `has_zcull_info = false` until then |

Without these gaps closed, NVK either refuses the device or computes wrong
limits.

**Memory heaps** (memory attribute rule): CPU mappings of BAR memory on the
Altra are Device-nGnRE, so unaligned CPU access traps. NVK copies into
host-visible maps with ordinary `memcpy`. So the backend reports VRAM as
device-local and **not host-visible**: no ReBAR-style heap. Host-visible memory
is sysmem only. On GB10 there is one heap, device-local and host-visible
(coherent over C2C).

Notes:

- **6.1 `type`.** `SOC` needs a positive signal: the GB10 architecture and
  implementation in the generation table, or an RM SoC/C2C flag. A discrete
  chip that reports 0 VRAM (for example because the FB query failed) is
  **refused**, rather than given the GB10 heap layout, since that layout would
  put host-visible maps on BAR memory. Fake test: the `discrete` profile with
  `vram_size = 0` must fail pdev creation.
- **6.2 `bar_size_B` and VRAM CPU maps fail closed.** The backend reports
  `bar1_size`, and allows `mem.map` of `NVRM_MEM_VRAM`, only when there is a
  positive signal that BAR mappings are Normal memory. Such a signal is a WC
  mapping on amd64, or a platform-table entry from the memory-attribute rule
  (`src/gb10-memattr/`) that says so. Without it, including when the
  attribute query fails or returns unknown, `bar_size_B` is 0 and VRAM
  `mem.map` returns `VK_ERROR_MEMORY_MAP_FAILED`. Fake tests: the `discrete`
  profile with `bar1_size == vram_size` gives no memory type with both
  `DEVICE_LOCAL` and `HOST_VISIBLE`, both with the Device-nGnRE attribute and
  with the attribute query made to fail.
- **6.3 `nc_atom_size_B`.** It is the flush granularity in `sync_to_gpu`: 64 on
  the Neoverse N1 cores of the Altra. On a coherent GB10 path it is not used
  for correctness.

## 7. Build layout (superseded by the fork)

Since the section 0 answer, the code and its build live in the private fork
`cloudbsdorg/mesa-cloudbsd`, branch `cloudbsd/26.3`:
- the root `Makefile` (purpose fork) and `cloudbsd/make.sh`, with the
  targets preflight, install-deps, configure, build, test and clean;
- `cloudbsd/tests/nvk-nvrm-probe.c`;
- the backend in `src/nouveau/vulkan/nvkmd/nvrm/`.

`make build NVRM_SRC=<a checkout of this repository>` builds libnvrm from its
`lib/libnvrm`, then NVK with `-Dvulkan-drivers=nvk -Dnvk-kmd=nvrm`, and
installs it into `WORK/prefix`. The installed library is
`libvulkan_nvk_nvrm.so`, and the ICD is `nvk_nvrm_icd.<arch>.json`;
`make configure` prints the full option list. With `NVRM_SRC` unset, the
default is `$HOME/work/gb10/nvidia-gb10-freebsd`, and the build stops with
"no libnvrm at ..." when that checkout has none. "Purpose fork" is the
project-makefile-contract term for a thin wrapper around an upstream build.
`make test` runs on the libnvrm fake backend.
This directory keeps only `DESIGN.md` and `JOURNAL.md`. The layout below was
the plan before the fork, kept for the record:

```
mesa/nvk-nvrm/
  Makefile    deps (root), fetch, verify, extract, patch, configure, build, test, clean
  SOURCES     Mesa version, URL, SHA256 (then the one source for the pin)
  patches/    the Mesa patch series (0001-...), pending the section 0 decision
  ci/         build against the libnvrm fake backend (NVRM_BACKEND=fake)
  testboot/   the kit rows and the nvk-nvrm-probe program (section 8)
  DESIGN.md, JOURNAL.md
```

The Makefile follows the project-makefile-contract skill. The meson line for
arm64 is `-Dvulkan-drivers=nvk -Dgallium-drivers= -Dplatforms=
-Dnvk-kmd=nvrm`. The last option is new: it chooses the nvrm backend. The dependencies are the
ones `graphics/mesa-devel` (#2309) already proved on arm64 (rust, bindgen,
libclc, spirv-tools, llvm).

Privilege split:

- Only a `deps` target installs packages with pkg. It needs root and says so.
- `extract` depends on `verify`, and it also re-checks the SHA256 of the
  distfile against `SOURCES` itself, so a file swapped after `verify` is
  caught. On a mismatch it exits non-zero and creates no extract directory.
  CI row: flip one byte in the distfile and run `make build`; it must fail
  with no extract directory.
- `fetch`, `verify`, `extract`, `patch`, `configure`, `build`, `test` and
  `clean` refuse to run when `id -u` is 0. So the Python and meson scripts of
  the downloaded tarball never run as root, and no root-owned files land in
  the build tree.
- Every path that `clean` removes is guarded with `${VAR:?}`.

Later, the series moves into `graphics/mesa-devel` as a `nvrm` option for
amd64 and arm64.

## 8. Test-boot rows (prepared; to run once the stub exists)

The nvidia driver is loaded only inside the test-boot kit, never on the build host.

Every row runs with the same environment:

- `VK_ICD_FILENAMES=<kit>/nvk_nvrm_icd.<arch>.json`, with `VK_LOADER_DRIVERS_SELECT`
  unset, so an installed NVIDIA ICD cannot answer in its place;
- `NVK_I_WANT_A_BROKEN_VULKAN_DRIVER=1`, because NVK hides devices it does not
  list as conformant, and a GB206 on this backend is not.

`kldstat -v` is recorded before and after each row. It lists the modules
inside each file, including the ones compiled into `kernel`.

| Row | Command (in the kit, self-recording) | Pass on hardware | Pass on the fake backend (CI) |
|---|---|---|---|
| nvk-nvrm-enum | `nvrm-info --json` | exit 0; one GPU; identity matches the hardware preflight (PCI address and UUID) | exit 0; profiles `discrete` (GB206-shaped) and `unified` (GB10-shaped) each list one GPU |
| nvk-nvrm-vulkaninfo | `vulkaninfo --summary` | one device with `driverID` `DRIVER_ID_MESA_NVK`; vendor, device ID and UUID equal the `nvrm-info --json` values from the row above | the same comparison against the fake `nvrm-info --json` |
| nvk-nvrm-device | `nvk-nvrm-probe` (planned in `testboot/`): prints `driverID`, then calls `vkCreateDevice` with one compute queue and prints the exact `VkResult` | `driverID == DRIVER_ID_MESA_NVK`, `VK_ERROR_FEATURE_NOT_PRESENT`, and stderr contains the literal stub line from section 3.3 | the same |
| nvk-nvrm-nolinux | the `kldstat -v` snapshots of the rows above | every snapshot exists, is not empty and lists `kernel` and `nvidia.ko`; no file name and no module name inside any file (including `kernel`) matches the patterns below | n/a; fixtures that must fail: a snapshot with `drm2.ko`, one with `lindebugfs.ko`, one whose `kernel` contains the module `linuxkpi`, an empty one, and one without `nvidia.ko` |

The nvk-nvrm-nolinux patterns, as extended regular expressions (copy them
from here, not from the table, where Markdown would need a pipe escape). For
file names:

```
^(linux.*|lin(sys|debug|proc)fs|.*drm.*)\.ko$
```

For module names inside a file, including `kernel`:

```
^(linux.*|lin(sys|debug|proc)fs|.*drm.*)$
```

`vkcube` is not used: the stub has no WSI platform, so it would fail at surface
creation before reaching the backend. The GPU is selected by `nvrm_enumerate()`
and the hardware-preflight-and-verify skill (by PCI address or UUID), never by
`/dev/nvidia0`.

## 9. Gaps and work packages

| Gap | WP |
|---|---|
| Device info fields NVK needs (section 6), the SoC signal | #2439 (S1 and S2 extensions) |
| PTE kind and compression on alloc; fixed-address and second CPU mapping; replace-first overmap; `mem_info.handle`; unmap by VA | #2439 |
| TSG, GPFIFO, USERD, engine objects, token, doorbell and both barriers, GP_GET tracking with the E - 2 batch bound, splitting and arrival order, progress-semaphore entry, the copy-engine question, mapped error notifiers, torn-free GPU timestamp, fake GPFIFO | **#2437** (libnvrm S3) |
| Verify the Blackwell host-class semaphore fields (64-bit payload, `ACQ_CIRC_GEQ`, any strict GEQ), the non-stall interrupt method after a release, the copy class on a graphics channel, and the chipset value against the NVK chipset table | #2437 (S3 spike) |
| Semaphore pool, per-export `NV_SEMAPHORE_SURFACE` syncs with the class check on import, per-(thread, device) event descriptors bound at device level, SET_TRIGGER wake, the fixed wait loop, CPU-side waits for imported syncs, CPU wait (spin then poll, kevent after `d_kqfilter`), device-loss events | **#2438** (libnvrm S4) |
| Check against `vk_queue.c` that the section 5 feature set selects immediate submit with no `vk_sync_timeline` emulation | #2379 |
| Re-pin S2: done at `4a745c7` (section 1) | #2379 |
| `mesa/nvk-nvrm/SOURCES` as the one source for the Mesa pin; section 1 then cites it | #2379 |
| The nvkmd nvrm backend itself, from stub to V1 | #2379, blocked on the section 0 decision |
| The existing agent-written `src/nouveau` patches in `graphics/mesa-devel` | #2309, the same section 0 decision |
| dma-buf import from other vendors, `SYNC_FD` | S6' (later) |
| Display (`VK_KHR_display`, WSI) | S8' / #2381 |

S5 (compute dispatch and the QMD builder) is **not** on the path to NVK. NVK
builds its own QMDs with NAK. S5 is for native CUDA (#2380).

## 10. Order of work to the first native llama.cpp Vulkan number on the RTX 5060 Ti

No durations or dates are given (Mark, 2026-11-22). The work goes in this
order, and each step has a gate:

| Step | Work | Gate before the next step |
|---|---|---|
| 1 | libnvrm S2, memory and VA (#2419) | done: merged at `4a745c7`, S2 rows of section 3 re-checked |
| 2 | libnvrm S1/S2 extensions for NVK (#2439), alongside S3 | fake-backend tests green |
| 3 | libnvrm S3, channels and submit (#2437), including the spike items of section 9 | NOP and semaphore release complete on the card in a test boot |
| 4 | libnvrm S4, the poll path (#2438) | a CPU wait wakes on a GPU release, fake and hardware |
| 5 | the nvkmd nvrm backend from stub to V1 compute, in the fork | dEQP compute subset on the fake backend, then in a test boot |
| 6 | bring-up on the card | `vulkaninfo --summary` lists the GPU; the dEQP compute subset passes in a test boot |
| 7 | the first native llama.cpp Vulkan number | `llama-bench` on the RTX 5060 Ti in a test boot, with no `linux*` module loaded |
| later | S4 kevent and `d_kqfilter` (#2438) | not needed for the first number |

Steps 1, 3 and 4 are the critical path. Step 2, and the parts of step 5 that
need no channels (enumeration, memory, VA and the sync type on the fake
backend), can run beside step 3. The rest of step 5 needs steps 3 and 4.

Two risks remain:

- The RM channel-setup details in the S3 spike (USERD placement, the token on
  user channels).
- NVK behaviour on GB206 with RM-placed memory (the PTE kinds behind
  `alloc_tiled_mem`). Compute-only llama.cpp paths need the tiled allocations
  only for images, so they can run before that gap closes.

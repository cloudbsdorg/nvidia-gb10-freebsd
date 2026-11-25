# nvidia-drm render uAPI (NVR), version 1.0

NVR is the ioctl interface that nvidia-drm offers to a user-space Vulkan driver: buffers, a
GPU address space the caller manages, queues and job submission. This file is the full
semantics; the layouts and numbers are in `src/nvidia-drm-render/nvidia-drm-render.h` and the
manual page is `nvidia_drm_render(4)` (`man/nvidia_drm_render.4`). Where the header and this
file disagree, the header's layout wins and this file is a defect to fix. Section 10 says
which kernel work package implements which part and what each must test.

"MUST", "MUST NOT", "SHOULD" are meant as in RFC 2119. "The kernel" is nvidia-drm.

## 1. Model

One DRM file (one open of `/dev/dri/renderD*` or `card*`) is one client. It owns:

- **one GPU VA space** (the file's VM), created by VM_INIT, destroyed when the file closes;
- **GEM buffer objects** (BOs), identified by ordinary DRM GEM handles; a BO is memory, not an
  address. Nothing is mapped into the VA space until VM_BIND does it;
- **channels**, each an in-order submission queue on one GPU engine;
- DRM **syncobjs** (core ioctls, not part of this uAPI) used to order binds and execs.

The VA space is managed by user space. The kernel owns one range inside it
(`kernel_managed`), where it places its own mappings (push buffer rings, semaphore surfaces,
channel state). Everything outside that range is the caller's.

All NVR ioctls are `DRM_RENDER_ALLOW`: they work on the render node and on the card node, with
no DRM master. They are `DRM_UNLOCKED` and safe to call from any number of threads on one fd
(section 9). Memory handed in by pointer is read and written with `copyin`/`copyout` semantics:
a bad pointer is `EFAULT`, never a panic.

### 1.1 Numbering

Command numbers are relative to `DRM_COMMAND_BASE` (0x40). Three sets are kept apart:

- nvidia-drm's own `DRM_NVIDIA_*` use 0x00-0x18 in driver 580.178.04 (0x07 unused) and NVIDIA
  adds new ones one at a time, so **0x19-0x3f** stay free for it;
- nouveau's driver ioctls are 0x00-0x13 and 0x40-0x44. NVR never uses 0x40-0x44, so a stale
  nouveau request code with a number in 0x40-0x44 reaches no NVR handler (a nouveau code in
  0x00-0x13 lands on a `DRM_NVIDIA_*` handler, which the DRM core does not stop; callers must
  check the driver name first, section 2);
- NVR takes **0x45-0x5f** (0x5f is the last number before `DRM_COMMAND_END`). It uses
  0x45-0x4f; **0x50-0x5f** are reserved for minor versions.

| Command | nr | ioctl (FreeBSD encoding) | Direction | Struct | Size |
|---|---|---|---|---|---|
| GETPARAM | 0x45 | 0xc0106485 | in/out | `drm_nvr_getparam` | 16 |
| GETINFO | 0x46 | 0xc0b06486 | in/out | `drm_nvr_getinfo` | 176 |
| CHANNEL_ALLOC | 0x47 | 0xc0586487 | in/out | `drm_nvr_channel_alloc` | 88 |
| CHANNEL_FREE | 0x48 | 0x80086488 | in | `drm_nvr_channel_free` | 8 |
| GEM_NEW | 0x49 | 0xc0306489 | in/out | `drm_nvr_gem_new` | 48 |
| GEM_INFO | 0x4a | 0xc028648a | in/out | `drm_nvr_gem_info` | 40 |
| GEM_CPU_PREP | 0x4b | 0x8008648b | in | `drm_nvr_gem_cpu_prep` | 8 |
| GEM_CPU_FINI | 0x4c | 0x8008648c | in | `drm_nvr_gem_cpu_fini` | 8 |
| VM_INIT | 0x4d | 0xc020648d | in/out | `drm_nvr_vm_init` | 32 |
| VM_BIND | 0x4e | 0xc028648e | in/out | `drm_nvr_vm_bind` | 40 |
| EXEC | 0x4f | 0xc028648f | in/out | `drm_nvr_exec` | 40 |

The request code is the FreeBSD encoding (`_IOWR` or `_IOW` per the Direction column, group
`'d'`, number `0x40 + nr`); a Linux build of the
same Mesa uses Linux's encoding of the same command numbers, which the Linuxulator translates.

Array element structures: `drm_nvr_class` (8), `drm_nvr_channel_obj` (8), `drm_nvr_sync` (16),
`drm_nvr_vm_bind_op` (40), `drm_nvr_exec_push` (16).

### 1.2 Rules for every structure

- Fixed-width types, no pointers (a user pointer is a `uint64_t`), no implicit padding.
- Every 64-bit member is at an offset divisible by 8 and every size is divisible by 8: the
  layout is the same for 32-bit and 64-bit callers, and there is no compat translation layer.
- **Pad, reserved and unknown-flag bits MUST be zero.** The kernel refuses anything else with
  `EINVAL`. This is what lets a later minor version give a pad bit a meaning.
- A released structure never changes. A new minor version adds GETPARAM values, flag bits that
  old callers leave zero, and new ioctl numbers in 0x50-0x5f.
- A count above its limit is `E2BIG`. A pointer with a non-zero count MUST be a readable (or,
  for an out array, writable) user range, else `EFAULT`; a pointer whose count is 0 MUST be 0,
  else `EINVAL`.

### 1.3 Errors

| errno | Meaning, in every ioctl unless an ioctl says otherwise |
|---|---|
| `EINVAL` | A value, flag, alignment or range rule was broken; non-zero pad or reserved bits; wrong state (for example no VM_INIT yet). |
| `E2BIG` | A count is above its limit (section 8). |
| `EFAULT` | A user pointer cannot be read or written. |
| `ENOENT` | A handle, channel id or mapping does not exist. |
| `EEXIST` | The range is already mapped (VM_BIND). |
| `EBUSY` | The object is in use (VM_INIT twice; sparse region still has mappings), or GEM_CPU_PREP with `NOWAIT` on a busy BO. |
| `ENOMEM` | Kernel, RM, video or page-table memory is exhausted. |
| `ENOSPC` | A per-file, per-credential or device-wide limit is reached (live or draining channels, channel ids, queued binds and jobs, reserved bytes, the kernel range). |
| `EPERM` | The operation is not allowed on this object (exporting a NO_SHARE BO). |
| `ENODEV` | The channel (or the whole GPU) is lost: section 6.4. |
| `EINTR` | A sleep was interrupted by a signal; nothing was changed. Retry the call. |
| `ECANCELED` | Not returned by an ioctl: the error a cancelled job's or bind's signal fences carry (CHANNEL_FREE, file close). |

An ioctl that fails changes nothing: no BO, no channel, no mapping, no syncobj. (EXEC and async
VM_BIND validate everything before they queue anything.)

## 2. Identity, version and limits

User space probes in this order:

1. `DRM_IOCTL_VERSION`: the driver name is `nvidia-drm` (not `nouveau`).
2. `GETPARAM(NVR_PARAM_UAPI_VERSION)`: returns `(major << 16) | minor`. An old nvidia-drm
   without NVR answers `EINVAL` or `ENOTTY` (DRM core behaviour for an unknown driver ioctl);
   callers treat both as "no NVR". The major version is 1. A caller refuses a major it does
   not know; a higher minor is fine.
3. `GETINFO`.

### 2.1 GETPARAM

`param` is an `NVR_PARAM_*` value, `value` is the result. An unknown `param` is `EINVAL`. All
values are snapshots.

| Param | Meaning |
|---|---|
| `UAPI_VERSION` (1) | `(major << 16) \| minor`. |
| `PCI_DEVICE` (2) | PCI device id. |
| `EXEC_PUSH_MAX` (3) | Largest `push_count` one EXEC accepts. Minimum: section 8. |
| `VRAM_SIZE` (4) | Usable video memory in bytes: what the RM reports as framebuffer size, not the BAR size. 0 with `NO_VRAM`. |
| `VRAM_BAR_SIZE` (5) | Size of the BAR1 aperture in bytes. 0 with `NO_VRAM`. |
| `VRAM_USED` (6) | Bytes of video memory held at this moment by **this DRM file's** BOs (rounded sizes). Other clients' allocations are never visible here. 0 with `NO_VRAM`. |
| `PTIMER_TIME` (7) | The GPU's global timer in nanoseconds, read from the RM at call time. Same clock as the timestamps a GPU semaphore release writes (section 6.5). |
| `GRAPH_UNITS` (8) | GPC count in bits 0-7, total TPC count in bits 8-23. |
| `HAS_VMA_TILEMODE` (9) | Always 1: `tile_mode` and `pte_kind` are accepted by GEM_NEW and VM_BIND. |
| `VA_BITS` (10) | Number of GPU virtual address bits. |
| `MAX_CHANNELS` (11) | Channels per DRM file, live or draining. Minimum: section 8. |
| `MAX_BIND_OPS` (12) | `op_count` limit of one VM_BIND. Minimum: section 8. |
| `MAX_SYNCS` (13) | `wait_count` and `sig_count` limit of one EXEC or VM_BIND. Minimum: section 8. |
| `PAGE_SIZES` (14) | Bitmask of the GPU page sizes in bytes (4 KiB, 64 KiB, 2 MiB are `0x1000`, `0x10000`, `0x200000`). |
| `FEATURES` (15) | The `NVR_INFO_FLAG_*` bits, as in GETINFO. |
| `VRAM_FREE` (16) | Free video memory on the GPU as the RM reports it, **rounded down to a multiple of 16 MiB**. It is device-wide and visible to every client of the render node: accepted parity with other drivers (Mesa's heap budget needs it), and the rounding only coarsens it. A hardened system may add a tunable that reports, to unprivileged files, only the device total minus their own `VRAM_USED`. `VRAM_USED` is the only per-file figure. 0 with `NO_VRAM`. |
| `VA_LIMIT` (17) | The first GPU address past the usable VA space (VM_INIT returns the same value). At most `1 << VA_BITS`; less when the RM reserves the top. |
| `KERNEL_VA_MIN_SIZE` (18) | The smallest `kernel_managed_size` VM_INIT accepts on this device: the larger of 16 MiB and `MAX_CHANNELS` times the kernel's per-channel placement, rounded up to 2 MiB. Minimum: section 8. |
| `MAX_QUEUED` (19) | Outstanding **unstarted** async VM_BINDs plus EXEC jobs per DRM file (those still waiting for a fence; running work does not count). Minimum: section 8. Beyond it an async VM_BIND or an EXEC is `ENOSPC`; a bind or job counts until it starts or is cancelled. |
| `MAX_RESERVED` (20) | Bytes of page-table and bookkeeping memory that the unstarted async binds of this file have reserved. Minimum: section 8. Beyond it an async VM_BIND is `ENOSPC`. The kernel also keeps a device-wide ceiling on the sum over all files, and a **per-credential** (per-uid) cap below it that counts every file the credential opened, so that one user opening many files cannot exhaust the ceiling for others; both give the same error. The same per-uid accounting covers `MAX_QUEUED` and the channels of section 3.1. |

### 2.2 GETINFO

One call returns what Mesa's `nv_device_info` needs: PCI identity, chipset, compute topology,
memory sizes, flags, the push limit, a device name and the class list.

- `chipset` is the RM's architecture value ORed with its implementation value (RM headers
  `NV2080_CTRL_MC_ARCH_INFO_*`): GB206 is `0x1b6`. 0x1b0 and above is the GB20x family, SM 12.x:
  GB202/203/205/206/207 and **GB20B (`0x1bb`), the GB10 SoC of the DGX Spark, SM 12.1**.
  0x1a0 to 0x1af is the datacenter GB10x family, SM 10.x. `sm_version` is
  `(major << 8) | minor` (`0x0c00` is SM 12.0, `0x0c01` is SM 12.1).
- `tpc_count` is the total over all GPCs; `GRAPH_UNITS` packs the same numbers. `mp_per_tpc`
  and `max_warps_per_mp` are the SM-count and warp numbers NVK's limits need. `exec_push_max`
  is the only limit in the struct; the others are GETPARAM values (the struct is frozen).
- `flags`:

| Flag | Meaning |
|---|---|
| `NO_VRAM` | Unified memory (GB10). `VRAM_SIZE`, `VRAM_BAR_SIZE` and `VRAM_USED` are 0 and every VRAM request becomes coherent system memory (section 4.2). |
| `CPU_COHERENT` | CPU caches are coherent with the GPU's access to system memory (the coherent link on GB10). Clear on a discrete card on a PCIe system where that was not established. |
| `BAR_DEVICE_MEM` | CPU mappings of video memory are Device-nGnRE: aligned, non-atomic accesses only (section 5.3). Set when the Altra rule is active. |
| `COMPRESSION` | Compressed PTE kinds are accepted. Never set with `NO_VRAM`. Clear when the GPU or the memory placement cannot do it. |

- **Class list.** `classes_ptr` is 0 exactly when `classes_cap` is 0 (the counting call), else it
  points at `classes_cap` `drm_nvr_class` entries (`EINVAL` for the mismatch).
  The kernel writes `min(classes_cap, classes_count)` entries and returns the **full** number
  in `classes_count`; user space calls twice (or with a large buffer). The list is the RM's
  class list for the device, each class with the engine that serves it, sorted by `engine`
  then by `class_id` ascending. It contains only classes a channel can use.
- Fields that have a GETPARAM twin (`va_bits`, `page_sizes`, `exec_push_max`, `vram_size`,
  `vram_bar_size`, `flags`/`FEATURES`) MUST be equal to it in the same state; a kernel that
  fills them from two sources is non-conforming.
- `name` is NUL-terminated and may be truncated.
- GETINFO does not depend on VM_INIT and is valid on any file.

## 3. Channels

### 3.1 CHANNEL_ALLOC

Allocates one queue on `engine` (`NVR_ENGINE_GR`, `_CE`, `_NVDEC`, `_NVENC`). `engine_instance`
is **1-based**: 0 means the driver chooses (round-robin over the copy engines), 1 to `ce_count`
picks that copy engine, and a larger value is `EINVAL`. For every engine other than `CE` it MUST
be 0 in version 1. `flags` MUST be 0.

- **Requires VM_INIT**; before it `EINVAL`.
- On success `channel` is the id and `objs[0..nr_obj-1]` lists the engine objects the kernel
  created and bound to subchannels: for `GR`, the 3D, compute, copy, inline-to-memory and 2D classes
  of the device (as in the class list; the copy class is the copy engine on the graphics
  runlist, because NVK writes copy methods into the graphics push), 5 of the `NVR_CHANNEL_OBJ_MAX` 8 slots; for `CE`, one copy class; for video engines, the engine
  class. `subchan` is the subchannel number a push buffer addresses the object on. The caller
  does not allocate objects itself: there is no NVIF and no per-object ioctl.
- An engine the GPU does not have is `EINVAL`. `MAX_CHANNELS` counts **live and draining**
  channels (a freed channel whose jobs have not ended still counts, section 3.2): one more is
  `ENOSPC`. RM exhaustion (no TSG, no channel) is `ENOMEM`.
- A channel id is **never reused within the lifetime of the DRM file**. A stale id therefore
  never names a different channel. The kernel counts ids with a 64-bit counter and, when the
  32-bit id space is used up (after 2^32 allocations in one file), CHANNEL_ALLOC returns
  `ENOSPC` for the rest of the file's life; the id never wraps.
- Channels of one file may be created and used on separate threads.

### 3.2 CHANNEL_FREE

Invalidates the id at once: a later EXEC or CHANNEL_FREE with it is `ENOENT`. The channel is
**draining** from then on, and counts against `MAX_CHANNELS` until it is gone. Jobs that are
running are not interrupted; they finish, fail or time out (section 6.4). **Every job that has not been handed to the hardware**, whether it waits for a fence or only
for the jobs ahead of it on the channel, is cancelled: their signals complete with
`ECANCELED` and what they reserved is released (nothing has touched the hardware). When no job
is left the kernel destroys the channel in the RM (the TSG is torn down and the RM confirms it
idle or gone) **and only then** releases the channel's placements in the kernel range and its
other memory (section 6.5). The call does not block on the GPU. Closing the file does the same
for every channel, then frees every BO, mapping and the VM.

## 4. Buffers

### 4.1 GEM_NEW and GEM_INFO

GEM_NEW creates a BO and returns a GEM handle (the same handle space as every DRM GEM handle,
closed with `DRM_IOCTL_GEM_CLOSE`, exported with the DRM PRIME ioctls). It does **not** need
VM_INIT, and gives the BO no GPU address. GEM_INFO returns the same `drm_nvr_gem_info` for an
existing handle (`ENOENT` for an unknown one); `flags` and `pad` MUST be 0 on GEM_INFO too (`EINVAL`), so a later minor version can give them a meaning on both calls.

In `drm_nvr_gem_info` (for GEM_NEW the `info` member of `drm_nvr_gem_new`):

| Member | GEM_NEW in | GEM_INFO in | Out (both) |
|---|---|---|---|
| `handle` | ignored | the handle to query | the GEM handle |
| `domain` | requested placement | ignored | the placement made |
| `size` | requested bytes, not 0 | ignored | bytes after rounding up to the device page granule (at least 4 KiB) |
| `map_handle` | ignored | ignored | the mmap offset on the DRM fd; 0 if the BO is not MAPPABLE |
| `tile_mode` | stored | ignored | the stored value |
| `pte_kind` | validated, stored | ignored | the stored value |
| `flags`, `pad` | MUST be 0 | MUST be 0 | 0 |

and in `drm_nvr_gem_new`, `align` is the placement alignment in bytes: a power of two from 4 KiB
to 2 MiB, or 0 meaning 4 KiB. Anything else (1, 2048, 4 MiB) is `EINVAL`. `size` 0 is `EINVAL`. The size limit is checked
**before** rounding: a `size` above the device maximum, or above `UINT64_MAX` minus the rounding
granule, is `ENOMEM`, so the rounded size can never wrap (`size = 2^64 - 1` creates no BO).

**Contents of a new BO.** GEM_NEW returns memory that reads as **zero** through the CPU
mapping and through the GPU. Memory last owned by another file, by the kernel or by another
driver MUST be scrubbed before it is handed out (video memory by an RM scrub or a copy-engine
clear before the handle is returned, system memory by zeroed pages); this is zero on allocate,
not scrub on free, so it also covers memory the RM recycled itself.

### 4.2 Domains, tile mode, PTE kind

`domain` is a mask of `VRAM`, `GART`, `MAPPABLE`, `COHERENT`, `NO_SHARE`; any other bit is
`EINVAL`. The rules:

- Exactly the placement bits `VRAM` and `GART` select where the memory lives. At least one MUST
  be set (else `EINVAL`). With both, the kernel chooses (video memory first, system memory when
  video memory is short); the answer is in the returned `domain`. The placement is **fixed for
  the life of the BO**: there is no migration in version 1.
- `VRAM` on a device with `NO_VRAM` is placed in coherent system memory: the returned domain has
  `GART | COHERENT` and no `VRAM`. It is not an error; the caller reads the returned domain.
- `MAPPABLE` makes the BO mmap-able through `map_handle`. For `VRAM` it means the pages come
  from the CPU-visible (BAR1) part of video memory, which is limited: `ENOMEM` when it is
  exhausted, even if video memory is free.
- `COHERENT` with `VRAM` and without `GART` on a device that has video memory is `EINVAL` (a
  silent downgrade would hide the BAR mapping it gets); with `GART` in the request, or on a
  `NO_VRAM` device, it is satisfiable. It means CPU writes need no cache maintenance to be seen
  by the GPU and the reverse. How it is achieved is a property of the mapping (section 5.2).
  It applies to the placement **made**: it is kept when the BO lands in system memory (also
  when a `VRAM|GART|COHERENT` request falls back to system memory) and cleared when it lands in
  video memory.
- **`NO_SHARE`**: the BO is private to this file. **Every** way of giving it to another client
  is `EPERM`: a PRIME export and `DRM_IOCTL_GEM_FLINK` alike (and a guessed flink name never
  opens it). An import never yields one. The kernel MAY give such a BO a reservation shared with the VM, so
  its fences are not visible to other files.
- **`tile_mode`** is never interpreted on GB10x and GB20x. Block-linear layout is chosen by user
  space (Mesa's `nil`); the GPU's MMU takes only the PTE kind. The value is stored and returned
  so a second process importing the BO through GEM_INFO can read the layout, and it must be
  the same in every GEM_INFO after.
- **`pte_kind`** is checked against the device's kind table. `NVR_PTE_KIND_PITCH` (0x00) and
  `NVR_PTE_KIND_GENERIC_MEMORY` (0x06) are valid on every supported device. A compressed kind
  is valid only with `NVR_INFO_FLAG_COMPRESSION` and only for a `VRAM` BO; otherwise it is
  `EINVAL`. `COMPRESSION` is never set together with `NO_VRAM`, so on a unified-memory device
  every compressed kind is `EINVAL`, even though a `VRAM` request is otherwise placed in system
  memory. A compressed kind **forces video memory placement**: with `VRAM|GART` the
  system-memory fallback is not taken and the call is `ENOMEM` when video memory is short.
  An unknown kind is `EINVAL`. Kinds that are valid only on pre-TU10x GPUs (`GENERIC_16BX2`,
  0xfe) are `EINVAL`: no supported device has them. VM_BIND's `pte_kind` check uses the
  placement actually made.

### 4.3 mmap

`mmap(2)` on the DRM fd at `map_handle`, for up to `size` bytes, `PROT_READ|PROT_WRITE`, `MAP_SHARED`.
`map_handle` is unique per BO per DRM device, and an mmap succeeds **only on a file that
holds a GEM handle to that BO** (it created or imported it); on any other file it is
`EACCES`, so guessing another client's offset reaches nothing. `map_handle` is 0 when the BO is not
MAPPABLE (an mmap at offset 0 is not a BO mapping and fails). The offset is page aligned; a mapping may cover
part of the BO, but the mapped range MUST lie inside one BO, checked without an
unchecked sum: `offset >= map_handle`, `offset - map_handle < size` and
`length <= size - (offset - map_handle)`: anything else is `EINVAL`, and no page outside the BO is ever
mapped (a length of `size + 4 KiB`, or a start near the end with a length past it, both fail). The mapping stays valid until `munmap`, even after GEM_CLOSE. The attribute of
the mapping is fixed by the BO's placement, never chosen by the caller (section 5).

### 4.4 GEM_CPU_PREP and GEM_CPU_FINI

CPU_PREP waits until the GPU has finished every job that uses the BO as the caller's access
needs: `WRITE` waits for readers and writers, otherwise writers. `NOWAIT` returns `EBUSY`
instead of waiting. It sleeps interruptibly (`EINTR`). If a fence it waited on completed with
an error (a faulted job, section 6.4) it returns `ENODEV`: the GPU is finished with the BO but
its contents are unspecified, so rewrite or discard them. The error is a property of that wait,
not a flag on the BO: a fault is also reported by the job's own signal fences and by the lost
channel, and a caller that must know about every fault watches those. 0 means the GPU is no
longer using the BO.

CPU_FINI ends the CPU access window; on a platform with non-coherent caches it flushes the
CPU's writes to the BO (a no-op on `CPU_COHERENT` and on non-cacheable mappings). Both calls
are optional for a `COHERENT` BO that the caller already fenced, and they are the way to wait
for the fences of an imported or exported BO (implicit sync). Unknown flags are `EINVAL`.

## 5. The memory attribute rule for CPU mappings (Altra and arm64)

This is the contract between the kernel and `src/gb10-memattr/gb10_memattr.h`. The attribute of
a user mapping depends only on **what the pages are**, never on what the caller would like:

### 5.1 Two kinds of pages

- **Video memory through BAR1** (`VRAM|MAPPABLE`): the pages are a PCIe BAR. A BAR is never
  cacheable on arm64. The mapping is `gb10_bar_memattr()`: write-combining requests become
  Normal non-cacheable, **except on Ampere Altra and Altra Max**, where Normal accesses to
  PCIe BARs are not safe (the root complex mishandles some of them) and the mapping is **Device-nGnRE**. GETINFO reports it
  as `BAR_DEVICE_MEM`.
- **System memory** (`GART`, and `VRAM` on `NO_VRAM`): the pages are managed RAM. The mapping
  is `gb10_ram_memattr()`: Normal write-back for a `COHERENT` BO on a `CPU_COHERENT` device,
  otherwise Normal non-cacheable (write-combining). **A BAR attribute MUST NEVER be applied to
  a RAM page, and a RAM attribute never to a BAR**: `pmap` rewrites the page's direct-map alias,
  and a Device attribute left on a RAM page makes every later unaligned kernel access to it
  fault. The kernel decides by walking the BO's pages with the
  `gb10_range_class()` classification and refuses a mixed range.

### 5.2 COHERENT

`COHERENT` on a system-memory BO is `CPU_COHERENT` -> write-back, otherwise non-cacheable. In
both cases a CPU write is visible to the GPU after a store barrier, and a GPU write is visible
to the CPU after the CPU waited for the job (CPU_PREP or a fence). `COHERENT` never selects a
cacheable mapping on a system where the GPU's access does not snoop the CPU caches.

### 5.3 What the caller MUST do under `BAR_DEVICE_MEM`

Device-nGnRE memory faults on unaligned access and on exclusive and atomic read-modify-write
instructions. So with `BAR_DEVICE_MEM`:

- copy to or from a mapped video memory BO with naturally aligned accesses only (4-byte or
  8-byte, no `ldp`/`stp` crossing alignment, no `dc zva`, no libc `memcpy` unless it is known to
  align);
- never use atomics on it (CPU atomics on GPU-visible memory belong in system-memory BOs);
- reads are slow and are not combined; stage in system memory.

Mesa's backend takes this flag as "use the aligned copy path", and, because applications
`memcpy` into mapped pointers, it MUST NOT expose host-visible device-local memory types when
the flag is set (section 11). Without the flag the mapping is
Normal non-cacheable and the usual rules for write-combining memory apply (a store barrier
before the GPU may read it). In either case **EXEC itself issues a store barrier** (`dsb st` on arm64)
before it publishes work, which covers the submitting thread's stores. A store done by another
thread needs that thread's own barrier before the hand-off.

### 5.4 Other rules

- A mapping is never upgraded: `mprotect` cannot add write to a read-only mapping the kernel
  made read-only, and no flag changes the attribute.
- PRIME-imported foreign system-memory BOs follow 5.1 for system memory; they are not NVR BOs
  and have no `map_handle` from this uAPI.

## 6. VM and execution

### 6.1 VM_INIT

`kernel_managed_addr` and `kernel_managed_size` choose the range the kernel keeps for itself.

- MUST be called once, **before the first CHANNEL_ALLOC or VM_BIND** (both are `EINVAL` before
  it). A second call is `EBUSY`. (GEM_NEW and GETINFO work without it.)
- `kernel_managed_addr` MUST be a multiple of 2 MiB; `kernel_managed_size` MUST be a multiple of
  2 MiB and at least `KERNEL_VA_MIN_SIZE` (GETPARAM; never below 16 MiB). The range MUST be inside
  the VA space **without computing an end that can wrap**: `kernel_managed_addr <= va_limit` and
  `kernel_managed_size <= va_limit - kernel_managed_addr`, with `va_limit` from `VA_LIMIT`.
  `EINVAL` otherwise (addresses with bit 63 set, or a range that would wrap, are refused).
- Out: `va_limit`, the same as `NVR_PARAM_VA_LIMIT`.
- **How much of the range the kernel uses:** the kernel places every one of its own mappings
  only inside this range, and a range of at least `KERNEL_VA_MIN_SIZE` is always enough for
  `MAX_CHANNELS` channels (that is what the parameter means; when the range is full, which a
  conforming caller never causes, CHANNEL_ALLOC is `ENOSPC`).
  User space may not bind inside it (`EINVAL`), may not read or write it from the GPU
  (a push buffer in it is `EINVAL`), and never learns an address in it. The range is
  fixed at VM_INIT and cannot move.
- **What may live in the kernel range.** The GPU channels of the file run in this same VA space,
  and the caller chose the range's base and size, so GPU work can aim at any address in it.
  Therefore **nothing in the kernel range is reachable by user work**: page tables, instance
  blocks, channel control state, the GPFIFO ring **and the job-end semaphore surface** MUST be in
  RM-internal memory or mapped with the privileged attribute that user engine work cannot
  access, never as ordinary PTEs of the client's VA space. A push buffer that is located in the
  range is `EINVAL` (a fetch address is checked at EXEC); GPU work that reads or writes into the
  range faults, and the fault kills that channel (section 6.4).

### 6.2 VM_BIND

A VM_BIND is a list of operations (`op_ptr`, `op_count` of 1 to `MAX_BIND_OPS`) on the file's VA
space. `flags` is 0 (synchronous) or `NVR_VM_BIND_RUN_ASYNC`. Without VM_INIT it is `EINVAL`.

**Addresses, alignments, ranges:**

- `op_count` MUST be at least 1 (`EINVAL` for 0). `range` MUST be non-zero. `addr + range` MUST
  NOT wrap and MUST be at most `va_limit` (checked as `addr <= va_limit` and
  `range <= va_limit - addr`).
  The span MUST lie outside the kernel range (`EINVAL` for any overlap).
- `addr`, `bo_offset` and `range` are multiples of 4 KiB (`NVR_PAGE_ALIGN`). For a sparse
  region (`NVR_VM_BIND_SPARSE`) `addr` and `range` are multiples of 64 KiB (`NVR_SPARSE_ALIGN`).
- The kernel picks the GPU page size per mapping: the largest of 2 MiB, 64 KiB, 4 KiB for which
  `addr`, `bo_offset` and `range` are aligned and the BO's backing is suitable. Alignment is
  never an error beyond 4 KiB; it only changes the page size. `PAGE_SIZES` lists the sizes.

**MAP** (`op = NVR_VM_BIND_OP_MAP`, no `SPARSE`): maps `range` bytes of the BO `handle` from
`bo_offset` at `addr`. `bo_offset` MUST be below the BO's size and `range` at most the size minus `bo_offset`
(`EINVAL`; the check is a subtraction, never `bo_offset + range`, which can wrap: `bo_offset =
2^64 - 4096` with `range = 8192` is refused). `handle` MUST be a BO of this file (`ENOENT`). A BO that was **imported** from another driver
(PRIME) can be mapped too, but only as `NVR_PTE_KIND_PITCH` or `NVR_PTE_KIND_GENERIC_MEMORY`
(any other kind, with or without `NVR_VM_BIND_PTE_KIND`, is `EINVAL`) and it is system memory
for section 5.1 purposes. `pte_kind` is 0 and the BO's kind is used, unless `NVR_VM_BIND_PTE_KIND`
is set, in which case the op's `pte_kind` is used (validated like GEM_NEW's, section 4.2). A
compressed `pte_kind` is accepted here only for a BO that was **created with a compressed
kind**, because only that BO has compression backing; for any other BO it is `EINVAL`.
Overlap rules:

- the span MUST be entirely free, **or** entirely inside one sparse region (it then replaces
  the sparse backing and any mappings for that span);
- outside a sparse region it overlaps an existing memory mapping: `EEXIST` (no implicit remap;
  unmap first). A MAP inside a sparse region replaces any memory mappings in its span
  atomically (a rebind of already bound pages succeeds);
- it straddles the edge of a sparse region, or covers a region and free space: `EINVAL`.

**MAP with `SPARSE`**: creates a sparse region over the span. `handle` and `bo_offset` MUST be 0.
Reads of a not-backed part return zero and writes to it are discarded; neither faults. The span
MUST be entirely free (`EEXIST` if anything is mapped, `EINVAL` if it overlaps another region).

**UNMAP** (`op = NVR_VM_BIND_OP_UNMAP`, no `SPARSE`): `handle`, `bo_offset` and `pte_kind` MUST be
0. UNMAP treats holes as no-ops: a span that is partly or wholly unmapped, or was never bound,
succeeds and unmaps only what is mapped (unbinding is idempotent).
**Partial unmap is allowed**: a mapping that is cut keeps its remaining pieces, which stay
mapped at their addresses with their `bo_offset` adjusted (by subtraction and addition of
values already known to be inside the old mapping, never by an unchecked sum); one UNMAP may cover several adjacent
mappings. The cut points are 4 KiB aligned (the same rule as above). Inside a sparse region
the unmapped part reverts to sparse backing; outside it becomes unmapped. Because a cut may need
page tables to be split, it can fail with `ENOMEM`, and that is reported by the call (section 6.2.2).

**UNMAP with `SPARSE`**: removes a sparse region. The span MUST be exactly one region
(`addr` and `range` equal; `ENOENT` if there is none, `EINVAL` if different; Mesa unmaps the
whole VA first, so a sparse region normally has no mapping left) and MUST contain no
memory mapping (`EBUSY`): unmap those first.

#### 6.2.1 Atomicity and validation

The operations of one call are validated in order against the VA state **as it would be after
the earlier operations of the same call and after every earlier call that has been accepted**
(synchronous or asynchronous). If any operation is invalid the call fails and **none** is
applied. VM_BIND calls on one file are serialised (section 9).

#### 6.2.2 Synchronous and asynchronous

- **Synchronous** (`flags == 0`): `wait_count`, `sig_count`, `wait_ptr`, `sig_ptr` MUST all be 0
  (`EINVAL` otherwise).
  The call takes the VM lock and looks at the bind queue. If the queue is not empty it drops
  the lock, waits **without holding it** for the queue to drain (an `EINTR` while waiting
  changes nothing), and starts again. It validates and applies only while holding the lock
  **and having seen the queue empty under that lock**, so no async bind can be accepted between
  the drain and the apply: another thread's bind is accepted either wholly before (and has run)
  or wholly after this one. It returns when the GPU page tables are updated. An async bind
  holds a reference to the BO it maps from acceptance until it ran or was cancelled, so a
  GEM_CLOSE cannot free the BO under a queued MAP. After it returns, any EXEC the
  caller submits sees the result.
- **Asynchronous** (`RUN_ASYNC`): the page-table update runs later, on the file's single
  **bind queue**. The queue is in-order: binds execute in the order the calls were accepted,
  one call's operations as a unit, and a bind never overtakes an earlier one. Each `wait`
  entry's `flags` MUST be `NVR_SYNC_SYNCOBJ` or `NVR_SYNC_TIMELINE_SYNCOBJ` (any other type or
  any bit outside `NVR_SYNC_TYPE_MASK` is `EINVAL`, in VM_BIND and EXEC alike), and its syncobj MUST already hold a fence (a binary syncobj with a fence; a timeline point that has
  been submitted), otherwise `EINVAL`: there is no wait-before-submit. The bind starts only
  after **all** its waits have signalled. When it has finished, every `sig` syncobj is
  signalled (binary: gets the bind's fence; timeline: the point `timeline_value`, which MUST be
  greater than the highest point already submitted for that syncobj, else `EINVAL`).
  A wait whose fence completed **with an error** does not stop the bind: the bind is still
  applied (the VA tracker, 6.2.1, has already counted it, so skipping it would make that state
  wrong) but the **first wait error is put on its `sig` fences**, so a job waiting on them
  fails too and an upstream failure is never turned into success by passing through a bind.
  A call with `sig_count == 0` is legal and fire-and-forget; a later synchronous bind waits for
  it. A bind whose waits never signal blocks the bind queue of **its own file** (and counts against its credential's caps) only; closing
  the file cancels it (`ECANCELED` signals, reservations released), see section 9.
- **Failure.** Everything that can fail for lack of memory is **reserved at the time of the call**
  (page-table memory included), so `ENOMEM` is reported by the call and never later. After
  acceptance a bind ends in one of three ways: it ran (signals clean, or carrying the first wait error), the GPU was lost (its
  `sig` fences complete with `ENODEV`, section 6.4), or the file was closed before it ran
  (`ECANCELED`, section 9). Reservations are bounded twice: by count (`MAX_QUEUED` unstarted
  binds and jobs per file) and by bytes (`MAX_RESERVED` per file and a device-wide ceiling),
  each giving `ENOSPC`, so no file or set of files can pin the device's memory by queueing
  work behind a fence that never signals; a few huge binds are limited as firmly as many small
  ones.
- An async bind does not wait for jobs that already use the range. An UNMAP while a job
  still runs is the caller's race: the GPU may fault, which kills the context
  (section 6.4). The kernel guarantees only its own safety: the BO's memory is not freed or
  reused while the unmap has not completed on the GPU.

### 6.3 EXEC

Submits one job to one channel: `push_count` push buffer ranges in the GPU VA space, run in
order, then the job completes.

- `channel` MUST be live, else `ENOENT`. `push_count` is 0 to `EXEC_PUSH_MAX`, `wait_count` and
  `sig_count` 0 to `MAX_SYNCS` (`E2BIG` above).
- Each push: `va` is a multiple of 4, `va_len` is a non-zero multiple of 4, the whole range MUST
  be mapped (checked at the call, against every bind accepted so far, `EINVAL` if not) and MUST
  lie outside the kernel range. `va_len` is at most `NVR_EXEC_PUSH_LEN_MAX` (8 MiB - 4 bytes, the
  longest push a GPFIFO entry's 21-bit dword length can carry; a longer push is `EINVAL`, never split), and the range is checked
  without a sum that can wrap: `va <= va_limit` and `va_len <= va_limit - va`.
  `flags` is 0 or `NVR_EXEC_PUSH_NO_PREFETCH`, which makes the GPFIFO entry wait: the GPU
  fetches that push only after every earlier entry of the channel has finished, so the push may
  have been written by an earlier push of the same channel. The kernel
  writes one GPFIFO entry per push, rings the channel's doorbell, and ends the job with a
  semaphore release that completes the job's fence.
- **Waits and signals.** As in VM_BIND async: each wait MUST already hold a fence, else `EINVAL`.
  The job starts only after every wait has signalled; waits on syncobjs signalled with an error
  make the job fail without running: its signal fences complete with that error. The channel is
  **not** lost by that, the jobs behind it run normally, and the job leaves the `MAX_QUEUED`
  count. Signals are set
  when the job completes; timeline points must exceed the highest point already submitted.
  They are attached **before** the call returns, so a following EXEC or VM_BIND may wait for
  them.
- **Queue cap.** An EXEC that would exceed `MAX_QUEUED` unstarted jobs and binds is `ENOSPC`
  (section 6.2.2).
- **EXEC can block.** If the channel's ring is full the call sleeps interruptibly until there is
  room (`EINTR` if a signal arrives first; nothing was submitted). It never returns `EBUSY`
  for a full ring.
- **Atomic:** on any error nothing was queued and no syncobj changed.
- **Ordering:** jobs on **one channel** execute in the order their EXEC
  calls were accepted and never overlap. Jobs on **different channels** have no order unless
  a syncobj creates one. EXEC does **not** wait for earlier asynchronous VM_BINDs: a bind
  and an exec sharing a VA range are ordered only by the syncobj the bind signals and the exec
  waits for (or by a synchronous bind before the EXEC). Two threads calling EXEC on one channel
  get the order in which the kernel's per-channel lock grants them; the call is
  atomic as a whole job.
- **Liveness probe.** EXEC with `push_count`, `wait_count` and `sig_count` all 0 does no work: it
  returns 0 if the channel is alive and `ENODEV` if it is lost (the nouveau backend does the same with an
  empty GEM_PUSHBUF). It is allowed on every live or lost channel; for a freed channel it is
  `ENOENT`.

### 6.4 Device loss and timeouts

Which error shows where:

- **Errors the call can see are returned by the call**: bad arguments, bad handles, unmapped
  push range, exhausted memory, a channel that is already lost (`ENODEV`).
- **Errors that happen while the GPU runs are never returned by the call that submitted the
  job**: they mark the **channel lost**. The failed job's signal fences, and the signal fences
  of every job queued behind it on that channel, complete with error `ENODEV`. The next EXEC on
  that channel (even the empty liveness probe) returns `ENODEV`. A lost channel stays lost; the
  only valid calls on it are CHANNEL_FREE and the liveness probe. The caller makes a new channel.
- What kills a channel: an RM channel error (a push buffer decode error, an invalid method,
  a GPU MMU fault on an address the job used, a semaphore or fence error), a job that
  does not complete within the **job timeout** (at least 10 seconds; the kernel may be
  configured longer, never shorter), and an RM-reported reset of the engine the channel used. Recovery from a timeout or a fault
  MUST be **per channel** (the RM removes only the offending TSG). Killing a channel does
  **not** affect other channels of the same file or of other files, the VM and its mappings, or
  BOs. Only if the RM can recover solely by resetting a whole engine, every channel on that
  engine is lost the same way (like the whole-GPU case below), the kernel MUST first try to
  preserve and resubmit the other TSGs, and a client that spins until each timeout must not be
  able to keep killing others: the kernel throttles recovery per credential.
- **Whole-GPU loss** (the RM reports a GPU reset or a fatal error): every channel on the device is
  lost at once, in every file. GETPARAM, GETINFO and GEM_* keep working. EXEC, CHANNEL_ALLOC
  and **VM_BIND return `ENODEV`**: the VM of every file is poisoned, because an accepted async
  bind that did not run leaves the VA tracker and the page tables apart (a retried MAP would be
  `EEXIST` on a hole). A poisoned VM stays poisoned; the caller opens the device again. Closing
  the file is always safe. The DRM core `ENODEV`-after-unplug rules are unchanged.
- A lost channel's push buffers and BOs are not touched; contents written by the failed job
  are unspecified.

### 6.5 Fences, timestamps and memory reuse

A job's fence is a DRM fence completed from a semaphore release on the channel's semaphore
surface, or from the RM's own channel progress. The surface is in the kernel range and out of
user reach (section 6.1), so a user push cannot complete a fence early. A fence that leaves
the file (attached to a syncobj another process can wait on, or to the reservation of a shared
or imported BO, for implicit sync) MUST complete only from that kernel-trusted source, never
from memory user work can write. `PTIMER_TIME` is on the same time base as the timestamp a
release writes. Nothing else of the surface is visible to user space.

Memory reuse does not rely on fences alone, as a second line of defence:

- Two kinds of memory are never released for reuse by **any other file** on the strength of a
  fence only: (a) a BO's backing store whose last mapping was removed, and the page tables an
  unmap freed; (b) everything the kernel placed in its range for a channel or the VM, and the
  channel's own backing memory.
- They are released only after the RM reports the channels of this VM idle, or after it has
  destroyed them (CHANNEL_FREE and file close destroy the TSG first, then free; section 3.2),
  **and after the GPU's translation caches were invalidated** for every removed mapping and the
  invalidation completed: a stale TLB entry must never outlive the page it names.
- A semaphore or fence error reported by the RM kills the channel (section 6.4).

## 7. What differs from nouveau

For whoever forks the Mesa backend:

| nouveau | NVR |
|---|---|
| name `nouveau`, version 1.3.1+ | name `nvidia-drm`, `NVR_PARAM_UAPI_VERSION` |
| `DRM_NOUVEAU_NVIF` for device info and classes | `GETINFO` (one struct, class list included) |
| user allocates engine objects with NVIF | `CHANNEL_ALLOC` returns the objects (`objs[]`) |
| `GETPARAM` with kernel-chosen param numbers | own numbers (section 2.1), more of them |
| `GEM_NEW` carries `channel_hint`, `info.offset` | neither; `align` is explicit; `pte_kind` is its own member, not `tile_flags >> 8` |
| PTE kind from the BO only | `NVR_VM_BIND_PTE_KIND` overrides it per mapping |
| no UNMAP rules documented | partial unmap defined (section 6.2) |
| `VM_INIT` after a BO is `ENOSYS` | `VM_INIT` is only required before channels and binds; second call `EBUSY` |
| `SVM_*`, `GROBJ_ALLOC`, `SETPARAM`, `GET_ZCULL_INFO`, `GEM_PUSHBUF` | absent: an ioctl number not listed is not implemented. Zcull info is optional in Mesa and its failure is tolerated; add as a minor version if needed |
| liveness by an empty `GEM_PUSHBUF` | liveness by an empty `EXEC` |
| `NO_SHARE`: never shared via import or export (header comment) | the same, and FLINK too is `EPERM` |
| `DRM_NOUVEAU_SYNC_*` | `NVR_SYNC_*`, same values and layout |

## 8. Limits

Minimums: a device may raise them and says so through GETPARAM; it never goes below them. The
header names them with the suffix `_MIN`.

| Limit | Guaranteed minimum | GETPARAM |
|---|---|---|
| pushes per EXEC | 256 | `EXEC_PUSH_MAX` |
| wait or signal entries per EXEC or VM_BIND | 128 | `MAX_SYNCS` |
| operations per VM_BIND | 1024 | `MAX_BIND_OPS` |
| channels per DRM file, live or draining | 32 | `MAX_CHANNELS` |
| unstarted async binds and jobs per DRM file | 1024 | `MAX_QUEUED` |
| reserved page-table bytes per DRM file | 64 MiB | `MAX_RESERVED` |
| VM_INIT kernel range | 16 MiB | `KERNEL_VA_MIN_SIZE` |

Fixed values and maxima: no device changes these.

| Value | Fixed at | Where |
|---|---|---|
| subchannel objects per channel | 8 | `objs[]` length |
| device name length in bytes | 64 | `name[]` length |
| smallest alignment of addr, bo_offset, range | 4 KiB | section 6.2 |
| sparse region alignment | 64 KiB | section 6.2 |
| VM_INIT alignment | 2 MiB | section 6.1 |
| largest GEM_NEW align | 2 MiB (maximum) | section 4.1 |
| largest push in bytes (va_len) | 8388604 (8 MiB - 4, a GPFIFO entry's 21-bit dword length) | section 6.3 |

## 9. Concurrency and lifetime

- **Per file:** every ioctl may be called from any number of threads at once. The kernel
  serialises per object: VM_INIT, VM_BIND and the VA tracker under one VM lock (so VM_BIND calls on
  a file are totally ordered, in the order they obtain the lock); each channel's EXEC under a
  per-channel lock; GEM operations per BO. Different files share nothing but the GPU and the
  device-wide pools of section 6.2.2, which per-credential caps protect.
- A blocked EXEC (full ring) does not hold the VM lock, and a VM_BIND that is waiting for its
  syncobjs holds no lock either: it takes the VM lock only to update the VA tracker and queue.
- **Lifetimes.** BO: until GEM_CLOSE (or file close) **and** all mappings and jobs that use it
  have ended; a mmap keeps it alive. Mapping: until UNMAP or file close. Channel id: from
  CHANNEL_ALLOC to CHANNEL_FREE (id dead) or file close; the channel's resources live until the
  RM has destroyed it (section 3.2). VM: until file close, after all channels were torn down.
- **Closing the DRM file** returns in bounded time and is always safe. Jobs and binds that have
  not started are cancelled (`ECANCELED` signals, reservations released), including those
  waiting on a fence that never signals (for example a foreign fence imported into a syncobj);
  running jobs are stopped by destroying their channels in the RM; only then is memory freed
  (section 6.5).
- **fork** and descriptors: a DRM file shared by `fork` or `dup` is one client; threads of the
  child and the parent race exactly as threads of one process. A BO mapping is not inherited
  across `exec`.
- **Signals:** an ioctl that sleeps (EXEC with a full ring, CPU_PREP, synchronous VM_BIND
  waiting for the queue) returns `EINTR` and has changed nothing; the caller retries.

## 10. Conformance list (what each kernel work package must satisfy)

The plan this contract belongs to is `docs/NATIVE-NVIDIA-RENDERING.md` (§11 lists the work
packages N3-N9 named below; N9 is the Mesa backend). The design study's §3.5 lists behaviours
that only the Linux nouveau code shows; this file defines each of them for NVR, so nobody needs
that code: VM_BIND edge cases in 6.2, EXEC ordering and errors in 6.3 and 6.4, GEM domains, tile
mode and kinds in 4.2, device info in 2.2, GETPARAM values in 2.1. Track #2314 holds this work
package.

| WP | Contract points it implements |
|---|---|
| N3 | section 6.1 (one VA space per file, create and destroy, no leak) |
| N4 | 4.2 placement, `pte_kind`, `tile_mode`, `COHERENT`, `NO_SHARE`; 6.2 page sizes; sparse range |
| N5 | 4.1, 4.3, 4.4, 5 (the mmap attribute rule), GEM_CLOSE and PRIME `EPERM` for `NO_SHARE` |
| N6 | 6.1, 6.2 synchronous, 6.2.1 atomicity, all overlap and unmap rules, sparse |
| N7 | 6.2 asynchronous: bind queue order, waits, signals, no failure after accept |
| N8a | 2 (GETPARAM, GETINFO, class list), 3 (channels, objects) |
| N8b | 6.3 EXEC, 6.5, `drm_sched` ordering, timeouts |
| N8c | 6.4 device loss: per-channel kill, whole-GPU loss, liveness probe |
| N9 | the whole file, as the caller |

Boundary cases every owning WP's user-space test must include (each one a hole a naive
implementation leaves):

- UNMAP of a range that was never bound, or has holes, succeeds; a MAP inside a sparse region over
  an already bound page succeeds and replaces it; UNMAP of the whole VA of a sparse resource with
  holes, then UNMAP|SPARSE of its region, both succeed (NVK's VA free);
- VM_BIND MAP with `bo_offset = 2^64 - 4096`, `range = 8192` on a small BO: `EINVAL`;
- VM_BIND with `addr + range` wrapping, or `op_count == 0`, or a sync bind with a non-zero
  `wait_ptr`: `EINVAL`;
- VM_INIT with `kernel_managed_addr = 0xFFFFFFFFFFE00000` and size 18 MiB: `EINVAL`;
- GEM_NEW with `size = 2^64 - 1`: `ENOMEM`, no handle; GEM_INFO with `flags = 1`: `EINVAL`;
- mmap of `size + 4 KiB`, and of the last page plus one more: `EINVAL`;
- a push buffer that writes `seqno + N` into every page of the kernel range: the channel is
  lost, no fence signals early, and a freed BO's memory is not reused by another file;
- `engine_instance = ce_count` succeeds, `ce_count + 1` is `EINVAL`;
- an async UNMAP waiting on a syncobj that holds an error: the mapping still changes and the
  signal carries that error, so an EXEC waiting on it fails with the same error and leaves
  its channel alive;
- two files each allocate 64 MiB: neither's `VRAM_USED` shows the other's (`VRAM_FREE` is
  device-wide and does show it, section 2.1);
- CHANNEL_ALLOC after `MAX_CHANNELS` CHANNEL_FREEs of channels that still run jobs: `ENOSPC`
  until one has drained; the id counter at `UINT32_MAX - 1` gives two distinct ids, then `ENOSPC`, never a
  reused id;
- a job that aims writes at the kernel range and spins, then CHANNEL_FREE: the channel is lost
  and another file's BOs never show its writes;
- an async bind and an EXEC waiting on a fence that never signals, then `close()`: it returns
  in bounded time and the RM channel count returns to its baseline;
- an async MAP, whole-GPU loss before it runs, then a MAP of the same range: `ENODEV`
  (poisoned VM), not `EEXIST`;
- a push at `va = 2^64 - 4`, `va_len = 8`, and one with `va_len` above `NVR_EXEC_PUSH_LEN_MAX`:
  `EINVAL`;
- GEM_NEW `VRAM|GART` with a compressed kind while video memory is full: `ENOMEM`, no BO;
  `align = 2048`: `EINVAL`;
- VM_BIND of a PRIME-imported foreign BO with a compressed kind: `EINVAL`;
- on a `NO_VRAM` device GEM_NEW `VRAM` with a compressed kind: `EINVAL`;
- `NO_SHARE` BO: PRIME export and FLINK are `EPERM`;
- a push `va_len = NVR_EXEC_PUSH_LEN_MAX` succeeds, `+ 4` is `EINVAL`;
- map X, touch it with a job, unmap, close X, let file B fill memory, run a job on X's old
  address: the channel is lost and B's data is never returned (TLB invalidated);
- queue `MAX_QUEUED + 1` async binds on a syncobj that never signals: the last one is
  `ENOSPC` and another file's GEM_NEW still succeeds;
- thread A a synchronous MAP of X behind a blocked async bind, thread B an async MAP of X:
  exactly one succeeds, the other is `EEXIST`; a delay injected between the drain and the lock
  of the sync bind, with an async UNMAP of X queued in the window: the sync MAP returns only
  after that UNMAP ran, and a job on X reads the sync MAP's data;
- async MAP queued behind a syncobj, GEM_CLOSE of its BO, another file allocates and fills
  memory, signal: the BO was kept alive and the other file's data is never written;
- GEM_NEW memory is zero: file A fills 64 MiB of video memory and 64 MiB of system memory with a
  pattern and closes; file B allocates until `VRAM_FREE` drops and scans its new BOs through
  mmap and through a copy-engine copy: no pattern word appears;
- GETINFO fields with a GETPARAM twin equal it; a sync entry with `flags = 2` or `0x10` is
  `EINVAL` in VM_BIND and EXEC;
- a `PITCH` video-memory BO mapped with a compressed `pte_kind` override: `EINVAL`;
- `GEM_NEW(VRAM|MAPPABLE|COHERENT)` on a device with video memory: `EINVAL`;
- file A runs a spinning job until its timeout while file B runs a long finite job on its own
  channel: B's job completes without error and B's liveness probe returns 0;
- CHANNEL_FREE with a ready job queued behind a running one: the queued job's signal completes
  with `ECANCELED`;
- a job that failed on an errored wait, then a normal EXEC on the same channel: it succeeds
  with a clean fence;
- a faulted writer of B, then CPU_PREP(B) while the fence is unsignalled or signalled with
  its error: `ENODEV`; the job's own signal fence carries the error as well;
- a process with 64 files filling its quotas behind never-signalled fences, then a process of
  another uid doing an async 4 KiB MAP and a CHANNEL_ALLOC: both succeed;
- mmap with `offset = map_handle + 4096`, `length = 2^64 - 4096`: `EINVAL`;
- file B `mmap`s the `map_handle` of file A's BO (with and without `NO_SHARE`): `EACCES`;
- many maximal-range async binds forced to 4 KiB pages behind a never-signalled syncobj, from
  several fds: `ENOSPC`, and another file's GEM_NEW of 64 MiB still succeeds;
- a job that forges a fence by writing `seqno` into every page of the kernel range faults
  instead; a dma-buf exporter that frees on fence never has its pages written afterwards;
- a faulted job that wrote BO B, then CPU_PREP(B): `ENODEV`;
- `VRAM|GART|COHERENT` with video memory full: the returned domain is `GART|COHERENT`.

Every ioctl and every error code above has a user-space test in the owning WP; a behaviour
this file leaves out is undefined and a defect in this file, to be fixed by a minor version.

## 11. Notes for the Mesa backend (N9)

Found by replaying NVK's real call sequences against this contract. None changes a layout.

- **PTE kind.** NVK puts the kind in bits 0-7 of the bind op's `flags`, also on UNMAP. Use
  `NVR_VM_BIND_PTE_KIND` with `pte_kind` on MAP only; send 0 in the bind op's `flags` kind bits and in `pte_kind` on UNMAP (anything else is `EINVAL`).
- **Unbind.** NVK's `va_unbind` sends MAP with handle 0; send UNMAP instead (holes are no-ops,
  section 6.2).
- **VM_INIT** is a 32-byte read-write structure here (NVK's is 16 bytes, write only).
- **Array sizes.** NVK's fixed arrays (256 syncs, 4096 bind ops) exceed the minimums of section
  8; size them from GETPARAM `MAX_SYNCS` and `MAX_BIND_OPS`.
- **VRAM_USED** is per file and can be 0; do not assert it is positive.
- **BAR_DEVICE_MEM.** Do not offer host-visible device-local memory types: applications `memcpy`
  into mapped pointers and Device-nGnRE memory faults on unaligned access.
- **Open questions that are not decided here** (Mark's): the per-credential cap values (section
  8), the major-version number plan (header comment, section 1.1) and the `VRAM_FREE` privacy
  tunable (section 2.1) stay open.

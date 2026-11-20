# Cross-vendor PRIME import on FreeBSD: making an amdgpu dma-buf usable by nvidia-drm

Design note for Track #2228, 2026-11-20. It was written together with the NULL-handle guard
(`patches/patch-nvidia-drm_nvidia-drm-fb.c`, commit 18fa11d) and is kept current as the work
items below land.

In this document `ogkm/` means NVIDIA's open-gpu-kernel-modules 580.178.04 (MIT), checked out
at `~/work/gb10/sources/open-gpu-kernel-modules-580.178.04`. Line numbers refer to the pristine
files; the functions named next to them are the stable anchors.

## 0. The short version

The kernel panic is not a nvidia-drm bug in the sense of "a wrong check": the framebuffer
code calls the NVKMS KAPI with a handle the RM never gave it, and the KAPI dereferences
whatever handle it is given. The guard in `nv_drm_framebuffer_init()` (#2228) turns that panic into `-EINVAL`.

The *import* fails for a different and much older reason: NVIDIA's FreeBSD driver has never
had a dma-buf import. The OS layer function the RM calls for it is a stub that returns
`NV_ERR_NOT_SUPPORTED`. That is true on x86-64 as well; the arm64 port inherited it.

The fix is not a one-liner, because the two sides of the boundary speak different types:
`nvidia-drm` sees a Linux `struct dma_buf` and a `struct sg_table`, while the OS layer in
`nvidia.ko` is native FreeBSD code that cannot even name those types (they are forward
declarations in `src/nvidia/nv.h`). The design below moves the type translation to the
side that can do it - `nvidia-drm` - and hands the RM the one thing the FreeBSD RM path
already understands: an array of `vm_page_t *`.

## 1. Where the import fails today (the exact chain)

| # | Where | What happens |
|---|---|---|
| 1 | `src/nvidia-drm/nvidia-drm-gem-dma-buf.c:155` | `nvKms->getSystemMemoryHandleFromDmaBuf(dev, (NvP64)dma_buf, size - 1)` |
| 2 | `ogkm/src/nvidia-modeset/kapi/src/nvkms-kapi.c:2006` | `GetSystemMemoryHandleFromDmaBuf()` -> `GetSystemMemoryHandleFromDmaBufSgtHelper(device, NVOS32_DESCRIPTOR_TYPE_OS_DMA_BUF_PTR, dmaBuf, limit)` (`:1928`) |
| 3 | `ogkm/src/nvidia-modeset/kapi/src/nvkms-kapi.c:1967` | `nvRmApiAlloc(..., NV01_MEMORY_SYSTEM_OS_DESCRIPTOR, &memAllocParams)` with `descriptorType = NVOS32_DESCRIPTOR_TYPE_OS_DMA_BUF_PTR` |
| 4 | `ogkm/src/nvidia/arch/nvalloc/unix/src/osmemdesc.c:159` | the descriptor switch calls `osCreateOsDescriptorFromDmaBufPtr()` (`:1049`) |
| 5 | `ogkm/src/nvidia/arch/nvalloc/unix/src/osmemdesc.c:1079` | `nv_dma_import_dma_buf(dma_dev, dmaBuf, bRoDeviceMap, &size, &pImportSgt, &pImportPriv)` |
| 6 | **`src/nvidia/nvidia_subr.c:2129`** | **the FreeBSD OS layer: `return NV_ERR_NOT_SUPPORTED;`** |
| 7 | `ogkm/src/nvidia-modeset/kapi/src/nvkms-kapi.c:1972-1980` | `nvRmApiAlloc` failed -> the KAPI frees the memory object and returns **NULL** |
| 8 | `src/nvidia-drm/nvidia-drm-gem-dma-buf.c:153-161` | `pMemory == NULL` is stored in the GEM object (`nv_drm_gem_object_init()`, `nvidia-drm-gem.c:127`) - no error is reported |
| 9 | `src/nvidia-drm/nvidia-drm-fb.c:167` | `nvKms->isVidmem(nv_gem->pMemory)` with a NULL handle |
| 10 | `ogkm/src/nvidia-modeset/kapi/src/nvkms-kapi.c:2225` | `IsVidmem()`: `return memory->isVidmem;` - **NULL dereference** |

Step 10 is the panic. `struct NvKmsKapiMemory`
(`ogkm/src/nvidia-modeset/kapi/include/nvkms-kapi-internal.h:167`) puts `isVidmem` at offset
**0x28**: `hRmHandle` (4) + padding (4) + `size` (8) + `surfaceParams` (24) = 40 = 0x28. The
panic's `far: 0x0000000000000028` is exactly that field, and `x9 = IsVidmem + 0x0` is the
KAPI function in the trace. The two numbers agree with the source, so the chain above is
the whole story, not a plausible story.

**Which of the three candidate causes is it?** A missing OS-interface implementation, not a
LinuxKPI difference and not an arm64 path:

* The stub at `src/nvidia/nvidia_subr.c:2129` is unconditional and architecture-free; the
  same file is used for the x86-64 driver, so PRIME import never worked on FreeBSD.
* The arm64 exception in the RM (`osmemdesc.c:90`, `!NVCPU_IS_AARCH64 && NV_RM_PAGE_SIZE !=
  os_page_size`) makes the RM *more* permissive on arm64, not less.
* The LinuxKPI dma-buf is not involved in the failure: the DRM core's import (which the
  panic proves worked - a GEM object with a NULL handle exists) hands the buffer over, and
  the failure is one layer further down, in the RM's OS layer.

The same gap exists in the sibling paths, all of them stubs in the same file:

| Function | FreeBSD | Used by |
|---|---|---|
| `nv_dma_import_dma_buf()` `nvidia_subr.c:2129` | `NV_ERR_NOT_SUPPORTED` | the PRIME import (`nvidia-drm-gem-dma-buf.c:155`) |
| `nv_dma_import_sgt()` `nvidia_subr.c:2119` | `NV_ERR_NOT_SUPPORTED` | the export ioctl (`nvidia-drm-gem-dma-buf.c:205`) |
| `nv_dma_import_from_fd()` `nvidia_subr.c:2142` | `NV_ERR_NOT_SUPPORTED` | the NVIDIA userspace driver's own dma-buf import (Vulkan/EGL under the Linuxulator) |
| `nv_register_sgt()` `nvidia_subr.c:1918` | `return NV_OK` **without filling the physical address array** | the RM's dma-buf/SGT memory descriptor (`osmemdesc.c:826`) |

The last one is the nastier of the four: it *lies*. It returns success and leaves the pte
array empty, so even with the import implemented the memory descriptor would have no pages
and the GPU would have nothing to scan out.

The Linux implementation of all four is `ogkm/kernel-open/nvidia/nv-dmabuf.c:1786`
(`nv_dma_import_dma_buf`: `dma_buf_attach()` + `dma_buf_map_attachment()`) - Linux glue that
is not built for FreeBSD.

## 2. Can the RM's FreeBSD layer take a scatterlist?

Yes, but not through the path NVIDIA chose. The RM has a second OS-descriptor type that the
FreeBSD OS layer implements **completely**:

* `NVOS32_DESCRIPTOR_TYPE_OS_PAGE_ARRAY` (`osmemdesc.c:152`, `osCreateOsDescriptorFromPageArray()`
  at `:306`): the descriptor *is* an array of `vm_page_t *`. It calls `osCreateMemdescFromPages()`
  -> `nv_register_user_pages()` (`src/nvidia/nvidia_subr.c:1797`, implemented: it converts the
  array into the RM's physical-address array) -> `memdescMapIommu()`. On teardown
  `osDestroyOsDescriptorPageArray()` (`osmemdesc.c:1129`) calls `nv_unregister_user_pages()`
  and `os_unlock_user_pages()` (`src/nvidia/nvidia_os.c:998`, implemented: unwires, dirties
  and frees the array).
  The path insists on `COHERENCY = CACHED/WRITE_BACK` and refuses a contiguous request
  (`osmemdesc.c:336-340`).
* The dma-buf/SGT path is the one that is stubbed. The RM's own `escape.c:164` shows how the
  page-array descriptor is meant to be produced: `os_lock_user_pages()` (implemented,
  `src/nvidia/nvidia_os.c:937`) turns a user address into a wired `vm_page_t *` array.

So the RM, the OS layer and the teardown path all work for system memory. What is missing is
only the step that turns a *foreign* dma-buf into that array.

**The enabler: linuxkpi's `struct page` IS a `vm_page_t`.**
`sys/compat/linuxkpi/common/include/linux/page.h:52`: `#define page vm_page`. And
`sys/compat/linuxkpi/common/include/linux/scatterlist.h` gives `struct sg_table` a
`struct scatterlist *sgl` whose entries carry their page in `page_link`, reachable with
`sg_page()` and iterable with `for_each_sgtable_sg()`. `nvidia-drm` is built against
linuxkpi, so it can walk the imported dma-buf's scatterlist and produce exactly the array
the RM's page-array path wants.

## 3. The design

> Sections 3 and 6 are the original sketches. Section 7 records what was built and where it
> differs (the KAPI signature has an out parameter `pPagesTaken`; the export uses the SGT entry
> points with a descriptor, not a Linux `sg_table`; the RM needed a one-hunk patch).

### 3.1 What to implement

**A FreeBSD-only KAPI entry that imports a page array.**

1. `nvidia-drm` (`src/nvidia-drm/nvidia-drm-gem-dma-buf.c`), in
   `nv_drm_gem_prime_import_sg_table()`: when `getSystemMemoryHandleFromDmaBuf()` returns
   NULL (the RM could not import the buffer), build the page array from the `struct
   sg_table *sgt` the DRM core already handed us and import it through the new entry.
   The pages are already pinned by the DRM core's dma-buf attachment, so no new pinning is
   needed - but they must be *wired* for the duration (see 3.3).

   ```c
   /* sketch, nvidia-drm */
   static int __nv_drm_gem_dma_buf_import_pages(struct nv_drm_gem_object *nv_gem,
                                                struct sg_table *sgt)
   {
       struct page **pages;
       unsigned int i, n = 0;

       pages = nv_drm_calloc(sgt->orig_nents, sizeof(*pages));
       if (pages == NULL)
           return -ENOMEM;

       for_each_sgtable_sg(sgt, sg, i) {
           pages[n++] = sg_page(sg);
       }

       nv_gem->pMemory = nvKms->getSystemMemoryHandleFromPageArray(
           nv_gem->nv_dev->pDevice, (NvP64)(NvUPtr)pages, n * PAGE_SIZE - 1);
       ...
   }
   ```

2. The KAPI (`ogkm/src/nvidia-modeset/kapi/src/nvkms-kapi.c`, plus the **two identical**
   headers `ogkm/src/nvidia-modeset/kapi/interface/nvkms-kapi.h` and
   `src/common/inc/nvkms-kapi.h` - they are byte-identical today and must stay so):

   ```c
   /* in struct NvKmsKapiFunctionsTable */
   struct NvKmsKapiMemory*
   (*getSystemMemoryHandleFromPageArray)(struct NvKmsKapiDevice *device,
                                         NvP64 pages,
                                         NvU32 limit);
   ```
   implemented like `GetSystemMemoryHandleFromDmaBufSgtHelper()`, but with
   `descriptorType = NVOS32_DESCRIPTOR_TYPE_OS_PAGE_ARRAY`, `descriptor = pages`,
   `COHERENCY = WRITE_BACK` and no contiguity request.

   `nvidia-drm.ko` and `nvidia-modeset.ko` each keep their own copy of the table
   (`src/nvidia-drm/nvidia-drm.c:30` fills it from the exported
   `nvKmsKapiGetFunctionsTable()`), so both sides must be rebuilt from the same headers -
   which this repository does.

3. The OS layer (`src/nvidia/nvidia_subr.c`): **nothing**, for the import itself -
   `nv_register_user_pages()`, `nv_unregister_user_pages()` and `os_unlock_user_pages()`
   are implemented and are exactly what the RM's page-array path calls. What the OS layer
   *does* need is the wiring discipline of 3.3, and - for the export ioctl - a real
   `nv_register_sgt()`.

### 3.2 The export ioctl (the other half)

`nv_drm_gem_export_dmabuf_memory_ioctl()` (`nvidia-drm-gem-dma-buf.c:205`) asks the RM for a
memory handle of an *already imported* buffer, through
`getSystemMemoryHandleFromSgt()`. That path is `NVOS32_DESCRIPTOR_TYPE_OS_SGT_PTR` ->
`osCreateOsDescriptorFromSgtPtr()` (`osmemdesc.c:1016`) -> `nv_dma_import_sgt()` (stub) and
then `nv_register_sgt()` (the lying stub). With the page-array import in place, the export
can be served from the same page array: the GEM object keeps the `vm_page_t **` it was
imported with, and the export ioctl hands *that* to the RM instead of an sg_table. That
removes the need for the SGT path on FreeBSD entirely.

### 3.3 The wiring (the one real FreeBSD-specific subtlety)

The RM's teardown calls `os_unlock_user_pages()` (`src/nvidia/nvidia_os.c:998`), which does
`vm_page_dirty()` + `vm_page_unwire(user_pages[i], PQ_ACTIVE)` and frees the array. The
pages of a dma-buf are *held* by the DRM core's attachment, but they are not *wired*. So
somebody must wire them, and the array must be allocated with an allocator the OS layer's
`os_free_mem()` can free (FreeBSD's `free()` ignores the zone type, so a `kzalloc()` array
is fine, but the ownership must be documented in one place).

Two candidate placements:

* **In `nvidia-drm`** (wire before the import, let the RM's teardown unwire). Smallest
  change; the DRM module already has the pages and the linuxkpi page API. The risk is a
  mismatch between "wired by nvidia-drm" and "unwired by the RM's teardown" if the import
  fails halfway.
* **In the OS layer** (a small `nv_import_pages()` / `nv_unimport_pages()` pair next to the
  other `nv_*` functions). Keeps the wiring and the unwiring in the same module and in the
  same allocator; costs one more exported symbol and one more patch.

The second is the safer one and is what this proposal recommends.

### 3.4 What this does NOT fix

1. **The scan-out rule.** `src/nvidia-drm/nvidia-drm-fb.c:167` (before the guard patch):

   ```c
   if (!nvKms->isVidmem(nv_gem->pMemory) && nv_dev->hasVideoMemory) {
       non_scanout_mem_backed = true;
   }
   ```

   and then `nv_fb->pSurface = NULL;` with the comment *"Do not register drm_framebuffer
   against nvkms"*. On a card **with** video memory (an RTX 5060 Ti does), a framebuffer
   whose plane is system memory gets **no NVKMS surface at all**, so the display engine
   cannot scan it out. This is NVIDIA's own rule, on Linux as well as on FreeBSD: a
   discrete NVIDIA GPU does not scan out system memory.

   Consequence: even with a perfect import, "render on the amdgpu, scan out on the NVIDIA
   card" cannot work as a *direct* scan-out. The workable shape is the one a compositor
   already uses for a cross-device renderer: the foreign buffer is imported as a texture
   and **copied** into an NVIDIA video-memory buffer that is then scanned out. That copy
   needs the import (section 3.1) on the NVIDIA side, and it needs the NVIDIA userspace
   driver to import a foreign dma-buf - which is `nv_dma_import_from_fd()`, the third stub.

2. **VRAM buffers.** A dma-buf that lives in the amdgpu's VRAM has no `vm_page_t` behind its
   scatterlist entries (those are ttm pages), so the page-array design does not apply to it.
   Only **system-memory** dma-bufs can be imported this way - which matches the case in
   the task ("system memory, linear"). A VRAM buffer needs a copy.

3. **The fd path.** `nv_dma_import_from_fd()` is a stub, and FreeBSD has no Linux dma-buf
   file-descriptor ABI, so the NVIDIA userspace driver's own import path (the one the
   Linuxulator's Vulkan/EGL uses) needs a FreeBSD equivalent of the dma-buf fd. That is a
   separate, larger piece of work - a FreeBSD dma-buf fd ABI in the DRM core.

## 4. Risks

| Risk | Why it matters | Mitigation |
|---|---|---|
| The page array outlives the DRM's pinning | The RM reads the pages asynchronously; if the DRM unpins them first, the GPU reads freed pages | The DRM destroys the GEM object (`drm_prime_gem_destroy`) *after* the RM memory handle is freed (`nvidia-drm-gem-dma-buf.c:48` before `:51`) - the order is already right; keep it |
| A dma-buf that is not page-aligned or not linear | The RM's page-array path wants whole pages | Refuse anything whose scatterlist is not a whole number of pages, with the page count checked against the buffer size |
| A dma-buf whose pages are not RAM | `nv_register_user_pages()` calls `VM_PAGE_TO_PHYS()` on every entry | Check that every entry is a managed RAM page; refuse otherwise (this is also the VRAM case of 3.4) |
| Coherency | The RM's page-array path refuses `WRITE_COMBINE` | The new KAPI entry must ask for `WRITE_BACK`; the display engine then reads cached memory, which is what the RM expects for this path |
| The table layout changes | `nvidia-drm.ko` and `nvidia-modeset.ko` each keep a copy of the KAPI table | Both are built from this tree; `nvKmsKapiGetFunctionsTable()` must be rebuilt on both sides (the version string check does not catch a layout change - a mismatched pair would call the wrong function pointer) |
| The guard is in the way | Once the import works, the framebuffer guard must not refuse a legitimate import | The guard only refuses a NULL handle; a successful import has a handle |

## 5. Test plan for amp001

amp001: AMD RX 7600 (card0, amdgpu) + NVIDIA RTX 5060 Ti (card1, nvidia). Both drivers
loaded, one Wayland session (Wayfire/wlroots).

### 5.1 Before anything else: the panic must be gone

With the guard of #2228, the same login that panicked must now fail *cleanly*:

```
dmesg | grep -i "NVKMS memory handle"
# [nvidia-drm] [GPU ID 0x...] The RM could not import the dma-buf; the buffer has no NVKMS memory handle
# [nvidia-drm] [GPU ID 0x...] Plane 0 has no NVKMS memory handle; refusing the framebuffer
```

and the `DRM_IOCTL_MODE_ADDFB2` that used to panic must return `-EINVAL` to the caller. The
compositor must not die; it should fall back (wlroots logs the failed direct scan-out and
copies, or gives up on that output).

### 5.2 Direction 1: render on the amdgpu, scan out on the NVIDIA card

1. Boot with both `amdgpu.ko` and `nvidia-drm.ko` loaded; the NVIDIA card owns the output
   (`/dev/dri/card1`), the AMD card is the renderer.
2. Run the session with the renderer on card0 and the output on card1. With wlroots, force
   the renderer (`WLR_RENDERER=gles2` with `WLR_RENDERER_DRM_DEVICE=card0`, or the Vulkan
   renderer with the AMD device selected) and keep the output on card1.
3. Observe:
   * no kernel panic, no `IsVidmem` fault;
   * the monitor shows the correct image (during the copy phase);
   * `dmesg` shows the import attempt and, after section 3.1 lands, a successful import
     (no "could not import" line);
   * the NVIDIA card's VRAM usage grows by the size of the copied frame (proves the copy
     landed in NVIDIA memory).
4. Direct, without a compositor: a small program that
   * creates a buffer on card0 (`DRM_IOCTL_MODE_CREATE_DUMB` on the amdgpu, or a
     `udmabuf` device for a plain system-memory buffer),
   * exports it (`DRM_IOCTL_PRIME_HANDLE_TO_FD`),
   * imports it into card1 (`DRM_IOCTL_PRIME_IMPORT_HANDLE`),
   * adds a framebuffer on card1 (`DRM_IOCTL_MODE_ADDFB2`),
   * sets a mode on card1 and reads the framebuffer back.
   Today: the import succeeds and `ADDFB2` returns `-EINVAL` (with the guard) - no panic.
   After section 3.1: `ADDFB2` succeeds; whether the NVIDIA card *scans it out* is the
   question of section 3.4, and the answer for a system-memory plane is no, so the test
   asserts the buffer is readable through the NVIDIA card, not that it is displayed.
5. The reverse of the copy: render on card1 into NVIDIA VRAM and hand it to card0. Expect
   today: the export ioctl fails with `-ENOMEM` (`getSystemMemoryHandleFromSgt` -> the
   `nv_dma_import_sgt` stub), and a *VRAM* NVIDIA buffer cannot be exported through DRM
   PRIME at all (`__nv_drm_gem_nvkms_memory_prime_get_sg_table()` returns `-ENOMEM` when
   `pages_count == 0`, i.e. for video memory). After section 3.2, an NVIDIA *system memory*
   buffer can be exported and imported by the amdgpu.

### 5.3 Regression: what must keep working

* The dumb-buffer path on the NVIDIA card (`DRM_IOCTL_MODE_CREATE_DUMB` + `mmap` + write +
  read back) - the guard must not touch the nvkms memory path. The existing evidence is
  the 1920x1080 colour-bar test with 0 bad samples (test boot 5, 2026-11-19; recorded in README.md, "What works").
* A framebuffer created from a user-memory GEM (`NV_DRM_GEM_IMPORT_USER_MEMORY`): it has no
  handle by design, so the guard refuses it. It was a panic before, so this is not a
  regression - but it must be checked that nothing in NVIDIA's stack creates framebuffers
  from user-memory or fence-context GEMs.
* The existing suite: `tests/drm_fault_index_test.sh` and `tests/drm_null_memory_test.sh`
  (#2228) must both pass on the prepared tree.

## 6. Work items, in order

1. **Done (18fa11d):** the NULL-handle guard in `nvidia-drm-fb.c`, the guards on the
   other `isVidmem()` call sites, the dma-buf import/mmap/export guards, and
   `tests/drm_null_memory_test.sh`.
2. The KAPI entry `getSystemMemoryHandleFromPageArray()` (ogkm KAPI + the two identical
   headers) and the `nvidia-drm` side that builds the page array from the scatterlist.
3. The wiring/unwiring in the OS layer (`nv_import_pages()` / `nv_unimport_pages()`), so
   that the RM's teardown unwires what was wired.
4. The export ioctl served from the imported page array (replacing the SGT path on FreeBSD),
   and a real `nv_register_sgt()`.
5. The dma-buf fd ABI for the userspace driver (`nv_dma_import_from_fd()`), which is what
   the NVIDIA Vulkan/EGL under the Linuxulator needs to import a foreign buffer as a
   texture.
6. The scan-out question of 3.4, decided with the owner: copy into NVIDIA VRAM (the
   compositor's normal cross-device path) or teach the display engine to scan out system
   memory (NVIDIA's own code says it does not).

## 7. Implementation status (work items 2 to 4, #2228)

Items 2, 3 and 4 are implemented. The code differs from the sketches above in the places listed
here; where the two disagree, this section is right.

### 7.1 What was built, and where

| Piece | File | Tests that go red without it |
|---|---|---|
| The pure core: conversion, wiring, the SGT logic | `src/gb10-pageimport/gb10_pageimport.h` (installed as `common/inc/gb10_pageimport.h`) | `tests/pageimport_test.sh` (conversion cases, wire balance, SGT cases, 16 mutants) |
| KAPI entry `getSystemMemoryHandleFromPageArray()`, last member of the table, in both header copies | `patches/ogkm/patch-src_nvidia-modeset_kapi_src_nvkms-kapi.c`, `patches/ogkm/patch-src_nvidia-modeset_kapi_interface_nvkms-kapi.h`, `patches/patch-common_inc_nvkms-kapi.h` | `tests/kapi_table_test.sh`, `tests/prime_import_test.sh` (K1) |
| RM core: a kernel client may create a page-array descriptor | `patches/ogkm/patch-src_nvidia_arch_nvalloc_unix_src_osmemdesc.c` | `tests/prime_import_test.sh` (R1) |
| nvidia-drm: scatter list to page array, import, export from the retained pages | `patches/patch-nvidia-drm_nvidia-drm-gem-dma-buf.c`, `.h` | `tests/prime_import_test.sh` (D1 to D3) |
| nvidia.ko: `nv_import_pages()`, `nv_unimport_pages()`, real `nv_register_sgt()`, `nv_unregister_sgt()`, `nv_dma_import_sgt()`, `nv_dma_release_sgt()`; the two new symbols exported (prototypes in the shared core header) | `patches/patch-nvidia_nvidia_subr_prime.c` (applied after the older `patch-nvidia_nvidia_subr.c`), `patches/patch-nvidia_Makefile` | `tests/prime_import_test.sh` (O1 to O4); `tests/kmod_symbols_test.sh` (every symbol nvidia-drm.ko takes resolves) |

### 7.2 Where the sketches were wrong or incomplete

1. **The RM refuses the page-array descriptor to kernel clients.** `osCreateMemFromOsDescriptor()`
   (`osmemdesc.c`) returns `NV_ERR_NOT_SUPPORTED` for a kernel RM client unless the descriptor
   type is `OS_PHYS_ADDR`, `OS_FILE_HANDLE`, `OS_DMA_BUF_PTR` or `OS_SGT_PTR`. NVKMS is a kernel
   client, so section 3.1 as written would have failed in the RM. The patch adds `OS_PAGE_ARRAY`
   to that list. This is a change to the RM core (MIT), kept as a one-hunk patch in `patches/ogkm`.
2. **A scatter-list entry can span several pages.** The sketch stored one page per entry. The
   core expands every entry (`gb10_pi_fill()`), asking the kernel for the page `index` pages after
   the first by physical address, and refuses a page that is not managed RAM at any position.
3. **Who owns the array.** The RM owns it from the moment the descriptor is created: it clears
   the descriptor in the parameters it was given (`os_desc_mem.c`), and its teardown unwires and
   frees the array (`osDestroyOsDescriptorPageArray()`). The RM's own `RmCreateOsDescriptor()`
   uses the same rule to decide who unwires after a failed allocation. The KAPI entry reports it
   with an out parameter (`pPagesTaken`); `nvidia-drm` gives the array back
   (`nv_unimport_pages()`) only when the RM did not take it. The rule relies on kernel callers'
   parameters being used in place (`serverAllocApiCopyIn()` copies only for user callers); the
   success path, which a test boot exercises, does not depend on that.
4. **The wiring is in the OS layer** (the second placement of 3.3): `nv_import_pages()` allocates
   the array with `os_alloc_mem()` (what the RM's `os_free_mem()` frees) and wires each page once
   with `vm_page_wire()`; the RM's teardown does `vm_page_unwire(page, PQ_ACTIVE)` per page,
   which `nv_pi_unwire()` repeats exactly. A wiring that fails halfway unwires what it wired.
5. **The export ioctl does not use the Linux `sg_table`** (and is reached only for a buffer whose
   page-array import produced no handle after the conversion succeeded: when the import has a
   handle, the export uses it and the SGT functions do not run; the kit's probe does not call the
   export ioctl, so those functions are covered by the userland model and the source checks only). The OS layer cannot read one. The GEM
   object keeps the pages it converted (not wired: the dma-buf attachment owns them) in a
   `struct gb10_pi_desc`, and the export passes that descriptor through the KAPI's existing SGT
   entry in place of the `sg_table`. The OS layer's SGT functions recognise it by a magic number
   that cannot be a kernel pointer: `nv_dma_import_sgt()` takes a GEM reference (the Linux driver
   does the same), `nv_register_sgt()` wires the pages and fills the RM's physical-address array
   (the stub returned success and filled nothing), `nv_unregister_sgt()` unwires,
   `nv_dma_release_sgt()` drops the reference. The RM calls release exactly once whatever
   happens to the registration, which the tests model for the success path, a failed
   registration and a failure after it.
6. **The table member is appended, not inserted.** `nvidia-drm.ko` and `nvidia-modeset.ko` each
   keep their own copy of the table, built from the same header; the version-string check does
   not notice a layout change. Appending leaves every existing offset alone; `tests/kapi_table_test.sh`
   compares `sizeof` and every `offsetof` of both header copies and fails on a planted mismatch.

7. **Pages that belong to a VM object are refused.** `vm_page_wire()` needs the object locked
   for such a page and the page can be renamed or freed under us, so both `page_at` functions
   (nvidia-drm and nvidia.ko) accept only a non-fictitious RAM page with no object. linuxkpi
   allocates a GPU driver's pages with `vm_page_alloc_noobj()`, so the buffers this feature is
   for qualify; a buffer made of object pages (a shared-memory object) is refused with the same
   log line. "Managed RAM" in the older text means exactly this.
8. **A mismatched `nvidia-modeset.ko`.** The appended table member stays NULL in an older module
   and the version string cannot tell; the import checks it and refuses with a log line before
   it wires anything.
9. **The RM rule the ownership report relies on** (kernel callers' allocation parameters are used
   in place) is pinned by `tests/prime_import_test.sh` (R2) against the pristine RM source, so a
   source bump that changes it goes red.

### 7.3 Refusals

A buffer that is not a whole number of managed RAM pages (partial page, a non-zero offset, an
entry with no page, a page in video memory, an empty buffer, more than 4 GiB, a scatter list
that does not add up to the size) is refused with `EINVAL`-class errors by the core and a log
line naming the reason (`gb10_pi_str()`). The GEM object is still created, without an NVKMS
handle (the behaviour of the guard in `nv_drm_framebuffer_init()`), so `DRM_IOCTL_MODE_ADDFB2`
answers `EINVAL`; the export ioctl answers `EINVAL` for it. Only an allocation failure is
`ENOMEM`. Nothing in the refusal paths can panic: the page count, the sizes and the
overflow cases are checked before any allocation or wiring (`tests/pageimport_test.sh`).

### 7.4 Risks that remain

* **Cache attributes.** The RM is asked for write-back memory (the page-array path accepts nothing
  else). Pages another driver mapped write-combining on the CPU side are aliased with a cacheable
  attribute here. arm64 allows it only with care; the 5.2 test is the first evidence.
* **Mixing module generations.** A new `nvidia-modeset.ko` fills one pointer past the table of an
  older `nvidia-drm.ko` (the version string cannot tell), and an older modeset module leaves the
  member NULL (checked, refused with a log line). The modules ship and load together; a layout
  tag in the handshake would close the first case and is not done.
* **Wire counting on hardware.** `vm.stats.vm.v_wire_count` counts pages whose wire count is
  non-zero. A GPU driver's pages are already wired, so the kit's `wire-count-stable` row only
  shows the count did not grow; the exact wire and unwire balance is proven by the userland model
  (`tests/pageimport_test.sh`) and by the source parity checks, not by the boot.
* **Freeing from the RM's teardown.** The last GEM reference can be dropped from inside the RM's
  teardown of an exported handle (the same shape as the Linux driver).
* **Direct scan-out** of an imported system-memory plane is still NVIDIA's rule (section 3.4):
  `ADDFB2` succeeds, the plane has no NVKMS surface (work item 6, #2308).

### 7.5 The hardware test

`tests/prime-import-testboot/` is the kit for a one-shot test boot environment named
`nvidia-prime-import-test-<date>-<n>`: `make-be.sh` assembles it, `prime_import_testboot` is the
self-recording rc one-shot (results under `~/work/gb10/logs/prime-import-*`), and
`prime_import_probe` (`prime_import_probe(8)`, JSON schema `prime-import-probe/1`) does the
create, export, import and `ADDFB2` of section 5.2. It never sets a mode and never loads or
unloads anything on a running system; the regressions of section 5.3 run from the rc script
with every missing tool recorded as a skip with its reason, never as a pass.

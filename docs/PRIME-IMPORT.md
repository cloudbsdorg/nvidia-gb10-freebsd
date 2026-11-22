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
| The pure core: conversion, wiring, the SGT logic | `src/gb10-pageimport/gb10_pageimport.h` (installed as `common/inc/gb10_pageimport.h`) | `tests/pageimport_test.sh` (conversion cases, busy/re-check/wire, dirty rule, exporter lifetime, SGT cases, about 35 mutants, a line-coverage gate of 100 percent with llvm-cov) |
| KAPI entry `getSystemMemoryHandleFromPageArray()`, last member of the table, in both header copies | `patches/ogkm/patch-src_nvidia-modeset_kapi_src_nvkms-kapi.c`, `patches/ogkm/patch-src_nvidia-modeset_kapi_interface_nvkms-kapi.h`, `patches/patch-common_inc_nvkms-kapi.h` | `tests/kapi_table_test.sh`, `tests/prime_import_test.sh` (K1) |
| RM core: a kernel client may create a page-array descriptor | `patches/ogkm/patch-src_nvidia_arch_nvalloc_unix_src_osmemdesc.c` | `tests/prime_import_test.sh` (R1) |
| nvidia-drm: scatter list to page array, import, export from the retained pages | `patches/patch-nvidia-drm_nvidia-drm-gem-dma-buf.c`, `.h` | `tests/prime_import_test.sh` (D1 to D3) |
| nvidia.ko, our own BSD-licensed file: `nv_import_pages()`, `nv_unimport_pages()`, the SGT register/unregister helpers, the guarded dirty step; the two import symbols exported (prototypes in the shared core header) | `src/gb10-pageimport/gb10_pageimport_os.c` (copied to `nvidia/` by `scripts/prepare-tree.sh`, added to `SRCS` by `patches/patch-nvidia_Makefile`); NVIDIA's proprietary `nvidia_subr.c` and `nvidia_os.c` only call into it (`patches/patch-nvidia_nvidia_subr_prime.c`, `patches/patch-nvidia_nvidia_os.c`) | `tests/prime_import_test.sh` (O1 to O4); `tests/kmod_symbols_test.sh` (every symbol nvidia-drm.ko takes resolves) |
| The pairing handshake: kld version 2 of `nvidia_modeset` against `MODULE_DEPEND(nvidia_drm, nvidia_modeset, 2, 2, 2)`, and the layout tag `NVKMS_KAPI_CBSD_LAYOUT` ("+cbsd-kapi.2") in the table's version string, in both header copies | `patches/patch-nvidia-modeset_nvidia-modeset-freebsd.c`, `patches/patch-nvidia-drm_nvidia-drm-freebsd-lkpi.c`, `patches/patch-nvidia-drm_nvidia-drm.c`, both KAPI header patches, `patches/ogkm/...nvkms-kapi.c` | `tests/kapi_table_test.sh` (both directions, planted mismatches) |

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
   The teardown also dirties the page when the descriptor is writable (the KAPI never marks it
   read-only): in the stock `os_unlock_user_pages()` that is `vm_page_dirty()` on every page, which
   asserts that the page is all valid on an INVARIANTS kernel, and marks an invalid page dirty on
   any other. The noobj pages of a GPU driver are never valid (only a user-mmap fault validates
   them), so the stock code panicked at the first close of an imported buffer. The dirty step is
   now `gb10_pi_os_dirty()`, see 7.6.
5. **The export ioctl does not use the Linux `sg_table`**, and it always goes through the SGT
   path when the pages were imported, also when the page-array import made a handle: that handle
   holds no reference on the GEM object or the exporter's dma-buf, so an RM file descriptor made
   from it could outlive both. The kit's probe does not call the export ioctl, so the SGT
   functions are covered by the userland model and the source checks only. The OS layer cannot
   read an `sg_table`. The GEM
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
   for such a page and the page can be renamed or freed under us, so one function,
   `gb10_pi_page_claimable()` in the core, decides, and both modules call it: nvidia-drm
   when it converts the scatter list (a first screening), nvidia.ko again with the page busied,
   just before it wires it (`gb10_pi_wire()`: busy, check again, wire, unbusy; a page that fails
   the second check, or whose busy lock somebody else holds, refuses the whole array and the
   pages wired before it are unwired). The check made in nvidia-drm alone was a
   check-then-wire race: a first-touch mmap fault of the exporter can insert the page into an
   object between the two. nvidia.ko has no `page_at` function any more. linuxkpi
   allocates a GPU driver's pages with `vm_page_alloc_noobj()`, so the buffers this feature is
   for qualify; a buffer made of object pages (a shared-memory object) is refused with the same
   log line. "Managed RAM" in the older text means exactly this.
8. **A mismatched `nvidia-modeset.ko`** is refused twice over. kldload refuses it first
   (`MODULE_VERSION(nvidia_modeset, 2)` against `MODULE_DEPEND(nvidia_drm, nvidia_modeset, 2, 2, 2)`).
   Then the table's version string carries `NVKMS_KAPI_CBSD_LAYOUT` on both sides, and
   `nvKmsKapiGetFunctionsTableInternal()` compares it before it writes any member, so a new
   nvidia-modeset never writes past an old nvidia-drm's table. Bump the tag and both versions
   whenever a member is appended. The import still checks the member for NULL.
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

* **Cache attributes (latent).** The RM records the pages as cached
  (`NV_MEMORY_CACHED`, snooped GPU access, the only mode the page-array path accepts) while the
  exporter may have set write-combining or non-cacheable on them with `pmap_page_set_memattr()`,
  which rewrites the direct-map alias with cache maintenance. This import creates no new CPU mapping, so
  there is no live aliasing today. **Any future CPU mapping of imported pages (by NVKMS or the
  RM) must take the exporter's attribute from the page (`md.pv_memattr`), not
  `gb10_ram_memattr()`:** the policy would give a cacheable alias of a non-cacheable page, a
  mismatched-attribute alias on arm64. Do not add such a mapping without that.
* **Mixing module generations** is refused by kldload (nvidia_modeset version, and nvidia-drm's undefined
  symbols against an older nvidia.ko without `nv_import_pages`) and by the table's layout tag (7.2, item 8).
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

### 7.6 The release path, the exporter's lifetime and the tripwire

**What keeps the exporter's buffer alive.** Every GEM object that imported pages holds a
reference on the exporter's dma-buf from the import (`gb10_pi_life_take()`) to the very last step of
the GEM object's free (`gb10_pi_life_drop()`), exported or not. The free order is fixed and
checked in the source (`tests/prime_import_test.sh`, D4): the RM handle first (the RM's teardown dirties and unwires the pages), then the
attachment (`drm_prime_gem_destroy()`), then the retained page array, then the dma-buf reference,
which is the only thing that lets the exporter's page pool reuse the pages. An export (the RM file
descriptor path) goes through the SGT functions and holds the GEM object for as long as the RM maps
the pages. `tests/pageimport_test.sh` models an exporter whose pool reuses the pages once nobody
holds the dma-buf: the exporter closes its handle and fd, and the pool has not reused them while
the importer's handle exists, nor when the last page is unwired; they are released only by the
final drop.

**Can an imported page enter a VM object while it is imported?** Yes, and it is legitimate. The
exporter's own user mapping of its buffer faults pages in through linuxkpi
(`lkpi_vmf_insert_pfn_prot_locked()`, `sys/compat/linuxkpi/common/src/linux_page.c`): it takes the
page with `PHYS_TO_VM_PAGE()`, busies it, and if it has no object inserts it into the mapping's
object and calls `vm_page_valid()` before it unbusies. It never looks at the wire count, so a page
we wired can gain an object at any time after the import; and a mapping that already faulted a
page in before the import is why such a page is refused at the conversion. The importer cannot map
the pages (`__nv_drm_gem_dma_buf_mmap()` refuses an imported buffer, which has no file). Preventing
the exporter's mapping would mean holding the pages busy for the whole import, which makes the
exporter's fault retry forever, or failing the exporter's mmap, which is not ours to do. So the
design does not prevent it; it makes it harmless, in the three orders the test covers
(`tests/pageimport_test.sh`): faulted in before the import (refused at the conversion, nothing
wired), during it (between the check and the wire: the busy lock and the second check refuse the
page and unwind), after the wiring (the page has an object and, because the fault path validates it
in the same busy hold, is all valid: the release dirties it correctly).

**The second wiring.** Exporting an imported buffer (the SGT path) wires its pages again. By then the
exporter's mapping may have faulted a page in, so the second wiring accepts a page that has an object
(it is wired by us and busied while it is wired once more; the descriptor is marked `imported` only once
the RM has the pages, and a buffer that was never wired by us is exported under the first-wiring rule) and refuses one that went fictitious
(permanent, `NV_ERR_NOT_SUPPORTED`); a page whose busy lock the exporter holds is a retry
(`NV_ERR_BUSY_RETRY`), at the first wiring and the second. Only the first wiring requires a page without
an object.

**The release step (`gb10_pi_os_dirty()`).** The RM's teardown calls it for every page of a
writable descriptor (the RM's own pinned user memory goes through it too, not only imported pages),
then unwires the page. The core (`gb10_pi_dirty_page()`) busies the page, waiting for a pager or a
laundry thread that holds it (about a millisecond, 100 spins of 10 microseconds, never sleeping: the
teardown may hold locks the sleep check cannot see), and asks at the dirty
site (`gb10_pi_dirty_action()`): no object means skip (no pager, nothing to write back); an object and
all valid means `vm_page_dirty()`; **an object that is not all valid is the tripwire**. If, after the spin,
the busy lock is still held by somebody else, the page is dirtied the way the stock code
did, without the lock, and counted: a dirty bit is never dropped silently. The spin has one budget for the whole teardown of a descriptor (`GB10_PI_DIRTY_SPIN_BUDGET`, 100
delays of 10 microseconds, about a millisecond in all, however many pages), and only a page that has an
object is waited for: a descriptor of many busy pages costs about a millisecond, not a millisecond a
page, under the RM API lock. Tests pin the budget and check it at the cap and one past it.

**The tripwires** are two read-only sysctls. The first should read 0 after a run of the kit, which pins no files (the boot kit has a
row for it, `dirty-refused`, which fails when it cannot be read after a passed import); the second
is reported by the kit as information:

* `hw.nvidia_unlock_dirty_refused`: a page with a VM object that was not all valid at the RM's unpin.
  It is logged, rate limited, with where to report it and a pointer to this section (no kernel
  pointer and no physical address: dmesg is readable by unprivileged users), not dirtied (`vm_page_dirty()` would assert on an INVARIANTS kernel and be wrong
  on any other), and not made a panic. The page is still unwired by the RM's teardown and the
  exporter's reference is still dropped last, so the pool cannot reuse the page while the RM maps
  it.
* `hw.nvidia_unlock_dirty_busy_fallback`: a page dirtied without its busy lock because the lock
  stayed held through the spin (the stock code's race: an invalidation between the question and the dirty).

The step also covers the RM's own pinned user memory. For a partly valid page of a file (a truncate
while it is pinned) the refusal means the GPU's writes to the valid part of that page are not
marked dirty and can be lost; the stock code asserted or marked an invalid page dirty there. That
is why a nonzero `hw.nvidia_unlock_dirty_refused` is unexpected for an imported buffer but not a
driver defect in itself: look at what was pinned.

Not chosen: leaving the page wired and the exporter's buffer referenced when the tripwire fires.
It would leak one wired page and one exporter buffer per event, without bound if userland can
repeat the event, and the RM's teardown hands over only the page array, so the count would be per
page and not per buffer. Because the only code that puts a wired page into an object (the
exporter's mapping fault, above) validates the page in the same busy hold, the refused state is
not reachable from it, and the counter exists to show a mistake in this analysis.
Preventing the entry itself would mean keeping every imported page busied for the whole
import, which puts the exporter's thread to sleep in its page fault until the importer lets go
(a deadlock when it is the same process that must release the import); it is not done.

The core is tested at 100 percent line coverage, with the partly valid object page, the page
invalidated after the wiring (a truncate), the page the exporter faulted in after the wiring, the page
with no object, and a busy lock held by a pager for a short and for a long time, each
with a mutant that fails without the rule. The tests also measure the counters: they stay 0 for a
page refused at the conversion, a page refused at the wire, and a page the exporter faulted in after the
wiring; they move only in the tripwire scenarios.

The rc script writes a `running` row and syncs the disk before each step that can panic the machine
(the import probe, the wire loop, the reverse probe, the regressions), and ends with a `done` row, so a
panic leaves the row it died in as the last line. `tests/prime-import-testboot/summarize.sh
<run directory | results.jsonl>` reads a run (usage in its header; exit 0 for a complete run
without a failure whose import passed, 1 for a failure, 2 for a usage error, 3 for a complete run that
skipped the import and so tested nothing): a missing `done` row or a trailing `running` row is a failure that names the step.
`tests/prime_import_kit_test.sh` runs the rc script itself against a fake probe, `sysctl`, `kldstat`
and `su` and checks the rows for a good probe, a failing probe and no probe (a skip, never a pass).
The row `wire-count-stable` says only that the wired page count did not grow; it cannot see a single
leaked wiring of an already wired page, and the sysctl `hw.nvidia_unlock_dirty_refused` must read 0 (the row `dirty-refused`)
after the run.

### 7.7 Unloading nvidia-drm, the coverage gate, and the kit

**Unload.** An export hands the RM a descriptor whose hold and release functions are in
`nvidia-drm.ko`; the RM file descriptor that holds it can outlive the DRM file and be closed after
the module is gone. `LKPI_DRIVER_MODULE` cannot refuse an unload, so a second module in
`nvidia-drm-freebsd-lkpi.c`, `nvidia_drm_pi_guard`, is the gate, and it must be unloaded first, so that its refusal comes before the driver's own
teardown. A file's modules are unloaded in the reverse of their load order (`module_register_init()` in
`sys/kern/kern_module.c` moves each loaded module to the head of the file's list, and `linker_file_unload()`
in `sys/kern/kern_linker.c` walks the list from the head), and the sysinits load by subsystem and order, so
the guard has to load last: `SI_SUB_DRIVERS` with `SI_ORDER_LAST`, above the `SI_ORDER_ANY` of
`LKPI_DRIVER_MODULE`. `kldstat -v` lists a file's modules in unload order; the boot kit checks that the guard is
listed before `nvidia_drm` (row `guard-order`) and `tests/prime_import_test.sh` runs a model of the two
functions on the guard's real order:

* `MOD_QUIESCE` returns `EBUSY` while any export is held (and says so in the log). When none is,
  it **closes the gate**: from then on a new export is refused (`nv_dma_import_sgt()` fails and the
  RM does not call the release after a failed import), and the unload can proceed. The kernel has
  no call that undoes a quiesce, so after a quiesce that was followed by an aborted unload (another
  module of the file refused), exports of imported buffers stay refused until the next boot.
* `MOD_UNLOAD` takes the same gate (EBUSY while an export is held, else it closes the gate), so an
  unload that skipped the quiesce still closes it when none is held.
* `kldunload -f` ignores a refused quiesce (`linker_file_unload()` in `sys/kern/kern_linker.c`), but not a
  module's refused unload: the loop that unloads the modules of the file returns the module's error
  whatever the flags. The guard loads last and so is unloaded first (see above), so its `EBUSY` stops even a forced
  unload before the driver's own teardown has run. A forced unload with no export held proceeds, the gate closed.
* A fallback, for a module order other than the one the guard relies on: `nv_drm_exit()`
  (through `nv_drm_remove_devices()`) does not destroy the devices and `nv_bsd_drm_exit()` does not free the
  pdevs while an export is held (the dma-buf attachment uses `&pdev->dev`), and the gate is marked kept and
  closed. This is reached only if the driver module is unloaded before the guard (for example, if the drm-kmod
  build orders its modules differently): the guard's `MOD_UNLOAD` still runs after it and refuses with the "kept"
  line, the file stays loaded, and every later quiesce and unload is refused until the machine is restarted. In
  that order this is the protection. On FreeBSD the teardown path is `nv_bsd_drm_exit` -> `nv_drm_exit` ->
  `nv_drm_remove_devices`; the KAPI `.remove` callback that calls `nv_drm_remove()` is registered only by the
  Linux build of nvidia-modeset.
* The count is taken in the hold, under a LinuxKPI spin lock (a default mutex there; a few instructions, nothing sleeps inside) together with the closing test, and counted down by
  the core in `nvidia.ko` after the module's own release function has returned (`gb10_pi_release()`),
  so no instruction of `nvidia-drm.ko` runs after the count reaches zero. The descriptor counts the
  holds taken on it (one object can be exported twice) and a release without a hold does nothing.
  The behaviour is modelled in `tests/pageimport_test.sh` (two holds, one release, the quiesce still
  refused; a quiesce that closes the gate; a refused hold takes nothing; two exports of one object) and
  the wiring is checked in `tests/prime_import_test.sh` (D6).

**Coverage.** `tests/pageimport_test.sh` gates the lines of the core header at 100 percent with
llvm-cov and tests the gate (a header with a line that never runs must fail it). Branch coverage is
reported and not gated, on purpose: the argument guards test several pointers on one line, and a
branch gate would need a test for each pointer. The risk a branch gate guards against is covered by
the mutants instead (about sixty, one for each decision of the core, each of which must make the
tests fail).

**Kit.** The rc one-shot stops each probe after `prime_import_testboot_probe_timeout` seconds
(120; 20 per probe of the wire loop; CUDA 300, Vulkan 120; each with `-k 5`) and records a hang as a
fail, for the reverse probe too. It requests a dead-man restart at the start
(`prime_import_testboot_deadman`, default 60 minutes, longer than the bounded worst case of about
32 minutes; 0 disables), checks that the request is really pending (a fail row otherwise), and
cancels it at the done row. A probe stuck inside the kernel cannot be killed by a signal; the
dead-man restart is what ends that run. The kit that boots is built from `git archive <reviewed commit>` extracted into a fresh directory and run with `make-be.sh -V <commit>`: `make-be.sh` refuses a git work tree with uncommitted changes (and one whose `make-be.sh` the repository does not track), and a kit that is neither a git work tree nor a `git archive` (its `KIT-COMMIT` file carries the commit through `export-subst`); a `-V` is checked against that commit and refused when it differs (in an archive the commit is the one `KIT-COMMIT` records: a record, not a proof of the content; in a git work tree the content of every installed file is compared with the committed one). It records the commit in the boot environment, the run records it in the row `kit-version`, and the staged `nvidia-drm.ko` is read before anything is cloned: the guard must be declared after the driver module (the tool needs python3 and `readelf`, which on FreeBSD is the ELF Tool Chain one). `PRIME_MNT` sets the mount point of the clone; `PRIME_ALLOW_DIRTY=1` and `PRIME_KO_ORDER_TOOL` are test hooks. If anything fails after the clone exists, `make-be.sh` unmounts and removes the half-built boot environment (and says so, or says it could not; the snapshot the clone was made from stays on the base boot environment, see `bectl list -s`). `make-be.sh` turns off every other `*_testboot_enable` in the
clone of the base boot environment (`/etc/rc.conf`, `/etc/rc.conf.local` and every file under
`/etc/rc.conf.d`) and removes an `nvidia-uvm.ko` the base left in
`/boot/modules.nvtest` unless `-u` gives one. The kit runs from rc, before sddm and any user session,
so the `xorg` and `wayfire` rows are skips in this boot and `prime_import_testboot_wayfire_cmd` stays
unset; a second-stage Wayfire step after login is a follow-up.

What to expect on the day: the machine boots into the test boot environment and the kit runs while
the boot is held, for about 30 minutes (a hang ends in the dead-man restart after 60). After the done
row it stays in the test boot environment until the next reboot. A missing run directory under
`~/work/gb10/logs/prime-import-<stamp>` means the boot died before the rc script. Read a run with
`tests/prime-import-testboot/summarize.sh <run directory>`: 0 passed, 1 failed, 3 finished but the
import or the wire measurement was skipped.

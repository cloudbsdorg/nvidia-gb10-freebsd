--- nvidia-drm/nvidia-drm-gem-nvkms-memory.c.orig
+++ nvidia-drm/nvidia-drm-gem-nvkms-memory.c
@@ -34,6 +34,138 @@
 #include <linux/io.h>
 #if defined(NV_BSD)
 #include <vm/vm_pageout.h>
+#endif
+#if !defined(NV_LINUX)
+#include <vm/vm_phys.h>
+#endif
+
+#if !defined(NV_LINUX)
+/*
+ * FreeBSD: a user mapping of video memory needs vm_pages.
+ *
+ * linuxkpi's vmf_insert_pfn() maps a pfn through PHYS_TO_VM_PAGE() and
+ * returns VM_FAULT_SIGBUS when no vm_page exists for it; its pager turns
+ * that into VM_PAGER_BAD, which vm_fault() takes as "handle this fault the
+ * normal way" and satisfies with a zero-filled RAM page in the mapping's
+ * object.  A PCIe BAR has vm_pages only while a fictitious range is
+ * registered for it (ttm registers its VRAM aperture; nothing did so for
+ * nvidia-drm).  So every CPU write to a video-memory dumb buffer went to
+ * anonymous RAM that died with the mapping, the GPU scanned out untouched
+ * video memory and the monitor stayed black (amp001, 2026-11-19; DTrace:
+ * lkpi_vmf_insert_pfn_prot_locked returned 2 for every page,
+ * linux_cdev_pager_populate 1, pmap_enter mapped RAM pages, and
+ * vm.phys_fictitious_segs listed only the other card's aperture).
+ *
+ * The mapped BAR window is registered as fictitious pages while the object
+ * is physically mapped.  The attribute given at registration is only the
+ * pages' initial one: the fault path sets the mapping's own (see
+ * __nv_drm_gem_nvkms_mmap).
+ *
+ * vm_phys_fictitious_reg_range() does not report an overlap: its tree
+ * comparator panics on one, and on VM_PHYSSEG_DENSE machines (amd64) a
+ * window inside vm_page_array is initialised in place, wiping live
+ * vm_pages, with no check at all.  So the window is probed first: a page
+ * that is already fictitious AND records this physical address belongs to
+ * a registration that exists (an in-array entry for a hole is never
+ * initialised on amd64, so its flags are boot-time garbage; the address
+ * check is what makes the probe trustworthy).  All pages fictitious means
+ * another object's memory maps to the same window (or, on amd64, an
+ * earlier owner's in-array pages, which unregistration leaves initialised):
+ * the pages are used without being owned.  A mix is a partial overlap and
+ * the map is refused.  An owner never unregisters pages another object
+ * still has in use: vm_phys_fictitious_unreg_range() frees the vm_pages,
+ * and it panics on a range it did not register.
+ *
+ * Assumed, not verified against the RM: every NVKMS_KAPI_MAPPING_TYPE_USER
+ * mapMemory() returns its own BAR window, so two live objects never share
+ * one.  Under that assumption the sharing path is never taken; without it
+ * (two objects mapping concurrently, or a sharer that has not faulted yet
+ * when the owner frees) a driver-wide refcounted window list would be
+ * needed.  If "sharing them" ever appears in the log, that is the moment.
+ */
+static int __nv_drm_gem_nvkms_bsd_pages_register(
+    struct nv_drm_gem_nvkms_memory *nv_nvkms_memory)
+{
+    struct nv_drm_device *nv_dev = nv_nvkms_memory->base.nv_dev;
+    vm_paddr_t start = (vm_paddr_t)(uintptr_t)nv_nvkms_memory->pPhysicalAddress;
+    vm_paddr_t end = start + nv_nvkms_memory->base.base.size;
+    vm_paddr_t pa;
+    vm_page_t m;
+    unsigned long fictitious = 0, pages = 0;
+    int error;
+
+    if (end <= start || (start & PAGE_MASK) != 0) {
+        NV_DRM_DEV_LOG_ERR(nv_dev,
+            "Video memory window 0x%llx-0x%llx is not page aligned",
+            (unsigned long long)start, (unsigned long long)end);
+        return -EINVAL;
+    }
+
+    for (pa = start; pa < end; pa += PAGE_SIZE) {
+        pages++;
+        m = PHYS_TO_VM_PAGE(pa);
+        if (m != NULL && (m->flags & PG_FICTITIOUS) != 0 &&
+            VM_PAGE_TO_PHYS(m) == pa) {
+            fictitious++;
+        }
+    }
+
+    if (fictitious == pages) {
+        NV_DRM_DEV_LOG_INFO(nv_dev,
+            "Video memory 0x%llx-0x%llx already has pages; sharing them",
+            (unsigned long long)start, (unsigned long long)end);
+        return 0;
+    }
+    if (fictitious != 0) {
+        NV_DRM_DEV_LOG_ERR(nv_dev,
+            "Video memory 0x%llx-0x%llx overlaps registered pages (%lu of %lu)",
+            (unsigned long long)start, (unsigned long long)end,
+            fictitious, pages);
+        return -EBUSY;
+    }
+
+    error = vm_phys_fictitious_reg_range(start, end, VM_MEMATTR_UNCACHEABLE);
+    if (error != 0) {
+        NV_DRM_DEV_LOG_ERR(nv_dev,
+            "Failed to register pages for video memory 0x%llx-0x%llx: %d",
+            (unsigned long long)start, (unsigned long long)end, error);
+        return -ENOMEM;
+    }
+    nv_nvkms_memory->bsd_pages_registered = true;
+    return 0;
+}
+
+static void __nv_drm_gem_nvkms_bsd_pages_unregister(
+    struct nv_drm_gem_nvkms_memory *nv_nvkms_memory)
+{
+    struct nv_drm_device *nv_dev = nv_nvkms_memory->base.nv_dev;
+    vm_paddr_t start = (vm_paddr_t)(uintptr_t)nv_nvkms_memory->pPhysicalAddress;
+    vm_paddr_t end = start + nv_nvkms_memory->base.base.size;
+    vm_paddr_t pa;
+    vm_page_t m;
+
+    if (!nv_nvkms_memory->bsd_pages_registered) {
+        return;
+    }
+    nv_nvkms_memory->bsd_pages_registered = false;
+
+    /*
+     * This object's own mappings are gone (each held a reference to it),
+     * so a page still in a VM object belongs to another object sharing the
+     * window: keep the pages rather than free them under that mapping.
+     */
+    for (pa = start; pa < end; pa += PAGE_SIZE) {
+        m = PHYS_TO_VM_PAGE(pa);
+        if (m != NULL && m->object != NULL) {
+            NV_DRM_DEV_LOG_INFO(nv_dev,
+                "Video memory 0x%llx-0x%llx still mapped; keeping its pages",
+                (unsigned long long)start, (unsigned long long)end);
+            return;
+        }
+    }
+
+    vm_phys_fictitious_unreg_range(start, end);
+}
 #endif
 
 static void __nv_drm_gem_nvkms_memory_free(struct nv_drm_gem_object *nv_gem)
@@ -47,6 +179,10 @@
             iounmap(nv_nvkms_memory->pWriteCombinedIORemapAddress);
         }
 
+#if !defined(NV_LINUX)
+        __nv_drm_gem_nvkms_bsd_pages_unregister(nv_nvkms_memory);
+#endif
+
         nvKms->unmapMemory(nv_dev->pDevice,
                            nv_nvkms_memory->base.pMemory,
                            NVKMS_KAPI_MAPPING_TYPE_USER,
@@ -78,8 +214,23 @@
        return ret;
     }
 
-    return drm_gem_mmap_obj(&nv_gem->base,
+    ret = drm_gem_mmap_obj(&nv_gem->base,
                 drm_vma_node_size(&nv_gem->base.vma_node) << PAGE_SHIFT, vma);
+#if !defined(NV_LINUX)
+    /*
+     * Video memory is reached through a PCIe BAR and must be mapped
+     * write-combining, as Linux's drm_gem_mmap_obj() does.  On FreeBSD the
+     * mapping kept a write-back attribute: harmless on x86, where the BAR's
+     * MTRR makes it uncached, but on arm64 the CPU then caches the BAR, so
+     * writes never reach video memory (amp001, 2026-11-18: a dumb buffer
+     * read back zeros through a fresh mapping; DTrace showed every page set
+     * VM_MEMATTR_WRITE_BACK).  System-memory objects keep their attribute.
+     */
+    if (ret == 0 && nv_nvkms_memory->pages_count == 0) {
+        vma->vm_page_prot = pgprot_writecombine(vma->vm_page_prot);
+    }
+#endif
+    return ret;
 }
 
 static vm_fault_t __nv_drm_gem_nvkms_handle_vma_fault(
@@ -94,11 +245,27 @@
     unsigned long page_offset, pfn;
     vm_fault_t ret;
 
+#if defined(NV_LINUX)
     page_offset = vmf->pgoff - drm_vma_node_start(&gem->vma_node);
+#else
+    /*
+     * linuxkpi's pager passes vmf->pgoff = 0 and vmf->address = the page
+     * index within the mapping (as a byte offset, vma->vm_start = 0), and
+     * its vmf_insert_pfn() uses the pfn as given.  The GEM page index is
+     * therefore the faulting address relative to the mapping: the same
+     * arithmetic lkpi_vmf_insert_pfn_prot_locked() uses for its pindex.
+     * (0 - drm_vma_node_start() would wrap to a huge index.)
+     */
+    page_offset = (address - vma->vm_start) >> PAGE_SHIFT;
+#endif
 
     if (nv_nvkms_memory->pages_count == 0) {
         pfn = (unsigned long)(uintptr_t)nv_nvkms_memory->pPhysicalAddress;
         pfn >>= PAGE_SHIFT;
+        /* An index past the buffer is the caller's error, not a panic. */
+        if (page_offset >= (gem->size >> PAGE_SHIFT)) {
+            return VM_FAULT_SIGBUS;
+        }
 #if defined(NV_LINUX)
         /*
          * FreeBSD doesn't set pgoff. We instead have pfn be the base physical
@@ -108,10 +275,12 @@
          * vmf->virtual_address. Then we turn the virtual address
          * into a physical page number.
          */
-        pfn += page_offset;
 #endif
+        pfn += page_offset;
     } else {
-        BUG_ON(page_offset >= nv_nvkms_memory->pages_count);
+        if (page_offset >= nv_nvkms_memory->pages_count) {
+            return VM_FAULT_SIGBUS;
+        }
         pfn = page_to_pfn(nv_nvkms_memory->pages[page_offset]);
     }
 
@@ -170,8 +339,20 @@
             "Failed to map NvKmsKapiMemory 0x%p",
             pMemory);
         ret = -ENOMEM;
+        goto done;
+    }
+
+#if !defined(NV_LINUX)
+    ret = __nv_drm_gem_nvkms_bsd_pages_register(nv_nvkms_memory);
+    if (ret) {
+        nvKms->unmapMemory(nv_dev->pDevice,
+                           pMemory,
+                           NVKMS_KAPI_MAPPING_TYPE_USER,
+                           nv_nvkms_memory->pPhysicalAddress);
+        nv_nvkms_memory->pPhysicalAddress = NULL;
         goto done;
     }
+#endif
 
     nv_nvkms_memory->pWriteCombinedIORemapAddress = ioremap_wc(
             (uintptr_t)nv_nvkms_memory->pPhysicalAddress,
@@ -297,6 +478,9 @@
     nv_nvkms_memory->pPhysicalAddress = NULL;
     nv_nvkms_memory->pWriteCombinedIORemapAddress = NULL;
     nv_nvkms_memory->physically_mapped = false;
+#if !defined(NV_LINUX)
+    nv_nvkms_memory->bsd_pages_registered = false;
+#endif
 
     if (!nvKms->isVidmem(pMemory) &&
         !nvKms->getMemoryPages(nv_dev->pDevice,

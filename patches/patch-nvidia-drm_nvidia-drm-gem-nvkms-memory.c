--- nvidia-drm/nvidia-drm-gem-nvkms-memory.c.orig
+++ nvidia-drm/nvidia-drm-gem-nvkms-memory.c
@@ -78,8 +78,23 @@
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
@@ -94,11 +109,27 @@
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
@@ -108,10 +139,12 @@
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
 

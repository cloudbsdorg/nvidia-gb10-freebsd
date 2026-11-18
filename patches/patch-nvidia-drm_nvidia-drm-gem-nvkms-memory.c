--- nvidia-drm/nvidia-drm-gem-nvkms-memory.c.orig
+++ nvidia-drm/nvidia-drm-gem-nvkms-memory.c
@@ -94,11 +94,27 @@
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
@@ -108,10 +124,12 @@
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
 

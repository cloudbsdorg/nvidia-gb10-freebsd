--- nvidia-drm/nvidia-drm-gem-nvkms-memory.c.orig	2026-11-24 03:21:15.421403000 +0000
+++ nvidia-drm/nvidia-drm-gem-nvkms-memory.c	2026-11-24 03:21:15.453675000 +0000
@@ -227,6 +227,18 @@
      * VM_MEMATTR_WRITE_BACK).  System-memory objects keep their attribute.
      */
     if (ret == 0 && nv_nvkms_memory->pages_count == 0) {
+        vma->vm_page_prot = pgprot_writecombine(vma->vm_page_prot);
+    }
+    /*
+     * GB10: "system memory" for display is the firmware scanout carveout,
+     * which the OS layer maps non-cacheable in the kernel and describes
+     * with fictitious pages.  The display engine cannot snoop the CPU
+     * cache, and a cacheable user alias of a non-cacheable kernel mapping
+     * is a mismatched-attribute alias on arm64, so map it the same way.
+     */
+    if (ret == 0 && nv_nvkms_memory->pages_count != 0 &&
+        nv_nvkms_memory->pages[0] != NULL &&
+        (nv_nvkms_memory->pages[0]->flags & PG_FICTITIOUS) != 0) {
         vma->vm_page_prot = pgprot_writecombine(vma->vm_page_prot);
     }
 #endif
@@ -281,6 +293,10 @@
         if (page_offset >= nv_nvkms_memory->pages_count) {
             return VM_FAULT_SIGBUS;
         }
+        /* No page behind the index is an error, not a NULL dereference. */
+        if (nv_nvkms_memory->pages[page_offset] == NULL) {
+            return VM_FAULT_SIGBUS;
+        }
         pfn = page_to_pfn(nv_nvkms_memory->pages[page_offset]);
     }
 

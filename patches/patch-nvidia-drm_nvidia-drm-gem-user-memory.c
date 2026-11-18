--- nvidia-drm/nvidia-drm-gem-user-memory.c.orig
+++ nvidia-drm/nvidia-drm-gem-user-memory.c
@@ -140,12 +140,28 @@
 {
     struct nv_drm_gem_user_memory *nv_user_memory = to_nv_user_memory(nv_gem);
     unsigned long address = vmf->address;
+#if defined(NV_LINUX)
     struct drm_gem_object *gem = vma->vm_private_data;
+#endif
     unsigned long page_offset;
     unsigned long pfn;
 
+#if defined(NV_LINUX)
     page_offset = vmf->pgoff - drm_vma_node_start(&gem->vma_node);
-    BUG_ON(page_offset >= nv_user_memory->pages_count);
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
+    if (page_offset >= nv_user_memory->pages_count) {
+        return VM_FAULT_SIGBUS;
+    }
     pfn = page_to_pfn(nv_user_memory->pages[page_offset]);
 
 #if !defined(NV_LINUX)

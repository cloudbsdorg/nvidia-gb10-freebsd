--- nvidia/nvidia_subr.c.orig	2026-11-24 03:21:15.411317000 +0000
+++ nvidia/nvidia_subr.c	2026-11-24 03:21:15.453463000 +0000
@@ -1680,6 +1680,93 @@
     free(at, M_NVIDIA);
 
     return NV_ERR_NO_MEMORY;
+}
+
+/*
+ * vm_pages for an aliased carveout range.
+ *
+ * nvidia-drm asks for the "struct page" array of every system-memory
+ * NvKmsKapiMemory (nv_get_phys_pages()) and maps a dumb buffer to userspace
+ * one page at a time with vmf_insert_pfn(), which needs a vm_page for the
+ * pfn.  Carveout memory is outside vm_phys_segs and has none (BOOT 109:
+ * NULL page -> panic in __nv_drm_gem_nvkms_handle_vma_fault), so register
+ * fictitious pages for the range the first time somebody asks.  LUT and
+ * other kernel-only aliases never ask and never pay for it.
+ *
+ * vm_phys_fictitious_reg_range() panics on an overlap instead of reporting
+ * it, so probe first: all pages already fictitious for this address means a
+ * registration we could not remove earlier (below) covers the range; use it
+ * without owning it.  A partial overlap is refused.
+ */
+static int nv_alias_fict_register(
+    struct nvidia_alloc *at
+)
+{
+    vm_paddr_t start = (vm_paddr_t)at->pte_array[0].physical_address;
+    vm_paddr_t end = start + (vm_paddr_t)at->num_pages * PAGE_SIZE;
+    vm_paddr_t pa;
+    vm_page_t m;
+    unsigned long fict = 0;
+    int error;
+
+    if (at->flags.fict_owned)
+        return 0;
+
+    for (pa = start; pa < end; pa += PAGE_SIZE) {
+        m = PHYS_TO_VM_PAGE(pa);
+        if (m != NULL && (m->flags & PG_FICTITIOUS) != 0 &&
+            VM_PAGE_TO_PHYS(m) == pa)
+            fict++;
+    }
+
+    if (fict == at->num_pages)
+        return 0;
+    if (fict != 0) {
+        printf("nvidia: carveout 0x%jx-0x%jx overlaps registered pages "
+            "(%lu of %u)\n", (uintmax_t)start, (uintmax_t)end, fict,
+            at->num_pages);
+        return EBUSY;
+    }
+
+    error = vm_phys_fictitious_reg_range(start, end, at->attr);
+    if (error != 0) {
+        printf("nvidia: carveout 0x%jx-0x%jx: fictitious pages: error %d\n",
+            (uintmax_t)start, (uintmax_t)end, error);
+        return error;
+    }
+    at->flags.fict_owned = NV_TRUE;
+
+    return 0;
+}
+
+static void nv_alias_fict_unregister(
+    struct nvidia_alloc *at
+)
+{
+    vm_paddr_t start = (vm_paddr_t)at->pte_array[0].physical_address;
+    vm_paddr_t end = start + (vm_paddr_t)at->num_pages * PAGE_SIZE;
+    vm_paddr_t pa;
+    vm_page_t m;
+
+    if (!at->flags.fict_owned)
+        return;
+    at->flags.fict_owned = NV_FALSE;
+
+    /*
+     * A page still in a VM object is still mapped somewhere; freeing its
+     * vm_page under that mapping would be worse than keeping the range
+     * registered.
+     */
+    for (pa = start; pa < end; pa += PAGE_SIZE) {
+        m = PHYS_TO_VM_PAGE(pa);
+        if (m != NULL && m->object != NULL) {
+            printf("nvidia: carveout 0x%jx-0x%jx still mapped; keeping "
+                "its pages\n", (uintmax_t)start, (uintmax_t)end);
+            return;
+        }
+    }
+
+    vm_phys_fictitious_unreg_range(start, end);
 }
 
 static NvS32 nv_free_aliased_pages(
@@ -1688,6 +1775,8 @@
 {
     struct nvidia_alloc *at = private;
 
+    nv_alias_fict_unregister(at);
+
     NV_VM_OBJECT_DEALLOCATE(at->object);
     NV_SGLIST_FREE(at->sg_list);
 
@@ -2469,6 +2558,7 @@
 {
     nvidia_alloc_t *at = pAllocPrivate;
     vm_page_t *pages = (vm_page_t *)pPages;
+    vm_paddr_t pa;
     NvU32 page_count;
     int i;
 
@@ -2476,10 +2566,28 @@
         return NV_ERR_INVALID_ARGUMENT;
     }
 
+    /* Carveout memory has no vm_page until we make some (gb10). */
+    if (at->flags.aliased && nv_alias_fict_register(at) != 0) {
+        return NV_ERR_NO_MEMORY;
+    }
+
     page_count = NV_MIN(*pNumPages, at->num_pages);
 
     for (i = 0; i < page_count; i++) {
-        pages[i] = PHYS_TO_VM_PAGE(at->pte_array[i].physical_address);
+        /*
+         * A contiguous allocation has one pte_array entry, not one per
+         * page: indexing it by page read past the array.
+         */
+        if (at->alloc_type_contiguous) {
+            pa = (vm_paddr_t)at->pte_array[0].physical_address +
+                (vm_paddr_t)i * PAGE_SIZE;
+        } else {
+            pa = (vm_paddr_t)at->pte_array[i].physical_address;
+        }
+        pages[i] = PHYS_TO_VM_PAGE(pa);
+        if (pages[i] == NULL) {
+            return NV_ERR_INVALID_STATE;
+        }
     }
 
     *pNumPages = page_count;

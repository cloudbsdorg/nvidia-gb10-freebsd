--- nvidia/nvidia_subr.c.orig
+++ nvidia/nvidia_subr.c
@@ -2353,6 +2353,7 @@
 {
     nvidia_alloc_t *at = pAllocPrivate;
     vm_page_t *pages = (vm_page_t *)pPages;
+    vm_paddr_t pa;
     NvU32 page_count;
     int i;
 
@@ -2363,7 +2364,30 @@
     page_count = NV_MIN(*pNumPages, at->num_pages);
 
     for (i = 0; i < page_count; i++) {
-        pages[i] = PHYS_TO_VM_PAGE(at->pte_array[i].physical_address);
+        /*
+         * A contiguous allocation has one pte_array entry, not one per
+         * page: indexing the array by page read past its end and handed
+         * the caller the page after the allocation.  This is wrong on
+         * every card, not only on the ones that use the GB10 carveout, so
+         * it is fixed here and not behind a GB10 condition.
+         */
+        if (at->alloc_type_contiguous) {
+            pa = (vm_paddr_t)at->pte_array[0].physical_address +
+                (vm_paddr_t)i * PAGE_SIZE;
+        } else {
+            pa = (vm_paddr_t)at->pte_array[i].physical_address;
+        }
+        pages[i] = PHYS_TO_VM_PAGE(pa);
+        if (pages[i] == NULL) {
+            /*
+             * A physical address that is not managed memory has no
+             * vm_page.  Handing the caller a NULL page panics the
+             * nvidia-drm fault handler (vmf_insert_pfn() with a NULL
+             * page), so refuse the request instead: the caller turns
+             * NV_ERR_INVALID_STATE into VM_FAULT_SIGBUS.
+             */
+            return NV_ERR_INVALID_STATE;
+        }
     }
 
     *pNumPages = page_count;

--- nvidia/nvidia_subr.c.orig	2026-11-25 09:33:01.431300000 +0000
+++ nvidia/nvidia_subr.c	2026-11-25 09:36:05.499760000 +0000
@@ -1336,6 +1336,58 @@
 SYSCTL_INT(_hw, OID_AUTO, nvidia_gb10_dma_bits, CTLFLAG_RWTUN,
     &nv_gb10_dma_bits, 0,
     "GB10 diagnostic: cap RM system memory below 2^bits (0 = off)");
+
+/*
+ * GB10: without video memory every CUDA buffer is system memory, asked for
+ * as single 4 KiB pages: 16 million of them for a 60 GiB model.  Giving
+ * each page its own kmem_alloc_contig() costs a piece of kernel address
+ * space and a mapping per page, and at free a vmem_xfree() and a TLB
+ * invalidation on every CPU per page (minutes for one model).  Write-back
+ * pages need no private mapping: take a wired page and use its direct-map
+ * address.  nv_free_system_pages() tells the two kinds apart by that
+ * address.  Loader/kenv tunable and run-time sysctl:
+ * hw.nvidia_gb10_dmap_pages (0 = old behaviour, for comparison).
+ */
+#if defined(__aarch64__)
+static int nv_gb10_dmap_pages = 1;
+SYSCTL_INT(_hw, OID_AUTO, nvidia_gb10_dmap_pages, CTLFLAG_RWTUN,
+    &nv_gb10_dmap_pages, 0,
+    "GB10: 4 KiB write-back system pages come from the direct map (1 = on)");
+
+static vm_offset_t nv_alloc_dmap_page(vm_paddr_t high_addr, NvBool zero)
+{
+    vm_page_t m;
+
+    m = vm_page_alloc_noobj(VM_ALLOC_WIRED | VM_ALLOC_NOWAIT |
+        (zero ? VM_ALLOC_ZERO : 0));
+    if (m == NULL)
+        return 0;
+    if (VM_PAGE_TO_PHYS(m) + PAGE_SIZE - 1 > high_addr ||
+        !PHYS_IN_DMAP(VM_PAGE_TO_PHYS(m))) {
+        vm_page_unwire_noq(m);
+        vm_page_free(m);
+        return 0;
+    }
+    return (vm_offset_t)PHYS_TO_DMAP(VM_PAGE_TO_PHYS(m));
+}
+#endif
+
+/* Free one unit of a non-contiguous allocation, whichever way it was made. */
+static void nv_free_system_unit(vm_offset_t address, vm_size_t unit)
+{
+#if defined(__aarch64__)
+    if (unit == PAGE_SIZE && VIRT_IN_DMAP(address)) {
+        vm_page_t m = PHYS_TO_VM_PAGE(DMAP_TO_PHYS(address));
+
+        vm_page_unwire_noq(m);
+        vm_page_free(m);
+        malloc_type_freed(M_NVIDIA, unit);
+        return;
+    }
+#endif
+    NV_KMEM_FREE(address, unit);
+    malloc_type_freed(M_NVIDIA, unit);
+}
 
 /*
  * GB10: the RM passes the page size it will map an allocation with on the
@@ -1503,8 +1555,15 @@
     vm_size_t unit = nv_alloc_unit(page_size);
     uint32_t ppu = unit / PAGE_SIZE;    /* pages per unit */
     uint32_t j;
+#if defined(__aarch64__)
+    NvBool dmap;
+#endif
 
     attr = _convert_caching_to_attr(cache_type);
+#if defined(__aarch64__)
+    dmap = (nv_gb10_dmap_pages != 0 && unit == PAGE_SIZE &&
+        attr == VM_MEMATTR_WRITE_BACK);
+#endif
 
     at = malloc(sizeof(nvidia_alloc_t), M_NVIDIA, (M_WAITOK | M_ZERO));
     if (!at)
@@ -1529,8 +1588,22 @@
      * described.  The first page of each unit owns the unit.
      */
     for (i = 0; i < count; i += ppu) {
-        address = NV_KMEM_ALLOC_CONTIG(unit, flags, 0,
-                high_addr, unit, 0, attr);
+        address = 0;
+#if defined(__aarch64__)
+        /*
+         * No free page right now, or one above high_addr: the kmem path
+         * below reclaims and honours the limit; stop trying the short cut
+         * for the rest of this allocation.
+         */
+        if (dmap) {
+            address = nv_alloc_dmap_page(high_addr, zero);
+            if (!address)
+                dmap = NV_FALSE;
+        }
+#endif
+        if (!address)
+            address = NV_KMEM_ALLOC_CONTIG(unit, flags, 0,
+                    high_addr, unit, 0, attr);
         if (!address) {
             status = ENOMEM;
             goto failed;
@@ -1585,8 +1658,7 @@
     for (i = 0; i < count; i += ppu) {
         if (at->pte_array[i].virtual_address == 0)
             break;
-        NV_KMEM_FREE(at->pte_array[i].virtual_address, unit);
-        malloc_type_freed(M_NVIDIA, unit);
+        nv_free_system_unit(at->pte_array[i].virtual_address, unit);
     }
 
     free(at->pte_array, M_NVIDIA);
@@ -1611,10 +1683,8 @@
     if (at->attr != VM_MEMATTR_WRITE_BACK)
         flush_cpu_cache();
 
-    for (i = 0; i < count; i += ppu) {
-        NV_KMEM_FREE(at->pte_array[i].virtual_address, ptoa(ppu));
-        malloc_type_freed(M_NVIDIA, ptoa(ppu));
-    }
+    for (i = 0; i < count; i += ppu)
+        nv_free_system_unit(at->pte_array[i].virtual_address, ptoa(ppu));
 
     free(at->pte_array, M_NVIDIA);
     free(at, M_NVIDIA);

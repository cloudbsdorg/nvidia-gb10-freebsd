--- nvidia/nvidia_subr.c.orig	2026-11-26 02:09:13.793306000 +0000
+++ nvidia/nvidia_subr.c	2026-11-26 02:09:38.978730000 +0000
@@ -1370,17 +1370,75 @@
     }
     return (vm_offset_t)PHYS_TO_DMAP(VM_PAGE_TO_PHYS(m));
 }
+
+/*
+ * GB10: the same for units above 4 KiB (64 KiB by default, the GPU big
+ * page): an aligned run of wired pages, used through the direct map.  A
+ * kmem_alloc_contig() per unit costs kernel address space, a mapping and a
+ * TLB shootdown at free, and on fragmented memory every miss of the buddy
+ * allocator runs vm_page_reclaim_contig() for that one unit, a scan over
+ * all of RAM (a vLLM start spent 47 minutes in it).  Here a miss reclaims
+ * one aligned 2 MiB run instead, which the next 32 units are carved from,
+ * and only when that fails does the caller fall back to the kmem path.
+ * Loader/kenv tunable and run-time sysctl hw.nvidia_gb10_dmap_units
+ * (0 = old behaviour, for comparison).
+ */
+static int nv_gb10_dmap_units = 1;
+SYSCTL_INT(_hw, OID_AUTO, nvidia_gb10_dmap_units, CTLFLAG_RWTUN,
+    &nv_gb10_dmap_units, 0,
+    "GB10: write-back units above 4 KiB come from the direct map (1 = on)");
+
+#define NV_GB10_RECLAIM_RUN (2UL << 20)
+
+static vm_offset_t nv_alloc_dmap_unit(vm_size_t unit, vm_paddr_t high_addr,
+    NvBool zero, NvBool *may_reclaim)
+{
+    vm_page_t m;
+    vm_paddr_t pa;
+    int req = VM_ALLOC_WIRED | VM_ALLOC_NOWAIT | VM_ALLOC_NORECLAIM |
+        (zero ? VM_ALLOC_ZERO : 0);
+    int tries;
+
+    for (tries = 0; tries < 2; tries++) {
+        m = vm_page_alloc_noobj_contig(req, atop(unit), 0, high_addr,
+            unit, 0, VM_MEMATTR_DEFAULT);
+        if (m != NULL)
+            break;
+        if (tries > 0 || !*may_reclaim)
+            return 0;
+        if (vm_page_reclaim_contig(VM_ALLOC_NOWAIT,
+            atop(MAX(unit, NV_GB10_RECLAIM_RUN)), 0, high_addr,
+            MAX(unit, NV_GB10_RECLAIM_RUN), 0) != 0)
+            *may_reclaim = NV_FALSE;
+    }
+    pa = VM_PAGE_TO_PHYS(m);
+    if (!PHYS_IN_DMAP(pa) || !PHYS_IN_DMAP(pa + unit - 1)) {
+        vm_size_t i;
+
+        for (i = 0; i < atop(unit); i++) {
+            vm_page_unwire_noq(&m[i]);
+            vm_page_free(&m[i]);
+        }
+        return 0;
+    }
+    return (vm_offset_t)PHYS_TO_DMAP(pa);
+}
 #endif
 
 /* Free one unit of a non-contiguous allocation, whichever way it was made. */
 static void nv_free_system_unit(vm_offset_t address, vm_size_t unit)
 {
 #if defined(__aarch64__)
-    if (unit == PAGE_SIZE && VIRT_IN_DMAP(address)) {
-        vm_page_t m = PHYS_TO_VM_PAGE(DMAP_TO_PHYS(address));
+    if (VIRT_IN_DMAP(address)) {
+        vm_offset_t va;
 
-        vm_page_unwire_noq(m);
-        vm_page_free(m);
+        /* a unit from nv_alloc_dmap_page() or nv_alloc_dmap_unit() */
+        for (va = address; va < address + unit; va += PAGE_SIZE) {
+            vm_page_t m = PHYS_TO_VM_PAGE(DMAP_TO_PHYS(va));
+
+            vm_page_unwire_noq(m);
+            vm_page_free(m);
+        }
         malloc_type_freed(M_NVIDIA, unit);
         return;
     }
@@ -1556,13 +1614,14 @@
     uint32_t ppu = unit / PAGE_SIZE;    /* pages per unit */
     uint32_t j;
 #if defined(__aarch64__)
-    NvBool dmap;
+    NvBool dmap, may_reclaim;
 #endif
 
     attr = _convert_caching_to_attr(cache_type);
 #if defined(__aarch64__)
-    dmap = (nv_gb10_dmap_pages != 0 && unit == PAGE_SIZE &&
-        attr == VM_MEMATTR_WRITE_BACK);
+    dmap = (attr == VM_MEMATTR_WRITE_BACK &&
+        (unit == PAGE_SIZE ? nv_gb10_dmap_pages : nv_gb10_dmap_units) != 0);
+    may_reclaim = NV_TRUE;
 #endif
 
     at = malloc(sizeof(nvidia_alloc_t), M_NVIDIA, (M_WAITOK | M_ZERO));
@@ -1595,10 +1654,14 @@
          * below reclaims and honours the limit; stop trying the short cut
          * for the rest of this allocation.
          */
-        if (dmap) {
+        if (dmap && unit == PAGE_SIZE) {
             address = nv_alloc_dmap_page(high_addr, zero);
             if (!address)
                 dmap = NV_FALSE;
+        } else if (dmap) {
+            /* a miss costs little; keep trying for the next unit */
+            address = nv_alloc_dmap_unit(unit, high_addr, zero,
+                &may_reclaim);
         }
 #endif
         if (!address)

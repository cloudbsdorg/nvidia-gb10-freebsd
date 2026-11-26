--- nvidia/nvidia_subr.c.orig	2026-11-26 15:38:33.547822000 +0000
+++ nvidia/nvidia_subr.c	2026-11-26 15:38:33.562371000 +0000
@@ -1420,27 +1420,48 @@
     return MAX(unit, (vm_size_t)run);
 }
 
+/*
+ * *run is the reclaim run for the rest of this allocation, 0 = do not
+ * reclaim.  BOOT 131: a failed run used to stop reclaiming for the whole
+ * allocation, and every later unit then went to kmem_alloc_contig(), which
+ * runs its own reclaim scan per 64 KiB unit (~16 k scans, up to ~18 min of
+ * a vLLM start with an 8 MiB run).  Now a failed run is halved down to the
+ * unit, and a successful one doubles again up to the sysctl, so a large run
+ * only costs when it works and a fragmented machine degrades to small runs
+ * instead of to per-unit kmem allocations.
+ */
 static vm_offset_t nv_alloc_dmap_unit(vm_size_t unit, vm_paddr_t high_addr,
-    vm_memattr_t attr, NvBool zero, NvBool *may_reclaim)
+    vm_memattr_t attr, NvBool zero, vm_size_t *run)
 {
     vm_page_t m;
     vm_paddr_t pa;
     int req = VM_ALLOC_WIRED | VM_ALLOC_NOWAIT | VM_ALLOC_NORECLAIM |
         (zero ? VM_ALLOC_ZERO : 0);
-    vm_size_t run;
-    int tries;
+    vm_size_t max;
 
-    for (tries = 0; tries < 2; tries++) {
+    for (;;) {
         m = vm_page_alloc_noobj_contig(req, atop(unit), 0, high_addr,
             unit, 0, attr);
         if (m != NULL)
             break;
-        if (tries > 0 || !*may_reclaim)
+        if (*run == 0)
             return 0;
-        run = nv_gb10_reclaim_size(unit);
-        if (vm_page_reclaim_contig(VM_ALLOC_NOWAIT, atop(run), 0,
-            high_addr, run, 0) != 0)
-            *may_reclaim = NV_FALSE;
+        if (vm_page_reclaim_contig(VM_ALLOC_NOWAIT, atop(*run), 0,
+            high_addr, *run, 0) == 0) {
+            max = nv_gb10_reclaim_size(unit);
+            if (*run < max)
+                *run = MIN(*run * 2, max);
+            m = vm_page_alloc_noobj_contig(req, atop(unit), 0, high_addr,
+                unit, 0, attr);
+            if (m == NULL)
+                return 0;   /* lost the run to another thread: kmem path */
+            break;
+        }
+        if (*run <= unit) {
+            *run = 0;
+            return 0;
+        }
+        *run /= 2;
     }
     pa = VM_PAGE_TO_PHYS(m);
     if (!PHYS_IN_DMAP(pa) || !PHYS_IN_DMAP(pa + unit - 1)) {
@@ -1645,7 +1666,8 @@
     uint32_t ppu = unit / PAGE_SIZE;    /* pages per unit */
     uint32_t j;
 #if defined(__aarch64__)
-    NvBool dmap, may_reclaim;
+    NvBool dmap;
+    vm_size_t run;
 #endif
 
     attr = _convert_caching_to_attr(cache_type);
@@ -1655,7 +1677,7 @@
     else
         dmap = (nv_gb10_dmap_units >= 2 ||
             (attr == VM_MEMATTR_WRITE_BACK && nv_gb10_dmap_units == 1));
-    may_reclaim = NV_TRUE;
+    run = nv_gb10_reclaim_size(unit);
 #endif
 
     at = malloc(sizeof(nvidia_alloc_t), M_NVIDIA, (M_WAITOK | M_ZERO));
@@ -1695,7 +1717,7 @@
         } else if (dmap) {
             /* a miss costs little; keep trying for the next unit */
             address = nv_alloc_dmap_unit(unit, high_addr, attr, zero,
-                &may_reclaim);
+                &run);
         }
 #endif
         if (!address)

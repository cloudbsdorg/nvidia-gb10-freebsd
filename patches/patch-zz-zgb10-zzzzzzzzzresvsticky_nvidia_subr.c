--- nvidia/nvidia_subr.c.orig	2026-11-26 16:04:05.057024000 +0000
+++ nvidia/nvidia_subr.c	2026-11-26 16:04:19.353005000 +0000
@@ -1419,16 +1419,32 @@
         run = 2UL << 20;
     return MAX(unit, (vm_size_t)run);
 }
+
+/*
+ * hw.nvidia_gb10_dmap_breakresv: let the first try of a unit break a
+ * partly used superpage reservation (vm_reserv_reclaim_contig(), a walk of
+ * the partly populated reservations) before a vm_page_reclaim_contig() scan
+ * over all of RAM.  VM_ALLOC_NORECLAIM only ever skipped that cheap step;
+ * BOOT 132 start 1: 222 kmem fallbacks (which do break reservations) got
+ * their unit without any scan, while the direct-map path scanned 4,489
+ * times (~80 ms each).  0 = old behaviour, for comparison.
+ */
+static int nv_gb10_dmap_breakresv = 1;
+SYSCTL_INT(_hw, OID_AUTO, nvidia_gb10_dmap_breakresv, CTLFLAG_RWTUN,
+    &nv_gb10_dmap_breakresv, 0,
+    "GB10: direct-map units may break a superpage reservation (1 = on)");
 
 /*
  * *run is the reclaim run for the rest of this allocation, 0 = do not
  * reclaim.  BOOT 131: a failed run used to stop reclaiming for the whole
  * allocation, and every later unit then went to kmem_alloc_contig(), which
  * runs its own reclaim scan per 64 KiB unit (~16 k scans, up to ~18 min of
- * a vLLM start with an 8 MiB run).  Now a failed run is halved down to the
- * unit, and a successful one doubles again up to the sysctl, so a large run
- * only costs when it works and a fragmented machine degrades to small runs
- * instead of to per-unit kmem allocations.
+ * a vLLM start with an 8 MiB run).  A failed run is halved down to the
+ * unit.  BOOT 132: doubling again after each success retried the size that
+ * had just failed (746 x "128 KiB fail, 64 KiB ok" in one start, two scans
+ * per unit), and a scan costs the same whatever the run, so the run now
+ * only shrinks within one allocation; the next allocation starts again at
+ * the sysctl.
  */
 static vm_offset_t nv_alloc_dmap_unit(vm_size_t unit, vm_paddr_t high_addr,
     vm_memattr_t attr, NvBool zero, vm_size_t *run)
@@ -1437,8 +1453,13 @@
     vm_paddr_t pa;
     int req = VM_ALLOC_WIRED | VM_ALLOC_NOWAIT | VM_ALLOC_NORECLAIM |
         (zero ? VM_ALLOC_ZERO : 0);
-    vm_size_t max;
 
+    if (nv_gb10_dmap_breakresv != 0) {
+        m = vm_page_alloc_noobj_contig(req & ~VM_ALLOC_NORECLAIM,
+            atop(unit), 0, high_addr, unit, 0, attr);
+        if (m != NULL)
+            goto got;
+    }
     for (;;) {
         m = vm_page_alloc_noobj_contig(req, atop(unit), 0, high_addr,
             unit, 0, attr);
@@ -1448,9 +1469,6 @@
             return 0;
         if (vm_page_reclaim_contig(VM_ALLOC_NOWAIT, atop(*run), 0,
             high_addr, *run, 0) == 0) {
-            max = nv_gb10_reclaim_size(unit);
-            if (*run < max)
-                *run = MIN(*run * 2, max);
             m = vm_page_alloc_noobj_contig(req, atop(unit), 0, high_addr,
                 unit, 0, attr);
             if (m == NULL)
@@ -1463,6 +1481,7 @@
         }
         *run /= 2;
     }
+got:
     pa = VM_PAGE_TO_PHYS(m);
     if (!PHYS_IN_DMAP(pa) || !PHYS_IN_DMAP(pa + unit - 1)) {
         vm_size_t i;

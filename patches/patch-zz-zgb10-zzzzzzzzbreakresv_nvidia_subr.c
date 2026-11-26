--- nvidia/nvidia_subr.c.orig	2026-11-26 16:51:17.678994000 +0000
+++ nvidia/nvidia_subr.c	2026-11-26 16:51:17.693602000 +0000
@@ -1420,6 +1420,23 @@
     return MAX(unit, (vm_size_t)run);
 }
 
+/*
+ * hw.nvidia_gb10_dmap_breakresv: direct-map unit allocations may break a
+ * partly used superpage reservation (vm_reserv_reclaim_contig(), a cheap
+ * walk of the partly populated reservations, run by
+ * vm_page_find_contig_domain() unless VM_ALLOC_NORECLAIM is set).  That
+ * flag never prevented the expensive vm_page_reclaim_contig() scan, which
+ * is our explicit call below; it only skipped the cheap step, which the
+ * kmem_alloc_contig() fallback does take (BOOT 132: 222 kmem fallbacks got
+ * their unit with no scan, the direct-map path scanned 4,489 times at
+ * ~80 ms each).  BOOT 133: ~3 us a call (2.1 s for 638 k calls).  0 = old
+ * behaviour, for comparison.
+ */
+static int nv_gb10_dmap_breakresv = 1;
+SYSCTL_INT(_hw, OID_AUTO, nvidia_gb10_dmap_breakresv, CTLFLAG_RWTUN,
+    &nv_gb10_dmap_breakresv, 0,
+    "GB10: direct-map units may break a superpage reservation (1 = on)");
+
 static vm_offset_t nv_alloc_dmap_unit(vm_size_t unit, vm_paddr_t high_addr,
     vm_memattr_t attr, NvBool zero, NvBool *may_reclaim)
 {
@@ -1430,6 +1447,8 @@
     vm_size_t run;
     int tries;
 
+    if (nv_gb10_dmap_breakresv != 0)
+        req &= ~VM_ALLOC_NORECLAIM;
     for (tries = 0; tries < 2; tries++) {
         m = vm_page_alloc_noobj_contig(req, atop(unit), 0, high_addr,
             unit, 0, attr);

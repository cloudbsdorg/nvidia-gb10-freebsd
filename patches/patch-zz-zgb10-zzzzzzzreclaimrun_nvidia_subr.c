--- nvidia/nvidia_subr.c.orig	2026-11-26 14:13:48.682658000 +0000
+++ nvidia/nvidia_subr.c	2026-11-26 14:14:02.842934000 +0000
@@ -1398,8 +1398,28 @@
     "GB10: units above 4 KiB come from the direct map "
     "(0 = off, 1 = write-back only, 2 = all memory attributes)");
 
-#define NV_GB10_RECLAIM_RUN (2UL << 20)
+/*
+ * Size and alignment of the run a 64 KiB miss reclaims: one
+ * vm_page_reclaim_contig() scans much of RAM (120-170 ms on the debug
+ * kernel with vLLM holding ~110 GiB), and at 2 MiB it buys only 32 units,
+ * so a vLLM start ran ~1,100 scans = ~60 % of its post-load phase
+ * (BOOT 130).  A larger run buys more units per scan.  Run-time sysctl;
+ * values that are not a power of two, or below the unit, mean 2 MiB.
+ */
+static u_long nv_gb10_reclaim_run = 2UL << 20;
+SYSCTL_ULONG(_hw, OID_AUTO, nvidia_gb10_reclaim_run, CTLFLAG_RWTUN,
+    &nv_gb10_reclaim_run, 0,
+    "GB10: bytes reclaimed (and alignment) per direct-map unit miss");
 
+static vm_size_t nv_gb10_reclaim_size(vm_size_t unit)
+{
+    u_long run = nv_gb10_reclaim_run;
+
+    if (run == 0 || !powerof2(run) || run > (1UL << 30))
+        run = 2UL << 20;
+    return MAX(unit, (vm_size_t)run);
+}
+
 static vm_offset_t nv_alloc_dmap_unit(vm_size_t unit, vm_paddr_t high_addr,
     vm_memattr_t attr, NvBool zero, NvBool *may_reclaim)
 {
@@ -1407,6 +1427,7 @@
     vm_paddr_t pa;
     int req = VM_ALLOC_WIRED | VM_ALLOC_NOWAIT | VM_ALLOC_NORECLAIM |
         (zero ? VM_ALLOC_ZERO : 0);
+    vm_size_t run;
     int tries;
 
     for (tries = 0; tries < 2; tries++) {
@@ -1416,9 +1437,9 @@
             break;
         if (tries > 0 || !*may_reclaim)
             return 0;
-        if (vm_page_reclaim_contig(VM_ALLOC_NOWAIT,
-            atop(MAX(unit, NV_GB10_RECLAIM_RUN)), 0, high_addr,
-            MAX(unit, NV_GB10_RECLAIM_RUN), 0) != 0)
+        run = nv_gb10_reclaim_size(unit);
+        if (vm_page_reclaim_contig(VM_ALLOC_NOWAIT, atop(run), 0,
+            high_addr, run, 0) != 0)
             *may_reclaim = NV_FALSE;
     }
     pa = VM_PAGE_TO_PHYS(m);

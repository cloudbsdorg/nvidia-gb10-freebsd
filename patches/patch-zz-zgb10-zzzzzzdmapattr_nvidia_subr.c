--- nvidia/nvidia_subr.c.orig	2026-11-26 12:30:17.833148000 +0000
+++ nvidia/nvidia_subr.c	2026-11-26 12:30:17.842729000 +0000
@@ -1380,18 +1380,28 @@
  * all of RAM (a vLLM start spent 47 minutes in it).  Here a miss reclaims
  * one aligned 2 MiB run instead, which the next 32 units are carved from,
  * and only when that fails does the caller fall back to the kmem path.
- * Loader/kenv tunable and run-time sysctl hw.nvidia_gb10_dmap_units
- * (0 = old behaviour, for comparison).
+ *
+ * Units with another memory attribute (CPU-uncached or write-combined,
+ * most vLLM buffers) take the same path: vm_page_alloc_noobj_contig()
+ * sets the attribute on the direct map of each page and flushes the
+ * caches (pmap_page_set_memattr()), and vm_page_free() restores it, so
+ * the direct-map address carries the attribute the RM asked for.  The kmem
+ * path changes the direct map in the same way, it only adds a second
+ * mapping.  Left on the kmem path, these units ran a contig reclaim per
+ * unit on fragmented memory (98 % of a 38-minute vLLM post-load phase).
+ * Loader/kenv tunable and run-time sysctl hw.nvidia_gb10_dmap_units
+ * (0 = old behaviour, 1 = write-back units only, 2 = all units).
  */
-static int nv_gb10_dmap_units = 1;
+static int nv_gb10_dmap_units = 2;
 SYSCTL_INT(_hw, OID_AUTO, nvidia_gb10_dmap_units, CTLFLAG_RWTUN,
     &nv_gb10_dmap_units, 0,
-    "GB10: write-back units above 4 KiB come from the direct map (1 = on)");
+    "GB10: units above 4 KiB come from the direct map "
+    "(0 = off, 1 = write-back only, 2 = all memory attributes)");
 
 #define NV_GB10_RECLAIM_RUN (2UL << 20)
 
 static vm_offset_t nv_alloc_dmap_unit(vm_size_t unit, vm_paddr_t high_addr,
-    NvBool zero, NvBool *may_reclaim)
+    vm_memattr_t attr, NvBool zero, NvBool *may_reclaim)
 {
     vm_page_t m;
     vm_paddr_t pa;
@@ -1401,7 +1411,7 @@
 
     for (tries = 0; tries < 2; tries++) {
         m = vm_page_alloc_noobj_contig(req, atop(unit), 0, high_addr,
-            unit, 0, VM_MEMATTR_DEFAULT);
+            unit, 0, attr);
         if (m != NULL)
             break;
         if (tries > 0 || !*may_reclaim)
@@ -1619,8 +1629,11 @@
 
     attr = _convert_caching_to_attr(cache_type);
 #if defined(__aarch64__)
-    dmap = (attr == VM_MEMATTR_WRITE_BACK &&
-        (unit == PAGE_SIZE ? nv_gb10_dmap_pages : nv_gb10_dmap_units) != 0);
+    if (unit == PAGE_SIZE)
+        dmap = (attr == VM_MEMATTR_WRITE_BACK && nv_gb10_dmap_pages != 0);
+    else
+        dmap = (nv_gb10_dmap_units >= 2 ||
+            (attr == VM_MEMATTR_WRITE_BACK && nv_gb10_dmap_units == 1));
     may_reclaim = NV_TRUE;
 #endif
 
@@ -1660,7 +1673,7 @@
                 dmap = NV_FALSE;
         } else if (dmap) {
             /* a miss costs little; keep trying for the next unit */
-            address = nv_alloc_dmap_unit(unit, high_addr, zero,
+            address = nv_alloc_dmap_unit(unit, high_addr, attr, zero,
                 &may_reclaim);
         }
 #endif

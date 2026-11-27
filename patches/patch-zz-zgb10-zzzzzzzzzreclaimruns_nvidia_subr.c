--- nvidia/nvidia_subr.c.orig	2026-11-26 18:58:13.494206000 +0000
+++ nvidia/nvidia_subr.c	2026-11-26 18:58:13.502967000 +0000
@@ -1418,6 +1418,39 @@
     if (run == 0 || !powerof2(run) || run > (1UL << 30))
         run = 2UL << 20;
     return MAX(unit, (vm_size_t)run);
+}
+
+/*
+ * hw.nvidia_gb10_reclaim_runs: runs of nv_gb10_reclaim_run bytes one
+ * reclaim may free.  vm_page_reclaim_contig_domain_ext() scans all of RAM
+ * every time and records every candidate run it passes, then relocates
+ * only desired_runs of them; vm_page_reclaim_contig() asks for one.  So a
+ * scan (~124 ms with vLLM up, debug kernel) bought one 2 MiB run (BOOT 134:
+ * 960-1,330 scans per start, 14 minutes in the post-load phase at the
+ * memory peak).  Asking for more runs costs the same scan; unlike a larger
+ * nv_gb10_reclaim_run (BOOT 131) the runs need not be adjacent, so they
+ * still exist on fragmented memory.  A partial result counts as success.
+ * Run-time sysctl; 1 = old behaviour, capped at 1024.
+ */
+static int nv_gb10_reclaim_runs = 16;
+SYSCTL_INT(_hw, OID_AUTO, nvidia_gb10_reclaim_runs, CTLFLAG_RWTUN,
+    &nv_gb10_reclaim_runs, 0,
+    "GB10: runs freed per direct-map reclaim scan (1 = old behaviour)");
+
+static int nv_gb10_reclaim(vm_size_t run, vm_paddr_t high_addr)
+{
+    int domain, runs = nv_gb10_reclaim_runs;
+
+    if (runs < 1)
+        runs = 1;
+    else if (runs > 1024)
+        runs = 1024;
+    for (domain = 0; domain < vm_ndomains; domain++) {
+        if (vm_page_reclaim_contig_domain_ext(domain, VM_ALLOC_NOWAIT,
+            atop(run), 0, high_addr, run, 0, runs) == 0)
+            return 0;
+    }
+    return ENOMEM;
 }
 
 static vm_offset_t nv_alloc_dmap_unit(vm_size_t unit, vm_paddr_t high_addr,
@@ -1438,8 +1471,7 @@
         if (tries > 0 || !*may_reclaim)
             return 0;
         run = nv_gb10_reclaim_size(unit);
-        if (vm_page_reclaim_contig(VM_ALLOC_NOWAIT, atop(run), 0,
-            high_addr, run, 0) != 0)
+        if (nv_gb10_reclaim(run, high_addr) != 0)
             *may_reclaim = NV_FALSE;
     }
     pa = VM_PAGE_TO_PHYS(m);

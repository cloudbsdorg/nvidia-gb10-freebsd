--- nvidia/nvidia_subr.c.orig
+++ nvidia/nvidia_subr.c
@@ -1323,6 +1323,19 @@
 
     return VM_MEMATTR_UNCACHEABLE;
 }
+
+/*
+ * GB10 bring-up knob (diagnostic).  0, the default, changes nothing.  A
+ * value from 32 to 63 keeps every RM system-memory allocation made for a
+ * GPU below 2^bits, whatever address width the RM reported.  It exists to
+ * test whether the GB20B SEC2 chain-of-trust command (error 0x6, BOOT 96)
+ * fails because the GSP-FMC and boot-args addresses are above 4 GiB.
+ * Loader/kenv tunable and run-time sysctl: hw.nvidia_gb10_dma_bits.
+ */
+static int nv_gb10_dma_bits = 0;
+SYSCTL_INT(_hw, OID_AUTO, nvidia_gb10_dma_bits, CTLFLAG_RWTUN,
+    &nv_gb10_dma_bits, 0,
+    "GB10 diagnostic: cap RM system memory below 2^bits (0 = off)");
 
 static NvS32 nv_alloc_contig_pages(
     NvU32       count,
@@ -1603,6 +1616,11 @@
     {
         high_addr = BUS_SPACE_MAXADDR;
     }
+
+    /* GB10 bring-up knob, see nv_gb10_dma_bits above. */
+    if (nv_gb10_dma_bits >= 32 && nv_gb10_dma_bits < 64 &&
+        high_addr > (((vm_paddr_t)1 << nv_gb10_dma_bits) - 1))
+        high_addr = ((vm_paddr_t)1 << nv_gb10_dma_bits) - 1;
 
     if (!alloc_type_contiguous) {
         if (nv_alloc_system_pages(count, cache_type, high_addr, zero,

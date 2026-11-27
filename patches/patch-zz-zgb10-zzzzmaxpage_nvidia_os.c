--- nvidia/nvidia_os.c.orig	2026-11-25 10:18:51.397216000 +0000
+++ nvidia/nvidia_os.c	2026-11-25 10:18:58.493297000 +0000
@@ -173,6 +173,23 @@
-NvU64 os_max_page_size = PAGE_SIZE;
+#if defined(__aarch64__)
+/*
+ * GB10: the RM gives a client's system memory allocation the GPU's big
+ * page size (64 KiB) only when osGetSupportedSysmemPageSizeMask(), built
+ * from os_page_size..os_max_page_size, contains it; otherwise every CUDA
+ * buffer is described and mapped on the GPU in 4 KiB pages.  Linux sets
+ * os_max_page_size to PAGE_SIZE << MAX_PAGE_ORDER (4 MiB with 4 KiB
+ * pages), and so do we: nv_alloc_pages() honours the page size it is
+ * passed.  Loader/kenv tunable and run-time sysctl, a power of two:
+ * hw.nvidia_gb10_max_page_size (4096 = NVIDIA's FreeBSD behaviour).
+ */
+NvU64 os_max_page_size = 4UL * 1024 * 1024;
+SYSCTL_U64(_hw, OID_AUTO, nvidia_gb10_max_page_size, CTLFLAG_RWTUN,
+    &os_max_page_size, 0,
+    "GB10: largest system memory page size offered to the RM, in bytes");
+#else
+NvU64 os_max_page_size = PAGE_SIZE;
+#endif
 NvU64 os_page_mask     = ~PAGE_MASK;
 NvU8  os_page_shift    = PAGE_SHIFT;
 
 NvBool os_cc_enabled = 0;
 NvBool os_cc_sev_snp_enabled = 0;

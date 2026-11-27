--- nvidia/nv-freebsd.h.orig	2026-11-25 00:16:20.307382000 +0000
+++ nvidia/nv-freebsd.h	2026-11-25 00:16:20.406697000 +0000
@@ -149,7 +149,7 @@
 struct nvidia_alloc {
     vm_memattr_t attr;
     uint32_t num_pages;
-    uint32_t size;
+    vm_size_t size;             /* bytes; more than 4 GiB is normal on GB10 */
     uint32_t unit_pages;        /* non-contiguous: pages per kmem unit (page_size) */
     int alloc_type_contiguous;
     struct nvidia_pte *pte_array;

--- nvidia/nv-freebsd.h.orig	2026-11-24 03:38:11.746401000 +0000
+++ nvidia/nv-freebsd.h	2026-11-24 03:38:42.087918000 +0000
@@ -150,6 +150,7 @@
     vm_memattr_t attr;
     uint32_t num_pages;
     uint32_t size;
+    uint32_t unit_pages;        /* non-contiguous: pages per kmem unit (page_size) */
     int alloc_type_contiguous;
     struct nvidia_pte *pte_array;
     struct sglist *sg_list;

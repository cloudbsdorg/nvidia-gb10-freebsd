--- nvidia/nvidia_subr.c.orig	2026-11-25 00:16:29.963189000 +0000
+++ nvidia/nvidia_subr.c	2026-11-25 00:16:29.991950000 +0000
@@ -1062,7 +1062,7 @@
 )
 {
     vm_offset_t virtual_address;
-    uint32_t size;
+    vm_size_t size;
 
     if (pPrivate != NULL) {
         virtual_address = (vm_offset_t)address & ~PAGE_MASK;
@@ -1371,7 +1371,7 @@
     struct nvidia_alloc *at;
     vm_memattr_t attr;
     vm_offset_t address;
-    NvU32 size = (count * PAGE_SIZE);
+    vm_size_t size = ptoa((vm_size_t)count);
     int flags = (zero ? M_ZERO : 0);
     int status;
     vm_size_t align = nv_alloc_unit(page_size);
@@ -1496,7 +1496,8 @@
     vm_offset_t address;
     uint32_t i;
     vm_memattr_t attr;
-    uint32_t size = (count * PAGE_SIZE);
+    /* 64-bit: a 32-bit byte count wraps at 4 GiB, and the free path then freed nothing */
+    vm_size_t size = ptoa((vm_size_t)count);
     int flags = (zero ? M_ZERO : 0);
     int status;
     vm_size_t unit = nv_alloc_unit(page_size);
@@ -1602,7 +1603,7 @@
     uint32_t i, count;
     uint32_t ppu = (at->unit_pages != 0) ? at->unit_pages : 1;
 
-    count = at->size / PAGE_SIZE;
+    count = at->num_pages;
 
     NV_VM_OBJECT_DEALLOCATE(at->object);
     NV_SGLIST_FREE(at->sg_list);
@@ -1681,7 +1682,7 @@
             (M_WAITOK | M_ZERO));
 
     at->num_pages = count;
-    at->size = (uint32_t)size;
+    at->size = size;
     at->alloc_type_contiguous = 1;
     at->attr = attr;
     at->flags.aliased = NV_TRUE;

--- nvidia/nvidia_subr.c.orig
+++ nvidia/nvidia_subr.c
@@ -1651,6 +1651,20 @@
         }
     }
 
+    /*
+     * Track #2376: the memory the RM took is wired system RAM (this board
+     * has no memory of its own behind the GPU), so it is charged to the
+     * credential that asked for it.  A charge that is refused gives the
+     * memory back and fails the allocation: the host keeps its memory.
+     */
+    if (status == NV_OK) {
+        if (nvga_wired_alloc(count, page_size, *private) != 0) {
+            nv_free_pages(nv, count, alloc_type_contiguous, cache_type,
+                *private);
+            status = NV_ERR_NO_MEMORY;
+        }
+    }
+
     return status;
 }
 
@@ -1672,6 +1686,11 @@
             status = NV_ERR_GENERIC;
     }
 
+    /*
+     * Track #2376: the memory is gone, so the charge for it goes with it.
+     */
+    nvga_wired_free(private);
+
     return status;
 }
 

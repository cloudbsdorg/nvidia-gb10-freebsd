--- nvidia/nvidia_subr.c.orig
+++ nvidia/nvidia_subr.c
@@ -17,7 +17,8 @@
 #include "nv-freebsd.h"
 #include "nv-caps.h"
 #include "nv-firmware.h"
 #include "nv-uvm-interface.h"	/* UVM top half, suspend/resume hooks (gb10) */
+#include "gb10_pageimport.h"	/* cross-GPU import core, docs/PRIME-IMPORT.md */
 
 #include <sys/consio.h>
 #include <sys/fbio.h>
@@ -2117,6 +2118,19 @@
 {
 }
 
+/*
+ * Cross-GPU buffer import (PRIME), Track #2228, docs/PRIME-IMPORT.md.  The
+ * logic is in gb10_pageimport.h and the FreeBSD side in gb10_pageimport_os.c
+ * (our own files; nv_import_pages() and nv_unimport_pages() are there too).
+ * The SGT path below is the RM's entry into it: the RM calls
+ * nv_dma_import_sgt() (take the owner's reference), nv_register_sgt() (wire
+ * the pages, fill the physical address array), and at the end
+ * nv_unregister_sgt() (unwire) and nv_dma_release_sgt() (drop the
+ * reference); a failure after the registration unregisters and then
+ * releases, a failed registration only releases.  The old stub returned
+ * success from nv_register_sgt() without filling the array.  The "sg_table"
+ * the RM passes through is a struct gb10_pi_desc.
+ */
 NV_STATUS NV_API_CALL nv_register_sgt(
     nv_state_t *nv,
     NvU64      *phys_addr,
@@ -2128,7 +2142,8 @@
     NvBool      is_peer_mmio
 )
 {
-    return NV_OK;
+    return gb10_pi_os_register(import_sgt, page_count, phys_addr, priv_data,
+                               is_peer_mmio);
 }
 
 void NV_API_CALL nv_unregister_sgt(
@@ -2138,6 +2153,7 @@
     void  *priv_data
 )
 {
+    gb10_pi_os_unregister(priv_data, (void **)import_sgt, import_priv);
 }
 
 
@@ -2325,7 +2341,8 @@
     struct drm_gem_object *gem
 )
 {
-    return NV_ERR_NOT_SUPPORTED;
+    /* sgt is a struct gb10_pi_desc, see nv_register_sgt(). */
+    return gb10_pi_os_import(sgt);
 }
 
 NV_STATUS NV_API_CALL nv_dma_import_dma_buf
@@ -2360,6 +2377,7 @@
     struct drm_gem_object *gem
 )
 {
+    gb10_pi_os_release(sgt);
 }
 
 void NV_API_CALL nv_dma_release_dma_buf

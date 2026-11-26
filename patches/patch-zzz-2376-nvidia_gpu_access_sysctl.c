--- nvidia/nvidia_sysctl.c.orig
+++ nvidia/nvidia_sysctl.c
@@ -13,6 +13,7 @@
 #include "nv-freebsd.h"
 #include "nv-reg.h"
 #include "nv_version_sysctl.h"
+#include "nvga_glue.h"		/* the state of the check and of the accounting (gb10) */
 
 struct sysctl_ctx_list sysctl_ctx;
 static struct nv_version_sysctl_state nv_version_sysctl_state;
@@ -49,6 +50,12 @@
     nv_version_sysctl_init(&sysctl_ctx, oid_nvidia, pNVRM_ID,
             &nv_version_sysctl_state);
 
+    /*
+     * Track #2374 and #2376: the state of the GPU access check and of the
+     * wired memory accounting, under this node.
+     */
+    nvga_sysctl_init(&sysctl_ctx, oid_nvidia);
+
     oid_registry = SYSCTL_ADD_NODE(&sysctl_ctx,
             SYSCTL_CHILDREN(oid_nvidia),
             OID_AUTO,
@@ -93,6 +100,10 @@
 
 void nvidia_sysctl_exit(void)
 {
+    /*
+     * Track #2374 and #2376: the state goes with the node.
+     */
+    nvga_sysctl_exit();
     sysctl_ctx_free(&sysctl_ctx);
     if (option_string != NULL)
         free((void *)option_string, M_NVIDIA);

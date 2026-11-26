--- nvidia/nvidia_sysctl.c.orig
+++ nvidia/nvidia_sysctl.c
@@ -12,8 +12,11 @@
 #include "nv.h"
 #include "nv-freebsd.h"
 #include "nv-reg.h"
+#include "nv_version_sysctl.h"
+#include "nv_device_sysctl.h"
 
 struct sysctl_ctx_list sysctl_ctx;
+static struct nv_version_sysctl_state nv_version_sysctl_state;
 
 struct sysctl_oid *oid_nvidia;
 struct sysctl_oid *oid_registry;
@@ -44,6 +47,16 @@
             0,
             "NVIDIA Resource Manager (NVRM) Version");
 
+    nv_version_sysctl_init(&sysctl_ctx, oid_nvidia, pNVRM_ID,
+            &nv_version_sysctl_state);
+
+    /*
+     * The number of GPUs the driver has.  The node is registered with the
+     * module, not with a GPU, so a host with no NVIDIA GPU reads 0 here
+     * instead of finding no node at all.
+     */
+    nv_device_sysctl_init(&sysctl_ctx, oid_nvidia);
+
     oid_registry = SYSCTL_ADD_NODE(&sysctl_ctx,
             SYSCTL_CHILDREN(oid_nvidia),
             OID_AUTO,
@@ -89,8 +102,14 @@
 void nvidia_sysctl_exit(void)
 {
     sysctl_ctx_free(&sysctl_ctx);
-    if (option_string != NULL)
+    if (option_string != NULL) {
         free((void *)option_string, M_NVIDIA);
+        option_string = NULL;
+    }
+    if (rm_msg_string != NULL) {
+        free((void *)rm_msg_string, M_NVIDIA);
+        rm_msg_string = NULL;
+    }
 }
 
 
@@ -352,6 +371,8 @@
             nvidia_sysctl_bus_type,
             "A",
             "NVIDIA GPU Bus Type");
+
+    nv_version_sysctl_gpu_init(nv, oid);
 }
 
 void nv_sysctl_exit(nv_state_t *nv)

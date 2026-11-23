--- nvidia/nvidia_sysctl.c.orig
+++ nvidia/nvidia_sysctl.c
@@ -12,6 +12,8 @@
 #include "nv.h"
 #include "nv-freebsd.h"
 #include "nv-reg.h"
+#include "nv_version_sysctl.h"
 
 struct sysctl_ctx_list sysctl_ctx;
+static struct nv_version_sysctl_state nv_version_sysctl_state;
 
@@ -44,6 +46,9 @@
             0,
             "NVIDIA Resource Manager (NVRM) Version");
 
+    nv_version_sysctl_init(&sysctl_ctx, oid_nvidia, pNVRM_ID,
+            &nv_version_sysctl_state);
+
     oid_registry = SYSCTL_ADD_NODE(&sysctl_ctx,
             SYSCTL_CHILDREN(oid_nvidia),
             OID_AUTO,
@@ -352,6 +357,8 @@
             nvidia_sysctl_bus_type,
             "A",
             "NVIDIA GPU Bus Type");
+
+    nv_version_sysctl_gpu_init(nv, oid);
 }
 
 void nv_sysctl_exit(nv_state_t *nv)

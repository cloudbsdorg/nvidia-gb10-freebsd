--- nvidia/nvidia_sysctl.c.orig
+++ nvidia/nvidia_sysctl.c
@@ -13,6 +13,7 @@
 #include "nv-freebsd.h"
 #include "nv-reg.h"
 #include "nv_version_sysctl.h"
+#include "nv_arch_floor.h"
 
 struct sysctl_ctx_list sysctl_ctx;
 static struct nv_version_sysctl_state nv_version_sysctl_state;
@@ -48,6 +49,7 @@
 
     nv_version_sysctl_init(&sysctl_ctx, oid_nvidia, pNVRM_ID,
             &nv_version_sysctl_state);
+    nv_arch_floor_sysctl_init(&sysctl_ctx, oid_nvidia);
 
     oid_registry = SYSCTL_ADD_NODE(&sysctl_ctx,
             SYSCTL_CHILDREN(oid_nvidia),

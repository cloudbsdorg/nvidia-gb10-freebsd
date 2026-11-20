--- nvidia-drm/nvidia-drm.c.orig
+++ nvidia-drm/nvidia-drm.c
@@ -28,7 +28,7 @@
 #include "nvidia-drm-drv.h"
 
 static struct NvKmsKapiFunctionsTable nvKmsFuncsTable = {
-    .versionString = NV_VERSION_STRING,
+    .versionString = NV_VERSION_STRING NVKMS_KAPI_CBSD_LAYOUT,
 };
 
 const struct NvKmsKapiFunctionsTable* const nvKms = &nvKmsFuncsTable;
@@ -46,8 +46,12 @@
 #if defined(NV_DRM_AVAILABLE)
     if (!nvKmsKapiGetFunctionsTable(&nvKmsFuncsTable)) {
         NV_DRM_LOG_ERR(
-            "Version mismatch: nvidia-modeset.ko(%s) nvidia-drm.ko(%s)",
-            nvKmsFuncsTable.versionString, NV_VERSION_STRING);
+            "Version mismatch: nvidia-modeset.ko(%s) nvidia-drm.ko(%s): the "
+            "+cbsd-kapi.N suffix is the layout of the KAPI table between "
+            "the two modules; install nvidia.ko, nvidia-modeset.ko and "
+            "nvidia-drm.ko from the same build",
+            nvKmsFuncsTable.versionString,
+            NV_VERSION_STRING NVKMS_KAPI_CBSD_LAYOUT);
         return -EINVAL;
     }
 

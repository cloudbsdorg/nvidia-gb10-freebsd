--- nvidia-modeset/nvidia-modeset-freebsd.c.orig
+++ nvidia-modeset/nvidia-modeset-freebsd.c
@@ -1467,7 +1467,7 @@
 
 MODULE_DEPEND(nvidia_modeset,               /* module name */
               nvidia,                       /* prerequisite module */
-              1, 1, 1);                     /* vmin, vpref, vmax */
+              2, 2, 2);                     /* vmin, vpref, vmax: nvidia.ko 2 (Track #2373) */
 
 #if defined(NVKMS_SUPPORT_LINUX_COMPAT)
 #if defined(NVCPU_AARCH64)

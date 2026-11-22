--- nvidia-drm/nvidia-drm-freebsd-lkpi.c.orig
+++ nvidia-drm/nvidia-drm-freebsd-lkpi.c
@@ -259,7 +259,7 @@
 MODULE_DEPEND(nvidia_drm, linuxkpi, 1, 1, 1);
 MODULE_DEPEND(nvidia_drm, drmn, 2, 2, 2);
 MODULE_DEPEND(nvidia_drm, dmabuf, 1, 1, 1);
-MODULE_DEPEND(nvidia_drm, nvidia, 1, 1, 1);
+MODULE_DEPEND(nvidia_drm, nvidia, 2, 2, 2);	/* nvidia.ko 2 (Track #2373) */
 /* version 2: the KAPI table has the page-array member (NVKMS_KAPI_CBSD_LAYOUT) */
 MODULE_DEPEND(nvidia_drm, nvidia_modeset, 2, 2, 2);
 

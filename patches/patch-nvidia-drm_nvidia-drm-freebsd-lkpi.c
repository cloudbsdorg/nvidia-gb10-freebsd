--- nvidia-drm/nvidia-drm-freebsd-lkpi.c.orig
+++ nvidia-drm/nvidia-drm-freebsd-lkpi.c
@@ -237,5 +237,6 @@
 MODULE_DEPEND(nvidia_drm, drmn, 2, 2, 2);
 MODULE_DEPEND(nvidia_drm, dmabuf, 1, 1, 1);
 MODULE_DEPEND(nvidia_drm, nvidia, 1, 1, 1);
-MODULE_DEPEND(nvidia_drm, nvidia_modeset, 1, 1, 1);
+/* version 2: the KAPI table has the page-array member (NVKMS_KAPI_CBSD_LAYOUT) */
+MODULE_DEPEND(nvidia_drm, nvidia_modeset, 2, 2, 2);
 #endif /* NV_DRM_AVAILABLE */

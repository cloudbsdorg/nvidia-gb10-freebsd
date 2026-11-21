--- nvidia-drm/nvidia-drm-freebsd-lkpi.c.orig
+++ nvidia-drm/nvidia-drm-freebsd-lkpi.c
@@ -236,6 +236,6 @@
 MODULE_DEPEND(nvidia_drm, linuxkpi, 1, 1, 1);
 MODULE_DEPEND(nvidia_drm, drmn, 2, 2, 2);
 MODULE_DEPEND(nvidia_drm, dmabuf, 1, 1, 1);
-MODULE_DEPEND(nvidia_drm, nvidia, 1, 1, 1);
+MODULE_DEPEND(nvidia_drm, nvidia, 2, 2, 2);	/* nvidia.ko 2 (Track #2373) */
 MODULE_DEPEND(nvidia_drm, nvidia_modeset, 1, 1, 1);
 #endif /* NV_DRM_AVAILABLE */

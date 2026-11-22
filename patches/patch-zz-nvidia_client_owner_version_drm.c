--- nvidia-drm/nvidia-drm-freebsd-lkpi.c.orig
+++ nvidia-drm/nvidia-drm-freebsd-lkpi.c
@@ -260,5 +260,5 @@
 MODULE_DEPEND(nvidia_drm, drmn, 2, 2, 2);
 MODULE_DEPEND(nvidia_drm, dmabuf, 1, 1, 1);
-MODULE_DEPEND(nvidia_drm, nvidia, 1, 1, 1);
+MODULE_DEPEND(nvidia_drm, nvidia, 2, 2, 2);	/* nvidia.ko 2 (Track #2373) */
 /* 2: getSystemMemoryHandleFromPageArray; 3: setConsoleOwner */
 MODULE_DEPEND(nvidia_drm, nvidia_modeset, 3, 3, 3);

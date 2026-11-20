--- nvidia-drm/nvidia-drm-freebsd-lkpi.c.orig
+++ nvidia-drm/nvidia-drm-freebsd-lkpi.c
@@ -237,5 +237,41 @@
 MODULE_DEPEND(nvidia_drm, drmn, 2, 2, 2);
 MODULE_DEPEND(nvidia_drm, dmabuf, 1, 1, 1);
 MODULE_DEPEND(nvidia_drm, nvidia, 1, 1, 1);
-MODULE_DEPEND(nvidia_drm, nvidia_modeset, 1, 1, 1);
+/* version 2: the KAPI table has the page-array member (NVKMS_KAPI_CBSD_LAYOUT) */
+MODULE_DEPEND(nvidia_drm, nvidia_modeset, 2, 2, 2);
+
+/*
+ * LKPI_DRIVER_MODULE cannot refuse an unload.  An RM file descriptor that
+ * holds an exported imported buffer (nv_drm_pi_live_holds() above zero) calls
+ * back into this module and its device structures when it closes: a second
+ * module in this file refuses MOD_QUIESCE and MOD_UNLOAD while any is held,
+ * and kldunload quiesces every module of the file before it unloads any.
+ */
+extern int nv_drm_pi_live_holds(void);
+
+static int
+nv_drm_pi_guard_handler(module_t mod, int what, void *arg)
+{
+    switch (what) {
+    case MOD_LOAD:
+        return 0;
+    case MOD_QUIESCE:
+    case MOD_UNLOAD:
+        if (nv_drm_pi_live_holds() > 0) {
+            printf("nvidia_drm: unload refused: %d RM export(s) of imported "
+                   "buffers are still open; close the processes that hold "
+                   "them (fstat /dev/nvidiactl) and try again\n",
+                   nv_drm_pi_live_holds());
+            return EBUSY;
+        }
+        return 0;
+    default:
+        return EOPNOTSUPP;
+    }
+}
+
+static moduledata_t nv_drm_pi_guard_mod = {
+    "nvidia_drm_pi_guard", nv_drm_pi_guard_handler, NULL
+};
+DECLARE_MODULE(nvidia_drm_pi_guard, nv_drm_pi_guard_mod, SI_SUB_DRIVERS, SI_ORDER_ANY);
 #endif /* NV_DRM_AVAILABLE */

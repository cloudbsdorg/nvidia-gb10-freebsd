--- nvidia-drm/nvidia-drm-drv.c.orig
+++ nvidia-drm/nvidia-drm-drv.c
@@ -2194,6 +2194,27 @@
 {
     struct nv_drm_device *nv_dev;
 
+    if (nv_drm_pi_live_holds() > 0) {
+        /*
+         * An RM file descriptor still holds an exported imported buffer:
+         * it will call into this module and through the GEM object into
+         * nv_dev when it closes, so the devices are kept instead of
+         * destroyed.  Only reached if the driver module is unloaded before
+         * the guard module (the guard normally unloads first and refuses):
+         * the guard's MOD_UNLOAD still runs after this and refuses too,
+         * the file stays loaded and every later unload is refused, so this
+         * is the protection in that order.
+         */
+        NV_DRM_LOG_ERR("%d RM export(s) of imported buffers are still "
+                       "open and the driver was torn down anyway: its "
+                       "devices are kept and this module now refuses every "
+                       "unload.  Restart the machine before closing those "
+                       "exports",
+                       nv_drm_pi_live_holds());
+        nv_drm_pi_keep();
+        return;
+    }
+
     while ((nv_dev = nv_drm_pop_device())) {
         drm_dev_unregister(nv_dev->dev);
         nv_drm_dev_destroy(nv_dev);

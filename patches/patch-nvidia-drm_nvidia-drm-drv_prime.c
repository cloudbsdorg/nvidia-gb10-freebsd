--- nvidia-drm/nvidia-drm-drv.c.orig
+++ nvidia-drm/nvidia-drm-drv.c
@@ -2193,6 +2193,24 @@
 void nv_drm_remove_devices(void)
 {
     struct nv_drm_device *nv_dev;
+
+    if (nv_drm_pi_live_holds() > 0) {
+        /*
+         * An RM file descriptor still holds an exported imported buffer
+         * (the guard module refuses the unload, so this is a second line
+         * of defence): it will call into this module and through the GEM
+         * object into nv_dev when it closes, so the devices are kept
+         * instead of destroyed.
+         */
+        NV_DRM_LOG_ERR("%d RM export(s) of imported buffers are still "
+                       "open, and the driver is being unloaded anyway: the "
+                       "programs that hold them will crash the kernel when "
+                       "they close.  Restart the machine now, before "
+                       "closing them",
+                       nv_drm_pi_live_holds());
+        nv_drm_pi_keep();
+        return;
+    }
 
     while ((nv_dev = nv_drm_pop_device())) {
         drm_dev_unregister(nv_dev->dev);

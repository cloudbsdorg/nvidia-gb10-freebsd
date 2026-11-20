--- nvidia-drm/nvidia-drm-drv.c.orig
+++ nvidia-drm/nvidia-drm-drv.c
@@ -2180,6 +2180,21 @@
 {
     struct nv_drm_device *nv_dev = nv_drm_find_and_remove_device(gpuId);
 
+    if (nv_dev && nv_drm_pi_live_holds() > 0) {
+        /*
+         * An RM file descriptor still holds an exported imported buffer,
+         * and will call into this module and through the GEM object into
+         * nv_dev when it closes: leak the device rather than free it.
+         */
+        NV_DRM_DEV_LOG_ERR(nv_dev,
+            "Device removed while %d RM export(s) of imported buffers are "
+            "still open: the device structures are kept until the next "
+            "boot, and nvidia_drm cannot be unloaded until those exports "
+            "are closed", nv_drm_pi_live_holds());
+        drm_dev_unplug(nv_dev->dev);
+        return;
+    }
+
     if (nv_dev) {
         NV_DRM_DEV_LOG_INFO(nv_dev, "Removing device");
         drm_dev_unplug(nv_dev->dev);

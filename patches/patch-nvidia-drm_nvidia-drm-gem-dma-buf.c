--- nvidia-drm/nvidia-drm-gem-dma-buf.c.orig
+++ nvidia-drm/nvidia-drm-gem-dma-buf.c
@@ -80,6 +80,16 @@
      * through the same linuxkpi bits it seems (probably so it can be used
      * elsewhere), so dma_buf->file really is a native FreeBSD struct file...
      */
+    if (nv_gem->base.filp == NULL) {
+        /*
+         * An imported dma-buf has no file of its own: the DRM core
+         * creates the GEM object without one, so there is nothing to map
+         * through here.  Refuse the mapping instead of dereferencing a
+         * NULL file.
+         */
+        return -EINVAL;
+    }
+
     if (!nv_gem->base.filp->f_op->mmap)
         return -EINVAL;
 
@@ -144,11 +154,24 @@
 
     if ((nv_dma_buf =
             nv_drm_calloc(1, sizeof(*nv_dma_buf))) == NULL) {
-        return NULL;
+        return ERR_PTR(-ENOMEM);
     }
 
-    // dma_buf->size must be a multiple of PAGE_SIZE
-    BUG_ON(dma_buf->size % PAGE_SIZE);
+    /*
+     * dma_buf->size must be a multiple of PAGE_SIZE.  This used to be a
+     * BUG_ON, which is a kernel panic reachable from a dma-buf exported
+     * by another driver: the size belongs to the exporter, not to us
+     * (a udmabuf device can export a buffer of any size).
+     */
+    if (dma_buf->size == 0 || (dma_buf->size % PAGE_SIZE) != 0) {
+        NV_DRM_DEV_LOG_ERR(
+            nv_dev,
+            "dma-buf size 0x%" NvU64_fmtx " is not a non-zero multiple of "
+            "the page size",
+            (NvU64)dma_buf->size);
+        nv_drm_free(nv_dma_buf);
+        return ERR_PTR(-EINVAL);
+    }
 
     pMemory = NULL;
     if (drm_core_check_feature(dev, DRIVER_MODESET)) {
@@ -157,6 +180,25 @@
                                                   dma_buf->size - 1);
     }
 
+    if (pMemory == NULL) {
+        /*
+         * The RM could not import the buffer.  On FreeBSD the OS layer
+         * has no dma-buf import at all (nvidia_subr.c:
+         * nv_dma_import_dma_buf() returns NV_ERR_NOT_SUPPORTED), so
+         * every dma-buf import ends here.
+         *
+         * The GEM object is still created: it can be mapped for CPU
+         * access through the exporter.  It has no NVKMS memory handle
+         * though, so it cannot be a framebuffer plane, and
+         * nv_drm_framebuffer_init() refuses such a framebuffer with
+         * EINVAL.
+         */
+        NV_DRM_DEV_LOG_ERR(
+            nv_dev,
+            "The RM could not import the dma-buf; the buffer has no NVKMS "
+            "memory handle");
+    }
+
     nv_drm_gem_object_init(nv_dev, &nv_dma_buf->base,
                            &__nv_gem_dma_buf_ops, dma_buf->size, pMemory);
 

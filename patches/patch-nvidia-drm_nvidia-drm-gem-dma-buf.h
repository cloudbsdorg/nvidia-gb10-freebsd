--- nvidia-drm/nvidia-drm-gem-dma-buf.h.orig
+++ nvidia-drm/nvidia-drm-gem-dma-buf.h
@@ -28,12 +28,40 @@
 #if defined(NV_DRM_AVAILABLE)
 
 #include "nvidia-drm-gem.h"
+#include "gb10_pageimport.h"
 
 struct nv_drm_gem_dma_buf {
     struct nv_drm_gem_object base;
     struct sg_table *sgt;
+
+    /*
+     * Cross-GPU import (Track #2228, docs/PRIME-IMPORT.md): the pages of
+     * the imported buffer, one per page, as vm_page pointers.  They belong
+     * to the dma-buf attachment, which outlives the GEM object's RM handle
+     * (see __nv_drm_gem_dma_buf_free()), and are not wired here.  NULL when
+     * the buffer was refused (not whole pages of system memory).
+     */
+    void **pages;
+    NvU64 page_count;
+
+    /*
+     * What the OS layer receives for the export ioctl, in place of the
+     * Linux sg_table it cannot read.
+     */
+    struct gb10_pi_desc pi_desc;
+
+    /*
+     * The exporter's dma-buf, held from the import until the GEM object is
+     * freed (after the RM handle), so that its page pool cannot reuse the
+     * pages while the RM maps them.
+     */
+    struct gb10_pi_life life;
 };
 
+/* The RM holds on exported imported buffers; nonzero forbids unloading nvidia-drm. */
+int nv_drm_pi_live_holds(void);
+int nv_drm_pi_quiesce(void);
+
 extern const struct nv_drm_gem_object_funcs __nv_gem_dma_buf_ops;
 
 static inline struct nv_drm_gem_dma_buf *to_nv_dma_buf(

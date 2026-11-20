--- nvidia-drm/nvidia-drm-gem-dma-buf.c.orig
+++ nvidia-drm/nvidia-drm-gem-dma-buf.c
@@ -37,6 +37,57 @@
 
 #include "linux/dma-buf.h"
 
+#include <vm/vm_phys.h>
+
+/* The page `index` pages after `first`, or NULL when it is not a RAM page without a VM object. */
+static void *__nv_drm_pi_page_at(void *ctx, void *first,
+                                 unsigned long long index)
+{
+    struct page *m = first;
+    struct page *p;
+
+    if (m == NULL || (m->flags & PG_FICTITIOUS) != 0) {
+        return NULL;
+    }
+
+    p = vm_phys_paddr_to_vm_page(page_to_phys(m) +
+                                 ((vm_paddr_t)index << PAGE_SHIFT));
+    if (p == NULL || (p->flags & PG_FICTITIOUS) != 0) {
+        return NULL;
+    }
+    if (index == 0 && p != m) {
+        return NULL;
+    }
+    if (p->object != NULL) {
+        /* Cannot be wired safely by the OS layer, see nv_pi_page_at(). */
+        return NULL;
+    }
+
+    return p;
+}
+
+static const struct gb10_pi_ops __nv_drm_pi_ops = {
+    .page_at = __nv_drm_pi_page_at,
+};
+
+/*
+ * The RM holds the GEM object while it uses the pages of an export (what
+ * the Linux driver does with the GEM reference nv_dma_import_sgt() takes).
+ */
+static void __nv_drm_gem_dma_buf_pi_hold(void *ctx)
+{
+    struct nv_drm_gem_object *nv_gem = ctx;
+
+    drm_gem_object_get(&nv_gem->base);
+}
+
+static void __nv_drm_gem_dma_buf_pi_release(void *ctx)
+{
+    struct nv_drm_gem_object *nv_gem = ctx;
+
+    nv_drm_gem_object_unreference_unlocked(nv_gem);
+}
+
 static inline
 void __nv_drm_gem_dma_buf_free(struct nv_drm_gem_object *nv_gem)
 {
@@ -50,6 +101,9 @@
 
     drm_prime_gem_destroy(&nv_gem->base, nv_dma_buf->sgt);
 
+    /* After the RM handle and the attachment: nothing reads the pages now. */
+    nv_drm_free(nv_dma_buf->pages);
+
     nv_drm_free(nv_dma_buf);
 }
 
@@ -80,6 +134,16 @@
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
 
@@ -124,6 +188,121 @@
 #endif
 
     return ret;
+}
+
+/*
+ * Import the pages of a dma-buf the RM's own import refused (on FreeBSD that
+ * is every dma-buf, see nv_dma_import_dma_buf()).  The scatter list is
+ * checked and expanded into one vm_page pointer per page first: nothing
+ * that is not a whole number of managed RAM pages gets any further, and a
+ * buffer in another GPU's video memory is refused here, with the reason in
+ * the log.  Then the pages are wired by the OS layer and handed to the RM as
+ * a page array.  Returns the NVKMS memory handle, or NULL: the GEM object is
+ * still created without one (it cannot be a framebuffer plane; see
+ * nv_drm_framebuffer_init()).  When the pages could be converted they are
+ * kept in the GEM object for the export ioctl, handle or not.
+ */
+static struct NvKmsKapiMemory *__nv_drm_gem_dma_buf_import_pages(
+    struct nv_drm_device *nv_dev,
+    struct nv_drm_gem_dma_buf *nv_dma_buf,
+    struct sg_table *sgt,
+    NvU64 size)
+{
+    struct gb10_pi_seg *segs = NULL;
+    struct scatterlist *sg;
+    void **pages = NULL;
+    void *array = NULL;
+    struct NvKmsKapiMemory *pMemory = NULL;
+    NvBool pages_taken = NV_FALSE;
+    unsigned long long nsegs = 0, npages = 0;
+    unsigned int i;
+    int rc;
+
+    if (sgt == NULL || sgt->orig_nents == 0) {
+        rc = GB10_PI_EMPTY;
+        goto refused;
+    }
+
+    segs = nv_drm_calloc(sgt->orig_nents, sizeof(*segs));
+    if (segs == NULL) {
+        rc = GB10_PI_NOMEM;
+        goto refused;
+    }
+
+    for_each_sgtable_sg(sgt, sg, i) {
+        segs[nsegs].first = sg_page(sg);
+        segs[nsegs].offset = sg->offset;
+        segs[nsegs].length = sg->length;
+        nsegs++;
+    }
+
+    rc = gb10_pi_count(segs, nsegs, size, PAGE_SIZE, &npages);
+    if (rc != GB10_PI_OK) {
+        goto refused;
+    }
+
+    pages = nv_drm_calloc(npages, sizeof(*pages));
+    if (pages == NULL) {
+        rc = GB10_PI_NOMEM;
+        goto refused;
+    }
+
+    rc = gb10_pi_fill(segs, nsegs, size, PAGE_SIZE, &__nv_drm_pi_ops, NULL,
+                      pages, npages, &npages);
+    if (rc != GB10_PI_OK) {
+        goto refused;
+    }
+
+    nv_drm_free(segs);
+    segs = NULL;
+
+    /* Kept for the export ioctl; the dma-buf attachment owns the pages. */
+    nv_dma_buf->pages = pages;
+    nv_dma_buf->page_count = npages;
+    nv_dma_buf->pi_desc.magic = GB10_PI_DESC_MAGIC;
+    nv_dma_buf->pi_desc.count = npages;
+    nv_dma_buf->pi_desc.pages = pages;
+    nv_dma_buf->pi_desc.ctx = &nv_dma_buf->base;
+    nv_dma_buf->pi_desc.hold = __nv_drm_gem_dma_buf_pi_hold;
+    nv_dma_buf->pi_desc.release = __nv_drm_gem_dma_buf_pi_release;
+
+    if (nvKms->getSystemMemoryHandleFromPageArray == NULL) {
+        /* An older nvidia-modeset.ko leaves the appended member empty. */
+        NV_DRM_DEV_LOG_ERR(
+            nv_dev,
+            "nvidia-modeset.ko has no page-array import; it does not match "
+            "this nvidia-drm.ko");
+        return NULL;
+    }
+
+    if (nv_import_pages(pages, npages, &array) != 0) {
+        NV_DRM_DEV_LOG_ERR(
+            nv_dev,
+            "Could not wire the %llu pages of the dma-buf", npages);
+        return NULL;
+    }
+
+    pMemory = nvKms->getSystemMemoryHandleFromPageArray(
+                  nv_dev->pDevice, (NvP64)(NvUPtr)array, size - 1,
+                  &pages_taken);
+
+    if (pMemory == NULL && !pages_taken) {
+        /* The RM never took the array: unwire and free it here. */
+        nv_unimport_pages(array, npages);
+    }
+
+    return pMemory;
+
+refused:
+    NV_DRM_DEV_LOG_ERR(
+        nv_dev,
+        "The dma-buf (0x%" NvU64_fmtx " bytes) cannot be imported: %s "
+        "(only buffers in system memory can be imported, see "
+        "docs/PRIME-IMPORT.md)",
+        (NvU64)size, gb10_pi_str(rc));
+    nv_drm_free(pages);
+    nv_drm_free(segs);
+    return NULL;
 }
 
 const struct nv_drm_gem_object_funcs __nv_gem_dma_buf_ops = {
@@ -144,11 +323,24 @@
 
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
@@ -157,6 +349,35 @@
                                                   dma_buf->size - 1);
     }
 
+    if (pMemory == NULL && drm_core_check_feature(dev, DRIVER_MODESET)) {
+        /*
+         * The RM's own dma-buf import is not implemented on FreeBSD
+         * (nv_dma_import_dma_buf() returns NV_ERR_NOT_SUPPORTED): import
+         * the buffer's pages instead, if it is system memory.
+         */
+        pMemory = __nv_drm_gem_dma_buf_import_pages(nv_dev, nv_dma_buf, sgt,
+                                                    dma_buf->size);
+    }
+
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
 
@@ -197,14 +418,27 @@
 
     if (drm_core_check_feature(dev, DRIVER_MODESET)) {
         if (!nv_dma_buf->base.pMemory) {
+            if (nv_dma_buf->pages == NULL) {
+                /* The import refused the buffer; nothing to export. */
+                ret = -EINVAL;
+                NV_DRM_DEV_LOG_ERR(
+                    nv_dev,
+                    "DMA-BUF GEM object 0x%08x has no importable pages "
+                    "to export: it was refused at import, see the earlier "
+                    "\"cannot be imported\" line", p->handle);
+                goto done;
+            }
+
             /*
-             * Get RM system memory handle from SGT - RM will take a reference
-             * on this GEM object to prevent the DMA-BUF from being unpinned
-             * prematurely.
+             * Get RM system memory handle from the pages kept at import
+             * time.  The OS layer reads them from a struct gb10_pi_desc (it
+             * cannot read the Linux sg_table), and the RM takes a reference
+             * on this GEM object through it, to prevent the DMA-BUF from
+             * being unpinned prematurely.
              */
             pTmpMemory = nvKms->getSystemMemoryHandleFromSgt(
                              nv_dev->pDevice,
-                             (NvP64)(NvUPtr)nv_dma_buf->sgt,
+                             (NvP64)(NvUPtr)&nv_dma_buf->pi_desc,
                              (NvP64)(NvUPtr)&nv_dma_buf->base.base,
                              nv_dma_buf->base.base.size - 1);
         }

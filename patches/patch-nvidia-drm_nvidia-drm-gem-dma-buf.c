--- nvidia-drm/nvidia-drm-gem-dma-buf.c.orig
+++ nvidia-drm/nvidia-drm-gem-dma-buf.c
@@ -37,6 +37,136 @@
 
 #include "linux/dma-buf.h"
 
+#include <vm/vm_phys.h>
+
+/*
+ * The page `index` pages after `first`, or NULL when it is not a RAM page
+ * without a VM object.  That a first page is the page the entry names is
+ * checked by gb10_pi_fill().  The answer is only a first screening: the OS
+ * layer busies each page and asks again before it wires it.
+ */
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
+    /* The one decision, shared with nvidia.ko: gb10_pi_page_claimable(). */
+    if (!gb10_pi_page_claimable(p != NULL,
+                                p != NULL && (p->flags & PG_FICTITIOUS) != 0,
+                                p != NULL && p->object != NULL)) {
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
+/*
+ * The holds the RM has on imported buffers (one per export, taken by
+ * nv_dma_import_sgt(), dropped by nv_dma_release_sgt()).  The RM calls back
+ * into this module's text and, through the GEM object, into its device
+ * structures, from an RM file descriptor that can outlive the DRM file.  The
+ * gate counts them: the guard module in nvidia-drm-freebsd-lkpi.c closes it
+ * at MOD_QUIESCE (refused while a hold is live; once closed no new hold is
+ * given, the export fails cleanly), and the teardown of the devices does not
+ * run while a hold is live.  The decrement is done by the core in nvidia.ko
+ * after __nv_drm_gem_dma_buf_pi_release() has returned, so no instruction
+ * of this module runs after the count reaches zero.
+ */
+static struct gb10_pi_gate __nv_drm_pi_gate;
+/*
+ * A LinuxKPI spin_lock, which is a default mutex with the thread pinned: the sections are a
+ * few instructions and nothing sleeps inside.  Not mutex_lock (an sx lock that may sleep):
+ * the RM calls the hold from its import path, whose context this module does not know.
+ */
+static DEFINE_SPINLOCK(__nv_drm_pi_gate_lock);
+
+int nv_drm_pi_live_holds(void)
+{
+    return gb10_pi_gate_live(&__nv_drm_pi_gate);
+}
+
+/* MOD_QUIESCE and MOD_UNLOAD: EBUSY while an export is held, else close the gate. */
+int nv_drm_pi_quiesce(int *held)
+{
+    int rc;
+
+    spin_lock(&__nv_drm_pi_gate_lock);
+    rc = gb10_pi_gate_quiesce(&__nv_drm_pi_gate);
+    *held = gb10_pi_gate_live(&__nv_drm_pi_gate);  /* the reason, read with the decision */
+    spin_unlock(&__nv_drm_pi_gate_lock);
+
+    return rc != 0 ? EBUSY : 0;
+}
+
+/*
+ * The teardown kept the devices because an export was held (its second
+ * line of defence, reached only if the guard module was bypassed): the gate
+ * is closed for the rest of that unload, which nothing stops any more, so
+ * this is a defensive assertion with a log line, not a protection.
+ */
+void nv_drm_pi_keep(void)
+{
+    spin_lock(&__nv_drm_pi_gate_lock);
+    gb10_pi_gate_keep(&__nv_drm_pi_gate);
+    spin_unlock(&__nv_drm_pi_gate_lock);
+}
+
+static int __nv_drm_gem_dma_buf_pi_hold(void *ctx)
+{
+    struct nv_drm_gem_object *nv_gem = ctx;
+    int rc;
+
+    spin_lock(&__nv_drm_pi_gate_lock);
+    rc = gb10_pi_gate_hold(&__nv_drm_pi_gate);
+    spin_unlock(&__nv_drm_pi_gate_lock);
+    if (rc != 0) {
+        return rc;
+    }
+
+    drm_gem_object_get(&nv_gem->base);
+    return 0;
+}
+
+static void __nv_drm_gem_dma_buf_pi_release(void *ctx)
+{
+    struct nv_drm_gem_object *nv_gem = ctx;
+
+    nv_drm_gem_object_unreference_unlocked(nv_gem);
+}
+
+/*
+ * The exporter's dma-buf, held for the whole life of the GEM object whenever
+ * its pages were imported (taken when the pages are imported,
+ * dropped as the last step of freeing the GEM object).  The
+ * RM maps the exporter's pages; nothing but a reference on the dma-buf
+ * stops the exporter's page pool from reusing them after the exporter
+ * closes its own handle and fd, exported again or not.
+ */
+static void __nv_drm_gem_dma_buf_life_hold(void *ctx)
+{
+    get_dma_buf((struct dma_buf *)ctx);
+}
+
+static void __nv_drm_gem_dma_buf_life_release(void *ctx)
+{
+    dma_buf_put((struct dma_buf *)ctx);
+}
+
 static inline
 void __nv_drm_gem_dma_buf_free(struct nv_drm_gem_object *nv_gem)
 {
@@ -50,6 +180,12 @@
 
     drm_prime_gem_destroy(&nv_gem->base, nv_dma_buf->sgt);
 
+    /* After the RM handle and the attachment: nothing reads the pages now. */
+    nv_drm_free(nv_dma_buf->pages);
+
+    /* Last: only now may the exporter's pool reuse the pages. */
+    gb10_pi_life_drop(&nv_dma_buf->life);
+
     nv_drm_free(nv_dma_buf);
 }
 
@@ -80,6 +216,16 @@
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
 
@@ -126,6 +272,150 @@
     return ret;
 }
 
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
+    struct dma_buf *dma_buf,
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
+    nv_dma_buf->pi_desc.gate = &__nv_drm_pi_gate;
+
+    /*
+     * The exporter's buffer must outlive every use of its pages.  Taken
+     * here, before the failure points below, on purpose: the caller creates
+     * the GEM object whatever this function returns (a buffer without an
+     * NVKMS handle still keeps its pages), and the free of that object is
+     * the one place that drops the reference.
+     */
+    nv_dma_buf->life.ctx = dma_buf;
+    nv_dma_buf->life.hold = __nv_drm_gem_dma_buf_life_hold;
+    nv_dma_buf->life.release = __nv_drm_gem_dma_buf_life_release;
+    gb10_pi_life_take(&nv_dma_buf->life);
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
+    rc = nv_import_pages(pages, npages, &array);
+    if (rc != 0) {
+        NV_DRM_DEV_LOG_ERR(
+            nv_dev,
+            "Could not wire the %llu pages of the dma-buf (status 0x%x): %s",
+            npages, (unsigned)rc,
+            rc == GB10_PI_STATUS_RETRY ?
+                "a page is held busy by the exporter's mapping right now; "
+                "the GEM object has no NVKMS handle, close it and import the "
+                "buffer again" :
+            rc == GB10_PI_STATUS_REFUSED ?
+                "a page is no longer importable (the exporter's mapping gave "
+                "it a VM object)" :
+                "out of resources or not system memory");
+        return NULL;
+    }
+
+    pMemory = nvKms->getSystemMemoryHandleFromPageArray(
+                  nv_dev->pDevice, (NvP64)(NvUPtr)array, size - 1,
+                  &pages_taken);
+
+    if (pMemory != NULL) {
+        /* wired for the RM: a later SGT export wires them again (second wiring) */
+        nv_dma_buf->pi_desc.imported = 1;
+    }
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
+}
+
 const struct nv_drm_gem_object_funcs __nv_gem_dma_buf_ops = {
     .free = __nv_drm_gem_dma_buf_free,
     .create_mmap_offset = __nv_drm_gem_dma_buf_create_mmap_offset,
@@ -144,11 +434,24 @@
 
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
@@ -157,6 +460,35 @@
                                                   dma_buf->size - 1);
     }
 
+    if (pMemory == NULL && drm_core_check_feature(dev, DRIVER_MODESET)) {
+        /*
+         * The RM's own dma-buf import is not implemented on FreeBSD
+         * (nv_dma_import_dma_buf() returns NV_ERR_NOT_SUPPORTED): import
+         * the buffer's pages instead, if it is system memory.
+         */
+        pMemory = __nv_drm_gem_dma_buf_import_pages(nv_dev, nv_dma_buf, dma_buf,
+                                                    sgt, dma_buf->size);
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
 
@@ -196,17 +528,46 @@
     }
 
     if (drm_core_check_feature(dev, DRIVER_MODESET)) {
-        if (!nv_dma_buf->base.pMemory) {
+        if (!nv_dma_buf->base.pMemory || nv_dma_buf->pages != NULL) {
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
+             * time, also when the page-array import made a handle of its
+             * own: that handle holds no reference on anything, so an RM FD
+             * made from it could outlive this GEM object and the exporter's
+             * buffer.  This one goes through the OS layer's SGT path, which
+             * takes a reference on this GEM object for as long as the RM
+             * maps the pages (the RM FD releases it).  The OS layer reads
+             * the pages from a struct gb10_pi_desc (it cannot read the
+             * Linux sg_table).
              */
             pTmpMemory = nvKms->getSystemMemoryHandleFromSgt(
                              nv_dev->pDevice,
-                             (NvP64)(NvUPtr)nv_dma_buf->sgt,
+                             (NvP64)(NvUPtr)&nv_dma_buf->pi_desc,
                              (NvP64)(NvUPtr)&nv_dma_buf->base.base,
                              nv_dma_buf->base.base.size - 1);
+
+            if (!pTmpMemory) {
+                ret = -ENOMEM;
+                NV_DRM_DEV_LOG_ERR(
+                    nv_dev,
+                    "Failed to get memory to export from DMA-BUF GEM "
+                    "object: 0x%08x (the RM refused the pages: one may be "
+                    "held busy by the exporter's mapping, or has gained a VM "
+                    "object; see the earlier log lines)",
+                    p->handle);
+                goto done;
+            }
         }
     }
 
@@ -220,8 +581,8 @@
     }
 
     if (!nvKms->exportMemory(nv_dev->pDevice,
-                             nv_dma_buf->base.pMemory ?
-                                nv_dma_buf->base.pMemory : pTmpMemory,
+                             pTmpMemory ?
+                                pTmpMemory : nv_dma_buf->base.pMemory,
                              p->nvkms_params_ptr,
                              p->nvkms_params_size)) {
         ret = -EINVAL;

--- common/inc/nvkms-kapi.h.orig
+++ common/inc/nvkms-kapi.h
/* CPD-OFF -- this patch and its twin edit two copies of the KAPI table header that must stay byte-identical (tests/kapi_table_test.sh); the duplication is the point */
@@ -619,6 +619,20 @@
     void (*remove)(NvU32 gpuId);
     void (*probe)(const struct NvKmsKapiGpuInfo *gpu_info);
 };
+
+/*
+ * CloudBSD (Track #2228): the layout of struct NvKmsKapiFunctionsTable.
+ * nvidia-drm.ko and nvidia-modeset.ko keep a copy of the table; the driver's
+ * own version check (NV_VERSION_STRING) does not notice a member appended to
+ * it, and a newer nvidia-modeset.ko would write one pointer past an older
+ * nvidia-drm.ko's table.  Both modules append this tag to the version string
+ * they compare, and nvidia-modeset.ko compares before it writes any member.
+ * Bump the number whenever a member is added or the table changes.  (The
+ * nvidia_modeset kld version (the number in the tag) and the
+ * matching MODULE_DEPEND in nvidia-drm make kldload refuse a
+ * mix before any code runs.)
+ */
+#define NVKMS_KAPI_CBSD_LAYOUT "+cbsd-kapi.2"
 
 struct NvKmsKapiFunctionsTable {
 
@@ -1606,6 +1620,41 @@
     (
         struct NvKmsKapiDevice *device
     );
+
+    /*
+     * CloudBSD (Track #2228): import an array of wired pages as a memory
+     * handle.  This member is last on purpose: nvidia-drm.ko and
+     * nvidia-modeset.ko each keep a copy of this table and are built
+     * from this header together.
+     *
+     * \param [in]  device  A device allocated using allocateDevice().
+     *
+     * \param [in]  pages   Array of vm_page pointers, one per page, each
+     *                      wired once, allocated by the OS layer
+     *                      (nv_import_pages()).
+     *
+     * \param [in]  limit   Size, in bytes, of the memory, minus one.
+     *
+     * \param [out] pPagesTaken
+     *                      NV_TRUE when the RM owns the array now (on
+     *                      success, and on a failure after it took it):
+     *                      the caller must not touch it again.  NV_FALSE
+     *                      when the caller still owns it and must give it
+     *                      back (nv_unimport_pages()).
+     *
+     * The memory is requested write-back; the page-array path refuses
+     * anything else.
+     *
+     * \return A valid memory handle on success, NULL on failure.
+     */
+    struct NvKmsKapiMemory*
+    (*getSystemMemoryHandleFromPageArray)
+    (
+        struct NvKmsKapiDevice *device,
+        NvP64 pages,
+        NvU32 limit,
+        NvBool *pPagesTaken
+    );
 };
 
 /** @} */
/* CPD-ON */

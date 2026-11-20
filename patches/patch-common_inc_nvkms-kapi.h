--- common/inc/nvkms-kapi.h.orig
+++ common/inc/nvkms-kapi.h
@@ -1606,6 +1606,41 @@
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

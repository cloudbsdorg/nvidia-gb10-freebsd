--- nvidia-drm/nvidia-drm-gem-nvkms-memory.h.orig
+++ nvidia-drm/nvidia-drm-gem-nvkms-memory.h
@@ -43,6 +43,14 @@
     bool physically_mapped;
     void *pPhysicalAddress;
     void *pWriteCombinedIORemapAddress;
+#if !defined(NV_LINUX)
+    /*
+     * FreeBSD: this object registered the fictitious vm_pages for its
+     * mapped video memory (see __nv_drm_gem_nvkms_bsd_pages_register) and
+     * unregisters them when it is freed.
+     */
+    bool bsd_pages_registered;
+#endif
 
     struct page **pages;
     unsigned long pages_count;

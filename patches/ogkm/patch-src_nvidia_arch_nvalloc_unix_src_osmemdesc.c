--- src/nvidia/arch/nvalloc/unix/src/osmemdesc.c.orig
+++ src/nvidia/arch/nvalloc/unix/src/osmemdesc.c
@@ -109,8 +109,13 @@
     // For UVM, they could have pre-allocated sysmem to register
     // with RM so we put in an exception for that case.
     //
+    // CloudBSD (Track #2228): a kernel client may also pass a page array.
+    // NVKMS is a kernel client, and the cross-GPU import hands it the
+    // wired pages of a buffer another driver exported.  The array is an
+    // array of kernel-owned pages, not a kernel virtual address range.
     if ((rmclientGetCachedPrivilege(pClient) >= RS_PRIV_LEVEL_KERNEL) &&
         (descriptorType != NVOS32_DESCRIPTOR_TYPE_OS_PHYS_ADDR) &&
+        (descriptorType != NVOS32_DESCRIPTOR_TYPE_OS_PAGE_ARRAY) &&
         (descriptorType != NVOS32_DESCRIPTOR_TYPE_OS_FILE_HANDLE) &&
         (descriptorType != NVOS32_DESCRIPTOR_TYPE_OS_DMA_BUF_PTR) &&
         (descriptorType != NVOS32_DESCRIPTOR_TYPE_OS_SGT_PTR))

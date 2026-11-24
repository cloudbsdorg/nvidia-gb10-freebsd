--- src/nvidia/src/kernel/gpu/gsp/arch/turing/kernel_gsp_tu102.c.orig
+++ src/nvidia/src/kernel/gpu/gsp/arch/turing/kernel_gsp_tu102.c
@@ -206,10 +206,19 @@
             heapSizeMB = NV_REG_STR_GSP_SYSMEM_HEAP_SIZE_MB_DEFAULT;
         }
 
+        //
+        // FreeBSD GB10 bring-up: the heap is handed to GSP as one base and
+        // size, so it must be contiguous as the GPU sees it (checked below).
+        // Upstream asks for a non-contiguous allocation and relies on the OS
+        // DMA layer (an IOMMU) to make it contiguous in bus-address space.
+        // The FreeBSD OS layer has no such mapping (nv_dma_map_alloc() is
+        // not supported; GPU address == physical address), so ask for
+        // physically contiguous pages instead.
+        //
         NV_ASSERT_OK_OR_GOTO(nvStatus,
                              memdescCreate(&pKernelGsp->pSysmemHeapDescriptor,
                                             pGpu, (NvU64)heapSizeMB << 20, 0,
-                                            NV_FALSE, ADDR_SYSMEM, NV_MEMORY_UNCACHED,
+                                            NV_TRUE, ADDR_SYSMEM, NV_MEMORY_UNCACHED,
                                             flags),
                              _kgspAllocBootArgs_exit_cleanup);
 
@@ -218,8 +227,19 @@
         NV_ASSERT_OK_OR_GOTO(nvStatus, nvStatus,
                             _kgspAllocBootArgs_exit_cleanup);
 
-        NV_ASSERT_OR_GOTO(memdescCheckContiguity(pKernelGsp->pSysmemHeapDescriptor, AT_GPU),
-                          _kgspAllocBootArgs_exit_cleanup);
+        //
+        // Upstream jumps to the cleanup with nvStatus still NV_OK here; the
+        // caller then carries on and writes through the boot-args mappings
+        // the cleanup has just torn down.  Return an error instead.
+        //
+        if (!memdescCheckContiguity(pKernelGsp->pSysmemHeapDescriptor, AT_GPU))
+        {
+            NV_PRINTF(LEVEL_ERROR,
+                      "GSP sysmem heap (%u MB) is not contiguous at the GPU\n",
+                      heapSizeMB);
+            nvStatus = NV_ERR_NO_MEMORY;
+            goto _kgspAllocBootArgs_exit_cleanup;
+        }
     }
 
     return nvStatus;

--- src/nvidia-modeset/kapi/src/nvkms-kapi.c.orig
+++ src/nvidia-modeset/kapi/src/nvkms-kapi.c
@@ -2010,7 +2010,86 @@
     return GetSystemMemoryHandleFromDmaBufSgtHelper(
         device, NVOS32_DESCRIPTOR_TYPE_OS_DMA_BUF_PTR, dmaBuf, limit);
 }
+
+/*
+ * CloudBSD (Track #2228): the page-array import.  The RM owns the array
+ * from the moment osCreateMemFromOsDescriptor() succeeded: it clears the
+ * descriptor in the parameters it was given, and its memory-descriptor
+ * teardown unwires and frees the array (the rule RmCreateOsDescriptor()
+ * relies on to decide who unwires after a failed allocation).  A kernel
+ * caller's parameters are used in place, so the descriptor is looked at
+ * after the call and the caller is told through *pPagesTaken.
+ */
+static struct NvKmsKapiMemory*
+GetSystemMemoryHandleFromPageArray(struct NvKmsKapiDevice *device,
+                                   NvP64 pages,
+                                   NvU32 limit,
+                                   NvBool *pPagesTaken)
+{
+    NvU32 ret;
+    NV_OS_DESC_MEMORY_ALLOCATION_PARAMS memAllocParams = {0};
+    struct NvKmsKapiMemory *memory = NULL;
+    NvU32 hRmHandle;
+
+    if (pPagesTaken == NULL) {
+        return NULL;
+    }
+
+    *pPagesTaken = NV_FALSE;
+
+    if (pages == NvP64_NULL) {
+        return NULL;
+    }
+
+    memory = AllocMemoryObjectAndHandle(device, &hRmHandle);
 
+    if (!memory) {
+        return NULL;
+    }
+
+    memAllocParams.type = NVOS32_TYPE_PRIMARY;
+    memAllocParams.descriptorType = NVOS32_DESCRIPTOR_TYPE_OS_PAGE_ARRAY;
+    memAllocParams.descriptor = pages;
+    memAllocParams.limit = limit;
+
+    memAllocParams.attr =
+        FLD_SET_DRF(OS32, _ATTR, _LOCATION, _PCI, memAllocParams.attr);
+
+    memAllocParams.attr2 =
+        FLD_SET_DRF(OS32, _ATTR2, _GPU_CACHEABLE, _NO, memAllocParams.attr2);
+
+    /* The page-array path accepts write-back memory only. */
+    memAllocParams.attr =
+        FLD_SET_DRF(OS32, _ATTR, _COHERENCY, _WRITE_BACK,
+                    memAllocParams.attr);
+
+    ret = nvRmApiAlloc(device->hRmClient,
+                       device->hRmDevice,
+                       hRmHandle,
+                       NV01_MEMORY_SYSTEM_OS_DESCRIPTOR,
+                       &memAllocParams);
+
+    *pPagesTaken = (ret == NVOS_STATUS_SUCCESS) ||
+                   (memAllocParams.descriptor == NvP64_NULL);
+
+    if (ret != NVOS_STATUS_SUCCESS) {
+        nvKmsKapiLogDeviceDebug(
+                device,
+                "nvRmApiAlloc (page array) failed with error code 0x%08x",
+                ret);
+        nvKmsKapiFreeRmHandle(device, hRmHandle);
+        FreeMemory(device, memory);
+        return NULL;
+    }
+
+    memory->hRmHandle = hRmHandle;
+    memory->size = (NvU64)limit + 1;
+    memory->surfaceParams.layout = NvKmsSurfaceMemoryLayoutPitch;
+    memory->isVidmem = NV_FALSE;
+
+    return memory;
+}
+
 static NvBool RmGc6BlockerRefCntAction(const struct NvKmsKapiDevice *device,
                                        NvU32 action)
 {
@@ -4061,7 +4140,40 @@
                                    &params, sizeof(params));
     if (!status) {
         nvKmsKapiLogDeviceDebug(device, "NVKMS FramebufferConsoleDisabled failed");
+    }
+}
+
+static NvBool SetConsoleOwner(
+    struct NvKmsKapiDevice *device,
+    void (*yield)(void *arg),
+    void (*reclaim)(void *arg),
+    void *arg)
+{
+    struct NvKmsCbsdSetConsoleOwnerParams params = { };
+    NvBool status;
+
+    if (device->hKmsDevice == 0x0) {
+        nvKmsKapiLogDevice(device,
+                           "NVKMS SetConsoleOwner: the KAPI device has no "
+                           "NVKMS device handle");
+        return NV_FALSE;
     }
+
+    params.request.deviceHandle = device->hKmsDevice;
+    params.request.yield = yield;
+    params.request.reclaim = reclaim;
+    params.request.arg = arg;
+
+    status = nvkms_ioctl_from_kapi(device->pKmsOpen,
+                                   NVKMS_IOCTL_CBSD_SET_CONSOLE_OWNER,
+                                   &params, sizeof(params));
+    if (!status) {
+        nvKmsKapiLogDevice(device,
+                           "NVKMS SetConsoleOwner: the ioctl was refused (not "
+                           "a kernel client, not the modeset owner, or "
+                           "mismatched callbacks)");
+    }
+    return status;
 }
 
 NvBool nvKmsKapiGetFunctionsTableInternal
@@ -4073,8 +4185,14 @@
         return NV_FALSE;
     }
 
-    if (nvkms_strcmp(funcsTable->versionString, NV_VERSION_STRING) != 0) {
-        funcsTable->versionString = NV_VERSION_STRING;
+    /*
+     * The version and the layout of the table (NVKMS_KAPI_CBSD_LAYOUT),
+     * compared before any member is written: a table of another layout is
+     * never filled.
+     */
+    if (nvkms_strcmp(funcsTable->versionString,
+                     NV_VERSION_STRING NVKMS_KAPI_CBSD_LAYOUT) != 0) {
+        funcsTable->versionString = NV_VERSION_STRING NVKMS_KAPI_CBSD_LAYOUT;
         return NV_FALSE;
     }
 
@@ -4111,6 +4229,8 @@
     funcsTable->getSystemMemoryHandleFromSgt = GetSystemMemoryHandleFromSgt;
     funcsTable->getSystemMemoryHandleFromDmaBuf =
         GetSystemMemoryHandleFromDmaBuf;
+    funcsTable->getSystemMemoryHandleFromPageArray =
+        GetSystemMemoryHandleFromPageArray;
 
     funcsTable->mapMemory   = MapMemory;
     funcsTable->unmapMemory = UnmapMemory;
@@ -4148,6 +4268,7 @@
     funcsTable->cancelDisplaySemaphore = nvKmsKapiCancelDisplaySemaphore;
     funcsTable->signalVrrSemaphore = SignalVrrSemaphore;
     funcsTable->checkLutNotifier = CheckLutNotifier;
+    funcsTable->setConsoleOwner = SetConsoleOwner;
 
     return NV_TRUE;
 }

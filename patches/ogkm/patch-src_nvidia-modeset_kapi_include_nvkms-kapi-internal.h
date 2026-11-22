--- src/nvidia-modeset/kapi/include/nvkms-kapi-internal.h.orig
+++ src/nvidia-modeset/kapi/include/nvkms-kapi-internal.h
@@ -44,6 +44,15 @@
                   device->gpuId, ##__VA_ARGS__)
 
 /*
+ * Non-debug device log (CloudBSD, Track #2448): unlike nvKmsKapiLogDeviceDebug, which
+ * compiles away without DEBUG, this one always prints, at warning level. Used for
+ * failures an operator must be able to see in the kernel log of a release build.
+ */
+#define nvKmsKapiLogDevice(__device, __format, ...)               \
+    nvEvoLog(EVO_LOG_WARN, "[kapi][GPU Id 0x%08x] "__format,      \
+             (__device)->gpuId, ##__VA_ARGS__)
+
+/*
  * Semaphore values used when using semaphore-based synchronization between
  * userspace rendering and flips.
  */

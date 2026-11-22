--- src/nvidia-modeset/interface/nvkms-api.h.orig
+++ src/nvidia-modeset/interface/nvkms-api.h
@@ -274,6 +274,7 @@
     NVKMS_IOCTL_ACCEL_VBLANK_SEM_CONTROLS,
     NVKMS_IOCTL_VRR_SIGNAL_SEMAPHORE,
     NVKMS_IOCTL_FRAMEBUFFER_CONSOLE_DISABLED,
+    NVKMS_IOCTL_CBSD_SET_CONSOLE_OWNER,
 };
 
 
@@ -4448,4 +4449,38 @@
     struct NvKmsFramebufferConsoleDisabledReply reply;
 };
 
+/*
+ * NVKMS_IOCTL_CBSD_SET_CONSOLE_OWNER
+ *
+ * Mark the calling device as the console owner.  The device must hold
+ * modeset ownership.  When another client takes ownership, NVKMS calls
+ * yield(arg); when that client releases ownership, NVKMS calls reclaim(arg)
+ * instead of restoring the firmware console.  NULL for both callbacks clears
+ * the console owner.
+ *
+ * Both callbacks run with the NVKMS lock held; they must not call into the
+ * KAPI table or take a lock that a KAPI caller holds.  NVKMS timers on
+ * FreeBSD run under the same lock, so there is no lock-free context to defer
+ * to.  reclaim may be called more than once for one release (release, the
+ * console restore timer, resume), so it must be idempotent.  yield is called
+ * once per grab.
+ *
+ * This IOCTL can only be used by kernel-mode clients.
+ */
+struct NvKmsCbsdSetConsoleOwnerRequest {
+    NvKmsDeviceHandle deviceHandle;
+    void (*yield)(void *);
+    void (*reclaim)(void *);
+    void *arg;
+};
+
+struct NvKmsCbsdSetConsoleOwnerReply {
+    NvU32 padding;
+};
+
+struct NvKmsCbsdSetConsoleOwnerParams {
+    struct NvKmsCbsdSetConsoleOwnerRequest request;
+    struct NvKmsCbsdSetConsoleOwnerReply reply;
+};
+
 #endif /* NVKMS_API_H */

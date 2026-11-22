--- src/nvidia-modeset/include/nvkms-types.h.orig
+++ src/nvidia-modeset/include/nvkms-types.h
@@ -1073,2 +1073,8 @@
     const struct NvKmsPerOpenDev *modesetOwner;
+
+    /* CloudBSD (Track #2448): the kernel console owner and its callbacks. */
+    struct NvKmsPerOpenDev *cbsdConsoleOwner;
+    void (*cbsdConsoleYield)(void *);
+    void (*cbsdConsoleReclaim)(void *);
+    void *cbsdConsoleArg;
 

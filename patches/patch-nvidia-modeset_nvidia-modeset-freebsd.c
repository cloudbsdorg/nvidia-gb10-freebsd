--- nvidia-modeset/nvidia-modeset-freebsd.c.orig
+++ nvidia-modeset/nvidia-modeset-freebsd.c
@@ -54,6 +54,13 @@
   #elif defined(NVCPU_X86_64)
     #include "machine/../linux32/linux.h"
     #include "machine/../linux32/linux32_proto.h"
+  #elif defined(NVCPU_AARCH64)
+    /*
+     * arm64 has a native (64-bit) Linuxulator and no linux32: the Linux
+     * types and struct linux_ioctl_args come from arm64/linux.
+     */
+    #include <arm64/linux/linux.h>
+    #include <arm64/linux/linux_proto.h>
   #endif
   #include <compat/linux/linux_ioctl.h>
   #include <compat/linux/linux_util.h>
@@ -1456,17 +1463,25 @@
                SI_SUB_DRIVERS,              /* subsystem */
                SI_ORDER_ANY);               /* initialization order */
 
-MODULE_VERSION(nvidia_modeset, 1);
+/* 2: the KAPI table has getSystemMemoryHandleFromPageArray (NVKMS_KAPI_CBSD_LAYOUT) */
+MODULE_VERSION(nvidia_modeset, 2);
 
 MODULE_DEPEND(nvidia_modeset,               /* module name */
               nvidia,                       /* prerequisite module */
               1, 1, 1);                     /* vmin, vpref, vmax */
 
 #if defined(NVKMS_SUPPORT_LINUX_COMPAT)
+#if defined(NVCPU_AARCH64)
 MODULE_DEPEND(nvidia_modeset,               /* module name */
+              linux64elf,                   /* arm64's 64-bit Linuxulator */
+              1, 1, 1);                     /* vmin, vpref, vmax */
+#else
+MODULE_DEPEND(nvidia_modeset,               /* module name */
               linux,                        /* prerequisite module */
               1, 1, 1);                     /* vmin, vpref, vmax */
-#if defined(NVCPU_X86_64)
+#endif
+/* the kernel linker resolves only from a module's own dependencies */
+#if defined(NVCPU_X86_64) || defined(NVCPU_AARCH64)
 MODULE_DEPEND(nvidia_modeset,               /* module name */
               linux_common,                 /* prerequisite module */
               1, 1, 1);                     /* vmin, vpref, vmax */

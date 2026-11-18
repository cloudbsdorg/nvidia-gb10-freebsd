--- nvidia/nvidia_linux.c.orig	2026-11-17 11:25:31.856029000 +0000
+++ nvidia/nvidia_linux.c	2026-11-17 11:25:44.911280000 +0000
@@ -20,6 +20,13 @@
 #if defined(NVCPU_X86_64)
 #include "machine/../linux32/linux.h"
 #include "machine/../linux32/linux32_proto.h"
+#elif defined(NVCPU_AARCH64)
+/*
+ * arm64 has a native (64-bit) Linuxulator and no linux32: the Linux
+ * types and struct linux_ioctl_args come from arm64/linux.
+ */
+#include <arm64/linux/linux.h>
+#include <arm64/linux/linux_proto.h>
 #endif
 
 #include <compat/linux/linux_ioctl.h>

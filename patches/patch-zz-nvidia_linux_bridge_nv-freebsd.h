--- nvidia/nv-freebsd.h.orig
+++ nvidia/nv-freebsd.h
@@ -110,15 +110,24 @@
 /*
  * This option decides if the driver will be built with support for Linux
  * or Linux 32-bit (FreeBSD/amd64) compatibility. This makes nvidia.ko
  * dependent on linux.ko; if you don't need Linux compatibility, then you
  * can safely unset this flag.
  */
 
+/*
+ * Track #2363: the core carries no Linux code by default. The Linux ioctl
+ * bridges live in nvidia_linux.ko (and nvidia_modeset_linux.ko), owned by the
+ * Linuxulator, and reach the core only through nvidia_bridge.h. Build with
+ * -DNV_CORE_LINUX_COMPAT (make NV_CORE_LINUX_COMPAT=yes) for the old
+ * in-core bridge, which makes nvidia.ko depend on linux64elf/linux_common.
+ */
+#ifdef NV_CORE_LINUX_COMPAT
 #define NV_SUPPORT_LINUX_COMPAT
+#endif
 
 /*
  * Enable/Disable support for ACPI Power Management.
  */
 
 #define NV_SUPPORT_ACPI_PM
 

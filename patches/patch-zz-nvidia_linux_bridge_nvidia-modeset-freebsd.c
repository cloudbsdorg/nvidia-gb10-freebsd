--- nvidia-modeset/nvidia-modeset-freebsd.c.orig
+++ nvidia-modeset/nvidia-modeset-freebsd.c
@@ -46,5 +46,14 @@
  * Linux compatibility, then you can safely unset this flag.
  */
+
+/*
+ * Track #2363: no Linux code in the native module by default. The NVKMS
+ * Linux ioctl bridge is nvidia_modeset_linux.ko, owned by the Linuxulator.
+ * -DNVKMS_CORE_LINUX_COMPAT (make NVKMS_CORE_LINUX_COMPAT=yes) builds the
+ * old in-core bridge, which makes nvidia-modeset.ko depend on the Linuxulator.
+ */
+#ifdef NVKMS_CORE_LINUX_COMPAT
 #define NVKMS_SUPPORT_LINUX_COMPAT
+#endif
 
 #if defined(NVKMS_SUPPORT_LINUX_COMPAT)

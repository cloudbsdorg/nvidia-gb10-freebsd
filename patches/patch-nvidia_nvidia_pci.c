--- nvidia/nvidia_pci.c.orig	2026-11-17 19:37:40.086213000 +0000
+++ nvidia/nvidia_pci.c	2026-11-17 19:39:02.498659000 +0000
@@ -346,10 +346,17 @@
 MODULE_VERSION(nvidia, 1);
 
 MODULE_DEPEND(nvidia, mem, 1, 1, 1);
+/* the io(4) device exists only on x86 */
+#if defined(__amd64__) || defined(__i386__)
 MODULE_DEPEND(nvidia, io, 1, 1, 1);
+#endif
 
 #ifdef NV_SUPPORT_LINUX_COMPAT /* (COMPAT_LINUX || COMPAT_LINUX32) */
+#if defined(__aarch64__)
+MODULE_DEPEND(nvidia, linux64elf, 1, 1, 1);	/* arm64's 64-bit Linuxulator */
+#else
 MODULE_DEPEND(nvidia, linux, 1, 1, 1);
+#endif
 #if defined(NVCPU_X86_64)
 MODULE_DEPEND(nvidia, linux_common, 1, 1, 1);
 #endif

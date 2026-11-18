--- nvidia/nv-freebsd.h.orig	2026-11-17 10:20:36.400428000 +0000
+++ nvidia/nv-freebsd.h	2026-11-17 10:21:10.178137000 +0000
@@ -13,9 +13,7 @@
 
 #include <sys/param.h>
 
-#if __FreeBSD_version >= 1600000
-#error This driver does not support FreeBSD-CURRENT!
-#endif
+/* This tree is built for FreeBSD 16-CURRENT on purpose. */
 #if __FreeBSD_version >= 1500000 && __FreeBSD_version < 1500068
 #error This driver requires FreeBSD 15.0 or later!
 #endif
@@ -48,7 +46,9 @@
 #include <machine/resource.h>
 #include <machine/clock.h>
 #include <machine/bus.h>
+#if defined(__amd64__) || defined(__i386__)
 #include <machine/specialreg.h>
+#endif
 
 #include <sys/conf.h>
 #include <sys/rman.h>

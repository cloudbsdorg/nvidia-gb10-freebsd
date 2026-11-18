--- nvidia-modeset/nvidia-modeset-os-interface.h.orig
+++ nvidia-modeset/nvidia-modeset-os-interface.h
@@ -156,7 +156,7 @@
 int    nvkms_snprintf   (char *str,
                          size_t size,
                          const char *format, ...)
-    __attribute__((format (printf, 3, 4)));
+    __attribute__((format (__printf__, 3, 4)));
 
 int    nvkms_vsnprintf  (char *str,
                          size_t size,

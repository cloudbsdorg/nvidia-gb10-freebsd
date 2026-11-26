--- nvidia/nvidia_dev.c.orig
+++ nvidia/nvidia_dev.c
@@ -13,6 +13,7 @@
 #include "nv-chardev-numbers.h"
 #include "nv-freebsd.h"
 #include "nvidia_bridge.h"
+#include "nvga_glue.h"		/* the mode and the group of the RM nodes (gb10) */
 
 static d_open_t  nvidia_dev_open;
 static d_ioctl_t nvidia_dev_ioctl;
@@ -188,7 +189,7 @@
 
     sc->cdev = make_dev(&nvidia_dev_cdevsw,
             device_get_unit(sc->dev),
-            UID_ROOT, GID_WHEEL, 0666,
+            UID_ROOT, nvga_device_gid(), nvga_device_mode(),
             "%s%d", nvidia_dev_cdevsw.d_name,
             device_get_unit(sc->dev));
     if (sc->cdev == NULL)

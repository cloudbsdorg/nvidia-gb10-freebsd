--- nvidia/nvidia_ctl.c.orig
+++ nvidia/nvidia_ctl.c
@@ -13,6 +13,7 @@
 #include "nv-chardev-numbers.h"
 #include "nv-freebsd.h"
 #include "nvidia_bridge.h"
+#include "nvga_glue.h"		/* the mode and the group of the RM nodes (gb10) */
 
 #ifdef NV_SUPPORT_LINUX_COMPAT
 #include <compat/linux/linux_util.h>
@@ -193,7 +194,7 @@
     if (nvidia_count == 0) {
         nvidia_ctl_cdev = make_dev(&nvidia_ctl_cdevsw,
                 CDEV_CTL_MINOR,
-                UID_ROOT, GID_WHEEL, 0666,
+                UID_ROOT, nvga_device_gid(), nvga_device_mode(),
                 "%s", nvidia_ctl_cdevsw.d_name);
         if (nvidia_ctl_cdev == NULL)
             return ENOMEM;

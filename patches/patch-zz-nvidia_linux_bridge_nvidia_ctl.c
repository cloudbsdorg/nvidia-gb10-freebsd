--- nvidia/nvidia_ctl.c.orig
+++ nvidia/nvidia_ctl.c
@@ -12,6 +12,7 @@
 #include "nv.h"
 #include "nv-chardev-numbers.h"
 #include "nv-freebsd.h"
+#include "nvidia_bridge.h"
 
 #ifdef NV_SUPPORT_LINUX_COMPAT
 #include <compat/linux/linux_util.h>
@@ -199,6 +200,9 @@
 
 #ifdef NV_SUPPORT_LINUX_COMPAT
 	linux_device_register_handler(&nvidia_ctl_linux_handler);
+#else
+	nvidia_bridge_cdev_added(nvidia_ctl_cdevsw.d_name,
+	    NV_MAJOR_DEVICE_NUMBER, CDEV_CTL_MINOR);
 #endif
     }
 
@@ -225,6 +229,8 @@
     if (nvidia_count == 0) {
 #ifdef NV_SUPPORT_LINUX_COMPAT
         linux_device_unregister_handler(&nvidia_ctl_linux_handler);
+#else
+        nvidia_bridge_cdev_removed(nvidia_ctl_cdevsw.d_name, CDEV_CTL_MINOR);
 #endif	
         destroy_dev(nvidia_ctl_cdev);
     }

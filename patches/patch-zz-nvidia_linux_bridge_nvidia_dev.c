--- nvidia/nvidia_dev.c.orig
+++ nvidia/nvidia_dev.c
@@ -12,6 +12,7 @@
 #include "nv.h"
 #include "nv-chardev-numbers.h"
 #include "nv-freebsd.h"
+#include "nvidia_bridge.h"
 
 static d_open_t  nvidia_dev_open;
 static d_ioctl_t nvidia_dev_ioctl;
@@ -199,6 +200,9 @@
     nvidia_dev_linux_handler.bsd_device_name = sc->cdev->si_name;
     nvidia_dev_linux_handler.linux_device_name = sc->cdev->si_name;
     (void)linux_device_register_handler(&nvidia_dev_linux_handler);
+#else
+    nvidia_bridge_cdev_added(sc->cdev->si_name, NV_MAJOR_DEVICE_NUMBER,
+        device_get_unit(sc->dev));
 #endif    
 
     return 0;
@@ -218,6 +222,8 @@
     };
 
     (void)linux_device_unregister_handler(&nvidia_dev_linux_handler);
+#else
+    nvidia_bridge_cdev_removed(sc->cdev->si_name, device_get_unit(sc->dev));
 #endif
 
     destroy_dev(sc->cdev);

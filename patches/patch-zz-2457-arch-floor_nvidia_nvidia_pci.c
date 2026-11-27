--- nvidia/nvidia_pci.c.orig
+++ nvidia/nvidia_pci.c
@@ -11,6 +11,7 @@
 #include "os-interface.h"
 #include "nv.h"
 #include "nv-freebsd.h"
+#include "nv_arch_floor.h"
 
 static void nvidia_pci_identify (driver_t *, device_t);
 static int  nvidia_pci_probe    (device_t);
@@ -44,6 +45,10 @@
 
     name = rm_get_device_name(device, subvendor, subdevice);
 
+    /* GA10x (RTX 30) and later only, for now (Track #2457) */
+    if (nv_arch_floor_probe(dev, name) != 0)
+        return ENXIO;
+
     device_set_desc_copy(dev, name);
 
     return 0;

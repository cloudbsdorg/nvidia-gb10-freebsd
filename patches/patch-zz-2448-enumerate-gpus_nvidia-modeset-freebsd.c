--- nvidia-modeset/nvidia-modeset-freebsd.c.orig
+++ nvidia-modeset/nvidia-modeset-freebsd.c
@@ -11,4 +11,5 @@
 #include <sys/types.h>
 #include <sys/param.h>
+#include <sys/bus.h>
 #include <sys/module.h>
 #include <sys/errno.h>
@@ -38,4 +39,10 @@
 #include "nv-kthread-q.h"
 
+#include "nvmisc.h"
+#define NVRM
+#include "nv.h"
+#include "nv-freebsd.h"
+#undef NVRM
+
 #include "nv-retpoline.h"
 
@@ -805,7 +812,59 @@
 }
 
-NvU32 nvkms_enumerate_gpus(nv_gpu_info_t *gpu_info)
+/*
+ * KAPI enumerateGpus is how a native kernel client finds the GPUs.  This stub
+ * returned 0 because FreeBSD nvidia-drm walks the devclass itself; its
+ * enumerateGpus probe is under #if defined(NV_LINUX) in nvidia-drm-drv.c.
+ * Fill it now so other native kernel clients can enumerate the devices.
+ *
+ * Time: O(U), where U is the highest unit number in the nvidia devclass;
+ *       at most NV_MAX_GPUS entries are written.
+ * Space: O(1).
+ */
+NvU32
+nvkms_enumerate_gpus(nv_gpu_info_t *gpu_info)
 {
-    return 0;
+    devclass_t nvidia_devclass;
+    int maxunit;
+    int unit;
+    NvU32 count = 0;
+
+    if (gpu_info == NULL) {
+        return 0;
+    }
+
+    bus_topo_lock();
+    nvidia_devclass = devclass_find("nvidia");
+    if (nvidia_devclass == NULL) {
+        bus_topo_unlock();
+        return 0;
+    }
+
+    maxunit = devclass_get_maxunit(nvidia_devclass);
+    for (unit = 0; unit < maxunit && count < NV_MAX_GPUS; unit++) {
+        struct nvidia_softc *sc = devclass_get_softc(nvidia_devclass, unit);
+        nv_state_t *nv;
+
+        if (sc == NULL || !device_is_attached(sc->dev)) {
+            continue;
+        }
+
+        nv = sc->nv_state;
+        if (nv == NULL) {
+            continue;
+        }
+
+        gpu_info[count].gpu_id = nv->gpu_id;
+        gpu_info[count].pci_info.domain = nv->pci_info.domain;
+        gpu_info[count].pci_info.bus = nv->pci_info.bus;
+        gpu_info[count].pci_info.slot = nv->pci_info.slot;
+        gpu_info[count].pci_info.function = nv->pci_info.function;
+        gpu_info[count].os_device_ptr = sc->dev;
+        gpu_info[count].needs_numa_setup = NV_FALSE;
+        count++;
+    }
+    bus_topo_unlock();
+
+    return count;
 }
 

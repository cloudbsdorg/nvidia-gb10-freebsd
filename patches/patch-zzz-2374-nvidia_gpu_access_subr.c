--- nvidia/nvidia_subr.c.orig
+++ nvidia/nvidia_subr.c
@@ -18,6 +18,7 @@
 #include "nv-caps.h"
 #include "nv-firmware.h"
 #include "nv-uvm-interface.h"	/* UVM top half, suspend/resume hooks (gb10) */
+#include "nvga_glue.h"		/* GPU access check, wired memory accounting (gb10) */
 #include "gb10_pageimport.h"	/* cross-GPU import core, docs/PRIME-IMPORT.md */
 
 #include <sys/consio.h>
@@ -496,6 +497,34 @@
             nvffp->num_attached_gpus = num_arg_gpus;
 
             status = 0;
+
+            /*
+             * Track #2374: the caller may attach only the GPUs it may use.
+             * The check runs before any GPU is opened, so the RM never sees
+             * a GPU the caller has no right to, and a refused attach leaves
+             * nothing open.
+             */
+            for (i = 0; i < nvffp->num_attached_gpus; i++)
+            {
+                if (nvffp->attached_gpus[i] == 0)
+                {
+                    continue;
+                }
+
+                if (nvga_check_attach(nvffp->attached_gpus[i]) != 0)
+                {
+                    free(nvffp->attached_gpus, M_NVIDIA);
+                    nvffp->num_attached_gpus = 0;
+
+                    status = EPERM;
+                    break;
+                }
+            }
+
+            if (status != 0)
+            {
+                break;
+            }
 
             for (i = 0; i < nvffp->num_attached_gpus; i++)
             {
@@ -869,6 +898,12 @@
             sc->nv_state = (void *)&nvidia_ctl_state;
 
             nvidia_sysctl_init();
+            /*
+             * Track #2374 and #2376: the rules of the access check (the
+             * group that owns the RM nodes, the host root) are set before
+             * any client can ask for a GPU.
+             */
+            nvga_init();
 #if defined(__aarch64__)
             /*
              * arm64: decide the BAR memory-attribute policy (ACPI MCFG +
@@ -2450,6 +2485,27 @@
     nv_state_t *nv
 )
 {
+    /*
+     * Track #2374: the RM asks whether it may use this GPU.  The answer is
+     * the right of the calling credential to use that GPU, decided per
+     * credential and per jail (src/gb10-gpu-access/nvga_glue.h).  The
+     * control device is not a GPU: it is always allowed.
+     */
+    const struct nvidia_softc *sc;
+    int unit, decision;
+
+    if (nv == NULL)
+        return NV_FALSE;
+
+    sc = nv->os_state;
+    if (sc == NULL || sc->dev == NULL)
+        return NV_TRUE;
+
+    unit = device_get_unit(sc->dev);
+    decision = nvga_may_use_unit(unit);
+    if (decision != NVGA_ALLOW)
+        return NV_FALSE;
+
     return NV_TRUE;
 }
 

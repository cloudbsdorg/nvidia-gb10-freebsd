--- nvidia-modeset/nvidia-modeset-freebsd.c.orig
+++ nvidia-modeset/nvidia-modeset-freebsd.c
@@ -42,14 +42,15 @@
 #include "nvmisc.h"
 #define NVRM
 #include "nv.h"
 #include "nv-freebsd.h"
 #undef NVRM
 
 #include "nv-retpoline.h"
+#include "nvga_nodes.h"		/* the mode and the group of the RM nodes (gb10) */
 
 /*
  * This option decides if nvidia-modeset.ko will be built with support
  * for Linux or Linux 32-bit (FreeBSD/amd64) compatibility.  This
  * makes nvidia-modeset.ko dependent on linux.ko; if you don't need
  * Linux compatibility, then you can safely unset this flag.
  */
@@ -1397,15 +1398,15 @@
         nvkms_module.is_unloading = NV_FALSE;
 
         LIST_INIT(&nvkms_timers.list);
         mtx_init(&nvkms_timers.lock, "nvidia-modeset timer lock", NULL, MTX_SPIN);
 
         nvkms_dev = make_dev(&nvkms_cdevsw,
                              NVKMS_CDEV_MINOR,
-                             UID_ROOT, GID_WHEEL, 0666,
+                             UID_ROOT, nvga_nodes_gid(), NVGA_NODES_MODE,
                              "nvidia-modeset");
 
         if (nvkms_dev == NULL) {
             nv_kthread_q_stop(&nvkms_kthread_q);
             sx_destroy(&nvkms_module.lock);
             mtx_destroy(&nvkms_timers.lock);
             sx_destroy(&nvkms_lock);

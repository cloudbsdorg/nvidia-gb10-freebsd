--- nvidia/nvidia_subr.c.orig
+++ nvidia/nvidia_subr.c
@@ -337,6 +337,9 @@
     return 0;
 }
 
+/* Track #2373: which nvidiactl file owns each RM client (table, hold/release, ioctl hook, close) */
+#include "nvco_glue.h"
+
 int nvidia_handle_ioctl(
     nv_state_t *nv,
     nv_freebsd_file_private_t *nvffp,
@@ -391,6 +394,19 @@
         }
 
         nr = xfer->cmd;
+    }
+
+    /*
+     * Track #2373: a client free waits for its holds here, before fops_sx
+     * and every RM lock (see nvco_glue.h); the ioctl proper follows.
+     */
+    struct nvco_ioctl_ctx nvco_ctx;
+    const void *nvco_who = (nv->flags & NV_FLAG_CONTROL) != 0 ? nvffp : NULL;
+    int nvco_error = nvco_ioctl_begin(&nvco_ctx, nr, size, args);
+
+    if (nvco_error != 0) {
+        status = nvco_error;    /* EINTR, or ERESTART for a restartable signal: nothing was freed */
+        goto nvco_out;
     }
 
     sx_xlock(&nvffp->fops_sx);
@@ -481,9 +497,12 @@
                             args, size) == NV_OK) ? 0 : EINVAL);
             break;
     }
+
+    nvco_ioctl_end(&nvco_ctx, nvco_who, status, nr, size, args);    /* Track #2373: under fops_sx, so one file's records follow its RM order */
 
     sx_xunlock(&nvffp->fops_sx);
 
+nvco_out:
     if (args != (void *)data) {
         if (copyout(args, NvP64_VALUE(xfer->ptr), size) != 0)
             status = EFAULT;
@@ -523,6 +542,9 @@
 {
     struct nvidia_softc *sc = nv->os_state;
     nvidia_stack_t *sp = nvffp->fops_sp;
+
+    /* Track #2373: the file's clients stop being its own before RM frees them */
+    nvco_forget_owner(nvffp);
 
     rm_cleanup_file_private(sp, nv, &nvffp->nvfp);
 

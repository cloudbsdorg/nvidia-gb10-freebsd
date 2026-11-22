--- nvidia/nvidia_subr.c.orig
+++ nvidia/nvidia_subr.c
@@ -634,7 +634,26 @@
     return 0;
 
 failed:
-    NV_SHUTDOWN_ADAPTER(sp, nv);
+    /*
+     * Reached on a failed stack allocation (sp is NULL) and on a failed
+     * rm_init_adapter(), and on nothing else: a step added after the init
+     * succeeded must unwind with NV_SHUTDOWN_ADAPTER() (disable, then
+     * shutdown), not jump here.
+     *
+     * Track #2417: no rm_disable_adapter() here.  Every failure exit of
+     * RmInitAdapter has either run RmShutdownAdapter itself (its
+     * "shutdown:" label) or happened before any GPU object existed
+     * (RmSetupRegisters), so pGpu of the private state is NULL on return,
+     * and RmDisableAdapter dereferences it (GPU_GET_INTR(pGpu)): a data
+     * abort at NULL+0x19f8, a host panic.  RmShutdownAdapter tests pGpu
+     * before it uses it, so the one call that stays is safe.  The open RM
+     * source carries the same guard in RmDisableAdapter (patches/ogkm,
+     * zz-2417); the prebuilt RM core of an amd64 build does not, so this
+     * skip is what protects every build.  When the stack allocation itself
+     * failed, sp is NULL and neither RM function can be called.
+     */
+    if (sp != NULL)
+        rm_shutdown_adapter(sp, nv);
     nv_dev_free_stacks(sc);
     nv_unlock_api(nv);
 

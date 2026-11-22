--- src/nvidia/arch/nvalloc/unix/src/osinit.c.orig
+++ src/nvidia/arch/nvalloc/unix/src/osinit.c
@@ -2444,6 +2444,17 @@
     nv_priv_t *nvp  = NV_GET_NV_PRIV(nv);
 
     //
+    // CloudBSD (Track #2417): a GPU whose init failed has no pGpu (RmInitAdapter's
+    // cleanup clears it), and there is nothing to disable then.  The FreeBSD OS
+    // layer no longer calls this after a failed init (nvidia_open_dev, patches/
+    // patch-zz-nvidia_init_failure_subr.c); this guard keeps any other caller
+    // from faulting on the cleared state.  It is compiled into the arm64 RM core
+    // (scripts/build-rmcore.sh); the prebuilt amd64 core does not have it.
+    //
+    if (pGpu == NULL)
+        return;
+
+    //
     // Normally, we re-enable interrupts when we release the lock
     // after RmDisableAdapter(), before disabling the bottom-half ISR.
     // If an interrupt came in in that time window, but the bottom half

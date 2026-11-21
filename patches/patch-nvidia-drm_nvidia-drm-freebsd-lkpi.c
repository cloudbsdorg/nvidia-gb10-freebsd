--- nvidia-drm/nvidia-drm-freebsd-lkpi.c.orig
+++ nvidia-drm/nvidia-drm-freebsd-lkpi.c
@@ -213,10 +213,33 @@
     return 0;
 }
 
+/* the gate of the exports of imported buffers, in nvidia-drm-gem-dma-buf.c */
+extern int nv_drm_pi_live_holds(void);
+extern int nv_drm_pi_quiesce(int *held, int *kept);
+extern void nv_drm_pi_keep(void);
+
 static void nv_bsd_drm_exit(void)
 {
     nv_drm_exit();
 
+    if (nv_drm_pi_live_holds() > 0) {
+        /*
+         * Not reached in the unload order the guard module relies on (the
+         * guard loads last and so unloads first, and answers EBUSY while an
+         * export is held, for kldunload -f as well).  Reached if the driver
+         * module is ever unloaded BEFORE the guard (a different module
+         * order): then nv_drm_exit() has left the devices alone (see
+         * nv_drm_remove_devices()), the pdevs they use (the dma-buf
+         * attachment keeps &pdev->dev) stay too, and the gate is marked
+         * kept and closed.  The guard's MOD_UNLOAD still runs after this and
+         * refuses with the kept message, the file stays loaded, and every
+         * later quiesce and unload is refused until the machine is
+         * restarted: there, this IS the protection.  See docs/PRIME-IMPORT.md 7.7.
+         */
+        nv_drm_pi_keep();
+        return;
+    }
+
     // After doing the common DRM teardown, free any linuxkpi devices we
     // allocated during init
     for (int i = 0; i < NV_MAX_DEVICES; i++) {
@@ -237,5 +260,85 @@
 MODULE_DEPEND(nvidia_drm, drmn, 2, 2, 2);
 MODULE_DEPEND(nvidia_drm, dmabuf, 1, 1, 1);
 MODULE_DEPEND(nvidia_drm, nvidia, 1, 1, 1);
-MODULE_DEPEND(nvidia_drm, nvidia_modeset, 1, 1, 1);
+/* version 2: the KAPI table has the page-array member (NVKMS_KAPI_CBSD_LAYOUT) */
+MODULE_DEPEND(nvidia_drm, nvidia_modeset, 2, 2, 2);
+
+/*
+ * LKPI_DRIVER_MODULE cannot refuse an unload.  An RM file descriptor that
+ * holds an exported imported buffer calls back into this module and its
+ * device structures when it closes, so a second module in this file is the
+ * gate: MOD_QUIESCE is refused with EBUSY while any hold is live and, when
+ * none is, closes the gate (no new hold is given afterwards, the export
+ * fails cleanly).  A closed gate stays closed until the next boot: the
+ * kernel has no call that undoes a quiesce, so after a quiesce that was
+ * followed by an aborted unload, exports of imported buffers are refused.
+ * MOD_UNLOAD is refused while a hold is live as well, for a forced unload
+ * (kldunload -f ignores a refused quiesce).  The guard must be UNLOADED
+ * FIRST, before nvidia_drm's own teardown can run.  A file's modules are
+ * unloaded in the reverse of their load order (module_register_init() moves
+ * each loaded module to the head of the file's list, linker_file_unload()
+ * walks the list from the head), and the sysinits load in (subsystem, order)
+ * order, so the guard has to LOAD LAST: SI_ORDER_LAST, above the
+ * SI_ORDER_ANY of LKPI_DRIVER_MODULE in the same subsystem.  kldstat -v shows
+ * the unload order (first listed, first unloaded); the boot kit checks it.
+ */
+static int
+nv_drm_pi_guard_handler(module_t mod, int what, void *arg)
+{
+    int held, kept;
+
+    switch (what) {
+    case MOD_LOAD:
+        return 0;
+    case MOD_QUIESCE:
+        if (nv_drm_pi_quiesce(&held, &kept) != 0) {
+            if (kept) {
+                printf("nvidia_drm: unload refused: the driver was torn down "
+                       "while RM exports were open and its display devices "
+                       "were kept; restart the machine before unloading this "
+                       "module\n");
+            } else {
+                printf("nvidia_drm: unload refused: %d RM export(s) of "
+                       "imported buffers are still open; close the processes "
+                       "that hold them (fstat /dev/nvidiactl) and try again\n",
+                       held);
+            }
+            return EBUSY;
+        }
+        return 0;
+    case MOD_UNLOAD:
+        /*
+         * The same gate as the quiesce, so that an unload that skipped the
+         * quiesce (kldunload -f ignores a refused quiesce) still closes it
+         * when no export is held, and a hold cannot arrive between this
+         * check and the teardown.  An EBUSY from here stops even a forced
+         * unload (linker_file_unload() returns a module's unload error
+         * whatever the flags), and this module is the first of the file to be
+         * unloaded (it loads last, SI_ORDER_LAST), so it answers before the
+         * driver's own teardown has run: see docs/PRIME-IMPORT.md 7.7.
+         */
+        if (nv_drm_pi_quiesce(&held, &kept) != 0) {
+            if (kept) {
+                printf("nvidia_drm: unload refused, also for kldunload -f: "
+                       "the driver was torn down while RM exports were open "
+                       "and its display devices were kept; restart the "
+                       "machine\n");
+            } else {
+                printf("nvidia_drm: unload refused, also for kldunload -f: "
+                       "%d RM export(s) of imported buffers are still open; "
+                       "close the processes that hold them (fstat "
+                       "/dev/nvidiactl) and try again\n", held);
+            }
+            return EBUSY;
+        }
+        return 0;
+    default:
+        return EOPNOTSUPP;
+    }
+}
+
+static moduledata_t nv_drm_pi_guard_mod = {
+    "nvidia_drm_pi_guard", nv_drm_pi_guard_handler, NULL
+};
+DECLARE_MODULE(nvidia_drm_pi_guard, nv_drm_pi_guard_mod, SI_SUB_DRIVERS, SI_ORDER_LAST);
 #endif /* NV_DRM_AVAILABLE */

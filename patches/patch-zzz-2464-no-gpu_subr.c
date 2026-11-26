--- nvidia/nvidia_subr.c.orig
+++ nvidia/nvidia_subr.c
@@ -594,6 +594,15 @@
     struct nvidia_softc *sc = nv->os_state;
 
     nv_lock_api(nv);
+    /*
+     * The module may be unloading: the control device is on its way out,
+     * and the resource manager with it.  An open that was in flight when
+     * the unload began must not reach a resource manager that is gone.
+     */
+    if (!nvidia_ctl_module_alive()) {
+        nv_unlock_api(nv);
+        return ENXIO;
+    }
     if (sc->refcnt == 0) {
         NV_UMA_ZONE_ALLOC_STACK(sc->sp[NV_DEV_STACK_API]);
         if (sc->sp[NV_DEV_STACK_API] == NULL) {
@@ -819,6 +828,8 @@
     nv_state_t *nv;
     struct nvidia_softc *sc;
     nvidia_stack_t *sp;
+    char msg[192];
+    int status;
 
     switch (what) {
         case MOD_LOAD:
@@ -869,6 +880,29 @@
             sc->nv_state = (void *)&nvidia_ctl_state;
 
             nvidia_sysctl_init();
+
+            /*
+             * The control device belongs to the module: it is created
+             * here, when the module loads, and destroyed when the module
+             * unloads, whether a GPU is attached or not.  Before, the
+             * first GPU to attach created it and the last one to detach
+             * destroyed it, so a host with no NVIDIA GPU had no control
+             * device at all: the tools could not ask the driver how many
+             * GPUs it has, and the answer could not be "none".
+             */
+            status = nvidia_ctl_module_attach();
+            if (status != 0) {
+                nv_ctl_create_error(status, msg, sizeof(msg));
+                printf("NVRM: %s\n", msg);
+                nvidia_sysctl_exit();
+                sx_destroy(&sc->api_sx);
+                nvidia_lock_destroy_locks(sp, &nvidia_ctl_state);
+                rm_shutdown_rm(sp);
+                NV_UMA_ZONE_FREE_STACK(sp);
+                uma_zdestroy(nvidia_stack_t_zone);
+                return status;
+            }
+
 #if defined(__aarch64__)
             /*
              * arm64: decide the BAR memory-attribute policy (ACPI MCFG +
@@ -900,6 +934,17 @@
                 return EBUSY;
             }
 
+            /*
+             * The control device goes first, while the API lock is still
+             * held: an open of /dev/nvidiactl waits for that lock, so it
+             * cannot slip in between the check above and the destroy,
+             * and once the destroy is done it finds no usable device.
+             * The resource manager is still up for the descriptors that
+             * are already open, but there are none: an open one would
+             * have made the check above refuse the unload.
+             */
+            nvidia_ctl_module_detach();
+
             nv_unlock_api(nv);
 
             mtx_destroy(&snapshot_timer_mutex);

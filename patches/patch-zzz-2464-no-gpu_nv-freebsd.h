--- nvidia/nv-freebsd.h.orig
+++ nvidia/nv-freebsd.h
@@ -290,7 +290,19 @@
 /* nvidia_ctl.c */
 int    nvidia_ctl_attach     (void);
 int    nvidia_ctl_detach     (void);
+/* The module's half of the control device's lifetime: the device exists
+ * from the module load to the module unload, with a GPU attached or not.
+ * nvidia_ctl_module_alive() says whether it may still be used.  The
+ * number of GPUs the driver has attached is the driver's own state and
+ * lives in nv_ctl_state.h, with the node that reads it. */
+int    nvidia_ctl_module_attach  (void);
+void   nvidia_ctl_module_detach  (void);
+int    nvidia_ctl_module_alive   (void);
 
+/* The message the driver prints when it cannot create the control
+ * device: it names the device, the reason and what to do about it. */
+void   nv_ctl_create_error       (int, char *, size_t);
+
 #ifdef NV_SUPPORT_LINUX_COMPAT
 extern const char nvidia_driver_name[];
 #endif

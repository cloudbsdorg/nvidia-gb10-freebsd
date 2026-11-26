--- nvidia/nvidia_ctl.c.orig
+++ nvidia/nvidia_ctl.c
@@ -12,6 +12,7 @@
 #include "nv.h"
 #include "nv-chardev-numbers.h"
 #include "nv-freebsd.h"
+#include "nv_ctl_state.h"
 #include "nvidia_bridge.h"
 
 #ifdef NV_SUPPORT_LINUX_COMPAT
@@ -37,8 +38,35 @@
 static struct cdev *nvidia_ctl_cdev = NULL;
 struct nvidia_softc nvidia_ctl_sc;
 
-static int nvidia_count = 0;
+#ifdef NV_SUPPORT_LINUX_COMPAT
+/*
+ * The Linux compat handler of the control device.  The device belongs to
+ * the module, so its registration does too: the module registers it when
+ * it makes the device and unregisters it when it destroys it.
+ */
+static struct linux_device_handler nvidia_ctl_linux_handler;
 
+/*
+ * The handler names the driver and the device.  Both are read from the
+ * driver's own table, so they are filled in when the device is made.
+ */
+static void
+nvidia_ctl_linux_handler_init(void)
+{
+    nvidia_ctl_linux_handler.bsd_driver_name =
+        __DECONST(char *, nvidia_driver_name);
+    nvidia_ctl_linux_handler.linux_driver_name =
+        __DECONST(char *, nvidia_driver_name);
+    nvidia_ctl_linux_handler.bsd_device_name =
+        __DECONST(char *, nvidia_ctl_cdevsw.d_name);
+    nvidia_ctl_linux_handler.linux_device_name =
+        __DECONST(char *, nvidia_ctl_cdevsw.d_name);
+    nvidia_ctl_linux_handler.linux_major = NV_MAJOR_DEVICE_NUMBER;
+    nvidia_ctl_linux_handler.linux_minor = CDEV_CTL_MINOR;
+    nvidia_ctl_linux_handler.linux_char_device = 1;
+}
+#endif
+
 static int nvidia_ctl_open(
     struct cdev *dev,
     int oflags,
@@ -50,6 +78,13 @@
     nv_state_t *nv = &nvidia_ctl_state;
     nv_freebsd_file_private_t *nvffp;
 
+    /*
+     * The module is unloading: the control device is on its way out,
+     * so an open must not reach the resource manager.
+     */
+    if (!nv_ctl_state_device_alive())
+        return ENXIO;
+
     nvffp = malloc(sizeof(nv_freebsd_file_private_t),
                    M_NVIDIA, (M_WAITOK | M_ZERO));
     if (nvffp == NULL)
@@ -124,6 +159,13 @@
     nv_state_t *nv = &nvidia_ctl_state;
     nv_freebsd_file_private_t *nvffp;
 
+    /*
+     * The module is unloading: the resource manager is on its way out,
+     * so an ioctl must not reach it.
+     */
+    if (!nv_ctl_state_device_alive())
+        return ENODEV;
+
     status = devfs_get_cdevpriv((void **)&nvffp);
     if (status != 0)
         return status;
@@ -176,64 +218,131 @@
     return nvidia_mmap_ctl_single(nvffp, offset, size, object, nprot);
 }
 
-int nvidia_ctl_attach(void)
+/*
+ * The control device belongs to the module, not to the first GPU: it is
+ * created when the module loads and destroyed when the module unloads.
+ * Before, the first GPU to attach created it and the last one to detach
+ * destroyed it, so a host with no NVIDIA GPU had no control device at all:
+ * the tools could not ask the driver how many GPUs it has, and the answer
+ * could not be "none".
+ *
+ * The module is the only owner: a GPU that attaches does not create the
+ * device and a GPU that detaches does not destroy it.  Two owners of one
+ * device are two creations and two destructions waiting to happen.
+ */
+static int
+nvidia_ctl_dev_create(void)
 {
-#ifdef NV_SUPPORT_LINUX_COMPAT
-    struct linux_device_handler nvidia_ctl_linux_handler = { 
-        .bsd_driver_name = __DECONST(char *, nvidia_driver_name),
-        .linux_driver_name = __DECONST(char *, nvidia_driver_name),
-        .bsd_device_name = __DECONST(char *, nvidia_ctl_cdevsw.d_name),
-        .linux_device_name = __DECONST(char *, nvidia_ctl_cdevsw.d_name),
-        .linux_major = NV_MAJOR_DEVICE_NUMBER,
-        .linux_minor = CDEV_CTL_MINOR,
-        .linux_char_device = 1 
-    };  
-#endif
+    int error;
 
-    if (nvidia_count == 0) {
-        nvidia_ctl_cdev = make_dev(&nvidia_ctl_cdevsw,
-                CDEV_CTL_MINOR,
-                UID_ROOT, GID_WHEEL, 0666,
-                "%s", nvidia_ctl_cdevsw.d_name);
-        if (nvidia_ctl_cdev == NULL)
-            return ENOMEM;
+    if (nvidia_ctl_cdev != NULL)
+        return (0);
 
-#ifdef NV_SUPPORT_LINUX_COMPAT
-	linux_device_register_handler(&nvidia_ctl_linux_handler);
-#else
-	nvidia_bridge_cdev_added(nvidia_ctl_cdevsw.d_name,
-	    NV_MAJOR_DEVICE_NUMBER, CDEV_CTL_MINOR);
-#endif
-    }
+    /*
+     * The device node is made by devfs.  make_dev() does not say why
+     * it could not: on the kernels that hand back a null pointer it
+     * says nothing at all, and on the ones that do not it panics
+     * instead.  make_dev_s() is the same call with the reason kept:
+     * the code it returns is the cause, and it is handed back
+     * unchanged, so the message the driver prints names the real
+     * failure and not some other one.
+     */
+    {
+        struct make_dev_args args;
+        struct cdev *cdev;
 
-    nvidia_count++;
-    return 0;
-}
+        make_dev_args_init(&args);
+        args.mda_devsw = &nvidia_ctl_cdevsw;
+        args.mda_unit = CDEV_CTL_MINOR;
+        args.mda_uid = UID_ROOT;
+        args.mda_gid = GID_WHEEL;
+        args.mda_mode = 0666;
+        args.mda_flags = MAKEDEV_CHECKNAME;
+        cdev = NULL;
+        error = make_dev_s(&args, &cdev, "%s", nvidia_ctl_cdevsw.d_name);
+        if (error != 0)
+            return (error);
+        nvidia_ctl_cdev = cdev;
+    }
 
-int nvidia_ctl_detach(void)
-{
 #ifdef NV_SUPPORT_LINUX_COMPAT
-    struct linux_device_handler nvidia_ctl_linux_handler = { 
-        .bsd_driver_name = __DECONST(char *, nvidia_driver_name),
-        .linux_driver_name = __DECONST(char *, nvidia_driver_name),
-        .bsd_device_name = __DECONST(char *, nvidia_ctl_cdevsw.d_name),
-        .linux_device_name = __DECONST(char *, nvidia_ctl_cdevsw.d_name),
-        .linux_major = NV_MAJOR_DEVICE_NUMBER,
-        .linux_minor = CDEV_CTL_MINOR,
-        .linux_char_device = 1 
-    };  
+    nvidia_ctl_linux_handler_init();
+    linux_device_register_handler(&nvidia_ctl_linux_handler);
+#else
+    nvidia_bridge_cdev_added(nvidia_ctl_cdevsw.d_name,
+        NV_MAJOR_DEVICE_NUMBER, CDEV_CTL_MINOR);
 #endif
 
-    nvidia_count--;
+    return (0);
+}
 
-    if (nvidia_count == 0) {
+static void
+nvidia_ctl_dev_destroy(void)
+{
+    if (nvidia_ctl_cdev == NULL)
+        return;
+
 #ifdef NV_SUPPORT_LINUX_COMPAT
-        linux_device_unregister_handler(&nvidia_ctl_linux_handler);
+    linux_device_unregister_handler(&nvidia_ctl_linux_handler);
 #else
-        nvidia_bridge_cdev_removed(nvidia_ctl_cdevsw.d_name, CDEV_CTL_MINOR);
-#endif	
-        destroy_dev(nvidia_ctl_cdev);
-    }
+    nvidia_bridge_cdev_removed(nvidia_ctl_cdevsw.d_name, CDEV_CTL_MINOR);
+#endif
 
+    destroy_dev(nvidia_ctl_cdev);
+    nvidia_ctl_cdev = NULL;
+}
+
+/*
+ * The module's half of the control device's lifetime.  The device exists
+ * from the module load to the module unload, whether a GPU is attached or
+ * not.
+ */
+int nvidia_ctl_module_attach(void)
+{
+    int error;
+
+    error = nvidia_ctl_dev_create();
+    if (error != 0)
+        return (error);
+
+    nv_ctl_state_device_created();
+    return (0);
+}
+
+void nvidia_ctl_module_detach(void)
+{
+    /*
+     * The device stops being usable before it is destroyed: an open that
+     * was in flight finds no usable device and gives up, instead of
+     * reaching a resource manager that is on its way out.
+     */
+    nv_ctl_state_device_destroyed();
+
+    nvidia_ctl_dev_destroy();
+}
+
+/* Whether the control device may still be used. */
+int nvidia_ctl_module_alive(void)
+{
+    return (nv_ctl_state_device_alive());
+}
+
+/*
+ * A GPU attached: the driver has one GPU more.  The count is the
+ * driver's own, and hw.nvidia.device_count reads it.
+ */
+int nvidia_ctl_attach(void)
+{
+    nv_ctl_state_gpu_attach();
     return 0;
 }
+
+/*
+ * A GPU detached: the driver has one GPU less.  The count never goes
+ * below zero.
+ */
+int nvidia_ctl_detach(void)
+{
+    nv_ctl_state_gpu_detach();
+    return 0;
+}

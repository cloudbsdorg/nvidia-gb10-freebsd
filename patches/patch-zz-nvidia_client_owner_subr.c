--- nvidia/nvidia_subr.c.orig
+++ nvidia/nvidia_subr.c
@@ -44,6 +44,28 @@
 #endif
 
 uma_zone_t nvidia_stack_t_zone;
+
+/*
+ * Which open /dev/nvidiactl file each RM client was allocated on, for
+ * nvidia-uvm.ko (Track #2373): see nv_client_owner.h.  An sx lock, because
+ * the table grows with M_WAITOK; the order is fops_sx, then nvco_sx.
+ */
+#define NVCO_MALLOC(n)  malloc((n), M_NVIDIA, M_WAITOK)
+#define NVCO_FREE(p)    free((p), M_NVIDIA)
+#include "nv_client_owner.h"
+
+static struct sx nvco_sx;
+static struct nvco_table nvco_table;
+SX_SYSINIT(nvco_sx, &nvco_sx, "nvco_sx");
+
+static void
+nvco_unload(void *arg __unused)
+{
+    sx_xlock(&nvco_sx);
+    nvco_destroy(&nvco_table);
+    sx_xunlock(&nvco_sx);
+}
+SYSUNINIT(nvco_unload, SI_SUB_DRIVERS, SI_ORDER_ANY, nvco_unload, NULL);
 static nvidia_stack_t *__nvidia_init_sp = NULL;
 
 devclass_t nvidia_devclass;
@@ -477,9 +499,58 @@
         }
 
         default:
+        {
+            /*
+             * Track #2373: a root-client allocation or free and the table
+             * change are one step under the table lock, so the table never
+             * lags the RM (a freed handle that the RM reuses cannot stay
+             * attributed to its old owner).  Only these rare operations
+             * take the lock.  A free waits for the holds in flight to end
+             * (nvUvmInterfaceClientHold); when the freeing file owns the
+             * client it also stops new holds meanwhile.  The wait is a
+             * signal-interruptible sleep, wait channel "nvcobusy", and while
+             * it lasts every ioctl on this file waits too (fops_sx).  Order:
+             * fops_sx, nvco_sx, then RM's locks.  nr and size are the real
+             * ones: a transfer escape is unwrapped above.
+             */
+            int client_op = nvco_is_client_op(nr, size, args);
+            int free_ok;
+            NvHandle free_h = nvco_client_free_handle(nr, size, args, &free_ok);
+            const void *who = (nv->flags & NV_FLAG_CONTROL) != 0 ? nvffp : NULL;
+            int counted = 0;
+            int wait_error = 0;
+
+            if (client_op) {
+                sx_xlock(&nvco_sx);
+                if (free_ok) {
+                    counted = nvco_begin_free(&nvco_table, who, free_h);
+                    while (wait_error == 0 && nvco_busy(&nvco_table, free_h))
+                        wait_error = sx_sleep(&nvco_table, &nvco_sx, PCATCH,
+                            "nvcobusy", 0);
+                    if (wait_error != 0)
+                        nvco_end_free(&nvco_table, free_h, who, counted);
+                }
+            }
+            if (wait_error != 0) {
+                status = wait_error;    /* EINTR, or ERESTART for a restartable signal: nothing was freed */
+                sx_xunlock(&nvco_sx);
+                break;
+            }
             status = ((rm_ioctl(sp, nv, &nvffp->nvfp, nr,
                             args, size) == NV_OK) ? 0 : EINVAL);
+            if (client_op) {
+                if (status == 0 &&
+                    nvco_after_ioctl(&nvco_table, who, nr, size, args) != 0)
+                    printf("NVRM: RM client 0x%x was not recorded for nvidia-uvm "
+                        "(handle already listed for another file, or out of memory): "
+                        "nvidia-uvm will refuse requests on it; free and reallocate it\n",
+                        (unsigned)nvco_alloc_handle(args));
+                if (free_ok)
+                    nvco_end_free(&nvco_table, free_h, who, counted);
+                sx_xunlock(&nvco_sx);
+            }
             break;
+        }
     }
 
     sx_xunlock(&nvffp->fops_sx);
@@ -523,6 +594,11 @@
 {
     struct nvidia_softc *sc = nv->os_state;
     nvidia_stack_t *sp = nvffp->fops_sp;
+
+    /* Track #2373: the file's clients stop being its own before RM frees them */
+    sx_xlock(&nvco_sx);
+    nvco_remove_owner(&nvco_table, nvffp);
+    sx_xunlock(&nvco_sx);
 
     rm_cleanup_file_private(sp, nv, &nvffp->nvfp);
 
@@ -952,7 +1028,97 @@
         size = (NvUPtr)pPrivate;
         vm_map_remove(kernel_map, virtual_address,
             (virtual_address + size));
+    }
+}
+
+/*
+ * nvco_file_owner - the table's name for an open file: the file's private
+ * data when fp is a /dev/nvidiactl file of this module, else NULL.  The file
+ * must be a character device node of devfs: only then does f_cdevpriv exist
+ * (on a regular file the same union member is the fadvise state).
+ */
+static const void *
+nvco_file_owner(struct file *fp)
+{
+    struct cdev_privdata *p;
+    struct vnode *vp;
+    struct cdev *dev;
+
+    if (fp == NULL || fp->f_type != DTYPE_VNODE)
+        return NULL;
+    vp = fp->f_vnode;
+    if (vp == NULL || vp->v_type != VCHR)
+        return NULL;
+    dev = vp->v_rdev;
+    if (dev == NULL || dev->si_devsw == NULL ||
+        strcmp(dev->si_devsw->d_name, "nvidiactl") != 0)
+        return NULL;
+    p = fp->f_cdevpriv;
+    if (p == NULL || p->cdpd_dtr != nvidia_ctl_dtor)
+        return NULL;
+    return p->cdpd_data;
+}
+
+/*
+ * nvUvmInterfaceClientHold - NV_OK only when fp is an open /dev/nvidiactl
+ * file of this module and hClient is an RM client allocated on that very
+ * file; NV_ERR_INSUFFICIENT_PERMISSIONS otherwise (nothing taken).  On
+ * NV_OK the client is held: a free of it waits and the file cannot close
+ * (the hold keeps its own reference on fp) until
+ * nvUvmInterfaceClientRelease(fp, hClient) with the same fp and handle,
+ * which the caller calls exactly once per NV_OK and never after a refusal.
+ * Holds nest per client.  A hold delays only a free of that client, but a
+ * waiting free delays every ioctl on the file it was made on (see the
+ * ioctl hook), so hold no longer than one request.  Context: sleepable, no
+ * RM lock held, never from an RM callback or from inside rm_ioctl (a hold
+ * from a thread that holds the table lock is refused; a release from one
+ * is a bug and asserts on a debug kernel).  The caller holds a
+ * reference on fp of its own across this call.  Track #2373.
+ */
+NV_STATUS nvUvmInterfaceClientHold(struct file *fp, NvHandle hClient);
+void nvUvmInterfaceClientRelease(struct file *fp, NvHandle hClient);
+
+NV_STATUS
+nvUvmInterfaceClientHold(struct file *fp, NvHandle hClient)
+{
+    const void *owner = nvco_file_owner(fp);
+    int held;
+
+    if (owner == NULL || sx_xlocked(&nvco_sx))
+        return NV_ERR_INSUFFICIENT_PERMISSIONS;
+    sx_xlock(&nvco_sx);
+    held = nvco_hold(&nvco_table, owner, fp, hClient);
+    sx_xunlock(&nvco_sx);
+    if (!held)
+        return NV_ERR_INSUFFICIENT_PERMISSIONS;
+    /* the hold's own reference: the file cannot close under it */
+    if (!fhold(fp)) {
+        sx_xlock(&nvco_sx);
+        (void)nvco_unhold(&nvco_table, fp, hClient);
+        sx_xunlock(&nvco_sx);
+        wakeup(&nvco_table);
+        return NV_ERR_INSUFFICIENT_PERMISSIONS;
     }
+    return NV_OK;
+}
+
+void
+nvUvmInterfaceClientRelease(struct file *fp, NvHandle hClient)
+{
+    int was_held;
+
+    /* same context rule as the hold: not from an RM callback, not under the table lock */
+    KASSERT(!sx_xlocked(&nvco_sx), ("nvidia: client release under the table lock"));
+    sx_xlock(&nvco_sx);
+    was_held = nvco_unhold(&nvco_table, fp, hClient);   /* matched on the file the hold took */
+    sx_xunlock(&nvco_sx);
+    wakeup(&nvco_table);
+    KASSERT(was_held, ("nvidia: client release without a matching hold"));
+    if (was_held)
+        fdrop(fp, curthread);    /* last: its close needs the table */
+    else
+        printf("NVRM: nvUvmInterfaceClientRelease: no hold on client 0x%x for this file (nvidia-uvm bug)\n",
+            (unsigned)hClient);
 }
 
 nv_file_private_t* NV_API_CALL nv_get_file_private(

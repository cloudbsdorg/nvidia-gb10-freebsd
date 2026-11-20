--- nvidia-drm/nvidia-drm-fb.c.orig
+++ nvidia-drm/nvidia-drm-fb.c
@@ -159,6 +159,40 @@
         struct drm_gem_object *gem = fb->obj[i];
         if (gem != NULL) {
             nv_gem = to_nv_gem_object(gem);
+
+            /*
+             * A plane without an NVKMS memory handle cannot be described
+             * to NVKMS and cannot be scanned out.  The KAPI's isVidmem()
+             * dereferences the handle it is given (nvkms-kapi.c:
+             * IsVidmem() returns memory->isVidmem), so a NULL handle is
+             * a kernel panic there and not an error return.
+             *
+             * A NULL handle is what a dma-buf import leaves behind when
+             * the RM cannot import the buffer: on FreeBSD the OS layer
+             * has no dma-buf import (nvidia_subr.c:
+             * nv_dma_import_dma_buf() returns NV_ERR_NOT_SUPPORTED), so
+             * getSystemMemoryHandleFromDmaBuf() returns NULL and the
+             * GEM object is created without a handle.  amp001,
+             * 2026-11-19: a Wayland login on a machine with an amdgpu
+             * and an NVIDIA card panicked the kernel in IsVidmem (x0=0,
+             * far 0x28) through drm_mode_addfb2.
+             *
+             * The user-memory and fence-context GEM objects have no
+             * handle by design and are not framebuffer planes either.
+             *
+             * Refuse the framebuffer instead of panicking.  The failure
+             * path below cleans up the DRM framebuffer object, and the
+             * caller (nv_drm_framebuffer_create) drops the references
+             * taken on the GEM objects, so no reference is left behind.
+             */
+            if (nv_gem->pMemory == NULL) {
+                NV_DRM_DEV_LOG_ERR(
+                    nv_dev,
+                    "Plane %u has no NVKMS memory handle; refusing the "
+                    "framebuffer",
+                    i);
+                goto fail;
+            }
 
             params.planes[i].memory = nv_gem->pMemory;
             params.planes[i].offset = fb->offsets[i];

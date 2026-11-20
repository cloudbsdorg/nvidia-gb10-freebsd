--- nvidia/nvidia_subr.c.orig
+++ nvidia/nvidia_subr.c
@@ -17,6 +17,8 @@
 #include "nv-freebsd.h"
 #include "nv-caps.h"
 #include "nv-firmware.h"
+#include <vm/vm_phys.h>		/* vm_phys_paddr_to_vm_page() */
+#include "gb10_pageimport.h"	/* cross-GPU import core, docs/PRIME-IMPORT.md */
 
 #include <sys/consio.h>
 #include <sys/fbio.h>
@@ -2114,9 +2116,140 @@
     nv_state_t *nv,
     void       *priv_data
 )
+{
+}
+
+/*
+ * Cross-GPU buffer import (PRIME), Track #2228, docs/PRIME-IMPORT.md.
+ *
+ * A buffer another GPU rendered into reaches nvidia-drm.ko as a Linux
+ * scatter list, which this module cannot read (struct sg_table is only
+ * declared in nv.h).  nvidia-drm turns it into an array of vm_page pointers
+ * and the logic below, in gb10_pageimport.h, wires and unwires the pages.
+ * Two entry points use it:
+ *
+ *  - nv_import_pages()/nv_unimport_pages(): the array the RM's page-array
+ *    descriptor takes (NVOS32_DESCRIPTOR_TYPE_OS_PAGE_ARRAY).  The RM's
+ *    teardown (osDestroyOsDescriptorPageArray) calls os_unlock_user_pages(),
+ *    which unwires one reference per page, drops nothing else and frees the
+ *    array with os_free_mem(): so the array is allocated with os_alloc_mem()
+ *    and every page is wired exactly once here.
+ *  - nv_dma_import_sgt() and its siblings: the SGT path the export ioctl
+ *    uses.  The "sg_table" the RM passes through is a struct gb10_pi_desc.
+ */
+
+/* The page `index` pages after `first`, or NULL when it is not a RAM page without a VM object. */
+static void *
+nv_pi_page_at(void *ctx, void *first, unsigned long long index)
+{
+    vm_page_t m = first;
+    vm_page_t p;
+
+    if (m == NULL || (m->flags & PG_FICTITIOUS) != 0)
+        return NULL;
+    p = vm_phys_paddr_to_vm_page(VM_PAGE_TO_PHYS(m) +
+                                 ((vm_paddr_t)index << PAGE_SHIFT));
+    if (p == NULL || (p->flags & PG_FICTITIOUS) != 0)
+        return NULL;
+    if (index == 0 && p != m)
+        return NULL;
+    /*
+     * A page that belongs to a VM object can only be wired with the
+     * object locked (vm_page_wire() asserts it under INVARIANTS) and can
+     * be renamed or freed under us; pages of a GPU driver's buffers
+     * (linuxkpi allocates them without an object) are the ones we take.
+     */
+    if (p->object != NULL)
+        return NULL;
+    return p;
+}
+
+static int
+nv_pi_wire(void *ctx, void *page)
 {
+    vm_page_wire((vm_page_t)page);
+    return 0;
 }
 
+/* The call os_unlock_user_pages() makes, so the RM's teardown balances it. */
+static void
+nv_pi_unwire(void *ctx, void *page)
+{
+    vm_page_unwire((vm_page_t)page, PQ_ACTIVE);
+}
+
+static unsigned long long
+nv_pi_phys(void *ctx, void *page)
+{
+    return VM_PAGE_TO_PHYS((vm_page_t)page);
+}
+
+static const struct gb10_pi_ops nv_pi_ops = {
+    .page_at = nv_pi_page_at,
+    .wire    = nv_pi_wire,
+    .unwire  = nv_pi_unwire,
+    .phys    = nv_pi_phys,
+};
+
+/*
+ * Wire `count` pages and hand back the array the RM's page-array descriptor
+ * wants.  On success the array and the wiring belong to the caller until it
+ * gives them to the RM (which then unwires and frees them) or back to
+ * nv_unimport_pages().  On failure nothing is wired and nothing is
+ * allocated.  Exported to nvidia-drm.ko through EXPORT_SYMS.
+ */
+NV_STATUS NV_API_CALL nv_import_pages(
+    void   **pages,
+    NvU64    count,
+    void   **array
+)
+{
+    vm_page_t *copy;
+    NvU64 i;
+
+    if (pages == NULL || array == NULL || count == 0 ||
+        count > (GB10_PI_MAX_BYTES >> PAGE_SHIFT))
+        return NV_ERR_INVALID_ARGUMENT;
+
+    *array = NULL;
+
+    if (os_alloc_mem((void **)&copy, count * sizeof(*copy)) != NV_OK)
+        return NV_ERR_NO_MEMORY;
+
+    for (i = 0; i < count; i++)
+        copy[i] = pages[i];
+
+    if (gb10_pi_wire((void **)copy, count, &nv_pi_ops, NULL) != GB10_PI_OK) {
+        os_free_mem(copy);
+        return NV_ERR_INSUFFICIENT_RESOURCES;
+    }
+
+    *array = copy;
+    return NV_OK;
+}
+
+/* Give back an array nv_import_pages() made and the RM did not take. */
+void NV_API_CALL nv_unimport_pages(
+    void    *array,
+    NvU64    count
+)
+{
+    if (array == NULL)
+        return;
+
+    gb10_pi_unwire((void **)array, count, &nv_pi_ops, NULL);
+    os_free_mem(array);
+}
+
+/*
+ * The SGT path.  The RM calls, in this order: nv_dma_import_sgt() (take the
+ * owner's reference), nv_register_sgt() (wire the pages, fill the physical
+ * address array), and at the end nv_unregister_sgt() (unwire) and
+ * nv_dma_release_sgt() (drop the reference); a failure after the
+ * registration unregisters and then releases, a failed registration only
+ * releases.  The old stub returned success from nv_register_sgt() without
+ * filling the array, so a descriptor built on it had no pages at all.
+ */
 NV_STATUS NV_API_CALL nv_register_sgt(
     nv_state_t *nv,
     NvU64      *phys_addr,
@@ -2128,6 +2261,25 @@
     NvBool      is_peer_mmio
 )
 {
+    struct gb10_pi_desc *desc = (struct gb10_pi_desc *)import_sgt;
+    int rc;
+
+    if (priv_data == NULL || phys_addr == NULL)
+        return NV_ERR_INVALID_ARGUMENT;
+
+    *priv_data = NULL;
+
+    if (is_peer_mmio)
+        return NV_ERR_NOT_SUPPORTED;
+
+    rc = gb10_pi_register(desc, page_count, (unsigned long long *)phys_addr,
+                          &nv_pi_ops, NULL);
+    if (rc == GB10_PI_WIRE_FAILED)
+        return NV_ERR_INSUFFICIENT_RESOURCES;
+    if (rc != GB10_PI_OK)
+        return NV_ERR_INVALID_ARGUMENT;
+
+    *priv_data = desc;
     return NV_OK;
 }
 
@@ -2138,6 +2290,15 @@
     void  *priv_data
 )
 {
+    struct gb10_pi_desc *desc = priv_data;
+
+    if (desc == NULL)
+        return;
+
+    gb10_pi_unregister(desc, &nv_pi_ops, NULL);
+
+    *import_sgt = (struct sg_table *)desc;
+    *import_priv = desc->ctx;
 }
 
 
@@ -2325,7 +2486,11 @@
     struct drm_gem_object *gem
 )
 {
-    return NV_ERR_NOT_SUPPORTED;
+    /* sgt is a struct gb10_pi_desc, see nv_register_sgt(). */
+    if (gb10_pi_import((struct gb10_pi_desc *)sgt) != GB10_PI_OK)
+        return NV_ERR_NOT_SUPPORTED;
+
+    return NV_OK;
 }
 
 NV_STATUS NV_API_CALL nv_dma_import_dma_buf
@@ -2360,6 +2525,8 @@
     struct drm_gem_object *gem
 )
 {
+    /* Last use of the descriptor: dropping the owner may free it. */
+    gb10_pi_release((struct gb10_pi_desc *)sgt);
 }
 
 void NV_API_CALL nv_dma_release_dma_buf

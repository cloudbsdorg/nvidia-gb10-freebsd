--- nvidia/nvidia_subr.c.orig
+++ nvidia/nvidia_subr.c
@@ -1575,6 +1575,24 @@
     return 0;
 }
 
+/*
+ * nv_alias_pages() - describe memory the RM did not get from nv_alloc_pages().
+ *
+ * GB10: the RM places every display (ISO) allocation in the firmware scanout
+ * carveout that GSP reports (NV2080_CTRL_CMD_FB_GET_CARVEOUT_REGION_INFO;
+ * on the DGX Spark 0x300000000 + 48 MiB = IORT RMR 0 = \_SB.PCIF.RP0.IGPU
+ * _CRS).  That range is RAM the firmware keeps out of the OS memory map, so
+ * it has no vm_page and is not in the direct map.  Build the same
+ * nvidia_alloc a contiguous allocation gets, but backed by a pmap_mapdev
+ * mapping instead of kmem: the kernel mapping, the OBJT_SG object used for
+ * user mmap and os_match_mmap_offset() then work unchanged.  The memory is
+ * not zeroed (it may hold the firmware console image) and is never handed
+ * back to the VM; nv_free_pages() only removes the mapping.
+ *
+ * Only contiguous carveout ranges that are not managed RAM are accepted.
+ */
+static unsigned int nv_alias_logged;
+
 NV_STATUS NV_API_CALL nv_alias_pages(
     nv_state_t *nv,
     NvU32       count,
@@ -1587,7 +1605,98 @@
     void      **priv_data
 )
 {
-    return NV_ERR_NOT_SUPPORTED;
+    struct nvidia_alloc *at;
+    vm_memattr_t attr;
+    vm_paddr_t pa;
+    uint64_t size;
+    void *va = NULL;
+
+    if (!carveout || !alloc_type_contiguous || count == 0)
+        return NV_ERR_NOT_SUPPORTED;
+
+    pa = (vm_paddr_t)pte_array[0];
+    size = (uint64_t)count * PAGE_SIZE;
+
+    if ((pa & PAGE_MASK) != 0 || size > 0x80000000ULL)
+        return NV_ERR_INVALID_ARGUMENT;
+
+    /* Refuse anything the VM manages: that is not a carveout. */
+    if (vm_phys_paddr_to_vm_page(pa) != NULL ||
+        vm_phys_paddr_to_vm_page(pa + size - PAGE_SIZE) != NULL) {
+        printf("nvidia: nv_alias_pages: 0x%jx+0x%jx is managed RAM, refused\n",
+            (uintmax_t)pa, (uintmax_t)size);
+        return NV_ERR_INVALID_ARGUMENT;
+    }
+
+    attr = _convert_caching_to_attr(cache_type);
+
+    at = malloc(sizeof(nvidia_alloc_t), M_NVIDIA, (M_WAITOK | M_ZERO));
+    at->pte_array = malloc(sizeof(nvidia_pte_t), M_NVIDIA,
+            (M_WAITOK | M_ZERO));
+
+    at->num_pages = count;
+    at->size = (uint32_t)size;
+    at->alloc_type_contiguous = 1;
+    at->attr = attr;
+    at->flags.aliased = NV_TRUE;
+
+    va = pmap_mapdev_attr(pa, size, attr);
+    if (va == NULL)
+        goto failed;
+
+    at->pte_array[0].virtual_address = (vm_offset_t)va;
+    at->pte_array[0].physical_address = (NvU64)pa;
+
+    at->sg_list = sglist_alloc(1, M_WAITOK);
+    if (!at->sg_list)
+        goto failed;
+    sglist_append_phys(at->sg_list, pa, size);
+
+    at->object = vm_pager_allocate(OBJT_SG, at->sg_list, size,
+            (VM_PROT_READ | VM_PROT_WRITE), 0, NULL);
+    if (!at->object)
+        goto failed;
+
+    VM_OBJECT_WLOCK(at->object);
+    vm_object_set_memattr(at->object, attr);
+    VM_OBJECT_WUNLOCK(at->object);
+
+    if (nv_alias_logged < 16) {
+        nv_alias_logged++;
+        printf("nvidia: nv_alias_pages: carveout 0x%jx+0x%jx cache %u attr %d va %p\n",
+            (uintmax_t)pa, (uintmax_t)size, cache_type, (int)attr, va);
+    }
+
+    *priv_data = at;
+
+    return NV_OK;
+
+failed:
+    if (at->sg_list)
+        NV_SGLIST_FREE(at->sg_list);
+    if (va != NULL)
+        pmap_unmapdev(va, size);
+    free(at->pte_array, M_NVIDIA);
+    free(at, M_NVIDIA);
+
+    return NV_ERR_NO_MEMORY;
+}
+
+static NvS32 nv_free_aliased_pages(
+    void *private
+)
+{
+    struct nvidia_alloc *at = private;
+
+    NV_VM_OBJECT_DEALLOCATE(at->object);
+    NV_SGLIST_FREE(at->sg_list);
+
+    pmap_unmapdev((void *)at->pte_array[0].virtual_address, at->size);
+
+    free(at->pte_array, M_NVIDIA);
+    free(at, M_NVIDIA);
+
+    return 0;
 }
 
 NV_STATUS NV_API_CALL nv_alloc_pages(
@@ -1647,6 +1756,13 @@
 {
     NV_STATUS status = NV_OK;
 
+    /* nv_alias_pages() memory: unmap only, it was never ours to free. */
+    if (((struct nvidia_alloc *)private)->flags.aliased) {
+        if (nv_free_aliased_pages(private))
+            status = NV_ERR_GENERIC;
+        return status;
+    }
+
     if (!alloc_type_contiguous) {
         if (nv_free_system_pages(private))
             status = NV_ERR_GENERIC;

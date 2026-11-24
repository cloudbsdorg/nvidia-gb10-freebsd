--- nvidia/nvidia_subr.c.orig	2026-11-24 03:38:11.739862000 +0000
+++ nvidia/nvidia_subr.c	2026-11-24 03:38:42.087573000 +0000
@@ -1337,8 +1337,30 @@
     &nv_gb10_dma_bits, 0,
     "GB10 diagnostic: cap RM system memory below 2^bits (0 = off)");
 
+/*
+ * GB10: the RM passes the page size it will map an allocation with on the
+ * GPU (memdescGetAdjustedPageSize(), e.g. 64 KiB for the Vulkan driver's
+ * buffers on a GPU without video memory).  It then requires every
+ * page_size unit to be physically contiguous and aligned to page_size:
+ * dmaAllocMapping computes the mapping length from the offset of the first
+ * page within a page_size unit, so unaligned memory overruns the VA block
+ * ("vaHi <= pMemBlock->end", gpu_vaspace.c).  NVIDIA's Linux layer
+ * allocates in units of that order; this layer ignored page_size.
+ *
+ * Returns the unit to allocate in: page_size when it is a power of two
+ * above PAGE_SIZE, else PAGE_SIZE.
+ */
+static vm_size_t nv_alloc_unit(NvU64 page_size)
+{
+    if (page_size > PAGE_SIZE && page_size <= ((NvU64)1 << 30) &&
+        powerof2(page_size))
+        return (vm_size_t)page_size;
+    return PAGE_SIZE;
+}
+
 static NvS32 nv_alloc_contig_pages(
     NvU32       count,
+    NvU64       page_size,
     NvU32       cache_type,
     vm_paddr_t  high_addr,
     NvBool      zero,
@@ -1352,7 +1374,12 @@
     NvU32 size = (count * PAGE_SIZE);
     int flags = (zero ? M_ZERO : 0);
     int status;
+    vm_size_t align = nv_alloc_unit(page_size);
 
+    /* Like a Linux high-order allocation: never stricter than the size. */
+    while (align > PAGE_SIZE && align > size)
+        align >>= 1;
+
     attr = _convert_caching_to_attr(cache_type);
 
     at = malloc(sizeof(nvidia_alloc_t), M_NVIDIA, (M_WAITOK | M_ZERO));
@@ -1372,7 +1399,12 @@
     }
 
     address = NV_KMEM_ALLOC_CONTIG(size, flags, 0,
-            high_addr, PAGE_SIZE, 0, attr);
+            high_addr, align, 0, attr);
+    if (!address && align > PAGE_SIZE) {
+        /* Keep the old behaviour rather than fail a large request. */
+        address = NV_KMEM_ALLOC_CONTIG(size, flags, 0,
+                high_addr, PAGE_SIZE, 0, attr);
+    }
     if (!address) {
         status = ENOMEM;
         goto failed;
@@ -1452,6 +1484,7 @@
 
 static NvS32 nv_alloc_system_pages(
     NvU32        count,
+    NvU64        page_size,
     NvU32        cache_type,
     vm_paddr_t   high_addr,
     NvBool       zero,
@@ -1466,6 +1499,9 @@
     uint32_t size = (count * PAGE_SIZE);
     int flags = (zero ? M_ZERO : 0);
     int status;
+    vm_size_t unit = nv_alloc_unit(page_size);
+    uint32_t ppu = unit / PAGE_SIZE;    /* pages per unit */
+    uint32_t j;
 
     attr = _convert_caching_to_attr(cache_type);
 
@@ -1475,6 +1511,7 @@
 
     at->num_pages = count;
     at->size = size;
+    at->unit_pages = ppu;
     at->alloc_type_contiguous = 0;
     at->attr = attr;
 
@@ -1485,17 +1522,25 @@
         return ENOMEM;
     }
 
-    for (i = 0; i < count; i++) {
-        address = NV_KMEM_ALLOC_CONTIG(PAGE_SIZE, flags, 0,
-                high_addr, PAGE_SIZE, 0, attr);
+    /*
+     * One aligned, contiguous unit per page_size; a short last unit is
+     * still allocated whole (as Linux does) and only its first pages are
+     * described.  The first page of each unit owns the unit.
+     */
+    for (i = 0; i < count; i += ppu) {
+        address = NV_KMEM_ALLOC_CONTIG(unit, flags, 0,
+                high_addr, unit, 0, attr);
         if (!address) {
             status = ENOMEM;
             goto failed;
         }
-        malloc_type_allocated(M_NVIDIA, PAGE_SIZE);
+        malloc_type_allocated(M_NVIDIA, unit);
 
-        at->pte_array[i].virtual_address = address;
-        at->pte_array[i].physical_address = (NvU64)vtophys(address);
+        for (j = 0; j < ppu && i + j < count; j++) {
+            at->pte_array[i + j].virtual_address = address + ptoa(j);
+            at->pte_array[i + j].physical_address =
+                (NvU64)vtophys(address + ptoa(j));
+        }
     }
 
     if (attr != VM_MEMATTR_WRITE_BACK)
@@ -1536,11 +1581,11 @@
     if (attr != VM_MEMATTR_WRITE_BACK)
         flush_cpu_cache();
 
-    for (i = 0; i < count; i++) {
+    for (i = 0; i < count; i += ppu) {
         if (at->pte_array[i].virtual_address == 0)
             break;
-        NV_KMEM_FREE(at->pte_array[i].virtual_address, PAGE_SIZE);
-        malloc_type_freed(M_NVIDIA, PAGE_SIZE);
+        NV_KMEM_FREE(at->pte_array[i].virtual_address, unit);
+        malloc_type_freed(M_NVIDIA, unit);
     }
 
     free(at->pte_array, M_NVIDIA);
@@ -1555,6 +1600,7 @@
 {
     struct nvidia_alloc *at = private;
     uint32_t i, count;
+    uint32_t ppu = (at->unit_pages != 0) ? at->unit_pages : 1;
 
     count = at->size / PAGE_SIZE;
 
@@ -1564,9 +1610,9 @@
     if (at->attr != VM_MEMATTR_WRITE_BACK)
         flush_cpu_cache();
 
-    for (i = 0; i < count; i++) {
-        NV_KMEM_FREE(at->pte_array[i].virtual_address, PAGE_SIZE);
-        malloc_type_freed(M_NVIDIA, PAGE_SIZE);
+    for (i = 0; i < count; i += ppu) {
+        NV_KMEM_FREE(at->pte_array[i].virtual_address, ptoa(ppu));
+        malloc_type_freed(M_NVIDIA, ptoa(ppu));
     }
 
     free(at->pte_array, M_NVIDIA);
@@ -1821,12 +1867,12 @@
         high_addr = ((vm_paddr_t)1 << nv_gb10_dma_bits) - 1;
 
     if (!alloc_type_contiguous) {
-        if (nv_alloc_system_pages(count, cache_type, high_addr, zero,
+        if (nv_alloc_system_pages(count, page_size, cache_type, high_addr, zero,
                     pte_array, private)) {
             status = NV_ERR_NO_MEMORY;
         }
     } else {
-        if (nv_alloc_contig_pages(count, cache_type, high_addr, zero,
+        if (nv_alloc_contig_pages(count, page_size, cache_type, high_addr, zero,
                     pte_array, private)) {
             status = NV_ERR_NO_MEMORY;
         }

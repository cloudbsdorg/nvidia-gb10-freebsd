--- nvidia/nvidia_subr.c.orig	2026-11-18 03:47:39.101201000 +0000
+++ nvidia/nvidia_subr.c	2026-11-18 03:49:20.209566000 +0000
@@ -22,9 +22,27 @@
 #include <sys/fbio.h>
 #include <sys/linker.h>
 #include <sys/firmware.h>
+#if defined(__amd64__) || defined(__i386__)
+/*
+ * syscons is x86-only: arm64 kernels have vt(4) and no syscons, so this
+ * header and the console fallback in nv_get_screen_info() below are
+ * compiled out there.  arm64 boots by UEFI and takes the EFI framebuffer
+ * path.
+ */
 #include <dev/syscons/syscons.h>
+#endif
 #include <machine/metadata.h>
+#if defined(__aarch64__)
+#include <machine/atomic.h>	/* dsb(sy) */
+#include <vm/vm_phys.h>		/* vm_phys_paddr_to_vm_page() */
+#include "gb10_memattr.h"	/* gb10_bar_memattr(), gb10_range_class(),
+				 * gb10_range_action() for device mmaps */
 
+/* arm64 BAR memory-attribute policy, defined in nvidia_os.c */
+extern int os_arm64_altra_device_wc;
+extern void os_arm64_bar_wc_init(void);
+#endif
+
 uma_zone_t nvidia_stack_t_zone;
 static nvidia_stack_t *__nvidia_init_sp = NULL;
 
@@ -736,6 +754,14 @@
             sc->nv_state = (void *)&nvidia_ctl_state;
 
             nvidia_sysctl_init();
+#if defined(__aarch64__)
+            /*
+             * arm64: decide the BAR memory-attribute policy (ACPI MCFG +
+             * loader tunable) once, now that the hw.nvidia sysctl node
+             * exists.  Defined in nvidia_os.c.
+             */
+            os_arm64_bar_wc_init();
+#endif
             nvidia_linux_init();
 
             mtx_init(&snapshot_timer_mutex, "nvidia_profiler", NULL, MTX_DEF);
@@ -1105,6 +1131,31 @@
     smp_rendezvous(NULL, wbinvd_action_func, NULL, NULL);
     wbinvd_action_func(NULL);
 }
+#elif defined(__aarch64__)
+/*
+ * arm64 has no pmap_invalidate_cache(), and there is no safe
+ * whole-cache flush that could replace it.  None is needed here: the
+ * arm64 pmap performs the data-cache maintenance itself when one of
+ * these pages gets its non-write-back attribute.  The attribute is
+ * applied to the pages through pmap_page_set_memattr()
+ * (sys/arm64/arm64/pmap.c:8619), which updates the page's direct-map
+ * alias via pmap_change_attr() (pmap.c:8657) ->
+ * pmap_change_props_locked() (pmap.c:8708), and that cleans and
+ * invalidates the dcache over the remapped range with
+ * cpu_dcache_wbinv_range() whenever the new attribute is
+ * VM_MEMATTR_UNCACHEABLE (pmap.c:8933-8934) -- the attribute
+ * _convert_caching_to_attr() below now returns for every non-cached
+ * system page.  (pmap_kenter() (pmap.c:2621) performs no cache
+ * maintenance, so the kmem mapping cannot be relied on for it.)  All
+ * that is left for the driver is to complete and order its prior
+ * stores before any later non-cacheable access to the same physical
+ * pages; dsb(sy), the full-system completion barrier from
+ * <machine/atomic.h>, does that.
+ */
+static void flush_cpu_cache(void)
+{
+    dsb(sy);
+}
 #else
 static void flush_cpu_cache(void)
 {
@@ -1118,6 +1169,7 @@
     NvU32 caching
 )
 {
+#if defined(__amd64__) || defined(__i386__)
     switch (caching) {
         case NV_MEMORY_UNCACHED:
             return VM_MEMATTR_UNCACHEABLE;
@@ -1128,7 +1180,29 @@
             return VM_MEMATTR_WEAK_UNCACHEABLE;
         case NV_MEMORY_WRITECOMBINED:
             return VM_MEMATTR_WRITE_COMBINING;
+    }
+#elif defined(__aarch64__)
+    /*
+     * arm64 has no VM_MEMATTR_WEAK_UNCACHEABLE, and its
+     * VM_MEMATTR_WRITE_COMBINING is an alias for
+     * VM_MEMATTR_WRITE_THROUGH (sys/arm64/include/vm.h:46), which is
+     * cacheable and therefore wrong for uncached or write-combined
+     * requests.  These are system RAM pages, not device BARs, so all
+     * three non-cached types map as Normal non-cacheable
+     * (VM_MEMATTR_UNCACHEABLE); that is also the one attribute for
+     * which the pmap cleans and invalidates the dcache itself (see
+     * flush_cpu_cache() above).
+     */
+    switch (caching) {
+        case NV_MEMORY_UNCACHED:
+        case NV_MEMORY_UNCACHED_WEAK:
+        case NV_MEMORY_WRITECOMBINED:
+            return VM_MEMATTR_UNCACHEABLE;
+        case NV_MEMORY_DEFAULT:
+        case NV_MEMORY_CACHED:
+            return VM_MEMATTR_WRITE_BACK;
     }
+#endif
 
     return VM_MEMATTR_UNCACHEABLE;
 }
@@ -1530,7 +1604,59 @@
     sx_xunlock(&nvffp->fops_sx);
 
     return status;
+}
+
+#if defined(__aarch64__)
+/*
+ * gb10_memarea_kind - classify the physical ranges of a device mmap for
+ * the arm64 attribute policy of nvidia_mmap_dev_single() below: walk
+ * every PAGE_SIZE step of every range of the area, counting the steps
+ * walked and the ones whose vm_phys_paddr_to_vm_page() (sys/vm/vm_phys.h:
+ * non-NULL exactly for a page the VM system manages as system RAM, NULL
+ * for a device BAR / MMIO hole) is non-NULL - across all ranges - and
+ * hand the two counts to gb10_range_class() (gb10_memattr.h): no managed
+ * RAM page -> GB10_RANGE_BAR, every page managed RAM -> GB10_RANGE_RAM,
+ * both (within one range or across ranges) -> GB10_RANGE_MIXED.  The walk
+ * stops at the first page that makes the area MIXED - the verdict
+ * cannot change back, and one vm_phys_paddr_to_vm_page() lookup per
+ * page (a binary search over the physical-memory segments) is the cost
+ * of the walk, so a large mmap stops paying it once the answer is
+ * known.  An empty area walks no step and classifies as BAR, which
+ * keeps the attribute such an mmap gets today.  gb10_range_action()
+ * (gb10_memattr.h) turns the kind into the action the caller takes.
+ *
+ * Time:  O(area bytes / PAGE_SIZE) page lookups in the worst case (an
+ *        all-RAM or all-BAR area); a mixed area stops at its first
+ *        mixed page.
+ * Space: O(1).
+ */
+static enum gb10_range
+gb10_memarea_kind(const MemoryArea *area)
+{
+    unsigned long ram_pages = 0;
+    unsigned long pages = 0;
+    NvU64 idx;
+    vm_paddr_t pa;
+
+    for (idx = 0; idx < area->numRanges; idx++) {
+        NvU64 start = area->pRanges[idx].start;
+        NvU64 size = area->pRanges[idx].size;
+
+        for (pa = start & ~(vm_paddr_t)PAGE_MASK; pa < start + size;
+             pa += PAGE_SIZE) {
+            pages++;
+            if (vm_phys_paddr_to_vm_page(pa) != NULL)
+                ram_pages++;
+            /* both kinds seen: the area is mixed, and no later page
+             * can undo that - stop here (see the cost note above) */
+            if (ram_pages > 0 && ram_pages < pages)
+                return (GB10_RANGE_MIXED);
+        }
+    }
+
+    return (gb10_range_class(ram_pages, pages));
 }
+#endif /* __aarch64__ */
 
 int nvidia_mmap_dev_single(
     nv_freebsd_file_private_t *nvffp,
@@ -1583,10 +1709,86 @@
     {
         goto free_sglist;
     }
+
+#if defined(__aarch64__)
+    /*
+     * The mmap usually covers PCIe BAR pages (device registers or a
+     * framebuffer), but it can also cover managed system RAM, and one
+     * attribute must never cross that line: a non-write-back attribute
+     * on managed RAM puts a mismatched alias beside the pages'
+     * write-back direct map, with no cache maintenance (nothing on
+     * this path rewrites the direct map itself) - the Track #1908
+     * hazard.  Classify the area first with
+     * gb10_memarea_kind() above and let gb10_range_action()
+     * (gb10_memattr.h) pick the policy:
+     *
+     *   system RAM  _convert_caching_to_attr(), this file's existing
+     *               system-memory policy (see flush_cpu_cache() above):
+     *               never gb10_bar_memattr() on managed pages.
+     *   BAR         gb10_bar_memattr() (see os_arm64_bar_wc_init() in
+     *               nvidia_os.c): Device-nGnRE for cached, uncached
+     *               and default (a BAR is never cacheable on arm64),
+     *               Normal non-cacheable - arm64's write-combining
+     *               attribute - for write-combined except on Altra,
+     *               and EINVAL for a caching
+     *               class the policy does not know.  The Normal
+     *               non-cacheable attribute _convert_caching_to_attr()
+     *               would return for uncached and write-combined BAR
+     *               requests allows speculative reads and merged writes
+     *               to registers, and on Ampere Altra it is the Track
+     *               #1908 hazard, which is why BARs get their own table.
+     *   mixed       refuse with EINVAL: no single attribute is correct
+     *               for both halves of the area.
+     */
+    {
+        vm_memattr_t attr;
+
+        switch (gb10_range_action(gb10_memarea_kind(&mmap_context->memArea))) {
+            case GB10_MAP_SYSTEM_POLICY:
+                attr = _convert_caching_to_attr(mmap_context->caching);
+                break;
+            case GB10_MAP_BAR_POLICY:
+                switch (gb10_bar_memattr(mmap_context->caching,
+                                         os_arm64_altra_device_wc)) {
+                    case GB10_ATTR_WRITE_BACK:
+                        attr = VM_MEMATTR_WRITE_BACK;
+                        break;
+                    case GB10_ATTR_NORMAL_NC:
+                        attr = VM_MEMATTR_UNCACHEABLE;
+                        break;
+                    case GB10_ATTR_DEVICE:
+                        attr = VM_MEMATTR_DEVICE;
+                        break;
+                    default: /* GB10_ATTR_INVALID */
+                        nv_printf(NV_DBG_ERRORS,
+                            "NVRM: VM: unsupported caching 0x%x for a device mmap\n",
+                            mmap_context->caching);
+                        vm_object_deallocate(*object);
+                        *object = NULL;
+                        status = EINVAL;
+                        goto free_sglist;
+                }
+                break;
+            default: /* GB10_MAP_REFUSE */
+                nv_printf(NV_DBG_ERRORS,
+                    "NVRM: VM: mmap of %llu ranges mixes system RAM and "
+                    "device memory; refusing to map\n",
+                    (unsigned long long)mmap_context->memArea.numRanges);
+                vm_object_deallocate(*object);
+                *object = NULL;
+                status = EINVAL;
+                goto free_sglist;
+        }
 
+        VM_OBJECT_WLOCK(*object);
+        vm_object_set_memattr(*object, attr);
+        VM_OBJECT_WUNLOCK(*object);
+    }
+#else
     VM_OBJECT_WLOCK(*object);
     vm_object_set_memattr(*object, _convert_caching_to_attr(mmap_context->caching));
     VM_OBJECT_WUNLOCK(*object);
+#endif
 
     status = NV_OK;
 
@@ -2414,6 +2615,12 @@
             return;
         }
     }
+#if defined(__amd64__) || defined(__i386__)
+    /*
+     * syscons console fallback, x86-only (see the include guard at the top
+     * of this file).  When it is compiled out on arm64, control goes from
+     * the EFI framebuffer path above straight to the "not found" exit.
+     */
     {
         const sc_softc_t *sc = sc_get_softc(0, SC_KERNEL_CONSOLE);
 
@@ -2440,6 +2647,7 @@
             }
         }
     }
+#endif
 
     *pPhysicalAddress = 0;
     *pFbWidth = *pFbHeight = *pFbDepth = *pFbPitch = *pFbSize = 0;

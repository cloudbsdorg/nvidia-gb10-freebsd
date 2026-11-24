--- nvidia/nvidia_os.c.orig
+++ nvidia/nvidia_os.c
@@ -12,15 +12,163 @@
 #include "nv.h"
 #include "nv-freebsd.h"
 #include "nv-retpoline.h"
+#include "gb10_pageimport.h"	/* gb10_pi_os_dirty() */
 
 #include <sys/linker.h>
 #include <sys/timex.h>
 #include <sys/stack.h>
+#if defined(__aarch64__)
+#include <machine/armreg.h>	/* READ_SPECIALREG(cntfrq_el0) */
+#include <machine/atomic.h>	/* dsb(st) */
+#include <vm/vm_phys.h>		/* vm_phys_paddr_to_vm_page() */
+#include <contrib/dev/acpica/include/acpi.h>	/* AcpiGetTable(ACPI_SIG_MCFG) */
+#include "gb10_memattr.h"	/* gb10_bar_memattr(), gb10_ram_memattr(),
+				 * gb10_range_class(), gb10_range_action(),
+				 * gb10_mcfg_is_altra() */
+#endif
 
 MALLOC_DEFINE(M_NVIDIA, "nvidia", "NVIDIA memory allocations");
 TASKQUEUE_DEFINE_THREAD(nvidia);
 NvBool os_is_unload_flush_ongoing = NV_FALSE;
 
+#if defined(__aarch64__)
+/*
+ * arm64 PCIe BAR memory-attribute policy state, decided once at module
+ * load by os_arm64_bar_wc_init() below and used by os_map_kernel_space()
+ * in this file and by nvidia_mmap_dev_single() in nvidia_subr.c, through
+ * gb10_bar_memattr() (gb10_memattr.h).
+ *
+ * os_arm64_altra_device_wc is the Ampere Altra decision: when it is 1,
+ * write-combining requests for BAR pages are mapped Device-nGnRE
+ * (VM_MEMATTR_DEVICE) instead of Normal non-cacheable
+ * (VM_MEMATTR_UNCACHEABLE, arm64's write-combining attribute), because
+ * Normal memory accesses to PCIe BARs are not safe on that platform
+ * (Track #1908).  A system that is not an Altra keeps Normal-NC
+ * write-combining and is otherwise undisturbed by this code.
+ */
+int os_arm64_altra_device_wc;
+
+extern struct sysctl_ctx_list sysctl_ctx;	/* nvidia_sysctl.c */
+extern struct sysctl_oid *oid_nvidia;		/* the hw.nvidia node */
+
+void os_arm64_bar_wc_init(void);
+
+/*
+ * os_arm64_bar_wc_init - one-time module-load setup of the arm64 BAR
+ * memory-attribute policy: read the loader tunable
+ * hw.nvidia.altra_device_wc (-1 auto, the default; 0 force off; 1 force
+ * on), identify the system by the OEM ID / OEM table ID of the ACPI MCFG
+ * header with gb10_mcfg_is_altra(), register the read-only
+ * hw.nvidia.altra_device_wc_active sysctl under the hw.nvidia node and
+ * print the decision.
+ *
+ * The MCFG header is read through ACPICA's AcpiGetTable(), which every
+ * GENERIC arm64 kernel exports, so nvidia.ko keeps loading on a stock
+ * FreeBSD arm64 kernel.  No MCFG table, or an AcpiGetTable failure, means
+ * "not an Altra".  Called from MOD_LOAD in nvidia_subr.c right after
+ * nvidia_sysctl_init() created the hw.nvidia node; the sysctl is added to
+ * that file's sysctl_ctx, so nvidia_sysctl_exit() removes it at unload.
+ *
+ * Time:  O(1) - one ACPI table lookup and a fixed number of compares.
+ * Space: O(1).
+ */
+void os_arm64_bar_wc_init(void)
+{
+    ACPI_TABLE_HEADER *hdr = NULL;
+    char oemid[7];	/* MCFG OEM ID (6 bytes) plus a NUL for printf */
+    char oemtableid[9];	/* MCFG OEM table ID (8 bytes) plus a NUL */
+    int tunable = -1;
+    int altra;
+
+    bzero(oemid, sizeof(oemid));
+    bzero(oemtableid, sizeof(oemtableid));
+
+    TUNABLE_INT_FETCH("hw.nvidia.altra_device_wc", &tunable);
+
+    if (ACPI_SUCCESS(AcpiGetTable(ACPI_SIG_MCFG, 1, &hdr)) && hdr != NULL) {
+        memcpy(oemid, hdr->OemId, sizeof(hdr->OemId));
+        memcpy(oemtableid, hdr->OemTableId, sizeof(hdr->OemTableId));
+        AcpiPutTable(hdr);
+    }
+
+    /* no MCFG (or failure) left the buffers zero: not an Altra */
+    altra = gb10_mcfg_is_altra(oemid, oemtableid);
+    if (tunable >= 0)
+        altra = (tunable != 0);
+    os_arm64_altra_device_wc = altra;
+
+    SYSCTL_ADD_INT(&sysctl_ctx, SYSCTL_CHILDREN(oid_nvidia), OID_AUTO,
+        "altra_device_wc_active", CTLFLAG_RD, &os_arm64_altra_device_wc, 0,
+        "BAR write-combining is mapped Device-nGnRE for the Ampere Altra quirk (1) or Normal-NC (0)");
+
+    printf("NVRM: arm64 BAR write-combining: %s (MCFG %s/%s, tunable %d)\n",
+        altra ? "Device-nGnRE" : "Normal-NC",
+        oemid[0] != '\0' ? oemid : "none",
+        oemtableid[0] != '\0' ? oemtableid : "none",
+        tunable);
+}
+
+/*
+ * gb10_range_kind_of - classify a physical range for the arm64 mapping
+ * policy of os_map_kernel_space() below: walk every PAGE_SIZE step of
+ * [start, start+size), counting the steps walked and the ones whose
+ * vm_phys_paddr_to_vm_page() (sys/vm/vm_phys.h: non-NULL exactly for a
+ * page the VM system manages as system RAM, NULL for a device BAR / MMIO
+ * hole) is non-NULL, and hand the two counts to gb10_range_class()
+ * (gb10_memattr.h): no managed RAM page -> GB10_RANGE_BAR, every page
+ * managed RAM -> GB10_RANGE_RAM, both -> GB10_RANGE_MIXED.  An empty
+ * (zero-size) range walks no step and classifies as BAR, which keeps the
+ * attribute such a request gets today.  gb10_range_action()
+ * (gb10_memattr.h) turns the kind into the action the caller takes.
+ *
+ * Time:  O(size / PAGE_SIZE) page lookups.
+ * Space: O(1).
+ */
+static enum gb10_range
+gb10_range_kind_of(vm_paddr_t start, vm_size_t size)
+{
+    unsigned long ram_pages = 0;
+    unsigned long pages = 0;
+    vm_paddr_t pa;
+
+    for (pa = start & ~(vm_paddr_t)PAGE_MASK; pa < start + size;
+         pa += PAGE_SIZE) {
+        pages++;
+        if (vm_phys_paddr_to_vm_page(pa) != NULL)
+            ram_pages++;
+    }
+
+    return (gb10_range_class(ram_pages, pages));
+}
+
+/*
+ * arm64 has no port I/O address space: the os_io_* functions below return
+ * all-ones for reads, as a failed PCI config-space read does, and drop
+ * writes.  Say so once per direction the first time either happens; the
+ * calls come from the closed core and must not flood the console.
+ */
+static int os_io_read_unsupported_logged;
+static int os_io_write_unsupported_logged;
+
+static void os_io_read_unsupported(void)
+{
+    if (!os_io_read_unsupported_logged) {
+        os_io_read_unsupported_logged = 1;
+        nv_printf(NV_DBG_ERRORS,
+            "NVRM: port I/O is not supported on arm64; read returning all-ones\n");
+    }
+}
+
+static void os_io_write_unsupported(void)
+{
+    if (!os_io_write_unsupported_logged) {
+        os_io_write_unsupported_logged = 1;
+        nv_printf(NV_DBG_ERRORS,
+            "NVRM: port I/O is not supported on arm64; write dropped\n");
+    }
+}
+#endif /* __aarch64__ */
+
 NvU64 os_page_size     = PAGE_SIZE;
 NvU64 os_max_page_size = PAGE_SIZE;
 NvU64 os_page_mask     = ~PAGE_MASK;
@@ -119,7 +267,21 @@
 NvU64 NV_API_CALL os_get_cpu_frequency(void)
 {
     /* round up by 4999 before division by 1000000 in osGetCpuFrequency() */
+#if defined(__amd64__) || defined(__i386__)
     return (tsc_freq + 4999);
+#elif defined(__aarch64__)
+    /*
+     * arm64: cntfrq_el0 is the generic timer's counter frequency, not the
+     * core clock.  The open core only stores the value in
+     * pSys->cpuInfo.clock (src/kernel/platform/cpu.c) and reports it
+     * through NV0000_CTRL_SYSTEM_GET_CPU_INFO
+     * (src/kernel/rmapi/client_resource.c:1038); nothing in the core
+     * times with it.
+     */
+    return (READ_SPECIALREG(cntfrq_el0) + 4999);
+#else
+#error "nvidia_os.c: unsupported architecture"
+#endif
 }
 
 NvU32 NV_API_CALL os_get_current_process(void)
@@ -205,8 +367,16 @@
     NvU32 address
 )
 {
+#if defined(__amd64__) || defined(__i386__)
     /* XXX Fix me? (bus_space access) */
     return inb(address);
+#elif defined(__aarch64__)
+    /* arm64 has no port I/O; return all-ones, as a failed PCI read does. */
+    os_io_read_unsupported();
+    return 0xff;
+#else
+#error "nvidia_os.c: unsupported architecture"
+#endif
 }
 
 void NV_API_CALL os_io_write_byte(
@@ -214,16 +384,31 @@
     NvU8  value
 )
 {
+#if defined(__amd64__) || defined(__i386__)
     /* XXX Fix me? (bus_space access) */
     outb(address, value);
+#elif defined(__aarch64__)
+    /* arm64 has no port I/O; the write is dropped. */
+    os_io_write_unsupported();
+#else
+#error "nvidia_os.c: unsupported architecture"
+#endif
 }
 
 NvU16 NV_API_CALL os_io_read_word(
     NvU32 address
 )
 {
+#if defined(__amd64__) || defined(__i386__)
     /* XXX Fix me? (bus_space access) */
     return inw(address);
+#elif defined(__aarch64__)
+    /* arm64 has no port I/O; return all-ones, as a failed PCI read does. */
+    os_io_read_unsupported();
+    return 0xffff;
+#else
+#error "nvidia_os.c: unsupported architecture"
+#endif
 }
 
 void NV_API_CALL os_io_write_word(
@@ -231,16 +416,31 @@
     NvU16 value
 )
 {
+#if defined(__amd64__) || defined(__i386__)
     /* XXX Fix me? (bus_space access) */
     return outw(address, value);
+#elif defined(__aarch64__)
+    /* arm64 has no port I/O; the write is dropped. */
+    os_io_write_unsupported();
+#else
+#error "nvidia_os.c: unsupported architecture"
+#endif
 }
 
 NvU32 NV_API_CALL os_io_read_dword(
     NvU32 address
 )
 {
+#if defined(__amd64__) || defined(__i386__)
     /* XXX Fix me? (bus_space access) */
     return inl(address);
+#elif defined(__aarch64__)
+    /* arm64 has no port I/O; return all-ones, as a failed PCI read does. */
+    os_io_read_unsupported();
+    return 0xffffffff;
+#else
+#error "nvidia_os.c: unsupported architecture"
+#endif
 }
 
 void NV_API_CALL os_io_write_dword(
@@ -248,8 +448,15 @@
     NvU32 value
 )
 {
+#if defined(__amd64__) || defined(__i386__)
     /* XXX Fix me? (bus_space access) */
     outl(address, value);
+#elif defined(__aarch64__)
+    /* arm64 has no port I/O; the write is dropped. */
+    os_io_write_unsupported();
+#else
+#error "nvidia_os.c: unsupported architecture"
+#endif
 }
 
 void* NV_API_CALL os_map_kernel_space(
@@ -260,6 +467,7 @@
 {
     int map_mode;
 
+#if defined(__amd64__) || defined(__i386__)
     switch (mode) {
         case NV_MEMORY_CACHED:
             map_mode = PAT_WRITE_BACK;
@@ -276,6 +484,72 @@
                       "NVRM: unknown mode in os_map_kernel_space()\n");
             return NULL;
     }
+#elif defined(__aarch64__)
+    /*
+     * The range is usually a PCIe BAR, but the closed core can also hand
+     * os_map_kernel_space() managed system RAM, and one attribute must
+     * never cross that line.  arm64's pmap_mapdev_attr() maps through
+     * pmap_kenter() (subr_devmap.c): no direct-map rewrite, no pv_memattr
+     * change, no cache maintenance (amd64's changes the DMAP attribute
+     * itself), so an uncached or Device attribute on RAM leaves a
+     * mismatched alias beside the write-back direct map - the Track #1908
+     * hazard.  So classify the range first with gb10_range_kind_of() above
+     * and let gb10_range_action() (gb10_memattr.h) pick the policy:
+     *
+     *   system RAM  gb10_ram_memattr(): cached and default stay
+     *               write-back, uncached and write-combined become
+     *               Normal non-cacheable, and a class x86 rejects here
+     *               fails the mapping as it does there.
+     *   BAR         gb10_bar_memattr() (see os_arm64_altra_device_wc
+     *               above): cached, uncached and the default class
+     *               become Device-nGnRE (a BAR is never cacheable on
+     *               arm64); write-combined becomes Normal
+     *               non-cacheable - arm64's write-combining attribute -
+     *               except on Altra, where Normal accesses to BARs are
+     *               unsafe (#1908) and it becomes Device-nGnRE too.
+     *               VM_MEMATTR_WRITE_COMBINING must never be used here:
+     *               on arm64 it aliases WRITE_THROUGH and is cacheable
+     *               (sys/arm64/include/vm.h:46).
+     *   mixed       refuse: no single attribute is correct for both
+     *               halves of the range.
+     */
+    {
+        enum gb10_memattr attr;
+
+        switch (gb10_range_action(gb10_range_kind_of(start, size))) {
+            case GB10_MAP_SYSTEM_POLICY:
+                attr = gb10_ram_memattr(mode);
+                break;
+            case GB10_MAP_BAR_POLICY:
+                attr = gb10_bar_memattr(mode, os_arm64_altra_device_wc);
+                break;
+            default: /* GB10_MAP_REFUSE */
+                nv_printf(NV_DBG_ERRORS,
+                    "NVRM: os_map_kernel_space: range 0x%llx+0x%llx mixes "
+                    "system RAM and device memory; refusing to map\n",
+                    (unsigned long long)start, (unsigned long long)size);
+                return NULL;
+        }
+
+        switch (attr) {
+            case GB10_ATTR_WRITE_BACK:
+                map_mode = VM_MEMATTR_WRITE_BACK;
+                break;
+            case GB10_ATTR_NORMAL_NC:
+                map_mode = VM_MEMATTR_UNCACHEABLE;
+                break;
+            case GB10_ATTR_DEVICE:
+                map_mode = VM_MEMATTR_DEVICE;
+                break;
+            default: /* GB10_ATTR_INVALID */
+                nv_printf(NV_DBG_ERRORS,
+                          "NVRM: unknown mode in os_map_kernel_space()\n");
+                return NULL;
+        }
+    }
+#else
+#error "nvidia_os.c: unsupported architecture"
+#endif
 
     return pmap_mapdev_attr(start, size, map_mode);
 }
@@ -584,7 +858,20 @@
 
 static void sfence_action_func(void *arg)
 {
+#if defined(__amd64__) || defined(__i386__)
     __asm__ __volatile__("sfence": : :"memory");
+#elif defined(__aarch64__)
+    /*
+     * arm64 has no sfence. dmb only orders memory accesses with respect
+     * to other observers, while dsb waits for completion of all prior
+     * stores; this runs before the GPU is told to read what was written,
+     * so the completion barrier dsb(st) (full system, store) is required
+     * (FreeBSD <machine/atomic.h>, arm64/include/atomic.h:51).
+     */
+    dsb(st);
+#else
+#error "nvidia_os.c: unsupported architecture"
+#endif
 }
 
 void NV_API_CALL os_flush_cpu_write_combine_buffer(void)
@@ -732,23 +1019,59 @@
-void* NV_API_CALL os_alloc_rwlock(void)
-{
-    struct sx *sx = NULL;
-
-    NV_STATUS rmStatus = os_alloc_mem((void *)&sx, sizeof(struct sx));
-    if (rmStatus != NV_OK)
-    {
-        nv_printf(NV_DBG_ERRORS, "NVRM: failed to allocate rwlock!\n");
-        return NULL;
-    }
-
-    sx_init(sx, "os.rwlock_sx");
-    return sx;
-}
-
-void NV_API_CALL os_free_rwlock(void *pRwLock)
-{
-    struct sx *sx = (struct sx *)pRwLock;
-    if (sx != NULL) {
-        sx_destroy(sx);
-        os_free_mem(sx);
-    }
-}
+/*
+ * WITNESS keys locks by *name*, not address.  Every rwlock the RM allocates
+ * was named "os.rwlock_sx", so the second sx_xlock() taken while the first is
+ * still held trips WITNESS's "acquiring duplicate lock of same type" check and
+ * fails SysCap object construction (NVRM 0x56, seen on the arm64 WITNESS boot
+ * path).  Give each rwlock a unique, stable name by embedding the name buffer
+ * next to the lock and suffixing a per-instance id, mirroring Linux's
+ * CONFIG_LOCKDEP per-instance lock_class_key.
+ */
+struct os_rwlock {
+    struct sx sx;
+    char     name[32];
+};
+
+static NvU32 nv_rwlock_next_id = 0;
+
+void* NV_API_CALL os_alloc_rwlock(void)
+{
+    struct os_rwlock *rwl = NULL;
+    NvU32 id;
+
+    NV_STATUS rmStatus = os_alloc_mem((void *)&rwl, sizeof(struct os_rwlock));
+    if (rmStatus != NV_OK)
+    {
+        nv_printf(NV_DBG_ERRORS, "NVRM: failed to allocate rwlock!\n");
+        return NULL;
+    }
+
+    id = atomic_fetchadd_32(&nv_rwlock_next_id, 1);
+    snprintf(rwl->name, sizeof(rwl->name), "os.rwlock_sx.%u", id);
+    /*
+     * The RM rwlock is a Linux rw_semaphore: readers may be re-acquired
+     * recursively and a writer may upgrade, which a plain (non-reentrant)
+     * sx forbids - the second acquisition of the *same* rwlock then trips
+     * WITNESS's recursion check ("acquiring duplicate lock of same type")
+     * and fails SysCap object construction (NVRM 0x56).  Mark it
+     * recursive, exactly as os_alloc_mutex() does the RM mutex with
+     * SX_RECURSE at the os.lock_sx site above.
+     */
+    sx_init_flags(&rwl->sx, rwl->name, SX_RECURSE);
+
+    return &rwl->sx;
+}
+
+void NV_API_CALL os_free_rwlock(void *pRwLock)
+{
+    struct os_rwlock *rwl;
+
+    if (pRwLock == NULL)
+        return;
+
+    /*
+     * The sx handle is the first member of struct os_rwlock, so the
+     * container-of is the identity cast.
+     */
+    rwl = (struct os_rwlock *)pRwLock;
+    sx_destroy(&rwl->sx);
+    os_free_mem(rwl);
+}
@@ -842,30 +1165,48 @@
 void NV_API_CALL os_enable_console_access(void)
 {
 }
 
+/*
+ * WITNESS keys spin locks by *name*, not address, and the RM re-acquires this
+ * lock within one critical section (tlsEntryGet -> gpumgrGetGpu at
+ * kgspInitRm_IMPL, the 0x56 backtrace).  The shared, non-recursive "os.lock_mtx"
+ * therefore tripped "acquiring duplicate lock of same type" and aborted RM
+ * bring-up.  Give each spin lock a unique name and mark it recursive, mirroring
+ * os_alloc_rwlock() above.
+ */
+struct os_spinlock {
+    struct mtx mtx;
+    char       name[32];
+};
+
+static NvU32 nv_spinlock_next_id = 0;
+
 NV_STATUS NV_API_CALL os_alloc_spinlock(void **lock)
 {
     NV_STATUS status;
-    struct mtx *mtx;
+    struct os_spinlock *osl;
+    NvU32 id;
 
-    status = os_alloc_mem((void **)&mtx, sizeof(struct mtx));
+    status = os_alloc_mem((void **)&osl, sizeof(struct os_spinlock));
     if (status != NV_OK)
         return status;
 
-    mtx_init(mtx, "os.lock_mtx", NULL, MTX_DEF);
+    id = atomic_fetchadd_32(&nv_spinlock_next_id, 1);
+    snprintf(osl->name, sizeof(osl->name), "os.lock_mtx.%u", id);
+    mtx_init(&osl->mtx, osl->name, NULL, MTX_DEF | MTX_RECURSE);
 
-    *lock = (void *)mtx;
+    *lock = (void *)&osl->mtx;
 
     return NV_OK;
 }
 
 void NV_API_CALL os_free_spinlock(void *lock)
 {
     struct mtx *mtx = lock;
 
     if (mtx != NULL) {
         mtx_assert(mtx, MA_OWNED);
         mtx_destroy(mtx);
-        os_free_mem(mtx);
+        os_free_mem((struct os_spinlock *)mtx);
     }
 }
@@ -1003,6 +1317,7 @@
 {
     NvBool write = FLD_TEST_DRF(_LOCK_USER_PAGES, _FLAGS, _WRITE, _YES, flags);
     vm_page_t *user_pages = page_array;
+    int dirty_spin = GB10_PI_DIRTY_SPIN_BUDGET;
     NvU32 i;
 
     for (i = 0; i < page_count; i++) {
@@ -1016,12 +1331,20 @@
 #endif
 
         if (write) {
-            vm_page_dirty(user_pages[i]);
+            /*
+             * The dirty step is ours (Track #2228): the page is busied
+             * (for a short spin) and dirtied only when it has an object and
+             * is all valid, which vm_page_dirty() asserts and which the
+             * pages of a buffer from another GPU driver never are; a page
+             * whose busy lock stays held is dirtied without it, as before,
+             * and counted.
+             */
+            gb10_pi_os_dirty(user_pages[i], &dirty_spin);
         }
         /*
          * In os_lock_user_pages either vm_fault_quick_hold_pages or us
          * on older FreeBSD versions will have wired the page. So here
          * we can unconditionally unwire the page since either way it is
          * wired.
          */

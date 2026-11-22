/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-3-Clause
 *
 * nv-uvm-interface.c - the UVM interface of NVIDIA's FreeBSD kernel glue
 * (uvm-spec r1, 02-rm-interface.md section 6).  nvidia.ko exports every
 * nvUvmInterface* function defined here (patches/patch-nvidia_Makefile,
 * EXPORT_SYMS) and nvidia-uvm.ko links against them.
 *
 * Three kinds of function live here:
 *
 *   1. wrappers: allocate an RM stack from the glue's UMA zone, call the
 *      RM gpu-ops function the core already contains, free the stack and
 *      return its status;
 *   2. glue-level entry points: the RM session's platform info, the
 *      callback table (install, remove with a wait for in-flight
 *      callbacks), GPU lookup by UUID with an open-reference on the
 *      device and RM's external-kernel-client count;
 *   3. hooks for the rest of the OS layer: the interrupt top half that
 *      nvidia_intr() calls BEFORE rm_isr(), the hook RM itself calls to
 *      schedule UVM's interrupt service (nv_schedule_uvm_isr), suspend and
 *      resume, and the P2P drain and resume notifications.
 *
 * Locking.  nv_uvm_mtx (MTX_DEF) protects the callback table and the
 * registered-GPU table and is held only briefly; it is taken from the
 * interrupt thread (nvidia_intr runs in an ithread, never in a filter), so
 * a default mutex is right.  A callback runs outside the mutex, counted in
 * nv_uvm_inflight, so deregistration can wait for the last one.
 * nv_uvm_reg_sx serialises RegisterGpu/UnregisterGpu, which call into RM
 * and sleep.
 *
 * GC6 (deep idle) blocking: NVIDIA's FreeBSD OS layer has no runtime power
 * management (nvidia_subr.c never initialises RM's dynamic power
 * management), so a GPU stays powered while a device reference is held;
 * the open reference RegisterGpu takes is that block.
 *
 * Register windows handed to UVM (fault GET/PUT, interrupt registers,
 * doorbells, channel RAM, the GPU time registers) are mapped by RM through
 * os_map_kernel_space(), which on arm64 applies the port's BAR policy
 * (src/gb10-memattr/gb10_memattr.h): Device-nGnRE, as 02 section 6 item 7
 * requires.  Nothing here maps registers itself.
 */

#include <sys/param.h>
#include <sys/systm.h>
#include <sys/kernel.h>
#include <sys/lock.h>
#include <sys/mutex.h>
#include <sys/sx.h>

#include "os-interface.h"
#include "nv.h"
#include "nv-freebsd.h"
#include "nv-uvm-interface.h"

/* a GPU UVM has registered: the device and the UUID RM reported for it */
struct nv_uvm_gpu {
    nv_state_t *nv;
    NvProcessorUuid uuid;
    NvU32 refs;
};

static struct mtx nv_uvm_mtx;
static struct sx nv_uvm_reg_sx;
static nv_uvm_events_t nv_uvm_ops;
static NvBool nv_uvm_ops_installed;
static volatile u_int nv_uvm_inflight;
static struct nv_uvm_gpu nv_uvm_gpus[NV_MAX_DEVICES];

/*
 * Every wrapper below follows one shape: allocate a stack (M_WAITOK: all of
 * them run in thread context), call, free.  NV_UMA_ZONE_ALLOC_STACK leaves
 * NULL only when the zone is gone, which cannot happen while nvidia.ko is
 * loaded, but the check keeps the "fail closed" shape the rest of the OS
 * layer uses.
 */
#define NV_UVM_STACK_ENTER(sp)                                           \
    nvidia_stack_t *sp;                                                  \
    NV_UMA_ZONE_ALLOC_STACK(sp);                                         \
    if ((sp) == NULL)                                                    \
        return NV_ERR_NO_MEMORY

#define NV_UVM_STACK_ENTER_VOID(sp)                                      \
    nvidia_stack_t *sp;                                                  \
    NV_UMA_ZONE_ALLOC_STACK(sp);                                         \
    if ((sp) == NULL)                                                    \
        return

#define NV_UVM_STACK_EXIT(sp) NV_UMA_ZONE_FREE_STACK(sp)

/* ---- module lifetime hooks ---- */

void nv_uvm_glue_init(void)
{
    mtx_init(&nv_uvm_mtx, "nvidia_uvm_glue", NULL, MTX_DEF);
    sx_init(&nv_uvm_reg_sx, "nvidia_uvm_reg");
    memset(nv_uvm_gpus, 0, sizeof(nv_uvm_gpus));
    nv_uvm_ops_installed = NV_FALSE;
}

void nv_uvm_glue_exit(void)
{
    sx_destroy(&nv_uvm_reg_sx);
    mtx_destroy(&nv_uvm_mtx);
}

NvBool nv_uvm_callbacks_installed(void)
{
    NvBool installed;

    mtx_lock(&nv_uvm_mtx);
    installed = nv_uvm_ops_installed;
    mtx_unlock(&nv_uvm_mtx);
    return installed;
}

/*
 * nv_uvm_gpu_find_locked - the table slot for a device, or NULL.
 * Time:  O(NV_MAX_DEVICES).  Space: O(1).  Caller holds nv_uvm_mtx.
 */
static struct nv_uvm_gpu *nv_uvm_gpu_find_locked(nv_state_t *nv)
{
    unsigned int i;

    for (i = 0; i < NV_MAX_DEVICES; i++) {
        if (nv_uvm_gpus[i].nv == nv)
            return &nv_uvm_gpus[i];
    }
    return NULL;
}

static struct nv_uvm_gpu *nv_uvm_gpu_find_uuid_locked(const NvProcessorUuid *pUuid)
{
    unsigned int i;

    for (i = 0; i < NV_MAX_DEVICES; i++) {
        if (nv_uvm_gpus[i].nv != NULL &&
            memcmp(nv_uvm_gpus[i].uuid.uuid, pUuid->uuid, sizeof(pUuid->uuid)) == 0)
            return &nv_uvm_gpus[i];
    }
    return NULL;
}

/*
 * nv_uvm_isr_top_half - run UVM's top half for a GPU (02 section 5).  Called
 * from nvidia_intr() before rm_isr(), and from nv_schedule_uvm_isr().  The
 * callback runs outside the mutex and is counted so DeRegisterUvmOps can
 * wait for it; the UUID is copied first so the table may change meanwhile.
 * Time:  O(NV_MAX_DEVICES) for the lookup, then the callback.
 */
NV_STATUS nv_uvm_isr_top_half(nv_state_t *nv)
{
    NV_STATUS (*top_half)(const NvProcessorUuid *);
    struct nv_uvm_gpu *g;
    NvProcessorUuid uuid;
    NV_STATUS status;

    mtx_lock(&nv_uvm_mtx);
    if (!nv_uvm_ops_installed || nv_uvm_ops.isrTopHalf == NULL) {
        mtx_unlock(&nv_uvm_mtx);
        return NV_ERR_NO_INTR_PENDING;
    }
    g = nv_uvm_gpu_find_locked(nv);
    if (g == NULL) {
        mtx_unlock(&nv_uvm_mtx);
        return NV_ERR_NO_INTR_PENDING;
    }
    uuid = g->uuid;
    top_half = nv_uvm_ops.isrTopHalf;
    atomic_add_int(&nv_uvm_inflight, 1);
    mtx_unlock(&nv_uvm_mtx);

    status = top_half(&uuid);

    atomic_subtract_int(&nv_uvm_inflight, 1);
    return status;
}

/*
 * nv_uvm_call_uuid_cb - run one of the UUID-taking callbacks (drain/resume
 * P2P) if a table is installed; NV_ERR_NOT_SUPPORTED otherwise.
 */
static NV_STATUS nv_uvm_call_uuid_cb(size_t member_offset, const NvProcessorUuid *pUuid)
{
    NV_STATUS (*cb)(const NvProcessorUuid *);
    NV_STATUS status;

    mtx_lock(&nv_uvm_mtx);
    if (!nv_uvm_ops_installed) {
        mtx_unlock(&nv_uvm_mtx);
        return NV_ERR_NOT_SUPPORTED;
    }
    cb = *(NV_STATUS (**)(const NvProcessorUuid *))((char *)&nv_uvm_ops + member_offset);
    if (cb == NULL) {
        mtx_unlock(&nv_uvm_mtx);
        return NV_ERR_NOT_SUPPORTED;
    }
    atomic_add_int(&nv_uvm_inflight, 1);
    mtx_unlock(&nv_uvm_mtx);
    status = cb(pUuid);
    atomic_subtract_int(&nv_uvm_inflight, 1);
    return status;
}

static NV_STATUS nv_uvm_call_void_cb(size_t member_offset)
{
    NV_STATUS (*cb)(void);
    NV_STATUS status;

    mtx_lock(&nv_uvm_mtx);
    if (!nv_uvm_ops_installed) {
        mtx_unlock(&nv_uvm_mtx);
        return NV_OK;
    }
    cb = *(NV_STATUS (**)(void))((char *)&nv_uvm_ops + member_offset);
    if (cb == NULL) {
        mtx_unlock(&nv_uvm_mtx);
        return NV_OK;
    }
    atomic_add_int(&nv_uvm_inflight, 1);
    mtx_unlock(&nv_uvm_mtx);
    status = cb();
    atomic_subtract_int(&nv_uvm_inflight, 1);
    return status;
}

NV_STATUS nv_uvm_suspend(void)
{
    return nv_uvm_call_void_cb(offsetof(nv_uvm_events_t, suspend));
}

NV_STATUS nv_uvm_resume(void)
{
    return nv_uvm_call_void_cb(offsetof(nv_uvm_events_t, resume));
}

/*
 * The hooks RM itself calls (declared in nv.h): osQueueMMUFaultHandler ->
 * nv_schedule_uvm_isr when RM's interrupt service finds UVM-owned work;
 * osQueueDrainP2PHandler / resume for NVLink error recovery.
 */
void NV_API_CALL nv_schedule_uvm_isr(nv_state_t *nv)
{
    (void)nv_uvm_isr_top_half(nv);
}

NV_STATUS NV_API_CALL nv_schedule_uvm_drain_p2p(NvU8 *pUuid)
{
    return nv_uvm_call_uuid_cb(offsetof(nv_uvm_events_t, drainP2P),
                               (const NvProcessorUuid *)pUuid);
}

void NV_API_CALL nv_schedule_uvm_resume_p2p(NvU8 *pUuid)
{
    (void)nv_uvm_call_uuid_cb(offsetof(nv_uvm_events_t, resumeP2P),
                              (const NvProcessorUuid *)pUuid);
}

/* ---- 3.1 module lifetime ---- */

NV_STATUS nvUvmInterfaceSessionCreate(nvgpuSessionHandle_t *session, UvmPlatformInfo *platformInfo)
{
    NV_STATUS status;
    NV_UVM_STACK_ENTER(sp);

    if (platformInfo != NULL) {
        memset(platformInfo, 0, sizeof(*platformInfo));
        platformInfo->atsSupported = NV_FALSE;
        platformInfo->confComputingEnabled = NV_FALSE;
    }
    status = rm_gpu_ops_create_session(sp, session);
    NV_UVM_STACK_EXIT(sp);
    return status;
}

void nvUvmInterfaceSessionDestroy(nvgpuSessionHandle_t session)
{
    NV_UVM_STACK_ENTER_VOID(sp);
    (void)rm_gpu_ops_destroy_session(sp, session);
    NV_UVM_STACK_EXIT(sp);
}

NV_STATUS nvUvmInterfaceRegisterUvmCallbacks(const nv_uvm_events_t *ops)
{
    if (ops == NULL)
        return NV_ERR_INVALID_ARGUMENT;

    mtx_lock(&nv_uvm_mtx);
    if (nv_uvm_ops_installed) {
        mtx_unlock(&nv_uvm_mtx);
        return NV_ERR_IN_USE;
    }
    nv_uvm_ops = *ops;
    nv_uvm_ops_installed = NV_TRUE;
    mtx_unlock(&nv_uvm_mtx);
    return NV_OK;
}

/*
 * nvUvmInterfaceDeRegisterUvmOps - remove the table and wait until every
 * callback in progress on any CPU has returned (02 section 3.1).  The wait
 * is a bounded-step poll: callbacks are short (the top half schedules work
 * and returns), and nothing new can start once the flag is cleared.
 */
void nvUvmInterfaceDeRegisterUvmOps(void)
{
    mtx_lock(&nv_uvm_mtx);
    nv_uvm_ops_installed = NV_FALSE;
    memset(&nv_uvm_ops, 0, sizeof(nv_uvm_ops));
    mtx_unlock(&nv_uvm_mtx);

    while (atomic_load_acq_int(&nv_uvm_inflight) != 0)
        pause("uvmdrg", 1);
}

/* ---- 3.2 GPU lifetime by UUID ---- */

/*
 * nvUvmInterfaceRegisterGpu - find the RM device with this UUID, opening
 * each attached device (rm_init_adapter, so RM knows its UUID) and closing
 * the ones that do not match; the match keeps its open reference until
 * UnregisterGpu, and RM's external-kernel-client count is raised so the
 * device cannot be torn down under UVM.  Returns the PCI device and the
 * DMA window the OS layer recorded for it (02 section 6 item 2).
 * Time:  O(NV_MAX_DEVICES) device opens in the worst case.
 */
NV_STATUS nvUvmInterfaceRegisterGpu(const NvProcessorUuid *pUuid, nv_uvm_gpu_platform_info_t *info)
{
    struct nvidia_softc *sc;
    struct nv_uvm_gpu *g;
    nv_state_t *nv, *match = NULL;
    const NvU8 *raw;
    unsigned int i;
    NV_STATUS status = NV_ERR_GPU_UUID_NOT_FOUND;
    nvidia_stack_t *sp;

    if (pUuid == NULL || info == NULL)
        return NV_ERR_INVALID_ARGUMENT;

    NV_UMA_ZONE_ALLOC_STACK(sp);
    if (sp == NULL)
        return NV_ERR_NO_MEMORY;

    sx_xlock(&nv_uvm_reg_sx);

    for (i = 0; i < NV_MAX_DEVICES && match == NULL; i++) {
        sc = devclass_get_softc(nvidia_devclass, i);
        if (sc == NULL || sc->nv_state == NULL)
            continue;
        nv = sc->nv_state;
        if (nv->flags & NV_FLAG_CONTROL)
            continue;
        if (nvidia_open_dev(nv, NULL) != 0)
            continue;
        raw = rm_get_gpu_uuid_raw(sp, nv);
        if (raw != NULL && memcmp(raw, pUuid->uuid, sizeof(pUuid->uuid)) == 0) {
            match = nv;         /* keep the open reference */
            break;
        }
        nvidia_close_dev(nv, NULL);
    }

    if (match == NULL)
        goto out;

    mtx_lock(&nv_uvm_mtx);
    g = nv_uvm_gpu_find_locked(match);
    if (g == NULL) {
        for (i = 0; i < NV_MAX_DEVICES; i++) {
            if (nv_uvm_gpus[i].nv == NULL) {
                g = &nv_uvm_gpus[i];
                break;
            }
        }
    }
    if (g == NULL) {
        mtx_unlock(&nv_uvm_mtx);
        nvidia_close_dev(match, NULL);
        status = NV_ERR_INSUFFICIENT_RESOURCES;
        goto out;
    }
    if (g->nv == NULL) {
        g->nv = match;
        g->uuid = *pUuid;
        g->refs = 0;
    }
    g->refs++;
    mtx_unlock(&nv_uvm_mtx);

    status = rm_set_external_kernel_client_count(sp, match, NV_TRUE);
    if (status != NV_OK) {
        mtx_lock(&nv_uvm_mtx);
        if (--g->refs == 0)
            memset(g, 0, sizeof(*g));
        mtx_unlock(&nv_uvm_mtx);
        nvidia_close_dev(match, NULL);
        goto out;
    }

    sc = match->os_state;
    info->dev = sc->dev;
    info->dma_addressable_start = 0;
    info->dma_addressable_limit = sc->dma_mask;
    status = NV_OK;

out:
    sx_xunlock(&nv_uvm_reg_sx);
    NV_UMA_ZONE_FREE_STACK(sp);
    return status;
}

void nvUvmInterfaceUnregisterGpu(const NvProcessorUuid *pUuid)
{
    struct nv_uvm_gpu *g;
    nv_state_t *nv = NULL;
    nvidia_stack_t *sp;

    if (pUuid == NULL)
        return;

    NV_UMA_ZONE_ALLOC_STACK(sp);
    if (sp == NULL)
        return;

    sx_xlock(&nv_uvm_reg_sx);
    mtx_lock(&nv_uvm_mtx);
    g = nv_uvm_gpu_find_uuid_locked(pUuid);
    if (g != NULL) {
        nv = g->nv;
        if (--g->refs == 0)
            memset(g, 0, sizeof(*g));
    }
    mtx_unlock(&nv_uvm_mtx);

    if (nv != NULL) {
        (void)rm_set_external_kernel_client_count(sp, nv, NV_FALSE);
        nvidia_close_dev(nv, NULL);
    }
    sx_xunlock(&nv_uvm_reg_sx);
    NV_UMA_ZONE_FREE_STACK(sp);
}

/*
 * CPD-OFF -- one wrapper per RM gpu-ops entry point from here to the end
 * of the file, all of the same shape by design (allocate a stack, call,
 * free, return): the repetition is the interface, not a copy to factor.
 */

NV_STATUS nvUvmInterfaceGetGpuInfo(const NvProcessorUuid *pUuid, const nvgpuClientInfo_t *pClientInfo,
                                   nvgpuInfo_t *pGpuInfo)
{
    NV_STATUS status;
    NV_UVM_STACK_ENTER(sp);
    status = rm_gpu_ops_get_gpu_info(sp, pUuid, pClientInfo, pGpuInfo);
    NV_UVM_STACK_EXIT(sp);
    return status;
}

NV_STATUS nvUvmInterfaceDeviceCreate(nvgpuSessionHandle_t session, const nvgpuInfo_t *pGpuInfo,
                                     const NvProcessorUuid *pUuid, nvgpuDeviceHandle_t *device,
                                     NvBool bCreateSmcPartition)
{
    NV_STATUS status;
    NV_UVM_STACK_ENTER(sp);
    status = rm_gpu_ops_device_create(sp, session, pGpuInfo, pUuid, device, bCreateSmcPartition);
    NV_UVM_STACK_EXIT(sp);
    return status;
}

void nvUvmInterfaceDeviceDestroy(nvgpuDeviceHandle_t device)
{
    NV_UVM_STACK_ENTER_VOID(sp);
    (void)rm_gpu_ops_device_destroy(sp, device);
    NV_UVM_STACK_EXIT(sp);
}

NV_STATUS nvUvmInterfaceGetFbInfo(nvgpuDeviceHandle_t device, nvgpuFbInfo_t fbInfo)
{
    NV_STATUS status;
    NV_UVM_STACK_ENTER(sp);
    status = rm_gpu_ops_get_fb_info(sp, device, fbInfo);
    NV_UVM_STACK_EXIT(sp);
    return status;
}

NV_STATUS nvUvmInterfaceQueryCaps(nvgpuDeviceHandle_t device, nvgpuCaps_t caps)
{
    NV_STATUS status;
    NV_UVM_STACK_ENTER(sp);
    status = rm_gpu_ops_query_caps(sp, device, caps);
    NV_UVM_STACK_EXIT(sp);
    return status;
}

NV_STATUS nvUvmInterfaceAddressSpaceCreate(nvgpuDeviceHandle_t device, NvU64 vaBase, NvU64 vaSize,
                                           NvBool enableAts, nvgpuAddressSpaceHandle_t *vaSpace,
                                           nvgpuAddressSpaceInfo_t vaSpaceInfo)
{
    NV_STATUS status;
    NV_UVM_STACK_ENTER(sp);
    status = rm_gpu_ops_address_space_create(sp, device, vaBase, vaSize, enableAts, vaSpace, vaSpaceInfo);
    NV_UVM_STACK_EXIT(sp);
    return status;
}

void nvUvmInterfaceAddressSpaceDestroy(nvgpuAddressSpaceHandle_t vaSpace)
{
    NV_UVM_STACK_ENTER_VOID(sp);
    (void)rm_gpu_ops_address_space_destroy(sp, vaSpace);
    NV_UVM_STACK_EXIT(sp);
}

NV_STATUS nvUvmInterfaceGetEccInfo(nvgpuDeviceHandle_t device, nvgpuEccInfo_t eccInfo)
{
    NV_STATUS status;
    NV_UVM_STACK_ENTER(sp);
    status = rm_gpu_ops_get_ecc_info(sp, device, eccInfo);
    NV_UVM_STACK_EXIT(sp);
    return status;
}

NV_STATUS nvUvmInterfaceGetNvlinkInfo(nvgpuDeviceHandle_t device, nvgpuNvlinkInfo_t nvlinkInfo)
{
    NV_STATUS status;
    NV_UVM_STACK_ENTER(sp);
    status = rm_gpu_ops_get_nvlink_info(sp, device, nvlinkInfo);
    NV_UVM_STACK_EXIT(sp);
    return status;
}

NV_STATUS nvUvmInterfaceGetPmaObject(nvgpuDeviceHandle_t device, void **pPma,
                                     const UvmPmaStatistics **pPmaPubStats)
{
    NV_STATUS status;
    UvmPmaStatistics *stats = NULL;
    NV_UVM_STACK_ENTER(sp);
    /* RM's signature spells the output as a pointer to a mutable pointer; UVM reads only */
    status = rm_gpu_ops_get_pma_object(sp, device, pPma, &stats);
    if (status == NV_OK && pPmaPubStats != NULL)
        *pPmaPubStats = stats;
    NV_UVM_STACK_EXIT(sp);
    return status;
}

NV_STATUS nvUvmInterfacePmaRegisterEvictionCallbacks(void *pPma, nvPmaEvictPagesCallback evictPages,
                                                     nvPmaEvictRangeCallback evictRange, void *callbackData)
{
    NV_STATUS status;
    NV_UVM_STACK_ENTER(sp);
    status = rm_gpu_ops_pma_register_callbacks(sp, pPma, evictPages, evictRange, callbackData);
    NV_UVM_STACK_EXIT(sp);
    return status;
}

void nvUvmInterfacePmaUnregisterEvictionCallbacks(void *pPma)
{
    NV_UVM_STACK_ENTER_VOID(sp);
    rm_gpu_ops_pma_unregister_callbacks(sp, pPma);
    NV_UVM_STACK_EXIT(sp);
}

NV_STATUS nvUvmInterfaceQueryCopyEnginesCaps(nvgpuDeviceHandle_t device, nvgpuCesCaps_t caps)
{
    NV_STATUS status;
    NV_UVM_STACK_ENTER(sp);
    status = rm_gpu_ops_query_ces_caps(sp, device, caps);
    NV_UVM_STACK_EXIT(sp);
    return status;
}

/* ---- 3.3 RM-backed memory ---- */

NV_STATUS nvUvmInterfaceMemoryAllocSys(nvgpuAddressSpaceHandle_t vaSpace, NvLength length,
                                       UvmGpuPointer *gpuPointer, nvgpuAllocInfo_t allocInfo)
{
    NV_STATUS status;
    NV_UVM_STACK_ENTER(sp);
    status = rm_gpu_ops_memory_alloc_sys(sp, vaSpace, length, (NvU64 *)gpuPointer, allocInfo);
    NV_UVM_STACK_EXIT(sp);
    return status;
}

NV_STATUS nvUvmInterfaceMemoryAllocFB(nvgpuAddressSpaceHandle_t vaSpace, NvLength length,
                                      UvmGpuPointer *gpuPointer, nvgpuAllocInfo_t allocInfo)
{
    NV_STATUS status;
    NV_UVM_STACK_ENTER(sp);
    status = rm_gpu_ops_memory_alloc_fb(sp, vaSpace, length, (NvU64 *)gpuPointer, allocInfo);
    NV_UVM_STACK_EXIT(sp);
    return status;
}

void nvUvmInterfaceMemoryFree(nvgpuAddressSpaceHandle_t vaSpace, UvmGpuPointer gpuPointer)
{
    NV_UVM_STACK_ENTER_VOID(sp);
    (void)rm_gpu_ops_memory_free(sp, vaSpace, (NvU64)gpuPointer);
    NV_UVM_STACK_EXIT(sp);
}

NV_STATUS nvUvmInterfaceMemoryCpuMap(nvgpuAddressSpaceHandle_t vaSpace, UvmGpuPointer gpuPointer,
                                     NvLength length, void **cpuPtr, NvU64 pageSize)
{
    NV_STATUS status;
    NV_UVM_STACK_ENTER(sp);
    status = rm_gpu_ops_memory_cpu_map(sp, vaSpace, (NvU64)gpuPointer, length, cpuPtr, pageSize);
    NV_UVM_STACK_EXIT(sp);
    return status;
}

void nvUvmInterfaceMemoryCpuUnMap(nvgpuAddressSpaceHandle_t vaSpace, void *cpuPtr)
{
    NV_UVM_STACK_ENTER_VOID(sp);
    (void)rm_gpu_ops_memory_cpu_ummap(sp, vaSpace, cpuPtr);
    NV_UVM_STACK_EXIT(sp);
}

NV_STATUS nvUvmInterfaceDupAllocation(nvgpuAddressSpaceHandle_t srcVaSpace, NvU64 srcAddress,
                                      nvgpuAddressSpaceHandle_t dstVaSpace, NvU64 dstVaAlignment,
                                      NvU64 *dstAddress)
{
    NV_STATUS status;
    NV_UVM_STACK_ENTER(sp);
    status = rm_gpu_ops_dup_allocation(sp, srcVaSpace, srcAddress, dstVaSpace, dstVaAlignment, dstAddress);
    NV_UVM_STACK_EXIT(sp);
    return status;
}

/* ---- 3.4 channels ---- */

NV_STATUS nvUvmInterfaceTsgAllocate(nvgpuAddressSpaceHandle_t vaSpace,
                                    const nvgpuTsgAllocParams_t *allocParams, nvgpuTsgHandle_t *tsg)
{
    NV_STATUS status;
    NV_UVM_STACK_ENTER(sp);
    status = rm_gpu_ops_tsg_allocate(sp, vaSpace, allocParams, tsg);
    NV_UVM_STACK_EXIT(sp);
    return status;
}

void nvUvmInterfaceTsgDestroy(nvgpuTsgHandle_t tsg)
{
    NV_UVM_STACK_ENTER_VOID(sp);
    (void)rm_gpu_ops_tsg_destroy(sp, tsg);
    NV_UVM_STACK_EXIT(sp);
}

NV_STATUS nvUvmInterfaceChannelAllocate(nvgpuTsgHandle_t tsg, const nvgpuChannelAllocParams_t *allocParams,
                                        nvgpuChannelHandle_t *channel, nvgpuChannelInfo_t channelInfo)
{
    NV_STATUS status;
    NV_UVM_STACK_ENTER(sp);
    status = rm_gpu_ops_channel_allocate(sp, tsg, allocParams, channel, channelInfo);
    NV_UVM_STACK_EXIT(sp);
    return status;
}

void nvUvmInterfaceChannelDestroy(nvgpuChannelHandle_t channel)
{
    NV_UVM_STACK_ENTER_VOID(sp);
    (void)rm_gpu_ops_channel_destroy(sp, channel);
    NV_UVM_STACK_EXIT(sp);
}

/* ---- 3.5 page directory hand-over ---- */

NV_STATUS nvUvmInterfaceSetPageDirectory(nvgpuAddressSpaceHandle_t vaSpace, NvU64 physAddress,
                                         unsigned numEntries, NvBool bVidMemAperture, NvU32 pasid,
                                         NvU64 *dmaAddress)
{
    NV_STATUS status;
    NV_UVM_STACK_ENTER(sp);
    status = rm_gpu_ops_set_page_directory(sp, vaSpace, physAddress, numEntries, bVidMemAperture, pasid,
                                           dmaAddress);
    NV_UVM_STACK_EXIT(sp);
    return status;
}

NV_STATUS nvUvmInterfaceUnsetPageDirectory(nvgpuAddressSpaceHandle_t vaSpace)
{
    NV_STATUS status;
    NV_UVM_STACK_ENTER(sp);
    status = rm_gpu_ops_unset_page_directory(sp, vaSpace);
    NV_UVM_STACK_EXIT(sp);
    return status;
}

NV_STATUS nvUvmInterfaceDupAddressSpace(nvgpuDeviceHandle_t device, NvHandle hUserClient, NvHandle hUserVASpace,
                                        nvgpuAddressSpaceHandle_t *vaSpace, nvgpuAddressSpaceInfo_t vaSpaceInfo)
{
    NV_STATUS status;
    NV_UVM_STACK_ENTER(sp);
    status = rm_gpu_ops_dup_address_space(sp, device, hUserClient, hUserVASpace, vaSpace, vaSpaceInfo);
    NV_UVM_STACK_EXIT(sp);
    return status;
}

/* ---- 3.6 fault buffers ---- */

/*
 * nvUvmInterfaceInitFaultInfo - RM allocates and maps the fault buffers;
 * the glue then allocates the two RM stacks the lock-free calls use (02
 * section 6 item 6).  If a stack cannot be had the RM state is torn down
 * again so the caller never sees a half-initialised structure.
 */
NV_STATUS nvUvmInterfaceInitFaultInfo(nvgpuDeviceHandle_t device, nvgpuFaultInfo_t pFaultInfo)
{
    NV_STATUS status;
    nvidia_stack_t *isr_sp = NULL, *isr_bh_sp = NULL;
    NV_UVM_STACK_ENTER(sp);

    status = rm_gpu_ops_init_fault_info(sp, device, pFaultInfo);
    if (status != NV_OK)
        goto out;

    NV_UMA_ZONE_ALLOC_STACK(isr_sp);
    NV_UMA_ZONE_ALLOC_STACK(isr_bh_sp);
    if (isr_sp == NULL || isr_bh_sp == NULL) {
        if (isr_sp != NULL)
            NV_UMA_ZONE_FREE_STACK(isr_sp);
        if (isr_bh_sp != NULL)
            NV_UMA_ZONE_FREE_STACK(isr_bh_sp);
        (void)rm_gpu_ops_destroy_fault_info(sp, device, pFaultInfo);
        status = NV_ERR_NO_MEMORY;
        goto out;
    }
    pFaultInfo->nonReplayable.isr_sp = isr_sp;
    pFaultInfo->nonReplayable.isr_bh_sp = isr_bh_sp;

out:
    NV_UVM_STACK_EXIT(sp);
    return status;
}

NV_STATUS nvUvmInterfaceDestroyFaultInfo(nvgpuDeviceHandle_t device, nvgpuFaultInfo_t pFaultInfo)
{
    NV_STATUS status;
    nvidia_stack_t *s;
    NV_UVM_STACK_ENTER(sp);

    s = pFaultInfo->nonReplayable.isr_sp;
    if (s != NULL) {
        NV_UMA_ZONE_FREE_STACK(s);
        pFaultInfo->nonReplayable.isr_sp = NULL;
    }
    s = pFaultInfo->nonReplayable.isr_bh_sp;
    if (s != NULL) {
        NV_UMA_ZONE_FREE_STACK(s);
        pFaultInfo->nonReplayable.isr_bh_sp = NULL;
    }
    status = rm_gpu_ops_destroy_fault_info(sp, device, pFaultInfo);
    NV_UVM_STACK_EXIT(sp);
    return status;
}

/* lock free: the pre-allocated stacks, no allocation, no RM locks inside */
NV_STATUS nvUvmInterfaceHasPendingNonReplayableFaults(nvgpuFaultInfo_t pFaultInfo, NvBool *hasPending)
{
    nvidia_stack_t *sp = pFaultInfo->nonReplayable.isr_sp;

    if (sp == NULL)
        return NV_ERR_INVALID_STATE;
    return rm_gpu_ops_has_pending_non_replayable_faults(sp, pFaultInfo, hasPending);
}

NV_STATUS nvUvmInterfaceGetNonReplayableFaults(nvgpuFaultInfo_t pFaultInfo, void *pFaultBuffer, NvU32 *numFaults)
{
    nvidia_stack_t *sp = pFaultInfo->nonReplayable.isr_bh_sp;

    if (sp == NULL)
        return NV_ERR_INVALID_STATE;
    return rm_gpu_ops_get_non_replayable_faults(sp, pFaultInfo, pFaultBuffer, numFaults);
}

NV_STATUS nvUvmInterfaceFlushReplayableFaultBuffer(nvgpuFaultInfo_t pFaultInfo, NvBool bCopyAndFlush)
{
    nvidia_stack_t *sp = pFaultInfo->nonReplayable.isr_bh_sp;

    if (sp == NULL)
        return NV_ERR_INVALID_STATE;
    return rm_gpu_ops_flush_replayable_fault_buffer(sp, pFaultInfo, bCopyAndFlush);
}

NV_STATUS nvUvmInterfaceTogglePrefetchFaults(nvgpuFaultInfo_t pFaultInfo, NvBool bEnable)
{
    nvidia_stack_t *sp = pFaultInfo->nonReplayable.isr_bh_sp;

    if (sp == NULL)
        return NV_ERR_INVALID_STATE;
    return rm_gpu_ops_toggle_prefetch_faults(sp, pFaultInfo, bEnable);
}

NV_STATUS nvUvmInterfaceReportNonReplayableFault(nvgpuDeviceHandle_t device, const void *pFaultPacket)
{
    NV_STATUS status;
    NV_UVM_STACK_ENTER(sp);
    status = rm_gpu_ops_report_non_replayable_fault(sp, device, pFaultPacket);
    NV_UVM_STACK_EXIT(sp);
    return status;
}

/* ---- 3.7 interrupt ownership ---- */

NV_STATUS nvUvmInterfaceOwnPageFaultIntr(nvgpuDeviceHandle_t device, NvBool bOwnInterrupts)
{
    NV_STATUS status;
    NV_UVM_STACK_ENTER(sp);
    status = rm_gpu_ops_own_page_fault_intr(sp, device, bOwnInterrupts);
    NV_UVM_STACK_EXIT(sp);
    return status;
}

NV_STATUS nvUvmInterfaceServiceDeviceInterruptsRM(nvgpuDeviceHandle_t device)
{
    NV_STATUS status;
    NV_UVM_STACK_ENTER(sp);
    status = rm_gpu_ops_service_device_interrupts_rm(sp, device);
    NV_UVM_STACK_EXIT(sp);
    return status;
}

/* ---- 3.8 user objects ---- */

NV_STATUS nvUvmInterfaceRetainChannel(nvgpuAddressSpaceHandle_t vaSpace, NvHandle hClient, NvHandle hChannel,
                                      void **retainedChannel, nvgpuChannelInstanceInfo_t channelInstanceInfo)
{
    NV_STATUS status;
    NV_UVM_STACK_ENTER(sp);
    status = rm_gpu_ops_retain_channel(sp, vaSpace, hClient, hChannel, retainedChannel, channelInstanceInfo);
    NV_UVM_STACK_EXIT(sp);
    return status;
}

void nvUvmInterfaceReleaseChannel(void *retainedChannel)
{
    NV_UVM_STACK_ENTER_VOID(sp);
    rm_gpu_ops_release_channel(sp, retainedChannel);
    NV_UVM_STACK_EXIT(sp);
}

NV_STATUS nvUvmInterfaceGetChannelResourcePtes(nvgpuAddressSpaceHandle_t vaSpace, NvP64 resourceDescriptor,
                                               NvU64 offset, NvU64 size,
                                               nvgpuExternalMappingInfo_t pExternalMappingInfo)
{
    NV_STATUS status;
    NV_UVM_STACK_ENTER(sp);
    status = rm_gpu_ops_get_channel_resource_ptes(sp, vaSpace, resourceDescriptor, offset, size,
                                                  pExternalMappingInfo);
    NV_UVM_STACK_EXIT(sp);
    return status;
}

NV_STATUS nvUvmInterfaceBindChannelResources(void *retainedChannel,
                                             nvgpuChannelResourceBindParams_t channelResourceBindParams)
{
    NV_STATUS status;
    NV_UVM_STACK_ENTER(sp);
    status = rm_gpu_ops_bind_channel_resources(sp, retainedChannel, channelResourceBindParams);
    NV_UVM_STACK_EXIT(sp);
    return status;
}

void nvUvmInterfaceStopChannel(void *retainedChannel, NvBool bImmediate)
{
    NV_UVM_STACK_ENTER_VOID(sp);
    rm_gpu_ops_stop_channel(sp, retainedChannel, bImmediate);
    NV_UVM_STACK_EXIT(sp);
}

NV_STATUS nvUvmInterfaceDupMemory(nvgpuDeviceHandle_t device, NvHandle hClient, NvHandle hPhysMemory,
                                  NvHandle *hDupMemory, nvgpuMemoryInfo_t pGpuMemoryInfo)
{
    NV_STATUS status;
    NV_UVM_STACK_ENTER(sp);
    status = rm_gpu_ops_dup_memory(sp, device, hClient, hPhysMemory, hDupMemory, pGpuMemoryInfo);
    NV_UVM_STACK_EXIT(sp);
    return status;
}

NV_STATUS nvUvmInterfaceFreeDupedHandle(nvgpuDeviceHandle_t device, NvHandle hPhysHandle)
{
    NV_STATUS status;
    NV_UVM_STACK_ENTER(sp);
    status = rm_gpu_ops_free_duped_handle(sp, device, hPhysHandle);
    NV_UVM_STACK_EXIT(sp);
    return status;
}

NV_STATUS nvUvmInterfaceGetExternalAllocPtes(nvgpuAddressSpaceHandle_t vaSpace, NvHandle hDupedMemory,
                                             NvU64 offset, NvU64 size,
                                             nvgpuExternalMappingInfo_t pExternalMappingInfo)
{
    NV_STATUS status;
    NV_UVM_STACK_ENTER(sp);
    status = rm_gpu_ops_get_external_alloc_ptes(sp, vaSpace, hDupedMemory, offset, size, pExternalMappingInfo);
    NV_UVM_STACK_EXIT(sp);
    return status;
}

/* ---- 3.9 the physical memory allocator ---- */

NV_STATUS nvUvmInterfacePmaAllocPages(void *pPma, NvLength pageCount, NvU64 pageSize,
                                      nvgpuPmaAllocationOptions_t pPmaAllocOptions, NvU64 *pPages)
{
    NV_STATUS status;
    NV_UVM_STACK_ENTER(sp);
    status = rm_gpu_ops_pma_alloc_pages(sp, pPma, pageCount, pageSize, pPmaAllocOptions, pPages);
    NV_UVM_STACK_EXIT(sp);
    return status;
}

NV_STATUS nvUvmInterfacePmaPinPages(void *pPma, NvU64 *pPages, NvLength pageCount, NvU64 pageSize, NvU32 flags)
{
    NV_STATUS status;
    NV_UVM_STACK_ENTER(sp);
    status = rm_gpu_ops_pma_pin_pages(sp, pPma, pPages, pageCount, pageSize, flags);
    NV_UVM_STACK_EXIT(sp);
    return status;
}

void nvUvmInterfacePmaFreePages(void *pPma, NvU64 *pPages, NvLength pageCount, NvU64 pageSize, NvU32 flags)
{
    NV_UVM_STACK_ENTER_VOID(sp);
    (void)rm_gpu_ops_pma_free_pages(sp, pPma, pPages, pageCount, pageSize, flags);
    NV_UVM_STACK_EXIT(sp);
}

/* ---- 3.10 peers and access counters ---- */

NV_STATUS nvUvmInterfaceP2pObjectCreate(nvgpuDeviceHandle_t device1, nvgpuDeviceHandle_t device2,
                                        NvHandle *hP2pObject)
{
    NV_STATUS status;
    NV_UVM_STACK_ENTER(sp);
    status = rm_gpu_ops_p2p_object_create(sp, device1, device2, hP2pObject);
    NV_UVM_STACK_EXIT(sp);
    return status;
}

void nvUvmInterfaceP2pObjectDestroy(nvgpuSessionHandle_t session, NvHandle hP2pObject)
{
    NV_UVM_STACK_ENTER_VOID(sp);
    rm_gpu_ops_p2p_object_destroy(sp, session, hP2pObject);
    NV_UVM_STACK_EXIT(sp);
}

NV_STATUS nvUvmInterfaceGetP2PCaps(nvgpuDeviceHandle_t device1, nvgpuDeviceHandle_t device2,
                                   nvgpuP2PCapsParams_t p2pCapsParams)
{
    NV_STATUS status;
    NV_UVM_STACK_ENTER(sp);
    status = rm_gpu_ops_get_p2p_caps(sp, device1, device2, p2pCapsParams);
    NV_UVM_STACK_EXIT(sp);
    return status;
}

NV_STATUS nvUvmInterfaceInitAccessCntrInfo(nvgpuDeviceHandle_t device, nvgpuAccessCntrInfo_t pAccessCntrInfo,
                                           NvU32 accessCntrIndex)
{
    NV_STATUS status;
    NV_UVM_STACK_ENTER(sp);
    status = rm_gpu_ops_init_access_cntr_info(sp, device, pAccessCntrInfo, accessCntrIndex);
    NV_UVM_STACK_EXIT(sp);
    return status;
}

NV_STATUS nvUvmInterfaceDestroyAccessCntrInfo(nvgpuDeviceHandle_t device, nvgpuAccessCntrInfo_t pAccessCntrInfo)
{
    NV_STATUS status;
    NV_UVM_STACK_ENTER(sp);
    status = rm_gpu_ops_destroy_access_cntr_info(sp, device, pAccessCntrInfo);
    NV_UVM_STACK_EXIT(sp);
    return status;
}

NV_STATUS nvUvmInterfaceEnableAccessCntr(nvgpuDeviceHandle_t device, nvgpuAccessCntrInfo_t pAccessCntrInfo,
                                         const nvgpuAccessCntrConfig_t *pAccessCntrConfig)
{
    NV_STATUS status;
    nvgpuAccessCntrConfig_t config = *pAccessCntrConfig;
    NV_UVM_STACK_ENTER(sp);
    status = rm_gpu_ops_enable_access_cntr(sp, device, pAccessCntrInfo, &config);
    NV_UVM_STACK_EXIT(sp);
    return status;
}

NV_STATUS nvUvmInterfaceDisableAccessCntr(nvgpuDeviceHandle_t device, nvgpuAccessCntrInfo_t pAccessCntrInfo)
{
    NV_STATUS status;
    NV_UVM_STACK_ENTER(sp);
    status = rm_gpu_ops_disable_access_cntr(sp, device, pAccessCntrInfo);
    NV_UVM_STACK_EXIT(sp);
    return status;
}

void nvUvmInterfaceReportFatalError(NV_STATUS error)
{
    NV_UVM_STACK_ENTER_VOID(sp);
    rm_gpu_ops_report_fatal_error(sp, error);
    NV_UVM_STACK_EXIT(sp);
}

/* CPD-ON */

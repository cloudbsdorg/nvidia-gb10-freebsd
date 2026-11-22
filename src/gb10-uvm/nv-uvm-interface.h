/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-3-Clause
 *
 * nv-uvm-interface.h - the UVM side of NVIDIA's FreeBSD kernel glue: the
 * nvUvmInterface* entry points nvidia.ko exports to nvidia-uvm.ko, the
 * callback table UVM installs, and the glue-internal hooks the rest of the
 * OS layer calls (interrupt top half, suspend/resume, P2P drain).
 *
 * The entry points wrap the RM "gpu-ops" functions that the open RM core
 * (open-gpu-kernel-modules 580.178.04, src/nvidia, MIT; built by
 * scripts/build-rmcore.sh into nv-kernel.o) already contains: each one
 * allocates an RM stack, calls the gpu-ops function of the same name
 * pattern, frees the stack and returns its status.  The structures that
 * cross into the RM core come from the core's own interface header
 * nv_uvm_types.h (MIT), which scripts/prepare-tree.sh copies beside this
 * file.  The functional contract is uvm-spec r1, 02-rm-interface.md
 * (sections 3, 5 and 6); this header states the C ABI.
 *
 * Lock-free entry points (02 section 3.6) use the two RM stacks that
 * nvUvmInterfaceInitFaultInfo stores in the fault-info structure instead
 * of allocating one, so they can run from the UVM interrupt path.
 */

#ifndef _NV_UVM_INTERFACE_H_
#define _NV_UVM_INTERFACE_H_

#include "nv.h"
#include "nv_uvm_types.h"

/*
 * The callback table (02 section 5).  nv_uvm_types.h declares a
 * struct UvmOpsUvmEvents whose isrTopHalf member has a Linux-only shape;
 * this port's table is its own type with the layout the UVM module
 * declares on its side (56 bytes: seven function pointers, isrTopHalf at
 * byte 32).  The glue calls the members from thread context only
 * (nvidia_intr runs in an interrupt thread).
 */
typedef struct nv_uvm_events {
    NV_STATUS (*suspend)(void);
    NV_STATUS (*resume)(void);
    NV_STATUS (*startDevice)(const NvProcessorUuid *pUuid);
    NV_STATUS (*stopDevice)(const NvProcessorUuid *pUuid);
    NV_STATUS (*isrTopHalf)(const NvProcessorUuid *pUuid);
    NV_STATUS (*drainP2P)(const NvProcessorUuid *pUuid);
    NV_STATUS (*resumeP2P)(const NvProcessorUuid *pUuid);
} nv_uvm_events_t;

/*
 * The output of nvUvmInterfaceRegisterGpu (02 section 2, UvmGpuPlatformInfo):
 * glue-defined, never seen by the RM core.  The DMA window is the one the
 * OS layer recorded for the device when RM initialised it (sc->dma_mask).
 */
typedef struct nv_uvm_gpu_platform_info {
    device_t dev;
    NvU64 dma_addressable_start;
    NvU64 dma_addressable_limit;
} nv_uvm_gpu_platform_info_t;

/* ---- hooks for the rest of the OS layer (nvidia_subr.c) ---- */

/* module load / unload: the table lock and the registered-GPU table */
void      nv_uvm_glue_init(void);
void      nv_uvm_glue_exit(void);

/*
 * The UVM interrupt top half for a GPU: called by nvidia_intr() BEFORE
 * rm_isr(), and by nv_schedule_uvm_isr() when RM asks for it.  Returns
 * NV_ERR_NO_INTR_PENDING when no callback table is installed or the GPU is
 * not registered with UVM; otherwise what the UVM top half returned.
 */
NV_STATUS nv_uvm_isr_top_half(nv_state_t *nv);

/* NV_TRUE while a UVM callback table is installed (UVM owns fault buffers). */
NvBool    nv_uvm_callbacks_installed(void);

/* system sleep: nvidia_suspend() before RM's standby, nvidia_resume() after RM's resume */
NV_STATUS nv_uvm_suspend(void);
NV_STATUS nv_uvm_resume(void);

/* ---- the exported interface, 02 section 3 ---- */

NV_STATUS nvUvmInterfaceSessionCreate(nvgpuSessionHandle_t *session, UvmPlatformInfo *platformInfo);
void      nvUvmInterfaceSessionDestroy(nvgpuSessionHandle_t session);
NV_STATUS nvUvmInterfaceRegisterUvmCallbacks(const nv_uvm_events_t *ops);
void      nvUvmInterfaceDeRegisterUvmOps(void);

NV_STATUS nvUvmInterfaceRegisterGpu(const NvProcessorUuid *pUuid, nv_uvm_gpu_platform_info_t *info);
void      nvUvmInterfaceUnregisterGpu(const NvProcessorUuid *pUuid);
NV_STATUS nvUvmInterfaceGetGpuInfo(const NvProcessorUuid *pUuid, const nvgpuClientInfo_t *pClientInfo,
                                   nvgpuInfo_t *pGpuInfo);
NV_STATUS nvUvmInterfaceDeviceCreate(nvgpuSessionHandle_t session, const nvgpuInfo_t *pGpuInfo,
                                     const NvProcessorUuid *pUuid, nvgpuDeviceHandle_t *device,
                                     NvBool bCreateSmcPartition);
void      nvUvmInterfaceDeviceDestroy(nvgpuDeviceHandle_t device);
NV_STATUS nvUvmInterfaceGetFbInfo(nvgpuDeviceHandle_t device, nvgpuFbInfo_t fbInfo);
NV_STATUS nvUvmInterfaceQueryCaps(nvgpuDeviceHandle_t device, nvgpuCaps_t caps);
NV_STATUS nvUvmInterfaceAddressSpaceCreate(nvgpuDeviceHandle_t device, NvU64 vaBase, NvU64 vaSize,
                                           NvBool enableAts, nvgpuAddressSpaceHandle_t *vaSpace,
                                           nvgpuAddressSpaceInfo_t vaSpaceInfo);
void      nvUvmInterfaceAddressSpaceDestroy(nvgpuAddressSpaceHandle_t vaSpace);
NV_STATUS nvUvmInterfaceGetEccInfo(nvgpuDeviceHandle_t device, nvgpuEccInfo_t eccInfo);
NV_STATUS nvUvmInterfaceGetNvlinkInfo(nvgpuDeviceHandle_t device, nvgpuNvlinkInfo_t nvlinkInfo);
NV_STATUS nvUvmInterfaceGetPmaObject(nvgpuDeviceHandle_t device, void **pPma,
                                     const UvmPmaStatistics **pPmaPubStats);
NV_STATUS nvUvmInterfacePmaRegisterEvictionCallbacks(void *pPma, nvPmaEvictPagesCallback evictPages,
                                                     nvPmaEvictRangeCallback evictRange,
                                                     void *callbackData);
void      nvUvmInterfacePmaUnregisterEvictionCallbacks(void *pPma);
NV_STATUS nvUvmInterfaceQueryCopyEnginesCaps(nvgpuDeviceHandle_t device, nvgpuCesCaps_t caps);

NV_STATUS nvUvmInterfaceMemoryAllocSys(nvgpuAddressSpaceHandle_t vaSpace, NvLength length,
                                       UvmGpuPointer *gpuPointer, nvgpuAllocInfo_t allocInfo);
NV_STATUS nvUvmInterfaceMemoryAllocFB(nvgpuAddressSpaceHandle_t vaSpace, NvLength length,
                                      UvmGpuPointer *gpuPointer, nvgpuAllocInfo_t allocInfo);
void      nvUvmInterfaceMemoryFree(nvgpuAddressSpaceHandle_t vaSpace, UvmGpuPointer gpuPointer);
NV_STATUS nvUvmInterfaceMemoryCpuMap(nvgpuAddressSpaceHandle_t vaSpace, UvmGpuPointer gpuPointer,
                                     NvLength length, void **cpuPtr, NvU64 pageSize);
void      nvUvmInterfaceMemoryCpuUnMap(nvgpuAddressSpaceHandle_t vaSpace, void *cpuPtr);
NV_STATUS nvUvmInterfaceDupAllocation(nvgpuAddressSpaceHandle_t srcVaSpace, NvU64 srcAddress,
                                      nvgpuAddressSpaceHandle_t dstVaSpace, NvU64 dstVaAlignment,
                                      NvU64 *dstAddress);

NV_STATUS nvUvmInterfaceTsgAllocate(nvgpuAddressSpaceHandle_t vaSpace,
                                    const nvgpuTsgAllocParams_t *allocParams, nvgpuTsgHandle_t *tsg);
void      nvUvmInterfaceTsgDestroy(nvgpuTsgHandle_t tsg);
NV_STATUS nvUvmInterfaceChannelAllocate(nvgpuTsgHandle_t tsg, const nvgpuChannelAllocParams_t *allocParams,
                                        nvgpuChannelHandle_t *channel, nvgpuChannelInfo_t channelInfo);
void      nvUvmInterfaceChannelDestroy(nvgpuChannelHandle_t channel);

NV_STATUS nvUvmInterfaceSetPageDirectory(nvgpuAddressSpaceHandle_t vaSpace, NvU64 physAddress,
                                         unsigned numEntries, NvBool bVidMemAperture, NvU32 pasid,
                                         NvU64 *dmaAddress);
NV_STATUS nvUvmInterfaceUnsetPageDirectory(nvgpuAddressSpaceHandle_t vaSpace);
NV_STATUS nvUvmInterfaceDupAddressSpace(nvgpuDeviceHandle_t device, NvHandle hUserClient,
                                        NvHandle hUserVASpace, nvgpuAddressSpaceHandle_t *vaSpace,
                                        nvgpuAddressSpaceInfo_t vaSpaceInfo);

NV_STATUS nvUvmInterfaceInitFaultInfo(nvgpuDeviceHandle_t device, nvgpuFaultInfo_t pFaultInfo);
NV_STATUS nvUvmInterfaceDestroyFaultInfo(nvgpuDeviceHandle_t device, nvgpuFaultInfo_t pFaultInfo);
NV_STATUS nvUvmInterfaceHasPendingNonReplayableFaults(nvgpuFaultInfo_t pFaultInfo, NvBool *hasPending);
NV_STATUS nvUvmInterfaceGetNonReplayableFaults(nvgpuFaultInfo_t pFaultInfo, void *pFaultBuffer,
                                               NvU32 *numFaults);
NV_STATUS nvUvmInterfaceFlushReplayableFaultBuffer(nvgpuFaultInfo_t pFaultInfo, NvBool bCopyAndFlush);
NV_STATUS nvUvmInterfaceTogglePrefetchFaults(nvgpuFaultInfo_t pFaultInfo, NvBool bEnable);
NV_STATUS nvUvmInterfaceReportNonReplayableFault(nvgpuDeviceHandle_t device, const void *pFaultPacket);

NV_STATUS nvUvmInterfaceOwnPageFaultIntr(nvgpuDeviceHandle_t device, NvBool bOwnInterrupts);
NV_STATUS nvUvmInterfaceServiceDeviceInterruptsRM(nvgpuDeviceHandle_t device);

NV_STATUS nvUvmInterfaceRetainChannel(nvgpuAddressSpaceHandle_t vaSpace, NvHandle hClient, NvHandle hChannel,
                                      void **retainedChannel, nvgpuChannelInstanceInfo_t channelInstanceInfo);
void      nvUvmInterfaceReleaseChannel(void *retainedChannel);
NV_STATUS nvUvmInterfaceGetChannelResourcePtes(nvgpuAddressSpaceHandle_t vaSpace, NvP64 resourceDescriptor,
                                               NvU64 offset, NvU64 size,
                                               nvgpuExternalMappingInfo_t pExternalMappingInfo);
NV_STATUS nvUvmInterfaceBindChannelResources(void *retainedChannel,
                                             nvgpuChannelResourceBindParams_t channelResourceBindParams);
void      nvUvmInterfaceStopChannel(void *retainedChannel, NvBool bImmediate);
NV_STATUS nvUvmInterfaceDupMemory(nvgpuDeviceHandle_t device, NvHandle hClient, NvHandle hPhysMemory,
                                  NvHandle *hDupMemory, nvgpuMemoryInfo_t pGpuMemoryInfo);
NV_STATUS nvUvmInterfaceFreeDupedHandle(nvgpuDeviceHandle_t device, NvHandle hPhysHandle);
NV_STATUS nvUvmInterfaceGetExternalAllocPtes(nvgpuAddressSpaceHandle_t vaSpace, NvHandle hDupedMemory,
                                             NvU64 offset, NvU64 size,
                                             nvgpuExternalMappingInfo_t pExternalMappingInfo);

NV_STATUS nvUvmInterfacePmaAllocPages(void *pPma, NvLength pageCount, NvU64 pageSize,
                                      nvgpuPmaAllocationOptions_t pPmaAllocOptions, NvU64 *pPages);
NV_STATUS nvUvmInterfacePmaPinPages(void *pPma, NvU64 *pPages, NvLength pageCount, NvU64 pageSize,
                                    NvU32 flags);
void      nvUvmInterfacePmaFreePages(void *pPma, NvU64 *pPages, NvLength pageCount, NvU64 pageSize,
                                     NvU32 flags);

NV_STATUS nvUvmInterfaceP2pObjectCreate(nvgpuDeviceHandle_t device1, nvgpuDeviceHandle_t device2,
                                        NvHandle *hP2pObject);
void      nvUvmInterfaceP2pObjectDestroy(nvgpuSessionHandle_t session, NvHandle hP2pObject);
NV_STATUS nvUvmInterfaceGetP2PCaps(nvgpuDeviceHandle_t device1, nvgpuDeviceHandle_t device2,
                                   nvgpuP2PCapsParams_t p2pCapsParams);
NV_STATUS nvUvmInterfaceInitAccessCntrInfo(nvgpuDeviceHandle_t device, nvgpuAccessCntrInfo_t pAccessCntrInfo,
                                           NvU32 accessCntrIndex);
NV_STATUS nvUvmInterfaceDestroyAccessCntrInfo(nvgpuDeviceHandle_t device,
                                              nvgpuAccessCntrInfo_t pAccessCntrInfo);
NV_STATUS nvUvmInterfaceEnableAccessCntr(nvgpuDeviceHandle_t device, nvgpuAccessCntrInfo_t pAccessCntrInfo,
                                         const nvgpuAccessCntrConfig_t *pAccessCntrConfig);
NV_STATUS nvUvmInterfaceDisableAccessCntr(nvgpuDeviceHandle_t device, nvgpuAccessCntrInfo_t pAccessCntrInfo);
void      nvUvmInterfaceReportFatalError(NV_STATUS error);

/* ---- the RM gpu-ops entry points in nv-kernel.o (one per interface call) ---- */

NV_STATUS NV_API_CALL rm_gpu_ops_create_session(nvidia_stack_t *, nvgpuSessionHandle_t *);
NV_STATUS NV_API_CALL rm_gpu_ops_destroy_session(nvidia_stack_t *, nvgpuSessionHandle_t);
NV_STATUS NV_API_CALL rm_gpu_ops_device_create(nvidia_stack_t *, nvgpuSessionHandle_t, const nvgpuInfo_t *,
                                               const NvProcessorUuid *, nvgpuDeviceHandle_t *, NvBool);
NV_STATUS NV_API_CALL rm_gpu_ops_device_destroy(nvidia_stack_t *, nvgpuDeviceHandle_t);
NV_STATUS NV_API_CALL rm_gpu_ops_address_space_create(nvidia_stack_t *, nvgpuDeviceHandle_t, NvU64, NvU64,
                                                      NvU32, nvgpuAddressSpaceHandle_t *,
                                                      nvgpuAddressSpaceInfo_t);
NV_STATUS NV_API_CALL rm_gpu_ops_dup_address_space(nvidia_stack_t *, nvgpuDeviceHandle_t, NvHandle, NvHandle,
                                                   nvgpuAddressSpaceHandle_t *, nvgpuAddressSpaceInfo_t);
NV_STATUS NV_API_CALL rm_gpu_ops_address_space_destroy(nvidia_stack_t *, nvgpuAddressSpaceHandle_t);
NV_STATUS NV_API_CALL rm_gpu_ops_memory_alloc_fb(nvidia_stack_t *, nvgpuAddressSpaceHandle_t, NvLength, NvU64 *,
                                                 nvgpuAllocInfo_t);
NV_STATUS NV_API_CALL rm_gpu_ops_memory_alloc_sys(nvidia_stack_t *, nvgpuAddressSpaceHandle_t, NvLength, NvU64 *,
                                                  nvgpuAllocInfo_t);
NV_STATUS NV_API_CALL rm_gpu_ops_get_p2p_caps(nvidia_stack_t *, nvgpuDeviceHandle_t, nvgpuDeviceHandle_t,
                                              nvgpuP2PCapsParams_t);
NV_STATUS NV_API_CALL rm_gpu_ops_pma_register_callbacks(nvidia_stack_t *, void *, nvPmaEvictPagesCallback,
                                                        nvPmaEvictRangeCallback, void *);
void      NV_API_CALL rm_gpu_ops_pma_unregister_callbacks(nvidia_stack_t *, void *);
NV_STATUS NV_API_CALL rm_gpu_ops_get_pma_object(nvidia_stack_t *, nvgpuDeviceHandle_t, void **,
                                                const nvgpuPmaStatistics_t *);
NV_STATUS NV_API_CALL rm_gpu_ops_pma_alloc_pages(nvidia_stack_t *, void *, NvLength, NvU64,
                                                 nvgpuPmaAllocationOptions_t, NvU64 *);
NV_STATUS NV_API_CALL rm_gpu_ops_pma_pin_pages(nvidia_stack_t *, void *, NvU64 *, NvLength, NvU64, NvU32);
NV_STATUS NV_API_CALL rm_gpu_ops_pma_free_pages(nvidia_stack_t *, void *, NvU64 *, NvLength, NvU64, NvU32);
NV_STATUS NV_API_CALL rm_gpu_ops_memory_cpu_map(nvidia_stack_t *, nvgpuAddressSpaceHandle_t, NvU64, NvLength,
                                                void **, NvU64);
NV_STATUS NV_API_CALL rm_gpu_ops_memory_cpu_ummap(nvidia_stack_t *, nvgpuAddressSpaceHandle_t, void *);
NV_STATUS NV_API_CALL rm_gpu_ops_tsg_allocate(nvidia_stack_t *, nvgpuAddressSpaceHandle_t,
                                              const nvgpuTsgAllocParams_t *, nvgpuTsgHandle_t *);
NV_STATUS NV_API_CALL rm_gpu_ops_tsg_destroy(nvidia_stack_t *, nvgpuTsgHandle_t);
NV_STATUS NV_API_CALL rm_gpu_ops_channel_allocate(nvidia_stack_t *, const nvgpuTsgHandle_t,
                                                  const nvgpuChannelAllocParams_t *, nvgpuChannelHandle_t *,
                                                  nvgpuChannelInfo_t);
NV_STATUS NV_API_CALL rm_gpu_ops_channel_destroy(nvidia_stack_t *, nvgpuChannelHandle_t);
NV_STATUS NV_API_CALL rm_gpu_ops_memory_free(nvidia_stack_t *, nvgpuAddressSpaceHandle_t, NvU64);
NV_STATUS NV_API_CALL rm_gpu_ops_query_caps(nvidia_stack_t *, nvgpuDeviceHandle_t, nvgpuCaps_t);
NV_STATUS NV_API_CALL rm_gpu_ops_query_ces_caps(nvidia_stack_t *, nvgpuDeviceHandle_t, nvgpuCesCaps_t);
NV_STATUS NV_API_CALL rm_gpu_ops_get_gpu_info(nvidia_stack_t *, const NvProcessorUuid *,
                                              const nvgpuClientInfo_t *, nvgpuInfo_t *);
NV_STATUS NV_API_CALL rm_gpu_ops_service_device_interrupts_rm(nvidia_stack_t *, nvgpuDeviceHandle_t);
NV_STATUS NV_API_CALL rm_gpu_ops_set_page_directory(nvidia_stack_t *, nvgpuAddressSpaceHandle_t, NvU64, unsigned,
                                                    NvBool, NvU32, NvU64 *);
NV_STATUS NV_API_CALL rm_gpu_ops_unset_page_directory(nvidia_stack_t *, nvgpuAddressSpaceHandle_t);
NV_STATUS NV_API_CALL rm_gpu_ops_dup_allocation(nvidia_stack_t *, nvgpuAddressSpaceHandle_t, NvU64,
                                                nvgpuAddressSpaceHandle_t, NvU64, NvU64 *);
NV_STATUS NV_API_CALL rm_gpu_ops_dup_memory(nvidia_stack_t *, nvgpuDeviceHandle_t, NvHandle, NvHandle,
                                            NvHandle *, nvgpuMemoryInfo_t);
NV_STATUS NV_API_CALL rm_gpu_ops_free_duped_handle(nvidia_stack_t *, nvgpuDeviceHandle_t, NvHandle);
NV_STATUS NV_API_CALL rm_gpu_ops_get_fb_info(nvidia_stack_t *, nvgpuDeviceHandle_t, nvgpuFbInfo_t);
NV_STATUS NV_API_CALL rm_gpu_ops_get_ecc_info(nvidia_stack_t *, nvgpuDeviceHandle_t, nvgpuEccInfo_t);
NV_STATUS NV_API_CALL rm_gpu_ops_get_nvlink_info(nvidia_stack_t *, nvgpuDeviceHandle_t, nvgpuNvlinkInfo_t);
NV_STATUS NV_API_CALL rm_gpu_ops_own_page_fault_intr(nvidia_stack_t *, nvgpuDeviceHandle_t, NvBool);
NV_STATUS NV_API_CALL rm_gpu_ops_init_fault_info(nvidia_stack_t *, nvgpuDeviceHandle_t, nvgpuFaultInfo_t);
NV_STATUS NV_API_CALL rm_gpu_ops_destroy_fault_info(nvidia_stack_t *, nvgpuDeviceHandle_t, nvgpuFaultInfo_t);
NV_STATUS NV_API_CALL rm_gpu_ops_has_pending_non_replayable_faults(nvidia_stack_t *, nvgpuFaultInfo_t, NvBool *);
NV_STATUS NV_API_CALL rm_gpu_ops_get_non_replayable_faults(nvidia_stack_t *, nvgpuFaultInfo_t, void *, NvU32 *);
NV_STATUS NV_API_CALL rm_gpu_ops_flush_replayable_fault_buffer(nvidia_stack_t *, nvgpuFaultInfo_t, NvBool);
NV_STATUS NV_API_CALL rm_gpu_ops_toggle_prefetch_faults(nvidia_stack_t *, nvgpuFaultInfo_t, NvBool);
NV_STATUS NV_API_CALL rm_gpu_ops_init_access_cntr_info(nvidia_stack_t *, nvgpuDeviceHandle_t,
                                                       nvgpuAccessCntrInfo_t, NvU32);
NV_STATUS NV_API_CALL rm_gpu_ops_destroy_access_cntr_info(nvidia_stack_t *, nvgpuDeviceHandle_t,
                                                          nvgpuAccessCntrInfo_t);
NV_STATUS NV_API_CALL rm_gpu_ops_enable_access_cntr(nvidia_stack_t *, nvgpuDeviceHandle_t, nvgpuAccessCntrInfo_t,
                                                    nvgpuAccessCntrConfig_t *);
NV_STATUS NV_API_CALL rm_gpu_ops_disable_access_cntr(nvidia_stack_t *, nvgpuDeviceHandle_t, nvgpuAccessCntrInfo_t);
NV_STATUS NV_API_CALL rm_gpu_ops_p2p_object_create(nvidia_stack_t *, nvgpuDeviceHandle_t, nvgpuDeviceHandle_t,
                                                   NvHandle *);
void      NV_API_CALL rm_gpu_ops_p2p_object_destroy(nvidia_stack_t *, nvgpuSessionHandle_t, NvHandle);
NV_STATUS NV_API_CALL rm_gpu_ops_get_external_alloc_ptes(nvidia_stack_t *, nvgpuAddressSpaceHandle_t, NvHandle,
                                                         NvU64, NvU64, nvgpuExternalMappingInfo_t);
NV_STATUS NV_API_CALL rm_gpu_ops_retain_channel(nvidia_stack_t *, nvgpuAddressSpaceHandle_t, NvHandle, NvHandle,
                                                void **, nvgpuChannelInstanceInfo_t);
NV_STATUS NV_API_CALL rm_gpu_ops_bind_channel_resources(nvidia_stack_t *, void *,
                                                        nvgpuChannelResourceBindParams_t);
void      NV_API_CALL rm_gpu_ops_release_channel(nvidia_stack_t *, void *);
void      NV_API_CALL rm_gpu_ops_stop_channel(nvidia_stack_t *, void *, NvBool);
NV_STATUS NV_API_CALL rm_gpu_ops_get_channel_resource_ptes(nvidia_stack_t *, nvgpuAddressSpaceHandle_t, NvP64,
                                                           NvU64, NvU64, nvgpuExternalMappingInfo_t);
NV_STATUS NV_API_CALL rm_gpu_ops_report_non_replayable_fault(nvidia_stack_t *, nvgpuDeviceHandle_t, const void *);
void      NV_API_CALL rm_gpu_ops_report_fatal_error(nvidia_stack_t *, NV_STATUS);

#endif /* _NV_UVM_INTERFACE_H_ */

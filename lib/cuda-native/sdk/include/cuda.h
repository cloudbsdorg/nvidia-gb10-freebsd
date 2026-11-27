/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * <cuda.h> - cuda-native SDK: the clean-room Driver API subset implemented by
 * libcuda(3).  Numeric ABI values come from NVIDIA's public Driver API
 * reference, not from a CUDA toolkit header.
 */
#ifndef CUDA_NATIVE_CUDA_H_
#define CUDA_NATIVE_CUDA_H_

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* API level the headers follow: CUDA 13.0 (major * 1000 + minor * 10). */
#define CUDA_VERSION 13000

/* Our own release, major * 10000 + minor * 100 + patch: 0.1.0. */
#define CUDA_NATIVE_VERSION 100

/* Fixed-width integer types of the Driver API. */
typedef uint32_t cuuint32_t;
typedef uint64_t cuuint64_t;

typedef enum CUresult_enum {
	CUDA_SUCCESS = 0,
	CUDA_ERROR_INVALID_VALUE = 1,
	CUDA_ERROR_OUT_OF_MEMORY = 2,
	CUDA_ERROR_NOT_INITIALIZED = 3,
	CUDA_ERROR_DEINITIALIZED = 4,
	CUDA_ERROR_NO_DEVICE = 100,
	CUDA_ERROR_INVALID_DEVICE = 101,
	CUDA_ERROR_INVALID_CONTEXT = 201,
	CUDA_ERROR_NOT_FOUND = 500,
	CUDA_ERROR_NOT_SUPPORTED = 801,
	CUDA_ERROR_UNKNOWN = 999
} CUresult;

typedef int CUdevice;
typedef struct CUctx_st *CUcontext;

/* A device address: the address of an allocation in the GPU's address
 * space.  The value is the one the resource manager reserves for the
 * allocation; libcuda(3) says which one it is. */
typedef unsigned long long CUdeviceptr;

/* Flags of cuCtxCreate.  Only the automatic schedule is implemented: no
 * work is submitted by this library, so a schedule has nothing to
 * schedule, and a host mapping has nothing to map. */
typedef enum CUctx_flags_enum {
	CU_CTX_SCHED_AUTO = 0x00,
	CU_CTX_SCHED_SPIN = 0x01,
	CU_CTX_SCHED_YIELD = 0x02,
	CU_CTX_SCHED_BLOCKING_SYNC = 0x04,
	CU_CTX_MAP_HOST = 0x08,
	CU_CTX_LMEM_RESIZE_TO_MAX = 0x10,
	CU_CTX_COREDUMP_ENABLE = 0x20,
	CU_CTX_SYNC_MEMOPS = 0x40
} CUctx_flags;

/* Flags of cuMemHostAlloc.  Only zero is implemented: the memory handed
 * out is ordinary system memory, not write-combining and not
 * cache-mapped. */
#define CU_MEMHOSTALLOC_PORTABLE	0x01
#define CU_MEMHOSTALLOC_DEVICEMAP	0x02
#define CU_MEMHOSTALLOC_WRITECOMBINED	0x04
#define CU_MEMHOSTALLOC_CACHEMAPPED	0x08

typedef struct CUuuid_st {
	char bytes[16];
} CUuuid;

typedef enum CUdevice_attribute_enum {
	CU_DEVICE_ATTRIBUTE_MAX_THREADS_PER_BLOCK = 1,
	CU_DEVICE_ATTRIBUTE_MAX_SHARED_MEMORY_PER_BLOCK = 8,
	CU_DEVICE_ATTRIBUTE_WARP_SIZE = 10,
	CU_DEVICE_ATTRIBUTE_MULTIPROCESSOR_COUNT = 16,
	CU_DEVICE_ATTRIBUTE_INTEGRATED = 18,
	CU_DEVICE_ATTRIBUTE_PCI_BUS_ID = 33,
	CU_DEVICE_ATTRIBUTE_PCI_DEVICE_ID = 34,
	CU_DEVICE_ATTRIBUTE_PCI_DOMAIN_ID = 50,
	CU_DEVICE_ATTRIBUTE_COMPUTE_CAPABILITY_MAJOR = 75,
	CU_DEVICE_ATTRIBUTE_COMPUTE_CAPABILITY_MINOR = 76,
	CU_DEVICE_ATTRIBUTE_COOPERATIVE_LAUNCH = 95,
	CU_DEVICE_ATTRIBUTE_MAX_SHARED_MEMORY_PER_BLOCK_OPTIN = 97,
	CU_DEVICE_ATTRIBUTE_VIRTUAL_MEMORY_MANAGEMENT_SUPPORTED = 102
} CUdevice_attribute;

typedef enum CUdriverProcAddressQueryResult_enum {
	CU_GET_PROC_ADDRESS_SUCCESS = 0,
	CU_GET_PROC_ADDRESS_SYMBOL_NOT_FOUND = 1,
	CU_GET_PROC_ADDRESS_VERSION_NOT_SUFFICIENT = 2
} CUdriverProcAddressQueryResult;

typedef enum CUdriverProcAddress_flags_enum {
	CU_GET_PROC_ADDRESS_DEFAULT = 0,
	CU_GET_PROC_ADDRESS_LEGACY_STREAM = 1,
	CU_GET_PROC_ADDRESS_PER_THREAD_DEFAULT_STREAM = 2
} CUdriverProcAddress_flags;

CUresult cuInit(unsigned int flags);
CUresult cuDriverGetVersion(int *driverVersion);

CUresult cuDeviceGetCount(int *count);
CUresult cuDeviceGet(CUdevice *device, int ordinal);
CUresult cuDeviceGetName(char *name, int len, CUdevice dev);
CUresult cuDeviceGetUuid(CUuuid *uuid, CUdevice dev);
CUresult cuDeviceTotalMem(size_t *bytes, CUdevice dev);
CUresult cuDeviceGetAttribute(int *pi, CUdevice_attribute attrib, CUdevice dev);

CUresult cuDevicePrimaryCtxRetain(CUcontext *pctx, CUdevice dev);
CUresult cuDevicePrimaryCtxRelease(CUdevice dev);
CUresult cuCtxGetCurrent(CUcontext *pctx);
CUresult cuCtxSetCurrent(CUcontext ctx);
CUresult cuCtxGetDevice(CUdevice *device);
CUresult cuCtxCreate(CUcontext *pctx, unsigned int flags, CUdevice dev);
CUresult cuCtxDestroy(CUcontext ctx);

CUresult cuMemAlloc(CUdeviceptr *dptr, size_t bytesize);
CUresult cuMemFree(CUdeviceptr dptr);
CUresult cuMemAllocHost(void **pp, size_t bytesize);
CUresult cuMemHostAlloc(void **pp, size_t bytesize, unsigned int flags);
CUresult cuMemFreeHost(void *p);
CUresult cuMemcpyHtoD(CUdeviceptr dstDevice, const void *srcHost,
    size_t ByteCount);
CUresult cuMemcpyDtoH(void *dstHost, CUdeviceptr srcDevice, size_t ByteCount);
CUresult cuMemcpyDtoD(CUdeviceptr dstDevice, CUdeviceptr srcDevice,
    size_t ByteCount);
CUresult cuMemsetD8(CUdeviceptr dstDevice, unsigned char ui, size_t N);
CUresult cuMemsetD32(CUdeviceptr dstDevice, unsigned int ui, size_t N);
CUresult cuMemGetInfo(size_t *free, size_t *total);

CUresult cuGetErrorName(CUresult error, const char **pStr);
CUresult cuGetErrorString(CUresult error, const char **pStr);
CUresult cuGetProcAddress(const char *symbol, void **pfn, int cudaVersion,
    cuuint64_t flags);
CUresult cuGetProcAddress_v2(const char *symbol, void **pfn, int cudaVersion,
    cuuint64_t flags, CUdriverProcAddressQueryResult *symbolStatus);
#define cuGetProcAddress cuGetProcAddress_v2

/* Why the first initialization attempt of the process failed.  The reason is
 * one of the cuda-native extensions: it tells a caller what the library could
 * not do, so the caller does not have to guess from a generic error value.
 * The reason of an initialization that succeeded is CUDA_NATIVE_INIT_OK.
 * Before any initialization is attempted the reason is
 * CUDA_NATIVE_INIT_NOT_ATTEMPTED, which is not a success. */
typedef enum cudaNativeInitReason_enum {
	/* The initialization succeeded. */
	CUDA_NATIVE_INIT_OK = 0,
	/* The selected backend names no registered provider. */
	CUDA_NATIVE_INIT_UNKNOWN_PROVIDER,
	/* More devices are selected than the library exposes. */
	CUDA_NATIVE_INIT_DEVICE_LIMIT,
	/* The provider could not discover its devices. */
	CUDA_NATIVE_INIT_PROVIDER_UNSUPPORTED,
	/* The provider reports more devices than the registry holds. */
	CUDA_NATIVE_INIT_PROVIDER_DEVICE_LIMIT,
	/* The provider failed for another reason. */
	CUDA_NATIVE_INIT_PROVIDER_ERROR,
	/* No initialization was attempted yet.  The value is last so that
	 * the values before it keep their numbers. */
	CUDA_NATIVE_INIT_NOT_ATTEMPTED
} cudaNativeInitReason;

/* cuda-native extensions; these queries do not initialize a provider. */
const char *cudaNativeGetBackendName(void);
const char *cudaNativeDefaultBackend(void);
int cudaNativeProviderKnown(const char *name);
unsigned cudaNativeProviderCount(void);
const char *cudaNativeProviderName(unsigned index);
int cudaNativeProviderTakesFakeProfiles(const char *name);
const char *cudaNativeProviderInUse(void);
int cudaNativeProviderHint(const char *name, char *buffer, size_t size);
int cudaNativeFakeProfileKnown(const char *name, size_t length);
unsigned cudaNativeFakeProfileCount(void);
const char *cudaNativeFakeProfileName(unsigned index);
const char *cudaNativeFakeProfileDefault(void);
cudaNativeInitReason cudaNativeInitFailureReason(void);
/* The reason of the last failure of the calling thread that named one, or
 * an empty string when there is none.  The reason is per thread: a failure
 * in one thread never names the failure of another. */
const char *cudaNativeFailureReason(void);

#ifdef __cplusplus
}
#endif

#endif /* CUDA_NATIVE_CUDA_H_ */

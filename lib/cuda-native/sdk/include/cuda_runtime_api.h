/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * <cuda_runtime_api.h> - cuda-native SDK (Track #2380).  Runtime API
 * declarations for the native runtime in lib/libcudart (Track #2430).
 * These are the entry points a CUDA program calls; the runtime answers
 * each one from the Driver API of libcuda.  A call the driver cannot
 * make yet fails with cudaErrorNotSupported and names the reason; it
 * never reports a success it did not achieve.
 */
#ifndef CUDA_NATIVE_CUDA_RUNTIME_API_H_
#define CUDA_NATIVE_CUDA_RUNTIME_API_H_

#include <stddef.h>
#include <stdint.h>

#include "host_defines.h"
#include "driver_types.h"
#include "vector_types.h"

#if defined(__cplusplus)
extern "C" {
#endif

/*
 * The declarations carry no execution-space attribute: a function declared
 * without one is a host function, which is what every entry point here
 * is.  The runtime that implements them is plain C, and clang ignores the
 * host attribute outside its CUDA mode with a warning.
 */

/*
 * Launch func on a grid of gridDim blocks of blockDim threads, with args
 * the array of pointers to its parameters, sharedMem bytes of dynamic
 * shared memory, on stream (0: the default stream).  clang's host-side
 * stub for a <<<...>>> launch calls this.
 */
extern cudaError_t cudaLaunchKernel(const void *func, dim3 gridDim,
    dim3 blockDim, void **args, size_t sharedMem, cudaStream_t stream);

/* ---- devices ---- */

/* The number of devices the driver exposes to this process. */
extern cudaError_t cudaGetDeviceCount(int *count);
/* The device the calling thread works on. */
extern cudaError_t cudaGetDevice(int *device);
/* Make device the calling thread's device; its primary context is
 * retained and made current. */
extern cudaError_t cudaSetDevice(int device);
/* The properties of a device, as the driver reports them. */
extern cudaError_t cudaGetDeviceProperties(struct cudaDeviceProp *prop,
    int device);
/* Release the primary context the runtime retained for the calling
 * thread's device. */
extern cudaError_t cudaDeviceReset(void);
/* Wait for every work of the calling thread's device. */
extern cudaError_t cudaDeviceSynchronize(void);

/* ---- memory ---- */

extern cudaError_t cudaMalloc(void **ptr, size_t size);
extern cudaError_t cudaFree(void *ptr);
extern cudaError_t cudaMallocHost(void **ptr, size_t size);
extern cudaError_t cudaFreeHost(void *ptr);
extern cudaError_t cudaMemcpy(void *dst, const void *src,
    size_t count, cudaMemcpyKind kind);
extern cudaError_t cudaMemcpyAsync(void *dst, const void *src,
    size_t count, cudaMemcpyKind kind, cudaStream_t stream);
extern cudaError_t cudaMemset(void *dst, int value, size_t count);
extern cudaError_t cudaMemsetAsync(void *dst, int value,
    size_t count, cudaStream_t stream);

/* ---- streams and events ---- */

extern cudaError_t cudaStreamCreate(cudaStream_t *stream);
extern cudaError_t cudaStreamCreateWithFlags(cudaStream_t *stream,
    unsigned int flags);
extern cudaError_t cudaStreamDestroy(cudaStream_t stream);
extern cudaError_t cudaStreamSynchronize(cudaStream_t stream);
extern cudaError_t cudaStreamQuery(cudaStream_t stream);
extern cudaError_t cudaEventCreate(cudaEvent_t *event);
extern cudaError_t cudaEventCreateWithFlags(cudaEvent_t *event,
    unsigned int flags);
extern cudaError_t cudaEventDestroy(cudaEvent_t event);
extern cudaError_t cudaEventRecord(cudaEvent_t event,
    cudaStream_t stream);
extern cudaError_t cudaEventSynchronize(cudaEvent_t event);
extern cudaError_t cudaEventQuery(cudaEvent_t event);
extern cudaError_t cudaEventElapsedTime(float *ms, cudaEvent_t start,
    cudaEvent_t end);

/* ---- kernels ---- */

extern cudaError_t cudaFuncGetAttributes(
    struct cudaFuncAttributes *attr, const void *func);
extern cudaError_t cudaFuncSetAttribute(const void *func,
    enum cudaFuncAttribute attr, int value);
extern cudaError_t cudaOccupancyMaxActiveBlocksPerMultiprocessor(
    int *numBlocks, const void *func, int blockSize, size_t dynamicSMemSize);
extern cudaError_t cudaOccupancyMaxPotentialBlockSize(int *minGridSize,
    int *blockSize, const void *func, size_t dynamicSMemSize);

/* ---- errors and versions ---- */

extern cudaError_t cudaGetLastError(void);
extern cudaError_t cudaPeekAtLastError(void);
extern cudaError_t cudaGetErrorName(cudaError_t error,
    const char **name);
extern cudaError_t cudaGetErrorString(cudaError_t error,
    const char **string);
extern cudaError_t cudaRuntimeGetVersion(int *version);
extern cudaError_t cudaDriverGetVersion(int *version);

/* ---- the registration contract of clang's CUDA mode ---- */

/*
 * A fat binary is registered before any of its kernels is launched.  The
 * wrapper is the one clang's generated code passes; the handle is the
 * registration this runtime keeps.
 */
extern void **__cudaRegisterFatBinary(void *wrapper);
extern void __cudaRegisterFatBinaryEnd(void **handle);
extern void __cudaUnregisterFatBinary(void **handle);
/*
 * One kernel of a fat binary.  The host stub is the pointer a launch
 * names; the device name is the name the fat binary gives the kernel.
 * The runtime looks a launch up by the host stub.
 */
extern int __cudaRegisterFunction(void **handle, const void *hostFunc,
    const char *deviceFunc, const char *deviceName, int threadLimit,
    void *tid, void *bid, void *blockDim, void *gridDim, void *wordSize);
extern void __cudaRegisterVar(void **handle, void *hostVar,
    const char *deviceAddress, const char *deviceName, int external,
    size_t size, int constant, int global);
extern void __cudaRegisterManagedVar(void **handle, void *hostVar,
    const char *deviceAddress, const char *deviceName, size_t size,
    int flags);
extern void __cudaRegisterSurface(void **handle, void *hostVar,
    const char *deviceAddress, const char *deviceName, int external,
    int dim);
extern void __cudaRegisterTexture(void **handle, void *hostVar,
    const char *deviceAddress, const char *deviceName, int normalized,
    int external, int dim);

/* The configuration of the launch that follows, per thread. */
extern unsigned int __cudaPushCallConfiguration(dim3 gridDim, dim3 blockDim,
    size_t sharedMem, void *stream);
extern int __cudaPopCallConfiguration(dim3 *gridDim, dim3 *blockDim,
    size_t *sharedMem, void **stream);

/* ---- the cuda-native extensions of the runtime ---- */

/* The reason of the last failure of the calling thread, or null when the
 * thread has no failure to report.  The reason names what the runtime
 * could not do. */
extern const char *cudaNativeLastFailureReason(void);
/* The number of kernels the registration contract registered. */
extern unsigned cudaNativeKernelCount(void);
/* The device name of the registered kernel at the given index, written
 * whole or not at all. */
extern int cudaNativeKernelName(unsigned index, char *buffer, size_t size);
/* The device name of the kernel the given host stub belongs to, written
 * whole or not at all. */
extern int cudaNativeKernelHostStub(const void *hostStub, char *buffer,
    size_t size);
/* The number of fat binaries the registration contract registered. */
extern unsigned cudaNativeFatBinaryCount(void);
/* The number of members of the fat binary at the given index. */
extern int cudaNativeFatBinaryMembers(unsigned index, unsigned *members);
/* The release of the runtime: major * 10000 + minor * 100 + patch. */
extern int cudaNativeRuntimeVersion(void);
/* The same release as text. */
extern const char *cudaNativeRuntimeVersionString(void);

#if defined(__cplusplus)
}
#endif

#endif /* CUDA_NATIVE_CUDA_RUNTIME_API_H_ */

/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * <driver_types.h> - cuda-native SDK (Track #2380).  Runtime API types:
 * the error codes and the opaque stream and event handles.  Error values
 * are the numbers the public CUDA Runtime API reference documents.  The
 * list is the set of codes the native runtime knows: it names every one
 * of them and it returns the ones its entry points can report.
 */
#ifndef CUDA_NATIVE_DRIVER_TYPES_H_
#define CUDA_NATIVE_DRIVER_TYPES_H_

#include <stddef.h>
#include <stdint.h>

#include "host_defines.h"

enum cudaError {
	cudaSuccess = 0,
	cudaErrorInvalidValue = 1,
	cudaErrorMemoryAllocation = 2,
	cudaErrorInitializationError = 3,
	cudaErrorNoDevice = 100,
	cudaErrorInvalidDevice = 101,
	cudaErrorInvalidResourceHandle = 400,
	cudaErrorNotReady = 600,
	cudaErrorIllegalAddress = 700,
	cudaErrorInvalidPitchValue = 701,
	cudaErrorLaunchTimeout = 708,
	cudaErrorLaunchFailure = 719,
	cudaErrorNotSupported = 801,
	cudaErrorUnknown = 999
};
typedef enum cudaError cudaError_t;

/* The direction of a copy.  The values are the ones the public CUDA
 * Runtime API reference documents. */
enum cudaMemcpyKind {
	cudaMemcpyHostToHost = 0,
	cudaMemcpyHostToDevice = 1,
	cudaMemcpyDeviceToHost = 2,
	cudaMemcpyDeviceToDevice = 3,
	cudaMemcpyDefault = 4
};
typedef enum cudaMemcpyKind cudaMemcpyKind;

/* The flags a stream or an event is created with. */
enum cudaStreamFlags {
	cudaStreamDefault = 0,
	cudaStreamNonBlocking = 1
};
typedef enum cudaStreamFlags cudaStreamFlags;

enum cudaEventFlags {
	cudaEventDefault = 0,
	cudaEventBlockingSync = 1,
	cudaEventDisableTiming = 2
};
typedef enum cudaEventFlags cudaEventFlags;

/* The attributes of a kernel the runtime reports. */
enum cudaFuncAttribute {
	cudaFuncAttributeMaxDynamicSharedMemorySize = 8,
	cudaFuncAttributePreferredSharedMemoryCarveout = 9
};
typedef enum cudaFuncAttribute cudaFuncAttribute;

/*
 * The properties of a device.  The fields are the ones the public CUDA
 * Runtime API reference lists, in its order, up to the PCI identity; the
 * runtime fills the fields it can read from the driver and leaves the
 * others at zero.  A program that exchanges this structure with a program
 * built against another SDK must not: the structure is this SDK's.
 */
struct cudaDeviceProp {
	char name[256];
	size_t totalGlobalMem;
	size_t sharedMemPerBlock;
	int regsPerBlock;
	int warpSize;
	int maxThreadsPerBlock;
	int maxThreadsDim[3];
	int maxGridSize[3];
	int clockRate;
	size_t totalConstMem;
	int major;
	int minor;
	size_t textureAlignment;
	int deviceOverlap;
	int multiProcessorCount;
	int kernelExecTimeoutEnabled;
	int integrated;
	int canMapHostMemory;
	int canUseMapHostMemory;
	int computeMode;
	int concurrentKernels;
	int ECCEnabled;
	int luid;
	int luidDeviceNodeMask;
	int luidSameDeviceGroup;
	int pciBusID;
	int pciDeviceID;
	int pciDomainID;
};

/* What the runtime knows about one kernel. */
struct cudaFuncAttributes {
	size_t sharedSizeBytes;
	size_t constSizeBytes;
	int localSizeBytes;
	int maxThreadsPerBlock;
	int numRegs;
	size_t ptxVersion;
	char name[256];
	int64_t binaryVersion;
	int cacheModeCausal;
	int maxDynamicSharedSizeBytes;
	int preferredSharedMemoryCarveout;
};

/* Opaque handles. */
typedef struct CUstream_st *cudaStream_t;
typedef struct CUevent_st *cudaEvent_t;

/* Texture and surface objects are 64-bit handles. */
typedef unsigned long long cudaTextureObject_t;
typedef unsigned long long cudaSurfaceObject_t;

/* What a texture fetch returns, and what a surface access out of range does. */
enum cudaTextureReadMode {
	cudaReadModeElementType = 0,
	cudaReadModeNormalizedFloat = 1
};
enum cudaSurfaceBoundaryMode {
	cudaBoundaryModeZero = 0,
	cudaBoundaryModeClamp = 1,
	cudaBoundaryModeTrap = 2
};

#endif /* CUDA_NATIVE_DRIVER_TYPES_H_ */

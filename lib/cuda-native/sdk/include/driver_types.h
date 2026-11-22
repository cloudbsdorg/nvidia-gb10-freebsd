/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * <driver_types.h> - cuda-native SDK (Track #2380).  Runtime API types:
 * the error codes and the opaque stream and event handles.  Error values
 * are the numbers the public CUDA Runtime API reference documents.  The
 * full list arrives with libcudart (Track #2430).
 */
#ifndef CUDA_NATIVE_DRIVER_TYPES_H_
#define CUDA_NATIVE_DRIVER_TYPES_H_

#include "host_defines.h"

enum cudaError {
	cudaSuccess = 0,
	cudaErrorInvalidValue = 1,
	cudaErrorMemoryAllocation = 2,
	cudaErrorInitializationError = 3,
	cudaErrorNotSupported = 801
};
typedef enum cudaError cudaError_t;

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

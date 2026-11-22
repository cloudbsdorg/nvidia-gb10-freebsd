/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * <cuda_runtime_api.h> - cuda-native SDK (Track #2380).  Runtime API
 * declarations.  This release declares only what clang's kernel launch
 * lowering calls; libcudart (Track #2430) brings the rest.
 */
#ifndef CUDA_NATIVE_CUDA_RUNTIME_API_H_
#define CUDA_NATIVE_CUDA_RUNTIME_API_H_

#include <stddef.h>

#include "host_defines.h"
#include "driver_types.h"
#include "vector_types.h"

#if defined(__cplusplus)
extern "C" {
#endif

/*
 * Launch func on a grid of gridDim blocks of blockDim threads, with args
 * the array of pointers to its parameters, sharedMem bytes of dynamic
 * shared memory, on stream (0: the default stream).  clang's host-side
 * stub for a <<<...>>> launch calls this.
 */
extern __host__ cudaError_t cudaLaunchKernel(const void *func, dim3 gridDim,
    dim3 blockDim, void **args, size_t sharedMem, cudaStream_t stream);

#if defined(__cplusplus)
}
#endif

#endif /* CUDA_NATIVE_CUDA_RUNTIME_API_H_ */

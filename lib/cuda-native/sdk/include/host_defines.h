/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * <host_defines.h> - cuda-native SDK (Track #2380).  The CUDA C++ execution
 * space and memory space keywords, spelled as the clang attributes that
 * implement them.  clang's CUDA runtime wrapper includes this file by name.
 */
#ifndef CUDA_NATIVE_HOST_DEFINES_H_
#define CUDA_NATIVE_HOST_DEFINES_H_

#if !defined(__clang__)
#error "cuda-native headers are for clang's CUDA mode (clang -x cuda)"
#endif

/* Execution spaces. */
#define __host__ __attribute__((host))
#define __device__ __attribute__((device))
#define __global__ __attribute__((global))

/* Memory spaces. */
#define __shared__ __attribute__((shared))
#define __constant__ __attribute__((constant))
#define __managed__ __attribute__((managed))

/* Inlining and launch bounds. */
#define __forceinline__ __inline__ __attribute__((always_inline))
#define __noinline__ __attribute__((noinline))
#define __launch_bounds__(...) __attribute__((launch_bounds(__VA_ARGS__)))

/* Alignment and builtin-type markers. */
#define __align__(n) __attribute__((aligned(n)))
#define __builtin_align__(n) __align__(n)
#define __device_builtin__
#define __cudart_builtin__
#define __location__(a) __attribute__((a))

/* Restricted pointers in kernels. */
#define __restrict__ __restrict

#endif /* CUDA_NATIVE_HOST_DEFINES_H_ */

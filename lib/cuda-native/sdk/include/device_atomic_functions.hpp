/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * <device_atomic_functions.hpp> - cuda-native SDK (Track #2380).  The
 * user-facing atomicAdd overloads, on top of the __iAtomicAdd,
 * __uAtomicAdd and __fAtomicAdd helpers in clang's
 * __clang_cuda_device_functions.h.  The other atomics arrive in a
 * later release.
 */
#ifndef CUDA_NATIVE_DEVICE_ATOMIC_FUNCTIONS_HPP_
#define CUDA_NATIVE_DEVICE_ATOMIC_FUNCTIONS_HPP_

#if defined(__cplusplus) && defined(__CUDACC__)

static __inline__ __device__ int
atomicAdd(int *address, int val)
{
	return __iAtomicAdd(address, val);
}

static __inline__ __device__ unsigned int
atomicAdd(unsigned int *address, unsigned int val)
{
	return __uAtomicAdd(address, val);
}

static __inline__ __device__ float
atomicAdd(float *address, float val)
{
	return __fAtomicAdd(address, val);
}

#endif /* __cplusplus && __CUDACC__ */

#endif /* CUDA_NATIVE_DEVICE_ATOMIC_FUNCTIONS_HPP_ */

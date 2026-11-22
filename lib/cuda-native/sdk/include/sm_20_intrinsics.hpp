/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * <sm_20_intrinsics.hpp> - cuda-native SDK (Track #2380).  Included by name
 * by clang's CUDA runtime wrapper.  It holds the documented address space
 * conversions from a generic pointer to a state-space address
 * (__cvta_generic_to_global, _shared, _constant, _local), written as the
 * address-space casts clang lowers to cvta.  clang's wrapper supplies the
 * __isGlobal family itself.
 */
#ifndef CUDA_NATIVE_SM_20_INTRINSICS_HPP_
#define CUDA_NATIVE_SM_20_INTRINSICS_HPP_

#if defined(__cplusplus) && defined(__CUDACC__)

#include <stddef.h>

static __inline__ __device__ size_t
__cvta_generic_to_global(const void *p)
{
	return (size_t)(__attribute__((address_space(1))) const void *)p;
}

static __inline__ __device__ size_t
__cvta_generic_to_shared(const void *p)
{
	return (size_t)(__attribute__((address_space(3))) const void *)p;
}

static __inline__ __device__ size_t
__cvta_generic_to_constant(const void *p)
{
	return (size_t)(__attribute__((address_space(4))) const void *)p;
}

static __inline__ __device__ size_t
__cvta_generic_to_local(const void *p)
{
	return (size_t)(__attribute__((address_space(5))) const void *)p;
}

#endif /* __cplusplus && __CUDACC__ */

#endif /* CUDA_NATIVE_SM_20_INTRINSICS_HPP_ */

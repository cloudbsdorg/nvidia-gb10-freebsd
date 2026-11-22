/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * <cuda_native_host_math.h> - cuda-native SDK (Track #2380).  Host-side
 * declarations of the CUDA Math API functions that the C library lacks.
 * clang's CUDA runtime wrapper defines host overloads (rsqrt, rcbrt, sinpi,
 * cospi, sincospi, erfcinv, normcdfinv, normcdf, erfcx) that call them; the
 * device versions come from clang's __clang_cuda_math.h.  The host
 * definitions arrive with libcudart (Track #2430).
 */
#ifndef CUDA_NATIVE_HOST_MATH_H_
#define CUDA_NATIVE_HOST_MATH_H_

#include "host_defines.h"

#if defined(__cplusplus)
extern "C" {
#endif

extern __host__ float rsqrtf(float x);
extern __host__ float rcbrtf(float x);
extern __host__ float sinpif(float x);
extern __host__ float cospif(float x);
extern __host__ void sincospif(float x, float *s, float *c);
extern __host__ float erfcinvf(float x);
extern __host__ float normcdfinvf(float x);
extern __host__ float normcdff(float x);
extern __host__ float erfcxf(float x);

#if defined(__cplusplus)
}
#endif

#endif /* CUDA_NATIVE_HOST_MATH_H_ */

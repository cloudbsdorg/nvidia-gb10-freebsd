/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * <cuda.h> - cuda-native SDK (Track #2380).  The Driver API header.  This
 * release carries only the version macros and the fixed-width types; the
 * Driver API declarations arrive with libcuda (Track #2428).
 */
#ifndef CUDA_NATIVE_CUDA_H_
#define CUDA_NATIVE_CUDA_H_

#include <stdint.h>

/* API level the headers follow: CUDA 13.0 (major * 1000 + minor * 10). */
#define CUDA_VERSION 13000

/* Our own release, major * 10000 + minor * 100 + patch: 0.1.0. */
#define CUDA_NATIVE_VERSION 100

/* Fixed-width integer types of the Driver API. */
typedef uint32_t cuuint32_t;
typedef uint64_t cuuint64_t;

#endif /* CUDA_NATIVE_CUDA_H_ */

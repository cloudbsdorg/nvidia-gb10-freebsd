/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The internal state of the native CUDA runtime.  The runtime answers the
 * Runtime API from the Driver API of libcuda; the declarations here are the
 * state both parts share.
 */
#ifndef CUDART_INTERNAL_H_
#define CUDART_INTERNAL_H_

#include <stddef.h>

#include <cuda.h>
#include <cuda_runtime_api.h>

/* The number of devices the runtime keeps state for.  It is the limit the
 * driver registry holds, so the runtime never has more devices than the
 * driver exposes. */
#define CUDART_MAX_DEVICES 64

/* The fat binaries and the kernels the registration contract holds. */
#define CUDART_MAX_FATBINS 64
#define CUDART_MAX_KERNELS 1024

/* The release of the runtime, as numbers.  They come from the one macro
 * the driver header carries, so the text and the numbers cannot disagree. */
#define CUDART_VERSION_MAJOR (CUDA_NATIVE_VERSION / 10000)
#define CUDART_VERSION_MINOR ((CUDA_NATIVE_VERSION % 10000) / 100)
#define CUDART_VERSION_PATCH (CUDA_NATIVE_VERSION % 100)

/* The error of the calling thread, and the reason of it.  The reason names
 * what the runtime could not do; it is set with the error and read with
 * it. */
void cudart_error_set(cudaError_t error, const char *reason);
cudaError_t cudart_error_last(void);
cudaError_t cudart_error_peek(void);
const char *cudart_error_reason(void);

/* Record a failure and hand its code back to the caller. */
static inline cudaError_t
cudart_fail(cudaError_t error, const char *reason)
{
	cudart_error_set(error, reason);
	return (error);
}

/* The driver: initialized once per process. */
CUresult cudart_driver_init(void);
/* The driver, initialized, with the runtime's own error for a driver that
 * cannot start. */
cudaError_t cudart_driver_ready(void);
/* The number of devices the driver exposes. */
cudaError_t cudart_device_count(int *count);

/* The registration table of the clang registration contract. */
const char *cudart_kernel_lookup(const void *host_stub);
unsigned cudart_kernel_count(void);
int cudart_kernel_name_at(unsigned index, char *buffer, size_t size);

#endif

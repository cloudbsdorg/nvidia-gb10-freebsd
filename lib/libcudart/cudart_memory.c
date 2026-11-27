/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The memory of the runtime.  The device memory of a program is allocated
 * by the driver, and the driver cannot allocate any yet: every call that
 * needs the device says so.  A copy between two host addresses is made by
 * the runtime itself.
 */
#include <stddef.h>
#include <string.h>

#include "cudart_internal.h"

cudaError_t
cudaMalloc(void **ptr, size_t size)
{
	cudaError_t ready;

	if (ptr == NULL)
		return (cudart_fail(cudaErrorInvalidValue,
		    "the allocation output pointer is null"));
	ready = cudart_driver_ready();
	if (ready != cudaSuccess)
		return (ready);
	return (cudart_fail(cudaErrorNotSupported,
	    "libcuda has no cuMemAlloc yet; the runtime cannot allocate "
	    "memory on the device"));
}

cudaError_t
cudaFree(void *ptr)
{
	cudaError_t ready;

	if (ptr == NULL)
		return (cudaSuccess);
	ready = cudart_driver_ready();
	if (ready != cudaSuccess)
		return (ready);
	return (cudart_fail(cudaErrorNotSupported,
	    "libcuda has no cuMemFree yet; the runtime cannot release memory "
	    "on the device"));
}

cudaError_t
cudaMallocHost(void **ptr, size_t size)
{
	cudaError_t ready;

	if (ptr == NULL)
		return (cudart_fail(cudaErrorInvalidValue,
		    "the allocation output pointer is null"));
	ready = cudart_driver_ready();
	if (ready != cudaSuccess)
		return (ready);
	return (cudart_fail(cudaErrorNotSupported,
	    "libcuda has no cuMemHostAlloc yet; the runtime cannot allocate "
	    "pinned host memory"));
}

cudaError_t
cudaFreeHost(void *ptr)
{
	cudaError_t ready;

	if (ptr == NULL)
		return (cudaSuccess);
	ready = cudart_driver_ready();
	if (ready != cudaSuccess)
		return (ready);
	return (cudart_fail(cudaErrorNotSupported,
	    "libcuda has no cuMemHostFree yet; the runtime cannot release "
	    "pinned host memory"));
}

cudaError_t
cudaMemcpy(void *dst, const void *src, size_t count, cudaMemcpyKind kind)
{
	if (dst == NULL)
		return (cudart_fail(cudaErrorInvalidValue,
		    "the destination pointer is null"));
	if (src == NULL)
		return (cudart_fail(cudaErrorInvalidValue,
		    "the source pointer is null"));
	switch (kind) {
	case cudaMemcpyHostToHost:
		/* A copy between two host addresses is the runtime's own
		 * work; it needs no device and no driver. */
		if (count > 0)
			memcpy(dst, src, count);
		return (cudaSuccess);
	case cudaMemcpyHostToDevice:
		return (cudart_fail(cudaErrorNotSupported,
		    "libcuda has no cuMemcpyHtoD yet; the runtime cannot copy "
		    "to the device"));
	case cudaMemcpyDeviceToHost:
		return (cudart_fail(cudaErrorNotSupported,
		    "libcuda has no cuMemcpyDtoH yet; the runtime cannot copy "
		    "from the device"));
	case cudaMemcpyDeviceToDevice:
		return (cudart_fail(cudaErrorNotSupported,
		    "libcuda has no cuMemcpyDtoD yet; the runtime cannot copy "
		    "between addresses of the device"));
	case cudaMemcpyDefault:
		return (cudart_fail(cudaErrorNotSupported,
		    "libcuda has no cuMemcpyDefault yet; the runtime cannot "
		    "guess the direction of a copy"));
	default:
		return (cudart_fail(cudaErrorInvalidValue,
		    "the copy kind is not one the runtime knows"));
	}
}

cudaError_t
cudaMemcpyAsync(void *dst, const void *src, size_t count, cudaMemcpyKind kind,
    cudaStream_t stream)
{
	if (dst == NULL)
		return (cudart_fail(cudaErrorInvalidValue,
		    "the destination pointer is null"));
	if (src == NULL)
		return (cudart_fail(cudaErrorInvalidValue,
		    "the source pointer is null"));
	if (stream != NULL)
		return (cudart_fail(cudaErrorInvalidResourceHandle,
		    "the runtime holds no stream of its own; only the default "
		    "stream exists"));
	return (cudart_fail(cudaErrorNotSupported,
	    "libcuda has no cuMemcpyHtoDAsync or cuMemcpyDtoHAsync yet; the "
	    "runtime cannot copy on a stream"));
}

cudaError_t
cudaMemset(void *dst, int value, size_t count)
{
	cudaError_t ready;

	if (dst == NULL)
		return (cudart_fail(cudaErrorInvalidValue,
		    "the destination pointer is null"));
	ready = cudart_driver_ready();
	if (ready != cudaSuccess)
		return (ready);
	return (cudart_fail(cudaErrorNotSupported,
	    "libcuda has no cuMemsetD8 yet; the runtime cannot clear memory "
	    "on the device"));
}

cudaError_t
cudaMemsetAsync(void *dst, int value, size_t count, cudaStream_t stream)
{
	if (dst == NULL)
		return (cudart_fail(cudaErrorInvalidValue,
		    "the destination pointer is null"));
	if (stream != NULL)
		return (cudart_fail(cudaErrorInvalidResourceHandle,
		    "the runtime holds no stream of its own; only the default "
		    "stream exists"));
	return (cudart_fail(cudaErrorNotSupported,
	    "libcuda has no cuMemsetD8Async yet; the runtime cannot clear "
	    "memory on a stream"));
}

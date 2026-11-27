/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The contexts the caller creates and the memory they hold.  The shared code
 * owns the CUDA contract: which call needs what, which pointer belongs to
 * which allocation and what a failure means.  The provider owns the memory:
 * the nvrm provider asks the resource manager for it, the fake provider
 * makes its own.
 *
 * The copies are made by the CPU, through the mapping the provider made.
 * There is no copy engine and no work is submitted to the GPU.
 */
#include <stdlib.h>
#include <string.h>

#include "cuda_internal.h"

/* The context of the calling thread, or null when there is none. */
static struct CUctx_st *
current_context(void)
{
	return ((struct CUctx_st *)cuda_registry_current_get());
}

/* The memory backend of the device of a context, or null. */
static const cuda_mem_ops *
context_backend(const struct CUctx_st *context)
{
	if (context == NULL || context->device == NULL)
		return (NULL);
	return (context->device->provider->mem);
}

CUresult
cuCtxCreate(CUcontext *pctx, unsigned int flags, CUdevice dev)
{
	cuda_device *device;
	void *provider_context = NULL;
	CUresult result;

	if (pctx == NULL)
		return (CUDA_ERROR_INVALID_VALUE);
	/* No work is submitted, so a schedule has nothing to schedule and a
	 * host mapping has nothing to map: only the automatic schedule is
	 * implemented. */
	if (flags != CU_CTX_SCHED_AUTO) {
		cuda_reason_set("only the automatic schedule is implemented: this "
		    "library submits no work to the GPU");
		return (CUDA_ERROR_NOT_SUPPORTED);
	}
	result = cuda_registry_result();
	if (result != CUDA_SUCCESS)
		return (result);
	device = cuda_registry_get(dev);
	if (device == NULL)
		return (CUDA_ERROR_INVALID_DEVICE);
	/* The context gets its own RM client and its own device: the
	 * provider opens what the context needs. */
	if (device->provider->mem != NULL) {
		result = device->provider->mem->context_create(
		    device->physical_index, &provider_context);
		if (result != CUDA_SUCCESS)
			return (result);
	}
	result = cuda_registry_context_create(device, provider_context, pctx);
	if (result != CUDA_SUCCESS) {
		if (provider_context != NULL && device->provider->mem != NULL)
			(void)device->provider->mem->context_destroy(
			    provider_context);
		return (result);
	}
	return (CUDA_SUCCESS);
}

CUresult
cuCtxDestroy(CUcontext ctx)
{
	CUresult result;

	if (ctx == NULL)
		return (CUDA_ERROR_INVALID_VALUE);
	result = cuda_registry_result();
	if (result != CUDA_SUCCESS)
		return (result);
	return (cuda_registry_context_destroy(ctx));
}

/* The allocation of the calling thread's context that holds a device
 * address, or null when no allocation holds it. */
static cuda_allocation *
allocation_at(CUdeviceptr pointer)
{
	return (cuda_registry_find_at(pointer));
}

CUresult
cuMemAlloc(CUdeviceptr *dptr, size_t bytesize)
{
	struct CUctx_st *context;
	cuda_allocation *allocation;
	CUresult result;

	if (dptr == NULL)
		return (CUDA_ERROR_INVALID_VALUE);
	context = current_context();
	if (context == NULL)
		return (CUDA_ERROR_INVALID_CONTEXT);
	if (bytesize == 0)
		return (CUDA_ERROR_INVALID_VALUE);
	result = cuda_registry_allocate(context, 0, bytesize, &allocation);
	if (result != CUDA_SUCCESS)
		return (result);
	*dptr = allocation->device_ptr;
	return (CUDA_SUCCESS);
}

CUresult
cuMemFree(CUdeviceptr dptr)
{
	struct CUctx_st *context;
	cuda_allocation *allocation;
	CUresult result;

	context = current_context();
	if (context == NULL)
		return (CUDA_ERROR_INVALID_CONTEXT);
	allocation = cuda_registry_find(dptr);
	if (allocation == NULL) {
		cuda_reason_set("no allocation of this context has this address");
		return (CUDA_ERROR_INVALID_VALUE);
	}
	if (allocation->context != context) {
		cuda_reason_set("the allocation belongs to another context");
		return (CUDA_ERROR_INVALID_CONTEXT);
	}
	allocation = cuda_registry_take(dptr);
	if (allocation == NULL)
		return (CUDA_ERROR_INVALID_VALUE);
	result = CUDA_SUCCESS;
	cuda_registry_free_allocation(allocation);
	return (result);
}

CUresult
cuMemHostAlloc(void **pp, size_t bytesize, unsigned int flags)
{
	struct CUctx_st *context;
	cuda_allocation *allocation;
	CUresult result;

	if (pp == NULL)
		return (CUDA_ERROR_INVALID_VALUE);
	/* The memory handed out is ordinary system memory: it is neither
	 * write-combining nor cache-mapped, and it is not registered with
	 * the device. */
	if (flags != 0) {
		cuda_reason_set("the host memory is ordinary system memory: no "
		    "portable, device-mapped, write-combining or cache-mapped "
		    "host memory is implemented");
		return (CUDA_ERROR_NOT_SUPPORTED);
	}
	context = current_context();
	if (context == NULL)
		return (CUDA_ERROR_INVALID_CONTEXT);
	if (bytesize == 0)
		return (CUDA_ERROR_INVALID_VALUE);
	result = cuda_registry_allocate(context, 1, bytesize, &allocation);
	if (result != CUDA_SUCCESS)
		return (result);
	*pp = allocation->host_address;
	return (CUDA_SUCCESS);
}

CUresult
cuMemAllocHost(void **pp, size_t bytesize)
{
	return (cuMemHostAlloc(pp, bytesize, 0));
}

CUresult
cuMemFreeHost(void *p)
{
	struct CUctx_st *context;
	cuda_allocation *allocation;

	context = current_context();
	if (context == NULL)
		return (CUDA_ERROR_INVALID_CONTEXT);
	allocation = cuda_registry_find_host(p);
	if (allocation == NULL) {
		cuda_reason_set("no host allocation of this context has this "
		    "address");
		return (CUDA_ERROR_INVALID_VALUE);
	}
	if (allocation->context != context) {
		cuda_reason_set("the allocation belongs to another context");
		return (CUDA_ERROR_INVALID_CONTEXT);
	}
	allocation = cuda_registry_take(allocation->device_ptr);
	if (allocation == NULL)
		return (CUDA_ERROR_INVALID_VALUE);
	cuda_registry_free_allocation(allocation);
	return (CUDA_SUCCESS);
}

/* The allocation of the calling thread's context that holds a device
 * address.  The result is the reason of the failure when there is none. */
static cuda_allocation *
allocation_for(CUdeviceptr pointer, CUresult *result)
{
	struct CUctx_st *context;
	cuda_allocation *allocation;

	context = current_context();
	if (context == NULL) {
		*result = CUDA_ERROR_INVALID_CONTEXT;
		return (NULL);
	}
	allocation = allocation_at(pointer);
	if (allocation == NULL) {
		cuda_reason_set("no allocation of this context holds this "
		    "device address");
		*result = CUDA_ERROR_INVALID_VALUE;
		return (NULL);
	}
	if (allocation->context != context) {
		cuda_reason_set("the allocation belongs to another context");
		*result = CUDA_ERROR_INVALID_CONTEXT;
		return (NULL);
	}
	*result = CUDA_SUCCESS;
	return (allocation);
}

/* The copy of a range of one allocation into another, or out of one.  The
 * range must lie inside the allocation: a copy that runs over the end of
 * the memory is an invalid value and copies nothing. */
static CUresult
copy_range(cuda_allocation *allocation, uint64_t offset, void *buffer,
    size_t bytes, int write)
{
	const cuda_mem_ops *ops = context_backend(allocation->context);

	if (ops == NULL) {
		cuda_reason_set("the provider of this device has no memory "
		    "backend");
		return (CUDA_ERROR_NOT_SUPPORTED);
	}
	if (offset > allocation->bytes ||
	    bytes > allocation->bytes - offset)
		return (CUDA_ERROR_INVALID_VALUE);
	if (write)
		return (ops->write(allocation->object, offset, buffer, bytes));
	return (ops->read(allocation->object, offset, buffer, bytes));
}

CUresult
cuMemcpyHtoD(CUdeviceptr dstDevice, const void *srcHost, size_t ByteCount)
{
	cuda_allocation *allocation;
	CUresult result;

	if (srcHost == NULL)
		return (CUDA_ERROR_INVALID_VALUE);
	if (ByteCount == 0)
		return (CUDA_SUCCESS);
	allocation = allocation_for(dstDevice, &result);
	if (allocation == NULL)
		return (result);
	return (copy_range(allocation, (uint64_t)(dstDevice -
	    allocation->device_ptr), (void *)(uintptr_t)srcHost, ByteCount, 1));
}

CUresult
cuMemcpyDtoH(void *dstHost, CUdeviceptr srcDevice, size_t ByteCount)
{
	cuda_allocation *allocation;
	CUresult result;

	if (dstHost == NULL)
		return (CUDA_ERROR_INVALID_VALUE);
	if (ByteCount == 0)
		return (CUDA_SUCCESS);
	allocation = allocation_for(srcDevice, &result);
	if (allocation == NULL)
		return (result);
	return (copy_range(allocation, (uint64_t)(srcDevice -
	    allocation->device_ptr), dstHost, ByteCount, 0));
}

CUresult
cuMemcpyDtoD(CUdeviceptr dstDevice, CUdeviceptr srcDevice, size_t ByteCount)
{
	cuda_allocation *source, *destination;
	unsigned char *buffer;
	CUresult result;

	if (ByteCount == 0)
		return (CUDA_SUCCESS);
	source = allocation_for(srcDevice, &result);
	if (source == NULL)
		return (result);
	destination = allocation_for(dstDevice, &result);
	if (destination == NULL)
		return (result);
	buffer = malloc(ByteCount);
	if (buffer == NULL)
		return (CUDA_ERROR_OUT_OF_MEMORY);
	result = copy_range(source, (uint64_t)(srcDevice -
	    source->device_ptr), buffer, ByteCount, 0);
	if (result == CUDA_SUCCESS)
		result = copy_range(destination, (uint64_t)(dstDevice -
		    destination->device_ptr), buffer, ByteCount, 1);
	free(buffer);
	return (result);
}

/* Fill a range of an allocation with a pattern.  The pattern is written
 * through a buffer, so the fill is one write of the whole range. */
static CUresult
memset_range(cuda_allocation *allocation, uint64_t offset, unsigned char *byte,
    size_t bytes)
{
	const cuda_mem_ops *ops = context_backend(allocation->context);

	if (ops == NULL) {
		cuda_reason_set("the provider of this device has no memory "
		    "backend");
		return (CUDA_ERROR_NOT_SUPPORTED);
	}
	if (offset > allocation->bytes || bytes > allocation->bytes - offset)
		return (CUDA_ERROR_INVALID_VALUE);
	return (ops->write(allocation->object, offset, byte, bytes));
}

CUresult
cuMemsetD8(CUdeviceptr dstDevice, unsigned char ui, size_t N)
{
	cuda_allocation *allocation;
	unsigned char *buffer;
	CUresult result;

	if (N == 0)
		return (CUDA_SUCCESS);
	allocation = allocation_for(dstDevice, &result);
	if (allocation == NULL)
		return (result);
	buffer = malloc(N);
	if (buffer == NULL)
		return (CUDA_ERROR_OUT_OF_MEMORY);
	memset(buffer, ui, N);
	result = memset_range(allocation, (uint64_t)(dstDevice -
	    allocation->device_ptr), buffer, N);
	free(buffer);
	return (result);
}

CUresult
cuMemsetD32(CUdeviceptr dstDevice, unsigned int ui, size_t N)
{
	cuda_allocation *allocation;
	unsigned int *buffer;
	size_t bytes, i;
	CUresult result;

	/* The count is a count of 32-bit elements. */
	if (N > (size_t)-1 / sizeof(unsigned int))
		return (CUDA_ERROR_INVALID_VALUE);
	if (N == 0)
		return (CUDA_SUCCESS);
	bytes = N * sizeof(unsigned int);
	allocation = allocation_for(dstDevice, &result);
	if (allocation == NULL)
		return (result);
	buffer = malloc(bytes);
	if (buffer == NULL)
		return (CUDA_ERROR_OUT_OF_MEMORY);
	for (i = 0; i < N; i++)
		buffer[i] = ui;
	result = memset_range(allocation, (uint64_t)(dstDevice -
	    allocation->device_ptr), (unsigned char *)buffer, bytes);
	free(buffer);
	return (result);
}

CUresult
cuMemGetInfo(size_t *free, size_t *total)
{
	struct CUctx_st *context;
	const cuda_mem_ops *ops;

	if (free == NULL || total == NULL)
		return (CUDA_ERROR_INVALID_VALUE);
	context = current_context();
	if (context == NULL)
		return (CUDA_ERROR_INVALID_CONTEXT);
	ops = context_backend(context);
	if (ops == NULL || ops->info == NULL) {
		cuda_reason_set("the provider of this device has no memory "
		    "backend");
		return (CUDA_ERROR_NOT_SUPPORTED);
	}
	return (ops->info(context->provider_context, free, total));
}

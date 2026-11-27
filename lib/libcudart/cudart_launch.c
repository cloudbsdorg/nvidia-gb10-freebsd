/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The launches and the kernels of the runtime.  A launch is answered from
 * the registration contract: the host stub a launch names is looked up in
 * the table the registration filled.  The driver cannot load a module and
 * cannot launch a kernel yet, so the launch stops there and says so.
 */
#include <stddef.h>
#include <string.h>

#include "cudart_internal.h"

/* The lookup of a launch: the kernel the host stub names. */
static cudaError_t
kernel_lookup(const void *func, const char **name)
{
	const char *found = cudart_kernel_lookup(func);

	if (found == NULL)
		return (cudart_fail(cudaErrorInvalidResourceHandle,
		    "the host stub names no registered kernel; the runtime cannot "
		    "launch it"));
	*name = found;
	return (cudaSuccess);
}

cudaError_t
cudaLaunchKernel(const void *func, dim3 gridDim, dim3 blockDim, void **args,
    size_t sharedMem, cudaStream_t stream)
{
	const char *name = NULL;
	cudaError_t result;
	cudaError_t ready;

	if (func == NULL)
		return (cudart_fail(cudaErrorInvalidValue,
		    "the kernel pointer is null"));
	if (args == NULL)
		return (cudart_fail(cudaErrorInvalidValue,
		    "the array of the arguments is null"));
	if (stream != NULL)
		return (cudart_fail(cudaErrorInvalidResourceHandle,
		    "the runtime holds no stream of its own; only the default "
		    "stream exists"));
	ready = cudart_driver_ready();
	if (ready != cudaSuccess)
		return (ready);
	result = kernel_lookup(func, &name);
	if (result != cudaSuccess)
		return (result);
	(void)gridDim;
	(void)blockDim;
	(void)args;
	(void)sharedMem;
	(void)name;
	return (cudart_fail(cudaErrorNotSupported,
	    "libcuda has no cuModuleLoadData or cuLaunchKernel yet; the "
	    "runtime cannot launch the kernel"));
}

cudaError_t
cudaFuncGetAttributes(struct cudaFuncAttributes *attr, const void *func)
{
	const char *name = NULL;
	cudaError_t result;
	cudaError_t ready;

	if (attr == NULL)
		return (cudart_fail(cudaErrorInvalidValue,
		    "the attributes output pointer is null"));
	if (func == NULL)
		return (cudart_fail(cudaErrorInvalidValue,
		    "the kernel pointer is null"));
	ready = cudart_driver_ready();
	if (ready != cudaSuccess)
		return (ready);
	result = kernel_lookup(func, &name);
	if (result != cudaSuccess)
		return (result);
	(void)name;
	return (cudart_fail(cudaErrorNotSupported,
	    "libcuda has no cuFuncGetAttribute yet; the runtime cannot "
	    "describe the kernel"));
}

cudaError_t
cudaFuncSetAttribute(const void *func, enum cudaFuncAttribute attr,
    int value)
{
	const char *name = NULL;
	cudaError_t result;
	cudaError_t ready;

	if (func == NULL)
		return (cudart_fail(cudaErrorInvalidValue,
		    "the kernel pointer is null"));
	switch (attr) {
	case cudaFuncAttributeMaxDynamicSharedMemorySize:
	case cudaFuncAttributePreferredSharedMemoryCarveout:
		break;
	default:
		return (cudart_fail(cudaErrorInvalidValue,
		    "the function attribute is not one the runtime knows"));
	}
	ready = cudart_driver_ready();
	if (ready != cudaSuccess)
		return (ready);
	result = kernel_lookup(func, &name);
	if (result != cudaSuccess)
		return (result);
	(void)name;
	(void)value;
	return (cudart_fail(cudaErrorNotSupported,
	    "libcuda has no cuFuncSetAttribute yet; the runtime cannot set an "
	    "attribute of the kernel"));
}

cudaError_t
cudaOccupancyMaxActiveBlocksPerMultiprocessor(int *numBlocks,
    const void *func, int blockSize, size_t dynamicSMemSize)
{
	const char *name = NULL;
	cudaError_t result;
	cudaError_t ready;

	if (numBlocks == NULL)
		return (cudart_fail(cudaErrorInvalidValue,
		    "the block count output pointer is null"));
	if (func == NULL)
		return (cudart_fail(cudaErrorInvalidValue,
		    "the kernel pointer is null"));
	ready = cudart_driver_ready();
	if (ready != cudaSuccess)
		return (ready);
	result = kernel_lookup(func, &name);
	if (result != cudaSuccess)
		return (result);
	(void)name;
	(void)blockSize;
	(void)dynamicSMemSize;
	return (cudart_fail(cudaErrorNotSupported,
	    "libcuda has no cuOccupancyMaxActiveBlocksPerMultiprocessor yet; "
	    "the runtime cannot compute the occupancy of the kernel"));
}

cudaError_t
cudaOccupancyMaxPotentialBlockSize(int *minGridSize, int *blockSize,
    const void *func, size_t dynamicSMemSize)
{
	const char *name = NULL;
	cudaError_t result;
	cudaError_t ready;

	if (minGridSize == NULL || blockSize == NULL)
		return (cudart_fail(cudaErrorInvalidValue,
		    "the output pointer of the block size is null"));
	if (func == NULL)
		return (cudart_fail(cudaErrorInvalidValue,
		    "the kernel pointer is null"));
	ready = cudart_driver_ready();
	if (ready != cudaSuccess)
		return (ready);
	result = kernel_lookup(func, &name);
	if (result != cudaSuccess)
		return (result);
	(void)name;
	(void)dynamicSMemSize;
	return (cudart_fail(cudaErrorNotSupported,
	    "libcuda has no cuOccupancyMaxPotentialBlockSize yet; the runtime "
	    "cannot compute the occupancy of the kernel"));
}

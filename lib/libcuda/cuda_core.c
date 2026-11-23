/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 */
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "cuda_internal.h"

/* The implementation exports both the legacy and current symbol arities. */
#undef cuGetProcAddress

CUresult
cuInit(unsigned int flags)
{
	if (flags != 0)
		return (CUDA_ERROR_INVALID_VALUE);
	return (cuda_registry_initialize());
}

CUresult
cuDriverGetVersion(int *driverVersion)
{
	if (driverVersion == NULL)
		return (CUDA_ERROR_INVALID_VALUE);
	*driverVersion = CUDA_VERSION;
	return (CUDA_SUCCESS);
}

CUresult
cuDeviceGetCount(int *count)
{
	CUresult result;

	if (count == NULL)
		return (CUDA_ERROR_INVALID_VALUE);
	result = cuda_registry_result();
	if (result != CUDA_SUCCESS)
		return (result);
	*count = (int)cuda_registry_count();
	return (CUDA_SUCCESS);
}

CUresult
cuDeviceGet(CUdevice *device, int ordinal)
{
	CUresult result;

	if (device == NULL)
		return (CUDA_ERROR_INVALID_VALUE);
	result = cuda_registry_result();
	if (result != CUDA_SUCCESS)
		return (result);
	if (ordinal < 0 || (unsigned)ordinal >= cuda_registry_count())
		return (CUDA_ERROR_INVALID_DEVICE);
	*device = ordinal;
	return (CUDA_SUCCESS);
}

static CUresult
device_lookup(CUdevice dev, cuda_device **device)
{
	CUresult result;

	result = cuda_registry_result();
	if (result != CUDA_SUCCESS)
		return (result);
	*device = cuda_registry_get(dev);
	if (*device == NULL)
		return (CUDA_ERROR_INVALID_DEVICE);
	return (CUDA_SUCCESS);
}

CUresult
cuDeviceGetName(char *name, int len, CUdevice dev)
{
	CUresult result;
	cuda_device *device;

	if (name == NULL || len <= 0)
		return (CUDA_ERROR_INVALID_VALUE);
	result = device_lookup(dev, &device);
	if (result != CUDA_SUCCESS)
		return (result);
	return (device->provider->name(device->physical_index, name, len));
}

CUresult
cuDeviceGetUuid(CUuuid *uuid, CUdevice dev)
{
	CUresult result;
	cuda_device *device;

	if (uuid == NULL)
		return (CUDA_ERROR_INVALID_VALUE);
	result = device_lookup(dev, &device);
	if (result != CUDA_SUCCESS)
		return (result);
	return (device->provider->uuid(device->physical_index, uuid));
}

CUresult
cuDeviceTotalMem(size_t *bytes, CUdevice dev)
{
	CUresult result;
	cuda_device *device;

	if (bytes == NULL)
		return (CUDA_ERROR_INVALID_VALUE);
	result = device_lookup(dev, &device);
	if (result != CUDA_SUCCESS)
		return (result);
	return (device->provider->memory(device->physical_index, bytes));
}

CUresult
cuDeviceGetAttribute(int *pi, CUdevice_attribute attrib, CUdevice dev)
{
	CUresult result;
	cuda_device *device;

	if (pi == NULL)
		return (CUDA_ERROR_INVALID_VALUE);
	result = device_lookup(dev, &device);
	if (result != CUDA_SUCCESS)
		return (result);
	return (device->provider->attribute(device->physical_index, attrib, pi));
}

CUresult
cuDevicePrimaryCtxRetain(CUcontext *pctx, CUdevice dev)
{
	CUresult result;
	cuda_device *device;

	if (pctx == NULL)
		return (CUDA_ERROR_INVALID_VALUE);
	result = device_lookup(dev, &device);
	if (result != CUDA_SUCCESS)
		return (result);
	return (cuda_registry_primary_retain(pctx, device));
}

CUresult
cuDevicePrimaryCtxRelease(CUdevice dev)
{
	CUresult result;
	cuda_device *device;

	result = device_lookup(dev, &device);
	if (result != CUDA_SUCCESS)
		return (result);
	return (cuda_registry_primary_release(device));
}

CUresult
cuCtxGetCurrent(CUcontext *pctx)
{
	CUresult result;

	if (pctx == NULL)
		return (CUDA_ERROR_INVALID_VALUE);
	result = cuda_registry_result();
	if (result != CUDA_SUCCESS)
		return (result);
	*pctx = cuda_registry_current_get();
	return (CUDA_SUCCESS);
}

CUresult
cuCtxSetCurrent(CUcontext ctx)
{
	CUresult result;

	result = cuda_registry_result();
	if (result != CUDA_SUCCESS)
		return (result);
	return (cuda_registry_current_set(ctx));
}

CUresult
cuCtxGetDevice(CUdevice *device)
{
	CUresult result;
	CUcontext current;
	cuda_device *physical;

	if (device == NULL)
		return (CUDA_ERROR_INVALID_VALUE);
	result = cuda_registry_result();
	if (result != CUDA_SUCCESS)
		return (result);
	current = cuda_registry_current_get();
	if (current == NULL || current->device == NULL)
		return (CUDA_ERROR_INVALID_CONTEXT);
	physical = current->device;
	*device = cuda_registry_ordinal(physical);
	return (*device >= 0 ? CUDA_SUCCESS : CUDA_ERROR_INVALID_DEVICE);
}

typedef struct proc_export {
	const char *name;
	void *address;
	void *legacy_address;
	int legacy_until;
} proc_export;

#define PROC_ENTRY(function) \
	{ #function, (void *)&function, NULL, 0 }

/* This table describes the CUDA 13.0 subset, not historical introductions. */
static const proc_export proc_exports[] = {
#include "cuda_exports.inc"
};

static CUresult
proc_lookup(const char *symbol, void **pfn, int cudaVersion,
    cuuint64_t flags, CUdriverProcAddressQueryResult *symbolStatus)
{
	size_t i;

	if (pfn != NULL)
		*pfn = NULL;
	if (symbolStatus != NULL)
		*symbolStatus = CU_GET_PROC_ADDRESS_SYMBOL_NOT_FOUND;
	if (symbol == NULL || pfn == NULL || symbolStatus == NULL ||
	    cudaVersion < 0 ||
	    (flags & ~(cuuint64_t)(CU_GET_PROC_ADDRESS_LEGACY_STREAM |
	    CU_GET_PROC_ADDRESS_PER_THREAD_DEFAULT_STREAM)) != 0)
		return (CUDA_ERROR_INVALID_VALUE);
	if (cudaVersion > CUDA_VERSION) {
		*symbolStatus = CU_GET_PROC_ADDRESS_VERSION_NOT_SUFFICIENT;
		return (CUDA_ERROR_INVALID_VALUE);
	}
	/* Time: O(exports * symbol length); Space: O(1). */
	for (i = 0; i < sizeof(proc_exports) / sizeof(proc_exports[0]); i++) {
		if (strcmp(symbol, proc_exports[i].name) != 0)
			continue;
		if (proc_exports[i].legacy_address != NULL &&
		    cudaVersion < proc_exports[i].legacy_until)
			*pfn = proc_exports[i].legacy_address;
		else
			*pfn = proc_exports[i].address;
		*symbolStatus = CU_GET_PROC_ADDRESS_SUCCESS;
		return (CUDA_SUCCESS);
	}
	return (CUDA_ERROR_NOT_FOUND);
}

CUresult
cuGetProcAddress(const char *symbol, void **pfn, int cudaVersion,
    cuuint64_t flags)
{
	CUdriverProcAddressQueryResult status;

	return (proc_lookup(symbol, pfn, cudaVersion, flags, &status));
}

CUresult
cuGetProcAddress_v2(const char *symbol, void **pfn, int cudaVersion,
    cuuint64_t flags, CUdriverProcAddressQueryResult *symbolStatus)
{
	CUdriverProcAddressQueryResult status;

	if (symbolStatus == NULL)
		symbolStatus = &status;
	return (proc_lookup(symbol, pfn, cudaVersion, flags, symbolStatus));
}

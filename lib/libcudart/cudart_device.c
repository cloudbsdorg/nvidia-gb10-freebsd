/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The devices of the runtime.  The runtime keeps one primary context per
 * device, the one the driver holds for it, and makes it the current
 * context of the calling thread.
 */
#include <pthread.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>

#include "cudart_internal.h"

/* The primary context the runtime holds for a device, and whether it holds
 * it at all.  The context belongs to the device, not to a thread: the
 * current context is per thread, the retained context is per device. */
struct device_state {
	CUcontext context;
	int retained;
};

static struct device_state devices[CUDART_MAX_DEVICES];
static pthread_mutex_t devices_lock = PTHREAD_MUTEX_INITIALIZER;
/* The device of the calling thread.  It is -1 until the thread names one;
 * the first device is the default of a thread that has not named one. */
static _Thread_local int thread_device = -1;

/* The reason of the initialization of the driver. */
static const char *driver_reason;
static CUresult driver_result;

/* The runtime's code for a driver code. */
static cudaError_t
driver_error(CUresult result)
{
	switch (result) {
	case CUDA_SUCCESS:
		return (cudaSuccess);
	case CUDA_ERROR_INVALID_VALUE:
		return (cudaErrorInvalidValue);
	case CUDA_ERROR_OUT_OF_MEMORY:
		return (cudaErrorMemoryAllocation);
	case CUDA_ERROR_NOT_INITIALIZED:
		return (cudaErrorInitializationError);
	case CUDA_ERROR_NO_DEVICE:
		return (cudaErrorNoDevice);
	case CUDA_ERROR_INVALID_DEVICE:
		return (cudaErrorInvalidDevice);
	case CUDA_ERROR_INVALID_CONTEXT:
		return (cudaErrorInvalidResourceHandle);
	case CUDA_ERROR_NOT_SUPPORTED:
		return (cudaErrorNotSupported);
	default:
		return (cudaErrorUnknown);
	}
}

/* The body of the one-time initialization of the driver. */
static void
driver_initialize_once(void)
{
	driver_result = cuInit(0);
	switch (driver_result) {
	case CUDA_SUCCESS:
		driver_reason = NULL;
		break;
	case CUDA_ERROR_NOT_SUPPORTED:
		driver_reason =
		    "the provider of the driver does not implement its discovery";
		break;
	case CUDA_ERROR_INVALID_VALUE:
		driver_reason =
		    "the selected backend names no provider of the driver";
		break;
	default:
		driver_reason = "the driver did not initialize";
		break;
	}
}

CUresult
cudart_driver_init(void)
{
	static pthread_once_t once = PTHREAD_ONCE_INIT;

	/* Time: O(1) after the first call; Space: O(1). */
	(void)pthread_once(&once, driver_initialize_once);
	return (driver_result);
}

cudaError_t
cudart_driver_ready(void)
{
	CUresult result = cudart_driver_init();
	char advice[256];
	const char *provider;

	if (result == CUDA_SUCCESS)
		return (cudaSuccess);
	/* The advice of the driver names the provider that is in use and
	 * the one to use instead; it is the advice of the library that
	 * holds the providers, so the runtime does not name them itself. */
	provider = cudaNativeProviderInUse();
	if (provider != NULL &&
	    cudaNativeProviderHint(provider, advice, sizeof(advice)) != 0)
		return (cudart_fail(driver_error(result), advice));
	return (cudart_fail(driver_error(result),
	    driver_reason != NULL ? driver_reason :
	    "the driver did not initialize"));
}

cudaError_t
cudart_device_count(int *count)
{
	CUresult result;

	result = cudart_driver_init();
	if (result != CUDA_SUCCESS)
		return (cudart_driver_ready());
	result = cuDeviceGetCount(count);
	if (result != CUDA_SUCCESS)
		return (cudart_fail(driver_error(result),
		    "the driver did not report its devices"));
	return (cudaSuccess);
}

/* Make the device the current device of the calling thread.  The primary
 * context of the device is retained once, by the runtime, and released by
 * cudaDeviceReset. */
static cudaError_t
device_select(int device)
{
	CUresult result;
	CUcontext context = NULL;
	int count = 0;
	cudaError_t status;

	status = cudart_device_count(&count);
	if (status != cudaSuccess)
		return (status);
	if (device < 0 || device >= count)
		return (cudart_fail(cudaErrorInvalidDevice,
		    "the device ordinal is outside the devices the driver exposes"));

	pthread_mutex_lock(&devices_lock);
	if (!devices[device].retained) {
		result = cuDevicePrimaryCtxRetain(&context, device);
		if (result != CUDA_SUCCESS) {
			pthread_mutex_unlock(&devices_lock);
			return (cudart_fail(driver_error(result),
			    "the driver refused the primary context of the device"));
		}
		devices[device].context = context;
		devices[device].retained = 1;
	}
	context = devices[device].context;
	pthread_mutex_unlock(&devices_lock);

	result = cuCtxSetCurrent(context);
	if (result != CUDA_SUCCESS)
		return (cudart_fail(driver_error(result),
		    "the driver refused the current context of the device"));
	thread_device = device;
	return (cudaSuccess);
}

cudaError_t
cudaGetDeviceCount(int *count)
{
	if (count == NULL)
		return (cudart_fail(cudaErrorInvalidValue,
		    "the device count output pointer is null"));
	return (cudart_device_count(count));
}

cudaError_t
cudaGetDevice(int *device)
{
	int count = 0;
	cudaError_t result;

	if (device == NULL)
		return (cudart_fail(cudaErrorInvalidValue,
		    "the device output pointer is null"));
	result = cudart_device_count(&count);
	if (result != cudaSuccess)
		return (result);
	if (count == 0)
		return (cudart_fail(cudaErrorNoDevice,
		    "the driver exposes no device to this process"));
	if (thread_device < 0) {
		/* The first device is the default device of a thread that
		 * has not named one. */
		result = device_select(0);
		if (result != cudaSuccess)
			return (result);
	}
	*device = thread_device;
	return (cudaSuccess);
}

cudaError_t
cudaSetDevice(int device)
{
	return (device_select(device));
}

cudaError_t
cudaGetDeviceProperties(struct cudaDeviceProp *prop, int device)
{
	CUresult result;
	cudaError_t status;
	int count = 0;
	int value;

	if (prop == NULL)
		return (cudart_fail(cudaErrorInvalidValue,
		    "the properties output pointer is null"));
	status = cudart_device_count(&count);
	if (status != cudaSuccess)
		return (status);
	if (device < 0 || device >= count)
		return (cudart_fail(cudaErrorInvalidDevice,
		    "the device ordinal is outside the devices the driver exposes"));

	memset(prop, 0, sizeof(*prop));
	result = cuDeviceGetName(prop->name, (int)sizeof(prop->name), device);
	if (result != CUDA_SUCCESS)
		return (cudart_fail(driver_error(result),
		    "the driver did not report the name of the device"));
	result = cuDeviceTotalMem(&prop->totalGlobalMem, device);
	if (result != CUDA_SUCCESS)
		return (cudart_fail(driver_error(result),
		    "the driver did not report the memory of the device"));

	/* The attributes the driver does not know stay at zero; the
	 * runtime reports the device it can describe. */
#define CUDART_ATTRIBUTE(field, attribute) do {				\
	value = 0;							\
	result = cuDeviceGetAttribute(&value, (attribute), device);	\
	if (result == CUDA_SUCCESS)					\
		prop->field = value;					\
	else if (result != CUDA_ERROR_NOT_SUPPORTED)			\
		return (cudart_fail(driver_error(result),		\
		    "the driver did not report an attribute of the device")); \
} while (0)
	CUDART_ATTRIBUTE(sharedMemPerBlock,
	    CU_DEVICE_ATTRIBUTE_MAX_SHARED_MEMORY_PER_BLOCK);
	CUDART_ATTRIBUTE(maxThreadsPerBlock,
	    CU_DEVICE_ATTRIBUTE_MAX_THREADS_PER_BLOCK);
	CUDART_ATTRIBUTE(warpSize, CU_DEVICE_ATTRIBUTE_WARP_SIZE);
	CUDART_ATTRIBUTE(multiProcessorCount,
	    CU_DEVICE_ATTRIBUTE_MULTIPROCESSOR_COUNT);
	CUDART_ATTRIBUTE(integrated, CU_DEVICE_ATTRIBUTE_INTEGRATED);
	CUDART_ATTRIBUTE(major, CU_DEVICE_ATTRIBUTE_COMPUTE_CAPABILITY_MAJOR);
	CUDART_ATTRIBUTE(minor, CU_DEVICE_ATTRIBUTE_COMPUTE_CAPABILITY_MINOR);
	CUDART_ATTRIBUTE(pciBusID, CU_DEVICE_ATTRIBUTE_PCI_BUS_ID);
	CUDART_ATTRIBUTE(pciDeviceID, CU_DEVICE_ATTRIBUTE_PCI_DEVICE_ID);
	CUDART_ATTRIBUTE(pciDomainID, CU_DEVICE_ATTRIBUTE_PCI_DOMAIN_ID);
#undef CUDART_ATTRIBUTE
	return (cudaSuccess);
}

cudaError_t
cudaDeviceReset(void)
{
	CUcontext context = NULL;
	CUresult result;
	int device = thread_device;

	if (device < 0)
		return (cudaSuccess);
	pthread_mutex_lock(&devices_lock);
	if (devices[device].retained) {
		context = devices[device].context;
		devices[device].retained = 0;
		devices[device].context = NULL;
	}
	pthread_mutex_unlock(&devices_lock);
	if (context == NULL)
		return (cudaSuccess);
	result = cuDevicePrimaryCtxRelease(device);
	if (result != CUDA_SUCCESS)
		return (cudart_fail(driver_error(result),
		    "the driver refused the release of the primary context"));
	thread_device = -1;
	return (cudaSuccess);
}

cudaError_t
cudaRuntimeGetVersion(int *version)
{
	if (version == NULL)
		return (cudart_fail(cudaErrorInvalidValue,
		    "the version output pointer is null"));
	/* The API level the headers follow, in the form the reference
	 * documents: major * 1000 + minor * 10. */
	*version = CUDA_VERSION;
	return (cudaSuccess);
}

cudaError_t
cudaDriverGetVersion(int *version)
{
	CUresult result;
	cudaError_t ready;

	if (version == NULL)
		return (cudart_fail(cudaErrorInvalidValue,
		    "the version output pointer is null"));
	ready = cudart_driver_ready();
	if (ready != cudaSuccess)
		return (ready);
	result = cuDriverGetVersion(version);
	if (result != CUDA_SUCCESS)
		return (cudart_fail(driver_error(result),
		    "the driver did not report its version"));
	return (cudaSuccess);
}

int
cudaNativeRuntimeVersion(void)
{
	/* The release of the runtime: major * 10000 + minor * 100 + patch. */
	return (CUDA_NATIVE_VERSION);
}

/* The text of the release, built once from the one macro the driver
 * header carries: the text and the numbers cannot disagree. */
static char version_text[32];
static pthread_once_t version_once = PTHREAD_ONCE_INIT;

static void
version_text_build(void)
{
	(void)snprintf(version_text, sizeof(version_text), "%d.%d.%d",
	    CUDART_VERSION_MAJOR, CUDART_VERSION_MINOR, CUDART_VERSION_PATCH);
}

const char *
cudaNativeRuntimeVersionString(void)
{
	(void)pthread_once(&version_once, version_text_build);
	return (version_text);
}

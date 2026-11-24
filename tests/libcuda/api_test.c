/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 */
#include <dlfcn.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

#include <cuda.h>
#include "t.h"

static const unsigned char gb206_uuid[16] = {
	0xcb, 0x14, 0xa0, 0x00, 0x00, 0x00, 0x40, 0x00,
	0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01
};
static const unsigned char gb10_uuid[16] = {
	0xcb, 0x14, 0xa0, 0x00, 0x00, 0x00, 0x40, 0x00,
	0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02
};

static void
check_abi_values(void)
{
	CHECK_EQ(CUDA_VERSION, 13000);
	CHECK_EQ(CUDA_NATIVE_VERSION, 100);
	CHECK_EQ(CUDA_SUCCESS, 0);
	CHECK_EQ(CUDA_ERROR_INVALID_VALUE, 1);
	CHECK_EQ(CUDA_ERROR_OUT_OF_MEMORY, 2);
	CHECK_EQ(CUDA_ERROR_NOT_INITIALIZED, 3);
	CHECK_EQ(CUDA_ERROR_DEINITIALIZED, 4);
	CHECK_EQ(CUDA_ERROR_NO_DEVICE, 100);
	CHECK_EQ(CUDA_ERROR_INVALID_DEVICE, 101);
	CHECK_EQ(CUDA_ERROR_INVALID_CONTEXT, 201);
	CHECK_EQ(CUDA_ERROR_NOT_FOUND, 500);
	CHECK_EQ(CUDA_ERROR_NOT_SUPPORTED, 801);
	CHECK_EQ(CUDA_ERROR_UNKNOWN, 999);
	CHECK_EQ(CU_DEVICE_ATTRIBUTE_MAX_THREADS_PER_BLOCK, 1);
	CHECK_EQ(CU_DEVICE_ATTRIBUTE_MAX_SHARED_MEMORY_PER_BLOCK, 8);
	CHECK_EQ(CU_DEVICE_ATTRIBUTE_WARP_SIZE, 10);
	CHECK_EQ(CU_DEVICE_ATTRIBUTE_MULTIPROCESSOR_COUNT, 16);
	CHECK_EQ(CU_DEVICE_ATTRIBUTE_INTEGRATED, 18);
	CHECK_EQ(CU_DEVICE_ATTRIBUTE_PCI_BUS_ID, 33);
	CHECK_EQ(CU_DEVICE_ATTRIBUTE_PCI_DEVICE_ID, 34);
	CHECK_EQ(CU_DEVICE_ATTRIBUTE_PCI_DOMAIN_ID, 50);
	CHECK_EQ(CU_DEVICE_ATTRIBUTE_COMPUTE_CAPABILITY_MAJOR, 75);
	CHECK_EQ(CU_DEVICE_ATTRIBUTE_COMPUTE_CAPABILITY_MINOR, 76);
	CHECK_EQ(CU_DEVICE_ATTRIBUTE_COOPERATIVE_LAUNCH, 95);
	CHECK_EQ(CU_DEVICE_ATTRIBUTE_MAX_SHARED_MEMORY_PER_BLOCK_OPTIN, 97);
	CHECK_EQ(CU_DEVICE_ATTRIBUTE_VIRTUAL_MEMORY_MANAGEMENT_SUPPORTED, 102);
	CHECK_EQ(CU_GET_PROC_ADDRESS_SUCCESS, 0);
	CHECK_EQ(CU_GET_PROC_ADDRESS_SYMBOL_NOT_FOUND, 1);
	CHECK_EQ(CU_GET_PROC_ADDRESS_VERSION_NOT_SUFFICIENT, 2);
	CHECK_EQ(CU_GET_PROC_ADDRESS_DEFAULT, 0);
	CHECK_EQ(CU_GET_PROC_ADDRESS_LEGACY_STREAM, 1);
	CHECK_EQ(CU_GET_PROC_ADDRESS_PER_THREAD_DEFAULT_STREAM, 2);
	CHECK_EQ(sizeof(CUuuid), 16);
}

static void
check_attribute(CUdevice dev, CUdevice_attribute attribute, int expected)
{
	int value = -777;

	CHECK_EQ(cuDeviceGetAttribute(&value, attribute, dev), CUDA_SUCCESS);
	CHECK_EQ(value, expected);
}

static void
check_error_api(void)
{
	static const CUresult errors[] = {
		CUDA_SUCCESS, CUDA_ERROR_INVALID_VALUE, CUDA_ERROR_OUT_OF_MEMORY,
		CUDA_ERROR_NOT_INITIALIZED, CUDA_ERROR_DEINITIALIZED,
		CUDA_ERROR_NO_DEVICE, CUDA_ERROR_INVALID_DEVICE,
		CUDA_ERROR_INVALID_CONTEXT, CUDA_ERROR_NOT_FOUND,
		CUDA_ERROR_NOT_SUPPORTED, CUDA_ERROR_UNKNOWN
	};
	static const char *const names[] = {
		"CUDA_SUCCESS", "CUDA_ERROR_INVALID_VALUE",
		"CUDA_ERROR_OUT_OF_MEMORY", "CUDA_ERROR_NOT_INITIALIZED",
		"CUDA_ERROR_DEINITIALIZED", "CUDA_ERROR_NO_DEVICE",
		"CUDA_ERROR_INVALID_DEVICE", "CUDA_ERROR_INVALID_CONTEXT",
		"CUDA_ERROR_NOT_FOUND", "CUDA_ERROR_NOT_SUPPORTED",
		"CUDA_ERROR_UNKNOWN"
	};
	const char *text;
	size_t i;

	for (i = 0; i < sizeof(errors) / sizeof(errors[0]); i++) {
		text = NULL;
		CHECK_EQ(cuGetErrorName(errors[i], &text), CUDA_SUCCESS);
		CHECK_STR(text, names[i]);
		text = NULL;
		CHECK_EQ(cuGetErrorString(errors[i], &text), CUDA_SUCCESS);
		CHECK(text != NULL && text[0] != '\0');
	}
	text = "unchanged";
	CHECK_EQ(cuGetErrorName((CUresult)123456, &text),
	    CUDA_ERROR_INVALID_VALUE);
	CHECK(text == NULL);
	text = "unchanged";
	CHECK_EQ(cuGetErrorString((CUresult)-9, &text),
	    CUDA_ERROR_INVALID_VALUE);
	CHECK(text == NULL);
	CHECK_EQ(cuGetErrorName(CUDA_SUCCESS, NULL), CUDA_ERROR_INVALID_VALUE);
	CHECK_EQ(cuGetErrorString(CUDA_SUCCESS, NULL), CUDA_ERROR_INVALID_VALUE);
}

static const char *const proc_names[] = {
#include "cuda_test_exports.inc"
};

static void
check_proc_name(const char *name)
{
	CUdriverProcAddressQueryResult status;
	void *expected, *actual;

	actual = NULL;
	status = CU_GET_PROC_ADDRESS_SYMBOL_NOT_FOUND;
	CHECK_EQ(cuGetProcAddress(name, &actual, CUDA_VERSION, 0, &status),
	    CUDA_SUCCESS);
	CHECK_EQ(status, CU_GET_PROC_ADDRESS_SUCCESS);
	expected = dlsym(RTLD_DEFAULT, strcmp(name, "cuGetProcAddress") == 0 ?
	    "cuGetProcAddress_v2" : name);
	CHECK(expected != NULL);
	CHECK(actual == expected);
}

static void
check_proc_api(void)
{
	CUdriverProcAddressQueryResult status;
	typedef CUresult (*legacy_proc)(const char *, void **, int, cuuint64_t);
	legacy_proc legacy;
	void *pfn, *v2;
	size_t i;

	/* Time: O(exports * registry entries); Space: O(1). */
	for (i = 0; i < sizeof(proc_names) / sizeof(proc_names[0]); i++)
		check_proc_name(proc_names[i]);
	pfn = (void *)&status;
	CHECK_EQ(cuGetProcAddress("cuInit", &pfn, CUDA_VERSION,
	    CU_GET_PROC_ADDRESS_LEGACY_STREAM, &status), CUDA_SUCCESS);
	CHECK(pfn == dlsym(RTLD_DEFAULT, "cuInit"));
	CHECK_EQ(cuGetProcAddress("cuInit", &pfn, CUDA_VERSION,
	    CU_GET_PROC_ADDRESS_PER_THREAD_DEFAULT_STREAM, &status),
	    CUDA_SUCCESS);
	CHECK(pfn == dlsym(RTLD_DEFAULT, "cuInit"));

	pfn = (void *)&status;
	status = CU_GET_PROC_ADDRESS_SUCCESS;
	CHECK_EQ(cuGetProcAddress("cuNotARealEntryPoint", &pfn, CUDA_VERSION,
	    0, &status), CUDA_ERROR_NOT_FOUND);
	CHECK(pfn == NULL);
	CHECK_EQ(status, CU_GET_PROC_ADDRESS_SYMBOL_NOT_FOUND);
	pfn = (void *)&status;
	CHECK_EQ(cuGetProcAddress("", &pfn, CUDA_VERSION, 0, &status),
	    CUDA_ERROR_NOT_FOUND);
	CHECK(pfn == NULL);
	CHECK_EQ(status, CU_GET_PROC_ADDRESS_SYMBOL_NOT_FOUND);

	pfn = (void *)&status;
	CHECK_EQ(cuGetProcAddress("cuInit", &pfn, CUDA_VERSION + 10, 0,
	    &status), CUDA_ERROR_INVALID_VALUE);
	CHECK(pfn == NULL);
	CHECK_EQ(status, CU_GET_PROC_ADDRESS_VERSION_NOT_SUFFICIENT);
	pfn = NULL;
	status = CU_GET_PROC_ADDRESS_VERSION_NOT_SUFFICIENT;
	CHECK_EQ(cuGetProcAddress("cuGetProcAddress", &pfn, 11020, 0,
	    &status), CUDA_SUCCESS);
	CHECK(pfn == dlsym(RTLD_DEFAULT, "cuGetProcAddress"));
	CHECK_EQ(status, CU_GET_PROC_ADDRESS_SUCCESS);
	/* The version rule of the legacy row has one boundary, and the two
	 * sides of it are different functions: below the introduction version
	 * the four-argument form, at and above it the five-argument one. */
	pfn = NULL;
	CHECK_EQ(cuGetProcAddress("cuGetProcAddress", &pfn, 11999, 0,
	    &status), CUDA_SUCCESS);
	CHECK(pfn == dlsym(RTLD_DEFAULT, "cuGetProcAddress"));
	CHECK_EQ(status, CU_GET_PROC_ADDRESS_SUCCESS);
	pfn = NULL;
	CHECK_EQ(cuGetProcAddress("cuGetProcAddress", &pfn, 12000, 0,
	    &status), CUDA_SUCCESS);
	CHECK(pfn == dlsym(RTLD_DEFAULT, "cuGetProcAddress_v2"));
	CHECK_EQ(status, CU_GET_PROC_ADDRESS_SUCCESS);
	CHECK_EQ(cuGetProcAddress("cuInit", &pfn, -1, 0, &status),
	    CUDA_ERROR_INVALID_VALUE);
	CHECK_EQ(cuGetProcAddress("cuInit", &pfn, CUDA_VERSION, 4, &status),
	    CUDA_ERROR_INVALID_VALUE);
	CHECK_EQ(cuGetProcAddress(NULL, &pfn, CUDA_VERSION, 0, &status),
	    CUDA_ERROR_INVALID_VALUE);
	CHECK_EQ(cuGetProcAddress("cuInit", NULL, CUDA_VERSION, 0, &status),
	    CUDA_ERROR_INVALID_VALUE);
	pfn = NULL;
	CHECK_EQ(cuGetProcAddress("cuInit", &pfn, CUDA_VERSION, 0, NULL),
	    CUDA_SUCCESS);
	CHECK(pfn == dlsym(RTLD_DEFAULT, "cuInit"));

	v2 = dlsym(RTLD_DEFAULT, "cuGetProcAddress_v2");
	CHECK(v2 != NULL);
	if (v2 != NULL) {
		legacy = (legacy_proc)dlsym(RTLD_DEFAULT, "cuGetProcAddress");
		CHECK(legacy != NULL);
		if (legacy != NULL) {
			pfn = NULL;
			CHECK_EQ(legacy("cuInit", &pfn, CUDA_VERSION, 0),
			    CUDA_SUCCESS);
			CHECK(pfn == dlsym(RTLD_DEFAULT, "cuInit"));
			pfn = NULL;
			CHECK_EQ(legacy("cuGetProcAddress", &pfn, 11030, 0),
			    CUDA_SUCCESS);
			CHECK(pfn == (void *)legacy);
			pfn = NULL;
			CHECK_EQ(legacy("cuGetProcAddress", &pfn, 11999, 0),
			    CUDA_SUCCESS);
			CHECK(pfn == (void *)legacy);
			pfn = NULL;
			CHECK_EQ(legacy("cuGetProcAddress", &pfn, 12000, 0),
			    CUDA_SUCCESS);
			CHECK(pfn == v2);
		}
	}
}

static int
proc_from_stdin_test(void)
{
	char name[256];
	size_t length;
	unsigned count = 0;

	/* Time: O(input bytes * registry entries); Space: O(name length). */
	while (fgets(name, sizeof(name), stdin) != NULL) {
		length = strlen(name);
		if (length != 0 && name[length - 1] == '\n')
			name[--length] = '\0';
		CHECK(length != 0 && length + 1 < sizeof(name));
		check_proc_name(name);
		count++;
	}
	CHECK(!ferror(stdin));
	CHECK_EQ(count, sizeof(proc_names) / sizeof(proc_names[0]));
	return (t_done("proc exports match the dynamic ABI"));
}

/* The version rule of the legacy proc-address row: below the introduction
 * version the four-argument form, at and above it the five-argument one.
 * The test does not read the addresses from the dynamic symbol table: it
 * compares what the library returns with the address of the function the
 * header declares, so the check works in a binary that links the library
 * sources directly. */
static int
proc_version_test(void)
{
	CUdriverProcAddressQueryResult status;
	void *below = NULL, *at = NULL, *v2 = NULL;

	status = CU_GET_PROC_ADDRESS_SYMBOL_NOT_FOUND;
	CHECK_EQ(cuGetProcAddress("cuGetProcAddress", &below, 11999, 0, &status),
	    CUDA_SUCCESS);
	CHECK_EQ(status, CU_GET_PROC_ADDRESS_SUCCESS);
	CHECK(below != NULL);
	status = CU_GET_PROC_ADDRESS_SYMBOL_NOT_FOUND;
	CHECK_EQ(cuGetProcAddress("cuGetProcAddress", &at, 12000, 0, &status),
	    CUDA_SUCCESS);
	CHECK_EQ(status, CU_GET_PROC_ADDRESS_SUCCESS);
	CHECK(at != NULL);
	/* The five-argument form is the one the table holds at that version. */
	status = CU_GET_PROC_ADDRESS_SYMBOL_NOT_FOUND;
	CHECK_EQ(cuGetProcAddress("cuGetProcAddress_v2", &v2, CUDA_VERSION, 0,
	    &status), CUDA_SUCCESS);
	CHECK_EQ(status, CU_GET_PROC_ADDRESS_SUCCESS);
	CHECK(at == v2);
	/* Below the introduction version another function is returned: the
	 * four-argument form. */
	CHECK(below != at);
	return (t_done("api proc-address version boundary"));
}

static int
proc_preinit_test(void)
{
	check_proc_api();
	return (t_done("proc lookup before cuInit"));
}

static void
check_context_basics(CUdevice dev)
{
	CUcontext first = NULL, second = NULL, current = (CUcontext)&current;
	CUdevice from_ctx = -1;

	CHECK_EQ(cuDevicePrimaryCtxRetain(NULL, dev), CUDA_ERROR_INVALID_VALUE);
	CHECK_EQ(cuDevicePrimaryCtxRetain(&first, 88),
	    CUDA_ERROR_INVALID_DEVICE);
	CHECK_EQ(cuDevicePrimaryCtxRelease(88), CUDA_ERROR_INVALID_DEVICE);
	CHECK_EQ(cuDevicePrimaryCtxRelease(dev), CUDA_ERROR_INVALID_CONTEXT);
	CHECK_EQ(cuDevicePrimaryCtxRetain(&first, dev), CUDA_SUCCESS);
	CHECK(first != NULL);
	CHECK_EQ(cuDevicePrimaryCtxRetain(&second, dev), CUDA_SUCCESS);
	CHECK(second == first);
	CHECK_EQ(cuCtxGetCurrent(NULL), CUDA_ERROR_INVALID_VALUE);
	CHECK_EQ(cuCtxGetCurrent(&current), CUDA_SUCCESS);
	CHECK(current == NULL);
	CHECK_EQ(cuCtxGetDevice(&from_ctx), CUDA_ERROR_INVALID_CONTEXT);
	CHECK_EQ(cuCtxSetCurrent((CUcontext)(uintptr_t)1),
	    CUDA_ERROR_INVALID_CONTEXT);
	CHECK_EQ(cuCtxSetCurrent(first), CUDA_SUCCESS);
	CHECK_EQ(cuCtxGetCurrent(&current), CUDA_SUCCESS);
	CHECK(current == first);
	CHECK_EQ(cuCtxGetDevice(NULL), CUDA_ERROR_INVALID_VALUE);
	CHECK_EQ(cuCtxGetDevice(&from_ctx), CUDA_SUCCESS);
	CHECK_EQ(from_ctx, dev);
	CHECK_EQ(cuDevicePrimaryCtxRelease(dev), CUDA_SUCCESS);
	CHECK_EQ(cuCtxGetDevice(&from_ctx), CUDA_SUCCESS);
	CHECK_EQ(cuCtxSetCurrent(NULL), CUDA_SUCCESS);
	CHECK_EQ(cuDevicePrimaryCtxRelease(dev), CUDA_SUCCESS);
	CHECK_EQ(cuCtxGetCurrent(&current), CUDA_SUCCESS);
	CHECK(current == NULL);
	CHECK_EQ(cuCtxSetCurrent(first), CUDA_ERROR_INVALID_CONTEXT);
	CHECK_EQ(cuDevicePrimaryCtxRelease(dev), CUDA_ERROR_INVALID_CONTEXT);
	CHECK_EQ(cuDevicePrimaryCtxRetain(&second, dev), CUDA_SUCCESS);
	CHECK(second == first);
	CHECK_EQ(cuDevicePrimaryCtxRelease(dev), CUDA_SUCCESS);
}

/* The native queries answer from the library's tables and do not start the
 * initialization: a device query after them still reports that the library is
 * not initialized. */
static int
native_queries_test(void)
{
	const char *name, *synthetic = NULL;
	char hint[256], exact[256];
	size_t need;
	unsigned i, count, plain = 0;
	int count_devices = -1;

	/* The provider table is what the library reports: the test carries no
	 * provider name of its own. */
	count = cudaNativeProviderCount();
	CHECK(count > 0);
	for (i = 0; i < count; i++) {
		name = cudaNativeProviderName(i);
		CHECK(name != NULL);
		CHECK(cudaNativeProviderKnown(name) != 0);
		if (cudaNativeProviderTakesFakeProfiles(name))
			synthetic = name;
		else
			plain++;
	}
	/* One provider takes the fake profiles; the others take none. */
	CHECK(synthetic != NULL);
	CHECK(plain == count - 1);
	CHECK(cudaNativeProviderKnown("not-a-provider") == 0);
	CHECK(cudaNativeProviderTakesFakeProfiles("not-a-provider") == 0);
	CHECK(cudaNativeProviderName(count) == NULL);
	CHECK(cudaNativeDefaultBackend() != NULL);
	/* The advice for a provider the library cannot use names that provider
	 * and the one to use instead, so a caller needs no provider name of
	 * its own.  It is written whole or not at all: a buffer that cannot
	 * hold all of it gets nothing, so a caller never reads a truncated
	 * remedy as if it were the whole one. */
	for (i = 0; i < count; i++) {
		name = cudaNativeProviderName(i);
		if (cudaNativeProviderTakesFakeProfiles(name))
			continue;
		CHECK(cudaNativeProviderHint(name, hint, sizeof(hint)) != 0);
		CHECK(strstr(hint, name) != NULL);
		CHECK(strstr(hint, synthetic) != NULL);
		need = strlen(hint);
		CHECK(need + 1 <= sizeof(hint));
		/* One byte too small: the advice does not fit, so the
		 * caller's buffer keeps what it had. */
		memset(hint, 'S', sizeof(hint));
		CHECK(cudaNativeProviderHint(name, hint, need) == 0);
		CHECK(hint[0] == 'S');
		/* Exactly the size of the advice: it is written whole. */
		memset(exact, 0, sizeof(exact));
		CHECK(cudaNativeProviderHint(name, exact, sizeof(exact)) != 0);
		memset(hint, 'S', sizeof(hint));
		CHECK(cudaNativeProviderHint(name, hint, need + 1) != 0);
		CHECK(strcmp(hint, exact) == 0);
	}
	/* A provider with no advice, an unknown name and a null buffer get
	 * nothing written and a zero answer. */
	memset(hint, 'S', sizeof(hint));
	CHECK(cudaNativeProviderHint(synthetic, hint, sizeof(hint)) == 0);
	CHECK(hint[0] == 'S');
	memset(hint, 'S', sizeof(hint));
	CHECK(cudaNativeProviderHint("not-a-provider", hint, sizeof(hint)) == 0);
	CHECK(hint[0] == 'S');
	CHECK(cudaNativeProviderHint(NULL, hint, sizeof(hint)) == 0);
	CHECK(cudaNativeProviderHint("fake", NULL, 0) == 0);
	CHECK(cudaNativeFakeProfileCount() > 0);
	CHECK(cudaNativeFakeProfileName(0) != NULL);
	CHECK(cudaNativeFakeProfileName(cudaNativeFakeProfileCount()) == NULL);
	CHECK(cudaNativeFakeProfileDefault() != NULL);
	/* No initialization has run, so there is no failure to report: the
	 * reason is "not attempted", which is not a success. */
	CHECK_EQ(cudaNativeInitFailureReason(), CUDA_NATIVE_INIT_NOT_ATTEMPTED);
	CHECK_EQ(cuDeviceGetCount(&count_devices), CUDA_ERROR_NOT_INITIALIZED);
	return (t_done("api native queries"));
}

static int
core_test(void)
{
	CUuuid uuid;
	CUdevice dev = -1;
	size_t bytes = 0;
	char name[128], short_name[5], one[2];
	int count = -1, version = -1, value = -1;

	check_abi_values();
	check_error_api();
	CHECK_EQ(cuDriverGetVersion(NULL), CUDA_ERROR_INVALID_VALUE);
	CHECK_EQ(cuDriverGetVersion(&version), CUDA_SUCCESS);
	CHECK_EQ(version, CUDA_VERSION);
	CHECK_EQ(cuDeviceGetCount(NULL), CUDA_ERROR_INVALID_VALUE);
	CHECK_EQ(cuDeviceGetCount(&count), CUDA_ERROR_NOT_INITIALIZED);
	value = 42;
	CHECK_EQ(cuDeviceGetAttribute(&value, CU_DEVICE_ATTRIBUTE_WARP_SIZE, 0),
	    CUDA_ERROR_NOT_INITIALIZED);
	CHECK_EQ(value, 42);
	CHECK_EQ(cuCtxGetCurrent(NULL), CUDA_ERROR_INVALID_VALUE);
	CHECK_EQ(cuInit(1), CUDA_ERROR_INVALID_VALUE);
	CHECK_EQ(cuDeviceGetCount(&count), CUDA_ERROR_NOT_INITIALIZED);
	CHECK_EQ(cuInit(0), CUDA_SUCCESS);
	CHECK_EQ(cuInit(0), CUDA_SUCCESS);

	CHECK_EQ(cuDeviceGetCount(&count), CUDA_SUCCESS);
	CHECK_EQ(count, 1);
	CHECK_EQ(cuDeviceGet(NULL, 0), CUDA_ERROR_INVALID_VALUE);
	CHECK_EQ(cuDeviceGet(&dev, -1), CUDA_ERROR_INVALID_DEVICE);
	CHECK_EQ(cuDeviceGet(&dev, 1), CUDA_ERROR_INVALID_DEVICE);
	CHECK_EQ(cuDeviceGet(&dev, 0), CUDA_SUCCESS);
	CHECK_EQ(dev, 0);

	memset(name, 'x', sizeof(name));
	CHECK_EQ(cuDeviceGetName(NULL, sizeof(name), dev),
	    CUDA_ERROR_INVALID_VALUE);
	CHECK_EQ(cuDeviceGetName(name, 0, dev), CUDA_ERROR_INVALID_VALUE);
	CHECK_EQ(cuDeviceGetName(name, -1, dev), CUDA_ERROR_INVALID_VALUE);
	CHECK_EQ(cuDeviceGetName(name, sizeof(name), 42),
	    CUDA_ERROR_INVALID_DEVICE);
	CHECK_EQ(cuDeviceGetName(name, sizeof(name), dev), CUDA_SUCCESS);
	CHECK_STR(name, "cuda-native fake GB206");
	memset(short_name, 'x', sizeof(short_name));
	CHECK_EQ(cuDeviceGetName(short_name, sizeof(short_name), dev),
	    CUDA_SUCCESS);
	CHECK_STR(short_name, "cuda");
	one[0] = one[1] = 'x';
	CHECK_EQ(cuDeviceGetName(one, 1, dev), CUDA_SUCCESS);
	CHECK_EQ(one[0], '\0');
	CHECK_EQ(one[1], 'x');

	CHECK_EQ(cuDeviceGetUuid(NULL, dev), CUDA_ERROR_INVALID_VALUE);
	CHECK_EQ(cuDeviceGetUuid(&uuid, 42), CUDA_ERROR_INVALID_DEVICE);
	memset(&uuid, 0, sizeof(uuid));
	CHECK_EQ(cuDeviceGetUuid(&uuid, dev), CUDA_SUCCESS);
	CHECK(memcmp(uuid.bytes, gb206_uuid, sizeof(gb206_uuid)) == 0);
	CHECK_EQ(cuDeviceTotalMem(NULL, dev), CUDA_ERROR_INVALID_VALUE);
	CHECK_EQ(cuDeviceTotalMem(&bytes, 42), CUDA_ERROR_INVALID_DEVICE);
	CHECK_EQ(cuDeviceTotalMem(&bytes, dev), CUDA_SUCCESS);
	CHECK_EQ(bytes, (size_t)16 * 1024 * 1024 * 1024);
	CHECK_EQ(cuDeviceGetAttribute(NULL,
	    CU_DEVICE_ATTRIBUTE_WARP_SIZE, dev), CUDA_ERROR_INVALID_VALUE);
	value = 42;
	CHECK_EQ(cuDeviceGetAttribute(&value, CU_DEVICE_ATTRIBUTE_WARP_SIZE, 42),
	    CUDA_ERROR_INVALID_DEVICE);
	CHECK_EQ(value, 42);
	value = 42;
	CHECK_EQ(cuDeviceGetAttribute(&value, (CUdevice_attribute)99999, dev),
	    CUDA_ERROR_NOT_SUPPORTED);
	CHECK_EQ(value, 42);

	check_attribute(dev, CU_DEVICE_ATTRIBUTE_MAX_THREADS_PER_BLOCK, 1024);
	check_attribute(dev, CU_DEVICE_ATTRIBUTE_MAX_SHARED_MEMORY_PER_BLOCK,
	    48 * 1024);
	check_attribute(dev, CU_DEVICE_ATTRIBUTE_WARP_SIZE, 32);
	check_attribute(dev, CU_DEVICE_ATTRIBUTE_MULTIPROCESSOR_COUNT, 36);
	check_attribute(dev, CU_DEVICE_ATTRIBUTE_INTEGRATED, 0);
	check_attribute(dev, CU_DEVICE_ATTRIBUTE_PCI_BUS_ID, 1);
	check_attribute(dev, CU_DEVICE_ATTRIBUTE_PCI_DEVICE_ID, 0);
	check_attribute(dev, CU_DEVICE_ATTRIBUTE_PCI_DOMAIN_ID, 0);
	check_attribute(dev, CU_DEVICE_ATTRIBUTE_COMPUTE_CAPABILITY_MAJOR, 12);
	check_attribute(dev, CU_DEVICE_ATTRIBUTE_COMPUTE_CAPABILITY_MINOR, 0);
	check_attribute(dev, CU_DEVICE_ATTRIBUTE_COOPERATIVE_LAUNCH, 0);
	check_attribute(dev,
	    CU_DEVICE_ATTRIBUTE_MAX_SHARED_MEMORY_PER_BLOCK_OPTIN, 99 * 1024);
	check_attribute(dev,
	    CU_DEVICE_ATTRIBUTE_VIRTUAL_MEMORY_MANAGEMENT_SUPPORTED, 1);
	check_proc_api();
	check_context_basics(dev);
	return (t_done("api core"));
}

static int
profiles_test(void)
{
	CUuuid a, b;
	CUdevice dev = -1;
	size_t bytes = 0;
	char name[64];
	int count = 0;

	CHECK_EQ(cuInit(0), CUDA_SUCCESS);
	CHECK_EQ(cuDeviceGetCount(&count), CUDA_SUCCESS);
	CHECK_EQ(count, 2);
	CHECK_EQ(cuDeviceGet(&dev, 0), CUDA_SUCCESS);
	CHECK_EQ(cuDeviceGetName(name, sizeof(name), dev), CUDA_SUCCESS);
	CHECK_STR(name, "cuda-native fake GB206");
	CHECK_EQ(cuDeviceGetUuid(&a, dev), CUDA_SUCCESS);
	check_attribute(dev, CU_DEVICE_ATTRIBUTE_MULTIPROCESSOR_COUNT, 36);
	check_attribute(dev, CU_DEVICE_ATTRIBUTE_COMPUTE_CAPABILITY_MINOR, 0);
	check_attribute(dev, CU_DEVICE_ATTRIBUTE_INTEGRATED, 0);
	check_attribute(dev, CU_DEVICE_ATTRIBUTE_PCI_DOMAIN_ID, 0);
	CHECK_EQ(cuDeviceGet(&dev, 1), CUDA_SUCCESS);
	CHECK_EQ(cuDeviceGetName(name, sizeof(name), dev), CUDA_SUCCESS);
	CHECK_STR(name, "cuda-native fake GB10");
	CHECK_EQ(cuDeviceGetUuid(&b, dev), CUDA_SUCCESS);
	CHECK(memcmp(a.bytes, b.bytes, sizeof(a.bytes)) != 0);
	CHECK(memcmp(a.bytes, gb206_uuid, sizeof(a.bytes)) == 0);
	CHECK(memcmp(b.bytes, gb10_uuid, sizeof(b.bytes)) == 0);
	CHECK_EQ(cuDeviceTotalMem(&bytes, dev), CUDA_SUCCESS);
	CHECK_EQ(bytes, (size_t)128 * 1024 * 1024 * 1024);
	check_attribute(dev, CU_DEVICE_ATTRIBUTE_MULTIPROCESSOR_COUNT, 48);
	check_attribute(dev, CU_DEVICE_ATTRIBUTE_COMPUTE_CAPABILITY_MAJOR, 12);
	check_attribute(dev, CU_DEVICE_ATTRIBUTE_COMPUTE_CAPABILITY_MINOR, 1);
	check_attribute(dev, CU_DEVICE_ATTRIBUTE_INTEGRATED, 1);
	check_attribute(dev, CU_DEVICE_ATTRIBUTE_PCI_DOMAIN_ID, 15);
	check_attribute(dev, CU_DEVICE_ATTRIBUTE_PCI_BUS_ID, 1);
	check_attribute(dev, CU_DEVICE_ATTRIBUTE_PCI_DEVICE_ID, 0);
	check_attribute(dev, CU_DEVICE_ATTRIBUTE_MAX_THREADS_PER_BLOCK, 1024);
	check_attribute(dev, CU_DEVICE_ATTRIBUTE_WARP_SIZE, 32);
	return (t_done("api profiles"));
}

static void
uuid_text(const CUuuid *uuid, char out[37])
{
	static const char hex[] = "0123456789abcdef";
	unsigned i, pos = 0;

	for (i = 0; i < 16; i++) {
		if (i == 4 || i == 6 || i == 8 || i == 10)
			out[pos++] = '-';
		out[pos++] = hex[((const unsigned char *)uuid->bytes)[i] >> 4];
		out[pos++] = hex[((const unsigned char *)uuid->bytes)[i] & 15];
	}
	out[pos] = '\0';
}

static int
order_test(int argc, char **argv, int uuids)
{
	char name[64], text[37];
	CUuuid uuid;
	CUdevice dev;
	int count = -1, i;

	CHECK_EQ(cuInit(0), CUDA_SUCCESS);
	CHECK_EQ(cuDeviceGetCount(&count), CUDA_SUCCESS);
	CHECK_EQ(count, argc);
	for (i = 0; i < argc; i++) {
		CHECK_EQ(cuDeviceGet(&dev, i), CUDA_SUCCESS);
		CHECK_EQ(dev, i);
		if (uuids) {
			CHECK_EQ(cuDeviceGetUuid(&uuid, dev), CUDA_SUCCESS);
			uuid_text(&uuid, text);
			CHECK_STR(text, argv[i]);
		} else {
			CHECK_EQ(cuDeviceGetName(name, sizeof(name), dev),
			    CUDA_SUCCESS);
			CHECK_STR(name, argv[i]);
		}
	}
	CHECK_EQ(cuDeviceGet(&dev, argc), CUDA_ERROR_INVALID_DEVICE);
	return (t_done(uuids ? "api UUID visibility" : "api visibility"));
}

struct thread_case {
	CUdevice dev;
	CUcontext expected;
	CUresult retain_result;
	CUresult set_result;
	CUresult get_result;
	CUresult release_result;
	CUcontext retained;
	CUdevice from_ctx;
	int initial_was_null;
};

static void *
context_thread(void *arg)
{
	struct thread_case *tc = arg;
	CUcontext current = (CUcontext)&current;

	tc->initial_was_null = 0;
	if (cuCtxGetCurrent(&current) == CUDA_SUCCESS && current == NULL)
		tc->initial_was_null = 1;
	tc->retain_result = cuDevicePrimaryCtxRetain(&tc->retained, tc->dev);
	tc->set_result = cuCtxSetCurrent(tc->retained);
	tc->get_result = cuCtxGetDevice(&tc->from_ctx);
	tc->release_result = cuDevicePrimaryCtxRelease(tc->dev);
	return (NULL);
}

static int
threads_test(void)
{
	struct thread_case a, b;
	CUcontext c0 = NULL, c1 = NULL, current = NULL;
	CUdevice dev = -1;
	pthread_t thread;
	int count = 0;

	CHECK_EQ(cuInit(0), CUDA_SUCCESS);
	CHECK_EQ(cuDeviceGetCount(&count), CUDA_SUCCESS);
	CHECK_EQ(count, 2);
	CHECK_EQ(cuDevicePrimaryCtxRetain(&c0, 0), CUDA_SUCCESS);
	CHECK_EQ(cuDevicePrimaryCtxRetain(&c1, 1), CUDA_SUCCESS);
	CHECK(c0 != NULL && c1 != NULL && c0 != c1);
	CHECK_EQ(cuCtxSetCurrent(c0), CUDA_SUCCESS);

	memset(&a, 0, sizeof(a));
	a.dev = 1;
	a.expected = c1;
	a.from_ctx = -1;
	CHECK_EQ(pthread_create(&thread, NULL, context_thread, &a), 0);
	CHECK_EQ(pthread_join(thread, NULL), 0);
	CHECK_EQ(a.initial_was_null, 1);
	CHECK_EQ(a.retain_result, CUDA_SUCCESS);
	CHECK(a.retained == a.expected);
	CHECK_EQ(a.set_result, CUDA_SUCCESS);
	CHECK_EQ(a.get_result, CUDA_SUCCESS);
	CHECK_EQ(a.from_ctx, 1);
	CHECK_EQ(a.release_result, CUDA_SUCCESS);
	CHECK_EQ(cuCtxGetCurrent(&current), CUDA_SUCCESS);
	CHECK(current == c0);
	CHECK_EQ(cuCtxGetDevice(&dev), CUDA_SUCCESS);
	CHECK_EQ(dev, 0);

	memset(&b, 0, sizeof(b));
	b.dev = 0;
	b.expected = c0;
	b.from_ctx = -1;
	CHECK_EQ(pthread_create(&thread, NULL, context_thread, &b), 0);
	CHECK_EQ(pthread_join(thread, NULL), 0);
	CHECK_EQ(b.initial_was_null, 1);
	CHECK_EQ(b.retain_result, CUDA_SUCCESS);
	CHECK(b.retained == b.expected);
	CHECK_EQ(b.set_result, CUDA_SUCCESS);
	CHECK_EQ(b.get_result, CUDA_SUCCESS);
	CHECK_EQ(b.from_ctx, 0);
	CHECK_EQ(b.release_result, CUDA_SUCCESS);
	CHECK_EQ(cuCtxGetCurrent(&current), CUDA_SUCCESS);
	CHECK(current == c0);
	CHECK_EQ(cuCtxSetCurrent(NULL), CUDA_SUCCESS);
	CHECK_EQ(cuDevicePrimaryCtxRelease(0), CUDA_SUCCESS);
	CHECK_EQ(cuDevicePrimaryCtxRelease(1), CUDA_SUCCESS);
	return (t_done("api contexts across two threads"));
}

struct init_case {
	CUresult init;
	CUresult count_result;
	int count;
};

static void *
init_thread(void *arg)
{
	struct init_case *ic = arg;

	ic->init = cuInit(0);
	ic->count_result = cuDeviceGetCount(&ic->count);
	return (NULL);
}

static int
init_race_test(void)
{
	struct init_case cases[12];
	pthread_t threads[12];
	unsigned round;
	int i;

	/* Time: O(200 * threads); Space: O(threads). */
	for (round = 0; round < 200; round++) {
		memset(cases, 0, sizeof(cases));
		/* Time: O(threads); Space: O(1). */
		for (i = 0; i < 12; i++)
			CHECK_EQ(pthread_create(&threads[i], NULL, init_thread,
			    &cases[i]), 0);
		/* Time: O(threads); Space: O(1). */
		for (i = 0; i < 12; i++) {
			CHECK_EQ(pthread_join(threads[i], NULL), 0);
			CHECK_EQ(cases[i].init, CUDA_SUCCESS);
			CHECK_EQ(cases[i].count_result, CUDA_SUCCESS);
			CHECK_EQ(cases[i].count, 2);
		}
	}
	return (t_done("api concurrent cuInit and count, 200 rounds"));
}

struct observer_case {
	CUresult first_result;
	CUresult init_result;
	CUresult observed_result;
	int first_count;
	int observed_count;
	int observations;
};

static pthread_mutex_t observer_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t observer_cond = PTHREAD_COND_INITIALIZER;
static int observer_ready;

static void *
observer_init_thread(void *arg)
{
	struct observer_case *observer = arg;

	pthread_mutex_lock(&observer_lock);
	/* Time: O(observer startup wait); Space: O(1). */
	while (!observer_ready)
		pthread_cond_wait(&observer_cond, &observer_lock);
	pthread_mutex_unlock(&observer_lock);
	observer->init_result = cuInit(0);
	return (NULL);
}

static void *
observer_count_thread(void *arg)
{
	struct observer_case *observer = arg;

	observer->first_count = -1;
	observer->first_result = cuDeviceGetCount(&observer->first_count);
	observer->observed_result = observer->first_result;
	observer->observed_count = observer->first_count;
	observer->observations = 1;
	pthread_mutex_lock(&observer_lock);
	observer_ready = 1;
	pthread_cond_signal(&observer_cond);
	pthread_mutex_unlock(&observer_lock);
	/* Time: O(initialization wait); Space: O(1). */
	while (observer->observed_result == CUDA_ERROR_NOT_INITIALIZED) {
		observer->observations++;
		observer->observed_result =
		    cuDeviceGetCount(&observer->observed_count);
	}
	return (NULL);
}

static int
init_observer_test(void)
{
	struct observer_case observer;
	const char *backend = getenv("CUDA_NATIVE_BACKEND");
	CUresult expected = backend != NULL && strcmp(backend, "nvrm") == 0 ?
	    CUDA_ERROR_NOT_SUPPORTED : CUDA_SUCCESS;
	pthread_t initializer, reader;

	memset(&observer, 0, sizeof(observer));
	observer_ready = 0;
	CHECK_EQ(pthread_create(&reader, NULL, observer_count_thread,
	    &observer), 0);
	CHECK_EQ(pthread_create(&initializer, NULL, observer_init_thread,
	    &observer), 0);
	CHECK_EQ(pthread_join(initializer, NULL), 0);
	CHECK_EQ(pthread_join(reader, NULL), 0);
	CHECK_EQ(observer.first_result, CUDA_ERROR_NOT_INITIALIZED);
	CHECK_EQ(observer.first_count, -1);
	CHECK_EQ(observer.init_result, expected);
	CHECK(observer.observations > 0);
	CHECK_EQ(observer.observed_result, expected);
	CHECK_EQ(observer.observed_count,
	    expected == CUDA_SUCCESS ? 2 : -1);
	return (t_done("api initialization observer"));
}

/* Many threads call cuInit and cuDeviceGetCount at once, again and again.
 * Every thread must see the same device count: the registry data is
 * published before a reader can see that the initialization completed.
 * Every round runs in a child process, so every round initializes a
 * registry of its own: the registry of one process is initialized once, and
 * a second round in the same process would only call the completed one. */
#define INIT_STRESS_THREADS 32
#define INIT_STRESS_ROUNDS 200

struct stress_case {
	CUresult init;
	CUresult count_result;
	int count;
	int index;
};

/* A test-only switch: it makes one thread of a round see a device count that
 * the other threads do not see.  The round fails, and the failure has to
 * reach the parent through the exit status of the child: a child that exits
 * with the status of success hides the failure. */
static int
stress_count_disturbed(void)
{
	const char *value = getenv("CUDA_NATIVE_TEST_STRESS_DISTURB");

	return (value != NULL && *value != '\0');
}

static void *
stress_thread(void *arg)
{
	struct stress_case *sc = arg;

	sc->init = cuInit(0);
	sc->count_result = cuDeviceGetCount(&sc->count);
	if (stress_count_disturbed() && sc->index == 0 && sc->count > 0)
		sc->count++;
	return (NULL);
}

/* One round: the threads call cuInit at once and must all see the same
 * device count.  The number of failed checks is the answer, so a child
 * process can report it. */
static int
stress_round(void)
{
	struct stress_case cases[INIT_STRESS_THREADS];
	pthread_t threads[INIT_STRESS_THREADS];
	int i, first;

	memset(cases, 0, sizeof(cases));
	/* Time: O(threads); Space: O(1). */
	for (i = 0; i < INIT_STRESS_THREADS; i++) {
		cases[i].index = i;
		CHECK_EQ(pthread_create(&threads[i], NULL, stress_thread,
		    &cases[i]), 0);
	}
	first = -1;
	/* Time: O(threads); Space: O(1). */
	for (i = 0; i < INIT_STRESS_THREADS; i++) {
		CHECK_EQ(pthread_join(threads[i], NULL), 0);
		CHECK_EQ(cases[i].init, CUDA_SUCCESS);
		CHECK_EQ(cases[i].count_result, CUDA_SUCCESS);
		if (first == -1)
			first = cases[i].count;
		/* Every thread sees the same device count. */
		CHECK_EQ(cases[i].count, first);
		CHECK_EQ(cases[i].count, 2);
	}
	return (t_fails);
}

static int
init_stress_test(void)
{
	unsigned round;
	pid_t pid;
	int status;

	/* Time: O(rounds * threads); Space: O(threads). */
	for (round = 0; round < INIT_STRESS_ROUNDS; round++) {
		/* A child process has a registry of its own, so this round
		 * initializes it for the first time. */
		pid = fork();
		if (pid < 0) {
			CHECK(pid >= 0);
			break;
		}
		if (pid == 0) {
			/* The registry of this process was never
			 * initialized: the reason says so before the
			 * first cuInit. */
			CHECK_EQ(cudaNativeInitFailureReason(),
			    CUDA_NATIVE_INIT_NOT_ATTEMPTED);
			/* The child has its own checks and its own failure
			 * count: the parent sees only the exit status, so
			 * a failure of the child has to be in it. */
			(void)stress_round();
			fflush(NULL);
			_exit(t_fails == 0 ? 0 : 1);
		}
		CHECK_EQ(waitpid(pid, &status, 0), pid);
		CHECK(WIFEXITED(status));
		CHECK(!WIFSIGNALED(status));
		CHECK_EQ(WEXITSTATUS(status), 0);
	}
	return (t_done("api concurrent cuInit and count, 32 threads, 200 rounds"));
}

/* The names the library reports.  A caller and a test take the provider and
 * the profile lists from here, not from a literal of their own. */
static int mode_usage(void);

static int
providers_test(void)
{
	const char *name;
	unsigned i, count;
	char hint[256];

	count = cudaNativeProviderCount();
	for (i = 0; i < count; i++) {
		name = cudaNativeProviderName(i);
		printf("provider %s\n", name);
		printf("%s %s\n", cudaNativeProviderTakesFakeProfiles(name) ?
		    "synthetic" : "native", name);
	}
	if (cudaNativeProviderHint(cudaNativeDefaultBackend(), hint,
	    sizeof(hint)))
		printf("hint %s\n", hint);
	count = cudaNativeFakeProfileCount();
	for (i = 0; i < count; i++)
		printf("profile %s\n", cudaNativeFakeProfileName(i));
	printf("default-profile %s\n", cudaNativeFakeProfileDefault());
	printf("default-backend %s\n", cudaNativeDefaultBackend());
	return (0);
}

/* The reason of the first initialization attempt, as a stable name. */
static const char *
reason_name(cudaNativeInitReason reason)
{
	switch (reason) {
	case CUDA_NATIVE_INIT_OK:
		return ("ok");
	case CUDA_NATIVE_INIT_UNKNOWN_PROVIDER:
		return ("unknown-provider");
	case CUDA_NATIVE_INIT_DEVICE_LIMIT:
		return ("device-limit");
	case CUDA_NATIVE_INIT_PROVIDER_UNSUPPORTED:
		return ("provider-unsupported");
	case CUDA_NATIVE_INIT_PROVIDER_DEVICE_LIMIT:
		return ("provider-device-limit");
	case CUDA_NATIVE_INIT_NOT_ATTEMPTED:
		return ("not-attempted");
	default:
		return ("provider-error");
	}
}

static int
init_reason_test(void)
{
	(void)cuInit(0);
	printf("reason %s\n", reason_name(cudaNativeInitFailureReason()));
	return (0);
}

/* The reason before any initialization attempt: it is its own state and it
 * is not the state of a successful initialization. */
static int
preinit_reason_test(void)
{
	printf("reason %s\n", reason_name(cudaNativeInitFailureReason()));
	return (0);
}

static int
attribute_error_test(void)
{
	static const CUdevice_attribute attributes[] = {
		CU_DEVICE_ATTRIBUTE_MAX_THREADS_PER_BLOCK,
		CU_DEVICE_ATTRIBUTE_MAX_SHARED_MEMORY_PER_BLOCK,
		CU_DEVICE_ATTRIBUTE_WARP_SIZE,
		CU_DEVICE_ATTRIBUTE_MULTIPROCESSOR_COUNT,
		CU_DEVICE_ATTRIBUTE_INTEGRATED,
		CU_DEVICE_ATTRIBUTE_PCI_BUS_ID,
		CU_DEVICE_ATTRIBUTE_PCI_DEVICE_ID,
		CU_DEVICE_ATTRIBUTE_PCI_DOMAIN_ID,
		CU_DEVICE_ATTRIBUTE_COMPUTE_CAPABILITY_MAJOR,
		CU_DEVICE_ATTRIBUTE_COMPUTE_CAPABILITY_MINOR,
		CU_DEVICE_ATTRIBUTE_COOPERATIVE_LAUNCH,
		CU_DEVICE_ATTRIBUTE_MAX_SHARED_MEMORY_PER_BLOCK_OPTIN,
		CU_DEVICE_ATTRIBUTE_VIRTUAL_MEMORY_MANAGEMENT_SUPPORTED
	};
	size_t i;
	int value;

	CHECK_EQ(cuInit(0), CUDA_SUCCESS);
	/* Time: O(attributes); Space: O(1). */
	for (i = 0; i < sizeof(attributes) / sizeof(attributes[0]); i++) {
		value = 4242;
		CHECK_EQ(cuDeviceGetAttribute(&value, attributes[i], 42),
		    CUDA_ERROR_INVALID_DEVICE);
		CHECK_EQ(value, 4242);
	}
	value = 4242;
	CHECK_EQ(cuDeviceGetAttribute(&value,
	    CU_DEVICE_ATTRIBUTE_COOPERATIVE_LAUNCH, 0), CUDA_ERROR_NOT_SUPPORTED);
	CHECK_EQ(value, 4242);
	value = 4242;
	CHECK_EQ(cuDeviceGetAttribute(&value, (CUdevice_attribute)99999, 0),
	    CUDA_ERROR_NOT_SUPPORTED);
	CHECK_EQ(value, 4242);
	return (t_done("api attribute failures preserve the output"));
}

static int
visibility_cap_test(void)
{
	int count = -1;

	CHECK_EQ(cuInit(0), CUDA_SUCCESS);
	CHECK_EQ(cuDeviceGetCount(&count), CUDA_SUCCESS);
	CHECK_EQ(count, 64);
	return (t_done("api visibility accepts exactly 64 entries"));
}

static int
nvrm_test(void)
{
	int count = -1;

	CHECK_EQ(cuInit(0), CUDA_ERROR_NOT_SUPPORTED);
	CHECK_EQ(cuDeviceGetCount(&count), CUDA_ERROR_NOT_SUPPORTED);
	CHECK_EQ(count, -1);
	return (t_done("api nvrm stub"));
}

/* The backend name follows the calling process's environment, so the manual
 * cannot describe it as process-independent. */
static int
backend_name_test(void)
{
	const char *name;

	CHECK_EQ(unsetenv("CUDA_NATIVE_BACKEND"), 0);
	name = cudaNativeGetBackendName();
	CHECK_STR(name, "nvrm");
	CHECK_EQ(setenv("CUDA_NATIVE_BACKEND", "fake", 1), 0);
	name = cudaNativeGetBackendName();
	CHECK_STR(name, "fake");
	CHECK_EQ(setenv("CUDA_NATIVE_BACKEND", "nvrm", 1), 0);
	name = cudaNativeGetBackendName();
	CHECK_STR(name, "nvrm");
	return (t_done("api backend name follows the calling environment"));
}

static int
failed_init_test(CUresult expected, const char *name)
{
	int count = -1;

	CHECK_EQ(cuInit(0), expected);
	CHECK_EQ(cuDeviceGetCount(&count), expected);
	CHECK_EQ(count, -1);
	CHECK_EQ(setenv("CUDA_NATIVE_BACKEND", "fake", 1), 0);
	CHECK_EQ(setenv("CUDA_NATIVE_FAKE_PROFILE", "gb206", 1), 0);
	CHECK_EQ(cuInit(0), expected);
	CHECK_EQ(cuDeviceGetCount(&count), expected);
	CHECK_EQ(count, -1);
	return (t_done(name));
}

static int
mode_usage(void)
{
	fprintf(stderr, "usage: api_test core|native-queries|profiles|threads|"
	    "init-race|init-stress|init-observer|init-reason|preinit-reason|"
	    "providers|"
	    "proc-preinit|proc-version|proc-from-stdin|attribute-error|"
	    "visibility-cap|nvrm|backend-name|"
	    "bad-backend|bad-profile|bad-visibility|uuid-error|"
	    "order [NAME ...]|uuid-order [UUID ...]\n");
	return (2);
}

#define	DEFINE_SIMPLE_MODE(name, test)					\
	static int							\
	name(int argc, char **argv)					\
	{								\
		(void)argv;						\
		if (argc != 2)						\
			return (mode_usage());				\
		return (test());					\
	}

DEFINE_SIMPLE_MODE(core_mode, core_test)
DEFINE_SIMPLE_MODE(native_queries_mode, native_queries_test)
DEFINE_SIMPLE_MODE(profiles_mode, profiles_test)
DEFINE_SIMPLE_MODE(threads_mode, threads_test)
DEFINE_SIMPLE_MODE(init_race_mode, init_race_test)
DEFINE_SIMPLE_MODE(init_stress_mode, init_stress_test)
DEFINE_SIMPLE_MODE(init_observer_mode, init_observer_test)
DEFINE_SIMPLE_MODE(providers_mode, providers_test)
DEFINE_SIMPLE_MODE(init_reason_mode, init_reason_test)
DEFINE_SIMPLE_MODE(preinit_reason_mode, preinit_reason_test)
DEFINE_SIMPLE_MODE(proc_preinit_mode, proc_preinit_test)
DEFINE_SIMPLE_MODE(proc_version_mode, proc_version_test)
DEFINE_SIMPLE_MODE(proc_from_stdin_mode, proc_from_stdin_test)
DEFINE_SIMPLE_MODE(attribute_error_mode, attribute_error_test)
DEFINE_SIMPLE_MODE(visibility_cap_mode, visibility_cap_test)
DEFINE_SIMPLE_MODE(nvrm_mode, nvrm_test)
DEFINE_SIMPLE_MODE(backend_name_mode, backend_name_test)

static int
failed_init_mode(int argc, char **argv)
{
	CUresult expected = CUDA_ERROR_INVALID_VALUE;
	const char *name = "api unknown backend";

	if (argc != 2)
		return (mode_usage());
	if (strcmp(argv[1], "bad-profile") == 0)
		name = "api unknown fake profile";
	else if (strcmp(argv[1], "bad-visibility") == 0)
		name = "api visibility list exceeds 64 entries";
	else if (strcmp(argv[1], "uuid-error") == 0) {
		expected = CUDA_ERROR_UNKNOWN;
		name = "api UUID provider failure is persistent";
	}
	return (failed_init_test(expected, name));
}

static int
order_mode(int argc, char **argv)
{
	return (order_test(argc - 2, argv + 2,
	    strcmp(argv[1], "uuid-order") == 0));
}

int
main(int argc, char **argv)
{
	struct mode {
		const char *name;
		int (*handler)(int argc, char **argv);
	};
	static const struct mode modes[] = {
		{ "core", core_mode },
		{ "native-queries", native_queries_mode },
		{ "profiles", profiles_mode },
		{ "threads", threads_mode },
		{ "init-race", init_race_mode },
		{ "init-stress", init_stress_mode },
		{ "init-observer", init_observer_mode },
		{ "init-reason", init_reason_mode },
		{ "preinit-reason", preinit_reason_mode },
		{ "providers", providers_mode },
		{ "proc-preinit", proc_preinit_mode },
		{ "proc-version", proc_version_mode },
		{ "proc-from-stdin", proc_from_stdin_mode },
		{ "attribute-error", attribute_error_mode },
		{ "visibility-cap", visibility_cap_mode },
		{ "nvrm", nvrm_mode },
		{ "backend-name", backend_name_mode },
		{ "bad-backend", failed_init_mode },
		{ "bad-profile", failed_init_mode },
		{ "bad-visibility", failed_init_mode },
		{ "uuid-error", failed_init_mode },
		{ "order", order_mode },
		{ "uuid-order", order_mode }
	};
	size_t i;

	if (argc >= 2) {
		/* Time: O(modes); Space: O(1). */
		for (i = 0; i < sizeof(modes) / sizeof(modes[0]); i++) {
			if (strcmp(argv[1], modes[i].name) == 0)
				return (modes[i].handler(argc, argv));
		}
	}
	return (mode_usage());
}

/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * api_test.c - the native CUDA runtime (lib/libcudart) against the fake
 * backend of libcuda.  Every entry point of the runtime is called here, the
 * error paths with it, and the thread-local error state is checked with two
 * threads that fail apart.
 */
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <cuda_runtime_api.h>

/* The harness is shared with the libcuda test: one copy of the checks. */
#include "../libcuda/t.h"

#define FATBIN_MAGIC "CUDA-NATIVE-STUB-FATBIN 1\n"

/* The wrapper clang's generated code hands to __cudaRegisterFatBinary. */
struct fatbin_wrapper {
	int magic;
	int version;
	const void *data;
	void *unused;
};

#define FATBIN_WRAPPER_MAGIC 0x466243b1

static const char fatbin_body[] =
    FATBIN_MAGIC
    "member kind=ptx sm=120 size=4 sha256="
    "0000000000000000000000000000000000000000000000000000000000000000\n"
    "---\nPTX!";

/* The geometry of a launch.  The C build of this test has no constructor
 * for dim3; the C++ one does. */
static dim3
dim3_of(unsigned x, unsigned y, unsigned z)
{
	dim3 value;

	value.x = x;
	value.y = y;
	value.z = z;
	return (value);
}

/* The reason of the last failure must name what the runtime could not do. */
#define REASON_NAMES(text) do {						\
	const char *reason_ = cudaNativeLastFailureReason();		\
	CHECK(reason_ != NULL);						\
	if (reason_ != NULL)						\
		CHECK(strstr(reason_, (text)) != NULL);		\
} while (0)

/* ---- helpers ------------------------------------------------------------ */

/* Every failing call must leave the caller's output alone. */
static void
check_outputs_untouched(void)
{
	void *pointer = (void *)(uintptr_t)0x1234;
	int count = 7;
	int device = 3;
	float elapsed = 1.0f;
	int blocks = 5;
	int grid = 6;
	struct cudaDeviceProp properties;
	struct cudaFuncAttributes attributes;

	memset(&properties, 0, sizeof(properties));
	memset(&attributes, 0, sizeof(attributes));

	CHECK_EQ(cudaMalloc(&pointer, 16), cudaErrorNotSupported);
	CHECK(pointer == (void *)(uintptr_t)0x1234);
	CHECK_EQ(cudaGetDeviceCount(NULL), cudaErrorInvalidValue);
	CHECK_EQ(count, 7);
	CHECK_EQ(cudaGetDevice(NULL), cudaErrorInvalidValue);
	CHECK_EQ(device, 3);
	CHECK_EQ(cudaEventElapsedTime(&elapsed, 0, 0), cudaErrorInvalidResourceHandle);
	CHECK(elapsed == 1.0f);
	CHECK_EQ(cudaOccupancyMaxActiveBlocksPerMultiprocessor(&blocks, NULL, 32, 0),
	    cudaErrorInvalidValue);
	CHECK_EQ(blocks, 5);
	CHECK_EQ(cudaOccupancyMaxPotentialBlockSize(&grid, &blocks, NULL, 0),
	    cudaErrorInvalidValue);
	CHECK_EQ(grid, 6);
	CHECK_EQ(cudaGetDeviceProperties(NULL, 0), cudaErrorInvalidValue);
	CHECK_EQ(cudaGetDeviceProperties(&properties, -1), cudaErrorInvalidDevice);
	CHECK_EQ(cudaFuncGetAttributes(NULL, NULL), cudaErrorInvalidValue);
	CHECK_EQ(cudaFuncGetAttributes(&attributes, NULL), cudaErrorInvalidValue);
}

/* ---- modes -------------------------------------------------------------- */

static int
core_mode(int argc, char **argv)
{
	int version = 0;
	const char *name = NULL;
	const char *text = NULL;

	(void)argc;
	(void)argv;

	/* The error values are the ones the public reference documents. */
	CHECK_EQ(cudaSuccess, 0);
	CHECK_EQ(cudaErrorInvalidValue, 1);
	CHECK_EQ(cudaErrorMemoryAllocation, 2);
	CHECK_EQ(cudaErrorInitializationError, 3);
	CHECK_EQ(cudaErrorNoDevice, 100);
	CHECK_EQ(cudaErrorInvalidDevice, 101);
	CHECK_EQ(cudaErrorInvalidResourceHandle, 400);
	CHECK_EQ(cudaErrorNotReady, 600);
	CHECK_EQ(cudaErrorIllegalAddress, 700);
	CHECK_EQ(cudaErrorInvalidPitchValue, 701);
	CHECK_EQ(cudaErrorLaunchTimeout, 708);
	CHECK_EQ(cudaErrorLaunchFailure, 719);
	CHECK_EQ(cudaErrorNotSupported, 801);
	CHECK_EQ(cudaErrorUnknown, 999);

	CHECK_EQ(cudaRuntimeGetVersion(&version), cudaSuccess);
	CHECK_EQ(version, 13000);
	CHECK_EQ(cudaDriverGetVersion(&version), cudaSuccess);
	CHECK_EQ(version, 13000);
	CHECK_EQ(cudaNativeRuntimeVersion(), 100);
	CHECK_STR(cudaNativeRuntimeVersionString(), "0.1.0");

	/* The name and the text of a known code. */
	CHECK_EQ(cudaGetErrorName(cudaErrorNotSupported, &name), cudaSuccess);
	CHECK_STR(name, "cudaErrorNotSupported");
	CHECK_EQ(cudaGetErrorString(cudaErrorNotSupported, &text), cudaSuccess);
	CHECK(text != NULL && strstr(text, "not supported") != NULL);
	CHECK_EQ(cudaGetErrorName(cudaErrorInvalidDevice, &name), cudaSuccess);
	CHECK_STR(name, "cudaErrorInvalidDevice");

	/* An unknown code is an invalid value and the output is null. */
	name = (const char *)(uintptr_t)0x1;
	CHECK_EQ(cudaGetErrorName((cudaError_t)12345, &name), cudaErrorInvalidValue);
	CHECK(name == NULL);
	text = (const char *)(uintptr_t)0x1;
	CHECK_EQ(cudaGetErrorString((cudaError_t)12345, &text), cudaErrorInvalidValue);
	CHECK(text == NULL);
	CHECK_EQ(cudaGetErrorName(cudaSuccess, NULL), cudaErrorInvalidValue);
	CHECK_EQ(cudaGetErrorString(cudaSuccess, NULL), cudaErrorInvalidValue);

	/* A fresh thread has no error to report. */
	CHECK_EQ(cudaGetLastError(), cudaSuccess);
	CHECK_EQ(cudaPeekAtLastError(), cudaSuccess);
	CHECK(cudaNativeLastFailureReason() == NULL);

	/* A failing call leaves the output of the caller alone. */
	check_outputs_untouched();

	return (t_done("core"));
}

static int
devices_mode(int argc, char **argv)
{
	int count = 0;
	int device = 0;
	struct cudaDeviceProp properties;

	(void)argc;
	(void)argv;

	CHECK_EQ(cudaGetDeviceCount(&count), cudaSuccess);
	CHECK_EQ(count, 2);

	/* The first device is the default device of a thread. */
	CHECK_EQ(cudaGetDevice(&device), cudaSuccess);
	CHECK_EQ(device, 0);

	/* A device out of range is an invalid device. */
	CHECK_EQ(cudaSetDevice(-1), cudaErrorInvalidDevice);
	CHECK_EQ(cudaSetDevice(2), cudaErrorInvalidDevice);
	CHECK_EQ(cudaGetDeviceProperties(&properties, 2), cudaErrorInvalidDevice);

	/* The properties of the second device come from the driver. */
	memset(&properties, 0, sizeof(properties));
	CHECK_EQ(cudaGetDeviceProperties(&properties, 1), cudaSuccess);
	CHECK_STR(properties.name, "cuda-native fake GB10");
	CHECK_EQ(properties.totalGlobalMem, (size_t)128 * 1024 * 1024 * 1024);
	CHECK_EQ(properties.major, 12);
	CHECK_EQ(properties.minor, 1);
	CHECK_EQ(properties.multiProcessorCount, 48);
	CHECK_EQ(properties.integrated, 1);
	CHECK_EQ(properties.maxThreadsPerBlock, 1024);
	CHECK_EQ(properties.warpSize, 32);
	CHECK_EQ(properties.sharedMemPerBlock, (size_t)48 * 1024);
	CHECK_EQ(properties.pciBusID, 1);
	CHECK_EQ(properties.pciDeviceID, 0);
	CHECK_EQ(properties.pciDomainID, 15);

	/* The first device is the other profile. */
	memset(&properties, 0, sizeof(properties));
	CHECK_EQ(cudaGetDeviceProperties(&properties, 0), cudaSuccess);
	CHECK_STR(properties.name, "cuda-native fake GB206");
	CHECK_EQ(properties.major, 12);
	CHECK_EQ(properties.minor, 0);
	CHECK_EQ(properties.multiProcessorCount, 36);
	CHECK_EQ(properties.integrated, 0);

	/* Setting a device makes it the device of the thread. */
	CHECK_EQ(cudaSetDevice(1), cudaSuccess);
	CHECK_EQ(cudaGetDevice(&device), cudaSuccess);
	CHECK_EQ(device, 1);

	/* The reset releases the primary context of the device. */
	CHECK_EQ(cudaDeviceReset(), cudaSuccess);
	CHECK_EQ(cudaGetDevice(&device), cudaSuccess);
	CHECK_EQ(device, 0);

	return (t_done("devices"));
}

static int
not_supported_mode(int argc, char **argv)
{
	void *pointer = NULL;
	cudaStream_t stream = NULL;
	cudaEvent_t event = NULL;
	float elapsed = 0.0f;
	int blocks = 0;
	int grid = 0;
	struct cudaFuncAttributes attributes;

	(void)argc;
	(void)argv;

	/* The memory of the device. */
	CHECK_EQ(cudaMalloc(&pointer, 1024), cudaErrorNotSupported);
	CHECK(pointer == NULL);
	REASON_NAMES("cuMemAlloc");
	CHECK_EQ(cudaFree((void *)(uintptr_t)0x1000), cudaErrorNotSupported);
	REASON_NAMES("cuMemFree");
	CHECK_EQ(cudaMallocHost(&pointer, 1024), cudaErrorNotSupported);
	REASON_NAMES("cuMemHostAlloc");
	CHECK_EQ(cudaFreeHost((void *)(uintptr_t)0x1000), cudaErrorNotSupported);
	REASON_NAMES("cuMemHostFree");
	CHECK_EQ(cudaMemcpy(NULL, NULL, 0, cudaMemcpyDeviceToHost),
	    cudaErrorInvalidValue);
	CHECK_EQ(cudaMemcpy((void *)(uintptr_t)0x1000, (void *)(uintptr_t)0x2000,
	    16, cudaMemcpyDeviceToHost), cudaErrorNotSupported);
	REASON_NAMES("cuMemcpyDtoH");
	CHECK_EQ(cudaMemcpyAsync((void *)(uintptr_t)0x1000,
	    (void *)(uintptr_t)0x2000, 16, cudaMemcpyHostToDevice, 0),
	    cudaErrorNotSupported);
	REASON_NAMES("cuMemcpyHtoD");
	CHECK_EQ(cudaMemset((void *)(uintptr_t)0x1000, 0, 16),
	    cudaErrorNotSupported);
	REASON_NAMES("cuMemset");
	CHECK_EQ(cudaMemsetAsync((void *)(uintptr_t)0x1000, 0, 16, 0),
	    cudaErrorNotSupported);

	/* The streams and the events. */
	CHECK_EQ(cudaStreamCreate(NULL), cudaErrorInvalidValue);
	CHECK_EQ(cudaStreamCreate(&stream), cudaErrorNotSupported);
	REASON_NAMES("cuStreamCreate");
	CHECK_EQ(cudaStreamCreateWithFlags(&stream, cudaStreamNonBlocking),
	    cudaErrorNotSupported);
	CHECK_EQ(cudaStreamSynchronize(0), cudaErrorNotSupported);
	REASON_NAMES("cuStreamSynchronize");
	CHECK_EQ(cudaStreamQuery(0), cudaErrorNotSupported);
	CHECK_EQ(cudaStreamDestroy(0), cudaErrorInvalidResourceHandle);
	CHECK_EQ(cudaStreamDestroy((void *)(uintptr_t)0x1000),
	    cudaErrorInvalidResourceHandle);
	CHECK_EQ(cudaEventCreate(NULL), cudaErrorInvalidValue);
	CHECK_EQ(cudaEventCreate(&event), cudaErrorNotSupported);
	REASON_NAMES("cuEventCreate");
	CHECK_EQ(cudaEventCreateWithFlags(&event, cudaEventDisableTiming),
	    cudaErrorNotSupported);
	CHECK_EQ(cudaEventRecord(0, 0), cudaErrorInvalidResourceHandle);
	CHECK_EQ(cudaEventSynchronize(0), cudaErrorInvalidResourceHandle);
	CHECK_EQ(cudaEventQuery(0), cudaErrorInvalidResourceHandle);
	CHECK_EQ(cudaEventDestroy(0), cudaErrorInvalidResourceHandle);
	CHECK_EQ(cudaEventElapsedTime(&elapsed, 0, 0), cudaErrorInvalidResourceHandle);
	CHECK_EQ(cudaDeviceSynchronize(), cudaErrorNotSupported);
	REASON_NAMES("cuCtxSynchronize");

	/* The kernels. */
	CHECK_EQ(cudaFuncGetAttributes(&attributes, NULL), cudaErrorInvalidValue);
	CHECK_EQ(cudaFuncGetAttributes(&attributes, (void *)(uintptr_t)0x1000),
	    cudaErrorInvalidResourceHandle);
	CHECK_EQ(cudaFuncSetAttribute((void *)(uintptr_t)0x1000,
	    cudaFuncAttributeMaxDynamicSharedMemorySize, 4096),
	    cudaErrorInvalidResourceHandle);
	CHECK_EQ(cudaOccupancyMaxActiveBlocksPerMultiprocessor(&blocks,
	    (void *)(uintptr_t)0x1000, 32, 0), cudaErrorInvalidResourceHandle);
	CHECK_EQ(cudaOccupancyMaxPotentialBlockSize(&grid, &blocks,
	    (void *)(uintptr_t)0x1000, 0), cudaErrorInvalidResourceHandle);

	/* A launch of a kernel the runtime never registered. */
	CHECK_EQ(cudaLaunchKernel(NULL, dim3_of(1, 1, 1), dim3_of(1, 1, 1), NULL, 0, 0),
	    cudaErrorInvalidValue);
	CHECK_EQ(cudaLaunchKernel((void *)(uintptr_t)0x1000, dim3_of(1, 1, 1), dim3_of(1, 1, 1),
	    NULL, 0, 0), cudaErrorInvalidValue);

	return (t_done("not-supported"));
}

/* A host-to-host copy is made by the runtime itself. */
static int
host_copy_mode(int argc, char **argv)
{
	char source[8] = "abcdefg";
	char destination[8];

	(void)argc;
	(void)argv;

	memset(destination, 0, sizeof(destination));
	CHECK_EQ(cudaMemcpy(destination, source, 7, cudaMemcpyHostToHost),
	    cudaSuccess);
	CHECK(memcmp(destination, source, 7) == 0);
	CHECK_EQ(cudaMemcpy(destination, source, 0, cudaMemcpyHostToHost),
	    cudaSuccess);
	/* Every other direction needs the driver. */
	CHECK_EQ(cudaMemcpy(destination, source, 7, cudaMemcpyDefault),
	    cudaErrorNotSupported);
	CHECK_EQ(cudaMemcpy(destination, source, 7, cudaMemcpyDeviceToDevice),
	    cudaErrorNotSupported);

	return (t_done("host-copy"));
}

/* A driver whose discovery is not implemented: every call that needs it
 * says so, and the reason names the provider. */
static int
driver_down_mode(int argc, char **argv)
{
	void *pointer = NULL;
	int count = 0;

	(void)argc;
	(void)argv;

	CHECK_EQ(cudaGetDeviceCount(&count), cudaErrorNotSupported);
	REASON_NAMES("not implemented");
	printf("reason=%s\n", cudaNativeLastFailureReason());
	CHECK_EQ(cudaMalloc(&pointer, 16), cudaErrorNotSupported);
	CHECK(pointer == NULL);
	REASON_NAMES("not implemented");
	CHECK_EQ(cudaSetDevice(0), cudaErrorNotSupported);

	return (t_done("driver-down"));
}

struct thread_case {
	const char *name;
	cudaError_t expected;
	int failed;
};

static void *
failing_thread(void *argument)
{
	struct thread_case *test = argument;

	/* A failure of this thread is its own. */
	CHECK_EQ(cudaGetLastError(), cudaSuccess);
	CHECK_EQ(cudaSetDevice(9), cudaErrorInvalidDevice);
	/* The reason of the failure is there before the error is read. */
	CHECK(cudaNativeLastFailureReason() != NULL);
	CHECK_EQ(cudaGetLastError(), cudaErrorInvalidDevice);
	/* The error is read once: the read clears it. */
	CHECK_EQ(cudaGetLastError(), cudaSuccess);
	/* The reason goes with the error. */
	CHECK(cudaNativeLastFailureReason() == NULL);
	/* The peek leaves it where it is. */
	CHECK_EQ(cudaSetDevice(9), cudaErrorInvalidDevice);
	CHECK_EQ(cudaPeekAtLastError(), cudaErrorInvalidDevice);
	CHECK_EQ(cudaPeekAtLastError(), cudaErrorInvalidDevice);
	CHECK(cudaNativeLastFailureReason() != NULL);
	CHECK_EQ(cudaGetLastError(), cudaErrorInvalidDevice);
	test->failed = 1;
	return (NULL);
}

static void *
clean_thread(void *argument)
{
	struct thread_case *test = argument;

	/* The failure of the other thread is not this thread's error. */
	CHECK_EQ(cudaPeekAtLastError(), cudaSuccess);
	CHECK(cudaNativeLastFailureReason() == NULL);
	/* A successful call does not clear the error of the thread either. */
	CHECK_EQ(cudaGetDeviceCount(NULL), cudaErrorInvalidValue);
	CHECK_EQ(cudaGetLastError(), cudaErrorInvalidValue);
	test->failed = 1;
	return (NULL);
}

static int
thread_errors_mode(int argc, char **argv)
{
	struct thread_case failing = { "failing", cudaErrorInvalidDevice, 0 };
	struct thread_case clean = { "clean", cudaSuccess, 0 };
	pthread_t one, two;

	(void)argc;
	(void)argv;

	/* The error of this thread is the one of the last failing call. */
	CHECK_EQ(cudaSetDevice(9), cudaErrorInvalidDevice);
	CHECK_EQ(cudaPeekAtLastError(), cudaErrorInvalidDevice);
	CHECK_EQ(cudaGetLastError(), cudaErrorInvalidDevice);
	CHECK_EQ(cudaPeekAtLastError(), cudaSuccess);

	CHECK_EQ(pthread_create(&one, NULL, failing_thread, &failing), 0);
	CHECK_EQ(pthread_create(&two, NULL, clean_thread, &clean), 0);
	CHECK_EQ(pthread_join(one, NULL), 0);
	CHECK_EQ(pthread_join(two, NULL), 0);
	CHECK_EQ(failing.failed, 1);
	CHECK_EQ(clean.failed, 1);

	return (t_done("thread-errors"));
}

static int
registration_mode(int argc, char **argv)
{
	struct fatbin_wrapper wrapper;
	void **handle = NULL;
	void **other = NULL;
	char name[256];
	char buffer[256];
	dim3 grid, block;
	size_t shared = 0;
	void *stream = NULL;
	unsigned count;
	unsigned members = 0;

	(void)argc;
	(void)argv;

	/* The registration contract of clang's CUDA mode. */
	wrapper.magic = FATBIN_WRAPPER_MAGIC;
	wrapper.version = 1;
	wrapper.data = fatbin_body;
	wrapper.unused = NULL;
	handle = __cudaRegisterFatBinary(&wrapper);
	CHECK(handle != NULL);
	CHECK_EQ(cudaNativeKernelCount(), 0);
	CHECK_EQ(cudaNativeFatBinaryCount(), 1);
	CHECK_EQ(cudaNativeFatBinaryMembers(0, &members), 1);
	CHECK_EQ(members, 1);

	/* A kernel of the fat binary. */
	CHECK_EQ(__cudaRegisterFunction(handle, (void *)(uintptr_t)0x1000,
	    "_Z4vaddPfS_Pfi", "vadd", 1024, NULL, NULL, NULL, NULL, NULL), 0);
	CHECK_EQ(cudaNativeKernelCount(), 1);
	CHECK_EQ(cudaNativeKernelName(0, name, sizeof(name)), 1);
	CHECK_STR(name, "vadd");
	/* The lookup by the host stub is how a launch finds its kernel. */
	CHECK_EQ(cudaNativeKernelHostStub((void *)(uintptr_t)0x1000, buffer,
	    sizeof(buffer)), 1);
	CHECK_STR(buffer, "vadd");
	CHECK_EQ(cudaNativeKernelHostStub((void *)(uintptr_t)0x2000, buffer,
	    sizeof(buffer)), 0);
	/* A buffer that cannot hold the whole name gets nothing. */
	CHECK_EQ(cudaNativeKernelHostStub((void *)(uintptr_t)0x1000, buffer, 2), 0);
	CHECK_EQ(cudaNativeKernelName(0, buffer, 2), 0);
	CHECK_EQ(cudaNativeKernelName(1, buffer, sizeof(buffer)), 0);

	/* A launch of a registered kernel stops at the limit of the driver. */
	{
		void *args[] = { NULL };

		CHECK_EQ(cudaLaunchKernel((void *)(uintptr_t)0x1000, dim3_of(1, 1, 1),
		    dim3_of(32, 1, 1), args, 0, 0), cudaErrorNotSupported);
		REASON_NAMES("cuLaunchKernel");
	}

	/* The configuration of a launch is per thread. */
	CHECK_EQ(__cudaPushCallConfiguration(dim3_of(2, 1, 1), dim3_of(32, 1, 1), 16,
	    (void *)(uintptr_t)0x1000), 0);
	memset(&grid, 0, sizeof(grid));
	memset(&block, 0, sizeof(block));
	CHECK_EQ(__cudaPopCallConfiguration(&grid, &block, &shared, &stream), 0);
	CHECK_EQ(grid.x, 2);
	CHECK_EQ(grid.y, 1);
	CHECK_EQ(grid.z, 1);
	CHECK_EQ(block.x, 32);
	CHECK_EQ(block.y, 1);
	CHECK_EQ(block.z, 1);
	CHECK_EQ(shared, 16);
	CHECK(stream == (void *)(uintptr_t)0x1000);

	/* A fat binary that is not ours is refused. */
	other = __cudaRegisterFatBinary(NULL);
	CHECK(other == NULL);
	wrapper.magic = 0;
	other = __cudaRegisterFatBinary(&wrapper);
	CHECK(other == NULL);
	wrapper.magic = FATBIN_WRAPPER_MAGIC;
	wrapper.data = "not a fat binary";
	other = __cudaRegisterFatBinary(&wrapper);
	CHECK(other == NULL);
	/* A refused fat binary is not a registration. */
	CHECK_EQ(cudaNativeFatBinaryCount(), 1);

	/* The variables, the surfaces and the textures of a module: the
	 * runtime holds none of them, and registering one changes
	 * nothing. */
	__cudaRegisterVar(handle, (void *)(uintptr_t)0x4000, "0x0", "var", 0, 4,
	    0, 1);
	__cudaRegisterManagedVar(handle, (void *)(uintptr_t)0x5000, "0x0",
	    "mvar", 4, 0);
	__cudaRegisterSurface(handle, (void *)(uintptr_t)0x6000, "0x0", "surf",
	    0, 0);
	__cudaRegisterTexture(handle, (void *)(uintptr_t)0x7000, "0x0", "tex",
	    0, 0, 0);
	CHECK_EQ(cudaNativeKernelCount(), 1);

	/* The end of a registration changes nothing. */
	__cudaRegisterFatBinaryEnd(handle);
	count = cudaNativeKernelCount();
	CHECK_EQ(count, 1);

	/* A second fat binary has its own kernels. */
	wrapper.data = fatbin_body;
	handle = __cudaRegisterFatBinary(&wrapper);
	CHECK(handle != NULL);
	CHECK_EQ(cudaNativeFatBinaryCount(), 2);
	CHECK_EQ(__cudaRegisterFunction(handle, (void *)(uintptr_t)0x3000,
	    "_Z4subfPfS_Pfi", "sub", 1024, NULL, NULL, NULL, NULL, NULL), 0);
	CHECK_EQ(cudaNativeKernelCount(), 2);
	CHECK_EQ(cudaNativeKernelName(1, name, sizeof(name)), 1);
	CHECK_STR(name, "sub");

	/* The end of the process takes the registrations away. */
	__cudaUnregisterFatBinary(handle);
	count = cudaNativeKernelCount();
	CHECK_EQ(count, 1);

	return (t_done("registration"));
}

static int
usage(void)
{
	fprintf(stderr, "usage: api_test MODE\n");
	fprintf(stderr, "modes: core devices not-supported host-copy "
	    "driver-down thread-errors registration\n");
	return (2);
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
		{ "devices", devices_mode },
		{ "not-supported", not_supported_mode },
		{ "host-copy", host_copy_mode },
		{ "driver-down", driver_down_mode },
		{ "thread-errors", thread_errors_mode },
		{ "registration", registration_mode }
	};
	size_t i;

	if (argc >= 2) {
		/* Time: O(modes); Space: O(1). */
		for (i = 0; i < sizeof(modes) / sizeof(modes[0]); i++)
			if (strcmp(argv[1], modes[i].name) == 0)
				return (modes[i].handler(argc, argv));
	}
	return (usage());
}

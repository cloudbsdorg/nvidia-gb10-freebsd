/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * cuda_mem_probe.c - the live check of the memory calls of libcuda for a
 * test boot: on every GPU the library enumerates (no index is assumed;
 * each line names the GPU by the name the library reports), create a
 * context, allocate video memory, copy a pattern into it, copy it back,
 * compare the bytes, fill the memory, free it and destroy the context.
 *
 * The copies are made by the CPU, through the mapping of the memory, so
 * the probe needs the driver and nothing else (no Linux layer).  With
 * CUDA_NATIVE_BACKEND=fake it runs on the synthetic devices (the suite
 * does that).
 *
 * Output: one line per step, "PASS gpu N (name) STEP: detail" or
 * "FAIL ...", for results.txt of the boot kit.  Exit status: the number of
 * FAIL lines (capped at 100); 101 when nothing could be enumerated.
 */
#include <sys/types.h>

#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <cuda.h>

#define PATTERN_BYTES (64 * 1024)

static int fails;
static char gpu_name[128];

static int
step(int ok, const char *what, const char *fmt, ...)
{
	va_list ap;

	printf("%s %s %s: ", ok ? "PASS" : "FAIL", gpu_name, what);
	va_start(ap, fmt);
	vprintf(fmt, ap);
	va_end(ap);
	printf("\n");
	fails += !ok;
	return (ok);
}

static void
fill(unsigned char *buffer, size_t bytes, unsigned seed)
{
	size_t i;

	for (i = 0; i < bytes; i++)
		buffer[i] = (unsigned char)(i * 131 + seed);
}

/* The name of the result, for the detail of a step. */
static const char *
result_name(CUresult result)
{
	const char *name = NULL;

	if (cuGetErrorName(result, &name) != CUDA_SUCCESS)
		return ("CUDA_ERROR_UNKNOWN");
	return (name);
}

/* #lizard forgives -- one live sequence, each step depends on the last */
static void
probe(CUdevice device)
{
	CUcontext context = NULL;
	CUdeviceptr pointer = 0;
	unsigned char pattern[PATTERN_BYTES], readback[PATTERN_BYTES];
	size_t free_bytes = 0, total_bytes = 0;
	CUresult result;

	result = cuCtxCreate(&context, CU_CTX_SCHED_AUTO, device);
	if (!step(result == CUDA_SUCCESS, "ctx_create", "%s",
	    result == CUDA_SUCCESS ? "a context with its own RM client" :
	    result_name(result)))
		return;
	result = cuCtxSetCurrent(context);
	if (!step(result == CUDA_SUCCESS, "ctx_set_current", "%s",
	    result_name(result)))
		goto out;
	result = cuMemAlloc(&pointer, 1024 * 1024);
	if (!step(result == CUDA_SUCCESS, "mem_alloc", "%s",
	    result == CUDA_SUCCESS ? "1 MiB of video memory" :
	    result_name(result)))
		goto out;
	result = cuMemGetInfo(&free_bytes, &total_bytes);
	step(result == CUDA_SUCCESS && total_bytes > 0, "mem_get_info",
	    "%s: total %zu bytes, free %zu bytes",
	    result == CUDA_SUCCESS ? "the device memory" : result_name(result),
	    total_bytes, free_bytes);
	/* The copy in. */
	fill(pattern, sizeof(pattern), 7);
	result = cuMemcpyHtoD(pointer, pattern, sizeof(pattern));
	step(result == CUDA_SUCCESS, "memcpy_htod", "%s",
	    result == CUDA_SUCCESS ? "64 KiB written" : result_name(result));
	/* The copy out and the comparison. */
	memset(readback, 0, sizeof(readback));
	result = cuMemcpyDtoH(readback, pointer, sizeof(readback));
	step(result == CUDA_SUCCESS && memcmp(pattern, readback,
	    sizeof(pattern)) == 0, "memcpy_dtoh", "%s",
	    result != CUDA_SUCCESS ? result_name(result) :
	    memcmp(pattern, readback, sizeof(pattern)) == 0 ?
	    "64 KiB read back, the bytes are equal" :
	    "64 KiB read back, the bytes differ");
	/* The fill and its reading back. */
	result = cuMemsetD8(pointer, 0x5A, sizeof(pattern));
	memset(readback, 0, sizeof(readback));
	if (result == CUDA_SUCCESS)
		result = cuMemcpyDtoH(readback, pointer, sizeof(readback));
	step(result == CUDA_SUCCESS && readback[0] == 0x5A &&
	    readback[sizeof(readback) - 1] == 0x5A, "memset_d8", "%s",
	    result != CUDA_SUCCESS ? result_name(result) :
	    "64 KiB filled with 0x5a and read back");
	/* The free. */
	result = cuMemFree(pointer);
	step(result == CUDA_SUCCESS, "mem_free", "%s",
	    result == CUDA_SUCCESS ? "the allocation is gone" :
	    result_name(result));
out:
	result = cuCtxDestroy(context);
	step(result == CUDA_SUCCESS, "ctx_destroy", "%s",
	    result == CUDA_SUCCESS ? "the context and its RM client are gone" :
	    result_name(result));
}

int
main(void)
{
	CUdevice device = -1;
	char name[128];
	int count = -1, ordinal;

	setvbuf(stdout, NULL, _IOLBF, 0);
	if (cuInit(0) != CUDA_SUCCESS) {
		printf("FAIL enumerate: %s (%s)\n",
		    result_name(cuInit(0)), cudaNativeFailureReason());
		return (101);
	}
	if (cuDeviceGetCount(&count) != CUDA_SUCCESS) {
		printf("FAIL enumerate: %s\n", result_name(cuDeviceGetCount(&count)));
		return (101);
	}
	printf("INFO backend %s, %d GPU(s)\n", cudaNativeGetBackendName(), count);
	if (count == 0) {
		printf("FAIL enumerate: no GPU\n");
		return (101);
	}
	for (ordinal = 0; ordinal < count; ordinal++) {
		if (cuDeviceGet(&device, ordinal) != CUDA_SUCCESS)
			continue;
		name[0] = '\0';
		if (cuDeviceGetName(name, sizeof(name), device) != CUDA_SUCCESS)
			snprintf(name, sizeof(name), "unknown");
		snprintf(gpu_name, sizeof(gpu_name), "gpu %d (%s)", ordinal, name);
		probe(device);
	}
	return (fails > 100 ? 100 : fails);
}

/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-3-Clause
 *
 * cuda_smoke.c - CUDA context, 64 MiB allocation, HtoD/DtoH copy and verify.
 */
/* CUDA driver API smoke test via dlopen("libcuda.so.1"). */
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
typedef int CUresult; typedef int CUdevice; typedef void *CUcontext; typedef unsigned long long CUdeviceptr;
#define LOAD(n) do { *(void **)&n = dlsym(h, #n); if (!n) { fprintf(stderr, "no %s\n", #n); return 2; } } while (0)
#define CK(x) do { CUresult r_ = (x); printf("%-28s rc=%d\n", #x, r_); if (r_) return 1; } while (0)
int main(void)
{
	void *h = dlopen("libcuda.so.1", RTLD_NOW);
	CUresult (*cuInit)(unsigned), (*cuDeviceGetCount)(int *), (*cuDeviceGet)(CUdevice *, int),
	    (*cuDeviceGetName)(char *, int, CUdevice), (*cuDeviceTotalMem_v2)(size_t *, CUdevice),
	    (*cuCtxCreate_v2)(CUcontext *, unsigned, CUdevice), (*cuMemAlloc_v2)(CUdeviceptr *, size_t),
	    (*cuMemcpyHtoD_v2)(CUdeviceptr, const void *, size_t), (*cuMemcpyDtoH_v2)(void *, CUdeviceptr, size_t),
	    (*cuMemFree_v2)(CUdeviceptr), (*cuCtxDestroy_v2)(CUcontext);
	int n = 0; CUdevice dev; char name[256] = ""; size_t tot = 0; CUcontext ctx; CUdeviceptr d;
	size_t sz = 64u << 20, i; uint32_t *a, *b;
	if (!h) { fprintf(stderr, "dlopen: %s\n", dlerror()); return 2; }
	LOAD(cuInit); LOAD(cuDeviceGetCount); LOAD(cuDeviceGet); LOAD(cuDeviceGetName); LOAD(cuDeviceTotalMem_v2);
	LOAD(cuCtxCreate_v2); LOAD(cuMemAlloc_v2); LOAD(cuMemcpyHtoD_v2); LOAD(cuMemcpyDtoH_v2); LOAD(cuMemFree_v2); LOAD(cuCtxDestroy_v2);
	CK(cuInit(0));
	CK(cuDeviceGetCount(&n)); printf("devices: %d\n", n); if (n < 1) return 1;
	CK(cuDeviceGet(&dev, 0));
	CK(cuDeviceGetName(name, sizeof(name), dev)); printf("name: %s\n", name);
	CK(cuDeviceTotalMem_v2(&tot, dev)); printf("total mem: %zu MiB\n", tot >> 20);
	CK(cuCtxCreate_v2(&ctx, 0, dev));
	CK(cuMemAlloc_v2(&d, sz));
	a = malloc(sz); b = calloc(1, sz);
	for (i = 0; i < sz / 4; i++) a[i] = (uint32_t)(i * 2654435761u);
	CK(cuMemcpyHtoD_v2(d, a, sz));
	CK(cuMemcpyDtoH_v2(b, d, sz));
	if (memcmp(a, b, sz) != 0) { puts("VERIFY FAIL"); return 1; }
	puts("VERIFY OK (64 MiB pattern round trip)");
	cuMemFree_v2(d); cuCtxDestroy_v2(ctx);
	return 0;
}

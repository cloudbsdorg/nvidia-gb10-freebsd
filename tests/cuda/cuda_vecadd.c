/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-3-Clause
 *
 * cuda_vecadd.c - PTX vectorAdd launch and a deviceQuery-lite, via libcuda.so.1.
 */
/* CUDA driver API vectorAdd via dlopen("libcuda.so.1"), hand-written PTX. */
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <math.h>
typedef int CUresult; typedef int CUdevice; typedef void *CUcontext, *CUmodule, *CUfunction, *CUstream;
typedef unsigned long long CUdeviceptr;
#define LOAD(n) do { *(void **)&n = dlsym(h, #n); if (!n) { fprintf(stderr, "no %s\n", #n); return 2; } } while (0)
#define CK(x) do { CUresult r_ = (x); printf("%-34s rc=%d\n", #x, r_); fflush(stdout); if (r_) return 1; } while (0)
#define N (1 << 20)
#ifndef PTX_TARGET
#define PTX_TARGET "sm_120"
#endif
#ifndef PTX_VER
#define PTX_VER "8.7"
#endif
static const char ptx[] =
".version " PTX_VER "\n.target " PTX_TARGET "\n.address_size 64\n"
".visible .entry vectorAdd(.param .u64 pa, .param .u64 pb, .param .u64 pc, .param .u32 pn)\n{\n"
"  .reg .pred p;\n  .reg .b32 r<6>;\n  .reg .b64 rd<11>;\n  .reg .f32 f<4>;\n"
"  ld.param.u64 rd1, [pa];\n  ld.param.u64 rd2, [pb];\n  ld.param.u64 rd3, [pc];\n  ld.param.u32 r1, [pn];\n"
"  mov.u32 r2, %ctaid.x;\n  mov.u32 r3, %ntid.x;\n  mov.u32 r4, %tid.x;\n"
"  mad.lo.s32 r5, r2, r3, r4;\n  setp.ge.s32 p, r5, r1;\n  @p bra DONE;\n"
"  cvta.to.global.u64 rd4, rd1;\n  cvta.to.global.u64 rd5, rd2;\n  cvta.to.global.u64 rd6, rd3;\n"
"  mul.wide.s32 rd7, r5, 4;\n  add.s64 rd8, rd4, rd7;\n  add.s64 rd9, rd5, rd7;\n  add.s64 rd10, rd6, rd7;\n"
"  ld.global.f32 f1, [rd8];\n  ld.global.f32 f2, [rd9];\n  add.f32 f3, f1, f2;\n  st.global.f32 [rd10], f3;\n"
"DONE:\n  ret;\n}\n";
int main(int argc, char **argv)
{
	void *h = dlopen("libcuda.so.1", RTLD_NOW);
	if (!h) { fprintf(stderr, "dlopen: %s\n", dlerror()); return 2; }
	CUresult (*cuInit)(unsigned), (*cuDeviceGet)(CUdevice *, int), (*cuDeviceGetName)(char *, int, CUdevice),
	    (*cuDeviceGetAttribute)(int *, int, CUdevice), (*cuCtxCreate_v2)(CUcontext *, unsigned, CUdevice),
	    (*cuModuleLoadDataEx)(CUmodule *, const void *, unsigned, int *, void **),
	    (*cuModuleGetFunction)(CUfunction *, CUmodule, const char *),
	    (*cuMemAlloc_v2)(CUdeviceptr *, size_t), (*cuMemFree_v2)(CUdeviceptr),
	    (*cuMemAllocManaged)(CUdeviceptr *, size_t, unsigned),
	    (*cuMemcpyHtoD_v2)(CUdeviceptr, const void *, size_t), (*cuMemcpyDtoH_v2)(void *, CUdeviceptr, size_t),
	    (*cuLaunchKernel)(CUfunction, unsigned, unsigned, unsigned, unsigned, unsigned, unsigned, unsigned, CUstream, void **, void **),
	    (*cuCtxSynchronize)(void), (*cuCtxDestroy_v2)(CUcontext);
	LOAD(cuInit); LOAD(cuDeviceGet); LOAD(cuDeviceGetName); LOAD(cuDeviceGetAttribute); LOAD(cuCtxCreate_v2);
	LOAD(cuModuleLoadDataEx); LOAD(cuModuleGetFunction); LOAD(cuMemAlloc_v2); LOAD(cuMemFree_v2); LOAD(cuMemAllocManaged);
	LOAD(cuMemcpyHtoD_v2); LOAD(cuMemcpyDtoH_v2); LOAD(cuLaunchKernel); LOAD(cuCtxSynchronize); LOAD(cuCtxDestroy_v2);
	int managed = argc > 1 && !strcmp(argv[1], "managed");
	CUdevice dev; CUcontext ctx; CUmodule mod; CUfunction fn; char name[128];
	CK(cuInit(0)); CK(cuDeviceGet(&dev, 0));
	CK(cuDeviceGetName(name, sizeof(name), dev)); printf("name: %s\n", name);
	static const struct { int id; const char *n; } at[] = {
	    {75, "cc_major"}, {76, "cc_minor"}, {16, "sm_count"}, {13, "clock_khz"}, {36, "mem_clock_khz"},
	    {37, "bus_width"}, {1, "max_threads_block"}, {8, "smem_per_block"}, {39, "l2_bytes"}, {83, "managed_mem"}, {89, "concurrent_managed"} };
	for (unsigned i = 0; i < sizeof at / sizeof at[0]; i++) {
		int v = -1; CUresult r = cuDeviceGetAttribute(&v, at[i].id, dev);
		printf("attr %-20s = %d (rc=%d)\n", at[i].n, v, r);
	}
	CK(cuCtxCreate_v2(&ctx, 0, dev));
	char elog[8192] = "", ilog[8192] = "";
	int opts[] = { 4 /*ERROR_LOG_BUFFER_SIZE_BYTES*/, 3 /*ERROR_LOG_BUFFER*/, 6 /*INFO_LOG_BUFFER_SIZE*/, 5 /*INFO_LOG_BUFFER*/ };
	void *vals[] = { (void *)(uintptr_t)sizeof elog, elog, (void *)(uintptr_t)sizeof ilog, ilog };
	/* option ids: 5=INFO_LOG_BUFFER 6=INFO_LOG_BUFFER_SIZE_BYTES 3=ERROR_LOG_BUFFER 4=ERROR_LOG_BUFFER_SIZE_BYTES */
	CUresult r = cuModuleLoadDataEx(&mod, ptx, 4, opts, vals);
	printf("%-34s rc=%d\nJIT error log: [%s]\nJIT info log: [%s]\n", "cuModuleLoadDataEx", r, elog, ilog);
	if (r) return 1;
	CK(cuModuleGetFunction(&fn, mod, "vectorAdd"));
	size_t sz = (size_t)N * sizeof(float);
	float *a = malloc(sz), *b = malloc(sz), *c = calloc(1, sz);
	for (int i = 0; i < N; i++) { a[i] = (float)i; b[i] = (float)(2 * i + 1); }
	CUdeviceptr da, db, dc; int n = N;
	if (!managed) {
		CK(cuMemAlloc_v2(&da, sz)); CK(cuMemAlloc_v2(&db, sz)); CK(cuMemAlloc_v2(&dc, sz));
		CK(cuMemcpyHtoD_v2(da, a, sz)); CK(cuMemcpyHtoD_v2(db, b, sz));
	} else {
		CK(cuMemAllocManaged(&da, sz, 1)); CK(cuMemAllocManaged(&db, sz, 1)); CK(cuMemAllocManaged(&dc, sz, 1));
		memcpy((void *)da, a, sz); memcpy((void *)db, b, sz); memset((void *)dc, 0, sz);
		printf("CPU wrote managed buffers\n"); fflush(stdout);
	}
	void *args[] = { &da, &db, &dc, &n };
	CK(cuLaunchKernel(fn, (N + 255) / 256, 1, 1, 256, 1, 1, 0, NULL, args, NULL));
	CK(cuCtxSynchronize());
	if (!managed) CK(cuMemcpyDtoH_v2(c, dc, sz)); else memcpy(c, (void *)dc, sz);
	int bad = 0;
	for (int i = 0; i < N; i++) if (c[i] != a[i] + b[i]) { if (bad++ < 5) printf("mismatch %d: %f vs %f\n", i, c[i], a[i] + b[i]); }
	printf("vecadd %s: %d mismatches of %d\n", bad ? "FAIL" : "PASS", bad, N);
	cuMemFree_v2(da); cuMemFree_v2(db); cuMemFree_v2(dc); cuCtxDestroy_v2(ctx);
	return bad != 0;
}

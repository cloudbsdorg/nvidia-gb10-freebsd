// Copyright (c) 2026 REVYTECH, Inc.
// SPDX-License-Identifier: BSD-2-Clause
//
// launch_libcudart.cu - the registration contract of clang's CUDA mode,
// against the native runtime in lib/libcudart.  The program is compiled by
// clang -x cuda with this SDK as its CUDA path: the device code is
// offloaded to PTX and never runs.  The host side registers the fat binary
// and the kernel, looks the kernel up by its host stub, and launches it.
// The launch stops at the limit of libcuda and says so.

#include <stdio.h>

#include <cuda_runtime.h>

__global__ void vadd(const float *a, const float *b, float *c, int n)
{
	int i = blockIdx.x * blockDim.x + threadIdx.x;

	if (i < n)
		c[i] = a[i] + b[i];
}

int main(void)
{
	float host_a = 1.0f, host_b = 2.0f, host_c = 0.0f;
	const float *a = &host_a, *b = &host_b;
	float *c = &host_c;
	int n = 1;
	void *args[] = { &a, &b, &c, &n };
	char name[256];
	cudaError_t status;
	int found;

	/* The <<<>>> path: clang pushes the configuration, the host stub pops
	 * it and launches. */
	vadd<<<1, 32>>>(a, b, c, n);

	/* The direct path: the same launch, named by the host stub. */
	status = cudaLaunchKernel((const void *)vadd, dim3(1), dim3(32), args, 0,
	    0);

	/* The registration contract: the fat binary registered its kernel and
	 * the kernel is found by the host stub a launch names. */
	found = cudaNativeKernelHostStub((const void *)vadd, name, sizeof(name));
	printf("kernels=%u\n", cudaNativeKernelCount());
	printf("found=%d\n", found);
	printf("name=%s\n", found == 1 ? name : "");
	printf("launch=%d\n", (int)status);
	printf("reason=%s\n", cudaNativeLastFailureReason());
	return (status == cudaErrorNotSupported ? 0 : 1);
}

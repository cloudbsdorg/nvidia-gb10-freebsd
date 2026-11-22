// Copyright (c) 2026 REVYTECH, Inc.
// SPDX-License-Identifier: BSD-2-Clause
//
// launch_main.cu - link and run against the cuda-native libcudart stub.
// The <<<>>> launch exercises clang's push/pop path.  The direct call makes
// the stub's result observable without claiming that a kernel ran.

#include <stdio.h>

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
	cudaError_t status;

	vadd<<<1, 32>>>(a, b, c, n);
	status = cudaLaunchKernel((const void *)vadd, dim3(1), dim3(32), args, 0, 0);
	printf("launch=%d\n", (int)status);
	return status == cudaErrorNotSupported ? 0 : 1;
}

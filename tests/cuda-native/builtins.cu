// Copyright (c) 2026 REVYTECH, Inc.
// SPDX-License-Identifier: BSD-2-Clause
//
// builtins.cu - cuda-native toolchain test input (Track #2380): the builtin
// variables, shared memory, a barrier, atomics and a warp shuffle.

__global__ void builtins_kernel(const float *in, int *icount, float *fsum)
{
	__shared__ float tile[256];
	unsigned int t = threadIdx.x;
	unsigned int g = blockIdx.x * blockDim.x + t;
	float v;

	tile[t % 256] = in[g];
	__syncthreads();
	v = tile[(t + 1) % 256];
	v += __shfl_down_sync(0xffffffffu, v, 16);
	if (t % warpSize == 0) {
		atomicAdd(icount, (int)gridDim.x);
		atomicAdd(fsum, v);
	}
}

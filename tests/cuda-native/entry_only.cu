// Copyright (c) 2026 REVYTECH, Inc.
// SPDX-License-Identifier: BSD-2-Clause
//
// entry_only.cu - cuda-native toolchain test input (Track #2380): one kernel
// that uses nothing but plain C++, so it still compiles when __global__ is
// emptied; the test then expects the kernel entry to be gone.

__global__ void entry_only(int *p)
{
	*p = 1;
}

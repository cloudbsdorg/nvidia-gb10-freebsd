/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 */
#include <cuda.h>

static_assert(CUDA_VERSION == 13000, "CUDA ABI version changed");
static_assert(CUDA_NATIVE_VERSION == 100, "native version changed");
static_assert(sizeof(CUuuid) == 16, "UUID ABI size changed");

int
main()
{
	CUcontext context = nullptr;
	return (cuCtxGetCurrent(&context) == CUDA_ERROR_NOT_INITIALIZED ? 0 : 1);
}

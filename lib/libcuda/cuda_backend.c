/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 */
#include <stdlib.h>

#include "cuda_internal.h"

/* The provider the library selects when the environment names none. */
static const char *const default_backend = "nvrm";

const char *
cudaNativeGetBackendName(void)
{
	const char *backend = getenv("CUDA_NATIVE_BACKEND");

	return (backend != NULL ? backend : default_backend);
}

const char *
cudaNativeDefaultBackend(void)
{
	return (default_backend);
}

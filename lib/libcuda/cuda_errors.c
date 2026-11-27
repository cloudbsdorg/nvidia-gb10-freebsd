/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 */
#include <stddef.h>
#include <stdio.h>

#include "cuda_internal.h"

typedef struct error_text {
	CUresult result;
	const char *name;
	const char *description;
} error_text;

static const error_text errors[] = {
	{ CUDA_SUCCESS, "CUDA_SUCCESS", "The operation completed successfully." },
	{ CUDA_ERROR_INVALID_VALUE, "CUDA_ERROR_INVALID_VALUE",
	    "An argument or option has an invalid value." },
	{ CUDA_ERROR_OUT_OF_MEMORY, "CUDA_ERROR_OUT_OF_MEMORY",
	    "The operation could not allocate enough memory." },
	{ CUDA_ERROR_NOT_INITIALIZED, "CUDA_ERROR_NOT_INITIALIZED",
	    "The driver has not been initialized with cuInit." },
	{ CUDA_ERROR_DEINITIALIZED, "CUDA_ERROR_DEINITIALIZED",
	    "The driver is shutting down." },
	{ CUDA_ERROR_NO_DEVICE, "CUDA_ERROR_NO_DEVICE",
	    "No usable compute device is available." },
	{ CUDA_ERROR_INVALID_DEVICE, "CUDA_ERROR_INVALID_DEVICE",
	    "The device ordinal or handle is not valid." },
	{ CUDA_ERROR_INVALID_CONTEXT, "CUDA_ERROR_INVALID_CONTEXT",
	    "The context is absent, inactive, or not valid." },
	{ CUDA_ERROR_NOT_FOUND, "CUDA_ERROR_NOT_FOUND",
	    "The requested symbol or object was not found." },
	{ CUDA_ERROR_NOT_SUPPORTED, "CUDA_ERROR_NOT_SUPPORTED",
	    "The requested operation is not supported by this provider." },
	{ CUDA_ERROR_UNKNOWN, "CUDA_ERROR_UNKNOWN",
	    "The driver reported an unknown error." }
};

static const error_text *
find_error(CUresult result)
{
	size_t i;

	for (i = 0; i < sizeof(errors) / sizeof(errors[0]); i++)
		if (errors[i].result == result)
			return (&errors[i]);
	return (NULL);
}

CUresult
cuGetErrorName(CUresult error, const char **pStr)
{
	const error_text *entry;

	if (pStr == NULL)
		return (CUDA_ERROR_INVALID_VALUE);
	entry = find_error(error);
	if (entry == NULL) {
		*pStr = NULL;
		return (CUDA_ERROR_INVALID_VALUE);
	}
	*pStr = entry->name;
	return (CUDA_SUCCESS);
}

CUresult
cuGetErrorString(CUresult error, const char **pStr)
{
	const error_text *entry;

	if (pStr == NULL)
		return (CUDA_ERROR_INVALID_VALUE);
	entry = find_error(error);
	if (entry == NULL) {
		*pStr = NULL;
		return (CUDA_ERROR_INVALID_VALUE);
	}
	*pStr = entry->description;
	return (CUDA_SUCCESS);
}

/* The reason of the last failure of the calling thread.  It is per thread:
 * a failure in one thread never names the failure of another one, and a
 * thread that never failed has no reason. */
static __thread char failure_reason[256];

void
cuda_reason_set(const char *text)
{
	if (text == NULL) {
		failure_reason[0] = '\0';
		return;
	}
	snprintf(failure_reason, sizeof(failure_reason), "%s", text);
}

void
cuda_reason_clear(void)
{
	failure_reason[0] = '\0';
}

const char *
cudaNativeFailureReason(void)
{
	return (failure_reason);
}

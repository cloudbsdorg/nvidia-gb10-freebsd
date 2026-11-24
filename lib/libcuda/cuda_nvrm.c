/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The NVRM provider is a deliberate boundary in cuda-native 0.1.0.  It opens
 * no device and makes no ioctl: enumeration reports that native NVRM discovery
 * is not implemented yet.
 */
#include "cuda_internal.h"

static CUresult
nvrm_enumerate(unsigned *count)
{
	if (count == NULL)
		return (CUDA_ERROR_INVALID_VALUE);
	return (CUDA_ERROR_NOT_SUPPORTED);
}

static CUresult
nvrm_name(unsigned index, char *name, int len)
{
	(void)index;
	(void)name;
	(void)len;
	return (CUDA_ERROR_NOT_SUPPORTED);
}

static CUresult
nvrm_uuid(unsigned index, CUuuid *uuid)
{
	(void)index;
	(void)uuid;
	return (CUDA_ERROR_NOT_SUPPORTED);
}

static CUresult
nvrm_memory(unsigned index, size_t *bytes)
{
	(void)index;
	(void)bytes;
	return (CUDA_ERROR_NOT_SUPPORTED);
}

static CUresult
nvrm_attribute(unsigned index, CUdevice_attribute attribute, int *value)
{
	(void)index;
	(void)attribute;
	(void)value;
	return (CUDA_ERROR_NOT_SUPPORTED);
}

/* This provider is the native kind: it takes no fake profile, and its
 * discovery is not implemented in this release. */
const cuda_provider cuda_nvrm_provider = {
	.backend = "nvrm",
	.kind = CUDA_PROVIDER_NATIVE,
	.enumerate = nvrm_enumerate,
	.name = nvrm_name,
	.uuid = nvrm_uuid,
	.memory = nvrm_memory,
	.attribute = nvrm_attribute
};

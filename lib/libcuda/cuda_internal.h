/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 */
#ifndef CUDA_NATIVE_INTERNAL_H_
#define CUDA_NATIVE_INTERNAL_H_

#include <stddef.h>
#include <stdint.h>

#include <cuda.h>

#define CUDA_NATIVE_MAX_DEVICES 64
#define CUDA_NATIVE_VERSION_TEXT_MAX 255
#define CUDA_NATIVE_CONTEXT_MAGIC 0x43545831U

typedef struct cuda_native_version {
	int available;
	char string[512];
	uint32_t major;
	uint32_t minor;
	uint32_t patch;
	char suffix[256];
	const char *reason;
} cuda_native_version;

typedef struct cuda_device_ops cuda_device_ops;
typedef cuda_device_ops cuda_provider;
typedef struct cuda_device cuda_device;

struct CUctx_st {
	unsigned magic;
	unsigned references;
	cuda_device *device;
};

struct cuda_device {
	const cuda_provider *provider;
	unsigned physical_index;
	struct CUctx_st *primary;
	struct CUctx_st primary_state;
};

struct cuda_device_ops {
	const char *backend;
	CUresult (*enumerate)(unsigned *count);
	CUresult (*name)(unsigned index, char *name, int len);
	CUresult (*uuid)(unsigned index, CUuuid *uuid);
	CUresult (*memory)(unsigned index, size_t *bytes);
	CUresult (*attribute)(unsigned index, CUdevice_attribute attribute,
	    int *value);
};

extern const cuda_provider cuda_fake_provider;
extern const cuda_provider cuda_nvrm_provider;

CUresult cuda_registry_initialize(void);
CUresult cuda_registry_result(void);
unsigned cuda_registry_count(void);
cuda_device *cuda_registry_get(CUdevice device);
CUdevice cuda_registry_ordinal(const cuda_device *device);
void *cuda_registry_current_get(void);
CUresult cuda_registry_current_set(void *context);
CUresult cuda_registry_primary_retain(CUcontext *context,
    cuda_device *device);
CUresult cuda_registry_primary_release(cuda_device *device);

const char *cuda_default_backend(void);
int cuda_version_parse(cuda_native_version *version, const char *raw);
int cuda_version_make(cuda_native_version *version, uint32_t major,
    uint32_t minor, uint32_t patch, unsigned parts);
int cuda_version_format(const cuda_native_version *version, char *output,
    size_t output_size);
void cuda_uuid_text(const CUuuid *uuid, char text[41]);

#endif

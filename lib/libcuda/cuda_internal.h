/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 */
#ifndef CUDA_NATIVE_INTERNAL_H_
#define CUDA_NATIVE_INTERNAL_H_

#include <stddef.h>
#include <stdint.h>

#include <cuda.h>

/* The number of devices the library exposes at once.  The limit counts the
 * visible devices, the selected ones.  A provider may report more devices
 * than the limit; the ones that no filter selects are not exposed.  Without
 * a filter the visible set is every provider device, so a provider that
 * reports more devices than the limit is an invalid value. */
#define CUDA_NATIVE_MAX_DEVICES 64
/* The number of provider devices the registry can hold.  This is a buffer
 * bound, not the policy limit: a provider may report more devices than the
 * library exposes, and a visibility list may then name more distinct devices
 * than the library exposes. */
#define CUDA_NATIVE_MAX_PHYSICAL_DEVICES 128
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
typedef struct cuda_context cuda_context;
typedef struct cuda_mem_ops cuda_mem_ops;

/* The kind of a provider.  The kind is the one fact about a provider: it
 * decides whether the provider takes the fake profiles named by
 * CUDA_NATIVE_FAKE_PROFILE, and only the synthetic kind applies them. */
enum cuda_provider_kind {
	/* A provider of synthetic devices, driven by the fake profiles. */
	CUDA_PROVIDER_SYNTHETIC,
	/* A provider of real devices: it discovers them through the
	 * resource manager and opens no device of its own. */
	CUDA_PROVIDER_NATIVE
};

struct CUctx_st {
	unsigned magic;
	unsigned references;
	cuda_device *device;
	/* What the provider holds for this context: an RM client and a
	 * device for the nvrm provider, a synthetic model for the fake
	 * one.  It is null when the provider has no memory backend. */
	void *provider_context;
};

struct cuda_device {
	const cuda_provider *provider;
	unsigned physical_index;
	struct CUctx_st primary_state;
};

/*
 * What a provider's memory backend offers.  The shared code owns the CUDA
 * contract; the provider owns the memory: the nvrm provider asks the
 * resource manager for video and system memory, the fake provider makes
 * its own.  A provider without this table answers no memory call: the
 * library then reports CUDA_ERROR_NOT_SUPPORTED with a reason.
 */
struct cuda_mem_ops {
	/* One context: the provider opens what the context needs (the nvrm
	 * provider opens an RM client for the device of the context). */
	CUresult (*context_create)(unsigned index, void **context);
	CUresult (*context_destroy)(void *context);
	/* A device allocation: memory the GPU addresses.  The device
	 * pointer is the address the GPU knows the memory by. */
	CUresult (*device_alloc)(void *context, size_t bytes, void **object,
	    uint64_t *device_ptr);
	CUresult (*device_free)(void *object);
	/* A host allocation: system memory the caller writes to.  The host
	 * address is the address the caller writes at. */
	CUresult (*host_alloc)(void *context, size_t bytes, void **object,
	    void **host_address, uint64_t *device_ptr);
	CUresult (*host_free)(void *object);
	/* Read and write the memory of an object, by the CPU. */
	CUresult (*read)(void *object, uint64_t offset, void *buffer,
	    size_t bytes);
	CUresult (*write)(void *object, uint64_t offset, const void *buffer,
	    size_t bytes);
	/* The memory of the device the context belongs to. */
	CUresult (*info)(void *context, size_t *free_bytes, size_t *total_bytes);
};

/* A context the caller created with cuCtxCreate.  The public handle is the
 * CUctx_st inside it. */
struct cuda_context {
	struct CUctx_st state;
	struct cuda_context *next;
};

/* One allocation of a context: the device pointer the caller holds, the
 * provider's object behind it and the CPU view of a host allocation. */
typedef struct cuda_allocation {
	CUdeviceptr device_ptr;
	void *object;
	void *host_address;
	size_t bytes;
	int host;
	struct CUctx_st *context;
	struct cuda_allocation *next;
} cuda_allocation;

struct cuda_device_ops {
	const char *backend;
	/* The kind of the provider: it is the one fact about a provider.
	 * The registry applies the profile selection under this kind, and
	 * the library reports the capability from it, so the capability and
	 * the handling cannot disagree. */
	enum cuda_provider_kind kind;
	/* The provider applies the profile selection the registry hands it:
	 * the comma-separated list of profile names, or null when the
	 * environment names none.  A provider that takes no profile has no
	 * selection call. */
	CUresult (*select)(const char *list);
	CUresult (*enumerate)(unsigned *count);
	CUresult (*name)(unsigned index, char *name, int len);
	CUresult (*uuid)(unsigned index, CUuuid *uuid);
	CUresult (*memory)(unsigned index, size_t *bytes);
	CUresult (*attribute)(unsigned index, CUdevice_attribute attribute,
	    int *value);
	/* The memory backend of the provider, or null when it has none. */
	const cuda_mem_ops *mem;
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
/* A context the caller created with cuCtxCreate. */
CUresult cuda_registry_context_create(cuda_device *device,
    void *provider_context, CUcontext *context);
CUresult cuda_registry_context_destroy(CUcontext context);
/* The provider context of a context, or null when it has none. */
void *cuda_registry_context_provider(CUcontext context);
/* The device a context belongs to, or null. */
cuda_device *cuda_registry_context_device(CUcontext context);
/* The allocations of the contexts.  The registry owns them: it knows which
 * context an allocation belongs to, and it frees them when the context
 * goes away. */
CUresult cuda_registry_allocate(struct CUctx_st *context, int host,
    size_t bytes, cuda_allocation **allocation);
cuda_allocation *cuda_registry_find(CUdeviceptr device_ptr);
/* The allocation whose range holds a device address. */
cuda_allocation *cuda_registry_find_at(CUdeviceptr pointer);
/* The host allocation of a host address. */
cuda_allocation *cuda_registry_find_host(void *address);
/* Take an allocation out of the registry.  The caller owns it afterwards
 * and frees it with the provider. */
cuda_allocation *cuda_registry_take(CUdeviceptr device_ptr);
/* Free an allocation with the provider it came from. */
void cuda_registry_free_allocation(cuda_allocation *entry);

/* The reason of the last failure of the calling thread.  A failure that
 * names no reason leaves the reason of the thread as it was. */
void cuda_reason_set(const char *text);
void cuda_reason_clear(void);

int cuda_version_parse(cuda_native_version *version, const char *raw);
int cuda_version_make(cuda_native_version *version, uint32_t major,
    uint32_t minor, uint32_t patch, unsigned parts);
int cuda_version_format(const cuda_native_version *version, char *output,
    size_t output_size);
void cuda_uuid_text(const CUuuid *uuid, char text[41]);

#endif

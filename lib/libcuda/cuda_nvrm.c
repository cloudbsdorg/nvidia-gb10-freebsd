/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The NVRM provider: the real GPU, through libnvrm.  It opens the resource
 * manager once, reports what the RM says about every device, and answers
 * the memory calls with the RM's own memory: video memory for the device,
 * system memory for the host.
 *
 * The copies are made by the CPU, through the mapping of the memory: no
 * copy engine is used and no work is submitted to the GPU.  libcuda(3)
 * says so.
 *
 * The library is loaded when the provider is first used, so a program that
 * only wants the synthetic devices does not need it.
 */
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "cuda_internal.h"
#include "cuda_nvrm.h"

/* The library the provider talks to. */
#define NVRM_LIBRARY "libnvrm.so.1"
/* The mapping descriptors one context holds: one for every allocation it
 * maps into the CPU at the same time. */
#define NVRM_MAP_SLOTS 64

/* What the provider holds after the enumeration. */
static struct {
	nvrm_ctx *ctx;
	nvrm_device *device[NVRM_MAX_GPUS];
	unsigned count;
} nvrm_state;

/* The calls of libnvrm.  They are filled when the provider is first used. */
static cuda_nvrm_api nvrm_api;
static int nvrm_api_ready;

/* One context: the RM client and the device it belongs to. */
typedef struct nvrm_context {
	nvrm_device *device;
	nvrm_client *client;
	/* The bytes this context holds, for the free count of the device. */
	size_t in_use;
} nvrm_context;

/* One allocation: the RM's memory object and the address the GPU knows it
 * by. */
typedef struct nvrm_object {
	nvrm_client *client;
	nvrm_mem *memory;
	uint64_t va;
	size_t bytes;
} nvrm_object;

/* ---- the calls of libnvrm -------------------------------------------------- */

/* The library the provider loads.  The name may be another one for a site
 * that installs the library under another name; the tests use it to have
 * the library missing. */
static const char *
nvrm_library_name(void)
{
	const char *name = getenv("CUDA_NATIVE_NVRM_LIBRARY");

	return (name != NULL && *name != '\0' ? name : NVRM_LIBRARY);
}

/* Load the library and fill the table.  A symbol the library does not have
 * is a failure: the provider never calls a function it could not resolve.
 * The table is filled once; a second call says the table is ready. */
static int
nvrm_load(void)
{
	const char *library = nvrm_library_name();
	char text[256];
	void *handle;
	int failed = 0;

	if (nvrm_api_ready)
		return (0);
	handle = dlopen(library, RTLD_LAZY | RTLD_LOCAL);
	if (handle == NULL) {
		snprintf(text, sizeof(text), "the native library %s could not "
		    "be loaded: it is not installed", library);
		cuda_reason_set(text);
		return (-1);
	}
#define	BIND(field, type, name) do {					\
	nvrm_api.field = (type)dlsym(handle, name);			\
	if (nvrm_api.field == NULL)					\
		failed = 1;						\
} while (0)
	BIND(enumerate, int (*)(nvrm_ctx **, const nvrm_enum_opts *, char *,
	    size_t), "nvrm_enumerate");
	BIND(close, void (*)(nvrm_ctx *), "nvrm_close");
	BIND(device_count, unsigned (*)(const nvrm_ctx *), "nvrm_device_count");
	BIND(device_get, nvrm_device *(*)(const nvrm_ctx *, unsigned),
	    "nvrm_device_get");
	BIND(device_info_get, const nvrm_device_info *(*)(const nvrm_device *),
	    "nvrm_device_info_get");
	BIND(client_open, int (*)(const nvrm_device *, const nvrm_open_opts *,
	    nvrm_client **, char *, size_t), "nvrm_client_open");
	BIND(client_close, void (*)(nvrm_client *), "nvrm_client_close");
	BIND(client_errmsg, const char *(*)(const nvrm_client *),
	    "nvrm_client_errmsg");
	BIND(va_reserve, int (*)(nvrm_client *, const nvrm_va_params *,
	    uint64_t *), "nvrm_va_reserve");
	BIND(va_release, int (*)(nvrm_client *, uint64_t), "nvrm_va_release");
	BIND(mem_alloc, int (*)(nvrm_client *, const nvrm_mem_params *,
	    nvrm_mem **), "nvrm_mem_alloc");
	BIND(mem_free, void (*)(nvrm_mem *), "nvrm_mem_free");
	BIND(mem_info_get, int (*)(const nvrm_mem *, nvrm_mem_info *),
	    "nvrm_mem_info_get");
	BIND(mem_map_gpu, int (*)(nvrm_mem *, const nvrm_gpu_map_params *),
	    "nvrm_mem_map_gpu");
	BIND(mem_unmap_gpu, int (*)(nvrm_mem *, uint64_t), "nvrm_mem_unmap_gpu");
	BIND(mem_map_cpu, int (*)(nvrm_mem *, unsigned, void **),
	    "nvrm_mem_map_cpu");
	BIND(mem_unmap_cpu, int (*)(nvrm_mem *), "nvrm_mem_unmap_cpu");
	BIND(mem_read, int (*)(nvrm_mem *, uint64_t, void *, size_t),
	    "nvrm_mem_read");
	BIND(mem_write, int (*)(nvrm_mem *, uint64_t, const void *, size_t),
	    "nvrm_mem_write");
	BIND(cap_name, const char *(*)(unsigned), "nvrm_cap_name");
	BIND(library_version, const nvrm_version *(*)(void),
	    "nvrm_library_version");
#undef	BIND
	if (failed) {
		cuda_reason_set("the native library does not have the calls "
		    "this provider needs: it is another version");
		dlclose(handle);
		return (-1);
	}
	nvrm_api_ready = 1;
	return (0);
}

void
cudaNvrmBindApi(const cuda_nvrm_api *api)
{
	if (api == NULL)
		return;
	nvrm_api = *api;
	nvrm_api_ready = 1;
}

/* The calls are ready: either the library was loaded or the test bound
 * them. */
static int
nvrm_ready(void)
{
	if (nvrm_api_ready)
		return (0);
	return (nvrm_load());
}

/* The result of a call of libnvrm, as a CUDA result.  The reason of the
 * failure is the message of the library. */
static CUresult
nvrm_result(int rc, const char *message)
{
	char text[256];

	if (rc == NVRM_OK)
		return (CUDA_SUCCESS);
	if (message == NULL || *message == '\0')
		message = "the resource manager refused the call";
	snprintf(text, sizeof(text), "%s", message);
	cuda_reason_set(text);
	switch (rc) {
	case NVRM_E_NOMEM:
	case NVRM_E_NOSLOT:
		return (CUDA_ERROR_OUT_OF_MEMORY);
	case NVRM_E_INVAL:
	case NVRM_E_RANGE:
	case NVRM_E_DENIED:
		return (CUDA_ERROR_INVALID_VALUE);
	case NVRM_E_NOBACKEND:
	case NVRM_E_OPEN:
	case NVRM_E_VERSION:
	case NVRM_E_NOTSUP:
		return (CUDA_ERROR_NOT_SUPPORTED);
	default:
		return (CUDA_ERROR_UNKNOWN);
	}
}

/* ---- the device information ------------------------------------------------ */

/* The device information of one GPU, or null. */
static const nvrm_device_info *
nvrm_info(unsigned index)
{
	if (index >= nvrm_state.count || nvrm_state.device[index] == NULL)
		return (NULL);
	return (nvrm_api.device_info_get(nvrm_state.device[index]));
}

/* The value of one hex digit, or -1. */
static int
hex_value(char c)
{
	if (c >= '0' && c <= '9')
		return (c - '0');
	if (c >= 'a' && c <= 'f')
		return (c - 'a' + 10);
	if (c >= 'A' && c <= 'F')
		return (c - 'A' + 10);
	return (-1);
}

/* The RM reports the UUID as text: "GPU-" and 32 hex digits in the eight
 * groups of the canonical form. */
static int
uuid_parse(const char *text, char bytes[16])
{
	const char *p = text;
	unsigned i;

	if (text == NULL || strncmp(text, "GPU-", 4) != 0)
		return (-1);
	p = text + 4;
	for (i = 0; i < 16; i++) {
		int high, low;

		high = hex_value(p[0]);
		low = hex_value(p[1]);
		if (high < 0 || low < 0)
			return (-1);
		bytes[i] = (char)(high * 16 + low);
		p += 2;
		if (i != 15 && *p == '-')
			p++;
	}
	return (*p == '\0' ? 0 : -1);
}

/* The index of a capability, by its stable name: the library owns the
 * order of the table, the name is the contract. */
static int
nvrm_capability_index(const char *name)
{
	unsigned i;

	for (i = 0; i < NVRM_NCAPS; i++) {
		const char *candidate = nvrm_api.cap_name(i);

		if (candidate != NULL && strcmp(candidate, name) == 0)
			return ((int)i);
	}
	return (-1);
}

static CUresult
nvrm_provider_enumerate(unsigned *count)
{
	char error[256];
	unsigned i;
	int rc;

	if (count == NULL)
		return (CUDA_ERROR_INVALID_VALUE);
	if (nvrm_ready() != 0)
		return (CUDA_ERROR_NOT_SUPPORTED);
	if (nvrm_state.ctx == NULL) {
		error[0] = '\0';
		rc = nvrm_api.enumerate(&nvrm_state.ctx, NULL, error,
		    sizeof(error));
		if (rc != NVRM_OK) {
			/* The driver is not there, or the library could
			 * not talk to it.  The provider has no device, and
			 * it says so instead of pretending it has one. */
			nvrm_result(rc, error);
			return (CUDA_ERROR_NOT_SUPPORTED);
		}
	}
	nvrm_state.count = nvrm_api.device_count(nvrm_state.ctx);
	if (nvrm_state.count > NVRM_MAX_GPUS) {
		cuda_reason_set("the resource manager reported more devices "
		    "than the provider can hold");
		return (CUDA_ERROR_INVALID_VALUE);
	}
	for (i = 0; i < nvrm_state.count; i++)
		nvrm_state.device[i] = nvrm_api.device_get(nvrm_state.ctx, i);
	*count = nvrm_state.count;
	return (CUDA_SUCCESS);
}

static CUresult
nvrm_provider_name(unsigned index, char *name, int len)
{
	const nvrm_device_info *info;
	char text[256];
	unsigned i;
	int used;

	if (name == NULL || len <= 0)
		return (CUDA_ERROR_INVALID_VALUE);
	if (nvrm_ready() != 0)
		return (CUDA_ERROR_NOT_SUPPORTED);
	info = nvrm_info(index);
	if (info == NULL)
		return (CUDA_ERROR_INVALID_VALUE);
	/* The RM does not report the board's marketing name: the name is
	 * the generation the RM reports, followed by the board decorators
	 * it reports. */
	used = snprintf(text, sizeof(text), "NVIDIA %s",
	    NVRM_HAVE(info->family) ? info->family.value : "GPU");
	if (used < 0)
		return (CUDA_ERROR_UNKNOWN);
	for (i = 0; i < info->ndecorators; i++) {
		if ((size_t)used >= sizeof(text))
			break;
		used += snprintf(text + used, sizeof(text) - used, " %s",
		    info->decorators[i]);
	}
	if (snprintf(name, (size_t)len, "%s", text) < 0)
		return (CUDA_ERROR_UNKNOWN);
	return (CUDA_SUCCESS);
}

static CUresult
nvrm_provider_uuid(unsigned index, CUuuid *uuid)
{
	const nvrm_device_info *info;

	if (uuid == NULL)
		return (CUDA_ERROR_INVALID_VALUE);
	if (nvrm_ready() != 0)
		return (CUDA_ERROR_NOT_SUPPORTED);
	info = nvrm_info(index);
	if (info == NULL)
		return (CUDA_ERROR_INVALID_VALUE);
	if (!NVRM_HAVE(info->uuid)) {
		cuda_reason_set("the resource manager did not report the UUID "
		    "of this device");
		return (CUDA_ERROR_NOT_SUPPORTED);
	}
	if (uuid_parse(info->uuid.value, uuid->bytes) != 0) {
		cuda_reason_set("the UUID the resource manager reported is not "
		    "in the canonical form");
		return (CUDA_ERROR_UNKNOWN);
	}
	return (CUDA_SUCCESS);
}

static CUresult
nvrm_provider_memory(unsigned index, size_t *bytes)
{
	const nvrm_device_info *info;

	if (bytes == NULL)
		return (CUDA_ERROR_INVALID_VALUE);
	if (nvrm_ready() != 0)
		return (CUDA_ERROR_NOT_SUPPORTED);
	info = nvrm_info(index);
	if (info == NULL)
		return (CUDA_ERROR_INVALID_VALUE);
	if (!NVRM_HAVE(info->vram_size)) {
		cuda_reason_set("the resource manager did not report the size "
		    "of the video memory of this device");
		return (CUDA_ERROR_NOT_SUPPORTED);
	}
	*bytes = (size_t)info->vram_size.value;
	return (CUDA_SUCCESS);
}

static CUresult
nvrm_provider_attribute(unsigned index, CUdevice_attribute attribute,
    int *value)
{
	const nvrm_device_info *info;
	const nvrm_u64 *source;
	uint64_t number;
	int soc;

	if (value == NULL)
		return (CUDA_ERROR_INVALID_VALUE);
	if (nvrm_ready() != 0)
		return (CUDA_ERROR_NOT_SUPPORTED);
	info = nvrm_info(index);
	if (info == NULL)
		return (CUDA_ERROR_INVALID_VALUE);
	switch (attribute) {
	case CU_DEVICE_ATTRIBUTE_MULTIPROCESSOR_COUNT:
		source = &info->sm_count;
		break;
	case CU_DEVICE_ATTRIBUTE_COMPUTE_CAPABILITY_MAJOR:
		source = &info->compute_capability_major;
		break;
	case CU_DEVICE_ATTRIBUTE_COMPUTE_CAPABILITY_MINOR:
		source = &info->compute_capability_minor;
		break;
	case CU_DEVICE_ATTRIBUTE_PCI_BUS_ID:
		source = &info->pci_bus;
		break;
	case CU_DEVICE_ATTRIBUTE_PCI_DEVICE_ID:
		source = &info->pci_device;
		break;
	case CU_DEVICE_ATTRIBUTE_PCI_DOMAIN_ID:
		source = &info->pci_domain;
		break;
	case CU_DEVICE_ATTRIBUTE_INTEGRATED:
		/* A GPU that is part of a system on a chip. */
		soc = nvrm_capability_index("soc");
		if (soc < 0) {
			cuda_reason_set("the native library does not name the "
			    "capability of a system on a chip");
			return (CUDA_ERROR_NOT_SUPPORTED);
		}
		source = &info->caps[soc];
		break;
	default:
		/* The RM does not report the other attributes: they stay
		 * unavailable rather than guessed. */
		cuda_reason_set("the resource manager does not report this "
		    "attribute");
		return (CUDA_ERROR_NOT_SUPPORTED);
	}
	if (!NVRM_HAVE(*source)) {
		cuda_reason_set("the resource manager did not report this "
		    "attribute of this device");
		return (CUDA_ERROR_NOT_SUPPORTED);
	}
	number = source->value;
	*value = (int)number;
	return (CUDA_SUCCESS);
}

/* ---- the memory -------------------------------------------------------------- */

static CUresult
nvrm_context_create(unsigned index, void **context)
{
	nvrm_open_opts options;
	nvrm_context *created;
	char error[256];
	int rc;

	if (context == NULL || index >= nvrm_state.count)
		return (CUDA_ERROR_INVALID_VALUE);
	created = calloc(1, sizeof(*created));
	if (created == NULL)
		return (CUDA_ERROR_OUT_OF_MEMORY);
	created->device = nvrm_state.device[index];
	memset(&options, 0, sizeof(options));
	/* The client needs the CPU mapping: the copies are made through
	 * it.  One descriptor per allocation the context holds. */
	options.flags = NVRM_OPEN_ALLOW_MAP;
	options.map_slots = NVRM_MAP_SLOTS;
	error[0] = '\0';
	rc = nvrm_api.client_open(created->device, &options, &created->client,
	    error, sizeof(error));
	if (rc != NVRM_OK) {
		free(created);
		return (nvrm_result(rc, error));
	}
	*context = created;
	return (CUDA_SUCCESS);
}

static CUresult
nvrm_context_destroy(void *context)
{
	nvrm_context *model = context;

	if (model == NULL)
		return (CUDA_ERROR_INVALID_VALUE);
	nvrm_api.client_close(model->client);
	free(model);
	return (CUDA_SUCCESS);
}

/* One allocation: the memory of the RM, the address the GPU knows it by,
 * and the view the CPU reads and writes. */
static CUresult
nvrm_allocate(nvrm_context *model, uint32_t kind, size_t bytes,
    nvrm_object **object, void **cpu_address, uint64_t *device_ptr)
{
	nvrm_mem_params parameters;
	nvrm_mem_info information;
	nvrm_va_params reservation;
	nvrm_gpu_map_params mapping;
	nvrm_object *created;
	nvrm_mem *memory = NULL;
	uint64_t va = 0;
	void *address = NULL;
	int rc;

	created = calloc(1, sizeof(*created));
	if (created == NULL)
		return (CUDA_ERROR_OUT_OF_MEMORY);
	memset(&parameters, 0, sizeof(parameters));
	parameters.kind = kind;
	parameters.bytes = bytes;
	rc = nvrm_api.mem_alloc(model->client, &parameters, &memory);
	if (rc != NVRM_OK) {
		free(created);
		return (nvrm_result(rc, nvrm_api.client_errmsg(model->client)));
	}
	memset(&information, 0, sizeof(information));
	rc = nvrm_api.mem_info_get(memory, &information);
	if (rc != NVRM_OK) {
		nvrm_api.mem_free(memory);
		free(created);
		return (nvrm_result(rc, nvrm_api.client_errmsg(model->client)));
	}
	/* The address the GPU knows the memory by: a range of the client's
	 * address space, at the page size the object got. */
	memset(&reservation, 0, sizeof(reservation));
	reservation.bytes = information.bytes;
	reservation.alignment = information.page_size;
	rc = nvrm_api.va_reserve(model->client, &reservation, &va);
	if (rc != NVRM_OK) {
		nvrm_api.mem_free(memory);
		free(created);
		return (nvrm_result(rc, nvrm_api.client_errmsg(model->client)));
	}
	memset(&mapping, 0, sizeof(mapping));
	mapping.va = va;
	rc = nvrm_api.mem_map_gpu(memory, &mapping);
	if (rc != NVRM_OK) {
		(void)nvrm_api.va_release(model->client, va);
		nvrm_api.mem_free(memory);
		free(created);
		return (nvrm_result(rc, nvrm_api.client_errmsg(model->client)));
	}
	/* The view the CPU reads and writes.  The copies are made through
	 * it, and the caller writes into it for a host allocation. */
	rc = nvrm_api.mem_map_cpu(memory, NVRM_CPU_READ | NVRM_CPU_WRITE,
	    &address);
	if (rc != NVRM_OK) {
		(void)nvrm_api.mem_unmap_gpu(memory, va);
		(void)nvrm_api.va_release(model->client, va);
		nvrm_api.mem_free(memory);
		free(created);
		return (nvrm_result(rc, nvrm_api.client_errmsg(model->client)));
	}
	created->client = model->client;
	created->memory = memory;
	created->va = va;
	created->bytes = information.bytes;
	*object = created;
	*cpu_address = address;
	*device_ptr = va;
	model->in_use += bytes;
	return (CUDA_SUCCESS);
}

static void
nvrm_object_release(nvrm_object *object)
{
	(void)nvrm_api.mem_unmap_cpu(object->memory);
	(void)nvrm_api.mem_unmap_gpu(object->memory, object->va);
	(void)nvrm_api.va_release(object->client, object->va);
	nvrm_api.mem_free(object->memory);
	free(object);
}

static CUresult
nvrm_device_alloc(void *context, size_t bytes, void **object,
    uint64_t *device_ptr)
{
	nvrm_context *model = context;
	nvrm_object *allocation = NULL;
	void *address = NULL;
	CUresult result;

	if (model == NULL || object == NULL || device_ptr == NULL)
		return (CUDA_ERROR_INVALID_VALUE);
	if (bytes == 0)
		return (CUDA_ERROR_INVALID_VALUE);
	result = nvrm_allocate(model, NVRM_MEM_VRAM, bytes, &allocation,
	    &address, device_ptr);
	if (result != CUDA_SUCCESS)
		return (result);
	*object = allocation;
	return (CUDA_SUCCESS);
}

static CUresult
nvrm_device_free(void *object)
{
	nvrm_object *allocation = object;

	if (allocation == NULL)
		return (CUDA_ERROR_INVALID_VALUE);
	nvrm_object_release(allocation);
	return (CUDA_SUCCESS);
}

static CUresult
nvrm_host_alloc(void *context, size_t bytes, void **object,
    void **host_address, uint64_t *device_ptr)
{
	nvrm_context *model = context;
	nvrm_mem_info information;
	nvrm_object *allocation = NULL;
	void *address = NULL;
	CUresult result;

	if (model == NULL || object == NULL || host_address == NULL ||
	    device_ptr == NULL)
		return (CUDA_ERROR_INVALID_VALUE);
	if (bytes == 0)
		return (CUDA_ERROR_INVALID_VALUE);
	result = nvrm_allocate(model, NVRM_MEM_SYSMEM, bytes, &allocation,
	    &address, device_ptr);
	if (result != CUDA_SUCCESS)
		return (result);
	/* The caller writes to the address with ordinary stores, so the
	 * memory must be one the CPU may write as ordinary memory. */
	memset(&information, 0, sizeof(information));
	if (nvrm_api.mem_info_get(allocation->memory, &information) != NVRM_OK) {
		nvrm_object_release(allocation);
		cuda_reason_set("the resource manager did not report the "
		    "attribute of the memory it made");
		return (CUDA_ERROR_UNKNOWN);
	}
	if (information.cpu_attr == NVRM_ATTR_DEVICE) {
		nvrm_object_release(allocation);
		cuda_reason_set("the system memory of this device is device "
		    "memory for the CPU: the caller cannot write it with "
		    "ordinary stores");
		return (CUDA_ERROR_NOT_SUPPORTED);
	}
	*host_address = address;
	*object = allocation;
	return (CUDA_SUCCESS);
}

static CUresult
nvrm_host_free(void *object)
{
	return (nvrm_device_free(object));
}

static CUresult
nvrm_read(void *object, uint64_t offset, void *buffer, size_t bytes)
{
	nvrm_object *allocation = object;

	if (allocation == NULL || buffer == NULL)
		return (CUDA_ERROR_INVALID_VALUE);
	if (offset > allocation->bytes || bytes > allocation->bytes - offset)
		return (CUDA_ERROR_INVALID_VALUE);
	return (nvrm_result(nvrm_api.mem_read(allocation->memory, offset,
	    buffer, bytes), nvrm_api.client_errmsg(allocation->client)));
}

static CUresult
nvrm_write(void *object, uint64_t offset, const void *buffer, size_t bytes)
{
	nvrm_object *allocation = object;

	if (allocation == NULL || buffer == NULL)
		return (CUDA_ERROR_INVALID_VALUE);
	if (offset > allocation->bytes || bytes > allocation->bytes - offset)
		return (CUDA_ERROR_INVALID_VALUE);
	return (nvrm_result(nvrm_api.mem_write(allocation->memory, offset,
	    buffer, bytes), nvrm_api.client_errmsg(allocation->client)));
}

/* The memory of the device: what the RM reports and what this library's
 * own allocations hold of it. */
static CUresult
nvrm_info_bytes(void *context, size_t *free_bytes, size_t *total_bytes)
{
	nvrm_context *model = context;
	const nvrm_device_info *info;
	uint64_t total, used;

	if (model == NULL || free_bytes == NULL || total_bytes == NULL)
		return (CUDA_ERROR_INVALID_VALUE);
	info = nvrm_api.device_info_get(model->device);
	if (info == NULL || !NVRM_HAVE(info->vram_size)) {
		cuda_reason_set("the resource manager did not report the size "
		    "of the video memory of this device");
		return (CUDA_ERROR_NOT_SUPPORTED);
	}
	total = info->vram_size.value;
	used = model->in_use;
	*total_bytes = (size_t)total;
	*free_bytes = used < total ? (size_t)(total - used) : 0;
	return (CUDA_SUCCESS);
}

static const cuda_mem_ops nvrm_mem_ops = {
	.context_create = nvrm_context_create,
	.context_destroy = nvrm_context_destroy,
	.device_alloc = nvrm_device_alloc,
	.device_free = nvrm_device_free,
	.host_alloc = nvrm_host_alloc,
	.host_free = nvrm_host_free,
	.read = nvrm_read,
	.write = nvrm_write,
	.info = nvrm_info_bytes
};

/* This provider is the native kind: it takes no fake profile, and it
 * discovers the devices through the resource manager. */
const cuda_provider cuda_nvrm_provider = {
	.backend = "nvrm",
	.kind = CUDA_PROVIDER_NATIVE,
	/* The memory backend of the provider: the RM's own memory. */
	.mem = &nvrm_mem_ops,
	.enumerate = nvrm_provider_enumerate,
	.name = nvrm_provider_name,
	.uuid = nvrm_provider_uuid,
	.memory = nvrm_provider_memory,
	.attribute = nvrm_provider_attribute
};

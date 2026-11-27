/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Deterministic devices for tests and documentation examples.  Every value
 * below is synthetic; this provider neither discovers nor accesses hardware.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "cuda_internal.h"

typedef struct fake_profile {
	const char *profile;
	const char *name;
	unsigned char uuid[16];
	size_t memory;
	int compute_major;
	int compute_minor;
	int multiprocessors;
	int integrated;
	int pci_domain;
	int pci_bus;
	int pci_device;
	/* Listed profiles are the ones the library advertises; a profile
	 * reserved for the library's own tests is accepted but not listed. */
	unsigned listed;
} fake_profile;

/* The profile the fake provider uses when the environment names none. */
static const char *const default_profile = "gb206";

/* The most profiles one selection may name.  The array of the selected
 * profiles below holds this many of them: the write of a selected profile
 * stops at the bound, and a selection that names more is counted, so the
 * registry refuses the count and names the reason. */
#define FAKE_MAX_PROFILES CUDA_NATIVE_MAX_PHYSICAL_DEVICES

static const fake_profile profiles[] = {
	{
		.profile = "gb206",
		.name = "cuda-native fake GB206",
		.uuid = { 0xcb, 0x14, 0xa0, 0x00, 0x00, 0x00, 0x40, 0x00,
		    0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01 },
		.memory = (size_t)16 * 1024 * 1024 * 1024,
		.compute_major = 12,
		.compute_minor = 0,
		.multiprocessors = 36,
		.integrated = 0,
		.pci_domain = 0,
		.pci_bus = 1,
		.pci_device = 0,
		.listed = 1
	},
	{
		.profile = "gb10",
		.name = "cuda-native fake GB10",
		.uuid = { 0xcb, 0x14, 0xa0, 0x00, 0x00, 0x00, 0x40, 0x00,
		    0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02 },
		.memory = (size_t)128 * 1024 * 1024 * 1024,
		.compute_major = 12,
		.compute_minor = 1,
		.multiprocessors = 48,
		.integrated = 1,
		.pci_domain = 15,
		.pci_bus = 1,
		.pci_device = 0,
		.listed = 1
	},
#ifdef CUDA_NATIVE_TESTING
	{
		.profile = "utf8",
		.name = "cuda-native fake \xE2\x84\xA2 \xC3\xA9 \xFF "
		    "\x01\x7F",
		.uuid = { 0xcb, 0x14, 0xa0, 0x00, 0x00, 0x00, 0x40, 0x00,
		    0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03 },
		.memory = (size_t)16 * 1024 * 1024 * 1024,
		.compute_major = 12,
		.compute_minor = 0,
		.multiprocessors = 36,
		.integrated = 0,
		.pci_domain = 0,
		.pci_bus = 1,
		.pci_device = 0,
		.listed = 0
	}
#endif
};

static const fake_profile *selected[FAKE_MAX_PROFILES];
static unsigned selected_count;
/* The count of the devices the selection names, even when the selection
 * names more devices than the array above holds: the count saturates at the
 * limit plus one, the registry refuses such a count and names the reason,
 * and the devices are never addressed. */
static unsigned selected_total;

static const fake_profile *
profile_find(const char *name, size_t length)
{
	size_t i;

	/* Time: O(profiles * name length); Space: O(1). */
	for (i = 0; i < sizeof(profiles) / sizeof(profiles[0]); i++)
		if (strlen(profiles[i].profile) == length &&
		    memcmp(profiles[i].profile, name, length) == 0)
			return (&profiles[i]);
	return (NULL);
}

int
cudaNativeFakeProfileKnown(const char *name, size_t length)
{
	if (name == NULL)
		return (0);
	return (profile_find(name, length) != NULL);
}

unsigned
cudaNativeFakeProfileCount(void)
{
	unsigned count = 0;
	size_t i;

	/* Time: O(profiles); Space: O(1). */
	for (i = 0; i < sizeof(profiles) / sizeof(profiles[0]); i++)
		if (profiles[i].listed)
			count++;
	return (count);
}

const char *
cudaNativeFakeProfileName(unsigned index)
{
	unsigned seen = 0;
	size_t i;

	/* Time: O(profiles); Space: O(1). */
	for (i = 0; i < sizeof(profiles) / sizeof(profiles[0]); i++) {
		if (!profiles[i].listed)
			continue;
		if (seen == index)
			return (profiles[i].profile);
		seen++;
	}
	return (NULL);
}

const char *
cudaNativeFakeProfileDefault(void)
{
	return (default_profile);
}

/* The provider applies the profile selection the registry hands it.  The
 * selection is the comma-separated list of profile names, or null when the
 * environment names none; then the provider uses its own default.  The
 * provider reports how many devices the selection names, even when that
 * number is above the number of devices the registry holds: the registry
 * refuses the count and names the reason, so the failure is not reported as
 * a provider error. */
static CUresult
fake_select(const char *list)
{
	const fake_profile *profile;
	const char *cursor, *comma;
	size_t length;
	unsigned count = 0;

	if (list == NULL)
		list = default_profile;
	if (*list == '\0')
		return (CUDA_ERROR_INVALID_VALUE);
	selected_count = 0;
	selected_total = 0;
	cursor = list;
	/* Time: O(profile-list bytes); Space: O(1) besides selected[]. */
	for (;;) {
		comma = strchr(cursor, ',');
		length = comma == NULL ? strlen(cursor) : (size_t)(comma - cursor);
		profile = profile_find(cursor, length);
		if (profile == NULL) {
			/* A selection that names a profile the provider does
			 * not know is no selection: the count of the last
			 * one is not the count of this one. */
			selected_count = 0;
			selected_total = 0;
			return (CUDA_ERROR_INVALID_VALUE);
		}
		/* The count of the selection saturates at the limit plus
		 * one: a count that wrapped around would name a count below
		 * the limit for a selection that is above it, and the
		 * registry would accept a selection it must refuse. */
		if (count < FAKE_MAX_PROFILES)
			count++;
		else
			count = FAKE_MAX_PROFILES + 1;
		/* The array holds the limit's worth of profiles: the write
		 * stops at the bound, so a selection that names more cannot
		 * step past the array. */
		if (selected_count < FAKE_MAX_PROFILES)
			selected[selected_count++] = profile;
		if (comma == NULL)
			break;
		cursor = comma + 1;
	}
	selected_total = count;
	return (CUDA_SUCCESS);
}

static CUresult
fake_enumerate(unsigned *count)
{
#ifdef CUDA_NATIVE_TESTING
	const char *delay;
#endif

	if (count == NULL)
		return (CUDA_ERROR_INVALID_VALUE);
#ifdef CUDA_NATIVE_TESTING
	delay = getenv("CUDA_NATIVE_FAKE_ENUM_DELAY_MS");
	if (delay != NULL && *delay != '\0') {
		unsigned long ms = strtoul(delay, NULL, 10);
		struct timespec request = {
			.tv_sec = (time_t)(ms / 1000),
			.tv_nsec = (long)(ms % 1000) * 1000000L
		};

		nanosleep(&request, NULL);
	}
#endif
	*count = selected_total;
	return (CUDA_SUCCESS);
}

static int
fake_valid(unsigned index)
{
	return (index < selected_count);
}

static CUresult
fake_name(unsigned index, char *name, int len)
{
	if (!fake_valid(index) || name == NULL || len <= 0)
		return (CUDA_ERROR_INVALID_VALUE);
	if (snprintf(name, (size_t)len, "%s", selected[index]->name) < 0)
		return (CUDA_ERROR_UNKNOWN);
	return (CUDA_SUCCESS);
}

static CUresult
fake_uuid(unsigned index, CUuuid *uuid)
{
	if (!fake_valid(index) || uuid == NULL)
		return (CUDA_ERROR_INVALID_VALUE);
#ifdef CUDA_NATIVE_TESTING
	if (getenv("CUDA_NATIVE_FAKE_UUID_ERROR") != NULL)
		return (CUDA_ERROR_UNKNOWN);
#endif
	memcpy(uuid->bytes, selected[index]->uuid, sizeof(uuid->bytes));
	return (CUDA_SUCCESS);
}

static CUresult
fake_memory(unsigned index, size_t *bytes)
{
	if (!fake_valid(index) || bytes == NULL)
		return (CUDA_ERROR_INVALID_VALUE);
	*bytes = selected[index]->memory;
	return (CUDA_SUCCESS);
}

static CUresult
fake_attribute(unsigned index, CUdevice_attribute attribute, int *value)
{
	const fake_profile *profile;

	if (!fake_valid(index) || value == NULL)
		return (CUDA_ERROR_INVALID_VALUE);
#ifdef CUDA_NATIVE_TESTING
	if (attribute == CU_DEVICE_ATTRIBUTE_COOPERATIVE_LAUNCH &&
	    getenv("CUDA_NATIVE_FAKE_UNSUPPORTED_COOPERATIVE") != NULL)
		return (CUDA_ERROR_NOT_SUPPORTED);
#endif
	profile = selected[index];
	switch (attribute) {
	case CU_DEVICE_ATTRIBUTE_MAX_THREADS_PER_BLOCK:
		*value = 1024;
		break;
	case CU_DEVICE_ATTRIBUTE_MAX_SHARED_MEMORY_PER_BLOCK:
		*value = 48 * 1024;
		break;
	case CU_DEVICE_ATTRIBUTE_WARP_SIZE:
		*value = 32;
		break;
	case CU_DEVICE_ATTRIBUTE_MULTIPROCESSOR_COUNT:
		*value = profile->multiprocessors;
		break;
	case CU_DEVICE_ATTRIBUTE_INTEGRATED:
		*value = profile->integrated;
		break;
	case CU_DEVICE_ATTRIBUTE_PCI_BUS_ID:
		*value = profile->pci_bus;
		break;
	case CU_DEVICE_ATTRIBUTE_PCI_DEVICE_ID:
		*value = profile->pci_device;
		break;
	case CU_DEVICE_ATTRIBUTE_PCI_DOMAIN_ID:
		*value = profile->pci_domain;
		break;
	case CU_DEVICE_ATTRIBUTE_COMPUTE_CAPABILITY_MAJOR:
		*value = profile->compute_major;
		break;
	case CU_DEVICE_ATTRIBUTE_COMPUTE_CAPABILITY_MINOR:
		*value = profile->compute_minor;
		break;
	case CU_DEVICE_ATTRIBUTE_COOPERATIVE_LAUNCH:
		*value = 0;
		break;
	case CU_DEVICE_ATTRIBUTE_MAX_SHARED_MEMORY_PER_BLOCK_OPTIN:
		*value = 99 * 1024;
		break;
	case CU_DEVICE_ATTRIBUTE_VIRTUAL_MEMORY_MANAGEMENT_SUPPORTED:
		*value = 1;
		break;
	default:
		return (CUDA_ERROR_NOT_SUPPORTED);
	}
	return (CUDA_SUCCESS);
}

/* ---- the memory model ---------------------------------------------------- */

/*
 * The fake memory: ordinary host memory under a synthetic device address.
 * The addresses are above the user address space, so a device pointer is
 * never mistaken for a host pointer, and they are test data, not hardware
 * measurements.
 */
#define FAKE_DEVICE_BASE	0x8000000000000000ULL
#define FAKE_DEVICE_STEP	0x1000ULL

static uint64_t fake_next_device = FAKE_DEVICE_BASE;

typedef struct fake_context {
	unsigned index;
	size_t in_use;
} fake_context;

static CUresult
fake_context_create(unsigned index, void **context)
{
	fake_context *created;

	if (context == NULL)
		return (CUDA_ERROR_INVALID_VALUE);
	created = calloc(1, sizeof(*created));
	if (created == NULL)
		return (CUDA_ERROR_OUT_OF_MEMORY);
	created->index = index;
	*context = created;
	return (CUDA_SUCCESS);
}

static CUresult
fake_context_destroy(void *context)
{
	if (context == NULL)
		return (CUDA_ERROR_INVALID_VALUE);
	free(context);
	return (CUDA_SUCCESS);
}

static CUresult
fake_device_alloc(void *context, size_t bytes, void **object,
    uint64_t *device_ptr)
{
	fake_context *model = context;
	void *memory;

	if (object == NULL || device_ptr == NULL || model == NULL)
		return (CUDA_ERROR_INVALID_VALUE);
	if (bytes == 0)
		return (CUDA_ERROR_INVALID_VALUE);
	memory = calloc(1, bytes);
	if (memory == NULL)
		return (CUDA_ERROR_OUT_OF_MEMORY);
	*object = memory;
	*device_ptr = fake_next_device;
	fake_next_device += FAKE_DEVICE_STEP;
	model->in_use += bytes;
	return (CUDA_SUCCESS);
}

static CUresult
fake_device_free(void *object)
{
	if (object == NULL)
		return (CUDA_ERROR_INVALID_VALUE);
	free(object);
	return (CUDA_SUCCESS);
}

static CUresult
fake_host_alloc(void *context, size_t bytes, void **object,
    void **host_address, uint64_t *device_ptr)
{
	uint64_t pointer = 0;
	CUresult result;

	if (host_address == NULL)
		return (CUDA_ERROR_INVALID_VALUE);
	result = fake_device_alloc(context, bytes, object, &pointer);
	if (result != CUDA_SUCCESS)
		return (result);
	/* The host memory is the memory of the allocation: the caller
	 * writes to it with ordinary stores. */
	*host_address = *object;
	*device_ptr = pointer;
	return (CUDA_SUCCESS);
}

static CUresult
fake_host_free(void *object)
{
	return (fake_device_free(object));
}

static CUresult
fake_read(void *object, uint64_t offset, void *buffer, size_t bytes)
{
	if (object == NULL || buffer == NULL)
		return (CUDA_ERROR_INVALID_VALUE);
	memcpy(buffer, (const unsigned char *)object + offset, bytes);
	return (CUDA_SUCCESS);
}

static CUresult
fake_write(void *object, uint64_t offset, const void *buffer, size_t bytes)
{
	if (object == NULL || buffer == NULL)
		return (CUDA_ERROR_INVALID_VALUE);
	memcpy((unsigned char *)object + offset, buffer, bytes);
	return (CUDA_SUCCESS);
}

/* The memory of the device: the size of the profile and what this
 * library's own allocations hold of it. */
static CUresult
fake_info(void *context, size_t *free_bytes, size_t *total_bytes)
{
	fake_context *model = context;
	size_t total, used;

	if (free_bytes == NULL || total_bytes == NULL || model == NULL)
		return (CUDA_ERROR_INVALID_VALUE);
	if (!fake_valid(model->index))
		return (CUDA_ERROR_INVALID_VALUE);
	total = selected[model->index]->memory;
	used = model->in_use;
	*total_bytes = total;
	/* The free memory is what the allocations of this library do not
	 * hold: nothing else holds any of it. */
	if (used >= total)
		*free_bytes = 0;
	else
		*free_bytes = total - used;
	return (CUDA_SUCCESS);
}

static const cuda_mem_ops fake_mem_ops = {
	.context_create = fake_context_create,
	.context_destroy = fake_context_destroy,
	.device_alloc = fake_device_alloc,
	.device_free = fake_device_free,
	.host_alloc = fake_host_alloc,
	.host_free = fake_host_free,
	.read = fake_read,
	.write = fake_write,
	.info = fake_info
};

/* This provider is the synthetic kind: the registry hands it the profiles
 * named by CUDA_NATIVE_FAKE_PROFILE, and it applies them.  The provider
 * itself reads no environment variable, so the capability the library
 * reports and the selection the provider applies cannot drift apart. */
const cuda_provider cuda_fake_provider = {
	.backend = "fake",
	.kind = CUDA_PROVIDER_SYNTHETIC,
	.select = fake_select,
	.enumerate = fake_enumerate,
	.name = fake_name,
	.uuid = fake_uuid,
	.memory = fake_memory,
	.attribute = fake_attribute,
	.mem = &fake_mem_ops
};

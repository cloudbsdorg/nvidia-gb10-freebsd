/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 */
#include <limits.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

#include "cuda_internal.h"

enum registry_init_state {
	REGISTRY_NOT_STARTED,
	REGISTRY_RUNNING,
	REGISTRY_DONE
};

static pthread_once_t registry_once = PTHREAD_ONCE_INIT;
static atomic_int registry_state = ATOMIC_VAR_INIT(REGISTRY_NOT_STARTED);
static pthread_mutex_t context_lock = PTHREAD_MUTEX_INITIALIZER;
static __thread CUcontext current_context;

static struct {
	CUresult result;
	const cuda_provider *provider;
	cuda_device physical[CUDA_NATIVE_MAX_DEVICES];
	unsigned physical_count;
	cuda_device *visible[CUDA_NATIVE_MAX_DEVICES];
	unsigned visible_count;
} registry;

static const cuda_provider *const providers[] = {
	&cuda_fake_provider,
	&cuda_nvrm_provider
};

static CUresult
visible_index(const char *token, size_t length, unsigned *physical_index,
    int *matched)
{
	const cuda_provider *provider = registry.provider;
	unsigned i, value, matches, match;
	CUuuid uuid;
	CUresult result;
	char text[41];
	size_t prefix;

	*matched = 0;
	if (length == 0)
		return (CUDA_SUCCESS);
	value = 0;
	/* Time: O(token length); Space: O(1). */
	for (i = 0; i < length; i++) {
		if (token[i] < '0' || token[i] > '9')
			break;
		if (value > (UINT_MAX - (unsigned)(token[i] - '0')) / 10)
			return (CUDA_SUCCESS);
		value = value * 10 + (unsigned)(token[i] - '0');
	}
	if (i == length) {
		if (value < registry.physical_count) {
			*physical_index = value;
			*matched = 1;
		}
		return (CUDA_SUCCESS);
	}
	if (length <= 4 || length > 40 || memcmp(token, "GPU-", 4) != 0)
		return (CUDA_SUCCESS);
	matches = 0;
	match = 0;
	prefix = length - 4;
	/* Time: O(physical devices * UUID length); Space: O(1). */
	for (i = 0; i < registry.physical_count; i++) {
		result = provider->uuid(i, &uuid);
		if (result != CUDA_SUCCESS)
			return (result);
		cuda_uuid_text(&uuid, text);
		if (strncasecmp(token + 4, text + 4, prefix) == 0) {
			matches++;
			match = i;
		}
	}
	if (matches == 1) {
		*physical_index = match;
		*matched = 1;
	}
	return (CUDA_SUCCESS);
}

static CUresult
apply_visibility(void)
{
	const char *list, *cursor, *comma;
	size_t length;
	unsigned index;
	CUresult result;
	int matched;

	registry.visible_count = 0;
	list = getenv("CUDA_VISIBLE_DEVICES");
	if (list == NULL) {
		/* Time: O(physical devices); Space: O(1) besides visible[]. */
		for (index = 0; index < registry.physical_count; index++)
			registry.visible[registry.visible_count++] =
			    &registry.physical[index];
		return (CUDA_SUCCESS);
	}
	if (*list == '\0')
		return (CUDA_SUCCESS);

	cursor = list;
	/* Time: O(list bytes * physical devices); Space: O(1) besides visible[]. */
	while (cursor != NULL) {
		comma = strchr(cursor, ',');
		length = comma == NULL ? strlen(cursor) : (size_t)(comma - cursor);
		result = visible_index(cursor, length, &index, &matched);
		if (result != CUDA_SUCCESS)
			return (result);
		if (!matched)
			break;
		if (registry.visible_count == CUDA_NATIVE_MAX_DEVICES)
			return (CUDA_ERROR_INVALID_VALUE);
		registry.visible[registry.visible_count++] =
		    &registry.physical[index];
		cursor = comma == NULL ? NULL : comma + 1;
	}
	/* The CUDA visibility contract stops at the first invalid entry. */
	return (CUDA_SUCCESS);
}

static void
registry_initialize_once(void)
{
	const char *backend;
	unsigned i, count;
	size_t p;
	CUresult result;

	backend = cuda_default_backend();
	/* Time: O(providers * backend length); Space: O(1). */
	for (p = 0; p < sizeof(providers) / sizeof(providers[0]); p++)
		if (strcmp(backend, providers[p]->backend) == 0) {
			registry.provider = providers[p];
			break;
		}
	if (registry.provider == NULL) {
		registry.result = CUDA_ERROR_INVALID_VALUE;
		goto out;
	}
	count = 0;
	result = registry.provider->enumerate(&count);
	if (result != CUDA_SUCCESS) {
		registry.result = result;
		goto out;
	}
	if (count > CUDA_NATIVE_MAX_DEVICES) {
		registry.result = CUDA_ERROR_INVALID_VALUE;
		goto out;
	}
	registry.physical_count = count;
	for (i = 0; i < count; i++) {
		registry.physical[i].provider = registry.provider;
		registry.physical[i].physical_index = i;
		registry.physical[i].primary = &registry.physical[i].primary_state;
		registry.physical[i].primary_state.device = &registry.physical[i];
	}
	registry.result = apply_visibility();
out:
	atomic_store_explicit(&registry_state, REGISTRY_DONE, memory_order_release);
}

CUresult
cuda_registry_initialize(void)
{
	int expected = REGISTRY_NOT_STARTED;

	/* Only cuInit marks initialization started; pthread_once runs it once. */
	(void)atomic_compare_exchange_strong_explicit(&registry_state, &expected,
	    REGISTRY_RUNNING, memory_order_acq_rel, memory_order_acquire);
	return (cuda_registry_result());
}

CUresult
cuda_registry_result(void)
{
	if (atomic_load_explicit(&registry_state, memory_order_acquire) ==
	    REGISTRY_NOT_STARTED)
		return (CUDA_ERROR_NOT_INITIALIZED);
	/* A concurrent observer waits here until every registry write is complete. */
	if (pthread_once(&registry_once, registry_initialize_once) != 0)
		return (CUDA_ERROR_UNKNOWN);
	return (registry.result);
}

unsigned
cuda_registry_count(void)
{
	return (registry.visible_count);
}

cuda_device *
cuda_registry_get(CUdevice device)
{
	if (device < 0 || (unsigned)device >= registry.visible_count)
		return (NULL);
	return (registry.visible[device]);
}

CUdevice
cuda_registry_ordinal(const cuda_device *device)
{
	unsigned i;

	/* Time: O(visible devices); Space: O(1). */
	for (i = 0; i < registry.visible_count; i++)
		if (registry.visible[i] == device)
			return ((CUdevice)i);
	return (-1);
}

static cuda_device *
context_lookup(const void *context, int active_only)
{
	unsigned i;
	cuda_device *device;

	for (i = 0; i < registry.physical_count; i++) {
		device = &registry.physical[i];
		if (device->primary != context)
			continue;
		if (!active_only ||
		    (device->primary->magic == CUDA_NATIVE_CONTEXT_MAGIC &&
		    device->primary->references != 0))
			return (device);
		return (NULL);
	}
	return (NULL);
}

void *
cuda_registry_current_get(void)
{
	void *context = current_context;

	if (context != NULL) {
		pthread_mutex_lock(&context_lock);
		if (context_lookup(context, 1) == NULL) {
			current_context = NULL;
			context = NULL;
		}
		pthread_mutex_unlock(&context_lock);
	}
	return (context);
}

CUresult
cuda_registry_current_set(void *context)
{
	CUresult result = CUDA_SUCCESS;

	if (context == NULL) {
		current_context = NULL;
		return (CUDA_SUCCESS);
	}
	pthread_mutex_lock(&context_lock);
	if (context_lookup(context, 1) == NULL)
		result = CUDA_ERROR_INVALID_CONTEXT;
	else
		current_context = context;
	pthread_mutex_unlock(&context_lock);
	return (result);
}

CUresult
cuda_registry_primary_retain(CUcontext *context, cuda_device *device)
{
	CUresult result = CUDA_SUCCESS;

	pthread_mutex_lock(&context_lock);
	if (device->primary->references == UINT_MAX) {
		result = CUDA_ERROR_OUT_OF_MEMORY;
	} else {
		if (device->primary->references == 0) {
			device->primary->magic = CUDA_NATIVE_CONTEXT_MAGIC;
			device->primary->device = device;
		}
		device->primary->references++;
		*context = device->primary;
	}
	pthread_mutex_unlock(&context_lock);
	return (result);
}

CUresult
cuda_registry_primary_release(cuda_device *device)
{
	CUresult result = CUDA_SUCCESS;

	pthread_mutex_lock(&context_lock);
	if (device->primary->references == 0) {
		result = CUDA_ERROR_INVALID_CONTEXT;
	} else {
		device->primary->references--;
		if (device->primary->references == 0) {
			device->primary->magic = 0;
			if (current_context == device->primary)
				current_context = NULL;
		}
	}
	pthread_mutex_unlock(&context_lock);
	return (result);
}

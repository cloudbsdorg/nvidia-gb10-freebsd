/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 */
#include <limits.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

#include "cuda_internal.h"

enum registry_init_state {
	REGISTRY_NOT_STARTED,
	REGISTRY_INITIALIZING,
	REGISTRY_STARTED
};

static pthread_once_t registry_once = PTHREAD_ONCE_INIT;
static atomic_int registry_state = ATOMIC_VAR_INIT(REGISTRY_NOT_STARTED);
/* The reason of the first initialization attempt.  Before an attempt it is
 * CUDA_NATIVE_INIT_NOT_ATTEMPTED, which is not a success: a caller that
 * reads it before cuInit cannot mistake it for a completed
 * initialization. */
static atomic_int registry_reason =
    ATOMIC_VAR_INIT(CUDA_NATIVE_INIT_NOT_ATTEMPTED);
static pthread_mutex_t context_lock = PTHREAD_MUTEX_INITIALIZER;
static __thread CUcontext current_context;

static struct {
	CUresult result;
	const cuda_provider *provider;
	cuda_device physical[CUDA_NATIVE_MAX_PHYSICAL_DEVICES];
	unsigned physical_count;
	/* The visible list holds more pointers than the library exposes, so the
	 * exposed-device limit is a policy limit and not a buffer bound. */
	cuda_device *visible[CUDA_NATIVE_MAX_PHYSICAL_DEVICES];
	unsigned visible_count;
} registry;

static const cuda_provider *const providers[] = {
	&cuda_fake_provider,
	&cuda_nvrm_provider
};

static const cuda_provider *
provider_find(const char *backend)
{
	size_t i;

	if (backend == NULL)
		return (NULL);
	/* Time: O(providers * backend length); Space: O(1). */
	for (i = 0; i < sizeof(providers) / sizeof(providers[0]); i++)
		if (strcmp(backend, providers[i]->backend) == 0)
			return (providers[i]);
	return (NULL);
}

static const cuda_provider *
provider_by_kind(enum cuda_provider_kind kind)
{
	size_t i;

	/* Time: O(providers); Space: O(1). */
	for (i = 0; i < sizeof(providers) / sizeof(providers[0]); i++)
		if (providers[i]->kind == kind)
			return (providers[i]);
	return (NULL);
}

int
cudaNativeProviderKnown(const char *name)
{
	return (provider_find(name) != NULL);
}

unsigned
cudaNativeProviderCount(void)
{
	return (sizeof(providers) / sizeof(providers[0]));
}

const char *
cudaNativeProviderName(unsigned index)
{
	if (index >= sizeof(providers) / sizeof(providers[0]))
		return (NULL);
	return (providers[index]->backend);
}

/* The library knows which provider takes the fake profiles, so a caller does
 * not have to know the provider names to find out.  The provider kind is the
 * one fact about a provider: the registry applies the profile selection
 * under the same kind, so the advertised capability and the behavior cannot
 * disagree. */
int
cudaNativeProviderTakesFakeProfiles(const char *name)
{
	const cuda_provider *provider = provider_find(name);

	return (provider != NULL && provider->kind == CUDA_PROVIDER_SYNTHETIC);
}

/* The library's advice for a provider whose discovery is not implemented.  The
 * text names the provider and the one to use instead, so a caller does not
 * have to know the provider names to write it.  The advice is written whole
 * or not at all: a buffer that cannot hold all of it gets nothing, so a
 * caller never reads a truncated remedy as if it were the whole one. */
int
cudaNativeProviderHint(const char *name, char *buffer, size_t size)
{
	const cuda_provider *provider, *fallback;
	char advice[256];
	int length;

	if (buffer == NULL || size == 0)
		return (0);
	provider = provider_find(name);
	if (provider == NULL || provider->kind != CUDA_PROVIDER_NATIVE)
		return (0);
	fallback = provider_by_kind(CUDA_PROVIDER_SYNTHETIC);
	if (fallback == NULL)
		return (0);
	length = snprintf(advice, sizeof(advice),
	    "%s discovery is not implemented yet; set CUDA_NATIVE_BACKEND=%s "
	    "for synthetic devices", provider->backend, fallback->backend);
	if (length < 0 || (size_t)length >= sizeof(advice))
		return (0);
	/* The caller's buffer holds the whole advice or nothing at all. */
	if (size <= (size_t)length)
		return (0);
	memcpy(buffer, advice, (size_t)length + 1);
	return (1);
}

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

/* The library exposes at most CUDA_NATIVE_MAX_DEVICES devices; a further
 * device is an invalid value rather than a silently dropped one.  The reason
 * of the failure is recorded, so a caller can tell this overflow from any
 * other invalid value. */
static CUresult
visible_append(cuda_device *device, cudaNativeInitReason *reason)
{
	if (registry.visible_count == CUDA_NATIVE_MAX_DEVICES) {
		*reason = CUDA_NATIVE_INIT_DEVICE_LIMIT;
		return (CUDA_ERROR_INVALID_VALUE);
	}
	registry.visible[registry.visible_count++] = device;
	return (CUDA_SUCCESS);
}

static CUresult
apply_visibility(cudaNativeInitReason *reason)
{
	const char *list, *cursor, *comma;
	size_t length;
	unsigned i, index;
	CUresult result;
	int matched;

	registry.visible_count = 0;
	list = getenv("CUDA_VISIBLE_DEVICES");
	if (list == NULL) {
		/* Time: O(physical devices); Space: O(1) besides visible[]. */
		for (index = 0; index < registry.physical_count; index++) {
			result = visible_append(&registry.physical[index],
			    reason);
			if (result != CUDA_SUCCESS)
				return (result);
		}
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
		/* Aliases would make a primary context's visible ordinal ambiguous. */
		for (i = 0; i < registry.visible_count; i++)
			if (registry.visible[i] == &registry.physical[index])
				break;
		if (i != registry.visible_count)
			break;
		result = visible_append(&registry.physical[index], reason);
		if (result != CUDA_SUCCESS)
			return (result);
		cursor = comma == NULL ? NULL : comma + 1;
	}
	/* The CUDA visibility contract stops at the first invalid entry. */
	return (CUDA_SUCCESS);
}

/* The body of pthread_once.  It writes the registry data and the reason of
 * the outcome; the thread that entered the once publishes the completed state
 * with a release store after the body has returned, so a reader that sees the
 * completed state sees the data as well. */
static void
registry_initialize_once(void)
{
	const char *backend, *profiles;
	unsigned i, count;
	CUresult result;
	cudaNativeInitReason reason = CUDA_NATIVE_INIT_NOT_ATTEMPTED;

	backend = cudaNativeGetBackendName();
	registry.provider = provider_find(backend);
	if (registry.provider == NULL) {
		registry.result = CUDA_ERROR_INVALID_VALUE;
		reason = CUDA_NATIVE_INIT_UNKNOWN_PROVIDER;
		goto out;
	}
	/* The provider kind is the one fact about a provider: the profile
	 * selection is applied under the same kind the capability is
	 * reported from, so the two cannot disagree. */
	if (registry.provider->kind == CUDA_PROVIDER_SYNTHETIC &&
	    registry.provider->select != NULL) {
		profiles = getenv("CUDA_NATIVE_FAKE_PROFILE");
		result = registry.provider->select(profiles);
		if (result != CUDA_SUCCESS) {
			registry.result = result;
			reason = CUDA_NATIVE_INIT_PROVIDER_ERROR;
			goto out;
		}
	}
	count = 0;
	result = registry.provider->enumerate(&count);
	if (result != CUDA_SUCCESS) {
		registry.result = result;
		reason = result == CUDA_ERROR_NOT_SUPPORTED ?
		    CUDA_NATIVE_INIT_PROVIDER_UNSUPPORTED :
		    CUDA_NATIVE_INIT_PROVIDER_ERROR;
		goto out;
	}
	if (count > CUDA_NATIVE_MAX_PHYSICAL_DEVICES) {
		registry.result = CUDA_ERROR_INVALID_VALUE;
		reason = CUDA_NATIVE_INIT_PROVIDER_DEVICE_LIMIT;
		goto out;
	}
	registry.physical_count = count;
	for (i = 0; i < count; i++) {
		registry.physical[i].provider = registry.provider;
		registry.physical[i].physical_index = i;
		registry.physical[i].primary_state.device = &registry.physical[i];
	}
	/* The visibility overflow names its own reason; every other failure
	 * of the selection is a provider error. */
	reason = CUDA_NATIVE_INIT_PROVIDER_ERROR;
	registry.result = apply_visibility(&reason);
	if (registry.result != CUDA_SUCCESS)
		goto out;
	reason = CUDA_NATIVE_INIT_OK;
out:
	atomic_store_explicit(&registry_reason, reason, memory_order_relaxed);
	return;
}

CUresult
cuda_registry_initialize(void)
{
	int expected = REGISTRY_NOT_STARTED;

	/* Only cuInit marks initialization started; pthread_once runs it once.
	 * The state moves to REGISTRY_INITIALIZING before the body runs, so a
	 * reader never mistakes an unfinished registry for a finished one:
	 * the data is written first, the completed state is published with a
	 * release store afterwards, and every reader acquires that state. */
	if (atomic_compare_exchange_strong_explicit(&registry_state, &expected,
	    REGISTRY_INITIALIZING, memory_order_acq_rel, memory_order_acquire)) {
		if (pthread_once(&registry_once, registry_initialize_once) != 0)
			return (CUDA_ERROR_UNKNOWN);
		atomic_store_explicit(&registry_state, REGISTRY_STARTED,
		    memory_order_release);
		return (registry.result);
	}
	/* Another thread is initializing: wait for the body to finish. */
	if (pthread_once(&registry_once, registry_initialize_once) != 0)
		return (CUDA_ERROR_UNKNOWN);
	return (registry.result);
}

CUresult
cuda_registry_result(void)
{
	int state;

	/* The acquire load pairs with the release store of the completed
	 * state. */
	state = atomic_load_explicit(&registry_state, memory_order_acquire);
	if (state == REGISTRY_NOT_STARTED)
		return (CUDA_ERROR_NOT_INITIALIZED);
	/* The initialization is under way: wait for the body, so the registry
	 * data is read after it is complete. */
	if (pthread_once(&registry_once, registry_initialize_once) != 0)
		return (CUDA_ERROR_UNKNOWN);
	(void)atomic_load_explicit(&registry_state, memory_order_acquire);
	return (registry.result);
}

cudaNativeInitReason
cudaNativeInitFailureReason(void)
{
	return ((cudaNativeInitReason)atomic_load_explicit(&registry_reason,
	    memory_order_acquire));
}

unsigned
cuda_registry_count(void)
{
	/* The registry data is read after the initialization completed: the
	 * acquire load pairs with the release store that published it. */
	(void)atomic_load_explicit(&registry_state, memory_order_acquire);
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
context_lookup(const void *context)
{
	unsigned i;
	cuda_device *device;

	for (i = 0; i < registry.physical_count; i++) {
		device = &registry.physical[i];
		if (&device->primary_state != context)
			continue;
		if (device->primary_state.magic == CUDA_NATIVE_CONTEXT_MAGIC &&
		    device->primary_state.references != 0)
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
		if (context_lookup(context) == NULL) {
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
	if (context_lookup(context) == NULL)
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
	if (device->primary_state.references == UINT_MAX) {
		result = CUDA_ERROR_OUT_OF_MEMORY;
	} else {
		if (device->primary_state.references == 0) {
			device->primary_state.magic = CUDA_NATIVE_CONTEXT_MAGIC;
			device->primary_state.device = device;
		}
		device->primary_state.references++;
		*context = &device->primary_state;
	}
	pthread_mutex_unlock(&context_lock);
	return (result);
}

CUresult
cuda_registry_primary_release(cuda_device *device)
{
	CUresult result = CUDA_SUCCESS;

	pthread_mutex_lock(&context_lock);
	if (device->primary_state.references == 0) {
		result = CUDA_ERROR_INVALID_CONTEXT;
	} else {
		device->primary_state.references--;
		if (device->primary_state.references == 0) {
			device->primary_state.magic = 0;
			if (current_context == &device->primary_state)
				current_context = NULL;
		}
	}
	pthread_mutex_unlock(&context_lock);
	return (result);
}

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

/* The provider the registry selected, published for the readers that ask
 * which provider is in use.  The publication is atomic: a reader that asks
 * while the first initialization runs sees either no provider or the one
 * that was selected, and never a pointer that is written under it.  The
 * provider is a static object, so the pointer is the whole of the answer. */
static _Atomic(const cuda_provider *) registry_provider =
    ATOMIC_VAR_INIT(NULL);

static struct {
	CUresult result;
	const cuda_provider *provider;
	cuda_device physical[CUDA_NATIVE_MAX_PHYSICAL_DEVICES];
	unsigned physical_count;
	/* The visible list holds more pointers than the library exposes, so the
	 * exposed-device limit is a policy limit and not a buffer bound. */
	cuda_device *visible[CUDA_NATIVE_MAX_PHYSICAL_DEVICES];
	unsigned visible_count;
	/* The contexts the caller created with cuCtxCreate. */
	cuda_context *created;
	/* The allocations of every context.  The registry owns them, so it
	 * knows which context they belong to and frees them when that
	 * context goes away. */
	cuda_allocation *allocations;
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

/* One fact about a provider: it takes the fake profiles when it is the
 * synthetic kind and it applies a selection.  The capability the library
 * reports and the selection the registry applies are read from this one
 * predicate, so a provider that cannot apply a selection cannot be
 * advertised as one that takes profiles. */
static int
provider_takes_profiles(const cuda_provider *provider)
{
	return (provider != NULL &&
	    provider->kind == CUDA_PROVIDER_SYNTHETIC &&
	    provider->select != NULL);
}

/* The provider that takes the fake profiles, if there is one.  The advice of
 * the library names such a provider, so it names one that can serve
 * synthetic devices. */
static const cuda_provider *
provider_taking_profiles(void)
{
	size_t i;

	/* Time: O(providers); Space: O(1). */
	for (i = 0; i < sizeof(providers) / sizeof(providers[0]); i++)
		if (provider_takes_profiles(providers[i]))
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
 * not have to know the provider names to find out.  The predicate is the one
 * fact about a provider: the registry applies the profile selection under
 * the same fact, so the advertised capability and the behavior cannot
 * disagree. */
int
cudaNativeProviderTakesFakeProfiles(const char *name)
{
	return (provider_takes_profiles(provider_find(name)));
}

/* The provider the registry selected: the one that is in use.  It is the
 * answer of the library and not a name read from the environment: the
 * registry resolved the environment to this provider, and a caller that
 * asks for advice about a failure needs the provider that failed.  The
 * answer is null before the first initialization attempt and after an
 * attempt that named no registered provider. */
const char *
cudaNativeProviderInUse(void)
{
	const cuda_provider *provider;

	/* The provider is read once, with an acquire load that pairs with the
	 * release store of the selection: the reader sees the provider the
	 * registry selected, and never a pointer that is written under it. */
	provider = atomic_load_explicit(&registry_provider,
	    memory_order_acquire);
	return (provider != NULL ? provider->backend : NULL);
}

/* The library's advice for a provider whose discovery needs something this
 * process does not have.  The text names the provider and the one to use
 * instead, so a caller does not have to know the provider names to write
 * it.  The advice is written whole or not at all: a buffer that cannot hold
 * all of it gets nothing, so a caller never reads a truncated remedy as if
 * it were the whole one. */
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
	fallback = provider_taking_profiles();
	if (fallback == NULL)
		return (0);
	length = snprintf(advice, sizeof(advice),
	    "the %s provider needs the native library and the driver; set "
	    "CUDA_NATIVE_BACKEND=%s for synthetic devices", provider->backend,
	    fallback->backend);
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
	/* The provider is published for the readers that ask which provider
	 * is in use.  The publication is atomic and it is paired with the
	 * acquire load of the getter, so a reader that asks while the
	 * initialization runs sees the provider or none. */
	atomic_store_explicit(&registry_provider, registry.provider,
	    memory_order_release);
	if (registry.provider == NULL) {
		registry.result = CUDA_ERROR_INVALID_VALUE;
		reason = CUDA_NATIVE_INIT_UNKNOWN_PROVIDER;
		goto out;
	}
	/* The provider kind and the selection callback are one fact about a
	 * provider: the capability the library reports and the selection
	 * the registry applies are read from the same predicate.  A
	 * synthetic provider that cannot apply a selection is refused, so
	 * the library never advertises a profile it would not apply. */
	if (registry.provider->kind == CUDA_PROVIDER_SYNTHETIC) {
		if (!provider_takes_profiles(registry.provider)) {
			registry.result = CUDA_ERROR_INVALID_VALUE;
			reason = CUDA_NATIVE_INIT_PROVIDER_ERROR;
			goto out;
		}
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
	cuda_context *created;
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
	for (created = registry.created; created != NULL; created = created->next)
		if (&created->state == context) {
			if (created->state.magic == CUDA_NATIVE_CONTEXT_MAGIC &&
			    created->state.references != 0)
				return (created->state.device);
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
	void *provider_context = NULL;

	pthread_mutex_lock(&context_lock);
	if (device->primary_state.references == UINT_MAX) {
		result = CUDA_ERROR_OUT_OF_MEMORY;
	} else {
		if (device->primary_state.references == 0) {
			/* The first reference opens what the context needs:
			 * an RM client and a device for the nvrm provider,
			 * a synthetic model for the fake one.  A provider
			 * that fails here fails the retain: the context is
			 * not created without what it needs. */
			if (device->provider->mem != NULL) {
				result = device->provider->mem->context_create(
				    device->physical_index, &provider_context);
				if (result != CUDA_SUCCESS) {
					pthread_mutex_unlock(&context_lock);
					return (result);
				}
			}
			device->primary_state.magic = CUDA_NATIVE_CONTEXT_MAGIC;
			device->primary_state.device = device;
			device->primary_state.provider_context = provider_context;
		}
		device->primary_state.references++;
		*context = &device->primary_state;
	}
	pthread_mutex_unlock(&context_lock);
	return (result);
}

/* Free one allocation with the provider it came from.  The provider's
 * context is still alive when this runs. */
void
cuda_registry_free_allocation(cuda_allocation *entry)
{
	cuda_device *device;
	const cuda_mem_ops *ops;

	device = entry->context->device;
	ops = device->provider->mem;
	if (ops != NULL) {
		if (entry->host)
			(void)ops->host_free(entry->object);
		else
			(void)ops->device_free(entry->object);
	}
	free(entry);
}

/* Take the allocations of a context out of the registry.  The caller frees
 * them with the provider, outside the lock. */
static cuda_allocation *
take_allocations(struct CUctx_st *context)
{
	cuda_allocation **link, *entry, *taken = NULL;

	pthread_mutex_lock(&context_lock);
	link = &registry.allocations;
	while ((entry = *link) != NULL) {
		if (entry->context != context) {
			link = &entry->next;
			continue;
		}
		*link = entry->next;
		entry->next = taken;
		taken = entry;
	}
	pthread_mutex_unlock(&context_lock);
	return (taken);
}

/* Free every allocation of a context that is going away. */
static void
release_allocations(struct CUctx_st *context)
{
	cuda_allocation *entry, *next;

	entry = take_allocations(context);
	while (entry != NULL) {
		next = entry->next;
		cuda_registry_free_allocation(entry);
		entry = next;
	}
}

CUresult
cuda_registry_primary_release(cuda_device *device)
{
	CUresult result = CUDA_SUCCESS;
	void *provider_context = NULL;

	pthread_mutex_lock(&context_lock);
	if (device->primary_state.references == 0) {
		result = CUDA_ERROR_INVALID_CONTEXT;
	} else {
		device->primary_state.references--;
		if (device->primary_state.references == 0) {
			device->primary_state.magic = 0;
			provider_context = device->primary_state.provider_context;
			device->primary_state.provider_context = NULL;
			if (current_context == &device->primary_state)
				current_context = NULL;
		}
	}
	pthread_mutex_unlock(&context_lock);
	if (result != CUDA_SUCCESS)
		return (result);
	/* The allocations go before the provider's context: the provider
	 * frees the memory it made. */
	release_allocations(&device->primary_state);
	if (provider_context != NULL && device->provider->mem != NULL)
		(void)device->provider->mem->context_destroy(provider_context);
	return (result);
}

/* ---- the contexts the caller created ------------------------------------- */

CUresult
cuda_registry_context_create(cuda_device *device, void *provider_context,
    CUcontext *context)
{
	cuda_context *entry;

	if (device == NULL || context == NULL)
		return (CUDA_ERROR_INVALID_VALUE);
	entry = calloc(1, sizeof(*entry));
	if (entry == NULL)
		return (CUDA_ERROR_OUT_OF_MEMORY);
	entry->state.magic = CUDA_NATIVE_CONTEXT_MAGIC;
	entry->state.references = 1;
	entry->state.device = device;
	entry->state.provider_context = provider_context;
	pthread_mutex_lock(&context_lock);
	entry->next = registry.created;
	registry.created = entry;
	pthread_mutex_unlock(&context_lock);
	*context = &entry->state;
	return (CUDA_SUCCESS);
}

CUresult
cuda_registry_context_destroy(CUcontext context)
{
	cuda_context **link, *entry = NULL;
	cuda_device *device;
	void *provider_context = NULL;

	if (context == NULL)
		return (CUDA_ERROR_INVALID_VALUE);
	pthread_mutex_lock(&context_lock);
	for (link = &registry.created; *link != NULL; link = &(*link)->next)
		if (&(*link)->state == context) {
			entry = *link;
			*link = entry->next;
			break;
		}
	if (entry == NULL) {
		pthread_mutex_unlock(&context_lock);
		return (CUDA_ERROR_INVALID_CONTEXT);
	}
	device = entry->state.device;
	provider_context = entry->state.provider_context;
	entry->state.provider_context = NULL;
	entry->state.magic = 0;
	entry->state.references = 0;
	if (current_context == context)
		current_context = NULL;
	pthread_mutex_unlock(&context_lock);
	/* The allocations go before the provider's context: the provider
	 * frees the memory it made. */
	release_allocations(&entry->state);
	if (provider_context != NULL && device != NULL &&
	    device->provider->mem != NULL)
		(void)device->provider->mem->context_destroy(provider_context);
	free(entry);
	return (CUDA_SUCCESS);
}

/* The state of a context: the primary one of a device, or one the caller
 * created. */
static struct CUctx_st *
context_state(CUcontext context)
{
	cuda_context *created;
	unsigned i;

	if (context == NULL)
		return (NULL);
	pthread_mutex_lock(&context_lock);
	for (created = registry.created; created != NULL; created = created->next)
		if (&created->state == context) {
			struct CUctx_st *state = &created->state;

			pthread_mutex_unlock(&context_lock);
			return (state);
		}
	for (i = 0; i < registry.physical_count; i++)
		if (&registry.physical[i].primary_state == context) {
			struct CUctx_st *state = &registry.physical[i].primary_state;

			pthread_mutex_unlock(&context_lock);
			return (state);
		}
	pthread_mutex_unlock(&context_lock);
	return (NULL);
}

void *
cuda_registry_context_provider(CUcontext context)
{
	struct CUctx_st *state = context_state(context);

	return (state == NULL ? NULL : state->provider_context);
}

cuda_device *
cuda_registry_context_device(CUcontext context)
{
	struct CUctx_st *state = context_state(context);

	return (state == NULL ? NULL : state->device);
}

/* ---- the allocations -------------------------------------------------------- */

CUresult
cuda_registry_allocate(struct CUctx_st *context, int host, size_t bytes,
    cuda_allocation **allocation)
{
	const cuda_mem_ops *ops;
	cuda_allocation *entry;
	void *object = NULL, *host_address = NULL;
	uint64_t device_ptr = 0;
	CUresult result;

	if (context == NULL || allocation == NULL || context->device == NULL)
		return (CUDA_ERROR_INVALID_VALUE);
	ops = context->device->provider->mem;
	if (ops == NULL) {
		cuda_reason_set("the provider of this device has no memory "
		    "backend");
		return (CUDA_ERROR_NOT_SUPPORTED);
	}
	entry = calloc(1, sizeof(*entry));
	if (entry == NULL)
		return (CUDA_ERROR_OUT_OF_MEMORY);
	if (host)
		result = ops->host_alloc(context->provider_context, bytes,
		    &object, &host_address, &device_ptr);
	else
		result = ops->device_alloc(context->provider_context, bytes,
		    &object, &device_ptr);
	if (result != CUDA_SUCCESS) {
		free(entry);
		return (result);
	}
	entry->device_ptr = (CUdeviceptr)device_ptr;
	entry->object = object;
	entry->host_address = host_address;
	entry->bytes = bytes;
	entry->host = host;
	entry->context = context;
	pthread_mutex_lock(&context_lock);
	entry->next = registry.allocations;
	registry.allocations = entry;
	pthread_mutex_unlock(&context_lock);
	*allocation = entry;
	return (CUDA_SUCCESS);
}

cuda_allocation *
cuda_registry_find(CUdeviceptr device_ptr)
{
	cuda_allocation *entry;

	pthread_mutex_lock(&context_lock);
	for (entry = registry.allocations; entry != NULL; entry = entry->next)
		if (entry->device_ptr == device_ptr)
			break;
	pthread_mutex_unlock(&context_lock);
	return (entry);
}

/* The allocation whose range holds a device address, or null when no
 * allocation holds it. */
cuda_allocation *
cuda_registry_find_at(CUdeviceptr pointer)
{
	cuda_allocation *entry;

	pthread_mutex_lock(&context_lock);
	for (entry = registry.allocations; entry != NULL; entry = entry->next)
		if (pointer >= entry->device_ptr &&
		    (uint64_t)(pointer - entry->device_ptr) < entry->bytes)
			break;
	pthread_mutex_unlock(&context_lock);
	return (entry);
}

/* The host allocation of a host address, or null when no allocation has
 * it. */
cuda_allocation *
cuda_registry_find_host(void *address)
{
	cuda_allocation *entry;

	pthread_mutex_lock(&context_lock);
	for (entry = registry.allocations; entry != NULL; entry = entry->next)
		if (entry->host && entry->host_address == address)
			break;
	pthread_mutex_unlock(&context_lock);
	return (entry);
}

cuda_allocation *
cuda_registry_take(CUdeviceptr device_ptr)
{
	cuda_allocation **link, *entry = NULL;

	pthread_mutex_lock(&context_lock);
	for (link = &registry.allocations; *link != NULL; link = &(*link)->next)
		if ((*link)->device_ptr == device_ptr) {
			entry = *link;
			*link = entry->next;
			break;
		}
	pthread_mutex_unlock(&context_lock);
	return (entry);
}

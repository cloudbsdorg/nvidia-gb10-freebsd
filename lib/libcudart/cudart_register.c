/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The registration contract of clang's CUDA mode.  The generated code of a
 * CUDA module registers its fat binary, registers every kernel of it with
 * the host stub that stands for the kernel on the host, and then launches
 * the kernel through that stub.  The runtime keeps the registrations, so a
 * launch can be answered by the name of its kernel.
 */
#include <pthread.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "cudart_internal.h"

/* The wrapper clang's generated code hands to the registration. */
struct cudart_fatbin_wrapper {
	int magic;
	int version;
	const void *data;
	void *unused;
};

#define CUDART_FATBIN_WRAPPER_MAGIC 0x466243b1
#define CUDART_FATBIN_MAGIC "CUDA-NATIVE-STUB-FATBIN 1\n"
#define CUDART_FATBIN_TERMINATOR "---\n"
/* The header of a fat binary is bounded; the scan of it stops there. */
#define CUDART_FATBIN_HEADER_LIMIT (64 * 1024)

/* One registered kernel.  The list is in registration order. */
struct cudart_kernel {
	struct cudart_kernel *next;
	const void *host_stub;
	char *name;
};

/* One registered fat binary.  The handle is the first member, so the
 * handle the registration hands out is the address of the record and the
 * registration takes it back. */
struct cudart_fatbin {
	void *handle;
	unsigned members;
	struct cudart_kernel **kernels;
	size_t kernel_count;
	size_t kernel_capacity;
};

_Static_assert(offsetof(struct cudart_fatbin, handle) == 0,
    "the handle must be first: the record is cast back from the handle");

static struct cudart_kernel *kernel_list;
static unsigned kernel_total;
static struct cudart_fatbin *fatbins[CUDART_MAX_FATBINS];
static size_t fatbin_count;
static pthread_mutex_t registry_lock = PTHREAD_MUTEX_INITIALIZER;

/* The configuration of the launch that follows.  It is per thread: two
 * threads that launch at the same time have their own configuration. */
struct cudart_launch_config {
	dim3 grid;
	dim3 block;
	size_t shared_mem;
	void *stream;
};

static _Thread_local struct cudart_launch_config launch_config;

/* The record of a fat binary, from the handle it was given. */
static struct cudart_fatbin *
fatbin_from_handle(void **handle)
{
	return ((struct cudart_fatbin *)handle);
}

/*
 * The members of the container of this SDK: a magic line, one line per
 * member, and a terminator line.  The runtime counts the members of the
 * header; it does not read the images, because the driver cannot load
 * them yet.
 */
static int
container_members(const char *data, unsigned *members)
{
	size_t used = sizeof(CUDART_FATBIN_MAGIC) - 1;
	const char *line = data + used;
	unsigned count = 0;

	for (;;) {
		size_t limit = CUDART_FATBIN_HEADER_LIMIT - used;
		const char *newline;
		size_t length, offset;
		int nul = 0;

		if (limit == 0)
			return (-1);
		newline = memchr(line, '\n', limit);
		if (newline == NULL)
			return (-1);
		length = (size_t)(newline - line) + 1;
		for (offset = 0; offset < length; offset++)
			if (line[offset] == '\0') {
				nul = 1;
				break;
			}
		if (nul)
			return (-1);
		if (length == sizeof(CUDART_FATBIN_TERMINATOR) - 1 &&
		    memcmp(line, CUDART_FATBIN_TERMINATOR, length) == 0) {
			*members = count;
			return (0);
		}
		count++;
		used += length;
		line = newline + 1;
	}
}

static void **
fatbin_refused(const char *reason)
{
	fprintf(stderr, "libcudart: %s; the fat binary was not registered\n",
	    reason);
	return (NULL);
}
void **
__cudaRegisterFatBinary(void *wrapper_pointer)
{
	struct cudart_fatbin_wrapper *wrapper = wrapper_pointer;
	struct cudart_fatbin *record;
	unsigned members = 0;

	if (wrapper == NULL || wrapper->magic != CUDART_FATBIN_WRAPPER_MAGIC)
		return (fatbin_refused("the fat binary wrapper is not one of ours"));
	if (wrapper->data == NULL)
		return (fatbin_refused("the fat binary carries no data"));
	if (memcmp(wrapper->data, CUDART_FATBIN_MAGIC,
	    sizeof(CUDART_FATBIN_MAGIC) - 1) != 0)
		return (fatbin_refused(
		    "the fat binary data is not a container of this SDK"));
	if (container_members(wrapper->data, &members) != 0)
		return (fatbin_refused(
		    "the fat binary header does not end where it must"));

	pthread_mutex_lock(&registry_lock);
	if (fatbin_count >= CUDART_MAX_FATBINS) {
		pthread_mutex_unlock(&registry_lock);
		return (fatbin_refused("the runtime holds as many fat binaries "
		    "as it can"));
	}
	record = calloc(1, sizeof(*record));
	if (record == NULL) {
		pthread_mutex_unlock(&registry_lock);
		return (fatbin_refused("host memory is exhausted"));
	}
	record->members = members;
	fatbins[fatbin_count++] = record;
	pthread_mutex_unlock(&registry_lock);
	return (&record->handle);
}

void
__cudaRegisterFatBinaryEnd(void **handle)
{
	/* Every kernel of the fat binary is registered by the time the
	 * registration ends; the runtime keeps the registration as it is. */
	(void)handle;
}

void
__cudaUnregisterFatBinary(void **handle)
{
	struct cudart_fatbin *record;
	size_t index, i;

	if (handle == NULL)
		return;
	pthread_mutex_lock(&registry_lock);
	for (index = 0; index < fatbin_count; index++)
		if (fatbins[index] == fatbin_from_handle(handle))
			break;
	if (index == fatbin_count) {
		pthread_mutex_unlock(&registry_lock);
		return;
	}
	record = fatbins[index];
	for (i = index + 1; i < fatbin_count; i++)
		fatbins[i - 1] = fatbins[i];
	fatbin_count--;
	for (i = 0; i < record->kernel_count; i++) {
		struct cudart_kernel *previous = NULL;
		struct cudart_kernel *current = kernel_list;

		while (current != NULL) {
			if (current == record->kernels[i]) {
				if (previous == NULL)
					kernel_list = current->next;
				else
					previous->next = current->next;
				free(current->name);
				free(current);
				kernel_total--;
				break;
			}
			previous = current;
			current = current->next;
		}
	}
	free(record->kernels);
	free(record);
	pthread_mutex_unlock(&registry_lock);
}

/* #lizard forgives -- clang's CUDA registration ABI passes exactly ten arguments */
int
__cudaRegisterFunction(void **handle, const void *host_func,
    const char *device_func, const char *device_name, int thread_limit,
    void *tid, void *bid, void *block_dim, void *grid_dim, void *word_size)
{
	struct cudart_fatbin *record = NULL;
	struct cudart_kernel *kernel;
	const char *name;
	size_t i, capacity;

	(void)thread_limit;
	(void)tid;
	(void)bid;
	(void)block_dim;
	(void)grid_dim;
	(void)word_size;
	if (handle == NULL)
		return (1);

	pthread_mutex_lock(&registry_lock);
	for (i = 0; i < fatbin_count; i++)
		if (fatbins[i] == fatbin_from_handle(handle)) {
			record = fatbins[i];
			break;
		}
	if (record == NULL || kernel_total >= CUDART_MAX_KERNELS) {
		pthread_mutex_unlock(&registry_lock);
		return (1);
	}
	/* The room for the kernel is made before the kernel is made, so a
	 * failure leaves the registration as it was. */
	if (record->kernel_count == record->kernel_capacity) {
		struct cudart_kernel **kernels;

		capacity = record->kernel_capacity == 0 ? 4 :
		    record->kernel_capacity * 2;
		kernels = realloc(record->kernels, capacity * sizeof(*kernels));
		if (kernels == NULL) {
			pthread_mutex_unlock(&registry_lock);
			return (1);
		}
		record->kernels = kernels;
		record->kernel_capacity = capacity;
	}
	kernel = calloc(1, sizeof(*kernel));
	if (kernel == NULL) {
		pthread_mutex_unlock(&registry_lock);
		return (1);
	}
	/* The name of the kernel is the one the fat binary gives it; the
	 * device function name is the same name in the form the driver
	 * uses. */
	name = device_name != NULL ? device_name : device_func;
	if (name == NULL)
		name = "";
	kernel->name = strdup(name);
	if (kernel->name == NULL) {
		free(kernel);
		pthread_mutex_unlock(&registry_lock);
		return (1);
	}
	kernel->host_stub = host_func;
	/* The list keeps the order of the registration. */
	if (kernel_list == NULL) {
		kernel_list = kernel;
	} else {
		struct cudart_kernel *last = kernel_list;

		while (last->next != NULL)
			last = last->next;
		last->next = kernel;
	}
	kernel_total++;
	record->kernels[record->kernel_count++] = kernel;
	pthread_mutex_unlock(&registry_lock);
	return (0);
}

void
__cudaRegisterVar(void **handle, void *host_var, const char *device_address,
    const char *device_name, int external, size_t size, int constant,
    int global)
{
	/* The runtime holds no variable of a device: the driver cannot
	 * read one yet. */
	(void)handle;
	(void)host_var;
	(void)device_address;
	(void)device_name;
	(void)external;
	(void)size;
	(void)constant;
	(void)global;
}

void
__cudaRegisterManagedVar(void **handle, void *host_var,
    const char *device_address, const char *device_name, size_t size,
    int flags)
{
	(void)handle;
	(void)host_var;
	(void)device_address;
	(void)device_name;
	(void)size;
	(void)flags;
}

void
__cudaRegisterSurface(void **handle, void *host_var,
    const char *device_address, const char *device_name, int external,
    int dim)
{
	(void)handle;
	(void)host_var;
	(void)device_address;
	(void)device_name;
	(void)external;
	(void)dim;
}

void
__cudaRegisterTexture(void **handle, void *host_var,
    const char *device_address, const char *device_name, int normalized,
    int external, int dim)
{
	(void)handle;
	(void)host_var;
	(void)device_address;
	(void)device_name;
	(void)normalized;
	(void)external;
	(void)dim;
}

unsigned int
__cudaPushCallConfiguration(dim3 gridDim, dim3 blockDim, size_t sharedMem,
    void *stream)
{
	launch_config.grid = gridDim;
	launch_config.block = blockDim;
	launch_config.shared_mem = sharedMem;
	launch_config.stream = stream;
	return (0);
}

int
__cudaPopCallConfiguration(dim3 *gridDim, dim3 *blockDim, size_t *sharedMem,
    void **stream)
{
	if (gridDim != NULL)
		*gridDim = launch_config.grid;
	if (blockDim != NULL)
		*blockDim = launch_config.block;
	if (sharedMem != NULL)
		*sharedMem = launch_config.shared_mem;
	if (stream != NULL)
		*stream = launch_config.stream;
	return (0);
}

const char *
cudart_kernel_lookup(const void *host_stub)
{
	/* The name is copied out under the lock: the registration of a
	 * kernel can be taken away by another thread, and the caller must
	 * not read a name that is gone. */
	static _Thread_local char buffer[256];
	struct cudart_kernel *kernel;
	int found = 0;

	pthread_mutex_lock(&registry_lock);
	for (kernel = kernel_list; kernel != NULL; kernel = kernel->next)
		if (kernel->host_stub == host_stub) {
			if (strlen(kernel->name) < sizeof(buffer)) {
				memcpy(buffer, kernel->name,
				    strlen(kernel->name) + 1);
				found = 1;
			}
			break;
		}
	pthread_mutex_unlock(&registry_lock);
	return (found ? buffer : NULL);
}

unsigned
cudart_kernel_count(void)
{
	unsigned count;

	pthread_mutex_lock(&registry_lock);
	count = kernel_total;
	pthread_mutex_unlock(&registry_lock);
	return (count);
}

int
cudart_kernel_name_at(unsigned index, char *buffer, size_t size)
{
	struct cudart_kernel *kernel;
	unsigned position = 0;
	int found = 0;

	if (buffer == NULL || size == 0)
		return (0);
	pthread_mutex_lock(&registry_lock);
	for (kernel = kernel_list; kernel != NULL; kernel = kernel->next) {
		if (position == index) {
			/* The name is written whole or not at all. */
			if (strlen(kernel->name) < size) {
				memcpy(buffer, kernel->name,
				    strlen(kernel->name) + 1);
				found = 1;
			}
			break;
		}
		position++;
	}
	pthread_mutex_unlock(&registry_lock);
	return (found);
}

unsigned
cudaNativeKernelCount(void)
{
	return (cudart_kernel_count());
}

int
cudaNativeKernelName(unsigned index, char *buffer, size_t size)
{
	return (cudart_kernel_name_at(index, buffer, size));
}

int
cudaNativeKernelHostStub(const void *hostStub, char *buffer, size_t size)
{
	const char *name;

	if (buffer == NULL || size == 0)
		return (0);
	name = cudart_kernel_lookup(hostStub);
	if (name == NULL)
		return (0);
	if (strlen(name) >= size)
		return (0);
	memcpy(buffer, name, strlen(name) + 1);
	return (1);
}

unsigned
cudaNativeFatBinaryCount(void)
{
	unsigned count;

	pthread_mutex_lock(&registry_lock);
	count = (unsigned)fatbin_count;
	pthread_mutex_unlock(&registry_lock);
	return (count);
}

int
cudaNativeFatBinaryMembers(unsigned index, unsigned *members)
{
	int found = 0;

	if (members == NULL)
		return (0);
	pthread_mutex_lock(&registry_lock);
	if (index < fatbin_count) {
		*members = fatbins[index]->members;
		found = 1;
	}
	pthread_mutex_unlock(&registry_lock);
	return (found);
}

/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * cudart_stub.c - a linkable, non-executing cuda-native runtime stub (C1.1).
 * This is not the CUDA runtime: every launch fails with 801, and the real
 * libcudart is Track #2430.  Signatures come from clang's wrapper declaration
 * and host LLVM IR.  Registration validates our fatbin container and keeps
 * per-fatbin host-side records; it never submits anything to a GPU.
 */

#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CUDA_NATIVE_SUCCESS 0
#define CUDA_NATIVE_ERROR_NOT_SUPPORTED 801
#define CUDA_NATIVE_FATBIN_WRAPPER_MAGIC 0x466243b1
#define CUDA_NATIVE_FATBIN_MAGIC "CUDA-NATIVE-STUB-FATBIN 1\n"
#define CUDA_NATIVE_MEMBER_PREFIX "member kind="
#define CUDA_NATIVE_FATBIN_HEADER_LIMIT (64 * 1024)
#define CUDA_NATIVE_FATBIN_MEMBER_LIMIT 64

struct cuda_native_dim3 {
	unsigned int x, y, z;
};

struct cuda_native_launch_config {
	struct cuda_native_dim3 grid;
	struct cuda_native_dim3 block;
	size_t shared_mem;
	void *stream;
};

struct cuda_native_fatbin_wrapper {
	int magic;
	int version;
	const void *data;
	void *unused;
};

struct cuda_native_fatbin_record {
	void *handle;
	size_t functions;
	char **kernel_names;
};
_Static_assert(offsetof(struct cuda_native_fatbin_record, handle) == 0,
    "handle must be first: record_from_handle casts it back");

static _Thread_local struct cuda_native_launch_config launch_config;

static FILE *
trace_open(void)
{
	const char *value = getenv("CUDA_NATIVE_STUB_TRACE");

	if (value == NULL || *value == '\0')
		return NULL;
	if (strcmp(value, "1") == 0)
		return stderr;
	return fopen(value, "a");
}

static void
trace_close(FILE *stream)
{
	if (stream != NULL && stream != stderr)
		fclose(stream);
}

static void
trace_json_string(FILE *stream, const char *name)
{
	const unsigned char *p = (const unsigned char *)(name != NULL ? name : "");

	fputc('"', stream);
	/* Time: O(name length).  Space: O(1). */
	for (; *p != '\0'; p++) {
		switch (*p) {
		case '"':
			fputs("\\\"", stream);
			break;
		case '\\':
			fputs("\\\\", stream);
			break;
		default:
			if (*p < 0x20)
				fprintf(stream, "\\u%04x", (unsigned int)*p);
			else
				fputc(*p, stream);
			break;
		}
	}
	fputc('"', stream);
}

static void
trace_register_fatbin(size_t members)
{
	FILE *stream = trace_open();

	if (stream == NULL)
		return;
	fprintf(stream, "{\"event\":\"register_fatbin\",\"members\":%zu}\n",
	    members);
	trace_close(stream);
}

static void
trace_register_refused(const char *reason)
{
	FILE *stream = trace_open();

	if (stream == NULL)
		return;
	fputs("{\"event\":\"register_fatbin\",\"refused\":true,\"reason\":", stream);
	trace_json_string(stream, reason);
	fputs("}\n", stream);
	trace_close(stream);
}

static void
trace_register_function(const char *name, const void *handle)
{
	FILE *stream = trace_open();

	if (stream == NULL)
		return;
	fputs("{\"event\":\"register_function\",", stream);
	if (handle == NULL)
		fputs("\"handle\":null,", stream);
	fputs("\"name\":", stream);
	trace_json_string(stream, name);
	fputs("}\n", stream);
	trace_close(stream);
}

static void
trace_simple(const char *event, const void *handle)
{
	FILE *stream = trace_open();

	if (stream == NULL)
		return;
	fprintf(stream, "{\"event\":\"%s\"", event);
	if (handle == NULL)
		fputs(",\"handle\":null", stream);
	fputs("}\n", stream);
	trace_close(stream);
}

static void
trace_launch(int status)
{
	FILE *stream = trace_open();

	if (stream == NULL)
		return;
	fprintf(stream, "{\"event\":\"launch\",\"status\":%d}\n", status);
	trace_close(stream);
}

static void **
invalid_fatbin(const char *reason)
{
	fprintf(stderr, "libcudart-stub: %s; rebuild the object with "
	    "--cuda-path=<cuda-native SDK> so its fatbinary stub is used\n", reason);
	trace_register_refused(reason);
	return NULL;
}

static int
consume_digits(const char **cursor, const char *end)
{
	const char *start = *cursor;

	/* Time: O(digits).  Space: O(1). */
	while (*cursor < end && **cursor >= '0' && **cursor <= '9')
		(*cursor)++;
	return *cursor == start ? -1 : 0;
}

static int
consume_literal(const char **cursor, const char *end, const char *literal,
    size_t length)
{
	if ((size_t)(end - *cursor) < length ||
	    memcmp(*cursor, literal, length) != 0)
		return -1;
	*cursor += length;
	return 0;
}

static int
consume_member_kind(const char **cursor, const char *end)
{
	if (consume_literal(cursor, end, "elf", 3) != 0 &&
	    consume_literal(cursor, end, "ptx", 3) != 0)
		return -1;
	return 0;
}

static int
valid_sha256(const char *p, const char *end)
{
	if ((size_t)(end - p) != 64)
		return 0;
	/* Time: O(hash length).  Space: O(1). */
	while (p < end) {
		if ((*p < '0' || *p > '9') && (*p < 'a' || *p > 'f'))
			return 0;
		p++;
	}
	return 1;
}

static int
valid_member_line(const char *line, size_t length)
{
	const char *p = line;
	const char *end;

	if (length == 0 || line[length - 1] != '\n')
		return 0;
	end = line + length - 1;
	if (consume_literal(&p, end, CUDA_NATIVE_MEMBER_PREFIX,
	    sizeof(CUDA_NATIVE_MEMBER_PREFIX) - 1) != 0)
		return 0;
	if (consume_member_kind(&p, end) != 0)
		return 0;
	if (consume_literal(&p, end, " sm=", 4) != 0)
		return 0;
	if (consume_digits(&p, end) != 0)
		return 0;
	if (consume_literal(&p, end, " size=", 6) != 0)
		return 0;
	if (consume_digits(&p, end) != 0)
		return 0;
	if (consume_literal(&p, end, " sha256=", 8) != 0)
		return 0;
	return valid_sha256(p, end);
}

/* The generated fatbin has a bounded header followed by opaque bytes. */
static int
count_fatbin_members(const char *data, size_t *member_count)
{
	const char *line = data + sizeof(CUDA_NATIVE_FATBIN_MAGIC) - 1;
	size_t used = sizeof(CUDA_NATIVE_FATBIN_MAGIC) - 1;
	size_t count = 0;

	/* Time: O(header bytes), capped at 64 KiB.  Space: O(1). */
	for (;;) {
		const char *newline;
		size_t length;

		if (used >= CUDA_NATIVE_FATBIN_HEADER_LIMIT)
			return -1;
		newline = memchr(line, '\n', CUDA_NATIVE_FATBIN_HEADER_LIMIT - used);
		if (newline == NULL)
			return -1;
		length = (size_t)(newline - line) + 1;
		if (length == 4 && memcmp(line, "---\n", 4) == 0) {
			*member_count = count;
			return 0;
		}
		if (count >= CUDA_NATIVE_FATBIN_MEMBER_LIMIT ||
		    !valid_member_line(line, length))
			return -1;
		count++;
		used += length;
		line = newline + 1;
	}
}

static struct cuda_native_fatbin_record *
record_from_handle(void **handle)
{
	return (struct cuda_native_fatbin_record *)handle;
}

unsigned int
__cudaPushCallConfiguration(struct cuda_native_dim3 grid,
    struct cuda_native_dim3 block, size_t shared_mem, void *stream)
{
	launch_config.grid = grid;
	launch_config.block = block;
	launch_config.shared_mem = shared_mem;
	launch_config.stream = stream;
	return CUDA_NATIVE_SUCCESS;
}

int
__cudaPopCallConfiguration(struct cuda_native_dim3 *grid,
    struct cuda_native_dim3 *block, size_t *shared_mem, void **stream)
{
	if (grid != NULL)
		*grid = launch_config.grid;
	if (block != NULL)
		*block = launch_config.block;
	if (shared_mem != NULL)
		*shared_mem = launch_config.shared_mem;
	if (stream != NULL)
		*stream = launch_config.stream;
	return CUDA_NATIVE_SUCCESS;
}

int
cudaLaunchKernel(const void *func, struct cuda_native_dim3 grid,
    struct cuda_native_dim3 block, void **args, size_t shared_mem,
    void *stream)
{
	(void)func;
	(void)grid;
	(void)block;
	(void)args;
	(void)shared_mem;
	(void)stream;
	trace_launch(CUDA_NATIVE_ERROR_NOT_SUPPORTED);
	return CUDA_NATIVE_ERROR_NOT_SUPPORTED;
}

void **
__cudaRegisterFatBinary(void *wrapper_pointer)
{
	struct cuda_native_fatbin_wrapper *wrapper = wrapper_pointer;
	struct cuda_native_fatbin_record *record;
	const char *data;
	size_t members;

	if (wrapper == NULL || wrapper->magic != CUDA_NATIVE_FATBIN_WRAPPER_MAGIC)
		return invalid_fatbin("invalid fatbin wrapper magic");
	if (wrapper->data == NULL)
		return invalid_fatbin("fatbin data is null");
	data = wrapper->data;
	if (memcmp(data, CUDA_NATIVE_FATBIN_MAGIC,
	    sizeof(CUDA_NATIVE_FATBIN_MAGIC) - 1) != 0)
		return invalid_fatbin("invalid cuda-native fatbin data magic");
	if (count_fatbin_members(data, &members) != 0)
		return invalid_fatbin("malformed cuda-native fatbin header");
	record = calloc(1, sizeof(*record));
	if (record == NULL)
		return invalid_fatbin("cannot allocate a fatbin registration");
	trace_register_fatbin(members);
	return &record->handle;
}

void
__cudaRegisterFatBinaryEnd(void **handle)
{
	trace_simple("register_fatbin_end", handle);
}

void
__cudaUnregisterFatBinary(void **handle)
{
	struct cuda_native_fatbin_record *record;
	size_t i;

	trace_simple("unregister_fatbin", handle);
	if (handle == NULL)
		return;
	record = record_from_handle(handle);
	/* Time: O(registered kernel names).  Space: O(1). */
	for (i = 0; i < record->functions; i++)
		free(record->kernel_names[i]);
	free(record->kernel_names);
	free(record);
}

/* #lizard forgives -- clang's CUDA registration ABI passes exactly ten arguments */
int
__cudaRegisterFunction(void **handle, const void *host_func,
    const char *device_func, const char *device_name, int thread_limit,
    void *tid, void *bid, void *block_dim, void *grid_dim, void *word_size)
{
	struct cuda_native_fatbin_record *record;
	const char *name = device_name != NULL ? device_name : "";
	char **names;
	char *copy;
	size_t length;

	(void)host_func;
	(void)device_func;
	(void)thread_limit;
	(void)tid;
	(void)bid;
	(void)block_dim;
	(void)grid_dim;
	(void)word_size;
	if (handle == NULL) {
		trace_register_function(name, NULL);
		return 1;
	}
	record = record_from_handle(handle);
	length = strlen(name);
	names = realloc(record->kernel_names,
	    (record->functions + 1) * sizeof(*names));
	if (names == NULL)
		return 1;
	record->kernel_names = names;
	copy = malloc(length + 1);
	if (copy == NULL)
		return 1;
	memcpy(copy, name, length + 1);
	record->kernel_names[record->functions] = copy;
	record->functions++;
	trace_register_function(name, handle);
	return CUDA_NATIVE_SUCCESS;
}

void
__cudaRegisterVar(void **handle, void *host_var, const char *device_address,
    const char *device_name, int external, size_t size, int constant,
    int global)
{
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
    const char *device_address, const char *device_name, size_t size, int flags)
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
    const char *device_address, const char *device_name, int external, int dim)
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

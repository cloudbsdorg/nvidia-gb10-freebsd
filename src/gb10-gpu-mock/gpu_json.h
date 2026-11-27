/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-3-Clause
 *
 * gpu_json.h - a small JSON reader for the GPU mock's model files.  It reads
 * the subset a model file uses (objects, arrays, strings, numbers, booleans
 * and null) and refuses anything else: a model file is data, and a typo in
 * it must be an error, never a silently dropped value.
 *
 * The whole tree lives in one arena: gpu_json_free() releases it all.
 */
#ifndef _GPU_JSON_H_
#define _GPU_JSON_H_

#include <stdint.h>
#include <stddef.h>

enum gpu_json_type {
	GPU_JSON_NULL = 0,
	GPU_JSON_BOOL,
	GPU_JSON_NUMBER,
	GPU_JSON_STRING,
	GPU_JSON_ARRAY,
	GPU_JSON_OBJECT
};

struct gpu_json;

/* The arena: every node and every string of one parse. */
struct gpu_json_arena;

/*
 * Parse a buffer.  Returns the root node, or NULL with *err naming the
 * reason (the byte offset and what was expected).  The root of a document
 * that is not an object or an array is refused: a model file is one object.
 */
struct gpu_json *gpu_json_parse(const char *text, size_t len,
    struct gpu_json_arena **arena, char *err, size_t errlen);

void	gpu_json_arena_free(struct gpu_json_arena *arena);

enum gpu_json_type gpu_json_type(const struct gpu_json *v);

/* The member named KEY of an object, or NULL. */
const struct gpu_json *gpu_json_get(const struct gpu_json *obj,
    const char *key);

/* The item at INDEX of an array, or NULL. */
const struct gpu_json *gpu_json_at(const struct gpu_json *arr, size_t index);

/* The number of items of an array or the members of an object. */
size_t	gpu_json_count(const struct gpu_json *v);

/* The name of a member of an object (the member at INDEX). */
const char *gpu_json_key(const struct gpu_json *obj, size_t index);

/* An integer value.  Refuses a number that is not an exact integer. */
int	gpu_json_int(const struct gpu_json *v, int64_t *out);

/* A string value, copied into BUF (always NUL terminated). */
int	gpu_json_str(const struct gpu_json *v, char *buf, size_t len);

/* A boolean value. */
int	gpu_json_bool(const struct gpu_json *v, int *out);

/*
 * A number as a string, so a hexadecimal id keeps its written form.  Only a
 * number node is accepted.
 */
int	gpu_json_num_text(const struct gpu_json *v, char *buf, size_t len);

#endif /* _GPU_JSON_H_ */

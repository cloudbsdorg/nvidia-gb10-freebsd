/* gdb_json.c - the JSON of the answers.
 *
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * A small tree of values, and a writer that prints it the way the tool
 * prints it: json.dumps(document, indent=1) of Python.  The export of a
 * run has to be the same document a live run prints, and the only way
 * to be sure of that is to print it the same way.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "gdb_internal.h"

#define GDB_JSON_NULL	0
#define GDB_JSON_BOOL	1
#define GDB_JSON_INT	2
#define GDB_JSON_NUMBER	3
#define GDB_JSON_STRING	4
#define GDB_JSON_ARRAY	5
#define GDB_JSON_OBJECT	6

struct gdb_json {
	int			 type;
	int			 bval;
	long long		 ival;
	double			 nval;
	char			*sval;
	struct gdb_json		**items;
	char			**keys;
	size_t			 n;
	size_t			 cap;
};

static struct gdb_json *
json_new(int type)
{
	struct gdb_json *node = calloc(1, sizeof(*node));

	if (node == NULL)
		return (NULL);
	node->type = type;
	return (node);
}

struct gdb_json *
gdb_json_object(void)
{
	return (json_new(GDB_JSON_OBJECT));
}

struct gdb_json *
gdb_json_array(void)
{
	return (json_new(GDB_JSON_ARRAY));
}

struct gdb_json *
gdb_json_string(const char *text)
{
	struct gdb_json *node = json_new(GDB_JSON_STRING);

	if (node == NULL)
		return (NULL);
	node->sval = strdup(text ? text : "");
	if (node->sval == NULL) {
		free(node);
		return (NULL);
	}
	return (node);
}

struct gdb_json *
gdb_json_int(long long value)
{
	struct gdb_json *node = json_new(GDB_JSON_INT);

	if (node == NULL)
		return (NULL);
	node->ival = value;
	return (node);
}

struct gdb_json *
gdb_json_number(double value)
{
	struct gdb_json *node = json_new(GDB_JSON_NUMBER);

	if (node == NULL)
		return (NULL);
	node->nval = value;
	return (node);
}

struct gdb_json *
gdb_json_bool(int value)
{
	struct gdb_json *node = json_new(GDB_JSON_BOOL);

	if (node == NULL)
		return (NULL);
	node->bval = value ? 1 : 0;
	return (node);
}

struct gdb_json *
gdb_json_null(void)
{
	return (json_new(GDB_JSON_NULL));
}

void
gdb_json_free(struct gdb_json *node)
{
	size_t i;

	if (node == NULL)
		return;
	for (i = 0; i < node->n; i++) {
		if (node->keys != NULL)
			free(node->keys[i]);
		gdb_json_free(node->items[i]);
	}
	free(node->items);
	free(node->keys);
	free(node->sval);
	free(node);
}

/* Add a value to an array, or a value with a key to an object. */
int
gdb_json_put(struct gdb_json *parent, const char *key, struct gdb_json *value)
{
	struct gdb_json **items;
	char **keys;

	if (parent == NULL || value == NULL) {
		gdb_json_free(value);
		return (-1);
	}
	if (parent->n == parent->cap) {
		size_t cap = parent->cap ? parent->cap * 2 : 8;

		items = realloc(parent->items, cap * sizeof(*items));
		if (items == NULL) {
			gdb_json_free(value);
			return (-1);
		}
		parent->items = items;
		if (parent->type == GDB_JSON_OBJECT) {
			keys = realloc(parent->keys, cap * sizeof(*keys));
			if (keys == NULL) {
				gdb_json_free(value);
				return (-1);
			}
			parent->keys = keys;
		}
		parent->cap = cap;
	}
	parent->items[parent->n] = value;
	if (parent->type == GDB_JSON_OBJECT)
		parent->keys[parent->n] = strdup(key ? key : "");
	parent->n++;
	return (0);
}

/* --- the writer ------------------------------------------------------------ */

/* The text of a string, as JSON writes it. */
static int
json_write_string(struct gdb_buf *buf, const char *text)
{
	const unsigned char *p = (const unsigned char *)text;

	if (gdb_buf_add(buf, "\"") != 0)
		return (-1);
	for (; *p != '\0'; p++) {
		int rc = 0;

		switch (*p) {
		case '"':
			rc = gdb_buf_add(buf, "\\\"");
			break;
		case '\\':
			rc = gdb_buf_add(buf, "\\\\");
			break;
		case '\b':
			rc = gdb_buf_add(buf, "\\b");
			break;
		case '\f':
			rc = gdb_buf_add(buf, "\\f");
			break;
		case '\n':
			rc = gdb_buf_add(buf, "\\n");
			break;
		case '\r':
			rc = gdb_buf_add(buf, "\\r");
			break;
		case '\t':
			rc = gdb_buf_add(buf, "\\t");
			break;
		default:
			if (*p < 0x20 || *p > 0x7e)
				rc = gdb_buf_addf(buf, "\\u%04x", (unsigned)*p);
			else
				rc = gdb_buf_addf(buf, "%c", (char)*p);
			break;
		}
		if (rc != 0)
			return (-1);
	}
	return (gdb_buf_add(buf, "\""));
}

/* The number of a JSON number: the same text Python prints. */
static int
json_write_number(struct gdb_buf *buf, double value)
{
	char text[64];

	if (value == (double)(long long)value && value < 1e16 && value > -1e16)
		snprintf(text, sizeof(text), "%lld", (long long)value);
	else
		snprintf(text, sizeof(text), "%.17g", value);
	return (gdb_buf_add(buf, text));
}

static int json_write(struct gdb_buf *buf, const struct gdb_json *node,
    int depth);

/* The indentation of one line: one space for each level. */
static int
json_indent(struct gdb_buf *buf, int depth)
{
	int j;

	for (j = 0; j < depth; j++)
		if (gdb_buf_add(buf, " ") != 0)
			return (-1);
	return (0);
}

/* The body of one item of a list: what is written between the
 * indentation and the comma that ends the item. */
typedef int (*json_item_body)(struct gdb_buf *, const struct gdb_json *,
    int, size_t);

/* The items of a list: one per line, each one indented one level
 * deeper, the items separated by a comma.  The body of an item is
 * written by the caller: an array item is a value, an object item is a
 * pair. */
static int
json_write_items(struct gdb_buf *buf, const struct gdb_json *node, int depth,
    json_item_body body)
{
	size_t i;

	for (i = 0; i < node->n; i++) {
		if (json_indent(buf, depth + 1) != 0)
			return (-1);
		if (body(buf, node, depth + 1, i) != 0)
			return (-1);
		if (i + 1 < node->n && gdb_buf_add(buf, ",") != 0)
			return (-1);
		if (gdb_buf_add(buf, "\n") != 0)
			return (-1);
	}
	if (json_indent(buf, depth) != 0)
		return (-1);
	return (0);
}

/* The body of an item of an array: the value itself. */
static int
json_write_array_item(struct gdb_buf *buf, const struct gdb_json *node,
    int depth, size_t index)
{
	return (json_write(buf, node->items[index], depth));
}

/* The body of an item of an object: the key, then the value. */
static int
json_write_object_item(struct gdb_buf *buf, const struct gdb_json *node,
    int depth, size_t index)
{
	if (json_write_string(buf, node->keys[index]) != 0)
		return (-1);
	if (gdb_buf_add(buf, ": ") != 0)
		return (-1);
	return (json_write(buf, node->items[index], depth));
}

/* An array: one item per line, each one indented one level deeper. */
static int
json_write_array(struct gdb_buf *buf, const struct gdb_json *node, int depth)
{
	if (node->n == 0)
		return (gdb_buf_add(buf, "[]"));
	if (gdb_buf_add(buf, "[\n") != 0)
		return (-1);
	if (json_write_items(buf, node, depth, json_write_array_item) != 0)
		return (-1);
	return (gdb_buf_add(buf, "]"));
}

/* An object: one pair per line, each one indented one level deeper. */
static int
json_write_object(struct gdb_buf *buf, const struct gdb_json *node, int depth)
{
	if (node->n == 0)
		return (gdb_buf_add(buf, "{}"));
	if (gdb_buf_add(buf, "{\n") != 0)
		return (-1);
	if (json_write_items(buf, node, depth, json_write_object_item) != 0)
		return (-1);
	return (gdb_buf_add(buf, "}"));
}

static int
json_write_item(struct gdb_buf *buf, const struct gdb_json *node, int depth)
{
	switch (node->type) {
	case GDB_JSON_NULL:
		return (gdb_buf_add(buf, "null"));
	case GDB_JSON_BOOL:
		return (gdb_buf_add(buf, node->bval ? "true" : "false"));
	case GDB_JSON_INT:
		return (gdb_buf_addf(buf, "%lld", node->ival));
	case GDB_JSON_NUMBER:
		return (json_write_number(buf, node->nval));
	case GDB_JSON_STRING:
		return (json_write_string(buf, node->sval));
	case GDB_JSON_ARRAY:
		return (json_write_array(buf, node, depth));
	case GDB_JSON_OBJECT:
		return (json_write_object(buf, node, depth));
	default:
		return (gdb_buf_add(buf, "null"));
	}
}

static int
json_write(struct gdb_buf *buf, const struct gdb_json *node, int depth)
{
	return (json_write_item(buf, node, depth));
}

/* How many items a node holds.  A document that has no steps says so
 * by not having the key at all, and a caller has to know that an empty
 * array and a missing array are not the same thing. */
size_t
gdb_json_count(const struct gdb_json *node)
{
	if (node == NULL)
		return (0);
	return (node->n);
}

/* The document as text.  The caller frees it. */
char *
gdb_json_render(const struct gdb_json *node)
{
	struct gdb_buf buf;

	gdb_buf_init(&buf);
	if (json_write(&buf, node, 0) != 0) {
		gdb_buf_free(&buf);
		return (NULL);
	}
	return (gdb_buf_take(&buf));
}

/* --- the growing text ----------------------------------------------------- */

void
gdb_buf_init(struct gdb_buf *buf)
{
	memset(buf, 0, sizeof(*buf));
}

void
gdb_buf_free(struct gdb_buf *buf)
{
	if (buf == NULL)
		return;
	free(buf->data);
	buf->data = NULL;
	buf->len = 0;
	buf->cap = 0;
}

static int
buf_reserve(struct gdb_buf *buf, size_t extra)
{
	size_t need = buf->len + extra + 1;
	char *data;
	size_t cap;

	if (need <= buf->cap)
		return (0);
	cap = buf->cap ? buf->cap : 256;
	while (cap < need)
		cap *= 2;
	data = realloc(buf->data, cap);
	if (data == NULL) {
		buf->failed = 1;
		return (-1);
	}
	buf->data = data;
	buf->cap = cap;
	return (0);
}

int
gdb_buf_add(struct gdb_buf *buf, const char *text)
{
	size_t len;

	if (buf == NULL || text == NULL)
		return (-1);
	len = strlen(text);
	if (buf_reserve(buf, len) != 0)
		return (-1);
	memcpy(buf->data + buf->len, text, len);
	buf->len += len;
	buf->data[buf->len] = '\0';
	return (0);
}

int
gdb_buf_addf(struct gdb_buf *buf, const char *fmt, ...)
{
	va_list ap;
	char text[1024];
	int len;

	if (buf == NULL)
		return (-1);
	va_start(ap, fmt);
	len = vsnprintf(text, sizeof(text), fmt, ap);
	va_end(ap);
	if (len < 0)
		return (-1);
	if ((size_t)len >= sizeof(text))
		len = (int)sizeof(text) - 1;
	return (gdb_buf_add(buf, text));
}

int
gdb_buf_add_json(struct gdb_buf *buf, const char *text)
{
	return (json_write_string(buf, text));
}

int
gdb_buf_add_json_num(struct gdb_buf *buf, double value)
{
	return (json_write_number(buf, value));
}

char *
gdb_buf_take(struct gdb_buf *buf)
{
	char *data = buf->data;

	buf->data = NULL;
	buf->len = 0;
	buf->cap = 0;
	return (data);
}

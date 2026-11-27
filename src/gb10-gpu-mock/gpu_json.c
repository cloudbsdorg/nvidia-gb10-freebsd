/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-3-Clause
 *
 * gpu_json.c - the small JSON reader of gpu_json.h.  A hand written recursive
 * descent parser: it walks the text once, builds the tree in one arena and
 * refuses what it does not understand.  Every failure names the byte offset
 * and what was expected, so a broken model file says where it broke.
 */
#include <ctype.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "gpu_json.h"

#define GPU_JSON_MAX_DEPTH	32

struct gpu_json {
	enum gpu_json_type type;
	int		b;		/* boolean */
	int		is_int;		/* the number is an exact integer */
	int64_t		i;		/* number, exact integer */
	double		d;		/* number */
	char		*s;		/* string: the decoded text */
	char		*numtext;	/* number: the written form */
	size_t		count;		/* array items, object members */
	struct gpu_json **items;
	char		**keys;
};

struct gpu_json_arena {
	void	**ptrs;
	size_t	 n, cap;
};

static int
arena_add(struct gpu_json_arena *a, void *p)
{
	if (a->n == a->cap) {
		size_t want = a->cap ? a->cap * 2 : 64;
		void **grown = realloc(a->ptrs, want * sizeof(*grown));

		if (grown == NULL)
			return (-1);
		a->ptrs = grown;
		a->cap = want;
	}
	a->ptrs[a->n++] = p;
	return (0);
}

/* ---- the parser ---------------------------------------------------------- */

struct gpu_json_parser {
	const char	*text;
	size_t		 len;
	size_t		 pos;
	int		 depth;
	struct gpu_json_arena *arena;
	char		*err;
	size_t		 errlen;
	int		 failed;
};

static struct gpu_json *parse_value(struct gpu_json_parser *p);

static void
fail(struct gpu_json_parser *p, const char *what)
{
	if (p->failed)
		return;
	p->failed = 1;
	snprintf(p->err, p->errlen, "byte %zu: %s", p->pos, what);
}

static void
skip_space(struct gpu_json_parser *p)
{
	while (p->pos < p->len) {
		unsigned char c = (unsigned char)p->text[p->pos];

		if (c == ' ' || c == '\t' || c == '\n' || c == '\r')
			p->pos++;
		else
			break;
	}
}

static struct gpu_json *
node_new(struct gpu_json_parser *p, enum gpu_json_type type)
{
	struct gpu_json *v = calloc(1, sizeof(*v));

	if (v == NULL) {
		fail(p, "out of memory");
		return (NULL);
	}
	v->type = type;
	if (arena_add(p->arena, v) != 0) {
		fail(p, "out of memory");
		return (NULL);
	}
	return (v);
}

static int
hex4(const char *s, unsigned *out)
{
	unsigned v = 0, i;

	for (i = 0; i < 4; i++) {
		char c = s[i];

		v <<= 4;
		if (c >= '0' && c <= '9')
			v |= (unsigned)(c - '0');
		else if (c >= 'a' && c <= 'f')
			v |= (unsigned)(c - 'a' + 10);
		else if (c >= 'A' && c <= 'F')
			v |= (unsigned)(c - 'A' + 10);
		else
			return (-1);
	}
	*out = v;
	return (0);
}

/* Write one code point as UTF-8.  Returns the bytes written. */
static size_t
utf8_put(unsigned cp, char *out)
{
	if (cp < 0x80) {
		out[0] = (char)cp;
		return (1);
	}
	if (cp < 0x800) {
		out[0] = (char)(0xc0 | (cp >> 6));
		out[1] = (char)(0x80 | (cp & 0x3f));
		return (2);
	}
	if (cp < 0x10000) {
		out[0] = (char)(0xe0 | (cp >> 12));
		out[1] = (char)(0x80 | ((cp >> 6) & 0x3f));
		out[2] = (char)(0x80 | (cp & 0x3f));
		return (3);
	}
	out[0] = (char)(0xf0 | (cp >> 18));
	out[1] = (char)(0x80 | ((cp >> 12) & 0x3f));
	out[2] = (char)(0x80 | ((cp >> 6) & 0x3f));
	out[3] = (char)(0x80 | (cp & 0x3f));
	return (4);
}

/*
 * A \u escape: the code point it names.  A surrogate pair is two escapes,
 * so the second one is read here too.
 */
static int
parse_unicode(struct gpu_json_parser *p, unsigned *cpp)
{
	unsigned cp;

	if (p->pos + 5 > p->len) {
		fail(p, "a \\u escape is cut short");
		return (-1);
	}
	if (hex4(p->text + p->pos + 1, &cp) != 0) {
		fail(p, "a \\u escape is not four hexadecimal digits");
		return (-1);
	}
	p->pos += 5;
	if (cp >= 0xd800 && cp <= 0xdbff && p->pos + 6 <= p->len &&
	    p->text[p->pos] == '\\' && p->text[p->pos + 1] == 'u') {
		unsigned lo;

		if (hex4(p->text + p->pos + 2, &lo) == 0 && lo >= 0xdc00 &&
		    lo <= 0xdfff) {
			cp = 0x10000 + ((cp - 0xd800) << 10) + (lo - 0xdc00);
			p->pos += 6;
		}
	}
	*cpp = cp;
	return (0);
}

/*
 * One escape: the character it stands for, written to the output.  The
 * output pointer moves on, so the caller keeps writing where it left off.
 */
static int
parse_escape(struct gpu_json_parser *p, char **wp)
{
	char *w = *wp;

	switch (p->text[p->pos]) {
	case '"':
		*w++ = '"';
		p->pos++;
		break;
	case '\\':
		*w++ = '\\';
		p->pos++;
		break;
	case '/':
		*w++ = '/';
		p->pos++;
		break;
	case 'b':
		*w++ = '\b';
		p->pos++;
		break;
	case 'f':
		*w++ = '\f';
		p->pos++;
		break;
	case 'n':
		*w++ = '\n';
		p->pos++;
		break;
	case 'r':
		*w++ = '\r';
		p->pos++;
		break;
	case 't':
		*w++ = '\t';
		p->pos++;
		break;
	case 'u': {
		unsigned cp;

		if (parse_unicode(p, &cp) != 0)
			return (-1);
		w += utf8_put(cp, w);
		break;
	}
	default:
		fail(p, "an unknown escape");
		return (-1);
	}
	*wp = w;
	return (0);
}

/* A string literal.  The decoded text is at most as long as the literal. */
static char *
parse_string(struct gpu_json_parser *p)
{
	size_t start, cap;
	char *out, *w;

	if (p->pos >= p->len || p->text[p->pos] != '"') {
		fail(p, "a string was expected");
		return (NULL);
	}
	p->pos++;
	start = p->pos;
	/* The literal is at most len bytes; the decoded text is never longer. */
	cap = p->len - start + 1;
	out = malloc(cap);
	if (out == NULL) {
		fail(p, "out of memory");
		return (NULL);
	}
	if (arena_add(p->arena, out) != 0) {
		fail(p, "out of memory");
		return (NULL);
	}
	w = out;
	while (p->pos < p->len) {
		unsigned char c = (unsigned char)p->text[p->pos];

		if (c == '"') {
			p->pos++;
			*w = '\0';
			return (out);
		}
		if (c == '\\') {
			p->pos++;
			if (p->pos >= p->len)
				break;
			if (parse_escape(p, &w) != 0)
				return (NULL);
			continue;
		}
		if (c < 0x20) {
			fail(p, "a control byte in a string");
			return (NULL);
		}
		*w++ = (char)c;
		p->pos++;
	}
	fail(p, "a string is not closed");
	return (NULL);
}

/* The digits of a number. */
static void
scan_digits(struct gpu_json_parser *p)
{
	while (p->pos < p->len && isdigit((unsigned char)p->text[p->pos]))
		p->pos++;
}

/*
 * The value of a number: the double always, and the integer when the
 * number is an exact one.
 */
static int
number_value(struct gpu_json_parser *p, const char *text, struct gpu_json *v)
{
	char *end = NULL;
	int64_t i;

	v->d = strtod(text, &end);
	if (end == NULL || *end != '\0') {
		fail(p, "a number is not a number");
		return (-1);
	}
	errno = 0;
	i = (int64_t)strtoll(text, &end, 10);
	v->i = i;
	v->is_int = (errno == 0 && end != NULL && *end == '\0' &&
	    (double)i == v->d);
	return (0);
}

static struct gpu_json *
parse_number(struct gpu_json_parser *p)
{
	size_t start = p->pos;
	struct gpu_json *v;
	char text[64];
	size_t n;

	if (p->pos < p->len && p->text[p->pos] == '-')
		p->pos++;
	scan_digits(p);
	if (p->pos < p->len && p->text[p->pos] == '.') {
		p->pos++;
		scan_digits(p);
	}
	if (p->pos < p->len && (p->text[p->pos] == 'e' ||
	    p->text[p->pos] == 'E')) {
		p->pos++;
		if (p->pos < p->len && (p->text[p->pos] == '+' ||
		    p->text[p->pos] == '-'))
			p->pos++;
		scan_digits(p);
	}
	n = p->pos - start;
	if (n == 0 || n >= sizeof(text)) {
		fail(p, "a number was expected");
		return (NULL);
	}
	memcpy(text, p->text + start, n);
	text[n] = '\0';
	v = node_new(p, GPU_JSON_NUMBER);
	if (v == NULL)
		return (NULL);
	v->numtext = strdup(text);
	if (v->numtext == NULL || arena_add(p->arena, v->numtext) != 0) {
		fail(p, "out of memory");
		return (NULL);
	}
	if (number_value(p, text, v) != 0)
		return (NULL);
	return (v);
}

static int
append_item(struct gpu_json_parser *p, struct gpu_json *v,
    struct gpu_json *item)
{
	struct gpu_json **grown = realloc(v->items,
	    (v->count + 1) * sizeof(*grown));

	if (grown == NULL) {
		fail(p, "out of memory");
		return (-1);
	}
	v->items = grown;
	v->items[v->count++] = item;
	return (0);
}

static int
append_member(struct gpu_json_parser *p, struct gpu_json *v, char *key,
    struct gpu_json *item)
{
	struct gpu_json **grown = realloc(v->items,
	    (v->count + 1) * sizeof(*grown));
	char **keys = realloc(v->keys, (v->count + 1) * sizeof(*keys));

	if (grown == NULL || keys == NULL) {
		fail(p, "out of memory");
		return (-1);
	}
	v->items = grown;
	v->keys = keys;
	v->keys[v->count] = key;
	v->items[v->count++] = item;
	return (0);
}

static struct gpu_json *
parse_array(struct gpu_json_parser *p)
{
	struct gpu_json *v = node_new(p, GPU_JSON_ARRAY);

	if (v == NULL)
		return (NULL);
	p->pos++;			/* the '[' */
	skip_space(p);
	if (p->pos < p->len && p->text[p->pos] == ']') {
		p->pos++;
		return (v);
	}
	for (;;) {
		struct gpu_json *item = parse_value(p);

		if (item == NULL)
			return (NULL);
		if (append_item(p, v, item) != 0)
			return (NULL);
		skip_space(p);
		if (p->pos < p->len && p->text[p->pos] == ',') {
			p->pos++;
			skip_space(p);
			continue;
		}
		if (p->pos < p->len && p->text[p->pos] == ']') {
			p->pos++;
			return (v);
		}
		fail(p, "a ',' or ']' was expected");
		return (NULL);
	}
}

static struct gpu_json *
parse_object(struct gpu_json_parser *p)
{
	struct gpu_json *v = node_new(p, GPU_JSON_OBJECT);

	if (v == NULL)
		return (NULL);
	p->pos++;			/* the '{' */
	skip_space(p);
	if (p->pos < p->len && p->text[p->pos] == '}') {
		p->pos++;
		return (v);
	}
	for (;;) {
		char *key;
		struct gpu_json *item;

		skip_space(p);
		key = parse_string(p);
		if (key == NULL)
			return (NULL);
		skip_space(p);
		if (p->pos >= p->len || p->text[p->pos] != ':') {
			fail(p, "a ':' was expected");
			return (NULL);
		}
		p->pos++;
		item = parse_value(p);
		if (item == NULL)
			return (NULL);
		if (append_member(p, v, key, item) != 0)
			return (NULL);
		skip_space(p);
		if (p->pos < p->len && p->text[p->pos] == ',') {
			p->pos++;
			continue;
		}
		if (p->pos < p->len && p->text[p->pos] == '}') {
			p->pos++;
			return (v);
		}
		fail(p, "a ',' or '}' was expected");
		return (NULL);
	}
}

/* A boolean node. */
static struct gpu_json *
bool_node(struct gpu_json_parser *p, int value)
{
	struct gpu_json *v = node_new(p, GPU_JSON_BOOL);

	if (v == NULL)
		return (NULL);
	v->b = value;
	return (v);
}

/*
 * The literals: true, false and null.  A word that starts like one of them
 * but is not one is not a literal at all: nothing is read and NULL comes
 * back.
 */
static struct gpu_json *
parse_literal(struct gpu_json_parser *p)
{
	switch (p->text[p->pos]) {
	case 't':
		if (p->len - p->pos >= 4 &&
		    memcmp(p->text + p->pos, "true", 4) == 0) {
			p->pos += 4;
			return (bool_node(p, 1));
		}
		break;
	case 'f':
		if (p->len - p->pos >= 5 &&
		    memcmp(p->text + p->pos, "false", 5) == 0) {
			p->pos += 5;
			return (bool_node(p, 0));
		}
		break;
	case 'n':
		if (p->len - p->pos >= 4 &&
		    memcmp(p->text + p->pos, "null", 4) == 0) {
			p->pos += 4;
			return (node_new(p, GPU_JSON_NULL));
		}
		break;
	default:
		break;
	}
	return (NULL);
}

static struct gpu_json *
parse_value(struct gpu_json_parser *p)
{
	struct gpu_json *v;

	if (p->failed)
		return (NULL);
	if (p->depth >= GPU_JSON_MAX_DEPTH) {
		fail(p, "the document is nested too deeply");
		return (NULL);
	}
	skip_space(p);
	if (p->pos >= p->len) {
		fail(p, "a value was expected");
		return (NULL);
	}
	switch (p->text[p->pos]) {
	case '{':
		p->depth++;
		v = parse_object(p);
		p->depth--;
		return (v);
	case '[':
		p->depth++;
		v = parse_array(p);
		p->depth--;
		return (v);
	case '"': {
		char *s = parse_string(p);

		if (s == NULL)
			return (NULL);
		v = node_new(p, GPU_JSON_STRING);
		if (v == NULL)
			return (NULL);
		v->s = s;
		return (v);
	}
	default:
		break;
	}
	v = parse_literal(p);
	if (v != NULL || p->failed)
		return (v);
	if (p->text[p->pos] == '-' ||
	    isdigit((unsigned char)p->text[p->pos]))
		return (parse_number(p));
	fail(p, "a value was expected");
	return (NULL);
}

struct gpu_json *
gpu_json_parse(const char *text, size_t len, struct gpu_json_arena **arena,
    char *err, size_t errlen)
{
	struct gpu_json_parser p = { 0 };
	struct gpu_json *root;

	*arena = NULL;
	p.text = text;
	p.len = len;
	p.err = err;
	p.errlen = errlen;
	p.arena = calloc(1, sizeof(*p.arena));
	if (p.arena == NULL) {
		snprintf(err, errlen, "out of memory");
		return (NULL);
	}
	root = parse_value(&p);
	if (root == NULL || p.failed) {
		if (!p.failed)
			snprintf(err, errlen, "the document is empty");
		gpu_json_arena_free(p.arena);
		return (NULL);
	}
	skip_space(&p);
	if (p.pos != p.len) {
		snprintf(err, errlen, "byte %zu: trailing text after the "
		    "document", p.pos);
		gpu_json_arena_free(p.arena);
		return (NULL);
	}
	*arena = p.arena;
	return (root);
}

void
gpu_json_arena_free(struct gpu_json_arena *arena)
{
	size_t i;

	if (arena == NULL)
		return;
	for (i = 0; i < arena->n; i++)
		free(arena->ptrs[i]);
	free(arena->ptrs);
	free(arena);
}

/* ---- reading ------------------------------------------------------------- */

enum gpu_json_type
gpu_json_type(const struct gpu_json *v)
{
	return (v == NULL ? GPU_JSON_NULL : v->type);
}

const struct gpu_json *
gpu_json_get(const struct gpu_json *obj, const char *key)
{
	size_t i;

	if (obj == NULL || obj->type != GPU_JSON_OBJECT || key == NULL)
		return (NULL);
	for (i = 0; i < obj->count; i++)
		if (strcmp(obj->keys[i], key) == 0)
			return (obj->items[i]);
	return (NULL);
}

const struct gpu_json *
gpu_json_at(const struct gpu_json *arr, size_t index)
{
	if (arr == NULL || arr->type != GPU_JSON_ARRAY || index >= arr->count)
		return (NULL);
	return (arr->items[index]);
}

size_t
gpu_json_count(const struct gpu_json *v)
{
	if (v == NULL)
		return (0);
	if (v->type != GPU_JSON_ARRAY && v->type != GPU_JSON_OBJECT)
		return (0);
	return (v->count);
}

const char *
gpu_json_key(const struct gpu_json *obj, size_t index)
{
	if (obj == NULL || obj->type != GPU_JSON_OBJECT ||
	    index >= obj->count)
		return (NULL);
	return (obj->keys[index]);
}

int
gpu_json_int(const struct gpu_json *v, int64_t *out)
{
	if (v == NULL || v->type != GPU_JSON_NUMBER || !v->is_int)
		return (-1);
	*out = v->i;
	return (0);
}

int
gpu_json_str(const struct gpu_json *v, char *buf, size_t len)
{
	if (v == NULL || v->type != GPU_JSON_STRING || len == 0)
		return (-1);
	snprintf(buf, len, "%s", v->s);
	return (0);
}

int
gpu_json_bool(const struct gpu_json *v, int *out)
{
	if (v == NULL || v->type != GPU_JSON_BOOL)
		return (-1);
	*out = v->b;
	return (0);
}

int
gpu_json_num_text(const struct gpu_json *v, char *buf, size_t len)
{
	if (v == NULL || v->type != GPU_JSON_NUMBER || len == 0)
		return (-1);
	snprintf(buf, len, "%s", v->numtext);
	return (0);
}

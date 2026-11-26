/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * fatbin_reader_test.c - the unit test for the cuda-native fatbin container
 * reader and writer (Track #2427, slice 1).
 *
 * The test builds containers with the writer, reads them back with the
 * reader and checks that every refusal the reader promises happens, each
 * with its own named error.  It also opens a file given on the command line
 * and prints the named error it finds, so a shell test can drive the same
 * checks from outside and so a mutant reader can be caught.
 *
 * Every case writes down the message it expects.  The message is the
 * oracle of the case: it is never taken from the reader, and no table of
 * errors is copied into this file.
 *
 * usage: fatbin_reader_test          run the unit checks
 *        fatbin_reader_test FILE     open FILE and print what the reader says
 *        fatbin_reader_test --write-cases DIR
 *                                    write the crafted containers into DIR
 *
 * Exit status: the number of failed checks.
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "cnfatbin.h"

static int passed = 0;
static int failures = 0;

/*
 * The reader asks the host for the members of a container.  The test makes
 * that ask fail, so the refusal is seen without the host running out of
 * memory.  The build of this test links with --wrap=calloc, so the ask
 * goes through the wrapper below.
 */
static int calloc_fails;

void *__real_calloc(size_t count, size_t size);

void *
__wrap_calloc(size_t count, size_t size)
{
	if (calloc_fails)
		return NULL;
	return __real_calloc(count, size);
}

static void
ok(const char *name)
{
	passed++;
	printf("ok   %s\n", name);
}

static void
bad(const char *name)
{
	failures++;
	printf("FAIL %s\n", name);
}

/* Write a little-endian 16 bit value into a buffer. */
static void
put_le16(uint8_t *p, uint16_t value)
{
	p[0] = (uint8_t)(value & 0xff);
	p[1] = (uint8_t)((value >> 8) & 0xff);
}

/* Write a little-endian 32 bit value into a buffer. */
static void
put_le32(uint8_t *p, uint32_t value)
{
	int i;

	for (i = 0; i < 4; i++)
		p[i] = (uint8_t)((value >> (8 * i)) & 0xff);
}

/* Write a little-endian 64 bit value into a buffer. */
static void
put_le64(uint8_t *p, uint64_t value)
{
	int i;

	for (i = 0; i < 8; i++)
		p[i] = (uint8_t)((value >> (8 * i)) & 0xff);
}

/* Read a little-endian 64 bit value from a buffer. */
static uint64_t
get_le64(const uint8_t *p)
{
	uint64_t value = 0;
	int i;

	for (i = 0; i < 8; i++)
		value |= (uint64_t)p[i] << (8 * i);
	return value;
}

/*
 * Build a container with one PTX member, one PTX member with an a suffix and
 * one cubin member.  The caller frees the result with cnfatbin_buffer_free().
 */
static uint8_t *
build_container(size_t *size, size_t *member_count, size_t *ptx_size)
{
	static const char ptx[] =
	    ".target sm_120\n.visible .entry k() { ret; }\n";
	static const char cubin[] = "CUDA-NATIVE-STUB-CUBIN 1\npayload\n";
	struct cnfatbin_input inputs[3];
	uint8_t *buffer = NULL;
	size_t total = 0;

	memset(inputs, 0, sizeof(inputs));
	inputs[0].kind = CNFATBIN_KIND_PTX;
	inputs[0].sm = 120;
	inputs[0].data = (const uint8_t *)ptx;
	inputs[0].size = sizeof(ptx) - 1;
	inputs[1].kind = CNFATBIN_KIND_PTX;
	inputs[1].sm = 121;
	inputs[1].suffix = 'a';
	inputs[1].data = (const uint8_t *)ptx;
	inputs[1].size = sizeof(ptx) - 1;
	inputs[2].kind = CNFATBIN_KIND_CUBIN;
	inputs[2].sm = 120;
	inputs[2].data = (const uint8_t *)cubin;
	inputs[2].size = sizeof(cubin) - 1;
	if (cnfatbin_write(inputs, 3, &buffer, &total) != CNFATBIN_OK)
		return NULL;
	*size = total;
	*member_count = 3;
	*ptx_size = sizeof(ptx) - 1;
	return buffer;
}

/* A copy of a container, so one test can change it without touching others. */
static uint8_t *
copy_bytes(const uint8_t *data, size_t size)
{
	uint8_t *copy = malloc(size);

	if (copy == NULL)
		return NULL;
	memcpy(copy, data, size);
	return copy;
}

/*
 * The list of crafted containers.  It is filled as the cases are built, and
 * --write-cases writes every container in it.
 */
static void add_case(const char *name, uint8_t *data, size_t size);

/* Open a container and report the error it gives. */
static enum cnfatbin_error
open_copy(const uint8_t *data, size_t size)
{
	struct cnfatbin_container container;
	enum cnfatbin_error err;

	err = cnfatbin_open(data, size, &container);
	if (err == CNFATBIN_OK)
		cnfatbin_close(&container);
	return err;
}

/*
 * Check that one broken container is refused with the message the case
 * expects.  The message is the oracle of the case.
 *
 * A refused container is left empty: the data pointer, the size, the member
 * count and the member table are all zero.  The container is poisoned
 * before the open, so a reader that leaves something of the container
 * behind is caught.
 */
static void
expect_error(const char *name, const uint8_t *data, size_t size,
    const char *message)
{
	struct cnfatbin_container opened;
	enum cnfatbin_error got;

	memset(&opened, 0xaa, sizeof(opened));
	got = cnfatbin_open(data, size, &opened);
	if (got != CNFATBIN_OK && strcmp(cnfatbin_strerror(got), message) == 0 &&
	    opened.data == NULL && opened.size == 0 &&
	    opened.entries_count == 0 && opened.members == NULL)
		ok(name);
	else
		bad(name);
}

/*
 * Find the string record of the first member whose value is the given text,
 * and return its offset in the buffer.  The test looks at the container the
 * way the format documents it, so it can break one value on purpose.
 */
static long
find_string_record(const uint8_t *data, size_t size, const char *text)
{
	uint64_t entries_offset = get_le64(data + 16);
	uint64_t string_offset = get_le64(data + entries_offset + 8);
	uint64_t num_strings = get_le64(data + entries_offset + 16);
	size_t text_length = strlen(text);
	uint64_t i;

	/* Time: O(strings in the first entry).  Space: O(1). */
	for (i = 0; i < num_strings; i++) {
		const uint8_t *record = data + string_offset + i * 24;
		uint64_t value_offset = get_le64(record + 8);

		if (value_offset + text_length > size)
			continue;
		if (memcmp(data + value_offset, text, text_length) == 0)
			return (long)(string_offset + i * 24);
	}
	return -1;
}

/* The offset of the value a string record points at. */
static long
value_offset_of(const uint8_t *data, long record)
{
	return (long)get_le64(data + record + 8);
}

/* What one crafted container breaks. */
enum craft {
	CRAFT_MAGIC,		/* the magic bytes are wrong */
	CRAFT_VERSION,		/* the version is one the reader does not know */
	CRAFT_SIZE,		/* the header claims more than the input holds */
	CRAFT_ENTRIES_OUT,	/* the entries table lies outside the container */
	CRAFT_ENTRIES_EARLY,	/* the entries table starts before the header */
	CRAFT_TOO_MANY,		/* the container claims more entries than it may */
	CRAFT_IMAGE_OUT,	/* an image lies outside the container */
	CRAFT_IMAGE_OVERFLOW,	/* an image offset and size overflow */
	CRAFT_IMAGE_KIND,	/* the image kind is one we do not carry */
	CRAFT_OFFLOAD_KIND,	/* the offload kind is not CUDA */
	CRAFT_STRING_OUT,	/* a string lies outside the container */
	CRAFT_STRING_VALUE,	/* a value has no NUL inside its range */
	CRAFT_SHA256_TEXT,	/* the sha256 is not hexadecimal */
	CRAFT_SHA256_SUM	/* the sha256 does not match the image */
};

/*
 * Break one string of the container: the record whose value is the triple
 * or the digest of the first member.  Returns 0 when the container has no
 * such string, so the case can fail instead of passing by accident.
 */
static int
break_string(uint8_t *broken, size_t size, enum craft way,
    const char *computed)
{
	const char *text = CNFATBIN_TRIPLE;
	long record;
	long value;

	if (way != CRAFT_STRING_OUT)
		text = computed;
	record = find_string_record(broken, size, text);
	if (record < 0)
		return 0;
	value = value_offset_of(broken, record);
	switch (way) {
	case CRAFT_STRING_OUT:
		/* The key of the string points outside the container. */
		put_le64(broken + record, (uint64_t)size + 16);
		break;
	case CRAFT_STRING_VALUE:
		/* Take the NUL away and let the range cover it. */
		broken[value + 64] = 'A';
		put_le64(broken + record + 16, 65);
		break;
	case CRAFT_SHA256_TEXT:
		broken[value] = 'Z';
		break;
	case CRAFT_SHA256_SUM:
		/* A different hexadecimal digit, same length. */
		broken[value] = computed[0] == '0' ? '1' : '0';
		break;
	default:
		break;
	}
	return 1;
}

/*
 * The file name of a crafted case.  The shell test drives the tools over
 * these files, so the name is the one the case is known by.
 */
static const char *
craft_file_name(enum craft way)
{
	switch (way) {
	case CRAFT_MAGIC:
		return "magic";
	case CRAFT_VERSION:
		return "version";
	case CRAFT_SIZE:
		return "size";
	case CRAFT_ENTRIES_OUT:
		return "entries";
	case CRAFT_ENTRIES_EARLY:
		return "entries-early";
	case CRAFT_TOO_MANY:
		return "many";
	case CRAFT_IMAGE_OUT:
		return "image";
	case CRAFT_IMAGE_OVERFLOW:
		return "image-overflow";
	case CRAFT_IMAGE_KIND:
		return "kind";
	case CRAFT_OFFLOAD_KIND:
		return "offload";
	case CRAFT_STRING_OUT:
		return "string";
	case CRAFT_STRING_VALUE:
		return "unterminated";
	case CRAFT_SHA256_TEXT:
		return "hash-format";
	case CRAFT_SHA256_SUM:
		return "hash-mismatch";
	}
	return "unknown";
}

/*
 * Craft a container for one error case: take a copy of a good container,
 * break it in the way the case names and check that the reader refuses it
 * with the message the case expects.  The broken container is kept, so that
 * --write-cases writes it and a shell test can drive the tools over it.
 */
static void
expect_crafted(const char *name, const uint8_t *container, size_t size,
    enum craft way, const char *message)
{
	char computed[CNFATBIN_SHA256_HEX_MAX + 1];
	uint8_t *broken;
	uint64_t entries_offset;

	/* The digest of the first member: three of the cases break it. */
	cnfatbin_sha256_hex(container + get_le64(container + 32 + 24),
	    (size_t)get_le64(container + 32 + 32), computed);
	broken = copy_bytes(container, size);
	if (broken == NULL) {
		bad(name);
		return;
	}
	entries_offset = get_le64(broken + 16);
	switch (way) {
	case CRAFT_MAGIC:
		broken[1] ^= 0xff;
		break;
	case CRAFT_VERSION:
		put_le32(broken + 4, CNFATBIN_VERSION + 1);
		break;
	case CRAFT_SIZE:
		put_le64(broken + 8, (uint64_t)size + 1);
		break;
	case CRAFT_ENTRIES_OUT:
		put_le64(broken + 16, (uint64_t)size + 8);
		break;
	case CRAFT_ENTRIES_EARLY:
		put_le64(broken + 16, 0);
		break;
	case CRAFT_TOO_MANY:
		put_le64(broken + 24, CNFATBIN_MAX_ENTRIES + 1);
		break;
	case CRAFT_IMAGE_OUT:
		put_le64(broken + entries_offset + 24, (uint64_t)size - 4);
		put_le64(broken + entries_offset + 32, 8);
		break;
	case CRAFT_IMAGE_OVERFLOW:
		/* An offset and a size that overflow. */
		put_le64(broken + entries_offset + 24, UINT64_MAX - 3);
		put_le64(broken + entries_offset + 32, 8);
		break;
	case CRAFT_IMAGE_KIND:
		broken[entries_offset] = 1;
		break;
	case CRAFT_OFFLOAD_KIND:
		broken[entries_offset + 2] = 1;
		break;
	case CRAFT_STRING_OUT:
	case CRAFT_STRING_VALUE:
	case CRAFT_SHA256_TEXT:
	case CRAFT_SHA256_SUM:
		if (!break_string(broken, size, way, computed)) {
			bad(name);
			free(broken);
			return;
		}
		break;
	}
	expect_error(name, broken, size, message);
	add_case(craft_file_name(way), broken, size);
}

/* The writer and the reader must agree on every field. */
static void
check_round_trip(const uint8_t *container, size_t size, size_t members,
    size_t ptx_size)
{
	/* What every member must say, in the order they were written. */
	static const uint16_t kinds[3] = {
		CNFATBIN_IMG_PTX, CNFATBIN_IMG_PTX, CNFATBIN_IMG_CUBIN
	};
	static const char *const archs[3] = {
		"sm_120", "sm_121a", "sm_120"
	};
	static const char *const formats[3] = {
		CNFATBIN_FORMAT_PTX, CNFATBIN_FORMAT_PTX, CNFATBIN_FORMAT_CUBIN
	};
	struct cnfatbin_container opened;
	int good;
	size_t i;

	if (cnfatbin_open(container, size, &opened) != CNFATBIN_OK) {
		bad("the writer and the reader agree on every field");
		return;
	}
	good = opened.entries_count == members;
	good = good && opened.version == CNFATBIN_VERSION;
	good = good && opened.members[0].image_size == ptx_size;
	good = good && strcmp(opened.members[0].triple, CNFATBIN_TRIPLE) == 0;
	/* Time: O(members).  Space: O(1). */
	for (i = 0; i < 3; i++) {
		good = good && opened.members[i].image_kind == kinds[i];
		good = good && strcmp(opened.members[i].arch, archs[i]) == 0;
		good = good && opened.members[i].has_format;
		good = good && strcmp(opened.members[i].format, formats[i]) == 0;
		good = good && opened.members[i].has_sha256;
	}
	cnfatbin_close(&opened);
	if (good)
		ok("the writer and the reader agree on every field");
	else
		bad("the writer and the reader agree on every field");
}

/* A short input is refused before anything is read. */
static void
check_short_input(const uint8_t *container)
{
	uint8_t *short_input = malloc(8);

	expect_error("a short input is refused", container, 8,
	    "input is shorter than the container header");
	if (short_input == NULL) {
		bad("the short input case is kept");
		return;
	}
	memcpy(short_input, container, 8);
	add_case("short", short_input, 8);
}

/* The header cases: the magic, the version, the size and the entries. */
static void
check_header_errors(const uint8_t *container, size_t size)
{
	expect_crafted("a bad magic is refused", container, size, CRAFT_MAGIC,
	    "bad container magic");
	expect_crafted("an unknown version is refused", container, size,
	    CRAFT_VERSION, "unknown container version");
	expect_crafted("a size larger than the input is refused", container, size,
	    CRAFT_SIZE, "container size is larger than the input");
	expect_crafted("an entries table outside the container is refused",
	    container, size, CRAFT_ENTRIES_OUT,
	    "the entries table is out of range");
	expect_crafted("an entries table before the header is refused", container,
	    size, CRAFT_ENTRIES_EARLY, "the entries table is out of range");
	expect_crafted("too many entries are refused", container, size,
	    CRAFT_TOO_MANY, "too many entries in the container");
}

/* The image cases: an image that leaves the container. */
static void
check_image_errors(const uint8_t *container, size_t size)
{
	expect_crafted("an image outside the container is refused", container,
	    size, CRAFT_IMAGE_OUT, "a member image is out of range");
	expect_crafted("an image offset and size that overflow are refused",
	    container, size, CRAFT_IMAGE_OVERFLOW,
	    "a member image is out of range");
}

/* The string cases: a string that leaves the container. */
static void
check_string_errors(const uint8_t *container, size_t size)
{
	expect_crafted("a string outside the container is refused", container,
	    size, CRAFT_STRING_OUT, "a member string is out of range");
	expect_crafted("a value that is not NUL terminated is refused",
	    container, size, CRAFT_STRING_VALUE,
	    "a member string value is not NUL terminated");
}

/* The kind cases: an image or offload kind we do not carry. */
static void
check_kind_errors(const uint8_t *container, size_t size)
{
	expect_crafted("an unknown image kind is refused", container, size,
	    CRAFT_IMAGE_KIND,
	    "a member has an image kind other than PTX, cubin or none");
	expect_crafted("an unknown offload kind is refused", container, size,
	    CRAFT_OFFLOAD_KIND,
	    "a member has an unsupported offload kind");
}

/* The digest cases: a sha256 that is not a digest of the image. */
static void
check_sha256_errors(const uint8_t *container, size_t size)
{
	expect_crafted("a sha256 that is not hexadecimal is refused", container,
	    size, CRAFT_SHA256_TEXT,
	    "a member sha256 is not 64 hexadecimal digits");
	expect_crafted("a sha256 that does not match is refused", container, size,
	    CRAFT_SHA256_SUM, "a member sha256 does not match its image");
}

/* A container without our own keys is still readable. */
static void
check_without_our_keys(const uint8_t *container, size_t size)
{
	struct cnfatbin_container opened;
	uint64_t entries_offset;
	uint8_t *broken;
	uint64_t i;
	int good;

	broken = copy_bytes(container, size);
	if (broken == NULL) {
		bad("a container without our keys is readable");
		return;
	}
	entries_offset = get_le64(broken + 16);
	/* Say that every entry holds only the two LLVM keys. */
	/* Time: O(entries in the container).  Space: O(1). */
	for (i = 0; i < 3; i++) {
		uint64_t entry = entries_offset + i * CNFATBIN_ENTRY_SIZE;

		put_le64(broken + entry + 16, 2);
	}
	if (cnfatbin_open(broken, size, &opened) == CNFATBIN_OK) {
		good = opened.entries_count == 3;
		good = good && !opened.members[0].has_format;
		good = good && !opened.members[0].has_sha256;
		good = good && opened.members[0].arch[0] != '\0';
		cnfatbin_close(&opened);
		if (good)
			ok("a container without our keys is readable");
		else
			bad("a container without our keys is readable");
	} else
		bad("a container without our keys is readable");
	free(broken);
}

/*
 * Check that one container opens.  The case names what it expects.
 */
static void
expect_ok(const char *name, const uint8_t *data, size_t size)
{
	if (open_copy(data, size) == CNFATBIN_OK)
		ok(name);
	else
		bad(name);
}

/*
 * A kind of none is a kind the writer did not name: LLVM's own packager
 * writes it, so a reader accepts it.  Every other kind is refused.
 */
static void
check_kind_none(const uint8_t *container, size_t size)
{
	uint8_t *broken = copy_bytes(container, size);
	uint64_t entries_offset;

	if (broken == NULL) {
		bad("a member whose kinds are none is accepted");
		return;
	}
	entries_offset = get_le64(broken + 16);
	put_le16(broken + entries_offset, CNFATBIN_IMG_NONE);
	put_le16(broken + entries_offset + 2, CNFATBIN_OFK_NONE);
	expect_ok("a member whose kinds are none is accepted", broken, size);
	free(broken);
}

/*
 * A container the test builds by hand: the members carry the strings they
 * name and the image they hold, and the layout is the one the format
 * documents.  The caller frees the result with free().
 */
#define RAW_MAX_STRINGS 20
#define RAW_MAX_MEMBERS 4

struct raw_string {
	const char *key;
	const uint8_t *value;
	size_t value_size;
};

struct raw_member {
	size_t string_count;
	struct raw_string strings[RAW_MAX_STRINGS];
	const uint8_t *image;
	size_t image_size;
};

/*
 * The size of a container, rounded up to the alignment the manual
 * documents.  One place rounds, so the two builders below cannot lay a
 * container out differently.
 */
static uint64_t
align_size(uint64_t size)
{
	return (size + CNFATBIN_ALIGNMENT - 1) &
	    ~(uint64_t)(CNFATBIN_ALIGNMENT - 1);
}

/*
 * The memory of a container and the header every container starts with:
 * the magic, the version, the size of the whole container and the number
 * of members.  One place allocates and writes them, so the builders below
 * cannot drift apart.  The size is the size of the whole container and
 * must already be aligned; align_size() rounds it.
 */
static uint8_t *
alloc_container(uint64_t total, uint64_t member_count, size_t *size)
{
	uint8_t *out;

	out = calloc(1, (size_t)total);
	if (out == NULL)
		return NULL;
	memcpy(out, "\x10\xff\x10\xad", 4);
	put_le32(out + 4, CNFATBIN_VERSION);
	put_le64(out + 8, total);
	put_le64(out + 16, CNFATBIN_HEADER_SIZE);
	put_le64(out + 24, member_count);
	*size = (size_t)total;
	return out;
}

static uint8_t *
build_raw(const struct raw_member *members, size_t count, size_t *size)
{
	uint64_t table_offset[RAW_MAX_MEMBERS];
	uint64_t image_offset[RAW_MAX_MEMBERS];
	uint64_t key_offset[RAW_MAX_MEMBERS][RAW_MAX_STRINGS];
	uint64_t value_offset[RAW_MAX_MEMBERS][RAW_MAX_STRINGS];
	uint64_t cursor = CNFATBIN_HEADER_SIZE +
	    (uint64_t)count * CNFATBIN_ENTRY_SIZE;
	uint64_t total;
	uint8_t *out;
	size_t i, j;

	for (i = 0; i < count; i++) {
		table_offset[i] = cursor;
		cursor += (uint64_t)members[i].string_count *
		    CNFATBIN_STRING_ENTRY_SIZE;
	}
	for (i = 0; i < count; i++) {
		for (j = 0; j < members[i].string_count; j++) {
			key_offset[i][j] = cursor;
			cursor += (uint64_t)strlen(members[i].strings[j].key) + 1;
			value_offset[i][j] = cursor;
			cursor += (uint64_t)members[i].strings[j].value_size + 1;
		}
	}
	for (i = 0; i < count; i++) {
		cursor = align_size(cursor);
		image_offset[i] = cursor;
		cursor += (uint64_t)members[i].image_size;
	}
	total = align_size(cursor);
	out = alloc_container(total, count, size);
	if (out == NULL)
		return NULL;
	for (i = 0; i < count; i++) {
		uint8_t *entry = out + CNFATBIN_HEADER_SIZE +
		    i * CNFATBIN_ENTRY_SIZE;
		uint8_t *table = out + table_offset[i];

		put_le16(entry, CNFATBIN_IMG_PTX);
		put_le16(entry + 2, CNFATBIN_OFK_CUDA);
		put_le32(entry + 4, 0);
		put_le64(entry + 8, table_offset[i]);
		put_le64(entry + 16, members[i].string_count);
		put_le64(entry + 24, image_offset[i]);
		put_le64(entry + 32, members[i].image_size);
		for (j = 0; j < members[i].string_count; j++) {
			uint8_t *record = table + j * CNFATBIN_STRING_ENTRY_SIZE;

			put_le64(record, key_offset[i][j]);
			put_le64(record + 8, value_offset[i][j]);
			put_le64(record + 16, members[i].strings[j].value_size);
		}
	}
	/* The strings themselves, packed one after the other. */
	for (i = 0; i < count; i++) {
		for (j = 0; j < members[i].string_count; j++) {
			size_t key_length = strlen(members[i].strings[j].key);

			memcpy(out + key_offset[i][j], members[i].strings[j].key,
			    key_length + 1);
			memcpy(out + value_offset[i][j], members[i].strings[j].value,
			    members[i].strings[j].value_size);
			out[value_offset[i][j] + members[i].strings[j].value_size] =
			    '\0';
		}
	}
	/* The images. */
	for (i = 0; i < count; i++) {
		if (members[i].image_size > 0)
			memcpy(out + image_offset[i], members[i].image,
			    members[i].image_size);
	}
	return out;
}

/* One container the test built by hand. */
struct test_case {
	const char *name;
	uint8_t *data;
	size_t size;
};

#define MAX_CASES 32

static struct test_case cases[MAX_CASES];
static size_t case_count;

/*
 * Add one container to the list of cases.  The list is what the unit
 * checks read and what the shell test drives the tools over, so there is
 * one place that builds a broken container.
 */
static void
add_case(const char *name, uint8_t *data, size_t size)
{
	if (data == NULL || case_count >= MAX_CASES) {
		bad("the crafted cases are built");
		free(data);
		return;
	}
	cases[case_count].name = name;
	cases[case_count].data = data;
	cases[case_count].size = size;
	case_count++;
}

static const struct test_case *
find_case(const char *name)
{
	size_t i;

	for (i = 0; i < case_count; i++) {
		if (strcmp(cases[i].name, name) == 0)
			return &cases[i];
	}
	return NULL;
}

/* The image every case carries, and the values the cases need. */
static const char case_ptx[] =
    ".target sm_120\n.visible .entry k() { ret; }\n";
static const uint8_t arch_invalid[] = { 's', 'm', '_', 0xff, 0xfe };
static const uint8_t arch_control[] = {
	'a', '\n', 'b', 0x1b, ']', '0', ';', 'x', 0x07
};
static uint8_t arch_long[200];
static uint8_t unknown_long[300];
static uint8_t digest_long[65];
static uint8_t zero_digest[64];
static uint8_t big_image[1024 * 1024];

/* A member with the two keys every case starts from. */
static void
plain_member(struct raw_member *member)
{
	memset(member, 0, sizeof(*member));
	member->string_count = 2;
	member->strings[0].key = CNFATBIN_KEY_TRIPLE;
	member->strings[0].value = (const uint8_t *)CNFATBIN_TRIPLE;
	member->strings[0].value_size = strlen(CNFATBIN_TRIPLE);
	member->strings[1].key = CNFATBIN_KEY_ARCH;
	member->strings[1].value = (const uint8_t *)"sm_120";
	member->strings[1].value_size = 6;
	member->image = (const uint8_t *)case_ptx;
	member->image_size = sizeof(case_ptx) - 1;
}

/* The three cases whose only difference is the arch value. */
static void
build_arch_cases(void)
{
	struct raw_member member;
	uint8_t *container;
	size_t size = 0;

	plain_member(&member);
	member.strings[1].value = arch_invalid;
	member.strings[1].value_size = sizeof(arch_invalid);
	container = build_raw(&member, 1, &size);
	add_case("arch-invalid-utf8", container, size);

	member.strings[1].value = arch_control;
	member.strings[1].value_size = sizeof(arch_control);
	container = build_raw(&member, 1, &size);
	add_case("arch-control-bytes", container, size);

	member.strings[1].value = arch_long;
	member.strings[1].value_size = sizeof(arch_long);
	container = build_raw(&member, 1, &size);
	add_case("value-too-long", container, size);
}

/* The two cases whose third key is one the reader does not know. */
static void
build_key_cases(void)
{
	struct raw_member member;
	uint8_t *container;
	size_t size = 0;

	plain_member(&member);
	member.string_count = 3;
	member.strings[2].key = "some.unknown.key";
	member.strings[2].value = unknown_long;
	member.strings[2].value_size = sizeof(unknown_long);
	container = build_raw(&member, 1, &size);
	add_case("unknown-long-key", container, size);

	member.strings[2].key = CNFATBIN_KEY_SHA256;
	member.strings[2].value = digest_long;
	member.strings[2].value_size = sizeof(digest_long);
	container = build_raw(&member, 1, &size);
	add_case("digest-too-long", container, size);
}

/* An entry with more strings than the four the reader knows. */
static void
build_many_strings_case(void)
{
	struct raw_member member;
	uint8_t *container;
	size_t size = 0;
	size_t i;

	plain_member(&member);
	member.string_count = 17;
	for (i = 2; i < 17; i++) {
		member.strings[i].key = "unknown.key";
		member.strings[i].value = unknown_long;
		member.strings[i].value_size = 8;
	}
	container = build_raw(&member, 1, &size);
	add_case("many-strings", container, size);
}

/*
 * Two members that name the same image range.  The second member holds no
 * image of its own: it names the image of the first, so the container asks
 * for the hashing work of one image twice.  The digest is the value of the
 * third key of each member: no digest at all, a digest that is one byte too
 * long, or 64 hexadecimal digits.  One builder, so the three cases cannot
 * lay the container out differently.
 */
static void
build_overlap_case(const char *name, const uint8_t *digest,
    size_t digest_size)
{
	struct raw_member members[2];
	uint8_t *container;
	size_t size = 0;
	size_t i;

	for (i = 0; i < 2; i++) {
		plain_member(&members[i]);
		members[i].image = big_image;
		members[i].image_size = sizeof(big_image);
		if (digest != NULL) {
			members[i].string_count = 3;
			members[i].strings[2].key = CNFATBIN_KEY_SHA256;
			members[i].strings[2].value = digest;
			members[i].strings[2].value_size = digest_size;
		}
	}
	members[1].image_size = 0;
	container = build_raw(members, 2, &size);
	if (container != NULL) {
		uint64_t first_image =
		    get_le64(container + CNFATBIN_HEADER_SIZE + 24);

		put_le64(container + CNFATBIN_HEADER_SIZE + CNFATBIN_ENTRY_SIZE +
		    24, first_image);
		put_le64(container + CNFATBIN_HEADER_SIZE + CNFATBIN_ENTRY_SIZE +
		    32, sizeof(big_image));
	}
	add_case(name, container, size);
}

/*
 * A record whose key is one the reader does not know, and whose value is
 * outside the container.  The value of a key we do not know is ignored, so
 * the container opens.
 */
static void
build_unknown_key_case(void)
{
	struct raw_member member;
	uint8_t *container;
	size_t size = 0;
	long record;

	plain_member(&member);
	member.string_count = 3;
	member.strings[2].key = "some.unknown.key";
	member.strings[2].value = unknown_long;
	member.strings[2].value_size = sizeof(unknown_long);
	container = build_raw(&member, 1, &size);
	if (container != NULL) {
		/* The value of the key we do not know points outside the
		 * container. */
		record = find_string_record(container, size, "xxxx");
		if (record >= 0) {
			put_le64(container + record + 8, (uint64_t)size + 16);
			put_le64(container + record + 16, 1);
		}
	}
	add_case("unknown-key-out-of-range", container, size);
}

/*
 * A known value that points outside the container.  The key is a key we
 * know, so its value is looked at, and a value that is not there is
 * refused.
 */
static void
build_value_out_of_range_case(void)
{
	struct raw_member member;
	uint8_t *container;
	size_t size = 0;
	long record;

	plain_member(&member);
	container = build_raw(&member, 1, &size);
	if (container != NULL) {
		record = find_string_record(container, size, "sm_120");
		if (record >= 0) {
			put_le64(container + record + 8, (uint64_t)size + 16);
			put_le64(container + record + 16, 1);
		}
	}
	add_case("value-out-of-range", container, size);
}

/*
 * A known value whose terminator is not there: the byte after the value is
 * not a NUL, so the value is not the string it claims to be.
 */
static void
build_unterminated_value_case(void)
{
	struct raw_member member;
	uint8_t *container;
	size_t size = 0;
	long record;

	plain_member(&member);
	container = build_raw(&member, 1, &size);
	if (container != NULL) {
		record = find_string_record(container, size, "sm_120");
		if (record >= 0)
			container[value_offset_of(container, record) + 6] = 'X';
	}
	add_case("value-not-terminated", container, size);
}

/*
 * A container whose members all name the same long value: 262144 string
 * records name one value of 4 MiB.  A reader that checks the value once
 * for every record scans a terabyte on a container of ten megabytes; a
 * reader that checks it once does the work of reading the container.  The
 * case is written to a file and the shell test opens it under a timeout.
 */
#define SHARED_ENTRIES 16
#define SHARED_RECORDS CNFATBIN_MAX_STRINGS_PER_ENTRY
#define SHARED_VALUE_SIZE (4u * 1024u * 1024u)

static uint8_t *
build_shared_value_case(size_t *size)
{
	uint64_t table_size =
	    (uint64_t)SHARED_RECORDS * CNFATBIN_STRING_ENTRY_SIZE;
	uint64_t cursor = CNFATBIN_HEADER_SIZE +
	    (uint64_t)SHARED_ENTRIES * CNFATBIN_ENTRY_SIZE;
	uint64_t key_offset = cursor + (uint64_t)SHARED_ENTRIES * table_size;
	uint64_t value_offset = key_offset + 12;
	uint64_t total;
	uint8_t *out;
	size_t i, j;

	total = align_size(value_offset + SHARED_VALUE_SIZE + 1);
	out = alloc_container(total, SHARED_ENTRIES, size);
	if (out == NULL)
		return NULL;
	/* Time: O(records in the container).  Space: O(container). */
	for (i = 0; i < SHARED_ENTRIES; i++) {
		uint64_t table = cursor + (uint64_t)i * table_size;
		uint8_t *entry = out + CNFATBIN_HEADER_SIZE +
		    i * CNFATBIN_ENTRY_SIZE;

		put_le16(entry, CNFATBIN_IMG_PTX);
		put_le16(entry + 2, CNFATBIN_OFK_CUDA);
		put_le32(entry + 4, 0);
		put_le64(entry + 8, table);
		put_le64(entry + 16, SHARED_RECORDS);
		put_le64(entry + 24, total);
		put_le64(entry + 32, 0);
		for (j = 0; j < SHARED_RECORDS; j++) {
			uint8_t *record = out + table +
			    j * CNFATBIN_STRING_ENTRY_SIZE;

			put_le64(record, key_offset);
			put_le64(record + 8, value_offset);
			put_le64(record + 16, SHARED_VALUE_SIZE);
		}
	}
	/* The key every record names, and the value they all share. */
	memcpy(out + key_offset, "unknown.key", 12);
	memset(out + value_offset, 'x', SHARED_VALUE_SIZE);
	out[value_offset + SHARED_VALUE_SIZE] = '\0';
	return out;
}

/*
 * Build the containers the cases need: the values that do not fit, the key
 * we do not know, the digest that is not a digest and the two members that
 * name the same image.
 */
static void
build_cases(void)
{
	uint8_t *shared = NULL;
	size_t shared_size = 0;
	size_t i;

	memset(arch_long, 'a', sizeof(arch_long));
	memset(unknown_long, 'x', sizeof(unknown_long));
	for (i = 0; i < sizeof(digest_long); i++)
		digest_long[i] = (uint8_t)('0' + (i % 10));
	for (i = 0; i < sizeof(zero_digest); i++)
		zero_digest[i] = '0';
	memset(big_image, 'y', sizeof(big_image));
	build_arch_cases();
	build_key_cases();
	build_many_strings_case();
	/* The three cases that share one image: no digest, a digest, and a
	 * digest that is not a digest. */
	build_overlap_case("overlapping-images", NULL, 0);
	build_overlap_case("overlapping-images-digested", zero_digest,
	    sizeof(zero_digest));
	build_overlap_case("overlapping-images-bad-digest", digest_long,
	    sizeof(digest_long));
	build_unknown_key_case();
	build_value_out_of_range_case();
	build_unterminated_value_case();
	/* The case whose work the shell test measures: it is written to a
	 * file and opened there under a timeout, because opening it here
	 * would take the work the case is about. */
	shared = build_shared_value_case(&shared_size);
	add_case("shared-long-value", shared, shared_size);
}

/*
 * The value rules: a value that does not fit the field it belongs to, a
 * digest that is not a digest, a key we do not know and two members that
 * name the same image.
 */
static void
check_value_rules(void)
{
	const struct test_case *c;

	c = find_case("value-too-long");
	if (c == NULL) {
		bad("a value longer than the field it belongs to is refused");
	} else
		expect_error("a value longer than the field it belongs to is refused",
		    c->data, c->size,
		    "a member value is longer than the field it belongs to");
	c = find_case("digest-too-long");
	if (c == NULL) {
		bad("a digest that is not 64 hexadecimal digits is refused");
	} else
		expect_error("a digest that is not 64 hexadecimal digits is refused",
		    c->data, c->size,
		    "a member sha256 is not 64 hexadecimal digits");
	c = find_case("unknown-long-key");
	if (c == NULL) {
		bad("a key we do not know with a long value is ignored");
	} else
		expect_ok("a key we do not know with a long value is ignored",
		    c->data, c->size);
	c = find_case("many-strings");
	if (c == NULL) {
		bad("an entry with more strings than we know still opens");
	} else
		expect_ok("an entry with more strings than we know still opens",
		    c->data, c->size);
	/* Only the images that carry a digest are hashed, so two members
	 * that share one image and carry no digest ask for no hashing at
	 * all and the container opens. */
	c = find_case("overlapping-images");
	if (c == NULL) {
		bad("two members that share an image and carry no digest open");
	} else
		expect_ok("two members that share an image and carry no digest open",
		    c->data, c->size);
	c = find_case("overlapping-images-digested");
	if (c == NULL) {
		bad("a container that asks for more hashing than its size allows "
		    "is refused");
	} else
		expect_error("a container that asks for more hashing than its size "
		    "allows is refused", c->data, c->size,
		    "the container asks for more hashing than its size allows");
}

/*
 * The registry of the mappings a program tells the reader about grows: a
 * program that registers many mappings is not refused for want of space.
 */
static void
check_mapping_registry(void)
{
	static char areas[64][128];
	int i;
	int good = 1;

	for (i = 0; i < 64; i++) {
		if (cnfatbin_register_mapping(areas[i], sizeof(areas[i])) != 0)
			good = 0;
	}
	if (good)
		ok("the registry of mappings takes more than sixteen mappings");
	else
		bad("the registry of mappings takes more than sixteen mappings");
}

/*
 * The registry of the mappings a program tells the reader about has a
 * bound: it takes every mapping up to the bound, and the mapping past the
 * bound is refused with the bound named.  A refused registration leaves
 * the registry as it was.
 */
static void
check_registry_bound(void)
{
	static char areas[CNFATBIN_MAX_MAPPINGS][CNFATBIN_MAPPING_SIZE];
	size_t before = cnfatbin_registered_mappings();
	size_t i;
	int good = 1;

	for (i = before; i < CNFATBIN_MAX_MAPPINGS; i++) {
		if (cnfatbin_register_mapping(areas[i], sizeof(areas[i])) !=
		    CNFATBIN_REGISTER_OK)
			good = 0;
	}
	if (cnfatbin_registered_mappings() != CNFATBIN_MAX_MAPPINGS)
		good = 0;
	if (good)
		ok("the registry of mappings takes every mapping up to its bound");
	else
		bad("the registry of mappings takes every mapping up to its bound");
	/* One mapping past the bound is refused, and the registry does not
	 * grow. */
	if (cnfatbin_register_mapping(areas[0], sizeof(areas[0])) ==
	    CNFATBIN_REGISTER_TOO_MANY &&
	    cnfatbin_registered_mappings() == CNFATBIN_MAX_MAPPINGS)
		ok("the registry of mappings refuses one mapping past its bound");
	else
		bad("the registry of mappings refuses one mapping past its bound");
	/* The reason names the bound. */
	if (strstr(cnfatbin_register_reason(CNFATBIN_REGISTER_TOO_MANY),
	    "4096") != NULL)
		ok("the reason for a full registry names the bound");
	else
		bad("the reason for a full registry names the bound");
}

/*
 * The arithmetic that grows the registry is checked before it is
 * multiplied: a capacity that cannot be doubled, and a size that cannot be
 * multiplied, are refused, and the registry is not touched.
 */
static void
check_registry_overflow(void)
{
	size_t grown = 0;
	size_t bytes = 0;
	size_t count = cnfatbin_registered_mappings();

	grown = 0;
	bytes = 0;
	if (cnfatbin_registry_growth(SIZE_MAX / 2 + 1, &grown, &bytes) ==
	    CNFATBIN_REGISTER_OVERFLOW && grown == 0 && bytes == 0)
		ok("a capacity that cannot be doubled is refused");
	else
		bad("a capacity that cannot be doubled is refused");
	grown = 0;
	bytes = 0;
	if (cnfatbin_registry_growth(SIZE_MAX / CNFATBIN_MAPPING_SIZE + 1,
	    &grown, &bytes) == CNFATBIN_REGISTER_OVERFLOW && grown == 0 &&
	    bytes == 0)
		ok("a size that cannot be multiplied is refused");
	else
		bad("a size that cannot be multiplied is refused");
	if (cnfatbin_registered_mappings() == count)
		ok("a refused growth leaves the registry as it was");
	else
		bad("a refused growth leaves the registry as it was");
}

/*
 * A container with no members opens, and it has no member table: the count
 * is zero and the table is empty, even when the caller handed us a
 * container that had one.
 */
static void
check_empty_container(void)
{
	struct cnfatbin_container opened;
	uint8_t *container;
	size_t size = 0;
	int good;

	container = build_raw(NULL, 0, &size);
	if (container == NULL) {
		bad("a container with no members has no member table");
		return;
	}
	memset(&opened, 0xaa, sizeof(opened));
	good = cnfatbin_open(container, size, &opened) == CNFATBIN_OK;
	good = good && opened.entries_count == 0 && opened.members == NULL;
	good = good && opened.version == CNFATBIN_VERSION;
	good = good && opened.data == container && opened.size == size;
	cnfatbin_close(&opened);
	free(container);
	if (good)
		ok("a container with no members has no member table");
	else
		bad("a container with no members has no member table");
}

/*
 * The reader that cannot hold the members refuses the container, and the
 * container it leaves behind is empty.
 */
static void
check_out_of_memory(void)
{
	struct cnfatbin_container opened;
	uint8_t *container;
	size_t size = 0;
	size_t members = 0;
	size_t ptx_size = 0;
	int good;

	container = build_container(&size, &members, &ptx_size);
	if (container == NULL) {
		bad("a container that cannot be held is refused");
		return;
	}
	calloc_fails = 1;
	memset(&opened, 0xaa, sizeof(opened));
	good = cnfatbin_open(container, size, &opened) == CNFATBIN_E_NOMEM;
	good = good && opened.data == NULL && opened.size == 0 &&
	    opened.entries_count == 0 && opened.members == NULL;
	calloc_fails = 0;
	cnfatbin_buffer_free(container, size);
	if (good)
		ok("a container that cannot be held is refused and leaves an empty "
		    "container");
	else
		bad("a container that cannot be held is refused and leaves an empty "
		    "container");
}

/*
 * The cases that tell a value from a key: a key we do not know with a
 * value that is not there is ignored, a known value that is not there is
 * refused, a known value whose terminator is not there is refused, and a
 * digest that is not a digest is refused before the hashing budget.
 */
static void
check_value_rules_2(void)
{
	const struct test_case *c;

	c = find_case("unknown-key-out-of-range");
	if (c == NULL)
		bad("a key we do not know with a value that is not there is ignored");
	else
		expect_ok("a key we do not know with a value that is not there is "
		    "ignored", c->data, c->size);
	c = find_case("value-out-of-range");
	if (c == NULL)
		bad("a known value that is not there is refused");
	else
		expect_error("a known value that is not there is refused",
		    c->data, c->size, "a member string is out of range");
	c = find_case("value-not-terminated");
	if (c == NULL)
		bad("a known value whose terminator is not there is refused");
	else
		expect_error("a known value whose terminator is not there is refused",
		    c->data, c->size, "a member string value is not NUL terminated");
	c = find_case("overlapping-images-bad-digest");
	if (c == NULL)
		bad("a digest that is not a digest is refused before the hashing "
		    "budget");
	else
		expect_error("a digest that is not a digest is refused before the "
		    "hashing budget", c->data, c->size,
		    "a member sha256 is not 64 hexadecimal digits");
}

/*
 * The writer refuses to write a container the reader or the runtime would
 * refuse.
 */
static void
check_writer_limits(void)
{
	struct cnfatbin_input input;
	uint8_t *buffer = NULL;
	size_t size = 0;
	uint8_t *big = NULL;

	memset(&input, 0, sizeof(input));
	input.kind = CNFATBIN_KIND_PTX;
	input.sm = 120;
	input.data = (const uint8_t *)"payload";
	input.size = 7;
	if (cnfatbin_write(&input, 0, &buffer, &size) ==
	    CNFATBIN_E_NO_MEMBERS)
		ok("the writer refuses a container with no members");
	else
		bad("the writer refuses a container with no members");
	if (cnfatbin_write(&input, CNFATBIN_MAX_ENTRIES + 1, &buffer, &size) ==
	    CNFATBIN_E_TOO_MANY_ENTRIES)
		ok("the writer refuses a container with too many members");
	else
		bad("the writer refuses a container with too many members");
	big = malloc(CNFATBIN_MAX_SIZE + 1);
	if (big == NULL) {
		bad("the writer refuses a container larger than the limit");
		return;
	}
	memset(big, 'z', CNFATBIN_MAX_SIZE + 1);
	input.data = big;
	input.size = CNFATBIN_MAX_SIZE + 1;
	if (cnfatbin_write(&input, 1, &buffer, &size) ==
	    CNFATBIN_E_OUTPUT_TOO_LARGE)
		ok("the writer refuses a container larger than the limit");
	else
		bad("the writer refuses a container larger than the limit");
	free(big);
}

/*
 * Every error code has a short name and a message of its own.
 */
static void
check_error_table(void)
{
	int code;
	int good = 1;

	for (code = 0; code < CNFATBIN_ERROR_COUNT; code++) {
		if (strcmp(cnfatbin_error_name(code), "unknown") == 0 ||
		    strcmp(cnfatbin_strerror(code), "unknown error") == 0)
			good = 0;
	}
	if (good)
		ok("every error code has a short name and a message");
	else
		bad("every error code has a short name and a message");
}

/*
 * Write the crafted containers into a directory, so that a shell test can
 * drive the tools over them.
 */
static int
write_cases(const char *directory)
{
	size_t i;

	for (i = 0; i < case_count; i++) {
		char path[1024];
		FILE *stream;

		snprintf(path, sizeof(path), "%s/%s.bin", directory,
		    cases[i].name);
		stream = fopen(path, "wb");
		if (stream == NULL) {
			fprintf(stderr, "cannot write %s\n", path);
			return 1;
		}
		if (fwrite(cases[i].data, 1, cases[i].size, stream) !=
		    cases[i].size) {
			fclose(stream);
			fprintf(stderr, "cannot write %s\n", path);
			return 1;
		}
		fclose(stream);
	}
	return 0;
}

/*
 * Open the file the caller named and say what the reader makes of it.
 */
static int
open_file(const char *path)
{
	struct cnfatbin_container opened;
	enum cnfatbin_error err;
	FILE *stream;
	uint8_t *data;
	long length;

	stream = fopen(path, "rb");
	if (stream == NULL) {
		fprintf(stderr, "cannot read %s\n", path);
		return 1;
	}
	if (fseek(stream, 0, SEEK_END) != 0) {
		fclose(stream);
		return 1;
	}
	length = ftell(stream);
	if (length < 0) {
		fclose(stream);
		return 1;
	}
	rewind(stream);
	data = malloc((size_t)length + 1);
	if (data == NULL) {
		fclose(stream);
		return 1;
	}
	/* Time: O(file size).  Space: O(file size). */
	if (length > 0 && fread(data, 1, (size_t)length, stream) !=
	    (size_t)length) {
		free(data);
		fclose(stream);
		return 1;
	}
	fclose(stream);
	err = cnfatbin_open(data, (size_t)length, &opened);
	if (err != CNFATBIN_OK) {
		printf("error=%s message=%s\n", cnfatbin_error_name(err),
		    cnfatbin_strerror(err));
		free(data);
		return 1;
	}
	printf("ok members=%llu version=%u\n",
	    (unsigned long long)opened.entries_count, opened.version);
	/* Time: O(members).  Space: O(1). */
	{
		size_t i;

		for (i = 0; i < (size_t)opened.entries_count; i++)
			printf("member %zu kind=%s arch=%s size=%llu\n", i,
			    cnfatbin_image_kind_name(opened.members[i].image_kind),
			    opened.members[i].arch,
			    (unsigned long long)opened.members[i].image_size);
	}
	cnfatbin_close(&opened);
	free(data);
	return 0;
}

int
main(int argc, char **argv)
{
	uint8_t *container;
	size_t size = 0;
	size_t members = 0;
	size_t ptx_size = 0;
	int rc;

	if (argc > 2 && strcmp(argv[1], "--write-cases") == 0) {
		container = build_container(&size, &members, &ptx_size);
		if (container == NULL) {
			fprintf(stderr, "cannot build a container\n");
			return 1;
		}
		/* Every container the shell test drives the tools over is
		 * built here: one place knows how to break one. */
		check_short_input(container);
		check_header_errors(container, size);
		check_image_errors(container, size);
		check_string_errors(container, size);
		check_kind_errors(container, size);
		check_sha256_errors(container, size);
		build_cases();
		rc = write_cases(argv[2]);
		cnfatbin_buffer_free(container, size);
		return rc;
	}
	if (argc > 1)
		return open_file(argv[1]);

	container = build_container(&size, &members, &ptx_size);
	if (container == NULL) {
		printf("FAIL cannot build a container\n");
		return 1;
	}

	check_round_trip(container, size, members, ptx_size);
	check_short_input(container);
	check_header_errors(container, size);
	check_image_errors(container, size);
	check_string_errors(container, size);
	check_kind_errors(container, size);
	check_sha256_errors(container, size);
	check_kind_none(container, size);
	check_without_our_keys(container, size);

	build_cases();
	check_value_rules();
	check_value_rules_2();
	check_writer_limits();
	check_mapping_registry();
	check_registry_bound();
	check_registry_overflow();
	check_empty_container();
	check_out_of_memory();
	check_error_table();

	cnfatbin_buffer_free(container, size);
	printf("%d passed, %d failed\n", passed, failures);
	return failures;
}

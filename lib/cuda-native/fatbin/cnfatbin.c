/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * cnfatbin.c - the cuda-native fatbin container: one reader and one writer
 * for LLVM's OffloadBinary format, version 2.
 *
 * The reader validates the whole container before any of it is used and
 * refuses every malformed input with a named error.  The writer lays the
 * container out the way LLVM's own writer does, so llvm-objdump --offloading
 * reads what we write.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <link.h>
#include <stdatomic.h>

#include <sha256.h>

#include "cnfatbin.h"

/* The number of strings every entry carries: triple, arch and our two. */
#define CNFATBIN_STRINGS_PER_ENTRY 4

static const char *const member_keys[CNFATBIN_STRINGS_PER_ENTRY] = {
	CNFATBIN_KEY_TRIPLE,
	CNFATBIN_KEY_ARCH,
	CNFATBIN_KEY_FORMAT,
	CNFATBIN_KEY_SHA256
};

static uint16_t
read_le16(const uint8_t *p)
{
	return (uint16_t)((uint16_t)p[0] | ((uint16_t)p[1] << 8));
}

static uint32_t
read_le32(const uint8_t *p)
{
	return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
	    ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static uint64_t
read_le64(const uint8_t *p)
{
	return (uint64_t)read_le32(p) | ((uint64_t)read_le32(p + 4) << 32);
}

static void
write_le16(uint8_t *p, uint16_t value)
{
	p[0] = (uint8_t)(value & 0xff);
	p[1] = (uint8_t)((value >> 8) & 0xff);
}

static void
write_le32(uint8_t *p, uint32_t value)
{
	p[0] = (uint8_t)(value & 0xff);
	p[1] = (uint8_t)((value >> 8) & 0xff);
	p[2] = (uint8_t)((value >> 16) & 0xff);
	p[3] = (uint8_t)((value >> 24) & 0xff);
}

static void
write_le64(uint8_t *p, uint64_t value)
{
	write_le32(p, (uint32_t)(value & 0xffffffffu));
	write_le32(p + 4, (uint32_t)((value >> 32) & 0xffffffffu));
}

/*
 * Is the half-open range [offset, offset + length) inside [0, total)?
 * The subtraction never overflows, so the answer is always correct.
 */
static int
in_range(uint64_t offset, uint64_t length, uint64_t total)
{
	if (offset > total)
		return 0;
	if (length > total - offset)
		return 0;
	return 1;
}

static uint64_t
align_up(uint64_t value, uint64_t alignment)
{
	uint64_t rest = value % alignment;

	if (rest == 0)
		return value;
	return value + (alignment - rest);
}

/*
 * The mappings a program has told us about.  A container a program built in
 * memory of its own is in no loaded object, so the bound on the reads the
 * reader makes there comes from here.
 *
 * The registry grows as it is used: a program that registers many mappings
 * is not refused for want of space.
 */
struct cnfatbin_mapping {
	const uint8_t *base;
	size_t length;
};

static struct cnfatbin_mapping *cnfatbin_mappings;
static size_t cnfatbin_mapping_count;
static size_t cnfatbin_mapping_capacity;
static atomic_flag cnfatbin_mapping_lock = ATOMIC_FLAG_INIT;

/* Time: O(1).  Space: O(1). */
static void
mapping_lock(void)
{
	while (atomic_flag_test_and_set_explicit(&cnfatbin_mapping_lock,
	    memory_order_acquire))
		;
}

/* Time: O(1).  Space: O(1). */
static void
mapping_unlock(void)
{
	atomic_flag_clear_explicit(&cnfatbin_mapping_lock, memory_order_release);
}

/*
 * The bytes at the pointer that a registered mapping allows us to read, or
 * zero when the pointer is in no registered mapping.
 */
static size_t
registered_bound(const uint8_t *data)
{
	uintptr_t target = (uintptr_t)data;
	size_t bound = 0;
	size_t i;

	mapping_lock();
	/* Time: O(registered mappings).  Space: O(1). */
	for (i = 0; i < cnfatbin_mapping_count; i++) {
		uintptr_t base = (uintptr_t)cnfatbin_mappings[i].base;
		size_t length = cnfatbin_mappings[i].length;

		if (target < base || target - base >= length)
			continue;
		bound = length - (size_t)(target - base);
		break;
	}
	mapping_unlock();
	return bound;
}

/* What the search of the loaded objects looks for. */
struct bound_search {
	uintptr_t target;
	size_t bound;
};

/*
 * The PT_LOAD segment of one loaded object that holds the pointer ends
 * where the readable bytes of that object end.
 */
static int
bound_in_object(struct dl_phdr_info *info, size_t size, void *argument)
{
	struct bound_search *search = argument;
	size_t i;

	(void)size;
	/* Time: O(segments in the object).  Space: O(1). */
	for (i = 0; i < info->dlpi_phnum; i++) {
		const ElfW(Phdr) *header = &info->dlpi_phdr[i];
		uintptr_t low, high;

		if (header->p_type != PT_LOAD || header->p_memsz == 0)
			continue;
		low = (uintptr_t)info->dlpi_addr + (uintptr_t)header->p_vaddr;
		high = low + (uintptr_t)header->p_memsz;
		if (search->target < low || search->target >= high)
			continue;
		search->bound = (size_t)(high - search->target);
		return 1;
	}
	return 0;
}

/*
 * The bytes at the pointer that the object which holds it allows us to
 * read, or zero when the pointer is in no loaded object.
 */
static size_t
object_bound(const uint8_t *data)
{
	struct bound_search search;

	search.target = (uintptr_t)data;
	search.bound = 0;
	dl_iterate_phdr(bound_in_object, &search);
	return search.bound;
}

size_t
cnfatbin_bound(const void *data)
{
	size_t bound;

	if (data == NULL)
		return 0;
	/* The object that holds the pointer is the authority: its PT_LOAD
	 * segment says how far the readable bytes go.  A registered mapping
	 * is only the way out for a pointer that is in no loaded object at
	 * all, so a registration can never widen the bound of a pointer that
	 * a loaded object already bounds. */
	bound = object_bound(data);
	if (bound == 0)
		bound = registered_bound(data);
	if (bound > CNFATBIN_MAX_SIZE)
		bound = CNFATBIN_MAX_SIZE;
	return bound;
}

int
cnfatbin_register_mapping(const void *base, size_t length)
{
	int recorded = -1;

	if (base == NULL || length == 0)
		return -1;
	mapping_lock();
	/* The registry grows as it is used: there is no limit on the number
	 * of mappings a program may tell the reader about. */
	if (cnfatbin_mapping_count == cnfatbin_mapping_capacity) {
		size_t grown = cnfatbin_mapping_capacity == 0 ? 8 :
		    cnfatbin_mapping_capacity * 2;
		struct cnfatbin_mapping *bigger =
		    realloc(cnfatbin_mappings, grown * sizeof(*bigger));

		if (bigger == NULL) {
			mapping_unlock();
			return -1;
		}
		cnfatbin_mappings = bigger;
		cnfatbin_mapping_capacity = grown;
	}
	cnfatbin_mappings[cnfatbin_mapping_count].base = base;
	cnfatbin_mappings[cnfatbin_mapping_count].length = length;
	cnfatbin_mapping_count++;
	recorded = 0;
	mapping_unlock();
	return recorded;
}

/*
 * Every way a container can be refused: the short name the tools print and
 * the message they print with it.  One table, so the two cannot disagree,
 * and one entry per code, so a code cannot lose its name or its message.
 */
struct cnfatbin_error_info {
	const char *name;
	const char *message;
};

static const struct cnfatbin_error_info error_table[] = {
	[CNFATBIN_OK] = { "ok", "no error" },
	[CNFATBIN_E_SHORT_INPUT] = {
		"short-input", "input is shorter than the container header" },
	[CNFATBIN_E_BAD_MAGIC] = { "bad-magic", "bad container magic" },
	[CNFATBIN_E_BAD_VERSION] = {
		"bad-version", "unknown container version" },
	[CNFATBIN_E_SIZE_TOO_LARGE] = {
		"size-too-large", "container size is larger than the input" },
	[CNFATBIN_E_TOO_MANY_ENTRIES] = {
		"too-many-entries", "too many entries in the container" },
	[CNFATBIN_E_ENTRIES_OUT_OF_RANGE] = {
		"entries-out-of-range", "the entries table is out of range" },
	[CNFATBIN_E_IMAGE_OUT_OF_RANGE] = {
		"image-out-of-range", "a member image is out of range" },
	[CNFATBIN_E_STRING_OUT_OF_RANGE] = {
		"string-out-of-range", "a member string is out of range" },
	[CNFATBIN_E_STRING_NOT_TERMINATED] = {
		"string-not-terminated",
		"a member string value is not NUL terminated" },
	[CNFATBIN_E_BAD_IMAGE_KIND] = {
		"bad-image-kind",
		"a member has an image kind other than PTX, cubin or none" },
	[CNFATBIN_E_BAD_OFFLOAD_KIND] = {
		"bad-offload-kind",
		"a member has an unsupported offload kind" },
	[CNFATBIN_E_SHA256_FORMAT] = {
		"sha256-format", "a member sha256 is not 64 hexadecimal digits" },
	[CNFATBIN_E_SHA256_MISMATCH] = {
		"sha256-mismatch", "a member sha256 does not match its image" },
	[CNFATBIN_E_VALUE_TOO_LONG] = {
		"value-too-long",
		"a member value is longer than the field it belongs to" },
	[CNFATBIN_E_HASH_BUDGET] = {
		"hash-budget",
		"the container asks for more hashing than its size allows" },
	[CNFATBIN_E_OUTPUT_TOO_LARGE] = {
		"output-too-large", "the container to write is larger than the limit" },
	[CNFATBIN_E_NO_MEMBERS] = {
		"no-members", "the container has no members" },
	[CNFATBIN_E_NOMEM] = { "nomem", "host memory exhausted" }
};

_Static_assert(sizeof(error_table) / sizeof(error_table[0]) == CNFATBIN_ERROR_COUNT,
    "the error table must have one entry for every error code");

const char *
cnfatbin_strerror(enum cnfatbin_error err)
{
	if ((int)err < 0 || (size_t)err >= CNFATBIN_ERROR_COUNT)
		return "unknown error";
	return error_table[err].message;
}

const char *
cnfatbin_error_name(enum cnfatbin_error err)
{
	if ((int)err < 0 || (size_t)err >= CNFATBIN_ERROR_COUNT)
		return "unknown";
	return error_table[err].name;
}

const char *
cnfatbin_image_kind_name(uint16_t image_kind)
{
	switch (image_kind) {
	case CNFATBIN_IMG_NONE:
		return "none";
	case CNFATBIN_IMG_PTX:
		return "ptx";
	case CNFATBIN_IMG_CUBIN:
		return "cubin";
	default:
		return "unknown";
	}
}

const char *
cnfatbin_offload_kind_name(uint16_t offload_kind)
{
	switch (offload_kind) {
	case CNFATBIN_OFK_NONE:
		return "none";
	case CNFATBIN_OFK_CUDA:
		return "cuda";
	default:
		return "unknown";
	}
}

int
cnfatbin_has_magic(const uint8_t *data, size_t size)
{
	if (data == NULL || size < 4)
		return 0;
	return data[0] == CNFATBIN_MAGIC_0 && data[1] == CNFATBIN_MAGIC_1 &&
	    data[2] == CNFATBIN_MAGIC_2 && data[3] == CNFATBIN_MAGIC_3;
}

int
cnfatbin_sha256_hex(const uint8_t *data, size_t size, char *out)
{
	static const char digits[] = "0123456789abcdef";
	unsigned char digest[SHA256_DIGEST_LENGTH];
	SHA256_CTX ctx;
	size_t i;

	SHA256_Init(&ctx);
	if (size > 0)
		SHA256_Update(&ctx, data, size);
	SHA256_Final(digest, &ctx);
	/* Time: O(digest length).  Space: O(1). */
	for (i = 0; i < SHA256_DIGEST_LENGTH; i++) {
		out[i * 2] = digits[(digest[i] >> 4) & 0x0f];
		out[i * 2 + 1] = digits[digest[i] & 0x0f];
	}
	out[SHA256_DIGEST_LENGTH * 2] = '\0';
	return 0;
}

static int
is_hex64(const char *s)
{
	size_t i;

	/* Time: O(64).  Space: O(1). */
	for (i = 0; i < CNFATBIN_SHA256_HEX_MAX; i++) {
		if ((s[i] < '0' || s[i] > '9') && (s[i] < 'a' || s[i] > 'f'))
			return 0;
	}
	return s[CNFATBIN_SHA256_HEX_MAX] == '\0';
}

/*
 * Is the value at [offset, offset + size) a NUL terminated string?  The
 * bytes of the value hold no NUL, and the byte after them is the NUL that
 * ends it.  Only the first `scan` bytes are looked at: a value that is
 * longer than the field it belongs to is refused by its length, so one
 * record cannot ask for the same long value to be scanned again and again.
 */
static int
value_is_terminated(const uint8_t *data, uint64_t total, uint64_t offset,
    uint64_t size, uint64_t scan)
{
	uint64_t i;

	if (scan > size)
		scan = size;
	/* Time: O(bytes looked at).  Space: O(1). */
	for (i = offset; i < offset + scan; i++) {
		if (data[i] == '\0')
			return 0;
	}
	if (offset + size >= total)
		return 0;
	return data[offset + size] == '\0';
}

/* The keys the reader knows, and the field each one belongs to. */
enum known_key {
	KEY_UNKNOWN,
	KEY_TRIPLE,
	KEY_ARCH,
	KEY_FORMAT,
	KEY_SHA256
};

/*
 * Which key a string record names.  The key must be a NUL terminated
 * string inside the container: a key that lies outside the container, or
 * one that is not terminated, is a malformed container and is refused.  The
 * key is compared where it lies: a key that is longer than the longest key
 * we know, or a key that differs from ours in one byte, is a key we do not
 * know, and a container is not refused for it.
 */
static enum cnfatbin_error
known_key(const uint8_t *data, uint64_t total, uint64_t key_offset,
    enum known_key *which)
{
	static const struct {
		const char *key;
		enum known_key which;
	} table[] = {
		{ CNFATBIN_KEY_TRIPLE, KEY_TRIPLE },
		{ CNFATBIN_KEY_ARCH, KEY_ARCH },
		{ CNFATBIN_KEY_FORMAT, KEY_FORMAT },
		{ CNFATBIN_KEY_SHA256, KEY_SHA256 }
	};
	uint64_t limit, i;
	size_t j;

	*which = KEY_UNKNOWN;
	if (key_offset >= total)
		return CNFATBIN_E_STRING_OUT_OF_RANGE;
	limit = key_offset + CNFATBIN_KEY_MAX + 1;
	if (limit > total)
		limit = total;
	/* Time: O(keys).  Space: O(1). */
	for (i = key_offset; i < limit; i++) {
		if (data[i] != '\0')
			continue;
		for (j = 0; j < sizeof(table) / sizeof(table[0]); j++) {
			size_t length = strlen(table[j].key);

			if (i - key_offset != length)
				continue;
			if (memcmp(data + key_offset, table[j].key, length) != 0)
				continue;
			*which = table[j].which;
			break;
		}
		return CNFATBIN_OK;
	}
	/* No NUL in the window: the key is longer than any key we know, or
	 * it is not terminated at all. */
	if (limit >= total)
		return CNFATBIN_E_STRING_OUT_OF_RANGE;
	return CNFATBIN_OK;
}

/*
 * Copy the value of a key we know into the field it belongs to.  The value
 * must fit the field and must be NUL terminated, and it is never
 * truncated.  Only the bytes that could fit the field are looked at, so
 * the work one record asks for does not grow with the size the value
 * claims.
 */
static enum cnfatbin_error
read_value(char *field, size_t field_size, const uint8_t *data,
    uint64_t total, uint64_t value_offset, uint64_t value_size)
{
	if (!value_is_terminated(data, total, value_offset, value_size,
	    field_size))
		return CNFATBIN_E_STRING_NOT_TERMINATED;
	if (value_size >= field_size)
		return CNFATBIN_E_VALUE_TOO_LONG;
	memcpy(field, data + value_offset, (size_t)value_size);
	field[value_size] = '\0';
	return CNFATBIN_OK;
}

/*
 * Read the strings of one entry.  The strings the reader knows go into the
 * member; a string whose key the reader does not know is ignored, and its
 * value may be as long as it likes.
 */
static enum cnfatbin_error
read_entry_strings(const uint8_t *data, uint64_t total, uint64_t string_offset,
    uint64_t num_strings, struct cnfatbin_member *member)
{
	uint64_t i;

	if (num_strings > (uint64_t)total / CNFATBIN_STRING_ENTRY_SIZE)
		return CNFATBIN_E_STRING_OUT_OF_RANGE;
	if (!in_range(string_offset, num_strings * CNFATBIN_STRING_ENTRY_SIZE,
	    total))
		return CNFATBIN_E_STRING_OUT_OF_RANGE;
	/* Time: O(strings in the entry).  Space: O(1). */
	for (i = 0; i < num_strings; i++) {
		const uint8_t *entry = data + string_offset +
		    i * CNFATBIN_STRING_ENTRY_SIZE;
		uint64_t key_offset = read_le64(entry);
		uint64_t value_offset = read_le64(entry + 8);
		uint64_t value_size = read_le64(entry + 16);
		enum known_key which;
		enum cnfatbin_error err;

		if (!in_range(value_offset, value_size, total))
			return CNFATBIN_E_STRING_OUT_OF_RANGE;
		/* The key is resolved before the value is looked at.  The
		 * value of a key we do not know is ignored, and a value
		 * that fits no field is refused by its length, so no
		 * record can ask for a long value to be scanned again
		 * and again. */
		err = known_key(data, total, key_offset, &which);
		if (err != CNFATBIN_OK)
			return err;
		switch (which) {
		case KEY_TRIPLE:
			err = read_value(member->triple, sizeof(member->triple),
			    data, total, value_offset, value_size);
			if (err != CNFATBIN_OK)
				return err;
			break;
		case KEY_ARCH:
			err = read_value(member->arch, sizeof(member->arch),
			    data, total, value_offset, value_size);
			if (err != CNFATBIN_OK)
				return err;
			break;
		case KEY_FORMAT:
			err = read_value(member->format,
			    sizeof(member->format), data, total, value_offset,
			    value_size);
			if (err != CNFATBIN_OK)
				return err;
			member->has_format = 1;
			break;
		case KEY_SHA256:
			/* The digest is exactly 64 hexadecimal digits, and
			 * it is measured before it is copied. */
			if (!value_is_terminated(data, total, value_offset,
			    value_size, CNFATBIN_SHA256_HEX_MAX))
				return CNFATBIN_E_STRING_NOT_TERMINATED;
			if (value_size != CNFATBIN_SHA256_HEX_MAX)
				return CNFATBIN_E_SHA256_FORMAT;
			memcpy(member->sha256, data + value_offset,
			    CNFATBIN_SHA256_HEX_MAX);
			member->sha256[CNFATBIN_SHA256_HEX_MAX] = '\0';
			if (!is_hex64(member->sha256))
				return CNFATBIN_E_SHA256_FORMAT;
			member->has_sha256 = 1;
			break;
		case KEY_UNKNOWN:
			/* A key we do not know: the value is ignored. */
			break;
		}
	}
	return CNFATBIN_OK;
}

static enum cnfatbin_error
read_member(const uint8_t *data, uint64_t total, uint64_t entry_offset,
    struct cnfatbin_member *member)
{
	const uint8_t *entry = data + entry_offset;
	uint64_t string_offset, num_strings, image_offset, image_size;
	enum cnfatbin_error err;

	member->image_kind = read_le16(entry);
	member->offload_kind = read_le16(entry + 2);
	member->flags = read_le32(entry + 4);
	string_offset = read_le64(entry + 8);
	num_strings = read_le64(entry + 16);
	image_offset = read_le64(entry + 24);
	image_size = read_le64(entry + 32);
	member->image_offset = image_offset;
	member->image_size = image_size;
	member->has_format = 0;
	member->has_sha256 = 0;
	member->triple[0] = '\0';
	member->arch[0] = '\0';
	member->format[0] = '\0';
	member->sha256[0] = '\0';

	/* An image kind of none means the writer did not name the kind of the
	 * image; LLVM's own packager writes that.  Every other kind is one we
	 * do not carry. */
	if (member->image_kind != CNFATBIN_IMG_NONE &&
	    member->image_kind != CNFATBIN_IMG_PTX &&
	    member->image_kind != CNFATBIN_IMG_CUBIN)
		return CNFATBIN_E_BAD_IMAGE_KIND;
	if (member->offload_kind != CNFATBIN_OFK_NONE &&
	    member->offload_kind != CNFATBIN_OFK_CUDA)
		return CNFATBIN_E_BAD_OFFLOAD_KIND;
	if (!in_range(image_offset, image_size, total))
		return CNFATBIN_E_IMAGE_OUT_OF_RANGE;
	if (num_strings > CNFATBIN_MAX_STRINGS_PER_ENTRY)
		return CNFATBIN_E_STRING_OUT_OF_RANGE;
	err = read_entry_strings(data, total, string_offset, num_strings,
	    member);
	if (err != CNFATBIN_OK)
		return err;

	if (member->has_sha256) {
		char computed[CNFATBIN_SHA256_HEX_MAX + 1];

		cnfatbin_sha256_hex(data + image_offset, (size_t)image_size,
		    computed);
		if (strcmp(computed, member->sha256) != 0)
			return CNFATBIN_E_SHA256_MISMATCH;
	}
	return CNFATBIN_OK;
}

enum cnfatbin_error
cnfatbin_peek_size(const uint8_t *data, size_t available, uint64_t *size)
{
	if (data == NULL || size == NULL)
		return CNFATBIN_E_SHORT_INPUT;
	if (available < CNFATBIN_HEADER_SIZE)
		return CNFATBIN_E_SHORT_INPUT;
	if (!cnfatbin_has_magic(data, available))
		return CNFATBIN_E_BAD_MAGIC;
	*size = read_le64(data + 8);
	return CNFATBIN_OK;
}

/*
 * Does the entry carry a digest?  The key of the string record is read
 * where it lies, so the answer needs no copy.  An entry whose string table
 * is out of range carries nothing we know: the reader that reads the entry
 * says so.
 */
static int
entry_has_sha256(const uint8_t *data, uint64_t total, uint64_t string_offset,
    uint64_t num_strings)
{
	uint64_t i;

	if (num_strings > CNFATBIN_MAX_STRINGS_PER_ENTRY)
		return 0;
	if (num_strings > (uint64_t)total / CNFATBIN_STRING_ENTRY_SIZE)
		return 0;
	if (!in_range(string_offset, num_strings * CNFATBIN_STRING_ENTRY_SIZE,
	    total))
		return 0;
	/* Time: O(strings in the entry).  Space: O(1). */
	for (i = 0; i < num_strings; i++) {
		const uint8_t *record = data + string_offset +
		    i * CNFATBIN_STRING_ENTRY_SIZE;
		uint64_t key_offset = read_le64(record);
		size_t length = sizeof(CNFATBIN_KEY_SHA256);

		if (key_offset >= total || length > total - key_offset)
			continue;
		if (memcmp(data + key_offset, CNFATBIN_KEY_SHA256, length) == 0)
			return 1;
	}
	return 0;
}

/*
 * The hashing work a container may ask for: the sum of the sizes of the
 * images whose members carry a digest may not be larger than the container
 * itself.  Only the images that are hashed are counted: a member without a
 * digest is not hashed and asks for no work.  Two members that name the
 * same image range and both carry a digest ask for twice the work of one,
 * and a container that asks for more is refused before any digest is
 * computed.
 */
static enum cnfatbin_error
check_hash_budget(const uint8_t *data, uint64_t total, uint64_t entries_offset,
    uint64_t entries_count)
{
	uint64_t sum = 0;
	uint64_t i;

	/* Time: O(entries in the container).  Space: O(1). */
	for (i = 0; i < entries_count; i++) {
		const uint8_t *entry = data + entries_offset +
		    i * CNFATBIN_ENTRY_SIZE;
		uint64_t string_offset = read_le64(entry + 8);
		uint64_t num_strings = read_le64(entry + 16);
		uint64_t image_start = read_le64(entry + 24);
		uint64_t image_length = read_le64(entry + 32);

		/* Only the images that are hashed are counted. */
		if (!entry_has_sha256(data, total, string_offset, num_strings))
			continue;
		/* An image that leaves the container is reported by the
		 * reader that reads the member; it is not this check. */
		if (!in_range(image_start, image_length, total))
			continue;
		if (image_length > total - sum)
			return CNFATBIN_E_HASH_BUDGET;
		sum += image_length;
	}
	return CNFATBIN_OK;
}

enum cnfatbin_error
cnfatbin_open(const uint8_t *data, size_t size,
    struct cnfatbin_container *container)
{
	uint64_t total, entries_offset, entries_count;
	struct cnfatbin_member *members = NULL;
	uint32_t version;
	size_t i;
	enum cnfatbin_error err;

	memset(container, 0, sizeof(*container));
	if (size < CNFATBIN_HEADER_SIZE)
		return CNFATBIN_E_SHORT_INPUT;
	if (!cnfatbin_has_magic(data, size))
		return CNFATBIN_E_BAD_MAGIC;
	version = read_le32(data + 4);
	if (version != CNFATBIN_VERSION)
		return CNFATBIN_E_BAD_VERSION;
	total = read_le64(data + 8);
	if (total > (uint64_t)size)
		return CNFATBIN_E_SIZE_TOO_LARGE;
	entries_offset = read_le64(data + 16);
	entries_count = read_le64(data + 24);
	if (entries_count > CNFATBIN_MAX_ENTRIES)
		return CNFATBIN_E_TOO_MANY_ENTRIES;
	if (entries_offset < CNFATBIN_HEADER_SIZE)
		return CNFATBIN_E_ENTRIES_OUT_OF_RANGE;
	if (entries_count > (uint64_t)size / CNFATBIN_ENTRY_SIZE)
		return CNFATBIN_E_ENTRIES_OUT_OF_RANGE;
	if (!in_range(entries_offset, entries_count * CNFATBIN_ENTRY_SIZE,
	    total))
		return CNFATBIN_E_ENTRIES_OUT_OF_RANGE;

	if (entries_count == 0) {
		container->version = version;
		container->data = data;
		container->size = size;
		return CNFATBIN_OK;
	}
	/* The hashing work is checked before any member is read, so that a
	 * container that asks for more work than its size allows never has
	 * a digest computed. */
	err = check_hash_budget(data, total, entries_offset, entries_count);
	if (err != CNFATBIN_OK)
		return err;
	members = calloc((size_t)entries_count, sizeof(*members));
	if (members == NULL)
		return CNFATBIN_E_NOMEM;
	/* Time: O(entries in the container).  Space: O(entries). */
	for (i = 0; i < (size_t)entries_count; i++) {
		err = read_member(data, total,
		    entries_offset + (uint64_t)i * CNFATBIN_ENTRY_SIZE,
		    &members[i]);
		if (err != CNFATBIN_OK) {
			free(members);
			return err;
		}
	}
	/* Nothing is published before every check has passed: a container
	 * that is refused leaves an empty container behind. */
	container->version = version;
	container->data = data;
	container->size = size;
	container->entries_count = entries_count;
	container->members = members;
	return CNFATBIN_OK;
}

void
cnfatbin_close(struct cnfatbin_container *container)
{
	free(container->members);
	container->members = NULL;
	container->entries_count = 0;
	container->data = NULL;
	container->size = 0;
}

/* What the writer needs to know about one member. */
struct write_member {
	uint16_t image_kind;
	uint64_t string_table_offset;
	uint64_t key_offset[CNFATBIN_STRINGS_PER_ENTRY];
	uint64_t value_offset[CNFATBIN_STRINGS_PER_ENTRY];
	uint64_t value_size[CNFATBIN_STRINGS_PER_ENTRY];
	uint64_t image_offset;
	char arch[CNFATBIN_ARCH_MAX];
	char format[CNFATBIN_FORMAT_MAX];
	char sha256[CNFATBIN_SHA256_HEX_MAX + 1];
};

/*
 * The four values of one member, in the order of the string table.
 */
static void
member_values(const struct write_member *member,
    const char *values[CNFATBIN_STRINGS_PER_ENTRY])
{
	values[0] = CNFATBIN_TRIPLE;
	values[1] = member->arch;
	values[2] = member->format;
	values[3] = member->sha256;
}

/*
 * Fill in the member table: the image kind, the arch, the format and the
 * SHA-256 of the image.
 */
static enum cnfatbin_error
prepare_members(const struct cnfatbin_input *inputs, size_t count,
    struct write_member *members)
{
	size_t i;

	/* Time: O(members).  Space: O(members). */
	for (i = 0; i < count; i++) {
		struct write_member *member = &members[i];

		switch (inputs[i].kind) {
		case CNFATBIN_KIND_PTX:
			member->image_kind = CNFATBIN_IMG_PTX;
			snprintf(member->format, sizeof(member->format), "%s",
			    CNFATBIN_FORMAT_PTX);
			break;
		case CNFATBIN_KIND_CUBIN:
			member->image_kind = CNFATBIN_IMG_CUBIN;
			snprintf(member->format, sizeof(member->format), "%s",
			    CNFATBIN_FORMAT_CUBIN);
			break;
		default:
			return CNFATBIN_E_BAD_IMAGE_KIND;
		}
		if (inputs[i].suffix == 'a' || inputs[i].suffix == 'f')
			snprintf(member->arch, sizeof(member->arch), "sm_%u%c",
			    inputs[i].sm, inputs[i].suffix);
		else
			snprintf(member->arch, sizeof(member->arch), "sm_%u",
			    inputs[i].sm);
		cnfatbin_sha256_hex(inputs[i].data, inputs[i].size,
		    member->sha256);
	}
	return CNFATBIN_OK;
}

/*
 * The sizing pass: lay the container out and remember where every part
 * of it goes.  Nothing is written yet.
 */
static void
size_container(const struct cnfatbin_input *inputs, size_t count,
    struct write_member *members, uint64_t *total)
{
	const char *values[CNFATBIN_STRINGS_PER_ENTRY];
	uint64_t cursor = CNFATBIN_HEADER_SIZE;
	size_t i, j;

	cursor += (uint64_t)count * CNFATBIN_ENTRY_SIZE;
	/* The string tables of every entry, one after the other. */
	/* Time: O(members).  Space: O(1). */
	for (i = 0; i < count; i++) {
		members[i].string_table_offset = cursor;
		cursor += (uint64_t)CNFATBIN_STRINGS_PER_ENTRY *
		    CNFATBIN_STRING_ENTRY_SIZE;
	}
	/* The strings themselves: every key and value, NUL terminated. */
	/* Time: O(members).  Space: O(1). */
	for (i = 0; i < count; i++) {
		member_values(&members[i], values);
		for (j = 0; j < CNFATBIN_STRINGS_PER_ENTRY; j++) {
			members[i].key_offset[j] = cursor;
			cursor += (uint64_t)strlen(member_keys[j]) + 1;
		}
		for (j = 0; j < CNFATBIN_STRINGS_PER_ENTRY; j++) {
			members[i].value_offset[j] = cursor;
			members[i].value_size[j] = (uint64_t)strlen(values[j]);
			cursor += (uint64_t)strlen(values[j]) + 1;
		}
	}
	/* The images, each one 8-byte aligned. */
	/* Time: O(members).  Space: O(1). */
	for (i = 0; i < count; i++) {
		cursor = align_up(cursor, CNFATBIN_ALIGNMENT);
		members[i].image_offset = cursor;
		cursor += inputs[i].size;
	}
	*total = align_up(cursor, CNFATBIN_ALIGNMENT);
}

/*
 * The writing pass: put every part of the container where the sizing pass
 * said it goes.
 */
static void
write_container(const struct cnfatbin_input *inputs, size_t count,
    const struct write_member *members, uint8_t *out, uint64_t total)
{
	const char *values[CNFATBIN_STRINGS_PER_ENTRY];
	size_t i, j;

	out[0] = CNFATBIN_MAGIC_0;
	out[1] = CNFATBIN_MAGIC_1;
	out[2] = CNFATBIN_MAGIC_2;
	out[3] = CNFATBIN_MAGIC_3;
	write_le32(out + 4, CNFATBIN_VERSION);
	write_le64(out + 8, total);
	write_le64(out + 16, CNFATBIN_HEADER_SIZE);
	write_le64(out + 24, (uint64_t)count);

	/* The entries, one per member. */
	/* Time: O(members).  Space: O(1). */
	for (i = 0; i < count; i++) {
		uint8_t *entry = out + CNFATBIN_HEADER_SIZE +
		    i * CNFATBIN_ENTRY_SIZE;

		write_le16(entry, members[i].image_kind);
		write_le16(entry + 2, CNFATBIN_OFK_CUDA);
		write_le32(entry + 4, 0);
		write_le64(entry + 8, members[i].string_table_offset);
		write_le64(entry + 16, CNFATBIN_STRINGS_PER_ENTRY);
		write_le64(entry + 24, members[i].image_offset);
		write_le64(entry + 32, (uint64_t)inputs[i].size);
	}
	/* The string tables. */
	/* Time: O(members).  Space: O(1). */
	for (i = 0; i < count; i++) {
		uint8_t *table = out + members[i].string_table_offset;

		member_values(&members[i], values);
		for (j = 0; j < CNFATBIN_STRINGS_PER_ENTRY; j++) {
			uint8_t *map = table + j * CNFATBIN_STRING_ENTRY_SIZE;

			write_le64(map, members[i].key_offset[j]);
			write_le64(map + 8, members[i].value_offset[j]);
			write_le64(map + 16, members[i].value_size[j]);
		}
	}
	/* The strings themselves. */
	/* Time: O(strings in the container).  Space: O(1). */
	for (i = 0; i < count; i++) {
		member_values(&members[i], values);
		for (j = 0; j < CNFATBIN_STRINGS_PER_ENTRY; j++) {
			size_t length = strlen(member_keys[j]);

			memcpy(out + members[i].key_offset[j], member_keys[j],
			    length + 1);
		}
		for (j = 0; j < CNFATBIN_STRINGS_PER_ENTRY; j++) {
			size_t length = strlen(values[j]);

			memcpy(out + members[i].value_offset[j], values[j],
			    length + 1);
		}
	}
	/* The images. */
	/* Time: O(total image bytes).  Space: O(1). */
	for (i = 0; i < count; i++) {
		if (inputs[i].size > 0)
			memcpy(out + members[i].image_offset, inputs[i].data,
			    inputs[i].size);
	}
}

enum cnfatbin_error
cnfatbin_write(const struct cnfatbin_input *inputs, size_t count,
    uint8_t **buffer, size_t *size)
{
	struct write_member *members;
	uint64_t total;
	uint8_t *out;
	enum cnfatbin_error err;

	*buffer = NULL;
	*size = 0;
	if (count == 0)
		return CNFATBIN_E_NO_MEMBERS;
	if (count > CNFATBIN_MAX_ENTRIES)
		return CNFATBIN_E_TOO_MANY_ENTRIES;
	members = calloc(count, sizeof(*members));
	if (members == NULL)
		return CNFATBIN_E_NOMEM;
	err = prepare_members(inputs, count, members);
	if (err != CNFATBIN_OK) {
		free(members);
		return err;
	}
	size_container(inputs, count, members, &total);
	/* The writer refuses to write a container that the reader or the
	 * runtime stub would refuse: the same limit, and the same number of
	 * members. */
	if (total > (uint64_t)CNFATBIN_MAX_SIZE) {
		free(members);
		return CNFATBIN_E_OUTPUT_TOO_LARGE;
	}
	if (total > (uint64_t)SIZE_MAX) {
		free(members);
		return CNFATBIN_E_NOMEM;
	}
	out = calloc(1, (size_t)total);
	if (out == NULL) {
		free(members);
		return CNFATBIN_E_NOMEM;
	}
	write_container(inputs, count, members, out, total);

	free(members);
	*buffer = out;
	*size = (size_t)total;
	return CNFATBIN_OK;
}
void
cnfatbin_buffer_free(uint8_t *buffer, size_t size)
{
	(void)size;
	free(buffer);
}

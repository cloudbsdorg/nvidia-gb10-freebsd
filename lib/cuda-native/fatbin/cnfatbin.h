/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * cnfatbin.h - the cuda-native fatbin container.
 *
 * The container is LLVM's OffloadBinary format, version 2: the layout
 * documented in llvm/Object/OffloadBinary.h (Apache-2 with LLVM exception).
 * We write and read that layout with our own C; we never read, parse or
 * imitate NVIDIA's fatbin or cubin formats.
 *
 * A container is a header, one entry per member, one string table per entry
 * and the member images.  Every offset is an absolute byte offset from the
 * start of the container and every field is little-endian.  The header, the
 * entries table, each entry's string table and each image start at an
 * 8-byte aligned offset.  The keys and the values inside the string blob
 * are packed one after another and are not aligned; that is how LLVM
 * writes them, and llvm-objdump reads both.
 *
 * One reader and one writer live here.  The tools nvfatbin(1) and
 * cuda-objdump(1) and the libcudart stub all use them, so a container that
 * one of them writes is read the same way by the others.
 */

#ifndef CNFATBIN_H
#define CNFATBIN_H

#include <stddef.h>
#include <stdint.h>

/* The OffloadBinary magic bytes, 0x10 0xFF 0x10 0xAD. */
#define CNFATBIN_MAGIC_0	0x10
#define CNFATBIN_MAGIC_1	0xff
#define CNFATBIN_MAGIC_2	0x10
#define CNFATBIN_MAGIC_3	0xad

/* The only container version this slice writes and reads. */
#define CNFATBIN_VERSION	2u

/* The offsets that are 8-byte aligned. */
#define CNFATBIN_ALIGNMENT	8u

/* A container never holds more entries than this. */
#define CNFATBIN_MAX_ENTRIES	4096u

/*
 * The most strings one entry may carry.  It is a limit of the format and
 * not an accident of the reader: a container that asks for more is
 * refused, and a container that carries fewer opens as it is.
 */
#define CNFATBIN_MAX_STRINGS_PER_ENTRY 16384u

/* The largest container we write, and the largest one we read from a
 * pointer that comes without a length of its own. */
#define CNFATBIN_MAX_SIZE	(16u * 1024u * 1024u)

/* On-disk sizes, all little-endian. */
#define CNFATBIN_HEADER_SIZE	32u
#define CNFATBIN_ENTRY_SIZE	40u
#define CNFATBIN_STRING_ENTRY_SIZE 24u

/* Image kinds, as LLVM's OffloadBinary::ImageKind numbers them.  A kind of
 * none means the writer did not name the kind of the image; LLVM's own
 * packager writes that, and we accept it. */
#define CNFATBIN_IMG_NONE	0
#define CNFATBIN_IMG_CUBIN	3
#define CNFATBIN_IMG_PTX	5

/* Offload kinds, as LLVM's OffloadBinary::OffloadKind numbers them.  A kind
 * of none means the writer did not name the producer; we accept that too. */
#define CNFATBIN_OFK_NONE	0
#define CNFATBIN_OFK_CUDA	2

/* The triple every CUDA member carries. */
#define CNFATBIN_TRIPLE		"nvptx64-nvidia-cuda"

/* The keys LLVM itself reads. */
#define CNFATBIN_KEY_TRIPLE	"triple"
#define CNFATBIN_KEY_ARCH	"arch"

/* Our own keys, in addition to the two above. */
#define CNFATBIN_KEY_FORMAT	"cloudbsd.format"
#define CNFATBIN_KEY_SHA256	"cloudbsd.sha256"

/* Our own format values. */
#define CNFATBIN_FORMAT_PTX	"ptx"
#define CNFATBIN_FORMAT_CUBIN	"nvcubin/1"

/* The magic our own nvptxas stub writes in front of a cubin payload. */
#define CNFATBIN_CUBIN_MAGIC	"CUDA-NATIVE-STUB-CUBIN 1\n"

/*
 * The longest values we keep, and the digest we keep.  A value of one of
 * the keys we know that does not fit the field it belongs to is refused;
 * a key we do not know is ignored, and its value may be as long as it
 * likes.
 */
#define CNFATBIN_TRIPLE_MAX	64
#define CNFATBIN_ARCH_MAX	32
#define CNFATBIN_FORMAT_MAX	32
#define CNFATBIN_SHA256_HEX_MAX	64

/* The longest key we look at; a longer key is one we do not know. */
#define CNFATBIN_KEY_MAX	64

/*
 * Every way a container can be refused.  Each code has one short name and
 * one message, and both live in the table in cnfatbin.c.
 */
enum cnfatbin_error {
	CNFATBIN_OK = 0,
	CNFATBIN_E_SHORT_INPUT,
	CNFATBIN_E_BAD_MAGIC,
	CNFATBIN_E_BAD_VERSION,
	CNFATBIN_E_SIZE_TOO_LARGE,
	CNFATBIN_E_TOO_MANY_ENTRIES,
	CNFATBIN_E_ENTRIES_OUT_OF_RANGE,
	CNFATBIN_E_IMAGE_OUT_OF_RANGE,
	CNFATBIN_E_STRING_OUT_OF_RANGE,
	CNFATBIN_E_STRING_NOT_TERMINATED,
	CNFATBIN_E_BAD_IMAGE_KIND,
	CNFATBIN_E_BAD_OFFLOAD_KIND,
	CNFATBIN_E_SHA256_FORMAT,
	CNFATBIN_E_SHA256_MISMATCH,
	CNFATBIN_E_VALUE_TOO_LONG,
	CNFATBIN_E_HASH_BUDGET,
	CNFATBIN_E_OUTPUT_TOO_LARGE,
	CNFATBIN_E_NO_MEMBERS,
	CNFATBIN_E_NOMEM,
	CNFATBIN_ERROR_COUNT
};

/* One member of a container, as the reader sees it. */
struct cnfatbin_member {
	uint16_t image_kind;
	uint16_t offload_kind;
	uint32_t flags;
	uint64_t image_offset;
	uint64_t image_size;
	int has_format;
	/* The digest was there and it matched: a mismatch is a refusal, so a
	 * member that carries a digest has always had it checked. */
	int has_sha256;
	char triple[CNFATBIN_TRIPLE_MAX];
	char arch[CNFATBIN_ARCH_MAX];
	char format[CNFATBIN_FORMAT_MAX];
	char sha256[CNFATBIN_SHA256_HEX_MAX + 1];
};

/* A container opened for reading.  The bytes stay owned by the caller. */
struct cnfatbin_container {
	const uint8_t *data;
	size_t size;
	uint32_t version;
	uint64_t entries_count;
	struct cnfatbin_member *members;
};

/* What the writer is asked to put in one member. */
enum cnfatbin_kind {
	CNFATBIN_KIND_PTX = 0,
	CNFATBIN_KIND_CUBIN = 1
};

struct cnfatbin_input {
	int kind;
	unsigned int sm;
	char suffix;			/* 'a', 'f' or 0 for none */
	const uint8_t *data;
	size_t size;
};

/*
 * The short name of one named error, the way the tools print it:
 * "bad-magic", "image-out-of-range" and so on.  Never NULL.
 */
const char *cnfatbin_error_name(enum cnfatbin_error err);

/* The message of one named error.  Never NULL. */
const char *cnfatbin_strerror(enum cnfatbin_error err);

/*
 * Whether the bytes start with the container magic.  One place knows the
 * magic, so every reader of ours agrees on it.
 */
int cnfatbin_has_magic(const uint8_t *data, size_t size);

/*
 * Read a container.  The size is the number of bytes at data that are ours
 * to read: the container's own header must not claim more than that.  The
 * caller keeps the bytes alive until cnfatbin_close().  On failure the
 * container is left empty and the named error is returned; nothing is read
 * past the end of the input.
 */
enum cnfatbin_error
cnfatbin_open(const uint8_t *data, size_t size,
    struct cnfatbin_container *container);

/* Release the members of a container opened by cnfatbin_open(). */
void cnfatbin_close(struct cnfatbin_container *container);

/*
 * The length the container claims in its own header.  The available length
 * is the number of bytes at data that are ours to read; it must be at least
 * a whole header.
 */
enum cnfatbin_error
cnfatbin_peek_size(const uint8_t *data, size_t available, uint64_t *size);

/*
 * How many bytes at the pointer may be read.  A pointer that comes without
 * a length of its own is inside a loaded object, and the PT_LOAD segment
 * that holds it gives the bound: the distance from the pointer to the end
 * of that segment's memory image, which is never past the bytes the loader
 * mapped.  The bound is never more than CNFATBIN_MAX_SIZE.
 *
 * A pointer in no loaded object has no bound at all, and cnfatbin_bound()
 * returns zero for it, so the caller refuses it.  A program that holds a
 * container in a mapping of its own registers that mapping with
 * cnfatbin_register_mapping() and the bound is the end of that mapping.
 */
size_t cnfatbin_bound(const void *data);

/*
 * The reader can bound a container that a program built in a mapping of its
 * own, which is in no loaded object.  This build always has that hook; a
 * caller that uses it compiles against CNFATBIN_HAVE_MAPPING_HOOK.
 */
#define CNFATBIN_HAVE_MAPPING_HOOK 1

/*
 * The most mappings a program may tell the reader about.  The registry of
 * mappings grows as it is used, so a program that registers many mappings
 * is not refused for want of space, but the registry has a bound: a
 * program that registers mappings for ever cannot make the host hold more
 * than this many of them.  A registration past the bound is refused with
 * CNFATBIN_REGISTER_TOO_MANY, and the reason names the bound.
 */
#define CNFATBIN_MAX_MAPPINGS 4096

/*
 * The size of one entry in the registry of mappings.  The registry grows by
 * doubling, and the doubling is checked against this size, so the size the
 * registry asks the host for is known to the caller.
 */
#define CNFATBIN_MAPPING_SIZE 16

/*
 * Why a mapping was not registered.  Every cause has its own name and its
 * own message, so a caller can say what happened without a table of its
 * own.  The zero result is the one that says the mapping was recorded.
 */
enum cnfatbin_register_result {
	CNFATBIN_REGISTER_OK = 0,
	CNFATBIN_REGISTER_BAD_ARGUMENT,	/* no base, or an empty mapping */
	CNFATBIN_REGISTER_TOO_MANY,	/* the registry is full */
	CNFATBIN_REGISTER_OVERFLOW,	/* the size does not fit */
	CNFATBIN_REGISTER_NOMEM,	/* the host is out of memory */
	CNFATBIN_REGISTER_COUNT
};

/*
 * The message of one named registration result.  Never NULL.
 */
const char *cnfatbin_register_reason(enum cnfatbin_register_result result);

/*
 * The capacity the registry of mappings grows to, and the number of bytes
 * that is.  The registry grows by doubling, and the doubling is checked
 * before it is multiplied: a capacity that cannot be doubled, or a size
 * that cannot be multiplied, is refused with CNFATBIN_REGISTER_OVERFLOW
 * and the registry is left as it was.  The reader grows the registry with
 * this, and the test proves that the arithmetic is checked.
 */
enum cnfatbin_register_result
cnfatbin_registry_growth(size_t capacity, size_t *grown, size_t *bytes);

/*
 * How many mappings the registry holds.  The count is at most
 * CNFATBIN_MAX_MAPPINGS, and a registration that is refused does not
 * change it.
 */
size_t cnfatbin_registered_mappings(void);

/*
 * Tell the reader that a mapping of ours holds a container, so that it can
 * bound the reads it makes there.  The runtime uses this for a container a
 * program built in memory of its own; the pointer must lie inside the
 * registered mapping.  The registry grows as it is used and has a bound:
 * CNFATBIN_MAX_MAPPINGS mappings at most.  Returns CNFATBIN_REGISTER_OK
 * when the mapping was recorded, and another named result when it was
 * not: a null pointer, an empty mapping, a full registry, an arithmetic
 * that does not fit, or a host that is out of memory.
 */
enum cnfatbin_register_result
cnfatbin_register_mapping(const void *base, size_t length);

/*
 * Write a container.  The result is a malloc'd buffer of *size bytes; the
 * caller frees it with cnfatbin_buffer_free().  The writer refuses to
 * produce a container the reader or the runtime would refuse: a container
 * with no members, one with more members than CNFATBIN_MAX_ENTRIES and one
 * larger than CNFATBIN_MAX_SIZE are refused, each with its own error.
 */
enum cnfatbin_error
cnfatbin_write(const struct cnfatbin_input *inputs, size_t count,
    uint8_t **buffer, size_t *size);

/* Free a buffer returned by cnfatbin_write(). */
void cnfatbin_buffer_free(uint8_t *buffer, size_t size);

/* The hex SHA-256 of a buffer, in out[0..64].  Returns 0 on success. */
int cnfatbin_sha256_hex(const uint8_t *data, size_t size, char *out);

/* The name of an image kind: "ptx", "cubin", "none" or "unknown". */
const char *cnfatbin_image_kind_name(uint16_t image_kind);

/* The name of an offload kind: "cuda", "none" or "unknown". */
const char *cnfatbin_offload_kind_name(uint16_t offload_kind);

#endif /* CNFATBIN_H */

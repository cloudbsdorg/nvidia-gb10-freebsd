/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * cuda-objdump.c - list the members of a cuda-native fatbin container.
 *
 * The container is LLVM's OffloadBinary format, version 2; see nvfatbin(5).
 * The file may be the container itself or an ELF object or executable that
 * carries one in its .nv_fatbin section, which is where clang puts it.
 */

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <libelf.h>
#include <gelf.h>

#include "cnfatbin.h"
#include "cntool.h"

#define TOOL_NAME "cuda-objdump"
#define SCHEMA_NAME "cuda-objdump/1"

/* Filled in by mksdk.sh from CUDA_NATIVE_VERSION in cuda.h. */
#define CUDA_NATIVE_VERSION_TEXT "@CUDA_NATIVE_VERSION@"
#define CUDA_NATIVE_VERSION_MAJOR @CUDA_NATIVE_VERSION_MAJOR@
#define CUDA_NATIVE_VERSION_MINOR @CUDA_NATIVE_VERSION_MINOR@
#define CUDA_NATIVE_VERSION_PATCH @CUDA_NATIVE_VERSION_PATCH@

/* The section clang puts the container in. */
#define FATBIN_SECTION ".nv_fatbin"

static const char schema_text[] =
#include "schema.inc"
;

enum output_mode {
	MODE_TEXT,
	MODE_JSON,
	MODE_JSONL
};

static void
usage(void)
{
	printf("usage: %s [--json|--jsonl] FILE\n", TOOL_NAME);
	printf("       %s --extract INDEX OUTPUT FILE\n", TOOL_NAME);
	printf("       %s --schema\n", TOOL_NAME);
	printf("       %s --version [--json]\n", TOOL_NAME);
	printf("       %s -h|--help\n", TOOL_NAME);
}

/* Write one line and flush it; a closed pipe is a clean end. */
static void
flush_line(void)
{
	if (fflush(stdout) != 0) {
		if (errno == EPIPE)
			exit(0);
		cntool_fail(TOOL_NAME, 1, "cannot write output");
	}
}

static void
print_member_json(FILE *stream, const struct cnfatbin_member *member,
    size_t index)
{
	fprintf(stream, "{\"schema\":\"%s\",\"index\":%zu,\"kind\":\"%s\",",
	    SCHEMA_NAME, index, cnfatbin_image_kind_name(member->image_kind));
	fputs("\"arch\":", stream);
	cntool_json_escape(stream, member->arch);
	if (member->triple[0] != '\0') {
		fputs(",\"triple\":", stream);
		cntool_json_escape(stream, member->triple);
	}
	if (member->has_format) {
		fputs(",\"format\":", stream);
		cntool_json_escape(stream, member->format);
	}
	fprintf(stream, ",\"size\":%llu",
	    (unsigned long long)member->image_size);
	if (member->has_sha256) {
		fputs(",\"sha256\":", stream);
		cntool_json_escape(stream, member->sha256);
	}
	fputc('}', stream);
}

/* Is this the container itself? */
static int
looks_like_container(const uint8_t *data, size_t size)
{
	return cnfatbin_has_magic(data, size);
}

/*
 * Find the .nv_fatbin section of an ELF file and copy it out.  Returns 0
 * when the section was found, 1 when the file is not an ELF at all and 2
 * when it is an ELF without the section.
 */
static int
read_fatbin_section(const char *path, uint8_t **data, size_t *size)
{
	Elf *elf;
	Elf_Scn *scn;
	size_t shstrndx = 0;
	int fd;
	int found = 2;

	/* libelf needs its version before any other call. */
	if (elf_version(EV_CURRENT) == EV_NONE)
		return 1;
	fd = open(path, O_RDONLY);
	if (fd < 0)
		return 1;
	elf = elf_begin(fd, ELF_C_READ, NULL);
	if (elf == NULL) {
		close(fd);
		return 1;
	}
	if (elf_kind(elf) != ELF_K_ELF) {
		elf_end(elf);
		close(fd);
		return 1;
	}
	if (elf_getshdrstrndx(elf, &shstrndx) != 0) {
		elf_end(elf);
		close(fd);
		return 1;
	}
	scn = elf_nextscn(elf, NULL);
	/* Time: O(sections in the file).  Space: O(container size). */
	while (scn != NULL) {
		size_t name_offset = 0;
		const char *name;

		/* The name of a section is an offset in the string table of
		 * the section headers, not the index of the section. */
		if (gelf_getclass(elf) == ELFCLASS64) {
			Elf64_Shdr *shdr = elf64_getshdr(scn);

			if (shdr != NULL)
				name_offset = shdr->sh_name;
		} else {
			Elf32_Shdr *shdr = elf32_getshdr(scn);

			if (shdr != NULL)
				name_offset = shdr->sh_name;
		}
		name = elf_strptr(elf, shstrndx, name_offset);
		if (name != NULL && strcmp(name, FATBIN_SECTION) == 0) {
			Elf_Data *section = elf_getdata(scn, NULL);

			if (section == NULL || section->d_buf == NULL ||
			    section->d_size == 0)
				break;
			*data = malloc(section->d_size);
			if (*data == NULL) {
				elf_end(elf);
				close(fd);
				cntool_fail(TOOL_NAME, 1, "host memory exhausted");
			}
			memcpy(*data, section->d_buf, section->d_size);
			*size = section->d_size;
			found = 0;
			break;
		}
		scn = elf_nextscn(elf, scn);
	}
	elf_end(elf);
	close(fd);
	return found;
}

/* What the command line asked for. */
struct options {
	enum output_mode mode;
	const char *path;
	const char *extract_path;
	unsigned long extract_index;
	int have_extract;
	int have_json;
	int have_jsonl;
};

/*
 * The member index: a non-empty run of decimal digits that fits in an
 * unsigned long.  A sign, a space, a letter and a number too large are
 * all usage problems, and the diagnostic says what an index is.
 */
static unsigned long
parse_index(const char *text)
{
	unsigned long value;
	char *end = NULL;
	char escaped[CNTOOL_ESCAPED_MAX];
	size_t i;

	/* The index comes from the command line: it is escaped before it
	 * goes in a diagnostic, so a control byte in it cannot write to the
	 * terminal. */
	cntool_escape_text(escaped, sizeof(escaped), text);
	if (text[0] == '\0')
		cntool_fail(TOOL_NAME, 2,
		    "member index must be a non-negative integer: %s", escaped);
	/* Time: O(digits).  Space: O(1). */
	for (i = 0; text[i] != '\0'; i++) {
		if (text[i] < '0' || text[i] > '9')
			cntool_fail(TOOL_NAME, 2,
			    "member index must be a non-negative integer: %s",
			    escaped);
	}
	errno = 0;
	value = strtoul(text, &end, 10);
	if (errno == ERANGE || end == text || *end != '\0')
		cntool_fail(TOOL_NAME, 2,
		    "member index must be a non-negative integer: %s", escaped);
	return value;
}

/*
 * Say the version, in the form the caller asked for.  The version takes
 * no operand: --version alone, or --version --json.  Every other form is
 * a usage problem, and no version is printed.
 */
static void
print_version(int argc, char **argv)
{
	char escaped[CNTOOL_ESCAPED_MAX];

	if (argc > 2 && strcmp(argv[2], "--json") == 0) {
		if (argc > 3)
			cntool_fail(TOOL_NAME, 2, "unexpected argument %s; "
			    "only --json may follow --version",
			    cntool_escape_text(escaped, sizeof(escaped),
			    argv[3]));
		printf("{\"schema\":\"%s\",\"tool\":\"%s\","
		    "\"version\":\"%s\",\"version_major\":%d,"
		    "\"version_minor\":%d,\"version_patch\":%d}\n",
		    SCHEMA_NAME, TOOL_NAME, CUDA_NATIVE_VERSION_TEXT,
		    CUDA_NATIVE_VERSION_MAJOR, CUDA_NATIVE_VERSION_MINOR,
		    CUDA_NATIVE_VERSION_PATCH);
		return;
	}
	if (argc > 2) {
		if (argv[2][0] == '-')
			cntool_fail(TOOL_NAME, 2,
			    "unsupported option %s; see %s(1)",
			    cntool_escape_text(escaped, sizeof(escaped),
			    argv[2]), TOOL_NAME);
		cntool_fail(TOOL_NAME, 2, "unexpected argument %s; only --json "
		    "may follow --version",
		    cntool_escape_text(escaped, sizeof(escaped), argv[2]));
	}
	printf("%s (cuda-native) %s\n", TOOL_NAME, CUDA_NATIVE_VERSION_TEXT);
}

/*
 * Read the command line.  Returns 0 when there is work to do and 1 when
 * the tool has already answered everything, as it does for --help.
 */
static int
parse_arguments(int argc, char **argv, struct options *options)
{
	char escaped[CNTOOL_ESCAPED_MAX];
	int argi;

	/* Time: O(arguments).  Space: O(1). */
	for (argi = 1; argi < argc; argi++) {
		const char *arg = argv[argi];

		if (strcmp(arg, "-h") == 0 || strcmp(arg, "--help") == 0) {
			usage();
			return 1;
		}
		if (strcmp(arg, "--schema") == 0) {
			fputs(schema_text, stdout);
			return 1;
		}
		if (strcmp(arg, "--json") == 0) {
			options->have_json = 1;
			options->mode = MODE_JSON;
			continue;
		}
		if (strcmp(arg, "--jsonl") == 0) {
			options->have_jsonl = 1;
			options->mode = MODE_JSONL;
			continue;
		}
		if (strcmp(arg, "--extract") == 0) {
			if (argi + 2 >= argc)
				cntool_fail(TOOL_NAME, 2,
				    "option requires two arguments: %s", arg);
			if (options->have_extract)
				cntool_fail(TOOL_NAME, 2,
				    "--extract may be given only once");
			options->extract_index = parse_index(argv[argi + 1]);
			options->extract_path = argv[argi + 2];
			options->have_extract = 1;
			argi += 2;
			continue;
		}
		if (arg[0] == '-' && arg[1] != '\0')
			cntool_fail(TOOL_NAME, 2,
			    "unsupported option %s; see %s(1)",
			    cntool_escape_text(escaped, sizeof(escaped), arg),
			    TOOL_NAME);
		if (options->path != NULL)
			cntool_fail(TOOL_NAME, 2, "unexpected argument %s; only "
			    "one file is read",
			    cntool_escape_text(escaped, sizeof(escaped), arg));
		options->path = arg;
	}
	/* The output modes cannot be combined: the last one would otherwise
	 * win, and a script that asked for JSON would get nothing. */
	if (options->have_json && options->have_jsonl)
		cntool_fail(TOOL_NAME, 2,
		    "choose only one output mode: --json and --jsonl cannot be "
		    "combined");
	if (options->have_extract && (options->have_json ||
	    options->have_jsonl))
		cntool_fail(TOOL_NAME, 2, "--extract cannot be combined with %s",
		    options->have_json ? "--json" : "--jsonl");
	if (options->path == NULL)
		cntool_fail(TOOL_NAME, 2, "a file is required; use -h for usage");
	return 0;
}

/*
 * Load the container: the file itself when it is one, the .nv_fatbin
 * section of an ELF file when it is not.  The bytes stay owned by the
 * caller, which frees both *owned and *section.
 */
static void
load_container(const char *path, uint8_t **owned, uint8_t **section,
    const uint8_t **bytes, size_t *container_size, const char **source)
{
	char escaped[CNTOOL_ESCAPED_MAX];
	char why[CNTOOL_REASON_MAX];
	size_t size = 0;
	size_t offset = 0;
	enum cntool_read_result reason;
	int rc;

	reason = cntool_read_file(path, owned, &size, CNTOOL_MAX_FILE_SIZE);
	if (reason != CNTOOL_READ_OK)
		cntool_fail(TOOL_NAME, 1, "cannot read %s: %s",
		    cntool_escape_text(escaped, sizeof(escaped), path),
		    cntool_read_reason(why, sizeof(why), reason,
		    CNTOOL_MAX_FILE_SIZE));
	*bytes = *owned;
	*container_size = size;
	if (looks_like_container(*owned, size))
		return;
	/* The file is not the container itself.  The bytes we read stay
	 * ours until we know what the file is: a file that is neither a
	 * container nor an ELF is handed to the reader as it is, so that
	 * the reader says what is wrong with it.  Nothing reads the bytes
	 * after they are freed. */
	rc = read_fatbin_section(path, section, &size);
	if (rc == 2) {
		/* An ELF file without the section: the bytes are of no use. */
		free(*owned);
		*owned = NULL;
		cntool_fail(TOOL_NAME, 1, "no %s section in %s", FATBIN_SECTION,
		    cntool_escape_text(escaped, sizeof(escaped), path));
	}
	if (rc == 1) {
		/* Not an ELF file: the reader says what is wrong with the
		 * bytes, and the bytes are still ours. */
		return;
	}
	free(*owned);
	*owned = NULL;
	*source = "section";
	/* The container is inside the section; it usually starts at its
	 * first byte. */
	/* Time: O(section size).  Space: O(1). */
	while (offset + 4 <= size &&
	    !looks_like_container(*section + offset, size - offset))
		offset++;
	if (offset + 4 > size)
		cntool_fail(TOOL_NAME, 1, "no cuda-native container in the %s "
		    "section of %s", FATBIN_SECTION,
		    cntool_escape_text(escaped, sizeof(escaped), path));
	*bytes = *section + offset;
	*container_size = size - offset;
}

/*
 * Write the image of one member to a file.  The directory the file goes in
 * is opened once and the file is written inside it, so a directory that is
 * replaced after the name was checked cannot redirect the write.
 */
static void
extract_member(unsigned long index, const char *out_path,
    const struct cnfatbin_container *container, const uint8_t *bytes)
{
	char escaped[CNTOOL_ESCAPED_MAX];
	struct cntool_output output;
	enum cntool_write_result result;

	if (index >= container->entries_count) {
		if (container->entries_count == 0)
			cntool_fail(TOOL_NAME, 1, "member index %lu is out of "
			    "range; the container has no members", index);
		cntool_fail(TOOL_NAME, 1, "member index %lu is out of range; "
		    "valid indexes are 0-%llu", index,
		    (unsigned long long)(container->entries_count - 1));
	}
	result = cntool_output_open(out_path, &output);
	if (result != CNTOOL_WRITE_OK)
		cntool_fail(TOOL_NAME, 1, "cannot create output: %s: %s",
		    cntool_escape_text(escaped, sizeof(escaped), out_path),
		    cntool_write_reason(result));
	result = cntool_output_write(&output,
	    bytes + container->members[index].image_offset,
	    (size_t)container->members[index].image_size, 0644);
	cntool_output_close(&output);
	if (result != CNTOOL_WRITE_OK)
		cntool_fail(TOOL_NAME, 1, "cannot write output: %s: %s",
		    cntool_escape_text(escaped, sizeof(escaped), out_path),
		    cntool_write_reason(result));
}

/* The text listing: one line per member. */
static void
output_text(const char *path, const char *source,
    const struct cnfatbin_container *container)
{
	size_t i;

	/* The path and the metadata come from outside, so every byte that
	 * is not a character is shown as an escape: no raw control byte
	 * reaches the terminal, and one member stays one line. */
	cntool_write_text(stdout, path);
	printf(": %s, container version %u, %llu members\n", source,
	    container->version, (unsigned long long)container->entries_count);
	/* Time: O(members).  Space: O(1). */
	for (i = 0; i < (size_t)container->entries_count; i++) {
		const struct cnfatbin_member *m = &container->members[i];

		printf("[%zu] %s arch=", i,
		    cnfatbin_image_kind_name(m->image_kind));
		cntool_write_text(stdout, m->arch[0] != '\0' ? m->arch : "-");
		fputs(" format=", stdout);
		cntool_write_text(stdout, m->has_format ? m->format : "-");
		fprintf(stdout, " size=%llu sha256=",
		    (unsigned long long)m->image_size);
		cntool_write_text(stdout, m->has_sha256 ? m->sha256 : "-");
		fputc('\n', stdout);
	}
}

/* The head every JSON document starts with: the schema, the tool, the file. */
static void
print_json_head(const char *path)
{
	printf("{\"schema\":\"%s\",\"tool\":\"%s\",\"file\":", SCHEMA_NAME,
	    TOOL_NAME);
	cntool_json_escape(stdout, path);
}

/* The JSON document: one object with every member in it. */
static void
output_json(const char *path, const char *source,
    const struct cnfatbin_container *container)
{
	size_t i;

	print_json_head(path);
	printf(",\"source\":\"%s\",\"container_version\":%u,\"members\":[",
	    source, container->version);
	/* Time: O(members).  Space: O(1). */
	for (i = 0; i < (size_t)container->entries_count; i++) {
		if (i > 0)
			fputc(',', stdout);
		print_member_json(stdout, &container->members[i], i);
	}
	printf("]}\n");
	flush_line();
}

/* The JSON lines: a header line and one line per member. */
static void
output_jsonl(const char *path, const char *source,
    const struct cnfatbin_container *container)
{
	size_t i;

	print_json_head(path);
	printf(",\"source\":\"%s\",\"container_version\":%u,\"members\":%llu}\n",
	    source, container->version,
	    (unsigned long long)container->entries_count);
	flush_line();
	/* Time: O(members).  Space: O(1). */
	for (i = 0; i < (size_t)container->entries_count; i++) {
		print_member_json(stdout, &container->members[i], i);
		fputc('\n', stdout);
		flush_line();
	}
}

int
main(int argc, char **argv)
{
	struct options options;
	uint8_t *owned = NULL;
	uint8_t *section = NULL;
	const uint8_t *container_bytes = NULL;
	size_t container_size = 0;
	struct cnfatbin_container container;
	const char *source = "container";
	enum cnfatbin_error err;

	/* A closed pipe is a clean end, not a signal. */
	signal(SIGPIPE, SIG_IGN);

	if (argc > 1 && strcmp(argv[1], "--version") == 0) {
		print_version(argc, argv);
		return 0;
	}

	memset(&options, 0, sizeof(options));
	options.mode = MODE_TEXT;
	if (parse_arguments(argc, argv, &options))
		return 0;

	load_container(options.path, &owned, &section, &container_bytes,
	    &container_size, &source);

	err = cnfatbin_open(container_bytes, container_size, &container);
	if (err != CNFATBIN_OK) {
		char escaped[CNTOOL_ESCAPED_MAX];

		cntool_fail(TOOL_NAME, 1, "%s: %s",
		    cntool_escape_text(escaped, sizeof(escaped), options.path),
		    cnfatbin_strerror(err));
	}

	if (options.have_extract)
		extract_member(options.extract_index, options.extract_path,
		    &container, container_bytes);
	else
		switch (options.mode) {
		case MODE_TEXT:
			output_text(options.path, source, &container);
			break;
		case MODE_JSON:
			output_json(options.path, source, &container);
			break;
		case MODE_JSONL:
			output_jsonl(options.path, source, &container);
			break;
		}

	cnfatbin_close(&container);
	free(owned);
	free(section);
	return 0;
}

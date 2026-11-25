/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * nvfatbin.c - the cuda-native nvfatbin tool, installed as nvfatbin and as
 * its fatbinary alias.  It is the tool clang's CUDA driver runs to collect
 * device images, and it writes one container per invocation.
 *
 * The container is LLVM's OffloadBinary format, version 2; see nvfatbin(5).
 * The command line, the diagnostics and the exit statuses are the ones the
 * shell stub used, so clang behaves exactly as before.
 */

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "cnfatbin.h"
#include "cntool.h"

/* Filled in by mksdk.sh from CUDA_NATIVE_VERSION in cuda.h. */
#define CUDA_NATIVE_VERSION_TEXT "@CUDA_NATIVE_VERSION@"
#define CUDA_NATIVE_VERSION_MAJOR @CUDA_NATIVE_VERSION_MAJOR@
#define CUDA_NATIVE_VERSION_MINOR @CUDA_NATIVE_VERSION_MINOR@
#define CUDA_NATIVE_VERSION_PATCH @CUDA_NATIVE_VERSION_PATCH@

/* The canonical name of the tool: the one the JSON and the trace records
 * carry. */
#define TOOL_NAME "nvfatbin"

/*
 * The name the program was invoked as.  It is the basename of argv[0], and
 * it is the name in the usage line and in every diagnostic: a user who runs
 * fatbinary reads fatbinary, not nvfatbin.
 *
 * The name comes from the command line, so it is escaped before it goes in
 * a message: a control byte in it cannot write to the terminal.
 */
static char program_name_buffer[CNTOOL_ESCAPED_MAX];
static const char *program_name = TOOL_NAME;

/* The basename of the path the program was invoked with. */
static const char *
invoked_name(const char *argv0)
{
	const char *slash;

	if (argv0 == NULL || *argv0 == '\0')
		return TOOL_NAME;
	slash = strrchr(argv0, '/');
	return slash != NULL ? slash + 1 : argv0;
}

/*
 * Set the name the program was invoked as.  This happens before any
 * message is made: the version, the usage line and every diagnostic carry
 * the name the user typed.
 */
static void
set_program_name(const char *argv0)
{
	const char *name = invoked_name(argv0);

	program_name = cntool_escape_text(program_name_buffer,
	    sizeof(program_name_buffer), name);
}

/* One --image3 argument, parsed but not yet read. */
struct image_spec {
	int kind;			/* CNFATBIN_KIND_PTX or _CUBIN */
	unsigned int sm;
	char suffix;			/* 'a', 'f' or 0 */
	char *file;
};

static void
usage(void)
{
	printf("usage: %s [-64] [-g] --create FILE\n", program_name);
	printf("       %s --image3=kind=elf|ptx,sm=NNN,file=INPUT [...]\n",
	    program_name);
	printf("       %s --version [--json]\n", program_name);
	printf("       %s -h|--help\n", program_name);
}

/* A usage or argument problem: exit status 2. */
static void
unsupported_option(const char *option)
{
	char escaped[CNTOOL_ESCAPED_MAX];

	cntool_fail(program_name, 2, "unsupported option %s; not supported by the "
	    "cuda-native stub; see nvfatbin(1); use -h for usage",
	    cntool_escape_text(escaped, sizeof(escaped), option));
}

static void
unexpected_argument(const char *argument, const char *guidance)
{
	char escaped[CNTOOL_ESCAPED_MAX];

	cntool_fail(program_name, 2, "unexpected argument %s; %s",
	    cntool_escape_text(escaped, sizeof(escaped), argument), guidance);
}

/*
 * How much of a UTF-8 sequence is still to come, and the range the next
 * byte must be in.
 */
struct utf8_state {
	unsigned int left;
	unsigned int low;
	unsigned int high;
};

/*
 * Start a UTF-8 sequence: set how many continuation bytes are needed and
 * the range the first of them must be in.  Returns 0 when the byte is a
 * valid lead byte and 2 when it is not.
 */
static int
start_sequence(struct utf8_state *state, unsigned int byte)
{
	if (byte >= 0xc2 && byte <= 0xdf) {
		state->left = 1;
		state->low = 0x80;
		state->high = 0xbf;
	} else if (byte == 0xe0) {
		state->left = 2;
		state->low = 0xa0;
		state->high = 0xbf;
	} else if ((byte >= 0xe1 && byte <= 0xec) ||
	    (byte >= 0xee && byte <= 0xef)) {
		state->left = 2;
		state->low = 0x80;
		state->high = 0xbf;
	} else if (byte == 0xed) {
		state->left = 2;
		state->low = 0x80;
		state->high = 0x9f;
	} else if (byte == 0xf0) {
		state->left = 3;
		state->low = 0x90;
		state->high = 0xbf;
	} else if (byte >= 0xf1 && byte <= 0xf3) {
		state->left = 3;
		state->low =  0x80;
		state->high = 0xbf;
	} else if (byte == 0xf4) {
		state->left = 3;
		state->low = 0x80;
		state->high = 0x8f;
	} else
		return 2;
	return 0;
}

/*
 * Take one byte of a UTF-8 string.  Returns 0 when the byte is good, 1
 * when it is a control byte and 2 when the string is not UTF-8.
 */
static int
check_byte(struct utf8_state *state, unsigned int byte)
{
	if (byte < 0x20 || byte == 0x7f)
		return 1;
	if (state->left > 0) {
		if (byte < state->low || byte > state->high)
			return 2;
		state->left--;
		state->low = 0x80;
		state->high = 0xbf;
		return 0;
	}
	if (byte < 0x80)
		return 0;
	return start_sequence(state, byte);
}

/*
 * Is the argument a valid UTF-8 string without control bytes?  Returns 0
 * when it is, 1 when it holds a control byte and 2 when it is not UTF-8.
 */
static int
check_argument(const char *s)
{
	const unsigned char *p = (const unsigned char *)s;
	struct utf8_state state;

	state.left = 0;
	state.low = 0;
	state.high = 0;
	/* Time: O(argument bytes).  Space: O(1). */
	while (*p != '\0') {
		unsigned int byte = *p++;
		int rc = check_byte(&state, byte);

		if (rc != 0)
			return rc;
	}
	return state.left == 0 ? 0 : 2;
}

static void
validate_argument(const char *s, const char *what)
{
	int rc = check_argument(s);

	if (rc == 1)
		cntool_fail(program_name, 2, "control characters in %s are not supported", what);
	if (rc == 2)
		cntool_fail(program_name, 2, "invalid UTF-8 in %s", what);
}

static void
show_version(int as_json)
{
	if (as_json) {
		printf("{\"tool\":\"%s\",\"version\":\"%s\",\"version_major\":%d,"
		    "\"version_minor\":%d,\"version_patch\":%d,\"stub\":true,"
		    "\"track\":\"2427\"}\n", TOOL_NAME, CUDA_NATIVE_VERSION_TEXT,
		    CUDA_NATIVE_VERSION_MAJOR, CUDA_NATIVE_VERSION_MINOR,
		    CUDA_NATIVE_VERSION_PATCH);
	} else
		printf("%s (cuda-native) %s stub\n", program_name,
		    CUDA_NATIVE_VERSION_TEXT);
}

/*
 * The kind of one image: "elf" for a cubin and "ptx" for PTX.  The text
 * between the start of the field and the comma that ends it names it.
 */
static void
parse_image_kind(const char *start, const char *end,
    struct image_spec *image)
{
	size_t length = (size_t)(end - start);

	if (length == 3 && memcmp(start, "elf", 3) == 0)
		image->kind = CNFATBIN_KIND_CUBIN;
	else if (length == 3 && memcmp(start, "ptx", 3) == 0)
		image->kind = CNFATBIN_KIND_PTX;
	else {
		char kind[16];
		char escaped[CNTOOL_ESCAPED_MAX];

		if (length >= sizeof(kind))
			length = sizeof(kind) - 1;
		memcpy(kind, start, length);
		kind[length] = '\0';
		cntool_fail(program_name, 2, "unsupported image kind: %s",
		    cntool_escape_text(escaped, sizeof(escaped), kind));
	}
}

/*
 * The SM of one image: a decimal number with an optional a or f suffix.
 */
static void
parse_image_sm(const char *start, const char *end, struct image_spec *image)
{
	char text[64];
	char escaped[CNTOOL_ESCAPED_MAX];
	const char *p = start;
	size_t length = (size_t)(end - start);

	/* The text of the field is copied out and escaped before it goes in
	 * a diagnostic. */
	if (length >= sizeof(text))
		length = sizeof(text) - 1;
	memcpy(text, start, length);
	text[length] = '\0';
	cntool_escape_text(escaped, sizeof(escaped), text);

	image->sm = 0;
	/* Time: O(digits).  Space: O(1). */
	while (p < end && *p >= '0' && *p <= '9') {
		if (image->sm > 100000)
			cntool_fail(program_name, 2,
			    "image sm must be a decimal number: %s", escaped);
		image->sm = image->sm * 10 + (unsigned int)(*p - '0');
		p++;
	}
	if (p == start)
		cntool_fail(program_name, 2,
		    "image sm must be a decimal number: %s", escaped);
	image->suffix = 0;
	if (p < end && (*p == 'a' || *p == 'f')) {
		image->suffix = *p;
		p++;
	}
	if (p != end)
		cntool_fail(program_name, 2,
		    "image sm must be a decimal number: %s", escaped);
}

/* The input file of one image. */
static void
parse_image_file(const char *spec, const char *rest, struct image_spec *image)
{
	const char *file;
	char escaped[CNTOOL_ESCAPED_MAX];

	if (strncmp(rest, "file=", 5) != 0)
		cntool_fail(program_name, 2, "malformed --image3: %s",
		    cntool_escape_text(escaped, sizeof(escaped), spec));
	file = rest + 5;
	if (*file == '\0')
		cntool_fail(program_name, 2, "image file is empty");
	image->file = strdup(file);
	if (image->file == NULL)
		cntool_fail(program_name, 1, "host memory exhausted");
}

/*
 * Parse one --image3 argument: kind=KIND,sm=SM,file=INPUT.  The file name
 * may hold commas; the three fields are the first three comma separated
 * parts, and the file name is everything after the first ",file=".
 */
static void
parse_image(const char *spec, struct image_spec *image)
{
	char escaped[CNTOOL_ESCAPED_MAX];
	const char *rest = spec;
	const char *comma;

	if (strncmp(rest, "kind=", 5) != 0)
		cntool_fail(program_name, 2, "malformed --image3: %s",
		    cntool_escape_text(escaped, sizeof(escaped), spec));
	rest += 5;
	comma = strchr(rest, ',');
	if (comma == NULL)
		cntool_fail(program_name, 2, "malformed --image3: %s",
		    cntool_escape_text(escaped, sizeof(escaped), spec));
	parse_image_kind(rest, comma, image);
	rest = comma + 1;
	if (strncmp(rest, "sm=", 3) != 0)
		cntool_fail(program_name, 2, "malformed --image3: %s",
		    cntool_escape_text(escaped, sizeof(escaped), spec));
	rest += 3;
	comma = strchr(rest, ',');
	if (comma == NULL)
		cntool_fail(program_name, 2, "malformed --image3: %s",
		    cntool_escape_text(escaped, sizeof(escaped), spec));
	parse_image_sm(rest, comma, image);
	parse_image_file(spec, comma + 1, image);
}

/* The trace file, or NULL when tracing is off. */
static const char *
trace_path(void)
{
	const char *value = getenv("CUDA_NATIVE_TRACE");

	if (value != NULL && *value != '\0')
		return value;
	value = getenv("CUDA_NATIVE_TOOL_TRACE");
	if (value != NULL && *value != '\0')
		return value;
	return NULL;
}

static void
write_trace(const char *create, const struct image_spec *images, size_t count)
{
	const char *path = trace_path();
	char escaped[CNTOOL_ESCAPED_MAX];
	FILE *stream;
	size_t i;

	if (path == NULL)
		return;
	stream = fopen(path, "a");
	if (stream == NULL)
		cntool_fail(program_name, 1, "cannot append trace: %s",
		    cntool_escape_text(escaped, sizeof(escaped), path));
	fputs("{\"tool\":\"nvfatbin\",\"schema\":1,\"output\":", stream);
	cntool_json_escape(stream, create);
	fputs(",\"images\":[", stream);
	/* Time: O(images).  Space: O(1). */
	for (i = 0; i < count; i++) {
		if (i > 0)
			fputc(',', stream);
		fputs("{\"kind\":", stream);
		cntool_json_escape(stream,
		    images[i].kind == CNFATBIN_KIND_PTX ? "ptx" : "elf");
		fprintf(stream, ",\"sm\":%u", images[i].sm);
		/* The architecture of the image, with its suffix: the same
		 * name the container records. */
		fputs(",\"arch\":\"sm_", stream);
		fprintf(stream, "%u", images[i].sm);
		if (images[i].suffix == 'a' || images[i].suffix == 'f')
			fputc(images[i].suffix, stream);
		fputc('"', stream);
		fputs(",\"file\":", stream);
		cntool_json_escape(stream, images[i].file);
		fputc('}', stream);
	}
	fputs("],\"stub\":true}\n", stream);
	if (fclose(stream) != 0)
		cntool_fail(program_name, 1, "cannot append trace: %s",
		    cntool_escape_text(escaped, sizeof(escaped), path));
}

/* What the command line asked for. */
struct nvfatbin_options {
	struct image_spec *images;
	size_t count;
	char *create;
};

/*
 * Read the command line.  Returns 0 when there is work to do and 1 when
 * the tool has already answered, as it does for --help.
 */
static int
parse_arguments(int argc, char **argv, struct nvfatbin_options *options)
{
	int argi;

	/* Time: O(arguments).  Space: O(arguments). */
	for (argi = 1; argi < argc; argi++) {
		const char *arg = argv[argi];

		if (strcmp(arg, "-h") == 0 || strcmp(arg, "--help") == 0) {
			usage();
			return 1;
		}
		if (strcmp(arg, "-64") == 0 || strcmp(arg, "-g") == 0)
			continue;
		if (strcmp(arg, "--create") == 0) {
			if (argi + 1 >= argc)
				cntool_fail(program_name, 2,
				    "option requires an argument: %s", arg);
			free(options->create);
			options->create = strdup(argv[++argi]);
			if (options->create == NULL)
				cntool_fail(program_name, 1, "host memory exhausted");
			continue;
		}
		if (strncmp(arg, "--create=", 9) == 0) {
			free(options->create);
			options->create = strdup(arg + 9);
			if (options->create == NULL)
				cntool_fail(program_name, 1, "host memory exhausted");
			continue;
		}
		if (strncmp(arg, "--image3=", 9) == 0) {
			struct image_spec *grown;

			validate_argument(arg, "image specifications");
			grown = realloc(options->images,
			    (options->count + 1) * sizeof(*options->images));
			if (grown == NULL)
				cntool_fail(program_name, 1, "host memory exhausted");
			options->images = grown;
			memset(&options->images[options->count], 0,
			    sizeof(options->images[options->count]));
			parse_image(arg + 9, &options->images[options->count]);
			options->count++;
			continue;
		}
		if (arg[0] == '-')
			unsupported_option(arg);
		unexpected_argument(arg, "images are given with --image3=");
	}
	return 0;
}

/* The output must not be a directory. */
static void
check_output_path(const char *create)
{
	char escaped[CNTOOL_ESCAPED_MAX];
	struct stat st;

	if (stat(create, &st) == 0 && S_ISDIR(st.st_mode))
		cntool_fail(program_name, 1, "output is a directory: %s",
		    cntool_escape_text(escaped, sizeof(escaped), create));
}

/* The directory the output goes in must exist. */
static void
check_output_directory(const char *create)
{
	char escaped[CNTOOL_ESCAPED_MAX];
	char *parent = strdup(create);
	char *slash;
	struct stat st;

	if (parent == NULL)
		cntool_fail(program_name, 1, "host memory exhausted");
	slash = strrchr(parent, '/');
	if (slash == NULL) {
		free(parent);
		parent = strdup(".");
		if (parent == NULL)
			cntool_fail(program_name, 1, "host memory exhausted");
	} else if (slash == parent)
		parent[1] = '\0';
	else
		*slash = '\0';
	if (stat(parent, &st) != 0 || !S_ISDIR(st.st_mode))
		cntool_fail(program_name, 1, "output directory does not exist: %s",
		    cntool_escape_text(escaped, sizeof(escaped), parent));
	free(parent);
}

/*
 * Read every image and remember what the writer needs to know about it.
 */
static void
load_images(struct image_spec *images, size_t count, uint8_t **payloads,
    struct cnfatbin_input *inputs)
{
	char escaped[CNTOOL_ESCAPED_MAX];
	size_t i;

	/* Time: O(images).  Space: O(total image bytes). */
	for (i = 0; i < count; i++) {
		size_t size = 0;
		uint8_t *data = NULL;
		enum cntool_read_result reason;

		reason = cntool_read_file(images[i].file, &data, &size,
		    CNTOOL_MAX_FILE_SIZE);
		if (reason != CNTOOL_READ_OK)
			cntool_fail(program_name, 1, "cannot read %s: %s",
			    cntool_escape_text(escaped, sizeof(escaped),
			    images[i].file),
			    cntool_read_reason(reason, CNTOOL_MAX_FILE_SIZE));
		if (images[i].kind == CNFATBIN_KIND_CUBIN) {
			static const char magic[] = CNFATBIN_CUBIN_MAGIC;
			size_t magic_len = sizeof(magic) - 1;

			if (size < magic_len ||
			    memcmp(data, magic, magic_len) != 0) {
				free(data);
				cntool_fail(program_name, 1,
				    "not a cuda-native cubin: %s",
				    cntool_escape_text(escaped, sizeof(escaped),
				    images[i].file));
			}
		}
		payloads[i] = data;
		inputs[i].kind = images[i].kind;
		inputs[i].sm = images[i].sm;
		inputs[i].suffix = images[i].suffix;
		inputs[i].data = data;
		inputs[i].size = size;
	}
}

/*
 * The output is built privately in its directory and renamed into place,
 * so a failed run leaves nothing behind.
 *
 * The temporary file has a short name of its own: the name of the output
 * is not made longer by it, so an output whose name is as long as the
 * filesystem allows can still be written.
 */
static void
write_container_file(const char *create, const uint8_t *container,
    size_t container_size)
{
	char escaped[CNTOOL_ESCAPED_MAX];
	char *temporary = NULL;
	char *directory = NULL;
	const char *slash;
	size_t namelen;
	int fd;

	slash = strrchr(create, '/');
	if (slash == NULL) {
		directory = strdup(".");
		if (directory == NULL)
			cntool_fail(program_name, 1, "host memory exhausted");
	} else {
		size_t length = (size_t)(slash - create);

		directory = malloc(length + 1);
		if (directory == NULL)
			cntool_fail(program_name, 1, "host memory exhausted");
		if (length == 0)
			directory[0] = '/';
		else {
			memcpy(directory, create, length);
			directory[length] = '\0';
		}
	}
	namelen = strlen(directory) + sizeof("/.nvfatbin.XXXXXX");
	temporary = malloc(namelen);
	if (temporary == NULL) {
		free(directory);
		cntool_fail(program_name, 1, "host memory exhausted");
	}
	snprintf(temporary, namelen, "%s/.nvfatbin.XXXXXX", directory);
	free(directory);
	fd = mkstemp(temporary);
	if (fd < 0) {
		free(temporary);
		cntool_fail(program_name, 1, "cannot create output: %s",
		    cntool_escape_text(escaped, sizeof(escaped), create));
	}
	/* Time: O(container size).  Space: O(1). */
	{
		size_t written = 0;

		while (written < container_size) {
			ssize_t n = write(fd, container + written,
			    container_size - written);

			if (n < 0) {
				if (errno == EINTR)
					continue;
				close(fd);
				unlink(temporary);
				cntool_fail(program_name, 1,
				    "cannot write output: %s",
				    cntool_escape_text(escaped, sizeof(escaped),
				    create));
			}
			written += (size_t)n;
		}
	}
	if (fchmod(fd, 0644) != 0) {
		close(fd);
		unlink(temporary);
		cntool_fail(program_name, 1, "cannot set output permissions: %s",
		    cntool_escape_text(escaped, sizeof(escaped), create));
	}
	if (close(fd) != 0) {
		unlink(temporary);
		cntool_fail(program_name, 1, "cannot write output: %s",
		    cntool_escape_text(escaped, sizeof(escaped), create));
	}
	if (rename(temporary, create) != 0) {
		unlink(temporary);
		cntool_fail(program_name, 1, "cannot write output: %s",
		    cntool_escape_text(escaped, sizeof(escaped), create));
	}
	free(temporary);
}

/* Give back everything the images took. */
static void
free_images(struct image_spec *images, size_t count, uint8_t **payloads)
{
	size_t i;

	/* Time: O(images).  Space: O(1). */
	for (i = 0; i < count; i++) {
		free(payloads[i]);
		free(images[i].file);
	}
	free(payloads);
	free(images);
}

int
main(int argc, char **argv)
{
	struct nvfatbin_options options;
	struct cnfatbin_input *inputs = NULL;
	uint8_t **payloads = NULL;
	uint8_t *container = NULL;
	size_t container_size = 0;
	enum cnfatbin_error err;

	/* The name the program was invoked as is set before any message is
	 * made: the version, the usage line and every diagnostic carry it. */
	set_program_name(argv[0]);

	if (argc > 1 && strcmp(argv[1], "--version") == 0) {
		/* The version takes no operand: --version, or --version
		 * --json.  Every other form is a usage problem. */
		if (argc == 2) {
			show_version(0);
			return 0;
		}
		if (argc == 3 && strcmp(argv[2], "--json") == 0) {
			show_version(1);
			return 0;
		}
		if (argc > 3 && strcmp(argv[2], "--json") == 0)
			unexpected_argument(argv[3],
			    "only --json may follow --version");
		if (argv[2][0] == '-')
			unsupported_option(argv[2]);
		unexpected_argument(argv[2],
		    "only --json may follow --version");
	}

	memset(&options, 0, sizeof(options));
	if (parse_arguments(argc, argv, &options))
		return 0;

	if (options.create == NULL)
		cntool_fail(program_name, 2, "--create is required");
	if (options.create[0] == '\0')
		cntool_fail(program_name, 2,
		    "--create requires a file name");
	if (options.count == 0)
		cntool_fail(program_name, 2, "at least one --image3 is required");
	validate_argument(options.create, "the output path");
	check_output_path(options.create);
	check_output_directory(options.create);

	payloads = calloc(options.count, sizeof(*payloads));
	inputs = calloc(options.count, sizeof(*inputs));
	if (payloads == NULL || inputs == NULL)
		cntool_fail(program_name, 1, "host memory exhausted");

	load_images(options.images, options.count, payloads, inputs);

	err = cnfatbin_write(inputs, options.count, &container, &container_size);
	if (err != CNFATBIN_OK)
		cntool_fail(program_name, 1, "%s", cnfatbin_strerror(err));

	write_container_file(options.create, container, container_size);

	write_trace(options.create, options.images, options.count);

	free_images(options.images, options.count, payloads);
	free(inputs);
	free(options.create);
	cnfatbin_buffer_free(container, container_size);
	return 0;
}

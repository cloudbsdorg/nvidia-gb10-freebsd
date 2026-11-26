/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * cntool.c - the parts of the cuda-native command line tools that both of
 * them share: the diagnostic printer, the JSON string escaper, the text
 * escaper, the file reader and the file writer.
 */

#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "cntool.h"

void
cntool_fail(const char *tool, int status, const char *fmt, ...)
{
	va_list ap;

	fprintf(stderr, "%s: ", tool);
	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
	fputc('\n', stderr);
	exit(status);
}

/*
 * How long is the UTF-8 character that starts at p, and is it one?  A
 * character of one byte is any byte below 0x80.  A character of more bytes
 * starts with a lead byte and continues with the bytes the lead byte
 * allows.  A byte that starts no character, a character whose bytes are
 * not there, and a character whose bytes are not the ones the lead byte
 * allows, all have no length: they are not characters.
 *
 * The ranges are the ones Unicode gives: no overlong forms, no surrogate
 * halves, nothing above U+10FFFF.
 */
static size_t
utf8_length(const unsigned char *p, size_t left)
{
	unsigned int need, low, high, i;

	if (p[0] < 0x80)
		return 1;
	if (p[0] >= 0xc2 && p[0] <= 0xdf) {
		need = 1;
		low = 0x80;
		high = 0xbf;
	} else if (p[0] == 0xe0) {
		need = 2;
		low = 0xa0;
		high = 0xbf;
	} else if ((p[0] >= 0xe1 && p[0] <= 0xec) ||
	    (p[0] >= 0xee && p[0] <= 0xef)) {
		need = 2;
		low = 0x80;
		high = 0xbf;
	} else if (p[0] == 0xed) {
		need = 2;
		low = 0x80;
		high = 0x9f;
	} else if (p[0] == 0xf0) {
		need = 3;
		low = 0x90;
		high = 0xbf;
	} else if (p[0] >= 0xf1 && p[0] <= 0xf3) {
		need = 3;
		low = 0x80;
		high = 0xbf;
	} else if (p[0] == 0xf4) {
		need = 3;
		low = 0x80;
		high = 0x8f;
	} else
		return 0;
	if (left < need + 1)
		return 0;
	/* Time: O(bytes of the character).  Space: O(1). */
	for (i = 0; i < need; i++) {
		unsigned int byte = p[1 + i];

		if (byte < low || byte > high)
			return 0;
		low = 0x80;
		high = 0xbf;
	}
	return need + 1;
}

/*
 * Write one string as a JSON string, with the quotes around it.  The bytes
 * that are not a character are written as the replacement character, so
 * the document is always valid UTF-8 and every parser can read it.
 */
void
cntool_json_escape(FILE *stream, const char *s)
{
	const unsigned char *p = (const unsigned char *)s;
	size_t left = strlen(s);

	fputc('"', stream);
	/* Time: O(string bytes).  Space: O(1). */
	while (left > 0) {
		size_t length = utf8_length(p, left);

		if (length == 0) {
			/* Not a character: the replacement character. */
			fputs("\\ufffd", stream);
			p++;
			left--;
			continue;
		}
		switch (p[0]) {
		case '"':
			fputs("\\\"", stream);
			break;
		case '\\':
			fputs("\\\\", stream);
			break;
		case '\t':
			fputs("\\t", stream);
			break;
		default:
			if (p[0] < 0x20)
				fprintf(stream, "\\u%04x", (unsigned int)p[0]);
			else
				fwrite(p, 1, length, stream);
			break;
		}
		p += length;
		left -= length;
	}
	fputc('"', stream);
}

/*
 * One unit of the escaped form of a string: a control byte, or a byte that
 * is not a UTF-8 character, becomes a four byte \xNN escape, and every
 * other byte stays as it is.  One escaper serves the text output and the
 * diagnostics, so the two cannot disagree about what a control byte looks
 * like.  The unit is written whole: an escape is never cut in half.
 */
struct escape_unit {
	char text[4];
	size_t length;		/* the bytes of the escaped form */
	size_t source;		/* the bytes of the string it is */
};

static int
next_unit(const unsigned char *p, size_t left, struct escape_unit *unit)
{
	size_t character = utf8_length(p, left);

	if (character == 0 || p[0] < 0x20 || p[0] == 0x7f) {
		static const char digits[] = "0123456789abcdef";

		unit->text[0] = '\\';
		unit->text[1] = 'x';
		unit->text[2] = digits[(p[0] >> 4) & 0x0f];
		unit->text[3] = digits[p[0] & 0x0f];
		unit->length = 4;
		unit->source = 1;
		return 1;
	}
	memcpy(unit->text, p, character);
	unit->length = character;
	unit->source = character;
	return 1;
}

/*
 * The length of the escaped form of a string: four bytes for every byte
 * that is escaped, and as many bytes as the character holds for every
 * byte that is not.
 */
static size_t
escaped_length(const char *data, size_t length)
{
	const unsigned char *p = (const unsigned char *)data;
	size_t left = length;
	size_t total = 0;

	while (left > 0) {
		struct escape_unit unit;

		if (!next_unit(p, left, &unit))
			break;
		if (total > SIZE_MAX - unit.length)
			return SIZE_MAX;
		total += unit.length;
		p += unit.source;
		left -= unit.source;
	}
	return total;
}

/*
 * Write the escaped form of a string into a buffer, and say how many bytes
 * of the string were written.  The escapes are never cut in half: a string
 * that does not fit stops at the end of an escape.
 */
static size_t
escape_to_buffer(char *buffer, size_t room, const char *data, size_t length,
    size_t *consumed)
{
	const unsigned char *p = (const unsigned char *)data;
	size_t left = length;
	size_t used = 0;

	while (left > 0) {
		struct escape_unit unit;

		if (!next_unit(p, left, &unit))
			break;
		if (unit.length > room - used)
			break;
		memcpy(buffer + used, unit.text, unit.length);
		used += unit.length;
		p += unit.source;
		left -= unit.source;
	}
	*consumed = length - left;
	return used;
}

/*
 * Write the escaped form of a string to a stream.
 */
static void
escape_to_stream(FILE *stream, const char *data, size_t length)
{
	const unsigned char *p = (const unsigned char *)data;
	size_t left = length;

	while (left > 0) {
		struct escape_unit unit;

		if (!next_unit(p, left, &unit))
			break;
		fwrite(unit.text, 1, unit.length, stream);
		p += unit.source;
		left -= unit.source;
	}
}

/*
 * Write one string as plain text, with every control byte and every byte
 * that is not a character shown as a \xNN escape, so that no raw control
 * byte reaches the terminal and one member is one line.
 */
void
cntool_write_text(FILE *stream, const char *s)
{
	escape_to_stream(stream, s, strlen(s));
}

/*
 * The room the marker that says how much was left out needs.  The count is
 * a size, so it is at most twenty digits, and the marker is at most
 * thirty five bytes.
 */
#define CNTOOL_OMITTED_ROOM 40

char *
cntool_escape_bytes(char *buffer, size_t buffer_size, const char *data,
    size_t length)
{
	size_t room;
	size_t needed;
	size_t used;
	size_t consumed;

	if (buffer == NULL || buffer_size == 0)
		return buffer;
	if (data == NULL) {
		buffer[0] = '\0';
		return buffer;
	}
	room = buffer_size - 1;
	needed = escaped_length(data, length);
	if (needed <= room) {
		used = escape_to_buffer(buffer, room, data, length, &consumed);
		buffer[used] = '\0';
		return buffer;
	}
	/* The string does not fit: as much of it as fits is written, and
	 * the marker says how many bytes were left out.  The marker has
	 * room of its own, so the string is cut a little early. */
	if (room > CNTOOL_OMITTED_ROOM) {
		used = escape_to_buffer(buffer, room - CNTOOL_OMITTED_ROOM,
		    data, length, &consumed);
		snprintf(buffer + used, room - used + 1, "<%zu bytes omitted>",
		    length - consumed);
		used += strlen(buffer + used);
	} else
		used = escape_to_buffer(buffer, room, data, length, &consumed);
	buffer[used] = '\0';
	return buffer;
}

char *
cntool_escape_text(char *buffer, size_t buffer_size, const char *s)
{
	if (s == NULL)
		return cntool_escape_bytes(buffer, buffer_size, "", 0);
	return cntool_escape_bytes(buffer, buffer_size, s, strlen(s));
}

/*
 * The cause of a failed read, in words.  One table, so the cause and its
 * words cannot disagree, and one entry per code, so a code cannot lose its
 * words.  The cause that names the limit is not in the table: it is made
 * where it is used, because the limit is the caller's.
 */
static const char *const read_reasons[] = {
	[CNTOOL_READ_OK] = "the file was read",
	[CNTOOL_READ_NOENT] = "no such file",
	[CNTOOL_READ_PERM] = "permission denied",
	[CNTOOL_READ_ISDIR] = "input is a directory",
	[CNTOOL_READ_EMPTY] = "input is empty",
	[CNTOOL_READ_FAILED] = "read failed",
	[CNTOOL_READ_NOMEM] = "host memory exhausted"
};

/*
 * The cause of a failed read, in words, in the buffer the caller owns.  The
 * limit is the one the caller asked for: the message that names it says how
 * large the input may be.  The reason is written into the caller's buffer,
 * so two reasons are two strings and neither of them changes under the
 * other.  Returns the buffer.
 */
char *
cntool_read_reason(char *buffer, size_t size, enum cntool_read_result result,
    size_t limit)
{
	if (buffer == NULL || size == 0)
		return buffer;
	if (result == CNTOOL_READ_TOO_LARGE) {
		snprintf(buffer, size,
		    "the input is larger than the %zu byte limit", limit);
		return buffer;
	}
	if ((size_t)result < sizeof(read_reasons) / sizeof(read_reasons[0]) &&
	    read_reasons[result] != NULL) {
		snprintf(buffer, size, "%s", read_reasons[result]);
		return buffer;
	}
	snprintf(buffer, size, "read failed");
	return buffer;
}

/*
 * Read a whole file into memory, up to the limit the caller gives.  The
 * caller frees the buffer.  On failure the buffer stays NULL and the
 * reason says why, so the caller can tell a missing file from a
 * directory, an empty file and a failed read.  The size is checked before
 * anything is allocated, so a file that is too large costs nothing.
 */
enum cntool_read_result
cntool_read_file(const char *path, uint8_t **data, size_t *size, size_t limit)
{
	struct stat st;
	uint8_t *buffer;
	size_t got = 0;
	int fd;

	*data = NULL;
	*size = 0;
	fd = open(path, O_RDONLY);
	if (fd < 0) {
		if (errno == ENOENT)
			return CNTOOL_READ_NOENT;
		if (errno == EACCES || errno == EPERM)
			return CNTOOL_READ_PERM;
		return CNTOOL_READ_FAILED;
	}
	if (fstat(fd, &st) != 0) {
		close(fd);
		return CNTOOL_READ_FAILED;
	}
	if (S_ISDIR(st.st_mode)) {
		close(fd);
		return CNTOOL_READ_ISDIR;
	}
	if (!S_ISREG(st.st_mode)) {
		close(fd);
		return CNTOOL_READ_FAILED;
	}
	if (st.st_size == 0) {
		close(fd);
		return CNTOOL_READ_EMPTY;
	}
	/* The limit is checked before the buffer is allocated: a file that
	 * is too large is refused without the host having to hold it. */
	if ((uintmax_t)st.st_size > (uintmax_t)limit) {
		close(fd);
		return CNTOOL_READ_TOO_LARGE;
	}
	buffer = malloc((size_t)st.st_size);
	if (buffer == NULL) {
		close(fd);
		return CNTOOL_READ_NOMEM;
	}
	/* Time: O(file size).  Space: O(file size). */
	while (got < (size_t)st.st_size) {
		ssize_t n = read(fd, buffer + got, (size_t)st.st_size - got);

		if (n < 0) {
			if (errno == EINTR)
				continue;
			free(buffer);
			close(fd);
			return CNTOOL_READ_FAILED;
		}
		if (n == 0)
			break;
		got += (size_t)n;
	}
	close(fd);
	if (got != (size_t)st.st_size) {
		free(buffer);
		return CNTOOL_READ_FAILED;
	}
	*data = buffer;
	*size = got;
	return CNTOOL_READ_OK;
}

/* The cause of a failed write, in words. */
const char *
cntool_write_reason(enum cntool_write_result result)
{
	switch (result) {
	case CNTOOL_WRITE_OK:
		return "the file was written";
	case CNTOOL_WRITE_NOENT:
		return "no such directory";
	case CNTOOL_WRITE_PERM:
		return "permission denied";
	case CNTOOL_WRITE_FAILED:
		return "the file could not be written";
	}
	return "the file could not be written";
}

/*
 * Split a path into the directory the file is in and the name of the file
 * in it.  A path with no slash in it is in the current directory, and a
 * path that starts with a slash is in the root directory.  Returns 0 when
 * the path does not fit in the room the caller has.
 */
static int
split_path(const char *path, char *directory, size_t directory_size,
    char *name, size_t name_size)
{
	const char *slash;
	size_t length;

	slash = strrchr(path, '/');
	if (slash == NULL) {
		if (directory_size < 2 || strlen(path) + 1 > name_size)
			return 0;
		strcpy(directory, ".");
		strcpy(name, path);
		return 1;
	}
	length = (size_t)(slash - path);
	if (length == 0)
		length = 1;
	if (length + 1 > directory_size || strlen(slash + 1) + 1 > name_size)
		return 0;
	memcpy(directory, path, length);
	directory[length] = '\0';
	strcpy(name, slash + 1);
	return 1;
}

/*
 * A test hook: with GB10_TEST_HOOKS=1 and CUDA_NATIVE_TEST_PARENT_SWAP
 * set to a directory, the directory the output goes in is replaced by a
 * symlink to that directory, after the directory was opened and before the
 * file is made.  The file must still land in the directory that was
 * opened, and the directory the symlink names must not be written at all.
 * The directory that was opened is renamed out of the way, so the test can
 * find it again.
 */
static void
swap_parent_for_test(struct cntool_output *output)
{
	const char *hooks = getenv("GB10_TEST_HOOKS");
	const char *target = getenv("CUDA_NATIVE_TEST_PARENT_SWAP");
	char saved[PATH_MAX + 16];

	if (hooks == NULL || strcmp(hooks, "1") != 0)
		return;
	if (target == NULL || *target == '\0')
		return;
	if (snprintf(saved, sizeof(saved), "%s.swapped", output->directory) >=
	    (int)sizeof(saved))
		return;
	if (rename(output->directory, saved) != 0)
		return;
	if (symlink(target, output->directory) != 0)
		(void)rename(saved, output->directory);
}

/*
 * The name the file is made under first: a name of its own in the
 * directory, so that a file that is not finished is never seen under the
 * name the caller asked for.  The name is made with O_EXCL, so it is
 * never the file of another run.
 */
#define CNTOOL_TEMPORARY ".cntool.tmp"

static int
make_temporary(char *name, size_t size, int directory_fd)
{
	unsigned int attempt;

	for (attempt = 0; attempt < 128; attempt++) {
		int fd;

		snprintf(name, size, "%s.%ld.%u", CNTOOL_TEMPORARY,
		    (long)getpid(), attempt);
		fd = openat(directory_fd, name,
		    O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
		if (fd >= 0)
			return fd;
		if (errno != EEXIST)
			return -1;
	}
	return -1;
}

enum cntool_write_result
cntool_output_open(const char *path, struct cntool_output *output)
{
	int fd;

	if (output == NULL)
		return CNTOOL_WRITE_FAILED;
	output->directory_fd = -1;
	output->directory[0] = '\0';
	output->name[0] = '\0';
	if (path == NULL || *path == '\0')
		return CNTOOL_WRITE_NOENT;
	if (!split_path(path, output->directory, sizeof(output->directory),
	    output->name, sizeof(output->name)))
		return CNTOOL_WRITE_NOENT;
	/* The name of the file must be a name: not empty, and not the
	 * directory itself. */
	if (output->name[0] == '\0' || strcmp(output->name, ".") == 0 ||
	    strcmp(output->name, "..") == 0)
		return CNTOOL_WRITE_NOENT;
	/* The directory is opened once and stays open: the file is
	 * written inside the directory that was opened, so a directory
	 * that is replaced after this cannot move the write. */
	fd = open(output->directory, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
	if (fd < 0) {
		if (errno == ENOENT || errno == ENOTDIR)
			return CNTOOL_WRITE_NOENT;
		if (errno == EACCES || errno == EPERM)
			return CNTOOL_WRITE_PERM;
		return CNTOOL_WRITE_FAILED;
	}
	output->directory_fd = fd;
	return CNTOOL_WRITE_OK;
}

enum cntool_write_result
cntool_output_write(struct cntool_output *output, const void *data,
    size_t size, unsigned int mode)
{
	const uint8_t *bytes = (const uint8_t *)data;
	char temporary[64];
	size_t written = 0;
	int fd;

	if (output == NULL || output->directory_fd < 0)
		return CNTOOL_WRITE_FAILED;
	/* The test hook runs between the opening of the directory and the
	 * making of the file. */
	swap_parent_for_test(output);
	fd = make_temporary(temporary, sizeof(temporary),
	    output->directory_fd);
	if (fd < 0) {
		if (errno == EACCES || errno == EPERM)
			return CNTOOL_WRITE_PERM;
		return CNTOOL_WRITE_FAILED;
	}
	/* Time: O(bytes).  Space: O(1). */
	while (written < size) {
		ssize_t n = write(fd, bytes + written, size - written);

		if (n < 0) {
			if (errno == EINTR)
				continue;
			close(fd);
			unlinkat(output->directory_fd, temporary, 0);
			return CNTOOL_WRITE_FAILED;
		}
		if (n == 0)
			break;
		written += (size_t)n;
	}
	if (written != size) {
		close(fd);
		unlinkat(output->directory_fd, temporary, 0);
		return CNTOOL_WRITE_FAILED;
	}
	if (fchmod(fd, (mode_t)mode) != 0) {
		close(fd);
		unlinkat(output->directory_fd, temporary, 0);
		return CNTOOL_WRITE_FAILED;
	}
	if (close(fd) != 0) {
		unlinkat(output->directory_fd, temporary, 0);
		return CNTOOL_WRITE_FAILED;
	}
	if (renameat(output->directory_fd, temporary, output->directory_fd,
	    output->name) != 0) {
		unlinkat(output->directory_fd, temporary, 0);
		return CNTOOL_WRITE_FAILED;
	}
	return CNTOOL_WRITE_OK;
}

void
cntool_output_close(struct cntool_output *output)
{
	if (output == NULL)
		return;
	if (output->directory_fd >= 0)
		close(output->directory_fd);
	output->directory_fd = -1;
}

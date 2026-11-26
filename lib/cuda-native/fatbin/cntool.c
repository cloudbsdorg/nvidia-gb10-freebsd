/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * cntool.c - the parts of the cuda-native command line tools that both of
 * them share: the diagnostic printer, the JSON string escaper, the text
 * escaper and the file reader.
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
 * that are not a character are written as the replacement character, so the
 * document is always valid UTF-8 and every parser can read it.
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
 * Write one string as plain text, with every control byte and every byte
 * that is not a character shown as a \xNN escape, so that no raw control
 * byte reaches the terminal and one member is one line.
 */
void
cntool_write_text(FILE *stream, const char *s)
{
	const unsigned char *p = (const unsigned char *)s;
	size_t left = strlen(s);

	/* Time: O(string bytes).  Space: O(1). */
	while (left > 0) {
		size_t length = utf8_length(p, left);

		if (length == 0 || p[0] < 0x20 || p[0] == 0x7f) {
			fprintf(stream, "\\x%02x", (unsigned int)p[0]);
			p++;
			left--;
			continue;
		}
		fwrite(p, 1, length, stream);
		p += length;
		left -= length;
	}
}

/*
 * The same escaping in a string of its own, for a diagnostic that has to
 * carry a path.  The caller frees it.  NULL when the host is out of memory.
 */
char *
cntool_escape_text(const char *s)
{
	char *buffer = NULL;
	size_t size = 0;
	FILE *stream;

	stream = open_memstream(&buffer, &size);
	if (stream == NULL)
		return NULL;
	cntool_write_text(stream, s);
	if (fclose(stream) != 0) {
		free(buffer);
		return NULL;
	}
	return buffer;
}

/* The cause of a failed read, in words. */
const char *
cntool_read_reason(enum cntool_read_result result)
{
	switch (result) {
	case CNTOOL_READ_OK:
		return "the file was read";
	case CNTOOL_READ_NOENT:
		return "no such file";
	case CNTOOL_READ_PERM:
		return "permission denied";
	case CNTOOL_READ_ISDIR:
		return "input is a directory";
	case CNTOOL_READ_EMPTY:
		return "input is empty";
	case CNTOOL_READ_FAILED:
		return "read failed";
	case CNTOOL_READ_NOMEM:
		return "host memory exhausted";
	}
	return "read failed";
}

/*
 * Read a whole file into memory.  The caller frees the buffer.  On failure
 * the buffer stays NULL and the reason says why, so the caller can tell a
 * missing file from a directory, an empty file and a failed read.
 */
enum cntool_read_result
cntool_read_file(const char *path, uint8_t **data, size_t *size)
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

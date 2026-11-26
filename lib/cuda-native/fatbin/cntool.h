/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * cntool.h - the parts of the cuda-native command line tools that both of
 * them share.
 *
 * nvfatbin(1) and cuda-objdump(1) say what went wrong the same way, read
 * files the same way, write files the same way, and escape the bytes they
 * print the same way.  That code lives here once, so the two tools cannot
 * drift apart and no copy of it sits in two files.
 */

#ifndef CNTOOL_H
#define CNTOOL_H

#include <limits.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <sys/param.h>

/*
 * The longest string a tool escapes in a diagnostic: a path or a command
 * line argument.  It is PATH_MAX bytes.
 */
#define CNTOOL_TEXT_MAX PATH_MAX

/*
 * The room one escaped string needs in a diagnostic.  Every byte of the
 * string becomes at most four bytes, so a string of CNTOOL_TEXT_MAX bytes
 * becomes 4 * CNTOOL_TEXT_MAX bytes, and the terminator needs one more.
 * A string that is longer than that is cut short, and the diagnostic says
 * how many bytes were left out.
 */
#define CNTOOL_ESCAPED_MAX (4 * CNTOOL_TEXT_MAX + 1)

/*
 * The largest file a tool reads.  A container is at most 16 MiB, but the
 * file may also be an ELF object that carries one, and an object of a
 * large CUDA translation unit is bigger than a container.  A file that is
 * larger than this is refused before anything is allocated for it.
 */
#define CNTOOL_MAX_FILE_SIZE (256u * 1024u * 1024u)

/*
 * Say what went wrong and stop: "tool: message" on stderr, then exit with
 * the given status.  The tool name is the one the user typed.
 */
void cntool_fail(const char *tool, int status, const char *fmt, ...)
#if defined(__GNUC__)
    __attribute__((format(printf, 3, 4), noreturn))
#endif
    ;

/*
 * Write one string as a JSON string, with the quotes around it.  The bytes
 * that are not a UTF-8 character are written as the replacement character
 * (\ufffd), so the document is always valid UTF-8 and every parser reads it.
 */
void cntool_json_escape(FILE *stream, const char *s);

/*
 * Write one string as plain text, with every control byte and every byte
 * that is not a UTF-8 character shown as a \xNN escape, so no raw control
 * byte reaches the terminal and one member stays one line.
 */
void cntool_write_text(FILE *stream, const char *s);

/*
 * The same escaping in a string of the caller's, for a diagnostic that has
 * to carry a path or an argument.  The buffer needs room for four bytes per
 * byte of the string; when it is too small the string is cut short at the
 * end of an escape, and the diagnostic says how many bytes were left out.
 * Returns the buffer.
 */
char *cntool_escape_text(char *buffer, size_t buffer_size, const char *s);

/*
 * The same escaping for a string whose length is known and whose bytes are
 * not a NUL terminated string: the bytes are escaped as they are, from the
 * first to the last, and none of them is left out before the others.  The
 * buffer needs room for four bytes per byte of the string; when it is too
 * small the string is cut short at the end of an escape, and the
 * diagnostic says how many bytes were left out.  Returns the buffer.
 */
char *cntool_escape_bytes(char *buffer, size_t buffer_size, const char *data,
    size_t length);

/* Why a file could not be read.  Every cause has its own name. */
enum cntool_read_result {
	CNTOOL_READ_OK = 0,
	CNTOOL_READ_NOENT,	/* there is no such file */
	CNTOOL_READ_PERM,	/* permission denied */
	CNTOOL_READ_ISDIR,	/* it is a directory */
	CNTOOL_READ_EMPTY,	/* it is empty */
	CNTOOL_READ_TOO_LARGE,	/* it is larger than the limit */
	CNTOOL_READ_FAILED,	/* the read failed */
	CNTOOL_READ_NOMEM	/* the host is out of memory */
};

/*
 * The room a reason needs: the longest reason is the one that names the
 * limit of a file, and a limit is a number of twenty digits.
 */
#define CNTOOL_REASON_MAX 96

/*
 * The cause of a failed read, in words.  The limit is the one the caller
 * asked for: the message that names it says how large the input may be.
 * The reason is written into the buffer the caller owns, so two reasons are
 * two strings and neither of them changes under the other.  Returns the
 * buffer.
 */
char *cntool_read_reason(char *buffer, size_t size,
    enum cntool_read_result result, size_t limit);

/*
 * Read a whole file into memory, up to the limit the caller gives.  The
 * caller frees the buffer.  On failure the buffer stays NULL and the
 * reason says why: the file is not there, the permission is refused, the
 * input is a directory, the input is empty, the input is larger than the
 * limit, the read failed, or the host is out of memory.  The size is
 * checked before anything is allocated, so a file that is too large costs
 * nothing.
 */
enum cntool_read_result
cntool_read_file(const char *path, uint8_t **data, size_t *size, size_t limit);

/* Why a file could not be written.  Every cause has its own name. */
enum cntool_write_result {
	CNTOOL_WRITE_OK = 0,
	CNTOOL_WRITE_NOENT,	/* the directory is not there */
	CNTOOL_WRITE_PERM,	/* the directory cannot be used */
	CNTOOL_WRITE_FAILED	/* the file could not be written */
};

/*
 * The cause of a failed write, in words.
 */
const char *cntool_write_reason(enum cntool_write_result result);

/*
 * The output of a tool: the directory it goes in and the name of the file
 * in it.  The directory is opened once and stays open, so that the file is
 * written in the directory that was opened and not in one that replaced
 * it.
 */
struct cntool_output {
	int directory_fd;
	char directory[PATH_MAX];
	char name[NAME_MAX + 1];
};

/*
 * Open the directory a file is to be written in, and split the path into
 * that directory and the name of the file in it.  The directory is opened
 * once, and the file is later written inside that open directory, so a
 * directory that is replaced after this cannot move the write somewhere
 * else.  The caller closes the output with cntool_output_close().
 */
enum cntool_write_result
cntool_output_open(const char *path, struct cntool_output *output);

/*
 * Write the bytes into the output.  The file is made under a name of its
 * own with O_CREAT|O_EXCL|O_NOFOLLOW inside the open directory, and it is
 * renamed into place with renameat(), so a file that is never finished is
 * never seen under the name the caller asked for.  On failure nothing is
 * left behind.
 */
enum cntool_write_result
cntool_output_write(struct cntool_output *output, const void *data,
    size_t size, unsigned int mode);

/*
 * Give the output back: the open directory is closed.
 */
void cntool_output_close(struct cntool_output *output);

#endif /* CNTOOL_H */

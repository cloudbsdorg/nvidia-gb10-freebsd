/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * cntool.h - the parts of the cuda-native command line tools that both of
 * them share.
 *
 * nvfatbin(1) and cuda-objdump(1) say what went wrong the same way, read
 * files the same way, and escape the bytes they print the same way.  That
 * code lives here once, so the two tools cannot drift apart and no copy of
 * it sits in two files.
 */

#ifndef CNTOOL_H
#define CNTOOL_H

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

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
 * The same escaping in a string of its own, for a diagnostic that has to
 * carry a path.  The caller frees it.  NULL when the host is out of memory.
 */
char *cntool_escape_text(const char *s);

/* Why a file could not be read.  Every cause has its own name. */
enum cntool_read_result {
	CNTOOL_READ_OK = 0,
	CNTOOL_READ_NOENT,	/* there is no such file */
	CNTOOL_READ_PERM,	/* permission denied */
	CNTOOL_READ_ISDIR,	/* it is a directory */
	CNTOOL_READ_EMPTY,	/* it is empty */
	CNTOOL_READ_FAILED,	/* the read failed */
	CNTOOL_READ_NOMEM	/* the host is out of memory */
};

/* The cause of a failed read, in words. */
const char *cntool_read_reason(enum cntool_read_result result);

/*
 * Read a whole file into memory.  The caller frees the buffer.  On failure
 * the buffer stays NULL and the reason says why: the file is not there,
 * the permission is refused, the input is a directory, the input is empty,
 * the read failed, or the host is out of memory.
 */
enum cntool_read_result
cntool_read_file(const char *path, uint8_t **data, size_t *size);

#endif /* CNTOOL_H */

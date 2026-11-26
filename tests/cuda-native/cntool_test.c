/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * cntool_test.c - the unit test for the parts of the cuda-native tools
 * that both of them share (Track #2427, slice 1).
 *
 * The escaper is the one place where the bytes of an untrusted string
 * become a diagnostic, so its bounds are tested here: the worst case that
 * fits in the buffer is not cut short, a string that does not fit says how
 * much of it was left out, and an escape is never cut in half.
 *
 * usage: cntool_test
 *
 * Exit status: the number of failed checks.
 */

#include <ctype.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "cntool.h"

static int passed = 0;
static int failures = 0;

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

/* How many \xNN escapes are in a string. */
static size_t
count_escapes(const char *text)
{
	size_t escapes = 0;
	size_t i;

	for (i = 0; text[i] != '\0'; i++) {
		if (text[i] == '\\' && text[i + 1] == 'x')
			escapes++;
	}
	return escapes;
}

/*
 * The worst case: every byte of a string of PATH_MAX bytes is a control
 * byte, so every byte of it becomes a four byte escape.  The buffer holds
 * exactly that many bytes, so nothing of the string may be left out.
 */
static void
check_worst_case(void)
{
	char source[CNTOOL_TEXT_MAX + 1];
	char buffer[CNTOOL_ESCAPED_MAX];
	size_t i;
	int good;

	for (i = 0; i < CNTOOL_TEXT_MAX; i++)
		source[i] = '\033';
	source[CNTOOL_TEXT_MAX] = '\0';
	memset(buffer, 0, sizeof(buffer));
	cntool_escape_text(buffer, sizeof(buffer), source);
	good = strlen(buffer) == 4 * CNTOOL_TEXT_MAX &&
	    count_escapes(buffer) == CNTOOL_TEXT_MAX &&
	    strstr(buffer, "omitted") == NULL;
	if (good)
		ok("the worst case that fits is escaped whole");
	else
		bad("the worst case that fits is escaped whole");
}

/*
 * A string that does not fit is cut short at the end of an escape, and the
 * diagnostic says how many bytes were left out.  The escape that is cut is
 * never half an escape.
 */
static void
check_truncation(void)
{
	char source[2 * CNTOOL_TEXT_MAX + 1];
	char buffer[CNTOOL_ESCAPED_MAX];
	size_t i;
	size_t length;
	int good;

	for (i = 0; i < 2 * CNTOOL_TEXT_MAX; i++)
		source[i] = '\033';
	source[2 * CNTOOL_TEXT_MAX] = '\0';
	memset(buffer, 0, sizeof(buffer));
	cntool_escape_text(buffer, sizeof(buffer), source);
	length = strlen(buffer);
	/* The marker is there, and the string before it is whole
	 * escapes. */
	good = strstr(buffer, "bytes omitted") != NULL &&
	    length > strlen("<0 bytes omitted>") &&
	    buffer[length - 1] != 'x';
	if (good)
		ok("a string that does not fit says what was left out");
	else
		bad("a string that does not fit says what was left out");
	/* The escapes before the marker are whole: every \x is followed
	 * by two hexadecimal digits. */
	good = 1;
	for (i = 0; buffer[i] != '\0'; i++) {
		if (buffer[i] != '\\')
			continue;
		if (buffer[i + 1] != 'x' ||
		    !isxdigit((unsigned char)buffer[i + 2]) ||
		    !isxdigit((unsigned char)buffer[i + 3])) {
			good = 0;
			break;
		}
	}
	if (good)
		ok("an escape is never cut in half");
	else
		bad("an escape is never cut in half");
}

/*
 * The escaping of a string whose length is known and whose bytes are not a
 * NUL terminated string: the bytes are escaped as they are, and the ones
 * after the first NUL are escaped too.
 */
static void
check_escape_bytes(void)
{
	char buffer[CNTOOL_ESCAPED_MAX];
	char source[8];
	int good;

	memcpy(source, "a\0b", 4);
	memset(buffer, 0, sizeof(buffer));
	cntool_escape_bytes(buffer, sizeof(buffer), source, 4);
	good = strcmp(buffer, "a\\x00b\\x00") == 0;
	if (good)
		ok("a string of a known length is escaped as it is");
	else
		bad("a string of a known length is escaped as it is");
}

/*
 * The buffer is the bound: the escaped form of a string never takes more
 * room than the buffer has, and the terminator is always there.
 */
static void
check_bound(void)
{
	char source[2 * CNTOOL_TEXT_MAX + 1];
	char buffer[64];
	size_t i;
	int good;

	for (i = 0; i < 2 * CNTOOL_TEXT_MAX; i++)
		source[i] = '\033';
	source[2 * CNTOOL_TEXT_MAX] = '\0';
	memset(buffer, 0, sizeof(buffer));
	cntool_escape_text(buffer, sizeof(buffer), source);
	good = strlen(buffer) < sizeof(buffer);
	if (good)
		ok("the escaped form never takes more room than the buffer");
	else
		bad("the escaped form never takes more room than the buffer");
}

/*
 * Two reasons for a file that is too large are two strings.  The reason
 * names the limit the caller asked for, so one reason must not change
 * under the other.
 */
static void
check_read_reasons(void)
{
	char first[CNTOOL_REASON_MAX];
	char second[CNTOOL_REASON_MAX];
	int good;

	cntool_read_reason(first, sizeof(first), CNTOOL_READ_TOO_LARGE, 10);
	cntool_read_reason(second, sizeof(second), CNTOOL_READ_TOO_LARGE, 20);
	good = strstr(first, "10 byte limit") != NULL &&
	    strstr(second, "20 byte limit") != NULL;
	if (good)
		ok("two reasons keep the limits they were made with");
	else
		bad("two reasons keep the limits they were made with");
	/* Every other cause has words of its own, in the caller's buffer. */
	cntool_read_reason(first, sizeof(first), CNTOOL_READ_NOENT, 10);
	good = strcmp(first, "no such file") == 0;
	if (good)
		ok("a cause that names no limit says what it is");
	else
		bad("a cause that names no limit says what it is");
}

int
main(void)
{
	check_worst_case();
	check_truncation();
	check_escape_bytes();
	check_bound();
	check_read_reasons();
	printf("%d passed, %d failed\n", passed, failures);
	return failures;
}

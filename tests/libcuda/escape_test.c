/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The escaping of the control code points, checked at the C level.  The
 * environment cannot carry a NUL, so the code points of the table are
 * checked here, one by one, against the one table of the tool.
 */
#include <stdio.h>
#include <string.h>

/* The escaping of the tool is its own source file: the test links it with
 * the tool, so that the table and the escaping that are under test are the
 * ones of the production code and not a copy of them. */
#include "escape.h"

#include "t.h"

/* The UTF-8 encoding of a code point, one to four bytes. */
static size_t
utf8_encode(uint32_t code, char *out)
{
	if (code < 0x80) {
		out[0] = (char)code;
		return (1);
	}
	if (code < 0x800) {
		out[0] = (char)(0xc0 | (code >> 6));
		out[1] = (char)(0x80 | (code & 0x3f));
		return (2);
	}
	if (code < 0x10000) {
		out[0] = (char)(0xe0 | (code >> 12));
		out[1] = (char)(0x80 | ((code >> 6) & 0x3f));
		out[2] = (char)(0x80 | (code & 0x3f));
		return (3);
	}
	out[0] = (char)(0xf0 | (code >> 18));
	out[1] = (char)(0x80 | ((code >> 12) & 0x3f));
	out[2] = (char)(0x80 | ((code >> 6) & 0x3f));
	out[3] = (char)(0x80 | (code & 0x3f));
	return (4);
}

/* A code point of the table is written as text: the escape of the code
 * point and nothing else. */
static void
check_control(uint32_t code)
{
	char text[8], escaped[32], expected[32];
	size_t length;

	length = utf8_encode(code, text);
	escaped_buffer(escaped, sizeof(escaped), text, length);
	snprintf(expected, sizeof(expected), "\\u%04x", (unsigned)code);
	CHECK_STR(escaped, expected);
}

/* A code point that is not in the table is copied through, byte for byte.
 * The replacement character is one of them: it is a valid code point, so
 * it is copied through like any other. */
static void
check_ordinary(uint32_t code)
{
	char text[8], escaped[32];
	size_t length;

	length = utf8_encode(code, text);
	escaped_buffer(escaped, sizeof(escaped), text, length);
	CHECK_EQ(strlen(escaped), length);
	CHECK(memcmp(escaped, text, length) == 0);
}

int
main(void)
{
	char text[2], escaped[32];
	size_t i;
	uint32_t code;

	/* The table is not empty, and it starts at the NUL: a table that
	 * lost a range would pass every other check of this test. */
	CHECK(control_range_count >= 8);
	CHECK_EQ(control_ranges[0].first, 0x0000);
	CHECK_EQ(control_ranges[0].last, 0x001f);
	/* Every code point of the table is escaped, the NUL included. */
	for (i = 0; i < control_range_count; i++) {
		for (code = control_ranges[i].first;
		    code <= control_ranges[i].last; code++)
			check_control(code);
	}
	/* The euro sign and the letter A with a diaeresis are ordinary
	 * characters: they are copied through unchanged. */
	check_ordinary(0x20ac);
	check_ordinary(0x00e9);
	/* The replacement character is a valid code point and it is not in
	 * the table: it is copied through, byte for byte. */
	check_ordinary(0xfffd);
	/* A byte that is not part of a valid UTF-8 sequence is not copied
	 * through: it is written as the escape of the replacement
	 * character, so the output is text and the invalid byte is gone.
	 * The man page states the rule. */
	text[0] = (char)0xff;
	text[1] = '\0';
	escaped_buffer(escaped, sizeof(escaped), text, 1);
	CHECK_STR(escaped, "\\ufffd");
	return (t_done("the control code points of the table are escaped"));
}

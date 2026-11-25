/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The bounds of the escaping of the text the tool prints: the decoder of
 * UTF-8 reads no byte past the length it is given, and a bounded buffer
 * holds the whole of the escaped text or nothing at all.
 *
 * The escaping under test is the production escaping: the test links the
 * escaper of the tool and does not copy it.  The bytes of every case are
 * in an allocation of their exact size, so the address sanitizer of the
 * build sees a read past the end of the input as the overflow it is.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "escape.h"

#include "t.h"

/* The escaped text of the bytes, in an allocation of their exact size: the
 * escaper reads no byte past the end of the allocation. */
static void
check_bytes(const unsigned char *bytes, size_t length, const char *expected)
{
	unsigned char *input;
	char escaped[64];
	size_t i;

	input = malloc(length);
	CHECK(input != NULL);
	if (input == NULL)
		return;
	memcpy(input, bytes, length);
	escaped[0] = '\0';
	escaped_buffer(escaped, sizeof(escaped), (const char *)input, length);
	CHECK_STR(escaped, expected);
	/* The bytes of the input are not changed by the escaping. */
	for (i = 0; i < length; i++)
		CHECK_EQ(input[i], bytes[i]);
	free(input);
}

/* A sequence that the buffer ends in the middle of is not a sequence: every
 * byte of it is a byte that is not part of a valid UTF-8 sequence, so every
 * byte of it is written as the escape of the replacement character, and the
 * byte that is not there is not read. */
static void
check_truncated(void)
{
	static const unsigned char two[] = { 0xc2 };
	static const unsigned char three[] = { 0xe2 };
	static const unsigned char three_half[] = { 0xe2, 0x82 };
	static const unsigned char four[] = { 0xf0 };
	static const unsigned char four_half[] = { 0xf0, 0x9f };
	static const unsigned char four_three[] = { 0xf0, 0x9f, 0x98 };
	static const unsigned char after_two[] = { 0x61, 0xc2 };
	static const unsigned char invalid[] = { 0xff };
	static const unsigned char invalid_tail[] = { 0x61, 0x80 };

	check_bytes(two, sizeof(two), "\\ufffd");
	check_bytes(three, sizeof(three), "\\ufffd");
	check_bytes(three_half, sizeof(three_half), "\\ufffd\\ufffd");
	check_bytes(four, sizeof(four), "\\ufffd");
	check_bytes(four_half, sizeof(four_half), "\\ufffd\\ufffd");
	check_bytes(four_three, sizeof(four_three), "\\ufffd\\ufffd\\ufffd");
	check_bytes(after_two, sizeof(after_two), "a\\ufffd");
	check_bytes(invalid, sizeof(invalid), "\\ufffd");
	check_bytes(invalid_tail, sizeof(invalid_tail), "a\\ufffd");
}

/* A sequence that ends exactly at the end of the input is a sequence: it is
 * copied through, byte for byte. */
static void
check_complete(void)
{
	static const unsigned char two[] = { 0xc2, 0xa9 };
	static const unsigned char three[] = { 0xe2, 0x82, 0xac };
	static const unsigned char four[] = { 0xf0, 0x9f, 0x98, 0x80 };

	check_bytes(two, sizeof(two), "\xc2\xa9");
	check_bytes(three, sizeof(three), "\xe2\x82\xac");
	check_bytes(four, sizeof(four), "\xf0\x9f\x98\x80");
}

/* The bounded buffer holds the whole of the escaped text or nothing at
 * all: a value that does not fit leaves the buffer empty, so a caller
 * never reads a spliced or a shortened value as if it were the whole one. */
static void
check_whole_or_nothing(void)
{
	static const unsigned char euro[] = { 0x61, 0xe2, 0x82, 0xac, 0x62 };
	char escaped[8];

	/* The escaped text is five bytes: "a", the euro sign and "b".  A
	 * buffer of six bytes holds it whole, with its terminator. */
	escaped[0] = 'x';
	escaped_buffer(escaped, 6, (const char *)euro, sizeof(euro));
	CHECK_STR(escaped, "a\xe2\x82\xac" "b");
	/* One byte too small: the text does not fit, so the buffer is left
	 * empty.  It does not hold the prefix that fits: a prefix is a
	 * value that was never in the input. */
	escaped[0] = 'x';
	escaped_buffer(escaped, 5, (const char *)euro, sizeof(euro));
	CHECK_STR(escaped, "");
	/* A buffer of four bytes cannot hold the euro sign with the text
	 * around it: the result is empty, and the two pieces around the
	 * euro sign are not spliced together. */
	escaped[0] = 'x';
	escaped_buffer(escaped, 4, (const char *)euro, sizeof(euro));
	CHECK_STR(escaped, "");
	/* A control code point is written as six bytes: a buffer that
	 * cannot hold them holds nothing. */
	escaped[0] = 'x';
	escaped_buffer(escaped, 4, "\x01", 1);
	CHECK_STR(escaped, "");
	/* A buffer that holds the escape holds it whole. */
	escaped[0] = 'x';
	escaped_buffer(escaped, 7, "\x01", 1);
	CHECK_STR(escaped, "\\u0001");
}

int
main(void)
{
	check_truncated();
	check_complete();
	check_whole_or_nothing();
	return (t_done("the escaping reads no byte past the input and holds a "
	    "value whole or not at all"));
}

/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The escaping of the text the tool prints.  The rules are:
 *
 * - a code point of the table of the control code points is written as a
 *   \uXXXX escape;
 * - a quote and a backslash are written as escapes;
 * - every other code point is copied through byte for byte;
 * - a byte that is not part of a valid UTF-8 sequence is written as the
 *   escape of the replacement character, \ufffd, so that the output is
 *   text and the invalid byte is not copied through.
 *
 * The escaping lives in its own source file: the tool and the test link
 * it, so the escaping under test is the escaping of the production code
 * and not a copy of it.
 */
#ifndef CUDA_NATIVE_ESCAPE_H_
#define CUDA_NATIVE_ESCAPE_H_

#include <stddef.h>
#include <stdint.h>

/* The shape of a range of the table of the control code points: the first
 * and the last code point of the range, both inclusive. */
struct control_range {
	uint32_t first;
	uint32_t last;
};

/* The one table of the control code points.  It lives in control_ranges.h,
 * which the tool and the test read, so a code point that is added to the
 * table is escaped by the tool and exercised by the test with it. */
extern const struct control_range control_ranges[];

/* The number of ranges of the table. */
extern const size_t control_range_count;

/* The escaped form of a string, written to the standard output between
 * quotes: the text of a JSON record. */
void escaped_string(const char *text);

/* The escaped form of a string in a bounded buffer: the same table,
 * without the quotes.  The buffer holds the whole of the escaped text or
 * nothing at all: a piece that does not fit is dropped whole, so an
 * escape sequence is never cut in half. */
void escaped_buffer(char *buffer, size_t size, const char *text, size_t length);

#endif

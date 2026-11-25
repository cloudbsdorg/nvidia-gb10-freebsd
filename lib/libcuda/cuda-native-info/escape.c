/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The escaping of the text the tool prints.  The rules are in escape.h.
 * The tool and the test link this file, so the escaping under test is the
 * escaping of the production code.
 */
#include <stdio.h>
#include <string.h>

#include "control_ranges.h"
#include "escape.h"

/* The code points that are written as text instead of being copied
 * through.  The table is the one list of them: it lives in
 * control_ranges.h, which the test reads as well, so a code point that is
 * added to the table is added to the test with it. */
const struct control_range control_ranges[] = {
	CUDA_NATIVE_CONTROL_RANGES
};

const size_t control_range_count =
    sizeof(control_ranges) / sizeof(control_ranges[0]);

static int
is_control_code(uint32_t code)
{
	size_t i;

	/* Time: O(table length); Space: O(1). */
	for (i = 0; i < control_range_count; i++)
		if (code >= control_ranges[i].first &&
		    code <= control_ranges[i].last)
			return (1);
	return (0);
}

/* The length of the UTF-8 sequence at p, and the code point it encodes.  A
 * zero length means the bytes are not a valid sequence.  The decoder reads
 * no byte past the available ones: a sequence that the buffer ends in the
 * middle of is not a sequence, and the byte that starts it is read alone
 * and written as the escape of the replacement character. */
static size_t
utf8_decode(const unsigned char *p, size_t available, uint32_t *code)
{
	uint32_t minimum;
	size_t i, length;

	if (available == 0)
		return (0);
	if (p[0] >= 0xc2 && p[0] <= 0xdf) {
		length = 2;
		*code = p[0] & 0x1f;
		minimum = 0x80;
	} else if (p[0] >= 0xe0 && p[0] <= 0xef) {
		length = 3;
		*code = p[0] & 0x0f;
		minimum = 0x800;
	} else if (p[0] >= 0xf0 && p[0] <= 0xf4) {
		length = 4;
		*code = p[0] & 0x07;
		minimum = 0x10000;
	} else {
		return (0);
	}
	/* The sequence must fit in the bytes that are there: the buffer may
	 * end in the middle of a sequence, and a continuation byte that is
	 * not there is not read. */
	if (length > available)
		return (0);
	/* Time: O(sequence length), at most four bytes; Space: O(1). */
	for (i = 1; i < length; i++) {
		if ((p[i] & 0xc0) != 0x80)
			return (0);
		*code = (*code << 6) | (p[i] & 0x3f);
	}
	if (*code < minimum || *code > 0x10ffff ||
	    (*code >= 0xd800 && *code <= 0xdfff))
		return (0);
	return (length);
}

/* The one escaping table.  A sink is either a bounded buffer or the standard
 * output, so the text report and the JSON records cannot drift apart. */
typedef struct escape_sink {
	char *buffer;
	size_t size;
	size_t used;
	FILE *stream;
	/* The sink knows that a piece did not fit: a bounded buffer holds
	 * the whole of the text or nothing at all. */
	int overflow;
} escape_sink;

static void
sink_write(escape_sink *sink, const char *text, size_t length)
{
	if (sink->buffer == NULL) {
		fwrite(text, 1, length, sink->stream);
		return;
	}
	/* A piece that does not fit is not written: the buffer holds the
	 * whole of the escaped text or nothing at all, so an escape sequence
	 * is never cut in half and two pieces are never spliced together
	 * into a value that was never in the input. */
	if (sink->used + length >= sink->size) {
		sink->overflow = 1;
		return;
	}
	memcpy(sink->buffer + sink->used, text, length);
	sink->used += length;
}

static void
escape_bytes(escape_sink *sink, const char *text, size_t length)
{
	const unsigned char *p = (const unsigned char *)text;
	uint32_t code;
	size_t i, used;

	/* Time: O(length); Space: O(1). */
	for (i = 0; i < length; i++) {
		if (p[i] >= 0x80) {
			used = utf8_decode(p + i, length - i, &code);
			if (used == 0) {
				/* A byte that is not part of a valid UTF-8
				 * sequence is not copied through: it is
				 * written as the escape of the replacement
				 * character, so the output is text.  The
				 * decoder has read no byte past the end of
				 * the input, so a sequence that the buffer
				 * ends in the middle of is refused here
				 * and not by a read of a byte that is not
				 * there. */
				sink_write(sink, "\\ufffd", 6);
				continue;
			}
			if (is_control_code(code)) {
				char form[8];

				snprintf(form, sizeof(form), "\\u%04x",
				    (unsigned)code);
				sink_write(sink, form, strlen(form));
			} else
				sink_write(sink, (const char *)(p + i), used);
			i += used - 1;
			continue;
		}
		switch (p[i]) {
		case '"':
			sink_write(sink, "\\\"", 2);
			break;
		case '\\':
			sink_write(sink, "\\\\", 2);
			break;
		default:
			if (is_control_code(p[i])) {
				char form[8];

				snprintf(form, sizeof(form), "\\u%04x",
				    (unsigned)p[i]);
				sink_write(sink, form, strlen(form));
			} else
				sink_write(sink, (const char *)(p + i), 1);
			break;
		}
	}
}

void
escaped_string(const char *text)
{
	escape_sink sink = { NULL, 0, 0, stdout, 0 };

	putchar('"');
	escape_bytes(&sink, text, strlen(text));
	putchar('"');
}

void
escaped_buffer(char *buffer, size_t size, const char *text, size_t length)
{
	escape_sink sink = { buffer, size, 0, NULL, 0 };

	if (size == 0)
		return;
	buffer[0] = '\0';
	escape_bytes(&sink, text, length);
	/* The whole of the escaped text or nothing at all: a text that does
	 * not fit leaves the buffer empty, so a caller never reads a
	 * shortened or a spliced value as if it were the whole one. */
	if (sink.overflow) {
		buffer[0] = '\0';
		return;
	}
	buffer[sink.used] = '\0';
}

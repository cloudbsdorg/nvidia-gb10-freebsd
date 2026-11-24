/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The code points that cuda-native-info writes as text instead of copying
 * through.  This table is the one list of them: the tool includes it and the
 * test reads it, so a code point that is added to the table is added to the
 * test with it and the two cannot drift apart.
 *
 * The macro takes the first code point of a range and the last one, both
 * inclusive, as a pair of braces.
 */
#ifndef CUDA_NATIVE_CONTROL_RANGES_H_
#define CUDA_NATIVE_CONTROL_RANGES_H_

/* The C0 controls and DEL are control characters in every terminal.  The C1
 * controls (U+0080 to U+009F) are control sequences in the UTF-8 encoding of
 * a terminal that implements 8-bit controls.  The line and paragraph
 * separators (U+2028, U+2029) are not safe in a JSON document that a program
 * reads as source text.  The bidirectional formatting controls can reorder
 * what a reader sees, so every Unicode Bidi_Control code point is in the
 * table: the Arabic letter mark, the left-to-right and right-to-left marks,
 * the embeddings and the override, and the isolates. */
#define CUDA_NATIVE_CONTROL_RANGES \
	{ 0x0000, 0x001f },	/* C0 controls */ \
	{ 0x007f, 0x007f },	/* DEL */ \
	{ 0x0080, 0x009f },	/* C1 controls */ \
	{ 0x061c, 0x061c },	/* ARABIC LETTER MARK */ \
	{ 0x200e, 0x200f },	/* LEFT-TO-RIGHT MARK, RIGHT-TO-LEFT MARK */ \
	{ 0x2028, 0x2029 },	/* LINE SEPARATOR, PARAGRAPH SEPARATOR */ \
	{ 0x202a, 0x202e },	/* embeddings and the override */ \
	{ 0x2066, 0x2069 }	/* isolates */

#endif

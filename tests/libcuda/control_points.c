/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The code points that cuda-native-info writes as text instead of copying
 * through.  The table is the one list of them: it lives in
 * control_ranges.h, the header the tool includes, and this program compiles
 * that header in, so the list of the code points the test exercises is the
 * list of the production table and the test keeps no copy of it.
 *
 * The program prints every code point of the table, one per line, in
 * hexadecimal.  The NUL is left out: it cannot travel through the
 * environment, so the code level test of the escaping checks it.
 */
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "control_ranges.h"

/* The shape of a range of the table: the macro of the header names the
 * first and the last code point of every range, in that order. */
struct control_range {
	uint32_t first;
	uint32_t last;
};

static const struct control_range ranges[] = {
	CUDA_NATIVE_CONTROL_RANGES
};

#define RANGE_COUNT (sizeof(ranges) / sizeof(ranges[0]))

int
main(int argc, char **argv)
{
	size_t i;
	uint64_t code;

	/* The ranges of the table, when they are asked for: the shell reads
	 * the ends of the ranges from here, so it keeps no copy of the
	 * table and names no code point of it. */
	if (argc == 2 && strcmp(argv[1], "ranges") == 0) {
		for (i = 0; i < RANGE_COUNT; i++)
			printf("%04x:%04x\n", (unsigned)ranges[i].first,
			    (unsigned)ranges[i].last);
		return (0);
	}
	if (argc != 1)
		return (2);

	/* Time: O(code points of the table); Space: O(1). */
	for (i = 0; i < RANGE_COUNT; i++) {
		for (code = ranges[i].first; code <= ranges[i].last; code++) {
			/* A NUL cannot travel through the environment, so
			 * the code level test of the escaping checks it. */
			if (code == 0)
				continue;
			printf("%04x\n", (unsigned)code);
		}
	}
	return (0);
}

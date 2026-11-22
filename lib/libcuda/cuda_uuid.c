/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 */
#include <string.h>

#include "cuda_internal.h"

void
cuda_uuid_text(const CUuuid *uuid, char text[41])
{
	static const char hex[] = "0123456789abcdef";
	const unsigned char *bytes = (const unsigned char *)uuid->bytes;
	unsigned i, position = 4;

	memcpy(text, "GPU-", 4);
	/* Time: O(1), Space: O(1): a UUID always contains 16 bytes. */
	for (i = 0; i < 16; i++) {
		if (i == 4 || i == 6 || i == 8 || i == 10)
			text[position++] = '-';
		text[position++] = hex[bytes[i] >> 4];
		text[position++] = hex[bytes[i] & 15];
	}
	text[position] = '\0';
}

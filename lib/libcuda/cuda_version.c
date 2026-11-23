/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 */
#include <ctype.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "cuda_internal.h"

static int
version_invalid(cuda_native_version *version, const char *reason)
{
	version->available = 0;
	version->major = 0;
	version->minor = 0;
	version->patch = 0;
	version->suffix[0] = '\0';
	version->reason = reason;
	return (-1);
}

int
cuda_version_parse(cuda_native_version *version, const char *raw)
{
	uint32_t parts[3] = { 0, 0, 0 };
	const char *cursor, *suffix;
	size_t length, suffix_length;
	unsigned part;

	if (version == NULL)
		return (-1);
	memset(version, 0, sizeof(*version));
	if (raw == NULL)
		return (version_invalid(version, "version string is absent"));
	length = strlen(raw);
	if (length >= sizeof(version->string))
		return (version_invalid(version, "version string is too long"));
	memcpy(version->string, raw, length + 1);
	if (length == 0 || length > CUDA_NATIVE_VERSION_TEXT_MAX)
		return (version_invalid(version, "version string has invalid length"));

	cursor = raw;
	part = 0;
	for (;;) {
		uint64_t value = 0;

		if (!isdigit((unsigned char)*cursor))
			return (version_invalid(version,
			    "version does not begin with a numeric component"));
		do {
			unsigned digit = (unsigned)(*cursor - '0');

			if (value > (UINT32_MAX - digit) / 10)
				return (version_invalid(version,
				    "version component exceeds uint32_t"));
			value = value * 10 + digit;
			cursor++;
		} while (isdigit((unsigned char)*cursor));
		parts[part++] = (uint32_t)value;
		if (*cursor == '\0')
			break;
		if (*cursor == '-' || *cursor == '+')
			break;
		if (*cursor != '.' || part == 3)
			return (version_invalid(version,
			    "version must have one to three numeric components"));
		cursor++;
	}

	suffix = cursor;
	if (*suffix != '\0') {
		if (*suffix != '-' && *suffix != '+')
			return (version_invalid(version, "invalid version suffix"));
		suffix_length = strlen(suffix);
		if (suffix_length < 2 || suffix_length >= sizeof(version->suffix))
			return (version_invalid(version, "invalid version suffix"));
		memcpy(version->suffix, suffix, suffix_length + 1);
	}
	version->major = parts[0];
	version->minor = parts[1];
	version->patch = parts[2];
	version->available = 1;
	version->reason = NULL;
	return (0);
}

int
cuda_version_make(cuda_native_version *version, uint32_t major, uint32_t minor,
    uint32_t patch, unsigned parts)
{
	char raw[64];
	int length;

	if (version == NULL || parts == 0 || parts > 3)
		return (-1);
	if (parts == 1)
		length = snprintf(raw, sizeof(raw), "%" PRIu32, major);
	else if (parts == 2)
		length = snprintf(raw, sizeof(raw), "%" PRIu32 ".%" PRIu32,
		    major, minor);
	else
		length = snprintf(raw, sizeof(raw),
		    "%" PRIu32 ".%" PRIu32 ".%" PRIu32, major, minor, patch);
	if (length < 0 || (size_t)length >= sizeof(raw))
		return (-1);
	return (cuda_version_parse(version, raw));
}

int
cuda_version_format(const cuda_native_version *version, char *output,
    size_t output_size)
{
	size_t length;

	if (version == NULL || output == NULL || output_size == 0 ||
	    !version->available)
		return (-1);
	length = strlen(version->string);
	if (length >= output_size)
		return (-1);
	memcpy(output, version->string, length + 1);
	return (0);
}

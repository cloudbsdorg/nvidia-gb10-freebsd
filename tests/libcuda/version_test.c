/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 */
#include <limits.h>
#include <stdint.h>
#include <string.h>

#include "cuda_internal.h"
#include "t.h"

static void
good(const char *raw, uint32_t major, uint32_t minor, uint32_t patch,
    const char *suffix)
{
	cuda_native_version v;
	char round[256];

	memset(&v, 0, sizeof(v));
	CHECK_EQ(cuda_version_parse(&v, raw), 0);
	CHECK_EQ(v.available, 1);
	CHECK_STR(v.string, raw);
	CHECK_EQ(v.major, major);
	CHECK_EQ(v.minor, minor);
	CHECK_EQ(v.patch, patch);
	CHECK_STR(v.suffix, suffix);
	CHECK_EQ(cuda_version_format(&v, round, sizeof(round)), 0);
	CHECK_STR(round, raw);
}

static void
bad_reason(const char *raw, const char *reason)
{
	cuda_native_version v;

	memset(&v, 0, sizeof(v));
	CHECK_EQ(cuda_version_parse(&v, raw), -1);
	CHECK_EQ(v.available, 0);
	if (strlen(raw) < sizeof(v.string))
		CHECK_STR(v.string, raw);
	CHECK_EQ(v.major, 0);
	CHECK_EQ(v.minor, 0);
	CHECK_EQ(v.patch, 0);
	CHECK(v.reason != NULL);
	if (reason != NULL)
		CHECK_STR(v.reason, reason);
}

static void
bad(const char *raw)
{
	bad_reason(raw, NULL);
}

static void
made(uint32_t major, uint32_t minor, uint32_t patch, unsigned parts,
    const char *want)
{
	cuda_native_version v;
	char text[256];

	CHECK_EQ(cuda_version_make(&v, major, minor, patch, parts), 0);
	CHECK_STR(v.string, want);
	CHECK_EQ(v.major, major);
	CHECK_EQ(v.minor, minor);
	CHECK_EQ(v.patch, patch);
	CHECK_EQ(v.available, 1);
	CHECK_EQ(cuda_version_format(&v, text, sizeof(text)), 0);
	CHECK_STR(text, want);
}

int
main(void)
{
	cuda_native_version v;
	char longraw[513];
	char tiny[2];

	good("13.0", 13, 0, 0, "");
	good("0.1.0", 0, 1, 0, "");
	good("580.178.04", 580, 178, 4, "");
	good("580.178", 580, 178, 0, "");
	good("1", 1, 0, 0, "");
	good("1.2.3-rc1", 1, 2, 3, "-rc1");
	good("1.2.3+build5", 1, 2, 3, "+build5");
	good("0001.0002.0003", 1, 2, 3, "");

	bad("");
	bad("v1.2");
	bad("1.");
	bad(".1");
	bad("1..2");
	bad("1.2.3.4");
	bad("1.x");
	bad("4294967296");
	bad("1.2.3-");
	memset(longraw, '1', 255);
	longraw[255] = '\0';
	bad_reason(longraw, "version component exceeds uint32_t");
	memset(longraw, '1', 256);
	longraw[256] = '\0';
	bad_reason(longraw, "version string has invalid length");
	memset(longraw, '1', 512);
	longraw[512] = '\0';
	bad_reason(longraw, "version string is too long");

	CHECK_EQ(cuda_version_parse(NULL, "1.2"), -1);
	CHECK_EQ(cuda_version_parse(&v, NULL), -1);
	made(12, 0, 0, 2, "12.0");
	made(0, 1, 0, 3, "0.1.0");
	made(7, 0, 0, 1, "7");
	CHECK_EQ(cuda_version_make(&v, 1, 2, 3, 0), -1);
	CHECK_EQ(cuda_version_make(&v, 1, 2, 3, 4), -1);
	CHECK_EQ(cuda_version_make(NULL, 1, 2, 3, 3), -1);
	CHECK_EQ(cuda_version_format(NULL, tiny, sizeof(tiny)), -1);
	CHECK_EQ(cuda_version_format(&v, NULL, 0), -1);
	made(12, 3, 4, 3, "12.3.4");
	CHECK_EQ(cuda_version_format(&v, tiny, sizeof(tiny)), -1);
	v.available = 0;
	CHECK_EQ(cuda_version_format(&v, longraw, sizeof(longraw)), -1);

	return (t_done("version_test"));
}

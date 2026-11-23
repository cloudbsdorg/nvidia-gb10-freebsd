/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * version_test.c - bounded version parsing, banner discovery and formatting.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <nvrm/nvrm_version.h>

#include "t.h"

static const char banner[] =
    "NVIDIA UNIX Open Kernel Module for aarch64  580.178.04  Release Build  "
    "(cloudbsd@build)  Sun Nov 22 06:36:44 UTC 2026";

static void
check_same(const nvrm_version *a, const nvrm_version *b)
{
	unsigned i;

	CHECK_EQ(a->available, b->available);
	CHECK_STR(a->string, b->string);
	CHECK_EQ(a->nparts, b->nparts);
	CHECK_STR(a->suffix, b->suffix);
	for (i = 0; i < NVRM_VERSION_MAX_PARTS; i++) {
		CHECK_EQ(a->parts[i], b->parts[i]);
		CHECK_EQ(a->width[i], b->width[i]);
	}
}

static void
check_round_trip(const char *s, unsigned base)
{
	nvrm_version a, b;
	char buf[NVRM_VERSION_STRING_MAX + 1];

	CHECK_EQ(nvrm_version_parse(s, base, &a), 0);
	CHECK_EQ(nvrm_version_format(&a, buf, sizeof(buf)), 0);
	CHECK_STR(buf, s);
	CHECK_EQ(nvrm_version_parse(buf, base, &b), 0);
	check_same(&a, &b);
}

static void
check_unparsed(const char *s, unsigned base)
{
	nvrm_version v;
	unsigned i;

	CHECK_EQ(nvrm_version_parse(s, base, &v), -1);
	CHECK(!v.available);
	CHECK_STR(v.reason, "version_unparsed");
	CHECK_STR(v.string, s);
	CHECK_EQ(v.nparts, 0);
	CHECK_EQ(v.suffix[0], 0);
	for (i = 0; i < NVRM_VERSION_MAX_PARTS; i++) {
		CHECK_EQ(v.parts[i], 0);
		CHECK_EQ(v.width[i], 0);
	}
}

static void
test_decimal_and_round_trips(void)
{
	nvrm_version v, built, parsed;
	char buf[NVRM_VERSION_STRING_MAX + 1];

	check_round_trip("580.178.04", 10);
	CHECK_EQ(nvrm_version_parse("580.178.04", 10, &v), 0);
	CHECK(v.available);
	CHECK(v.reason == NULL);
	CHECK_EQ(v.nparts, 3);
	CHECK_EQ(v.parts[0], 580);
	CHECK_EQ(v.parts[1], 178);
	CHECK_EQ(v.parts[2], 4);
	CHECK_EQ(v.width[0], 3);
	CHECK_EQ(v.width[1], 3);
	CHECK_EQ(v.width[2], 2);
	CHECK_STR(v.suffix, "");

	check_round_trip("580.178", 10);
	CHECK_EQ(nvrm_version_parse("580.178", 10, &v), 0);
	CHECK_EQ(v.nparts, 2);
	CHECK_EQ(v.parts[2], 0);	/* the fixed patch slot for a missing part */
	CHECK_EQ(v.width[2], 0);
	check_round_trip("7", 10);
	check_round_trip("1.2.3.4.5.6", 10);
	check_round_trip("1.2.3-rc1", 10);
	CHECK_EQ(nvrm_version_parse("1.2.3-rc1", 10, &v), 0);
	CHECK_EQ(v.parts[0], 1);
	CHECK_EQ(v.parts[1], 2);
	CHECK_EQ(v.parts[2], 3);
	CHECK_STR(v.suffix, "-rc1");
	check_round_trip("1.2.3+build5", 10);
	CHECK_EQ(nvrm_version_parse("1.2.3+build5", 10, &v), 0);
	CHECK_STR(v.suffix, "+build5");
	check_round_trip("0001.002.0003", 10);
	check_round_trip("4294967295.0", 10);

	/* A caller-built value formats from its integer parts and widths. */
	memset(&built, 0, sizeof(built));
	built.available = 1;
	built.nparts = 3;
	built.parts[0] = 580;
	built.parts[1] = 178;
	built.parts[2] = 4;
	built.width[0] = 3;
	built.width[1] = 3;
	built.width[2] = 2;
	memcpy(built.suffix, "-rc1", sizeof("-rc1"));
	CHECK_EQ(nvrm_version_format(&built, buf, sizeof(buf)), 0);
	CHECK_STR(buf, "580.178.04-rc1");
	CHECK_EQ(nvrm_version_parse(buf, 10, &parsed), 0);
	CHECK_EQ(parsed.nparts, built.nparts);
	CHECK_EQ(parsed.parts[0], built.parts[0]);
	CHECK_EQ(parsed.parts[1], built.parts[1]);
	CHECK_EQ(parsed.parts[2], built.parts[2]);
	CHECK_STR(parsed.suffix, built.suffix);
}

static void
test_hex_and_width(void)
{
	nvrm_version v;

	check_round_trip("96.06.1e.00.4a", 16);
	CHECK_EQ(nvrm_version_parse("96.06.1e.00.4a", 16, &v), 0);
	CHECK_EQ(v.nparts, 5);
	CHECK_EQ(v.parts[0], 0x96);
	CHECK_EQ(v.parts[1], 6);
	CHECK_EQ(v.parts[2], 0x1e);
	CHECK_EQ(v.parts[3], 0);
	CHECK_EQ(v.parts[4], 0x4a);
	CHECK_EQ(v.width[2], 2);
	/* Exact source preservation includes hex letter case. */
	check_round_trip("96.06.1E.00.4A", 16);
	check_round_trip("ffffffff.0", 16);
	check_unparsed("100000000.0", 16);
	check_unparsed("96.06.1e.00.4a", 10);
}

static void
test_invalid_and_bounds(void)
{
	nvrm_version v;
	char exact[NVRM_VERSION_STRING_MAX + 2], over[NVRM_VERSION_STRING_MAX + 3];
	char suffix[100];
	unsigned i;

	check_unparsed("", 10);
	check_unparsed("N/A", 10);
	check_unparsed("??.??.??.??.??", 10);
	check_unparsed("0123456789abcdef", 10);
	check_unparsed(".1", 10);
	check_unparsed("1.", 10);
	check_unparsed("1..2", 10);
	check_unparsed("1.a", 10);
	check_unparsed("-1.2", 10);
	check_unparsed("1.2rc1", 10);
	check_unparsed("4294967296", 10);
	check_unparsed("1.2.3.4.5.6.7", 10);
	check_unparsed("1.2", 0);
	check_unparsed("1.2", 9);
	check_unparsed("1.2", 17);

	/* 245 digits plus five '.1' parts is exactly 255 bytes. */
	memset(exact, '0', 245);
	exact[244] = '1';
	for (i = 0; i < 5; i++) {
		exact[245 + i * 2] = '.';
		exact[246 + i * 2] = '1';
	}
	exact[255] = '\0';
	check_round_trip(exact, 10);
	memcpy(over, exact, 245);
	memmove(over + 246, exact + 245, 11);
	over[245] = '0';
	over[256] = '\0';
	CHECK_EQ(strlen(over), 256);
	CHECK_EQ(nvrm_version_parse(over, 10, &v), -1);
	CHECK(!v.available);
	CHECK_STR(v.reason, "version_unparsed");

	/* suffix[64] holds a delimiter and at most 62 following bytes. */
	strcpy(suffix, "1.2-");
	memset(suffix + 4, 'r', 62);
	suffix[4 + 62] = '\0';
	check_round_trip(suffix, 10);
	suffix[4 + 62] = 'r';
	suffix[4 + 63] = '\0';
	CHECK_EQ(nvrm_version_parse(suffix, 10, &v), -1);
	CHECK(!v.available);

	CHECK_EQ(nvrm_version_parse(NULL, 10, &v), -1);
	CHECK(!v.available);
	CHECK_STR(v.string, "");
	CHECK_EQ(nvrm_version_parse("1.2", 10, NULL), -1);
}

static void
test_banner_find(void)
{
	nvrm_version v;
	char no_version[512];
	char long_token[300];

	CHECK_EQ(nvrm_version_find(banner, &v), 0);
	CHECK(v.available);
	CHECK_STR(v.string, "580.178.04");
	CHECK_EQ(v.nparts, 3);
	CHECK_EQ(v.parts[0], 580);
	CHECK_EQ(v.parts[1], 178);
	CHECK_EQ(v.parts[2], 4);

	CHECK_EQ(nvrm_version_find("NVIDIA UNIX Open Kernel Module for aarch64 "
	    "Release Build", &v), -1);
	CHECK(!v.available);
	CHECK_STR(v.string, "");
	CHECK_STR(v.reason, "version_unparsed");
	CHECK_EQ(nvrm_version_find("module 580 release 1.2.3+build5", &v), 0);
	CHECK_STR(v.string, "1.2.3+build5");
	CHECK_EQ(nvrm_version_find("module aarch64 580.178", &v), 0);
	CHECK_STR(v.string, "580.178");
	CHECK_EQ(v.nparts, 2);
	CHECK_EQ(nvrm_version_find(NULL, &v), -1);
	CHECK_EQ(nvrm_version_find("1.2", NULL), -1);

	/* An unparseably long numeric token is skipped, not truncated into one. */
	memset(long_token, '1', sizeof(long_token));
	memcpy(long_token, "module ", 7);
	long_token[7 + 256] = ' ';
	memcpy(long_token + 7 + 256 + 1, "580.178.04", sizeof("580.178.04"));
	CHECK_EQ(nvrm_version_find(long_token, &v), 0);
	CHECK_STR(v.string, "580.178.04");

	strcpy(no_version, "NVIDIA ?? .?? 7 2026");
	CHECK_EQ(nvrm_version_find(no_version, &v), -1);
	CHECK(!v.available);
}

static void
test_format_bounds(void)
{
	nvrm_version v;
	char buf[8];

	CHECK_EQ(nvrm_version_parse("1.20", 10, &v), 0);
	CHECK_EQ(nvrm_version_format(&v, buf, 5), 0);
	CHECK_STR(buf, "1.20");
	CHECK_EQ(nvrm_version_format(&v, buf, 4), -1);
	CHECK_EQ(nvrm_version_format(&v, NULL, 0), -1);
	CHECK_EQ(nvrm_version_format(NULL, buf, sizeof(buf)), -1);

	memset(&v, 0, sizeof(v));
	v.available = 1;
	v.nparts = 1;
	v.parts[0] = 12;
	v.width[0] = 1;		/* too narrow for the integer */
	CHECK_EQ(nvrm_version_format(&v, buf, sizeof(buf)), -1);
	v.width[0] = 2;
	CHECK_EQ(nvrm_version_format(&v, buf, sizeof(buf)), 0);
	CHECK_STR(buf, "12");
	v.nparts = 0;
	CHECK_EQ(nvrm_version_format(&v, buf, sizeof(buf)), -1);
	v.nparts = NVRM_VERSION_MAX_PARTS + 1;
	CHECK_EQ(nvrm_version_format(&v, buf, sizeof(buf)), -1);
	v.nparts = 1;
	v.available = 0;
	CHECK_EQ(nvrm_version_format(&v, buf, sizeof(buf)), -1);
}

int
main(void)
{
	setvbuf(stdout, NULL, _IOLBF, 0);
	test_decimal_and_round_trips();
	test_hex_and_width();
	test_invalid_and_bounds();
	test_banner_find();
	test_format_bounds();
	return (t_done("version_test"));
}

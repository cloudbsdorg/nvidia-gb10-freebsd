/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * t_version.h - shared checks for parsed versions and device fields.
 */
#ifndef _T_VERSION_H_
#define _T_VERSION_H_

#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "nvrm_internal.h"
#include "t.h"

static void
t_check_version(const nvrm_version *v, const char *string,
    const uint32_t *parts, unsigned nparts, const char *suffix)
{
	unsigned n;

	CHECK(v != NULL);
	if (v == NULL)
		return;
	CHECK(v->available);
	CHECK_STR(v->string, string);
	CHECK_STR(v->suffix, suffix);
	CHECK(v->reason == NULL);
	CHECK_EQ(v->nparts, nparts);
	CHECK(nparts <= NVRM_VERSION_MAX_PARTS);
	if (nparts > NVRM_VERSION_MAX_PARTS)
		return;
	for (n = 0; n < nparts; n++)
		CHECK_EQ(v->parts[n], parts[n]);
}

static void
t_check_version3(const nvrm_version *v, const char *string, uint32_t major,
    uint32_t minor, uint32_t patch, const char *suffix)
{
	const uint32_t parts[] = { major, minor, patch };

	t_check_version(v, string, parts, 3, suffix);
}

static void
t_check_unavailable_version(const nvrm_version *v, const char *string,
    const char *reason)
{
	unsigned n;

	CHECK(v != NULL);
	if (v == NULL)
		return;
	CHECK(!v->available);
	CHECK_STR(v->string, string);
	CHECK_STR(v->reason, reason);
	CHECK_EQ(v->nparts, 0);
	for (n = 0; n < NVRM_VERSION_MAX_PARTS; n++) {
		CHECK_EQ(v->parts[n], 0);
		CHECK_EQ(v->width[n], 0);
	}
}

static int
t_get_version_field(const nvrm_device_info *info, const char *name,
    nvrm_version_field *out)
{
	unsigned n;

	for (n = 0; n < nvrm_info_nfields(); n++) {
		const nvrm_field *f = nvrm_info_field(n);

		if (strcmp(f->name, name) != 0)
			continue;
		CHECK_STR(f->group, "versions");
		CHECK(f->kind == NVRM_K_VERSION);
		if (f->kind != NVRM_K_VERSION)
			return (-1);
		memcpy(out, (const char *)info + f->offset, sizeof(*out));
		return (0);
	}
	CHECK(0);	/* the field is absent */
	return (-1);
}

static void
t_check_version_field(const nvrm_device_info *info, const char *name,
    const char *string, const uint32_t *parts, unsigned nparts)
{
	nvrm_version_field v;

	if (t_get_version_field(info, name, &v) != 0)
		return;
	t_check_version(&v.version, string, parts, nparts, "");
	CHECK_EQ(v.source, NVRM_S_RM);
}

static void
t_check_unavailable_version_field(const nvrm_device_info *info,
    const char *name, const char *string, const char *reason)
{
	nvrm_version_field v;

	if (t_get_version_field(info, name, &v) != 0)
		return;
	t_check_unavailable_version(&v.version, string, reason);
	CHECK_EQ(v.source, NVRM_S_RM);
}

static void
t_check_common_device(const nvrm_device_info *info)
{
	static const struct {
		const char	*name;
		size_t		offset;
		uint64_t	value;
	} want[] = {
		{ "pci_vendor", offsetof(nvrm_device_info, pci_vendor), 0x10de },
		{ "pci_device", offsetof(nvrm_device_info, pci_device), 0x2d04 },
		{ "pci_subsystem_vendor",
		    offsetof(nvrm_device_info, pci_subsystem_vendor), 0x1462 },
		{ "pci_subsystem_device",
		    offsetof(nvrm_device_info, pci_subsystem_device), 0x5351 },
		{ "chip_id", offsetof(nvrm_device_info, chip_id), 0x1b6 },
		{ "gpc_count", offsetof(nvrm_device_info, gpc_count), 3 },
		{ "tpc_count", offsetof(nvrm_device_info, tpc_count), 18 },
		{ "sm_count", offsetof(nvrm_device_info, sm_count), 36 },
		{ "vram_size", offsetof(nvrm_device_info, vram_size),
		    16ULL << 30 },
	};
	unsigned n;

	for (n = 0; n < sizeof(want) / sizeof(want[0]); n++) {
		const nvrm_u64 *field = (const nvrm_u64 *)
		    ((const char *)info + want[n].offset);

		if (field->value != want[n].value)
			printf("  %s: value %#jx, want %#jx\n", want[n].name,
			    (uintmax_t)field->value, (uintmax_t)want[n].value);
		CHECK_EQ(field->value, want[n].value);
	}
	CHECK_STR(info->family.value, "blackwell-b");
}

#endif

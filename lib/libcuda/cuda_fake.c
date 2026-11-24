/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Deterministic devices for tests and documentation examples.  Every value
 * below is synthetic; this provider neither discovers nor accesses hardware.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "cuda_internal.h"

typedef struct fake_profile {
	const char *profile;
	const char *name;
	unsigned char uuid[16];
	size_t memory;
	int compute_major;
	int compute_minor;
	int multiprocessors;
	int integrated;
	int pci_domain;
	int pci_bus;
	int pci_device;
	/* Listed profiles are the ones the library advertises; a profile
	 * reserved for the library's own tests is accepted but not listed. */
	unsigned listed;
} fake_profile;

/* The profile the fake provider uses when the environment names none. */
static const char *const default_profile = "gb206";

static const fake_profile profiles[] = {
	{
		.profile = "gb206",
		.name = "cuda-native fake GB206",
		.uuid = { 0xcb, 0x14, 0xa0, 0x00, 0x00, 0x00, 0x40, 0x00,
		    0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01 },
		.memory = (size_t)16 * 1024 * 1024 * 1024,
		.compute_major = 12,
		.compute_minor = 0,
		.multiprocessors = 36,
		.integrated = 0,
		.pci_domain = 0,
		.pci_bus = 1,
		.pci_device = 0,
		.listed = 1
	},
	{
		.profile = "gb10",
		.name = "cuda-native fake GB10",
		.uuid = { 0xcb, 0x14, 0xa0, 0x00, 0x00, 0x00, 0x40, 0x00,
		    0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02 },
		.memory = (size_t)128 * 1024 * 1024 * 1024,
		.compute_major = 12,
		.compute_minor = 1,
		.multiprocessors = 48,
		.integrated = 1,
		.pci_domain = 15,
		.pci_bus = 1,
		.pci_device = 0,
		.listed = 1
	},
#ifdef CUDA_NATIVE_TESTING
	{
		.profile = "utf8",
		.name = "cuda-native fake \xE2\x84\xA2 \xC3\xA9 \xFF "
		    "\x01\x7F",
		.uuid = { 0xcb, 0x14, 0xa0, 0x00, 0x00, 0x00, 0x40, 0x00,
		    0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03 },
		.memory = (size_t)16 * 1024 * 1024 * 1024,
		.compute_major = 12,
		.compute_minor = 0,
		.multiprocessors = 36,
		.integrated = 0,
		.pci_domain = 0,
		.pci_bus = 1,
		.pci_device = 0,
		.listed = 0
	}
#endif
};

static const fake_profile *selected[CUDA_NATIVE_MAX_PHYSICAL_DEVICES];
static unsigned selected_count;
/* The count of the selection, even when the selection names more devices
 * than the array above holds: the registry refuses such a count, and the
 * devices are never addressed. */
static unsigned selected_total;

static const fake_profile *
profile_find(const char *name, size_t length)
{
	size_t i;

	/* Time: O(profiles * name length); Space: O(1). */
	for (i = 0; i < sizeof(profiles) / sizeof(profiles[0]); i++)
		if (strlen(profiles[i].profile) == length &&
		    memcmp(profiles[i].profile, name, length) == 0)
			return (&profiles[i]);
	return (NULL);
}

int
cudaNativeFakeProfileKnown(const char *name, size_t length)
{
	if (name == NULL)
		return (0);
	return (profile_find(name, length) != NULL);
}

unsigned
cudaNativeFakeProfileCount(void)
{
	unsigned count = 0;
	size_t i;

	/* Time: O(profiles); Space: O(1). */
	for (i = 0; i < sizeof(profiles) / sizeof(profiles[0]); i++)
		if (profiles[i].listed)
			count++;
	return (count);
}

const char *
cudaNativeFakeProfileName(unsigned index)
{
	unsigned seen = 0;
	size_t i;

	/* Time: O(profiles); Space: O(1). */
	for (i = 0; i < sizeof(profiles) / sizeof(profiles[0]); i++) {
		if (!profiles[i].listed)
			continue;
		if (seen == index)
			return (profiles[i].profile);
		seen++;
	}
	return (NULL);
}

const char *
cudaNativeFakeProfileDefault(void)
{
	return (default_profile);
}

/* The provider applies the profile selection the registry hands it.  The
 * selection is the comma-separated list of profile names, or null when the
 * environment names none; then the provider uses its own default.  The
 * provider reports how many devices the selection names, even when that
 * number is above the number of devices the registry holds: the registry
 * refuses the count and names the reason, so the failure is not reported as
 * a provider error. */
static CUresult
fake_select(const char *list)
{
	const fake_profile *profile;
	const char *cursor, *comma;
	size_t length;
	unsigned count = 0;

	if (list == NULL)
		list = default_profile;
	if (*list == '\0')
		return (CUDA_ERROR_INVALID_VALUE);
	selected_count = 0;
	cursor = list;
	/* Time: O(profile-list bytes); Space: O(1). */
	for (;;) {
		comma = strchr(cursor, ',');
		length = comma == NULL ? strlen(cursor) : (size_t)(comma - cursor);
		profile = profile_find(cursor, length);
		if (profile == NULL)
			return (CUDA_ERROR_INVALID_VALUE);
		count++;
		if (comma == NULL)
			break;
		cursor = comma + 1;
	}
	selected_total = count;
	if (count > CUDA_NATIVE_MAX_PHYSICAL_DEVICES)
		return (CUDA_SUCCESS);
	cursor = list;
	selected_count = 0;
	/* Time: O(profile-list bytes); Space: O(1) besides selected[]. */
	for (;;) {
		comma = strchr(cursor, ',');
		length = comma == NULL ? strlen(cursor) : (size_t)(comma - cursor);
		profile = profile_find(cursor, length);
		if (profile == NULL)
			return (CUDA_ERROR_INVALID_VALUE);
		selected[selected_count++] = profile;
		if (comma == NULL)
			break;
		cursor = comma + 1;
	}
	return (CUDA_SUCCESS);
}

static CUresult
fake_enumerate(unsigned *count)
{
#ifdef CUDA_NATIVE_TESTING
	const char *delay;
#endif

	if (count == NULL)
		return (CUDA_ERROR_INVALID_VALUE);
#ifdef CUDA_NATIVE_TESTING
	delay = getenv("CUDA_NATIVE_FAKE_ENUM_DELAY_MS");
	if (delay != NULL && *delay != '\0') {
		unsigned long ms = strtoul(delay, NULL, 10);
		struct timespec request = {
			.tv_sec = (time_t)(ms / 1000),
			.tv_nsec = (long)(ms % 1000) * 1000000L
		};

		nanosleep(&request, NULL);
	}
#endif
	*count = selected_total;
	return (CUDA_SUCCESS);
}

static int
fake_valid(unsigned index)
{
	return (index < selected_count);
}

static CUresult
fake_name(unsigned index, char *name, int len)
{
	if (!fake_valid(index) || name == NULL || len <= 0)
		return (CUDA_ERROR_INVALID_VALUE);
	if (snprintf(name, (size_t)len, "%s", selected[index]->name) < 0)
		return (CUDA_ERROR_UNKNOWN);
	return (CUDA_SUCCESS);
}

static CUresult
fake_uuid(unsigned index, CUuuid *uuid)
{
	if (!fake_valid(index) || uuid == NULL)
		return (CUDA_ERROR_INVALID_VALUE);
#ifdef CUDA_NATIVE_TESTING
	if (getenv("CUDA_NATIVE_FAKE_UUID_ERROR") != NULL)
		return (CUDA_ERROR_UNKNOWN);
#endif
	memcpy(uuid->bytes, selected[index]->uuid, sizeof(uuid->bytes));
	return (CUDA_SUCCESS);
}

static CUresult
fake_memory(unsigned index, size_t *bytes)
{
	if (!fake_valid(index) || bytes == NULL)
		return (CUDA_ERROR_INVALID_VALUE);
	*bytes = selected[index]->memory;
	return (CUDA_SUCCESS);
}

static CUresult
fake_attribute(unsigned index, CUdevice_attribute attribute, int *value)
{
	const fake_profile *profile;

	if (!fake_valid(index) || value == NULL)
		return (CUDA_ERROR_INVALID_VALUE);
#ifdef CUDA_NATIVE_TESTING
	if (attribute == CU_DEVICE_ATTRIBUTE_COOPERATIVE_LAUNCH &&
	    getenv("CUDA_NATIVE_FAKE_UNSUPPORTED_COOPERATIVE") != NULL)
		return (CUDA_ERROR_NOT_SUPPORTED);
#endif
	profile = selected[index];
	switch (attribute) {
	case CU_DEVICE_ATTRIBUTE_MAX_THREADS_PER_BLOCK:
		*value = 1024;
		break;
	case CU_DEVICE_ATTRIBUTE_MAX_SHARED_MEMORY_PER_BLOCK:
		*value = 48 * 1024;
		break;
	case CU_DEVICE_ATTRIBUTE_WARP_SIZE:
		*value = 32;
		break;
	case CU_DEVICE_ATTRIBUTE_MULTIPROCESSOR_COUNT:
		*value = profile->multiprocessors;
		break;
	case CU_DEVICE_ATTRIBUTE_INTEGRATED:
		*value = profile->integrated;
		break;
	case CU_DEVICE_ATTRIBUTE_PCI_BUS_ID:
		*value = profile->pci_bus;
		break;
	case CU_DEVICE_ATTRIBUTE_PCI_DEVICE_ID:
		*value = profile->pci_device;
		break;
	case CU_DEVICE_ATTRIBUTE_PCI_DOMAIN_ID:
		*value = profile->pci_domain;
		break;
	case CU_DEVICE_ATTRIBUTE_COMPUTE_CAPABILITY_MAJOR:
		*value = profile->compute_major;
		break;
	case CU_DEVICE_ATTRIBUTE_COMPUTE_CAPABILITY_MINOR:
		*value = profile->compute_minor;
		break;
	case CU_DEVICE_ATTRIBUTE_COOPERATIVE_LAUNCH:
		*value = 0;
		break;
	case CU_DEVICE_ATTRIBUTE_MAX_SHARED_MEMORY_PER_BLOCK_OPTIN:
		*value = 99 * 1024;
		break;
	case CU_DEVICE_ATTRIBUTE_VIRTUAL_MEMORY_MANAGEMENT_SUPPORTED:
		*value = 1;
		break;
	default:
		return (CUDA_ERROR_NOT_SUPPORTED);
	}
	return (CUDA_SUCCESS);
}

/* This provider is the synthetic kind: the registry hands it the profiles
 * named by CUDA_NATIVE_FAKE_PROFILE, and it applies them.  The provider
 * itself reads no environment variable, so the capability the library
 * reports and the selection the provider applies cannot drift apart. */
const cuda_provider cuda_fake_provider = {
	.backend = "fake",
	.kind = CUDA_PROVIDER_SYNTHETIC,
	.select = fake_select,
	.enumerate = fake_enumerate,
	.name = fake_name,
	.uuid = fake_uuid,
	.memory = fake_memory,
	.attribute = fake_attribute
};

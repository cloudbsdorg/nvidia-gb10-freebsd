/* gdb_platform.c - the register of the platform providers.
 *
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The register, and nothing else.  It names no platform and calls no
 * system of one: a provider is a pointer that a provider gave us.
 */
#include <stdlib.h>
#include <string.h>

#include "gdb_platform.h"

#define GDB_MAX_PLATFORMS	8

static const struct gdb_platform_ops *gdb_platforms[GDB_MAX_PLATFORMS];
static int gdb_nplatforms;

int
gdb_platform_register(const struct gdb_platform_ops *ops)
{
	int i;

	if (ops == NULL || ops->name == NULL || ops->snapshot == NULL)
		return (-1);
	for (i = 0; i < gdb_nplatforms; i++) {
		if (strcmp(gdb_platforms[i]->name, ops->name) == 0) {
			/* The same provider again: the later one wins. */
			gdb_platforms[i] = ops;
			return (0);
		}
	}
	if (gdb_nplatforms >= GDB_MAX_PLATFORMS)
		return (-1);
	gdb_platforms[gdb_nplatforms++] = ops;
	return (0);
}

const struct gdb_platform_ops *
gdb_platform_find(const char *name)
{
	int i;

	if (name == NULL)
		return (NULL);
	for (i = 0; i < gdb_nplatforms; i++) {
		if (strcmp(gdb_platforms[i]->name, name) == 0)
			return (gdb_platforms[i]);
	}
	return (NULL);
}

char *
gdb_platform_names(void)
{
	char *out;
	size_t len = 1;
	int i;

	for (i = 0; i < gdb_nplatforms; i++)
		len += strlen(gdb_platforms[i]->name) + 1;
	out = calloc(1, len);
	if (out == NULL)
		return (NULL);
	for (i = 0; i < gdb_nplatforms; i++) {
		strcat(out, gdb_platforms[i]->name);
		strcat(out, "\n");
	}
	return (out);
}

const char *
gdb_platform_default(void)
{
	/* The provider that says it is the default wins; otherwise the
	 * first one that was registered. */
	int i;

	for (i = 0; i < gdb_nplatforms; i++) {
		if (strcmp(gdb_platforms[i]->name, "fake") == 0)
			continue;
		return (gdb_platforms[i]->name);
	}
	if (gdb_nplatforms > 0)
		return (gdb_platforms[0]->name);
	return (NULL);
}

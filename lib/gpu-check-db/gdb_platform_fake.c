/* gdb_platform_fake.c - a machine that is not there.
 *
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * A provider that answers with a fixed set of properties, so a test
 * has something to look at without a machine behind it.  It is also the
 * proof that the core of the library holds nothing of an operating
 * system: the library builds and works with this provider alone.
 *
 * The properties are of the three kinds the tool knows: a constant one,
 * a changing one and a counter.  The counter goes up every time the
 * machine is asked, and the changing one goes up and down, so a test
 * can tell the three apart.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "gdb_platform.h"

/* How many times the machine was asked.  The counter of the machine is
 * this number, and the changing property is this number in base two.
 * The state is of the file and not of the handle: the provider is
 * opened again for every snapshot, and the machine is the same one. */
static long fake_seen;

struct fake_state {
	int	seen;
};

static void *
fake_open(char *err, size_t errlen)
{
	struct fake_state *state;

	(void)err;
	(void)errlen;
	state = calloc(1, sizeof(*state));
	if (state == NULL)
		return (NULL);
	return (state);
}

static void
fake_close(void *handle)
{
	free(handle);
}

/* The properties of the machine that is not there. */
static int
fake_snapshot(void *handle, gdb_platform_emit emit, void *ctx, char *err,
    size_t errlen)
{
	struct fake_state *state = handle;
	struct gdb_value value;
	static const struct {
		const char	*source;
		const char	*key;
		const char	*kind;
		const char	*text;
		long long	 number;
	} properties[] = {
		{ "sysctl", "hw.ncpu", GDB_KIND_INT, NULL, 4 },
		{ "sysctl", "hw.nvme.verbose_cmd_dump", GDB_KIND_INT, NULL, 0 },
		{ "sysctl", "kern.ostype", GDB_KIND_STRING, "FreeBSD", 0 },
		{ "sysctl", "kern.osrelease", GDB_KIND_STRING, "16.0-CURRENT", 0 },
		{ "uname", "machine", GDB_KIND_STRING, "arm64", 0 },
		{ "uname", "sysname", GDB_KIND_STRING, "FreeBSD", 0 },
		{ "kenv", "fake.setting", GDB_KIND_STRING, "yes", 0 },
		{ "loader", "fake.tunable", GDB_KIND_STRING, "1", 0 }
	};
	size_t i;

	(void)err;
	(void)errlen;
	if (state == NULL)
		return (-1);
	state->seen++;
	fake_seen++;
	for (i = 0; i < sizeof(properties) / sizeof(properties[0]); i++) {
		memset(&value, 0, sizeof(value));
		value.kind = properties[i].kind;
		if (properties[i].text != NULL) {
			value.text = properties[i].text;
		} else {
			value.ivalue = properties[i].number;
		}
		if (emit(ctx, properties[i].source, properties[i].key, &value) != 0)
			return (-1);
	}
	/* The counter: it goes up every time the machine is asked, so a
	 * test can see that a counter is not a change of value. */
	memset(&value, 0, sizeof(value));
	value.kind = GDB_KIND_INT;
	value.ivalue = fake_seen;
	if (emit(ctx, "sysctl", "vm.stats.count", &value) != 0)
		return (-1);
	/* The changing one: it goes up and down, so a test can see that
	 * a property that changes is not a counter. */
	memset(&value, 0, sizeof(value));
	value.kind = GDB_KIND_INT;
	value.ivalue = fake_seen % 2;
	if (emit(ctx, "sysctl", "fake.ticker", &value) != 0)
		return (-1);
	return (0);
}

static const struct gdb_platform_ops gdb_platform_fake_ops = {
	"fake",
	"A machine that is not there: the same properties every time",
	fake_open,
	fake_close,
	fake_snapshot
};

/* The provider says so itself when the library is loaded. */
__attribute__((constructor)) static void
gdb_platform_fake_register(void)
{
	gdb_platform_register(&gdb_platform_fake_ops);
}

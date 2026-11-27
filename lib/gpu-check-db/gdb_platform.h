/* gdb_platform.h - what a machine can be asked.
 *
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The core of the database knows nothing of an operating system.  What
 * a machine can be asked is the work of a platform provider, and a
 * provider says so itself: it registers itself when the library is
 * loaded.  The core asks for a provider by name and never names one.
 *
 * A provider answers with properties: a source (where the fact came
 * from), a key (what it is called there) and a value (what it holds).
 * The value has a kind, so a number is never read as text.
 *
 * To write a provider for another operating system, see
 * docs/GPU-CHECK-PLATFORMS.md.
 */
#ifndef GDB_PLATFORM_H
#define GDB_PLATFORM_H

#include <stddef.h>

#include "gdb.h"

/* The answer of a provider: one property.  The callback returns zero
 * when all is well and a negative number when the walk has to stop. */
typedef int (*gdb_platform_emit)(void *ctx, const char *source,
    const char *key, const struct gdb_value *value);

/* What a provider has to offer. */
struct gdb_platform_ops {
	/* The name the database knows this platform by.  It is the name
	 * of a row of the platforms table. */
	const char	*name;
	/* A sentence about it, for the table of the platforms. */
	const char	*description;
	/* Open the machine.  The handle is given back to the other two
	 * calls.  A provider that needs nothing returns a handle of
	 * NULL, and that is not an error. */
	void		*(*open)(char *err, size_t errlen);
	/* Close what open opened. */
	void		 (*close)(void *handle);
	/* Walk the machine and answer with every property it holds. */
	int		 (*snapshot)(void *handle, gdb_platform_emit emit,
			    void *ctx, char *err, size_t errlen);
};

/* Register a provider.  A provider calls this when its library is
 * loaded; the core never calls it. */
int			 gdb_platform_register(const struct gdb_platform_ops *ops);

/* The provider with that name, or NULL. */
const struct gdb_platform_ops *gdb_platform_find(const char *name);

/* The names of the providers that are registered, one per line, each
 * one followed by a newline.  The caller frees it. */
char			*gdb_platform_names(void);

/* The name of the platform this library was built for.  It is the
 * default when a run does not name one. */
const char		*gdb_platform_default(void);

#endif /* GDB_PLATFORM_H */

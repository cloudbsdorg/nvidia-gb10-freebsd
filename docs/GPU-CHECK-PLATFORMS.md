# Porting gpu-check to another operating system

The core of the database library, the event stream, the schema and the outputs know nothing of an
operating system. Everything that needs one is behind a **platform provider**: a small object
with three calls that a provider registers for itself when its library is loaded.

There are two providers in the tree today:

- `lib/gpu-check-db/gdb_platform_freebsd.c` — the FreeBSD machine;
- `lib/gpu-check-db/gdb_platform_fake.c` — a machine that is not there, used by the tests and
  by the fake-only build.

A third one is a file of about three hundred lines and a constructor. This file says what it
has to do.

## 1. The rule

The core never names an operating system. Not in a header, not in a statement, not in a string
that reaches an output.

The test `(h) the core of the library holds no header of an operating system` greps every core
file for `<sys/`, `<machine/`, `<linux/`, `<os/`, `<windows.h>` and for the names of the calls
that only one operating system has. The test `(i) the library with only the fake provider holds
no provider of an operating system` builds the library with the fake provider alone and greps
the result the same way. A provider that puts a FreeBSD header in the core fails the build.

## 2. The interface

The provider fills in a `struct gdb_platform_ops` and registers it:

```c
#include "gdb_platform.h"

static void *
my_open(char *err, size_t errlen)
{
	return (NULL);			/* nothing to open: not an error */
}

static void
my_close(void *handle)
{
}

static int
my_snapshot(void *handle, gdb_platform_emit emit, void *ctx,
    char *err, size_t errlen)
{
	struct gdb_value value;

	value.kind = GDB_KIND_INT;
	value.ivalue = 42;
	/* The text of a value is borrowed: it is valid during the call
	 * and not a moment longer. */
	value.text = NULL;
	if (emit(ctx, "sysctl", "kern.hostname", &value) != 0)
		return (-1);
	return (0);
}

static const struct gdb_platform_ops my_ops = {
	.name		= "myos",
	.description	= "My operating system",
	.open		= my_open,
	.close		= my_close,
	.snapshot	= my_snapshot,
};

__attribute__((constructor)) static void
my_register(void)
{
	gdb_platform_register(&my_ops);
}
```

The three calls:

| call | what it does | what it may return |
|---|---|---|
| `open` | open the machine | a handle, or `NULL` when there is nothing to open. `NULL` is **not** an error |
| `close` | close what `open` opened | nothing |
| `snapshot` | walk the machine and answer with every property it holds | zero when the walk is done, a negative number when it has to stop |

`emit()` returns zero when all is well. A provider that stops early returns a negative number and
the core stops the walk.

### The value

```c
struct gdb_value {
	const char	*kind;		/* GDB_KIND_INT, GDB_KIND_UINT,
					 * GDB_KIND_NUMBER or GDB_KIND_STRING */
	long long	ivalue;		/* for INT and UINT */
	double		nvalue;		/* for NUMBER */
	const char	*text;		/* for STRING */
};
```

**The text of a value is borrowed.** It is valid during the call of `emit()` and not a moment
longer. A provider that builds the text on the stack is right; a provider that frees it right
after `emit()` returns is right; a provider that keeps it and frees it later is wrong, and the
core will read freed memory.

The kind of a value is what the database stores. A number is never read as text, and a text that
holds a number is still a text: the kind of a key is fixed the first time the key is seen, and a
key that is another kind later is a mismatch (see
[`GPU-CHECK-DB.md`](GPU-CHECK-DB.md#7-the-properties)).

### The source and the key

A property is a **source** (where the fact came from), a **key** (what it is called there) and a
**value**. The source and the key are strings. The same key may name one thing in one source and
another thing in another source, so the pair is what identifies a property.

The sources that the FreeBSD provider uses, and the ones a provider is expected to use:

| source | what it holds |
|---|---|
| `sysctl` | the tree of the kernel parameters, and nothing else |
| `kenv` | the environment of the kernel |
| `loader` | the environment of the loader |
| `uname` | what the kernel says it is |
| `kldstat` | the modules that are loaded, and the version of each |
| `pciconf` | the devices of the bus |

A provider may use others. A source is a row of the `sources` table, and a new source is a new
row: nothing else has to change.

The key is the name of the thing in that source. For the sysctl tree it is the dotted name, such
as `kern.maxvnodes`. For the module list it is the name of the module.

## 3. What a provider has to do

The FreeBSD provider walks six things, and a provider for another operating system walks the
six things of that operating system:

1. **the tree of the kernel parameters.** The whole tree, not a part of it. The FreeBSD provider
   walks the `CTL_SYSCTL_NEXT` node of `sysctl(3)`, so it reads every value by its own OID and
   never parses the text of `sysctl -a`. A provider for another operating system reads its own
   tree through its own call.
2. **the devices of the bus.** The PCI devices, with their vendor and device numbers.
3. **the modules that are loaded,** with the version of each.
4. **the environment of the kernel.**
5. **the environment of the loader,** the tunables that were set at boot.
6. **what the kernel says it is:** the name of the system, the release and the machine.

The order does not matter. What matters is that a snapshot answers with every property of the
machine, so that two snapshots can be compared and the properties that came and went can be
found.

### A provider that may not read everything

A provider that is not allowed to read a tree says so and goes on. The FreeBSD provider, run as
a user on a machine with `security.bsd.unprivileged_kenv_read=0`, records the sysctl tree, the
module list, the bus and the name of the system, and leaves the two environments out. A run is
never refused because a tree could not be read.

The rule is that a provider never fails a run for a tree it could not read. It may fail for a
tree it was asked to read and could not open at all, and then it returns a negative number with
a reason in `err`.

## 4. How a provider is chosen

The name of the platform is the name of a row of the `platforms` table, and the core asks for
the provider with that name. A run that names no platform uses the provider the library was
built for (`gdb_platform_default()`).

The provider of a run is chosen by the Python side, which asks the library for the names of the
providers that are registered. The names are in the `registry.providers` array of the document.

## 5. Building a provider

The FreeBSD provider is built into `libgpubcheckdb.so.1`. The fake provider is built on its own:

```sh
cd lib/gpu-check-db/fake && make
```

which produces `libgpubcheckdb_fake.so` with the core and the fake provider and nothing else.
The Python side picks the library with the environment:

| variable | what it holds |
|---|---|
| `GPU_CHECK_DB_LIB` | the library to load |
| `GPU_CHECK_DB_PLATFORM` | the provider to ask for; `fake` loads `libgpubcheckdb_fake.so` |
| `GPU_CHECK_DB_SCHEMA` | the directory of the migrations |
| `GPU_CHECK_DB_PREFIX` | where the files live; `/usr/local` by default |

A provider that is a library of its own is loaded with `dlopen()` and registers itself through
its constructor. The core never calls `gdb_platform_register()`: the provider calls it.

## 6. The checks that hold a provider to this

| check | what it holds the provider to |
|---|---|
| `(h) the core of the library holds no header of an operating system` | the core files name no operating system |
| `(i) the library with only the fake provider holds no provider of an operating system` | the fake-only build is free of the FreeBSD provider |
| the fake-only build | the library links and the tests run with `GPU_CHECK_DB_PLATFORM=fake` |
| the run against the fake provider | the events, the document and the database are the same shape as with a real provider |

## 7. What is not in a provider

A provider answers what a machine holds. It does not decide anything:

- it does not load a module;
- it does not write a file;
- it does not read the catalogue of the checks;
- it does not know what a card is.

The checks live in the library of the tool (`lib/gpu-check/gpu_check/`), the decision lives in the
provider records under `data/providers`, and the probes live in `scripts/adapters/`. A provider
that starts deciding is a provider that has to be rewritten for the next operating system.

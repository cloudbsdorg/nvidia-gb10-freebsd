/* gdb_platform_freebsd.c - what a FreeBSD machine can be asked.
 *
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * This is the only file of the library that knows FreeBSD.  It reads:
 *
 *   sysctl    the whole tree, walked with sysctl(3) through the
 *             CTL_SYSCTL_NEXT node: the text of "sysctl -a" is never
 *             parsed, and every value is read by its own OID;
 *   kenv      the kernel environment, through the kenv(2) syscall;
 *   loader    the environment of the loader, through the same syscall;
 *   uname     what the kernel says it is;
 *   kldstat   the modules that are loaded, and the version of each;
 *   pciconf   the devices of the PCI bus.
 *
 * A provider for another operating system does the same six things its
 * own way: see docs/GPU-CHECK-PLATFORMS.md.
 */
#include <sys/param.h>
#include <sys/sysctl.h>
#include <sys/types.h>
#include <sys/utsname.h>

#include <sys/kenv.h>
#include <sys/syscall.h>

#include <ctype.h>
#include <errno.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "gdb_platform.h"

#define FBSD_MAX_OID		CTL_MAXNAME
#define FBSD_NAME_MAX		512
#define FBSD_VALUE_MAX		(256 * 1024)
#define FBSD_HEX_BYTES		64
#define FBSD_KENV_MAX		(1024 * 1024)

/* The state of one run of the provider. */
struct fbsd_state {
	int		seen;
};

static void *
fbsd_open(char *err, size_t errlen)
{
	struct fbsd_state *state;

	(void)err;
	(void)errlen;
	state = calloc(1, sizeof(*state));
	if (state == NULL)
		return (NULL);
	return (state);
}

static void
fbsd_close(void *handle)
{
	free(handle);
}

/* --- the sysctl tree ------------------------------------------------------ */

/* The next node of the tree, depth first.  The kernel walks the tree
 * for us: we hand it the OID we are standing on and it gives us the
 * next one. */
static int
fbsd_next_oid(int *oid, int oidlen, int *out, int outmax)
{
	int mib[FBSD_MAX_OID + 2];
	size_t len = (size_t)outmax * sizeof(int);
	int i;

	mib[0] = CTL_SYSCTL;
	mib[1] = CTL_SYSCTL_NEXT;
	for (i = 0; i < oidlen && i < FBSD_MAX_OID; i++)
		mib[2 + i] = oid[i];
	if (sysctl(mib, 2 + oidlen, out, &len, NULL, 0) != 0)
		return (-1);
	return ((int)(len / sizeof(int)));
}

/* The dotted name of a node. */
static int
fbsd_oid_name(const int *oid, int oidlen, char *buf, size_t bufsz)
{
	int mib[FBSD_MAX_OID + 2];
	size_t len = bufsz - 1;
	int i;

	mib[0] = CTL_SYSCTL;
	mib[1] = CTL_SYSCTL_NAME;
	for (i = 0; i < oidlen && i < FBSD_MAX_OID; i++)
		mib[2 + i] = oid[i];
	buf[0] = '\0';
	if (sysctl(mib, 2 + oidlen, buf, &len, NULL, 0) != 0)
		return (-1);
	buf[len < bufsz ? len : bufsz - 1] = '\0';
	return (0);
}

/* The kind of a node and the format of its value.  The kernel gives
 * both: the kind first, as an integer that holds the flags of the node
 * as well, and then the format, as the text of a few letters.  The kind
 * is the low bits of the integer; the letters say whether the number
 * is signed ("I", "L") or not ("IU", "LU"). */
static int
fbsd_oid_kind(const int *oid, int oidlen, int *kind, char *fmt, size_t fmtsz)
{
	unsigned char buf[64];
	int mib[FBSD_MAX_OID + 2];
	size_t len = sizeof(buf);
	size_t flen;
	size_t n;
	unsigned int raw;
	int i;

	if (fmtsz < 2)
		return (-1);
	mib[0] = CTL_SYSCTL;
	mib[1] = CTL_SYSCTL_OIDFMT;
	for (i = 0; i < oidlen && i < FBSD_MAX_OID; i++)
		mib[2 + i] = oid[i];
	if (sysctl(mib, 2 + oidlen, buf, &len, NULL, 0) != 0)
		return (-1);
	if (len < sizeof(raw) + 1)
		return (-1);
	memcpy(&raw, buf, sizeof(raw));
	*kind = (int)(raw & CTLTYPE);
	/* The format is a text of letters that ends with a NUL. */
	flen = len - sizeof(raw);
	n = strnlen((const char *)buf + sizeof(raw), flen);
	if (n >= fmtsz)
		n = fmtsz - 1;
	memcpy(fmt, buf + sizeof(raw), n);
	fmt[n] = '\0';
	return (0);
}

/* The value of a node, read by its own OID. */
static int
fbsd_oid_value(const int *oid, int oidlen, unsigned char **out, size_t *outlen)
{
	unsigned char *buf;
	size_t len = 4096;

	*out = NULL;
	*outlen = 0;
	buf = malloc(len + 1);
	if (buf == NULL)
		return (-1);
	if (sysctl(oid, oidlen, buf, &len, NULL, 0) == 0) {
		buf[len] = '\0';
		*out = buf;
		*outlen = len;
		return (0);
	}
	if (errno != ENOMEM) {
		free(buf);
		return (-1);
	}
	/* The kernel says how much it wants. */
	if (len > FBSD_VALUE_MAX)
		len = FBSD_VALUE_MAX;
	free(buf);
	buf = malloc(len + 1);
	if (buf == NULL)
		return (-1);
	if (sysctl(oid, oidlen, buf, &len, NULL, 0) != 0) {
		free(buf);
		return (-1);
	}
	buf[len] = '\0';
	*out = buf;
	*outlen = len;
	return (0);
}

/* The widths the kernel may give a number in. */
static int
fbsd_number_width(size_t len)
{
	switch (len) {
	case 1:
	case 2:
	case 4:
	case 8:
		return (0);
	default:
		return (-1);
	}
}

/* A number of the width the kernel gave, signed or not.
 *
 * There is one function and not a copy per signedness: the width of the
 * value and its signedness are two arguments, and the sign of the value
 * is carried by the top bit of its last byte. */
static int
fbsd_number(const unsigned char *buf, size_t len, int is_signed,
    long long *out)
{
	uint64_t raw = 0;

	if (fbsd_number_width(len) != 0)
		return (-1);
	memcpy(&raw, buf, len);
	if (is_signed && len < sizeof(raw)) {
		/* The bits above the width the kernel gave are the sign
		 * of the value, not zeros. */
		unsigned int bits = (unsigned int)(len * 8);
		uint64_t sign = raw & ((uint64_t)1 << (bits - 1));

		if (sign != 0)
			raw |= ~(((uint64_t)1 << bits) - 1);
	}
	*out = (long long)raw;
	return (0);
}

/* The kinds of the tree that hold a number, and whether the number is
 * signed.  The list is a table and not a chain of cases: a case for each
 * kind is a function that grows with every kind the tree has. */
static const struct {
	int ctl;
	int is_signed;
} fbsd_numbers[] = {
	{ CTLTYPE_INT, 1 }, { CTLTYPE_UINT, 0 },
	{ CTLTYPE_S64, 1 }, { CTLTYPE_U64, 0 },
	{ CTLTYPE_LONG, 1 }, { CTLTYPE_ULONG, 0 },
	{ CTLTYPE_U8, 0 }, { CTLTYPE_U16, 0 }, { CTLTYPE_U32, 0 },
	{ CTLTYPE_S8, 1 }, { CTLTYPE_S16, 1 }, { CTLTYPE_S32, 1 }
};

/* A text value: the buffer of the node, without the zeros at its end. */
static int
fbsd_value_string(unsigned char *buf, size_t len, struct gdb_value *value)
{
	size_t n = len;

	while (n > 0 && buf[n - 1] == '\0')
		n--;
	buf[n] = '\0';
	value->kind = GDB_KIND_STRING;
	value->text = (const char *)buf;
	return (0);
}

/* A number: the kind of the node says whether it is signed. */
static int
fbsd_value_number(unsigned char *buf, size_t len, int kind, const char *fmt,
    struct gdb_value *value)
{
	size_t i;
	long long number;

	for (i = 0; i < sizeof(fbsd_numbers) / sizeof(fbsd_numbers[0]); i++) {
		if (fbsd_numbers[i].ctl != kind)
			continue;
		if (fbsd_numbers[i].is_signed) {
			if (fbsd_number(buf, len, 1, &number) != 0)
				return (-1);
			value->kind = (kind == CTLTYPE_INT &&
			    strchr(fmt, 'U') != NULL) ? GDB_KIND_UINT :
			    GDB_KIND_INT;
		} else {
			if (fbsd_number(buf, len, 0, &number) != 0)
				return (-1);
			value->kind = GDB_KIND_UINT;
		}
		value->ivalue = number;
		return (0);
	}
	return (-1);
}

/* A value the tree does not explain: the bytes of it, as they are. */
static int
fbsd_value_opaque(unsigned char *buf, size_t len, char *scratch,
    size_t scratchsz, struct gdb_value *value)
{
	size_t keep = len;
	size_t i;

	if (keep > FBSD_HEX_BYTES)
		keep = FBSD_HEX_BYTES;
	if (keep * 2 + 1 > scratchsz)
		return (-1);
	for (i = 0; i < keep; i++) {
		static const char hex[] = "0123456789abcdef";

		scratch[i * 2] = hex[(buf[i] >> 4) & 0xf];
		scratch[i * 2 + 1] = hex[buf[i] & 0xf];
	}
	scratch[keep * 2] = '\0';
	value->kind = GDB_KIND_STRING;
	value->text = scratch;
	return (0);
}

/* The value of a node, in the kind the node has.  The text of the
 * value is not copied: it is borrowed from the buffer of the node and
 * is good as long as the callback that receives it lasts. */
static int
fbsd_value_of(unsigned char *buf, size_t len, int kind, const char *fmt,
    char *scratch, size_t scratchsz, struct gdb_value *value)
{
	memset(value, 0, sizeof(*value));
	if (kind == CTLTYPE_STRING)
		return (fbsd_value_string(buf, len, value));
	if (kind == CTLTYPE_OPAQUE)
		return (fbsd_value_opaque(buf, len, scratch, scratchsz, value));
	return (fbsd_value_number(buf, len, kind, fmt, value));
}

/* The whole tree, one property at a time. */
static int
fbsd_collect_sysctl(gdb_platform_emit emit, void *ctx, char *err,
    size_t errlen)
{
	int oid[FBSD_MAX_OID];
	int next[FBSD_MAX_OID];
	char name[FBSD_NAME_MAX];
	char fmt[16];
	char scratch[FBSD_HEX_BYTES * 2 + 1];
	int oidlen = 0;
	long nodes = 0;

	for (;;) {
		int n, kind;
		unsigned char *buf;
		size_t len;
		struct gdb_value value;

		n = fbsd_next_oid(oid, oidlen, next, FBSD_MAX_OID);
		if (n < 0) {
			if (errno == ENOENT)
				break;
			snprintf(err, errlen, "the sysctl tree cannot be walked: %s",
			    strerror(errno));
			return (-1);
		}
		if (n <= 0)
			break;
		memcpy(oid, next, (size_t)n * sizeof(int));
		oidlen = n;
		nodes++;
		if (fbsd_oid_name(oid, oidlen, name, sizeof(name)) != 0)
			continue;
		/* The name of a node is the name of a key. */
		if (fbsd_oid_kind(oid, oidlen, &kind, fmt, sizeof(fmt)) != 0)
			continue;
		if (kind == CTLTYPE_NODE)
			continue;
		if (fbsd_oid_value(oid, oidlen, &buf, &len) != 0)
			continue;
		if (fbsd_value_of(buf, len, kind, fmt, scratch, sizeof(scratch),
		    &value) != 0) {
			free(buf);
			continue;
		}
		if (emit(ctx, "sysctl", name, &value) != 0) {
			free(buf);
			return (-1);
		}
		free(buf);
	}
	(void)nodes;
	return (0);
}

/* --- the kernel environment ---------------------------------------------- */

/* The environment of the kernel or of the loader.  The kenv(2) syscall
 * gives it: what it holds is a list of names and values, each one
 * ended by a NUL. */
static int
fbsd_collect_kenv(int what, const char *source, gdb_platform_emit emit,
    void *ctx, char *err, size_t errlen)
{
	char *buf;
	size_t len = FBSD_KENV_MAX;
	size_t used = 0;
	int rc;

	buf = malloc(len);
	if (buf == NULL) {
		snprintf(err, errlen, "there is no memory for the environment");
		return (-1);
	}
	rc = (int)syscall(SYS_kenv, what, (const char *)NULL, buf, (int)len);
	if (rc < 0) {
		/* The syscall is not everywhere yet, and the environment
		 * may be closed to this user.  Neither is a failure of
		 * the walk: there is simply nothing to record. */
		free(buf);
		return (0);
	}
	used = (size_t)rc;
	/* The environment is a list of "name=value" entries, each one
	 * ended by a NUL, and the list itself ends with an empty one. */
	{
		size_t start = 0;

		while (start < used) {
			char *entry = buf + start;
			size_t elen = strnlen(entry, used - start);
			char *eq;
			const char *name;
			const char *value;
			struct gdb_value gvalue;

			start += elen + 1;
			if (elen == 0)
				continue;
			eq = strchr(entry, '=');
			if (eq == NULL)
				continue;
			*eq = '\0';
			name = entry;
			value = eq + 1;
			memset(&gvalue, 0, sizeof(gvalue));
			gvalue.kind = GDB_KIND_STRING;
			gvalue.text = value;
			if (emit(ctx, source, name, &gvalue) != 0)
				break;
		}
	}
	free(buf);
	return (0);
}

/* --- the kernel ------------------------------------------------------------ */

static int
fbsd_collect_uname(gdb_platform_emit emit, void *ctx)
{
	struct utsname name;
	static const struct {
		const char	*key;
		size_t		 offset;
	} fields[] = {
		{ "sysname", offsetof(struct utsname, sysname) },
		{ "machine", offsetof(struct utsname, machine) },
		{ "release", offsetof(struct utsname, release) },
		{ "version", offsetof(struct utsname, version) }
	};
	size_t i;

	if (uname(&name) != 0)
		return (-1);
	for (i = 0; i < sizeof(fields) / sizeof(fields[0]); i++) {
		struct gdb_value value;
		const char *text = (const char *)((const char *)&name +
		    fields[i].offset);

		memset(&value, 0, sizeof(value));
		value.kind = GDB_KIND_STRING;
		value.text = text;
		if (emit(ctx, "uname", fields[i].key, &value) != 0)
			return (-1);
	}
	return (0);
}

/* --- the modules ----------------------------------------------------------- */

/* The modules that are loaded, with the version of each.  kldstat(8)
 * prints them: a line holds the number, the references, the address,
 * the size, the name and the path of a module, and the line that
 * follows it holds the version of the module, when it has one. */
static int
fbsd_collect_kldstat(gdb_platform_emit emit, void *ctx)
{
	FILE *pipe;
	char line[1024];
	char pending[256];
	int have = 0;

	pipe = popen("/sbin/kldstat -v 2>/dev/null", "r");
	if (pipe == NULL)
		return (0);
	pending[0] = '\0';
	while (fgets(line, sizeof(line), pipe) != NULL) {
		char *p = line;
		char *paren;
		char *last;

		while (*p == ' ' || *p == '\t')
			p++;
		if (*p == '\0' || *p == '\n')
			continue;
		if (strncmp(p, "Version:", 8) == 0) {
			struct gdb_value value;
			char *text = p + 8;
			char key[320];

			if (!have)
				continue;
			while (*text == ' ' || *text == '\t')
				text++;
			text[strcspn(text, "\r\n")] = '\0';
			memset(&value, 0, sizeof(value));
			value.kind = GDB_KIND_STRING;
			value.text = text;
			snprintf(key, sizeof(key), "%s.version", pending);
			if (emit(ctx, "kldstat", key, &value) != 0)
				break;
			continue;
		}
		if (!isdigit((unsigned char)*p))
			continue;
		paren = strchr(p, '(');
		if (paren != NULL)
			*paren = '\0';
		last = strrchr(p, ' ');
		if (last == NULL)
			continue;
		*last = '\0';
		snprintf(pending, sizeof(pending), "%s", last + 1);
		have = 1;
		/* The path of the module, when the line named one. */
		if (paren != NULL) {
			struct gdb_value value;
			char key[320];
			char *path = paren + 1;
			char *close = strchr(path, ')');

			if (close != NULL)
				*close = '\0';
			memset(&value, 0, sizeof(value));
			value.kind = GDB_KIND_STRING;
			value.text = path;
			snprintf(key, sizeof(key), "%s.path", pending);
			if (emit(ctx, "kldstat", key, &value) != 0)
				break;
		}
	}
	pclose(pipe);
	return (0);
}

/* --- the PCI bus ------------------------------------------------------------ */

/* The devices of the PCI bus.  pciconf(8) prints them; the first line
 * of a device holds everything there is to know about it. */
static int
fbsd_collect_pciconf(gdb_platform_emit emit, void *ctx)
{
	FILE *pipe;
	char line[2048];

	pipe = popen("/usr/sbin/pciconf -lv 2>/dev/null", "r");
	if (pipe == NULL)
		return (0);
	while (fgets(line, sizeof(line), pipe) != NULL) {
		char *at;
		char *newline;
		struct gdb_value value;

		newline = strpbrk(line, "\r\n");
		if (newline != NULL)
			*newline = '\0';
		if (line[0] == '\0')
			continue;
		at = strchr(line, '@');
		if (at == NULL)
			continue;
		/* The name of the device is what is before the at sign;
		 * the slot is what is after it. */
		*at = '\0';
		memset(&value, 0, sizeof(value));
		value.kind = GDB_KIND_STRING;
		value.text = at + 1;
		if (emit(ctx, "pciconf", line, &value) != 0)
			break;
	}
	pclose(pipe);
	return (0);
}

/* --- the provider ---------------------------------------------------------- */

static int
fbsd_snapshot(void *handle, gdb_platform_emit emit, void *ctx, char *err,
    size_t errlen)
{
	struct fbsd_state *state = handle;

	if (state == NULL)
		return (-1);
	state->seen++;
	if (fbsd_collect_sysctl(emit, ctx, err, errlen) != 0)
		return (-1);
	if (fbsd_collect_kenv(KENV_DUMP, "kenv", emit, ctx, err, errlen) != 0)
		return (-1);
	if (fbsd_collect_kenv(KENV_DUMP_LOADER, "loader", emit, ctx, err,
	    errlen) != 0)
		return (-1);
	if (fbsd_collect_uname(emit, ctx) != 0)
		return (-1);
	if (fbsd_collect_kldstat(emit, ctx) != 0)
		return (-1);
	if (fbsd_collect_pciconf(emit, ctx) != 0)
		return (-1);
	return (0);
}

static const struct gdb_platform_ops gdb_platform_freebsd_ops = {
	"freebsd",
	"FreeBSD: the sysctl tree, the kernel environment, the loader, the"
	" kernel, the modules and the PCI bus",
	fbsd_open,
	fbsd_close,
	fbsd_snapshot
};

/* The provider says so itself when the library is loaded. */
__attribute__((constructor)) static void
gdb_platform_freebsd_register(void)
{
	gdb_platform_register(&gdb_platform_freebsd_ops);
}

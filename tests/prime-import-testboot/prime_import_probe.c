/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-3-Clause
 *
 * prime_import_probe - cross-GPU buffer import probe (Track #2228,
 * docs/PRIME-IMPORT.md, section 5.2).  Creates a dumb buffer on one DRM
 * card, fills it, exports it as a dma-buf (PRIME), imports it on a second
 * card and adds a framebuffer for the imported handle, and reports every
 * step.  It never sets a mode and never touches a CRTC.  See
 * prime_import_probe(8).
 *
 *   prime_import_probe [--json | --jsonl] [-s WxH]... SRC DST
 *
 * Build: cc -o prime_import_probe prime_import_probe.c \
 *        -I/usr/local/include -I/usr/local/include/libdrm \
 *        -L/usr/local/lib -ldrm
 *
 * Exit status: 0 when every step returned (with success or an errno),
 * 2 on a usage error, 3 when a card cannot be opened.
 */
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>

#include <xf86drm.h>
#include <xf86drmMode.h>
#include <drm_fourcc.h>

#define SCHEMA		"prime-import-probe/1"
#define MAXSIZES	16

struct size {
	unsigned	w;
	unsigned	h;
};

struct row {
	const char	*src;
	const char	*dst;
	unsigned	w, h;
	uint64_t	bytes;
	int		create, map, fill, export, import, addfb;
	int		err;		/* the first errno, 0 when none */
	const char	*stage;		/* where it stopped, or "done" */
};

static void
usage(FILE *f)
{
	fprintf(f, "usage: prime_import_probe [--json | --jsonl] [-s WxH]... "
	    "SRC DST\n"
	    "  SRC, DST   DRM device nodes, for example /dev/dri/card0 and "
	    "/dev/dri/card1\n"
	    "  -s WxH     dumb buffer size (repeatable, 1 to 16384 each; default 64x64, "
	    "1920x1080)\n"
	    "  --json     one JSON document on stdout\n"
	    "  --jsonl    one JSON object per buffer size, flushed as it "
	    "is produced\n"
	    "  --help     this text\n"
	    "Imports SRC's buffer on DST and adds a framebuffer for it; sets "
	    "no mode.\n");
}

static void
probe(struct row *r, int s, int d)
{
	struct drm_mode_create_dumb cr;
	struct drm_mode_map_dumb mp;
	struct drm_mode_destroy_dumb de;
	uint32_t imported = 0, fbid = 0;
	int fd = -1;
	void *map;
	uint32_t *p;
	size_t i;

	memset(&cr, 0, sizeof(cr));
	cr.width = r->w;
	cr.height = r->h;
	cr.bpp = 32;
	r->stage = "create";
	r->create = drmIoctl(s, DRM_IOCTL_MODE_CREATE_DUMB, &cr);
	if (r->create != 0) {
		r->err = errno;
		return;
	}
	r->bytes = cr.size;

	r->stage = "map";
	memset(&mp, 0, sizeof(mp));
	mp.handle = cr.handle;
	r->map = drmIoctl(s, DRM_IOCTL_MODE_MAP_DUMB, &mp);
	if (r->map != 0) {
		r->err = errno;
		goto out;
	}
	{
		map = mmap(NULL, cr.size, PROT_READ | PROT_WRITE, MAP_SHARED,
		    s, (off_t)mp.offset);
		if (map == MAP_FAILED) {
			r->fill = -1;
			r->err = errno;
			goto out;
		} else {
			p = map;
			for (i = 0; i < cr.size / 4; i++)
				p[i] = 0xA5000000u | (uint32_t)(i & 0xFFFFFF);
			r->fill = 0;
			munmap(map, cr.size);
		}
	}

	r->stage = "export";
	r->export = drmPrimeHandleToFD(s, cr.handle, DRM_CLOEXEC, &fd);
	if (r->export != 0) {
		r->err = errno;
		goto out;
	}

	r->stage = "import";
	r->import = drmPrimeFDToHandle(d, fd, &imported);
	if (r->import != 0) {
		r->err = errno;
		goto out;
	}

	r->stage = "addfb";
	{
		uint32_t h[4] = { imported, 0, 0, 0 };
		uint32_t pitch[4] = { cr.pitch, 0, 0, 0 };
		uint32_t off[4] = { 0, 0, 0, 0 };

		r->addfb = drmModeAddFB2(d, r->w, r->h, DRM_FORMAT_XRGB8888,
		    h, pitch, off, &fbid, 0);
		if (r->addfb != 0) {
			r->err = errno;
			goto out;
		}
		(void)drmModeRmFB(d, fbid);
	}
	r->stage = "done";
out:
	if (fd >= 0)
		close(fd);
	if (imported != 0) {
		struct drm_gem_close gc = { .handle = imported };

		(void)drmIoctl(d, DRM_IOCTL_GEM_CLOSE, &gc);
	}
	memset(&de, 0, sizeof(de));
	de.handle = cr.handle;
	(void)drmIoctl(s, DRM_IOCTL_MODE_DESTROY_DUMB, &de);
}

/* A JSON string: quotes, backslashes and control characters escaped. */
static void
print_str(const char *s)
{
	putchar('"');
	for (; *s != '\0'; s++) {
		unsigned char c = (unsigned char)*s;

		if (c == '"' || c == '\\')
			printf("\\%c", c);
		else if (c < 0x20 || c == 0x7f)
			printf("\\u%04x", c);
		else
			putchar(c);
	}
	putchar('"');
}

static void
print_row(const struct row *r, int comma)
{
	printf("{\"schema\":\"%s\",\"src\":", SCHEMA);
	print_str(r->src);
	printf(",\"dst\":");
	print_str(r->dst);
	printf(",\"width\":%u,\"height\":%u,\"bytes\":%llu,"
	    "\"create\":%d,\"map\":%d,\"fill\":%d,\"export\":%d,"
	    "\"import\":%d,\"addfb\":%d,\"stage\":\"%s\",\"errno\":%d,"
	    "\"error\":", r->w, r->h, (unsigned long long)r->bytes,
	    r->create, r->map, r->fill, r->export, r->import, r->addfb,
	    r->stage, r->err);
	print_str(r->err ? strerror(r->err) : "");
	printf("}%s\n", comma ? "," : "");
}

struct args {
	struct size	sizes[MAXSIZES];
	int		nsizes;
	int		json;
	const char	*src;
	const char	*dst;
};

/* One -s WxH operand: 0 on success, -1 on a bad one. */
static int
parse_size(struct args *a, const char *arg)
{
	unsigned w, h;
	char x;

	if (a->nsizes >= MAXSIZES) {
		fprintf(stderr, "prime_import_probe: too many -s (at most %d)\n",
		    MAXSIZES);
		return (-1);
	}
	if (sscanf(arg, "%ux%u%c", &w, &h, &x) != 2 || w == 0 || h == 0 ||
	    w > 16384 || h > 16384) {
		fprintf(stderr, "prime_import_probe: bad -s operand '%s' "
		    "(WxH, each 1 to 16384)\n", arg);
		return (-1);
	}
	a->sizes[a->nsizes].w = w;
	a->sizes[a->nsizes++].h = h;
	return (0);
}

/* 0 ok, 1 --help was asked for, -1 a usage error. */
static int
parse_args(struct args *a, int argc, char **argv)
{
	int i, jsonl = 0;

	for (i = 1; i < argc; i++) {
		if (strcmp(argv[i], "--help") == 0)
			return (1);
		else if (strcmp(argv[i], "--json") == 0)
			a->json = 1;
		else if (strcmp(argv[i], "--jsonl") == 0)
			jsonl = 1;
		else if (strcmp(argv[i], "-s") == 0 && i + 1 < argc) {
			if (parse_size(a, argv[++i]) != 0)
				return (-1);
		} else if (argv[i][0] != '-' && a->src == NULL)
			a->src = argv[i];
		else if (argv[i][0] != '-' && a->dst == NULL)
			a->dst = argv[i];
		else {
			fprintf(stderr, "prime_import_probe: unexpected "
			    "argument '%s'\n", argv[i]);
			return (-1);
		}
	}
	if (a->json && jsonl) {
		fprintf(stderr, "prime_import_probe: --json and --jsonl are "
		    "exclusive\n");
		return (-1);
	}
	if (a->src == NULL || a->dst == NULL)
		return (-1);
	if (a->nsizes == 0) {
		a->sizes[0].w = 64; a->sizes[0].h = 64;
		a->sizes[1].w = 1920; a->sizes[1].h = 1080;
		a->nsizes = 2;
	}
	return (0);
}

int
main(int argc, char **argv)
{
	struct args a;
	struct row rows[MAXSIZES];
	int i, s, d, rc;

	memset(&a, 0, sizeof(a));
	rc = parse_args(&a, argc, argv);
	if (rc == 1) {
		usage(stdout);
		return (0);
	}
	if (rc != 0) {
		usage(stderr);
		return (2);
	}

	s = open(a.src, O_RDWR | O_CLOEXEC);
	d = open(a.dst, O_RDWR | O_CLOEXEC);
	if (s < 0 || d < 0) {
		fprintf(stderr, "prime_import_probe: cannot open %s: %s\n",
		    s < 0 ? a.src : a.dst, strerror(errno));
		return (3);
	}

	memset(rows, 0, sizeof(rows));
	if (a.json)
		printf("{\"schema\":\"%s\",\"rows\":[\n", SCHEMA);
	for (i = 0; i < a.nsizes; i++) {
		rows[i].src = a.src;
		rows[i].dst = a.dst;
		rows[i].w = a.sizes[i].w;
		rows[i].h = a.sizes[i].h;
		rows[i].create = rows[i].map = rows[i].fill = -1;
		rows[i].export = rows[i].import = rows[i].addfb = -1;
		rows[i].stage = "none";
		probe(&rows[i], s, d);
		print_row(&rows[i], a.json && i + 1 < a.nsizes);
		fflush(stdout);
	}
	if (a.json)
		printf("]}\n");
	close(s);
	close(d);
	return (0);
}

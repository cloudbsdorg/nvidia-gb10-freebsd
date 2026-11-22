/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * nvrm-info - list the NVIDIA GPUs through libnvrm, as text, one JSON
 * document (--json) or a JSON Lines stream (--jsonl).  See nvrm-info(8).
 *
 * After the descriptors are open the program enters capability mode, then
 * queries the GPUs again through them: what it prints was read in capability
 * mode.
 */
#include <sys/types.h>
#include <sys/capsicum.h>

#include <err.h>
#include <errno.h>
#include <getopt.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <nvrm/nvrm.h>

enum mode { M_TEXT, M_JSON, M_JSONL, M_SCHEMA };

static void
usage(FILE *fp)
{
	fprintf(fp,
	    "usage: nvrm-info [--json | --jsonl | --schema] [--backend name]\n"
	    "       nvrm-info --help\n"
	    "\n"
	    "  --json      one JSON document (schema nvrm-info/1); versions are\n"
	    "              strings plus integer parts\n"
	    "  --jsonl     JSON Lines: header, one record per GPU, end record;\n"
	    "              versions are strings plus integer parts\n"
	    "  --schema    print the JSON Schema of both outputs\n"
	    "  --backend   rm (the kernel driver) or fake (no hardware);\n"
	    "              default: NVRM_BACKEND, else rm\n"
	    "Exit status: 0 success (including no GPU attached), 1 failure\n"
	    "(a JSON error record is printed in the JSON modes), 2 usage.\n");
}

static int
text_version_reason(const nvrm_version *v)
{
	int reason;

	for (reason = 0; reason < NVRM_R__COUNT; reason++)
		if (v->reason != NULL &&
		    strcmp(v->reason, nvrm_reason_id(reason)) == 0)
			return (reason);
#ifdef NVRM_FAULT_INJECT
	abort();	/* a stored id must name a table row */
#else
	return (NVRM_R_VERSION_UNPARSED);
#endif
}

static void
text_version(const nvrm_version *v)
{
	if (v->available)
		printf("%s", v->string);
	else
		printf("unknown (%s)", nvrm_reason_text(text_version_reason(v)));
}

static void
text_value(const nvrm_field *f, const char *base)
{
	const nvrm_u64 *u = (const nvrm_u64 *)(base + f->offset);
	const nvrm_str *st = (const nvrm_str *)(base + f->offset);
	const nvrm_list *l = (const nvrm_list *)(base + f->offset);
	const nvrm_version_field *ver =
	    (const nvrm_version_field *)(base + f->offset);
	uint32_t k;

	printf("  %-22s ", f->name);
	if (f->kind == NVRM_K_U64 && NVRM_HAVE(*u))
		printf(f->hex ? "%#jx (%s)\n" : "%ju (%s)\n",
		    (uintmax_t)u->value, nvrm_source_name(u->source));
	else if (f->kind == NVRM_K_STR && NVRM_HAVE(*st))
		printf("%s (%s)\n", st->value, nvrm_source_name(st->source));
	else if (f->kind == NVRM_K_LIST && NVRM_HAVE(*l)) {
		for (k = 0; k < l->count; k++)
			printf(f->hex ? "%s%#jx" : "%s%ju", k != 0 ? " " : "",
			    (uintmax_t)l->value[k]);
		printf(" (%s)\n", nvrm_source_name(l->source));
	} else if (f->kind == NVRM_K_VERSION && ver->version.available)
		printf("%s (%s)\n", ver->version.string,
		    nvrm_source_name(ver->source));
	else if (f->kind == NVRM_K_VERSION) {
		text_version(&ver->version);
		putchar('\n');
	} else
		printf("unavailable: %s\n", nvrm_reason_text(
		    f->kind == NVRM_K_U64 ? u->reason :
		    f->kind == NVRM_K_STR ? st->reason : l->reason));
}

/* The text view walks the same field table as the JSON emitter. */
static void
text_device(const nvrm_device *dev, unsigned index)
{
	const nvrm_device_info *i = nvrm_device_info_get(dev);
	unsigned c, f;

	printf("GPU %u\n", index);
	for (f = 0; f < nvrm_info_nfields(); f++)
		text_value(nvrm_info_field(f), (const char *)i);
	for (c = 0; c < NVRM_NCAPS; c++) {
		const nvrm_u64 *cap = &i->caps[c];

		if (NVRM_HAVE(*cap))
			printf("  cap %-18s %s (%s)\n", nvrm_cap_name(c),
			    cap->value ? "yes" : "no",
			    nvrm_source_name(cap->source));
		else
			printf("  cap %-18s unavailable: %s\n",
			    nvrm_cap_name(c), nvrm_reason_text(cap->reason));
	}
	for (c = 0; c < i->ndecorators; c++)
		printf("  decorator %s\n", i->decorators[c]);
}

/* A failed write to a closed pipe is not an error of ours. */
static int
out_failed(void)
{
	return (errno == EPIPE ? 0 : 1);
}

/* Parse the options.  Returns -1 to go on, else the exit status. */
static int
parse_args(int argc, char **argv, enum mode *mode, nvrm_enum_opts *opts)
{
	static const struct option longopts[] = {
		{ "json", no_argument, NULL, 'j' },
		{ "jsonl", no_argument, NULL, 'l' },
		{ "schema", no_argument, NULL, 's' },
		{ "backend", required_argument, NULL, 'b' },
		{ "help", no_argument, NULL, 'h' },
		{ NULL, 0, NULL, 0 }
	};
	int ch, nmodes = 0;

	while ((ch = getopt_long(argc, argv, "h", longopts, NULL)) != -1) {
		switch (ch) {
		case 'j':
			*mode = M_JSON;
			nmodes++;
			break;
		case 'l':
			*mode = M_JSONL;
			nmodes++;
			break;
		case 's':
			*mode = M_SCHEMA;
			nmodes++;
			break;
		case 'b':
			opts->backend = optarg;
			break;
		case 'h':
			usage(stdout);
			return (0);
		default:
			usage(stderr);
			return (2);
		}
	}
	/* the modes exclude each other; --schema takes no backend */
	if (nmodes > 1)
		fprintf(stderr, "nvrm-info: --json, --jsonl and --schema "
		    "exclude each other\n");
	else if (*mode == M_SCHEMA && opts->backend != NULL)
		fprintf(stderr, "nvrm-info: --schema takes no --backend\n");
	if (argc != optind || nmodes > 1 ||
	    (*mode == M_SCHEMA && opts->backend != NULL)) {
		usage(stderr);
		return (2);
	}
	return (-1);
}

/* Print the GPUs in the chosen mode.  Returns 0, or -1 when output failed. */
static int
emit(nvrm_ctx *ctx, enum mode mode)
{
	unsigned i, n = nvrm_device_count(ctx);
	int rc = 0;

	switch (mode) {
	case M_JSON:
		return (nvrm_json_document(ctx, stdout));
	case M_JSONL:
		rc = nvrm_json_header(ctx, stdout);
		for (i = 0; rc == 0 && i < n; i++)
			rc = nvrm_json_device(nvrm_device_get(ctx, i), stdout);
		if (rc == 0)
			rc = nvrm_json_end(n, stdout);
		return (rc);
	default:
		printf("backend %s, built for RM ", nvrm_backend_name(ctx));
		text_version(nvrm_built_for_version());
		printf(", running RM ");
		text_version(nvrm_driver_version(ctx));
		putchar('\n');
		printf("RM API version ");
		text_version(nvrm_rm_api_version(ctx));
		putchar('\n');
		printf("library version ");
		text_version(nvrm_library_version());
		putchar('\n');
		printf("library symbol version ");
		text_version(nvrm_symbol_version());
		putchar('\n');
		printf("schema version ");
		text_version(nvrm_schema_version());
		putchar('\n');
		if (n == 0)
			printf("no GPU is attached\n");
		for (i = 0; i < n; i++)
			text_device(nvrm_device_get(ctx, i), i);
		return (fflush(stdout) == 0 ? 0 : -1);
	}
}

/* Report a failure in the chosen mode; the exit status is always 1. */
static int
report_failure(enum mode mode, const char *code, const char *msg)
{
	if (mode == M_TEXT)
		fprintf(stderr, "nvrm-info: %s\n", msg);
	else
		nvrm_json_error(code, msg, stdout);	/* EPIPE is not news */
	return (1);
}

int
main(int argc, char **argv)
{
	nvrm_enum_opts opts = { NULL, 0 };	/* no flags: least privilege */
	nvrm_ctx *ctx;
	enum mode mode = M_TEXT;
	char msg[512];
	unsigned i;
	int rc, wrote;

	rc = parse_args(argc, argv, &mode, &opts);
	if (rc >= 0)
		return (rc);
	signal(SIGPIPE, SIG_IGN);

	if (mode == M_SCHEMA)
		return (nvrm_json_schema(stdout) == 0 ? 0 : out_failed());

	rc = nvrm_enumerate(&ctx, &opts, msg, sizeof(msg));
	if (rc != NVRM_OK) {
		if (rc == NVRM_E_NOBACKEND && opts.backend == NULL)
			strlcat(msg, " (for nvrm-info: --backend fake)",
			    sizeof(msg));
		return (report_failure(mode, nvrm_error_id(rc), msg));
	}
	/* Capability mode: from here on only the open descriptors work.  A
	 * kernel without it is a failure, not a silent unsandboxed run. */
	if (cap_enter() != 0) {
		snprintf(msg, sizeof(msg), "cannot enter capability mode: %s%s",
		    strerror(errno), errno == ENOSYS ? " (this kernel lacks "
		    "Capsicum: build it with options CAPABILITY_MODE)" : "");
		nvrm_close(ctx);
		return (report_failure(mode,
		    nvrm_error_id(NVRM_E_CAPSICUM), msg));
	}
	for (i = 0; i < nvrm_device_count(ctx); i++)
		if (nvrm_device_refresh(nvrm_device_get(ctx, i)) != NVRM_OK) {
			snprintf(msg, sizeof(msg), "GPU %u: a system call to "
			    "the driver failed while reading it in capability "
			    "mode; check that the nvidia module is still "
			    "loaded (kldstat, dmesg)", i);
			nvrm_close(ctx);
			return (report_failure(mode, nvrm_error_id(NVRM_E_IO),
			    msg));
		}

	rc = emit(ctx, mode);
	wrote = rc == 0 ? 0 : out_failed();	/* before close changes errno */
	nvrm_close(ctx);
	return (wrote);
}

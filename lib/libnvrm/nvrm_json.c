/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * nvrm_json.c - JSON output of nvrm-info (schema nvrm-info/1) and the schema
 * itself.  The emitter walks nvrm_fields[]; the schema generator walks the
 * same table, so a field added to the table appears in both or in neither.
 * Every function returns 0, or -1 when the stream failed (EPIPE included);
 * output is one compact line per call, flushed.
 */
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "nvrm_internal.h"

#define SCHEMA_ID	"nvrm-info/1"
#define SCHEMA_MINOR	2
#define SCHEMA_VERSION	"1." NVRM_STRINGIFY(SCHEMA_MINOR)

static nvrm_version schema_version;
static pthread_once_t schema_once = PTHREAD_ONCE_INIT;

static void
init_schema_version(void)
{
	(void)nvrm_version_parse(SCHEMA_VERSION, 10, &schema_version);
}

const nvrm_version *
nvrm_schema_version(void)
{
	pthread_once(&schema_once, init_schema_version);
	return (&schema_version);
}

/* ---- emitter ----------------------------------------------------------- */

static void
put_str(FILE *fp, const char *s)
{
	const unsigned char *p;

	fputc('"', fp);
	for (p = (const unsigned char *)s; *p != '\0'; p++) {
		switch (*p) {
		case '"':
			fputs("\\\"", fp);
			break;
		case '\\':
			fputs("\\\\", fp);
			break;
		case '\n':
			fputs("\\n", fp);
			break;
		default:
			if (*p >= 0x80)
				fputs("\\ufffd", fp);	/* not ASCII: say so */
			else if (*p < 0x20 || *p == 0x7f)
				fprintf(fp, "\\u%04x", *p);
			else
				fputc(*p, fp);
		}
	}
	fputc('"', fp);
}

static void
put_unavail(FILE *fp, int reason, int source)
{
	fprintf(fp, "\"available\":false,\"reason_id\":\"%s\","
	    "\"reason\":", nvrm_reason_id(reason));
	put_str(fp, nvrm_reason_text(reason));
	fprintf(fp, ",\"source\":\"%s\"}", nvrm_source_name(source));
}

static void
put_u64(FILE *fp, const nvrm_u64 *v)
{
	fputc('{', fp);
	if (NVRM_HAVE(*v))
		fprintf(fp, "\"available\":true,\"value\":%ju,"
		    "\"source\":\"%s\"}", (uintmax_t)v->value,
		    nvrm_source_name(v->source));
	else
		put_unavail(fp, v->reason, v->source);
}

static void
put_strv(FILE *fp, const nvrm_str *v)
{
	fputc('{', fp);
	if (NVRM_HAVE(*v)) {
		fputs("\"available\":true,\"value\":", fp);
		put_str(fp, v->value);
		fprintf(fp, ",\"source\":\"%s\"}", nvrm_source_name(v->source));
	} else
		put_unavail(fp, v->reason, v->source);
}

static void
put_version(FILE *fp, const nvrm_version *v, int source)
{
	unsigned i;
	int reason;

	fputc('{', fp);
	if (v->available) {
		fputs("\"available\":true,\"string\":", fp);
		put_str(fp, v->string);
		fprintf(fp, ",\"major\":%ju,\"minor\":%ju,\"patch\":%ju,"
		    "\"parts\":[", (uintmax_t)v->parts[0],
		    (uintmax_t)v->parts[1], (uintmax_t)v->parts[2]);
		for (i = 0; i < v->nparts; i++)
			fprintf(fp, "%s%ju", i != 0 ? "," : "",
			    (uintmax_t)v->parts[i]);
		fputc(']', fp);
		if (v->suffix[0] != '\0') {
			fputs(",\"suffix\":", fp);
			put_str(fp, v->suffix);
		}
	} else {
		reason = nvrm_reason_from_id(v->reason);
		if (reason < 0) {
#ifdef NVRM_FAULT_INJECT
			abort();	/* a stored id must name a table row */
#else
			reason = NVRM_R_VERSION_UNPARSED;
#endif
		}
		fputs("\"available\":false,\"string\":", fp);
		put_str(fp, v->string);
		fprintf(fp, ",\"reason_id\":\"%s\",\"reason\":",
		    nvrm_reason_id(reason));
		put_str(fp, nvrm_reason_text(reason));
	}
	fprintf(fp, ",\"source\":\"%s\"}", nvrm_source_name(source));
}

static void
put_list(FILE *fp, const nvrm_list *v)
{
	uint32_t i;

	fputc('{', fp);
	if (NVRM_HAVE(*v)) {
		fputs("\"available\":true,\"value\":[", fp);
		for (i = 0; i < v->count; i++)
			fprintf(fp, "%s%ju", i != 0 ? "," : "",
			    (uintmax_t)v->value[i]);
		fprintf(fp, "],\"source\":\"%s\"}", nvrm_source_name(v->source));
	} else
		put_unavail(fp, v->reason, v->source);
}

static void
put_device(FILE *fp, const nvrm_device *dev, const nvrm_field *tab, unsigned n)
{
	const nvrm_device_info *info = &dev->info;
	const char *base = (const char *)info;
	unsigned g, i, k;

	fprintf(fp, "{\"index\":%u", dev->index);
	for (g = 0; g < nvrm_ngroups; g++) {
		fprintf(fp, ",\"%s\":{", nvrm_group_names[g]);
		for (i = 0, k = 0; i < n; i++) {
			const nvrm_field *f = &tab[i];

			if (strcmp(f->group, nvrm_group_names[g]) != 0)
				continue;
			fprintf(fp, "%s\"%s\":", k++ != 0 ? "," : "", f->name);
			if (f->kind == NVRM_K_U64)
				put_u64(fp, (const nvrm_u64 *)(base + f->offset));
			else if (f->kind == NVRM_K_STR)
				put_strv(fp, (const nvrm_str *)(base + f->offset));
			else if (f->kind == NVRM_K_LIST)
				put_list(fp, (const nvrm_list *)(base + f->offset));
			else {
				const nvrm_version_field *v =
				    (const nvrm_version_field *)(base + f->offset);

				put_version(fp, &v->version, v->source);
			}
		}
		fputc('}', fp);
	}
	fputs(",\"capabilities\":[", fp);
	for (i = 0; i < NVRM_NCAPS; i++) {
		const nvrm_u64 *c = &info->caps[i];

		fprintf(fp, "%s{\"index\":%u,\"name\":\"%s\",", i != 0 ? "," : "",
		    i, nvrm_cap_name(i));
		if (NVRM_HAVE(*c))
			fprintf(fp, "\"available\":true,\"value\":%s,"
			    "\"source\":\"%s\"}", c->value ? "true" : "false",
			    nvrm_source_name(c->source));
		else
			put_unavail(fp, c->reason, c->source);
	}
	fputs("],\"decorators\":[", fp);
	for (i = 0; i < info->ndecorators; i++) {
		if (i != 0)
			fputc(',', fp);
		put_str(fp, info->decorators[i]);
	}
	fputs("]}", fp);
}

static int
finish(FILE *fp)
{
	fputc('\n', fp);
	if (fflush(fp) != 0 || (ferror)(fp))
		return (-1);
	return (0);
}

static void
put_versions(const nvrm_ctx *ctx, FILE *fp)
{
	fputs(",\"versions\":{\"driver\":", fp);
	put_version(fp, nvrm_driver_version(ctx), NVRM_S_OS);
	fputs(",\"rm_api\":", fp);
	put_version(fp, nvrm_rm_api_version(ctx), NVRM_S_RM);
	fputs(",\"built_for\":", fp);
	put_version(fp, nvrm_built_for_version(), NVRM_S_DERIVED);
	fputs(",\"library\":", fp);
	put_version(fp, nvrm_library_version(), NVRM_S_DERIVED);
	fputs(",\"library_symbols\":", fp);
	put_version(fp, nvrm_symbol_version(), NVRM_S_DERIVED);
	fputs(",\"schema\":", fp);
	put_version(fp, nvrm_schema_version(), NVRM_S_DERIVED);
	fputc('}', fp);
}

static void
put_head(const nvrm_ctx *ctx, FILE *fp, const char *kind)
{
	fprintf(fp, "{\"schema\":\"%s\",\"schema_minor\":%d,\"kind\":\"%s\","
	    "\"backend\":\"%s\",\"built_for_rm_version\":\"%s\","
	    "\"running_rm_version\":", SCHEMA_ID, SCHEMA_MINOR, kind,
	    nvrm_backend_name(ctx), NVRM_RM_VERSION);
	put_strv(fp, nvrm_rm_running_version(ctx));
	put_versions(ctx, fp);
}

int
nvrm_json_document(const nvrm_ctx *ctx, FILE *fp)
{
	unsigned i;

	put_head(ctx, fp, "document");
	fputs(",\"devices\":[", fp);
	for (i = 0; i < ctx->ndev; i++) {
		if (i != 0)
			fputc(',', fp);
		put_device(fp, &ctx->dev[i], nvrm_fields, nvrm_nfields);
	}
	fputs("]}", fp);
	return (finish(fp));
}

int
nvrm_json_header(const nvrm_ctx *ctx, FILE *fp)
{
	put_head(ctx, fp, "header");
	fputc('}', fp);
	return (finish(fp));
}

int
nvrm_json_device(const nvrm_device *dev, FILE *fp)
{
	fprintf(fp, "{\"schema\":\"%s\",\"schema_minor\":%d,"
	    "\"kind\":\"device\",\"device\":", SCHEMA_ID, SCHEMA_MINOR);
	put_device(fp, dev, nvrm_fields, nvrm_nfields);
	fputc('}', fp);
	return (finish(fp));
}

int
nvrm_json_device_fields(const nvrm_device *dev, FILE *fp, const nvrm_field *tab,
    unsigned n)
{
	put_device(fp, dev, tab, n);
	return (finish(fp));
}

int
nvrm_json_end(unsigned count, FILE *fp)
{
	fprintf(fp, "{\"schema\":\"%s\",\"schema_minor\":%d,\"kind\":\"end\","
	    "\"count\":%u}", SCHEMA_ID, SCHEMA_MINOR, count);
	return (finish(fp));
}

int
nvrm_json_error(const char *code, const char *message, FILE *fp)
{
	fprintf(fp, "{\"schema\":\"%s\",\"schema_minor\":%d,\"kind\":\"error\","
	    "\"error\":{\"code\":", SCHEMA_ID, SCHEMA_MINOR);
	put_str(fp, code);
	fputs(",\"message\":", fp);
	put_str(fp, message);
	fputs("}}", fp);
	return (finish(fp));
}

/* ---- schema generator -------------------------------------------------- */

static void
schema_value(FILE *fp, const char *name, const char *vtype, int is_list)
{
	fprintf(fp, "    \"%s\": {\n      \"oneOf\": [\n"
	    "        {\n"
	    "          \"type\": \"object\",\n"
	    "          \"additionalProperties\": false,\n"
	    "          \"required\": [\"available\", \"value\", \"source\"],\n"
	    "          \"properties\": {\n"
	    "            \"available\": { \"const\": true },\n", name);
	if (is_list)
		fputs("            \"value\": { \"type\": \"array\", "
		    "\"items\": { \"type\": \"integer\", \"minimum\": 0 } },\n",
		    fp);
	else
		fprintf(fp, "            \"value\": %s,\n", vtype);
	fputs("            \"source\": { \"$ref\": \"#/$defs/source\" }\n"
	    "          }\n"
	    "        },\n"
	    "        { \"$ref\": \"#/$defs/unavailable\" }\n"
	    "      ]\n"
	    "    },\n", fp);
}

static void
schema_group(FILE *fp, const char *group)
{
	unsigned i, n = 0;

	fprintf(fp, "    \"group_%s\": {\n"
	    "      \"type\": \"object\",\n"
	    "      \"additionalProperties\": false,\n"
	    "      \"required\": [", group);
	for (i = 0; i < nvrm_nfields; i++)
		if (strcmp(nvrm_fields[i].group, group) == 0)
			fprintf(fp, "%s\"%s\"", n++ != 0 ? ", " : "",
			    nvrm_fields[i].name);
	fputs("],\n      \"properties\": {\n", fp);
	for (i = 0, n = 0; i < nvrm_nfields; i++) {
		const nvrm_field *f = &nvrm_fields[i];

		if (strcmp(f->group, group) != 0)
			continue;
		fprintf(fp, "%s        \"%s\": { \"$ref\": \"#/$defs/%s\", "
		    "\"description\": \"%s\" }", n++ != 0 ? ",\n" : "",
		    f->name, f->kind == NVRM_K_U64 ? "u64" :
		    f->kind == NVRM_K_STR ? "text" :
		    f->kind == NVRM_K_LIST ? "list" : "version", f->desc);
	}
	fputs("\n      }\n    },\n", fp);
}

/* The header of the schema, the enums and the unavailable shape. */
static void
schema_prelude(FILE *fp)
{
	unsigned i;

	fprintf(fp, "{\n"
	    "  \"$schema\": \"https://json-schema.org/draft/2020-12/schema\",\n"
	    "  \"$id\": \"urn:cloudbsd:nvrm:schema:%s\",\n"
	    "  \"title\": \"nvrm-info output, major version 1, minor %d\",\n"
	    "  \"description\": \"One schema for every nvrm-info mode: "
	    "--json prints one document; --jsonl prints a header, one device "
	    "per line and an end record; a failure prints an error. Generated "
	    "by nvrm-info --schema from the library's field table; do not edit.\",\n"
	    "  \"oneOf\": [\n"
	    "    { \"$ref\": \"#/$defs/document\" },\n"
	    "    { \"$ref\": \"#/$defs/header\" },\n"
	    "    { \"$ref\": \"#/$defs/device_record\" },\n"
	    "    { \"$ref\": \"#/$defs/end\" },\n"
	    "    { \"$ref\": \"#/$defs/error\" }\n"
	    "  ],\n"
	    "  \"$defs\": {\n", SCHEMA_ID, SCHEMA_MINOR);
	fputs("    \"source\": { \"enum\": [", fp);
	for (i = 0; i < NVRM_S__COUNT; i++)
		fprintf(fp, "%s\"%s\"", i != 0 ? ", " : "", nvrm_source_name(i));
	fputs("] },\n    \"reason_id\": { \"enum\": [", fp);
	for (i = 1; i < NVRM_R__COUNT; i++)
		fprintf(fp, "%s\"%s\"", i != 1 ? ", " : "", nvrm_reason_id(i));
	fputs("] },\n"
	    "    \"unavailable\": {\n"
	    "      \"type\": \"object\",\n"
	    "      \"additionalProperties\": false,\n"
	    "      \"required\": [\"available\", \"reason_id\", \"reason\", "
	    "\"source\"],\n"
	    "      \"properties\": {\n"
	    "        \"available\": { \"const\": false },\n"
	    "        \"reason_id\": { \"$ref\": \"#/$defs/reason_id\" },\n"
	    "        \"reason\": { \"type\": \"string\" },\n"
	    "        \"source\": { \"$ref\": \"#/$defs/source\" }\n"
	    "      }\n"
	    "    },\n", fp);
	fputs("    \"version_part\": { \"type\": \"integer\", \"minimum\": 0, "
	    "\"maximum\": 4294967295 },\n"
	    "    \"version\": {\n"
	    "      \"oneOf\": [\n"
	    "        {\n"
	    "          \"type\": \"object\",\n"
	    "          \"additionalProperties\": false,\n"
	    "          \"required\": [\"available\", \"string\", \"major\", "
	    "\"minor\", \"patch\", \"parts\", \"source\"],\n"
	    "          \"properties\": {\n"
	    "            \"available\": { \"const\": true },\n"
	    "            \"string\": { \"type\": \"string\" },\n"
	    "            \"major\": { \"$ref\": \"#/$defs/version_part\" },\n"
	    "            \"minor\": { \"$ref\": \"#/$defs/version_part\" },\n"
	    "            \"patch\": { \"$ref\": \"#/$defs/version_part\" },\n"
	    "            \"parts\": { \"type\": \"array\", \"minItems\": 1, "
	    "\"maxItems\": 6, \"items\": { \"$ref\": "
	    "\"#/$defs/version_part\" } },\n"
	    "            \"suffix\": { \"type\": \"string\" },\n"
	    "            \"source\": { \"$ref\": \"#/$defs/source\" }\n"
	    "          }\n"
	    "        },\n"
	    "        {\n"
	    "          \"type\": \"object\",\n"
	    "          \"additionalProperties\": false,\n"
	    "          \"required\": [\"available\", \"string\", "
	    "\"reason_id\", \"reason\", \"source\"],\n"
	    "          \"properties\": {\n"
	    "            \"available\": { \"const\": false },\n"
	    "            \"string\": { \"type\": \"string\" },\n"
	    "            \"reason_id\": { \"$ref\": \"#/$defs/reason_id\" },\n"
	    "            \"reason\": { \"type\": \"string\" },\n"
	    "            \"source\": { \"$ref\": \"#/$defs/source\" }\n"
	    "          }\n"
	    "        }\n"
	    "      ]\n"
	    "    },\n"
	    "    \"versions\": {\n"
	    "      \"type\": \"object\",\n"
	    "      \"additionalProperties\": false,\n"
	    "      \"required\": [\"driver\", \"rm_api\", \"built_for\", "
	    "\"library\", \"library_symbols\", \"schema\"],\n"
	    "      \"properties\": {\n"
	    "        \"driver\": { \"$ref\": \"#/$defs/version\" },\n"
	    "        \"rm_api\": { \"$ref\": \"#/$defs/version\" },\n"
	    "        \"built_for\": { \"$ref\": \"#/$defs/version\" },\n"
	    "        \"library\": { \"$ref\": \"#/$defs/version\" },\n"
	    "        \"library_symbols\": { \"$ref\": \"#/$defs/version\" },\n"
	    "        \"schema\": { \"$ref\": \"#/$defs/version\" }\n"
	    "      }\n"
	    "    },\n", fp);
}

/* The three value shapes, the capability flag and the field groups. */
static void
schema_values(FILE *fp)
{
	unsigned i;

	schema_value(fp, "u64", "{ \"type\": \"integer\", \"minimum\": 0 }", 0);
	schema_value(fp, "text", "{ \"type\": \"string\" }", 0);
	schema_value(fp, "list", NULL, 1);
	fputs("    \"capability\": {\n"
	    "      \"oneOf\": [\n"
	    "        {\n"
	    "          \"type\": \"object\",\n"
	    "          \"additionalProperties\": false,\n"
	    "          \"required\": [\"index\", \"name\", \"available\", "
	    "\"value\", \"source\"],\n"
	    "          \"properties\": {\n"
	    "            \"index\": { \"type\": \"integer\", \"minimum\": 0 },\n"
	    "            \"name\": { \"type\": \"string\" },\n"
	    "            \"available\": { \"const\": true },\n"
	    "            \"value\": { \"type\": \"boolean\" },\n"
	    "            \"source\": { \"$ref\": \"#/$defs/source\" }\n"
	    "          }\n"
	    "        },\n"
	    "        {\n"
	    "          \"type\": \"object\",\n"
	    "          \"additionalProperties\": false,\n"
	    "          \"required\": [\"index\", \"name\", \"available\", "
	    "\"reason_id\", \"reason\", \"source\"],\n"
	    "          \"properties\": {\n"
	    "            \"index\": { \"type\": \"integer\", \"minimum\": 0 },\n"
	    "            \"name\": { \"type\": \"string\" },\n"
	    "            \"available\": { \"const\": false },\n"
	    "            \"reason_id\": { \"$ref\": \"#/$defs/reason_id\" },\n"
	    "            \"reason\": { \"type\": \"string\" },\n"
	    "            \"source\": { \"$ref\": \"#/$defs/source\" }\n"
	    "          }\n"
	    "        }\n"
	    "      ]\n"
	    "    },\n", fp);
	for (i = 0; i < nvrm_ngroups; i++)
		schema_group(fp, nvrm_group_names[i]);
}

/* One device: groups, capabilities, decorators. */
static void
schema_device(FILE *fp)
{
	unsigned i;

	fprintf(fp, "    \"device\": {\n"
	    "      \"type\": \"object\",\n"
	    "      \"additionalProperties\": false,\n"
	    "      \"required\": [\"index\"");
	for (i = 0; i < nvrm_ngroups; i++)
		fprintf(fp, ", \"%s\"", nvrm_group_names[i]);
	fputs(", \"capabilities\", \"decorators\"],\n"
	    "      \"properties\": {\n"
	    "        \"index\": { \"type\": \"integer\", \"minimum\": 0 },\n", fp);
	for (i = 0; i < nvrm_ngroups; i++)
		fprintf(fp, "        \"%s\": { \"$ref\": \"#/$defs/group_%s\" },\n",
		    nvrm_group_names[i], nvrm_group_names[i]);
	/* The capability flags are pinned by position: index i is the name
	 * nvrm_cap_name(i), as a constant, so a rename or a reorder is a
	 * schema change and not a silent one. */
	fprintf(fp, "        \"capabilities\": {\n"
	    "          \"type\": \"array\",\n"
	    "          \"minItems\": %d,\n"
	    "          \"maxItems\": %d,\n"
	    "          \"prefixItems\": [\n", NVRM_NCAPS, NVRM_NCAPS);
	for (i = 0; i < NVRM_NCAPS; i++)
		fprintf(fp, "            { \"$ref\": \"#/$defs/capability\", "
		    "\"properties\": { \"index\": { \"const\": %u }, "
		    "\"name\": { \"const\": \"%s\" } } }%s\n", i,
		    nvrm_cap_name(i), i + 1 != NVRM_NCAPS ? "," : "");
	fprintf(fp, "          ]\n"
	    "        },\n"
	    "        \"decorators\": {\n"
	    "          \"type\": \"array\",\n"
	    "          \"maxItems\": %d,\n"
	    "          \"items\": { \"type\": \"string\" }\n"
	    "        }\n"
	    "      }\n"
	    "    },\n", NVRM_MAX_DECORATORS);
}

/* The document, header and device records. */
static void
schema_documents(FILE *fp)
{
	fprintf(fp, "    \"document\": {\n"
	    "      \"type\": \"object\",\n"
	    "      \"additionalProperties\": false,\n"
	    "      \"required\": [\"schema\", \"schema_minor\", \"kind\", "
	    "\"backend\", \"built_for_rm_version\", \"running_rm_version\", "
	    "\"versions\", \"devices\"],\n"
	    "      \"properties\": {\n"
	    "        \"schema\": { \"const\": \"%s\" },\n"
	    "        \"schema_minor\": { \"const\": %d },\n"
	    "        \"kind\": { \"const\": \"document\" },\n"
	    "        \"backend\": { \"type\": \"string\" },\n"
	    "        \"built_for_rm_version\": { \"type\": \"string\" },\n"
	    "        \"running_rm_version\": { \"$ref\": \"#/$defs/text\" },\n"
	    "        \"versions\": { \"$ref\": \"#/$defs/versions\" },\n"
	    "        \"devices\": {\n"
	    "          \"type\": \"array\",\n"
	    "          \"minItems\": 0,\n"
	    "          \"maxItems\": %d,\n"
	    "          \"items\": { \"$ref\": \"#/$defs/device\" }\n"
	    "        }\n"
	    "      }\n"
	    "    },\n", SCHEMA_ID, SCHEMA_MINOR, NVRM_MAX_GPUS);
	fprintf(fp, "    \"header\": {\n"
	    "      \"type\": \"object\",\n"
	    "      \"additionalProperties\": false,\n"
	    "      \"required\": [\"schema\", \"schema_minor\", \"kind\", "
	    "\"backend\", \"built_for_rm_version\", \"running_rm_version\", "
	    "\"versions\"],\n"
	    "      \"properties\": {\n"
	    "        \"schema\": { \"const\": \"%s\" },\n"
	    "        \"schema_minor\": { \"const\": %d },\n"
	    "        \"kind\": { \"const\": \"header\" },\n"
	    "        \"backend\": { \"type\": \"string\" },\n"
	    "        \"built_for_rm_version\": { \"type\": \"string\" },\n"
	    "        \"running_rm_version\": { \"$ref\": \"#/$defs/text\" },\n"
	    "        \"versions\": { \"$ref\": \"#/$defs/versions\" }\n"
	    "      }\n"
	    "    },\n", SCHEMA_ID, SCHEMA_MINOR);
	fprintf(fp, "    \"device_record\": {\n"
	    "      \"type\": \"object\",\n"
	    "      \"additionalProperties\": false,\n"
	    "      \"required\": [\"schema\", \"schema_minor\", \"kind\", "
	    "\"device\"],\n"
	    "      \"properties\": {\n"
	    "        \"schema\": { \"const\": \"%s\" },\n"
	    "        \"schema_minor\": { \"const\": %d },\n"
	    "        \"kind\": { \"const\": \"device\" },\n"
	    "        \"device\": { \"$ref\": \"#/$defs/device\" }\n"
	    "      }\n"
	    "    },\n", SCHEMA_ID, SCHEMA_MINOR);
}

/* The end and error records, and the close of the schema. */
static void
schema_closing(FILE *fp)
{
	unsigned i;

	fprintf(fp, "    \"end\": {\n"
	    "      \"type\": \"object\",\n"
	    "      \"additionalProperties\": false,\n"
	    "      \"required\": [\"schema\", \"schema_minor\", \"kind\", "
	    "\"count\"],\n"
	    "      \"properties\": {\n"
	    "        \"schema\": { \"const\": \"%s\" },\n"
	    "        \"schema_minor\": { \"const\": %d },\n"
	    "        \"kind\": { \"const\": \"end\" },\n"
	    "        \"count\": { \"type\": \"integer\", \"minimum\": 0 }\n"
	    "      }\n"
	    "    },\n", SCHEMA_ID, SCHEMA_MINOR);
	fprintf(fp, "    \"error\": {\n"
	    "      \"type\": \"object\",\n"
	    "      \"additionalProperties\": false,\n"
	    "      \"required\": [\"schema\", \"schema_minor\", \"kind\", "
	    "\"error\"],\n"
	    "      \"properties\": {\n"
	    "        \"schema\": { \"const\": \"%s\" },\n"
	    "        \"schema_minor\": { \"const\": %d },\n"
	    "        \"kind\": { \"const\": \"error\" },\n"
	    "        \"error\": {\n"
	    "          \"type\": \"object\",\n"
	    "          \"additionalProperties\": false,\n"
	    "          \"required\": [\"code\", \"message\"],\n"
	    "          \"properties\": {\n"
	    "            \"code\": { \"enum\": [", SCHEMA_ID, SCHEMA_MINOR);
	for (i = 1; i < NVRM_E__COUNT; i++)
		fprintf(fp, "%s\"%s\"", i != 1 ? ", " : "", nvrm_error_id(i));
	fputs("] },\n"
	    "            \"message\": { \"type\": \"string\" }\n"
	    "          }\n"
	    "        }\n"
	    "      }\n"
	    "    }\n"
	    "  }\n"
	    "}\n", fp);
}

int
nvrm_json_schema(FILE *fp)
{
	schema_prelude(fp);
	schema_values(fp);
	schema_device(fp);
	schema_documents(fp);
	schema_closing(fp);
	if (fflush(fp) != 0 || (ferror)(fp))
		return (-1);
	return (0);
}

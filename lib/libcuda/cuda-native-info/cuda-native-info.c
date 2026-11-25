/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Print the small native Driver API surface.  The fake provider makes every
 * output mode testable without a GPU; the default nvrm provider is deliberately
 * unsupported in cuda-native 0.1.0.
 */
#include <errno.h>
#include <getopt.h>
#include <inttypes.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "cuda_internal.h"
#include "escape.h"

static const char schema_text[] =
#include "schema.inc"
;

enum output_mode {
	MODE_TEXT,
	MODE_JSON,
	MODE_JSONL,
	MODE_SCHEMA
};

typedef struct attribute_spec {
	CUdevice_attribute attribute;
	const char *name;
} attribute_spec;

static const attribute_spec attribute_specs[] = {
	{ CU_DEVICE_ATTRIBUTE_MAX_THREADS_PER_BLOCK, "max_threads_per_block" },
	{ CU_DEVICE_ATTRIBUTE_MAX_SHARED_MEMORY_PER_BLOCK,
	    "max_shared_memory_per_block" },
	{ CU_DEVICE_ATTRIBUTE_WARP_SIZE, "warp_size" },
	{ CU_DEVICE_ATTRIBUTE_MULTIPROCESSOR_COUNT, "multiprocessor_count" },
	{ CU_DEVICE_ATTRIBUTE_INTEGRATED, "integrated" },
	{ CU_DEVICE_ATTRIBUTE_PCI_BUS_ID, "pci_bus_id" },
	{ CU_DEVICE_ATTRIBUTE_PCI_DEVICE_ID, "pci_device_id" },
	{ CU_DEVICE_ATTRIBUTE_PCI_DOMAIN_ID, "pci_domain_id" },
	{ CU_DEVICE_ATTRIBUTE_COMPUTE_CAPABILITY_MAJOR,
	    "compute_capability_major" },
	{ CU_DEVICE_ATTRIBUTE_COMPUTE_CAPABILITY_MINOR,
	    "compute_capability_minor" },
	{ CU_DEVICE_ATTRIBUTE_COOPERATIVE_LAUNCH, "cooperative_launch" },
	{ CU_DEVICE_ATTRIBUTE_MAX_SHARED_MEMORY_PER_BLOCK_OPTIN,
	    "max_shared_memory_per_block_optin" },
	{ CU_DEVICE_ATTRIBUTE_VIRTUAL_MEMORY_MANAGEMENT_SUPPORTED,
	    "virtual_memory_management_supported" }
};

#define NATTRIBUTES	(sizeof(attribute_specs) / sizeof(attribute_specs[0]))

typedef struct device_info {
	int ordinal;
	char name[128];
	char uuid[41];
	size_t memory;
	int attributes[NATTRIBUTES];
	unsigned char attribute_supported[NATTRIBUTES];
} device_info;

typedef struct native_info {
	const char *backend;
	const char *visibility;
	cuda_native_version cuda;
	cuda_native_version native;
	int count;
	device_info devices[CUDA_NATIVE_MAX_DEVICES];
} native_info;

static void
join_names(char *buffer, size_t size, const char *separator, unsigned count,
    const char *(*name)(unsigned index))
{
	unsigned i;
	const char *text;
	size_t used;
	int written;

	buffer[0] = '\0';
	/* Time: O(names * name length); Space: O(1) besides the buffer. */
	for (i = 0; i < count; i++) {
		text = name(i);
		if (text == NULL)
			continue;
		used = strlen(buffer);
		if (used + 1 >= size)
			break;
		written = snprintf(buffer + used, size - used, "%s%s",
		    used == 0 ? "" : separator, text);
		if (written < 0 || (size_t)written >= size - used)
			break;
	}
}

static void
usage(FILE *stream)
{
	char list[512];

	fprintf(stream,
	    "usage: cuda-native-info [--json | --jsonl | --schema]\n"
	    "       cuda-native-info [-h | --help]\n"
	    "\n"
	    "  --json     write one JSON document on one line\n"
	    "  --jsonl    write a header, one record per device, and an end record\n"
	    "  --schema   write the JSON Schema shared by both JSON modes\n"
	    "  -h, --help show this help\n"
	    "\n");
	join_names(list, sizeof(list), ", ", cudaNativeProviderCount(),
	    cudaNativeProviderName);
	fprintf(stream,
	    "CUDA_NATIVE_BACKEND selects a provider: %s (default %s).\n", list,
	    cudaNativeDefaultBackend());
	join_names(list, sizeof(list), ",", cudaNativeFakeProfileCount(),
	    cudaNativeFakeProfileName);
	fprintf(stream,
	    "CUDA_NATIVE_FAKE_PROFILE takes a comma-separated list of fake"
	    " profiles:\n  %s (default %s).\n", list,
	    cudaNativeFakeProfileDefault());
	fprintf(stream,
	    "CUDA_VISIBLE_DEVICES: comma-separated indices or GPU-<uuid>"
	    " prefixes;\n"
	    "  stops at the first invalid entry (libcuda(3)).\n"
	    "  Repeated devices also stop parsing.\n"
	    "Exit status: 0 success, 1 query or output failure, 2 usage error.\n");
}

static int
parse_args(int argc, char **argv, enum output_mode *mode)
{
	static const struct option options[] = {
		{ "json", no_argument, NULL, 'j' },
		{ "jsonl", no_argument, NULL, 'l' },
		{ "schema", no_argument, NULL, 's' },
		{ "help", no_argument, NULL, 'h' },
		{ NULL, 0, NULL, 0 }
	};
	int ch, modes = 0;

	while ((ch = getopt_long(argc, argv, "h", options, NULL)) != -1) {
		switch (ch) {
		case 'j':
			*mode = MODE_JSON;
			modes++;
			break;
		case 'l':
			*mode = MODE_JSONL;
			modes++;
			break;
		case 's':
			*mode = MODE_SCHEMA;
			modes++;
			break;
		case 'h':
			usage(stdout);
			return (0);
		default:
			usage(stderr);
			return (2);
		}
	}
	if (modes > 1)
		fprintf(stderr, "cuda-native-info: --json, --jsonl and --schema "
		    "exclude each other\n");
	if (modes > 1 || optind != argc) {
		usage(stderr);
		return (2);
	}
	return (-1);
}

static int
validate_environment(char *detail, size_t detail_size)
{
	const char *backend = cudaNativeGetBackendName();
	const char *profiles, *start, *comma;
	size_t length;
	int shown;
	char list[512];
	char escaped[512];

	if (!cudaNativeProviderKnown(backend)) {
		join_names(list, sizeof(list), ", ",
		    cudaNativeProviderCount(), cudaNativeProviderName);
		escaped_buffer(escaped, sizeof(escaped), backend, strlen(backend));
		snprintf(detail, detail_size,
		    "CUDA_NATIVE_BACKEND=%s is not a provider; use one of: %s",
		    escaped, list);
		return (-1);
	}
	/* The library says which provider takes the fake profiles; the tool
	 * does not carry the provider names of its own. */
	if (!cudaNativeProviderTakesFakeProfiles(backend))
		return (0);
	profiles = getenv("CUDA_NATIVE_FAKE_PROFILE");
	if (profiles == NULL)
		return (0);
	start = profiles;
	/* Time: O(profile-list bytes); Space: O(1). */
	for (;;) {
		comma = strchr(start, ',');
		length = comma != NULL ? (size_t)(comma - start) : strlen(start);
		if (!cudaNativeFakeProfileKnown(start, length)) {
			shown = length > 80 ? 80 : (int)length;
			escaped_buffer(escaped, sizeof(escaped), start,
			    (size_t)shown);
			/* The list is printed without spaces, so a reader can
			 * copy it into the variable and it is accepted. */
			join_names(list, sizeof(list), ",",
			    cudaNativeFakeProfileCount(),
			    cudaNativeFakeProfileName);
			/* The value is wrapped in double quotes, the one
			 * delimiter the escaping helper escapes: a value
			 * that holds a quote cannot close the quoted
			 * value and hide what follows it. */
			snprintf(detail, detail_size,
			    "CUDA_NATIVE_FAKE_PROFILE: unknown profile \"%s%s\"; "
			    "known profiles: %s; give one or several separated by "
			    "commas", escaped, length > 80 ? "..." : "", list);
			return (-1);
		}
		if (comma == NULL)
			break;
		start = comma + 1;
	}
	return (0);
}

static CUresult
query(native_info *info)
{
	CUresult result;
	CUdevice device;
	CUuuid uuid;
	unsigned a;
	int count, driver, i;

	memset(info, 0, sizeof(*info));
	result = cuInit(0);
	if (result != CUDA_SUCCESS)
		return (result);
	result = cuDriverGetVersion(&driver);
	if (result != CUDA_SUCCESS)
		return (result);
	if (driver < 0 || cuda_version_make(&info->cuda,
	    (uint32_t)driver / 1000, ((uint32_t)driver % 1000) / 10, 0, 2) != 0 ||
	    cuda_version_make(&info->native, CUDA_NATIVE_VERSION / 10000,
	    (CUDA_NATIVE_VERSION / 100) % 100, CUDA_NATIVE_VERSION % 100, 3) != 0)
		return (CUDA_ERROR_UNKNOWN);
	info->backend = cudaNativeGetBackendName();
	info->visibility = getenv("CUDA_VISIBLE_DEVICES");
	result = cuDeviceGetCount(&count);
	if (result != CUDA_SUCCESS)
		return (result);
	if (count < 0 || (unsigned)count > CUDA_NATIVE_MAX_DEVICES)
		return (CUDA_ERROR_UNKNOWN);
	info->count = count;
	/* Time: O(devices * attributes); Space: O(1) besides info. */
	for (i = 0; i < count; i++) {
		device_info *out = &info->devices[i];

		out->ordinal = i;
		result = cuDeviceGet(&device, i);
		if (result == CUDA_SUCCESS)
			result = cuDeviceGetName(out->name, sizeof(out->name), device);
		if (result == CUDA_SUCCESS)
			result = cuDeviceGetUuid(&uuid, device);
		if (result == CUDA_SUCCESS)
			result = cuDeviceTotalMem(&out->memory, device);
		if (result != CUDA_SUCCESS)
			return (result);
		cuda_uuid_text(&uuid, out->uuid);
		/* Time: O(attributes); Space: O(1). */
		for (a = 0; a < NATTRIBUTES; a++) {
			out->attribute_supported[a] = 1;
			result = cuDeviceGetAttribute(&out->attributes[a],
			    attribute_specs[a].attribute, device);
			if (result == CUDA_ERROR_NOT_SUPPORTED) {
				out->attribute_supported[a] = 0;
				out->attributes[a] = 0;
			} else if (result != CUDA_SUCCESS) {
				return (result);
			}
		}
	}
	return (CUDA_SUCCESS);
}

static void
json_version(const cuda_native_version *version)
{
	char text[sizeof(version->string)];

	if (cuda_version_format(version, text, sizeof(text)) != 0)
		text[0] = '\0';
	printf("{\"string\":");
	escaped_string(text);
	printf(",\"major\":%" PRIu32 ",\"minor\":%" PRIu32
	    ",\"patch\":%" PRIu32 "}", version->major, version->minor,
	    version->patch);
}

static void
json_common(const native_info *info, const char *kind)
{
	printf("{\"schema\":\"cuda-native-info/1\",\"kind\":");
	escaped_string(kind);
	printf(",\"backend\":");
	escaped_string(info->backend);
	printf(",\"cuda_version\":");
	json_version(&info->cuda);
	printf(",\"cuda_native_version\":");
	json_version(&info->native);
	printf(",\"device_count\":%d", info->count);
	/* The raw filter is reported so a truncated list can be explained. */
	if (info->visibility != NULL) {
		printf(",\"visibility_filter\":");
		escaped_string(info->visibility);
	}
}

static void
json_device(const device_info *device)
{
	size_t a;

	printf("{\"schema\":\"cuda-native-info/1\",\"kind\":\"device\","
	    "\"ordinal\":%d,\"name\":", device->ordinal);
	escaped_string(device->name);
	printf(",\"uuid\":");
	escaped_string(device->uuid);
	printf(",\"total_memory_bytes\":%zu,\"attributes\":{", device->memory);
	/* Time: O(attributes); Space: O(1). */
	for (a = 0; a < NATTRIBUTES; a++) {
		if (a != 0)
			putchar(',');
		escaped_string(attribute_specs[a].name);
		if (device->attribute_supported[a])
			printf(":%d", device->attributes[a]);
		else
			fputs(":null", stdout);
	}
	fputs("}}", stdout);
}

static void
emit_json(const native_info *info)
{
	int i;

	json_common(info, "document");
	fputs(",\"devices\":[", stdout);
	for (i = 0; i < info->count; i++) {
		if (i != 0)
			putchar(',');
		json_device(&info->devices[i]);
	}
	fputs("]}\n", stdout);
}

static void
emit_jsonl(const native_info *info)
{
	int i;

	json_common(info, "header");
	fputs("}\n", stdout);
	for (i = 0; i < info->count; i++) {
		json_device(&info->devices[i]);
		putchar('\n');
	}
	printf("{\"schema\":\"cuda-native-info/1\",\"kind\":\"end\","
	    "\"count\":%d}\n", info->count);
}

static void
emit_text(const native_info *info)
{
	const char *visibility = info->visibility;
	int i;
	size_t a;

	printf("backend %s\n", info->backend);
	printf("cuda_version %s (%" PRIu32 ", %" PRIu32 ", %" PRIu32 ")\n",
	    info->cuda.string, info->cuda.major, info->cuda.minor,
	    info->cuda.patch);
	printf("cuda_native_version %s (%" PRIu32 ", %" PRIu32 ", %" PRIu32
	    ")\n", info->native.string, info->native.major, info->native.minor,
	    info->native.patch);
	printf("device_count %d\n", info->count);
	/* The filter names the devices the library was asked to expose, not the
	 * devices it exposes; it is escaped so no control byte reaches the
	 * terminal. */
	if (visibility != NULL) {
		printf("visibility_filter ");
		escaped_string(visibility);
		printf("\n");
	}
	if (info->count == 0) {
		if (visibility != NULL) {
			printf("no CUDA devices are visible (filtered by "
			    "CUDA_VISIBLE_DEVICES=");
			escaped_string(visibility);
			printf("; see libcuda(3))\n");
		} else
			printf("no CUDA devices are visible\n");
	}
	for (i = 0; i < info->count; i++) {
		const device_info *device = &info->devices[i];

		printf("GPU %d\n", device->ordinal);
		printf("  name %s\n", device->name);
		printf("  uuid %s\n", device->uuid);
		printf("  total_memory_bytes %zu\n", device->memory);
		/* Time: O(attributes); Space: O(1). */
		for (a = 0; a < NATTRIBUTES; a++)
			if (device->attribute_supported[a])
				printf("  %s %d\n", attribute_specs[a].name,
				    device->attributes[a]);
			else
				printf("  %s unsupported\n", attribute_specs[a].name);
	}
}

static int
report_error(enum output_mode mode, CUresult result, const char *detail)
{
	const char *backend = cudaNativeGetBackendName();
	/* The provider that is in use: the library answers with the provider
	 * the registry selected and not with the name the environment held.
	 * The name of the environment is the fallback for the case where no
	 * provider is in use. */
	const char *provider = cudaNativeProviderInUse();
	const char *name = NULL, *message = NULL, *hint = NULL;
	char hint_text[256];

	if (provider == NULL)
		provider = backend;
	if (cuGetErrorName(result, &name) != CUDA_SUCCESS)
		name = "CUDA_ERROR_UNKNOWN";
	if (cuGetErrorString(result, &message) != CUDA_SUCCESS)
		message = "The native CUDA query failed.";
	if (detail != NULL)
		message = detail;
	/* The library gives the advice for a provider it cannot use, and it
	 * says why the initialization failed; the tool carries no provider
	 * name of its own. */
	if (result == CUDA_ERROR_NOT_SUPPORTED &&
	    cudaNativeProviderHint(provider, hint_text, sizeof(hint_text)))
		hint = hint_text;
	else if (detail == NULL &&
	    cudaNativeInitFailureReason() == CUDA_NATIVE_INIT_DEVICE_LIMIT) {
		/* The initialization failed because more devices are selected
		 * than the library exposes: name the limit and the filter that
		 * lowers it.  No other failure is a device count overflow. */
		snprintf(hint_text, sizeof(hint_text),
		    "the library exposes at most %d devices; set "
		    "CUDA_VISIBLE_DEVICES to select fewer of them",
		    CUDA_NATIVE_MAX_DEVICES);
		hint = hint_text;
	} else if (detail == NULL &&
	    cudaNativeInitFailureReason() ==
	    CUDA_NATIVE_INIT_PROVIDER_DEVICE_LIMIT) {
		/* The provider reported more devices than the registry holds.
		 * The registry refuses that count before it applies the
		 * visibility filter, so CUDA_VISIBLE_DEVICES cannot lower
		 * it.  The advice is about the provider that is in use: the
		 * library answers with the provider the registry selected
		 * and not with the name the environment held.  The step it
		 * names can be taken: a provider that takes the fake
		 * profiles is shortened by naming fewer of them, and any
		 * other provider is shortened by its own device list. */
		if (cudaNativeProviderTakesFakeProfiles(provider))
			snprintf(hint_text, sizeof(hint_text),
			    "the %s provider reports more devices than the "
			    "registry holds, at most %d; name fewer profiles in "
			    "CUDA_NATIVE_FAKE_PROFILE",
			    provider, CUDA_NATIVE_MAX_PHYSICAL_DEVICES);
		else
			snprintf(hint_text, sizeof(hint_text),
			    "the %s provider reports more devices than the "
			    "registry holds, at most %d; reduce the number of "
			    "devices the provider reports: its device list has "
			    "to name at most %d of them",
			    provider, CUDA_NATIVE_MAX_PHYSICAL_DEVICES,
			    CUDA_NATIVE_MAX_PHYSICAL_DEVICES);
		hint = hint_text;
	} else if (detail == NULL &&
	    cudaNativeInitFailureReason() == CUDA_NATIVE_INIT_PROVIDER_ERROR) {
		/* The provider failed for a reason of its own: say what the
		 * library knows and what the caller can do about it. */
		snprintf(hint_text, sizeof(hint_text),
		    "the provider failed to report its devices; check the "
		    "provider and retry the query");
		hint = hint_text;
	}
	if (mode == MODE_TEXT) {
		if (detail != NULL)
			fprintf(stderr, "cuda-native-info: %s\n", message);
		else
			fprintf(stderr, "cuda-native-info: %s provider: %s: %s\n",
			    backend, name, message);
		if (hint != NULL)
			fprintf(stderr, "cuda-native-info: %s\n", hint);
	} else {
		printf("{\"schema\":\"cuda-native-info/1\",\"kind\":\"error\","
		    "\"backend\":");
		escaped_string(backend);
		printf(",\"error\":{\"code\":%d,\"name\":", (int)result);
		escaped_string(name);
		fputs(",\"message\":", stdout);
		escaped_string(message);
		if (hint != NULL) {
			fputs(",\"hint\":", stdout);
			escaped_string(hint);
		}
		fputs("}}\n", stdout);
	}
	return (1);
}

static int
output_status(void)
{
	if (fflush(stdout) == 0 && !ferror(stdout))
		return (0);
	return (errno == EPIPE ? 0 : 1);
}

int
main(int argc, char **argv)
{
	enum output_mode mode = MODE_TEXT;
	native_info info;
	CUresult result;
	char input_error[1024];
	int parsed;

	parsed = parse_args(argc, argv, &mode);
	if (parsed >= 0)
		return (parsed);
	signal(SIGPIPE, SIG_IGN);
	if (mode == MODE_SCHEMA) {
		fputs(schema_text, stdout);
		return (output_status());
	}
	if (validate_environment(input_error, sizeof(input_error)) != 0)
		return (report_error(mode, CUDA_ERROR_INVALID_VALUE, input_error));
	result = query(&info);
	if (result != CUDA_SUCCESS)
		return (report_error(mode, result, NULL));
	switch (mode) {
	case MODE_TEXT:
		emit_text(&info);
		break;
	case MODE_JSON:
		emit_json(&info);
		break;
	case MODE_JSONL:
		emit_jsonl(&info);
		break;
	case MODE_SCHEMA:
		break;
	}
	return (output_status());
}

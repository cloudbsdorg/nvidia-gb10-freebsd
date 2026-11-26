/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * nvrm_names.c - names and texts: errors, reasons, sources, capability flags.
 * The capability index is stable: new flags are appended, never reordered.
 */
#include <stddef.h>
#include <string.h>

#include "nvrm_internal.h"

/*
 * The name and the text of every error code and of every reason: one
 * table, the error codes first and the reasons after them.  The two kinds
 * have their own number spaces, so the reasons are indexed by the number of
 * error codes plus their own.  One table and not two: two tables of the
 * same shape are what the copy-paste detector finds.
 */
#define NVRM_NAME_REASONS	NVRM_E__COUNT

static const struct { const char *text, *id; } names[
    NVRM_E__COUNT + NVRM_R__COUNT] = {
	/* the error codes */
	[NVRM_OK] = { "success", "ok" },
	[NVRM_E_NOBACKEND] = { "no usable backend", "no_backend" },
	[NVRM_E_OPEN] = { "cannot open the control device", "open_failed" },
	[NVRM_E_VERSION] = { "kernel module version mismatch",
	    "version_mismatch" },
	[NVRM_E_IO] = { "an RM call failed", "rm_call_failed" },
	[NVRM_E_NOMEM] = { "out of memory", "out_of_memory" },
	[NVRM_E_INVAL] = { "invalid argument", "invalid_argument" },
	[NVRM_E_NODEV] = { "no GPU attached", "no_gpu" },
	[NVRM_E_CAPSICUM] = { "cannot limit descriptors for capability mode",
	    "capsicum_limit_failed" },
	[NVRM_E_RM] = { "the RM refused the call", "rm_refused" },
	[NVRM_E_DENIED] = { "not allowed for this client or mapping", "denied" },
	[NVRM_E_NOSLOT] = { "no spare descriptor is left",
	    "no_spare_descriptor" },
	[NVRM_E_RANGE] = { "address or range not available",
	    "range_unavailable" },
	[NVRM_E_NOTSUP] = { "not supported by the backend", "not_supported" },
	[NVRM_E_BUSY] = { "still in use", "busy" },
	[NVRM_E_TIMEOUT] = { "timed out", "timeout" },
	[NVRM_E_LOST] = { "the channel is dead", "channel_lost" },
	[NVRM_E_NOENT] = { "there is nothing to report", "nothing_to_report" },
	/* the reasons */
	[NVRM_NAME_REASONS + NVRM_R_NONE] = { "the value is available",
	    "available" },
	[NVRM_NAME_REASONS + NVRM_R_NOT_QUERIED] = { "the value was not queried",
	    "not_queried" },
	[NVRM_NAME_REASONS + NVRM_R_RM_FAILED] = { "the RM control returned "
	    "an error", "rm_control_failed" },
	[NVRM_NAME_REASONS + NVRM_R_RM_UNSUPPORTED] = { "the RM reports the "
	    "control is not supported on this GPU", "rm_not_supported" },
	[NVRM_NAME_REASONS + NVRM_R_OS_NOT_REPORTED] = { "the OS layer does not "
	    "report this value", "os_not_reported" },
	[NVRM_NAME_REASONS + NVRM_R_FAMILY_UNKNOWN] = { "the GPU is not in the "
	    "generation table", "family_unknown" },
	[NVRM_NAME_REASONS + NVRM_R_INPUT_MISSING] = { "a value this one is "
	    "computed from is unavailable", "input_unavailable" },
	[NVRM_NAME_REASONS + NVRM_R_NO_NUMA] = { "the GPU is not attached to a "
	    "NUMA node", "no_numa_node" },
	[NVRM_NAME_REASONS + NVRM_R_BACKEND_NONE] = { "the backend does not "
	    "provide this value", "backend_does_not_provide" },
	[NVRM_NAME_REASONS + NVRM_R_CLASS_ABSENT] = { "the GPU does not list "
	    "the class", "class_absent" },
	[NVRM_NAME_REASONS + NVRM_R_OS_CALL_FAILED] = { "the system call to the "
	    "driver failed", "os_call_failed" },
	[NVRM_NAME_REASONS + NVRM_R_VALUE_UNUSABLE] = { "the RM answered, but "
	    "the answer failed a consistency check (it names another device, "
	    "or exceeds what the library can count)", "value_unusable" },
	[NVRM_NAME_REASONS + NVRM_R_FAMILY_NO_CLASS] = { "the GPU family is "
	    "known and has no class of this kind", "family_has_no_class" },
	[NVRM_NAME_REASONS + NVRM_R_VERSION_UNPARSED] = { "the version string "
	    "has no readable numeric scheme", "version_unparsed" },
	[NVRM_NAME_REASONS + NVRM_R_VERSION_INCONSISTENT] = { "the kernel "
	    "module version sysctls disagree with its version string",
	    "version_inconsistent" },
};

const char *
nvrm_strerror(int error)
{
	if (error < 0 || (size_t)error >= NVRM_E__COUNT)
		return ("unknown error");
	return (names[error].text);
}

const char *
nvrm_error_id(int error)
{
	if (error < 0 || (size_t)error >= NVRM_E__COUNT)
		return ("unknown");
	return (names[error].id);
}

const char *
nvrm_reason_id(int reason)
{
	if (reason < 0 || reason >= NVRM_R__COUNT)
		return ("unknown");
	return (names[NVRM_NAME_REASONS + reason].id);
}

const char *
nvrm_reason_text(int reason)
{
	if (reason < 0 || reason >= NVRM_R__COUNT)
		return ("unknown reason");
	return (names[NVRM_NAME_REASONS + reason].text);
}

int
nvrm_reason_from_id(const char *id)
{
	int i;

	if (id == NULL)
		return (-1);
	for (i = 1; i < NVRM_R__COUNT; i++)
		if (strcmp(id, names[NVRM_NAME_REASONS + i].id) == 0)
			return (i);
	return (-1);
}

static const char *const source_names[NVRM_S__COUNT] = {
	[NVRM_S_RM] = "rm",
	[NVRM_S_OS] = "os",
	[NVRM_S_DERIVED] = "derived",
	[NVRM_S_FAMILY] = "family",
	[NVRM_S_BOARD] = "board",
};

const char *
nvrm_source_name(int source)
{
	if (source < 0 || source >= NVRM_S__COUNT)
		return ("unknown");
	return (source_names[source]);
}

static const char *const cap_names[NVRM_NCAPS] = {
	"dmabuf_export",
	"ats",
	"self_hosted",
	"display_enabled",
	"soc",
	"coherent_gpu_memory",
	"os_device_wc_active",
};

const char *
nvrm_cap_name(unsigned index)
{
	if (index >= NVRM_NCAPS)
		return (NULL);
	return (cap_names[index]);
}

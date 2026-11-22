/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * nvrm_names.c - names and texts: errors, reasons, sources, capability flags.
 * The capability index is stable: new flags are appended, never reordered.
 */
#include <stddef.h>

#include "nvrm_internal.h"

static const char *const error_text[] = {
	[NVRM_OK] = "success",
	[NVRM_E_NOBACKEND] = "no usable backend",
	[NVRM_E_OPEN] = "cannot open the control device",
	[NVRM_E_VERSION] = "kernel module version mismatch",
	[NVRM_E_IO] = "an RM call failed",
	[NVRM_E_NOMEM] = "out of memory",
	[NVRM_E_INVAL] = "invalid argument",
	[NVRM_E_NODEV] = "no GPU attached",
	[NVRM_E_CAPSICUM] = "cannot limit descriptors for capability mode",
	[NVRM_E_RM] = "the RM refused the call",
	[NVRM_E_DENIED] = "not allowed for this client or mapping",
	[NVRM_E_NOSLOT] = "no spare descriptor is left",
	[NVRM_E_RANGE] = "address or range not available",
	[NVRM_E_NOTSUP] = "not supported by the backend",
	[NVRM_E_BUSY] = "still in use",
	[NVRM_E_TIMEOUT] = "timed out",
	[NVRM_E_LOST] = "the channel is dead",
};
_Static_assert(sizeof(error_text) / sizeof(error_text[0]) == NVRM_E__COUNT,
    "an error code has no text");

const char *
nvrm_strerror(int error)
{
	if (error < 0 || (size_t)error >=
	    sizeof(error_text) / sizeof(error_text[0]))
		return ("unknown error");
	return (error_text[error]);
}

static const char *const error_ids[] = {
	[NVRM_OK] = "ok",
	[NVRM_E_NOBACKEND] = "no_backend",
	[NVRM_E_OPEN] = "open_failed",
	[NVRM_E_VERSION] = "version_mismatch",
	[NVRM_E_IO] = "rm_call_failed",
	[NVRM_E_NOMEM] = "out_of_memory",
	[NVRM_E_INVAL] = "invalid_argument",
	[NVRM_E_NODEV] = "no_gpu",
	[NVRM_E_CAPSICUM] = "capsicum_limit_failed",
	[NVRM_E_RM] = "rm_refused",
	[NVRM_E_DENIED] = "denied",
	[NVRM_E_NOSLOT] = "no_spare_descriptor",
	[NVRM_E_RANGE] = "range_unavailable",
	[NVRM_E_NOTSUP] = "not_supported",
	[NVRM_E_BUSY] = "busy",
	[NVRM_E_TIMEOUT] = "timeout",
	[NVRM_E_LOST] = "channel_lost",
};
_Static_assert(sizeof(error_ids) / sizeof(error_ids[0]) == NVRM_E__COUNT,
    "an error code has no id");

const char *
nvrm_error_id(int error)
{
	if (error < 0 || (size_t)error >=
	    sizeof(error_ids) / sizeof(error_ids[0]))
		return ("unknown");
	return (error_ids[error]);
}

static const struct { const char *id, *text; } reasons[NVRM_R__COUNT] = {
	[NVRM_R_NONE] = { "available", "the value is available" },
	[NVRM_R_NOT_QUERIED] = { "not_queried", "the value was not queried" },
	[NVRM_R_RM_FAILED] = { "rm_control_failed",
	    "the RM control returned an error" },
	[NVRM_R_RM_UNSUPPORTED] = { "rm_not_supported",
	    "the RM reports the control is not supported on this GPU" },
	[NVRM_R_OS_NOT_REPORTED] = { "os_not_reported",
	    "the OS layer does not report this value" },
	[NVRM_R_FAMILY_UNKNOWN] = { "family_unknown",
	    "the GPU is not in the generation table" },
	[NVRM_R_INPUT_MISSING] = { "input_unavailable",
	    "a value this one is computed from is unavailable" },
	[NVRM_R_NO_NUMA] = { "no_numa_node",
	    "the GPU is not attached to a NUMA node" },
	[NVRM_R_BACKEND_NONE] = { "backend_does_not_provide",
	    "the backend does not provide this value" },
	[NVRM_R_CLASS_ABSENT] = { "class_absent",
	    "the GPU does not list the class" },
	[NVRM_R_OS_CALL_FAILED] = { "os_call_failed",
	    "the system call to the driver failed" },
	[NVRM_R_VALUE_UNUSABLE] = { "value_unusable",
	    "the RM answered, but the answer failed a consistency check (it "
	    "names another device, or exceeds what the library can count)" },
	[NVRM_R_FAMILY_NO_CLASS] = { "family_has_no_class",
	    "the GPU family is known and has no class of this kind" },
};

const char *
nvrm_reason_id(int reason)
{
	if (reason < 0 || reason >= NVRM_R__COUNT)
		return ("unknown");
	return (reasons[reason].id);
}

const char *
nvrm_reason_text(int reason)
{
	if (reason < 0 || reason >= NVRM_R__COUNT)
		return ("unknown reason");
	return (reasons[reason].text);
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

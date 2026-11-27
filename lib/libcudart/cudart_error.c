/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The error state of the runtime: the error of the calling thread, the
 * reason of it, and the names and texts of the error codes.
 */
#include <stddef.h>
#include <string.h>

#include "cudart_internal.h"

/* The error of the calling thread.  It is per thread: a failure of one
 * thread is never the error of another. */
static _Thread_local cudaError_t thread_error = cudaSuccess;
/* The reason of the last failure of the calling thread.  It names what the
 * runtime could not do.  The text is copied into the thread's own buffer:
 * a reason the runtime builds on the stack lives only as long as the call
 * that built it. */
static _Thread_local char reason_buffer[1024];
static _Thread_local const char *thread_reason;

typedef struct error_text {
	cudaError_t code;
	const char *name;
	const char *text;
} error_text;

/* The codes the runtime returns.  The values are the ones the public CUDA
 * Runtime API reference documents. */
static const error_text errors[] = {
	{ cudaSuccess, "cudaSuccess", "no error" },
	{ cudaErrorInvalidValue, "cudaErrorInvalidValue",
	    "an argument has an invalid value" },
	{ cudaErrorMemoryAllocation, "cudaErrorMemoryAllocation",
	    "the runtime could not allocate enough memory" },
	{ cudaErrorInitializationError, "cudaErrorInitializationError",
	    "the driver did not initialize" },
	{ cudaErrorNoDevice, "cudaErrorNoDevice",
	    "no usable compute device is available" },
	{ cudaErrorInvalidDevice, "cudaErrorInvalidDevice",
	    "the device ordinal is not valid" },
	{ cudaErrorInvalidResourceHandle, "cudaErrorInvalidResourceHandle",
	    "the handle is not one the runtime holds" },
	{ cudaErrorNotReady, "cudaErrorNotReady",
	    "the operation is not ready" },
	{ cudaErrorIllegalAddress, "cudaErrorIllegalAddress",
	    "an address is outside the memory of the device" },
	{ cudaErrorInvalidPitchValue, "cudaErrorInvalidPitchValue",
	    "the pitch of the memory is invalid" },
	{ cudaErrorLaunchTimeout, "cudaErrorLaunchTimeout",
	    "the launch did not finish in time" },
	{ cudaErrorLaunchFailure, "cudaErrorLaunchFailure",
	    "the launch failed" },
	{ cudaErrorNotSupported, "cudaErrorNotSupported",
	    "the operation is not supported by the driver" },
	{ cudaErrorUnknown, "cudaErrorUnknown",
	    "the driver reported an unknown error" }
};

static const error_text *
error_find(cudaError_t code)
{
	size_t i;

	/* Time: O(number of codes); Space: O(1). */
	for (i = 0; i < sizeof(errors) / sizeof(errors[0]); i++)
		if (errors[i].code == code)
			return (&errors[i]);
	return (NULL);
}

void
cudart_error_set(cudaError_t error, const char *reason)
{
	size_t length;

	thread_error = error;
	if (reason == NULL) {
		thread_reason = NULL;
		return;
	}
	/* The reason is copied into the thread's own buffer.  A reason
	 * longer than the buffer is cut short; every reason the runtime
	 * builds is far shorter. */
	length = strlen(reason);
	if (length >= sizeof(reason_buffer))
		length = sizeof(reason_buffer) - 1;
	memcpy(reason_buffer, reason, length);
	reason_buffer[length] = '\0';
	thread_reason = reason_buffer;
}

cudaError_t
cudart_error_last(void)
{
	cudaError_t error = thread_error;

	/* The read clears the error: the next read reports no error until
	 * the thread fails again. */
	thread_error = cudaSuccess;
	thread_reason = NULL;
	return (error);
}

cudaError_t
cudart_error_peek(void)
{
	return (thread_error);
}

const char *
cudart_error_reason(void)
{
	return (thread_reason);
}

cudaError_t
cudaGetLastError(void)
{
	return (cudart_error_last());
}

cudaError_t
cudaPeekAtLastError(void)
{
	return (cudart_error_peek());
}

/*
 * The two error queries answer about a code; they are not an operation, so
 * they leave the error state of the thread alone.  A thread that asks for
 * the name of a code it does not know still has the error it had.
 */
cudaError_t
cudaGetErrorName(cudaError_t error, const char **name)
{
	const error_text *entry;

	if (name == NULL)
		return (cudaErrorInvalidValue);
	entry = error_find(error);
	if (entry == NULL) {
		*name = NULL;
		return (cudaErrorInvalidValue);
	}
	*name = entry->name;
	return (cudaSuccess);
}

cudaError_t
cudaGetErrorString(cudaError_t error, const char **string)
{
	const error_text *entry;

	if (string == NULL)
		return (cudaErrorInvalidValue);
	entry = error_find(error);
	if (entry == NULL) {
		*string = NULL;
		return (cudaErrorInvalidValue);
	}
	*string = entry->text;
	return (cudaSuccess);
}

const char *
cudaNativeLastFailureReason(void)
{
	return (cudart_error_reason());
}

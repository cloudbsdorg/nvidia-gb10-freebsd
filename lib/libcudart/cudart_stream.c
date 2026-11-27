/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The streams and the events of the runtime.  The driver holds no stream
 * and no event yet: the default stream is the only one a caller may name,
 * and every operation on it says that the driver cannot do it.
 */
#include <stddef.h>
#include <stdio.h>

#include "cudart_internal.h"

/* The default stream is the stream of handle zero.  The runtime holds no
 * other stream, so a handle that is not the default one names nothing the
 * runtime knows. */
static cudaError_t
stream_check(cudaStream_t stream)
{
	if (stream != NULL)
		return (cudart_fail(cudaErrorInvalidResourceHandle,
		    "the runtime holds no stream of its own; only the default "
		    "stream exists"));
	return (cudaSuccess);
}

/* The runtime holds no event at all: every event handle names nothing it
 * knows. */
static cudaError_t
event_check(cudaEvent_t event)
{
	(void)event;
	return (cudart_fail(cudaErrorInvalidResourceHandle,
	    "the runtime holds no event of its own"));
}

/* The runtime holds no stream and no event of its own, so a call that would
 * create one is refused the same way: the output pointer is checked, the
 * flags are checked, the driver is asked whether it is ready, and the reason
 * names the driver call that is missing.  The four calls differ only in the
 * name of the thing, the flags they know and the driver call they need, so
 * the shape of the refusal is written once and the table holds the rest. */
typedef struct create_kind {
	const char *what;		/* what the runtime calls the thing */
	const char *driver_call;	/* the driver call that is missing */
	unsigned int known_flags;	/* the flags the runtime knows */
} create_kind;

static const create_kind stream_kind = {
	"stream",
	"cuStreamCreate",
	(unsigned int)cudaStreamNonBlocking
};

static const create_kind event_kind = {
	"event",
	"cuEventCreate",
	(unsigned int)(cudaEventBlockingSync | cudaEventDisableTiming)
};

/* A call that would create a stream or an event.  The reason is built in a
 * buffer of this call's own and the failure copies it, so the name of the
 * thing and the name of the driver call come from the one table and cannot
 * disagree with it. */
static cudaError_t
create_refused(void *out, unsigned int flags, const create_kind *kind)
{
	char reason[256];
	cudaError_t ready;

	if (out == NULL) {
		(void)snprintf(reason, sizeof(reason),
		    "the %s output pointer is null", kind->what);
		return (cudart_fail(cudaErrorInvalidValue, reason));
	}
	if ((flags & ~kind->known_flags) != 0) {
		(void)snprintf(reason, sizeof(reason),
		    "the %s flags are not ones the runtime knows", kind->what);
		return (cudart_fail(cudaErrorInvalidValue, reason));
	}
	ready = cudart_driver_ready();
	if (ready != cudaSuccess)
		return (ready);
	(void)snprintf(reason, sizeof(reason),
	    "libcuda has no %s yet; the runtime cannot create a %s",
	    kind->driver_call, kind->what);
	return (cudart_fail(cudaErrorNotSupported, reason));
}

cudaError_t
cudaStreamCreate(cudaStream_t *stream)
{
	return (create_refused(stream, 0, &stream_kind));
}

cudaError_t
cudaStreamCreateWithFlags(cudaStream_t *stream, unsigned int flags)
{
	return (create_refused(stream, flags, &stream_kind));
}

cudaError_t
cudaStreamDestroy(cudaStream_t stream)
{
	if (stream == NULL)
		return (cudart_fail(cudaErrorInvalidResourceHandle,
		    "the default stream cannot be destroyed; it belongs to the "
		    "driver"));
	return (cudart_fail(cudaErrorInvalidResourceHandle,
	    "the runtime holds no stream of its own; only the default stream "
	    "exists"));
}

cudaError_t
cudaStreamSynchronize(cudaStream_t stream)
{
	cudaError_t result;
	cudaError_t ready;

	result = stream_check(stream);
	if (result != cudaSuccess)
		return (result);
	ready = cudart_driver_ready();
	if (ready != cudaSuccess)
		return (ready);
	return (cudart_fail(cudaErrorNotSupported,
	    "libcuda has no cuStreamSynchronize yet; the runtime cannot wait "
	    "for a stream"));
}

cudaError_t
cudaStreamQuery(cudaStream_t stream)
{
	cudaError_t result;
	cudaError_t ready;

	result = stream_check(stream);
	if (result != cudaSuccess)
		return (result);
	ready = cudart_driver_ready();
	if (ready != cudaSuccess)
		return (ready);
	return (cudart_fail(cudaErrorNotSupported,
	    "libcuda has no cuStreamQuery yet; the runtime cannot ask a "
	    "stream for its state"));
}

cudaError_t
cudaEventCreate(cudaEvent_t *event)
{
	return (create_refused(event, 0, &event_kind));
}

cudaError_t
cudaEventCreateWithFlags(cudaEvent_t *event, unsigned int flags)
{
	return (create_refused(event, flags, &event_kind));
}

cudaError_t
cudaEventDestroy(cudaEvent_t event)
{
	return (event_check(event));
}

cudaError_t
cudaEventRecord(cudaEvent_t event, cudaStream_t stream)
{
	cudaError_t result;

	result = event_check(event);
	if (result != cudaSuccess)
		return (result);
	return (stream_check(stream));
}

cudaError_t
cudaEventSynchronize(cudaEvent_t event)
{
	return (event_check(event));
}

cudaError_t
cudaEventQuery(cudaEvent_t event)
{
	return (event_check(event));
}

cudaError_t
cudaEventElapsedTime(float *ms, cudaEvent_t start, cudaEvent_t end)
{
	cudaError_t result;

	if (ms == NULL)
		return (cudart_fail(cudaErrorInvalidValue,
		    "the time output pointer is null"));
	result = event_check(start);
	if (result != cudaSuccess)
		return (result);
	return (event_check(end));
}

cudaError_t
cudaDeviceSynchronize(void)
{
	cudaError_t ready;

	ready = cudart_driver_ready();
	if (ready != cudaSuccess)
		return (ready);
	return (cudart_fail(cudaErrorNotSupported,
	    "libcuda has no cuCtxSynchronize yet; the runtime cannot wait "
	    "for the device"));
}

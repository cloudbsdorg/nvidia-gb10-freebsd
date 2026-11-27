/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * probe_util.h - what the native probes of the test-boot kit share: the
 * monotonic clock in nanoseconds and a number read from the environment.
 * One copy of each, so that a deadline is changed in one place and the two
 * probes cannot drift apart.  Include once per probe.
 */
#ifndef _PROBE_UTIL_H_
#define _PROBE_UTIL_H_

#include <stdint.h>
#include <stdlib.h>
#include <time.h>

/* The monotonic clock, in nanoseconds. */
static inline uint64_t
now_ns(void)
{
	struct timespec ts;

	(void)clock_gettime(CLOCK_MONOTONIC, &ts);
	return ((uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec);
}

/* A number from the environment, or the default when it is not one. */
static inline uint64_t
env_u64(const char *name, uint64_t dflt)
{
	const char *v = getenv(name);
	char *end;
	uint64_t n;

	if (v == NULL || *v == '\0')
		return (dflt);
	n = (uint64_t)strtoull(v, &end, 10);
	if (end == v || *end != '\0' || n == 0)
		return (dflt);
	return (n);
}

#endif

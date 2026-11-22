/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * fault_calloc.h - the allocation seam of the tests: the library built with
 * NVRM_FAULT_INJECT allocates through nvrm_test_calloc(), which fails the
 * Nth call when calloc_fail_at is N (0 = never).  Include once per test.
 */
#ifndef _FAULT_CALLOC_H_
#define _FAULT_CALLOC_H_

#include <stdlib.h>

static int calloc_calls, calloc_fail_at;

void *
nvrm_test_calloc(size_t n, size_t sz)
{
	calloc_calls++;
	if (calloc_fail_at != 0 && calloc_calls == calloc_fail_at)
		return (NULL);
	return (calloc(n, sz));
}

#endif

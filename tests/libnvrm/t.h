/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * t.h - a very small test harness: CHECK prints a line per failure and counts.
 */
#ifndef _T_H_
#define _T_H_

#include <stdio.h>
#include <stdlib.h>

static int t_checks, t_fails;

#define CHECK(cond) do {						\
	t_checks++;							\
	if (!(cond)) {							\
		t_fails++;						\
		printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);	\
	}								\
} while (0)

#define CHECK_EQ(a, b) do {						\
	uintmax_t _a = (uintmax_t)(a), _b = (uintmax_t)(b);		\
	t_checks++;							\
	if (_a != _b) {							\
		t_fails++;						\
		printf("FAIL %s:%d: %s == %s (%#jx vs %#jx)\n", __FILE__, \
		    __LINE__, #a, #b, _a, _b);				\
	}								\
} while (0)

#define CHECK_STR(a, b) do {						\
	const char *_a = (a), *_b = (b);				\
	t_checks++;							\
	if (_a == NULL || strcmp(_a, _b) != 0) {			\
		t_fails++;						\
		printf("FAIL %s:%d: %s is \"%s\", want \"%s\"\n",	\
		    __FILE__, __LINE__, #a, _a ? _a : "(null)", _b);	\
	}								\
} while (0)

static int
t_done(const char *name)
{
	printf("%s: %d checks, %d failed\n", name, t_checks, t_fails);
	return (t_fails == 0 ? 0 : 1);
}

#endif

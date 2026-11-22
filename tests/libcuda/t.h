/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 */
#ifndef LIBCUDA_TEST_T_H_
#define LIBCUDA_TEST_T_H_

#include <inttypes.h>
#include <stdio.h>
#include <string.h>

static int t_checks;
static int t_fails;

#define CHECK(cond) do {                                                   \
	t_checks++;                                                        \
	if (!(cond)) {                                                     \
		t_fails++;                                                 \
		printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);    \
	}                                                                  \
} while (0)

#define CHECK_EQ(a, b) do {                                                \
	uintmax_t ta_ = (uintmax_t)(a);                                    \
	uintmax_t tb_ = (uintmax_t)(b);                                    \
	t_checks++;                                                        \
	if (ta_ != tb_) {                                                  \
		t_fails++;                                                 \
		printf("FAIL %s:%d: %s == %s (%" PRIuMAX " vs %"           \
		    PRIuMAX ")\n", __FILE__, __LINE__, #a, #b, ta_, tb_); \
	}                                                                  \
} while (0)

#define CHECK_STR(a, b) do {                                               \
	const char *ta_ = (a);                                             \
	const char *tb_ = (b);                                             \
	t_checks++;                                                        \
	if (ta_ == NULL || tb_ == NULL || strcmp(ta_, tb_) != 0) {        \
		t_fails++;                                                 \
		printf("FAIL %s:%d: %s is \"%s\", want \"%s\"\n",         \
		    __FILE__, __LINE__, #a, ta_ == NULL ? "(null)" : ta_,  \
		    tb_ == NULL ? "(null)" : tb_);                        \
	}                                                                  \
} while (0)

static int
t_done(const char *name)
{
	printf("%s: %d checks, %d failed\n", name, t_checks, t_fails);
	return (t_fails == 0 ? 0 : 1);
}

#endif

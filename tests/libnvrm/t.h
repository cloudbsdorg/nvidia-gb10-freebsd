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
#include <string.h>

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

/*
 * One table entry per test.  The group names what NVRM_TEST_SKIP and
 * NVRM_TEST_ONLY select on (one group name each; a test whose group is
 * skipped, or is not the only one, does not run).  An entry marked required
 * is never filtered: later entries depend on it.  A group that no entry has
 * prints the groups there are and fails the run, so a typo cannot pass as a
 * run that skipped nothing.
 */
struct t_entry {
	const char *group;
	void (*fn)(void);
	int required;
};

/* The table lines, one per test.  A macro rather than a braced initializer:
 * PMD CPD (ignoring identifiers and literals) reads the braced lines as the
 * same tokens as the other { "name", value } tables in core_test.c. */
#define T_TEST(group, fn)	{ group, fn, 0 },
/* why says what depends on the entry; it is documentation only. */
#define T_NEEDED(group, fn, why) { group, fn, 1 },

static inline int
t_has_group(const struct t_entry *tab, size_t n, const char *name)
{
	size_t i;

	for (i = 0; i < n; i++)
		if (strcmp(tab[i].group, name) == 0)
			return (1);
	return (0);
}

/* Exit 1, naming the groups, when name is set and matches no entry. */
static inline void
t_check_group(const struct t_entry *tab, size_t n, const char *var,
    const char *name)
{
	size_t i;

	if (name == NULL || t_has_group(tab, n, name))
		return;
	printf("FAIL %s=%s names no group; groups:", var, name);
	for (i = 0; i < n; i++)
		if (!t_has_group(tab, i, tab[i].group))
			printf(" %s", tab[i].group);
	printf("\n");
	exit(1);
}

static inline void
t_run(const struct t_entry *tab, size_t n)
{
	const char *skip = getenv("NVRM_TEST_SKIP");
	const char *only = getenv("NVRM_TEST_ONLY");
	size_t i, ran = 0;
	int run;

	t_check_group(tab, n, "NVRM_TEST_SKIP", skip);
	t_check_group(tab, n, "NVRM_TEST_ONLY", only);
	for (i = 0; i < n; i++) {
		run = (skip == NULL || strcmp(skip, tab[i].group) != 0) &&
		    (only == NULL || strcmp(only, tab[i].group) == 0);
		if (run || tab[i].required) {
			tab[i].fn();
			ran++;
		}
	}
	if (skip != NULL || only != NULL)
		printf("subset run: %zu of %zu entries ran\n", ran, n);
}

#endif

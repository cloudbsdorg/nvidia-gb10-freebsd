/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-3-Clause
 *
 * gb10smmu_unload_test.c - the unload path of the gb10smmu module, with
 * fakes.
 *
 * A refused unload (the nvidia driver is still attached to the GPU, or the
 * SMMU cannot be disabled) keeps the module loaded: the kernel does not
 * unload a module whose unload handler returns an error.  The lock the
 * module holds is therefore still in use, and the next unload attempt
 * takes it again.  Destroying it while the module stays loaded leaves a
 * destroyed mutex behind that the module uses.
 *
 * The code under test is the module's own gb10smmu_stop(): the shell test
 * takes it out of src/gb10-smmu/gb10smmu.c into gb10smmu_stop_case.inc
 * beside this file, so this test runs the code the module builds and not a
 * copy of it.
 */
#include <errno.h>
#include <stdio.h>

/* The fakes the module's unload path needs. */
struct mtx {
	int		fake;
};

static struct mtx fake_lock;

static int	fake_mtx_destroyed;
static int	fake_stop_held_error;
static int	fake_holds;

/* The module's own names. */
#define	sc_lock	fake_lock

static struct {
	char	*va;
} sc;

static void
gb10smmu_hold(void)
{
	fake_holds++;
}

static void
gb10smmu_unhold(void)
{
	fake_holds--;
}

/* The held part of the unload: the fake refuses or accepts it. */
static int
gb10smmu_stop_held(void)
{
	return (fake_stop_held_error);
}

static void
fake_mtx_destroy(struct mtx *m)
{
	(void)m;
	fake_mtx_destroyed++;
}

#define	mtx_destroy(m)	fake_mtx_destroy(m)

/* The module's gb10smmu_stop(), and the rule it asks, from the module. */
#include "gb10smmu_stop_case.inc"

static int failures;

static void
check(int ok, const char *what)
{
	if (ok) {
		printf("ok   %s\n", what);
		return;
	}
	failures++;
	printf("FAIL %s\n", what);
}

int
main(void)
{
	int error;

	/* A refused unload: the module stays loaded and the lock stays. */
	fake_mtx_destroyed = 0;
	fake_stop_held_error = EBUSY;
	fake_holds = 0;
	sc.va = (char *)0x1000;
	error = gb10smmu_stop();
	check(error == EBUSY, "a refused unload returns the refusal");
	check(fake_mtx_destroyed == 0,
	    "a refused unload does not destroy the lock");
	check(fake_holds == 0, "a refused unload gives the holds up");

	/* An unload that was not refused: the module goes away. */
	fake_mtx_destroyed = 0;
	fake_stop_held_error = 0;
	fake_holds = 0;
	sc.va = (char *)0x1000;
	error = gb10smmu_stop();
	check(error == 0, "an accepted unload returns no error");
	check(fake_mtx_destroyed == 1, "an accepted unload destroys the lock");
	check(fake_holds == 0, "an accepted unload gives the holds up");

	if (failures != 0) {
		printf("failed: %d\n", failures);
		return (1);
	}
	printf("passed: 6\n");
	return (0);
}

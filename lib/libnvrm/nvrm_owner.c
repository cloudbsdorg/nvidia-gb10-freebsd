/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * nvrm_owner.c - the process and fork generation that own libnvrm objects.
 */
#include <pthread.h>
#include <unistd.h>

#include "nvrm_internal.h"

pid_t (*nvrm_getpid_hook)(void);	/* test seam: NULL = getpid() */
static unsigned long fork_generation;	/* counts the fork()s that led here */
static pthread_once_t atfork_once = PTHREAD_ONCE_INIT;

static pid_t
my_pid(void)
{
	return (nvrm_getpid_hook != NULL ? nvrm_getpid_hook() : getpid());
}

static void
atfork_child(void)
{
	fork_generation++;
}

static void
register_atfork(void)
{
	pthread_atfork(NULL, NULL, atfork_child);
}

void
nvrm_owner_set(nvrm_owner *o)
{
	pthread_once(&atfork_once, register_atfork);
	o->pid = my_pid();
	o->generation = fork_generation;
}

int
nvrm_owner_is_me(const nvrm_owner *o)
{
	return (my_pid() == o->pid && fork_generation == o->generation);
}

void
nvrm_owner_fork_seam(void)
{
	atfork_child();
}

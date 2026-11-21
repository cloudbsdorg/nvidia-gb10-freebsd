/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-3-Clause
 *
 * nvidia_bridge.c - the core side of the compat provider KPI (Track #2363).
 * Built into nvidia.ko. No Linux header, no Linux symbol.
 */
#include <sys/param.h>
#include <sys/systm.h>
#include <sys/kernel.h>
#include <sys/malloc.h>
#include <sys/lock.h>
#include <sys/sx.h>
#include <sys/queue.h>
#include <sys/libkern.h>

#include "nvidia_bridge.h"

static MALLOC_DEFINE(M_NVBRIDGE, "nvbridge", "nvidia compat provider devices");

struct nvb_dev {
	TAILQ_ENTRY(nvb_dev)	link;
	char			*name;
	struct nvidia_bridge_cdev cdev;
};

static TAILQ_HEAD(, nvb_dev) nvb_devs = TAILQ_HEAD_INITIALIZER(nvb_devs);
static const struct nvidia_bridge_ops *nvb_ops;
static struct sx nvb_lock;
SX_SYSINIT(nvb_lock, &nvb_lock, "nvidia bridge");

/*
 * Replay the devices that exist to a new provider. If the provider refuses
 * one, take back what it accepted so it holds nothing, and fail.
 */
int
nvidia_bridge_register(const struct nvidia_bridge_ops *ops)
{
	struct nvb_dev *d, *u;
	int error = 0;

#ifdef NV_CORE_LINUX_COMPAT
	/* The in-core Linux bridge serves Linux binaries; a provider would
	 * register a second handler over the same ioctl range. */
	return (ENXIO);
#endif
	if (ops == NULL || ops->nbo_version != NVIDIA_BRIDGE_KPI_VERSION ||
	    ops->nbo_size != sizeof(*ops) || ops->nbo_cdev_add == NULL ||
	    ops->nbo_cdev_del == NULL)
		return (EINVAL);
	sx_xlock(&nvb_lock);
	if (nvb_ops != NULL) {
		sx_xunlock(&nvb_lock);
		return (EBUSY);
	}
	TAILQ_FOREACH(d, &nvb_devs, link) {
		error = ops->nbo_cdev_add(&d->cdev);
		if (error != 0) {
			for (u = TAILQ_FIRST(&nvb_devs); u != d;
			    u = TAILQ_NEXT(u, link))
				ops->nbo_cdev_del(&u->cdev);
			break;
		}
	}
	if (error == 0)
		nvb_ops = ops;
	sx_xunlock(&nvb_lock);
	return (error);
}

/* Withdraw the provider; it is told to drop every device it holds. */
int
nvidia_bridge_unregister(const struct nvidia_bridge_ops *ops)
{
	struct nvb_dev *d;

	sx_xlock(&nvb_lock);
	if (ops == NULL || nvb_ops != ops) {
		sx_xunlock(&nvb_lock);
		return (EINVAL);
	}
	TAILQ_FOREACH(d, &nvb_devs, link)
		ops->nbo_cdev_del(&d->cdev);
	nvb_ops = NULL;
	sx_xunlock(&nvb_lock);
	return (0);
}

void
nvidia_bridge_cdev_added(const char *name, int major, int minor)
{
	struct nvb_dev *d;
	size_t len = strlen(name) + 1;

	d = malloc(sizeof(*d), M_NVBRIDGE, M_WAITOK | M_ZERO);
	d->name = malloc(len, M_NVBRIDGE, M_WAITOK);
	memcpy(d->name, name, len);
	d->cdev.nbc_name = d->name;
	d->cdev.nbc_major = major;
	d->cdev.nbc_minor = minor;
	sx_xlock(&nvb_lock);
	TAILQ_INSERT_TAIL(&nvb_devs, d, link);
	/* A refusing provider does not stop the native device. */
	if (nvb_ops != NULL)
		(void)nvb_ops->nbo_cdev_add(&d->cdev);
	sx_xunlock(&nvb_lock);
}

void
nvidia_bridge_cdev_removed(const char *name, int minor)
{
	struct nvb_dev *d;

	sx_xlock(&nvb_lock);
	TAILQ_FOREACH(d, &nvb_devs, link) {
		if (d->cdev.nbc_minor == minor &&
		    strcmp(d->name, name) == 0)
			break;
	}
	if (d != NULL) {
		TAILQ_REMOVE(&nvb_devs, d, link);
		if (nvb_ops != NULL)
			nvb_ops->nbo_cdev_del(&d->cdev);
	}
	sx_xunlock(&nvb_lock);
	if (d != NULL) {
		free(d->name, M_NVBRIDGE);
		free(d, M_NVBRIDGE);
	}
}

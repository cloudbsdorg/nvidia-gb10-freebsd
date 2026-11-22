/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-3-Clause
 *
 * nvidia_linux.ko - the Linux compatibility provider of nvidia.ko (Track
 * #2363). It belongs to the Linuxulator: it depends on linux64elf and
 * linux_common, translates the Linux NVIDIA ioctls (0x4600-0x46ff) into the
 * native encoding, and tells the Linuxulator which device names and
 * major:minor numbers nvidiactl and nvidia<unit> have, so stat(2) and /proc
 * show them to Linux binaries. nvidia.ko itself loads and works without it.
 *
 * Unload order: this module depends on nvidia, so kldunload nvidia is refused
 * (EBUSY, kern_kldunload: refs > 1) while this one is loaded. Unloading this
 * module waits out any Linux ioctl in the handler (see nvbridge_ioctl.h).
 */
#include <sys/param.h>
#include <sys/systm.h>
#include <sys/kernel.h>
#include <sys/module.h>
#include <sys/malloc.h>
#include <sys/lock.h>
#include <sys/mutex.h>
#include <sys/queue.h>

#include "nvidia_bridge.h"
#include "nvbridge_ioctl.h"

#define NVLINUX_IOCTL_MIN	0x4600
#define NVLINUX_IOCTL_MAX	0x46ff
#define NVLINUX_DRIVER		"nvidia"

static MALLOC_DEFINE(M_NVLINUX, "nvidia_linux", "nvidia Linux provider");

/* the cdevsw names of nvidiactl and nvidia<unit> (nvidia_ctl.c, nvidia_dev.c) */
static const char *const nvlinux_names[] = { "nvidiactl", "nvidia", NULL };

struct nvlinux_dev {
	TAILQ_ENTRY(nvlinux_dev) link;
	char			*name;
	struct linux_device_handler h;
	int			minor;
};
static TAILQ_HEAD(, nvlinux_dev) nvlinux_devs =
    TAILQ_HEAD_INITIALIZER(nvlinux_devs);
static struct mtx nvlinux_mtx;
MTX_SYSINIT(nvlinux_mtx, &nvlinux_mtx, "nvidia_linux", MTX_DEF);

static int
nvlinux_ioctl(struct thread *td, struct linux_ioctl_args *args)
{
	return (nvbridge_linux_ioctl(nvlinux_names, td, args));
}

static struct linux_ioctl_handler nvlinux_handler = {
	nvlinux_ioctl,
	NVLINUX_IOCTL_MIN,
	NVLINUX_IOCTL_MAX
};

static int
nvlinux_cdev_add(const struct nvidia_bridge_cdev *c)
{
	struct nvlinux_dev *d;
	size_t len = strlen(c->nbc_name) + 1;

	d = malloc(sizeof(*d), M_NVLINUX, M_WAITOK | M_ZERO);
	d->name = malloc(len, M_NVLINUX, M_WAITOK);
	memcpy(d->name, c->nbc_name, len);
	d->minor = c->nbc_minor;
	d->h.bsd_driver_name = __DECONST(char *, NVLINUX_DRIVER);
	d->h.linux_driver_name = __DECONST(char *, NVLINUX_DRIVER);
	d->h.bsd_device_name = d->name;
	d->h.linux_device_name = d->name;
	d->h.linux_major = c->nbc_major;
	d->h.linux_minor = c->nbc_minor;
	d->h.linux_char_device = 1;
	(void)linux_device_register_handler(&d->h);
	mtx_lock(&nvlinux_mtx);
	TAILQ_INSERT_TAIL(&nvlinux_devs, d, link);
	mtx_unlock(&nvlinux_mtx);
	return (0);
}

static void
nvlinux_cdev_del(const struct nvidia_bridge_cdev *c)
{
	struct nvlinux_dev *d;

	mtx_lock(&nvlinux_mtx);
	TAILQ_FOREACH(d, &nvlinux_devs, link) {
		if (d->minor == c->nbc_minor && strcmp(d->name, c->nbc_name) == 0) {
			TAILQ_REMOVE(&nvlinux_devs, d, link);
			break;
		}
	}
	mtx_unlock(&nvlinux_mtx);
	if (d == NULL)
		return;
	(void)linux_device_unregister_handler(&d->h);
	free(d->name, M_NVLINUX);
	free(d, M_NVLINUX);
}

static const struct nvidia_bridge_ops nvlinux_ops = {
	.nbo_version = NVIDIA_BRIDGE_KPI_VERSION,
	.nbo_size = sizeof(struct nvidia_bridge_ops),
	.nbo_cdev_add = nvlinux_cdev_add,
	.nbo_cdev_del = nvlinux_cdev_del,
};

static int
nvlinux_load(void)
{
	return (nvidia_bridge_register(&nvlinux_ops));
}

static void
nvlinux_unload(void)
{
	(void)nvidia_bridge_unregister(&nvlinux_ops);
}

NVBRIDGE_PROVIDER_MODULE(nvlinux, nvidia_linux);
MODULE_VERSION(nvidia_linux, 1);
/* nvidia 1 is today's core, 2 is the core with the #2373 client table. */
MODULE_DEPEND(nvidia_linux, nvidia, 1, 2, 2);
NVBRIDGE_LINUXULATOR_DEPEND(nvidia_linux);

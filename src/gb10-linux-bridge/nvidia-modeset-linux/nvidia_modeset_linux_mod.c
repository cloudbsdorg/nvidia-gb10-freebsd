/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-3-Clause
 *
 * nvidia_modeset_linux.ko - the Linux compatibility provider of
 * nvidia-modeset.ko (Track #2363): the NVKMS ioctl for Linux binaries and the
 * nvidia-modeset device name. It takes no symbol from nvidia-modeset.ko; it
 * depends on it only so that kldunload of nvidia-modeset is refused (EBUSY)
 * while this module is loaded. Do not load it with a nvidia-modeset built
 * with NVKMS_CORE_LINUX_COMPAT: that module carries the same bridge and the
 * Linuxulator would then hold two handlers for the same ioctl.
 */
#include <sys/param.h>
#include <sys/systm.h>
#include <sys/kernel.h>
#include <sys/module.h>

#include "nvbridge_ioctl.h"

/*
 * NVKMS_IOCTL_MAGIC 'm' and NVKMS_IOCTL_CMD 0 (nvkms-ioctl.h). The Linuxulator
 * matches on the low 16 bits of the Linux command (magic << 8 | number), and
 * _IOC(0, 'm', 0, 0) is 0x6d00 in FreeBSD's encoding too: the direction and
 * size bits are above bit 16.
 */
#define NVKMS_LINUX_IOCTL	_IOC(0, 'm', 0, 0)
/*
 * The numbers the native driver publishes: NV_MAJOR_DEVICE_NUMBER
 * (nv-chardev-numbers.h) and NVKMS_CDEV_MINOR (nvidia-modeset-freebsd.c).
 * tests/linux_bridge_test.sh compares them with the pinned sources.
 */
#define NVKMS_LINUX_MAJOR	195
#define NVKMS_LINUX_MINOR	254

/* the cdevsw name of the NVKMS device (nvidia-modeset-freebsd.c, nvkms_cdevsw) */
static const char *const nvmlinux_names[] = { "nvidia-modeset", NULL };

static struct linux_device_handler nvmlinux_device = {
	.bsd_driver_name = __DECONST(char *, "nvidia-modeset"),
	.linux_driver_name = __DECONST(char *, "nvidia-modeset"),
	.bsd_device_name = __DECONST(char *, "nvidia-modeset"),
	.linux_device_name = __DECONST(char *, "nvidia-modeset"),
	.linux_major = NVKMS_LINUX_MAJOR,
	.linux_minor = NVKMS_LINUX_MINOR,
	.linux_char_device = 1
};

static int
nvmlinux_ioctl(struct thread *td, struct linux_ioctl_args *args)
{
	return (nvbridge_linux_ioctl(nvmlinux_names, td, args));
}

static struct linux_ioctl_handler nvmlinux_handler = {
	nvmlinux_ioctl,
	NVKMS_LINUX_IOCTL,
	NVKMS_LINUX_IOCTL
};

static int
nvmlinux_load(void)
{
	return (linux_device_register_handler(&nvmlinux_device));
}

static void
nvmlinux_unload(void)
{
	(void)linux_device_unregister_handler(&nvmlinux_device);
}

NVBRIDGE_PROVIDER_MODULE(nvmlinux, nvidia_modeset_linux);
MODULE_VERSION(nvidia_modeset_linux, 1);
/* nvidia_modeset is at version 2 (the KAPI table of #2228); no symbol is used, so any of 1 to 2 serves. */
MODULE_DEPEND(nvidia_modeset_linux, nvidia_modeset, 1, 2, 2);
MODULE_DEPEND(nvidia_modeset_linux, linux64elf, 1, 1, 1);
MODULE_DEPEND(nvidia_modeset_linux, linux_common, 1, 1, 1);

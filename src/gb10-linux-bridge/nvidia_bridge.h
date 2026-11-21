/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-3-Clause
 *
 * nvidia_bridge.h - the compat provider KPI of nvidia.ko (Track #2363).
 *
 * nvidia.ko holds no Linux code. A provider module (nvidia_linux.ko, owned by
 * the Linuxulator) registers an ops table here and is told about every
 * character device the core makes: nvidiactl and nvidia<unit>. The provider
 * may load before or after the devices exist; on registration it is replayed
 * the devices that are already there.
 *
 * Versioning: ANY layout change of struct nvidia_bridge_ops or struct
 * nvidia_bridge_cdev (a field added, removed or reordered) bumps
 * NVIDIA_BRIDGE_KPI_VERSION. The core refuses a provider whose version or
 * nbo_size differs from its own (EINVAL), so a provider built against another
 * layout never runs; there is no "additive" exception. The module version of
 * nvidia.ko is separate and is not used for this.
 */
#ifndef _NVIDIA_BRIDGE_H_
#define _NVIDIA_BRIDGE_H_

#define NVIDIA_BRIDGE_KPI_VERSION	1

struct nvidia_bridge_cdev {
	const char	*nbc_name;	/* devfs name: nvidiactl, nvidia0 */
	int		nbc_major;	/* the Linux major NVIDIA assigns (195) */
	int		nbc_minor;	/* unit, or 255 for nvidiactl */
};

struct nvidia_bridge_ops {
	unsigned int	nbo_version;	/* NVIDIA_BRIDGE_KPI_VERSION */
	unsigned int	nbo_size;	/* sizeof(struct nvidia_bridge_ops) */
	/* A device appeared; called with the core's bridge lock held, may sleep. */
	int		(*nbo_cdev_add)(const struct nvidia_bridge_cdev *);
	/* A device the provider accepted is about to go; same locking. A device whose add failed is never deleted. */
	void		(*nbo_cdev_del)(const struct nvidia_bridge_cdev *);
};

/*
 * 0; EBUSY (a provider is registered); EINVAL (bad version, size or table);
 * ENXIO when the core was built with NV_CORE_LINUX_COMPAT, which carries the
 * Linux bridge itself and has nothing for a provider to do. A device that
 * nbo_cdev_add refuses, at registration or later, does not fail anything: the
 * provider is not told about that device again.
 */
int nvidia_bridge_register(const struct nvidia_bridge_ops *);
/* 0, or EINVAL when ops is not the registered provider. */
int nvidia_bridge_unregister(const struct nvidia_bridge_ops *);

#ifdef _KERNEL
/* The core's own notifications (nvidia_ctl.c, nvidia_dev.c). */
void nvidia_bridge_cdev_added(const char *, int, int);
void nvidia_bridge_cdev_removed(const char *, int);
#endif

#endif /* _NVIDIA_BRIDGE_H_ */

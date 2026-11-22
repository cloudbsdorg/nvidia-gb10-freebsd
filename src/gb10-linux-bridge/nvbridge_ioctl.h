/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-3-Clause
 *
 * nvbridge_ioctl.h - what the NVIDIA compat provider modules share (Track
 * #2363): the Linux to FreeBSD ioctl command translation, the device filter,
 * the module event handler. Included by the provider modules only, never by
 * the native drivers.
 *
 * Linux encodes the direction in the top two bits (IN 0x40000000, OUT
 * 0x80000000) and the argument size in 14 bits; FreeBSD uses the top three
 * bits (VOID 0x20000000, OUT 0x40000000, IN 0x80000000) and 13 size bits. A
 * Linux size field that reaches bit 29 would be read as the FreeBSD VOID bit,
 * so such a command is refused.
 *
 * Unload safety: the Linuxulator calls a handler with linux_ioctl_sx held
 * shared (linux_ioctl_fallback), and linux_ioctl_unregister_handler takes it
 * exclusive. When the unregister returns, no thread is inside the handler and
 * none can enter it, so the module text can go; no counter of our own is
 * needed.
 */
#ifndef _NVBRIDGE_IOCTL_H_
#define _NVBRIDGE_IOCTL_H_

#include <sys/param.h>
#include <sys/systm.h>
#include <sys/capsicum.h>
#include <sys/conf.h>
#include <sys/file.h>
#include <sys/filedesc.h>
#include <sys/ioccom.h>
#include <sys/module.h>
#include <sys/proc.h>
#include <sys/sysproto.h>
#include <sys/vnode.h>
#if defined(__aarch64__)
#include <arm64/linux/linux.h>
#include <arm64/linux/linux_proto.h>
#elif defined(__amd64__)
#include <amd64/linux/linux.h>
#include <amd64/linux/linux_proto.h>
#else
#error "the NVIDIA Linux providers support arm64 and amd64 only"
#endif
#include <compat/linux/linux_ioctl.h>
#include <compat/linux/linux_util.h>

/* Returns 0 and the FreeBSD command in *out, or EINVAL. */
static inline int
nvbridge_translate_cmd(u_long lcmd, u_long *out)
{
	u_long dir;

	if ((lcmd & LINUX_IOC_INOUT) != (lcmd & IOC_DIRMASK))
		return (EINVAL);
	switch (lcmd & LINUX_IOC_INOUT) {
	case LINUX_IOC_VOID:
		dir = IOC_VOID;
		break;
	case LINUX_IOC_IN:
		dir = IOC_IN;
		break;
	case LINUX_IOC_OUT:
		dir = IOC_OUT;
		break;
	default:
		dir = IOC_INOUT;
		break;
	}
	*out = (lcmd & ~(u_long)LINUX_IOC_INOUT) | dir;
	return (0);
}

/* Is d_name one of the NULL-terminated names? (pure: host-tested) */
static inline int
nvbridge_name_match(const char *d_name, const char *const *names)
{
	for (; *names != NULL; names++) {
		if (strcmp(d_name, *names) == 0)
			return (1);
	}
	return (0);
}

/*
 * Is the descriptor one of the provider's devices? The Linuxulator chooses a
 * handler by command number alone, so a handler must answer ENOIOCTL for a
 * descriptor that is not its own (0x4600 is also the Linux framebuffer range).
 * The cdevsw name is matched against a NULL-terminated list, with the cdevsw
 * held by devvn_refthread() so that a device destroyed meanwhile cannot go
 * under us. A descriptor that cannot be taken is "not ours": the fallback then
 * reports the error. The check is made once, at entry: a descriptor replaced
 * by another thread (dup2) between this check and the ioctl is not re-checked,
 * and affects only that process's own descriptors.
 */
static inline int
nvbridge_fd_is_ours(struct thread *td, int fd, const char *const *names)
{
	struct file *fp;
	struct cdevsw *csw;
	struct cdev *dev;
	int ours = 0, ref;

	if (fget(td, fd, &cap_ioctl_rights, &fp) != 0)
		return (0);
	if (fp->f_type == DTYPE_VNODE && fp->f_vnode != NULL &&
	    fp->f_vnode->v_type == VCHR) {
		csw = devvn_refthread(fp->f_vnode, &dev, &ref);
		if (csw != NULL) {
			ours = nvbridge_name_match(csw->d_name, names);
			dev_relthread(dev, ref);
		}
	}
	fdrop(fp, td);
	return (ours);
}

/* The handler body: ENOIOCTL for a foreign descriptor, else translate and call ioctl(2). */
static inline int
nvbridge_linux_ioctl(const char *const *names, struct thread *td,
    struct linux_ioctl_args *args)
{
	u_long cmd;
	int error;

	if (!nvbridge_fd_is_ours(td, args->fd, names))
		return (ENOIOCTL);
	error = nvbridge_translate_cmd(args->cmd, &cmd);
	if (error != 0)
		return (error);
	args->cmd = cmd;
	return (sys_ioctl(td, (struct ioctl_args *)args));
}

/*
 * The module event handler shared by the provider modules: register the ioctl
 * handler and run the provider's own load step on MOD_LOAD (undone when it
 * fails); on MOD_UNLOAD unregister the handler (which waits out any call, see
 * the header comment), then run the provider's own unload step.
 */
struct nvbridge_provider {
	struct linux_ioctl_handler	*handler;
	int				(*load)(void);
	void				(*unload)(void);
};

static inline int
nvbridge_modevent(const struct nvbridge_provider *p, int what)
{
	int error;

	switch (what) {
	case MOD_LOAD:
		error = linux_ioctl_register_handler(p->handler);
		if (error == 0 && (error = p->load()) != 0)
			linux_ioctl_unregister_handler(p->handler);
		return (error);
	case MOD_UNLOAD:
		linux_ioctl_unregister_handler(p->handler);
		p->unload();
		return (0);
	case MOD_QUIESCE:
		return (0);
	default:
		return (EOPNOTSUPP);
	}
}

/*
 * NVBRIDGE_PROVIDER_MODULE(prefix, modname): the provider table, the module
 * event handler and the DECLARE_MODULE of a provider module whose
 * prefix_handler, prefix_load and prefix_unload are defined above it.
 */
#define NVBRIDGE_PROVIDER_MODULE(prefix, modname)			\
static const struct nvbridge_provider prefix##_provider = {		\
	.handler = &prefix##_handler,					\
	.load = prefix##_load,						\
	.unload = prefix##_unload,					\
};									\
static int								\
prefix##_modevent(module_t mod, int what, void *arg)			\
{									\
	return (nvbridge_modevent(&prefix##_provider, what));		\
}									\
static moduledata_t prefix##_mod = { #modname, prefix##_modevent, NULL }; \
DECLARE_MODULE(modname, prefix##_mod, SI_SUB_DRIVERS, SI_ORDER_ANY)

/*
 * NVBRIDGE_LINUXULATOR_DEPEND(modname): the provider's dependencies on the
 * Linuxulator. The 64-bit Linuxulator exports the MODULE_VERSION interface
 * linux64elf on arm64 and linux64 on amd64 (linux64elf is only a module name
 * there, which a dependency does not resolve against), and both need
 * linux_common. A 32-bit Linux binary on amd64 is not served: that needs the
 * linux interface. tests/linux_bridge_test.sh cross-builds the providers for
 * amd64 and reads the dependencies back, and checks that another architecture
 * does not build.
 */
#if defined(__aarch64__)
#define NVBRIDGE_LINUXULATOR_DEPEND(modname)				\
MODULE_DEPEND(modname, linux64elf, 1, 1, 1);				\
MODULE_DEPEND(modname, linux_common, 1, 1, 1)
#elif defined(__amd64__)
#define NVBRIDGE_LINUXULATOR_DEPEND(modname)				\
MODULE_DEPEND(modname, linux64, 1, 1, 1);				\
MODULE_DEPEND(modname, linux_common, 1, 1, 1)
#else
#error "NVBRIDGE_LINUXULATOR_DEPEND: no 64-bit Linuxulator interface known for this architecture"
#endif

#endif /* _NVBRIDGE_IOCTL_H_ */

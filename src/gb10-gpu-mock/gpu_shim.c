/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-3-Clause
 *
 * gpu_shim.c - the seam as a preload library: the fake pciconf, devinfo and
 * hw.nvidia / dev.nvidia answers of one model, for a program that reads the
 * hardware through the system calls.
 *
 * The seam is one model and one set of answers.  The mock daemon (gpu_daemon.c)
 * publishes the same model behind CUSE device nodes, for a jail; this shim
 * answers the OS layer (the sysctls) and, when no daemon runs, the ioctl path
 * too, so a program (nvrm-info, a test) reads the same answers in a CI run
 * that has no device and no root.
 *
 * The shim answers only what the model knows.  Everything else goes to the
 * real system call: a preload that answered everything would be a lie.
 *
 * Every answer it gives is a mock: the version banner says so, and the
 * answers never count as a hardware result.
 */
#include <sys/param.h>
#include <sys/ioctl.h>
#include <sys/sysctl.h>

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "gpu_mock.h"
#include "gpu_rm.h"

/* The name of the environment variable that names the model. */
#define GPU_MOCK_ENV	"GPU_MOCK"
/* The name of the environment variable that names the model directory. */
#define GPU_MOCK_DIR_ENV "GPU_MOCK_DIR"

/* The state of the shim: the model, the engine and the fake descriptors. */
static struct gpu_model shim_model;
static struct gpu_rm *shim_rm;
static int shim_loaded;
static int shim_fds[16];
static unsigned shim_nfds;

static int (*real_open)(const char *, int, ...);
static int (*real_close)(int);
static int (*real_ioctl)(int, unsigned long, ...);
static int (*real_access)(const char *, int);
static int (*real_sysctlbyname)(const char *, void *, size_t *, const void *,
    size_t);

static void
load_real(void)
{
	if (real_open != NULL)
		return;
	real_open = dlsym(RTLD_NEXT, "open");
	real_close = dlsym(RTLD_NEXT, "close");
	real_ioctl = dlsym(RTLD_NEXT, "ioctl");
	real_access = dlsym(RTLD_NEXT, "access");
	real_sysctlbyname = dlsym(RTLD_NEXT, "sysctlbyname");
}

/*
 * The model of the shim: the one GPU_MOCK names, loaded once.  Returns 0 when
 * there is no model: the shim then answers nothing and every call goes to the
 * real system call.
 */
static int
load_model(void)
{
	const char *name;
	char err[512];
	char path[1024];

	if (shim_loaded)
		return (shim_rm != NULL ? 0 : -1);
	shim_loaded = 1;
	name = getenv(GPU_MOCK_ENV);
	if (name == NULL || name[0] == '\0')
		return (-1);
	if (gpu_model_path(name, path, sizeof(path)) != 0) {
		fprintf(stderr, "gpu-mock: the shim cannot find the model "
		    "\"%s\"\n", name);
		return (-1);
	}
	if (gpu_model_load(path, &shim_model, err, sizeof(err)) != 0) {
		fprintf(stderr, "gpu-mock: the shim cannot read the model "
		    "\"%s\": %s\n", name, err);
		return (-1);
	}
	shim_rm = gpu_rm_new(&shim_model);
	if (shim_rm == NULL) {
		fprintf(stderr, "gpu-mock: the shim has no memory for the "
		    "engine\n");
		return (-1);
	}
	return (0);
}

/* Is this a device node of the NVIDIA driver? */
static int
is_nvidia_node(const char *path)
{
	if (path == NULL)
		return (0);
	return (strncmp(path, "/dev/nvidia", 11) == 0);
}

/* Is this descriptor one the shim handed out? */
static int
is_shim_fd(int fd)
{
	unsigned i;

	for (i = 0; i < shim_nfds; i++)
		if (shim_fds[i] == fd)
			return (1);
	return (0);
}

int
open(const char *path, int flags, ...)
{
	va_list ap;
	int mode = 0;
	int fd;

	va_start(ap, flags);
	if (flags & O_CREAT)
		mode = va_arg(ap, int);
	va_end(ap);
	load_real();
	if (!is_nvidia_node(path))
		return (real_open(path, flags, mode));
	if (load_model() != 0)
		return (real_open(path, flags, mode));
	/*
	 * The engine of the model answers in the place of the node: the
	 * shim is the seam, and the node of a daemon is the path for a
	 * jail, which has no shim.  The descriptor is a real one
	 * (/dev/null), because the caller limits it for capability mode and
	 * a descriptor that does not exist cannot be limited.
	 */
	if (shim_nfds >= sizeof(shim_fds) / sizeof(shim_fds[0])) {
		errno = EMFILE;
		return (-1);
	}
	fd = real_open("/dev/null", O_RDWR);
	if (fd < 0)
		return (-1);
	shim_fds[shim_nfds++] = fd;
	return (fd);
}

int
close(int fd)
{
	unsigned i;

	load_real();
	for (i = 0; i < shim_nfds; i++) {
		if (shim_fds[i] != fd)
			continue;
		shim_fds[i] = shim_fds[shim_nfds - 1];
		shim_nfds--;
		return (real_close(fd));
	}
	return (real_close(fd));
}

int
ioctl(int fd, unsigned long request, ...)
{
	va_list ap;
	void *arg;

	va_start(ap, request);
	arg = va_arg(ap, void *);
	va_end(ap);
	load_real();
	if (!is_shim_fd(fd))
		return (real_ioctl(fd, request, arg));
	if (load_model() != 0 || shim_rm == NULL) {
		errno = ENOTTY;
		return (-1);
	}
	return (gpu_rm_ioctl(shim_rm, request, arg));
}

/*
 * Is the node of the driver there?  A program that looks for the node
 * before it uses it (libnvrm's rm backend does) must find the mock's
 * node: the model answers it, so it is there for the caller.  Without
 * this the program would say "the driver is not loaded" and stop, and the
 * mock would answer nothing at all.
 */
int
access(const char *path, int mode)
{
	load_real();
	if (!is_nvidia_node(path))
		return (real_access(path, mode));
	if (load_model() != 0)
		return (real_access(path, mode));
	return (0);
}

/*
 * The sysctls of the OS layer: the ones the model knows.  Every other name
 * goes to the real sysctl(3), so the shim never hides a real value.
 *
 * The sysctls that are numbers in the kernel are numbers here too: the
 * caller reads them as an int, and a text answer would be refused.
 */
static const char *const int_sysctls[] = {
	"hw.nvidia.version_major",
	"hw.nvidia.version_minor",
	"hw.nvidia.version_patch",
	"hw.nvidia.version_available",
	"hw.nvidia.altra_device_wc_active"
};

static int
is_int_sysctl(const char *name)
{
	unsigned i;

	for (i = 0; i < sizeof(int_sysctls) / sizeof(int_sysctls[0]); i++)
		if (strcmp(int_sysctls[i], name) == 0)
			return (1);
	return (0);
}

int
sysctlbyname(const char *name, void *oldp, size_t *oldlenp, const void *newp,
    size_t newlen)
{
	char value[4096];

	load_real();
	if (name == NULL)
		return (real_sysctlbyname(name, oldp, oldlenp, newp, newlen));
	if (load_model() != 0)
		return (real_sysctlbyname(name, oldp, oldlenp, newp, newlen));
	if (gpu_seam_sysctl(&shim_model, name, value, sizeof(value)) != 0)
		return (real_sysctlbyname(name, oldp, oldlenp, newp, newlen));
	if (oldp == NULL) {
		if (oldlenp != NULL)
			*oldlenp = is_int_sysctl(name) ? sizeof(int) :
			    strlen(value) + 1;
		return (0);
	}
	if (oldlenp == NULL) {
		errno = EINVAL;
		return (-1);
	}
	if (is_int_sysctl(name)) {
		int number;

		number = (int)strtol(value, NULL, 10);
		if (*oldlenp < sizeof(number)) {
			errno = ENOMEM;
			return (-1);
		}
		memcpy(oldp, &number, sizeof(number));
		*oldlenp = sizeof(number);
		return (0);
	}
	if (*oldlenp < strlen(value) + 1) {
		errno = ENOMEM;
		return (-1);
	}
	memcpy(oldp, value, strlen(value) + 1);
	*oldlenp = strlen(value) + 1;
	return (0);
}

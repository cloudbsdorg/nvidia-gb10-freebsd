/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-3-Clause
 *
 * nvkms_ioctl_probe.c - one Linux NVKMS ioctl, for the test-boot kit of the
 * Linux bridges (row B3-nvkms-ioctl). Built by make-be.sh as a freestanding,
 * static LINUX program (raw system calls, no libc), branded with
 * brandelf -t Linux, and run by the recorder as root inside the Linuxulator
 * after nvidia_modeset_linux.ko is loaded.
 *
 * It opens /dev/nvidia-modeset and sends the NVKMS ioctl (magic 'm', command
 * 0, struct NvKmsIoctlParams of 16 bytes: Linux command 0xc0106d00) with an
 * inner command NVKMS cannot dispatch. What the answer says:
 *   - the provider translated the command and nvidia-modeset.ko ran it: the
 *     ioctl returns 0 or EPERM (nvkms_ioctl_common: 0 or EPERM);
 *   - nothing translated it: the Linuxulator answers EINVAL (no handler for
 *     0x6d00). nvkms_ioctl (nvidia-modeset-freebsd.c) answers EINVAL only when the
 *     outer command number is not NVKMS_IOCTL_CMD or its size is not
 *     sizeof(struct NvKmsIoctlParams): a translation that corrupts the command or
 *     the size. An inner command NVKMS has no entry for is not that case: it goes
 *     to nvkms_ioctl_common, which answers 0 or EPERM.
 * Exit status: 0 reached NVKMS; 2 the device did not open; 3 EINVAL or ENOTTY
 * (the provider is missing or mistranslates); 4 any other answer.
 * One line goes to standard output, ending with the meaning of the exit status:
 * "nvkms_ioctl_probe: open=<fd> ioctl=<ret> verdict=<word>".
 *
 * The syscall layer is the only part that is not portable; a host unit test
 * (tests/linux_bridge_kit_test.sh) builds this file with
 * -DNVKMS_PROBE_HOST_TEST against a fake syscall layer and checks the command
 * number, the parameters and the exit status for each answer.
 */
typedef unsigned int u32;
typedef unsigned long long u64;

#define NVKMS_PROBE_IOCTL	0xc0106d00UL	/* Linux _IOWR('m', 0, struct NvKmsIoctlParams) */
#define NVKMS_PROBE_BADCMD	0xffffffffU	/* an inner command NVKMS has no entry for */
#define PROBE_EPERM		1
#define PROBE_EINVAL		22
#define PROBE_ENOTTY		25
#define PROBE_O_RDWR		2
#define PROBE_AT_FDCWD		(-100)

struct nvkms_params {
	u32 cmd;
	u32 size;
	u64 address;
};

#ifdef NVKMS_PROBE_HOST_TEST
extern long probe_sys_openat(long dirfd, const char *path, long flags, long mode);
extern long probe_sys_ioctl(long fd, unsigned long cmd, void *arg);
extern long probe_sys_write(long fd, const char *buf, unsigned long len);
extern void probe_sys_exit(long status);
#else
#if defined(__aarch64__)
#define SYS_ioctl	29
#define SYS_openat	56
#define SYS_write	64
#define SYS_exit_group	94
static long
sys4(long n, long a, long b, long c, long d)
{
	register long x8 __asm__("x8") = n;
	register long x0 __asm__("x0") = a;
	register long x1 __asm__("x1") = b;
	register long x2 __asm__("x2") = c;
	register long x3 __asm__("x3") = d;

	__asm__ volatile("svc #0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2), "r"(x3) : "memory", "cc");
	return (x0);
}
#elif defined(__x86_64__)
#define SYS_write	1
#define SYS_ioctl	16
#define SYS_openat	257
#define SYS_exit_group	231
static long
sys4(long n, long a, long b, long c, long d)
{
	long ret;
	register long r10 __asm__("r10") = d;

	__asm__ volatile("syscall" : "=a"(ret) : "0"(n), "D"(a), "S"(b), "d"(c), "r"(r10) : "rcx", "r11", "memory", "cc");
	return (ret);
}
#else
#error "nvkms_ioctl_probe supports aarch64 and x86_64 only"
#endif
#define probe_sys_openat(d, p, f, m)	sys4(SYS_openat, (d), (long)(p), (f), (m))
#define probe_sys_ioctl(fd, c, a)	sys4(SYS_ioctl, (fd), (long)(c), (long)(a), 0)
#define probe_sys_write(fd, b, l)	sys4(SYS_write, (fd), (long)(b), (long)(l), 0)
#define probe_sys_exit(s)		((void)sys4(SYS_exit_group, (s), 0, 0, 0))
#endif

static unsigned long
cstrlen(const char *s)
{
	unsigned long n = 0;

	while (s[n] != '\0')
		n++;
	return (n);
}

static void
say(const char *s)
{
	(void)probe_sys_write(1, s, cstrlen(s));
}

/* sayl: a signed decimal, no libc */
static void
sayl(long v)
{
	char b[24];
	int i = sizeof(b) - 1;
	unsigned long u = v < 0 ? 0UL - (unsigned long)v : (unsigned long)v;

	b[i] = '\0';
	do {
		b[--i] = (char)('0' + u % 10);
		u /= 10;
	} while (u != 0);
	if (v < 0)
		b[--i] = '-';
	say(&b[i]);
}

/* probe_main: returns the exit status described above */
int
probe_main(void)
{
	struct nvkms_params p;
	long fd, r;

	fd = probe_sys_openat(PROBE_AT_FDCWD, "/dev/nvidia-modeset", PROBE_O_RDWR, 0);
	say("nvkms_ioctl_probe: open=");
	sayl(fd);
	if (fd < 0) {
		say(" verdict=open-failed\n");
		return (2);
	}
	p.cmd = NVKMS_PROBE_BADCMD;
	p.size = 0;
	p.address = 0;
	r = probe_sys_ioctl(fd, NVKMS_PROBE_IOCTL, &p);
	say(" ioctl=");
	sayl(r);
	if (r == 0 || r == -PROBE_EPERM) {
		say(" verdict=reached-nvkms\n");
		return (0);
	}
	if (r == -PROBE_EINVAL || r == -PROBE_ENOTTY) {
		say(" verdict=not-translated\n");
		return (3);
	}
	say(" verdict=other-answer\n");
	return (4);
}

#ifndef NVKMS_PROBE_HOST_TEST
#if defined(__x86_64__)
/* the process enters _start with the stack 16-byte aligned and no return address; C code expects 8 off */
__attribute__((force_align_arg_pointer))
#endif
void
_start(void)
{
	probe_sys_exit(probe_main());
	for (;;)
		;
}
#endif

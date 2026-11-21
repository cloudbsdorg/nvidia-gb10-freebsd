/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-3-Clause
 *
 * Host unit test of src/gb10-linux-bridge/nvbridge_ioctl.h (Track #2363): the
 * ioctl command translation, the device-name match, the descriptor filter and
 * the module event handler, against stub kernel declarations.
 */
#include <stdio.h>
#include "nvbridge_ioctl.h"

const int cap_ioctl_rights = 0;

/* fake descriptor table */
static struct cdevsw csw_ctl = { "nvidiactl" }, csw_fb = { "fb" };
static struct cdev dev_ctl = { &csw_ctl }, dev_fb = { &csw_fb };
static struct vnode vn_ctl = { VCHR }, vn_fb = { VCHR }, vn_reg = { 1 }, vn_gone = { VCHR };
static struct file f_ctl = { DTYPE_VNODE, &vn_ctl }, f_fb = { DTYPE_VNODE, &vn_fb },
    f_sock = { 2, NULL }, f_reg = { DTYPE_VNODE, &vn_reg }, f_gone = { DTYPE_VNODE, &vn_gone };
static int refs_open, files_open, sys_ioctl_calls;
static u_long last_cmd;
static int sys_ioctl_ret;

int fget(struct thread *td, int fd, const void *r, struct file **fpp)
{
	struct file *t[] = { NULL, NULL, NULL, &f_ctl, &f_fb, &f_sock, &f_reg, &f_gone };
	(void)td; (void)r;
	if (fd < 3 || fd > 7)
		return (EBADF);
	*fpp = t[fd];
	files_open++;
	return (0);
}
void fdrop(struct file *fp, struct thread *td) { (void)fp; (void)td; files_open--; }
struct cdevsw *devvn_refthread(struct vnode *vp, struct cdev **devp, int *ref)
{
	if (vp == &vn_gone)
		return (NULL);
	*devp = vp == &vn_fb ? &dev_fb : &dev_ctl;	/* a regular vnode would look like nvidiactl: only the VCHR test keeps it out */
	*ref = 1;
	refs_open++;
	return ((*devp)->si_devsw);
}
void dev_relthread(struct cdev *d, int ref) { (void)d; (void)ref; refs_open--; }
int sys_ioctl(struct thread *td, struct ioctl_args *a) { (void)td; sys_ioctl_calls++; last_cmd = a->com; return (sys_ioctl_ret); }

static int handlers, loads, unloads, load_ret;
int linux_ioctl_register_handler(struct linux_ioctl_handler *h) { (void)h; handlers++; return (0); }
int linux_ioctl_unregister_handler(struct linux_ioctl_handler *h) { (void)h; handlers--; return (0); }

static int fails;
#define CHECK(c, msg) do { if (!(c)) { printf("FAIL: %s\n", msg); fails++; } else printf("PASS: %s\n", msg); } while (0)

static int my_load(void) { loads++; return (load_ret); }
static void my_unload(void) { unloads++; }
static struct linux_ioctl_handler my_handler = { NULL, 0x4600, 0x46ff };
static const struct nvbridge_provider my_provider = { &my_handler, my_load, my_unload };

int main(void)
{
	static const char *const names[] = { "nvidiactl", "nvidia", NULL };
	struct thread td;
	struct linux_ioctl_args args;
	u_long out;

	/* translation */
	CHECK(nvbridge_translate_cmd(0x40044601UL, &out) == 0 && out == 0x80044601UL, "Linux IN becomes FreeBSD IN");
	CHECK(nvbridge_translate_cmd(0x80044601UL, &out) == 0 && out == 0x40044601UL, "Linux OUT becomes FreeBSD OUT");
	CHECK(nvbridge_translate_cmd(0xc0044601UL, &out) == 0 && out == 0xc0044601UL, "Linux IN|OUT stays IN|OUT");
	CHECK(nvbridge_translate_cmd(0x00004601UL, &out) == 0 && out == 0x20004601UL, "Linux VOID becomes FreeBSD VOID");
	CHECK(nvbridge_translate_cmd(0x20044601UL, &out) == EINVAL, "a size field that reaches bit 29 is EINVAL");
	CHECK(nvbridge_translate_cmd(0xe0044601UL, &out) == EINVAL, "IN|OUT with bit 29 set is EINVAL");
	/* name match */
	CHECK(nvbridge_name_match("nvidiactl", names) && nvbridge_name_match("nvidia", names), "the two cdevsw names match");
	CHECK(!nvbridge_name_match("fb", names) && !nvbridge_name_match("nvidia0", names) && !nvbridge_name_match("", names), "fb, nvidia0 (a si_name) and the empty name do not match");
	/* descriptor filter */
	CHECK(nvbridge_fd_is_ours(&td, 3, names) == 1, "a descriptor of nvidiactl is ours");
	CHECK(nvbridge_fd_is_ours(&td, 4, names) == 0, "a descriptor of another character device is not");
	CHECK(nvbridge_fd_is_ours(&td, 5, names) == 0, "a socket is not");
	CHECK(nvbridge_fd_is_ours(&td, 6, names) == 0, "a regular vnode is not");
	CHECK(nvbridge_fd_is_ours(&td, 7, names) == 0, "a device that is being destroyed is not");
	CHECK(nvbridge_fd_is_ours(&td, 9, names) == 0, "a bad descriptor is not");
	CHECK(refs_open == 0 && files_open == 0, "every device thread reference and file reference was released");
	/* the handler */
	args.fd = 4; args.cmd = 0xc0044601UL; sys_ioctl_calls = 0;
	CHECK(nvbridge_linux_ioctl(names, &td, &args) == ENOIOCTL && sys_ioctl_calls == 0, "a foreign descriptor gets ENOIOCTL and nothing reaches ioctl(2)");
	args.fd = 3; args.cmd = 0x40044601UL; sys_ioctl_ret = 0;
	CHECK(nvbridge_linux_ioctl(names, &td, &args) == 0 && sys_ioctl_calls == 1 && last_cmd == 0x80044601UL, "our descriptor is translated and handed to ioctl(2)");
	sys_ioctl_ret = 25;
	CHECK(nvbridge_linux_ioctl(names, &td, &args) == 25, "ioctl(2)'s error is returned");
	args.cmd = 0x20044601UL; sys_ioctl_calls = 0;
	CHECK(nvbridge_linux_ioctl(names, &td, &args) == EINVAL && sys_ioctl_calls == 0, "a command with bit 29 is EINVAL without reaching ioctl(2)");
	/* the module event handler */
	CHECK(nvbridge_modevent(&my_provider, MOD_LOAD) == 0 && handlers == 1 && loads == 1, "MOD_LOAD registers the handler and runs the load step");
	CHECK(nvbridge_modevent(&my_provider, MOD_QUIESCE) == 0, "MOD_QUIESCE is not vetoed");
	CHECK(nvbridge_modevent(&my_provider, MOD_UNLOAD) == 0 && handlers == 0 && unloads == 1, "MOD_UNLOAD unregisters the handler and runs the unload step");
	load_ret = ENODEV;
	CHECK(nvbridge_modevent(&my_provider, MOD_LOAD) == ENODEV && handlers == 0, "a failing load step takes the handler back");
	CHECK(nvbridge_modevent(&my_provider, 99) == EOPNOTSUPP, "an unknown event is EOPNOTSUPP");
	return (fails != 0);
}

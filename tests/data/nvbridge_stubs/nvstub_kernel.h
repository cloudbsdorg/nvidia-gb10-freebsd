/* host stub of the kernel and Linuxulator declarations nvbridge_ioctl.h uses */
#ifndef _NVSTUB_KERNEL_H
#define _NVSTUB_KERNEL_H
#include <sys/types.h>
#include <errno.h>
#include <string.h>
#define ENOIOCTL (-3)
#define IOC_VOID	0x20000000UL
#define IOC_OUT		0x40000000UL
#define IOC_IN		0x80000000UL
#define IOC_INOUT	(IOC_IN | IOC_OUT)
#define IOC_DIRMASK	0xe0000000UL
#define LINUX_IOC_VOID	0
#define LINUX_IOC_IN	0x40000000
#define LINUX_IOC_OUT	0x80000000
#define LINUX_IOC_INOUT	(LINUX_IOC_IN | LINUX_IOC_OUT)
struct thread { int unused; };
struct linux_ioctl_args { int fd; u_long cmd; void *arg; };
struct ioctl_args { int fd; u_long com; void *data; };
typedef int linux_ioctl_function_t(struct thread *, struct linux_ioctl_args *);
struct linux_ioctl_handler { linux_ioctl_function_t *func; int low, high; };
int linux_ioctl_register_handler(struct linux_ioctl_handler *);
int linux_ioctl_unregister_handler(struct linux_ioctl_handler *);
struct linux_device_handler { char *bsd_driver_name, *linux_driver_name, *bsd_device_name, *linux_device_name; int linux_major, linux_minor, linux_char_device; };
int sys_ioctl(struct thread *, struct ioctl_args *);
struct cdevsw { const char *d_name; };
struct cdev { struct cdevsw *si_devsw; };
struct vnode { int v_type; };
#define VCHR 4
struct file { int f_type; struct vnode *f_vnode; };
#define DTYPE_VNODE 1
extern const int cap_ioctl_rights;
int fget(struct thread *, int, const void *, struct file **);
void fdrop(struct file *, struct thread *);
struct cdevsw *devvn_refthread(struct vnode *, struct cdev **, int *);
void dev_relthread(struct cdev *, int);
typedef struct module *module_t;
typedef struct moduledata { const char *name; int (*evhand)(module_t, int, void *); void *priv; } moduledata_t;
#define MOD_LOAD 0
#define MOD_UNLOAD 1
#define MOD_QUIESCE 3
#define SI_SUB_DRIVERS 0
#define SI_ORDER_ANY 0
#define DECLARE_MODULE(name, data, sub, order) struct stub_declared_##name { int x; }
#endif

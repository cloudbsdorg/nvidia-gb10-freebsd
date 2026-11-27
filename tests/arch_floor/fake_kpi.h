/*
 * User-space fake of the FreeBSD kernel interfaces that
 * src/gb10-archfloor/nv_arch_floor.c uses, for tests/arch_floor_test.sh.
 * Every fake header in this directory includes this one file.
 *
 * Each fake device carries a BAR0 page.  The fake enforces what real
 * hardware does and what the driver must respect: while memory decode is
 * off, a mapping reads all ones; sleeping calls must not run under a mutex;
 * every allocation, mapping and decode change is counted so the test can
 * check that nothing is left behind.
 */
#ifndef FAKE_KPI_H
#define FAKE_KPI_H

#include <sys/types.h>
#include <errno.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define PAGE_SIZE		4096

typedef uintmax_t rman_res_t;
typedef unsigned int u_int;

/* bus and PCI */
#define SYS_RES_MEMORY		3
#define RF_ACTIVE		0x0002
#define PCIR_COMMAND		0x04
#define PCIR_BAR(x)		(0x10 + (x) * 4)
#define PCIM_CMD_MEMEN		0x0002

struct resource {
	rman_res_t start;
};

struct _device {
	uint16_t vendor;
	uint16_t device_id;
	int domain, bus, slot, function;
	uint16_t command;
	uint16_t command_initial;
	int alloc_fails;
	uint32_t page[PAGE_SIZE / 4];
	uint32_t ones[PAGE_SIZE / 4];
	struct resource res;
	/* the parent device: the PCI device the driver sits on */
	struct _device *parent;
	char nameunit[16];
	/* counters */
	int allocs, releases, maps, unmaps, enables, disables;
	int alloc_flags, alloc_rid, release_rid;
	size_t map_len, unmap_len;
	int live_res, live_map;
	int touched;
};

extern int fake_mutex_held;
extern int fake_failures;
extern int fake_log_count;
extern char fake_log[64][512];
extern int fake_malloc_outstanding;
extern struct _device *fake_devices[128];
extern int fake_ndevices;

void fake_fail(const char *what);

static inline uint16_t pci_get_vendor(device_t d) { return (d->vendor); }
static inline uint16_t pci_get_device(device_t d) { return (d->device_id); }
static inline int pci_get_domain(device_t d) { return (d->domain); }
static inline int pci_get_bus(device_t d) { return (d->bus); }
static inline int pci_get_slot(device_t d) { return (d->slot); }
static inline int pci_get_function(device_t d) { return (d->function); }
static inline struct _device *device_get_parent(device_t d) { return (d->parent); }
static inline const char *device_get_nameunit(device_t d) { return (d->nameunit); }

struct resource *fake_bus_alloc_resource_any(device_t, int, int *, u_int);
int fake_bus_release_resource(device_t, int, int, struct resource *);
#define bus_alloc_resource_any(d, t, ridp, f) \
	fake_bus_alloc_resource_any((d), (t), (ridp), (f))
#define bus_release_resource(d, t, rid, r) \
	fake_bus_release_resource((d), (t), (rid), (r))
static inline rman_res_t rman_get_start(struct resource *r) { return (r->start); }

uint32_t fake_pci_read_config(device_t, int, int);
void fake_pci_enable_io(device_t, int);
void fake_pci_disable_io(device_t, int);
#define pci_read_config(d, reg, w)	fake_pci_read_config((d), (reg), (w))
#define pci_enable_io(d, s)		fake_pci_enable_io((d), (s))
#define pci_disable_io(d, s)		fake_pci_disable_io((d), (s))

void *fake_pmap_mapdev(uintptr_t, size_t);
void fake_pmap_unmapdev(void *, size_t);
#define pmap_mapdev(pa, len)		fake_pmap_mapdev((pa), (len))
#define pmap_unmapdev(va, len)		fake_pmap_unmapdev((va), (len))

int fake_device_printf(device_t, const char *, ...)
    __attribute__((format(printf, 2, 3)));
#define device_printf			fake_device_printf

/* mutex, kernel, malloc */
struct mtx {
	int locked;
};
#define MTX_DEF				0
#define MTX_SYSINIT(name, mtx, desc, opts)
void fake_mtx_lock(struct mtx *);
void fake_mtx_unlock(struct mtx *);
#define mtx_lock(m)			fake_mtx_lock(m)
#define mtx_unlock(m)			fake_mtx_unlock(m)

struct malloc_type { int unused; };
extern struct malloc_type fake_m_temp;
#define M_TEMP				(&fake_m_temp)
#define M_WAITOK			0x0002
#define M_ZERO				0x0100
void *fake_malloc(size_t, struct malloc_type *, int);
void fake_free(void *, struct malloc_type *);
#undef malloc
#undef free
#define malloc(size, type, flags)	fake_malloc((size), (type), (flags))
#define free(p, type)			fake_free((p), (type))

/* sysctl */
#define CTLTYPE_INT			2
#define CTLTYPE_STRING			3
#define CTLFLAG_RD			0x80000000
#define CTLFLAG_WR			0x40000000
#define CTLFLAG_MPSAFE			0x00040000
#define CTLFLAG_DYN			0x00010000
#define OID_AUTO			(-1)

struct sysctl_ctx_list { int unused; };
struct sysctl_req {
	char out[8192];
	size_t outlen;
};
struct sysctl_oid;
typedef int (*fake_handler)(struct sysctl_oid *, void *, int,
    struct sysctl_req *);
struct sysctl_oid {
	const char *name;
	int kind;			/* 1 int, 2 string, 3 proc */
	int flags;
	int *int_ptr;
	char *str_ptr;
	fake_handler handler;
	const char *fmt;
};
#define SYSCTL_HANDLER_ARGS \
	struct sysctl_oid *oidp, void *arg1, int arg2, struct sysctl_req *req
#define SYSCTL_CHILDREN(oid)		(oid)

#define SYSCTL_ADD_INT(ctx, parent, nbr, name, flags, ptr, val, descr) \
	fake_add_int((parent), (name), (flags), (ptr))
#define SYSCTL_ADD_STRING(ctx, parent, nbr, name, flags, ptr, len, descr) \
	fake_add_string((parent), (name), (flags), (ptr))
#define SYSCTL_ADD_PROC(ctx, parent, nbr, name, flags, a1, a2, h, fmt, descr) \
	fake_add_proc((parent), (name), (flags), (h), (fmt))
struct sysctl_oid *fake_add_int(struct sysctl_oid *, const char *, int, int *);
struct sysctl_oid *fake_add_string(struct sysctl_oid *, const char *, int, char *);
struct sysctl_oid *fake_add_proc(struct sysctl_oid *, const char *, int,
    fake_handler, const char *);
int fake_sysctl_out(struct sysctl_req *, const void *, size_t);
#define SYSCTL_OUT(req, ptr, len)	fake_sysctl_out((req), (ptr), (len))

#endif /* FAKE_KPI_H */

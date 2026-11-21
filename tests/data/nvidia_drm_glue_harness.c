/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-3-Clause
 *
 * nvidia_drm_glue_harness.c - tests/prime_import_test.sh compiles the REAL functions of the
 * patched nvidia-drm sources (extracted by name into glue_decls.h and glue_funcs.h) against
 * gb10_pageimport.h with the stubs below, and runs the scenarios in main().  The stubs
 * make the kernel services observable: the spin lock is a flag that the gate functions assert
 * (a gate decision made outside the lock is counted as a violation), the GEM reference, the
 * device destroy and the pdev detach are counters.  Each failed expectation prints one line
 * starting with FAIL; a good tree prints nothing but "glue ok".
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "gb10_pageimport.h"

#define EBUSY		16
#define EOPNOTSUPP	45
#define MOD_LOAD	0
#define MOD_UNLOAD	1
#define MOD_QUIESCE	3
#define NV_MAX_DEVICES	2
#define __FreeBSD_version 1600031
#define M_DEVBUF	0

typedef void *module_t;
typedef struct { int unused; } spinlock_t;
#define DEFINE_SPINLOCK(x) spinlock_t x

static int spin_held, spin_violations;
static void spin_lock(spinlock_t *l) { (void)l; spin_held = 1; }
static void spin_unlock(spinlock_t *l) { (void)l; spin_held = 0; }

/* the gate decisions must be made with the lock held */
static void need_lock(void) { if (!spin_held) spin_violations++; }
#define gb10_pi_gate_hold(g)	(need_lock(), (gb10_pi_gate_hold)(g))
#define gb10_pi_gate_quiesce(g)	(need_lock(), (gb10_pi_gate_quiesce)(g))
#define gb10_pi_gate_keep(g)	(need_lock(), (gb10_pi_gate_keep)(g))

struct drm_gem_object { int refs; };
struct nv_drm_gem_object { struct drm_gem_object base; };
static int gem_gets, gem_puts;
static void drm_gem_object_get(struct drm_gem_object *o) { o->refs++; gem_gets++; }
static void nv_drm_gem_object_unreference_unlocked(struct nv_drm_gem_object *o) { o->base.refs--; gem_puts++; }

struct nv_drm_device { void *dev; };
static struct nv_drm_device devs[2];
static int ndevs = 2, devs_destroyed, devs_unregistered;
static struct nv_drm_device *nv_drm_pop_device(void) { return ndevs > 0 ? &devs[--ndevs] : NULL; }
static void drm_dev_unregister(void *d) { (void)d; devs_unregistered++; }
static void nv_drm_dev_destroy(struct nv_drm_device *d) { (void)d; devs_destroyed++; }
#define NV_DRM_LOG_ERR(fmt, ...) printf("log: " fmt "\n", ##__VA_ARGS__)

static void *nv_lkpi_pci_devs[NV_MAX_DEVICES] = { &devs[0], &devs[1] };
static int pdevs_detached, pdevs_freed;
static void linux_pci_detach_device(void *p) { (void)p; pdevs_detached++; }
#define free(p, t) (pdevs_freed++)

static void nv_drm_remove_devices(void);
static void nv_drm_exit(void) { nv_drm_remove_devices(); }

#include "glue_decls.h"
#include "glue_funcs.h"

static int failures;
#define EXPECT(cond, what) do { if (!(cond)) { printf("FAIL %s\n", what); failures++; } } while (0)

static void reset(void)
{
	memset(&__nv_drm_pi_gate, 0, sizeof(__nv_drm_pi_gate));
	spin_held = spin_violations = 0;
	gem_gets = gem_puts = 0;
	ndevs = 2; devs_destroyed = devs_unregistered = 0;
	nv_lkpi_pci_devs[0] = &devs[0]; nv_lkpi_pci_devs[1] = &devs[1];
	pdevs_detached = pdevs_freed = 0;
}

static struct nv_drm_gem_object gem;

/* an export is held: neither MOD_QUIESCE nor MOD_UNLOAD agrees, and nothing is torn down */
static void sc_export_held(void)
{
	reset();
	EXPECT(__nv_drm_gem_dma_buf_pi_hold(&gem) == 0, "a hold on an open gate is given");
	EXPECT(gem_gets == 1 && nv_drm_pi_live_holds() == 1, "the hold takes one GEM reference and is counted");
	EXPECT(nv_drm_pi_guard_handler(NULL, MOD_QUIESCE, NULL) == EBUSY, "MOD_QUIESCE with an export held answers EBUSY");
	EXPECT(nv_drm_pi_guard_handler(NULL, MOD_UNLOAD, NULL) == EBUSY, "MOD_UNLOAD with an export held answers EBUSY");
	EXPECT(__nv_drm_pi_gate.closing == 0, "a refused quiesce does not close the gate");
	EXPECT(nv_drm_pi_guard_handler(NULL, MOD_LOAD, NULL) == 0, "MOD_LOAD is fine");
	EXPECT(nv_drm_pi_guard_handler(NULL, 99, NULL) == EOPNOTSUPP, "an unknown event is not supported");
}

/* the teardown with an export held (the fallback for another module order): nothing destroyed, nothing freed; the gate is kept and closed */
static void sc_teardown_held(void)
{
	nv_bsd_drm_exit();
	EXPECT(devs_destroyed == 0 && devs_unregistered == 0, "the devices are kept while an export is held");
	EXPECT(pdevs_detached == 0 && pdevs_freed == 0, "the pdevs are kept while an export is held");
	EXPECT(ndevs == 2, "no device was even taken off the list");
	EXPECT(__nv_drm_pi_gate.kept == 1 && __nv_drm_pi_gate.closing == 1, "keeping the devices marks the gate kept and closed");
	EXPECT(__nv_drm_gem_dma_buf_pi_hold(&gem) != 0 && gem_gets == 1, "after the devices were kept, no new export is given");
	/* the RM releases (the core does the count, as gb10_pi_release() does in nvidia.ko) */
	__nv_drm_gem_dma_buf_pi_release(&gem);
	gb10_pi_gate_drop(&__nv_drm_pi_gate);
	EXPECT(gem_puts == 1 && gb10_pi_gate_live(&__nv_drm_pi_gate) == 0, "the release drops the reference and the count goes to zero");
	/* the exports are closed and the module is unloaded again: the kept devices are still not torn down */
	nv_bsd_drm_exit();
	EXPECT(devs_destroyed == 0 && devs_unregistered == 0 && pdevs_detached == 0 && pdevs_freed == 0 && ndevs == 2, "a later teardown, after the exports closed, still keeps the devices and pdevs");
	EXPECT(nv_drm_pi_live_holds() > 0, "a kept gate keeps reporting that the devices must stay");
}

/* no export held: the quiesce agrees and closes the gate; a closed gate gives no hold and takes no reference */
static void sc_closed_gate(void)
{
	reset();
	EXPECT(nv_drm_pi_guard_handler(NULL, MOD_QUIESCE, NULL) == 0, "MOD_QUIESCE with no export held agrees");
	EXPECT(__nv_drm_pi_gate.closing == 1, "the quiesce closes the gate");
	EXPECT(__nv_drm_gem_dma_buf_pi_hold(&gem) != 0, "a closed gate refuses a hold");
	EXPECT(gem_gets == 0 && gem.base.refs == 0, "a refused hold takes no GEM reference");
	EXPECT(nv_drm_pi_live_holds() == 0, "a refused hold is not counted");
}

/* no export held: the teardown runs completely, and MOD_UNLOAD also closes the gate */
static void sc_teardown_free(void)
{
	reset();
	nv_bsd_drm_exit();
	EXPECT(devs_destroyed == 2 && devs_unregistered == 2, "with no export held the devices are destroyed");
	EXPECT(pdevs_detached == 2 && pdevs_freed == 2, "with no export held the pdevs are detached and freed");
	reset();
	EXPECT(nv_drm_pi_guard_handler(NULL, MOD_UNLOAD, NULL) == 0 && __nv_drm_pi_gate.closing == 1, "MOD_UNLOAD with no export held agrees and closes the gate");
}

/*
 * the real kldunload sequence (kern_linker.c linker_file_unload): the quiesce pass (a refusal is ignored when
 * forced), then the unload pass (a refusal stops the unload whatever the flags), then the driver's teardown
 */
static int kldunload(int force)
{
	if (nv_drm_pi_guard_handler(NULL, MOD_QUIESCE, NULL) != 0 && !force)
		return EBUSY;
	if (nv_drm_pi_guard_handler(NULL, MOD_UNLOAD, NULL) != 0)
		return EBUSY;
	nv_bsd_drm_exit();
	return 0;
}

static void sc_kldunload(void)
{
	int force;

	for (force = 0; force <= 1; force++) {
		reset();
		__nv_drm_gem_dma_buf_pi_hold(&gem);
		EXPECT(kldunload(force) == EBUSY, force ? "kldunload -f with an export held is stopped" : "kldunload with an export held is stopped");
		EXPECT(devs_destroyed == 0 && pdevs_detached == 0, force ? "kldunload -f with an export held tears nothing down" : "kldunload with an export held tears nothing down");
	}
	reset();
	EXPECT(kldunload(0) == 0, "kldunload with no export held is agreed by both passes");
	EXPECT(devs_destroyed == 2 && pdevs_detached == 2, "kldunload with no export held tears the driver down");
}

int main(void)
{
	sc_export_held();
	sc_teardown_held();
	sc_closed_gate();
	sc_teardown_free();
	sc_kldunload();

	EXPECT(spin_violations == 0, "every gate decision was made with the spin lock held");
	if (failures == 0)
		printf("glue ok\n");
	return failures ? 1 : 0;
}

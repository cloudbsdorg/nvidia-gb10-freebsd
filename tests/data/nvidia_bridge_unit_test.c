/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-3-Clause
 *
 * Host unit test of src/gb10-linux-bridge/nvidia_bridge.c (Track #2363): the
 * file is compiled into this program against stub kernel headers
 * (tests/data/nvbridge_stubs) and driven by a fake provider.
 */
#include <stdio.h>
#include "nvidia_bridge.c"

int stub_live_allocs;
int stub_sx_max_depth;

#define MAXEV 64
static char evlog[MAXEV][64];
static int nev;
static int refuse_at = -1;	/* refuse the add with this 1-based index */
static int adds_seen;
static int accepted;	/* adds the fake provider accepted since the last reset() */

static int fake_add(const struct nvidia_bridge_cdev *c)
{
	adds_seen++;
	if (nev < MAXEV)
		snprintf(evlog[nev++], 64, "add %s %d %d", c->nbc_name, c->nbc_major, c->nbc_minor);
	if (adds_seen == refuse_at)
		return (ENODEV);
	accepted++;
	return (0);
}
static void fake_del(const struct nvidia_bridge_cdev *c)
{
	if (nev < MAXEV)
		snprintf(evlog[nev++], 64, "del %s %d", c->nbc_name, c->nbc_minor);
}
static struct nvidia_bridge_ops good = { NVIDIA_BRIDGE_KPI_VERSION, sizeof(struct nvidia_bridge_ops), fake_add, fake_del };

static int fails;
#define CHECK(c, msg) do { if (!(c)) { printf("FAIL: %s\n", msg); fails++; } else printf("PASS: %s\n", msg); } while (0)
static void reset(void) { nev = 0; adds_seen = 0; accepted = 0; refuse_at = -1; }
static int ev_is(int i, const char *s) { return i < nev && strcmp(evlog[i], s) == 0; }
static int ev_has(const char *s) { int i; for (i = 0; i < nev; i++) if (strstr(evlog[i], s) != NULL) return (1); return (0); }

int main(void)
{
	struct nvidia_bridge_ops bad;

#ifdef NV_CORE_LINUX_COMPAT
	CHECK(nvidia_bridge_register(&good) == ENXIO, "a legacy (in-core bridge) build refuses a provider with ENXIO");
	return (fails != 0);
#endif
	/* validation */
	CHECK(nvidia_bridge_register(NULL) == EINVAL, "register(NULL) is EINVAL");
	bad = good; bad.nbo_version = NVIDIA_BRIDGE_KPI_VERSION + 1;
	CHECK(nvidia_bridge_register(&bad) == EINVAL, "another version is EINVAL");
	bad = good; bad.nbo_size = sizeof(good) + 8;
	CHECK(nvidia_bridge_register(&bad) == EINVAL, "another size is EINVAL");
	bad = good; bad.nbo_cdev_del = NULL;
	CHECK(nvidia_bridge_register(&bad) == EINVAL, "a missing nbo_cdev_del is EINVAL");
	bad = good; bad.nbo_cdev_add = NULL;
	CHECK(nvidia_bridge_register(&bad) == EINVAL, "a missing nbo_cdev_add is EINVAL");

	/* replay of devices that exist before the provider */
	nvidia_bridge_cdev_added("nvidiactl", 195, 255);
	nvidia_bridge_cdev_added("nvidia0", 195, 0);
	nvidia_bridge_cdev_added("nvidia1", 195, 1);
	reset();
	CHECK(nvidia_bridge_register(&good) == 0, "register succeeds");
	CHECK(nev == 3 && ev_is(0, "add nvidiactl 195 255") && ev_is(1, "add nvidia0 195 0") && ev_is(2, "add nvidia1 195 1"), "the existing devices are replayed in order");
	CHECK(nvidia_bridge_register(&good) == EBUSY, "a second provider is EBUSY");
	/* live add and remove */
	reset();
	nvidia_bridge_cdev_added("nvidia2", 195, 2);
	CHECK(nev == 1 && ev_is(0, "add nvidia2 195 2"), "a device that appears later is announced");
	reset();
	nvidia_bridge_cdev_removed("nvidia1", 1);
	CHECK(nev == 1 && ev_is(0, "del nvidia1 1"), "a removed device is announced by name and minor");
	reset();
	nvidia_bridge_cdev_removed("nvidia1", 1);
	nvidia_bridge_cdev_removed("nvidia0", 7);
	CHECK(nev == 0, "an unknown device (gone, or the minor differs) is not announced");
	/* unregister tells the provider to drop what it holds */
	reset();
	CHECK(nvidia_bridge_unregister(&bad) == EINVAL, "unregister of another table is EINVAL");
	CHECK(nvidia_bridge_unregister(&good) == 0, "unregister succeeds");
	CHECK(nev == 3 && ev_is(0, "del nvidiactl 255") && ev_is(1, "del nvidia0 0") && ev_is(2, "del nvidia2 2"), "unregister deletes every remaining device");
	reset();
	nvidia_bridge_cdev_added("nvidia3", 195, 3);
	CHECK(nev == 0, "no provider: a new device is not announced");
	/* a provider that refuses the 2nd device at replay still registers, and holds only what it accepted */
	reset();
	refuse_at = 2;
	CHECK(nvidia_bridge_register(&good) == 0, "a provider that refuses one device at replay still registers");
	CHECK(nev == 4 && accepted == 3, "it was offered every device and accepted the others");
	reset();
	CHECK(nvidia_bridge_unregister(&good) == 0, "unregister after a refused replay");
	CHECK(nev == 3 && !ev_has("del nvidia0 0"), "unregister deletes only the three accepted devices, not the refused nvidia0");
	reset();
	CHECK(nvidia_bridge_register(&good) == 0, "registering again offers the refused device again (it is accepted now)");
	CHECK(accepted == 4, "all four devices are provided after the second registration");
	CHECK(nvidia_bridge_unregister(&good) == 0, "and unregister");
	/* a live add the provider refuses: never deleted from it, on removal or on unregister */
	reset();
	CHECK(nvidia_bridge_register(&good) == 0, "register again");
	reset();
	refuse_at = adds_seen + 1;
	nvidia_bridge_cdev_added("nvidia9", 195, 9);
	CHECK(nev == 1 && ev_is(0, "add nvidia9 195 9") && accepted == 0, "the refused live add was offered");
	reset();
	nvidia_bridge_cdev_added("nvidia8", 195, 8);
	reset();
	CHECK(nvidia_bridge_unregister(&good) == 0, "unregister while the refused device is still listed");
	CHECK(!ev_has("nvidia9") && ev_has("del nvidia8 8"), "unregister does not delete the refused nvidia9, and deletes the accepted nvidia8");
	nvidia_bridge_cdev_removed("nvidia9", 9);
	CHECK(nvidia_bridge_register(&good) == 0, "register once more");
	reset();
	nvidia_bridge_cdev_added("nvidia7", 195, 7);
	refuse_at = adds_seen + 1;
	nvidia_bridge_cdev_added("nvidia6", 195, 6);
	reset();
	nvidia_bridge_cdev_removed("nvidia6", 6);
	CHECK(nev == 0, "a device whose add was refused is not deleted from the provider on removal");
	CHECK(nvidia_bridge_unregister(&good) == 0, "and unregister");
	nvidia_bridge_cdev_removed("nvidia8", 8);
	nvidia_bridge_cdev_removed("nvidia7", 7);
	/* clean up the core's list */
	nvidia_bridge_cdev_removed("nvidiactl", 255);
	nvidia_bridge_cdev_removed("nvidia0", 0);
	nvidia_bridge_cdev_removed("nvidia1", 1);
	nvidia_bridge_cdev_removed("nvidia2", 2);
	nvidia_bridge_cdev_removed("nvidia3", 3);
	CHECK(stub_live_allocs == 0, "no allocation is left once every device is removed");
	CHECK(nvb_lock.held == 0, "the lock is balanced");
	return (fails != 0);
}

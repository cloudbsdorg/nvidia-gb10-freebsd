/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * mem_probe.c - the live check of the libnvrm memory calls (Track #2419) for a
 * test boot: on every GPU the library enumerates (no index is assumed; each
 * line names the GPU by its PCI address), open a client with CPU mapping,
 * reserve VA, allocate video and system memory, map them for the GPU and the
 * CPU, write a pattern through the CPU mapping and read it back, export the
 * video memory and import it into a second client, read the pattern through
 * the import, then free everything and check that nothing is left and no
 * release was refused.  It needs the driver and nothing else (no Linux
 * layer); with NVRM_BACKEND=fake it runs on the software GPU (the suite does
 * that).
 *
 * Output: one line per step, "PASS gpu N (dddd:bb:ss.f) STEP: detail" or
 * "FAIL ...", for results.txt of the boot kit.  Exit status: the number of
 * FAIL lines (capped at 100); 101 when nothing could be enumerated.
 */
#include <sys/types.h>

#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <nvrm/nvrm.h>

#define MiB	(1024ULL * 1024)

static int fails;
static char gpu_name[64];

static int
step(int ok, const char *what, const char *fmt, ...)
{
	va_list ap;

	printf("%s %s %s: ", ok ? "PASS" : "FAIL", gpu_name, what);
	va_start(ap, fmt);
	vprintf(fmt, ap);
	va_end(ap);
	printf("\n");
	fails += !ok;
	return (ok);
}

static const char *
attr_name(uint32_t a)
{
	switch (a) {
	case NVRM_ATTR_CACHED:
		return ("cached");
	case NVRM_ATTR_WC:
		return ("write-combined");
	case NVRM_ATTR_DEVICE:
		return ("device");
	default:
		return ("unknown");
	}
}

static void
fill(uint8_t *b, size_t n, unsigned seed)
{
	size_t i;

	for (i = 0; i < n; i++)
		b[i] = (uint8_t)(i * 131 + seed);
}

/* Write a pattern through the CPU mapping and read it back. */
static int
pattern(nvrm_client *cl, nvrm_mem *m, const char *what, unsigned seed)
{
	static uint8_t want[64 * 1024], got[64 * 1024];
	int rc;

	fill(want, sizeof(want), seed);
	memset(got, 0, sizeof(got));
	rc = nvrm_mem_write(m, 4096, want, sizeof(want));
	if (rc == NVRM_OK)
		rc = nvrm_mem_read(m, 4096, got, sizeof(got));
	return (step(rc == NVRM_OK && memcmp(want, got, sizeof(want)) == 0,
	    what, "%s", rc != NVRM_OK ? nvrm_client_errmsg(cl) :
	    memcmp(want, got, sizeof(want)) == 0 ? "64 KiB written and read "
	    "back equal" : "the bytes read back differ"));
}

/* #lizard forgives -- one scripted live sequence, each step depends on the last */
static void
probe(nvrm_device *dev)
{
	nvrm_open_opts o = { 0, NVRM_OPEN_ALLOW_MAP, 4, 4 };
	nvrm_va_params vp = { 0, 0, 64 * MiB, 2 * MiB, 0 };	/* any page fits */
	nvrm_mem_params vram = { 0, NVRM_MEM_VRAM, 0, 0, 2 * MiB, 0, 0 };
	nvrm_mem_params sys = { 0, NVRM_MEM_SYSMEM, 0, 0, 2 * MiB, 0, 0 };
	nvrm_gpu_map_params gp = { 0 };
	nvrm_vaspace_info vi = { 0 };
	nvrm_mem_info mi = { 0 };
	nvrm_client_stats st = { 0 };
	nvrm_client *cl = NULL, *cl2 = NULL;
	nvrm_mem *v = NULL, *s = NULL, *im = NULL;
	char err[200];
	uint64_t va = 0;
	void *p;
	int rc, fd = -1;

	rc = nvrm_client_open(dev, &o, &cl, err, sizeof(err));
	if (!step(rc == NVRM_OK, "client_open", "%s", rc == NVRM_OK ?
	    "own RM session, VA space and spares (ALLOW_MAP)" : err))
		return;
	rc = nvrm_vaspace_info_get(cl, &vi);
	if (rc != NVRM_OK)
		step(0, "vaspace", "%s", nvrm_client_errmsg(cl));
	else
		step(vi.end > vi.base, "vaspace", "base 0x%jx end 0x%jx",
		    (uintmax_t)vi.base, (uintmax_t)vi.end);
	rc = nvrm_va_reserve(cl, &vp, &va);
	if (!step(rc == NVRM_OK, "va_reserve", "%s", rc == NVRM_OK ? "64 MiB" :
	    nvrm_client_errmsg(cl)))
		goto out;
	rc = nvrm_mem_alloc(cl, &vram, &v);
	if (step(rc == NVRM_OK, "alloc_vram", "%s", rc == NVRM_OK ? "2 MiB" :
	    nvrm_client_errmsg(cl))) {
		rc = nvrm_mem_info_get(v, &mi);
		if (rc != NVRM_OK)
			step(0, "vram_info", "%s", nvrm_client_errmsg(cl));
		else
			step(1, "vram_info", "place %s, page %ju, cpu attribute "
			    "%s", mi.place == NVRM_PLACE_VIDMEM ? "video" :
			    "system", (uintmax_t)mi.page_size,
			    attr_name(mi.cpu_attr));
	}
	rc = nvrm_mem_alloc(cl, &sys, &s);
	step(rc == NVRM_OK, "alloc_sysmem", "%s", rc == NVRM_OK ? "2 MiB" :
	    nvrm_client_errmsg(cl));
	if (v != NULL) {
		gp.va = va;
		rc = nvrm_mem_map_gpu(v, &gp);
		step(rc == NVRM_OK, "map_gpu_vram", "%s", rc == NVRM_OK ?
		    "at the reservation start" : nvrm_client_errmsg(cl));
		rc = nvrm_mem_map_cpu(v, NVRM_CPU_READ | NVRM_CPU_WRITE, &p);
		if (step(rc == NVRM_OK, "map_cpu_vram", "%s", rc == NVRM_OK ?
		    "read-write" : nvrm_client_errmsg(cl)))
			pattern(cl, v, "rw_vram", 7);
	}
	if (s != NULL) {
		gp.va = va + 32 * MiB;
		rc = nvrm_mem_map_gpu(s, &gp);
		step(rc == NVRM_OK, "map_gpu_sysmem", "%s", rc == NVRM_OK ?
		    "32 MiB into the reservation" : nvrm_client_errmsg(cl));
		rc = nvrm_mem_map_cpu(s, NVRM_CPU_READ | NVRM_CPU_WRITE, &p);
		if (step(rc == NVRM_OK, "map_cpu_sysmem", "%s", rc == NVRM_OK ?
		    "read-write" : nvrm_client_errmsg(cl)))
			pattern(cl, s, "rw_sysmem", 11);
	}
	/* sharing: the pattern written into the video memory is what an import
	 * by a second client reads */
	if (v != NULL) {
		rc = nvrm_mem_export_fd(v, &fd);
		step(rc == NVRM_OK, "export", "%s", rc == NVRM_OK ? "descriptor" :
		    nvrm_client_errmsg(cl));
		rc = rc == NVRM_OK ? nvrm_client_open(dev, &o, &cl2, err,
		    sizeof(err)) : rc;
		if (fd >= 0 && step(rc == NVRM_OK, "second_client", "%s",
		    rc == NVRM_OK ? "opened" : err)) {
			rc = nvrm_mem_import_fd(cl2, fd, &im);
			step(rc == NVRM_OK, "import", "%s", rc == NVRM_OK ?
			    "the exported video memory" : nvrm_client_errmsg(cl2));
		}
		if (im != NULL && nvrm_mem_map_cpu(im, NVRM_CPU_READ, &p) ==
		    NVRM_OK) {
			static uint8_t want[4096], got[4096];

			fill(want, sizeof(want), 7);
			rc = nvrm_mem_read(im, 4096, got, sizeof(got));
			step(rc == NVRM_OK && memcmp(want, got, sizeof(got)) == 0,
			    "read_import", "%s", rc != NVRM_OK ?
			    nvrm_client_errmsg(cl2) : memcmp(want, got,
			    sizeof(got)) == 0 ? "the import reads the pattern" :
			    "the import reads other bytes");
		} else if (im != NULL)
			step(0, "read_import", "%s", nvrm_client_errmsg(cl2));
	}
out:
	if (im != NULL)
		nvrm_mem_free(im);
	if (fd >= 0)
		close(fd);
	if (v != NULL)
		nvrm_mem_free(v);
	if (s != NULL)
		nvrm_mem_free(s);
	if (va != 0) {
		rc = nvrm_va_release(cl, va);
		step(rc == NVRM_OK, "va_release", "%s", rc == NVRM_OK ?
		    "released" : nvrm_client_errmsg(cl));
	}
	rc = nvrm_client_stats_get(cl, &st);
	step(rc == NVRM_OK && st.live_mem == 0 && st.live_bytes == 0 &&
	    st.live_reservations == 0 && st.live_gpu_maps == 0 &&
	    st.live_cpu_maps == 0, "nothing_left",
	    "live objects %ju, reservations %ju, GPU maps %ju, CPU maps %ju",
	    (uintmax_t)st.live_mem, (uintmax_t)st.live_reservations,
	    (uintmax_t)st.live_gpu_maps, (uintmax_t)st.live_cpu_maps);
	step(rc == NVRM_OK && st.failed_releases == 0, "no_refused_release",
	    "failed_releases %ju", (uintmax_t)st.failed_releases);
	nvrm_client_close(cl2);
	nvrm_client_close(cl);
}

int
main(void)
{
	nvrm_ctx *ctx;
	const nvrm_device_info *i;
	char err[300];
	unsigned n, k;

	setvbuf(stdout, NULL, _IOLBF, 0);
	if (nvrm_enumerate(&ctx, NULL, err, sizeof(err)) != NVRM_OK) {
		printf("FAIL enumerate: %s\n", err);
		return (101);
	}
	n = nvrm_device_count(ctx);
	printf("INFO backend %s, %u GPU(s)\n", nvrm_backend_name(ctx), n);
	if (n == 0) {
		printf("FAIL enumerate: no GPU\n");
		nvrm_close(ctx);
		return (101);
	}
	for (k = 0; k < n; k++) {
		i = nvrm_device_info_get(nvrm_device_get(ctx, k));
		snprintf(gpu_name, sizeof(gpu_name),
		    "gpu %u (%04jx:%02jx:%02jx.%jx %04jx:%04jx)", k,
		    (uintmax_t)i->pci_domain.value, (uintmax_t)i->pci_bus.value,
		    (uintmax_t)i->pci_slot.value,
		    (uintmax_t)i->pci_function.value,
		    (uintmax_t)i->pci_vendor.value, (uintmax_t)i->pci_device.value);
		probe(nvrm_device_get(ctx, k));
	}
	nvrm_close(ctx);
	return (fails > 100 ? 100 : fails);
}

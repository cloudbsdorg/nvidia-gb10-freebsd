/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-3-Clause
 *
 * cuinit.c - cuInit, version and device count through libcuda.so.1.
 */
/* cuinit.c - load libcuda.so.1 and call cuInit(0), cuDriverGetVersion and
 * cuDeviceGetCount; print every result. Linux aarch64, run under the
 * Linuxulator. */
#include <dlfcn.h>
#include <stdio.h>
int main(void) {
	void *h = dlopen("libcuda.so.1", RTLD_NOW);
	if (h == NULL) { printf("dlopen libcuda.so.1: %s\n", dlerror()); return 1; }
	int (*cuInit)(unsigned) = dlsym(h, "cuInit");
	int (*cuDriverGetVersion)(int *) = dlsym(h, "cuDriverGetVersion");
	int (*cuDeviceGetCount)(int *) = dlsym(h, "cuDeviceGetCount");
	int (*cuGetErrorString)(int, const char **) = dlsym(h, "cuGetErrorString");
	int ver = 0, n = -1; const char *s = "?";
	int rc = cuDriverGetVersion(&ver);
	printf("cuDriverGetVersion rc=%d version=%d\n", rc, ver);
	rc = cuInit(0);
	cuGetErrorString(rc, &s);
	printf("cuInit(0) rc=%d (%s)\n", rc, s ? s : "?");
	if (rc == 0) { rc = cuDeviceGetCount(&n); printf("cuDeviceGetCount rc=%d n=%d\n", rc, n); }
	return rc != 0;
}

/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * rm_mock_test.c - the libnvrm rm backend against the GPU mock: the seam
 * stands in front of the backend, so the backend runs its real path (open,
 * the version check, the card list, the attach, the allocations, the
 * controls, the free) against a model file instead of a driver.
 *
 * The answers are the model's: the identity of the card, its architecture,
 * its VRAM, its SM count, its class list and its capabilities are the values
 * the model file carries, so a test can check the backend against a known
 * answer instead of against a driver that may not be there.
 *
 * usage: rm_mock_test MODEL EXPECT
 *   MODEL   the path of the model file
 *   EXPECT  "cards:N" (N cards), "nocards" (the RM reports no GPU) or
 *           "alloc-refused" (the enumeration fails on the allocation)
 */
#include <sys/param.h>
#include <sys/ioctl.h>

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <nvrm/nvrm.h>

#include "nvrm_rm_sys.h"

#include <nv-ioctl.h>
#include <nv_escape.h>

#include "gpu_mock.h"
#include "gpu_rm.h"

/* The attach ioctl: the number of GPUs is the size of its argument. */
#define IOC_ATTACH_GPUS		_IOWR(NV_IOCTL_MAGIC, NV_ESC_ATTACH_GPUS_TO_FD, \
				    uint32_t)
#define IOC_ATTACH_GPUS_MANY	_IOWR(NV_IOCTL_MAGIC, NV_ESC_ATTACH_GPUS_TO_FD, \
				    uint32_t[1024])

static int failures;

#define CHECK(cond, ...)						\
	do {								\
		if (!(cond)) {						\
			failures++;					\
			printf("FAIL %s:%d: ", __FILE__, __LINE__);	\
			printf(__VA_ARGS__);				\
			printf("\n");					\
		}							\
	} while (0)

/* The model and the engine of the test. */
static struct gpu_model model;
static struct gpu_rm *rm;

/* The seam: the system calls the rm backend makes, answered by the model. */
static int
seam_open(const char *path, int flags)
{
	int fd;

	(void)path;
	(void)flags;
	/*
	 * A real descriptor: the backend limits it for capability mode, and
	 * a descriptor that does not exist cannot be limited.
	 */
	fd = open("/dev/null", O_RDWR);
	if (fd < 0)
		return (-1);
	return (fd);
}

static int
seam_close(int fd)
{
	return (close(fd));
}

static int
seam_ioctl(int fd, unsigned long cmd, void *arg)
{
	(void)fd;
	return (gpu_rm_ioctl(rm, cmd, arg));
}

static int
seam_sysctlbyname(const char *name, void *old, size_t *oldlen)
{
	char value[4096];
	size_t len;

	if (gpu_seam_sysctl(&model, name, value, sizeof(value)) != 0) {
		errno = ENOENT;
		return (-1);
	}
	len = strlen(value) + 1;
	if (old == NULL) {
		if (oldlen != NULL)
			*oldlen = len;
		return (0);
	}
	if (oldlen == NULL || *oldlen < len) {
		errno = ENOMEM;
		return (-1);
	}
	memcpy(old, value, len);
	*oldlen = len;
	return (0);
}

static int
seam_access(const char *path)
{
	(void)path;
	return (0);
}

static const nvrm_rm_sys seam_sys = {
	seam_open, seam_close, seam_ioctl, seam_sysctlbyname, seam_access
};

/* The value of a string member of the device info, or NULL. */
static const char *
info_str(const nvrm_device_info *i, const char *name)
{
	unsigned n = nvrm_info_nfields();
	unsigned f;

	for (f = 0; f < n; f++) {
		const nvrm_field *field = nvrm_info_field(f);

		if (strcmp(field->name, name) != 0)
			continue;
		if (field->kind != NVRM_K_STR)
			return (NULL);
		return ((const char *)((const char *)i + field->offset));
	}
	return (NULL);
}

/* The value of a number member of the device info. */
static int
info_u64(const nvrm_device_info *i, const char *name, uint64_t *out)
{
	unsigned n = nvrm_info_nfields();
	unsigned f;

	for (f = 0; f < n; f++) {
		const nvrm_field *field = nvrm_info_field(f);

		if (strcmp(field->name, name) != 0)
			continue;
		if (field->kind != NVRM_K_U64)
			return (-1);
		*out = *(const uint64_t *)((const char *)i + field->offset);
		return (0);
	}
	return (-1);
}

/*
 * The attach ioctl: the size of its argument is the number of GPUs.  A
 * client that asks for more GPUs than the RM can hold is refused, and the
 * list of the attached GPUs is never written past its end.  The engine
 * answers this in the caller's own process, so the check runs everywhere:
 * with no device, with no cuse and with no root.
 */
static void
check_attach_bound(void)
{
	uint32_t ids[1024];
	uint32_t one = 1;
	int rc;

	memset(ids, 0, sizeof(ids));
	errno = 0;
	rc = gpu_rm_ioctl(rm, IOC_ATTACH_GPUS_MANY, ids);
	CHECK(rc != 0, "the attach of more GPUs than the RM can hold must be "
	    "refused");
	CHECK(errno == EINVAL, "the attach of too many GPUs was refused with "
	    "%s, the RM must say EINVAL", strerror(errno));
	/* The engine is whole: one GPU is attached and answered. */
	errno = 0;
	rc = gpu_rm_ioctl(rm, IOC_ATTACH_GPUS, &one);
	CHECK(rc == 0, "the attach of one GPU must be answered: %s",
	    strerror(errno));
}

/*
 * The identity of the card: every value comes from the model.
 */
static void
check_identity(const nvrm_device_info *info)
{
	const struct gpu_card *cards[GPU_RM_MAX_CARDS];
	unsigned n = gpu_model_nvidia_cards(&model, cards, GPU_RM_MAX_CARDS);
	const struct gpu_card *c;
	uint64_t v;

	CHECK(n > 0, "the model has no NVIDIA card");
	if (n == 0)
		return;
	c = cards[0];
	CHECK(strcmp(info_str(info, "uuid"), c->uuid) == 0,
	    "the uuid is \"%s\", the model says \"%s\"",
	    info_str(info, "uuid"), c->uuid);
	if (info_u64(info, "pci_bus", &v) == 0)
		CHECK(v == c->pci_bus, "the pci bus is %llu, the model says %u",
		    (unsigned long long)v, c->pci_bus);
	if (info_u64(info, "pci_slot", &v) == 0)
		CHECK(v == c->pci_slot, "the pci slot is %llu, the model says %u",
		    (unsigned long long)v, c->pci_slot);
	if (info_u64(info, "vram_size", &v) == 0)
		CHECK(v == c->vram_bytes, "the vram size is %llu, the model says "
		    "%llu", (unsigned long long)v,
		    (unsigned long long)c->vram_bytes);
	if (info_u64(info, "bar1_size", &v) == 0)
		CHECK(v == c->bar1_bytes, "the bar1 size is %llu, the model says "
		    "%llu", (unsigned long long)v,
		    (unsigned long long)c->bar1_bytes);
}

/*
 * The capabilities of the card: the architecture, the SM version and the
 * class list are the ones of the model.
 */
static void
check_capabilities(const nvrm_device_info *info)
{
	const struct gpu_card *cards[GPU_RM_MAX_CARDS];
	unsigned n = gpu_model_nvidia_cards(&model, cards, GPU_RM_MAX_CARDS);
	const struct gpu_card *c;
	uint64_t v;

	if (n == 0)
		return;
	c = cards[0];
	if (info_u64(info, "architecture", &v) == 0)
		CHECK(v == c->base->architecture, "the architecture is %llu, the "
		    "model says %u", (unsigned long long)v,
		    c->base->architecture);
	if (info_u64(info, "implementation", &v) == 0)
		CHECK(v == c->base->implementation, "the implementation is "
		    "%llu, the model says %u", (unsigned long long)v,
		    c->base->implementation);
	if (info_u64(info, "rm_sm_version", &v) == 0)
		CHECK(v == (((uint64_t)c->base->sm_version.major << 8) |
		    c->base->sm_version.minor), "the sm version is 0x%llx, the "
		    "model says 0x%llx", (unsigned long long)v,
		    (unsigned long long)(((uint64_t)c->base->sm_version.major
		    << 8) | c->base->sm_version.minor));
	/* The class list is the model's: the RM answers the class list
	 * control from the base of the card. */
	CHECK(info->classes.count == c->base->nclasses,
	    "the class list holds %u classes, the model says %u",
	    info->classes.count, c->base->nclasses);
	if (info->classes.count == c->base->nclasses &&
	    c->base->nclasses > 0)
		CHECK(info->classes.value[0] == c->base->classes[0],
		    "the first class is 0x%x, the model says 0x%x",
		    info->classes.value[0], c->base->classes[0]);
}

/*
 * The version of the driver comes from the OS layer, through the seam: the
 * answer is the model's, and it says it is a mock.
 */
static void
check_version(nvrm_ctx *ctx)
{
	const nvrm_version *dv;

	CHECK(nvrm_driver_version(ctx) != NULL, "no driver version");
	dv = nvrm_driver_version(ctx);
	if (dv == NULL)
		return;
	CHECK(dv->available, "the driver version is not available");
	CHECK(strcmp(dv->string, model.driver_version.string) == 0,
	    "the driver version is \"%s\", the model says \"%s\"",
	    dv->string, model.driver_version.string);
}

/* The cards of the model: how many there are, and what they are. */
static void
check_cards(nvrm_ctx *ctx, const char *expect)
{
	const nvrm_device_info *info;
	unsigned want;

	/* The expected card count: "cards:N". */
	want = (unsigned)strtoul(expect + 6, NULL, 10);
	CHECK(nvrm_device_count(ctx) == want,
	    "the device count is %u, the model says %u",
	    nvrm_device_count(ctx), want);
	/* The engine refuses what the RM refuses: a client that asks for
	 * more GPUs than the RM can attach. */
	check_attach_bound();
	if (nvrm_device_count(ctx) == 0)
		return;
	info = nvrm_device_info_get(nvrm_device_get(ctx, 0));
	CHECK(info != NULL, "no device info");
	/* The identity of the card comes from the model. */
	check_identity(info);
	check_capabilities(info);
}

/* The end of the test: the engine is let go, the status is the failures. */
static int
finish(void)
{
	nvrm_rm_set_sys(NULL);
	gpu_rm_free(rm);
	gpu_model_free(&model);
	return (failures == 0 ? 0 : 1);
}

/* The run of one expectation: the enumeration and the checks of it. */
static void
run_case(const char *expect, const char *path, char *err, size_t errlen)
{
	nvrm_enum_opts opts = { "rm" };
	nvrm_ctx *ctx = NULL;
	int rc;

	rc = nvrm_enumerate(&ctx, &opts, err, errlen);
	if (strcmp(expect, "alloc-refused") == 0) {
		/* The RM refuses every allocation: the enumeration fails. */
		CHECK(rc != NVRM_OK, "the enumeration must fail when the RM "
		    "refuses the allocation");
		CHECK(ctx == NULL, "no context when the enumeration fails");
		if (rc == NVRM_OK)
			printf("  the enumeration succeeded: %s\n", err);
		return;
	}
	CHECK(rc == NVRM_OK, "the enumeration failed: %s", err);
	if (rc != NVRM_OK)
		return;
	if (strcmp(expect, "nocards") == 0) {
		CHECK(nvrm_device_count(ctx) == 0, "the RM must report no GPU");
		nvrm_close(ctx);
		return;
	}
	check_cards(ctx, expect);
	check_version(ctx);
	nvrm_close(ctx);
	if (failures == 0)
		printf("ok rm_mock_test: %s\n", path);
}

int
main(int argc, char **argv)
{
	char err[512];

	if (argc != 3) {
		fprintf(stderr, "usage: rm_mock_test MODEL EXPECT\n");
		return (2);
	}
	if (gpu_model_load(argv[1], &model, err, sizeof(err)) != 0) {
		fprintf(stderr, "rm_mock_test: %s\n", err);
		return (2);
	}
	rm = gpu_rm_new(&model);
	if (rm == NULL) {
		fprintf(stderr, "rm_mock_test: no memory for the engine\n");
		return (2);
	}
	nvrm_rm_set_sys(&seam_sys);
	run_case(argv[2], argv[1], err, sizeof(err));
	return (finish());
}

/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * core_test.c - tests of the libnvrm core and the fake backend: registry,
 * enumeration and its failure paths, the layered device model (identity,
 * gpu class, family, board decorators), the JSON emitter and schema
 * generator, names, the Capsicum helper.  Built with the library sources and
 * coverage; the gate demands 100% line and branch coverage of the core and
 * the fake backend.  Every group has a control: a case that must fail, or an
 * expected-unavailable value, so a test that cannot fail is visible.
 */
#include <sys/types.h>
#include <sys/resource.h>
#include <sys/wait.h>

#include <signal.h>

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "nvrm_internal.h"
#include "nvrm_fake.h"
#include "nvrm_rm_sys.h"
#include "t.h"
#include "t_version.h"

#include "fault_calloc.h"

static void
fail_calloc_at(int n)
{
	calloc_calls = 0;
	calloc_fail_at = n;
}

/* ---- helpers ----------------------------------------------------------- */

static int rm_access_result = -1;

static int
stub_access(const char *p)
{
	(void)p;
	return (rm_access_result);
}

static const nvrm_rm_sys stub_sys = { NULL, NULL, NULL, NULL, stub_access };

static void
reset_env(void)
{
	unsetenv("NVRM_BACKEND");
	unsetenv("NVRM_FAKE_PROFILE");
	unsetenv("NVRM_FAKE_FAIL");
	nvrm_fake_inject_clear();
	fail_calloc_at(0);
	nvrm_issetugid_hook = NULL;
}

static nvrm_ctx *
enum_profile(const char *profile, int *rc, char *err, size_t errlen)
{
	nvrm_enum_opts o = { "fake" };
	nvrm_ctx *ctx;

	setenv("NVRM_FAKE_PROFILE", profile, 1);
	*rc = nvrm_enumerate(&ctx, &o, err, errlen);
	return (ctx);
}

static const nvrm_device_info *
info_of(nvrm_ctx *ctx, unsigned i)
{
	return (nvrm_device_info_get(nvrm_device_get(ctx, i)));
}

static nvrm_ctx *
must_enum(const char *profile)
{
	char err[200];
	int rc;
	nvrm_ctx *ctx = enum_profile(profile, &rc, err, sizeof(err));

	CHECK_EQ(rc, NVRM_OK);
	if (ctx == NULL) {
		printf("fatal: enumerate(%s): %s\n", profile, err);
		exit(1);
	}
	return (ctx);
}

/* ---- registry ---------------------------------------------------------- */

static int probe_yes(void) { return (1); }
static int probe_no(void) { return (0); }

static void
test_registry(void)
{
	nvrm_backend_ops a = nvrm_backend_fake_ops, b = nvrm_backend_fake_ops;
	nvrm_backend_ops c = nvrm_backend_fake_ops;
	unsigned i;

	nvrm_registry_reset();
	CHECK(nvrm_backend_select(NULL) == NULL);	/* empty: nothing */
	CHECK(nvrm_backend_select("fake") == NULL);

	a.name = "a"; a.probe = probe_yes; a.score = 5;
	b.name = "b"; b.probe = probe_yes; b.score = 9;
	c.name = "c"; c.probe = probe_no; c.score = 99;
	CHECK_EQ(nvrm_backend_register(&a), NVRM_OK);
	CHECK_EQ(nvrm_backend_register(&b), NVRM_OK);
	CHECK_EQ(nvrm_backend_register(&c), NVRM_OK);
	/* the best usable one wins; an unusable one never does */
	CHECK(nvrm_backend_select(NULL) == &b);
	CHECK(nvrm_backend_select("a") == &a);
	CHECK(nvrm_backend_select("c") == &c);	/* by name, no probe */
	CHECK(nvrm_backend_select("nope") == NULL);

	/* a later one with a lower score does not displace the best */
	nvrm_registry_reset();
	nvrm_backend_register(&b);
	nvrm_backend_register(&a);
	CHECK(nvrm_backend_select(NULL) == &b);

	/* the registry is bounded */
	nvrm_registry_reset();
	for (i = 0; i < 8; i++)
		CHECK_EQ(nvrm_backend_register(&a), NVRM_OK);
	CHECK_EQ(nvrm_backend_register(&a), NVRM_E_INVAL);

	/* builtins: rm and fake register themselves; rm is the default when
	 * its control device exists, never when it does not. */
	nvrm_registry_reset();
	nvrm_registry_builtin();
	CHECK(nvrm_backend_select("rm") == &nvrm_backend_rm_ops);
	CHECK(nvrm_backend_select("fake") == &nvrm_backend_fake_ops);
	nvrm_rm_set_sys(&stub_sys);
	rm_access_result = -1;
	CHECK(nvrm_backend_select(NULL) == NULL);	/* the fake is never auto */
	rm_access_result = 0;
	CHECK(nvrm_backend_select(NULL) == &nvrm_backend_rm_ops);
	nvrm_rm_set_sys(NULL);
	CHECK(nvrm_backend_fake_ops.probe() == 0);
	nvrm_registry_reset();
	nvrm_registry_builtin();
}

/* ---- enumeration and its failure paths --------------------------------- */

static void
test_two_gpus(void)
{
	nvrm_ctx *ctx;

	reset_env();
	/* two GPUs: ids, order, bounds */
	ctx = must_enum("discrete,unified");
	CHECK_EQ(nvrm_device_count(ctx), 2);
	CHECK(nvrm_device_get(ctx, 2) == NULL);
	CHECK(nvrm_device_get(ctx, 0) != nvrm_device_get(ctx, 1));
	CHECK(info_of(ctx, 0)->rm_gpu_id.value !=
	    info_of(ctx, 1)->rm_gpu_id.value);
	nvrm_close(ctx);
}

static void
test_enumerate(void)
{
	nvrm_ctx *ctx;
	nvrm_enum_opts o = { NULL };
	char err[256];
	int rc;

	reset_env();
	nvrm_registry_reset();
	nvrm_registry_builtin();
	nvrm_rm_set_sys(&stub_sys);
	rm_access_result = -1;

	/* no backend: no rm device, no selection */
	ctx = (nvrm_ctx *)1;
	rc = nvrm_enumerate(&ctx, NULL, err, sizeof(err));
	CHECK_EQ(rc, NVRM_E_NOBACKEND);
	CHECK(ctx == NULL);
	CHECK(strstr(err, "kernel module is not loaded") != NULL);
	CHECK(strstr(err, "NVRM_BACKEND=fake") != NULL && strstr(err, "set-user-ID") != NULL);
	/* an unknown name is a different message */
	o.backend = "nope";
	rc = nvrm_enumerate(&ctx, &o, err, sizeof(err));
	CHECK_EQ(rc, NVRM_E_NOBACKEND);
	CHECK(strstr(err, "no such backend") != NULL);
	o.backend = NULL;
	/* a NULL error buffer, and a zero length, are allowed */
	CHECK_EQ(nvrm_enumerate(&ctx, &o, NULL, 0), NVRM_E_NOBACKEND);
	CHECK_EQ(nvrm_enumerate(&ctx, &o, err, 0), NVRM_E_NOBACKEND);

	/* the environment selects the backend; an empty value means none */
	setenv("NVRM_BACKEND", "fake", 1);
	rc = nvrm_enumerate(&ctx, NULL, err, sizeof(err));
	CHECK_EQ(rc, NVRM_OK);
	CHECK_STR(nvrm_backend_name(ctx), "fake");
	CHECK_EQ(nvrm_device_count(ctx), 1);
	nvrm_close(ctx);
	setenv("NVRM_BACKEND", "", 1);
	CHECK_EQ(nvrm_enumerate(&ctx, NULL, err, sizeof(err)),
	    NVRM_E_NOBACKEND);
	/* a set-id program ignores the environment (control: not set-id) */
	setenv("NVRM_BACKEND", "fake", 1);
	nvrm_issetugid_hook = probe_yes;
	CHECK_EQ(nvrm_enumerate(&ctx, NULL, err, sizeof(err)),
	    NVRM_E_NOBACKEND);
	nvrm_issetugid_hook = probe_no;
	CHECK_EQ(nvrm_enumerate(&ctx, NULL, err, sizeof(err)), NVRM_OK);
	nvrm_close(ctx);
	/* an explicit option still works for a set-id program */
	nvrm_issetugid_hook = probe_yes;
	o.backend = "fake";
	CHECK_EQ(nvrm_enumerate(&ctx, &o, err, sizeof(err)), NVRM_OK);
	nvrm_close(ctx);
	nvrm_close(NULL);
	reset_env();

	/* injected failures at every step, each leaves no context behind */
	o.backend = "fake";
	setenv("NVRM_FAKE_FAIL", "open", 1);
	CHECK_EQ(nvrm_enumerate(&ctx, &o, err, sizeof(err)), NVRM_E_OPEN);
	CHECK(ctx == NULL);
	setenv("NVRM_FAKE_FAIL", "version", 1);
	CHECK_EQ(nvrm_enumerate(&ctx, &o, err, sizeof(err)), NVRM_E_VERSION);
	CHECK(strstr(err, NVRM_RM_VERSION) != NULL);
	setenv("NVRM_FAKE_FAIL", "list", 1);
	CHECK_EQ(nvrm_enumerate(&ctx, &o, err, sizeof(err)), NVRM_E_IO);
	/* zero GPUs is a result, not an error: OK, an empty context */
	setenv("NVRM_FAKE_FAIL", "nogpu", 1);
	CHECK_EQ(nvrm_enumerate(&ctx, &o, err, sizeof(err)), NVRM_OK);
	CHECK(ctx != NULL);
	CHECK_EQ(nvrm_device_count(ctx), 0);
	CHECK(nvrm_device_get(ctx, 0) == NULL);
	CHECK_STR(nvrm_backend_name(ctx), "fake");
	nvrm_close(ctx);
	ctx = NULL;
	setenv("NVRM_FAKE_FAIL", "gpu_open", 1);
	CHECK_EQ(nvrm_enumerate(&ctx, &o, err, sizeof(err)), NVRM_E_IO);
	setenv("NVRM_FAKE_FAIL", "limit", 1);
	CHECK_EQ(nvrm_enumerate(&ctx, &o, err, sizeof(err)), NVRM_E_CAPSICUM);
	CHECK(strstr(err, "capability mode") != NULL);
	unsetenv("NVRM_FAKE_FAIL");

	/* out of memory at each allocation: context, backend, GPU 0, GPU 1
	 * (the second GPU's failure frees the first) */
	setenv("NVRM_FAKE_PROFILE", "discrete,unified", 1);
	fail_calloc_at(1);
	CHECK_EQ(nvrm_enumerate(&ctx, &o, err, sizeof(err)), NVRM_E_NOMEM);
	fail_calloc_at(2);
	CHECK_EQ(nvrm_enumerate(&ctx, &o, err, sizeof(err)), NVRM_E_NOMEM);
	fail_calloc_at(3);
	CHECK_EQ(nvrm_enumerate(&ctx, &o, err, sizeof(err)), NVRM_E_NOMEM);
	fail_calloc_at(4);
	CHECK_EQ(nvrm_enumerate(&ctx, &o, err, sizeof(err)), NVRM_E_NOMEM);
	CHECK(ctx == NULL);
	fail_calloc_at(5);			/* control: one past the last */
	CHECK_EQ(nvrm_enumerate(&ctx, &o, err, sizeof(err)), NVRM_OK);
	nvrm_close(ctx);

	test_two_gpus();
	nvrm_rm_set_sys(NULL);
}

/* ---- the device model -------------------------------------------------- */

/* Every source label is pinned: which layer supplied each value.  A new field
 * needs a name in one group, so its label is a decision, not a default. */
typedef struct source_group {
	int source;
	const char *const *names;
	size_t count;
} source_group;

#define SOURCE_COUNT(a)	(sizeof(a) / sizeof((a)[0]))
#define SOURCE_GROUP(s, n)	{ (s), (n), SOURCE_COUNT(n) }

static const char *const field_os[] = {
	"pci_domain", "pci_bus", "pci_slot", "pci_function",
	"pci_vendor", "pci_device",
};
static const char *const field_rm[] = {
	"pci_subsystem_vendor", "pci_subsystem_device", "pci_revision",
	"rm_gpu_id", "uuid", "architecture", "implementation",
	"sm_version_major", "sm_version_minor", "rm_sm_version",
	"gpc_count", "tpc_count", "classes", "vram_size", "bar1_size",
	"max_page_size", "numa_node", "vbios", "gsp_firmware",
};
static const char *const field_derived[] = {
	"chip_id", "compute_capability_major", "compute_capability_minor",
	"sm_count",
};
static const char *const field_family[] = {
	"cls_gpfifo", "cls_compute", "cls_eng3d", "cls_copy", "family",
	"page_sizes",
};
static const source_group field_sources[] = {
	SOURCE_GROUP(NVRM_S_OS, field_os),
	SOURCE_GROUP(NVRM_S_RM, field_rm),
	SOURCE_GROUP(NVRM_S_DERIVED, field_derived),
	SOURCE_GROUP(NVRM_S_FAMILY, field_family),
};
static const char *const cap_rm[] = {
	"dmabuf_export", "ats", "self_hosted", "display_enabled", "soc",
	"coherent_gpu_memory",
};
static const char *const cap_os[] = { "os_device_wc_active" };
static const source_group cap_sources[] = {
	SOURCE_GROUP(NVRM_S_RM, cap_rm),
	SOURCE_GROUP(NVRM_S_OS, cap_os),
};

static unsigned
check_source_label(const char *name, int source, const source_group *groups,
    size_t ngroups)
{
	unsigned hits = 0;
	size_t g, n;

	for (g = 0; g < ngroups; g++) {
		for (n = 0; n < groups[g].count; n++) {
			if (strcmp(groups[g].names[n], name) != 0)
				continue;
			hits++;
			if (groups[g].source != source)
				printf("  %s: source %s, want %s\n", name,
				    nvrm_source_name(source),
				    nvrm_source_name(groups[g].source));
			CHECK_EQ(source, groups[g].source);
		}
	}
	CHECK_EQ(hits, 1);	/* a value with no pinned label */
	return (hits);
}

static void
check_source_labels(const nvrm_device_info *i)
{
	unsigned f, c, matched = 0, rows = 0;

	for (f = 0; f < nvrm_nfields; f++) {
		const char *b = (const char *)i + nvrm_fields[f].offset;
		int src = nvrm_fields[f].kind == NVRM_K_U64 ?
		    ((const nvrm_u64 *)b)->source :
		    nvrm_fields[f].kind == NVRM_K_STR ?
		    ((const nvrm_str *)b)->source :
		    nvrm_fields[f].kind == NVRM_K_LIST ?
		    ((const nvrm_list *)b)->source :
		    ((const nvrm_version_field *)b)->source;

		matched += check_source_label(nvrm_fields[f].name, src,
		    field_sources, SOURCE_COUNT(field_sources));
	}
	CHECK_EQ(matched, nvrm_nfields);
	CHECK_EQ(SOURCE_COUNT(field_os) + SOURCE_COUNT(field_rm) +
	    SOURCE_COUNT(field_derived) + SOURCE_COUNT(field_family),
	    nvrm_nfields);
	/* Capability names, not positions, pin the labels of appended flags. */
	for (c = 0; c < NVRM_NCAPS; c++)
		rows += check_source_label(nvrm_cap_name(c), i->caps[c].source,
		    cap_sources, SOURCE_COUNT(cap_sources));
	CHECK_EQ(rows, NVRM_NCAPS);
	CHECK_EQ(SOURCE_COUNT(cap_rm) + SOURCE_COUNT(cap_os), NVRM_NCAPS);
}

static void
test_device_versions(void)
{
	static const uint32_t vbios[] = { 0x96, 0x06, 0x1e, 0x00, 0x4a };
	static const uint32_t vbios_unified[] = { 0x97, 0x06, 0x1e, 0x00, 0x4a };
	static const uint32_t gsp[] = { 580, 178, 4 };
	nvrm_ctx *ctx;
	const nvrm_device_info *info;
	char *buf = NULL;
	size_t len = 0;
	FILE *fp;

	reset_env();
	ctx = must_enum("discrete");
	info = info_of(ctx, 0);
	t_check_version_field(info, "vbios", "96.06.1e.00.4a", vbios, 5);
	t_check_version_field(info, "gsp_firmware", "580.178.04", gsp, 3);
	fp = open_memstream(&buf, &len);
	CHECK_EQ(nvrm_json_device(nvrm_device_get(ctx, 0), fp), 0);
	fflush(fp);
	CHECK(strstr(buf, "\"versions\":{\"vbios\":{\"available\":true,"
	    "\"string\":\"96.06.1e.00.4a\",\"major\":150,\"minor\":6,"
	    "\"patch\":30,\"parts\":[150,6,30,0,74],\"source\":\"rm\"},"
	    "\"gsp_firmware\":{\"available\":true,"
	    "\"string\":\"580.178.04\",\"major\":580,\"minor\":178,"
	    "\"patch\":4,\"parts\":[580,178,4],\"source\":\"rm\"}}") != NULL);
	fclose(fp);
	free(buf);
	nvrm_close(ctx);

	ctx = must_enum("unified");
	t_check_version_field(info_of(ctx, 0), "vbios", "97.06.1e.00.4a",
	    vbios_unified, 5);
	t_check_version_field(info_of(ctx, 0), "gsp_firmware", "580.178.04",
	    gsp, 3);
	nvrm_close(ctx);

	ctx = must_enum("sparse");
	info = info_of(ctx, 0);
	t_check_unavailable_version_field(info, "vbios", "",
	    "rm_control_failed");
	t_check_unavailable_version_field(info, "gsp_firmware", "",
	    "rm_not_supported");
	buf = NULL;
	len = 0;
	fp = open_memstream(&buf, &len);
	CHECK_EQ(nvrm_json_device(nvrm_device_get(ctx, 0), fp), 0);
	fflush(fp);
	CHECK(strstr(buf, "\"vbios\":{\"available\":false,\"string\":\"\","
	    "\"reason_id\":\"rm_control_failed\"") != NULL);
	CHECK(strstr(buf, "\"gsp_firmware\":{\"available\":false,"
	    "\"string\":\"\",\"reason_id\":\"rm_not_supported\"") != NULL);
	fclose(fp);
	free(buf);
	nvrm_close(ctx);
}

static void
test_model_discrete(void)
{
	nvrm_ctx *ctx;
	const nvrm_device_info *i;

	reset_env();
	ctx = must_enum("discrete");
	i = info_of(ctx, 0);
	t_check_common_device(i);
	CHECK_EQ(i->architecture.value, 0x1b0);
	CHECK_EQ(i->implementation.value, 6);
	CHECK(i->chip_id.source == NVRM_S_DERIVED);
	CHECK_EQ(i->sm_version_major.value, 10);
	CHECK_EQ(i->sm_version_minor.value, 4);
	CHECK_EQ(i->rm_sm_version.value, 0x0a04);
	CHECK_EQ(i->compute_capability_major.value, 12);
	CHECK_EQ(i->compute_capability_minor.value, 0);
	CHECK_EQ(i->bar1_size.value, 16ULL << 30);
	CHECK_STR(i->uuid.value, "GPU-00000000-0000-4000-8000-0000000000a1");
	CHECK(i->family.source == NVRM_S_FAMILY);
	CHECK_EQ(i->cls_gpfifo.value, 0xCA6F);
	CHECK_EQ(i->cls_compute.value, 0xCEC0);
	CHECK_EQ(i->cls_eng3d.value, 0xCE97);
	CHECK_EQ(i->cls_copy.value, 0xCAB5);
	CHECK_EQ(i->classes.count, 6);
	CHECK_EQ(i->page_sizes.count, 4);	/* 4K 64K 2M 512M under cap */
	CHECK_EQ(i->page_sizes.value[3], 512ULL << 20);
	/* no NUMA node: unavailable with the reason, not a made-up -1 */
	CHECK(!NVRM_HAVE(i->numa_node));
	CHECK_EQ(i->numa_node.reason, NVRM_R_NO_NUMA);
	/* capabilities: stable index, name, per-flag availability */
	CHECK(NVRM_HAVE(i->caps[0]) && i->caps[0].value == 1);
	CHECK(NVRM_HAVE(i->caps[3]) && i->caps[3].value == 1);
	CHECK(NVRM_HAVE(i->caps[1]) && i->caps[1].value == 0);
	CHECK(!NVRM_HAVE(i->caps[6]));
	CHECK_EQ(i->caps[6].reason, NVRM_R_OS_NOT_REPORTED);
	CHECK_EQ(i->ndecorators, 0);
	check_source_labels(i);
	/* a refresh gives the same answer */
	CHECK_EQ(nvrm_device_refresh(nvrm_device_get(ctx, 0)), NVRM_OK);
	CHECK_EQ(info_of(ctx, 0)->sm_count.value, 36);
	CHECK_STR(nvrm_rm_running_version(ctx)->value, NVRM_RM_VERSION);
	nvrm_close(ctx);
}

static void
test_model_unified(void)
{
	nvrm_ctx *ctx;
	const nvrm_device_info *i;

	reset_env();
	ctx = must_enum("unified");
	i = info_of(ctx, 0);
	CHECK_EQ(i->chip_id.value, 0x1bb);
	CHECK_EQ(i->sm_version_major.value, 12);
	CHECK_EQ(i->sm_version_minor.value, 1);
	CHECK_EQ(i->rm_sm_version.value, 0x0c01);
	CHECK_EQ(i->compute_capability_major.value, 12);
	CHECK_EQ(i->compute_capability_minor.value, 1);
	/* VRAM is available and zero on a unified-memory part */
	CHECK(NVRM_HAVE(i->vram_size));
	CHECK_EQ(i->vram_size.value, 0);
	CHECK_EQ(i->tpc_count.value, 17);
	CHECK_EQ(i->sm_count.value, 34);
	CHECK(NVRM_HAVE(i->numa_node));
	CHECK_EQ(i->numa_node.value, 0);
	CHECK_EQ(i->page_sizes.count, 3);	/* the 512M page is above max */
	CHECK_EQ(i->page_sizes.value[2], 2ULL << 20);
	CHECK(i->caps[4].value == 1 && i->caps[5].value == 1);
	CHECK(NVRM_HAVE(i->caps[6]) && i->caps[6].value == 1);
	CHECK(i->caps[6].source == NVRM_S_OS);
	nvrm_close(ctx);
}

static void
test_model_unknown_and_sparse(void)
{
	nvrm_ctx *ctx;
	const nvrm_device_info *i;
	unsigned c;

	reset_env();
	/* a GPU the table does not know: reported, family values unavailable */
	ctx = must_enum("unknown");
	i = info_of(ctx, 0);
	CHECK_EQ(i->architecture.value, 0xfff0);
	CHECK(!NVRM_HAVE(i->family));
	CHECK_EQ(i->family.reason, NVRM_R_FAMILY_UNKNOWN);
	CHECK(!NVRM_HAVE(i->cls_gpfifo) && !NVRM_HAVE(i->cls_compute));
	CHECK(!NVRM_HAVE(i->cls_eng3d) && !NVRM_HAVE(i->cls_copy));
	CHECK(!NVRM_HAVE(i->page_sizes));
	/* every value the family supplies says family_unknown (not another
	 * reason), and each one is checked by itself */
	CHECK_EQ(i->cls_gpfifo.reason, NVRM_R_FAMILY_UNKNOWN);
	CHECK_EQ(i->cls_compute.reason, NVRM_R_FAMILY_UNKNOWN);
	CHECK_EQ(i->cls_eng3d.reason, NVRM_R_FAMILY_UNKNOWN);
	CHECK_EQ(i->cls_copy.reason, NVRM_R_FAMILY_UNKNOWN);
	CHECK_EQ(i->page_sizes.reason, NVRM_R_FAMILY_UNKNOWN);
	CHECK_STR(nvrm_reason_id(i->cls_gpfifo.reason), "family_unknown");
	CHECK_STR(nvrm_reason_id(i->cls_copy.reason), "family_unknown");
	/* With no architecture/implementation row, raw RM bytes are not CUDA. */
	CHECK_EQ(i->sm_version_major.value, 13);
	CHECK_EQ(i->sm_version_minor.value, 2);
	CHECK_EQ(i->rm_sm_version.value, 0x0d02);
	CHECK(!NVRM_HAVE(i->compute_capability_major));
	CHECK_EQ(i->compute_capability_major.reason, NVRM_R_FAMILY_UNKNOWN);
	CHECK(!NVRM_HAVE(i->compute_capability_minor));
	CHECK_EQ(i->compute_capability_minor.reason, NVRM_R_FAMILY_UNKNOWN);
	CHECK(NVRM_HAVE(i->classes));
	nvrm_close(ctx);

	/* GB20C has no row either: the raw 0x0a04 cannot invent CC 12.0. */
	ctx = must_enum("untabled");
	i = info_of(ctx, 0);
	CHECK_EQ(i->architecture.value, 0x1b0);
	CHECK_EQ(i->implementation.value, 0x0c);
	CHECK_EQ(i->sm_version_major.value, 10);
	CHECK_EQ(i->sm_version_minor.value, 4);
	CHECK_EQ(i->rm_sm_version.value, 0x0a04);
	CHECK(!NVRM_HAVE(i->compute_capability_major));
	CHECK_EQ(i->compute_capability_major.reason, NVRM_R_FAMILY_UNKNOWN);
	CHECK(!NVRM_HAVE(i->compute_capability_minor));
	CHECK_EQ(i->compute_capability_minor.reason, NVRM_R_FAMILY_UNKNOWN);
	nvrm_close(ctx);

	/* With no table row the reason is family_unknown whatever the raw code
	 * is: the table does not read it (zero here). */
	reset_env();
	nvrm_fake_inject_value(NVRM_P_SM_VERSION, 0);
	ctx = must_enum("unknown");
	i = info_of(ctx, 0);
	CHECK(!NVRM_HAVE(i->sm_version_major));
	CHECK_EQ(i->sm_version_major.reason, NVRM_R_RM_UNSUPPORTED);
	CHECK(!NVRM_HAVE(i->sm_version_minor));
	CHECK(!NVRM_HAVE(i->rm_sm_version));
	CHECK_EQ(i->rm_sm_version.reason, NVRM_R_RM_UNSUPPORTED);
	CHECK(!NVRM_HAVE(i->compute_capability_major));
	CHECK_EQ(i->compute_capability_major.reason, NVRM_R_FAMILY_UNKNOWN);
	CHECK(!NVRM_HAVE(i->compute_capability_minor));
	CHECK_EQ(i->compute_capability_minor.reason, NVRM_R_FAMILY_UNKNOWN);
	nvrm_close(ctx);

	/* everything missing: every value says why, nothing is a fake zero */
	ctx = must_enum("sparse");
	i = info_of(ctx, 0);
	CHECK(!NVRM_HAVE(i->pci_vendor));
	CHECK_EQ(i->pci_vendor.reason, NVRM_R_OS_NOT_REPORTED);
	CHECK(!NVRM_HAVE(i->chip_id));
	CHECK_EQ(i->chip_id.reason, NVRM_R_INPUT_MISSING);
	CHECK(!NVRM_HAVE(i->gpc_count));
	CHECK(!NVRM_HAVE(i->tpc_count));
	CHECK_EQ(i->tpc_count.reason, NVRM_R_INPUT_MISSING);
	CHECK(!NVRM_HAVE(i->sm_count));
	CHECK(!NVRM_HAVE(i->classes));
	CHECK(!NVRM_HAVE(i->uuid));
	CHECK(!NVRM_HAVE(i->family));
	CHECK_EQ(i->family.reason, NVRM_R_INPUT_MISSING);
	CHECK(!NVRM_HAVE(i->compute_capability_major));
	CHECK_EQ(i->compute_capability_major.reason, NVRM_R_INPUT_MISSING);
	CHECK(!NVRM_HAVE(i->compute_capability_minor));
	CHECK_EQ(i->compute_capability_minor.reason, NVRM_R_INPUT_MISSING);
	CHECK_EQ(i->page_sizes.reason, NVRM_R_INPUT_MISSING);
	CHECK(!NVRM_HAVE(i->vram_size));
	for (c = 0; c < NVRM_NCAPS; c++) {
		CHECK(!NVRM_HAVE(i->caps[c]));
		CHECK_EQ(i->caps[c].value, 0);
	}
	nvrm_close(ctx);
}

/* The Ada row and the families that have no class of a kind. */
static void
test_model_ada(void)
{
	nvrm_ctx *ctx;
	const nvrm_device_info *i;
	static const uint32_t ada[] = { 0xc56f, 0xc9c0, 0xc997, 0xc7b5 };
	static const uint32_t ada_nocopy[] = { 0xc56f, 0xc9c0, 0xc997 };

	/* the Ada row: its copy class is the one of the generation before,
	 * so the family reports it available, from the table */
	reset_env();
	nvrm_fake_inject_classes(ada, 4);
	ctx = must_enum("discrete");
	i = info_of(ctx, 0);
	CHECK_STR(i->family.value, "ada");
	CHECK(NVRM_HAVE(i->cls_eng3d));
	CHECK(NVRM_HAVE(i->cls_copy));
	CHECK_EQ(i->cls_copy.value, 0xC7B5);
	CHECK(i->cls_copy.source == NVRM_S_FAMILY);
	nvrm_close(ctx);
	/* an Ada GPU whose class list lacks the copy class: absent, and not
	 * "the family has none" (that statement would be false) */
	reset_env();
	nvrm_fake_inject_classes(ada_nocopy, 3);
	ctx = must_enum("discrete");
	i = info_of(ctx, 0);
	CHECK_STR(i->family.value, "ada");
	CHECK(!NVRM_HAVE(i->cls_copy));
	CHECK_EQ(i->cls_copy.reason, NVRM_R_CLASS_ABSENT);
	nvrm_close(ctx);
	/* a table row with no class of a kind: the table says so */
	{
		static const nvrm_family row[] = {
			{ "row", 1, 2, 3, 0, { 0 } },
		};
		nvrm_device_info info;

		nvrm_info_init(&info);
		info.classes.reason = NVRM_R_NONE;
		info.classes.count = 3;
		info.classes.value[0] = 1;
		info.classes.value[1] = 2;
		info.classes.value[2] = 3;
		nvrm_apply_family(&info, row, 1);
		CHECK(!NVRM_HAVE(info.cls_copy));
		CHECK_EQ(info.cls_copy.reason, NVRM_R_FAMILY_NO_CLASS);
		CHECK(NVRM_HAVE(info.cls_eng3d));
	}
}

static const nvrm_device_info *
must_injected_discrete(nvrm_ctx **ctx, int prop, int reason)
{
	reset_env();
	nvrm_fake_inject(prop, reason);
	*ctx = must_enum("discrete");
	return (info_of(*ctx, 0));
}

static void
test_model_injections(void)
{
	nvrm_ctx *ctx;
	const nvrm_device_info *i;
	static const uint32_t no_eng3d[] = { 0xca6f, 0xcec0, 0xcab5 };

	/* GPC mask works but a TPC mask fails part way */
	reset_env();
	nvrm_fake_inject_tpc_fail(1);
	ctx = must_enum("discrete");
	i = info_of(ctx, 0);
	CHECK(NVRM_HAVE(i->gpc_count));
	CHECK(!NVRM_HAVE(i->tpc_count));
	CHECK_EQ(i->tpc_count.reason, NVRM_R_RM_FAILED);
	CHECK(!NVRM_HAVE(i->sm_count));
	CHECK_EQ(i->sm_count.reason, NVRM_R_INPUT_MISSING);
	nvrm_close(ctx);

	/* the chip id is the sum, not an or, of architecture and implementation */
	reset_env();
	nvrm_fake_inject_value(NVRM_P_ARCHITECTURE, 0x1b3);
	nvrm_fake_inject_value(NVRM_P_IMPLEMENTATION, 3);
	ctx = must_enum("discrete");
	CHECK_EQ(info_of(ctx, 0)->chip_id.value, 0x1b6);
	nvrm_close(ctx);
	/* SM version minor is the low byte only */
	reset_env();
	nvrm_fake_inject_value(NVRM_P_SM_VERSION, 0x0cc5);
	ctx = must_enum("discrete");
	CHECK_EQ(info_of(ctx, 0)->sm_version_minor.value, 0xc5);
	CHECK_EQ(info_of(ctx, 0)->sm_version_major.value, 12);
	/* The architecture table determines compute capability, not raw SM. */
	CHECK_EQ(info_of(ctx, 0)->compute_capability_major.value, 12);
	CHECK_EQ(info_of(ctx, 0)->compute_capability_minor.value, 0);
	nvrm_close(ctx);

	/* A table row needs no raw SM value; its architecture is authoritative. */
	i = must_injected_discrete(&ctx, NVRM_P_SM_VERSION,
	    NVRM_R_RM_UNSUPPORTED);
	CHECK(!NVRM_HAVE(i->rm_sm_version));
	CHECK_EQ(i->rm_sm_version.reason, NVRM_R_RM_UNSUPPORTED);
	CHECK(NVRM_HAVE(i->compute_capability_major));
	CHECK_EQ(i->compute_capability_major.value, 12);
	CHECK_EQ(i->compute_capability_minor.value, 0);
	nvrm_close(ctx);

	/* A raw SM value cannot replace a missing architecture table key. */
	i = must_injected_discrete(&ctx, NVRM_P_ARCHITECTURE, NVRM_R_RM_FAILED);
	CHECK(!NVRM_HAVE(i->architecture));
	CHECK(NVRM_HAVE(i->rm_sm_version));
	CHECK(!NVRM_HAVE(i->compute_capability_major));
	CHECK_EQ(i->compute_capability_major.reason, NVRM_R_INPUT_MISSING);
	CHECK(!NVRM_HAVE(i->compute_capability_minor));
	CHECK_EQ(i->compute_capability_minor.reason, NVRM_R_INPUT_MISSING);
	nvrm_close(ctx);

	/* implementation unknown: the chip id cannot be derived */
	i = must_injected_discrete(&ctx, NVRM_P_IMPLEMENTATION, NVRM_R_RM_FAILED);
	CHECK(NVRM_HAVE(i->architecture));
	CHECK(!NVRM_HAVE(i->chip_id));
	CHECK_EQ(i->chip_id.reason, NVRM_R_INPUT_MISSING);
	nvrm_close(ctx);

	/* SM per TPC fails: TPCs known, SMs not */
	i = must_injected_discrete(&ctx, NVRM_P_SM_PER_TPC, NVRM_R_RM_FAILED);
	CHECK(NVRM_HAVE(i->tpc_count));
	CHECK(!NVRM_HAVE(i->sm_count));
	CHECK_EQ(i->sm_count.reason, NVRM_R_RM_FAILED);
	nvrm_close(ctx);

	/* the RM cannot say the largest page size: no page size list */
	i = must_injected_discrete(&ctx, NVRM_P_MAX_PAGE_SIZE,
	    NVRM_R_RM_UNSUPPORTED);
	CHECK(NVRM_HAVE(i->family));
	CHECK(!NVRM_HAVE(i->page_sizes));
	CHECK_EQ(i->page_sizes.reason, NVRM_R_INPUT_MISSING);
	nvrm_close(ctx);

	/* UUID query fails */
	reset_env();
	nvrm_fake_inject_uuid_fail(NVRM_R_RM_FAILED);
	ctx = must_enum("discrete");
	CHECK(!NVRM_HAVE(info_of(ctx, 0)->uuid));
	nvrm_close(ctx);

	/* the family's key classes are there but 3D is not: class_absent */
	reset_env();
	nvrm_fake_inject_classes(no_eng3d, 3);
	ctx = must_enum("discrete");
	i = info_of(ctx, 0);
	CHECK(NVRM_HAVE(i->cls_compute));
	CHECK(!NVRM_HAVE(i->cls_eng3d));
	CHECK_EQ(i->cls_eng3d.reason, NVRM_R_CLASS_ABSENT);
	CHECK(NVRM_HAVE(i->cls_copy));
	nvrm_close(ctx);

	test_model_ada();
	reset_env();
}

static void
check_compute_capability(uint64_t architecture, uint64_t implementation,
    uint32_t major, uint32_t minor)
{
	uint32_t got_major = 99, got_minor = 99;

	CHECK_EQ(nvrm_compute_capability_for(architecture, implementation,
	    &got_major, &got_minor), 1);
	CHECK_EQ(got_major, major);
	CHECK_EQ(got_minor, minor);
}

static void
test_compute_capability_table(void)
{
	static const uint64_t ga86[] = { 2, 3, 4, 6, 7 };
	static const uint64_t gb120[] = { 2, 3, 5, 6, 7 };
	uint32_t major = 88, minor = 77;
	unsigned i;

	check_compute_capability(0x160, 0, 7, 5);
	check_compute_capability(0x160, 0xff, 7, 5);
	check_compute_capability(0x170, 0, 8, 0);
	for (i = 0; i < sizeof(ga86) / sizeof(ga86[0]); i++)
		check_compute_capability(0x170, ga86[i], 8, 6);
	check_compute_capability(0x170, 0x0b, 8, 7);
	check_compute_capability(0x190, 0, 8, 9);
	check_compute_capability(0x190, 0xff, 8, 9);
	check_compute_capability(0x180, 0, 9, 0);
	check_compute_capability(0x180, 1, 9, 0);
	check_compute_capability(0x1a0, 0, 10, 0);
	check_compute_capability(0x1a0, 2, 10, 0);
	for (i = 0; i < sizeof(gb120) / sizeof(gb120[0]); i++)
		check_compute_capability(0x1b0, gb120[i], 12, 0);
	check_compute_capability(0x1b0, 0x0b, 12, 1);
	CHECK_EQ(nvrm_compute_capability_for(0x1b0, 0x0c, &major, &minor), 0);
	CHECK_EQ(major, 88);
	CHECK_EQ(minor, 77);
	CHECK_EQ(nvrm_compute_capability_for(0xfff0, 1, &major, &minor), 0);
}

static void
test_family_match(void)
{
	static const nvrm_family tab[] = {
		{ "new", 10, 20, 0, 0, { 0 } },
		{ "old", 1, 2, 0, 0, { 0 } },
	};
	uint64_t both_old[] = { 2, 1 }, only_gpfifo[] = { 10 };
	uint64_t only_compute[] = { 20 }, all[] = { 1, 2, 10, 20 };

	CHECK(nvrm_family_match(tab, 2, both_old, 2) == &tab[1]);
	CHECK(nvrm_family_match(tab, 2, only_gpfifo, 1) == NULL);
	CHECK(nvrm_family_match(tab, 2, only_compute, 1) == NULL);
	CHECK(nvrm_family_match(tab, 2, all, 4) == &tab[0]);	/* newest first */
	CHECK(nvrm_family_match(tab, 2, all, 0) == NULL);
	CHECK(nvrm_family_match(tab, 0, all, 4) == NULL);
	/* a row with every page-size slot used: the scan ends on the count */
	{
		static const nvrm_family wide[] = {
			{ "wide", 1, 2, 0, 0, { 1, 2, 3, 4, 5, 6, 7, 8 } },
		};
		nvrm_device_info info;

		nvrm_info_init(&info);
		info.classes.reason = NVRM_R_NONE;
		info.classes.count = 2;
		info.classes.value[0] = 1;
		info.classes.value[1] = 2;
		info.max_page_size.reason = NVRM_R_NONE;
		info.max_page_size.value = 6;
		nvrm_apply_family(&info, wide, 1);
		CHECK_EQ(info.page_sizes.count, 6);
		info.max_page_size.value = 100;
		nvrm_apply_family(&info, wide, 1);
		CHECK_EQ(info.page_sizes.count, 8);
	}
	/* the production table: every row is reachable by its own key pair
	 * (a duplicated row would be shadowed by first-match-wins) */
	CHECK(nvrm_family_count >= 7);
	{
		unsigned a, b;

		for (a = 0; a < nvrm_family_count; a++) {
			uint64_t key[2];

			key[0] = nvrm_family_table[a].cls_gpfifo;
			key[1] = nvrm_family_table[a].cls_compute;
			CHECK(nvrm_family_match(nvrm_family_table,
			    nvrm_family_count, key, 2) == &nvrm_family_table[a]);
			for (b = a + 1; b < nvrm_family_count; b++)
				CHECK(nvrm_family_table[a].cls_gpfifo !=
				    nvrm_family_table[b].cls_gpfifo ||
				    nvrm_family_table[a].cls_compute !=
				    nvrm_family_table[b].cls_compute);
		}
	}
}

/* ---- board decorators --------------------------------------------------- */

static void
test_decorators(void)
{
	static const nvrm_decorator tab[] = {
		{ "board-a", 0x1111, 0x2222,
		    { { 2, 1 }, { 3, 0 }, { -1, 0 } } },
		{ "board-b", 0x1111, 0x3333, { { -1, 0 } } },
		{ "board-c", 0x1111, 0x2222, { { -1, 0 } } },
		{ "board-d", 0x1111, 0x2222, { { -1, 0 } } },
		{ "board-e", 0x1111, 0x2222, { { -1, 0 } } },
		{ "board-f", 0x1111, 0x2222, { { -1, 0 } } },
		{ NULL, 0, 0, { { -1, 0 } } },
	};
	nvrm_device_info i;
	nvrm_ctx *ctx;

	reset_env();
	/* production table: no board needs a decorator, so none matches */
	ctx = must_enum("discrete");
	CHECK_EQ(info_of(ctx, 0)->ndecorators, 0);
	CHECK(nvrm_decorator_table[0].name == NULL);
	nvrm_close(ctx);

	memset(&i, 0, sizeof(i));
	nvrm_info_init(&i);
	/* subsystem unknown: nothing matches, nothing is decided */
	nvrm_apply_decorators(&i, tab);
	CHECK_EQ(i.ndecorators, 0);
	i.pci_subsystem_vendor.reason = NVRM_R_NONE;
	i.pci_subsystem_vendor.value = 0x1111;
	nvrm_apply_decorators(&i, tab);
	CHECK_EQ(i.ndecorators, 0);	/* device id still unknown */
	i.pci_subsystem_device.reason = NVRM_R_NONE;
	i.pci_subsystem_device.value = 0x2222;
	nvrm_apply_decorators(&i, tab);
	/* matches a, c, d, e up to the limit; b (other device) never */
	CHECK_EQ(i.ndecorators, NVRM_MAX_DECORATORS);
	CHECK_STR(i.decorators[0], "board-a");
	CHECK_STR(i.decorators[1], "board-c");
	/* options are added or overridden, with the board as the source */
	CHECK(NVRM_HAVE(i.caps[2]) && i.caps[2].value == 1);
	CHECK(NVRM_HAVE(i.caps[3]) && i.caps[3].value == 0);
	CHECK(i.caps[2].source == NVRM_S_BOARD);
	/* ... and they never decide support: family stays as the table left it */
	CHECK(!NVRM_HAVE(i.family));
	CHECK(!NVRM_HAVE(i.cls_compute));
	/* a decorator may set every capability: the loop ends on the count */
	{
		static const nvrm_decorator full[] = {
			{ "full", 0x1111, 0x2222, { { 0, 1 }, { 1, 1 }, { 2, 1 },
			    { 3, 1 }, { 4, 1 }, { 5, 1 }, { 6, 1 } } },
			{ NULL, 0, 0, { { -1, 0 } } },
		};

		nvrm_apply_decorators(&i, full);
		CHECK_EQ(i.ndecorators, 1);
		CHECK(NVRM_HAVE(i.caps[6]) && i.caps[6].value == 1);
	}
	/* a row naming a capability that does not exist writes nothing */
	{
		static const nvrm_decorator oob[] = {
			{ "oob", 0x1111, 0x2222, { { NVRM_NCAPS, 1 }, { -1, 0 } } },
			{ NULL, 0, 0, { { -1, 0 } } },
		};

		nvrm_apply_decorators(&i, oob);
		CHECK_EQ(i.ndecorators, 1);
		CHECK_STR(i.decorators[0], "oob");
	}
	/* a different vendor, same device id: no match */
	i.pci_subsystem_vendor.value = 0x9999;
	nvrm_apply_decorators(&i, tab);
	CHECK_EQ(i.ndecorators, 0);
}

/* ---- init, names, fields ------------------------------------------------ */

static void
test_abi_1_0_layout(void)
{
	/* The 1.0 layout (LP64), measured from the header of commit 8702134:
	 * the file lib/libnvrm/include/nvrm/nvrm.h in that commit. */
	/* CPD-OFF -- ABI offset expectations are tabular data. */
	static const struct {
		const char *name;
		size_t got, want;
	} offsets[] = {
		{ "pci_domain", offsetof(nvrm_device_info, pci_domain), 0 },
		{ "pci_bus", offsetof(nvrm_device_info, pci_bus), 16 },
		{ "pci_slot", offsetof(nvrm_device_info, pci_slot), 32 },
		{ "pci_function", offsetof(nvrm_device_info, pci_function), 48 },
		{ "pci_vendor", offsetof(nvrm_device_info, pci_vendor), 64 },
		{ "pci_device", offsetof(nvrm_device_info, pci_device), 80 },
		{ "pci_subsystem_vendor",
		    offsetof(nvrm_device_info, pci_subsystem_vendor), 96 },
		{ "pci_subsystem_device",
		    offsetof(nvrm_device_info, pci_subsystem_device), 112 },
		{ "pci_revision", offsetof(nvrm_device_info, pci_revision), 128 },
		{ "rm_gpu_id", offsetof(nvrm_device_info, rm_gpu_id), 144 },
		{ "uuid", offsetof(nvrm_device_info, uuid), 160 },
		{ "architecture", offsetof(nvrm_device_info, architecture), 264 },
		{ "implementation",
		    offsetof(nvrm_device_info, implementation), 280 },
		{ "chip_id", offsetof(nvrm_device_info, chip_id), 296 },
		{ "sm_version_major",
		    offsetof(nvrm_device_info, sm_version_major), 312 },
		{ "sm_version_minor",
		    offsetof(nvrm_device_info, sm_version_minor), 328 },
		{ "gpc_count", offsetof(nvrm_device_info, gpc_count), 344 },
		{ "tpc_count", offsetof(nvrm_device_info, tpc_count), 360 },
		{ "sm_count", offsetof(nvrm_device_info, sm_count), 376 },
		{ "cls_gpfifo", offsetof(nvrm_device_info, cls_gpfifo), 392 },
		{ "cls_compute", offsetof(nvrm_device_info, cls_compute), 408 },
		{ "cls_eng3d", offsetof(nvrm_device_info, cls_eng3d), 424 },
		{ "cls_copy", offsetof(nvrm_device_info, cls_copy), 440 },
		{ "classes", offsetof(nvrm_device_info, classes), 456 },
		{ "family", offsetof(nvrm_device_info, family), 2072 },
		{ "vram_size", offsetof(nvrm_device_info, vram_size), 2176 },
		{ "bar1_size", offsetof(nvrm_device_info, bar1_size), 2192 },
		{ "max_page_size", offsetof(nvrm_device_info, max_page_size), 2208 },
		{ "numa_node", offsetof(nvrm_device_info, numa_node), 2224 },
		{ "page_sizes", offsetof(nvrm_device_info, page_sizes), 2240 },
		{ "caps", offsetof(nvrm_device_info, caps), 3856 },
		{ "ndecorators", offsetof(nvrm_device_info, ndecorators), 3968 },
		{ "decorators", offsetof(nvrm_device_info, decorators), 3976 },
	};
	/* CPD-ON */
	unsigned i;

	for (i = 0; i < sizeof(offsets) / sizeof(offsets[0]); i++) {
		if (offsets[i].got != offsets[i].want)
			printf("  %s: offset %ju, want %ju\n", offsets[i].name,
			    (uintmax_t)offsets[i].got, (uintmax_t)offsets[i].want);
		CHECK_EQ(offsets[i].got, offsets[i].want);
	}

	/* The 1.1 members follow the complete 1.0 structure, in table order. */
	CHECK_EQ(offsetof(nvrm_device_info, rm_sm_version), 4008);
	CHECK_EQ(offsetof(nvrm_device_info, compute_capability_major), 4024);
	CHECK_EQ(offsetof(nvrm_device_info, compute_capability_minor), 4040);
	CHECK_EQ(offsetof(nvrm_device_info, vbios), 4056);
	CHECK_EQ(offsetof(nvrm_device_info, gsp_firmware),
	    4056 + sizeof(nvrm_version_field));
	CHECK_EQ(sizeof(nvrm_device_info), offsetof(nvrm_device_info,
	    gsp_firmware) + sizeof(nvrm_version_field));
}

static void
test_names_and_fields(void)
{
	unsigned i;

	CHECK_STR(nvrm_strerror(NVRM_OK), "success");
	CHECK_STR(nvrm_strerror(NVRM_E_VERSION), "kernel module version mismatch");
	CHECK_STR(nvrm_strerror(-1), "unknown error");
	CHECK_STR(nvrm_strerror(NVRM_E__COUNT), "unknown error");
	CHECK_STR(nvrm_error_id(NVRM_E_NODEV), "no_gpu");
	CHECK_STR(nvrm_error_id(-1), "unknown");
	CHECK_STR(nvrm_error_id(NVRM_E__COUNT), "unknown");
	/* every code has a text and an id, none the fallback, no two alike */
	{
		int i, j;

		for (i = 0; i < NVRM_E__COUNT; i++) {
			CHECK(nvrm_strerror(i) != NULL && nvrm_error_id(i) != NULL);
			if (nvrm_strerror(i) == NULL || nvrm_error_id(i) == NULL)
				continue;
			CHECK(strcmp(nvrm_strerror(i), "unknown error") != 0);
			CHECK(strcmp(nvrm_error_id(i), "unknown") != 0);
			for (j = 0; j < i; j++) {
				CHECK(strcmp(nvrm_strerror(i), nvrm_strerror(j)) != 0);
				CHECK(strcmp(nvrm_error_id(i), nvrm_error_id(j)) != 0);
			}
		}
		CHECK_STR(nvrm_error_id(NVRM_E_DENIED), "denied");
		CHECK_STR(nvrm_error_id(NVRM_E_BUSY), "busy");
	}
	CHECK_STR(nvrm_reason_id(NVRM_R_NO_NUMA), "no_numa_node");
	CHECK_STR(nvrm_reason_id(-1), "unknown");
	CHECK_STR(nvrm_reason_id(NVRM_R__COUNT), "unknown");
	CHECK_STR(nvrm_reason_text(-1), "unknown reason");
	CHECK_STR(nvrm_reason_text(NVRM_R__COUNT), "unknown reason");
	CHECK(strlen(nvrm_reason_text(NVRM_R_NOT_QUERIED)) > 10);
	CHECK_STR(nvrm_reason_text(NVRM_R_VERSION_INCONSISTENT),
	    "the kernel module version sysctls disagree with its version string");
	CHECK_EQ(nvrm_reason_from_id("version_inconsistent"),
	    NVRM_R_VERSION_INCONSISTENT);
	CHECK_EQ(nvrm_reason_from_id("not_a_reason"), -1);
	CHECK_EQ(nvrm_reason_from_id(NULL), -1);
	/* the documented contract: the NONE id is not a reason a value gives */
	CHECK_EQ(nvrm_reason_from_id(nvrm_reason_id(NVRM_R_NONE)), -1);
	CHECK_STR(nvrm_source_name(NVRM_S_BOARD), "board");
	CHECK_STR(nvrm_source_name(-1), "unknown");
	CHECK_STR(nvrm_source_name(NVRM_S__COUNT), "unknown");
	CHECK(nvrm_cap_name(NVRM_NCAPS) == NULL);
	/* the capability index is a contract: every index has its name */
	{
		static const char *const want[] = { "dmabuf_export", "ats",
		    "self_hosted", "display_enabled", "soc",
		    "coherent_gpu_memory", "os_device_wc_active" };
		unsigned c;

		/* the names already released keep their index; a flag appended
		 * later adds a name here, it never moves one */
		CHECK(sizeof(want) / sizeof(want[0]) <= NVRM_NCAPS);
		for (c = 0; c < sizeof(want) / sizeof(want[0]); c++)
			CHECK_STR(nvrm_cap_name(c), want[c]);
	}
	/* every reason and every error has a distinct id and a text */
	for (i = 0; i < NVRM_R__COUNT; i++)
		CHECK(strlen(nvrm_reason_id(i)) > 0 &&
		    strlen(nvrm_reason_text(i)) > 0);
}

static void
test_field_table(void)
{
	unsigned i;

	/* the field table covers each kind and group exactly as declared */
	CHECK(nvrm_nfields >= 30);
	CHECK_EQ(nvrm_ngroups, 4);
	for (i = 0; i < nvrm_nfields; i++)
		CHECK(nvrm_fields[i].offset < sizeof(nvrm_device_info));
	/* every member of nvrm_device_info before the capabilities has exactly
	 * one table row: the rows tile [0, offsetof(caps)) with no gap and no
	 * overlap, so a new member without a row is caught here */
	{
		size_t pos = 0, sz = 0;
		unsigned j, found, rows = 0, appended = 0;

		while (pos < offsetof(nvrm_device_info, caps)) {
			found = 0;
			sz = sizeof(nvrm_u64);		/* progress on a gap */
			for (j = 0; j < nvrm_nfields; j++) {
				if (nvrm_fields[j].offset != pos)
					continue;
				found++;
				sz = nvrm_fields[j].kind == NVRM_K_U64 ?
				    sizeof(nvrm_u64) :
				    nvrm_fields[j].kind == NVRM_K_STR ?
				    sizeof(nvrm_str) :
				    nvrm_fields[j].kind == NVRM_K_LIST ?
				    sizeof(nvrm_list) : sizeof(nvrm_version_field);
			}
			CHECK_EQ(found, 1);
			rows += found;
			pos += sz;
		}
		CHECK_EQ(pos, offsetof(nvrm_device_info, caps));
		/* The rows of the members appended after the 1.0 layout, from
		 * rm_sm_version on, are checked separately below. */
		for (j = 0; j < nvrm_nfields; j++)
			if (NVRM_ADDED_AFTER_1_0(nvrm_fields[j].offset))
				appended++;
		CHECK_EQ(rows + appended, nvrm_nfields);
		/* NVRM_NFIELDS_1_0 is the table position where the appended
		 * rows start: the rows before it are 1.0 rows, every row from
		 * it on was added later (a row inserted mid-table fails here),
		 * and a duplicated row is caught by the count and by the
		 * pairwise distinct offsets. */
		CHECK_EQ(nvrm_nfields - appended, NVRM_NFIELDS_1_0);
		CHECK_EQ(appended, 5);
		for (j = 0; j < nvrm_nfields; j++) {
			unsigned k;

			CHECK(NVRM_ADDED_AFTER_1_0(nvrm_fields[j].offset) ==
			    (j >= NVRM_NFIELDS_1_0));
			for (k = j + 1; k < nvrm_nfields; k++)
				CHECK(nvrm_fields[j].offset !=
				    nvrm_fields[k].offset);
		}
	}
	/* ... and the whole struct is tied, not only the part before the
	 * capabilities: the capability array, the decorator count and the
	 * decorator names follow each other with nothing in between, and
	 * nothing follows the names.  A member added anywhere fails here until
	 * it has a row (or is one of these). */
	{
		nvrm_device_info *np = NULL;
		const size_t al = _Alignof(const char *);
		size_t caps_end = offsetof(nvrm_device_info, caps) +
		    sizeof(np->caps);
		size_t cnt_end = offsetof(nvrm_device_info, ndecorators) +
		    sizeof(np->ndecorators);

		CHECK_EQ(offsetof(nvrm_device_info, ndecorators), caps_end);
		CHECK_EQ(offsetof(nvrm_device_info, decorators),
		    (cnt_end + al - 1) / al * al);
		CHECK_EQ(offsetof(nvrm_device_info, rm_sm_version),
		    offsetof(nvrm_device_info, decorators) +
		    sizeof(np->decorators));
		CHECK_EQ(sizeof(nvrm_device_info),
		    offsetof(nvrm_device_info, gsp_firmware) +
		    sizeof(np->gsp_firmware));
		CHECK_EQ(sizeof(np->caps) / sizeof(np->caps[0]), NVRM_NCAPS);
		CHECK_EQ(sizeof(np->decorators) / sizeof(np->decorators[0]),
		    NVRM_MAX_DECORATORS);
	}
	/* a fresh info says "not queried" everywhere */
	{
		nvrm_device_info info;

		nvrm_info_init(&info);
		CHECK_EQ(info.uuid.reason, NVRM_R_NOT_QUERIED);
		CHECK_EQ(info.classes.reason, NVRM_R_NOT_QUERIED);
		CHECK_EQ(info.sm_count.reason, NVRM_R_NOT_QUERIED);
		CHECK_EQ(info.caps[NVRM_NCAPS - 1].reason, NVRM_R_NOT_QUERIED);
		CHECK(!info.vbios.version.available);
		CHECK_STR(info.vbios.version.reason, "not_queried");
	}
}

static void
test_accessors_refresh_json_table(void)
{
	nvrm_ctx *ctx;
	nvrm_field tab[64];
	unsigned i, n;
	char *buf = NULL;
	size_t len = 0;
	FILE *fp;

	reset_env();
	CHECK_EQ(nvrm_info_nfields(), nvrm_nfields);
	CHECK(nvrm_info_field(0) == &nvrm_fields[0]);
	CHECK(nvrm_info_field(nvrm_nfields) == NULL);

	/* refresh fails when the system call to the driver fails */
	ctx = must_enum("discrete");
	close(nvrm_fake_fd());
	CHECK_EQ(nvrm_device_refresh(nvrm_device_get(ctx, 0)), NVRM_E_IO);
	CHECK_EQ(info_of(ctx, 0)->gpc_count.reason, NVRM_R_OS_CALL_FAILED);
	nvrm_close(ctx);
	/* a version's own failed system call also makes refresh fail */
	reset_env();
	ctx = must_enum("discrete");
	nvrm_fake_inject_str_fail(NVRM_SP_VBIOS, NVRM_R_OS_CALL_FAILED);
	CHECK_EQ(nvrm_device_refresh(nvrm_device_get(ctx, 0)), NVRM_E_IO);
	t_check_unavailable_version_field(info_of(ctx, 0), "vbios", "",
	    "os_call_failed");
	nvrm_close(ctx);
	reset_env();
	/* a failed system call during enumeration fails it, in a string, a
	 * list or a capability alone; the message names the GPU */
	{
		char err[200];
		int rc;

		nvrm_fake_inject_uuid_fail(NVRM_R_OS_CALL_FAILED);
		ctx = enum_profile("discrete", &rc, err, sizeof(err));
		CHECK_EQ(rc, NVRM_E_IO);
		CHECK(ctx == NULL && strstr(err, "reading GPU 0") != NULL);
		reset_env();
		nvrm_fake_inject_classes_fail(NVRM_R_OS_CALL_FAILED);
		ctx = enum_profile("discrete", &rc, err, sizeof(err));
		CHECK_EQ(rc, NVRM_E_IO);
		reset_env();
		nvrm_fake_inject(NVRM_P_CAP_ATS, NVRM_R_OS_CALL_FAILED);
		ctx = enum_profile("discrete", &rc, err, sizeof(err));
		CHECK_EQ(rc, NVRM_E_IO);
		reset_env();
		/* the second GPU fails: the first is released, nothing leaks */
		nvrm_fake_inject(NVRM_P_CAP_ATS, NVRM_R_OS_CALL_FAILED);
		ctx = enum_profile("discrete,unified", &rc, err, sizeof(err));
		CHECK_EQ(rc, NVRM_E_IO);
		reset_env();
	}

	/* the emitter does not depend on the order of the field table: a
	 * group whose rows are not adjacent still gives valid JSON */
	ctx = must_enum("discrete");
	n = nvrm_nfields;
	for (i = 1; i < n; i++)
		tab[i - 1] = nvrm_fields[i];
	tab[n - 1] = nvrm_fields[0];	/* the first identity row moves last */
	fp = open_memstream(&buf, &len);
	CHECK_EQ(nvrm_json_device_fields(nvrm_device_get(ctx, 0), fp, tab, n), 0);
	fflush(fp);
	CHECK(strstr(buf, "}\"") == NULL);	/* a missing comma */
	CHECK(strstr(buf, "{,") == NULL && strstr(buf, ",,") == NULL &&
	    strstr(buf, ",}") == NULL);		/* a stray comma */
	CHECK(strstr(buf, "\"pci_domain\"") != NULL);
	fclose(fp);
	free(buf);
	nvrm_close(ctx);
}

static void
abort_handler(int sig)
{
	(void)sig;
	exit(77);		/* flush the coverage data, then report */
}

static void
test_field_reason_and_masks(void)
{
	nvrm_device_info info;
	nvrm_field bad = { "gpu", "x", 99, 0, 0, "x" };
	nvrm_enum_opts o = { "fake" };
	nvrm_ctx *ctx;
	char err[100];
	pid_t pid;
	int st;

	reset_env();
	nvrm_info_init(&info);
	CHECK(nvrm_field_reason(&info, &nvrm_fields[0]) == &info.pci_domain.reason);
	/* an unknown field kind aborts instead of guessing an offset */
	fflush(stdout);
	pid = fork();
	if (pid == 0) {
		signal(SIGABRT, abort_handler);
		(void)nvrm_field_reason(&info, &bad);
		_exit(1);
	}
	waitpid(pid, &st, 0);
	CHECK(WIFEXITED(st) && WEXITSTATUS(st) == 77);

	/* a GPC mask wider than the TPC walk covers is not reported as a count */
	nvrm_fake_inject_value(NVRM_P_GPC_MASK, (1ULL << 40) | 1);
	ctx = must_enum("discrete");
	CHECK(!NVRM_HAVE(info_of(ctx, 0)->gpc_count));
	CHECK_EQ(info_of(ctx, 0)->gpc_count.reason, NVRM_R_VALUE_UNUSABLE);
	CHECK(!NVRM_HAVE(info_of(ctx, 0)->tpc_count));
	CHECK(!NVRM_HAVE(info_of(ctx, 0)->sm_count));
	nvrm_close(ctx);
	reset_env();

	/* the default (least privilege) descriptors still enumerate and refresh */
	setenv("NVRM_FAKE_PROFILE", "discrete", 1);
	CHECK_EQ(nvrm_enumerate(&ctx, &o, err, sizeof(err)), NVRM_OK);
	CHECK_EQ(nvrm_device_refresh(nvrm_device_get(ctx, 0)), NVRM_OK);
	nvrm_close(ctx);
	/* the explicit opt-in for allocation (there is no mapping in S1) */
	o.flags = NVRM_ENUM_ALLOW_ALLOC;
	CHECK_EQ(nvrm_enumerate(&ctx, &o, err, sizeof(err)), NVRM_OK);
	nvrm_close(ctx);
	/* a bit the library does not know, including the retired bit 0 of the
	 * old positional member, is refused rather than read as a privilege */
	o.flags = 1;
	CHECK_EQ(nvrm_enumerate(&ctx, &o, err, sizeof(err)), NVRM_E_INVAL);
	CHECK(ctx == NULL && strstr(err, "unknown enumeration flags") != NULL);
	o.flags = NVRM_ENUM_ALLOW_ALLOC | 0x100;
	CHECK_EQ(nvrm_enumerate(&ctx, &o, err, sizeof(err)), NVRM_E_INVAL);
	/* each reserved word must be zero */
	{
		unsigned i;

		o.flags = 0;
		for (i = 0; i < 4; i++) {
			memset(o.reserved, 0, sizeof(o.reserved));
			o.reserved[i] = 1u << i;
			ctx = (nvrm_ctx *)1;
			CHECK_EQ(nvrm_enumerate(&ctx, &o, err, sizeof(err)), NVRM_E_INVAL);
			CHECK(ctx == NULL && strstr(err, "reserved must be zero") != NULL);
		}
		memset(o.reserved, 0, sizeof(o.reserved));
		CHECK_EQ(nvrm_enumerate(&ctx, &o, err, sizeof(err)), NVRM_OK);
		nvrm_close(ctx);
	}
}

/* ---- Capsicum helper ----------------------------------------------------- */

static void
test_cap_helper(void)
{
	static const unsigned long a[] = { 1 }, b[] = { 2 };
	int p[2];

	CHECK_EQ(nvrm_cap_limit_fd(-1, a, 1), NVRM_E_CAPSICUM);
	CHECK_EQ(pipe(p), 0);
	CHECK_EQ(nvrm_cap_limit_fd(p[0], a, 1), NVRM_OK);
	/* a limit can only be narrowed: a disjoint set is refused */
	CHECK_EQ(nvrm_cap_limit_fd(p[0], b, 1), NVRM_E_CAPSICUM);
	close(p[0]);
	close(p[1]);
}

/* ---- the fake backend's own ops ------------------------------------------ */

static void
test_fake_direct(void)
{
	const nvrm_backend_ops *o = &nvrm_backend_fake_ops;
	nvrm_backend *be;
	nvrm_gpu *g, *g2;
	uint32_t ids[4], cl[2];
	unsigned n;
	uint64_t v;
	char err[100], buf[64], big[4096];
	nvrm_str rv;
	int i;

	reset_env();
	/* an injected class list replaces the profile's, even a failing one */
	nvrm_registry_reset();
	nvrm_registry_builtin();
	{
		static const uint32_t some[] = { 7, 8, 9 };
		nvrm_ctx *c2;

		nvrm_fake_inject_classes(some, 3);
		c2 = must_enum("sparse");
		CHECK_EQ(info_of(c2, 0)->classes.count, 3);
		nvrm_close(c2);
		nvrm_fake_inject_clear();
	}

	/* profile list: unknown name, empty items, too many */
	setenv("NVRM_FAKE_PROFILE", "bogus", 1);
	CHECK_EQ(o->open(&be, err, sizeof(err)), NVRM_E_INVAL);
	CHECK(be == NULL && strstr(err, "unknown profile \"bogus\"") != NULL);
	big[0] = '\0';
	for (i = 0; i < 33; i++)
		strcat(big, i ? ",discrete" : "discrete");
	setenv("NVRM_FAKE_PROFILE", big, 1);
	CHECK_EQ(o->open(&be, err, sizeof(err)), NVRM_E_INVAL);
	CHECK(strstr(err, "more than 32 GPUs") != NULL);
	big[0] = '\0';
	for (i = 0; i < 32; i++)
		strcat(big, i ? ",discrete" : "discrete");
	setenv("NVRM_FAKE_PROFILE", big, 1);
	CHECK_EQ(o->open(&be, err, sizeof(err)), NVRM_OK);
	CHECK_EQ(o->list_gpus(be, ids, 4, &n, err, sizeof(err)), NVRM_OK);
	CHECK_EQ(n, 4);			/* bounded by the caller's maximum */
	o->close(be);
	setenv("NVRM_FAKE_PROFILE", "", 1);	/* empty = the default */
	CHECK_EQ(o->open(&be, err, sizeof(err)), NVRM_OK);
	CHECK_EQ(o->list_gpus(be, ids, 4, &n, err, sizeof(err)), NVRM_OK);
	CHECK_EQ(n, 1);
	o->running_version(be, &rv);
	CHECK_STR(rv.value, NVRM_RM_VERSION);
	CHECK_EQ(o->gpu_open(be, ids[0], &g, err, sizeof(err)), NVRM_OK);
	CHECK_EQ(o->gpu_open(be, ids[0], &g2, err, sizeof(err)), NVRM_OK);

	/* queries: the TPC argument is bounded, ids come from the listing */
	CHECK_EQ(o->gpu_u64(g, NVRM_P_TPC_MASK, 0, &v), 0);
	CHECK_EQ(v, 0x3f);
	CHECK_EQ(o->gpu_u64(g, NVRM_P_TPC_MASK, 32, &v), NVRM_R_RM_FAILED);
	CHECK_EQ(o->gpu_u64(g, NVRM_P_RM_GPU_ID, 0, &v), 0);
	CHECK_EQ(v, ids[0]);
	CHECK_EQ(o->gpu_str(g, NVRM_SP_UUID, buf, sizeof(buf)), 0);
	CHECK_STR(buf, "GPU-00000000-0000-4000-8000-0000000000a1");
	CHECK_EQ(o->gpu_str(g, NVRM_SP_VBIOS, buf, sizeof(buf)), 0);
	CHECK_STR(buf, "96.06.1e.00.4a");
	CHECK_EQ(o->gpu_str(g, NVRM_SP_GSP_FIRMWARE, buf, sizeof(buf)), 0);
	CHECK_STR(buf, "580.178.04");
	CHECK_EQ(o->gpu_str(g, (enum nvrm_sprop)-1, buf, sizeof(buf)),
	    NVRM_R_BACKEND_NONE);
	CHECK_EQ(o->gpu_str(g, NVRM_SP_COUNT, buf, sizeof(buf)),
	    NVRM_R_BACKEND_NONE);
	CHECK_EQ(o->gpu_classes(g, cl, 2, &n), 0);
	CHECK_EQ(n, 2);			/* truncated to the caller's room */

	/* the owned descriptor is gone: every query says the RM call failed */
	close(nvrm_fake_fd());
	CHECK_EQ(o->gpu_u64(g, NVRM_P_ARCHITECTURE, 0, &v),
	    NVRM_R_OS_CALL_FAILED);
	CHECK_EQ(o->gpu_str(g, NVRM_SP_UUID, buf, sizeof(buf)),
	    NVRM_R_OS_CALL_FAILED);
	CHECK_EQ(o->gpu_classes(g, cl, 2, &n), NVRM_R_OS_CALL_FAILED);
	o->gpu_close(g);
	o->gpu_close(g2);
	o->close(be);

	/* descriptor exhaustion: the pipe cannot be made */
	{
		struct rlimit rl, saved;
		int j;

		getrlimit(RLIMIT_NOFILE, &saved);
		rl = saved;
		j = dup(0);		/* the highest descriptor in use */
		close(j);
		rl.rlim_cur = (rlim_t)j;
		setrlimit(RLIMIT_NOFILE, &rl);
		CHECK_EQ(o->open(&be, err, sizeof(err)), NVRM_E_OPEN);
		CHECK(strstr(err, "pipe2") != NULL);
		setrlimit(RLIMIT_NOFILE, &saved);
	}
	reset_env();
}

static void
test_public_versions(void)
{
	static const uint32_t built_for[] = { 580, 178, 4 };
	static const uint32_t library[] = { 1, 3, 0 };
	static const uint32_t symbols[] = { 1, 3 };
	static const uint32_t schema[] = { 1, 3 };
	nvrm_ctx *ctx;
	const nvrm_version *v;

	CHECK_EQ(NVRM_API_MAJOR, 1);
	CHECK_EQ(NVRM_API_MINOR, 3);
	t_check_version(nvrm_built_for_version(), NVRM_RM_VERSION, built_for, 3,
	    "");
	t_check_version(nvrm_library_version(), "1.3.0", library, 3, "");
	v = nvrm_symbol_version();
	t_check_version(v, "NVRM_1.3", symbols, 2, "");
	CHECK(v == nvrm_symbol_version());
	t_check_version(nvrm_schema_version(), "1.3", schema, 2, "");
	CHECK(nvrm_schema_version() == nvrm_schema_version());
	CHECK(nvrm_built_for_version() == nvrm_built_for_version());
	CHECK(nvrm_library_version() == nvrm_library_version());

	reset_env();
	ctx = must_enum("discrete");
	t_check_version(nvrm_driver_version(ctx), NVRM_RM_VERSION, built_for, 3,
	    "");
	t_check_version(nvrm_rm_api_version(ctx), NVRM_RM_VERSION, built_for, 3,
	    "");
	nvrm_close(ctx);
}

/* ---- JSON ---------------------------------------------------------------- */

static void test_json_versions_and_errors(nvrm_ctx *ctx);

static void
test_json(void)
{
	nvrm_ctx *ctx;
	FILE *fp;
	char *buf = NULL;
	size_t len = 0;
	nvrm_device *dev;

	reset_env();
	ctx = must_enum("discrete,sparse");
	fp = open_memstream(&buf, &len);
	CHECK_EQ(nvrm_json_document(ctx, fp), 0);
	CHECK_EQ(nvrm_json_header(ctx, fp), 0);
	CHECK_EQ(nvrm_json_device(nvrm_device_get(ctx, 0), fp), 0);
	CHECK_EQ(nvrm_json_end(2, fp), 0);
	CHECK_EQ(nvrm_json_error("code", "a \"quoted\" \\ line\nand \x01 ctl \x7f \xc3\xa9",
	    fp), 0);
	fflush(fp);
	CHECK(strstr(buf, "{,") == NULL && strstr(buf, ",,") == NULL &&
	    strstr(buf, ",}") == NULL && strstr(buf, "}\"") == NULL);
	CHECK(strstr(buf, "\"kind\":\"document\"") != NULL);
	CHECK(strstr(buf, "\"schema_minor\":3") != NULL);
	CHECK(strstr(buf, "\"built_for_rm_version\":\"580.178.04\"") != NULL);
	CHECK(strstr(buf, "\"running_rm_version\":{\"available\":true,"
	    "\"value\":\"580.178.04\",\"source\":\"os\"}") != NULL);
	CHECK(strstr(buf, "\"versions\":{\"driver\":{\"available\":true,"
	    "\"string\":\"580.178.04\",\"major\":580,\"minor\":178,"
	    "\"patch\":4,\"parts\":[580,178,4],\"source\":\"os\"},"
	    "\"rm_api\":") != NULL);
	CHECK(strstr(buf, "\"built_for\":{\"available\":true,"
	    "\"string\":\"580.178.04\",\"major\":580,\"minor\":178,"
	    "\"patch\":4,\"parts\":[580,178,4],\"source\":\"derived\"}") != NULL);
	CHECK(strstr(buf, "\"library\":{\"available\":true,"
	    "\"string\":\"1.3.0\",\"major\":1,\"minor\":3,\"patch\":0,"
	    "\"parts\":[1,3,0],\"source\":\"derived\"}") != NULL);
	CHECK(strstr(buf, "\"library_symbols\":{\"available\":true,"
	    "\"string\":\"NVRM_1.3\",\"major\":1,\"minor\":3,\"patch\":0,"
	    "\"parts\":[1,3],\"source\":\"derived\"}") != NULL);
	CHECK(strstr(buf, "\"schema\":{\"available\":true,\"string\":\"1.3\","
	    "\"major\":1,\"minor\":3,\"patch\":0,\"parts\":[1,3],"
	    "\"source\":\"derived\"}") != NULL);
	CHECK(strstr(buf, "\"pci_vendor\":{\"available\":true,\"value\":4318,"
	    "\"source\":\"os\"}") != NULL);
	CHECK(strstr(buf, "\"name\":\"dmabuf_export\",\"available\":true,"
	    "\"value\":true") != NULL);
	CHECK(strstr(buf, "\"classes\":{\"available\":true,\"value\":[") != NULL);
	CHECK(strstr(buf, "\"kind\":\"header\"") != NULL);
	CHECK(strstr(buf, "\"kind\":\"end\",\"count\":2") != NULL);
	CHECK(strstr(buf, "\\\"quoted\\\" \\\\ line\\nand \\u0001 ctl "
	    "\\u007f \\ufffd\\ufffd") != NULL);	/* not ASCII: U+FFFD, not mojibake */
	/* the unavailable shape, with the reason id and text */
	CHECK(strstr(buf, "\"available\":false,\"reason_id\":\"os_not_reported\","
	    "\"reason\":\"the OS layer does not report this value\"") != NULL);
	/* decorators are strings in an array */
	dev = nvrm_device_get(ctx, 0);
	dev->info.ndecorators = 2;
	dev->info.decorators[0] = "a\"b";
	dev->info.decorators[1] = "c";
	fclose(fp);
	free(buf);
	buf = NULL;
	fp = open_memstream(&buf, &len);
	nvrm_json_device(dev, fp);
	fflush(fp);
	CHECK(strstr(buf, "\"decorators\":[\"a\\\"b\",\"c\"]") != NULL);
	fclose(fp);
	free(buf);

	test_json_versions_and_errors(ctx);
}

static void
test_json_versions_and_errors(nvrm_ctx *ctx)
{
	FILE *fp, *ro, *dn;
	char *buf = NULL;
	size_t len = 0;
	pid_t pid;
	int st;

	/* A suffix is optional, and an unavailable version keeps its raw string
	 * and reason while omitting every numeric part. */
	CHECK_EQ(nvrm_version_parse("580.178.04-rc1", 10, &ctx->rm_api), 0);
	buf = NULL;
	len = 0;
	fp = open_memstream(&buf, &len);
	CHECK_EQ(nvrm_json_header(ctx, fp), 0);
	fflush(fp);
	CHECK(strstr(buf, "\"rm_api\":{\"available\":true,"
	    "\"string\":\"580.178.04-rc1\",\"major\":580,\"minor\":178,"
	    "\"patch\":4,\"parts\":[580,178,4],\"suffix\":\"-rc1\","
	    "\"source\":\"rm\"}") != NULL);
	fclose(fp);
	free(buf);
	ctx->driver.available = 0;
	strcpy(ctx->driver.string, "N/A");
	ctx->driver.nparts = 0;
	ctx->driver.reason = "version_unparsed";
	buf = NULL;
	len = 0;
	fp = open_memstream(&buf, &len);
	CHECK_EQ(nvrm_json_header(ctx, fp), 0);
	fflush(fp);
	CHECK(strstr(buf, "\"driver\":{\"available\":false,\"string\":\"N/A\","
	    "\"reason_id\":\"version_unparsed\",\"reason\":\"the version string "
	    "has no readable numeric scheme\",\"source\":\"os\"}") != NULL);
	fclose(fp);
	free(buf);

	/* An unknown stored reason id is a programming error, not version_unparsed. */
	ctx->driver.reason = "os_call_faild";
	fflush(stdout);
	pid = fork();
	if (pid == 0) {
		signal(SIGABRT, abort_handler);
		fp = open_memstream(&buf, &len);
		if (fp == NULL)
			_exit(2);
		(void)nvrm_json_header(ctx, fp);
		_exit(1);
	}
	CHECK(pid > 0);
	waitpid(pid, &st, 0);
	CHECK(WIFEXITED(st) && WEXITSTATUS(st) == 77);
	ctx->driver.reason = nvrm_reason_id(NVRM_R_VERSION_UNPARSED);
	buf = NULL;
	len = 0;

	/* a stream that fails: the error is reported, not lost */
	ro = fopen("/dev/null", "r");		/* writes fail, flush is fine */
	CHECK_EQ(nvrm_json_end(0, ro), -1);
	CHECK_EQ(nvrm_json_schema(ro), -1);
	fclose(ro);
	dn = fopen("/dev/full", "w");		/* the flush itself fails */
	if (dn != NULL) {
		CHECK_EQ(nvrm_json_end(0, dn), -1);
		CHECK_EQ(nvrm_json_schema(dn), -1);
		fclose(dn);
	}
	/* the schema is valid-looking and names itself */
	buf = NULL;
	fp = open_memstream(&buf, &len);
	CHECK_EQ(nvrm_json_schema(fp), 0);
	fflush(fp);
	CHECK(strstr(buf, "urn:cloudbsd:nvrm:schema:nvrm-info/1") != NULL);
	CHECK(strstr(buf, "major version 1, minor 3") != NULL);
	CHECK(strstr(buf, "\"version\": {") != NULL);
	CHECK(strstr(buf, "\"versions\": {") != NULL);
	CHECK(strstr(buf, "\"library_symbols\": { \"$ref\": "
	    "\"#/$defs/version\" }") != NULL);
	CHECK(strstr(buf, "\"version_unparsed\"") != NULL);
	CHECK(strstr(buf, "\"sm_count\"") != NULL);
	CHECK(strstr(buf, "\"capability\"") != NULL);
	fclose(fp);
	free(buf);
	nvrm_close(ctx);
}

/* ---- threads: the lazy registry is filled once ---------------------------- */

static pthread_barrier_t race_bar;
static const nvrm_backend_ops *race_got[8];

static volatile int race_paused;

static void
race_pause(void)
{
	race_paused++;
	usleep(20000);	/* the first thread sits in the middle of registering */
}

static void *
race_thread(void *arg)
{
	pthread_barrier_wait(&race_bar);
	race_got[(uintptr_t)arg] = nvrm_backend_select("fake");
	return (NULL);
}

/* Must run before anything else selects a backend: the registry is lazy and
 * process wide, so the race happens once.  It runs in a child process, with
 * the registry still pristine (the child's profile is merged by %p). */
static void
test_registry_threads(void)
{
	pthread_t th[8];
	unsigned k;
	pid_t pid;
	int st, bad;

	fflush(stdout);
	pid = fork();
	if (pid == 0) {
		bad = 0;
		nvrm_registry_pause_hook = race_pause;
		bad += pthread_barrier_init(&race_bar, NULL, 8) != 0;
		for (k = 0; k < 8; k++)
			bad += pthread_create(&th[k], NULL, race_thread,
			    (void *)(uintptr_t)k) != 0;
		for (k = 0; k < 8; k++)
			pthread_join(th[k], NULL);
		for (k = 0; k < 8; k++)
			bad += race_got[k] != &nvrm_backend_fake_ops;
		/* the precondition, as a check: the registry was pristine (the
		 * pause ran) and the registration ran once, not once per thread */
		if (race_paused != 1)
			printf("FAIL threads: the registration ran %d times, "
			    "want 1 (a registry that was not pristine, or a "
			    "race)\n", race_paused);
		bad += race_paused != 1;
		/* exactly the two built-in providers, however many raced */
		if (nvrm_registry_count() != 2)
			printf("FAIL threads: %u providers registered, want 2\n",
			    nvrm_registry_count());
		bad += nvrm_registry_count() != 2;
		exit(bad == 0 ? 0 : 1);
	}
	CHECK(pid > 0);
	CHECK(waitpid(pid, &st, 0) == pid);
	CHECK(WIFEXITED(st) && WEXITSTATUS(st) == 0);
}

static void
test_boot_select(void)
{
	reset_env();
	/* the first selection registers the built-in providers by itself */
	CHECK(nvrm_backend_select("fake") == &nvrm_backend_fake_ops);
	CHECK(nvrm_backend_select("rm") == &nvrm_backend_rm_ops);
}

#define CORE_TESTS(X, N)						\
	N("threads", test_registry_threads, \
	    "it needs a registry no other test has touched") \
	N("boot", test_boot_select, \
	    "the registry is lazy: it fills on the first selection") \
	X("registry", test_registry) \
	X("enumerate", test_enumerate) \
	X("model", test_model_discrete) \
	X("model", test_model_unified) \
	X("model", test_model_unknown_and_sparse) \
	X("model", test_device_versions) \
	X("model", test_model_injections) \
	X("model", test_compute_capability_table) \
	X("model", test_family_match) \
	X("decorators", test_decorators) \
	X("abi", test_abi_1_0_layout) \
	X("names", test_names_and_fields) \
	X("names", test_field_table) \
	X("names", test_accessors_refresh_json_table) \
	X("names", test_field_reason_and_masks) \
	X("cap", test_cap_helper) \
	X("fake", test_fake_direct) \
	X("version", test_public_versions) \
	X("json", test_json)

T_TABLE(tests, CORE_TESTS);

int
main(int argc, char **argv)
{
	t_run(tests, sizeof(tests) / sizeof(tests[0]));
	return (t_done("core_test"));
}

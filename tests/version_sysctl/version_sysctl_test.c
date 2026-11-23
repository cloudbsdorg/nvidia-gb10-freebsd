/* User-space behavioral test for src/gb10-version/nv_version_sysctl.c. */
#include <sys/types.h>
#include <sys/systm.h>
#include <sys/sysctl.h>

#include "nv_version_sysctl.h"

#define MAX_OIDS	256
#define REAL_BANNER \
	"NVIDIA UNIX Open Kernel Module for aarch64  580.178.04  Release Build  " \
	"(cloudbsd@build)  Sun Nov 22 06:36:44 UTC 2026"

#ifndef NV_VERSION_SYSCTL_MODESET
struct fake_device {
	struct sysctl_ctx_list ctx;
	struct sysctl_oid *tree;
};
#endif

static struct sysctl_oid oids[MAX_OIDS];
static unsigned noids;
struct sysctl_oid fake_hw = { .name = "hw" };
static int checks, failures;
static const char *fail_node;
static int null_parent_use;
#ifndef NV_VERSION_SYSCTL_MODESET
static nvidia_stack_t stack;
static int stack_outstanding;
static char fake_uuid[80];
static char fake_vbios[NV_VBIOS_VERSION_LEN];
static int vbios_fetches, firmware_fetches;
static int vbios_nowrite;
static int uuid_null;
static char fake_firmware[64];
static int uuid_frees;
#endif

static void
check_true(int condition, const char *what)
{
	checks++;
	if (!condition) {
		failures++;
		printf("FAIL %s\n", what);
	}
}

static void
check_int_value(const char *what, int got, int want)
{
	checks++;
	if (got != want) {
		failures++;
		printf("FAIL %s: got %d, want %d\n", what, got, want);
	}
}

static void
check_string_value(const char *what, const char *got, const char *want)
{
	checks++;
	if (strcmp(got, want) != 0) {
		failures++;
		printf("FAIL %s: got <%s>, want <%s>\n", what, got, want);
	}
}

static struct sysctl_oid *
add_oid(struct sysctl_ctx_list *ctx, struct sysctl_oid *parent,
    const char *name, void *arg1)
{
	struct sysctl_oid *oid;

	check_true(noids < MAX_OIDS, "fake sysctl table capacity");
	if (noids >= MAX_OIDS)
		return (NULL);
	oid = &oids[noids++];
	memset(oid, 0, sizeof(*oid));
	oid->name = name;
	oid->ctx = ctx;
	oid->parent = parent;
	oid->arg1 = arg1;
	return (oid);
}

struct sysctl_oid *
fake_sysctl_add_node(struct sysctl_ctx_list *ctx, struct sysctl_oid *parent,
    const char *name, int flags, const char *desc)
{
	struct sysctl_oid *oid;

	if (fail_node != NULL && strcmp(name, fail_node) == 0)
		return (NULL);
	oid = add_oid(ctx, parent, name, NULL);
	if (oid != NULL) {
		oid->flags = flags;
		oid->description = desc;
	}
	return (oid);
}

struct sysctl_oid *
fake_children(struct sysctl_oid *oid)
{
	if (oid == NULL)
		null_parent_use++;
	return (oid);
}

struct sysctl_oid *
fake_sysctl_add_string(struct sysctl_ctx_list *ctx, struct sysctl_oid *parent,
    const char *name, int flags, char *value, size_t len, const char *desc)
{
	struct sysctl_oid *oid;

	(void)len;
	oid = add_oid(ctx, parent, name, value);
	if (oid != NULL) {
		oid->flags = flags;
		oid->description = desc;
	}
	return (oid);
}

struct sysctl_oid *
fake_sysctl_add_int(struct sysctl_ctx_list *ctx, struct sysctl_oid *parent,
    const char *name, int flags, int *value, const char *desc)
{
	struct sysctl_oid *oid;

	oid = add_oid(ctx, parent, name, value);
	if (oid != NULL) {
		oid->flags = flags;
		oid->description = desc;
	}
	return (oid);
}

struct sysctl_oid *
fake_sysctl_add_proc(struct sysctl_ctx_list *ctx, struct sysctl_oid *parent,
    const char *name, const struct fake_proc_args *args)
{
	struct sysctl_oid *oid;

	oid = add_oid(ctx, parent, name, args->arg1);
	if (oid != NULL) {
		oid->arg2 = args->arg2;
		oid->handler = args->handler;
		oid->flags = args->flags;
		oid->fmt = args->fmt;
		oid->description = args->desc;
	}
	return (oid);
}

int
fake_sysctl_out(struct sysctl_req *req, const void *value, size_t len)
{
	if (req->newptr != NULL)
		return (EPERM);
	if (req->oldptr == NULL || req->oldlen < len)
		return (ENOMEM);
	memcpy(req->oldptr, value, len);
	req->oldlen = len;
	return (0);
}

void
fake_sysctl_ctx_free(struct sysctl_ctx_list *ctx)
{
	ctx->freed = 1;
}

static struct sysctl_oid *
find_oid(struct sysctl_oid *parent, const char *name)
{
	unsigned i;

	if (parent == NULL)
		return (NULL);
	for (i = 0; i < noids; i++) {
		if (oids[i].parent == parent && strcmp(oids[i].name, name) == 0)
			return (&oids[i]);
	}
	return (NULL);
}

static struct sysctl_oid *
need_oid(struct sysctl_oid *parent, const char *name)
{
	struct sysctl_oid *oid = find_oid(parent, name);
	check_true(oid != NULL, name);
	return (oid);
}

#ifndef NV_VERSION_SYSCTL_MODESET
static void
expect_oid_context(struct sysctl_oid *parent, const char *name,
    struct sysctl_ctx_list *want)
{
	struct sysctl_oid *oid = need_oid(parent, name);

	if (oid != NULL)
		check_true(oid->ctx == want, "identity sysctl uses softc context");
}

#endif

static void
expect_static_int(struct sysctl_oid *parent, const char *name, int want)
{
	struct sysctl_oid *oid = need_oid(parent, name);

	if (oid != NULL)
		check_int_value(name, *(int *)oid->arg1, want);
}

static void
expect_static_string(struct sysctl_oid *parent, const char *name,
    const char *want)
{
	struct sysctl_oid *oid = need_oid(parent, name);

	if (oid != NULL)
		check_string_value(name, (const char *)oid->arg1, want);
}

#ifndef NV_VERSION_SYSCTL_MODESET
static void
expect_oid_type(struct sysctl_oid *oid, const char *name, int type,
    const char *fmt)
{
	check_int_value(name, oid->flags & CTLTYPE, type);
	check_true(oid->fmt != NULL && strcmp(oid->fmt, fmt) == 0,
	    "sysctl format matches the registered type");
}

static void
expect_proc_int(struct sysctl_oid *parent, const char *name, nv_state_t *nv,
    int want)
{
	struct sysctl_oid *oid = need_oid(parent, name);
	struct sysctl_req req;
	int error, value = -1;

	if (oid == NULL)
		return;
	expect_oid_type(oid, name, CTLTYPE_INT, "I");
	memset(&req, 0, sizeof(req));
	req.oldptr = &value;
	req.oldlen = sizeof(value);
	error = oid->handler(oid, nv, oid->arg2, &req);
	check_int_value(name, error, 0);
	check_int_value(name, value, want);
}

static void
expect_proc_string(struct sysctl_oid *parent, const char *name, nv_state_t *nv,
    const char *want)
{
	struct sysctl_oid *oid = need_oid(parent, name);
	struct sysctl_req req;
	char value[256];
	int error;

	if (oid == NULL)
		return;
	expect_oid_type(oid, name, CTLTYPE_STRING, "A");
	memset(&req, 0, sizeof(req));
	memset(value, 0, sizeof(value));
	req.oldptr = value;
	req.oldlen = sizeof(value);
	error = oid->handler(oid, nv, oid->arg2, &req);
	check_int_value(name, error, 0);
	check_string_value(name, value, want);
}

nvidia_stack_t *
fake_stack_alloc(void)
{
	stack_outstanding++;
	return (&stack);
}

void
fake_stack_free(nvidia_stack_t *sp)
{
	check_true(sp == &stack, "stack allocation identity");
	stack_outstanding--;
}

char *
rm_get_gpu_uuid(nvidia_stack_t *sp, nv_state_t *nv)
{
	(void)sp;
	(void)nv;
	if (uuid_null)
		return (NULL);
	return (fake_uuid);
}

void
rm_get_vbios_version(nvidia_stack_t *sp, nv_state_t *nv, char *out)
{
	(void)sp;
	(void)nv;
	vbios_fetches++;
	if (!vbios_nowrite)
		strlcpy(out, fake_vbios, NV_VBIOS_VERSION_LEN);
}

void
rm_get_firmware_version(nvidia_stack_t *sp, nv_state_t *nv, char *out,
    size_t len)
{
	(void)sp;
	(void)nv;
	firmware_fetches++;
	strlcpy(out, fake_firmware, len);
}

void
os_free_mem(void *ptr)
{
	check_true(ptr == fake_uuid, "UUID buffer freed");
	uuid_frees++;
}

struct sysctl_oid *
device_get_sysctl_tree(device_t dev)
{
	return (dev->tree);
}
#endif /* !NV_VERSION_SYSCTL_MODESET */

static void
test_driver_versions(void)
{
	static const char no_version[] =
	    "NVIDIA UNIX Open Kernel Module for aarch64 Release Build";
	static const char suffixed[] = "NVIDIA driver 1.2.3-rc1 test";
	struct sysctl_ctx_list ctx1, ctx2, ctx3;
	struct nv_version_sysctl_state st1, st2, st3;
	struct sysctl_oid *root1, *root2, *root3;

	root1 = fake_sysctl_add_node(&ctx1, &fake_hw, "nvidia", 0, "test");
	nv_version_sysctl_init(&ctx1, root1, REAL_BANNER, &st1);
	expect_static_string(root1, "version_string", "580.178.04");
	expect_static_int(root1, "version_major", 580);
	expect_static_int(root1, "version_minor", 178);
	expect_static_int(root1, "version_patch", 4);
	expect_static_int(root1, "version_available", 1);
	expect_static_string(root1, "version_suffix", "");

	root2 = fake_sysctl_add_node(&ctx2, &fake_hw, "nvidia2", 0, "test");
	nv_version_sysctl_init(&ctx2, root2, no_version, &st2);
	expect_static_string(root2, "version_string", "");
	expect_static_int(root2, "version_major", 0);
	expect_static_int(root2, "version_minor", 0);
	expect_static_int(root2, "version_patch", 0);
	expect_static_int(root2, "version_available", 0);
	expect_static_string(root2, "version_suffix", "");

	root3 = fake_sysctl_add_node(&ctx3, &fake_hw, "nvidia3", 0, "test");
	nv_version_sysctl_init(&ctx3, root3, suffixed, &st3);
	expect_static_string(root3, "version_string", "1.2.3-rc1");
	expect_static_int(root3, "version_major", 1);
	expect_static_int(root3, "version_minor", 2);
	expect_static_int(root3, "version_patch", 3);
	expect_static_int(root3, "version_available", 1);
	expect_static_string(root3, "version_suffix", "-rc1");

	/* The first caller's leaves still read its own banner. */
	expect_static_string(root1, "version_string", "580.178.04");
	expect_static_int(root1, "version_major", 580);
	expect_static_int(root1, "version_minor", 178);
	expect_static_int(root1, "version_patch", 4);
	expect_static_int(root1, "version_available", 1);
	expect_static_string(root1, "version_suffix", "");
	expect_static_int(root2, "version_available", 0);
}

#ifndef NV_VERSION_SYSCTL_MODESET
static void
expect_description(struct sysctl_oid *parent, const char *name,
    const char *word)
{
	struct sysctl_oid *oid = need_oid(parent, name);

	if (oid != NULL)
		check_true(oid->description != NULL &&
		    strstr(oid->description, word) != NULL,
		    "sysctl description names the part encoding");
}

struct vbios_want {
	int major, minor, patch, build, revision, available;
	const char *suffix;
};

static void
expect_vbios(struct sysctl_oid *gpu, nv_state_t *nv,
    const struct vbios_want *want)
{
	expect_proc_int(gpu, "vbios_major", nv, want->major);
	expect_proc_int(gpu, "vbios_minor", nv, want->minor);
	expect_proc_int(gpu, "vbios_patch", nv, want->patch);
	expect_proc_int(gpu, "vbios_build", nv, want->build);
	expect_proc_int(gpu, "vbios_revision", nv, want->revision);
	expect_proc_int(gpu, "vbios_available", nv, want->available);
	expect_proc_string(gpu, "vbios_suffix", nv, want->suffix);
}

static void
expect_firmware(struct sysctl_oid *gpu, nv_state_t *nv, int major, int minor,
    int patch, int available, const char *suffix)
{
	expect_proc_int(gpu, "firmware_major", nv, major);
	expect_proc_int(gpu, "firmware_minor", nv, minor);
	expect_proc_int(gpu, "firmware_patch", nv, patch);
	expect_proc_int(gpu, "firmware_available", nv, available);
	expect_proc_string(gpu, "firmware_suffix", nv, suffix);
}

static int
call_handler(struct sysctl_oid *oid, nv_state_t *nv, int arg2)
{
	struct sysctl_req req;
	int value = -1;

	memset(&req, 0, sizeof(req));
	req.oldptr = &value;
	req.oldlen = sizeof(value);
	return (oid->handler(oid, nv, arg2, &req));
}

/* Fill the stack below the caller with a string pattern RM did not write. */
static void __attribute__((noinline))
poison_stack(void)
{
	volatile char junk[4096];
	size_t i;

	for (i = 0; i < sizeof(junk); i++)
		junk[i] = (i % 16 == 15) ? '\0' : '7';
}

static int
read_int(struct sysctl_oid *gpu, const char *name, nv_state_t *nv)
{
	struct sysctl_oid *oid = need_oid(gpu, name);
	struct sysctl_req req;
	int value = -1;

	if (oid == NULL)
		return (-1);
	memset(&req, 0, sizeof(req));
	req.oldptr = &value;
	req.oldlen = sizeof(value);
	check_int_value(name, oid->handler(oid, nv, oid->arg2, &req), 0);
	return (value);
}

/*
 * Each read fetches the value anew (documented in nvidia(4)): reading a part
 * and then the availability flag can straddle the GPU's initialization, and
 * the documented recipes (read the string sysctl, or re-read the flag after
 * the parts) are the way to get a consistent set.
 */
static void
test_fetch_per_read(struct sysctl_oid *gpu, nv_state_t *nv)
{
	int fetches, major, available;

	strlcpy(fake_vbios, "??.??.??.??.??", sizeof(fake_vbios));
	fetches = vbios_fetches;
	major = read_int(gpu, "vbios_major", nv);
	check_int_value("one fetch per part read", vbios_fetches - fetches, 1);
	strlcpy(fake_vbios, "96.06.1e.00.4a", sizeof(fake_vbios));
	available = read_int(gpu, "vbios_available", nv);
	check_int_value("one fetch per available read",
	    vbios_fetches - fetches, 2);
	check_int_value("part read before the GPU was ready", major, 0);
	check_int_value("available read after the GPU became ready",
	    available, 1);
	/* The documented retry: read the flag again after the parts. */
	major = read_int(gpu, "vbios_major", nv);
	available = read_int(gpu, "vbios_available", nv);
	check_int_value("retried part", major, 150);
	check_int_value("retried available", available, 1);

	fetches = firmware_fetches;
	strlcpy(fake_firmware, "580.178.04", sizeof(fake_firmware));
	(void)read_int(gpu, "firmware_minor", nv);
	(void)read_int(gpu, "firmware_available", nv);
	check_int_value("firmware fetches per read",
	    firmware_fetches - fetches, 2);
}

static void
test_gpu_versions_and_identity(void)
{
	struct sysctl_ctx_list ctx;
	struct nvidia_softc sc;
	struct fake_device dev;
	nv_state_t nv;
	struct sysctl_oid *gpu, *oid;
	struct sysctl_req req;
	int uuid_frees_before;

	memset(&sc, 0, sizeof(sc));
	memset(&dev, 0, sizeof(dev));
	memset(&nv, 0, sizeof(nv));
	dev.tree = fake_sysctl_add_node(&ctx, NULL, "dev.nvidia.1", 0, "test");
	sc.dev = &dev;
	nv.os_state = &sc;
	nv.pci_info.domain = 13;
	nv.pci_info.bus = 1;
	nv.pci_info.slot = 0;
	nv.pci_info.function = 0;
	gpu = fake_sysctl_add_node(&ctx, NULL, "gpus.1", 0, "test");
	nv_version_sysctl_gpu_init(&nv, gpu);

	strlcpy(fake_vbios, "96.06.1e.00.4a", sizeof(fake_vbios));
	expect_vbios(gpu, &nv, &(struct vbios_want){ 150, 6, 30, 0, 74, 1, "" });
	expect_description(gpu, "vbios_major", "hex");
	expect_description(gpu, "vbios_revision", "hex");
	expect_description(gpu, "firmware_major", "decimal");

	strlcpy(fake_vbios, "96.06.1e-b1", sizeof(fake_vbios));
	expect_vbios(gpu, &nv, &(struct vbios_want){ 150, 6, 30, 0, 0, 1, "-b1" });

	strlcpy(fake_vbios, "??.??.??.??.??", sizeof(fake_vbios));
	expect_vbios(gpu, &nv, &(struct vbios_want){ 0, 0, 0, 0, 0, 0, "" });

	strlcpy(fake_firmware, "580.178.04", sizeof(fake_firmware));
	expect_firmware(gpu, &nv, 580, 178, 4, 1, "");

	strlcpy(fake_firmware, "580.178.04-beta", sizeof(fake_firmware));
	expect_firmware(gpu, &nv, 580, 178, 4, 1, "-beta");

	strlcpy(fake_firmware, "N/A", sizeof(fake_firmware));
	expect_firmware(gpu, &nv, 0, 0, 0, 0, "");

	/* RM writes nothing: no stale stack bytes may be read as a version. */
	vbios_nowrite = 1;
	oid = need_oid(gpu, "vbios_major");
	if (oid != NULL) {
		int value = -1;

		memset(&req, 0, sizeof(req));
		req.oldptr = &value;
		req.oldlen = sizeof(value);
		poison_stack();
		check_int_value("vbios_major without RM output",
		    oid->handler(oid, &nv, oid->arg2, &req), 0);
		check_int_value("vbios_major without RM output value", value, 0);
	}
	vbios_nowrite = 0;

	/* arg2 outside the selectors is refused. */
	oid = need_oid(gpu, "vbios_major");
	if (oid != NULL) {
		strlcpy(fake_vbios, "96.06.1e.00.4a", sizeof(fake_vbios));
		check_int_value("arg2 -1", call_handler(oid, &nv, -1), EINVAL);
		check_int_value("arg2 past the selectors",
		    call_handler(oid, &nv, 99), EINVAL);
	}

	test_fetch_per_read(gpu, &nv);

	strlcpy(fake_uuid, "GPU-17743da2-61b3-ef41-e46e-5679f4ed15ec",
	    sizeof(fake_uuid));
	expect_oid_context(dev.tree, "uuid", &sc.sysctl_ctx);
	expect_oid_context(dev.tree, "pci_bus_id", &sc.sysctl_ctx);
	uuid_frees_before = uuid_frees;
	expect_proc_string(dev.tree, "uuid", &nv, fake_uuid);
	check_int_value("uuid free count", uuid_frees - uuid_frees_before, 1);
	expect_proc_string(dev.tree, "pci_bus_id", &nv, "000d:01:00.0");

	/* A failed UUID fetch reports EIO and frees nothing. */
	uuid_null = 1;
	oid = need_oid(dev.tree, "uuid");
	if (oid != NULL) {
		uuid_frees_before = uuid_frees;
		check_int_value("uuid EIO", call_handler(oid, &nv, 0), EIO);
		check_int_value("uuid EIO frees nothing",
		    uuid_frees - uuid_frees_before, 0);
	}
	uuid_null = 0;

	/* The widest domain and bus fields print in full. */
	nv.pci_info.domain = 0xffffffffu;
	nv.pci_info.bus = 0xff;
	nv.pci_info.slot = 0x1f;
	nv.pci_info.function = 7;
	expect_proc_string(dev.tree, "pci_bus_id", &nv, "ffffffff:ff:1f.7");
	nv.pci_info.domain = 0x10000;
	nv.pci_info.bus = 1;
	nv.pci_info.slot = 0;
	nv.pci_info.function = 0;
	expect_proc_string(dev.tree, "pci_bus_id", &nv, "10000:01:00.0");

	check_int_value("stack balance", stack_outstanding, 0);
}
#endif /* !NV_VERSION_SYSCTL_MODESET */

#ifdef NV_VERSION_SYSCTL_MODESET
static void
test_modeset_version(void)
{
	struct sysctl_oid *root;
	unsigned before;

	nv_version_sysctl_modeset_init("580.178.04");
	root = find_oid(&fake_hw, "nvidiamodeset");
	check_true(root != NULL, "hw.nvidiamodeset node");
	if (root != NULL) {
		expect_static_string(root, "version", "580.178.04");
		expect_static_string(root, "version_string", "580.178.04");
		expect_static_int(root, "version_major", 580);
		expect_static_int(root, "version_minor", 178);
		expect_static_int(root, "version_patch", 4);
		expect_static_int(root, "version_available", 1);
		expect_static_string(root, "version_suffix", "");
	}
	nv_version_sysctl_modeset_exit();

	/* A parent node that cannot be created registers nothing under NULL. */
	fail_node = "nvidiamodeset";
	before = noids;
	nv_version_sysctl_modeset_init("580.178.04");
	fail_node = NULL;
	check_int_value("no sysctl added without the parent node",
	    (int)(noids - before), 0);
	check_int_value("no child registered under a NULL parent",
	    null_parent_use, 0);
	nv_version_sysctl_modeset_exit();
}
#endif /* NV_VERSION_SYSCTL_MODESET */

int
main(void)
{
	test_driver_versions();
#ifdef NV_VERSION_SYSCTL_MODESET
	test_modeset_version();
#else
	test_gpu_versions_and_identity();
#endif
	if (failures != 0) {
		printf("version_sysctl_test: FAIL (checks %d, failures %d)\n",
		    checks, failures);
		return (1);
	}
	printf("version_sysctl_test: PASS (checks %d)\n", checks);
	return (0);
}

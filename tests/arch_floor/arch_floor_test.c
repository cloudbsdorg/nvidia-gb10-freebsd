/*
 * Behavioural test of src/gb10-archfloor/nv_arch_floor.c against the fake
 * kernel interfaces of fake_kpi.h.  Built three times by
 * tests/arch_floor_test.sh: with the machine architecture of <machine/param.h>
 * (the default), with "amd64" and with "aarch64".
 */
#include <sys/param.h>
#include <sys/systm.h>
#include <sys/bus.h>
#include <sys/sysctl.h>

#include "nv_arch_floor.h"

struct _device *fake_devices[128];
int fake_ndevices;
int fake_mutex_held;
int fake_failures;
int fake_log_count;
char fake_log[64][512];
int fake_malloc_outstanding;
struct malloc_type fake_m_temp;

static int checks;
static int test_failures;

void
fake_fail(const char *what)
{
	fake_failures++;
	printf("FAIL fake KPI: %s\n", what);
}

static void
check_true(int condition, const char *what)
{
	checks++;
	if (!condition) {
		test_failures++;
		printf("FAIL %s\n", what);
	}
}

static void
check_int(const char *what, long got, long want)
{
	checks++;
	if (got != want) {
		test_failures++;
		printf("FAIL %s: got %ld, want %ld\n", what, got, want);
	}
}

static void
check_str(const char *what, const char *got, const char *want)
{
	checks++;
	if (got == NULL) {
		test_failures++;
		printf("FAIL %s: got NULL, want <%s>\n", what, want);
		return;
	}
	if (strcmp(got, want) != 0) {
		test_failures++;
		printf("FAIL %s: got <%s>, want <%s>\n", what, got, want);
	}
}

static void
check_has(const char *what, const char *got, const char *want)
{
	checks++;
	if (got == NULL || strstr(got, want) == NULL) {
		test_failures++;
		printf("FAIL %s: <%s> does not contain <%s>\n", what,
		    got != NULL ? got : "(null)", want);
	}
}

/* --- fake KPI --- */

static struct _device *
find_by_pa(uintptr_t pa)
{
	int i;

	for (i = 0; i < fake_ndevices; i++)
		if ((uintptr_t)fake_devices[i]->page == pa)
			return (fake_devices[i]);
	return (NULL);
}

static void
sleep_check(const char *what)
{
	if (fake_mutex_held)
		fake_fail(what);
}

struct resource *
fake_bus_alloc_resource_any(device_t dev, int type, int *rid, u_int flags)
{
	sleep_check("bus_alloc_resource_any under a mutex");
	dev->touched = 1;
	dev->alloc_flags = (int)flags;
	dev->alloc_rid = *rid;
	if (type != SYS_RES_MEMORY)
		fake_fail("allocation of a non-memory resource");
	if (dev->alloc_fails)
		return (NULL);
	dev->allocs++;
	dev->live_res++;
	dev->res.start = (rman_res_t)(uintptr_t)dev->page;
	return (&dev->res);
}

int
fake_bus_release_resource(device_t dev, int type, int rid, struct resource *r)
{
	sleep_check("bus_release_resource under a mutex");
	if (type != SYS_RES_MEMORY || r != &dev->res || dev->live_res <= 0)
		fake_fail("bad bus_release_resource");
	dev->release_rid = rid;
	dev->releases++;
	dev->live_res--;
	return (0);
}

uint32_t
fake_pci_read_config(device_t dev, int reg, int width)
{
	if (reg != PCIR_COMMAND || width != 2)
		fake_fail("pci_read_config of something but the command register");
	return (dev->command);
}

void
fake_pci_enable_io(device_t dev, int space)
{
	if (space != SYS_RES_MEMORY)
		fake_fail("pci_enable_io of a non-memory space");
	dev->enables++;
	dev->command |= PCIM_CMD_MEMEN;
}

void
fake_pci_disable_io(device_t dev, int space)
{
	if (space != SYS_RES_MEMORY)
		fake_fail("pci_disable_io of a non-memory space");
	dev->disables++;
	dev->command &= (uint16_t)~PCIM_CMD_MEMEN;
}

void *
fake_pmap_mapdev(uintptr_t pa, size_t len)
{
	struct _device *dev = find_by_pa(pa);

	if (dev == NULL || dev->live_res <= 0) {
		fake_fail("pmap_mapdev of an address that is not an allocated BAR");
		return (NULL);
	}
	dev->maps++;
	dev->live_map++;
	dev->map_len = len;
	/* real hardware answers all ones while memory decode is off */
	return ((dev->command & PCIM_CMD_MEMEN) ? (void *)dev->page :
	    (void *)dev->ones);
}

void
fake_pmap_unmapdev(void *va, size_t len)
{
	int i;

	for (i = 0; i < fake_ndevices; i++) {
		struct _device *dev = fake_devices[i];

		if (va == (void *)dev->page || va == (void *)dev->ones) {
			dev->unmaps++;
			dev->live_map--;
			dev->unmap_len = len;
			return;
		}
	}
	fake_fail("pmap_unmapdev of an unknown mapping");
}

int
fake_device_printf(device_t dev, const char *fmt, ...)
{
	va_list ap;
	char buf[400];
	int n;

	va_start(ap, fmt);
	n = vsnprintf(buf, sizeof(buf), fmt, ap);
	va_end(ap);
	if (fake_log_count >= 64) {
		fake_fail("log capacity");
		return (0);
	}
	/* the kernel prints the name unit of the device it is given */
	snprintf(fake_log[fake_log_count], sizeof(fake_log[0]), "%s: %s",
	    dev->nameunit, buf);
	fake_log_count++;
	return (n);
}

void
fake_mtx_lock(struct mtx *m)
{
	if (m->locked)
		fake_fail("recursive mtx_lock");
	m->locked = 1;
	fake_mutex_held++;
}

void
fake_mtx_unlock(struct mtx *m)
{
	if (!m->locked)
		fake_fail("mtx_unlock of an unlocked mutex");
	m->locked = 0;
	fake_mutex_held--;
}

void *
fake_malloc(size_t size, struct malloc_type *type, int flags)
{
	(void)type;
	sleep_check("malloc under a mutex");
	if (!(flags & M_WAITOK))
		fake_fail("malloc without M_WAITOK");
	fake_malloc_outstanding++;
	return (calloc(1, size));
}

void
fake_free(void *p, struct malloc_type *type)
{
	(void)type;
	fake_malloc_outstanding--;
	(free)(p);
}

#define MAX_OIDS 16
static struct sysctl_oid oids[MAX_OIDS];
static int noids;

static struct sysctl_oid *
new_oid(const char *name, int kind, int flags)
{
	struct sysctl_oid *oid;

	if (noids >= MAX_OIDS) {
		fake_fail("sysctl capacity");
		return (&oids[0]);
	}
	oid = &oids[noids++];
	memset(oid, 0, sizeof(*oid));
	oid->name = name;
	oid->kind = kind;
	oid->flags = flags;
	return (oid);
}

struct sysctl_oid *
fake_add_int(struct sysctl_oid *parent, const char *name, int flags, int *ptr)
{
	struct sysctl_oid *oid = new_oid(name, 1, flags);

	(void)parent;
	oid->int_ptr = ptr;
	return (oid);
}

struct sysctl_oid *
fake_add_string(struct sysctl_oid *parent, const char *name, int flags,
    char *ptr)
{
	struct sysctl_oid *oid = new_oid(name, 2, flags);

	(void)parent;
	oid->str_ptr = ptr;
	return (oid);
}

struct sysctl_oid *
fake_add_proc(struct sysctl_oid *parent, const char *name, int flags,
    fake_handler handler, const char *fmt)
{
	struct sysctl_oid *oid = new_oid(name, 3, flags);

	(void)parent;
	oid->handler = handler;
	oid->fmt = fmt;
	return (oid);
}

int
fake_sysctl_out(struct sysctl_req *req, const void *ptr, size_t len)
{
	sleep_check("SYSCTL_OUT under a mutex");
	if (req->outlen + len > sizeof(req->out)) {
		fake_fail("sysctl output capacity");
		return (ENOMEM);
	}
	memcpy(req->out + req->outlen, ptr, len);
	req->outlen += len;
	return (0);
}

/* --- test helpers --- */

static struct _device pool[64];
static int npool;

/* the parents: the PCI devices the driver sits on */
static struct _device parents[64];
static int nparents;

static struct _device *
make_dev(uint16_t vendor, uint16_t device_id, int bus, int slot, int function,
    uint32_t boot_0, uint32_t boot_42, uint16_t command)
{
	struct _device *dev, *parent;

	if (npool >= (int)(sizeof(pool) / sizeof(pool[0])) ||
	    nparents >= (int)(sizeof(parents) / sizeof(parents[0]))) {
		printf("FAIL device pool exhausted\n");
		exit(2);
	}
	dev = &pool[npool++];
	memset(dev, 0, sizeof(*dev));
	dev->vendor = vendor;
	dev->device_id = device_id;
	dev->bus = bus;
	dev->slot = slot;
	dev->function = function;
	dev->command = command;
	dev->command_initial = command;
	/* the register offsets are written out: the header is under test */
	dev->page[0x000 / 4] = boot_0;
	dev->page[0xA00 / 4] = boot_42;
	memset(dev->ones, 0xff, sizeof(dev->ones));
	/* the parent: the PCI device, with the name pciconf gives it */
	parent = &parents[nparents++];
	memset(parent, 0, sizeof(*parent));
	snprintf(parent->nameunit, sizeof(parent->nameunit), "vgapci%d",
	    nparents);
	dev->parent = parent;
	fake_devices[fake_ndevices++] = dev;
	return (dev);
}

/* The name of the PCI device the driver sits on: "vgapci1". */
static const char *
parent_name(struct _device *dev)
{
	if (dev->parent == NULL)
		return ("");
	return (dev->parent->nameunit);
}

#define BOOT42(arch, impl) \
	((uint32_t)(((arch) << 24) | ((impl) << 20) | 0x000a1000))

static int
probe(struct _device *dev, const char *name)
{
	return (nv_arch_floor_probe(dev, name));
}

/* Nothing the probe took may be left behind, whatever the verdict. */
static void
check_hygiene(const char *what, struct _device *dev, int expect_alloc_tried)
{
	char msg[160];

#define HY(text) (snprintf(msg, sizeof(msg), "%s: %s", what, text), msg)
	check_int(HY("allocations released"), dev->allocs, dev->releases);
	check_int(HY("no live resource"), dev->live_res, 0);
	check_int(HY("mappings unmapped"), dev->maps, dev->unmaps);
	check_int(HY("no live mapping"), dev->live_map, 0);
	check_int(HY("memory decode as before"), dev->command,
	    dev->command_initial);
	check_int(HY("mutex not held"), fake_mutex_held, 0);
	check_int(HY("no outstanding malloc"), fake_malloc_outstanding, 0);
	if (expect_alloc_tried) {
		check_int(HY("allocation flags are 0"), dev->alloc_flags, 0);
		check_int(HY("allocation rid is BAR0"), dev->alloc_rid,
		    PCIR_BAR(0));
		if (dev->allocs > 0) {
			check_int(HY("release rid is BAR0"), dev->release_rid,
			    PCIR_BAR(0));
			check_int(HY("mapped length is PAGE_SIZE"),
			    (long)dev->map_len, PAGE_SIZE);
			check_int(HY("unmapped length is PAGE_SIZE"),
			    (long)dev->unmap_len, PAGE_SIZE);
			check_int(HY("one mapping per allocation"), dev->maps,
			    dev->allocs);
		}
	} else {
		check_int(HY("not touched"), dev->touched, 0);
		check_int(HY("no mapping"), dev->maps, 0);
		check_int(HY("no decode change"),
		    dev->enables + dev->disables, 0);
	}
#undef HY
}

static struct sysctl_oid *
find_oid(const char *name)
{
	int i;

	for (i = 0; i < noids; i++)
		if (strcmp(oids[i].name, name) == 0)
			return (&oids[i]);
	return (NULL);
}

static int
get_int(const char *name)
{
	struct sysctl_oid *oid = find_oid(name);

	if (oid == NULL || oid->kind != 1) {
		test_failures++;
		printf("FAIL sysctl %s is not an int\n", name);
		return (-1);
	}
	return (*oid->int_ptr);
}

static const char *
get_string(const char *name)
{
	struct sysctl_oid *oid = find_oid(name);

	if (oid == NULL || oid->kind != 2) {
		test_failures++;
		printf("FAIL sysctl %s is not a string\n", name);
		return ("");
	}
	return (oid->str_ptr);
}

static const char *
get_refused(void)
{
	static struct sysctl_req req;
	struct sysctl_oid *oid = find_oid("refused");

	memset(&req, 0, sizeof(req));
	if (oid == NULL || oid->kind != 3 || oid->handler == NULL) {
		test_failures++;
		printf("FAIL sysctl refused is not a handler\n");
		return ("");
	}
	check_int("refused handler returns 0",
	    oid->handler(oid, NULL, 0, &req), 0);
	check_true(req.outlen > 0 && req.out[req.outlen - 1] == '\0',
	    "refused output is NUL terminated");
	return (req.out);
}

/* The line of the refused list that names LOCATION, or an empty string. */
static const char *
refused_line(const char *location)
{
	static char line[512];
	const char *all, *s, *end;

	all = get_refused();
	if (all == NULL || *all == '\0')
		return ("");
	s = strstr(all, location);
	if (s == NULL || (s != all && s[-1] != '\n'))
		return ("");
	end = strchr(s, '\n');
	if (end == NULL)
		end = s + strlen(s);
	snprintf(line, sizeof(line), "%.*s", (int)(end - s), s);
	return (line);
}

static int
count_lines(const char *s)
{
	int n = *s ? 1 : 0;

	for (; *s; s++)
		if (*s == '\n')
			n++;
	return (n);
}

/* Whether S ends with SUFFIX. */
static int
ends_with(const char *s, const char *suffix)
{
	size_t ls = strlen(s), lx = strlen(suffix);

	return (ls >= lx && strcmp(s + ls - lx, suffix) == 0);
}

static const char *
last_log(void)
{
	return (fake_log_count > 0 ? fake_log[fake_log_count - 1] : "");
}

#define FLOOR_TAIL "this driver supports Ampere (RTX 30) and later"

/* --- tests --- */

static void
test_pure_decide(void)
{
	struct nv_arch_floor_decision d;
	unsigned arch;

	for (arch = 0; arch < 0x40; arch++) {
		char what[64];

		nv_arch_floor_decide(0x170000a1, BOOT42(arch, 2), &d);
		snprintf(what, sizeof(what), "architecture 0x%02x value", arch);
		check_int(what, d.architecture, arch);
		snprintf(what, sizeof(what), "architecture 0x%02x impl", arch);
		check_int(what, d.implementation, 2);
		snprintf(what, sizeof(what), "architecture 0x%02x floor", arch);
		if (arch < 0x17)
			check_int(what, d.verdict, NV_ARCH_FLOOR_BELOW_FLOOR);
		else if (arch <= 0x1b)
			check_true(d.verdict == NV_ARCH_FLOOR_ACCEPT, what);
		else
			check_int(what, d.verdict, NV_ARCH_FLOOR_UNKNOWN);
	}
	nv_arch_floor_decide(0, BOOT42(0x16, 4), &d);
	check_str("Turing name", d.architecture_name, "Turing");
	nv_arch_floor_decide(0, BOOT42(0x0e, 4), &d);
	check_true(d.architecture_name == NULL, "unnamed older has no name");
	check_int("unnamed older is below the floor", d.verdict,
	    NV_ARCH_FLOOR_BELOW_FLOOR);
	nv_arch_floor_decide(NV_ARCH_FLOOR_ALL_ONES, NV_ARCH_FLOOR_ALL_ONES, &d);
	check_int("all ones", d.verdict, NV_ARCH_FLOOR_NOT_RESPONDING);
	nv_arch_floor_decide(0x170000a1, NV_ARCH_FLOOR_ALL_ONES, &d);
	check_int("only BOOT_42 all ones is unknown", d.verdict,
	    NV_ARCH_FLOOR_UNKNOWN);
	nv_arch_floor_decide(NV_ARCH_FLOOR_ALL_ONES, BOOT42(0x17, 2), &d);
	check_true(d.verdict == NV_ARCH_FLOOR_ACCEPT,
	    "only BOOT_0 all ones with a valid BOOT_42 is accepted");
	nv_arch_floor_decide(0, BOOT42(0x17, 0), &d);
	if (strcmp(NV_ARCH_FLOOR_MACHINE, "amd64") == 0) {
		check_true(d.verdict == NV_ARCH_FLOOR_ACCEPT,
		    "GA100 with the image is accepted");
	} else {
		check_int("GA100 without the image", d.verdict,
		    NV_ARCH_FLOOR_NO_FIRMWARE);
		check_str("missing image", d.missing_image, "gsp_tu10x");
		check_str("missing image chip", d.chip, "GA100");
		check_str("missing image machines", d.machines, "amd64");
	}
	nv_arch_floor_decide(0, BOOT42(0x17, 2), &d);
	check_true(d.verdict == NV_ARCH_FLOOR_ACCEPT && d.missing_image == NULL,
	    "GA102 needs no image this build lacks");
	check_str("keyword accept",
	    nv_arch_floor_keyword(NV_ARCH_FLOOR_ACCEPT), "accept");
	check_str("keyword below-floor",
	    nv_arch_floor_keyword(NV_ARCH_FLOOR_BELOW_FLOOR), "below-floor");
	check_str("keyword unknown",
	    nv_arch_floor_keyword(NV_ARCH_FLOOR_UNKNOWN), "unknown");
	check_str("keyword no-firmware",
	    nv_arch_floor_keyword(NV_ARCH_FLOOR_NO_FIRMWARE), "no-firmware");
	check_str("keyword not-responding",
	    nv_arch_floor_keyword(NV_ARCH_FLOOR_NOT_RESPONDING),
	    "not-responding");
	check_str("keyword unreadable",
	    nv_arch_floor_keyword(NV_ARCH_FLOOR_UNREADABLE), "unreadable");
}

static void
test_pure_format(void)
{
	struct nv_arch_floor_decision d;
	char buf[NV_ARCH_FLOOR_LINE_SIZE];
	char small[24];
	char guarded[40];

	nv_arch_floor_decide(0, BOOT42(0x16, 4), &d);
	nv_arch_floor_format(&d, "NVIDIA GeForce RTX 2070 SUPER", 0x1e84, buf,
	    sizeof(buf));
	check_str("format Turing", buf,
	    "NVIDIA GeForce RTX 2070 SUPER (0x1e84) is Turing; " FLOOR_TAIL);
	nv_arch_floor_decide(0, BOOT42(0x0e, 4), &d);
	nv_arch_floor_format(&d, "NVIDIA GeForce GT 710", 0x0fc6, buf,
	    sizeof(buf));
	check_str("format unnamed older", buf,
	    "NVIDIA GeForce GT 710 (0x0fc6) is architecture 0x0e, older than "
	    "Ampere; " FLOOR_TAIL);
	nv_arch_floor_decide(0, BOOT42(0x1f, 0), &d);
	nv_arch_floor_format(&d, "NVIDIA Future", 0x9999, buf, sizeof(buf));
	check_str("format unknown", buf,
	    "NVIDIA Future (0x9999) reports unknown architecture 0x1f; "
	    FLOOR_TAIL);
	memset(&d, 0, sizeof(d));
	d.verdict = NV_ARCH_FLOOR_NO_FIRMWARE;
	d.architecture = 0x17;
	d.architecture_name = "Ampere";
	d.chip = "GA100";
	d.missing_image = "gsp_tu10x";
	d.machines = "amd64";
	nv_arch_floor_format(&d, "NVIDIA A100-SXM4-40GB", 0x20b0, buf,
	    sizeof(buf));
	check_str("format no firmware", buf,
	    "NVIDIA A100-SXM4-40GB (0x20b0) is Ampere GA100, which needs the "
	    "gsp_tu10x firmware; only the amd64 build carries it");
	nv_arch_floor_decide(NV_ARCH_FLOOR_ALL_ONES, NV_ARCH_FLOOR_ALL_ONES, &d);
	nv_arch_floor_format(&d, "NVIDIA GeForce RTX 3060", 0x2504, buf,
	    sizeof(buf));
	check_str("format not responding", buf,
	    "NVIDIA GeForce RTX 3060 (0x2504) does not respond (PMC_BOOT_0 and "
	    "PMC_BOOT_42 read 0xffffffff); not attaching");
	memset(&d, 0, sizeof(d));
	d.verdict = NV_ARCH_FLOOR_UNREADABLE;
	nv_arch_floor_format(&d, NULL, 0x2504, buf, sizeof(buf));
	check_str("format unreadable, NULL name", buf,
	    "NVIDIA GPU (0x2504): cannot read PMC_BOOT_42 (BAR0 not available); "
	    "not attaching");

	nv_arch_floor_decide(0, BOOT42(0x16, 4), &d);
	memset(guarded, 'X', sizeof(guarded));
	nv_arch_floor_format(&d, "NVIDIA GeForce RTX 2070 SUPER", 0x1e84,
	    guarded, 16);
	check_int("truncated output is NUL terminated", guarded[15], 0);
	check_int("truncation does not write past len", guarded[16], 'X');
	memset(guarded, 'X', sizeof(guarded));
	nv_arch_floor_format(&d, "x", 1, guarded, 0);
	check_int("len 0 writes nothing", guarded[0], 'X');
	nv_arch_floor_format(&d, "NVIDIA GeForce RTX 2070 SUPER", 0x1e84, small,
	    sizeof(small));
	check_int("small buffer terminated", (int)strlen(small),
	    (int)sizeof(small) - 1);
	check_true(strchr(buf, '\n') == NULL, "no newline in a line");
}

static void
test_accept(const char *label, uint16_t id, uint32_t boot_42, int bus)
{
	struct _device *dev;
	char what[96];
	int before = fake_log_count;

	dev = make_dev(0x10de, id, bus, 0, 0, 0x170000a1, boot_42,
	    PCIM_CMD_MEMEN);
	snprintf(what, sizeof(what), "%s accepted", label);
	check_int(what, probe(dev, "NVIDIA test GPU"), 0);
	snprintf(what, sizeof(what), "%s: nothing logged", label);
	check_int(what, fake_log_count, before);
	check_hygiene(label, dev, 1);
	dev = make_dev(0x10de, id, bus, 1, 0, 0x170000a1, boot_42, 0);
	snprintf(what, sizeof(what), "%s accepted with decode off", label);
	check_int(what, probe(dev, "NVIDIA test GPU"), 0);
	check_hygiene(what, dev, 1);
	check_int(what, dev->enables, 1);
	check_int(what, dev->disables, 1);
}

/*
 * The refused list at its worst case: every one of the 16 entries as long
 * as the fields allow, so the buffer the list is written into has to hold
 * all of it.  The accounting of that buffer reserves
 * NV_ARCH_FLOOR_LOCATION_SIZE bytes for the location,
 * NV_ARCH_FLOOR_NAME_SIZE for the parent and NV_ARCH_FLOOR_LINE_SIZE for
 * the message, and not-responding is the longest keyword.  The fake's
 * location numbers and parent names are wider than the real ones, so a
 * line can fill every field: the real PCI bus and slot numbers are 8-bit
 * and never get that far, but the buffer has to hold what it can be given.
 */
static void
test_refused_buffer(void)
{
	struct nv_arch_floor_decision d;
	struct _device *dev[NV_ARCH_FLOOR_MAX_REFUSED];
	char name[256];
	char location[NV_ARCH_FLOOR_LOCATION_SIZE];
	char parent[NV_ARCH_FLOOR_NAME_SIZE];
	char message[NV_ARCH_FLOOR_LINE_SIZE];
	char want[512];
	const char *refused;
	int i, last, logs_before;

	last = NV_ARCH_FLOOR_MAX_REFUSED - 1;
	logs_before = fake_log_count;
	memset(name, 'N', sizeof(name) - 1);
	name[sizeof(name) - 1] = '\0';
	for (i = 0; i < NV_ARCH_FLOOR_MAX_REFUSED; i++) {
		dev[i] = make_dev(0x10de, 0x2504, -1, -1, -1,
		    NV_ARCH_FLOOR_ALL_ONES, NV_ARCH_FLOOR_ALL_ONES,
		    PCIM_CMD_MEMEN);
		/* a distinct location that fills the 32-byte buffer */
		dev[i]->domain = -1 - i;
		/* a parent name that fills the 16-byte buffer */
		snprintf(dev[i]->parent->nameunit,
		    sizeof(dev[i]->parent->nameunit), "vgapci%09d", i);
		check_int("the buffer test refuses", probe(dev[i], name), ENXIO);
		check_hygiene("the buffer test", dev[i], 1);
	}
	/* the last entry, as the driver wrote it */
	snprintf(location, sizeof(location), "pci%u:%u:%u:%u",
	    (unsigned)dev[last]->domain, (unsigned)dev[last]->bus,
	    (unsigned)dev[last]->slot, (unsigned)dev[last]->function);
	snprintf(parent, sizeof(parent), "%s", dev[last]->parent->nameunit);
	nv_arch_floor_decide(NV_ARCH_FLOOR_ALL_ONES, NV_ARCH_FLOOR_ALL_ONES, &d);
	nv_arch_floor_format(&d, name, 0x2504, message, sizeof(message));
	/* every field is full */
	check_int("the location fills its buffer", (int)strlen(location),
	    NV_ARCH_FLOOR_LOCATION_SIZE - 1);
	check_int("the parent fills its buffer", (int)strlen(parent),
	    NV_ARCH_FLOOR_NAME_SIZE - 1);
	check_int("the message fills its buffer", (int)strlen(message),
	    NV_ARCH_FLOOR_LINE_SIZE - 1);
	snprintf(want, sizeof(want), "%s %s 0x%04x %s %s", location, parent,
	    0x2504, "not-responding", message);
	refused = get_refused();
	check_int("the refused list holds every line", count_lines(refused),
	    NV_ARCH_FLOOR_MAX_REFUSED);
	check_int("the refused list holds every byte", (int)strlen(refused),
	    NV_ARCH_FLOOR_MAX_REFUSED * (int)strlen(want) +
	    NV_ARCH_FLOOR_MAX_REFUSED - 1);
	check_true(ends_with(refused, want),
	    "the last line of the refused list is truncated");
	/*
	 * The tables are global: let the devices attach again, so the tests
	 * that follow see an empty list.
	 */
	for (i = 0; i < NV_ARCH_FLOOR_MAX_REFUSED; i++) {
		dev[i]->page[0x000 / 4] = 0x170000a1;
		dev[i]->page[0xA00 / 4] = BOOT42(0x17, 2);
		check_int("the buffer test releases", probe(dev[i], name), 0);
	}
	fake_log_count = logs_before;
	check_int("the refused list is empty again", get_int("refused_count"),
	    0);
	check_str("the refused list is empty again", get_refused(), "");
}

static void
test_refusals(void)
{
	struct _device *dev;
	const char *refused;
	char want[512];
	int count;

	/* Turing TU104 */
	dev = make_dev(0x10de, 0x1e84, 3, 0, 0, 0x164000a1, BOOT42(0x16, 4),
	    PCIM_CMD_MEMEN);
	check_int("Turing refused", probe(dev, "NVIDIA GeForce RTX 2070 SUPER"),
	    ENXIO);
	check_int("Turing logged once", fake_log_count, 1);
	snprintf(want, sizeof(want),
	    "%s: nvidia: NVIDIA GeForce RTX 2070 SUPER (0x1e84) is Turing; "
	    FLOOR_TAIL "\n", parent_name(dev));
	check_str("Turing log line", last_log(), want);
	check_hygiene("Turing", dev, 1);
	check_int("refused_count 1", get_int("refused_count"), 1);
	refused = get_refused();
	snprintf(want, sizeof(want),
	    "pci0:3:0:0 %s 0x1e84 below-floor "
	    "NVIDIA GeForce RTX 2070 SUPER (0x1e84) is Turing; " FLOOR_TAIL,
	    parent_name(dev));
	check_str("refused one line", refused, want);

	/* the same location again: one log line, one entry */
	check_int("Turing refused again",
	    probe(dev, "NVIDIA GeForce RTX 2070 SUPER"), ENXIO);
	check_int("re-probe logs nothing new", fake_log_count, 1);
	check_int("re-probe counts once", get_int("refused_count"), 1);
	check_int("re-probe adds no line", count_lines(get_refused()), 1);
	check_hygiene("Turing re-probe", dev, 1);

	/* Pascal GP104 at another location */
	dev = make_dev(0x10de, 0x1b80, 4, 0, 0, 0x134000a1, BOOT42(0x13, 4),
	    PCIM_CMD_MEMEN);
	check_int("Pascal refused", probe(dev, "NVIDIA GeForce GTX 1080"), ENXIO);
	check_int("Pascal logged", fake_log_count, 2);
	check_has("Pascal line", last_log(),
	    "(0x1b80) is Pascal; " FLOOR_TAIL);
	check_int("two locations count two", get_int("refused_count"), 2);
	refused = get_refused();
	check_int("two lines", count_lines(refused), 2);
	snprintf(want, sizeof(want),
	    "\npci0:4:0:0 %s 0x1b80 below-floor "
	    "NVIDIA GeForce GTX 1080 (0x1b80)", parent_name(dev));
	check_has("second line", refused, want);

	/* AMODEL */
	dev = make_dev(0x10de, 0x7777, 5, 0, 0, 0x1f4000a1, BOOT42(0x1f, 0),
	    PCIM_CMD_MEMEN);
	check_int("AMODEL refused", probe(dev, NULL), ENXIO);
	check_has("AMODEL line", last_log(),
	    "NVIDIA GPU (0x7777) reports unknown architecture 0x1f");
	check_hygiene("AMODEL", dev, 1);
	check_has("AMODEL keyword", get_refused(), " 0x7777 unknown ");

	/* fallen off the bus */
	dev = make_dev(0x10de, 0x2504, 6, 0, 0, NV_ARCH_FLOOR_ALL_ONES,
	    NV_ARCH_FLOOR_ALL_ONES, PCIM_CMD_MEMEN);
	check_int("dead card refused", probe(dev, "NVIDIA GeForce RTX 3060"),
	    ENXIO);
	check_has("dead card line", last_log(), "does not respond");
	check_hygiene("dead card", dev, 1);
	check_has("dead card keyword", get_refused(), " 0x2504 not-responding ");

	/* accepted with decode off: the decode is given back */
	dev = make_dev(0x10de, 0x2504, 6, 1, 0, 0x170000a1, BOOT42(0x17, 2), 0);
	check_int("accepted with decode off first", probe(dev, "x"), 0);
	check_hygiene("decode off", dev, 1);
	check_int("decode off enabled decode", dev->enables, 1);
	check_int("decode off gave the decode back", dev->disables, 1);

	/* decode off and a dead card: all ones, and the decode is given back */
	dev = make_dev(0x10de, 0x2504, 6, 2, 0, NV_ARCH_FLOOR_ALL_ONES,
	    NV_ARCH_FLOOR_ALL_ONES, 0);
	check_int("dead card with decode off refused",
	    probe(dev, "NVIDIA GeForce RTX 3060"), ENXIO);
	check_has("dead card with decode off line", last_log(),
	    "does not respond");
	check_hygiene("dead card with decode off", dev, 1);
	check_int("dead card with decode off enabled decode", dev->enables,
	    1);
	check_int("dead card with decode off gave the decode back",
	    dev->disables, 1);

	/* BAR0 cannot be allocated */
	dev = make_dev(0x10de, 0x2504, 7, 0, 0, 0x170000a1, BOOT42(0x17, 2),
	    PCIM_CMD_MEMEN);
	dev->alloc_fails = 1;
	check_int("unreadable refused", probe(dev, "NVIDIA GeForce RTX 3060"),
	    ENXIO);
	check_has("unreadable line", last_log(),
	    "cannot read PMC_BOOT_42 (BAR0 not available); not attaching");
	check_int("unreadable took nothing", dev->allocs, 0);
	check_int("unreadable mapped nothing", dev->maps, 0);
	check_int("unreadable changed no decode", dev->enables + dev->disables,
	    0);
	check_int("unreadable memory decode as before", dev->command,
	    dev->command_initial);
	check_has("unreadable keyword", get_refused(), " 0x2504 unreadable ");

	/* a device of another vendor: nothing at all */
	count = fake_log_count;
	dev = make_dev(0x1002, 0x7480, 8, 0, 0, 0x164000a1, BOOT42(0x16, 4),
	    PCIM_CMD_MEMEN);
	check_int("non-NVIDIA refused", probe(dev, "AMD Radeon"), ENXIO);
	check_int("non-NVIDIA logs nothing", fake_log_count, count);
	check_hygiene("non-NVIDIA", dev, 0);
	check_true(strstr(get_refused(), "pci0:8:0:0") == NULL,
	    "non-NVIDIA is not recorded");
}

static void
test_ga100(void)
{
	struct _device *dev = make_dev(0x10de, 0x20b0, 2, 0, 0, 0x170000a1,
	    BOOT42(0x17, 0), PCIM_CMD_MEMEN);
	char want[512];
	int before = get_int("refused_count");
	int rc = probe(dev, "NVIDIA A100-SXM4-40GB");

	check_hygiene("GA100", dev, 1);
	if (strcmp(NV_ARCH_FLOOR_MACHINE, "amd64") == 0) {
		check_int("GA100 accepted with the image", rc, 0);
		check_int("GA100 recorded nothing", get_int("refused_count"),
		    before);
	} else {
		check_int("GA100 refused without the image", rc, ENXIO);
		check_has("GA100 line", last_log(),
		    "(0x20b0) is Ampere GA100, which needs the gsp_tu10x "
		    "firmware; only the amd64 build carries it");
		snprintf(want, sizeof(want), "pci0:2:0:0 %s 0x20b0 no-firmware ",
		    parent_name(dev));
		check_has("GA100 keyword", get_refused(), want);
		check_int("GA100 counted", get_int("refused_count"), before + 1);
	}
}

static void
test_overflow(void)
{
	struct _device *dev, *seventeenth = NULL;
	int i, before_count, before_log;

	before_count = get_int("refused_count");
	before_log = fake_log_count;
	/* distinct locations on buses 16 and up */
	for (i = 0; i < NV_ARCH_FLOOR_MAX_REFUSED + 3; i++) {
		dev = make_dev(0x10de, 0x1e84, 16 + i, 0, 0, 0x164000a1,
		    BOOT42(0x16, 4), PCIM_CMD_MEMEN);
		if (i == NV_ARCH_FLOOR_MAX_REFUSED)
			seventeenth = dev;
		check_int("overflow device refused", probe(dev, "NVIDIA T"),
		    ENXIO);
		check_hygiene("overflow device", dev, 1);
	}
	check_int("every refusal logged", fake_log_count - before_log,
	    NV_ARCH_FLOOR_MAX_REFUSED + 3);
	check_int("overflow is counted", get_int("refused_count"),
	    before_count + NV_ARCH_FLOOR_MAX_REFUSED + 3);
	check_int("array is bounded", count_lines(get_refused()),
	    NV_ARCH_FLOOR_MAX_REFUSED);
	/* the 17th device did not fit the list: it is still counted and
	 * logged once, and a re-probe changes neither */
	check_int("the 17th device refused again",
	    probe(seventeenth, "NVIDIA T"), ENXIO);
	check_int("the 17th device logs nothing new", fake_log_count,
	    before_log + NV_ARCH_FLOOR_MAX_REFUSED + 3);
	check_int("the 17th device counts once", get_int("refused_count"),
	    before_count + NV_ARCH_FLOOR_MAX_REFUSED + 3);
}

/* The refused list follows the device: a refusal that is accepted later
 * leaves the list, and a re-probe with another verdict replaces it. */
static void
test_reprobe(void)
{
	struct _device *dev;
	const char *line;
	int before_count, before_log;

	/* refused as unreadable, then accepted: the entry is gone */
	dev = make_dev(0x10de, 0x2504, 40, 0, 0, 0x170000a1, BOOT42(0x17, 2),
	    PCIM_CMD_MEMEN);
	dev->alloc_fails = 1;
	before_count = get_int("refused_count");
	before_log = fake_log_count;
	check_int("unreadable refused", probe(dev, "NVIDIA GeForce RTX 3060"),
	    ENXIO);
	check_int("unreadable counted", get_int("refused_count"),
	    before_count + 1);
	check_has("unreadable listed", get_refused(), "pci0:40:0:0");
	dev->alloc_fails = 0;
	check_int("accepted after a refusal", probe(dev, "NVIDIA GeForce RTX 3060"),
	    0);
	check_int("the count goes down", get_int("refused_count"),
	    before_count);
	check_true(strstr(get_refused(), "pci0:40:0:0") == NULL,
	    "the accepted device is not listed any more");
	check_int("the accept logs nothing", fake_log_count, before_log + 1);

	/* refused as unreadable, then as Turing: the entry is replaced */
	dev = make_dev(0x10de, 0x1e84, 41, 0, 0, 0x164000a1, BOOT42(0x16, 4),
	    PCIM_CMD_MEMEN);
	dev->alloc_fails = 1;
	before_count = get_int("refused_count");
	before_log = fake_log_count;
	check_int("unreadable refused first",
	    probe(dev, "NVIDIA GeForce RTX 2070 SUPER"), ENXIO);
	check_int("unreadable counted first", get_int("refused_count"),
	    before_count + 1);
	dev->alloc_fails = 0;
	check_int("refused as Turing next",
	    probe(dev, "NVIDIA GeForce RTX 2070 SUPER"), ENXIO);
	check_int("the count does not change", get_int("refused_count"),
	    before_count + 1);
	check_int("the second verdict is logged", fake_log_count,
	    before_log + 2);
	line = refused_line("pci0:41:0:0");
	check_has("the line says below-floor", line, "below-floor");
	check_true(strstr(line, "unreadable") == NULL,
	    "the old verdict is gone");
}

static void
test_sysctls(void)
{
	check_int("min_architecture", get_int("min_architecture"), 23);
	check_str("min_architecture_name", get_string("min_architecture_name"),
	    "Ampere");
	check_true(find_oid("refused_count") != NULL, "refused_count exists");
	check_true(find_oid("refused") != NULL, "refused exists");
	{
		int i;

		for (i = 0; i < noids; i++) {
			check_true((oids[i].flags & CTLFLAG_RD) != 0 &&
			    (oids[i].flags & CTLFLAG_WR) == 0,
			    "every sysctl is read-only");
		}
	}
	check_true(find_oid("refused")->flags & CTLFLAG_MPSAFE,
	    "refused handler is MPSAFE");
	check_str("refused format", find_oid("refused")->fmt, "A");
}

int
main(void)
{
	struct sysctl_oid parent;
	struct sysctl_ctx_list ctx;

	setvbuf(stdout, NULL, _IOLBF, 0);
	memset(&parent, 0, sizeof(parent));
	nv_arch_floor_sysctl_init(&ctx, &parent);
	check_int("no refused devices at first", get_int("refused_count"), 0);
	check_str("refused is empty at first", get_refused(), "");

	test_pure_decide();
	test_pure_format();

	test_accept("GA102", 0x2204, BOOT42(0x17, 2), 1);
	test_accept("AD102", 0x2684, BOOT42(0x19, 2), 1);
	test_accept("GB206", 0x2d04, BOOT42(0x1b, 6), 1);
	test_accept("GB10", 0x2e12, BOOT42(0x1b, 0xb), 1);
	test_accept("datacentre GB10x", 0x2901, BOOT42(0x1a, 0), 1);
	check_int("accepted devices recorded nothing", get_int("refused_count"),
	    0);
	check_str("refused still empty", get_refused(), "");
	check_int("accepted devices logged nothing", fake_log_count, 0);

	test_refused_buffer();

	test_refusals();
	test_ga100();
	test_reprobe();
	test_overflow();
	test_sysctls();

	check_int("fake KPI failures", fake_failures, 0);
	if (test_failures != 0) {
		printf("arch_floor_test: FAIL (%d of %d checks)\n", test_failures,
		    checks);
		return (1);
	}
	printf("arch_floor_test: ok (%d checks, machine=%s)\n", checks,
	    NV_ARCH_FLOOR_MACHINE);
	return (0);
}

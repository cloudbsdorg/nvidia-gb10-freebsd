/*
 * User-space test of src/gb10-device/nv_device_sysctl.c,
 * src/gb10-device/nv_ctl_state.c and src/gb10-device/nv_ctl_error.c:
 * the number of NVIDIA GPUs the driver reports, the lifetime of the
 * control device, and the message the driver prints when it cannot
 * create the control device.
 *
 * The test drives the driver's own state: it calls the same functions
 * the driver calls, so it cannot pass while the driver counts
 * something else.  No GPU at all is the case this work is about; a GPU
 * that attaches later is the case that must not break it.
 */
#include <sys/types.h>
#include <sys/systm.h>
#include <sys/sysctl.h>

#include <errno.h>
#include <stdio.h>
#include <string.h>

#include "nv-freebsd.h"
#include "nv_device_sysctl.h"
#include "nv_ctl_error.h"
#include "nv_ctl_state.h"

#define MAX_OIDS	16

static struct sysctl_oid oids[MAX_OIDS];
static struct sysctl_oid parent = { .name = "nvidia" };
static unsigned noids;
static int checks, failures;

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

/* The text names something: a resource, a reason, a way out. */
static void
check_names(const char *what, const char *text, const char *needle)
{
	checks++;
	if (text == NULL || strstr(text, needle) == NULL) {
		failures++;
		printf("FAIL %s: \"%s\" does not name \"%s\"\n", what,
		    text == NULL ? "(null)" : text, needle);
	}
}

/* ---- the sysctl fake ---------------------------------------------------- */

struct sysctl_oid *
fake_children(struct sysctl_oid *oid)
{
	return (oid);
}

/*
 * The fake of the kernel's SYSCTL_ADD_PROC.  The node is described by one
 * struct, so this function has one parameter instead of one per field.
 */
struct sysctl_oid *
fake_sysctl_add_proc(const struct fake_sysctl_node *node)
{
	struct sysctl_oid *oid;

	if (noids >= MAX_OIDS)
		return (NULL);
	oid = &oids[noids++];
	memset(oid, 0, sizeof(*oid));
	oid->name = node->name;
	oid->ctx = node->ctx;
	oid->parent = node->parent;
	oid->arg1 = node->arg1;
	oid->arg2 = node->arg2;
	oid->handler = node->handler;
	oid->flags = node->flags;
	oid->fmt = node->fmt;
	oid->description = node->desc;
	return (oid);
}

int
fake_sysctl_out(struct sysctl_req *req, const void *buf, size_t len)
{
	if (req->oldptr == NULL)
		return (0);
	if (req->oldlen < len)
		return (EINVAL);
	memcpy(req->oldptr, buf, len);
	return (0);
}

/* ---- the test ------------------------------------------------------------ */

static struct sysctl_oid *
find_oid(const char *name)
{
	unsigned i;

	for (i = 0; i < noids; i++)
		if (strcmp(oids[i].name, name) == 0)
			return (&oids[i]);
	return (NULL);
}

/* Read the node the way the kernel does: call its handler. */
static int
read_count(struct sysctl_oid *oid)
{
	int value = -1;
	struct sysctl_req req;

	memset(&req, 0, sizeof(req));
	req.oldptr = &value;
	req.oldlen = sizeof(value);
	if (oid == NULL || oid->handler == NULL)
		return (-1);
	if (oid->handler(oid, oid->arg1, oid->arg2, &req) != 0)
		return (-1);
	return (value);
}

/* The message the driver prints when it cannot create the device. */
static void
check_error_message(int err, const char *reason, const char *what)
{
	char msg[256];

	memset(msg, 0, sizeof(msg));
	nv_ctl_create_error(err, msg, sizeof(msg));
	check_names(what, msg, "/dev/nvidiactl");
	check_names(what, msg, reason);
	check_names(what, msg, "load nvidia.ko again");
}

/*
 * The count the driver publishes, as the GPUs come and go.  The count is
 * read when the node is read, not when it is made.
 */
static void
check_the_count(struct sysctl_oid *oid)
{

	/* The driver has no GPU: the count is zero. */
	check_int_value("no GPU: the count is 0", read_count(oid), 0);

	/* One GPU attaches. */
	nv_ctl_state_gpu_attach();
	check_int_value("one GPU: the count is 1", read_count(oid), 1);

	/* Two GPUs attach. */
	nv_ctl_state_gpu_attach();
	check_int_value("two GPUs: the count is 2", read_count(oid), 2);

	/* The count is read when the node is read, not when it is made:
	 * a GPU that attaches while the module stays loaded is counted. */
	nv_ctl_state_gpu_attach();
	check_int_value("a GPU that attaches later is counted",
	    read_count(oid), 3);

	/* And a GPU that detaches is not. */
	nv_ctl_state_gpu_detach();
	check_int_value("a GPU that detaches is not counted",
	    read_count(oid), 2);

	/* The last GPU detaches: the driver has none again. */
	nv_ctl_state_gpu_detach();
	nv_ctl_state_gpu_detach();
	check_int_value("no GPU: the count is 0 again", read_count(oid), 0);

	/* A detach without an attach is a bug in the caller, not a
	 * negative number of GPUs: the count stays at zero, and the node
	 * never publishes a negative number. */
	nv_ctl_state_gpu_detach();
	check_int_value("a detach without an attach leaves the count at 0",
	    read_count(oid), 0);
}

/*
 * The lifetime of the control device: it belongs to the module, so it
 * exists from the module load to the module unload, with a GPU attached
 * or not.
 */
static void
check_the_device_lifetime(void)
{

	/* The module is loaded: it owns the control device, and the
	 * device may be used. */
	nv_ctl_state_device_created();
	check_true(nv_ctl_state_device_alive() != 0,
	    "the loaded module's control device may be used");

	/* The module is unloaded: the device may not be used any more,
	 * and an open in flight is refused. */
	nv_ctl_state_device_destroyed();
	check_true(nv_ctl_state_device_alive() == 0,
	    "the unloaded module's control device may not be used");
}

/*
 * The message when the control device cannot be made names the device,
 * the reason and what to do about it, and every reason says its own: a
 * failure is not reported as another failure.  The reasons are the codes
 * the kernel returns when it cannot make the device node.
 */
static void
check_the_error_messages(void)
{

	check_error_message(ENOMEM, "out of memory",
	    "the message for a memory failure");
	check_error_message(EINVAL, "refused",
	    "the message for a refused device node");
	check_error_message(ENAMETOOLONG, "could not be made",
	    "the message for any other failure");
}

int
main(void)
{
	struct sysctl_ctx_list ctx;
	struct sysctl_oid *oid;
	int rc;

	memset(&ctx, 0, sizeof(ctx));

	/* The node is registered with the module, not with a GPU. */
	nv_device_sysctl_init(&ctx, &parent);
	oid = find_oid("device_count");
	check_true(oid != NULL, "hw.nvidia.device_count is registered");
	if (oid == NULL) {
		printf("no_gpu_test: FAIL (no node)\n");
		return (1);
	}
	check_true((oid->flags & CTLTYPE_INT) != 0,
	    "hw.nvidia.device_count is an integer");
	check_true((oid->flags & CTLFLAG_RD) != 0,
	    "hw.nvidia.device_count is read-only");

	check_the_count(oid);
	check_the_device_lifetime();
	check_the_error_messages();

	/* The handler reports a failure when the kernel cannot take the
	 * value: the count is never a half-written number. */
	{
		int value = -1;
		struct sysctl_req req;

		memset(&req, 0, sizeof(req));
		req.oldptr = &value;
		req.oldlen = sizeof(value) - 1;
		rc = oid->handler(oid, oid->arg1, oid->arg2, &req);
		check_true(rc != 0, "a short buffer is refused");
		check_int_value("a refused read leaves the value alone",
		    value, -1);
	}

	if (failures != 0) {
		printf("no_gpu_test: FAIL (%d failures)\n", failures);
		return (1);
	}
	printf("no_gpu_test: PASS (%d checks)\n", checks);
	return (0);
}

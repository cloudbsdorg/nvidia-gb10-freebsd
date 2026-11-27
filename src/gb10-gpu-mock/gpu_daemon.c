/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-3-Clause
 *
 * gpu_daemon.c - the daemon of the mock: the CUSE device nodes a jail sees.
 *
 * The daemon loads no kernel module: it opens /dev/cuse and publishes the
 * nodes a real NVIDIA driver publishes:
 *
 *   /dev/nvidiactl       the RM escape ioctls
 *   /dev/nvidia0..N      one node per card of the model
 *   /dev/nvidia_modeset  the modeset node
 *   /dev/nvidia_uvm      the unified memory node
 *
 * The two last names carry an underscore where the driver has a dash: the
 * mechanism of cuse(3) replaces every character of a device name it does
 * not know with an underscore, so the node that exists on disk is the one
 * with the underscore.  The ruleset of the nodes names the nodes that
 * exist.
 *
 * Every node answers with the RM engine of the model, so a jail that is
 * given the nodes sees the same answers a test sees.  The nodes are a mock:
 * the daemon says so in its banner and in every answer it gives.
 */
#include <sys/param.h>
#include <sys/ioctl.h>
#include <sys/stat.h>

#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <cuse.h>
#include <fs/cuse/cuse_ioctl.h>

#include "gpu_mock.h"
#include "gpu_rm.h"
#include "gpu_rm_ioctl.h"

/* The role of a node: what it answers. */
enum mock_role {
	MOCK_ROLE_CONTROL = 1,
	MOCK_ROLE_GPU,
	MOCK_ROLE_MODESET,
	MOCK_ROLE_UVM
};

struct mock_node {
	struct cuse_dev	*cuse;
	struct gpu_rm		*rm;
	const struct gpu_model	*model;
	enum mock_role		role;
	char			name[64];
	unsigned		unit;		/* the card, for a GPU node */
};

/* The nodes the daemon publishes. */
static struct mock_node nodes[GPU_MOCK_MAX_NODES];
static unsigned nnodes;

/*
 * The daemon stops when it is asked to.  The handler only sets the flag:
 * the loop does the work, so the nodes are destroyed by the same thread
 * that made them.
 */
static volatile sig_atomic_t stop_requested;

static void
on_stop(int sig)
{
	(void)sig;
	stop_requested = 1;
}

/*
 * The signals that stop the daemon.  There is no SA_RESTART: the wait for
 * a command must come back with EINTR, so the loop can stop.  SIGHUP is
 * ignored: the mechanism sends it to a thread that is in a command of a
 * file that was closed, and a daemon must not die of it.
 */
static void
install_stop_handlers(void)
{
	struct sigaction sa;

	memset(&sa, 0, sizeof(sa));
	sa.sa_handler = on_stop;
	sigemptyset(&sa.sa_mask);
	(void)sigaction(SIGTERM, &sa, NULL);
	(void)sigaction(SIGINT, &sa, NULL);
	memset(&sa, 0, sizeof(sa));
	sa.sa_handler = SIG_IGN;
	sigemptyset(&sa.sa_mask);
	(void)sigaction(SIGHUP, &sa, NULL);
}

/*
 * The group that owns the nodes: the one the real driver's nodes have.  The
 * name is looked up once; a machine without it gets the root group.
 */
static gid_t
video_gid(void)
{
	struct group *gr;

	gr = getgrnam("video");
	return (gr != NULL ? gr->gr_gid : (gid_t)0);
}

/*
 * The pid file.  It is a registry of the mocks that run on this machine:
 * every line is "<pid> <prefix> <token>", the pid of a daemon, the names
 * of the nodes it published and the token of the run that started it.  The
 * daemon writes its own line, so the tool that started it can stop it even
 * when the daemon was started through doas(1) or sudo(8): the helper is
 * another process, and its pid is not the pid of the daemon.  The token is
 * what tells the two apart: the tool that starts a mock knows the token of
 * its own run and nothing else.
 *
 * A daemon refuses to start when a live daemon holds the same names: two
 * mocks must not fight over the names of the nodes.  Two mocks with other
 * names live side by side, and the file holds both.
 */
#define MOCK_PIDFILE_ENV "GPU_MOCK_PIDFILE"
#define MOCK_TOKEN_ENV "GPU_MOCK_TOKEN"
static char pidfile[512];

/* The prefix of the names the daemon publishes, for the pid file. */
static void
pidfile_prefix(char *buf, size_t len)
{
	const char *env = getenv("GPU_MOCK_PREFIX");

	if (env == NULL || env[0] == '\0')
		env = "nvidia";
	strlcpy(buf, env, len);
}

/* The token of the run that started the daemon. */
static void
pidfile_token(char *buf, size_t len)
{
	const char *env = getenv(MOCK_TOKEN_ENV);

	if (env == NULL || env[0] == '\0')
		env = "-";
	strlcpy(buf, env, len);
}

/*
 * pidfile_line: the pid of a line of the registry, the prefix of the names
 * of that daemon and the token of the run that started it.  Returns 0 when
 * the line is not one.
 */
static int
pidfile_line(const char *line, long *pid, char *prefix, size_t prefixlen,
    char *token, size_t tokenlen)
{
	char name[64], tok[64];
	long p = 0;
	int n;

	if (prefix != NULL && prefixlen > 0)
		prefix[0] = '\0';
	if (token != NULL && tokenlen > 0)
		token[0] = '\0';
	n = sscanf(line, "%ld %63s %63s", &p, name, tok);
	if (n < 2 || p <= 0)
		return (0);
	if (pid != NULL)
		*pid = p;
	if (prefix != NULL && prefixlen > 0)
		strlcpy(prefix, name, prefixlen);
	if (token != NULL && tokenlen > 0)
		strlcpy(token, n == 3 ? tok : "-", tokenlen);
	return (1);
}

/* pidfile_alive: 1 when the daemon of the line is running, 0 when it is
 * gone. */
static int
pidfile_alive(const char *line)
{
	long pid = 0;

	if (!pidfile_line(line, &pid, NULL, 0, NULL, 0))
		return (0);
	if (pid == (long)getpid())
		return (0);
	return (kill((pid_t)pid, 0) == 0);
}

/*
 * pidfile_write: write the file with the daemon of this process in it.  A
 * live daemon that holds the same names is a refusal: the mock does not
 * start and the nodes of the other one are not taken away.
 */
static int
pidfile_write(void)
{
	const char *path = getenv(MOCK_PIDFILE_ENV);
	char tmp[sizeof(pidfile) + 8];
	char mine[64], token[64], other[64];
	char line[256];
	FILE *fp;
	int fd;

	if (path == NULL || path[0] == '\0')
		return (0);		/* no pid file: the daemon just runs */
	if (strlen(path) >= sizeof(pidfile)) {
		fprintf(stderr, "gpu-mock: the name of the pid file is too "
		    "long\n");
		return (-1);
	}
	strlcpy(pidfile, path, sizeof(pidfile));
	pidfile_prefix(mine, sizeof(mine));
	pidfile_token(token, sizeof(token));
	/* Another mock holds the same names: refuse. */
	fp = fopen(pidfile, "r");
	if (fp != NULL) {
		while (fgets(line, sizeof(line), fp) != NULL) {
			if (!pidfile_alive(line))
				continue;
			if (!pidfile_line(line, NULL, other, sizeof(other),
			    NULL, 0))
				continue;
			if (strcmp(other, mine) == 0) {
				fprintf(stderr, "gpu-mock: another mock is "
				    "running (the nodes %s are taken in %s)\n",
				    mine, pidfile);
				(void)fclose(fp);
				return (-1);
			}
		}
		(void)fclose(fp);
	}
	snprintf(tmp, sizeof(tmp), "%s.new", pidfile);
	fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0644);
	if (fd < 0) {
		fprintf(stderr, "gpu-mock: cannot write the pid file %s: %s\n",
		    tmp, strerror(errno));
		return (-1);
	}
	/* The lines of the mocks that still run, then ours. */
	fp = fopen(pidfile, "r");
	if (fp != NULL) {
		while (fgets(line, sizeof(line), fp) != NULL) {
			long pid = 0;
			char tok[64];

			if (!pidfile_alive(line))
				continue;
			if (!pidfile_line(line, &pid, other, sizeof(other),
			    tok, sizeof(tok)))
				continue;
			(void)dprintf(fd, "%ld %s %s\n", pid, other, tok);
		}
		(void)fclose(fp);
	}
	(void)dprintf(fd, "%ld %s %s\n", (long)getpid(), mine, token);
	(void)close(fd);
	if (rename(tmp, pidfile) != 0) {
		(void)unlink(tmp);
		fprintf(stderr, "gpu-mock: cannot write the pid file %s: %s\n",
		    pidfile, strerror(errno));
		return (-1);
	}
	return (0);
}

/*
 * pidfile_remove: take the line of this daemon away.  The lines of the
 * other mocks stay.
 */
static void
pidfile_remove(void)
{
	char other[64], tmp[sizeof(pidfile) + 8];
	char line[256];
	FILE *fp;
	int fd;

	if (pidfile[0] == '\0')
		return;
	fp = fopen(pidfile, "r");
	if (fp == NULL)
		return;
	snprintf(tmp, sizeof(tmp), "%s.new", pidfile);
	fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0644);
	if (fd < 0) {
		(void)fclose(fp);
		return;
	}
	while (fgets(line, sizeof(line), fp) != NULL) {
		long pid = 0;
		char tok[64];

		if (!pidfile_line(line, &pid, other, sizeof(other), tok,
		    sizeof(tok)))
			continue;
		if (pid == (long)getpid())
			continue;	/* our own line */
		if (!pidfile_alive(line))
			continue;	/* a mock that is gone */
		(void)dprintf(fd, "%ld %s %s\n", pid, other, tok);
	}
	(void)fclose(fp);
	(void)close(fd);
	if (rename(tmp, pidfile) != 0)
		(void)unlink(tmp);
}

static int
node_open(struct cuse_dev *cd, int fflags)
{
	struct mock_node *n = cuse_dev_get_priv0(cd);

	(void)fflags;
	if (n == NULL) {
		errno = ENODEV;
		return (-1);
	}
	/*
	 * The daemon finds the node of a later command by the handle of the
	 * open file: without it the daemon does not know which node the
	 * client opened, and every command on it is refused.
	 */
	cuse_dev_set_per_file_handle(cd, n);
	return (0);
}

static int
node_close(struct cuse_dev *cd, int fflags)
{
	(void)cd;
	(void)fflags;
	return (0);
}

/* The doorbell of a GPU node: the mock has no ring, so it reads as empty. */
static int
node_read(struct cuse_dev *cd, int fflags, void *user_ptr, int len)
{
	(void)cd;
	(void)fflags;
	(void)user_ptr;
	(void)len;
	return (0);
}

/* A write to the doorbell: the mock counts it and takes it. */
static int
node_write(struct cuse_dev *cd, int fflags, const void *user_ptr, int len)
{
	(void)cd;
	(void)fflags;
	(void)user_ptr;
	return (len);
}

/*
 * The answers of a CUSE callback are the CUSE error codes, not an errno:
 * the library hands the return value to the kernel, which turns it into
 * the errno the client sees (CUSE_ERR_INVALID is EINVAL, CUSE_ERR_FAULT is
 * EFAULT, CUSE_ERR_NO_MEMORY is ENOMEM and anything else is ENXIO).
 */
#define MOCK_ERR_INVALID	CUSE_ERR_INVALID
#define MOCK_ERR_FAULT	CUSE_ERR_FAULT
#define MOCK_ERR_MEMORY	CUSE_ERR_NO_MEMORY
#define MOCK_ERR_OTHER	CUSE_ERR_OTHER

/*
 * The CUSE error that carries an errno.  The client sees the errno the
 * engine gave, not a flat error: the kernel turns CUSE_ERR_INVALID into
 * EINVAL, CUSE_ERR_NO_MEMORY into ENOMEM, CUSE_ERR_FAULT into EFAULT and
 * anything else into ENXIO.  The mechanism has no ENOTTY, so a command the
 * RM does not know reaches the client as ENXIO.
 */
static int
cuse_error_for(int e)
{
	switch (e) {
	case EINVAL:
		return (MOCK_ERR_INVALID);
	case ENOMEM:
		return (MOCK_ERR_MEMORY);
	case EFAULT:
		return (MOCK_ERR_FAULT);
	default:
		return (MOCK_ERR_OTHER);
	}
}

/*
 * The RM ioctls over CUSE.
 *
 * The argument of an ioctl is copied by the kernel into the client's
 * window, and the daemon reads it from there with cuse_copy_in(); the
 * answer goes back the same way with cuse_copy_out().
 *
 * The window holds the argument alone.  A pointer inside the argument (the
 * card list of the transfer ioctl, the parameters of a control) names the
 * client's address space, and CUSE cannot carry it: the daemon says so
 * instead of answering with a wrong answer.  The seam shim (gpu_shim.c)
 * answers those ioctls in the client's own process, where the pointers are
 * the client's own.
 */
static int
rm_ioctl(struct mock_node *n, unsigned long cmd, void *local, unsigned len)
{
	int rc;

	switch (cmd) {
	case IOC_XFER: {
		nv_ioctl_xfer_t xfer;

		/* The client sent fewer bytes than the ioctl names: the
		 * daemon does not read past what it got. */
		if (len < sizeof(xfer))
			return (MOCK_ERR_INVALID);
		memcpy(&xfer, local, sizeof(xfer));
		if (xfer.cmd != NV_ESC_CARD_INFO || xfer.ptr == 0)
			return (MOCK_ERR_INVALID);
		/* The card list lives in the client's address space: CUSE
		 * cannot carry it. */
		goto cannot_carry;
	}
	case IOC_RM_CONTROL:
		/* The control parameters live in the client's address space:
		 * CUSE cannot carry them. */
		goto cannot_carry;
	case IOC_RM_ALLOC: {
		NVOS21_PARAMETERS p;

		if (len < sizeof(p))
			return (MOCK_ERR_INVALID);
		memcpy(&p, local, sizeof(p));
		if (p.pAllocParms != 0 && p.paramsSize > 0) {
			/* The allocation parameters live in the client's
			 * address space: CUSE cannot carry them. */
			goto cannot_carry;
		}
		break;
	}
	default:
		break;
	}
	rc = gpu_rm_ioctl(n->rm, cmd, local);
	if (rc < 0) {
		/* The engine refused the call: the client sees the errno
		 * the engine gave, carried by the CUSE error that holds
		 * it. */
		return (cuse_error_for(errno));
	}
	return (rc);

cannot_carry:
	fprintf(stderr, "gpu-mock: the node %s cannot answer the ioctl "
	    "0x%lx over CUSE: the argument holds a pointer into the "
	    "client's address space, and CUSE carries the argument "
	    "alone (the seam shim answers this ioctl in the client's "
	    "own process)\n", n->name, cmd);
	return (MOCK_ERR_INVALID);
}

static int
node_ioctl(struct cuse_dev *cd, int fflags, unsigned long cmd, void *user_data)
{
	struct mock_node *n = cuse_dev_get_priv0(cd);
	unsigned len = IOCPARM_LEN(cmd);
	uint8_t local[CUSE_BUFFER_MAX];
	int rc;

	(void)fflags;
	(void)user_data;
	if (n == NULL || n->rm == NULL)
		return (MOCK_ERR_INVALID);
	/* Only the control and the card nodes speak the RM ioctls. */
	if (n->role != MOCK_ROLE_CONTROL && n->role != MOCK_ROLE_GPU)
		return (MOCK_ERR_INVALID);
	if (len > sizeof(local))
		return (MOCK_ERR_MEMORY);
	/* The window is the daemon's only source: it starts empty, so the
	 * daemon never reads what another command left in it. */
	memset(local, 0, sizeof(local));
	/* The argument of the call is in the client's window. */
	if (len > 0 && cuse_copy_in((const void *)(uintptr_t)CUSE_BUF_MIN_PTR,
	    local, (int)len) != 0)
		return (MOCK_ERR_FAULT);
	rc = rm_ioctl(n, cmd, local, len);
	if (rc == 0 && len > 0 && cuse_copy_out(local,
	    (void *)(uintptr_t)CUSE_BUF_MIN_PTR, (int)len) != 0)
		return (MOCK_ERR_FAULT);
	return (rc);
}

static int
node_poll(struct cuse_dev *cd, int fflags, int events)
{
	(void)cd;
	(void)fflags;
	(void)events;
	return (0);
}

static const struct cuse_methods methods = {
	node_open, node_close, node_read, node_write, node_ioctl, node_poll
};

/* One node: the name, the role and the card it belongs to. */
static int
add_node(const struct gpu_model *model, struct gpu_rm *rm, const char *name,
    enum mock_role role, unsigned unit)
{
	struct mock_node *n;

	if (nnodes >= GPU_MOCK_MAX_NODES)
		return (-1);
	n = &nodes[nnodes];
	memset(n, 0, sizeof(*n));
	snprintf(n->name, sizeof(n->name), "%s", name);
	n->model = model;
	n->rm = rm;
	n->role = role;
	n->unit = unit;
	/*
	 * The nodes belong to root and to the group that uses the display:
	 * the same owner and group the real driver's nodes have, so a jail
	 * that is given the nodes by the devfs ruleset can open them.
	 */
	n->cuse = cuse_dev_create(&methods, n, NULL, 0, video_gid(), 0660,
	    "%s", name);
	if (n->cuse == NULL) {
		fprintf(stderr, "gpu-mock: cannot create the node %s: %s\n",
		    name, strerror(errno));
		return (-1);
	}
	nnodes++;
	return (0);
}

/*
 * The nodes go away: the daemon destroys the ones it made.  The mechanism
 * does not take them away by itself when the daemon dies, and a daemon that
 * could not take all its names must not leave the ones it took behind.
 */
static void
destroy_nodes(void)
{
	unsigned i;

	for (i = 0; i < nnodes; i++)
		cuse_dev_destroy(nodes[i].cuse);
	nnodes = 0;
}

/*
 * The nodes of the model.  The names are the ones the real driver uses:
 * nvidiactl, then one nvidiaN per card, then the modeset node and the uvm
 * node (with the underscore the mechanism of cuse(3) gives them).
 * GPU_MOCK_PREFIX names them instead, for a host where those names are
 * taken or for two mocks side by side.
 */
int
gpu_daemon_run(const struct gpu_model *model, struct gpu_rm *rm)
{
	struct gpu_node_names names;
	const struct gpu_card *cards[GPU_RM_MAX_CARDS];
	unsigned n, i;
	char name[64];

	if (gpu_model_node_names(model, &names) != 0) {
		fprintf(stderr, "gpu-mock: the name of the nodes is not a name a "
		    "device may carry (GPU_MOCK_PREFIX)\n");
		return (1);
	}
	if (cuse_init() != 0) {
		fprintf(stderr, "gpu-mock: cannot use cuse(3): %s "
		    "(is the cuse module loaded? kldstat -m cuse)\n",
		    strerror(errno));
		return (1);
	}
	install_stop_handlers();
	if (pidfile_write() != 0)
		return (1);
	if (add_node(model, rm, names.control, MOCK_ROLE_CONTROL, 0) != 0)
		goto failed;
	n = gpu_model_nvidia_cards(model, cards, GPU_RM_MAX_CARDS);
	for (i = 0; i < n; i++) {
		snprintf(name, sizeof(name), "%s", names.card[i]);
		if (add_node(model, rm, name, MOCK_ROLE_GPU, i) != 0)
			goto failed;
	}
	if (add_node(model, rm, names.modeset, MOCK_ROLE_MODESET, 0) != 0)
		goto failed;
	if (add_node(model, rm, names.uvm, MOCK_ROLE_UVM, 0) != 0)
		goto failed;
	printf("gpu-mock: model %s: the nodes %s, %s, %s and %s are published "
	    "(mock; not hardware)\n", model->name, names.control,
	    names.card[0], names.modeset, names.uvm);
	fflush(stdout);
	for (;;) {
		if (cuse_wait_and_process() != 0) {
			if (stop_requested)
				break;
			if (errno == EINTR)
				continue;	/* a signal came: go on */
			fprintf(stderr, "gpu-mock: cuse_wait_and_process: %s\n",
			    strerror(errno));
			break;
		}
		if (stop_requested)
			break;
	}
	/*
	 * The nodes go away with the daemon.  The mechanism does not take
	 * them away by itself when the daemon dies: the daemon destroys
	 * them, so the next mock finds the names free.
	 */
	destroy_nodes();
	cuse_uninit();
	pidfile_remove();
	printf("gpu-mock: the nodes are gone (mock; not hardware)\n");
	fflush(stdout);
	return (0);

failed:
	/* A node that could not be made: the ones that were made go away
	 * with the daemon, so the next mock finds the names free. */
	destroy_nodes();
	cuse_uninit();
	pidfile_remove();
	return (1);
}

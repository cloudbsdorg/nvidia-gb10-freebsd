/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-3-Clause
 *
 * shim.c - LD_PRELOAD shim for Linux CUDA under the Linuxulator (see below).
 */
/* shim.c - LD_PRELOAD test shim for Linux CUDA on FreeBSD (Linuxulator).
 *
 * Two jobs:
 *
 *   1. redirect opens of /proc/sys/vm/mmap_min_addr (absent from FreeBSD's
 *      linprocfs) to a regular file holding "65536";
 *
 *   2. emulate the Linux abstract-namespace AF_UNIX socket.  FreeBSD's
 *      Linuxulator does not implement it: sys/compat/linux/linux.c passes
 *      the abstract name bytes to unix(4) as if they were a pathname, so
 *      bind() fails with ENOENT.  This shim maps an abstract address onto
 *      a file under $SHIM_ABSTRACT_DIR (default $HOME/.cache/shim-abstract)
 *      and maps it back on the way out, so the caller sees its abstract
 *      name again.
 *
 * Linux aarch64, test only. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <errno.h>
#include <limits.h>
#include <stddef.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/un.h>
static const char *fix(const char *p) {
	if (p && strcmp(p, "/proc/sys/vm/mmap_min_addr") == 0) {
		const char *r = getenv("SHIM_MMAP_MIN_ADDR");
		fprintf(stderr, "shim: redirecting %s -> %s\n", p, r ? r : "(unset)");
		return r ? r : p;
	}
	if (p && strncmp(p, "/proc/self/task/", 16) == 0 && strlen(p) > 5 &&
	    strcmp(p + strlen(p) - 5, "/comm") == 0) {
		const char *r = getenv("SHIM_COMM");
		fprintf(stderr, "shim: redirecting %s -> %s\n", p, r ? r : "(unset)");
		return r ? r : p;
	}
	return p;
}
int open(const char *p, int f, ...) { va_list a; va_start(a, f); int m = va_arg(a, int); va_end(a);
	int (*o)(const char *, int, ...) = dlsym(RTLD_NEXT, "open"); return o(fix(p), f, m); }
int open64(const char *p, int f, ...) { va_list a; va_start(a, f); int m = va_arg(a, int); va_end(a);
	int (*o)(const char *, int, ...) = dlsym(RTLD_NEXT, "open64"); return o(fix(p), f, m); }
int openat(int d, const char *p, int f, ...) { va_list a; va_start(a, f); int m = va_arg(a, int); va_end(a);
	int (*o)(int, const char *, int, ...) = dlsym(RTLD_NEXT, "openat"); return o(d, fix(p), f, m); }
FILE *fopen(const char *p, const char *m) { FILE *(*o)(const char *, const char *) = dlsym(RTLD_NEXT, "fopen"); return o(fix(p), m); }
FILE *fopen64(const char *p, const char *m) { FILE *(*o)(const char *, const char *) = dlsym(RTLD_NEXT, "fopen64"); return o(fix(p), m); }
#include <pthread.h>
/* linprocfs has no /proc/self/task/<tid>/comm, so glibc's
 * pthread_setname_np() fails with ENOENT; pretend it worked. */
int pthread_setname_np(pthread_t t, const char *n) { (void)t; (void)n; fprintf(stderr, "shim: pthread_setname_np(%s) -> 0\n", n); return 0; }

/* ------------------------------------------------------------------ */
/* Linux abstract-namespace AF_UNIX emulation.                       */
/*                                                                     */
/* A Linux abstract address is a struct sockaddr_un whose sun_path[0] */
/* is '\0'; the name is the bytes that follow, up to the length the */
/* caller passed to bind()/connect():                               */
/*     namelen = addrlen - offsetof(sun_path) - 1.                    */
/*                                                                     */
/* Each abstract name is represented by one file:                    */
/*     $SHIM_ABSTRACT_DIR/<hex of the name>                          */
/* so the abstract namespace becomes an ordinary filesystem namespace */
/* that the FreeBSD Linuxulator can carry.                           */
/* ------------------------------------------------------------------ */

#define SHIM_SUN_PATH_MAX 108	/* Linux's sizeof(sun_path) */
#define SHIM_MAX_PATH_LEN  103	/* longest path we can carry in sun_path */

/* SHIM_ABSTRACT=off: do not emulate abstract sockets. */
static int
abstract_off(void)
{
	const char *e = getenv("SHIM_ABSTRACT");

	return (e != NULL && strcmp(e, "off") == 0);
}

/* The name of the directory holding the mapped sockets. */
static const char *
abstract_dir(void)
{
	static char dir[PATH_MAX];
	static int done;

	if (!done) {
		const char *d = getenv("SHIM_ABSTRACT_DIR");
		if (d != NULL && *d != '\0') {
			snprintf(dir, sizeof(dir), "%s", d);
		} else {
			const char *h = getenv("HOME");
			if (h == NULL || *h == '\0')
				h = ".";
			snprintf(dir, sizeof(dir), "%s/.cache/shim-abstract", h);
		}
		done = 1;
	}
	return (dir);
}

/* mkdir -p, every component with the given mode. */
static int
mkdir_p_mode(const char *path, mode_t mode)
{
	char tmp[PATH_MAX];
	char *p;
	struct stat st;

	if (strlen(path) >= sizeof(tmp)) {
		errno = ENAMETOOLONG;
		return (-1);
	}
	strcpy(tmp, path);
	for (p = tmp + 1; *p != '\0'; p++) {
		if (*p != '/')
			continue;
		*p = '\0';
		/* a parent we cannot create may still exist (EACCES) */
		if (mkdir(tmp, mode) != 0 && stat(tmp, &st) != 0)
			return (-1);
		*p = '/';
	}
	if (mkdir(tmp, mode) != 0 && stat(tmp, &st) != 0)
		return (-1);
	if (stat(tmp, &st) != 0)
		return (-1);
	if (!S_ISDIR(st.st_mode)) {
		errno = ENOTDIR;
		return (-1);
	}
	return (0);
}

/* Make sure the abstract directory exists; it is ours alone, mode 0700. */
static int
ensure_abstract_dir(void)
{
	static int tried;
	static int rv;

	if (!tried) {
		rv = mkdir_p_mode(abstract_dir(), 0700);
		if (rv == 0)
			(void)chmod(abstract_dir(), 0700);
		tried = 1;
	}
	return (rv);
}

static const char hexdigits[] = "0123456789abcdef";

static void
hex_encode(const unsigned char *name, size_t n, char *out)
{
	size_t i;

	for (i = 0; i < n; i++) {
		out[2 * i] = hexdigits[name[i] >> 4];
		out[2 * i + 1] = hexdigits[name[i] & 0x0f];
	}
	out[2 * n] = '\0';
}

static int
hexval(char c)
{
	const char *p = strchr(hexdigits, c);

	if (p == NULL || c == '\0')
		return (-1);
	return (int)(p - hexdigits);
}

/* Decode a hex file name back into the abstract name bytes. */
static int
hex_decode(const char *hex, unsigned char *out, size_t outmax)
{
	size_t len = strlen(hex), i;

	if (len == 0 || (len % 2) != 0 || len / 2 > outmax)
		return (-1);
	for (i = 0; i < len; i += 2) {
		int hi = hexval(hex[i]), lo = hexval(hex[i + 1]);

		if (hi < 0 || lo < 0)
			return (-1);
		out[i / 2] = (unsigned char)((hi << 4) | lo);
	}
	return (int)(len / 2);
}

/*
 * Is sa an abstract-namespace AF_UNIX address?  If it is, hand back the
 * name bytes and their length.
 */
static int
abstract_name(const struct sockaddr *sa, socklen_t len,
    const unsigned char **name, size_t *namelen)
{
	const struct sockaddr_un *un;
	size_t off = offsetof(struct sockaddr_un, sun_path);

	if (sa == NULL || len < off + 1)
		return (0);
	if (sa->sa_family != AF_UNIX)
		return (0);
	/*
	 * SHIM_ABSTRACT=off leaves abstract names to the kernel: the test for
	 * a Linuxulator that maps them itself (Track #2101) keeps the /proc
	 * redirects but must not have this emulation in front of it.
	 */
	if (abstract_off())
		return (0);
	un = (const struct sockaddr_un *)(const void *)sa;
	if (un->sun_path[0] != '\0')
		return (0);
	*name = (const unsigned char *)un->sun_path + 1;
	*namelen = (size_t)(len - off - 1);
	if (*namelen > sizeof(un->sun_path) - 1)
		*namelen = sizeof(un->sun_path) - 1;
	return (1);
}

/* A printable, lossless description of the abstract name. */
static void
abstract_desc(const struct sockaddr *sa, socklen_t len, char *buf, size_t buflen)
{
	const unsigned char *name;
	size_t namelen;
	char hex[2 * SHIM_SUN_PATH_MAX + 1];

	if (!abstract_name(sa, len, &name, &namelen)) {
		snprintf(buf, buflen, "<not-abstract>");
		return;
	}
	if (namelen == 0) {
		snprintf(buf, buflen, "<empty>");
		return;
	}
	hex_encode(name, namelen, hex);
	snprintf(buf, buflen, "%s", hex);
}

/*
 * Build the filesystem sockaddr that stands in for an abstract address.
 * Returns 0 when the address was mapped, 1 when it is not abstract, and
 * -1 (with errno set) on failure.
 */
static int
abstract_to_path(const struct sockaddr *sa, socklen_t len,
    struct sockaddr_un *out, socklen_t *outlen)
{
	const unsigned char *name;
	size_t namelen, off = offsetof(struct sockaddr_un, sun_path);
	char hex[2 * SHIM_SUN_PATH_MAX + 1];
	char path[PATH_MAX];
	size_t plen;
	int rv;

	rv = abstract_name(sa, len, &name, &namelen);
	if (rv == 0)
		return (1);
	if (ensure_abstract_dir() != 0) {
		fprintf(stderr, "shim: abstract: cannot create %s: %s\n",
		    abstract_dir(), strerror(errno));
		errno = EACCES;
		return (-1);
	}
	hex_encode(name, namelen, hex);
	if (hex[0] == '\0')
		strcpy(hex, "_empty");
	plen = (size_t)snprintf(path, sizeof(path), "%s/%s", abstract_dir(), hex);
	if (plen >= sizeof(path)) {
		errno = ENAMETOOLONG;
		return (-1);
	}
	/* The mapped path has to fit in sun_path, or the Linuxulator cannot
	 * carry it: FreeBSD's struct sockaddr_un has a 104 byte sun_path. */
	if (plen > SHIM_MAX_PATH_LEN) {
		fprintf(stderr, "shim: abstract: mapped path too long (%zu bytes)\n",
		    plen);
		errno = ENAMETOOLONG;
		return (-1);
	}
	memset(out, 0, sizeof(*out));
	out->sun_family = AF_UNIX;
	memcpy(out->sun_path, path, plen + 1);
	*outlen = (socklen_t)(off + plen + 1);
	return (0);
}

/*
 * Rewrite a pathname AF_UNIX address that points into the abstract
 * directory back into the abstract form the caller expects.  Returns 1
 * when the address was rewritten, 0 otherwise.
 */
static int
path_to_abstract(struct sockaddr *sa, socklen_t *len)
{
	struct sockaddr_un *un;
	const char *dir = abstract_dir();
	size_t dlen = strlen(dir), off = offsetof(struct sockaddr_un, sun_path);
	unsigned char raw[SHIM_SUN_PATH_MAX];
	const char *hex;
	size_t rawlen;
	int n;

	if (sa == NULL || len == NULL || *len < off + 1)
		return (0);
	un = (struct sockaddr_un *)(void *)sa;
	if (un->sun_family != AF_UNIX)
		return (0);
	if (un->sun_path[0] == '\0')
		return (0);			/* already abstract */
	if (strncmp(un->sun_path, dir, dlen) != 0 || un->sun_path[dlen] != '/')
		return (0);
	hex = un->sun_path + dlen + 1;
	if (strcmp(hex, "_empty") == 0)
		rawlen = 0;
	else {
		n = hex_decode(hex, raw, sizeof(raw));
		if (n < 0)
			return (0);
		rawlen = (size_t)n;
	}
	if (rawlen > sizeof(un->sun_path) - 1)
		return (0);
	memset(un->sun_path, 0, sizeof(un->sun_path));
	memcpy(un->sun_path + 1, raw, rawlen);
	*len = (socklen_t)(off + 1 + rawlen);
	return (1);
}

/*
 * Map an abstract destination onto its file.  Returns -1 on error (errno
 * set), 0 when *m holds the mapped address, 1 when addr is not abstract.
 */
static int
map_addr(const char *who, const struct sockaddr *addr, socklen_t len,
    struct sockaddr_un *m, socklen_t *mlen)
{
	char desc[2 * SHIM_SUN_PATH_MAX + 1];
	int rv;

	rv = abstract_to_path(addr, len, m, mlen);
	if (rv != 0)
		return (rv);
	abstract_desc(addr, len, desc, sizeof(desc));
	fprintf(stderr, "shim: %s: abstract %s -> %s\n", who, desc, m->sun_path);
	return (0);
}

/* Map a returned filesystem address back to abstract form, and say so. */
static void
unmap_addr(const char *who, int rv, struct sockaddr *addr, socklen_t *len)
{
	if (rv == 0 && addr != NULL && len != NULL &&
	    path_to_abstract(addr, len))
		fprintf(stderr, "shim: %s: filesystem path -> abstract\n", who);
}

/* bind() and connect() alike: map an abstract address, then call real. */
static int
addr_call(const char *who, int (*real)(int, const struct sockaddr *, socklen_t),
    int fd, const struct sockaddr *addr, socklen_t len, int is_bind)
{
	struct sockaddr_un mapped;
	socklen_t mlen;
	int rv;

	rv = map_addr(who, addr, len, &mapped, &mlen);
	if (rv < 0)
		return (-1);
	if (rv > 0)
		return (real(fd, addr, len));
	/* the caller believes the node does not exist yet */
	if (is_bind && unlink(mapped.sun_path) != 0 && errno != ENOENT)
		fprintf(stderr, "shim: bind: unlink %s: %s\n",
		    mapped.sun_path, strerror(errno));
	return (real(fd, (const struct sockaddr *)(void *)&mapped, mlen));
}

int
bind(int fd, const struct sockaddr *addr, socklen_t len)
{
	static int (*real)(int, const struct sockaddr *, socklen_t);

	if (real == NULL)
		real = dlsym(RTLD_NEXT, "bind");
	return (addr_call("bind", real, fd, addr, len, 1));
}

int
connect(int fd, const struct sockaddr *addr, socklen_t len)
{
	static int (*real)(int, const struct sockaddr *, socklen_t);

	if (real == NULL)
		real = dlsym(RTLD_NEXT, "connect");
	return (addr_call("connect", real, fd, addr, len, 0));
}

int
getsockname(int fd, struct sockaddr *addr, socklen_t *len)
{
	static int (*real)(int, struct sockaddr *, socklen_t *);
	int rv;

	if (real == NULL)
		real = dlsym(RTLD_NEXT, "getsockname");
	rv = real(fd, addr, len);
	unmap_addr("getsockname", rv, addr, len);
	return (rv);
}

int
getpeername(int fd, struct sockaddr *addr, socklen_t *len)
{
	static int (*real)(int, struct sockaddr *, socklen_t *);
	int rv;

	if (real == NULL)
		real = dlsym(RTLD_NEXT, "getpeername");
	rv = real(fd, addr, len);
	unmap_addr("getpeername", rv, addr, len);
	return (rv);
}

ssize_t
sendto(int fd, const void *buf, size_t len, int flags,
    const struct sockaddr *dest, socklen_t destlen)
{
	static ssize_t (*real)(int, const void *, size_t, int,
	    const struct sockaddr *, socklen_t);
	struct sockaddr_un mapped;
	socklen_t mlen;
	int rv;

	if (real == NULL)
		real = dlsym(RTLD_NEXT, "sendto");
	rv = map_addr("sendto", dest, destlen, &mapped, &mlen);
	if (rv < 0)
		return (-1);
	if (rv > 0)
		return (real(fd, buf, len, flags, dest, destlen));
	return (real(fd, buf, len, flags,
	    (const struct sockaddr *)(void *)&mapped, mlen));
}

/*
 * sendmsg() carries no destination address on Linux (the peer is fixed by
 * connect()), but some callers fill in msghdr.msg_name.  Map it when it is
 * there and let the kernel ignore it otherwise.
 */
ssize_t
sendmsg(int fd, const struct msghdr *msg, int flags)
{
	static ssize_t (*real)(int, const struct msghdr *, int);
	struct msghdr copy;
	struct sockaddr_un mapped;
	socklen_t mlen;
	int rv;

	if (real == NULL)
		real = dlsym(RTLD_NEXT, "sendmsg");
	if (msg == NULL || msg->msg_name == NULL)
		return (real(fd, msg, flags));
	rv = map_addr("sendmsg", msg->msg_name, msg->msg_namelen, &mapped, &mlen);
	if (rv < 0)
		return (-1);
	if (rv > 0)
		return (real(fd, msg, flags));
	copy = *msg;
	copy.msg_name = &mapped;
	copy.msg_namelen = mlen;
	return (real(fd, &copy, flags));
}

int
accept(int fd, struct sockaddr *addr, socklen_t *len)
{
	static int (*real)(int, struct sockaddr *, socklen_t *);
	int rv;

	if (real == NULL)
		real = dlsym(RTLD_NEXT, "accept");
	rv = real(fd, addr, len);
	unmap_addr("accept", rv >= 0 ? 0 : -1, addr, len);
	return (rv);
}

int
accept4(int fd, struct sockaddr *addr, socklen_t *len, int flags)
{
	static int (*real)(int, struct sockaddr *, socklen_t *, int);
	int rv;

	if (real == NULL)
		real = dlsym(RTLD_NEXT, "accept4");
	rv = real(fd, addr, len, flags);
	unmap_addr("accept4", rv >= 0 ? 0 : -1, addr, len);
	return (rv);
}

/* The source address of a received message, for symmetry with sendmsg(). */
ssize_t
recvmsg(int fd, struct msghdr *msg, int flags)
{
	static ssize_t (*real)(int, struct msghdr *, int);
	ssize_t rv;

	if (real == NULL)
		real = dlsym(RTLD_NEXT, "recvmsg");
	rv = real(fd, msg, flags);
	if (rv >= 0 && msg != NULL && msg->msg_name != NULL &&
	    msg->msg_namelen != 0 &&
	    path_to_abstract(msg->msg_name, &msg->msg_namelen))
		fprintf(stderr, "shim: recvmsg: source -> abstract\n");
	return (rv);
}

/*
 * Optional ioctl tracer (SHIM_IOCTL_LOG=1): dump the argument block after each
 * ioctl, so a status the driver returns inside the block (rmStatus) is visible.
 * ktrace shows only the errno, and these drivers report most failures in the
 * block with errno 0.  Linux _IOC_SIZE is bits 16..29 of the request.
 */
#include <sys/ioctl.h>
int
ioctl(int fd, unsigned long req, ...)
{
	static int (*real)(int, unsigned long, void *);
	static int logging = -1;
	va_list ap;
	void *arg;
	int rv, saved;
	size_t sz, i;

	va_start(ap, req);
	arg = va_arg(ap, void *);
	va_end(ap);
	if (real == NULL)
		real = dlsym(RTLD_NEXT, "ioctl");
	if (logging < 0) {
		const char *e = getenv("SHIM_IOCTL_LOG");
		logging = (e != NULL && *e == '1');
	}
	rv = real(fd, req, arg);
	saved = errno;
	if (logging && arg != NULL &&
	    ((req & 0xc0000000UL) != 0 || req < 0x100)) {
		/* uvm-style small request numbers carry no size: dump 64 bytes */
		sz = req < 0x100 ? 64 : (size_t)((req >> 16) & 0x3fff);
		if (sz > 96)
			sz = 96;
		fprintf(stderr, "shim: ioctl fd=%d req=0x%lx rv=%d errno=%d blk=", fd, req, rv,
		    rv < 0 ? saved : 0);
		for (i = 0; i < sz; i++)
			fprintf(stderr, "%02x", ((unsigned char *)arg)[i]);
		fputc('\n', stderr);
	}
	errno = saved;
	return (rv);
}

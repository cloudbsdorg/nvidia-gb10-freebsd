/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-3-Clause
 *
 * test_shim_abstract.c - abstract AF_UNIX socket round trip; fails without shim.so.
 */
/* Linux test: abstract AF_UNIX socket round trip.  Needs shim.so on FreeBSD Linuxulator. */
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <stddef.h>
#include <sys/socket.h>
#include <sys/un.h>
static int fail(const char *m) { perror(m); return 1; }
int main(void)
{
	static const char name[] = "shimtst\x01\xff-s";
	size_t nl = sizeof(name) - 1;
	struct sockaddr_un a, got;
	socklen_t alen, glen;
	int ls, cs, as;
	char c = 0;

	memset(&a, 0, sizeof(a));
	a.sun_family = AF_UNIX;
	memcpy(a.sun_path + 1, name, nl);
	alen = offsetof(struct sockaddr_un, sun_path) + 1 + nl;
	if ((ls = socket(AF_UNIX, SOCK_STREAM, 0)) < 0) return fail("socket");
	if (bind(ls, (struct sockaddr *)&a, alen) < 0) return fail("bind");
	if (listen(ls, 1) < 0) return fail("listen");
	if ((cs = socket(AF_UNIX, SOCK_STREAM, 0)) < 0) return fail("socket2");
	if (connect(cs, (struct sockaddr *)&a, alen) < 0) return fail("connect");
	if (write(cs, "x", 1) != 1) return fail("write");
	if ((as = accept(ls, NULL, NULL)) < 0) return fail("accept");
	if (read(as, &c, 1) != 1 || c != 'x') { fprintf(stderr, "bad byte\n"); return 1; }
	memset(&got, 0, sizeof(got)); glen = sizeof(got);
	if (getsockname(ls, (struct sockaddr *)&got, &glen) < 0) return fail("getsockname");
	if (glen != alen || got.sun_path[0] != '\0' || memcmp(got.sun_path + 1, name, nl) != 0) {
		fprintf(stderr, "getsockname mismatch: len %u want %u path0=%d\n", glen, alen, got.sun_path[0]);
		return 1;
	}
	memset(&got, 0, sizeof(got)); glen = sizeof(got);
	if (getpeername(cs, (struct sockaddr *)&got, &glen) < 0) return fail("getpeername");
	if (glen != alen || got.sun_path[0] != '\0' || memcmp(got.sun_path + 1, name, nl) != 0) {
		fprintf(stderr, "getpeername mismatch: len %u\n", glen);
		return 1;
	}
	puts("PASS: abstract bind/connect/send/accept/getsockname/getpeername");
	return 0;
}

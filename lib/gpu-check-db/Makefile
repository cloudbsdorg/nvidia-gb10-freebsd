# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-2-Clause
#
# libgpubcheckdb: the database of the gpu-check tool.
#
# The library holds no operating system of its own.  What a machine can
# be asked is the work of a platform provider, and the FreeBSD provider
# is the one that is built in.  The library with only the fake provider
# is built by lib/gpu-check-db/fake/Makefile: it is the proof that the
# core needs nothing of an operating system to work.
#
#   make            the library (libgpubcheckdb.so.1, libgpubcheckdb.a)
#   make fake       the library with only the fake provider
#   make clean      what this Makefile built

LIB=		gpubcheckdb
SHLIB_MAJOR=	1
SRCS=		gdb_core.c gdb_query.c gdb_json.c gdb_sha256.c \
		gdb_platform.c gdb_platform_freebsd.c
INCSDIR=	${INCLUDEDIR}/gpubcheckdb
INCS=		gdb.h gdb_platform.h
MAN5=		${.CURDIR}/../../man/gpu-check.db.5
CFLAGS+=	-I${.CURDIR} -I/usr/local/include -std=gnu11 -Wall -Wextra -Werror
WARNS?=		3
# The SQLite library is a package, not a part of the base system.
LDADD=		-lsqlite3 -L/usr/local/lib

.include <bsd.lib.mk>

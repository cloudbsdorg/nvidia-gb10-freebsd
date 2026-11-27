# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-2-Clause
#
# libgpubcheckdb_fake: the database of the gpu-check tool, with only the
# fake platform provider.
#
# This is the proof that the core of the library holds nothing of an
# operating system: the same core, the same events, the same schema and
# the same answers, with a provider that knows no system call at all.
# The test that uses it builds it and runs the whole of the suite against
# it.
#
# The build is one command: the core sources of the parent directory and
# the fake provider, and nothing else.  The FreeBSD provider is not in
# the list, so it is not in the library, so the core cannot have used it.
#
#   make            the library (libgpubcheckdb_fake.so)
#   make clean      what this Makefile built

CC?=	cc
CFLAGS+=	-I.. -I/usr/local/include -std=gnu11 -Wall -Wextra -Werror -fPIC
LDFLAGS+=	-shared
LDADD=		-lsqlite3 -L/usr/local/lib

CORE=		../gdb_core.c ../gdb_query.c ../gdb_json.c ../gdb_sha256.c \
		../gdb_platform.c
HEADERS=	../gdb.h ../gdb_internal.h ../gdb_platform.h
FAKE=		../gdb_platform_fake.c

LIB=		libgpubcheckdb_fake.so

all: $(LIB)

$(LIB): $(CORE) $(FAKE) $(HEADERS)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $(LIB) $(CORE) $(FAKE) $(LDADD)

clean:
	rm -f $(LIB)

.PHONY: all clean

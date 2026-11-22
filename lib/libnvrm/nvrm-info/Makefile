# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-2-Clause
#
# nvrm-info, and the schema drift check: the build fails when the committed
# schema is not what the library generates from its field table.

PROG=		nvrm-info
BINDIR?=	/usr/sbin
SRCS=		nvrm-info.c
MAN=		nvrm-info.8
LIBNVRM_OBJ?=	${.CURDIR}/..
CFLAGS+=	-I${.CURDIR}/../include -std=gnu11 -Wall -Wextra -Werror
LDFLAGS+=	-L${LIBNVRM_OBJ}
LDADD=		-lnvrm
DPADD=		${LIBNVRM_OBJ}/libnvrm.a
SCHEMA=		${.CURDIR}/../schema/nvrm-info-1.schema.json

FILES=		${SCHEMA}
FILESDIR=	${SHAREDIR}/nvrm/schema

all: schema-check
schema-check: ${PROG}
	@LD_LIBRARY_PATH=${LIBNVRM_OBJ} ./${PROG} --schema | cmp -s - ${SCHEMA} || \
	    { echo "nvrm-info: schema drift: ${SCHEMA} is not what the" \
	    "library generates (make regen-schema)"; exit 1; }
regen-schema: ${PROG}
	LD_LIBRARY_PATH=${LIBNVRM_OBJ} ./${PROG} --schema > ${SCHEMA}

.include <bsd.prog.mk>

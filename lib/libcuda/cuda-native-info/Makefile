# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-2-Clause

PROG=		cuda-native-info
BINDIR?=	/usr/bin
SRCS=		cuda-native-info.c escape.c cuda_version.c cuda_uuid.c
DPSRCS=		${.OBJDIR}/schema.inc
CLEANFILES=	schema.inc
MAN=		cuda-native-info.1
LIBCUDA_OBJ?=	${.OBJDIR}/..
SCHEMA=		${.CURDIR}/../schema/cuda-native-info-1.schema.json

.PATH: ${.CURDIR}/..
CFLAGS+=	-I. -I${.CURDIR} -I${.CURDIR}/.. \
		-I${.CURDIR}/../../cuda-native/sdk/include \
		-std=gnu11 -Wall -Wextra -Werror
.if ${CUDA_NATIVE_TESTING:Uno} == "yes"
CFLAGS+=	-DCUDA_NATIVE_TESTING
.endif
LDFLAGS+=	-L${LIBCUDA_OBJ}
LDADD=		-lcuda -lthr
DPADD=		${LIBCUDA_OBJ}/libcuda.so

FILES=		${SCHEMA}
FILESDIR=	${SHAREDIR}/cuda-native/schema

${.OBJDIR}/schema.inc: ${SCHEMA}
	awk '{ gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); \
	    printf "\t\"%s\\n\"\n", $$0 }' ${SCHEMA} > ${.TARGET}

cuda-native-info.o cuda-native-info.pieo: ${.OBJDIR}/schema.inc

check: schema-check
schema-check: ${.OBJDIR}/schema.inc ${PROG}
	@LD_LIBRARY_PATH=${LIBCUDA_OBJ} ./${PROG} --schema | cmp -s - ${SCHEMA} || \
	    { echo "cuda-native-info: --schema differs from ${SCHEMA}"; exit 1; }

.include <bsd.prog.mk>

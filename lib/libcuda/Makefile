# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-2-Clause

LIB=		cuda
SHLIB_MAJOR=	1
VERSION_MAP=	${.CURDIR}/Version.map
VERSION_MAP_AWK=	${.CURDIR}/version_map.awk
SRCS=		cuda_core.c cuda_registry.c cuda_fake.c cuda_nvrm.c \
		cuda_errors.c cuda_backend.c cuda_version.c cuda_uuid.c
INCSDIR=	${INCLUDEDIR}
INCS=		${.CURDIR}/../cuda-native/sdk/include/cuda.h
MAN=		man/libcuda.3
DPSRCS=		${.OBJDIR}/cuda_exports.inc
CLEANFILES=	cuda_exports.inc
# The man links and the proc-address table share the one exported-name list;
# both come from the one Version.map parser, in its two modes.
CUDA_FUNCS!=	awk -f ${VERSION_MAP_AWK} -v mode=names ${VERSION_MAP}
CUDA_EXPORTS_INC!=	awk -f ${VERSION_MAP_AWK} -v mode=include ${VERSION_MAP}
.export CUDA_EXPORTS_INC
.for f in ${CUDA_FUNCS}
MLINKS+=	libcuda.3 ${f}.3
.endfor
CFLAGS+=	-I${.OBJDIR} -I${.CURDIR} -I${.CURDIR}/../cuda-native/sdk/include \
		-std=gnu11 -Wall -Wextra -Werror
.if ${CUDA_NATIVE_TESTING:Uno} == "yes"
CFLAGS+=	-DCUDA_NATIVE_TESTING
.endif
WARNS?=		3
# Function addresses in the proc table must be the exported implementations.
LDFLAGS+=	-Wl,-Bsymbolic-functions
# pthread_once needs libthr in an out-of-tree build; libc's stub is not enough.
LDADD=		-lthr

${.OBJDIR}/cuda_exports.inc: ${VERSION_MAP} ${VERSION_MAP_AWK}
	printf "%s\n" "$$CUDA_EXPORTS_INC" > ${.TARGET}

cuda_core.o cuda_core.pieo: ${.OBJDIR}/cuda_exports.inc

.include <bsd.lib.mk>

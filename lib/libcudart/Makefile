# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-2-Clause
#
# The native CUDA runtime: the Runtime API on our own libcuda.  The
# library is libcudart-native.so.13; the soname is libcudart-native.so.13
# and not libcudart.so.13, because the SDK tree ships a link-only stub
# under that name and a program must never load one library when it asked
# for the other.

LIB=		cudart-native
SHLIB_MAJOR=	13
VERSION_MAP=	${.CURDIR}/Version.map
SRCS=		cudart_device.c cudart_error.c cudart_launch.c \
		cudart_memory.c cudart_register.c cudart_stream.c
INCSDIR=	${INCLUDEDIR}
# The headers of the SDK: the runtime API and the driver API.
SDKINC?=	${.CURDIR}/../cuda-native/sdk/include
INCS=		${SDKINC}/cuda.h ${SDKINC}/cuda_runtime_api.h
MAN=		man/libcudart.3
# The directory that holds libcuda.so.  The runtime links against it.
LIBCUDA_OBJ?=	${.OBJDIR}/../libcuda
CFLAGS+=	-I${.CURDIR} -I${SDKINC} \
		-std=gnu11 -Wall -Wextra -Werror
WARNS?=		3
LDFLAGS+=	-L${LIBCUDA_OBJ}
LDADD=		-lcuda -lthr
DPADD=		${LIBCUDA_OBJ}/libcuda.so

.include <bsd.lib.mk>

# The linker name of the runtime is libcudart.so, so that -lcudart finds
# it in the directory that holds it.  The soname stays
# libcudart-native.so.13, so the loader never takes the SDK stub for the
# runtime.
${.OBJDIR}/libcudart.so: ${.OBJDIR}/libcudart-native.so
	ln -sf libcudart-native.so ${.TARGET}

all: ${.OBJDIR}/libcudart.so

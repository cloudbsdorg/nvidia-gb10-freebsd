# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-2-Clause

LIB=		cuda
SHLIB_MAJOR=	1
VERSION_MAP=	${.CURDIR}/Version.map
SRCS=		cuda_core.c cuda_registry.c cuda_fake.c cuda_nvrm.c \
		cuda_errors.c cuda_version.c cuda_uuid.c
INCSDIR=	${INCLUDEDIR}
INCS=		${.CURDIR}/../cuda-native/sdk/include/cuda.h
MAN=		man/libcuda.3
CUDA_FUNCS=	cuInit cuDriverGetVersion cuDeviceGetCount cuDeviceGet \
		cuDeviceGetName cuDeviceGetUuid cuDeviceTotalMem \
		cuDeviceGetAttribute cuDevicePrimaryCtxRetain \
		cuDevicePrimaryCtxRelease cuCtxGetCurrent cuCtxSetCurrent \
		cuCtxGetDevice cuGetErrorName cuGetErrorString cuGetProcAddress \
		cuGetProcAddress_v2
.for f in ${CUDA_FUNCS}
MLINKS+=	libcuda.3 ${f}.3
.endfor
CFLAGS+=	-I${.CURDIR} -I${.CURDIR}/../cuda-native/sdk/include \
		-std=gnu11 -Wall -Wextra -Werror
.if ${CUDA_NATIVE_TESTING:Uno} == "yes"
CFLAGS+=	-DCUDA_NATIVE_TESTING
.endif
WARNS?=		3
# Function addresses in the proc table must be the exported implementations.
LDFLAGS+=	-Wl,-Bsymbolic-functions
# pthread_once needs libthr in an out-of-tree build; libc's stub is not enough.
LDADD=		-lthr

.include <bsd.lib.mk>

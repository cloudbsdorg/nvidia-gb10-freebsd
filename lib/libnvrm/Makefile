# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-2-Clause
#
# libnvrm (Track #2378).  Needs NVIDIA's open-gpu-kernel-modules 580.178.04
# headers (MIT), fetched by scripts/fetch-sources.sh:
#   make OGKM=/path/to/open-gpu-kernel-modules-580.178.04
# The default is ${GB10_WORK:-$HOME/work/gb10}/sources/....

OGKM?=	${GB10_WORK:U${HOME}/work/gb10}/sources/open-gpu-kernel-modules-580.178.04

LIB=		nvrm
SHLIB_MAJOR=	1
VERSION_MAP=	${.CURDIR}/Version.map
SRCS=		nvrm.c nvrm_cap.c nvrm_fake.c nvrm_fields.c nvrm_json.c \
		nvrm_names.c nvrm_rm.c nvrm_table.c
INCSDIR=	${INCLUDEDIR}/nvrm
INCS=		include/nvrm/nvrm.h
MAN=		man/nvrm.3 man/nvrm.7
MLINKS=		nvrm.3 nvrm_enumerate.3 nvrm.3 nvrm_close.3 \
		nvrm.3 nvrm_device_info_get.3 nvrm.3 nvrm_device_refresh.3 \
		nvrm.3 nvrm_json_document.3 nvrm.3 nvrm_json_schema.3
CFLAGS+=	-I${.CURDIR} -I${.CURDIR}/include -std=gnu11 -Wall -Wextra \
		-Wno-unused-parameter -Werror
CFLAGS+=	-I${OGKM}/src/common/sdk/nvidia/inc \
		-I${OGKM}/src/common/sdk/nvidia/inc/ctrl \
		-I${OGKM}/src/nvidia/arch/nvalloc/unix/include \
		-I${OGKM}/src/common/inc
WARNS?=		3
LIBADD=

.include <bsd.lib.mk>

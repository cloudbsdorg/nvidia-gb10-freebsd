# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-2-Clause

LIB=		cuda
SHLIB_MAJOR=	1
VERSION_MAP=	${.CURDIR}/Version.map
VERSION_MAP_AWK=	${.CURDIR}/version_map.awk
SRCS=		cuda_core.c cuda_registry.c cuda_fake.c cuda_nvrm.c \
		cuda_mem.c cuda_errors.c cuda_backend.c cuda_version.c \
		cuda_uuid.c
INCSDIR=	${INCLUDEDIR}
INCS=		${.CURDIR}/../cuda-native/sdk/include/cuda.h
MAN=		man/libcuda.3
DPSRCS=		${.OBJDIR}/cuda_exports.inc
CLEANFILES=	cuda_exports.inc
# The man links and the proc-address table share the one exported-name list;
# both come from the one Version.map parser, in its two modes.
CUDA_FUNCS!=	awk -f "${VERSION_MAP_AWK}" -v mode=names "${VERSION_MAP}"
.for f in ${CUDA_FUNCS}
MLINKS+=	libcuda.3 ${f}.3
.endfor
CFLAGS+=	-I${.OBJDIR} -I${.CURDIR} -I${.CURDIR}/../cuda-native/sdk/include \
		-I${.CURDIR}/../libnvrm/include \
		-std=gnu11 -Wall -Wextra -Werror
.if ${CUDA_NATIVE_TESTING:Uno} == "yes"
CFLAGS+=	-DCUDA_NATIVE_TESTING
.endif
WARNS?=		3
# Function addresses in the proc table must be the exported implementations.
LDFLAGS+=	-Wl,-Bsymbolic-functions
# pthread_once needs libthr in an out-of-tree build; libc's stub is not enough.
LDADD=		-lthr

# The proc-address table is generated from the exported-name list.  The
# generated file is a prerequisite of every object flavour of cuda_core.c,
# which includes it: the plain object, the shared-object one and the profiled
# ones.  Without those edges a build of one flavour can start before the
# generated file exists.  The generation writes a temporary file and renames
# it only after the parser succeeds.  A failed run removes the temporary file
# and the include it was to replace, so a failed generation leaves no stale
# table behind and the next build regenerates the whole table.  Every path
# the recipe expands is quoted, so a path that carries a shell command stays
# a path and does not become a command.
${.OBJDIR}/cuda_exports.inc: ${VERSION_MAP} ${VERSION_MAP_AWK}
	@test -n "${.OBJDIR}" || { echo "libcuda: the object directory is empty" >&2; exit 1; }
	awk -f "${VERSION_MAP_AWK}" -v mode=include "${VERSION_MAP}" > "${.OBJDIR}/cuda_exports.inc.tmp" && mv -f "${.OBJDIR}/cuda_exports.inc.tmp" "${.TARGET}" || { rm -f "${.OBJDIR}/cuda_exports.inc.tmp" "${.TARGET}"; exit 1; }

cuda_core.o cuda_core.pico cuda_core.po cuda_core.pieo: ${.OBJDIR}/cuda_exports.inc

.include <bsd.lib.mk>

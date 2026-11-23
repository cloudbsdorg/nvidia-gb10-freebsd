# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-2-Clause
#
# libnvrm.  Needs NVIDIA's open-gpu-kernel-modules headers (MIT), fetched by
# scripts/fetch-sources.sh.  The version of those headers has one source:
# the ogkm_tag line of SOURCES.  The default header path is built from it, and
# the build refuses when NVRM_RM_VERSION in nvrm.h names another version.
#   make OGKM=/path/to/open-gpu-kernel-modules-<tag>
# The default is <repo>/work/sources/open-gpu-kernel-modules-<tag>.

OGKM_TAG!=	awk '$$1 == "ogkm_tag" { print $$2 }' ${.CURDIR}/../../SOURCES
OGKM?=	${GB10_WORK:U${.CURDIR}/../../work}/sources/open-gpu-kernel-modules-${OGKM_TAG}

.if empty(OGKM_TAG)
.error libnvrm: ${.CURDIR}/../../SOURCES has no ogkm_tag line (copy SOURCES with lib/)
.endif

.if !make(clean) && !make(cleandir) && !make(cleandepend)
.BEGIN:
	@have=$$(sed -n 's/^#define NVRM_RM_VERSION[[:space:]]*"\(.*\)".*/\1/p' \
	    ${.CURDIR}/include/nvrm/nvrm.h); \
	[ "$$have" = "${OGKM_TAG}" ] || { echo \
	    "libnvrm: nvrm.h says NVRM_RM_VERSION $$have, SOURCES ogkm_tag says ${OGKM_TAG}: change NVRM_RM_VERSION in include/nvrm/nvrm.h or the ogkm_tag line in SOURCES"; \
	    exit 1; }
.endif

LIB=		nvrm
SHLIB_MAJOR=	1
VERSION_MAP=	${.CURDIR}/Version.map
SRCS=		nvrm.c nvrm_cap.c nvrm_compat.c nvrm_fake.c nvrm_fake_mem.c nvrm_fields.c \
		nvrm_json.c nvrm_mem.c nvrm_names.c nvrm_owner.c nvrm_rm.c \
		nvrm_rm_mem.c nvrm_table.c nvrm_va.c
INCSDIR=	${INCLUDEDIR}/nvrm
INCS=		include/nvrm/nvrm.h include/nvrm/nvrm_version.h
MAN=		man/nvrm.3 man/nvrm_mem.3 man/nvrm.7
# The man links come from Version.map, the one list of the exported calls:
# NVRM_1.0 (discovery) and NVRM_1.2 (version numbers) link to nvrm.3,
# NVRM_1.1 (memory and VA) to nvrm_mem.3.
NVRM_FUNCS!=	awk '/^NVRM_1\.[02] /{v=1;next} /^}/{v=0} v && /^\t\tnvrm_/{sub(";","");if (!s[$$1]++) print $$1}' ${.CURDIR}/Version.map
NVRM_MEM_FUNCS!=	awk '/^NVRM_1\.1 /{v=1;next} /^}/{v=0} v && /^\t\tnvrm_/{sub(";","");print $$1}' ${.CURDIR}/Version.map
.for f in ${NVRM_FUNCS}
MLINKS+=	nvrm.3 ${f}.3
.endfor
.for f in ${NVRM_MEM_FUNCS}
MLINKS+=	nvrm_mem.3 ${f}.3
.endfor
CFLAGS+=	-I${.CURDIR} -I${.CURDIR}/include -std=gnu11 -Wall -Wextra \
		-Wno-unused-parameter -Werror
CFLAGS+=	-I${OGKM}/src/common/sdk/nvidia/inc \
		-I${OGKM}/src/common/sdk/nvidia/inc/ctrl \
		-I${OGKM}/src/nvidia/arch/nvalloc/unix/include \
		-I${OGKM}/src/common/inc
WARNS?=		3
# pthread_once for the backend registry.  LDADD, not LIBADD: LIBADD is only
# processed by a build inside the FreeBSD source tree (measured: out of tree it
# adds nothing, and libc's own pthread_once is a stub that never calls back).
# Only the PIC objects (the shared library) carry symbol versions; the static
# archive keeps the plain names.
SHARED_CFLAGS+=	-DNVRM_SHLIB
LDADD=		-lthr

.include <bsd.lib.mk>

# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-2-Clause
#
# libnvrm.  Needs NVIDIA's open-gpu-kernel-modules headers (MIT), fetched by
# scripts/fetch-sources.sh.  The version of those headers has one source:
# the ogkm_tag line of SOURCES.  The default header path is built from it, and
# the build refuses when NVRM_RM_VERSION in nvrm.h names another version.
#   make OGKM=/path/to/open-gpu-kernel-modules-<tag>
# The default is ${GB10_WORK:-$HOME/work/gb10}/sources/open-gpu-kernel-modules-<tag>.

OGKM_TAG!=	awk '$$1 == "ogkm_tag" { print $$2 }' ${.CURDIR}/../../SOURCES
OGKM?=	${GB10_WORK:U${HOME}/work/gb10}/sources/open-gpu-kernel-modules-${OGKM_TAG}

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
SRCS=		nvrm.c nvrm_cap.c nvrm_fake.c nvrm_fake_mem.c nvrm_fields.c \
		nvrm_json.c nvrm_mem.c nvrm_names.c nvrm_rm.c nvrm_rm_mem.c \
		nvrm_table.c nvrm_va.c
INCSDIR=	${INCLUDEDIR}/nvrm
INCS=		include/nvrm/nvrm.h
MAN=		man/nvrm.3 man/nvrm_mem.3 man/nvrm.7
NVRM_FUNCS=	nvrm_enumerate nvrm_close nvrm_backend_name \
		nvrm_rm_running_version nvrm_device_count nvrm_device_get \
		nvrm_device_info_get nvrm_device_refresh nvrm_strerror \
		nvrm_error_id nvrm_reason_id nvrm_reason_text \
		nvrm_source_name nvrm_cap_name nvrm_info_nfields \
		nvrm_info_field nvrm_json_document nvrm_json_header \
		nvrm_json_device nvrm_json_end nvrm_json_error \
		nvrm_json_schema
.for f in ${NVRM_FUNCS}
MLINKS+=	nvrm.3 ${f}.3
.endfor
NVRM_MEM_FUNCS=	nvrm_device_open nvrm_device_close nvrm_client_errmsg \
		nvrm_client_stats_get nvrm_vaspace_info_get nvrm_va_reserve \
		nvrm_va_release nvrm_mem_alloc nvrm_mem_register_user \
		nvrm_mem_free nvrm_mem_info_get nvrm_mem_map_gpu \
		nvrm_mem_unmap_gpu nvrm_mem_map_cpu nvrm_mem_unmap_cpu \
		nvrm_mem_read nvrm_mem_write nvrm_mem_export_fd \
		nvrm_mem_import_fd
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
LDADD=		-lthr

.include <bsd.lib.mk>

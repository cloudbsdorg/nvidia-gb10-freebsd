# Copyright (c) 2026 Dave Cottlehuber
# SPDX-License-Identifier: BSD-2-Clause
#
# gb10smmu.ko: enables the SMMU in front of the GB10 GPU.  Built on its own:
#	make -C src/gb10-smmu SYSDIR=/usr/src/sys

KMOD=	gb10smmu
SRCS=	gb10smmu.c
# The IORT parser, kept in a file of its own so that the unit test can
# build the same source the module builds.
SRCS+=	gb10smmu_iort.c
# <sys/bus.h> pulls in the two interface headers the kernel generates from
# its own device_if.m and bus_if.m; conf/kmod.mk makes the rules for them.
SRCS+=	device_if.h
SRCS+=	bus_if.h
# The ACPICA headers (contrib/dev/acpica/include/acpi.h) include the
# kernel's opt_acpi.h.  The module build makes one for us: conf/kmod.mk
# links it from KERNBUILDDIR when the build has one and writes an empty
# one when it does not (the NVIDIA driver does the same).
SRCS+=	opt_acpi.h

.include <bsd.kmod.mk>

# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# nvidia_linux.ko: the Linux compatibility provider of nvidia.ko (Track #2363).
# Built beside TREE/nvidia by scripts/build-shim.sh --module=nvidia-linux.
KMOD=		nvidia_linux
SRCS=		nvidia_linux_mod.c
SRCS+=		bus_if.h device_if.h vnode_if.h
CFLAGS+=	-I.
# The bridge never links the NVIDIA RM core and exports nothing; it takes
# nvidia_bridge_register and nvidia_bridge_unregister from nvidia.ko.
KMODDIR?=	/boot/modules
.include <bsd.kmod.mk>

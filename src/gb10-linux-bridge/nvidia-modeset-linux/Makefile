# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# nvidia_modeset_linux.ko: the Linux compatibility provider of
# nvidia-modeset.ko (Track #2363). Built by scripts/build-shim.sh
# --module=nvidia-modeset-linux.
KMOD=		nvidia_modeset_linux
SRCS=		nvidia_modeset_linux_mod.c
SRCS+=		bus_if.h device_if.h vnode_if.h
CFLAGS+=	-I.
KMODDIR?=	/boot/modules
.include <bsd.kmod.mk>

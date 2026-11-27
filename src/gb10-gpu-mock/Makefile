# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# gpu-mock - the GPU mock of nvidia-gb10-freebsd: the CUSE device nodes a
# jail sees, the fake pciconf and sysctl answers, and the RM escape ioctls
# answered from a model file.  The logic is in scripts/gpu-mock.sh, so GNU
# make and bmake drive it the same way.
#
#   make            build the mock
#   make clean      remove the build tree
#
# The NVIDIA headers are the open-gpu-kernel-modules of the tag in SOURCES.
# Set GB10_WORK to the work root that holds them.

PROG = gpu-mock

all: $(PROG)

$(PROG):
	@sh ../../scripts/gpu-mock.sh build

clean:
	@sh ../../scripts/gpu-mock.sh clean

.PHONY: all clean

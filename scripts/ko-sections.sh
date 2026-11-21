#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# ko-sections.sh MODULE.ko ... - print "<name> <sha256>" of the contents of the loaded sections
# (.text, .rodata, .data) of each kernel module file.  Two builds of one tree differ in the
# RM core's embedded build date only: the hashes tell a changed module from a rebuilt one.
# This is the command that produced ~/work/gb10/testboot-prime-import/SECTIONS.sums:
#   cd ~/work/gb10/testboot-prime-import/mods && sh <repo>/scripts/ko-sections.sh nvidia-drm/nvidia-drm.ko nvidia-modeset/nvidia-modeset.ko nvidia/nvidia.ko
set -u
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
export PATH
[ $# -ge 1 ] || { echo "usage: ko-sections.sh MODULE.ko ..." >&2; exit 2; }
for f in "$@"; do
	[ -f "$f" ] || { echo "ko-sections: no such file: $f" >&2; exit 2; }
	n=$(basename "$f" .ko)
	h=$(llvm-objdump -s -j .text -j .rodata -j .data "$f" | sed 1,2d | sha256 -q)
	echo "$n $h"
done

#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# nvbridge_ioctl_unit_test.sh - host unit test of the provider modules' shared
# header (src/gb10-linux-bridge/nvbridge_ioctl.h, Track #2363), plus mutants of
# that header the test must refuse. A mutant that does not build is a FAIL, not
# a catch. No kernel, no root.
set -u
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
export PATH
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC=$HERE/../src/gb10-linux-bridge
WORK=${GB10_WORK:-$HOME/work/gb10}
mkdir -p "$WORK/tmp"
TMPD=$(mktemp -d "$WORK/tmp/nvbridge_ioctl_unit_test.XXXXXXXX") || exit 1
trap 'rm -rf "$TMPD"' EXIT
fails=0

build() {	# build <header> <out>
	mkdir -p "$TMPD/inc"
	cp "$1" "$TMPD/inc/nvbridge_ioctl.h"
	cc -std=gnu11 -Wall -Werror -Wno-unused-function -D_KERNEL -I"$HERE/data/nvbridge_stubs" -I"$TMPD/inc" -o "$2" "$HERE/data/nvbridge_ioctl_unit_test.c" 2> "$TMPD/cc.err"
}
build_unit() { build "$1" "$2"; }
. "$HERE/lib/mutant.sh"
if ! build "$SRC/nvbridge_ioctl.h" "$TMPD/good"; then echo "FAIL: the unit test does not build: $(head -3 "$TMPD/cc.err")"; exit 1; fi
if "$TMPD/good" > "$TMPD/good.out"; then echo "PASS: the unit test passes on nvbridge_ioctl.h ($(grep -c '^PASS' "$TMPD/good.out") checks)"; else echo "FAIL: the unit test fails on nvbridge_ioctl.h"; grep FAIL "$TMPD/good.out"; fails=$((fails + 1)); fi

mutant() { mutant_check "$1" "$SRC/nvbridge_ioctl.h" "$2"; }
mutant in-out-swapped 's/dir = IOC_IN;/dir = IOC_OUT_TMP;/; s/dir = IOC_OUT;/dir = IOC_IN;/; s/IOC_OUT_TMP/IOC_OUT/'
mutant bit29-check-removed 's/if ((lcmd & LINUX_IOC_INOUT) != (lcmd & IOC_DIRMASK))/if (0)/'
mutant void-lost 's/dir = IOC_VOID;/dir = 0;/'
mutant name-match-always 's/if (strcmp(d_name, \*names) == 0)/if (1)/'
mutant refthread-leaked 's/dev_relthread(dev, ref);/(void)dev;/'
mutant vchr-not-checked 's/fp->f_vnode->v_type == VCHR/1/'
mutant filter-removed 's/if (!nvbridge_fd_is_ours(td, args->fd, names))/if (0)/'
mutant enoioctl-becomes-zero 's/return (ENOIOCTL);/return (0);/'
mutant file-not-dropped 's/fdrop(fp, td);/(void)fp;/'
mutant load-failure-keeps-handler 's/linux_ioctl_unregister_handler(p->handler);$/(void)p;/'
[ "$fails" -eq 0 ] || { echo "nvbridge_ioctl_unit_test: $fails FAILED"; exit 1; }
echo "nvbridge_ioctl_unit_test: all passed"

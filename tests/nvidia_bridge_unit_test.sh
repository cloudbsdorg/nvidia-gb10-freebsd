#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# nvidia_bridge_unit_test.sh - host unit test of the core side of the compat
# provider KPI (src/gb10-linux-bridge/nvidia_bridge.c, Track #2363), plus
# mutants of that file that the test must refuse. No kernel, no root.
set -u
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
export PATH
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$HERE/..
SRC=$REPO/src/gb10-linux-bridge
WORK=${GB10_WORK:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)/work}
mkdir -p "$WORK/tmp"
TMPD=$(mktemp -d "$WORK/tmp/nvidia_bridge_unit_test.XXXXXXXX") || exit 1
trap 'rm -rf "$TMPD"' EXIT
fails=0

# build <bridge.c> <out> [extra cc flags]
build() {
	_c=$1; _o=$2; shift 2
	mkdir -p "$TMPD/inc"
	cp "$_c" "$TMPD/inc/nvidia_bridge.c"
	cp "$SRC/nvidia_bridge.h" "$TMPD/inc/nvidia_bridge.h"
	cc -std=gnu11 -Wall -Werror -D_KERNEL "$@" -I"$HERE/data/nvbridge_stubs" -I"$TMPD/inc" -o "$_o" "$HERE/data/nvidia_bridge_unit_test.c" 2> "$TMPD/cc.err"
}
build_unit() { build "$1" "$2"; }
. "$HERE/lib/mutant.sh"

if ! build "$SRC/nvidia_bridge.c" "$TMPD/good"; then echo "FAIL: the unit test does not build: $(head -3 "$TMPD/cc.err")"; exit 1; fi
if "$TMPD/good" > "$TMPD/good.out"; then echo "PASS: the unit test passes on nvidia_bridge.c ($(grep -c '^PASS' "$TMPD/good.out") checks)"; else echo "FAIL: the unit test fails on nvidia_bridge.c"; grep FAIL "$TMPD/good.out"; fails=$((fails + 1)); fi

# the legacy build refuses a provider
if build "$SRC/nvidia_bridge.c" "$TMPD/legacy" -DNV_CORE_LINUX_COMPAT && "$TMPD/legacy" > "$TMPD/legacy.out"; then echo "PASS: a build with NV_CORE_LINUX_COMPAT refuses a provider"; else echo "FAIL: the legacy build check: $(head -2 "$TMPD/legacy.out" "$TMPD/cc.err" 2>/dev/null)"; fails=$((fails + 1)); fi

# mutants: each must turn the test red
mutant() { mutant_check "$1" "$SRC/nvidia_bridge.c" "$2"; }
mutant replay-failure-fatal 's/d->provided = ops->nbo_cdev_add(&d->cdev) == 0;/if (ops->nbo_cdev_add(\&d->cdev) != 0) { sx_xunlock(\&nvb_lock); return (ENODEV); } d->provided = 1;/'
mutant size-check-removed 's/ops->nbo_size != sizeof(\*ops) ||//'
mutant version-check-removed 's/ops->nbo_version != NVIDIA_BRIDGE_KPI_VERSION ||//'
mutant busy-check-removed 's/if (nvb_ops != NULL) {$/if (0) {/'
mutant no-replay 's/TAILQ_FOREACH(d, &nvb_devs, link)$/TAILQ_FOREACH(d, \&nvb_devs, link) if (0)/'
mutant forget-to-del-on-unregister 's/^\t\t\tops->nbo_cdev_del(&d->cdev);$/\t\t\t(void)d;/'
mutant unregister-dels-refused 's/^\t\tif (d->provided)$/\t\tif (1)/'
mutant del-after-refused-add 's/if (nvb_ops != NULL && d->provided)/if (nvb_ops != NULL)/'
mutant leak-on-remove 's/free(d, M_NVBRIDGE);/(void)d;/'
mutant removed-ignores-minor 's/d->cdev.nbc_minor == minor \&\&/1 \&\&/'

[ "$fails" -eq 0 ] || { echo "nvidia_bridge_unit_test: $fails FAILED"; exit 1; }
echo "nvidia_bridge_unit_test: all passed"

#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# build-stubs.sh - compile the fail-closed RM core stubs
# (src/gb10-stubs/nv-gb10-stubs.c) with the RM core's own compile flags
# for the running architecture, partially link them onto the core object
# with ld.lld -r, and count what remains undefined against the prepared
# OS layer.
#
# Usage: scripts/build-stubs.sh
#
# Environment:
#   GB10_WORK   work root holding build/ and logs/; defaults to
#               <repo>/work
#   CORE_OBJ    RM core object; defaults to
#               $GB10_WORK/build/nv-kernel-aarch64.o on aarch64 and
#               $GB10_WORK/build/nv-kernel-amd64.o on amd64
#   STUBS_SRC   stub source; defaults to
#               <repo>/src/gb10-stubs/nv-gb10-stubs.c
#   STUBS_OBJ   stub object output; defaults to
#               $GB10_WORK/build/nv-gb10-stubs.o
#   LINKED_OBJ  partial-link output; defaults to
#               $GB10_WORK/build/nv-kernel-gb10.o
# (tests override the last four; defaults are the shipping paths.)
#
# Architecture: aarch64 and amd64 are supported and nothing else. The
# architecture is the test hook GB10_TEST_ARCH when GB10_TEST_HOOKS=1
# and the hook is set, and `uname -p` otherwise; any other value is a
# hard error (there is no fallback to aarch64). The compiler and the
# linker are the CC and LD test hooks under the same GB10_TEST_HOOKS=1
# gate, defaulting to cc and ld.lld. The hooks are honoured ONLY when
# GB10_TEST_HOOKS=1 (scripts/lib.sh's test_hook), which announces every
# hook it honours on stderr, so a hooked run can never be mistaken for
# a real one.
#
# Prints "still undefined vs OS layer: N" (the count_missing set
# difference from scripts/lib.sh, the same method build-rmcore.sh
# reports) and exits 1 if N is not 0 or the count cannot be made.
# Requires the ogkm copy from scripts/build-rmcore.sh and the OS-layer
# objects from scripts/prepare-tree.sh. Nothing is written outside
# $GB10_WORK (and explicit overrides); /tmp is never used.

set -eu

PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL

WORK=${GB10_WORK:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)/work}
# GB10_WORK must be an ABSOLUTE path: the build below cd's into the ogkm
# copy before it compiles and links, so a relative work root would break
# the build and could leave a stray directory behind (pass-3 u09 #1).
# Refusing beats absolutising, and it closes the leading-'-' case too.
case $WORK in
/*) ;;
*)
	echo "build-stubs: GB10_WORK must be an absolute path: $WORK" >&2
	exit 1
	;;
esac
export TMPDIR="$WORK/tmp"

SCRIPTDIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH= cd -- "$SCRIPTDIR/.." && pwd)
. "$SCRIPTDIR/lib.sh"

# The architecture the stubs are compiled for. test_hook prints the
# fixed path it is handed unless GB10_TEST_HOOKS=1 and the named
# variable is set, so `uname -p` is the fixed path here: the hook wins
# when the hooks are on and the hook is set, and `uname -p` is used when
# the hook is unset or the hooks are off. The hook is announced on
# stderr by test_hook, so a hooked run can never be mistaken for a
# real one. Only aarch64 and amd64 are supported; anything else is a
# hard error - the build NEVER falls back to aarch64, because a stub
# compiled for the wrong architecture would link onto the wrong core.
ARCH=$(test_hook build-stubs GB10_TEST_ARCH "$(uname -p)")
case $ARCH in
aarch64)
	CORE_DEFAULT=$WORK/build/nv-kernel-aarch64.o
	;;
amd64)
	CORE_DEFAULT=$WORK/build/nv-kernel-amd64.o
	;;
*)
	echo "build-stubs: unsupported architecture '$ARCH' (expected aarch64 or amd64)" >&2
	exit 1
	;;
esac

# The compiler and the linker, under the same hook gate: cc and ld.lld
# unless GB10_TEST_HOOKS=1 and CC or LD is set, in which case the hook
# wins and is announced on stderr.
CC_PROG=$(test_hook build-stubs CC cc)
LD_PROG=$(test_hook build-stubs LD ld.lld)

OGKM=$WORK/build/ogkm
OSOBJDIR=$WORK/build/tree/nvidia
CORE_OBJ=${CORE_OBJ:-$CORE_DEFAULT}
STUBS_SRC=${STUBS_SRC:-$REPO/src/gb10-stubs/nv-gb10-stubs.c}
STUBS_OBJ=${STUBS_OBJ:-$WORK/build/nv-gb10-stubs.o}
LINKED_OBJ=${LINKED_OBJ:-$WORK/build/nv-kernel-gb10.o}
# Unpredictable scratch directory: a PID-named path ($WORK/tmp/build-stubs.$$)
# is guessable, and mkdir -p would silently reuse a pre-planted directory
# (r14 u09 sec3 fixed the same shape in build-rmcore.sh). Created BEFORE the
# trap is installed, so cleanup never runs rm -rf on an unset name.
mkdir -p "$WORK/tmp"
SCRATCH=$(mktemp -d "$WORK/tmp/build-stubs.XXXXXXXX") || exit 1

# cleanup - remove this run's scratch files on exit.
# Time:  O(1) (a handful of files).
# Space: O(1).
cleanup() {
	rm -rf "$SCRATCH"
}
# EXIT always runs cleanup; HUP/QUIT/INT/TERM exit with the conventional
# 128+n status so the trap cannot clean up and then let the build carry on.
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 131' QUIT
trap 'exit 130' INT
trap 'exit 143' TERM

# The RM core's own compile flags, copied verbatim from the first "cc"
# line that compiles a file under src/libraries/libspdm/ in the
# orchestrator's verbose diagnostic log
# (<work>/logs/rmcore-arm64-diag-1.log, whose paths point at
# <work>/build/diag-rm - the flags are relative to src/nvidia and
# identical for the ogkm copy this script cd's into). -Werror is ours,
# on top: a stub whose prototype drifts from its header must fail the
# build, which is what tests/stubs_test.sh falsifies.
#
# The flags below are the ARCH-INDEPENDENT ones: today's one long
# string, cut into four fragments at the three points where the
# architecture decides.
#   HEAD  up to and including -DNV_BSD
#   MID   -DNV_ARCH_BITS=64 through -fno-stack-protector
#   TAIL  -fno-pic through -fdata-sections
#   END   the libspdm include paths, the second quoted -D and the
#         trailing warnings
# The aarch64 build is today's string, unchanged and in the same order:
# -DNV_AARCH64, then the AArch64 ISA flags -mgeneral-regs-only
# -march=armv8-a -mstrict-align -ffixed-x18, then -mno-outline-atomics.
# The amd64 build replaces -DNV_AARCH64 with -DNV_X86_64 (utils.mk in
# OGKM 580.178.04 defines -DNV_X86_64 and -DNV_ARCH_BITS=64) and the
# AArch64 ISA flags with the x86_64 kernel flags of OGKM 580.178.04's
# src/nvidia/Makefile (TARGET_ARCH=x86_64): -msoft-float -mno-red-zone
# -mcmodel=kernel -mno-mmx -mno-sse -mno-sse2 -mno-3dnow. amd64 has no
# -mno-outline-atomics counterpart, so that flag is dropped there.
# -mbranch-protection=standard is ours too: ld -r only emits the
# GNU_PROPERTY_AARCH64_FEATURE_1_BTI property when every input object
# carries it, and FreeBSD 16 arm64 links kernel modules with
# -zbti-report=error, so the stubs must have the same branch protection
# as the (patched) core they are linked onto. It is an AArch64 flag, so
# it is passed on aarch64 only. The two quoted -D values keep their
# quotes; the `eval "set -- ..."` below splits the flags into the
# positional parameters for cc exactly as the core's gmake shell did,
# and no other argument goes through eval.
RMCORE_FLAGS_HEAD='-Wall -fno-strict-aliasing -fno-omit-frame-pointer -Wformat=2 -Wno-unused-parameter -O2 -DNV_BSD'
RMCORE_FLAGS_MID='-DNV_ARCH_BITS=64 -include ../common/sdk/nvidia/inc/cpuopsys.h -I kernel/inc -I interface -I ../common/sdk/nvidia/inc -I ../common/sdk/nvidia/inc/hw -I arch/nvalloc/common/inc -I arch/nvalloc/common/inc/gsp -I arch/nvalloc/common/inc/deprecated -I arch/nvalloc/unix/include -I inc -I inc/os -I ../common/shared/inc -I ../common/shared/msgq/inc -I ../common/inc -I ../common/uproc/os/libos-v2.0.0/include -I ../common/uproc/os/common/include -I ../common/inc/swref -I ../common/inc/swref/published -I generated -I ../common/nvswitch/kernel/inc -I ../common/nvswitch/interface -I ../common/nvswitch/common/inc/ -I ../common/inc/displayport -I ../common/nvlink/interface/ -I ../common/nvlink/inband/interface -I src/mm/uvm/interface -I inc/libraries -I src/libraries -I inc/kernel -I ../common/mbedtls/3.6.2/include -I ../common/mbedtls/3.6.2/nvidia -D"MBEDTLS_USER_CONFIG_FILE=<nvrm_mbedtls_config.h>" -Werror-implicit-function-declaration -Wwrite-strings -Wundef -fno-common -ffreestanding -fno-stack-protector'
RMCORE_FLAGS_TAIL='-fno-pic -D_LANGUAGE_C -D__NO_CTYPE -DNVRM -DLOCK_VAL_ENABLED=0 -DPORT_ATOMIC_64_BIT_SUPPORTED=1 -DPORT_IS_KERNEL_BUILD=1 -DPORT_IS_CHECKED_BUILD=0 -DPORT_MODULE_atomic=1 -DPORT_MODULE_core=1 -DPORT_MODULE_cpu=1 -DPORT_MODULE_crypto=1 -DPORT_MODULE_debug=1 -DPORT_MODULE_memory=1 -DPORT_MODULE_safe=1 -DPORT_MODULE_string=1 -DPORT_MODULE_sync=1 -DPORT_MODULE_thread=1 -DPORT_MODULE_util=1 -DPORT_MODULE_example=0 -DPORT_MODULE_mmio=0 -DPORT_MODULE_time=0 -DRS_STANDALONE=0 -DRS_STANDALONE_TEST=0 -DRS_COMPATABILITY_MODE=1 -DRS_PROVIDES_API_STATE=0 -DNV_CONTAINERS_NO_TEMPLATES -DINCLUDE_NVLINK_LIB -DINCLUDE_NVSWITCH_LIB -DNV_PRINTF_STRINGS_ALLOWED=1 -DNV_ASSERT_FAILED_USES_STRINGS=1 -DPORT_ASSERT_FAILED_USES_STRINGS=1 -ffunction-sections -fdata-sections'
RMCORE_FLAGS_END='-I src/libraries/libspdm/3.5.0/include -I src/libraries/libspdm/3.5.0/include/hal -I src/libraries/libspdm/3.5.0/os_stub/include -I src/libraries/libspdm/3.5.0/os_stub -I src/libraries/libspdm/3.5.0/os_stub/cryptlib_null -I src/libraries/libspdm/nvidia -D"LIBSPDM_CONFIG=<nvspdm_rmconfig.h>" -Wstrict-prototypes -Wold-style-definition -Wno-format-zero-length --std=gnu11'

# Assemble the flag string for the architecture this run builds for.
# aarch64 reproduces today's string exactly; amd64 substitutes its own
# architecture macro and its own ISA flags (see above).
case $ARCH in
aarch64)
	RMCORE_FLAGS="$RMCORE_FLAGS_HEAD -DNV_AARCH64 $RMCORE_FLAGS_MID -mgeneral-regs-only -march=armv8-a -mstrict-align -ffixed-x18 $RMCORE_FLAGS_TAIL -mno-outline-atomics $RMCORE_FLAGS_END"
	BRANCH_PROTECTION='-mbranch-protection=standard'
	;;
amd64)
	RMCORE_FLAGS="$RMCORE_FLAGS_HEAD -DNV_X86_64 $RMCORE_FLAGS_MID -msoft-float -mno-red-zone -mcmodel=kernel -mno-mmx -mno-sse -mno-sse2 -mno-3dnow $RMCORE_FLAGS_TAIL $RMCORE_FLAGS_END"
	BRANCH_PROTECTION=''
	;;
esac

# Overrides may be relative; the compile below cd's into the ogkm tree,
# so make every path absolute now.
case $CORE_OBJ in /*) ;; *) CORE_OBJ=$PWD/$CORE_OBJ ;; esac
case $STUBS_SRC in /*) ;; *) STUBS_SRC=$PWD/$STUBS_SRC ;; esac
case $STUBS_OBJ in /*) ;; *) STUBS_OBJ=$PWD/$STUBS_OBJ ;; esac
case $LINKED_OBJ in /*) ;; *) LINKED_OBJ=$PWD/$LINKED_OBJ ;; esac

if [ ! -d "$OGKM/src/nvidia" ]; then
	echo "build-stubs: no ogkm copy at $OGKM (run scripts/build-rmcore.sh first)" >&2
	exit 1
fi
for f in "$CORE_OBJ" "$STUBS_SRC"; do
	if [ ! -f "$f" ]; then
		echo "build-stubs: missing $f" >&2
		exit 1
	fi
done

mkdir -p "$(dirname "$STUBS_OBJ")" "$(dirname "$LINKED_OBJ")"

cd "$OGKM/src/nvidia"
# eval splits RMCORE_FLAGS (whose quoted -D values must reach cc as one
# argument each) into the positional parameters ONCE; the source and object
# paths are then handed to cc as separate arguments and are never re-parsed
# by eval, so an override path holding a quote or a shell metacharacter
# cannot break the command line or inject a command.
eval "set -- $RMCORE_FLAGS"
# $BRANCH_PROTECTION holds -mbranch-protection=standard on aarch64 and
# nothing on amd64; an empty expansion adds no argument at all.
"$CC_PROG" "$@" $BRANCH_PROTECTION -Werror -c "$STUBS_SRC" -o "$STUBS_OBJ"
"$LD_PROG" -r -o "$LINKED_OBJ" "$CORE_OBJ" "$STUBS_OBJ"

_n=$(count_missing "$LINKED_OBJ" "$OSOBJDIR" "$SCRATCH")
if [ -z "$_n" ]; then
	echo "build-stubs: cannot count undefined symbols (no OS-layer objects in $OSOBJDIR, or nm failed)" >&2
	exit 1
fi
printf 'still undefined vs OS layer: %s\n' "$_n"
if [ "$_n" -ne 0 ]; then
	exit 1
fi
echo "build-stubs: $LINKED_OBJ ready"

#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-2-Clause
#
# build-probes.sh - build the native probes of the test-boot kit (Track #2362, #2437).
#
# usage: build-probes.sh LIBDIR OUTDIR [PROBE...]
#   LIBDIR   the directory holding libnvrm.so.1 (the library the probe is built against)
#   OUTDIR   where the probes are written
#   PROBE    the name of a probe to build (default: mem_probe and chan_probe); the source is
#            $REPO/tests/libnvrm/<probe>.c
#
# The compile line is the one of tests/libnvrm_test.sh: the same flags, the same library, the same
# thread library.  A probe of the kit is therefore the probe of the suite, and not a second copy of it.
#
# Exit: 0 when every probe is built, 2 on a usage error, 1 when a probe does not compile (the message
# names the probe).

set -eu
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL

PROBEDIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH= cd -- "$PROBEDIR/../.." && pwd)

usage()
{
	echo "usage: build-probes.sh LIBDIR OUTDIR [PROBE...]" >&2
	exit 2
}

[ $# -ge 2 ] || usage
LIBDIR=$1
OUTDIR=$2
shift 2
[ -d "$LIBDIR" ] || { echo "build-probes.sh: $LIBDIR is not a directory" >&2; usage; }
[ -n "$OUTDIR" ] || usage
[ $# -gt 0 ] || set -- mem_probe chan_probe

mkdir -p "$OUTDIR" || { echo "build-probes.sh: $OUTDIR cannot be made" >&2; exit 1; }

# build <probe>: compile one probe of the kit against the library in LIBDIR
# Time: O(1) per probe (one compile); Space: O(1) beyond the compiler's own scratch.
build()
{
	_p=$1
	[ -f "$REPO/tests/libnvrm/$_p.c" ] || { echo "build-probes.sh: the probe $_p has no source ($REPO/tests/libnvrm/$_p.c)" >&2; exit 1; }
	cc -I"$REPO/lib/libnvrm/include" -std=gnu11 -Wall -Wextra -Werror \
	    -o "$OUTDIR/$_p" "$REPO/tests/libnvrm/$_p.c" -L"$LIBDIR" -lnvrm -lthr || {
		echo "build-probes.sh: the probe $_p does not compile" >&2
		exit 1
	}
	echo "built $_p"
}

# Time: O(n) in the number of probes; Space: O(1) beyond the probes themselves.
for _probe in "$@"; do
	build "$_probe"
done

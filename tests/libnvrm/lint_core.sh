#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-2-Clause
#
# lint_core.sh DIR - the core must not name a chip or a family, and nothing
# may depend on Linux: refuses (rc 1) any hit in the core sources, the public
# header and the build files.  The generation table (nvrm_table.c), the fake
# backend's data and the RM backend's header-derived constants are the data
# and are exempt from the chip check; the Linux check covers every file but
# the man pages (which say the library needs no Linux layer).
DIR=$1
bad=0
[ -d "$DIR" ] || { echo "lint_core: no such directory $DIR" >&2; exit 1; }
# Exempt from the chip check, by name: the generation table and the fake
# backend's profile data (data), and the RM backend with its NVIDIA header
# constants.  Every other source and header is core and is checked, so a new
# file is covered by default.
EXEMPT=" nvrm_table.c nvrm_fake.c nvrm_rm.c nvrm_rm_sys.h "
CHIP='blackwell|hopper|ampere|ada[^a-z]|turing|volta|pascal|kepler|maxwell|gb[0-9]+|gh[0-9]+|ga[0-9]+|tu[0-9]+|0x10de|0x[cC][0-9a-fA-F]{3}'
n=0
for f in "$DIR"/*.c "$DIR"/*.h "$DIR"/include/nvrm/*.h; do
	[ -f "$f" ] || continue
	n=$((n + 1))
	case "$EXEMPT" in *" $(basename "$f") "*) continue ;; esac
	if grep -nE -i "$CHIP" "$f"; then
		echo "lint_core: chip or class id named in core file $f" >&2
		bad=1
	fi
done
[ "$n" -gt 0 ] || { echo "lint_core: no sources in $DIR" >&2; exit 1; }
for f in "$DIR"/*.c "$DIR"/*.h "$DIR"/include/nvrm/*.h "$DIR"/Makefile "$DIR"/nvrm-info/*.c "$DIR"/nvrm-info/Makefile; do
	[ -f "$f" ] || continue
	if grep -nEi 'linux|linuxkpi|compat/linux|nouveau' "$f"; then
		echo "lint_core: Linux or nouveau referenced in $f" >&2
		bad=1
	fi
done
exit $bad

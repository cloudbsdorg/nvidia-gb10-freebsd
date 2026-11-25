#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-2-Clause
#
# lint_core.sh DIR - the core must not name a chip or a family, and nothing
# may depend on Linux: refuses (rc 1) any hit in the core sources, the public
# header and the build files.  The chip family table (nvrm_table.c), the fake
# backend's data and channel model, and the RM backend's header-derived
# constants are the data and are exempt from the chip check; the Linux check
# covers every file but the man pages (which say the library needs no Linux
# layer).
#
# A chip family is named by its chip prefix and a digit (GA10x, GH100, GB20x
# and the rest), and the marketing name of a generation (Ampere, Blackwell,
# ...) is never a name here: both are refused.  The check matches whole
# words, so an ordinary identifier that happens to hold the same letters
# (read1024, payload123) is not a chip and is not refused.
DIR=$1
bad=0
[ -d "$DIR" ] || { echo "lint_core: no such directory $DIR" >&2; exit 1; }
# Exempt from the chip check, by name: the chip family table and the fake
# backend's profile data and channel model and its header (data), and the RM backend with its
# NVIDIA header constants.  Every other source and header is core and is checked,
# so a new file is covered by default.
EXEMPT=" nvrm_table.c nvrm_fake.c nvrm_fake_chan.c nvrm_fake.h nvrm_rm.c nvrm_rm_sys.h "
B='[[:<:]]'
E='[[:>:]]'
# the marketing names of the generations: never a name of a chip or a family
MARKETING='blackwell|hopper|ampere|ada|turing|volta|pascal|kepler|maxwell'
# the chip codes: the prefix of the chip and its digits, with the x of a
# family name (GA10x).  Whole words only.
CHIP="${B}(${MARKETING})${E}|${B}(ga|gb|gh|ad|tu|gm|gp|gv)[0-9]+x?${E}|0x10de|0x[cC][0-9a-fA-F]{3}"
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
# The published values: the row names of the chip family table are chip
# families, never a marketing name of a generation.  They are the values
# nvrm-info publishes, so the naming rule applies to them as well.
if [ -f "$DIR/nvrm_table.c" ]; then
	for _n in $(sed -n 's/^[[:space:]]*{[[:space:]]*"\([^"]*\)".*/\1/p' \
	    "$DIR/nvrm_table.c"); do
		case $(printf '%s' "$_n" | tr 'A-Z' 'a-z') in
		ga[0-9]*|gb[0-9]*|gh[0-9]*|ad[0-9]*|tu[0-9]*|gm[0-9]*|gp[0-9]*|gv[0-9]*)
			;;
		*)
			echo "lint_core: the published family value '$_n' is not a chip family" >&2
			bad=1
			;;
		esac
	done
fi
[ "$n" -gt 0 ] || { echo "lint_core: no sources in $DIR" >&2; exit 1; }
for f in "$DIR"/*.c "$DIR"/*.h "$DIR"/include/nvrm/*.h "$DIR"/Makefile "$DIR"/nvrm-info/*.c "$DIR"/nvrm-info/Makefile; do
	[ -f "$f" ] || continue
	if grep -nEi 'linux|linuxkpi|compat/linux|nouveau' "$f"; then
		echo "lint_core: Linux or nouveau referenced in $f" >&2
		bad=1
	fi
done
exit $bad

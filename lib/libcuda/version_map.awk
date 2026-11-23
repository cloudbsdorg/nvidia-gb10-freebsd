#
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-2-Clause
#
# The one parser for Version.map.  The man-link name list and the proc-table
# include are two modes of this helper, so the two build-time readings of the
# version script cannot drift apart.
#
#	mode=names    one exported symbol per line
#	mode=include  the proc-table entries for cuda_exports.inc
#
# An entry is recognized by its shape, not by the exact indentation, so a
# version script written with spaces parses like one written with tabs.
#
BEGIN {
	mode = (mode == "" ? "names" : mode)
	inside = 0
}

{
	line = $0
	sub(/\r$/, "", line)
	if (line ~ /^[ \t]*CUDA_1\.0[ \t]*\{/) {
		inside = 1
		next
	}
	if (line ~ /^[ \t]*\}/) {
		inside = 0
		next
	}
	if (!inside)
		next
	if (line !~ /^[ \t]*[A-Za-z_][A-Za-z0-9_]*[ \t]*;[ \t]*$/)
		next
	name = line
	sub(/^[ \t]+/, "", name)
	sub(/[ \t]*;.*$/, "", name)
	if (mode == "include") {
		if (name == "cuGetProcAddress") {
			printf "\t{ \"%s\", (void *)&%s_v2,\n", name, name
			printf "\t    (void *)&%s, 12000 },\n", name
		} else {
			printf "\tPROC_ENTRY(%s),\n", name
		}
	} else {
		print name
	}
}

# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-2-Clause
#
# bare-shutdown-check.sh - the one bare-shutdown detector of the native-tools test-boot kit.  It is dot-sourced by
# check-be.sh and by tests/native_tools_kit_test.sh (never installed on the target boot environment on its own).
#
#   bare_shutdown_lines FILE   prints the lines of FILE that call shutdown other than through the guarded variable;
#                              prints nothing when FILE is clean.
#
# Rules: comment lines are removed; only the two allowlisted lines are removed (the nvidia_native_tools_testboot_real_shutdown=
# assignment and the one line that calls "$nvidia_native_tools_testboot_shutdown" -r); on row, echo and printf lines the quoted
# arguments (messages) are dropped.  Everything else, quoted or not, is searched for the token shutdown as a command word: at
# the start of a line, or after ; & | ( { ! or one of if then else do while until exec command nohup time eval env xargs
# sudo doas "sh -c" "bash -c", or followed by a flag (-r -h -p -k now +N).
bare_shutdown_lines() {
	grep -v '^[[:space:]]*#' "$1" \
	    | grep -v '^[[:space:]]*nvidia_native_tools_testboot_real_shutdown=/sbin/shutdown[[:space:]]*$' \
	    | grep -v '^[[:space:]]*"\$nvidia_native_tools_testboot_shutdown" -r ' \
	    | sed -E -e '/^[[:space:]]*(row|echo|printf)[[:space:]]/{s/"[^"]*"//g;s/'"'"'[^'"'"']*'"'"'//g;}' \
	    | grep -E -e '(^|[;&|({!]|[^A-Za-z0-9_](if|then|else|do|while|until|exec|command|nohup|time|eval|env|xargs|sudo|doas)|(sh|bash)[[:space:]]+-c)[[:space:]]*["'"'"']?[[:space:]]*shutdown([^A-Za-z0-9_]|$)' \
	    -e '(^|[^A-Za-z0-9_])shutdown[[:space:]]+(-[rhpk]|now|\+[0-9])'
	return 0
}

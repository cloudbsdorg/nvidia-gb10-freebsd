# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# bare-shutdown-check.sh - the one bare-shutdown detector of this kit.  Dot-sourced
# by the host test and (where the kit has one) by check-be.sh; never run alone.
#
# bare_shutdown_lines FILE prints every line of the recorder FILE that may call
# shutdown(8) other than through "$linux_bridge_testboot_shutdown"; empty output = clean.
#
# What is removed before the search: comment lines; the two allowlisted lines (the
# linux_bridge_testboot_real_shutdown= assignment and the one line that calls
# "$linux_bridge_testboot_shutdown" -r); and the quoted arguments of lines that start with row,
# echo or printf (messages).  Everything else, quoted or not (sh -c "...", eval '...',
# a variable assignment), is searched for the word shutdown as a command word: at the
# start of a line, after if/then/else/do/while/until/!/{/(/;/&&/||/|, after
# exec/command/nohup/time/eval/env/xargs/sudo/doas (optionally with sh -c or bash -c
# and an opening quote), or followed by a -x flag, now or +N.
bare_shutdown_lines()
{
	[ -r "$1" ] || { printf '%s\n' "cannot read $1"; return 0; }
	sed -E -e '/^[[:space:]]*#/d' \
	    -e '/^linux_bridge_testboot_real_shutdown=\/sbin\/shutdown$/d' \
	    -e '/^[[:space:]]*"\$linux_bridge_testboot_shutdown" -r /d' \
	    -e '/^[[:space:]]*(row|echo|printf)[[:space:]]/{
s/"[^"]*"//g
s/'"'"'[^'"'"']*'"'"'//g
}' "$1" |
	    grep -E -e '(^|[;&|!{(])[[:space:]]*shutdown([^A-Za-z0-9_]|$)' \
		-e '(^|[[:space:]])(if|then|else|do|while|until|exec|command|nohup|time|eval|env|xargs|sudo|doas)[[:space:]]+["'"'"'(]?[[:space:]]*shutdown([^A-Za-z0-9_]|$)' \
		-e '(sh|bash)[[:space:]]+-c[[:space:]]+["'"'"']?[[:space:]]*shutdown([^A-Za-z0-9_]|$)' \
		-e '(^|[^A-Za-z0-9_$])shutdown[[:space:]]+(-[A-Za-z]|now|\+[0-9])' || true
}

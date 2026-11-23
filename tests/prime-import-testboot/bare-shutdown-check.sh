# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# bare-shutdown-check.sh - the one bare-shutdown detector of this kit.  It is
# dot-sourced by the host test (and by check-be.sh where a kit has one); it is
# never run on its own and is not installed on the target boot environment.
#
# bare_shutdown_lines FILE: prints the lines of the rc script FILE that call
# shutdown(8) by name, numbered.  An empty output means clean.  What is
# removed before looking:
#   - comment lines;
#   - the two allowlisted lines: the <kit>_real_shutdown=/sbin/shutdown
#     assignment and the one line that calls "$<kit>_shutdown" -r;
#   - the quoted text of row, echo and printf lines (the messages).
# Everything else, quoted or not, is searched for shutdown as a command word:
# at the start of a line, after if/then/else/do/while/until/!/{/(/;/&&/||/|,
# after exec/command/nohup/time/eval/env/xargs/sudo/doas, after sh -c or
# bash -c (a quote may follow), or followed by a flag (-r, -h, -p, now, +N).
bare_shutdown_lines() {
	sed -E -e '/^[[:space:]]*#/d' \
	    -e '/^[A-Za-z0-9_]*_real_shutdown=\/sbin\/shutdown$/d' \
	    -e '/^[[:space:]]*"\$[A-Za-z0-9_]*_shutdown" -r /d' \
	    -e '/^[[:space:]]*(row|echo|printf)[[:space:]]/{s/"[^"]*"//g;s/'"'"'[^'"'"']*'"'"'//g;}' "$1" |
	    grep -nE '(^|[;&|({!]|[[:<:]](if|then|else|do|while|until|exec|command|nohup|time|eval|env|xargs|sudo|doas)|[[:<:]](sh|bash|dash|zsh)[[:space:]]+-c|[[:<:]]eval)[[:space:]]*["'"'"']?[[:space:]]*(/sbin/|/usr/sbin/)?[[:<:]]shutdown[[:>:]]|[[:<:]]shutdown[[:>:]][[:space:]]+(-[rhp]|now|\+[0-9])'
}

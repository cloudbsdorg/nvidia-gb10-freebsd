#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# gpu-mock-up.sh - the one switch of the GPU mock: GPU_MOCK=<model> starts the
# daemon, sets up the devfs rules of the nodes and points the seam at the
# model.
#
# usage: gpu-mock-up.sh up [model] | down
#
# The model is the value of GPU_MOCK, else the argument.  The three parts:
#
#   the daemon   the mock publishes /dev/nvidiactl, one node per card of
#                the model, /dev/nvidia_modeset and /dev/nvidia_uvm with
#                cuse(3).  It needs the cuse module and the right to open
#                /dev/cuse.
#   the devfs    the rules of the nodes are written in a ruleset file (a
#                fragment of /etc/devfs.rules, for a jail or for the boot of
#                this machine) and put in force here before the daemon makes
#                the nodes, so the nodes are created with the mode and the
#                group of the rules.
#   the seam     the pciconf, devinfo and hw.nvidia / dev.nvidia answers
#                come from the same model: the mock tool answers them, and
#                the seam shim gives them to a program that reads the
#                hardware through the system calls.
#
# Nothing here loads a kernel module and nothing here is a hardware result:
# every answer of the mock says it is a mock.

set -u

here=$(dirname "$0")
root=$(cd "$here/.." && pwd)
bin=${GPU_MOCK_BIN:-$root/src/gb10-gpu-mock/build/gpu-mock}
shim=${GPU_MOCK_SHIM:-$root/src/gb10-gpu-mock/build/libgpubmockshim.so}
models=${GPU_MOCK_DIR:-$root/data/models}
installed=/usr/local/share/nvidia-gb10-freebsd/models
prefix=${GPU_MOCK_PREFIX:-nvidia}
# The files of the mock carry the names of its nodes, so two mocks side by
# side do not write over each other.  The pid file is the exception: it is
# the registry of every mock that runs on this machine.
pidfile=${GPU_MOCK_PIDFILE:-/var/run/gpu-mock.pid}
statefile=${GPU_MOCK_STATEFILE:-/var/run/gpu-mock-$prefix.model}
rules=${GPU_MOCK_RULES:-/var/run/gpu-mock-$prefix.rules}
log=${GPU_MOCK_LOG:-/var/run/gpu-mock-$prefix.log}
# The token of this run: the daemon writes it in the pid file, so the switch
# knows which daemon of the file is its own.
token="$$-$(date +%s 2>/dev/null || echo run)"

# The daemon and the tool must name the nodes the same way.
export GPU_MOCK_PREFIX="$prefix"

usage() {
	echo "usage: gpu-mock-up.sh up [model] | down" >&2
	echo "" >&2
	echo "  up [model]   start the daemon, set up the devfs rules and the seam" >&2
	echo "  down         stop the daemon and take the rules away" >&2
	exit 2
}

# root_cmd: run a command as root: directly when this user is root, else
# through doas(1) or sudo(8) when one of them is set up for this user.  The
# daemon opens /dev/cuse and the devfs rules are the rules of the kernel:
# both need root.
root_cmd() {
	if [ "$(id -u)" = 0 ]; then
		"$@"
		return $?
	fi
	if command -v doas >/dev/null 2>&1 && doas -n true >/dev/null 2>&1; then
		doas -n "$@"
		return $?
	fi
	if command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
		sudo -n "$@"
		return $?
	fi
	echo "gpu-mock-up.sh: this needs root: the daemon opens /dev/cuse and" >&2
	echo "     the devfs rules are the rules of the kernel.  Run this as" >&2
	echo "     root, or set up doas(1) or sudo(8) for $(id -un)." >&2
	return 1
}

# root_bg_cmd: run a command as root in the background and come straight
# back.  The command is a plain command and never a function: the shell of
# a script waits for a backgrounded function (the function runs in a
# subshell that doas(1) keeps alive), and a caller that reads the output of
# this script would then wait for the daemon to leave.
root_bg_cmd() {
	if [ "$(id -u)" = 0 ]; then
		"$@" >/dev/null 2>&1 &
	else
		doas -n "$@" >/dev/null 2>&1 &
	fi
}

# write_root_file PATH CONTENT: a file of the system, written as root.
write_root_file() {
	printf '%s\n' "$2" | root_cmd tee "$1" >/dev/null 2>&1
}

# the_nodes: the names of the nodes of the ruleset file, one per line.
the_nodes() {
	[ -f "$rules" ] || return 0
	awk '/^add path/ { gsub(/\047/, "", $3); print $3 }' "$rules"
}

case "${1:-}" in
up) ;;
down) ;;
*) usage ;;
esac

if [ ! -x "$bin" ]; then
	echo "gpu-mock-up.sh: the mock is not built: $bin" >&2
	echo "gpu-mock-up.sh: build it with 'sh scripts/gpu-mock.sh build'" >&2
	exit 1
fi

if [ "$1" = down ]; then
	# The daemon: the pid file holds the pid of every mock that runs and
	# the names of its nodes, so the mock with these names is found there.
	# The helper that started it is another process, and its pid is not
	# the pid of the daemon.
	pid=
	[ -f "$pidfile" ] &&
	    pid=$(awk -v p="$prefix" '$2 == p { print $1; exit }' "$pidfile" 2>/dev/null)
	if [ -n "$pid" ]; then
		kill "$pid" 2>/dev/null || root_cmd kill -TERM "$pid" 2>/dev/null
		i=0
		while [ $i -lt 100 ] && kill -0 "$pid" 2>/dev/null; do
			sleep 0.1
			i=$((i + 1))
		done
		if kill -0 "$pid" 2>/dev/null; then
			root_cmd kill -KILL "$pid" 2>/dev/null
		fi
	fi
	rm -f "$statefile" 2>/dev/null || root_cmd rm -f "$statefile" 2>/dev/null
	# The pid file keeps the lines of the other mocks: the daemon takes
	# its own line away when it stops.
	# The rules of the nodes: the rules that were put in force here are
	# taken away, so the machine is as it was.
	for node in $(the_nodes); do
		for num in $(root_cmd /sbin/devfs rule show 2>/dev/null |
		    awk -v p="$node" '$2 == "path" && $3 == p { print $1 }'); do
			root_cmd /sbin/devfs rule del "$num" 2>/dev/null
		done
	done
	echo "gpu-mock: the daemon is stopped (mock; not hardware)"
	exit 0
fi

model=${2:-${GPU_MOCK:-}}
if [ -z "$model" ]; then
	echo "gpu-mock-up.sh: no model: pass one, or set GPU_MOCK" >&2
	exit 1
fi

# The file of the model: a path, or a name under a model directory.
modelfile=
if [ -f "$model" ]; then
	modelfile=$model
else
	for d in "$models" "$installed"; do
		if [ -f "$d/$model.json" ]; then
			modelfile=$d/$model.json
			break
		fi
	done
fi
if [ -z "$modelfile" ]; then
	echo "gpu-mock-up.sh: no model file for \"$model\" under $models" >&2
	exit 1
fi
# The seam and the daemon must find the model and the files it includes.
export GPU_MOCK_DIR="$(dirname "$modelfile")"

if [ ! -c /dev/cuse ]; then
	echo "gpu-mock-up.sh: /dev/cuse is missing: the cuse module is not" >&2
	echo "     loaded (kldstat -m cuse), or this user may not open it" >&2
	exit 1
fi

# The rules of the nodes: a ruleset file (a fragment of /etc/devfs.rules,
# for a jail or for the boot of this machine) and the rules in force here.
"$bin" nodes "$model" 2>/dev/null | root_cmd tee "$rules" >/dev/null || {
	echo "gpu-mock-up.sh: the ruleset file could not be written: $rules" >&2
	exit 1
}
if [ ! -s "$rules" ]; then
	echo "gpu-mock-up.sh: the ruleset of the nodes is empty: $rules" >&2
	exit 1
fi
# The rules are in force before the daemon makes the nodes, so the nodes are
# created with the mode and the group of the rules.
for node in $(the_nodes); do
	root_cmd /sbin/devfs rule add path "$node" mode 0660 group video ||
	    echo "gpu-mock-up.sh: the rule for $node was not added" >&2
done

# The daemon: it publishes the nodes and stays up.  The names of the nodes
# and the model travel with the command: doas(1) and sudo(8) reset the
# environment of the command they run, so the daemon would not see them
# otherwise.  The output of the background job goes nowhere: the daemon
# holds the terminal of this script otherwise, and a caller that reads our
# output would wait for the daemon to leave.
root_bg_cmd env GPU_MOCK_PREFIX="$prefix" GPU_MOCK_DIR="$GPU_MOCK_DIR" \
    GPU_MOCK_PIDFILE="$pidfile" GPU_MOCK_TOKEN="$token" \
    sh -c 'exec "$0" daemon "$1" >"$2" 2>&1' "$bin" "$model" "$log"
i=0
control=/dev/${prefix}ctl
while [ $i -lt 100 ] && [ ! -c "$control" ]; do
	sleep 0.1
	i=$((i + 1))
done
# The daemon of this run must be in the pid file with the token of this
# run: the control node may belong to another mock (the daemon refuses to
# start when another one holds the same names, and that node is there).
pid=
[ -f "$pidfile" ] &&
    pid=$(awk -v t="$token" '$3 == t { print $1; exit }' "$pidfile" 2>/dev/null)
if [ ! -c "$control" ] || [ -z "$pid" ]; then
	echo "gpu-mock-up.sh: the daemon did not publish the nodes" >&2
	[ -f "$log" ] && tail -5 "$log" >&2
	# A daemon that did not publish its nodes is stopped: it must not
	# hold the names of the nodes.  Only the daemon of this run is
	# stopped: the token of the file tells it from another mock (the
	# daemon refuses to start when another one holds the same names,
	# and that mock keeps its nodes).
	if [ -n "$pid" ]; then
		root_cmd kill -TERM "$pid" 2>/dev/null
	fi
	# The rules of the nodes go away with it: the machine is as it was.
	for node in $(the_nodes); do
		for num in $(root_cmd /sbin/devfs rule show 2>/dev/null |
		    awk -v p="$node" '$2 == "path" && $3 == p { print $1 }'); do
			root_cmd /sbin/devfs rule del "$num" 2>/dev/null
		done
	done
	exit 1
fi
write_root_file "$statefile" "$model"

# The seam: the answers of the model, for the tools that read the hardware
# through the system calls.
echo "gpu-mock: the model is $model ($modelfile)"
echo "gpu-mock: the nodes are published: $control and the other nodes of the model"
echo "gpu-mock: the rules of the nodes: $rules (a fragment of /etc/devfs.rules)"
echo "gpu-mock: the log of the daemon: $log"
echo "gpu-mock: export GPU_MOCK=$model GPU_MOCK_DIR=$(dirname "$modelfile")"
echo "gpu-mock: export LD_PRELOAD=$shim for a program that reads the hardware"
echo "gpu-mock: the daemon is $pid (the pid file is $pidfile)"
exit 0

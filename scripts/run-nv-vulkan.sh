#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# run-nv-vulkan.sh - run the Linux aarch64 Vulkan userspace against the
# NVIDIA card through the Linuxulator, from private Linux roots of their own
# (nothing in /compat/linux is touched).
#
# Usage: run-nv-vulkan.sh vulkaninfo | list | bench [model.gguf] [options...]
#        run-nv-vulkan.sh server MODEL [llama-server options...]
#        run-nv-vulkan.sh llama-bench [llama-bench options...]
#        run-nv-vulkan.sh rpc [ggml-rpc-server options...]
#
# Environment:
#   GB10_WORK  work root (default <repo>/work). It holds:
#                linuxroot/nv/     NVIDIA user libraries (580.178.04), the
#                                  Vulkan ICD file nvidia_icd.json and the
#                                  EGL vendor file 10_nvidia.json
#                linuxroot/rl9/   Rocky 9: Vulkan loader 1.4, vulkaninfo,
#                                  libglvnd, libX11/Xext/xcb/Xau, libffi,
#                                  libwayland-client
#                linuxroot/noble/ Ubuntu 24.04: glibc 2.39, libstdc++ 14,
#                                  libgomp, Vulkan loader 1.3, vulkaninfo,
#                                  X11/glvnd libraries: what the official
#                                  llama.cpp ubuntu-vulkan-arm64 build needs
#                                  (GLIBC_2.38)
#                llm/llama-vulkan-arm64/llama-b12531/  the llama.cpp build
#                models/             the default model for bench
#
# The modes:
#   vulkaninfo  the Rocky Vulkan loader and vulkaninfo against the ICD
#   list        llama-bench --list-devices
#   bench       llama-bench with one model, prompt 512 and 128 tokens; the
#               options that follow the model are passed on to llama-bench,
#               and a default is added only for the flags the options do
#               not give themselves
#   server      llama-server with one model and the given options
#   llama-bench llama-bench with the given options (the model is yours to
#               pass; give an absolute path)
#   rpc         ggml-rpc-server with the given options
#
# Only "bench" and "server" take a model.  In the other modes the second
# argument is one of the program's own options and is passed on unchanged.
# "vulkaninfo" is the one exception: it runs "vulkaninfo --summary" when it
# is given no arguments of its own, and the arguments it is given are passed
# on instead of --summary.
#
# llama-bench APPENDS -m, -p, -n, -ngl and -fa to a list: a flag given
# twice does not override the first one, it adds a second run.  So the
# defaults of "bench" (-p 512, -n 128, -ngl 99, -fa 0,1) are added only for
# the flags the options do not give, and a -m in the options of "bench" or
# "server" is refused: the model is that mode's own argument, and two
# models would both be run.
#
# History: early nvidia.ko builds mapped the BAR0 window write-back, so every
# Vulkan command died with SIGBUS on its first read of the USERMODE register
# window; the memory-attribute rule of this repository fixes that.
#
# Detached use (daemon(8), rc scripts, cron): every mode runs from the llama
# directory, because ggml finds its backends (libggml-vulkan.so,
# libggml-cpu-*.so, libggml-rpc.so) next to the executable and in the current
# directory, and the "executable" here is ld-linux-aarch64.so.1 from
# noble/lib, so only the cwd search finds them.  daemon(8) chdirs to /, and
# from there llama-server reports "no usable GPU found" or "no backends are
# loaded".  Relative paths in the llama-server options are therefore taken
# from the llama directory; pass absolute ones.  The model path itself is
# made absolute against the directory the script was started from.
#
# The NVIDIA Vulkan ICD initialises through libEGL (glvnd); without the
# vendor file libEGL finds no NVIDIA vendor, vk_icdGetInstanceProcAddr
# returns NULL and the loader says "Could not get 'vkCreateInstance' via
# 'vk_icdGetInstanceProcAddr' for ICD libGLX_nvidia.so.0" / "Found no
# drivers!".  Any launcher that bypasses this script must set both.
#
# Exit: 0 the command ran; 1 a path is missing; 2 an unknown mode, a missing
#       argument, an option the mode does not take, or HOME is not set.

set -eu

PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL

usage() {
	cat <<'EOF'
Usage:
  run-nv-vulkan.sh vulkaninfo [vulkaninfo options...]
  run-nv-vulkan.sh list [llama-bench options...]
  run-nv-vulkan.sh bench [model.gguf] [llama-bench options...]
  run-nv-vulkan.sh server MODEL [llama-server options...]
  run-nv-vulkan.sh llama-bench [llama-bench options...]
  run-nv-vulkan.sh rpc [ggml-rpc-server options...]

The options of "bench" are passed on to llama-bench after its defaults
(-p 512 -n 128 -ngl 99 -fa 0,1).  llama-bench appends -p, -n, -ngl and -fa
to a list, so a default is added only for the flags your options do not
give themselves.

"vulkaninfo" runs vulkaninfo --summary when it is given no options, and
the options it is given instead.

Environment:
  GB10_WORK  work root and default model parent (default <repo>/work)
EOF
}

# has_flag FLAG [ARG...] - true when one of the arguments is the flag.
# llama-bench takes "-p 512" and "-p=512"; both count as the flag.
# Time:  O(number of arguments).
# Space: O(1).
has_flag() {
	_flag=$1
	shift
	for _arg in "$@"; do
		case $_arg in
		"$_flag" | "$_flag="*) return 0 ;;
		esac
	done
	return 1
}

case ${1:-} in
-h | --help)
	usage
	exit 0
	;;
esac

WORK=${GB10_WORK:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)/work}
DEFAULT_MODEL=$WORK/models/Llama-3.2-3B-Instruct-Q4_K_M.gguf

R=$WORK/linuxroot
LL=$WORK/llm/llama-vulkan-arm64/llama-b12531
# The directory the script was started from: a relative model path belongs to
# it, not to the llama directory the script changes into below.
CWD=$(pwd)

[ -d "$R/noble" ] && [ -d "$LL" ] || { echo "missing $R/noble or $LL" >&2; exit 1; }
cd "$LL"

for f in "$R/nv/nvidia_icd.json" "$R/nv/10_nvidia.json"; do
	[ -f "$f" ] || { echo "missing $f" >&2; exit 1; }
done
export VK_DRIVER_FILES=$R/nv/nvidia_icd.json
export __EGL_VENDOR_LIBRARY_FILENAMES=$R/nv/10_nvidia.json
export VK_LOADER_DEBUG=${VK_LOADER_DEBUG:-error}
# GGML_BACKEND_PATH names ONE backend library and stops ggml loading the
# rest (no CPU backend: "CPU backend is not loaded"), so clear it.
unset GGML_BACKEND_PATH

case ${1:-} in
vulkaninfo)
	# Rocky loader + vulkaninfo against the ICD (glibc 2.34 from /compat/linux).
	# The options are passed on; --summary is the default when there are
	# none.
	shift 1
	[ "$#" -gt 0 ] || set -- --summary
	LD_LIBRARY_PATH=$R/rl9/usr/lib64:$R/nv exec "$R/rl9/usr/bin/vulkaninfo" "$@"
	;;
list)
	# The options are passed on after --list-devices.
	shift 1
	exec "$R/noble/lib/ld-linux-aarch64.so.1" \
	    --library-path "$R/noble/lib/aarch64-linux-gnu:$LL:$R/nv" \
	    "$LL/llama-bench" --list-devices "$@"
	;;
bench)
	# llama-bench with one model: the second argument is the model, the
	# arguments after it are llama-bench's own options.
	# ${1-"$DEFAULT_MODEL"} (not ${1:-...}) tells "not given" from "given and
	# empty": an empty model is a missing argument, not the default one.
	shift 1
	MODEL=${1-"$DEFAULT_MODEL"}
	[ -n "$MODEL" ] || { echo "bench needs a model" >&2; exit 2; }
	case $MODEL in /*) ;; *) MODEL=$CWD/$MODEL ;; esac
	[ -f "$MODEL" ] || { echo "no model: $MODEL" >&2; exit 1; }
	if [ "$#" -ge 1 ]; then
		shift 1
	fi
	# The model is this mode's own argument: a -m in the options would add
	# a second model and llama-bench would run both.  llama-bench takes the
	# long names too, so each check covers both spellings.
	if has_flag -m "$@" || has_flag --model "$@"; then
		echo "bench takes the model as its argument; -m is not allowed here" >&2
		exit 2
	fi
	# The defaults are added only for the flags the options do not give:
	# llama-bench appends -p, -n, -ngl and -fa to a list, so a default
	# that is given as well would run the same test twice.  They are
	# prepended in reverse order, so they end up in front of the options
	# in the order -p, -n, -ngl, -fa.
	has_flag -fa "$@" || has_flag --flash-attn "$@" || set -- -fa 0,1 "$@"
	has_flag -ngl "$@" || has_flag --n-gpu-layers "$@" || set -- -ngl 99 "$@"
	has_flag -n "$@" || has_flag --n-gen "$@" || set -- -n 128 "$@"
	has_flag -p "$@" || has_flag --n-prompt "$@" || set -- -p 512 "$@"
	exec "$R/noble/lib/ld-linux-aarch64.so.1" \
	    --library-path "$R/noble/lib/aarch64-linux-gnu:$LL:$R/nv" \
	    "$LL/llama-bench" -m "$MODEL" "$@"
	;;
server)
	# llama-server on the NVIDIA card; the remaining arguments go to it
	[ "$#" -ge 2 ] || { echo "server needs a model" >&2; exit 2; }
	MODEL=$2
	[ -n "$MODEL" ] || { echo "server needs a model" >&2; exit 2; }
	case $MODEL in /*) ;; *) MODEL=$CWD/$MODEL ;; esac
	shift 2
	# The model is this mode's own argument: a -m in the options would
	# silently replace it (llama-server keeps the last -m), so it is refused.
	if has_flag -m "$@" || has_flag --model "$@"; then
		echo "server takes the model as its argument; -m is not allowed here" >&2
		exit 2
	fi
	exec "$R/noble/lib/ld-linux-aarch64.so.1" \
	    --library-path "$R/noble/lib/aarch64-linux-gnu:$LL:$R/nv" \
	    "$LL/llama-server" -m "$MODEL" "$@"
	;;
llama-bench)
	# llama-bench with any arguments (absolute model paths); no model is
	# added here, the second argument is one of llama-bench's own options.
	shift 1
	exec "$R/noble/lib/ld-linux-aarch64.so.1" \
	    --library-path "$R/noble/lib/aarch64-linux-gnu:$LL:$R/nv" \
	    "$LL/llama-bench" "$@"
	;;
rpc)
	# ggml RPC server on the NVIDIA card; the remaining arguments go to it
	shift 1
	exec "$R/noble/lib/ld-linux-aarch64.so.1" \
	    --library-path "$R/noble/lib/aarch64-linux-gnu:$LL:$R/nv" \
	    "$LL/ggml-rpc-server" "$@"
	;;
*)
	echo "usage: $0 vulkaninfo | list | bench [model.gguf] | server MODEL [options] | llama-bench [options] | rpc [options]" >&2
	exit 2
	;;
esac

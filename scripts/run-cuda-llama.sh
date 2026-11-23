#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# run-cuda-llama.sh - run the official llama.cpp ubuntu-cuda-13.5-arm64 build
# on the RTX 5060 Ti: Linux aarch64 CUDA user space through the Linuxulator,
# the CUDA shim preloaded, NVIDIA's Linux libcuda, uvm-bsd in the kernel.
#
# Usage: scripts/run-cuda-llama.sh PROG [ARGS...]
#        PROG is a program from the llama.cpp release directory, for example
#        llama-bench, llama-cli or llama-server.
#
# Environment:
#   GB10_WORK  work root (default <repo>/work)
#   LL         llama.cpp CUDA release directory, with the cudart and cuBLAS
#              libraries merged in (default $GB10_WORK/llm/cuda/llama-b12531-cuda/llama-b12531)
#   SHIMDIR    directory holding shim.so (default $GB10_WORK/build/linux-cuda)
#
# Exit status: that of PROG; 2 usage; 1 a path is missing.
set -eu

case "${1:-}" in
-h | --help)
	sed -n '5,/^# Exit status/p' "$0" | sed 's/^# \{0,1\}//'
	exit 0
	;;
"")
	echo "usage: $0 PROG [ARGS...]" >&2
	exit 2
	;;
esac
W=${GB10_WORK:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)/work}
R=$W/linuxroot
LL=${LL:-$W/llm/cuda/llama-b12531-cuda/llama-b12531}
SHIMDIR=${SHIMDIR:-$W/build/linux-cuda}
CACHE=${HOME:-$W}/.cache/sa
prog=$1
shift
for f in "$R/noble/lib/ld-linux-aarch64.so.1" "$SHIMDIR/shim.so" "$LL/$prog" "$LL/libggml-cuda.so" "$LL/libcudart.so.13" "$R/nv/libcuda.so.1"; do
	[ -e "$f" ] || { echo "run-cuda-llama: missing $f" >&2; exit 1; }
done
mkdir -p "$CACHE"
printf '65536\n' > "$CACHE/mmap_min_addr.txt"
printf 'cuda\n' > "$CACHE/comm.txt"
SHIM_MMAP_MIN_ADDR=$CACHE/mmap_min_addr.txt SHIM_COMM=$CACHE/comm.txt SHIM_ABSTRACT_DIR=$CACHE
export SHIM_MMAP_MIN_ADDR SHIM_COMM SHIM_ABSTRACT_DIR
# GGML_BACKEND_PATH names ONE backend library and stops ggml loading the rest.
unset GGML_BACKEND_PATH
# ggml finds its backends next to the loader and in the cwd; the loader is ld.so
# from noble/lib, so only the cwd search finds them.
cd "$LL"
exec "$R/noble/lib/ld-linux-aarch64.so.1" --preload "$SHIMDIR/shim.so" \
    --library-path "$R/noble/lib/aarch64-linux-gnu:$LL:$R/nv" "$LL/$prog" "$@"

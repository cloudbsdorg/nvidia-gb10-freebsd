#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# bench-report.sh - run the report llama-bench set on the RTX 5060 Ti with one
# backend and leave one JSON file per model in a run directory.
#
# Usage: scripts/bench-report.sh cuda|vulkan OUTDIR
#        OUTDIR is created; it receives <backend>-<model>.json, .err and run.log.
#
# Set: Llama 3.2 3B Q4_K_M (fa 1), Llama 2 7B Q4_0 (fa 0,1), Ornith 1.5 9B
# Q4_K_M (fa 1) and Qwen2.5 14B Q4_K_M (fa 1); every run is
# -ngl 99 -t 8 -r 3 -p 512 -n 128 -o json, from <repo>/work/models (MODELS).
# One benchmark at a time: refuses to start while uvm_stress.sh runs.
#
# Environment:
#   GB10_WORK  work root (default <repo>/work)
#   MODELS     model directory (default <repo>/work/models)
#   ONLY       space-separated model tags to run (3b 7b ornith qwen)
#
# Exit status: 0 all runs ok; 1 a run failed; 2 usage or a stress run active.
set -eu

case "${1:-}" in
-h | --help)
	sed -n '5,/^# Exit status/p' "$0" | sed 's/^# \{0,1\}//'
	exit 0
	;;
cuda | vulkan) ;;
*)
	echo "usage: $0 cuda|vulkan OUTDIR" >&2
	exit 2
	;;
esac
[ $# -eq 2 ] || { echo "usage: $0 cuda|vulkan OUTDIR" >&2; exit 2; }
backend=$1
out=$2
W=${GB10_WORK:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)/work}
M=${MODELS:-$W/models}
here=$(cd "$(dirname "$0")" && pwd)
if pgrep -f '^(timeout [0-9]+ )?sh [^ ]*uvm_stress\.sh' >/dev/null 2>&1; then
	echo "bench-report: uvm_stress.sh is running; not benchmarking" >&2
	exit 2
fi
case $backend in
cuda) run="$here/run-cuda-llama.sh llama-bench" ;;
vulkan) run="sh $W/llm/run-nv-vulkan.sh llama-bench" ;;
esac
mkdir -p "$out"
rc=0
one() { # tag name file fa
	case " ${ONLY:-3b 7b ornith qwen} " in *" $1 "*) ;; *) return 0 ;; esac
	echo "# $(date -u +%Y-%m-%dT%H:%M:%SZ) $backend $2 fa=$4" >> "$out/run.log"
	# shellcheck disable=SC2086
	if $run -m "$M/$3" -ngl 99 -fa "$4" -t 8 -r 3 -p 512 -n 128 -o json \
	    > "$out/$backend-$2.json" 2> "$out/$backend-$2.err"; then
		echo "rc=0" >> "$out/run.log"
	else
		echo "rc=$?" >> "$out/run.log"
		rc=1
	fi
}
one 3b Llama-3.2-3B-Instruct-Q4_K_M Llama-3.2-3B-Instruct-Q4_K_M.gguf 1
one 7b llama-2-7b.Q4_0 llama-2-7b.Q4_0.gguf 0,1
one ornith Ornith-1.5-9B-Q4_K_M Ornith-1.5-9B-Q4_K_M.gguf 1
one qwen qwen2.5-14b-instruct-q4_k_m qwen2.5-14b-instruct-q4_k_m-00001-of-00003.gguf 1
exit $rc

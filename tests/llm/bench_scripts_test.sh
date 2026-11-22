#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# bench_scripts_test.sh - unit tests for scripts/bench-report.sh and
# scripts/run-cuda-llama.sh, with stub backends (no GPU needed).
# Usage: sh tests/llm/bench_scripts_test.sh      Exit 0 when every test passes.
set -u
here=$(cd "$(dirname "$0")/../.." && pwd)
T=${TMPDIR:-$here/tmp}/bench-test.$$
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }
check() { # name expected-rc actual-rc
	if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want rc=$2 got rc=$3)"; fi
}

# A fake work root: a stub run-nv-vulkan.sh that records its arguments and can
# be told to fail, and empty model files.
W=$T/work; M=$T/models
mkdir -p "$W/llm" "$M" "$T/bin"
cat > "$W/llm/run-nv-vulkan.sh" <<'STUB'
#!/bin/sh
echo "$*" >> "$STUB_LOG"
[ -n "${STUB_FAIL:-}" ] && exit 3
echo '[]'
STUB
for f in Llama-3.2-3B-Instruct-Q4_K_M.gguf llama-2-7b.Q4_0.gguf Ornith-1.5-9B-Q4_K_M.gguf \
    qwen2.5-14b-instruct-q4_k_m-00001-of-00003.gguf; do : > "$M/$f"; done
# a pgrep that reports no stress run unless FAKE_STRESS is set
cat > "$T/bin/pgrep" <<'STUB'
#!/bin/sh
[ -n "${FAKE_STRESS:-}" ]
STUB
chmod +x "$T/bin/pgrep" "$W/llm/run-nv-vulkan.sh"
export STUB_LOG=$T/stub.log HOME=$T GB10_WORK=$W MODELS=$M
B="env PATH=$T/bin:$PATH sh $here/scripts/bench-report.sh"

$B >/dev/null 2>&1; check "no arguments is a usage error" 2 $?
$B tpu "$T/o0" >/dev/null 2>&1; check "unknown backend is a usage error" 2 $?
$B --help >/dev/null 2>&1; check "--help exits 0" 0 $?
FAKE_STRESS=1 $B vulkan "$T/o1" >/dev/null 2>&1; check "refuses while a stress run is active" 2 $?
[ ! -e "$T/o1/run.log" ] && ok "no benchmark started during stress" || bad "benchmark started during stress"

: > "$STUB_LOG"
$B vulkan "$T/o2" >/dev/null 2>&1; check "vulkan set runs" 0 $?
n=$(wc -l < "$STUB_LOG" | tr -d ' ')
[ "$n" = 4 ] && ok "four llama-bench invocations" || bad "invocations: $n (want 4)"
grep -q -- '-fa 0,1' "$STUB_LOG" && ok "7B runs fa 0,1" || bad "7B fa 0,1 missing"
grep -q -- '-ngl 99 .*-t 8 -r 3 -p 512 -n 128 -o json' "$STUB_LOG" && ok "report flags" || bad "report flags missing"
[ -s "$T/o2/vulkan-llama-2-7b.Q4_0.json" ] && ok "json per model" || bad "json per model missing"

: > "$STUB_LOG"
ONLY="7b" $B vulkan "$T/o3" >/dev/null 2>&1
[ "$(wc -l < "$STUB_LOG" | tr -d ' ')" = 1 ] && ok "ONLY limits the set" || bad "ONLY ignored"

STUB_FAIL=1 $B vulkan "$T/o4" >/dev/null 2>&1; check "a failing run gives rc 1" 1 $?
grep -q 'rc=3' "$T/o4/run.log" && ok "failure recorded in run.log" || bad "failure not recorded"

# run-cuda-llama.sh
R="sh $here/scripts/run-cuda-llama.sh"
$R >/dev/null 2>&1; check "run-cuda-llama: no arguments" 2 $?
$R --help >/dev/null 2>&1; check "run-cuda-llama: --help" 0 $?
env -u HOME -u GB10_WORK $R llama-bench >/dev/null 2>&1; check "run-cuda-llama: no HOME, no files (needs no HOME, so a missing file)" 1 $?
$R llama-bench >/dev/null 2>&1; check "run-cuda-llama: missing files" 1 $?

# The contract: run-cuda-llama.sh needs no HOME.  Its cache directory is
# ${HOME:-$W}/.cache/sa (scripts/run-cuda-llama.sh, the CACHE= line), so with
# HOME unset it falls back to the work root.  A fake work root holds every file
# the script checks, with a stub loader that records its arguments.
F=$T/fakework
mkdir -p "$F/linuxroot/noble/lib" "$F/linuxroot/nv" "$F/build/linux-cuda" "$F/llm/cuda/llama-b12531-cuda/llama-b12531"
LLD=$F/llm/cuda/llama-b12531-cuda/llama-b12531
printf '#!/bin/sh\necho "$*" > "%s/loader.args"\n' "$T" > "$F/linuxroot/noble/lib/ld-linux-aarch64.so.1"
chmod +x "$F/linuxroot/noble/lib/ld-linux-aarch64.so.1"
: > "$F/build/linux-cuda/shim.so"; : > "$LLD/llama-bench"; : > "$LLD/libggml-cuda.so"; : > "$LLD/libcudart.so.13"; : > "$F/linuxroot/nv/libcuda.so.1"
env -u HOME GB10_WORK="$F" sh "$here/scripts/run-cuda-llama.sh" llama-bench -h >/dev/null 2>&1
check "run-cuda-llama: HOME unset, files present, runs" 0 $?
grep -q -- "$LLD/llama-bench -h" "$T/loader.args" && ok "run-cuda-llama: HOME unset, the loader got the program and its arguments" || bad "run-cuda-llama: HOME unset, the loader was not run"
[ -s "$F/.cache/sa/comm.txt" ] && ok "run-cuda-llama: HOME unset, the cache falls back to the work root" || bad "run-cuda-llama: HOME unset, no cache under the work root"
rm "$LLD/libcudart.so.13"
env -u HOME GB10_WORK="$F" sh "$here/scripts/run-cuda-llama.sh" llama-bench >/dev/null 2>&1
check "run-cuda-llama: HOME unset, a file missing" 1 $?

[ $fail = 0 ] && echo "all passed" || echo "FAILED"
exit $fail

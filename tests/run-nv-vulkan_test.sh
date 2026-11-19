#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# run-nv-vulkan_test.sh - tests for scripts/run-nv-vulkan.sh, without a GPU
# and without a Linux root.
#
# The script is pointed at a fake work root under tmp/ (git-ignored) that has
# the shape of the real one:
#   linuxroot/noble/lib/ld-linux-aarch64.so.1   a stub shell script that
#                                               prints its arguments and its
#                                               working directory
#   linuxroot/nv/nvidia_icd.json, 10_nvidia.json  the ICD and EGL vendor files
#   llm/llama-vulkan-arm64/llama-b12531/         the llama directory
#
# Cases:
#   (a) --help:                          exits 0 and prints the usage block
#   (b) a missing work root:             exits non-zero with "missing"
#   (c) server MODEL:                    runs from the llama directory and
#                                        passes an absolute model path
#   (d) llama-bench -p 512:              no model path is inserted; "-p" is
#                                        passed on as llama-bench's own option
#   (e) a missing nvidia_icd.json:       exits non-zero with "missing"
#   (f) HOME unset, no GB10_WORK:        exits 2 under sh and under
#                                        bash --posix alike, and says "HOME"
#   (g) HOME unset, GB10_WORK set:       works (GB10_WORK replaces the default
#                                        work root, so HOME is not needed)
#   (h) sh -n:                           the script parses
#   (i) bench MODEL:                     the model path is absolute
#   (j) bench NOSUCHMODEL:               exits 1 with "no model:"
#   (k) bench MODEL OPTIONS:             the options are passed on to
#                                        llama-bench after the defaults, and
#                                        a default the user gave is not added
#                                        a second time
#   (l) rpc OPTIONS:                     the options are passed on unchanged
#   (m) vulkaninfo:                      the Rocky vulkaninfo is run with
#                                        --summary
#   (n) bench with an empty model:       exits 2 with "bench needs a model"
#   (o) server with an empty model:      exits 2 with "server needs a model"
#   (p) the script is executable:        scripts/run-nv-vulkan.sh is mode 755
#   (q) the header of the script:        it does not promise exit 1 for the
#                                        HOME case (/bin/sh exits 2)
#   (r) bench with no model at all:      the default model is used and only
#                                        the default arguments reach
#                                        llama-bench
#   (s) bench MODEL -p 1024:             exactly one -p, and it is the user's
#   (t) bench MODEL:                     exactly one -p, and it is the
#                                        default 512
#   (u) bench MODEL -fa on:              exactly one -fa, and it is the
#                                        user's
#   (v) bench MODEL:                     exactly one -fa, and it is the
#                                        default 0,1
#   (w) vulkaninfo OPTIONS:              the options are passed on and the
#                                        default --summary is not added
#   (x) list OPTIONS:                    the options are passed on after
#                                        --list-devices
#   (y) bench MODEL -m OTHER:            refused (exit 2): the model is the
#                                        mode's own argument
#   (z) server MODEL -m OTHER:           refused (exit 2), same reason
#
# Run: sh tests/run-nv-vulkan_test.sh

set -eu

PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL

TESTSDIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH= cd -- "$TESTSDIR/.." && pwd)
SCRIPT=$REPO/scripts/run-nv-vulkan.sh
# The directory the test runs in: a relative model path of the script would
# be made absolute against it.
CWD=$(pwd)

PASSED=0
FAILED=0

# Scratch inside the repository (tmp/ is git-ignored), not in the system
# temporary directory and not outside the repository.
mkdir -p "$REPO/tmp"
TESTROOT=$(mktemp -d "$REPO/tmp/run-nv-vulkan-test.XXXXXXXX") || exit 1
FAKE=$TESTROOT/work
LL=$FAKE/llm/llama-vulkan-arm64/llama-b12531

# cleanup - remove exactly this run's scratch files on every exit path.
# Time:  O(files created by this test).
# Space: O(1).
cleanup() {
	rm -rf "$TESTROOT"
}
trap cleanup EXIT INT TERM

ok() {
	PASSED=$((PASSED + 1))
	printf 'ok   %s\n' "$1"
}

fail() {
	FAILED=$((FAILED + 1))
	printf 'FAIL %s\n' "$1"
}

# make_tree - build the fake work root.
# Time:  O(files created by this test).
# Space: O(1).
make_tree() {
	mkdir -p "$FAKE/linuxroot/noble/lib" "$FAKE/linuxroot/nv" "$LL" \
	    "$FAKE/linuxroot/rl9/usr/bin" "$FAKE/linuxroot/rl9/usr/lib64"
	cat > "$FAKE/linuxroot/noble/lib/ld-linux-aarch64.so.1" <<'EOF'
#!/bin/sh
# Stub for the Linux aarch64 dynamic loader: it prints the arguments it was
# called with and the directory it runs in, and exits 0.
printf 'PWD: %s\n' "$(pwd)"
for arg in "$@"; do
	printf 'ARG: %s\n' "$arg"
done
exit 0
EOF
	chmod +x "$FAKE/linuxroot/noble/lib/ld-linux-aarch64.so.1"
	printf '{}\n' > "$FAKE/linuxroot/nv/nvidia_icd.json"
	printf '{}\n' > "$FAKE/linuxroot/nv/10_nvidia.json"
	# The Rocky vulkaninfo of the vulkaninfo mode.
	cat > "$FAKE/linuxroot/rl9/usr/bin/vulkaninfo" <<'EOF'
#!/bin/sh
# Stub for the Rocky vulkaninfo: it prints the arguments it was called with,
# the directory it runs in and the library path it was given.
printf 'VULKANINFO: %s\n' "$(pwd)"
printf 'LD_LIBRARY_PATH: %s\n' "${LD_LIBRARY_PATH:-}"
for arg in "$@"; do
	printf 'ARG: %s\n' "$arg"
done
exit 0
EOF
	chmod +x "$FAKE/linuxroot/rl9/usr/bin/vulkaninfo"
	: > "$LL/llama-bench"
	: > "$LL/llama-server"
	: > "$LL/ggml-rpc-server"
}

# args_of FILE - the arguments the stub was called with, one per line.
# Time:  O(lines of FILE).
# Space: O(lines of FILE).
args_of() {
	sed -n 's/^ARG: //p' "$1"
}

# bench_args FILE - the arguments the stub llama-bench was called with, one
# per line.
# Time:  O(lines of FILE).
# Space: O(lines of FILE).
bench_args() {
	args_of "$1" | sed -n '/\/llama-bench$/,$p' | sed -n '2,$p'
}

# bench_arg_count FLAG FILE - how many times the flag appears in the
# arguments of the stub llama-bench.
# Time:  O(lines of FILE).
# Space: O(lines of FILE).
bench_arg_count() {
	bench_args "$2" | grep -c -- "^$1\$" || true
}

# bench_arg_after FLAG FILE - the argument that follows the flag (empty when
# the flag is not there).
# Time:  O(lines of FILE).
# Space: O(lines of FILE).
bench_arg_after() {
	bench_args "$2" | awk -v f="$1" 'prev == f { print; exit } { prev = $0 }'
}

make_tree

# (a) --help: the usage block, exit 0, nothing else needed.
rc=0
sh "$SCRIPT" --help > "$TESTROOT/a.out" 2> "$TESTROOT/a.err" || rc=$?
if [ "$rc" -eq 0 ] && grep -q 'Usage' "$TESTROOT/a.out"; then
	ok "(a) --help: exit 0, usage printed"
else
	fail "(a) --help: rc=$rc stderr=$(cat "$TESTROOT/a.err")"
fi

# (b) a work root without the trees: refused before anything runs.
rc=0
GB10_WORK=$TESTROOT/nowhere sh "$SCRIPT" list \
    > "$TESTROOT/b.out" 2> "$TESTROOT/b.err" || rc=$?
if [ "$rc" -ne 0 ] && grep -q 'missing' "$TESTROOT/b.err"; then
	ok "(b) missing work root: exit $rc, \"missing\" printed"
else
	fail "(b) missing work root: rc=$rc stderr=$(cat "$TESTROOT/b.err")"
fi

# (c) server MODEL: the llama directory is the working directory and the
# model path is absolute.
mkdir -p "$TESTROOT/models"
: > "$TESTROOT/models/model.gguf"
rc=0
(cd "$TESTROOT/models" && GB10_WORK="$FAKE" sh "$SCRIPT" server model.gguf) \
    > "$TESTROOT/c.out" 2> "$TESTROOT/c.err" || rc=$?
model=$(args_of "$TESTROOT/c.out" | awk 'prev == "-m" { print; exit } { prev = $0 }')
if [ "$rc" -eq 0 ] &&
    grep -qx "PWD: $LL" "$TESTROOT/c.out" &&
    [ -n "$model" ] &&
    case "$model" in /*) true ;; *) false ;; esac &&
    [ "${model##*/}" = "model.gguf" ]; then
	ok "(c) server MODEL: runs in the llama directory, model path $model"
else
	fail "(c) server MODEL: rc=$rc model=$model out=$(cat "$TESTROOT/c.out") err=$(cat "$TESTROOT/c.err")"
fi

# (d) llama-bench -p 512: "-p" is llama-bench's own option, not a model.
rc=0
GB10_WORK="$FAKE" sh "$SCRIPT" llama-bench -p 512 \
    > "$TESTROOT/d.out" 2> "$TESTROOT/d.err" || rc=$?
bench_args=$(args_of "$TESTROOT/d.out" | sed -n '/\/llama-bench$/,$p' | sed -n '2,$p' |
    tr '\n' ' ')
if [ "$rc" -eq 0 ] && [ "$bench_args" = "-p 512 " ] &&
    ! args_of "$TESTROOT/d.out" | grep -q '\.gguf' &&
    ! args_of "$TESTROOT/d.out" | grep -qx -- "$CWD/-p"; then
	ok "(d) llama-bench -p 512: no model path inserted"
else
	fail "(d) llama-bench -p 512: rc=$rc args=[$bench_args] out=$(cat "$TESTROOT/d.out")"
fi

# (e) a missing nvidia_icd.json: refused before anything runs.
mv "$FAKE/linuxroot/nv/nvidia_icd.json" "$TESTROOT/nvidia_icd.json.keep"
rc=0
GB10_WORK="$FAKE" sh "$SCRIPT" list > "$TESTROOT/e.out" 2> "$TESTROOT/e.err" || rc=$?
mv "$TESTROOT/nvidia_icd.json.keep" "$FAKE/linuxroot/nv/nvidia_icd.json"
if [ "$rc" -ne 0 ] && grep -q 'missing' "$TESTROOT/e.err"; then
	ok "(e) missing nvidia_icd.json: exit $rc, \"missing\" printed"
else
	fail "(e) missing nvidia_icd.json: rc=$rc stderr=$(cat "$TESTROOT/e.err")"
fi

# (f) HOME unset and no GB10_WORK: the script has no work root and says so.
# The status is 2, and it is 2 under every shell: the exit code must not
# depend on the shell (a ${HOME:?} expansion error exits 2 under /bin/sh but
# 1 under bash).
f_ok=1
f_shell=
f_rc=
f_err=
for f_cmd in "sh" "bash --posix"; do
	rc=0
	# The shell word is split on purpose: "bash --posix" is two words.
	# shellcheck disable=SC2086
	env -u HOME -u GB10_WORK $f_cmd "$SCRIPT" list \
	    > "$TESTROOT/f.out" 2> "$TESTROOT/f.err" || rc=$?
	if [ "$rc" -ne 2 ] || ! grep -q 'HOME' "$TESTROOT/f.err"; then
		f_ok=0
		f_shell=$f_cmd
		f_rc=$rc
		f_err=$(cat "$TESTROOT/f.err")
	fi
done
if [ "$f_ok" -eq 1 ]; then
	ok "(f) HOME unset, no GB10_WORK: exit 2 under sh and bash --posix"
else
	fail "(f) HOME unset, no GB10_WORK ($f_shell): rc=$f_rc stderr=$f_err"
fi

# (g) HOME unset but GB10_WORK set: the work root is known, so HOME is not
# needed.
rc=0
env -u HOME GB10_WORK="$FAKE" sh "$SCRIPT" list \
    > "$TESTROOT/g.out" 2> "$TESTROOT/g.err" || rc=$?
if [ "$rc" -eq 0 ] && grep -qx "PWD: $LL" "$TESTROOT/g.out"; then
	ok "(g) HOME unset, GB10_WORK set: runs"
else
	fail "(g) HOME unset, GB10_WORK set: rc=$rc stderr=$(cat "$TESTROOT/g.err")"
fi

# (h) the script parses.
rc=0
sh -n "$SCRIPT" || rc=$?
if [ "$rc" -eq 0 ]; then
	ok "(h) sh -n scripts/run-nv-vulkan.sh"
else
	fail "(h) sh -n scripts/run-nv-vulkan.sh: rc=$rc"
fi

# (i) bench MODEL: the model path is made absolute against the directory the
# script was started from.
rc=0
(cd "$TESTROOT/models" && GB10_WORK="$FAKE" sh "$SCRIPT" bench model.gguf) \
    > "$TESTROOT/i.out" 2> "$TESTROOT/i.err" || rc=$?
model=$(args_of "$TESTROOT/i.out" | awk 'prev == "-m" { print; exit } { prev = $0 }')
if [ "$rc" -eq 0 ] && [ -n "$model" ] &&
    case "$model" in /*) true ;; *) false ;; esac &&
    [ "${model##*/}" = "model.gguf" ]; then
	ok "(i) bench MODEL: model path $model"
else
	fail "(i) bench MODEL: rc=$rc model=$model out=$(cat "$TESTROOT/i.out") err=$(cat "$TESTROOT/i.err")"
fi

# (j) bench NOSUCHMODEL: the model has to exist.
rc=0
GB10_WORK="$FAKE" sh "$SCRIPT" bench nosuchmodel.gguf \
    > "$TESTROOT/j.out" 2> "$TESTROOT/j.err" || rc=$?
if [ "$rc" -eq 1 ] && grep -q 'no model:' "$TESTROOT/j.err"; then
	ok "(j) bench NOSUCHMODEL: exit 1, \"no model:\" printed"
else
	fail "(j) bench NOSUCHMODEL: rc=$rc stderr=$(cat "$TESTROOT/j.err")"
fi

# (k) bench MODEL OPTIONS: the options are passed on to llama-bench after the
# defaults, and a default the user gave is NOT added a second time (llama-bench
# appends -p, -n, -ngl and -fa to a list, so "-p 512 -p 1024" would run the
# prefill test twice).
rc=0
(cd "$TESTROOT/models" && GB10_WORK="$FAKE" sh "$SCRIPT" bench model.gguf -fa on -p 1024) \
    > "$TESTROOT/k.out" 2> "$TESTROOT/k.err" || rc=$?
bench_args=$(bench_args "$TESTROOT/k.out" | tr '\n' ' ')
if [ "$rc" -eq 0 ] &&
    [ "$bench_args" = "-m $TESTROOT/models/model.gguf -n 128 -ngl 99 -fa on -p 1024 " ]; then
	ok "(k) bench MODEL OPTIONS: the options come after the defaults"
else
	fail "(k) bench MODEL OPTIONS: rc=$rc args=[$bench_args] err=$(cat "$TESTROOT/k.err")"
fi

# (k2) bench MODEL with the LONG flag names: llama-bench takes --n-prompt,
# --n-gen, --n-gpu-layers and --flash-attn as well, so none of the defaults
# may be added; --model in the options is refused like -m.
rc=0
(cd "$TESTROOT/models" && GB10_WORK="$FAKE" sh "$SCRIPT" bench model.gguf \
    --n-prompt 1024 --n-gen 64 --n-gpu-layers 0 --flash-attn 1) \
    > "$TESTROOT/k2.out" 2> "$TESTROOT/k2.err" || rc=$?
bench_args=$(bench_args "$TESTROOT/k2.out" | tr '\n' ' ')
if [ "$rc" -eq 0 ] &&
    [ "$bench_args" = "-m $TESTROOT/models/model.gguf --n-prompt 1024 --n-gen 64 --n-gpu-layers 0 --flash-attn 1 " ]; then
	ok "(k2) bench MODEL with long flag names: no default is added"
else
	fail "(k2) bench MODEL with long flag names: rc=$rc args=[$bench_args] err=$(cat "$TESTROOT/k2.err")"
fi
for mode in bench server; do
	rc=0
	(cd "$TESTROOT/models" && GB10_WORK="$FAKE" sh "$SCRIPT" $mode model.gguf --model x.gguf) \
	    > "$TESTROOT/k3.out" 2> "$TESTROOT/k3.err" || rc=$?
	if [ "$rc" -eq 2 ] && ! grep -q '^ARG:' "$TESTROOT/k3.out"; then
		ok "(k3) $mode MODEL --model x: refused with exit 2, nothing run"
	else
		fail "(k3) $mode MODEL --model x: rc=$rc out=$(cat "$TESTROOT/k3.out")"
	fi
done

# (l) rpc OPTIONS: the options are passed on unchanged.
rc=0
GB10_WORK="$FAKE" sh "$SCRIPT" rpc --host 127.0.0.1 --port 50052 \
    > "$TESTROOT/l.out" 2> "$TESTROOT/l.err" || rc=$?
rpc_args=$(args_of "$TESTROOT/l.out" | sed -n '/\/ggml-rpc-server$/,$p' | sed -n '2,$p' |
    tr '\n' ' ')
if [ "$rc" -eq 0 ] && [ "$rpc_args" = "--host 127.0.0.1 --port 50052 " ]; then
	ok "(l) rpc OPTIONS: the options are passed on unchanged"
else
	fail "(l) rpc OPTIONS: rc=$rc args=[$rpc_args] err=$(cat "$TESTROOT/l.err")"
fi

# (m) vulkaninfo: the Rocky vulkaninfo runs with --summary.
rc=0
GB10_WORK="$FAKE" sh "$SCRIPT" vulkaninfo \
    > "$TESTROOT/m.out" 2> "$TESTROOT/m.err" || rc=$?
if [ "$rc" -eq 0 ] && grep -q '^ARG: --summary$' "$TESTROOT/m.out" &&
    grep -q '^VULKANINFO: ' "$TESTROOT/m.out" &&
    grep -q "$FAKE/linuxroot/rl9/usr/lib64" "$TESTROOT/m.out"; then
	ok "(m) vulkaninfo: the Rocky vulkaninfo runs with --summary"
else
	fail "(m) vulkaninfo: rc=$rc out=$(cat "$TESTROOT/m.out") err=$(cat "$TESTROOT/m.err")"
fi

# (n) bench with an empty model: a missing argument, not the default model.
rc=0
GB10_WORK="$FAKE" sh "$SCRIPT" bench "" \
    > "$TESTROOT/n.out" 2> "$TESTROOT/n.err" || rc=$?
if [ "$rc" -eq 2 ] && grep -q 'bench needs a model' "$TESTROOT/n.err"; then
	ok "(n) bench with an empty model: exit 2"
else
	fail "(n) bench with an empty model: rc=$rc stderr=$(cat "$TESTROOT/n.err")"
fi

# (o) server with an empty model: a missing argument, not the current
# directory.
rc=0
GB10_WORK="$FAKE" sh "$SCRIPT" server "" \
    > "$TESTROOT/o.out" 2> "$TESTROOT/o.err" || rc=$?
if [ "$rc" -eq 2 ] && grep -q 'server needs a model' "$TESTROOT/o.err"; then
	ok "(o) server with an empty model: exit 2"
else
	fail "(o) server with an empty model: rc=$rc stderr=$(cat "$TESTROOT/o.err")"
fi

# (p) the script keeps its executable bit: it has a shebang and is run
# directly.
if [ -x "$SCRIPT" ]; then
	ok "(p) scripts/run-nv-vulkan.sh is executable"
else
	fail "(p) scripts/run-nv-vulkan.sh is not executable"
fi

# (q) The header of the script must not promise exit 1 for the HOME case:
# the ${HOME:?} parameter expansion error of /bin/sh exits with 2.
if grep -q 'HOME is not set' "$SCRIPT" &&
    grep -q '1 a path is missing or HOME is not set' "$SCRIPT"; then
	fail "(q) the header still promises exit 1 for the HOME case"
else
	ok "(q) the header does not promise exit 1 for the HOME case"
fi

# (r) bench with no model at all: the default model is used and nothing else
# reaches llama-bench (the name of the mode is not one of its arguments).
mkdir -p "$TESTROOT/home/work/models"
: > "$TESTROOT/home/work/models/Llama-3.2-3B-Instruct-Q4_K_M.gguf"
rc=0
HOME="$TESTROOT/home" GB10_WORK="$FAKE" sh "$SCRIPT" bench \
    > "$TESTROOT/r.out" 2> "$TESTROOT/r.err" || rc=$?
bench_args=$(bench_args "$TESTROOT/r.out" | tr '\n' ' ')
if [ "$rc" -eq 0 ] &&
    [ "$bench_args" = "-m $TESTROOT/home/work/models/Llama-3.2-3B-Instruct-Q4_K_M.gguf -p 512 -n 128 -ngl 99 -fa 0,1 " ]; then
	ok "(r) bench with no model: the default model, and nothing else"
else
	fail "(r) bench with no model: rc=$rc args=[$bench_args] err=$(cat "$TESTROOT/r.err")"
fi

# (s) bench MODEL -p 1024: llama-bench appends -p to a list, so the default
# -p 512 must not be added as well.  Exactly one -p, and it is the user's.
rc=0
(cd "$TESTROOT/models" && GB10_WORK="$FAKE" sh "$SCRIPT" bench model.gguf -p 1024) \
    > "$TESTROOT/s.out" 2> "$TESTROOT/s.err" || rc=$?
n_p=$(bench_arg_count -p "$TESTROOT/s.out")
p_value=$(bench_arg_after -p "$TESTROOT/s.out")
if [ "$rc" -eq 0 ] && [ "$n_p" -eq 1 ] && [ "$p_value" = "1024" ]; then
	ok "(s) bench MODEL -p 1024: exactly one -p, the user's"
else
	fail "(s) bench MODEL -p 1024: rc=$rc n_p=$n_p value=$p_value err=$(cat "$TESTROOT/s.err")"
fi

# (t) bench MODEL without -p: the default -p 512 is added, once.
rc=0
(cd "$TESTROOT/models" && GB10_WORK="$FAKE" sh "$SCRIPT" bench model.gguf) \
    > "$TESTROOT/t.out" 2> "$TESTROOT/t.err" || rc=$?
n_p=$(bench_arg_count -p "$TESTROOT/t.out")
p_value=$(bench_arg_after -p "$TESTROOT/t.out")
if [ "$rc" -eq 0 ] && [ "$n_p" -eq 1 ] && [ "$p_value" = "512" ]; then
	ok "(t) bench MODEL: exactly one -p, the default 512"
else
	fail "(t) bench MODEL: rc=$rc n_p=$n_p value=$p_value err=$(cat "$TESTROOT/t.err")"
fi

# (u) bench MODEL -fa on: the default -fa 0,1 is not added as well.
rc=0
(cd "$TESTROOT/models" && GB10_WORK="$FAKE" sh "$SCRIPT" bench model.gguf -fa on) \
    > "$TESTROOT/u.out" 2> "$TESTROOT/u.err" || rc=$?
n_fa=$(bench_arg_count -fa "$TESTROOT/u.out")
fa_value=$(bench_arg_after -fa "$TESTROOT/u.out")
if [ "$rc" -eq 0 ] && [ "$n_fa" -eq 1 ] && [ "$fa_value" = "on" ]; then
	ok "(u) bench MODEL -fa on: exactly one -fa, the user's"
else
	fail "(u) bench MODEL -fa on: rc=$rc n_fa=$n_fa value=$fa_value err=$(cat "$TESTROOT/u.err")"
fi

# (v) bench MODEL without -fa: the default -fa 0,1 is added, once.  llama-bench
# writes the AUTO setting as -1, and a -1 row matches no published row.
rc=0
(cd "$TESTROOT/models" && GB10_WORK="$FAKE" sh "$SCRIPT" bench model.gguf) \
    > "$TESTROOT/v.out" 2> "$TESTROOT/v.err" || rc=$?
n_fa=$(bench_arg_count -fa "$TESTROOT/v.out")
fa_value=$(bench_arg_after -fa "$TESTROOT/v.out")
if [ "$rc" -eq 0 ] && [ "$n_fa" -eq 1 ] && [ "$fa_value" = "0,1" ]; then
	ok "(v) bench MODEL: exactly one -fa, the default 0,1"
else
	fail "(v) bench MODEL: rc=$rc n_fa=$n_fa value=$fa_value err=$(cat "$TESTROOT/v.err")"
fi

# (w) vulkaninfo with its own arguments: they are passed on, and the default
# --summary is not added (it is the default only when there are no arguments).
rc=0
GB10_WORK="$FAKE" sh "$SCRIPT" vulkaninfo --json \
    > "$TESTROOT/w.out" 2> "$TESTROOT/w.err" || rc=$?
if [ "$rc" -eq 0 ] && grep -qx 'ARG: --json' "$TESTROOT/w.out" &&
    ! grep -qx 'ARG: --summary' "$TESTROOT/w.out"; then
	ok "(w) vulkaninfo OPTIONS: the options are passed on, without --summary"
else
	fail "(w) vulkaninfo OPTIONS: rc=$rc out=$(cat "$TESTROOT/w.out") err=$(cat "$TESTROOT/w.err")"
fi

# (x) list with its own arguments: they are passed on after --list-devices.
rc=0
GB10_WORK="$FAKE" sh "$SCRIPT" list --device Vulkan0 \
    > "$TESTROOT/x.out" 2> "$TESTROOT/x.err" || rc=$?
if [ "$rc" -eq 0 ] && grep -qx 'ARG: --list-devices' "$TESTROOT/x.out" &&
    grep -qx 'ARG: --device' "$TESTROOT/x.out" &&
    grep -qx 'ARG: Vulkan0' "$TESTROOT/x.out"; then
	ok "(x) list OPTIONS: the options are passed on after --list-devices"
else
	fail "(x) list OPTIONS: rc=$rc out=$(cat "$TESTROOT/x.out") err=$(cat "$TESTROOT/x.err")"
fi

# (y) bench MODEL -m OTHER: the model is the mode's own argument, so a second
# -m is refused (llama-bench appends the models and would run both).
rc=0
(cd "$TESTROOT/models" && GB10_WORK="$FAKE" sh "$SCRIPT" bench model.gguf -m other.gguf) \
    > "$TESTROOT/y.out" 2> "$TESTROOT/y.err" || rc=$?
if [ "$rc" -eq 2 ] && grep -q -- '-m' "$TESTROOT/y.err"; then
	ok "(y) bench MODEL -m OTHER: refused, exit 2"
else
	fail "(y) bench MODEL -m OTHER: rc=$rc err=$(cat "$TESTROOT/y.err")"
fi

# (z) server MODEL -m OTHER: the same refusal.
rc=0
(cd "$TESTROOT/models" && GB10_WORK="$FAKE" sh "$SCRIPT" server model.gguf -m other.gguf) \
    > "$TESTROOT/z.out" 2> "$TESTROOT/z.err" || rc=$?
if [ "$rc" -eq 2 ] && grep -q -- '-m' "$TESTROOT/z.err"; then
	ok "(z) server MODEL -m OTHER: refused, exit 2"
else
	fail "(z) server MODEL -m OTHER: rc=$rc err=$(cat "$TESTROOT/z.err")"
fi

printf 'passed: %s failed: %s\n' "$PASSED" "$FAILED"
if [ "$FAILED" -gt 0 ]; then
	exit 1
fi
exit 0

#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# native_llm_bench_test.sh - fake-only tests for scripts/native-llm-bench.
# No GPU, llama.cpp binary, system sysctl, or other live command is used.

PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
LC_ALL=C
TMPDIR=${TMPDIR:-$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)}
export PATH LC_ALL TMPDIR

TESTSDIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SCRIPT=$TESTSDIR/../scripts/native-llm-bench
DATA=$TESTSDIR/data/native-llm-bench
MEDIANS=$TESTSDIR/../docs/published-medians.json
PATH_CHECK=$TESTSDIR/../scripts/native-path-check
REGISTRY=$TESTSDIR/../docs/native-paths.json
NOUVEAU_ERROR='libvulkan_nouveau.so'
WORK=$(mktemp -d -t native-llm-bench-test.XXXXXXXX) || exit 1
PASSED=0
FAILED=0

cleanup() {
	rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

ok() {
	PASSED=$((PASSED + 1))
	printf 'ok   %s\n' "$1"
}

fail() {
	FAILED=$((FAILED + 1))
	printf 'FAIL %s\n' "$1"
}

# setup_case NAME GPU SCENARIO VULKAN_MODE
# Make an isolated model/build/ICD tree and point every command override at
# the single fake.  Model files are deliberately tiny: memory arithmetic is
# tested against their actual size, without allocating gigabytes.
setup_case() {
	NAME=$1
	GPU=$2
	SCENARIO=$3
	VULKAN=$4
	CASE=$WORK/$NAME
	ICD_DIR=$CASE/icd
	mkdir -p "$CASE/bin" "$CASE/build/bin" "$CASE/models" "$ICD_DIR"
	for cmd in vulkaninfo pciconf sysctl kldstat fstat file hw-preflight bectl uname; do
		ln -s "$DATA/fake-command" "$CASE/bin/$cmd"
	done
	ln -s "$DATA/fake-command" "$CASE/build/bin/llama-bench"
	printf 'fake 3B model\n' > "$CASE/models/Llama-3.2-3B-Instruct-Q4_K_M.gguf"
	printf 'fake 7B model\n' > "$CASE/models/llama-2-7b.Q4_0.gguf"
	if [ "$GPU" = nvidia ]; then
		LIB=libvulkan_nvk_nvrm.so
		ICD_NAME=nvk_nvrm_icd.aarch64.json
	else
		LIB=libvulkan_radeon.so
		ICD_NAME=native.json
	fi
	printf '{"ICD":{"library_path":"%s","api_version":"1.4.0"}}\n' "./$LIB" > "$ICD_DIR/$ICD_NAME"
	: > "$ICD_DIR/$LIB"
	unset VK_DRIVER_FILES VK_ICD_FILENAMES VK_ADD_DRIVER_FILES
	unset VK_LOADER_DRIVERS_SELECT VK_LOADER_DRIVERS_DISABLE VK_LOADER_LAYERS_ENABLE
	unset VK_INSTANCE_LAYERS LD_PRELOAD LD_LIBRARY_PATH
	NLB_TEST=1
	NLB_VULKANINFO=$CASE/bin/vulkaninfo
	NLB_PCICONF=$CASE/bin/pciconf
	NLB_SYSCTL=$CASE/bin/sysctl
	NLB_KLDSTAT=$CASE/bin/kldstat
	NLB_FSTAT=$CASE/bin/fstat
	NLB_FILE=$CASE/bin/file
	NLB_BECTL=$CASE/bin/bectl
	NLB_HW_PREFLIGHT=$CASE/bin/hw-preflight
	NLB_UNAME=$CASE/bin/uname
	NLB_LLAMA_BENCH=$CASE/build/bin/llama-bench
	FAKE_LOG=$CASE/log
	FAKE_SCENARIO=$SCENARIO
	FAKE_VULKAN=$VULKAN
	FAKE_BINARY_OS=FreeBSD
	FAKE_LIBRARY_OS=FreeBSD
	FAKE_KLD=loaded
	FAKE_KLD_VERBOSE=none
	FAKE_LIST_MODE=ordinary
	FAKE_NVIDIA_SYSCTL=present
	FAKE_GPU_FREE_MIB=8147
	FAKE_BENCH_FAIL_MODEL=
	FAKE_VERSION=stderr
	FAKE_ARCH=aarch64
	FAKE_HOST_FREE_PAGES=8388608
	FAKE_HOST_INACTIVE_PAGES=8388608
	export NLB_TEST NLB_VULKANINFO NLB_PCICONF NLB_SYSCTL NLB_KLDSTAT NLB_FSTAT NLB_FILE
	export NLB_BECTL NLB_HW_PREFLIGHT NLB_UNAME NLB_LLAMA_BENCH
	export FAKE_LOG FAKE_SCENARIO FAKE_VULKAN
	export FAKE_BINARY_OS FAKE_LIBRARY_OS FAKE_KLD FAKE_KLD_VERBOSE FAKE_LIST_MODE
	export FAKE_NVIDIA_SYSCTL FAKE_GPU_FREE_MIB FAKE_BENCH_FAIL_MODEL FAKE_VERSION FAKE_ARCH
	export FAKE_HOST_FREE_PAGES FAKE_HOST_INACTIVE_PAGES
}

run_tool() {
	"$SCRIPT" --gpu "$GPU" --build "$CASE/build" --models "$CASE/models" \
	    --out "$CASE/out" --hw-preflight "$NLB_HW_PREFLIGHT" \
	    --icd-dir "$ICD_DIR" --medians "$MEDIANS" "$@" \
	    > "$CASE/stdout.json" 2> "$CASE/stderr.txt"
	RC=$?
}

basic_result() {
	# NAME WANT_RC WANT_STATUS [ERROR_SUBSTRING]
	name=$1 want_rc=$2 want_status=$3 text=${4:-}
	if [ "$RC" -ne "$want_rc" ]; then
		fail "$name: rc $RC, want $want_rc"
		return 1
	fi
	if ! python3 -I -c '
import json, sys
d = json.load(open(sys.argv[1]))
assert d["status"] == sys.argv[2], d
assert set(("version", "gpu", "steps", "rows", "medians", "error")) <= set(d)
if len(sys.argv) > 3:
    assert sys.argv[3] in d["error"], d["error"]
' "$CASE/stdout.json" "$want_status" ${text:+"$text"} 2>/dev/null; then
		fail "$name: status $want_status or error text '$text'"
		return 1
	fi
	return 0
}

# a. Native Radeon happy path, both model files and all median arithmetic.
setup_case a radeon radeon radeon
run_tool
if basic_result "a radeon native" 0 ok && python3 -I -c '
import json, os, sys
case, out = sys.argv[1:]
d = json.load(open(os.path.join(case, "stdout.json")))
s = json.load(open(os.path.join(out, "summary.json")))
m = json.load(open(os.path.join(out, "meta.json")))
assert len(d["rows"]) == len(s["rows"]) == 6
assert m["test_mode"] is m["_run"]["test_mode"] is True
assert m["path_status"] == m["_run"]["path_status"] == "test"
assert m["_run"]["card"] == "amd-rx7600"
assert m["_run"]["backend"] == "vulkan"
assert m["_run"]["build"] == (
    "version: 1.0.0-dev (build 1, commit 225a534), commit 225a5345b "
    "native FreeBSD build (%s)" % os.path.join(case, "build"))
assert "radv Mesa 26.2.2" in m["_run"]["stack"]
assert "PCI pci12:3:0:0" in m["_run"]["stack"]
assert m["_run"]["boot"] == "cloudbsd-test"
expected = {(0, "pp512"): (1167.2, 2.8), (0, "tg128"): (58.03, 3.4),
            (1, "pp512"): (1353.47, 3.4), (1, "tg128"): (60.88, 6.8)}
seen = {}
for r in s["rows"]:
    assert r["path"] == r["path_status"] == "test"
    assert r["test_mode"] is True
    assert r["card"] == "amd-rx7600" and r["backend"] == "vulkan"
    if r["model"] == "llama-2-7b.Q4_0":
        key = (r["fa"], r["test"])
        assert (r["published_median"], r["difference_percent"]) == expected[key], r
        assert r["median_sources"][0]["url"].endswith("17845940")
        seen[key] = True
assert set(seen) == set(expected)
for model in ("Llama-3.2-3B-Instruct-Q4_K_M", "llama-2-7b.Q4_0"):
    raw = os.path.join(out, "radeon-" + model + ".json")
    assert len(json.load(open(raw))) == (2 if "3B" in model else 4)
    assert os.path.exists(raw[:-5] + ".err")
bench = [json.loads(l) for l in open(os.path.join(case, "log", "benchmarks.jsonl"))]
assert len(bench) == 2
assert "Llama-3.2-3B-Instruct-Q4_K_M.gguf" in bench[0][bench[0].index("-m") + 1]
assert bench[0][bench[0].index("-fa") + 1] == "1"
assert "llama-2-7b.Q4_0.gguf" in bench[1][bench[1].index("-m") + 1]
assert bench[1][bench[1].index("-fa") + 1] == "0,1"
for args in bench:
    assert args[args.index("-dev") + 1] == "Vulkan0"
    assert args[args.index("-ngl") + 1] == "99"
    assert args[args.index("-r") + 1] == "3"
commands = [json.loads(l) for l in open(os.path.join(case, "log", "commands.jsonl"))]
assert all(c["VK_DRIVER_FILES"] == os.path.join(case, "icd", "native.json")
           for c in commands if c["command"] in ("vulkaninfo", "llama-bench"))
assert all(c["args"][0] == "-b" for c in commands if c["command"] == "file")
for c in commands:
    for name, value in c["loader_env"].items():
        if name == "VK_DRIVER_FILES":
            assert value in (None, os.path.join(case, "icd", "native.json")), c
        else:
            assert value is None, (c["command"], name, value)
' "$CASE" "$CASE/out" 2>/dev/null; then
	ok "a radeon native: rc 0, six rows, raw JSON, meta, medians"
else
	[ "$FAILED" -gt 0 ] && [ "$RC" -ne 0 ] || fail "a radeon native: output files or medians"
fi

# Test-mode rows must never be accepted as native history records.
python3 -I -c '
import json, sys
s = json.load(open(sys.argv[1]))
json.dump({"records": s["rows"]}, open(sys.argv[2], "w"))
' "$CASE/out/summary.json" "$CASE/history.json"
"$PATH_CHECK" --registry "$REGISTRY" "$CASE/history.json" > "$CASE/path-check.json" 2>/dev/null
RC=$?
if [ "$RC" -eq 1 ] && python3 -I -c '
import json, sys
d = json.load(open(sys.argv[1]))
assert d["status"] == "violations" and d["checked"] == 6
assert d["counts"]["native"] == 0 and len(d["violations"]) == 6
' "$CASE/path-check.json"; then
	ok "case-a test rows are refused as native history"
else
	fail "case-a test rows are refused as native history: rc $RC"
fi

# The second run may not overwrite or mix records in a nonempty run directory.
cp "$CASE/out/summary.json" "$CASE/summary.first"
run_tool
if basic_result "u nonempty output directory" 2 error "not empty" &&
   cmp -s "$CASE/summary.first" "$CASE/out/summary.json"; then
	ok "u nonempty --out: rc 2, first summary unchanged"
else
	fail "u nonempty --out was not refused cleanly"
fi

# An existing empty output directory remains valid.
setup_case empty-out radeon radeon radeon
mkdir "$CASE/out"
run_tool
if basic_result "empty output directory" 0 ok; then
	ok "existing empty --out is accepted"
else
	fail "existing empty --out was refused"
fi

# b. NVIDIA without NVK is refused before vulkaninfo.
setup_case b nvidia nvidia nvk
rm "$ICD_DIR/$ICD_NAME"
run_tool
if basic_result "b no NVK" 3 refused "Track #2379" && python3 -I -c '
import json, sys
case = sys.argv[1]
d = json.load(open(case + "/stdout.json"))
message = ("no NVK-on-libnvrm Vulkan driver (nvk_nvrm_icd.<arch>.json) is installed; "
           "it is Track #2379")
assert d["error"] == message, d["error"]
human = open(case + "/stderr.txt").read()
assert human.count(message) == 1, human
assert "model                              fa test" not in human, human
' "$CASE"; then
	ok "b NVIDIA without NVK: exact message appears once"
else
	fail "b NVIDIA without NVK"
fi

# c. Even an NVK manifest below a Linux root is never used.
setup_case c nvidia nvidia nvk
mkdir -p "$CASE/linuxroot"
mv "$ICD_DIR" "$CASE/linuxroot/icd"
ICD_DIR=$CASE/linuxroot/icd
run_tool
if basic_result "c linuxroot ICD" 3 refused linuxroot; then
	ok "c NVIDIA ICD under linuxroot: rc 3 refused"
else
	fail "c NVIDIA ICD under linuxroot"
fi

# d. A proprietary NVIDIA driverName is not the required NVK/libnvrm path.
setup_case d nvidia nvidia proprietary
run_tool
if basic_result "d proprietary driver" 3 refused "NVK (CloudBSD, libnvrm)"; then
	ok "d proprietary driverName: rc 3 refused"
else
	fail "d proprietary driverName"
fi

# e. NVIDIA refuses a loaded Linux compatibility layer.
setup_case e nvidia nvidia nvk
run_tool
if basic_result "e NVIDIA linux64.ko" 3 refused "linux_enable=NO"; then
	ok "e NVIDIA with linux64.ko: rc 3 refused"
else
	fail "e NVIDIA with linux64.ko"
fi

# f. FreeBSD in the path cannot make a GNU/Linux executable native.
setup_case f-FreeBSD-build radeon radeon radeon
FAKE_BINARY_OS=Linux
export FAKE_BINARY_OS
run_tool
if basic_result "f Linux binary" 3 refused "not a FreeBSD binary" && python3 -I -c '
import json, sys
case = sys.argv[1]
d = json.load(open(case + "/stdout.json"))
binary = case + "/build/bin/llama-bench"
assert d["error"] == ("llama-bench at %s is not a FreeBSD binary; "
                      "build llama.cpp natively (docs/llm.md)" % binary), d["error"]
' "$CASE"; then
	ok "f Linux llama-bench under FreeBSD path: exact native-build refusal"
else
	fail "f Linux llama-bench binary"
fi

# The same path spoof cannot approve a Linux Vulkan library.
setup_case f-FreeBSD-icd radeon radeon radeon
FAKE_LIBRARY_OS=Linux
export FAKE_LIBRARY_OS
run_tool
if basic_result "f Linux Vulkan library" 3 refused "not a native FreeBSD binary"; then
	ok "f Linux ICD under FreeBSD path: rc 3 refused"
else
	fail "f Linux ICD under FreeBSD path"
fi

# g. No index fallback when no Vulkan block has the preflight PCI address.
setup_case g nvidia nvidia wrong-bus
run_tool
if basic_result "g PCI mismatch" 3 refused "pci13:1:0:0"; then
	ok "g Vulkan PCI mismatch: rc 3, no index fallback"
else
	fail "g Vulkan PCI mismatch"
fi

# h. No eligible device is distinct from a refusal.
setup_case h nvidia none nvk
run_tool
if basic_result "h no device" 4 none; then
	ok "h no device of vendor: rc 4, status none"
else
	fail "h no device of vendor"
fi

# i. A failed larger model preserves earlier rows and stops the sequence.
setup_case i radeon radeon radeon
FAKE_BENCH_FAIL_MODEL=llama-2-7b
export FAKE_BENCH_FAIL_MODEL
run_tool
if basic_result "i 7B failure" 1 failed && python3 -I -c '
import json, os, sys
case = sys.argv[1]
d = json.load(open(os.path.join(case, "stdout.json")))
s = json.load(open(os.path.join(case, "out", "summary.json")))
assert len(d["rows"]) == len(s["rows"]) == 2
assert {r["model"] for r in s["rows"]} == {"Llama-3.2-3B-Instruct-Q4_K_M"}
bench = [json.loads(l) for l in open(os.path.join(case, "log", "benchmarks.jsonl"))]
assert len(bench) == 2 and "llama-2-7b" in bench[-1][bench[-1].index("-m") + 1]
' "$CASE" 2>/dev/null; then
	ok "i 7B run failure: rc 1, 3B rows kept, sequence stopped"
else
	fail "i 7B run failure"
fi

# j. A memory refusal is recorded without invoking a benchmark.
setup_case j radeon radeon radeon
FAKE_GPU_FREE_MIB=1
export FAKE_GPU_FREE_MIB
run_tool
if basic_result "j low GPU memory" 1 failed "GPU memory" &&
   [ ! -e "$CASE/log/benchmarks.jsonl" ] && python3 -I -c '
import json, sys
d = json.load(open(sys.argv[1]))
run = [s for s in d["steps"] if s.get("step") == "run"]
assert run and run[0]["status"] == "failed"
assert run[0]["reason"] == "low-gpu-memory"
assert "need " in run[0]["error"] and "free " in run[0]["error"]
assert "MiB" in run[0]["error"] and "bytes" not in run[0]["error"]
skipped = [s for s in d["steps"] if s.get("status") == "skipped"]
assert skipped and skipped[0]["reason"] == "skipped: an earlier run failed"
' "$CASE/stdout.json" 2>/dev/null; then
	ok "j low GPU memory: MiB need/free, recorded skip"
else
	fail "j low GPU memory"
fi

# Host-memory failures use the same explicit MiB need/free diagnostic.
setup_case j-host radeon radeon radeon
FAKE_HOST_FREE_PAGES=1
FAKE_HOST_INACTIVE_PAGES=1
export FAKE_HOST_FREE_PAGES FAKE_HOST_INACTIVE_PAGES
run_tool
if basic_result "j low host memory" 1 failed && python3 -I -c '
import json, sys
d = json.load(open(sys.argv[1]))
run = next(s for s in d["steps"] if s.get("step") == "run")
assert run["reason"] == "low-host-memory", run
assert "need " in run["error"] and "free+inactive " in run["error"], run["error"]
assert "MiB" in run["error"] and "bytes" not in run["error"], run["error"]
' "$CASE/stdout.json"; then
	ok "j low host memory: MiB need and free+inactive"
else
	fail "j low host memory"
fi

# A resource-check exception is still a failed run for that specific model.
setup_case resource-error radeon radeon radeon
rm "$CASE/models/Llama-3.2-3B-Instruct-Q4_K_M.gguf"
run_tool
if basic_result "resource exception" 1 failed "cannot stat model" && python3 -I -c '
import json, sys
d = json.load(open(sys.argv[1]))
runs = [s for s in d["steps"] if s.get("step") == "run"]
assert runs[0]["status"] == "failed", runs
assert runs[0]["model"] == "Llama-3.2-3B-Instruct-Q4_K_M", runs
assert runs[0]["reason"] == "resource-check", runs
assert "cannot stat model" in runs[0]["error"], runs
assert runs[1]["status"] == "skipped", runs
assert runs[1]["reason"] == "skipped: an earlier run failed", runs
' "$CASE/stdout.json"; then
	ok "resource-check exception records the failed model and later skip"
else
	fail "resource-check exception has no per-model run step"
fi

# k. Dry-run emits the two exact plans but never enters llama_bench's run path.
setup_case k radeon radeon radeon
run_tool --dry-run
if basic_result "k dry-run" 0 ok && [ ! -e "$CASE/log/benchmarks.jsonl" ] &&
   python3 -I -c '
import json, sys
d = json.load(open(sys.argv[1]))
r = [s for s in d["steps"] if s.get("step") == "runs"]
assert len(r) == 1 and r[0]["status"] == "dry-run"
assert len(r[0]["planned_commands"]) == 2
assert not d["rows"]
' "$CASE/stdout.json" 2>/dev/null; then
	ok "k dry-run: rc 0, planned commands, no benchmark"
else
	fail "k dry-run"
fi

# l. JSONL contains steps and rows followed by exactly one final summary.
setup_case l radeon radeon radeon
run_tool --jsonl
if [ "$RC" -eq 0 ] && python3 -I -c '
import json, sys
lines = open(sys.argv[1]).read().splitlines()
docs = [json.loads(l) for l in lines]
assert len(docs) > 7
assert docs[-1]["type"] == "summary" and docs[-1]["status"] == "ok"
assert all(d["type"] == "step" for d in docs if "step" in d)
assert sum(d.get("type") == "row" for d in docs) == 6
' "$CASE/stdout.json" 2>/dev/null; then
	ok "l JSONL: every line parses, final line is summary"
else
	fail "l JSONL: rc $RC"
fi

# m. The future NVK/libnvrm path works with no Linux modules loaded.
setup_case m nvidia nvidia nvk
FAKE_KLD=none
VK_DRIVER_FILES=$ICD_DIR/$ICD_NAME
export FAKE_KLD VK_DRIVER_FILES
run_tool
if basic_result "m NVIDIA NVK native" 0 ok && python3 -I -c '
import json, os, sys
case = sys.argv[1]
d = json.load(open(os.path.join(case, "stdout.json")))
m = json.load(open(os.path.join(case, "out", "meta.json")))
assert m["_run"]["card"] == "nvidia-rtx5060ti"
assert len(d["rows"]) == 6
expected = os.path.join(case, "icd", "nvk_nvrm_icd.aarch64.json")
icd = next(s for s in d["steps"] if s.get("step") == "icd")
assert icd["icd"] == icd["VK_DRIVER_FILES"] == expected
commands = [json.loads(l) for l in open(os.path.join(case, "log", "commands.jsonl"))]
assert any(c["command"] == "uname" and c["args"] == ["-p"] for c in commands)
assert all(c["VK_DRIVER_FILES"] == expected for c in commands
           if c["command"] in ("vulkaninfo", "llama-bench"))
assert all(r["card"] == "nvidia-rtx5060ti" for r in d["rows"])
assert all("published_median" in r for r in d["rows"] if r["model"] == "llama-2-7b.Q4_0")
' "$CASE" 2>/dev/null; then
	ok "m NVIDIA NVK happy path: rc 0, card nvidia-rtx5060ti"
else
	fail "m NVIDIA NVK happy path"
fi

# Command overrides are a test-only interface and are named when refused.
setup_case override-without-test radeon radeon radeon
unset NLB_TEST
run_tool
if basic_result "override without NLB_TEST" 2 error "NLB_" && [ ! -e "$CASE/out" ]; then
	ok "NLB_* override without NLB_TEST=1: rc 2, variable named"
else
	fail "NLB_* override without NLB_TEST=1"
fi

# A bare ICD library name is not silently resolved beside its manifest.
setup_case bare-icd radeon radeon radeon
printf '{"ICD":{"library_path":"libvulkan_radeon.so","api_version":"1.4.0"}}\n' \
    > "$ICD_DIR/$ICD_NAME"
run_tool
if basic_result "bare ICD library_path" 3 refused "bare library_path"; then
	ok "bare ICD library_path is refused by name"
else
	fail "bare ICD library_path"
fi

# Every loader or dynamic-loader override except the pinned driver is refused.
for VARIABLE in VK_ADD_DRIVER_FILES VK_ICD_FILENAMES VK_LOADER_DRIVERS_SELECT \
    VK_LOADER_DRIVERS_DISABLE VK_LOADER_LAYERS_ENABLE VK_INSTANCE_LAYERS \
    LD_PRELOAD LD_LIBRARY_PATH; do
	setup_case "loader-$VARIABLE" radeon radeon radeon
	if [ "$VARIABLE" = VK_ICD_FILENAMES ]; then
		eval "$VARIABLE=\$ICD_DIR/\$ICD_NAME"
	elif [ "$VARIABLE" = LD_PRELOAD ]; then
		# An invalid preload kills the interpreter before Python can refuse it.
		eval "$VARIABLE=/lib/libc.so.7"
	else
		eval "$VARIABLE=fixture-value"
	fi
	export "$VARIABLE"
	run_tool
	if basic_result "loader override $VARIABLE" 3 refused "$VARIABLE"; then
		ok "loader override $VARIABLE: rc 3, variable named"
	else
		fail "loader override $VARIABLE"
	fi
	eval "unset $VARIABLE"
done

# n. A nouveau ICD beside the NVK/libnvrm ICD poisons the NVIDIA path.
setup_case n nvidia nvidia nvk
FAKE_KLD=none
export FAKE_KLD
printf '{"ICD":{"library_path":"./libvulkan_nouveau.so","api_version":"1.4.0"}}\n' \
    > "$ICD_DIR/nouveau.json"
run_tool
if basic_result "n nouveau beside NVK" 3 refused "$NOUVEAU_ERROR" &&
   grep -q 'nouveau.json' "$CASE/stdout.json"; then
	ok "n nouveau beside NVK: refusal names nouveau.json"
else
	fail "n nouveau ICD beside NVK"
fi

# o. A nouveau-only ICD directory gets the same specific refusal.
setup_case o nvidia nvidia nvk
FAKE_KLD=none
export FAKE_KLD
rm "$ICD_DIR/$ICD_NAME"
printf '{"ICD":{"library_path":"./libvulkan_nouveau.so","api_version":"1.4.0"}}\n' \
    > "$ICD_DIR/nouveau.json"
run_tool
if basic_result "o only nouveau" 3 refused "$NOUVEAU_ERROR" &&
   grep -q 'nouveau.json' "$CASE/stdout.json"; then
	ok "o only nouveau ICD: refusal names nouveau.json"
else
	fail "o only nouveau ICD"
fi

# An inherited ICD manifest with a nouveau library is rejected as well.
setup_case o-inherited nvidia nvidia nvk
FAKE_KLD=none
export FAKE_KLD
printf '{"ICD":{"library_path":"./libvulkan_nouveau.so","api_version":"1.4.0"}}\n' \
    > "$CASE/inherited-nouveau.json"
VK_ICD_FILENAMES=$CASE/inherited-nouveau.json
export VK_ICD_FILENAMES
run_tool
if basic_result "inherited nouveau ICD" 3 refused "VK_ICD_FILENAMES"; then
	ok "inherited nouveau ICD: refusal names VK_ICD_FILENAMES"
else
	fail "inherited nouveau ICD"
fi

# p. An inherited driver-files override may not replace the selected NVIDIA ICD.
setup_case p nvidia nvidia nvk
printf '{"ICD":{"library_path":"./libvulkan_nvk_nvrm.so","api_version":"1.4.0"}}\n' \
    > "$ICD_DIR/other.json"
VK_DRIVER_FILES=$ICD_DIR/other.json
export VK_DRIVER_FILES
run_tool
if basic_result "p inherited other ICD" 3 refused "VK_DRIVER_FILES"; then
	ok "p inherited VK_DRIVER_FILES at another ICD: rc 3 refused"
else
	fail "p inherited VK_DRIVER_FILES at another ICD"
fi

# The inherited-override refusal also covers Radeon and VK_ICD_FILENAMES.
setup_case p-radeon radeon radeon radeon
printf '{"ICD":{"library_path":"./libvulkan_other.so","api_version":"1.4.0"}}\n' \
    > "$ICD_DIR/other.json"
VK_ICD_FILENAMES=$ICD_DIR/other.json
export VK_ICD_FILENAMES
run_tool
if basic_result "p Radeon inherited other ICD" 3 refused "VK_ICD_FILENAMES"; then
	ok "p Radeon inherited VK_ICD_FILENAMES at another ICD: rc 3 refused"
else
	fail "p Radeon inherited VK_ICD_FILENAMES at another ICD"
fi

# q. The right NVK filename does not make a different library_path eligible.
setup_case q nvidia nvidia nvk
printf '{"ICD":{"library_path":"./libvulkan_radeon.so","api_version":"1.4.0"}}\n' \
    > "$ICD_DIR/$ICD_NAME"
run_tool
if basic_result "q NVK filename wrong library" 3 refused \
    "does not name libvulkan_nvk_nvrm.so"; then
	ok "q NVK filename with another library_path: rc 3 refused"
else
	fail "q NVK filename with another library_path"
fi

# r. An explicit source tag prefixes the complete build description.
setup_case r radeon radeon radeon
run_tool --build-tag b12627
if basic_result "r build tag" 0 ok && python3 -I -c '
import json, os, sys
case = sys.argv[1]
m = json.load(open(os.path.join(case, "out", "meta.json")))
expected = (
    "b12627 version: 1.0.0-dev (build 1, commit 225a534), commit 225a5345b "
    "native FreeBSD build (%s)" % os.path.join(case, "build"))
assert m["_run"]["build"] == expected, m["_run"]["build"]
' "$CASE" 2>/dev/null; then
	ok "r --build-tag prefixes the version and row commit"
else
	fail "r --build-tag prefixes the version and row commit"
fi

# s. A record failure after two successful runs preserves raw data and all rows.
setup_case s radeon radeon radeon
FAKE_VERSION=none
export FAKE_VERSION
run_tool
if basic_result "s record failure" 2 error "returned no first line" && python3 -I -c '
import json, os, sys
case = sys.argv[1]
d = json.load(open(os.path.join(case, "stdout.json")))
s = json.load(open(os.path.join(case, "out", "summary.json")))
assert d["status"] == s["status"] == "error"
assert "returned no first line" in s["error"]
assert len(d["rows"]) == len(s["rows"]) == 6
runs = [step for step in d["steps"] if step.get("step") == "run"]
assert len(runs) == 2 and all(step["status"] == "ok" for step in runs)
record = [step for step in d["steps"] if step.get("step") == "record"]
assert len(record) == 1 and record[0]["status"] == "error"
for model, count in (("Llama-3.2-3B-Instruct-Q4_K_M", 2), ("llama-2-7b.Q4_0", 4)):
    raw = os.path.join(case, "out", "radeon-" + model + ".json")
    assert len(json.load(open(raw))) == count
    assert os.path.isfile(raw[:-5] + ".err")
' "$CASE" 2>/dev/null; then
	ok "s record failure: raw JSON intact, error summary keeps six rows"
else
	fail "s record failure: raw JSON intact, error summary keeps six rows"
fi

# Multiple eligible devices cannot silently select index zero.
setup_case multi radeon multi radeon
run_tool
if basic_result "multiple eligible devices" 3 refused "--device BUS" && python3 -I -c '
import json, sys
d = json.load(open(sys.argv[1]))
assert "pci12:3:0:0" in d["error"] and "pci14:1:0:0" in d["error"], d["error"]
' "$CASE/stdout.json"; then
	ok "multiple eligible devices list both PCI addresses"
else
	fail "multiple eligible devices require --device BUS: rc $RC"
fi

# Probe errors are refusals, not misreported absence of hardware.
for STATUS in error verify-failed; do
	setup_case "preflight-$STATUS" radeon "$STATUS" radeon
	run_tool
	if [ "$STATUS" = error ]; then TEXT='probe failed'; else TEXT='verification failed'; fi
	if basic_result "preflight $STATUS" 3 refused "$TEXT"; then
		ok "hw-preflight $STATUS: rc 3 with helper error"
	else
		fail "hw-preflight $STATUS"
	fi
done

# Failure to resolve dev.nvidia means the NVIDIA kernel module is not loaded.
setup_case nvidia-no-kld nvidia nvidia nvk
FAKE_NVIDIA_SYSCTL=missing
export FAKE_NVIDIA_SYSCTL
run_tool
if basic_result "NVIDIA module missing" 4 none \
    "nvidia.ko is not loaded (load it in a test boot)"; then
	ok "sysctl dev.nvidia failure: status none, exit 4, loadable-module advice"
else
	fail "NVIDIA module missing"
fi

# kldstat -v catches Linux compatibility compiled into the kernel.
for MODULE in linux64elf linuxelf linux_common; do
	setup_case "builtin-$MODULE" nvidia nvidia nvk
	FAKE_KLD=none
	FAKE_KLD_VERBOSE=$MODULE
	export FAKE_KLD FAKE_KLD_VERBOSE
	run_tool
	if basic_result "compiled-in $MODULE" 3 refused "$MODULE"; then
		ok "kldstat -v $MODULE: NVIDIA run refused"
	else
		fail "compiled-in $MODULE"
	fi
done

# Duplicate names require the complete llama-bench order to match vulkaninfo.
setup_case duplicate-mismatch radeon multi duplicate
FAKE_LIST_MODE=duplicate-mismatch
export FAKE_LIST_MODE
run_tool --device pci12:3:0:0
if basic_result "duplicate name order mismatch" 3 refused "order"; then
	ok "duplicate Vulkan deviceName with mismatched order: rc 3"
else
	fail "duplicate Vulkan deviceName order mismatch"
fi

setup_case duplicate-match radeon multi duplicate
FAKE_LIST_MODE=duplicate-match
export FAKE_LIST_MODE
run_tool --device pci12:3:0:0
if basic_result "duplicate name order match" 0 ok && python3 -I -c '
import json, sys
d = json.load(open(sys.argv[1]))
step = next(s for s in d["steps"] if s.get("step") == "device")
assert step["vulkan_index"] == 0 and step["bus"] == "pci12:3:0:0", step
' "$CASE/stdout.json"; then
	ok "duplicate Vulkan deviceName with matching order is accepted"
else
	fail "duplicate Vulkan deviceName matching order"
fi

# A different declared model disables median attachment instead of comparing 7B.
setup_case medians-other-model radeon radeon radeon
python3 -I -c '
import json, sys
d = json.load(open(sys.argv[1]))
d["model"] = "other"
json.dump(d, open(sys.argv[2], "w"))
' "$MEDIANS" "$CASE/medians.json"
MEDIANS=$CASE/medians.json
run_tool
if basic_result "declared median model" 0 ok && python3 -I -c '
import json, sys
d = json.load(open(sys.argv[1]))
assert len(d["rows"]) == 6
assert all("published_median" not in row for row in d["rows"])
' "$CASE/stdout.json"; then
	ok "medians attach only to the model declared by the file"
else
	fail "declared median model"
fi
MEDIANS=$TESTSDIR/../docs/published-medians.json

# The median file has one source list per card/backend and no decorative flag.
python3 -I -c '
import json, sys
d = json.load(open(sys.argv[1]))
assert d["model"] == "llama-2-7b.Q4_0"
groups = d["groups"]
assert len(groups) == 3
assert {(g["card"], g["backend"]) for g in groups} == {
    ("amd-rx7600", "vulkan"), ("nvidia-rtx5060ti", "vulkan"),
    ("nvidia-rtx5060ti", "cuda")}
for group in groups:
    assert isinstance(group["sources"], list) and group["sources"]
    assert len(group["results"]) == 4
    assert "reference_only" not in group
    assert all("sources" not in result and "reference_only" not in result
               for result in group["results"])
' "$MEDIANS"
if [ "$?" -eq 0 ]; then
	ok "published medians are grouped with one source list per card/backend"
else
	fail "published medians grouping"
fi

# The default run stamp has second resolution.
if GB10_WORK=$WORK/stamp-work SCRIPT_UNDER_TEST=$SCRIPT python3 -I -c '
import os, re, runpy
module = runpy.run_path(os.environ["SCRIPT_UNDER_TEST"])
opts = module["parse_cli"](["--gpu", "radeon"])
name = os.path.basename(opts["out"])
assert re.fullmatch(r"[0-9]{8}T[0-9]{6}Z-native-radeon-radv", name), name
'; then
	ok "default run directory stamp includes seconds"
else
	fail "default run directory stamp includes seconds"
fi

# Usage errors keep help out of the JSON error string and print it once to stderr.
"$SCRIPT" > "$WORK/no-gpu.json" 2> "$WORK/no-gpu.err"
RC=$?
if [ "$RC" -eq 2 ] && python3 -I -c '
import json, sys
d = json.load(open(sys.argv[1]))
assert d["error"] == "--gpu must be nvidia or radeon", d["error"]
assert "usage:" not in d["error"]
human = open(sys.argv[2]).read()
assert human.count("usage: native-llm-bench") == 1, human
assert human.count("--gpu must be nvidia or radeon") == 1, human
' "$WORK/no-gpu.json" "$WORK/no-gpu.err"; then
	ok "usage error: one-line JSON error, usage only on stderr"
else
	fail "usage error JSON/human separation"
fi

"$SCRIPT" --help > "$WORK/help.txt" 2>/dev/null
RC=$?
if [ "$RC" -eq 0 ] && SCRIPT_UNDER_TEST=$SCRIPT python3 -c '
import os, runpy, sys
module = runpy.run_path(os.environ["SCRIPT_UNDER_TEST"])
lines = open(sys.argv[1]).read().splitlines()
assert all(len(line) <= 79 for line in lines), [(len(x), x) for x in lines if len(x) > 79]
text = "\n".join(lines)
for option in list(module["VALUE_OPTIONS"]) + ["--dry-run", "--jsonl", "--help"]:
    assert option in text, option
' "$WORK/help.txt"; then
	ok "--help lists every option and fits 80 columns"
else
	fail "--help: rc $RC, missing option or overlong line"
fi

# mdoc semantics: real cross references, no empty list items, working example.
MAN=$TESTSDIR/../man/native-llm-bench.1
# Resolve both Xr targets without installing host manuals; style includes warnings.
mkdir -p "$WORK/man/man1"
cp "$TESTSDIR/../man/native-path-check.1" "$WORK/man/man1/native-path-check.1"
cat > "$WORK/man/man1/vulkaninfo.1" <<'EOF'
.Dd November 22, 2026
.Dt VULKANINFO 1
.Os
.Sh NAME
.Nm vulkaninfo
.Nd test-only cross-reference target
EOF
makewhatis "$WORK/man"
MANPATH="$WORK/man" mandoc -T lint -W style "$MAN" > "$WORK/mandoc-lint.txt" 2>&1
RC=$?
if [ "$RC" -eq 0 ] && python3 -I -c '
import sys
lines = open(sys.argv[1]).read().splitlines()
assert ".Xr native-path-check 1 ," in lines
assert ".Xr vulkaninfo 1 ," in lines
assert "native-llm-bench --gpu radeon --dry-run" in lines
for n, line in enumerate(lines[:-1]):
    assert not (line.startswith(".It ") and lines[n + 1].startswith(".It ")), (n + 1, line)
' "$MAN"; then
	ok "man page macros, environment list, Radeon example and mandoc lint"
else
	fail "man page macros/examples or mandoc lint (rc $RC)"
fi

printf '%s passed, %s failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]

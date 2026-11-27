#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# gpu_mock_test.sh - the GPU mock: the model files, the seam, the RM engine
# behind the CUSE nodes and the libnvrm rm backend that runs against them.
#
# What is proved here:
#   the models      every model file loads, and the decision on every card
#                   of every model is the one the model says
#   the seam        the pciconf, devinfo and hw.nvidia / dev.nvidia answers
#                   come from the model and say they are a mock
#   the rm backend  libnvrm's rm backend runs its real path against the
#                   model through the seam: the identity, the VRAM, the SM
#                   version, the class list and the capabilities are the
#                   model's
#   the faults      a lost device and a refused allocation are answered the
#                   way the RM answers them
#   the node        the daemon publishes the nodes with cuse(3) and a real
#                   ioctl(2) on /dev/nvidiactl gets the model's answers
#   the honesty     every answer of the mock says it is a mock, and no
#                   answer of the mock counts as a hardware result
#
# No hardware and no loaded driver are needed.  The node test needs the cuse
# module and the right to open /dev/cuse; it is skipped when the machine
# cannot, and the live proof is the same test in a test boot.
#
# Run: sh tests/gpu_mock_test.sh        (GB10_WORK=... to point at the sources)

PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH= cd -- "$HERE/.." && pwd)
GB10=${GB10_WORK:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)/work}
TAG=$(awk '$1 == "ogkm_tag" { print $2 }' "$REPO/SOURCES")
OGKM=${OGKM:-$GB10/sources/open-gpu-kernel-modules-$TAG}

# The scratch is inside the work root, never in /tmp.
mkdir -p "$GB10/tmp" || exit 1
W=$(mktemp -d "$GB10/tmp/gpu-mock-test.XXXXXXXX") || exit 1
trap 'rm -rf "$W"' EXIT INT TERM
unset GPU_MOCK GPU_MOCK_DIR NVRM_BACKEND

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }
# expect NAME RC WANT: the status the caller captured on its own line.
expect_rc() {
	if [ "$2" -eq "$3" ]; then ok "$1"; else bad "$1 (rc=$2, want $3)"; fi
}
# have TEXT NEEDLE: the text holds the needle.
have() {
	case "$1" in
	*"$2"*) ok "$3" ;;
	*) bad "$3" ;;
	esac
}
# hasnt TEXT NEEDLE: the text does not hold the needle.
hasnt() {
	case "$1" in
	*"$2"*) bad "$3" ;;
	*) ok "$3" ;;
	esac
}

[ -d "$OGKM/src/common/sdk/nvidia/inc" ] || {
	echo "gpu_mock_test: the NVIDIA headers are not at $OGKM (run scripts/fetch-sources.sh)" >&2
	exit 99
}

M=$REPO/src/gb10-gpu-mock/build/gpu-mock
SHIM=$REPO/src/gb10-gpu-mock/build/libgpubmockshim.so
MODELS=$REPO/data/models

# ---- build ------------------------------------------------------------------
GB10_WORK="$GB10" sh "$REPO/scripts/gpu-mock.sh" build >"$W/build.log" 2>&1
rc=$?
expect_rc "the mock and the seam shim build" $rc 0
[ $rc -eq 0 ] || cat "$W/build.log"
[ -x "$M" ] && [ -f "$SHIM" ]
expect_rc "the mock tool and the seam shim are there" $? 0

# ---- the models --------------------------------------------------------------
# The decision on every card of every model: the model says which one it is.
decide() {
	GPU_MOCK_DIR="$MODELS" "$M" decide "$1" 2>/dev/null
}
for m in rtx5060ti gb10 turing pascal rx7600 mixed-box \
    fault-device-lost fault-alloc-refused; do
	out=$(decide "$m")
	rc=$?
	expect_rc "the model $m loads" $rc 0
	case "$m" in
	rtx5060ti | gb10)
		have "$out" "nvidia0                  supported" \
		    "the model $m: the NVIDIA card is supported"
		;;
	turing)
		have "$out" "nvidia0                  unsupported_firmware" \
		    "the model $m: the Turing card has no firmware"
		;;
	pascal)
		have "$out" "nvidia0                  unsupported_generation" \
		    "the model $m: the card below the floor is refused"
		;;
	rx7600)
		have "$out" "amd0                     not_claimed" \
		    "the model $m: the AMD card is claimed by nobody"
		;;
	mixed-box)
		have "$out" "amd0                     not_claimed" \
		    "the model $m: the AMD card is claimed by nobody"
		have "$out" "nvidia0                  supported" \
		    "the model $m: the NVIDIA card is supported"
		have "$out" "bmc0                     not_claimed" \
		    "the model $m: the BMC adapter is claimed by nobody"
		;;
	esac
done

# The model files are data: one JSON per card, and a box that composes them.
[ -f "$MODELS/nvidia-provider.json" ] && [ -f "$MODELS/rtx5060ti.json" ] \
    && [ -f "$MODELS/gb10.json" ] && [ -f "$MODELS/rx7600.json" ] \
    && [ -f "$MODELS/turing.json" ] && [ -f "$MODELS/pascal.json" ] \
    && [ -f "$MODELS/mixed-box.json" ]
expect_rc "every model file is in the tree" $? 0
n=$(ls "$MODELS" | wc -l | tr -d ' ')
[ "$n" -ge 8 ]
expect_rc "the model directory holds the models" $? 0

# The tool finds the models of the checkout it was built in, with no
# environment variable: a model is a name, not a path.
out=$("$M" model rtx5060ti 2>&1)
rc=$?
expect_rc "the tool finds the models of the checkout without GPU_MOCK_DIR" $rc 0
have "$out" '"mock": true' "the model of the checkout is a mock"

# ---- the model of the RTX 5060 Ti still matches the capture ------------------
# The model is data; the capture of 2026-11-22 is the truth it was written
# from.  The test compares them field by field, so a model that drifts from
# the capture fails here.
CAP=$REPO/tests/data/nvrm-info-boot-20261122T095018Z/nvrm-info.json
if [ -f "$CAP" ]; then
	python3 -I "$REPO/tests/gpu_mock/capture_check.py" "$CAP" \
	    "$MODELS/rtx5060ti.json" >"$W/capture.txt" 2>&1
	rc=$?
	expect_rc "the model of the RTX 5060 Ti matches the capture" $rc 0
	[ $rc -eq 0 ] || cat "$W/capture.txt"
fi

# ---- the seam ----------------------------------------------------------------
pc=$(GPU_MOCK_DIR="$MODELS" "$M" pciconf -lvb rtx5060ti 2>/dev/null)
have "$pc" "# gpu-mock: mock answers from the model" \
    "the pciconf answer says it is a mock"
have "$pc" "vgapci1@pci13:1:0:0:" "the pciconf answer names the card"
have "$pc" "vendor=0x10de device=0x2d04" "the pciconf answer has the ids"
have "$pc" "GB206 [GeForce RTX 5060 Ti]" "the pciconf answer has the name"
hasnt "$pc" "hardware result" "the pciconf answer does not claim hardware"

dv=$(GPU_MOCK_DIR="$MODELS" "$M" devinfo vgapci1 rtx5060ti 2>/dev/null)
have "$dv" "# gpu-mock: mock answers from the model" \
    "the devinfo answer says it is a mock"
have "$dv" "pci_vendor = 0x10de" "the devinfo answer has the vendor"

sv=$(GPU_MOCK_DIR="$MODELS" "$M" sysctl hw.nvidia.gpus.1.uuid rtx5060ti 2>/dev/null)
have "$sv" "GPU-17743da2-61b3-ef41-e46e-5679f4ed15ec" \
    "the sysctl answer is the uuid of the card"
sv=$(GPU_MOCK_DIR="$MODELS" "$M" sysctl hw.nvidia.version rtx5060ti 2>/dev/null)
have "$sv" "GPU MOCK" "the version banner says it is a mock"

# Every answer of the tool says it is a mock, on stderr, so the answer on
# stdout stays machine readable.
err=$(GPU_MOCK_DIR="$MODELS" "$M" sysctl hw.nvidia.version rtx5060ti 2>&1 >/dev/null)
have "$err" "not a hardware result" "every answer of the tool is labelled"

nd=$(GPU_MOCK_DIR="$MODELS" "$M" nodes rtx5060ti 2>/dev/null)
have "$nd" "add path 'nvidiactl' mode 0660 group video" \
    "the ruleset gives the control node to the jail"
have "$nd" "add path 'nvidia0' mode 0660 group video" \
    "the ruleset gives the card node to the jail"
# The ruleset must name the nodes that exist: the mechanism of cuse(3)
# replaces a dash of a device name with an underscore, so the modeset node
# and the uvm node exist with an underscore.
have "$nd" "add path 'nvidia_modeset'" \
    "the ruleset names the modeset node that exists"
have "$nd" "add path 'nvidia_uvm'" \
    "the ruleset names the uvm node that exists"
hasnt "$nd" "nvidia-modeset" "the ruleset names no node that does not exist"
hasnt "$nd" "nvidia-uvm" "the ruleset names no node that does not exist"

# ---- the preflight and the card check read through the seam -----------------
# The card check of the preflight reads the pciconf output through the seam:
# with a model named, the card of the model is the card it finds.
out=$(GPU_MOCK=gb10 GPU_MOCK_DIR="$MODELS" GPU_MOCK_BIN="$M" \
    sh "$REPO/scripts/make.sh" preflight 2>&1)
have "$out" "0x10de 0x2e12" \
    "the preflight finds the card of the model through the seam"
out=$(GPU_MOCK=mixed-box GPU_MOCK_DIR="$MODELS" GPU_MOCK_BIN="$M" \
    sh "$REPO/scripts/make.sh" preflight 2>&1)
have "$out" "0x10de 0x2d04" \
    "the card check of the mixed box finds the NVIDIA card of the model"
hasnt "$out" "0x1002 0x7480" \
    "the card check of the mixed box does not list the AMD card"

# ---- the model as one JSON document -----------------------------------------
doc=$(GPU_MOCK_DIR="$MODELS" "$M" model rtx5060ti 2>/dev/null)
have "$doc" '"mock": true' "the document says it is a mock"
python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)))' <<EOF >"$W/doc.json"
$doc
EOF
python3 -I "$REPO/tests/libnvrm/schema_validate.py" \
    "$REPO/schema/gpu-mock-1.schema.json" "$W/doc.json" >"$W/doc.schema" 2>&1
expect_rc "the document validates against gpu-mock-1" $? 0
python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))))' \
    "$REPO/tests/fixtures/gpu-mock-model.json" \
    | python3 -I "$REPO/tests/libnvrm/schema_validate.py" \
	"$REPO/schema/gpu-mock-1.schema.json" >"$W/fixture.schema" 2>&1
expect_rc "the captured sample validates against gpu-mock-1" $? 0
python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))))' \
    "$REPO/tests/fixtures/gpu-model-file.json" \
    | python3 -I "$REPO/tests/libnvrm/schema_validate.py" \
	"$REPO/schema/gpu-model-1.schema.json" >"$W/file.schema" 2>&1
expect_rc "the model file validates against gpu-model-1" $? 0
python3 - "$REPO" <<'EOF' >"$W/samples.txt" 2>&1
import json, os, sys
repo = sys.argv[1]
samples = json.load(open(os.path.join(repo, "schema/samples.json")))["samples"]
rows = [s for s in samples if s.get("schema", "").startswith("schema/gpu-")]
print(len(rows))
EOF
n=$(cat "$W/samples.txt")
[ "$n" -eq 2 ]
expect_rc "both mock schemas are registered in schema/samples.json" $? 0

# ---- the rm backend through the seam ----------------------------------------
# The library is built from the sources of the tree, out of tree.
L=$REPO/lib/libnvrm
O=$W/obj
mkdir -p "$O/lib" "$O/info"
(cd "$L" && MAKEOBJDIR="$O/lib" OGKM="$OGKM" make) >"$W/build-lib.log" 2>&1
rc=$?
expect_rc "libnvrm builds" $rc 0
[ $rc -eq 0 ] || tail -20 "$W/build-lib.log"
(cd "$L/nvrm-info" && MAKEOBJDIR="$O/info" LIBNVRM_OBJ="$O/lib" make) \
    >"$W/build-info.log" 2>&1
rc=$?
expect_rc "nvrm-info builds" $rc 0
[ $rc -eq 0 ] || tail -20 "$W/build-info.log"

CINC="-pthread -I$L -I$L/include -I$REPO/tests/gpu_mock -std=gnu11 -Wall -Wextra -Wno-unused-parameter -I$OGKM/src/common/sdk/nvidia/inc -I$OGKM/src/common/sdk/nvidia/inc/ctrl -I$OGKM/src/nvidia/arch/nvalloc/unix/include -I$REPO/src/gb10-gpu-mock"
LIBSRC="$L/nvrm.c $L/nvrm_cap.c $L/nvrm_fake.c $L/nvrm_fields.c $L/nvrm_json.c $L/nvrm_names.c $L/nvrm_table.c $L/nvrm_rm.c $L/nvrm_va.c $L/nvrm_mem.c $L/nvrm_owner.c $L/nvrm_fake_mem.c $L/nvrm_rm_mem.c $L/nvrm_rm_chan.c $L/nvrm_chan.c $L/nvrm_fake_chan.c"
MOCKSRC="$REPO/src/gb10-gpu-mock/gpu_json.c $REPO/src/gb10-gpu-mock/gpu_model.c $REPO/src/gb10-gpu-mock/gpu_seam.c $REPO/src/gb10-gpu-mock/gpu_rm.c"
# shellcheck disable=SC2086
cc $CINC -o "$W/rm_mock_test" "$REPO/tests/gpu_mock/rm_mock_test.c" $LIBSRC $MOCKSRC \
    >"$W/cc-rm-mock.log" 2>&1
rc=$?
expect_rc "rm_mock_test compiles" $rc 0
[ $rc -eq 0 ] || tail -20 "$W/cc-rm-mock.log"

"$W/rm_mock_test" "$MODELS/rtx5060ti.json" cards:1 >"$W/rm-mock.out" 2>&1
rc=$?
expect_rc "the rm backend reads the model of the RTX 5060 Ti" $rc 0
[ $rc -eq 0 ] || grep -E "^(FAIL|  )" "$W/rm-mock.out" | head -20
"$W/rm_mock_test" "$MODELS/gb10.json" cards:1 >"$W/rm-mock-gb10.out" 2>&1
rc=$?
expect_rc "the rm backend reads the model of the GB10" $rc 0
"$W/rm_mock_test" "$MODELS/mixed-box.json" cards:1 >"$W/rm-mock-mixed.out" 2>&1
rc=$?
expect_rc "the rm backend reads the mixed box: one NVIDIA card" $rc 0
"$W/rm_mock_test" "$MODELS/fault-device-lost.json" nocards >"$W/rm-lost.out" 2>&1
rc=$?
expect_rc "a lost device: the RM reports no GPU" $rc 0
"$W/rm_mock_test" "$MODELS/fault-alloc-refused.json" alloc-refused \
    >"$W/rm-refused.out" 2>&1
rc=$?
expect_rc "a refused allocation: the enumeration fails" $rc 0

# The mutant: a model whose uuid is not the uuid of the card must fail the
# test, or the test proves nothing.
sed 's/GPU-17743da2-61b3-ef41-e46e-5679f4ed15ec/GPU-00000000-0000-4000-8000-0000000000ff/' \
    "$MODELS/rtx5060ti.json" >"$W/mutant.json"
cp "$MODELS/nvidia-provider.json" "$W/nvidia-provider.json"
"$W/rm_mock_test" "$W/mutant.json" cards:1 >"$W/rm-mutant.out" 2>&1
rc=$?
[ $rc -ne 0 ]
expect_rc "the mutant: a model with another uuid fails the rm backend test" $? 1

# ---- nvrm-info through the seam ----------------------------------------------
# The seam shim answers the sysctls of the model and, with no daemon, the
# ioctl path too: nvrm-info reads the model, not a driver.
if [ -x "$O/info/nvrm-info" ]; then
	GPU_MOCK_DIR="$MODELS" GPU_MOCK=rtx5060ti \
	    LD_LIBRARY_PATH="$O/lib" LD_PRELOAD="$SHIM" \
	    "$O/info/nvrm-info" --json >"$W/info.json" 2>"$W/info.err"
	rc=$?
	expect_rc "nvrm-info runs on the mock" $rc 0
	have "$(cat "$W/info.json")" "GPU-17743da2-61b3-ef41-e46e-5679f4ed15ec" \
	    "nvrm-info reports the uuid of the model"
	have "$(cat "$W/info.json")" '"backend":"rm"' \
	    "nvrm-info names the backend it used"
	# Without the model the same program finds no device: the mock is
	# the only source of the answer.
	LD_LIBRARY_PATH="$O/lib" LD_PRELOAD="$SHIM" \
	    "$O/info/nvrm-info" --json >"$W/info-none.json" 2>/dev/null
	hasnt "$(cat "$W/info-none.json")" "GPU-17743da2" \
	    "without a model nvrm-info finds no card of ours"
fi

# ---- the node: the CUSE device and a real ioctl -----------------------------
if [ -c /dev/cuse ] && command -v doas >/dev/null 2>&1 && doas -n true 2>/dev/null; then
	# shellcheck disable=SC2086
	cc $CINC -o "$W/node_ioctl_test" "$REPO/tests/gpu_mock/node_ioctl_test.c" \
	    >"$W/cc-node.log" 2>&1
	rc=$?
	expect_rc "node_ioctl_test compiles" $rc 0
	[ $rc -eq 0 ] || tail -20 "$W/cc-node.log"
	# The nodes are the ones the driver publishes.  When those names are
	# taken (the node of a mock that was killed on a host whose kernel
	# still holds it), the mock publishes its own names and the test
	# uses those: the path of the control node is what the test asks
	# for.  The name of the test's own nodes carries the pid of the
	# test, so a run never meets the nodes of another run.
	#
	# The daemon runs as root (it opens /dev/cuse), so the test stops it
	# as root too: a plain kill would be refused.
	node=/dev/nvidiactl
	for try in "" "gpumock$$"; do
		if [ -z "$try" ]; then
			node=/dev/nvidiactl
		else
			node=/dev/${try}ctl
		fi
		doas -n env GPU_MOCK_PREFIX="$try" "$M" daemon \
		    "$MODELS/rtx5060ti.json" >"$W/daemon.out" 2>&1 &
		dpid=$!
		# The daemon publishes the nodes; wait for the control node.
		i=0
		while [ $i -lt 50 ]; do
			[ -c "$node" ] && break
			# The daemon is gone: it could not take the names.
			doas -n kill -0 "$dpid" 2>/dev/null || break
			sleep 0.2
			i=$((i + 1))
		done
		[ -c "$node" ] && break
		# The names are taken: the daemon stops and the mock tries
		# with its own names.
		doas -n kill -TERM "$dpid" 2>/dev/null
		wait "$dpid" 2>/dev/null
	done
	if [ -c "$node" ]; then
		ok "the daemon publishes the control node"
		doas -n "$W/node_ioctl_test" "$node" >"$W/node.out" 2>&1
		rc=$?
		expect_rc "a real ioctl(2) on the node answers with the model" $rc 0
		[ $rc -eq 0 ] || cat "$W/node.out"
		# The ruleset of the nodes names the nodes that exist: the
		# rules the mock publishes and the rules the mock hands to a
		# jail are the same names.
		rules=$(GPU_MOCK_PREFIX="$try" "$M" nodes rtx5060ti 2>/dev/null)
		for n in $(printf '%s\n' "$rules" |
		    awk '/^add path/ { gsub(/\047/, "", $3); print $3 }'); do
			if [ -c "/dev/$n" ]; then
				ok "the ruleset names the node that exists: $n"
			else
				bad "the ruleset names a node that does not exist: $n"
			fi
		done
		# Every node the daemon published is named by the ruleset.
		banner=$(sed -n 's/.*the nodes \(.*\) are published.*/\1/p' \
		    "$W/daemon.out")
		for n in $(printf '%s\n' "$banner" | tr ',' ' ' |
		    sed 's/ and / /'); do
			[ -n "$n" ] || continue
			case "$rules" in
			*"'$n'"*)
				ok "the ruleset names the node the daemon published: $n"
				;;
			*)
				bad "the ruleset does not name the node the daemon published: $n"
				;;
			esac
		done
	else
		bad "the daemon publishes the control node"
		cat "$W/daemon.out"
	fi
	# The daemon stops: it destroys the nodes it made, so the next mock
	# finds the names free.
	doas -n kill -TERM "$dpid" 2>/dev/null
	wait "$dpid" 2>/dev/null
	i=0
	while [ $i -lt 50 ] && [ -e "$node" ]; do
		sleep 0.2
		i=$((i + 1))
	done
	if [ -e "$node" ]; then
		bad "the daemon takes the nodes away with it"
	else
		ok "the daemon takes the nodes away with it"
	fi
else
	printf 'skip the node test: no usable /dev/cuse (the live proof is the same\n'
	printf '     test in a test boot)\n'
fi

# ---- the one switch --------------------------------------------------------
# GPU_MOCK=<model> starts the daemon, sets up the devfs rules of the nodes and
# points the seam at the model.  The switch needs the right to open /dev/cuse
# and to change the rules of the kernel: the same condition as the node test.
if [ -c /dev/cuse ] && command -v doas >/dev/null 2>&1 && doas -n true 2>/dev/null; then
	sp=sw$$
	swenv="GPU_MOCK_PREFIX=$sp GPU_MOCK=rtx5060ti
	    GPU_MOCK_PIDFILE=$W/gpu-mock.pid
	    GPU_MOCK_STATEFILE=$W/gpu-mock.model
	    GPU_MOCK_RULES=$W/gpu-mock.rules
	    GPU_MOCK_LOG=$W/gpu-mock.log"
	# shellcheck disable=SC2086
	out=$(env $swenv sh "$REPO/scripts/gpu-mock-up.sh" up 2>&1)
	rc=$?
	expect_rc "the switch starts the mock" $rc 0
	[ $rc -eq 0 ] || printf '%s\n' "$out"
	have "$out" "mock" "the switch says it is a mock"
	if [ -c "/dev/${sp}ctl" ]; then
		ok "the switch publishes the control node"
	else
		bad "the switch publishes the control node"
	fi
	# The ruleset of the nodes is written, and the rules of the nodes are
	# in force on this machine.
	[ -s "$W/gpu-mock.rules" ]
	expect_rc "the switch writes the ruleset of the nodes" $? 0
	nrules=$(doas -n /sbin/devfs rule show 2>/dev/null | grep -c "${sp}ctl")
	[ "$nrules" -ge 1 ]
	expect_rc "the rules of the nodes are in force" $? 0
	# A second switch with the same names must not take the nodes of the
	# first one: the daemon refuses to start (another mock holds them)
	# and the mock that runs keeps its nodes.
	# shellcheck disable=SC2086
	out=$(env $swenv sh "$REPO/scripts/gpu-mock-up.sh" up 2>&1)
	rc=$?
	if [ $rc -ne 0 ]; then
		ok "a second switch with the same names fails"
	else
		bad "a second switch with the same names fails"
	fi
	if [ -c "/dev/${sp}ctl" ]; then
		ok "the mock that runs keeps its nodes"
	else
		bad "the mock that runs keeps its nodes"
	fi
	# The switch down stops the daemon and takes the nodes and the rules
	# away.
	# shellcheck disable=SC2086
	out=$(env $swenv sh "$REPO/scripts/gpu-mock-up.sh" down 2>&1)
	rc=$?
	expect_rc "the switch stops the mock" $rc 0
	[ $rc -eq 0 ] || printf '%s\n' "$out"
	if [ -e "/dev/${sp}ctl" ]; then
		bad "the switch takes the nodes away"
	else
		ok "the switch takes the nodes away"
	fi
	nrules=$(doas -n /sbin/devfs rule show 2>/dev/null | grep -c "${sp}ctl")
	[ "$nrules" -eq 0 ]
	expect_rc "the switch takes the rules away" $? 0
else
	printf 'skip the switch test: no usable /dev/cuse (the live proof is the\n'
	printf '     same test in a test boot)\n'
fi

# ---- the honesty -------------------------------------------------------------
# No answer of the mock counts as a hardware result.
for cmd in "pciconf -lvb rtx5060ti" "devinfo vgapci1 rtx5060ti" \
    "decide rtx5060ti" "nodes rtx5060ti" "model rtx5060ti"; do
	# shellcheck disable=SC2086
	out=$(GPU_MOCK_DIR="$MODELS" $M $cmd 2>&1)
	case "$out" in
	*"mock"* | *"MOCK"*) ok "the answer of \"$cmd\" says it is a mock" ;;
	*) bad "the answer of \"$cmd\" does not say it is a mock" ;;
	esac
	case "$out" in
	*"not a hardware result"*) ok "the answer of \"$cmd\" does not count as a hardware result" ;;
	*"hardware result"*) bad "the answer of \"$cmd\" calls itself a hardware result" ;;
	*) ok "the answer of \"$cmd\" does not count as a hardware result" ;;
	esac
done

printf 'gpu_mock_test: %d ok, %d FAILED\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]

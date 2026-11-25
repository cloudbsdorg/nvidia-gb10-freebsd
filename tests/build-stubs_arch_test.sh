#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# build-stubs_arch_test.sh - scripts/build-stubs.sh links stubs onto the
# RM core for the running architecture (Track #2475). Offline: a fake
# ogkm copy and hooked cc/ld.lld, no kldload. Scratch under work/tmp,
# never /tmp.
#   (a) Hooked amd64: default CORE_OBJ is $GB10_WORK/build/nv-kernel-amd64.o,
#       default LINKED_OBJ stays $GB10_WORK/build/nv-kernel-gb10.o, cc is
#       not given AArch64 ISA flags or -mbranch-protection=standard, and
#       is given -DNV_X86_64 and the OGKM x86_64 kernel flags
#       (-msoft-float -mno-red-zone -mcmodel=kernel -mno-mmx -mno-sse
#       -mno-sse2 -mno-3dnow). ld is ld.lld -r.
#   (b) Hooked aarch64: default CORE_OBJ is nv-kernel-aarch64.o, LINKED_OBJ
#       stays nv-kernel-gb10.o, and today's AArch64 flags remain
#       (-DNV_AARCH64, -mgeneral-regs-only, -march=armv8-a,
#       -mstrict-align, -ffixed-x18, -mno-outline-atomics, and
#       -mbranch-protection=standard). The arm64 path is unchanged.
#   (c) Live FreeBSD amd64 with no arch hook: same defaults as (a).
# Hooks: GB10_TEST_HOOKS=1, GB10_TEST_ARCH=amd64|aarch64, CC, LD.

set -u
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL

TESTSDIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo=$(CDPATH='' cd -- "$TESTSDIR/.." && pwd -P)
SCRIPT="$repo/scripts/build-stubs.sh"
base=${GB10_WORK:-$repo/work}
mkdir -p -- "$base/tmp"
TESTROOT=$(mktemp -d "$base/tmp/stubs-arch.XXXXXX") || exit 1

PASSED=0
FAILED=0
ok() { PASSED=$((PASSED + 1)); printf 'ok    %s\n' "$1"; }
fail() { FAILED=$((FAILED + 1)); printf 'FAIL  %s\n' "$1"; }
cleanup() { rm -rf "$TESTROOT"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [ ! -f "$SCRIPT" ]; then
	fail "scripts/build-stubs.sh does not exist"
	echo "passed: $PASSED failed: $FAILED"
	exit 1
fi

mkdir -p "$TESTROOT/build/ogkm/src/nvidia" "$TESTROOT/build/tree/nvidia" "$TESTROOT/tmp" "$TESTROOT/hooks"
printf 'int stub(void) { return 0; }\n' > "$TESTROOT/stubs.c"
printf 'int core(void) { return 0; }\n' > "$TESTROOT/core.c"

# Fake cc/ld record their arguments and write placeholder objects.
# GMEOF is unquoted except we expand TESTROOT once when writing the file.
cat > "$TESTROOT/hooks/cc" <<GMEOF
#!/bin/sh
printf '%s\n' "\$@" > "$TESTROOT/cc-args"
i=0
out=
prev=
for a in "\$@"; do
	if [ "\$prev" = -o ]; then out=\$a; fi
	prev=\$a
done
[ -n "\$out" ] || out=$TESTROOT/hooks/cc-out.o
: > "\$out"
exit 0
GMEOF
cat > "$TESTROOT/hooks/ld" <<GMEOF
#!/bin/sh
printf '%s\n' "\$@" > "$TESTROOT/ld-args"
out=
prev=
for a in "\$@"; do
	if [ "\$prev" = -o ]; then out=\$a; fi
	prev=\$a
done
[ -n "\$out" ] || out=$TESTROOT/hooks/ld-out.o
: > "\$out"
exit 0
GMEOF
chmod 755 "$TESTROOT/hooks/cc" "$TESTROOT/hooks/ld"

# A dummy "OS layer" object so count_missing can run if the script
# reaches it. nm on an empty file may fail; write a tiny ELF if we can.
if ! cc -c -fno-stack-protector -o "$TESTROOT/build/tree/nvidia/os.o" "$TESTROOT/core.c" 2>/dev/null; then
	printf 'os\n' > "$TESTROOT/build/tree/nvidia/os.o"
fi
cp "$TESTROOT/build/tree/nvidia/os.o" "$TESTROOT/core-obj.o"

reset() {
	rm -f "$TESTROOT/build/nv-kernel-amd64.o" "$TESTROOT/build/nv-kernel-aarch64.o" \
		"$TESTROOT/build/nv-kernel-gb10.o" "$TESTROOT/build/nv-gb10-stubs.o" \
		"$TESTROOT/cc-args" "$TESTROOT/ld-args"
}

run_missing() {
	_arch=$1
	_tag=$2
	reset
	rc=0
	GB10_WORK="$TESTROOT" GB10_TEST_HOOKS=1 GB10_TEST_ARCH="$_arch" \
		CC="$TESTROOT/hooks/cc" LD="$TESTROOT/hooks/ld" \
		STUBS_SRC="$TESTROOT/stubs.c" \
		sh "$SCRIPT" >"$TESTROOT/out-$_tag" 2>"$TESTROOT/err-$_tag" || rc=$?
	echo "$rc"
}

run_full() {
	_arch=$1
	_tag=$2
	_hooked=$3
	reset
	# Place the core object at the name this arch should use as default.
	case $_arch in
	amd64) cp "$TESTROOT/core-obj.o" "$TESTROOT/build/nv-kernel-amd64.o" ;;
	aarch64) cp "$TESTROOT/core-obj.o" "$TESTROOT/build/nv-kernel-aarch64.o" ;;
	esac
	rc=0
	if [ "$_hooked" = hook ]; then
		GB10_WORK="$TESTROOT" GB10_TEST_HOOKS=1 GB10_TEST_ARCH="$_arch" \
			CC="$TESTROOT/hooks/cc" LD="$TESTROOT/hooks/ld" \
			STUBS_SRC="$TESTROOT/stubs.c" \
			sh "$SCRIPT" >"$TESTROOT/out-$_tag" 2>"$TESTROOT/err-$_tag" || rc=$?
	else
		GB10_WORK="$TESTROOT" GB10_TEST_HOOKS=1 \
			CC="$TESTROOT/hooks/cc" LD="$TESTROOT/hooks/ld" \
			STUBS_SRC="$TESTROOT/stubs.c" \
			sh "$SCRIPT" >"$TESTROOT/out-$_tag" 2>"$TESTROOT/err-$_tag" || rc=$?
	fi
	echo "$rc"
}

# (a) hooked amd64
rc=$(run_missing amd64 a0)
a_ok=1
# The default CORE_OBJ for amd64 must be the one reported missing.
if ! grep -q "missing $TESTROOT/build/nv-kernel-amd64.o" "$TESTROOT/err-a0"; then a_ok=0; fi
if grep -q "nv-kernel-aarch64.o" "$TESTROOT/err-a0"; then a_ok=0; fi

rc=$(run_full amd64 a hook)
[ "$rc" -eq 0 ] || [ -f "$TESTROOT/cc-args" ] || a_ok=0
# After the default is correct, flags and LINKED_OBJ must be amd64-shaped.
if [ -f "$TESTROOT/cc-args" ]; then
	grep -q -- '-DNV_X86_64' "$TESTROOT/cc-args" || a_ok=0
	grep -q -- '-mno-red-zone' "$TESTROOT/cc-args" || a_ok=0
	grep -q -- '-mcmodel=kernel' "$TESTROOT/cc-args" || a_ok=0
	grep -q -- '-msoft-float' "$TESTROOT/cc-args" || a_ok=0
	if grep -q -- '-DNV_AARCH64' "$TESTROOT/cc-args"; then a_ok=0; fi
	if grep -q -- '-march=armv8-a' "$TESTROOT/cc-args"; then a_ok=0; fi
	if grep -q -- '-mbranch-protection=standard' "$TESTROOT/cc-args"; then a_ok=0; fi
	if grep -q -- '-mgeneral-regs-only' "$TESTROOT/cc-args"; then a_ok=0; fi
	if grep -q -- '-ffixed-x18' "$TESTROOT/cc-args"; then a_ok=0; fi
	if grep -q -- '-mno-outline-atomics' "$TESTROOT/cc-args"; then a_ok=0; fi
else
	a_ok=0
fi
if [ -f "$TESTROOT/ld-args" ]; then
	grep -qx -- '-r' "$TESTROOT/ld-args" || a_ok=0
else
	a_ok=0
fi
[ -f "$TESTROOT/build/nv-kernel-gb10.o" ] || a_ok=0
if [ "$a_ok" -eq 1 ]; then
	ok "(a) hooked amd64: default CORE_OBJ nv-kernel-amd64.o, LINKED_OBJ nv-kernel-gb10.o, x86_64 flags, no BTI, ld.lld -r"
else
	fail "(a) hooked amd64: rc-miss=$(cat "$TESTROOT/err-a0" 2>/dev/null) rc=$rc err=$(cat "$TESTROOT/err-a" 2>/dev/null)"
fi

# (b) hooked aarch64 path unchanged
rc=$(run_missing aarch64 b0)
b_ok=1
if ! grep -q "missing $TESTROOT/build/nv-kernel-aarch64.o" "$TESTROOT/err-b0"; then b_ok=0; fi
if grep -q "nv-kernel-amd64.o" "$TESTROOT/err-b0"; then b_ok=0; fi

rc=$(run_full aarch64 b hook)
if [ -f "$TESTROOT/cc-args" ]; then
	grep -q -- '-DNV_AARCH64' "$TESTROOT/cc-args" || b_ok=0
	grep -q -- '-mgeneral-regs-only' "$TESTROOT/cc-args" || b_ok=0
	grep -q -- '-march=armv8-a' "$TESTROOT/cc-args" || b_ok=0
	grep -q -- '-mstrict-align' "$TESTROOT/cc-args" || b_ok=0
	grep -q -- '-ffixed-x18' "$TESTROOT/cc-args" || b_ok=0
	grep -q -- '-mno-outline-atomics' "$TESTROOT/cc-args" || b_ok=0
	grep -q -- '-mbranch-protection=standard' "$TESTROOT/cc-args" || b_ok=0
	if grep -q -- '-DNV_X86_64' "$TESTROOT/cc-args"; then b_ok=0; fi
	if grep -q -- '-mno-red-zone' "$TESTROOT/cc-args"; then b_ok=0; fi
else
	b_ok=0
fi
[ -f "$TESTROOT/build/nv-kernel-gb10.o" ] || b_ok=0
if [ "$b_ok" -eq 1 ]; then
	ok "(b) hooked aarch64: default CORE_OBJ nv-kernel-aarch64.o, LINKED_OBJ nv-kernel-gb10.o, AArch64 flags unchanged"
else
	fail "(b) hooked aarch64: rc-miss=$(cat "$TESTROOT/err-b0" 2>/dev/null) rc=$rc err=$(cat "$TESTROOT/err-b" 2>/dev/null)"
fi

# (c) live amd64, no arch hook
arch=$(uname -p 2>/dev/null || uname -m)
if [ "$(uname -s)" = FreeBSD ] && [ "$arch" = amd64 ]; then
	rc=$(run_missing amd64 c0)
	# reuse run_missing with arch only for naming the expected file; hook is on for CC/LD
	# but we need no GB10_TEST_ARCH. Redo live missing+full here.
	reset
	rcm=0
	GB10_WORK="$TESTROOT" GB10_TEST_HOOKS=1 \
		CC="$TESTROOT/hooks/cc" LD="$TESTROOT/hooks/ld" \
		STUBS_SRC="$TESTROOT/stubs.c" \
		sh "$SCRIPT" >"$TESTROOT/out-c0" 2>"$TESTROOT/err-c0" || rcm=$?
	c_ok=1
	if ! grep -q "missing $TESTROOT/build/nv-kernel-amd64.o" "$TESTROOT/err-c0"; then c_ok=0; fi
	rc=$(run_full amd64 c live)
	if [ -f "$TESTROOT/cc-args" ] && grep -q -- '-DNV_X86_64' "$TESTROOT/cc-args" \
	    && [ -f "$TESTROOT/build/nv-kernel-gb10.o" ]; then
		:
	else
		c_ok=0
	fi
	if [ "$c_ok" -eq 1 ]; then
		ok "(c) live FreeBSD amd64, no arch hook: default CORE_OBJ nv-kernel-amd64.o, x86_64 flags"
	else
		fail "(c) live FreeBSD amd64: rcm=$rcm err0=$(cat "$TESTROOT/err-c0") rc=$rc err=$(cat "$TESTROOT/err-c")"
	fi
else
	ok "(c) live amd64 check skipped (host is $(uname -s) $arch)"
fi

if [ "$FAILED" -ne 0 ]; then
	printf 'FAILED %s checks (%s passed)\n' "$FAILED" "$PASSED"
	exit 1
fi
printf 'all ok (%s passed)\n' "$PASSED"
exit 0

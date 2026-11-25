#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# build-rmcore_arch_test.sh - scripts/build-rmcore.sh builds the RM core
# for the running architecture (Track #2475). Offline: a fake ogkm git
# checkout and a fake gmake, no network, no kldload. Scratch under
# work/tmp, never /tmp.
#   (a) Hooked amd64: default OUT is $GB10_WORK/build/nv-kernel-amd64.o,
#       gmake gets TARGET_OS=FreeBSD TARGET_ARCH=x86_64 LD=ld.lld and
#       no LD_TARGET_EMULATION_FLAG_FreeBSD_aarch64, CFLAGS has no
#       -mbranch-protection=standard, the object is copied from
#       _out/FreeBSD_x86_64/, and there is no AArch64 BTI refusal.
#   (b) Hooked amd64 modeset: default OUT is
#       $GB10_WORK/build/nv-modeset-kernel-amd64.o, same TARGET_ARCH=x86_64.
#   (c) Hooked aarch64: gmake still gets TARGET_ARCH=aarch64, LD=ld.lld,
#       LD_TARGET_EMULATION_FLAG_FreeBSD_aarch64=aarch64elf, and
#       CFLAGS including -mbranch-protection=standard; default OUT is
#       not the amd64 name (the arm64 path is unchanged).
#   (d) Live FreeBSD amd64 with no arch hook: same defaults as (a).
# Hooks: GB10_TEST_HOOKS=1 and GB10_TEST_ARCH=amd64|aarch64.

set -u
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL

OGKMDIR=open-gpu-kernel-modules-580.178.04
TESTSDIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo=$(CDPATH='' cd -- "$TESTSDIR/.." && pwd -P)
SCRIPT="$repo/scripts/build-rmcore.sh"
base=${GB10_WORK:-$repo/work}
mkdir -p -- "$base/tmp"
TESTROOT=$(mktemp -d "$base/tmp/rmcore-arch.XXXXXX") || exit 1

PASSED=0
FAILED=0
ok() { PASSED=$((PASSED + 1)); printf 'ok    %s\n' "$1"; }
fail() { FAILED=$((FAILED + 1)); printf 'FAIL  %s\n' "$1"; }
cleanup() { rm -rf "$TESTROOT"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

GB10_TEST_HOOKS=1
export GB10_TEST_HOOKS

if [ ! -f "$SCRIPT" ]; then
	fail "scripts/build-rmcore.sh does not exist"
	echo "passed: $PASSED failed: $FAILED"
	exit 1
fi

SRC="$TESTROOT/sources/$OGKMDIR"
mkdir -p "$SRC/src/nvidia" "$SRC/src/nvidia-modeset" "$TESTROOT/hooks-empty"
printf 'int dummy(void) { return 0; }\n' > "$SRC/src/nvidia/dummy.c"
printf 'int dummy(void) { return 0; }\n' > "$SRC/src/nvidia-modeset/dummy.c"
printf '.PHONY: clean\n' > "$SRC/src/nvidia-modeset/Makefile"
awk 'BEGIN { for (i = 1; i <= 219; i++) printf "# filler %d\n", i }' \
	> "$SRC/src/nvidia/Makefile"
cat >> "$SRC/src/nvidia/Makefile" <<'MKEOF'
	$(call quiet_cmd,OBJCOPY) \
	  --localize-symbol=memset \
	  --localize-symbol=memcpy \
	  --remove-section=.note.gnu.property \
	  $@

.PHONY: clean
MKEOF
for _p in "$repo"/patches/ogkm/patch-*; do
	case $_p in */patch-src_nvidia_Makefile) continue ;; esac
	_rel=$(sed -n '1s/^--- \([^[:space:]]*\)\.orig.*/\1/p' "$_p")
	[ -n "$_rel" ] || continue
	mkdir -p "$SRC/$(dirname "$_rel")"
	awk '
		/^@@ / {
			split($2, a, ","); start = substr(a[1], 2) + 0
			while (n < start - 1) { n++; printf "/* filler %d */\n", n }
			next
		}
		/^--- / || /^\+\+\+ / { next }
		/^-/ || /^ / { print substr($0, 2); n++ }
	' "$_p" > "$SRC/$_rel"
done
git -C "$SRC" init -q
git -C "$SRC" add -A
git -C "$SRC" -c core.hooksPath="$TESTROOT/hooks-empty" \
	-c user.email=test@example.invalid -c user.name=test \
	commit -q --no-verify -m "fake ogkm"
HEAD_SHA=$(git -C "$SRC" rev-parse HEAD)
printf 'ogkm_commit %s\n' "$HEAD_SHA" > "$TESTROOT/SOURCES-good"

printf 'int f(void) { return 0; }\n' > "$TESTROOT/fake-kernel.c"
cc -c -fno-stack-protector -o "$TESTROOT/fake-nv-kernel.o" "$TESTROOT/fake-kernel.c" \
	|| { fail "cannot compile the fake core object"; echo "passed: $PASSED failed: $FAILED"; exit 1; }

cat > "$TESTROOT/fake-gmake-ok" <<'GMEOF'
#!/bin/sh
# Paths below are filled in after this template is written? No: use env.
pwd > "$TESTROOT/gmake-cwd"
GMEOF
# The quoted heredoc cannot see TESTROOT. Write the hook script with sed.
cat > "$TESTROOT/fake-gmake-ok" <<GMEOF
#!/bin/sh
pwd > "$TESTROOT/gmake-cwd"
: > "$TESTROOT/gmake-args"
for a in "\$@"; do printf '%s\n' "\$a" >> "$TESTROOT/gmake-args"; done
printf '%s\n' "\${CFLAGS-}" > "$TESTROOT/gmake-cflags"
echo "fake gmake ran"
arch=aarch64
for a in "\$@"; do
	case \$a in TARGET_ARCH=*) arch=\${a#TARGET_ARCH=} ;; esac
done
case \$(basename "\$PWD") in
nvidia-modeset) obj=nv-modeset-kernel.o ;;
*) obj=nv-kernel.o ;;
esac
mkdir -p "_out/FreeBSD_\$arch"
cp "$TESTROOT/fake-nv-kernel.o" "_out/FreeBSD_\$arch/\$obj"
exit 0
GMEOF
chmod 755 "$TESTROOT/fake-gmake-ok"

run_core() {
	_arch=$1
	_corearg=${2-}
	_tag=$3
	rm -rf "$TESTROOT/build"
	mkdir -p "$TESTROOT/build/tree/nvidia" "$TESTROOT/build/tree/nvidia-modeset"
	rc=0
	if [ -n "$_corearg" ]; then
		GB10_WORK="$TESTROOT" SOURCES="$TESTROOT/SOURCES-good" \
			GMAKE="$TESTROOT/fake-gmake-ok" GB10_TEST_HOOKS=1 GB10_TEST_ARCH="$_arch" \
			sh "$SCRIPT" "$_corearg" >"$TESTROOT/out-$_tag" 2>"$TESTROOT/err-$_tag" || rc=$?
	else
		GB10_WORK="$TESTROOT" SOURCES="$TESTROOT/SOURCES-good" \
			GMAKE="$TESTROOT/fake-gmake-ok" GB10_TEST_HOOKS=1 GB10_TEST_ARCH="$_arch" \
			sh "$SCRIPT" >"$TESTROOT/out-$_tag" 2>"$TESTROOT/err-$_tag" || rc=$?
	fi
	echo "$rc"
}

# (a) hooked amd64 nvidia default
rc=$(run_core amd64 "" a)
a_ok=1
[ "$rc" -eq 0 ] || a_ok=0
[ -f "$TESTROOT/build/nv-kernel-amd64.o" ] || a_ok=0
[ ! -e "$TESTROOT/build/nv-kernel-aarch64.o" ] || a_ok=0
grep -qx -- 'TARGET_OS=FreeBSD' "$TESTROOT/gmake-args" || a_ok=0
grep -qx -- 'TARGET_ARCH=x86_64' "$TESTROOT/gmake-args" || a_ok=0
grep -qx -- 'LD=ld.lld' "$TESTROOT/gmake-args" || a_ok=0
if grep -q 'LD_TARGET_EMULATION_FLAG_FreeBSD_aarch64' "$TESTROOT/gmake-args"; then a_ok=0; fi
if grep -q -- '-mbranch-protection=standard' "$TESTROOT/gmake-cflags"; then a_ok=0; fi
if grep -qi 'lacks the AArch64 BTI' "$TESTROOT/err-a"; then a_ok=0; fi
if [ "$a_ok" -eq 1 ]; then
	ok "(a) hooked amd64: default OUT nv-kernel-amd64.o, TARGET_ARCH=x86_64, LLD, no aarch64 emulation or BTI CFLAGS"
else
	fail "(a) hooked amd64: rc=$rc out=$(cat "$TESTROOT/out-a") err=$(cat "$TESTROOT/err-a") args=$(tr '\n' ' ' < "$TESTROOT/gmake-args" 2>/dev/null) cflags=$(cat "$TESTROOT/gmake-cflags" 2>/dev/null)"
fi

# (b) hooked amd64 modeset default
rc=$(run_core amd64 "--core=nvidia-modeset" b)
b_ok=1
[ "$rc" -eq 0 ] || b_ok=0
[ -f "$TESTROOT/build/nv-modeset-kernel-amd64.o" ] || b_ok=0
[ ! -e "$TESTROOT/build/nv-modeset-kernel-aarch64.o" ] || b_ok=0
grep -qx -- 'TARGET_ARCH=x86_64' "$TESTROOT/gmake-args" || b_ok=0
if [ "$b_ok" -eq 1 ]; then
	ok "(b) hooked amd64 modeset: default OUT nv-modeset-kernel-amd64.o, TARGET_ARCH=x86_64"
else
	fail "(b) hooked amd64 modeset: rc=$rc out=$(cat "$TESTROOT/out-b") err=$(cat "$TESTROOT/err-b")"
fi

# (c) hooked aarch64 path unchanged
rm -rf "$TESTROOT/build"
mkdir -p "$TESTROOT/build/tree/nvidia"
rc=0
GB10_WORK="$TESTROOT" SOURCES="$TESTROOT/SOURCES-good" \
	GMAKE="$TESTROOT/fake-gmake-ok" GB10_TEST_HOOKS=1 GB10_TEST_ARCH=aarch64 \
	sh "$SCRIPT" "$TESTROOT/build/want-aarch64.o" "$TESTROOT/log-c" \
	>"$TESTROOT/out-c" 2>"$TESTROOT/err-c" || rc=$?
c_ok=1
grep -qx -- 'TARGET_ARCH=aarch64' "$TESTROOT/gmake-args" || c_ok=0
grep -qx -- 'LD=ld.lld' "$TESTROOT/gmake-args" || c_ok=0
grep -qx -- 'LD_TARGET_EMULATION_FLAG_FreeBSD_aarch64=aarch64elf' "$TESTROOT/gmake-args" || c_ok=0
grep -q -- '-mbranch-protection=standard' "$TESTROOT/gmake-cflags" || c_ok=0
rm -rf "$TESTROOT/build"
mkdir -p "$TESTROOT/build/tree/nvidia"
GB10_WORK="$TESTROOT" SOURCES="$TESTROOT/SOURCES-good" \
	GMAKE="$TESTROOT/fake-gmake-ok" GB10_TEST_HOOKS=1 GB10_TEST_ARCH=aarch64 \
	sh "$SCRIPT" >"$TESTROOT/out-c2" 2>"$TESTROOT/err-c2" || true
if [ -f "$TESTROOT/build/nv-kernel-aarch64.o" ] \
    || grep -q 'nv-kernel-aarch64\.o' "$TESTROOT/out-c2" "$TESTROOT/err-c2" 2>/dev/null \
    || grep -qi 'AArch64 feature: BTI\|lacks the AArch64 BTI' "$TESTROOT/err-c2"; then
	:
else
	c_ok=0
fi
[ ! -e "$TESTROOT/build/nv-kernel-amd64.o" ] || c_ok=0
if [ "$c_ok" -eq 1 ]; then
	ok "(c) hooked aarch64: TARGET_ARCH=aarch64, LLD, aarch64elf emulation, BTI CFLAGS, default OUT not amd64"
else
	fail "(c) hooked aarch64: rc=$rc args=$(tr '\n' ' ' < "$TESTROOT/gmake-args" 2>/dev/null) cflags=$(cat "$TESTROOT/gmake-cflags" 2>/dev/null) err=$(cat "$TESTROOT/err-c2")"
fi

# (d) live amd64 host, no hook
arch=$(uname -p 2>/dev/null || uname -m)
if [ "$(uname -s)" = FreeBSD ] && [ "$arch" = amd64 ]; then
	rm -rf "$TESTROOT/build"
	mkdir -p "$TESTROOT/build/tree/nvidia"
	rc=0
	GB10_WORK="$TESTROOT" SOURCES="$TESTROOT/SOURCES-good" \
		GMAKE="$TESTROOT/fake-gmake-ok" GB10_TEST_HOOKS=1 \
		sh "$SCRIPT" >"$TESTROOT/out-d" 2>"$TESTROOT/err-d" || rc=$?
	if [ "$rc" -eq 0 ] && [ -f "$TESTROOT/build/nv-kernel-amd64.o" ] \
	    && grep -qx -- 'TARGET_ARCH=x86_64' "$TESTROOT/gmake-args"; then
		ok "(d) live FreeBSD amd64, no arch hook: default OUT nv-kernel-amd64.o, TARGET_ARCH=x86_64"
	else
		fail "(d) live FreeBSD amd64: rc=$rc out=$(cat "$TESTROOT/out-d") err=$(cat "$TESTROOT/err-d")"
	fi
else
	ok "(d) live amd64 check skipped (host is $(uname -s) $arch)"
fi

if [ "$FAILED" -ne 0 ]; then
	printf 'FAILED %s checks (%s passed)\n' "$FAILED" "$PASSED"
	exit 1
fi
printf 'all ok (%s passed)\n' "$PASSED"
exit 0

#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# render_uapi_layout_test.sh - layout and numbering test for the render uAPI
# header src/nvidia-drm-render/nvidia-drm-render.h (Track #2314).
#
# Checks (all through tests/render_uapi_layout.c):
#   1. user space: the probe compiles (-std=c11 -Wall -Wextra -Werror) and runs:
#      sizes, member offsets and sizes, no implicit padding, 8-byte alignment of
#      every 64-bit member, ioctl encoding, ioctl numbers unique and outside the
#      nvidia-drm range;
#   2. the same with a drm.h stub (Linux and drm-kmod spelling) included before
#      the header and after it, under -Werror: no macro clash, same numbers;
#   3. kernel: the probe compiles with -D_KERNEL -nostdinc against the FreeBSD
#      source tree SYSDIR (no default: a src/sys checkout the caller names),
#      where _Static_assert does the checking;
#   4. self-contained: the header alone compiles as C99, C11 and C++17 with
#      -Wall -Wextra -Werror -pedantic, included twice, as the first include;
#   4b. the header defines no macro outside NVR_, DRM_NVR_ and DRM_IOCTL_NVR_
#      (so it never clashes with drm.h or a caller's names);
#   5. every struct and every DRM_IOCTL_NVR_* in the header has a row in the
#      probe, and no row is stale;
#      every member is uint32_t, uint64_t, a char array or a nested NVR struct
#      (so a pointer or a long cannot slip in where LP64 hides the size);
#   6. the nvidia-drm ioctl numbers in every NVIDIA header found (when a source tree is
#      present) are all within 0x00-0x3f, below the NVR range, and none equals an
#      NVR number (NVIDIA may add 0x19 and up: that must not fail);
#   7. the test can fail: planted changes to the header (a widened field, a
#      removed pad member, a reordered pair, a duplicate ioctl number, numbers
#      in the nvidia-drm and nouveau ranges, a changed ioctl direction, an
#      unlisted struct, an unlisted ioctl, a stray macro, a macro that clashes
#      with drm.h, a pointer member in a listed struct and in a new one) each
#      make checks 1-5 fail, and for the stated reason (see the `mutate` lines).
#
# A check that cannot run (no SYSDIR, no NVIDIA header) is SKIPPED and said so
# loudly; every SKIPPED line stays in the output. The checks that can run still
# decide the result: with neither CI nor REQUIRE_INPUTS=yes the test exits 0 and
# its last line says plainly how many checks were skipped and what would make
# each of them run; with CI or REQUIRE_INPUTS=yes a skip is a FAIL (exit 1).
# RENDER_UAPI_ALLOW_SKIP=1 is still accepted, but it is now a no-op: a skip is
# a skip, not a failure.
#
# Environment: GB10_WORK (default <repo>/work; the NVIDIA header is looked for
# under $GB10_WORK/sources), NVIDIA_IOCTL_H (names the NVIDIA header instead,
# when it names a file that exists), SYSDIR (no default; a FreeBSD src/sys
# checkout), TMPDIR (default <repo>/tmp), RENDER_UAPI_ALLOW_SKIP (accepted,
# no-op).
# Exit: 0 every check that could run passed (a skip is reported in the last
#       line; with CI or REQUIRE_INPUTS=yes a skip exits 1 instead)
#       1 a check failed, or a required input was missing
#       2 the test itself cannot run: the render header or the probe is
#         missing, cc is not on PATH, or there is no temporary directory
# Run: sh tests/render_uapi_layout_test.sh

set -u
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL

TESTSDIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH= cd -- "$TESTSDIR/.." && pwd)
# No $HOME defaults: inputs come from the environment or the repository.
#   SYSDIR     a FreeBSD src/sys checkout (kernel compile)
#   GB10_WORK  work root whose sources/ holds open-gpu-kernel-modules-580.178.04
#               (default <repo>/work, so the path in a skip message is a real one)
#   CI=1 or REQUIRE_INPUTS=yes make a missing input a FAIL (exit 1)
WORK=${GB10_WORK:-$REPO/work}
TMPDIR=${TMPDIR:-$REPO/tmp}
export TMPDIR
SYSDIR=${SYSDIR:-}
HDR_DIR=$REPO/src/nvidia-drm-render
PROBE=$TESTSDIR/render_uapi_layout.c

die2() { echo "render_uapi_layout_test: $*" >&2; exit 2; }
[ -f "$HDR_DIR/nvidia-drm-render.h" ] || die2 "missing $HDR_DIR/nvidia-drm-render.h"
[ -f "$PROBE" ] || die2 "missing $PROBE"
# RENDER_UAPI_ALLOW_SKIP is accepted for callers that still set it; it is a
# no-op, because a skip is a skip and never changes the exit status.  It is
# not read into a variable: nothing uses it.
SKIPS=0
SKIP_LABELS=
skipped() { # label remedy - record a check that could not run, and what
	# would make it run
	SKIPS=$((SKIPS + 1))
	if [ -z "$SKIP_LABELS" ]; then
		SKIP_LABELS="$1 ($2)"
	else
		SKIP_LABELS="$SKIP_LABELS, $1 ($2)"
	fi
}
HAVE_SYS=1
if [ -z "$SYSDIR" ] || [ ! -f "$SYSDIR/sys/ioccom.h" ] || [ ! -d "$SYSDIR/arm64/include" ]; then
	HAVE_SYS=0
	# The remedy is written once and used in the SKIPPED line and in the
	# PASS summary, so the two cannot tell the reader different things.
	_sys_remedy="set SYSDIR to a FreeBSD src/sys tree"
	echo "SKIPPED: kernel compile (check 3): SYSDIR $SYSDIR is not a FreeBSD src/sys tree ($_sys_remedy)"
	skipped "kernel compile" "$_sys_remedy"
fi
command -v cc >/dev/null 2>&1 || die2 "cc not found; install a C compiler (pkg install llvm) and make sure cc is on PATH"
mkdir -p "$TMPDIR" || die2 "cannot create $TMPDIR"
W=$(mktemp -d "$TMPDIR/render_uapi.XXXXXX") || die2 "mktemp failed"
trap 'rm -rf "$W"' EXIT INT TERM

# kernel include setup: <machine/...> is arm64/include
mkdir -p "$W/kinc" "$W/stub"
[ "$HAVE_SYS" -eq 1 ] && ln -s "$SYSDIR/arm64/include" "$W/kinc/machine"
cat >"$W/stub/drm.h" <<'STUB'
/* a drm.h as Linux and drm-kmod ship it (DRM_IOCTL_BASE spelling), reduced to what matters here */
#include <sys/ioccom.h>
#define DRM_IOCTL_BASE 'd'
#define DRM_COMMAND_BASE 0x40
#define DRM_IOW(nr, type)  _IOW(DRM_IOCTL_BASE, nr, type)
#define DRM_IOWR(nr, type) _IOWR(DRM_IOCTL_BASE, nr, type)
STUB

HAVE_CXX=0
command -v c++ >/dev/null 2>&1 && HAVE_CXX=1
FAILS=0
fail() { echo "FAIL: $*"; FAILS=$((FAILS + 1)); }
pass() { echo "PASS: $*"; }

# check_all INCDIR LABEL OUTPUTFILE - runs checks 1-5 against the header in
# INCDIR; returns non-zero if any of them fails; messages go to OUTPUTFILE.
check_all() {
	_inc=$1; _out=$3; _rc=0; : >"$_out"
	_d=$(mktemp -d "$W/chk.XXXXXX") || return 1
	# 1. user space
	if cc -std=c11 -Wall -Wextra -Werror -I"$_inc" "$PROBE" -o "$_d/probe" >>"$_out" 2>&1; then
		"$_d/probe" >>"$_out" 2>&1 || { echo "user probe failed" >>"$_out"; _rc=1; }
	else echo "user compile failed" >>"$_out"; _rc=1; fi
	# 2. drm.h stub first
	if cc -std=c11 -Wall -Wextra -Werror -include "$W/stub/drm.h" -I"$_inc" "$PROBE" -o "$_d/probe2" >>"$_out" 2>&1; then
		"$_d/probe2" >"$_d/p2.txt" 2>&1 || { echo "stub probe failed" >>"$_out"; _rc=1; }
		[ -x "$_d/probe" ] && "$_d/probe" >"$_d/p1.txt" 2>&1
		cmp -s "$_d/p1.txt" "$_d/p2.txt" || { echo "numbers differ with a drm.h first" >>"$_out"; _rc=1; }
	else echo "stub compile failed (drm.h first)" >>"$_out"; _rc=1; fi
	printf '#include "nvidia-drm-render.h"\n#include "drm.h"\nint nvr_after_unused;\n' >"$_d/after.c"
	cc -std=c11 -Wall -Wextra -Werror -I"$W/stub" -I"$_inc" -c "$_d/after.c" -o "$_d/after.o" >>"$_out" 2>&1 \
	    || { echo "drm.h after the header failed (macro clash)" >>"$_out"; _rc=1; }
	# 3. kernel
	if [ "$HAVE_SYS" -eq 1 ]; then
		cc -D_KERNEL -DKLD_MODULE -std=gnu99 -nostdinc -ffreestanding -Wall -Werror \
		    -I"$SYSDIR" -I"$SYSDIR/contrib/ck/include" -I"$W/kinc" -I"$_inc" \
		    -c "$PROBE" -o "$_d/k.o" >>"$_out" 2>&1 || { echo "kernel compile failed" >>"$_out"; _rc=1; }
	fi
	# 4. self-contained
	printf '#include "nvidia-drm-render.h"\n#include "nvidia-drm-render.h"\nint nvr_probe_unused;\n' >"$_d/one.c"
	for _std in c99 c11; do
		cc -std=$_std -Wall -Wextra -Werror -pedantic -I"$_inc" -c "$_d/one.c" -o "$_d/one.o" >>"$_out" 2>&1 \
		    || { echo "self-contained $_std failed" >>"$_out"; _rc=1; }
	done
	# the non-FreeBSD include branch (<sys/ioctl.h>), as a Linux build would take it
	cc -std=c11 -Wall -Wextra -Werror -pedantic -U__FreeBSD__ -I"$_inc" -c "$_d/one.c" -o "$_d/one.o" >>"$_out" 2>&1 \
	    || { echo "self-contained without __FreeBSD__ failed" >>"$_out"; _rc=1; }
	if [ "$HAVE_CXX" -eq 1 ]; then
		cp "$_d/one.c" "$_d/one.cc"
		c++ -std=c++17 -Wall -Wextra -Werror -pedantic -I"$_inc" -c "$_d/one.cc" -o "$_d/one.o" >>"$_out" 2>&1 \
		    || { echo "self-contained c++17 failed" >>"$_out"; _rc=1; }
	fi
	# 4b. header contract: the header defines nothing outside its own prefixes
	printf '#include <stdint.h>\n#include <sys/ioccom.h>\n' >"$_d/empty.c"
	cc -E -dM "$_d/empty.c" 2>/dev/null | sort >"$_d/macros.base"
	cc -E -dM -I"$_inc" "$_d/one.c" 2>/dev/null | sort >"$_d/macros.hdr"
	comm -13 "$_d/macros.base" "$_d/macros.hdr" | awk '{print $2}' | sed 's/(.*//' \
	    | grep -v -E '^(_NVIDIA_DRM_RENDER_H_|NVR_|DRM_NVR_|DRM_IOCTL_NVR_)' >"$_d/stray.txt"
	[ -s "$_d/stray.txt" ] && { echo "header defines names outside NVR_/DRM_NVR_/DRM_IOCTL_NVR_: $(tr '\n' ' ' <"$_d/stray.txt")" >>"$_out"; _rc=1; }
	# 4c. ABI freeze: every NVR_/DRM_NVR_ define has an exact-value row V() in the probe
	grep -E '^#define[[:space:]]+(NVR_|DRM_NVR_)[A-Z0-9_]+[[:space:]]' "$_inc/nvidia-drm-render.h" | awk '{print $2}' | grep -v '^NVR_IOW' | sort >"$_d/defs.txt"
	sed -n 's/^V(\([A-Z0-9_]*\),.*/\1/p' "$PROBE" | sort >"$_d/vrows.txt"
	cmp -s "$_d/defs.txt" "$_d/vrows.txt" || { echo "constant list differs from the V() value rows:" >>"$_out"; diff "$_d/defs.txt" "$_d/vrows.txt" >>"$_out" 2>&1; _rc=1; }
	# 5. struct coverage
	awk '/^struct[[:space:]]+[A-Za-z_0-9]+[[:space:]]*\{/ {sub(/^struct[[:space:]]+/, ""); sub(/[[:space:]]*\{.*/, ""); sub(/^drm_nvr_/, ""); print}' \
	    "$_inc/nvidia-drm-render.h" | sort >"$_d/hdr.txt"
	awk '/^CHK\(/ {sub(/^CHK\(/, ""); sub(/,.*/, ""); print}' "$PROBE" | sort >"$_d/rows.txt"
	cmp -s "$_d/hdr.txt" "$_d/rows.txt" || { echo "struct list differs from the probe rows:" >>"$_out"; diff "$_d/hdr.txt" "$_d/rows.txt" >>"$_out" 2>&1; _rc=1; }
	sed -n 's/^#define[[:space:]]*DRM_IOCTL_NVR_\([A-Z0-9_]*\)[[:space:]].*/\1/p' "$_inc/nvidia-drm-render.h" | sort >"$_d/hio.txt"
	sed -n 's/^[[:space:]]*Y(\([A-Z0-9_]*\),.*/\1/p' "$PROBE" | sort >"$_d/pio.txt"
	cmp -s "$_d/hio.txt" "$_d/pio.txt" || { echo "ioctl list differs from the probe rows:" >>"$_out"; diff "$_d/hio.txt" "$_d/pio.txt" >>"$_out" 2>&1; _rc=1; }
	# 5b. member types: fixed-width integers, char arrays and nested NVR structs only
	awk '/^struct[[:space:]]+[A-Za-z_0-9]+[[:space:]]*\{/ {s=1; next} /^\};/ {s=0} s {
		l=$0; gsub(/\/\*.*\*\//, "", l); if (l ~ /^[[:space:]]*$/) next
		if (l !~ /^[[:space:]]*(uint32_t|uint64_t|char|struct drm_nvr_[a-z_]+)[[:space:]]+[a-z_0-9]+(\[[A-Za-z_0-9]+\])?;[[:space:]]*$/) print "bad member: " $0 }' \
	    "$_inc/nvidia-drm-render.h" >"$_d/types.txt"
	[ -s "$_d/types.txt" ] && { cat "$_d/types.txt" >>"$_out"; echo "member type check failed" >>"$_out"; _rc=1; }
	rm -rf "$_d"
	return $_rc
}

# ---- 1-5 on the real header -------------------------------------------------
if check_all "$HDR_DIR" real "$W/real.out"; then
	pass "header layout, ioctl numbers, kernel and user compile, self-contained, struct coverage"
	grep -E '^(DRM_IOCTL|[0-9]+ ioctls)' "$W/real.out"
else
	fail "header checks"; cat "$W/real.out"
fi

# ---- 6. NVIDIA's own table --------------------------------------------------
# The NVIDIA header is looked for under the work root the caller named.
# NVIDIA_IOCTL_H names it instead when it names a file that exists: the
# caller asked for that header.  When it names no file the skip says which
# path is wrong, because fetching the sources would not repair a path the
# caller chose.  The remedy is written once and used both in the SKIPPED
# line and in the PASS summary, so the two cannot disagree.
NVH_REMEDY=
if [ -n "${NVIDIA_IOCTL_H:-}" ]; then
	if [ -f "$NVIDIA_IOCTL_H" ]; then
		NVH_PIN=$NVIDIA_IOCTL_H
	else
		NVH_PIN=
		NVH_REMEDY="set NVIDIA_IOCTL_H to an existing header, or unset it to use the header under $WORK/sources"
	fi
else
	NVH_PIN=$WORK/sources/open-gpu-kernel-modules-580.178.04/kernel-open/nvidia-drm/nvidia-drm-ioctl.h
	NVH_REMEDY="run $REPO/scripts/fetch-sources.sh to fetch it into $WORK/sources"
fi
NVHS=
[ -n "$NVH_PIN" ] && [ -f "$NVH_PIN" ] && NVHS=$NVH_PIN
if [ -n "$NVHS" ]; then
	_gend=$(cc -std=c11 -I"$HDR_DIR" "$PROBE" -o "$W/probe.g" 2>/dev/null && "$W/probe.g" | sed -n 's/^NV_GROWTH_END //p')
	sed -n 's/^#define[[:space:]]*DRM_NVR_[A-Z0-9_]*[[:space:]]*\(0x[0-9a-fA-F]*\).*/\1/p' "$HDR_DIR/nvidia-drm-render.h" | sort -u >"$W/nvr.txt"
	_minnvr=$(while read -r v; do printf '%d\n' "$v"; done <"$W/nvr.txt" | sort -n | head -1)
	for NVH in $NVHS; do
		sed -n 's/^#define DRM_NVIDIA_[A-Z0-9_]*  *\(0x[0-9a-fA-F]*\).*/\1/p' "$NVH" | sort -u >"$W/nv.txt"
		_cnt=$(wc -l <"$W/nv.txt" | tr -d ' ')
		_maxnv=$(while read -r v; do printf '%d\n' "$v"; done <"$W/nv.txt" | sort -n | tail -1)
		_clash=$(sort "$W/nv.txt" "$W/nvr.txt" | uniq -d | tr '\n' ' ')
		# the end of the range left to NVIDIA's growth is the probe's NV_GROWTH_END;
		# a count of 0 would mean the sed above matched nothing.
		if [ "$_cnt" -ge 1 ] && [ -n "$_gend" ] && [ -z "$_clash" ] && [ "$_maxnv" -le "$_gend" ] && [ "$_maxnv" -lt "$_minnvr" ]; then
			pass "NVIDIA header $NVH: $_cnt DRM_NVIDIA_* numbers, highest $_maxnv (growth limit $_gend), all below the NVR range (lowest $_minnvr), no shared number"
		else
			fail "NVIDIA ioctl table $NVH: count $_cnt max $_maxnv growth limit '$_gend' NVR min $_minnvr clash '$_clash'"
		fi
	done
else
	if [ -n "${NVIDIA_IOCTL_H:-}" ]; then
		echo "SKIPPED: check 6: NVIDIA_IOCTL_H names $NVIDIA_IOCTL_H, which is not there ($NVH_REMEDY); the probe still asserts the NVR numbers are above 0x3f"
	else
		echo "SKIPPED: check 6: no NVIDIA nvidia-drm-ioctl.h under $WORK/sources ($NVH_REMEDY); the probe still asserts the NVR numbers are above 0x3f"
	fi
	skipped "check 6" "$NVH_REMEDY"
fi
if [ "$HAVE_CXX" -eq 0 ]; then
	_cxx_remedy="install a c++ compiler (pkg install llvm)"
	echo "SKIPPED: C++17 self-contained check (check 4): no c++ on PATH ($_cxx_remedy)"
	skipped "C++17 self-contained" "$_cxx_remedy"
fi

# ---- 7. the test can fail ---------------------------------------------------
H=$HDR_DIR/nvidia-drm-render.h
mutate() { # name, expected message (grep pattern), function applying the change
	_name=$1; _want=$2; shift 2
	_md="$W/mut.$_name"; mkdir -p "$_md"
	"$@" <"$H" >"$_md/nvidia-drm-render.h" || { fail "mutation $_name could not be built"; return; }
	if cmp -s "$H" "$_md/nvidia-drm-render.h"; then fail "mutation $_name changed nothing (stale pattern)"; return; fi
	if check_all "$_md" "$_name" "$W/mut.$_name.out"; then
		fail "planted change '$_name' was NOT detected"
	elif ! grep -q -E "$_want" "$W/mut.$_name.out"; then
		cat "$W/mut.$_name.out" | head -5
		fail "planted change '$_name' was refused for the wrong reason (expected '$_want')"
	else
		_why=$({ grep -m1 -E 'failed|differs|FAIL|bad member|header defines' "$W/mut.$_name.out"; grep -m1 'error:' "$W/mut.$_name.out" | sed 's|.*error: ||'; } | tr '\n' ' ' | cut -c1-100)
		pass "planted change '$_name' turns the test red ($_why)"
	fi
}
m_widen()    { sed 's|uint32_t sig_count;	/\* in \*/|uint64_t sig_count;	/* in */|'; }
m_droppad()  { awk '/^struct drm_nvr_gem_info \{/ {s=1} s && /uint32_t pad;/ {s=0; next} {print}'; }
m_reorder()  { awk '/uint64_t wait_ptr;.*drm_nvr_sync\[wait_count\] \*\/$/ && !d && ++n==2 {hold=$0; next} hold && /uint64_t sig_ptr;/ {print; print hold; hold=""; d=1; next} {print}'; }
m_dupnr()    { sed 's|^\(#define[[:space:]]*DRM_NVR_EXEC[[:space:]]*\)0x4f|\10x4e|'; }
m_collide()  { sed 's|^\(#define[[:space:]]*DRM_NVR_GETPARAM[[:space:]]*\)0x45|\10x18|'; }
m_nouveau()  { sed 's|^\(#define[[:space:]]*DRM_NVR_GETPARAM[[:space:]]*\)0x45|\10x44|'; }
m_growth()   { sed 's|^\(#define[[:space:]]*DRM_NVR_GETPARAM[[:space:]]*\)0x45|\10x20|'; }
m_dir()      { sed 's|NVR_IOW(DRM_NVR_CHANNEL_FREE|NVR_IOWR(DRM_NVR_CHANNEL_FREE|'; }
# inserting whole lines goes through awk, never through "\n" in a sed replacement (BSD sed)
m_newioctl() { awk '{print} /^#define[[:space:]]*DRM_NVR_EXEC[[:space:]]/ {print "#define\tDRM_NVR_GEM_WAIT\t\t0x50"; print "#define\tDRM_IOCTL_NVR_GEM_WAIT\t\tNVR_IOW(DRM_NVR_GEM_WAIT, struct drm_nvr_gem_cpu_prep)"}'; }
m_cmdbase()  { awk '/^#define[[:space:]]*NVR_COMMAND_BASE[[:space:]]/ {print "#define\tDRM_COMMAND_BASE\t0x40"} {print}'; }
m_clash()    { awk '/^#define[[:space:]]*NVR_COMMAND_BASE[[:space:]]/ {print "#define\tDRM_IOWR(a, b)\t0"} {print}'; }
m_newstruct(){ awk '/^\/\* ---- EXEC -/ {print "struct drm_nvr_unlisted {\n\tuint32_t a;\n\tuint32_t b;\n};\n"} {print}'; }
m_pointer()  { sed 's|uint64_t op_ptr;	/\* in: user pointer to struct drm_nvr_vm_bind_op\[op_count\] \*/|void *op_ptr;|'; }
m_synctl()   { sed 's|^\(#define[[:space:]]*NVR_SYNC_TIMELINE_SYNCOBJ[[:space:]]*\)0x1|\10x2|'; }
m_last()     { sed 's|^\(#define[[:space:]]*DRM_NVR_LAST[[:space:]]*\)0x5f|\10x60|'; }
m_newconst() { awk '{print} /^#define[[:space:]]*NVR_ENGINE_NVENC[[:space:]]/ {print "#define\tNVR_ENGINE_NEW\t\t\t5"}'; }
m_digitptr() { awk '/^\/\* ---- EXEC -/ {print "struct drm_nvr_exec2 {\n\tvoid *p;\n};\n"} {print}'; }
# a listed struct gets a pointer member, so only the member-type check (5b) can fire
m_ptrlisted(){ awk '/^struct drm_nvr_sync \{/ {s=1} s && /uint64_t timeline_value;/ {print "\tlong timeline_value;"; s=0; next} {print}'; }
mutate widen-field 'static assertion failed|sizeof' m_widen
mutate drop-pad 'no member named' m_droppad
mutate reorder-fields 'static assertion failed|offsetof' m_reorder
mutate duplicate-ioctl-number 'EXEC command number|duplicate' m_dupnr
mutate collide-with-nvidia-range 'GETPARAM command number|inside NVIDIA' m_collide
mutate inside-nvidia-growth-range 'GETPARAM command number|inside NVIDIA' m_growth
mutate inside-nouveau-range 'GETPARAM command number|inside nouveau' m_nouveau
mutate unlisted-ioctl 'ioctl list differs' m_newioctl
mutate stray-DRM_COMMAND_BASE 'header defines names outside' m_cmdbase
mutate defines-DRM_IOWR-itself 'macro redefined|DRM_IOWR' m_clash
mutate digit-named-struct-with-pointer 'struct list differs|bad member' m_digitptr
mutate pointer-in-a-listed-struct 'bad member' m_ptrlisted
mutate change-ioctl-direction 'encoded direction' m_dir
mutate unlisted-struct 'struct list differs' m_newstruct
mutate pointer-member 'bad member' m_pointer
mutate sync-timeline-value-changed 'value of NVR_SYNC_TIMELINE_SYNCOBJ' m_synctl
mutate command-range-past-DRM_COMMAND_END 'DRM_NVR_LAST|value of DRM_NVR_LAST' m_last
mutate new-constant-without-a-row 'constant list differs' m_newconst

if [ "$FAILS" -eq 0 ]; then
	if [ "$SKIPS" -gt 0 ] && { [ -n "${CI:-}" ] || [ "${REQUIRE_INPUTS:-}" = yes ]; }; then
		echo "render_uapi_layout_test: FAIL: $SKIPS input(s) missing and CI or REQUIRE_INPUTS is set"
		exit 1
	fi
	if [ "$SKIPS" -gt 0 ]; then
		_skipword=checks
		[ "$SKIPS" -eq 1 ] && _skipword=check
		echo "render_uapi_layout_test: PASS ($SKIPS $_skipword SKIPPED: $SKIP_LABELS; REQUIRE_INPUTS=yes makes a skip a failure)"
		exit 0
	fi
	echo "render_uapi_layout_test: PASS"
	exit 0
fi
echo "render_uapi_layout_test: FAIL ($FAILS)"
exit 1

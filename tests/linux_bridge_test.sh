#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# linux_bridge_test.sh - the Linux ioctl bridges are optional modules (Track
# #2363): nvidia.ko and nvidia-modeset.ko load and work with no linux64elf and
# no linux_common; the Linux-facing code lives in nvidia_linux.ko and
# nvidia_modeset_linux.ko. No kldload(8), no root.
#
# Usage: tests/linux_bridge_test.sh [TREE]
#   TREE  prepared and built working tree; default
#         ${GB10_WORK:-$HOME/work/gb10}/build/tree-2363
#   LINUX_BRIDGE_SKIP_FUZZ=1 skips the fresh-archive fuzz 0 apply (slow).
#
# Checks, on the built modules:
#   (a) nvidia.ko: no MODULE_DEPEND on linux, linuxelf, linux64elf or
#       linux_common (read from the _m_depend_on_ symbols MODULE_DEPEND(9)
#       leaves in the modmetadata set);
#   (b) nvidia.ko imports no symbol whose name starts with linux (nm -u);
#   (c) nvidia.ko exports the bridge KPI (nvidia_bridge_register,
#       nvidia_bridge_unregister), and defines no linux_ioctl handler;
#   (d) nvidia-modeset.ko: the same as (a) and (b);
#   (e) nvidia_linux.ko depends on exactly {nvidia, linux64elf, linux_common}
#       (kernel allowed), accepts nvidia 2 (vmax >= 2) and nvidia 1, and every
#       undefined symbol resolves in the kernel, nvidia.ko or the Linuxulator
#       modules it depends on;
#   (f) nvidia_modeset_linux.ko depends on exactly {nvidia_modeset,
#       linux64elf, linux_common};
#   (g) the patches apply to a fresh extraction of NVIDIA's archive with fuzz 0
#       (patch -F0) and no rejects, in lexical order;
#   (h) the core's nv-freebsd.h no longer defines NV_SUPPORT_LINUX_COMPAT
#       unconditionally.
# Every check has a plant: a synthetic object with the defect, which the same
# check function must refuse. A check that cannot fail is a defect.

set -eu

PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL

WORK=${GB10_WORK:-$HOME/work/gb10}
TESTSDIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH= cd -- "$TESTSDIR/.." && pwd)
TREE=${1:-$WORK/build/tree-2363}
SYSDIR=${SYSDIR:-/usr/src/sys}
KDIR=$(dirname "$(sysctl -n kern.bootfile)")

NVKO=$TREE/nvidia/nvidia.ko
MSKO=$TREE/nvidia-modeset/nvidia-modeset.ko
BRKO=$TREE/nvidia-linux/nvidia_linux.ko
MSBRKO=$TREE/nvidia-modeset-linux/nvidia_modeset_linux.ko

fails=0
fail() {
	echo "FAIL: $*" >&2
	fails=$((fails + 1))
}
pass() {
	echo "PASS: $*"
}

mkdir -p "$WORK/tmp"
TMPD=$(mktemp -d "$WORK/tmp/linux_bridge_test.XXXXXXXX") || exit 1
cleanup() {
	rm -rf "$TMPD"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# deps_of <obj>: sorted module names the object declares with MODULE_DEPEND.
deps_of() {
	nm "$1" | awk '$NF ~ /^_[A-Za-z0-9_]*_depend_on_[A-Za-z0-9_]*$/ { print $NF }' | sed 's/.*_depend_on_//' | sort -u
}

# undef_of <obj>: sorted undefined symbol names.
undef_of() {
	nm -u "$1" | awk '{ print $NF }' | sort -u
}

# linux_dep_in <obj>: print every Linuxulator dependency the object declares.
linux_dep_in() {
	deps_of "$1" | grep -E '^(linux|linuxelf|linux64elf|linux_common|linux64)$' || true
}

# linux_import_in <obj>: print every undefined symbol that is a Linuxulator one.
linux_import_in() {
	undef_of "$1" | grep -E '^linux' || true
}

# check_no_linux <label> <obj>: no Linux dependency and no Linux import.
check_no_linux() {
	_l=$(linux_dep_in "$2")
	_i=$(linux_import_in "$2")
	if [ -n "$_l" ]; then
		return 1
	fi
	if [ -n "$_i" ]; then
		return 2
	fi
	return 0
}

# check_exact_deps <obj> <expected words...>: the dependency set is exactly
# the expected set, with "kernel" tolerated.
check_exact_deps() {
	_obj=$1
	shift
	_want=$(printf '%s\n' "$@" | sort -u)
	_have=$(deps_of "$_obj" | grep -v '^kernel$' || true)
	[ "$_have" = "$_want" ]
}

# dep_range <ko> <module> <dep>: struct mod_depend is three ints (minimum,
# preferred, maximum), the static _<module>_depend_on_<dep> in a data
# section. Print "min pref max".
dep_range() {
	_sym=_$2_depend_on_$3
	_line=$(readelf -sW "$1" | awk -v s="$_sym" '$8 == s { print $2, $7; exit }')
	[ -n "$_line" ] || return 1
	_val=${_line% *}
	_shn=${_line#* }
	_secinfo=$(readelf -SW "$1" | sed -n "s/^ *\[ *$_shn\] *[^ ]* *[^ ]* *\([0-9a-f]*\) *\([0-9a-f]*\) .*/\1 \2/p")
	[ -n "$_secinfo" ] || return 1
	_base=${_secinfo% *}
	_off=${_secinfo#* }
	_pos=$(( 0x$_val - 0x$_base + 0x$_off ))
	od -An -t d4 -j "$_pos" -N 12 "$1" | awk '{ print $1, $2, $3 }'
}

# bridge_exports <obj>: how many of the two KPI symbols the object exports.
bridge_exports() {
	nm -g --defined-only "$1" | awk '{ print $NF }' | grep -c -E '^nvidia_bridge_(register|unregister)$' || true
}

# range_ok <obj> <module> <dep>: the dependency accepts nvidia 1 and 2
# (minimum <= 1, maximum >= 2).
range_ok() {
	_r=$(dep_range "$1" "$2" "$3") || return 1
	set -- $_r
	[ "$1" -le 1 ] && [ "$3" -ge 2 ]
}

# unresolved_of <obj> <sorted defined-symbols file>: the undefined symbols the
# file does not define (__this_linker_file is the kernel linker's own).
unresolved_of() {
	undef_of "$1" | comm -23 - "$2" | grep -v '^__this_linker_file$' || true
}

# unconditional_define <file> <symbol> <guard-depth>: line numbers where the
# symbol is #defined outside any #if, ignoring <guard-depth> enclosing
# conditionals (1 for nv-freebsd.h: its _NV_FREEBSD_H_ include guard; 0 for
# nvidia-modeset-freebsd.c).
unconditional_define() {
	awk -v sym="$2" -v guard="${3:-0}" '
		/^#[ \t]*(if|ifdef|ifndef)/ { depth++ }
		/^#[ \t]*endif/ { depth-- }
		$0 ~ ("^#[ \t]*define[ \t]+" sym "([ \t]|$)") { if (depth <= guard) print NR }
	' "$1"
}

# ---------------------------------------------------------------- plants
# Synthetic objects carrying the defect each check must refuse. They are
# compiled with the host cc: nm reads symbols, nothing is linked or loaded.
cat > "$TMPD/plant_dep.c" <<'EOF'
int _x_depend_on_linux64elf;
int _x_depend_on_mem;
EOF
cat > "$TMPD/plant_dep_common.c" <<'EOF'
int _x_depend_on_linux_common;
EOF
cat > "$TMPD/plant_import.c" <<'EOF'
extern int linux_ioctl_register_handler(void *);
int plant(void) { return linux_ioctl_register_handler(0); }
EOF
cat > "$TMPD/plant_clean.c" <<'EOF'
int _x_depend_on_mem;
extern int sx_xlock(void *);
int plant(void) { return sx_xlock(0); }
EOF
cat > "$TMPD/plant_extra_dep.c" <<'EOF'
int _x_depend_on_nvidia;
int _x_depend_on_linux64elf;
int _x_depend_on_linux_common;
int _x_depend_on_mem;
EOF
cat > "$TMPD/plant_range_bad.c" <<'EOF'
struct { int a, b, c; } _nvidia_linux_depend_on_nvidia = { 1, 1, 1 };
EOF
cat > "$TMPD/plant_range_good.c" <<'EOF'
struct { int a, b, c; } _nvidia_linux_depend_on_nvidia = { 1, 2, 2 };
EOF
cat > "$TMPD/plant_one_export.c" <<'EOF'
int nvidia_bridge_register(void) { return 0; }
EOF
cat > "$TMPD/plant_two_exports.c" <<'EOF'
int nvidia_bridge_register(void) { return 0; }
int nvidia_bridge_unregister(void) { return 0; }
EOF
cat > "$TMPD/plant_unres.c" <<'EOF'
extern int zz_undefined_sym(void);
int plant(void) { return zz_undefined_sym(); }
EOF
for p in plant_dep plant_dep_common plant_import plant_clean plant_extra_dep plant_range_bad plant_range_good plant_one_export plant_two_exports plant_unres; do
	cc -c -o "$TMPD/$p.o" "$TMPD/$p.c" || { echo "FAIL: cannot build plant $p" >&2; exit 1; }
done

# plants must be refused
if check_no_linux plant "$TMPD/plant_dep.o"; then fail "plant: a linux64elf dependency was accepted"; else pass "plant: linux64elf dependency refused"; fi
if check_no_linux plant "$TMPD/plant_dep_common.o"; then fail "plant: a linux_common dependency was accepted"; else pass "plant: linux_common dependency refused"; fi
if check_no_linux plant "$TMPD/plant_import.o"; then fail "plant: a linux_ import was accepted"; else pass "plant: linux_ import refused"; fi
if check_no_linux plant "$TMPD/plant_clean.o"; then pass "control: a clean object is accepted"; else fail "control: a clean object was refused"; fi
if check_exact_deps "$TMPD/plant_extra_dep.o" nvidia linux64elf linux_common; then fail "plant: an extra mem dependency was accepted"; else pass "plant: extra dependency refused"; fi
if check_exact_deps "$TMPD/plant_dep.o" nvidia linux64elf linux_common; then fail "plant: a missing nvidia dependency was accepted"; else pass "plant: missing dependency refused"; fi

# (c) export count: one of two refused, two accepted
[ "$(bridge_exports "$TMPD/plant_one_export.o")" = 2 ] && fail "plant (c): one exported KPI symbol counted as two" || pass "plant (c): an object exporting one KPI symbol is refused"
[ "$(bridge_exports "$TMPD/plant_two_exports.o")" = 2 ] && pass "control (c): two KPI exports are accepted" || fail "control (c): two exports not counted"
# (e) nvidia version range: {1,1,1} refused, {1,2,2} accepted
range_ok "$TMPD/plant_range_bad.o" nvidia_linux nvidia && fail "plant (e): a 1,1,1 range was accepted" || pass "plant (e): the nvidia range 1,1,1 is refused"
range_ok "$TMPD/plant_range_good.o" nvidia_linux nvidia && pass "control (e): the nvidia range 1,2,2 is accepted" || fail "control (e): the range reader failed on 1,2,2 (dep_range reads garbage?)"
# (e) unresolved imports: an undefined symbol with no definer is refused, a defined one passes
: > "$TMPD/nodefs"
[ -n "$(unresolved_of "$TMPD/plant_unres.o" "$TMPD/nodefs")" ] && pass "plant (e): an unresolved import is refused" || fail "plant (e): an unresolved import was accepted"
echo zz_undefined_sym > "$TMPD/somedefs"
[ -z "$(unresolved_of "$TMPD/plant_unres.o" "$TMPD/somedefs")" ] && pass "control (e): a defined import resolves" || fail "control (e): a defined import was refused"
# (f) the modeset provider set shares check_exact_deps: the same plants apply
check_exact_deps "$TMPD/plant_extra_dep.o" nvidia_modeset linux64elf linux_common && fail "plant (f): a wrong dependency set was accepted" || pass "plant (f): a wrong modeset provider set is refused"

# ------------------------------------------------------- built modules
need() {
	[ -f "$1" ] || { fail "no $1: prepare-tree.sh and build-shim.sh (--module=...) first"; return 1; }
}

if need "$NVKO"; then
	_l=$(linux_dep_in "$NVKO")
	if [ -z "$_l" ]; then pass "(a) nvidia.ko has no Linuxulator MODULE_DEPEND"; else fail "(a) nvidia.ko depends on: $_l"; fi
	_i=$(linux_import_in "$NVKO")
	if [ -z "$_i" ]; then pass "(b) nvidia.ko imports no linux symbol"; else fail "(b) nvidia.ko imports: $_i"; fi
	_x=$(bridge_exports "$NVKO")
	if [ "$_x" = 2 ]; then pass "(c) nvidia.ko exports nvidia_bridge_register and nvidia_bridge_unregister"; else fail "(c) nvidia.ko exports $_x of the 2 bridge KPI symbols"; fi
	if nm "$NVKO" | grep -q 'linux_ioctl_nvidia\|nvidia_handler$'; then fail "(c) nvidia.ko still holds the Linux ioctl handler"; else pass "(c) nvidia.ko holds no Linux ioctl handler"; fi
fi

if [ -f "$MSKO" ]; then
	if check_no_linux modeset "$MSKO"; then pass "(d) nvidia-modeset.ko has no Linux dependency or import"; else fail "(d) nvidia-modeset.ko: $(linux_dep_in "$MSKO") $(linux_import_in "$MSKO")"; fi
else
	fail "no $MSKO: build-shim.sh --module=nvidia-modeset first"
fi

if need "$BRKO"; then
	if check_exact_deps "$BRKO" nvidia linux64elf linux_common; then pass "(e) nvidia_linux.ko depends on exactly nvidia, linux64elf, linux_common"; else fail "(e) nvidia_linux.ko dependency set is: $(deps_of "$BRKO" | tr '\n' ' ')"; fi
	if _r=$(dep_range "$BRKO" nvidia_linux nvidia); then
		if range_ok "$BRKO" nvidia_linux nvidia; then pass "(e) nvidia_linux.ko accepts nvidia 1 through 2 (range $_r)"; else fail "(e) nvidia_linux.ko nvidia range is $_r, want min <= 1 and max >= 2"; fi
	else
		fail "(e) cannot read the nvidia version range of nvidia_linux.ko"
	fi
	# every undefined symbol resolves in kernel, nvidia.ko or the Linuxulator modules
	: > "$TMPD/defs"
	nm -g --defined-only "$KDIR/kernel" 2>/dev/null | awk '{ print $NF }' >> "$TMPD/defs" || true
	for f in "$NVKO" "$KDIR/linux64.ko" "$KDIR/linux_common.ko"; do
		if [ -f "$f" ]; then nm -g --defined-only "$f" | awk '{ print $NF }' >> "$TMPD/defs"; fi
	done
	sort -u "$TMPD/defs" > "$TMPD/defs.s"
	_unres=$(unresolved_of "$BRKO" "$TMPD/defs.s")
	if [ -z "$_unres" ]; then pass "(e) every nvidia_linux.ko import resolves"; else fail "(e) unresolved in nvidia_linux.ko: $_unres"; fi
fi

if need "$MSBRKO"; then
	if check_exact_deps "$MSBRKO" nvidia_modeset linux64elf linux_common; then pass "(f) nvidia_modeset_linux.ko depends on exactly nvidia_modeset, linux64elf, linux_common"; else fail "(f) nvidia_modeset_linux.ko dependency set is: $(deps_of "$MSBRKO" | tr '\n' ' ')"; fi
fi

# --------------------------------------------- (h) the define is no longer unconditional
HDR=$TREE/nvidia/nv-freebsd.h
if [ -f "$HDR" ]; then
	_bad=$(unconditional_define "$HDR" NV_SUPPORT_LINUX_COMPAT 1)
	if [ -z "$_bad" ]; then pass "(h) nv-freebsd.h defines NV_SUPPORT_LINUX_COMPAT only under a condition"; else fail "(h) nv-freebsd.h defines NV_SUPPORT_LINUX_COMPAT unconditionally at line $_bad"; fi
	if grep -q 'NV_CORE_LINUX_COMPAT' "$HDR"; then pass "(h) the legacy switch NV_CORE_LINUX_COMPAT exists"; else fail "(h) no NV_CORE_LINUX_COMPAT legacy switch"; fi
else
	fail "no $HDR"
fi
# plant for (h): the pristine header defines it unconditionally
SRCHDR=$WORK/sources/NVIDIA-FreeBSD-x86_64-580.178.04/src/nvidia/nv-freebsd.h
if [ -f "$SRCHDR" ]; then
	_bad=$(unconditional_define "$SRCHDR" NV_SUPPORT_LINUX_COMPAT 1)
	if [ -n "$_bad" ]; then pass "plant (h): the pristine header is refused (line $_bad)"; else fail "plant (h): the check accepted the pristine unconditional define"; fi
fi

# (h2) the same for nvidia-modeset: NVKMS_SUPPORT_LINUX_COMPAT
MSSRC=$TREE/nvidia-modeset/nvidia-modeset-freebsd.c
if [ -f "$MSSRC" ]; then
	_bad=$(unconditional_define "$MSSRC" NVKMS_SUPPORT_LINUX_COMPAT 0)
	if [ -z "$_bad" ]; then pass "(h2) nvidia-modeset defines NVKMS_SUPPORT_LINUX_COMPAT only under a condition"; else fail "(h2) nvidia-modeset defines it unconditionally at line $_bad"; fi
	if grep -q 'NVKMS_CORE_LINUX_COMPAT' "$MSSRC"; then pass "(h2) the legacy switch NVKMS_CORE_LINUX_COMPAT exists"; else fail "(h2) no NVKMS_CORE_LINUX_COMPAT legacy switch"; fi
else
	fail "no $MSSRC"
fi
MSPRISTINE=$WORK/sources/NVIDIA-FreeBSD-x86_64-580.178.04/src/nvidia-modeset/nvidia-modeset-freebsd.c
if [ -f "$MSPRISTINE" ]; then
	_bad=$(unconditional_define "$MSPRISTINE" NVKMS_SUPPORT_LINUX_COMPAT 0)
	if [ -n "$_bad" ]; then pass "plant (h2): the pristine modeset source is refused (line $_bad)"; else fail "plant (h2): the check accepted the pristine unconditional define"; fi
fi

# ----------------------------------------- (g) fuzz 0 on a fresh archive
if [ "${LINUX_BRIDGE_SKIP_FUZZ:-0}" = 1 ]; then
	echo "SKIP: (g) fuzz 0 apply (LINUX_BRIDGE_SKIP_FUZZ=1)"
else
	TARBALL=$WORK/sources/NVIDIA-FreeBSD-x86_64-580.178.04.tar.xz
	TOP=NVIDIA-FreeBSD-x86_64-580.178.04
	if [ -f "$TARBALL" ]; then
		FZ=$TMPD/fz
		mkdir -p "$FZ"
		tar -xJf "$TARBALL" -C "$FZ" --strip-components 2 --exclude '*.o' "$TOP/src/"
		_ok=1
		for p in "$REPO"/patches/patch-*; do
			if ! patch -d "$FZ" -p0 -E -s -F0 -i "$p" > "$TMPD/patch.out" 2>&1; then
				fail "(g) $(basename "$p") does not apply with fuzz 0: $(head -3 "$TMPD/patch.out" | tr '\n' ' ')"
				_ok=0
				break
			fi
		done
		[ "$_ok" = 1 ] && pass "(g) every patch applies to a fresh archive with fuzz 0"
		if [ -n "$(find "$FZ" -name '*.rej' | head -1)" ]; then fail "(g) a .rej file was left behind"; fi
		# plant: a patch with a wrong context line must be refused at fuzz 0
		mkdir -p "$TMPD/pl"
		printf 'a\nb\nc\nd\ne\nf\ng\n' > "$TMPD/pl/f"
		cat > "$TMPD/pl.patch" <<'EOF'
--- f.orig
+++ f
@@ -2,5 +2,5 @@
 b
 c
-X
+d2
 e
 Z
EOF
		if patch -d "$TMPD/pl" -p0 -s -F0 -i "$TMPD/pl.patch" > /dev/null 2>&1; then fail "plant (g): a patch with a wrong context applied at fuzz 0"; else pass "plant (g): a wrong-context patch is refused at fuzz 0"; fi
	else
		fail "(g) no $TARBALL"
	fi
fi

# ------------------------------------------------------------ (i) docs
# docs_missing <file> <words...>: print each word the page lacks.
docs_missing() {
	_f=$1
	shift
	for _w in "$@"; do
		grep -q -- "$_w" "$_f" || echo "$_w"
	done
}
for pg in nvidia nvidia_linux; do
	if [ -f "$REPO/man/$pg.4" ]; then
		# a missing referenced page is allowed only when it is a page of this repo
		_lint=$(mandoc -T lint -W warning "$REPO/man/$pg.4" 2>&1 | grep -v -E 'referenced manual not found: Xr (nvidia|nvidia_linux|nvidia_drm_render) 4' || true)
		if [ -z "$_lint" ]; then pass "(i) man/$pg.4 is lint clean"; else fail "(i) man/$pg.4 lint: $_lint"; fi
	else
		fail "(i) no man/$pg.4"
	fi
done
if [ -f "$REPO/man/nvidia_linux.4" ]; then
	_m=$(docs_missing "$REPO/man/nvidia_linux.4" nvidia_modeset_linux NV_CORE_LINUX_COMPAT NVKMS_CORE_LINUX_COMPAT nvidia_linux_mode kld_list linux_enable EBUSY)
	if [ -z "$_m" ]; then pass "(i) nvidia_linux(4) documents modules, legacy switches, rc variable, unload"; else fail "(i) nvidia_linux(4) lacks: $_m"; fi
fi
if [ -f "$REPO/man/nvidia.4" ]; then
	_m=$(docs_missing "$REPO/man/nvidia.4" nvidia_bridge_register nvidia_bridge_unregister NVIDIA_BRIDGE_KPI_VERSION NV_CORE_LINUX_COMPAT)
	if [ -z "$_m" ]; then pass "(i) nvidia(4) documents the KPI and the legacy switch"; else fail "(i) nvidia(4) lacks: $_m"; fi
fi
# plant: a page without the words is refused
printf '.Dd x\n' > "$TMPD/empty.4"
if [ -n "$(docs_missing "$TMPD/empty.4" nvidia_bridge_register)" ]; then pass "plant (i): a page without the KPI is refused"; else fail "plant (i): an empty page was accepted"; fi
for f in README.md rc.d/nvidia_linux; do
	[ -f "$REPO/$f" ] || fail "(i) no $f"
done
grep -q 'nvidia_linux' "$REPO/README.md" && pass "(i) README names nvidia_linux" || fail "(i) README does not name nvidia_linux"


# ------------------------------------------- (j) numbers, claims, manifest
# the modeset provider repeats two numbers of the native driver: compare them
BRDIR=$REPO/src/gb10-linux-bridge
MPROV=$BRDIR/nvidia-modeset-linux/nvidia_modeset_linux_mod.c
CHARNUM=$WORK/sources/NVIDIA-FreeBSD-x86_64-580.178.04/src/nvidia/nv-chardev-numbers.h
MSPRISTINE=$WORK/sources/NVIDIA-FreeBSD-x86_64-580.178.04/src/nvidia-modeset/nvidia-modeset-freebsd.c
# num_of <file> <macro>: the number a "#define <macro> <n>" line gives
num_of() { sed -n "s/^[[:space:]]*#[[:space:]]*define[[:space:]]*$2[[:space:]]*\\([0-9][0-9]*\\).*/\\1/p" "$1" | head -1; }
if [ -f "$CHARNUM" ] && [ -f "$MSPRISTINE" ]; then
	[ "$(num_of "$MPROV" NVKMS_LINUX_MAJOR)" = "$(num_of "$CHARNUM" NV_MAJOR_DEVICE_NUMBER)" ] && pass "(j) the modeset provider's Linux major is NV_MAJOR_DEVICE_NUMBER" || fail "(j) NVKMS_LINUX_MAJOR differs from NV_MAJOR_DEVICE_NUMBER"
	[ "$(num_of "$MPROV" NVKMS_LINUX_MINOR)" = "$(num_of "$MSPRISTINE" NVKMS_CDEV_MINOR)" ] && pass "(j) the modeset provider's Linux minor is NVKMS_CDEV_MINOR" || fail "(j) NVKMS_LINUX_MINOR differs from NVKMS_CDEV_MINOR"
	# plant: a provider with another minor must be refused
	sed 's/NVKMS_LINUX_MINOR\t254/NVKMS_LINUX_MINOR\t253/' "$MPROV" > "$TMPD/mprov_bad.c"
	[ "$(num_of "$TMPD/mprov_bad.c" NVKMS_LINUX_MINOR)" != "$(num_of "$MSPRISTINE" NVKMS_CDEV_MINOR)" ] && pass "plant (j): a changed minor is refused" || fail "plant (j): the minor comparison cannot fire"
else
	fail "(j) no pinned sources to compare the NVKMS numbers with"
fi
# docs and rc header must not claim uvm needs no Linux layer
for f in README.md man/nvidia_linux.4 rc.d/nvidia_linux; do
	if grep -q -i -E 'uvm-bsd load and work with no|unified-memory driver$|nvidia-uvm.ko need no Linux' "$REPO/$f" 2>/dev/null; then fail "(j) $f claims uvm needs no Linux layer"; else pass "(j) $f makes no false uvm claim"; fi
done
printf 'nvidia.ko, nvidia-modeset.ko and uvm-bsd load and work with no linux64\n' > "$TMPD/claim.txt"
grep -q -i -E 'uvm-bsd load and work with no' "$TMPD/claim.txt" && pass "plant (j): the uvm claim pattern fires" || fail "plant (j): the uvm claim pattern cannot fire"
# the manifest: every copy_one is recorded
PREP=$TREE/.prepared
if [ -f "$PREP" ]; then
	_n=$(grep -c '^src/gb10-linux-bridge/' "$PREP" || true)
	_c=$(grep -c '^[[:space:]]*copy_one [a-z]' "$REPO/scripts/prepare-tree.sh" || true)
	[ "$_n" = "$_c" ] && [ "$_c" -gt 0 ] && pass "(j) the manifest records every copy ($_n)" || fail "(j) the manifest has $_n bridge lines, prepare-tree.sh makes $_c copies"
fi
# the ioctl handler answers ENOIOCTL for a foreign descriptor
grep -q 'return (ENOIOCTL)' "$BRDIR/nvbridge_ioctl.h" && pass "(j) the handler returns ENOIOCTL for a foreign descriptor" || fail "(j) no ENOIOCTL path in the handler"
grep -q 'refused ENXIO\|ENXIO' "$BRDIR/nvidia_bridge.c" && pass "(j) the legacy build refuses a provider (ENXIO)" || fail "(j) no ENXIO for the legacy build"

# the mutant harness is defined once
_n=$(grep -l 'cmp -s "\$TMPD/mut' "$REPO"/tests/nvidia_bridge_unit_test.sh "$REPO"/tests/nvbridge_ioctl_unit_test.sh | wc -l | tr -d ' ')
[ "$_n" = 0 ] && [ -f "$REPO/tests/lib/mutant.sh" ] && pass "(j) the mutant harness lives only in tests/lib/mutant.sh" || fail "(j) a unit test script carries its own copy of the mutant harness ($_n)"
# the descriptor filter holds the cdevsw with devvn_refthread and never reads si_devsw by hand
if grep -q 'devvn_refthread' "$BRDIR/nvbridge_ioctl.h" && ! grep -q 'si_devsw->d_name' "$BRDIR/nvbridge_ioctl.h"; then pass "(j) the descriptor filter takes the cdevsw with devvn_refthread"; else fail "(j) the descriptor filter reads si_devsw without a thread reference"; fi
printf 'x = dev->si_devsw->d_name;\n' > "$TMPD/hdr_bad.h"
if grep -q 'devvn_refthread' "$TMPD/hdr_bad.h" && ! grep -q 'si_devsw->d_name' "$TMPD/hdr_bad.h"; then fail "plant (j): a header reading si_devsw by hand was accepted"; else pass "plant (j): a header reading si_devsw by hand is refused"; fi
# user docs carry no tracker references
_docs_ok=1
for d in README.md man/nvidia.4 man/nvidia_linux.4; do [ -f "$REPO/$d" ] || { fail "(j) no $d to check"; _docs_ok=0; }; done
if [ "$_docs_ok" = 1 ]; then
	grep -q 'Track #2363' "$REPO/README.md" "$REPO/man/nvidia.4" "$REPO/man/nvidia_linux.4" && _rc=0 || _rc=$?
	if [ "$_rc" = 1 ]; then pass "(j) no Track #2363 in README or the man pages"; else fail "(j) a Track #2363 reference is in the user documents (grep rc $_rc)"; fi
fi
printf 'see Track #2363\n' > "$TMPD/doc_bad.md"
grep -q 'Track #2363' "$TMPD/doc_bad.md" && pass "plant (j): the Track-reference pattern fires" || fail "plant (j): the Track-reference pattern cannot fire"
# the rc.conf synopsis does not list a provider in kld_list
if ! sed -n '/^\.Sh SYNOPSIS/,/^\.Sh DESCRIPTION/p' "$REPO/man/nvidia_linux.4" | grep -q 'kld_list='; then fail "(j) the nvidia_linux(4) synopsis has no kld_list line to check"
elif sed -n '/^\.Sh SYNOPSIS/,/^\.Sh DESCRIPTION/p' "$REPO/man/nvidia_linux.4" | grep 'kld_list=' | grep -q '_linux'; then fail "(j) the nvidia_linux(4) synopsis puts a provider in kld_list"; else pass "(j) the nvidia_linux(4) synopsis kld_list holds no provider"; fi
printf 'kld_list="nvidia nvidia_linux"\n' | grep 'kld_list=' | grep -q '_linux' && pass "plant (j): the synopsis pattern fires" || fail "plant (j): the synopsis pattern cannot fire"
# the README loads the providers by path (nothing installs them)
readme_block() { sed -n '/^## Linux bridges/,/^## Licence/p' "$1"; }
sed 's/^## Linux bridges/### Linux bridges/' "$REPO/README.md" > "$TMPD/README.retitled"
if readme_block "$TMPD/README.retitled" | grep -q '^kldload'; then fail "plant (j): a re-levelled heading still yields a block"; else pass "plant (j): a re-levelled README heading gives an empty block (refused below)"; fi
if ! readme_block "$REPO/README.md" | grep -q '^kldload \$GB10_WORK/build/tree/nvidia/nvidia.ko'; then fail "(j) the README bridges block is empty or lacks the nvidia.ko kldload line"
elif readme_block "$REPO/README.md" | grep '^kldload' | grep -v '^kldload \$GB10_WORK/' | grep -q .; then fail "(j) a README kldload line loads by module name with no install step"; else pass "(j) every README kldload line in the bridges block is a path"; fi
printf 'kldload nvidia_linux\n' | grep '^kldload' | grep -v '^kldload \$GB10_WORK/' | grep -q . && pass "plant (j): the README pattern fires" || fail "plant (j): the README pattern cannot fire"

if [ "$fails" -ne 0 ]; then
	echo "linux_bridge_test: $fails FAILED" >&2
	exit 1
fi
echo "linux_bridge_test: all passed"

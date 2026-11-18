#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# kmod_symbols_test.sh - static load check for the arm64 nvidia.ko
# (TREE/nvidia/nvidia.ko). No kldload(8), no root:
#   (a) the ELF header says AArch64 and type DYN (shared object):
#       bsd.kmod.mk links nvidia.ko from the REL nvidia.kld with
#       `ld -Bshareable`, the same type as the system's own kmods;
#   (b) every undefined symbol (nm -u) is defined in the running kernel
#       ($(sysctl -n kern.bootfile)) or in a module nvidia.ko depends on
#       per patches/patch-nvidia_nvidia_pci.c: linux64.ko (which registers
#       the linux64elf module) and linux_common.ko (which linux64.ko
#       needs), both looked up in the running kernel's own directory; mem
#       is a dependency but its interface symbols live in the kernel.
#       Only GLOBAL defined symbols count as resolvers: the kernel linker
#       never resolves a module's undefined symbols against STB_LOCAL
#       symbols (kern/link_elf.c:1589-1590, 1705), so a local kernel
#       function with a matching name would pass a "not U" filter while
#       kldload would still fail. nm prints global symbols with uppercase
#       type letters and local ones lowercase, with one exception:
#       STT_GNU_IFUNC symbols print as 'i' whatever their binding, and
#       the kernel's memcpy/memset are IFUNC GLOBAL DEFAULT (checked with
#       readelf -sW on $(sysctl -n kern.bootfile): every IFUNC in the
#       kernel is GLOBAL; the dependency modules here have none), so 'i'
#       is accepted as a resolver too.
#       Every unresolved symbol is printed and the test exits 1; success
#       prints "unresolved: 0";
#   (c) the module dependency names embedded in nvidia.ko, read from the
#       symbols MODULE_DEPEND(9) creates: each MODULE_DEPEND(m, dep, ...)
#       emits a linker-set pointer symbol
#       __set_modmetadata_set_sym__m_depend_on_<dep> and a static struct
#       _m_depend_on_<dep> (/usr/src/sys/sys/module.h:120-127), so
#       "nm nvidia.ko | grep _depend_on_" yields the dependency list.
#       Asserted: the set is EXACTLY {linux64elf, mem} - a membership
#       check ("mem present, linux64elf present, io absent") would let a
#       regression like MODULE_DEPEND(nvidia, linux) through, and no such
#       module exists on arm64, so kldload would fail; io(4) is x86-only
#       (/usr/src/sys/modules/Makefile:780 inside an x86 block).
#   (d) $WORK/build/nv-kernel-gb10.o (the partially linked core + stubs
#       object that build-shim.sh links in as nv-kernel.o) carries the
#       AArch64 GNU property note with BTI and PAC: FreeBSD 16 arm64
#       links every kmod with -zbti-report=error, and ld -r only emits
#       GNU_PROPERTY_AARCH64_FEATURE_1_BTI when every input has it.
#   (e) freshness: the nvidia.ko checked here must come from the CURRENT
#       patches. TREE/.prepared must say "state done" (line 2), every
#       entry of its manifest (each applied patch's name and sha256, and
#       the copied src/ additions) must match the file in the repo right
#       now, and nvidia.ko must be NEWER than .prepared. Without this a
#       stale .ko from older patches passes every other check here
#       (pass-3 u12 item 3). Two controls prove the check can fail: a
#       nvidia.ko with an old timestamp and a .prepared whose manifest
#       hash no longer matches the repo are both refused.
#   (f) the nvidia-modeset.ko module, when it has been built (or always,
#       with --modeset):
#       (f1) its declared dependency set is exactly
#            {linux64elf, linux_common, nvidia} plus the kernel itself
#            (MODULE_DEPEND(nvidia_modeset, kernel) may or may not be
#            there - the kernel is not a module and has no .ko file), and
#            nothing else: an extra dependency (a regression putting back
#            MODULE_DEPEND(nvidia_modeset, linux) - no such module on
#            arm64, the 64-bit Linuxulator is linux64elf) or a missing
#            one must both fail here;
#       (f2) every undefined symbol resolves in the kernel or in the file
#            of one of those dependencies: linux64elf is registered by
#            linux64.ko, linux_common by linux_common.ko, nvidia by
#            TREE/nvidia/nvidia.ko (the kernel linker resolves a module's
#            undefined symbols only from the kernel and the module's own
#            dependencies, and only against their EXPORTED symbols);
#       (f3) nvidia.ko exports (defines globally) every symbol
#            nvidia-modeset.ko takes from it. bsd.kmod.mk (kmod.mk in
#            FreeBSD 16) exports nothing unless EXPORT_SYMS names the
#            symbol: without the hunk in patches/patch-nvidia_Makefile the
#            six symbols the modeset module calls stay local in nvidia.ko
#            and kldload would fail with "symbol ... undefined". The
#            control localizes them in a copy of the real nvidia.ko -
#            exactly what a build without the hunk produces - and the
#            check must refuse that copy.
#   (g) the nvidia-drm module, when it has been built (or always, with
#       --drm):
#       (g1) its declared dependency set is exactly
#            {dmabuf, drmn, linuxkpi, nvidia, nvidia_modeset} plus the
#            kernel itself: "kernel" is not a module and has no .ko file,
#            so it may or may not be declared, but nothing else may be.
#            drmn is the module name drm.ko registers itself under;
#            dmabuf, linuxkpi and drm are drm.ko's own dependencies and
#            are declared here because nvidia-drm calls into them.
#       (g2) every undefined symbol resolves in the kernel or in the file
#            of one of those dependencies, and only against their
#            EXPORTED symbols: dmabuf is dmabuf.ko, drmn is drm.ko (both
#            in the running kernel's directory), linuxkpi is
#            linuxkpi.ko, nvidia is TREE/nvidia/nvidia.ko and
#            nvidia_modeset is TREE/nvidia-modeset/nvidia-modeset.ko.
#            The kernel linker resolves a module's undefined symbols only
#            from the kernel and from the module's DIRECT dependencies,
#            and only against their exported symbols, so anything else is
#            a symbol the kernel will refuse at kldload.
#            __this_linker_file is the ONE allowed exception: the kernel
#            linker resolves it itself for every module (kern/kern_linker.c:
#            "Treat the __this_linker_file as a special symbol"), it is
#            what LinuxKPI's THIS_MODULE points at, and the system's own
#            modules leave it undefined too (amdgpu.ko, drm.ko).
#       (g3) linuxkpi_video.ko is linuxkpi's OWN dependency: the kernel
#            linker does not follow a dependency's dependencies, so a
#            symbol that only linuxkpi_video.ko exports cannot be
#            resolved by nvidia-drm.ko. The check finds out with nm
#            whether nvidia-drm.ko needs one; if it does, that is a real
#            defect and the test says so - it is never papered over.
#       (g-control) Falsifiability: a nvidia-modeset.ko that does NOT
#            export the symbols nvidia-drm.ko takes from it must be
#            refused. The kernel build turns a symbol global only when
#            the module's Makefile names it in EXPORT_SYMS (sys/conf/kmod.mk:
#            kmod_syms.awk + objcopy --globalize-symbol); without the hunk
#            in patches/patch-nvidia-modeset_Makefile the eight
#            nvKmsKapi* symbols stay local and kldload would fail with
#            "symbol ... undefined". The control localizes them in a copy
#            of the real module - exactly what a build without the hunk
#            produces - and the check must refuse that copy.
#
# Usage: tests/kmod_symbols_test.sh [TREE] [--modeset] [--drm]
#   TREE  prepared working tree; defaults to ${GB10_WORK:-$HOME/work/gb10}/build/tree
#   --modeset
#         check nvidia-modeset.ko even when it has not been built; the
#         run then fails if the module is missing
#   --drm
#         check nvidia-drm.ko even when it has not been built; the run
#         then fails if the module is missing
#
# Prerequisite: scripts/prepare-tree.sh, scripts/build-stubs.sh and
# scripts/build-shim.sh have run and produced $WORK/build/nv-kernel-gb10.o
# and TREE/nvidia/nvidia.ko. Scratch stays under $WORK/tmp.

set -eu

PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL

WORK=${GB10_WORK:-$HOME/work/gb10}
WANT_MODESET=0
WANT_DRM=0
# The TREE is the only positional argument; --modeset and --drm ask for
# the nvidia-modeset and nvidia-drm modules to be checked even when they
# have not been built.
for _a in "$@"; do
	case $_a in
	--modeset) WANT_MODESET=1 ;;
	--drm) WANT_DRM=1 ;;
	-*)
		echo "FAIL: unknown option: $_a" >&2
		exit 1
		;;
	*)
		TREE=$_a
		;;
	esac
done
TREE=${TREE:-$WORK/build/tree}
KO=$TREE/nvidia/nvidia.ko
MSKO=$TREE/nvidia-modeset/nvidia-modeset.ko
DRMKO=$TREE/nvidia-drm/nvidia-drm.ko
TESTSDIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH= cd -- "$TESTSDIR/.." && pwd)

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

[ -f "$KO" ] || fail "no $KO: run scripts/build-shim.sh first"

# Unpredictable scratch directory ($WORK/tmp is $HOME/work/gb10/tmp unless
# GB10_WORK says otherwise), removed by the trap on every exit path.
mkdir -p "$WORK/tmp"
TMPD=$(mktemp -d "$WORK/tmp/kmod_symbols_test.XXXXXXXX") || exit 1
# Time:  O(F) cleanup for F scratch files, once per run.
# Space: O(1) in this shell.
cleanup() {
	rm -rf "$TMPD"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 131' QUIT
trap 'exit 130' INT
trap 'exit 143' TERM

# fresh_reason <tree> <repo>: print why <tree>'s nvidia.ko is not fresh;
# print nothing and return 0 when it is fresh; return 1 when it is not.
# A tree is fresh when its .prepared says "state done", every manifest
# entry (an applied patch's name and sha256, or a copied src/ addition)
# still matches the file in the repo, and nvidia.ko is newer than
# .prepared. Everything the check reads is read from files, never from a
# pipeline, so a failed command cannot read as "no problems".
# Limits: "newer" is an mtime comparison, so it catches a forgotten rebuild,
# not a deliberately touched file; and only files in the manifest are
# compared, so a patch added to patches/ after the tree was prepared is
# not noticed here (prepare-tree.sh's own checks cover that).
# Time:  O(P) manifest entries, one sha256 run each.
# Space: O(P) manifest lines in the scratch file.
fresh_reason() {
	_fr_tree=$1
	_fr_repo=$2
	_fr_prep=$_fr_tree/.prepared
	_fr_ko=$_fr_tree/nvidia/nvidia.ko
	if [ ! -f "$_fr_prep" ]; then
		echo "no $_fr_prep: run scripts/prepare-tree.sh first"
		return 1
	fi
	if [ "$(sed -n '2p' "$_fr_prep" 2>/dev/null)" != "state done" ]; then
		echo "$_fr_prep does not say 'state done'"
		return 1
	fi
	if ! sed -n '3,$p' "$_fr_prep" > "$TMPD/fr-manifest" 2>/dev/null; then
		echo "cannot read the manifest from $_fr_prep"
		return 1
	fi
	if [ ! -s "$TMPD/fr-manifest" ]; then
		echo "$_fr_prep carries no manifest lines"
		return 1
	fi
	while read -r _fr_name _fr_sha; do
		[ -n "$_fr_name" ] || continue
		case $_fr_name in
		patch-*) _fr_src=$_fr_repo/patches/$_fr_name ;;
		src/*) _fr_src=$_fr_repo/$_fr_name ;;
		*)
			echo "unknown manifest entry: $_fr_name"
			return 1
			;;
		esac
		if [ ! -f "$_fr_src" ]; then
			echo "the manifest names $_fr_name but $_fr_src does not exist"
			return 1
		fi
		if ! _fr_now=$(sha256 -q "$_fr_src"); then
			echo "cannot hash $_fr_src"
			return 1
		fi
		if [ "$_fr_now" != "$_fr_sha" ]; then
			echo "$_fr_name changed since the tree was prepared (manifest $_fr_sha, now $_fr_now)"
			return 1
		fi
	done < "$TMPD/fr-manifest"
	if [ ! "$_fr_ko" -nt "$_fr_prep" ]; then
		echo "$_fr_ko is not newer than $_fr_prep: it predates the prepared tree"
		return 1
	fi
	return 0
}

# (e) freshness of the nvidia.ko this test checks.
# A non-zero status is stale even with no reason printed: "could not
# finish the check" must never read as fresh.
_fr_rc=0
_fr_reason=$(fresh_reason "$TREE" "$REPO") || _fr_rc=$?
if [ "$_fr_rc" -ne 0 ] || [ -n "$_fr_reason" ]; then
	[ -n "$_fr_reason" ] || _fr_reason="freshness check failed (status $_fr_rc)"
	fail "stale artifacts: $_fr_reason (rerun scripts/prepare-tree.sh and scripts/build-shim.sh)"
fi
echo "fresh: .prepared says state done, its manifest matches patches/ and src/, nvidia.ko is newer than .prepared"

# (e-control-1) Falsifiability: a nvidia.ko that PREDATES .prepared must be
# refused. The scratch tree holds a copy of the real .prepared and a copy
# of nvidia.ko with an old timestamp - everything else is identical, so
# only the age of the module can be what fails.
STALE=$TMPD/stale-tree
mkdir -p "$STALE/nvidia"
cp "$TREE/.prepared" "$STALE/.prepared"
cp "$KO" "$STALE/nvidia/nvidia.ko"
touch -t 202501010000 "$STALE/nvidia/nvidia.ko"
_fr_rc=0
_fr_out=$(fresh_reason "$STALE" "$REPO") || _fr_rc=$?
if [ "$_fr_rc" -ne 0 ]; then
	echo "freshness control: a stale nvidia.ko is refused: $_fr_out"
else
	fail "(e-control-1) a stale nvidia.ko passes the freshness check"
fi

# (e-control-2) Falsifiability: a .prepared whose manifest hash no longer
# matches the repo's file must be refused - the patches changed after the
# tree was prepared.
BAD=$TMPD/bad-manifest-tree
mkdir -p "$BAD/nvidia"
awk 'NR == 3 { sub(/[0-9a-f]+$/, "0000000000000000000000000000000000000000000000000000000000000000") } { print }' \
	"$TREE/.prepared" > "$BAD/.prepared"
cp "$KO" "$BAD/nvidia/nvidia.ko"
touch "$BAD/nvidia/nvidia.ko"
_fr_rc=0
_fr_out=$(fresh_reason "$BAD" "$REPO") || _fr_rc=$?
if [ "$_fr_rc" -ne 0 ]; then
	echo "freshness control: a changed patch hash is refused: $_fr_out"
else
	fail "(e-control-2) a changed patch hash passes the freshness check"
fi

# (a) ELF header: AArch64 machine, DYN (shared object) type. The .ko is
# DYN, not REL: bsd.kmod.mk links the intermediate nvidia.kld (REL, from
# `ld -r`) into nvidia.ko with `ld -Bshareable`, exactly like the
# system's own modules (linux64.ko, zfs.ko are DYN on this host).
readelf -h "$KO" > "$TMPD/hdr"
grep -q 'Machine:.*AArch64' "$TMPD/hdr" || fail "nvidia.ko machine is not AArch64"
grep -q 'Type:.*DYN' "$TMPD/hdr" || fail "nvidia.ko type is not DYN (shared object; bsd.kmod.mk links kmods with ld -Bshareable)"
echo "elf: AArch64, DYN"

# (b) every undefined symbol resolves in the kernel or a declared
# dependency module.
KERNEL=$(sysctl -n kern.bootfile)
KDIR=$(dirname "$KERNEL")
# nm runs into a file first: in a pipe an nm failure would be hidden and
# read as "no undefined symbols", silently passing this section.
nm -u "$KO" > "$TMPD/nm-undef" || fail "nm -u failed on $KO"
awk '{print $NF}' < "$TMPD/nm-undef" | sort -u > "$TMPD/undef"

# append_defined_syms FILE OUT - append FILE's GLOBAL defined symbol
# names to OUT. Uppercase nm types plus 'i' count; every other lowercase
# (STB_LOCAL) type is dropped: the kernel linker never resolves a
# module's undefined symbols against local symbols
# (kern/link_elf.c:1589-1590, 1705), so a local kernel function sharing
# a name with one of nvidia.ko's undefined symbols must NOT read as a
# resolver. 'i' is STT_GNU_IFUNC, which nm prints lowercase whatever the
# binding; the kernel's IFUNCs (memcpy, memset, ...) are all GLOBAL -
# verified with readelf -sW on this kernel - and modules really do
# resolve against them. nm runs into a file first: in a pipe an nm
# failure would be hidden and read as "FILE defines nothing",
# misreporting every one of its symbols as unresolved.
# Time:  O(S) for S symbols in FILE (one nm + awk pass).
# Space: O(S) lines appended to OUT.
append_defined_syms() {
	nm "$1" > "$TMPD/nm-syms" || fail "nm failed on $1"
	awk 'NF == 3 && ($2 ~ /^[A-TV-Z]$/ || $2 == "i") {print $3}' < "$TMPD/nm-syms" >> "$2"
}

nm "$KERNEL" > /dev/null 2>&1 || fail "cannot read symbols of running kernel $KERNEL"
append_defined_syms "$KERNEL" "$TMPD/defined"
# (c) dependency names embedded in nvidia.ko (see header comment), read
# BEFORE the symbol check: the kernel linker resolves a module's undefined
# symbols only from the kernel and the module's DIRECT dependencies
# (linker_file_lookup_symbol() does not follow a dependency's own
# dependencies), so the defined set below must be built from exactly the
# declared ones. A symbol that only an undeclared module defines (2026-11-18:
# linux_device_register_handler, in linux_common.ko, which nvidia.ko did not
# declare) fails kldload with "symbol ... undefined" and must fail here.
# nm runs into a file first: in a pipe an nm failure would be hidden by
# the pipeline's last-stage status, and only a file keeps nm's own
# failure checkable instead of masquerading as "no dependencies".
# Time:  O(N) for N lines of nm output (grep/awk/sed/sort passes).
# Space: O(N) for the nm dump, O(P) for P dependency names.
nm "$KO" > "$TMPD/nm-all" || fail "nm failed on $KO"
grep '_nvidia_depend_on_' "$TMPD/nm-all" | awk '{print $NF}' \
    | sed 's/.*_nvidia_depend_on_//' | sort -u > "$TMPD/deps"
[ -s "$TMPD/deps" ] || fail "no MODULE_DEPEND symbols found in nvidia.ko"
echo "deps: $(tr '\n' ' ' < "$TMPD/deps")"
# Exact set, not membership: an extra dependency (a regression putting
# back MODULE_DEPEND(nvidia, linux) - no such module on arm64) or a
# missing one must both fail here, before kldload could.
printf 'linux64elf\nlinux_common\nmem\n' > "$TMPD/deps-want"
if cmp -s "$TMPD/deps" "$TMPD/deps-want"; then
	echo "deps ok: exactly linux64elf linux_common mem"
else
	fail "dependency set is not exactly {linux64elf, linux_common, mem}: got [$(tr '\n' ' ' < "$TMPD/deps")]"
fi

# Symbols from the kernel and from each DECLARED dependency's file. On this
# arm64 kernel the module name linux64elf is registered by linux64.ko
# (sys/arm64/linux/linux_sysvec.c: DECLARE_MODULE_TIED(linux64elf, ...));
# any other name is <name>.ko. A dependency with no file must be compiled
# into the kernel (mem is, in GENERIC), so its symbols are the kernel's.
# Time:  O(P) loop iterations for P declared dependencies.
# Space: O(1) in this shell.
while IFS= read -r dep; do
	case $dep in
	linux64elf) f=linux64 ;;
	*) f=$dep ;;
	esac
	if [ -f "$KDIR/$f.ko" ]; then
		append_defined_syms "$KDIR/$f.ko" "$TMPD/defined"
	elif [ "$dep" != mem ]; then
		fail "no $KDIR/$f.ko for declared dependency $dep"
	fi
done < "$TMPD/deps"
sort -u "$TMPD/defined" -o "$TMPD/defined"

# Time:  O(U log U + D log D) for the two sorts and the comm(1) merge,
#        U undefined and D defined symbols.
# Space: O(U + D) across the scratch files.
comm -23 "$TMPD/undef" "$TMPD/defined" > "$TMPD/unresolved"
if [ -s "$TMPD/unresolved" ]; then
	sed 's/^/unresolved symbol: /' "$TMPD/unresolved"
	fail "$(wc -l < "$TMPD/unresolved" | tr -d '[:space:]') undefined symbols resolve neither in $KERNEL nor in a declared dependency"
fi
echo "unresolved: 0"


# (d) BTI/PAC GNU property note on the core+stubs object.
# Time:  O(N) for N readelf note lines (two grep passes).
# Space: O(N) in the scratch file.
GB10OBJ=$WORK/build/nv-kernel-gb10.o
[ -f "$GB10OBJ" ] || fail "no $GB10OBJ: run scripts/build-stubs.sh first"
readelf -n "$GB10OBJ" > "$TMPD/notes"
grep -i 'AArch64 feature' "$TMPD/notes" | grep -q 'BTI' ||
	fail "nv-kernel-gb10.o lacks GNU_PROPERTY_AARCH64_FEATURE_1_BTI (build the core and stubs with -mbranch-protection=standard and keep .note.gnu.property)"
grep -i 'AArch64 feature' "$TMPD/notes" | grep -q 'PAC' ||
	fail "nv-kernel-gb10.o lacks the PAC GNU property (build with -mbranch-protection=standard)"
echo "property: nv-kernel-gb10.o has AArch64 feature BTI+PAC"

# (f) the nvidia-modeset module. It is checked when it has been built, and
# always when --modeset was given (then a missing module is a failure).
if [ "$WANT_MODESET" -eq 1 ] && [ ! -f "$MSKO" ]; then
	fail "no $MSKO: run scripts/build-shim.sh --module=nvidia-modeset first"
fi
if [ ! -f "$MSKO" ]; then
	echo "modeset: $MSKO not built: not checked (build it with scripts/build-shim.sh --module=nvidia-modeset)"
	if [ -f "$DRMKO" ]; then
		fail "no $MSKO: nvidia-drm.ko is built and takes symbols from the modeset module: run scripts/build-shim.sh --module=nvidia-modeset first"
	fi
	echo "PASS"
	exit 0
fi

# The module must come from the current patches too: a modeset .ko built
# before the tree was prepared is stale in the same way nvidia.ko is.
if [ ! "$MSKO" -nt "$TREE/.prepared" ]; then
	fail "stale artifacts: $MSKO is not newer than $TREE/.prepared: it predates the prepared tree"
fi

readelf -h "$MSKO" > "$TMPD/ms-hdr"
grep -q 'Machine:.*AArch64' "$TMPD/ms-hdr" ||
	fail "nvidia-modeset.ko machine is not AArch64"
grep -q 'Type:.*DYN' "$TMPD/ms-hdr" ||
	fail "nvidia-modeset.ko type is not DYN (shared object; kmod.mk links kmods with ld -Bshareable)"
echo "modeset elf: AArch64, DYN"

# (f1) the declared dependency set. MODULE_DEPEND(9) makes each
# MODULE_DEPEND(m, dep) emit a linker-set symbol
# __set_modmetadata_set_sym__mod_metadata_<m>_depend_on_<dep> and a static
# struct _<m>_depend_on_<dep>, so "nm | grep _nvidia_modeset_depend_on_"
# yields the dependency list. The set must be exactly {linux64elf,
# linux_common, nvidia} plus the kernel itself: "kernel" is not a module
# and has no .ko file, so it may or may not be declared, but nothing else
# may be - MODULE_DEPEND(nvidia_modeset, linux) (the 32-bit Linuxulator,
# which does not exist on arm64) would fail at kldload.
nm "$MSKO" > "$TMPD/ms-nm-all" || fail "nm failed on $MSKO"
grep '_nvidia_modeset_depend_on_' "$TMPD/ms-nm-all" | awk '{print $NF}' \
    | sed 's/.*_nvidia_modeset_depend_on_//' | sort -u > "$TMPD/ms-deps"
[ -s "$TMPD/ms-deps" ] || fail "no MODULE_DEPEND symbols found in nvidia-modeset.ko"
while IFS= read -r _ms_dep; do
	case $_ms_dep in
	kernel|linux64elf|linux_common|nvidia) ;;
	*)
		fail "nvidia-modeset.ko declares an unexpected dependency: $_ms_dep (allowed: kernel, linux64elf, linux_common, nvidia)"
		;;
	esac
done < "$TMPD/ms-deps"
for _ms_dep in linux64elf linux_common nvidia; do
	grep -qx "$_ms_dep" "$TMPD/ms-deps" ||
		fail "nvidia-modeset.ko does not declare the dependency $_ms_dep"
done
echo "modeset deps: $(tr '\n' ' ' < "$TMPD/ms-deps")"
echo "deps ok: exactly linux64elf linux_common nvidia (plus the kernel itself)"

# (f2) every undefined symbol resolves in the kernel or in the file of one
# of the declared dependencies, and only against their EXPORTED symbols.
# linux64elf is registered by linux64.ko (the 64-bit Linuxulator),
# linux_common by linux_common.ko, and nvidia by TREE/nvidia/nvidia.ko.
nm -u "$MSKO" > "$TMPD/ms-nm-undef" || fail "nm -u failed on $MSKO"
awk '{print $NF}' < "$TMPD/ms-nm-undef" | sort -u > "$TMPD/ms-undef"
: > "$TMPD/ms-defined-others"
append_defined_syms "$KERNEL" "$TMPD/ms-defined-others"
[ -f "$KDIR/linux64.ko" ] || fail "no $KDIR/linux64.ko for the linux64elf dependency"
[ -f "$KDIR/linux_common.ko" ] ||
	fail "no $KDIR/linux_common.ko for the linux_common dependency"
append_defined_syms "$KDIR/linux64.ko" "$TMPD/ms-defined-others"
append_defined_syms "$KDIR/linux_common.ko" "$TMPD/ms-defined-others"
sort -u "$TMPD/ms-defined-others" -o "$TMPD/ms-defined-others"
cat "$TMPD/ms-defined-others" > "$TMPD/ms-defined"
append_defined_syms "$KO" "$TMPD/ms-defined"
sort -u "$TMPD/ms-defined" -o "$TMPD/ms-defined"
comm -23 "$TMPD/ms-undef" "$TMPD/ms-defined" > "$TMPD/ms-unresolved"
if [ -s "$TMPD/ms-unresolved" ]; then
	sed 's/^/modeset unresolved symbol: /' "$TMPD/ms-unresolved"
	fail "$(wc -l < "$TMPD/ms-unresolved" | tr -d '[:space:]') undefined symbols of nvidia-modeset.ko resolve neither in $KERNEL nor in a declared dependency"
fi
echo "modeset unresolved: 0"

# (f3) nvidia.ko must export (define globally) every symbol
# nvidia-modeset.ko takes from it. kmod.mk exports nothing unless
# EXPORT_SYMS names the symbol: without the hunk in
# patches/patch-nvidia_Makefile the symbols stay local in nvidia.ko and
# the kernel linker cannot resolve them.
# export_check <modeset-ko> <nvidia-ko> <out>: write to <out> the symbols
# the modeset module takes from the nvidia module that <nvidia-ko> does
# NOT export. Only GLOBAL defined symbols count as exported (the kernel
# linker never resolves against STB_LOCAL ones). A symbol counts as taken
# from the nvidia module only when nothing else can resolve it: the
# kernel's own symbols and the other dependencies' are looked up first -
# nvidia.ko holds LOCAL memcpy and memset (the RM core localizes them),
# and those resolve against the kernel's IFUNCs, not against nvidia.ko.
# Time:  O(U log U + D log D) for the sorts, plus one nm run per file.
# Space: O(U + D) across the scratch files.
export_check() {
	_ec_ms=$1
	_ec_nv=$2
	_ec_out=$3
	nm -u "$_ec_ms" | awk '{print $NF}' | sort -u > "$TMPD/ec-undef"
	nm "$_ec_nv" > "$TMPD/ec-nv-all" || return 1
	awk 'NF == 3 { print $3 }' < "$TMPD/ec-nv-all" | sort -u > "$TMPD/ec-nv-any"
	awk 'NF == 3 && ($2 ~ /^[A-TV-Z]$/ || $2 == "i") { print $3 }' \
	    < "$TMPD/ec-nv-all" | sort -u > "$TMPD/ec-nv-global"
	comm -12 "$TMPD/ec-undef" "$TMPD/ms-defined-others" > "$TMPD/ec-elsewhere"
	comm -23 "$TMPD/ec-undef" "$TMPD/ec-elsewhere" > "$TMPD/ec-mine"
	comm -12 "$TMPD/ec-mine" "$TMPD/ec-nv-any" > "$TMPD/ec-taken"
	comm -23 "$TMPD/ec-taken" "$TMPD/ec-nv-global" > "$_ec_out"
	return 0
}
export_check "$MSKO" "$KO" "$TMPD/ms-not-exported"
if [ -s "$TMPD/ms-not-exported" ]; then
	sed 's/^/not exported by nvidia.ko: /' "$TMPD/ms-not-exported"
	fail "nvidia.ko does not export the symbols nvidia-modeset.ko takes from it (add them to EXPORT_SYMS in patches/patch-nvidia_Makefile)"
fi
echo "modeset exports: nvidia.ko exports every symbol nvidia-modeset.ko takes from it"

# (f-control) Falsifiability: a nvidia.ko that does NOT export those
# symbols must be refused. The kernel build turns a symbol global only
# when the module's Makefile names it in EXPORT_SYMS (sys/conf/kmod.mk:
# kmod_syms.awk + objcopy --globalize-symbol); without that hunk the
# symbols stay local. The control reproduces exactly that on the real
# module: a copy of nvidia.ko with the symbols localized.
CTL=$TMPD/ctl-nvidia.ko
cp "$KO" "$CTL"
_ctl_args=
while IFS= read -r _ctl_sym; do
	[ -n "$_ctl_sym" ] || continue
	_ctl_args="$_ctl_args --localize-symbol=$_ctl_sym"
done < "$TMPD/ec-taken"
if [ -z "$_ctl_args" ]; then
	fail "nvidia-modeset.ko takes no symbol from nvidia.ko: the export check cannot be exercised"
fi
# shellcheck disable=SC2086
if command -v llvm-objcopy > /dev/null 2>&1; then
	OBJCOPY_TOOL=llvm-objcopy
else
	OBJCOPY_TOOL=objcopy
fi
# shellcheck disable=SC2086
if ! $OBJCOPY_TOOL $_ctl_args "$CTL" "$TMPD/ctl-nvidia-local.ko" 2> "$TMPD/ctl-objcopy.err"; then
	fail "cannot build the export control: $OBJCOPY_TOOL failed: $(cat "$TMPD/ctl-objcopy.err")"
fi
export_check "$MSKO" "$TMPD/ctl-nvidia-local.ko" "$TMPD/ctl-not-exported"
if [ -s "$TMPD/ctl-not-exported" ]; then
	echo "export control: a nvidia.ko without the EXPORT_SYMS hunk is refused: $(tr '\n' ' ' < "$TMPD/ctl-not-exported")"
else
	fail "(f-control) a nvidia.ko that does not export the modeset module's symbols passes the export check"
fi

# --------------------------------------------------------------------------
# (g) the nvidia-drm module. It is NVIDIA's own FreeBSD code against
# drm-kmod: it declares the DRM, dmabuf, LinuxKPI, nvidia and
# nvidia-modeset modules, and every symbol it leaves undefined must be
# resolvable by the kernel linker, which looks only at the kernel and at
# the module's DIRECT dependencies, and only at their EXPORTED symbols.
if [ "$WANT_DRM" -eq 1 ] && [ ! -f "$DRMKO" ]; then
	fail "no $DRMKO: run scripts/build-shim.sh --module=nvidia-drm first"
fi
if [ ! -f "$DRMKO" ]; then
	echo "drm: $DRMKO not built: not checked (build it with scripts/build-shim.sh --module=nvidia-drm)"
	echo "PASS"
	exit 0
fi

# The module must come from the current patches too.
if [ ! "$DRMKO" -nt "$TREE/.prepared" ]; then
	fail "stale artifacts: $DRMKO is not newer than $TREE/.prepared: it predates the prepared tree"
fi

readelf -h "$DRMKO" > "$TMPD/drm-hdr"
grep -q 'Machine:.*AArch64' "$TMPD/drm-hdr" ||
	fail "nvidia-drm.ko machine is not AArch64"
grep -q 'Type:.*DYN' "$TMPD/drm-hdr" ||
	fail "nvidia-drm.ko type is not DYN (shared object; kmod.mk links kmods with ld -Bshareable)"
echo "drm elf: AArch64, DYN"

# (g1) the declared dependency set: exactly {dmabuf, drmn, linuxkpi,
# nvidia, nvidia_modeset} plus the kernel itself. "kernel" is not a
# module and has no .ko file, so it may or may not be declared, but
# nothing else may be: a dependency that does not exist on this system
# (the 32-bit Linuxulator "linux", or the x86-only "io") fails at
# kldload with "module ... not found".
nm "$DRMKO" > "$TMPD/drm-nm-all" || fail "nm failed on $DRMKO"
grep '_nvidia_drm_depend_on_' "$TMPD/drm-nm-all" | awk '{print $NF}' \
    | sed 's/.*_nvidia_drm_depend_on_//' | sort -u > "$TMPD/drm-deps"
[ -s "$TMPD/drm-deps" ] || fail "no MODULE_DEPEND symbols found in nvidia-drm.ko"
while IFS= read -r _drm_dep; do
	case $_drm_dep in
	kernel|dmabuf|drmn|linuxkpi|nvidia|nvidia_modeset) ;;
	*)
		fail "nvidia-drm.ko declares an unexpected dependency: $_drm_dep (allowed: kernel, dmabuf, drmn, linuxkpi, nvidia, nvidia_modeset)"
		;;
	esac
done < "$TMPD/drm-deps"
for _drm_dep in dmabuf drmn linuxkpi nvidia nvidia_modeset; do
	grep -qx "$_drm_dep" "$TMPD/drm-deps" ||
		fail "nvidia-drm.ko does not declare the dependency $_drm_dep"
done
echo "drm deps: $(tr '\n' ' ' < "$TMPD/drm-deps")"
echo "deps ok: exactly dmabuf drmn linuxkpi nvidia nvidia_modeset (plus the kernel itself)"

# The files the declared dependencies live in. drmn is the module name
# drm.ko registers itself under (sys/modules/drm: MODULE_VERSION or the
# DECLARE_MODULE in drm.c); dmabuf, drm and linuxkpi are modules of the
# running kernel's own directory.
for _drm_file in "$KDIR/dmabuf.ko" "$KDIR/drm.ko" "$KDIR/linuxkpi.ko"; do
	[ -f "$_drm_file" ] ||
		fail "no $_drm_file for a declared dependency of nvidia-drm.ko"
done

# drm_resolvers <out>: the EXPORTED symbols of the kernel and of every
# dependency of nvidia-drm.ko except the modeset module: the kernel
# itself, dmabuf.ko, drm.ko, linuxkpi.ko and TREE/nvidia/nvidia.ko.
# Only GLOBAL defined symbols count (the kernel linker never resolves a
# module's undefined symbols against STB_LOCAL ones).
# Time:  O(S) per file (one nm + awk pass each).
# Space: O(S) lines appended to OUT.
drm_resolvers() {
	: > "$1"
	append_defined_syms "$KERNEL" "$1"
	append_defined_syms "$KDIR/dmabuf.ko" "$1"
	append_defined_syms "$KDIR/drm.ko" "$1"
	append_defined_syms "$KDIR/linuxkpi.ko" "$1"
	append_defined_syms "$KO" "$1"
	sort -u "$1" -o "$1"
}

# drm_unresolved <drm-ko> <modeset-ko> <out>: the undefined symbols of
# <drm-ko> that neither the kernel nor one of the declared dependencies
# exports. <modeset-ko> is the modeset module the check resolves
# against, so the control can offer a doctored one.
# Time:  O(U log U + D log D) for the sorts and the comm(1) merge.
# Space: O(U + D) across the scratch files.
drm_unresolved() {
	_du_drm=$1
	_du_ms=$2
	_du_out=$3
	drm_resolvers "$TMPD/du-others"
	cp "$TMPD/du-others" "$TMPD/du-defined"
	append_defined_syms "$_du_ms" "$TMPD/du-defined"
	sort -u "$TMPD/du-defined" -o "$TMPD/du-defined"
	nm -u "$_du_drm" > "$TMPD/du-nm-undef" || fail "nm -u failed on $_du_drm"
	awk '{print $NF}' < "$TMPD/du-nm-undef" | sort -u > "$TMPD/du-undef"
	comm -23 "$TMPD/du-undef" "$TMPD/du-defined" > "$_du_out"
}

# (g2) every undefined symbol of nvidia-drm.ko must resolve.
drm_unresolved "$DRMKO" "$MSKO" "$TMPD/drm-unresolved"
# __this_linker_file is the one allowed exception: the kernel linker
# resolves that special symbol itself for every module (kern/kern_linker.c:
# "Treat the __this_linker_file as a special symbol"), it is what
# LinuxKPI's THIS_MODULE points at, and the system's own modules leave
# it undefined too (amdgpu.ko and drm.ko both do).
# awk, not grep -v: grep -v exits 1 when it selects no line (which is
# exactly the case here - the exception is the only unresolved symbol),
# and that would end the script under `set -e` with no message at all.
awk '!/^__this_linker_file$/' "$TMPD/drm-unresolved" > "$TMPD/drm-unresolved-real"
if [ -s "$TMPD/drm-unresolved-real" ]; then
	sed 's/^/drm unresolved symbol: /' "$TMPD/drm-unresolved-real"
	fail "$(wc -l < "$TMPD/drm-unresolved-real" | tr -d '[:space:]') undefined symbols of nvidia-drm.ko resolve neither in $KERNEL nor in a declared dependency (only __this_linker_file, which the kernel linker supplies, is allowed to be unresolved)"
fi
echo "drm unresolved: 0 (except __this_linker_file, which the kernel linker supplies to every module)"

# (g3) linuxkpi_video.ko is linuxkpi's OWN dependency: the kernel linker
# resolves a module's undefined symbols only from the kernel and from
# the module's own declared dependencies (linker_file_lookup_symbol()
# does not follow a dependency's dependencies), so a symbol that only
# linuxkpi_video.ko exports cannot be resolved by nvidia-drm.ko. Find
# out with nm whether nvidia-drm.ko needs one: if it does, that is a
# real defect - nvidia-drm.ko would have to declare linuxkpi_video as
# a dependency - and the test says so instead of papering over it.
if [ -f "$KDIR/linuxkpi_video.ko" ]; then
	append_defined_syms "$KDIR/linuxkpi_video.ko" "$TMPD/lkv-defined"
	sort -u "$TMPD/lkv-defined" -o "$TMPD/lkv-defined"
	comm -12 "$TMPD/drm-unresolved-real" "$TMPD/lkv-defined" > "$TMPD/drm-needs-lkv"
	if [ -s "$TMPD/drm-needs-lkv" ]; then
		sed 's/^/nvidia-drm.ko needs a symbol only linuxkpi_video.ko exports: /' \
		    "$TMPD/drm-needs-lkv"
		fail "nvidia-drm.ko needs symbols from linuxkpi_video.ko, which it does not declare as a dependency: the kernel linker will refuse the module at kldload"
	fi
	echo "drm linuxkpi_video: no symbol of nvidia-drm.ko comes only from linuxkpi_video.ko"
else
	echo "drm linuxkpi_video: no $KDIR/linuxkpi_video.ko: nothing to check"
fi

# (g-control) Falsifiability: a nvidia-modeset.ko that does NOT export
# the symbols nvidia-drm.ko takes from it must be refused. The kernel
# build turns a symbol global only when the module's Makefile names it in
# EXPORT_SYMS (sys/conf/kmod.mk: kmod_syms.awk + objcopy
# --globalize-symbol); without the hunk in
# patches/patch-nvidia-modeset_Makefile the eight nvKmsKapi* symbols
# stay local and kldload would fail with "symbol ... undefined". The
# control localizes them in a copy of the real module - exactly what a
# build without the hunk produces - and the check must refuse that copy.
# The symbols nvidia-drm.ko takes from the modeset module are the ones
# it leaves undefined, the modeset module defines, and nothing else
# defines.
append_defined_syms "$MSKO" "$TMPD/ms-exports"
sort -u "$TMPD/ms-exports" -o "$TMPD/ms-exports"
comm -12 "$TMPD/du-undef" "$TMPD/ms-exports" > "$TMPD/drm-from-ms"
drm_resolvers "$TMPD/du-others"
comm -23 "$TMPD/drm-from-ms" "$TMPD/du-others" > "$TMPD/drm-taken"
CTL=$TMPD/ctl-nvidia-modeset.ko
cp "$MSKO" "$CTL"
_ctl_args=
while IFS= read -r _ctl_sym; do
	[ -n "$_ctl_sym" ] || continue
	_ctl_args="$_ctl_args --localize-symbol=$_ctl_sym"
done < "$TMPD/drm-taken"
if [ -z "$_ctl_args" ]; then
	fail "nvidia-drm.ko takes no symbol from nvidia-modeset.ko: the export check cannot be exercised"
fi
# shellcheck disable=SC2086
if ! $OBJCOPY_TOOL $_ctl_args "$CTL" "$TMPD/ctl-nvidia-modeset-local.ko" 2> "$TMPD/ctl-objcopy.err"; then
	fail "cannot build the export control: $OBJCOPY_TOOL failed: $(cat "$TMPD/ctl-objcopy.err")"
fi
drm_unresolved "$DRMKO" "$TMPD/ctl-nvidia-modeset-local.ko" "$TMPD/drm-unresolved-ctl"
if [ -s "$TMPD/drm-unresolved-ctl" ]; then
	echo "drm export control: a nvidia-modeset.ko without the EXPORT_SYMS hunk is refused: $(tr '\n' ' ' < "$TMPD/drm-unresolved-ctl")"
else
	fail "(g-control) a nvidia-modeset.ko that does not export the DRM module's symbols passes the export check"
fi

echo "PASS"

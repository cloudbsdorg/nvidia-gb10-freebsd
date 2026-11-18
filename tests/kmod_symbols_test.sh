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
#
# Usage: tests/kmod_symbols_test.sh [TREE]
#   TREE  prepared working tree; defaults to ${GB10_WORK:-$HOME/work/gb10}/build/tree
#
# Prerequisite: scripts/prepare-tree.sh, scripts/build-stubs.sh and
# scripts/build-shim.sh have run and produced $WORK/build/nv-kernel-gb10.o
# and TREE/nvidia/nvidia.ko. Scratch stays under $WORK/tmp.

set -eu

PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL

WORK=${GB10_WORK:-$HOME/work/gb10}
TREE=${1:-$WORK/build/tree}
KO=$TREE/nvidia/nvidia.ko
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
echo "PASS"

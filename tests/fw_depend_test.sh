#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# fw_depend_test.sh - Track #2417: nvidia.ko depends on its GSP firmware
# modules, so a first open by a caller without PRIV_FIRMWARE_LOAD finds the
# firmware already registered. No kldload(8), no root.
#
# The claim, and what each part rests on:
#   (a) the patched nvidia_pci.c MODULE_DEPENDs on exactly the firmware
#       modules built for the arch, under the names the kernel registers
#       them with (<KMOD>_fw, from the same sys/tools/fw_stub.awk that
#       bsd.kmod.mk runs). The set built for amd64 is the SUBDIR of NVIDIA's
#       firmware/Makefile (make -V SUBDIR); the set built for arm64 is the
#       gsp_* directories scripts/build-firmware.sh builds. Both are read
#       from the tree, not written down here;
#   (b) the image names the driver requests for every GSP chip family (its
#       own macro and NVIDIA's nv-firmware.h, compiled here) are the images
#       those modules register with firmware_register(): all of them on
#       amd64; on arm64 all but the tu10x image, a NAMED exclusion (the
#       TU10X, TU11X and GA100 families are not supported on arm64: no
#       module for them is built there); and nvidia/ has exactly one
#       firmware_get() call site, the one fed by that macro, so no other
#       image is requested at open time (the GSP log image is requested
#       only when firmware logs are enabled and its absence is non-fatal,
#       checked in the pinned RM source);
#   (c) the kernel facts the design rests on, read from the FreeBSD source in
#       SYSDIR: a registered image is returned before the privilege check
#       (subr_firmware.c); loading a module from inside a module load waits
#       for the lock the load holds (kern_linker.c), which is why the driver
#       does not call firmware_get() from nvidia_attach(); an already loaded
#       dependency is accepted; a missing one prints the "depends on ... not
#       available" line the man page documents;
#   (d) the EnableGpuFirmware values the man page states are the RM source's
#       (nv-firmware-registry.h); nvidia_attach() has no firmware_get();
#       the docs name what was built; the test-boot rows are specified.
#   Every check also runs on a plant and must go red; a plant that changes
#   nothing, does not build, or hits a tooling failure is a FAIL, never a
#   pass.
#
# Usage: sh tests/fw_depend_test.sh
#   SYSDIR defaults to /usr/src/sys; without the FreeBSD source the kernel
#   fact checks FAIL unless FW_DEPEND_ALLOW_SKIP=1 (then they are reported
#   SKIPPED and the exit status is 2). The pinned NVIDIA sources
#   (scripts/fetch-sources.sh) are needed.
# Exit: 0 every case passes, 1 a case fails, 2 skipped by request.

set -u
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$repo/scripts/lib.sh"
WORK=${GB10_WORK:-$HOME/work/gb10}
SYSDIR=${SYSDIR:-/usr/src/sys}
command -v mandoc >/dev/null 2>&1 || { echo "FAIL: mandoc is not installed (needed for the man page lint)"; exit 1; }
command -v cc >/dev/null 2>&1 || { echo "FAIL: cc is not installed"; exit 1; }
ver=$(sources_get "$repo/SOURCES" ogkm_tag) || { echo "FAIL: no ogkm_tag in SOURCES"; exit 1; }
OGKM=$WORK/sources/open-gpu-kernel-modules-$ver
mkdir -p "$WORK/tmp" "$WORK/build" || exit 1
TMPD=$(mktemp -d "$WORK/tmp/fw-depend-test.XXXXXXXX") || exit 1
TREEROOT=
trap 'rm -rf -- "$TMPD" ${TREEROOT:+"$TREEROOT"}' EXIT
trap 'exit 130' INT TERM
TREEROOT=$(mktemp -d "$WORK/build/fw-depend-test.XXXXXXXX") || exit 1
TREE=$TREEROOT/tree

passed=0; failed=0; skipped=0
ok() { echo "PASS: $1"; passed=$((passed + 1)); }
bad() { echo "FAIL: $1"; failed=$((failed + 1)); }
skip() { echo "SKIPPED: $1"; skipped=$((skipped + 1)); }
# need_source <what>: a check that needs the FreeBSD source or fw_stub.awk
# is a FAIL without it, a SKIP with FW_DEPEND_ALLOW_SKIP=1.
need_source() {
	if [ "${FW_DEPEND_ALLOW_SKIP:-0}" = 1 ]; then skip "$1"; else bad "$1 (set SYSDIR, or FW_DEPEND_ALLOW_SKIP=1)"; fi
}

if ! GB10_WORK=$WORK sh "$repo/scripts/prepare-tree.sh" "$TREE" > "$TMPD/prepare.out" 2>&1; then
	echo "FAIL: prepare-tree.sh failed (run scripts/fetch-sources.sh first?)"; sed 's/^/    /' "$TMPD/prepare.out"; exit 1
fi
PCI=$TREE/nvidia/nvidia_pci.c
SUBR=$TREE/nvidia/nvidia_subr.c
STUB=$SYSDIR/tools/fw_stub.awk

# ---- the sets built per arch
# subdirs_of <arch macro>: the firmware/gsp_* directories built for the arch.
subdirs_of() {
	case "$1" in
	__amd64__)
		make -C "$TREE/firmware" -V SUBDIR 2> "$TMPD/make.err" | tr ' ' '\n' | sed '/^$/d' | sort
		;;
	__aarch64__)
		grep -o 'firmware/gsp_[a-z0-9]*' "$repo/scripts/build-firmware.sh" | sed 's|firmware/||' | sort -u
		;;
	esac
}
# build_sets <arch macro>: write $TMPD/mods.<arch> (module names, as kldstat
# shows them) and $TMPD/imgs.<arch> (image names firmware_register() gets) for
# the firmware modules built for the arch: KMOD and FIRMWS read from each
# directory's Makefile, the stub generated by the tool bsd.kmod.mk runs.
# Returns 2 on any tooling failure.
build_sets() {
	_mods=$TMPD/mods.$1; _imgs=$TMPD/imgs.$1
	: > "$_mods.raw"; : > "$_imgs.raw"
	subdirs_of "$1" > "$TMPD/subdirs.$1"
	[ -s "$TMPD/subdirs.$1" ] || return 2
	while read -r _sd; do
		_mk=$TREE/firmware/$_sd/Makefile
		[ -f "$_mk" ] || return 2
		_kmod=$(awk '$1 == "KMOD=" { print $2 }' "$_mk")
		_fws=$(awk '$1 == "FIRMWS=" { print $2 }' "$_mk" | sed "s/\${KMOD}/$_kmod/")
		[ -n "$_kmod" ] && [ -n "$_fws" ] || return 2
		awk -f "$STUB" $_fws "-m$_kmod" "-c$TMPD/stub.$_kmod.c" || return 2
		grep -o 'MODULE_VERSION([A-Za-z0-9_]*' "$TMPD/stub.$_kmod.c" | sed 's/^MODULE_VERSION(//' >> "$_mods.raw" || return 2
		sed -n 's/.*firmware_register("\([^"]*\)".*/\1/p' "$TMPD/stub.$_kmod.c" >> "$_imgs.raw"
	done < "$TMPD/subdirs.$1"
	sort "$_mods.raw" > "$_mods" || return 2
	sort -u "$_imgs.raw" > "$_imgs" || return 2
	[ -s "$_mods" ] && [ -s "$_imgs" ]
}
# region <nvidia_pci.c> <out>: the text this change added, from the comment
# line before its marker to the end of the file.
region() {
	awk -v marker='Track #2417: the GSP firmware' '
	{ if (!on && index($0, marker)) { on = 1; print prev } if (on) print; prev = $0 }' "$1" > "$2"
	[ -s "$2" ]
}
# deps_of <region file> <arch macro> <out>: the module names the region
# depends on for that arch (MODULE_DEPEND expanded by the preprocessor, so the
# #if arms are really evaluated). Returns 2 when the preprocessor fails.
deps_of() {
	{ echo '#define MODULE_DEPEND(a, b, c, d, e) DEP b'; cat "$1"; } > "$TMPD/dep-in.c"
	cc -E -P -x c -undef "-D$2" "$TMPD/dep-in.c" > "$TMPD/dep-out.c" 2> "$TMPD/dep-cc.err" || return 2
	awk '$1 == "DEP" { sub(/;$/, "", $2); print $2 }' "$TMPD/dep-out.c" | sort > "$3"
}
# check_set <region file>: 0 = the dependency set equals the built set on both
# arches, 1 = it differs, 2 = a tool failed.
check_set() {
	for _a in __aarch64__ __amd64__; do
		deps_of "$1" "$_a" "$TMPD/deps.$_a" || return 2
		cmp -s "$TMPD/deps.$_a" "$TMPD/mods.$_a" || return 1
	done
	return 0
}

region "$PCI" "$TMPD/region.c" || { bad "the patched nvidia_pci.c has no firmware dependency region"; echo "passed=$passed failed=$failed"; exit 1; }

echo "== (a) the dependency set equals the firmware modules built, per arch"
if [ ! -f "$STUB" ]; then
	need_source "(a) no $STUB"
else
	have_sets=1
	for _a in __aarch64__ __amd64__; do
		build_sets "$_a" || { bad "(a) could not read the firmware modules built for $_a (KMOD/FIRMWS of firmware/gsp_*/Makefile, SUBDIR, or $STUB failed)"; have_sets=0; }
	done
	if [ "$have_sets" -eq 1 ]; then
		check_set "$TMPD/region.c"; _rc=$?
		if [ "$_rc" -eq 0 ]; then
			ok "arm64 depends on $(tr '\n' ' ' < "$TMPD/deps.__aarch64__")and amd64 on $(tr '\n' ' ' < "$TMPD/deps.__amd64__")= the modules built"
		elif [ "$_rc" -eq 2 ]; then
			bad "(a) the preprocessor failed: $(cat "$TMPD/dep-cc.err")"
		else
			bad "(a) dependency set differs from the built modules"
			for _a in __aarch64__ __amd64__; do echo "  $_a deps: $(tr '\n' ' ' < "$TMPD/deps.$_a") built: $(tr '\n' ' ' < "$TMPD/mods.$_a")"; done
		fi
		plant_region() {
			# plant_region <label> <sed expression>: the check must report 1 (differs)
			sed -e "$2" "$TMPD/region.c" > "$TMPD/region.plant"
			if cmp -s "$TMPD/region.c" "$TMPD/region.plant"; then bad "plant $1 changed nothing"; return; fi
			check_set "$TMPD/region.plant"; _prc=$?
			case $_prc in
			1) ok "plant: $1 goes red" ;;
			2) bad "plant: $1: a tool failed, the plant proves nothing" ;;
			*) bad "plant: $1 did not go red" ;;
			esac
		}
		plant_region "the ga10x dependency dropped" '/MODULE_DEPEND(nvidia, nvidia_gsp_ga10x_fw_fw/d'
		plant_region "the ga10x name without its _fw suffix (the file name, not the module name)" 's/nvidia_gsp_ga10x_fw_fw/nvidia_gsp_ga10x_fw/'
		plant_region "tu10x on every arch (arm64 does not build it)" '/^#if defined(__amd64__)$/d;/^#endif$/d'
		plant_region "the amd64 tu10x dependency dropped" '/MODULE_DEPEND(nvidia, nvidia_gsp_tu10x_fw_fw/d'
		# the build side of the arm64 set: a build-firmware.sh that builds tu10x too
		sed 's|firmware/gsp_ga10x|firmware/gsp_ga10x firmware/gsp_tu10x|' "$repo/scripts/build-firmware.sh" > "$TMPD/build-firmware.plant"
		_n=$(grep -o 'firmware/gsp_[a-z0-9]*' "$TMPD/build-firmware.plant" | sed 's|firmware/||' | sort -u | tr '\n' ' ')
		[ "$_n" = "gsp_ga10x gsp_tu10x " ] && ok "plant: a build-firmware.sh that builds tu10x changes the derived arm64 set (the dependency set would then differ)" || bad "plant: the derived arm64 set did not change ($_n)"
	fi
	# a tooling failure must not read as a pass: fw_stub.awk replaced by one that fails
	printf 'BEGIN { exit 1 }\n' > "$TMPD/stub.fail.awk"
	_saved=$STUB; STUB=$TMPD/stub.fail.awk
	build_sets __amd64__; [ $? -eq 2 ] && ok "a failing fw_stub.awk is a tooling failure (rc 2), not a difference" || bad "a failing fw_stub.awk was not reported as a tooling failure"
	STUB=$_saved
fi

# ---- (b) the images the driver requests are the images the modules register
echo "== (b) the image names the driver requests are registered by those modules"
grep '^#define NV_FIRMWARE_FOR_NAME' "$SUBR" > "$TMPD/fwmacro.h"
build_names() {
	# build_names <macro header> <out binary>
	cc -std=gnu99 -Wall -I"$TREE/common/inc" -I"$TREE/nvidia" -DFW_NAME_MACRO="\"$1\"" \
	    -o "$2" "$repo/tests/data/fw_names.c" 2> "$TMPD/fw_names.err"
}
if [ ! -s "$TMPD/fwmacro.h" ]; then
	bad "(b) NV_FIRMWARE_FOR_NAME not found in nvidia/nvidia_subr.c (moved or renamed?)"
elif ! build_names "$TMPD/fwmacro.h" "$TMPD/fw_names"; then
	bad "(b) could not build the name printer"; cat "$TMPD/fw_names.err"
elif [ ! -s "$TMPD/imgs.__amd64__" ] || [ ! -s "$TMPD/imgs.__aarch64__" ]; then
	need_source "(b) the registered image sets are unavailable (see (a))"
else
	"$TMPD/fw_names" | sort -u > "$TMPD/requested"
	EXCL_ARM64=nvidia_gsp_tu10x_fw	# TU10X, TU11X and GA100 families: no module is built for them on arm64
	grep -vx "$EXCL_ARM64" "$TMPD/requested" > "$TMPD/requested.arm64"
	if [ -s "$TMPD/requested" ] && cmp -s "$TMPD/requested" "$TMPD/imgs.__amd64__"; then
		ok "amd64: the driver requests exactly the registered images: $(tr '\n' ' ' < "$TMPD/requested")"
	else
		bad "(b) amd64 requested: $(tr '\n' ' ' < "$TMPD/requested") registered: $(tr '\n' ' ' < "$TMPD/imgs.__amd64__")"
	fi
	if [ -s "$TMPD/requested.arm64" ] && cmp -s "$TMPD/requested.arm64" "$TMPD/imgs.__aarch64__"; then
		ok "arm64: the requested images, less the named exclusion $EXCL_ARM64, are exactly the registered ones: $(tr '\n' ' ' < "$TMPD/requested.arm64")"
	else
		bad "(b) arm64 requested (less $EXCL_ARM64): $(tr '\n' ' ' < "$TMPD/requested.arm64") registered: $(tr '\n' ' ' < "$TMPD/imgs.__aarch64__")"
	fi
	# plant: a driver macro that builds a different name (must build, run and differ)
	sed 's/"nvidia_" name "_fw"/"nvidia_" name/' "$TMPD/fwmacro.h" > "$TMPD/fwmacro.plant.h"
	rm -f "$TMPD/fw_names.plant" "$TMPD/requested.plant"
	if ! cmp -s "$TMPD/fwmacro.h" "$TMPD/fwmacro.plant.h" && build_names "$TMPD/fwmacro.plant.h" "$TMPD/fw_names.plant" \
	    && "$TMPD/fw_names.plant" | sort -u > "$TMPD/requested.plant" && [ -s "$TMPD/requested.plant" ]; then
		if ! cmp -s "$TMPD/requested.plant" "$TMPD/imgs.__amd64__"; then ok "plant: a driver macro without the _fw suffix goes red"; else bad "plant: the changed driver macro was not seen"; fi
	else
		bad "plant: the changed driver macro did not build or run, the plant proves nothing"
	fi
	# a plant that does not build is a FAIL, not a pass
	printf '%s\n' '#define NV_FIRMWARE_FOR_NAME(name)  "nvidia_" name "' > "$TMPD/fwmacro.broken.h"
	build_names "$TMPD/fwmacro.broken.h" "$TMPD/fw_names.broken" 2>/dev/null && bad "a syntactically broken macro built" || ok "a macro that does not compile is detected as a build failure"
fi
# the single firmware_get() call site
_n=$(cat "$TREE"/nvidia/*.c | awk '/^[ \t]*(\/\/|\/\*|\*)/ { next } /firmware_get[ \t]*\(/ { n++ } END { print n + 0 }')
if [ "$_n" -eq 1 ] && awk '/^const void\* NV_API_CALL nv_get_firmware/ { inf = 1 } inf && /firmware_get\(fw_name\)/ { f = 1 } inf && /^}/ { inf = 0 } END { exit !f }' "$SUBR"; then
	ok "nvidia/ has exactly one firmware_get() call site, in nv_get_firmware, fed by the name macro"
else
	bad "nvidia/ has $_n firmware_get() call sites, or the one is not in nv_get_firmware"
fi
mkdir -p "$TMPD/nv-plant"; cat "$TREE"/nvidia/*.c > "$TMPD/nv-plant/all.c"; echo '    (void)firmware_get("nvidia_gsp_log_ga10x_fw");' >> "$TMPD/nv-plant/all.c"
_n2=$(awk '/^[ \t]*(\/\/|\/\*|\*)/ { next } /firmware_get[ \t]*\(/ { n++ } END { print n + 0 }' "$TMPD/nv-plant/all.c")
[ "$_n2" -eq 2 ] && ok "plant: a second firmware_get() call site is counted (goes red)" || bad "plant: a second call site was not counted"
OSINIT=$OGKM/src/nvidia/arch/nvalloc/unix/src/osinit.c
if grep -q 'if (nv->enable_firmware_logs)' "$OSINIT" && grep -q 'no GSP-RM logs will be printed (non-fatal)' "$OSINIT"; then
	ok "the RM source requests the GSP log image only when firmware logs are enabled, and its absence is non-fatal"
else
	bad "the RM source no longer guards the GSP log image request as documented"
fi

# ---- (c) kernel facts, from the FreeBSD source
echo "== (c) the kernel facts the design rests on ($SYSDIR)"
SF=$SYSDIR/kern/subr_firmware.c
KL=$SYSDIR/kern/kern_linker.c
if [ -f "$SF" ] && [ -f "$KL" ]; then
	fact_priv_after_lookup() {
		# the registered-image return ("goto found" on a hit) comes before
		# the PRIV_FIRMWARE_LOAD check in firmware_get_flags
		awk '/^firmware_get_flags\(/ { inf = 1 }
		inf && /goto found;/ && !f { f = NR }
		inf && /PRIV_FIRMWARE_LOAD/ && !p { p = NR }
		inf && /^}/ { inf = 0 }
		END { exit !(f && p && f < p) }' "$1"
	}
	fact_lock() {
		# loadimage() loads a missing module through linker_reference_module(),
		# which takes kld_sx exclusively; kldload loads under that lock
		# (linker_load_module asserts it held)
		awk '/^linker_reference_module\(/ { a = 1 } a && /sx_xlock\(&kld_sx\)/ { r = 1 } a && /^}/ { a = 0 }
		/^linker_load_module\(/ { b = 1 } b && /sx_assert\(&kld_sx, SA_XLOCKED\)/ { l = 1 } b && /^}/ { b = 0 }
		END { exit !(r && l) }' "$1" || return 1
		grep -q 'linker_reference_module(fwli->imagename' "$2"
	}
	fact_dep_messages() {
		# a loaded dependency is accepted (modlist_lookup2 hit, no load), a missing
		# one prints the line the man page documents
		grep -q "woohoo, it's loaded already" "$1" && grep -q 'depends on %s - not available or' "$1"
	}
	fact_priv_after_lookup "$SF"; [ $? -eq 0 ] && ok "firmware_get_flags returns a registered image before the PRIV_FIRMWARE_LOAD check" || bad "(c) the privilege check is not after the lookup"
	fact_lock "$KL" "$SF"; [ $? -eq 0 ] && ok "a module load holds kld_sx and the firmware loader's reference takes it" || bad "(c) the kld_sx facts do not hold"
	fact_dep_messages "$KL"; [ $? -eq 0 ] && ok "the linker accepts a loaded dependency and prints 'depends on ... not available or version mismatch' for a missing one" || bad "(c) the linker dependency messages changed"
	# plants: the same checks on altered copies of the kernel source
	awk '/^firmware_get_flags\(/ { inf = 1 } inf && /^\tfp = lookup\(imagename\);$/ && !d { d = 1; print "\tif (priv_check(td, PRIV_FIRMWARE_LOAD) != 0)\n\t\treturn NULL;" } { print } /^}/ { inf = 0 }' "$SF" > "$TMPD/sf.plant.c"
	if cmp -s "$SF" "$TMPD/sf.plant.c"; then bad "plant: the moved privilege check changed nothing"
	else fact_priv_after_lookup "$TMPD/sf.plant.c"; [ $? -eq 1 ] && ok "plant: the privilege check before the lookup goes red" || bad "plant: privilege check moved, not seen"; fi
	sed 's/sx_xlock(&kld_sx)/sx_slock(\&kld_sx)/' "$KL" > "$TMPD/kl.plant.c"
	if cmp -s "$KL" "$TMPD/kl.plant.c"; then bad "plant: the kld_sx plant changed nothing"
	else fact_lock "$TMPD/kl.plant.c" "$SF"; [ $? -eq 1 ] && ok "plant: a linker_reference_module that does not take kld_sx exclusively goes red" || bad "plant: kld_sx lock fact not seen"; fi
	sed 's/depends on %s - not available or/needs %s - not available or/' "$KL" > "$TMPD/kl.plant2.c"
	if cmp -s "$KL" "$TMPD/kl.plant2.c"; then bad "plant: the dependency message plant changed nothing"
	else fact_dep_messages "$TMPD/kl.plant2.c"; [ $? -eq 1 ] && ok "plant: a changed linker dependency message goes red" || bad "plant: dependency message change not seen"; fi
else
	need_source "(c) no FreeBSD source in $SYSDIR"
fi

# ---- (d) tunable values, attach, docs, test-boot rows
echo "== (d) tunable values, attach, docs, test-boot rows"
REG=$OGKM/kernel-open/common/inc/nv-firmware-registry.h
MAN=$repo/man/nvidia.4
reg_ok() {
	# the values the man page states for EnableGpuFirmware: 0 off, 1 on, 2 default policy
	grep -q 'NV_REG_ENABLE_GPU_FIRMWARE_MODE_DISABLED[ \t]*0x00000000' "$1" &&
	grep -q 'NV_REG_ENABLE_GPU_FIRMWARE_MODE_ENABLED[ \t]*0x00000001' "$1" &&
	grep -q 'NV_REG_ENABLE_GPU_FIRMWARE_MODE_DEFAULT[ \t]*0x00000002' "$1"
}
if [ -f "$REG" ]; then
	reg_ok "$REG"; [ $? -eq 0 ] && ok "the RM registry header: EnableGpuFirmware 0 disabled, 1 enabled, 2 default policy (as the man page says)" || bad "the RM registry header disagrees with the man page"
	sed 's/MODE_DEFAULT           0x00000002/MODE_DEFAULT           0x00000003/' "$REG" > "$TMPD/reg.plant.h"
	if cmp -s "$REG" "$TMPD/reg.plant.h"; then bad "plant: the registry header plant changed nothing"
	else reg_ok "$TMPD/reg.plant.h"; [ $? -eq 1 ] && ok "plant: a different default mode value goes red" || bad "plant: registry value change not seen"; fi
	grep -q '^0 turns the GSP firmware off, 1 turns it on, 2 (the default)' "$MAN" && ok "the man page states those three values" || bad "the man page does not state the EnableGpuFirmware values"
else
	bad "no $REG (the pinned open source is needed)"
fi
attach_has_get() {
	awk '/^int nvidia_attach\(/ { inf = 1 } inf && /firmware_get/ { f = 1 } inf && /^}/ { inf = 0 } END { exit !f }' "$1"
}
attach_has_get "$SUBR"; [ $? -eq 1 ] && ok "nvidia_attach() does not call firmware_get()" || bad "nvidia_attach() calls firmware_get() (it would wait for the kldload lock)"
awk '{ print } /^int nvidia_attach\(/ { print "    (void)firmware_get(\"x\");" }' "$SUBR" > "$TMPD/attach.plant.c"
attach_has_get "$TMPD/attach.plant.c"; [ $? -eq 0 ] && ok "plant: firmware_get() added to nvidia_attach goes red" || bad "plant: firmware_get in attach not seen"

if mandoc -T lint "$MAN" > "$TMPD/lint.out" 2>&1 && [ ! -s "$TMPD/lint.out" ]; then ok "man/nvidia.4 is mandoc -T lint clean"; else bad "man/nvidia.4 does not lint clean"; sed 's/^/    /' "$TMPD/lint.out"; fi
for w in nvidia_gsp_ga10x_fw_fw nvidia_gsp_tu10x_fw_fw kldxref; do
	grep -q "$w" "$MAN" && ok "man/nvidia.4 names $w" || bad "man/nvidia.4 does not name $w"
done
for w in nvidia_gsp_ga10x_fw_fw kldxref; do
	grep -q "$w" "$repo/README.md" && ok "README names $w" || bad "README does not name $w"
done
# GA100 is a tu10x part: the man page and the README say so, and the driver's own table agrees
grep -q 'NV_FIRMWARE_CHIP_FAMILY_GA100:  // fall through' "$TREE/common/inc/nv-firmware.h" && ok "nv-firmware.h maps GA100 to the tu10x image (GSP table)" || bad "nv-firmware.h GA100 mapping changed"
awk '/GA100/ && /tu10x/ { f = 1 } END { exit !f }' "$MAN" && ok "man/nvidia.4 says GA100 uses the tu10x module" || bad "man/nvidia.4 does not say GA100 uses tu10x"
awk '/GA100/ && /tu10x/ { f = 1 } END { exit !f }' "$repo/README.md" && ok "README says GA100 uses the tu10x module" || bad "README does not say GA100 uses tu10x"
# DIAGNOSTICS: the linker line, the privilege line (with both modules) and the reload advice
awk '/^\.Sh DIAGNOSTICS/ { d = 1 } d' "$MAN" > "$TMPD/man.diag"
grep -q 'depends on nvidia_gsp_ga10x_fw_fw' "$TMPD/man.diag" && ok "DIAGNOSTICS documents the linker dependency line" || bad "DIAGNOSTICS lacks the linker dependency line"
grep -q 'nvidia_gsp_tu10x_fw' "$TMPD/man.diag" && ok "DIAGNOSTICS names the tu10x module too" || bad "DIAGNOSTICS does not name the tu10x module"
grep -q 'reboot' "$TMPD/man.diag" && ok "DIAGNOSTICS says a tunable change needs a reboot or a reload" || bad "DIAGNOSTICS does not say when a tunable change takes effect"
ROWS=$repo/tests/nvidia-fw-depend-testboot/ROWS.md
if [ -f "$ROWS" ]; then
	for r in R1 R2 R3 R4 R5 R6; do
		grep -q "^### $r " "$ROWS" && ok "test-boot row $r is specified" || bad "test-boot row $r is missing from ROWS.md"
	done
	grep -q 'depends on nvidia_gsp_ga10x_fw_fw - not available' "$ROWS" && ok "row R5 records the linker line" || bad "row R5 does not name the linker line"
else
	bad "tests/nvidia-fw-depend-testboot/ROWS.md is missing"
fi

echo "passed=$passed failed=$failed skipped=$skipped"
[ "$failed" -eq 0 ] || exit 1
[ "$skipped" -eq 0 ] || exit 2
exit 0

#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# open_dev_failure_test.sh - Track #2417: a failed GPU init must not panic
# the host.
#
# 2026-11-22 (the #2373 test boot): the first open of the GPU came from
# an unprivileged process, firmware_get(9) refused to load the GSP image,
# rm_init_adapter() failed, and nvidia_open_dev()'s failed: path called
# rm_disable_adapter().  RmDisableAdapter() dereferences pGpu, which
# RmInitAdapter's own cleanup had already cleared: a data abort at
# NULL+0x19f8 (GPU_GET_INTR(NULL)), a panic any local user could trigger.
#
# What this test proves:
#   (a) nvidia_open_dev() and nvidia_close_dev(), extracted from the
#       prepared nvidia_subr.c and compiled against stubs
#       (tests/data/open_dev_harness.c), never call rm_disable_adapter()
#       after a failed rm_init_adapter(), call rm_shutdown_adapter() once,
#       call neither RM function when the stack allocation failed (sp is
#       NULL), and still disable-then-shutdown on the last close;
#   (b) RmDisableAdapter() of the open RM core (osinit.c, MIT) returns
#       before ANY use of pGpu when pGpu is NULL (every repository ogkm
#       patch for osinit.c, in lexical order as scripts/build-rmcore.sh
#       applies them, on the pinned pristine file), and RmShutdownAdapter(),
#       the one RM call the failed path keeps, tests pGpu before its first
#       use; nvidia_open_dev has no jump to failed: after the init
#       succeeded (the label means "init never completed");
#   (c) the harness and the osinit check CAN fail: they run on NVIDIA's
#       pristine sources (today's code: must go red), and on plants of the
#       fixed code (the old call restored, the sp guard dropped, the
#       shutdown dropped, the stacks not freed, a post-init jump to
#       failed:, the osinit guard removed / late / after a non-GPU_GET_INTR
#       use / not returning, the RmShutdownAdapter test removed), each of
#       which must go red; a mutation that changes nothing is refused;
#   (d) a failed open followed by a good one on the same state leaves no
#       residue (case 5 of the harness).
#
# Usage: sh tests/open_dev_failure_test.sh
#   The tree under test is prepared here from the repository's own patches
#   (scripts/prepare-tree.sh) into a scratch tree under
#   ${GB10_WORK:-$HOME/work/gb10}/build and removed on exit; it needs the
#   pristine sources (scripts/fetch-sources.sh) and a C compiler.
# Exit: 0 every case passes, 1 otherwise.

set -u
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$repo/scripts/lib.sh"
WORK=${GB10_WORK:-$HOME/work/gb10}
ver=$(sources_get "$repo/SOURCES" ogkm_tag) || { echo "FAIL: no ogkm_tag in SOURCES"; exit 1; }
PRISTINE=$WORK/sources/NVIDIA-FreeBSD-x86_64-$ver/src
OGKM=$WORK/sources/open-gpu-kernel-modules-$ver
OSINIT=src/nvidia/arch/nvalloc/unix/src/osinit.c

mkdir -p "$WORK/tmp" || exit 1
TMPD=$(mktemp -d "$WORK/tmp/open-dev-failure-test.XXXXXXXX") || exit 1
# prepare-tree.sh wants its tree strictly under $WORK/build: a directory of
# our own there (mktemp), the tree one level below it; only that directory
# is ever removed.
mkdir -p "$WORK/build" || exit 1
TREEROOT=$(mktemp -d "$WORK/build/open-dev-test.XXXXXXXX") || exit 1
TREE=$TREEROOT/tree
trap 'rm -rf -- "$TMPD" "$TREEROOT"' EXIT
trap 'exit 130' INT TERM

passed=0
failed=0
ok() { echo "PASS: $1"; passed=$((passed + 1)); }
bad() { echo "FAIL: $1"; failed=$((failed + 1)); }

command -v mandoc >/dev/null 2>&1 || { echo "FAIL: mandoc is not installed (needed for the man page lint)"; exit 1; }
for f in "$PRISTINE/nvidia/nvidia_subr.c" "$PRISTINE/nvidia/nv-freebsd.h" \
    "$OGKM/$OSINIT" "$repo/tests/data/open_dev_harness.c"; do
	[ -f "$f" ] || { echo "FAIL: missing $f (run scripts/fetch-sources.sh, or set GB10_WORK)"; exit 1; }
done

# extract_fn <file> <regex of the first line> <out>: the function from its
# first line to the first line that is exactly "}".
extract_fn() {
	awk -v pat="$2" '
	!on && $0 ~ pat { on = 1 }
	on { print }
	on && $0 == "}" { exit }' "$1" > "$3"
	[ -s "$3" ]
}

# extract_macro <header> <out>: the NV_SHUTDOWN_ADAPTER definition (a
# multi-line #define, continued with backslashes).
extract_macro() {
	awk '
	!on && /^#define NV_SHUTDOWN_ADAPTER/ { on = 1 }
	on { print }
	on && $0 !~ /\\$/ { exit }' "$1" > "$2"
	[ -s "$2" ]
}

# harness <label> <subr.c> <nv-freebsd.h> [sed-expr]: build the harness
# around the two functions of <subr.c> (mutated by sed-expr when given,
# which must change the text) and run it. Output in $TMPD/<label>.out;
# returns the harness exit status (2 = could not build, 3 = mutation no-op).
harness() {
	_l=$1; _subr=$2; _hdr=$3; _sed=${4:-}
	_d=$TMPD/$_l
	mkdir -p "$_d"
	extract_fn "$_subr" '^int nvidia_open_dev[(]' "$_d/open.c" || return 2
	extract_fn "$_subr" '^void nvidia_close_dev[(]' "$_d/close.c" || return 2
	if [ -n "$_sed" ]; then
		sed -e "$_sed" "$_d/open.c" > "$_d/open.mut" || return 2
		if cmp -s "$_d/open.c" "$_d/open.mut"; then
			echo "mutation changed nothing: $_sed" > "$TMPD/$_l.out"
			return 3
		fi
		mv "$_d/open.mut" "$_d/open.c"
	fi
	cat "$_d/open.c" "$_d/close.c" > "$_d/fns.c"
	extract_macro "$_hdr" "$_d/macro.h" || return 2
	cc -std=gnu99 -Wall -Wno-unused-function -Wno-unused-variable \
	    -DOPEN_DEV_SRC="\"$_d/fns.c\"" -DOPEN_DEV_MACRO="\"$_d/macro.h\"" \
	    -o "$_d/h" "$repo/tests/data/open_dev_harness.c" > "$TMPD/$_l.cc" 2>&1 || {
		cp "$TMPD/$_l.cc" "$TMPD/$_l.out"
		return 2
	}
	"$_d/h" > "$TMPD/$_l.out" 2>&1
}

# expect_green / expect_red <label> <what> <harness args...>
expect_green() {
	_l=$1; _w=$2; shift 2
	harness "$_l" "$@"
	_rc=$?
	if [ "$_rc" -eq 0 ]; then ok "$_w"; else bad "$_w (rc=$_rc)"; sed 's/^/    /' "$TMPD/$_l.out"; fi
}
expect_red() {
	_l=$1; _w=$2; shift 2
	harness "$_l" "$@"
	_rc=$?
	if [ "$_rc" -eq 1 ]; then
		ok "$_w goes red: $(grep -c ': FAIL' "$TMPD/$_l.out") failing case line(s)"
	else
		bad "$_w did not go red (rc=$_rc)"
		sed 's/^/    /' "$TMPD/$_l.out"
	fi
}

# ---- the prepared tree: the repository's own patches on the pristine source
if ! GB10_WORK=$WORK sh "$repo/scripts/prepare-tree.sh" "$TREE" > "$TMPD/prepare.out" 2>&1; then
	bad "prepare-tree.sh failed"; sed 's/^/    /' "$TMPD/prepare.out"
	echo "passed=$passed failed=$failed"; exit 1
fi
SUBR=$TREE/nvidia/nvidia_subr.c
HDR=$TREE/nvidia/nv-freebsd.h

echo "== nvidia_open_dev on stubs (a, c)"
expect_red   pristine "NVIDIA's pristine nvidia_open_dev (today's code)" \
    "$PRISTINE/nvidia/nvidia_subr.c" "$PRISTINE/nvidia/nv-freebsd.h"
expect_green fixed    "the patched nvidia_open_dev" "$SUBR" "$HDR"
# the failed: path of the fixed text, mutated
expect_red   plant_old_call "plant: the old call (disable then shutdown) restored" \
    "$SUBR" "$HDR" '/^failed:/,/^}/ s/rm_shutdown_adapter(sp, nv);/NV_SHUTDOWN_ADAPTER(sp, nv);/'
expect_red   plant_no_sp_guard "plant: the sp == NULL guard dropped" \
    "$SUBR" "$HDR" '/^failed:/,/^}/ s/if (sp != NULL)/if (1)/'
expect_red   plant_no_free "plant: nv_dev_free_stacks dropped from the failed path (leaks the stacks, breaks the retry)" \
    "$SUBR" "$HDR" '/^failed:/,/^}/ s/nv_dev_free_stacks(sc);/(void)0;/'
expect_red   plant_no_shutdown "plant: rm_shutdown_adapter dropped" \
    "$SUBR" "$HDR" '/^failed:/,/^}/ s/rm_shutdown_adapter(sp, nv);/(void)0;/'
# the controls themselves: a harness that cannot see a NULL-gpu disable
# would pass the old call, so the pristine run above is the control; this
# one proves the mutation machinery refuses a no-op mutation.
harness noop "$SUBR" "$HDR" 's/zzz_no_such_text/x/'
if [ $? -eq 3 ]; then ok "a no-op mutation is refused, not run"; else bad "a no-op mutation was accepted"; fi

echo "== the open RM core (b, c)"
# osinit_fn <osinit.c> <function> <out>: the function body.
# osinit_check <osinit.c>: RmDisableAdapter returns on a NULL pGpu before
# ANY other use of the word pGpu (declaration and the guard line excepted;
# a guard whose body is a block must contain a return). Exit 0 = good.
osinit_check() {
	extract_fn "$1" '^void RmDisableAdapter[(]' "$TMPD/rda.c" || return 2
	awk '
	function use(l) { return l ~ /(^|[^A-Za-z0-9_])pGpu([^A-Za-z0-9_]|$)/ }
	{ line = $0; sub(/\/\/.*$/, "", line) }
	line ~ /^[ \t]*$/ { next }
	line ~ /^[ \t]*\*/ || line ~ /^[ \t]*\/\*/ { next }
	inblk { if (line ~ /return;/) ret = 1; if (line ~ /^[ \t]*}/) inblk = 0; next }
	waitret { waitret = 0; if (line ~ /^[ \t]*return;/) ret = 1; else if (line ~ /^[ \t]*{/) { inblk = 1; if (line ~ /return;/) ret = 1 } ; next }
	!guard && line ~ /^[ \t]*if \(pGpu == NULL\)/ { guard = NR; waitret = 1; next }
	line ~ /OBJGPU[ \t]*\*[ \t]*pGpu/ { next }
	use(line) && !guard { early = 1 }
	END { exit !(guard && ret && !early) }' "$TMPD/rda.c"
}
# osinit_shutdown_check <osinit.c>: the first use of pGpu in
# RmShutdownAdapter (after its declaration) is a pGpu != NULL test.
osinit_shutdown_check() {
	extract_fn "$1" '^void RmShutdownAdapter[(]' "$TMPD/rsa.c" || return 2
	awk '
	{ line = $0; sub(/\/\/.*$/, "", line) }
	line ~ /OBJGPU[ \t]*\*[ \t]*pGpu/ { next }
	!seen && line ~ /(^|[^A-Za-z0-9_])pGpu([^A-Za-z0-9_]|$)/ { seen = 1; ok = (line ~ /pGpu != NULL/) }
	END { exit !(seen && ok) }' "$TMPD/rsa.c"
}
# osinit_patched <out>: the pinned pristine osinit.c with every
# patches/ogkm patch that names it, in lexical order (as build-rmcore.sh).
osinit_patched() {
	_o=$TMPD/osinit-tree; rm -rf "$_o"; mkdir -p "$_o/$(dirname "$OSINIT")"
	cp "$OGKM/$OSINIT" "$_o/$OSINIT" || return 2
	_n=0
	for _p in "$repo"/patches/ogkm/patch-*; do
		grep -q '^+++ .*arch/nvalloc/unix/src/osinit\.c' "$_p" || continue
		patch -d "$_o" -p0 -E -s -i "$_p" || return 4
		_n=$((_n + 1))
	done
	[ "$_n" -ge 1 ] || return 3
	cp "$_o/$OSINIT" "$1"
}
# plant <in> <out> <awk program over the lines of one function>: every plant
# is confined to one function (the awk program sees only that function's
# lines through the variable fn) and must change the file.
plant() {
	awk -v fn="$3" '
	$0 ~ ("^void " fn "[(]") { inf = 1 }
	{ if (inf) { r = mut($0); if (r != "\001keep") { if (r != "\001drop") print r; if ($0 == "}") inf = 0; next } } print; if ($0 == "}") inf = 0 }
	'"$4" "$1" > "$2"
	! cmp -s "$1" "$2"
}
osinit_check "$OGKM/$OSINIT"
[ $? -eq 1 ] && ok "pristine RmDisableAdapter has no pGpu guard (goes red)" || bad "pristine RmDisableAdapter passed the guard check"
osinit_shutdown_check "$OGKM/$OSINIT" && ok "pristine RmShutdownAdapter tests pGpu before its first use (the failed path may call it)" || bad "RmShutdownAdapter uses pGpu before testing it"
if osinit_patched "$TMPD/osinit.patched.c"; then
	osinit_check "$TMPD/osinit.patched.c" && ok "patched RmDisableAdapter returns before any other use of pGpu" || bad "patched RmDisableAdapter lacks the early NULL guard"
	osinit_shutdown_check "$TMPD/osinit.patched.c" && ok "patched RmShutdownAdapter still tests pGpu first" || bad "patched RmShutdownAdapter changed"
	# plants on RmDisableAdapter (each confined to the function)
	P_DROP='function mut(l) { if (l ~ /^    if \(pGpu == NULL\)$/) { skip = 1; return "\001drop" } if (skip) { skip = 0; return "\001drop" } return "\001keep" }'
	P_LATE='function mut(l) { if (l ~ /^    if \(pGpu == NULL\)$/) { skip = 1; return "\001drop" } if (skip) { skip = 0; return "\001drop" } if (l ~ /Intr \*pIntr = GPU_GET_INTR\(pGpu\);/) return l "\n    if (pGpu == NULL)\n        return;"; return "\001keep" }'
	P_USE='function mut(l) { if (l ~ /^    if \(pGpu == NULL\)$/) return "    (void)IS_GSP_CLIENT(pGpu);\n" l; return "\001keep" }'
	P_NORET='function mut(l) { if (l ~ /^    if \(pGpu == NULL\)$/) { nr = 1; return "\001keep" } if (nr && l ~ /^        return;$/) { nr = 0; return "        (void)0;" } return "\001keep" }'
	P_NOSHUT='function mut(l) { if (l ~ /pGpu != NULL\) &&/) { sub(/\(pGpu != NULL\) && /, "", l); return l } return "\001keep" }'
	for _pl in "DROP:the osinit guard removed" "LATE:the osinit guard after the first GPU_GET_INTR use" \
	    "USE:a use of pGpu (IS_GSP_CLIENT) above the guard" "NORET:the guard that does not return"; do
		_k=${_pl%%:*}; _w=${_pl#*:}; eval "_prog=\$P_$_k"
		if plant "$TMPD/osinit.patched.c" "$TMPD/osinit.$_k.c" RmDisableAdapter "$_prog"; then
			osinit_check "$TMPD/osinit.$_k.c"; [ $? -eq 1 ] && ok "plant: $_w goes red" || bad "plant: $_w did not go red"
		else
			bad "plant: $_w changed nothing"
		fi
	done
	if plant "$TMPD/osinit.patched.c" "$TMPD/osinit.NOSHUT.c" RmShutdownAdapter "$P_NOSHUT"; then
		osinit_shutdown_check "$TMPD/osinit.NOSHUT.c"; [ $? -eq 1 ] && ok "plant: the pGpu != NULL test of RmShutdownAdapter removed goes red" || bad "plant: RmShutdownAdapter test removed did not go red"
	else
		bad "plant: RmShutdownAdapter mutation changed nothing"
	fi
else
	bad "could not apply the repository's osinit patches (rc=$?)"
fi

echo "== no jump to failed: after the init succeeded (the label means init never completed)"
post_init_jump() {
	# post_init_jump <subr.c>: exit 0 when a "goto failed" follows the line
	# that marks the init as done (NV_FLAG_OPEN).
	extract_fn "$1" '^int nvidia_open_dev[(]' "$TMPD/od.c" || return 2
	awk '/nv->flags \|= NV_FLAG_OPEN;/ { done = 1 } done && /goto failed;/ { bad = 1 } END { exit !bad }' "$TMPD/od.c"
}
post_init_jump "$SUBR"; [ $? -eq 1 ] && ok "no goto failed: after the init succeeded" || bad "a goto failed: follows the successful init"
awk '/^int nvidia_open_dev[(]/ { inf = 1 } { print } inf && /nv->flags \|= NV_FLAG_OPEN;/ { print "        goto failed;"; inf = 0 }' "$SUBR" > "$TMPD/subr.plant.c"
if cmp -s "$SUBR" "$TMPD/subr.plant.c"; then bad "plant: post-init jump changed nothing"
else post_init_jump "$TMPD/subr.plant.c"; [ $? -eq 0 ] && ok "plant: a goto failed: after the init succeeded goes red" || bad "plant: post-init jump not seen"; fi

echo "== docs (man/nvidia.4, README)"
# Only the cross-references to this repository's own pages may be reported
# (not installed where mandoc looks): nvidia_linux(4) and nvidia_drm_render(4).
# mandoc must exit 0, or exit non-zero having printed only those lines: a
# failed run that prints nothing does not pass.
mandoc -T lint "$repo/man/nvidia.4" > "$TMPD/lint.raw" 2>&1
_lrc=$?
grep -v -E 'STYLE: referenced manual not found: Xr (nvidia_linux|nvidia_drm_render) 4' "$TMPD/lint.raw" > "$TMPD/lint.out"
if [ ! -s "$TMPD/lint.out" ] && { [ "$_lrc" -eq 0 ] || [ -s "$TMPD/lint.raw" ]; }; then
	ok "man/nvidia.4 is mandoc -T lint clean"
else
	bad "man/nvidia.4 does not lint clean"; sed 's/^/    /' "$TMPD/lint.out"
fi
# The documents name the unit as nvidiaN because the unit number is never assumed (the card is not always unit 0).
DIAG='NVRM: rm_init_adapter() failed!'
MSG="nvidiaN: $DIAG"
grep -qF "$MSG" "$repo/man/nvidia.4" && grep -qF "$MSG" "$repo/README.md" \
    && ok "man page and README name the driver's diagnostic with the unit placeholder nvidiaN" || bad "the man page or the README does not name the diagnostic as nvidiaN: ..."
for _doc in man/nvidia.4 README.md; do
	grep -qE 'nvidia[0-9]+: NVRM: rm_init_adapter\(\) failed!' "$repo/$_doc"
	_grc=$?
	if [ "$_grc" -eq 0 ]; then
		bad "$_doc names the diagnostic with a concrete unit number"
	elif [ "$_grc" -eq 1 ]; then
		ok "$_doc does not name the diagnostic with a concrete unit number"
	else
		bad "could not read $_doc"
	fi
done
grep -qF "$DIAG" "$TREE/nvidia/nvidia_subr.c" && ok "the driver prints that diagnostic (device_printf adds the unit prefix)" || bad "the driver does not print the documented diagnostic"
grep -q 'nvidia_gsp_ga10x_fw' "$repo/man/nvidia.4" && grep -q 'EnableGpuFirmware' "$repo/man/nvidia.4" \
    && ok "man page gives the remedy (firmware module) and explains EnableGpuFirmware" || bad "man page lacks the firmware remedy"
if grep -n '0x19f8\|Track #' "$repo/man/nvidia.4" > "$TMPD/hist.out"; then bad "man page carries a fault address or a tracker number"; cat "$TMPD/hist.out"; else ok "man page has neither a fault address nor a tracker number"; fi

echo "passed=$passed failed=$failed"
[ "$failed" -eq 0 ]

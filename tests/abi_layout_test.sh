#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# abi_layout_test.sh - prove the FreeBSD OS layer's nv.h and the open RM
# core's nv.h agree on the memory layout of every struct/union typedef they
# share, on aarch64.
#
# The OS layer (build/tree, from scripts/prepare-tree.sh) and the open RM core
# (build/ogkm, from scripts/build-rmcore.sh) each compile against their own
# copy of nv.h, and both sides pass nv_state_t and the other nv.h structs
# across the link. This test:
#   1. extracts every struct/union typedef name (and its named direct members)
#      from BOTH nv.h copies with awk,
#   2. generates one C probe that prints sizeof, _Alignof and the offsetof of
#      every named member for each typedef present in both copies,
#   3. compiles the probe once per side with that side's include paths, runs
#      both and diffs the outputs (PASS when identical),
#   4. proves it can fail: recompiles the core side against a scratch copy of
#      the core nv.h with NV_MAX_DPAUX_NUM_DEVICES changed to 8 and asserts
#      the diff against the OS side is NON-empty.
#
# Typedef names present in only one copy (expected: some Tegra ones) are
# listed and do not fail the test - EXCEPT the fixed MUST_TYPES list of
# cross-boundary types the OS layer passes to the core, which is fatal when
# missing on either side. Pointer typedefs, aliases of incomplete
# structs, bit-fields and anonymous members cannot be compared by name and
# are listed as skipped.
#
# Environment:
#   GB10_WORK  work root holding build/tree and build/ogkm; defaults to
#              $HOME/work/gb10, the same root every other script and test
#              in this repo uses. TMPDIR is always $GB10_WORK/tmp - an
#              inherited TMPDIR is ignored.
#
# Exit codes:
#   0  layouts identical and the self-check detected the mutation
#   1  a layout difference was found, or the self-check failed (broken test)
#   2  a prerequisite tree/tool/host is missing
#
# Run: sh tests/abi_layout_test.sh   (foreground, on an aarch64 FreeBSD host)

set -u
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
export PATH
# The work root comes from GB10_WORK like every other script and test in
# this repo, so the trees checked here are the trees the scripts built
# (r14e-c pass-2 u11 #2: $HOME/work/gb10 was hard-coded and GB10_WORK was
# silently ignored).
ROOT=${GB10_WORK:-$HOME/work/gb10}
# TMPDIR is FORCED, never inherited: this test compiles probe binaries in
# it and EXECUTES them, and the project rule is that scratch never lives
# outside $ROOT/tmp - an inherited TMPDIR=/tmp would put executed code in
# a world-writable directory (r14e-c pass-2 u11 #1).
TMPDIR="$ROOT/tmp"
export TMPDIR

TREE="$ROOT/build/tree"
OGKM="$ROOT/build/ogkm"
OS_NV_H="$TREE/nvidia/nv.h"
CORE_NV_H="$OGKM/src/nvidia/arch/nvalloc/unix/include/nv.h"
CORE_CPUOPSYS="$OGKM/src/common/sdk/nvidia/inc/cpuopsys.h"

DEFS="-DNV_BSD -DNV_AARCH64 -DNV_ARCH_BITS=64 -D__KERNEL__ -DNVRM -DNV_KERNEL_INTERFACE_LAYER"
OS_INC="-I$TREE/nvidia -I$TREE/common/inc"
CORE_INC="-I$OGKM/src/nvidia/arch/nvalloc/unix/include -I$OGKM/src/nvidia/inc/kernel -I$OGKM/src/common/sdk/nvidia/inc -I$OGKM/src/common/inc -I$OGKM/src/nvidia/interface -I$OGKM/src/nvidia/arch/nvalloc/common/inc -I$OGKM/src/nvidia/kernel/inc"
CSTD="-std=gnu11"

die1() { echo "abi_layout_test: FAIL: $*" >&2; echo "abi_layout_test: artifacts kept in ${WORK:-<none>}" >&2; exit 1; }
die2() { echo "abi_layout_test: $*" >&2; exit 2; }

# --- prerequisites -------------------------------------------------------
[ -f "$OS_NV_H" ]       || die2 "missing $OS_NV_H - run scripts/prepare-tree.sh first"
[ -f "$CORE_NV_H" ]     || die2 "missing $CORE_NV_H - run scripts/build-rmcore.sh first"
[ -f "$CORE_CPUOPSYS" ] || die2 "missing $CORE_CPUOPSYS - run scripts/build-rmcore.sh first"
command -v cc  >/dev/null 2>&1 || die2 "cc not found on PATH ($PATH)"
command -v awk >/dev/null 2>&1 || die2 "awk not found on PATH ($PATH)"
ARCH="$(uname -m)"
case "$ARCH" in
arm64|aarch64) ;;
*) die2 "this test proves the aarch64 ABI; host is '$ARCH' - run it on an aarch64 host" ;;
esac

mkdir -p "$TMPDIR" || die2 "cannot create TMPDIR $TMPDIR"
WORK="$(mktemp -d "$TMPDIR/abi_layout_test.XXXXXX")" || die2 "mktemp -d failed under $TMPDIR"
KEEP=1
# cleanup - on the EXIT path remove this run's scratch dir unless artifacts
# are being kept for inspection (KEEP=1; cleared only on the PASS path).
# HUP/QUIT/INT/TERM exit with 128+signo (129/131/130/143) and let the EXIT
# trap do the cleanup, instead of a combined trap that cleans up and
# RETURNS (which would let the script carry on after a signal).
# Time:  O(files under $WORK), once per run.
# Space: O(1).
cleanup() {
	if [ "$KEEP" = 0 ]; then
		rm -rf -- "$WORK"
	fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 131' QUIT
trap 'exit 130' INT
trap 'exit 143' TERM

# --- awk extractor -------------------------------------------------------
# Emits records for one nv.h copy:
#   T <type>              a complete struct/union typedef name
#   M <type> <member>     a named direct member of <type>, in file order
#   S <category> <text>   parsed but not comparable (reported, never fatal)
cat > "$WORK/extract.awk" <<'AWKEOF'
function ltrim(s) { sub(/^[ \t]+/, "", s); return s }
function rtrim(s) { sub(/[ \t]+$/, "", s); return s }
function trim(s)  { return ltrim(rtrim(s)) }
function squash(s) { gsub(/[ \t]+/, " ", s); return trim(s) }

# strip_comments: remove /*...*/ (carrying in_comment across lines) and
# //... from one source line.
# Time:  O(n) in the line length n - every index() scan discards what it matched.
# Space: O(n) for the returned string.
function strip_comments(line,   out, p, pb, ps) {
    out = ""
    while (length(line) > 0) {
        if (in_comment) {
            p = index(line, "*/")
            if (p == 0) return out
            line = substr(line, p + 2)
            in_comment = 0
            continue
        }
        pb = index(line, "/*")
        ps = index(line, "//")
        if (pb == 0 && ps == 0) return out line
        if (ps != 0 && (pb == 0 || ps < pb)) return out substr(line, 1, ps - 1)
        out = out substr(line, 1, pb - 1)
        line = substr(line, pb + 2)
        in_comment = 1
    }
    return out
}

# strip_attrs: remove every __attribute__((...)) from s with balanced-paren
# scanning (the contents may themselves contain parentheses).
# Time:  O(a * n) for a attribute occurrences in a string of length n
#        (each removal rescans the shortened string once).
# Space: O(n) for the intermediate copies.
function strip_attrs(s,   i, j, d, c) {
    while ((i = index(s, "__attribute__")) > 0) {
        j = i + 13
        while (j <= length(s) && substr(s, j, 1) != "(") j++
        if (j > length(s)) return substr(s, 1, i - 1)
        d = 0
        while (j <= length(s)) {
            c = substr(s, j, 1)
            if (c == "(") d++
            else if (c == ")") { d--; if (d == 0) break }
            j++
        }
        s = substr(s, 1, i - 1) substr(s, j + 1)
    }
    return s
}

function add_member(nm) {
    if (nm == "" || (nm in keyword)) return
    nmembers++
    members[nmembers] = nm
}

# process_member: turn one declaration collected between ';' at body depth 1
# into zero or more member names. Handles comma-separated declarators
# ("nv_aperture_t *fb, ud;"), arrays, pointers, __attribute__, named nested
# anonymous struct/union tails ("struct { ... } rmapi;") and function
# pointers. Skips (and reports) bit-fields and anonymous members.
# Time:  O(n + k * m) - linear strip passes over the n-char declaration, then
#        k comma parts with an O(m) last-identifier match each.
# Space: O(n) for the stripped copy; members[] grows by one slot per member.
function process_member(d,   nd, np, i, part, nm) {
    d = trim(d)
    if (d == "") return
    nd = strip_attrs(d)
    if (index(nd, ":") > 0) { printf "S bitfield %s\n", squash(nd); return }
    if (index(nd, "(") > 0) {
        if (match(nd, /\(\*[ \t]*[A-Za-z_][A-Za-z0-9_]*/)) {
            nm = substr(nd, RSTART, RLENGTH)
            sub(/^\(\*[ \t]*/, "", nm)
            add_member(nm)
        } else printf "S fnptr-noname %s\n", squash(nd)
        return
    }
    gsub(/\[[^]]*\]/, "", nd)
    nd = trim(nd)
    if (nd == "") { printf "S anonymous-member %s\n", squash(d); return }
    np = split(nd, parts, ",")
    for (i = 1; i <= np; i++) {
        part = parts[i]
        gsub(/\*/, "", part)
        part = trim(part)
        if (part == "") continue
        if (match(part, /[A-Za-z_][A-Za-z0-9_]*$/)) {
            nm = substr(part, RSTART, RLENGTH)
            if (nm in keyword) printf "S anonymous-member %s\n", squash(d)
            else add_member(nm)
        } else printf "S anonymous-member %s\n", squash(d)
    }
}

function emit_type(name,   i) {
    printf "T %s\n", name
    for (i = 1; i <= nmembers; i++) printf "M %s %s\n", name, members[i]
}

function store_tag(tag,   i) {
    if (tag == "") return
    tagdef[tag] = 1
    ntagmem[tag] = nmembers
    for (i = 1; i <= nmembers; i++) tagmem[tag, i] = members[i]
}

# finish_def: the definition's closing '} ... ;' tail was collected; parse the
# typedef name list (which may mix value names and pointer names) or, for a
# bare struct definition, just remember the tag's members for alias resolution.
# Time:  O(k * m) for k comma-separated names of m chars each.
# Space: O(k) for the split parts array.
function finish_def(tailtext,   n, i, part, nm) {
    gsub(/[ \t]+/, " ", tailtext)
    if (is_tdef) {
        n = split(tailtext, parts, ",")
        for (i = 1; i <= n; i++) {
            part = trim(parts[i])
            if (part == "") continue
            if (substr(part, 1, 1) == "*") {
                nm = trim(substr(part, 2))
                sub(/\[.*$/, "", nm)
                if (nm != "") printf "S pointer-typedef %s\n", nm
                continue
            }
            sub(/\[.*$/, "", part)
            if (part ~ /^[A-Za-z_][A-Za-z0-9_]*$/) emit_type(part)
            else printf "S unparseable-name %s\n", squash(part)
        }
    }
    store_tag(body_tag)
}

# add_alias: record a brace-less "typedef struct TAG NAME[, *PNAME]...;" for
# resolution in END (the tag may be defined later in the file).
# Time:  O(k * m) for k declarator names.
# Space: O(k) alias slots.
function add_alias(text,   nt, tag, rest, n, i, part) {
    sub(/;.*/, "", text)
    text = trim(text)
    if (text == "") return
    nt = split(text, toks, /[ \t]+/)
    tag = toks[1]
    rest = trim(substr(text, length(tag) + 1))
    n = split(rest, parts, ",")
    for (i = 1; i <= n; i++) {
        part = trim(parts[i])
        if (part == "") continue
        if (substr(part, 1, 1) == "*") {
            part = trim(substr(part, 2))
            if (part != "") printf "S pointer-typedef %s\n", part
            continue
        }
        if (part ~ /^[A-Za-z_][A-Za-z0-9_]*$/) { nalias++; alias_tag[nalias] = tag; alias_name[nalias] = part }
        else printf "S unparseable-name %s\n", squash(part)
    }
}

# start_body: a definition body opens; reset per-definition state and scan the
# opening line.
# Time/Space: O(1) plus scan_body's cost for the first line.
function start_body(tag, tdef, text) {
    body_tag = tag
    is_tdef = tdef
    depth = 0
    decl = ""
    tail = ""
    nmembers = 0
    delete members
    mode = "body"
    scan_body(text)
}

# scan_body: character walk of one comment-free line inside a definition.
# depth 0: text before the opening '{' (tag), ignored. depth 1: declaration
# text accumulated into decl, cut at ';'. depth >= 2: nested anonymous
# struct/union body, ignored (only its closing name rejoins decl). After the
# final '}' the tail is collected until ';'.
# Time:  O(n) - one pass over the n chars of the line, O(1) work per char.
# Space: O(n) appended to decl/tail.
function scan_body(text,   i, n, c, rest) {
    n = length(text)
    for (i = 1; i <= n; i++) {
        c = substr(text, i, 1)
        if (mode == "tail") {
            if (c == ";") {
                finish_def(tail)
                tail = ""
                mode = "top"
                rest = substr(text, i + 1)
                if (trim(rest) != "") handle_top(rest)
                return
            }
            tail = tail c
            continue
        }
        if (c == "{") { depth++; continue }
        if (c == "}") {
            depth--
            if (depth == 0) { mode = "tail"; tail = "" }
            continue
        }
        if (depth == 1) {
            if (c == ";") { process_member(decl); decl = ""; continue }
            decl = decl c
        }
    }
}

# handle_decl_start: classify what follows "typedef struct|union" (or a bare
# "struct|union tag"): an opening brace on this line, a brace-less alias
# ending in ';', or a body that opens on a later line (pend).
# Time:  O(m) in the length m of the remainder (index/trim/split-free).
# Space: O(1) besides the pending-state variables.
function handle_decl_start(rest, tdef,   tag) {
    if (index(rest, "{") > 0) {
        tag = trim(substr(rest, 1, index(rest, "{") - 1))
        start_body(tag, tdef, rest)
    } else if (index(rest, ";") > 0) {
        if (tdef) add_alias(rest)
    } else {
        mode = "pend"
        pend_tag = trim(rest)
        is_tdef = tdef
    }
}

function handle_top(line,   t, rest) {
    t = trim(line)
    if (t ~ /^typedef[ \t]+(struct|union)([^A-Za-z0-9_]|$)/) {
        rest = t
        sub(/^typedef[ \t]+(struct|union)[ \t]*/, "", rest)
        handle_decl_start(rest, 1)
        return
    }
    if (t ~ /^(struct|union)[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]*\{?[ \t]*$/) {
        rest = t
        sub(/^(struct|union)[ \t]+/, "", rest)
        handle_decl_start(rest, 0)
    }
}

function handle_pend(line,   t, bi, tag) {
    t = trim(line)
    if (t == "") return
    bi = index(t, "{")
    if (bi > 0) {
        # The body may open as "TAG {" with the tag on THIS line (the
        # "typedef struct" keyword line carried no tag): take the tag from
        # the text before the '{', falling back to the tag already seen.
        tag = trim(substr(t, 1, bi - 1))
        if (tag == "") tag = pend_tag
        start_body(tag, is_tdef, t)
        return
    }
    if (is_tdef && index(t, ";") > 0) { add_alias(pend_tag " " t); mode = "top"; return }
    mode = "top"
    handle_top(line)
}

BEGIN {
    in_comment = 0
    in_define = 0
    mode = "top"
    depth = 0
    is_tdef = 0
    pend_tag = ""
    body_tag = ""
    decl = ""
    tail = ""
    nmembers = 0
    nalias = 0
    split("struct union enum const volatile unsigned signed char int short long float double void _Bool register static extern inline", kwarr, " ")
    for (ki in kwarr) keyword[kwarr[ki]] = 1
}

{
    line = strip_comments($0)
    t0 = trim(line)
    # skip #define bodies: their continuation lines are not declarations
    if (in_define) {
        if (t0 == "" || substr(t0, length(t0), 1) != "\\") in_define = 0
        next
    }
    if (substr(t0, 1, 1) == "#") {
        if (substr(t0, length(t0), 1) == "\\") in_define = 1
        if (mode == "top" || mode == "pend") next
        printf "S preproc-in-body %s\n", squash(t0)
        next
    }
    if (mode == "top") { handle_top(line); next }
    if (mode == "pend") { handle_pend(line); next }
    scan_body(line)
}

END {
    for (a = 1; a <= nalias; a++) {
        tag = alias_tag[a]
        nm = alias_name[a]
        if (tag in tagdef) {
            printf "T %s\n", nm
            for (i = 1; i <= ntagmem[tag]; i++) printf "M %s %s\n", nm, tagmem[tag, i]
        } else {
            printf "S incomplete-alias %s (struct %s has no definition in this header)\n", nm, tag
        }
    }
}
AWKEOF

# --- extractor self-test ----------------------------------------------------
# The two-line shape "typedef struct" followed by "TAG {" on the NEXT line must
# be extracted (handle_pend takes the tag from the text before the '{'). If
# this fixture stops producing records, the extractor silently drops types from
# the real nv.h copies and the whole comparison below compares nothing, so a
# fixture failure is fatal.
cat > "$WORK/fixture.h" <<'FIXEOF'
/* fixture: tag sits on the line after "typedef struct", brace after the tag */
typedef struct
fixt_tag_t {
    int fixt_a;
    char fixt_b[4];
} fixt_type_t;
FIXEOF
awk -f "$WORK/extract.awk" "$WORK/fixture.h" > "$WORK/fixture.rec" ||
    die1 "extractor self-test: awk failed on the fixture"
grep -qx 'T fixt_type_t' "$WORK/fixture.rec" ||
    die1 "extractor self-test FAILED: 'typedef struct' + 'TAG {' on the next line was not extracted (no 'T fixt_type_t' record)"
grep -qx 'M fixt_type_t fixt_a' "$WORK/fixture.rec" ||
    die1 "extractor self-test FAILED: member fixt_a of fixt_type_t not extracted"
grep -qx 'M fixt_type_t fixt_b' "$WORK/fixture.rec" ||
    die1 "extractor self-test FAILED: member fixt_b of fixt_type_t not extracted"
echo "abi_layout_test: extractor self-test: two-line 'typedef struct' + 'TAG {' shape extracted"

# extract_nv: run the awk extractor over one nv.h copy.
# Time:  O(L) - a single awk pass over the L lines of the header (each line is
#        scanned a constant number of times; see the per-function notes above).
# Space: O(T + M) records for T typedefs and M members, written to $2.
extract_nv() {
    awk -f "$WORK/extract.awk" "$1" > "$2" || die1 "awk extractor failed on $1"
}

extract_nv "$OS_NV_H"   "$WORK/os.rec"
extract_nv "$CORE_NV_H" "$WORK/core.rec"

grep '^T ' "$WORK/os.rec"   | cut -d' ' -f2 | LC_ALL=C sort -u > "$WORK/os.types"
grep '^T ' "$WORK/core.rec" | cut -d' ' -f2 | LC_ALL=C sort -u > "$WORK/core.types"
LC_ALL=C comm -12 "$WORK/os.types"   "$WORK/core.types" > "$WORK/common.types"
LC_ALL=C comm -23 "$WORK/os.types"   "$WORK/core.types" > "$WORK/only_os.types"
LC_ALL=C comm -13 "$WORK/os.types"   "$WORK/core.types" > "$WORK/only_core.types"

# --- MUST types --------------------------------------------------------------
# The cross-boundary struct/union typedefs the FreeBSD OS layer passes to the
# open RM core, chosen from the rm_* prototypes in nv.h and the OS-layer
# nvidia_*.c call sites: every rm_* entry point the OS layer calls
# (rm_init_rm, rm_ioctl, rm_isr, rm_init_adapter, ...) takes nvidia_stack_t *
# and all but a handful take nv_state_t *, so those two struct typedefs are
# the MUST list. One-sided types in general are only listed (some Tegra ones
# are expected on one side alone), so this fixed list closes that hole for
# the types the link actually depends on: a MUST type missing on either side
# is fatal, never a silent skip of the layout comparison.
# Considered and excluded, with reasons:
#   - nv_ioctl_* (nv_ioctl_xfer_t, nv_ioctl_numa_info_t, ...) and nv_alloc_t:
#     not defined in nv.h at all (nv-ioctl*.h / OS headers), and this test
#     parses nv.h only;
#   - nv_file_private_t (rm_ioctl): only forward-declared in both nv.h
#     copies, so it has no comparable layout record;
#   - nv_i2c_cmd_t (rm_i2c_transfer), nv_pm_action_t (rm_power_management):
#     enum typedefs - this test proves struct/union layout, and enums cross
#     the boundary as plain ints;
#   - nv_power_info_t: a struct in both nv.h copies, but rm_get_power_info
#     has no OS-layer call site, so it does not cross the boundary;
#   - nv_parm_t: OS-layer-internal (nvidia_os_registry.c, nvidia_sysctl.c).
MUST_TYPES="nvidia_stack_t nv_state_t"

# check_must_types <os.types> <core.types>: return 1 (with a message per
# miss) when any MUST type is absent from either sorted type list.
# Time:  O(k * T) - k MUST types, one grep per type per side over T lines.
# Space: O(1).
check_must_types() {
    _must_os=$1
    _must_core=$2
    _must_bad=0
    for _mt in $MUST_TYPES; do
        grep -qx -- "$_mt" "$_must_os" || {
            echo "abi_layout_test: MUST type $_mt missing from the OS-side nv.h" >&2
            _must_bad=1
        }
        grep -qx -- "$_mt" "$_must_core" || {
            echo "abi_layout_test: MUST type $_mt missing from the core-side nv.h" >&2
            _must_bad=1
        }
    done
    return "$_must_bad"
}

check_must_types "$WORK/os.types" "$WORK/core.types" ||
    die1 "a MUST cross-boundary type is missing on one side (listed above) - the layout comparison would silently skip it"
echo "abi_layout_test: MUST cross-boundary types present on both sides: $MUST_TYPES"

# Falsifiability fixture: removing a MUST type from a scratch copy of the
# core-side list must fail the check. If this fixture ever stops failing, the
# MUST check above is decoration.
grep -vx -- nv_state_t "$WORK/core.types" > "$WORK/core.types.mut"
if check_must_types "$WORK/os.types" "$WORK/core.types.mut" 2>/dev/null; then
    die1 "MUST-check self-test FAILED: nv_state_t removed from the core-side list did not fail check_must_types"
fi
echo "abi_layout_test: MUST-check self-test: removing nv_state_t from one side fails the check"

NTYPES_OS="$(awk 'END{print NR}' "$WORK/os.types")"
NTYPES_CORE="$(awk 'END{print NR}' "$WORK/core.types")"
NTYPES="$(awk 'END{print NR}' "$WORK/common.types")"
[ "$NTYPES" -gt 0 ] || die1 "no common struct/union typedefs found - is the extractor broken?"

echo "abi_layout_test: host arch: $ARCH"
echo "abi_layout_test: OS-side nv.h:   $OS_NV_H"
echo "abi_layout_test: core-side nv.h: $CORE_NV_H"
echo "abi_layout_test: struct/union typedefs found: OS=$NTYPES_OS core=$NTYPES_CORE common=$NTYPES"
echo "abi_layout_test: common types compared:"
sed 's/^/  /' "$WORK/common.types"
if [ -s "$WORK/only_os.types" ]; then
    echo "abi_layout_test: only in OS nv.h (listed, not compared, not fatal):"
    sed 's/^/  /' "$WORK/only_os.types"
else
    echo "abi_layout_test: only in OS nv.h: (none)"
fi
if [ -s "$WORK/only_core.types" ]; then
    echo "abi_layout_test: only in core nv.h (listed, not compared, not fatal):"
    sed 's/^/  /' "$WORK/only_core.types"
else
    echo "abi_layout_test: only in core nv.h: (none)"
fi
echo "abi_layout_test: parsed but not comparable (skipped, listed):"
cat "$WORK/os.rec" "$WORK/core.rec" | grep '^S ' | LC_ALL=C sort -u | sed 's/^S /  /'

# members_of: the named members of one type from one record file, in file order.
# Time:  O(R) - one grep over the R records of the file.
# Space: O(m) for the m member lines written.
members_of() {
    grep "^M $1 " "$2" | cut -d' ' -f3
}

# --- generate the probe ---------------------------------------------------
# gen_probe: write one C file printing sizeof/alignof per common type and
# offsetof per named member. The member list of each type must be identical in
# both headers (a differing member list is itself an ABI difference -> fail).
# Time:  O(T * (R + m)) - per common type T, two greps over the R-record files
#        and one pass over its m members.
# Space: O(T * m) lines of generated C.
gen_probe() {
    {
        echo '/* Copyright (c) 2026 REVYTECH, Inc. */'
        echo '/* SPDX-License-Identifier: BSD-3-Clause */'
        echo '/* Generated by tests/abi_layout_test.sh - do not edit. */'
        echo '#include <stdio.h>'
        echo '#include <stddef.h>'
        echo '#include <nv.h>'
        echo ''
        echo 'int main(void)'
        echo '{'
    } > "$WORK/abi_probe.c"
    NMEMBERS=0
    while read -r t; do
        members_of "$t" "$WORK/os.rec"   > "$WORK/m_os"
        members_of "$t" "$WORK/core.rec" > "$WORK/m_core"
        if ! cmp -s "$WORK/m_os" "$WORK/m_core"; then
            echo "abi_layout_test: member list of '$t' differs between the two nv.h copies:" >&2
            diff -u "$WORK/m_os" "$WORK/m_core" >&2
            die1 "member lists differ for $t (an ABI difference in itself)"
        fi
        echo "	printf(\"T $t sizeof %zu alignof %zu\\n\", sizeof($t), (size_t)_Alignof($t));" >> "$WORK/abi_probe.c"
        while read -r m; do
            [ -n "$m" ] || continue
            echo "	printf(\"M $t.$m %zu\\n\", (size_t)offsetof($t, $m));" >> "$WORK/abi_probe.c"
            NMEMBERS=$((NMEMBERS + 1))
        done < "$WORK/m_os"
    done < "$WORK/common.types"
    {
        echo '	return (0);'
        echo '}'
    } >> "$WORK/abi_probe.c"
}
gen_probe

# --- compile both sides ---------------------------------------------------
# shellcheck disable=SC2086
cc $CSTD $DEFS $OS_INC -o "$WORK/probe_os" "$WORK/abi_probe.c" 2> "$WORK/cc_os.log" || {
    sed 's/^/  /' "$WORK/cc_os.log" >&2
    die1 "OS-side probe failed to compile"
}
# shellcheck disable=SC2086
cc $CSTD $DEFS -include "$CORE_CPUOPSYS" $CORE_INC -o "$WORK/probe_core" "$WORK/abi_probe.c" 2> "$WORK/cc_core.log" || {
    sed 's/^/  /' "$WORK/cc_core.log" >&2
    die1 "core-side probe failed to compile"
}

"$WORK/probe_os"   > "$WORK/os.out"   || die1 "OS-side probe failed at runtime"
"$WORK/probe_core" > "$WORK/core.out" || die1 "core-side probe failed at runtime"

if ! cmp -s "$WORK/os.out" "$WORK/core.out"; then
    echo "abi_layout_test: layout differences (OS vs core):" >&2
    diff -u "$WORK/os.out" "$WORK/core.out" >&2
    die1 "nv.h struct layouts differ between the OS layer and the open RM core"
fi
echo "abi_layout_test: compared $NTYPES types and $NMEMBERS members: OS-side and core-side outputs identical"

# --- self-check: prove the test can fail ----------------------------------
# NV_MAX_DPAUX_NUM_DEVICES is #defined unconditionally inside nv.h, so a -D
# override would be discarded; mutate a scratch copy of the core nv.h instead
# and put its directory first on the core include path.
mkdir -p "$WORK/scratch" || die1 "cannot create scratch dir"
sed -E 's/^#define[[:space:]]+NV_MAX_DPAUX_NUM_DEVICES[[:space:]]+[0-9]+/#define NV_MAX_DPAUX_NUM_DEVICES 8/' \
    "$CORE_NV_H" > "$WORK/scratch/nv.h" || die1 "cannot write scratch nv.h"
grep -q '^#define NV_MAX_DPAUX_NUM_DEVICES 8$' "$WORK/scratch/nv.h" ||
    die1 "self-check fixture broken: NV_MAX_DPAUX_NUM_DEVICES not rewritten in the scratch core nv.h"
# shellcheck disable=SC2086
cc $CSTD $DEFS -include "$CORE_CPUOPSYS" -I"$WORK/scratch" $CORE_INC -o "$WORK/probe_core_mut" "$WORK/abi_probe.c" 2> "$WORK/cc_core_mut.log" || {
    sed 's/^/  /' "$WORK/cc_core_mut.log" >&2
    die1 "self-check probe failed to compile"
}
"$WORK/probe_core_mut" > "$WORK/core_mut.out" || die1 "self-check probe failed at runtime"
# cmp(1) exits 0 (same), 1 (different) or >1 (could not compare - a missing
# or unreadable file). Treat only rc 1 as "different"; an rc > 1 means the
# self-check itself is broken and must die, not pass as "mutation detected".
sc_rc=0
cmp -s "$WORK/os.out" "$WORK/core_mut.out" || sc_rc=$?
if [ "$sc_rc" -gt 1 ]; then
    die1 "self-check cmp failed (rc=$sc_rc) comparing $WORK/os.out and $WORK/core_mut.out - cannot tell 'different' from 'broken'"
fi
if [ "$sc_rc" -eq 0 ]; then
    die1 "SELF-CHECK FAILED: growing dpaux[]/dpaux_irqs[] (NV_MAX_DPAUX_NUM_DEVICES -> 8) changed nothing - this test cannot detect a layout change"
fi
NDIFF="$(diff "$WORK/os.out" "$WORK/core_mut.out" | grep -c '^[<>]')"
echo "abi_layout_test: self-check: mutated core nv.h (NV_MAX_DPAUX_NUM_DEVICES -> 8) changed $NDIFF output line(s) - layout changes are detected"

KEEP=0
echo "abi_layout_test: PASS"
exit 0

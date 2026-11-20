#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# render_uapi_docs_test.sh - the render uAPI documents agree with the header
# (Track #2314).  Checks:
#   1. man/nvidia_drm_render.4 is clean under `mandoc -T lint`;
#   2. every DRM_IOCTL_NVR_* in the header appears in the man page, and the
#      man page names no ioctl the header lacks;
#   3. docs/RENDER-UAPI.md's ioctl table has, per ioctl, the command number,
#      the encoded request and the struct size the compiled header gives;
#   4. every NVR_PARAM_* of the header has its row `| `NAME` (value) |` in the
#      document's parameter table with the header's value, every NVR_INFO_FLAG_*
#      has its flag row, and every define of the header's Limits block (the
#      *_MIN minimums and the fixed values) has its "docs:" row in section 8
#      with the same value, matched as a whole cell;
#   5. every "section N" reference in the document has a heading N; the ioctl
#      range the document offers for new ioctls starts above the highest used
#      number; every markdown table row has its header's cell count; the man
#      page's CPU MAPPINGS warns about memcpy, its EBUSY names VM_INIT and its
#      GETINFO entry gives the counting-call rule;
#   6. the test can fail: a man page without an ioctl or without the memcpy
#      warning, a document with a wrong struct size, without a parameter row,
#      with a wrong or too long minimum (256 -> 2560), a wrong kernel range, a
#      dangling section reference, a renamed section 9, an offered used ioctl
#      number or an unescaped pipe are each refused, for the stated reason.
# Environment: scratch goes to TMPDIR (default $REPO/tmp); no $HOME paths are used.
# Exit: 0 pass, 1 fail (including a header the probe rejects), 2 a tool is missing.   Run: sh tests/render_uapi_docs_test.sh

set -u
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL
TESTSDIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH= cd -- "$TESTSDIR/.." && pwd)
TMPDIR=${TMPDIR:-$REPO/tmp}; export TMPDIR
H_DIR=$REPO/src/nvidia-drm-render
H=$H_DIR/nvidia-drm-render.h
MAN=$REPO/man/nvidia_drm_render.4
DOC=$REPO/docs/RENDER-UAPI.md
for f in "$H" "$MAN" "$DOC"; do [ -f "$f" ] || { echo "missing $f" >&2; exit 2; }; done
command -v mandoc >/dev/null 2>&1 || { echo "mandoc not found" >&2; exit 2; }
command -v cc >/dev/null 2>&1 || { echo "cc not found" >&2; exit 2; }
mkdir -p "$TMPDIR" && W=$(mktemp -d "$TMPDIR/render_docs.XXXXXX") || exit 2
trap 'rm -rf "$W"' EXIT INT TERM
FAILS=0
fail() { echo "FAIL: $*"; FAILS=$((FAILS + 1)); }
pass() { echo "PASS: $*"; }

cc -std=c11 -I"$REPO/src/nvidia-drm-render" "$TESTSDIR/render_uapi_layout.c" -o "$W/probe" 2>"$W/cc.err" \
    || { cat "$W/cc.err"; echo "render_uapi_docs_test: FAIL: the layout probe does not compile (the header is broken)" >&2; exit 1; }
"$W/probe" >"$W/probe.out" || { cat "$W/probe.out"; echo "render_uapi_docs_test: FAIL: the layout probe failed" >&2; exit 1; }
grep '^DRM_IOCTL_NVR_' "$W/probe.out" >"$W/table.txt"
_n_hdr=$(sed -n 's/^#define[[:space:]]*\(DRM_IOCTL_NVR_[A-Z_]*\).*/\1/p' "$H" | wc -l | tr -d ' ')
[ "$(wc -l <"$W/table.txt" | tr -d ' ')" -eq "$_n_hdr" ] && [ "$_n_hdr" -gt 0 ] \
    || { echo "render_uapi_docs_test: FAIL: probe table has $(wc -l <"$W/table.txt") rows, header $_n_hdr ioctls" >&2; exit 1; }

# check_docs MAN DOC: prints problems, returns non-zero on any
check_docs() {
	_man=$1; _doc=$2; _rc=0
	mandoc -T lint "$_man" >"$W/lint.txt" 2>&1 || { cat "$W/lint.txt"; echo "man page not lint clean"; _rc=1; }
	[ -s "$W/lint.txt" ] && { cat "$W/lint.txt"; echo "man page lint output"; _rc=1; }
	sed -n 's/^#define[[:space:]]*\(DRM_IOCTL_NVR_[A-Z_]*\).*/\1/p' "$H" | sort >"$W/h_ioctls.txt"
	grep -o 'DRM_IOCTL_NVR_[A-Z_]*' "$_man" | sort -u >"$W/m_ioctls.txt"
	cmp -s "$W/h_ioctls.txt" "$W/m_ioctls.txt" || { echo "man ioctl list differs from header:"; diff "$W/h_ioctls.txt" "$W/m_ioctls.txt"; _rc=1; }
	while read -r name _ nr _ cmd _ _ size; do
		short=${name#DRM_IOCTL_NVR_}
		grep -q "^| $short | $nr | $cmd | .* | $size |\$" "$_doc" \
		    || { echo "doc table row for $short (nr $nr cmd $cmd size $size) missing or wrong"; _rc=1; }
		grep -q "Dv $name Pq $nr, " "$_man" || { echo "man page entry for $name with $nr missing"; _rc=1; }
	done <"$W/table.txt"
	sed -n 's/^#define[[:space:]]*NVR_PARAM_\([A-Z_0-9]*\)[[:space:]][[:space:]]*\([0-9][0-9]*\)\([[:space:]].*\)\{0,1\}$/\1 \2/p' "$H" >"$W/params.txt"
	[ -s "$W/params.txt" ] || { echo "no NVR_PARAM_* found in the header"; _rc=1; }
	while read -r pn pv; do
		grep -q "^| \`$pn\` ($pv) |" "$_doc" || { echo "parameter row for NVR_PARAM_$pn ($pv) missing or wrong in the document"; _rc=1; }
	done <"$W/params.txt"
	for fl in $(sed -n 's/^#define[[:space:]]*NVR_INFO_FLAG_\([A-Z_]*\).*/\1/p' "$H"); do
		grep -q "^| \`$fl\` |" "$_doc" || { echo "flag row for NVR_INFO_FLAG_$fl missing in the document"; _rc=1; }
	done
	# limits and fixed values: every define of the header's Limits block carries a "docs:" tag
	# naming its row in section 8; the row's value cell must be the header's value
	sed -n '/^\/\* ---- Limits/,/^\/\* ---- GETPARAM/p' "$H" | grep '^#define' >"$W/limdefs.txt"
	[ -s "$W/limdefs.txt" ] || { echo "no defines found in the header's Limits block"; _rc=1; }
	while IFS= read -r ld; do
		ln=$(printf '%s\n' "$ld" | sed 's/^#define[[:space:]]*\([A-Z_0-9]*\).*/\1/')
		row=$(printf '%s\n' "$ld" | sed -n 's/.*\/\* docs: \(.*\) \*\/.*/\1/p')
		[ -n "$row" ] || { echo "limit $ln has no docs: tag in the header"; _rc=1; continue; }
		printf '#include "nvidia-drm-render.h"\n#include <stdio.h>\nint main(void){printf("%%llu\\n",(unsigned long long)(%s));return 0;}\n' "$ln" >"$W/lim.c"
		cc -std=c11 -I"$H_DIR" "$W/lim.c" -o "$W/lim" 2>/dev/null && v=$("$W/lim") || { echo "cannot evaluate $ln"; _rc=1; continue; }
		case $ld in
		*ULL*)
			if [ "$v" -ge 1048576 ] && [ $((v % 1048576)) -eq 0 ]; then txt="$((v / 1048576)) MiB"
			elif [ "$v" -ge 1024 ] && [ $((v % 1024)) -eq 0 ]; then txt="$((v / 1024)) KiB"
			else txt="$v"; fi;;
		*) txt="$v";;
		esac
		# a minimum names its GETPARAM; the row's last cell must show it
		par=$(printf '%s\n' "$ld" | sed -n 's/.*param: \([A-Z_]*\) \*\/.*/\1/p')
		row=$(printf '%s\n' "$row" | sed 's/; param: .*//')
		rowre=$(printf '%s' "$row" | sed 's/[][\.*^$()+?{|]/\\&/g')
		# the whole cell: the value, optionally followed by a parenthetical remark
		if [ -n "$par" ]; then
			case $ln in *_MIN) ;; *) echo "limit $ln carries a param: tag but its name does not end in _MIN"; _rc=1;; esac
			grep -Eq "^\| $rowre \| $txt( \([^|]*\))? \| \`$par\` \|\$" "$_doc" \
			    || { echo "limits table: $ln = $v ($txt) and GETPARAM $par not matched by the row '$row'"; _rc=1; }
			grep -q "^#define[[:space:]]*NVR_PARAM_$par[[:space:]]" "$H" || { echo "limits table: $ln names GETPARAM $par, which the header lacks"; _rc=1; }
		else
			grep -Eq "^\| $rowre \| $txt( \([^|]*\))? \|" "$_doc" \
			    || { echo "limits table: $ln = $v ($txt) not matched by the row '$row'"; _rc=1; }
		fi
	done <"$W/limdefs.txt"
	# ioctl number ranges quoted in the document must not reach into used numbers
	_lastd=$(awk '{print $3}' "$W/table.txt" | while read -r v; do printf '%d\n' "$v"; done | sort -n | tail -1)
	_last=$(printf '0x%x' "$_lastd")
	grep -c 'new ioctl numbers in 0x[0-9a-f]*-0x[0-9a-f]*' "$_doc" | grep -q '^[1-9]' \
	    || { echo "the document no longer states the range for new ioctl numbers"; _rc=1; }
	grep -o 'new ioctl numbers in 0x[0-9a-f]*-0x[0-9a-f]*' "$_doc" | sed 's/.* in //; s/-.*//' | while read -r lo; do
		[ "$(printf '%d' "$lo")" -gt "$_lastd" ] || echo "document offers $lo for new ioctls but $_last is already used"
	done >"$W/rng.txt"
	[ -s "$W/rng.txt" ] && { cat "$W/rng.txt"; _rc=1; }
	# markdown tables: every row has the header's cell count (an unescaped pipe in a cell breaks it)
	for f in "$_doc" "$REPO/PROVENANCE.md"; do
		awk -v F="$f" 'function cells(l,  t) { t=l; gsub(/\\\|/, "", t); return gsub(/\|/, "|", t) }
			/^\|/ { n=cells($0); if (!intab) { hdr=n; intab=1 } else if (n != hdr) print F ": table row has " n " pipes, header " hdr ": " substr($0, 1, 60); next }
			!/^\|/ { intab=0 }' "$f"
	done >"$W/tab.txt"
	grep -n '^[^|].*\\|' "$_doc" | grep -v '^[0-9]*:|' >"$W/escp.txt" || true
	[ -s "$W/escp.txt" ] && { sed 's/^/escaped pipe outside a table: /' "$W/escp.txt"; _rc=1; }
	[ -s "$W/tab.txt" ] && { cat "$W/tab.txt"; _rc=1; }
	# every NVR_ identifier the prose names is defined by the header (a trailing underscore is a wildcard)
	cat "$_doc" "$_man" | grep -o '\(DRM_IOCTL_\|DRM_\)\{0,1\}NVR_[A-Z0-9_]*' | sort -u | while read -r id; do
		case $id in *_) continue;; esac
		grep -q "^#define[[:space:]]*$id\([[:space:]]\|(\)" "$H" || echo "the prose names $id, which the header does not define"
	done >"$W/ids.txt"
	[ -s "$W/ids.txt" ] && { cat "$W/ids.txt"; _rc=1; }
	# man page prose for the rules reviewers asked to see
	awk '/^\.It Dv DRM_IOCTL_NVR_EXEC/ {s=1; next} /^\.It Dv/ {s=0} s' "$_man" | grep -q 'NVR_EXEC_PUSH_LEN_MAX' || { echo "man page: EXEC does not name NVR_EXEC_PUSH_LEN_MAX"; _rc=1; }
	awk '/^\.It Dv DRM_IOCTL_NVR_GETPARAM/ {s=1; next} /^\.It Dv/ {s=0} s' "$_man" | grep -q 'rounded down' || { echo "man page: GETPARAM does not say the free video memory is rounded down"; _rc=1; }
	awk '/^\.It Dv DRM_IOCTL_NVR_CHANNEL_ALLOC/ {s=1; next} /^\.It Dv/ {s=0} s' "$_man" | grep -q '1-based' || { echo "man page: CHANNEL_ALLOC does not say engine_instance is 1-based"; _rc=1; }
	awk '/^\.It Er ENODEV/ {s=1; next} /^\.It Er/ {s=0} /^\.Sh / {s=0} s' "$_man" | grep -q 'CHANNEL_FREE' || { echo "man page: ENODEV does not say to free the channel"; _rc=1; }
	awk '/^\.It Er ENOSPC/ {s=1; next} /^\.It Er/ {s=0} /^\.Sh / {s=0} s' "$_man" | grep -q 'wait\|drain' || { echo "man page: ENOSPC gives no next step"; _rc=1; }
	# review fixes B1, B2 and the N9 notes
	tr '\n' ' ' <"$_doc" | tr -s ' ' | grep -q 'for `GR`, the 3D, compute, copy, inline-to-memory and 2D classes' || { echo "document: a GR channel must list the copy class"; _rc=1; }
	grep -q 'copy' "$H_DIR/nvidia-drm-render.h" && sed -n '/define[[:space:]]*NVR_ENGINE_GR/p' "$H_DIR/nvidia-drm-render.h" | grep -q copy || { echo "header: NVR_ENGINE_GR comment must list copy"; _rc=1; }
	awk '/^\.It Dv DRM_IOCTL_NVR_CHANNEL_ALLOC/ {s=1; next} /^\.It Dv/ {s=0} s' "$_man" | grep -q 'copy object' || { echo "man page: CHANNEL_ALLOC must list the copy object"; _rc=1; }
	tr '\n' ' ' <"$_doc" | tr -s ' ' | grep -q 'UNMAP treats holes as no-ops' || { echo "document: UNMAP must treat holes as no-ops"; _rc=1; }
	tr '\n' ' ' <"$_doc" | tr -s ' ' | grep -q 'MAP inside a sparse region replaces' || { echo "document: a MAP inside a sparse region must replace mappings"; _rc=1; }
	grep -q '^## 11\. Notes for the Mesa backend' "$_doc" || { echo "document: the section of notes for N9 is missing"; _rc=1; }
	grep -q 'EACCES' "$_doc" || { echo "document: the mmap authorisation rule (EACCES) is missing"; _rc=1; }
	awk '/^\.It Er EBUSY/ {s=1; next} /^\.It Er/ {s=0} /^\.Sh / {s=0} s' "$_man" | grep -q 'VM_INIT' || { echo "man page: EBUSY does not mention VM_INIT"; _rc=1; }
	awk '/^\.It Er ENOSPC/ {s=1; next} /^\.It Er/ {s=0} /^\.Sh / {s=0} s' "$_man" | grep -q 'open the device again' || { echo "man page: ENOSPC does not say to open the device again"; _rc=1; }
	grep -q 'EACCES' "$_man" || { echo "man page: the mmap EACCES rule is missing"; _rc=1; }
	awk '/^\.It Dv DRM_IOCTL_NVR_GEM_CPU_PREP/ {s=1; next} /^\.It Dv/ {s=0} s' "$_man" | grep -q 'unspecified' || { echo "man page: CPU_PREP does not say what the buffer holds after ENODEV"; _rc=1; }
	awk '/^\.It Dv DRM_IOCTL_NVR_GETINFO/ {s=1; next} /^\.It Dv/ {s=0} s' "$_man" | grep -q 'must be 0' || { echo "man page: GETINFO lacks the counting-call rule"; _rc=1; }
	# section references
	grep -o 'section [0-9][0-9]*\(\.[0-9][0-9]*\)*' "$_doc" | sed 's/section //' | sort -u | while read -r ref; do
		grep -q "^#\{1,6\} $ref\.\{0,1\}[[:space:]]" "$_doc" || echo "dangling reference: section $ref has no heading"
	done >"$W/refs.txt"
	[ -s "$W/refs.txt" ] && { cat "$W/refs.txt"; _rc=1; }
	# man page content
	awk '/^\.Sh CPU MAPPINGS/ {s=1; next} /^\.Sh / {s=0} s' "$_man" | grep -q 'memcpy' || { echo "man page: CPU MAPPINGS lacks the memcpy warning"; _rc=1; }
	awk '/^\.Sh SEE ALSO/ {s=1; next} /^\.Sh / {s=0} s' "$_man" | grep -q 'the source tree' && { echo "man page: SEE ALSO names 'the source tree'"; _rc=1; }
	return $_rc
}

if check_docs "$MAN" "$DOC" >"$W/real.out" 2>&1; then
	pass "man page lint clean; $(wc -l <"$W/table.txt" | tr -d ' ') ioctls agree across header, man page and document; params and flags described"
else cat "$W/real.out"; fail "documents disagree with the header"; fi

# the test can fail: each planted change must be refused, and for the stated reason
expect_refused() { # label man doc pattern
	_l=$1; _m=$2; _d=$3; _p=$4
	if check_docs "$_m" "$_d" >"$W/mut.out" 2>&1; then
		fail "$_l was NOT refused"
	elif grep -q "$_p" "$W/mut.out"; then
		pass "$_l is refused"
	else
		cat "$W/mut.out"; fail "$_l was refused for the wrong reason (expected '$_p')"
	fi
}
grep -v 'DRM_IOCTL_NVR_EXEC' "$MAN" >"$W/man.mut"
expect_refused "man page without DRM_IOCTL_NVR_EXEC" "$W/man.mut" "$DOC" "man ioctl list differs"
sed 's/^| EXEC | 0x4f | \(0x[0-9a-f]*\) | in\/out | `drm_nvr_exec` | 40 |$/| EXEC | 0x4f | \1 | in\/out | `drm_nvr_exec` | 48 |/' "$DOC" >"$W/doc.mut"
cmp -s "$DOC" "$W/doc.mut" && fail "size mutation changed nothing"
expect_refused "document with a wrong struct size" "$MAN" "$W/doc.mut" "row for EXEC"
grep -v '^| `MAX_SYNCS` (13) |' "$DOC" >"$W/doc.mut2"
cmp -s "$DOC" "$W/doc.mut2" && fail "parameter-row mutation changed nothing"
expect_refused "document without the MAX_SYNCS parameter row" "$MAN" "$W/doc.mut2" "NVR_PARAM_MAX_SYNCS"
sed 's/^| pushes per EXEC | 256 |/| pushes per EXEC | 255 |/' "$DOC" >"$W/doc.mut3"
cmp -s "$DOC" "$W/doc.mut3" && fail "minimum mutation changed nothing"
expect_refused "document with a wrong guaranteed minimum" "$MAN" "$W/doc.mut3" "NVR_EXEC_PUSH_MAX_MIN"
sed 's/^## 6\. VM and execution/## 6. VM and execution (renumbered)/; s/^### 6\.5 Fences/### 6.9 Fences/' "$DOC" >"$W/doc.mut4"
cmp -s "$DOC" "$W/doc.mut4" && fail "section mutation changed nothing"
expect_refused "document with a dangling section reference" "$MAN" "$W/doc.mut4" "dangling reference: section 6.5"
sed 's/^## 9\. Concurrency and lifetime/## 10. Concurrency and lifetime/' "$DOC" >"$W/doc.mut5"
cmp -s "$DOC" "$W/doc.mut5" && fail "section 9 mutation changed nothing"
expect_refused "document with the heading of section 9 renamed" "$MAN" "$W/doc.mut5" "dangling reference: section 9"
sed 's/^| VM_INIT kernel range | 16 MiB |/| VM_INIT kernel range | 32 MiB |/' "$DOC" >"$W/doc.mut6"
cmp -s "$DOC" "$W/doc.mut6" && fail "kernel range mutation changed nothing"
expect_refused "document with a wrong kernel range minimum" "$MAN" "$W/doc.mut6" "NVR_KERNEL_VA_SIZE_MIN"
sed 's/new ioctl numbers in 0x50-0x5f/new ioctl numbers in 0x4b-0x5f/' "$DOC" >"$W/doc.mut7"
cmp -s "$DOC" "$W/doc.mut7" && fail "range mutation changed nothing"
expect_refused "document offering used ioctl numbers" "$MAN" "$W/doc.mut7" "already used"
sed 's/(major << 16) \\| minor/(major << 16) | minor/' "$DOC" >"$W/doc.mut8"
cmp -s "$DOC" "$W/doc.mut8" && fail "pipe mutation changed nothing"
expect_refused "document with an unescaped pipe in a table cell" "$MAN" "$W/doc.mut8" "table row has"
sed 's/^| pushes per EXEC | 256 |/| pushes per EXEC | 2560 |/' "$DOC" >"$W/doc.mut9"
cmp -s "$DOC" "$W/doc.mut9" && fail "prefix mutation changed nothing"
expect_refused "document with 2560 where the minimum is 256" "$MAN" "$W/doc.mut9" "NVR_EXEC_PUSH_MAX_MIN"
sed 's/new ioctl numbers in/new numbers for ioctls in/' "$DOC" >"$W/doc.mut10"
cmp -s "$DOC" "$W/doc.mut10" && fail "range phrase mutation changed nothing"
expect_refused "document without the new-ioctl range sentence" "$MAN" "$W/doc.mut10" "no longer states"
sed 's/`NVR_PAGE_ALIGN`/`NVR_BOGUS_NAME`/' "$DOC" >"$W/doc.mut11"
cmp -s "$DOC" "$W/doc.mut11" && fail "identifier mutation changed nothing"
expect_refused "document naming an undefined NVR_ identifier" "$MAN" "$W/doc.mut11" "NVR_BOGUS_NAME"
sed 's/^| pushes per EXEC | 256 | `EXEC_PUSH_MAX` |/| pushes per EXEC | 256 | `MAX_SYNCS` |/' "$DOC" >"$W/doc.mut12"
cmp -s "$DOC" "$W/doc.mut12" && fail "param swap mutation changed nothing"
expect_refused "document with a swapped GETPARAM cell" "$MAN" "$W/doc.mut12" "NVR_EXEC_PUSH_MAX_MIN"
grep -v 'NVR_EXEC_PUSH_LEN_MAX' "$MAN" >"$W/man.mut3"
expect_refused "man page without the push length limit" "$W/man.mut3" "$DOC" "NVR_EXEC_PUSH_LEN_MAX"
awk '/^\.It Er EBUSY/ {s=1} s && /VM_INIT/ {s=0; next} {print}' "$MAN" >"$W/man.mut4"
cmp -s "$MAN" "$W/man.mut4" && fail "EBUSY mutation changed nothing"
expect_refused "man page whose EBUSY does not name VM_INIT" "$W/man.mut4" "$DOC" "EBUSY does not mention VM_INIT"
sed 's/(major << 16) | minor/(major << 16) \\| minor/; s/^\(  .*\)(major << 8) | minor/\1(major << 8) \\| minor/' "$DOC" >"$W/doc.mut13"
cmp -s "$DOC" "$W/doc.mut13" && fail "escaped pipe mutation changed nothing"
expect_refused "document with an escaped pipe outside a table" "$MAN" "$W/doc.mut13" "escaped pipe outside"
grep -v 'memcpy' "$MAN" >"$W/man.mut2"
expect_refused "man page without the memcpy warning" "$W/man.mut2" "$DOC" "memcpy"

[ "$FAILS" -eq 0 ] && { echo "render_uapi_docs_test: PASS"; exit 0; }
echo "render_uapi_docs_test: FAIL ($FAILS)"; exit 1

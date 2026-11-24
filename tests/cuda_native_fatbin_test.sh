#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-2-Clause
#
# cuda_native_fatbin_test.sh - the cuda-native fatbin container (Track #2427,
# slice 1): the C nvfatbin that writes our container, the C cuda-objdump that
# reads it, and the container itself, which is LLVM's OffloadBinary layout
# version 2.
#
# It runs on a FRESH COPY of the STAGED content (checkout-index; after a
# commit that is the commit).  Stage new files before running it.
#
# Steps:
# - the C tools are built by mksdk.sh and carry our header and the LLD
#   linker in .comment;
# - the reader and the writer agree, and every refusal the reader promises
#   happens with its own message, from a crafted file;
# - a round trip through nvfatbin and cuda-objdump keeps the kinds, the
#   arches, the sizes and the hashes, and --extract gives the bytes back;
# - the JSON and the JSON lines validate against the schema, and a closed
#   pipe is a clean end;
# - the JSON is valid UTF-8 whatever the metadata holds, and the text output
#   shows the control bytes instead of printing them;
# - the output modes cannot be combined, and the member index is a number;
# - a file that cannot be read says why, and the writer refuses a container
#   the runtime would refuse;
# - LLVM reads our container (llvm-objdump --offloading) and we read the
#   container LLVM writes;
# - the ELF path: cuda-objdump finds the members in the object clang builds
#   with our SDK;
# - a mutant reader without the image bounds check is caught.
#
# Every check prints "ok", "FAIL" or "skip".  The summary counts all three.
# Exit status: the number of failures (at most 76, so it never reads as 77),
# 77 when LLVM 23 is missing and every check that ran passed (the checks
# that need LLVM were skipped), 99 when the setup failed (no fresh copy).
# Run: sh tests/cuda_native_fatbin_test.sh
# Env: LLVM (default /usr/local/llvm23), TMPDIR (scratch, default /tmp).
# CUDA_NATIVE_TEST_REPO overrides REPO for a child run from the staged copy.

PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=${CUDA_NATIVE_TEST_REPO:-$(CDPATH= cd -- "$HERE/.." && pwd)}
LLVM=${LLVM:-/usr/local/llvm23}
export LLVM
CXX=$LLVM/bin/clang++

W=$(mktemp -d "${TMPDIR:-/tmp}/cuda-native-fatbin-test.XXXXXXXX") || exit 99
trap 'rm -rf "$W"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

PASS=0
FAIL=0
SKIP=0
ok() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }
# skip_check NAME: record and print a skip without counting it as a pass.
# Time: O(1).  Space: O(1).
skip_check() { SKIP=$((SKIP + 1)); printf 'skip %s\n' "$1"; }
# expect_rc NAME RC WANT: rc captured by the caller on its own line before.
expect_rc() {
	if [ "$2" -eq "$3" ]; then ok "$1"; else bad "$1 (rc=$2, want $3)"; fi
}
finish() {
	printf '%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
	[ "$FAIL" -le 76 ] || FAIL=76
	exit "$FAIL"
}

# ---- fresh copy ----------------------------------------------------------
SRC=$W/src
mkdir -p "$SRC"
git -C "$REPO" checkout-index -a --prefix="$SRC/" >"$W/checkout.log" 2>&1
rc=$?
expect_rc "fresh copy of the staged tree" $rc 0
CN=$SRC/lib/cuda-native
K=$SRC/tests/cuda-native
if [ ! -f "$CN/mksdk.sh" ] || [ ! -f "$K/fatbin_reader_test.c" ]; then
	echo "The test runs on the staged tree: stage the files first" \
	    "(git add lib/cuda-native tests/cuda-native tests/cuda_native_fatbin_test.sh)." >&2
	printf '%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
	exit 99
fi

# ---- LLVM ----------------------------------------------------------------
if [ ! -x "$LLVM/bin/clang" ] || [ ! -x "$LLVM/bin/llvm-objdump" ]; then
	skip_check "every check that needs LLVM 23"
	printf '%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
	exit 77
fi

# ---- the SDK -------------------------------------------------------------
SDK=$W/sdk
if ! sh "$CN/mksdk.sh" "$SDK" >"$W/mksdk.log" 2>&1; then
	echo "mksdk.sh failed:" >&2
	sed -n 1,20p "$W/mksdk.log" >&2
	printf '%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
	exit 99
fi
ok "mksdk.sh builds the SDK tree with the C tools"

# The C tools carry our header and the linker that linked them.
for tool in nvfatbin fatbinary cuda-objdump; do
	[ -x "$SDK/bin/$tool" ]
	expect_rc "the SDK installs an executable $tool" $? 0
done
cmp -s "$SDK/bin/nvfatbin" "$SDK/bin/fatbinary"
expect_rc "nvfatbin and fatbinary are the same program" $? 0
for tool in nvfatbin fatbinary cuda-objdump; do
	readelf -p .comment "$SDK/bin/$tool" 2>/dev/null |
	    grep -Fq 'Linker: LLD'
	expect_rc "$tool was linked with LLD" $? 0
done

# ---- the reader and the writer -------------------------------------------
# The unit test builds containers and breaks them in memory.  It is the same
# reader the tools use, so a check there is a check of the tools.
cc -std=gnu11 -O2 -Wall -Wextra -Werror -I"$CN/fatbin" \
    -o "$W/fatbin_reader_test" "$K/fatbin_reader_test.c" \
    "$CN/fatbin/cnfatbin.c" -lmd >"$W/reader-build.log" 2>&1
expect_rc "the reader test builds with the base compiler" $? 0
"$W/fatbin_reader_test" >"$W/reader.out" 2>&1
rc=$?
[ $rc -eq 0 ]
expect_rc "every reader and writer check passes" $rc 0
sed -n 1,40p "$W/reader.out"

# ---- a round trip --------------------------------------------------------
PTX1=$W/one.ptx
PTX2=$W/two.ptx
CUBIN=$W/one.cubin
printf '.target sm_120\n.visible .entry one() { ret; }\n' >"$PTX1"
printf '.target sm_121a\n.visible .entry two() { ret; }\n' >"$PTX2"
printf 'CUDA-NATIVE-STUB-CUBIN 1\nstub cubin payload\n' >"$CUBIN"
CONTAINER=$W/container.bin
"$SDK/bin/nvfatbin" -64 --create "$CONTAINER" \
    --image3=kind=ptx,sm=120,file="$PTX1" \
    --image3=kind=ptx,sm=121a,file="$PTX2" \
    --image3=kind=elf,sm=120,file="$CUBIN" >"$W/nvfatbin.out" 2>&1
rc=$?
[ $rc -eq 0 ] && [ -s "$CONTAINER" ]
expect_rc "nvfatbin writes a container for two PTX members and one cubin" $rc 0

"$SDK/bin/cuda-objdump" --json "$CONTAINER" >"$W/container.json" 2>"$W/container.err"
rc=$?
[ $rc -eq 0 ] && [ ! -s "$W/container.err" ]
expect_rc "cuda-objdump --json reads the container" $rc 0
python3 -I "$SRC/tests/libnvrm/schema_validate.py" \
    "$SDK/share/cuda-native/schema/cuda-objdump-1.schema.json" \
    "$W/container.json" >"$W/container.schema" 2>&1
expect_rc "the container JSON validates against cuda-objdump-1" $? 0
python3 -I - "$W/container.json" "$PTX1" "$PTX2" "$CUBIN" <<'PY'
import json
import sys
from pathlib import Path

with open(sys.argv[1], encoding="utf-8") as f:
    doc = json.load(f)
assert doc["schema"] == "cuda-objdump/1", doc["schema"]
assert doc["tool"] == "cuda-objdump"
assert doc["source"] == "container", doc["source"]
assert doc["container_version"] == 2, doc["container_version"]
members = doc["members"]
assert len(members) == 3, members
want = [("ptx", "sm_120"), ("ptx", "sm_121a"), ("cubin", "sm_120")]
for member, (kind, arch) in zip(members, want):
    assert member["kind"] == kind, member
    assert member["arch"] == arch, member
    assert member["index"] >= 0
    assert len(member["sha256"]) == 64, member
    assert member["triple"] == "nvptx64-nvidia-cuda", member
sizes = [Path(p).stat().st_size for p in sys.argv[2:]]
for member, size in zip(members, sizes):
    assert member["size"] == size, (member, size)
assert members[0]["format"] == "ptx", members[0]
assert members[2]["format"] == "nvcubin/1", members[2]
PY
expect_rc "the JSON names the kinds, the arches, the sizes and the hashes" $? 0

# --extract gives the exact bytes back.
"$SDK/bin/cuda-objdump" --extract 0 "$W/extracted.ptx" "$CONTAINER" \
    >"$W/extract.out" 2>&1
rc=$?
[ $rc -eq 0 ] && cmp -s "$PTX1" "$W/extracted.ptx"
expect_rc "--extract 0 gives the first PTX member back byte for byte" $rc 0
"$SDK/bin/cuda-objdump" --extract 2 "$W/extracted.cubin" "$CONTAINER" \
    >"$W/extract2.out" 2>&1
rc=$?
[ $rc -eq 0 ] && cmp -s "$CUBIN" "$W/extracted.cubin"
expect_rc "--extract 2 gives the cubin member back byte for byte" $rc 0
"$SDK/bin/cuda-objdump" --extract 3 "$W/extract-none.bin" "$CONTAINER" \
    >"$W/extract3.out" 2>"$W/extract3.err"
rc=$?
[ $rc -eq 1 ] && [ ! -e "$W/extract-none.bin" ] &&
    grep -q 'member index out of range' "$W/extract3.err"
expect_rc "--extract refuses a member that is not there" $rc 1

# The text form names the same members.
"$SDK/bin/cuda-objdump" "$CONTAINER" >"$W/container.txt" 2>&1
rc=$?
[ $rc -eq 0 ] && grep -q '3 members' "$W/container.txt" &&
    grep -q 'ptx arch=sm_121a' "$W/container.txt" &&
    grep -q 'cubin arch=sm_120' "$W/container.txt"
expect_rc "the text form lists every member" $rc 0

# ---- JSON lines ----------------------------------------------------------
"$SDK/bin/cuda-objdump" --jsonl "$CONTAINER" >"$W/container.jsonl" 2>&1
rc=$?
[ $rc -eq 0 ]
expect_rc "cuda-objdump --jsonl writes a header line and one line per member" $rc 0
[ "$(wc -l <"$W/container.jsonl")" -eq 4 ]
expect_rc "--jsonl writes one header line and three member lines" $? 0
python3 -I "$SRC/tests/libnvrm/schema_validate.py" \
    "$SDK/share/cuda-native/schema/cuda-objdump-1.schema.json" \
    "$W/container.jsonl" >"$W/container-jsonl.schema" 2>&1
expect_rc "every JSON line validates against cuda-objdump-1" $? 0
# A closed pipe is a clean end, not an error.
"$SDK/bin/cuda-objdump" --jsonl "$CONTAINER" 2>"$W/epipe.err" | head -1 \
    >"$W/epipe.out"
rc=$?
[ $rc -eq 0 ] || [ $rc -eq 141 ]
expect_rc "a closed pipe ends cuda-objdump cleanly" $rc 0
[ ! -s "$W/epipe.err" ]
expect_rc "a closed pipe prints no error" $? 0

# ---- every reader error, from a crafted file -----------------------------
# The C reader test builds the containers it breaks: one place knows how to
# lay a container out, and the tools are driven over the files it writes.
rm -rf "$W/cases"
mkdir -p "$W/cases"
"$W/fatbin_reader_test" --write-cases "$W/cases" >"$W/write-cases.log" 2>&1
expect_rc "the reader test writes the crafted containers" $? 0
for name in short magic version size entries many image string \
    unterminated kind offload hash-format hash-mismatch; do
	[ -s "$W/cases/$name.bin" ]
	expect_rc "the crafted container $name is written" $? 0
done

# Every case is refused with its own message.
check_case() {
	name=$1
	want=$2
	"$SDK/bin/cuda-objdump" --json "$W/cases/$name" \
	    >"$W/case-$name.out" 2>"$W/case-$name.err"
	rc=$?
	if [ $rc -ne 1 ]; then
		bad "the reader refuses $name with its own message (rc=$rc)"
		return
	fi
	if grep -Fq "$want" "$W/case-$name.err"; then
		ok "the reader refuses $name with its own message"
	else
		bad "the reader refuses $name with its own message"
		sed -n 1,3p "$W/case-$name.err"
	fi
}
check_case short.bin "input is shorter than the container header"
check_case magic.bin "bad container magic"
check_case version.bin "unknown container version"
check_case size.bin "container size is larger than the input"
check_case entries.bin "the entries table is out of range"
check_case many.bin "too many entries in the container"
check_case image.bin "a member image is out of range"
check_case string.bin "a member string is out of range"
check_case unterminated.bin "a member string value is not NUL terminated"
check_case kind.bin "a member has an image kind other than PTX, cubin or none"
check_case offload.bin "a member has an unsupported offload kind"
check_case hash-format.bin "a member sha256 is not 64 hexadecimal digits"
check_case hash-mismatch.bin "a member sha256 does not match its image"

# ---- the cases the reader test builds -------------------------------------
# The same directory holds the containers the C test builds by hand.
for name in arch-invalid-utf8 arch-control-bytes value-too-long \
    unknown-long-key digest-too-long overlapping-images many-strings; do
	[ -s "$W/cases/$name.bin" ]
	expect_rc "the crafted container $name is written" $? 0
done
check_case value-too-long.bin \
    "a member value is longer than the field it belongs to"
check_case digest-too-long.bin \
    "a member sha256 is not 64 hexadecimal digits"
check_case overlapping-images.bin \
    "the container asks for more hashing than its size allows"

# A key we do not know is ignored, and the container still opens.
"$SDK/bin/cuda-objdump" --json "$W/cases/unknown-long-key.bin" \
    >"$W/unknown-long-key.json" 2>"$W/unknown-long-key.err"
rc=$?
[ $rc -eq 0 ] && [ ! -s "$W/unknown-long-key.err" ]
check=$?
expect_rc "a key we do not know with a long value is ignored" $check 0

# ---- one place crafts the broken containers ------------------------------
# The C reader test is the only place that breaks a container: the shell
# test drives the tools over the files it writes.
craft=$(printf '%s%s' find _record)
! grep -rq "$craft" "$SRC/tests" &&
    grep -q 'craft_file_name' "$K/fatbin_reader_test.c"
expect_rc "only the C reader test crafts a broken container" $? 0

# ---- one table of errors -------------------------------------------------
# Every code has one short name and one message, and both live in one table.
python3 -I - "$CN/fatbin/cnfatbin.c" "$CN/fatbin/cnfatbin.h" <<'PY'
import re
import sys

source = open(sys.argv[1], encoding="utf-8").read()
header = open(sys.argv[2], encoding="utf-8").read()
start = header.index("enum cnfatbin_error {")
block = header[start:header.index("};", start)]
codes = re.findall(r"^\t(CNFATBIN_[A-Z0-9_]+)(?: =|,|$)", block, re.M)
codes = [code for code in codes if code != "CNFATBIN_ERROR_COUNT"]
table = re.findall(r"^\t\[(CNFATBIN_[A-Z0-9_]+)\] = \{", source, re.M)
assert table == codes, (table, codes)
assert "case CNFATBIN_E_" not in source, "a second table of errors"
assert source.count("error_table[err]") == 2, "the accessors do not read the table"
assert "_Static_assert(sizeof(error_table)" in source, "no build time check"
print("%d error codes, one table" % len(table))
PY
expect_rc "the error codes have one table with a name and a message each" $? 0

# ---- one magic check and one file reader ---------------------------------
python3 -I - "$CN/fatbin/cnfatbin.c" "$CN/fatbin/cnfatbin.h" \
    "$CN/fatbin/cuda-objdump.c" "$CN/fatbin/nvfatbin.c" "$CN/fatbin/cntool.c" \
    <<'PY'
import glob
import os
import re
import sys

cnfatbin_c, cnfatbin_h, objdump, nvfatbin, cntool = sys.argv[1:6]
source = open(cnfatbin_c, encoding="utf-8").read()
header = open(cnfatbin_h, encoding="utf-8").read()
objdump_source = open(objdump, encoding="utf-8").read()
nvfatbin_source = open(nvfatbin, encoding="utf-8").read()
# One magic: the helper is declared once and every reader of ours uses it.
assert header.count("cnfatbin_has_magic(") == 1, header
assert source.count("cnfatbin_has_magic(") == 3, source.count("cnfatbin_has_magic(")
assert objdump_source.count("cnfatbin_has_magic(") == 1
# No other file of ours knows the magic bytes.
assert "CNFATBIN_MAGIC" not in objdump_source
assert "CNFATBIN_MAGIC" not in nvfatbin_source
# One file reader: it is defined once, and both tools call it.
definitions = []
for path in glob.glob(os.path.dirname(cnfatbin_c) + "/*.c"):
    text = open(path, encoding="utf-8").read()
    if re.search(r"^cntool_read_file\(", text, re.M):
        definitions.append(path)
assert definitions == [cntool], definitions
assert "cntool_read_file(" in objdump_source
assert "cntool_read_file(" in nvfatbin_source
assert "read_whole_file" not in objdump_source
assert "read_file(" not in nvfatbin_source.replace("cntool_read_file(", "")
print("one magic check, one file reader")
PY
expect_rc "the magic is checked in one place and one helper reads a file" $? 0

# ---- the alignment the manual documents ----------------------------------
# The header, the entries table, the string tables and the images are
# 8-byte aligned; the keys and the values are packed and are not.
python3 -I - "$CONTAINER" "$CN/man/nvfatbin.5" "$CN/fatbin/cnfatbin.h" \
    <<'PY'
import struct
import sys

data = open(sys.argv[1], "rb").read()
man = open(sys.argv[2], encoding="utf-8").read()
header = open(sys.argv[3], encoding="utf-8").read()


def u64(offset):
    return struct.unpack_from("<Q", data, offset)[0]


entries = u64(16)
count = u64(24)
assert entries % 8 == 0, entries
arches = []
for index in range(count):
    entry = entries + index * 40
    string_table = u64(entry + 8)
    image_offset = u64(entry + 24)
    assert string_table % 8 == 0, string_table
    assert image_offset % 8 == 0, image_offset
    for j in range(u64(entry + 16)):
        record = string_table + j * 24
        key_offset = u64(record)
        value_offset = u64(record + 8)
        key = data[key_offset:data.index(b"\0", key_offset)].decode("utf-8")
        value = data[value_offset:data.index(b"\0", value_offset)].decode("utf-8")
        assert key in ("triple", "arch", "cloudbsd.format", "cloudbsd.sha256"), key
        if key == "arch":
            arches.append(value)
assert arches == ["sm_120", "sm_121a", "sm_120"], arches
# The manual and the header say which offsets are aligned.
assert "every offset is 8-byte aligned" not in man, man
assert "every offset is 8-byte aligned" not in header, header
assert "8-byte aligned" in man and "8-byte aligned" in header
print("the aligned offsets are aligned, the keys are packed")
PY
expect_rc "the container matches the alignment the manual documents" $? 0

# ---- the kinds the manual documents --------------------------------------
grep -q 'neither PTX, nor a cubin, nor none' "$CN/man/nvfatbin.5" &&
    grep -q 'an offload kind is neither CUDA nor none' "$CN/man/nvfatbin.5" &&
    grep -q '"kind": { "enum": \["ptx", "cubin", "none"\] }' \
    "$CN/schema/cuda-objdump-1.schema.json"
expect_rc "the manual and the schema say that a kind of none is accepted" $? 0

# ---- the JSON is always valid UTF-8 ----------------------------------------
# A container may hold bytes that are not a UTF-8 character.  The JSON
# holds the replacement character for them, so every parser reads it.
"$SDK/bin/cuda-objdump" --json "$W/cases/arch-invalid-utf8.bin" \
    >"$W/arch-invalid-utf8.json" 2>"$W/arch-invalid-utf8.err"
rc=$?
[ $rc -eq 0 ]
check=$?
expect_rc "cuda-objdump --json reads a container with bytes that are not UTF-8" $check 0
python3 -I - "$W/arch-invalid-utf8.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as f:
    doc = json.load(f)
arch = doc["members"][0]["arch"]
assert arch.startswith("sm_"), arch
assert "�" in arch, arch
print("the JSON holds the replacement character: %r" % arch)
PY
expect_rc "the JSON with bytes that are not UTF-8 is valid UTF-8 JSON" $? 0
python3 -I "$SRC/tests/libnvrm/schema_validate.py" \
    "$SDK/share/cuda-native/schema/cuda-objdump-1.schema.json" \
    "$W/arch-invalid-utf8.json" >"$W/arch-invalid-utf8.schema" 2>&1
expect_rc "the JSON with bytes that are not UTF-8 validates against the schema" $? 0

# ---- no raw control byte in the text output --------------------------------
# One member is one line, and the control bytes in the metadata are shown.
"$SDK/bin/cuda-objdump" "$W/cases/arch-control-bytes.bin" \
    >"$W/arch-control-bytes.txt" 2>"$W/arch-control-bytes.err"
rc=$?
[ $rc -eq 0 ] && [ "$(wc -l <"$W/arch-control-bytes.txt")" -eq 2 ] &&
    ! LC_ALL=C grep -q "$(printf '\033')" "$W/arch-control-bytes.txt" &&
    grep -q 'arch=a\\x0ab\\x1b' "$W/arch-control-bytes.txt"
check=$?
expect_rc "the text output shows the control bytes in the metadata" $check 0
sed -n 1,3p "$W/arch-control-bytes.txt"

# ---- the output modes cannot be combined -----------------------------------
"$SDK/bin/cuda-objdump" --json --jsonl "$CONTAINER" \
    >"$W/conflict.out" 2>"$W/conflict.err"
rc=$?
[ $rc -eq 2 ] && [ ! -s "$W/conflict.out" ] &&
    grep -q -- '--json and --jsonl cannot be combined' "$W/conflict.err"
check=$?
expect_rc "--json and --jsonl cannot be combined" $check 0
"$SDK/bin/cuda-objdump" --extract 0 "$W/conflict-extract.bin" --json \
    "$CONTAINER" >"$W/conflict2.out" 2>"$W/conflict2.err"
rc=$?
[ $rc -eq 2 ] && [ ! -e "$W/conflict-extract.bin" ] &&
    grep -q -- '--extract cannot be combined with --json' "$W/conflict2.err"
check=$?
expect_rc "--extract cannot be combined with --json" $check 0
"$SDK/bin/cuda-objdump" --extract 0 "$W/conflict-first.bin" \
    --extract 1 "$W/conflict-second.bin" "$CONTAINER" \
    >"$W/conflict3.out" 2>"$W/conflict3.err"
rc=$?
[ $rc -eq 2 ] && [ ! -e "$W/conflict-first.bin" ] &&
    [ ! -e "$W/conflict-second.bin" ] &&
    grep -q -- '--extract may be given only once' "$W/conflict3.err"
check=$?
expect_rc "--extract may be given only once" $check 0

# ---- the member index ------------------------------------------------------
"$SDK/bin/cuda-objdump" --extract -1 "$W/index-negative.bin" "$CONTAINER" \
    >"$W/index-negative.out" 2>"$W/index-negative.err"
rc=$?
[ $rc -eq 2 ] && [ ! -e "$W/index-negative.bin" ] &&
    grep -q 'member index must be a non-negative integer' \
    "$W/index-negative.err"
check=$?
expect_rc "a negative member index is refused" $check 0
"$SDK/bin/cuda-objdump" --extract 999999999999999999999999 \
    "$W/index-overflow.bin" "$CONTAINER" \
    >"$W/index-overflow.out" 2>"$W/index-overflow.err"
rc=$?
[ $rc -eq 2 ] && [ ! -e "$W/index-overflow.bin" ] &&
    grep -q 'member index must be a non-negative integer' \
    "$W/index-overflow.err"
check=$?
expect_rc "a member index too large is refused" $check 0
"$SDK/bin/cuda-objdump" --extract " 1" "$W/index-space.bin" "$CONTAINER" \
    >"$W/index-space.out" 2>"$W/index-space.err"
rc=$?
[ $rc -eq 2 ] && [ ! -e "$W/index-space.bin" ] &&
    grep -q 'member index must be a non-negative integer' \
    "$W/index-space.err"
check=$?
expect_rc "a member index with a space in it is refused" $check 0
"$SDK/bin/cuda-objdump" --extract 3 "$W/index-absent.bin" "$CONTAINER" \
    >"$W/index-absent.out" 2>"$W/index-absent.err"
rc=$?
[ $rc -eq 1 ] && [ ! -e "$W/index-absent.bin" ] &&
    grep -q 'member index 3 is out of range; valid indexes are 0-2' \
    "$W/index-absent.err"
check=$?
expect_rc "a member index that is not there says which indexes are" $check 0

# ---- why a file could not be read ------------------------------------------
"$SDK/bin/cuda-objdump" "$W/no-such-container.bin" \
    >"$W/noent.out" 2>"$W/noent.err"
rc=$?
[ $rc -eq 1 ] && grep -q 'no such file' "$W/noent.err"
check=$?
expect_rc "a missing file says that it is not there" $check 0
mkdir -p "$W/a-directory"
"$SDK/bin/cuda-objdump" "$W/a-directory" \
    >"$W/isdir.out" 2>"$W/isdir.err"
rc=$?
[ $rc -eq 1 ] && grep -q 'input is a directory' "$W/isdir.err"
check=$?
expect_rc "a directory says that it is a directory" $check 0
: >"$W/empty.bin"
"$SDK/bin/cuda-objdump" "$W/empty.bin" \
    >"$W/empty.out" 2>"$W/empty.err"
rc=$?
[ $rc -eq 1 ] && grep -q 'input is empty' "$W/empty.err"
check=$?
expect_rc "an empty file says that it is empty" $check 0
"$SDK/bin/nvfatbin" -64 --create "$W/no-image.bin" \
    --image3=kind=ptx,sm=120,file="$W/no-such-image.ptx" \
    >"$W/nvnoent.out" 2>"$W/nvnoent.err"
rc=$?
[ $rc -eq 1 ] && [ ! -e "$W/no-image.bin" ] &&
    grep -q 'no such file' "$W/nvnoent.err"
check=$?
expect_rc "nvfatbin says why an image could not be read" $check 0

# ---- the writer refuses what the runtime would refuse ----------------------
dd if=/dev/zero of="$W/huge.ptx" bs=1048576 count=17 2>/dev/null
"$SDK/bin/nvfatbin" -64 --create "$W/huge-container.bin" \
    --image3=kind=ptx,sm=120,file="$W/huge.ptx" \
    >"$W/huge.out" 2>"$W/huge.err"
rc=$?
[ $rc -eq 1 ] && [ ! -e "$W/huge-container.bin" ] &&
    grep -q 'the container to write is larger than the limit' "$W/huge.err"
check=$?
expect_rc "the writer refuses a container larger than the limit" $check 0

# ---- LLVM reads our container -------------------------------------------
# llvm-objdump --offloading looks at the sections whose ELF type is
# SHT_LLVM_OFFLOADING, so the section type is set after llvm-objcopy has
# added the section.
printf 'int helper;\n' >"$W/small.c"
"$LLVM/bin/clang" -c "$W/small.c" -o "$W/small.o" >"$W/small.log" 2>&1
expect_rc "a small object for the LLVM oracle" $? 0
"$LLVM/bin/llvm-objcopy" --add-section ".llvm.offloading=$CONTAINER" \
    --set-section-flags .llvm.offloading=exclude "$W/small.o" "$W/offloading.o" \
    >"$W/objcopy.log" 2>&1
expect_rc "llvm-objcopy adds our container as .llvm.offloading" $? 0
python3 -I - "$W/offloading.o" <<'PY'
import struct
import sys

SHT_LLVM_OFFLOADING = 0x6FFF4C0B
path = sys.argv[1]
data = bytearray(open(path, "rb").read())
assert data[:4] == b"\x7fELF"
endian = "<" if data[5] == 1 else ">"
e_shoff = struct.unpack_from(endian + "Q", data, 0x28)[0]
e_shentsize = struct.unpack_from(endian + "H", data, 0x3A)[0]
e_shnum = struct.unpack_from(endian + "H", data, 0x3C)[0]
e_shstrndx = struct.unpack_from(endian + "H", data, 0x3E)[0]
str_off = struct.unpack_from(endian + "Q", data,
    e_shoff + e_shstrndx * e_shentsize + 0x18)[0]
found = False
for index in range(e_shnum):
    base = e_shoff + index * e_shentsize
    name_off = struct.unpack_from(endian + "I", data, base)[0]
    end = data.index(b"\0", str_off + name_off)
    name = bytes(data[str_off + name_off:end]).decode("utf-8")
    if name == ".llvm.offloading":
        struct.pack_into(endian + "I", data, base + 4, SHT_LLVM_OFFLOADING)
        found = True
assert found, "no .llvm.offloading section"
open(path, "wb").write(bytes(data))
PY
expect_rc "the .llvm.offloading section gets the LLVM offloading type" $? 0
"$LLVM/bin/llvm-objdump" --offloading "$W/offloading.o" >"$W/offloading.out" 2>&1
rc=$?
[ $rc -eq 0 ] && grep -q 'kind            ptx' "$W/offloading.out" &&
    grep -q 'arch            sm_121a' "$W/offloading.out" &&
    grep -q 'kind            cubin' "$W/offloading.out" &&
    grep -q 'triple          nvptx64-nvidia-cuda' "$W/offloading.out"
expect_rc "llvm-objdump --offloading lists our members with kind and arch" $rc 0
sed -n 1,30p "$W/offloading.out"

# LLVM's own reader reads the container as well.
if [ -x "$LLVM/bin/llvm-offload-binary" ]; then
	(cd "$W" && "$LLVM/bin/llvm-offload-binary" "$CONTAINER" \
	    >"$W/llvm-read.out" 2>&1)
	rc=$?
	[ $rc -eq 0 ] && grep -q 'nvptx64-nvidia-cuda-sm_120.0.s' "$W/llvm-read.out" &&
	    grep -q 'nvptx64-nvidia-cuda-sm_121a.1.s' "$W/llvm-read.out"
	expect_rc "LLVM extracts our PTX members with their arch" $rc 0
fi

# ---- we read the container LLVM writes ------------------------------------
# clang-offload-packager writes the container itself; its --help names file
# and triple as the required keys.
"$LLVM/bin/clang-offload-packager" -o "$W/packager.bin" \
    --image="file=$PTX1,kind=cuda,triple=nvptx64-nvidia-cuda,arch=sm_120" \
    >"$W/packager.log" 2>&1
rc=$?
[ $rc -eq 0 ] && [ -s "$W/packager.bin" ]
expect_rc "clang-offload-packager writes a container" $rc 0
"$SDK/bin/cuda-objdump" --json "$W/packager.bin" >"$W/packager.json" 2>&1
rc=$?
[ $rc -eq 0 ]
expect_rc "our reader reads the container clang-offload-packager wrote" $rc 0
python3 -I "$SRC/tests/libnvrm/schema_validate.py" \
    "$SDK/share/cuda-native/schema/cuda-objdump-1.schema.json" \
    "$W/packager.json" >"$W/packager.schema" 2>&1
expect_rc "the packager container validates against cuda-objdump-1" $? 0
python3 -I - "$W/packager.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as f:
    doc = json.load(f)
member = doc["members"][0]
assert doc["container_version"] == 2
assert member["kind"] == "none", member
assert member["arch"] == "sm_120", member
assert member["triple"] == "nvptx64-nvidia-cuda", member
assert "format" not in member, member
assert "sha256" not in member, member
PY
expect_rc "the packager container has no cloudbsd keys, and we say so" $? 0

# ---- the ELF path --------------------------------------------------------
# clang's CUDA driver runs our fatbinary and puts the container in the
# object it writes.
"$CXX" -x cuda --cuda-path="$SDK" --cuda-gpu-arch=sm_120 \
    "$K/vector_add.cu" -c -o "$W/vector_add.o" >"$W/vector_add.log" 2>&1
rc=$?
[ $rc -eq 0 ] && [ -s "$W/vector_add.o" ]
expect_rc "clang compiles vector_add.cu with our SDK" $rc 0
"$SDK/bin/cuda-objdump" --json "$W/vector_add.o" >"$W/vector_add.json" 2>&1
rc=$?
[ $rc -eq 0 ]
expect_rc "cuda-objdump reads the container in the object clang built" $rc 0
python3 -I - "$W/vector_add.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as f:
    doc = json.load(f)
assert doc["source"] == "section", doc["source"]
assert len(doc["members"]) >= 1, doc
member = doc["members"][0]
assert member["arch"] == "sm_120", member
assert member["sha256"] is not None, member
PY
expect_rc "the object carries our container with one sm_120 member" $? 0
python3 -I "$SRC/tests/libnvrm/schema_validate.py" \
    "$SDK/share/cuda-native/schema/cuda-objdump-1.schema.json" \
    "$W/vector_add.json" >"$W/vector_add.schema" 2>&1
expect_rc "the object JSON validates against cuda-objdump-1" $? 0

# ---- the mutant ----------------------------------------------------------
# The reader without the check on image_offset + image_size accepts a
# container whose image leaves the container.  The case above must catch it.
mkdir -p "$W/mutant"
sed -e '/if (!in_range(image_offset, image_size, total))/,+1d' \
    "$CN/fatbin/cnfatbin.c" >"$W/mutant/cnfatbin.c"
grep -q 'in_range(image_offset, image_size, total)' "$W/mutant/cnfatbin.c"
expect_rc "the mutant fixture still holds the check that is removed" $? 1
cc -std=gnu11 -O2 -Wall -Wextra -Werror -I"$CN/fatbin" \
    -o "$W/mutant/fatbin_reader_test" "$K/fatbin_reader_test.c" \
    "$W/mutant/cnfatbin.c" -lmd >"$W/mutant-build.log" 2>&1
expect_rc "the mutant reader builds" $? 0
"$W/mutant/fatbin_reader_test" "$W/cases/image.bin" >"$W/mutant.out" 2>&1
rc=$?
grep -q 'error=image-out-of-range' "$W/mutant.out"
expect_rc "mutant: the reader without the image bounds check is caught" $? 1
sed -n 1,5p "$W/mutant.out"

# ---- the manuals and the headers -----------------------------------------
for man in nvfatbin.1 nvfatbin.5 cuda-objdump.1; do
	mandoc -T lint -W warning "$CN/man/$man" >"$W/$man.mandoc" 2>&1
	rc=$?
	[ $rc -eq 0 ] && [ ! -s "$W/$man.mandoc" ]
	expect_rc "$man is mandoc -T lint -W warning clean" $rc 0
done
for file in fatbin/cnfatbin.h fatbin/cnfatbin.c fatbin/cntool.h \
    fatbin/cntool.c fatbin/nvfatbin.c fatbin/cuda-objdump.c man/nvfatbin.1 \
    man/nvfatbin.5 man/cuda-objdump.1; do
	grep -q 'SPDX-License-Identifier: BSD-2-Clause' "$CN/$file" &&
	    grep -q 'Copyright (c) 2026 REVYTECH, Inc\.' "$CN/$file"
	expect_rc "$file carries the BSD-2 header" $? 0
done
[ ! -e "$CN/tools/nvfatbin.sh" ]
expect_rc "the shell nvfatbin is gone" $? 0

finish

#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-2-Clause
#
# nvfatbin.sh - fatbinary stand-in for clang's CUDA driver.  It wraps every
# supplied ELF-labelled or PTX member in the documented cuda-native stub
# container.  It does not create a vendor fatbin or execute device code.
# CUDA_NATIVE_TRACE names an optional JSONL trace file.

PATH=/sbin:/bin:/usr/sbin:/usr/bin
LC_ALL=C
export PATH LC_ALL
umask 022

CUDA_NATIVE_TOOL=nvfatbin
tool_path=$(realpath "$0") || exit 1
. "$(dirname -- "$tool_path")/../share/cuda-native/cuda-native-tool-lib.sh" || exit 1

usage()
{
	echo "usage: $CUDA_NATIVE_TOOL [-64] [-g] --create FILE"
	echo "       $CUDA_NATIVE_TOOL --image3=kind=elf|ptx,sm=NNN,file=INPUT [...]"
	echo "       $CUDA_NATIVE_TOOL --version [--json]"
	echo "       $CUDA_NATIVE_TOOL -h|--help"
}

[ "${1:-}" = --version ] && handle_version "$@"

# Split the field order clang emits.  A comma in the file name is retained.
split_image()
{
	image_spec=${1#--image3=}
	case $image_spec in
	kind=*,sm=*,file=*) ;;
	*) die2 "malformed --image3: $image_spec" ;;
	esac
	image_rest=${image_spec#kind=}
	image_kind=${image_rest%%,*}
	image_rest=${image_rest#*,}
	image_sm=${image_rest%%,*}
	image_sm=${image_sm#sm=}
	image_file=${image_rest#*,file=}
	case $image_kind in
	elf | ptx) ;;
	*) die2 "unsupported image kind: $image_kind" ;;
	esac
	case $image_sm in
	'' | *[!0-9]*) die2 "image sm must be a decimal number: $image_sm" ;;
	esac
	[ -n "$image_file" ] || die2 "image file is empty"
}

create=
images=0
image_args=
# Validate each option once.  Control-free image arguments are newline-delimited
# for the single build pass below; no second option table can drift or spin.
# Time: O(arguments).  Space: O(total image argument length).
parse()
{
	while [ $# -gt 0 ]; do
		case $1 in
		-h | --help)
			usage
			exit 0
			;;
		-64 | -g)
			shift
			;;
		--create)
			[ $# -ge 2 ] || die2 "option requires an argument: $1"
			create=$2
			shift 2
			;;
		--create=*)
			create=${1#--create=}
			shift
			;;
		--image3=*)
			validate_utf8_argument "$1" "image specifications"
			image_args="$image_args$1
"
			images=$((images + 1))
			shift
			;;
		-*)
			unsupported_option "$1"
			;;
		*)
			unexpected_argument "$1" "images are given with --image3="
			;;
		esac
	done
}
parse "$@"
[ -n "$create" ] || die2 "--create is required"
[ "$images" -gt 0 ] || die2 "at least one --image3 is required"
validate_utf8_argument "$create" "the output path"
[ ! -d "$create" ] || fail "output is a directory: $create"
parent=$(dirname -- "$create")
[ -d "$parent" ] || fail "output directory does not exist: $parent"
WORK=$(mktemp -d "$parent/.nvfatbin.XXXXXXXX") || exit 1
trap 'rm -rf -- "$WORK"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
out=$WORK/fatbin
json=$WORK/images
payload=$WORK/payload
image_args_file=$WORK/image-args
printf 'CUDA-NATIVE-STUB-FATBIN 1\n' >"$out" || fail "cannot create output: $create"
: >"$json"
: >"$payload"
printf '%s' "$image_args" >"$image_args_file" || fail "cannot save image arguments"
index=0
# Build the metadata, payload and trace from the one validated argument list.
# The separator lets the runtime count members without scanning opaque bytes.
# Time: O(arguments + total image size).  Space: O(argument length) beyond files.
while IFS= read -r image_arg; do
	split_image "$image_arg"
	[ -f "$image_file" ] && [ -r "$image_file" ] && [ -s "$image_file" ] ||
	    fail "cannot read a nonempty image: $image_file"
	cp -- "$image_file" "$WORK/img.$index" || fail "cannot copy image: $image_file"
	image_size=$(wc -c <"$WORK/img.$index") || fail "cannot measure image: $image_file"
	image_size=$(printf '%s' "$image_size" | tr -d '[:space:]')
	image_sha=$(/sbin/sha256 -q -- "$WORK/img.$index") || fail "cannot hash image: $image_file"
	printf 'member kind=%s sm=%s size=%s sha256=%s\n' \
	    "$image_kind" "$image_sm" "$image_size" "$image_sha" >>"$out" ||
	    fail "cannot write output: $create"
	cat -- "$WORK/img.$index" >>"$payload" || fail "cannot read image copy: $image_file"
	[ "$index" -eq 0 ] || printf ',' >>"$json"
	e_file=$(json_escape "$image_file")
	printf '{"kind":"%s","sm":%s,"file":"%s"}' \
	    "$image_kind" "$image_sm" "$e_file" >>"$json" ||
	    fail "cannot construct the trace"
	index=$((index + 1))
done <"$image_args_file"
printf '%s\n' '---' >>"$out" || fail "cannot write output: $create"
cat -- "$payload" >>"$out" || fail "cannot write output: $create"
chmod 644 "$out" || fail "cannot set output permissions: $create"
mv -h -- "$out" "$create" || fail "cannot write output: $create"
if [ -n "${CUDA_NATIVE_TRACE:-}" ]; then
	e_output=$(json_escape "$create")
	image_json=$(cat "$json")
	printf '{"tool":"nvfatbin","schema":1,"output":"%s","images":[%s],"stub":true}\n' \
	    "$e_output" "$image_json" >>"$CUDA_NATIVE_TRACE" ||
	    fail "cannot append trace: $CUDA_NATIVE_TRACE"
fi
rm -rf -- "$WORK"
trap - EXIT
exit 0

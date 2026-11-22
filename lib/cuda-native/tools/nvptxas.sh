#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-2-Clause
#
# nvptxas.sh - fail-obvious ptxas stand-in for clang's CUDA driver.  The PTX
# input is preserved after a cuda-native cubin-placeholder header; no machine
# code is assembled and no GPU execution is implied.  CUDA_NATIVE_TRACE names
# an optional JSONL trace file.

PATH=/sbin:/bin:/usr/sbin:/usr/bin
export PATH
umask 022

CUDA_NATIVE_TOOL=nvptxas
. "$(dirname -- "$0")/../share/cuda-native/cuda-native-tool-lib.sh" || exit 1

usage()
{
	echo "usage: ptxas [-m64] [-O0..-O3] --gpu-name ARCH --output-file FILE INPUT.ptx"
	echo "       ptxas --version [--json]"
}

if [ "${1:-}" = --version ]; then
	if [ $# -gt 2 ]; then
		case $3 in
		-*) unsupported_option "$3" ;;
		*) unexpected_argument "$3" "only --json may follow --version" ;;
		esac
	fi
	if [ $# -eq 1 ]; then
		show_version text
	elif [ "$2" = --json ]; then
		show_version json
	else
		case $2 in
		-*) unsupported_option "$2" ;;
		*) unexpected_argument "$2" "only --json may follow --version" ;;
		esac
	fi
	exit 0
fi

arch=
input=
output=
# Time: O(arguments).  Space: O(1); only the three current values are kept.
while [ $# -gt 0 ]; do
	case $1 in
	-h | --help)
		usage
		exit 0
		;;
	-m64 | -O0 | -O1 | -O2 | -O3 | -g | -lineinfo | --dont-merge-basicblocks | --return-at-end)
		shift
		;;
	--gpu-name)
		[ $# -ge 2 ] || die2 "option requires an argument: $1"
		arch=$2
		shift 2
		;;
	--gpu-name=*)
		arch=${1#--gpu-name=}
		shift
		;;
	--output-file)
		[ $# -ge 2 ] || die2 "option requires an argument: $1"
		output=$2
		shift 2
		;;
	--output-file=*)
		output=${1#--output-file=}
		shift
		;;
	-*)
		unsupported_option "$1"
		;;
	*)
		[ -z "$input" ] || unexpected_argument "$1" "only one PTX input is accepted"
		input=$1
		shift
		;;
	esac
done
[ -n "$arch" ] || die2 "--gpu-name is required"
[ -n "$output" ] || die2 "--output-file is required"
[ -n "$input" ] || die2 "one PTX input is required"
case $arch$input$output in
*[[:cntrl:]]*) die2 "control characters in arguments are not supported" ;;
esac
arch_tail=${arch#sm_}
case $arch_tail in
*[af]) arch_digits=${arch_tail%?} ;;
*) arch_digits=$arch_tail ;;
esac
case $arch in
sm_*) ;;
*) arch_digits= ;;
esac
case $arch_digits in
'' | *[!0-9]*) die2 "--gpu-name must be sm_<N> with an optional a or f suffix: $arch" ;;
esac
[ -f "$input" ] && [ -r "$input" ] && [ -s "$input" ] ||
    fail "cannot read a nonempty PTX input: $input"
target_count=$(grep -c '^[[:space:]]*\.target[[:space:]]' "$input")
case $target_count in
0) fail "input has no .target line: $input" ;;
1) ;;
*) fail "input has multiple .target lines: $input" ;;
esac
target=$(sed -n 's/^[[:space:]]*\.target[[:space:]]*\([^[:space:],]*\).*$/\1/p' "$input")
[ -n "$target" ] || fail "input has an empty .target architecture: $input"
[ "$target" = "$arch" ] ||
    fail ".target $target does not match --gpu-name $arch"
ptx_sha=$(/sbin/sha256 -q "$input") || fail "cannot hash PTX input: $input"

[ ! -d "$output" ] || fail "output is a directory: $output"
parent=$(dirname -- "$output")
[ -d "$parent" ] || fail "output directory does not exist: $parent"
tmp=$(mktemp "$parent/.nvptxas.XXXXXXXX") || exit 1
trap 'rm -f -- "$tmp"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
{
	printf 'CUDA-NATIVE-STUB-CUBIN 1\narch=%s\nptx-sha256=%s\n---\n' "$arch" "$ptx_sha"
	cat -- "$input"
} >"$tmp" || fail "cannot write cubin placeholder: $output"
mv -h -- "$tmp" "$output" || fail "cannot write output: $output"
trap - EXIT

if [ -n "${CUDA_NATIVE_TRACE:-}" ]; then
	e_arch=$(json_escape "$arch")
	e_input=$(json_escape "$input")
	e_output=$(json_escape "$output")
	printf '{"tool":"nvptxas","schema":1,"arch":"%s","input":"%s","output":"%s","stub":true}\n' \
	    "$e_arch" "$e_input" "$e_output" >>"$CUDA_NATIVE_TRACE" ||
	    fail "cannot append trace: $CUDA_NATIVE_TRACE"
fi
exit 0

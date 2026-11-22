# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-2-Clause
#
# Shared helpers for the nvptxas and nvfatbin stubs.  The caller sets
# CUDA_NATIVE_TOOL to its canonical name before sourcing this file.  mksdk.sh
# substitutes all four version fields from CUDA_NATIVE_VERSION in cuda.h.

CUDA_NATIVE_VERSION='@CUDA_NATIVE_VERSION@'
CUDA_NATIVE_VERSION_MAJOR='@CUDA_NATIVE_VERSION_MAJOR@'
CUDA_NATIVE_VERSION_MINOR='@CUDA_NATIVE_VERSION_MINOR@'
CUDA_NATIVE_VERSION_PATCH='@CUDA_NATIVE_VERSION_PATCH@'

die2()
{
	echo "$CUDA_NATIVE_TOOL: $*" >&2
	exit 2
}

fail()
{
	echo "$CUDA_NATIVE_TOOL: $*" >&2
	exit 1
}

unsupported_option()
{
	case $CUDA_NATIVE_TOOL in
	nvptxas) manual=nvptxas ;;
	nvfatbin) manual=nvfatbin ;;
	esac
	die2 "unsupported option $1; not supported by the cuda-native stub; see $manual(1); use -h for usage"
}

unexpected_argument()
{
	die2 "unexpected argument $1; $2"
}

show_version()
{
	if [ "$1" = json ]; then
		printf '{"tool":"%s","version":"%s","version_major":%s,"version_minor":%s,"version_patch":%s,"stub":true,"track":"2427"}\n' \
		    "$CUDA_NATIVE_TOOL" "$CUDA_NATIVE_VERSION" "$CUDA_NATIVE_VERSION_MAJOR" \
		    "$CUDA_NATIVE_VERSION_MINOR" "$CUDA_NATIVE_VERSION_PATCH"
	else
		printf '%s (cuda-native) %s stub\n' "$CUDA_NATIVE_TOOL" "$CUDA_NATIVE_VERSION"
	fi
}

# JSON string contents from clang's path arguments.  Reject line breaks in the
# caller; sed escapes the two JSON metacharacters and horizontal tabs.
# Time: O(argument length).  Space: O(argument length).
json_escape()
{
	printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/	/\\t/g'
}

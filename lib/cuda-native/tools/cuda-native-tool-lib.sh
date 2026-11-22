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
	die2 "unsupported option $1; not supported by the cuda-native stub; see $CUDA_NATIVE_TOOL(1); use -h for usage"
}

unexpected_argument()
{
	die2 "unexpected argument $1; $2"
}

# Accept every valid UTF-8 sequence, but no ASCII/control bytes.  od exposes
# the original bytes even under LC_ALL=C; awk enforces shortest forms, excludes
# surrogates and stops at U+10FFFF.  Shell arguments cannot contain NUL.
validate_utf8_argument()
{
	case $1 in
	*[[:cntrl:]]*) die2 "control characters in $2 are not supported" ;;
	esac
	printf '%s' "$1" | od -An -v -tu1 | awk '
	BEGIN { left = 0; bad = 0 }
	{
		# Time: O(argument bytes).  Space: O(bytes per od output line).
		for (i = 1; i <= NF; i++) {
			byte = $i + 0
			if (left > 0) {
				if (byte < low || byte > high)
					bad = 1
				left--
				low = 128
				high = 191
				continue
			}
			if (byte <= 127)
				continue
			low = 128
			high = 191
			if (byte >= 194 && byte <= 223)
				left = 1
			else if (byte == 224) {
				left = 2
				low = 160
			} else if ((byte >= 225 && byte <= 236) || byte == 238 || byte == 239)
				left = 2
			else if (byte == 237) {
				left = 2
				high = 159
			} else if (byte == 240) {
				left = 3
				low = 144
			} else if (byte >= 241 && byte <= 243)
				left = 3
			else if (byte == 244) {
				left = 3
				high = 143
			} else
				bad = 1
		}
	}
	END { exit (bad || left != 0) ? 1 : 0 }
	' || die2 "invalid UTF-8 in $2"
}

handle_version()
{
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

# JSON string contents from clang's path arguments.  The caller rejects control
# bytes and malformed UTF-8; valid UTF-8 passes through and sed escapes JSON
# metacharacters.
# Time: O(argument length).  Space: O(argument length).
json_escape()
{
	printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/	/\\t/g'
}

#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# preflight_platform_test.sh - make.sh preflight accepts FreeBSD amd64 as
# well as aarch64 (Track #2475). Run as a normal user. Scratch under
# WORK/tmp, never /tmp.
#   (a) On a live FreeBSD amd64 host, platform is ok and the fix does not
#       send the user to `pkg install nvidia-driver`.
#   (b) On a live FreeBSD aarch64 host, platform stays ok (the arm64 path
#       is unchanged).
#   (c) With test hooks, FreeBSD/amd64 and FreeBSD/aarch64 are both ok,
#       and a non-FreeBSD or other-arch host is missing without the
#       nvidia-driver redirect. The hook probe itself must pass on every
#       host: it is not waived on amd64, because a waiver there hid the
#       broken hook plumbing on aarch64 (Track #2475).
#   (d) On hooked or live amd64, without a foreign drm.ko, the drm.ko item
#       is missing and tells the user to install FreeBSD's drm-kmod
#       packages; with a foreign drm.ko, the item is ok and we do not
#       offer to install our own drm.ko.
# The MK_* switches of a calling make are cleared first.

set -u
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
export PATH
unset MK_WORK MK_PREFIX MK_DESTDIR MK_SYSDIR MK_BSDSRCTOP MK_DRMKMODDIR \
    MK_YES MK_ASSUME_YES MK_JSON MK_JSONL MK_PURPOSE MK_ACCEPT_NVIDIA_LICENSE \
    MK_ACCEPT_ALL_LICENSES
# The live checks must see a live host: a hook variable inherited from the
# environment would make them report the hooked platform instead. The
# hooked cases below set the hooks they need themselves.
unset GB10_TEST_HOOKS GB10_TEST_OS GB10_TEST_ARCH
repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
base=${GB10_WORK:-$repo/work}
mkdir -p -- "$base/tmp"
S=$(mktemp -d "$base/tmp/preflight_platform.XXXXXX") || exit 1
trap 'if [ "${KEEP_SCRATCH:-0}" = 1 ]; then printf "scratch: %s\n" "$S"; else chmod -R u+w "$S" 2>/dev/null; rm -rf -- "$S"; fi' EXIT
fail=0
ok() { printf 'ok    %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1"; fail=$((fail + 1)); }

# mk: run make.sh preflight --json in a child process.
#
# A prefix assignment on a shell function call is not reliably exported to
# the children that function starts. FreeBSD sh keeps it local to the
# function, so the `env ... sh make.sh' child never saw the hook variables:
# metadata.os/metadata.arch stayed at uname and the hook probe failed
# (Track #2475). The hook variables the caller set are therefore handed to
# the child explicitly on the env line, so the child always receives them.
mk() {
	set -- MK_WORK="$W"
	# ${VAR:-} is safe under set -u and is supported by every shell we
	# run on, so the check works in FreeBSD sh as well as in dash/bash.
	if [ -n "${GB10_TEST_HOOKS:-}" ]; then
		set -- "$@" "GB10_TEST_HOOKS=$GB10_TEST_HOOKS"
	fi
	if [ -n "${GB10_TEST_OS:-}" ]; then
		set -- "$@" "GB10_TEST_OS=$GB10_TEST_OS"
	fi
	if [ -n "${GB10_TEST_ARCH:-}" ]; then
		set -- "$@" "GB10_TEST_ARCH=$GB10_TEST_ARCH"
	fi
	env "$@" sh "$repo/scripts/make.sh" preflight --json
}

# item_field FILE NAME FIELD: print one JSON field of the named preflight item
item_field() {
	python3 -I - "$1" "$2" "$3" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
name, field = sys.argv[2], sys.argv[3]
items = [s for s in d["status"] if s["name"] == name]
assert items, "no item %r" % name
print(items[0].get(field, ""))
PY
}

W=$S/work
mkdir -p "$W"

os=$(uname -s)
arch=$(uname -p 2>/dev/null || uname -m)

# (a) (b) live host
mk > "$S/live.json" 2> "$S/live.err" || true
if [ "$os" = FreeBSD ] && [ "$arch" = amd64 ]; then
	state=$(item_field "$S/live.json" platform state) || state=err
	fix=$(item_field "$S/live.json" platform fix) || fix=
	reason=$(item_field "$S/live.json" platform reason) || reason=
	if [ "$state" = ok ] && ! printf '%s' "$fix$reason" | grep -q 'nvidia-driver'; then
		ok "(a) live FreeBSD amd64: platform ok, no nvidia-driver redirect"
	else
		bad "(a) live FreeBSD amd64: platform state=$state reason=$reason fix=$fix"
	fi
elif [ "$os" = FreeBSD ] && [ "$arch" = aarch64 ]; then
	state=$(item_field "$S/live.json" platform state) || state=err
	if [ "$state" = ok ]; then
		ok "(b) live FreeBSD aarch64: platform ok (unchanged)"
	else
		bad "(b) live FreeBSD aarch64: platform state=$state"
	fi
else
	ok "live platform check skipped (host is $os $arch, not FreeBSD amd64/aarch64)"
fi

# (c) hooks, when the script honours GB10_TEST_OS / GB10_TEST_ARCH
hook_probe() {
	# Distinctive values a live host never reports, so a real
	# FreeBSD/amd64 uname cannot look like a working hook.
	GB10_TEST_HOOKS=1 GB10_TEST_OS=HookOS GB10_TEST_ARCH=hookarch \
	    mk > "$S/hook-probe.json" 2> "$S/hook-probe.err" || true
	python3 -I - "$S/hook-probe.json" <<'J'
import json, sys
d = json.load(open(sys.argv[1]))
meta = d.get("metadata") or {}
sys.exit(0 if meta.get("os") == "HookOS" and meta.get("arch") == "hookarch" else 1)
J
}
if hook_probe; then
	# amd64 hooked (a fresh run, not the HookOS/hookarch probe file)
	GB10_TEST_HOOKS=1 GB10_TEST_OS=FreeBSD GB10_TEST_ARCH=amd64 \
	    mk > "$S/hook-amd64.json" 2> "$S/hook-amd64.err" || true
	state=$(item_field "$S/hook-amd64.json" platform state) || state=err
	fix=$(item_field "$S/hook-amd64.json" platform fix) || fix=
	reason=$(item_field "$S/hook-amd64.json" platform reason) || reason=
	if [ "$state" = ok ] && ! printf '%s' "$fix$reason" | grep -q 'nvidia-driver'; then
		ok "(c) hooked FreeBSD/amd64: platform ok, no nvidia-driver redirect"
	else
		bad "(c) hooked FreeBSD/amd64: state=$state reason=$reason fix=$fix"
	fi
	# aarch64 hooked
	GB10_TEST_HOOKS=1 GB10_TEST_OS=FreeBSD GB10_TEST_ARCH=aarch64 \
	    mk > "$S/hook-arm.json" 2> "$S/hook-arm.err" || true
	state=$(item_field "$S/hook-arm.json" platform state) || state=err
	if [ "$state" = ok ]; then
		ok "(c) hooked FreeBSD/aarch64: platform ok"
	else
		bad "(c) hooked FreeBSD/aarch64: state=$state"
	fi
	# other OS
	GB10_TEST_HOOKS=1 GB10_TEST_OS=Linux GB10_TEST_ARCH=x86_64 \
	    mk > "$S/hook-linux.json" 2> "$S/hook-linux.err" || true
	state=$(item_field "$S/hook-linux.json" platform state) || state=err
	fix=$(item_field "$S/hook-linux.json" platform fix) || fix=
	reason=$(item_field "$S/hook-linux.json" platform reason) || reason=
	if [ "$state" = missing ] && ! printf '%s' "$fix$reason" | grep -q 'nvidia-driver'; then
		ok "(c) hooked Linux: platform missing, no nvidia-driver redirect"
	else
		bad "(c) hooked Linux: state=$state reason=$reason fix=$fix"
	fi
else
	# The hook probe is a hard failure on every host, including a live
	# amd64 one. A live amd64 host used to waive it, and that waiver is
	# exactly what hid the broken hook plumbing on aarch64 (Track #2475):
	# the probe has to fail where it fails.
	bad "(c) GB10_TEST_OS/GB10_TEST_ARCH hooks not honoured (needed to test amd64 off this host)"
fi

# (d) amd64 drm.ko policy: never build our own; use FreeBSD drm-kmod
# A user-owned DESTDIR with no drm.ko.
D=$S/dest-empty
mkdir -p "$D"
if [ "$os" = FreeBSD ] && [ "$arch" = amd64 ]; then
	# The hook variables are cleared explicitly: this case asserts the
	# live amd64 policy, and a hook left over from the (c) cases must not
	# change what the child sees.
	env -u GB10_TEST_HOOKS -u GB10_TEST_OS -u GB10_TEST_ARCH \
	    MK_WORK="$W" MK_DESTDIR="$D" sh "$repo/scripts/make.sh" preflight --json \
	    > "$S/drm-missing.json" 2> "$S/drm-missing.err" || true
	state=$(item_field "$S/drm-missing.json" drm.ko state) || state=err
	fix=$(item_field "$S/drm-missing.json" drm.ko fix) || fix=
	reason=$(item_field "$S/drm-missing.json" drm.ko reason) || reason=
	if [ "$state" = missing ] && printf '%s %s' "$fix" "$reason" | grep -Eq 'drm-kmod|drm.ko'; then
		if printf '%s' "$reason" | grep -q 'make install installs drm.ko'; then
			bad "(d) empty DESTDIR on amd64 still offers to install our drm.ko: $reason"
		else
			ok "(d) empty DESTDIR on amd64: drm.ko missing, points at FreeBSD drm-kmod"
		fi
	else
		bad "(d) empty DESTDIR on amd64: drm.ko state=$state reason=$reason fix=$fix"
	fi
	# plant a foreign drm.ko
	mkdir -p "$D/boot/modules"
	printf 'foreign\n' > "$D/boot/modules/drm.ko"
	env -u GB10_TEST_HOOKS -u GB10_TEST_OS -u GB10_TEST_ARCH \
	    MK_WORK="$W" MK_DESTDIR="$D" sh "$repo/scripts/make.sh" preflight --json \
	    > "$S/drm-foreign.json" 2> "$S/drm-foreign.err" || true
	state=$(item_field "$S/drm-foreign.json" drm.ko state) || state=err
	reason=$(item_field "$S/drm-foreign.json" drm.ko reason) || reason=
	if [ "$state" = ok ] && ! printf '%s' "$reason" | grep -q 'make install installs drm.ko'; then
		ok "(d) foreign drm.ko on amd64: item ok, we do not install our own"
	else
		bad "(d) foreign drm.ko on amd64: state=$state reason=$reason"
	fi
else
	ok "(d) amd64 drm.ko policy skipped (host is $os $arch)"
fi

if [ "$fail" -ne 0 ]; then
	printf 'FAILED %s checks\n' "$fail"
	exit 1
fi
printf 'all ok\n'
exit 0

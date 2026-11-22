#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# Offline tests for scripts/fetch-nvidia-smi.sh (the checksum-verified fetch
# and unpack of NVIDIA's Linux arm64 nvidia-smi).  A fake installer is built
# here - a text header with a skip= line, then a zstd-compressed tar holding a
# stand-in nvidia-smi and libnvidia-ml.so.<version> - and fetch(1) is replaced
# through the FETCH test hook, SOURCES through the SOURCES hook (both honoured
# only with GB10_TEST_HOOKS=1); nothing touches the network.  Scratch files
# live in a mktemp(1) directory under $(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)/work/tmp, never /tmp.
#
# Usage: sh tests/fetch-nvidia-smi_test.sh
# Exit:  0 when every case passes, 1 otherwise; each case prints PASS/FAIL.

set -u

PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
script=$repo/scripts/fetch-nvidia-smi.sh

test_dir=$(mktemp -d "$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)/work/tmp/fetch-smi-test.XXXXXXXX") || exit 1
trap 'rm -rf "$test_dir"' EXIT INT TERM
chmod 700 "$test_dir"

passed=0
failed=0
ok() { echo "PASS: $1"; passed=$((passed + 1)); }
bad() { echo "FAIL: $1"; failed=$((failed + 1)); }

ver=9.9.9
# The fake payload: nvidia-smi prints its library path so the wrapper's
# LD_LIBRARY_PATH can be checked; the library is a plain file.
mkdir -p "$test_dir/payload"
printf '#!/bin/sh\necho "fake-smi lib=$LD_LIBRARY_PATH args=$*"\n' > "$test_dir/payload/nvidia-smi"
chmod 755 "$test_dir/payload/nvidia-smi"
printf 'lib\n' > "$test_dir/payload/libnvidia-ml.so.$ver"
printf 'other\n' > "$test_dir/payload/unrelated-file"
# Header of 4 lines; the payload starts on line 5.
{
	printf '#!/bin/sh\n'
	printf 'skip=5\n'
	printf 'echo this installer must never run\n'
	printf 'exit 0\n'
	tar -C "$test_dir/payload" -cf - nvidia-smi "libnvidia-ml.so.$ver" unrelated-file | zstd -q -c
} > "$test_dir/good.run"
good_sha=$(sha256 -q "$test_dir/good.run")
printf 'not an installer\n' > "$test_dir/bad.run"

# fake_fetch <file> - a FETCH stub that "downloads" <file> to the -o path.
fake_fetch() {
	printf '#!/bin/sh\n# fetch -o <out> <url>\n[ "$1" = -o ] || exit 2\ncp -- "%s" "$2"\n' "$1" \
	    > "$test_dir/fetch-stub"
	chmod 755 "$test_dir/fetch-stub"
}

# sources <sha> <skip> [omit-key] - write a SOURCES file with these pins.
sources() {
	{
		echo "ogkm_tag $ver"
		echo "nvidia_linux_aarch64_url https://download.example.invalid/x/NVIDIA-Linux-aarch64-$ver.run"
		echo "nvidia_linux_aarch64_sha256 $1"
		echo "nvidia_linux_aarch64_skip $2"
	} | grep -v "^${3:-no-such-key} " > "$test_dir/SOURCES"
}

# run <destdir> - run the script with the hooks; output in $test_dir/out.
run() {
	GB10_TEST_HOOKS=1 FETCH=$test_dir/fetch-stub SOURCES=$test_dir/SOURCES \
	    sh "$script" "$1" > "$test_dir/out" 2>&1
}

# (a) good installer: unpacked, only the two files, wrapper runs with the
# right library path, installer header never executed.
fake_fetch "$test_dir/good.run"
sources "$good_sha" 5
d=$test_dir/dest-a
mkdir -m 700 "$d"
if run "$d" && [ -x "$d/x/nvidia-smi" ] && [ -f "$d/x/libnvidia-ml.so.$ver" ] \
    && [ ! -e "$d/x/unrelated-file" ] && [ -L "$d/lib/libnvidia-ml.so.1" ] \
    && "$d/nvidia-smi" -L | grep -qx "fake-smi lib=$d/lib args=-L" \
    && ! grep -q 'must never run' "$test_dir/out"; then
	ok "(a) good installer: two files unpacked, wrapper sets LD_LIBRARY_PATH"
else
	bad "(a) good installer: $(cat "$test_dir/out")"
fi

# (b) second run with the file already present: no download, same result.
printf '#!/bin/sh\nexit 1\n' > "$test_dir/fetch-stub"
if run "$d" && grep -q 'ok (cached)' "$test_dir/out" && [ -x "$d/x/nvidia-smi" ]; then
	ok "(b) cached installer is re-verified, not re-downloaded"
else
	bad "(b) cached: $(cat "$test_dir/out")"
fi

# (c) checksum mismatch: exit 1, nothing unpacked, the download not kept.
fake_fetch "$test_dir/bad.run"
d=$test_dir/dest-c
mkdir -m 700 "$d"
if ! run "$d" && grep -q 'sha256 mismatch' "$test_dir/out" && [ ! -e "$d/x" ] \
    && [ -z "$(ls "$d")" ]; then
	ok "(c) checksum mismatch: exit 1, nothing unpacked or kept"
else
	bad "(c) mismatch: rc=$? $(cat "$test_dir/out"); $(ls "$d")"
fi

# (d) a pin missing from SOURCES: exit 1 before any download.
printf '#!/bin/sh\ntouch "%s/fetched"\nexit 1\n' "$test_dir" > "$test_dir/fetch-stub"
sources "$good_sha" 5 nvidia_linux_aarch64_sha256
d=$test_dir/dest-d
mkdir -m 700 "$d"
if ! run "$d" && grep -q 'no nvidia_linux_aarch64_sha256' "$test_dir/out" \
    && [ ! -e "$test_dir/fetched" ]; then
	ok "(d) missing sha256 pin: exit 1 before fetching"
else
	bad "(d) missing pin: $(cat "$test_dir/out")"
fi

# (e) malformed pins: a short sha256, a non-numeric skip.
sources abc123 5
if ! run "$d" && grep -q 'not 64 lowercase hex' "$test_dir/out"; then
	ok "(e1) malformed sha256 pin refused"
else
	bad "(e1) malformed sha256: $(cat "$test_dir/out")"
fi
sources "$good_sha" '5;rm'
if ! run "$d" && grep -q 'skip is not a line number' "$test_dir/out"; then
	ok "(e2) malformed skip pin refused"
else
	bad "(e2) malformed skip: $(cat "$test_dir/out")"
fi

# (f) right checksum, wrong skip: the payload line is not zstd, so nothing
# is unpacked (a stale skip after a version bump must not unpack garbage).
fake_fetch "$test_dir/good.run"
sources "$good_sha" 3
d=$test_dir/dest-f
mkdir -m 700 "$d"
if ! run "$d" && grep -q 'not a zstd stream' "$test_dir/out" && [ ! -e "$d/x" ]; then
	ok "(f) wrong skip: payload check fails, nothing unpacked"
else
	bad "(f) wrong skip: $(cat "$test_dir/out")"
fi

# (g) DESTDIR that is a symlink, or writable by group: refused.
sources "$good_sha" 5
mkdir -m 700 "$test_dir/real-g"
ln -s "$test_dir/real-g" "$test_dir/dest-g"
if ! run "$test_dir/dest-g" && grep -q 'symlink' "$test_dir/out" \
    && [ -z "$(ls "$test_dir/real-g")" ]; then
	ok "(g1) symlinked DESTDIR refused"
else
	bad "(g1) symlink DESTDIR: $(cat "$test_dir/out")"
fi
mkdir -m 770 "$test_dir/dest-g2"
if ! run "$test_dir/dest-g2" && grep -q 'writable by group or other' "$test_dir/out"; then
	ok "(g2) group-writable DESTDIR refused"
else
	bad "(g2) group-writable DESTDIR: $(cat "$test_dir/out")"
fi

# (h) without GB10_TEST_HOOKS the hooks are ignored. The fake SOURCES has a
# bad sha256 pin and FETCH a stub; with the hooks ignored the repo's own
# (good) pins are read, so the run must get PAST the pin checks and stop at
# the group-writable DESTDIR - before any download, so no network is used.
sources abc123 5
printf '#!/bin/sh\ntouch "%s/fetched-h"\nexit 7\n' "$test_dir" > "$test_dir/fetch-stub"
if ! FETCH=$test_dir/fetch-stub SOURCES=$test_dir/SOURCES sh "$script" "$test_dir/dest-g2" \
        > "$test_dir/out" 2>&1 \
    && ! grep -q 'not 64 lowercase hex' "$test_dir/out" \
    && grep -q 'writable by group or other' "$test_dir/out" \
    && [ ! -e "$test_dir/fetched-h" ]; then
	ok "(h) hooks ignored without GB10_TEST_HOOKS (repo pins read)"
else
	bad "(h) without GB10_TEST_HOOKS: $(cat "$test_dir/out")"
fi

echo "passed: $passed failed: $failed"
[ "$failed" -eq 0 ]

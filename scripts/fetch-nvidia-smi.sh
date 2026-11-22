#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# fetch-nvidia-smi.sh - fetch NVIDIA's Linux arm64 driver installer pinned in
# SOURCES, verify its sha256, and unpack only nvidia-smi and libnvidia-ml.so
# from it (NVIDIA's installer script is never run). nvidia-smi then runs
# through the Linuxulator against the FreeBSD nvidia.ko of the same version.
#
# Usage: scripts/fetch-nvidia-smi.sh [DESTDIR]
#   DESTDIR defaults to ${GB10_WORK:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)/work}/nvidia-smi. It must not
#   be a symlink, must be owned by this user and must not be writable by
#   group or other. Afterwards:
#     DESTDIR/nvidia-smi     wrapper to run (sets LD_LIBRARY_PATH itself)
#     DESTDIR/x/             nvidia-smi and libnvidia-ml.so.<version>
#     DESTDIR/lib/           libnvidia-ml.so.1 -> ../x/libnvidia-ml.so.<version>
#     DESTDIR/<installer>    the verified download, kept so a rerun needs no fetch
#
# Pins read from SOURCES (each format-checked before use):
#   nvidia_linux_aarch64_url     https:// URL of the installer
#   nvidia_linux_aarch64_sha256  its sha256 (64 lowercase hex)
#   nvidia_linux_aarch64_skip    line where the installer's zstd payload starts
#   ogkm_tag                     the driver version (library file suffix)
#
# Test hooks FETCH and SOURCES are honoured only with GB10_TEST_HOOKS=1 (see
# lib.sh test_hook); otherwise the fixed fetch(1) and the repo's SOURCES are
# used.
#
# Exit: 0 unpacked; 1 any failure (bad pin, unsafe DESTDIR, download,
# checksum, payload or unpack), with the reason on stderr. On a checksum
# mismatch the download is deleted and nothing is unpacked.

set -eu

PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$script_dir/lib.sh"

die() {
	echo "fetch-nvidia-smi: $*" >&2
	exit 1
}

FETCH=$(test_hook fetch-nvidia-smi FETCH /usr/bin/fetch) || exit 1
sources=$(test_hook fetch-nvidia-smi SOURCES "$script_dir/../SOURCES") || exit 1
[ -f "$sources" ] || die "missing SOURCES file: $sources"

# pin <key> - print <key>'s value from SOURCES, or stop.
pin() {
	_v=$(sources_get "$sources" "$1") && [ -n "$_v" ] || die "no $1 in SOURCES"
	printf '%s\n' "$_v"
}
url=$(pin nvidia_linux_aarch64_url) || exit 1
want_sha=$(pin nvidia_linux_aarch64_sha256) || exit 1
skip=$(pin nvidia_linux_aarch64_skip) || exit 1
ver=$(pin ogkm_tag) || exit 1

case $want_sha in
*[!0-9a-f]*) die "nvidia_linux_aarch64_sha256 is not 64 lowercase hex digits" ;;
esac
[ ${#want_sha} -eq 64 ] || die "nvidia_linux_aarch64_sha256 is not 64 lowercase hex digits"
case $skip in
'' | *[!0-9]* | 0*) die "nvidia_linux_aarch64_skip is not a line number: $skip" ;;
esac
case $url in
https://?*) ;;
*) die "nvidia_linux_aarch64_url is not an https:// URL: $url" ;;
esac
run=${url##*/}
case $run in
'' | . | .. | *[!A-Za-z0-9._+-]*) die "nvidia_linux_aarch64_url has no usable file name: $url" ;;
esac
case $ver in
'' | . | .. | *[!A-Za-z0-9._-]*) die "ogkm_tag is not one word of [A-Za-z0-9._-]: $ver" ;;
esac
lib=libnvidia-ml.so.$ver

destdir=${1:-${GB10_WORK:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)/work}/nvidia-smi}
# A symlink would pass the owner/mode check from the link itself while every
# write went through it, so it is refused before the stat.
[ ! -L "$destdir" ] || die "refusing DESTDIR $destdir: symlink"
mkdir -p -- "$destdir"
[ -d "$destdir" ] || die "refusing DESTDIR $destdir: not a directory"
st=$(stat -f '%u %Lp' -- "$destdir") || die "refusing DESTDIR $destdir: cannot stat it"
[ "${st%% *}" = "$(id -u)" ] || die "refusing DESTDIR $destdir: owned by uid ${st%% *}, not $(id -u)"
[ $((0${st##* } & 0022)) -eq 0 ] \
    || die "refusing DESTDIR $destdir: mode ${st##* } is writable by group or other"
destdir=$(CDPATH= cd -- "$destdir" && pwd)

for p in "$run" "$run.part" "$run.zst" x x.new lib nvidia-smi; do
	[ ! -L "$destdir/$p" ] || die "refusing $destdir/$p: symlink"
done

# --- download and verify ---------------------------------------------------
if [ -f "$destdir/$run" ] && [ "$(sha256 -q -- "$destdir/$run")" = "$want_sha" ]; then
	echo "ok (cached): $run"
else
	rm -f -- "$destdir/$run" "$destdir/$run.part"
	"$FETCH" -o "$destdir/$run.part" "$url" || { rm -f -- "$destdir/$run.part"; die "download failed: $url"; }
	got=$(sha256 -q -- "$destdir/$run.part") || { rm -f -- "$destdir/$run.part"; die "cannot checksum the download"; }
	if [ "$got" != "$want_sha" ]; then
		rm -f -- "$destdir/$run.part"
		die "sha256 mismatch: expected $want_sha got $got"
	fi
	mv -- "$destdir/$run.part" "$destdir/$run"
	echo "fetched: $run"
fi

# --- unpack the two files --------------------------------------------------
# The payload must start with the zstd magic (28 b5 2f fd) at line $skip: a
# stale skip after a version bump stops here instead of unpacking garbage.
tail -n +"$skip" -- "$destdir/$run" > "$destdir/$run.zst"
magic=$(head -c 4 -- "$destdir/$run.zst" | od -An -tx1 | tr -d ' \n')
if [ "$magic" != 28b52ffd ]; then
	rm -f -- "$destdir/$run.zst"
	die "line $skip of $run is not a zstd stream (got $magic); nvidia_linux_aarch64_skip is wrong for this installer"
fi
rm -rf -- "$destdir/x.new"
mkdir -- "$destdir/x.new"
# tar(1) reads the zstd file itself, so a decompression error is tar's exit
# status, not a hidden pipeline stage.
if ! tar -C "$destdir/x.new" -xf "$destdir/$run.zst" nvidia-smi "$lib"; then
	rm -rf -- "$destdir/x.new" "$destdir/$run.zst"
	die "unpacking nvidia-smi and $lib from $run failed"
fi
rm -f -- "$destdir/$run.zst"
[ -f "$destdir/x.new/nvidia-smi" ] && [ -f "$destdir/x.new/$lib" ] \
    || { rm -rf -- "$destdir/x.new"; die "$run does not hold nvidia-smi and $lib"; }
rm -rf -- "$destdir/x"
mv -- "$destdir/x.new" "$destdir/x"
mkdir -p -- "$destdir/lib"
ln -sfn -- "../x/$lib" "$destdir/lib/libnvidia-ml.so.1"

# The wrapper finds its own directory, so DESTDIR can be moved.
cat > "$destdir/nvidia-smi" <<'EOF'
#!/bin/sh
d=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 1
LD_LIBRARY_PATH="$d/lib" exec "$d/x/nvidia-smi" "$@"
EOF
chmod 755 "$destdir/nvidia-smi"
echo "nvidia-smi ready: $destdir/nvidia-smi"

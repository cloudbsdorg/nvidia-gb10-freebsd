#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# make-be.sh - build the one-shot test boot environment for kernel-patches/
# (Track #2442): the patched FreeBSD kernel, booted once on an Ampere Altra
# with an AMD GPU, recording every tunable, sysctl and dmesg line of the
# patches, the amdgpu load and a small GPU job, then returning to the
# normal boot environment.  Run as root.
#
# Usage: make-be.sh -s SRCDIR -o OBJDIR [-w WORK] [-b BASE_BE] [-N NORMAL_BE] [-U OWNER] [-B BENCH] [-M MODEL] [-D YYYYMMDD] [-n SEQ]
#   -s SRCDIR   the patched FreeBSD source tree the kernel was built from (it must
#               match the base BE's world: same __FreeBSD_version)
#   -o OBJDIR   the MAKEOBJDIRPREFIX of that build (buildkernel KERNCONF=GENERIC)
#   -w WORK     the work root (default: GB10_WORK; one of the two is required)
#   -b BASE_BE  the boot environment to clone (default NORMAL_BE)
#   -N NORMAL_BE the boot environment the host returns to (default cloudbsd-rx7600)
#   -U OWNER   the user that runs the GPU jobs and owns the copy-out (default:
#               the owner of WORK)
#   -B BENCH   the Vulkan llama-bench executable (default:
#               WORK/llm/b12627/build-vulkan/bin/llama-bench)
#   -M MODEL   the GGUF model (default: dirname(WORK)/models/Llama-3.2-3B-Instruct-Q4_K_M.gguf)
#   -D, -n      the name is kernel-patches-fix-test-<DATE>-<SEQ> (today, 1)
#
# What it does:
#   1. checks the build (the kernel file exists and carries the fixed code's
#      strings) and that the kernel's __FreeBSD_version is the base BE's;
#   2. bectl create -e BASE BE, mounts it on a new root-owned directory of /var/run;
#   3. make installkernel INSTKERNNAME=kernel.kpfix DESTDIR=<clone>: the
#      patched kernel goes to /boot/kernel.kpfix of the clone only;
#   4. copies the modules the base kernel directory has and the build does not
#      (the drm-kmod and amdgpu firmware modules, if_aq and the like) into
#      kernel.kpfix, then kldxref;
#   5. rewrites every kernel=, kern.panic_reboot_wait_time= and
#      debug.debugger_on_panic= line of the clone's loader files and writes
#      /boot/loader.conf.d/zzz-kernel-patches-test.conf in the clone:
#      kernel="kernel.kpfix", kern.panic_reboot_wait_time="5",
#      debug.debugger_on_panic="0"; and /etc/rc.conf.d/kld: the base kld_list
#      without amdgpu (the recorder loads it);
#   6. installs the recorder (kernel_patches_testboot), the vendored
#      testboot-return (sha256 pinned in VENDOR), the hash list and the version
#      file, enables the recorder and turns every other *_testboot_enable off;
#   7. unmounts.  It never activates: it prints the arm command.
# The running system is not changed: nothing is loaded and nothing is rebooted.
# check-be.sh checks the result.  WORK comes from -w or GB10_WORK (required).
# NORMAL_BE defaults to cloudbsd-rx7600.

set -eu
PATH=/sbin:/bin:/usr/sbin:/usr/bin
LC_ALL=C
export PATH LC_ALL

KITDIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH= cd -- "$KITDIR/../.." && pwd)
WORK=${GB10_WORK-}
NORMAL=cloudbsd-rx7600
BASE=
OWNER=
BENCH=
MODEL=
SRC=
OBJ=
DATE=$(date -u +%Y%m%d)
SEQ=1
KNAME=kernel.kpfix

usage() { sed -n '/^# Usage:/,/^#   -D/p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
need() { [ "$2" -ge 2 ] || { echo "make-be.sh: $1 needs a value" >&2; usage; }; }
as_owner() { su -m "$OWNER" -c '/bin/sh -c '\''exec "$0" "$@"'\'' "$0" "$@"' "$@"; }
filter_kld_list()
{
	_sep=
	for m in $1; do
		case ${m##*/} in
		amdgpu | amdgpu.ko) continue ;;
		esac
		printf '%s%s' "$_sep" "$m"
		_sep=' '
	done
	printf '\n'
}
while [ $# -gt 0 ]; do
	case $1 in
	-s) need "$1" "$#"; SRC=$2; shift 2 ;;
	-o) need "$1" "$#"; OBJ=$2; shift 2 ;;
	-w) need "$1" "$#"; WORK=$2; shift 2 ;;
	-b) need "$1" "$#"; BASE=$2; shift 2 ;;
	-N) need "$1" "$#"; NORMAL=$2; shift 2 ;;
	-U) need "$1" "$#"; OWNER=$2; shift 2 ;;
	-B) need "$1" "$#"; BENCH=$2; shift 2 ;;
	-M) need "$1" "$#"; MODEL=$2; shift 2 ;;
	-D) need "$1" "$#"; DATE=$2; shift 2 ;;
	-n) need "$1" "$#"; SEQ=$2; shift 2 ;;
	-h | --help) usage ;;
	*) echo "make-be.sh: unknown argument: $1" >&2; usage ;;
	esac
done
[ -n "$SRC" ] && [ -n "$OBJ" ] || { echo "make-be.sh: -s and -o are required" >&2; usage; }
[ -n "$WORK" ] || { echo "make-be.sh: give -w WORK or set GB10_WORK" >&2; exit 2; }
[ -n "$BASE" ] || BASE=$NORMAL
if [ -z "$OWNER" ]; then
	OWNER=$(stat -f %Su "$WORK") || { echo "make-be.sh: cannot find the owner of $WORK" >&2; exit 1; }
fi
[ -n "$BENCH" ] || BENCH=$WORK/llm/b12627/build-vulkan/bin/llama-bench
[ -n "$MODEL" ] || MODEL=$(dirname "$WORK")/models/Llama-3.2-3B-Instruct-Q4_K_M.gguf
case $OWNER in '' | *[!A-Za-z0-9._-]*) echo "make-be.sh: unusable OWNER: $OWNER" >&2; exit 2 ;; esac
id "$OWNER" > /dev/null 2>&1 || { echo "make-be.sh: no such OWNER: $OWNER" >&2; exit 1; }
case $BENCH in '' | *[!A-Za-z0-9._/+-]*) echo "make-be.sh: unusable BENCH path: $BENCH" >&2; exit 2 ;; esac
[ -f "$BENCH" ] && [ -x "$BENCH" ] || { echo "make-be.sh: BENCH is not an executable file: $BENCH" >&2; exit 1; }
case $MODEL in '' | *[!A-Za-z0-9._/+-]*) echo "make-be.sh: unusable MODEL path: $MODEL" >&2; exit 2 ;; esac
[ -f "$MODEL" ] || { echo "make-be.sh: MODEL is not a file: $MODEL" >&2; exit 1; }
case $DATE in [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) ;; *) echo "make-be.sh: -D takes YYYYMMDD" >&2; exit 2 ;; esac
case $SEQ in '' | *[!0-9]*) echo "make-be.sh: -n takes a number" >&2; exit 2 ;; esac
for _n in "$NORMAL" "$BASE"; do
	case $_n in '' | -* | *[!A-Za-z0-9._-]*) echo "make-be.sh: unusable boot environment name: $_n" >&2; exit 2 ;; esac
done
[ "$(id -u)" = 0 ] || { echo "make-be.sh: run as root" >&2; exit 2; }
BE=kernel-patches-fix-test-$DATE-$SEQ

SRC=$(cd "$SRC" && pwd)
KBUILD=$OBJ$SRC/arm64.aarch64/sys/GENERIC
[ -f "$KBUILD/kernel" ] || { echo "make-be.sh: no built kernel at $KBUILD/kernel" >&2; exit 1; }
for _s in \
    'arm64: kernel alignment-fault fixup enabled (%s)' \
    'linuxkpi: Ampere Altra erratum 82288: PCIe write-combining mapped as Device (mode %d)' \
    '32-bit config space reads only'; do
	strings "$KBUILD/kernel" | grep -qF "$_s" || { echo "make-be.sh: $KBUILD/kernel lacks '$_s': not the fixed series" >&2; exit 1; }
done
bectl list -H | cut -f1 | grep -qx "$NORMAL" || { echo "make-be.sh: no boot environment $NORMAL" >&2; exit 1; }
bectl list -H | cut -f1 | grep -qx "$BE" && { echo "make-be.sh: $BE exists already (use -n)" >&2; exit 1; }

VWANT=$(sed -n 's/^sha256 *= *\([0-9a-f]\{64\}\)$/\1/p' "$KITDIR/VENDOR")
[ -n "$VWANT" ] && [ "$(sha256 -q "$KITDIR/testboot-return")" = "$VWANT" ] || { echo "make-be.sh: testboot-return differs from the pin in VENDOR" >&2; exit 1; }

MNTBASE=$(mktemp -d /var/run/kpfix.XXXXXXXX)
MNT=$MNTBASE/root
mkdir "$MNT"
BE_MADE=0
BE_DONE=0
cleanup() {
	_rc=$?
	trap '' INT TERM HUP
	if [ "$BE_MADE" = 1 ] && [ "$BE_DONE" = 0 ]; then
		echo "make-be.sh: failed (exit $_rc); removing $BE" >&2
		bectl umount -f "$BE" > /dev/null 2>&1 || true
		bectl destroy -F "$BE" > /dev/null 2>&1 || echo "make-be.sh: COULD NOT remove $BE" >&2
	fi
	rmdir "$MNT" "$MNTBASE" 2> /dev/null || true
	exit "$_rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
run() { echo "+ $*"; "$@"; }

run bectl create -e "$BASE" "$BE"
BE_MADE=1
run bectl mount "$BE" "$MNT"

# the kernel's __FreeBSD_version must be the clone's world's
_kv=$(sed -n 's/^#define[[:space:]]*__FreeBSD_version[[:space:]]*\([0-9]*\).*/\1/p' "$SRC/sys/sys/param.h")
_wv=$(sed -n 's/^#define[[:space:]]*__FreeBSD_version[[:space:]]*\([0-9]*\).*/\1/p' "$MNT/usr/include/sys/param.h")
[ -n "$_kv" ] && [ "$_kv" = "$_wv" ] || { echo "make-be.sh: the tree is $_kv, the clone's world is $_wv" >&2; exit 1; }

# the base kernel directory: the effective kernel= of the clone's loader configuration
eff_conf() {
	for _f in "$MNT/boot/loader.conf" $(ls "$MNT"/boot/loader.conf.d/*.conf 2> /dev/null | sort) "$MNT/boot/loader.conf.local"; do
		[ -f "$_f" ] && cat "$_f"
	done | sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"\{0,1\}\([^\"]*\)\"\{0,1\}[[:space:]]*\(#.*\)\{0,1\}\$/\1/p" | tail -n 1
}
BASEK=$(eff_conf kernel)
BASEK=${BASEK:-kernel}
[ -d "$MNT/boot/$BASEK" ] || { echo "make-be.sh: the clone has no /boot/$BASEK" >&2; exit 1; }
[ ! -e "$MNT/boot/$KNAME" ] || { echo "make-be.sh: the clone already has /boot/$KNAME" >&2; exit 1; }
[ -z "$(eff_conf module_path)" ] || { echo "make-be.sh: the clone sets module_path; this kit relies on the default (the kernel directory, then /boot/modules)" >&2; exit 1; }

run env PATH=/sbin:/bin:/usr/sbin:/usr/bin MAKEOBJDIRPREFIX="$OBJ" \
    make -C "$SRC" installkernel KERNCONF=GENERIC INSTKERNNAME="$KNAME" DESTDIR="$MNT" \
    WITHOUT_KERNEL_SYMBOLS=yes > "$MNTBASE/installkernel.log" 2>&1 || { tail -20 "$MNTBASE/installkernel.log" >&2; exit 1; }
[ "$(sha256 -q "$MNT/boot/$KNAME/kernel")" = "$(sha256 -q "$KBUILD/kernel")" ] || { echo "make-be.sh: the installed kernel differs from the build" >&2; exit 1; }

# modules the base kernel directory has and the build does not
_extra=
for _m in "$MNT/boot/$BASEK"/*.ko; do
	_b=$(basename "$_m")
	[ -e "$MNT/boot/$KNAME/$_b" ] && continue
	run install -m 0555 "$_m" "$MNT/boot/$KNAME/$_b"
	_extra="$_extra $_b"
done
for _need in amdgpu.ko drm.ko ttm.ko dmabuf.ko; do
	[ -f "$MNT/boot/$KNAME/$_need" ] || { echo "make-be.sh: /boot/$KNAME/$_need is missing (the base kernel directory has no $_need)" >&2; exit 1; }
done
run kldxref "$MNT/boot/$KNAME"

# loader: this kernel, panics restart in 5 seconds and never wait in the debugger.  The
# loader reads loader.conf.d in directory order, not sorted, so every existing assignment
# of these three variables is rewritten in the clone, and a file adds them where none is.
for _f in "$MNT/boot/loader.conf" "$MNT"/boot/loader.conf.d/*.conf "$MNT/boot/loader.conf.local"; do
	[ -f "$_f" ] || continue
	[ ! -L "$_f" ] || { echo "make-be.sh: ${_f#$MNT} is a symbolic link" >&2; exit 1; }
	sed -E -e "s/^[[:space:]]*kernel[[:space:]]*=.*/kernel=\"$KNAME\"/" \
	    -e 's/^[[:space:]]*kern\.panic_reboot_wait_time[[:space:]]*=.*/kern.panic_reboot_wait_time="5"/' \
	    -e 's/^[[:space:]]*debug\.debugger_on_panic[[:space:]]*=.*/debug.debugger_on_panic="0"/' "$_f" > "$_f.kp-new"
	if cmp -s "$_f" "$_f.kp-new"; then rm -f "$_f.kp-new"; else cat "$_f.kp-new" > "$_f"; rm -f "$_f.kp-new"; echo "rewrote the test settings in ${_f#$MNT}"; fi
done
install -d -m 0755 "$MNT/boot/loader.conf.d"
printf '# kernel-patches test boot (Track #2442): this boot environment only\nkernel="%s"\nkern.panic_reboot_wait_time="5"\ndebug.debugger_on_panic="0"\n' "$KNAME" \
    > "$MNT/boot/loader.conf.d/zzz-kernel-patches-test.conf"
# all_conf VAR: every value VAR is given in the loader files, one per line, unique
# keep in step with check-be.sh
all_conf() {
	cat "$MNT/boot/loader.conf" "$MNT"/boot/loader.conf.d/*.conf "$MNT/boot/loader.conf.local" 2> /dev/null |
	    sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"\{0,1\}\([^\"]*\)\"\{0,1\}[[:space:]]*\(#.*\)\{0,1\}\$/\1/p" | sort -u
}
[ "$(all_conf kernel)" = "$KNAME" ] && [ "$(all_conf kern.panic_reboot_wait_time)" = 5 ] && [ "$(all_conf debug.debugger_on_panic)" = 0 ] || \
    { echo "make-be.sh: the loader files still give other values for kernel or the panic settings" >&2; exit 1; }

# kld_list without amdgpu: the recorder loads it after the rows before
_kl=$(sh -c '. "$1" || exit 1; [ ! -f "$2" ] || . "$2" || exit 1; [ ! -f "$3" ] || . "$3" || exit 1; [ ! -f "$4" ] || . "$4" || exit 1; printf "%s\n" "${kld_list-}"' sh "$MNT/etc/rc.conf" "$MNT/etc/rc.conf.local" "$MNT/etc/rc.conf.d/kld" "$MNT/usr/local/etc/rc.conf.d/kld") || {
	echo "make-be.sh: cannot read kld_list from the clone's rc.conf files" >&2
	exit 1
}
_nkl=$(filter_kld_list "$_kl")
install -d -m 0755 "$MNT/etc/rc.conf.d"
printf 'kld_list="%s"\n' "$_nkl" > "$MNT/etc/rc.conf.d/kld"
echo "kld_list of the clone: [$_kl] -> [$_nkl]"

# Nothing may load the GPU driver before the recorder has armed its dead-man.
for _v in amdgpu_load drm_load ttm_load; do
	if all_conf "$_v" | grep -Eq '^(YES|yes|Yes)$'; then
		echo "make-be.sh: the loader files set $_v to YES; the recorder must load amdgpu" >&2
		exit 1
	fi
done
if [ -e "$MNT/usr/local/etc/rc.conf.d/kld" ] || [ -L "$MNT/usr/local/etc/rc.conf.d/kld" ]; then
	echo "make-be.sh: /usr/local/etc/rc.conf.d/kld exists in the clone; it could load amdgpu" >&2
	exit 1
fi
_devmatch=$(sh -c '. "$1" || exit 1; [ ! -f "$2" ] || . "$2" || exit 1; [ ! -f "$3" ] || . "$3" || exit 1; [ ! -f "$4" ] || . "$4" || exit 1; printf "%s\n" "${devmatch_blocklist-}"' sh "$MNT/etc/rc.conf" "$MNT/etc/rc.conf.local" "$MNT/etc/rc.conf.d/devmatch" "$MNT/usr/local/etc/rc.conf.d/devmatch")
printf 'devmatch_blocklist="%s amdgpu"\n' "$_devmatch" > "$MNT/etc/rc.conf.d/devmatch"
if [ -e "$MNT/var/db/testboot-return.hold" ] || [ -L "$MNT/var/db/testboot-return.hold" ]; then
	rm -f "$MNT/var/db/testboot-return.hold"
	echo "removed stale /var/db/testboot-return.hold from the clone"
fi

# every other test-boot kit is turned off
for _f in "$MNT/etc/rc.conf" "$MNT/etc/rc.conf.local" "$MNT/usr/local/etc/rc.conf" "$MNT/usr/local/etc/rc.conf.local" \
    "$MNT"/etc/rc.conf.d/* "$MNT"/usr/local/etc/rc.conf.d/*; do
	[ -f "$_f" ] && [ ! -L "$_f" ] || continue
	grep -Eq '^[[:space:]]*[A-Za-z0-9_]+_testboot_enable=' "$_f" || continue
	sed -E 's/^([[:space:]]*[A-Za-z0-9_]+_testboot_enable)=.*/\1="NO"/' "$_f" > "$_f.kp-new" && cat "$_f.kp-new" > "$_f" && rm -f "$_f.kp-new"
	echo "turned off the test-boot kits in ${_f#$MNT}"
done

# The marker ties use of the real shutdown to this one-shot boot environment.
install -d -m 0755 "$MNT/usr/local/etc"
printf '%s\n' "$BE" > "$MNT/usr/local/etc/kernel_patches_testboot.marker"
chmod 0444 "$MNT/usr/local/etc/kernel_patches_testboot.marker"

# the recorder
install -d -m 0755 "$MNT/usr/local/etc/rc.d" "$MNT/usr/local/sbin"
run install -o root -g wheel -m 0555 "$KITDIR/kernel_patches_testboot" "$MNT/usr/local/etc/rc.d/kernel_patches_testboot"
run install -o root -g wheel -m 0555 "$KITDIR/testboot-return" "$MNT/usr/local/sbin/testboot-return"
HASHES=$MNT/usr/local/etc/kernel_patches_testboot.sha256
{
	echo "$(sha256 -q "$MNT/boot/$KNAME/kernel") kernel"
	for _p in $(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$REPO/kernel-patches/series"); do
		echo "$(sha256 -q "$REPO/kernel-patches/$_p") $_p"
	done
	echo "$(sha256 -q "$KITDIR/kernel_patches_testboot") kernel_patches_testboot"
} > "$HASHES"
_head=$(git -c safe.directory="$REPO" -C "$REPO" rev-parse HEAD 2> /dev/null || echo unknown)
_dirty=$(git -c safe.directory="$REPO" -C "$REPO" status --porcelain -- kernel-patches tests/kernel-patches-testboot 2> /dev/null | wc -l | tr -d ' ')
printf 'kit %s (%s uncommitted kit files), BE %s, source %s, extra modules:%s\n' "$_head" "$_dirty" "$BE" "$SRC" "$_extra" \
    > "$MNT/usr/local/etc/kernel_patches_testboot.version"
printf 'kernel_patches_testboot_enable="YES"\nkernel_patches_testboot_normal_be="%s"\nkernel_patches_testboot_copyout="%s"\nkernel_patches_testboot_owner="%s"\nkernel_patches_testboot_bench="%s"\nkernel_patches_testboot_model="%s"\n' \
    "$NORMAL" "$WORK/logs/kernel-patches-testboot" "$OWNER" "$BENCH" "$MODEL" > "$MNT/etc/rc.conf.d/kernel_patches_testboot"
as_owner /bin/sh -c 'mkdir -p "$0" && cat > "$0/$1"' "$WORK/logs/kernel-patches-testboot" "$BE.sha256" < "$HASHES"

run bectl umount "$BE"
BE_DONE=1
echo "built, NOT armed: $BE (base $BASE, returns to $NORMAL)"
echo "check it with: sh $KITDIR/check-be.sh -s $SRC -o $OBJ $BE"
echo "arm it with:   bectl activate -t $BE   (the host reboots into it once, runs the recorder, and returns to $NORMAL by itself)"

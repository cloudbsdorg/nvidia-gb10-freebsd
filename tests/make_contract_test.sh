#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# make_contract_test.sh - the root Makefile and scripts/make.sh (skill
# project-makefile-contract), run as a normal user, with a planted build so
# nothing is compiled:
#   (a) bmake and GNU make: help prints "purpose: application" first, purpose
#       prints the value, the documented targets are listed, the install
#       targets dry-run
#   (b) preflight --json parses, has the contract fields, reports
#       "no NVIDIA device" or "NVIDIA device present", and exits 1 when an
#       item is missing (an empty WORK has no sources); text preflight too
#   (c) install into a user-owned DESTDIR without YES and without a terminal:
#       the DESTDIR is the confirmation, so the staged files are installed
#   (d) install YES=1 into a DESTDIR: every staged file lands; each manifest
#       line's mode, owner and sha256 match the file on disk; the modules
#       are exactly the module list of make.sh; the created directories are
#       recorded, the ones that existed are not
#   (e) a second install over the first one is allowed (it wrote the files)
#   (f) a file the install did not write is never replaced
#   (g) a file changed since install is not replaced by a reinstall
#   (h) deinstall keeps a file changed since install (listed, exit 1), and
#       never follows a manifest path with a .. component
#   (i) an interrupted install (a read-only directory) can be rerun, and
#       deinstall then restores the DESTDIR
#   (j) a reinstall with a smaller stage removes the files it no longer has
#   (k) deinstall YES=1 leaves the DESTDIR exactly as it was before
#   (l) mutant: a manifest with a wrong sha256 is caught by check_manifest
#       (it runs right after (d))
#   (m) configure: refused without YES; applied with YES (backup, the
#       proposed lines shown); nothing to configure the second time;
#       deinstall restores both files exactly and removes the backup
#   (n) a path planted in the stage is refused before anything is copied
#   (o) preflight creates no WORK
#   (p) a WORK writable by group or other is refused and keeps its mode
#   (q) tests/install-e2e/expected.manifest equals what install writes
#   (s) someone else's drm.ko is kept, and ours is not installed
#   (t) a manifest at the place commit 23c18da used is moved; deinstall
#       then removes everything; migration never writes through a dangling
#       manifest symlink or a symlinked state parent; a refused migration
#       makes deinstall fail instead of reporting success
#   (u) every module of the module table is among the installed files
#   (v) a migrated manifest cannot make deinstall remove an arbitrary file
#   (w) deinstall undoes a configured key when its unchanged file's backup
#       is missing, and never prints a malformed backup-kept suffix
#   (x) test-install defaults --ref to checkout HEAD, with E2E_REF as override
#   (y) environment DESTDIR and PREFIX survive make; environment licence
#       acceptance never does
#   (z) the manifest records PREFIX; a different PREFIX cannot reinstall
#       over it, and deinstall with that different PREFIX uses the record
#   (r) the NVIDIA licence: YES=1 alone and no terminal both stop with the
#       explanation; ACCEPT_NVIDIA_LICENSE=1 and ACCEPT_ALL_LICENSES=1
#       accept and record it; a changed licence asks again; preflight and
#       help say so
# The DRM modules are architecture-dependent (uname -p).  On amd64 drm.ko
# and dmabuf.ko come from FreeBSD's drm-kmod packages: this repository
# does not install them, so the tests plant a packaged drm.ko and
# dmabuf.ko in DESTDIR/boot/modules the way `pkg install drm-kmod` would,
# expect the install to keep them and to leave them out of our manifest,
# and compare with the expected manifest without them.  On aarch64 this
# tree installs both and today's expectations stand.
# The MK_* switches of a calling make (make test YES=1) are cleared first.
# The planted build, source tarball and pinned-looking trees keep every
# automatic install-prereqs run offline.  Scratch files live under WORK/tmp
# (never /tmp) and are removed at the end.

set -u
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
export PATH
unset MK_WORK MK_PREFIX MK_DESTDIR MK_SYSDIR MK_BSDSRCTOP MK_DRMKMODDIR \
    MK_YES MK_ASSUME_YES MK_JSON MK_JSONL MK_PURPOSE MK_ACCEPT_NVIDIA_LICENSE MK_ACCEPT_ALL_LICENSES
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
base=${GB10_WORK:-$repo/work}
mkdir -p -- "$base/tmp"
S=$(mktemp -d "$base/tmp/make_contract.XXXXXX") || exit 1
trap 'if [ "${KEEP_SCRATCH:-0}" = 1 ]; then printf "scratch: %s\n" "$S"; else chmod -R u+w "$S" 2>/dev/null; rm -rf -- "$S"; fi' EXIT
fail=0
ok() { printf 'ok    %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1"; fail=$((fail + 1)); }

url=$(awk '$1 == "nvidia_freebsd_url" { print $2 }' "$repo/SOURCES")
want_sha=$(awk '$1 == "nvidia_freebsd_sha256" { print $2 }' "$repo/SOURCES")
ogkm_tag=$(awk '$1 == "ogkm_tag" { print $2 }' "$repo/SOURCES")
want_commit=$(awk '$1 == "ogkm_commit" { print $2 }' "$repo/SOURCES")
top=${url##*/}
top=${top%.tar.xz}
export PLANT_TAR_NAME="$top.tar.xz" PLANT_WANT_SHA="$want_sha" PLANT_WANT_COMMIT="$want_commit"
H=$S/hooks
mkdir -p -- "$H"
cat > "$H/sha256" <<'EOF'
#!/bin/sh
case "$*" in
*"$PLANT_TAR_NAME"*) printf '%s\n' "$PLANT_WANT_SHA" ;;
*) exec /sbin/sha256 "$@" ;;
esac
EOF
cat > "$H/git" <<'EOF'
#!/bin/sh
case "$*" in
*' rev-parse HEAD'*) printf '%s\n' "$PLANT_WANT_COMMIT" ;;
*' status --porcelain --untracked-files=no'*) exit 0 ;;
*' diff --quiet HEAD'*) exit 0 ;;
*) echo "planted git: unexpected command: $*" >&2; exit 1 ;;
esac
EOF
chmod 755 "$H/sha256" "$H/git"
GB10_TEST_HOOKS=1
FETCH=/bin/false
SHA256=$H/sha256
GIT=$H/git
export GB10_TEST_HOOKS FETCH SHA256 GIT

# assignments in front of a shell function are not exported to the
# commands it runs (sh(1)), so mk exports the switches itself.  Install uses
# the planted source trees and accepts the planted licence explicitly.
mk() (
	MK_ACCEPT_NVIDIA_LICENSE=0
	MK_ACCEPT_ALL_LICENSES=0
	export MK_WORK MK_DESTDIR MK_YES MK_ACCEPT_NVIDIA_LICENSE MK_ACCEPT_ALL_LICENSES
	if [ -n "${W:-}" ]; then
		MK_SYSDIR=$W/src/sys
		MK_BSDSRCTOP=$W/src
		MK_DRMKMODDIR=$S/drm-kmod
		export MK_SYSDIR MK_BSDSRCTOP MK_DRMKMODDIR
	fi
	if [ "${1:-}" = install ]; then
		MK_ACCEPT_NVIDIA_LICENSE=1
		export MK_ACCEPT_NVIDIA_LICENSE
	fi
	sh "$repo/scripts/make.sh" "$@"
)
me=$(id -un):$(id -gn)

# The DRM modules are architecture-dependent.  On amd64 drm.ko and
# dmabuf.ko come from FreeBSD's drm-kmod packages and this repository
# does not install them; on aarch64 this tree installs both, unless a
# foreign drm.ko is already in place.
arch=$(uname -p)
case "$arch" in
amd64)	drm_ours=no ;;
aarch64)	drm_ours=yes ;;
*)	drm_ours=yes
	printf 'note: unknown architecture %s, keeping the aarch64 expectations\n' "$arch" ;;
esac

# plant_packaged_drm DESTDIR: leave the DRM modules in
# DESTDIR/boot/modules the way `pkg install drm-kmod` leaves them.  On
# amd64 the install has to find a packaged DRM module there, must keep
# it and must not put it in our manifest; on aarch64 this tree installs
# its own, so nothing is planted.  A module that is already there (a
# foreign one) is left alone.
plant_packaged_drm() {
	[ "$drm_ours" = no ] || return 0
	_p=$1
	mkdir -p "$_p/boot/modules"
	for _m in drm dmabuf; do
		if [ ! -e "$_p/boot/modules/$_m.ko" ]; then
			printf 'packaged %s\n' "$_m" > "$_p/boot/modules/$_m.ko"
			chmod 555 "$_p/boot/modules/$_m.ko"
		fi
	done
	return 0
}

# (a) help and purpose under both makes
for m in make gmake; do
	command -v "$m" >/dev/null 2>&1 || { bad "$m not installed"; continue; }
	out=$(cd "$repo" && "$m" -s 2>&1)
	first=$(printf '%s\n' "$out" | sed -n 1p)
	[ "$first" = "purpose: application" ] && ok "$m help first line" || bad "$m help first line: $first"
	for t in preflight install-prereqs configure build test install deinstall test-install YES=1 JSON=1; do
		printf '%s\n' "$out" | grep -q -- "$t" || bad "$m help does not list $t"
	done
	p=$(cd "$repo" && "$m" -s purpose)
	[ "$p" = application ] && ok "$m purpose" || bad "$m purpose: $p"
	(cd "$repo" && "$m" -r -n install deinstall deps install-deps >/dev/null 2>&1) \
	    && ok "$m -n install deinstall deps install-deps" || bad "$m -n of the install targets"
done

# (y) the environment rule is part of the user-facing contract: staging
# roots may come from the environment, but confirmation and licence choices
# are command-line-only.  Check the values without running an install.
_mhelp=$(cd "$repo" && make -s help)
if sed -n '1,45p' "$repo/Makefile" | grep -qF 'DESTDIR and PREFIX may come from the environment' \
    && sed -n '1,45p' "$repo/Makefile" | grep -qF 'ASSUME_YES and the licence settings never do (only the command line)' \
    && printf '%s\n' "$_mhelp" | grep -qF 'DESTDIR and PREFIX may come from the environment' \
    && printf '%s\n' "$_mhelp" | grep -qF 'ASSUME_YES and the licence settings never do (only the command line)'; then
	ok "Makefile header and help document the environment rule"
else
	bad "(y) Makefile header or help omits the environment rule"
fi
for _v in YES ASSUME_YES ACCEPT_NVIDIA_LICENSE ACCEPT_ALL_LICENSES; do
	_value=$(cd "$repo" && env "$_v=1" make -s -V "$_v")
	[ "$_value" = 0 ] && ok "environment $_v cannot enable $_v" \
	    || bad "(y) environment $_v=1 produced $_value"
done

# (x) local work is tested by default; E2E_REF overrides the checkout HEAD
_e2e=$(sed -n '/^do_test_install() {/,/^}/p' "$repo/scripts/make.sh")
if printf '%s\n' "$_e2e" | grep -qF '_ref=${MK_E2E_REF:-}' \
    && printf '%s\n' "$_e2e" | grep -qF '[ -n "$_ref" ] || _ref=$(git -C "$repo" rev-parse HEAD)' \
    && printf '%s\n' "$_e2e" | grep -qF 'set -- "$@" --ref "$_ref"' \
    && grep -q '^E2E_REF =' "$repo/Makefile" \
    && grep -qF 'MK_E2E_REF="$(E2E_REF)"' "$repo/Makefile" \
    && (cd "$repo" && make -s help) | grep -q 'E2E_REF=.*default: checkout HEAD' \
    && grep -q 'mirror must carry that commit' "$repo/tests/install-e2e/README.md"; then
	ok "test-install: checkout HEAD is the default and E2E_REF overrides it"
else
	bad "(x) test-install does not default to checkout HEAD with an E2E_REF override"
fi

# (b) preflight on an empty WORK
W=$S/work
mkdir -p "$W"
MK_WORK=$W mk preflight --json --purpose application > "$S/pf.json" 2> "$S/pf.err"
rc=$?
[ "$rc" = 1 ] && ok "preflight exit 1 with nothing fetched" || bad "preflight exit $rc with nothing fetched"
if python3 -I - "$S/pf.json" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["schema_version"] == "1.0" and d["tool"] == "preflight"
assert d["purpose"] == "application"
assert d["device"] in ("no NVIDIA device", "NVIDIA device present", "device check unavailable")
assert isinstance(d["status"], list) and isinstance(d["items"], list)
names = [s["name"] for s in d["status"]]
assert "sources" in names and "sysdir" in names and "drmkmoddir" in names and "root" in names
for i, s in enumerate(d["status"]):
    assert s["index"] == i and s["state"] in ("ok", "missing", "warn")
    assert s["available"] == (s["state"] == "ok")
src = [s for s in d["status"] if s["name"] == "sources"][0]
assert src["state"] == "missing" and src["fix"] == "make install-prereqs"
assert d["missing"] == sum(1 for s in d["status"] if s["state"] == "missing")
assert (d["device"] == "NVIDIA device present") == (len(d["items"]) > 0)
EOF
then ok "preflight --json contract"; else bad "preflight --json contract"; fi
MK_WORK=$W mk preflight > "$S/pf.txt" 2>&1
grep -q '^miss  sources: ' "$S/pf.txt" && grep -q '^preflight: [1-9][0-9]* missing$' "$S/pf.txt" \
    && ok "preflight text" || bad "preflight text: $(tail -n 2 "$S/pf.txt")"

# A planted build: every module make.sh installs, libnvrm and nvrm-info, as
# plain files, and a build stamp that matches so install does not rebuild.
# The cached source inputs satisfy install-prereqs without a network.
T=$W/build/tree
mods=$(mk _module-list)
[ "$(printf '%s\n' "$mods" | wc -l | tr -d ' ')" -ge 6 ] || bad "module list: $mods"
for ko in $mods; do
	mkdir -p "$T/$(dirname "$ko")"
	printf 'planted %s\n' "$ko" > "$T/$ko"
done
L=$W/build/libnvrm-obj
mkdir -p "$L/lib" "$L/info"
printf 'so\n' > "$L/lib/libnvrm.so.1"
printf 'a\n' > "$L/lib/libnvrm.a"
printf 'prog\n' > "$L/info/nvrm-info"
printf 'drm\n' > "$W/build/drm.ko"
printf 'dmabuf\n' > "$W/build/dmabuf.ko"
mkdir -p "$W/sources/$top/doc" "$W/sources/open-gpu-kernel-modules-$ogkm_tag/.git" \
    "$W/src/sys/sys" "$W/src/include" "$S/drm-kmod"
printf 'NVIDIA Driver License Agreement (test copy)\n' > "$W/sources/$top/doc/license.txt"
tar -cJf "$W/sources/$top.tar.xz" -C "$W/sources" "$top"
printf 'X=1\n' > "$S/drm-kmod/linuxkpi_version.mk"
printf '#define __FreeBSD_version %s\n' "$(sysctl -n kern.osreldate)" > "$W/src/sys/sys/param.h"
MK_WORK=$W mk _build-stamp > "$W/build/stamp"
D=$S/dest
mkdir -p "$D/boot/modules" "$D/usr/local/etc" "$D/etc"
# the packaged DRM modules are there before the snapshot: the install
# must keep them, the manifest must not claim them and the deinstall
# must leave them alone
plant_packaged_drm "$D"
snap() { (cd "$1" && find . | sort); }
snap "$D" > "$S/before.list"

# (c) a user-owned DESTDIR is itself the confirmation; no YES or terminal is
# needed.  Use a separate destination so (d) still tests a first install.
DC=$S/dest-no-yes
mkdir -p "$DC/boot/modules" "$DC/usr/local/etc" "$DC/etc"
plant_packaged_drm "$DC"
(MK_WORK=$W MK_DESTDIR=$DC MK_YES=0 mk install < /dev/null) > "$S/c.out" 2>&1
rc=$?
if [ "$rc" = 0 ] && [ -f "$DC/boot/modules/nvidia.ko" ] \
    && [ -f "$DC/var/db/nvidia-gb10-freebsd/installed.manifest" ] \
    && ! grep -q 'no terminal to ask' "$S/c.out"; then
	ok "install into a user DESTDIR needs neither YES nor a terminal"
else
	bad "install without YES (rc $rc): $(tail -n 3 "$S/c.out")"
fi

inst() { MK_WORK=$W MK_DESTDIR=$1 MK_YES=1 mk install > "$2" 2>&1 < /dev/null; }
deinst() { MK_WORK=$W MK_DESTDIR=$1 MK_YES=1 mk deinstall > "$2" 2>&1 < /dev/null; }

# check_manifest MANIFEST ROOT: each file line's mode, owner and sha256
# match ROOT; prints one line per mismatch
check_manifest() {
	awk '$1 !~ /^@/ && $2 != "dir" && $2 != "link"' "$1" | while read -r p m o h; do
		[ -f "$2$p" ] || { echo "missing $p"; continue; }
		[ "$(stat -f '%Lp' "$2$p")" = "$m" ] || echo "mode $p"
		[ "$(stat -f '%Su:%Sg' "$2$p")" = "$o" ] || echo "owner $p"
		[ "$h" = - ] || [ "$(sha256 -q "$2$p")" = "$h" ] || echo "sha256 $p"
	done
}

# (d) YES=1 install into DESTDIR
inst "$D" "$S/d.out"
rc=$?
M=$D/var/db/nvidia-gb10-freebsd/installed.manifest
cp "$M" "$S/q.manifest" 2>/dev/null
if [ "$rc" = 0 ] && [ -f "$M" ]; then
	errs=$(check_manifest "$M" "$D")
	[ -z "$errs" ] && ok "install: manifest modes, owners and sha256 match" || bad "install manifest: $errs"
	for want in "/usr/local/etc/rc.d/nvidia_linux 555 $me" \
	    "/usr/local/share/man/man4/nvidia.4 444 $me" "/usr/local/lib/libnvrm.so.1 444 $me" \
	    "/usr/local/sbin/nvrm-info 555 $me" "/usr/local/share/man/man8/nvrm-info.8 444 $me" \
	    "/usr/local/lib/libnvrm.so link -> libnvrm.so.1" "/usr/local/share/man/man3/nvrm_enumerate.3 link -> nvrm.3" \
	    "/usr/local/etc/devd/nvidia_gb10.conf 444 $me" \
	    "/usr/local/share/licenses/nvidia-gb10-freebsd/NVIDIA-LICENSE 444 $me" \
	    "/var/db/nvidia-gb10-freebsd dir" "/usr/local/include/nvrm dir" "/usr/local/etc/rc.d dir"; do
		grep -q "^$want" "$M" || bad "manifest lacks: $want"
	done
	# the DRM modules are ours on aarch64 and FreeBSD's on amd64
	if [ "$drm_ours" = yes ]; then
		for want in "/boot/modules/drm.ko 555 $me" "/boot/modules/dmabuf.ko 555 $me"; do
			grep -q "^$want" "$M" || bad "manifest lacks: $want"
		done
	else
		if grep -q '^/boot/modules/drm.ko ' "$M"; then
			bad "manifest claims drm.ko, which comes from drm-kmod on $arch"
		fi
		if grep -q '^/boot/modules/dmabuf.ko ' "$M"; then
			bad "manifest claims dmabuf.ko, which comes from drm-kmod on $arch"
		fi
	fi
	grep -q '^/boot/modules dir' "$M" && bad "manifest claims /boot/modules, which existed before"
	got=$(awk '$1 ~ /^\/boot\/modules\// { sub(/.*\//, "", $1); print $1 }' "$M" | sort)
	if [ "$drm_ours" = yes ]; then
		want=$(printf '%s\n' $mods drm.ko dmabuf.ko | sed 's|.*/||' | sort)
	else
		want=$(printf '%s\n' $mods | sed 's|.*/||' | grep -E -v '(^|/)drm\.ko$|(^|/)dmabuf\.ko$' | sort)
	fi
	[ "$got" = "$want" ] && ok "install: the modules are the module list" || bad "modules: $got"
	if [ "$drm_ours" = no ]; then
		# the packaged DRM modules stay as they are and are not ours
		if [ -f "$D/boot/modules/drm.ko" ] && [ -f "$D/boot/modules/dmabuf.ko" ] \
		    && [ "$(cat "$D/boot/modules/drm.ko")" = "packaged drm" ] \
		    && [ "$(cat "$D/boot/modules/dmabuf.ko")" = "packaged dmabuf" ] \
		    && ! grep -q '^/boot/modules/drm.ko ' "$M" \
		    && ! grep -q '^/boot/modules/dmabuf.ko ' "$M"; then
			ok "the packaged drm.ko and dmabuf.ko are kept and are not in the manifest"
		else
			bad "the packaged DRM modules were replaced or claimed by the install"
		fi
	fi
	n=$(awk '$2 ~ /^[0-7]+$/' "$M" | wc -l | tr -d ' ')
	ns=$(find "$W/stage" -type f | wc -l | tr -d ' ')
	[ "$n" = $((ns + 1)) ] && ok "install: $n files (the stage and the manifest)" || bad "install: $n files, stage $ns"
else
	bad "install YES=1 (rc $rc): $(tail -n 3 "$S/d.out")"
fi

# (y) environment DESTDIR and PREFIX must survive make.  Before the fix,
# avoid the live root install that the discarded DESTDIR would request.
D9=$S/dest9
mkdir -p "$D9/boot/modules" "$D9/etc"
plant_packaged_drm "$D9"
if [ "$(cd "$repo" && env DESTDIR="$D9" make -V DESTDIR)" = "$D9" ] \
    && [ "$(cd "$repo" && env PREFIX=/opt/gb10 make -V PREFIX)" = /opt/gb10 ]; then
	(cd "$repo" && env DESTDIR="$D9" PREFIX=/opt/gb10 make install YES=1 ACCEPT_NVIDIA_LICENSE=1 \
	    WORK="$W" SYSDIR="$W/src/sys" BSDSRCTOP="$W/src" DRMKMODDIR="$S/drm-kmod") > "$S/y.out" 2>&1 < /dev/null
	rc=$?
	if [ "$rc" = 0 ] && [ -f "$D9/opt/gb10/etc/rc.d/nvidia_linux" ] \
	    && [ -f "$D9/var/db/nvidia-gb10-freebsd/installed.manifest" ] \
	    && [ ! -e "$D9/usr/local/etc/rc.d/nvidia_linux" ]; then
		ok "environment DESTDIR and PREFIX select the install root"
	else
		bad "(y) environment install (rc $rc): $(tail -n 3 "$S/y.out")"
	fi
else
	bad "(y) make discards environment DESTDIR or PREFIX; live install not attempted"
fi

# (z) PREFIX belongs to the install, not to the later deinstall command.
# A different PREFIX cannot reinstall over a manifest; deinstall still
# removes every file by using the prefix recorded at install time.
D10=$S/dest10
mkdir -p "$D10/boot/modules" "$D10/usr/local/etc" "$D10/etc"
plant_packaged_drm "$D10"
inst "$D10" "$S/z1.out"
rc1=$?
M10=$D10/var/db/nvidia-gb10-freebsd/installed.manifest
grep -q '^@prefix /usr/local$' "$M10"
pfxrc=$?
env MK_WORK="$W" MK_DESTDIR="$D10" MK_YES=1 MK_PREFIX=/opt \
    MK_SYSDIR="$W/src/sys" MK_BSDSRCTOP="$W/src" MK_DRMKMODDIR="$S/drm-kmod" \
    MK_ACCEPT_NVIDIA_LICENSE=1 \
    sh "$repo/scripts/make.sh" install > "$S/z2.out" 2>&1 < /dev/null
rc2=$?
env MK_WORK="$W" MK_DESTDIR="$D10" MK_YES=1 MK_PREFIX=/opt \
    sh "$repo/scripts/make.sh" deinstall > "$S/z3.out" 2>&1 < /dev/null
rc3=$?
if [ "$rc1" = 0 ] && [ "$pfxrc" = 0 ] \
    && [ "$rc2" != 0 ] && grep -q 'make deinstall PREFIX=/usr/local first' "$S/z2.out" \
    && [ "$rc3" = 0 ] && [ ! -e "$D10/usr/local/etc/rc.d/nvidia_linux" ] \
    && [ ! -e "$D10/boot/modules/nvidia.ko" ] && [ ! -e "$M10" ] && [ ! -e "$D10/opt" ]; then
	ok "recorded PREFIX rejects a reinstall mismatch and survives a deinstall mismatch"
else
	bad "(z) PREFIX mismatch (rc $rc1 $rc2 $rc3): $(tail -n 3 "$S/z3.out" | sed "s|$S|SCRATCH|g" | tr '\n' ' ')"
fi

# (l) mutant: a wrong sha256 must be caught
sed '1,/ 444 [^ ]* [0-9a-f]/s/\( 444 [^ ]* \)[0-9a-f]*/\1deadbeef/' "$M" > "$S/mut.manifest"
[ -n "$(check_manifest "$S/mut.manifest" "$D")" ] && ok "mutant: wrong sha256 caught" || bad "mutant: wrong sha256 not caught"

# (e) reinstall over our own files
inst "$D" "$S/e.out" && ok "reinstall over the previous install" || bad "reinstall: $(tail -n 2 "$S/e.out")"

# (f) a foreign file is never replaced
D2=$S/dest2
mkdir -p "$D2/boot/modules"
plant_packaged_drm "$D2"
printf 'foreign\n' > "$D2/boot/modules/nvidia.ko"
inst "$D2" "$S/f.out"
rc=$?
if [ "$rc" != 0 ] && [ "$(cat "$D2/boot/modules/nvidia.ko")" = foreign ] && grep -q 'did not write it' "$S/f.out"; then
	ok "a file install did not write is not replaced"
else
	bad "foreign file (rc $rc)"
fi

# (g) a file changed since install is not replaced
cp "$D/usr/local/share/man/man4/nvidia.4" "$S/nvidia.4.orig"
chmod u+w "$D/usr/local/share/man/man4/nvidia.4"
printf 'changed\n' > "$D/usr/local/share/man/man4/nvidia.4"
inst "$D" "$S/g.out"
rc=$?
if [ "$rc" != 0 ] && [ "$(cat "$D/usr/local/share/man/man4/nvidia.4")" = changed ] && grep -q 'changed since' "$S/g.out"; then
	ok "a file changed since install is not replaced"
else
	bad "changed file on reinstall (rc $rc)"
fi

# (h) deinstall keeps the changed file and refuses a .. path
printf 'outside\n' > "$S/outside-file"
chmod u+w "$M"
printf '%s 444 %s %s\n' "/../../outside" "$me" "$(sha256 -q "$S/outside-file")" >> "$M"
deinst "$D" "$S/h.out"
rc=$?
# exit 1: a file was kept; it stays listed in the manifest
if [ "$rc" = 1 ] && [ "$(cat "$D/usr/local/share/man/man4/nvidia.4")" = changed ] && [ -f "$S/outside-file" ] \
    && grep -q 'kept .*nvidia.4' "$S/h.out" && grep -q 'refusing manifest path' "$S/h.out" \
    && grep -q '^/usr/local/share/man/man4/nvidia.4 ' "$M"; then
	ok "deinstall keeps a changed file, lists it, exits 1, and refuses a .. path"
else
	bad "deinstall changed/.. (rc $rc): $(tail -n 3 "$S/h.out")"
fi
# the user removes the changed file; a second deinstall finishes the job
rm -f "$D/usr/local/share/man/man4/nvidia.4"
deinst "$D" "$S/h2.out" || bad "second deinstall: $(tail -n 2 "$S/h2.out")"
snap "$D" > "$S/h.list"
cmp -s "$S/before.list" "$S/h.list" || bad "after (h): $(diff "$S/before.list" "$S/h.list" | head -5)"

# (i) interrupted install: lib/ read-only, then rerun, then deinstall
mkdir -p "$D/usr/local/lib"
snap "$D" > "$S/i.before"
chmod 555 "$D/usr/local/lib"
inst "$D" "$S/i1.out"
rc1=$?
chmod 755 "$D/usr/local/lib"
inst "$D" "$S/i2.out"
rc2=$?
deinst "$D" "$S/i3.out"
rc3=$?
snap "$D" > "$S/i.after"
if [ "$rc1" != 0 ] && [ "$rc2" = 0 ] && [ "$rc3" = 0 ] && cmp -s "$S/i.before" "$S/i.after"; then
	ok "an interrupted install reruns and deinstalls cleanly"
else
	bad "interrupted install (rc $rc1 $rc2 $rc3): $(tail -n 2 "$S/i2.out") $(diff "$S/i.before" "$S/i.after" | head -3)"
fi
rmdir "$D/usr/local/lib"

# (j) a smaller stage removes what it no longer has
inst "$D" "$S/j1.out" || bad "(j) install: $(tail -n 2 "$S/j1.out")"
# the two files must be there before, or the check below would pass vacuously
[ -f "$D/usr/local/share/man/man4/nvidia.4" ] && [ -L "$D/usr/local/share/man/man3/nvrm_enumerate.3" ] \
    || bad "(j) precondition: the files to drop were not installed"
cp -Rp "$W/stage" "$S/stage-small"
rm -f "$S/stage-small/usr/local/share/man/man4/nvidia.4" "$S/stage-small/usr/local/share/man/man3/nvrm_enumerate.3"
mk _install-stage "$S/stage-small" "$D" /usr/local > "$S/j2.out" 2>&1
rc=$?
if [ "$rc" = 0 ] && [ ! -e "$D/usr/local/share/man/man4/nvidia.4" ] && [ ! -L "$D/usr/local/share/man/man3/nvrm_enumerate.3" ] \
    && ! grep -q '^/usr/local/share/man/man4/nvidia.4 ' "$M"; then
	ok "a smaller stage removes the files it no longer has"
else
	bad "smaller stage (rc $rc): $(tail -n 2 "$S/j2.out")"
fi

# (k) deinstall restores the tree
deinst "$D" "$S/k.out"
rc=$?
snap "$D" > "$S/k.list"
if [ "$rc" = 0 ] && cmp -s "$S/before.list" "$S/k.list"; then
	ok "deinstall leaves the DESTDIR as it was"
else
	bad "deinstall (rc $rc): $(diff "$S/before.list" "$S/k.list" | head -5)"
fi

# (m) configure into a DESTDIR: refused without YES, applied with it (an
# existing rc.conf is backed up), "nothing to configure" the second time,
# and deinstall puts both files back exactly and removes the backup
D3=$S/dest3
mkdir -p "$D3/boot" "$D3/etc" "$D3/var/db"
printf 'hostname="h"\n' > "$D3/etc/rc.conf"
cp "$D3/etc/rc.conf" "$S/rc.conf.orig"
snap "$D3" > "$S/m.before"
(MK_WORK=$W MK_DESTDIR=$D3 mk configure < /dev/null) > "$S/m0.out" 2>&1
[ $? != 0 ] && cmp -s "$D3/etc/rc.conf" "$S/rc.conf.orig" && [ ! -e "$D3/boot/loader.conf" ] \
    && ok "configure without YES and without a terminal is refused" || bad "configure without YES"
MK_WORK=$W MK_DESTDIR=$D3 MK_YES=1 mk configure > "$S/m1.out" 2>&1 < /dev/null
if [ $? = 0 ] && grep -q '^nvidia_gb10_autoload="YES"' "$D3/etc/rc.conf" && grep -q '^hostname="h"' "$D3/etc/rc.conf" \
    && grep -q '^hw.nvidia.registry.EnableGpuFirmware="1"' "$D3/boot/loader.conf" \
    && ls "$D3"/etc/rc.conf.bak-* > /dev/null 2>&1 && grep -q '^proposed: ' "$S/m1.out"; then
	ok "configure YES=1 shows, backs up and applies"
else
	bad "configure YES=1: $(tail -n 3 "$S/m1.out")"
fi
MK_WORK=$W MK_DESTDIR=$D3 MK_YES=1 mk configure > "$S/m2.out" 2>&1 < /dev/null
grep -q 'nothing to configure' "$S/m2.out" && ok "configure twice: nothing to configure" || bad "configure twice: $(tail -n 2 "$S/m2.out")"
MK_WORK=$W MK_DESTDIR=$D3 MK_YES=1 mk deinstall > "$S/m3.out" 2>&1 < /dev/null
rc=$?
snap "$D3" > "$S/m.after"
if [ "$rc" = 0 ] && cmp -s "$S/m.before" "$S/m.after" && cmp -s "$D3/etc/rc.conf" "$S/rc.conf.orig"; then
	ok "deinstall takes out what configure set, restores rc.conf, removes the backup"
else
	bad "unconfigure: $(diff "$S/m.before" "$S/m.after" | head -4) $(tail -n 2 "$S/m3.out")"
fi

# (w) the configured file is unchanged but its backup has been removed:
# deinstall must still undo the key instead of skipping the record
D8=$S/dest8
mkdir -p "$D8/boot" "$D8/etc" "$D8/var/db"
printf 'hostname="h"\n' > "$D8/etc/rc.conf"
MK_WORK=$W MK_DESTDIR=$D8 MK_YES=1 mk configure > "$S/w1.out" 2>&1 < /dev/null
rc1=$?
rm -f "$D8"/etc/rc.conf.bak-*
MK_WORK=$W MK_DESTDIR=$D8 MK_YES=1 mk deinstall > "$S/w2.out" 2>&1 < /dev/null
rc2=$?
if [ "$rc1" = 0 ] && [ "$rc2" = 0 ] && ! grep -q '^nvidia_gb10_autoload=' "$D8/etc/rc.conf" \
    && grep -q '^hostname="h"' "$D8/etc/rc.conf" && grep -q 'backup .* missing' "$S/w2.out"; then
	ok "unconfigure undoes a key when the unchanged file's backup is missing"
else
	bad "(w) missing backup (rc $rc1 $rc2): $(tail -n 3 "$S/w2.out")"
fi

# (n) a path planted in the stage is refused, and nothing is written
D4=$S/dest4
mkdir -p "$D4"
plant_packaged_drm "$D4"
cp -Rp "$W/stage" "$S/stage-evil"
mkdir -p "$S/stage-evil/etc/rc.d"
printf '#!/bin/sh\n' > "$S/stage-evil/etc/rc.d/evil"
snap "$D4" > "$S/n.before"
mk _install-stage "$S/stage-evil" "$D4" /usr/local > "$S/n.out" 2>&1
rc=$?
rm -rf "$D4/var/db/nvidia-gb10-freebsd/.install."* 2>/dev/null
if [ "$rc" != 0 ] && [ ! -e "$D4/etc/rc.d/evil" ] && grep -q 'refusing staged path /etc/rc.d/evil' "$S/n.out" \
    && [ ! -e "$D4/boot/modules/nvidia.ko" ]; then
	ok "a path planted in the stage is refused before anything is copied"
else
	bad "planted stage path (rc $rc): $(tail -n 2 "$S/n.out")"
fi

# (o) preflight and configure resolve paths only: no WORK is created
MK_WORK=$S/nowork mk preflight > /dev/null 2>&1
[ ! -e "$S/nowork" ] && ok "preflight creates no WORK" || bad "preflight created $S/nowork"

# (p) a WORK writable by group or other is refused and left alone
mkdir -m 775 "$S/gw"
MK_WORK=$S/gw MK_DESTDIR=$D4 MK_YES=1 mk install > "$S/p.out" 2>&1 < /dev/null
rc=$?
[ "$rc" != 0 ] && [ "$(stat -f '%Lp' "$S/gw")" = 775 ] && grep -q 'writable by group or other' "$S/p.out" \
    && ok "a group-writable WORK is refused and keeps its mode" || bad "group-writable WORK (rc $rc): $(tail -n 1 "$S/p.out")"

# (r) the NVIDIA licence: YES=1 alone stops with the explanation and the
# setting to add; no setting and no terminal stops too; either setting
# accepts and records it; a changed licence asks again; preflight says so
WL=$S/wl
top=NVIDIA-FreeBSD-x86_64-580.178.04
mkdir -p "$S/lt/$top/doc" "$WL/sources"
printf 'NVIDIA Driver License Agreement (test copy)\n' > "$S/lt/$top/doc/license.txt"
tar -cJf "$WL/sources/$top.tar.xz" -C "$S/lt" "$top"
lic() { env MK_WORK="$WL" MK_ACCEPT_NVIDIA_LICENSE=0 MK_ACCEPT_ALL_LICENSES=0 "$@" sh "$repo/scripts/make.sh" _licence < /dev/null; }
lic MK_YES=1 > "$S/r1.out" 2>&1
rc=$?
[ "$rc" = 1 ] && grep -q 'ACCEPT_NVIDIA_LICENSE=1' "$S/r1.out" && grep -q 'YES=1 alone' "$S/r1.out" \
    && [ ! -e "$WL/sources/nvidia-licence.accepted" ] \
    && ok "licence: YES=1 alone stops with the explanation and the setting" || bad "licence YES=1 alone (rc $rc)"
lic > "$S/r2.out" 2>&1
rc=$?
[ "$rc" = 1 ] && grep -q 'ACCEPT_ALL_LICENSES=1' "$S/r2.out" && [ ! -e "$WL/sources/nvidia-licence.accepted" ] \
    && ok "licence: no setting and no terminal stops" || bad "licence no setting (rc $rc)"
MK_WORK=$WL mk preflight --json > "$S/r.json" 2>/dev/null
grep -q '"name": "licence", "state": "missing".*ACCEPT_NVIDIA_LICENSE=1' "$S/r.json" \
    && ok "preflight: licence missing, with the setting to add" || bad "preflight licence missing"
(cd "$repo" && env ACCEPT_NVIDIA_LICENSE=1 make preflight JSON=1 WORK="$WL") > "$S/r-env.json" 2>&1
rc=$?
if [ "$rc" = 1 ] && grep -q '"name": "licence", "state": "missing"' "$S/r-env.json" \
    && [ ! -e "$WL/sources/nvidia-licence.accepted" ]; then
	ok "environment ACCEPT_NVIDIA_LICENSE does not accept the licence"
else
	bad "(y) environment licence acceptance was not ignored (rc $rc)"
fi
lic MK_YES=1 MK_ACCEPT_NVIDIA_LICENSE=1 > "$S/r3.out" 2>&1
rc=$?
[ "$rc" = 0 ] && grep -q 'accepted by ACCEPT_NVIDIA_LICENSE=1' "$WL/sources/nvidia-licence.accepted" \
    && ok "licence: ACCEPT_NVIDIA_LICENSE=1 accepts and records it" || bad "ACCEPT_NVIDIA_LICENSE=1 (rc $rc)"
MK_WORK=$WL mk preflight --json > "$S/r.json" 2>/dev/null
grep -q '"name": "licence", "state": "ok"' "$S/r.json" && ok "preflight: licence ok once accepted" || bad "preflight licence ok"
printf 'a changed term\n' >> "$S/lt/$top/doc/license.txt"
tar -cJf "$WL/sources/$top.tar.xz" -C "$S/lt" "$top"
lic MK_YES=1 > "$S/r4.out" 2>&1
rc=$?
[ "$rc" = 1 ] && ok "licence: a changed licence asks again" || bad "changed licence (rc $rc)"
MK_WORK=$WL mk preflight --json > "$S/r.json" 2>/dev/null
grep -q '"name": "licence", "state": "missing", "available": false, "reason": "the NVIDIA driver licence in the tarball changed' "$S/r.json" \
    && ok "preflight: a changed licence is missing again" || bad "preflight after a licence change"
lic MK_ACCEPT_ALL_LICENSES=1 > "$S/r5.out" 2>&1
rc=$?
[ "$rc" = 0 ] && grep -q 'accepted by ACCEPT_ALL_LICENSES=1' "$WL/sources/nvidia-licence.accepted" \
    && ok "licence: ACCEPT_ALL_LICENSES=1 accepts it" || bad "ACCEPT_ALL_LICENSES=1 (rc $rc)"
(cd "$repo" && make -s help) | grep -q 'ACCEPT_NVIDIA_LICENSE=1' && ok "help lists the licence settings" || bad "help: licence settings"

# (s) someone else's drm.ko in /boot/modules: install leaves drm.ko and
# dmabuf.ko out and does not touch the foreign one
D5=$S/dest5
mkdir -p "$D5/boot/modules"
printf 'foreign drm\n' > "$D5/boot/modules/drm.ko"
plant_packaged_drm "$D5"
inst "$D5" "$S/s.out"
rc=$?
M5=$D5/var/db/nvidia-gb10-freebsd/installed.manifest
if [ "$rc" = 0 ] && [ "$(cat "$D5/boot/modules/drm.ko")" = "foreign drm" ] && ! grep -q '^/boot/modules/drm.ko ' "$M5" \
    && ! grep -q '^/boot/modules/dmabuf.ko ' "$M5" && grep -q '^/boot/modules/nvidia-drm.ko ' "$M5"; then
	ok "a foreign drm.ko is kept and ours is not installed"
else
	bad "foreign drm.ko (rc $rc): $(tail -n 2 "$S/s.out")"
fi
deinst "$D5" "$S/s2.out"
[ "$(cat "$D5/boot/modules/drm.ko")" = "foreign drm" ] && ok "deinstall keeps the foreign drm.ko" || bad "deinstall removed the foreign drm.ko"

# (t) a manifest at the old place (commit 23c18da: PREFIX/share) is moved,
# and deinstall still removes everything
D6=$S/dest6
mkdir -p "$D6/boot/modules" "$D6/usr/local/etc" "$D6/etc"
plant_packaged_drm "$D6"
snap "$D6" > "$S/t.before"
inst "$D6" "$S/t1.out" || bad "(t) install: $(tail -n 2 "$S/t1.out")"
mkdir -p "$D6/usr/local/share/nvidia-gb10-freebsd"
awk '$1 == "/var/db/nvidia-gb10-freebsd/installed.manifest" { $1 = "/usr/local/share/nvidia-gb10-freebsd/installed.manifest" }
    $1 != "/var/db/nvidia-gb10-freebsd" && $1 != "/var/db" && $1 != "/var" { print }' \
    "$D6/var/db/nvidia-gb10-freebsd/installed.manifest" > "$D6/usr/local/share/nvidia-gb10-freebsd/installed.manifest"
printf '/usr/local/share/nvidia-gb10-freebsd dir\n/var dir\n/var/db dir\n' >> "$D6/usr/local/share/nvidia-gb10-freebsd/installed.manifest"
chmod u+w "$D6/var/db/nvidia-gb10-freebsd/installed.manifest"
rm -f "$D6/var/db/nvidia-gb10-freebsd/installed.manifest"
deinst "$D6" "$S/t2.out"
rc=$?
snap "$D6" > "$S/t.after"
[ "$rc" = 0 ] && cmp -s "$S/t.before" "$S/t.after" && grep -q 'moved the manifest of an earlier install' "$S/t2.out" \
    && ok "a manifest at the old place is moved and deinstall removes everything" \
    || bad "(t) rc $rc: $(diff "$S/t.before" "$S/t.after" | head -4 | tr '\n' ' ')"

# (t) neither a dangling destination symlink nor a symlinked var/db may
# redirect the migration's write outside the DESTDIR
mkdir -p "$S/outside"
D6A=$S/dest6-dangling
mkdir -p "$D6A/usr/local/share/nvidia-gb10-freebsd" "$D6A/var/db/nvidia-gb10-freebsd"
: > "$D6A/usr/local/share/nvidia-gb10-freebsd/installed.manifest"
ln -s "$S/outside/x" "$D6A/var/db/nvidia-gb10-freebsd/installed.manifest"
deinst "$D6A" "$S/t-dangling.out"
D6B=$S/dest6-parent
mkdir -p "$D6B/usr/local/share/nvidia-gb10-freebsd" "$D6B/var"
: > "$D6B/usr/local/share/nvidia-gb10-freebsd/installed.manifest"
ln -s "$S/outside" "$D6B/var/db"
deinst "$D6B" "$S/t-parent.out"
if [ ! -e "$S/outside/x" ] && [ ! -e "$S/outside/nvidia-gb10-freebsd/installed.manifest" ]; then
	ok "migration never writes through a dangling manifest or state-parent symlink"
else
	bad "(t) migration followed a symlink: $(find "$S/outside" -maxdepth 3 -print | sed "s|$S/||g" | tr '\n' ' ')"
fi

# (t) a migration refused for an unsafe destination is a deinstall error,
# not a successful deinstall that leaves the real old manifest behind
D6C=$S/dest6-refused
mkdir -p "$D6C/usr/local/share/nvidia-gb10-freebsd" "$D6C/var"
: > "$D6C/usr/local/share/nvidia-gb10-freebsd/installed.manifest"
ln -s "$S/outside" "$D6C/var/db"
deinst "$D6C" "$S/t-refused.out"
rc=$?
if [ "$rc" = 1 ] && grep -q 'remove the planted file or check its owner' "$S/t-refused.out"; then
	ok "deinstall fails with an actionable error when migration is refused"
else
	bad "(t) refused migration returned rc $rc: $(tail -n 3 "$S/t-refused.out" | tr '\n' ' ')"
fi

# (v) a user-planted path in an old-place manifest is neither migrated nor
# removed by deinstall
D7=$S/dest7
mkdir -p "$D7/etc" "$D7/usr/local/share/nvidia-gb10-freebsd"
printf 'x\n' > "$D7/etc/keep"
printf '/etc/keep 444 %s %s\n' "$me" "$(sha256 -q "$D7/etc/keep")" \
    > "$D7/usr/local/share/nvidia-gb10-freebsd/installed.manifest"
deinst "$D7" "$S/v.out"
rc=$?
if [ -f "$D7/etc/keep" ] && [ "$(cat "$D7/etc/keep")" = x ] \
    && grep -q 'refusing manifest path /etc/keep' "$S/v.out"; then
	ok "deinstall refuses an arbitrary path from a migrated manifest"
else
	bad "(v) arbitrary manifest path (rc $rc): $(tail -n 3 "$S/v.out")"
fi

# (u) every module of the module table is a path install may write.  The
# DRM modules are not ours on amd64, so they are not in the table we
# expect to find installed.
if [ "$drm_ours" = yes ]; then
	modlist=$mods
else
	modlist=$(printf '%s\n' $mods | grep -E -v '(^|/)drm\.ko$|(^|/)dmabuf\.ko$')
fi
bad_paths=$(printf '%s\n' $modlist | sed 's|.*/|/boot/modules/|' | while read -r pth; do
	grep -q "^$pth " "$S/q.manifest" || echo "$pth"
done)
[ -z "$bad_paths" ] && ok "every module of the module table is installed" || bad "not installed: $bad_paths"

# (q) the expected manifest in the repository is what install writes
# (owners as a root install sets them)
awk '$1 ~ /^@/ || $2 == "dir" || $1 ~ /installed\.manifest$/ { next } { if ($2 == "link") print $1, "link", $4; else print $1, $2, "root:wheel" }' \
    "$S/q.manifest" 2>/dev/null | sort > "$S/q.got"
grep -v '^#' "$repo/tests/install-e2e/expected.manifest" | awk 'NF' | sort > "$S/q.want.all"
if [ "$drm_ours" = yes ]; then
	cp "$S/q.want.all" "$S/q.want"
else
	# on amd64 the DRM modules come from FreeBSD's drm-kmod packages:
	# this repository does not install them, so the expected list drops
	# them (the file itself is not ours to edit here)
	awk '$1 != "/boot/modules/drm.ko" && $1 != "/boot/modules/dmabuf.ko"' "$S/q.want.all" > "$S/q.want"
fi
[ -s "$S/q.got" ] && cmp -s "$S/q.got" "$S/q.want" && ok "tests/install-e2e/expected.manifest matches what install writes" \
    || bad "expected.manifest differs: $(diff "$S/q.want" "$S/q.got" | head -4 | tr '\n' ' ')"

if [ "$fail" = 0 ]; then
	echo "make_contract_test: PASS"
	exit 0
fi
echo "make_contract_test: $fail FAILED"
exit 1

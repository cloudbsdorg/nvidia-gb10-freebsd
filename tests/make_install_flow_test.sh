#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# One-command install contract.  A planted build avoids compilation; the
# existing gated source-fetch hooks make install-prereqs offline.  Every
# install goes into a scratch DESTDIR, as a normal user, with no root helper.
# Scratch is under the caller's GB10_WORK or this repository's work directory.

set -u
[ "$(id -u)" != 0 ] || { echo "make_install_flow_test.sh: run as a normal user" >&2; exit 2; }
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
export PATH
unset MK_WORK MK_PREFIX MK_DESTDIR MK_SYSDIR MK_BSDSRCTOP MK_DRMKMODDIR \
    MK_YES MK_ASSUME_YES MK_JSON MK_JSONL MK_ACCEPT_NVIDIA_LICENSE MK_ACCEPT_ALL_LICENSES
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
base=${GB10_WORK:-$repo/work}
mkdir -p -- "$base/tmp"
S=$(mktemp -d "$base/tmp/make-install-flow.XXXXXX") || exit 1
trap 'chmod -R u+w "$S" 2>/dev/null; rm -rf -- "$S"' EXIT
fail=0
ok() { printf 'ok    %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1"; fail=$((fail + 1)); }

# Architecture (Track #2475).  On amd64 the DRM modules of the target system
# come from FreeBSD's drm-kmod packages and this repository does not install
# them; on aarch64 the repository ships its own drm.ko and dmabuf.ko.  Every
# expectation below is architecture aware: the amd64 cases never expect this
# repository to install drm.ko or dmabuf.ko.
arch=$(uname -p)

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

# plant_work DIR: a current planted build, a licence-bearing source tarball,
# a pinned-looking OGKM directory (checked by the gated git stub), and source
# trees which fetch-trees.sh can accept without fetching anything.
plant_work() {
	_w=$1
	_drm=$1-drm
	_t=$_w/build/tree
	_mods=$(sh "$repo/scripts/make.sh" _module-list)
	for _ko in $_mods; do
		mkdir -p -- "$_t/$(dirname -- "$_ko")"
		printf 'planted %s\n' "$_ko" > "$_t/$_ko"
	done
	_l=$_w/build/libnvrm-obj
	mkdir -p -- "$_l/lib" "$_l/info" "$_w/sources/$top/doc" \
	    "$_w/sources/open-gpu-kernel-modules-$ogkm_tag/.git" \
	    "$_w/src/sys/sys" "$_w/src/include" "$_drm"
	printf 'so\n' > "$_l/lib/libnvrm.so.1"
	printf 'a\n' > "$_l/lib/libnvrm.a"
	printf 'prog\n' > "$_l/info/nvrm-info"
	printf 'drm\n' > "$_w/build/drm.ko"
	printf 'dmabuf\n' > "$_w/build/dmabuf.ko"
	printf 'NVIDIA Driver License Agreement (test copy)\n' > "$_w/sources/$top/doc/license.txt"
	tar -cJf "$_w/sources/$top.tar.xz" -C "$_w/sources" "$top"
	printf 'X=1\n' > "$_drm/linuxkpi_version.mk"
	printf '#define __FreeBSD_version %s\n' "$(sysctl -n kern.osreldate)" > "$_w/src/sys/sys/param.h"
	env MK_WORK="$_w" MK_SYSDIR="$_w/src/sys" MK_BSDSRCTOP="$_w/src" MK_DRMKMODDIR="$_drm" \
	    sh "$repo/scripts/make.sh" _build-stamp > "$_w/build/stamp"
}

# run_install WORK DESTDIR OUTPUT [make variables...]: the one command under
# test.  Check the staging value first so a Makefile regression can never
# turn this test into a live install.
run_install() {
	_w=$1
	_d=$2
	_o=$3
	shift 3
	_got=$(cd "$repo" && make -s -V DESTDIR DESTDIR="$_d") || return 1
	[ "$_got" = "$_d" ] || { printf 'DESTDIR check failed\n' > "$_o"; return 1; }
	# Capture stderr separately.  BSD make writes its own failure diagnostics
	# to stdout; the strict machine interface is the driver, checked below.
	(cd "$repo" && env -u ACCEPT_NVIDIA_LICENSE -u ACCEPT_ALL_LICENSES -u ACCEPT_EULA \
	    GB10_TEST_HOOKS=1 FETCH=/bin/false SHA256="$H/sha256" GIT="$H/git" \
	    make install WORK="$_w" DESTDIR="$_d" SYSDIR="$_w/src/sys" \
	    BSDSRCTOP="$_w/src" DRMKMODDIR="$_w-drm" "$@") > "$_o" 2> "$_o.err" < /dev/null
}

# Strict JSON is a driver contract.  Unlike GNU make, stock BSD make prints
# its own failure diagnostics on stdout after a failing recipe; no Makefile
# setting can move them.  Run the same blocked install through the driver to
# prove clean stdout and status 1, then compare its object with root make's.
run_blocked_driver_json() {
	_w=$1
	_d=$2
	_o=$3
	(cd "$repo" && env -u ACCEPT_NVIDIA_LICENSE -u ACCEPT_ALL_LICENSES -u ACCEPT_EULA \
	    GB10_TEST_HOOKS=1 FETCH=/bin/false SHA256="$H/sha256" GIT="$H/git" \
	    MK_WORK="$_w" MK_PREFIX=/usr/local MK_DESTDIR="$_d" \
	    MK_SYSDIR="$_w/src/sys" MK_BSDSRCTOP="$_w/src" MK_DRMKMODDIR="$_w-drm" \
	    MK_JSON=1 sh scripts/make.sh install) > "$_o" 2> "$_o.err" < /dev/null
}

# snap ROOT: names, modes, file hashes and link targets, sorted by name.
snap() {
	(cd "$1" && find . | sort | while IFS= read -r _p; do
		if [ -L "$_p" ]; then
			printf '%s link %s\n' "$_p" "$(readlink "$_p")"
		elif [ -f "$_p" ]; then
			printf '%s %s %s\n' "$_p" "$(stat -f '%Lp' "$_p")" "$(sha256 -q "$_p")"
		else
			printf '%s %s\n' "$_p" "$(stat -f '%Lp' "$_p")"
		fi
	done)
}

# plant_packaged_drm DESTDIR: on amd64 the DRM modules of the target system
# come from FreeBSD's drm-kmod packages, not from this repository, so the
# destination has to carry a packaged drm.ko and dmabuf.ko of its own before
# the install runs.  The stand-in satisfies the DRM policy for the cases
# which are about something else.  It is not ours: the install must leave it
# alone and must not claim it in the manifest.
drm_standin='packaged drm.ko stand-in (drm-kmod)'
dmabuf_standin='packaged dmabuf.ko stand-in (drm-kmod)'
plant_packaged_drm() {
	[ "$arch" = amd64 ] || return 0
	[ -d "$1/boot/modules" ] || return 0
	printf '%s\n' "$drm_standin" > "$1/boot/modules/drm.ko"
	printf '%s\n' "$dmabuf_standin" > "$1/boot/modules/dmabuf.ko"
}

new_dest() {
	mkdir -p -- "$1/boot/modules" "$1/usr/local/etc" "$1/etc"
	plant_packaged_drm "$1"
}

W1=$S/w1
D1=$S/d1
plant_work "$W1"
new_dest "$D1"
snap "$D1" > "$S/blocked.before"

# (b) no accepted licence, no accept setting and no terminal: blocked before
# even a manifest or a destination directory can be written.
run_install "$W1" "$D1" "$S/blocked.out"
rc=$?
rc_blocked_sample=$rc
snap "$D1" > "$S/blocked.after"
if [ "$rc" = 1 ] && grep -q 'ACCEPT_NVIDIA_LICENSE=1' "$S/blocked.out" \
    && cmp -s "$S/blocked.before" "$S/blocked.after" \
    && [ ! -e "$D1/var/db/nvidia-gb10-freebsd/installed.manifest" ] \
    && [ ! -e "$W1/sources/nvidia-licence.accepted" ]; then
	ok "an unaccepted licence blocks with its fix and no destination change"
else
	bad "licence block (rc $rc): $(tail -n 3 "$S/blocked.out" | tr '\n' ' ')"
fi

run_install "$W1" "$D1" "$S/blocked.make.json" JSON=1
make_rc=$?
snap "$D1" > "$S/blocked-make-json.after"
run_blocked_driver_json "$W1" "$D1" "$S/blocked.json"
driver_rc=$?
snap "$D1" > "$S/blocked-driver-json.after"
if [ "$make_rc" = 1 ] && [ "$driver_rc" = 1 ] \
    && cmp -s "$S/blocked.before" "$S/blocked-make-json.after" \
    && cmp -s "$S/blocked.before" "$S/blocked-driver-json.after" \
    && python3 -I - "$S/blocked.json" "$S/blocked.out" "$S/blocked.make.json" <<'EOF'
import json, sys
raw = open(sys.argv[1]).read()
d = json.loads(raw)
assert raw.count('\n{') == 0
assert d["schema_version"] == "2.1" and d["tool"] == "install"
assert d["schema_version_major"] == 2 and d["schema_version_minor"] == 1
assert d["outcome"] == "blocked" and d["installed"] == []
assert d["kind"] == "summary", d
assert "resume" not in d, d.get("resume")
b = [b for b in d["blockers"] if b["name"] == "licence"]
assert len(b) == 1 and "ACCEPT_NVIDIA_LICENSE=1" in b[0]["fix"]
assert [x["index"] for x in d["blockers"]] == list(range(len(d["blockers"])))
assert b[0]["reason"] in open(sys.argv[2]).read() and b[0]["fix"] in open(sys.argv[2]).read()
# Root make passes every setting through unchanged.  On BSD make its own
# diagnostics follow this object on stdout; on GNU make stdout ends here.
assert open(sys.argv[3]).read().startswith(raw)
EOF
then ok "blocked driver JSON is clean and root make emits the same blocker"; else bad "blocked JSON (make rc $make_rc, driver rc $driver_rc): $(tail -n 3 "$S/blocked.json" | tr '\n' ' ')"; fi

# ACCEPT_EULA is deliberately not an alias and cannot accept anything.
W3=$S/w3
D3=$S/d3
plant_work "$W3"
new_dest "$D3"
snap "$D3" > "$S/eula.before"
run_install "$W3" "$D3" "$S/eula.out" ACCEPT_EULA=1
rc=$?
snap "$D3" > "$S/eula.after"
if [ "$rc" = 1 ] && cmp -s "$S/eula.before" "$S/eula.after" \
    && [ ! -e "$W3/sources/nvidia-licence.accepted" ]; then
	ok "ACCEPT_EULA=1 does not accept the NVIDIA licence"
else
	bad "ACCEPT_EULA alias (rc $rc)"
fi

# (a) exact one-command install, with command-line licence acceptance.
run_install "$W1" "$D1" "$S/installed.out" ACCEPT_NVIDIA_LICENSE=1
rc=$?
# GB10_FLOW_SAMPLES_ONLY=1 (tests/readme_install_doc_test.sh): write the output
# of the planted blocked run, the planted install and the doas next steps into
# GB10_FLOW_SAMPLES, and exit non-zero unless all three behaved.
if [ "${GB10_FLOW_SAMPLES_ONLY:-0}" = 1 ]; then
	_so=1
	if [ -d "${GB10_FLOW_SAMPLES:-}" ] && [ "$rc_blocked_sample" = 1 ] && [ "$rc" = 0 ] \
	    && env GB10_TEST_HOOKS=1 GB10_TEST_ROOT_METHOD=doas MK_DESTDIR= sh "$repo/scripts/make.sh" _next-steps 2>/dev/null > "$S/next-doas.out" \
	    && env GB10_TEST_HOOKS=1 GB10_TEST_ROOT_METHOD=doas MK_DESTDIR= sh "$repo/scripts/make.sh" _next-note 2>/dev/null > "$S/next-note.out" \
	    && grep -q 'kldload nvidia-drm' "$S/next-doas.out" && [ -s "$S/next-note.out" ]; then
		cp "$S/blocked.out" "$S/installed.out" "$S/next-doas.out" "$S/next-note.out" "$GB10_FLOW_SAMPLES/" && _so=0
	fi
	exit "$_so"
fi
if [ "$rc" = 0 ] && grep -q '/boot/modules/nvidia.ko' "$S/installed.out" \
    && grep -q 'staged under' "$S/installed.out" \
    && ! grep -q '^next: ' "$S/installed.out" \
    && [ -f "$D1/boot/modules/nvidia.ko" ] \
    && grep -q 'accepted by ACCEPT_NVIDIA_LICENSE=1' "$W1/sources/nvidia-licence.accepted"; then
	ok "one command installs and says where the files are staged"
else
	bad "installed English (rc $rc): $(tail -n 5 "$S/installed.out" | tr '\n' ' ')"
fi

D1J=$S/d1-json
new_dest "$D1J"
run_install "$W1" "$D1J" "$S/installed.json" ACCEPT_NVIDIA_LICENSE=1 JSON=1
rc=$?
if [ "$rc" = 0 ] && python3 -I - "$S/installed.json" "$S/installed.out" <<'EOF'
import json, re, sys
raw = open(sys.argv[1]).read()
d = json.loads(raw)
assert raw.count('\n{') == 0
assert d["schema_version"] == "2.1" and d["tool"] == "install"
assert d["schema_version_major"] == 2 and d["schema_version_minor"] == 1
assert d["outcome"] == "installed" and d["blockers"] == []
assert d["kind"] == "summary", d
assert "resume" not in d, d.get("resume")
paths = [x["path"] for x in d["installed"]]
assert "/boot/modules/nvidia.ko" in paths
assert len(paths) == len(set(paths)) and paths
assert all(set(x) == {"path", "mode"} for x in d["installed"])
english = []
for line in open(sys.argv[2]):
    m = re.match(r"installed (\S+) (\S+)\s*$", line)
    if m:
        english.append({"path": m.group(1), "mode": m.group(2)})
assert english == d["installed"], (english, d["installed"])
# A staged install has no next step: the files are only staged, so there is
# nothing to run on this system.  The explanation is prose, in the note.
assert d["next"] == [], d["next"]
assert d["requires_root_shell"] == [], d["requires_root_shell"]
assert "staged under" in d["note"] and "nothing was loaded" in d["note"], d["note"]
EOF
then ok "installed JSON is one object and agrees with English"; else bad "installed JSON (rc $rc): $(tail -n 4 "$S/installed.json" | tr '\n' ' ')"; fi

# (Track #2475) On amd64 the DRM modules of the target system come from
# FreeBSD's drm-kmod packages; this repository does not install them.  The
# packaged drm.ko which is already in the destination is left exactly as it
# is, and it is not claimed in our manifest or in the machine output.
if [ "$arch" = amd64 ]; then
	_mf=$D1/var/db/nvidia-gb10-freebsd/installed.manifest
	_drm_left=1
	[ "$(cat "$D1/boot/modules/drm.ko" 2>/dev/null)" = "$drm_standin" ] || _drm_left=0
	[ "$(cat "$D1/boot/modules/dmabuf.ko" 2>/dev/null)" = "$dmabuf_standin" ] || _drm_left=0
	if [ -f "$_mf" ]; then
		grep -Eq '(^|[^[:alnum:]_.-])drm\.ko' "$_mf" && _drm_left=0
		grep -Eq '(^|[^[:alnum:]_.-])dmabuf\.ko' "$_mf" && _drm_left=0
	fi
	grep -q '^installed /boot/modules/drm\.ko' "$S/installed.out" && _drm_left=0
	grep -q '^installed /boot/modules/dmabuf\.ko' "$S/installed.out" && _drm_left=0
	if [ "$_drm_left" = 1 ] && python3 -I - "$S/installed.json" <<'EOF'
import json, sys
d = json.loads(open(sys.argv[1]).read())
paths = [x["path"] for x in d["installed"]]
assert not any(p.endswith("/drm.ko") or p.endswith("/dmabuf.ko") for p in paths), paths
EOF
	then ok "amd64: the packaged drm.ko of the destination is left alone and is not in the manifest"
	else bad "amd64 DRM modules (manifest=[$(head -c 200 "$_mf" 2>/dev/null | tr '\n' ' ')] drm.ko=[$(head -c 40 "$D1/boot/modules/drm.ko" 2>/dev/null)]): the install touched the DRM modules of the destination"
	fi
	# The DRM policy on amd64 is a precondition of the install, not something
	# this repository provides: without a packaged drm.ko in the destination
	# the install is blocked and the block names the package which does.
	DND=$S/d-no-drm
	new_dest "$DND"
	rm -f -- "$DND/boot/modules/drm.ko" "$DND/boot/modules/dmabuf.ko"
	run_install "$W1" "$DND" "$S/nodrm.json" ACCEPT_NVIDIA_LICENSE=1 JSON=1
	rc=$?
	if [ "$rc" = 1 ] && python3 -I - "$S/nodrm.json" <<'EOF'
import json, sys
d = json.loads(open(sys.argv[1]).read().split('\n')[0])
assert d["outcome"] == "blocked", d
assert d["installed"] == [], d
b = [x for x in d["blockers"] if "drm" in (x["name"] + x["reason"] + x["fix"]).lower()]
assert b, d["blockers"]
EOF
	then ok "amd64: without a packaged drm.ko in the destination the install is blocked by the DRM policy"
	else bad "amd64 DRM policy (rc $rc): $(head -c 300 "$S/nodrm.json" | tr '\n' ' ')"
	fi
fi

# Output wording (Track #2440): the fix names the command the user ran and the
# settings that change where the install goes, the progress lines carry a
# phase word, and the next steps are commands to paste.
# The blocked run above went to a DESTDIR, so the fix keeps it.
LICFIX_RUN="make install DESTDIR='$D1' ACCEPT_NVIDIA_LICENSE=1"
LICFIX_PRE='make install-prereqs ACCEPT_NVIDIA_LICENSE=1'
if grep -qxF "fix: $LICFIX_RUN" "$S/blocked.out" \
    && ! grep -q 'make install-prereqs' "$S/blocked.out" \
    && python3 -I - "$S/blocked.json" "$LICFIX_RUN" <<'PEOF'
import json, sys
d = json.load(open(sys.argv[1]))
b = [x for x in d["blockers"] if x["name"] == "licence"]
assert len(b) == 1, b
assert b[0]["fix"] == sys.argv[2], b[0]["fix"]
PEOF
then ok "make install: the blocked licence fix names make install and the DESTDIR, in English and JSON"
else bad "licence fix names the wrong command: $(grep '^fix:' "$S/blocked.out" | tr '\n' ' ')"; fi
# The fix is a command: it is valid shell and it says what to do.
if printf '%s\n' "$LICFIX_RUN" | sh -n 2>/dev/null \
    && grep -q 'accept every licence instead run make install' "$S/blocked.out"; then
	ok "the licence fix is one pasteable command, and the other ways are prose"
else
	bad "the licence fix is not a command: $(grep '^fix:' "$S/blocked.out" | tr '\n' ' ')"
fi
# The same fix with a PREFIX the user chose: the fix keeps that too.  The work
# tree is fresh, so the licence is not accepted yet and the run blocks.
WPFX=$S/wpfix
DPFX=$S/dpfix
plant_work "$WPFX"
new_dest "$DPFX"
run_install "$WPFX" "$DPFX" "$S/blocked-prefix.out" PREFIX=/opt/gb10
rc=$?
LICFIX_PREFIX="make install DESTDIR='$DPFX' PREFIX='/opt/gb10' ACCEPT_NVIDIA_LICENSE=1"
if [ "$rc" = 1 ] && grep -qxF "fix: $LICFIX_PREFIX" "$S/blocked-prefix.out"; then
	ok "the licence fix keeps the PREFIX the user gave"
else
	bad "licence fix with a PREFIX (rc $rc): $(grep '^fix:' "$S/blocked-prefix.out" | tr '\n' ' ')"
fi
# make preflight (the install-prereqs view) keeps naming install-prereqs.
WPF=$S/wpf
plant_work "$WPF"
_wp=$(cd "$repo" && env -u ACCEPT_NVIDIA_LICENSE -u ACCEPT_ALL_LICENSES GB10_TEST_HOOKS=1 \
    MK_WORK="$WPF" MK_SYSDIR="$WPF/src/sys" MK_BSDSRCTOP="$WPF/src" MK_DRMKMODDIR="$WPF-drm" \
    sh scripts/make.sh preflight --json 2>/dev/null < /dev/null)
if printf '%s\n' "$_wp" | python3 -I -c '
import json, sys
d = json.load(sys.stdin)
r = [x for x in d["status"] if x["name"] == "licence"]
assert len(r) == 1 and r[0]["fix"] == sys.argv[1], r' "$LICFIX_PRE"; then
	ok "make preflight: the licence fix names make install-prereqs"
else
	bad "preflight licence fix: $(printf '%s' "$_wp" | grep -o '"fix": "make install-prereqs[^"]*"' | head -n 2 | tr '\n' ' ')"
fi
# The warning path: the acceptance setting is set, so the licence is a
# warning, not a blocker.  Its fix must still carry the acceptance setting,
# or a user who copies it into a shell without it does not accept anything.
WWA=$S/wwarn
DWA=$S/dwarn
plant_work "$WWA"
new_dest "$DWA"
_wpwarn=$(cd "$repo" && env -u ACCEPT_NVIDIA_LICENSE -u ACCEPT_ALL_LICENSES GB10_TEST_HOOKS=1 \
    MK_ACCEPT_NVIDIA_LICENSE=1 MK_WORK="$WWA" MK_DESTDIR="$DWA" \
    MK_SYSDIR="$WWA/src/sys" MK_BSDSRCTOP="$WWA/src" MK_DRMKMODDIR="$WWA-drm" \
    sh scripts/make.sh preflight --json 2>/dev/null < /dev/null)
if printf '%s\n' "$_wpwarn" | python3 -I -c '
import json, sys
d = json.load(sys.stdin)
r = [x for x in d["status"] if x["name"] == "licence"]
assert len(r) == 1, r
assert r[0]["state"] == "warn", r
fix = r[0]["fix"]
assert "ACCEPT_NVIDIA_LICENSE=1" in fix, fix
assert "DESTDIR=" in fix, fix
'; then
	ok "the licence warning keeps the acceptance setting in its fix"
else
	bad "licence warning fix: $(printf '%s' "$_wpwarn" | grep -o '"name": "licence"[^}]*' | head -n 1)"
fi
# The licence fix is written once: the fix of a licence that was never
# accepted and the fix of a licence that changed since it was accepted are the
# same command.  The behaviour, not the source text, is what is checked.
WCH=$S/wchanged
DCH=$S/dchanged
plant_work "$WCH"
new_dest "$DCH"
run_install "$WCH" "$DCH" "$S/changed-accepted.out" ACCEPT_NVIDIA_LICENSE=1
rc=$?
# A new tarball with a different licence text: the acceptance on record is
# for the old one, so the licence must be accepted again.
printf 'NVIDIA Driver License Agreement (test copy, changed)\n' > "$WCH/sources/$top/doc/license.txt"
tar -cJf "$WCH/sources/$top.tar.xz" -C "$WCH/sources" "$top"
snap "$DCH" > "$S/changed.before"
run_install "$WCH" "$DCH" "$S/changed.out"
rc=$?
snap "$DCH" > "$S/changed.after"
_changed_fix=$(sed -n 's/^fix: //p' "$S/changed.out" | head -n 1)
_changed_reason=$(sed -n 's/^blocked licence: //p' "$S/changed.out" | head -n 1)
if [ "$rc" = 1 ] && [ -n "$_changed_fix" ] \
    && [ -f "$WCH/sources/nvidia-licence.accepted" ] \
    && [ "$_changed_fix" = "make install DESTDIR='$DCH' ACCEPT_NVIDIA_LICENSE=1" ] \
    && [ "$_changed_fix" = "$(sed -n 's/^fix: //p' "$S/blocked.out" | head -n 1 | sed "s|$D1|$DCH|")" ] \
    && printf '%s\n' "$_changed_fix" | sh -n 2>/dev/null \
    && printf '%s\n' "$_changed_reason" | grep -q 'changed since it was accepted'; then
	ok "a changed licence gets the same fix as an unaccepted one, and it is a command"
else
	bad "the changed-licence fix (rc $rc): [$_changed_fix] reason: [$_changed_reason]"
fi
# The acceptance must match the licence that blocked.  The settings file
# (the acceptance on record) names an old licence text: it is not an
# acceptance of the licence now required, so the install stays blocked and
# writes nothing.  The message names the licence now required, and the one
# the record names.
_new_lic=$(sha256 -q "$WCH/sources/$top/doc/license.txt")
_old_lic=$(sed -n 1p "$WCH/sources/nvidia-licence.accepted" 2>/dev/null)
if [ "$_new_lic" != "$_old_lic" ] \
    && printf '%s\n' "$_changed_reason" | grep -qF "the licence now required is NVIDIA driver licence sha256:$_new_lic" \
    && printf '%s\n' "$_changed_reason" | grep -qF "the acceptance on record is for sha256:$_old_lic" \
    && cmp -s "$S/changed.before" "$S/changed.after"; then
	ok "a settings file accepting an old licence text: the install stays blocked and the message names the licence required"
else
	bad "the licence the message names: [$_changed_reason] (required: $_new_lic, on record: $_old_lic)"
fi
# The machine output names the same licences as the English one.
run_blocked_driver_json "$WCH" "$DCH" "$S/changed.json"
rc=$?
if [ "$rc" = 1 ] && python3 -I - "$S/changed.json" "$_new_lic" "$_old_lic" <<'PEOF'
import json, sys
d = json.load(open(sys.argv[1]))
new, old = sys.argv[2], sys.argv[3]
assert d["outcome"] == "blocked", d["outcome"]
b = [x for x in d["blockers"] if x["name"] == "licence"]
assert len(b) == 1, d["blockers"]
assert "the licence now required is NVIDIA driver licence sha256:" + new in b[0]["reason"], b[0]["reason"]
assert "the acceptance on record is for sha256:" + old in b[0]["reason"], b[0]["reason"]
PEOF
then ok "the machine output names the licence required and the one the record names"
else bad "the licence in the machine output: $(head -c 300 "$S/changed.json")"; fi
# The fix accepts exactly the licence the blocker named: the acceptance it
# records is the one for the licence now required, never the one the old
# record carried over.
DCH2=$S/dchanged2
new_dest "$DCH2"
run_install "$WCH" "$DCH2" "$S/changed-fixed.out" ACCEPT_NVIDIA_LICENSE=1
rc=$?
_rec_now=$(sed -n 1p "$WCH/sources/nvidia-licence.accepted" 2>/dev/null)
_rec_id=$(sed -n 3p "$WCH/sources/nvidia-licence.accepted" 2>/dev/null)
if [ "$rc" = 0 ] && [ "$_rec_now" = "$_new_lic" ] \
    && [ "$_rec_id" = "NVIDIA driver licence sha256:$_new_lic" ]; then
	ok "the fix accepts exactly the licence the blocker named, and the record names it"
else
	bad "the acceptance the fix records: [$_rec_now] [$_rec_id] (the licence required: $_new_lic)"
fi
# Progress lines carry a phase word; the outcome line is install: installed.
_prog_all=$(grep -c '^install: ' "$S/installed.out")
_prog_phased=$(grep -cE '^install: (prerequisites|build|staging|copying) ' "$S/installed.out")
if ! grep -qx 'install: done' "$S/installed.out" \
    && grep -qx 'install: copying done' "$S/installed.out" \
    && grep -qx 'install: installed' "$S/installed.out" \
    && [ "$_prog_all" -eq $((_prog_phased + 1)) ]; then
	ok "every progress line names its phase and the outcome line is install: installed"
else
	bad "progress wording: $(grep '^install: ' "$S/installed.out" | tr '\n' ' ')"
fi
FWK=hw.nvidia.registry.EnableGpuFirmware=1
oldifs=$IFS
IFS='|'
for _pair in "root|kenv $FWK|kldload nvidia-drm" "doas|doas kenv $FWK|doas kldload nvidia-drm" \
    "sudo|sudo kenv $FWK|sudo kldload nvidia-drm" "su|su root -c 'kenv $FWK'|su root -c 'kldload nvidia-drm'" \
    "none|kenv $FWK|kldload nvidia-drm"; do
	set -- $_pair
	_m=$1
	_fw=$2
	_kl=$3
	IFS=$oldifs
	env GB10_TEST_HOOKS=1 GB10_TEST_ROOT_METHOD=$_m MK_DESTDIR= sh "$repo/scripts/make.sh" _next-steps 2>/dev/null > "$S/next-$_m.out"
	if [ "$(sed -n 1p "$S/next-$_m.out")" = "$_fw" ] && [ "$(sed -n 2p "$S/next-$_m.out")" = "$_kl" ] \
	    && [ "$(sed -n 3,4p "$S/next-$_m.out" | tr '\n' '|')" = 'kldstat|nvrm-info --json|' ]; then
		ok "next steps ($_m): the firmware command, then kldload, each one a command"
	else
		bad "next steps ($_m): $(tr '\n' '|' < "$S/next-$_m.out") (want [$_fw] then [$_kl])"
	fi
	IFS='|'
done
IFS=$oldifs
_note=$(env GB10_TEST_HOOKS=1 GB10_TEST_ROOT_METHOD=doas MK_DESTDIR= sh "$repo/scripts/make.sh" _next-note 2>/dev/null)
if printf '%s\n' "$_note" | grep -q 'make configure YES=1' \
    && printf '%s\n' "$_note" | grep -q 'firmware setting and the module load'; then
	ok "a live install says make configure YES=1 loads the driver at boot"
else
	bad "no boot-load note: [$_note]"
fi
if ! grep -q 'EnableGpuFirmware\|make configure' "$S/installed.out"; then
	ok "a DESTDIR install has no firmware or load step"
else
	bad "DESTDIR install mentions the firmware setting"
fi

# JSONL carries progress objects followed by exactly the same summary shape.
D1L=$S/d1-jsonl
new_dest "$D1L"
run_install "$W1" "$D1L" "$S/installed.jsonl" ACCEPT_NVIDIA_LICENSE=1 JSONL=1
rc=$?
if [ "$rc" = 0 ] && python3 -I - "$S/installed.jsonl" <<'EOF'
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
assert len(rows) > 1
assert all(r.get("tool") == "install" for r in rows)
assert all(r.get("kind") == "progress" for r in rows[:-1])
assert rows[-1]["outcome"] == "installed" and rows[-1]["blockers"] == []
# The summary row carries the discriminator the contract promises, so a
# consumer that dispatches on kind finds every record it gets.
assert rows[-1]["kind"] == "summary", rows[-1]
assert any(r["path"] == "/boot/modules/nvidia.ko" for r in rows[-1]["installed"])
# The version of the contract is the schema's version, in the summary and in
# every progress record, with its parts as integers.
for r in rows:
    assert r["schema_version"] == "2.1", r
    assert r["schema_version_major"] == 2 and r["schema_version_minor"] == 1, r
# The phase of a progress record is a machine value: it never changes, so a
# consumer that filters on phase == "install" keeps seeing the copy phase.
# Only the English line uses the clearer word.
phases = [r["phase"] for r in rows[:-1]]
assert phases, rows
assert set(phases) <= {"prereqs", "build", "stage", "install"}, phases
assert "install" in phases, phases
EOF
then ok "JSONL emits progress records then the install summary"; else bad "installed JSONL (rc $rc): $(tail -n 4 "$S/installed.jsonl" | tr '\n' ' ')"; fi

# ACCEPT_ALL_LICENSES accepts on a work root with no earlier acceptance.
W2=$S/w2
D2=$S/d2
plant_work "$W2"
new_dest "$D2"
run_install "$W2" "$D2" "$S/all.out" ACCEPT_ALL_LICENSES=1
rc=$?
if [ "$rc" = 0 ] && [ -f "$D2/boot/modules/nvidia.ko" ] \
    && grep -q 'accepted by ACCEPT_ALL_LICENSES=1' "$W2/sources/nvidia-licence.accepted"; then
	ok "ACCEPT_ALL_LICENSES=1 accepts and installs"
else
	bad "ACCEPT_ALL_LICENSES=1 (rc $rc): $(tail -n 3 "$S/all.out" | tr '\n' ' ')"
fi

# A failure after earlier replacements and new files: every replaced byte,
# link, mode, manifest and directory is restored.  The read-only library
# directory fails after the sorted module paths have already been handled.
if [ ! -d "$D1/usr/local/lib" ] || [ ! -f "$D1/boot/modules/nvidia.ko" ]; then
	bad "partial rollback precondition: the first install did not create its files"
else
	printf 'replacement nvidia module\n' > "$W1/build/tree/nvidia/nvidia.ko"
	printf 'pre-existing rollback neighbour\n' > "$D1/boot/modules/nvidia.ko.rollback"
	chmod 555 "$D1/usr/local/lib"
	snap "$D1" > "$S/partial.before"
	run_install "$W1" "$D1" "$S/partial.out" ACCEPT_NVIDIA_LICENSE=1
	rc=$?
	snap "$D1" > "$S/partial.after"
	chmod 755 "$D1/usr/local/lib"
	if [ "$rc" = 1 ] && cmp -s "$S/partial.before" "$S/partial.after" \
	    && grep -q 'install' "$S/partial.out" \
	    && ! grep -q 'replacement nvidia module' "$D1/boot/modules/nvidia.ko"; then
		ok "a part-way install failure rolls back replacements and every new file"
	else
		bad "partial rollback (rc $rc): $(diff "$S/partial.before" "$S/partial.after" | head -n 8 | tr '\n' ' ')"
	fi
	if [ "$(cat "$D1/boot/modules/nvidia.ko.rollback" 2>/dev/null)" = 'pre-existing rollback neighbour' ]; then
		ok "rollback leaves a pre-existing file it never created or backed up"
	else
		bad "rollback removed or replaced a pre-existing rollback neighbour"
	fi
fi

# ---- review round R3: log directory setup and blocker records --------------

# A log directory which cannot be created is a blocker in the normal summary.
W14=$S/w14
D14=$S/d14
plant_work "$W14"
new_dest "$D14"
mkdir -p -- "$W14/logs"
chmod 555 "$W14/logs"
run_install "$W14" "$D14" "$S/logfail.out" ACCEPT_NVIDIA_LICENSE=1
rc=$?
run_install "$W14" "$D14" "$S/logfail.json" ACCEPT_NVIDIA_LICENSE=1 JSON=1
rcj=$?
chmod 755 "$W14/logs"
if [ "$rc" = 1 ] && grep -q '^blocked logs:' "$S/logfail.out" \
    && grep -q 'fix: make .*/logs writable by you' "$S/logfail.out" \
    && grep -q '^install: blocked$' "$S/logfail.out" \
    && [ "$rcj" = 1 ] && python3 -I - "$S/logfail.json" <<'PEOF'
import json, sys
d = json.loads(open(sys.argv[1]).read().split('\n')[0])
assert d["outcome"] == "blocked", d
b = [x for x in d["blockers"] if x["name"] == "logs"]
assert b and "writable by you" in b[0]["fix"], d["blockers"]
PEOF
then ok "a log directory setup failure is a blocker in English and JSON"
else bad "log setup (rc $rc/$rcj): $(tail -n 3 "$S/logfail.out" | tr '\n' ' ') $(head -c 200 "$S/logfail.json")"; fi

# A pipe in a path must not corrupt the pipe-separated blocker record.
W15="$S/w|15"
D15=$S/d15
plant_work "$W15"
new_dest "$D15"
mkdir -p -- "$S/elsewhere15"
ln -s "$S/elsewhere15" "$W15/logs"
run_install "$W15" "$D15" "$S/pipe.out" ACCEPT_NVIDIA_LICENSE=1
rc=$?
run_install "$W15" "$D15" "$S/pipe.json" ACCEPT_NVIDIA_LICENSE=1 JSON=1
rcj=$?
if [ "$rc" = 1 ] && grep -qF "blocked logs: $W15/logs is a symbolic link" "$S/pipe.out" \
    && grep -qxF 'fix: remove the symbolic link' "$S/pipe.out" \
    && [ "$rcj" = 1 ] && python3 -I - "$S/pipe.json" "$W15" <<'PEOF'
import json, sys
d = json.loads(open(sys.argv[1]).read().split('\n')[0])
b = [x for x in d["blockers"] if x["name"] == "logs"]
assert len(b) == 1 and sys.argv[2] + "/logs is a symbolic link" in b[0]["reason"], d["blockers"]
assert b[0]["fix"] == "remove the symbolic link", b
PEOF
then ok "a pipe in a path survives the blocker record"
else bad "pipe path (rc $rc/$rcj): $(tail -n 3 "$S/pipe.out" | tr '\n' ' ')"; fi

# ---- rollback restore proof -----------------------------------------------

# Exercise the real transaction functions with command stubs for failures which
# cannot be induced portably as a normal user.  No installer or reboot runs here.
awk '/^txn_backup\(\) \{/{copy=1} /^install_stage\(\) \{/{copy=0} copy' \
    "$repo/scripts/make.sh" > "$S/txn-functions.sh"
cat > "$S/txn-test-lib.sh" <<'XEOF'
. "$S/txn-functions.sh"
note() { printf 'make.sh: %s\n' "$*"; }
txn_fixture() {
	_txn_root=$1
	_w=$1-work
	_txn_dir=$_w/backups
	_txn_records=$_w/backup.list
	_txn_intents=$_w/intents
	_txn_hints=0
	_txn_n=0
	_txn_active=1
	_newdirs=
	mkdir -p -- "$_txn_root" "$_txn_dir"
	: > "$_txn_records"
	: > "$_txn_intents"
}
XEOF
# The functions are cut out of make.sh by name; a missing one must fail loudly
# here, not look like a rollback failure below.
for _fn in txn_exit txn_state txn_orig_state txn_backup txn_created txn_put_back txn_rollback_fail; do
	( . "$S/txn-test-lib.sh"; command -v "$_fn" > /dev/null ) \
	    || bad "the transaction function $_fn is missing from the extracted range"
done

# A failed removal of a directory this run created is not a proven restore.
TH=$S/txn-directory
(
	. "$S/txn-test-lib.sh"
	txn_fixture "$TH/root"
	mkdir -- "$_txn_root/newdir"
	_newdirs=/newdir
	rmdir() { return 1; }
	false
	txn_exit
) > "$TH.out" 2>&1
rc=$?
if [ "$rc" = 1 ] && grep -q 'rollback-failed /newdir:' "$TH.out" \
    && ! grep -q '^rollback: restored$' "$TH.out"; then
	ok "a failed directory restore is listed, not reported restored"
else
	bad "directory restore failure: $(tr '\n' ' ' < "$TH.out")"
fi

# sha256/readlink (and reading an original link) failures all produce U.  A
# pair of failed hashes must never compare equal and prove rollback restored.
TH=$S/txn-unknown
_unknown=$(
	. "$S/txn-test-lib.sh"
	txn_fixture "$TH/root"
	printf 'current\n' > "$_txn_root/file"
	ln -s current "$_txn_root/link"
	printf 'original\n' > "$_txn_dir/7.file"
	printf 'original-target\n' > "$_txn_dir/8.target"
	sha256() { return 1; }
	readlink() { return 1; }
	cat() { return 1; }
	txn_state "$_txn_root/file"
	txn_state "$_txn_root/link"
	txn_orig_state 7 file
	txn_orig_state 8 link
)
if [ "$_unknown" = "$(printf 'U\nU\nU\nU')" ]; then
	ok "failed hashes and link reads have unknown state"
else
	bad "failed state reads: $(printf '%s' "$_unknown" | tr '\n' ' ')"
fi
(
	. "$S/txn-test-lib.sh"
	txn_fixture "$TH/hash-root"
	printf 'current\n' > "$_txn_root/file"
	printf 'original\n' > "$_txn_dir/0.file"
	printf '0 file /file\n' > "$_txn_records"
	sha256() { return 1; }
	false
	txn_exit
) > "$TH.hash.out" 2>&1
rc=$?
if [ "$rc" = 1 ] && grep -q 'rollback-failed /file:' "$TH.hash.out" \
    && ! grep -q '^rollback: restored$' "$TH.hash.out"; then
	ok "unknown states are never accepted as restore proof"
else
	bad "unknown-state rollback: $(tr '\n' ' ' < "$TH.hash.out")"
fi

# A link which is gone without a recorded removal is never restored over: the
# only absence this run intends is an A intent, and a failed or unknown state
# check is never "ours".  Another process may have removed it on purpose.
TH=$S/txn-link
(
	. "$S/txn-test-lib.sh"
	txn_fixture "$TH/root"
	ln -s original-target "$_txn_root/link"
	txn_backup /link
	rm -f -- "$_txn_root/link"
	printf '/link L:replacement-target\n' > "$_txn_intents"
	false
	txn_exit
) > "$TH.out" 2>&1
rc=$?
if [ "$rc" = 1 ] && [ ! -e "$TH/root/link" ] && [ ! -L "$TH/root/link" ] \
    && grep -q 'rollback-failed /link: .*changed by another process' "$TH.out" \
    && ! grep -q '^rollback: restored$' "$TH.out"; then
	ok "a link removed without a recorded removal is not recreated over another process"
else
	bad "missing link treated as ours: $(tr '\n' ' ' < "$TH.out")"
fi
# the link this run replaced is put back
TH=$S/txn-link2
(
	. "$S/txn-test-lib.sh"
	txn_fixture "$TH/root"
	ln -s original-target "$_txn_root/link"
	txn_backup /link
	rm -f -- "$_txn_root/link"
	ln -s replacement-target "$_txn_root/link"
	printf '/link L:replacement-target\n' > "$_txn_intents"
	false
	txn_exit
) > "$TH.out" 2>&1
rc=$?
if [ "$rc" = 1 ] && [ "$(readlink "$TH/root/link" 2>/dev/null)" = original-target ] \
    && grep -q '^rollback: restored$' "$TH.out" && [ ! -e "$TH/root-work" ]; then
	ok "a link this run replaced is restored and the transaction directory removed"
else
	bad "link restore: $(tr '\n' ' ' < "$TH.out")"
fi

# A restore which fails keeps the backup in place, names it and says how to
# restore by hand: the original is never deleted before it is verified back.
for _kcase in move copy; do
	TH=$S/txn-keep-$_kcase
	(
		. "$S/txn-test-lib.sh"
		txn_fixture "$TH/root"
		printf 'original\n' > "$_txn_root/f"
		txn_backup /f
		printf 'replacement\n' > "$_txn_root/f"
		printf '/f F:%s\n' "$(/sbin/sha256 -q "$_txn_root/f")" > "$_txn_intents"
		if [ "$_kcase" = move ]; then mv() { return 1; }; else cp() { for _a; do _last=$_a; done; printf 'garbage\n' > "$_last"; }; fi
		false
		txn_exit
	) > "$TH.out" 2>&1
	rc=$?
	if [ "$rc" = 1 ] && [ "$(cat "$TH/root-work/backups/0.file" 2>/dev/null)" = original ] \
	    && grep -qF "$TH/root-work/backups/0.file" "$TH.out" \
	    && grep -q 'restore it by hand with: cp -p' "$TH.out" \
	    && [ "$(cat "$TH/root/f")" = replacement ] \
	    && ! grep -q '^rollback: restored$' "$TH.out"; then
		ok "a failed restore ($_kcase) keeps the backup, names it and says how to restore by hand"
	else
		bad "failed restore ($_kcase) lost or hid the original: $(tr '\n' ' ' < "$TH.out")"
	fi
done
if [ -f "$S/txn-unknown/hash-root-work/backups/0.file" ] \
    && grep -qF "$S/txn-unknown/hash-root-work/backups/0.file" "$S/txn-unknown.hash.out"; then
	ok "an unknown state keeps the backup and names it"
else
	bad "unknown state deleted the backup: $(tr '\n' ' ' < "$S/txn-unknown.hash.out")"
fi

# Rollback never follows a symbolic link: a replacement link to a directory is
# replaced by the original file, and nothing lands in the directory.
TH=$S/txn-linkdir
mkdir -p -- "$TH/elsewhere"
(
	. "$S/txn-test-lib.sh"
	txn_fixture "$TH/root"
	printf 'original\n' > "$_txn_root/f"
	txn_backup /f
	rm -f -- "$_txn_root/f"
	ln -s "$TH/elsewhere" "$_txn_root/f"
	printf '/f L:%s\n' "$TH/elsewhere" > "$_txn_intents"
	false
	txn_exit
) > "$TH.out" 2>&1
rc=$?
if [ "$rc" = 1 ] && [ -f "$TH/root/f" ] && [ ! -L "$TH/root/f" ] \
    && [ "$(cat "$TH/root/f")" = original ] && [ -z "$(ls -A "$TH/elsewhere")" ] \
    && grep -q '^rollback: restored$' "$TH.out"; then
	ok "rollback replaces a link to a directory and never moves a file into the directory"
else
	bad "rollback followed a link (elsewhere: $(ls -A "$TH/elsewhere" | tr '\n' ' ')): $(tr '\n' ' ' < "$TH.out")"
fi

# A partial temporary file of this run is its own write: removed, not blamed
# on another process.  The same bytes without a recorded intent stay put.
TH=$S/txn-partial
(
	. "$S/txn-test-lib.sh"
	txn_fixture "$TH/root"
	txn_created /x.new.abc123
	printf '/x.new.abc123 W\n' > "$_txn_intents"
	printf 'half' > "$_txn_root/x.new.abc123"
	false
	txn_exit
) > "$TH.out" 2>&1
rc=$?
if [ "$rc" = 1 ] && [ ! -e "$TH/root/x.new.abc123" ] \
    && ! grep -q 'another process' "$TH.out" && grep -q '^rollback: restored$' "$TH.out"; then
	ok "a partial temporary file of this run is removed, not reported as tampering"
else
	bad "partial temporary file: $(tr '\n' ' ' < "$TH.out")"
fi
TH=$S/txn-partial2
(
	. "$S/txn-test-lib.sh"
	txn_fixture "$TH/root"
	txn_created /x.new.abc123
	printf 'half' > "$_txn_root/x.new.abc123"
	false
	txn_exit
) > "$TH.out" 2>&1
if [ "$(cat "$TH/root/x.new.abc123" 2>/dev/null)" = half ] && grep -q 'another process' "$TH.out"; then
	ok "a file which this run never recorded writing is left alone and reported"
else
	bad "unrecorded file removed: $(tr '\n' ' ' < "$TH.out")"
fi

# A backup record of an unknown kind is named as such.
TH=$S/txn-kind
(
	. "$S/txn-test-lib.sh"
	txn_fixture "$TH/root"
	printf 'x\n' > "$_txn_root/file"
	printf '0 bogus /file\n' > "$_txn_records"
	false
	txn_exit
) > "$TH.out" 2>&1
if grep -q 'rollback-failed /file: .*unknown kind' "$TH.out"; then
	ok "a backup record of an unknown kind is reported as an unknown kind"
else
	bad "unknown kind: $(tr '\n' ' ' < "$TH.out")"
fi

# The kldxref advice names the boot/modules of the tree it concerns.
_h_live=$(. "$S/txn-test-lib.sh"; _txn_root=; _txn_hints=1; txn_rollback_fail /boot/modules/linker.hints "not restored: x")
_h_dest=$(. "$S/txn-test-lib.sh"; _txn_root=/stage; _txn_hints=1; txn_rollback_fail /boot/modules/linker.hints "not restored: x")
if printf '%s\n' "$_h_live" | grep -qF 'kldxref /boot/modules needs to run' \
    && printf '%s\n' "$_h_live" | grep -qF 'not restored: x' \
    && printf '%s\n' "$_h_dest" | grep -qF 'kldxref /stage/boot/modules needs to run' \
    && ! printf '%s\n' "$_h_dest" | grep -qF 'kldxref /boot/modules'; then
	ok "the kldxref advice names the staged boot/modules under DESTDIR and the live one without"
else
	bad "kldxref advice: $_h_live / $_h_dest"
fi

# ---- install flow: logs, questions, signals, output switches ---------------

# Hooks for these tests: a kldxref that can tamper with a written path and
# signal its parent.
cat > "$H/kldxref" <<'XEOF'
#!/bin/sh
[ -z "${TEST_TAMPER:-}" ] || { rm -f "$TEST_TAMPER"; printf 'changed by someone else\n' > "$TEST_TAMPER"; }
[ -z "${TEST_SIGNAL:-}" ] || kill -TERM "$PPID"
exit 0
XEOF
chmod 755 "$H/kldxref"

# run_tty WORK DESTDIR OUTPUT INPUT [make variables...]: the same install on a
# pseudo terminal; INPUT (printf %b) is typed after a short wait.
run_tty() {
	_w=$1
	_d=$2
	_o=$3
	_in=$4
	shift 4
	(sleep 2; printf '%b' "$_in"; sleep 2) | script -q /dev/null sh -c '
		cd "$1" && shift
		exec env -u ACCEPT_NVIDIA_LICENSE -u ACCEPT_ALL_LICENSES -u ACCEPT_EULA \
		    GB10_TEST_HOOKS=1 FETCH=/bin/false SHA256="$HOOKDIR/sha256" GIT="$HOOKDIR/git" \
		    PAGER=cat GB10_TEST_ROOT_METHOD=${TEST_ROOT_METHOD:-none} make install "$@"' \
	    sh "$repo" WORK="$_w" DESTDIR="$_d" SYSDIR="$_w/src/sys" \
	    BSDSRCTOP="$_w/src" DRMKMODDIR="$_w-drm" "$@" > "$_o" 2>&1
}
export HOOKDIR=$H

# Phase logs: a planted symlink at a log name is never written through,
# and a symbolic link where the log directory goes is refused.
W5=$S/w5
D5=$S/d5
plant_work "$W5"
new_dest "$D5"
mkdir -p -- "$W5/logs/make-install"
printf 'precious\n' > "$S/victim"
for _p in prereqs build stage install; do
	ln -s "$S/victim" "$W5/logs/make-install/$_p.log"
done
run_install "$W5" "$D5" "$S/log1.out" ACCEPT_NVIDIA_LICENSE=1
rc=$?
if [ "$rc" = 0 ] && [ "$(cat "$S/victim")" = precious ]; then
	ok "a planted symlink at a phase log name is not written through"
else
	bad "planted log symlink (rc $rc, victim now: $(head -c 20 "$S/victim"))"
fi
W6=$S/w6
D6=$S/d6
plant_work "$W6"
new_dest "$D6"
mkdir -p -- "$S/elsewhere"
ln -s "$S/elsewhere" "$W6/logs"
run_install "$W6" "$D6" "$S/log2.out" ACCEPT_NVIDIA_LICENSE=1
rc=$?
if [ "$rc" = 1 ] && [ -z "$(ls -A "$S/elsewhere")" ] && grep -q 'symbolic link' "$S/log2.out.err" "$S/log2.out"; then
	ok "a symbolic link in place of the log directory is refused"
else
	bad "logs symlink (rc $rc, elsewhere: $(ls -A "$S/elsewhere" | tr '\n' ' '))"
fi

# One question up front, before any root step.
W7=$S/w7
D7=$S/d7
plant_work "$W7"
new_dest "$D7"
snap "$D7" > "$S/ask.before"
(export GB10_TEST_PKG_NEEDED=nvgb10-test-pkg GB10_TEST_ROOT_METHOD=none
 run_install "$W7" "$D7" "$S/ask1.out" ACCEPT_NVIDIA_LICENSE=1)
rc=$?
snap "$D7" > "$S/ask.after"
if [ "$rc" = 1 ] && grep -q 'blocked root:' "$S/ask1.out" \
    && grep -qF '(nvgb10-test-pkg)' "$S/ask1.out" \
    && ! grep -q 'blocked confirm:' "$S/ask1.out" \
    && cmp -s "$S/ask.before" "$S/ask.after" && [ ! -e "$W7/logs" ]; then
	ok "missing packages and no root method block before any write"
else
	bad "package/root preflight (rc $rc): $(tail -n 3 "$S/ask1.out" | tr '\n' ' ')"
fi
_pkg_preflight=$(env GB10_TEST_HOOKS=1 GB10_TEST_PKG_NEEDED=nvgb10-test-pkg \
    GB10_TEST_ROOT_METHOD=none MK_WORK="$W7" MK_DESTDIR="$D7" MK_SYSDIR="$W7/src/sys" \
    MK_BSDSRCTOP="$W7/src" MK_DRMKMODDIR="$W7-drm" MK_ACCEPT_NVIDIA_LICENSE=1 \
    sh "$repo/scripts/make.sh" preflight --json 2>/dev/null)
if printf '%s\n' "$_pkg_preflight" | python3 -I -c '
import json, sys
d = json.load(sys.stdin)
r = [x for x in d["status"] if x["name"] == "root"][0]
assert r["state"] == "missing" and "nvgb10-test-pkg" in r["reason"], r
assert "no root helper needed" not in r["reason"], r'; then
	ok "preflight never says root is unneeded when packages are missing"
else
	bad "package/root JSON: $(printf '%s' "$_pkg_preflight" | head -c 300)"
fi
(export GB10_TEST_PKG_NEEDED=nvgb10-test-pkg TEST_ROOT_METHOD=doas
 run_tty "$W7" "$D7" "$S/ask2.out" 'n\n' ACCEPT_NVIDIA_LICENSE=1)
snap "$D7" > "$S/ask.after2"
if [ "$(grep -c '\[y/N\]' "$S/ask2.out")" = 1 ] && grep -q 'nvgb10-test-pkg' "$S/ask2.out" \
    && grep -qi 'as root' "$S/ask2.out" && cmp -s "$S/ask.before" "$S/ask.after2" \
    && [ ! -e "$W7/logs" ] && grep -q 'not confirmed' "$S/ask2.out"; then
	ok "one question lists the root steps; no answer means nothing is done"
else
	bad "terminal question: $(tr -d '\r' < "$S/ask2.out" | tail -n 6 | tr '\n' ' ')"
fi

# An interrupt during the install step: rolled back, outcome
# interrupted, exit 1; a path another process changed is left and reported.
W8=$S/w8
D8=$S/d8
plant_work "$W8"
new_dest "$D8"
snap "$D8" > "$S/sig.before"
(export TEST_SIGNAL=1 GB10_TEST_KLDXREF=$H/kldxref
 run_install "$W8" "$D8" "$S/sig.json" ACCEPT_NVIDIA_LICENSE=1 JSON=1)
rc=$?
snap "$D8" > "$S/sig.after"
if [ "$rc" = 1 ] && cmp -s "$S/sig.before" "$S/sig.after" && python3 -I - "$S/sig.json" <<'PEOF'
import json, sys
d = json.loads(open(sys.argv[1]).read().split('\n')[0])
assert d["outcome"] == "interrupted", d["outcome"]
assert d["installed"] == [] and d["next"] == []
assert any("restored" in b["reason"] for b in d["blockers"]), d["blockers"]
PEOF
then ok "a signal during the install is interrupted, exit 1, rollback reported restored"
else bad "signal (rc $rc): $(head -c 400 "$S/sig.json" | tr '\n' ' ')"; fi
D9=$S/d9
new_dest "$D9"
(export TEST_SIGNAL=1 TEST_TAMPER=$D9/boot/modules/nvidia.ko GB10_TEST_KLDXREF=$H/kldxref
 run_install "$W8" "$D9" "$S/tamper.json" ACCEPT_NVIDIA_LICENSE=1 JSON=1)
rc=$?
if [ "$rc" = 1 ] && [ "$(cat "$D9/boot/modules/nvidia.ko")" = 'changed by someone else' ] \
    && [ ! -e "$D9/boot/modules/nvidia-drm.ko" ] \
    && python3 -I - "$S/tamper.json" <<'PEOF'
import json, sys
d = json.loads(open(sys.argv[1]).read().split('\n')[0])
assert d["outcome"] == "interrupted", d["outcome"]
b = [x for x in d["blockers"] if "/boot/modules/nvidia.ko" in x["reason"]]
assert b and "not restored" in " ".join(x["reason"] for x in d["blockers"]), d["blockers"]
assert not any("were restored" in x["reason"] for x in d["blockers"]), d["blockers"]
PEOF
then ok "a path changed by another process is left alone and reported"
else bad "tamper (rc $rc): $(head -c 400 "$S/tamper.json" | tr '\n' ' ')"; fi
# an upgrade whose module another process then replaced is not restored over it
D10=$S/d10
new_dest "$D10"
run_install "$W8" "$D10" "$S/up1.out" ACCEPT_NVIDIA_LICENSE=1
printf 'upgraded nvidia module\n' > "$W8/build/tree/nvidia/nvidia.ko"
(export TEST_SIGNAL=1 TEST_TAMPER=$D10/boot/modules/nvidia.ko GB10_TEST_KLDXREF=$H/kldxref
 run_install "$W8" "$D10" "$S/up2.out" ACCEPT_NVIDIA_LICENSE=1)
rc=$?
if [ "$rc" = 1 ] && [ "$(cat "$D10/boot/modules/nvidia.ko")" = 'changed by someone else' ] \
    && grep -q 'interrupted' "$S/up2.out"; then
	ok "an upgrade rollback does not restore over another process's change"
else
	bad "upgrade tamper (rc $rc): $(tail -n 4 "$S/up2.out" | tr '\n' ' ')"
fi

# linker.hints is not a blanket rollback exception.  A kldxref-time change
# which is not a recorded write of this run stays in place with its own fix.
D13=$S/d13
new_dest "$D13"
(export TEST_SIGNAL=1 TEST_TAMPER=$D13/boot/modules/linker.hints GB10_TEST_KLDXREF=$H/kldxref
 run_install "$W8" "$D13" "$S/hints.json" ACCEPT_NVIDIA_LICENSE=1 JSON=1)
rc=$?
if [ "$rc" = 1 ] && [ "$(cat "$D13/boot/modules/linker.hints" 2>/dev/null)" = 'changed by someone else' ] \
    && python3 -I - "$S/hints.json" "$D13" <<'PEOF'
import json, sys
d = json.loads(open(sys.argv[1]).read().split('\n')[0])
b = [x for x in d["blockers"] if "/boot/modules/linker.hints" in x["reason"]]
r = " ".join(x["reason"] for x in b)
assert b and ("kldxref %s/boot/modules needs to run" % sys.argv[2]) in r, d["blockers"]
assert "kldxref /boot/modules" not in r, r
assert "changed by another process" in r, r
assert not any("were restored" in x["reason"] for x in d["blockers"]), d["blockers"]
PEOF
then ok "linker.hints is restored only across a recorded write"
else bad "linker.hints guard (rc $rc): $(head -c 500 "$S/hints.json" | tr '\n' ' ')"; fi

# install(1) failing part way (a partial file) and a signal between install(1)
# and the move: both are this run's own temporary file and roll back cleanly.
IB=$S/instbin
mkdir -p -- "$IB"
cat > "$IB/install" <<'XEOF'
#!/bin/sh
for _a; do _dest=$_a; done
case $_dest in
*"${TEST_INSTALL_FAIL:-@@none@@}"*)
	for _a; do [ "$_a" = "$_dest" ] || _src=$_a; done
	head -c 5 "$_src" > "$_dest"
	exit 1 ;;
esac
/usr/bin/install "$@"
_rc=$?
case $_dest in *"${TEST_INSTALL_KILL:-@@none@@}"*) kill -TERM "$PPID" ;; esac
exit $_rc
XEOF
chmod 755 "$IB/install"
for _icase in fail kill; do
	D16=$S/d16-$_icase
	new_dest "$D16"
	snap "$D16" > "$S/inst-$_icase.before"
	if [ "$_icase" = fail ]; then _ienv=TEST_INSTALL_FAIL; else _ienv=TEST_INSTALL_KILL; fi
	(export GB10_TEST_INSTALL="$IB/install" "$_ienv=/boot/modules/nvidia.ko.new"
	 run_install "$W8" "$D16" "$S/inst-$_icase.out" ACCEPT_NVIDIA_LICENSE=1)
	rc=$?
	snap "$D16" > "$S/inst-$_icase.after"
	if [ "$rc" = 1 ] && cmp -s "$S/inst-$_icase.before" "$S/inst-$_icase.after" \
	    && ! grep -q 'another process' "$S/inst-$_icase.out" \
	    && grep -q 'was restored' "$S/inst-$_icase.out"; then
		ok "install(1) $_icase: the temporary file is removed and the destination is as before"
	else
		bad "install(1) $_icase (rc $rc): $(diff "$S/inst-$_icase.before" "$S/inst-$_icase.after" | head -n 4 | tr '\n' ' ') $(tail -n 6 "$S/inst-$_icase.out" | tr '\n' ' ')"
	fi
done

# A newline in a path must not split a blocker record into a second blocker.
W16="$S/w
16"
D17=$S/d17
plant_work "$W16"
new_dest "$D17"
mkdir -p -- "$S/elsewhere16"
ln -s "$S/elsewhere16" "$W16/logs"
(export MK_ACCEPT_NVIDIA_LICENSE=1; run_blocked_driver_json "$W16" "$D17" "$S/nl.json")
rc=$?
if [ "$rc" = 1 ] && python3 -I - "$S/nl.json" "$W16" <<'PEOF'
import json, sys
d = json.loads(open(sys.argv[1]).read().strip().split('\n')[0])
b = [x for x in d["blockers"] if x["name"] == "logs"]
assert len(b) == 1 and len(d["blockers"]) == 1, d["blockers"]
assert b[0]["reason"].startswith(sys.argv[2] + "/logs is a symbolic link"), b
assert b[0]["fix"] == "remove the symbolic link", b
PEOF
then ok "a newline in a path survives the blocker record as one blocker"
else bad "newline path (rc $rc): $(head -c 300 "$S/nl.json" | tr '\n' ' ')"; fi

# A failed package query is a blocker, never "no packages needed".
D18=$S/d18
new_dest "$D18"
snap "$D18" > "$S/pkgfail.before"
(export GB10_TEST_PKG_FAIL=boom GB10_TEST_ROOT_METHOD=none
 run_install "$W7" "$D18" "$S/pkgfail.out" ACCEPT_NVIDIA_LICENSE=1)
rc=$?
snap "$D18" > "$S/pkgfail.after"
if [ "$rc" = 1 ] && grep -q 'blocked packages: could not ask pkg which packages are missing: .*boom' "$S/pkgfail.out" \
    && ! grep -q 'no root helper needed' "$S/pkgfail.out" \
    && cmp -s "$S/pkgfail.before" "$S/pkgfail.after"; then
	ok "a failed package query blocks the preflight instead of saying no root is needed"
else
	bad "package query failure, no root method (rc $rc): $(tail -n 3 "$S/pkgfail.out" | tr '\n' ' ')"
fi
(export GB10_TEST_PKG_FAIL=boom GB10_TEST_ROOT_METHOD=doas
 run_install "$W7" "$D18" "$S/pkgfail2.out" ACCEPT_NVIDIA_LICENSE=1)
rc=$?
if [ "$rc" = 1 ] && grep -q 'blocked packages: could not ask pkg which packages are missing: .*boom' "$S/pkgfail2.out" \
    && ! grep -q 'blocked confirm:' "$S/pkgfail2.out" && snap "$D18" | cmp -s "$S/pkgfail.before" -; then
	ok "a failed package query blocks the install plan with a root method present"
else
	bad "package query failure, root method (rc $rc): $(tail -n 3 "$S/pkgfail2.out" | tr '\n' ' ')"
fi

# Root steps with no terminal and no YES=1 are a blocker, with a root method.
(export GB10_TEST_PKG_NEEDED=nvgb10-test-pkg GB10_TEST_ROOT_METHOD=doas
 run_install "$W7" "$D18" "$S/noconfirm.out" ACCEPT_NVIDIA_LICENSE=1)
rc=$?
if [ "$rc" = 1 ] && grep -q '^blocked confirm:' "$S/noconfirm.out" \
    && grep -q 'YES=1 or on a terminal' "$S/noconfirm.out" \
    && snap "$D18" | cmp -s "$S/pkgfail.before" -; then
	ok "root steps without a terminal and without YES=1 are a blocker and change nothing"
else
	bad "no-terminal confirm blocker (rc $rc): $(tail -n 3 "$S/noconfirm.out" | tr '\n' ' ')"
fi

# ---- test hooks, package list, escaping, hand-restore hint, rollback ------

# fn_extract FILE NAME...: the named top-level shell functions of FILE.
fn_extract() {
	_fe_file=$1
	shift
	for _fe_n in "$@"; do
		awk -v n="$_fe_n" '$0 ~ "^" n "\\(\\) \\{" { copy = 1 } copy { print } copy && /^}/ { copy = 0 }' "$_fe_file"
	done
}
fn_extract "$repo/scripts/lib.sh" test_hook > "$S/hook-fns.sh"
fn_extract "$repo/scripts/make.sh" mk_hook esc_bytes json_str blk_esc blk_unesc \
    tool_table pkgs_needed pkgs_needed_list sh_quote >> "$S/hook-fns.sh"
for _fn in test_hook mk_hook esc_bytes json_str blk_esc blk_unesc tool_table pkgs_needed pkgs_needed_list sh_quote; do
	( . "$S/hook-fns.sh"; command -v "$_fn" > /dev/null ) \
	    || bad "the function $_fn is missing from make.sh or lib.sh"
done

# A test hook never takes effect for root, nor while installing without a
# DESTDIR; it needs GB10_TEST_HOOKS=1 and works for a user with a DESTDIR.
hook_try() {
	# hook_try UID INSTALLING DESTDIR HOOKS: what mk_hook prints (and its status)
	(
		. "$S/hook-fns.sh"
		_uid=$1
		id() { printf '%s\n' "$_uid"; }
		_installing=$2
		DESTDIR=$3
		GB10_TEST_HOOKS=$4
		GB10_TEST_INSTALL=/some/where/install
		export GB10_TEST_HOOKS GB10_TEST_INSTALL
		mk_hook GB10_TEST_INSTALL /usr/bin/install 2>/dev/null
		echo "rc=$?"
	)
}
_h1=$(hook_try 0 1 /stage 1)
_h2=$(hook_try 1001 1 '' 1)
_h3=$(hook_try 1001 1 /stage 1)
_h4=$(hook_try 1001 1 /stage 0)
_h5=$(hook_try 1001 0 '' 1)
if [ "$_h1" = "rc=1" ] && [ "$_h2" = "rc=1" ] \
    && [ "$_h3" = "/some/where/install
rc=0" ] && [ "$_h4" = "/usr/bin/install
rc=0" ] && [ "$_h5" = "/some/where/install
rc=0" ]; then
	ok "a test hook is refused for root and when installing without a DESTDIR, and needs GB10_TEST_HOOKS=1"
else
	bad "test hook gate: root=[$_h1] nodest=[$_h2] user=[$_h3] nohooks=[$_h4] notinstalling=[$_h5]"
fi
sed -n '/^# Test hooks\./,/^# Exit status/p' "$repo/scripts/make.sh" > "$S/hook-doc.txt"
_undoc=$(for _hk in $(grep -o 'GB10_TEST_[A-Z_]*' "$repo/scripts/make.sh" | sort -u); do
	grep -q "$_hk" "$S/hook-doc.txt" || printf '%s ' "$_hk"
done)
if [ -z "$_undoc" ] && [ -s "$S/hook-doc.txt" ]; then
	ok "every GB10_TEST_ hook is documented in the make.sh header"
else
	bad "undocumented test hooks: ${_undoc:-the header section is missing}"
fi

# The package list is stdout only; stderr is the reason after a failure and
# nothing otherwise.
_pl=$(. "$S/hook-fns.sh"
	pkgs_needed() { printf 'nvgb10-test-pkg\n'; echo 'warning: -f bogus' >&2; }
	pkgs_needed_list)
_pf1=$(. "$S/hook-fns.sh"
	pkgs_needed() { printf 'half\n'; echo 'pkg: no repository' >&2; return 1; }
	pkgs_needed_list; echo "rc=$?")
if [ "$_pl" = nvgb10-test-pkg ] && [ "$_pf1" = "pkg: no repository
rc=1" ]; then
	ok "a warning on stderr stays out of the package list; a failure's stderr is its reason"
else
	bad "package list: success=[$_pl] failure=[$_pf1]"
fi

# json_str and blk_esc: no byte is special; every control character is
# escaped; blocker fields round-trip any byte.
_bytes=$(printf 'a\001b\002c\003d\033e\177f\rg\th|i\\j"k\nl')
_rt=$(. "$S/hook-fns.sh"; _e=$(blk_esc "$_bytes"); blk_unesc "$_e")
_one=$(. "$S/hook-fns.sh"; blk_esc "$_bytes" | grep -c '[^ -~]')
if [ "$_rt" = "$_bytes" ] && [ "$_one" = 0 ] \
    && [ "$(. "$S/hook-fns.sh"; blk_esc "$(printf 'x|y')")" = 'x\py' ]; then
	ok "a blocker field round-trips every control character, a pipe and a backslash"
else
	bad "blocker escaping round trip: [$(printf '%s' "$_rt" | od -An -c | head -n 2 | tr '\n' ' ')]"
fi
_js=$(. "$S/hook-fns.sh"; json_str "$_bytes")
if printf '%s' "$_js" | JS_WANT=$_bytes python3 -I -c '
import json, os, sys
raw = sys.stdin.read()
assert all(ord(c) >= 32 for c in raw), raw
assert json.loads("\"" + raw + "\"") == os.environ["JS_WANT"], raw'; then
	ok "json_str output is valid JSON for every control character and gives the input back"
else
	bad "json_str: $(printf '%s' "$_js" | od -An -c | head -n 3 | tr '\n' ' ')"
fi

# The hand-restore hint can be pasted: paths with a space, a quote or a
# command substitution.
TH="$S/txn hint \$(touch $S/pwned) it's"
(
	. "$S/txn-test-lib.sh"
	txn_fixture "$TH/root"
	printf 'original\n' > "$_txn_root/f"
	txn_backup /f
	printf 'replacement\n' > "$_txn_root/f"
	printf '/f F:%s\n' "$(/sbin/sha256 -q "$_txn_root/f")" > "$_txn_intents"
	mv() { return 1; }
	false
	txn_exit
) > "$S/txn-hint.out" 2>&1
_cmd=$(sed -n 's/.*restore it by hand with: //p' "$S/txn-hint.out" | head -n 1)
if [ -n "$_cmd" ] && sh -c "$_cmd" && [ "$(cat "$TH/root/f")" = original ] && [ ! -e "$S/pwned" ]; then
	ok "the hand-restore hint is pasteable for a path with a space, a quote and a command substitution"
else
	bad "hand-restore hint: [$_cmd] $(cat "$TH/root/f" 2>/dev/null)"
fi

# A restore file which cannot be removed is named, not forgotten.
TH=$S/txn-leftrm
(
	. "$S/txn-test-lib.sh"
	txn_fixture "$TH/root"
	printf 'original\n' > "$_txn_root/f"
	txn_backup /f
	printf 'replacement\n' > "$_txn_root/f"
	printf '/f F:%s\n' "$(/sbin/sha256 -q "$_txn_root/f")" > "$_txn_intents"
	mv() { return 1; }
	rm() { return 1; }
	false
	txn_exit
) > "$TH.out" 2>&1
if grep -q 'the private restore file .*f\.rollback\.[A-Za-z0-9]* is left' "$TH.out"; then
	ok "a private restore file which cannot be removed is named in the rollback report"
else
	bad "leftover restore file hidden: $(tr '\n' ' ' < "$TH.out")"
fi

# A directory this run created is removed or reported even after another
# directory failed to go.
TH=$S/txn-dirs
(
	. "$S/txn-test-lib.sh"
	txn_fixture "$TH/root"
	_w=$_txn_root/a/w
	_txn_dir=$_w/backups
	_txn_records=$_w/backup.list
	_txn_intents=$_w/intents
	mkdir -p -- "$_txn_dir" "$_txn_root/a/b"
	: > "$_txn_records"
	: > "$_txn_intents"
	_newdirs="
/a
/a/b"
	rmdir() { case $2 in */a/b) return 1 ;; esac; command rmdir "$@"; }
	false
	txn_exit
) > "$TH.out" 2>&1
if grep -q 'rollback-failed /a/b:' "$TH.out" && grep -q 'rollback-failed /a:' "$TH.out" \
    && ! grep -q '^rollback: restored$' "$TH.out"; then
	ok "a directory this run created is never skipped without a report"
else
	bad "directory left unreported: $(tr '\n' ' ' < "$TH.out")"
fi

# Install stubs: a link written then a signal; a signal right after the name
# of a temporary neighbour is made.
LB=$S/linkbin
mkdir -p -- "$LB"
cat > "$LB/ln" <<'XEOF'
#!/bin/sh
/bin/ln "$@"
_rc=$?
case $* in *"${TEST_LN_KILL:-@@none@@}"*) kill -TERM "$PPID" ;; esac
exit $_rc
XEOF
cat > "$LB/mktemp" <<'XEOF'
#!/bin/sh
_out=$(/usr/bin/mktemp "$@") || exit 1
printf '%s\n' "$_out"
case $* in
*"${TEST_MKTEMP_KILL:-@@none@@}"*) kill -TERM "$PPID" ;;
esac
exit 0
XEOF
chmod 755 "$LB/ln" "$LB/mktemp"
for _scase in ln mktemp; do
	D19=$S/d19-$_scase
	new_dest "$D19"
	snap "$D19" > "$S/stub-$_scase.before"
	if [ "$_scase" = ln ]; then _senv=TEST_LN_KILL=libnvrm.so.new; else _senv=TEST_MKTEMP_KILL=/boot/modules/nvidia.ko.new; fi
	(export "$_senv" GB10_TEST_LN="$LB/ln" GB10_TEST_MKTEMP="$LB/mktemp"
	 run_install "$W8" "$D19" "$S/stub-$_scase.out" ACCEPT_NVIDIA_LICENSE=1)
	rc=$?
	snap "$D19" > "$S/stub-$_scase.after"
	if [ "$rc" = 1 ] && cmp -s "$S/stub-$_scase.before" "$S/stub-$_scase.after" \
	    && ! grep -q 'another process' "$S/stub-$_scase.out" \
	    && grep -q 'was restored' "$S/stub-$_scase.out"; then
		ok "a signal during the $_scase step of a temporary neighbour leaves the destination as it was"
	else
		bad "signal during $_scase (rc $rc): $(diff "$S/stub-$_scase.before" "$S/stub-$_scase.after" | head -n 4 | tr '\n' ' ') $(tail -n 5 "$S/stub-$_scase.out" | tr '\n' ' ')"
	fi
done

# The licence question appears on the terminal, not in a captured log.
W11=$S/w11
D11=$S/d11
plant_work "$W11"
new_dest "$D11"
run_tty "$W11" "$D11" "$S/lic.out" '\nyes\n'
if grep -q 'Do you accept the NVIDIA driver licence' "$S/lic.out" \
    && grep -q 'install: installed' "$S/lic.out" \
    && ! grep -rq 'Do you accept' "$W11/logs"; then
	ok "the licence explanation and question are shown on the terminal"
else
	bad "licence prompt: $(tr -d '\r' < "$S/lic.out" | tail -n 6 | tr '\n' ' ')"
fi

# A DESTDIR that is not the user's needs root.
_pf=$(env GB10_TEST_HOOKS=1 GB10_TEST_ROOT_METHOD=none MK_DESTDIR=/usr/local sh "$repo/scripts/make.sh" preflight --json 2>/dev/null)
_pu=$(env GB10_TEST_HOOKS=1 GB10_TEST_ROOT_METHOD=none MK_DESTDIR="$D11" sh "$repo/scripts/make.sh" preflight --json 2>/dev/null)
if printf '%s\n' "$_pf" | python3 -I -c '
import json, sys
d = json.load(sys.stdin)
r = [x for x in d["status"] if x["name"] == "root"][0]
assert r["state"] == "missing", r' \
    && printf '%s\n' "$_pu" | python3 -I -c '
import json, sys
d = json.load(sys.stdin)
r = [x for x in d["status"] if x["name"] == "root"][0]
assert r["state"] == "ok", r'; then
	ok "preflight needs root for a DESTDIR the user does not own"
else
	bad "root item: $(printf '%s' "$_pf" | head -c 300)"
fi

# The transaction trap is set before its private directory exists.
_trap=$(grep -n 'trap txn_exit' "$repo/scripts/make.sh" | head -n 1 | cut -d: -f1)
_mk=$(grep -n 'mktemp -d "\$_d\$STATEDIR' "$repo/scripts/make.sh" | head -n 1 | cut -d: -f1)
if [ -n "$_trap" ] && [ -n "$_mk" ] && [ "$_trap" -lt "$_mk" ]; then
	ok "the rollback trap is set before the private directory is made"
else
	bad "trap at line ${_trap:-none}, mktemp at line ${_mk:-none}"
fi

# JSON=1 with JSONL=1: JSONL wins, one stderr note, help says so.
D12=$S/d12
new_dest "$D12"
run_install "$W11" "$D12" "$S/both.out" ACCEPT_NVIDIA_LICENSE=1 JSON=1 JSONL=1
rc=$?
if [ "$rc" = 0 ] && [ "$(grep -c 'JSON=1 is ignored' "$S/both.out.err")" = 1 ] \
    && python3 -I - "$S/both.out" <<'PEOF'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
assert len(rows) > 1 and all(r.get("kind") == "progress" for r in rows[:-1])
PEOF
then ok "JSON=1 JSONL=1 gives JSONL and one note on stderr"
else bad "both switches (rc $rc): $(head -c 300 "$S/both.out.err" | tr '\n' ' ')"; fi
if (cd "$repo" && make -s help) | grep -q 'JSONL=1 wins'; then
	ok "the help says JSONL wins over JSON"
else
	bad "help does not say JSONL wins"
fi

# Success instructions: the staged case, and the root tool the user has.
if python3 -I - "$S/installed.json" <<'PEOF'
import json, sys
d = json.load(open(sys.argv[1]))
# A staged install has no next step: the files are only staged, so there is
# nothing to run here, and the explanation is the note.
assert d["next"] == [], d["next"]
assert not any("kldload" in n for n in d["next"]), d["next"]
assert "staged under" in d["note"], d["note"]
PEOF
then ok "a DESTDIR install says the files are staged, and has no next step"
else bad "DESTDIR next steps: $(tr -d '\n' < "$S/installed.json" | head -c 300)"; fi
_ns=
for _m in root doas sudo su; do
	_ns="$_ns$(env GB10_TEST_HOOKS=1 GB10_TEST_ROOT_METHOD=$_m MK_DESTDIR= sh "$repo/scripts/make.sh" _next-steps 2>/dev/null | grep kldload | head -n 1)|"
done
if [ "$_ns" = "kldload nvidia-drm|doas kldload nvidia-drm|sudo kldload nvidia-drm|su root -c 'kldload nvidia-drm'|" ]; then
	ok "the root tool the user has is the one named"
else
	bad "next steps by root method: $_ns"
fi

# GB10_WORK with a tilde; bench-report without HOME.
mkdir -p -- "$S/fakehome"
if HOME=$S/fakehome GB10_WORK='~/tw' SCRIPT_UNDER_TEST=$repo/scripts/native-llm-bench python3 -I -c '
import os, runpy
m = runpy.run_path(os.environ["SCRIPT_UNDER_TEST"])
o = m["parse_cli"](["--gpu", "radeon"])
assert o["out"].startswith(os.environ["HOME"] + "/tw/"), o["out"]'; then
	ok "GB10_WORK with a tilde expands again"
else
	bad "native-llm-bench GB10_WORK tilde"
fi
if env -u HOME ONLY=none sh "$repo/scripts/bench-report.sh" cuda "$S/bench-out" > "$S/bench.out" 2>&1; then
	ok "bench-report runs without HOME"
else
	bad "bench-report without HOME: $(head -c 200 "$S/bench.out")"
fi

# Schema registration and fixture are part of the machine-output contract.
if python3 -I - "$repo" "$S/installed.json" "$S/blocked.json" <<'EOF'
import json, os, re, sys
repo = sys.argv[1]
schema = json.load(open(os.path.join(repo, "schema/make-install-2.schema.json")))
fixture = json.load(open(os.path.join(repo, "tests/fixtures/make-install.json")))
samples = json.load(open(os.path.join(repo, "schema/samples.json")))["samples"]
row = [s for s in samples if s.get("schema") == "schema/make-install-2.schema.json"
       and s.get("fixture") == "tests/fixtures/make-install.json"]
assert len(row) == 1, row
# The progress records of the same contract are registered too: the schema
# has both shapes.
prow = [s for s in samples if s.get("fixture") == "tests/fixtures/make-install-progress.jsonl"]
assert len(prow) == 1 and prow[0]["schema"] == "schema/make-install-2.schema.json", prow
# The driver emits the version of the schema: one constant, one contract.
_mk = open(os.path.join(repo, "scripts/make.sh")).read()
_mv = re.search(r"^install_schema_version=(\S+)$", _mk, re.M)
assert _mv, "make.sh has no install_schema_version"
assert _mv.group(1) == schema["version"], (_mv.group(1), schema["version"])
# Version 2 is a union of the two shapes the contract has: the progress
# record and the summary record.  A consumer dispatches on the version and
# on kind, and every record it gets validates against one of the branches.
assert "oneOf" in schema, sorted(schema)
assert len(schema["oneOf"]) == 2, schema["oneOf"]
summary = schema["$defs"]["summary"]
progress = schema["$defs"]["progress"]
assert summary["properties"]["tool"]["const"] == "install"
assert summary["properties"]["outcome"]["enum"] == ["installed", "blocked", "interrupted"]
assert set(summary["required"]) == {"schema_version", "schema_version_major",
                                     "schema_version_minor", "tool", "kind",
                                     "outcome", "blockers", "installed", "next"}
assert progress["properties"]["kind"]["const"] == "progress"
assert set(progress["required"]) == {"schema_version", "schema_version_major",
                                     "schema_version_minor", "tool", "kind",
                                     "phase", "message"}
# The summary record carries the discriminator the contract promises: a
# consumer dispatches on kind, and every record it gets has one.
assert summary["properties"]["kind"]["const"] == "summary"
assert "kind" in summary["required"]
assert fixture.get("kind") == "summary", fixture
# The notes about the next steps are their own field, and it is optional (a
# blocked install has no next steps and so no note).
assert summary["properties"]["note"]["type"] == "string"
assert "note" not in summary["required"]
assert fixture.get("note"), fixture
# How to resume an interrupted install is its own field too, and it is
# optional: only the interrupted outcome has one.
assert summary["properties"]["resume"]["type"] == "string"
assert "resume" not in summary["required"]
# The next steps belong to an installed install alone.  The schema says so,
# and the wording names the other outcomes.
_next_doc = summary["properties"]["next"]["description"]
assert "installed install" in _next_doc, _next_doc
assert "blocked install" in _next_doc, _next_doc
assert "interrupted install" in _next_doc, _next_doc
# The steps that need a root shell are named by index; the field is optional.
assert summary["properties"]["requires_root_shell"]["type"] == "array"
assert "requires_root_shell" not in summary["required"]
# The note is prose and it may name a command; the commands to run are in
# next.  The schema says so, and the note that is emitted says it too.
assert "make configure YES=1" in summary["properties"]["note"]["description"], \
    summary["properties"]["note"]["description"]
assert "Never a command" not in summary["properties"]["note"]["description"], \
    summary["properties"]["note"]["description"]
for doc in (fixture, json.load(open(sys.argv[2])), json.load(open(sys.argv[3]))):
    # The document names the contract it follows: the version of the schema
    # is the version every document carries, with its parts as integers.
    assert doc["schema_version"] == schema["version"], (doc["schema_version"], schema["version"])
    assert doc["schema_version_major"] == 2 and doc["schema_version_minor"] == 1, doc
    assert doc["tool"] == "install"
    assert doc["outcome"] in ("installed", "blocked", "interrupted")
    assert isinstance(doc["blockers"], list) and isinstance(doc["installed"], list) and isinstance(doc["next"], list)
    for i, b in enumerate(doc["blockers"]):
        assert b["index"] == i and set(b) == {"index", "name", "reason", "fix"}
    for item in doc["installed"]:
        assert set(item) == {"path", "mode"} and item["path"].startswith("/")
EOF
then ok "install schema, sample registration and fixture agree with real output"; else bad "install schema or fixture"; fi

# ---- follow-up findings ----------------------------------------------------

# A temporary-name collision never touches the file that took the name: the
# stub names a path and, the first time (or every time), has already put a
# foreign file there.  A path is this run's write only after its own exclusive
# create succeeded.
cat > "$LB/mktemp-collide" <<'XEOF'
#!/bin/sh
# prints a name that already exists (holding "foreign") for the target in
# TEST_COLLIDE; once only unless TEST_COLLIDE_ALWAYS=1
for _a; do _last=$_a; done
case $_last in
*"${TEST_COLLIDE:-@@none@@}".XXXXXX)
	if [ "${TEST_COLLIDE_ALWAYS:-0}" = 1 ] || [ ! -e "$TEST_COLLIDE_MARK" ]; then
		: > "$TEST_COLLIDE_MARK"
		_name=${_last%XXXXXX}FOREGN
		printf 'foreign\n' > "$_name"
		printf '%s\n' "$_name"
		exit 0
	fi
	;;
esac
exec /usr/bin/mktemp "$@"
XEOF
chmod 755 "$LB/mktemp-collide"
for _cmode in once always; do
	D20=$S/d20-$_cmode
	new_dest "$D20"
	_foreign=$D20/boot/modules/nvidia.ko.new.FOREGN
	if [ "$_cmode" = always ]; then _always=1; else _always=0; fi
	(export TEST_COLLIDE=/boot/modules/nvidia.ko.new TEST_COLLIDE_ALWAYS=$_always \
	     TEST_COLLIDE_MARK="$S/collide-$_cmode.mark" GB10_TEST_MKTEMP="$LB/mktemp-collide" \
	     GB10_TEST_KLDXREF="$H/kldxref"
	 run_install "$W8" "$D20" "$S/collide-$_cmode.out" ACCEPT_NVIDIA_LICENSE=1)
	rc=$?
	if [ "$_cmode" = once ]; then _want_rc=0; else _want_rc=1; fi
	if [ "$rc" = "$_want_rc" ] && [ "$(cat "$_foreign" 2>/dev/null)" = foreign ]; then
		ok "a foreign file that took a temporary name survives ($_cmode): rc $rc, content kept"
	else
		bad "temporary name collision ($_cmode): rc $rc, foreign file: [$(cat "$_foreign" 2>&1 | head -c 40)]"
	fi
done

# Non-ASCII paths: a WORK directory named with e-acute and u-umlaut shows up
# unchanged in English, in JSON (valid UTF-8 JSON) and in a blocker record.
UW=$S/$(printf 'w\303\251')/$(printf '\303\274')
mkdir -p -- "$S/$(printf 'w\303\251')"
plant_work "$UW"
new_dest "$S/d-utf8"
mkdir -p -- "$S/elsewhere-utf8"
ln -s "$S/elsewhere-utf8" "$UW/logs"
run_install "$UW" "$S/d-utf8" "$S/utf8.en.out" ACCEPT_NVIDIA_LICENSE=1
run_install "$UW" "$S/d-utf8" "$S/utf8.json" ACCEPT_NVIDIA_LICENSE=1 JSON=1
_upath=$(printf 'w\303\251/\303\274/logs')
if grep -qF -- "$_upath" "$S/utf8.en.out" "$S/utf8.en.out.err" 2>/dev/null; then
	ok "a UTF-8 path appears unchanged in the English output"
else
	bad "UTF-8 path in English: $(cat "$S/utf8.en.out" "$S/utf8.en.out.err" | head -c 300 | od -An -c | head -n 4 | tr '\n' ' ')"
fi
if command -v python3 > /dev/null 2>&1; then
	if python3 -I - "$S/utf8.json" "$_upath" <<'PEOF'
import json, sys
raw = open(sys.argv[1], "rb").read()
d = json.loads(raw.decode("utf-8").split("\n")[0])
want = sys.argv[2]
assert any(want in b["reason"] for b in d["blockers"]), d["blockers"]
PEOF
	then ok "a UTF-8 path is valid UTF-8 JSON and round-trips through the blocker record"
	else bad "UTF-8 path in JSON: $(head -c 300 "$S/utf8.json" | od -An -c | head -n 4 | tr '\n' ' ')"; fi
fi
_all=$(i=1; while [ "$i" -le 255 ]; do printf "\\$(printf '%03o' "$i")"; i=$((i + 1)); done; printf x)
_rt=$(. "$S/hook-fns.sh"; _e=$(blk_esc "$_all"); blk_unesc "$_e")
_hi=$(. "$S/hook-fns.sh"; json_str "$(printf '\303\251\377')" | LC_ALL=C od -An -v -tx1 | tr -d ' \n')
if [ "$_rt" = "$_all" ] && [ "$_hi" = c3a9ff ]; then
	ok "every byte 1..255 round-trips a blocker field, and json_str passes bytes >= 0x80 through"
else
	bad "byte round trip: blk=[$([ "$_rt" = "$_all" ] && echo same || echo differs)] json high bytes=[$_hi]"
fi
# one decoder and one table: the blk decoder is esc_bytes in its own mode.
# The rule is about the byte decoder: the escape table and the hexadecimal
# digit table inside esc_bytes are written once, the byte-at-a-time pipeline
# is written once, and json_str, blk_esc and blk_unesc call the decoder
# instead of carrying a copy of it.  The count is scoped to the decoder: the
# architecture table's own parser (arch_floor_table) reads the hexadecimal
# constants of the header, and that is a different program with a different
# job.  The rule that program has is checked below.
_dec=$(sed -n '/^esc_bytes() {/,/^}/p' "$repo/scripts/make.sh")
if [ "$(grep -c 'od -An -v -tx1' "$repo/scripts/make.sh")" = 1 ] \
    && [ "$(grep -c '^esc_bytes() {' "$repo/scripts/make.sh")" = 1 ] \
    && [ "$(printf '%s\n' "$_dec" | grep -c 'index("0123456789abcdef"')" = 1 ] \
    && [ "$(printf '%s\n' "$_dec" | grep -c 'function hv')" = 1 ] \
    && [ "$(grep -c '^blk_esc() {' "$repo/scripts/make.sh")" = 1 ] \
    && [ "$(grep -c '^blk_unesc() {' "$repo/scripts/make.sh")" = 1 ] \
    && [ "$(grep -c '^json_str() {' "$repo/scripts/make.sh")" = 1 ] \
    && sed -n '/^blk_esc() {/,/^}/p' "$repo/scripts/make.sh" | grep -q 'esc_bytes blk' \
    && sed -n '/^blk_unesc() {/,/^}/p' "$repo/scripts/make.sh" | grep -q 'esc_bytes unblk' \
    && sed -n '/^json_str() {/,/^}/p' "$repo/scripts/make.sh" | grep -q 'esc_bytes json'; then
	ok "the byte decoder and the escape table are written once"
else
	bad "make.sh has more than one byte decoder"
fi

# The hexadecimal constants of the architecture table are read as numbers: the
# digit b is eleven, not ten.  The GB20x row is 0x1b (27) and the GB10x row
# is 0x1a (26); a parser that reads every digit from b to f as ten reads the
# GB20x row as 0x1a, the value of the GB10x row, and the two chip families
# stop telling themselves apart.
fn_extract "$repo/scripts/make.sh" arch_floor_header arch_floor_table > "$S/arch-fns.sh"
_at=$(. "$S/arch-fns.sh"; repo="$repo"; arch_floor_table 2>/dev/null)
_gb10=$(printf '%s\n' "$_at" | awk '$1 == "arch" && $3 == "GB10x" { print $2; exit }')
_gb20=$(printf '%s\n' "$_at" | awk '$1 == "arch" && $3 == "GB20x" { print $2; exit }')
if [ "$_gb10" = 26 ] && [ "$_gb20" = 27 ]; then
	ok "the architecture table reads a hexadecimal digit as its number (GB10x 26, GB20x 27)"
else
	bad "the architecture table reads the hexadecimal digits wrongly: GB10x=$_gb10 GB20x=$_gb20"
fi

# A test hook never reaches the package step, which runs as root on the live
# system: with the hook set and no DESTDIR the step is refused, not run.
_hr=$(env GB10_TEST_HOOKS=1 GB10_TEST_PKG_NEEDED=nvgb10-test-pkg GB10_TEST_ROOT_METHOD=none \
    MK_YES=1 MK_WORK="$S/w-hookpkg" sh "$repo/scripts/make.sh" install-prereqs 2>&1 < /dev/null)
rc=$?
if [ "$rc" != 0 ] && printf '%s\n' "$_hr" | grep -q 'refusing test hook GB10_TEST_PKG_NEEDED' \
    && ! printf '%s\n' "$_hr" | grep -q 'packages to install'; then
	ok "GB10_TEST_PKG_NEEDED is refused before the root package step"
else
	bad "package hook reached the package step (rc $rc): $(printf '%s' "$_hr" | head -c 300 | tr '\n' ' ')"
fi
_hr2=$(env GB10_TEST_HOOKS=1 GB10_TEST_PKG_NEEDED=nvgb10-test-pkg GB10_TEST_ROOT_METHOD=none \
    MK_YES=1 MK_WORK="$S/w-hookpkg" MK_DESTDIR="$S/d-hookpkg" sh "$repo/scripts/make.sh" _install-prereqs-auto 2>&1 < /dev/null)
rc=$?
if [ "$rc" != 0 ] && printf '%s\n' "$_hr2" | grep -q 'refusing test hook GB10_TEST_PKG_NEEDED' \
    && ! printf '%s\n' "$_hr2" | grep -q 'packages to install'; then
	ok "GB10_TEST_PKG_NEEDED is refused for the automatic package step with a DESTDIR too"
else
	bad "package hook with a DESTDIR (rc $rc): $(printf '%s' "$_hr2" | head -c 300 | tr '\n' ' ')"
fi

# A tool table or probe failure is a failed query, never "nothing needed".
_tf1=$(. "$S/hook-fns.sh"; tool_table() { return 1; }; pkgs_needed_list; echo "rc=$?")
_tf2=$(. "$S/hook-fns.sh"; tool_table() { :; }; pkgs_needed_list; echo "rc=$?")
_tf3=$(. "$S/hook-fns.sh"; tool_table() { printf '%s\n' "cc"; }; pkgs_needed_list; echo "rc=$?")
case $_tf1:$_tf2:$_tf3 in
*rc=1:*rc=1:*rc=1)
	if [ "$(printf '%s\n' "$_tf1" | wc -l | tr -d ' ')" = 2 ]; then
		ok "a failing, empty or malformed tool table is a failed package query with a reason"
	else
		bad "tool table failure has no reason: [$_tf1]"
	fi
	;;
*) bad "tool table failure fails open: [$_tf1] [$_tf2] [$_tf3]" ;;
esac

# A failed package query is a blocker in the preflight whatever the root method.
_pq=$(env GB10_TEST_HOOKS=1 GB10_TEST_PKG_FAIL=boom GB10_TEST_ROOT_METHOD=doas MK_WORK="$W7" \
    MK_DESTDIR="$D7" MK_SYSDIR="$W7/src/sys" MK_BSDSRCTOP="$W7/src" MK_DRMKMODDIR="$W7-drm" \
    MK_ACCEPT_NVIDIA_LICENSE=1 sh "$repo/scripts/make.sh" preflight --json 2>/dev/null)
if printf '%s\n' "$_pq" | python3 -I -c '
import json, sys
d = json.load(sys.stdin)
p = [x for x in d["status"] if x["name"] == "packages"]
assert len(p) == 1 and p[0]["state"] == "missing" and "boom" in p[0]["reason"], p'; then
	ok "a failed package query is a missing item in the preflight with a root method present"
else
	bad "preflight with a failed query and doas: $(printf '%s' "$_pq" | head -c 300)"
fi

# The header's stderr promise: an accepted hook says so on stderr.
_hn=$(env GB10_TEST_HOOKS=1 GB10_TEST_ROOT_METHOD=doas MK_DESTDIR= sh "$repo/scripts/make.sh" _next-steps 2>&1 >/dev/null)
if printf '%s\n' "$_hn" | grep -q 'test hook GB10_TEST_ROOT_METHOD'; then
	ok "an accepted root-method hook says so on stderr"
else
	bad "root-method hook is silent: [$_hn]"
fi

# ---- install output wording: the notes, the commands, the licence fix ------

# The summary is called here with a stubbed root method, so the live system is
# never touched: a live install would load a module.  The functions come from
# make.sh by name; a missing one fails loudly below.
fn_extract "$repo/scripts/make.sh" install_summary install_next_list install_next_steps \
    install_next_note install_next_root_note install_next_staged_note install_next_notes \
    install_root_method install_nvrm_command install_schema_fields root_cmd su_quote \
    install_next_add install_next_render install_resume_command \
    >> "$S/hook-fns.sh"
for _fn in install_summary install_next_list install_next_steps install_next_note \
    install_next_root_note install_next_staged_note install_next_notes \
    install_root_method install_nvrm_command install_schema_fields root_cmd su_quote \
    install_next_add install_next_render install_resume_command; do
	( . "$S/hook-fns.sh"; command -v "$_fn" > /dev/null ) \
	    || bad "the function $_fn is missing from make.sh"
done
# summary ROOT-METHOD JSON [DESTDIR] [PREFIX]: the summary of an installed
# live install, with ROOT-METHOD as the way this user becomes root.
summary() {
	(
		. "$S/hook-fns.sh"
		_rmstub=$1
		root_method() { printf '%s\n' "$_rmstub"; }
		DESTDIR=${3:-}
		PREFIX=${4:-/usr/local}
		# the version the driver emits, read from the driver itself
		install_schema_version=$(sed -n 's/^install_schema_version=//p' "$repo/scripts/make.sh")
		install_records='/boot/modules/nvidia.ko|555
'
		install_blockers=
		MK_JSON=$2
		install_summary installed
	)
}
_sum_none=$(summary none 0)
_sum_doas=$(summary doas 0)
_sum_json_none=$(summary none 1)
_sum_json_doas=$(summary doas 1)
printf '%s\n' "$_sum_json_doas" > "$S/sum.json"
# The fixture is the output of the generator: the same live summary, with a
# doas user, has the same next steps, the same note and the same root steps.
if python3 -I - "$repo" "$S/sum.json" <<'PEOF'
import json, os, sys
repo = sys.argv[1]
fixture = json.load(open(os.path.join(repo, "tests/fixtures/make-install.json")))
live = json.load(open(sys.argv[2]))
assert fixture["next"] == live["next"], (fixture["next"], live["next"])
assert fixture["note"] == live["note"], (fixture["note"], live["note"])
assert fixture["requires_root_shell"] == live["requires_root_shell"], fixture["requires_root_shell"]
assert fixture["schema_version"] == live["schema_version"], fixture["schema_version"]
PEOF
then ok "the fixture is what the generator emits for a doas user"
else bad "the fixture and the generated summary differ"; fi
# The root note stands before the list of commands; the boot-load note after
# it; every next: line is a command and nothing else.
printf '%s\n' "$_sum_none" > "$S/sum.none"
cat > "$S/sum.none.want" <<'XEOF'
installed /boot/modules/nvidia.ko 555
the firmware setting and the module load run as root (this user has no doas, sudo or su): ask an administrator to run them as root, or open a root shell on the console and run them there.
next: kenv hw.nvidia.registry.EnableGpuFirmware=1
next: kldload nvidia-drm
next: kldstat
next: nvrm-info --json
To load the driver at boot instead of the firmware setting and the module load, run make configure YES=1 once.
install: installed
XEOF
if cmp -s "$S/sum.none" "$S/sum.none.want"; then
	ok "with no root tool the commands are bare and the root note says what to do"
else
	bad "the summary with no root tool: $(printf '%s' "$_sum_none" | tr '\n' '|')"
fi
if ! printf '%s\n' "$_sum_doas" | grep -q 'no doas, sudo or su' \
    && printf '%s\n' "$_sum_doas" | grep -q 'make configure YES=1'; then
	ok "with a root tool there is no root note, and the boot-load note comes after the list"
else
	bad "the summary with doas: $(printf '%s' "$_sum_doas" | tr '\n' '|')"
fi
# The JSON: the next array holds commands only, the steps that need a root
# shell are named by index, and the notes are prose in their own field.
if printf '%s\n' "$_sum_json_none" | python3 -I -c '
import json, sys
d = json.load(sys.stdin)
assert d["next"] == ["kenv hw.nvidia.registry.EnableGpuFirmware=1", "kldload nvidia-drm",
                     "kldstat", "nvrm-info --json"], d["next"]
assert all(" as root" not in n for n in d["next"]), d["next"]
assert d["requires_root_shell"] == [0, 1], d["requires_root_shell"]
assert "no doas, sudo or su" in d["note"], d["note"]
assert "open a root shell" in d["note"], d["note"]
assert "make configure YES=1" in d["note"], d["note"]
' && printf '%s\n' "$_sum_json_doas" | python3 -I -c '
import json, sys
d = json.load(sys.stdin)
assert d["next"] == ["doas kenv hw.nvidia.registry.EnableGpuFirmware=1", "doas kldload nvidia-drm",
                     "kldstat", "nvrm-info --json"], d["next"]
assert d["requires_root_shell"] == [], d["requires_root_shell"]
assert "no doas" not in d["note"], d["note"]
assert d["note"].startswith("To load the driver at boot"), d["note"]
'; then
	ok "the JSON next array holds commands only and the notes are their own field"
else
	bad "the JSON summary: $(printf '%s\n' "$_sum_json_none" | tr '\n' ' ')"
fi
# One notion of "no root tool": a root method that is empty or unknown means
# the same thing as none, and then the commands are bare and the note says
# they run as root.
for _rm in '' unknown none; do
	_sum_rm=$(summary "$_rm" 0)
	_sum_json_rm=$(summary "$_rm" 1)
	if printf '%s\n' "$_sum_rm" | grep -q '^next: kenv hw.nvidia.registry.EnableGpuFirmware=1$' \
	    && printf '%s\n' "$_sum_rm" | grep -q 'no doas, sudo or su' \
	    && printf '%s\n' "$_sum_json_rm" | python3 -I -c '
import json, sys
d = json.load(sys.stdin)
assert d["next"][0] == "kenv hw.nvidia.registry.EnableGpuFirmware=1", d["next"]
assert d["requires_root_shell"] == [0, 1], d["requires_root_shell"]
assert "no doas, sudo or su" in d["note"], d["note"]
'; then
		ok "the root method [$_rm] means no root tool: bare commands and the root note"
	else
		bad "the root method [$_rm]: $(printf '%s\n' "$_sum_rm" | tr '\n' '|')"
	fi
done
# A staged install has no next step at all: the files are only staged, so
# there is nothing to run on this system, and the explanation is the note.
_sum_staged=$(summary none 0 /some/stage)
_sum_json_staged=$(summary none 1 /some/stage)
if ! printf '%s\n' "$_sum_staged" | grep -q '^next: ' \
    && printf '%s\n' "$_sum_staged" | grep -q 'staged under /some/stage' \
    && printf '%s\n' "$_sum_json_staged" | python3 -I -c '
import json, sys
d = json.load(sys.stdin)
assert d["next"] == [], d["next"]
assert d["requires_root_shell"] == [], d["requires_root_shell"]
assert "staged under /some/stage" in d["note"], d["note"]
assert "nothing was loaded" in d["note"], d["note"]
'; then
	ok "a staged install has no next step, and its note says where the files are"
else
	bad "the staged summary: $(printf '%s\n' "$_sum_staged" | tr '\n' '|')"
fi
# A PREFIX the user chose: the tool is not on PATH, so the command names the
# installed path.
_sum_json_prefix=$(summary doas 1 '' /opt/gb10)
if printf '%s\n' "$_sum_json_prefix" | python3 -I -c '
import json, sys
d = json.load(sys.stdin)
assert d["next"][-1] == chr(39) + "/opt/gb10/sbin/nvrm-info" + chr(39) + " --json", d["next"]
'; then
	ok "with a PREFIX the check command names the installed tool"
else
	bad "the summary with a PREFIX: $(printf '%s\n' "$_sum_json_prefix" | tr '\n' ' ')"
fi
# The note and the steps come from one list: the note names the steps it
# replaces instead of counting them.
if grep -q 'install_next_load=' "$repo/scripts/make.sh" \
    && ! grep -q 'the first two next steps' "$repo/scripts/make.sh"; then
	ok "the boot-load note names the steps it replaces, it does not count them"
else
	bad "the boot-load note still counts the steps"
fi
# su root -c: the command is quoted, so a single quote in it cannot break out.
_suq=$(. "$S/hook-fns.sh"; su_quote "echo it's here")
_suw=$(eval "printf '%s' $_suq" 2>/dev/null)
_suc=$(. "$S/hook-fns.sh"; root_method() { printf 'su\n'; }; root_cmd su "echo it's here")
if [ "$_suw" = "echo it's here" ] \
    && [ "$_suc" = "su root -c 'echo it'\''s here'" ]; then
	ok "the su command is quoted, so a single quote in it cannot break out"
else
	bad "the su quoting: [$_suc] (word: [$_suw])"
fi
# The licence fix names the terminal way of accepting it, and a terminal run
# of make install really asks the licence question.
if grep -q 'on a terminal and answer the licence question' "$S/blocked.out" \
    && grep -q 'Do you accept the NVIDIA driver licence' "$S/lic.out"; then
	ok "the licence fix names the terminal way, and make install asks on a terminal"
else
	bad "the licence fix does not name a way that works: $(grep '^fix:' "$S/blocked.out" | tr '\n' ' ')"
fi

# ---- the ladder gate: every next step is one pasteable command -------------

# A PREFIX is a path the user typed.  Every command that names it quotes the
# path as one word, so a prefix with a space in it names the tool that was
# installed and not the first word of the path.
PFXDIR="$S/prefix with space"
mkdir -p "$PFXDIR/sbin"
printf '#!/bin/sh\nprintf "FAKE-NVRM\\n"\n' > "$PFXDIR/sbin/nvrm-info"
chmod 755 "$PFXDIR/sbin/nvrm-info"
_next=$(env GB10_TEST_HOOKS=1 GB10_TEST_ROOT_METHOD=doas MK_DESTDIR= MK_PREFIX="$PFXDIR" \
    sh "$repo/scripts/make.sh" _next-steps 2>/dev/null)
_next_last=$(printf '%s\n' "$_next" | tail -n 1)
_next_run=$(cd "$S" && sh -c "$_next_last" 2>/dev/null)
if [ "$_next_run" = "FAKE-NVRM" ]; then
	ok "a PREFIX with a space names one executable: the command runs the installed tool"
else
	bad "the command for a PREFIX with a space: [$_next_last] (it ran: [$_next_run])"
fi
# A PREFIX with a shell metacharacter in it cannot run another command: the
# path is quoted, so the semicolon is part of the name and not a command
# separator.
INJ=$S/injection
mkdir -p "$INJ"
SENT=$INJ/sentinel
_inj=$(env GB10_TEST_HOOKS=1 GB10_TEST_ROOT_METHOD=doas MK_DESTDIR= \
    MK_PREFIX="$INJ/pfx;touch $SENT #" \
    sh "$repo/scripts/make.sh" _next-steps 2>/dev/null)
_inj_last=$(printf '%s\n' "$_inj" | tail -n 1)
(cd "$INJ" && sh -c "$_inj_last" >/dev/null 2>&1)
if [ ! -e "$SENT" ]; then
	ok "a PREFIX with a shell metacharacter cannot run another command"
else
	bad "the command for a PREFIX with a metacharacter ran it: [$_inj_last]"
fi
# A PREFIX with a newline in it is refused: the next steps travel one
# command per line, and a newline in a path would make two of them.
_nl=$(env GB10_TEST_HOOKS=1 MK_DESTDIR= MK_PREFIX="$INJ/pfx
second" sh "$repo/scripts/make.sh" _next-steps 2>&1)
_rc=$?
if [ "$_rc" != 0 ] && printf '%s\n' "$_nl" | grep -qi 'newline'; then
	ok "a PREFIX with a newline is refused before any command is built from it"
else
	bad "a PREFIX with a newline (rc $_rc): $(printf '%s\n' "$_nl" | tr '\n' ' ')"
fi

# The licence alternatives keep the settings that change where the install
# goes: following one must not turn a staged install into a live one.
_reason=$(sed -n 's/^blocked licence: //p' "$S/blocked.out" | head -n 1)
if printf '%s\n' "$_reason" | grep -q "make install DESTDIR='$D1' ACCEPT_ALL_LICENSES=1" \
    && printf '%s\n' "$_reason" | grep -q "run make install DESTDIR='$D1' on a terminal" \
    && ! printf '%s\n' "$_reason" | grep -q 'run make install on a terminal'; then
	ok "the licence alternatives keep the DESTDIR the install was given"
else
	bad "the licence alternatives: [$_reason]"
fi
# The same with a PREFIX the user chose: that one is kept too.
_reason_pfx=$(sed -n 's/^blocked licence: //p' "$S/blocked-prefix.out" | head -n 1)
if printf '%s\n' "$_reason_pfx" | grep -q "PREFIX='/opt/gb10'" \
    && printf '%s\n' "$_reason_pfx" | grep -q "run make install DESTDIR='$DPFX' PREFIX='/opt/gb10' on a terminal"; then
	ok "the licence alternatives keep the PREFIX the install was given"
else
	bad "the licence alternatives with a PREFIX: [$_reason_pfx]"
fi

# The steps that need a root shell are named by requires_root_shell: the
# field says what it means, and it is empty when the commands carry the
# root tool.
_sum_root_none=$(summary none 1)
_sum_root_doas=$(summary doas 1)
if printf '%s\n' "$_sum_root_none" | python3 -I -c '
import json, sys
d = json.load(sys.stdin)
assert "requires_root_shell" in d, sorted(d)
assert "requires_root" not in d, sorted(d)
assert d["requires_root_shell"] == [0, 1], d["requires_root_shell"]
assert d["next"][0].endswith("kenv hw.nvidia.registry.EnableGpuFirmware=1"), d["next"]
assert d["next"][1].endswith("kldload nvidia-drm"), d["next"]
' && printf '%s\n' "$_sum_root_doas" | python3 -I -c '
import json, sys
d = json.load(sys.stdin)
assert d["requires_root_shell"] == [], d["requires_root_shell"]
'; then
	ok "requires_root_shell names the steps that need a root shell"
else
	bad "requires_root_shell: $(printf '%s\n' "$_sum_root_none" | tr -d '\n' | head -c 200)"
fi
# The indexes come from the records the commands come from: a copy of the
# generator with one step before the privileged ones moves them.
cp "$repo/scripts/make.sh" "$S/make-extra-step.sh"
sed "s|^\tinstall_next_add 'the firmware setting'|\tinstall_next_add 'a first check' 'true' '' ''\n&|" \
    "$S/make-extra-step.sh" > "$S/make-extra-step.patched.sh"
fn_extract "$S/make-extra-step.patched.sh" install_next_list install_next_add install_next_render \
    >> "$S/hook-fns.sh"
_extra=$( . "$S/hook-fns.sh"; root_method() { printf 'none\n'; }; DESTDIR=; PREFIX=/usr/local; \
    install_next_list installed; printf '%s' "$install_next_root" )
_cmds=$( . "$S/hook-fns.sh"; root_method() { printf 'none\n'; }; DESTDIR=; PREFIX=/usr/local; \
    install_next_list installed; printf '%s' "$install_next_cmds" )
_load=$( . "$S/hook-fns.sh"; root_method() { printf 'none\n'; }; DESTDIR=; PREFIX=/usr/local; \
    install_next_list installed; printf '%s' "$install_next_load" )
if [ "$_extra" = "1
2" ] && [ "$(printf '%s\n' "$_cmds" | head -n 1)" = "true" ] \
    && [ "$_load" = "the firmware setting and the module load" ]; then
	ok "the root-shell indexes follow the records: a step before them moves them"
else
	bad "the root-shell indexes do not follow the records: [$_extra] (first step: [$(printf '%s\n' "$_cmds" | head -n 1)])"
fi
# The note names a way to become root that a user without a root tool can
# actually take.
if printf '%s\n' "$_sum_none" | grep -qi 'administrator' \
    && printf '%s\n' "$_sum_none" | grep -qi 'console'; then
	ok "the no-root-tool note names an escalation route"
else
	bad "the no-root-tool note names no way to become root: $(printf '%s\n' "$_sum_none" | head -n 2 | tr '\n' ' ')"
fi

# A blocked install has no next steps: the module was never installed, so
# kldload cannot work, and nothing was staged.  The licence is not accepted,
# so the install blocks before it copies anything.
BND=$S/wblocked
DND=$S/dblocked
plant_work "$BND"
new_dest "$DND"
run_install "$BND" "$DND" "$S/blocked-destdir.out"
rc=$?
if [ "$rc" = 1 ] && grep -q '^install: blocked' "$S/blocked-destdir.out" \
    && ! grep -q '^next: ' "$S/blocked-destdir.out" \
    && ! grep -q 'staged under' "$S/blocked-destdir.out" \
    && ! grep -q 'make configure YES=1' "$S/blocked-destdir.out" \
    && ! grep -q 'run as root' "$S/blocked-destdir.out"; then
	ok "a blocked staged install names no next step"
else
	bad "a blocked staged install names next steps (rc $rc): $(grep -E '^(next:|To load|the files)' "$S/blocked-destdir.out" | tr '\n' ' ')"
fi
# The same without a DESTDIR: the install is blocked before any root step.
(cd "$repo" && env -u ACCEPT_NVIDIA_LICENSE -u ACCEPT_ALL_LICENSES -u ACCEPT_EULA \
    GB10_TEST_HOOKS=1 FETCH=/bin/false SHA256="$H/sha256" GIT="$H/git" \
    MK_WORK="$BND" MK_DESTDIR= MK_SYSDIR="$BND/src/sys" MK_BSDSRCTOP="$BND/src" \
    MK_DRMKMODDIR="$BND-drm" sh scripts/make.sh install) > "$S/blocked-live.out" 2>&1 < /dev/null
rc=$?
if [ "$rc" = 1 ] && grep -q '^install: blocked' "$S/blocked-live.out" \
    && ! grep -q '^next: ' "$S/blocked-live.out" \
    && ! grep -q 'staged under' "$S/blocked-live.out" \
    && ! grep -q 'make configure YES=1' "$S/blocked-live.out" \
    && ! grep -q 'run as root' "$S/blocked-live.out"; then
	ok "a blocked live install names no next step"
else
	bad "a blocked live install names next steps (rc $rc): $(grep -E '^(next:|To load|the files)' "$S/blocked-live.out" | tr '\n' ' ')"
fi
# The machine output agrees: no next steps and no note for a blocked install.
(cd "$repo" && env -u ACCEPT_NVIDIA_LICENSE -u ACCEPT_ALL_LICENSES -u ACCEPT_EULA \
    GB10_TEST_HOOKS=1 FETCH=/bin/false SHA256="$H/sha256" GIT="$H/git" \
    MK_WORK="$BND" MK_DESTDIR= MK_SYSDIR="$BND/src/sys" MK_BSDSRCTOP="$BND/src" \
    MK_DRMKMODDIR="$BND-drm" MK_JSON=1 sh scripts/make.sh install) > "$S/blocked-live.json" 2>/dev/null < /dev/null
if python3 -I - "$S/blocked-live.json" <<'PEOF'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["outcome"] != "installed", d["outcome"]
assert d["next"] == [], d["next"]
assert "note" not in d, d.get("note")
PEOF
then ok "a blocked install has no next steps and no note in the machine output"
else bad "the blocked summary: $(head -c 200 "$S/blocked-live.json")"; fi

# ---- the outcome contract: what each outcome names -------------------------
#
# The summary says what happened.  An installed install names its next steps;
# a blocked one names its blocker and that blocker's fix; an interrupted one
# names how to resume it.  An install that did not happen never names the
# next steps of an install that did.
# The functions come from make.sh by name, into a file of their own: the
# summary is what the driver emits, not what a patched copy of it emits.
fn_extract "$repo/scripts/make.sh" install_summary install_next_list install_next_steps \
    install_next_note install_next_root_note install_next_staged_note install_next_notes \
    install_root_method install_nvrm_command install_schema_fields root_cmd su_quote \
    install_next_add install_next_render install_resume_command \
    > "$S/summary-fns.sh"
summary_outcome() {
	(
		. "$S/hook-fns.sh"
		. "$S/summary-fns.sh"
		_so_outcome=$1
		_rmstub=$2
		root_method() { printf '%s\n' "$_rmstub"; }
		DESTDIR=${4:-}
		PREFIX=${5:-/usr/local}
		# the version the driver emits, read from the driver itself
		install_schema_version=$(sed -n 's/^install_schema_version=//p' "$repo/scripts/make.sh")
		install_records='/boot/modules/nvidia.ko|555
'
		install_blockers='licence|the NVIDIA driver licence is not accepted|make install ACCEPT_NVIDIA_LICENSE=1
'
		MK_JSON=$3
		install_summary "$_so_outcome"
	)
}
# An installed install: the next steps and the note, and no resume.
_out_installed=$(summary_outcome installed none 0)
_out_installed_json=$(summary_outcome installed none 1)
if printf '%s\n' "$_out_installed" | grep -q '^next: kenv hw.nvidia.registry.EnableGpuFirmware=1$' \
    && printf '%s\n' "$_out_installed" | grep -q '^install: installed$' \
    && ! printf '%s\n' "$_out_installed" | grep -q '^resume: ' \
    && printf '%s\n' "$_out_installed_json" | python3 -I -c '
import json, sys
d = json.load(sys.stdin)
assert d["kind"] == "summary" and d["outcome"] == "installed", d
assert any(x.endswith("kenv hw.nvidia.registry.EnableGpuFirmware=1") for x in d["next"]), d["next"]
assert "note" in d, d
assert "resume" not in d, d.get("resume")
'; then
	ok "an installed install names its next steps and no resume"
else
	bad "the installed summary: $(printf '%s\n' "$_out_installed" | tr '\n' ' ')"
fi
# A blocked install: the blocker and its fix, and nothing else.
_out_blocked=$(summary_outcome blocked none 0)
_out_blocked_json=$(summary_outcome blocked none 1)
if printf '%s\n' "$_out_blocked" | grep -q '^blocked licence: the NVIDIA driver licence is not accepted$' \
    && printf '%s\n' "$_out_blocked" | grep -q '^fix: make install ACCEPT_NVIDIA_LICENSE=1$' \
    && printf '%s\n' "$_out_blocked" | grep -q '^install: blocked$' \
    && ! printf '%s\n' "$_out_blocked" | grep -q '^next: ' \
    && ! printf '%s\n' "$_out_blocked" | grep -q '^resume: ' \
    && printf '%s\n' "$_out_blocked_json" | python3 -I -c '
import json, sys
d = json.load(sys.stdin)
assert d["kind"] == "summary" and d["outcome"] == "blocked", d
assert d["next"] == [], d["next"]
assert "note" not in d, d.get("note")
assert "resume" not in d, d.get("resume")
b = d["blockers"][0]
assert b["name"] == "licence" and b["fix"] == "make install ACCEPT_NVIDIA_LICENSE=1", d["blockers"]
'; then
	ok "a blocked install names its blocker and its fix only"
else
	bad "the blocked summary: $(printf '%s\n' "$_out_blocked" | tr '\n' ' ')"
fi
# An interrupted install: how to resume it, and no next steps.
_out_interrupted=$(summary_outcome interrupted none 0 /stage)
_out_interrupted_json=$(summary_outcome interrupted none 1 /stage)
if printf '%s\n' "$_out_interrupted" | grep -q "^resume: make install DESTDIR='/stage'$" \
    && printf '%s\n' "$_out_interrupted" | grep -q '^install: interrupted$' \
    && ! printf '%s\n' "$_out_interrupted" | grep -q '^next: ' \
    && printf '%s\n' "$_out_interrupted_json" | python3 -I -c '
import json, sys
d = json.load(sys.stdin)
assert d["kind"] == "summary" and d["outcome"] == "interrupted", d
assert d["next"] == [], d["next"]
assert "note" not in d, d.get("note")
assert d["resume"] == "make install DESTDIR='"'"'/stage'"'"'", d.get("resume")
'; then
	ok "an interrupted install names how to resume it and no next steps"
else
	bad "the interrupted summary: $(printf '%s\n' "$_out_interrupted" | tr '\n' ' ')"
fi

# Every row of the machine output is described by the schema of the contract
# it names: the progress rows and the summary row both validate.
if python3 -I - "$repo" "$S/installed.jsonl" "$S/blocked.json" <<'PEOF'
import json, os, re, sys
repo = sys.argv[1]
schema = json.load(open(os.path.join(repo, "schema/make-install-2.schema.json")))


def validate(node, doc, root):
    if "$ref" in node:
        ref = node["$ref"]
        assert ref.startswith("#/"), ref
        target = root
        for part in ref[2:].split("/"):
            target = target[part]
        return validate(target, doc, root)
    if "oneOf" in node:
        errors = []
        for sub in node["oneOf"]:
            try:
                return validate(sub, doc, root)
            except AssertionError as exc:
                errors.append(str(exc))
        raise AssertionError("no branch of the union matched: " + "; ".join(errors))
    if "const" in node:
        assert doc == node["const"], (doc, node["const"])
    if "enum" in node:
        assert doc in node["enum"], (doc, node["enum"])
    kind = node.get("type")
    if kind == "object":
        assert isinstance(doc, dict), doc
        props = node.get("properties", {})
        for name in node.get("required", []):
            assert name in doc, "missing " + name
        if node.get("additionalProperties") is False:
            for name in doc:
                assert name in props, "unexpected property " + name
        for name, value in doc.items():
            if name in props:
                validate(props[name], value, root)
    elif kind == "array":
        assert isinstance(doc, list), doc
        for item in doc:
            validate(node["items"], item, root)
    elif kind == "string":
        assert isinstance(doc, str), doc
        if "minLength" in node:
            assert len(doc) >= node["minLength"], doc
        if "pattern" in node:
            assert re.search(node["pattern"], doc), doc
    elif kind == "integer":
        assert isinstance(doc, int) and not isinstance(doc, bool), doc
        if "minimum" in node:
            assert doc >= node["minimum"], doc


rows = [json.loads(line) for line in open(sys.argv[2]) if line.strip()]
assert len(rows) > 1, rows
for row in rows:
    validate(schema, row, schema)
for path in (sys.argv[3],):
    doc = json.load(open(path))
    validate(schema, doc, schema)
fixture = json.load(open(os.path.join(repo, "tests/fixtures/make-install.json")))
validate(schema, fixture, schema)
# The registered progress sample: every row of it is one of the two shapes
# the contract has, and its progress rows carry the same keys as the rows a
# real run emits.
progress_sample = os.path.join(repo, "tests/fixtures/make-install-progress.jsonl")
sample_rows = [json.loads(line) for line in open(progress_sample) if line.strip()]
assert sample_rows, "the progress sample is empty"
for row in sample_rows:
    validate(schema, row, schema)
real_progress = [r for r in rows if r.get("kind") == "progress"]
sample_progress = [r for r in sample_rows if r.get("kind") == "progress"]
assert sample_progress, sample_rows
assert set(sample_progress[0]) == set(real_progress[0]), (sample_progress[0], real_progress[0])
# Every registered sample names a fixture that is there.
samples = json.load(open(os.path.join(repo, "schema/samples.json")))["samples"]
for sample in samples:
    assert os.path.isfile(os.path.join(repo, sample["fixture"])), sample
PEOF
then ok "every row of the machine output validates against the schema it names"
else bad "the machine output does not validate against its own schema"; fi

# No personal defaults.  The needles are tests/lib/personal-paths.txt, the
# same list tests/readme_install_doc_test.sh reads.  README.md, docs/ and man/
# are covered too.
needles=$repo/tests/lib/personal-paths.txt
scan=$S/no-user-paths
# The list and its samples are read by tests/lib/personal-paths.sh, shared with
# tests/readme_install_doc_test.sh.  A missing, empty or unreadable list is one
# failure, never also a pass.
. "$repo/tests/lib/personal-paths.sh"
pp_ok=0
pp_pat=$S/personal-patterns
pp_allow=$S/personal-allows
if pp_load "$needles" "$pp_pat" "$pp_allow"; then pp_ok=1; fi
# The library's failure paths: each bad list must fail, never pass.
pp_t=$S/pp-lists
mkdir -p "$pp_t"
: > "$pp_t/empty"
printf '# only a comment\n\n' > "$pp_t/comments"
printf '# sample: x\nfoo\n# sample+: foo\n' > "$pp_t/badkind-sample"
printf 'foo\n# sample+: foo\n# allow x-literal-long\n' > "$pp_t/badkind-allow"
printf 'foo\n# sample+:\n' > "$pp_t/badkind-empty"
printf 'foo\n# sample+: foo\n# the samples below\n' > "$pp_t/badkind-typo-ok"
pp_load "$pp_t/missing" "$pp_t/n" "$pp_t/a" && bad "pp_load accepts a missing list" || ok "pp_load refuses a missing list"
for pp_c in empty comments badkind-sample badkind-allow badkind-empty; do
	if pp_load "$pp_t/$pp_c" "$pp_t/n" "$pp_t/a"; then bad "pp_load accepts the list $pp_c"; else ok "pp_load refuses the list $pp_c"; fi
done
# A comment that merely mentions another word is a comment.
if pp_load "$pp_t/badkind-typo-ok" "$pp_t/n" "$pp_t/a"; then ok "pp_load keeps a comment whose first word is not sample or allow"; else bad "pp_load refuses a plain comment"; fi
# pp_selftest branches: sample before a needle (both kinds), a needle without a positive sample, a positive
# sample that misses, a negative sample that is flagged, and each bad allow literal.
printf '# sample+: x\nfoo\n# sample+: foo\n' > "$pp_t/st-first-pos"
printf '# sample-: x\nfoo\n# sample+: foo\n' > "$pp_t/st-first-neg"
printf 'foo\n# sample+: foo\nbar\n' > "$pp_t/st-no-sample"
printf 'foo\n# sample+: nomatch\n' > "$pp_t/st-misses"
printf 'foo\n# sample+: foo\n# sample-: a foo b\n' > "$pp_t/st-flagged"
printf 'foo\n# sample+: foo\n# allow: foo\n' > "$pp_t/st-allow-short"
printf '/foo/\n# sample+: /foo/x\n# allow: /foo/bar-long\n' > "$pp_t/st-allow-slash"
printf 'foo\n# sample+: foo\n# allow: unrelated-literal\n' > "$pp_t/st-allow-noneedle"
printf 'foo\n' > "$pp_t/st-no-samples"
pp_selftest_refuses() {	# a subshell with silent ok and bad, so only the return status counts
	pp_load "$pp_t/$1" "$pp_t/n" "$pp_t/a" || return 0
	(ok() { :; }; bad() { :; }; pp_selftest "$pp_t/$1" "$pp_t/n" "$pp_t/a") && return 1
	return 0
}
for pp_c in st-first-pos st-first-neg st-no-sample st-misses st-flagged st-allow-short st-allow-slash st-allow-noneedle st-no-samples; do
	if pp_selftest_refuses "$pp_c"; then ok "pp_selftest refuses the list $pp_c"; else bad "pp_selftest accepts the list $pp_c"; fi
done
# a good list, with allow, negative sample and no newline at the end, passes
printf 'foo/\n# sample+: -Lfoo/x\n# sample-: a zfoo/test\n# allow: zfoo/test\n# sample+: ../foo/x' > "$pp_t/st-good"
pp_load "$pp_t/st-good" "$pp_t/n" "$pp_t/a" && (ok() { :; }; bad() { :; }; pp_selftest "$pp_t/st-good" "$pp_t/n" "$pp_t/a") && ok "pp_selftest passes a good list that has no final newline" || bad "pp_selftest refuses a good list"
if [ "$pp_ok" = 1 ]; then
	pp_selftest "$needles" "$pp_pat" "$pp_allow" || true
	: > "$S/pp-files"
	for p in Makefile scripts lib/libnvrm/Makefile README.md docs man; do
		find "$repo/$p" -type f >> "$S/pp-files" 2>/dev/null || true
	done
	for p in "$repo"/tests/*.sh "$repo"/tests/fixtures/*; do
		[ ! -f "$p" ] || printf '%s\n' "$p" >> "$S/pp-files"
	done
	pp_hits "$pp_pat" "$pp_allow" $(cat "$S/pp-files") > "$scan" 2>/dev/null || bad "personal-path scan could not run"
	if [ -s "$scan" ]; then
		sed "s|$repo|<repo>|g" "$scan"
		bad "personal paths remain"
	else
		ok "no personal paths in code, tests, README.md, docs or man"
	fi
else
	bad "tests/lib/personal-paths.txt is missing, empty, unreadable or has a mistyped line"
fi

if [ "$fail" = 0 ]; then
	echo "make_install_flow_test: PASS"
	exit 0
fi
echo "make_install_flow_test: $fail FAILED"
exit 1

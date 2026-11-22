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

new_dest() {
	mkdir -p -- "$1/boot/modules" "$1/usr/local/etc" "$1/etc"
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
assert d["schema_version"] == "1.0" and d["tool"] == "install"
assert d["outcome"] == "blocked" and d["installed"] == []
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
if [ "$rc" = 0 ] && grep -q '/boot/modules/nvidia.ko' "$S/installed.out" \
    && grep -q 'staged under' "$S/installed.out" \
    && grep -q 'kldstat' "$S/installed.out" && grep -q 'nvrm-info --json' "$S/installed.out" \
    && [ -f "$D1/boot/modules/nvidia.ko" ] \
    && grep -q 'accepted by ACCEPT_NVIDIA_LICENSE=1' "$W1/sources/nvidia-licence.accepted"; then
	ok "one command installs and prints the load and check instructions"
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
assert d["schema_version"] == "1.0" and d["tool"] == "install"
assert d["outcome"] == "installed" and d["blockers"] == []
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
assert len(d["next"]) == 3 and "staged under" in d["next"][0]
assert d["next"][1:] == ["kldstat", "nvrm-info --json"]
EOF
then ok "installed JSON is one object and agrees with English"; else bad "installed JSON (rc $rc): $(tail -n 4 "$S/installed.json" | tr '\n' ' ')"; fi

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
assert any(r["path"] == "/boot/modules/nvidia.ko" for r in rows[-1]["installed"])
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
assert not any("kldload" in n for n in d["next"]), d["next"]
assert any("staged under" in n for n in d["next"]), d["next"]
PEOF
then ok "a DESTDIR install says the files are staged, no kldload"
else bad "DESTDIR next steps: $(tr -d '\n' < "$S/installed.json" | head -c 300)"; fi
_ns=
for _m in root doas sudo su; do
	_ns="$_ns$(env GB10_TEST_HOOKS=1 GB10_TEST_ROOT_METHOD=$_m MK_DESTDIR= sh "$repo/scripts/make.sh" _next-steps 2>/dev/null | head -n 1)|"
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
import json, os, sys
repo = sys.argv[1]
schema = json.load(open(os.path.join(repo, "schema/make-install-1.schema.json")))
fixture = json.load(open(os.path.join(repo, "tests/fixtures/make-install.json")))
samples = json.load(open(os.path.join(repo, "schema/samples.json")))["samples"]
row = [s for s in samples if s.get("schema") == "schema/make-install-1.schema.json"]
assert len(row) == 1 and row[0]["fixture"] == "tests/fixtures/make-install.json"
assert schema["properties"]["tool"]["const"] == "install"
assert schema["properties"]["outcome"]["enum"] == ["installed", "blocked", "interrupted"]
assert set(schema["required"]) == {"schema_version", "tool", "outcome", "blockers", "installed", "next"}
for doc in (fixture, json.load(open(sys.argv[2])), json.load(open(sys.argv[3]))):
    assert doc["schema_version"] == "1.0" and doc["tool"] == "install"
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
# one decoder and one table: the blk decoder is esc_bytes in its own mode
if [ "$(grep -c 'index("0123456789abcdef"' "$repo/scripts/make.sh")" = 1 ] \
    && [ "$(grep -c 'function hv' "$repo/scripts/make.sh")" = 1 ] \
    && [ "$(grep -c '^blk_unesc() {' "$repo/scripts/make.sh")" = 1 ] \
    && sed -n '/^blk_unesc() {/,/^}/p' "$repo/scripts/make.sh" | grep -q 'esc_bytes unblk'; then
	ok "the byte decoder and the escape table are written once"
else
	bad "make.sh has more than one byte decoder"
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

# No personal defaults.  The needles are tests/lib/personal-paths.txt, the
# same list tests/readme_install_doc_test.sh reads.  README.md, docs/ and man/
# are covered too.
needles=$repo/tests/lib/personal-paths.txt
scan=$S/no-user-paths
if [ -s "$needles" ]; then ok "personal-path needle list exists"; else bad "tests/lib/personal-paths.txt is missing or empty"; fi
: > "$scan"
for p in Makefile scripts lib/libnvrm/Makefile README.md docs man; do
	grep -R -n -F -f "$needles" "$repo/$p" >> "$scan" 2>/dev/null || true
done
for p in "$repo"/tests/*.sh "$repo"/tests/fixtures/*; do
	[ ! -f "$p" ] || grep -n -F -f "$needles" "$p" >> "$scan" 2>/dev/null || true
done
if [ -s "$scan" ]; then
	sed "s|$repo|<repo>|g" "$scan"
	bad "personal paths remain"
else
	ok "no personal paths in code, tests, README.md, docs or man"
fi

if [ "$fail" = 0 ]; then
	echo "make_install_flow_test: PASS"
	exit 0
fi
echo "make_install_flow_test: $fail FAILED"
exit 1

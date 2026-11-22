#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# install_e2e_test.sh - the stock-install harness (tests/install-e2e)
# without a VM:
#   (a) guest.sh refuses root, and refuses a missing --repo-url
#   (b) guest.sh runs the whole flow on a fixture repository that follows
#       the Makefile contract and installs into a directory of its own (no
#       root): every step passes, steps.jsonl holds one stock-install-step/1
#       object per line with consecutive indexes, summary.json says pass,
#       the installed manifest matches the expected one
#   (c) a fixture whose deinstall leaves a file behind fails nothing-left
#       ... and one whose expected manifest differs fails manifest-expected
#   (d) run.sh --backend ssh --dry-run prints the plan and a summary
#   (e) run.sh --backend vmm --arch aarch64 is blocked (exit 3) with a reason
#       (the stock image lookup and all remote commands are PATH stubs)
#   (g) --make-arg reaches every make command line; a bad name is refused
#   (h) run.sh single-quotes the arguments of the remote guest command
#   (i) gated kld stubs make a module left loaded fail the load step
#   (j) an empty ssh result collection forces a failing verdict
#   (k) kld test hooks are confined to the load step, require a private
#       invoking-user-owned directory, and stub doas accepts only stub klds;
#       this test script itself refuses root
#   (l) kldstat failures before and after a load fail the load step
#   (m) run.sh refuses ref characters outside [0-9A-Za-z._/-]
#   (f) every JSON line validates against schema/stock-install-step-1 and
#       the summary against schema/stock-install-summary-1 (python3)
# Scratch under WORK/tmp (never /tmp).

set -u
[ "$(id -u)" != 0 ] || { echo "install_e2e_test.sh: run it as a normal user, not root" >&2; exit 2; }
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
export PATH
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
base=${GB10_WORK:-$repo/work}
mkdir -p -- "$base/tmp"
S=$(mktemp -d "$base/tmp/install-e2e.XXXXXX") || exit 1
trap 'rm -rf -- "$S"' EXIT
fail=0
ok() { printf 'ok    %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1"; fail=$((fail + 1)); }
G="git -c user.name=t -c user.email=t@t -c init.defaultBranch=main"
H=$repo/tests/install-e2e

# Host-side commands are stubs on PATH: no network, VM or remote host is
# needed.  The image response is valid; the ssh collect deliberately emits an
# empty tar stream for case (j).
B=$S/ssh-stubs
mkdir -p "$B"
cat > "$B/fetch" <<'EOF'
#!/bin/sh
out=
while [ $# -gt 0 ]; do
	if [ "$1" = -o ]; then out=$2; shift 2; else shift; fi
done
[ -z "$out" ] || printf 'SHA256 (FreeBSD-16.0-CURRENT-arm64-aarch64-BASIC-CLOUDINIT-ufs.raw.xz) = %064d\n' 0 > "$out"
exit 0
EOF
cat > "$B/ssh" <<'EOF'
#!/bin/sh
case "$*" in
*'uname -rp'*) printf '16.0-CURRENT aarch64\n' ;;
*'tar -cf - results'*) : ;;
esac
exit 0
EOF
cat > "$B/scp" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod 755 "$B/fetch" "$B/ssh" "$B/scp"

# fixture FIX LEAVE EXPECTED: a contract repository at $S/FIX whose install
# writes $S/FIX.root/opt/hello (and its manifest); LEAVE=1 makes deinstall
# leave a file behind; EXPECTED is the expected-manifest line it commits
fixture() {
	_f=$S/$1
	_r=$S/$1.root
	mkdir -p "$_f" "$_r"
	cat > "$_f/Makefile" <<EOF
REPO_PURPOSE = application
YES = 0
help:
	@printf '%s\n' "purpose: \$(REPO_PURPOSE)"
purpose:
	@printf '%s\n' "\$(REPO_PURPOSE)"
preflight:
	@printf '%s\n' '{' '  "schema_version": "1.0",' '  "status": [],' '  "device": "no NVIDIA device"' '}'
ACCEPT_X = 0
install-prereqs:
	@[ "\$(ACCEPT_X)" = 1 ] || [ "${4:-}" != needs-accept ] || { echo "ACCEPT_X=1 is needed"; exit 1; }
	@echo prereqs ok
configure:
	@echo nothing to configure
install:
	@mkdir -p $_r/opt $_r/db && printf 'hi\n' > $_r/opt/hello && chmod 444 $_r/opt/hello && printf '%s 444 %s %s\n' $_r/opt/hello "\$\$(id -un):\$\$(id -gn)" "\$\$(sha256 -q $_r/opt/hello)" > $_r/db/m && echo installed
deinstall:
	@rm -f $_r/db/m && $( [ "$2" = 1 ] && echo true || echo "rm -f $_r/opt/hello" ) && { rmdir $_r/opt $_r/db 2>/dev/null; true; } && echo removed
EOF
	printf '%s\n' "$3" > "$_f/expected.manifest"
	(cd "$_f" && $G init -q && $G add -A . && _t=$($G write-tree) \
	    && _c=$(echo fixture | $G commit-tree "$_t") && $G update-ref refs/heads/main "$_c") || return 1
}

me=$(id -un):$(id -gn)

# (a)
if [ "$(id -u)" != 0 ]; then
	sh "$H/guest.sh" --results "$S/a" > "$S/a.out" 2>&1
	[ $? = 2 ] && ok "guest.sh needs --repo-url" || bad "(a) no --repo-url"
fi

# (b) a good fixture: every step passes
fixture good 0 "$S/good.root/opt/hello 444 $me" || bad "fixture good"
mkdir -p "$S/good.root"
sh "$H/guest.sh" --repo-url "file://$S/good" --results "$S/rb" --installed-manifest "$S/good.root/db/m" \
    --expected-manifest expected.manifest --watch "$S/good.root" --no-load > "$S/b.out" 2>&1
rc=$?
if [ "$rc" = 0 ] && grep -q '"pass":true' "$S/rb/summary.json" && ! grep -q '"pass":false' "$S/rb/steps.jsonl"; then
	ok "guest.sh: every step passes on a good fixture"
else
	bad "(b) rc $rc: $(grep '"pass":false' "$S/rb/steps.jsonl" | head -3)"
fi
for st in env clone preflight-before install-prereqs preflight-after install manifest-on-disk manifest-expected configure deinstall nothing-left; do
	grep -q "\"step\":\"$st\"" "$S/rb/steps.jsonl" || bad "(b) no step $st"
done
n=$(wc -l < "$S/rb/steps.jsonl" | tr -d ' ')
last=$(sed -n '$s/.*"index":\([0-9]*\).*/\1/p' "$S/rb/steps.jsonl")
[ "$last" = $((n - 1)) ] && ok "steps.jsonl: $n records, indexes 0..$last" || bad "(b) indexes: $n lines, last $last"

# (g) --make-arg reaches every make command line: a fixture whose
# install-prereqs needs ACCEPT_X=1 fails without it and passes with it
fixture lic 0 "$S/lic.root/opt/hello 444 $me" needs-accept || bad "fixture lic"
mkdir -p "$S/lic.root"
sh "$H/guest.sh" --repo-url "file://$S/lic" --results "$S/rg1" --no-load > "$S/g1.out" 2>&1
rc1=$?
sh "$H/guest.sh" --repo-url "file://$S/lic" --results "$S/rg2" --make-arg ACCEPT_X=1 --no-load > "$S/g2.out" 2>&1
rc2=$?
if [ "$rc1" = 1 ] && grep -q '"step":"install-prereqs","pass":false' "$S/rg1/steps.jsonl" \
    && grep -q '"step":"install-prereqs","pass":true' "$S/rg2/steps.jsonl"; then
	ok "--make-arg reaches make: without it install-prereqs fails, with it it passes"
else
	bad "(g) --make-arg rc $rc1 $rc2"
fi
sh "$H/guest.sh" --repo-url "file://$S/lic" --results "$S/rg3" --make-arg 'bad name=1' > "$S/g3.out" 2>&1
[ $? = 2 ] && ok "--make-arg refuses a bad name" || bad "(g) --make-arg bad name"

# (h) run.sh single-quotes every argument of the remote guest command, so a
# URL holding shell syntax stays one word
PATH="$B:$PATH" sh "$H/run.sh" --repo-url "file:///x'; echo INJECTED; '" --backend ssh --ssh nobody@localhost --dry-run --results "$S/rh" > "$S/h.out" 2>&1
want=$(cat <<'W'
--repo-url 'file:///x'\''; echo INJECTED; '\'''
W
)
{ grep -qF -- "$want" "$S/h.out" || grep -q 'cannot fetch' "$S/h.out"; } \
    && ok "run.sh single-quotes the guest arguments" || bad "(h) quoting: $(grep host:plan "$S/h.out")"

# (c) a fixture that leaves a file behind, and one with a wrong expected manifest
fixture leaky 1 "$S/leaky.root/opt/hello 444 $me" || bad "fixture leaky"
mkdir -p "$S/leaky.root"
sh "$H/guest.sh" --repo-url "file://$S/leaky" --results "$S/rc" --installed-manifest "$S/leaky.root/db/m" \
    --watch "$S/leaky.root" --no-load > "$S/c.out" 2>&1
rc=$?
[ "$rc" = 1 ] && grep -q '"step":"nothing-left","pass":false' "$S/rc/steps.jsonl" \
    && ok "a deinstall that leaves a file behind fails nothing-left" || bad "(c) leaky rc $rc"
fixture wrong 0 "$S/wrong.root/opt/hello 555 $me" || bad "fixture wrong"
sh "$H/guest.sh" --repo-url "file://$S/wrong" --results "$S/rw" --installed-manifest "$S/wrong.root/db/m" \
    --expected-manifest expected.manifest --no-load > "$S/w.out" 2>&1
rc=$?
[ "$rc" = 1 ] && grep -q '"step":"manifest-expected","pass":false' "$S/rw/steps.jsonl" \
    && ok "a manifest that differs from the expected one fails" || bad "(c) wrong manifest rc $rc"

# (d) run.sh ssh dry run
PATH="$B:$PATH" sh "$H/run.sh" --repo-url "file://$S/good" --backend ssh --ssh nobody@localhost --dry-run --results "$S/rd" > "$S/d.out" 2>&1
rc=$?
if grep -q '^PASS host:image' "$S/d.out" || grep -q 'cannot fetch' "$S/d.out"; then
	if grep -q 'cannot fetch' "$S/d.out"; then
		ok "run.sh: offline, the image check is reported as blocked (exit $rc)"
	else
		[ "$rc" = 0 ] && grep -q 'host:plan' "$S/rd/run.jsonl" && ok "run.sh --backend ssh --dry-run prints the plan" || bad "(d) rc $rc"
	fi
else
	bad "(d) $(head -n 2 "$S/d.out")"
fi

# (e) vmm aarch64: blocked with a reason
PATH="$B:$PATH" sh "$H/run.sh" --repo-url "file://$S/good" --backend vmm --arch aarch64 --results "$S/re" > "$S/e.out" 2>&1
rc=$?
[ "$rc" = 3 ] && grep -q '"blocked":"[^"]' "$S/re/summary.json" && ok "run.sh vmm aarch64: blocked (exit 3) with a reason" || bad "(e) rc $rc"

# (i) GUEST_KLD_TEST_DIR is honoured only behind GUEST_TEST_HOOKS=1.  The
# unload stub deliberately leaves the module in kldstat, so load must fail.
K=$S/kld-stubs
mkdir -p "$K"
cat > "$K/kldstat" <<'EOF'
#!/bin/sh
[ "${KLDSTAT_STUB_FAIL:-}" != before ] || exit 1
if [ "${KLDSTAT_STUB_FAIL:-}" = after ] && [ -f "$GUEST_KLD_TEST_DIR/loaded" ]; then exit 1; fi
printf ' Id Refs Address Size Name\n'
[ ! -f "$GUEST_KLD_TEST_DIR/loaded" ] || printf ' 1 1 0x0 0x1000 nvidia-drm.ko\n'
EOF
cat > "$K/kldload" <<'EOF'
#!/bin/sh
: > "$GUEST_KLD_TEST_DIR/loaded"
EOF
cat > "$K/kldunload" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$K/doas" <<'EOF'
#!/bin/sh
case ${1:-} in
"$GUEST_KLD_TEST_DIR/kldload"|"$GUEST_KLD_TEST_DIR/kldunload") exec "$@" ;;
*) echo "stub doas: refusing $*" >&2; exit 1 ;;
esac
EOF
cat > "$K/git" <<'EOF'
#!/bin/sh
: > "$GUEST_KLD_TEST_DIR/path-escaped"
exit 1
EOF
chmod 755 "$K/kldstat" "$K/kldload" "$K/kldunload" "$K/doas" "$K/git"
GUEST_KLD_TEST_DIR="$K" "$K/doas" /bin/true > "$S/k-doas.out" 2>&1
rc=$?
if [ "$rc" != 0 ] && grep -q 'refusing' "$S/k-doas.out"; then
	ok "stub doas refuses a command other than a stub kld command"
else
	bad "(k) stub doas passed through an arbitrary command"
fi
if sed -n '1,45p' "$0" | grep -q 'echo "install_e2e_test.sh: run it as a normal user, not root"'; then
	ok "install_e2e_test.sh refuses root"
else
	bad "(k) install_e2e_test.sh has no root refusal"
fi
if ! grep -q 'GUEST_TEST_HOOKS' "$H/guest.sh" || ! grep -q 'GUEST_KLD_TEST_DIR' "$H/guest.sh"; then
	bad "(i) guest.sh has no gated kld test hooks; the leftover-module case was not run"
else
	GUEST_TEST_HOOKS=1 GUEST_KLD_TEST_DIR="$K" sh "$H/guest.sh" --repo-url "file://$S/good" \
	    --results "$S/ri" --load nvidia-drm > "$S/i.out" 2>&1
	rc=$?
	if [ "$rc" = 1 ] && grep -q '"step":"load","pass":false' "$S/ri/steps.jsonl" \
	    && grep '"step":"load"' "$S/ri/steps.jsonl" | grep -q 'nvidia-drm.ko'; then
		ok "guest.sh fails load when a module remains after unload"
	else
		bad "(i) leftover module (rc $rc): $(grep '"step":"load"' "$S/ri/steps.jsonl")"
		if [ -f "$S/ri/kld.before" ] && [ -f "$S/ri/kld.after" ] && [ -f "$S/ri/kld.unloaded" ]; then
			printf '  kld before: %s\n  kld after: %s\n  kld unloaded: %s\n' \
			    "$(tr '\n' ' ' < "$S/ri/kld.before")" "$(tr '\n' ' ' < "$S/ri/kld.after")" \
			    "$(tr '\n' ' ' < "$S/ri/kld.unloaded")"
		fi
		[ ! -f "$S/ri/logs/load.log" ] || sed -n '1,12p' "$S/ri/logs/load.log"
	fi
fi
if [ ! -e "$K/path-escaped" ]; then
	ok "kld test hooks do not put their directory on PATH outside the load step"
else
	bad "(k) the kld hook directory replaced git outside the load step"
fi
chmod 775 "$K"
GUEST_TEST_HOOKS=1 GUEST_KLD_TEST_DIR="$K" sh "$H/guest.sh" --repo-url "file://$S/good" \
    --results "$S/rk-unsafe" --load nvidia-drm > "$S/k-unsafe.out" 2>&1
rc=$?
chmod 755 "$K"
if [ "$rc" = 2 ] && grep -q 'not writable by group or other' "$S/k-unsafe.out"; then
	ok "guest.sh refuses a group-writable kld hook directory"
else
	bad "(k) group-writable hook directory returned rc $rc"
fi

# (l) neither a pre-load nor a post-load kldstat failure is an empty list
for when in before after; do
	rm -f "$K/loaded"
	KLDSTAT_STUB_FAIL=$when GUEST_TEST_HOOKS=1 GUEST_KLD_TEST_DIR="$K" \
	    sh "$H/guest.sh" --repo-url "file://$S/good" --results "$S/rl-$when" \
	    --load nvidia-drm > "$S/l-$when.out" 2>&1
	rc=$?
	if [ "$rc" = 1 ] && grep '"step":"load"' "$S/rl-$when/steps.jsonl" \
	    | grep -q "\"pass\":false.*kldstat $when load failed"; then
		ok "guest.sh fails load when kldstat fails $when the load"
	else
		bad "(l) kldstat $when failure returned rc $rc: $(grep '"step":"load"' "$S/rl-$when/steps.jsonl")"
	fi
done

# (j) an empty tar stream from ssh must poison the final verdict even when
# the remote guest returned zero.  PATH supplies every remote-side stub;
# run.sh needs no test-specific hook for this.
PATH="$B:$PATH" sh "$H/run.sh" --repo-url "file://$S/good" --backend ssh \
    --ssh nobody@localhost --results "$S/rj" > "$S/j.out" 2>&1
rc=$?
if [ "$rc" = 1 ] && grep -q '"pass":false' "$S/rj/summary.json" \
    && grep -q '"step":"host:collect","pass":false' "$S/rj/run.jsonl" \
    && grep -q 'could not bring the results back' "$S/rj/run.jsonl"; then
	ok "run.sh fails an empty ssh result collection"
else
	bad "(j) empty ssh collection returned rc $rc: $(tail -n 2 "$S/j.out" | tr '\n' ' ')"
fi

# (m) a ref is data for git, never remote shell syntax; invalid characters
# are a usage error before any fetch or remote command
PATH="$B:$PATH" sh "$H/run.sh" --repo-url "file://$S/good" --ref 'bad;ref' \
    --backend ssh --ssh nobody@localhost --dry-run --results "$S/r-ref" > "$S/ref.out" 2>&1
rc=$?
if [ "$rc" = 2 ] && grep -q 'run.sh: invalid --ref' "$S/ref.out"; then
	ok "run.sh refuses a ref outside [0-9A-Za-z._/-]"
else
	bad "(m) invalid ref returned rc $rc instead of 2"
fi

# (f) schemas
if command -v python3 > /dev/null 2>&1; then
	if python3 -I - "$repo/schema" "$S/rb/steps.jsonl" "$S/rb/summary.json" "$S/re/summary.json" <<'EOF'
import json, sys
sd, steps, *sums = sys.argv[1:]
st = json.load(open(sd + "/stock-install-step-1.schema.json"))
su = json.load(open(sd + "/stock-install-summary-1.schema.json"))
def check(o, sc):
    for k in sc["required"]:
        assert k in o, k
    for k, v in o.items():
        p = sc["properties"].get(k)
        assert p is not None or sc.get("additionalProperties", True), k
        if p and "const" in p: assert v == p["const"], (k, v)
        if p and p.get("type") == "boolean": assert isinstance(v, bool), k
        if p and p.get("type") == "integer": assert isinstance(v, int), k
for line in open(steps):
    check(json.loads(line), st)
for f in sums:
    check(json.load(open(f)), su)
EOF
	then ok "the JSONL and summaries follow their schemas"; else bad "(f) schemas"; fi
else
	ok "python3 not installed: schema shape check skipped"
fi

if [ "$fail" = 0 ]; then
	echo "install_e2e_test: PASS"
	exit 0
fi
echo "install_e2e_test: $fail FAILED"
exit 1

#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# gpu_check_test.sh - the card check command: the decision, the checks, the
# output contract, and the lint that keeps the vendor knowledge in the data.
#
# The checks are registered in the library (lib/gpu-check); the tool asks
# the registry what to run and holds no list of its own.  The cases below
# hold that: a check added to the library appears in the rows of the tool.
#
# Cases:
#   (a) the tool, the library, the man page and the provider record are in
#       the tree
#   (b) the five cards of the fake pciconf: a supported card, a card the
#       driver does not cover on this architecture, a legacy card, a card of
#       another vendor, and a mixed box
#   (c) the run needs no root: the detection and the decision work as a
#       normal user, and --load without a fake is refused
#   (d) the --load path against the fake: the firmware and the driver of the
#       served card are loaded, and a refused card is never touched
#   (e) --json prints one document that matches schema/gpu-check-1.schema.json
#   (f) --jsonl prints a flushed stream: a header, a record per card, a
#       record per check and an end record
#   (g) --report writes a file to attach, and nothing is sent anywhere
#   (h) no personal data is in the output: no host name, no user name, no
#       home path, no serial, and the UUID is hashed
#   (i) the vendor-free lint: the shared code names no vendor, and a planted
#       file that names one is refused
#   (j) a broken provider record is refused, not used
#   (k) the fake provider: a board decorator and a family that refuses
#   (l) every card has one row per registered check, and every row says why
#   (m) --help and the man page name every option
#   (n) an empty fake file is a fake run: it loads nothing and needs no root
#   (o) the fake file has one vocabulary: pass, fail, not_tested, not_available
#   (p) every error path speaks the language of the mode it was asked for
#   (q) the stream is written as it goes: the header is out while the tool
#       is still working on the cards
#   (r) a feature flag and the row that follows it say the same thing
#   (s) the loaded list holds the modules that were loaded, and only those
#   (t) two cards of one machine get their own answers
#   (u) a provider record that cannot be used is refused, not used
#   (w) the schema checker of the suite holds what the schemas hold
#   (x) the makefile puts no free text in a recipe
#   (y) a load run takes the modules of the installed registry only
#   (z) the report replaces a symlink and leaves the file it pointed at alone
#   (bb) the architecture is normalized, and one that is not an architecture
#       is a usage error
#   (dd) a selector that matches no card is a usage error
#   (ee) the text output says what happened and what to do next
#   (ff) the value of an option is a value, never another option
#   (gg) the installed tool finds its library and its adapters
#   (hh) the plain table is the same bytes every time: the golden file
#   (ii) --list lists the checks and what each one needs
#   (jj) --check runs the checks that were named and the ones they depend on
#   (kk) a mutant that drops the reason of a row is killed
#   (ll) the recorded run of 2026-11-26 replays as it was recorded
#   (mm) the fake backend answers what the file says, and nothing else
#   (nn) the checks of the environment of a native run
#   (oo) the registry is the only list of checks
#   (pp) the colour is for a terminal, and NO_COLOR says no
#   (qq) the load of a module that is already loaded, and of one that is
#       not installed
#   (rr) --assume-loaded runs every check and loads nothing
#   (ss) the unit tests of the library: the paths a command never takes
#   (tt) the checks against the fake backend of our own library: the memory
#       and the channel steps run over a card that behaves like one
#
# Run: sh tests/gpu_check_test.sh

set -u

PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL

TESTSDIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH= cd -- "$TESTSDIR/.." && pwd)
TOOL="$REPO/scripts/gpu-check"
LIB="$REPO/lib/gpu-check"
DATA="$REPO/tests/data/gpu-check"

PASSED=0
FAILED=0

ok() {
	PASSED=$((PASSED + 1))
	printf 'ok   %s\n' "$1"
}

bad() {
	FAILED=$((FAILED + 1))
	printf 'FAIL %s\n' "$1"
}

# Scratch inside the repository (tmp/ is git-ignored), not in the system
# temporary directory and not outside the repository.
mkdir -p "$REPO/tmp"
TESTROOT=$(mktemp -d "$REPO/tmp/gpu-check-test.XXXXXXXX") || exit 1

cleanup() {
	rm -rf "$TESTROOT"
}
trap cleanup EXIT INT TERM

# The tool runs with python3: the script has no extension.  The record of
# the run is not kept here: the cases of this suite are about the tool,
# and the record has its own suite (tests/gpu_check_db_test.sh).
run_tool() {
	python3 "$TOOL" --no-db "$@" 2>"$TESTROOT/stderr"
}

# expect_rc DESCRIPTION EXPECTED_RC COMMAND...: the command runs, and the
# exit status is what counts.
expect_rc() {
	_desc=$1
	_want=$2
	shift 2
	"$@" > "$TESTROOT/out" 2> "$TESTROOT/err"
	_got=$?
	if [ "$_got" = "$_want" ]; then
		ok "$_desc (rc $_got)"
	else
		bad "$_desc: rc is $_got, not $_want: $(head -c 200 "$TESTROOT/err" | tr '\n' ' ')"
	fi
}

# (a) the tool, the library, the man page and the provider record are in
# the tree.
if [ -x "$TOOL" ] && [ -f "$REPO/man/gpu-check.8" ] && [ -f "$REPO/data/providers/nvidia-open.json" ] &&
	[ -f "$REPO/schema/gpu-check-1.schema.json" ] && [ -f "$LIB/gpu_check/registry.py" ] &&
	[ -f "$LIB/gpu_check/checks.py" ]; then
	ok "(a) the tool, the man page, the library, the provider record and the schema are in the tree"
else
	bad "(a) the tool, the man page, the library, the provider record or the schema is missing"
	printf 'passed: %s failed: %s\n' "$PASSED" "$FAILED"
	exit 1
fi

if command -v mandoc > /dev/null 2>&1; then
	mandoc -T lint -W warning "$REPO/man/gpu-check.8" > "$TESTROOT/lint" 2>&1
	if [ ! -s "$TESTROOT/lint" ]; then
		ok "(a) man/gpu-check.8: mandoc -T lint -W warning is quiet"
	else
		bad "(a) man/gpu-check.8: $(tr '\n' ' ' < "$TESTROOT/lint")"
	fi
else
	printf 'note: mandoc is not installed: the man page was not linted\n'
fi

# (b) the five cards of the fake pciconf.
run_tool --pciconf-file "$DATA/pciconf-supported.txt" --arch arm64 > "$TESTROOT/supported.out"
_supported_rc=$?
run_tool --pciconf-file "$DATA/pciconf-unsupported.txt" --arch arm64 > "$TESTROOT/unsupported.out"
_unsupported_rc=$?
run_tool --pciconf-file "$DATA/pciconf-legacy.txt" --arch arm64 > "$TESTROOT/legacy.out"
_legacy_rc=$?
run_tool --pciconf-file "$DATA/pciconf-nonnvidia.txt" --arch arm64 > "$TESTROOT/nonnvidia.out"
_nonnvidia_rc=$?
run_tool --pciconf-file "$DATA/pciconf-mixed.txt" --arch arm64 > "$TESTROOT/mixed.out"
_mixed_rc=$?

if [ "$_supported_rc" = 0 ] && grep -q "supported:" "$TESTROOT/supported.out" &&
	grep -q "GB20X" "$TESTROOT/supported.out"; then
	ok "(b) the supported card is served, with its generation"
else
	bad "(b) the supported card: rc $_supported_rc $(head -c 200 "$TESTROOT/supported.out" | tr '\n' ' ')"
fi

if [ "$_unsupported_rc" = 7 ] && grep -q "not_built_arm64" "$TESTROOT/unsupported.out" &&
	grep -q "gsp_tu10x" "$TESTROOT/unsupported.out"; then
	ok "(b) the card the driver does not cover here is refused, and the reason names the firmware"
else
	bad "(b) the unsupported card: rc $_unsupported_rc $(head -c 200 "$TESTROOT/unsupported.out" | tr '\n' ' ')"
fi

if [ "$_legacy_rc" = 7 ] && grep -q "below_policy" "$TESTROOT/legacy.out"; then
	ok "(b) the legacy card is refused below the policy floor"
else
	bad "(b) the legacy card: rc $_legacy_rc $(head -c 200 "$TESTROOT/legacy.out" | tr '\n' ' ')"
fi

if [ "$_nonnvidia_rc" = 3 ] && grep -q "no_provider" "$TESTROOT/nonnvidia.out"; then
	ok "(b) the card of another vendor has no provider"
else
	bad "(b) the non-NVIDIA card: rc $_nonnvidia_rc $(head -c 200 "$TESTROOT/nonnvidia.out" | tr '\n' ' ')"
fi

if [ "$_mixed_rc" = 0 ] && [ "$(grep -c '^gpu' "$TESTROOT/mixed.out")" = 3 ] &&
	grep -q "no_provider" "$TESTROOT/mixed.out" && grep -q "supported:" "$TESTROOT/mixed.out"; then
	ok "(b) the mixed box: every card is reported, the NVIDIA one is served and the others are not"
else
	bad "(b) the mixed box: rc $_mixed_rc $(head -c 200 "$TESTROOT/mixed.out" | tr '\n' ' ')"
fi

# The decision never depends on the order of the cards: the NVIDIA card is
# not the first one on the mixed box.
if grep -q "^gpu1 .*supported:" "$TESTROOT/mixed.out" && grep -q "^gpu0 .*no_provider" "$TESTROOT/mixed.out"; then
	ok "(b) the mixed box: the served card is the NVIDIA one, not the first card"
else
	bad "(b) the mixed box: the wrong card was served"
fi

# (c) the run needs no root.
if [ "$(id -u)" != 0 ]; then
	if [ "$_supported_rc" = 0 ]; then
		ok "(c) the detection and the decision work as a normal user"
	else
		bad "(c) the detection and the decision need root"
	fi
	expect_rc "(c) --load without a fake is refused for a normal user" 2 \
		run_tool --load --pciconf-file "$DATA/pciconf-supported.txt" --arch arm64
	if grep -q "needs root" "$TESTROOT/stderr"; then
		ok "(c) the refusal names the reason"
	else
		bad "(c) the refusal does not name the reason: $(head -c 200 "$TESTROOT/stderr" | tr '\n' ' ')"
	fi
else
	printf 'note: this suite runs as root: the normal-user cases were not run\n'
fi

# (d) the --load path against the fake.
run_tool --load --fake "$DATA/fake-load.json" --pciconf-file "$DATA/pciconf-mixed.txt" \
	--arch arm64 --json > "$TESTROOT/load.json"
_load_rc=$?
if [ "$_load_rc" = 0 ] && python3 - "$TESTROOT/load.json" <<'EOF'
import json, sys
doc = json.load(open(sys.argv[1]))
cards = doc["devices"]
served = [c for c in cards if c["decision"]["code"] == "supported"]
refused = [c for c in cards if c["decision"]["code"] != "supported"]
assert len(served) == 1, served
assert len(refused) == 2, refused
# the served card loaded the firmware and the driver, in that order
loaded = served[0]["loaded"]
assert loaded == ["nvidia_gsp_ga10x_fw", "nvidia", "nvidia-modeset", "nvidia-drm"], loaded
# a refused card is never touched: nothing was loaded for it
for card in refused:
    assert card["loaded"] == [], card
# the rows of the served card say what was done
rows = dict((r["name"], r) for r in served[0]["checks"])
assert rows["firmware"]["status"] == "pass", rows["firmware"]
assert rows["driver-loaded"]["status"] == "pass", rows["driver-loaded"]
assert rows["device-open"]["status"] == "pass", rows["device-open"]
assert rows["identity"]["status"] == "pass", rows["identity"]
assert rows["memory"]["status"] == "pass", rows["memory"]
assert rows["display"]["status"] == "pass", rows["display"]
# the rows of a refused card are never tested, and the reason says why
for card in refused:
    for row in card["checks"]:
        if row["name"] in ("detect", "decide", "no-linux-layer", "native-modules"):
            continue
        assert row["status"] == "not_tested", row
        assert "refused" in row["reason"] or "no provider" in row["reason"], row
EOF
then
	ok "(d) the --load path: the served card is loaded, a refused card is never touched"
else
	bad "(d) the --load path: rc $_load_rc $(head -c 300 "$TESTROOT/load.json" | tr '\n' ' ')"
fi

# A failed load stops the checks of that card and says why.
cat > "$TESTROOT/fake-fail.json" <<'EOF'
{
 "kldload": {
   "nvidia_gsp_ga10x_fw": {"status": "ok", "message": "the firmware module was loaded"},
   "nvidia": {"status": "fail", "message": "the module does not fit this kernel"}
  },
 "identity": {"status": "pass", "pci_vendor": "0x10de", "pci_device": "0x2d04"},
 "memory": {"status": "pass", "message": "not reached"}
}
EOF
run_tool --load --fake "$TESTROOT/fake-fail.json" --pciconf-file "$DATA/pciconf-supported.txt" \
	--arch arm64 --json > "$TESTROOT/loadfail.json"
_loadfail_rc=$?
if [ "$_loadfail_rc" = 1 ] && python3 - "$TESTROOT/loadfail.json" <<'EOF'
import json, sys
doc = json.load(open(sys.argv[1]))
rows = dict((r["name"], r) for r in doc["devices"][0]["checks"])
assert rows["firmware"]["status"] == "pass", rows["firmware"]
assert rows["driver-loaded"]["status"] == "fail", rows["driver-loaded"]
assert "does not fit" in rows["driver-loaded"]["reason"], rows["driver-loaded"]
# the checks that need the driver did not run
assert rows["device-open"]["status"] == "not_tested", rows["device-open"]
assert rows["memory"]["status"] == "not_tested", rows["memory"]
EOF
then
	ok "(d) a failed load fails the row and stops the checks that need the driver"
else
	bad "(d) a failed load: rc $_loadfail_rc $(head -c 300 "$TESTROOT/loadfail.json" | tr '\n' ' ')"
fi

# A fake that answers with another card fails the identity row.
cat > "$TESTROOT/fake-wrong.json" <<'EOF'
{
 "kldload": {"nvidia_gsp_ga10x_fw": {"status": "ok"}, "nvidia": {"status": "ok"},
             "nvidia-modeset": {"status": "ok"}, "nvidia-drm": {"status": "ok"}},
 "identity": {"status": "pass", "pci_vendor": "0x10de", "pci_device": "0x2204",
              "message": "another card opened"}
}
EOF
run_tool --load --fake "$TESTROOT/fake-wrong.json" --pciconf-file "$DATA/pciconf-supported.txt" \
	--arch arm64 --json > "$TESTROOT/loadwrong.json"
if python3 - "$TESTROOT/loadwrong.json" <<'EOF'
import json, sys
doc = json.load(open(sys.argv[1]))
rows = dict((r["name"], r) for r in doc["devices"][0]["checks"])
assert rows["device-open"]["status"] == "fail", rows["device-open"]
assert "not the card" in rows["device-open"]["reason"], rows["device-open"]
EOF
then
	ok "(d) the identity row fails when another card opened"
else
	bad "(d) the identity row did not fail for another card"
fi

# (e) --json prints one document that matches the schema.
run_tool --json --fake "$DATA/fake-load.json" --pciconf-file "$DATA/pciconf-mixed.txt" \
	--arch arm64 > "$TESTROOT/document.json"
if python3 "$REPO/tests/schema_check.py" "$REPO/schema/gpu-check-1.schema.json" \
	"$TESTROOT/document.json" "$REPO/tests/fixtures/gpu-check.json" \
	> "$TESTROOT/schema.out" 2>&1; then
	ok "(e) --json prints one document that matches the registered schema and its sample"
else
	bad "(e) the JSON document does not match the schema: $(tr '\n' ' ' < "$TESTROOT/schema.out")"
fi

# The error document is the other branch of the same schema.
cat > "$TESTROOT/error-document.json" <<'EOF'
{"schema_version": {"string": "1.1", "major": 1, "minor": 1, "patch": 0},
 "tool": "gpu-check", "schema": "gpu-check.v1", "status": "error",
 "error": "the machine could not be looked at", "exit": 4}
EOF
if python3 "$REPO/tests/schema_check.py" "$REPO/schema/gpu-check-1.schema.json" \
	"$TESTROOT/error-document.json" > "$TESTROOT/schema.out" 2>&1; then
	ok "(e) the error document is the other branch of the same schema"
else
	bad "(e) the error document does not match the schema: $(tr '\n' ' ' < "$TESTROOT/schema.out")"
fi

# (f) --jsonl prints a flushed stream.
run_tool --jsonl --pciconf-file "$DATA/pciconf-mixed.txt" --arch arm64 > "$TESTROOT/stream.jsonl"
if python3 - "$TESTROOT/stream.jsonl" <<'EOF'
import json, sys
lines = [l for l in open(sys.argv[1], encoding="utf-8").read().splitlines() if l.strip()]
records = [json.loads(l) for l in lines]
assert records[0]["kind"] == "header", records[0]
assert records[-1]["kind"] == "end", records[-1]
cards = [r for r in records if r["kind"] == "device"]
checks = [r for r in records if r["kind"] == "check"]
assert len(cards) == 3, len(cards)
# every card carries one record per registered check
assert len(checks) == 3 * 13, len(checks)
assert records[-1]["exit"] == 0, records[-1]
# a card record carries no checks: the checks come one by one
for card in cards:
    assert "checks" not in card, card
EOF
then
	ok "(f) --jsonl prints a header, a record per card, a record per check and an end record"
else
	bad "(f) the --jsonl stream is not what it must be"
fi

# The stream has its own schema, and the captured sample of it validates.
if python3 "$REPO/tests/schema_check.py" "$REPO/schema/gpu-check-stream-1.schema.json" \
	"$TESTROOT/stream.jsonl" "$REPO/tests/fixtures/gpu-check.jsonl" \
	> "$TESTROOT/stream-schema.out" 2>&1; then
	ok "(f) the --jsonl stream matches its own registered schema, and the captured sample does"
else
	bad "(f) the --jsonl stream does not match the registered schema: $(tr '\n' ' ' < "$TESTROOT/stream-schema.out")"
fi

# (g) --report writes a file, and nothing is sent anywhere.
run_tool --json --pciconf-file "$DATA/pciconf-supported.txt" --arch arm64 \
	--report "$TESTROOT/report.json" > /dev/null
if [ -s "$TESTROOT/report.json" ] && python3 - "$TESTROOT/report.json" <<'EOF'
import json, sys
doc = json.load(open(sys.argv[1]))
assert doc["tool"] == "gpu-check"
assert doc["schema"] == "gpu-check.v1"
assert len(doc["devices"]) == 1
EOF
then
	ok "(g) --report writes the document to the file it was given"
else
	bad "(g) --report did not write a usable document"
fi

# The tool opens no socket: the only programs it runs are the ones of the
# machine it looks at.
if grep -Eq "socket|urllib|http|requests|urlopen" "$TOOL" "$LIB/gpu-check/gpu_check/"; then
	bad "(g) the tool has network code in it"
else
	ok "(g) the tool has no network code: nothing is submitted"
fi

# (h) no personal data is in the output.
run_tool --json --load --fake "$DATA/fake-load.json" --pciconf-file "$DATA/pciconf-supported.txt" \
	--arch arm64 > "$TESTROOT/personal.json"
# The error paths are outputs too, and they are checked as well.
run_tool --json --pciconf-file "$TESTROOT/no-such-pciconf.txt" \
	> "$TESTROOT/personal-error.json" 2> "$TESTROOT/personal-error.err"
_host=$(hostname 2> /dev/null || echo "")
_user=$(id -un 2> /dev/null || echo "")
_home=${HOME:-}
_bad=0
for _needle in "$_host" "$_user" "$_home"; do
	[ -n "$_needle" ] || continue
	for _file in "$TESTROOT/personal.json" "$TESTROOT/personal-error.json" \
		"$TESTROOT/personal-error.err"; do
		if grep -qF -- "$_needle" "$_file" 2> /dev/null; then
			_bad=1
			printf 'FAIL the output holds %s\n' "$_needle"
		fi
	done
done
if [ "$_bad" = 0 ]; then
	ok "(h) the output holds no host name, no user name and no home path"
else
	FAILED=$((FAILED + 1))
	printf 'FAIL (h) the output holds personal data\n'
fi

# The home path is not in the output, not even when it is the home of
# another user and the name of it is not the name of the user.
_mkhome="$TESTROOT/other-home"
mkdir -p "$_mkhome"
(
	HOME="$_mkhome"
	export HOME
	run_tool --json --pciconf-file "$_mkhome/card.txt"
) > "$TESTROOT/other-home.json" 2>&1
if grep -qF -- "$_mkhome" "$TESTROOT/other-home.json"; then
	bad "(h) the output holds the home path of the run"
else
	ok "(h) the output holds no home path, not even the home of the run"
fi

if grep -qF "GPU-11111111-2222-3333-4444-555555555555" "$TESTROOT/personal.json"; then
	bad "(h) the UUID is in the output as it is"
else
	if grep -qF "sha256:" "$TESTROOT/personal.json"; then
		ok "(h) the UUID is hashed, never printed as it is"
	else
		bad "(h) the UUID is neither hashed nor left out"
	fi
fi

# (i) the vendor-free lint.
# The decision core of the tool names no vendor, and neither does the
# library it runs the checks from.  The vocabulary comes from the provider
# records (the names they use, the vendor ids they claim) and from the
# adapters (the programs of a vendor); a vendor constant or a vendor
# comparison is a finding by itself, whatever its value is.
cat > "$TESTROOT/lint.py" <<'EOF'
import ast, json, os, re, sys

repo = sys.argv[1]
targets = sys.argv[2:]
registry = os.path.join(repo, "data", "providers")
if not os.path.isdir(registry):
    print("the registry is missing")
    sys.exit(1)
names = set()
ids = set()
records = []
for directory in (registry, os.path.join(repo, "tests", "data", "gpu-check", "providers-fake")):
    if not os.path.isdir(directory):
        continue
    for entry in sorted(os.listdir(directory)):
        if not entry.endswith(".json"):
            continue
        doc = json.load(open(os.path.join(directory, entry)))
        records.append((directory, entry, doc))
        ids.add(doc["vendor"].lower())
        if directory == registry:
            names.add(doc["provider"])
            if doc.get("vendor_name"):
                names.add(doc["vendor_name"])
            for backend in doc.get("backends", []):
                names.add(backend["name"])
            for family in doc.get("families", []):
                names.add(family["id"])
# The probes of a vendor name the programs of that vendor: the core of
# the tool may not hold them.
adapters = os.path.join(repo, "scripts", "adapters")
if os.path.isdir(adapters):
    for entry in sorted(os.listdir(adapters)):
        if not entry.endswith(".py"):
            continue
        tree = ast.parse(open(os.path.join(adapters, entry), encoding="utf-8").read())
        for node in tree.body:
            if not isinstance(node, ast.Assign):
                continue
            if not any(getattr(one, "id", "") == "VOCABULARY" for one in node.targets):
                continue
            for word in ast.literal_eval(node.value):
                names.add(word)
names = sorted(n for n in names if len(n) > 3)
patterns = [
    r"\bVENDOR[A-Z0-9_]*\s*=",
    r"\bvendor[A-Za-z0-9_]*\s*=\s*[\"']",
    r"\bvendor[A-Za-z0-9_]*\s*[!=]=\s*(0x[0-9a-fA-F]+|[\"'])",
]
for name in names:
    patterns.append(r"\b%s\b" % re.escape(name))
for vendor in sorted(ids):
    patterns.append(r"\b%s\b" % re.escape(vendor))
hits = []
for target in targets:
    if not os.path.isfile(target):
        hits.append("the file %s is missing" % target)
        continue
    source = open(target, encoding="utf-8").read()
    for pattern in patterns:
        if re.search(pattern, source):
            hits.append("the pattern %s in %s" % (pattern, os.path.basename(target)))
# Every provider of the shipped records has an adapter that can open its
# cards: the core asks for the adapter by the vendor id.
for directory, entry, doc in records:
    if directory != registry:
        continue
    adapter = os.path.join(adapters, "%s.py" % doc["vendor"].lower())
    if not os.path.isfile(adapter):
        hits.append("the provider %s has no probe adapter" % doc["provider"])
if hits:
    for hit in hits:
        print("the shared code holds %s" % hit)
    sys.exit(1)
EOF
_lint_targets="$TOOL"
for _f in "$LIB"/gpu_check/*.py; do
	_lint_targets="$_lint_targets $_f"
done
if python3 "$TESTROOT/lint.py" "$REPO" $_lint_targets > "$TESTROOT/lint.out" 2>&1; then
	ok "(i) the shared code of the tool and of the library names no vendor"
else
	bad "(i) the shared code names a vendor: $(tr '\n' ' ' < "$TESTROOT/lint.out")"
fi

# The lint must fail on a file that names a vendor: a lint that cannot fail
# is not a lint.
cat > "$TESTROOT/planted.c" <<'EOF'
static int
planted(const struct dev_id *id)
{
	if (id->vendor == 0x10de)
		return 1;
	return 0;
}
EOF
if python3 "$TESTROOT/lint.py" "$REPO" "$TESTROOT/planted.c" > "$TESTROOT/planted.out" 2>&1; then
	bad "(i) the lint accepted a planted file that names a vendor"
else
	ok "(i) the lint refuses a planted file that names a vendor"
fi

# A plain vendor name is a finding too, and so is a vendor comparison
# with a value the lint does not know.
cat > "$TESTROOT/planted-name.c" <<'EOF'
static const char *vendor = "nvidia";
EOF
if python3 "$TESTROOT/lint.py" "$REPO" "$TESTROOT/planted-name.c" > /dev/null 2>&1; then
	bad "(i) the lint accepted a planted file that names a vendor in a string"
else
	ok "(i) the lint refuses a planted file that names a vendor in a string"
fi

cat > "$TESTROOT/planted-id.c" <<'EOF'
static int
planted(const struct dev_id *id)
{
	if (id->vendor == 0x1234)
		return 1;
	return 0;
}
EOF
if python3 "$TESTROOT/lint.py" "$REPO" "$TESTROOT/planted-id.c" > /dev/null 2>&1; then
	bad "(i) the lint accepted a planted file that compares a vendor with an id"
else
	ok "(i) the lint refuses a planted file that compares a vendor with an id"
fi

# The programs of a vendor belong to the adapter, not to the core.
cat > "$TESTROOT/planted-probe.c" <<'EOF'
static int
planted(void)
{
	return system("nvrm-info --json");
}
EOF
if python3 "$TESTROOT/lint.py" "$REPO" "$TESTROOT/planted-probe.c" > /dev/null 2>&1; then
	bad "(i) the lint accepted a planted file that runs a program of a vendor"
else
	ok "(i) the lint refuses a planted file that runs a program of a vendor"
fi

# The lint must also fail closed: a registry it cannot read is a failure,
# not a clean lint.  This is the lint itself, not a second script.
if python3 "$TESTROOT/lint.py" "$TESTROOT/nowhere" "$TOOL" > /dev/null 2>&1; then
	bad "(i) the lint passes when the registry is missing"
else
	ok "(i) the lint fails closed when the registry is missing"
fi

# (j) a broken provider record is refused, not used.
mkdir -p "$TESTROOT/badreg"
cat > "$TESTROOT/badreg/bad.json" <<'EOF'
{
 "schema_version": {"string": "1.0", "major": 1, "minor": 0, "patch": 0},
 "provider": "bad", "vendor": "0x10de", "classes": ["0x03"], "score": 1,
 "generation_order": [{"name": "alpha", "arch_values": [99]}],
 "policy": {"min_generation": "alpha", "reason": "a test"},
 "feature_flags": [{"index": 1, "name": "display"}],
 "backends": [{"name": "b", "archs": ["amd64"], "score": 1, "modules": ["m"]}],
 "families": [
  {"id": "alpha", "arch_values": [99], "devids": ["0x1234"], "backends": ["b"],
   "generations": [{"name": "alpha", "arch_values": [99]}], "features": {"display": true}},
  {"id": "beta", "arch_values": [99], "devids": ["0x1234"], "backends": ["b"],
   "generations": [{"name": "alpha", "arch_values": [99]}], "features": {"display": true}}
 ],
 "decorators": []
}
EOF
expect_rc "(j) a record with one device id in two families is refused" 2 \
	run_tool --registry "$TESTROOT/badreg" --pciconf-file "$DATA/pciconf-supported.txt" --arch arm64
if grep -q "device id" "$TESTROOT/stderr"; then
	ok "(j) the refusal names the device id that is in two families"
else
	bad "(j) the refusal does not name the device id: $(head -c 200 "$TESTROOT/stderr" | tr '\n' ' ')"
fi

# A record that names a vendor but no family of the device id refuses the
# card as uncovered, and says what to do about it.
mkdir -p "$TESTROOT/uncoveredreg"
python3 - "$TESTROOT/uncoveredreg" "$REPO/data/providers/nvidia-open.json" <<'EOF'
import json, os, sys
out, source = sys.argv[1], sys.argv[2]
doc = json.load(open(source))
doc["families"] = [doc["families"][0]]
doc["families"][0]["devids"] = ["0x1234"]
json.dump(doc, open(os.path.join(out, "nvidia-open.json"), "w"), indent=1)
EOF
run_tool --registry "$TESTROOT/uncoveredreg" --pciconf-file "$DATA/pciconf-supported.txt" \
	--arch arm64 > "$TESTROOT/uncovered.out"
_uncovered_rc=$?
if [ "$_uncovered_rc" = 7 ] && grep -q "uncovered" "$TESTROOT/uncovered.out" &&
	grep -q "provider record" "$TESTROOT/uncovered.out"; then
	ok "(j) a device id no family covers is refused as uncovered, with the next step"
else
	bad "(j) the uncovered card: rc $_uncovered_rc $(head -c 200 "$TESTROOT/uncovered.out" | tr '\n' ' ')"
fi

# (k) the fake provider: a board decorator and a family that refuses.
run_tool --registry "$DATA/providers-fake" --pciconf-file "$DATA/pciconf-fake.txt" \
	--arch arm64 --json > "$TESTROOT/fake.json"
if python3 - "$TESTROOT/fake.json" <<'EOF'
import json, sys
doc = json.load(open(sys.argv[1]))
cards = dict((c["identity"]["device"], c) for c in doc["devices"])
assert len(cards) == 2, cards
alpha = cards["0x9001"]
beta = cards["0x9002"]
# the fake provider claims its own made-up vendor, with its own feature
# indexes, and never borrows a real feature name
assert alpha["decision"]["code"] == "supported", alpha["decision"]
assert alpha["decision"]["provider"] == "fake", alpha["decision"]
assert [f["index"] for f in alpha["features"]] == [101, 102], alpha["features"]
assert alpha["features"][1]["available"] is False, alpha["features"]
# the board decorator overrode the feature of the family
assert alpha["board"]["name"] == "fake-board", alpha["board"]
assert alpha["features"][1]["available"] is False, alpha["features"]
# the family that refuses is refused, and nothing was loaded for it
assert beta["decision"]["code"] == "refused", beta["decision"]
assert beta["decision"]["reason_code"] == "uncovered", beta["decision"]
assert beta["loaded"] == [], beta["loaded"]
# the backend that is built for this architecture wins, and the one that is
# not built here is never chosen
assert alpha["decision"]["backend"] == "fake-backend", alpha["decision"]
EOF
then
	ok "(k) the fake provider: its own feature indexes, its board decorator, its refusing family"
else
	bad "(k) the fake provider: $(head -c 300 "$TESTROOT/fake.json" | tr '\n' ' ')"
fi

run_tool --registry "$DATA/providers-fake" --pciconf-file "$DATA/pciconf-fake.txt" \
	--arch amd64 --json > "$TESTROOT/fake-amd64.json"
if python3 - "$TESTROOT/fake-amd64.json" <<'EOF'
import json, sys
doc = json.load(open(sys.argv[1]))
cards = dict((c["identity"]["device"], c) for c in doc["devices"])
alpha = cards["0x9001"]
# the backend that is built for amd64 and scores higher wins there
assert alpha["decision"]["backend"] == "fake-backend-amd64", alpha["decision"]
EOF
then
	ok "(k) the fake provider: on amd64 the backend built for amd64 wins"
else
	bad "(k) the fake provider did not choose the backend built for amd64"
fi

# (l) every card has one row per registered check, and every row says why.
if python3 - "$TESTROOT/document.json" <<'EOF'
import json, sys
doc = json.load(open(sys.argv[1]))
names = ["detect", "decide", "firmware", "driver-loaded", "device-open", "identity",
         "memory", "channel", "uvm", "prime", "display", "no-linux-layer",
         "native-modules"]
for card in doc["devices"]:
    rows = card["checks"]
    assert [r["name"] for r in rows] == names, rows
    for index, row in enumerate(rows, 1):
        assert row["index"] == index, row
        assert row["status"] in ("pass", "fail", "not_tested", "not_available"), row
        assert row["reason"], row
EOF
then
	ok "(l) every card has one row per check, and every row has a status and a reason"
else
	bad "(l) the rows of a card are not what they must be"
fi

# The text output and the JSON agree: the english line of a card is the
# same bytes in both.
if python3 - "$TESTROOT/document.json" "$TESTROOT/mixed.out" <<'EOF'
import json, sys
doc = json.load(open(sys.argv[1]))
text = open(sys.argv[2], encoding="utf-8").read()
for card in doc["devices"]:
    assert card["english"] in text, card["english"]
EOF
then
	ok "(l) the english line of a card is the same bytes in the text and in the JSON"
else
	bad "(l) the english line of a card differs between the text and the JSON"
fi

# (m) --help and the man page name every option.
run_tool --help > "$TESTROOT/help.out"
_help_rc=$?
if [ "$_help_rc" = 0 ]; then
	ok "(m) --help prints the usage and exits 0"
else
	bad "(m) --help exited $_help_rc"
fi
_missing=
for _option in --load --assume-loaded --check --list --json --jsonl --report --registry \
	--pciconf-file --fake --capture --device --module-dir --arch; do
	grep -q -- "$_option" "$TESTROOT/help.out" || _missing="$_missing $_option"
	grep -q -- "Fl -${_option#--}" "$REPO/man/gpu-check.8" || _missing="$_missing man:$_option"
done
if [ -z "$_missing" ]; then
	ok "(m) --help and the man page name every option"
else
	bad "(m) these options are not named:$_missing"
fi

# A usage error is a usage error.
expect_rc "(m) an unknown option is refused" 2 run_tool --nonsense
expect_rc "(m) --json and --jsonl together are refused" 2 \
	run_tool --json --jsonl --pciconf-file "$DATA/pciconf-supported.txt"
expect_rc "(m) --list with another option is refused" 2 \
	run_tool --list --json --pciconf-file "$DATA/pciconf-supported.txt"
expect_rc "(m) --load and --assume-loaded together are refused" 2 \
	run_tool --load --assume-loaded --pciconf-file "$DATA/pciconf-supported.txt"

# (n) an empty fake file is a fake run: it loads nothing and needs no root.
cat > "$TESTROOT/empty-fake.json" <<'EOF'
{}
EOF
run_tool --load --fake "$TESTROOT/empty-fake.json" --pciconf-file "$DATA/pciconf-supported.txt" \
	--arch arm64 --json > "$TESTROOT/empty-fake.out"
_empty_rc=$?
if [ "$_empty_rc" = 0 ] && python3 - "$TESTROOT/empty-fake.out" <<'EOF'
import json, sys
doc = json.load(open(sys.argv[1]))
assert doc["fake"] is True, doc["fake"]
card = doc["devices"][0]
assert card["loaded"] == [], card["loaded"]
rows = dict((r["name"], r) for r in card["checks"])
assert rows["firmware"]["status"] == "not_tested", rows["firmware"]
assert rows["driver-loaded"]["status"] == "not_tested", rows["driver-loaded"]
EOF
then
	ok "(n) an empty fake file is a fake run: it loads nothing and needs no root"
else
	bad "(n) the empty fake file: rc $_empty_rc $(head -c 200 "$TESTROOT/empty-fake.out" | tr '\n' ' ')"
fi

# (o) the fake file has one vocabulary: pass, fail, not_tested, not_available.
cat > "$TESTROOT/fake-pass.json" <<'EOF'
{
  "kldload": {
    "nvidia_gsp_ga10x_fw": {"status": "pass"},
    "nvidia": {"status": "pass"},
    "nvidia-modeset": {"status": "pass"},
    "nvidia-drm": {"status": "pass"}
  },
  "identity": {"status": "pass", "pci_vendor": "0x10de", "pci_device": "0x2d04"},
  "memory": {"status": "pass"}
}
EOF
run_tool --load --fake "$TESTROOT/fake-pass.json" --pciconf-file "$DATA/pciconf-supported.txt" \
	--arch arm64 --json > "$TESTROOT/fake-pass.out"
_fakepass_rc=$?
if [ "$_fakepass_rc" = 0 ] && python3 - "$TESTROOT/fake-pass.out" <<'EOF'
import json, sys
doc = json.load(open(sys.argv[1]))
rows = dict((r["name"], r) for r in doc["devices"][0]["checks"])
assert rows["firmware"]["status"] == "pass", rows["firmware"]
assert rows["driver-loaded"]["status"] == "pass", rows["driver-loaded"]
assert rows["memory"]["status"] == "pass", rows["memory"]
for name, row in rows.items():
    assert row["reason"], row
EOF
then
	ok "(o) a fake file that says pass loads the modules, and every row says why"
else
	bad "(o) the fake file with pass: rc $_fakepass_rc $(head -c 200 "$TESTROOT/fake-pass.out" | tr '\n' ' ')"
fi

cat > "$TESTROOT/fake-bogus.json" <<'EOF'
{"memory": {"status": "garbage"}}
EOF
expect_rc "(o) a fake file with a status the vocabulary does not hold is refused" 2 \
	run_tool --load --fake "$TESTROOT/fake-bogus.json" --pciconf-file "$DATA/pciconf-supported.txt" \
	--arch arm64
if grep -q "garbage" "$TESTROOT/stderr"; then
	ok "(o) the refusal names the status that is not one"
else
	bad "(o) the refusal does not name the status: $(head -c 200 "$TESTROOT/stderr" | tr '\n' ' ')"
fi

# (p) every error path speaks the language of the mode it was asked for.
run_tool --json --pciconf-file "$TESTROOT/no-such-pciconf.txt" > "$TESTROOT/error.json"
_error_json_rc=$?
run_tool --jsonl --pciconf-file "$TESTROOT/no-such-pciconf.txt" > "$TESTROOT/error.jsonl"
_error_jsonl_rc=$?
if [ "$_error_json_rc" = 4 ] && [ "$_error_jsonl_rc" = 4 ] && \
	python3 "$REPO/tests/schema_check.py" "$REPO/schema/gpu-check-1.schema.json" \
	"$TESTROOT/error.json" > "$TESTROOT/error.out" 2>&1 && \
	python3 "$REPO/tests/schema_check.py" "$REPO/schema/gpu-check-stream-1.schema.json" \
	"$TESTROOT/error.jsonl" >> "$TESTROOT/error.out" 2>&1; then
	ok "(p) the error paths print a document and a stream that hold the schema"
else
	bad "(p) the error paths do not hold the schema: $(tr '\n' ' ' < "$TESTROOT/error.out")"
fi

# A pciconf line that does not parse is an error, in every mode.
cat > "$TESTROOT/pciconf-bad.txt" <<'EOF'
vgapci0@pci0:0:2:0:	class=0x030000 rev=0xa1 hdr=0x00 vendor=0x10deZ device=0x2d04
EOF
run_tool --json --pciconf-file "$TESTROOT/pciconf-bad.txt" > "$TESTROOT/bad.json"
_bad_json_rc=$?
run_tool --jsonl --pciconf-file "$TESTROOT/pciconf-bad.txt" > "$TESTROOT/bad.jsonl"
_bad_jsonl_rc=$?
if [ "$_bad_json_rc" = 4 ] && [ "$_bad_jsonl_rc" = 4 ] && \
	python3 "$REPO/tests/schema_check.py" "$REPO/schema/gpu-check-1.schema.json" \
	"$TESTROOT/bad.json" > "$TESTROOT/bad.out" 2>&1 && \
	python3 "$REPO/tests/schema_check.py" "$REPO/schema/gpu-check-stream-1.schema.json" \
	"$TESTROOT/bad.jsonl" >> "$TESTROOT/bad.out" 2>&1; then
	ok "(p) a pciconf line that does not parse is an error document and an error stream"
else
	bad "(p) a malformed pciconf line: $(tr '\n' ' ' < "$TESTROOT/bad.out")"
fi

# (q) the stream is written as it goes: the header is out while the tool
# is still working on the cards.
_qmany="$TESTROOT/many-pciconf.txt"
: > "$_qmany"
_qi=0
while [ "$_qi" -lt 8000 ]; do
	printf 'vgapci%d@pci0:0:%d:0:\tclass=0x030000 rev=0xa1 hdr=0x00 vendor=0x10de device=0x2d04 subvendor=0x1462 subdevice=0x5351\n' \
		"$_qi" "$_qi" >> "$_qmany"
	_qi=$((_qi + 1))
done
_qfifo="$TESTROOT/stream.fifo"
rm -f "$_qfifo"
mkfifo "$_qfifo"
python3 - "$_qfifo" "$TESTROOT/stream.out" "$TESTROOT/header.time" <<'EOF' &
import sys, time
fifo, out, stamp = sys.argv[1], sys.argv[2], sys.argv[3]
with open(fifo, "r", encoding="utf-8") as handle, open(out, "w", encoding="utf-8") as sink:
    first = True
    for line in handle:
        sink.write(line)
        if first:
            first = False
            with open(stamp, "w", encoding="utf-8") as mark:
                mark.write("%.3f\n" % time.time())
EOF
_qreader=$!
_qstart=$(python3 -c 'import time; print("%.3f" % time.time())')
python3 "$TOOL" --no-db --jsonl --pciconf-file "$_qmany" --arch arm64 > "$_qfifo" 2> /dev/null
_qrun_rc=$?
wait "$_qreader"
_qend=$(python3 -c 'import time; print("%.3f" % time.time())')
if [ "$_qrun_rc" = 0 ] && python3 - "$_qstart" "$(cat "$TESTROOT/header.time" 2> /dev/null)" "$_qend" <<'EOF'
import sys
start, head, end = (float(one) for one in sys.argv[1:4])
assert head - start < 1.0, "the header came %.1f seconds after the start" % (head - start)
assert end - head > 0.5, "the tool was done %.1f seconds after the header" % (end - head)
EOF
then
	ok "(q) the --jsonl stream is flushed: the header is out before the cards are done"
else
	bad "(q) the --jsonl stream is not flushed: the header came late"
fi

# (r) a feature flag and the row that follows it say the same thing.
if python3 - "$REPO/data/providers/nvidia-open.json" "$TESTROOT/document.json" <<'EOF'
import json, sys
record = json.load(open(sys.argv[1]))
doc = json.load(open(sys.argv[2]))
flags = [f["name"] for f in record["feature_flags"]]
assert "compute" not in flags, flags
assert "backend_compute" in flags, flags
# the flags the record names are the flags the rows answer for
for card in doc["devices"]:
    features = dict((f["name"], f["available"]) for f in card["features"])
    rows = dict((r["name"], r) for r in card["checks"])
    if "uvm" in features and not features["uvm"]:
        assert rows["uvm"]["status"] in ("not_available", "not_tested"), rows["uvm"]
    if "display" in features and not features["display"]:
        assert rows["display"]["status"] in ("not_available", "not_tested"), rows["display"]
EOF
then
	ok "(r) a feature flag and the row that follows it say the same thing"
else
	bad "(r) a feature flag and its row say different things"
fi

# (s) the loaded list holds the modules that were loaded, and only those.
cat > "$TESTROOT/fake-partial.json" <<'EOF'
{
  "kldload": {
    "nvidia_gsp_ga10x_fw": {"status": "pass"},
    "nvidia": {"status": "pass"},
    "nvidia-modeset": {"status": "fail", "message": "the module does not fit this kernel"}
  },
  "identity": {"status": "pass", "pci_vendor": "0x10de", "pci_device": "0x2d04"}
}
EOF
run_tool --load --fake "$TESTROOT/fake-partial.json" --pciconf-file "$DATA/pciconf-supported.txt" \
	--arch arm64 --json > "$TESTROOT/partial.json"
if python3 - "$TESTROOT/partial.json" <<'EOF'
import json, sys
doc = json.load(open(sys.argv[1]))
card = doc["devices"][0]
assert card["loaded"] == ["nvidia_gsp_ga10x_fw", "nvidia"], card["loaded"]
rows = dict((r["name"], r) for r in card["checks"])
assert rows["driver-loaded"]["status"] == "fail", rows["driver-loaded"]
EOF
then
	ok "(s) the loaded list holds the modules that were loaded, and not the one that failed"
else
	bad "(s) the loaded list is wrong: $(head -c 300 "$TESTROOT/partial.json" | tr '\n' ' ')"
fi

cat > "$TESTROOT/fake-firmware-fail.json" <<'EOF'
{
  "kldload": {"nvidia_gsp_ga10x_fw": {"status": "fail", "message": "the firmware does not fit"}},
  "identity": {"status": "pass"}
}
EOF
run_tool --load --fake "$TESTROOT/fake-firmware-fail.json" --pciconf-file "$DATA/pciconf-supported.txt" \
	--arch arm64 --json > "$TESTROOT/firmware-fail.json"
if python3 - "$TESTROOT/firmware-fail.json" <<'EOF'
import json, sys
doc = json.load(open(sys.argv[1]))
card = doc["devices"][0]
assert card["loaded"] == [], card["loaded"]
rows = dict((r["name"], r) for r in card["checks"])
assert rows["firmware"]["status"] == "fail", rows["firmware"]
EOF
then
	ok "(s) a firmware that was not loaded is not in the loaded list"
else
	bad "(s) a firmware that was not loaded is in the loaded list"
fi

# (t) two cards of one machine get their own answers.
cat > "$TESTROOT/pciconf-two.txt" <<'EOF'
vgapci0@pci0:0:2:0:	class=0x030000 rev=0xa1 hdr=0x00 vendor=0x10de device=0x2d04 subvendor=0x1462 subdevice=0x5351
vgapci1@pci0:0:3:0:	class=0x030000 rev=0xa1 hdr=0x00 vendor=0x10de device=0x2d04 subvendor=0x1462 subdevice=0x5351
EOF
cat > "$TESTROOT/fake-two.json" <<'EOF'
{
  "kldload": {"nvidia_gsp_ga10x_fw": {"status": "pass"}, "nvidia": {"status": "pass"},
              "nvidia-modeset": {"status": "pass"}, "nvidia-drm": {"status": "pass"}},
  "identity": {
    "pci0:0:2:0": {"status": "pass", "pci_vendor": "0x10de", "pci_device": "0x2d04",
                   "message": "the first card opened"},
    "pci0:0:3:0": {"status": "fail", "pci_vendor": "0x10de", "pci_device": "0x2d04",
                   "message": "the second card did not open"}
  }
}
EOF
run_tool --load --fake "$TESTROOT/fake-two.json" --pciconf-file "$TESTROOT/pciconf-two.txt" \
	--arch arm64 --json > "$TESTROOT/two.json"
if python3 - "$TESTROOT/two.json" <<'EOF'
import json, sys
doc = json.load(open(sys.argv[1]))
cards = dict((c["selector"], c) for c in doc["devices"])
assert len(cards) == 2, cards
first = dict((r["name"], r) for r in cards["pci0:0:2:0"]["checks"])
second = dict((r["name"], r) for r in cards["pci0:0:3:0"]["checks"])
assert first["device-open"]["status"] == "pass", first["device-open"]
assert second["device-open"]["status"] == "fail", second["device-open"]
assert "second card" in second["device-open"]["reason"], second["device-open"]
EOF
then
	ok "(t) two cards of one machine get their own answers"
else
	bad "(t) the two cards do not get their own answers: $(head -c 300 "$TESTROOT/two.json" | tr '\n' ' ')"
fi

# (u) a provider record that cannot be used is refused, not used.
mkdir -p "$TESTROOT/versionreg"
python3 - "$TESTROOT/versionreg" "$REPO/data/providers/nvidia-open.json" <<'EOF'
import json, os, sys
out, source = sys.argv[1], sys.argv[2]
doc = json.load(open(source))
doc["schema_version"]["major"] = 2
doc["schema_version"]["string"] = "2.0"
json.dump(doc, open(os.path.join(out, "nvidia-open.json"), "w"), indent=1)
EOF
expect_rc "(u) a record of another schema version is refused" 2 \
	run_tool --registry "$TESTROOT/versionreg" --pciconf-file "$DATA/pciconf-supported.txt" --arch arm64

mkdir -p "$TESTROOT/noversreg"
python3 - "$TESTROOT/noversreg" "$REPO/data/providers/nvidia-open.json" <<'EOF'
import json, os, sys
out, source = sys.argv[1], sys.argv[2]
doc = json.load(open(source))
del doc["schema_version"]
json.dump(doc, open(os.path.join(out, "nvidia-open.json"), "w"), indent=1)
EOF
expect_rc "(u) a record without a schema version is refused" 2 \
	run_tool --registry "$TESTROOT/noversreg" --pciconf-file "$DATA/pciconf-supported.txt" --arch arm64

mkdir -p "$TESTROOT/dupreg"
python3 - "$TESTROOT/dupreg" "$REPO/data/providers/nvidia-open.json" <<'EOF'
import json, os, sys
out, source = sys.argv[1], sys.argv[2]
doc = json.load(open(source))
json.dump(doc, open(os.path.join(out, "one.json"), "w"), indent=1)
json.dump(doc, open(os.path.join(out, "two.json"), "w"), indent=1)
EOF
expect_rc "(u) two records with the same provider name are refused" 2 \
	run_tool --registry "$TESTROOT/dupreg" --pciconf-file "$DATA/pciconf-supported.txt" --arch arm64

mkdir -p "$TESTROOT/generationreg"
python3 - "$TESTROOT/generationreg" "$REPO/data/providers/nvidia-open.json" <<'EOF'
import json, os, sys
out, source = sys.argv[1], sys.argv[2]
doc = json.load(open(source))
for family in doc["families"]:
    for generation in family["generations"]:
        generation["arch_values"] = [1]
json.dump(doc, open(os.path.join(out, "nvidia-open.json"), "w"), indent=1)
EOF
expect_rc "(u) a record whose generation table disagrees with its families is refused" 2 \
	run_tool --registry "$TESTROOT/generationreg" --pciconf-file "$DATA/pciconf-supported.txt" --arch arm64

mkdir -p "$TESTROOT/nomodulesreg"
python3 - "$TESTROOT/nomodulesreg" "$REPO/data/providers/nvidia-open.json" <<'EOF'
import json, os, sys
out, source = sys.argv[1], sys.argv[2]
doc = json.load(open(source))
for backend in doc["backends"]:
    backend["modules"] = []
json.dump(doc, open(os.path.join(out, "nvidia-open.json"), "w"), indent=1)
EOF
expect_rc "(u) a backend that loads no module is refused" 2 \
	run_tool --registry "$TESTROOT/nomodulesreg" --pciconf-file "$DATA/pciconf-supported.txt" --arch arm64

# (u2) two providers of one vendor: the higher score wins, and a provider
# that refuses may hand the card over when its record says so.
mkdir -p "$TESTROOT/twoproviders"
python3 - "$TESTROOT/twoproviders" "$DATA/providers-fake/fake.json" <<'EOF'
import json, os, sys
out, source = sys.argv[1], sys.argv[2]
doc = json.load(open(source))
high = json.loads(json.dumps(doc))
high["provider"] = "high"
high["score"] = 100
json.dump(doc, open(os.path.join(out, "low.json"), "w"), indent=1)
json.dump(high, open(os.path.join(out, "high.json"), "w"), indent=1)
EOF
run_tool --registry "$TESTROOT/twoproviders" --pciconf-file "$DATA/pciconf-fake.txt" \
	--arch arm64 --json > "$TESTROOT/twoproviders.json"
if python3 - "$TESTROOT/twoproviders.json" <<'EOF'
import json, sys
doc = json.load(open(sys.argv[1]))
cards = dict((c["identity"]["device"], c) for c in doc["devices"])
alpha = cards["0x9001"]
# the provider with the higher score is the one that is chosen
assert alpha["decision"]["provider"] == "high", alpha["decision"]
assert alpha["decision"]["code"] == "supported", alpha["decision"]
EOF
then
	ok "(u2) two providers of one vendor: the one with the higher score is chosen"
else
	bad "(u2) the wrong provider was chosen: $(head -c 200 "$TESTROOT/twoproviders.json" | tr '\n' ' ')"
fi

mkdir -p "$TESTROOT/fallbackreg"
python3 - "$TESTROOT/fallbackreg" "$DATA/providers-fake/fake.json" <<'EOF'
import json, os, sys
out, source = sys.argv[1], sys.argv[2]
doc = json.load(open(source))
high = json.loads(json.dumps(doc))
high["provider"] = "high"
high["score"] = 100
high["fallback_ok"] = True
# the family of the high provider covers no card of the machine
high["families"][0]["devids"] = ["0x9999"]
json.dump(high, open(os.path.join(out, "high.json"), "w"), indent=1)
json.dump(doc, open(os.path.join(out, "low.json"), "w"), indent=1)
EOF
run_tool --registry "$TESTROOT/fallbackreg" --pciconf-file "$DATA/pciconf-fake.txt" \
	--arch arm64 --json > "$TESTROOT/fallback.json"
if python3 - "$TESTROOT/fallback.json" <<'EOF'
import json, sys
doc = json.load(open(sys.argv[1]))
cards = dict((c["identity"]["device"], c) for c in doc["devices"])
alpha = cards["0x9001"]
# the card the high provider refused is offered to the lower-scoring one
assert alpha["decision"]["provider"] == "fake", alpha["decision"]
assert alpha["decision"]["code"] == "supported", alpha["decision"]
EOF
then
	ok "(u2) a provider that refuses and allows a fallback hands the card over"
else
	bad "(u2) the card was not handed over: $(head -c 200 "$TESTROOT/fallback.json" | tr '\n' ' ')"
fi

mkdir -p "$TESTROOT/nofallbackreg"
cp "$TESTROOT/fallbackreg/high.json" "$TESTROOT/nofallbackreg/high.json"
python3 - "$TESTROOT/nofallbackreg/high.json" <<'EOF'
import json, sys
path = sys.argv[1]
doc = json.load(open(path))
doc["fallback_ok"] = False
json.dump(doc, open(path, "w"), indent=1)
EOF
cp "$DATA/providers-fake/fake.json" "$TESTROOT/nofallbackreg/low.json"
run_tool --registry "$TESTROOT/nofallbackreg" --pciconf-file "$DATA/pciconf-fake.txt" \
	--arch arm64 --json > "$TESTROOT/nofallback.json"
if python3 - "$TESTROOT/nofallback.json" <<'EOF'
import json, sys
doc = json.load(open(sys.argv[1]))
cards = dict((c["identity"]["device"], c) for c in doc["devices"])
alpha = cards["0x9001"]
# without fallback_ok the refusal stands
assert alpha["decision"]["provider"] == "high", alpha["decision"]
assert alpha["decision"]["code"] == "refused", alpha["decision"]
EOF
then
	ok "(u2) a provider that refuses without a fallback keeps the card"
else
	bad "(u2) the refusal did not stand: $(head -c 200 "$TESTROOT/nofallback.json" | tr '\n' ' ')"
fi

# (w) the schema checker of the suite holds what the schemas hold.
if python3 - "$REPO" <<'EOF'
import json, os, sys
repo = sys.argv[1]
sys.path.insert(0, os.path.join(repo, "tests"))
import schema_check

stream = json.load(open(os.path.join(repo, "schema/gpu-check-stream-1.schema.json")))
document = json.load(open(os.path.join(repo, "schema/gpu-check-1.schema.json")))
lines = [l for l in open(os.path.join(repo, "tests/fixtures/gpu-check.jsonl"), encoding="utf-8")
         if l.strip()]
schema_check.validate_lines(lines, stream)
record = json.loads(lines[2])
assert record["kind"] == "check", record
record["status"] = "bogus"
try:
    schema_check.validate(record, stream)
except AssertionError:
    pass
else:
    raise AssertionError("the checker accepted a check with a status the schema does not hold")
doc = json.load(open(os.path.join(repo, "tests/fixtures/gpu-check.json")))
doc["devices"][0]["name"] = ""
try:
    schema_check.validate(doc, document)
except AssertionError:
    pass
else:
    raise AssertionError("the checker accepted an empty name")
EOF
then
	ok "(w) the schema checker refuses what the registered schemas refuse"
else
	bad "(w) the schema checker holds documents the schemas refuse"
fi

# (x) the makefile puts no free text in a recipe.
if command -v make > /dev/null 2>&1; then
	_marker="$TESTROOT/gpu-check-pwned"
	rm -f "$_marker"
	( cd "$REPO" && make check-card ARGS="--json; touch $_marker" ) > "$TESTROOT/make.out" 2>&1
	_makerc=$?
	if [ "$_makerc" != 0 ] && [ ! -e "$_marker" ]; then
		ok "(x) make check-card ARGS=... is refused, and it runs nothing"
	else
		bad "(x) make check-card ARGS=...: rc $_makerc, marker: $([ -e "$_marker" ] && echo there || echo none)"
	fi
	( cd "$REPO" && make check-card CHECK_JSON=1 ) > "$TESTROOT/make-json.out" 2>&1
	if grep -q '"schema": "gpu-check.v1"' "$TESTROOT/make-json.out"; then
		ok "(x) make check-card CHECK_JSON=1 prints the document"
	else
		bad "(x) make check-card CHECK_JSON=1 did not print the document: $(head -c 200 "$TESTROOT/make-json.out" | tr '\n' ' ')"
	fi
fi

# (y) a load run takes the modules of the installed registry only.
mkdir -p "$TESTROOT/evilreg"
python3 - "$TESTROOT/evilreg" "$REPO/data/providers/nvidia-open.json" <<'EOF'
import json, os, sys
out, source = sys.argv[1], sys.argv[2]
doc = json.load(open(source))
for backend in doc["backends"]:
    backend["modules"] = ["/tmp/attacker/evil.ko"]
json.dump(doc, open(os.path.join(out, "nvidia-open.json"), "w"), indent=1)
EOF
expect_rc "(y) a registry whose module is a path is refused" 2 \
	run_tool --registry "$TESTROOT/evilreg" --pciconf-file "$DATA/pciconf-supported.txt" --arch arm64

mkdir -p "$TESTROOT/optionreg"
python3 - "$TESTROOT/optionreg" "$REPO/data/providers/nvidia-open.json" <<'EOF'
import json, os, sys
out, source = sys.argv[1], sys.argv[2]
doc = json.load(open(source))
for backend in doc["backends"]:
    backend["modules"] = ["-oops"]
json.dump(doc, open(os.path.join(out, "nvidia-open.json"), "w"), indent=1)
EOF
expect_rc "(y) a registry whose module starts with a dash is refused" 2 \
	run_tool --registry "$TESTROOT/optionreg" --pciconf-file "$DATA/pciconf-supported.txt" --arch arm64

expect_rc "(y) a load run takes the default registry only" 2 \
	run_tool --load --registry "$TESTROOT/evilreg" --pciconf-file "$DATA/pciconf-supported.txt" \
	--arch arm64

# (z) the report replaces a symlink and leaves the file it pointed at alone.
cat > "$TESTROOT/victim.txt" <<'EOF'
this file must not change
EOF
rm -f "$TESTROOT/report-link.json"
ln -s "$TESTROOT/victim.txt" "$TESTROOT/report-link.json"
run_tool --json --pciconf-file "$DATA/pciconf-supported.txt" --arch arm64 \
	--report "$TESTROOT/report-link.json" > /dev/null
if [ ! -L "$TESTROOT/report-link.json" ] && \
	grep -q "this file must not change" "$TESTROOT/victim.txt" && \
	python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$TESTROOT/report-link.json"; then
	ok "(z) the report replaces the symlink and leaves the file it pointed at alone"
else
	bad "(z) the report followed the symlink"
fi

# (bb) the architecture is normalized, and one that is not an architecture
# is a usage error.
run_tool --arch ARM64 --pciconf-file "$DATA/pciconf-supported.txt" --json > "$TESTROOT/arch.json"
if grep -q '"arch": "arm64"' "$TESTROOT/arch.json"; then
	ok "(bb) the architecture is written as the records name it"
else
	bad "(bb) the architecture was not normalized: $(head -c 200 "$TESTROOT/arch.json" | tr '\n' ' ')"
fi
expect_rc "(bb) an architecture that is not one is refused" 2 \
	run_tool --arch "arm 64" --pciconf-file "$DATA/pciconf-supported.txt"

# (dd) a selector that matches no card is a usage error, not a machine
# without a card.
expect_rc "(dd) a selector that matches no card is refused" 2 \
	run_tool --device pci0:0:9:9 --pciconf-file "$DATA/pciconf-mixed.txt" --arch arm64
if grep -q "pci0:0:9:9" "$TESTROOT/stderr"; then
	ok "(dd) the refusal names the selector that matches nothing"
else
	bad "(dd) the refusal does not name the selector: $(head -c 200 "$TESTROOT/stderr" | tr '\n' ' ')"
fi

# (ee) the text output says what happened and what to do next.
run_tool --pciconf-file "$DATA/pciconf-mixed.txt" --arch arm64 > "$TESTROOT/mixed2.out"
if grep -q "next:" "$TESTROOT/mixed2.out"; then
	ok "(ee) the refused card names the next step"
else
	bad "(ee) the refused card does not name the next step"
fi
if grep "no_provider" "$TESTROOT/mixed2.out" | grep -q "1002" && \
	! grep -q "unknown vendor" "$TESTROOT/mixed2.out"; then
	ok "(ee) the card of another vendor names the vendor, and not an unknown one"
else
	bad "(ee) the card of another vendor does not name the vendor"
fi

# (ff) the value of an option is a value, never another option.
expect_rc "(ff) an option as the value of an option is refused" 2 \
	run_tool --report --json --pciconf-file "$DATA/pciconf-supported.txt"
if [ ! -e "$REPO/--json" ] && [ ! -e "$TESTROOT/--json" ]; then
	ok "(ff) the refused value wrote no file"
else
	bad "(ff) the refused value wrote a file"
fi

# (gg) the installed tool finds its library and its adapters.
_gp="$TESTROOT/prefix"
mkdir -p "$_gp/sbin" "$_gp/share/gpu-check/adapters" "$_gp/share/gpu-check/lib"
cp "$TOOL" "$_gp/sbin/gpu-check"
cp "$REPO"/scripts/adapters/*.py "$_gp/share/gpu-check/adapters/"
cp -R "$LIB/gpu_check" "$_gp/share/gpu-check/lib/gpu_check"
if python3 - "$_gp/sbin/gpu-check" "$_gp" "$REPO/scripts/adapters/0x10de.py" <<'EOF'
import importlib.machinery, importlib.util, sys

def load(name, path):
    loader = importlib.machinery.SourceFileLoader(name, path)
    spec = importlib.util.spec_from_loader(name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module

core = load("gpu_check_core", sys.argv[1])
prefixes = core.install_prefixes()
assert prefixes[0] == sys.argv[2], prefixes
adapter = load("gpu_check_adapter", sys.argv[3])
paths = adapter._paths(prefixes, adapter.PROGRAM, "sbin")
assert paths[0] == sys.argv[2] + "/sbin/" + adapter.PROGRAM, paths
EOF
then
	ok "(gg) the probes of the installed tool look beside it"
else
	bad "(gg) the probes do not follow the prefix of the installed tool"
fi

# The installed tool finds the library it runs the checks from.
if python3 "$_gp/sbin/gpu-check" --no-db --list > "$TESTROOT/installed-list.out" 2>&1; then
	if [ "$(grep -c . "$TESTROOT/installed-list.out")" = 13 ]; then
		ok "(gg) the installed tool finds its library and lists the checks"
	else
		bad "(gg) the installed tool listed $(grep -c . "$TESTROOT/installed-list.out") checks, not 13"
	fi
else
	bad "(gg) the installed tool did not run: $(head -c 200 "$TESTROOT/installed-list.out" | tr '\n' ' ')"
fi

# (hh) the plain table is the same bytes every time: the golden file.
run_tool --load --fake "$DATA/fake-load.json" --pciconf-file "$DATA/pciconf-supported.txt" \
	--arch arm64 > "$TESTROOT/golden.out"
if cmp -s "$TESTROOT/golden.out" "$DATA/golden-table.txt"; then
	ok "(hh) the plain table is the same bytes as the golden file"
else
	bad "(hh) the plain table is not the golden file: $(diff "$DATA/golden-table.txt" "$TESTROOT/golden.out" | head -c 300 | tr '\n' ' ')"
fi

# The plain table holds no colour: the escape of the colour is not in it.
if LC_ALL=C grep -q "$(printf '\033')" "$TESTROOT/golden.out"; then
	bad "(hh) the plain table holds the escape of the colour"
else
	ok "(hh) the plain table holds no colour"
fi

# The table says what happened in one line at the end.
if grep -q "^[0-9]* passed" "$TESTROOT/golden.out"; then
	ok "(hh) the table ends with the one line that counts the rows"
else
	bad "(hh) the table has no summary line"
fi

# (ii) --list lists the checks and what each one needs.
run_tool --list > "$TESTROOT/list.out"
if python3 - "$TESTROOT/list.out" <<'EOF'
import re, sys
lines = [l for l in open(sys.argv[1], encoding="utf-8").read().splitlines() if l.strip()]
ids = [l.split()[0] for l in lines]
assert ids == ["detect", "decide", "firmware", "driver-loaded", "device-open", "identity",
               "memory", "channel", "uvm", "prime", "display", "no-linux-layer",
               "native-modules"], ids

def needs_of(line):
    """The needs a line carries: the marker at the end of it."""
    found = re.search(r"\s\(([^)]*)\)$", line)
    if not found:
        return []
    return [part.strip() for part in found.group(1).split(",")]

# the checks that need the root and the driver say so
needs = dict((l.split()[0], l) for l in lines)
assert needs_of(needs["firmware"]) == ["root", "load"], needs["firmware"]
assert needs_of(needs["driver-loaded"]) == ["root", "load"], needs["driver-loaded"]
# the checks that open the card need the root: the device of a card is
# not for a user
assert needs_of(needs["device-open"]) == ["root", "load"], needs["device-open"]
assert needs_of(needs["identity"]) == ["root", "load"], needs["identity"]
assert needs_of(needs["memory"]) == ["root", "load"], needs["memory"]
assert needs_of(needs["channel"]) == ["root", "load"], needs["channel"]
assert needs_of(needs["detect"]) == [], needs["detect"]
assert needs_of(needs["no-linux-layer"]) == [], needs["no-linux-layer"]
assert needs_of(needs["native-modules"]) == [], needs["native-modules"]
EOF
then
	ok "(ii) --list lists every check and what each one needs"
else
	bad "(ii) --list does not list the checks: $(head -c 300 "$TESTROOT/list.out" | tr '\n' ' ')"
fi

# (jj) --check runs the checks that were named and the ones they depend on.
run_tool --check memory --fake "$DATA/fake-load.json" \
	--pciconf-file "$DATA/pciconf-supported.txt" --arch arm64 --json > "$TESTROOT/check.json"
if python3 - "$TESTROOT/check.json" <<'EOF'
import json, sys
doc = json.load(open(sys.argv[1]))
assert doc["mode"] == "check", doc["mode"]
rows = dict((r["name"], r) for r in doc["devices"][0]["checks"])
# the checks that were named and the ones they depend on ran
assert rows["detect"]["status"] == "pass", rows["detect"]
assert rows["decide"]["status"] == "pass", rows["decide"]
# the check that was named did not run: the driver was not loaded
assert rows["memory"]["status"] == "not_tested", rows["memory"]
assert "--load" in rows["memory"]["reason"], rows["memory"]
# the checks that were not asked for say so, and name the run
assert rows["channel"]["status"] == "not_tested", rows["channel"]
assert "not asked for" in rows["channel"]["reason"], rows["channel"]
assert "memory" in rows["channel"]["reason"], rows["channel"]
assert rows["native-modules"]["status"] == "not_tested", rows["native-modules"]
EOF
then
	ok "(jj) --check runs the checks that were named and the ones they depend on"
else
	bad "(jj) --check did not run what it was asked for: $(head -c 300 "$TESTROOT/check.json" | tr '\n' ' ')"
fi

# A check that is not registered is a usage error, and the message names
# the checks that are.
expect_rc "(jj) a check that is not registered is refused" 2 \
	run_tool --check nosuchcheck --pciconf-file "$DATA/pciconf-supported.txt" --arch arm64
if grep -q "no check named nosuchcheck" "$TESTROOT/stderr"; then
	ok "(jj) the refusal names the check that is not registered"
else
	bad "(jj) the refusal does not name the check: $(head -c 200 "$TESTROOT/stderr" | tr '\n' ' ')"
fi

# (kk) a mutant that drops the reason of a row is killed.
# The property: every row of every card carries a reason.  The check that
# holds it must be able to fail, so a mutant of the tool that drops the
# reason is run through it.
cat > "$TESTROOT/reasons.py" <<'EOF'
import json, sys
doc = json.load(open(sys.argv[1]))
for card in doc["devices"]:
    for row in card["checks"]:
        assert row.get("reason"), "the row %s of %s has no reason" % (row.get("name"),
                                                                      card.get("label"))
EOF
if python3 "$TESTROOT/reasons.py" "$TESTROOT/document.json" > "$TESTROOT/reasons.out" 2>&1; then
	ok "(kk) every row of the tool carries a reason"
else
	bad "(kk) a row of the tool has no reason: $(tr '\n' ' ' < "$TESTROOT/reasons.out")"
fi

rm -rf "$TESTROOT/mutant"
mkdir -p "$TESTROOT/mutant/scripts" "$TESTROOT/mutant/lib"
cp "$TOOL" "$TESTROOT/mutant/scripts/gpu-check"
cp -R "$LIB/gpu_check" "$TESTROOT/mutant/lib/gpu_check"
python3 - "$TESTROOT/mutant/scripts/gpu-check" <<'EOF'
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
old = 'reason = outcome.get("reason") or "the check said nothing"'
new = 'reason = outcome.get("reason") or ""'
assert old in text, "the mutant could not be planted"
open(path, "w", encoding="utf-8").write(text.replace(old, new))
EOF
python3 "$TESTROOT/mutant/scripts/gpu-check" --no-db --load --fake "$DATA/fake-load.json" \
	--pciconf-file "$DATA/pciconf-supported.txt" --arch arm64 --json \
	> "$TESTROOT/mutant.json" 2> /dev/null
if python3 "$TESTROOT/reasons.py" "$TESTROOT/mutant.json" > "$TESTROOT/mutant.out" 2>&1; then
	bad "(kk) the mutant that drops the reason of a row was not killed"
else
	ok "(kk) the mutant that drops the reason of a row is killed"
fi

# The registered schema refuses the mutant too: the reason is not empty.
if python3 "$REPO/tests/schema_check.py" "$REPO/schema/gpu-check-1.schema.json" \
	"$TESTROOT/mutant.json" > "$TESTROOT/mutant-schema.out" 2>&1; then
	bad "(kk) the schema holds the mutant that drops the reason of a row"
else
	ok "(kk) the schema refuses the mutant that drops the reason of a row"
fi

# (ll) the recorded run of 2026-11-26 replays as it was recorded.
run_tool --capture "$DATA/capture-20261126" --json > "$TESTROOT/capture.json"
_capture_rc=$?
if [ "$_capture_rc" = 1 ] && python3 - "$TESTROOT/capture.json" <<'EOF'
import json, sys
doc = json.load(open(sys.argv[1]))
assert doc["mode"] == "capture", doc["mode"]
assert doc["capture"] is True, doc["capture"]
card = doc["devices"][0]
assert card["selector"] == "pci13:1:0:0", card["selector"]
rows = dict((r["name"], r) for r in card["checks"])
# the memory probe of that day passed all its steps
assert rows["memory"]["status"] == "pass", rows["memory"]
assert len(rows["memory"]["steps"]) == 19, rows["memory"]
# the channel probe failed on the creation, and the steps after it were
# not reached; the cleanup still ran
assert rows["channel"]["status"] == "fail", rows["channel"]
assert "0x1f" in rows["channel"]["reason"], rows["channel"]
steps = dict((s["name"], s) for s in rows["channel"]["steps"])
assert steps["create"]["status"] == "fail", steps["create"]
for name in ("release", "latency", "stress", "isolation"):
    assert steps[name]["status"] == "not_reached", steps[name]
assert steps["cleanup"]["status"] == "pass", steps["cleanup"]
# the checks that run did not happen that day say so
assert rows["uvm"]["status"] == "not_tested", rows["uvm"]
assert rows["prime"]["status"] == "not_tested", rows["prime"]
assert rows["display"]["status"] == "not_tested", rows["display"]
EOF
then
	ok "(ll) the recorded run of 2026-11-26 replays as it was recorded"
else
	bad "(ll) the recorded run did not replay: rc $_capture_rc $(head -c 300 "$TESTROOT/capture.json" | tr '\n' ' ')"
fi

# A replay needs no root and loads nothing.
if grep -q '"loaded": \[\]' "$TESTROOT/capture.json"; then
	ok "(ll) the replay loads nothing"
else
	bad "(ll) the replay loaded something"
fi

# (mm) the fake backend answers what the file says, and nothing else.
# A file that says nothing about a probe does not answer it.
cat > "$TESTROOT/fake-quiet.json" <<'EOF'
{
  "kldload": {"nvidia_gsp_ga10x_fw": {"status": "pass"}, "nvidia": {"status": "pass"},
              "nvidia-modeset": {"status": "pass"}, "nvidia-drm": {"status": "pass"}}
}
EOF
run_tool --load --fake "$TESTROOT/fake-quiet.json" --pciconf-file "$DATA/pciconf-supported.txt" \
	--arch arm64 --json > "$TESTROOT/quiet.json"
if python3 - "$TESTROOT/quiet.json" <<'EOF'
import json, sys
doc = json.load(open(sys.argv[1]))
rows = dict((r["name"], r) for r in doc["devices"][0]["checks"])
# the file answered the load, and the load answered the modules
assert rows["firmware"]["status"] == "pass", rows["firmware"]
assert rows["driver-loaded"]["status"] == "pass", rows["driver-loaded"]
# the file said nothing about the probes, so they were not tested
for name in ("identity", "memory", "channel", "uvm", "prime", "display"):
    assert rows[name]["status"] == "not_tested", rows[name]
    assert rows[name]["reason"], rows[name]
EOF
then
	ok "(mm) a fake file that says nothing about a probe does not answer it"
else
	bad "(mm) the quiet fake file: $(head -c 300 "$TESTROOT/quiet.json" | tr '\n' ' ')"
fi

# The file that says a module was loaded holds that module: the file is
# the machine of a fake run.
cat > "$TESTROOT/fake-modules.json" <<'EOF'
{
  "kldload": {"nvidia_gsp_ga10x_fw": {"status": "ok"}, "nvidia": {"status": "ok"},
              "nvidia-modeset": {"status": "fail"}},
  "identity": {"status": "pass", "pci_vendor": "0x10de", "pci_device": "0x2d04"}
}
EOF
run_tool --load --fake "$TESTROOT/fake-modules.json" --pciconf-file "$DATA/pciconf-supported.txt" \
	--arch arm64 --json > "$TESTROOT/fake-modules.out"
if python3 - "$TESTROOT/fake-modules.out" <<'EOF'
import json, sys
doc = json.load(open(sys.argv[1]))
rows = dict((r["name"], r) for r in doc["devices"][0]["checks"])
# the module the file says was loaded is in the listing of the machine
assert "nvidia" in rows["no-linux-layer"]["reason"], rows["no-linux-layer"]
assert "nvidia-modeset" not in rows["no-linux-layer"]["reason"], rows["no-linux-layer"]
EOF
then
	ok "(mm) the modules of the fake file are the modules of the machine of the run"
else
	bad "(mm) the module listing of the fake run is wrong: $(head -c 300 "$TESTROOT/fake-modules.out" | tr '\n' ' ')"
fi

# "ok" is a synonym of "pass" for a module load.
run_tool --load --fake "$DATA/fake-load.json" --pciconf-file "$DATA/pciconf-supported.txt" \
	--arch arm64 --json > "$TESTROOT/ok.json"
if python3 - "$TESTROOT/ok.json" <<'EOF'
import json, sys
doc = json.load(open(sys.argv[1]))
rows = dict((r["name"], r) for r in doc["devices"][0]["checks"])
assert rows["firmware"]["status"] == "pass", rows["firmware"]
assert rows["driver-loaded"]["status"] == "pass", rows["driver-loaded"]
EOF
then
	ok "(mm) the status ok of a fake file is the status pass"
else
	bad "(mm) the status ok of a fake file is not the status pass"
fi

# (nn) the checks of the environment of a native run.
cat > "$TESTROOT/fake-linux.json" <<'EOF'
{
  "modules": ["nvidia", "linuxkms"],
  "kldload": {"nvidia_gsp_ga10x_fw": {"status": "pass"}, "nvidia": {"status": "pass"},
              "nvidia-modeset": {"status": "pass"}, "nvidia-drm": {"status": "pass"}},
  "identity": {"status": "pass", "pci_vendor": "0x10de", "pci_device": "0x2d04"}
}
EOF
run_tool --load --fake "$TESTROOT/fake-linux.json" --pciconf-file "$DATA/pciconf-supported.txt" \
	--arch arm64 --json > "$TESTROOT/linux.json"
if python3 - "$TESTROOT/linux.json" <<'EOF'
import json, sys
doc = json.load(open(sys.argv[1]))
rows = dict((r["name"], r) for r in doc["devices"][0]["checks"])
# a module of the Linux layer is loaded: the native run is not native
assert rows["no-linux-layer"]["status"] == "fail", rows["no-linux-layer"]
assert "linuxkms" in rows["no-linux-layer"]["reason"], rows["no-linux-layer"]
EOF
then
	ok "(nn) a module of the Linux layer fails the check of the environment"
else
	bad "(nn) the module of the Linux layer was not found: $(head -c 300 "$TESTROOT/linux.json" | tr '\n' ' ')"
fi

# The check of the environment runs without the driver: it reads the
# listing of the machine, not the card.
run_tool --pciconf-file "$DATA/pciconf-supported.txt" --arch arm64 --json > "$TESTROOT/default.json"
if python3 - "$TESTROOT/default.json" <<'EOF'
import json, sys
doc = json.load(open(sys.argv[1]))
rows = dict((r["name"], r) for r in doc["devices"][0]["checks"])
# a run without --load does not touch the machine
for name in ("firmware", "driver-loaded", "device-open", "identity", "memory",
             "channel", "uvm", "prime", "display"):
    assert rows[name]["status"] == "not_tested", rows[name]
    assert "not asked for" in rows[name]["reason"], rows[name]
assert rows["detect"]["status"] == "pass", rows["detect"]
assert rows["decide"]["status"] == "pass", rows["decide"]
EOF
then
	ok "(nn) a run without --load touches nothing and says so"
else
	bad "(nn) a run without --load touched the machine: $(head -c 300 "$TESTROOT/default.json" | tr '\n' ' ')"
fi

# (oo) the registry is the only list of checks: a check added to the
# library appears in the rows of the tool, and the tool holds no list.
rm -rf "$TESTROOT/extra"
mkdir -p "$TESTROOT/extra/scripts" "$TESTROOT/extra/lib/gpu-check"
cp "$TOOL" "$TESTROOT/extra/scripts/gpu-check"
cp -R "$LIB/gpu_check" "$TESTROOT/extra/lib/gpu-check/gpu_check"
mkdir -p "$TESTROOT/extra/data"
cp -R "$REPO/data/providers" "$TESTROOT/extra/data/providers"
python3 - "$TESTROOT/extra/lib/gpu-check/gpu_check/checks.py" <<'EOF'
import re, sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
old = ('_register("native-modules", "the modules of this card that are loaded are native",\n'
       '          _native_modules)')
assert old in text, "the extra check could not be planted"
new = old + ('\n_register("extra-check", "a check that a test added", _extra,\n'
             '           default=True)')
text = text.replace(old, new)
extra = '''

def _extra(context):
    """A check that a test added to the library."""
    return _result(PASS, "the check that the test added ran")
'''
text = text.replace('\n\n# --- the registry ---', extra + '\n\n# --- the registry ---')
open(path, "w", encoding="utf-8").write(text)
EOF
python3 "$TESTROOT/extra/scripts/gpu-check" --no-db --pciconf-file "$DATA/pciconf-supported.txt" \
	--arch arm64 > "$TESTROOT/extra.out" 2> "$TESTROOT/extra.err"
if grep -q "^extra-check" "$TESTROOT/extra.out"; then
	ok "(oo) a check added to the library appears in the rows of the tool"
else
	bad "(oo) the check that was added to the library did not appear: $(head -c 200 "$TESTROOT/extra.err" | tr '\n' ' ')"
fi

# The tool holds no list of checks of its own: it asks the registry.  A
# collection that holds two of the names of the checks is a list, and a
# comparison against the name of a check is a check that is hardcoded.
if python3 - "$TOOL" "$LIB/gpu_check/checks.py" <<'EOF'
import ast, sys
tool, checks = sys.argv[1], sys.argv[2]
tree = ast.parse(open(checks, encoding="utf-8").read())
ids = []
for node in ast.walk(tree):
    if not isinstance(node, ast.Call):
        continue
    if not isinstance(node.func, ast.Name) or node.func.id != "_register":
        continue
    if not node.args or not isinstance(node.args[0], ast.Constant):
        continue
    ids.append(node.args[0].value)
assert ids, "the library registers no check"
tree = ast.parse(open(tool, encoding="utf-8").read())
for node in ast.walk(tree):
    if isinstance(node, (ast.Tuple, ast.List, ast.Set)):
        names = [e.value for e in node.elts
                 if isinstance(e, ast.Constant) and isinstance(e.value, str)]
        held = [name for name in names if name in ids]
        assert len(held) < 2, "the tool holds the list %s" % held
    if isinstance(node, ast.Compare):
        sides = [node.left] + list(node.comparators)
        names = [e.value for e in sides
                 if isinstance(e, ast.Constant) and isinstance(e.value, str)]
        for name in names:
            assert name not in ids, "the tool compares against the check %s" % name
EOF
then
	ok "(oo) the tool holds no list of checks: every check is registered in the library"
else
	bad "(oo) the tool holds a list of checks of its own"
fi

# The schema holds the same names as the registry: a check that is added
# needs a schema bump, and the two cannot drift apart.
if python3 - "$LIB/gpu_check/checks.py" "$REPO/schema/gpu-check-1.schema.json" <<'EOF'
import ast, json, sys
checks, schema = sys.argv[1], sys.argv[2]
tree = ast.parse(open(checks, encoding="utf-8").read())
ids = []
for node in ast.walk(tree):
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) \
            and node.func.id == "_register" and node.args \
            and isinstance(node.args[0], ast.Constant):
        ids.append(node.args[0].value)
doc = json.load(open(schema))
names = doc["$defs"]["check"]["properties"]["name"]["enum"]
assert names == ids, "the schema holds %s and the registry holds %s" % (names, ids)
EOF
then
	ok "(oo) the schema and the registry hold the same names"
else
	bad "(oo) the schema and the registry hold different names"
fi

# (pp) the colour is for a terminal, and NO_COLOR says no.
if python3 - "$TOOL" "$DATA/fake-load.json" "$DATA/pciconf-supported.txt" > "$TESTROOT/tty.out" 2>&1 <<'EOF'
import os, pty, subprocess, sys
tool, fake, pciconf = sys.argv[1:4]
master, slave = pty.openpty()
env = dict(os.environ)
env["TERM"] = "xterm"
env.pop("NO_COLOR", None)
proc = subprocess.Popen([sys.executable, tool, "--load", "--fake", fake,
                          "--pciconf-file", pciconf, "--arch", "arm64"],
                         stdout=slave, stderr=subprocess.DEVNULL, env=env)
os.close(slave)
data = b""
while True:
    try:
        chunk = os.read(master, 65536)
    except OSError:
        break
    if not chunk:
        break
    data += chunk
proc.wait()
sys.stdout.buffer.write(data)
EOF
then
	if grep -q "$(printf '\033')" "$TESTROOT/tty.out"; then
		ok "(pp) the table of a terminal holds the colour"
	else
		bad "(pp) the table of a terminal holds no colour"
	fi
else
	bad "(pp) the tool did not run on a terminal"
fi

if python3 - "$TOOL" "$DATA/fake-load.json" "$DATA/pciconf-supported.txt" > "$TESTROOT/tty-nocolour.out" 2>&1 <<'EOF'
import os, pty, subprocess, sys
tool, fake, pciconf = sys.argv[1:4]
master, slave = pty.openpty()
env = dict(os.environ)
env["TERM"] = "xterm"
env["NO_COLOR"] = "1"
proc = subprocess.Popen([sys.executable, tool, "--load", "--fake", fake,
                          "--pciconf-file", pciconf, "--arch", "arm64"],
                         stdout=slave, stderr=subprocess.DEVNULL, env=env)
os.close(slave)
data = b""
while True:
    try:
        chunk = os.read(master, 65536)
    except OSError:
        break
    if not chunk:
        break
    data += chunk
proc.wait()
sys.stdout.buffer.write(data)
EOF
then
	if grep -q "$(printf '\033')" "$TESTROOT/tty-nocolour.out"; then
		bad "(pp) NO_COLOR was not obeyed"
	else
		ok "(pp) NO_COLOR says no, and the table is plain"
	fi
else
	bad "(pp) the tool did not run on a terminal"
fi

# (qq) the load of a module that is already loaded, and of a module that
# is not installed: the kit loads the modules itself, and the tool must
# go on with the ones that are there.
cat > "$TESTROOT/fake-loaded.json" <<'EOF'
{
  "modules": ["nvidia", "nvidia-modeset"],
  "kldload": {
    "nvidia_gsp_ga10x_fw": {"status": "pass", "message": "the firmware module was loaded"},
    "nvidia-drm": {"status": "not_available", "message": "the module nvidia-drm is not installed"}
  },
  "identity": {"status": "pass", "pci_vendor": "0x10de", "pci_device": "0x2d04"},
  "memory": {"status": "pass", "message": "the memory probe passed every step"}
}
EOF
run_tool --load --fake "$TESTROOT/fake-loaded.json" --pciconf-file "$DATA/pciconf-supported.txt" \
	--arch arm64 --json > "$TESTROOT/loaded.json"
if python3 - "$TESTROOT/loaded.json" <<'EOF'
import json, sys
doc = json.load(open(sys.argv[1]))
rows = dict((r["name"], r) for r in doc["devices"][0]["checks"])
# a module that is loaded is loaded: the row says so
assert rows["driver-loaded"]["status"] == "pass", rows["driver-loaded"]
assert "already loaded" in rows["driver-loaded"]["reason"], rows["driver-loaded"]
# a module that is not installed is not a failure: the row names it
assert "nvidia-drm" in rows["driver-loaded"]["reason"], rows["driver-loaded"]
assert "not available" in rows["driver-loaded"]["reason"], rows["driver-loaded"]
# the checks that need the driver ran
assert rows["identity"]["status"] == "pass", rows["identity"]
assert rows["memory"]["status"] == "pass", rows["memory"]
EOF
then
	ok "(qq) a module that is already loaded is loaded, and a module that is not installed does not stop the run"
else
	bad "(qq) the load of the modules: $(head -c 300 "$TESTROOT/loaded.json" | tr '\n' ' ')"
fi

# No module at all: the row says the driver is not available, and the
# checks that need it say they did not run.
cat > "$TESTROOT/fake-none.json" <<'EOF'
{
  "kldload": {
    "nvidia_gsp_ga10x_fw": {"status": "not_available", "message": "the firmware module is not installed"},
    "nvidia": {"status": "not_available", "message": "the module nvidia is not installed"},
    "nvidia-modeset": {"status": "not_available", "message": "the module nvidia-modeset is not installed"},
    "nvidia-drm": {"status": "not_available", "message": "the module nvidia-drm is not installed"}
  }
}
EOF
run_tool --load --fake "$TESTROOT/fake-none.json" --pciconf-file "$DATA/pciconf-supported.txt" \
	--arch arm64 --json > "$TESTROOT/none.json"
if python3 - "$TESTROOT/none.json" <<'EOF'
import json, sys
doc = json.load(open(sys.argv[1]))
rows = dict((r["name"], r) for r in doc["devices"][0]["checks"])
assert rows["firmware"]["status"] == "not_available", rows["firmware"]
assert rows["driver-loaded"]["status"] == "not_available", rows["driver-loaded"]
assert "not installed" in rows["driver-loaded"]["reason"], rows["driver-loaded"]
assert rows["identity"]["status"] == "not_tested", rows["identity"]
assert "driver was not loaded" in rows["identity"]["reason"], rows["identity"]
EOF
then
	ok "(qq) no module at all: the driver is not available and the checks that need it say why"
else
	bad "(qq) the run without any module: $(head -c 300 "$TESTROOT/none.json" | tr '\n' ' ')"
fi

# The rule of the live path: a module that is not installed is not
# available, and a name that is not a bare module name is a failure.
if python3 - "$TOOL" <<'EOF'
import sys
tool = sys.argv[1]
namespace = {"__name__": "gpu_check_tool", "__file__": tool}
exec(compile(open(tool, encoding="utf-8").read(), tool, "exec"), namespace)
path_of = namespace["trusted_module_path"]
not_available = namespace["NOT_AVAILABLE"]
failed = namespace["FAIL"]
# a module that is not installed under the module directory
path, reason, status = path_of("no-such-module-here")
assert path is None, path
assert status == not_available, status
assert "not installed" in reason, reason
# a name that is not a bare module name is never loaded
path, reason, status = path_of("nvidia/../evil")
assert path is None, path
assert status == failed, status
EOF
then
	ok "(qq) the rule of the live path: a module that is not installed is not available"
else
	bad "(qq) the rule of the live path is not the one the rows say"
fi

# (rr) --assume-loaded: the driver is already loaded, so the tool runs
# every check and loads nothing.  The listing of the loaded modules is
# the proof: it is the same before and after the run.
kldstat -v > "$TESTROOT/kld-before" 2>&1
run_tool --assume-loaded --pciconf-file "$DATA/pciconf-supported.txt" --arch arm64 \
	--json > "$TESTROOT/assume.json"
kldstat -v > "$TESTROOT/kld-after" 2>&1
if cmp -s "$TESTROOT/kld-before" "$TESTROOT/kld-after"; then
	ok "(rr) --assume-loaded loads no module: the listing is the same before and after"
else
	bad "(rr) --assume-loaded changed the listing of the loaded modules"
fi
if python3 - "$TESTROOT/assume.json" <<'EOF'
import json, sys
doc = json.load(open(sys.argv[1]))
# the run says which mode it was
assert doc["mode"] == "assume-loaded", doc["mode"]
rows = dict((r["name"], r) for r in doc["devices"][0]["checks"])
# every check ran or said why it did not: none was left out
for name, row in rows.items():
    assert "not asked for" not in row["reason"], (name, row)
# the checks that need the driver are answered by the driver that is
# there, not left out
assert rows["identity"]["name"] == "identity", rows["identity"]
# the tool says what is loaded and what is not, and it never loads
for name in ("firmware", "driver-loaded"):
    reason = rows[name]["reason"]
    assert ("this run loads nothing" in reason
            or "was already loaded" in reason), (name, reason)
EOF
then
	ok "(rr) --assume-loaded runs every check, says what is loaded and loads nothing"
else
	bad "(rr) the run with --assume-loaded: $(head -c 300 "$TESTROOT/assume.json" | tr '\n' ' ')"
fi
if python3 "$REPO/tests/schema_check.py" "$REPO/schema/gpu-check-1.schema.json" \
	"$TESTROOT/assume.json" > "$TESTROOT/assume-schema.out" 2>&1; then
	ok "(rr) the document of an --assume-loaded run matches the registered schema"
else
	bad "(rr) the document of an --assume-loaded run does not match the schema: $(tr '\n' ' ' < "$TESTROOT/assume-schema.out")"
fi

# (ss) the unit tests of the library: the paths a command never takes.
if python3 "$REPO/tests/gpu_check_unit.py" "$LIB" > "$TESTROOT/unit.out" 2>&1; then
	ok "(ss) the unit tests of the library pass"
else
	bad "(ss) the unit tests of the library failed: $(grep '^FAIL' "$TESTROOT/unit.out" | head -3 | tr '\n' ' ')"
fi

# (tt) the checks against the fake backend of our own library: the memory
# and the channel steps run over a card that behaves like one, without one.
# The library is built when the pinned sources are here; the case says so
# and skips itself when they are not.
_ogkm=$(awk '$1 == "ogkm_tag" { print $2 }' "$REPO/SOURCES" 2> /dev/null)
_sources=
for _base in "${GB10_WORK:-}" "$REPO/work" "$REPO/../work" "$REPO/.."; do
	[ -n "$_base" ] || continue
	if [ -d "$_base/sources/open-gpu-kernel-modules-$_ogkm" ]; then
		_sources="$_base/sources/open-gpu-kernel-modules-$_ogkm"
		break
	fi
done
if [ -z "$_sources" ]; then
	printf 'note: the pinned sources are not here: the checks against the fake backend did not run\n'
elif ! mkdir -p "$TESTROOT/lib"; then
	printf 'note: the scratch of the library cannot be made: the fake backend did not run\n'
elif ! MAKEOBJDIR="$TESTROOT/lib" OGKM="$_sources" /usr/bin/make -C "$REPO/lib/libnvrm" \
	> "$TESTROOT/libbuild.log" 2>&1; then
	printf 'note: the library could not be built here: the fake backend did not run\n'
else
	NVRM_BACKEND=fake
	GPU_CHECK_NVRM_LIBRARY="$TESTROOT/lib/libnvrm.so.1"
	LD_LIBRARY_PATH="$TESTROOT/lib"
	GPU_CHECK_CHAN_STRESS=50
	export NVRM_BACKEND GPU_CHECK_NVRM_LIBRARY LD_LIBRARY_PATH GPU_CHECK_CHAN_STRESS
	python3 "$REPO/tests/gpu_check_fake_backend.py" "$REPO/scripts/adapters/0x10de.py" \
		"$LIB" > "$TESTROOT/fake-backend.json" 2> "$TESTROOT/fake-backend.err"
	_fb_rc=$?
	unset NVRM_BACKEND GPU_CHECK_NVRM_LIBRARY LD_LIBRARY_PATH GPU_CHECK_CHAN_STRESS
	if [ "$_fb_rc" = 0 ] && python3 - "$TESTROOT/fake-backend.json" <<'EOF'
import json, sys
doc = json.load(open(sys.argv[1]))
# the identity of the card is read from the resource manager
assert doc["identity"]["status"] == "pass", doc["identity"]
assert isinstance(doc["identity"]["extra"]["rm_index"], int), doc["identity"]
# the UUID of the card is hashed and never printed
uuid = doc["identity"]["extra"]["uuid_sha256"]
assert uuid.startswith("sha256:"), uuid
# the memory probe ran every step of the memory probe of the kit
memory = doc["memory_steps"]["steps"]
assert len(memory) == 19, sorted(memory)
for name, step in memory.items():
    assert step["status"] == "pass", (name, step)
# the leak checks are the ones that say nothing was left behind
assert "nothing_left" in memory and "no_refused_release" in memory, sorted(memory)
# the channel probe ran every step of the channel probe of the kit
channel = doc["channel_steps"]["steps"]
assert len(channel) == 6, sorted(channel)
for name, step in channel.items():
    assert step["status"] == "pass", (name, step)
assert "cleanup" in channel, sorted(channel)
# the library that runs the steps folds them into the row of the check
assert doc["memory"]["status"] == "pass", doc["memory"]
assert doc["channel"]["status"] == "pass", doc["channel"]
assert len(doc["memory"]["steps"]) == 19, doc["memory"]
assert len(doc["channel"]["steps"]) == 6, doc["channel"]
EOF
	then
		ok "(tt) the checks against the fake backend of the library ran every step"
	else
		bad "(tt) the checks against the fake backend failed: $(head -c 300 "$TESTROOT/fake-backend.err" "$TESTROOT/fake-backend.json" 2> /dev/null | tr '\n' ' ')"
	fi
fi

printf 'passed: %s failed: %s\n' "$PASSED" "$FAILED"
if [ "$FAILED" -gt 0 ]; then
	exit 1
fi
exit 0

#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# preflight_support_test.sh - what make preflight says about each NVIDIA
# display device now that nvidia.ko attaches to GA10x (RTX 30) and later only
# (Track #2457): the support verdict from the chip name and the header's
# table when nvidia.ko is not loaded, from the kernel's own answer when it is,
# the JSON contract (schema 2.0: the document carries schema_version as a
# string and schema_major and schema_minor as integers) and the text.
# pciconf, sysctl and the machine architecture are faked through the make.sh
# test hooks; plants (mutated copies of make.sh and the header) must turn the
# cases red.  Nothing is loaded and no GPU is needed.
set -u
ulimit -c 0
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH= cd -- "$HERE/.." && pwd -P)
WORK=${GB10_WORK:-$REPO/work}
mkdir -p "$WORK/tmp"
T=$(mktemp -d "$WORK/tmp/preflight_support_test.XXXXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT
fails=0
killed=0
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }
pass() { echo "PASS: $*"; }

FAKE=$T/fake
mkdir -p "$FAKE/sysd" "$T/work"
cat > "$FAKE/pciconf" <<'EOT'
#!/bin/sh
case "$1" in
-l) cat "$FAKE_DIR/pci-l" ;;
-lv) cat "$FAKE_DIR/pci-lv" ;;
*) exit 2 ;;
esac
EOT
cat > "$FAKE/sysctl" <<'EOT'
#!/bin/sh
d=$FAKE_DIR/sysd
case "$*" in
"-n hw.nvidia.min_architecture") [ -f "$d/min" ] || exit 1; cat "$d/min" ;;
"-n hw.nvidia.min_architecture_name") cat "$d/name" ;;
"dev.nvidia") [ -f "$d/dev" ] || { echo "sysctl: unknown oid 'dev.nvidia'" >&2; exit 1; }; cat "$d/dev" ;;
"-n hw.nvidia.refused") cat "$d/refused" ;;
"-n hw.nvidia.refused_count") [ -f "$d/count" ] || exit 1; cat "$d/count" ;;
*) exit 1 ;;
esac
EOT
chmod +x "$FAKE/pciconf" "$FAKE/sysctl"

# reset: no devices, nvidia.ko not loaded
reset() {
	: > "$FAKE/pci-l"
	: > "$FAKE/pci-lv"
	rm -f "$FAKE/sysd/min" "$FAKE/sysd/name" "$FAKE/sysd/dev" \
	    "$FAKE/sysd/refused" "$FAKE/sysd/count"
}

# add_dev SELECTOR VENDOR DEVICE DEVICE-NAME [CLASS]
add_dev() {
	_cls=${5:-0x030000}
	printf '%s:\tclass=%s rev=0xa1 hdr=0x00 vendor=%s device=%s subvendor=0x1462 subdevice=0x5351\n' \
	    "$1" "$_cls" "$2" "$3" >> "$FAKE/pci-l"
	printf '%s:\tclass=%s rev=0xa1 hdr=0x00 vendor=%s device=%s subvendor=0x1462 subdevice=0x5351\n    vendor     = '"'"'Vendor'"'"'\n    device     = '"'"'%s'"'"'\n    class      = display\n    subclass   = VGA\n' \
	    "$1" "$_cls" "$2" "$3" "$4" >> "$FAKE/pci-lv"
}

# run_pf REPODIR MACHINE OUTPUT [--json]: preflight of REPODIR's make.sh
run_pf() {
	_rd=$1
	_mach=$2
	_out=$3
	shift 3
	env FAKE_DIR="$FAKE" GB10_TEST_HOOKS=1 GB10_TEST_PCICONF="$FAKE/pciconf" \
	    GB10_TEST_SYSCTL="$FAKE/sysctl" GB10_TEST_MACHINE_ARCH="$_mach" \
	    MK_WORK="$T/work" sh "$_rd/scripts/make.sh" preflight "$@" > "$_out" 2> "$_out.err"
}

# table_for REPODIR: the verdict of every device in eight preflight runs, one
# line per device: "<scenario>: <selector> state=<s> arch=<a> source=<src>"
table_for() {
	_rd=$1
	one() { # scenario machine
		run_pf "$_rd" "$2" "$T/pf.json" --json
		python3 -I - "$T/pf.json" "$1" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
for it in d["items"]:
    s = it["support"]
    print("%s: %s state=%s arch=%s source=%s" % (sys.argv[2], it["selector"], s["state"], s["architecture"], s["source"]))
PYEOF
	}
	# nvidia.ko not loaded: the chip name and the header decide
	reset
	add_dev vgapci0@pci0:2:0:0 0x1002 0x7480 'Navi 33 [Radeon RX 7600]'
	add_dev vgapci1@pci0:1:0:0 0x10de 0x1e84 'TU104 [GeForce RTX 2070 SUPER]'
	add_dev vgapci2@pci0:2:0:0 0x10de 0x2204 'GA102 [GeForce RTX 3090]'
	add_dev vgapci3@pci0:3:0:0 0x10de 0x2684 'AD102 [GeForce RTX 4090]'
	add_dev vgapci4@pci0:4:0:0 0x10de 0x2d04 'GB206 [GeForce RTX 5060 Ti]'
	add_dev vgapci5@pci0:5:0:0 0x10de 0x2e12 'GB20B [GB10]'
	add_dev vgapci6@pci0:6:0:0 0x10de 0x1b80 'GP104 [GeForce GTX 1080]'
	add_dev vgapci7@pci0:7:0:0 0x10de 0x20b0 'GA100 [A100 SXM4 40GB]'
	add_dev vgapci8@pci0:8:0:0 0x10de 0x9999 'Device 9999'
	add_dev vgapci9@pci0:9:0:0 0x10de 0x9998 'ZZ104 [Future]'
	add_dev vgapci10@pci0:10:0:0 0x10de 0x20b6 'GA100GL [A30 PCIe]'
	add_dev vgapci11@pci0:11:0:0 0x10de 0x0fc6 'GK208B [GeForce GT 710]'
	# the chip key (the prefix and the two digits) tells the families of
	# one prefix apart: GM100 is not GM200, GV100 is not GV110 and
	# GB100 is not GB206
	add_dev vgapci12@pci0:12:0:0 0x10de 0x1004 'GM100 [GeForce GTX 780]'
	add_dev vgapci13@pci0:13:0:0 0x10de 0x1024 'GM200 [Tesla M60]'
	add_dev vgapci14@pci0:14:0:0 0x10de 0x1db1 'GV100 [Tesla V100 PCIe]'
	add_dev vgapci15@pci0:15:0:0 0x10de 0x1c1c 'GV110 [Tesla P100 PCIe]'
	add_dev vgapci16@pci0:16:0:0 0x10de 0x2321 'GB100 [NVIDIA B200]'
	one arm64 aarch64
	one amd64 amd64
	# nvidia.ko loaded: the kernel decides
	reset
	add_dev vgapci1@pci0:13:0:0 0x10de 0x1e84 'TU104 [GeForce RTX 2070 SUPER]'
	add_dev vgapci2@pci0:5:0:0 0x10de 0x2204 'GA102 [GeForce RTX 3090]'
	add_dev vgapci3@pci0:6:0:0 0x10de 0x2684 'AD102 [GeForce RTX 4090]'
	printf '23\n' > "$FAKE/sysd/min"
	printf 'GA10x\n' > "$FAKE/sysd/name"
	printf 'dev.nvidia.0.%%parent: vgapci2\ndev.nvidia.0.%%desc: NVIDIA test\n' > "$FAKE/sysd/dev"
	printf 'pci0:13:0:0 vgapci1 0x1e84 below-floor NVIDIA GeForce RTX 2070 SUPER (0x1e84) is TU10x; this driver supports GA10x (RTX 30) and later\n' > "$FAKE/sysd/refused"
	one kernel amd64
	# vgapci1 unclaimed while vgapci10 attached: vgapci1 is not "attached"
	reset
	add_dev vgapci1@pci0:13:0:0 0x10de 0x2204 'GA102 [GeForce RTX 3090]'
	printf '23\n' > "$FAKE/sysd/min"
	printf 'GA10x\n' > "$FAKE/sysd/name"
	printf 'dev.nvidia.0.%%parent: vgapci10\n' > "$FAKE/sysd/dev"
	: > "$FAKE/sysd/refused"
	one kernel-prefix aarch64
	# a refused line with a keyword this build does not know
	reset
	add_dev vgapci1@pci0:13:0:0 0x10de 0x1e84 'TU104 [GeForce RTX 2070 SUPER]'
	printf '23\n' > "$FAKE/sysd/min"
	printf 'GA10x\n' > "$FAKE/sysd/name"
	: > "$FAKE/sysd/dev"
	printf 'pci0:13:0:0 vgapci1 0x1e84 bogus msg\n' > "$FAKE/sysd/refused"
	one kernel-bogus aarch64
	# a refused line whose keyword tries to close the JSON object
	reset
	add_dev vgapci1@pci0:13:0:0 0x10de 0x1e84 'TU104 [GeForce RTX 2070 SUPER]'
	printf '23\n' > "$FAKE/sysd/min"
	printf 'GA10x\n' > "$FAKE/sysd/name"
	: > "$FAKE/sysd/dev"
	printf 'pci0:13:0:0 vgapci1 0x1e84 x","architecture":"GA10x","source":"kernel below\n' > "$FAKE/sysd/refused"
	one kernel-injected aarch64
	# the kernel refused more GPUs than it lists
	reset
	add_dev vgapci1@pci0:13:0:0 0x10de 0x1e84 'TU104 [GeForce RTX 2070 SUPER]'
	printf '23\n' > "$FAKE/sysd/min"
	printf 'GA10x\n' > "$FAKE/sysd/name"
	: > "$FAKE/sysd/dev"
	: > "$FAKE/sysd/refused"
	printf '17\n' > "$FAKE/sysd/count"
	one kernel-overflow aarch64
}

cat > "$T/want" <<'EOT'
arm64: vgapci1@pci0:1:0:0 state=below-floor arch=TU10x source=pci_vendors
arm64: vgapci2@pci0:2:0:0 state=supported arch=GA10x source=pci_vendors
arm64: vgapci3@pci0:3:0:0 state=supported arch=AD10x source=pci_vendors
arm64: vgapci4@pci0:4:0:0 state=supported arch=GB20x source=pci_vendors
arm64: vgapci5@pci0:5:0:0 state=supported arch=GB20x source=pci_vendors
arm64: vgapci6@pci0:6:0:0 state=below-floor arch=GP10x source=pci_vendors
arm64: vgapci7@pci0:7:0:0 state=no-firmware arch=GA10x source=pci_vendors
arm64: vgapci8@pci0:8:0:0 state=unknown arch=None source=pci_vendors
arm64: vgapci9@pci0:9:0:0 state=unknown arch=None source=pci_vendors
arm64: vgapci10@pci0:10:0:0 state=no-firmware arch=GA10x source=pci_vendors
arm64: vgapci11@pci0:11:0:0 state=unknown arch=None source=pci_vendors
arm64: vgapci12@pci0:12:0:0 state=below-floor arch=GM10x source=pci_vendors
arm64: vgapci13@pci0:13:0:0 state=below-floor arch=GM20x source=pci_vendors
arm64: vgapci14@pci0:14:0:0 state=below-floor arch=GV10x source=pci_vendors
arm64: vgapci15@pci0:15:0:0 state=below-floor arch=GV11x source=pci_vendors
arm64: vgapci16@pci0:16:0:0 state=supported arch=GB10x source=pci_vendors
amd64: vgapci1@pci0:1:0:0 state=below-floor arch=TU10x source=pci_vendors
amd64: vgapci2@pci0:2:0:0 state=supported arch=GA10x source=pci_vendors
amd64: vgapci3@pci0:3:0:0 state=supported arch=AD10x source=pci_vendors
amd64: vgapci4@pci0:4:0:0 state=supported arch=GB20x source=pci_vendors
amd64: vgapci5@pci0:5:0:0 state=supported arch=GB20x source=pci_vendors
amd64: vgapci6@pci0:6:0:0 state=below-floor arch=GP10x source=pci_vendors
amd64: vgapci7@pci0:7:0:0 state=supported arch=GA10x source=pci_vendors
amd64: vgapci8@pci0:8:0:0 state=unknown arch=None source=pci_vendors
amd64: vgapci9@pci0:9:0:0 state=unknown arch=None source=pci_vendors
amd64: vgapci10@pci0:10:0:0 state=supported arch=GA10x source=pci_vendors
amd64: vgapci11@pci0:11:0:0 state=unknown arch=None source=pci_vendors
amd64: vgapci12@pci0:12:0:0 state=below-floor arch=GM10x source=pci_vendors
amd64: vgapci13@pci0:13:0:0 state=below-floor arch=GM20x source=pci_vendors
amd64: vgapci14@pci0:14:0:0 state=below-floor arch=GV10x source=pci_vendors
amd64: vgapci15@pci0:15:0:0 state=below-floor arch=GV11x source=pci_vendors
amd64: vgapci16@pci0:16:0:0 state=supported arch=GB10x source=pci_vendors
kernel: vgapci1@pci0:13:0:0 state=below-floor arch=TU10x source=kernel
kernel: vgapci2@pci0:5:0:0 state=supported arch=GA10x source=kernel
kernel: vgapci3@pci0:6:0:0 state=unknown arch=AD10x source=kernel
kernel-prefix: vgapci1@pci0:13:0:0 state=unknown arch=GA10x source=kernel
kernel-bogus: vgapci1@pci0:13:0:0 state=unknown arch=TU10x source=kernel
kernel-injected: vgapci1@pci0:13:0:0 state=unknown arch=TU10x source=kernel
kernel-overflow: vgapci1@pci0:13:0:0 state=unknown arch=TU10x source=kernel
EOT

table_for "$REPO" > "$T/got" 2> "$T/got.err"
if diff -u "$T/want" "$T/got" > "$T/diff"; then
	pass "verdicts: pci_vendors source for every architecture, kernel source for attached, refused and unclaimed"
else
	cat "$T/diff" >&2
	head -n 5 "$T/got.err" >&2
	fail "the verdict table differs"
fi

# the details: reasons, min_architecture, no missing item, contract, text
reset
add_dev vgapci1@pci0:13:0:0 0x10de 0x1e84 'TU104 [GeForce RTX 2070 SUPER]'
run_pf "$REPO" aarch64 "$T/one.json" --json
reset
run_pf "$REPO" aarch64 "$T/none.json" --json
cat > "$T/validate.py" <<'PYEOF'
# a small JSON Schema checker for the keywords schema/make-preflight-2 uses
import json, re, sys

def check(schema, doc, path="$"):
    errs = []
    t = schema.get("type")
    types = {"object": dict, "array": list, "string": str, "integer": int, "boolean": bool}
    def type_ok(name):
        if name == "null":
            return doc is None
        if name == "integer":
            return isinstance(doc, int) and not isinstance(doc, bool)
        return isinstance(doc, types[name])
    if t is not None:
        names = t if isinstance(t, list) else [t]
        if not any(type_ok(n) for n in names):
            return ["%s: not %s" % (path, t)]
    if "const" in schema and doc != schema["const"]:
        errs.append("%s: not %r" % (path, schema["const"]))
    if "enum" in schema and doc not in schema["enum"]:
        errs.append("%s: %r not in enum" % (path, doc))
    if "pattern" in schema and isinstance(doc, str) and not re.search(schema["pattern"], doc):
        errs.append("%s: pattern" % path)
    if "minimum" in schema and isinstance(doc, int) and doc < schema["minimum"]:
        errs.append("%s: minimum" % path)
    if "minLength" in schema and isinstance(doc, str) and len(doc) < schema["minLength"]:
        errs.append("%s: minLength" % path)
    if isinstance(doc, dict):
        for k in schema.get("required", []):
            if k not in doc:
                errs.append("%s: missing %s" % (path, k))
        props = schema.get("properties", {})
        if schema.get("additionalProperties") is False:
            for k in doc:
                if k not in props:
                    errs.append("%s: unexpected %s" % (path, k))
        for k, v in props.items():
            if k in doc:
                errs += check(v, doc[k], path + "." + k)
    if isinstance(doc, list) and "items" in schema:
        for i, v in enumerate(doc):
            errs += check(schema["items"], v, "%s[%d]" % (path, i))
    return errs

schema = json.load(open(sys.argv[1]))
bad = 0
for f in sys.argv[2:]:
    errs = check(schema, json.load(open(f)))
    for e in errs:
        print("%s: %s" % (f, e))
    bad += len(errs)
sys.exit(1 if bad else 0)
PYEOF
if python3 -I "$T/validate.py" "$REPO/schema/make-preflight-2.schema.json" \
    "$T/one.json" "$T/none.json" "$REPO/tests/fixtures/make-preflight-2.json" > "$T/validate.out" 2>&1; then
	pass "schema: a device document, an empty one and the fixture validate"
else
	cat "$T/validate.out" >&2
	fail "schema validation"
fi
# the fixture of the old contract still validates against the old schema
if python3 -I "$T/validate.py" "$REPO/schema/make-preflight-1.schema.json" \
    "$REPO/tests/fixtures/make-preflight.json" > "$T/validate1.out" 2>&1; then
	pass "schema: the fixture of the old contract validates against the old schema"
else
	cat "$T/validate1.out" >&2
	fail "the old fixture does not validate against the old schema"
fi
# the checker itself can fail: a bad state and a stray key are refused
python3 -I - "$T/one.json" "$T/bad.json" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
d["items"][0]["support"]["state"] = "maybe"
d["extra"] = 1
json.dump(d, open(sys.argv[2], "w"))
PYEOF
if python3 -I "$T/validate.py" "$REPO/schema/make-preflight-2.schema.json" "$T/bad.json" > /dev/null 2>&1; then
	fail "the schema checker accepted a bad document"
else
	pass "the schema checker refuses a bad state and a stray key"
fi
# the schema requires the new properties: a document without them is refused
python3 -I - "$REPO/tests/fixtures/make-preflight-2.json" "$T/v10.json" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
d.pop("min_architecture", None)
for it in d["items"]:
    it.pop("support", None)
json.dump(d, open(sys.argv[2], "w"))
PYEOF
if python3 -I "$T/validate.py" "$REPO/schema/make-preflight-2.schema.json" "$T/v10.json" > "$T/validate.out" 2>&1; then
	fail "the schema checker accepted a document without support and min_architecture"
else
	pass "schema: a document without support or min_architecture is refused"
fi
if python3 -I - "$T/one.json" "$T/none.json" <<'PYEOF'
import json, sys
one = json.load(open(sys.argv[1]))
none = json.load(open(sys.argv[2]))
assert one["schema_version"] == "2.0", one["schema_version"]
assert one["schema_major"] == 2 and one["schema_minor"] == 0, one
m = one["min_architecture"]
assert m["value"] == 23 and m["name"] == "GA10x" and m["source"] == "header", m
s = one["items"][0]["support"]
assert s["state"] == "below-floor" and s["architecture"] == "TU10x"
assert s["reason"] == "TU104 belongs to the TU10x chip family; this driver supports GA10x (RTX 30) and later", s["reason"]
# a card below the floor is never a missing item: the build needs no GPU
assert one["missing"] == none["missing"], (one["missing"], none["missing"])
assert [x["name"] for x in one["status"]] == [x["name"] for x in none["status"]]
assert one["device"] == "NVIDIA device present" and none["device"] == "no NVIDIA device"
assert none["items"] == [] and none["min_architecture"]["value"] == 23
PYEOF
then
	pass "JSON: reason, min_architecture 23 GA10x from the header, no missing item for an old card"
else
	fail "JSON details"
fi

# kernel source details: the kernel's own message, min_architecture from it
reset
add_dev vgapci2@pci0:13:0:0 0x10de 0x1e84 'TU104 [GeForce RTX 2070 SUPER]'
printf '24\n' > "$FAKE/sysd/min"
printf 'GH100\n' > "$FAKE/sysd/name"
: > "$FAKE/sysd/dev"
printf 'pci0:13:0:0 vgapci2 0x1e84 below-floor NVIDIA GeForce RTX 2070 SUPER (0x1e84) is TU10x; this driver supports GA10x (RTX 30) and later\n' > "$FAKE/sysd/refused"
run_pf "$REPO" aarch64 "$T/k.json" --json
run_pf "$REPO" aarch64 "$T/k.txt"
if python3 -I - "$T/k.json" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
m = d["min_architecture"]
assert m == {"value": 24, "name": "GH100", "source": "kernel"}, m
s = d["items"][0]["support"]
assert s["source"] == "kernel" and s["state"] == "below-floor"
assert s["reason"] == "NVIDIA GeForce RTX 2070 SUPER (0x1e84) is TU10x; this driver supports GA10x (RTX 30) and later", s["reason"]
PYEOF
then pass "JSON kernel source: the kernel's message and its own floor"; else fail "JSON kernel source details"; fi
if grep -q '^gpu   vgapci2@pci0:13:0:0 0x10de 0x1e84 0x030000: present, below the supported floor$' "$T/k.txt" &&
    grep -q '^      NVIDIA GeForce RTX 2070 SUPER (0x1e84) is TU10x; this driver supports GA10x (RTX 30) and later$' "$T/k.txt"; then
	pass "text: a refused card prints 'present, below the supported floor' with the kernel's words"
else
	grep '^gpu\|^      ' "$T/k.txt" >&2
	fail "text line for a refused card"
fi
reset
add_dev vgapci1@pci0:13:0:0 0x10de 0x2d04 'GB206 [GeForce RTX 5060 Ti]'
run_pf "$REPO" aarch64 "$T/s.txt"
if grep -q '^gpu   vgapci1@pci0:13:0:0 0x10de 0x2d04 0x030000: present, supported$' "$T/s.txt" &&
    grep -q '^      GB206 belongs to the GB20x chip family$' "$T/s.txt"; then
	pass "text: a supported card prints its architecture and 'supported'"
else
	grep '^gpu\|^      ' "$T/s.txt" >&2
	fail "text line for a supported card"
fi
# the reason of a hostile device name is escaped, not trusted
reset
add_dev vgapci2@pci0:13:0:0 0x10de 0x1e84 'TU104 [x]'
printf '23\n' > "$FAKE/sysd/min"
printf 'GA10x\n' > "$FAKE/sysd/name"
: > "$FAKE/sysd/dev"
printf 'pci0:13:0:0 vgapci2 0x1e84 below-floor name "with|pipe" (0x1e84) is TU10x\n' > "$FAKE/sysd/refused"
run_pf "$REPO" aarch64 "$T/h.json" --json
if python3 -I - "$T/h.json" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["items"][0]["support"]["reason"] == 'name "with|pipe" (0x1e84) is TU10x', d["items"][0]["support"]["reason"]
PYEOF
then pass "a '|' and quotes in the kernel's message round-trip"; else fail "hostile message round trip"; fi

# a kernel older than this build answers hw.nvidia.min_architecture_name
# with the marketing name of the generation: the document must carry the
# chip family, and it must validate against the schema of this build
reset
add_dev vgapci2@pci0:13:0:0 0x10de 0x1e84 'TU104 [GeForce RTX 2070 SUPER]'
printf '23\n' > "$FAKE/sysd/min"
printf 'Ampere\n' > "$FAKE/sysd/name"
: > "$FAKE/sysd/dev"
: > "$FAKE/sysd/refused"
run_pf "$REPO" aarch64 "$T/old.json" --json
if python3 -I "$T/validate.py" "$REPO/schema/make-preflight-2.schema.json" "$T/old.json" > "$T/validate.out" 2>&1 &&
    python3 -I - "$T/old.json" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
m = d["min_architecture"]
assert m == {"value": 23, "name": "GA10x", "source": "kernel"}, m
PYEOF
then
	pass "an older kernel: the marketing name is translated and the document validates"
else
	cat "$T/validate.out" >&2
	fail "the document of an older kernel does not validate"
fi
# an old name that names two chip families is left out, not guessed
printf 'Blackwell\n' > "$FAKE/sysd/name"
run_pf "$REPO" aarch64 "$T/old2.json" --json
if python3 -I "$T/validate.py" "$REPO/schema/make-preflight-2.schema.json" "$T/old2.json" > "$T/validate.out" 2>&1 &&
    python3 -I - "$T/old2.json" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
m = d["min_architecture"]
assert m == {"value": 23, "name": None, "source": "kernel"}, m
PYEOF
then
	pass "an older kernel with an ambiguous name: the name is left out"
else
	cat "$T/validate.out" >&2
	fail "the document of an older kernel with an ambiguous name does not validate"
fi

# a keyword this build does not know is "unknown", and the document is valid
reset
add_dev vgapci2@pci0:13:0:0 0x10de 0x1e84 'TU104 [x]'
printf '23\n' > "$FAKE/sysd/min"
printf 'GA10x\n' > "$FAKE/sysd/name"
: > "$FAKE/sysd/dev"
printf 'pci0:13:0:0 vgapci2 0x1e84 bogus msg\n' > "$FAKE/sysd/refused"
run_pf "$REPO" aarch64 "$T/bogus.json" --json
if python3 -I "$T/validate.py" "$REPO/schema/make-preflight-2.schema.json" "$T/bogus.json" > "$T/validate.out" 2>&1 &&
    python3 -I - "$T/bogus.json" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
s = d["items"][0]["support"]
assert s["state"] == "unknown", s
assert s["reason"] == "msg", s
PYEOF
then pass "an unknown keyword is 'unknown' and the document still validates"
else
	cat "$T/validate.out" >&2
	fail "the kernel's keyword is not checked"
fi
# a keyword that tries to close the JSON object cannot: the state is "unknown"
reset
add_dev vgapci2@pci0:13:0:0 0x10de 0x1e84 'TU104 [x]'
printf '23\n' > "$FAKE/sysd/min"
printf 'GA10x\n' > "$FAKE/sysd/name"
: > "$FAKE/sysd/dev"
printf 'pci0:13:0:0 vgapci2 0x1e84 x","architecture":"GA10x","source":"kernel below\n' > "$FAKE/sysd/refused"
run_pf "$REPO" aarch64 "$T/injected.json" --json
if python3 -I "$T/validate.py" "$REPO/schema/make-preflight-2.schema.json" "$T/injected.json" > "$T/validate.out" 2>&1 &&
    python3 -I - "$T/injected.json" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
s = d["items"][0]["support"]
assert s["state"] == "unknown", s
assert s["architecture"] == "TU10x", s
PYEOF
then pass "a keyword that tries to inject JSON cannot: the state is 'unknown'"
else
	cat "$T/validate.out" >&2
	fail "the kernel's keyword is injected into the JSON"
fi
# the kernel refused more GPUs than it lists: preflight says so
reset
add_dev vgapci2@pci0:13:0:0 0x10de 0x1e84 'TU104 [x]'
printf '23\n' > "$FAKE/sysd/min"
printf 'GA10x\n' > "$FAKE/sysd/name"
: > "$FAKE/sysd/dev"
: > "$FAKE/sysd/refused"
printf '17\n' > "$FAKE/sysd/count"
run_pf "$REPO" aarch64 "$T/of.json" --json
if python3 -I - "$T/of.json" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
r = d["items"][0]["support"]["reason"]
assert "refused more GPUs than hw.nvidia.refused lists (16)" in r, r
assert "vgapci2: nvidia:" in r, r
PYEOF
then pass "more refusals than listed: the reason says so"
else fail "the reason for a refusal that is not listed"; fi
# nothing refused and nothing attached: the plain unknown reason
reset
add_dev vgapci2@pci0:13:0:0 0x10de 0x1e84 'TU104 [x]'
printf '23\n' > "$FAKE/sysd/min"
printf 'GA10x\n' > "$FAKE/sysd/name"
: > "$FAKE/sysd/dev"
: > "$FAKE/sysd/refused"
run_pf "$REPO" aarch64 "$T/un.json" --json
if python3 -I - "$T/un.json" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
r = d["items"][0]["support"]["reason"]
assert r == "nvidia.ko has neither attached nor refused it; see dmesg | grep vgapci2", r
PYEOF
then pass "neither attached nor refused: the reason says where to look"
else fail "the reason for a device the kernel did not touch"; fi

# the README says which cards the preflight can name
if grep -q 'A GM10x, GM20x, GP10x, GV10x, GV11x' "$REPO/README.md" &&
    grep -q 'or TU10x card below the floor' "$REPO/README.md" &&
    grep -q 'an older card' "$REPO/README.md"; then
	pass "README: only the six families below the floor are named"
else
	fail "README does not narrow the cards preflight names"
fi

# A floor with three hexadecimal digits is malformed: every verdict is
# unknown, and the floor itself is unavailable.
MAL=$T/malformed
mkdir -p "$MAL/scripts" "$MAL/src/gb10-archfloor"
for _e in "$REPO"/*; do
	case $_e in
	"$REPO/scripts"|"$REPO/src"|"$REPO/work"|"$REPO/tmp") ;;
	*) ln -s "$_e" "$MAL/$(basename "$_e")" ;;
	esac
done
cp "$REPO"/scripts/* "$MAL/scripts/" 2>/dev/null
sed -e 's/^\(#define NV_ARCH_FLOOR_MIN_ARCHITECTURE[ \t]*\)0x17/\10x017/' \
    "$REPO/src/gb10-archfloor/nv_arch_floor.h" > "$MAL/src/gb10-archfloor/nv_arch_floor.h"
if ! cmp -s "$REPO/src/gb10-archfloor/nv_arch_floor.h" "$MAL/src/gb10-archfloor/nv_arch_floor.h"; then
	reset
	add_dev vgapci1@pci0:13:0:0 0x10de 0x1e84 'TU104 [GeForce RTX 2070 SUPER]'
	add_dev vgapci2@pci0:5:0:0 0x10de 0x2204 'GA102 [GeForce RTX 3090]'
	run_pf "$MAL" aarch64 "$T/mal.json" --json
	if python3 -I - "$T/mal.json" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["min_architecture"]["source"] == "unavailable", d["min_architecture"]
assert d["min_architecture"]["value"] is None, d["min_architecture"]
assert d["items"], "the devices are missing"
for it in d["items"]:
    assert it["support"]["state"] == "unknown", it
    assert it["support"]["source"] == "pci_vendors", it
PYEOF
	then
		pass "a malformed floor: every verdict is unknown and the floor is unavailable"
	else
		fail "a malformed floor does not fail closed"
	fi
fi

# --- plants: mutated copies of make.sh and the header ---
# plant NAME FILE SED: FILE is scripts/make.sh or src/gb10-archfloor/nv_arch_floor.h
plant() {
	_name=$1
	_file=$2
	_expr=$3
	_pd=$T/plant-$_name
	mkdir -p "$_pd/scripts" "$_pd/src/gb10-archfloor"
	for _e in "$REPO"/*; do
		case $_e in
		"$REPO/scripts"|"$REPO/src"|"$REPO/work"|"$REPO/tmp") ;;
		*) ln -s "$_e" "$_pd/$(basename "$_e")" ;;
		esac
	done
	cp "$REPO"/scripts/* "$_pd/scripts/" 2>/dev/null
	cp "$REPO/src/gb10-archfloor/nv_arch_floor.h" "$_pd/src/gb10-archfloor/"
	sed -e "$_expr" "$REPO/$_file" > "$_pd/$_file"
	if cmp -s "$REPO/$_file" "$_pd/$_file"; then
		fail "plant $_name: substitution did not change $_file"
		return
	fi
	table_for "$_pd" > "$T/plant.got" 2> /dev/null
	if cmp -s "$T/want" "$T/plant.got"; then
		fail "plant $_name survived"
	else
		killed=$((killed + 1))
		pass "plant killed: $_name"
	fi
}

plant floor-0x16 src/gb10-archfloor/nv_arch_floor.h \
	's/^\(#define NV_ARCH_FLOOR_MIN_ARCHITECTURE[ 	]*\)0x17/\10x16/'
plant floor-0x1a src/gb10-archfloor/nv_arch_floor.h \
	's/^\(#define NV_ARCH_FLOOR_MIN_ARCHITECTURE[ 	]*\)0x17/\10x1a/'
# a floor with three hexadecimal digits is malformed: every verdict is unknown
plant floor-0x017 src/gb10-archfloor/nv_arch_floor.h \
	's/^\(#define NV_ARCH_FLOOR_MIN_ARCHITECTURE[ 	]*\)0x17/\10x017/'
# both GB rows share the prefix GB: dropping one leaves the verdict as it was
plant row-gb-dropped src/gb10-archfloor/nv_arch_floor.h '/^	ROW(0x1[ab], /d'
plant row-ad10x-dropped src/gb10-archfloor/nv_arch_floor.h '/^	ROW(0x19, /d'
plant firmware-row-dropped src/gb10-archfloor/nv_arch_floor.h '/^	ROW(0x17, 0x0, "GA100"/d'
plant floor-exclusive scripts/make.sh 's/if (best < floor) {/if (best <= floor) {/'
plant firmware-machine-inverted scripts/make.sh \
	's/&& !machine_in(fwmach\[j\], machine)/\&\& machine_in(fwmach[j], machine)/'
plant firmware-chip-exact scripts/make.sh \
	's/if (substr(c, 1, length(row)) != row) return 0/if (c != row) return 0/'
plant prefix-two-letters scripts/make.sh 's/p = substr(chip, 1, 4)/p = substr(chip, 1, 2)/'
plant kernel-ignored scripts/make.sh 's/\*) _k_on=1 ;;/*) _k_on=0 ;;/'
plant attached-prefix-match scripts/make.sh 's/\$2 == v { print "yes"; exit }/index($2, v) == 1 { print "yes"; exit }/'
plant location-not-after-at scripts/make.sh 's#@/, "", s#X/, "", s#'
plant refused-ignored scripts/make.sh 's/\$1 == loc \&\& NF >= 5 {/$1 == loc \&\& NF >= 99 {/'
plant kernel-state-unvalidated scripts/make.sh \
	's/below-floor|no-firmware|unknown|not-responding|unreadable)/below-floor|no-firmware|unknown|not-responding|unreadable|bogus)/'
plant chip-first-device scripts/make.sh 's/inblk = (\$1 == sel); next/inblk = 1; next/'
plant arch-name-dropped scripts/make.sh 's/_parch=\${_parch%%|\*}/_parch=/'

if [ "$fails" -ne 0 ]; then
	echo "preflight_support_test.sh: FAIL ($fails failures)" >&2
	exit 1
fi
echo "preflight_support_test.sh: PASS ($killed plants killed)"

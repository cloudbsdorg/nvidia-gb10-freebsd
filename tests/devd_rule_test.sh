#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# devd_rule_test.sh - the action of devd/nvidia_gb10.conf (Track #2457): it
# loads nvidia-drm only when the card that raised the event got an attached
# nvidia child.  The action is taken from the real conf, devd(8)'s variable
# expansion is reproduced (devd.conf(5): $name becomes $'value'), the absolute
# tool paths are rewritten to fakes and the result runs under sh -c.  grep is
# the real one: its -w and -F semantics are part of what is tested.  Plants
# (mutated copies of the conf) must turn the cases red.  Nothing is loaded.
set -u
ulimit -c 0
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CONF=$HERE/../devd/nvidia_gb10.conf
WORK=${GB10_WORK:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)/work}
mkdir -p "$WORK/tmp"
TMPD=$(mktemp -d "$WORK/tmp/devd_rule_test.XXXXXXXX") || exit 1
trap 'rm -rf "$TMPD"' EXIT
fails=0
killed=0
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }
pass() { echo "PASS: $*"; }

FAKES=$TMPD/fakes
mkdir -p "$FAKES"
# sysrc -c nvidia_gb10_autoload=YES: succeeds only when the test says YES.
cat > "$FAKES/sysrc" <<'EOT'
#!/bin/sh
[ "$1" = -c ] && [ "$2" = nvidia_gb10_autoload=YES ] || exit 2
[ "${TEST_AUTOLOAD:-NO}" = YES ]
EOT
# kldload -n NAME: records the name; loading nvidia marks the module loaded.
cat > "$FAKES/kldload" <<'EOT'
#!/bin/sh
[ "$1" = -n ] || exit 2
echo "$2" >> "$TEST_STATE/loaded"
[ "$2" = nvidia ] && : > "$TEST_STATE/nvidia.loaded"
exit 0
EOT
# sysctl dev.nvidia: the attached nvidia children (lines in $TEST_STATE/dev),
# or "unknown oid" when none is attached or the module is not loaded.
cat > "$FAKES/sysctl" <<'EOT'
#!/bin/sh
[ "$1" = dev.nvidia ] || exit 2
if [ -f "$TEST_STATE/nvidia.loaded" ] && [ -s "$TEST_STATE/dev" ]; then
	cat "$TEST_STATE/dev"
	exit 0
fi
echo "sysctl: unknown oid 'dev.nvidia'" >&2
exit 1
EOT
chmod +x "$FAKES/sysrc" "$FAKES/kldload" "$FAKES/sysctl"

# action <conf>: the one action string of the conf.
action() {
	sed -n 's/^[ 	]*action "\(.*\)";[ 	]*$/\1/p' "$1"
}

# expand <action> <device-name>: devd's expansion of $device-name.
expand() {
	printf '%s\n' "$1" | sed "s/\\\$device-name/\\\$'$2'/g"
}

# run_event <conf> <autoload> <device-name> <dev lines...>: prints the
# modules the rule loaded, space separated.
run_event() {
	_conf=$1
	_auto=$2
	_dev=$3
	shift 3
	_state=$TMPD/state
	rm -rf "$_state"
	mkdir -p "$_state"
	: > "$_state/dev"
	for _l in "$@"; do
		printf '%s\n' "$_l" >> "$_state/dev"
	done
	_act=$(action "$_conf")
	_act=$(printf '%s\n' "$_act" | sed \
	    -e "s#/usr/sbin/sysrc#$FAKES/sysrc#" \
	    -e "s#/sbin/kldload#$FAKES/kldload#g" \
	    -e "s#/sbin/sysctl#$FAKES/sysctl#")
	_act=$(expand "$_act" "$_dev")
	TEST_STATE=$_state TEST_AUTOLOAD=$_auto sh -c "$_act" >/dev/null 2>&1
	if [ -f "$_state/loaded" ]; then
		tr '\n' ' ' < "$_state/loaded" | sed 's/ $//'
	fi
	echo
}

# cases <conf>: the truth table, one "label: got" line per case.
cases() {
	_c=$1
	echo "ampere-attached: $(run_event "$_c" YES vgapci1 'dev.nvidia.0.%parent: vgapci1')"
	echo "turing-refused: $(run_event "$_c" YES vgapci1)"
	echo "autoload-off: $(run_event "$_c" NO vgapci1 'dev.nvidia.0.%parent: vgapci1')"
	echo "vgapci1-refused-vgapci10-attached-event1: $(run_event "$_c" YES vgapci1 'dev.nvidia.0.%parent: vgapci10')"
	echo "vgapci1-refused-vgapci10-attached-event10: $(run_event "$_c" YES vgapci10 'dev.nvidia.0.%parent: vgapci10')"
	echo "two-cards-event-for-the-refused-one: $(run_event "$_c" YES vgapci2 'dev.nvidia.0.%parent: vgapci1' 'dev.nvidia.1.%parent: vgapci3')"
	echo "two-cards-event-for-the-attached-one: $(run_event "$_c" YES vgapci3 'dev.nvidia.0.%parent: vgapci1' 'dev.nvidia.1.%parent: vgapci3')"
}

cat > "$TMPD/want" <<'EOT'
ampere-attached: nvidia nvidia-drm
turing-refused: nvidia
autoload-off: 
vgapci1-refused-vgapci10-attached-event1: nvidia
vgapci1-refused-vgapci10-attached-event10: nvidia nvidia-drm
two-cards-event-for-the-refused-one: nvidia
two-cards-event-for-the-attached-one: nvidia nvidia-drm
EOT

if [ "$(grep -c '^[ 	]*action "' "$CONF")" -ne 1 ]; then
	fail "the conf has not exactly one action"
fi
if [ "$(action "$CONF" | grep -c '\$')" -ne 1 ] \
    || [ "$(action "$CONF" | tr -cd '$' | wc -c | tr -d ' ')" -ne 1 ]; then
	fail "the action holds a \$ other than \$device-name (devd would expand it)"
fi

cases "$CONF" > "$TMPD/got"
if diff -u "$TMPD/want" "$TMPD/got" > "$TMPD/diff"; then
	pass "the real conf: nvidia-drm only for a card with an attached nvidia child"
else
	cat "$TMPD/diff" >&2
	fail "the real conf gives the wrong answers"
fi

# The installed conf and the schema are read by operators and by machines:
# they carry no tracker number.
if grep -n 'Track #' "$HERE/../devd/"*.conf "$HERE/../schema/"*.json > "$TMPD/track.txt" 2>&1; then
	fail "a tracker number is in the operator's text:"
	cat "$TMPD/track.txt" >&2
else
	pass "no tracker number in devd/*.conf or schema/*.json"
fi

# plant NAME SED-EXPRESSION: the mutated conf must turn the table red.
plant() {
	_name=$1
	_expr=$2
	sed -e "$_expr" "$CONF" > "$TMPD/plant.conf"
	if cmp -s "$CONF" "$TMPD/plant.conf"; then
		fail "plant $_name: substitution did not change the conf"
		return
	fi
	cases "$TMPD/plant.conf" > "$TMPD/plant.got"
	if cmp -s "$TMPD/want" "$TMPD/plant.got"; then
		fail "plant $_name survived"
	else
		killed=$((killed + 1))
		pass "plant killed: $_name"
	fi
}

plant drop-w "s# -q -w -F # -q -F #"
plant drop-sysctl-check "s# \&\& /sbin/sysctl dev.nvidia 2>/dev/null | /usr/bin/grep -q -w -F '%parent: '\$device-name##"
plant swap-order "s# \&\& /sbin/kldload -n nvidia-drm\";#\";#; s#/sbin/kldload -n nvidia \&\& /sbin/sysctl#/sbin/kldload -n nvidia \&\& /sbin/kldload -n nvidia-drm \&\& /sbin/sysctl#"
plant variable-inside-single-quotes "s#'%parent: '\$device-name#'%parent: \$device-name'#"
plant drop-nvidia-load "s# \&\& /sbin/kldload -n nvidia \&\& # \&\& #"
plant drop-autoload-check "s#/usr/sbin/sysrc -c nvidia_gb10_autoload=YES \&\& ##"

if [ "$fails" -ne 0 ]; then
	echo "devd_rule_test.sh: FAIL ($fails failures)" >&2
	exit 1
fi
echo "devd_rule_test.sh: PASS ($killed plants killed)"

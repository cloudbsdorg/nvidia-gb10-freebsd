#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# rc_nvidia_linux_test.sh - rc.d/nvidia_linux decides when the Linux provider
# modules load (Track #2363): the truth table of nvidia_linux_wanted, the
# start path with stubbed kldstat and kldload, and plants (a mutated script
# must turn the table red). No kldload of the real kernel, no root.
set -u
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
export PATH
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
RC=$HERE/../rc.d/nvidia_linux
WORK=${GB10_WORK:-$HOME/work/gb10}
mkdir -p "$WORK/tmp"
TMPD=$(mktemp -d "$WORK/tmp/rc_nvidia_linux_test.XXXXXXXX") || exit 1
trap 'rm -rf "$TMPD"' EXIT
fails=0
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }
pass() { echo "PASS: $*"; }

# table <script>: prints one line per case, "mode linux loaded -> answer"
table() {
	NVIDIA_LINUX_RC_SOURCE_ONLY=1 sh -c '
		. "$1"
		for mode in AUTO YES NO yes auto-x; do
			for lin in YES NO; do
				for ld in 0 1; do
					echo "$mode $lin $ld $(nvidia_linux_wanted $mode $lin $ld)"
				done
			done
		done' sh "$1"
}

cat > "$TMPD/want" <<'EOT'
AUTO YES 0 no-native
AUTO YES 1 yes
AUTO NO 0 no
AUTO NO 1 no
YES YES 0 yes
YES YES 1 yes
YES NO 0 yes
YES NO 1 yes
NO YES 0 no
NO YES 1 no
NO NO 0 no
NO NO 1 no
yes YES 0 yes
yes YES 1 yes
yes NO 0 yes
yes NO 1 yes
auto-x YES 0 no
auto-x YES 1 no
auto-x NO 0 no
auto-x NO 1 no
EOT

sh -n "$RC" && pass "rc.d/nvidia_linux parses" || fail "rc.d/nvidia_linux has a syntax error"
table "$RC" > "$TMPD/got" 2>"$TMPD/err"
if cmp -s "$TMPD/want" "$TMPD/got"; then pass "truth table"; else fail "truth table differs: $(diff "$TMPD/want" "$TMPD/got" | head -4 | tr '\n' ' ')"; fi

# plants: each mutation must turn the table red
mutate() { # name sed-expr
	sed "$2" "$RC" > "$TMPD/mut.sh"
	table "$TMPD/mut.sh" > "$TMPD/mgot" 2>/dev/null
	if cmp -s "$TMPD/want" "$TMPD/mgot"; then fail "plant $1: the table did not change"; else pass "plant $1 turns the table red"; fi
}
mutate auto-ignores-loaded 's/\[ "\$3" = 1 \] && echo yes || echo no/echo yes/'
mutate no-means-yes 's/\[Nn\]\[Oo\]) echo no/[Nn][Oo]) echo yes/'
mutate auto-ignores-linux 's/\*) echo no ;;/*) echo yes ;;/'
mutate unknown-means-auto 's/\[Aa\]\[Uu\]\[Tt\]\[Oo\])$/*)/'

# start path with stubs: kldstat -q -m <mod> succeeds for the modules listed
# in $TMPD/loaded, kldload logs its argument.
mkdir -p "$TMPD/bin"
cat > "$TMPD/bin/kldstat" <<'EOT'
#!/bin/sh
# kldstat -q -m NAME
while [ $# -gt 0 ]; do case $1 in -m) m=$2; shift ;; esac; shift; done
grep -qx "$m" "$STUB_LOADED"
EOT
cat > "$TMPD/bin/kldload" <<'EOT'
#!/bin/sh
echo "$1" >> "$STUB_LOG"
[ -z "${STUB_KLDLOAD_FAIL:-}" ]
EOT
chmod +x "$TMPD/bin/kldstat" "$TMPD/bin/kldload"
run_start() { # mode linux_enable loaded...  (STUB_KLDLOAD_FAIL=1 makes kldload fail)
	_mode=$1; _lin=$2; shift 2
	: > "$TMPD/log"; : > "$TMPD/loaded"
	for m in "$@"; do echo "$m" >> "$TMPD/loaded"; done
	STUB_LOADED=$TMPD/loaded STUB_LOG=$TMPD/log PATH=$TMPD/bin:$PATH NVIDIA_LINUX_RC_SOURCE_ONLY=1 \
	    sh -c '. "$1"; nvidia_linux_mode=$2; linux_enable=$3; nvidia_linux_start' sh "$RC" "$_mode" "$_lin" > "$TMPD/start.out" 2>&1
	tr '\n' ' ' < "$TMPD/log"
}
r=$(run_start AUTO YES nvidia nvidia_modeset)
[ "$r" = "nvidia_linux nvidia_modeset_linux " ] && pass "AUTO with the Linuxulator on and both drivers loaded loads both providers" || fail "AUTO/YES both loaded: got [$r]"
r=$(run_start AUTO YES nvidia)
[ "$r" = "nvidia_linux " ] && pass "AUTO loads only the provider of a loaded driver" || fail "AUTO/YES nvidia only: got [$r]"
r=$(run_start AUTO NO nvidia nvidia_modeset)
[ -z "$r" ] && pass "AUTO with the Linuxulator off loads nothing" || fail "AUTO/NO: got [$r]"
# rc.d/linux enables itself through checkyesno(), which also takes TRUE, ON and 1 (any case):
# AUTO must follow the same rule
for _v in TRUE ON 1 true on Yes; do
	r=$(run_start AUTO "$_v" nvidia nvidia_modeset)
	[ "$r" = "nvidia_linux nvidia_modeset_linux " ] && pass "AUTO with linux_enable=$_v loads both providers" || fail "AUTO/linux_enable=$_v: got [$r]"
done
for _v in NO FALSE OFF 0 maybe ""; do
	r=$(run_start AUTO "$_v" nvidia nvidia_modeset)
	[ -z "$r" ] && pass "AUTO with linux_enable=[$_v] loads nothing" || fail "AUTO/linux_enable=[$_v]: got [$r]"
done
# an unparsable linux_enable warns once per start (checkyesno), not once per provider
run_start AUTO maybe nvidia nvidia_modeset > /dev/null
_n=$(grep -c 'not set properly' "$TMPD/start.out")
[ "$_n" = 1 ] && pass "an unparsable linux_enable is warned about once" || fail "linux_enable=maybe: $_n warning lines (want 1): $(head -3 "$TMPD/start.out" | tr '\n' ' ')"
# plant: deciding per provider (inside nvidia_linux_load_one) warns twice
sed 's/^	_want=\$(nvidia_linux_wanted/	nvidia_linux_decide_linux\n	_want=$(nvidia_linux_wanted/' "$RC" > "$TMPD/plant-twice.sh"
if cmp -s "$RC" "$TMPD/plant-twice.sh"; then fail "plant twice: the sed changed nothing"; else
	: > "$TMPD/loaded"; echo nvidia > "$TMPD/loaded"; echo nvidia_modeset >> "$TMPD/loaded"
	STUB_LOADED=$TMPD/loaded STUB_LOG=$TMPD/log PATH=$TMPD/bin:$PATH NVIDIA_LINUX_RC_SOURCE_ONLY=1 \
	    sh -c '. "$1"; nvidia_linux_mode=AUTO; linux_enable=maybe; nvidia_linux_start' sh "$TMPD/plant-twice.sh" > "$TMPD/twice.out" 2>&1
	[ "$(grep -c 'not set properly' "$TMPD/twice.out")" -ge 2 ] && pass "plant: deciding per provider warns twice (the row above can fail)" || fail "plant twice: the mutant did not warn twice: $(head -3 "$TMPD/twice.out" | tr '\n' ' ')"
fi
# plant: the old test of the raw string must turn the TRUE/ON/1 rows red
sed 's/checkyesno linux_enable && nvidia_linux_linux_on=YES/case $linux_enable in [Yy][Ee][Ss]) nvidia_linux_linux_on=YES ;; esac/' "$RC" > "$TMPD/plant-raw.sh"
if cmp -s "$RC" "$TMPD/plant-raw.sh"; then fail "plant checkyesno: the sed changed nothing"; else
	: > "$TMPD/log"; echo nvidia > "$TMPD/loaded"
	STUB_LOADED=$TMPD/loaded STUB_LOG=$TMPD/log PATH=$TMPD/bin:$PATH NVIDIA_LINUX_RC_SOURCE_ONLY=1 \
	    sh -c '. "$1"; nvidia_linux_mode=AUTO; linux_enable=TRUE; nvidia_linux_start' sh "$TMPD/plant-raw.sh" > /dev/null 2>&1
	[ -z "$(cat "$TMPD/log")" ] && pass "plant: a raw YES test skips the provider for linux_enable=TRUE (the rows above would fail)" || fail "plant: the raw-string mutant still loaded the provider"
fi
r=$(run_start AUTO YES)
[ -z "$r" ] && pass "AUTO with no GPU driver loaded loads nothing (the GPU stack is not pulled in)" || fail "AUTO/YES none: got [$r]"
r=$(run_start NO YES nvidia nvidia_modeset)
[ -z "$r" ] && pass "NO loads nothing" || fail "NO: got [$r]"

# a provider already loaded (kld_list, loader.conf) is not loaded twice
r=$(run_start AUTO YES nvidia nvidia_linux)
[ -z "$r" ] && pass "an already loaded provider is not loaded again" || fail "double load: got [$r]"
# an unknown mode loads nothing
r=$(run_start OFF YES nvidia nvidia_modeset)
[ -z "$r" ] && pass "an unknown mode loads nothing" || fail "unknown mode OFF: got [$r]"
# the unknown-mode warning is printed once and names the valid values
run_start OFF YES nvidia nvidia_modeset > /dev/null
_n=$(grep -c 'AUTO, YES or NO' "$TMPD/start.out")
[ "$_n" = 1 ] && pass "the unknown-mode warning is printed once and names AUTO, YES or NO" || fail "unknown mode: $_n warning lines (want 1): $(head -3 "$TMPD/start.out")"
# AUTO that skips the core's provider because the driver is not loaded says so ...
run_start AUTO YES > /dev/null
grep -q 'not loaded: skipping nvidia_linux ' "$TMPD/start.out" && pass "AUTO says when it skips nvidia_linux because nvidia is not loaded" || fail "AUTO skipped silently: $(head -2 "$TMPD/start.out")"
# ... but not for the modeset pair: a compute-only host has no nvidia_modeset
run_start AUTO YES nvidia > /dev/null
grep -q 'skipping nvidia_modeset_linux' "$TMPD/start.out" && fail "AUTO nags about nvidia_modeset on a compute-only host" || pass "AUTO is silent about nvidia_modeset_linux when nvidia_modeset is not loaded"
# ... and says nothing when the Linuxulator is off
run_start AUTO NO > /dev/null
[ ! -s "$TMPD/start.out" ] && pass "AUTO with the Linuxulator off is silent" || fail "AUTO with the Linuxulator off printed: $(head -2 "$TMPD/start.out")"
# a decision that is no for another reason prints nothing, whatever the reason token says elsewhere
NVIDIA_LINUX_RC_SOURCE_ONLY=1 sh -c '. "$1"; nvidia_linux_wanted() { echo no; }; nvidia_linux_mode=AUTO; linux_enable=YES; nvidia_linux_load_one nvidia_linux nvidia 1' sh "$RC" > "$TMPD/other.out" 2>&1
[ ! -s "$TMPD/other.out" ] && pass "a plain no from nvidia_linux_wanted prints nothing" || fail "a plain no printed: $(head -1 "$TMPD/other.out")"
# kldload failure is reported by start
export STUB_KLDLOAD_FAIL=1
STUB_LOADED=$TMPD/loaded; echo nvidia > "$TMPD/loaded"; : > "$TMPD/log"
STUB_LOADED=$TMPD/loaded STUB_LOG=$TMPD/log PATH=$TMPD/bin:$PATH NVIDIA_LINUX_RC_SOURCE_ONLY=1 \
    sh -c '. "$1"; nvidia_linux_mode=YES; linux_enable=YES; nvidia_linux_start' sh "$RC" >/dev/null 2>&1 \
    && fail "start reported success although kldload failed" || pass "start fails when kldload fails"
unset STUB_KLDLOAD_FAIL

# the script reads rc.conf.d/linux (where linux_enable may live) as well as its own: load_rc_config linux
# comes before load_rc_config $name, which comes before run_rc_command
rc_loads_linux() {	# rc_loads_linux <script>
	_a=$(grep -n '^load_rc_config linux$' "$1" | head -1 | cut -d: -f1)
	_b=$(grep -n '^load_rc_config \$name$' "$1" | head -1 | cut -d: -f1)
	_c=$(grep -n '^run_rc_command' "$1" | head -1 | cut -d: -f1)
	[ -n "$_a" ] && [ -n "$_b" ] && [ -n "$_c" ] && [ "$_a" -lt "$_b" ] && [ "$_b" -lt "$_c" ]
}
rc_loads_linux "$RC" && pass "the script loads the rc.conf.d of linux before its own" || fail "the script does not load rc.conf.d/linux (linux_enable may be set there)"
grep -v '^load_rc_config linux$' "$RC" > "$TMPD/plant-nolinuxconf.sh"
rc_loads_linux "$TMPD/plant-nolinuxconf.sh" && fail "plant: a script that never loads rc.conf.d/linux passed" || pass "plant: a script that never loads rc.conf.d/linux is refused"

if [ "$fails" -ne 0 ]; then echo "rc_nvidia_linux_test: $fails FAILED" >&2; exit 1; fi
echo "rc_nvidia_linux_test: all passed"

#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# Keep the one-command install documentation and the make help in agreement,
# keep the manual build sequence in one document, and reject dead local links.

set -u
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
export PATH
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
base=${TMPDIR:-}
case $base in
# Never /tmp: it is shared and world-writable; scratch stays in the checkout.
''|/tmp|/tmp/*) base=$repo/work/tmp ;;
/*) ;;
*) base=$repo/$base ;;
esac
mkdir -p -- "$base" || exit 1
S=$(mktemp -d "$base/readme-install-doc.XXXXXX") || exit 1
trap 'rm -rf -- "${S:?}"' EXIT
trap 'exit 130' HUP INT TERM
fail=0
ok() { printf 'ok    %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1"; fail=$((fail + 1)); }

for need in README.md docs/MANUAL-BUILD.md docs/llm.md scripts/make.sh; do
	if [ -f "$repo/$need" ] && [ -r "$repo/$need" ]; then
		ok "$need exists and is readable"
	else
		bad "$need is missing or unreadable"
	fi
done
set -- "$repo"/docs/*.md
if [ -f "$1" ]; then
	ok "docs/*.md matches at least one file"
else
	bad "docs/*.md matches no file"
fi

if (cd "$repo" && make -s help) > "$S/help"; then
	ok "make help is available"
else
	bad "make help failed"
fi

awk '
/^## Install[[:space:]]*$/ { inside = 1; next }
inside && /^## / { exit }
inside { print }
' "$repo/README.md" > "$S/install"
if [ -s "$S/install" ]; then
	ok "README has one top-level Install section"
else
	bad "README has no top-level section named exactly Install"
fi

# Normalize Markdown quoting so both fenced commands and inline references
# expose the same make targets and variable assignments.
sed 's/`/ /g' "$S/install" > "$S/install.words"
awk '
{
	for (i = 1; i <= NF; i++) {
		if ($i == "make" && (i + 1) <= NF && $(i + 1) ~ /^[a-z][a-z-]*$/)
			print $(i + 1)
	}
}
' "$S/install.words" | sort -u > "$S/targets"
while IFS= read -r target; do
	[ -n "$target" ] || continue
	if awk -v target="$target" '
	$1 == "make" && $2 == target { found = 1 }
	END { exit found ? 0 : 1 }
	' "$S/help"; then
		ok "Install target $target is in make help"
	else
		bad "Install target $target is not in make help"
	fi
done < "$S/targets"

awk '
{
	for (i = 1; i <= NF; i++) {
		if ($i ~ /^[A-Z][A-Z0-9_]*=/) {
			name = $i
			sub(/=.*/, "", name)
			print name
		}
	}
}
' "$S/install.words" | sort -u > "$S/variables"
while IFS= read -r variable; do
	[ -n "$variable" ] || continue
	# Whole word: a help word starts with the name and an equals sign, after
	# any opening punctuation; a longer name that merely ends in it is not it.
	if awk -v v="$variable" '
	{
		for (i = 1; i <= NF; i++) {
			w = $i
			sub(/^[^A-Za-z0-9_]+/, "", w)
			if (index(w, v "=") == 1) found = 1
		}
	}
	END { exit found ? 0 : 1 }
	' "$S/help"; then
		ok "Install variable $variable is in make help"
	else
		bad "Install variable $variable is not in make help"
	fi
done < "$S/variables"

# The expected command comes from make help: the target whose help line says
# it runs the prerequisites, the build and the install, plus the NVIDIA
# licence setting help names.
help_install=$(awk '
$1 == "make" && /prerequisites/ && /build/ && /install/ { print $1 " " $2; exit }
' "$S/help")
help_licence=$(awk '
{
	for (i = 1; i <= NF; i++) {
		if ($i ~ /^ACCEPT_[A-Z_]*LICENSE=1$/ && $i ~ /NVIDIA/) {
			print $i
			exit
		}
	}
}
' "$S/help")
if [ -n "$help_install" ] && [ -n "$help_licence" ]; then
	canonical="$help_install $help_licence"
	if awk -v canonical="$canonical" -v t="$help_install" '
	{
		line = $0
		gsub(/`/, "", line)
		sub(/^[[:space:]]+/, "", line)
		sub(/[[:space:]]+$/, "", line)
		if (index(line, t) == 1 && (length(line) == length(t) || substr(line, length(t) + 1, 1) ~ /[[:space:]]/)) {
			count++
			if (line != canonical) {
				printf "wrong install command: %s\n", line > "/dev/stderr"
				wrong++
			}
		}
	}
	END {
		if (count != 1 || wrong) exit 1
	}
	' "$S/install" 2> "$S/install-command.err"; then
		ok "Install uses exactly the make help command: $canonical"
	else
		detail=$(cat "$S/install-command.err")
		bad "Install must contain exactly one command '$canonical'; $detail"
	fi
else
	bad "make help does not identify the install target and NVIDIA licence setting"
fi

# The manual build sequence is this ordered script list.  A file contains it
# when it runs these scripts ("sh scripts/NAME" on a line, any environment
# prefix allowed) in this order; repeated build-shim invocations between the
# names do not reset the match, and prose mentions do not count.
manual_list="prepare-tree.sh build-rmcore.sh build-shim.sh build-stubs.sh build-firmware.sh"
: > "$S/manual-files"
for doc in "$repo/README.md" "$repo"/docs/*.md; do
	if [ ! -r "$doc" ]; then
		bad "cannot read ${doc#$repo/} for the manual sequence scan"
		continue
	fi
	if awk -v list="$manual_list" '
	BEGIN { n = split(list, name, " "); pos = 1 }
	pos <= n && match($0, "(^|[[:space:]])sh scripts/" name[pos] "([[:space:];]|$)") { pos++ }
	END { exit pos > n ? 0 : 1 }
	' "$doc"; then
		printf '%s\n' "${doc#$repo/}" >> "$S/manual-files"
	fi
done
manual_count=$(wc -l < "$S/manual-files" | tr -d ' ')
if [ "$manual_count" = 1 ]; then
	ok "the manual build sequence occurs in exactly one Markdown file: $(cat "$S/manual-files")"
else
	bad "the manual build sequence must occur in exactly one Markdown file, found $manual_count: $(tr '\n' ' ' < "$S/manual-files")"
fi

# Heading anchors of a Markdown file, one per line, as the code host makes
# them: lower case, backticks and punctuation removed, spaces to hyphens,
# a repeated heading numbered.  Headings inside code fences do not count.
anchors_of() {
	awk '
	/^```/ { fence = !fence; next }
	fence { next }
	/^#+[[:space:]]/ {
		h = $0
		sub(/^#+[[:space:]]+/, "", h)
		h = tolower(h)
		gsub(/`/, "", h)
		gsub(/[^a-z0-9 _-]/, "", h)
		gsub(/ /, "-", h)
		n = seen[h]++
		print n ? h "-" n : h
	}
	' "$1"
}

# Every inline Markdown target in README.md and docs/*.md, outside code
# fences.  External URLs are skipped.  A local target must exist; a
# #fragment, on this file or another Markdown file, must be a heading there.
: > "$S/dead-links"
for doc in "$repo/README.md" "$repo"/docs/*.md; do
	if [ ! -r "$doc" ]; then
		printf '%s: unreadable\n' "${doc#$repo/}" >> "$S/dead-links"
		continue
	fi
	dir=$(dirname -- "$doc")
	awk '
	/^```/ { fence = !fence; next }
	fence { next }
	{
		rest = $0
		while (match(rest, /\[[^]]*\]\([^)]*\)/)) {
			link = substr(rest, RSTART, RLENGTH)
			sub(/^.*\]\(/, "", link)
			sub(/\)$/, "", link)
			print link
			rest = substr(rest, RSTART + RLENGTH)
		}
	}
	' "$doc" | while IFS= read -r link; do
		case $link in
		''|[a-zA-Z]*:*|'//'*) continue ;;
		esac
		path=${link%%#*}
		frag=
		case $link in *'#'*) frag=${link#*#} ;; esac
		if [ -z "$path" ]; then
			target=$doc
		else
			target=$dir/$path
		fi
		if [ ! -e "$target" ]; then
			printf '%s: %s\n' "${doc#$repo/}" "$link"
			continue
		fi
		if [ -n "$frag" ]; then
			case $target in
			*.md) anchors_of "$target" | grep -Fx -- "$frag" >/dev/null || printf '%s: %s (no such heading)\n' "${doc#$repo/}" "$link" ;;
			esac
		fi
	done >> "$S/dead-links"
done
if [ -s "$S/dead-links" ]; then
	bad "dead local links: $(tr '\n' ';' < "$S/dead-links")"
else
	ok "every local link in README.md and docs/*.md exists, and every #fragment is a heading"
fi

# No personal path in the documents.  Fail closed: a file that cannot be read
# is a failure, not a pass.  The needles are one list, tests/lib/personal-paths.txt,
# which tests/make_install_flow_test.sh reads too.  Documents also may not use
# "~/" at all (they say GB10_WORK or work/).
needles=$repo/tests/lib/personal-paths.txt
# personal_hit FILE: 0 when FILE holds a needle or a "~/"; 1 when clean; 2 on error.
personal_hit() {
	grep -F -f "$needles" -e '~/' "$1" >/dev/null 2>&1
}
scan_bad=
[ -s "$needles" ] || scan_bad=" tests/lib/personal-paths.txt(missing)"
for f in "$repo/README.md" "$repo"/docs/*.md "$repo"/man/*.1 "$repo"/man/*.4 "$repo"/lib/libnvrm/man/*; do
	[ -e "$f" ] || { scan_bad="$scan_bad ${f#$repo/}(missing)"; continue; }
	if [ ! -r "$f" ]; then
		scan_bad="$scan_bad ${f#$repo/}(unreadable)"
		continue
	fi
	personal_hit "$f"
	case $? in
	1) ;;
	0) scan_bad="$scan_bad ${f#$repo/}(personal path)" ;;
	*) scan_bad="$scan_bad ${f#$repo/}(scan error)" ;;
	esac
done
if [ -z "$scan_bad" ]; then
	ok "no personal path in the documents and manual pages"
else
	bad "personal-path scan failed:$scan_bad"
fi
# The scan itself must catch each kind of path, for any account name.
# (Built in pieces so this file holds no needle itself.)
dollar=$
for sample in "/ho$(printf me)/anyone/gb10" "/Us$(printf ers)/anyone/gb10" "${dollar}HOME/wo""rk/x" '~'"/wo""rk/x" '~/notes'; do
	printf 'cd %s\n' "$sample" > "$S/sample.md"
	if personal_hit "$S/sample.md"; then
		ok "personal-path scan catches $sample"
	else
		bad "personal-path scan misses $sample"
	fi
done
printf 'cd /usr/local/share\n' > "$S/sample.md"
if personal_hit "$S/sample.md"; then
	bad "personal-path scan flags a system path"
else
	ok "personal-path scan passes a system path"
fi

# --- statements the README makes about what the code does ---------------
readme=$repo/README.md
make_sh=$repo/scripts/make.sh
check() {  # check DESCRIPTION COMMAND...
	_d=$1
	shift
	if "$@"; then ok "$_d"; else bad "$_d"; fi
}
# Both fail on a missing or unreadable file: only grep's own answer counts
# (0 found, 1 not found; 2 is an error and fails either way).
no_match() { grep -E -- "$1" "$2" >/dev/null 2>&1; [ $? = 1 ]; }
has() { grep -F -- "$1" "$2" >/dev/null 2>&1; [ $? = 0 ]; }

# The doas setup block, run in /bin/sh against a scratch file.
check "README doas setup has no <user> placeholder" no_match '<user>' "$readme"
check "README doas setup never overwrites doas.conf with a single >" no_match "[^>]> */usr/local/etc/doas.conf" "$readme"
awk '
/^```sh/ { buf = ""; inb = 1; hit = 0; next }
/^```/ { if (inb && hit) { printf "%s", buf; exit } inb = 0; next }
inb { buf = buf $0 "\n"; if (index($0, "pkg install -y doas git")) hit = 1 }
' "$readme" | grep -v 'pkg install' > "$S/doas-block"
if [ -s "$S/doas-block" ] && grep -F '/usr/local/etc/doas.conf' "$S/doas-block" >/dev/null; then
	ok "README has a doas setup block"
	d=$S/doas
	mkdir -p "$d"
	# run_doas LOGNAME-BODY [SED-EXPR [ENV-BUSER]]: run the block on
	# $d/doas.conf in /bin/sh with a logname function, after an optional sed
	# edit of the block (the documented "set buser" recovery).  A non-empty
	# ENV-BUSER is exported as buser, to show the environment is ignored; with
	# none, buser is removed from the environment.  Returns the block's status.
	run_doas() {
		{
			echo "logname() { $1; }"
			sed "s#/usr/local/etc/doas.conf#$d/doas.conf#g" "$S/doas-block"
		} > "$d/run.sh.0"
		if [ -n "${2:-}" ]; then
			sed "$2" "$d/run.sh.0" > "$d/run.sh"
		else
			cp "$d/run.sh.0" "$d/run.sh"
		fi
		if [ -n "${3:-}" ]; then
			env buser="$3" /bin/sh "$d/run.sh" > "$d/out" 2>&1
		else
			env -u buser /bin/sh "$d/run.sh" > "$d/out" 2>&1
		fi
	}
	rm -f "$d/doas.conf"
	run_doas 'echo tester'
	if [ $? = 0 ] && [ "$(cat "$d/doas.conf")" = 'permit tester' ]; then
		ok "doas setup creates doas.conf with the user's rule"
	else
		bad "doas setup does not create doas.conf with exactly the user's rule"
	fi
	printf 'permit keepme\n' > "$d/doas.conf"
	run_doas 'echo tester'
	if [ "$(cat "$d/doas.conf")" = "$(printf 'permit keepme\npermit tester')" ]; then
		ok "doas setup appends after a file that ends in a newline"
	else
		bad "doas setup mangles a doas.conf that ends in a newline"
	fi
	printf 'permit keepme' > "$d/doas.conf"
	run_doas 'echo tester'
	if [ "$(cat "$d/doas.conf")" = "$(printf 'permit keepme\npermit tester')" ]; then
		ok "doas setup keeps the last rule intact when the file has no trailing newline"
	else
		bad "doas setup glues the new rule to a last line without a newline: $(cat "$d/doas.conf")"
	fi
	printf 'permit keepme\npermit tester\n' > "$d/doas.conf"
	run_doas 'echo tester'
	run_doas 'echo tester'
	if [ "$(grep -c '^permit tester$' "$d/doas.conf")" = 1 ] && grep -qx 'permit keepme' "$d/doas.conf"; then
		ok "doas setup adds no duplicate rule and keeps the others"
	else
		bad "doas setup duplicates an existing rule or drops another"
	fi
	# An environment buser is ignored: the block takes the name from logname.
	for envname in 'nopass x' ':wheel' root evil; do
		printf 'permit keepme\n' > "$d/doas.conf"
		run_doas 'echo tester' '' "$envname"
		if [ $? = 0 ] && [ "$(cat "$d/doas.conf")" = "$(printf 'permit keepme\npermit tester')" ]; then
			ok "doas setup ignores buser='$envname' from the environment"
		else
			bad "doas setup lets buser='$envname' from the environment decide: $(cat "$d/doas.conf")"
		fi
	done
	# Refusals leave the file alone, say why, and exit non-zero.
	refuse_case() {  # refuse_case DESCRIPTION LOGNAME-BODY [SED-EXPR]
		printf 'permit keepme\n' > "$d/doas.conf"
		run_doas "$2" "${3:-}"
		_st=$?
		if [ "$_st" != 0 ] && [ "$(cat "$d/doas.conf")" = 'permit keepme' ] && [ -s "$d/out" ]; then
			ok "doas setup refuses ($1): exit $_st, message, file unchanged"
		else
			bad "doas setup does not refuse cleanly ($1): exit $_st, file: $(cat "$d/doas.conf")"
		fi
	}
	refuse_case 'logname fails' 'return 1'
	refuse_case 'logname is root' 'echo root'
	refuse_case 'name has a space' 'echo "nopass x"'
	refuse_case 'name starts with a colon' 'echo ":wheel"'
	refuse_case 'name starts with a dash' 'echo "-x"'
	refuse_case 'name starts with a dot' 'echo ".x"'
	refuse_case 'name has a newline' "printf 'bob\\npermit nopass mallory\\n'"
	refuse_case 'name has a shell character' 'echo "a;b"'
	# The documented recovery: replace the buser line with a name.
	rm -f "$d/doas.conf"
	run_doas 'echo root' 's/^buser=.*/buser=tester/'
	if [ $? = 0 ] && [ "$(cat "$d/doas.conf")" = 'permit tester' ]; then
		ok "doas setup: editing the buser line works when logname is root"
	else
		bad "doas setup: editing the buser line does not write the rule: $(cat "$d/doas.conf" 2>&1)"
	fi
	# An existing rule is matched literally: a dot is not a wildcard.
	printf 'permit testxr\n' > "$d/doas.conf"
	run_doas 'echo test.r'
	if [ "$(cat "$d/doas.conf")" = "$(printf 'permit testxr\npermit test.r')" ]; then
		ok "doas setup matches an existing rule literally"
	else
		bad "doas setup treats the user name as a regex: $(cat "$d/doas.conf")"
	fi
else
	bad "README has no doas setup block naming /usr/local/etc/doas.conf"
fi

# Installed: the quoted next steps are what make.sh prints, and the firmware
# setting sits beside the load instructions.
awk '/^### Installed/ { i = 1; next } i && /^### / { exit } i' "$readme" > "$S/installed"
awk '/^### Blocked/ { i = 1; next } i && /^##/ { exit } i' "$readme" > "$S/blocked"
# printed_whole_line STEP [FILE]: 0 when a printf or echo line of FILE (default
# make.sh) prints STEP as a whole output line.  That is: STEP sits in the
# quoted text with a quote (' or ") or a \n escape just before it and a quote
# or a \n escape just after it.  A longer string that only starts or ends with
# STEP, or a string on a line without printf or echo, does not count; a string
# continued on the next physical line is not seen (fails closed).
printed_whole_line() {
	awk -v p="$1" '
	/printf|echo/ {
		line = $0
		off = 0
		while ((i = index(substr(line, off + 1), p)) > 0) {
			st = off + i
			before = substr(line, st - 2, 2)
			b1 = substr(line, st - 1, 1)
			after = substr(line, st + length(p), 2)
			a1 = substr(line, st + length(p), 1)
			if ((b1 == "\047" || b1 == "\042" || before == "\\n") && (a1 == "\047" || a1 == "\042" || after == "\\n")) f = 1
			off = st
		}
	}
	END { exit f ? 0 : 1 }' "${2:-$make_sh}"
}
# Fixtures: the helper accepts each way make.sh may print a whole line and
# rejects a step that is only part of a longer string.
pw=$S/printed
accept_cases="echo 'STEP one'|printf 'STEP one\n'|printf '%s\n' 'STEP one'|printf 'a\nSTEP one\nb\n'|printf 'a\nSTEP one'|printf \"su root -c 'STEP one'\\n\""
reject_cases="x='STEP one more'|echo 'the STEP one'|echo 'STEP one more'|STEP one|echo 'xSTEP one'"
oldifs=$IFS
IFS='|'
for c in $accept_cases; do
	printf '%s\n' "$c" | sed 's/STEP one/next-step/' > "$pw"
	if printed_whole_line next-step "$pw"; then ok "printed_whole_line accepts: $c"; else bad "printed_whole_line rejects: $c"; fi
done
for c in $reject_cases; do
	printf '%s\n' "$c" | sed 's/STEP one/next-step/' > "$pw"
	if printed_whole_line next-step "$pw"; then bad "printed_whole_line accepts: $c"; else ok "printed_whole_line rejects: $c"; fi
done
IFS=$oldifs
sed -n 's/^next: //p' "$S/installed" > "$S/next-lines"
[ -s "$S/next-lines" ] || bad "README Installed has no quoted next: lines"
# The quoted examples are compared with what make.sh printed in a test run: the
# flow test's planted install (blocked and installed output) and its next steps
# for a doas user (a live load: a DESTDIR install stages, it loads nothing).
mkdir -p "$S/samples"
# Sample-only mode of the flow test: it runs the planted blocked install, the
# planted install and the doas next steps, and exits non-zero if any of them
# misbehaves.  Its other checks are its own business.
if GB10_FLOW_SAMPLES_ONLY=1 GB10_FLOW_SAMPLES=$S/samples sh "$repo/tests/make_install_flow_test.sh" > "$S/flow.log" 2>&1 \
    && [ -s "$S/samples/blocked.out" ] && [ -s "$S/samples/installed.out" ] \
    && [ -s "$S/samples/next-doas.out" ] && [ -s "$S/samples/next-note.out" ]; then
	ok "the planted blocked run, install and next steps ran and wrote their output"
else
	bad "the planted runs behind the quoted output failed: $(tail -n 3 "$S/flow.log" | tr '\n' ' ')"
fi
while IFS= read -r nl; do
	[ -n "$nl" ] || continue
	if sed 's/^/next: /' "$S/samples/next-doas.out" 2>/dev/null | grep -qxF -- "next: $nl"; then
		ok "Installed next step is what make.sh printed: $nl"
	else
		bad "Installed next step is not what make.sh printed: $nl"
	fi
done < "$S/next-lines"
# The one quoted line that is not prefixed is the boot-load note.
grep -v -e '^next: ' -e '^```' "$S/installed" | grep -F 'make configure YES=1' > "$S/note-lines"
if [ -s "$S/note-lines" ] && [ "$(cat "$S/note-lines")" = "$(cat "$S/samples/next-note.out" 2>/dev/null)" ]; then
	ok "Installed quotes the boot-load note as make.sh printed it"
else
	bad "Installed does not quote the boot-load note as make.sh printed it"
fi
# README order: the firmware step comes before the kldload step.
_fwl=$(grep -n 'EnableGpuFirmware=1' "$S/next-lines" | head -n 1 | cut -d: -f1)
_kll=$(grep -n 'kldload' "$S/next-lines" | head -n 1 | cut -d: -f1)
if [ -n "$_fwl" ] && [ -n "$_kll" ] && [ "$_fwl" -lt "$_kll" ]; then
	ok "README Installed quotes the firmware step before the kldload step"
else
	bad "README Installed does not quote the firmware step before the kldload step"
fi
# The other quoted lines (not next:) must be lines make.sh printed.
grep -E '^install: ' "$S/installed" > "$S/install-lines"
[ -s "$S/install-lines" ] || bad "README Installed has no quoted install: lines"
while IFS= read -r il; do
	[ -n "$il" ] || continue
	if grep -qxF -- "$il" "$S/samples/installed.out" 2>/dev/null; then
		ok "Installed line is what make.sh printed: $il"
	else
		bad "Installed line is not what make.sh printed: $il"
	fi
done < "$S/install-lines"
check "README Installed says the root tool in the kldload line is the one you have" has 'root tool in that line is the one' "$S/installed"
check "README Installed puts EnableGpuFirmware=1 with the load instructions" has 'hw.nvidia.registry.EnableGpuFirmware=1' "$S/installed"
grep -v '^next: ' "$readme" > "$S/readme-unquoted"
check "README never hardcodes doas for kenv or kldload, in code or inline, outside the quoted output" no_match 'doas +(kenv|kldload)' "$S/readme-unquoted"

# Blocked: every quoted line is a line make.sh printed in the test run.
awk '/^```text$/ { i = 1; next } /^```$/ { i = 0 } i' "$S/blocked" > "$S/blocked-lines"
[ -s "$S/blocked-lines" ] || bad "README Blocked quotes no output"
while IFS= read -r bl; do
	[ -n "$bl" ] || continue
	if grep -qxF -- "$bl" "$S/samples/blocked.out" 2>/dev/null; then
		ok "Blocked line is what make.sh printed: $bl"
	else
		bad "Blocked line is not what make.sh printed: $bl"
	fi
done < "$S/blocked-lines"
check "README Blocked says what a blocked install writes and leaves" has 'stay installed' "$S/blocked"
check "README never calls a sample real output" no_match '[Rr]eal ([Ee]nglish )?[Oo]utput' "$readme"
check "README labels the samples as example output from make.sh" has 'Example output (from `scripts/make.sh`' "$readme"
check "README says JSON=1 output is on stdout and make adds its own lines" has "BSD make's own error lines are mixed in" "$readme"
check "README Blocked says the setting works on make install" has 'make install ACCEPT_NVIDIA_LICENSE=1' "$S/blocked"
check "README names 15.1-RELEASE with 16.0-CURRENT" has '15.1-RELEASE' "$S/install"

# Status wording: not-yet-verified statuses stay not-yet-verified.
# Vulkan has one status in the README: not verified, waiting for a test boot.
# The status row says so and no line says Vulkan works.
vk_works=$(grep -E '^\| Vulkan \(.*\) \| works' "$readme" | head -n 1)
vk_row=$(grep -F '| Vulkan (' "$readme" | head -n 1)
case $vk_row in
*'waits for a test boot'*) ok "README status table says Vulkan waits for a test boot" ;;
*) bad "README status table does not say Vulkan waits for a test boot: $vk_row" ;;
esac
if [ -z "$vk_works" ]; then
	ok "README has no line that says Vulkan works"
else
	bad "README says Vulkan works, contradicting its status: $vk_works"
fi
check "README does not name an internal test boot number" no_match 'test boot [0-9]' "$readme"
# The PRIME status is its own table row, not the Vulkan row.
pr_row=$(grep -F '| Cross-GPU buffer import (PRIME)' "$readme" | head -n 1)
case $pr_row in
*'waits for a test boot'*) ok "README status table says PRIME import waits for a test boot" ;;
*) bad "README status table does not say PRIME import waits for a test boot: $pr_row" ;;
esac
check "README names the Vulkan fix, not 'the latest fix'" no_match 'latest (Vulkan )?fix' "$readme"
check "README says where to report problems" has 'so expect rough edges. Report them at' "$readme"

# JSON for machines: only what make.sh supports.
check "make.sh preflight takes --json" has '--json) MK_JSON=1' "$make_sh"
check "README gives the machine form 'sh scripts/make.sh preflight --json'" has 'sh scripts/make.sh preflight --json' "$readme"
check "README does not invent 'install --json'" no_match 'install --json' "$readme"

# The default work root is said the same way everywhere, on one line.
for f in "$readme" "$repo/docs/MANUAL-BUILD.md" "$repo/docs/llm.md"; do
	if awk '
	index($0, "`work/` directory of the checkout") && index($0, "GB10_WORK") { found = 1 }
	END { exit found ? 0 : 1 }' "$f"; then
		ok "${f#$repo/} states the default work root with GB10_WORK"
	else
		bad "${f#$repo/} does not say, on one line, that work/ of the checkout is the default and GB10_WORK overrides it"
	fi
done
for f in "$repo"/man/*.1; do
	if grep -F 'Ev GB10_WORK' "$f" >/dev/null 2>&1; then
		if grep -F 'Pa work/' "$f" >/dev/null 2>&1 && ! grep -F '<repo>' "$f" >/dev/null 2>&1; then
			ok "${f#$repo/} states the default GB10_WORK"
		else
			bad "${f#$repo/} does not state the work/ default of GB10_WORK"
		fi
	fi
done

# No literal placeholder inside a copy-paste block.
for f in "$readme" "$repo/docs/MANUAL-BUILD.md" "$repo/docs/llm.md"; do
	if awk '
	/^```/ { fence = !fence; next }
	fence && /<(repo|user)>/ { print FILENAME ": " $0; bad = 1 }
	END { exit bad ? 1 : 0 }
	' "$f"; then
		ok "${f#$repo/} has no <repo> or <user> placeholder in a code block"
	else
		bad "${f#$repo/} has a <repo> or <user> placeholder in a code block"
	fi
done

# MANUAL-BUILD.md: the work root honours GB10_WORK, the Linux provider
# modules stay optional at boot, and loading from a user-owned tree is
# stated as a trust decision.
manual=$repo/docs/MANUAL-BUILD.md
check "MANUAL-BUILD sets T from GB10_WORK with the checkout default" has 'T=${GB10_WORK:-$(pwd)/work}' "$manual"
check "MANUAL-BUILD quotes the work root in every command" no_match '(^|[^"])\$T/' "$manual"
check "MANUAL-BUILD shows T before root uses it" has 'echo "T=$T"' "$manual"
check "MANUAL-BUILD never hardwires T to the checkout's work directory" no_match 'T="\$\(pwd\)/work"' "$manual"
awk '/^## Load at boot/ { i = 1; next } i && /^## / { exit } i' "$manual" > "$S/boot-section"
awk '/^install -o root -g wheel -m 555 \\$/ && !done { c = 1 } c { print } c && /\/boot\/modules\/$/ { c = 0; done = 1 }' "$S/boot-section" > "$S/boot-core-install"
if [ ! -s "$S/boot-core-install" ]; then
	bad "MANUAL-BUILD Load at boot has no core-module install command"
elif grep -F 'linux' "$S/boot-core-install" >/dev/null; then
	bad "MANUAL-BUILD Load at boot installs the Linux providers with the core modules"
else
	ok "MANUAL-BUILD Load at boot installs the core modules without the Linux providers"
fi
check "MANUAL-BUILD Load at boot still covers nvidia_linux.ko" has 'nvidia_linux.ko' "$S/boot-section"
check "MANUAL-BUILD Load at boot names the trust in the user who owns the work tree" has 'trust' "$S/boot-section"
awk '/^## Test-load safely/ { i = 1; next } i && /^## / { exit } i' "$manual" > "$S/load-section"
check "MANUAL-BUILD Test-load tells root to carry GB10_WORK into the root shell" has 'same path in this root shell' "$S/load-section"
check "MANUAL-BUILD Load at boot tells root to carry GB10_WORK into the root shell" has 'same path in this root shell' "$S/boot-section"
# The loader.conf append, run on a scratch file whose last line has no newline.
awk '/^grep -q .*EnableGpuFirmware/ { c = 1 } c { print } c && /^}/ { exit }' "$S/boot-section" | sed "s#/boot/loader.conf#$S/loader.conf#g" > "$S/loader-block"
if [ -s "$S/loader-block" ]; then
	printf 'kern.foo="1"' > "$S/loader.conf"
	/bin/sh "$S/loader-block" >/dev/null 2>&1
	if [ "$(cat "$S/loader.conf")" = "$(printf 'kern.foo="1"\nhw.nvidia.registry.EnableGpuFirmware="1"')" ]; then
		ok "MANUAL-BUILD loader.conf append keeps the last line intact"
	else
		bad "MANUAL-BUILD loader.conf append glues onto a last line without a newline: $(cat "$S/loader.conf")"
	fi
	/bin/sh "$S/loader-block" >/dev/null 2>&1
	if [ "$(grep -c '^hw.nvidia.registry.EnableGpuFirmware=' "$S/loader.conf")" = 1 ]; then
		ok "MANUAL-BUILD loader.conf append adds the setting once"
	else
		bad "MANUAL-BUILD loader.conf append repeats the setting"
	fi
else
	bad "MANUAL-BUILD Load at boot has no loader.conf block ending in a closing brace"
fi
check "MANUAL-BUILD Test-load names the trust in the user who owns the work tree" has 'trust' "$S/load-section"

# MANUAL-BUILD.md names only files the build scripts produce.
grep -o '\$T/[A-Za-z0-9_./-]*' "$repo/docs/MANUAL-BUILD.md" | sort -u > "$S/manual-paths"
while IFS= read -r mp; do
	[ -n "$mp" ] || continue
	case $mp in
	'$T/build/tree/'*.ko)
		ko=${mp##*/}
		if grep -F -- "$ko" "$repo"/scripts/build-*.sh >/dev/null 2>&1; then
			ok "MANUAL-BUILD names a module the build writes: $ko"
		else
			bad "MANUAL-BUILD names a module no build script writes: $mp"
		fi
		;;
	*) bad "MANUAL-BUILD names a path the build does not produce: $mp" ;;
	esac
done < "$S/manual-paths"

if [ "$fail" = 0 ]; then
	echo "readme_install_doc_test: PASS"
	exit 0
fi
echo "readme_install_doc_test: $fail FAILED"
exit 1

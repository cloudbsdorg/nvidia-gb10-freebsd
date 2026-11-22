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
base=${TMPDIR:-$repo/work/tmp}
case $base in
/*) ;;
*) base=$repo/$base ;;
esac
mkdir -p -- "$base" || exit 1
S=$(mktemp -d "$base/readme-install-doc.XXXXXX") || exit 1
trap 'rm -rf -- "${S:?}"' EXIT HUP INT TERM
fail=0
ok() { printf 'ok    %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1"; fail=$((fail + 1)); }

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
	[ -f "$doc" ] || continue
	if awk -v list="$manual_list" '
	BEGIN { n = split(list, name, " "); pos = 1 }
	pos <= n && match($0, "(^|[[:space:]])sh scripts/" name[pos] "([[:space:]]|$)") { pos++ }
	END { exit pos > n ? 0 : 1 }
	' "$doc"; then
		printf '%s\n' "${doc#$repo/}" >> "$S/manual-files"
	fi
done
manual_count=$(wc -l < "$S/manual-files" | tr -d ' ')
if [ "$manual_count" -le 1 ]; then
	ok "the manual build sequence ($manual_list) occurs in at most one Markdown file"
else
	bad "the manual build sequence occurs in more than one file: $(tr '\n' ' ' < "$S/manual-files")"
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
	[ -f "$doc" ] || continue
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

# No home-directory path and no user name in the documents.  Fail closed: a
# file that cannot be read is a failure, not a pass.
# The patterns are built in pieces so this file does not match itself.
hp=/ho"me/"
up=/Us"ers/"
scan_bad=
for f in "$repo/README.md" "$repo"/docs/*.md "$repo"/man/*.1 "$repo"/man/*.4 "$repo"/lib/libnvrm/man/*; do
	[ -e "$f" ] || { scan_bad="$scan_bad ${f#$repo/}(missing)"; continue; }
	if [ ! -r "$f" ]; then
		scan_bad="$scan_bad ${f#$repo/}(unreadable)"
		continue
	fi
	grep -E "$hp|$up" "$f" >/dev/null 2>&1
	case $? in
	1) ;;
	0) scan_bad="$scan_bad ${f#$repo/}(personal path)" ;;
	*) scan_bad="$scan_bad ${f#$repo/}(scan error)" ;;
	esac
done
if [ -z "$scan_bad" ]; then
	ok "no home-directory path in the documents and manual pages"
else
	bad "personal-path scan failed:$scan_bad"
fi

# --- statements the README makes about what the code does ---------------
readme=$repo/README.md
make_sh=$repo/scripts/make.sh
check() {  # check DESCRIPTION COMMAND...
	_d=$1
	shift
	if "$@"; then ok "$_d"; else bad "$_d"; fi
}
no_match() { ! grep -E -- "$1" "$2" >/dev/null 2>&1; }
has() { grep -F -- "$1" "$2" >/dev/null 2>&1; }

# The doas setup appends a line only when it is missing, with no placeholder.
doasline=$(grep -F '/usr/local/etc/doas.conf 2>/dev/null ||' "$readme" | head -n 1)
check "README doas setup has no <user> placeholder" no_match '<user>' "$readme"
check "README doas setup never overwrites doas.conf with a single >" no_match "[^>]> */usr/local/etc/doas.conf" "$readme"
if [ -n "$doasline" ]; then
	d=$S/doas
	mkdir -p "$d"
	printf 'permit keepme\n' > "$d/doas.conf"
	line=$(printf '%s' "$doasline" | sed "s#/usr/local/etc/doas.conf#$d/doas.conf#g")
	{
		echo 'logname() { echo tester; }'
		echo "$line"
		echo "$line"
	} > "$d/run.sh"
	if /bin/sh "$d/run.sh" && [ "$(grep -c '^permit tester$' "$d/doas.conf")" = 1 ] && grep -qx 'permit keepme' "$d/doas.conf"; then
		ok "README doas line runs in /bin/sh, appends once, keeps existing rules"
	else
		bad "README doas line does not append once and keep existing rules in /bin/sh"
	fi
else
	bad "README has no doas.conf append line"
fi

# Installed: the quoted next steps are what make.sh prints, and the firmware
# setting sits beside the load instructions.
awk '/^### Installed/ { i = 1; next } i && /^### / { exit } i' "$readme" > "$S/installed"
awk '/^### Blocked/ { i = 1; next } i && /^##/ { exit } i' "$readme" > "$S/blocked"
sed -n 's/^next: //p' "$S/installed" > "$S/next-lines"
[ -s "$S/next-lines" ] || bad "README Installed has no quoted next: lines"
while IFS= read -r nl; do
	[ -n "$nl" ] || continue
	if grep -F -- "$nl" "$make_sh" >/dev/null 2>&1; then
		ok "Installed next step is printed by make.sh: $nl"
	else
		bad "Installed next step is not printed by make.sh: $nl"
	fi
done < "$S/next-lines"
check "README Installed puts EnableGpuFirmware=1 with the load instructions" has 'hw.nvidia.registry.EnableGpuFirmware=1' "$S/installed"
check "README Installed says the root tool in the kldload line is the one you have" has 'root tool in that line is the one' "$S/installed"
check "README never hardcodes doas for kenv or kldload outside the quoted output" no_match '(^|[^:] )doas (kenv|kldload)' "$readme"

# Blocked: the quoted fix line is what make.sh prints today.
fixline=$(sed -n 's/^fix: //p' "$S/blocked" | head -n 1)
if [ -n "$fixline" ] && grep -F -- "$fixline" "$make_sh" >/dev/null 2>&1; then
	ok "Blocked fix line is in make.sh"
else
	bad "Blocked fix line is missing or not in make.sh: $fixline"
fi
check "README Blocked says the setting works on make install" has 'make install ACCEPT_NVIDIA_LICENSE=1' "$S/blocked"
check "README Blocked says what a blocked install writes and leaves" has 'stay installed' "$S/blocked"
check "README never calls a sample real output" no_match -i 'real (english )?output' "$readme"
check "README labels the samples as example output from make.sh" has 'Example output (from `scripts/make.sh`' "$readme"
check "README names 15.1-RELEASE with 16.0-CURRENT" has '15.1-RELEASE' "$S/install"

# Status wording: not-yet-verified statuses stay not-yet-verified.
check "README keeps 'waits for test boot 6' for the Vulkan fix" has 'waits for test boot 6' "$readme"
check "README keeps 'waits for a test boot' for PRIME import" has 'waits for a test boot' "$readme"

# JSON for machines: only what make.sh supports.
check "make.sh preflight takes --json" has '--json) MK_JSON=1' "$make_sh"
check "README gives the machine form 'sh scripts/make.sh preflight --json'" has 'sh scripts/make.sh preflight --json' "$readme"
check "README does not invent 'install --json'" no_match 'install --json' "$readme"
check "README says JSON=1 output is on stdout and make adds its own lines" has "BSD make's own error lines are mixed in" "$readme"

# The default work root is said the same way everywhere.
for f in "$readme" "$repo/docs/MANUAL-BUILD.md" "$repo/docs/llm.md"; do
	check "${f#$repo/} states the default work root" has '`work/` directory of the checkout' "$f"
done
for f in "$repo"/man/*.1; do
	if grep -F 'Ev GB10_WORK' "$f" >/dev/null 2>&1; then
		if grep -F 'directory of the checkout' "$f" >/dev/null 2>&1 && ! grep -F '<repo>' "$f" >/dev/null 2>&1; then
			ok "${f#$repo/} states the default GB10_WORK"
		else
			bad "${f#$repo/} does not state the default GB10_WORK like the README"
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

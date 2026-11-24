# Shared by tests/make_install_flow_test.sh and tests/readme_install_doc_test.sh.
# Source it; pp_selftest needs the caller's ok() and bad().
#
# The list (tests/lib/personal-paths.txt) holds fixed-string needles, samples
# and "# allow:" literals.  Every function classifies a line with pp_kind.
#
# The exemptions (tests/lib/personal-paths.exempt) hold the files the scan
# does not look at, one per line: "<path relative to the repo> <count> <sha256>
# <ticket> <reason>".  The count is the number of personal-path occurrences the
# file holds today: one occurrence is one needle found in the file, so two paths
# on one line are two occurrences.  The count must be exactly what the file
# holds: the scan fails when the file holds more (a path was added), when it
# holds fewer (a path was removed) and when it holds none (the file is clean:
# remove the entry).  The sha256 binds the exemption to the content that was
# approved: it is the sha256 of the exempt file, so any change to that file
# (a path replaced by another one, a line added) makes the exemption stale and
# it is refused until the entry is written again.  The path must lie inside the
# repository: an absolute path and a path with a ".." component are refused,
# because they would exempt a file the scan never looks at.  Every entry is
# printed on every run, and an exemption whose file is gone or no longer holds a
# personal path is a failure.
#
# The paths are compared canonically (no "." component, no repeated slash), on
# both sides: the exemption names the file find(1) lists, whatever spelling the
# entry used.  A path that holds a space cannot be exempted: the fields of an
# entry are separated by spaces (the repository holds no such path).  The skip
# list the exemptions write holds "<path> <sha256>", so the scan skips a file
# only while it still holds the content that was approved: a file that changed
# between the check and the scan is a failure, never a silent skip.  Every
# decision about an exempt file is made on one snapshot of it (_pp_snapshot):
# the sha256, the count and the skip are decided on the same bytes, so there is
# no window between the check and its use.
#
# The scan fails closed: a list that cannot be read, a list that holds no
# needle, a file that cannot be read, an empty file list, a list whose files
# are all skipped and an allow literal that is not sound are all errors, never
# a clean result.  "Could not look" is not "found nothing": the reason and the
# file are named on stderr, and the hits that were found before the failure
# are still printed.
#
# pp_kind LINE: blank, comment, needle, sample+, sample-, allow or badkind.
pp_kind() {
	case $1 in
	'# sample+: '?*) echo sample+ ;;
	'# sample-: '?*) echo sample- ;;
	'# allow: '?*) echo allow ;;
	'#'*)
		_pp_rest=${1#'#'}
		_pp_rest=${_pp_rest#"${_pp_rest%%[![:space:]]*}"}
		case $_pp_rest in sample* | allow*) echo badkind ;; *) echo comment ;; esac ;;
	*) case $1 in *[![:space:]]*) echo needle ;; *) echo blank ;; esac ;;
	esac
}

# pp_allow_reason LITERAL NEEDLES: print why an allow literal is refused, or
# nothing when it is sound.  An allow literal must
#   - be at least 8 characters: an allow that is short matches inside ordinary
#     text (a flag, a word, a directory name), so it would cut whole paths out
#     of the lines the scan must read; a broad allow hides what the scan is
#     there to find;
#   - not start with "/": an allow names a fragment of a line, not a path;
#   - hold no whitespace: the removal writes a space, so an allow with a space
#     in it could match the space it wrote;
#   - hold a needle: an allow that hides no needle is dead weight;
#   - hold exactly one needle occurrence: an allow that holds two of them (two
#     needles, or the same needle twice, as in a literal that repeats a
#     directory name) removes both from every line, so it hides what the scan
#     is there to find (one broad allow can cover a whole tree of paths).  The
#     occurrences are counted the way the matcher counts them: every place in
#     the literal where a needle starts, each needle looked for in turn;
#   - not be equal to a needle and not be contained in one: such an allow
#     removes the needle itself, and the scan would be blind to that path.
pp_allow_reason() {
	_pp_lit=$1
	_pp_nf=$2
	[ -n "$_pp_lit" ] || { echo "it is empty"; return 1; }
	[ "${#_pp_lit}" -ge 8 ] || { echo "it is shorter than 8 characters"; return 1; }
	case $_pp_lit in
	/*) echo "it starts with /"; return 1 ;;
	*[[:space:]]*) echo "it holds whitespace"; return 1 ;;
	esac
	_pp_found=0
	_pp_in=0
	while IFS= read -r _pp_nd || [ -n "$_pp_nd" ]; do
		case $_pp_nd in
		'' | *[![:space:]]*) ;;
		*) continue ;;
		esac
		[ -n "$_pp_nd" ] || continue
		# every occurrence of this needle in the literal: the text after each
		# match is searched again, so a literal that repeats the needle holds
		# it twice
		_pp_rest=$_pp_lit
		while :; do
			case $_pp_rest in
			*"$_pp_nd"*) ;;
			*) break ;;
			esac
			_pp_found=$((_pp_found + 1))
			_pp_rest=${_pp_rest#*"$_pp_nd"}
		done
		case $_pp_nd in *"$_pp_lit"*) _pp_in=1 ;; esac
	done < "$_pp_nf"
	[ "$_pp_found" -ge 1 ] || { echo "it holds no needle"; return 1; }
	[ "$_pp_found" -eq 1 ] || { echo "it holds more than one needle occurrence ($_pp_found)"; return 1; }
	[ "$_pp_in" = 0 ] || { echo "it is a needle or is contained in one"; return 1; }
	return 0
}

# _pp_sha256 FILE: the sha256 of the file, or nothing when it cannot be read.
# sha256(1) lives in /sbin, which is not in the PATH of every shell, so the
# full path is tried too.
_pp_sha256() {
	command -v sha256 > /dev/null 2>&1 && sha256 -q "$1" 2> /dev/null && return 0
	[ -x /sbin/sha256 ] && /sbin/sha256 -q "$1" 2> /dev/null && return 0
	return 1
}

# _pp_snapshot FILE: read FILE once, into a copy under TMPDIR (mktemp), and
# print the copy's path.  Everything an exemption decides is decided on the
# copy: its sha256 and its count come from the same bytes, and the file that is
# skipped is the one that was hashed.  A file that is hashed and then counted,
# or hashed and then skipped, from its live path can change in between, and the
# decision is then made on two different contents.  Returns 1 and prints
# nothing when the file cannot be copied; the caller fails closed.  The caller
# removes the copy.
_pp_snapshot() {
	[ -f "$1" ] && [ -r "$1" ] || return 1
	_ps_c=$(mktemp "${TMPDIR:-/tmp}/pp-snap.$$.XXXXXX" 2> /dev/null) || return 1
	[ -n "$_ps_c" ] || return 1
	if ! cp -- "$1" "$_ps_c" 2> /dev/null; then
		rm -f -- "$_ps_c" 2> /dev/null
		return 1
	fi
	printf '%s\n' "$_ps_c"
	return 0
}

# pp_canon PATH: the path without "." components and with single slashes: the
# spelling find(1) prints, so a path and the file it names compare equal.  A
# ".." component is not resolved here: the caller refuses it (it would leave the
# repository).
pp_canon() {
	_pc_in=$1
	case $_pc_in in
	/*) _pc_lead=/; _pc_in=${_pc_in#/} ;;
	*) _pc_lead= ;;
	esac
	_pc_out=
	while [ -n "$_pc_in" ]; do
		_pc_one=${_pc_in%%/*}
		if [ "$_pc_one" = "$_pc_in" ]; then _pc_in=; else _pc_in=${_pc_in#*/}; fi
		case $_pc_one in
		'' | '.') continue ;;
		esac
		if [ -z "$_pc_out" ]; then _pc_out=$_pc_one; else _pc_out=$_pc_out/$_pc_one; fi
	done
	printf '%s%s\n' "$_pc_lead" "$_pc_out"
}

# _pp_numcmp A B: prints 0 when A equals B, 1 when A is greater, 2 when A is
# smaller and 3 when one of them is not a number.  The numbers are decimal
# strings compared by length and then digit by digit: a count that does not fit
# the shell integer cannot be compared with test(1) (the comparison is an error
# there, and an error must never read as "equal").
_pp_numcmp() {
	_nc_a=$1
	_nc_b=$2
	case $_nc_a in
	'' | *[!0-9]*) printf '3\n'; return 0 ;;
	esac
	case $_nc_b in
	'' | *[!0-9]*) printf '3\n'; return 0 ;;
	esac
	# the leading zeros do not count: 007 is 7
	while :; do
		case $_nc_a in
		0?*) _nc_a=${_nc_a#0} ;;
		*) break ;;
		esac
	done
	while :; do
		case $_nc_b in
		0?*) _nc_b=${_nc_b#0} ;;
		*) break ;;
		esac
	done
	[ -n "$_nc_a" ] || _nc_a=0
	[ -n "$_nc_b" ] || _nc_b=0
	if [ "${#_nc_a}" -gt "${#_nc_b}" ]; then printf '1\n'; return 0; fi
	if [ "${#_nc_a}" -lt "${#_nc_b}" ]; then printf '2\n'; return 0; fi
	while [ -n "$_nc_a" ]; do
		_nc_x=${_nc_a%"${_nc_a#?}"}
		_nc_y=${_nc_b%"${_nc_b#?}"}
		if [ "$_nc_x" != "$_nc_y" ]; then
			if [ "$_nc_x" -lt "$_nc_y" ]; then printf '2\n'; return 0; fi
			printf '1\n'
			return 0
		fi
		_nc_a=${_nc_a#?}
		_nc_b=${_nc_b#?}
	done
	printf '0\n'
	return 0
}

# pp_load LIST NEEDLES ALLOWS: write the needles of LIST to NEEDLES and the allow
# literals to ALLOWS.  Returns 1 (callers fail closed) when LIST is missing or
# unreadable, holds no needle, holds a mistyped kind, holds an empty needle or
# an empty allow literal, or holds an allow literal that is not sound: the
# allows are checked here, where they are used, and not only in the self-test.
# An empty entry is refused while it is loaded: a needle of no length is a
# regexp that matches every line, and an allow literal of no length removes
# the empty string from every line (it never ends).  Every refusal names the
# list, the line and what was expected on standard error: the operator repairs
# the entry it names, not a guess.
pp_load() {
	if [ ! -f "$1" ] || [ ! -r "$1" ]; then
		echo "pp_load: the needle list is missing or cannot be read: $1; restore tests/lib/personal-paths.txt from the repository" >&2
		return 1
	fi
	: > "$2" 2>/dev/null && : > "$3" 2>/dev/null || { echo "pp_load: cannot write $2 or $3" >&2; return 1; }
	_pp_ln=0
	while IFS= read -r _pp_line || [ -n "$_pp_line" ]; do
		_pp_ln=$((_pp_ln + 1))
		case $(pp_kind "$_pp_line") in
		needle)
			case $_pp_line in
			*[![:space:]]*) ;;
			*)
				echo "pp_load: $1:$_pp_ln: a needle holds no character: it is refused" >&2
				return 1 ;;
			esac
			printf '%s\n' "$_pp_line" >> "$2" ;;
		allow)
			_pp_lit=${_pp_line#'# allow: '}
			case $_pp_lit in
			*[![:space:]]*) ;;
			*)
				echo "pp_load: $1:$_pp_ln: an allow literal holds no character: it is refused" >&2
				return 1 ;;
			esac
			printf '%s\n' "$_pp_lit" >> "$3" ;;
		badkind)
			echo "pp_load: $1:$_pp_ln: unknown entry type: $_pp_line; expected a needle, \`# sample+: TEXT\`, \`# sample-: TEXT\`, \`# allow: LITERAL\` or a comment whose first word is not sample or allow" >&2
			return 1 ;;
		esac
	done < "$1"
	[ -s "$2" ] || { echo "pp_load: the needle list holds no needle: $1" >&2; return 1; }
	while IFS= read -r _pp_lit || [ -n "$_pp_lit" ]; do
		_pp_why=$(pp_allow_reason "$_pp_lit" "$2") || {
			echo "pp_load: the allow literal is refused because $_pp_why: $_pp_lit" >&2
			return 1
		}
	done < "$3"
	return 0
}

# The matcher, one copy of it: pp_hits (over files), pp_line (over one line)
# and pp_count (the number of personal-path occurrences) all run it, so a
# self-test sample is matched exactly as a scanned line is.  The allow literals
# are removed from the line first (every match becomes a space); then every
# needle is looked for anywhere in the line.
#
# The matcher fails when it could not look: a needle list it cannot read, a
# needle list that holds no needle, an allow list it cannot read.  Zero
# needles loaded is a failure, never "nothing found".
#
# The modes: files prints FILE:LINE:TEXT for every line that holds a needle,
# loc prints FILE:LINE for the same lines, line prints the needle a line
# holds, and count prints the number of personal-path occurrences in the
# files.  An occurrence is one needle found in a line: the longest needle
# wins where two of them match at the same place, so a path that holds a
# shorter needle is counted once.
_pp_matcher='
function esc(s,   i, c, out) {
	out = ""
	for (i = 1; i <= length(s); i++) {
		c = substr(s, i, 1)
		if (index(".*+?()[]{}|^$\\", c) > 0) out = out "\\" c
		else out = out c
	}
	return out
}
BEGIN {
	while ((r = (getline l < nf)) > 0) {
		# A needle of no length is a regexp that matches every line, and in
		# count mode it never advances: it is refused, not used.
		if (l ~ /[^ \t]/) n[++nn] = l
	}
	if (r < 0) { print "pp: the needle list cannot be read: " nf > "/dev/stderr"; failed = 1; exit 2 }
	if (nn == 0) { print "pp: the needle list holds no needle: " nf > "/dev/stderr"; failed = 1; exit 2 }
	while ((r = (getline l < af)) > 0) {
		# An allow literal of no length removes the empty string from every
		# line and never ends: it is refused.
		if (l ~ /[^ \t]/) a[++na] = l
		else { print "pp: the allow list holds an empty literal: " af > "/dev/stderr"; failed = 1; exit 2 }
	}
	if (r < 0) { print "pp: the allow list cannot be read: " af > "/dev/stderr"; failed = 1; exit 2 }
	# The longest needle first: where two needles match at the same place, the
	# longest one wins, so a path that holds a shorter needle is counted once.
	for (i = 2; i <= nn; i++) {
		v = n[i]; lv = length(v); j = i - 1
		while (j >= 1 && length(n[j]) < lv) { n[j+1] = n[j]; j-- }
		n[j+1] = v
	}
	re = esc(n[1])
	for (i = 2; i <= nn; i++) re = re "|" esc(n[i])
}
{
	line = $0
	for (i = 1; i <= na; i++)
		while ((p = index(line, a[i])) > 0)
			line = substr(line, 1, p - 1) " " substr(line, p + length(a[i]))
	if (mode == "count") {
		rest = line
		while (match(rest, re)) {
			# a match of no length never advances: the count would not end
			if (RLENGTH == 0) { print "pp: the matcher matched nothing at all: the needle list holds an empty needle: " nf > "/dev/stderr"; failed = 1; exit 2 }
			cnt++; rest = substr(rest, RSTART + RLENGTH)
		}
		next
	}
	for (i = 1; i <= nn; i++)
		if (index(line, n[i])) {
			if (mode == "line") print n[i]
			else if (mode == "loc") { print FILENAME ":" FNR; next }
			else { print FILENAME ":" FNR ":" $0; next }
		}
}
END { if (mode == "count" && !failed) print cnt + 0 }'

# pp_hits NEEDLES ALLOWS FILE...: print FILE:LINE:TEXT for every line that holds
# a needle once the allow literals are replaced by a space.  With no FILE it
# returns 2 and looks at nothing: it must not read stdin, because "could not
# look" is not "found nothing".  It returns 2 as well when the needle list is
# empty or unreadable, or holds no needle: a matcher that loaded no needle
# found nothing because it looked at nothing.
pp_hits() {
	_pp_n=$1; _pp_a=$2; shift 2
	[ $# -gt 0 ] || return 2
	[ -s "$_pp_n" ] || { echo "pp_hits: the needle list is empty or unreadable: $_pp_n" >&2; return 2; }
	[ -r "$_pp_a" ] || { echo "pp_hits: cannot read the allow list: $_pp_a" >&2; return 2; }
	awk -v nf="$_pp_n" -v af="$_pp_a" -v mode=files "$_pp_matcher" "$@"
}

# pp_locs NEEDLES ALLOWS FILE...: print FILE:LINE for every line that holds a
# needle: the places a personal path was found.  The same failures as pp_hits.
pp_locs() {
	_pp_n=$1; _pp_a=$2; shift 2
	[ $# -gt 0 ] || return 2
	[ -s "$_pp_n" ] || { echo "pp_locs: the needle list is empty or unreadable: $_pp_n" >&2; return 2; }
	[ -r "$_pp_a" ] || { echo "pp_locs: cannot read the allow list: $_pp_a" >&2; return 2; }
	awk -v nf="$_pp_n" -v af="$_pp_a" -v mode=loc "$_pp_matcher" "$@"
}

# pp_line NEEDLES ALLOWS TEXT: print every needle TEXT holds once the allow
# literals are replaced by a space; print nothing when it holds none.
pp_line() {
	_pp_n=$1; _pp_a=$2; _pp_t=$3
	printf '%s\n' "$_pp_t" | awk -v nf="$_pp_n" -v af="$_pp_a" -v mode=line "$_pp_matcher"
}

# pp_count NEEDLES ALLOWS FILE...: print the number of personal-path
# occurrences in the files.  One occurrence is one needle found in a file, so
# two paths on one line are two occurrences and a path that holds a shorter
# needle is counted once.  Returns 2 when it could not look: no file, a needle
# list that is empty, unreadable or holds no needle, an allow list that cannot
# be read, or a matcher that returned no count.
pp_count() {
	_pp_n=$1; _pp_a=$2; shift 2
	[ $# -gt 0 ] || return 2
	[ -s "$_pp_n" ] || { echo "pp_count: the needle list is empty or unreadable: $_pp_n" >&2; return 2; }
	[ -r "$_pp_a" ] || { echo "pp_count: cannot read the allow list: $_pp_a" >&2; return 2; }
	_pp_c=$(awk -v nf="$_pp_n" -v af="$_pp_a" -v mode=count "$_pp_matcher" "$@") || return 2
	case $_pp_c in
	'' | *[!0-9]*) echo "pp_count: the matcher returned no count: [$_pp_c]" >&2; return 2 ;;
	esac
	printf '%s\n' "$_pp_c"
}

# pp_file_list ROOT NEEDLELIST OUT: every regular file under ROOT, except the
# needle list itself, one name per line, appended to OUT.  The needle list is
# excluded by its exact path, not by its name: a file called personal-paths.txt
# anywhere else is scanned like any other file.  The pattern of the exclusion
# is escaped, so a checkout whose own name holds a glob character does not
# widen it.
#
# A file name that holds a newline cannot be written in a list of one name per
# line: the listing refuses it, so the scan fails closed instead of leaving the
# file unscanned.  Returns 1 when it could not look.
pp_file_list() {
	_pfr=$1; _pfn=$2; _pfo=$3
	[ -d "$_pfr" ] || { echo "pp_file_list: not a directory: $_pfr" >&2; return 1; }
	# A file name that holds a newline cannot be written in a list of one name
	# per line: the listing refuses it, so the scan fails closed instead of
	# leaving the file unscanned.  (The pattern is a literal newline: a
	# command substitution would strip it.)
	_pp_nl='
'
	_pfb=$(find "$_pfr" -type f -name "*${_pp_nl}*" -print 2> /dev/null | head -1)
	if [ -n "$_pfb" ]; then
		echo "pp_file_list: a file name holds a newline; it cannot be listed one name per line: $_pfb" >&2
		return 1
	fi
	_pfp=$(printf '%s' "$_pfn" | sed 's/[][*?\\]/\\&/g')
	find "$_pfr" -type f ! -path "$_pfp" >> "$_pfo" 2> /dev/null || {
		echo "pp_file_list: cannot list the files under $_pfr" >&2
		return 1
	}
	# The list is not an input of the scan: the file the list is written to is
	# removed from it, whatever spelling the root and the output were given
	# in.  A list that holds itself is scanned as an input, and the checkout
	# path (or the scratch path) in it can make the scan hit itself.
	_pfo_c=$(pp_canon "$_pfo")
	_pft="${_pfo}.pp-self.$$"
	if ! : > "$_pft" 2> /dev/null; then
		echo "pp_file_list: cannot write the list beside $_pfo" >&2
		return 1
	fi
	while IFS= read -r _pff || [ -n "$_pff" ]; do
		[ -n "$_pff" ] || continue
		[ "$(pp_canon "$_pff")" = "$_pfo_c" ] && continue
		printf '%s\n' "$_pff" >> "$_pft"
	done < "$_pfo"
	if ! cat "$_pft" > "$_pfo" 2> /dev/null; then
		rm -f "$_pft"
		echo "pp_file_list: cannot rewrite the list $_pfo" >&2
		return 1
	fi
	rm -f "$_pft"
	return 0
}

# pp_scan NEEDLES ALLOWS LISTFILE [SKIPFILE]: LISTFILE holds one file name per
# line.  The list is read one line at a time, so a name is never word-split
# and never globbed.  SKIPFILE, when given, holds the files the scan must not
# look at (the exemptions), one per line, as "<path> <sha256>": the sha256 is
# the content the exemption approved, so a file is skipped only while it still
# holds it; a file that changed is a failure, never a silent skip.  The paths
# are compared canonically, so a path and the file it names compare equal
# whatever spelling they have.  Returns 0 when no scanned file holds a needle,
# 1 when one does (the hits are printed), and 2 when the scan could not look: a
# missing needle, allow, list or skip file, an empty list, a list whose files
# are all skipped, a skip entry without a sha256, an exempt file that changed,
# or a file that cannot be read.  An empty list is an error, never a clean
# result, and so is a list whose every file is skipped: a scan that looked at
# nothing found nothing.  Every "could not look" names the file and the reason
# on stderr.
pp_scan() {
	_pp_n=$1; _pp_a=$2; _pp_lf=$3; _pp_sf=${4:-}
	# A file it reads must be a regular file it can read: a directory is
	# readable, but reading it does not read a list of names, and a list that
	# cannot be read must never look like an empty one.
	if [ ! -f "$_pp_n" ] || [ ! -r "$_pp_n" ]; then echo "pp_scan: cannot read the needle list: $_pp_n" >&2; return 2; fi
	if [ ! -f "$_pp_a" ] || [ ! -r "$_pp_a" ]; then echo "pp_scan: cannot read the allow list: $_pp_a" >&2; return 2; fi
	if [ ! -f "$_pp_lf" ] || [ ! -r "$_pp_lf" ]; then echo "pp_scan: cannot read the file list: $_pp_lf" >&2; return 2; fi
	if [ -n "$_pp_sf" ] && { [ ! -f "$_pp_sf" ] || [ ! -r "$_pp_sf" ]; }; then echo "pp_scan: cannot read the skip list: $_pp_sf" >&2; return 2; fi
	_pp_listed=0
	_pp_seen=0
	_pp_hit=0
	while IFS= read -r _pp_f || [ -n "$_pp_f" ]; do
		[ -n "$_pp_f" ] || continue
		_pp_listed=$((_pp_listed + 1))
		# The paths are compared canonically: the file list and the skip list
		# may spell the same file differently ("./x", "a//b", "a/./b").
		_pp_f=$(pp_canon "$_pp_f")
		if [ ! -f "$_pp_f" ] || [ ! -r "$_pp_f" ]; then
			echo "pp_scan: cannot read: $_pp_f" >&2
			return 2
		fi
		_pp_skip=0
		if [ -n "$_pp_sf" ]; then
			while IFS= read -r _pp_s || [ -n "$_pp_s" ]; do
				[ -n "$_pp_s" ] || continue
				# A skip entry is "<path> <sha256>": the sha256 is what the
				# exemption approved, so the file is skipped only while it
				# still holds it.
				_pp_sha=${_pp_s##* }
				_pp_sp=${_pp_s% *}
				case $_pp_sha in
				*[!0-9a-f]*) _pp_sha= ;;
				esac
				if [ "$_pp_sp" = "$_pp_s" ] || [ "${#_pp_sha}" != 64 ]; then
					echo "pp_scan: the skip list entry holds no sha256: $_pp_s" >&2
					return 2
				fi
				if [ "$(pp_canon "$_pp_sp")" = "$_pp_f" ]; then
					# The file is read once, into a snapshot, and the snapshot is
					# what is hashed: the bytes the skip is decided on are the
					# bytes that were read, whatever the file holds a moment
					# later.  A snapshot that cannot be taken is a failure.
					if ! _pp_snap=$(_pp_snapshot "$_pp_f"); then
						echo "pp_scan: cannot read the exempt file: $_pp_f" >&2
						return 2
					fi
					_pp_now=$(_pp_sha256 "$_pp_snap") || _pp_now=
					rm -f -- "$_pp_snap"
					if [ "$_pp_now" != "$_pp_sha" ]; then
						echo "pp_scan: the exempt file changed since its exemption was checked: $_pp_f (the exemption approved $_pp_sha, the file holds ${_pp_now:-nothing})" >&2
						return 2
					fi
					_pp_skip=1
					break
				fi
			done < "$_pp_sf"
		fi
		if [ "$_pp_skip" = 1 ]; then
			continue
		fi
		_pp_seen=$((_pp_seen + 1))
		if ! _pp_h=$(pp_hits "$_pp_n" "$_pp_a" "$_pp_f"); then
			echo "pp_scan: cannot scan: $_pp_f" >&2
			return 2
		fi
		if [ -n "$_pp_h" ]; then
			_pp_hit=1
			printf '%s\n' "$_pp_h"
		fi
	done < "$_pp_lf"
	if [ "$_pp_listed" -eq 0 ]; then
		echo "pp_scan: the file list is empty: $_pp_lf" >&2
		return 2
	fi
	if [ "$_pp_seen" -eq 0 ]; then
		echo "pp_scan: every file of the list was skipped: nothing was scanned: $_pp_lf" >&2
		return 2
	fi
	[ "$_pp_hit" = 0 ] || return 1
	return 0
}

# _pp_exempt_parse LINE: the fields of an exemption entry, in the globals
# _xe_path, _xe_count, _xe_sha, _xe_ticket and _xe_reason.  Returns 1 when the
# entry is malformed (a field is missing).
_pp_exempt_parse() {
	_xl=$1
	_xe_path=${_xl%% *}
	_xr2=${_xl#"$_xe_path"}
	_xr2=${_xr2#"${_xr2%%[![:space:]]*}"}
	_xe_count=${_xr2%% *}
	_xr3=${_xr2#"$_xe_count"}
	_xr3=${_xr3#"${_xr3%%[![:space:]]*}"}
	_xe_sha=${_xr3%% *}
	_xr4=${_xr3#"$_xe_sha"}
	_xr4=${_xr4#"${_xr4%%[![:space:]]*}"}
	_xe_ticket=${_xr4%% *}
	_xe_reason=${_xr4#"$_xe_ticket"}
	_xe_reason=${_xe_reason#"${_xe_reason%%[![:space:]]*}"}
	[ -n "$_xe_path" ] && [ -n "$_xe_count" ] && [ -n "$_xe_sha" ] &&
		[ -n "$_xe_ticket" ] && [ -n "$_xe_reason" ]
}

# pp_exempt_report EXEMPTFILE: print every entry of the exemption file, one per
# line: "exempt: <path> <count> <sha256> (<ticket>: <reason>)".  The entries are
# printed without looking at the files they name, so every entry is printed on
# every run, even when the scan could not look (a missing needle list, a
# listing that failed): an exemption is never invisible.  Returns 2 when the
# exemption file is not a regular file it can read.
pp_exempt_report() {
	# The exemption file must be a regular file it can read: a directory is
	# readable, but the entries of a directory are not exemption entries, and
	# a report that read none must not look like a report of every entry.
	if [ ! -f "$1" ] || [ ! -r "$1" ]; then echo "pp_exempt_report: cannot read the exemption file: $1" >&2; return 2; fi
	while IFS= read -r _xl || [ -n "$_xl" ]; do
		case $_xl in
		'' | '#'*) continue ;;
		esac
		if ! _pp_exempt_parse "$_xl"; then
			echo "the exemption entry is malformed: $_xl; expected: \`<path relative to the repo> <count> <sha256> <ticket> <reason>\`" >&2
			continue
		fi
		printf 'exempt: %s %s %s (%s: %s)\n' "$_xe_path" "$_xe_count" "$_xe_sha" "$_xe_ticket" "$_xe_reason"
	done < "$1"
	return 0
}

# pp_exempt_scan EXEMPTFILE REPO NEEDLES ALLOWS SKIPFILE: read the exemption
# file and check every entry.  An entry is one line:
#   <path relative to the repo> <count> <sha256> <ticket> <reason>
# The count is the number of personal-path occurrences the file holds today, so
# an exemption cannot cover a path that was added later.  The sha256 binds the
# exemption to the content that was approved: it is the sha256 of the exempt
# file, so a file that changed (a path replaced by another one, a line added)
# makes the exemption stale, and it is refused until the entry is written
# again.  The path must lie inside the repository: an absolute path and a path
# with a ".." component are refused.  A blank line and a line whose first
# character is "#" are comments.  The entries are printed by pp_exempt_report,
# before anything can fail, so every entry is printed on every run.  The
# absolute path of every exempt file and the sha256 the entry approved are
# written to SKIPFILE, one per line, and the scan skips exactly those files,
# and only while they still hold that content.  An exemption must still be
# justified: the file must exist, must hold exactly as many personal-path
# occurrences as the entry records and must hold the content the entry
# approved.  It holds more when a path was added (the entry must record the
# new count, or the path must go) and fewer when a path was removed (the entry
# must record the count the file holds now).  Returns 0 when every exemption is
# justified, 1 when one is not (the file is gone, changed, holds no personal
# path any more, holds a number of personal paths other than the one the entry
# records, or names a path outside the repository) and 2 when the exemption
# file is not a regular file it can read, or when the skip list cannot be
# written: an exemption the scan could not read is not an exemption, and a
# skip list that could not be written is not a skip list.
pp_exempt_scan() {
	_xf=$1; _xr=$2; _xn=$3; _xa=$4; _xs=$5
	# The exemption file must be a regular file it can read: a directory is
	# readable, but the entries of a directory are not exemption entries, and
	# an exemption the scan could not read is not an exemption.
	if [ ! -f "$_xf" ] || [ ! -r "$_xf" ]; then echo "pp_exempt_scan: cannot read the exemption file: $_xf" >&2; return 2; fi
	: > "$_xs" 2>/dev/null || { echo "pp_exempt_scan: cannot write the skip list: $_xs" >&2; return 2; }
	_xrc=0
	while IFS= read -r _xl || [ -n "$_xl" ]; do
		case $_xl in
		'' | '#'*) continue ;;
		esac
		if ! _pp_exempt_parse "$_xl"; then
			echo "the exemption entry is malformed: $_xl; expected: \`<path relative to the repo> <count> <sha256> <ticket> <reason>\`" >&2
			_xrc=1
			continue
		fi
		_xp=$_xe_path; _xc=$_xe_count; _xh=$_xe_sha; _xt=$_xe_ticket; _xreason=$_xe_reason
		# The count is a decimal string of any length: it is compared with
		# _pp_numcmp, never with test(1), so no count is too large to compare
		# (an integer comparison of an oversized number is a shell error, and
		# an error must never read as "equal"); there is no other bound.
		case $_xc in
		'' | *[!0-9]*)
			echo "the exemption entry is malformed: $_xl; the count is not a number (a path that holds a space cannot be exempted: the fields are separated by spaces); expected: \`<path relative to the repo> <count> <sha256> <ticket> <reason>\`" >&2
			_xrc=1
			continue ;;
		esac
		case $_xh in
		*[!0-9a-f]*)
			echo "the exemption entry is malformed: $_xl; the sha256 is not a sha256" >&2
			_xrc=1
			continue ;;
		esac
		[ "${#_xh}" = 64 ] || {
			echo "the exemption entry is malformed: $_xl; the sha256 is not a sha256" >&2
			_xrc=1
			continue
		}
		# The path must lie inside the repository: an absolute path and a path
		# with a ".." component would exempt a file the scan never looks at.
		case $_xp in
		/*)
			echo "the exemption path is absolute: $_xp; it must be a path relative to the repository" >&2
			_xrc=1
			continue ;;
		esac
		case "/$_xp/" in
		*/../*)
			echo "the exemption path holds a .. component: $_xp; it must be a path relative to the repository, inside it" >&2
			_xrc=1
			continue ;;
		esac
		# The path is canonical: "./x", "a//b" and "a/./b" name the file
		# find(1) lists as "x", "a/b" and "a/b", and the skip list must hold
		# the same spelling the scan compares.
		_xp=$(pp_canon "$_xp")
		_xfile=$_xr/$_xp
		case $_xfile in
		"$_xr"/*) ;;
		*)
			echo "the exemption path is outside the repository: $_xp; it must be a path relative to the repository, inside it" >&2
			_xrc=1
			continue ;;
		esac
		if [ ! -f "$_xfile" ]; then
			echo "the exempt file does not exist: $_xp; remove its line from tests/lib/personal-paths.exempt or correct the path" >&2
			_xrc=1
			continue
		fi
		# The file is read once, into a snapshot: the sha256 that binds the
		# exemption and the count that justifies it come from the same bytes.
		if ! _xsnap=$(_pp_snapshot "$_xfile"); then
			echo "the exempt file cannot be read: $_xp" >&2
			_xrc=1
			continue
		fi
		# The exemption is bound to the content it approved.
		_xnow=$(_pp_sha256 "$_xsnap") || _xnow=
		if [ "$_xnow" != "$_xh" ]; then
			rm -f -- "$_xsnap"
			echo "the exempt file changed since the exemption was recorded: $_xp (the entry records $_xh, the file holds ${_xnow:-nothing}); record the sha256 and the count the file holds now, or remove the line" >&2
			_xrc=1
			continue
		fi
		_xcount=$(pp_count "$_xn" "$_xa" "$_xsnap") || _xcount=
		rm -f -- "$_xsnap"
		if [ -z "$_xcount" ]; then
			echo "the exempt file could not be scanned: $_xp; the reason is above" >&2
			_xrc=1
			continue
		fi
		if [ "$_xcount" = 0 ]; then
			echo "the exempt file no longer holds a personal path: $_xp; remove its line from tests/lib/personal-paths.exempt" >&2
			_xrc=1
			continue
		fi
		# The counts are compared as decimal strings: an error in the
		# comparison is a failure, never a false equality.
		case $(_pp_numcmp "$_xcount" "$_xc") in
		0) ;;
		1)
			echo "the personal paths of the exempt file are here:" >&2
			pp_locs "$_xn" "$_xa" "$_xfile" | awk -v f="$_xp" '{ print "  " f ":" $NF }' >&2
			echo "the exempt file holds more personal paths than the exemption records: $_xp ($_xcount found, $_xc recorded); remove the new path or record the count the file holds now" >&2
			_xrc=1
			continue ;;
		2)
			echo "the exempt file holds fewer personal paths than the exemption records: $_xp ($_xcount found, $_xc recorded); record the count the file holds now, or remove the line" >&2
			_xrc=1
			continue ;;
		*)
			echo "the counts of the exemption could not be compared: $_xp ($_xcount found, $_xc recorded)" >&2
			_xrc=1
			continue ;;
		esac
		# The skip list is written as the exemptions are checked: a write that
		# fails is an error, never a success with a short list.  A skip list
		# that holds fewer entries than the exemptions would let the scan look
		# at a file the exemption approved.
		if ! printf '%s %s\n' "$_xfile" "$_xh" >> "$_xs" 2> /dev/null; then
			echo "pp_exempt_scan: cannot write the skip list: $_xs" >&2
			return 2
		fi
	done < "$_xf"
	return $_xrc
}

# pp_selftest LIST NEEDLES ALLOWS: run every sample and check every allow of LIST.
# "# sample+:" must match the needle just above it, after the allow literals are
# removed: the sample goes through the same matcher as the real scan, so an
# allow that hides a real path fails here.  "# sample-:" must match no needle
# after the allows are applied.  Each of these calls bad(): a sample before
# the first needle, a needle without a positive sample, a list without samples,
# an allow literal that is not sound.  Returns 1 on any bad.
pp_selftest() {
	_pp_cur=
	_pp_have=1
	_pp_cnt=0
	_pp_bad=0
	while IFS= read -r _pp_line || [ -n "$_pp_line" ]; do
		case $(pp_kind "$_pp_line") in
		sample+)
			_pp_text=${_pp_line#'# sample+: '}
			_pp_cnt=$((_pp_cnt + 1))
			if [ -z "$_pp_cur" ]; then bad "personal-path sample before any needle: $_pp_text"; _pp_bad=1
			else
				# The needles the matcher printed, one per line, compared with
				# the current needle as exact strings: a pattern comparison
				# would read a needle such as "foo[ab]" as a character class
				# and accept "fooa" for it.
				_pp_hit=$(pp_line "$2" "$3" "$_pp_text")
				_pp_same=0
				while IFS= read -r _pp_one || [ -n "$_pp_one" ]; do
					[ "$_pp_one" = "$_pp_cur" ] && _pp_same=1
				done <<EOF
$_pp_hit
EOF
				if [ "$_pp_same" = 1 ]; then _pp_have=1; ok "personal-path needle matches: $_pp_text"
				else bad "personal-path needle misses: $_pp_text"; _pp_bad=1; fi
			fi ;;
		sample-)
			_pp_text=${_pp_line#'# sample-: '}
			_pp_cnt=$((_pp_cnt + 1))
			if [ -z "$_pp_cur" ]; then bad "personal-path sample before any needle: $_pp_text"; _pp_bad=1
			elif [ -n "$(pp_line "$2" "$3" "$_pp_text")" ]; then bad "personal-path needles flag a non-path: $_pp_text"; _pp_bad=1
			else ok "personal-path needles pass: $_pp_text"; fi ;;
		allow)
			_pp_lit=${_pp_line#'# allow: '}
			_pp_why=$(pp_allow_reason "$_pp_lit" "$2")
			if [ -z "$_pp_why" ]; then ok "personal-path allow literal is sound: $_pp_lit"; else bad "personal-path allow literal is refused because $_pp_why: $_pp_lit"; _pp_bad=1; fi ;;
		needle)
			[ "$_pp_have" = 1 ] || { bad "personal-path needle has no positive sample: $_pp_cur"; _pp_bad=1; }
			_pp_cur=$_pp_line; _pp_have=0 ;;
		esac
	done < "$1"
	[ "$_pp_have" = 1 ] || { bad "personal-path needle has no positive sample: $_pp_cur"; _pp_bad=1; }
	[ "$_pp_cnt" -gt 0 ] || { bad "personal-path list has no samples"; _pp_bad=1; }
	[ "$_pp_bad" = 0 ]
}

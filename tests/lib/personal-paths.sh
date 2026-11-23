# Shared by tests/make_install_flow_test.sh and tests/readme_install_doc_test.sh.
# Source it; pp_selftest needs the caller's ok() and bad().
#
# The list (tests/lib/personal-paths.txt) holds fixed-string needles, samples
# and "# allow:" literals.  Every function classifies a line with pp_kind.
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

# pp_load LIST NEEDLES ALLOWS: write the needles of LIST to NEEDLES and the allow
# literals to ALLOWS.  Returns 1 (callers fail closed) when LIST is missing or
# unreadable, holds no needle, or holds a mistyped kind.
pp_load() {
	[ -r "$1" ] || return 1
	: > "$2" 2>/dev/null && : > "$3" 2>/dev/null || return 1
	while IFS= read -r _pp_line || [ -n "$_pp_line" ]; do
		case $(pp_kind "$_pp_line") in
		needle) printf '%s\n' "$_pp_line" >> "$2" ;;
		allow) printf '%s\n' "${_pp_line#'# allow: '}" >> "$3" ;;
		badkind) return 1 ;;
		esac
	done < "$1"
	[ -s "$2" ]
}

# pp_hits NEEDLES ALLOWS [FILE...]: print FILE:LINE:TEXT for every line that holds
# a needle once the allow literals are replaced by a space.  Reads stdin with no FILE.
pp_hits() {
	_pp_n=$1; _pp_a=$2; shift 2
	awk -v nf="$_pp_n" -v af="$_pp_a" '
	BEGIN {
		while ((getline l < nf) > 0) n[++nn] = l
		while ((getline l < af) > 0) a[++na] = l
	}
	{
		line = $0
		for (i = 1; i <= na; i++)
			while ((p = index(line, a[i])) > 0)
				line = substr(line, 1, p - 1) " " substr(line, p + length(a[i]))
		for (i = 1; i <= nn; i++)
			if (index(line, n[i])) { print FILENAME ":" FNR ":" $0; next }
	}' "$@"
}

# pp_selftest LIST NEEDLES ALLOWS: run every sample and check every allow of LIST.
# "# sample+:" must match the needle just above it; "# sample-:" must match no
# needle after the allows are applied.  Each of these calls bad(): a sample before
# the first needle, a needle without a positive sample, a list without samples, an
# allow literal shorter than 8 characters, starting with "/", or holding no needle.
# Returns 1 on any bad.
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
				case $_pp_text in
				*"$_pp_cur"*) _pp_have=1; ok "personal-path needle matches: $_pp_text" ;;
				*) bad "personal-path needle misses: $_pp_text"; _pp_bad=1 ;;
				esac
			fi ;;
		sample-)
			_pp_text=${_pp_line#'# sample-: '}
			_pp_cnt=$((_pp_cnt + 1))
			if [ -z "$_pp_cur" ]; then bad "personal-path sample before any needle: $_pp_text"; _pp_bad=1
			elif [ -n "$(printf '%s\n' "$_pp_text" | pp_hits "$2" "$3")" ]; then bad "personal-path needles flag a non-path: $_pp_text"; _pp_bad=1
			else ok "personal-path needles pass: $_pp_text"; fi ;;
		allow)
			_pp_lit=${_pp_line#'# allow: '}
			_pp_okl=1
			[ "${#_pp_lit}" -ge 8 ] || _pp_okl=0
			case $_pp_lit in /*) _pp_okl=0 ;; esac
			_pp_found=0
			while IFS= read -r _pp_nd || [ -n "$_pp_nd" ]; do
				case $_pp_lit in *"$_pp_nd"*) _pp_found=1 ;; esac
			done < "$2"
			[ "$_pp_found" = 1 ] || _pp_okl=0
			if [ "$_pp_okl" = 1 ]; then ok "personal-path allow literal is sound: $_pp_lit"; else bad "personal-path allow literal is too short, starts with /, or holds no needle: $_pp_lit"; _pp_bad=1; fi ;;
		needle)
			[ "$_pp_have" = 1 ] || { bad "personal-path needle has no positive sample: $_pp_cur"; _pp_bad=1; }
			_pp_cur=$_pp_line; _pp_have=0 ;;
		esac
	done < "$1"
	[ "$_pp_have" = 1 ] || { bad "personal-path needle has no positive sample: $_pp_cur"; _pp_bad=1; }
	[ "$_pp_cnt" -gt 0 ] || { bad "personal-path list has no samples"; _pp_bad=1; }
	[ "$_pp_bad" = 0 ]
}

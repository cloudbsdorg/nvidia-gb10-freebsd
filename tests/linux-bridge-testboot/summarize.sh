#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# summarize.sh [--kit COMMIT] [--hashes FILE] RESULTS.jsonl | --required
#
# Exit 0 only when the run finished ("done" is the last row), no row failed, at
# least one pass row exists, every required row passed, and the provenance holds.
# A trailing "running" row (the machine died in that step) or a missing "done"
# is a failure. Prints one line per non-info row.
#
# Waivers are per row. SUMMARIZE_ALLOW_SKIP is a list of row names (blanks or
# commas); the only row that may be waived is B4-cuda (the Linux CUDA smoke needs
# a staged nvidia-uvm.ko and runner). Every other name, "1" included, is refused,
# so a run can never be waived past the veto rows, the nvrm-info proof or the
# provenance. A waiver ends the verdict with PARTIAL, not OK (exit status 0).
#
# Provenance: the start row names the kit commit (not "unknown"); for each of
# the four staged modules a HASH-staged row (the hash list make-be.sh wrote into
# the boot environment) and a HASH-loaded row (the sha256 of the file the kernel
# loaded, by kldstat -v) must both exist and be equal. --kit COMMIT and --hashes
# FILE (the list make-be.sh printed and kept on the host) additionally compare
# the results with what was armed: a results file from another kit revision or
# another set of modules is refused.
#
# The rows the verdict needs; the kit test builds its fixtures from this list.
# C4-modeset and C4-nvidia are also required unless C4-core is a skip (the
# nvidia_drm module holds the core): they separate the provider's reference veto
# from a driver's own refusal.
REQUIRED_ROWS="A1-modeset A2-no-linux A4-nvrm-info P1-staged B2-rc B2-nvidia_linux B2-refs-nvidia B2-modeset_linux B2-refs-modeset B3-nvkms-ioctl B4-cuda C1-veto-modeset C1-veto-nvidia"
PROV_MODULES="nvidia.ko nvidia-modeset.ko nvidia_linux.ko nvidia_modeset_linux.ko"
WAIVABLE="B4-cuda"
[ "${1:-}" != --required ] || { echo $REQUIRED_ROWS; exit 0; }
KIT=
HASHES=
while [ $# -gt 1 ]; do
	case $1 in
	--kit) KIT=${2:?--kit takes a commit}; shift 2 ;;
	--hashes) HASHES=${2:?--hashes takes a file}; shift 2 ;;
	*) break ;;
	esac
done
f=${1:?usage: summarize.sh [--kit COMMIT] [--hashes FILE] RESULTS.jsonl | --required}
[ $# -eq 1 ] || { echo "summarize.sh: arguments after the results file: $*" >&2; exit 2; }
# the provenance comparison needs both sides, or neither
if { [ -n "$KIT" ] && [ -z "$HASHES" ]; } || { [ -z "$KIT" ] && [ -n "$HASHES" ]; }; then
	echo "summarize.sh: --kit and --hashes go together (the commit and the hash list make-be.sh printed)" >&2
	exit 2
fi
[ -f "$f" ] || { echo "no $f" >&2; exit 2; }

# the waiver list: only named, waivable rows
WAIVED=
for w in $(printf '%s' "${SUMMARIZE_ALLOW_SKIP:-}" | tr ',' ' '); do
	case " $WAIVABLE " in
	*" $w "*) WAIVED="$WAIVED $w" ;;
	*) echo "FAIL: SUMMARIZE_ALLOW_SKIP names '$w': only $WAIVABLE may be waived (it takes row names, not 1)"; exit 1 ;;
	esac
done

last=$(tail -n 1 "$f")
fails=$(grep -c '"result":"fail"' "$f")
passes=$(grep -c '"result":"pass"' "$f")
sed -n 's/^{"row":"\([^"]*\)","result":"\([^"]*\)","detail":"\(.*\)"}$/\2 \1 \3/p' "$f" | grep -v '^info '
case $last in
'{"row":"done"'*) ;;
*) echo "FAIL: the run did not end with a done row: last row is $last"; exit 1 ;;
esac
hint() {	# hint <row> <result>
	case $1:$2 in
	A4-nvrm-info:skip) echo "make-be.sh -i and -p stage nvrm-info and its proof" ;;
	B4-cuda:skip) echo "make-be.sh -U, -C and -u stage the Linux CUDA smoke" ;;
	B3-nvkms-ioctl:skip) echo "nvidia_modeset_linux is not loaded (see B2-modeset_linux), or the NVKMS probe is not in the boot environment" ;;
	B2-modeset_linux:skip | B2-refs-modeset:skip) echo "add nvidia-modeset (the file name) to kld_list in the boot environment: the provider rows need nvidia_modeset loaded" ;;
	B2-refs-nvidia:fail | B2-refs-modeset:fail) echo "$1: compare refs-$1-before.txt and refs-$1-after.txt in the run directory; a module other than the provider that depends on the native module is another holder" ;;
	C1-veto-modeset:skip | C1-veto-nvidia:skip) echo "another module holds the native one (the row's detail names it); a nvidia_drm boot cannot prove this" ;;
	esac
}
if [ "$fails" -ne 0 ]; then
	echo "FAIL: $fails failed rows"
	# a Refs row that failed on the numbers (not because the provider did not load) has snapshots to compare
	for r in B2-refs-nvidia B2-refs-modeset; do
		grep -q "\"row\":\"$r\",\"result\":\"fail\",\"detail\":\"kldstat Refs of" "$f" && echo "      $(hint "$r" fail)"
	done
	exit 1
fi
[ "$passes" -gt 0 ] || { echo "FAIL: no pass row"; exit 1; }

# row_detail <row> [result]: the detail of the LAST row with that name (and result)
row_detail() {
	sed -n "s/^{\"row\":\"$1\",\"result\":\"${2:-[a-z]*}\",\"detail\":\"\\(.*\\)\"}\$/\\1/p" "$f" | tail -n 1
}

# provenance
start=$(row_detail start info)
case $start in
*" kit "*) kit=${start##* kit } ;;
*) kit= ;;
esac
kit=${kit%% *}
if [ -z "$kit" ] || [ "$kit" = unknown ]; then
	echo "FAIL: the start row carries no kit commit (kit '${kit:-missing}'): the run cannot be tied to a kit revision"
	exit 1
fi
if [ -n "$KIT" ] && [ "$kit" != "$KIT" ]; then
	echo "FAIL: the results come from kit $kit, the boot environment was armed with kit $KIT"
	exit 1
fi
for m in $PROV_MODULES; do
	staged=$(sed -n "s/^{\"row\":\"HASH-staged\",\"result\":\"info\",\"detail\":\"$m \\([0-9a-f]\\{64\\}\\)\"}\$/\\1/p" "$f" | tail -n 1)
	loaded=$(sed -n "s/^{\"row\":\"HASH-loaded\",\"result\":\"info\",\"detail\":\"$m \\([0-9a-f]\\{64\\}\\)\"}\$/\\1/p" "$f" | tail -n 1)
	if [ -z "$staged" ] || [ -z "$loaded" ]; then
		echo "FAIL: no staged and loaded sha256 for $m in the results (HASH-staged: '${staged:-missing}', HASH-loaded: '${loaded:-missing}')"
		exit 1
	fi
	if [ "$staged" != "$loaded" ]; then
		echo "FAIL: the $m the kernel loaded ($loaded) is not the staged one ($staged)"
		exit 1
	fi
	if [ -n "$HASHES" ]; then
		want=$(awk -v m="$m" '$2 == m { print $1; exit }' "$HASHES" 2> /dev/null)
		if [ -z "$want" ] || [ "$want" != "$staged" ]; then
			echo "FAIL: $m is $staged in the results, the armed hash list says '${want:-no entry}'"
			exit 1
		fi
	fi
done
if [ -z "$HASHES" ] && [ -z "$KIT" ]; then
	echo "NOTE: no --kit and --hashes given: the provenance is checked inside the results only"
fi

# The rows that carry the claim must PASS, not be skipped: a skipped row is a
# test that did not run. A waiver names the row (see above); a failed or missing
# row is never accepted.
NEEDED=$REQUIRED_ROWS
if ! grep -q '"row":"C4-core","result":"skip"' "$f"; then
	NEEDED="$NEEDED C4-modeset C4-nvidia"
fi
partial=
for r in $NEEDED; do
	res=$(sed -n "s/^{\"row\":\"$r\",\"result\":\"\\([a-z]*\\)\".*/\\1/p" "$f" | tail -n 1)
	[ "$res" = pass ] && continue
	case " $WAIVED " in
	*" $r "*)
		if [ "$res" = skip ]; then
			echo "NOTE: $r was skipped and is waived by SUMMARIZE_ALLOW_SKIP"
			partial="$partial $r"
			continue
		fi
		;;
	esac
	echo "FAIL: required row $r is ${res:-missing}, not pass"
	[ -z "$(hint "$r" "$res")" ] || echo "      $(hint "$r" "$res")"
	if [ "$res" = skip ]; then
		case " $WAIVABLE " in
		*" $r "*) echo "      or set SUMMARIZE_ALLOW_SKIP=$r to accept this one skip (the verdict is then PARTIAL)" ;;
		*) echo "      this row cannot be waived" ;;
		esac
	fi
	exit 1
done
if [ -n "$partial" ]; then
	echo "PARTIAL: $passes passed, 0 failed; waived:$partial"
	exit 0
fi
echo "OK: $passes passed, 0 failed"

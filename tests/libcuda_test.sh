#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-2-Clause
#
# Native CUDA C1.4a (Track #2428).  Build and test a FRESH COPY OF THE INDEX,
# never the working tree.  Stage every new file and every edit before running.
# TMPDIR must name an existing scratch directory; never use the system /tmp.

PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH= cd -- "$HERE/.." && pwd)
: "${TMPDIR:?set TMPDIR to the assigned scratch directory}"
case $TMPDIR in
/*) ;;
*) echo "libcuda_test: TMPDIR must be absolute" >&2; exit 99 ;;
esac
W=$(mktemp -d "$TMPDIR/libcuda-test.XXXXXXXX") || exit 99
trap 'rm -rf "$W"' EXIT INT TERM
unset CUDA_NATIVE_BACKEND CUDA_NATIVE_FAKE_PROFILE CUDA_VISIBLE_DEVICES
unset CUDA_NATIVE_FAKE_ENUM_DELAY_MS CUDA_NATIVE_FAKE_UUID_ERROR
unset CUDA_NATIVE_FAKE_UNSUPPORTED_COOPERATIVE

PASS=0
FAIL=0
SKIP=0
ok() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }
skip() { SKIP=$((SKIP + 1)); printf 'skip %s\n' "$1"; }
expect_rc() {
	if [ "$2" -eq "$3" ]; then ok "$1"; else bad "$1 (rc=$2, want $3)"; fi
}
run_case() {	# run_case NAME COMMAND [ARG ...]; retain output in the transcript
	_name=$1
	shift
	"$@" >"$W/case.out" 2>&1
	_rc=$?
	cat "$W/case.out"
	expect_rc "$_name" "$_rc" 0
}
map_exports() {	# map_exports VERSION_MAP; one exported symbol per line
	awk '/^CUDA_1\.0 \{/{inside=1;next} /^\};/{inside=0}
	    inside && $1 ~ /^[A-Za-z_][A-Za-z0-9_]*;$/ { sub(/;$/, "", $1); print $1 }' "$1"
}

# ---- fresh copy and base toolchain ---------------------------------------
SRC=$W/src
mkdir -p "$SRC"
git -C "$REPO" checkout-index -a --prefix="$SRC/" >"$W/checkout.log" 2>&1
rc=$?
expect_rc "fresh copy of the staged tree" "$rc" 0
[ -f "$SRC/lib/libcuda/cuda_core.c" ] && [ -f "$SRC/tests/libcuda/api_test.c" ] &&
    [ -f "$SRC/tests/libcuda_test.sh" ]
rc=$?
expect_rc "the staged copy contains the library, tests and runner" "$rc" 0
[ "$rc" -eq 0 ] || { cat "$W/checkout.log"; exit 98; }
L=$SRC/lib/libcuda
T=$SRC/tests/libcuda
SDK=$SRC/lib/cuda-native/sdk/include
SCHEMA=$L/schema/cuda-native-info-1.schema.json

ld --version 2>&1 | grep -q LLD
rc=$?
expect_rc "base linker is LLD" "$rc" 0
cc --version | head -1
c++ --version | head -1

# ---- BSD make builds ------------------------------------------------------
O=$W/obj
mkdir -p "$O/lib" "$O/info" "$W/bin"
(cd "$L" && MAKEOBJDIR="$O/lib" make CUDA_NATIVE_TESTING=yes) >"$W/build-lib.log" 2>&1
rc=$?
expect_rc "libcuda builds with BSD make and -Werror" "$rc" 0
[ "$rc" -eq 0 ] || sed -n '1,100p' "$W/build-lib.log"
(cd "$L/cuda-native-info" && MAKEOBJDIR="$O/info" LIBCUDA_OBJ="$O/lib" \
    make CUDA_NATIVE_TESTING=yes && MAKEOBJDIR="$O/info" LIBCUDA_OBJ="$O/lib" \
    make CUDA_NATIVE_TESTING=yes check) >"$W/build-info.log" 2>&1
rc=$?
expect_rc "cuda-native-info builds and its embedded schema matches" "$rc" 0
[ "$rc" -eq 0 ] || sed -n '1,100p' "$W/build-info.log"
LIB=$O/lib/libcuda.so.1
INFO=$O/info/cuda-native-info
export LD_LIBRARY_PATH=$O/lib

if [ -f "$LIB" ]; then
	readelf -p .comment "$LIB" >"$W/lib-comment.out" 2>"$W/lib-comment.err"
	rc=$?
else
	rc=1
fi
expect_rc "readelf can inspect libcuda.so.1" "$rc" 0
grep -q 'Linker: LLD' "$W/lib-comment.out" 2>/dev/null
rc=$?
expect_rc "libcuda.so.1 was linked by LLD" "$rc" 0
if [ -f "$LIB" ]; then
	nm -D --defined-only "$LIB" >"$W/nm.out" 2>"$W/nm.err"
	rc=$?
else
	rc=1
fi
expect_rc "nm can inspect libcuda.so.1 dynamic symbols" "$rc" 0
awk 'NF >= 3 { sub(/@@.*/, "", $3); print $3 }' "$W/nm.out" 2>/dev/null |
    sort >"$W/exports.actual"
map_exports "$L/Version.map" | sort >"$W/map-exports.sorted"
cp "$W/map-exports.sorted" "$W/exports.expected"
cp "$W/map-exports.sorted" "$W/exports.sorted"
awk '{ printf "\t\"%s\",\n", $0 }' "$W/map-exports.sorted" \
    >"$W/cuda_test_exports.inc"
[ -s "$W/map-exports.sorted" ] && [ -s "$W/cuda_test_exports.inc" ]
rc=$?
expect_rc "Version.map exports were extracted for documentation checks" "$rc" 0
python3 -I - "$SRC/README.md" "$W/map-exports.sorted" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
count = len(open(sys.argv[2]).read().splitlines())
match = re.search(r"libcuda\.so\.1[^\n]*\bwith ([0-9]+) [^\n]* calls", text)
assert match is not None, "README libcuda export count is missing"
assert int(match.group(1)) == count, (match.group(1), count)
PY
rc=$?
expect_rc "README call count is derived from Version.map" "$rc" 0
cmp -s "$W/exports.actual" "$W/exports.sorted"
rc=$?
expect_rc "dynamic exports match Version.map exactly" "$rc" 0
(cd "$L" && make -V CUDA_FUNCS) >"$W/make-funcs.raw" 2>"$W/make-funcs.err"
rc=$?
expect_rc "BSD make can evaluate the man-link export list" "$rc" 0
tr -s '[:space:]' '\n' <"$W/make-funcs.raw" | sed '/^$/d' | sort \
    >"$W/make-funcs.sorted"
cmp -s "$W/make-funcs.sorted" "$W/exports.sorted"
rc=$?
expect_rc "man-link exports match Version.map" "$rc" 0
EM=$W/export-map-mutant
mkdir -p "$EM"
cp "$L/Makefile" "$L/version_map.awk" "$EM/"
awk '{ print } $0 == "\t\tcuInit;" { print "\t\tcuCtxSynchronize;" }' \
    "$L/Version.map" >"$EM/Version.map"
grep -q '^		cuCtxSynchronize;$' "$EM/Version.map" &&
    ! cmp -s "$EM/Version.map" "$L/Version.map"
rc=$?
expect_rc "an added Version.map global was planted for the man-link check" "$rc" 0
(cd "$EM" && make -V CUDA_FUNCS) >"$EM/make-funcs.raw" 2>"$EM/make-funcs.err"
rc=$?
if [ "$rc" -eq 0 ]; then
	tr -s '[:space:]' '\n' <"$EM/make-funcs.raw" | sed '/^$/d' |
	    grep -Fxq cuCtxSynchronize
	rc=$?
fi
expect_rc "man-link exports follow an added Version.map global" "$rc" 0

# One Version.map parser: the man-link name list and the proc-table include
# are two modes of it, so a space-indented entry must reach both of them.
FM=$W/version-map-spaces
mkdir -p "$FM"
cp "$L/Makefile" "$L/version_map.awk" "$FM/"
awk '{ if ($0 == "\t\tcuDeviceGetName;") print "        cuDeviceGetName;"; else print }' \
    "$L/Version.map" >"$FM/Version.map"
grep -q '^        cuDeviceGetName;$' "$FM/Version.map" &&
    ! cmp -s "$FM/Version.map" "$L/Version.map"
rc=$?
expect_rc "a space-indented Version.map entry was planted for the parser check" "$rc" 0
map_exports "$FM/Version.map" | sort >"$FM/oracle.sorted"
(cd "$FM" && make -V CUDA_FUNCS) >"$FM/names.raw" 2>"$FM/names.err"
rc=$?
expect_rc "the Makefile reads the space-indented Version.map fixture" "$rc" 0
tr -s '[:space:]' '\n' <"$FM/names.raw" | sed '/^$/d' | sort >"$FM/names.sorted"
cmp -s "$FM/names.sorted" "$FM/oracle.sorted"
rc=$?
expect_rc "the man-link name list and the field-based oracle agree on the fixture" "$rc" 0
# The field-based oracle is one shell function, not two copies of the same
# awk program pasted into the runner.  The marker is assembled at run time, so
# this check does not count itself.
oracle_pattern=$(printf 'inside %s $1' '&&')
[ "$(grep -c -F "$oracle_pattern" "$SRC/tests/libcuda_test.sh")" = 1 ]
rc=$?
expect_rc "the field-based Version.map oracle is one shell function" "$rc" 0
(cd "$FM" && MAKEOBJDIR="$FM" make "$FM/cuda_exports.inc") \
    >"$FM/inc.raw" 2>"$FM/inc.err"
rc=$?
expect_rc "the Makefile reads the proc-table include of the fixture" "$rc" 0
grep -q 'PROC_ENTRY(cuDeviceGetName)' "$FM/cuda_exports.inc"
rc=$?
expect_rc "the proc-table include contains the space-indented entry too" "$rc" 0
awk -f "$L/version_map.awk" -v mode=include "$L/Version.map" >"$W/inc.expected"
cmp -s "$W/inc.expected" "$O/lib/cuda_exports.inc"
rc=$?
expect_rc "the generated proc-table include is the parser's include output" "$rc" 0
# The generated table is included by cuda_core.c, so every object flavour of
# that file needs it: the plain object, the shared-object one and the
# profiled ones.  Each flavour is built in an object directory of its own,
# with no earlier build that would leave the generated file behind: a build
# of one flavour must generate the table itself.  The edge of each flavour
# is load-bearing: a Makefile without it cannot build that flavour in a
# fresh object directory.
for flavour in o pico po pieo; do
	FD=$W/fresh-obj.$flavour
	mkdir -p "$FD"
	(cd "$L" && MAKEOBJDIR="$FD" make "cuda_core.$flavour") \
	    >"$W/fresh-$flavour.log" 2>&1
	rc=$?
	expect_rc "the $flavour flavour builds in a fresh object directory" "$rc" 0
	[ "$rc" -eq 0 ] || sed -n '1,40p' "$W/fresh-$flavour.log"
	[ -s "$FD/cuda_exports.inc" ]
	rc=$?
	expect_rc "the $flavour flavour generated the table itself" "$rc" 0
	MM=$W/no-edge.$flavour
	mkdir -p "$MM"
	cp "$L"/*.c "$L"/*.h "$L/Version.map" "$L/version_map.awk" "$MM/"
	sed "s/cuda_core\.$flavour//" "$L/Makefile" >"$MM/Makefile"
	if grep -q "cuda_core\.$flavour" "$MM/Makefile"; then
		bad "the $flavour edge is gone from the copied Makefile"
	else
		ok "the $flavour edge is gone from the copied Makefile"
	fi
	FD2=$W/no-edge-obj.$flavour
	mkdir -p "$FD2"
	(cd "$MM" && MAKEOBJDIR="$FD2" make "cuda_core.$flavour") \
	    >"$W/no-edge-$flavour.log" 2>&1
	rc=$?
	if [ "$rc" -ne 0 ]; then
		ok "the $flavour flavour needs the edge to the generated table"
	else
		bad "the $flavour flavour needs the edge to the generated table (rc=$rc)"
	fi
done
FO=$W/fresh-obj.pico
awk '!/^\tPROC_ENTRY\([A-Za-z_][A-Za-z0-9_]*\),$/ { bad = 1 }
    END { exit bad }' "$FO/cuda_exports.inc"
rc=$?
expect_rc "the generated include holds one table entry per line" "$rc" 0
# A failed generation leaves no include behind: the recipe writes a
# temporary file and renames it only when the parser succeeds, so the next
# build regenerates the whole table instead of compiling an empty one.  The
# include of an earlier good run is stale after a failed run, and it must be
# gone too.
SI=$W/stale-include
mkdir -p "$SI"
cp "$L"/*.c "$L"/*.h "$L/Makefile" "$L/Version.map" "$L/version_map.awk" "$SI/"
(cd "$SI" && MAKEOBJDIR="$SI" make "$SI/cuda_exports.inc") \
    >"$SI/first.log" 2>&1
rc=$?
expect_rc "the good parser generates the include" "$rc" 0
[ -s "$SI/cuda_exports.inc" ]
rc=$?
expect_rc "the generated include is there before the failure" "$rc" 0
printf 'BEGIN { exit 1 }\n' >"$SI/version_map.awk"
# The rule runs again when a prerequisite is newer than the include.  The
# file system keeps the time of a file to a second, so the wait is one
# second.
sleep 1
touch "$SI/Version.map"
(cd "$SI" && MAKEOBJDIR="$SI" make) >"$SI/fail.log" 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then
	ok "the build fails when the generation fails"
else
	bad "the build fails when the generation fails (rc=$rc)"
	sed -n '1,20p' "$SI/fail.log"
fi
[ ! -e "$SI/cuda_exports.inc" ]
rc=$?
expect_rc "a failed generation leaves no include behind" "$rc" 0
[ ! -e "$SI/cuda_exports.inc.tmp" ]
rc=$?
expect_rc "a failed generation leaves no temporary file behind" "$rc" 0
# Every path the recipe expands is quoted: an object directory that carries
# a shell command is a path and not a command.  The object directory is
# made first, so that the creation of it is not what is measured.
IJ=$W/injection
mkdir -p "$IJ/obj; touch $IJ/pwned #/#" "$IJ/#"
cp "$L/Makefile" "$L/Version.map" "$L/version_map.awk" "$IJ/"
# The rule is asked for by the target that make expands the object directory
# into, so the recipe of the generated include really runs.  A target that
# make does not know makes the build fail before the recipe, and the absence
# of the command then says nothing at all.
(cd "$IJ" && MAKEOBJDIR="$IJ/obj; touch $IJ/pwned #" make \
    "#/cuda_exports.inc") >"$IJ/log" 2>&1
rc=$?
expect_rc "the generated include builds in an object directory that carries a command" \
    "$rc" 0
[ "$rc" -eq 0 ] || sed -n '1,20p' "$IJ/log"
grep -q 'version_map.awk' "$IJ/log"
rc=$?
expect_rc "the recipe of the generated include ran" "$rc" 0
if [ -n "$(find "$IJ" -name 'cuda_exports.inc' -size +0 -print -quit \
    2>/dev/null)" ]; then
	ok "the generated include is there after the build"
else
	bad "the generated include is there after the build"
fi
[ ! -e "$IJ/pwned" ]
rc=$?
expect_rc "an object directory that carries a command does not run it" "$rc" 0
# The check above has teeth: the same build with the quoting of the paths
# removed runs the command of the object directory.
IM=$W/injection-mutant
mkdir -p "$IM/obj; touch $IM/pwned #/#" "$IM/#"
cp "$L/Makefile" "$L/Version.map" "$L/version_map.awk" "$IM/"
python3 -I - "$IM/Makefile" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
old = '> "${.OBJDIR}/cuda_exports.inc.tmp"'
new = '> ${.OBJDIR}/cuda_exports.inc.tmp'
assert old in text, "the recipe does not write the temporary file as quoted"
open(path, "w").write(text.replace(old, new, 1))
PY
rc=$?
expect_rc "the unquoted recipe mutant changed the Makefile" "$rc" 0
(cd "$IM" && MAKEOBJDIR="$IM/obj; touch $IM/pwned #" make \
    "#/cuda_exports.inc") >"$IM/log" 2>&1
if [ -e "$IM/pwned" ]; then
	ok "the unquoted recipe runs the command of the object directory"
else
	bad "the unquoted recipe runs the command of the object directory"
	sed -n '1,20p' "$IM/log"
fi
cp "$L/version_map.awk" "$SI/version_map.awk"
(cd "$SI" && MAKEOBJDIR="$SI" make "$SI/cuda_exports.inc") \
    >"$SI/ok.log" 2>&1
rc=$?
expect_rc "the restored parser regenerates the include" "$rc" 0
grep -q 'PROC_ENTRY(cuInit)' "$SI/cuda_exports.inc" &&
    grep -q 'PROC_ENTRY(cuDeviceGetCount)' "$SI/cuda_exports.inc"
rc=$?
expect_rc "the regenerated include holds the whole table" "$rc" 0
map_exports "$L/Version.map" | grep -v '^cuGetProcAddress$' | sort \
    >"$W/include-names.expected"
sed -n 's/^\tPROC_ENTRY(\([A-Za-z_][A-Za-z0-9_]*\)),$/\1/p' \
    "$FO/cuda_exports.inc" | sort >"$W/include-names.actual"
cmp -s "$W/include-names.expected" "$W/include-names.actual"
rc=$?
expect_rc "the generated include names every exported entry point but the legacy row" "$rc" 0
# The proc-table version rule belongs to the library, not to the parser: the
# parser only knows which names are exported.
# The proc-table version rule belongs to the library, not the parser: the
# parser only knows which names are exported.  The rule itself is checked by
# behaviour, in the api_test: a lookup below the introduction version must
# return the four-argument form and a lookup at it the five-argument one.
grep -q 'CU_GET_PROC_ADDRESS_V2_MIN_VERSION' "$L/cuda_core.c"
rc=$?
expect_rc "the library names the proc-address introduction version" "$rc" 0
awk '/^static const proc_export proc_exports\[\] = \{/{inside=1;next}
    inside && /^\};/{exit} inside { print }' "$L/cuda_core.c" \
    >"$W/proc-table.body"
sed -n '1p' "$W/proc-table.body" >"$W/proc-table.first"
printf '#include "cuda_exports.inc"\n' >"$W/proc-table.expected"
cmp -s "$W/proc-table.first" "$W/proc-table.expected"
rc=$?
expect_rc "proc lookup table is generated from Version.map" "$rc" 0
sed -n '2,$p' "$W/proc-table.body" >"$W/proc-table.handwritten"
[ "$(wc -l <"$W/proc-table.handwritten" | tr -d ' ')" = 2 ] &&
    grep -q 'cuGetProcAddress_v2' "$W/proc-table.handwritten" &&
    grep -q 'cuGetProcAddress' "$W/proc-table.handwritten"
rc=$?
expect_rc "the only hand-written table row is the legacy cuGetProcAddress entry" "$rc" 0
[ "$(awk 'NF >= 3 && $3 !~ /@@CUDA_1.0$/ { n++ } END { print n + 0 }' \
    "$W/nm.out" 2>/dev/null)" = 0 ]
rc=$?
expect_rc "every defined dynamic symbol carries CUDA_1.0" "$rc" 0
if [ -f "$LIB" ]; then
	readelf -d "$LIB" >"$W/lib-dynamic.out" 2>"$W/lib-dynamic.err"
	rc=$?
else
	rc=1
fi
expect_rc "readelf can inspect libcuda.so.1 dependencies" "$rc" 0
awk '/NEEDED/ { gsub(/[][]/, "", $NF); print $NF }' "$W/lib-dynamic.out" \
    2>/dev/null | sort >"$W/needed.actual"
printf '%s\n' libc.so.7 libthr.so.3 | sort >"$W/needed.expected"
cmp -s "$W/needed.actual" "$W/needed.expected"
rc=$?
expect_rc "libcuda needs only base libc and libthr (no Linux dependency)" "$rc" 0
if [ -x "$INFO" ]; then
	readelf -d "$INFO" >"$W/info-dynamic.out" 2>"$W/info-dynamic.err"
	rc=$?
else
	rc=1
fi
expect_rc "readelf can inspect cuda-native-info dependencies" "$rc" 0
awk '/NEEDED/ { print $NF }' "$W/info-dynamic.out" 2>/dev/null |
    grep -Ei 'linux|nvidia|cuda\.so\.[^1]' &&
    bad "cuda-native-info has an unexpected dependency" || ok "cuda-native-info has no Linux or NVIDIA binary dependency"

# ---- C, C++ and version oracles ------------------------------------------
CFLAGS="-std=gnu11 -Wall -Wextra -Werror"
cc $CFLAGS -pthread -I"$W" -I"$SDK" -I"$T" "$T/api_test.c" -L"$O/lib" -lcuda -lthr \
    -o "$W/bin/api_test" >"$W/build-api.log" 2>&1
rc=$?
expect_rc "api_test compiles against the shared library" "$rc" 0
# The thread sanitizer of the base compiler: the stress case runs under it,
# so the publication order of the registry is checked with a race detector
# too.  The library sources are compiled into the test binary, so the
# detector sees the registry itself and not only the test.
#
# The support of the compiler for the flag is probed on its own.  A compiler
# without the flag is a skip, said with the reason; a build of the project
# sources that fails is a failure.  A compiler that takes the flag and
# cannot link the runtime has failed for a reason of its own: that is a
# failure of the toolchain and not a compiler without the feature.  The three
# are never the same answer.
tsan_build() {	# tsan_build CC LOG ARGS...; 0 built, 1 no flag, 2 build failed, 3 probe failed
	_cc=$1
	_log=$2
	shift 2
	printf 'int main(void) { return 0; }\n' >"$W/tsan-probe.c"
	# The flag is probed by compiling alone: a compiler that does not
	# take it fails here, whatever it says about it.
	if ! "$_cc" -fsanitize=thread -c "$W/tsan-probe.c" \
	    -o "$W/tsan-probe.o" >"$_log.probe" 2>&1; then
		return 1
	fi
	# The runtime is probed by linking: a compiler that takes the flag
	# and cannot link the runtime has failed for a reason of its own.
	if ! "$_cc" -fsanitize=thread "$W/tsan-probe.c" -o "$W/tsan-probe" \
	    >>"$_log.probe" 2>&1; then
		return 3
	fi
	if "$_cc" -fsanitize=thread "$@" >"$_log" 2>&1; then
		return 0
	fi
	return 2
}
tsan_build cc "$W/build-tsan.log" -pthread -I"$W" -I"$O/lib" -I"$L" \
    -I"$SDK" -I"$T" "$T/api_test.c" "$L"/cuda_*.c -lthr \
    -o "$W/bin/api_test_tsan"
case $? in
0)
	env CUDA_NATIVE_BACKEND=fake CUDA_NATIVE_FAKE_PROFILE=gb206,gb10 \
	    "$W/bin/api_test_tsan" init-stress >"$W/tsan-stress.out" 2>&1
	rc=$?
	cat "$W/tsan-stress.out"
	expect_rc "the thread sanitizer build of the stress case is clean" "$rc" 0
	if grep -q 'WARNING: ThreadSanitizer' "$W/tsan-stress.out"; then
		bad "the thread sanitizer reports no data race in the registry"
	else
		ok "the thread sanitizer reports no data race in the registry"
	fi
	;;
1)
	skip "the base compiler has no thread sanitizer: the race check is skipped"
	sed -n '1,5p' "$W/build-tsan.log.probe"
	;;
2)
	bad "the thread sanitizer build of the project sources fails"
	sed -n '1,20p' "$W/build-tsan.log"
	;;
3)
	bad "the thread sanitizer probe failed: the toolchain cannot link the runtime"
	sed -n '1,20p' "$W/build-tsan.log.probe"
	;;
esac
# The classification of a sanitizer build is checked on its own: a compiler
# that takes the flag but fails on the project sources is a failure and not a
# skip.  The wrapper below takes the flag and compiles the probe alone.
cat >"$W/tsan-broken-cc" <<'EOF'
#!/bin/sh
# A compiler that accepts the sanitizer flag and fails on every source of
# the project: the probe compiles alone, the build of the test does not.
for arg in "$@"; do
	case $arg in
	*tsan-probe.c) ;;
	*.c) exit 1 ;;
	esac
done
exec cc "$@"
EOF
chmod +x "$W/tsan-broken-cc"
tsan_build "$W/tsan-broken-cc" "$W/build-tsan-broken.log" \
    -pthread -I"$W" "$T/api_test.c" -o "$W/bin/api_test_broken"
rc=$?
[ "$rc" -eq 2 ]
rc=$?
expect_rc "a sanitizer build that fails on the project sources is a failure, not a skip" "$rc" 0
# The probe is classified on its own: a compiler that does not take the
# flag is a skip, with the reason, and a compiler that takes the flag and
# cannot link the runtime is a failure of the toolchain, never a skip.
cat >"$W/tsan-no-flag-cc" <<'EOF'
#!/bin/sh
# A compiler that does not know the sanitizer flag.
for arg in "$@"; do
	case $arg in
	-fsanitize=*)
		echo "error: unsupported option '$arg'" >&2
		exit 1
		;;
	esac
done
exec cc "$@"
EOF
chmod +x "$W/tsan-no-flag-cc"
tsan_build "$W/tsan-no-flag-cc" "$W/build-tsan-noflag.log" \
    -pthread -I"$W" "$T/api_test.c" -o "$W/bin/api_test_noflag"
rc=$?
[ "$rc" -eq 1 ]
rc=$?
expect_rc "a compiler without the sanitizer flag is a skip" "$rc" 0
cat >"$W/tsan-no-link-cc" <<'EOF'
#!/bin/sh
# A compiler that takes the sanitizer flag and compiles, but cannot link the
# sanitizer runtime: the link of the probe fails.
mode=link
for arg in "$@"; do
	case $arg in
	-c) mode=compile ;;
	esac
done
if [ "$mode" = compile ]; then
	exec cc "$@"
fi
echo "ld: error: cannot find the sanitizer runtime" >&2
exit 1
EOF
chmod +x "$W/tsan-no-link-cc"
tsan_build "$W/tsan-no-link-cc" "$W/build-tsan-nolink.log" \
    -pthread -I"$W" "$T/api_test.c" -o "$W/bin/api_test_nolink"
rc=$?
[ "$rc" -eq 3 ]
rc=$?
expect_rc "a compiler that cannot link the sanitizer runtime is a failure, not a skip" "$rc" 0
cc $CFLAGS -I"$L" -I"$SDK" -I"$T" "$T/version_test.c" "$L/cuda_version.c" \
    -o "$W/bin/version_test" >"$W/build-version.log" 2>&1
rc=$?
expect_rc "version_test compiles against the one shared parser" "$rc" 0
c++ -std=c++11 -Wall -Wextra -Werror -I"$SDK" "$T/header_test.cpp" \
    -L"$O/lib" -lcuda -o "$W/bin/header_test" >"$W/build-header.log" 2>&1
rc=$?
expect_rc "cuda.h compiles as C++ and links with C linkage" "$rc" 0
API=$W/bin/api_test
# The provider and the profile lists come from the library, not from a
# literal of the test: the names are the library's to choose.
"$API" providers >"$W/providers.out" 2>&1
rc=$?
expect_rc "the library reports its provider and profile names" "$rc" 0
library_providers=$(awk '/^provider /{ if (n++) printf ", "; printf "%s", $2 }' \
    "$W/providers.out")
library_synthetic=$(sed -n 's/^synthetic //p' "$W/providers.out")
library_native=$(sed -n 's/^native //p' "$W/providers.out")
library_profiles=$(awk '/^profile /{ if (n++) printf ","; printf "%s", $2 }' \
    "$W/providers.out")
library_default_profile=$(sed -n 's/^default-profile //p' "$W/providers.out")
library_hint=$(sed -n 's/^hint //p' "$W/providers.out")
[ -n "$library_providers" ] && [ -n "$library_synthetic" ] &&
    [ -n "$library_profiles" ] && [ -n "$library_hint" ]
rc=$?
expect_rc "the library names its providers, its profiles and its advice" "$rc" 0
run_case "version parser and formatter assertions" "$W/bin/version_test"
run_case "C++ header and pre-initialization context check" "$W/bin/header_test"
run_case "API core, errors and every proc export" env CUDA_NATIVE_BACKEND=fake "$API" core
run_case "the native queries do not initialize the provider" env \
    CUDA_NATIVE_BACKEND=fake "$API" native-queries
env CUDA_NATIVE_BACKEND=fake "$API" proc-from-stdin <"$W/exports.actual" >"$W/proc-abi.out" 2>&1
rc=$?
cat "$W/proc-abi.out"
expect_rc "every dynamic export resolves to its proc-table address" "$rc" 0
run_case "proc lookup works before cuInit" env CUDA_NATIVE_BACKEND=fake \
    "$API" proc-preinit
run_case "fake GB206 and GB10 profiles" env CUDA_NATIVE_BACKEND=fake \
    CUDA_NATIVE_FAKE_PROFILE=gb206,gb10 "$API" profiles
run_case "primary and current contexts across two threads" env \
    CUDA_NATIVE_BACKEND=fake CUDA_NATIVE_FAKE_PROFILE=gb206,gb10 "$API" threads
run_case "context state follows reordered physical devices" env \
    CUDA_NATIVE_BACKEND=fake CUDA_NATIVE_FAKE_PROFILE=gb206,gb10 CUDA_VISIBLE_DEVICES=1,0 \
    "$API" threads
run_case "pthread_once concurrent cuInit" env CUDA_NATIVE_BACKEND=fake \
    CUDA_NATIVE_FAKE_PROFILE=gb206,gb10 "$API" init-race
run_case "32 threads call cuInit and cuDeviceGetCount at once, 200 rounds" env \
    CUDA_NATIVE_BACKEND=fake CUDA_NATIVE_FAKE_PROFILE=gb206,gb10 "$API" init-stress
run_case "the proc-address version boundary returns the two forms" env \
    CUDA_NATIVE_BACKEND=fake "$API" proc-version
run_case "a concurrent observer never sees partial initialization" env \
    CUDA_NATIVE_BACKEND=fake CUDA_NATIVE_FAKE_PROFILE=gb206,gb10 \
    CUDA_NATIVE_FAKE_ENUM_DELAY_MS=100 "$API" init-observer
run_case "an NVRM observer never sees false success during initialization" env \
    CUDA_NATIVE_BACKEND=nvrm "$API" init-observer
run_case "NVRM provider is a not-supported stub" env CUDA_NATIVE_BACKEND=nvrm "$API" nvrm
run_case "the backend name follows the calling process environment" env \
    CUDA_NATIVE_BACKEND=fake "$API" backend-name
run_case "unknown provider fails cuInit and later device calls" env \
    CUDA_NATIVE_BACKEND=not-a-provider "$API" bad-backend
run_case "unknown fake profile fails cuInit and later device calls" env \
    CUDA_NATIVE_BACKEND=fake CUDA_NATIVE_FAKE_PROFILE=not-a-profile "$API" bad-profile
run_case "an empty fake profile fails cuInit permanently" env \
    CUDA_NATIVE_BACKEND=fake CUDA_NATIVE_FAKE_PROFILE= "$API" bad-profile
run_case "attribute failures preserve every probed output" env \
    CUDA_NATIVE_BACKEND=fake CUDA_NATIVE_FAKE_UNSUPPORTED_COOPERATIVE=1 \
    "$API" attribute-error

run_case "visibility defaults to physical order" env CUDA_NATIVE_BACKEND=fake \
    CUDA_NATIVE_FAKE_PROFILE=gb206,gb10 "$API" order \
    "cuda-native fake GB206" "cuda-native fake GB10"
run_case "visibility filters and reorders indices" env CUDA_NATIVE_BACKEND=fake \
    CUDA_NATIVE_FAKE_PROFILE=gb206,gb10 CUDA_VISIBLE_DEVICES=1,0 "$API" order \
    "cuda-native fake GB10" "cuda-native fake GB206"
run_case "visibility truncates at an invalid positive index" env \
    CUDA_NATIVE_BACKEND=fake CUDA_NATIVE_FAKE_PROFILE=gb206,gb10 CUDA_VISIBLE_DEVICES=0,999,1 \
    "$API" order "cuda-native fake GB206"
run_case "visibility stops at a repeated physical device" env \
    CUDA_NATIVE_BACKEND=fake CUDA_NATIVE_FAKE_PROFILE=gb206,gb10 \
    CUDA_VISIBLE_DEVICES=0,0,1 "$API" order "cuda-native fake GB206"
run_case "visibility truncates at a negative index" env CUDA_NATIVE_BACKEND=fake \
    CUDA_NATIVE_FAKE_PROFILE=gb206,gb10 CUDA_VISIBLE_DEVICES=0,-1,1 "$API" order \
    "cuda-native fake GB206"
run_case "an empty visibility string hides every device" env CUDA_NATIVE_BACKEND=fake \
    CUDA_NATIVE_FAKE_PROFILE=gb206,gb10 CUDA_VISIBLE_DEVICES= "$API" order
run_case "full GPU UUIDs filter and reorder" env CUDA_NATIVE_BACKEND=fake \
    CUDA_NATIVE_FAKE_PROFILE=gb206,gb10 \
    CUDA_VISIBLE_DEVICES=GPU-cb14a000-0000-4000-8000-000000000002,GPU-cb14a000-0000-4000-8000-000000000001 \
    "$API" uuid-order cb14a000-0000-4000-8000-000000000002 \
    cb14a000-0000-4000-8000-000000000001
run_case "an unambiguous abbreviated GPU UUID selects its device" env \
    CUDA_NATIVE_BACKEND=fake CUDA_NATIVE_FAKE_PROFILE=gb206 \
    CUDA_VISIBLE_DEVICES=GPU-cb14a000 \
    "$API" uuid-order cb14a000-0000-4000-8000-000000000001
run_case "an uppercase abbreviated GPU UUID selects its device" env \
    CUDA_NATIVE_BACKEND=fake CUDA_NATIVE_FAKE_PROFILE=gb206 \
    CUDA_VISIBLE_DEVICES=GPU-CB14A000 \
    "$API" uuid-order cb14a000-0000-4000-8000-000000000001
run_case "an ambiguous UUID prefix hides all following entries" env \
    CUDA_NATIVE_BACKEND=fake CUDA_NATIVE_FAKE_PROFILE=gb206,gb10 CUDA_VISIBLE_DEVICES=GPU-cb,0 \
    "$API" order
run_case "a UUID provider failure aborts initialization permanently" env \
    CUDA_NATIVE_BACKEND=fake CUDA_NATIVE_FAKE_PROFILE=gb206,gb10 \
    CUDA_NATIVE_FAKE_UUID_ERROR=1 CUDA_VISIBLE_DEVICES=GPU-cb14a000 \
    "$API" uuid-error
# The library tells the caller why the initialization failed: the reason is
# one of the named values, and a caller does not have to guess it from the
# error code.
env CUDA_NATIVE_BACKEND=not-a-provider "$API" init-reason \
    >"$W/reason-unknown.out" 2>&1
rc=$?
expect_rc "the reason query runs after a failed initialization" "$rc" 0
grep -q '^reason unknown-provider$' "$W/reason-unknown.out"
rc=$?
expect_rc "the library names an unknown provider as the reason" "$rc" 0
env CUDA_NATIVE_BACKEND=nvrm "$API" init-reason >"$W/reason-nvrm.out" 2>&1
rc=$?
expect_rc "the reason query runs for an unsupported provider" "$rc" 0
grep -q '^reason provider-unsupported$' "$W/reason-nvrm.out"
rc=$?
expect_rc "the library names an unsupported provider as the reason" "$rc" 0
env CUDA_NATIVE_BACKEND=fake CUDA_NATIVE_FAKE_PROFILE=gb206,gb10 "$API" \
    init-reason >"$W/reason-ok.out" 2>&1
rc=$?
expect_rc "the reason query runs after a successful initialization" "$rc" 0
grep -q '^reason ok$' "$W/reason-ok.out"
rc=$?
expect_rc "the library reports no reason for a successful initialization" "$rc" 0
# Before any initialization is attempted the reason is its own state, and it
# is not the state of a successful initialization.
"$API" preinit-reason >"$W/reason-preinit.out" 2>&1
rc=$?
expect_rc "the reason query runs before any initialization" "$rc" 0
grep -q '^reason not-attempted$' "$W/reason-preinit.out"
rc=$?
expect_rc "the library says that no initialization was attempted yet" "$rc" 0
profiles64=$(python3 -I -c 'print(",".join(["gb206"] * 64))')
profiles65=$(python3 -I -c 'print(",".join(["gb206"] * 65))')
visibility64=$(python3 -I -c 'print(",".join(str(i) for i in range(64)))')
visibility65=$(python3 -I -c 'print(",".join(str(i) for i in range(65)))')
run_case "visibility accepts exactly 64 distinct entries" env CUDA_NATIVE_BACKEND=fake \
    CUDA_NATIVE_FAKE_PROFILE="$profiles64" CUDA_VISIBLE_DEVICES="$visibility64" \
    "$API" visibility-cap
run_case "visibility stops at an invalid entry after 64 distinct devices" env \
    CUDA_NATIVE_BACKEND=fake CUDA_NATIVE_FAKE_PROFILE="$profiles64" \
    CUDA_VISIBLE_DEVICES="$visibility65" "$API" visibility-cap
run_case "a 65th valid visible device exceeds the library device limit" env \
    CUDA_NATIVE_BACKEND=fake CUDA_NATIVE_FAKE_PROFILE="$profiles65" \
    CUDA_VISIBLE_DEVICES="$visibility65" "$API" bad-visibility
env CUDA_NATIVE_BACKEND=fake CUDA_NATIVE_FAKE_PROFILE="$profiles65" \
    CUDA_VISIBLE_DEVICES="$visibility65" "$INFO" >"$W/overflow.txt" \
    2>"$W/overflow.err"
rc=$?
expect_rc "a visibility list beyond the device limit returns 1" "$rc" 1
grep -q "^cuda-native-info: $library_synthetic provider: CUDA_ERROR_INVALID_VALUE:" \
    "$W/overflow.err"
rc=$?
expect_rc "the overflow diagnostic names the invalid value error" "$rc" 0
grep -q '64' "$W/overflow.err" && grep -q 'CUDA_VISIBLE_DEVICES' "$W/overflow.err"
rc=$?
expect_rc "the overflow diagnostic names the device limit and the filter" "$rc" 0
env CUDA_NATIVE_BACKEND=fake CUDA_NATIVE_FAKE_PROFILE="$profiles65" \
    "$INFO" >"$W/overflow-unfiltered.txt" 2>"$W/overflow-unfiltered.err"
rc=$?
expect_rc "more devices than the limit return 1 without a visibility filter" "$rc" 1
grep -q '64' "$W/overflow-unfiltered.err" &&
    grep -q 'CUDA_VISIBLE_DEVICES' "$W/overflow-unfiltered.err"
rc=$?
expect_rc "the unfiltered overflow diagnostic names the device limit and the filter" "$rc" 0
# The library says why the initialization failed, and the device-limit hint
# is printed for that reason only.
env CUDA_NATIVE_BACKEND=fake CUDA_NATIVE_FAKE_PROFILE="$profiles65" \
    CUDA_VISIBLE_DEVICES="$visibility65" "$API" init-reason \
    >"$W/reason-limit.out" 2>&1
rc=$?
expect_rc "the reason query runs for the device limit" "$rc" 0
grep -q '^reason device-limit$' "$W/reason-limit.out"
rc=$?
expect_rc "the library names the device limit as the reason" "$rc" 0
# A failure that is not the overflow gets no device-limit hint: a provider
# list longer than the registry holds fails with an invalid value too.
profiles129=$(python3 -I -c 'print(",".join(["gb206"] * 129))')
env CUDA_NATIVE_BACKEND=fake CUDA_NATIVE_FAKE_PROFILE="$profiles129" "$INFO" \
    >"$W/provider-limit.txt" 2>"$W/provider-limit.err"
rc=$?
expect_rc "a provider list beyond the registry returns 1" "$rc" 1
if grep -q 'at most 64 devices' "$W/provider-limit.err"; then
	bad "a failure that is not the device limit prints no device-limit hint"
else
	ok "a failure that is not the device limit prints no device-limit hint"
fi
# The capacity failure of the provider has its own reason and says what to
# do next: the bound of the registry and the setting that can lower the
# count of the provider.  The visibility filter cannot lower it: the
# registry refuses the count of the provider before the filter is applied,
# so the diagnostic must not advertise the filter as the remedy.
grep -q '128' "$W/provider-limit.err" &&
    grep -q 'CUDA_NATIVE_FAKE_PROFILE' "$W/provider-limit.err"
rc=$?
expect_rc "the provider capacity diagnostic names the bound and the remedy" "$rc" 0
if grep -q 'CUDA_VISIBLE_DEVICES' "$W/provider-limit.err"; then
	bad "the provider capacity diagnostic does not advertise the visibility filter"
else
	ok "the provider capacity diagnostic does not advertise the visibility filter"
fi
# The filter does not change the failure either: the count of the provider
# is refused before the filter is read, so the same reason is reported.
env CUDA_NATIVE_BACKEND=fake CUDA_NATIVE_FAKE_PROFILE="$profiles129" \
    CUDA_VISIBLE_DEVICES=0 "$INFO" >"$W/provider-limit-filtered.txt" \
    2>"$W/provider-limit-filtered.err"
rc=$?
expect_rc "a provider list beyond the registry fails with a filter too" "$rc" 1
grep -q 'CUDA_NATIVE_FAKE_PROFILE' "$W/provider-limit-filtered.err" &&
    ! grep -q 'CUDA_VISIBLE_DEVICES' "$W/provider-limit-filtered.err"
rc=$?
expect_rc "the filtered provider capacity diagnostic names the setting that fixes it" "$rc" 0
env CUDA_NATIVE_BACKEND=fake CUDA_NATIVE_FAKE_PROFILE="$profiles129" "$API" \
    init-reason >"$W/reason-provider.out" 2>&1
rc=$?
expect_rc "the reason query runs for a failing provider" "$rc" 0
grep -q '^reason provider-device-limit$' "$W/reason-provider.out"
rc=$?
expect_rc "the library names the provider device limit as the reason" "$rc" 0
# A visibility entry that names no device ends the list; it is not a count
# overflow and gets no device-limit hint.
for bad in not-an-index 999 0,0; do
	env CUDA_NATIVE_BACKEND=fake CUDA_VISIBLE_DEVICES="$bad" "$INFO" \
	    >"$W/bad-visibility.out" 2>"$W/bad-visibility.err"
	rc=$?
	expect_rc "a bad visibility entry stops the list instead of failing: $bad" \
	    "$rc" 0
	if grep -q 'at most 64 devices' "$W/bad-visibility.err"; then
		bad "a bad visibility entry prints no device-limit hint: $bad"
	else
		ok "a bad visibility entry prints no device-limit hint: $bad"
	fi
done
# The limit counts the selected devices: 65 provider devices and a filter
# that selects one are a valid report.
env CUDA_NATIVE_BACKEND=fake CUDA_NATIVE_FAKE_PROFILE="$profiles65" \
    CUDA_VISIBLE_DEVICES=0 "$INFO" --json >"$W/filtered-limit.json" \
    2>"$W/filtered-limit.err"
rc=$?
expect_rc "65 provider devices with a one-device filter succeed" "$rc" 0
python3 -I - "$W/filtered-limit.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["device_count"] == 1, d["device_count"]
assert len(d["devices"]) == 1, d["devices"]
PY
rc=$?
expect_rc "the filtered report shows the one selected device" "$rc" 0

# ---- assertion-level source mutants --------------------------------------
mutant() {	# mutant NAME FILE SED-EXPR VISIBILITY(- for unset) MODE [ARGS ...]
	_name=$1
	_file=$2
	_expr=$3
	_visibility=$4
	_mode=$5
	shift 5
	# MUTANT_PROFILE selects the provider device list of the mutant run.
	_profile=${MUTANT_PROFILE:-gb206,gb10}
	_md=$W/mutant.$_name
	mkdir -p "$_md"
	cp "$L"/*.c "$L"/*.h "$_md"/
	sed -i '' "$_expr" "$_md/$_file"
	if cmp -s "$_md/$_file" "$L/$_file"; then
		bad "mutant $_name: the source edit did not apply"
		return
	fi
	cc -std=gnu11 -w -pthread -I"$W" -I"$O/lib" -I"$_md" -I"$SDK" -I"$T" \
	    "$T/api_test.c" \
	    "$_md"/*.c -o "$_md/api_test" >"$_md/build.log" 2>&1
	if [ "$?" -ne 0 ]; then
		bad "mutant $_name: does not compile (not an assertion oracle)"
		return
	fi
	if [ "$_visibility" = - ]; then
		env CUDA_NATIVE_BACKEND=fake CUDA_NATIVE_FAKE_PROFILE="$_profile" \
		    "$_md/api_test" "$_mode" "$@" >"$_md/run.log" 2>&1
	else
		env CUDA_NATIVE_BACKEND=fake CUDA_NATIVE_FAKE_PROFILE="$_profile" \
		    CUDA_VISIBLE_DEVICES="$_visibility" "$_md/api_test" "$_mode" "$@" \
		    >"$_md/run.log" 2>&1
	fi
	_rc=$?
	if [ "$_rc" -ne 0 ] && grep -q '^FAIL ' "$_md/run.log"; then
		ok "mutant killed by assertions: $_name"
		tail -n 1 "$_md/run.log"
	else
		bad "mutant SURVIVED or did not fail by assertion: $_name (rc=$_rc)"
	fi
}
mutant fake-sm-count cuda_fake.c 's/\.multiprocessors = 36/.multiprocessors = 35/' \
    - profiles
mutant context-set-current cuda_core.c \
    's/return (cuda_registry_current_set(ctx));/return (CUDA_ERROR_INVALID_CONTEXT);/' \
    - threads
mutant visibility-invalid-index cuda_registry.c \
    's/if (value < registry\.physical_count)/if (1)/; s/\*physical_index = value;/*physical_index = value >= registry.physical_count ? 1 : value;/' \
    0,999,1 order "cuda-native fake GB206"
# The device limit is a real error: without the overflow return the 65th valid
# visible device would be accepted, and this mutant must be killed.
MUTANT_PROFILE="$profiles65"
mutant visibility-overflow cuda_registry.c \
    's/if (registry\.visible_count == CUDA_NATIVE_MAX_DEVICES)/if (0)/' \
    "$visibility65" bad-visibility
# The version rule of the legacy proc-address row is checked by behaviour: a
# lookup below the introduction version returns the four-argument form and a
# lookup at it the five-argument one.  A mutant with the wrong threshold must
# be killed by that lookup, which the source checks of an earlier round
# could not do: the comment keeps the number either way.
mutant proc-version-threshold cuda_core.c \
    's/#define CU_GET_PROC_ADDRESS_V2_MIN_VERSION 12000/#define CU_GET_PROC_ADDRESS_V2_MIN_VERSION 13000/' \
    - proc-version
MUTANT_PROFILE="gb206,gb10"
if grep -n '"\$TMPDIR/mutant' "$SRC/tests/libcuda_test.sh" >"$W/mutant-paths.out"; then
	cat "$W/mutant-paths.out"
	bad "mutant logs stay inside the private per-mutant directory"
else
	ok "mutant logs stay inside the private per-mutant directory"
fi

# ---- CLI text, JSON, JSON Lines and schema --------------------------------
run_case "text output on the default fake device" env CUDA_NATIVE_BACKEND=fake "$INFO"
env CUDA_NATIVE_BACKEND=fake "$INFO" >"$W/text.out" 2>"$W/text.err"
rc=$?
expect_rc "text mode exit status" "$rc" 0
grep -q '^cuda_version 13.0 (13, 0, 0)$' "$W/text.out" &&
    grep -q '^cuda_native_version 0.1.0 (0, 1, 0)$' "$W/text.out" &&
    grep -q '^  name cuda-native fake GB206$' "$W/text.out" &&
    grep -q '^  total_memory_bytes 17179869184$' "$W/text.out" &&
    grep -q '^  multiprocessor_count 36$' "$W/text.out" && [ ! -s "$W/text.err" ]
rc=$?
expect_rc "text output contains versions, identity, memory and SM count" "$rc" 0

VAL="python3 -I $SRC/tests/libnvrm/schema_validate.py $SCHEMA"
for profile in gb206 gb206,gb10; do
	env CUDA_NATIVE_BACKEND=fake CUDA_NATIVE_FAKE_PROFILE=$profile "$INFO" --json >"$W/$profile.json"
	rc=$?
	expect_rc "--json exits 0 for $profile" "$rc" 0
	$VAL "$W/$profile.json"
	rc=$?
	expect_rc "--json validates for $profile" "$rc" 0
	env CUDA_NATIVE_BACKEND=fake CUDA_NATIVE_FAKE_PROFILE=$profile "$INFO" --jsonl >"$W/$profile.jsonl"
	rc=$?
	expect_rc "--jsonl exits 0 for $profile" "$rc" 0
	$VAL "$W/$profile.jsonl"
	rc=$?
	expect_rc "--jsonl validates each record for $profile" "$rc" 0
done
[ "$(wc -l <"$W/gb206,gb10.json" | tr -d ' ')" = 1 ]
rc=$?
expect_rc "--json is exactly one line" "$rc" 0
[ "$(wc -l <"$W/gb206,gb10.jsonl" | tr -d ' ')" = 4 ]
rc=$?
expect_rc "two-device --jsonl is header + 2 devices + end" "$rc" 0
python3 -I - "$W/gb206.json" "$W/gb206,gb10.json" "$W/gb206,gb10.jsonl" <<'PY'
import json, sys
one = json.load(open(sys.argv[1]))
two = json.load(open(sys.argv[2]))
stream = [json.loads(line) for line in open(sys.argv[3])]
assert one["cuda_version"] == {"string":"13.0", "major":13, "minor":0, "patch":0}
assert one["cuda_native_version"] == {"string":"0.1.0", "major":0, "minor":1, "patch":0}
a = one["devices"][0]
assert a["uuid"] == "GPU-cb14a000-0000-4000-8000-000000000001"
assert a["total_memory_bytes"] == 16 * 1024**3
assert a["attributes"]["compute_capability_major"] == 12
assert a["attributes"]["compute_capability_minor"] == 0
assert a["attributes"]["multiprocessor_count"] == 36
assert a["attributes"]["integrated"] == 0
assert a["attributes"]["max_threads_per_block"] == 1024
assert a["attributes"]["max_shared_memory_per_block"] == 48 * 1024
assert a["attributes"]["max_shared_memory_per_block_optin"] == 99 * 1024
assert a["attributes"]["warp_size"] == 32
assert a["attributes"]["virtual_memory_management_supported"] == 1
assert a["attributes"]["cooperative_launch"] == 0
b = two["devices"][1]
assert b["name"] == "cuda-native fake GB10"
assert b["uuid"] == "GPU-cb14a000-0000-4000-8000-000000000002"
assert b["total_memory_bytes"] == 128 * 1024**3
assert b["attributes"]["compute_capability_minor"] == 1
assert b["attributes"]["multiprocessor_count"] == 48
assert b["attributes"]["integrated"] == 1
assert b["attributes"]["pci_domain_id"] == 15
assert two["device_count"] == len(two["devices"]) == 2
assert [d["ordinal"] for d in two["devices"]] == [0, 1]
assert [r["kind"] for r in stream] == ["header", "device", "device", "end"]
assert stream[0]["device_count"] == stream[-1]["count"] == 2
PY
rc=$?
expect_rc "JSON semantics: all synthetic values, versions and stream counts" "$rc" 0

env CUDA_NATIVE_BACKEND=fake CUDA_NATIVE_FAKE_UNSUPPORTED_COOPERATIVE=1 \
    "$INFO" --json >"$W/unsupported-attribute.json" 2>"$W/unsupported-attribute.err"
rc=$?
expect_rc "an unsupported attribute does not abort --json" "$rc" 0
$VAL "$W/unsupported-attribute.json"
rc=$?
expect_rc "JSON null for an unsupported attribute validates" "$rc" 0
env CUDA_NATIVE_BACKEND=fake CUDA_NATIVE_FAKE_UNSUPPORTED_COOPERATIVE=1 \
    "$INFO" --jsonl >"$W/unsupported-attribute.jsonl" 2>>"$W/unsupported-attribute.err"
rc=$?
expect_rc "an unsupported attribute does not abort --jsonl" "$rc" 0
$VAL "$W/unsupported-attribute.jsonl"
rc=$?
expect_rc "JSON Lines null for an unsupported attribute validates" "$rc" 0
python3 -I - "$W/unsupported-attribute.json" "$W/unsupported-attribute.jsonl" <<'PY'
import json, sys
document = json.load(open(sys.argv[1]))
stream = [json.loads(line) for line in open(sys.argv[2])]
assert document["devices"][0]["attributes"]["cooperative_launch"] is None
assert stream[1]["attributes"]["cooperative_launch"] is None
assert document["devices"][0]["attributes"]["warp_size"] == 32
PY
rc=$?
expect_rc "unsupported attributes stay present as null" "$rc" 0

env CUDA_NATIVE_BACKEND=fake CUDA_NATIVE_FAKE_PROFILE=utf8 "$INFO" --json \
    >"$W/utf8.json" 2>"$W/utf8.err"
rc=$?
expect_rc "UTF-8 fake profile produces JSON" "$rc" 0
python3 -I - "$W/utf8.json" <<'PY'
import json, sys
raw = open(sys.argv[1], "rb").read()
document = json.loads(raw)
expected = "cuda-native fake \u2122 \u00e9 \ufffd \x01\x7f"
assert document["devices"][0]["name"] == expected, repr(document["devices"][0]["name"])
assert "\u2122".encode("utf-8") in raw
assert "\u00e9".encode("utf-8") in raw
assert b"\\ufffd" in raw
assert b"\\u0001" in raw and b"\\u007f" in raw
PY
rc=$?
expect_rc "JSON preserves UTF-8, replaces invalid bytes and escapes controls" "$rc" 0

# Every code point the library refuses to copy through is escaped: the raw
# bytes are absent and the escape is present.  One case per code point, in
# the text diagnostic and in the JSON document.  The list of code points is
# read from the table of the tool, so a code point that is added to the
# table is added to the test with it and the test keeps no copy of it.
control_ranges() {	# control_ranges HEADER; one "first:last" pair per line, in hex
	sed -n 's/.*\(0x[0-9a-fA-F]\{1,\}\)[^0-9a-fA-Fx]*\(0x[0-9a-fA-F]\{1,\}\).*/\1:\2/p' \
	    "$1"
}
control_points() {	# control_points HEADER; one code point per line, in hex
	for pair in $(control_ranges "$1"); do
		first=${pair%:*}
		last=${pair#*:}
		i=$((first))
		last=$((last))
		while [ "$i" -le "$last" ]; do
			# A NUL cannot travel through the environment.
			if [ "$i" -ne 0 ]; then
				printf '%04x\n' "$i"
			fi
			i=$((i + 1))
		done
	done
}
# The UTF-8 bytes of a code point as the octal escapes of printf: the shell
# of the test has no \u in its printf.
utf8_escapes() {	# utf8_escapes CODEPOINT
	_n=$((0x$1))
	if [ "$_n" -lt 128 ]; then
		printf '\\%03o' "$_n"
	elif [ "$_n" -lt 2048 ]; then
		printf '\\%03o\\%03o' $((0xC0 | (_n >> 6))) \
		    $((0x80 | (_n & 0x3F)))
	elif [ "$_n" -lt 65536 ]; then
		printf '\\%03o\\%03o\\%03o' $((0xE0 | (_n >> 12))) \
		    $((0x80 | ((_n >> 6) & 0x3F))) $((0x80 | (_n & 0x3F)))
	else
		printf '\\%03o\\%03o\\%03o\\%03o' $((0xF0 | (_n >> 18))) \
		    $((0x80 | ((_n >> 12) & 0x3F))) \
		    $((0x80 | ((_n >> 6) & 0x3F))) $((0x80 | (_n & 0x3F)))
	fi
}
control_case() {	# control_case CODEPOINT
	_cp=$1
	_raw=$(printf "x$(utf8_escapes "$_cp")y")
	env CUDA_NATIVE_BACKEND="$_raw" "$INFO" \
	    >"$W/control.out" 2>"$W/control.err"
	rc=$?
	if [ "$rc" -eq 1 ]; then
		ok "the control code point U+$_cp is refused"
	else
		bad "the control code point U+$_cp is refused (rc=$rc)"
	fi
	if grep -qF "\\u$_cp" "$W/control.err"; then
		ok "the text diagnostic escapes U+$_cp"
	else
		bad "the text diagnostic escapes U+$_cp"
	fi
	case $_cp in
	0009|000a|000d)
		# A white space control is in the output itself, so only the
		# escape can be checked.
		;;
	*)
		if grep -qF "$_raw" "$W/control.err"; then
			bad "the text diagnostic holds no raw U+$_cp"
		else
			ok "the text diagnostic holds no raw U+$_cp"
		fi
		;;
	esac
	env CUDA_NATIVE_BACKEND="$_raw" "$INFO" --json \
	    >"$W/control.json" 2>"$W/control-json.err"
	rc=$?
	if [ "$rc" -eq 1 ] && grep -qF "\\u$_cp" "$W/control.json"; then
		ok "the JSON document escapes U+$_cp"
	else
		bad "the JSON document escapes U+$_cp (rc=$rc)"
	fi
}
profile_control_case() {	# profile_control_case CODEPOINT
	_cp=$1
	_raw=$(printf "gb$(utf8_escapes "$_cp")")
	env CUDA_NATIVE_BACKEND=fake CUDA_NATIVE_FAKE_PROFILE="$_raw" "$INFO" \
	    >"$W/profile-control.out" 2>"$W/profile-control.err"
	rc=$?
	if [ "$rc" -eq 1 ] && grep -qF "\\u$_cp" "$W/profile-control.err"; then
		ok "the profile diagnostic escapes U+$_cp"
	else
		bad "the profile diagnostic escapes U+$_cp (rc=$rc)"
	fi
}
for cp in $(control_points "$L/control_ranges.h"); do
	control_case "$cp"
done
# The bidirectional controls are the ones a reader cannot see, so they are
# checked in the profile diagnostic too: every code point of the table that
# is not an ASCII one.
for cp in $(control_points "$L/control_ranges.h" | awk '$0 >= "061c"'); do
	profile_control_case "$cp"
done
# The profile diagnostic wraps the bad value in the delimiter it escapes: a
# value that holds a quote cannot close the value and hide what follows it.
# The delimiter is the double quote, the one the escaping helper escapes, so
# the value that is tested holds a double quote and not another one.
env CUDA_NATIVE_BACKEND=fake CUDA_NATIVE_FAKE_PROFILE='a"b' "$INFO" \
    >"$W/quote-profile.out" 2>"$W/quote-profile.err"
rc=$?
expect_rc "a profile with the delimiter in it is refused" "$rc" 1
python3 -I - "$W/quote-profile.err" <<'PY'
import sys
text = open(sys.argv[1], errors="replace").read()
assert 'unknown profile "a\\"b"' in text, text
assert 'unknown profile "a"b"' not in text, text
PY
rc=$?
expect_rc "the profile diagnostic escapes the quote it uses as a delimiter" "$rc" 0
# A quote that is not the delimiter is an ordinary character: it is copied
# through, inside the delimited value.
env CUDA_NATIVE_BACKEND=fake CUDA_NATIVE_FAKE_PROFILE="a'b" "$INFO" \
    >"$W/apostrophe-profile.out" 2>"$W/apostrophe-profile.err"
rc=$?
expect_rc "a profile with an apostrophe in it is refused" "$rc" 1
python3 -I - "$W/apostrophe-profile.err" <<'PY'
import sys
text = open(sys.argv[1], errors="replace").read()
assert 'unknown profile "a\'b"' in text, text
PY
rc=$?
expect_rc "the profile diagnostic keeps the quote that is not its delimiter" "$rc" 0

# A changed library default must change the CLI's reported backend too.
DB=$W/default-backend
mkdir -p "$DB"
cp "$L/cuda_backend.c" "$DB/cuda_backend.c"
sed -i '' 's/default_backend = "nvrm"/default_backend = "fake"/' \
    "$DB/cuda_backend.c"
! cmp -s "$DB/cuda_backend.c" "$L/cuda_backend.c"
rc=$?
expect_rc "the shared backend-default mutant changed the library default" "$rc" 0
(
    cc $CFLAGS -fPIC -shared -Wl,-Bsymbolic-functions \
        -Wl,--version-script="$L/Version.map" -I"$O/lib" -I"$L" -I"$SDK" \
        "$L/cuda_core.c" "$L/cuda_registry.c" "$L/cuda_fake.c" \
        "$L/cuda_nvrm.c" "$L/cuda_errors.c" "$DB/cuda_backend.c" \
        "$L/cuda_version.c" "$L/cuda_uuid.c" -lthr -o "$DB/libcuda.so.1" &&
    ln -s libcuda.so.1 "$DB/libcuda.so" &&
    cc $CFLAGS -I"$O/info" -I"$L" -I"$SDK" \
        "$L/cuda-native-info/cuda-native-info.c" "$L/cuda_version.c" \
        "$L/cuda_uuid.c" -L"$DB" -lcuda -lthr -o "$DB/cuda-native-info"
) >"$DB/build.log" 2>&1
rc=$?
expect_rc "shared backend-default mutant builds" "$rc" 0
if [ "$rc" -eq 0 ]; then
	env -u CUDA_NATIVE_BACKEND LD_LIBRARY_PATH="$DB" "$DB/cuda-native-info" \
	    --json >"$DB/output.json" 2>"$DB/error.log"
	rc=$?
	expect_rc "patched fake default produces a device report" "$rc" 0
	python3 -I - "$DB/output.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["backend"] == "fake", d["backend"]
assert d["device_count"] == 1
assert d["devices"][0]["name"] == "cuda-native fake GB206"
PY
	rc=$?
	expect_rc "CLI backend follows the patched library default" "$rc" 0
	env -u CUDA_NATIVE_BACKEND LD_LIBRARY_PATH="$DB" "$DB/cuda-native-info" \
	    --help >"$DB/help.out" 2>&1
	grep -q "(default $library_synthetic)" "$DB/help.out" &&
	    ! grep -q "(default $library_native)" "$DB/help.out"
	rc=$?
	expect_rc "--help follows the patched library default backend" "$rc" 0
	env -u CUDA_NATIVE_BACKEND CUDA_NATIVE_FAKE_PROFILE=gb100 \
	    LD_LIBRARY_PATH="$DB" "$DB/cuda-native-info" >"$DB/bad-profile.out" \
	    2>"$DB/bad-profile.err"
	rc=$?
	expect_rc "CLI validates profiles against a patched fake default" "$rc" 1
	grep -q 'CUDA_NATIVE_FAKE_PROFILE: unknown profile "gb100"' \
	    "$DB/bad-profile.err"
	rc=$?
	expect_rc "patched fake default retains the named profile diagnostic" "$rc" 0
fi

# A provider profile added to the library must be known to an existing CLI.
PT=$W/profile-table
mkdir -p "$PT"
cp "$L"/*.c "$L"/*.h "$PT"/
python3 -I - "$PT/cuda_fake.c" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
start = text.index('\t{\n\t\t.profile = "gb206",')
end = text.index('\n\t},', start) + len('\n\t},')
entry = text[start:end]
entry = entry.replace('"gb206"', '"gb202"').replace(
    '"cuda-native fake GB206"', '"cuda-native fake GB202"')
entry = entry.replace('0x00, 0x00, 0x00, 0x01 }',
    '0x00, 0x00, 0x00, 0x04 }')
assert entry != text[start:end]
open(path, "w").write(text[:start] + entry + '\n' + text[start:])
PY
(
    cc $CFLAGS -fPIC -shared -Wl,-Bsymbolic-functions \
        -Wl,--version-script="$L/Version.map" -DCUDA_NATIVE_TESTING \
        -I"$O/lib" -I"$PT" -I"$SDK" "$PT"/*.c -lthr -o "$PT/libcuda.so.1" &&
    ln -s libcuda.so.1 "$PT/libcuda.so" &&
    cc $CFLAGS -I"$O/info" -I"$L" -I"$SDK" \
        "$L/cuda-native-info/cuda-native-info.c" "$L/cuda_version.c" \
        "$L/cuda_uuid.c" -L"$PT" -lcuda -lthr -o "$PT/cuda-native-info"
) >"$PT/build.log" 2>&1
rc=$?
expect_rc "added-profile library and unmodified CLI build" "$rc" 0
[ "$rc" -eq 0 ] || sed -n '1,80p' "$PT/build.log"
if [ "$rc" -eq 0 ]; then
	env CUDA_NATIVE_BACKEND=fake CUDA_NATIVE_FAKE_PROFILE=gb202 \
	    LD_LIBRARY_PATH="$PT" "$PT/cuda-native-info" --json \
	    >"$PT/output.json" 2>"$PT/error.log"
	rc=$?
	expect_rc "CLI accepts a profile known only to the library table" "$rc" 0
	if [ -s "$PT/output.json" ]; then
		python3 -I - "$PT/output.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["devices"][0]["name"] == "cuda-native fake GB202"
PY
		rc=$?
	else
		rc=1
	fi
	expect_rc "added profile reaches the CLI device report" "$rc" 0
	env LD_LIBRARY_PATH="$PT" "$PT/cuda-native-info" --help >"$PT/help.out" 2>&1
	grep -q 'gb202' "$PT/help.out" &&
	    ! grep -q '^  gb206,gb10 (default gb206)\.$' "$PT/help.out"
	rc=$?
	expect_rc "--help names the profile the library added" "$rc" 0
fi

# A provider renamed in the library must still take the fake profiles: the CLI
# asks the library which provider takes them, it does not know the names.
# Both providers are renamed here, so a tool that carries a provider name of
# its own names one that does not exist.
SP=$W/provider-mutant
mkdir -p "$SP"
cp "$L"/*.c "$L"/*.h "$SP/"
sed -i '' 's/\.backend = "fake"/.backend = "synthetic"/' "$SP/cuda_fake.c"
sed -i '' 's/\.backend = "nvrm"/.backend = "native"/' "$SP/cuda_nvrm.c"
sed -i '' 's/default_backend = "nvrm"/default_backend = "native"/' \
    "$SP/cuda_backend.c"
grep -q '\.backend = "synthetic"' "$SP/cuda_fake.c" &&
    grep -q '\.backend = "native"' "$SP/cuda_nvrm.c" &&
    grep -q 'default_backend = "native"' "$SP/cuda_backend.c"
rc=$?
expect_rc "the renamed provider mutant changed the library" "$rc" 0
(
    cc $CFLAGS -fPIC -shared -Wl,-Bsymbolic-functions \
        -Wl,--version-script="$L/Version.map" -I"$O/lib" -I"$SP" -I"$SDK" \
        "$SP"/*.c -lthr -o "$SP/libcuda.so.1" &&
    ln -s libcuda.so.1 "$SP/libcuda.so" &&
    cc $CFLAGS -I"$O/info" -I"$L" -I"$SDK" \
        "$L/cuda-native-info/cuda-native-info.c" "$L/cuda_version.c" \
        "$L/cuda_uuid.c" -L"$SP" -lcuda -lthr -o "$SP/cuda-native-info" &&
    cc $CFLAGS -pthread -I"$W" -I"$O/lib" -I"$SP" -I"$SDK" -I"$T" \
        "$T/api_test.c" "$SP"/*.c -lthr -o "$SP/api_test"
) >"$SP/build.log" 2>&1
rc=$?
expect_rc "the renamed provider library and the unmodified CLI build" "$rc" 0
[ "$rc" -eq 0 ] || sed -n '1,80p' "$SP/build.log"
if [ "$rc" -eq 0 ]; then
	env CUDA_NATIVE_BACKEND=synthetic CUDA_NATIVE_FAKE_PROFILE=gb100 \
	    LD_LIBRARY_PATH="$SP" "$SP/cuda-native-info" >"$SP/output.txt" \
	    2>"$SP/error.txt"
	rc=$?
	expect_rc "a renamed provider still gives the named-profile diagnostic" "$rc" 1
	grep -q 'CUDA_NATIVE_FAKE_PROFILE: unknown profile "gb100"' "$SP/error.txt"
	rc=$?
	expect_rc "the renamed provider reaches the named-profile diagnostic" "$rc" 0
	# The provider that takes the profiles applies them: the reported
	# device follows the profile that was asked for.
	env CUDA_NATIVE_BACKEND=synthetic CUDA_NATIVE_FAKE_PROFILE=gb10 \
	    LD_LIBRARY_PATH="$SP" "$SP/cuda-native-info" --json \
	    >"$SP/profile.json" 2>"$SP/profile.err"
	rc=$?
	expect_rc "a renamed provider applies a valid profile" "$rc" 0
	python3 -I - "$SP/profile.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["devices"][0]["name"] == "cuda-native fake GB10", d["devices"][0]["name"]
PY
	rc=$?
	expect_rc "the reported device follows the selected profile" "$rc" 0
	# The advice for the provider that cannot be used comes from the
	# library, so it names the providers the library knows.
	"$SP/api_test" providers >"$SP/providers.out" 2>&1
	rc=$?
	expect_rc "the renamed library reports its provider names" "$rc" 0
	mutant_hint=$(sed -n 's/^hint //p' "$SP/providers.out")
	mutant_synthetic=$(sed -n 's/^synthetic //p' "$SP/providers.out")
	[ -n "$mutant_hint" ] && [ "$mutant_synthetic" = synthetic ]
	rc=$?
	expect_rc "the renamed library advises its own provider names" "$rc" 0
	env CUDA_NATIVE_BACKEND=native LD_LIBRARY_PATH="$SP" \
	    "$SP/cuda-native-info" >"$SP/native.out" 2>"$SP/native.err"
	rc=$?
	expect_rc "the renamed native provider fails as the stub does" "$rc" 1
	grep -q -F "$mutant_hint" "$SP/native.err"
	rc=$?
	expect_rc "the unsupported-provider advice comes from the library" "$rc" 0
fi

# The capability the library reports and the behavior of the provider are
# one fact: a provider that the library says takes the fake profiles applies
# them, so the reported device follows the selected profile.
env CUDA_NATIVE_BACKEND="$library_synthetic" CUDA_NATIVE_FAKE_PROFILE=gb10 \
    "$INFO" --json >"$W/capability.json" 2>"$W/capability.err"
rc=$?
expect_rc "a provider that takes the fake profiles applies them" "$rc" 0
python3 -I - "$W/capability.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["devices"][0]["name"] == "cuda-native fake GB10", d["devices"][0]["name"]
PY
rc=$?
expect_rc "the reported device follows the selected profile" "$rc" 0
# A registry that does not apply the selection leaves the provider with its
# own default, while the library still reports that the provider takes the
# profiles: the mutant must be killed, and a build that fails must be a
# failure and not a skipped check.
PI=$W/profile-ignored-mutant
mkdir -p "$PI"
cp "$L"/*.c "$L"/*.h "$PI/"
sed -i '' 's/registry\.provider->kind == CUDA_PROVIDER_SYNTHETIC/registry.provider->kind != CUDA_PROVIDER_SYNTHETIC/' \
    "$PI/cuda_registry.c"
grep -q 'registry.provider->kind != CUDA_PROVIDER_SYNTHETIC' \
    "$PI/cuda_registry.c"
rc=$?
expect_rc "the profile-ignoring mutant changed the library" "$rc" 0
(
    cc $CFLAGS -fPIC -shared -Wl,-Bsymbolic-functions \
        -Wl,--version-script="$L/Version.map" -I"$O/lib" -I"$PI" -I"$SDK" \
        "$PI"/*.c -lthr -o "$PI/libcuda.so.1" &&
    ln -s libcuda.so.1 "$PI/libcuda.so" &&
    cc $CFLAGS -I"$O/info" -I"$L" -I"$SDK" \
        "$L/cuda-native-info/cuda-native-info.c" "$L/cuda_version.c" \
        "$L/cuda_uuid.c" -L"$PI" -lcuda -lthr -o "$PI/cuda-native-info"
) >"$PI/build.log" 2>&1
rc=$?
expect_rc "the profile-ignoring library and the unmodified CLI build" "$rc" 0
if [ "$rc" -eq 0 ]; then
	env CUDA_NATIVE_BACKEND=fake CUDA_NATIVE_FAKE_PROFILE=gb10 \
	    LD_LIBRARY_PATH="$PI" "$PI/cuda-native-info" --json \
	    >"$PI/profile.json" 2>"$PI/profile.err"
	python3 -I - "$PI/profile.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["devices"][0]["name"] == "cuda-native fake GB10", d["devices"][0]["name"]
PY
	rc=$?
	if [ "$rc" -ne 0 ]; then
		ok "mutant killed by assertions: a provider that ignores the fake profiles"
	else
		bad "mutant SURVIVED: a provider that ignores the fake profiles"
	fi
else
	bad "the profile-ignoring mutant was not exercised: the build failed"
	sed -n '1,40p' "$PI/build.log"
fi

env CUDA_NATIVE_BACKEND=fake CUDA_NATIVE_FAKE_PROFILE=gb206,gb10 CUDA_VISIBLE_DEVICES=1,0 \
    "$INFO" --json >"$W/reordered.json"
python3 -I - "$W/reordered.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert [x["name"] for x in d["devices"]] == ["cuda-native fake GB10", "cuda-native fake GB206"]
PY
rc=$?
expect_rc "CLI observes visibility reordering" "$rc" 0
env CUDA_NATIVE_BACKEND=fake CUDA_NATIVE_FAKE_PROFILE=gb206,gb10 CUDA_VISIBLE_DEVICES= \
    "$INFO" --json >"$W/empty.json"
rc=$?
expect_rc "empty visibility is a successful JSON result" "$rc" 0
$VAL "$W/empty.json"
rc=$?
expect_rc "empty device document validates" "$rc" 0
python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["device_count"] == 0 and d["devices"] == []' "$W/empty.json"
rc=$?
expect_rc "empty device document has count zero and devices []" "$rc" 0
env CUDA_NATIVE_BACKEND=fake CUDA_VISIBLE_DEVICES= "$INFO" --jsonl >"$W/empty.jsonl"
[ "$(wc -l <"$W/empty.jsonl" | tr -d ' ')" = 2 ]
rc=$?
expect_rc "empty JSON Lines output is header + end" "$rc" 0
$VAL "$W/empty.jsonl"
rc=$?
expect_rc "empty JSON Lines output validates" "$rc" 0
env CUDA_NATIVE_BACKEND=fake CUDA_VISIBLE_DEVICES= "$INFO" >"$W/empty.txt"
grep -q '^no CUDA devices are visible (filtered by CUDA_VISIBLE_DEVICES=""; see libcuda(3))$' \
    "$W/empty.txt"
rc=$?
expect_rc "filtered-empty text output names CUDA_VISIBLE_DEVICES" "$rc" 0
env CUDA_NATIVE_BACKEND=fake CUDA_NATIVE_FAKE_PROFILE=gb206,gb10 \
    CUDA_VISIBLE_DEVICES=0,999,1 "$INFO" >"$W/truncated-visibility.txt"
rc=$?
expect_rc "partially visible text report succeeds" "$rc" 0
grep -q '^device_count 1$' "$W/truncated-visibility.txt" &&
    grep -q '^visibility_filter "0,999,1"$' "$W/truncated-visibility.txt"
rc=$?
expect_rc "text report shows the visibility filter before a partial result" "$rc" 0

# A visibility value with a quote, a backslash, a newline and an escape must
# not break the report, and no control byte may reach the terminal.
evil_vis=$(printf '0,"\\\n\033')
env CUDA_NATIVE_BACKEND=fake CUDA_NATIVE_FAKE_PROFILE=gb206,gb10 \
    CUDA_VISIBLE_DEVICES="$evil_vis" "$INFO" >"$W/escaped.txt" 2>"$W/escaped.err"
rc=$?
expect_rc "a visibility value with control bytes still reports" "$rc" 0
[ "$(grep -c '^visibility_filter ' "$W/escaped.txt")" = 1 ]
rc=$?
expect_rc "the escaped visibility filter is exactly one report line" "$rc" 0
grep -q -F 'visibility_filter "0,\"\\\u000a\u001b"' "$W/escaped.txt"
rc=$?
expect_rc "the visibility filter escapes quotes, backslashes and control bytes" "$rc" 0
if grep -q "$(printf '\033')" "$W/escaped.txt"; then
	bad "no escape byte reaches the text report"
else
	ok "no escape byte reaches the text report"
fi
env CUDA_NATIVE_BACKEND=fake CUDA_NATIVE_FAKE_PROFILE=gb206,gb10 \
    CUDA_VISIBLE_DEVICES="$evil_vis" "$INFO" --json >"$W/escaped.json"
rc=$?
expect_rc "the JSON document is written for a visibility value with control bytes" "$rc" 0
python3 -I - "$W/escaped.json" "$evil_vis" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["visibility_filter"] == sys.argv[2], repr(d["visibility_filter"])
PY
rc=$?
expect_rc "the JSON document carries the same escaped visibility filter" "$rc" 0

env CUDA_NATIVE_BACKEND=nvrm "$INFO" --schema >"$W/schema.out"
rc=$?
expect_rc "--schema does not need a working provider" "$rc" 0
cmp -s "$W/schema.out" "$SCHEMA"
rc=$?
expect_rc "--schema is byte-identical to the committed schema" "$rc" 0
python3 -I -c 'import json,sys; json.load(open(sys.argv[1]))' "$SCHEMA"
rc=$?
expect_rc "the committed schema parses as JSON" "$rc" 0
for backend in not-a-provider "$library_native"; do
	env CUDA_NATIVE_BACKEND=$backend "$INFO" --json >"$W/error-$backend.json"
	rc=$?
	expect_rc "provider failure $backend returns 1" "$rc" 1
	$VAL "$W/error-$backend.json"
	rc=$?
	expect_rc "provider failure $backend is a schema-valid error" "$rc" 0
done
python3 -I - "$W/error-not-a-provider.json" "$W/error-$library_native.json" \
    "$library_native" "$library_hint" <<'PY'
import json, sys
da = json.load(open(sys.argv[1]))
db = json.load(open(sys.argv[2]))
native = sys.argv[3]
hint = sys.argv[4]
a = da["error"]
b = db["error"]
assert a["code"] == 1 and a["name"] == "CUDA_ERROR_INVALID_VALUE"
assert b["code"] == 801 and b["name"] == "CUDA_ERROR_NOT_SUPPORTED"
assert da["backend"] == "not-a-provider" and db["backend"] == native
assert hint in b["hint"], (hint, b.get("hint"))
PY
rc=$?
expect_rc "JSON errors carry codes, names, backend and the library's advice" "$rc" 0
env CUDA_NATIVE_BACKEND="$library_native" "$INFO" >"$W/nvrm.out" 2>"$W/nvrm.err"
rc=$?
expect_rc "text provider failure returns 1" "$rc" 1
grep -q 'CUDA_ERROR_NOT_SUPPORTED' "$W/nvrm.err"
rc=$?
expect_rc "text provider failure explains the error on stderr" "$rc" 0
grep -q "^cuda-native-info: $library_native provider: CUDA_ERROR_NOT_SUPPORTED:" \
    "$W/nvrm.err" && grep -q -F "$library_hint" "$W/nvrm.err"
rc=$?
expect_rc "text provider failure names the backend and the library's advice" "$rc" 0
env CUDA_NATIVE_BACKEND=not-a-provider "$INFO" >"$W/bad-backend.out" 2>"$W/bad-backend.err"
rc=$?
expect_rc "an invalid provider environment value returns 1" "$rc" 1
grep -q "^cuda-native-info: CUDA_NATIVE_BACKEND=not-a-provider is not a provider; use one of: $library_providers$" \
    "$W/bad-backend.err"
rc=$?
expect_rc "provider diagnostics name the variable and the library's providers" "$rc" 0
# A control byte in an environment value must not reach the terminal: the
# diagnostic carries the escaped form of the value.
evil_backend=$(printf 'x\033y')
env CUDA_NATIVE_BACKEND="$evil_backend" "$INFO" >"$W/evil-backend.out" \
    2>"$W/evil-backend.err"
rc=$?
expect_rc "an unknown provider with a control byte returns 1" "$rc" 1
grep -q "$(printf '\033')" "$W/evil-backend.err"
rc=$?
if [ "$rc" -eq 0 ]; then
	bad "no escape byte reaches the unknown-provider diagnostic"
else
	ok "no escape byte reaches the unknown-provider diagnostic"
fi
grep -q -F 'x\u001by' "$W/evil-backend.err"
rc=$?
expect_rc "the unknown-provider diagnostic carries the escaped value" "$rc" 0
env CUDA_NATIVE_BACKEND=fake CUDA_NATIVE_FAKE_PROFILE=gb100 "$INFO" \
    >"$W/bad-profile.out" 2>"$W/bad-profile.err"
rc=$?
expect_rc "an unknown fake profile environment value returns 1" "$rc" 1
grep -q "CUDA_NATIVE_FAKE_PROFILE: unknown profile \"gb100\"; known profiles: $library_profiles; give one or several separated by commas" \
    "$W/bad-profile.err"
rc=$?
expect_rc "profile diagnostics name the variable, value and valid profiles" "$rc" 0
# The list the diagnostic prints is a value the variable accepts: it is
# printed without spaces, so a reader can copy it.
known_profiles=$(sed -n 's/.*known profiles: \([^;]*\); give one or several.*/\1/p' \
    "$W/bad-profile.err")
[ -n "$known_profiles" ]
rc=$?
expect_rc "the unknown-profile diagnostic prints the known profiles" "$rc" 0
env CUDA_NATIVE_BACKEND=fake CUDA_NATIVE_FAKE_PROFILE="$known_profiles" "$INFO" \
    >"$W/known-profiles.out" 2>"$W/known-profiles.err"
rc=$?
expect_rc "the printed profile list is accepted by the parser" "$rc" 0
env CUDA_NATIVE_BACKEND=fake CUDA_NATIVE_FAKE_PROFILE="$(printf 'gb\033[2J')" \
    "$INFO" >"$W/evil-profile.out" 2>"$W/evil-profile.err"
rc=$?
expect_rc "an unknown profile with a control byte returns 1" "$rc" 1
grep -q "$(printf '\033')" "$W/evil-profile.err"
rc=$?
if [ "$rc" -eq 0 ]; then
	bad "no escape byte reaches the unknown-profile diagnostic"
else
	ok "no escape byte reaches the unknown-profile diagnostic"
fi
grep -q -F 'unknown profile "gb\u001b[2J"' "$W/evil-profile.err"
rc=$?
expect_rc "the unknown-profile diagnostic carries the escaped value" "$rc" 0
# A C1 control in its UTF-8 encoding is a control sequence in a terminal
# that implements 8-bit controls: it must not reach the terminal.
c1=$(printf '\302\233')
env CUDA_NATIVE_BACKEND="$c1" "$INFO" >"$W/c1-backend.out" \
    2>"$W/c1-backend.err"
rc=$?
expect_rc "an unknown provider with a C1 control returns 1" "$rc" 1
if grep -q "$(printf '\302\233')" "$W/c1-backend.err"; then
	bad "no C1 control reaches the unknown-provider diagnostic"
else
	ok "no C1 control reaches the unknown-provider diagnostic"
fi
grep -q -F 'CUDA_NATIVE_BACKEND=\u009b' "$W/c1-backend.err"
rc=$?
expect_rc "the unknown-provider diagnostic carries the escaped C1 control" "$rc" 0
env CUDA_NATIVE_BACKEND=fake CUDA_NATIVE_FAKE_PROFILE="gb$c1" "$INFO" \
    >"$W/c1-profile.out" 2>"$W/c1-profile.err"
rc=$?
expect_rc "an unknown profile with a C1 control returns 1" "$rc" 1
if grep -q "$(printf '\302\233')" "$W/c1-profile.err"; then
	bad "no C1 control reaches the unknown-profile diagnostic"
else
	ok "no C1 control reaches the unknown-profile diagnostic"
fi
grep -q -F 'unknown profile "gb\u009b"' "$W/c1-profile.err"
rc=$?
expect_rc "the unknown-profile diagnostic carries the escaped C1 control" "$rc" 0
env CUDA_NATIVE_BACKEND="$c1" "$INFO" --json >"$W/c1-backend.json" \
    2>"$W/c1-backend-json.err"
rc=$?
expect_rc "a C1 control in the backend still produces a JSON document" "$rc" 1
python3 -I - "$W/c1-backend.json" <<'PY'
import json, sys
raw = open(sys.argv[1], "rb").read()
assert b"\xc2\x9b" not in raw, "the raw C1 bytes reached the JSON document"
assert b"\\u009b" in raw, "the escaped C1 control is missing"
document = json.loads(raw)
assert "\\u009b" in document["error"]["message"], \
    document["error"]["message"]
PY
rc=$?
expect_rc "the JSON document carries the escaped C1 control and no raw byte" "$rc" 0
# The line and paragraph separators are not JSON-safe: they are written as
# text in the JSON document too.
sep=$(printf '\342\200\250')
env CUDA_NATIVE_BACKEND="$sep" "$INFO" --json >"$W/separator.json" \
    2>"$W/separator.err"
rc=$?
expect_rc "a separator in the backend still produces a JSON document" "$rc" 1
python3 -I - "$W/separator.json" <<'PY'
import json, sys
raw = open(sys.argv[1], "rb").read()
assert b"\xe2\x80\xa8" not in raw, "the raw separator reached the JSON document"
assert b"\\u2028" in raw, "the escaped separator is missing"
json.loads(raw)
PY
rc=$?
expect_rc "the JSON document carries the escaped separator and no raw byte" "$rc" 0
env CUDA_NATIVE_BACKEND=fake CUDA_NATIVE_FAKE_PROFILE=gb100 "$INFO" --json \
    >"$W/error-bad-profile.json"
rc=$?
expect_rc "an invalid profile still produces a JSON error" "$rc" 1
$VAL "$W/error-bad-profile.json"
rc=$?
expect_rc "the invalid-profile JSON error validates" "$rc" 0
python3 -I - "$W/error-not-a-provider.json" "$W/error-bad-profile.json" \
    "$library_providers" "$library_profiles" <<'PY'
import json, sys
backend = json.load(open(sys.argv[1]))
profile = json.load(open(sys.argv[2]))
providers = sys.argv[3]
profiles = sys.argv[4]
assert "CUDA_NATIVE_BACKEND=not-a-provider" in backend["error"]["message"]
assert "use one of: " + providers in backend["error"]["message"]
assert 'unknown profile "gb100"' in profile["error"]["message"]
assert "known profiles: " + profiles in profile["error"]["message"]
PY
rc=$?
expect_rc "JSON environment diagnostics carry the same actionable messages" "$rc" 0

"$INFO" --help >"$W/help.out" 2>&1
rc=$?
expect_rc "--help exits 0" "$rc" 0
"$INFO" -h >"$W/help-short.out" 2>&1
rc=$?
expect_rc "-h exits 0" "$rc" 0
cmp -s "$W/help-short.out" "$W/help.out" &&
    grep -q -F -- '-h, --help' "$W/help.out"
rc=$?
expect_rc "-h matches --help and is advertised beside it" "$rc" 0
grep -q -- '--jsonl' "$W/help.out" && grep -q -- '--schema' "$W/help.out"
rc=$?
expect_rc "--help describes JSON Lines and schema modes" "$rc" 0
grep -q '^CUDA_NATIVE_FAKE_PROFILE takes a comma-separated list of fake profiles:$' \
    "$W/help.out" &&
    grep -q "^  $library_profiles (default $library_default_profile)\.$" \
    "$W/help.out"
rc=$?
expect_rc "--help names both fake profiles on a split line" "$rc" 0
help_profiles=$(sed -n 's/^  \([A-Za-z0-9,]*\) (default [^)]*)\.$/\1/p' "$W/help.out")
[ -n "$help_profiles" ]
rc=$?
expect_rc "--help prints the fake profile list as one copyable value" "$rc" 0
case $help_profiles in
*" "*) rc=1 ;;
*) rc=0 ;;
esac
expect_rc "the printed fake profile list has no separator whitespace" "$rc" 0
env CUDA_NATIVE_BACKEND=fake CUDA_NATIVE_FAKE_PROFILE="$help_profiles" "$INFO" \
    >"$W/help-profiles.out" 2>&1
rc=$?
expect_rc "the profile list the help prints is accepted by the parser" "$rc" 0
if grep -nE 'gb206|gb10|fake or nvrm|"fake"|"nvrm"' \
    "$L/cuda-native-info/cuda-native-info.c" >"$W/cli-hardcoded.out"; then
	cat "$W/cli-hardcoded.out"
	bad "the CLI tool source holds no hard-coded backend or profile list"
else
	ok "the CLI tool source holds no hard-coded backend or profile list"
fi
grep -q 'comma-separated indices or GPU-<uuid> prefixes' "$W/help.out" &&
    grep -q 'stops at the first invalid entry (libcuda(3))' "$W/help.out" &&
    grep -q 'Repeated devices also stop parsing' "$W/help.out"
rc=$?
expect_rc "--help gives visibility syntax and truncation behavior" "$rc" 0
python3 -I - "$W/help.out" <<'PY'
import re, sys
columns = []
for line in open(sys.argv[1]):
    row = re.match(r"^  (-h, --help|--jsonl|--json|--schema)( +)(\S.*)$", line)
    if row is not None:
        columns.append(2 + len(row.group(1)) + len(row.group(2)))
assert len(columns) == 4, columns
assert len(set(columns)) == 1, columns
PY
rc=$?
expect_rc "every help option row starts its description in one column" "$rc" 0
# The provider list lives in the library.  The schema names the same values,
# and the help text is where the library reports them.
providers=$(sed -n 's/^CUDA_NATIVE_BACKEND selects a provider: \(.*\) (default .*)\.$/\1/p' \
    "$W/help.out")
[ -n "$providers" ]
rc=$?
expect_rc "the help names the provider list the library reports" "$rc" 0
python3 -I - "$SCHEMA" "$providers" <<'PY'
import json, sys
schema = json.load(open(sys.argv[1]))
names = [n.strip() for n in sys.argv[2].split(",") if n.strip()]
enums = []
def walk(node):
    if isinstance(node, dict):
        for key, value in node.items():
            if key == "backend" and isinstance(value, dict) and "enum" in value:
                enums.append(value["enum"])
            walk(value)
    elif isinstance(node, list):
        for item in node:
            walk(item)
walk(schema)
assert enums, "the schema names no backend enum"
for enum in enums:
    assert enum == names, (enum, names)
PY
rc=$?
expect_rc "the schema backend enum is the provider list the library reports" "$rc" 0
awk 'length($0) > 79 {
	print "help line exceeds 79 columns: " $0
	failed = 1
}
END { exit failed }' "$W/help.out"
rc=$?
expect_rc "--help fits an 80-column terminal" "$rc" 0
"$INFO" --not-an-option >/dev/null 2>&1
rc=$?
expect_rc "unknown CLI option exits 2" "$rc" 2
"$INFO" extra >/dev/null 2>&1
rc=$?
expect_rc "positional CLI argument exits 2" "$rc" 2
"$INFO" --json --jsonl >/dev/null 2>"$W/modes.err"
rc=$?
expect_rc "multiple output modes exit 2" "$rc" 2
grep -q 'exclude each other' "$W/modes.err"
rc=$?
expect_rc "multiple output modes explain the conflict" "$rc" 0

# ---- validator mutants: wrong data and unknown keywords must be refused ---
python3 -I - "$W/gb206.json" "$SCHEMA" "$W" <<'PY'
import copy, json, sys
good = json.load(open(sys.argv[1]))
schema = json.load(open(sys.argv[2]))
w = sys.argv[3]
def dump(name, value):
    open(w + "/invalid-" + name + ".json", "w").write(json.dumps(value) + "\n")
m = copy.deepcopy(good); del m["devices"][0]["name"]; dump("missing", m)
m = copy.deepcopy(good); m["devices"][0]["extra"] = 1; dump("extra", m)
m = copy.deepcopy(good); m["devices"][0]["attributes"]["warp_size"] = "32"; dump("type", m)
m = copy.deepcopy(good); m["devices"][0]["attributes"]["warp_size"] = -1; dump("negative", m)
m = copy.deepcopy(good); m["schema"] = "cuda-native-info/2"; dump("schema", m)
m = copy.deepcopy(good); m["kind"] = "not-a-kind"; dump("kind", m)
s = copy.deepcopy(schema); s["unsupportedKeyword"] = True
json.dump(s, open(w + "/unsupported.schema.json", "w"))
open(w + "/not-json.json", "w").write("{not JSON}\n")
open(w + "/no-values.json", "w").write("\n")
PY
for mutant in missing extra type negative schema kind; do
	$VAL "$W/invalid-$mutant.json" >/dev/null 2>&1
	rc=$?
	if [ "$rc" -eq 1 ]; then ok "validator refused data mutant: $mutant"; else bad "validator accepted data mutant: $mutant (rc=$rc)"; fi
done
python3 -I "$SRC/tests/libnvrm/schema_validate.py" "$W/unsupported.schema.json" "$W/gb206.json" >"$W/keyword.out" 2>&1
rc=$?
if [ "$rc" -eq 1 ] && grep -q 'does not support keyword unsupportedKeyword' "$W/keyword.out"; then
	ok "validator refuses an unsupported schema keyword"
else
	bad "validator accepted or crashed on an unsupported keyword (rc=$rc)"
fi
python3 -I "$SRC/tests/libnvrm/schema_validate.py" "$SCHEMA" "$W/not-json.json" >/dev/null 2>&1
rc=$?
expect_rc "validator refuses malformed JSON" "$rc" 1
python3 -I "$SRC/tests/libnvrm/schema_validate.py" "$SCHEMA" "$W/no-values.json" >/dev/null 2>&1
rc=$?
expect_rc "validator refuses an empty input stream" "$rc" 1
python3 -I "$SRC/tests/libnvrm/schema_validate.py" >/dev/null 2>&1
rc=$?
expect_rc "validator usage error is 2" "$rc" 2

# ---- manuals, source hygiene and licence provenance -----------------------
awk '
	/^struct thread_case \{/ { inside = 1; next }
	inside && /^};/ { exit }
	inside {
		sub(/;.*/, "")
		gsub(/^[ \t]+|[ \t]+$/, "")
		print $NF
	}
' "$T/api_test.c" >"$W/thread-fields"
[ -s "$W/thread-fields" ]
rc=$?
expect_rc "thread_case fields were extracted for the unused-member check" "$rc" 0
unused=
while IFS= read -r member; do
	if ! grep -Eq "(tc->|[ab]\\.)${member}([^[:alnum:]_]|$)" "$T/api_test.c"; then
		unused="$unused $member"
	fi
done <"$W/thread-fields"
[ -z "$unused" ]
rc=$?
expect_rc "every thread_case member is used${unused:+ (unused:$unused)}" "$rc" 0
for dead in active_only REGISTRY_RUNNING REGISTRY_DONE; do
	if grep -n "$dead" "$L/cuda_registry.c" >"$W/registry-dead.out"; then
		cat "$W/registry-dead.out"
		bad "registry omits dead state or parameter: $dead"
	else
		ok "registry omits dead state or parameter: $dead"
	fi
done
if grep -nE '(->|\.)primary([^_[:alnum:]]|$)' "$L/cuda_registry.c" \
    >"$W/registry-primary.out"; then
	cat "$W/registry-primary.out"
	bad "registry uses primary_state directly, without a redundant pointer"
else
	ok "registry uses primary_state directly, without a redundant pointer"
fi
# The registry state changes in cuInit only: the once body writes the data,
# and the completed state is published after the body has written it.
awk '/^registry_initialize_once\(void\)/{inside=1; next}
    inside && /^}/{exit} inside { print }' "$L/cuda_registry.c" \
    >"$W/registry-once.body"
if grep -nE 'atomic_store[^;]*registry_state' "$W/registry-once.body" \
    >"$W/registry-once-store.out"; then
	cat "$W/registry-once-store.out"
	bad "the once body does not store the registry state"
else
	ok "the once body does not store the registry state"
fi
# The completed state is published with a release store once the data is
# written, and the state has an initializing phase between the two: a reader
# that sees the completed state sees the registry data as well.
awk '/^cuda_registry_initialize\(void\)/{inside=1; next}
    inside && /^}/{exit} inside { print }' "$L/cuda_registry.c" \
    >"$W/registry-init.body"
grep -q 'REGISTRY_INITIALIZING' "$W/registry-init.body" &&
    grep -q 'memory_order_release' "$W/registry-init.body"
rc=$?
expect_rc "the completed registry state is published after the data" "$rc" 0
! grep -q 'Track #' "$SDK/cuda.h"
rc=$?
expect_rc "public header has no internal tracker labels" "$rc" 0
if grep -R -n 'this round' "$L" >"$W/process-labels.out"; then
	cat "$W/process-labels.out"
	bad "library comments have no process-specific round labels"
else
	ok "library comments have no process-specific round labels"
fi
python3 -I - "$L/man/libcuda.3" <<'PY'
import re, sys
source = open(sys.argv[1]).read()
text = re.sub(r"(?m)^\.[A-Z][a-z]?\s*", " ", source)
text = " ".join(text.split())
required = ("When no devices remain visible, cuInit returns CUDA_SUCCESS and "
    "cuDeviceGetCount reports zero. CUDA_ERROR_NO_DEVICE is not returned for "
    "an empty device set.")
if required not in text:
    raise SystemExit("missing explicit empty-system success documentation")
if "matching the public CUDA environment-variable contract" in text:
    raise SystemExit("visibility documentation overclaims public compatibility")
PY
rc=$?
expect_rc "empty visibility success is documented without a compatibility overclaim" "$rc" 0
# The device limit is a policy about the visible set: the manual, the
# internal comment and the code must say the same thing.
python3 -I - "$L/man/libcuda.3" <<'PY'
import re, sys
source = open(sys.argv[1]).read()
text = re.sub(r"(?m)^\.[A-Z][a-z]?\s*", " ", source)
text = " ".join(text.split())
required = (
    "The limit counts the visible devices, the selected ones.",
    "A provider may report more devices than the limit",
    "Without a filter the visible set is every provider device",
    "A visibility list that selects more devices than the limit is an invalid value")
for part in required:
    if part not in text:
        raise SystemExit("missing device-limit policy text: " + part)
PY
rc=$?
expect_rc "the manual states the device limit in terms of the visible set" "$rc" 0
grep -q 'visible devices, the selected ones' "$L/cuda_internal.h" &&
    grep -q 'a buffer' "$L/cuda_internal.h"
rc=$?
expect_rc "the internal comment states the same device-limit policy" "$rc" 0
python3 -I - "$L/man/libcuda.3" <<'PY'
import re, sys
source = open(sys.argv[1]).read()
text = re.sub(r"(?m)^\.[A-Z][a-z]?\s*", " ", source)
text = " ".join(text.split())
if "process-independent" in text:
    raise SystemExit("the manual still calls the native queries process-independent")
required = (
    "These cuda-native extensions do not initialize a provider.",
    "reads the calling process's environment when it is called",
    "Provider and profile table membership is fixed by the loaded library")
for part in required:
    if part not in text:
        raise SystemExit("missing native-query documentation: " + part)
PY
rc=$?
expect_rc "the native extension queries are documented as environment-dependent" "$rc" 0
missing=
while IFS= read -r name; do
	if ! grep -qE "\.Fn[[:space:]]+${name}([^_[:alnum:]]|\$)" \
	    "$L/man/libcuda.3"; then
		missing="$missing $name"
	fi
done <"$W/map-exports.sorted"
[ -z "$missing" ]
rc=$?
expect_rc "every exported function has a .Fn entry in libcuda.3${missing:+ (missing:$missing)}" "$rc" 0
# The renamed provider query: the new name is exported and declared, and the
# old name is gone from the header, the version map and the exports.
grep -q 'cudaNativeProviderTakesFakeProfiles' "$SDK/cuda.h"
rc=$?
expect_rc "the header declares the renamed provider query" "$rc" 0
if grep -q 'cudaNativeProviderTakesProfiles' "$SDK/cuda.h" "$L/Version.map" \
    "$W/nm.out" >"$W/old-name.out" 2>&1; then
	cat "$W/old-name.out"
	bad "the old provider query name is gone from the header, the map and the exports"
else
	ok "the old provider query name is gone from the header, the map and the exports"
fi
grep -q 'cudaNativeProviderTakesFakeProfiles' "$W/nm.out"
rc=$?
expect_rc "the renamed provider query is exported" "$rc" 0
# ---- the table of the control code points ---------------------------------
# The table of the code points that the tool escapes is the one of the
# production code: the test reads it and keeps no copy of it, so a code
# point that is added to the table is exercised with it.
# The pattern of a range of code points is built here, so that the check
# does not match itself.
range_pattern='[0-9a-f]{4}:[0-9a-f]{4}'
if grep -qE "$range_pattern" "$SRC/tests/libcuda_test.sh"; then
	bad "the test keeps no copy of the table of the control code points"
else
	ok "the test keeps no copy of the table of the control code points"
fi
# The list follows the table: a range that is added to the table is added to
# the list of the code points the test exercises.
python3 -I - "$L/control_ranges.h" "$W/control_ranges.h" <<'PYEOF'
import sys
text = open(sys.argv[1]).read()
marker = "\t{ 0x2066, 0x2069 }"
assert marker in text, "the table of the control code points is not in the header"
text = text.replace(marker,
    "\t{ 0x2ff0, 0x2ff0 },\t/* a range that is added to the table */ \\\n" + marker, 1)
open(sys.argv[2], "w").write(text)
PYEOF
rc=$?
expect_rc "the table of the control code points with an added range is written" "$rc" 0
if control_points "$W/control_ranges.h" | grep -q '^2ff0$'; then
	ok "the list of the code points follows the table of the production code"
else
	bad "the list of the code points follows the table of the production code"
fi
# Every code point of the table is escaped, the NUL included: the environment
# cannot carry a NUL, so the code points are checked at the C level, against
# the one table of the tool.
cc $CFLAGS -I"$O/info" -I"$L" -I"$L/cuda-native-info" -I"$SDK" -I"$T" \
    "$T/escape_test.c" "$L/cuda_version.c" "$L/cuda_uuid.c" \
    -L"$O/lib" -lcuda -lthr -o "$W/bin/escape_test" \
    >"$W/build-escape.log" 2>&1
rc=$?
expect_rc "the escape test compiles against the tool" "$rc" 0
[ "$rc" -eq 0 ] || sed -n '1,40p' "$W/build-escape.log"
if [ -x "$W/bin/escape_test" ]; then
	run_case "every code point of the table is escaped" "$W/bin/escape_test"
fi

# ---- the count of the profiles of the fake provider -----------------------
# A count that overflows must not write past the array of the selected
# profiles.  The count of a selection saturates at the limit, so the counter
# cannot wrap around: the mutant below starts the counter at UINT_MAX, the
# state an overflowed counter is in, and the build with the address
# sanitizer must report no write past the array.
AS=$W/asan-overflow
mkdir -p "$AS"
cp "$L"/*.c "$L"/*.h "$AS/"
python3 -I - "$AS/cuda_fake.c" <<'PYEOF'
import sys
path = sys.argv[1]
text = open(path).read()
marker = "fake_select(const char *list)"
head, sep, tail = text.partition(marker)
assert sep, "the selection of the fake provider is not in the source"
patched = tail.replace("unsigned count = 0;", "unsigned count = UINT_MAX;", 1)
assert patched != tail, "the count of the selection is not in fake_select"
text = text.replace(head + sep + tail, head + sep + patched, 1)
if "#include <limits.h>" not in text:
    text = text.replace("#include <stdlib.h>",
        "#include <limits.h>\n#include <stdlib.h>", 1)
open(path, "w").write(text)
PYEOF
rc=$?
expect_rc "the overflowing counter mutant changed the fake provider" "$rc" 0
cat >"$W/asan-driver.c" <<'EOF'
/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The driver of the address sanitizer build: it initializes the library with
 * a selection of more profiles than the registry holds and reports what
 * happened.  Every outcome it does not expect has a status of its own, so
 * the shell can tell them apart.
 */
#include <stdio.h>

#include <cuda.h>

int
main(void)
{
	CUresult result;
	cudaNativeInitReason reason;

	result = cuInit(0);
	reason = cudaNativeInitFailureReason();
	printf("init %d reason %d\n", (int)result, (int)reason);
	if (result != CUDA_ERROR_INVALID_VALUE)
		return (2);
	if (reason != CUDA_NATIVE_INIT_PROVIDER_DEVICE_LIMIT)
		return (3);
	return (0);
}
EOF
cc $CFLAGS -fsanitize=address -pthread -I"$W" -I"$O/lib" -I"$AS" -I"$SDK" \
    "$W/asan-driver.c" "$AS"/cuda_*.c -lthr -o "$W/bin/asan-driver" \
    >"$W/build-asan.log" 2>&1
rc=$?
expect_rc "the address sanitizer build of the overflowing counter compiles" "$rc" 0
[ "$rc" -eq 0 ] || sed -n '1,40p' "$W/build-asan.log"
if [ -x "$W/bin/asan-driver" ]; then
	overflow_profiles=$(python3 -I -c 'print(",".join(["gb206"] * 129))')
	env CUDA_NATIVE_BACKEND=fake CUDA_NATIVE_FAKE_PROFILE="$overflow_profiles" \
	    "$W/bin/asan-driver" >"$W/asan.out" 2>&1
	rc=$?
	cat "$W/asan.out"
	if grep -q 'AddressSanitizer' "$W/asan.out"; then
		bad "the address sanitizer reports no write past the array of the profiles"
	else
		ok "the address sanitizer reports no write past the array of the profiles"
	fi
	expect_rc "the overflowing counter is refused over the limit" "$rc" 0
fi

# ---- the child of the stress case -----------------------------------------
# A child of the stress case that fails must be reported as a failure: the
# parent sees the exit status of the child and nothing else.  The switch
# makes one thread of a round see a device count that the other threads do
# not see, so the round fails on purpose.
env CUDA_NATIVE_BACKEND=fake CUDA_NATIVE_FAKE_PROFILE=gb206,gb10 \
    CUDA_NATIVE_TEST_STRESS_DISTURB=1 "$API" init-stress \
    >"$W/stress-disturbed.out" 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then
	ok "the stress case fails when a child fails"
else
	bad "the stress case fails when a child fails"
	sed -n '1,20p' "$W/stress-disturbed.out"
fi

# ---- a provider that cannot select ----------------------------------------
# A provider of the synthetic kind that cannot apply a selection must not
# keep the capability it cannot apply: the library reports that it takes no
# profiles and refuses to initialize it.
NS=$W/no-select-mutant
mkdir -p "$NS"
cp "$L"/*.c "$L"/*.h "$NS/"
sed -i '' 's/\.select = fake_select,/.select = NULL,/' "$NS/cuda_fake.c"
grep -q '\.select = NULL' "$NS/cuda_fake.c"
rc=$?
expect_rc "the provider without a selection callback mutant changed the library" \
    "$rc" 0
# The mutant leaves the selection function of the provider unused: the
# warning about that is not what this case is about.
(
    cc $CFLAGS -Wno-unused-function -pthread -I"$W" -I"$O/lib" -I"$NS" \
        -I"$SDK" -I"$T" "$T/api_test.c" "$NS"/*.c -lthr -o "$NS/api_test"
) >"$NS/build.log" 2>&1
rc=$?
expect_rc "the provider without a selection callback library builds" "$rc" 0
[ "$rc" -eq 0 ] || sed -n '1,40p' "$NS/build.log"
if [ "$rc" -eq 0 ]; then
    env CUDA_NATIVE_BACKEND=fake "$NS/api_test" providers \
        >"$NS/providers.out" 2>&1
    rc=$?
    expect_rc "the mutant library reports its providers" "$rc" 0
    if grep -q '^synthetic fake$' "$NS/providers.out"; then
        bad "a provider that cannot select takes no profile"
    else
        ok "a provider that cannot select takes no profile"
    fi
    env CUDA_NATIVE_BACKEND=fake "$NS/api_test" init-reason \
        >"$NS/reason.out" 2>&1
    rc=$?
    expect_rc "the reason query runs for the provider that cannot select" "$rc" 0
    grep -q '^reason provider-error$' "$NS/reason.out"
    rc=$?
    expect_rc "the library refuses a provider that cannot select" "$rc" 0
fi

MANWIDTH=80 man -l "$L/cuda-native-info/cuda-native-info.1" \
    >"$W/info-man.raw" 2>"$W/info-man.err" &&
    col -b <"$W/info-man.raw" >"$W/info-man.txt"
rc=$?
expect_rc "cuda-native-info manual renders as printable 80-column text" "$rc" 0
grep -q -F -- '-h, --help' "$W/info-man.txt"
rc=$?
expect_rc "cuda-native-info manual documents -h beside --help" "$rc" 0
grep -q 'env CUDA_NATIVE_BACKEND=fake \\$' "$W/info-man.txt" &&
    grep -q 'python3 tests/libnvrm/schema_validate.py \\$' "$W/info-man.txt"
rc=$?
expect_rc "rendered manual examples retain their shell continuations" "$rc" 0
awk 'length($0) > 80 {
	print "manual line exceeds 80 columns: " $0
	failed = 1
}
END { exit failed }' "$W/info-man.txt"
rc=$?
expect_rc "rendered cuda-native-info manual fits 80 columns" "$rc" 0
for man in "$L/man/libcuda.3" "$L/cuda-native-info/cuda-native-info.1"; do
	mandoc -T lint -W warning "$man" >"$W/mandoc.log" 2>&1
	rc=$?
	if [ "$rc" -eq 0 ] && [ ! -s "$W/mandoc.log" ]; then
		ok "mandoc -T lint -W warning is silent: $(basename "$man")"
	else
		bad "mandoc is not silent: $(basename "$man")"
		cat "$W/mandoc.log"
	fi
done
sh -n "$SRC/tests/libcuda_test.sh"
rc=$?
expect_rc "the test runner passes sh -n" "$rc" 0
python3 -I - "$L" "$T" "$SDK/cuda.h" "$SRC/tests/libcuda_test.sh" <<'PY'
import os, sys
roots = sys.argv[1:3]
files = []
for root in roots:
    for base, dirs, names in os.walk(root):
        for name in names:
            if not name.endswith(".json"):
                files.append(os.path.join(base, name))
files.extend(sys.argv[3:])
bad = []
for path in files:
    with open(path, errors="replace") as f:
        head = "".join(f.readline() for _ in range(12))
    if "SPDX-License-Identifier: BSD-2-Clause" not in head:
        bad.append(path)
assert not bad, bad
PY
rc=$?
expect_rc "every new source, script, Makefile and man page has BSD-2-Clause provenance" "$rc" 0

printf 'SUMMARY: %d checks passed, %d failed' "$PASS" "$FAIL"
if [ "$SKIP" -gt 0 ]; then
	printf ', %d skipped' "$SKIP"
fi
printf '\n'
[ "$FAIL" -eq 0 ]

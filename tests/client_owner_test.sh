#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# client_owner_test.sh - Track #2373: the client ownership table nvidia.ko
# keeps for nvidia-uvm.ko (src/gb10-client-owner/nv_client_owner.h and
# patches/patch-zz-nvidia_client_owner_subr.c).  Checks:
#   (a) the table logic (tests/client_owner_test.c): two files, allocation
#       through NVOS21/NVOS64/NVOS05, frees, reuse, close, growth; the
#       structure layouts equal the real nvos.h (MIT, pinned checkout);
#   (b) the patch is wired: the ioctl hook, the forget on close, the exported
#       nvUvmInterfaceClientHold and nvUvmInterfaceClientRelease, its EXPORT_SYMS entry, and the
#       header copied by prepare-tree.sh;
#   (c) the plants (deliberately broken copies the test must reject):
#       removing the owner comparison, the free handling or the close
#       handling turns (a) red; removing any hook turns the matching
#       check of (b) red.
#
# Run: sh tests/client_owner_test.sh

set -eu
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL
TESTSDIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH= cd -- "$TESTSDIR/.." && pwd)
WORK=${GB10_WORK:-/nonexistent-set-GB10_WORK}	# inputs only: scratch never goes there
OGKM=$WORK/sources/open-gpu-kernel-modules-580.178.04
mkdir -p "${TMPDIR:-$REPO/tmp}"
T=$(mktemp -d "${TMPDIR:-$REPO/tmp}/client-owner-test.XXXXXXXX")
trap 'rm -rf "$T"' EXIT HUP INT QUIT TERM
HDR=$REPO/src/gb10-client-owner/nv_client_owner.h
PATCH=$REPO/patches/patch-zz-nvidia_client_owner_subr.c
MKPATCH=$REPO/patches/patch-zz-nvidia_client_owner_Makefile
rc=0
strict() { [ -n "${REQUIRE_INPUTS:-}" ] || [ -n "${CI:-}" ]; }	# missing inputs fail instead of skipping
if [ ! -d "$OGKM/src/common/sdk/nvidia/inc" ] && strict; then
	echo "FAIL missing input: $OGKM (unpack the pinned open-gpu-kernel-modules 580.178.04 checkout there, or set GB10_WORK); nothing was run"
	exit 1
fi
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; rc=1; }

build_run() {	# build_run <header dir> <out>
	if [ -d "$OGKM/src/common/sdk/nvidia/inc" ]; then
		cc -std=c11 -Wall -Wextra -Werror -DWITH_NVOS -I "$1" \
		    -I "$OGKM/src/common/sdk/nvidia/inc" -I "$OGKM/src/common/inc" \
		    -I "$OGKM/src/nvidia/arch/nvalloc/unix/include" \
		    -o "$2" "$REPO/tests/client_owner_test.c" 2>"$T/cc.err" || { cat "$T/cc.err"; return 2; }
	else
		cc -std=c11 -Wall -Wextra -Werror -I "$1" -o "$2" "$REPO/tests/client_owner_test.c" || return 2
	fi
	"$2"
}

# (a)
if build_run "$REPO/src/gb10-client-owner" "$T/t"; then
	if [ -d "$OGKM/src/common/sdk/nvidia/inc" ]; then ok "table logic and nvos.h layouts"; else ok "table logic"; echo "skip nvos.h layout comparison: $OGKM not found (set GB10_WORK)"; fi
else bad "table logic"; fi

# (c) plants on a copy of the header: each must turn (a) red
plant() {	# plant <name> <sed expression>
	mkdir -p "$T/p-$1"
	sed -e "$2" "$HDR" > "$T/p-$1/nv_client_owner.h"
	if cmp -s "$HDR" "$T/p-$1/nv_client_owner.h"; then bad "plant $1 did not change the header"; return; fi
	build_run "$T/p-$1" "$T/pt-$1" >"$T/p-$1/out" 2>&1 && prc=0 || prc=$?
	if [ "$prc" = 0 ]; then bad "plant $1 stays green"
	elif [ "$prc" = 2 ] && grep -q 'static assertion failed' "$T/p-$1/out"; then ok "plant $1 is red (a static assertion against NVIDIA's header fails)"
	elif [ "$prc" = 2 ]; then bad "plant $1 did not run: $(head -2 "$T/p-$1/out")"
	else ok "plant $1 is red"; fi
}
plant owner-ignored 's/e->owner == owner \&\& !e->revoked/1 \&\& !e->revoked/'
plant free-ignored 's/nvco_remove_handle(t, f->hObjectOld);/(void)0;/'
plant close-ignored 's/if (t->e\[i\].owner == owner \&\& !t->e\[i\].tomb \&\& nvco_remove_entry/if (t->e[i].owner == owner \&\& !t->e[i].tomb \&\& owner == NULL \&\& nvco_remove_entry/'
plant any-class 's/return (hClass == NVCO_CLASS_ROOT || hClass == NVCO_CLASS_ROOT_NON_PRIV ||/return ((hClass | 1u) != 0 || hClass == NVCO_CLASS_ROOT_NON_PRIV ||/'
plant client-op-any-free 's/^\t\treturn (ok);/\t\treturn (1);/'
plant alloc-object-undecoded 's/nvco_is_root_class(((const struct nvco_alloc_object_params \*)args)->hClass));/0);/'
plant hold-ignores-owner 's/if (!nvco_grants(e, owner) || file == NULL)/if (e == NULL || file == NULL || (owner == NULL \&\& 0))/'
plant revoked-ignored 's/ \&\& !e->revoked//'
plant freeing-ignored 's/ \&\& e->freeing == 0//'
plant unhold-file-ignored 's/e->file != file || e->refs == 0/e->refs == 0/'
plant evict-removes-held 's/^\tif (e->refs != 0) {$/\tif (0) {/'
plant begin-free-noop 's/e->freeing++;/e->freeing += 0;/'
plant end-free-ignores-token 's/e->fgen != token || //'
plant gen-never-new 's/e->gen = nvco_new_gen(t);/e->gen = 1;/'
plant gen-wrap-zero 's/if (++t->next_gen == 0)/if (0)/'
plant free-not-logged 's/^		t->frees\[seq % NVCO_FREELOG\].handle = handle;/		(void)seq;/'
plant tombstone-never 's/^		e->tomb = 1;$/		e->tomb = 0;/'
plant turnback-not-tomb 's/^	e->tomb = 1;$/	e->tomb = 0;/'
plant fgen-narrowed 's/^\tuint64_t\tfgen;/\tuint32_t\tfgen;/'
plant revert-drops-marker 's/if (e->conv \&\& e->freeing != 0) {/if (0) {/'
plant log-ignores-entry-state 's/(unlisted || (e != NULL \&\& token != 0 \&\& e->fgen == token \&\& e->tomb))/unlisted/'
plant junk-frees-logged 's/if (rm_freed \&\& (unlisted ||/if ((rm_freed || unlisted) \&\& (unlisted ||/'
plant stale-ignores-overflow 's/if (t->seq - mark >= NVCO_FREELOG)/if (0)/'
plant stale-ignores-handle 's/t->frees\[i\].seq > mark \&\& t->frees\[i\].handle == handle/t->frees[i].seq > mark \&\& t->frees[i].handle == handle + 1/'
plant stranger-permitted 's/return (e == NULL || e->tomb || e->owner == who);/return (e == NULL || e->tomb || e->owner == who || e != NULL);/'
plant marked-ignores-mark 's/nvco_alloc_stale(t, h, mark)/nvco_alloc_stale(t, h, mark | ~mark)/'
plant remove-owner-keeps-held '/^nvco_remove_entry/,/^}/s/^\t\te->revoked = 1;$/\t\t(void)0;/'
plant close-drops-marker 's/ \&\& nvco_remove_entry(t, \&t->e\[i\]))$/ \&\& (nvco_drop_entry(t, \&t->e[i]), 1))/'
plant close-skips-held 's/if (t->e\[i\].owner == owner \&\& !t->e\[i\].tomb \&\& nvco_remove_entry/if (t->e[i].owner == owner \&\& !t->e[i].tomb \&\& t->e[i].refs == 0 \&\& nvco_remove_entry/'
plant close-skips-after-drop 's/^\t\t\tcontinue;$/\t\t\t(void)0;/'
plant second-file-shares-hold 's/if (e->refs != 0 \&\& e->file != file)/if (0)/'
plant collision-moves-owner 's/if (old->owner != owner) {/if (0) {/'
plant end-free-resets 's/e->freeing--;/e->freeing = 0;/'
plant busy-never 's/return (e != NULL \&\& e->refs != 0);/return (e == NULL \&\& 0);/'
plant ownerless-keeps-stale 's/nvco_remove_handle(t, h);/(void)h;/'
plant second-decoder 's/if (!nvco_is_client_op(nr, size, args))/if (0)/'
plant root-client-class-missing 's/hClass == NVCO_CLASS_ROOT_CLIENT);/0);/'
[ -d "$OGKM/src/nvidia/arch/nvalloc/unix/include" ] && plant escape-number-moved 's/#define\tNVCO_ESC_RM_FREE\t\t0x29/#define\tNVCO_ESC_RM_FREE\t\t0x2A/'
plant second-free-listed 's/\*unlisted = (e == NULL || e->tomb);/*unlisted = (e == NULL);/'
plant tomb-eperm 's/return (e == NULL || e->tomb || e->owner == who);/return (e == NULL || e->owner == who);/'
plant gen-narrowed 's/^\tuint64_t\tgen;/\tuint32_t\tgen;/'
plant next-gen-narrowed 's/^\tuint64_t\t\tnext_gen;/\tuint32_t\t\tnext_gen;/'
plant token-narrowed '/^static inline uint64_t$/{N;s/uint64_t\nnvco_begin_free/uint32_t\nnvco_begin_free/;}'
plant converted-kept-after-free 's/if (rm_freed \&\& e->conv \&\& !e->tomb) {/if (0) {/'
plant conversion-keeps-gen 's/old->gen = nvco_new_gen(t);/(void)0;/'
plant conv-never-cleared 's/\t\te->conv = 0;\t\t\/\* the free that covered/\t\t(void)0;\t\t\/* the free that covered/'
plant tombstone-collides 's/\t\tif (old->tomb) {/\t\tif (0 \&\& old->tomb) {/'
plant stale-log-hit-keeps-entry '/a free of this handle began while the allocation/{n;s/.*/\t\t(void)h;/;}'
plant n1-fail-open 's/\*unlisted = (e == NULL || e->tomb);/*unlisted = (e == NULL);/;s/(unlisted || (e != NULL \&\& token != 0 \&\& e->fgen == token \&\& e->tomb))/unlisted/'
plant status-ignored 's/ok = a64->status == 0;/ok = 1;/'

has() { grep -qF -- "$2" "$1"; }	# quiet predicate
need() {	# need <file> <fixed string> <what>: a requirement; reports, never returns non-zero
	if has "$1" "$2"; then ok "$3"; else bad "$3 (missing: $2)"; fi
}
need "$MKPATCH" 'nvUvmInterfaceClientHold nvUvmInterfaceClientRelease' "the arm64 export list names both"
need "$REPO/scripts/prepare-tree.sh" 'nv_client_owner.h' "prepare-tree copies the header"
need "$REPO/README.md" 'symbol nvUvmInterfaceClientHold undefined' "the README says what a missing export looks like"
need "$REPO/README.md" 'dmesg' "the README says where the undefined-symbol message appears"
need "$REPO/README.md" 'SA_RESTART' "the README says a restartable signal waits again"
if grep -q '^## .*Track #' "$REPO/README.md"; then bad "a tracker label in a README heading"; else ok "README headings carry no tracker label"; fi
need "$REPO/README.md" 'version mismatch' "the README quotes the version-mismatch failure"
need "$REPO/README.md" 'also stops the display' "the README warns that nvidia-modeset and nvidia-drm need the same build"
need "$REPO/README.md" 'nvidia-uvm bug' "the README tells the reporter about the release diagnostic"
need "$REPO/README.md" 'fails with `EPERM` at once' "the README says a stranger free is EPERM"
# the README names the log size the header defines
freelog=$(sed -n 's/^#define[[:space:]]*NVCO_FREELOG[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$HDR")
if [ -n "$freelog" ] && grep -qF "the last $freelog, \`NVCO_FREELOG\`" "$REPO/README.md" && grep -qF "$freelog or more frees of other unrecorded handles" "$REPO/README.md"; then
	ok "the README log size ($freelog) matches NVCO_FREELOG"
else
	bad "the README log size does not match NVCO_FREELOG ($freelog)"
fi
tr '\n' ' ' < "$REPO/README.md" | tr -s ' ' > "$T/readme.flat"	# the pins below survive a reflow
need "$T/readme.flat" 'the entry goes back to a marker instead of being dropped' "the README says a closing owner's entry goes back to a marker"
need "$T/readme.flat" 'Default client-handle validation does not prevent this' "the README says close-path is reachable with the default validation"
need "$REPO/README.md" 'nvcobusy' "the README names the wait channel of a waiting free"
need "$REPO/README.md" 'fail until' "the README says what nvidia-uvm sees while a free covers the record"
need "$REPO/README.md" 'began before such a free ended' "the README says which records the free log refuses"

# MODULE_VERSION 2 and every dependent's window: an old (vulnerable) nvidia-uvm.ko must refuse to load
need "$REPO/patches/patch-zz-nvidia_client_owner_version_pci.c" '+MODULE_VERSION(nvidia, 2);' "nvidia.ko is module version 2"
need "$REPO/patches/patch-zz-nvidia_client_owner_version_modeset.c" '2, 2, 2);' "nvidia-modeset depends on nvidia 2"
need "$REPO/patches/patch-zz-nvidia_client_owner_version_drm.c" 'MODULE_DEPEND(nvidia_drm, nvidia, 2, 2, 2);' "nvidia-drm depends on nvidia 2"
# the glue harness (behaviour tests of the real glue) and its pins
if sh "$REPO/tests/client_owner_glue_test.sh" > "$T/glue.out" 2>&1; then ok "glue harness: $(grep -c '^ok' "$T/glue.out") checks, mutants red"; else cat "$T/glue.out"; bad "glue harness"; fi

# no stale export name anywhere
if grep -q ClientOwnedByFile "$HDR" "$PATCH" "$MKPATCH" "$REPO/README.md" "$REPO/tests/client_owner_test.c" ||
    grep -q 'ownership query' "$MKPATCH"; then
	bad "a stale export name (ClientOwnedByFile) is still mentioned"
else
	ok "no stale export name"
fi
# the header comment names the sx lock, not a mutex
if grep -q 'holds a mutex' "$HDR"; then bad "header says a mutex holds the table"; else ok "header names the right lock"; fi

# (b2) the patches apply to the pinned sources and leave the hooks in the prepared tree
if [ -f "$WORK/sources/NVIDIA-FreeBSD-x86_64-580.178.04.tar.xz" ]; then
	PW=$T/w
	mkdir -p "$PW/build"
	ln -s "$WORK/sources" "$PW/sources"
	if GB10_WORK=$PW sh "$REPO/scripts/prepare-tree.sh" "$PW/build/tree" >"$T/prep.out" 2>&1; then
		ok "prepare-tree applies the patches"
		need "$PW/build/tree/nvidia/nvidia_subr.c" 'nvco_ioctl_end(&nvco_ctx, nvco_who, status, nr, size, args);' "prepared tree: ioctl hook (end)"
		need "$PW/build/tree/nvidia/nvco_glue.h" 'nvco_after_ioctl_marked(&nvco_table' "prepared tree: the glue is copied"
		need "$PW/build/tree/nvidia/nvidia_subr.c" 'nvco_forget_owner(nvffp);' "prepared tree: forget on close"
		nvs=$PW/build/tree/nvidia/nvidia_subr.c
		a=$(grep -n 'nr = xfer->cmd;' "$nvs" | head -1 | cut -d: -f1)
		b=$(grep -n 'int nvco_error = nvco_ioctl_begin' "$nvs" | head -1 | cut -d: -f1)
		c=$(grep -n 'size = xfer->size;' "$nvs" | head -1 | cut -d: -f1)
		d=$(grep -n 'copyin(NvP64_VALUE(xfer->ptr), args, size)' "$nvs" | head -1 | cut -d: -f1)
		if [ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ] && [ -n "$d" ] && [ "$a" -lt "$b" ] && [ "$c" -lt "$b" ] && [ "$d" -lt "$b" ]; then
			ok "prepared tree: the transfer escape (size, args, nr) is unwrapped before the hook decodes"
		else
			bad "prepared tree: the transfer escape unwrap (nr line '$a', size '$c', args '$d') must come before the decoder (line '$b')"
		fi
		# begin and end always pair: nothing between them can return (the begin error goes to the label)
		pair_ok() {	# pair_ok <nvidia_subr.c>: 0 when no return sits between the begin call and the end call
			awk '/nvco_ioctl_begin\(&nvco_ctx/ { f = 1; next } /nvco_ioctl_end\(&nvco_ctx/ { f = 0 } f && /(^|[^a-z_])return([^a-z_]|$)/ { bad = 1 } END { exit bad }' "$1"
		}
		if pair_ok "$nvs"; then ok "prepared tree: no return between nvco_ioctl_begin and nvco_ioctl_end"; else bad "prepared tree: a return sits between nvco_ioctl_begin and nvco_ioctl_end"; fi
		sed 's/^    sx_xlock(&nvffp->fops_sx);$/    sx_xlock(\&nvffp->fops_sx); if (nr == 0) return EINVAL;/' "$nvs" > "$T/subr.mut"
		if cmp -s "$nvs" "$T/subr.mut"; then bad "pairing mutant changed nothing"; elif pair_ok "$T/subr.mut"; then bad "pairing mutant (a return after the fops_sx lock) stays green"; else ok "pairing mutant is red"; fi
		if grep -q 'devfs_set_cdevpriv(nvffp, nvidia_ctl_dtor)' "$PW/build/tree/nvidia/nvidia_ctl.c"; then ok "prepared tree: the control file's private data is the nvffp the hooks record"; else bad "prepared tree: nvidia_ctl.c no longer stores nvffp as the control file's private data"; fi
		need "$PW/build/tree/nvidia/Makefile" 'nvUvmInterfaceClientHold nvUvmInterfaceClientRelease' "prepared tree: export list"
		[ -f "$PW/build/tree/nvidia/nv_client_owner.h" ] && ok "prepared tree: header present" || bad "prepared tree: header missing"
	else
		cat "$T/prep.out"; bad "prepare-tree failed"
	fi
elif strict; then
	bad "missing $WORK/sources/NVIDIA-FreeBSD-x86_64-580.178.04.tar.xz (set GB10_WORK or place the tarball there)"
else
	echo "skip prepare-tree check: $WORK/sources/NVIDIA-FreeBSD-x86_64-580.178.04.tar.xz not found (set GB10_WORK or place the tarball there)"
fi
if [ "$rc" = 0 ]; then echo "client_owner_test.sh: all checks passed"; else echo "client_owner_test.sh: FAILED"; fi
exit $rc

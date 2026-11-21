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
plant close-ignored 's/if (t->e\[i\].owner == owner \&\& t->e\[i\].refs == 0)/if (t->e[i].owner == owner \&\& t->e[i].refs == 0 \&\& owner == NULL)/'
plant any-class 's/return (hClass == NVCO_CLASS_ROOT || hClass == NVCO_CLASS_ROOT_NON_PRIV ||/return ((hClass | 1u) != 0 || hClass == NVCO_CLASS_ROOT_NON_PRIV ||/'
plant client-op-any-free 's/^\t\treturn (ok);/\t\treturn (1);/'
plant alloc-object-undecoded 's/nvco_is_root_class(((const struct nvco_alloc_object_params \*)args)->hClass));/0);/'
plant hold-ignores-owner 's/if (!nvco_grants(e, owner) || file == NULL)/if (e == NULL || file == NULL || (owner == NULL \&\& 0))/'
plant revoked-ignored 's/ \&\& !e->revoked//'
plant freeing-ignored 's/ \&\& e->freeing == 0//'
plant unhold-file-ignored 's/e->file != file || e->refs == 0/e->refs == 0/'
plant evict-removes-held 's/if (e->refs != 0)$/if (0)/'
plant begin-free-noop 's/e->freeing++;/e->freeing += 0;/'
plant stranger-free-counted 's/if (e == NULL || owner == NULL || e->owner != owner)/if (e == NULL || owner == NULL)/'
plant remove-owner-keeps-held 's/\t\t\tif (t->e\[i\].owner == owner)$/\t\t\tif (0)/'
plant second-file-shares-hold 's/if (e->refs != 0 \&\& e->file != file)/if (0)/'
plant collision-moves-owner 's/if (old->owner != owner) {/if (0) {/'
plant end-free-any-owner 's/e->owner == owner \&\& e->freeing != 0/e->freeing != 0 \&\& (owner == NULL || 1)/'
plant end-free-resets 's/e->freeing--;/e->freeing = 0;/'
plant busy-never 's/return (e != NULL \&\& e->refs != 0);/return (e == NULL \&\& 0);/'
plant ownerless-keeps-stale 's/nvco_remove_handle(t, h);/(void)h;/'
plant second-decoder 's/if (!nvco_is_client_op(nr, size, args))/if (0)/'
plant root-client-class-missing 's/hClass == NVCO_CLASS_ROOT_CLIENT);/0);/'
[ -d "$OGKM/src/nvidia/arch/nvalloc/unix/include" ] && plant escape-number-moved 's/#define\tNVCO_ESC_RM_FREE\t\t0x29/#define\tNVCO_ESC_RM_FREE\t\t0x2A/'
plant status-ignored 's/ok = a64->status == 0;/ok = 1;/'

# (b) the hooks in the patch files.  These are presence checks of whole
# statements, not behaviour tests: the behaviour is the table logic of (a) and
# the test-boot probes.  Each is also run against mutated copies of the patch
# (a deleted hook, an inverted operator) and must turn red there.
has() { grep -qF -- "$2" "$1"; }	# quiet predicate
need() {	# need <file> <fixed string> <what>: a requirement; reports, never returns non-zero
	if has "$1" "$2"; then ok "$3"; else bad "$3 (missing: $2)"; fi
}
PATCH_PINS='nvco_after_ioctl(&nvco_table|the ioctl hook records and frees clients
nvco_remove_owner(&nvco_table|closing a control file forgets its clients
nvUvmInterfaceClientHold(struct file *fp, NvHandle hClient)|the hold export exists
nvUvmInterfaceClientRelease(struct file *fp, NvHandle hClient)|the release export exists
fdrop(fp, curthread)|release drops the hold file reference
fhold(fp)|hold takes its own file reference
sx_sleep(&nvco_table, &nvco_sx, PCATCH,|a client free waits for its holds, interruptibly
nvco_begin_free(&nvco_table, who, free_h)|a free by the owner refuses new holds while it waits
nvco_is_client_op(nr, size, args)|client operations are decoded before the RM call
fp->f_type != DTYPE_VNODE|the owner lookup checks the file type
vp->v_type != VCHR|the owner lookup insists on a character device vnode
strcmp(dev->si_devsw->d_name, "nvidiactl") != 0|the owner lookup insists on the nvidiactl device
p->cdpd_dtr != nvidia_ctl_dtor|the owner lookup accepts only an nvidiactl file
nvco_unhold(&nvco_table, fp, hClient)|release names the file the hold took
nvco_hold(&nvco_table, owner, fp, hClient)|hold names the owner and the file
owner == NULL || sx_xlocked(&nvco_sx)|hold refuses a call made under the table lock
nvco_end_free(&nvco_table, free_h, who, counted)|every free ends its count for its own owner
KASSERT(!sx_xlocked(&nvco_sx)|release asserts the context rule
no hold on client 0x%x for this file|an unmatched release logs'
check_patch() {	# check_patch <patch file>: every pin, one result line each
	printf '%s\n' "$PATCH_PINS" | while IFS='|' read -r pin what; do
		if has "$1" "$pin"; then echo "ok   $what"; else echo "FAIL $what (missing: $pin)"; fi
	done
	n=$(grep -c 'rm_ioctl(sp, nv, &nvffp->nvfp, nr' "$1" || true)
	if [ "$n" = 1 ]; then echo "ok   one rm_ioctl call in the patched default branch"; else echo "FAIL expected one rm_ioctl call in the patch, found $n"; fi
}
check_patch "$PATCH" > "$T/pins.out"
cat "$T/pins.out"
if grep -q '^FAIL' "$T/pins.out"; then rc=1; fi
need "$MKPATCH" 'nvUvmInterfaceClientHold nvUvmInterfaceClientRelease' "the arm64 export list names both"
need "$REPO/scripts/prepare-tree.sh" 'nv_client_owner.h' "prepare-tree copies the header"
need "$REPO/README.md" 'symbol nvUvmInterfaceClientHold undefined' "the README says what a missing export looks like"
need "$REPO/README.md" 'dmesg' "the README says where the undefined-symbol message appears"
need "$REPO/README.md" 'SA_RESTART' "the README says a restartable signal waits again"
if grep -q '^## .*Track #' "$REPO/README.md"; then bad "a tracker label in a README heading"; else ok "README headings carry no tracker label"; fi
need "$REPO/README.md" 'nvidia-uvm bug' "the README tells the reporter about the release diagnostic"
need "$REPO/README.md" 'nvcobusy' "the README names the wait channel of a waiting free"

# (b1) mutations of the patch: each must make check_patch report a FAIL
mutant() {	# mutant <name> <sed expression or 'delete:<fixed string>'>
	case "$2" in
	delete:*)	grep -vF -- "${2#delete:}" "$PATCH" > "$T/mut.patch" ;;
	*)	sed -e "$2" "$PATCH" > "$T/mut.patch" ;;
	esac
	if cmp -s "$PATCH" "$T/mut.patch"; then bad "mutant $1 did not change the patch"; return; fi
	check_patch "$T/mut.patch" > "$T/mut.out"
	if grep -q '^FAIL' "$T/mut.out"; then ok "mutant $1 is red"; else bad "mutant $1 stays green"; fi
}
mutant hook-deleted 'delete:nvco_after_ioctl(&nvco_table'
mutant close-hook-deleted 'delete:nvco_remove_owner(&nvco_table'
mutant fhold-deleted 'delete:fhold(fp)'
mutant client-op-deleted 'delete:nvco_is_client_op(nr, size, args)'
mutant device-check-inverted 's/"nvidiactl") != 0/"nvidiactl") == 0/'
mutant vchr-check-inverted 's/vp->v_type != VCHR/vp->v_type == VCHR/'
mutant dtor-check-inverted 's/p->cdpd_dtr != nvidia_ctl_dtor/p->cdpd_dtr == nvidia_ctl_dtor/'
mutant vnode-check-inverted 's/fp->f_type != DTYPE_VNODE/fp->f_type == DTYPE_VNODE/'
mutant xlocked-guard-deleted 's/ || sx_xlocked(&nvco_sx)//'
mutant release-diagnostic-deleted 'delete:no hold on client 0x%x for this file'
mutant sleep-uninterruptible 's/PCATCH,/0,/'
mutant second-rm-ioctl 's/^+            if (wait_error != 0) {/+            rm_ioctl(sp, nv, \&nvffp->nvfp, nr, args, size);\
&/'

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
		need "$PW/build/tree/nvidia/nvidia_subr.c" 'nvco_after_ioctl(&nvco_table' "prepared tree: ioctl hook"
		need "$PW/build/tree/nvidia/nvidia_subr.c" 'nvco_remove_owner(&nvco_table, nvffp)' "prepared tree: forget on close"
		nvs=$PW/build/tree/nvidia/nvidia_subr.c
		a=$(grep -n 'nr = xfer->cmd;' "$nvs" | head -1 | cut -d: -f1)
		b=$(grep -n 'int client_op = nvco_is_client_op' "$nvs" | head -1 | cut -d: -f1)
		c=$(grep -n 'size = xfer->size;' "$nvs" | head -1 | cut -d: -f1)
		d=$(grep -n 'copyin(NvP64_VALUE(xfer->ptr), args, size)' "$nvs" | head -1 | cut -d: -f1)
		if [ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ] && [ -n "$d" ] && [ "$a" -lt "$b" ] && [ "$c" -lt "$b" ] && [ "$d" -lt "$b" ]; then
			ok "prepared tree: the transfer escape (size, args, nr) is unwrapped before the hook decodes"
		else
			bad "prepared tree: the transfer escape unwrap (nr line '$a', size '$c', args '$d') must come before the decoder (line '$b')"
		fi
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

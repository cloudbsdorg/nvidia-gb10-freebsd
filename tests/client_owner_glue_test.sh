#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# client_owner_glue_test.sh - Track #2373: behaviour tests of the REAL nvidia.ko glue.
# src/gb10-client-owner/nvco_glue.h (file owner lookup, the exported hold and
# release, the ioctl begin/end hook, the close-time forget) is compiled in
# userland against fakes of the kernel
# (tests/data/nvidia_glue_harness.c), then run.  Mutants of the extracted code
# (an owner check turned off, a comment instead of the call, a wait loop turned
# into an if, a release that keeps the file reference, a forget that does not
# forget, ...) must each make the harness fail.  Also pins, on comment-stripped
# code that must hold no disabled forms, the call sites inside
# nvidia_handle_ioctl and nvidia_close_ctl and their order against fops_sx.
#
# Run: sh tests/client_owner_glue_test.sh

set -eu
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL
TESTSDIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH= cd -- "$TESTSDIR/.." && pwd)
mkdir -p "${TMPDIR:-$REPO/tmp}"
T=$(mktemp -d "${TMPDIR:-$REPO/tmp}/client-owner-glue.XXXXXXXX")
trap 'rm -rf "$T"' EXIT HUP INT QUIT TERM
. "$TESTSDIR/pins_lib.sh"
PATCH=$REPO/patches/patch-zz-nvidia_client_owner_subr.c
rc=0

# the added text of the patch (leading + removed)
added() { awk '/^\+/ && !/^\+\+\+/ { print substr($0, 2) }' "$1"; }
cp "$REPO/src/gb10-client-owner/nvco_glue.h" "$T/real.inc"
REAL_GLUE=$REPO/src/gb10-client-owner/nvco_glue.h

run_glue() {	# run_glue <glue file> <out>: compile and run; 0 ok, 1 harness failed, 2 did not build
	mkdir -p "$T/b"
	cp "$1" "$T/b/nvco_glue.h"
	cc -std=gnu11 -Wall -Wextra -Wno-unused-function -Werror -I "$T/b" -I "$REPO/src/gb10-client-owner" \
	    -o "$T/b/h" "$REPO/tests/data/nvidia_glue_harness.c" >"$2" 2>&1 || return 2
	"$T/b/h" >"$2" 2>&1 || return 1
	return 0
}

if run_glue "$T/real.inc" "$T/real.out"; then
	echo "ok   the real glue passes every scenario"
else
	cat "$T/real.out"; echo "FAIL the real glue fails the harness"; rc=1
fi

mutant() {	# mutant <name> <sed expression>
	sed -e "$2" "$T/real.inc" > "$T/mut.inc"
	if cmp -s "$T/real.inc" "$T/mut.inc"; then echo "FAIL mutant $1 changed nothing"; rc=1; return; fi
	run_glue "$T/mut.inc" "$T/mut.out" && r=0 || r=$?
	case $r in
	1) echo "ok   mutant $1 is red" ;;
	2) echo "FAIL mutant $1 did not build: $(head -2 "$T/mut.out" | tr '\n' ' ')"; rc=1 ;;
	*) echo "FAIL mutant $1 stays green"; rc=1 ;;
	esac
}
mutant hold-always-refused-branch-off 's/    if (!held)$/    if (0 \&\& !held)/'
mutant hold-not-asked 's/held = nvco_hold(&nvco_table, owner, fp, hClient);/held = 1;/'
mutant hold-commented-out 's/held = nvco_hold(&nvco_table, owner, fp, hClient);/held = 1; \/* held = nvco_hold(\&nvco_table, owner, fp, hClient); *\//'
mutant release-keeps-file 's/^    if (was_held)$/    if (0 \&\& was_held)/'
mutant wait-is-an-if 's/while (wait_error == 0 \&\& nvco_busy/if (wait_error == 0 \&\& nvco_busy/'
mutant wait-never 's/while (wait_error == 0 \&\& nvco_busy(&nvco_table, c->free_h))/while (0 \&\& nvco_busy(\&nvco_table, c->free_h))/'
mutant forget-does-nothing 's/nvco_remove_owner(&nvco_table, nvffp);/(void)nvffp;/'
mutant vnode-check-off 's/vp->v_type != VCHR/0/'
mutant filetype-check-off 's/fp->f_type != DTYPE_VNODE/0/'
mutant dtor-check-off 's/p->cdpd_dtr != nvidia_ctl_dtor/0/'
mutant stranger-free-reaches-rm 's/if (!nvco_free_permitted(&nvco_table, who, c->free_h)) {/if (0 \&\& !nvco_free_permitted(\&nvco_table, who, c->free_h)) {/'
mutant alloc-mark-not-taken 's/c->mark = nvco_alloc_mark(&nvco_table);/c->mark = ~(uint64_t)0;/'
mutant record-ignores-the-mark 's/nvco_after_ioctl_marked(&nvco_table, who, nr, size, args, c->mark)/nvco_after_ioctl_marked(\&nvco_table, who, nr, size, args, nvco_alloc_mark(\&nvco_table))/'
mutant free-success-not-logged 's/nvco_free_succeeded(nr, size, args, status));/0);/'
mutant junk-frees-logged 's/nvco_free_succeeded(nr, size, args, status));/1);/'
mutant free-not-counted 's/c->counted = nvco_begin_free(&nvco_table, c->free_h, &c->unlisted);/c->counted = 0;/'
mutant no-own-file-reference 's/if (!fhold(fp)) {/if (0) {/'
mutant end-free-skipped 's/^    if (c->free_ok)$/    if (0)/'
mutant failed-ioctl-recorded 's/^    if (status == 0)$/    if (status == 0 || 1)/'
mutant xlocked-guard-off 's/ || sx_xlocked(&nvco_sx)//'
mutant recording-needs-the-rate-limiter 's/^    if (status == 0)$/    if (status == 0 \&\& ppsratecheck(\&nvco_rec_lasttime, \&nvco_rec_curpps, 1))/'
mutant release-drops-wrong-handle 's/was_held = nvco_unhold(&nvco_table, fp, hClient);/was_held = nvco_unhold(\&nvco_table, fp, hClient + 0);\n    (void)0; if (hClient == 0xC1D00000u) was_held = 1;/'

# a mutant that needs more than a one-line sed: <name> <perl -0 expression on the glue>
pmut() {
	perl -0pe "$2" "$T/real.inc" > "$T/mut.inc"
	if cmp -s "$T/real.inc" "$T/mut.inc"; then echo "FAIL mutant $1 changed nothing"; rc=1; return; fi
	run_glue "$T/mut.inc" "$T/mut.out" && r=0 || r=$?
	case $r in
	1) echo "ok   mutant $1 is red" ;;
	2) echo "FAIL mutant $1 did not build: $(head -2 "$T/mut.out" | tr '\n' ' ')"; rc=1 ;;
	*) echo "FAIL mutant $1 stays green"; rc=1 ;;
	esac
}
# the table lock kept across the RM call on the free path (the end re-takes it only if it is not held, as a quiet guard would)
pmut free-lock-held-across-rm 's/(c->counted = nvco_begin_free.*?\n)    sx_xunlock\(&nvco_sx\);\n    return wait_error;/$1    if (wait_error != 0)\n        sx_xunlock(&nvco_sx);\n    return wait_error;/s; s/(    if \(!c->client_op && !c->free_ok\)\n        return;\n)    sx_xlock\(&nvco_sx\);/$1    if (!sx_xlocked(&nvco_sx))\n        sx_xlock(&nvco_sx);/'

# mutants of the table logic, run against the glue harness (a header copy first on the include path)
HDR=$REPO/src/gb10-client-owner/nv_client_owner.h
hmutant() {	# hmutant <name> <sed on the header>
	mkdir -p "$T/hm"
	sed -e "$2" "$HDR" > "$T/hm/nv_client_owner.h"
	if cmp -s "$HDR" "$T/hm/nv_client_owner.h"; then echo "FAIL header mutant $1 changed nothing"; rc=1; return; fi
	mkdir -p "$T/b"; cp "$T/real.inc" "$T/b/nvco_glue.h"
	if ! cc -std=gnu11 -Wall -Wextra -Wno-unused-function -Werror -I "$T/hm" -I "$T/b" -I "$REPO/src/gb10-client-owner" \
	    -o "$T/b/hm" "$REPO/tests/data/nvidia_glue_harness.c" >"$T/hm/out" 2>&1; then
		echo "FAIL header mutant $1 did not build: $(head -2 "$T/hm/out" | tr '\n' ' ')"; rc=1; return
	fi
	if "$T/b/hm" >"$T/hm/out" 2>&1; then echo "FAIL header mutant $1 stays green in the glue harness"; rc=1; else echo "ok   header mutant $1 is red in the glue harness"; fi
}
# n1 needs both halves removed: the unlisted flag of a free that finds a marker, and the entry state the end of a free logs from
hmutant n1-fail-open 's/\*unlisted = (e == NULL || e->tomb);/*unlisted = (e == NULL);/;s/(unlisted || (e != NULL \&\& token != 0 \&\& e->fgen == token \&\& e->tomb))/unlisted/'
hmutant tomb-eperm 's/return (e == NULL || e->tomb || e->owner == who);/return (e == NULL || e->owner == who);/'
hmutant tombstone-never 's/^		e->tomb = 1;$/		e->tomb = 0;/'
hmutant tombstone-collides 's/		if (old->tomb) {/		if (0 \&\& old->tomb) {/'
hmutant close-drops-marker 's/ \&\& nvco_remove_entry(t, \&t->e\[i\]))$/ \&\& (nvco_drop_entry(t, \&t->e[i]), 1))/'
hmutant grants-ignore-freeing 's/ \&\& e->freeing == 0);/);/'

# pins on the call sites in the handler and the close path: comment-stripped, no disabled forms,
# and in order against fops_sx.  The patch's added lines carry the calls; its context lines carry fops_sx.
pins_ok() {	# pins_ok <patch file>: prints problems
	_p=$1
	added "$_p" > "$T/pa.c"
	pin_strip "$T/pa.c" > "$T/pa.stripped"
	_t=$(cat "$T/pa.stripped")
	pin_dead "$_t" || echo "the patch has a disabled-code form (if (0, 0 &&, || 1)"
	pin_has "$_t" 'nvco_error = nvco_ioctl_begin\(&nvco_ctx, nvco_who, nr, size, args\);' || echo "no begin call in the handler"
	pin_has "$_t" '^    if \(nvco_error != 0\) \{' || echo "the begin error is not acted on"
	pin_has "$_t" '^        goto nvco_out;' || echo "the begin error does not skip the ioctl (goto nvco_out)"
	pin_has "$_t" '^nvco_out:' || echo "no nvco_out label before the copy-out and free"
	[ "$(printf '%s\n' "$_t" | grep -cF 'free(args')" = 0 ] || echo "the patch adds its own free of args (the label reuses the handler's)"
	pin_has "$_t" '^    nvco_ioctl_end\(&nvco_ctx, nvco_who, status, nr, size, args\);' || echo "no end call in the handler"
	printf '%s\n' "$_t" | grep -qF 'sx_xlock(&nvco_sx)' && echo "the patch takes the table lock itself (it must stay a leaf taken inside the glue)"
	pin_has "$_t" '^    nvco_forget_owner\(nvffp\);' || echo "no forget call in the close path"
	# order in the patch: begin before the fops_sx lock, end before its unlock (one file's records follow its RM order)
	_b=$(grep -n 'nvco_ioctl_begin(&nvco_ctx' "$_p" | head -1 | cut -d: -f1)
	_l=$(grep -n '^[ +]    sx_xlock(&nvffp->fops_sx);' "$_p" | head -1 | cut -d: -f1)
	_u=$(grep -n '^ *    sx_xunlock(&nvffp->fops_sx);' "$_p" | head -1 | cut -d: -f1)
	_e=$(grep -n '^+    nvco_ioctl_end(&nvco_ctx' "$_p" | head -1 | cut -d: -f1)
	_xu=$(grep -n '^[ +]    sx_xunlock(&nvffp->fops_sx);' "$_p" | head -1 | cut -d: -f1)
	[ -n "$_b" ] && [ -n "$_l" ] && [ "$_b" -lt "$_l" ] || echo "the begin call is not before the fops_sx lock"
	[ -n "$_xu" ] && [ -n "$_e" ] && [ "$_e" -lt "$_xu" ] || echo "the end call is not before the fops_sx unlock"
	[ "$(grep -c '^+.*rm_ioctl(' "$_p" || true)" = 0 ] || echo "the patch itself calls rm_ioctl (the hook must not wrap it)"
		pin_has "$_t" 'const void \*nvco_who = \(nv->flags & NV_FLAG_CONTROL\) != 0 \? nvffp : NULL;' || echo "only a control file may own clients: nvco_who is not NULL for other files"
}
glue_pins() {
	pin_strip "$1" > "$T/g.stripped"
	_g=$(cat "$T/g.stripped")
	pin_dead "$_g" || echo "the glue has a disabled-code form (if (0, 0 &&, || 1)"
	pin_has "$_g" 'sx_sleep\(&nvco_table, &nvco_sx, PCATCH, "nvcobusy", 0\)' || echo "the wait is not an interruptible nvcobusy sleep"
	pin_has "$_g" 'ppsratecheck\(&nvco_rec_lasttime, &nvco_rec_curpps, 1\)' || echo "the not-recorded message has no limiter of its own"
	pin_has "$_g" 'ppsratecheck\(&nvco_rel_lasttime, &nvco_rel_curpps, 1\)' || echo "the release message has no limiter of its own"
	pin_has "$_g" 'while \(wait_error == 0 && nvco_busy\(&nvco_table, c->free_h\)\)' || echo "the wait is not a loop"
}
out=$(pins_ok "$PATCH"; glue_pins "$REAL_GLUE")
if [ -z "$out" ]; then echo "ok   call sites in the handler and the close path"; else echo "FAIL call sites:"; echo "$out"; rc=1; fi

pmutant() {	# pmutant <name> <sed on the patch>
	sed -e "$2" "$PATCH" > "$T/pm.patch"
	if cmp -s "$PATCH" "$T/pm.patch"; then echo "FAIL pin mutant $1 changed nothing"; rc=1; return; fi
	if [ -z "$(pins_ok "$T/pm.patch")" ]; then echo "FAIL pin mutant $1 stays green"; rc=1; else echo "ok   pin mutant $1 is red"; fi
}
gmutant() {	# gmutant <name> <sed on the glue>: the glue pins must fail
	sed -e "$2" "$REAL_GLUE" > "$T/gm.h"
	if cmp -s "$REAL_GLUE" "$T/gm.h"; then echo "FAIL glue pin mutant $1 changed nothing"; rc=1; return; fi
	if [ -z "$(glue_pins "$T/gm.h")" ]; then echo "FAIL glue pin mutant $1 stays green"; rc=1; else echo "ok   glue pin mutant $1 is red"; fi
}
gmutant shared-rate-limiter 's/ppsratecheck(&nvco_rel_lasttime, &nvco_rel_curpps, 1)/ppsratecheck(\&nvco_rec_lasttime, \&nvco_rec_curpps, 1)/'
gmutant wait-commented 's|^        wait_error = sx_sleep(.*|        wait_error = 0; /* sx_sleep(\&nvco_table, \&nvco_sx, PCATCH, "nvcobusy", 0); */|'
pmutant who-for-every-file 's|^+    const void \*nvco_who = (nv->flags \& NV_FLAG_CONTROL) != 0 ? nvffp : NULL;|+    const void *nvco_who = nvffp;|'
pmutant begin-commented 's|^+    int nvco_error = nvco_ioctl_begin(&nvco_ctx, nvco_who, nr, size, args);|+    int nvco_error = 0; /* nvco_error = nvco_ioctl_begin(\&nvco_ctx, nvco_who, nr, size, args); */|'
pmutant begin-disabled 's|^+    if (nvco_error != 0) {|+    if (0 \&\& nvco_error != 0) {|'
pmutant begin-error-not-skipping 's|^+        goto nvco_out;|+        (void)0;|'
pmutant end-after-unlock 's|^+    nvco_ioctl_end(&nvco_ctx, nvco_who, status, nr, size, args);.*|+    sx_xunlock(\&nvffp->fops_sx);\
+    nvco_ioctl_end(\&nvco_ctx, nvco_who, status, nr, size, args);|'
pmutant table-lock-in-handler 's|^+    struct nvco_ioctl_ctx nvco_ctx;|+    struct nvco_ioctl_ctx nvco_ctx; sx_xlock(\&nvco_sx);|'
pmutant own-free-of-args 's|^+        goto nvco_out;|+        free(args, M_NVIDIA); goto nvco_out;|'
pmutant end-commented 's|^+    nvco_ioctl_end(&nvco_ctx, nvco_who, status, nr, size, args);.*|+    /* nvco_ioctl_end(\&nvco_ctx, nvco_who, status, nr, size, args); */|'
pmutant forget-commented 's|^+    nvco_forget_owner(nvffp);|+    /* nvco_forget_owner(nvffp); */|'
pmutant forget-disabled 's|^+    nvco_forget_owner(nvffp);|+    if (0) nvco_forget_owner(nvffp);|'
pmutant begin-after-lock 's|^+     \* Track #2373: a client free waits for its holds here|+    sx_xlock(\&nvffp->fops_sx);\
&|'
if [ "$rc" = 0 ]; then echo "client_owner_glue_test.sh: all checks passed"; else echo "client_owner_glue_test.sh: FAILED"; fi
exit $rc

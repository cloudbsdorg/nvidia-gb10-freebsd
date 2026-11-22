#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# run.sh - the stock-install test, host side: get a fresh stock FreeBSD
# machine, run guest.sh in it as a normal user, bring the results back as
# JSON and JSONL.  Any repository that follows the project Makefile contract
# can call it (see README.md in this directory for the interface).
#
# Usage: sh run.sh --repo-url URL [--ref REF] [--os OS] [--arch ARCH]
#            [--backend vmm|ssh] [--ssh USER@HOST] [--ssh-key FILE]
#            [--installed-manifest PATH] [--expected-manifest REL]
#            [--load MODULE] [--make-arg VAR=VALUE]... [--results DIR] [--dry-run]
#   --os        16.0-CURRENT (default), 15.1-RELEASE, ...: the FreeBSD
#               project's stock image (a snapshot for CURRENT, checked live)
#   --arch      aarch64 (default) or amd64
#   --backend   vmm: a new VM through cloudbsd-vmm (fleet.call through the
#               masters), deleted afterwards; ssh: a fresh stock machine you
#               already made, reached as USER@HOST (the user is the normal
#               user the test runs as, with doas set up as the README of the
#               repository under test says)
#   --ssh-key   the private key for --backend ssh (a path, never the key)
#   --make-arg  passed to guest.sh (added to every make command line, for
#               example ACCEPT_NVIDIA_LICENSE=1 from the person running it)
#   --results   where to put the run (default: the calling repository's
#               tests/install-e2e/results/<os>-<arch>-<UTC time>)
#   --dry-run   print the plan (and, for vmm, the service's dry run) only
#
# The vmm backend reaches cloudbsd-vmm through the fleet masters with a
# command of the test host's own (nothing about the fleet is in this
# repository): E2E_VMM_CALL is a program that reads one fleet.call JSON
# request on stdin and prints the answer; E2E_VMM_WORKER_AARCH64 and
# E2E_VMM_WORKER_AMD64 name the worker for each guest arch.  Unset, the
# backend reports blocked.
#
# Output: RESULTS/run.jsonl (one stock-install-step/1 object per host step,
# then the guest's steps), RESULTS/summary.json (stock-install-summary/1,
# with "os", "arch", "backend", "pass", and "blocked" with a reason when no
# machine could be had).  Exit 0 pass, 1 fail, 2 usage, 3 blocked.

set -u
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin
export PATH
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)

repo_url=
ref=
os=16.0-CURRENT
arch=aarch64
backend=vmm
ssh_target=
ssh_key=
inst_man=
exp_man=
load_mod=
results=
dry=0
margs=
while [ $# -gt 0 ]; do
	case $1 in
	--repo-url) repo_url=${2:?}; shift ;;
	--ref) ref=${2:?}; shift ;;
	--os) os=${2:?}; shift ;;
	--arch) arch=${2:?}; shift ;;
	--backend) backend=${2:?}; shift ;;
	--ssh) ssh_target=${2:?}; shift ;;
	--ssh-key) ssh_key=${2:?}; shift ;;
	--installed-manifest) inst_man=${2:?}; shift ;;
	--expected-manifest) exp_man=${2:?}; shift ;;
	--load) load_mod=${2:?}; shift ;;
	--results) results=${2:?}; shift ;;
	--dry-run) dry=1 ;;
	--make-arg) margs="$margs --make-arg ${2:?}"; case $2 in *[!A-Za-z0-9_=.,:/-]*) echo "run.sh: --make-arg: only [A-Za-z0-9_=.,:/-]" >&2; exit 2 ;; esac; shift ;;
	-h|--help) sed -n '2,32p' "$0"; exit 0 ;;
	*) echo "run.sh: unknown argument $1" >&2; exit 2 ;;
	esac
	shift
done
[ -n "$repo_url" ] || { echo "run.sh: --repo-url is required" >&2; exit 2; }
case $arch in aarch64|amd64) ;; *) echo "run.sh: --arch is aarch64 or amd64" >&2; exit 2 ;; esac
case $os in
*-CURRENT|*-RELEASE|*-STABLE|*-BETA*|*-RC*) ;;
*) echo "run.sh: --os looks like 16.0-CURRENT or 15.1-RELEASE" >&2; exit 2 ;;
esac
case $backend in vmm|ssh) ;; *) echo "run.sh: --backend is vmm or ssh" >&2; exit 2 ;; esac
stamp=$(date -u +%Y%m%dT%H%M%SZ)
[ -n "$results" ] || results=$here/results/$os-$arch-$stamp
mkdir -p -- "$results" || exit 2
results=$(cd "$results" && pwd -P)
J=$results/run.jsonl
: > "$J"
idx=0

json_str() {
	printf '%s' "$1" | tr '\n\t' '  ' | sed 's/\\/\\\\/g; s/"/\\"/g'
}

hstep() {
	printf '{"schema":"stock-install-step/1","index":%s,"step":"host:%s","pass":%s,"rc":%s,"seconds":0,"detail":"%s","log":""}\n' \
	    "$idx" "$1" "$2" "$3" "$(json_str "$4")" >> "$J"
	idx=$((idx + 1))
	printf '%s host:%s %s\n' "$([ "$2" = true ] && echo PASS || echo FAIL)" "$1" "$4"
}

summary() {
	# summary PASS BLOCKED-REASON
	printf '{"schema":"stock-install-summary/1","pass":%s,"os":"%s","arch":"%s","backend":"%s","repo_url":"%s","ref":"%s","blocked":"%s","results":"%s"}\n' \
	    "$1" "$os" "$arch" "$backend" "$(json_str "$repo_url")" "$(json_str "$ref")" "$(json_str "$2")" "$(json_str "$results")" \
	    | tee "$results/summary.json"
}

# image: the FreeBSD project's stock cloud-init image for OS and ARCH
case $arch in
aarch64) iarch=arm64-aarch64; darch=aarch64 ;;
amd64) iarch=amd64; darch=amd64 ;;
esac
case $os in
*-CURRENT|*-STABLE) ibase=https://download.freebsd.org/snapshots/VM-IMAGES/$os/$darch/Latest ;;
*) ibase=https://download.freebsd.org/releases/VM-IMAGES/$os/$darch/Latest ;;
esac
image=FreeBSD-$os-$iarch-BASIC-CLOUDINIT-ufs.raw
if fetch -q -o "$results/CHECKSUM.SHA256" "$ibase/CHECKSUM.SHA256" 2>/dev/null; then
	# a snapshot names its date, commit and revision in the file name
	# (FreeBSD-16.0-CURRENT-arm64-aarch64-BASIC-CLOUDINIT-20261117-611046b15dbb-291235-ufs.raw.xz)
	_line=$(grep -E "^SHA256 \(FreeBSD-$os-$iarch-BASIC-CLOUDINIT(-[0-9]+-[0-9a-f]+-[0-9]+)?-ufs\.raw\.xz\) = " "$results/CHECKSUM.SHA256" | sed -n 1p)
	ifile=$(printf '%s\n' "$_line" | sed -n 's/^SHA256 (\(.*\)) = .*/\1/p')
	isum=${_line##* = }
	if [ -n "$ifile" ]; then
		image=${ifile%.xz}
		hstep image true 0 "$ibase/$ifile sha256 $isum (checked live)"
	else
		hstep image false 1 "no BASIC-CLOUDINIT ufs raw image in $ibase/CHECKSUM.SHA256"
	fi
else
	hstep image false 1 "cannot fetch $ibase/CHECKSUM.SHA256"
	summary false "no stock image found for $os $arch"
	exit 3
fi

# sq WORD: WORD in single quotes for a remote sh(1) command line, so no
# argument (a URL, a ref) is ever read as shell syntax by the guest
sq() {
	printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}
guest_args="--repo-url $(sq "$repo_url") --results results"
[ -n "$ref" ] && guest_args="$guest_args --ref $(sq "$ref")"
[ -n "$inst_man" ] && guest_args="$guest_args --installed-manifest $(sq "$inst_man")"
[ -n "$exp_man" ] && guest_args="$guest_args --expected-manifest $(sq "$exp_man")"
[ -n "$load_mod" ] && guest_args="$guest_args --load $(sq "$load_mod")"
guest_args="$guest_args$margs"

case $backend in
ssh)
	[ -n "$ssh_target" ] || { echo "run.sh: --backend ssh needs --ssh USER@HOST" >&2; exit 2; }
	set -- -o BatchMode=yes -o ConnectTimeout=15
	[ -n "$ssh_key" ] && set -- "$@" -i "$ssh_key" -o IdentitiesOnly=yes
	if [ "$dry" = 1 ]; then
		hstep plan true 0 "copy guest.sh to $ssh_target, run: sh guest.sh $guest_args"
		summary true "dry run"
		exit 0
	fi
	# the remote is a fresh machine: its uname must say the OS and arch asked for
	_u=$(ssh "$@" "$ssh_target" 'uname -rp') || { hstep reach false 1 "ssh $ssh_target failed"; summary false "cannot reach $ssh_target"; exit 3; }
	case "$_u" in
	"$os"*" $arch") hstep reach true 0 "$ssh_target: $_u" ;;
	*) hstep reach false 1 "$ssh_target is $_u, not $os $arch"; summary false "wrong machine"; exit 3 ;;
	esac
	_rd=stock-install-e2e-$stamp
	ssh "$@" "$ssh_target" "mkdir -p $_rd" && scp -q "$@" "$here/guest.sh" "$ssh_target:$_rd/guest.sh" \
	    || { hstep copy false 1 "scp failed"; summary false "copy failed"; exit 1; }
	# shellcheck disable=SC2029
	ssh "$@" "$ssh_target" "cd $_rd && sh guest.sh $guest_args" > "$results/guest.out" 2>&1
	grc=$?
	ssh "$@" "$ssh_target" "cd $_rd && tar -cf - results" | tar -xf - -C "$results" \
	    || hstep collect false 1 "could not bring the results back"
	;;
vmm)
	case $arch in
	aarch64) worker=${E2E_VMM_WORKER_AARCH64:-} ;;
	amd64) worker=${E2E_VMM_WORKER_AMD64:-} ;;
	esac
	if [ -z "$worker" ] || [ -z "${E2E_VMM_CALL:-}" ]; then
		hstep vmm-worker false 3 "no cloudbsd-vmm worker for $arch guests is configured (E2E_VMM_WORKER_$(echo "$arch" | tr a-z A-Z) and E2E_VMM_CALL)"
		summary false "no vmm worker for $arch guests: set E2E_VMM_CALL and E2E_VMM_WORKER_$(echo "$arch" | tr a-z A-Z), or use --backend ssh with a fresh stock machine"
		exit 3
	fi
	_name=e2e-$(printf '%s' "$os" | tr -cd 'A-Za-z0-9' | cut -c1-8)-$(date -u +%H%M%S)
	python3 -I -c 'import json,sys
w,n,img=sys.argv[1:4]
print(json.dumps({"worker":w,"agent":"vmm","tool":"vm.create","dry_run":True,"arguments":{
 "name":n,"vcpus":4,"memoryMiB":8192,"firmware":"uefi","engine":"bhyve","serialConsole":True,
 "description":"stock-install E2E guest (tests/install-e2e/run.sh)",
 "disks":[{"bus":"virtio-blk","pool":"/cloudbsd/vm/disks","volume":n+"-disk0","sizeGiB":40,"source":"image","image":img}],
 "nics":[{"model":"virtio-net","switch":"vmsw0"}]}}))' "$worker" "$_name" "$image" > "$results/vm-create-dry.json"
	$E2E_VMM_CALL < "$results/vm-create-dry.json" > "$results/vm-create-dry.out" 2>&1
	if grep -q -E 'not the name of an image in the library|no image named' "$results/vm-create-dry.out"; then
		hstep vmm-plan false 3 "$worker has no $image in its image library (image.fetch $ibase/$image.xz, then image.decompress)"
	elif grep -q '"viable"' "$results/vm-create-dry.out"; then
		hstep vmm-plan true 0 "$worker accepts the VM spec (dry run)"
	else
		hstep vmm-plan false 3 "$(head -c 300 "$results/vm-create-dry.out")"
	fi
	# Creating the VM with its cloud-init user data (the test user, its
	# doas rule), and bringing the results back from the guest, are not
	# wired yet.
	hstep vmm-run false 3 "vm.create with cloud-init and the result read-back are not wired in run.sh yet"
	summary false "vmm backend: VM creation and result collection not wired yet"
	exit 3
	;;
esac

if [ -f "$results/results/steps.jsonl" ]; then
	cat "$results/results/steps.jsonl" >> "$J"
	_g=$(sed -n '$p' "$results/guest.out")
	printf '%s\n' "$_g" > "$results/guest-summary.json"
fi
if [ "${grc:-1}" = 0 ]; then
	summary true ""
	exit 0
fi
summary false ""
exit 1

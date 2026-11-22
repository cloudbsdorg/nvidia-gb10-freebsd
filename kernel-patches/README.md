# FreeBSD kernel patches for GPUs on arm64 and on Ampere Altra

Four patches to the FreeBSD kernel source. You apply them to the source tree of the
FreeBSD you run, build a kernel, and boot it next to the stock one. Nothing here replaces
files on your system until you say so, and the stock kernel stays in `/boot/kernel`.

| # | File | Who needs it | Adds |
|---|---|---|---|
| 1 | [`0001-linuxkpi-arm64-write-combining.diff`](0001-linuxkpi-arm64-write-combining.diff) | **every arm64 machine** that runs a drm-kmod driver (amdgpu, nvidia-drm, ...) | nothing to set |
| 2 | [`0002-linuxkpi-altra-erratum-82288.diff`](0002-linuxkpi-altra-erratum-82288.diff) | Ampere Altra / Altra Max with a drm-kmod driver | `compat.linuxkpi.altra_82288`, `compat.linuxkpi.altra_82288_active` |
| 3 | [`0003-arm64-kernel-alignment-fixup.diff`](0003-arm64-kernel-alignment-fixup.diff) | Ampere Altra / Altra Max with any GPU driver, nvidia.ko included | `machdep.kern_align_fixup`, `machdep.kern_align_fixup_active`, `machdep.kern_align_fixups` |
| 4 | [`0004-pci-host-generic-altra-ecam.diff`](0004-pci-host-generic-altra-ecam.diff) | Ampere Altra (any PCIe device) | nothing to set |

The order is in [`series`](series). The four patches change different files, so you can
apply any subset. Patches 2, 3 and 4 detect the Altra by themselves and do nothing on other
machines, so applying all four on any arm64 machine is safe. On amd64 and the other
architectures the patched code is not compiled in.

They are BSD-2-Clause, written for this project. They are not part of FreeBSD.

Contents:

- [How to apply](#how-to-apply), the whole walk-through, start to finish
- [With the helper script](#with-the-helper-script) (`apply.sh`)
- [The patches in detail](#the-patches-in-detail): what each one fixes, symptoms, who needs it,
  tunables, how to check it is active
- [Rebuild the GPU modules too](#rebuild-the-gpu-modules-against-the-patched-tree)
- [FreeBSD updates](#freebsd-updates-freebsd-update-and-pkgbase)
- [Tested on](#tested-on)
- [Troubleshooting](#troubleshooting)
- [Reference](#reference): the manual page and the test

## How to apply

Everything is done as a normal user, except the lines that start with `doas`. If you use
`sudo`, write `sudo` where it says `doas`. The commands assume `sh` or `bash`; under `csh`
or `tcsh` run `sh` first.

The walk-through uses these paths. Change them if you like, but keep them the same in every
step:

```sh
SRC=$HOME/src/freebsd        # the FreeBSD source tree you will patch
OBJ=$HOME/obj                # where the build goes
KP=$HOME/nvidia-gb10-freebsd/kernel-patches   # this directory
```

If you do not have this repository yet:

```sh
git clone https://github.com/cloudbsdorg/nvidia-gb10-freebsd.git $HOME/nvidia-gb10-freebsd
```

You need `git` (`doas pkg install git`) and about 4 GB of disk for the source and the build.

### 1. Check whether you need them

You need patch 1 on any arm64 machine where you use a graphics driver from drm-kmod
(amdgpu, nvidia-drm and the others). You need patches 2, 3 and 4 only on an Ampere Altra or
Altra Max. To find out whether this machine is one, look at the ACPI MCFG table:

```sh
doas acpidump -t | grep -A3 'MCFG:'
```

On an Ampere Altra this prints:

```
  MCFG: Length=140, Revision=1, Checksum=169,
	OEMID=Ampere, OEM Table ID=Altra, OEM Revision=0x1,
	Creator ID=AMP., Creator Revision=0x1000013
```

`OEMID=Ampere` and an `OEM Table ID` that starts with `Altra` mean it is an Altra: apply all
four. Anything else (another OEMID, or no MCFG at all) means patch 1 is the one you need;
patches 2 to 4 would stay off. On amd64 you need none of them.

The patches do not all use the same test:

- patches 2 and 3 switch on for `OEMID=Ampere` and any `OEM Table ID` that starts with
  `Altra`, at any `OEM Revision`;
- patch 4 switches on only for `OEM Table ID=Altra` exactly and `OEM Revision=0x1`, which is
  what the Altra boards it was checked on report. With another table ID or revision, patch 4
  stays off and step 7 shows no `32-bit config space` lines; if your PCIe devices then show
  wrong IDs in `pciconf -lv`, [report the `acpidump` lines above](#reporting-problems).

Check the architecture too:

```sh
uname -m -p
```

```
arm64 aarch64
```

### 2. Get the source tree that matches your running kernel

The patched kernel must be built from the same FreeBSD version you run, so that your world,
your packages and your kernel modules keep matching. First find out what you run:

```sh
uname -v        # the build of the running kernel
uname -K        # its __FreeBSD_version
uname -U        # the __FreeBSD_version of your installed world (userland)
```

Example output on a 16.0-CURRENT snapshot:

```
FreeBSD 16.0-CURRENT #0 main-n283001-2cc3f14701c9: Thu Nov 19 04:10:00 UTC 2026     root@releng3.nyi.freebsd.org:/usr/obj/usr/src/arm64.aarch64/sys/GENERIC
1600031
1600031
```

`main` is the branch and the 12 hex digits after `n283001-` are the source commit. A
15-STABLE kernel shows `stable/15-n...-<commit>`; a release kernel shows, for example,
`FreeBSD 15.0-RELEASE releng/15.0-n281010-7aedc8de6446 GENERIC`. If `uname -K` and `uname -U` differ, your
world and kernel are already out of step: update first, then come back.

Save the branch and the commit:

```sh
BRANCH=$(uname -v | sed -nE 's/.*[ ](main|stable\/[0-9]+|releng\/[0-9]+\.[0-9]+)-.*/\1/p')
COMMIT=$(uname -v | sed -nE 's/.*[ ](main|stable\/[0-9]+|releng\/[0-9]+\.[0-9]+)-(n[0-9]+-)?([0-9a-f]{12}).*/\3/p')
echo "branch=$BRANCH commit=$COMMIT"
```

```
branch=main commit=2cc3f14701c9
```

If either one is empty, your kernel was not built from git with the usual version string
(for example a kernel you built yourself from an archive). Use the source you built it from,
or use way B below.

**Way A, git (recommended):** clone that branch without file history (fast and small), then
check out the exact commit:

```sh
mkdir -p $HOME/src
git clone --filter=blob:none --single-branch -b "$BRANCH" https://git.FreeBSD.org/src.git "$SRC"
git -C "$SRC" checkout "$COMMIT"
```

**Way B, src.txz:** for a FreeBSD **release** (for example 15.0-RELEASE), the release's
`src.txz` is the source of its kernel as shipped. It does not include later security
patches (`-p1`, `-p2` ...); if `freebsd-version -k` shows a `-p` level, use way A with the
`releng/` branch instead.

```sh
mkdir -p $HOME/src/txz
fetch -o $HOME/src.txz https://download.freebsd.org/releases/arm64/aarch64/15.0-RELEASE/src.txz
tar -xf $HOME/src.txz -C $HOME/src/txz        # it unpacks as usr/src/...
SRC=$HOME/src/txz/usr/src
ls "$SRC/sys/conf/newvers.sh"
```

With way B there is no git: the checks below use `param.h` only, and to take the patches
out later you use `apply.sh -R` (step 8).

For a 16.0-CURRENT snapshot, the `src.txz` next to the snapshot changes every week, so it
rarely matches the snapshot you installed; use way A.

**Check the tree:** the commit and the version must match what `uname` said.

```sh
git -C "$SRC" rev-parse --short=12 HEAD          # way A: must print the same as $COMMIT
grep '^#define[[:space:]]*__FreeBSD_version' "$SRC/sys/sys/param.h"   # must show uname -K
```

```
2cc3f14701c9
#define __FreeBSD_version 1600031
```

### 3. Apply the patches, in series order

Dry run first. `patch --dry-run` changes nothing; every patch must report each file with no
`failed` and no `fuzz` line:

```sh
cd "$SRC"
for p in $(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$KP/series"); do
	echo "== $p"
	patch -p1 -F 0 --dry-run -N < "$KP/$p" || echo "!! $p DOES NOT APPLY"
done
```

You should see only `Hunk #n succeeded` lines (an `offset N lines` note is fine) and no
`!!` line. If any patch fails, stop here and read [Troubleshooting](#troubleshooting).

Then apply them for real, the same way without `--dry-run`. `-V none` keeps `patch` from
leaving `.orig` copies:

```sh
cd "$SRC"
for p in $(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$KP/series"); do
	echo "== $p"
	patch -p1 -F 0 -N -V none < "$KP/$p" || { echo "!! $p FAILED"; break; }
done
```

Check that nothing was rejected and see what changed:

```sh
find "$SRC" -name '*.rej'          # must print nothing
git -C "$SRC" status --short       # way A only
```

```
 M etc/mtree/BSD.tests.dist
 M sys/arm64/arm64/trap.c
 M sys/compat/linuxkpi/common/include/linux/io-mapping.h
 M sys/compat/linuxkpi/common/include/linux/io.h
 M sys/compat/linuxkpi/common/include/linux/page.h
 M sys/compat/linuxkpi/common/src/linux_page.c
 M sys/conf/files.arm64
 M sys/dev/pci/pci_host_generic.c
 M sys/dev/pci/pci_host_generic.h
 M sys/dev/pci/pci_host_generic_acpi.c
 M tests/sys/Makefile
?? sys/arm64/arm64/align_fixup.c
?? sys/dev/pci/pci_host_generic_quirks.h
?? tests/sys/pci/
```

To apply only some of them (for example only patch 1 on a machine that is not an Altra),
run the `patch` line for just that file. The [helper script](#with-the-helper-script) does
step 3 (the dry run and the apply) in one command.

### 4. Build the kernel

As a normal user. `/usr/bin` goes first in `PATH`: with GNU `ld` from `/usr/local/bin`
(binutils) first, the kernel can link but its modules will not load.

```sh
cd "$SRC"
mkdir -p "$OBJ"
env PATH=/sbin:/bin:/usr/sbin:/usr/bin MAKEOBJDIRPREFIX="$OBJ" \
    make -j"$(sysctl -n hw.ncpu)" buildkernel KERNCONF=GENERIC
```

It ends with lines like these (the time depends on the machine; 168 seconds with 32 jobs on
a 128-core Altra):

```
--------------------------------------------------------------
>>> Kernel build for GENERIC completed on Sun Nov 22 07:05:18 UTC 2026
--------------------------------------------------------------
>>> Kernel(s)  GENERIC built in 168 seconds, ncpu: 128, make -j32
--------------------------------------------------------------
```

If you built a custom kernel configuration before, use its name instead of `GENERIC`.

### 5. Install it as `kernel.patched`, next to the stock kernel

`INSTKERNNAME` puts the new kernel and its modules in `/boot/kernel.patched`. `/boot/kernel`
stays as it is, so you can always boot the stock kernel again.

```sh
cd "$SRC"
doas env PATH=/sbin:/bin:/usr/sbin:/usr/bin MAKEOBJDIRPREFIX="$OBJ" \
    make installkernel KERNCONF=GENERIC INSTKERNNAME=kernel.patched
ls /boot/kernel.patched/kernel /boot/kernel.patched/linuxkpi.ko
```

```
/boot/kernel.patched/kernel	/boot/kernel.patched/linuxkpi.ko
```

### 6. Test it once with nextboot

`nextboot -k` boots `kernel.patched` for the **next boot only**. If it panics, hangs or does
not work, the boot after that is your stock kernel again. The two `-e` settings make a panic
reboot after 5 seconds instead of waiting in the debugger (16.0-CURRENT's GENERIC has the
debugger compiled in).

```sh
doas nextboot -k kernel.patched -e debug.debugger_on_panic=0 -e kern.panic_reboot_wait_time=5
doas shutdown -r now
```

If the machine hangs without a panic, power it off and on; it then comes up on the stock
kernel. For patch 1 to take effect, the GPU modules must also be rebuilt against the
patched tree; see
[Rebuild the GPU modules](#rebuild-the-gpu-modules-against-the-patched-tree).

### 7. Check after the boot

The reboot started a new shell, so set the paths of the walk-through again first:

```sh
SRC=$HOME/src/freebsd OBJ=$HOME/obj KP=$HOME/nvidia-gb10-freebsd/kernel-patches
```

The patched kernel is running:

```sh
sysctl -n kern.bootfile
uname -v
```

```
/boot/kernel.patched/kernel
FreeBSD 16.0-CURRENT #0 main-n283001-2cc3f14701c9-dirty: Sun Nov 22 07:03:20 UTC 2026     you@host:/home/you/obj/home/you/src/freebsd/arm64.aarch64/sys/GENERIC
```

`-dirty` means "built from a tree with local changes": your patches.

On an **Ampere Altra**:

```sh
dmesg | grep -e 'alignment-fault fixup' -e '32-bit config space'
sysctl machdep.kern_align_fixup machdep.kern_align_fixup_active machdep.kern_align_fixups
```

```
arm64: kernel alignment-fault fixup enabled (Ampere Altra)
pcib0: 32-bit config space reads only
pcib1: 32-bit config space reads only
...
machdep.kern_align_fixup: -1
machdep.kern_align_fixup_active: 1
machdep.kern_align_fixups: 0
```

There is one `32-bit config space reads only` line per PCIe host bridge.
`machdep.kern_align_fixup` is the setting (`-1` is "automatic"); `_active` is what is in
effect. `machdep.kern_align_fixups` counts the accesses the fixup has emulated; it grows while
a GPU driver works.

Patch 2 is in LinuxKPI. The arm64 GENERIC kernel has LinuxKPI built in (`options COMPAT_LINUXKPI`, from `std.azure`), so its line and sysctls are there from boot; with a kernel that does not, they appear when `linuxkpi.ko` loads with the first drm-kmod driver:

```sh
dmesg | grep 'erratum 82288'
sysctl compat.linuxkpi.altra_82288 compat.linuxkpi.altra_82288_active
```

```
linuxkpi: Ampere Altra erratum 82288: PCIe write-combining mapped as Device (mode 1)
compat.linuxkpi.altra_82288: -1
compat.linuxkpi.altra_82288_active: 1
```

On **other arm64 machines** none of these lines appear, and both `_active` sysctls are `0`.
Patch 1 has no switch to read; see [patch 1](#patch-1-linuxkpi-write-combining-on-arm64) for
how to check it.

Then load your GPU driver as you normally do and check that it works.

### 8. Make it the default, and how to go back

When you are happy with it, boot `kernel.patched` every time:

```sh
doas sysrc -f /boot/loader.conf kernel="kernel.patched"
```

```
kernel:  -> kernel.patched
```

**To go back to the stock kernel** for one boot: at the loader menu choose "Kernel" until it
shows `kernel`, or escape to the loader prompt and type `boot kernel`. To go back for good:

```sh
doas sysrc -f /boot/loader.conf -x kernel
doas shutdown -r now
```

After that boot, and only when the stock kernel is running (`sysctl -n kern.bootfile` shows
`/boot/kernel/kernel`), you can delete the patched one:

```sh
doas rm -rf /boot/kernel.patched
```

To take the patches back out of the source tree:

```sh
sh "$KP/apply.sh" -R "${SRC:?set SRC first}"
```

or, for a git tree, throw away every local change in it (the `${SRC:?}` stops the command
when `SRC` is not set, instead of running it in whatever repository you are in):

```sh
git -C "${SRC:?set SRC first}" checkout . && git -C "${SRC:?}" clean -fd
```

### 9. Redo it after every FreeBSD update

`kernel.patched` is built from one FreeBSD version. Before updating, select the stock kernel
and reboot, or update while the stock kernel is already running:

```sh
doas sysrc -f /boot/loader.conf -x kernel
```

After the update, repeat steps 2 to 8 for the new version and
[rebuild the GPU modules](#rebuild-the-gpu-modules-against-the-patched-tree).

## With the helper script

[`apply.sh`](apply.sh) does step 3 for you. It reads [`series`](series), dry-runs every
patch first and stops before changing anything if any patch would be rejected or would only
fit with fuzz. It writes only inside the tree you give it, never `.orig` or `.rej` files, and
does not need root. A patch that is already applied is reported and skipped, so running it
twice is harmless.

```sh
sh "$KP/apply.sh" -n "$SRC"      # dry run only: changes nothing
sh "$KP/apply.sh" "$SRC"         # apply all, in series order
sh "$KP/apply.sh" "$SRC" 0001-linuxkpi-arm64-write-combining.diff   # only some
sh "$KP/apply.sh" -R "$SRC"      # take them out again, last one first
```

A good run:

```
apply.sh: tree /home/you/src/freebsd (__FreeBSD_version 1600031)
apply.sh: 0001-linuxkpi-arm64-write-combining.diff   dry run ok
apply.sh: 0002-linuxkpi-altra-erratum-82288.diff     dry run ok
apply.sh: 0003-arm64-kernel-alignment-fixup.diff     dry run ok
apply.sh: 0004-pci-host-generic-altra-ecam.diff      dry run ok
apply.sh: 0001-linuxkpi-arm64-write-combining.diff   applied
apply.sh: 0002-linuxkpi-altra-erratum-82288.diff     applied
apply.sh: 0003-arm64-kernel-alignment-fixup.diff     applied
apply.sh: 0004-pci-host-generic-altra-ecam.diff      applied
apply.sh: done
```

A run that stops (here because the tree was already edited by hand):

```
apply.sh: 0001-linuxkpi-arm64-write-combining.diff   DOES NOT APPLY
    Patching file sys/compat/linuxkpi/common/include/linux/io.h using Plan A...
    Hunk #2 failed at 452.
    1 out of 2 hunks failed while patching sys/compat/linuxkpi/common/include/linux/io.h
apply.sh: stopped before changing anything in /home/you/src/freebsd.
```

It warns, but goes on, when the tree's `__FreeBSD_version` is not the running kernel's
(`uname -K`). Exit status: 0 done or nothing to do, 1 a patch does not apply or the tree is
unusable, 2 a usage error. `sh apply.sh -h` prints the usage. Then continue with
[step 4](#4-build-the-kernel).

## The patches in detail

### Patch 1: LinuxKPI write-combining on arm64

File: `0001-linuxkpi-arm64-write-combining.diff`. Changes
`sys/compat/linuxkpi/common/include/linux/io.h`, `io-mapping.h` and `page.h`.

**The problem.** drm-kmod drivers are Linux drivers that run on FreeBSD's LinuxKPI. They map
GPU memory (video memory apertures, framebuffers, ring buffers) with `ioremap_wc()`,
`io_mapping` and `pgprot_writecombine()`, which mean "uncached, writes may be combined". On
arm64 FreeBSD's `VM_MEMATTR_WRITE_COMBINING` is an alias of **write-through, which is a
cacheable type**, and LinuxKPI used it for all three. So GPU memory was mapped cacheable: CPU
reads can return stale cache lines instead of what the GPU wrote, and a cacheable access to
PCIe memory is not something every arm64 platform's interconnect accepts.

Also, `memcpy_toio()`, `memcpy_fromio()` and `memset_io()` were plain `memcpy()` and
`memset()`. The arm64 versions of those use unaligned paired loads and stores and the `DC ZVA`
cache-zeroing instruction. On Device memory (what `ioremap()` gives) an unaligned access and
any `DC ZVA` raise an alignment fault, and in the kernel that is a panic.

**What the patch does.** On arm64 only: `ioremap_wc()`, `io_mapping` and
`pgprot_writecombine()` use Normal non-cacheable (`VM_MEMATTR_UNCACHEABLE`, arm64's real
write-combining type); and the three MMIO copy functions `memcpy_toio()`, `memcpy_fromio()`
and `memset_io()` become loops that make only naturally aligned accesses (bytes up to an
8-byte boundary, then 8-byte words, then bytes). `pgprot_noncached()` stays as upstream
(Normal non-cacheable): Device on a RAM page would also change its direct-map alias.

**Symptoms without it** (arm64, a drm-kmod driver): wrong or stale pixels, garbage in parts
of the screen or a frozen-looking console after the driver takes over; the driver failing
its ring or firmware tests and hanging the GPU; a panic `Misaligned access from kernel
space!` when a driver copies to or clears device memory; on some platforms a synchronous
external abort, which is a panic in the kernel and `SIGBUS` in a program that mapped the
memory (a Vulkan or OpenGL program).

**Who needs it:** every arm64 machine that uses a drm-kmod driver.

| Driver | Needs patch 1? |
|---|---|
| amdgpu (drm-kmod) | yes |
| nvidia-drm (this repository) | yes: it maps video memory with `pgprot_writecombine()` and `ioremap_wc()` |
| other drm-kmod drivers, drm.ko, ttm | yes |
| nvidia.ko, nvidia-modeset.ko | no: they do not use LinuxKPI and choose their own memory types (see the main README, "Memory attributes on arm64") |
| amd64 and other architectures | no: the change is only compiled on arm64 |

**Important:** patch 1 changes header files. A module only gets the fix when it is
**compiled against the patched tree**. The kernel alone is not enough: rebuild drm-kmod and
nvidia-drm as described in [Rebuild the GPU modules](#rebuild-the-gpu-modules-against-the-patched-tree).

**Tunables and sysctls:** none.

**How to check it is active:** there is no switch at run time. Check the tree your modules
were built from; the dry run reports the patch as already there:

```sh
sh "$KP/apply.sh" -n "$SRC" 0001-linuxkpi-arm64-write-combining.diff
```

```
apply.sh: 0001-linuxkpi-arm64-write-combining.diff   already applied, skipped
```

and that the modules were built after it (`ls -l /boot/modules/amdgpu.ko` or wherever your
drm modules are, against the time you applied the patch).

### Patch 2: LinuxKPI, Ampere Altra erratum 82288

File: `0002-linuxkpi-altra-erratum-82288.diff`. Changes
`sys/compat/linuxkpi/common/src/linux_page.c` (LinuxKPI: built into the arm64 GENERIC kernel, and also built as `linuxkpi.ko`).

**The problem.** The Ampere Altra's PCIe root complex has an erratum (Ampere erratum 82288,
also listed as PCIE_65): CPU writes that carry a non-contiguous set of byte enables can reach
the device at the wrong address. Normal memory mappings (write-combining) produce such writes
when the CPU merges stores. The safe type for PCIe memory on this chip is Device-nGnRE.

**What the patch does.** In `_ioremap_attr()` (behind `ioremap_wc()` and friends) and in the
LinuxKPI page-fault handler (behind `mmap` of GPU memory by programs), a write-combining or
uncached request for an address in the Altra's PCIe windows becomes Device-nGnRE, as the mode
below says; on the Altra a cacheable write-through request there becomes Normal
non-cacheable, so a module built without patch 1 does not get a cacheable mapping there.

Whether the machine is an Altra (ACPI MCFG: OEMID `Ampere`, OEM Table ID starting `Altra`) is
decided **once, when LinuxKPI initialises** (at boot when LinuxKPI is built into the kernel, as in arm64 GENERIC; when `linuxkpi.ko` loads otherwise), and kept. The mapping
paths only read that answer, so no table lookup ever happens inside a page fault. On a
machine that is not an Altra the patch changes no mapping at all, whatever the setting.

**Symptoms without it** (Altra, a drm-kmod driver): rare, data-dependent corruption of what is
written to the GPU: wrong pixels, corrupted command buffers, GPU hangs or resets that come and
go, a driver that works for a while and then hangs.

**Who needs it:** Ampere Altra and Altra Max with amdgpu, nvidia-drm or another drm-kmod
driver. nvidia.ko does not use LinuxKPI; it applies the same rule to its own mappings
(`hw.nvidia.altra_device_wc_active`, see the main README). Not needed and inert on other
machines.

**Tunable and sysctls:**

| Name | Type | Default | Values |
|---|---|---|---|
| `compat.linuxkpi.altra_82288` | loader tunable and read-write sysctl (int) | `-1` | the setting: `-1` automatic (mode `1` on an Altra); `0` off; `1` kernel mappings (`ioremap_wc` and friends) use Device; `2` kernel mappings and program (`mmap`) mappings use Device. Ignored on machines that are not an Altra |
| `compat.linuxkpi.altra_82288_active` | read-only sysctl (int) | | the mode in effect: `0` (off, or not an Altra), `1` or `2` |

Mode `1` is the default an Altra gets. Mode `2` is stricter (also programs' mappings of GPU
memory) and slower for programs that write to video memory; use it only for testing. With
mode `2`, a program that makes an unaligned access or a large memset into GPU memory it
mapped crashes with `SIGBUS` (`BUS_ADRALN`). A `read(2)` or `write(2)` whose user buffer is
such a mapping at an unaligned address can fail with `EFAULT`. Patch 3's fixup covers
kernel-mode faults only, so mode `2` is not a fix for corruption. For testing, set it before
LinuxKPI loads, in `/boot/loader.conf`:

```sh
doas sysrc -f /boot/loader.conf compat.linuxkpi.altra_82288="2"
```

Changing it with `sysctl` at run time affects only mappings made after the change; writing
`-1` goes back to the automatic choice.

**How to check it is active:** after boot (arm64 GENERIC), or once `linuxkpi.ko` has loaded,

```sh
dmesg | grep 'erratum 82288'
sysctl compat.linuxkpi.altra_82288 compat.linuxkpi.altra_82288_active
```

```
linuxkpi: Ampere Altra erratum 82288: PCIe write-combining mapped as Device (mode 1)
compat.linuxkpi.altra_82288: -1
compat.linuxkpi.altra_82288_active: 1
```

The `dmesg` line is printed once, when LinuxKPI initialises, and shows the mode it found then
(with `compat.linuxkpi.altra_82288=0` it says `workaround off`). `unknown oid` means
the kernel has no LinuxKPI built in and `linuxkpi.ko` is not loaded (`kldstat | grep linuxkpi`), or the running kernel is not the
patched one.

On a kernel built without ACPI support (`DEV_ACPI`), the line is instead:

```
linuxkpi: built without DEV_ACPI: Ampere Altra erratum 82288 detection unavailable
```

This means the patch cannot detect an Altra. Build LinuxKPI with the kernel using
`buildkernel`, so ACPI support is included.

### Patch 3: kernel alignment-fault fixup on arm64

File: `0003-arm64-kernel-alignment-fixup.diff`. Adds `sys/arm64/arm64/align_fixup.c`, its prototype in `sys/arm64/include/md_var.h`, a hook in
`sys/arm64/arm64/trap.c`, and the line in `sys/conf/files.arm64` that builds it.

**The problem.** On Device memory every unaligned load or store, and every `DC ZVA`, takes an
alignment fault. In the kernel the stock handler panics. Once write-combining GPU memory is
mapped as Device (patch 2, and nvidia.ko on the Altra), ordinary driver code that was written
for Normal memory, such as `memcpy()`, structure copies and compiler-generated paired
loads and stores, hits this.

**What the patch does.** Before panicking, the alignment-fault handler for kernel mode decodes
the faulting instruction. If it is a general-purpose register load or store (LDR/STR in all
addressing forms and sizes, sign-extending loads, LDP/STP/LDNP/STNP/LDPSW, PRFM, which is
skipped) or `DC ZVA`, it performs the access as naturally aligned pieces, so the PCIe side sees
contiguous byte enables, writes back the registers and resumes after the instruction.
Anything else (vector registers, atomics, exclusive loads and stores) panics as before.
Faults in programs are not touched: a program still gets `SIGBUS` (`BUS_ADRALN`).

Whether the machine is an Altra is decided once at boot, **before any driver attaches**, from
the ACPI MCFG table, so GPU drivers preloaded by the loader (`nvidia_load="YES"`,
`amdgpu_load="YES"` in `loader.conf`) are covered as well as ones loaded later.

**Symptoms without it** (Altra, a GPU driver): a panic with

```
panic: Misaligned access from kernel space!
```

while the GPU driver loads, sets a display mode or runs the first program that uses the GPU,
with a backtrace inside amdgpu, nvidia or drm code.

**Who needs it:** Ampere Altra and Altra Max with any GPU driver: amdgpu and other drm-kmod
drivers, nvidia-drm, and nvidia.ko (which maps write-combining memory as Device on the Altra).
The emulator itself works on any arm64 machine, but other machines map GPU memory Normal
non-cacheable, which allows unaligned access, so it is off there.

**Tunable and sysctls:**

| Name | Type | Default | Values |
|---|---|---|---|
| `machdep.kern_align_fixup` | loader tunable and read-write sysctl (int) | `-1` | the setting: `-1` automatic (on when the ACPI MCFG says OEMID `Ampere` and an OEM Table ID starting `Altra`, off elsewhere); `0` off (stock behaviour: panic); `1` on. Writing `-1` at run time goes back to the automatic choice |
| `machdep.kern_align_fixup_active` | read-only sysctl (int) | | in effect: `1` on, `0` off |
| `machdep.kern_align_fixups` | read-only sysctl (unsigned long) | `0` | number of kernel accesses emulated since boot |

To force it on another machine, or off on an Altra (to debug which code makes the
misaligned access):

```sh
doas sysrc -f /boot/loader.conf machdep.kern_align_fixup="1"    # or "0"
```

**How to check it is active:**

```sh
dmesg | grep 'alignment-fault fixup'
sysctl machdep.kern_align_fixup machdep.kern_align_fixup_active machdep.kern_align_fixups
```

```
arm64: kernel alignment-fault fixup enabled (Ampere Altra)
machdep.kern_align_fixup: -1
machdep.kern_align_fixup_active: 1
machdep.kern_align_fixups: 4613
```

When the tunable turned it on, the line ends in `(machdep.kern_align_fixup)` instead. When
`machdep.kern_align_fixup=0` turns it off on an Altra, boot prints:

```
arm64: kernel alignment-fault fixup off on Ampere Altra (machdep.kern_align_fixup=0)
```

A count that grows while the GPU is in use is normal on an Altra. It costs one trap per
emulated access, so a very fast-growing count means a driver path that would be worth fixing
to use aligned accesses.

### Patch 4: Ampere Altra PCIe configuration reads (ECAM quirk)

File: `0004-pci-host-generic-altra-ecam.diff`. Changes `sys/dev/pci/pci_host_generic.c`,
`pci_host_generic.h`, `pci_host_generic_acpi.c`, adds `sys/dev/pci/pci_host_generic_quirks.h`
and a test, `tests/sys/pci/pci_host_generic_quirks_test.c` (with its `Makefile`, an entry in
`tests/sys/Makefile` and one in `etc/mtree/BSD.tests.dist`).

**The problem.** On the Altra, 8-bit and 16-bit reads of PCI configuration space can return
wrong data; only aligned 32-bit reads are reliable. FreeBSD reads the vendor, device, class
and many other registers with 8- and 16-bit reads.

**What the patch does.** For host bridges described by an ACPI MCFG with OEMID `Ampere`, OEM
Table ID `Altra` and OEM revision 1, every configuration read is made as an aligned 32-bit read
and the wanted bytes are taken out of it. Writes are not changed. The MCFG quirk table moves
into a small header of pure functions so that a userland test can check it; the existing
Marvell entries stay as they were.

**Symptoms without it** (Altra): PCIe devices that show the wrong vendor, device or class in
`pciconf -lv`, or do not show at all, typically the PCIe switch inside a GPU card (an AMD
Radeon's switch read as device 0, class 0), so the GPU behind it is never found and its driver
never attaches; drivers that fail to attach with odd errors because a capability list read
back wrong.

**Who needs it:** every Ampere Altra host with PCIe devices beyond the onboard ones, for
any driver (nvidia.ko, amdgpu, network and storage cards alike). Not needed and inert on
other machines.

**Tunables and sysctls:** none. It is chosen by the MCFG header alone.

**How to check it is active:**

```sh
dmesg | grep '32-bit config space'
pciconf -lv | grep -B1 -A3 -i -e vga -e display
```

```
pcib0: 32-bit config space reads only
...
```

and your GPU shows up in `pciconf -lv` with its real vendor and device.

**The test:** `tests/sys/pci/pci_host_generic_quirks_test` checks the byte extraction for
every offset of a 4 KiB configuration space, the Altra match (including that other Ampere
tables and other revisions do not match) and the unchanged Marvell entries. With a world
built from the patched tree it is installed and run with the other tests (`kyua test -k
/usr/tests/sys/pci/Kyuafile`). Without rebuilding world you can build and run it by hand:

```sh
cd "$SRC"
cc -I sys/dev/pci -I contrib/atf -o $HOME/pci_quirks_test \
    tests/sys/pci/pci_host_generic_quirks_test.c -lprivateatf-c
$HOME/pci_quirks_test -l | grep ident        # lists the 9 test cases
$HOME/pci_quirks_test quirks_ampere_altra    # passed
```

`libprivateatf-c` is part of the base system (`/usr/lib/libprivateatf-c.so`). The test
prints two warnings about running outside `kyua`; they are expected. Each case prints
`passed`.

## Rebuild the GPU modules against the patched tree

Patch 1 is in header files that every drm-kmod module is compiled with. A module built
against the stock tree keeps the stock behaviour even on the patched kernel. So after step 5,
rebuild the GPU modules with the patched tree as their kernel source:

- **drm-kmod from ports** (amdgpu and the other drm-kmod drivers): build the port with
  `SRC_BASE` pointing at the patched tree, for example

  ```sh
  cd /usr/ports/graphics/drm-612-kmod     # or the drm-kmod version you use
  make SRC_BASE="$SRC" clean build
  doas make SRC_BASE="$SRC" deinstall reinstall
  ```

  The package from `pkg` was built against the stock tree and does not have the fix.
- **nvidia-drm from this repository:** build with `SYSDIR="$SRC/sys"` and the drm-kmod tree
  you built `drm.ko` from (`DRMKMODDIR=`); see the main README.
- **nvidia.ko** does not need a rebuild for these patches.

Patches 2, 3 and 4 are in the kernel (and in `linuxkpi.ko`), which `installkernel` already put in
`/boot/kernel.patched`; they need no module rebuild.

## FreeBSD updates (freebsd-update and pkgbase)

The patches live in your source tree and in `/boot/kernel.patched`, nowhere else. Updates do
not know about them:

- **freebsd-update** (releases) installs the kernel into the directory of the **running**
  kernel. If you run `kernel.patched` when you update, the patched files are replaced by stock
  ones and the patches are gone. If you run the stock kernel, `kernel.patched` is left as it was
  and is now **older** than the rest of the system.
- **pkgbase** (`pkg upgrade` of the `FreeBSD-*` packages) updates `/boot/kernel` and leaves
  `/boot/kernel.patched` alone, which is then older than the rest of the system.
- **A new 16.0-CURRENT snapshot** or a `buildworld`/`installworld` of a newer tree: the same.

A kernel that is older than the world and the modules can fail to load modules (`kldload:
... Exec format error` or `KLD ... depends on kernel - not available or version mismatch`) or
misbehave. So after **every** update:

1. Boot the stock kernel (`doas sysrc -f /boot/loader.conf -x kernel`, reboot), or update while
   running it.
2. Update as usual.
3. Get the source of the new version (step 2), apply the patches (step 3), build and install
   `kernel.patched` again (steps 4 and 5), rebuild the GPU modules, test with nextboot (steps 6
   and 7), then make it the default again (step 8).

## Tested on

| FreeBSD | Commit | Applies | GENERIC arm64 buildkernel |
|---|---|---|---|
| 16.0-CURRENT (main), 2026-11-22 | `2cc3f14701c9` | yes, no fuzz | yes, no warnings in the patched files |
| 15-STABLE (stable/15), 2026-11-20 | `55b89b7b529f` | yes, no fuzz | yes, no warnings in the patched files |
| 16.0-CURRENT (main), 2026-11 | `c502df9eb193` | yes (the base they were written on) | yes; this kernel is booted on an Ampere Altra host with an AMD Radeon RX 7600 (amdgpu) and an NVIDIA RTX 5060 Ti (nvidia.ko) |

The ECAM quirk test (`pci_host_generic_quirks_test`) passed all 9 cases built from both the
main and the stable/15 trees. A release branch (`releng/15.0`) was not checked separately;
it is a branch of stable/15, and `apply.sh -n` tells you in a second whether the patches fit.
The alignment emulator of patch 3 has no unit test yet; it is exercised on hardware, where
`machdep.kern_align_fixups` counts the emulated accesses.
The `series` file records the same commits. None of this is part of FreeBSD itself and none of
it has been submitted there.

## Troubleshooting

**A patch does not apply (`Hunk #n failed`, `DOES NOT APPLY`).**

- The tree is not clean: `git -C "${SRC:?}" status` shows changes you made earlier, or an
  earlier attempt half applied a patch. Take the series out with
  `sh "$KP/apply.sh" -R "${SRC:?}"`, or reset a git tree with
  `git -C "${SRC:?}" checkout . && git -C "${SRC:?}" clean -fd` (this throws away all local
  changes), and start step 3 again.
- The tree is a FreeBSD version the patches were not checked on (see [Tested on](#tested-on)),
  for example a much older one. Check `$SRC/sys/sys/param.h` against `uname -K`. If it is the
  right version and still fails, the patch needs refreshing for it; [report it with the output
  of `apply.sh -n`](#reporting-problems).
- Never apply with fuzz (`patch -F 3` or a plain `patch` that reports `with fuzz`): in kernel
  code a hunk in the wrong place builds and breaks at run time.

**`already applied, skipped` for a patch you did not apply.** The tree already contains that
change, for example a tree from a vendor that carries it. That is fine.

**The build fails.**

- `ld: error: ... incompatible` or modules that build but will not load: GNU `ld` from
  `/usr/local/bin` was used. Use the `env PATH=/sbin:/bin:/usr/sbin:/usr/bin` of step 4.
- `make: don't know how to make ...` or a compiler that is too old for the tree: the tree is
  much newer than your system. Use the tree that matches your kernel (step 2), or build the
  toolchain first: `make -j"$(sysctl -n hw.ncpu)" kernel-toolchain`, then step 4 again.
- Out of disk space: the build needs about 3 GB under `$OBJ`.

**`installkernel` says permission denied.** It has to run as root (`doas` or `sudo`). Keep the
same `MAKEOBJDIRPREFIX` as for the build, or it will look for the build in the wrong place and
say `no kernel built`.

**The machine does not come back after the nextboot.** Power it off and on; the next boot is
the stock kernel. With a serial console or the BMC console you can watch the boot and read the
panic message. A panic in a GPU driver right after boot can also be the driver: boot the stock
kernel, disable loading the GPU driver (`kld_list` in `/etc/rc.conf`), then test the patched
kernel again and load the driver by hand with `doas kldload`.

**`sysctl: unknown oid 'machdep.kern_align_fixup'`.** The running kernel is not the patched one
(`sysctl -n kern.bootfile`), or patch 3 was not applied before the build.

**`sysctl: unknown oid 'compat.linuxkpi.altra_82288'`.** The running kernel is not the patched one (`sysctl -n kern.bootfile`), or it has no LinuxKPI built in and `linuxkpi.ko` is not loaded yet (it
loads with the first drm-kmod driver), or the kernel and its modules did not come from the
patched build (when LinuxKPI is a module, `kldstat -v | grep linuxkpi` must show `/boot/kernel.patched/linuxkpi.ko`).

**An `_active` sysctl reads `0` on an Altra.** Check `dmesg`.
`arm64: kernel alignment-fault fixup off on Ampere Altra (machdep.kern_align_fixup=0)` means
patch 3 was disabled with `machdep.kern_align_fixup=0`.
`linuxkpi: Ampere Altra erratum 82288: workaround off (compat.linuxkpi.altra_82288=0)` means
patch 2 was disabled with `compat.linuxkpi.altra_82288=0`.
`arm64: built without DEV_ACPI: Ampere Altra detection unavailable; set machdep.kern_align_fixup=1 to force the fixup on` and
`linuxkpi: built without DEV_ACPI: Ampere Altra erratum 82288 detection unavailable` mean the
kernel has no ACPI support, so patches 2 and 3 cannot detect the Altra. The kernel
configuration needs `device acpi` (GENERIC has it). Without it, force patch 3 on with
`machdep.kern_align_fixup=1`.

**Still `Misaligned access from kernel space!` on an Altra.** Check `machdep.kern_align_fixup_active`
is `1`. The fixup handles general-purpose register loads and stores only; a fault on a vector
(SIMD) or atomic instruction still panics. [Report the panic message with its backtrace and the
`far` and `esr` lines printed before it](#reporting-problems).

**GPU still shows wrong pixels on arm64 with patch 1.** The drm-kmod modules were not rebuilt
against the patched tree; see [Rebuild the GPU modules](#rebuild-the-gpu-modules-against-the-patched-tree).

**Modules fail to load after a FreeBSD update.** `kernel.patched` is older than the system; see
[FreeBSD updates](#freebsd-updates-freebsd-update-and-pkgbase).

## Reporting problems

Open an issue at <https://github.com/cloudbsdorg/nvidia-gb10-freebsd/issues> with the output
named in the relevant troubleshooting entry above.

## Reference

- [`kernel-patches.7`](kernel-patches.7): manual page with the tunables, sysctls and
  `apply.sh`. Read it with `man ./kernel-patches.7` from this directory.
- [`series`](series): the patch order and the FreeBSD commits each was checked against.
- [`../tests/kernel_patches_test.sh`](../tests/kernel_patches_test.sh): checks the series, this
  README and the manual page against the patches, and tests `apply.sh` on a scratch tree; run
  by `make test`. `sh tests/kernel_patches_test.sh "$SRC"` also dry-runs the series against
  your tree.

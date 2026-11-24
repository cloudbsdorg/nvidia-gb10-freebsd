# NVIDIA driver for FreeBSD on arm64

NVIDIA ships a FreeBSD driver only for x86-64. This repository builds it for **arm64
(aarch64)**: NVIDIA's FreeBSD OS layer, patched for arm64, linked to NVIDIA's open GPU kernel
module core (open-gpu-kernel-modules, MIT) compiled for aarch64 instead of NVIDIA's prebuilt
x86-64 object. Driver version **580.178.04**.

NVIDIA's sources and binaries are not stored here. The scripts fetch them and check them
against the pins in [`SOURCES`](SOURCES) (a sha256 for the FreeBSD tarball, a tag and commit
for open-gpu-kernel-modules). This repository holds the build scripts, our patches to NVIDIA's
code (`patches/`, unified diffs, so they carry the changed lines and their context), a few
small source files of our own, and the tests.

## Install

Use this path on a stock **FreeBSD arm64** installation: 16.0-CURRENT or 15.1-RELEASE or
later. On a fresh system, run this one-time setup as root:

```sh
pkg install -y doas git
buser=$(logname 2>/dev/null)
case $buser in
''|root|*[!A-Za-z0-9_.-]*|[!A-Za-z0-9_]*)
    echo "no valid build user (logname gave '$buser'): edit the buser= line above to your account name, then run this block again" >&2
    false ;;
*)
    grep -F -x -q -- "permit $buser" /usr/local/etc/doas.conf 2>/dev/null || {
        [ -z "$(tail -c 1 /usr/local/etc/doas.conf 2>/dev/null)" ] || echo >> /usr/local/etc/doas.conf
        echo "permit $buser" >> /usr/local/etc/doas.conf
    } ;;
esac
```

`logname` is the user who opened the root shell with `su`, and that user gets the `permit`
line. The block never reads `buser` from the environment: it sets it itself. If root logged in
directly, `logname` names root or fails, and the block refuses (exit status 1) and writes
nothing; change its second line to `buser=alice`, with the name of the account that will run
the build, and run it again. A name must start with a letter, digit or underscore and contain
only letters, digits, `_`, `.` and `-`. The line is added only when it is missing (compared
literally), on a line of its own, so an existing `/usr/local/etc/doas.conf` keeps its other
rules. (`sudo`, if you set it up yourself, works as well.)

Then, as that user:

```sh
git clone https://github.com/cloudbsdorg/nvidia-gb10-freebsd.git
cd nvidia-gb10-freebsd
make install ACCEPT_NVIDIA_LICENSE=1
```

This install path has not yet been run end to end on a stock FreeBSD VM. Its pieces are
tested separately, so expect rough edges. Report them at
<https://github.com/cloudbsdorg/nvidia-gb10-freebsd/issues>.

That one command runs the preflight, installs the prerequisites, fetches and verifies the
sources, builds what is needed, and installs the result. It asks once before doing anything as
root; add `YES=1` to answer that confirmation non-interactively. A signal interrupts the
install, and a failed install rolls back the files it changed.

NVIDIA's terms require the person installing the driver to accept its licence first.
`ACCEPT_NVIDIA_LICENSE=1` records acceptance of that licence; `ACCEPT_ALL_LICENSES=1` accepts
every licence encountered by the install. `YES=1` alone never accepts a licence. Without an
accept setting, a terminal shows the licence and asks; acceptance is tied to the licence's
sha256, so a changed licence must be accepted again. The blocker names the licence it
requires, by that name and hash, and the one the acceptance on record names: an acceptance
of another licence text is never carried over to the one now required.

Optional, for Linux binaries only (Steam, the Linux CUDA stack): after `make install` the two
Linux providers load by module name. They pull in the Linuxulator; native use does not need them.
Run these lines as root, with the root tool you set up above:

```sh
# as root:
kldload nvidia_linux
kldload nvidia_modeset_linux
sysrc linux_enable=YES           # the Linuxulator at boot, which rc.d/nvidia_linux needs
sysrc nvidia_linux_mode=AUTO     # rc.d/nvidia_linux loads the providers at boot when it is on
```

### Installed

A successful install exits 0. Example output (from `scripts/make.sh`, an excerpt: a
successful run also prints its prerequisite, build and copying progress):

```text
install: copying done
install: installed
```

A live install, without a DESTDIR, also lists its next steps, one command per line. Example
output (from `scripts/make.sh`) for a user who has doas; yours names the root tool you have:
`sudo`, `su root -c`, or no prefix as root. With no root tool at all the commands are
printed bare, and the line above them says to ask an administrator to run them as root, or
to open a root shell on the console and run them there.

```text
next: doas kenv hw.nvidia.registry.EnableGpuFirmware=1
next: doas kldload nvidia-drm
next: kldstat
next: nvrm-info --json
To load the driver at boot instead of the firmware setting and the module load, run make configure YES=1 once.
```

A staged install, with a DESTDIR, has no next steps: the files are only staged, so nothing
was loaded and there is nothing to run on this system. Its summary only says where the files
are. Do not run the load commands below on a staging system: they load a driver that system
does not have.

The summary lists every installed file and mode. Kernel modules go into `/boot/modules`;
the devd and rc.d configuration, `nvrm-info`, libnvrm, headers, schema, manual pages and
licences go under `/usr/local`. For a live install, load the driver now: first set the
firmware setting as root (with doas or sudo, whichever you have),
`kenv hw.nvidia.registry.EnableGpuFirmware=1`, then run the `kldload` line exactly as
`install` printed it. The root tool in that line is the one you have, so copy that line;
with no root tool at all, ask an administrator to run those two lines as root, or open a
root shell on the console and run them there. Or configure loading at boot with
`make configure`, described
below: it sets the same firmware value in `/boot/loader.conf` and makes the devd rule load
`nvidia-drm` at boot, so it replaces the firmware setting and the module load above. Then
check it without assuming a device number:

```sh
kldstat
dmesg | grep -i nvidia
nvrm-info --json
```

With a PREFIX of your own, the last line names the installed tool
(`'/opt/gb10/sbin/nvrm-info' --json`), because it is not on your PATH. The path is quoted,
so a prefix with a space in it is still one command.

### Blocked

A blocked install exits 1 and prints every blocker with its fix. It writes nothing to
`/boot/modules` or the install prefix. Sources already fetched stay in `./work`, and packages
the prerequisite step already installed stay installed. For example, withholding licence
acceptance produces this example output (from `scripts/make.sh`; BSD make's own failure
lines follow it):

```text
fix: make install ACCEPT_NVIDIA_LICENSE=1
install: blocked
```

The blocker itself is one long line: it says that NVIDIA's terms ask the person installing
the driver to read and accept the driver licence before install, that `YES=1` alone does not
accept it, and the two other ways to accept it: accept every licence this install meets
with `ACCEPT_ALL_LICENSES=1`, or run the same command on a terminal and answer the licence
question. The `fix:` line above is that same command with the accept setting added.

Follow the `fix:` line of the licence blocker: it is one command, ready to paste. The other
blockers name their fix in words, because each of them has more than one way to be fixed.
For the licence, the line names the command you ran, so under `make install` it says
`make install`, as above,
and it keeps the settings that change where the install goes, so a `DESTDIR` or a `PREFIX` you
gave is in the line too. The other ways to accept the licence are in the blocker's reason:
add `ACCEPT_ALL_LICENSES=1`, or run the command on a terminal and answer the licence
question. `make preflight` shows the same checks without installing, with `make install-prereqs`
in its fix. For a missing kernel change, see [`kernel-patches/README.md`](kernel-patches/README.md).

For machines, `JSON=1` makes preflight or install print one JSON object on stdout; `JSONL=1`
streams install progress objects followed by the summary and wins when both are set. When a
run fails, BSD make's own error lines are mixed in, so a machine should call the
driver directly: `sh scripts/make.sh preflight --json`, or `sh scripts/make.sh install` with
the environment variable `MK_JSON` set to 1 (the driver reads its settings from `MK_*`
variables, listed in the header of `scripts/make.sh`), and read the object only.

The prerequisite phase does all of this without separate manual steps:

- installs the packages the build needs with `pkg` (`git` and `gmake`; on a system
  where pkg is not set up yet it bootstraps pkg first). The compiler and linker are the base
  system's `cc` and `ld.lld`; `/usr/bin` comes first on `PATH`, so a GNU `ld` from ports is never
  used, and the build refuses a module that LLD did not link.
- fetches NVIDIA's FreeBSD driver tarball and `open-gpu-kernel-modules` 580.178.04, checked
  against the pins in `SOURCES`. The GSP firmware comes from that tarball; it is not shipped
  in this repository (its licence limits it to NVIDIA hardware), it is fetched on your machine.
- fetches the FreeBSD source of the kernel you are running into `./work/src` (16.0-CURRENT
  and 15.1-RELEASE or later): for a RELEASE, that release's `src.txz`, checked against its `MANIFEST`; for a CURRENT, STABLE, BETA or RC
  kernel, the exact git commit `uname -v` names (`main-n291235-611046b15dbb`), from
  git.freebsd.org. A stock install usually has no `/usr/src`; a matching `/usr/src` is used
  when there is one. A kernel you built from your own tree names no commit: then set
  `SYSDIR=/path/to/that/tree/sys`.
- fetches drm-kmod at the tag pinned in `SOURCES` for your kernel (drm_v6.12.110_1 for
  16.0-CURRENT and 15.1). FreeBSD's drm-kmod packages are amd64-only, so on arm64 `make build`
  builds `drm.ko` and `dmabuf.ko` from that tree and `make install` installs them, unless a
  `drm.ko` from somewhere else is already in `/boot/modules` (then nvidia-drm is built against
  `DRMKMODDIR=`, which must be that drm.ko's source).

What `make install` writes (listed with mode, owner and sha256 in
`/var/db/nvidia-gb10-freebsd/installed.manifest`; it never replaces a file it did not write,
or one that changed since it wrote it):

- `/boot/modules`: `nvidia_gsp_ga10x_fw.ko` (the GSP firmware), `nvidia.ko`,
  `nvidia-modeset.ko`, `nvidia-drm.ko`, `nvidia_linux.ko`, `nvidia_modeset_linux.ko`, and
  `drm.ko`, `dmabuf.ko`; then `kldxref /boot/modules`, so the stock loader and `kldload` find
  them and their dependencies by name.
- under `/usr/local`: `etc/rc.d/nvidia_linux`, `etc/devd/nvidia_gb10.conf`, the manual pages
  nvidia(4), nvidia_drm_render(4), nvidia_linux(4), nvrm(3), nvrm(7), nvrm-info(8), `lib/libnvrm`,
  `include/nvrm/nvrm.h`, `sbin/nvrm-info` and its JSON schema, and the licences in
  `share/licenses/nvidia-gb10-freebsd`.

`make configure` shows the change, backs up each file next to itself (`.bak-<UTC time>`), and
asks (`YES=1` does not ask). To apply the boot-loading configuration:

```sh
make configure YES=1
```

It changes:

- `/boot/loader.conf`: `hw.nvidia.registry.EnableGpuFirmware="1"` (the open RM core runs the
  GPU through its GSP firmware);
- `/etc/rc.conf`: `nvidia_gb10_autoload="YES"`: the installed devd rule then runs
  `kldload nvidia-drm` when vgapci(4) attaches to an NVIDIA display device; nvidia-drm pulls in
  nvidia-modeset, nvidia, drm and dmabuf, and nvidia loads its firmware module.

Without `make configure`, load by hand as root (doas or sudo): `kenv
hw.nvidia.registry.EnableGpuFirmware=1`, then `kldload nvidia-drm`.

`make deinstall YES=1` removes every file `make install` wrote and the directories it created,
and takes out what `make configure` set (restoring the earlier values and removing the
backups). A file changed since install is kept, listed, and deinstall exits 1. It refuses
while a module is loaded.

Kernel changes: `make install` never patches or rebuilds your kernel. `make preflight` reports
whether the running kernel has the changes in `kernel-patches/` (see
`kernel-patches/README.md`): the LinuxKPI arm64 write-combining change
(`compat.linuxkpi.altra_82288`), needed on any arm64 for drm-kmod write-combining mappings, and,
on an Ampere Altra only (found by its ACPI MCFG table), the PCIe ECAM quirk and the alignment
fixup (`machdep.kern_align_fixup`). They are reported as `warn`: the build and install work
without them.

The default work root is the `work/` directory of the checkout; `WORK=` (or `GB10_WORK` for
the individual scripts) overrides it. `WORK=`, `PREFIX=`, `DESTDIR=`, `SYSDIR=`, `BSDSRCTOP=` and `DRMKMODDIR=` override the
defaults. `make help` lists every target and switch.

Developers who need the individual build and test-load commands should use
[`docs/MANUAL-BUILD.md`](docs/MANUAL-BUILD.md); they are not a second installation path.

### What works today and what does not

- KMS and Xorg modesetting work, with software rendering only.
- Native NVIDIA user space is limited to `nvrm-info` device enumeration through
  [libnvrm](#libnvrm-and-nvrm-info). It passes against a simulated device but is untested on
  hardware. Native NVK and CUDA have not reached a workload.
- CUDA, Vulkan and `nvidia-smi` monitoring are Linux-only fallbacks through NVIDIA's Linux
  libraries and the Linuxulator. They need `nvidia_linux.ko` and `nvidia_modeset_linux.ko`;
  CUDA additionally needs `nvidia-uvm.ko` and Linuxulator changes that are not in a stock
  FreeBSD kernel. See [Linux dependencies](docs/LINUX-DEPENDENCY-AUDIT.md) and
  [Linux bridges](#linux-bridges-nvidia_linuxko).
- Wayfire cannot yet use the NVIDIA output, cross-GPU PRIME import is not merged, and no
  packages are published.
- Report problems at <https://github.com/cloudbsdorg/nvidia-gb10-freebsd/issues> with the
  failing step's output, `dmesg` and `uname -a`.

## Firmware

`nvidia.ko` depends on the GSP firmware module for its GPUs. `nvidia_gsp_ga10x_fw` serves
Ampere other than GA100, Ada, Hopper and Blackwell, on every architecture. `nvidia_gsp_tu10x_fw`
serves Turing and GA100 (GA100 uses the tu10x firmware) and is built on amd64 only. Once the
modules are installed next to `nvidia.ko` and `kldxref` has indexed the directory, `kldload nvidia`
loads them first, as root, so the first open of the GPU by an unprivileged process finds the
firmware already registered. The kernel names the module after the file with `_fw` appended, so
`nvidia_gsp_ga10x_fw_fw` shows in `kldstat -v`; a firmware module cannot be unloaded while
`nvidia` is loaded. If `kldload` says `depends on nvidia_gsp_ga10x_fw_fw - not available`, the
module is not installed or the index is stale: run `make install` again, which runs `kldxref`.
See `man/nvidia.4`.

## Diagnostics

The GPU is initialised, and GSP booted, on the first open of its `/dev/nvidiaN`. If that first
open fails (`nvidiaN: NVRM: rm_init_adapter() failed!` in `dmesg`, and the program gets `EIO`),
the driver frees what the open took and the open can be tried again. `N` is the unit number:
find it by PCI bus, never by assuming 0. See `man/nvidia.4`.

## What works

| | Status |
|---|---|
| `nvidia.ko` loads and attaches to the GPU; GSP firmware boots | works |
| `nvidia-modeset.ko` and `nvidia-drm.ko` load | works |
| Display (DRM/KMS on the NVIDIA card: mode set, scan-out) | works: colour bars on the NVIDIA card's DRM node, found by PCI bus; Xorg modesetting at 2560x1440 on HDMI, software rendering only |
| CPU writes to a dumb buffer in video memory | works: written data reads back through a fresh `mmap` |
| Device enumeration, native (`nvrm-info`, libnvrm) | untested on hardware (passes against a simulated device only) |
| `nvidia-smi` (NVIDIA's Linux arm64 build, through the Linuxulator) | works; Linux-only, last resort |
| Vulkan (NVIDIA's Linux arm64 ICD, through the Linuxulator) | waits for a test boot: it ran earlier on the tested machine (numbers below); the BAR0 mapping fix (register window as Device memory, not cached) is committed and not yet run on hardware; Linux-only, last resort |
| CUDA (NVIDIA's Linux `libcuda`, through the Linuxulator) | works, with the prerequisites below; Linux-only, last resort |
| CUDA, native | in progress: full compile and link work with stubs; every launch returns `cudaErrorNotSupported` (801); no GPU execution yet (Track #2362) |
| Wayfire on the NVIDIA output | not yet: Wayfire runs on the other GPU and the NVIDIA output stays blank. It needs cross-GPU import. A framebuffer without NVIDIA memory is refused with `EINVAL` |
| Cross-GPU buffer import (PRIME) of system-memory buffers | implemented (#2228), waits for a test boot; not merged; see [Cross-GPU buffers](#cross-gpu-buffers-prime-import) and Track #2228 |
| Accelerated native rendering and native Vulkan (Mesa NVK; on libnvrm for compute, Track #2379) | not started: only the interface contract exists ([`nvidia-drm-render.h`](src/nvidia-drm-render/nvidia-drm-render.h), [nvidia_drm_render(4)](man/nvidia_drm_render.4)) |

Tested on one machine so far: an Ampere Altra running FreeBSD 16.0-CURRENT with a GeForce RTX
5060 Ti (GB206). Not tested yet: DGX Spark (GB10), other arm64 machines, other GPUs, amd64.

**CUDA prerequisites.** `libcuda` needs `/dev/nvidia-uvm`, which NVIDIA does not ship for
FreeBSD. It comes from the clean-room module
[uvm-bsd](https://github.com/cloudbsdorg/uvm-bsd) (tested at commit 256297e; the version 2 `nvidia.ko` below needs a newer one, see Versions). It also needs
Linuxulator additions in the kernel: the `/proc` files `libcuda` reads, and Linux abstract
UNIX sockets. Those are in the cloudbsd-src tree, not here (Track #2101).

**Numbers.** These predate the BAR0 mapping fix, which waits for a test boot. Linux-only, last resort: the official Ubuntu arm64 llama.cpp b12531 builds on
NVIDIA's Linux libraries, under the Linuxulator (`llama-bench`, defaults otherwise), in tokens per
second. They are not native numbers; there is no native NVIDIA path to measure yet. pp512 is the prompt-processing speed over a 512-token prompt, and tg128 the generation
speed over 128 tokens.

| Backend | Model | pp512 | tg128 |
|---|---|---|---|
| Vulkan | Llama-3.2-3B-Instruct Q4_K_M | 7047 | 159 |
| CUDA | Llama-3.2-3B-Instruct Q4_K_M | 8728 | 166.2 |
| CUDA | 7B Q4_0 | 3706 | 97.8 |

CUDA also ran a 30-minute stress test (5992 CUDA processes, 220 of them killed with `kill -9`)
with no failure.

**Packages.** No package is published yet. The CloudBSD ports overlay accepts the 580 driver
set on aarch64 (`x11/nvidia-kmod-580`, `graphics/nvidia-drm-612-kmod-580`,
`x11/nvidia-driver-580`, `x11/linux-nvidia-libs-580`) and builds `graphics/nvidia-uvm-kmod`
from uvm-bsd. The Jenkins builds come next.

**Native desktop.** The goal is a native FreeBSD accelerated desktop on the NVIDIA card (Mesa NVK
and Zink), with Linux binaries running on top of the same drivers. NVK already builds on FreeBSD
arm64 and finds the GB206 through a test shim. It cannot drive the card until the render
interface exists in the kernel.

The arm64 BAR mapping and the `SIGBUS` on the first Vulkan register read are described under
[Memory attributes on arm64](#memory-attributes-on-arm64). See uvm-bsd's README, under
"Status", for CUDA start-up.

Example, on that machine:

```
NVIDIA-SMI 580.178.04             Driver Version: 580.178.04     CUDA Version: N/A
  0  NVIDIA GeForce RTX 5060 Ti     Off |   0000000C:01:00.0 Off |                  N/A
 47%   30C    P0             13W /  180W |       0MiB /  16311MiB |      3%      Default
```

## Kernel

`nvidia.ko` needs no kernel change: its symbols resolve against a stock 16.0-CURRENT kernel alone.
It needs no Linux layer: `linux64.ko` and `linux_common.ko` are not dependencies; the
Linux ioctl bridges are the optional modules `nvidia_linux.ko` and `nvidia_modeset_linux.ko`
(see [Linux bridges](#linux-bridges-nvidia_linuxko) below). An **Ampere Altra** does need kernel workarounds for its PCIe
(32-bit configuration reads, emulation of misaligned device accesses), and `nvidia-drm`, like
every drm-kmod driver, needs LinuxKPI to map write-combining memory non-cacheable on arm64.
Those are FreeBSD kernel patches, kept in [`kernel-patches/`](kernel-patches/README.md) with a
step-by-step guide (check whether you need them, fetch the matching source, apply, build,
install as `kernel.patched`, test once with `nextboot`, make it the default, go back, redo after
updates), a helper `kernel-patches/apply.sh` and the manual page `kernel-patches(7)`. Other
arm64 machines need only the LinuxKPI patch, and only for `nvidia-drm`.

On the Altra the driver also maps write-combining BARs as Device memory. It decides this itself
from the ACPI MCFG table and reports the decision in `hw.nvidia.altra_device_wc_active`; see
[Tunables and sysctls](#tunables-and-sysctls).

## Requirements

- FreeBSD 16.0-CURRENT on arm64, and the matching kernel source (`SYSDIR`, default
  `/usr/src/sys`).
- For `nvidia-drm`: the drm-kmod **source tree** the running `drm.ko` was built from
  (`DRMKMODDIR`), and the FreeBSD source tree it takes its headers from (`BSDSRCTOP`,
  the parent of `SYSDIR` by default).
- `git`, `gmake`, `zstd`; the base system's `clang` and `ld.lld`.
- For `nvidia-smi` (and any Linux binary): the Linuxulator (`linux64.ko`), `nvidia_linux.ko` and
  `linux_base-rl9`. `nvidia.ko` does not load the Linuxulator; load `nvidia_linux.ko` for Linux
  programs, or install `rc.d/nvidia_linux` in `/usr/local/etc/rc.d`, put `nvidia` (and `nvidia_modeset` if you use it) in `kld_list`, set
  `linux_enable=YES` and let it do it at boot (`nvidia_linux_mode=AUTO` loads a provider only for a
  driver that is already loaded).
- An Ampere-generation or newer GPU (RTX 30 series and later, and data-centre parts of the
  same generations). Those run the `gsp_ga10x` firmware this repository builds; Turing needs
  `gsp_tu10x`, which is not built yet.

## Memory attributes on arm64

On x86 NVIDIA's driver picks a PAT type for each mapping, and the BAR's MTRR keeps register
pages uncached whatever the driver asks for. arm64 has no MTRRs: the attribute in the page
table is the only one, so a wrong choice reaches the hardware. The policy for a physical range
lives in [`src/gb10-memattr/gb10_memattr.h`](src/gb10-memattr/gb10_memattr.h). Both mapping
paths in `nvidia.ko` use it: kernel mappings (`os_map_kernel_space`) and the device mappings
that user clients `mmap` (`nvidia_mmap_dev_single`).

First the range is classified, page by page, with `vm_phys_paddr_to_vm_page()`:

- every page is managed RAM: the system-memory policy (write-back);
- no page is managed RAM: it is a PCIe BAR, and the table below applies;
- a mix of the two: the mapping is refused.

For a BAR the caching class the driver requests (NVIDIA's `NV_MEMORY_*`) maps to:

| Request | Other arm64 systems | Ampere Altra |
|---|---|---|
| `CACHED` | Device-nGnRE | Device-nGnRE |
| `UNCACHED` | Device-nGnRE | Device-nGnRE |
| `DEFAULT` | Device-nGnRE | Device-nGnRE |
| `WRITECOMBINED` | Normal non-cacheable | Device-nGnRE |
| anything else | mapping refused | mapping refused |

Device-nGnRE is `VM_MEMATTR_DEVICE`; Normal non-cacheable is `VM_MEMATTR_UNCACHEABLE`, which is
arm64's write-combining attribute. `VM_MEMATTR_WRITE_COMBINING` is not used: on arm64 it is an
alias of write-through, which is cacheable.

A BAR is never mapped cacheable, even when the driver asks for `CACHED`. The open RM core does
ask for it: it maps the 64 KiB USERMODE register window in BAR0, the first thing every Vulkan
and CUDA process maps, as `NV_MEMORY_CACHED`. On x86 the MTRR makes that harmless. On the Altra
a cacheable load from a register page is a synchronous external abort, which the process sees as
`SIGBUS` (`BUS_OBJERR`). The mapping rule above prevents that Vulkan crash.

On the Altra, Normal memory accesses to PCIe BARs are not safe (the root complex mishandles
some of them), so write-combining requests fall back to Device-nGnRE there as well. The
FreeBSD kernel patches in [`kernel-patches/`](kernel-patches/README.md) apply the same rule to
LinuxKPI's write-combining mappings, Device for the kernel and Normal non-cacheable for user
processes (`compat.linuxkpi.altra_82288`). `nvidia.ko` applies its table to the
mappings it makes itself, the kernel ones and the user ones alike.

## Video memory and fictitious pages (nvidia-drm)

A program draws into a dumb buffer by `mmap`ing it from the DRM device. For a buffer in video
memory the mapping points into BAR1. `nvidia-drm` is built against linuxkpi, and linuxkpi maps
a page frame through its `struct vm_page`. A PCIe BAR has no `vm_page`s unless someone
registers a fictitious range for it; ttm does that for its VRAM aperture, but NVIDIA's
upstream FreeBSD code does not. Without one, `vmf_insert_pfn` fails, linuxkpi's pager returns `VM_PAGER_BAD`,
and the VM system falls back to an ordinary fault: the user page becomes a zero-filled RAM
page. Nothing reports an error. The program writes into RAM, video memory never changes, and
the monitor stays black.

`nvidia-drm` therefore registers each video-memory window with
`vm_phys_fictitious_reg_range()` right after `nvKms->mapMemory()`. If registration fails, the
window is unmapped and the map fails (`ENOMEM`), so a mapping never quietly lands in RAM. The
kernel panics on an overlapping registration, so the window is probed first. Pages that are
all fictitious already, at the same physical addresses, are shared and not registered again. A
partial overlap is refused (`EBUSY`). On free, the range is unregistered before
`unmapMemory()`, unless another VM object still holds one of its pages.

The cost is one `struct vm_page` per page of each video-memory buffer while it is mapped (about
200 KiB for a 1920x1080 32-bit buffer), not the whole BAR. This is not Altra-specific: amd64
FreeBSD takes the same path.

The same mappings are write-combining (`pgprot_writecombine`), as Linux's DRM core makes them,
not write-back. On arm64 that is Normal non-cacheable.

`sysctl vm.phys_fictitious_segs` lists the registered ranges while a buffer is mapped.

### The PAGE_MASK trap

Code compiled against linuxkpi (here `nvidia-drm`) gets Linux's `PAGE_MASK`: linuxkpi's
`linux/page.h` redefines it as `~(PAGE_SIZE - 1)`, the page address, where FreeBSD's
`PAGE_MASK` is `PAGE_SIZE - 1`, the offset within the page. So `addr & PAGE_MASK` is the
opposite test in the two worlds: a FreeBSD-style alignment check in `nvidia-drm` rejects every
video-memory window as "not page aligned", so no dumb buffer can be created. The registration
code tests `start & (PAGE_SIZE - 1)` (`patches/patch-nvidia-drm_nvidia-drm-gem-nvkms-memory.c`),
and `tests/drm_fault_index_test.sh` fails if it tests `& PAGE_MASK`. In FreeBSD-only code
that includes linuxkpi headers, test alignment with `addr & (PAGE_SIZE - 1)`. `nvidia.ko` is
native FreeBSD code, where `PAGE_MASK` means what FreeBSD says.

## Cross-GPU buffers (PRIME import)

A buffer another GPU rendered into (the RX 7600 on amp001, through `amdgpu`) can be imported by
`nvidia-drm` when it is **system memory**. NVIDIA's unpatched FreeBSD OS layer answers every
dma-buf import with "not supported" and then `nvidia-drm` hands the KAPI a NULL handle.
[`patches/patch-nvidia-drm_nvidia-drm-fb.c`](patches/patch-nvidia-drm_nvidia-drm-fb.c) rejects
that NULL handle with `EINVAL` instead of panicking. The design, the exact failure chain and
every decision are in [`docs/PRIME-IMPORT.md`](docs/PRIME-IMPORT.md); the sources consulted are
in [`PROVENANCE.md`](PROVENANCE.md).

How it works, in one paragraph. `nvidia-drm` walks the buffer's scatter list and expands it to one
`vm_page` pointer per page; anything that is not a whole number of managed RAM pages (a partial
page, a buffer in the other card's video memory, an empty or over-4-GiB buffer, a list that
disagrees with the size) is refused with `EINVAL` and a line in the log saying why, and the GEM
object is created without an NVKMS handle, so it cannot become a framebuffer (the guard of #2228
answers `ADDFB2` with `EINVAL`). Otherwise `nvidia.ko` wires the pages (`nv_import_pages()`) and
the KAPI entry `getSystemMemoryHandleFromPageArray()` gives them to the RM as a write-back
page-array descriptor; the RM's own teardown unwires and frees them. The export ioctl always goes through the SGT entry points (`nv_register_sgt()` and friends)
when the pages were imported, never straight from the page-array handle: that holds no
reference, and the SGT path holds the GEM
object for as long as the RM file descriptor maps the pages. The exporter's dma-buf is held for
the whole life of the imported GEM object.

A buffer the exporter has already CPU-mapped and touched when it is imported (a page the exporter
faulted in has a VM object) is refused with a log line. One it maps later is fine: the page gets
an object after the wiring and is dirtied correctly at the release.

Two read-only sysctls report the release path: `hw.nvidia_unlock_dirty_refused` (pages with a VM
object that were not all valid when the RM unpinned them; unexpected for an imported buffer) and
`hw.nvidia_unlock_dirty_busy_fallback` (pages dirtied without their busy lock after a short spin);
see section 7.6 of `docs/PRIME-IMPORT.md`. `kldunload nvidia_drm` is refused (`EBUSY`, with the reason in the log) while an RM file descriptor
still holds an exported imported buffer, also for `kldunload -f`, and once the driver has agreed to an unload (a quiesce with no
export open) new exports are refused until the next boot, even if the unload is then abandoned. The guard is a second module of `nvidia-drm.ko` that loads
last (`SI_ORDER_LAST`) so that it is unloaded first; the boot kit checks that with `kldstat -v`
(docs/PRIME-IMPORT.md 7.7).

What does not work yet: a buffer in the other GPU's video memory (needs a copy), the dma-buf file
descriptor interface the NVIDIA userspace driver uses (Track #2307), and scanning an imported
system-memory buffer out directly (NVIDIA's own rule: a card with video memory does not; Track
#2308).

Tests. `tests/pageimport_test.sh` (the conversion, wiring and SGT logic against a fake VM, with
mutants that must fail), `tests/kapi_table_test.sh` (both copies of the KAPI table header agree;
a planted mismatch fails), `tests/prime_import_test.sh` (the patched sources are wired as the
design says). Hardware: [`tests/prime-import-testboot/`](tests/prime-import-testboot/) holds the
one-shot test-boot kit and `prime_import_probe(8)`; nothing here is loaded on a running system.

## Tunables and sysctls

| Name | Kind | Values |
|---|---|---|
| `hw.nvidia.altra_device_wc` | loader tunable, read when `nvidia.ko` loads | `-1` decide from ACPI (default), `0` force Normal non-cacheable write-combining, `1` force Device-nGnRE write-combining |
| `hw.nvidia.altra_device_wc_active` | read-only sysctl | `1` write-combining BAR mappings are Device-nGnRE, `0` they are Normal non-cacheable |

With the default `-1` the driver reads the ACPI MCFG table header. It treats the system as an
Altra when the OEM ID is exactly `Ampere` and the OEM table ID starts with `Altra` (Altra and
Altra Max). The kernel's Altra workarounds use the same rule. No MCFG table means "not an
Altra". Any value of 0 or more overrides the detection. The decision is also printed at load:

```
NVRM: arm64 BAR write-combining: Device-nGnRE (MCFG Ampere/Altra   , tunable -1)
```

Set the tunable in `/boot/loader.conf`, or with `kenv` before `kldload`:

```sh
kenv hw.nvidia.altra_device_wc=0     # try Normal-NC write-combining on this boot only
sysctl hw.nvidia.altra_device_wc_active
```

Forcing `0` on an Altra brings back the unsafe Normal accesses to BARs. Use it only to test.

### Version and identity sysctls

The driver exposes its version as integers, so a script never has to parse a version
string, and the UUID and PCI location of each GPU:

```sh
sysctl hw.nvidia.version_major hw.nvidia.version_minor hw.nvidia.version_patch
sysctl hw.nvidia.gpus.0.vbios_major hw.nvidia.gpus.0.firmware_major
sysctl dev.nvidia.0.uuid dev.nvidia.0.pci_bus_id
```

`nvidia-modeset.ko` has the same `version_*` variables under `hw.nvidiamodeset`. The full
list, the meaning of the `*_available` flags and what a read returns before the GPU is
initialized are in `nvidia(4)`.

## The UVM interface in nvidia.ko

CUDA needs `nvidia-uvm.ko`, a separate kernel module that is a client of the resource
manager (RM) inside `nvidia.ko`. NVIDIA's FreeBSD OS layer does not export the kernel
interface that module needs, although the open RM core already contains the implementation
("gpu-ops"). `src/gb10-uvm/nv-uvm-interface.[ch]`, built into `nvidia.ko`, adds it:

- the `nvUvmInterface*` entry points, each a wrapper that allocates an RM stack and calls
  the matching gpu-ops function of the core; `nvidia.ko` exports them
  (`patches/patch-nvidia_Makefile`, `EXPORT_SYMS`) for `nvidia-uvm.ko` to link against;
- GPU lookup by UUID (`nvUvmInterfaceRegisterGpu`): opens each attached device so RM knows its
  UUID, keeps the open reference on the match and raises RM's external-kernel-client count;
  returns the PCI `device_t` and the DMA window the OS layer recorded;
- the callback table UVM installs (`nvUvmInterfaceRegisterUvmCallbacks`); removing it waits
  for every callback in flight;
- the interrupt order UVM needs: `nvidia_intr()` runs UVM's top half before `rm_isr()`, and
  stops copying MMU faults itself while a UVM table is installed (RM fills UVM's shadow buffer);
  `nv_schedule_uvm_isr`, the hook RM calls, runs the same top half;
- suspend and resume: UVM is told before RM's standby (it may veto) and after RM's resume;
- the two RM stacks the lock-free fault calls use, allocated by `nvUvmInterfaceInitFaultInfo`.

Three MIT-licensed interface headers of the open RM core that the FreeBSD tarball does not
ship (`nv_uvm_types.h`, `nv_uvm_user_types.h`, `nvgputypes.h`) are copied into the tree by
`scripts/prepare-tree.sh` from the pinned checkout and recorded in the tree's manifest as
`ogkm:<path>`. `tests/uvm_glue_test.sh` checks the exports, the structure layouts against the
UVM specification, the interrupt order and the manifest.

The module itself lives in its own repository (uvm-bsd), written clean-room
from a specification; this repository holds only the `nvidia.ko` side.

## nvidia-smi

Not built here. NVIDIA's Linux arm64 `nvidia-smi` of the same version runs through the
Linuxulator. `scripts/fetch-nvidia-smi.sh` fetches NVIDIA's Linux arm64 installer pinned in
`SOURCES`, checks its sha256, and unpacks only `nvidia-smi` and `libnvidia-ml.so` from it;
NVIDIA's installer is never run. On any failure it stops with a message and a non-zero exit,
and on a checksum mismatch it unpacks nothing.

```sh
sh scripts/fetch-nvidia-smi.sh          # into $GB10_WORK/nvidia-smi (or give a directory)
$GB10_WORK/nvidia-smi/nvidia-smi        # the wrapper sets LD_LIBRARY_PATH itself
```

The pins are `nvidia_linux_aarch64_url`, `_sha256` and `_skip` (the line where the
installer's compressed payload starts; the script checks that a zstd stream starts there), with
`ogkm_tag` as the library version. For another driver version update all four; read the new
payload line from the installer's header with `head -c 4096 <installer>.run | grep -a '^skip='`.

## Vulkan (Linux ICD under the Linuxulator)

There is no FreeBSD build of NVIDIA's Vulkan driver. NVIDIA's Linux arm64 ICD of the same
version talks to `nvidia.ko` through the Linuxulator, as `nvidia-smi` does. It was run from a
private Linux root, a directory of its own (`$GB10_WORK/linuxroot`), so nothing in
`/compat/linux` is changed:

| Directory | Contents |
|---|---|
| `nv/` | NVIDIA's 580.178.04 user-space libraries from the same Linux arm64 installer (`libGLX_nvidia`, `libEGL_nvidia`, `libnvidia-*`), with `nvidia_icd.json` and `10_nvidia.json` |
| `rl9/` | Rocky Linux 9 packages: the Vulkan loader, `vulkaninfo`, `libglvnd`, the X11, xcb and Wayland client libraries and `libffi` |
| `noble/` | Ubuntu 24.04 packages for programs built for a newer glibc (llama.cpp's `ubuntu-vulkan-arm64` build needs `GLIBC_2.38`): glibc 2.39, `libstdc++`, `libgomp`, the Vulkan loader, the X11 and glvnd libraries |

`fetch-nvidia-smi.sh` unpacks only `nvidia-smi` and `libnvidia-ml.so`; the other libraries in
`nv/` come from the same verified installer but are not unpacked by a script in this repository
yet. The `rl9/` binaries use the glibc of `linux_base-rl9`. The `noble/` binaries are started
through that root's own dynamic linker.

Two things are needed besides the libraries:

- `libglvnd`. Without it the ICD cannot load `libEGL.so.1` and returns no `vkCreateInstance`
  ("Could not get 'vkCreateInstance' via 'vk_icdGetInstanceProcAddr'").
- The environment that points the loader and glvnd at the private root:

```sh
R=$GB10_WORK/linuxroot
export VK_DRIVER_FILES=$R/nv/nvidia_icd.json
export __EGL_VENDOR_LIBRARY_FILENAMES=$R/nv/10_nvidia.json

# Rocky userland (glibc from linux_base-rl9):
LD_LIBRARY_PATH=$R/rl9/usr/lib64:$R/nv $R/rl9/usr/bin/vulkaninfo --summary

# Ubuntu userland, started through its own dynamic linker:
$R/noble/lib/ld-linux-aarch64.so.1 --library-path "$R/noble/lib/aarch64-linux-gnu:$R/nv" \
    <program> ...
```

Status: waits for a test boot (see [What works](#what-works)). Before the BAR0 mapping fix,
`vulkaninfo --summary` listed "NVIDIA GeForce RTX 5060 Ti" on the tested machine. The USERMODE
register window uses the mapping rule in [Memory attributes on arm64](#memory-attributes-on-arm64).
The ioctl `0xc23046d7` failing with `EINVAL` ("unknown NVRM ioctl") in a `ktrace` is harmless.

[`scripts/run-nv-vulkan.sh`](scripts/run-nv-vulkan.sh) wraps all of this: it sets the two
variables, runs the programs from the llama directory (so they find their backends, also under
`daemon(8)`) and starts them through the Ubuntu root's own dynamic linker. It is described in
[`docs/llm.md`](docs/llm.md#nvidia).

## Running LLMs

How to run llama.cpp on this kind of machine (Vulkan on the AMD card, the numbers measured,
splitting prefill and decode between two servers, the NVIDIA Vulkan launcher and the llama-bench
comparison tables): [`docs/llm.md`](docs/llm.md).

## Repository layout

| Path | What |
|---|---|
| `SOURCES` | pins for NVIDIA's sources |
| `scripts/` | fetch, prepare and build steps; `lib.sh` holds the shared helpers; `pd_split.py`, the prefill/decode split client, `bench_compare.py`, the llama-bench comparison tables, and `run-nv-vulkan.sh`, the Vulkan launcher of [`docs/llm.md`](docs/llm.md) |
| `patches/` | one unified diff per changed file of NVIDIA's FreeBSD OS layer |
| `patches/ogkm/` | patches to the open-gpu-kernel-modules build for FreeBSD aarch64 |
| `kernel-patches/` | patches to the FreeBSD kernel itself (LinuxKPI write-combining on arm64; Ampere Altra PCIe workarounds), `apply.sh`, `kernel-patches(7)` and a [step-by-step README](kernel-patches/README.md) |
| `src/gb10-stubs/` | fail-closed stubs for RM core functions the arm64 build lacks |
| `src/gb10-memattr/` | the memory-type policy for kernel mappings on arm64 |
| `src/gb10-linux-bridge/` | the compat provider interface of `nvidia.ko` (`nvidia_bridge.h`, `nvidia_bridge.c`) and the two Linux provider modules, `nvidia_linux.ko` and `nvidia_modeset_linux.ko` |
| `rc.d/nvidia_linux` | loads the providers when the Linuxulator is configured |
| `src/nvidia-drm-render/` | `nvidia-drm-render.h`, the render uAPI of nvidia-drm: layouts and ioctl numbers for the kernel work packages and the Mesa `nvdrm` backend; MIT |
| `man/` | `nvidia_drm_render(4)`, the manual page of that interface; `nvidia(4)` and `nvidia_linux(4)`, the native driver and its Linux providers |
| `docs/` | how-tos: [`llm.md`](docs/llm.md), running LLMs; [`RENDER-UAPI.md`](docs/RENDER-UAPI.md), the full semantics of the render uAPI |
| `tests/` | one `*_test.sh` per script, plus the ABI layout and symbol checks; `render_uapi_layout_test.sh` and `render_uapi_docs_test.sh` check the render uAPI header and its documents (`render_uapi_layout_test.sh` reads `SYSDIR`, a FreeBSD `src/sys` checkout for the kernel compile, and `RENDER_UAPI_ALLOW_SKIP=1` to accept a skipped check; both read `GB10_WORK` and `TMPDIR`); run each with `sh` |
| `src/gb10-pageimport/` | the pure core of the cross-GPU buffer import: scatter list to page array, wiring, the SGT entry points |
| `src/gb10-uvm/` | the UVM interface of the OS layer: `nvUvmInterface*` exports, callback table, ISR hook |
| `lib/cuda-native/` | the native CUDA SDK tree for clang (`--cuda-path`): our headers, the libdevice source, `mksdk.sh`; see [Native CUDA toolchain](#native-cuda-toolchain-cuda-native) |
| `docs/` | how-tos: [`llm.md`](docs/llm.md), running LLMs; [`PRIME-IMPORT.md`](docs/PRIME-IMPORT.md), cross-GPU buffer import |
| `tests/` | one `*_test.sh` per script, plus the ABI layout and symbol checks; run each with `sh` |
| `tests/cuda/` | Linux aarch64 CUDA test programs and the LD_PRELOAD shim ([`docs/llm.md`](docs/llm.md#cuda-linux-libcuda-through-the-linuxulator-linux-only-last-resort)); built by `scripts/build-linux-cuda.sh`, run by `scripts/run-linux-cuda.sh` |

## RM client ownership for nvidia-uvm

**What and why.** The RM resolves a client handle with kernel privilege and never asks who
is calling, and handles are predictable (`0xC1D00000` is the first client of a boot). So
`nvidia.ko` records which open `/dev/nvidiactl` file each client was allocated on
(`src/gb10-client-owner/nv_client_owner.h`, hooked into `nvidia_handle_ioctl` and
`nvidia_close_ctl` by `patches/patch-zz-nvidia_client_owner_subr.c`) and exports two
functions for `nvidia-uvm.ko` (the clean-room UVM driver, uvm-bsd):

- `NV_STATUS nvUvmInterfaceClientHold(struct file *fp, NvHandle hClient)`: `NV_OK` only for a
  devfs character device `nvidiactl` file of this module that owns the client, otherwise
  `NV_ERR_INSUFFICIENT_PERMISSIONS`. On `NV_OK` the client is held: a free of it waits, and
  the file cannot close (the hold keeps its own file reference).
- `void nvUvmInterfaceClientRelease(struct file *fp, NvHandle hClient)`: call it exactly once
  per `NV_OK`, never after a refusal. Holds are per client and nest, so an RM call made under
  a hold delays only a free of that one client, not other users.

**Guarantees.** The table lock is a leaf lock: it is never held across an RM call (the RM can run
a file's close destructor, which takes it, from inside an RM call), so the table is updated after
the RM call returns and may lag it; every lag fails closed. An unrecorded new client is refused. A reused handle leaves both parties
unowned. A free in flight keeps new holds out. A free of a handle the table has not recorded leaves
a short-lived marker (a tombstone) while it runs. A free of an unrecorded handle that the RM carried out is remembered
(the last 64, `NVCO_FREELOG`), and an allocation that began before such a free ended is refused its
record. A record that lands while a marker stands takes the marker over: no hold is granted on
it until that free ends. If the RM refused that free, the owner keeps its record; nvidia-uvm requests on that client fail until
the free ends, then work again. If the RM carried it out, the record is dropped with it. A free of a client the table lists by a file that does not own it is refused with `EPERM` before the
RM is called, so a stranger can neither reach the RM in that window nor raise the count of a
predictable handle. The owner's free first waits for the holds on the client, before the ioctl
takes any other lock. A client freed leaves the table, a closing file forgets its clients, and only
a control file can own one.
If a client's free is still running when the file that owns that client closes, the entry goes back to a
marker instead of being dropped, so a later record of the same handle is held back until the free ends.
Default client-handle validation does not prevent this: a control file linked by `NV_ESC_REGISTER_FD` to
another file of the same user is enough, so it does not need validation to be off.
The free counts use 64-bit generation numbers that are never 0.

**Versions.** `nvidia.ko` is module version 2. `nvidia-modeset.ko`, `nvidia-drm.ko` and
`nvidia-uvm.ko` depend on exactly that. `nvidia-uvm.ko` has to come from the uvm-bsd branch
`agent/2373-uvm-client-ownership` or later (its `MODULE_DEPEND` is in that repository).
Updating `nvidia.ko` alone does not fix the cross-user hole or keep the display: the four
modules go together.

- Symptom: `kldload` fails ("an error occurred while loading module"), and `dmesg` shows a
  version mismatch or `symbol nvUvmInterfaceClientHold undefined` (or `...ClientRelease`).
- Cause: the modules are from different builds, or `nvidia.ko` was built without the
  `patch-zz-nvidia_client_owner_*` patches. An older `nvidia-uvm.ko` (version 1 dependency)
  refuses the new `nvidia.ko`, and the new one refuses an old `nvidia.ko`.
- Fix: rebuild `nvidia`, `nvidia-modeset`, `nvidia-drm` and `nvidia-uvm` from one tree made by
  `scripts/prepare-tree.sh` and reload them together.

**A stuck free.** A free of a client waits for the holds on it, in an interruptible sleep with
wait channel `nvcobusy`, and every other ioctl on the same file waits behind it. `nvidia-uvm.ko`
takes a hold for one request and releases it when the request ends, so the wait is normally
short. A process that stays in `nvcobusy` means a hold was leaked, which is a bug in
uvm-bsd: a leaked hold lasts until reboot (killing the waiting process only ends
that one wait, and the client is never freed). A fatal signal, or a caught signal without
`SA_RESTART`, ends the wait (`EINTR`, nothing freed); a restartable signal waits again.
`ps -axo pid,wchan,comm | grep nvcobusy` finds the process. A console line
`nvUvmInterfaceClientRelease: no hold on client ... (nvidia-uvm bug)` is the opposite fault, a
release without a matching hold; quote it in the report if you see it (a debug kernel panics
with "client release without a matching hold" instead). A console line
`RM client 0x... could not be recorded for nvidia-uvm` means the table and the RM disagreed about a
handle. The causes: the handle was listed for another file; a free of it that the RM carried out
ended after the allocation began; 64 or more frees of other unrecorded handles that the RM carried out
ended during the allocation (the log holds only the most recent ones); or memory ran out.
nvidia-uvm refuses requests on that client until it is freed and allocated again. A free by a
file that does not own a listed client fails with `EPERM` at once and changes nothing (free the
client through the `/dev/nvidiactl` file that allocated it). A stranger therefore cannot free a
client the table has recorded for its owner. While a handle is unrecorded (including while a free that found it
unrecorded is in flight), any control file may free it and the RM decides: if the RM carries the free out, the owner
loses that client. `nvUvmInterfaceClientHold` must be called from a sleepable context with
no RM lock held, never from an RM callback; the same goes for `nvUvmInterfaceClientRelease`.

**Tests.** `tests/client_owner_glue_test.sh` compiles the real glue (`src/gb10-client-owner/nvco_glue.h`)
against fakes of the kernel and runs it, with mutants that must fail. `tests/client_owner_test.sh` reads `GB10_WORK` (a directory with `sources/` holding the
pinned open-gpu-kernel-modules 580.178.04 checkout and the NVIDIA FreeBSD tarball) and `TMPDIR`;
without them the layout and prepare-tree checks are skipped (a failure under `CI` or
`REQUIRE_INPUTS`). It runs the table logic (layouts compared with the real `nvos.h`), checks the
patch hooks, and runs deliberately broken copies of the header and the patch that it must reject.

## Linux bridges (`nvidia_linux.ko`)

`nvidia.ko` and `nvidia-modeset.ko` load and work with no `linux64`, no `linux_common` and no
`/compat/linux`. The `nvidia-uvm.ko` module from uvm-bsd currently depends on the Linuxulator.
What Linux binaries need lives in two modules that belong to the Linuxulator:

| Module | Serves | Depends on |
|---|---|---|
| `nvidia_linux.ko` | Linux ioctls 0x4600-0x46ff, Linux device names of `/dev/nvidiactl` and `/dev/nvidiaN` | `nvidia` (1 to 2), `linux64elf` (`linux64` on amd64), `linux_common` |
| `nvidia_modeset_linux.ko` | the NVKMS Linux ioctl and the `nvidia-modeset` device name | `nvidia_modeset`, `linux64elf` (`linux64` on amd64), `linux_common` |

On amd64 only the 64-bit Linuxulator is served: a 32-bit Linux binary gets no NVIDIA ioctl
translation from these modules.

```sh
sh scripts/build-shim.sh --module=nvidia-linux           # nvidia_linux.ko
sh scripts/build-shim.sh --module=nvidia-modeset-linux   # nvidia_modeset_linux.ko
kldload $GB10_WORK/build/tree/nvidia/nvidia.ko                          # no Linux layer
kldload $GB10_WORK/build/tree/nvidia-linux/nvidia_linux.ko              # loads linux64 and linux_common, then bridges nvidia
# or, once the modules are installed in /boot/modules and kldxref has run: kldload nvidia_linux
kldunload nvidia                  # refused (Device busy) while nvidia_linux is loaded
kldunload nvidia_linux            # unload the bridge first
```

`rc.d/nvidia_linux` loads them at boot when `linux_enable=YES` and the native module is already
loaded (`nvidia_linux_mode=AUTO`, `YES` or `NO`). To make `nvidia.ko` itself pull in the
Linuxulator, set `NV_CORE_LINUX_COMPAT=yes` in the environment of `scripts/build-shim.sh` for
`nvidia.ko` and `NVKMS_CORE_LINUX_COMPAT=yes` for `nvidia-modeset.ko` (for example
`NV_CORE_LINUX_COMPAT=yes sh scripts/build-shim.sh --module=nvidia`; the switches are in the
build stamp, so changing one cleans the objects first). `tests/linux_bridge_test.sh` checks the
module metadata, the imports and the fuzz 0 patch apply; see `nvidia_linux(4)` and `nvidia(4)`.

## Licence

Our scripts, patches and sources are BSD-3-Clause (see [`LICENSE`](LICENSE)). NVIDIA's code,
fetched at build time, keeps NVIDIA's licences: MIT for open-gpu-kernel-modules, NVIDIA's own
licence for the FreeBSD driver package and the firmware. `src/nvidia-drm-render/nvidia-drm-render.h`
is MIT, because its layouts follow Mesa's MIT nouveau uAPI header and it is meant to be included by
NVIDIA's MIT nvidia-drm sources and by Mesa. Provenance: [`PROVENANCE.md`](PROVENANCE.md).

## libnvrm and nvrm-info

`lib/libnvrm/` is the shared user-space layer for native NVIDIA access: C, BSD-2-Clause, no
LinuxKPI and no Linux layer. `nvrm_enumerate()` opens `/dev/nvidiactl`, checks that the kernel
module is the RM version the library was built for (580.178.04), lists and attaches the probed
GPUs and describes each one (PCI identity, UUID, architecture, SM version, GPC/TPC/SM counts,
class list, VRAM, BAR1, page sizes, capability flags). Every value is available or carries a
reason; the layers are abstract device, class, family (a generation table keyed by class ids)
and board decorators (none yet). Backends are providers: `rm` and `fake`
(`NVRM_BACKEND=fake`, for CI without a GPU). After enumeration the process may enter Capsicum
capability mode (the descriptors keep RM control and free, plus allocate with `NVRM_ENUM_ALLOW_ALLOC`; the
enumeration descriptors never carry a mapping right). No GPU is a success with zero devices. The interface is provisional
until the first package release. A context is not thread-safe, and a forked child must only
`nvrm_close` it (see `nvrm(3)`). `nvrm-info [--json | --jsonl | --schema]` prints the result; the schema is
`lib/libnvrm/schema/nvrm-info-1.schema.json`, generated from the field table of the library, and
the build fails when it drifts. Man pages: `nvrm(3)`, `nvrm_mem(3)`, `nvrm(7)`, `nvrm-info(8)`. The build needs
the NVIDIA headers from `scripts/fetch-sources.sh`. Tests: `sh tests/libnvrm_test.sh`.

GPU memory (`nvrm_mem(3)`, API minor 1, symbol version `NVRM_1.1`) is what NVK and a native CUDA
runtime build on. `nvrm_client_open()` makes a client for one GPU: its own RM session, its own GPU
virtual address space (the library hands out the addresses), and every object made through it.
On it: VA reservations (sparse or not), video and system memory with a chosen page size (4 KiB,
64 KiB, 2 MiB, 512 MiB), registered user pages, GPU mappings at fixed addresses, CPU mappings,
and sharing by descriptor (export, import). CPU mapping needs `NVRM_OPEN_ALLOW_MAP`: the client then
opens spare descriptors of this GPU's own device node (`/dev/nvidiaN`, N reported by the driver), so
it keeps working after `cap_enter()`; each CPU mapping or export uses one. The
CPU attribute of a mapping follows the rule in `nvrm(7)` (on arm64, video memory is Device unless the
OS layer says write-combining is safe); `nvrm_mem_read()` and `nvrm_mem_write()` obey it. A release the
RM refuses is counted (`failed_releases`) and its addresses are never reused. The fake backend is a
software GPU (video and system memory in one shared object, a VA table, sparse reads), so the whole
API is tested without hardware; the RM backend is tested against a scripted kernel
(`tests/libnvrm/rm_mem_test.c`).

## Native test boot (no Linux layer)

`tests/native-tools-testboot/` builds a one-shot boot environment,
`nvidia-native-tools-test-YYYYMMDD-N`. It measures the card with native FreeBSD tools only:

- `linux_enable="NO"`;
- no Linuxulator or LinuxKPI module (amdgpu and drm are stripped from `kld_list` and blocked in
  devmatch);
- only the GSP firmware module, `nvidia.ko` and `nvidia-modeset.ko` of main, none of which has a
  Linux dependency since #2363;
- `gpu-detect.sh` and `nvrm-info` traced under `ktrace`, so that every file they execute is checked.

The environment check fails when a loaded file other than the kernel, or a module record in such a
file, has a Linux-layer name listed by `guard_layer_name`, or when `compat.linux` answers. Module
records built into the kernel file are only reported. A failed environment check makes every row
`not-available` and the verdict `fail`. A traced tool fails its row when it executes a non-FreeBSD binary,
calls `fexecve`, or calls `execve` with no path. A correct run on current main ends with the verdict
`incomplete`: some rows are `not-available`, `needs-linux` or `needs-linuxkpi`. Without the optional
UVM and DRM control modules their rows are `not-available`; the known Linux-dependent controls make
the uvm rows `needs-linux` and PRIME `needs-linuxkpi`. Results are `summary.json` (schema
`native-tools-summary/1`) plus per-tool JSON. See
[tests/native-tools-testboot/ROWS.md](tests/native-tools-testboot/ROWS.md) for the rows, the
statuses, the files and the build, check and arm commands. `sh tests/native_tools_kit_test.sh`
tests the kit without a boot.

What the `nvrm-info` row expects of the board. `boot_nvrm_info.sh` requires three environment
variables; `make-be.sh` always writes them to `rc.conf.d` from its options, whose defaults are the
amp001 board (the 16 GiB RTX 5060 Ti; the values are in `tests/libnvrm/board-amp001.env`, the one
place that states them). The comparison is `tests/libnvrm/boot_compare.py`, which refuses a reserve
the boot would reject, as `make-be.sh` does:

- `-V` (`BOOT_EXPECT_VRAM_BYTES`, default 17179869184): the nominal VRAM in bytes, 0 for a
  unified-memory part;
- `-R` (`BOOT_EXPECT_VRAM_RESERVE_MAX_BYTES`, default 268435456): the most the driver may reserve
  of it, below `-V` unless `-V` is 0. The RM reports the usable size (17103323136 on that card),
  which must lie between nominal less the reserve and nominal;
- `-S` (`BOOT_EXPECT_SM`, default 12.0): the compute capability. It is compared with
  `compute_capability_major/minor`, not with the RM's own SM numbering (10.4 on that card).

The GPU uuid is found through the device unit whose `dev.nvidia.<unit>.pci_bus_id` is the device's
PCI location (000d:01:00.0 on amp001; the units are not nvrm-info's indexes: a BMC display can take
unit 0). When the unit was found that way (a module with the new sysctls),
`dev.nvidia.<unit>.uuid` is required and must equal the nvrm-info uuid, as must
`hw.nvidia.gpus.<unit>.uuid`. When it was found only through `dev.nvidia.<unit>.%location` (an older
module), only `hw.nvidia.gpus.<unit>.uuid` is required. A `pci_bus_id` that is present but not
`dddd:bb:ss.f` in lowercase hex is a FAIL of its own ("malformed"), and the `%location` fallback is
still tried. `versions.driver` must equal
`hw.nvidia.version_major`, `_minor` and `_patch` as integers, with `hw.nvidia.version_available`
1 and the string equal to the pinned tag; `running_rm_version` must equal it.
`sh tests/libnvrm/boot_fixture_test.sh` runs the comparison on the real capture of the first boot
(`tests/data/nvrm-info-boot-20261122T095018Z`, which must fail), on a derived fixture (which must
pass) and on mutations of it. It makes its scratch directory (default `tmp/` of the checkout) when
it is missing; its exit status is the number of failures, or 99 when it cannot make the directory.

## Native CUDA toolchain (cuda-native)

`lib/cuda-native/` is the first piece of native CUDA (Track #2380, stage C1.1 #2425). It holds the
SDK tree that clang takes as `--cuda-path`. Its headers are written from the public CUDA
references and from what clang's CUDA runtime wrapper includes by name; no file of NVIDIA's CUDA
toolkit is used. The compiler is clang from the ports `llvm23` package (`pkg install llvm23`).
`sh lib/cuda-native/mksdk.sh obj/cuda-native` builds the tree. Then
`/usr/local/llvm23/bin/clang++ -x cuda --cuda-path=obj/cuda-native --cuda-gpu-arch=sm_121 --cuda-device-only -S -o x.ptx x.cu`
emits PTX for the GB10, and `sm_120` emits it for the RTX 50 series (`sm_120a` and `sm_121a` work too).
The stub `ptxas`/`fatbinary` tools and `libcudart` let clang fully compile and link, but every launch returns `cudaErrorNotSupported` (801); the libdevice math library, real compiler and runtime, device execution and `libcuda` are not there yet.
Man page: `cuda-native-toolchain(7)`. Tests: `sh tests/cuda_native_toolchain_test.sh` (skips
without LLVM 23).

## libcuda (native CUDA Driver API)

`lib/libcuda/` builds `libcuda.so.1` from NVIDIA's public API documentation, with 16 device, context, error and entry-point calls.
The default `nvrm` provider is a stub; `CUDA_NATIVE_BACKEND=fake` selects synthetic devices without hardware.
`CUDA_NATIVE_FAKE_PROFILE=gb206,gb10` selects both fake profiles; `CUDA_VISIBLE_DEVICES` filters and reorders them.
`cuda-native-info [--json | --jsonl | --schema]` reports versions and devices; its schema is under `lib/libcuda/schema/`.
The C/C++ header is `lib/cuda-native/sdk/include/cuda.h`; manuals are `libcuda(3)` and `cuda-native-info(1)`.
Tests run against the git index, not the working tree: run `git add` first.
Run `TMPDIR=/path/to/existing/scratch sh tests/libcuda_test.sh`; the directory must already exist.

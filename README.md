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

## Installation

Use the `agent/2088-build-host` branch; `main` is behind.

### 1. What you need

- FreeBSD 16.0-CURRENT on arm64, and the source for the kernel you are running
  (`/usr/src/sys` by default; `SYSDIR=` to override).
- An RTX 30-series or newer GPU (Ampere generation or later). Turing (RTX 20) is not supported
  yet.
- `pkg install git gmake zstd`. Use the base system's `clang` and `ld.lld`. The scripts here
  set their own `PATH` with `/usr/bin` ahead of `/usr/local/bin`. When you build a module by
  hand, keep `/usr/bin` first too: with binutils' GNU `ld` from `/usr/local/bin` the module
  builds but will not load.
- For `nvidia-drm`: the drm-kmod source tree the installed `drm.ko` was built from
  (`DRMKMODDIR=`, an absolute path), and the FreeBSD source headers (`BSDSRCTOP=`, the parent
  of `SYSDIR` by default).
- A host with an Ampere Altra CPU (not to be confused with the GPU generation) needs PCIe
  workarounds in the kernel. They are in a separate kernel tree, not in this repository; ask
  for it when you report (see the end of this section). Other arm64 machines do not need them.

### 2. Get the code and sources

As a normal user. Work files go under `~/work/gb10`, or under `GB10_WORK=` (an absolute path).

```sh
git clone -b agent/2088-build-host https://github.com/cloudbsdorg/nvidia-gb10-freebsd.git
cd nvidia-gb10-freebsd
sh scripts/fetch-sources.sh      # NVIDIA FreeBSD tarball + open-gpu-kernel-modules, checked against SOURCES
sh scripts/prepare-tree.sh       # prints "prepare-tree: .../build/tree ready"
```

### 3. Build, in this order

Run the commands one at a time and check each one's result before the next.

```sh
sh scripts/build-rmcore.sh
sh scripts/build-shim.sh; echo $?    # pass 1: expected to fail and print 3, see below
sh scripts/build-stubs.sh        # prints "still undefined vs OS layer: 0"
sh scripts/build-shim.sh         # pass 2: prints "build: OK"
sh scripts/build-firmware.sh
sh scripts/build-rmcore.sh --core=nvidia-modeset
sh scripts/build-shim.sh --module=nvidia-modeset
DRMKMODDIR=/path/to/drm-kmod sh scripts/build-shim.sh --module=nvidia-drm
sh tests/kmod_symbols_test.sh
```

Pass 1 has no arm64 RM core to link yet, so it must fail exactly like this, and the script
must exit 3 (the `rc 1` in its last line is make's status, not the script's):

```
errors: 1
ld: error: nv-kernel.o is incompatible with aarch64elf
build: FAILED (make rc 1)
```

Any other error, or any other failing step, means stop and report it (see the end of this
section). The modules land under `$GB10_WORK/build/tree/`: `nvidia/nvidia.ko`,
`nvidia-modeset/nvidia-modeset.ko`, `nvidia-drm/nvidia-drm.ko` and
`firmware/gsp_ga10x/nvidia_gsp_ga10x_fw.ko`. The [Build](#build) section explains each step.

### 4. Test-load safely (root)

Work over SSH or a serial console: once the driver loads, a monitor on the NVIDIA card goes
dark until a program (Xorg, or another KMS client) sets a mode on it. A console on another GPU
is not affected.

Use a one-shot boot environment, so that a panic reboots into your normal one. The second
setting keeps a GENERIC kernel from stopping in the debugger instead of rebooting. A hang that
does not panic still needs a power cycle; the one-shot boot environment then still brings back
your normal one.

```sh
bectl create nvidia-test
bectl mount nvidia-test /mnt
printf '%s\n' 'kern.panic_reboot_wait_time="5"' 'debug.debugger_on_panic="0"' >> /mnt/boot/loader.conf
bectl umount nvidia-test
bectl activate -t nvidia-test
shutdown -r now
```

In that boot environment, as root. `T` is the `GB10_WORK` of the user who built the modules
(`~/work/gb10` by default); replace `YOUR_USER`. These commands load files that user owns, so
that user must be trusted with root:

```sh
T=/home/YOUR_USER/work/gb10
kenv hw.nvidia.registry.EnableGpuFirmware=1
kldload $T/build/tree/firmware/gsp_ga10x/nvidia_gsp_ga10x_fw.ko
kldload $T/build/tree/nvidia/nvidia.ko            # also loads linux64 and linux_common, for now
kldload $T/build/tree/nvidia-modeset/nvidia-modeset.ko
kldload $T/build/tree/nvidia-drm/nvidia-drm.ko    # last
```

### 5. Check it worked

```sh
kldstat                  # the four modules, plus linux64, linux_common, drm and its linuxkpi modules
dmesg | tail             # nvidia0: <NVIDIA ...> on vgapci0
ls /dev/nvidia*          # /dev/nvidia0 /dev/nvidiactl
sleep 30 < /dev/nvidia0 &   # hold the device open: the GPU and GSP start on the first open
sysctl hw.nvidia.gpus.0  # firmware and VBIOS versions, while the device is held open
```

### 6. Load at boot

First reboot back into your normal boot environment (the one-shot one is gone after a reboot;
`bectl list` shows `NR` on the active one). Keep a copy of it to boot back into if the
boot-time load fails, then install the modules as root-owned files:

```sh
bectl create pre-nvidia
T=/home/YOUR_USER/work/gb10
install -o root -g wheel -m 555 \
    $T/build/tree/firmware/gsp_ga10x/nvidia_gsp_ga10x_fw.ko \
    $T/build/tree/nvidia/nvidia.ko \
    $T/build/tree/nvidia-modeset/nvidia-modeset.ko \
    $T/build/tree/nvidia-drm/nvidia-drm.ko /boot/modules/
kldxref /boot/modules
sysrc kld_list+="nvidia_gsp_ga10x_fw nvidia nvidia-modeset nvidia-drm"   # once: += appends
grep -q '^hw.nvidia.registry.EnableGpuFirmware=' /boot/loader.conf ||
    echo 'hw.nvidia.registry.EnableGpuFirmware="1"' >> /boot/loader.conf
```

`kld_list` loads in the order given. `nvidia.ko` reads `hw.nvidia.registry.*` from the kernel
environment when it loads, so the `loader.conf` line takes effect for a `kld_list` load.

### What works and what does not

In short (details in the [status table](#what-works-status-2026-11-20) below):

- KMS and Xorg modesetting work, with software rendering only.
- `nvidia-smi` runs through the Linuxulator: `sh scripts/fetch-nvidia-smi.sh`, plus
  `linux_base-rl9`; see [nvidia-smi](#nvidia-smi).
- CUDA and Vulkan work only through NVIDIA's Linux libraries under the Linuxulator. CUDA also
  needs `nvidia-uvm.ko` from [cloudbsdorg/uvm-bsd](https://github.com/cloudbsdorg/uvm-bsd)
  (private; ask for access when you report), built per its README, and Linuxulator additions
  that are in the cloudbsd-src kernel, not in a stock one. Native versions are in progress.
- There are no published packages yet.
- To report a problem, open an issue at
  <https://github.com/cloudbsdorg/nvidia-gb10-freebsd/issues> with the failing step's output,
  `dmesg` and `uname -a`.

## What works (status 2026-11-20)

| | Status |
|---|---|
| `nvidia.ko` loads and attaches to the GPU; GSP firmware boots | works |
| `nvidia-modeset.ko` and `nvidia-drm.ko` load | works |
| Display (DRM/KMS on the NVIDIA card: mode set, scan-out) | works: colour bars on `/dev/dri/card1`; Xorg modesetting at 2560x1440 on HDMI, software rendering only |
| CPU writes to a dumb buffer in video memory | works: written data reads back through a fresh `mmap` |
| `nvidia-smi` (NVIDIA's Linux arm64 build, through the Linuxulator) | works |
| Vulkan (NVIDIA's Linux arm64 ICD, through the Linuxulator) | works (numbers below) |
| CUDA (NVIDIA's Linux `libcuda`, through the Linuxulator) | works, with the prerequisites below |
| Wayfire on the NVIDIA output | not yet: Wayfire runs on the other GPU and the NVIDIA output stays blank. It needs cross-GPU import. The kernel no longer panics: a framebuffer without NVIDIA memory is refused with `EINVAL` |
| Cross-GPU buffer import (PRIME: render on another GPU, show on the NVIDIA card) | not merged yet; see Track #2228 |
| Accelerated native rendering (Mesa NVK over a render interface in `nvidia-drm`) | not started: only the interface contract exists ([`nvidia-drm-render.h`](src/nvidia-drm-render/nvidia-drm-render.h), [nvidia_drm_render(4)](man/nvidia_drm_render.4)) |
| Vulkan (NVIDIA's Linux arm64 ICD, through the Linuxulator) | fix committed (3414fd7), waits for test boot 6 |
| Cross-GPU buffer import (PRIME) of system-memory buffers | implemented (#2228), waits for a test boot; see [Cross-GPU buffers](#cross-gpu-buffers-prime-import) |
| CUDA | does not work yet: needs `nvidia-uvm` (clean-room module in progress) |

Tested on one machine so far: an Ampere Altra running FreeBSD 16.0-CURRENT with a GeForce RTX
5060 Ti (GB206). Not tested yet: DGX Spark (GB10), other arm64 machines, other GPUs, amd64.

**CUDA prerequisites.** `libcuda` needs `/dev/nvidia-uvm`, which NVIDIA does not ship for
FreeBSD. It comes from the clean-room module
[uvm-bsd](https://github.com/cloudbsdorg/uvm-bsd) (tested at commit 256297e). It also needs
Linuxulator additions in the kernel: the `/proc` files `libcuda` reads, and Linux abstract
UNIX sockets. Those are in the cloudbsd-src tree, not here (Track #2101).

**Numbers.** Measured with llama.cpp b12531 (`llama-bench`, defaults otherwise), in tokens per
second. pp512 is the prompt-processing speed over a 512-token prompt, and tg128 the generation
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

The earlier fixes (the arm64 BAR mapping and the `SIGBUS` on the first Vulkan register read)
are under [Memory attributes on arm64](#memory-attributes-on-arm64). The CUDA start-up fix is
in uvm-bsd's README, under "Status".

Example, on that machine:

```
NVIDIA-SMI 580.178.04             Driver Version: 580.178.04     CUDA Version: N/A
  0  NVIDIA GeForce RTX 5060 Ti     Off |   0000000C:01:00.0 Off |                  N/A
 47%   30C    P0             13W /  180W |       0MiB /  16311MiB |      3%      Default
```

### Kernel

`nvidia.ko` needs no kernel change: its symbols resolve against a stock 16.0-CURRENT kernel plus
`linux64.ko` and `linux_common.ko`. An **Ampere Altra** does need kernel workarounds for its PCIe
(32-bit configuration reads, emulation of misaligned device accesses); those are kernel
changes kept in a separate kernel tree, not here. Other arm64 machines should not need them.

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
- For `nvidia-smi`: the Linuxulator (`linux64.ko`, loaded automatically by `nvidia.ko`) and
  `linux_base-rl9`.
- An Ampere-generation or newer GPU (RTX 30 series and later, and data-centre parts of the
  same generations). Those run the `gsp_ga10x` firmware this repository builds; Turing needs
  `gsp_tu10x`, which is not built yet.

## Build

As an ordinary user, from the repository root. Work files go under `GB10_WORK` (default
`~/work/gb10`); nothing is written to `/tmp`.

```sh
sh scripts/fetch-sources.sh      # NVIDIA FreeBSD tarball + open-gpu-kernel-modules, checked against SOURCES
sh scripts/prepare-tree.sh       # NVIDIA's FreeBSD OS layer with patches/ applied
sh scripts/build-rmcore.sh       # NVIDIA's open RM core, compiled for aarch64
sh scripts/build-shim.sh         # first pass: compiles the OS layer; the link fails here, expected (see below)
sh scripts/build-stubs.sh        # links the fail-closed stubs onto the core; "still undefined vs OS layer: 0"
sh scripts/build-shim.sh         # second pass: nvidia.ko; prints "build: OK" and its sha256
sh scripts/build-firmware.sh     # nvidia_gsp_ga10x_fw.ko, the GSP firmware module
sh scripts/build-rmcore.sh --core=nvidia-modeset   # NVIDIA's open modeset core, compiled for aarch64
sh scripts/build-shim.sh --module=nvidia-modeset   # nvidia-modeset.ko; prints "build: OK" and its sha256
DRMKMODDIR=~/rx7600/drm-kmod sh scripts/build-shim.sh --module=nvidia-drm   # nvidia-drm.ko
sh tests/kmod_symbols_test.sh    # every undefined symbol resolves as the kernel linker will resolve it
```

`build-shim.sh` runs twice because `build-stubs.sh` checks the core against the compiled OS
layer: on the first pass there is no arm64 core yet, so it links NVIDIA's x86-64 `nv-kernel.o`
and fails. The first pass is right only if it exits 3 and its summary is exactly

```
errors: 1
ld: error: nv-kernel.o is incompatible with aarch64elf
build: FAILED (make rc 1)
```

Any other error, or more than one, is a real failure: stop there. (One script for the whole build is on the to-do list.) This order was checked from a
clean checkout against a stock `/usr/src`.

The two `nvidia-modeset` steps build NVIDIA's open modeset core (the same MIT sources as the
RM core, `src/nvidia-modeset` instead of `src/nvidia`) and link it into `nvidia-modeset.ko`.
`nvidia-modeset.ko` calls six symbols in `nvidia.ko`, and a kernel module exports nothing
unless its Makefile names the symbol in `EXPORT_SYMS`; `patches/patch-nvidia_Makefile` does
that for arm64. `tests/kmod_symbols_test.sh` checks that `nvidia.ko` really exports them.

The `nvidia-drm` step builds NVIDIA's own DRM/KMS module (the `nvidia-drm` directory of
NVIDIA's FreeBSD package) against drm-kmod. It needs two extra variables:

- `DRMKMODDIR`: the drm-kmod **source tree** the running `drm.ko` was built from. There is no
  default: the script refuses to build without it, and refuses one that is not an absolute
  path, is not a directory, or holds no `linuxkpi_version.mk`. The headers it generates
  must match the `drm.ko` that is loaded, or the module is built against the wrong LinuxKPI.
- `BSDSRCTOP`: the top of the FreeBSD source tree the module takes its headers from. It
  defaults to the parent of `SYSDIR`.

`nvidia-drm.ko` calls `nvidia_devclass` in `nvidia.ko` and eight `nvKmsKapi*` symbols in
`nvidia-modeset.ko`; those are exported by name on arm64
(`patches/patch-nvidia_Makefile` and `patches/patch-nvidia-modeset_Makefile`), and
`tests/kmod_symbols_test.sh` checks the whole chain: the declared dependency set is exactly
`dmabuf`, `drmn`, `linuxkpi`, `nvidia` and `nvidia-modeset`, and every undefined symbol
resolves against the kernel or against those modules' exported symbols - the way the kernel
linker resolves them.

The modules end up in `$GB10_WORK/build/tree/nvidia/nvidia.ko`,
`$GB10_WORK/build/tree/nvidia-modeset/nvidia-modeset.ko`,
`$GB10_WORK/build/tree/nvidia-drm/nvidia-drm.ko` and
`$GB10_WORK/build/tree/firmware/gsp_ga10x/nvidia_gsp_ga10x_fw.ko`.

If you point `SYSDIR` at a different kernel source, `build-shim.sh` notices: it records the
SYSDIR and its `__FreeBSD_version` in `TREE/<module>/.gb10-sysdir` and runs `make clean`
before the build when they changed. For `nvidia-drm` the stamp records `BSDSRCTOP` and
`DRMKMODDIR` as well: the module's objects are built against those two trees' headers, so a
changed one cleans them too.

## Load

As root. Try it first from a one-time boot environment (`bectl activate -t <BE>`) whose
`loader.conf` has `kern.panic_reboot_wait_time="5"`, so a panic reboots into your normal boot
environment.

```sh
kenv hw.nvidia.registry.EnableGpuFirmware=1
kldload $GB10_WORK/build/tree/firmware/gsp_ga10x/nvidia_gsp_ga10x_fw.ko
kldload $GB10_WORK/build/tree/nvidia/nvidia.ko    # also loads linux64 and linux_common
kldload $GB10_WORK/build/tree/nvidia-modeset/nvidia-modeset.ko
kldload $GB10_WORK/build/tree/nvidia-drm/nvidia-drm.ko
dmesg | tail                                      # nvidia0: <NVIDIA ...> on vgapci0
ls /dev/nvidia*                                   # /dev/nvidia0 /dev/nvidiactl
```

`nvidia.ko` depends on the GSP firmware module for its architecture: `nvidia_gsp_ga10x_fw`
(Ampere other than GA100, Ada, Hopper, Blackwell; every architecture) and, on amd64 only,
`nvidia_gsp_tu10x_fw` (Turing and GA100). Once they are installed next to it and `kldxref` has
indexed the directory (step 6), `kldload nvidia` loads them first, as root, so the first open of
the GPU by an unprivileged process finds the firmware already registered. The kernel names the
module after the file with `_fw` appended (`nvidia_gsp_ga10x_fw_fw` in `kldstat -v`); a
firmware module cannot be unloaded while `nvidia` is loaded. Loading from the build tree by
path, as above, works because a dependency that is already loaded is accepted; keep the firmware
`kldload` line first. If `kldload` says `depends on nvidia_gsp_ga10x_fw_fw - not available`, the
module is not installed or `kldxref` was not run. See `man/nvidia.4`.

The GPU is initialised, and GSP booted, on the first open of `/dev/nvidia0`; it is shut down
again when the last open closes. `sysctl hw.nvidia.gpus.0` shows the firmware and VBIOS
versions while something holds the device open.

If that first open fails (`nvidia0: NVRM: rm_init_adapter() failed!` in `dmesg`, and the
program gets `EIO`), the driver frees what the open took and the open can be tried again. See
`man/nvidia.4`.

`nvidia-drm.ko` goes last: it drives the DRM/KMS side of the card and needs the modeset
module loaded before it.

Loading the driver takes the display hardware over from the UEFI framebuffer, so a monitor on the
NVIDIA card goes dark until `nvidia-modeset` and `nvidia-drm` are loaded and a program sets a
mode on the card's DRM device. A console or desktop on another GPU is not affected.

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
`SIGBUS` (`BUS_OBJERR`). That was the Vulkan crash, fixed in 3414fd7.

On the Altra, Normal memory accesses to PCIe BARs are not safe (the root complex mishandles
some of them), so write-combining requests fall back to Device-nGnRE there as well. The
FreeBSD kernel tree applies the same rule to its own write-combining mappings, Device for the
kernel and Normal non-cacheable for user processes. `nvidia.ko` applies its table to the
mappings it makes itself, the kernel ones and the user ones alike.

## Video memory and fictitious pages (nvidia-drm)

A program draws into a dumb buffer by `mmap`ing it from the DRM device. For a buffer in video
memory the mapping points into BAR1. `nvidia-drm` is built against linuxkpi, and linuxkpi maps
a page frame through its `struct vm_page`. A PCIe BAR has no `vm_page`s unless someone
registers a fictitious range for it; ttm does that for its VRAM aperture, NVIDIA's FreeBSD
code never did. Without one, `vmf_insert_pfn` fails, linuxkpi's pager returns `VM_PAGER_BAD`,
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
opposite test in the two worlds. A FreeBSD-style alignment check in `nvidia-drm` rejected every
video-memory window as "not page aligned", and no dumb buffer could be created. In FreeBSD-only
code that includes linuxkpi headers, test alignment with `addr & (PAGE_SIZE - 1)`. `nvidia.ko`
is native FreeBSD code, where `PAGE_MASK` means what FreeBSD says.
`tests/drm_fault_index_test.sh` fails if the registration code tests `& PAGE_MASK` again.

## Cross-GPU buffers (PRIME import)

A buffer another GPU rendered into (the RX 7600 on amp001, through `amdgpu`) can be imported by
`nvidia-drm` when it is **system memory**. NVIDIA's FreeBSD driver never had this: its OS layer
answered every dma-buf import with "not supported" and then `nvidia-drm` handed the KAPI a NULL
handle (the panic that [`18fa11d`](patches/patch-nvidia-drm_nvidia-drm-fb.c) turned into
`EINVAL`). The design, the exact failure chain and every decision are in
[`docs/PRIME-IMPORT.md`](docs/PRIME-IMPORT.md); the sources consulted are in
[`PROVENANCE.md`](PROVENANCE.md).

How it works, in one paragraph. `nvidia-drm` walks the buffer's scatter list and expands it to one
`vm_page` pointer per page; anything that is not a whole number of managed RAM pages (a partial
page, a buffer in the other card's video memory, an empty or over-4-GiB buffer, a list that
disagrees with the size) is refused with `EINVAL` and a line in the log saying why, and the GEM
object is created without an NVKMS handle, so it cannot become a framebuffer (the guard of #2228
answers `ADDFB2` with `EINVAL`). Otherwise `nvidia.ko` wires the pages (`nv_import_pages()`) and
the new KAPI entry `getSystemMemoryHandleFromPageArray()` gives them to the RM as a write-back
page-array descriptor; the RM's own teardown unwires and frees them. The export ioctl always goes through the SGT entry points (`nv_register_sgt()` and friends, which
used to be stubs that returned success and filled nothing) when the pages were imported, never
straight from the page-array handle: that holds no reference, and the SGT path holds the GEM
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

`vulkaninfo --summary` should list "NVIDIA GeForce RTX 5060 Ti". It has not done so yet: with
`nvidia.ko` older than 3414fd7 every Vulkan program dies with `SIGBUS` on its first read of the
USERMODE register window (see [Memory attributes on arm64](#memory-attributes-on-arm64)). The
ioctl `0xc23046d7` failing with `EINVAL` ("unknown NVRM ioctl") in a `ktrace` is harmless.

## Running LLMs

How to run llama.cpp on this kind of machine (Vulkan on the AMD card, the numbers measured, and
splitting prefill and decode between two servers): [`docs/llm.md`](docs/llm.md).

## Repository layout

| Path | What |
|---|---|
| `SOURCES` | pins for NVIDIA's sources |
| `scripts/` | fetch, prepare and build steps; `lib.sh` holds the shared helpers; `pd_split.py`, the prefill/decode split client of [`docs/llm.md`](docs/llm.md) |
| `patches/` | one unified diff per changed file of NVIDIA's FreeBSD OS layer |
| `patches/ogkm/` | patches to the open-gpu-kernel-modules build for FreeBSD aarch64 |
| `src/gb10-stubs/` | fail-closed stubs for RM core functions the arm64 build lacks |
| `src/gb10-memattr/` | the memory-type policy for kernel mappings on arm64 |
| `src/nvidia-drm-render/` | `nvidia-drm-render.h`, the render uAPI of nvidia-drm: layouts and ioctl numbers for the kernel work packages and the Mesa `nvdrm` backend; MIT |
| `man/` | `nvidia_drm_render(4)`, the manual page of that interface |
| `docs/` | how-tos: [`llm.md`](docs/llm.md), running LLMs; [`RENDER-UAPI.md`](docs/RENDER-UAPI.md), the full semantics of the render uAPI |
| `tests/` | one `*_test.sh` per script, plus the ABI layout and symbol checks; `render_uapi_layout_test.sh` and `render_uapi_docs_test.sh` check the render uAPI header and its documents (`render_uapi_layout_test.sh` reads `SYSDIR`, a FreeBSD `src/sys` checkout for the kernel compile, and `RENDER_UAPI_ALLOW_SKIP=1` to accept a skipped check; both read `GB10_WORK` and `TMPDIR`); run each with `sh` |
| `src/gb10-pageimport/` | the pure core of the cross-GPU buffer import: scatter list to page array, wiring, the SGT entry points |
| `docs/` | how-tos: [`llm.md`](docs/llm.md), running LLMs; [`PRIME-IMPORT.md`](docs/PRIME-IMPORT.md), cross-GPU buffer import |
| `tests/` | one `*_test.sh` per script, plus the ABI layout and symbol checks; run each with `sh` |

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
capability mode (the descriptors keep RM control and free, plus allocate with `NVRM_ENUM_ALLOW_ALLOC`; this
version has no call that maps device memory). No GPU is a success with zero devices. The interface is provisional
until the first package release. A context is not thread-safe, and a forked child must only
`nvrm_close` it (see `nvrm(3)`). `nvrm-info [--json | --jsonl | --schema]` prints the result; the schema is
`lib/libnvrm/schema/nvrm-info-1.schema.json`, generated from the field table of the library, and
the build fails when it drifts. Man pages: `nvrm(3)`, `nvrm(7)`, `nvrm-info(8)`. The build needs
the NVIDIA headers from `scripts/fetch-sources.sh`. Tests: `sh tests/libnvrm_test.sh`.

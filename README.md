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

The GPU is initialised, and GSP booted, on the first open of `/dev/nvidia0`; it is shut down
again when the last open closes. `sysctl hw.nvidia.gpus.0` shows the firmware and VBIOS
versions while something holds the device open.

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

## RM client ownership for nvidia-uvm

**What and why.** The RM resolves a client handle with kernel privilege and never asks who
is calling, and handles are predictable (`0xC1D00000` is the first client of a boot). So
`nvidia.ko` records which open `/dev/nvidiactl` file each client was allocated on
(`src/gb10-client-owner/nv_client_owner.h`, hooked into `nvidia_handle_ioctl` and
`nvidia_close_ctl` by `patches/patch-zz-nvidia_client_owner_subr.c`) and exports two
functions for `nvidia-uvm.ko` (the clean-room UVM driver, nvidia-uvm-freebsd):

- `NV_STATUS nvUvmInterfaceClientHold(struct file *fp, NvHandle hClient)`: `NV_OK` only for a
  devfs character device `nvidiactl` file of this module that owns the client, otherwise
  `NV_ERR_INSUFFICIENT_PERMISSIONS`. On `NV_OK` the client is held: a free of it waits, and
  the file cannot close (the hold keeps its own file reference).
- `void nvUvmInterfaceClientRelease(struct file *fp, NvHandle hClient)`: call it exactly once
  per `NV_OK`, never after a refusal. Holds are per client and nest, so an RM call made under
  a hold delays only a free of that one client, not other users.

**Guarantees.** The table lock is a leaf lock: it is never held across an RM call (the RM can run
a file's close destructor, which takes it, from inside an RM call), so the table is updated after
the RM call returns and may lag it; every lag fails closed (an unrecorded new client is refused, a
reused handle leaves both parties unowned, the owner's own free keeps new holds out). A free of a
client first waits for the holds on it, before the ioctl takes any other lock. A client freed
through any file leaves the table, a closing file forgets its clients, and only a control file can
own one.

**Versions.** `nvidia.ko` is module version 2, and `nvidia-modeset.ko` and `nvidia-drm.ko` depend on
exactly that, as does `nvidia-uvm.ko` from uvm-bsd branch `agent/2373-uvm-client-ownership` or
later (its `MODULE_DEPEND` is in that repository). Updating `nvidia.ko` alone does not fix the
cross-user hole: an older `nvidia-uvm.ko` (depending on version 1) refuses to load against it
(module version mismatch), and the new one refuses an old `nvidia.ko`. If `kldload nvidia-uvm` fails (it
prints "an error occurred while loading module") and `dmesg` shows a version mismatch or
`symbol nvUvmInterfaceClientHold undefined` (or `...ClientRelease`), the loaded `nvidia.ko` was
built without the `patch-zz-nvidia_client_owner_*` patches, or a module of the set is from another
build (`kldload` fails with a `version mismatch` or `undefined` message in `dmesg`). Rebuild all four
modules (`nvidia`, `nvidia-modeset`, `nvidia-drm`, `nvidia-uvm`) from one tree made by
`scripts/prepare-tree.sh` and reload them together: `nvidia-modeset` and `nvidia-drm` depend on
version 2 as well, so replacing `nvidia.ko` alone also stops the display.

**A stuck free.** A free of a client waits for the holds on it, in an interruptible sleep with
wait channel `nvcobusy`, and every other ioctl on the same file waits behind it. `nvidia-uvm.ko`
takes a hold for one request and releases it when the request ends, so the wait is normally
short. A process that stays in `nvcobusy` means a hold was leaked, which is a bug in
nvidia-uvm-freebsd: a leaked hold lasts until reboot (killing the waiting process only ends
that one wait, and the client is never freed). A fatal signal, or a caught signal without
`SA_RESTART`, ends the wait (`EINTR`, nothing freed); a restartable signal waits again.
`ps -axo pid,wchan,comm | grep nvcobusy` finds the process. A console line
`nvUvmInterfaceClientRelease: no hold on client ... (nvidia-uvm bug)` is the opposite fault, a
release without a matching hold; quote it in the report if you see it (a debug kernel panics
with "client release without a matching hold" instead). A console line
`RM client 0x... was not recorded for nvidia-uvm` means the table and the RM disagreed about a
handle: nvidia-uvm refuses requests on that client until it is freed and allocated again. Only a free by the
client's owner stops new holds while it waits, so a stranger cannot starve the owner by freeing
its predictable handle. `nvUvmInterfaceClientHold` must be called from a sleepable context with
no RM lock held, never from an RM callback; the same goes for `nvUvmInterfaceClientRelease`.

**Tests.** `tests/client_owner_glue_test.sh` compiles the real glue (`src/gb10-client-owner/nvco_glue.h`)
against fakes of the kernel and runs it, with mutants that must fail. `tests/client_owner_test.sh` reads `GB10_WORK` (a directory with `sources/` holding the
pinned open-gpu-kernel-modules 580.178.04 checkout and the NVIDIA FreeBSD tarball) and `TMPDIR`;
without them the layout and prepare-tree checks are skipped (a failure under `CI` or
`REQUIRE_INPUTS`). It runs the table logic (layouts compared with the real `nvos.h`), checks the
patch hooks, and runs deliberately broken copies of the header and the patch that it must reject.

## Licence

Our scripts, patches and sources are BSD-3-Clause (see [`LICENSE`](LICENSE)). NVIDIA's code,
fetched at build time, keeps NVIDIA's licences: MIT for open-gpu-kernel-modules, NVIDIA's own
licence for the FreeBSD driver package and the firmware. `src/nvidia-drm-render/nvidia-drm-render.h`
is MIT, because its layouts follow Mesa's MIT nouveau uAPI header and it is meant to be included by
NVIDIA's MIT nvidia-drm sources and by Mesa. Provenance: [`PROVENANCE.md`](PROVENANCE.md).

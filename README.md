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

## What works

| | Status |
|---|---|
| `nvidia.ko` loads and attaches to the GPU | works |
| GSP firmware module (`nvidia_gsp_ga10x_fw.ko`), GSP boots | works |
| `nvidia-modeset.ko` and `nvidia-drm.ko` load | works |
| Display (DRM/KMS on the NVIDIA card: mode set, scan-out) | works: 1920x1080 colour bars on `/dev/dri/card1` |
| CPU writes to a dumb buffer in video memory | works: written data reads back through a fresh `mmap` |
| `nvidia-smi` (NVIDIA's Linux arm64 build, through the Linuxulator) | works |
| Vulkan (NVIDIA's Linux arm64 ICD, through the Linuxulator) | works: `vulkaninfo` lists the card; llama.cpp runs on it ([`docs/llm.md`](docs/llm.md)) |
| CUDA | not yet: `nvidia.ko` exports the UVM interface (below) and the clean-room `nvidia-uvm.ko` (uvm-bsd) loads and passes its ioctl tests; with the shim of [`docs/llm.md`](docs/llm.md#cuda-linux-libcuda-through-the-linuxulator) Linux `libcuda` runs cuInit, context, copies and a PTX kernel |

Tested on one machine so far: an Ampere Altra running FreeBSD 16.0-CURRENT with a GeForce RTX
5060 Ti (GB206). Not tested yet: DGX Spark (GB10), other arm64 machines, other GPUs.

The display and dumb-buffer results are from test boot 5 (2026-11-19): `nvidia-drm` at
8f16409, a 1920x1080 colour-bar buffer on `/dev/dri/card1` read back with 0 bad samples.

Vulkan reached the driver on 2026-11-19 and then died with `SIGBUS` on its first load from a
GPU register page; the cause and fix are under [Memory attributes on arm64](#memory-attributes-on-arm64).
The fixed `nvidia.ko` has not been booted yet.

CUDA (NVIDIA's Linux `libcuda` under the Linuxulator) stops in `cuInit` for two reasons. The
first is two `/proc` files that FreeBSD's `linprocfs` does not have yet:
`/proc/sys/vm/mmap_min_addr` and `/proc/<pid>/task/<tid>/comm`. They are added in the
FreeBSD kernel tree, not here. The second, and the real blocker, is that `libcuda` needs
`/dev/nvidia-uvm` and its ioctl interface. NVIDIA's FreeBSD driver has no UVM module
(`nvidia_subr.c`: "UVM with faulting is currently not supported in this platform"). The only
implementation is NVIDIA's Linux `nvidia-uvm`, which this project does not use, so a
clean-room module is being written.

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
sh tests/linux_cuda_test.sh      # Linux CUDA test programs and shim: build, abstract-socket test; skips without LINUXROOT
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

The module itself lives in its own repository (`nvidia-uvm-freebsd`), written clean-room
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
| `src/gb10-uvm/` | the UVM interface of the OS layer: `nvUvmInterface*` exports, callback table, ISR hook |
| `docs/` | how-tos: [`llm.md`](docs/llm.md), running LLMs |
| `tests/cuda/` | Linux aarch64 CUDA test programs and the LD_PRELOAD shim ([`docs/llm.md`](docs/llm.md#cuda-linux-libcuda-through-the-linuxulator)); built by `scripts/build-linux-cuda.sh`, run by `scripts/run-linux-cuda.sh` |
| `tests/` | one `*_test.sh` per script, plus the ABI layout and symbol checks; run each with `sh` |

## Licence

Our scripts, patches and sources are BSD-3-Clause (see [`LICENSE`](LICENSE)). NVIDIA's code,
fetched at build time, keeps NVIDIA's licences: MIT for open-gpu-kernel-modules, NVIDIA's own
licence for the FreeBSD driver package and the firmware.

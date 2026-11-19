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
| `nvidia-smi` (NVIDIA's Linux arm64 build, through the Linuxulator) | works |
| CUDA | not yet: `nvidia.ko` now exports the UVM interface (below); the clean-room `nvidia-uvm.ko` is in progress |
| `nvidia-modeset.ko` (display output from the NVIDIA card) | builds, not loaded yet |
| `nvidia-drm.ko` (DRM/KMS on the NVIDIA card) | builds, not loaded yet |

Tested on one machine so far: an Ampere Altra running FreeBSD 16.0-CURRENT with a GeForce RTX
5060 Ti (GB206). Not tested yet: DGX Spark (GB10), other arm64 machines, other GPUs.

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

On the Altra the driver also maps write-combining BARs as Device memory; it decides this itself
from the ACPI MCFG table and reports it in `hw.nvidia.altra_device_wc_active`.

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
kldload $GB10_WORK/build/tree/nvidia-modeset/nvidia-modeset.ko   # not tried yet
kldload $GB10_WORK/build/tree/nvidia-drm/nvidia-drm.ko           # not tried yet
dmesg | tail                                      # nvidia0: <NVIDIA ...> on vgapci0
ls /dev/nvidia*                                   # /dev/nvidia0 /dev/nvidiactl
```

The GPU is initialised, and GSP booted, on the first open of `/dev/nvidia0`; it is shut down
again when the last open closes. `sysctl hw.nvidia.gpus.0` shows the firmware and VBIOS
versions while something holds the device open.

`nvidia-drm.ko` goes last: it drives the DRM/KMS side of the card and needs the modeset
module loaded before it.

Loading the driver takes the display hardware over from the UEFI framebuffer, so a monitor on the
NVIDIA card goes dark until `nvidia-modeset` and `nvidia-drm` are loaded (both build, but
neither has ever been loaded). A console or desktop on another GPU is not affected.

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

## Repository layout

| Path | What |
|---|---|
| `SOURCES` | pins for NVIDIA's sources |
| `scripts/` | fetch, prepare and build steps; `lib.sh` holds the shared helpers |
| `patches/` | one unified diff per changed file of NVIDIA's FreeBSD OS layer |
| `patches/ogkm/` | patches to the open-gpu-kernel-modules build for FreeBSD aarch64 |
| `src/gb10-stubs/` | fail-closed stubs for RM core functions the arm64 build lacks |
| `src/gb10-memattr/` | the memory-type policy for kernel mappings on arm64 |
| `src/gb10-uvm/` | the UVM interface of the OS layer: `nvUvmInterface*` exports, callback table, ISR hook |
| `tests/` | one `*_test.sh` per script, plus the ABI layout and symbol checks; run each with `sh` |

## Licence

Our scripts, patches and sources are BSD-3-Clause (see [`LICENSE`](LICENSE)). NVIDIA's code,
fetched at build time, keeps NVIDIA's licences: MIT for open-gpu-kernel-modules, NVIDIA's own
licence for the FreeBSD driver package and the firmware.

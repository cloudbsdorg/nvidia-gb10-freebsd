# Manual build for developers

Use [`make install`](../README.md#install) to install on a stock system. This document exposes
the individual build and test-load commands for driver development. Run each command from the
repository root and check its result before continuing.

## Requirements

- FreeBSD 16.0-CURRENT on arm64 or amd64, and the source for the running kernel
  (`/usr/src/sys` by default; override it with `SYSDIR=`). The RM core is built for the
  running architecture from open-gpu-kernel-modules 580.178.04 (`nv-kernel-aarch64.o` or
  `nv-kernel-amd64.o`). On amd64 the open core is still rebuilt; NVIDIA's prebuilt
  `nv-kernel.o` is not what the final `nvidia.ko` links. Kernel modules are linked with
  the base system's `ld.lld` (`/usr/bin` ahead of `/usr/local/bin`).
- An Ampere-generation or newer NVIDIA GPU (RTX 30 series and later, and data-centre parts of
  the same generations). Turing needs `gsp_tu10x`, which this build does not produce.
- `git`, `gmake` and `zstd`, plus the base system's `clang` and `ld.lld`:

  ```sh
  pkg install git gmake zstd
  ```

  Keep `/usr/bin` ahead of `/usr/local/bin` when invoking a build by hand. The scripts set that
  order themselves. A module linked with binutils' GNU `ld` can build successfully but fail to
  load.
- For `nvidia-drm`, the drm-kmod source tree from which the installed `drm.ko` was built
  (`DRMKMODDIR=`, an absolute path) and the FreeBSD source headers (`BSDSRCTOP=`, the parent of
  `SYSDIR` by default). On amd64 that `drm.ko` comes from FreeBSD's drm-kmod packages
  (`pkg install drm-kmod`); this tree does not build its own. On arm64 the build produces
  `drm.ko` and `dmabuf.ko` from the pinned drm-kmod sources unless a foreign `drm.ko` is
  already installed.
- An Ampere Altra host needs the PCIe workarounds in
  [`kernel-patches/README.md`](../kernel-patches/README.md). On every arm64 host, `nvidia-drm`
  needs the LinuxKPI write-combining change from the same guide. `nvidia.ko` alone needs neither
  change on a non-Altra host.

## Check out and choose the work root

The default work root is the `work/` directory of the checkout; `GB10_WORK` overrides it. The
commands below use the default, so you need not set anything. Run every command from the
checkout.

```sh
git clone https://github.com/cloudbsdorg/nvidia-gb10-freebsd.git
cd nvidia-gb10-freebsd
```

To keep the work root somewhere else, `export GB10_WORK=/absolute/path` before the first
command and again in each later shell. The paths below call the work root `work/`.

Fetch NVIDIA's FreeBSD driver tarball and open-gpu-kernel-modules, verify them against
`SOURCES`, then prepare the patched tree:

```sh
sh scripts/fetch-sources.sh
sh scripts/prepare-tree.sh
```

`prepare-tree.sh` prints `prepare-tree: .../build/tree ready` when the tree is complete.

## Build in order

```sh
sh scripts/build-rmcore.sh
sh scripts/build-shim.sh; echo $?    # pass 1: expected to fail and print 3
sh scripts/build-stubs.sh            # prints "still undefined vs OS layer: 0"
sh scripts/build-shim.sh             # pass 2: prints "build: OK"
sh scripts/build-firmware.sh
sh scripts/build-rmcore.sh --core=nvidia-modeset
sh scripts/build-shim.sh --module=nvidia-modeset
DRMKMODDIR=/path/to/drm-kmod sh scripts/build-shim.sh --module=nvidia-drm
sh scripts/build-shim.sh --module=nvidia-linux           # only to run Linux binaries
sh scripts/build-shim.sh --module=nvidia-modeset-linux   # only to run Linux binaries
sh tests/kmod_symbols_test.sh
```

The first `build-shim.sh` pass has no rebuilt open RM core to link yet. On arm64 the
tree still holds NVIDIA's prebuilt x86-64 `nv-kernel.o`, so the link must fail and the
script must exit 3, ending with exactly this summary (`make rc 1` is make's status, not
the script's):

```text
errors: 1
ld: error: nv-kernel.o is incompatible with aarch64elf
build: FAILED (make rc 1)
```

On amd64 that prebuilt object is an amd64 object, so pass 1 may link it and exit 0.
That is only a compile check: `build-stubs.sh` and the second `build-shim.sh` pass
still replace it with the open core (`nv-kernel-gb10.o`) before `nvidia.ko` is the
finished module. The second pass must print `build: OK`, and `readelf -p .comment`
on the module must name LLD.

Any other error, or a failure at any other step, means stop and investigate. The second pass
links `nvidia.ko`. `build-stubs.sh` checks the core against the compiled OS layer between the
two passes and links the fail-closed stubs onto the core.

The modeset commands build NVIDIA's open modeset core from `src/nvidia-modeset` and link
`nvidia-modeset.ko`. That module calls six symbols in `nvidia.ko`; a kernel module exports a
symbol only when its Makefile names it in `EXPORT_SYMS`. `patches/patch-nvidia_Makefile` makes
those exports, and `tests/kmod_symbols_test.sh` checks them.

The `nvidia-drm` command builds NVIDIA's DRM/KMS module against drm-kmod. `DRMKMODDIR` has no
manual-build default: the script rejects a missing or relative path, a non-directory, or a tree
without `linuxkpi_version.mk`. Its generated headers must match the `drm.ko` that will be
loaded. `BSDSRCTOP` supplies the FreeBSD headers and defaults to the parent of `SYSDIR`.

`nvidia-drm.ko` calls `nvidia_devclass` in `nvidia.ko` and eight `nvKmsKapi*` symbols in
`nvidia-modeset.ko`. The patches export them by name. The symbol test checks the declared
dependency set (`dmabuf`, `drmn`, `linuxkpi`, `nvidia` and `nvidia-modeset`) and resolves every
undefined symbol as the kernel linker will.

The modules land in:

- `work/build/tree/nvidia/nvidia.ko`
- `work/build/tree/nvidia-modeset/nvidia-modeset.ko`
- `work/build/tree/nvidia-drm/nvidia-drm.ko`
- `work/build/tree/firmware/gsp_ga10x/nvidia_gsp_ga10x_fw.ko`

`build-shim.sh` records `SYSDIR` and its `__FreeBSD_version` in
`TREE/<module>/.gb10-sysdir`. If either changes, it runs `make clean` before rebuilding. The
`nvidia-drm` stamp also records `BSDSRCTOP` and `DRMKMODDIR`, because changes to those headers
require clean objects too.

Additional development checks, with their documented input requirements, are:

```sh
sh tests/linux_cuda_test.sh
sh tests/pd_split_test.sh
sh tests/bench_compare_test.sh
sh tests/run-nv-vulkan_test.sh
sh tests/manpages_test.sh
```

## Test-load safely

Work over SSH or a serial console. Loading the driver takes the display over from the UEFI
framebuffer, so a monitor on the NVIDIA card stays dark until a KMS client sets a mode. A
console on another GPU is not affected.

Use a one-shot boot environment so a panic returns the machine to its normal environment. A
hang that does not panic can still require a power cycle. These commands are for a disposable
developer test boot:

```sh
bectl create nvidia-test
bectl mount nvidia-test /mnt
printf '%s\n' 'kern.panic_reboot_wait_time="5"' 'debug.debugger_on_panic="0"' >> /mnt/boot/loader.conf
bectl umount nvidia-test
bectl activate -t nvidia-test
shutdown -r now
```

In that boot environment, as root, from the checkout (`cd` to it first). Loading modules from
a work tree owned by a user, as root, trusts that user: whoever can write those files gets
kernel code execution. Do this only for a tree you built yourself.

`T` below is `GB10_WORK` when it is set in the root shell, else `work/` of the checkout. A
root shell opened with `su -` or a fresh login does not carry the `GB10_WORK` you built with:
set it to the same path in this root shell first (or set `T` yourself), and check the `T=`
line it prints before going on:

```sh
T=${GB10_WORK:-$(pwd)/work}; echo "T=$T"
kenv hw.nvidia.registry.EnableGpuFirmware=1
kldload "$T/build/tree/firmware/gsp_ga10x/nvidia_gsp_ga10x_fw.ko"
kldload "$T/build/tree/nvidia/nvidia.ko"
kldload "$T/build/tree/nvidia-modeset/nvidia-modeset.ko"
kldload "$T/build/tree/nvidia-drm/nvidia-drm.ko"
```

`nvidia.ko` depends on the architecture's GSP firmware module. Keep the firmware `kldload`
first when loading by path. Once the modules are installed together and `kldxref` has indexed
them, loading `nvidia` loads the firmware dependency automatically. The kernel displays the
firmware module as `nvidia_gsp_ga10x_fw_fw` in `kldstat -v`; it cannot be unloaded while
`nvidia` is loaded. If `kldload` reports that this dependency is unavailable, install the
firmware module beside `nvidia.ko` and run `kldxref /boot/modules`.

`nvidia-drm.ko` goes last because it needs the modeset module. `nvidia.ko` itself needs no
Linux layer. Linux CUDA, Vulkan and `nvidia-smi` additionally need both provider modules, which
load the Linuxulator:

```sh
kldload "$T/build/tree/nvidia-linux/nvidia_linux.ko"
kldload "$T/build/tree/nvidia-modeset-linux/nvidia_modeset_linux.ko"
```

Build the providers with the two `--module=nvidia-linux` and `--module=nvidia-modeset-linux`
commands above first. Skip them on a host that runs no Linux binaries.

## Check the result

```sh
kldstat
dmesg | tail
ls /dev/nvidia*
```

There is one `/dev/nvidiaN` node per GPU plus `/dev/nvidiactl`. Never assume a node number:
another NVIDIA GPU, a BMC, or attach order can change the NVIDIA, vgapci and DRM numbers. Find
each node's newbus parent and use `pciconf` to identify its PCI bus:

```sh
unset NV
units=$(sysctl -N dev.nvidia 2>/dev/null | sed -n 's/^dev\.nvidia\.\([0-9]*\)\.%parent$/\1/p')
for u in $units; do echo "/dev/nvidia$u $(pciconf -l "$(sysctl -n dev.nvidia.$u.%parent)")"; done
set -- $units
case $# in
0) echo "no nvidiaN attached: see dmesg | grep -i nvidia" >&2 ;;
1) NV=/dev/nvidia$1 ;;
*) echo "several NVIDIA GPUs: set NV to the node on the bus you want, from the list" >&2 ;;
esac
sleep 30 < "${NV:?no NVIDIA node chosen}" &
sysctl hw.nvidia.gpus
```

The GPU is initialised and GSP is booted on the first open of its device node; the last close
shuts it down. Holding the node open as above lets `hw.nvidia.gpus` report firmware and VBIOS
versions. If the first open fails with `NVRM: rm_init_adapter() failed!` and `EIO`, the driver
frees the open's resources and the open can be retried. See `man/nvidia.4`.

## Load at boot

Return to the normal boot environment after the one-shot test (`bectl list` marks the active
and next-boot environments). Keep a fallback environment, then install the modules as
root-owned files:

Run these as root from the checkout. They copy files from the user-owned work tree, which
trusts that user with root; install only a tree you built yourself. As above, `T` is
`GB10_WORK` when set in the root shell, else `work/` of the checkout. If you built with
`GB10_WORK` set, set it to the same path in this root shell first (or set `T` yourself), and
check the `T=` line it prints:

```sh
bectl create pre-nvidia
T=${GB10_WORK:-$(pwd)/work}; echo "T=$T"
install -o root -g wheel -m 555 \
    "$T/build/tree/firmware/gsp_ga10x/nvidia_gsp_ga10x_fw.ko" \
    "$T/build/tree/nvidia/nvidia.ko" \
    "$T/build/tree/nvidia-modeset/nvidia-modeset.ko" \
    "$T/build/tree/nvidia-drm/nvidia-drm.ko" /boot/modules/
kldxref /boot/modules
sysrc kld_list+="nvidia_gsp_ga10x_fw nvidia nvidia-modeset nvidia-drm"
grep -q '^hw.nvidia.registry.EnableGpuFirmware=' /boot/loader.conf || {
    [ -z "$(tail -c 1 /boot/loader.conf 2>/dev/null)" ] || echo >> /boot/loader.conf
    echo 'hw.nvidia.registry.EnableGpuFirmware="1"' >> /boot/loader.conf
}
```

The Linux provider modules are optional. Skip this step on a host that runs no Linux
binaries. To run them, build the providers (the two `--module=nvidia-linux` and
`--module=nvidia-modeset-linux` commands above), then, as root and with the same `T`:

```sh
install -o root -g wheel -m 555 \
    "$T/build/tree/nvidia-linux/nvidia_linux.ko" \
    "$T/build/tree/nvidia-modeset-linux/nvidia_modeset_linux.ko" /boot/modules/
install -o root -g wheel -m 555 rc.d/nvidia_linux /usr/local/etc/rc.d/nvidia_linux
kldxref /boot/modules
sysrc linux_enable=YES
sysrc nvidia_linux_mode=AUTO
```

`kld_list` loads in the order given. `nvidia.ko` reads `hw.nvidia.registry.*` from the kernel
environment when it loads, so the loader setting applies. The providers are deliberately not in
`kld_list`: `rc.d/nvidia_linux` loads them after the Linuxulator is available.

`linux_enable=YES` is needed only for Linux CUDA, Vulkan and `nvidia-smi`. In the default
`nvidia_linux_mode=AUTO`, the rc script loads a provider only when Linux is enabled and its
corresponding native module is loaded. `YES` loads both whenever the script runs; `NO` loads
neither. See `nvidia_linux(4)`.

# Native-tools test boot: rows and files

Track #2362. This one-shot boot environment measures the NVIDIA card with native FreeBSD tools only.
It loads no Linuxulator module and no LinuxKPI module, and it runs no Linux binary.

## What the boot environment is

- `nvidia-native-tools-test-YYYYMMDD-N`, cloned from `cloudbsd-rx7600`.
- In the clone, `make-be.sh` sets `linux_enable="NO"` and strips amdgpu, drm, nvidia and every
  `*linux*` entry from `kld_list`. It also blocks those drivers in devmatch, through rc.conf and
  the loader kenv. The AMD card therefore has no driver during this boot, and the console stays
  on the EFI frame buffer.
- `/boot/modules.nvnative-test` holds a build of nvidia-gb10-freebsd main without the Linux dependency
  (see #2363): `nvidia_gsp_ga10x_fw.ko`, `nvidia.ko` and `nvidia-modeset.ko`, plus `nvrm-info` and
  `libnvrm.so.1`. `make-be.sh` and `check-be.sh` refuse a module
  that depends on `linux*`, `drm*` or `dmabuf`, or that has undefined `linux_`, `lkpi_` or
  `linuxkpi_` symbols.

## Statuses

| status | meaning |
|---|---|
| pass, fail | the row ran natively and passed or failed |
| error | the row could not look; it counts as a failure, never as "found nothing" |
| info | a record, not a check. A planned check row (anything but done) that records info is an error |
| needs-linux | the tool needs the Linuxulator; the evidence is in the detail |
| needs-linuxkpi | the tool needs LinuxKPI or drm-kmod; the evidence is in the detail |
| not-available | the native tool or its evidence does not exist yet |
| not-run | the row was not reached: an earlier row failed. Either the rc script records it, or `summarize.py` fills it in for a planned row the run never wrote. A planned row that is missing while no row failed is an error |

A static row's evidence file may only say needs-linux, needs-linuxkpi or not-available: any other
status there is recorded as an error.

`summary.json` (schema `native-tools-summary/1`, `native-tools-summary.schema.json`) lists every
planned row with its status. It carries two verdicts:

- `native_verdict` covers the rows that ran. It is fail when any of them failed or hit an error.
- `verdict` covers the whole plan: fail when `native_verdict` is fail or the run did not finish,
  incomplete when any planned row is skipped, and pass only when every planned row passed.

## Rows, in order

| row | what |
|---|---|
| deadman | `shutdown -r +30` is pending; without it nothing is loaded |
| panic-settings | `kern.panic_reboot_wait_time=5`, `debug.debugger_on_panic=0`, read back |
| linux-enable | `linux_enable` is NO |
| env-before | the no-Linux guard (`guard.sh`) before anything is loaded. No loaded kld file other than the kernel may have a Linux-layer name: one containing `linux`, or with a part that starts with `lkpi`, `lindebugfs`, `linsysfs`, `linprocfs`, `drm`, `dmabuf`, `ttm`, `amdgpu`, `radeonkms` or `i915kms`. No loaded file other than the kernel may hold a module record of such a name. `compat.linux` must be an unknown oid. The listing must name `kernel` |
| env-before-kernel-records, env-loaded-kernel-records, env-after-kernel-records | info: the Linux-layer module records compiled into the kernel file itself, such as `uhub/usb_linux`, `lkpi_iic/iicbus` and `pci/lkpi_mlx5_core_pci_table` on the stock kernel. They are not loaded files and never fail the guard; the ko-native rows make sure nothing loaded uses them. `tests/data/native-tools-env-before-20261122T072752Z.kldstat` is a real listing with them |
| hash-* | each staged file equals its full sha256 |
| ko-native-nvidia, ko-native-nvidia-modeset | before loading, three checks. (1) The module declares no Linux-layer dependency (kldxref -d -v; same names as env-before). (2) It has no undefined `linux_`, `lkpi_` or `linuxkpi_` symbol (nm -u). (3) It imports no symbol that the `linuxkpi*.ko` and `lindebugfs.ko` beside the running kernel define, whatever its name (`__start_set_*` and `__stop_set_*` excepted). fail when one is found; error when kldxref or nm could not read a file. Either way, the module is not loaded |
| load-*, load | the GSP firmware first, then `nvidia.ko` and `nvidia-modeset.ko`, as root and by full path |
| env-loaded | the guard again; the listing must name `nvidia.ko` and `nvidia-modeset.ko` |
| gpu-node, root-open, gpu-verify | `gpu-detect.sh` (vendored from uvm-bsd) picks the card by PCI class, vendor and driver parent, never by `/dev/nvidia0`; root opens the node once; the driver confirms the opened node is the chosen card |
| gpu-detect-native | `gpu-detect.sh` ran under `ktrace -i -t cn`. Every file it executed (`pciconf`, `sysctl`, `awk` and the rest) must be FreeBSD-native, nothing may call kldload or kldunload, and no module may appear |
| nvidiactl-open, modeset-open | root opens `/dev/nvidiactl` and `/dev/nvidia-modeset` |
| nvrm-info | `tests/libnvrm/boot_nvrm_info.sh` runs `nvrm-info` (libnvrm, RM-direct) in every mode against the driver and compares it with sysctl (`hw.nvidia`, `dev.nvidia`), pciconf and what the board is (`make-be.sh -V -R -S`): the nominal VRAM and the most the driver may reserve (the reported VRAM must lie in nominal less reserve .. nominal), and the compute capability (compared with `compute_capability_major/minor`, not the RM's SM numbering). Per GPU: the uuid, found through the `dev.nvidia.<unit>.pci_bus_id` of the device's PCI location (a malformed one FAILs and `%location` is tried), must equal `hw.nvidia.gpus.<unit>.uuid` and `dev.nvidia.<unit>.uuid` (the latter required when the unit was found through `pci_bus_id`; a unit found only through `%location` needs only `hw.nvidia.gpus.<unit>.uuid`); `versions.driver` integers must equal `hw.nvidia.version_major/_minor/_patch` with `hw.nvidia.version_available` 1 and the string equal to the SOURCES tag, and `running_rm_version` must equal it (`tests/libnvrm/boot_compare.py`) |
| nvrm-info-native | the row ran under `ktrace -i -t cn`. Every file that a successful execve ran (the image and its interpreters) must be a FreeBSD-branded ELF or a #! script, at an absolute path that still exists; a relative or vanished path is an error. Any kldload or kldunload call fails the row |
| nvrm-info-no-new-module | no module appeared while it ran |
| uvm-ioctl-suite, uvm-owner-probe, uvm-owner-race | `make-be.sh -u` classifies the supplied `nvidia-uvm.ko`. A module that declares MODULE_DEPEND on linux64elf (linux on amd64) and linux_common, and registers a Linux ioctl handler, is needs-linux; with no module the rows are not-available. The detail holds the kldxref and nm evidence |
| prime-import | `make-be.sh -d` classifies the supplied `nvidia-drm.ko`; a drm-kmod module is needs-linuxkpi. With no module the row is not-available |
| render-uapi | not-available: main has the header and documents only |
| nvrm-s2-memory | not-available until libnvrm S2 (memory allocation and copy timing) is on main |
| env-after, env-after-delta | the guard a last time, and no module new since env-loaded |
| done | the run finished |

## Files of a run

The run is written to `/var/db/nvidia-native-tools-test/<stamp>/` in the boot environment: that is
the log root the rc one-shot has at boot (`nvidia_native_tools_testboot_work`). It is then copied
to the copy-out directory that `make-be.sh` wrote into the boot environment's
`/etc/rc.conf.d/nvidia_native_tools_testboot` when the environment was built
(`nvidia_native_tools_testboot_copyout`), and the copy lands in a new directory `<copy-out>/<stamp>/`
under it. That copy-out base is `<repo>/work/logs/native-tools-testboot` for a build that took the
default (the work root of the checkout, a non-root build), and `$GB10_WORK/logs/native-tools-testboot`
for a root build that set `GB10_WORK`. So a run is on the host in
`<repo>/work/logs/native-tools-testboot/<stamp>/`, or in `$GB10_WORK/logs/native-tools-testboot/<stamp>/`
for a root build: the run of the stamp `20261122T0537Z` is in
`<repo>/work/logs/native-tools-testboot/20261122T0537Z/`. The boot-time job does
not read `GB10_WORK`: it copies to the absolute path the build wrote. A run holds:

- `results.jsonl`: one `{"row","status","detail"}` per line.
- `summary.json` and `summary.txt`: the reading. The last line of `summary.txt` is PASS, FAIL or
  INCOMPLETE.
- `gpu-detect.json` and `gpu-verify.json`.
- `nvrm-info/`: `nvrm-info.json`, `nvrm-info.jsonl`, `results.txt`, and the sysctl and pciconf
  captures.
- `nvrm-info.kdump` and `nvrm-info.execs`: the trace and every executed file with its brand.
- `env-*.kldstat` and `env-*.compat-linux`, plus `dmesg-*.txt` and `rc.log`.
- `testboot-return.txt`, and `rc.log` again with the return in it: they are copied after the
  return. When the return reboots, the reboot may come first, and the full copies then stay in
  `/var/db/nvidia-native-tools-test/<stamp>/` of the test boot environment.

The copy is made as root into a new 0700 directory. Root refuses a copy-out path with a
symbolic link in it, enters the new directory and compares its physical path before writing.

## Build, check, arm

```sh
sudo sh tests/native-tools-testboot/make-be.sh -n N          # dry run: built, checked, not armed
sudo sh tests/native-tools-testboot/check-be.sh nvidia-native-tools-test-YYYYMMDD-N
sudo bectl activate -t nvidia-native-tools-test-YYYYMMDD-N   # arms the boot: the host REBOOTS into it at the next restart
```

Arming is the orchestrator's step: never while a Fable agent runs on the host, and only after
check-be.sh passed. The test boot reboots the host, and the kit returns it to `cloudbsd-rx7600`
by itself.

`sh tests/native_tools_kit_test.sh` tests the guard, the reading rule, `make-be.sh`, `check-be.sh`
and a foreground run of the rc one-shot with stubbed system commands. It needs no root and no
boot.

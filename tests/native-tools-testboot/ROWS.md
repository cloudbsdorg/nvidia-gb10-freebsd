# Native-tools test boot: rows and files

Track #2362. This one-shot boot environment measures the NVIDIA card with native FreeBSD tools only.
It loads no Linuxulator module and no LinuxKPI module, and it runs no Linux binary.

## What the boot environment is

- `nvidia-native-tools-test-YYYYMMDD-N`, cloned from `cloudbsd-rx7600`.
- In the clone, `make-be.sh` sets `linux_enable="NO"` and strips amdgpu, drm, nvidia and every
  `*linux*` entry from `kld_list`. It also blocks those drivers in devmatch, through rc.conf and
  the loader kenv. The AMD card therefore has no driver during this boot, and the console stays
  on the EFI frame buffer.
- `/boot/modules.nvnative-test` holds the staged build of nvidia-gb10-freebsd main (a682522 or
  later): `nvidia_gsp_ga10x_fw.ko`, `nvidia.ko` and `nvidia-modeset.ko`, none of which has a Linux
  dependency, plus `nvrm-info` and `libnvrm.so.1`. `make-be.sh` and `check-be.sh` refuse a module
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
| env-before | the no-Linux guard (`guard.sh`) before anything is loaded: no kld file or module name contains `linux`, `compat.linux` is an unknown oid; the listing must name `kernel` |
| hash-* | each staged file equals its full sha256 |
| load-*, load | the GSP firmware first, then `nvidia.ko` and `nvidia-modeset.ko`, as root and by full path |
| env-loaded | the guard again; the listing must name `nvidia.ko` and `nvidia-modeset.ko` |
| gpu-node, root-open, gpu-verify | `gpu-detect.sh` (vendored from uvm-bsd) picks the card by PCI class, vendor and driver parent, never by `/dev/nvidia0`; root opens the node once; the driver confirms the opened node is the chosen card |
| gpu-detect-native | `gpu-detect.sh` ran under `ktrace -i -t cn`. Every file it executed (`pciconf`, `sysctl`, `awk` and the rest) must be FreeBSD-native, nothing may call kldload or kldunload, and no module may appear |
| nvidiactl-open, modeset-open | root opens `/dev/nvidiactl` and `/dev/nvidia-modeset` |
| nvrm-info | `tests/libnvrm/boot_nvrm_info.sh` runs `nvrm-info` (libnvrm, RM-direct) in every mode against the driver and compares it with sysctl, pciconf and the board's stated VRAM and SM (`make-be.sh -V -S`) |
| nvrm-info-native | the row ran under `ktrace -i -t cn`. Every file that a successful execve ran (the image and its interpreters) must be a FreeBSD-branded ELF or a #! script, at an absolute path that still exists; a relative or vanished path is an error. Any kldload or kldunload call fails the row |
| nvrm-info-no-new-module | no module appeared while it ran |
| uvm-ioctl-suite, uvm-owner-probe, uvm-owner-race | needs-linux: `nvidia-uvm.ko` declares MODULE_DEPEND on linux64elf (linux on amd64) and linux_common, and registers a Linux ioctl handler (uvm-bsd `sys/uvm_main.c`); `make-be.sh` writes the kldxref evidence |
| prime-import | needs-linuxkpi: `nvidia-drm.ko` and amdgpu are drm-kmod modules |
| render-uapi | not-available: main has the header and documents only |
| nvrm-s2-memory | not-available until libnvrm S2 (memory allocation and copy timing) is on main |
| env-after, env-after-delta | the guard a last time, and no module new since env-loaded |
| done | the run finished |

## Files of a run

The run is written to `/var/db/nvidia-native-tools-test/<stamp>/` in the boot environment. It is
then copied to the copy-out directory, by default
`/home/mlapointe/work/gb10/logs/native-tools-testboot/<stamp>/`. A run holds:

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

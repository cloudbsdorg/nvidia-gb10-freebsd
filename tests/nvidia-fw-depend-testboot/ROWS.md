# Test-boot rows: nvidia.ko depends on its GSP firmware modules (Track #2417)

Specification only. The kit that arms and runs these rows is built by the orchestrator, which
arms a boot only with the hardware owner's go-ahead. Nothing here is run by a test suite: no kldload, no boot.

## Kit rules (the repository's test-boot conventions)

- A one-shot boot environment named for what it tests, for example
  `nvidia-fw-depend-test-<UTC date>`, made with `bectl create` and activated with
  `bectl activate -t`. The normal boot environment is untouched.
- A self-recording rc one-shot writes every row's result under the absolute directory the build kit
  computed at build time and wrote into the rc configuration of the boot environment (the copy-out
  base is `$GB10_WORK/logs/nvidia-fw-depend-testboot` for a build that set `GB10_WORK`, and
  `<repo>/work/logs/nvidia-fw-depend-testboot` for a build that took the checkout default; the
  one-shot writes `<that directory>/<UTC stamp>/`), one line per row (`PASS`, `FAIL` or `INFO`,
  plus the raw output), then reboots into the normal environment. The one-shot does not read
  `GB10_WORK` at boot: `GB10_WORK` need not exist in the boot environment and `<repo>` is not a
  path there, so the build kit writes the absolute destination into the rc configuration and the
  one-shot uses that path.
- The kit script that builds the boot environment must call `guard_work_default`
  (`tests/native-tools-testboot/guard.sh`), like the other test-boot kits do: the work directory of
  the checkout belongs to the developer account that cloned the repository, so root must set
  `GB10_WORK` when a path comes from the work root. `tests/kit_work_guard_test.sh` checks that this
  rule stays stated here while the kit has no script yet.
- The modules come from `git archive` of the reviewed commit, built with base LLD
  (`readelf -p .comment x.ko | grep 'Linker: LLD'` is checked before install). They are
  installed into the test environment's `/boot/modules`: `nvidia.ko`, `nvidia-modeset.ko`,
  `nvidia-drm.ko`, `nvidia_gsp_ga10x_fw.ko`, then `kldxref /boot/modules`. The firmware module
  is NOT in `kld_list`, and nothing loads it before `nvidia.ko`: the dependency is the thing
  under test.
- The environment has the test user (not root, not in `wheel`) that the probes run as, and
  `/dev/nvidia0` is opened by that user (devfs rule or mode granting access; the rule is part
  of the kit and recorded).
- After the run the kit records which boot environment is running. A run that did not return to
  the normal environment is reported as such.

## Rows

### R1 precondition: modules staged and indexed
`kldstat` shows neither `nvidia` nor `nvidia_gsp_ga10x_fw`. `kldxref -v /boot/modules` (or the
`linker.hints` listing) names the module `nvidia_gsp_ga10x_fw_fw`. The staged file hashes equal
the kit's recorded hashes. PASS when all hold; otherwise the later rows are not run.

### R2 kldload of nvidia.ko alone brings the firmware module
As root, `kldload nvidia` (no firmware module loaded first) succeeds. `kldstat -v` then lists
`nvidia_gsp_ga10x_fw` and the module `nvidia_gsp_ga10x_fw_fw`, loaded before `nvidia`. `dmesg`
has no `could not load firmware image` and no `insufficient privileges`. PASS when all hold.

### R3 an unprivileged first open works
As the test user, hold `/dev/nvidia0` open (`sleep 20 < /dev/nvidia0`). Before the change this
open failed (`firmware_get_flags` refused the load, `RmInitAdapter failed!`) and, with the old
failure path, panicked the host. PASS when the open succeeds, `sysctl hw.nvidia.gpus.0` (read
while it is held) shows a firmware version, `dmesg` has no `RmInitAdapter failed` and no
`insufficient privileges`, and the system stays up.

### R4 the firmware module cannot be unloaded under the driver
As root, `kldunload nvidia_gsp_ga10x_fw` while `nvidia` is loaded is refused (EBUSY: the
dependency keeps a reference). `nvidia` stays loaded and the GPU still opens. PASS when refused
and nothing else changed. (`kldunload -f` is not part of this row.)

### R5 a missing firmware module fails the load, not the host
In a second one-shot environment (or after removing the module file and re-running `kldxref`),
`kldload nvidia` fails and `dmesg` shows the line below (recorded verbatim), `nvidia` is not
loaded, and no device is attached.

    KLD nvidia.ko: depends on nvidia_gsp_ga10x_fw_fw - not available or version mismatch

PASS when the load fails cleanly with that line and the system stays up.

### R6 a failed GPU init returns EIO and does not panic (commit 1 under the real resource manager)
In an environment with `hw.nvidia.registry.EnableGpuFirmware=0` in its `loader.conf` (the
GSP firmware is what these GPUs need, so the init is expected to fail), the test user's first
open of `/dev/nvidia0` returns EIO and `dmesg` shows `rm_init_adapter() failed!`. A second open,
by root, behaves the same way. PASS when both opens return an error and the host does not
panic. If the init does not fail on this hardware, the row is INFO: it records what happened and
is not a failure, because no failed init was produced. The old code panicked here (data abort at
NULL+0x19f8 in `RmDisableAdapter`).

## Not covered here

- amd64: `nvidia_gsp_tu10x_fw` is a dependency on amd64 only; no amd64 kit exists yet.
- GSP log images (`gsp_log_*`) are not firmware modules of this repository and are not
  dependencies: the driver requests one only when firmware logs are enabled, and the RM treats
  its absence as non-fatal (tests/fw_depend_test.sh checks both against the pinned source).
- Turing and GA100 on arm64: unsupported; no module is built for them there.

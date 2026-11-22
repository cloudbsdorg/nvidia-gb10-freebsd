# Linux dependencies of the GPU and LLM stack: native or not

Rule: if the native underpinnings exist, the workload is native. A run that
went through the Linuxulator where a native path exists is invalid; it is re-run natively and the
Linux number is marked superseded. The Linuxulator is kept only where nothing native exists, and is
then labelled "Linux-only, last resort". The registry of which card and backend have a native path
is [`native-paths.json`](native-paths.json). It is the source for the llama.cpp card and
backend rows below (the other rows are descriptive); `scripts/native-path-check` ([native-path-check(1)](../man/native-path-check.1)) fails a
benchmark history that breaks the rule: a Linuxulator record where a native path exists must be
marked superseded and have a native record beside it, and one where none exists must be marked
last resort. Track numbers below are work packages at https://track.cloudbsd.org/work_packages/N.

State as of 2026-11-22, host amp001 (Ampere Altra, FreeBSD 16.0-CURRENT arm64, RX 7600 and
RTX 5060 Ti).

## Layers

| Layer | Native? | Why | Next step |
|---|---|---|---|
| llama.cpp, RX 7600, Vulkan | **native** | FreeBSD clang build of b12627 (and b12531) on Mesa RADV, `amdgpu` from drm-kmod | Package: overlay `misc/llama-cpp` override at b12627 (Track 2424) |
| llama.cpp, CPU | **native** | Same FreeBSD build, CPU backend | none |
| llama.cpp, RTX 5060 Ti, Vulkan | no: Linux-only, last resort | No native NVIDIA Vulkan driver exists for FreeBSD arm64. NVIDIA publishes FreeBSD drivers for x86 and x86_64 only (download.nvidia.com/XFree86, checked 2026-11-22). Mesa NVK needs a kernel backend: nouveau is ruled out, and an NVK backend on libnvrm (RM-direct) is not written. A FreeBSD llama.cpp cannot load NVIDIA's Linux ICD, so the llama.cpp binary must be Linux too. | NVK on libnvrm, Track 2379 (needs libnvrm S2 memory and VA, then channels) |
| llama.cpp, RTX 5060 Ti, CUDA | no: Linux-only, last resort | No FreeBSD CUDA driver or runtime from NVIDIA on any arch. libnvrm S1 exports enumeration only (`nvrm_enumerate`, `nvrm_device_*`, JSON; see `lib/libnvrm/Version.map`); it has no memory, channel or launch calls. | Native CUDA, Track 2362 (C0/C1 in 2380) |
| llama.cpp RPC layer split (RX 7600 + RTX 5060 Ti) | no: Linux-only, last resort | The Radeon half and the client are native; the NVIDIA half is the Linux ICD and Linux `ggml-rpc-server` | Follows 2379 |
| llama.cpp on both cards at once (two servers) | no: Linux-only, last resort | The Radeon server is native; the NVIDIA server is the Linux build on the Linux ICD | Follows 2379 |
| NVIDIA device enumeration and identity | **native** (live proof pending) | `nvrm-info` (libnvrm S1, on main) lists every GPU with the values libnvrm reports, as text, JSON or JSONL, with no Linux layer; it passes against libnvrm's simulated device; it has not run against `nvidia.ko` yet (2378) | Run it on the real GPU in the next NVIDIA test boot; after that, use it instead of `nvidia-smi -L` |
| NVIDIA monitoring (utilisation, memory, clocks, temperatures) | no: Linux-only, last resort | Only NVIDIA's Linux arm64 `nvidia-smi` / `libnvidia-ml` provide it | Native monitor on libnvrm RM controls (gputop-style, MVC, `--json`/`--jsonl`); no ticket of its own yet; part of 2228 (feature-complete NVIDIA driver) |
| `nvidia.ko`, `nvidia-modeset.ko` Linux ioctl bridges | no (as packaged on main) | `MODULE_DEPEND` on `linux64elf`/`linux_common`, so loading the GPU loads the Linuxulator | Bridges become separate modules loaded only with the Linux layer: branch `agent/2363-linux-bridges-optional` (Track 2363), not on main yet |
| `nvidia-uvm.ko` (uvm-bsd) Linux bridge | no | Unconditional Linux `MODULE_DEPEND`; the native ioctl encoding already exists beside it | Same split as the line above (2363) |
| CUDA `LD_PRELOAD` shim, abstract sockets, linprocfs gaps | Linux-only by design | Exist only so Linux libcuda starts | Retire with native CUDA; 2361 keeps the Linux path working meanwhile |
| Test-boot kits and multi-GPU acceptance harness | partly | Radeon providers are native; NVIDIA workloads are Linux libcuda / Linux ICD | Native providers through the provider registry, Track 2371 |
| `x11/nvidia-kmod` LINUX option default, `linux_enable=YES` in images, `linux_base` in pkgsets | config, not native-by-default | A DGX profile needs these off | Linux layer as an explicit opt-in (2363 and the image profiles) |
| NVIDIA DRM/KMS (`nvidia-drm.ko` on LinuxKPI) | **native** | LinuxKPI is a native kernel KPI, not the Linuxulator | none for this rule (LinuxKPI is scaffolding: see the native NVIDIA plan) |
| GSP firmware, open RM core | **native** | OS-neutral firmware; MIT RM core built for aarch64 | none |
| Linux device exposure (linsysfs DRM nodes) | Linux-only by design | Lives in the Linuxulator, for third-party Linux binaries | none |

## Scripts and docs checked for Linux use where a native path exists

| Item | Finding | Action |
|---|---|---|
| `run-nv-vulkan.sh` (`$GB10_WORK/llm`, branch `agent/2101-llm-scripts`) | NVIDIA only: Linux ICD + Ubuntu llama.cpp. No native NVIDIA path exists. Its `rpc` mode starts a Linux `ggml-rpc-server` for the NVIDIA half only. | Cannot convert. Its header and man page are to say "Linux-only, last resort" when the branch lands on main. Radeon and CPU runs must use the native build, never this script. |
| `run-cuda-llama.sh`, `run-linux-cuda.sh`, `build-linux-cuda.sh` (branch `agent/2289-llama-cuda`) | NVIDIA CUDA only. No native CUDA exists. | Cannot convert (2362). Same "Linux-only, last resort" labelling when the branch lands. |
| `bench-report.sh` (branch `agent/2289-llama-cuda`) | Runs the two Linux launchers above, NVIDIA only. | Cannot convert; labelled as above. Native Radeon and CPU sets are run with the native build (`$GB10_WORK/llm/b12627`). |
| `build_history.py`, `bench-history.json` | Records had no path field; the NVIDIA stack strings said "via Linuxulator" only. | Every record now carries `path` (native or linuxulator) and `path_status` (native, superseded, last-resort); NVIDIA stacks say "Linux-only, last resort". |
| `pages/build_current_cuda.py` (Two GPUs page) | Describes the NVIDIA rows as official Ubuntu builds under the Linuxulator; does not say last resort. | Owned by the page orchestrator: the NVIDIA rows are to be labelled "Linux-only, last resort (no native NVIDIA path)", the Radeon rows "native b12627". |
| README and `docs/llm.md` | Listed the Linuxulator Vulkan, CUDA and `nvidia-smi` rows as plain successes; hard-coded a fixed NVIDIA device node. | Rows relabelled "Linux-only, last resort"; device nodes found by detection; `docs/llm.md` has the native b12627 numbers. |

No Radeon or CPU benchmark in the history ran through the Linuxulator, so no record is superseded
today: every Linuxulator record is NVIDIA (or the split with an NVIDIA half), all last resort.

## Evidence (2026-11-21 read-only audit, kept)

Live host checks: `kldstat` shows `linux64.ko` and `linux_common.ko` loaded (through `linux_enable`
and the `MODULE_DEPEND`s below); `/compat/linux` and `linux_base-rl9` are installed; the private
Linux roots are `$GB10_WORK/linuxroot/{nv,rl9,noble}` (NVIDIA's Linux user libraries, Rocky 9,
Ubuntu 24.04).

| # | Item | Evidence |
|---|---|---|
| 1 | `nvidia.ko` depends on the Linuxulator | `patches/patch-nvidia_nvidia_pci.c`: `MODULE_DEPEND(nvidia, linux64elf)` (aarch64) and `linux_common`, gated by `NV_SUPPORT_LINUX_COMPAT` (always defined in `nv-freebsd.h`) |
| 2 | `nvidia-modeset.ko` depends on the Linuxulator | `patches/patch-nvidia-modeset_nvidia-modeset-freebsd.c`, gated by `NVKMS_SUPPORT_LINUX_COMPAT` |
| 3 | `nvidia-uvm.ko` depends on the Linuxulator | `nvidia-uvm-freebsd/sys/uvm_main.c:450-456`; Linux bridge at 210-275 |
| 4 | CUDA is NVIDIA's Linux `libcuda` | `run-linux-cuda.sh`, `run-cuda-llama.sh`, `linuxroot/nv` (libcuda 580.178.04), `llm/cuda/llama-b12531-cuda` (official ubuntu-cuda-13.5-arm64) |
| 5 | `LD_PRELOAD` shim | `tests/cuda/shim.c` fakes `/proc/sys/vm/mmap_min_addr`, `/proc/self/task/*/comm`, abstract AF_UNIX |
| 6 | Abstract-socket kernel work | cloudbsd-src `agent/2101-linux-abstract-native` |
| 7 | NVIDIA Vulkan is the Linux ICD | `run-nv-vulkan.sh`: `VK_DRIVER_FILES=linuxroot/nv/nvidia_icd.json`, glvnd `10_nvidia.json`, Ubuntu noble glibc 2.39 for `llama-b12531` ubuntu-vulkan-arm64 |
| 8 | NVIDIA benchmarks use the official Ubuntu builds | `llm/llama-vulkan-arm64/llama-b12531`, `llm/cuda/llama-b12531-cuda` |
| 9 | `nvidia-smi` is the Linux build | `scripts/fetch-nvidia-smi.sh` unpacks `NVIDIA-Linux-aarch64-580.178.04.run`; a native build exists only in the FreeBSD x86_64 tarball |
| 10 | Acceptance harness | `testboot-multigpu/multigpu-accept:175-208`: NVIDIA providers are the Linux launchers |
| 11 | Test-boot workloads | `testboot-{cememset,dma,memset-pitch,prime-numa,ptphys,xid71}`, `testboot-uvm-*`, `testboot-linux-abstract` run Linux libcuda through `ld-linux-aarch64.so.1` |
| 12 | `x11/linux-nvidia-libs` | overlay port, `USES=linux`; pulled by `cloudbsd-gpu-pkgset` on amd64 only |
| 13 | `x11/nvidia-kmod` | `OPTIONS_DEFAULT` includes LINUX (overlay Makefile 110-114, 317-325) |
| 14 | Images boot with Linux compat | `sysutils/cloudbsd-linuxulator` comment; server and desktop pkgsets RUN_DEPEND on `linux_base-rl9`; amp001 `linux_enable="YES"` |
| 15 | No FreeBSD arm64 NVIDIA user space | download.nvidia.com/XFree86 lists FreeBSD-x86 and FreeBSD-x86_64 only; FreeBSD-aarch64 and FreeBSD-arm64 return 404 (2026-11-22) |
| 16 | libnvrm S1 scope | `lib/libnvrm/Version.map` NVRM_1.0: enumerate, device info, JSON; S2 (memory, VA) is uncommitted work in `wt-libnvrm-s2` |
| 17 | Mesa NVK | overlay `graphics/mesa-devel` has an `nvk` option, proven only on a drm-shim; no ICD for NVIDIA is installed on amp001 (`/usr/local/share/vulkan/icd.d`: radeon, lvp) |

# Running LLMs on FreeBSD arm64

How to run llama.cpp on an arm64 FreeBSD machine with a GPU, and what it does on the one
machine measured so far: an Ampere Altra running FreeBSD 16.0-CURRENT with an AMD Radeon RX
7600 and an NVIDIA GeForce RTX 5060 Ti. The AMD card and the CPU run llama.cpp natively. The
NVIDIA card has no native path yet; it runs only through NVIDIA's Linux libraries under the
Linuxulator, as a last resort (see [NVIDIA](#nvidia) below).

Rule: if the native underpinnings exist, the workload is native. A Linuxulator run where a
native path exists is invalid. `scripts/native-path-check`
([native-path-check(1)](../man/native-path-check.1)) checks a benchmark history against
the registry [`native-paths.json`](native-paths.json); see
[Linux dependencies](LINUX-DEPENDENCY-AUDIT.md) for every layer.

## Native build from source (b12627)

The newest llama.cpp release is b12627 (225a5345b, 2026-11-22; the `v1.0.0` tag is older than
b12531). It builds natively with the base compiler; two settings are needed on FreeBSD:

```sh
# b12627 by commit, so a moved tag cannot change what is built
git init src && git -C src fetch --depth 1 https://github.com/ggml-org/llama.cpp \
    225a5345bbb0e0c70859af5441ba922beb666fcf && git -C src checkout --detach FETCH_HEAD
cmake -S src -B build -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DGGML_NATIVE=ON -DGGML_VULKAN=ON -DGGML_RPC=ON \
    -DGGML_RPC_RDMA=OFF \
    -DCMAKE_SHARED_LINKER_FLAGS=-pthread \
    -DLLAMA_CURL=OFF -DLLAMA_BUILD_UI=OFF
ninja -C build
```

- `GGML_RPC_RDMA=OFF`: CMake turns RDMA on when it finds base `libibverbs`, which is too old
  (`IBV_GID_TYPE_IB` and `ibv_gid_entry` are missing).
- `-pthread` for shared libraries: otherwise `libggml-rpc.so` fails to link
  (`undefined reference: pthread_create`).
- A CPU-only build is the same with `-DGGML_VULKAN=OFF -DGGML_RPC=OFF`.

Pick the card by PCI bus, not by number. `pciconf -l` shows the AMD card (vendor 0x1002) and
its bus in decimal; `llama-bench --list-devices` prints `VulkanN: <name>` in ggml's order, which
skips CPU devices such as llvmpipe. When two devices have the same name, match the bus: in
`vulkaninfo`, `pciDomain`/`pciBus`/`pciDevice` (decimal) under each GPU; count only the
non-CPU GPUs to get N.

```sh
pciconf -l | grep 'vendor=0x1002'                      # vgapciM@pciD:B:S:F
llama-bench --list-devices                              # Vulkan0: AMD Radeon RX 7600 (RADV NAVI33)
vulkaninfo | grep -E '^GPU[0-9]|deviceType|pciDomain|pciBus'
```

## Native numbers, 2026-11-22

`llama-bench -ngl 99 -t 8 -r 3 -p 512 -n 128` (`-t 64` for the 64-thread row), tokens per
second; `fa` is flash attention (`-fa`). RX 7600 on Mesa RADV 26.2.2. b12627 and b12531 were run
back to back, twice, in alternating order; the table gives the second pass. The CPU was measured
with b12627 only (n/a: not run).

| Card | Model | fa | b12627 pp512 | b12531 pp512 | b12627 tg128 | b12531 tg128 |
|---|---|---|---|---|---|---|
| RX 7600 | Llama 3.2 3B Q4_K_M | 1 | 2340.30 ± 5.71 | 2355.83 ± 21.74 | 78.64 ± 0.05 | 79.07 ± 0.04 |
| RX 7600 | Llama 2 7B Q4_0 | 0 | 1143.79 ± 2.22 | 1147.08 ± 3.45 | 48.31 ± 0.08 | 48.27 ± 0.06 |
| RX 7600 | Llama 2 7B Q4_0 | 1 | 1349.08 ± 2.99 | 1354.96 ± 1.63 | 51.68 ± 0.05 | 51.65 ± 0.02 |
| CPU, 8 threads | Llama 3.2 3B Q4_K_M | 1 | 83.44 ± 0.16 | n/a | 25.16 ± 0.15 | n/a |
| CPU, 8 threads | Llama 2 7B Q4_0 | 0 | 46.93 ± 0.24 | n/a | 15.61 ± 0.07 | n/a |
| CPU, 8 threads | Llama 2 7B Q4_0 | 1 | 55.13 ± 0.01 | n/a | 17.21 ± 0.09 | n/a |
| CPU, 64 threads | Llama 2 7B Q4_0 | 1 | 405.03 ± 0.23 | n/a | 29.85 ± 0.03 | n/a |

b12627 and b12531 are within 1% of each other on the Radeon. Against the published RX 7600
Vulkan scoreboard row
([llama.cpp discussion #10879](https://github.com/ggml-org/llama.cpp/discussions/10879)):
pp512 −2.0% (fa 0) and −0.3% (fa 1), tg128 −16.7% and −15.1%. The raw `llama-bench` JSON is
kept in the bench history (`$GB10_WORK/llm/history/runs/20261122T05*-native-*`).


## llama.cpp from packages, Vulkan on the AMD card

The `llama-cpp` package uses `ggml` for its compute backends. Build `ggml` with the `VULKAN`
option on and llama.cpp runs on any Vulkan device; on the RX 7600 that device is Mesa's RADV.

You need:

- the `amdgpu` DRM driver loaded (drm-kmod; `kld_list="amdgpu"` in `/etc/rc.conf`);
- the packages `llama-cpp` and `ggml` (with `VULKAN=on`), `vulkan-loader` and `mesa-dri`;
- a user who can open `/dev/dri/renderD*` (group `video`).

Measured with `llama-cpp` 11669 and `ggml` 0.27.0. Check that llama.cpp sees the card:

```sh
pkg query '%n %Ok=%Ov' ggml          # ggml VULKAN=on
llama-bench --list-devices
```

If more than one Vulkan device is listed (Mesa's software renderer, lavapipe, can be one), pick
the card with `--device`.

## Numbers measured

Model: Llama-3.2-3B-Instruct, `Q4_K_M` GGUF (about 2 GB), all layers on the GPU (`-ngl 99`).

| Test | Result |
|---|---|
| `llama-bench`, prompt 512 tokens (pp512) | 1778 tokens/s |
| `llama-bench`, generate 128 tokens (tg128) | 41.7 tokens/s |
| `llama-bench`, prompt 2048 tokens, flash attention off | 491 tokens/s |
| `llama-bench`, prompt 2048 tokens, flash attention on | 1072 tokens/s |
| `llama-server -fa on -t 8`, 1913-token prompt | 966 ms (1981 tokens/s) |
| `llama-server -fa on -t 8`, decode | 76 tokens/s |

```sh
M=Llama-3.2-3B-Instruct-Q4_K_M.gguf
llama-bench -m $M -ngl 99                        # pp512 and tg128
llama-bench -m $M -ngl 99 -p 2048 -n 0 -fa off   # long prompt, flash attention off
llama-bench -m $M -ngl 99 -p 2048 -n 0 -fa on    # and on
```

## Flash attention and thread count

Two settings matter more than anything else here:

- **`-fa on`.** Flash attention doubled long-prompt throughput (491 to 1072 tokens/s at 2048
  tokens). Turn it on for the server.
- **`-t 8`.** With every layer on the GPU, the CPU threads only feed the GPU, and a few are
  enough. Run with 64 threads beside a second, CPU-only server, the GPU server's prefill fell
  to 145 tokens/s: the two servers' threads were competing for cores. With `-t 8` the same
  1913-token prompt took 966 ms (1981 tokens/s).

```sh
llama-server -m $M -ngl 99 -fa on -t 8 -c 8192 -np 1 --port 18080
```

## Splitting prefill and decode

Prefill (reading the prompt) is compute-bound and suits the GPU; decode (generating tokens) is
memory-bound and can run elsewhere. llama.cpp's server can move a request between servers
through slot save and restore: the prefill server computes the prompt's KV cache and saves the
slot to a file, the decode server restores it and generates from there without recomputing the
prompt. [`scripts/pd_split.py`](../scripts/pd_split.py) does this against two running
servers (Python 3, standard library only).

Both servers need the same model, the same context size, one slot, and `--slot-save-path` on the
same directory, since one writes the slot file and the other reads it:

```sh
mkdir -p ~/llm-slots
# prefill: the RX 7600
llama-server -m $M -ngl 99 -fa on -t 8 -c 8192 -np 1 \
    --slot-save-path ~/llm-slots --port 18080 &
# decode: the CPU only
llama-server -m $M --device none -t 32 -c 8192 -np 1 \
    --slot-save-path ~/llm-slots --port 18081 &

python3 scripts/pd_split.py http://127.0.0.1:18080 http://127.0.0.1:18081 128
```

The script sends one long prompt (about 1900 tokens) for prefill only, saves the slot, restores
it on the decode server and generates 128 tokens there. Then it runs the whole request on each
server alone and reports whether the split output matches the decode server's own output.
Measured, prefill on the RX 7600 and decode on 32 CPU threads:

| Step | Result |
|---|---|
| prefill on the RX 7600 | 0.97 s |
| slot saved (KV cache, 219 MB) | 328 ms |
| slot restored on the CPU server | 48 ms |
| decode on the CPU server | 32.8 tokens/s (2.43 s for the request) |
| the same request on the CPU server alone | 27.3 s |
| split output identical to the CPU server alone | yes |

On this machine decode is faster on the GPU too (76 tokens/s), so the split pays off only when
the GPU is wanted for other prompts, or when the decode side is a different, faster device.
Here it shows that the mechanism works and that the output does not change.

The servers have no API key and accept any origin; keep them on `127.0.0.1`.

vLLM's disaggregated prefill needs CUDA or ROCm, and FreeBSD arm64 has neither.

## NVIDIA

No native path exists yet, so there is no native NVIDIA number:

- Vulkan: NVIDIA publishes FreeBSD drivers for x86 and x86_64 only, so there is no FreeBSD
  arm64 Vulkan ICD. Mesa NVK needs a kernel backend; nouveau is ruled out, and NVK on libnvrm
  (RM-direct: talking to `nvidia.ko`, no nouveau) is Track
  [#2379](https://track.cloudbsd.org/work_packages/2379).
- CUDA: there is no FreeBSD CUDA driver or runtime. libnvrm S1 only enumerates GPUs. Native CUDA
  is Track [#2362](https://track.cloudbsd.org/work_packages/2362).

Linux-only, last resort: until then, llama.cpp runs on the NVIDIA card only as the official
Ubuntu arm64 builds (`ubuntu-vulkan-arm64`, `ubuntu-cuda-13.5-arm64`) on NVIDIA's Linux
libraries under the Linuxulator (see the
[README](../README.md#vulkan-linux-icd-under-the-linuxulator)). A FreeBSD llama.cpp cannot load
NVIDIA's Linux ICD or `libcuda`, so the whole process has to be Linux. The NVIDIA numbers (the
README's [Numbers](../README.md#what-works-status-2026-11-20) and the bench history) are
recorded with `"path": "linuxulator"` and `"path_status": "last-resort"`, and are replaced as
soon as a native path exists.
The Linux CUDA path is described in the next section.

## Native NVIDIA benchmark

When NVK on libnvrm can create a device, `scripts/native-llm-bench`
([native-llm-bench(1)](../man/native-llm-bench.1)) selects the card by PCI bus, proves the Vulkan and
benchmark paths are native, checks memory before each model, and records history rows with
published-median comparisons. For NVIDIA it pins only `nvk_nvrm_icd.<arch>.json` with library
`libvulkan_nvk_nvrm.so`; any `libvulkan_nouveau.so` ICD or inherited override to another ICD is
refused. It refuses Linux ICDs, Linux binaries and loaded Linux compatibility modules; until that
native path exists, it exits with the Track #2379 refusal instead of running the Linux path.

Check the working Radeon path without starting a benchmark:

```sh
scripts/native-llm-bench --gpu radeon --dry-run
```

The NVIDIA command below refuses with exit 3 until NVK on libnvrm is installed:

```sh
scripts/native-llm-bench --gpu nvidia
```

## CUDA (Linux libcuda through the Linuxulator; Linux-only, last resort)

NVIDIA's Linux `libcuda.so.1` (580.178.04) runs under the Linuxulator against `nvidia.ko`
and the clean-room `nvidia-uvm.ko` (uvm-bsd).

What works today, checked on the RTX 5060 Ti:

- `cuInit`, `cuDriverGetVersion`, device count, name, memory size and attributes
- context creation, allocation, host-to-device and device-to-host copies
  (`cuda_smoke`: a 64 MiB pattern round trip verifies)
- a PTX kernel through the driver's JIT: `cuModuleLoadDataEx`, `cuLaunchKernel`
  (`cuda_vecadd`: vectorAdd over 1 Mi elements, 0 mismatches)

Managed memory is not covered yet: no test allocates it.

Requirements:

- `nvidia-uvm.ko` (uvm-bsd) loaded, so `/dev/nvidia-uvm` exists.
- A Rocky 9 root in `$GB10_WORK/linuxroot/rl9` and NVIDIA's user libraries in
  `$GB10_WORK/linuxroot/nv` (`LINUXROOT` names another place).

The abstract-socket gap: `libcuda` binds an AF_UNIX socket in the Linux abstract namespace
(a `sun_path` that starts with a NUL byte). The Linuxulator does not implement that
namespace; it hands the name bytes to unix(4) as a path and `bind` fails with ENOENT, so
`cuInit` returned error 304. `tests/cuda/shim.c` is an `LD_PRELOAD` shim that maps each
abstract name to a file in `SHIM_ABSTRACT_DIR` and maps it back in `getsockname`,
`getpeername`, `accept` and `recvmsg`. It also redirects `/proc/sys/vm/mmap_min_addr` and
`/proc/self/task/*/comm`, which `linprocfs` lacks, and `SHIM_IOCTL_LOG=1` logs ioctl
argument blocks. Keep `SHIM_ABSTRACT_DIR` short: `sun_path` holds 103 bytes on FreeBSD. `SHIM_ABSTRACT=off` turns the emulation off and leaves abstract names to the kernel, for testing a Linuxulator that maps them itself (cloudbsd-src branch `agent/2101-linux-abstract-sockets`).

The real fix is abstract-namespace sockets in the Linuxulator itself (cloudbsd-src, in
progress). The shim goes away when that lands.

Commands:

```sh
sh scripts/build-linux-cuda.sh                 # builds into $GB10_WORK/build/linux-cuda
sh scripts/run-linux-cuda.sh cuinit            # cuInit and the device count
sh scripts/run-linux-cuda.sh cuda_smoke        # context, 64 MiB alloc, copies, verify
sh scripts/run-linux-cuda.sh cuda_vecadd       # deviceQuery-lite and a PTX vectorAdd
sh tests/linux_cuda_test.sh                    # no GPU: build and the shim test
```

`run-linux-cuda.sh` starts the program through the Rocky `ld-linux-aarch64.so.1` with
`--preload shim.so` and `--library-path` over `nv`, `rl9/usr/lib64` and `rl9/usr/lib`, and
sets `SHIM_MMAP_MIN_ADDR`, `SHIM_COMM` and `SHIM_ABSTRACT_DIR` (default `~/.cache/sa`).

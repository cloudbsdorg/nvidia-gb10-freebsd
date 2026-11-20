# Running LLMs on FreeBSD arm64

How to run llama.cpp on an arm64 FreeBSD machine with a GPU, and what it does on the one
machine measured so far: an Ampere Altra running FreeBSD 16.0-CURRENT with an AMD Radeon RX
7600 and an NVIDIA GeForce RTX 5060 Ti. The AMD card works today, from packages. The NVIDIA
card does not run llama.cpp yet (see [NVIDIA](#nvidia) below).

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

Not yet. llama.cpp's Vulkan backend needs NVIDIA's Linux Vulkan ICD under the Linuxulator
(see the [README](../README.md#vulkan-linux-icd-under-the-linuxulator)). The official
llama.cpp `ubuntu-vulkan-arm64` build already runs that way from a private Ubuntu 24.04 root,
started through that root's dynamic linker with `GGML_BACKEND_PATH` pointing at its
`libggml-vulkan.so`. It finds no device without the ICD; with the ICD it stops at the same
`SIGBUS` as `vulkaninfo`. The fix (3414fd7) waits for a test boot; after it, the plan is the
same `llama-bench` run (pp512, tg128) for a comparison with the RX 7600. For CUDA see the
next section.

## CUDA (Linux libcuda through the Linuxulator)

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

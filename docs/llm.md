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
same `llama-bench` run (pp512, tg128) for a comparison with the RX 7600. CUDA needs
`nvidia-uvm`, which does not exist for FreeBSD yet (see the README's status table).

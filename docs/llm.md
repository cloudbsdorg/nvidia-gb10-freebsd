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

### The options of pd_split.py

| Option | What it does |
|---|---|
| `--slot-file NAME` | the slot file the two servers save and restore (default `pd-slot.bin`) |
| `--json PATH` | write the same results (timings, outputs, comparisons) to a JSON file |
| `--label-prefill X` | the name of the prefill server in the printed lines (default `prefill server`) |
| `--label-decode Y` | the name of the decode server in the printed lines (default `decode server`) |

```sh
python3 scripts/pd_split.py http://127.0.0.1:18080 http://127.0.0.1:18081 128 \
    --slot-file slot-42.bin --label-prefill gpu --label-decode cpu \
    --json pd-split.json
```

The script prints all three texts: the one from the split run, and the two baselines (the whole
request on each server alone). Then it says whether the split output is the same as each
baseline. When they differ it prints the first character that differs, so a broken split run can
be traced without reading two whole answers.

The two server URLs must be http(s): anything else (`file:`, `ftp:`, `data:`) is refused before
the first request is made, and a trailing slash is removed so the request paths stay clean. The
scheme is matched the way RFC 3986 says it is matched, case-insensitively, so `HTTP://host` is
an http URL and is accepted. What is refused: a URL with a space or a tab in it (including a
leading or a trailing one, because urllib would strip it again and send the request under a URL
that was never checked), a URL without a host, a URL that is not ASCII (a zero width space is
not whitespace and would survive every other check), a URL with a query or a fragment (they
would be sent to the server as part of the request path, where they mean something else) and a
URL whose port is not a number.

The servers have no API key and accept any origin; keep them on `127.0.0.1`.

vLLM's disaggregated prefill needs CUDA or ROCm, and FreeBSD arm64 has neither.

## Comparing llama-bench runs

[`scripts/bench_compare.py`](../scripts/bench_compare.py) turns llama-bench JSON files into
tables with one percentage per row (Python 3, standard library only). It has two modes:

- `published PUBLISHED.json CARD=OURS.json ...` compares our runs against published reference
  numbers. For every card, every flash-attention setting in our file and every test (pp512,
  tg128) the row gives our throughput, the median of the published numbers for that card and
  setting, the smallest and the largest of them, how many there were, and the percentage.
- `delta A.json B.json` compares two of our own runs, the same way.

```sh
# our run against the published numbers for the same card
python3 scripts/bench_compare.py published published.json nv=ours.json
# our two runs against each other
python3 scripts/bench_compare.py delta build-a.json build-b.json --format html
```

In `published` mode the percentage is (ours − median) / median; in `delta` mode it is
(a − b) / b, where a is the first run and b the second. The number is signed: a positive
number means our run is faster than the number it is compared with, a negative one means it
is slower. It is printed with one decimal, a plus sign for the positive numbers and U+2212
MINUS SIGN (not the ASCII hyphen) for the negative ones, so a slow run reads "−12.4%" and
never "-12.4%". A number that rounds to zero keeps its sign ("−0.0%").

The published file is a JSON object with a "rows" list. Each row names a card, a GPU, a backend,
an operating system, a build, the flash-attention setting, the numbers for pp512 and tg128, and
a "compare" flag. Rows with `"compare": false` are printed under "Reference only": they never
enter the median, they carry their own percentage against our run. A row without a `compare`
key at all is compared: only an explicit `"compare": false` keeps a row out of the median. The
flag must be a JSON boolean: a string, a number or `null` is an error (exit 2), not a flag.

A row of a bench file is named from both of its counters: a row that measured the prompt only
is `ppN`, a row that measured the generation only is `tgN`, and a row that measured both (the
combined prompt-and-generation test, `llama-bench -pg N,M`) is `ppNtgM`. `-p` and `-n` are the
two separate tests (`ppN` and `tgN`), not one combined test. Only `pp512` and `tg128` are
compared with the published numbers, so a combined row is never mistaken for a pure prefill row,
and a file with the same row twice is refused instead of silently using one of them.

One of our rows that has no published row for its card, its test and its flash-attention
setting is reported on stderr, one line per row: it is in the table with an empty median and an
"n/a" percentage, which says nothing about the run. This is what a run with llama-bench's own
default flash attention looks like: that default is AUTO, llama-bench writes it as `-1`, and a
`-1` row matches no published `fa` 0 or `fa` 1 row.

`--format md` (the default), `json` and `html` choose the output. Bad input is one line
"bench_compare.py: ..." on stderr and exit 2, never a traceback. A number that is not finite
(NaN, Infinity) is bad input: no table can hold it. `-h` and `--help` print the usage and exit
0.

## NVIDIA

Not yet. llama.cpp's Vulkan backend needs NVIDIA's Linux Vulkan ICD under the Linuxulator
(see the [README](../README.md#vulkan-linux-icd-under-the-linuxulator)). The official
llama.cpp `ubuntu-vulkan-arm64` build already runs that way from a private Ubuntu 24.04 root,
started through that root's dynamic linker with `GGML_BACKEND_PATH` pointing at its
`libggml-vulkan.so`. It finds no device without the ICD; with the ICD it stops at the same
`SIGBUS` as `vulkaninfo`. The fix (3414fd7) waits for a test boot; after it, the plan is the
same `llama-bench` run (pp512, tg128) for a comparison with the RX 7600. For CUDA see the
next section.

[`scripts/run-nv-vulkan.sh`](../scripts/run-nv-vulkan.sh) runs the Linux aarch64 Vulkan stack
against the NVIDIA card through the Linuxulator. It starts the programs from private Linux roots
of their own (nothing in `/compat/linux` is touched) and sets the two environment variables the
loader needs:

```sh
export VK_DRIVER_FILES=$GB10_WORK/linuxroot/nv/nvidia_icd.json
export __EGL_VENDOR_LIBRARY_FILENAMES=$GB10_WORK/linuxroot/nv/10_nvidia.json
```

The work root is `GB10_WORK`, which defaults to `$HOME/work/gb10`. It holds:

| Directory | Contents |
|---|---|
| `linuxroot/nv/` | NVIDIA's 580.178.04 user libraries, `nvidia_icd.json` (the Vulkan ICD) and `10_nvidia.json` (the EGL vendor file) |
| `linuxroot/rl9/` | Rocky 9: Vulkan loader, `vulkaninfo`, libglvnd, the X11, xcb and Wayland client libraries, libffi |
| `linuxroot/noble/` | Ubuntu 24.04: glibc 2.39, libstdc++, libgomp, Vulkan loader 1.3, `vulkaninfo`, X11/glvnd libraries: what the official llama.cpp `ubuntu-vulkan-arm64` build needs (GLIBC_2.38) |
| `llm/llama-vulkan-arm64/llama-b12531/` | the llama.cpp build |

The modes:

| Mode | What it runs |
|---|---|
| `vulkaninfo [options...]` | the Rocky Vulkan loader and `vulkaninfo` against the ICD; `--summary` when it is given no options of its own |
| `list [options...]` | `llama-bench --list-devices`, with the options after it |
| `bench [model.gguf] [options...]` | `llama-bench` with that model, prompt 512 and 128 tokens, all layers on the GPU and flash attention off and on; each default is added only for the flags your options do not give |
| `server MODEL [options...]` | `llama-server` with that model |
| `llama-bench [options...]` | `llama-bench` with the given options; no model is added, the model is yours to pass |
| `rpc [options...]` | `ggml-rpc-server` with the given options |

Only `bench` and `server` take a model. In the other modes the second argument is one of the
program's own options and is passed on unchanged. An empty model argument is a missing
argument, not the default model: `bench ""` and `server ""` stop with exit 2.

llama-bench **appends** `-m`, `-p`, `-n`, `-ngl` and `-fa` to a list: a flag given twice does
not override the first one, it adds a second run. `bench m.gguf -p 1024` would therefore run
both pp512 and pp1024. So the defaults of `bench` (`-p 512`, `-n 128`, `-ngl 99`, `-fa 0,1`)
are added only for the flags your options do not give themselves, by their short or long name
(`-p`/`--n-prompt`, `-n`/`--n-gen`, `-ngl`/`--n-gpu-layers`, `-fa`/`--flash-attn`). A `-m` or
`--model` in the options of `bench` or `server` is refused (exit 2): the model is that mode's own
argument. llama-bench would run both models, and llama-server would silently use the last one. The `-fa 0,1` default is what makes the rows comparable: llama-bench's own
default flash attention is AUTO, it writes that as `-1`, and a `-1` row matches no published
`fa` 0 or `fa` 1 row.

Two traps, in plain words:

- **The working directory.** ggml looks for its backends (`libggml-vulkan.so`,
  `libggml-cpu-*.so`, `libggml-rpc.so`) next to the executable *and* in the current directory,
  and the executable here is `ld-linux-aarch64.so.1` from the Ubuntu root, so only the
  current-directory search finds them. `daemon(8)` changes to `/` before it runs the program, and
  from there `llama-server` says "no usable GPU found" or "no backends are loaded". The script
  therefore runs every mode from the llama directory. A relative path in the options of
  `llama-server` is then relative to that directory: pass absolute ones. The model path itself is
  made absolute against the directory the script was started from.
- **The EGL vendor file.** The NVIDIA Vulkan ICD starts through libEGL (glvnd). Without
  `10_nvidia.json` libEGL finds no NVIDIA vendor, `vk_icdGetInstanceProcAddr` returns NULL and
  the loader says "Could not get 'vkCreateInstance' via 'vk_icdGetInstanceProcAddr' for ICD
  libGLX_nvidia.so.0" and "Found no drivers!". Any launcher that does not use this script has to
  set both variables itself.

The script is tested without a GPU and without a Linux root:
`sh tests/run-nv-vulkan_test.sh` builds a fake work root whose dynamic linker is a shell script
that prints its arguments, and checks the modes, the model path and the two refusals.

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

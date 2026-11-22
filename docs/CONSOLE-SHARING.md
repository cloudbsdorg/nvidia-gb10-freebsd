# Console sharing: the boot console on every monitor, NVIDIA included

Track #2448 (part of #2381, F11). Related: #2375 (display ownership), #2362, #2422
(hardware preflight and verify).

Loading amdgpu moves the boot console onto the Radeon's monitor; loading the NVIDIA driver
leaves its monitors dark. The goal is that the console is **shared**, not moved: with several
monitors it shows on **all** of them by default, on every connected head of every NVIDIA GPU
and on the outputs of other drivers too.

This document is the design. Phase 1 is what branch `agent/2448-console-sharing` builds, in a
series of commits (the NVKMS patches first, then `vt_share`, `nvidia_console`, the build and
the test-boot kit); a path named here may land in a later commit of that series. Phase 2 is
follow-up work filed under #2448. Each phase ends at its gate.

## 1. Summary

Two native BSD-C kernel modules, with no LinuxKPI, no drm-kmod and no nvidia-drm:

| module | what it is | depends on |
|---|---|---|
| `vt_share.ko` | a vendor-neutral vt(4) backend that fans every console draw out to a set of **outputs**. Outputs come from **providers** that register themselves (a provider registry: no vendor list anywhere in it). It owns the configuration (loader tunables, sysctls) and the JSON status. A built-in provider covers the firmware (UEFI GOP) framebuffer. | the kernel only |
| `nvidia_console.ko` | the NVIDIA provider: a kernel-side NVKMS client (the KAPI) that lights every connected head of every NVIDIA GPU with a linear surface and registers each head with `vt_share`. | `nvidia_modeset`, `vt_share` |

Plus one small patch to NVKMS (in `patches/ogkm/`, MIT code we already patch): a **console
owner** that NVKMS asks to yield when another client grabs the display, and calls back when
the display is free again (section 6).

Why two modules and not a part of nvidia-modeset: the fan-out is not NVIDIA's business. A
Radeon on drm-kmod, efifb and a future Intel provider all feed the same backend, and Mark's
provider-registry rule (11-18, 11-19) wants one registry with self-registering providers.
Keeping `nvidia_console` out of `nvidia-modeset.ko` also leaves NVIDIA's module with no vt(4)
code, lets the console be unloaded and reloaded on its own (section 8), and keeps the KAPI
client in our own source, not in a patch to NVIDIA's.

## 2. What NVKMS offers a kernel-side client (the KAPI)

`nvidia-modeset.ko` exports `nvKmsKapiGetFunctionsTable()` (by name on arm64 too, see
`EXPORT_SYMS` in its Makefile). The caller fills `versionString` with the driver version plus
our layout tag (`NVKMS_KAPI_CBSD_LAYOUT`, `+cbsd-kapi.N`) and gets the function table. The
calls `nvidia_console` uses, in order:

1. `enumerateGpus(cb)`: one `NvKmsKapiGpuInfo` per GPU, with `gpu_id` and the PCI
   `domain:bus:slot.function`. This is the enumeration for the multi-GPU choice; nothing is
   looked up by index. On FreeBSD the OS layer's `nvkms_enumerate_gpus()` returned 0, so this
   call found nothing; phase 1 fills it from the `nvidia` devclass, walked under the bus
   topology lock, attached units only. The FreeBSD nvidia-drm does not call it (it walks the
   devclass itself; its `enumerateGpus` probe is Linux-only), so nvidia-drm is unaffected.
2. `allocateDevice({gpuId, privateData, eventCallback})`, then
   `declareEventInterest(DPY_CHANGED | DYNAMIC_DPY_CONNECTED)` for hot-plug.
3. `grabOwnership(device)`: modesetting needs it. Ownership is exclusive in NVKMS
   (`GrabModesetOwnership` refuses a second owner), which is why section 6 adds the console
   owner.
4. `getDeviceResourcesInfo`: `numHeads`, the connector handles, `caps.pitchAlignment`,
   `caps.hasVideoMemory`, `caps.min/max{Width,Height}InPixels`,
   `supportedSurfaceMemoryFormats[primary layer]`, and `vtFbBaseAddress` / `vtFbSize`: the
   framebuffer console memory the RM reserved at boot (on FreeBSD the RM learns it from the
   loader's `MODINFOMD_EFI_FB` metadata, `nv_get_screen_info()`, when that address lies in one
   of the GPU's BARs).
5. `getDisplays`, then per display `getStaticDisplayInfo` (`headMask`, `connectorHandle`,
   `internal`, `isDpMST`), `getConnectorInfo` (`type`, `physicalIndex`, `signalFormat`) and
   `getDynamicDisplayInfo` (`connected`, the EDID).
6. `getDisplayMode(display, i, ...)` walks the mode list and flags the EDID's preferred mode;
   `validateDisplayMode` checks one.
7. `allocateMemory({layout = Pitch, type = SCANOUT, size, noDisplayCaching = TRUE,
   useVideoMemory = caps.hasVideoMemory})`: one buffer per lit head, pitch rounded up to
   `pitchAlignment`.
8. `mapMemory(device, memory, NVKMS_KAPI_MAPPING_TYPE_KERNEL, &va)`: the kernel CPU mapping.
   The memory attribute is the OS layer's (section 9), never chosen here.
9. `createSurface({planes[0] = {memory, 0, pitch}, width, height,
   format = X8R8G8B8 (A8R8G8B8 when X8 is not offered), explicit_layout = FALSE})`.
10. `applyModeSetConfig(device, cfg, &reply, commit)`: first with `commit = FALSE` (validate),
    then `TRUE`. Per head: `bActive`, `numDisplays = 1`, the display handle, the mode, and the
    primary layer (`surface`, `src = dst = the mode size`, opaque composition).
11. `framebufferConsoleDisabled(device)`: tells NVKMS the firmware console memory may be
    unmapped. Called only after `vt_share` has retired the firmware output on that GPU
    (section 5.3), never before.
12. Teardown: `applyModeSetConfig` with the heads off, `destroySurface`, `unmapMemory`,
    `freeMemory`, `releaseOwnership`, `freeDevice`.

No flip queue is needed: the console draws into the scanned-out buffer directly
(`noDisplayCaching` keeps the display engine reading memory, not a cached copy). Flips
(`applyModeSetConfig` with only the layer changed, `getFlipPendingStatus`) stay unused in
phase 1.

## 3. The mode: keep the firmware's, or pick the native one

Tunable `hw.nvidia_console.mode`:

- `auto` (the default): if the display is the one the firmware lit (the GPU holds the GOP
  framebuffer, section 10) and the firmware's resolution is in its mode list, keep that mode
  (no visible mode change at the hand-over from efifb); otherwise the EDID's preferred mode;
  with no preferred mode, the largest valid mode not above 3840x2160.
- `native`: always the preferred mode.
- `firmware`: the firmware's resolution or nothing on that head.
- `WxH`: that size if the display offers it, else `auto`.

Every choice is logged (`nvidia_console: pci13:1:0:0/DP-1: 1920x1080 (preferred)`) and shown
in the JSON. A mode that `applyModeSetConfig(commit = FALSE)` refuses falls back down the
list; a head with no mode left is reported `state = "failed"` with the reason.

Heads: each connected display gets one head from its `headMask`, assigned greedily in
connector order, each head used once. A display with no free head is `state = "no-head"`.
MST displays are lit like any other (`isDpMST`); clones are not used (each display is its own
output, so each can have its own resolution).

## 4. vt_share: one vt(4) backend, many outputs

### 4.1 Why a fan-out backend

vt(4) has one active backend (`main_vd->vd_driver`), chosen by priority through
`vt_allocate()`. Registering NVIDIA as a second `vt_fb` would replace the Radeon's console,
not share it. So `vt_share` is the one backend and fans out.

### 4.2 The canvas

`vt_share` registers a `struct vt_driver` (`vd_name = "vt_share"`) whose softc starts with a
`struct fb_info` describing a **canvas**: a RAM buffer, 32 bits per pixel, in the kernel's
normal write-back memory. Every drawing call (`vd_blank`, `vd_bitblt_text`,
`vd_bitblt_bmp`, `vd_bitblt_argb`, `vd_drawrect`, `vd_setpixel`, `vd_invalidate_text`)
calls the matching `vt_fb_*` routine of `sys/dev/vt/hw/fb/vt_fb.c` on the canvas (those
routines take the `fb_info` from `vd->vd_softc`), so the glyph and cursor code is FreeBSD's,
unchanged, and then **blits the changed rectangle** to every live output.

The blit is the only code that touches an output, and it is written for the strictest memory
on our platforms (section 9): aligned 32-bit (or 16-bit for 16 bpp) stores only, no
`memcpy`, `bzero` or `dc zva`, no reads from the output. It converts the canvas's XRGB8888 to
the output's pixel layout (`fb_rgboffs`, 16/24/32 bpp).

Canvas size (`kern.vt.share.canvas`, default `auto`): the smallest width and the smallest
height over the live outputs, so the whole terminal fits everywhere. Each output shows the
canvas scaled by the largest integer factor that fits (`scale = auto`), or `1`, or a fixed
factor, and centred; the border is the background colour. A change in the set of outputs that
changes the canvas size resizes the terminal (`vt` re-runs its font and window sizing through
its normal backend re-initialisation); one that does not just blits the canvas to the new
output.

### 4.3 The provider registry

```c
struct vt_share_output_desc {           /* filled by the provider (src/vt-share/vt_share.h) */
	uint32_t	 vso_abi;               /* VT_SHARE_ABI_VERSION */
	const char	*vso_provider;          /* provider name, for the JSON only */
	device_t	 vso_dev;               /* the PCI device that scans it out */
	const char	*vso_connector;         /* connector name; vt_share builds the id (4.4) */
	uintptr_t	 vso_vbase;             /* the provider's kernel mapping */
	uint32_t	 vso_width, vso_height, vso_stride, vso_bpp;
	uint32_t	 vso_roff, vso_goff, vso_boff, vso_rlen, vso_glen, vso_blen;
	const char	*vso_memattr;           /* for the JSON only */
	int		 vso_connector_order;   /* the provider's order on its device */
	int		 vso_score;             /* tie-break when two providers claim one output */
};
struct vt_share_output_ops {
	void	(*vso_enter)(void *softc);  /* the output is shown again (may sleep) */
	void	(*vso_leave)(void *softc);  /* stop: another owner has the display (may sleep) */
};
int  vt_share_output_register(const struct vt_share_output_desc *,
         const struct vt_share_output_ops *, void *softc, struct vt_share_output **);
void vt_share_output_park(struct vt_share_output *);    /* lock-free: stop blitting */
void vt_share_output_unpark(struct vt_share_output *);  /* blit the whole canvas again */
int  vt_share_output_unregister(struct vt_share_output *); /* waits for in-flight blits */
int  vt_share_firmware_live(device_t);  /* a live firmware output scans out from it */
```

The provider passes the device and the connector name; `vt_share` builds the stable id from
the device's PCI address, so a provider cannot hand in an id that does not match its device.

`vt_share` has no vendor names or PCI IDs in it; a lint test greps for them and the test
suite plants one to prove the lint fails. A **fake provider** (an in-memory framebuffer) is
used by the unit tests, which run the selection, layout, configuration, JSON and blit code
in user space with no real provider registered. When two providers register an output for
the same `device_t` with the same connector, the higher `vso_score` wins and the choice is
logged.

Locking: registration takes an `sx`. The draw path never takes it: the live output list is
an array published with a release store and read with an acquire load; a retired array is
freed only after `vt_share` has seen a full `vt` flush on every CPU (an `epoch(9)` section
around the blit). The panic path reads the same array and takes no lock at all.

### 4.4 Stable output ids

Never an index (hardware-preflight-and-verify, #2422). An id is the PCI address of the
scanning-out device in FreeBSD's `pci<domain>:<bus>:<slot>:<function>` form, a slash, and the
connector name:

- NVIDIA: the connector type and its `physicalIndex`, as NVKMS reports them:
  `pci13:1:0:0/DP-1`, `pci13:1:0:0/HDMI-0`; an MST display adds its DP address
  (`pci13:1:0:0/DP-1-1.2`).
- the firmware framebuffer: the device whose BAR holds the GOP framebuffer, then `/efifb`
  (`pci12:3:0:0/efifb`), or `efi/efifb` when no BAR holds it.
- a drm-kmod fbdev (phase 2): the device, then `/fb` (drm-kmod already clones its fbdev to
  its own connectors).

### 4.5 The firmware output and the priority

`vt_share` attaches when its first provider-backed output registers (a module that only
loads does nothing visible). At that point it registers the built-in firmware output if the
loader passed `MODINFOMD_EFI_FB`: it maps the GOP framebuffer exactly as `efifb` does (the
same attribute, honouring `hw.efifb.cache_attr`, so the two mappings of that page never
differ), then calls `vt_allocate()` with its own driver. The `efifb`, `vt_fb` or `vbefb`
backend it replaces stays as vt's previous backend, so `vt_deallocate()` on unload gives the
console back to it.

Priority `VD_PRIORITY_GENERIC + 15`: above `vt_fb` and `efifb`, below drm-kmod's `drmfb`
(`GENERIC + 20`) in phase 1, so a Radeon that loads later still takes the console the way it
does today (no regression for a Radeon-only host), and loading `amdgpu` before
`nvidia_console` keeps the order that works (section 11). Phase 2 raises it once drm-kmod's
fbdev is a provider (section 11.2).

## 5. Registration order relative to efifb, and the hand-over on one GPU

### 5.1 The order at boot

1. The loader leaves a GOP framebuffer; `efifb` is vt's backend (as today).
2. `kld_list` loads the drm-kmod drivers first (when the host has any), then `nvidia`,
   `nvidia_modeset`, `nvidia_console` (which pulls `vt_share` in by `MODULE_DEPEND`).
3. `nvidia_console` lights the NVIDIA heads and registers them; `vt_share` registers the
   firmware output, takes the vt backend, and the console shows on the firmware's monitor and
   on every NVIDIA monitor at once.

### 5.2 The GOP is on another GPU

Nothing more: the firmware output keeps showing (efifb's monitor), the NVIDIA heads are
extra outputs.

### 5.3 The GOP is on the NVIDIA GPU itself

The RM reserved that memory (`vtFbBaseAddress`), so drawing to it stays safe until
`framebufferConsoleDisabled`. `nvidia_console` lights its heads with its own surfaces, which
replaces the firmware's scanout on that GPU; the firmware output then shows nothing, so
`vt_share` **retires** it (an output whose `vso_dev` equals a registered provider output's
`vso_dev` is retired, unless `kern.vt.share.outputs` names it). Only after the retire has
returned (no blit in flight) does `nvidia_console` call `framebufferConsoleDisabled` so the
RM may free and unmap the reservation.

## 6. The hand-off protocol (KMS clients)

### 6.1 The NVKMS patch: a console owner

A new KAPI member (appended last; `NVKMS_KAPI_CBSD_LAYOUT` goes to `+cbsd-kapi.3`, and the
kld version of `nvidia_modeset` goes up with it so a mixed pair is refused at `kldload`):

```c
NvBool (*setConsoleOwner)(struct NvKmsKapiDevice *device,
                          void (*yield)(void *arg), void (*reclaim)(void *arg), void *arg);
```

It marks the calling KAPI device, which must hold ownership, as a console owner. In
`GrabModesetOwnership()`, when the current owner is a console owner and another client asks:
NVKMS calls `yield(arg)`, moves ownership to the new client, and the grab succeeds. When
that client releases ownership or closes (the paths that today end in `RestoreConsole()`),
NVKMS skips its own console restore for a device with a console owner and calls
`reclaim(arg)` instead; the console restore timer and resume call it too when the display has
no owner.

**Both callbacks run with `nvkms_lock` held**, synchronously. NVKMS has no lock-free context to
defer to: its timers on FreeBSD also run under `nvkms_lock` (`nvkms_taskqueue_callback()` in
`nvidia-modeset-freebsd.c`). So a callback must never call into the KAPI table or take a lock a
KAPI caller holds. `yield` only parks the GPU's outputs (`vt_share_output_park()`, an atomic
store) and returns; `reclaim` only enqueues a task, and that task grabs ownership, re-applies
the console modeset and unparks the outputs. `reclaim` can be called more than once for one
release (release, timer, resume), so the task is idempotent: it does nothing when the console
already owns the display. A console owner that unloads clears itself first
(`setConsoleOwner(device, NULL, NULL, NULL)`); clearing while nobody owns the display makes
NVKMS restore the firmware console itself, so the display is never left with no one to
restore it.

This covers every client the same way: X or a compositor through `/dev/nvidia-modeset`, our
native DRM module (#2381) through the KAPI, and a crashed client (its close releases). The
patch does not widen who may grab: without a console owner the display has no owner, and any
client allowed to open `/dev/nvidia-modeset` may grab it; with one, the same clients may grab
it, and the console yields. Who may open the node at all is #2375's seat-daemon rule, which
this change neither needs nor alters.

### 6.2 vt(4) switches

X and Wayland compositors already release NVKMS ownership when their VT is switched away
(VT_PROCESS release) and grab it again when it comes back. With the console owner, a switch
from the compositor's VT to a text VT gives the display back to the console through
`reclaim`; a switch back gives it to the compositor through `yield`. `vt_share` also parks an
output while vt's current window is in `KD_GRAPHICS`, so a client that draws without NVKMS
ownership (none today) is not overdrawn.

### 6.3 In-kernel clients

The native DRM module (#2381) uses the same KAPI grab, so it gets `yield` and `reclaim` for
free. No private call between the two modules is needed.

## 7. The panic and ddb path

- No NVKMS call in panic or ddb: no lock, no RM call. `vt_share`'s drawing callbacks are the
  only code vt runs there; they draw into the canvas and blit to every **unparked** output
  with plain stores into memory that was mapped at registration. `epoch(9)` is skipped when
  `KERNEL_PANICKED()` or `kdb_active`; the output array is read with one acquire load.
- Panic and ddb output goes to **all** live outputs at once (every live output, not just one).
- An output that is parked (a KMS client owns its head) shows the client's buffer, not ours.
  The blind path for it, a polled flip of the console surface into that head, needs an NVKMS
  entry point that runs without its lock; it is filed as follow-up work (#2448 child, phase
  2). Until then a panic while a compositor owns the NVIDIA display shows on every other
  output (another GPU's console, the firmware output, the BMC's monitor) and on the serial
  console.
- `kern.vt.share.panic_test` (write 1, root only, phase-1 test hook) draws a test pattern
  through the panic blit path without panicking, for the test boot.

## 8. Unload safety

- `nvidia_console` unload: for each output `vt_share_output_unregister()` (it returns after
  in-flight blits finish; the canvas keeps drawing to the other outputs), then
  `setConsoleOwner(NULL)`, heads off, `destroySurface`, `unmapMemory`, `freeMemory`,
  `releaseOwnership` (NVKMS's own console restore then runs, so the firmware console comes
  back on that GPU when there was one), `freeDevice`. A failure at any step is logged and the
  remaining steps still run; the module unloads.
- `nvidia_modeset` cannot unload under it (the `MODULE_DEPEND` reference).
- `vt_share` unload: refused (`EBUSY`) while a provider output is registered; otherwise it
  calls `vt_deallocate()` so vt goes back to its previous backend, unmaps the firmware output
  and frees the canvas. Refused while `KERNEL_PANICKED()` or `kdb_active`.
- A GPU that goes away (`remove` callback, hot unplug, a fallen-off-the-bus RM error) is
  handled as an unload of that GPU's outputs.

## 9. Memory attributes: the Altra rule and amd64

`vt_share` never picks a memory attribute for a provider's framebuffer; the provider maps it.

- NVIDIA on arm64: `mapMemory(KERNEL)` ends in the OS layer's kernel mapping, which applies
  `gb10_bar_memattr()`: write-combining is Normal non-cacheable, **except on Ampere Altra and
  Altra Max, where it is Device-nGnRE** (`hw.nvidia.altra_device_wc`, auto-detected from the
  MCFG table; Track #1908, `docs/RENDER-UAPI.md` section 5). Device memory takes aligned,
  non-atomic stores only, which is why the blit (section 4.2) uses only aligned 32/16-bit
  stores and never reads the output.
- NVIDIA on amd64: the same call maps write-combining through the PAT
  (`pmap_mapdev_attr(..., VM_MEMATTR_WRITE_COMBINING)`).
- The firmware output: `efifb`'s attribute, on both architectures (section 4.5).
- The canvas: normal kernel RAM.

`nvidia_console` reports the attribute it got (`hw.nvidia.altra_device_wc_active` on arm64)
in the JSON as `memattr`.

## 10. Several GPUs: which outputs, and the primary

Enumeration is by the providers' own lists (NVKMS's `enumerateGpus`, the loader's GOP
metadata), never an index or a fixed `/dev` node. The GPU the firmware used is the one whose
BAR holds the GOP framebuffer address (UEFI, both architectures) or, with no GOP, the one
`vga_pci_is_boot_display()` names (legacy BIOS on amd64).

Configuration (section 12): `mode = all` (the default) lights and shows every connected head
of every provider; `primary` shows only the primary output; `list` shows only the outputs
named in `outputs`. The primary is `hw.console_share.primary` (a stable id), by default the
firmware's output or, when that is retired, the first output of the firmware's GPU in
connector order; it decides the canvas size when `kern.vt.share.canvas = primary`.

Verify: an output is listed `state = "live"` only after a write and read-back through the
canvas succeeds and its first full blit returned; the JSON carries the enumeration, the
choice and the verify result (the #2422 report shape).

## 11. Sharing with other drivers

### 11.1 Phase 1 (this branch)

The firmware output plus every NVIDIA head. A drm-kmod driver (amdgpu, radeonkms, i915kms)
keeps working as today: when it loads after `vt_share`, its `drmfb` (priority `GENERIC + 20`)
takes the vt backend from `vt_share` and the console moves to it, as it does today; when it
loads before (the recommended `kld_list` order), it already is vt's backend and
`vt_share` registers it as an output through the backend capture below.

Backend capture: when `vt_share` takes the vt backend, the previous backend is kept as an
output if its softc is a framebuffer `vt_share` can address. vt(4) does not say what a
backend's softc is, so the capture uses the `fbd(4)` interface instead of the backend's
name: the backend's `vd_video_dev` is asked for its `fb_info` through `FB_GETINFO`, and only
an `fb_info` that comes back is used. drm-kmod does not attach an `fbd(4)` child today, so
phase 1 captures nothing from drm-kmod and the Radeon's console is not shared yet; the
firmware output and the NVIDIA heads are.

### 11.2 Phase 2 (follow-up work, filed as children of #2448)

- A small cloudbsd-src change to `sys/dev/vt/vt_core.c`: a **backend mux hook**. When a mux is
  registered, `vt_allocate()` offers each new backend (`drv`, `softc`) to the mux instead of
  replacing the current one, and `vt_deallocate()` takes it back. `vt_share` becomes that mux
  and every vt backend (drmfb, vt_fb, efifb, a future one) becomes an output driven through
  its own `vt_driver` ops on a per-output `vt_device`. Upstream-friendly, strippable, never
  submitted without Mark's word.
- The aperture hand-over: drm-kmod's `vt_freeze_main_vd()` stops the firmware backend from
  writing into VRAM that amdgpu is reclaiming, by checking the backend's name. With
  `vt_share` as the backend that check misses, so the mux hook adds
  `vt_share_claim_aperture(base, size)`, which retires any output inside that range before
  the claiming driver touches it; drm-kmod's FreeBSD glue calls it (a two-line patch in our
  drm-kmod port; not LinuxKPI).
- Then the priority goes above `drmfb`, and a Radeon, an NVIDIA card and the GOP all show the
  console at once.
- The polled panic flip for parked NVIDIA heads (section 7).

## 12. Configuration

### 12.1 Loader tunables (read at boot)

| tunable | values | default |
|---|---|---|
| `hw.console_share.mode` | `all`, `primary`, `list` | `all` |
| `hw.console_share.outputs` | comma-separated stable ids (section 4.4) | empty |
| `hw.console_share.primary` | a stable id, or `firmware` | `firmware` |
| `hw.console_share.scale` | `auto`, `1`, `2`, `3`, `4` | `auto` |
| `hw.console_share.canvas` | `auto`, `primary`, `WxH` | `auto` |
| `hw.nvidia_console.mode` | `auto`, `native`, `firmware`, `WxH` | `auto` |
| `hw.nvidia_console.enable` | `0`, `1` | `1` |

### 12.2 Sysctls (writable at run time)

Under `kern.vt.share`, not under `hw.console_share`: vt(4) keeps its run-time knobs under
`kern.vt` (`kern.vt.suspendswitch`, `kern.vt.enable_bell`, `kern.vt.kbd_*`), and `vt_share`
is a vt backend, so an operator finds them with `sysctl kern.vt`. The tunables keep the
names Mark gave, under `hw.`, like other boot-time hardware choices (`hw.efifb.cache_attr`,
`hw.nvidia.*`). Each sysctl starts from its tunable.

| sysctl | type | what |
|---|---|---|
| `kern.vt.share.mode` | string, rw | as the tunable |
| `kern.vt.share.outputs` | string, rw | as the tunable; a write adds or removes outputs live |
| `kern.vt.share.primary` | string, rw | as the tunable |
| `kern.vt.share.scale` | string, rw | as the tunable |
| `kern.vt.share.canvas` | string, rw | `auto` (smallest), `primary`, or `WxH` |
| `kern.vt.share.status` | string, ro | the JSON document of section 12.3 |
| `kern.vt.share.version` | string, ro | `vt_share` version, plus `version_major`, `version_minor`, `version_patch` (integers) |
| `kern.vt.share.abi` | int, ro | the provider ABI number (`VT_SHARE_ABI_VERSION`) |
| `kern.vt.share.panic_test` | int, wo (root) | section 7 |
| `hw.nvidia_console.version` | string, ro | plus `_major`, `_minor`, `_patch` |

A write is validated whole (an unknown id in `outputs` is kept and reported as
`state = "absent"`, so a monitor plugged in later is picked up; a malformed id is `EINVAL`,
and `vt_share` logs the offending item and the expected form,
`pci<domain>:<bus>:<slot>:<function>/<connector>`). A malformed tunable is logged the same way
and the default is kept.

### 12.3 The JSON status

`sysctl -n kern.vt.share.status` prints one document; `tests/schema/vt-share-status-1.schema.json`
is its schema and the tests validate every output against it:

```json
{"schema": "vt-share-status-1",
 "version": {"string": "1.0.0", "major": 1, "minor": 0, "patch": 0},
 "abi": 1,
 "mode": "all", "primary": "pci13:1:0:0/DP-1", "scale": "auto",
 "canvas": {"width": 1920, "height": 1080},
 "outputs": [
   {"id": "pci13:1:0:0/DP-1", "provider": "nvidia_console", "state": "live",
    "selected": true, "primary": true, "width": 2560, "height": 1440, "bpp": 32,
    "scale": 1, "offset": {"x": 320, "y": 180}, "memattr": "Device-nGnRE",
    "verified": true, "reason": null},
   {"id": "pci13:1:0:0/HDMI-0", "provider": "nvidia_console", "state": "live",
    "selected": true, "primary": false, "width": 1920, "height": 1080, "bpp": 32,
    "scale": 1, "offset": {"x": 0, "y": 0}, "memattr": "Device-nGnRE",
    "verified": true, "reason": null},
   {"id": "pci13:1:0:0/efifb", "provider": "efifb", "state": "retired",
    "selected": false, "primary": false, "width": 1920, "height": 1080, "bpp": 32,
    "scale": null, "offset": null, "memattr": "WC", "verified": false,
    "reason": "the GPU's own provider registered an output"}]}
```

`state` is one of `live`, `parked`, `retired`, `absent`, `failed`, `no-head`; an unknown
value is `null` with a `reason`, never a made-up number. Additive fields bump the minor; a
breaking change is `vt-share-status-2`, kept alongside.

## 13. amd64

Every release ships amd64 and arm64. What differs:

- **Mapping.** Write-combining through the PAT (section 9). `vt_share`'s blit is the same;
  WC on amd64 needs no extra barrier for the console (a `sfence` before the panic path
  returns, so the last line reaches the screen before a reset).
- **Firmware hand-off.** UEFI GOP: as on arm64 (`MODINFOMD_EFI_FB`, the x86 value 0x1005 is
  the kernel's own constant). Legacy BIOS / CSM: there is no linear firmware framebuffer, vt
  runs `vt_vga` in text mode (`VDF_TEXTMODE`); `vt_share` then has no firmware output, takes
  the backend from `vt_vga` with its provider outputs only, and gives it back on unload. The
  boot GPU is the one `vga_pci_is_boot_display()` names.
- **VGA arbiter.** FreeBSD has no VGA arbiter; the legacy VGA ranges (I/O 0x3B0-0x3DF,
  memory 0xA0000-0xBFFFF) belong to the boot display. `nvidia_console` never touches them;
  it uses only NVKMS surfaces. A non-boot NVIDIA card's legacy decode is the RM's business,
  unchanged by this work.
- **Build.** Both modules are plain C against `sys/`, with no `#ifdef` on the CPU except the
  panic-path store barrier. The amd64 build runs on amp001 with base clang targeting
  `x86_64-unknown-freebsd16.0`, base `ld.lld` and the same `SYSDIR`
  (`scripts/build-console.sh --arch amd64`), and the result is checked like the arm64 one
  (ELF machine, LLD stamp, no LinuxKPI import).
- **Test plan on an amd64 fleet host with an NVIDIA card.** The host is picked by
  hardware-preflight (vendor 0x10de, class 0x03, a connected display) across the fleet, not
  named here; the same one-shot kit (section 14) runs there with the amd64 modules: dmesg
  shows `VT: Replacing driver "efifb" with new "vt_share"` (or `"vga"` on a BIOS boot), the
  JSON lists every head `live`, the write test passes, and the forced-panic row (behind its
  flag) shows on every head. Until that host exists and is free, the amd64 row is the build
  and the static checks only, and the hand-back says so.

## 14. Tests

- **Host, red first:** the `vt_share` core (configuration parsing, id validation, output
  selection for 0, 1 and several outputs, outputs not at index 0, an Apple-style layout,
  canvas sizing, integer scale and centring, pixel conversion for 16/24/32 bpp, JSON against
  the schema) as user-space C tests with the fake provider; the vendor-name lint and its
  planted failure; the KAPI table layout test extended to `+cbsd-kapi.3`; man pages
  `mandoc -T lint` clean.
- **Build checks:** both modules built for arm64 and amd64 with base LLD (`readelf -p .comment`
  shows `Linker: LLD`), and `kldxref -d -v` plus `nm -u` show no Linuxulator or LinuxKPI
  dependency or import (the native-tools `ko-native` check).
- **One-shot test boot** (`tests/console-sharing-testboot/`, the native-tools kit pattern):
  no amdgpu, no Linuxulator; loads `nvidia`, `nvidia-modeset`, `nvidia_console`; records
  dmesg (vt taking over), `kern.vt.share.*` and `hw.nvidia_console.*`, the JSON, a write test
  (`panic_test` pattern plus a line written to `/dev/console`), the BMC screenshot when the
  kit can reach the BMC, and an optional forced panic behind `--panic`; returns to the normal
  boot environment.

## 15. What phase 1 does not do

- No nvidia-drm and no drm-kmod change; drm-kmod sharing is phase 2.
- No X or Wayland change; they already release ownership on VT switch.
- No change to who may grab NVKMS from user space (#2375 does that).

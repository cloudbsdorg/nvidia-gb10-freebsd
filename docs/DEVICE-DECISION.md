# Device decision: detect, decide, then load (design, Track #2455)

Status: design only. Phase 1 of Track #2455. No code comes with this file. Phase 2 (section 14)
implements it.

"MUST", "MUST NOT", "SHOULD" are meant as in RFC 2119. Where this file says a fact was checked, it
names the file and the function. Where it could not be checked it says **unverified**. Nothing here
promises a date.

Every version this design exposes (driver branch, record, firmware, OS, schema) is a string plus
integer major, minor and patch parts, and `available:false` with a reason when it cannot be read,
so no consumer parses a string to compare versions ("versions as numbers").

## 1. Purpose and Mark's words

Mark, 2026-11-22, on Track #2455:

> We will need to abstract everything; because there are older cards that may or may not have
> features and load different firmware. We need to be dynamic.

and the rule it extends (Mark, 2026-11-19): a factory/builder provider registry for every
multi-vendor path, never `if vendor == ...`. Mark, 2026-11-21: layers from abstract device to
board decorators, indexed feature flags, one definition that generates everything, aliases when
we take over a driver. The interim floor (Mark): "RTX 30 and later ... the driver doesn't attach
to anything less right now." The target (Mark): load this driver and support for all NVIDIA cards
is present.

This file designs one thing: a **decision step** that runs before any driver or firmware module
loads. It detects the display devices, asks every registered provider, picks, and then loads
exactly the firmware and driver modules the chosen provider names (firmware may be none), as root,
in order. Or it refuses with a plain reason. Or it says "no provider yet". It is the yes or no to
loading.

Today vs target: the interim policy is Ampere and later (#2457). The target is every NVIDIA card
through one driver and one package. The core must take each new backend with no core change.

What it replaces:

- the devd rule that loads `nvidia-drm` for any vendor 0x10de display device;
- the `MODULE_DEPEND` lines that load two firmware modules whenever `nvidia.ko` loads;
- the hand-written vendor/class match in `make preflight`.

## 2. What happens today, and why it is wrong

Checked in this repository:

1. `devd/nvidia_gb10.conf`: on any `vgapci` attach with vendor 0x10de, run
   `kldload -n nvidia-drm` (when `nvidia_gb10_autoload=YES`). It looks at the vendor only.
2. `patches/patch-zz-nvidia_fw_depend_pci.c` (Track #2417): `nvidia.ko` has
   `MODULE_DEPEND(nvidia, nvidia_gsp_ga10x_fw_fw, ...)` and, on amd64,
   `MODULE_DEPEND(nvidia, nvidia_gsp_tu10x_fw_fw, ...)`. Both firmware modules load whenever
   `nvidia.ko` loads, for every card, including cards that need only one or none.
3. `scripts/make.sh`, `nvidia_devices` and `collect_preflight`: preflight selects devices by
   vendor 0x10de and class 0x03 only. It knows nothing about generations.

Checked in NVIDIA's open RM, `src/nvidia/arch/nvalloc/unix/src/osapi.c` (MIT):

- `rm_is_supported_pci_device()` runs at PCI probe. It accepts class 0x03 with subclass 0x00 or
  0x02, vendor 0x10de, device id 0x0020 or higher, and calls `rm_is_legacy_device()`. In the open
  RM that function is a stub that returns false. So the PCI-time check says yes to every NVIDIA
  display device.
- `rm_is_supported_device()` runs after BAR0 is mapped. It reads `PMC_BOOT_0` and `PMC_BOOT_42`,
  asks `halmgrGetHalForGpu`, and on failure asks `gpumgrIsDeviceRmFirmwareCapable` to choose
  between "does not include GSP, not supported by open nvidia.ko" and "not supported by this
  release". The real generation decision needs a register read.

Why this is wrong. (amp001 is our mixed test box: an AMD card, an NVIDIA card and a BMC display
adapter; section 3.3 describes it.)

| Problem | Effect |
|---|---|
| Vendor-only match | A Pascal card or an unsupported board gets the driver loaded, attaches nothing useful, and the user sees a late, vague failure. |
| Blanket firmware | amd64 loads both firmware modules always. arm64 never tries `gsp_tu10x` (not built): Turing and GA100 fail at first open, no image. |
| One answer for the whole machine | amp001 has an AMD card, an NVIDIA card and a BMC display adapter. The rule must work per device and never assume index 0. |
| Policy buried in code | The interim Ampere floor (`agent/2457-ampere-floor`) is a named constant in `nvidia.ko`. It should be data. |
| Stage mixing | The PCI-time check accepts everything, so the only real check is inside the driver, after the module is already loaded. |

## 3. Survey

### 3.1 NVIDIA generations

Sources: the architecture values are `src/common/inc/swref/published/nv_ref.h`; the GSP families
are `src/nvidia/arch/nvalloc/common/inc/nv-firmware-chip-family-select.h` and
`kernel-open/common/inc/nv-firmware.h`; the id ranges are from
`NVIDIA-FreeBSD-x86_64-580.178.04/doc/supported-gpus/supported-gpus.json` (2312 entries; zlib
licence). The json has **no architecture field**. A range-to-family map is therefore our derived
data. Stage 2 (section 8) confirms it on the real chip.

Firmware (GSP) capable means BOOT_42 architecture at or above TU100 (`gpu_mgr.c`,
`_gpumgrIsRmFirmwareCapableChip`). Architecture values: GM100 0x11, GM200 0x12, GP100 0x13,
GV100 0x14, GV110 0x15, TU100 0x16, GA100 0x17, GH100 0x18, AD100 0x19, GB100 0x1A, GB200 0x1B.

Identity and firmware (device ids derived from the json):

| Generation | Arch value | Device ids | Example cards | GSP family: image |
|---|---|---|---|---|
| Blackwell | 0x1A, 0x1B | 0x2200 and up | `0x2D04` GB206 (amp001), `0x2C05` RTX 5070 Ti, `0x2E12` GB10 | GB10X, GB10Y, GB20X, GB20Y: `gsp_ga10x` |
| Hopper | 0x18 | 0x2200 and up | GH100 parts | GH100: `gsp_ga10x` |
| Ada | 0x19 | 0x2200 and up | AD10x cards | AD10X: `gsp_ga10x` |
| Ampere, not GA100 | 0x17 (GA10x implementations) | 0x2200 and up | GA10x cards | GA10X: `gsp_ga10x` |
| Ampere GA100 | 0x17 (GA100 implementation) | below 0x2200, for example `0x20B0` | A100 | GA100: `gsp_tu10x`, not `gsp_ga10x` |
| Turing | 0x16 | `0x1e02` to below 0x2200 | TU10x, TU11x cards | TU10X (to TU106), TU11X: `gsp_tu10x` |
| Volta | 0x14, 0x15 | inside `0x1340..0x1df6` | Titan V (**unverified id**) | none (no GSP) |
| Pascal | 0x13 | inside `0x1340..0x1df6` | GTX 1000 series | none |
| Maxwell | 0x11, 0x12 | inside `0x1340..0x1df6` | GTX 900 series | none |
| Kepler | not in the checked list | `0x0fc6..0x12ba` (470.xx) | GTX 600 and 700 series | none |
| Fermi | not in the checked list | `0x06c0..0x1251` (390.xx) | GTX 400 and 500 series | none |
| Tesla and older | not in the checked list | 340.xx `0x0191..0x10d8`; 367.xx (3); 304.xx, 173.14.xx, 96.43.xx, 71.86.xx | GeForce 8 and 9, older | none |

Exact bounds inside `0x1340..0x1df6` (Volta, Pascal, Maxwell) are derived at generation time.

Status today:

| Generation | 580 backend today | arm64 today | Interim floor (#2457) | Path to coverage |
|---|---|---|---|---|
| Blackwell | open RM (`kernelopen`) | works (our open RM core) | supported | none needed |
| Hopper | open RM | builds; untested on hardware (**unverified**) | supported | none needed |
| Ada | open RM | as Ampere (**unverified**: no Ada card tested) | supported | none needed |
| Ampere, not GA100 | open RM | works | supported | none needed |
| Ampere GA100 | open RM | no `gsp_tu10x` image: fails at first open | floor says yes; firmware is missing | 4.5, 3.1.1 |
| Turing | open RM | no `gsp_tu10x` image: fails at first open | below the floor | build `gsp_tu10x` for arm64, edit policy |
| Volta, Pascal, Maxwell | closed RM, amd64 | no NVIDIA binary; no support | below the floor | section 11 |
| Kepler | legacy 470.xx, closed, amd64 and i386 | none | below the floor | section 11 |
| Fermi | legacy 390.xx, closed | none | below the floor | section 11 |
| Tesla and older | legacy 340.xx and older, closed | none | below the floor | section 11 |

The id ranges for Kepler, Fermi and Tesla overlap by number (Fermi `0x06c0..0x1251` and Kepler
`0x0fc6..0x12ba` share values). The generator therefore keys on the exact `devid` list per
`legacybranch`, never on a range. Ranges are only a compact way to print and to match the
open-capable and no-legacy-branch groups.

The json counts, for the record: no `legacybranch` plus `kernelopen` is `0x1e02..0x31c2`; no
`legacybranch` and no `kernelopen` is `0x1340..0x1df6`; `gsp_proprietary_supported` covers
`0x1e02..0x28f8`. Features seen: `kernelopen` (825), `gsp_proprietary_supported` (743),
`runtimepm`, `hdmi4k60rgb444`, `dpycbcr420`, `dpgsynccompatible`, `hdmigsynccompatible`,
`vdpaufeatureset` A to K.

Open-capable ids below 0x2200 are TU10x, TU11x and GA100 (image `gsp_tu10x`); 0x2200 and up are
`gsp_ga10x`. That split is our reading of the table and the family-select header. It is data in
the provider record, and stage 2 checks it.

#### 3.1.1 The GA100 wrinkle

GA100 is Ampere by architecture value (0x17) and uses the `gsp_tu10x` image
(`kernel-open/common/inc/nv-firmware.h`). This repository builds `gsp_tu10x` on amd64 only
(README, "Firmware"). A rule that reads "architecture at or above Ampere" would accept an A100 on
arm64 and then fail for lack of firmware. The record fixes this without special code: firmware is
chosen per family, and each family lists the architectures it is available on (section 4.5). For
GA100 the record says family `ga100`, image `gsp_tu10x`, available on amd64, so on arm64 the plan
step refuses with "firmware gsp_tu10x is not built for arm64" before anything loads. GA100 and the
GA10x group share architecture value 0x17, so stage 2 tells them apart by (architecture,
implementation) and stage 1 by device id (section 4.3, `impl_values`). `0x20b0` is simply outside
the `0x2200..` range.

### 3.2 AMD and Intel (design depth)

Sources: FreeBSD base, `/usr/libexec/fwget/pci_video_amd` and `pci_video_intel` (BSD-2-Clause), and
`devmatch(8)`, `kldxref(8)`, `devd.conf(5)`. We copy no GPL table. The providers get their match
data from the installed module and from `fwget`.

AMD (`amdgpu`):

- Claimed by the module that exports PNP info for the PCI id (`devmatch` over `linker.hints`).
- Firmware: `fwget` maps device id patterns to `gpu-firmware-amd-kmod-<chip>` packages
  (`pci_video_amd`; for example `0x678*` to `tahiti`, `0x730*` to `fiji`).
- Architectures: amd64 and arm64.
- Capabilities: display, compute (where the stack provides it), PRIME, runtime PM.

Intel (`xe`, `i915`):

- Claimed the same way, by the module's PNP info.
- Firmware: `fwget` maps ids to `gpu-firmware-intel-kmod-<gen>` (`pci_video_intel`; for example
  `0x9a*` to `tigerlake`, `0x4c*` to `rocketlake` plus `tigerlake`).
- Architectures: `xe` covers arm64. `i915` is amd64-only tested, so the i915 record lists only
  amd64 in `archs` and an arm64 box is refused for i915 ("not built"; section 4.3, rule for built
  and tested).
- Capabilities: display, PRIME, runtime PM.
- Not yet known: which Intel parts `fwget` does not map. The table covers Skylake to Alder Lake
  and DG1; newer parts are **unverified**.

A provider asks, in this order: does the installed module say it claims this id (`devmatch`)?
Which firmware packages does `fwget` name for it? Both answers go into the plan as `package` steps. A package step is a precondition, not an action:
if the package is not installed, the device is `refused` with code `needs_install` and the exact
command (`pkg install ...` or `fwget`) in `next`. devd never fetches anything. The fetch on
detection belongs to `make install` and `fwget`, as the firmware rules in section 4.5 say.

ASPEED (the BMC display adapter, 0x1a03:0x2000 on amp001) and any other display-class device with
no provider report "no provider" and are never loaded by us.

### 3.3 amp001, the real mixed box

`pciconf -lv` on amp001 shows `vgapci0` AMD 0x1002:0x7480 (Navi 33, RX 7600), `vgapci1` NVIDIA
0x10de:0x2d04 (GB206, subsystem 1462:5351), `vgapci2` ASPEED 0x1a03:0x2000 (BMC). The NVIDIA card
is not index 0. Every design choice below has to work on this box without a special case.

## 4. The model

### 4.1 Layers

```
abstract device     identity, bus location, lifecycle, status, flags (all available:false)
  class             GPU (later: Wi-Fi, Bluetooth, Ethernet)
    family          generation/chipset base: matches by vendor:device range or chip id
      decorators    board variants keyed by subsystem id; add or override only
```

- **Abstract device.** What `pciconf` gives: selector, vendor, device, subvendor, subdevice,
  class, revision. Every other field starts as `available:false` with a reason.
- **Class.** The class owns the ops table type and the flag set. The first class is GPU. The
  machinery (registry, records, flags, generator, aliases) is class-neutral; Ethernet is the next
  class in Mark's plan, and none of it starts until Mark says so.
- **Family.** The default. A family record says what a device matching it gets: firmware, driver
  path, supported generations, features.
- **Decorators.** Keyed by subvendor:subdevice. A decorator MAY add a feature, override an option,
  or change a firmware choice. A decorator MUST NOT decide whether a device is supported. Two
  decorators that disagree on the same key and field are an error at generation time.
- **Minimal.** The generator emits a decorator only when a real json entry (or measured device)
  differs from its family base. No decorator and no flag exists without a real device behind it.

Consumers work only against the abstract and class contract. Nothing outside a provider names a
vendor.

### 4.2 Provider ops table (vendor-free sketch)

```c
#define DEV_SELECTOR_MAX 32          /* parsers reject a longer selector or version string */
#define DEV_VERSION_MAX  32          /* with an error, never truncate */

/* identity as read from PCI config space; no vendor field is interpreted by the core */
struct dev_id {
	uint16_t vendor, device, subvendor, subdevice, revision;
	uint32_t pci_class;                 /* class, subclass, progif */
	char     selector[DEV_SELECTOR_MAX];/* "pci0:3:0:0": whatever pciconf printed */
};

struct dev_version {                        /* versions as numbers */
	char     string[DEV_VERSION_MAX];
	uint32_t major, minor, patch;
	int      available;                 /* 0: parts read 0 */
	const char *reason;                 /* set when !available */
};

struct dev_feature {                        /* one entry per index in the record's features[] */
	uint16_t    index;
	int         available;
	const char *value;                  /* NULL unless the feature carries a value */
	const char *reason;                 /* set when !available */
};

#define DEV_MINE      0              /* the provider names this id */
#define DEV_NOT_MINE  1000           /* outside the errno range; any other non-zero is an error */

struct dev_match {                          /* result of match() */
	const char *family;                 /* opaque to the core */
	const char *board;                  /* decorator name or NULL */
	const char *const *backends;        /* candidate set, host-arch filtered; may be empty */
	size_t      nbackends;
	const struct dev_feature *features; size_t nfeatures;
	const char *refuse_code;            /* non-NULL: claimed, but refused (policy, not built, ...) */
	const char *refuse_reason;
	const char *next;                   /* what to do about a refusal */
	const char *warning;                /* for example "not_tested_on_arm64"; may be NULL */
};

enum dev_step_kind { STEP_KLD, STEP_PACKAGE };
struct dev_step {
	enum dev_step_kind kind;
	const char *name;                   /* module or package name, alias-resolved */
};

struct dev_plan {                           /* for one device and the backend bound to it */
	const struct dev_step *firmware; size_t nfirmware;   /* may be empty: no firmware */
	const struct dev_step *driver;   size_t ndriver;     /* in load order */
	const char *backend;
};

struct dev_provider_ops {
	const char *name;
	struct dev_version record_version;
	int  (*match)(const struct dev_id *, struct dev_match *);
	int  (*describe)(const struct dev_match *, struct dev_desc *);   /* name, English parts */
	int  (*plan_load)(const struct dev_id *, const struct dev_match *, const char *backend,
	                  const struct host_info *, struct dev_plan *);  /* arch, installed modules */
	int  (*verify)(const struct dev_id *, const struct dev_plan *, struct dev_verify *);
	const struct dev_capability *caps;                               /* 4.3 */
};

DEV_PROVIDER_REGISTER(nvidia_open);        /* linker-set entry; the core never includes this file */
```

Rules for the ops:

- `match` returns `DEV_NOT_MINE`, or `DEV_MINE` with the struct filled. `DEV_MINE` with an empty
  `backends` and no `refuse_code` means the record names the id and no backend serves it on this
  host (`no_provider_yet`). A `refuse_code` means claimed and refused. Any other return value is
  a `provider_error`: a fifth decision with its reason. It never falls through to a lower-scoring
  provider. A claimed device is not offered to a lower-scoring provider either, unless the record
  sets `fallback_ok`.
- `match` does not choose a backend. It returns the candidate set. The binding step (section 9) is
  the only place a backend is chosen.
- `plan_load` is called for the bound backend. It may use `host_info` (architecture, installed
  modules from `kldxref`, loaded modules) and no vendor knowledge of other providers.
- Plans are counted lists, with no fixed array size. The generator fails when a record exceeds a
  bound it declares itself (`max_steps`, `max_backends`, `max_features`). Fixed buffers (selector,
  version string) stay, with the length check above.
- Group merge: for one backend group, the steps of every device are merged in order (all firmware
  steps, then all driver steps) and de-duplicated by module name.

### 4.3 Capability record (versioned)

Each provider carries one record, generated from its data file (section 5). Every field, with its
default:

| Field | Meaning | Default |
|---|---|---|
| `record_version` | version object of the record schema this provider was generated for | required |
| `provider` | provider name | required |
| `driver_branch` | version object, for example 580.178.04 (section 10) | required for providers with a branch |
| `score` | tie-break between providers (4.6) | 0 |
| `backends[]` | name, `archs`, `modules`, `licence_class`, `exclusive_group`, `score` (backend preference) | required |
| `families[]` | `id`, `arch_values`, `impl_values`, `devids` or `devid_ranges`, `backends`, `firmware`, `tested_arch`, `verified_on_hardware` | required |
| `decorators[]` | board decorators keyed by subvendor:subdevice | `[]` |
| `features[]` | the flag indexes this provider can set; every one appears in the output | required |
| `policy` | `{min_generation, reason}`, for example `ampere` (8.2) | none: no floor |
| `fallback_ok` | a claimed-but-refused device may be offered to a lower-scoring provider | false |
| `on_conflict` | `best_cover` or `refuse` (9.1) | `best_cover` |
| `acknowledged_moves[]` | ids that moved backend on a branch change and were acknowledged (10.3) | `[]` |
| `max_steps`, `max_backends`, `max_features` | declared bounds the generator checks | generator default |

Family fields in more detail:

- `impl_values` lists the implementation values a family covers. It is required when two families
  share an architecture value (GA100 and the GA10x group both have 0x17). The generator fails when
  two families match the same (architecture, implementation) pair.
- `tested_arch` and `verified_on_hardware` are per family. Rule for equal evidence and equal
  outcome: an architecture the family's backend or firmware is **not built** for is `refused`
  (code `not_built_<arch>`). An architecture it is **built for but not tested** on is `supported`
  with the warning `not_tested_on_<arch>` in the output.
- Backend preference is data: each backend has a `score`. Convention: an open backend outscores a
  closed one; the generator checks `rm-open` > `rm-closed` and fails otherwise.

### 4.4 Feature flags

A feature is an indexed, versioned flag: a numeric index, a name, a state. Indexes are stable.
They are never renumbered and never reused. A feature a device does not have, or cannot be
determined, reads `available:false` with a reason. A new feature takes the next index (an
additive change, minor bump of the schema).

| Index | Name | Meaning | NVIDIA source name where one fits |
|---|---|---|---|
| 1 | `display` | native display output | (`nvidia-modeset` present) |
| 2 | `compute` | native compute path | |
| 3 | `uvm` | unified memory interface | |
| 4 | `vulkan` | native Vulkan path | |
| 5 | `cuda` | native CUDA path | |
| 6 | `prime` | cross-GPU buffer import and export | |
| 7 | `runtime_pm` | runtime power management | `runtimepm` |
| 8 | `gsp` | GSP firmware runs the GPU | `gsp_proprietary_supported` (closed RM can run GSP), plus our own family map |
| 9 | `open_rm` | the open RM supports the device | `kernelopen` |
| 10 | `hdmi_4k60_rgb444` | HDMI 4K60 RGB 4:4:4 | `hdmi4k60rgb444` |
| 11 | `dp_ycbcr420` | DisplayPort YCbCr 4:2:0 | `dpycbcr420` |
| 12 | `dp_gsync` | G-Sync compatible over DisplayPort | `dpgsynccompatible` |
| 13 | `hdmi_gsync` | G-Sync compatible over HDMI | `hdmigsynccompatible` |
| 14 | `vdpau_featureset` | VDPAU feature set letter (A to K) is a value, not a bool | `vdpaufeatureset` |

Rows 1 to 6 are what a backend offers. Rows 7 to 14 come from the NVIDIA json where they exist.
Index 14 carries a value; the flag object has `value` (a string) beside `available`.

### 4.5 Firmware per family

A family names the firmware it needs per architecture, or none:

```json
"firmware": {"image": "gsp_tu10x", "module": "nvidia_gsp_tu10x_fw",
             "archs": ["amd64"], "licence_class": "redistributable"}
```

`none` is a legal value (pre-Turing NVIDIA, most of the older families). A family whose image is
not available on the host architecture is refused in `plan_load` with the reason, never loaded
halfway. The licence class is recorded per image, read from the actual licence text. There are
three classes, from our firmware rule:

1. Redistributable: we package and ship it, so the hardware works offline from first boot.
2. A licence with rules (vendor-silicon-only use, legal review pending, no redistribution): we do
   not bundle it. It is fetched automatically when the hardware is detected, never by hand.
3. A licence that requires display or acceptance: the licence text is shown and an explicit accept
   is taken first, in the installer and the fetch tool alike. An automated install needs an
   explicit pre-accepted setting.

When unsure, treat the file as class 2 until the licence is read.

### 4.6 The factory and scoring

```
for each display-class device D (all of them, no index assumed):
    claims = [P for P in registry if P.match(D) == DEV_MINE]    (an error return: provider_error)
    none?   -> decision "no_provider": nothing anywhere names this id
    one?    -> that provider
    several -> highest declared provider score; equal scores broken by provider name; the
               choice and every rejected candidate are logged and reported
then, for the chosen provider's match:
    refuse_code set         -> "refused"
    candidate set empty     -> "no_provider_yet": some record names the id, no backend serves it here
    else                    -> candidate set goes to the binding step (section 9)
```

One definition of the two "no provider" values: `no_provider_yet` means some provider's record
names the id (a planned or uncovered generation, or one dropped by a branch change) and no backend
serves it on this host. `no_provider` means nothing anywhere names it (the BMC display adapter).

The score is a number in the record. It is not computed from vendor knowledge. The log line names
the winner, the losers, and the score of each. A tie by score is reported as a warning in the
output, even though it is resolved.

### 4.7 Lint and the fake provider

- A **fake provider** (`fake`) registers the same ops table with a made-up vendor id and two
  families, one with a decorator and one that refuses. The tests drive the whole decision step
  through it from fake `pciconf -l` text.
- A **vendor-free lint test** greps the core sources (registry, factory, decision tool, generator
  core, JSON writer) for any name from the set of provider names, and for the patterns
  `vendor ==`, `vendor !=`, `0x10de`, `0x1002`, `0x8086`, and a vendor-named switch case. The
  test also carries a planted file with `if (id->vendor == 0x10de)` and MUST fail on it. A lint
  that cannot fail is not accepted.

## 5. The one definition

### 5.1 File format

One JSON data file per provider, `data/providers/<provider>.json`, validated by
`schema/provider-record-1.schema.json`. JSON because the repository already validates JSON against
JSON Schemas, and tooling language is free (the driver side is C; the generator may be Python).
Shape:

```json
{
  "schema_version": "1.0",
  "provider": "nvidia-open",
  "score": 100,
  "fallback_ok": false,
  "on_conflict": "best_cover",
  "driver_branch": {"string": "580.178.04", "major": 580, "minor": 178, "patch": 4},
  "input": {"file": "supported-gpus.json", "licence": "zlib", "sha256": "..."},
  "backends": [
    {"name": "rm-open", "archs": ["amd64", "arm64"], "exclusive_group": "nvidia-rm", "score": 20,
     "modules": ["nvidia", "nvidia_modeset", "nvidia_drm"], "licence_class": "mit"},
    {"name": "rm-closed", "archs": ["amd64"], "exclusive_group": "nvidia-rm", "score": 10,
     "modules": ["nvidia", "nvidia_modeset", "nvidia_drm"], "licence_class": "nvidia-eula"}
  ],
  "policy": {"min_generation": "ampere", "reason": "interim floor, Track #2457"},
  "families": [
    {"id": "gsp_ga10x_group", "arch_values": [23, 24, 25, 26, 27],
     "impl_values": ["ga10x", "ad10x", "gh100", "gb10x", "gb10y", "gb20x", "gb20y"],
     "devid_ranges": [["0x2200", "0x31c2"]],
     "note": "the firmware group: Ampere (not GA100), Ada, Hopper, Blackwell. GA100 has the same arch value 23 and is told apart by impl_values (stage 2) and by device id (stage 1)",
     "backends": ["rm-open", "rm-closed"], "tested_arch": ["arm64"], "verified_on_hardware": ["0x2d04"],
     "firmware": {"image": "gsp_ga10x", "module": "nvidia_gsp_ga10x_fw", "archs": ["amd64", "arm64"]}},
    {"id": "ga100", "arch_values": [23], "impl_values": ["ga100"], "devids": ["0x20b0"],
     "backends": ["rm-open", "rm-closed"], "tested_arch": [], "verified_on_hardware": [],
     "firmware": {"image": "gsp_tu10x", "module": "nvidia_gsp_tu10x_fw", "archs": ["amd64"]}}
  ],
  "decorators": []
}
```

`decorators` is empty until a real board needs one. The values in this sample are illustrations of
the shape, not the final table: the real file is generated from the json input (5.2). The `impl_values` names are placeholders for the
implementation numbers the generator takes from the NVIDIA headers.

### 5.2 Inputs

- `supported-gpus.json` from the NVIDIA package is an **input** to the generator for the NVIDIA
  provider. It is never copied by hand into a table. `scripts/fetch-sources.sh` stages it next to
  the other pinned sources, with its checksum in `SOURCES`. The file is under the zlib licence:
  the notice stays with it, and any output that alters it says so ("generated from NVIDIA
  supported-gpus.json, altered").
- Our own additions (the family-to-firmware map, the arch availability, the policy field) live in
  the provider data file, not in the generator.
- For AMD and Intel there is no input table to copy; the provider reads the installed module's PNP
  data and the `fwget` tables at run time.

### 5.3 Generator and outputs

One generator, `scripts/gen-device-tables` (any language; it takes the data files and inputs and
writes files; it makes no network calls). It writes:

| Output | Used by |
|---|---|
| C tables (`generated/nvidia_provider_table.h`) | the in-kernel stage 2 check (section 8) and the user-space provider |
| devd conf (`generated/devd/device-decide.conf`) | devd (section 7) |
| manifests and install lists (`generated/manifests/*`) | `make install`, `make deinstall`, the package |
| JSON Schema (`schema/device-decision-1.schema.json`, `schema/provider-record-1.schema.json`) | the decision tool output and the data files |
| schema samples (`schema/samples.json` rows, fixtures) | `schema-check` |

### 5.4 Drift test

`tests/device_tables_test.sh` regenerates every output into `$TMPDIR`, diffs it against the
committed copy, and fails on any difference. It also fails when a provider data file does not
validate against its schema, when two decorators conflict, when a firmware module named by a
family is absent from the manifests, when two families match the same (architecture,
implementation) pair, when `rm-open` does not outscore `rm-closed`, and when a record exceeds a
bound it declares. The build runs it, so a hand edit of a generated file, or a
data edit without regeneration, fails the build. The test has a planted-drift case that MUST fail.

## 6. The decision step

### 6.1 Tool name

The tool is class-neutral: `device-decide`, with `--class gpu` (default `gpu` for now). Its name
goes through the alias layer (section 12), so the rebrand renames data. The man page is
`device-decide(8)` with a COMPATIBILITY section.

### 6.2 Inputs

Stage 1 reads PCI config space only, through `pciconf -l` (or `devinfo` where it answers better):
vendor, device, subvendor, subdevice, class, revision, selector. It also reads host facts: machine
architecture, loaded modules (`kldstat`), indexed modules (`linker.hints` through `kldxref`
data and `devmatch`), installed firmware packages.

Why stage 1 does not probe BAR0: reading `PMC_BOOT_0` and `PMC_BOOT_42` needs a mapped BAR0 and a
device with memory decode on. With no driver attached, memory decode may be off, and turning it on
means writing the PCI command register behind the PCI bus driver's back. A `/dev/mem` read of BAR0
would also race the bus code and any driver that attaches, and on arm64 it would need the right
memory attribute (the BAR0 Device-memory fix in this repository exists because the wrong one is
unsafe). It also makes a user-space tool poke hardware before a policy says yes. It is rejected. The stage 2 check in the
driver does the register read at the one time it is safe (section 8).

### 6.3 Algorithm

1. **Enumerate** every display-class device (class 0x03, any subclass) from `pciconf -l`. If
   `pciconf` itself fails, the answer is "could not look", not "no device".
2. **Match.** For each device, run the factory (4.6). The outcome is `refused`, `no_provider_yet`,
   `no_provider`, `provider_error`, or a **candidate set of backends** (host-arch filtered). No
   backend is chosen here.
3. **Bind** (section 9). Group the devices that have candidates by `exclusive_group`. For each
   group choose one backend. Each device's `backend`, `firmware` and `driver` fields come from the
   backend bound to its group. A device the bound backend does not cover becomes `refused` with
   code `uncovered`. Then compute one ordered plan per group: for every device of the group,
   firmware steps first, then driver steps, merged and de-duplicated by module name (4.2). Modules
   already loaded are marked `already loaded`, and firmware steps are still planned when the driver
   is already loaded or listed in `kld_list`.
4. **Check** each plan. A device is refused when its firmware is not built for the host
   architecture (`not_built_<arch>`), or a `package` step is not installed (`needs_install`, with
   the exact command in `next`), or a `kld` module is not installed. Each refusal has a stable
   code, a plain reason and a `next` step.
5. **Act**, only with `--act`. Decide-only is the default; `--act` is opt-in. `--act` takes an
   exclusive `flock` on a fixed lock file under `/var/run` so concurrent runs are serialised. As
   root, it runs the `kld` steps of the plan in order: `kldload` each firmware module, then each
   driver module, only for modules that are installed. `--act` plans firmware for **every** device
   of the bound group, not only the triggering one. `--device <selector>` names the device whose
   event triggered the run; it does not limit the plan. A non-root `--act` stops with "needs root"
   and prints the exact command. Without `--act` the tool only decides and prints (what preflight
   and `nvrm-info` use).
6. **Verify.** After the load, ask each provider's `verify` (module present, device attached,
   stage 2 sysctls read back, section 8). The tool computes `agrees` by comparing the image its
   stage 1 chose with the `fw_image` the driver reports, and maps `fw_image` only through the
   provider record's firmware list. Any other value is refused and never passed to `kldload`.
   Report the result per device.

### 6.4 Outputs

English, one line per device. One format:

```
<label> (<selector>): <vendor> <vvvv:dddd> (<name>) <decision>, firmware <modules or none>, driver <modules>
<label> (<selector>): <vendor> <vvvv:dddd> (<name>) <decision>: <reason>; next: <next step>
```

Module names are as `kldstat` lists them (the file name without `.ko`). A list joins names with
`+`, and an empty list reads `none`. The JSON `english` field is byte-identical to the text line.
For amp001:

```
gpu0 (pci0:0:1:0): amd 1002:7480 (Navi 33) supported, firmware gpu-firmware-amd-kmod-navi33, driver amdgpu
gpu1 (pci0:0:2:0): nvidia 10de:2d04 (GB206) supported, firmware nvidia_gsp_ga10x_fw, driver nvidia+nvidia_modeset+nvidia_drm
gpu2 (pci0:0:3:0): aspeed 1a03:2000 (BMC display adapter) no_provider: no record names this device; next: none, it is never loaded
```

A refused line (an A100 on an arm64 box):

```
gpu0 (pci0:0:4:0): nvidia 10de:20b0 (GA100) refused: firmware gsp_tu10x is not built for arm64; next: use an amd64 host, or build gsp_tu10x for arm64
```

(The `gpuN` label is the position in this run's enumeration. It is a label, not a device node and
not the `nvidiaN` unit; the selector identifies the device, and the driver's own log and sysctls
use `nvidia<unit> (<selector>)`.)

Decisions: `supported`, `refused`, `no_provider_yet`, `no_provider`, `provider_error`. Every
refusal carries a `next` field (JSON) and the clause in the English line. A `supported` device may
carry warnings, for example `not_tested_on_arm64`.

`--json` prints one document. `--jsonl` prints JSON Lines: a header record, one record per
device, one per plan, one per verify result, an end record. The schema is
`schema/device-decision-1.schema.json`, generated, registered in `schema/samples.json`, and
enforced like the existing schemas. Versions are objects as in "versions as numbers". Every index
in the chosen provider's `features[]` appears in a device's `features` list (available true or
false, with a reason when false), and the schema requires it. A device with no provider
(`no_provider`) has an empty `features` list: that is the rule for it.

Example for amp001 (selectors, the AMD record and the NVIDIA feature values are illustrative, not
read from hardware):

```json
{
  "schema_version": "1.0",
  "tool": "device-decide",
  "host": {"arch": "arm64", "os": "FreeBSD", "os_release": {"string": "16.0-CURRENT", "major": 16, "minor": 0, "patch": 0, "suffix": "-CURRENT"}},
  "enumeration": [
    {"selector": "pci0:0:1:0", "label": "gpu0", "vendor": "0x1002", "device": "0x7480",
     "subvendor": "0x1002", "subdevice": "0x0e1d", "class": "0x030000", "revision": "0xc1"},
    {"selector": "pci0:0:2:0", "label": "gpu1", "vendor": "0x10de", "device": "0x2d04",
     "subvendor": "0x1462", "subdevice": "0x5351", "class": "0x030000", "revision": "0xa1"},
    {"selector": "pci0:0:3:0", "label": "gpu2", "vendor": "0x1a03", "device": "0x2000",
     "subvendor": "0x1a03", "subdevice": "0x2000", "class": "0x030000", "revision": "0x41"}
  ],
  "devices": [
    {"label": "gpu0", "decision": "supported", "provider": "amd", "family": "navi33", "board": null,
     "backend": "amdgpu", "warnings": [],
     "english": "gpu0 (pci0:0:1:0): amd 1002:7480 (Navi 33) supported, firmware gpu-firmware-amd-kmod-navi33, driver amdgpu",
     "firmware": [{"module": "gpu-firmware-amd-kmod-navi33", "kind": "package"}],
     "driver": [{"module": "amdgpu", "kind": "kld"}],
     "features": [
       {"index": 1, "name": "display", "available": true},
       {"index": 6, "name": "prime", "available": true},
       {"index": 7, "name": "runtime_pm", "available": true}]},
    {"label": "gpu1", "decision": "supported", "provider": "nvidia-open",
     "family": "gsp_ga10x_group", "board": null, "backend": "rm-open",
     "warnings": [],
     "english": "gpu1 (pci0:0:2:0): nvidia 10de:2d04 (GB206) supported, firmware nvidia_gsp_ga10x_fw, driver nvidia+nvidia_modeset+nvidia_drm",
     "firmware": [{"module": "nvidia_gsp_ga10x_fw", "kind": "kld"}],
     "driver": [{"module": "nvidia", "kind": "kld"}, {"module": "nvidia_modeset", "kind": "kld"},
                {"module": "nvidia_drm", "kind": "kld"}],
     "driver_branch": {"string": "580.178.04", "major": 580, "minor": 178, "patch": 4},
     "features": [
       {"index": 1, "name": "display", "available": true},
       {"index": 2, "name": "compute", "available": true},
       {"index": 3, "name": "uvm", "available": true},
       {"index": 4, "name": "vulkan", "available": false, "reason": "native Vulkan not started (Track #2379)"},
       {"index": 5, "name": "cuda", "available": false, "reason": "native CUDA launch not implemented (Track #2362)"},
       {"index": 6, "name": "prime", "available": false, "reason": "not merged (Track #2228)"},
       {"index": 7, "name": "runtime_pm", "available": false, "reason": "not listed in supported-gpus.json for this id"},
       {"index": 8, "name": "gsp", "available": true},
       {"index": 9, "name": "open_rm", "available": true},
       {"index": 10, "name": "hdmi_4k60_rgb444", "available": false, "reason": "not listed in supported-gpus.json for this id"},
       {"index": 11, "name": "dp_ycbcr420", "available": false, "reason": "not listed in supported-gpus.json for this id"},
       {"index": 12, "name": "dp_gsync", "available": false, "reason": "not listed in supported-gpus.json for this id"},
       {"index": 13, "name": "hdmi_gsync", "available": false, "reason": "not listed in supported-gpus.json for this id"},
       {"index": 14, "name": "vdpau_featureset", "available": false, "reason": "not listed in supported-gpus.json for this id"}],
     "aliases": [{"name": "nvidia", "kind": "module", "owner": "this-project", "since": {"string": "1.0.0", "major": 1, "minor": 0, "patch": 0}, "deprecated": false}],
     "replaced_driver": {"name": "nvidia-driver", "kind": "package"}},
    {"label": "gpu2", "decision": "no_provider",
     "english": "gpu2 (pci0:0:3:0): aspeed 1a03:2000 (BMC display adapter) no_provider: no record names this device; next: none, it is never loaded",
     "reason": {"code": "no_provider", "text": "no record names this device"},
     "next": "none, it is never loaded",
     "firmware": [], "driver": [], "features": []}
  ],
  "plans": [
    {"backend": "rm-open", "devices": ["gpu1"], "steps": [
      {"order": 1, "module": "nvidia_gsp_ga10x_fw", "kind": "kld", "state": "loaded"},
      {"order": 2, "module": "nvidia", "kind": "kld", "state": "loaded"},
      {"order": 3, "module": "nvidia_modeset", "kind": "kld", "state": "loaded"},
      {"order": 4, "module": "nvidia_drm", "kind": "kld", "state": "loaded"}]}
  ],
  "verify": [
    {"label": "gpu1", "stage2": {"available": true, "arch": 26, "fw_image": "gsp_ga10x", "fw_loaded": true, "agrees": true}}
  ],
  "exit": 0
}
```

A device whose version cannot be read prints `{"string": "", "available": false, "reason": "..."}`
with no part fields.

### 6.5 Exit codes

| Code | Meaning |
|---|---|
| 0 | every supported device was loaded and verified (including "everything was already loaded and verify passed") |
| 1 | a load or verify step failed (the JSON names the step) |
| 2 | usage error |
| 3 | nothing claimed: every device is `no_provider` or `no_provider_yet`. devd treats only this as normal |
| 4 | could not look (`pciconf` failed) |
| 5 | the stage 2 correction failed (module not installed, not available on this architecture, or a `fw_image` the record does not list) |
| 6 | partial: at least one claimed device is refused, uncovered or `provider_error` while others loaded |
| 7 | every claimed device is refused |

When several apply, the highest-precedence code is reported: 4, then 5, then 1, then 7, then 6,
then 3, then 0. devd logs refusals with `logger -p daemon.warning`.

### 6.6 Man page and docs

`man/device-decide.8` (checked with `mandoc -T lint`), a `README.md` section, and `--help` with
the same text as the man page synopsis. The man page has EXIT STATUS, FILES, EXAMPLES (the amp001
example), SEE ALSO (`nvidia(4)`, `devd.conf(5)`, `devmatch(8)`, `fwget(8)`), and COMPATIBILITY
(section 12).

## 7. Loading as root before the first open

The #2417 fix works because the firmware image is registered before the first open, and the first
open of an unprivileged process cannot load a module (`firmware_get_flags` looks up an already
registered image first and only then checks `PRIV_FIRMWARE_LOAD`; checked in the comment of the
patch and in firmware(9)). Loading from `nvidia_attach` would wait on the kernel linker lock held
by the `kldload` that is running it (same comment). So firmware loading stays outside the driver
and before it, and it needs root.

The decision tool is that root step. The `MODULE_DEPEND` lines go away because the tool replaces
them, not because the need went away.

Paths:

- **devd attach.** `device-decide` generates the devd conf. The action runs as root:
  `device-decide --act --device <selector>`. The match is on the `vgapci` display class, not a
  vendor; the tool says yes or no. It loads the firmware modules of the whole group, then the
  driver. `/dev/nvidiaN` exists only after the driver loads, so no unprivileged open can come
  first. The rule also fires on the driver's own attach event, which covers the case below.
- **Boot, `loader.conf`.** `make configure` runs `device-decide --loader-conf` and writes the
  firmware module line, then the driver lines, from the decision (not from a fixed list). The
  loader loads them in that order. A box with no supported card gets no line. `make install` and
  `make configure` also look for `kld_list` or `loader.conf` lines that load the driver without
  its firmware line, and rewrite them (with the usual backup and a question) or fail loudly.
- **Manual `kldload nvidia`.** Without the `MODULE_DEPEND`, this loads the driver with no
  firmware. The driver MUST NOT hang or panic. It does not fail the attach and it does not need a
  reattach: it stays attached, sets `fw_loaded` to 0, and refuses opens of that device with
  `ENXIO` until the image is registered (the same behaviour as section 8.3). Why `ENXIO`: the
  device is "not configured" yet, and `EIO` stays reserved for a real initialisation failure
  (README, "Diagnostics"), so a caller can tell the two apart. The kernel log gets one line, rate
  limited to at most one per open attempt:
  `nvidia<unit> (<selector>): firmware image <fw_image> is not registered (arch A, impl I); run as root: <tool> --act`
  (names through the alias layer). `nvrm-info` and `make preflight` print the `fw_loaded` state
  with the same command.
- **Stage 2 image different from stage 1.** Section 8.3: same behaviour, and the tool loads the
  right module as root.
- **Already loaded or in `kld_list`.** Checked per module. A module that is already loaded, or
  listed in `rc.conf` `kld_list` (the usual drm-kmod setup for amdgpu and i915), is reported as
  "already loaded" or "already listed". The tool never loads a second copy and never fights
  `kld_list`. Firmware steps are always planned, even when the driver is loaded or listed:
  `kld_list="nvidia-drm"` with `nvidia` loaded and no firmware gives a plan of only the firmware
  module.

Removal of the `MODULE_DEPEND` is one change in `patches/patch-zz-nvidia_fw_depend_pci.c` (the
patch's body shrinks to the log message on missing firmware). It lands in the same change set as
the devd, loader.conf and test changes, never alone. After `make configure` has run, no state
exists where the driver loads and nothing loads its firmware.

Why #2417 still holds: (1) firmware registration still happens before the driver's MOD_LOAD, in the
same `kldload` sequence the tool runs as root; (2) the device nodes appear only after the driver
loads; (3) a test boots a non-root user, runs the tool through devd, and opens the node as that
user (section 14).

## 8. Stage 2 in the driver

Stage 2 runs at attach, after BAR0 is mapped, where the RM already reads `PMC_BOOT_42`
(`rm_is_supported_device()`). We add one step there:

1. Read the architecture (BOOT_42) and the implementation.
2. Look both up in the table generated from the provider record (`generated/nvidia_provider_table.h`).
3. Outside the table (architecture unknown, or below the provider's `policy.min_generation`,
   or no (architecture, implementation) row): **decline with `ENXIO`**, log the architecture value
   and the reason, and create no `hw.nvidia.gpus.<n>` node. The decline is visible in the kernel log
   and in the tool's verify output.
4. Inside the table: publish what was found, and the firmware image the table says it needs.

This replaces the named minimum-architecture constant of the interim floor (section 8.2). It does
not rely on stage 1 being right.

### 8.1 Sysctls (versions as numbers)

Under the existing root `hw.nvidia.gpus.<n>` (README, "Tunables and sysctls"):

| Sysctl | Type | Meaning |
|---|---|---|
| `hw.nvidia.gpus.<n>.arch` | integer | BOOT_42 architecture value |
| `hw.nvidia.gpus.<n>.arch_available` | 0 or 1 | 0 when the value could not be read |
| `hw.nvidia.gpus.<n>.impl` | integer | implementation value |
| `hw.nvidia.gpus.<n>.fw_family` | string | chip family stage 2 found, for example `gb20x`; informational |
| `hw.nvidia.gpus.<n>.fw_image` | string | image the chip needs, for example `gsp_ga10x` |
| `hw.nvidia.gpus.<n>.fw_loaded` | 0 or 1 | the image is registered with firmware(9) |
| `hw.nvidia.provider_record` | string | version of the provider record compiled in |
| `hw.nvidia.provider_record_major`, `_minor`, `_patch` | integer | its parts |
| `hw.nvidia.policy_min_generation` | string | the policy field, for example `ampere` |

A node `hw.nvidia.gpus.<n>` exists only for a device that passed stage 2, so there is no `stage2`
sysctl. The driver cannot know what stage 1 chose: the tool compares stage 1's image with
`fw_image` and reports `agrees`.

The existing `hw.nvidia.version` family and the per-GPU `vbios_*` and `firmware_*` families keep
their meaning. The man page `nvidia(4)` documents the new ones.

### 8.2 The interim floor becomes a record rule

Branch `agent/2457-ampere-floor` adds one named minimum-architecture value inside `nvidia.ko`.
That patch is another agent's work and is not copied here. In this design its content moves to
data. The NVIDIA open-RM provider record carries:

```json
"policy": {"min_generation": "ampere", "reason": "supported generations: Ampere and later, for now"}
```

The generator turns the policy into the number that stage 2 compares against (architecture 0x17
for `ampere`; the mapping from the generation name to the architecture value is a table in the
provider data file, built from `nv_ref.h`). The result lands in the generated C table. The
decision tool uses the same field for stage 1, so both stages give one answer. Turing becomes
supported by editing `min_generation` to `turing` in the data file, regenerating, and making the
`gsp_tu10x` firmware available on arm64 (section 4.5 and 3.1.1). No C is edited.

Until the interim patch is merged and the table exists, the named constant stays. The commit that
introduces the generated table deletes the constant in the same change.

### 8.3 Mismatch handling

In this RM the GSP image is requested at the first open, not at attach. So the missing-image state
needs no detach or reattach, and it is one behaviour whatever the cause (a manual `kldload`, or
range data that put a device in the wrong firmware group, for example `gsp_tu10x` when the chip
needs `gsp_ga10x`):

1. The driver stays attached. It sets `fw_loaded` to 0 and `fw_image` to what the chip needs. It
   cannot know what stage 1 chose, so its log line names only the image:
   `nvidia<unit> (<selector>): firmware image <fw_image> is not registered (arch A, impl I); run as root: <tool> --act`.
2. Until that image is registered, the driver refuses opens of that device with `ENXIO`, with the
   log line above (at most once per open attempt).
3. The devd rule fires on the driver's own attach event (or the tool's verify step runs right
   after its load). The tool reads `fw_image` and `fw_loaded`, compares `fw_image` with the image
   its stage 1 chose, reports the disagreement (`"agrees": false`), and, as root, loads the
   firmware module the record lists for `fw_image`. The next open works. A `fw_image` the record
   does not list (for example `../../x`) is refused, never passed to `kldload`, and exits 5.
4. A disagreement is data to fix: the id-to-family range in the provider record is wrong, and a
   test case is added.
5. If the correct firmware module is not installed or not available on this architecture, the tool
   exits 5 with that reason.

An out-of-policy or unknown architecture is different: it declines with `ENXIO` at attach (step 3
of section 8) and no node exists.

The test plan (section 14) has cases for these.

## 9. One driver for every card

The user never chooses between `nvidia-driver`, `-470` and `-390`. There is one package and one
tool. The tool picks the backend per card.

Honest limit: one `nvidia.ko` serves every NVIDIA card in a box. NVIDIA's legacy FreeBSD drivers
(470, 390, 340) are each a complete `nvidia.ko` with the same module and symbol names as the
current one. Two resource managers cannot be loaded side by side without renaming one. So backend
choice is per RM instance, and a box has one instance today.

### 9.1 Binding

Binding is the only place a backend is chosen (step 3 of section 6.3). Step 2 gave each device a
candidate set; binding picks one backend per `exclusive_group`.

- Each backend declares an `exclusive_group` (for example `nvidia-rm`). At most one backend of a
  group loads.
- For each group, collect the backends that cover each device (the intersection of the devices'
  candidate sets with the group).
- Choose a backend that **covers every device in the group**. When several qualify, the highest
  backend `score` wins. The preference is data: open backends outscore closed ones (checked by the
  generator, 4.3), and the reasons are in the record. The open backend is MIT and builds on
  arm64; the closed backend needs the NVIDIA licence acceptance that `make install` already asks
  for.
- If no single backend covers every device, the tool reports a **conflict** with the reason and
  names the devices each backend would cover. By default (`on_conflict: "best_cover"`) it loads the
  backend that covers the most cards and reports the rest as uncovered (`refused`, code
  `uncovered`, with the reason). The record field `on_conflict: "refuse"` refuses the whole group
  instead. The tool never leaves a card without a driver and says nothing, and never loads a
  wrong driver for a card.
- A card no backend serves on this host is `no_provider_yet` with the reason, and the covered
  cards still load.

What the closed 580 RM covers. NVIDIA's README for the 580.178.04 FreeBSD package, Appendix A1
("Current NVIDIA GPUs"), lists the GPUs the package's driver supports; its first entry is
`1340` (GeForce 830M, Maxwell) and it includes `2F58` (RTX 5070 Ti Laptop GPU) and `31C2` (GB300).
Chapter 27C says: "The GSP firmware will be used by default for all Turing and later GPUs." The
json says only that the open RM supports the `kernelopen` ids and that the closed RM can run GSP
on the `gsp_proprietary_supported` ids (`0x1e02..0x28f8`). So the closed coverage the record
states is the set of ids with no `legacybranch`, which matches Appendix A1 (`0x1340..0x31c2`).
Residual caveat, **unverified**: the README does not say, per id, which ids the package's closed
RM drives without GSP above `0x28f8`; it lists them as supported by the driver. The package driver
is the closed RM on amd64 (README title: "FreeBSD x86_64").

The boxes below describe the target state, with the interim floor (8.2) removed. Today the floor
refuses every pre-Ampere card first. Rows that depend on the closed backend are marked pending
question 2.

| Box | Result |
|---|---|
| one Blackwell card (arm64) | open RM; firmware `gsp_ga10x` |
| Pascal and Blackwell cards (amd64) | closed covers both, open covers only Blackwell, so closed is bound. Pending question 2 |
| Pascal and Ampere cards (amd64) | same: closed is the only full cover. Pending question 2 |
| Pascal and Ampere cards (arm64) | Ampere loads on the open RM; Pascal is `no_provider_yet` (no backend built for arm64) |
| Kepler and Ampere cards (amd64) | conflict (470 versus 580): 580 loads for Ampere, Kepler reported uncovered. Pending question 4 |
| AMD card plus NVIDIA card | different `exclusive_group`s; both plan and load |

### 9.2 Future: namespacing a second RM

Loading the legacy 470 and the current RM together needs: module names, exported symbol names, the
control device node (`/dev/nvidiactl`), the `hw.nvidia` sysctl root and the `nvidiaN` unit
numbers all renamed per instance, in the build, for a closed binary whose own symbol names are
fixed. This is future work; it needs a check of what the closed object lets us rename (**unverified**)
and an NVIDIA licence read for modified binaries. Until then, conflicts are reported, not hidden.

## 10. Driver branch as data

The RM version is a provider record field, `driver_branch`, as a version object. The core has no
branch assumption. Today the value is 580.178.04 (`{"string":"580.178.04","major":580,"minor":178,"patch":4}`).
A 600-series branch is a data and input change.

### 10.1 What changes

| Change | Where |
|---|---|
| the pin | `SOURCES` (NVIDIA package, open-gpu-kernel-modules, checksums) |
| the input | the branch's `supported-gpus.json`, staged by `scripts/fetch-sources.sh` |
| the firmware images and the family map | `data/providers/nvidia-open.json`, from the branch's `nv-firmware.h` and `nv-firmware-chip-family-select.h` |
| the patches | `patches/`: each patch is re-applied and re-tested against the new tree; failures are findings, not silent drops |
| the build of the core | `scripts/build-rmcore.sh` on arm64 against the new open RM; on amd64 the new package's `nv-kernel.o` |

### 10.2 What is regenerated

C tables, devd conf, schema samples and fixtures, manifests, the man page tables that list
families. The drift test (5.4) fails until they are committed.

### 10.3 How the per-generation table moves

The branch's json is the authority. For each device id:

- still no `legacybranch`: stays in its family on this branch;
- newly carries `legacybranch` (the old branch is now the last one for it): the generator moves the
  id to a `legacy` backend record that names that branch, for example 580.xx, with the reason
  `"dropped by the 600 branch; last branch 580.xx"`, and the tool reports it as covered by the
  legacy backend where one is installed and shipped, else `no_provider_yet` with that reason;
- gains a new family: a new family row, flagged "needs a firmware map entry" and failing the
  generator until the map exists.

A card that drops out is never silently reassigned. The generator prints a diff of ids that moved
backends and exits non-zero until a human acknowledges it in the data file
(`"acknowledged_moves": [...]`).

**Unverified:** which generations a 600-series branch drops. Nothing in this file assumes it.
The decision comes only after the branch's `supported-gpus.json` is read.

## 11. Path to full coverage per generation

The target is full coverage: load this driver and support for all NVIDIA cards is present. "No
provider yet" is today's state, not an answer. Order below is by how many cards are in use:
Pascal, Maxwell, Kepler, Volta, then Fermi and older. **This order is our estimate (uncited), from
product age and sales volume. It is to be confirmed against a cited public survey before phase 2
picks the next backend.**

Common to every path:

- **Sources.** NVIDIA's MIT headers and manuals in open-gpu-kernel-modules (under
  `src/common/inc/swref/published/<arch>/`, which includes kepler, maxwell, pascal and volta, and
  the HAL code for maxwell, pascal and volta in mmu, bif, mem_sys, ce and bus under
  `src/nvidia/src/kernel/gpu/*/arch/`); NVIDIA's `open-gpu-doc` if present (**unverified**: not
  fetched here); public specifications; our own hardware tests. Clean-room rules apply. Never
  Linux, GPL or nouveau code, including the nouveau directory inside open-gpu-kernel-modules.
- **What the tree is not.** The open RM tree carries those register manuals and some HAL code. It
  is not a working pre-Turing RM: it has no GR, no PMU and no falcon boot for those chips.
- **Firmware, in general.** Pre-Turing chips have no GSP. Maxwell second generation and later
  need NVIDIA-signed falcon firmware for the secure boot of their engines (**unverified (public
  knowledge; confirm from an NVIDIA source before phase 2)**). Where such firmware
  may legally come from: the closed driver package for that branch (embedded; licence is NVIDIA's
  EULA, which requires acceptance: licence class 3 in section 4.5); NVIDIA's
  redistributable firmware releases if their licence allows redistribution (**unverified**: the actual
  licence text must be read first, and until then the file is treated as class 2, fetched on
  detection). The licence class is recorded per image in the provider record.
- **Core impact.** A new backend is a new provider data file plus (for a native backend) a new
  backend module. The core takes it with no core change.

The interim floor (8.2) applies to every backend of the NVIDIA record, so the closed and legacy
backends below stay dormant until `min_generation` is lowered.

### 11.1 Pascal

- amd64: the closed 580 backend (`rm-closed`): `nvidia.ko` with NVIDIA's prebuilt `nv-kernel.o`.
- arm64: NVIDIA ships nothing. A native backend, written from the Pascal manuals and HAL files.
- Firmware: none for GSP. Signed falcon firmware for secure engines: see above (**unverified**
  which engines on Pascal).
- Hardware at init: BAR setup, memory controller, channel and GR engine init, falcon boot.
- Display: the closed 580 modeset covers it where the display engine class is supported
  (**unverified**: read `src/nvidia-modeset` before relying on it).
- Compute: the closed RM, through NVIDIA's path. Native: new work.

### 11.2 Maxwell

- amd64: the same closed 580 backend.
- arm64: a native backend, after Pascal.
- Firmware, init, display, compute: as Pascal. Second-generation chips need signed falcon
  firmware (see above, **unverified**).

### 11.3 Kepler

- amd64: the legacy 470.xx backend (`rm-legacy-470`): amd64 only, closed, its own `nvidia.ko`,
  exclusive with 580.
- arm64: a native backend; first-generation parts may need no signed falcon firmware
  (**unverified**).
- Firmware: none at the GSP level.
- Init: as Pascal, with the Kepler manuals.
- Display and compute: the 470 driver.

### 11.4 Volta

- amd64: the closed 580 backend.
- arm64: a native backend; the Volta manuals exist in the tree.
- Firmware: signed falcon firmware (see above, **unverified**).
- Init: as Pascal. Display and compute: the closed 580 driver.

### 11.5 Fermi and older

- amd64: the legacy 390.xx and older backends, each amd64 and i386 only, closed, one `nvidia.ko`
  each.
- arm64: a native backend only if demand is shown. The tree has no MIT manuals for Fermi in the
  list we checked (**unverified**).
- Firmware: none. Display and compute: the legacy drivers.

For each legacy backend the provider record carries the module set, the `exclusive_group`, the
licence class (closed, acceptance needed), and `archs: [amd64]` or `[amd64, i386]`. For a native
backend the record names the new module set, and the backend registers as an ordinary provider.

What each path needs, to say it once:

- **Closed backends (amd64).** A package build that stages the branch's closed object, the
  licence acceptance already in `make install`, per-branch module names handled by section 9.2 or
  by the exclusive group. No new core code.
- **Native backends.** A clean-room describer and checker pass over the MIT manuals, an implementer
  that has seen only the clean description (the repository's clean-room process), our own hardware
  tests on cards we hold, the firmware question above settled by licence read, and a display and
  compute plan per generation. Each native backend is a project of its own, planned as one Track
  work package per generation in the order above.

## 12. Neutral names and aliases

Module, package, sysctl, device node and tool names go through one alias layer. It is a data file,
`data/names.json`, keyed by logical name:

```json
{
  "schema_version": "1.0",
  "names": [
    {"key": "driver.core", "kind": "module", "name": "nvidia"},
    {"key": "driver.modeset", "kind": "module", "name": "nvidia_modeset"},
    {"key": "driver.drm", "kind": "module", "name": "nvidia_drm"},
    {"key": "firmware.gsp_ga10x", "kind": "module", "name": "nvidia_gsp_ga10x_fw"},
    {"key": "firmware.gsp_tu10x", "kind": "module", "name": "nvidia_gsp_tu10x_fw"},
    {"key": "tool.decide", "kind": "tool", "name": "device-decide"}
  ],
  "aliases": [
    {"key": "driver.core", "alias": "nvidia", "owner": "this-project",
     "since": {"string": "1.0.0", "major": 1, "minor": 0, "patch": 0},
     "deprecation": {"state": "none"}}
  ]
}
```

The entries above are shapes. The names in `names` are today's names. The neutral names are Mark's
to give (question 9).

Rules:

- Code, devd conf, manifests, the man pages' name tables and the JSON all read names from this
  data. A rebrand is a data rename plus regeneration. No code changes.
- When ours replaces an existing driver, the old names stay as **declared aliases**: owner,
  since-version (a version object), deprecation state (`none`, `deprecated` with a version, or
  `removed`). One owner per device.
- A man page COMPATIBILITY section lists the aliases for the tool and the modules.
- Tests cover: each alias resolves; a removed alias gives a clear error naming the replacement; an
  alias that two providers claim fails generation.
- The JSON reports `aliases` (the names a thing answers to) and `replaced_driver` (the existing
  driver or package ours takes over, for example the `nvidia-driver` package and its `-470`,
  `-390` variants).

## 13. Consumers

One decision, many readers. All call the same tool (or its library) and never re-derive the answer.

| Consumer | How it uses the decision |
|---|---|
| devd | the generated conf matches the display class; the action is `device-decide --act --device <selector>` as root (section 7) |
| `make preflight` | `device-decide --json` replaces `nvidia_devices`; shows decision, reason, `fw_loaded`, command; schema grows additive fields |
| `nvrm-info` | prints the decision and `fw_loaded` with its command per device, beside the generation table and decorators it shows |
| `make configure` | writes `loader.conf` module lines (firmware first) and the devd enable from `--loader-conf`; `make deinstall` removes exactly those |
| install and package | manifests and install lists come from the definition (5.3): only firmware modules some supported family names, per architecture |

## 14. Phase 2 plan and tests

Slices (each lands with its tests; none has a date):

1. Registry, ops table, factory, scoring, fake provider, English and JSON output, lint. No
   vendor code in the core.
2. Data file format, schemas, generator, drift test, committed generated files (still no behaviour
   change).
3. NVIDIA open-RM provider: input from `supported-gpus.json`, families, firmware per arch, policy
   field.
4. Stage 2 in the driver (generated table, sysctls, decline with `ENXIO`, missing-image state); the
   interim floor constant is removed in the same change.
5. Loading as root: devd conf, `--act` with its lock, loader.conf and `kld_list` checks, removal of
   `MODULE_DEPEND`, missing-firmware message.
6. Consumers: preflight, nvrm-info, configure, install.
7. AMD and Intel providers (design in 3.2).
8. The alias layer and `data/names.json`.
9. Backend binding per RM instance (section 9).
10. Next backend (section 11), chosen after the survey is cited.

All tests run from fake `pciconf -l` input and the fake provider. None needs hardware.

| Case | Expected |
|---|---|
| supported NVIDIA card (GB206 `0x2d04`, subsystem 1462:5351) | `supported`, firmware `gsp_ga10x`, driver set named, firmware first |
| NVIDIA id claimed but below policy (Turing on arm64) | `refused`, code `below_policy`; nothing loads |
| NVIDIA id in no family | `no_provider`: no record names it; the fix is a newer input |
| legacy card (a Kepler id) | `no_provider_yet` until a legacy backend record exists; then the candidate is `rm-legacy-470` on amd64 |
| non-NVIDIA card (BMC display adapter) | `no_provider`; never loaded; empty `features` |
| mixed two-vendor box (AMD plus NVIDIA) | two plans, different groups; both decided |
| NVIDIA card not at index 0 | decided by selector; asserted by shuffling the order |
| stage 2 image differs from stage 1 | fake sysctls report another `fw_image`; `agrees:false`; the right module loads; exit 5 if unavailable |
| `fw_image=../../x` | refused, never passed to `kldload`; exit 5 |
| GA100 on arm64 | `refused`, code `not_built_arm64`, with the English line of 6.4 |
| built but untested (Hopper on arm64) | `supported` with the warning `not_tested_on_arm64` |
| i915 on arm64 | `refused` (not built) |
| mixed generations, one backend covers all | one plan, no conflict; the open backend wins only if it covers all |
| mixed generations, no backend covers all | conflict with both device lists; default loads best cover; `on_conflict: refuse` refuses the group |
| two-card box, `--act --device A` | the plan lists both cards' firmware modules before the driver |
| two concurrent `--act` runs | serialised by the lock; the second finds everything loaded |
| `kld_list="nvidia-drm"`, `nvidia` loaded, firmware not loaded | plan is only the firmware module; result loaded |
| run as root without `--act` | nothing loaded |
| `provider_error` from a fake provider | `provider_error`; no fall-through to a lower-scoring provider |
| exit precedence | each pair in the order 4, 5, 1, 7, 6, 3, 0 gives the higher code |
| English line | JSON `english` equals the plain text line for every device |
| over-long selector or version string | parser error, no truncation |
| decorator conflict | the generator fails |
| two families match one (architecture, implementation) | the generator fails |
| `rm-open` not above `rm-closed`, or a record over its declared bound | the generator fails |
| lint | the core is clean; the planted vendor check makes the lint fail |
| drift | a stale generated file or an unregenerated data edit fails the build; the planted drift fails |
| tie by score | resolved by name; warning present |
| manual `kldload` without firmware | driver stays attached; `fw_loaded=0`; open returns `ENXIO`; the log line names the command; no hang |
| #2417 regression | a non-root user opens the node after the devd action and the open succeeds |
| JSON | validates against the schema; versions have string and integer parts; `available:false` has a reason; every feature index appears |
| names | every alias resolves; the removed alias error names the replacement |

## 15. Open questions for Mark

1. **Tool name.** `device-decide` (class-neutral, `--class gpu`) or `gpu-decide`. Options: neutral
   now, or per class. Recommendation: `device-decide`, because Ethernet is the next class in the
   plan and the machinery is shared.
2. **Closed RM on amd64 for a mixed box.** Backend scores prefer open; binding still requires a
   backend that covers every card (9.1). When only the closed RM covers all, we use it (it needs the
   NVIDIA licence acceptance that `make install` already asks for). Options: prefer coverage; or
   prefer open always and report the rest as uncovered. Recommendation: prefer coverage, with the
   licence prompt.
3. **First native backend.** Pascal first (our uncited estimate from sales volume). Options:
   Pascal, or Maxwell with Pascal as a follow-on, since both share the engines. Recommendation:
   Pascal after the cited survey, as one work package per generation.
4. **Conflicts with no covering backend.** Options: load the backend that covers the most cards and
   report the rest; or refuse the whole group. Recommendation: load the best cover and report the
   rest, because a working card beats a refused one, with `on_conflict` in the record to override.
5. **Where Turing sits on arm64.** The floor says Ampere and later. Turing needs `gsp_tu10x` built
   for arm64, which also fixes GA100. Options: build it now, or keep Ampere-only on arm64.
   Recommendation: treat GA100 and Turing as one work package, since they share the image.
6. **Firmware sources for pre-Turing native backends.** Options: extract from NVIDIA's closed
   package (acceptance needed, class 3), or use NVIDIA's redistributable firmware releases if their licence
   allows (unread). Recommendation: read the licence of the redistributable releases first; class 2
   until then.
7. **Namespacing a second RM.** Options: report conflicts only, or invest in per-instance
   renaming of the closed object. Recommendation: report only until a box with a real conflict
   exists and the closed object's licence allows modification.
8. **Provider data format.** JSON (this design) or UCL. Recommendation: JSON, to share the
   validation and the schema checker the repository already has.
9. **Neutral names.** The rebrand names for the modules, package, sysctl root, node and tool are
   yours to give. The design needs them only as data. Recommendation: pick them any time; nothing
   waits on them.
10. **Intel on arm64.** `xe` covers arm64 and `i915` is amd64-only tested. Options: refuse i915 on
    arm64, or allow it with a "not tested" warning. Recommendation: refuse, with the reason.
11. **Stage 1 id ranges.** Our derived split at 0x2200 comes from the json plus the family-select
    header; stage 2 confirms it. Options: ship it as the default, or require a hardware sample for
    each family before it is marked supported. Recommendation: ship it, and mark each family with
    `verified_on_hardware` so the report says which are tested.

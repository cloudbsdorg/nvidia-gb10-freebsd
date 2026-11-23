# Device decision: detect, decide, then load (design, Track #2455)

Status: design only. Phase 1 of Track #2455. No code comes with this file. Phase 2 (section 14)
implements it.

"MUST", "MUST NOT", "SHOULD" are meant as in RFC 2119. Where this file says a fact was checked, it
names the file and the function. Where it could not be checked it says **unverified**. Nothing here
promises a date.

Every version this design exposes (driver branch, record, firmware, OS, schema) is a string plus
integer major, minor and patch parts, and `available:false` with a reason when it cannot be read,
so no consumer parses a string to compare versions ("versions as numbers"). A version that cannot
be read is `{"string": "", "available": false, "reason": "..."}`; the JSON writer omits the part
fields when `available` is false. A version is never a bare string. The `os_release` object has
an optional `suffix` string (`CURRENT`, `RELEASE`): it is a defined part of the versions
sentence, and it is never parsed for comparison.

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
in order. Or it refuses with a plain reason, with the code `uncovered` when no backend of ours
covers that card. Or it says "no provider". It is the yes or no to
loading.

Today vs target: the interim policy is Ampere and later (#2457). The target is every NVIDIA card
through one package: our own backends only, and several of them at once when the cards of one
box need different ones. The core must take each new backend with no core change.

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
| One answer for the whole machine | amp001 has an AMD card, an NVIDIA card and a BMC adapter. The rule must work per device and never assume index 0. |
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
`_gpumgrIsRmFirmwareCapableChip`). The architecture values are the ones in NVIDIA's
`src/common/inc/swref/published/nv_ref.h`, and the generator takes them from that header, so
none of them is typed by hand here: GM100 0x11 (17), GM200 0x12 (18), GP100 0x13 (19), GV100
0x14 (20), GV110 0x15 (21), TU100 0x16 (22), GA100 0x17 (23), GH100 0x18 (24), AD100 0x19 (25),
GB100 0x1A (26), GB200 0x1B (27). The decimal part is what the record carries, because the
floor comparison is numeric and never a string (4.3). The decimal value of a generation is
written per generation, in `generations[].arch_values` (4.3).

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

| Generation | Our backend | arm64 today | Interim floor (#2457) | Path to coverage |
|---|---|---|---|---|
| Blackwell | our open RM (`kernelopen`) | works (our open RM core) | supported | none needed |
| Hopper | our open RM | builds; untested on hardware (**unverified**) | supported | none needed |
| Ada | our open RM | as Ampere (**unverified**: no Ada card tested) | supported | none needed |
| Ampere, not GA100 | our open RM | works | supported | none needed |
| Ampere GA100 | our open RM | no `gsp_tu10x` image: fails at first open | floor says yes; firmware is missing | 4.5, 3.1.1 |
| Turing | our open RM | no `gsp_tu10x` image: fails at first open | below the floor | build `gsp_tu10x` for arm64 (#2458), edit policy |
| Volta, Pascal, Maxwell | none yet: a native backend | no NVIDIA binary; no support | below the floor | section 11 |
| Kepler | none yet: a native backend | none | below the floor | section 11 |
| Fermi | none yet: a native backend | none | below the floor | section 11 |
| Tesla and older | none yet: a native backend | none | below the floor | section 11 |

Every backend is ours: the open RM today, and later our own native backends (section 11). There
is no closed-RM backend and no legacy backend (Mark, 2026-11-23; section 15). A generation with
no native backend yet has no backend at all, and its cards are refused in two steps: below the
active floor it is `below_policy`; once policy admits it and no backend of ours covers it, it is
`uncovered`. The floor comes first, so a Kepler card reads `below_policy` while the floor is
still Ampere, and reads `uncovered` once the floor is lowered and no native backend covers it
yet (section 14 has both rows for the same card).

The id ranges for Kepler, Fermi and Tesla overlap by number (Fermi `0x06c0..0x1251` and Kepler
`0x0fc6..0x12ba` share values). The generator therefore keys on the exact `devid` list, never on
a range. Ranges are only a compact way to print and to match the open-capable and
no-legacy-branch groups.

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
GA100 the record says family `ga100`, image `gsp_tu10x`, available on amd64, so on arm64 the core's
per-arch build check refuses with `not_built_arm64` ("firmware gsp_tu10x is not built for arm64")
before anything loads. GA100 and the GA10x group share architecture value 0x17, so stage 2 tells
them apart by (architecture, implementation) and stage 1 by device id (section 4.3, `impl_values`).
`0x20b0` is simply outside the `0x2200..` range.

Turing and GA100 on arm64 are one work package, Track #2458: it builds `gsp_tu10x` for arm64 and
moves the floor to Turing. Turing is below the floor until then, so a Turing card on arm64 is
refused with `below_policy`, not with `not_built_arm64` (6.3).

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
- Architectures: `xe` covers arm64. `i915` is not built for arm64 by our packages, so the i915
  record lists only `amd64` in `archs` and an arm64 box refuses i915 with the code
  `not_built_arm64` and the reason "i915 is not built for arm64" (section 4.3). `xe` is built for
  arm64 and is not tested there, so an arm64 box supports it with the warning
  `not_tested_on_arm64` (section 4.3).
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
- **Many of each class.** A class holds any number of devices: the GPU class has no fixed count,
  no slot and no unit assumption, and the classes after it follow the same rule. Each device
  arrives and leaves on its own (#2464), and each one gets its own decision record, its own
  binding to a backend instance and its own unit inside that instance. The class owns the type
  of a device, never the number of them.
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
#define DEV_SELECTOR_MAX 32          /* room for the NUL: 32 bytes or more is rejected */
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

struct dev_candidate {                  /* one candidate backend, with where it is built */
	const char *name;                 /* the backend name, as the record spells it */
	const char *const *archs;         /* the architectures it is built for */
	size_t      narchs;
};

struct dev_match {                          /* result of match() */
	const char *family;                 /* opaque to the core */
	const char *board;                  /* decorator name or NULL */
	const struct dev_candidate *candidates; /* candidate set, not host-arch filtered */
	size_t      ncandidates;
	const struct dev_feature *features; size_t nfeatures;
	const char *refuse_code;            /* non-NULL: claimed, but refused (policy, not built, ...) */
	const char *refuse_reason;
	const char *next;                   /* what to do about a refusal */
	const char *warning;                /* for example "not_tested_on_arm64"; may be NULL */
};

enum dev_step_kind { STEP_KLD, STEP_PACKAGE };
struct dev_step {
	enum dev_step_kind kind;
	const char *module_file;            /* file name (manifests, kldload); package name for a package step */
	const char *kernel_module;          /* kernel name (kldstat, the loaded check); NULL for a package step */
};

struct dev_plan {                           /* for one device and the backend bound to it */
	const struct dev_step *firmware; size_t nfirmware;   /* may be empty: no firmware */
	const struct dev_step *driver;   size_t ndriver;     /* in load order */
	const char *backend;
	/* the firmware list is per device; the core merges every device's list into the one
	   firmware plan of the run (6.3, step 7, and 9.2.3) */
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
  `candidates` list and no `refuse_code` means the record names the id and the provider offers
  no backend at all, for any architecture. No backend of ours covers that card, so the binding
  step refuses it with the code `uncovered` (section 9), unless the policy floor refuses it
  first with `below_policy` (4.6). A `refuse_code` means claimed and refused.
  Any other return value is a `provider_error`: a fifth decision with its reason. It never falls
  through to a lower-scoring provider. A claimed device is not offered to a lower-scoring
  provider either, unless the record sets `fallback_ok`.
- `match` does not choose a backend. It returns the candidate set as candidate records
  (`{name, archs[]}`), not as bare names, so the core can do the per-arch check with no vendor
  knowledge. The binding step (section 9) is the only place a backend is chosen.
- `match` takes no host information. It returns the candidates with their per-architecture
  availability: every candidate record carries the architectures it is built for. The core
  filters the candidates by the host architecture between `match` and binding. The core's
  per-arch build check (6.3, step 4) is what emits `not_built_<arch>`, from that per-architecture
  availability. `match` never emits it, and `plan_load` never emits it.
- `plan_load` is called for the bound backend. It may use `host_info` (architecture, installed
  modules from `kldxref`, loaded modules) and no vendor knowledge of other providers.
- Plans are counted lists, with no fixed array size. The generator fails when a record exceeds a
  bound it declares itself (`max_steps`, `max_backends`, `max_features`). Fixed buffers (selector,
  version string) stay, with the length check above.
- A selector or version string is rejected when its length is greater than or equal to the buffer
  size, so the NUL always fits. In a 32-byte buffer 31 characters are accepted and 32 are
  rejected. The parser errors; it never truncates.
- Instance merge: for one backend instance, the driver steps of every device bound to it are
  merged in order and de-duplicated by module file name. The firmware steps are not in the
  instance plan: the firmware is one shared plan for the whole run (6.3, step 7, and 9.2.3).

### 4.3 Capability record (versioned)

Each provider carries one record, generated from its data file (section 5). Every field, with its
default:

| Field | Meaning | Default |
|---|---|---|
| `schema_version` | version object of the record format (the schema) | required |
| `record_version` | version object of the record content; the generator owns it (5.1) | absent in the source record; required in the generated one |
| `provider` | provider name | required |
| `driver_branch` | version object, for example 580.178.04 (section 10) | required for providers with a branch |
| `score` | tie-break between providers (4.6) | 0 |
| `backends[]` | name, `branch`, `archs`, `modules`, `licence_class`, `score`; the name is unique in the record | required |
| `families[]` | `id`, `arch_values`, `impl_values`, `devids`, `generations[]`, `backends`, `firmware` | required |
| `decorators[]` | board decorators keyed by subvendor:subdevice | `[]` |
| `features[]` | the flag indexes this provider can set; every one appears in the output | required |
| `policy` | `{min_generation, reason}`, for example `ampere` (8.2) | none: no floor |
| `generation_order` | the ordered generation names, oldest first, each with its architecture values (8.2) | required for a provider with a policy |
| `preference` | lists of backend names; the earlier backend must outscore the later one (4.3) | `[]` |
| `fallback_ok` | a claimed-but-refused device may be offered to a lower-scoring provider | false |
| `acknowledged_moves[]` | ids that moved backend on a branch change and were acknowledged (10.3) | `[]` |
| `max_steps`, `max_backends`, `max_features` | declared bounds the generator checks | generator default |

Family fields in more detail:

- `impl_values` lists the implementation values a family covers. It is required when two families
  share an architecture value (GA100 and the GA10x group both have 0x17). The generator fails when
  two families match the same (architecture, implementation) pair.
- `devids` is the exact device id list of the family, taken from the json (3.1). The generator
  fails when any device id is in two families. A range is only a printing form of a list.
- `generations[]` lists the generations inside the family. Each entry has a `name`, its own
  `arch_values` (the architecture values of that generation, taken from `nv_ref.h`), its own
  `tested_arch` and its own `verified_on_hardware`. The family's `arch_values` is the union of the
  generations' arrays, and the generator checks that the union equals the family list exactly: a
  value in the family that no generation of it names, and a value a generation names that the
  family does not list, both fail generation. Blackwell is one generation with two values (GB100
  26 and GB200 27); GA100 is the Ampere generation with the value 23, so the generation name
  `ampere` covers both the GA10x group and GA100. The evidence is per generation, not per family:
  Hopper inside the `gsp_ga10x` group is not tested on arm64, while Blackwell in the same group
  is.
- The generator emits a per-devid generation map (5.3): for every device id it knows the
  generation, from the json name and our family map. Stage 1 uses it, so stage 1 never guesses a
  generation from a range.
- `min_generation` is a name, and `generation_order` turns it into the architecture value to
  compare with: the ordered list of generations, oldest first, each with the architecture values
  it names (for example `turing` to 22, `ampere` to 23). The comparison is numeric, on the
  architecture value, never on the name. A generation with more than one value (Blackwell is 26
  and 27) contributes its lowest value as the floor of that generation. The generator checks that
  the policy names a generation that is in `generation_order`, that the table is ordered, and
  that every generation the record uses is in `generation_order`: a generation named by a family
  but missing from the order fails generation.
- Rule for equal evidence and equal outcome: an architecture the generation's backend or firmware
  is **not built** for is `refused` (code `not_built_<arch>`), and the core's per-arch build check
  is what emits that code, from the candidates' per-architecture availability that `match`
  returned. An architecture it is **built for but not tested** on is `supported` with the warning
  `not_tested_on_<arch>` in the output.
- i915 is **not built** for arm64 by our packages. Its record lists only `amd64` in `archs`, so an
  arm64 box gets `refused` with code `not_built_arm64` and the reason "i915 is not built for
  arm64". The built-but-not-tested rule applies to
  `xe`: `xe` is built for arm64, and while it is not tested on arm64 the device is `supported`
  with the warning `not_tested_on_arm64`.
- Backend preference is data: each backend has a `score`, and the provider file lists the
  preferences as `"preference": [["rm-open","rm-native"]]`. The generator checks each list
  generically: the earlier backend must outscore the later one, and the generator fails
  otherwise. The generator names no backend.
- The `branch` of a backend is the RM branch its instances are built from, as a version object
  (the shape of `driver_branch`). A backend that carries no branch of its own uses the record's
  `driver_branch`. The branch is a field of the backend entry, and the backend name is unique in
  the record: two RM branches are two entries with two names (`rm-open-580` and `rm-open-600`),
  never one name with two branches. Families and preference lists name unique backend entries, so
  a name that is not in `backends[]` fails generation, and so does a name that appears twice:
  the generator fails on a duplicate backend name. The branch is data: no instance name is typed
  by hand.

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
| 8 | `gsp` | GSP firmware runs the GPU | `gsp_proprietary_supported` (NVIDIA's own closed branch can run GSP), plus our own family map |
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
not available on the host architecture is refused by the core's per-arch check with
`not_built_<arch>` and the reason (6.3, step 4), never loaded halfway. `plan_load` never emits
that code. The licence class is recorded per image, read from the actual licence text. There are
three classes, from our firmware rule:

1. Redistributable: we package and ship it, so the hardware works offline from first boot.
2. A licence with rules (vendor-silicon-only use, legal review pending, no redistribution): we do
   not bundle it. It is fetched automatically when the hardware is detected, never by hand.
3. A licence that requires display or acceptance: the licence text is shown and an explicit accept
   is taken first, in the installer and the fetch tool alike. An automated install needs an
   explicit pre-accepted setting.

When unsure, treat the file as class 2 until the licence is read.

The firmware module file name is `nvidia_gsp_ga10x_fw` (the `firmware.gsp_ga10x` name of the alias
layer). The kernel names the module after the file with `_fw` appended, so `nvidia_gsp_ga10x_fw_fw`
shows in `kldstat -v`. The record's `firmware.module` field holds that file name, and a plan
step derived from it carries it as `module_file`. A firmware module name is not per instance:
two instances that need the same image share one firmware module (9.2.3).

A step carries two names, and each field holds exactly one of them:

| Field | Holds | Used by |
|---|---|---|
| `module_file` | the module file name without `.ko`: the name a manifest lists and the name `kldload` takes | manifests, install lists, `kldload` |
| `kernel_module` | the kernel module name, as `kldstat` shows it: the file name with `-` and `.` replaced by `_` | `kldstat`, the loaded check |

`kldload` takes the file name; `kldstat` and the loaded check use the kernel name. The two are
resolved through the alias layer: `nvidia_gsp_ga10x_fw` counts as loaded when `kldstat` lists
`nvidia_gsp_ga10x_fw_fw` (the file name with `_fw` appended), and `nvidia-drm` counts as loaded
when `kldstat` lists `nvidia_drm` (its declared alias). The English line and the JSON
`module_file` field hold the file name; the JSON `kernel_module` field holds the kernel name.

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
    candidate set empty     -> "refused": the record names the id, and no backend of ours covers
                               it. The policy floor is checked first, so an older generation
                               reads "below_policy" below the active floor, and "uncovered" once
                               policy admits it and no backend of ours covers it
    else                    -> candidate set goes to the binding step (section 9)
```

One definition of the two "no provider" values: `uncovered` means some provider's record names
the id (a planned generation, or one dropped by a branch change) and no backend of ours covers
it, for any architecture. It is the answer only once the policy floor has admitted that
generation: below the active floor the same card is `below_policy`, and the floor is checked
first (6.3, step 3). `no_provider` means nothing anywhere names it (the BMC display adapter).

The score is a number in the record. It is not computed from vendor knowledge. The log line names
the winner, the losers, and the score of each. A tie by score is reported as a warning in the
output, even though it is resolved.

### 4.7 Lint and the fake provider

- A **fake provider** (`fake`) registers the same ops table with a made-up vendor id and two
  families, one with a decorator and one that refuses. The tests drive the whole decision step
  through it from fake `pciconf -l` text. The fake provider has its own feature indexes, in its
  own range, so the fake output never borrows a real feature name.
- A **vendor-free lint test** greps the core sources (registry, factory, decision tool, generator
  core, JSON writer) against two separate sets. The **pattern set** is fixed in the test:
  `vendor ==`, `vendor !=`, `0x10de`, `0x1002`, `0x8086`, and a vendor-named switch case. The
  **name set** comes from the data files: the provider names and the backend names. The two sets
  never mix: an architecture name (`amd64`, `arm64`, `i386`) is not a lint name, so the core may
  name an architecture. The lint **fails closed**: when the data files are missing or unreadable
  the lint fails, because a lint that could not look is not a clean lint. The test also carries a
  planted file with `if (id->vendor == 0x10de)` and MUST fail on it. A lint that cannot fail is
  not accepted.

## 5. The one definition

### 5.1 File format

One provider record per provider, in two formats: `data/providers/<provider>.json` and
`data/providers/<provider>.ucl`. Both hold the same record, and both are validated against the
one source schema, `schema/provider-record-1.schema.json`. The JSON file is checked as JSON; the UCL file
is parsed into the same value tree and checked the same way, so the schema is written once and
both formats are held to it. The generator reads either format and does not care which one it
got; what the tree holds is one JSON and the twin generated from it.

There are two schemas, and they differ in exactly one field:

| Schema | Covers | `record_version` |
|---|---|---|
| `schema/provider-record-1.schema.json` | the source record: the file a person writes | absent; an input that carries one is refused |
| `schema/provider-record-1.generated.schema.json` | the generated record: what the generator writes out | required, and stamped by the generator |

The source record never carries `record_version`: the generator owns that field. An input file
that carries one is refused, not quietly stripped.

The JSON file is canonical. The UCL file is its twin: the generator writes it from the JSON, and
the drift test fails when the twin no longer matches (5.4). A hand edit of the UCL file alone is
a drift, not a second source of truth.

`record_version` is computed from the input sha256 plus a canonical serialisation of the parsed
record, never from the raw file bytes. The canonical serialisation is the parsed value tree
written in a fixed key order, so the JSON file and its UCL twin get the same `record_version`
although their bytes differ. A whitespace-only change to a record leaves `record_version` where
it was; a change to any value in it moves the version.

JSON because the repository already validates JSON against JSON Schemas, and tooling language is
free (the driver side is C; the generator may be Python). UCL because the same record has to be
read where no JSON parser is at hand (the shell, a jail, a script). Shape:

```json
{
  "schema_version": {"string": "1.0", "major": 1, "minor": 0, "patch": 0},
  "provider": "nvidia-open",
  "score": 100,
  "fallback_ok": false,
  "driver_branch": {"string": "580.178.04", "major": 580, "minor": 178, "patch": 4},
  "input": {"file": "supported-gpus.json", "licence": "zlib", "sha256": "..."},
  "preference": [],
  "generation_order": [
    {"name": "maxwell", "arch_values": [17, 18]},
    {"name": "pascal", "arch_values": [19]},
    {"name": "volta", "arch_values": [20, 21]},
    {"name": "turing", "arch_values": [22]},
    {"name": "ampere", "arch_values": [23]},
    {"name": "hopper", "arch_values": [24]},
    {"name": "ada", "arch_values": [25]},
    {"name": "blackwell", "arch_values": [26, 27]}],
  "backends": [
    {"name": "rm-open", "branch": {"string": "580.178.04", "major": 580, "minor": 178, "patch": 4},
     "archs": ["amd64", "arm64"], "score": 20,
     "modules": ["nvidia", "nvidia-modeset", "nvidia-drm"], "licence_class": "mit"}],
  "policy": {"min_generation": "ampere", "reason": "interim floor, Track #2457"},
  "families": [
    {"id": "gsp_ga10x_group", "arch_values": [23, 24, 25, 26, 27],
     "impl_values": ["ga10x", "ad10x", "gh100", "gb10x", "gb10y", "gb20x", "gb20y"],
     "devids": ["0x2c05", "0x2d04", "0x2e12"],
     "note": "the firmware group: Ampere (not GA100), Ada, Hopper, Blackwell. GA100 has the same arch value 23 and is told apart by impl_values (stage 2) and by device id (stage 1)",
     "backends": ["rm-open"],
     "generations": [
       {"name": "ampere", "arch_values": [23], "tested_arch": [], "verified_on_hardware": []},
       {"name": "hopper", "arch_values": [24], "tested_arch": [], "verified_on_hardware": []},
       {"name": "ada", "arch_values": [25], "tested_arch": [], "verified_on_hardware": []},
       {"name": "blackwell", "arch_values": [26, 27], "tested_arch": ["arm64"],
        "verified_on_hardware": ["0x2d04"]}],
     "firmware": {"image": "gsp_ga10x", "module": "nvidia_gsp_ga10x_fw", "archs": ["amd64", "arm64"],
                  "licence_class": "redistributable"}},
    {"id": "ga100", "arch_values": [23], "impl_values": ["ga100"], "devids": ["0x20b0"],
     "backends": ["rm-open"],
     "generations": [
       {"name": "ampere", "arch_values": [23], "tested_arch": [], "verified_on_hardware": []}],
     "firmware": {"image": "gsp_tu10x", "module": "nvidia_gsp_tu10x_fw", "archs": ["amd64"],
                  "licence_class": "redistributable"}}
  ],
  "decorators": []
}
```

The same record in UCL. It holds the same values and nothing else:

```
schema_version = { "string": "1.0", "major": 1, "minor": 0, "patch": 0 };
provider = "nvidia-open";
score = 100;
fallback_ok = false;
driver_branch = { "string": "580.178.04", "major": 580, "minor": 178, "patch": 4 };
input = { "file": "supported-gpus.json", "licence": "zlib", "sha256": "..." };
preference = ();
generation_order = (
  { "name": "maxwell", "arch_values": ( 17, 18 ) },
  { "name": "pascal", "arch_values": ( 19 ) },
  { "name": "volta", "arch_values": ( 20, 21 ) },
  { "name": "turing", "arch_values": ( 22 ) },
  { "name": "ampere", "arch_values": ( 23 ) },
  { "name": "hopper", "arch_values": ( 24 ) },
  { "name": "ada", "arch_values": ( 25 ) },
  { "name": "blackwell", "arch_values": ( 26, 27 ) }
);
backends = (
  { "name": "rm-open",
    "branch": { "string": "580.178.04", "major": 580, "minor": 178, "patch": 4 },
    "archs": ( "amd64", "arm64" ), "score": 20,
    "modules": ( "nvidia", "nvidia-modeset", "nvidia-drm" ), "licence_class": "mit" }
);
policy = { "min_generation": "ampere", "reason": "interim floor, Track #2457" };
families = (
  { "id": "gsp_ga10x_group", "arch_values": ( 23, 24, 25, 26, 27 ),
    "impl_values": ( "ga10x", "ad10x", "gh100", "gb10x", "gb10y", "gb20x", "gb20y" ),
    "devids": ( "0x2c05", "0x2d04", "0x2e12" ),
    "note": "the firmware group: Ampere (not GA100), Ada, Hopper, Blackwell. GA100 has the same arch value 23 and is told apart by impl_values (stage 2) and by device id (stage 1)",
    "backends": ( "rm-open" ),
    "generations": (
      { "name": "ampere", "arch_values": ( 23 ), "tested_arch": ( ), "verified_on_hardware": ( ) },
      { "name": "hopper", "arch_values": ( 24 ), "tested_arch": ( ), "verified_on_hardware": ( ) },
      { "name": "ada", "arch_values": ( 25 ), "tested_arch": ( ), "verified_on_hardware": ( ) },
      { "name": "blackwell", "arch_values": ( 26, 27 ), "tested_arch": ( "arm64" ),
        "verified_on_hardware": ( "0x2d04" ) }
    ),
    "firmware": { "image": "gsp_ga10x", "module": "nvidia_gsp_ga10x_fw",
      "archs": ( "amd64", "arm64" ), "licence_class": "redistributable" } },
  { "id": "ga100", "arch_values": ( 23 ), "impl_values": ( "ga100" ),
    "devids": ( "0x20b0" ), "backends": ( "rm-open" ),
    "generations": (
      { "name": "ampere", "arch_values": ( 23 ), "tested_arch": ( ), "verified_on_hardware": ( ) }
    ),
    "firmware": { "image": "gsp_tu10x", "module": "nvidia_gsp_tu10x_fw",
      "archs": ( "amd64" ), "licence_class": "redistributable" } }
);
decorators = ();
```

`decorators` is empty until a real board needs one. The values in this sample are illustrations of
the shape, not the final table: the real file is generated from the json input (5.2). The `impl_values` names are placeholders for the
implementation numbers the generator takes from the NVIDIA headers. The evidence is per
generation: the `hopper` entry has no tested architecture, so a Hopper card on arm64 is
`not_tested_on_arm64` while a Blackwell card in the same family (the GB206, 0x2d04) is tested there (4.3). The device id
lists are exact lists taken from the json; a range is only a printing form of a list, and the
generator fails when one id is in two families. The architecture values of the two samples are
the same list, and the generator takes them from `nv_ref.h` (3.1).

The source record carries no `record_version`: the generator owns that field and stamps it into
the generated record from the input sha256 and a canonical serialisation of the parsed record
(4.3). An input file that carries `record_version` is refused.

The preference list is empty while there is one backend. A native backend for an older generation
(section 11) joins the same record as a second backend entry, and the preference list then reads
`[["rm-open", "rm-native"]]`. Every name in a preference list, and every name in a family's
`backends` list, is the name of exactly one entry in `backends[]` (4.3).

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
| the per-devid generation map (`generated/nvidia_devid_generation.h`) | stage 1: the generation of every device id (4.3) |
| devd conf (`generated/devd/gpu-decide.conf`) | devd (section 7) |
| manifests and install lists (`generated/manifests/*`) | `make install`, `make deinstall`, the package |
| JSON Schema (`schema/gpu-decision-1.schema.json`, and the two provider-record schemas) | the decision tool output, the data files and the generated record |
| the generated provider record (`generated/provider-record-<provider>.json`) | the compiled-in record: the source record plus the stamped `record_version` |
| the UCL twin (`data/providers/<provider>.ucl`) | the twin the generator writes from the canonical JSON |
| schema samples (`schema/samples.json` rows, fixtures) | `schema-check` |

### 5.4 Drift test

`tests/device_tables_test.sh` regenerates every output into `$TMPDIR`, diffs it against the
committed copy, and fails on any difference. It also fails when a provider data file does not
validate against its schema, in either format, when the committed UCL twin differs from the
twin the generator writes from the canonical JSON, when a JSON data file and its UCL twin
generate different output, when two decorators conflict, when a firmware module named by a
family is absent from the manifests, when two families match the same (architecture,
implementation) pair, when the union of a family's `generations[].arch_values` is not the
family's own `arch_values`, when a generation the record uses is missing from
`generation_order`, when a backend name appears twice, when a family or a preference list names
a backend that is not in `backends[]`, when a preference list is not satisfied (the earlier
backend must outscore the later one), when two backends produce the same instance name (9.2.1),
and when a record exceeds a bound it declares. It also fails when the input sha256 or the data
file changes and `record_version` does not move with it, and when a whitespace-only change to
a record moves `record_version`. The build runs it, so
a hand edit of a generated file, or a data edit without regeneration, fails the build. The test
has a planted-drift case that MUST fail.

## 6. The decision step

### 6.1 Tool name

The tool is `gpu-decide` (Mark, 2026-11-23). The name says the class, so there is no `--class`
option: GPU is the first class, and a class-neutral name comes with the next class. Its name
goes through the alias layer (section 12), so the rebrand renames data. The man page is
`gpu-decide(8)` with a COMPATIBILITY section.

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

Before step 1, and only with `--act`, the tool takes an exclusive `flock` on a fixed lock file
under `/var/run` and holds it to the end of verify. A concurrent run waits for the lock, so it
never acts on a plan it made before the other run changed the machine.

The lock file is created by root, with mode 0600, in `/var/run`. It is opened `O_NOFOLLOW`, so a
symlink in its place is refused instead of followed. A run that is not root never takes the lock:
it decides only, and it prints the command the root run would use. A run waits for the lock for
at most the bound `--lock-wait-seconds` (default 30), and it prints that it waits while it waits.
On timeout it exits with code 8 and the reason `lock_timeout` (6.5): the other run still holds
the machine, and the answer is "retry after the other run finishes", not a failure of this one.

1. **Enumerate** every display-class device (class 0x03, any subclass) from `pciconf -l`. If
   `pciconf` itself fails, the answer is "could not look", not "no device".
2. **Match.** For each device, run the factory (4.6). The outcome is `refused`, `no_provider`,
   `provider_error`, or a **candidate set of backends**. No backend is chosen here.
3. **Policy check.** A device whose generation is below the provider's `min_generation` is refused
   with `below_policy`, the reason and a `next`. This check comes before every architecture
   check: a Turing card on arm64 is `below_policy`, not `not_built_arm64`.
4. **Per-arch build check.** The core takes the candidates' per-architecture availability that
   `match` returned, and the architectures the family lists for its firmware. The check refuses
   with `not_built_<arch>` when the covering backend is not built for the running architecture
   **or** the family firmware is not built for it; the plain reason names which one it was
   ("i915 is not built for arm64", "firmware gsp_tu10x is not built for arm64"). A GA100 on
   arm64 is refused this way even though its backend is built there: the firmware it needs is
   not. The core emits this code; `match` never does, and `plan_load` never does.
5. **Core arch filter.** The core drops the candidates that are not built for the running
   architecture. The provider's `match` never does this. A device left with no candidate was
   already refused at step 4; `uncovered` comes only from `match` itself (4.2).
6. **Bind** (section 9). For each device on its own, choose the backend that covers it. The
   highest-scoring candidate that covers that device wins; the provider's preference list is the
   data for that order. Each device's `backend`, `firmware` and `driver` fields come from the
   backend bound to it, and no card's binding constrains another card's. A card no backend of
   ours covers is refused with the code `uncovered`, the reason and a `next` that names what
   would have to change; the other cards of the box still load. The instance of a card is the
   backend name plus the RM branch of that backend, and nothing else (9.2.1): two cards of
   different generations that the same backend and the same branch cover share one instance,
   each card with its own unit inside it. All the instances the run binds run at the same time
   (9.2). Then compute one ordered driver plan per instance: for every device bound to it, the
   driver steps merged and de-duplicated by module file name (4.2). Modules already loaded are
   marked `already loaded`.
7. **Firmware plan.** The firmware is one plan for the whole run, not one plan per instance: the
   images the bound devices need, de-duplicated by image, each with `required_by` naming the
   instances that need it. The firmware plan runs before any instance's driver plan, so every
   driver finds its image registered (section 7). Each instance that needs an image takes one
   reference to it, and the image is unloaded when the last reference goes (9.2.3). A firmware
   step is still planned when the driver is already loaded or listed in `kld_list`: the image is
   what the driver needs, not the driver.
8. **Check packages and modules.** A device is refused when a `package` step is not installed
   (`needs_install`, with the exact command in `next`), or a `kld` module is not installed: that
   refusal has the code `module_missing`, a reason that names the missing module, and a `next`
   that names the package that supplies it. Each refusal has a stable code, a plain reason and a
   `next` step.
9. **Act**, only with `--act`. Decide-only is the default; `--act` is opt-in. The lock taken before
   step 1 is still held. As root, it runs the firmware plan first, one `kldload` per image, and
   then the `kld` steps of each instance's driver plan in order, only for modules that are
   installed. `--act` plans firmware for **every** device of every instance the run binds, not
   only the triggering one. `--device <selector>` names the device whose event triggered the
   run; it does not limit the plan. A non-root `--act` stops with "needs root" and prints the
   exact command. Without `--act` the tool only decides and prints (what preflight and
   `nvrm-info` use).
10. **Verify.** After the load, ask each provider's `verify` (module present, device attached,
    stage 2 sysctls read back, section 8). The tool joins the stage 2 sysctl nodes to the devices by
    the `selector` sysctl, never by the order of the nodes. The tool computes `agrees` by comparing
    the image its stage 1 chose with the `fw_image` the driver reports, and maps `fw_image` only
    through the provider record's firmware list. Any other value is refused and never passed to
    `kldload`. The verify state of a device is one of `not_loaded`, `agreed`, `mismatched` or
    `unreadable` (6.5). Report the result per device. In decide-only mode the tool reads the same
    stage 2 sysctls but corrects nothing: an uncorrectable mismatch is reported and the run
    exits 5 (6.5).

### 6.4 Outputs

English, one line per device. One format:

```
<label> (<selector>): <vendor> <vvvv:dddd> (<name>) <decision>, firmware <modules or none>, driver <modules>
<label> (<selector>): <vendor> <vvvv:dddd> (<name>) <decision>, package <name> (installed), driver <modules>
<label> (<selector>): <vendor> <vvvv:dddd> (<name>) <decision>, package <name> (missing), driver <modules>
<label> (<selector>): <vendor> <vvvv:dddd> (<name>) <decision>: <reason>; next: <next step>
```

The module names on the line are module file names (the file name without `.ko`); the kernel
name `kldstat` shows is in the `kernel_module` field of the same step in the JSON (4.5). A list
joins names with
`+`, and an empty list reads `none`. A package step prints as `package <name> (installed)` or
`package <name> (missing)`. It never
takes the firmware slot: that slot lists firmware modules only. A warning is appended as
`; warning: <code>`, or `; warning: <code>, <code>` when there is more than one. The JSON
`english` field is byte-identical to the text line. For amp001:

```
gpu0 (pci0:0:1:0): amd 1002:7480 (Navi 33) supported, package gpu-firmware-amd-kmod-navi33 (installed), driver amdgpu
gpu1 (pci0:0:2:0): nvidia 10de:2d04 (GB206) supported, firmware nvidia_gsp_ga10x_fw, driver nvidia-rm-open-580.178.04+nvidia-modeset-rm-open-580.178.04+nvidia-drm-rm-open-580.178.04
gpu2 (pci0:0:3:0): aspeed 1a03:2000 (BMC display adapter) no_provider: no record names this device; next: none, it is never loaded
```

A refused line (an A100 on an arm64 box):

```
gpu0 (pci0:0:4:0): nvidia 10de:20b0 (GA100) refused: firmware gsp_tu10x is not built for arm64; next: use an amd64 host, or build gsp_tu10x for arm64
```

(The `gpuN` label is the position in this run's enumeration. It is a label, not a device node and
not the instance unit; the selector identifies the device, and the driver's own log and sysctls
use `<instance>:<unit> (<selector>)`.)

Decisions: `supported`, `refused`, `no_provider`, `provider_error`. Every refusal carries a code
(`uncovered` when no backend of ours covers the card, `below_policy`, `not_built_<arch>`,
`module_missing` when a module of the plan is not installed, or `needs_install` when a package is
not installed), a `next` field (JSON) and the clause in the English line. A
`supported` device may carry warnings, for example `not_tested_on_arm64`; they are printed as
`; warning: <code>` at the end of the line, and they are also in the JSON `warnings` list.

`--json` prints one document. `--jsonl` prints JSON Lines: a header record, one record per
device, one per plan, one for the firmware plan, one per verify result, an end record. The schema is
`schema/gpu-decision-1.schema.json`, generated, registered in `schema/samples.json`, and
enforced like the existing schemas. Versions are objects as in "versions as numbers". Every index
in the chosen provider's `features[]` appears in a device's `features` list (available true or
false, with a reason when false), and the schema requires it. A device with no provider
(`no_provider`) has an empty `features` list: that is the rule for it. Every `supported` device
label appears in exactly one plan and in exactly one verify record, and the schema requires that
too.

A verify record carries one `state`, and it is one of four:

| State | Meaning |
|---|---|
| `not_loaded` | there is nothing to verify: no driver of ours is loaded for that device, or the provider has no stage 2 to read. It is not an error |
| `agreed` | the driver is loaded, its stage 2 node was read, and the image it names is the image stage 1 chose |
| `mismatched` | the driver is loaded, its stage 2 node was read, and the image it names is not the image stage 1 chose |
| `unreadable` | a driver is loaded, but the stage 2 node that should exist is missing or cannot be read |

The `agrees` field is true only for `agreed`, false for `mismatched`, and null for the two
states that compare nothing.

Example for amp001 (selectors, the AMD record and the NVIDIA feature values are illustrative, not
read from hardware):

```json
{
  "schema_version": {"string": "1.0", "major": 1, "minor": 0, "patch": 0},
  "tool": "gpu-decide",
  "host": {"arch": "arm64", "os": "FreeBSD", "os_release": {"string": "16.0-CURRENT", "major": 16, "minor": 0, "patch": 0, "suffix": "CURRENT"}},
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
     "english": "gpu0 (pci0:0:1:0): amd 1002:7480 (Navi 33) supported, package gpu-firmware-amd-kmod-navi33 (installed), driver amdgpu",
     "firmware": [{"module_file": "gpu-firmware-amd-kmod-navi33", "kernel_module": null,
                   "kind": "package"}],
     "driver": [{"module_file": "amdgpu", "kernel_module": "amdgpu", "kind": "kld"}],
     "features": [
       {"index": 1, "name": "display", "available": true},
       {"index": 6, "name": "prime", "available": true},
       {"index": 7, "name": "runtime_pm", "available": true}]},
    {"label": "gpu1", "decision": "supported", "provider": "nvidia-open",
     "family": "gsp_ga10x_group", "board": null, "backend": "rm-open",
     "instance": "rm-open-580.178.04",
     "warnings": [],
     "english": "gpu1 (pci0:0:2:0): nvidia 10de:2d04 (GB206) supported, firmware nvidia_gsp_ga10x_fw, driver nvidia-rm-open-580.178.04+nvidia-modeset-rm-open-580.178.04+nvidia-drm-rm-open-580.178.04",
     "firmware": [{"module_file": "nvidia_gsp_ga10x_fw", "kernel_module": "nvidia_gsp_ga10x_fw_fw",
                   "kind": "kld"}],
     "driver": [{"module_file": "nvidia-rm-open-580.178.04",
                 "kernel_module": "nvidia_rm_open_580_178_04", "kind": "kld"},
                {"module_file": "nvidia-modeset-rm-open-580.178.04",
                 "kernel_module": "nvidia_modeset_rm_open_580_178_04", "kind": "kld"},
                {"module_file": "nvidia-drm-rm-open-580.178.04",
                 "kernel_module": "nvidia_drm_rm_open_580_178_04", "kind": "kld"}],
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
     "aliases": [{"name": "nvidia", "kind": "module", "owner": "this-project", "since": {"string": "1.0.0", "major": 1, "minor": 0, "patch": 0}, "deprecation": {"state": "none"}}],
     "replaced_driver": {"name": "nvidia-driver", "kind": "package"}},
    {"label": "gpu2", "decision": "no_provider",
     "english": "gpu2 (pci0:0:3:0): aspeed 1a03:2000 (BMC display adapter) no_provider: no record names this device; next: none, it is never loaded",
     "reason": {"code": "no_provider", "text": "no record names this device"},
     "next": "none, it is never loaded",
     "firmware": [], "driver": [], "features": []}
  ],
  "firmware_plan": [
    {"image": "gsp_ga10x", "module_file": "nvidia_gsp_ga10x_fw",
     "kernel_module": "nvidia_gsp_ga10x_fw_fw", "kind": "kld", "state": "loaded",
     "required_by": ["rm-open-580.178.04"], "references": 1}],
  "plans": [
    {"backend": "rm-open", "instance": "rm-open-580.178.04", "devices": ["gpu1"], "steps": [
      {"order": 1, "module_file": "nvidia-rm-open-580.178.04",
       "kernel_module": "nvidia_rm_open_580_178_04", "kind": "kld", "state": "loaded"},
      {"order": 2, "module_file": "nvidia-modeset-rm-open-580.178.04",
       "kernel_module": "nvidia_modeset_rm_open_580_178_04", "kind": "kld", "state": "loaded"},
      {"order": 3, "module_file": "nvidia-drm-rm-open-580.178.04",
       "kernel_module": "nvidia_drm_rm_open_580_178_04", "kind": "kld", "state": "loaded"}]},
    {"backend": "amdgpu", "devices": ["gpu0"], "steps": [
      {"order": 1, "module_file": "gpu-firmware-amd-kmod-navi33", "kernel_module": null,
       "kind": "package", "state": "installed"},
      {"order": 2, "module_file": "amdgpu", "kernel_module": "amdgpu", "kind": "kld",
       "state": "loaded"}]}
  ],
  "verify": [
    {"label": "gpu0", "state": "not_loaded", "agrees": null,
     "stage2": {"available": false, "reason": "the AMD provider has no stage 2"}},
    {"label": "gpu1", "state": "agreed", "agrees": true,
     "stage2": {"available": true, "arch": 26, "fw_image": "gsp_ga10x", "fw_loaded": true}}
  ],
  "exit": 0
}
```

A device whose version cannot be read prints `{"string": "", "available": false, "reason": "..."}`
with no part fields.

A plan step carries one `state`: `loaded` (the module is loaded now), `already loaded` (it was
loaded before this run), `already listed` (it is in `kld_list` or `loader.conf`, not loaded yet),
`installed` (the package is installed) or `missing` (the package is not installed). A step carries
`module_file` and `kernel_module` (4.5): the file name is what a manifest lists and what
`kldload` takes, and the kernel name is what `kldstat` and the loaded check use. A package step
has no kernel module, so its `kernel_module` is null.

The `firmware_plan` is the one firmware plan of the run, beside the per-instance `plans`
(6.3, step 7). It holds one row per firmware image, not one row per instance, with `required_by`
naming the instances that need that image and `references` counting them. A firmware module never
appears in a driver plan; a firmware that arrives as a package (the AMD case) is a `package` step
and stays with its device.

### 6.5 Exit codes

A **claimed** device is one a provider record names. A card refused with `uncovered` is claimed
(a record names its id, and no backend of ours covers it). `no_provider` is unclaimed (nothing
anywhere names it). The exit code counts claimed devices only.

| Code | Meaning |
|---|---|
| 0 | every claimed device is served |
| 1 | a load or verify step failed (the JSON names the step); only with `--act` |
| 2 | usage error |
| 3 | nothing claimed: every device is `no_provider`, or there is no display device. devd treats 0 and 3 as normal |
| 4 | could not look (`pciconf` failed) |
| 5 | a stage 2 `mismatched` that was not corrected, in both modes (the image is missing, not built here, or not in the record) |
| 6 | partial: some claimed device is served and some is refused (a refusal includes `uncovered`) or `provider_error` |
| 7 | no claimed device is served: every claimed device is refused or `provider_error` |
| 8 | the lock timed out: another run still holds it. Retry after the other run finishes |

With `--act`, 0 means every claimed device was loaded and verified, including "everything was
already loaded and verify passed". In decide-only mode, 0 means every claimed device would be
served. 1 is returned only with `--act`: a decide-only run loads nothing, so it has no load step
and no load step that can fail. 5 is returned in both modes: a decide-only run reads the stage 2
sysctls and reports a mismatch it cannot correct.

A verify state that is not a failure leaves the exit code alone. A `not_loaded` verify is not an
error: a decide-only run with no driver loaded has nothing to compare, and it exits as the
devices decide. A `mismatched` that the tool corrected (it loaded the image stage 2 named) is
exit 0: it is logged with `logger -p daemon.warning` and its verify record carries
`agrees:false`. A `mismatched` the tool could not correct is exit 5. An `unreadable` verify is
exit 1 with `--act`, because a driver that is loaded but has no node to read is a failure of the
run; in decide-only mode it is reported in the verify record and the exit code is the one the
decisions give.

Exit 8 is its own code, not exit 1: the tool did not fail, another run still holds the lock, and
the answer is "retry after the other run finishes".

When several apply, the highest-precedence code is reported: 4, then 8, then 5, then 1, then 7,
then 6, then 3, then 0. devd logs refusals with `logger -p daemon.warning`.

### 6.6 Man page and docs

`man/gpu-decide.8` (checked with `mandoc -T lint`), a `README.md` section, and `--help` with
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

- **devd attach.** `gpu-decide` generates the devd conf. The action runs as root:
  `gpu-decide --act --device <selector>`. The match is on the `vgapci` display class, not a
  vendor; the tool says yes or no. It loads the firmware images the run needs, then the driver
  of every instance the run binds. `/dev/nvidia-<instance>-<unit>` exists only after that
  instance's driver loads, so no unprivileged open can come first. The rule also fires on the
  driver's own attach event, which covers the case below.
- **No device present.** The driver must load cleanly with zero devices: a box with no NVIDIA
  card in it is not a reason to fail the load. The tool decides nothing and loads nothing, and
  the driver attaches to nothing. The zero-device load, the hot-plug of external GPU enclosures
  and the virtual machine with a simulated fictional NVIDIA PCI device are Track #2464.
- **Hot-plug.** Every hot-plug arrival is a fresh decision: "the devices that get pulled in and
  out may not be the same". Nothing is cached per slot. The backend instance and the firmware
  are chosen per card, on the card that arrived, and an instance that no attached card needs any
  more is unloaded on detach. A firmware image that no attached card of any instance needs is
  unloaded when its last reference goes (9.2.3). The details are Track #2464.
- **Boot, `loader.conf`.** `make configure` runs `gpu-decide --loader-conf` and writes the
  firmware module line, then the driver lines, from the decision (not from a fixed list). The
  loader loads them in that order. A box with no supported card gets no line. `make install` and
  `make configure` also look for `kld_list` or `loader.conf` lines that load the driver without
  its firmware line, and rewrite them (with the usual backup and a question) or fail loudly.
- **Manual `kldload` of an instance module.** Without the `MODULE_DEPEND`, this loads the
  driver with no firmware. The driver MUST NOT hang or panic. It does not fail the attach and it
  does not need a
  reattach: it stays attached, sets `fw_loaded` to 0, and refuses opens of that device with
  `ENXIO` until the image is registered (the same behaviour as section 8.3). Why `ENXIO`: the
  device is "not configured" yet, and `EIO` stays reserved for a real initialisation failure
  (README, "Diagnostics"), so a caller can tell the two apart. The kernel log gets the
  missing-firmware line once per device each time `fw_loaded` goes from 1 to 0, and once at
  attach. A per-device flag holds it: the flag is cleared when the image is registered, so the
  next drop from 1 to 0 logs again. Every open still returns `ENXIO`:
  `<instance>:<unit> (<selector>): firmware image <fw_image> is not registered (arch A, impl I); run as root: <tool> --act`
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
the devd, loader.conf and test changes, never alone. After `make configure` has run, only a
manual `kldload` loads the driver without its firmware, and that state is the stay-attached,
ENXIO state of 8.3.

Why #2417 still holds: (1) firmware registration still happens before the driver's MOD_LOAD, in the
same `kldload` sequence the tool runs as root; (2) the device nodes appear only after the driver
loads; (3) a test boots a non-root user, runs the tool through devd, and opens the node as that
user (section 14).

## 8. Stage 2 in the driver

Stage 2 runs at attach, after BAR0 is mapped, where the RM already reads `PMC_BOOT_42`
(`rm_is_supported_device()`). We add one step there:

1. Read the architecture (BOOT_42) and the implementation.
2. Look both up in the table generated from the provider record (`generated/nvidia_provider_table.h`).
   The table also carries the firmware image each chip needs and the architectures that image is
   built for.
3. Outside the table (architecture unknown, or below the provider's `policy.min_generation`,
   or no (architecture, implementation) row): **decline with `ENXIO`**, log the architecture value
   and the reason, and create no `hw.<instance>.gpus.<n>` node. The decline is visible in the kernel log
   and in the tool's verify output.
4. Inside the table: publish what was found, and the firmware image the table says it needs.
5. The image the chip needs is not built for the running architecture: **decline with `ENXIO`** and
   create no node, the same as step 3, and log the image and the architecture. A GA100 on an arm64
   box with a GB206 is never attached: the GA100 needs `gsp_tu10x`, which is not built for arm64,
   so stage 2 declines it while the GB206 attaches.

This replaces the named minimum-architecture constant of the interim floor (section 8.2). It does
not rely on stage 1 being right.

Stage 2 runs per device, so the same code path covers the box with no NVIDIA card in it: the
driver loads with zero devices and stage 2 runs when a device attaches later. The hot-plug of
external GPU enclosures and the virtual machine with a simulated fictional NVIDIA PCI device are
Track #2464.

### 8.1 Sysctls (versions as numbers)

Under the per-instance root `hw.<instance>.gpus.<n>`, for example
`hw.nvidia_rm_open_580_178_04.gpus.<n>` (README, "Tunables and sysctls"):

| Sysctl | Type | Meaning |
|---|---|---|
| `hw.<instance>.gpus.<n>.selector` | string | the pciconf selector of the device, for example `pci0:13:1:0` |
| `hw.<instance>.gpus.<n>.arch` | integer | BOOT_42 architecture value |
| `hw.<instance>.gpus.<n>.arch_available` | 0 or 1 | 0 when the value could not be read |
| `hw.<instance>.gpus.<n>.impl` | integer | implementation value |
| `hw.<instance>.gpus.<n>.fw_family` | string | chip family stage 2 found, for example `gb20x`; informational |
| `hw.<instance>.gpus.<n>.fw_image` | string | image the chip needs, for example `gsp_ga10x` |
| `hw.<instance>.gpus.<n>.fw_loaded` | 0 or 1 | the image is registered with firmware(9) |
| `hw.<instance>.provider_record` | string | `record_version` of the provider record compiled in |
| `hw.<instance>.provider_record_major`, `_minor`, `_patch` | integer | its parts |
| `hw.<instance>.provider_schema` | string | `schema_version` of the provider record format |
| `hw.<instance>.policy_min_generation` | string | the policy field, for example `ampere` |

A node `hw.<instance>.gpus.<n>` exists only for a device that passed stage 2, so there is no
`stage2` sysctl. Every instance has its own root, so two instances in one box never share a node
(9.2.2). The `selector` sysctl is the join key: it is the pciconf selector the enumeration read
(4.2), in the same shape, so the tool matches a node to a device by its selector and the order
of the nodes never matters. The driver cannot know what stage 1 chose: the tool compares stage 1's
image with `fw_image` and reports `agrees`.

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
for `ampere`; the mapping from the generation name to the architecture value is the ordered
`generation_order` table in the provider data file, built from `nv_ref.h`). The comparison is
numeric, on the architecture value: the generation name is only how the data file spells it, and
it is never compared as a string. The result lands in the generated C table. The
decision tool uses the same field for stage 1, so both stages give one answer. Turing becomes
supported by editing `min_generation` to `turing` in the data file, regenerating, and making the
`gsp_tu10x` firmware available on arm64 (section 4.5 and 3.1.1). No C is edited.

Turing on arm64 and GA100 on arm64 are one work package, Track #2458: it builds `gsp_tu10x` for
arm64 and moves the floor to Turing. Until it lands, a Turing card on arm64 is refused with
`below_policy`.

Until the interim patch is merged and the table exists, the named constant stays. The commit that
introduces the generated table deletes the constant in the same change.

### 8.3 Mismatch handling

In this RM the GSP image is requested at the first open, not at attach. So the missing-image state
needs no detach or reattach, and it is one behaviour whatever the cause (a manual `kldload`, or
range data that put a device in the wrong firmware group, for example `gsp_tu10x` when the chip
needs `gsp_ga10x`):

1. The driver stays attached. It sets `fw_loaded` to 0 and `fw_image` to what the chip needs. It
   cannot know what stage 1 chose, so its log line names only the image:
   `<instance>:<unit> (<selector>): firmware image <fw_image> is not registered (arch A, impl I); run as root: <tool> --act`.
2. Until that image is registered, the driver refuses opens of that device with `ENXIO`. The log
   line above is written once per device each time `fw_loaded` goes from 1 to 0, and once at
   attach. A per-device flag holds it and is cleared when the image is registered. Every open
   still returns `ENXIO`.
3. The devd rule fires on the driver's own attach event (or the tool's verify step runs right
   after its load). The tool reads `fw_image` and `fw_loaded`, compares `fw_image` with the image
   its stage 1 chose, reports the disagreement (`"agrees": false`), and, as root, loads the
   firmware module the record lists for `fw_image`. The next open works. A `fw_image` the record
   does not list (for example `../../x`) is refused, never passed to `kldload`, and exits 5.
4. A disagreement is data to fix: the id-to-family range in the provider record is wrong, and a
   test case is added.
5. If the correct firmware module is not installed or not available on this architecture, the tool
   exits 5 with that reason: the disagreement stays uncorrected. (A module of the plan that is
   not installed is a different case: the device is refused with the code `module_missing` and a
   `next` that names the package that supplies it, 6.3, step 8.)
6. In decide-only mode the tool reads the same sysctls and reports the same disagreement, but it
   corrects nothing: the run exits 5 with the same reason. Only `--act` corrects.

An out-of-policy or unknown architecture is different: it declines with `ENXIO` at attach (step 3
of section 8) and no node exists.

The test plan (section 14) has cases for these.

## 9. Many backends at once, one package

The user never chooses between `nvidia-driver`, `-470` and `-390`. There is one package and one
tool. The tool picks the backend instance per card.

Every backend is ours: the open RM today, our own native backends for the older generations
(section 11), and more than one RM branch when a branch is needed. There is no third-party NVIDIA
backend: no closed-RM backend and no legacy backend (Mark, 2026-11-23; section 15). The NVIDIA
FreeBSD package ships a closed driver and the legacy 470, 390 and 340 drivers; we take over all
of them (12.1). Each of those is a complete `nvidia.ko` with the same module and symbol names as
ours, so none of them can sit in the box beside ours: ours is the one that is installed. Our own
backends do not take those names: each one runs as an instance with names of its own (9.2), and
several of our own instances run at the same time (9.2). The older cards have no path at all
until our own native backend for that generation exists (section 11).

### 9.1 Binding

Binding is the only place a backend is chosen (step 6 of section 6.3). Step 2 gave each device a
candidate set; binding picks a backend for each device, one device at a time.

- Each device is bound on its own. Nothing about one card's binding constrains another card's.
- For one device, the backends that cover it are its candidate set. The highest backend `score`
  wins. The preference is data: our open RM outscores the native backends that come later
  (checked by the generator, 4.3), and the reasons are in the record.
- There is no group and no `exclusive_group`: the candidate set of one card is never reduced to
  one backend for the box, and no backend is held back for the box.
- A card no backend of ours covers is refused on its own, with the code `uncovered`, the reason
  and a `next` that names what would have to change. The other cards of the box still load. The
  tool never loads a wrong driver for a card.
- The instance of a card is the backend name plus the RM branch of that backend, and nothing else
  (9.2.1). Two cards of different generations that the same backend and the same branch cover
  share one instance, each card with its own unit inside it. Two cards that need different
  backends, or the same backend on different RM branches, get different backend instances, and
  all of those instances run at the same time (9.2).

What the input says. NVIDIA's README for the 580.178.04 FreeBSD package, Appendix A1 ("Current
NVIDIA GPUs"), lists the GPUs the package's driver supports; its first entry is `1340` (GeForce
830M, Maxwell) and it includes `2F58` (RTX 5070 Ti Laptop GPU) and `31C2` (GB300). That is the
coverage of NVIDIA's own closed driver, which we do not ship; it is the set of cards our native
backends have to cover eventually (section 11). The json says the open RM supports the
`kernelopen` ids and that NVIDIA's closed branch can run GSP on the `gsp_proprietary_supported`
ids (`0x1e02..0x28f8`). Residual caveat, **unverified**: the README does not say, per id, which
ids the package's closed RM drives without GSP above `0x28f8`.

The boxes below describe the target state, with the interim floor (8.2) removed. Today the floor
refuses every pre-Ampere card first.

| Box | Result |
|---|---|
| one Blackwell card (arm64) | our open RM; firmware `gsp_ga10x`; one instance |
| one Blackwell card (amd64) | our open RM; firmware `gsp_ga10x`; one instance |
| a Blackwell card and a Pascal card (arm64) | the Pascal card has no backend yet: `uncovered` (`below_policy` while the floor is on) |
| a Blackwell card and a Pascal card (amd64), with the native Pascal backend | two instances: the Blackwell on the open RM, the Pascal on the native one |
| a Pascal card and an Ampere card (amd64), with the native Pascal backend | the candidate set names both backends; rm-open wins for the card it covers |
| an Ampere card and a Hopper card, our open RM on 580 | one instance serves both, one unit each: the instance is the backend name plus the branch |
| two Blackwell cards, our open RM on two branches | two instances, one per branch; both cards are served |
| two Ampere cards | one instance serves both, one unit each |
| AMD card plus NVIDIA card | two providers, two plans; both decided |

### 9.2 Several instances at once

Several backend instances can run in one box: different backends, or the same backend on
different RM branches. They are all our own backends, inside our one driver package. They must
not collide with each other.

#### 9.2.1 The instance name

An **instance** is a backend with one RM branch, and nothing else. The generation of the card is
not part of it: two cards of different generations that the same backend and the same branch
cover share one instance, each card with its own unit inside it. Its name is generated, never
typed:

    instance name = <backend-name>-<major>.<minor>.<patch>

The branch is carried as data, as a version object (`{"string": "580.178.04", "major": 580,
"minor": 178, "patch": 4}`), and the three parts come from that object, never from parsing the
string. The provider-level `driver_branch` is the branch of the record itself; a backend entry
carries the branch its instances are built from (4.3).

Every per-instance name comes from the alias layer, from that one instance name:

| Thing | Rule | Example for `rm-open-580.178.04` |
|---|---|---|
| module file name | the project prefix, the instance name, then `.ko` | `nvidia-rm-open-580.178.04.ko` |
| kernel module name | the file name without `.ko`, with `-` and `.` replaced by `_` | `nvidia_rm_open_580_178_04` |
| device node prefix | the project prefix, the instance name, then `-` | `/dev/nvidia-rm-open-580.178.04-0` |
| sysctl root | `hw.` plus the kernel module name | `hw.nvidia_rm_open_580_178_04.gpus.<n>` |
| control node | `/dev/`, the project prefix, the instance name, then `-ctl` | `/dev/nvidia-rm-open-580.178.04-ctl` |

The modeset and drm modules of an instance carry the same instance name
(`nvidia-modeset-rm-open-580.178.04.ko`, `nvidia-drm-rm-open-580.178.04.ko`).

The backend name is unique in the record, and the branch is a field of that one entry: two RM
branches are two entries with two names (`rm-open-580` and `rm-open-600`), never one name with
two branches (4.3). The generator fails on a duplicate backend name, and it checks that no two
backends produce the same instance name and fails otherwise. The check covers the backends of
every provider, not one record at a time.

#### 9.2.2 Symbols, nodes and sysctls

- **Symbols.** Every symbol an instance exports carries the instance prefix
  (`nvidia_rm_open_580_178_04_*`), so two instances never export the same name. The prefix is a
  build-time value the instance's sources are compiled with, and the generator emits it into the
  build. **Unverified:** whether an RM build can be renamed per instance without source changes.
  The open RM exports fixed symbol names, so this is a phase 2 question (section 14).
- **Device nodes.** Each instance has its own node prefix, and the units inside an instance are
  per card: `/dev/nvidia-rm-open-580.178.04-0` and `/dev/nvidia-rm-open-580.178.04-1` are two
  cards of one instance, and `/dev/nvidia-rm-open-600.178.04-0` belongs to another instance. No
  node name is shared.
- **Sysctls.** Each instance has its own sysctl root (8.1), so the per-device nodes of two
  instances never collide. The `selector` sysctl is still the join key.
- **Control node.** Each instance has its own control node, for the commands that act on the
  instance as a whole: a reset of that instance, a reload of its branch.

#### 9.2.3 Firmware shared by two instances

A firmware image is not per instance. Two instances that need the same image (for example the
open RM on two branches, both needing `gsp_ga10x`) load the firmware module once.

The firmware is one plan for the whole run, not one plan per instance (6.3, step 7):

- The plan has one row per image, de-duplicated by image, and `required_by` names the instances
  that need that image. An image two instances need appears once, with both instances in
  `required_by`.
- The plan runs before any instance's driver plan, so every driver finds its image registered
  (section 7). There is exactly one `kldload` per image, whatever the number of instances that
  need it.
- Every instance that needs the image holds one reference to it. The image is unloaded when the
  last reference goes: when the last instance that needed it is gone and no card of any instance
  needs it any more.
- A reference is taken at load and released at unload, so an instance that loads and unloads
  without touching the firmware holds no reference it never needed.
- Firmware module names are not per instance, because the firmware is not per instance.

| Order | What happens | The image |
|---|---|---|
| instance A loads, then instance B loads | the firmware plan runs first, then the driver plans; one `kldload` for the image | loaded once, two references |
| instance B loads, then instance A loads | the same: the plan is one plan for the run, not one per instance | loaded once, two references |
| A detaches | A's reference goes; B still needs the image | still loaded |
| B detaches | the last reference goes | unloaded |

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
| the build of the core | `scripts/build-rmcore.sh` against the new open RM, on arm64 and on amd64 |

### 10.2 What is regenerated

C tables, devd conf, schema samples and fixtures, manifests, the man page tables that list
families. The drift test (5.4) fails until they are committed.

### 10.3 How the per-generation table moves

The branch's json is the authority. For each device id:

- still no `legacybranch`: stays in its family on this branch;
- newly carries `legacybranch` (the old branch is now the last one for it): the generator moves the
  id to the native backend family that covers it, with the reason
  `"dropped by the 600 branch; last branch 580.xx"`, and while no native backend covers it the
  tool refuses that card with the code `uncovered` and that reason (the floor is checked first,
  so a card below the active floor reads `below_policy`);
- gains a new family: a new family row, flagged "needs a firmware map entry" and failing the
  generator until the map exists.

A card that drops out is never silently reassigned. The generator prints a diff of ids that moved
backends and exits non-zero until a human acknowledges it in the data file
(`"acknowledged_moves": [...]`).

**Unverified:** which generations a 600-series branch drops. Nothing in this file assumes it.
The decision comes only after the branch's `supported-gpus.json` is read.

## 11. Path to full coverage per generation

The target is full coverage: load this driver and support for all NVIDIA cards is present. A card
with no backend yet is today's state, not an answer. The only path to an older card is a native
backend of our own; there is no other driver in the box (Mark, 2026-11-23; section 15). Order
below is by how many cards are in use: Pascal, Maxwell, Kepler, Volta, then Fermi and older.
**This order is our estimate (uncited), from
product age and sales volume. It is to be confirmed against a cited public survey before phase 2
picks the next backend.** Pascal is first in the order, but it is not implemented now: it is its
own work package.

Phase 2 builds and tests Ampere (RTX 30) and later only. The generations below stay designed
provider slots: the record shape, the slot, the firmware answers and the tests are designed, and
nothing is built for them in phase 2 (section 14).

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
- **Core impact.** A new backend is a new backend entry and a new module in the one NVIDIA
  provider record. The core takes it with no core change: the record grows a backend entry, and
  the entry names the module set, the branch, the licence class and the architectures.

The interim floor (8.2) applies to every backend of the NVIDIA record, so the native backends
below stay dormant until `min_generation` is lowered.

### 11.1 Pascal

- Both architectures: a native backend of our own, written from the Pascal manuals and HAL files.
- Firmware: none for GSP. Signed falcon firmware for secure engines: see above (**unverified**
  which engines on Pascal).
- Hardware at init: BAR setup, memory controller, channel and GR engine init, falcon boot.
- Display: our own modeset path, to be written.
- Compute: our own path, to be written.

### 11.2 Maxwell

- Both architectures: a native backend of our own, after Pascal.
- Firmware, init, display, compute: as Pascal. Second-generation chips need signed falcon
  firmware (see above, **unverified**).

### 11.3 Kepler

- Both architectures: a native backend of our own; first-generation parts may need no signed
  falcon firmware (**unverified**).
- Firmware: none at the GSP level.
- Init: as Pascal, with the Kepler manuals.
- Display and compute: our own path, to be written.

### 11.4 Volta

- Both architectures: a native backend of our own; the Volta manuals exist in the tree.
- Firmware: signed falcon firmware (see above, **unverified**).
- Init: as Pascal. Display and compute: our own path, to be written.

### 11.5 Fermi and older

- Both architectures: a native backend of our own only if demand is shown. The tree has no MIT
  manuals for Fermi in the list we checked (**unverified**).
- Firmware: none. Display and compute: our own path, to be written.

For each native backend the one NVIDIA provider record carries a backend entry with the module
set, the `branch` its instances are built from, the licence class, and the `archs` it is built
for. A native backend is an ordinary backend entry of that record, not a second provider: it
runs beside our other backends as its own instance (9.2).

What each path needs, to say it once:

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
  "schema_version": {"string": "1.0", "major": 1, "minor": 0, "patch": 0},
  "names": [
    {"key": "driver.core", "kind": "module", "name": "nvidia"},
    {"key": "driver.modeset", "kind": "module", "name": "nvidia-modeset"},
    {"key": "driver.drm", "kind": "module", "name": "nvidia-drm"},
    {"key": "firmware.gsp_ga10x", "kind": "module", "name": "nvidia_gsp_ga10x_fw"},
    {"key": "firmware.gsp_tu10x", "kind": "module", "name": "nvidia_gsp_tu10x_fw"},
    {"key": "tool.decide", "kind": "tool", "name": "gpu-decide"}
  ],
  "aliases": [
    {"key": "driver.core", "alias": "nvidia", "owner": "this-project",
     "since": {"string": "1.0.0", "major": 1, "minor": 0, "patch": 0},
     "deprecation": {"state": "none"}},
    {"key": "driver.modeset", "alias": "nvidia_modeset", "owner": "this-project",
     "since": {"string": "1.0.0", "major": 1, "minor": 0, "patch": 0},
     "deprecation": {"state": "none"}},
    {"key": "driver.drm", "alias": "nvidia_drm", "owner": "this-project",
     "since": {"string": "1.0.0", "major": 1, "minor": 0, "patch": 0},
     "deprecation": {"state": "none"}}
  ]
}
```

The entries above are shapes. The names in `names` are today's names: the module file names as
`kldstat` and `kld_list` use them (`nvidia`, `nvidia-modeset`, `nvidia-drm`, and the firmware
file names `nvidia_gsp_ga10x_fw` and `nvidia_gsp_tu10x_fw`). The underscore spellings
`nvidia_modeset` and `nvidia_drm` appear only as declared aliases, never as names. The neutral
names are Mark's to give (open question Q9, section 16). The tool name is not among them: it is
decided as `gpu-decide` (6.1).

Rules:

- Code, devd conf, manifests, the man pages' name tables and the JSON all read names from this
  data. A rebrand is a data rename plus regeneration. No code changes.
- The per-instance names of 9.2 are generated through this layer: the base names here (`nvidia`,
  `nvidia-modeset`, `nvidia-drm`) get the instance name appended, so one base name gives one
  module file name per instance. The generator checks that no two instances produce the same
  name, and fails on a clash.
- When ours replaces an existing driver, the old names stay as **declared aliases**: owner,
  since-version (a version object), deprecation state (`none`, `deprecated` with a version, or
  `removed`). One owner per device.
- Every alias entry carries the same `"deprecation": {"state": "..."}` object as this file. There
  is no boolean `deprecated` field anywhere. The device JSON (6.4) carries the same object, so a
  deprecated alias validates in the device output.
- A man page COMPATIBILITY section lists the aliases for the tool and the modules.
- Tests cover: each alias resolves; a removed alias gives a clear error naming the replacement; an
  alias that two providers claim fails generation.
- The JSON reports `aliases` (the names a thing answers to) and `replaced_driver` (the existing
  driver or package ours takes over, for example the `nvidia-driver` package and its `-470`,
  `-390` variants).

### 12.1 We take over every NVIDIA driver

Mark, 2026-11-23: "No other driver should be installed; in fact when this driver gets installed
from ports, it should remove all of the other Nvidia drivers that are packaged these days. We are
completely taking over."

The port and the package declare `CONFLICTS` with every FreeBSD-packaged NVIDIA driver:
`nvidia-driver`, the legacy `nvidia-driver-470`, `nvidia-driver-390` and `nvidia-driver-340`
ports, `nvidia-kmod` and `nvidia-drm-kmod` and the like.

What pkg does, in order: installing ours while a conflicting NVIDIA package is present makes
pkg report the conflict, name the conflicting packages and propose removing them. The user
confirms, and pkg removes them and puts ours in their place. `make install` lists the exact
packages it is about to remove before it asks, and `YES=1` answers that question for a scripted
install. An old driver is never left in the box beside ours: two drivers with the same module
and symbol names cannot both be there (section 9).

| Step | What happens |
|---|---|
| `pkg install` ours with `nvidia-driver-470` present | pkg reports the conflict and proposes removing the conflicting packages |
| the user confirms, or `YES=1` in `make install` | the conflicting packages are removed and ours is installed |
| after the install | the old package is gone: an old driver never sits beside ours |

**Unverified**: the behaviour above is designed, not yet tested. The test is a disposable VM
with `nvidia-driver-470` installed: after the install the old package is gone. Until that test
runs, this behaviour stays **unverified**.

Their names are declared in the alias layer. Each old name is a **declared alias** with an owner,
a since-version (a version object) and a deprecation state, and each old package is named in
`replaced_driver`. The JSON reports both, so a consumer can tell what ours took over.

## 13. Consumers

One decision, many readers. All call the same tool (or its library) and never re-derive the answer.

| Consumer | How it uses the decision |
|---|---|
| devd | the generated conf matches the display class; the action is `gpu-decide --act --device <selector>` as root (section 7) |
| `make preflight` | `gpu-decide --json` replaces `nvidia_devices`; shows decision, reason, `fw_loaded`, command; schema grows additive fields |
| `nvrm-info` | prints the decision and `fw_loaded` with its command per device, beside the generation table and decorators it shows |
| `make configure` | writes `loader.conf` module lines (firmware first) and the devd enable from `--loader-conf`; `make deinstall` removes exactly those |
| install and package | manifests and install lists come from the definition (5.3): only firmware modules some supported family names, per architecture |

## 14. Phase 2 plan and tests

Slices (each lands with its tests; none has a date). Phase 2 builds and tests Ampere (RTX 30) and
later, so every slice that RTX 30 and later needs comes first, and the slices for the other
generations and the other vendors come last and are marked "designed, not built in phase 2":

1. Registry, ops table, factory, scoring, fake provider, English and JSON output, lint. No
   vendor code in the core.
2. Data file format (JSON and UCL), schemas, generator, drift test, committed generated files
   (still no behaviour change).
3. NVIDIA open-RM provider: input from `supported-gpus.json`, families, firmware per arch, policy
   field.
4. Stage 2 in the driver (generated table, sysctls, decline with `ENXIO`, missing-image state); the
   interim floor constant is removed in the same change.
5. Backend binding (section 9) and per-instance coexistence (9.2): binding per card, the instance
   names, the clash check, and the shared firmware reference counting.
6. The alias layer and `data/names.json`, with the `CONFLICTS` declarations of 12.1.
7. Loading as root: devd conf, `--act` with its lock, loader.conf and `kld_list` checks, removal of
   `MODULE_DEPEND`, missing-firmware message.
8. Consumers: preflight, nvrm-info, configure, install.
9. Zero-device load, hot-plug of external GPU enclosures and the simulated NVIDIA PCI device
   (Track #2464).
10. AMD and Intel providers (design in 3.2): **designed, not built in phase 2**.
11. Native backends for the generations below Ampere (Pascal, Maxwell, Kepler, Volta, Fermi and
    older; section 11): **designed, not built in phase 2**. The next one to build is chosen after
    the survey is cited.

All tests run from fake `pciconf -l` input and the fake provider. None needs hardware.

| Case | Expected |
|---|---|
| supported NVIDIA card (GB206 `0x2d04`, subsystem 1462:5351) | `supported`, firmware `gsp_ga10x`, driver set named, firmware first |
| NVIDIA id claimed but below policy (Turing on arm64) | `refused`, code `below_policy`; policy is checked first, so it wins over `not_built_arm64` |
| NVIDIA id in no family | `no_provider`: no record names it; the fix is a newer input |
| the same Kepler card, floor on | `refused`, code `below_policy`: below the active floor, and the floor is checked first |
| the same Kepler card, floor off | `refused`, code `uncovered`: policy admits it and no backend of ours covers it |
| non-NVIDIA card (BMC display adapter) | `no_provider`; never loaded; empty `features` |
| mixed two-vendor box (AMD plus NVIDIA) | two plans, one per provider; both decided |
| NVIDIA card not at index 0 | two NVIDIA cards with shuffled `<n>`; decided by selector, not by index |
| stage 2 image differs from stage 1 | fake sysctls report another `fw_image`; `agrees:false`; the right module loads; exit 5 if unavailable |
| stage 2 image differs from stage 1, decide-only | the mismatch is reported and the run exits 5: it corrects nothing |
| stage 2: fake BOOT_42 below `min_generation` | attach declines with `ENXIO`; no `hw.<instance>.gpus.<n>` node; a log line names the architecture value |
| stage 2: the image the chip needs is not built for this arch | a GA100 with a GB206 on arm64 declines with `ENXIO`, no node; the GB206 attaches |
| `fw_image=../../x` | refused, never passed to `kldload`; exit 5 |
| GA100 on arm64 (backend built, firmware not) | `refused`, code `not_built_arm64`, the reason names the firmware; no driver step is planned |
| built but untested (Hopper on arm64) | `supported` with the warning `not_tested_on_arm64`; the English line carries `warning: not_tested_on_arm64` |
| i915 on arm64 (backend not built) | `refused`, code `not_built_arm64`, the reason `i915 is not built for arm64` |
| a fake candidate that is amd64-only, on arm64 | `refused`, code `not_built_arm64`: the core reads the candidate's own `archs`, with no vendor knowledge |
| mixed generations, one backend covers all | one instance serves both; our backend wins for each card it covers |
| an Ampere card and a Hopper card on rm-open 580 | one instance, two units: the instance is the backend name plus the branch, not the generation |
| mixed generations, no backend covers all | each card binds on its own: one is served, the other is refused with `uncovered`, reason and `next` |
| a Pascal card and an Ampere card, one record with both backends | the candidate set names both backends; rm-open wins for the card it covers |
| two Ampere cards, one backend | one instance serves both, one unit each |
| two-card box, `--act --device A` | the firmware plan lists the firmware image once, then the driver plan of every instance the run binds |
| a two-card box with cards of different generations, no backend covers both | two instances, one per card; both load; the plans are separate |
| two fake backends with different branches | the generated names are disjoint: no module name, node prefix, sysctl root or control node is shared |
| a planted clash: two backends with the same name and branch | generation fails: the generator refuses the duplicate instance name |
| a planted duplicate backend name | generation fails: the backend name is unique in the record, and the branch is a field of that entry |
| two instances that need the same firmware image | the firmware plan has one row for the image, both instances in `required_by`; one `kldload` |
| instance A loads, then instance B | the image loads once; each instance holds a reference |
| instance B loads, then instance A | the same: one image, one load, two references |
| instance A detaches | the image stays loaded: instance B still holds a reference |
| instance B detaches | the image is unloaded: the last reference went |
| two concurrent `--act` runs | the lock is taken before step 1 and held to the end of verify; the second run waits, never acting on a stale plan |
| a third `--act` run, the lock held past the wait bound | it prints that it waits, then exits 8 with the reason `lock_timeout` |
| a non-root `--act` run | it never takes the lock; it prints the root command to use |
| `kld_list="nvidia-drm"`, `nvidia` loaded, firmware not loaded | the `nvidia-drm` step is marked `already listed`; the plan loads only the firmware module |
| run as root without `--act` | nothing loaded |
| `provider_error` from a fake provider | `provider_error`; no fall-through to a lower-scoring provider |
| exit precedence | each pair in the order 4, 8, 5, 1, 7, 6, 3, 0 gives the higher code |
| decide-only on amp001 | exit 0: every claimed device would be served |
| decide-only, a GA100 alone on arm64 | exit 7: the only claimed device is refused |
| decide-only, a Pascal card alone on arm64 | exit 7, not 3: the card is claimed, so something is missing |
| one card whose provider `match` returns EIO | exit 7: `provider_error` |
| English line | JSON `english` equals the plain text line for every device |
| the amp001 gpu0 English line | contains `package gpu-firmware-amd-kmod-navi33 (installed)` |
| every `supported` device label | appears in exactly one plan and in exactly one verify record |
| fake provider features: one with a value, one with a reason | both appear in the JSON: index 9001 with its value, the other with its reason |
| AMD fixture, firmware package missing, `--act`, stub `pkg` and `fwget` on PATH | result `needs_install`; the stubs are never called; exit 7 |
| a `kld` module of the plan is not installed | `refused`, code `module_missing`; the `next` names the package that supplies the module |
| verify, no driver loaded | state `not_loaded`, and it is not an error: the exit code is the one the decisions give |
| verify, the driver is loaded and the image agrees | state `agreed`, `agrees:true` |
| verify, the driver is loaded and the image differs, and the tool corrected it | state `mismatched`, `agrees:false`, exit 0 |
| verify, the driver is loaded and the image differs, and it cannot be corrected | state `mismatched`, exit 5 |
| verify, the driver is loaded and the expected node is missing | state `unreadable`; exit 1 with `--act`, reported in decide-only |
| a module file name with dashes and dots | the step carries `module_file` and `kernel_module`; `kldload` takes the file, `kldstat` the kernel name |
| 10000 opens with the image absent | one log line; every open returns `ENXIO` |
| over-long selector or version string | parser error, no truncation; 31 characters are accepted in a 32-byte buffer, 32 are rejected |
| decorator conflict | the generator fails |
| two families match one (architecture, implementation) | the generator fails |
| a family whose `generations[].arch_values` do not union to its own `arch_values` | the generator fails |
| a generation the record uses that is missing from `generation_order` | the generator fails |
| a planted Turing entry containing `0x20b0` | generation fails: that device id is in two families |
| a preference list whose earlier backend does not outscore the later, or a record over its bound | the generator fails |
| lint | the core is clean; the planted vendor check makes the lint fail |
| lint, the data files missing | the lint fails: it fails closed, it never passes what it could not look at |
| a provider data file in UCL | it validates against the same schema as its JSON twin |
| the JSON and UCL samples of section 5.1 | both parse, both validate against the source schema, and their value trees are equal |
| a JSON data file and its UCL twin | the generated outputs are byte-identical |
| drift | a stale generated file or an unregenerated data edit fails the build; the planted drift fails |
| drift: the input file changes | `record_version` changes with it; the diff fails until the record is regenerated |
| `record_version` in a data file | the generator refuses it: the generator owns that field |
| a whitespace-only change to a record | `record_version` does not move: it is computed from the parsed record, not from the file bytes |
| a semantic change to a record | `record_version` moves |
| a drifted UCL twin | the generator fails: the twin must match the canonical JSON |
| tie by score | resolved by name; warning present |
| manual `kldload` without firmware | driver stays attached; `fw_loaded=0`; open returns `ENXIO`; the log line names the command; no hang |
| #2417 regression | a non-root user opens the node after the devd action and the open succeeds |
| JSON | validates against the schema; versions have string and integer parts; `available:false` has a reason; every feature index appears |
| `os_release` | carries `suffix` (`CURRENT`), a defined string part of the versions sentence, never parsed for comparison |
| names | every alias resolves; the removed alias error names the replacement |
| a deprecated alias | validates in the device output: the `deprecation` object, never a boolean |
| a disposable VM with `nvidia-driver-470` installed, then our package | the old package is gone after the install; **unverified** until that test runs |
| the same pciconf input, host arm64 then amd64, interim floor off | a Pascal card gives `uncovered` on arm64 and a candidate set on amd64 |
| zero NVIDIA devices in the box | the driver loads cleanly; nothing is decided and nothing is loaded |
| a hot-plug arrival | a fresh decision for the card that arrived; nothing is cached per slot; a backend instance and a firmware are chosen per card |
| a card detached | the instance no attached card needs is unloaded, and a firmware image is unloaded when its last reference goes |
| N devices of one class arriving and leaving in any order | N independent decision records; no fixed count, no slot and no unit assumption |
| the simulated NVIDIA PCI device in a VM (Track #2464) | the device is decided like any other |

## 15. Decisions

Mark answered on 2026-11-23. Each decision below is his, in his words.

1. **The tool is `gpu-decide`.** The name says the class, so there is no `--class` option: GPU is
   the first class, and a class-neutral name comes with the next class. The man page is
   `gpu-decide(8)`.
2. **Every NVIDIA driver in the box is ours.** There is no closed-RM backend and no legacy
   backend: no third-party NVIDIA driver at all. "No other driver should be installed; in fact
   when this driver gets installed from ports, it should remove all of the other Nvidia drivers
   that are packaged these days. We are completely taking over."
3. **Older cards are reached only through our own native backends.** Maxwell, Pascal, Volta,
   Kepler and older have no other path. Pascal is first in the order, but it is not implemented
   now: it is its own work package.
4. **Many backends at once, one per card.** "We might have to get pluralistic": many backends at
   once, and many of each class. Several of our NVIDIA backends run at the same time, all inside
   our one driver package. The instance of a card is the backend name plus the RM branch, and
   nothing else: cards of different generations that the same backend and the same branch cover
   share one instance, each card with its own unit inside it. The core binds each device to a
   backend instance independently. A card is refused only when no backend
   of ours covers it: `uncovered`, with the reason and a `next`. There is no group and no
   one-backend-per-box rule.
5. **Turing and GA100 on arm64 are one work package, Track #2458.** It builds `gsp_tu10x` for
   arm64 and moves the floor to Turing.
6. **i915 on arm64 is refused**, with the code `not_built_arm64` and the reason "i915 is not
   built for arm64".
7. **Provider data exists in both JSON and UCL**, from one schema: each format is checked against
   `schema/provider-record-1.schema.json`, the generator reads either, and a JSON file and its UCL
   twin give byte-identical generated outputs.
8. **Zero-device load, hot-plug of external GPU enclosures and the simulated fictional NVIDIA PCI
   device are Track #2464.** "We should be able to load the driver with no device present. There
   are external usb enclosures where they can be plugged in and unplugged ... We may want to make
   a Vm and see about simulating with a fictional device."
9. **Every hot-plug arrival is a fresh decision.** "The devices that get pulled in and out may not
   be the same." Nothing is cached per slot; the backend instance and the firmware are chosen per
   card, and an instance no attached card needs any more is unloaded on detach.
10. **Namespacing is per instance, not per box.** The earlier answer that there was nothing to
    namespace, because there was one RM, does not hold now that several instances can run at
    once. Every per-instance name (module file name, kernel module name, device node prefix,
    sysctl root, control node) carries the backend name and its RM branch, and the generator
    fails when two backends would produce the same name.
11. **Any number of devices per class.** Each device of a class arrives and leaves on its own
    (#2464); there is no fixed count, no slot and no unit; each device has its own decision
    record, its own binding to a backend instance and its own unit inside that instance.

## 16. Open questions for Mark

The two questions below are still open. They keep the numbers they had in the question list.

- **Q6. Firmware sources for pre-Turing native backends.** Options: extract from NVIDIA's closed
  package (acceptance needed, class 3), or use NVIDIA's redistributable firmware releases if their
  licence allows (unread). Recommendation: read the licence of the redistributable releases first;
  class 2 until then. Phase 2 does not build the pre-Turing backends, so this does not block
  phase 2 (section 14).
- **Q9. Neutral names.** The rebrand names for the modules, the package, the sysctl root and the
  device nodes are yours to give. The design needs them only as data. Recommendation: pick them
  any time; nothing waits on them. The tool name is no longer part of the question: it is
  decided as `gpu-decide` (6.1, decision 1 of section 15).

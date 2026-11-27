# The model files of the GPU mock

One JSON file per card, in the schema `gpu-model.v1` (the schema of the file
is `schema/gpu-model-1.schema.json`; the schema of the document the tool
prints is `schema/gpu-mock-1.schema.json`).  A model file is data: it says
which cards the mock has, what each of them is, what the providers claim and
which faults are scripted.  Nothing in the code knows a vendor.

## The files

| File | What it is |
|---|---|
| `nvidia-provider.json` | the provider record of NVIDIA: the vendor it claims, the generations it drives and the firmware each of them needs.  The card files include it, so the record is written once. |
| `rtx5060ti.json` | one card: the GeForce RTX 5060 Ti (GB206) of the boot capture of 2026-11-22 (`tests/data/nvrm-info-boot-20261122T095018Z`). |
| `gb10.json` | one card: the GB10 SoC of the DGX Spark (device id 0x2e12, GB20B). |
| `rx7600.json` | one card: the AMD Radeon RX 7600 (Navi 33) of the same capture.  No provider of ours claims vendor 0x1002, so the decision on it is `not_claimed`. |
| `turing.json` | one card: a GeForce RTX 2080 Ti (TU10x).  Its firmware (`gsp_tu10x`) is not built on this platform, so the decision on it is `unsupported_firmware`. |
| `pascal.json` | one card: a GeForce GTX 1080 (GP100).  It is below the floor of the provider, so the decision on it is `unsupported_generation`. |
| `mixed-box.json` | one box: the amp001 test box, with the AMD card, the NVIDIA card and the BMC display adapter.  It composes `rx7600.json` and `rtx5060ti.json` through its `include` member. |
| `fault-device-lost.json` | the RTX 5060 Ti with the device lost: the RM does not list it. |
| `fault-alloc-refused.json` | the RTX 5060 Ti with the allocations refused. |

## Where every value comes from

| Value | Source |
|---|---|
| the identity, the PCI location, the VRAM, the BARs, the class list, the SM version and the capabilities of the RTX 5060 Ti | `tests/data/nvrm-info-boot-20261122T095018Z/` (the boot capture of 2026-11-22) and `pciconf.txt` of the same capture |
| the device ids and the card names | NVIDIA's own `supported-gpus.json` of the 580.178.04 tarball |
| the architecture values and the generations | `docs/DEVICE-DECISION.md` (section 3.1) and the tables of `JOURNAL.md` |
| the GB10's architecture (0x1b0 with the implementation 0x0b, SM 12.1), its unified memory and its coherence | `docs/RENDER-UAPI.md` (section 2.2) and the unified profile of `lib/libnvrm/nvrm_fake.c` |
| the VBIOS revision of the RTX 5060 Ti (0x96061e00, the OEM 0x4a) | the `discrete` profile of `lib/libnvrm/nvrm_fake.c` |

The values that no checked source carries are left out of the file (the VRAM
of the Turing card, the revision of the GB10) rather than guessed.  The UUIDs
of the cards that were never read are the synthetic ones of the fake backend's
profiles, and they say so in the description of the model.

## The floor of the provider

The provider record names `turing` as its floor: the oldest generation with a
backend of ours.  The interim floor of the driver (Ampere and later) is a
policy of the driver, not of this record, and the Turing card is refused here
for the other reason: the `gsp_tu10x` firmware is not built on this
platform.

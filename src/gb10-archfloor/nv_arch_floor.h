/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The architecture floor of nvidia.ko (Track #2457): the driver attaches to
 * GA10x (RTX 30) and later GPUs and refuses anything older at probe time.
 * The floor lives here and nowhere else; scripts/make.sh (make preflight)
 * reads the NV_ARCH_FLOOR_TABLE and NV_ARCH_FLOOR_FIRMWARE rows of this very
 * file with awk, so no second copy of the values exists.  The device
 * provider registry (Track #2455, docs/DEVICE-DECISION.md section 8.2)
 * replaces the constant with a value generated from the provider record.
 *
 * The decision and the one-line message are pure functions of the two
 * register values and need no kernel types; the probe that reads the
 * registers is in nv_arch_floor.c next to them.
 */
#ifndef NV_ARCH_FLOOR_H
#define NV_ARCH_FLOOR_H

#include <sys/types.h>

#ifdef _KERNEL
#include <sys/bus.h>

struct sysctl_ctx_list;
struct sysctl_oid;
#endif

/*
 * Register offsets and fields, from NVIDIA's open-gpu-kernel-modules
 * src/common/inc/swref/published/nv_ref.h (MIT): NV_PMC_BOOT_0 is 0x0,
 * NV_PMC_BOOT_42 is 0xA00 with NV_PMC_BOOT_42_ARCHITECTURE in bits 29:24 and
 * NV_PMC_BOOT_42_IMPLEMENTATION in bits 23:20.
 */
#define NV_ARCH_FLOOR_PMC_BOOT_0		0x0
#define NV_ARCH_FLOOR_PMC_BOOT_42		0xA00
#define NV_ARCH_FLOOR_ARCH_SHIFT		24
#define NV_ARCH_FLOOR_ARCH_MASK			0x3f
#define NV_ARCH_FLOOR_IMPL_SHIFT		20
#define NV_ARCH_FLOOR_IMPL_MASK			0xf
#define NV_ARCH_FLOOR_ALL_ONES			0xffffffffu

/*
 * The architecture values are not chronological, but every GA10x or later
 * value is at least 0x17 and every older one is below it (nv_ref.h).
 *
 * Every name here is a chip family, never a marketing name.  NAME is the
 * published value: it is what hw.nvidia.min_architecture_name returns and
 * what the preflight JSON carries as the architecture name.  LABEL is that
 * name with the product line it covers.  There is no second name for the
 * floor: the messages print the name of the row they name.
 */
#define NV_ARCH_FLOOR_MIN_ARCHITECTURE		0x17
#define NV_ARCH_FLOOR_MIN_ARCHITECTURE_NAME	"GA10x"
#define NV_ARCH_FLOOR_MIN_ARCHITECTURE_LABEL	"GA10x (RTX 30)"

/*
 * Known architectures: ROW(value, "chip family", "chip key").  One row per
 * line so that make preflight can read the table with awk.  The name of a
 * row is its chip family: the chip key with its last digit replaced by an x
 * (GM10 gives GM10x, GV11 gives GV11x, GB20 gives GB20x), or the chip name
 * itself where the family has a single chip (GH100).  The name is a value
 * too: the architecture field of the preflight JSON carries it.
 *
 * The chip key is the first four characters of the chip names of the family
 * (GM100 gives GM10, GV100 gives GV10, GV110 gives GV11).  The key tells
 * the families apart, which the two-letter prefix cannot: GM10x and GM20x
 * both start with GM, and GB10x and GB20x both start with GB.  make preflight
 * looks a chip name up by that key (the first four characters of the name
 * pciconf gives); the kernel looks it up by the architecture number the
 * register gives, which needs no key at all.
 */
#define NV_ARCH_FLOOR_TABLE(ROW) \
	ROW(0x11, "GM10x", "GM10") \
	ROW(0x12, "GM20x", "GM20") \
	ROW(0x13, "GP10x", "GP10") \
	ROW(0x14, "GV10x", "GV10") \
	ROW(0x15, "GV11x", "GV11") \
	ROW(0x16, "TU10x", "TU10") \
	ROW(0x17, "GA10x", "GA10") \
	ROW(0x18, "GH100", "GH10") \
	ROW(0x19, "AD10x", "AD10") \
	ROW(0x1a, "GB10x", "GB10") \
	ROW(0x1b, "GB20x", "GB20")

/*
 * GSP images that a build may lack: ROW(architecture, implementation, "chip",
 * "image", "machines").  GA100 runs the gsp_tu10x image, which only the
 * amd64 build carries, so the last field names the machine architectures
 * whose build carries the image.  That list is the only copy of the fact:
 * the kernel and make preflight both read it from this row, and the
 * MODULE_DEPEND that makes the image's firmware module a dependency of
 * nvidia.ko carries the same condition (patches/patch-zz-nvidia_fw_depend_pci.c).
 */
#define NV_ARCH_FLOOR_FIRMWARE(ROW) \
	ROW(0x17, 0x0, "GA100", "gsp_tu10x", "amd64")

/*
 * The machine architecture of this build: "amd64" or "aarch64".  It comes
 * from <machine/param.h>; a test overrides it with -D.
 */
#ifndef NV_ARCH_FLOOR_MACHINE
#include <machine/param.h>
#define NV_ARCH_FLOOR_MACHINE		MACHINE_ARCH
#endif

enum nv_arch_floor_verdict {
	NV_ARCH_FLOOR_ACCEPT = 0,
	NV_ARCH_FLOOR_BELOW_FLOOR,
	NV_ARCH_FLOOR_UNKNOWN,
	NV_ARCH_FLOOR_NO_FIRMWARE,
	NV_ARCH_FLOOR_NOT_RESPONDING,
	NV_ARCH_FLOOR_UNREADABLE
};

/* The fixed keyword of a verdict (accept, below-floor, ...). */
const char *nv_arch_floor_keyword(enum nv_arch_floor_verdict);

struct nv_arch_floor_decision {
	enum nv_arch_floor_verdict verdict;
	unsigned architecture;			/* BOOT_42 architecture */
	unsigned implementation;		/* BOOT_42 implementation */
	const char *architecture_name;		/* table name or NULL */
	const char *chip;			/* firmware row chip or NULL */
	const char *missing_image;		/* image this build lacks or NULL */
	const char *machines;			/* builds that carry the image */
};

/* Decide from the raw PMC_BOOT_0 and PMC_BOOT_42 values.  Pure. */
void nv_arch_floor_decide(uint32_t boot_0, uint32_t boot_42,
    struct nv_arch_floor_decision *decision);

/*
 * Format one line, no trailing newline, for a device called NAME (NULL
 * prints "NVIDIA GPU") with PCI device id DEVICE_ID.  Truncates safely.
 */
void nv_arch_floor_format(const struct nv_arch_floor_decision *decision,
    const char *name, uint16_t device_id, char *buf, size_t len);

/* The one-line message length, including the terminating NUL. */
#define NV_ARCH_FLOOR_LINE_SIZE			192

/*
 * The PCI selector of a device, as pciconf(8) prints it: "pci" and the
 * domain, bus, slot and function in decimal, for example "pci0:13:0:0".
 * The longest one is "pci", ten digits of domain, three of bus, three of
 * slot and three of function and three colons: 3 + 10 + 1 + 3 + 1 + 3 + 1
 * + 3 = 25 characters, and the terminating NUL makes 26.
 */
#define NV_ARCH_FLOOR_LOCATION_SIZE		32

/*
 * The name unit of the parent device, the PCI device the driver sits on:
 * "vgapci1" and the like.  Nine characters and the terminating NUL are
 * enough for a PCI device name.
 */
#define NV_ARCH_FLOOR_NAME_SIZE			16

#ifdef _KERNEL
/* Refused devices kept for hw.nvidia.refused. */
#define NV_ARCH_FLOOR_MAX_REFUSED		16

/*
 * The locations of the refused devices, for the dedupe: a device that did
 * not fit the list above is still counted once and logged once.  Past this
 * many locations a refusal is logged again every time it is probed, and it
 * is counted again every time as well: a location that is not in this table
 * is never forgotten, so past it refused_count can overstate the number of
 * refused GPUs.
 */
#define NV_ARCH_FLOOR_MAX_LOCATIONS		64

/*
 * 0 to accept the device, ENXIO to refuse it.  NAME is the device name RM
 * gave it, or NULL.  A non-NVIDIA device is refused silently.
 */
int nv_arch_floor_probe(device_t dev, const char *name);

/* hw.nvidia.min_architecture, min_architecture_name, refused_count, refused. */
void nv_arch_floor_sysctl_init(struct sysctl_ctx_list *ctx,
    struct sysctl_oid *parent);
#endif /* _KERNEL */

#endif /* NV_ARCH_FLOOR_H */

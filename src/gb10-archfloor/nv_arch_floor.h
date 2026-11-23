/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The architecture floor of nvidia.ko (Track #2457): the driver attaches to
 * Ampere (RTX 30) and later GPUs and refuses anything older at probe time.
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
 * The architecture values are not chronological, but every Ampere or later
 * value is at least 0x17 and every older one is below it (nv_ref.h).
 */
#define NV_ARCH_FLOOR_MIN_ARCHITECTURE		0x17
#define NV_ARCH_FLOOR_MIN_ARCHITECTURE_NAME	"Ampere"
#define NV_ARCH_FLOOR_MIN_ARCHITECTURE_LABEL	"Ampere (RTX 30)"

/*
 * Known architectures: ROW(value, "Name", "chip prefix").  One row per line
 * so that make preflight can read the table with awk.
 */
#define NV_ARCH_FLOOR_TABLE(ROW) \
	ROW(0x11, "Maxwell", "GM") \
	ROW(0x12, "Maxwell", "GM") \
	ROW(0x13, "Pascal", "GP") \
	ROW(0x14, "Volta", "GV") \
	ROW(0x15, "Volta", "GV") \
	ROW(0x16, "Turing", "TU") \
	ROW(0x17, "Ampere", "GA") \
	ROW(0x18, "Hopper", "GH") \
	ROW(0x19, "Ada", "AD") \
	ROW(0x1a, "Blackwell", "GB") \
	ROW(0x1b, "Blackwell", "GB")

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

/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-3-Clause
 *
 * gb10_memattr.h - arm64 memory-attribute policy for the FreeBSD OS layer
 * (nvidia_os.c os_map_kernel_space, nvidia_subr.c nvidia_mmap_dev_single)
 * when it maps a physical range.  The range is expected to be an NVIDIA
 * PCIe BAR (device registers or a framebuffer aperture), but it can turn
 * out to be managed system RAM, and then a different policy applies - see
 * the gb10_range_action() choice table below.
 *
 * Why a policy of our own: on arm64 the attribute has to describe device
 * memory, and the obvious choices are wrong.  VM_MEMATTR_WRITE_COMBINING
 * aliases VM_MEMATTR_WRITE_THROUGH (sys/arm64/include/vm.h:46) and is
 * cacheable; VM_MEMATTR_UNCACHEABLE is Normal non-cacheable, which is the
 * arm64 write-combining attribute for a BAR but also permits speculative
 * reads and merged writes - and on Ampere Altra / Altra Max systems
 * Normal memory accesses to PCIe BARs are not safe at all (Track #1908),
 * which is why those systems need VM_MEMATTR_DEVICE (Device-nGnRE) even
 * for write-combining requests.  On a system that does not need the Altra
 * fix, keeping Normal-NC for write-combining preserves the performance
 * the request asked for; nothing here changes x86, where NVIDIA's own
 * PAT_* mapping in os_map_kernel_space() stays in charge.
 *
 * This header is deliberately pure - no kernel includes, no globals - so
 * tests/memattr_policy_test.sh can compile it into a userland program
 * and check the table below.  Mapping the returned class to a
 * VM_MEMATTR_* value stays with the (arm64-only) kernel-side callers:
 *
 *   GB10_ATTR_DEVICE     -> VM_MEMATTR_DEVICE      (Device-nGnRE)
 *   GB10_ATTR_NORMAL_NC  -> VM_MEMATTR_UNCACHEABLE (Normal non-cacheable)
 *   GB10_ATTR_WRITE_BACK -> VM_MEMATTR_WRITE_BACK
 *   GB10_ATTR_INVALID    -> caller errors out, as it does today
 *
 * System-RAM mappings in nvidia_subr.c keep using _convert_caching_to_attr()
 * where the file already applies it; for the two mapping entry points above
 * the caller first walks the range's pages with vm_phys_paddr_to_vm_page()
 * (sys/vm/vm_phys.h), counting the managed-RAM pages and the PAGE_SIZE
 * steps walked, and feeds the two counts to gb10_range_class();
 * gb10_range_action() then picks the policy for the kind it returns:
 * every page managed RAM -> the system-memory policy (gb10_ram_memattr(),
 * or _convert_caching_to_attr()), no managed RAM page -> the BAR policy
 * (gb10_bar_memattr()), a mix of RAM and non-RAM -> refuse the mapping.
 */

#ifndef _GB10_MEMATTR_H_
#define	_GB10_MEMATTR_H_

/*
 * The caching classes of a mapping request, by value: these are NVIDIA's
 * NV_MEMORY_* constants from the driver tarball's
 * common/inc/os/nv_memory_type.h (MIT), repeated here so the header stays
 * standalone (and testable in userland) instead of including driver or
 * kernel headers.
 */
#define	GB10_CACHING_CACHED		0u	/* NV_MEMORY_CACHED */
#define	GB10_CACHING_UNCACHED		1u	/* NV_MEMORY_UNCACHED */
#define	GB10_CACHING_WRITECOMBINED	2u	/* NV_MEMORY_WRITECOMBINED */
#define	GB10_CACHING_DEFAULT		6u	/* NV_MEMORY_DEFAULT */

/*
 * The attribute classes an arm64 mapping may get.  INVALID is returned for
 * any caching class a policy does not know (including NV_MEMORY_WRITEBACK 5
 * and NV_MEMORY_UNCACHED_WEAK 7, which os_map_kernel_space() rejects today
 * and which are system-RAM concepts); the caller must then fail the mapping
 * instead of guessing an attribute.
 */
enum gb10_memattr {
	GB10_ATTR_INVALID	= -1,
	GB10_ATTR_DEVICE	= 0,	/* arm64 Device-nGnRE */
	GB10_ATTR_NORMAL_NC	= 1,	/* arm64 Normal non-cacheable */
	GB10_ATTR_WRITE_BACK	= 2	/* cacheable, for CACHED requests */
};

/*
 * gb10_bar_memattr - the arm64 attribute class for mapping a PCIe BAR.
 *
 * caching_class is one of the GB10_CACHING_* values above (callers pass
 * the request's NV_MEMORY_* class through unchanged).  altra is non-zero
 * when the Ampere Altra quirk is active for this system (see
 * gb10_mcfg_is_altra() and the hw.nvidia.altra_device_wc tunable in
 * nvidia_os.c).
 *
 *   request         altra = 0        altra = 1
 *   CACHED          WRITE_BACK       DEVICE
 *   UNCACHED        DEVICE           DEVICE
 *   DEFAULT (BAR)   DEVICE           DEVICE
 *   WRITECOMBINED   NORMAL_NC        DEVICE
 *   anything else   INVALID          INVALID
 *
 * Time:  O(1) - one switch on a fixed value set.
 * Space: O(1).
 */
static __inline enum gb10_memattr
gb10_bar_memattr(unsigned caching_class, int altra)
{

	switch (caching_class) {
	case GB10_CACHING_CACHED:
		/*
		 * A cacheable Normal-WB mapping of a BAR is the worst case
		 * of the unsafe Normal accesses on Ampere Altra (#1908), so
		 * there a CACHED BAR request falls back to Device-nGnRE like
		 * every other class; a coherent system (e.g. GB10) keeps the
		 * write-back attribute the request asked for.
		 */
		return (altra ? GB10_ATTR_DEVICE : GB10_ATTR_WRITE_BACK);
	case GB10_CACHING_UNCACHED:
	case GB10_CACHING_DEFAULT:
		/*
		 * Uncached BAR registers, and the default class for a BAR,
		 * are device memory on every arm64 system: Device-nGnRE.
		 */
		return (GB10_ATTR_DEVICE);
	case GB10_CACHING_WRITECOMBINED:
		/*
		 * Normal non-cacheable is arm64's write-combining attribute
		 * (merging, no speculative access reordering guarantees that
		 * registers need) and is what a working system should get;
		 * on Ampere Altra it is unsafe for BARs (#1908), so there
		 * the request falls back to Device-nGnRE.
		 */
		return (altra ? GB10_ATTR_DEVICE : GB10_ATTR_NORMAL_NC);
	default:
		return (GB10_ATTR_INVALID);
	}
}

/*
 * gb10_ram_memattr - the arm64 attribute class for mapping managed system
 * RAM: the os_map_kernel_space() equivalent of nvidia_subr.c's
 * _convert_caching_to_attr().  Cached and the default class stay
 * write-back; uncached and write-combined become Normal non-cacheable
 * (VM_MEMATTR_UNCACHEABLE) - never Device-nGnRE and never the cacheable
 * VM_MEMATTR_WRITE_COMBINING alias.  A BAR attribute must never reach a
 * managed RAM page: pmap_page_set_memattr() rewrites the page's DMAP alias
 * to match and pv_memattr outlives the mapping, so Device-nGnRE (or a
 * mismatched Normal alias) on RAM makes every later unaligned kernel access
 * to that page fault - the Track #1908 hazard.  Any class
 * os_map_kernel_space() rejects on x86 (NV_MEMORY_WRITEBACK 5,
 * NV_MEMORY_UNCACHED_WEAK 7, ...) is INVALID so the caller fails the
 * mapping as it does today.
 *
 *   request         attribute
 *   CACHED          WRITE_BACK
 *   DEFAULT         WRITE_BACK
 *   UNCACHED        NORMAL_NC
 *   WRITECOMBINED   NORMAL_NC
 *   anything else   INVALID
 *
 * Time:  O(1) - one switch on a fixed value set.
 * Space: O(1).
 */
static __inline enum gb10_memattr
gb10_ram_memattr(unsigned caching_class)
{

	switch (caching_class) {
	case GB10_CACHING_CACHED:
	case GB10_CACHING_DEFAULT:
		return (GB10_ATTR_WRITE_BACK);
	case GB10_CACHING_UNCACHED:
	case GB10_CACHING_WRITECOMBINED:
		return (GB10_ATTR_NORMAL_NC);
	default:
		return (GB10_ATTR_INVALID);
	}
}

/*
 * gb10_range - what the caller's page walk decided about a physical range
 * the driver was asked to map.  The kernel-side per-page predicate is
 * `vm_phys_paddr_to_vm_page(pa) != NULL` (sys/vm/vm_phys.h: non-NULL
 * exactly for a page the VM system manages as system RAM, NULL for a
 * device BAR / MMIO hole), walked over every page of [start, start+size)
 * by the caller in nvidia_os.c / nvidia_subr.c.  The caller counts the
 * predicate's hits and the steps it walked and hands the two counts to
 * gb10_range_class() below, so the classification stays pure and
 * testable:
 *
 *   GB10_RANGE_RAM    every page of the range is managed system RAM
 *   GB10_RANGE_BAR    no page is managed RAM (a PCIe BAR / device MMIO)
 *   GB10_RANGE_MIXED  some pages are RAM and some are not
 */
enum gb10_range {
	GB10_RANGE_MIXED	= -1,
	GB10_RANGE_BAR		= 0,
	GB10_RANGE_RAM		= 1
};

/*
 * gb10_range_class - classify a physical range from two counts:
 * ram_pages, the number of pages of the range whose
 * vm_phys_paddr_to_vm_page() was non-NULL (managed system RAM), and
 * pages, the total number of PAGE_SIZE steps the caller walked over
 * [start, start+size).
 *
 *   ram_pages == 0      GB10_RANGE_BAR    nothing in the range is RAM
 *   ram_pages == pages  GB10_RANGE_RAM    everything in the range is RAM
 *   anything else       GB10_RANGE_MIXED
 *
 * pages == 0 gives GB10_RANGE_BAR: an empty range maps nothing as RAM,
 * so the caller keeps the attribute such a request gets today.  An
 * over-count (ram_pages > pages, a caller bug) is neither == 0 nor
 * == pages, so it lands on GB10_RANGE_MIXED and the mapping is refused:
 * the table fails closed.
 *
 * Time:  O(1) - two comparisons.
 * Space: O(1).
 */
static __inline enum gb10_range
gb10_range_class(unsigned long ram_pages, unsigned long pages)
{

	if (ram_pages == 0)
		return (GB10_RANGE_BAR);
	if (ram_pages == pages)
		return (GB10_RANGE_RAM);
	return (GB10_RANGE_MIXED);
}

/*
 * gb10_map_action - what the OS layer must do with a mapping request, given
 * the kind of the range it was handed:
 *
 *   GB10_MAP_SYSTEM_POLICY  the range is managed RAM: use the system-RAM
 *                           attribute policy (gb10_ram_memattr() here, or
 *                           nvidia_subr.c's _convert_caching_to_attr()),
 *                           never gb10_bar_memattr().
 *   GB10_MAP_BAR_POLICY     the range is a BAR: use gb10_bar_memattr().
 *   GB10_MAP_REFUSE         the range mixes RAM and non-RAM; no single
 *                           attribute is correct for both halves, so the
 *                           caller fails the mapping (NULL / EINVAL) with
 *                           one nv_printf.
 */
enum gb10_map_action {
	GB10_MAP_REFUSE		= -1,
	GB10_MAP_BAR_POLICY	= 0,
	GB10_MAP_SYSTEM_POLICY	= 1
};

/*
 * gb10_range_action - the choice table: map a range kind to the action its
 * mapping takes.  Pure, so tests/memattr_policy_test.sh can check the table
 * (RAM -> system policy; BAR -> BAR policy; mixed -> refuse) with no kernel.
 *
 * Time:  O(1).
 * Space: O(1).
 */
static __inline enum gb10_map_action
gb10_range_action(enum gb10_range kind)
{

	switch (kind) {
	case GB10_RANGE_RAM:
		return (GB10_MAP_SYSTEM_POLICY);
	case GB10_RANGE_BAR:
		return (GB10_MAP_BAR_POLICY);
	default:
		return (GB10_MAP_REFUSE);
	}
}

/*
 * gb10_mcfg_is_altra - do the 6-byte OEM ID and 8-byte OEM table ID of an
 * ACPI table header (neither NUL terminated) identify an Ampere Altra or
 * Altra Max system?  OEM ID exactly "Ampere" and an OEM table ID starting
 * with "Altra" ("Altra   ", "AltraMax", ...): the same rule the kernel-side
 * Altra quirk of Track #1908 uses.  Callers pass the oem_id and
 * oem_table_id fields of an ACPI_TABLE_HEADER (or NUL-terminated copies -
 * only the first 6 and 5 bytes are read).
 *
 * Time:  O(1) - at most 11 byte comparisons.
 * Space: O(1).
 */
static __inline int
gb10_mcfg_is_altra(const char oemid[6], const char oemtableid[8])
{
	static const char id[] = { 'A', 'm', 'p', 'e', 'r', 'e' };
	static const char pfx[] = { 'A', 'l', 't', 'r', 'a' };
	int i;

	for (i = 0; i < 6; i++)
		if (oemid[i] != id[i])
			return (0);
	for (i = 0; i < 5; i++)
		if (oemtableid[i] != pfx[i])
			return (0);
	return (1);
}

#endif /* !_GB10_MEMATTR_H_ */

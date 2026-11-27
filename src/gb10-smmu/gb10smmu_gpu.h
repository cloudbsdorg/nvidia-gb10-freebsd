/*
 * Copyright (c) 2026 Dave Cottlehuber
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The GPU the module of ours programs the SMMU of.
 *
 * The rules are in a header of their own, with no kernel dependency in
 * them, so that the unit test can build them outside the kernel: the
 * module finds the GPU in the device tree of the running machine and asks
 * these rules whether the device it found is the GPU.
 */
#ifndef _GB10SMMU_GPU_H_
#define _GB10SMMU_GPU_H_

#ifdef _KERNEL
#include <sys/types.h>
#else
#include <stdint.h>
#endif

/*
 * The PCI identity of the GB10 GPU: an NVIDIA GB10 (GB20B).  The vendor
 * ID is NVIDIA's, the device ID is the GB10's.
 */
#define	GB10SMMU_PCI_VENDOR	0x10de
#define	GB10SMMU_PCI_DEVICE	0x2e12

/*
 * gb10smmu_is_gb10 - is this PCI device the GPU the module programs?
 *
 * Nothing else is the GPU: the module programs the SMMU in front of the
 * GB10 and of no other device, and a machine without that device has no
 * SMMU of ours to program.
 */
static inline int
gb10smmu_is_gb10(uint32_t vendor, uint32_t device)
{
	return (vendor == GB10SMMU_PCI_VENDOR &&
	    device == GB10SMMU_PCI_DEVICE);
}

/*
 * gb10smmu_requester_id - the PCI requester ID of a device.
 *
 * The requester ID of a PCI device is the bus it is on, its slot and its
 * function, in the PCI's own layout: the bus in the upper eight bits, the
 * slot in the next five and the function in the last three.  It is the ID
 * the IORT maps onto the stream IDs of the SMMU.
 */
static inline uint32_t
gb10smmu_requester_id(uint32_t bus, uint32_t slot, uint32_t function)
{
	return ((bus << 8) | (slot << 3) | function);
}

#endif /* _GB10SMMU_GPU_H_ */

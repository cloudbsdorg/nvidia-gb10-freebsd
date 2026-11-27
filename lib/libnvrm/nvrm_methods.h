/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * nvrm_methods.h - pushbuffer and GPFIFO wire-format helpers, without state.
 * The field values are the MIT-licensed cl906f and clc86f definitions.
 */
#ifndef _NVRM_METHODS_H_
#define _NVRM_METHODS_H_

#include <stdint.h>
#include <string.h>

#define NVRM_MTHD_SET_OBJECT	0x00
#define NVRM_MTHD_NOP		0x08
#define NVRM_MTHD_SEM_ADDR_LO	0x5c
#define NVRM_MTHD_SEM_ADDR_HI	0x60
#define NVRM_MTHD_SEM_PAYLOAD_LO	0x64
#define NVRM_MTHD_SEM_PAYLOAD_HI	0x68
#define NVRM_MTHD_SEM_EXECUTE	0x6c
#define NVRM_MTHD_WFI		0x78

#define NVRM_MTHD_OP_INC	1U
#define NVRM_MTHD_OP_NON_INC	3U
#define NVRM_MTHD_OP_IMMD	4U
#define NVRM_MTHD_OP_ONE_INC	5U

#define NVRM_SEM_ACQUIRE	0U
#define NVRM_SEM_RELEASE	1U
#define NVRM_SEM_ACQ_CIRC_GEQ	3U
#define NVRM_SEM_WFI		(1U << 20)
#define NVRM_SEM_PAYLOAD_64	(1U << 24)

static inline uint32_t
nvrm_method_header(unsigned subch, unsigned method, unsigned count,
    unsigned op)
{
	return (((method >> 2) & 0xfffU) | ((subch & 7U) << 13) |
	    ((count & 0x1fffU) << 16) | ((op & 7U) << 29));
}

static inline uint32_t
nvrm_method_immd(unsigned subch, unsigned method, uint32_t data)
{
	return (nvrm_method_header(subch, method, data, NVRM_MTHD_OP_IMMD));
}

static inline unsigned
nvrm_method_address(uint32_t hdr)
{
	return ((hdr & 0xfffU) << 2);
}

static inline unsigned
nvrm_method_subch(uint32_t hdr)
{
	return ((hdr >> 13) & 7U);
}

static inline unsigned
nvrm_method_count(uint32_t hdr)
{
	return ((hdr >> 16) & 0x1fffU);
}

static inline unsigned
nvrm_method_op(uint32_t hdr)
{
	return ((hdr >> 29) & 7U);
}

/*
 * The GPFIFO entry of a pushbuffer fetch, in the wire format of the class
 * the board's channel has (and of every class that came before it):
 *
 *   the first word   the pushbuffer's address, its bits 31:2 in the field
 *                    GET (31:2) and the FETCH bit (0) below it;
 *   the second word  the length of the pushbuffer in dwords (LENGTH, 30:10),
 *                    the SYNC bit (31) and the address's bits 39:32
 *                    (GET_HI, 7:0).
 *
 * The GET_HI field is what NVIDIA's own client writes: the host HAL of
 * open-gpu-kernel-modules (kernel-open/nvidia-uvm/, the set_gpfifo_entry
 * function of the host HAL) puts NvU64_HI32(pushbuffer_va) there, and the
 * push library of the same tree
 * (src/common/unix/nvidia-push/src/nvidia-push.c, FillGpEntry) does the
 * same.  The same bits are named OPCODE in the class headers (clc36f.h,
 * cla06f.h, clc86f.h and clca6f.h), because a control entry - one that
 * sets the pushbuffer segment's extended base - spells its opcode there
 * (the set_gpfifo_pushbuffer_segment_base function of the same HAL); a
 * fetch entry carries the address's high byte there instead.
 *
 * The fetch takes the low 40 bits of the address: the upper bits are the
 * channel's pushbuffer segment's extended base, which the core sets with a
 * control entry of its own and does not change from submit to submit.  So
 * an address at or above 2^40 cannot be fetched, and the core refuses it.
 */
static inline uint32_t
nvrm_gp_entry0(uint64_t va)
{
	return ((uint32_t)(va & 0xfffffffcULL));
}

static inline uint32_t
nvrm_gp_entry1(uint64_t va, uint32_t dwords, int sync)
{
	return ((uint32_t)((va >> 32) & 0xffU) | (dwords << 10) |
	    (sync ? (1U << 31) : 0));
}

/* The address an entry names: its low 40 bits. */
static inline uint64_t
nvrm_gp_decode_va(uint32_t e0, uint32_t e1)
{
	return ((uint64_t)(e0 & 0xfffffffcU) |
	    ((uint64_t)(e1 & 0xffU) << 32));
}

static inline uint32_t
nvrm_gp_decode_dwords(uint32_t e1)
{
	return ((e1 >> 10) & 0x1fffffU);
}

/* The SYNC bit of an entry: the fetch waits for the work before it.  The
 * name the library has always used is the older one. */
static inline int
nvrm_gp_decode_no_prefetch(uint32_t e1)
{
	return ((e1 >> 31) != 0);
}

static inline int
nvrm_gp_decode_sync(uint32_t e1)
{
	return (nvrm_gp_decode_no_prefetch(e1));
}

/* A release segment holds eight dwords; the incrementing header and five
 * values use six. */
#define NVRM_RELEASE_SEG_DWORDS	8
#define NVRM_RELEASE_DWORDS	6
_Static_assert(NVRM_RELEASE_DWORDS <= NVRM_RELEASE_SEG_DWORDS,
    "the release segment must hold the release methods");

/*
 * Write the host release of a progress point.  SEM_ADDR_LO is the field
 * OFFSET in bits 31:2 of the word: the address value va >> 2 placed at bit 2,
 * which is the low word of the address with its two low bits clear.  Returns
 * the number of dwords the segment uses.
 */
static inline unsigned
nvrm_release_segment(uint32_t seg[NVRM_RELEASE_SEG_DWORDS], uint64_t sem_va,
    uint64_t point)
{
	memset(seg, 0, NVRM_RELEASE_SEG_DWORDS * sizeof(*seg));
	seg[0] = nvrm_method_header(0, NVRM_MTHD_SEM_ADDR_LO, 5,
	    NVRM_MTHD_OP_INC);
	seg[1] = (uint32_t)sem_va & 0xfffffffcU;
	seg[2] = (uint32_t)((sem_va >> 32) & 0x1ffffffU);
	seg[3] = (uint32_t)point;
	seg[4] = (uint32_t)(point >> 32);
	seg[5] = NVRM_SEM_RELEASE | NVRM_SEM_WFI | NVRM_SEM_PAYLOAD_64;
	return (NVRM_RELEASE_DWORDS);
}

#endif /* _NVRM_METHODS_H_ */

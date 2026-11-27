/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * <device_atomic_functions.hpp> - cuda-native SDK (Track #2380, stage C1.1
 * #2425; the atomic family in #2463).  The device atomic family: the
 * definitions.  The declarations are in device_atomic_functions.h, which
 * clang's CUDA runtime wrapper includes by name right before this file.
 *
 * Every atomic exists in three scopes: the device scope (the name without
 * a suffix), the block scope (_block) and the system scope (_system), as
 * the CUDA C++ Programming Guide defines them.
 *
 * The bodies are clang's own NVVM atomic builtins (__nvvm_atom_*), which
 * the NVPTX backend lowers to the atom instructions of the PTX ISA.  No
 * function of the libdevice is called: our libdevice holds none, so a
 * kernel that needed one would link to nothing.
 *
 * Three of the atomics have no instruction of their own in the PTX ISA and
 * are built from the ones there are, as CUDA builds them:
 *   - the subtraction is the addition of the negated value;
 *   - the exchange of a float is the exchange of its bit pattern;
 *   - the minimum and the maximum of a float and of a double are a
 *     compare-and-swap loop.
 */
#ifndef CUDA_NATIVE_DEVICE_ATOMIC_FUNCTIONS_HPP_
#define CUDA_NATIVE_DEVICE_ATOMIC_FUNCTIONS_HPP_

#include "device_atomic_functions.h"

#if defined(__cplusplus) && defined(__CUDACC__)

/*
 * The NVVM atomic builtins of one operation (add, exch, min, max, inc, dec,
 * cas, and, or, xor) and one type (i, ui, ll, ull, us, f, d), in the three
 * scopes: the device scope (CN_ATOM_GEN), the block scope (CN_ATOM_CTA) and
 * the system scope (CN_ATOM_SYS).
 */
#define CN_ATOM_GEN(OP, TY) __nvvm_atom_##OP##_gen_##TY
#define CN_ATOM_CTA(OP, TY) __nvvm_atom_cta_##OP##_gen_##TY
#define CN_ATOM_SYS(OP, TY) __nvvm_atom_sys_##OP##_gen_##TY

/*
 * The bit pattern of a float and of a double.  __builtin_memcpy keeps the
 * copy in the compiler: the libdevice functions that do this
 * (__nv_float_as_int and its kin) are not in our libdevice.
 */
static __inline__ __device__ int
CN_FLOAT_BITS(float value)
{
	int bits;

	__builtin_memcpy(&bits, &value, sizeof(bits));
	return bits;
}

static __inline__ __device__ float
CN_BITS_FLOAT(int bits)
{
	float value;

	__builtin_memcpy(&value, &bits, sizeof(value));
	return value;
}

static __inline__ __device__ long long
CN_DOUBLE_BITS(double value)
{
	long long bits;

	__builtin_memcpy(&bits, &value, sizeof(bits));
	return bits;
}

static __inline__ __device__ double
CN_BITS_DOUBLE(long long bits)
{
	double value;

	__builtin_memcpy(&value, &bits, sizeof(value));
	return value;
}

/*
 * CN_DEFINE(NAME, TYPE, BTYPE, OP, TY): the three scope variants of one
 * atomic.  BTYPE is the type of the pointer the builtin takes and TY the
 * suffix of its name: the builtins of the 32 bit and of the 64 bit integers
 * take a signed pointer whatever the type of the atomic is, because they
 * work on the bits.
 */
#define CN_DEFINE(NAME, TYPE, BTYPE, OP, TY)				\
	static __inline__ __device__ TYPE				\
	NAME(TYPE *address, TYPE val)					\
	{								\
		return CN_ATOM_GEN(OP, TY)((BTYPE *)address,		\
		    (BTYPE)val);						\
	}								\
	static __inline__ __device__ TYPE				\
	NAME##_block(TYPE *address, TYPE val)				\
	{								\
		return CN_ATOM_CTA(OP, TY)((BTYPE *)address,		\
		    (BTYPE)val);						\
	}								\
	static __inline__ __device__ TYPE				\
	NAME##_system(TYPE *address, TYPE val)			\
	{								\
		return CN_ATOM_SYS(OP, TY)((BTYPE *)address,		\
		    (BTYPE)val);						\
	}

/*
 * CN_DEFINE_SUB(NAME, TYPE, BTYPE, OP, TY, NEG): the subtraction, which is
 * the addition of the negated value, as CUDA implements it.  NEG is the
 * negation of the value; it is written in the unsigned type, so that the
 * negation of the smallest int is not an overflow.
 */
#define CN_DEFINE_SUB(NAME, TYPE, BTYPE, OP, TY, NEG)			\
	static __inline__ __device__ TYPE				\
	NAME(TYPE *address, TYPE val)					\
	{								\
		return CN_ATOM_GEN(OP, TY)((BTYPE *)address,		\
		    (BTYPE)(NEG));						\
	}								\
	static __inline__ __device__ TYPE				\
	NAME##_block(TYPE *address, TYPE val)				\
	{								\
		return CN_ATOM_CTA(OP, TY)((BTYPE *)address,		\
		    (BTYPE)(NEG));						\
	}								\
	static __inline__ __device__ TYPE				\
	NAME##_system(TYPE *address, TYPE val)			\
	{								\
		return CN_ATOM_SYS(OP, TY)((BTYPE *)address,		\
		    (BTYPE)(NEG));						\
	}

/*
 * CN_DEFINE_CAS(NAME, TYPE, BTYPE, OP, TY): the compare and swap, which
 * takes the value to compare and the new value.
 */
#define CN_DEFINE_CAS(NAME, TYPE, BTYPE, OP, TY)			\
	static __inline__ __device__ TYPE				\
	NAME(TYPE *address, TYPE compare, TYPE val)			\
	{								\
		return CN_ATOM_GEN(OP, TY)((BTYPE *)address,		\
		    (BTYPE)compare, (BTYPE)val);				\
	}								\
	static __inline__ __device__ TYPE				\
	NAME##_block(TYPE *address, TYPE compare, TYPE val)		\
	{								\
		return CN_ATOM_CTA(OP, TY)((BTYPE *)address,		\
		    (BTYPE)compare, (BTYPE)val);				\
	}								\
	static __inline__ __device__ TYPE				\
	NAME##_system(TYPE *address, TYPE compare, TYPE val)		\
	{								\
		return CN_ATOM_SYS(OP, TY)((BTYPE *)address,		\
		    (BTYPE)compare, (BTYPE)val);				\
	}

/*
 * CN_DEFINE_EXCH_FLOAT(NAME, SCOPE): the exchange of a float, which is the
 * exchange of its bit pattern: the PTX ISA has no float exchange.
 */
#define CN_DEFINE_EXCH_FLOAT(NAME, SCOPE)				\
	static __inline__ __device__ float				\
	NAME(float *address, float val)				\
	{								\
		int old = SCOPE(xchg, i)((int *)address,	\
		    CN_FLOAT_BITS(val));				\
									\
		return CN_BITS_FLOAT(old);				\
	}

/*
 * CN_DEFINE_MINMAX_FLOAT(NAME, SCOPE, CMP): the minimum or the maximum of
 * a float, which is a compare-and-swap loop: the PTX ISA has no float
 * minimum and no float maximum.  CMP tells which of the two it is.
 */
#define CN_DEFINE_MINMAX_FLOAT(NAME, SCOPE, CMP)			\
	static __inline__ __device__ float				\
	NAME(float *address, float val)				\
	{								\
		int old = CN_FLOAT_BITS(*address);			\
		int assumed;						\
									\
		do {							\
			assumed = old;					\
			int wanted = (CMP)				\
			    ? CN_FLOAT_BITS(val) : assumed;		\
			old = SCOPE(cas, i)((int *)address,	\
			    assumed, wanted);				\
		} while (assumed != old);				\
									\
		return CN_BITS_FLOAT(old);				\
	}

/*
 * CN_DEFINE_MINMAX_DOUBLE(NAME, SCOPE, CMP): the minimum or the maximum of
 * a double, which is a compare-and-swap loop as well.
 */
#define CN_DEFINE_MINMAX_DOUBLE(NAME, SCOPE, CMP)			\
	static __inline__ __device__ double				\
	NAME(double *address, double val)				\
	{								\
		long long old = CN_DOUBLE_BITS(*address);		\
		long long assumed;					\
									\
		do {							\
			assumed = old;					\
			long long wanted = (CMP)				\
			    ? CN_DOUBLE_BITS(val) : assumed;		\
			old = SCOPE(cas, ll)((long long *)address, \
			    assumed, wanted);				\
		} while (assumed != old);				\
									\
		return CN_BITS_DOUBLE(old);				\
	}

/* The addition, in every type the CUDA C++ Programming Guide gives it. */
CN_DEFINE(atomicAdd, int, int, add, i);
CN_DEFINE(atomicAdd, unsigned int, int, add, i);
CN_DEFINE(atomicAdd, unsigned long long, long long, add, ll);
CN_DEFINE(atomicAdd, float, float, add, f);
CN_DEFINE(atomicAdd, double, double, add, d);

/* The subtraction, in the same types. */
CN_DEFINE_SUB(atomicSub, int, int, add, i, 0u - (unsigned int)val);
CN_DEFINE_SUB(atomicSub, unsigned int, int, add, i, 0u - val);
CN_DEFINE_SUB(atomicSub, unsigned long long, long long, add, ll,
    0ull - (unsigned long long)val);
CN_DEFINE_SUB(atomicSub, float, float, add, f, -val);
CN_DEFINE_SUB(atomicSub, double, double, add, d, -val);

/* The exchange, in every type the guide gives it. */
CN_DEFINE(atomicExch, int, int, xchg, i);
CN_DEFINE(atomicExch, unsigned int, int, xchg, i);
CN_DEFINE(atomicExch, unsigned long long, long long, xchg, ll);
CN_DEFINE_EXCH_FLOAT(atomicExch, CN_ATOM_GEN);
CN_DEFINE_EXCH_FLOAT(atomicExch_block, CN_ATOM_CTA);
CN_DEFINE_EXCH_FLOAT(atomicExch_system, CN_ATOM_SYS);

/* The minimum, in every type the guide gives it. */
CN_DEFINE(atomicMin, int, int, min, i);
CN_DEFINE(atomicMin, unsigned int, unsigned int, min, ui);
CN_DEFINE(atomicMin, long long, long long, min, ll);
CN_DEFINE(atomicMin, unsigned long long, unsigned long long, min, ull);
CN_DEFINE_MINMAX_FLOAT(atomicMin, CN_ATOM_GEN, val < CN_BITS_FLOAT(assumed));
CN_DEFINE_MINMAX_FLOAT(atomicMin_block, CN_ATOM_CTA, val < CN_BITS_FLOAT(assumed));
CN_DEFINE_MINMAX_FLOAT(atomicMin_system, CN_ATOM_SYS, val < CN_BITS_FLOAT(assumed));
CN_DEFINE_MINMAX_DOUBLE(atomicMin, CN_ATOM_GEN, val < CN_BITS_DOUBLE(assumed));
CN_DEFINE_MINMAX_DOUBLE(atomicMin_block, CN_ATOM_CTA, val < CN_BITS_DOUBLE(assumed));
CN_DEFINE_MINMAX_DOUBLE(atomicMin_system, CN_ATOM_SYS, val < CN_BITS_DOUBLE(assumed));

/* The maximum, in every type the guide gives it. */
CN_DEFINE(atomicMax, int, int, max, i);
CN_DEFINE(atomicMax, unsigned int, unsigned int, max, ui);
CN_DEFINE(atomicMax, long long, long long, max, ll);
CN_DEFINE(atomicMax, unsigned long long, unsigned long long, max, ull);
CN_DEFINE_MINMAX_FLOAT(atomicMax, CN_ATOM_GEN, val > CN_BITS_FLOAT(assumed));
CN_DEFINE_MINMAX_FLOAT(atomicMax_block, CN_ATOM_CTA, val > CN_BITS_FLOAT(assumed));
CN_DEFINE_MINMAX_FLOAT(atomicMax_system, CN_ATOM_SYS, val > CN_BITS_FLOAT(assumed));
CN_DEFINE_MINMAX_DOUBLE(atomicMax, CN_ATOM_GEN, val > CN_BITS_DOUBLE(assumed));
CN_DEFINE_MINMAX_DOUBLE(atomicMax_block, CN_ATOM_CTA, val > CN_BITS_DOUBLE(assumed));
CN_DEFINE_MINMAX_DOUBLE(atomicMax_system, CN_ATOM_SYS, val > CN_BITS_DOUBLE(assumed));

/* The increment and the decrement, of an unsigned int. */
CN_DEFINE(atomicInc, unsigned int, unsigned int, inc, ui);
CN_DEFINE(atomicDec, unsigned int, unsigned int, dec, ui);

/* The compare and swap, in every type the guide gives it. */
CN_DEFINE_CAS(atomicCAS, int, int, cas, i);
CN_DEFINE_CAS(atomicCAS, unsigned int, int, cas, i);
CN_DEFINE_CAS(atomicCAS, unsigned long long, long long, cas, ll);
CN_DEFINE_CAS(atomicCAS, unsigned short, unsigned short, cas, us);

/* The bitwise operations, in every type the guide gives them. */
CN_DEFINE(atomicAnd, int, int, and, i);
CN_DEFINE(atomicAnd, unsigned int, int, and, i);
CN_DEFINE(atomicAnd, unsigned long long, long long, and, ll);
CN_DEFINE(atomicOr, int, int, or, i);
CN_DEFINE(atomicOr, unsigned int, int, or, i);
CN_DEFINE(atomicOr, unsigned long long, long long, or, ll);
CN_DEFINE(atomicXor, int, int, xor, i);
CN_DEFINE(atomicXor, unsigned int, int, xor, i);
CN_DEFINE(atomicXor, unsigned long long, long long, xor, ll);

#undef CN_DEFINE
#undef CN_DEFINE_CAS
#undef CN_DEFINE_EXCH_FLOAT
#undef CN_DEFINE_MINMAX_DOUBLE
#undef CN_DEFINE_MINMAX_FLOAT
#undef CN_DEFINE_SUB
#undef CN_ATOM_CTA
#undef CN_ATOM_GEN
#undef CN_ATOM_SYS

#endif /* __cplusplus && __CUDACC__ */

#endif /* CUDA_NATIVE_DEVICE_ATOMIC_FUNCTIONS_HPP_ */

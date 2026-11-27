/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * <device_atomic_functions.h> - cuda-native SDK (Track #2380, stage C1.1
 * #2425; the atomic family in #2463).  The declarations of the device
 * atomic family.  clang's CUDA runtime wrapper includes this file by name,
 * and the definitions follow in device_atomic_functions.hpp.
 *
 * Every atomic exists in three scopes: the device scope (the name without
 * a suffix), the block scope (_block) and the system scope (_system), as
 * the CUDA C++ Programming Guide defines them.
 *
 * The declarations are here and the definitions are in the .hpp, so a
 * header of ours that needs an atomic can include this file alone.  Every
 * declaration has a definition: the test compiles a kernel that calls each
 * of them and reads the PTX it produces.
 */
#ifndef CUDA_NATIVE_DEVICE_ATOMIC_FUNCTIONS_H_
#define CUDA_NATIVE_DEVICE_ATOMIC_FUNCTIONS_H_

#if defined(__cplusplus) && defined(__CUDACC__)

/*
 * CN_DECLARE(NAME, TYPE): the three scope variants of one atomic.
 */
#define CN_DECLARE(NAME, TYPE)						\
	static __inline__ __device__ TYPE				\
	NAME(TYPE *address, TYPE val);					\
	static __inline__ __device__ TYPE				\
	NAME##_block(TYPE *address, TYPE val);				\
	static __inline__ __device__ TYPE				\
	NAME##_system(TYPE *address, TYPE val)

/*
 * CN_DECLARE_CAS(NAME, TYPE): the three scope variants of one compare and
 * swap, which takes the value to compare and the new value.
 */
#define CN_DECLARE_CAS(NAME, TYPE)					\
	static __inline__ __device__ TYPE				\
	NAME(TYPE *address, TYPE compare, TYPE val);			\
	static __inline__ __device__ TYPE				\
	NAME##_block(TYPE *address, TYPE compare, TYPE val);		\
	static __inline__ __device__ TYPE				\
	NAME##_system(TYPE *address, TYPE compare, TYPE val)

/* The addition, in every type the CUDA C++ Programming Guide gives it. */
CN_DECLARE(atomicAdd, int);
CN_DECLARE(atomicAdd, unsigned int);
CN_DECLARE(atomicAdd, unsigned long long);
CN_DECLARE(atomicAdd, float);
CN_DECLARE(atomicAdd, double);

/* The subtraction, in the same types. */
CN_DECLARE(atomicSub, int);
CN_DECLARE(atomicSub, unsigned int);
CN_DECLARE(atomicSub, unsigned long long);
CN_DECLARE(atomicSub, float);
CN_DECLARE(atomicSub, double);

/* The exchange, in every type the guide gives it. */
CN_DECLARE(atomicExch, int);
CN_DECLARE(atomicExch, unsigned int);
CN_DECLARE(atomicExch, unsigned long long);
CN_DECLARE(atomicExch, float);

/* The minimum and the maximum, in every type the guide gives them. */
CN_DECLARE(atomicMin, int);
CN_DECLARE(atomicMin, unsigned int);
CN_DECLARE(atomicMin, long long);
CN_DECLARE(atomicMin, unsigned long long);
CN_DECLARE(atomicMin, float);
CN_DECLARE(atomicMin, double);
CN_DECLARE(atomicMax, int);
CN_DECLARE(atomicMax, unsigned int);
CN_DECLARE(atomicMax, long long);
CN_DECLARE(atomicMax, unsigned long long);
CN_DECLARE(atomicMax, float);
CN_DECLARE(atomicMax, double);

/* The increment and the decrement, of an unsigned int. */
CN_DECLARE(atomicInc, unsigned int);
CN_DECLARE(atomicDec, unsigned int);

/* The compare and swap, in every type the guide gives it. */
CN_DECLARE_CAS(atomicCAS, int);
CN_DECLARE_CAS(atomicCAS, unsigned int);
CN_DECLARE_CAS(atomicCAS, unsigned long long);
CN_DECLARE_CAS(atomicCAS, unsigned short);

/* The bitwise operations, in every type the guide gives them. */
CN_DECLARE(atomicAnd, int);
CN_DECLARE(atomicAnd, unsigned int);
CN_DECLARE(atomicAnd, unsigned long long);
CN_DECLARE(atomicOr, int);
CN_DECLARE(atomicOr, unsigned int);
CN_DECLARE(atomicOr, unsigned long long);
CN_DECLARE(atomicXor, int);
CN_DECLARE(atomicXor, unsigned int);
CN_DECLARE(atomicXor, unsigned long long);

#undef CN_DECLARE
#undef CN_DECLARE_CAS

#endif /* __cplusplus && __CUDACC__ */

#endif /* CUDA_NATIVE_DEVICE_ATOMIC_FUNCTIONS_H_ */

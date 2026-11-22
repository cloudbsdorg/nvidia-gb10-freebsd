/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * <vector_functions.h> - cuda-native SDK (Track #2380).  The make_<type>
 * constructors for every vector type in <vector_types.h>.
 */
#ifndef CUDA_NATIVE_VECTOR_FUNCTIONS_H_
#define CUDA_NATIVE_VECTOR_FUNCTIONS_H_

#include "host_defines.h"
#include "vector_types.h"

static __inline__ __host__ __device__ char1
make_char1(signed char x)
{
	char1 v = {x};

	return v;
}

static __inline__ __host__ __device__ char2
make_char2(signed char x, signed char y)
{
	char2 v = {x, y};

	return v;
}

static __inline__ __host__ __device__ char3
make_char3(signed char x, signed char y, signed char z)
{
	char3 v = {x, y, z};

	return v;
}

static __inline__ __host__ __device__ char4
make_char4(signed char x, signed char y, signed char z, signed char w)
{
	char4 v = {x, y, z, w};

	return v;
}

static __inline__ __host__ __device__ uchar1
make_uchar1(unsigned char x)
{
	uchar1 v = {x};

	return v;
}

static __inline__ __host__ __device__ uchar2
make_uchar2(unsigned char x, unsigned char y)
{
	uchar2 v = {x, y};

	return v;
}

static __inline__ __host__ __device__ uchar3
make_uchar3(unsigned char x, unsigned char y, unsigned char z)
{
	uchar3 v = {x, y, z};

	return v;
}

static __inline__ __host__ __device__ uchar4
make_uchar4(unsigned char x, unsigned char y, unsigned char z, unsigned char w)
{
	uchar4 v = {x, y, z, w};

	return v;
}

static __inline__ __host__ __device__ short1
make_short1(short x)
{
	short1 v = {x};

	return v;
}

static __inline__ __host__ __device__ short2
make_short2(short x, short y)
{
	short2 v = {x, y};

	return v;
}

static __inline__ __host__ __device__ short3
make_short3(short x, short y, short z)
{
	short3 v = {x, y, z};

	return v;
}

static __inline__ __host__ __device__ short4
make_short4(short x, short y, short z, short w)
{
	short4 v = {x, y, z, w};

	return v;
}

static __inline__ __host__ __device__ ushort1
make_ushort1(unsigned short x)
{
	ushort1 v = {x};

	return v;
}

static __inline__ __host__ __device__ ushort2
make_ushort2(unsigned short x, unsigned short y)
{
	ushort2 v = {x, y};

	return v;
}

static __inline__ __host__ __device__ ushort3
make_ushort3(unsigned short x, unsigned short y, unsigned short z)
{
	ushort3 v = {x, y, z};

	return v;
}

static __inline__ __host__ __device__ ushort4
make_ushort4(unsigned short x, unsigned short y, unsigned short z, unsigned short w)
{
	ushort4 v = {x, y, z, w};

	return v;
}

static __inline__ __host__ __device__ int1
make_int1(int x)
{
	int1 v = {x};

	return v;
}

static __inline__ __host__ __device__ int2
make_int2(int x, int y)
{
	int2 v = {x, y};

	return v;
}

static __inline__ __host__ __device__ int3
make_int3(int x, int y, int z)
{
	int3 v = {x, y, z};

	return v;
}

static __inline__ __host__ __device__ int4
make_int4(int x, int y, int z, int w)
{
	int4 v = {x, y, z, w};

	return v;
}

static __inline__ __host__ __device__ uint1
make_uint1(unsigned int x)
{
	uint1 v = {x};

	return v;
}

static __inline__ __host__ __device__ uint2
make_uint2(unsigned int x, unsigned int y)
{
	uint2 v = {x, y};

	return v;
}

static __inline__ __host__ __device__ uint3
make_uint3(unsigned int x, unsigned int y, unsigned int z)
{
	uint3 v = {x, y, z};

	return v;
}

static __inline__ __host__ __device__ uint4
make_uint4(unsigned int x, unsigned int y, unsigned int z, unsigned int w)
{
	uint4 v = {x, y, z, w};

	return v;
}

static __inline__ __host__ __device__ long1
make_long1(long x)
{
	long1 v = {x};

	return v;
}

static __inline__ __host__ __device__ long2
make_long2(long x, long y)
{
	long2 v = {x, y};

	return v;
}

static __inline__ __host__ __device__ long3
make_long3(long x, long y, long z)
{
	long3 v = {x, y, z};

	return v;
}

static __inline__ __host__ __device__ long4
make_long4(long x, long y, long z, long w)
{
	long4 v = {x, y, z, w};

	return v;
}

static __inline__ __host__ __device__ ulong1
make_ulong1(unsigned long x)
{
	ulong1 v = {x};

	return v;
}

static __inline__ __host__ __device__ ulong2
make_ulong2(unsigned long x, unsigned long y)
{
	ulong2 v = {x, y};

	return v;
}

static __inline__ __host__ __device__ ulong3
make_ulong3(unsigned long x, unsigned long y, unsigned long z)
{
	ulong3 v = {x, y, z};

	return v;
}

static __inline__ __host__ __device__ ulong4
make_ulong4(unsigned long x, unsigned long y, unsigned long z, unsigned long w)
{
	ulong4 v = {x, y, z, w};

	return v;
}

static __inline__ __host__ __device__ longlong1
make_longlong1(long long x)
{
	longlong1 v = {x};

	return v;
}

static __inline__ __host__ __device__ longlong2
make_longlong2(long long x, long long y)
{
	longlong2 v = {x, y};

	return v;
}

static __inline__ __host__ __device__ longlong3
make_longlong3(long long x, long long y, long long z)
{
	longlong3 v = {x, y, z};

	return v;
}

static __inline__ __host__ __device__ longlong4
make_longlong4(long long x, long long y, long long z, long long w)
{
	longlong4 v = {x, y, z, w};

	return v;
}

static __inline__ __host__ __device__ ulonglong1
make_ulonglong1(unsigned long long x)
{
	ulonglong1 v = {x};

	return v;
}

static __inline__ __host__ __device__ ulonglong2
make_ulonglong2(unsigned long long x, unsigned long long y)
{
	ulonglong2 v = {x, y};

	return v;
}

static __inline__ __host__ __device__ ulonglong3
make_ulonglong3(unsigned long long x, unsigned long long y, unsigned long long z)
{
	ulonglong3 v = {x, y, z};

	return v;
}

static __inline__ __host__ __device__ ulonglong4
make_ulonglong4(unsigned long long x, unsigned long long y, unsigned long long z, unsigned long long w)
{
	ulonglong4 v = {x, y, z, w};

	return v;
}

static __inline__ __host__ __device__ float1
make_float1(float x)
{
	float1 v = {x};

	return v;
}

static __inline__ __host__ __device__ float2
make_float2(float x, float y)
{
	float2 v = {x, y};

	return v;
}

static __inline__ __host__ __device__ float3
make_float3(float x, float y, float z)
{
	float3 v = {x, y, z};

	return v;
}

static __inline__ __host__ __device__ float4
make_float4(float x, float y, float z, float w)
{
	float4 v = {x, y, z, w};

	return v;
}

static __inline__ __host__ __device__ double1
make_double1(double x)
{
	double1 v = {x};

	return v;
}

static __inline__ __host__ __device__ double2
make_double2(double x, double y)
{
	double2 v = {x, y};

	return v;
}

static __inline__ __host__ __device__ double3
make_double3(double x, double y, double z)
{
	double3 v = {x, y, z};

	return v;
}

static __inline__ __host__ __device__ double4
make_double4(double x, double y, double z, double w)
{
	double4 v = {x, y, z, w};

	return v;
}

#endif /* CUDA_NATIVE_VECTOR_FUNCTIONS_H_ */

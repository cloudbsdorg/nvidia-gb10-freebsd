/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * <vector_types.h> - cuda-native SDK (Track #2380).  The launch geometry
 * types uint3 and dim3 (each unspecified dimension of a dim3 is 1) and the
 * vector types char1 to double4.
 */
#ifndef CUDA_NATIVE_VECTOR_TYPES_H_
#define CUDA_NATIVE_VECTOR_TYPES_H_

#include "host_defines.h"

struct uint3 {
	unsigned int x, y, z;
};
typedef struct uint3 uint3;

/*
 * The vector types of the CUDA C++ Programming Guide.  Three-element types
 * keep the alignment of one element; the others align to their size, at
 * most 16 bytes.
 */
struct __align__(1) char1 {
	signed char x;
};
typedef struct char1 char1;

struct __align__(2) char2 {
	signed char x, y;
};
typedef struct char2 char2;

struct __align__(1) char3 {
	signed char x, y, z;
};
typedef struct char3 char3;

struct __align__(4) char4 {
	signed char x, y, z, w;
};
typedef struct char4 char4;

struct __align__(1) uchar1 {
	unsigned char x;
};
typedef struct uchar1 uchar1;

struct __align__(2) uchar2 {
	unsigned char x, y;
};
typedef struct uchar2 uchar2;

struct __align__(1) uchar3 {
	unsigned char x, y, z;
};
typedef struct uchar3 uchar3;

struct __align__(4) uchar4 {
	unsigned char x, y, z, w;
};
typedef struct uchar4 uchar4;

struct __align__(2) short1 {
	short x;
};
typedef struct short1 short1;

struct __align__(4) short2 {
	short x, y;
};
typedef struct short2 short2;

struct __align__(2) short3 {
	short x, y, z;
};
typedef struct short3 short3;

struct __align__(8) short4 {
	short x, y, z, w;
};
typedef struct short4 short4;

struct __align__(2) ushort1 {
	unsigned short x;
};
typedef struct ushort1 ushort1;

struct __align__(4) ushort2 {
	unsigned short x, y;
};
typedef struct ushort2 ushort2;

struct __align__(2) ushort3 {
	unsigned short x, y, z;
};
typedef struct ushort3 ushort3;

struct __align__(8) ushort4 {
	unsigned short x, y, z, w;
};
typedef struct ushort4 ushort4;

struct __align__(4) int1 {
	int x;
};
typedef struct int1 int1;

struct __align__(8) int2 {
	int x, y;
};
typedef struct int2 int2;

struct __align__(4) int3 {
	int x, y, z;
};
typedef struct int3 int3;

struct __align__(16) int4 {
	int x, y, z, w;
};
typedef struct int4 int4;

struct __align__(4) uint1 {
	unsigned int x;
};
typedef struct uint1 uint1;

struct __align__(8) uint2 {
	unsigned int x, y;
};
typedef struct uint2 uint2;

struct __align__(16) uint4 {
	unsigned int x, y, z, w;
};
typedef struct uint4 uint4;

struct __align__(8) long1 {
	long x;
};
typedef struct long1 long1;

struct __align__(16) long2 {
	long x, y;
};
typedef struct long2 long2;

struct __align__(8) long3 {
	long x, y, z;
};
typedef struct long3 long3;

struct __align__(16) long4 {
	long x, y, z, w;
};
typedef struct long4 long4;

struct __align__(8) ulong1 {
	unsigned long x;
};
typedef struct ulong1 ulong1;

struct __align__(16) ulong2 {
	unsigned long x, y;
};
typedef struct ulong2 ulong2;

struct __align__(8) ulong3 {
	unsigned long x, y, z;
};
typedef struct ulong3 ulong3;

struct __align__(16) ulong4 {
	unsigned long x, y, z, w;
};
typedef struct ulong4 ulong4;

struct __align__(8) longlong1 {
	long long x;
};
typedef struct longlong1 longlong1;

struct __align__(16) longlong2 {
	long long x, y;
};
typedef struct longlong2 longlong2;

struct __align__(8) longlong3 {
	long long x, y, z;
};
typedef struct longlong3 longlong3;

struct __align__(16) longlong4 {
	long long x, y, z, w;
};
typedef struct longlong4 longlong4;

struct __align__(8) ulonglong1 {
	unsigned long long x;
};
typedef struct ulonglong1 ulonglong1;

struct __align__(16) ulonglong2 {
	unsigned long long x, y;
};
typedef struct ulonglong2 ulonglong2;

struct __align__(8) ulonglong3 {
	unsigned long long x, y, z;
};
typedef struct ulonglong3 ulonglong3;

struct __align__(16) ulonglong4 {
	unsigned long long x, y, z, w;
};
typedef struct ulonglong4 ulonglong4;

struct __align__(4) float1 {
	float x;
};
typedef struct float1 float1;

struct __align__(8) float2 {
	float x, y;
};
typedef struct float2 float2;

struct __align__(4) float3 {
	float x, y, z;
};
typedef struct float3 float3;

struct __align__(16) float4 {
	float x, y, z, w;
};
typedef struct float4 float4;

struct __align__(8) double1 {
	double x;
};
typedef struct double1 double1;

struct __align__(16) double2 {
	double x, y;
};
typedef struct double2 double2;

struct __align__(8) double3 {
	double x, y, z;
};
typedef struct double3 double3;

struct __align__(16) double4 {
	double x, y, z, w;
};
typedef struct double4 double4;

struct dim3 {
	unsigned int x, y, z;
#if defined(__cplusplus)
	__host__ __device__ constexpr dim3(unsigned int vx = 1,
	    unsigned int vy = 1, unsigned int vz = 1)
	    : x(vx), y(vy), z(vz) {}
	__host__ __device__ constexpr dim3(uint3 v) : x(v.x), y(v.y), z(v.z) {}
	__host__ __device__ constexpr operator uint3() const
	{
		return uint3{x, y, z};
	}
#endif
};
typedef struct dim3 dim3;

#endif /* CUDA_NATIVE_VECTOR_TYPES_H_ */

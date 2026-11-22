// Copyright (c) 2026 REVYTECH, Inc.
// SPDX-License-Identifier: BSD-2-Clause
//
// vector_types_check.cu - cuda-native toolchain test input (Track #2380):
// the sizes and alignments of the vector types (the CUDA C++ Programming
// Guide table: three-element types keep the element alignment, the others
// align to their size up to 16 bytes), dim3 defaults, and make_* on both
// sides.  Every check is a static_assert, so a wrong header fails the compile.

#define CHECK(t, size, align) \
	static_assert(sizeof(t) == (size), #t " size"); \
	static_assert(alignof(t) == (align), #t " alignment")

CHECK(char1, 1, 1);
CHECK(char2, 2, 2);
CHECK(char3, 3, 1);
CHECK(char4, 4, 4);
CHECK(uchar4, 4, 4);
CHECK(short2, 4, 4);
CHECK(short3, 6, 2);
CHECK(ushort4, 8, 8);
CHECK(int1, 4, 4);
CHECK(int2, 8, 8);
CHECK(int3, 12, 4);
CHECK(int4, 16, 16);
CHECK(uint2, 8, 8);
CHECK(uint3, 12, 4);
CHECK(uint4, 16, 16);
CHECK(long2, 16, 16);
CHECK(longlong3, 24, 8);
CHECK(ulonglong4, 32, 16);
CHECK(float2, 8, 8);
CHECK(float3, 12, 4);
CHECK(float4, 16, 16);
CHECK(double1, 8, 8);
CHECK(double2, 16, 16);
CHECK(double3, 24, 8);
CHECK(double4, 32, 16);
CHECK(dim3, 12, 4);

static_assert(dim3().x == 1 && dim3().y == 1 && dim3().z == 1, "dim3 defaults");
static_assert(dim3(7).x == 7 && dim3(7).y == 1, "dim3 partial");

__host__ __device__ float sum4(float a)
{
	float4 f = make_float4(a, 1.0f, 2.0f, 3.0f);
	int2 i = make_int2(4, 5);
	uchar3 c = make_uchar3(6, 7, 8);
	double2 d = make_double2(9.0, 10.0);

	return f.x + f.y + f.z + f.w + (float)(i.x + i.y) +
	    (float)(c.x + c.y + c.z) + (float)(d.x + d.y);
}

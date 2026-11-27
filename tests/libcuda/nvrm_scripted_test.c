/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * nvrm_scripted_test.c - the native provider of libcuda against the
 * scripted kernel of libnvrm.  No driver, no hardware: the scripted kernel
 * (tests/libnvrm/scripted_rm.h and scripted_mem.h) answers the escapes of
 * the resource manager, and the provider of libcuda talks to libnvrm the
 * way it talks to the driver.
 *
 * The provider is bound to the copy of libnvrm that is compiled into this
 * program, so the scripted kernel is the one the provider reaches.
 */
#include <sys/param.h>
#include <sys/capsicum.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/syscall.h>

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <nvtypes.h>
#include <nvstatus.h>
#include <nvmisc.h>
#include <nvos.h>
#include <nv-ioctl.h>
#include <nv_escape.h>
#include <nv-unix-nvos-params-wrappers.h>
#include <class/cl0000.h>
#include <class/cl003e.h>
#include <class/cl0040.h>
#include <class/cl0070.h>
#include <class/cl0071.h>
#include <class/cl0080.h>
#include <class/cl2080.h>
#include <class/cl50a0.h>
#include <class/cl90f1.h>
#include <ctrl/ctrl0000/ctrl0000client.h>
#include <ctrl/ctrl0000/ctrl0000gpu.h>
#include <ctrl/ctrl0000/ctrl0000unix.h>
#include <ctrl/ctrl0041.h>
#include <ctrl/ctrl0080/ctrl0080gpu.h>
#include <ctrl/ctrl2080/ctrl2080bios.h>
#include <ctrl/ctrl2080/ctrl2080bus.h>
#include <ctrl/ctrl2080/ctrl2080fb.h>
#include <ctrl/ctrl2080/ctrl2080gpu.h>
#include <ctrl/ctrl2080/ctrl2080gr.h>
#include <ctrl/ctrl2080/ctrl2080gsp.h>
#include <ctrl/ctrl2080/ctrl2080mc.h>

#include <nvrm/nvrm.h>

#include <cuda.h>

#include "nvrm_rm_priv.h"	/* the escapes of the scripted kernel */
#include "nvrm_rm_sys.h"	/* the seam of the scripted kernel */
#include "cuda_nvrm.h"		/* the calls the provider makes */
#include "t.h"

#include "scripted_rm.h"
#include "scripted_mem.h"

/* The calls of the copy of libnvrm that is compiled into this program. */
static const cuda_nvrm_api api = {
	.enumerate = nvrm_enumerate,
	.close = nvrm_close,
	.device_count = nvrm_device_count,
	.device_get = nvrm_device_get,
	.device_info_get = nvrm_device_info_get,
	.client_open = nvrm_client_open,
	.client_close = nvrm_client_close,
	.client_errmsg = nvrm_client_errmsg,
	.va_reserve = nvrm_va_reserve,
	.va_release = nvrm_va_release,
	.mem_alloc = nvrm_mem_alloc,
	.mem_free = nvrm_mem_free,
	.mem_info_get = nvrm_mem_info_get,
	.mem_map_gpu = nvrm_mem_map_gpu,
	.mem_unmap_gpu = nvrm_mem_unmap_gpu,
	.mem_map_cpu = nvrm_mem_map_cpu,
	.mem_unmap_cpu = nvrm_mem_unmap_cpu,
	.mem_read = nvrm_mem_read,
	.mem_write = nvrm_mem_write,
	.cap_name = nvrm_cap_name,
	.library_version = nvrm_library_version
};

/* The size of the video memory the scripted kernel reports: 16 GiB. */
#define SCRIPTED_VRAM_BYTES (16ULL * 1024 * 1024 * 1024)
/* The UUID the scripted kernel reports: GPU-11111111-2222-4333-8444-... */
static const unsigned char scripted_uuid[16] = {
	0x11, 0x11, 0x11, 0x11, 0x22, 0x22, 0x43, 0x33,
	0x84, 0x44, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55
};
/* The number of streaming multiprocessors the scripted kernel reports:
 * three GPCs of six TPCs of two multiprocessors. */
#define SCRIPTED_SM_COUNT 36

static void
check_devices(void)
{
	CUdevice device = -1;
	CUuuid uuid;
	char name[128];
	size_t bytes = 0;
	int count = -1, value = 0;

	CHECK_EQ(cuDeviceGetCount(&count), CUDA_SUCCESS);
	CHECK_EQ(count, 1);
	CHECK_EQ(cuDeviceGet(&device, 0), CUDA_SUCCESS);
	/* The name is the generation the resource manager reported. */
	CHECK_EQ(cuDeviceGetName(name, sizeof(name), device), CUDA_SUCCESS);
	CHECK_STR(name, "NVIDIA blackwell-b");
	/* The video memory is the one the resource manager reported. */
	CHECK_EQ(cuDeviceTotalMem(&bytes, device), CUDA_SUCCESS);
	CHECK_EQ(bytes, SCRIPTED_VRAM_BYTES);
	/* The UUID is the one the resource manager reported. */
	CHECK_EQ(cuDeviceGetUuid(&uuid, device), CUDA_SUCCESS);
	CHECK_EQ(memcmp(uuid.bytes, scripted_uuid, sizeof(scripted_uuid)), 0);
	/* The number of multiprocessors is the one the resource manager
	 * reported. */
	CHECK_EQ(cuDeviceGetAttribute(&value,
	    CU_DEVICE_ATTRIBUTE_MULTIPROCESSOR_COUNT, device), CUDA_SUCCESS);
	CHECK_EQ(value, SCRIPTED_SM_COUNT);
	/* An attribute the resource manager does not report stays
	 * unavailable, and the library says why. */
	value = -1;
	CHECK_EQ(cuDeviceGetAttribute(&value, CU_DEVICE_ATTRIBUTE_WARP_SIZE,
	    device), CUDA_ERROR_NOT_SUPPORTED);
	CHECK(value == -1);
	CHECK(cudaNativeFailureReason()[0] != '\0');
}

static void
check_memory(void)
{
	CUcontext context = NULL;
	CUdevice device = -1;
	CUdeviceptr pointer = 0;
	unsigned char pattern[4096], readback[4096];
	size_t free_bytes = 0, total_bytes = 0;
	size_t i;

	CHECK_EQ(cuDeviceGet(&device, 0), CUDA_SUCCESS);
	CHECK_EQ(cuCtxCreate(&context, CU_CTX_SCHED_AUTO, device),
	    CUDA_SUCCESS);
	CHECK_EQ(cuCtxSetCurrent(context), CUDA_SUCCESS);
	/* The allocation: video memory of the device of the context. */
	CHECK_EQ(cuMemAlloc(&pointer, 1024 * 1024), CUDA_SUCCESS);
	CHECK(pointer != 0);
	CHECK_EQ(cuMemGetInfo(&free_bytes, &total_bytes), CUDA_SUCCESS);
	CHECK_EQ(total_bytes, SCRIPTED_VRAM_BYTES);
	CHECK(free_bytes < total_bytes);
	/* The copy in and the copy out. */
	for (i = 0; i < sizeof(pattern); i++)
		pattern[i] = (unsigned char)(i * 7 + 3);
	CHECK_EQ(cuMemcpyHtoD(pointer, pattern, sizeof(pattern)), CUDA_SUCCESS);
	memset(readback, 0, sizeof(readback));
	CHECK_EQ(cuMemcpyDtoH(readback, pointer, sizeof(readback)),
	    CUDA_SUCCESS);
	CHECK_EQ(memcmp(pattern, readback, sizeof(pattern)), 0);
	/* The fills. */
	CHECK_EQ(cuMemsetD8(pointer, 0x5A, sizeof(pattern)), CUDA_SUCCESS);
	memset(readback, 0, sizeof(readback));
	CHECK_EQ(cuMemcpyDtoH(readback, pointer, sizeof(readback)),
	    CUDA_SUCCESS);
	for (i = 0; i < sizeof(pattern); i++)
		CHECK_EQ(readback[i], 0x5A);
	/* The free, and the context that goes with it. */
	CHECK_EQ(cuMemFree(pointer), CUDA_SUCCESS);
	CHECK_EQ(cuMemFree(pointer), CUDA_ERROR_INVALID_VALUE);
	CHECK_EQ(cuCtxDestroy(context), CUDA_SUCCESS);
}

int
main(void)
{
	/* The scripted kernel stands in front of the resource manager, and
	 * the provider of libcuda talks to the copy of libnvrm that is
	 * compiled into this program. */
	nvrm_rm_set_sys(&mem_sys);
	cudaNvrmBindApi(&api);
	reset_all();
	CHECK_EQ(cuInit(0), CUDA_SUCCESS);
	check_devices();
	check_memory();
	/* The scripted kernel refuses nothing: it checks every request it
	 * gets, and it refuses the ones the library sends wrongly. */
	if (K.bad) {
		printf("FAIL the scripted kernel refused %d requests: %s\n",
		    K.bad, K.badmsg);
		t_fails++;
	} else {
		printf("ok the scripted kernel refused no request\n");
	}
	return (t_done("libcuda native provider against the scripted kernel"));
}

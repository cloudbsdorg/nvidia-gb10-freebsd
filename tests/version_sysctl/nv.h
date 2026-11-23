/* NVIDIA types and RM entry points needed by nv_version_sysctl.c. */
#ifndef _FAKE_NV_H_
#define _FAKE_NV_H_

#include <stddef.h>
#include <stdint.h>
#include <sys/sysctl.h>

typedef uint32_t NvU32;
typedef uint16_t NvU16;
typedef uint8_t NvU8;

typedef struct {
	NvU32 domain;
	NvU8 bus;
	NvU8 slot;
	NvU8 function;
	NvU16 vendor_id;
	NvU16 device_id;
} nv_pci_info_t;

typedef struct fake_device *device_t;

struct nvidia_softc {
	device_t dev;
	struct sysctl_ctx_list sysctl_ctx;
};

typedef struct nv_state_t {
	nv_pci_info_t pci_info;
	struct nvidia_softc *os_state;
} nv_state_t;

typedef struct nvidia_stack_t {
	int unused;
} nvidia_stack_t;

nvidia_stack_t *fake_stack_alloc(void);
void fake_stack_free(nvidia_stack_t *);
#define NV_UMA_ZONE_ALLOC_STACK(sp)	((sp) = fake_stack_alloc())
#define NV_UMA_ZONE_FREE_STACK(sp)	fake_stack_free(sp)

char *rm_get_gpu_uuid(nvidia_stack_t *, nv_state_t *);
void rm_get_vbios_version(nvidia_stack_t *, nv_state_t *, char *);
void rm_get_firmware_version(nvidia_stack_t *, nv_state_t *, char *, size_t);
void os_free_mem(void *);

struct sysctl_oid *device_get_sysctl_tree(device_t);

#endif /* _FAKE_NV_H_ */

/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-3-Clause
 *
 * fw_names.c - Track #2417: print the firmware(9) image name the driver asks
 * for, for every GSP chip family, using the driver's own macro
 * (FW_NAME_MACRO, taken from the prepared nvidia_subr.c) and NVIDIA's own
 * nv-firmware.h.  One name per line, sorted and unique by the caller.
 */
#include FW_NAME_MACRO
#include "nv-firmware.h"
#include <stdio.h>

int main(void)
{
	int f;

	for (f = NV_FIRMWARE_CHIP_FAMILY_TU10X; f < NV_FIRMWARE_CHIP_FAMILY_END; f++) {
		const char *n = nv_firmware_for_chip_family(NV_FIRMWARE_TYPE_GSP,
		    (nv_firmware_chip_family_t)f);
		if (n != NULL && n[0] != '\0')
			printf("%s\n", n);
	}
	return 0;
}

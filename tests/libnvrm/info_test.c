/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * info_test.c - drive the real nvrm-info main function with the scripted RM.
 * One process handles one invocation because nvrm-info enters capability mode.
 */
#include <sys/param.h>
#include <sys/ioctl.h>
#include <sys/filio.h>

#include <unistd.h>

#ifndef NVRM_INFO_SOURCE
#define NVRM_INFO_SOURCE "../../lib/libnvrm/nvrm-info/nvrm-info.c"
#endif
#define main nvrm_info_main
#include NVRM_INFO_SOURCE
#undef main

#include <nvtypes.h>
#include <nvstatus.h>
#include <nvmisc.h>
#include <nvos.h>
#include <nv-ioctl.h>
#include <nv_escape.h>
#include <class/cl0000.h>
#include <class/cl0080.h>
#include <class/cl2080.h>
#include <ctrl/ctrl0000/ctrl0000gpu.h>
#include <ctrl/ctrl0080/ctrl0080gpu.h>
#include <ctrl/ctrl2080/ctrl2080bios.h>
#include <ctrl/ctrl2080/ctrl2080bus.h>
#include <ctrl/ctrl2080/ctrl2080fb.h>
#include <ctrl/ctrl2080/ctrl2080gpu.h>
#include <ctrl/ctrl2080/ctrl2080gr.h>
#include <ctrl/ctrl2080/ctrl2080gsp.h>
#include <ctrl/ctrl2080/ctrl2080mc.h>

#include "nvrm_internal.h"
#include "nvrm_rm_sys.h"
#include "fault_calloc.h"
#include "scripted_rm.h"

int
main(int argc, char **argv)
{
	char *args[5];
	int n = 0;

	if (argc < 2 || argc > 3)
		return (2);
	reset_kernel();
	if (strcmp(argv[1], "query-fail") == 0)
		K.fail_version_query = 1;
	else if (strcmp(argv[1], "inconsistent") == 0) {
		K.version_parts = 1;
		K.version_major--;
	} else if (strcmp(argv[1], "sparse") == 0) {
		K.fail_vbios_oem = 1;
		K.gsp_valid = 0;
	} else if (strcmp(argv[1], "default") != 0)
		return (2);
	args[n++] = argv[0];
	if (argc == 3) {
		if (strcmp(argv[2], "--json") != 0 &&
		    strcmp(argv[2], "--jsonl") != 0)
			return (2);
		args[n++] = argv[2];
	}
	args[n++] = "--backend";
	args[n++] = "rm";
	args[n] = NULL;
	nvrm_rm_set_sys(&scripted);
	return (nvrm_info_main(n, args));
}

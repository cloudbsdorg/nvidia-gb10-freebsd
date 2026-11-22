; Copyright (c) 2026 REVYTECH, Inc.
; SPDX-License-Identifier: BSD-2-Clause
;
; libdevice.ll - cuda-native SDK (Track #2380).  clang links
; nvvm/libdevice/libdevice.10.bc into every device compile
; (-mlink-builtin-bitcode).  This is the C1.1 placeholder: a module with no
; functions.  The __nv_* math library built from libclc replaces it in a
; later C1.1 round (Track #2425); until then a kernel that calls a math
; function leaves an unresolved __nv_* symbol in its PTX.
target triple = "nvptx64-nvidia-cuda"

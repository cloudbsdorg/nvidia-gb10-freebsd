--- src/nvidia/src/kernel/gpu/subdevice/subdevice_ctrl_timer_kernel.c.orig
+++ src/nvidia/src/kernel/gpu/subdevice/subdevice_ctrl_timer_kernel.c
@@ -40,6 +40,7 @@
 #include "rmapi/client.h"
 
 #include "kernel/gpu/intr/intr.h"
+#include "os/os.h"
 
 //
 // subdeviceCtrlCmdTimerCancel
@@ -285,6 +286,33 @@
     NV_ASSERT_OR_RETURN(rmapiLockIsOwner(), NV_ERR_INVALID_LOCK_STATE);
 
     return gpuGetRegBaseOffset_HAL(pGpu, NV_REG_BASE_TIMER, &pTimerRegOffsetParams->tmr_offset);
+}
+
+//
+// FreeBSD GB10 port: GB10B keeps the wall-clock offset of PTIMER in software
+// only (tmrSetCurrentTime_GB10B computes sysTimerOffsetNs; nothing programs
+// the hardware), so the GPU writes raw PTIMER values into the timestamps of
+// CUPTI activity records. CUPTI converts those with the samples returned
+// below; with the offset added, the conversion goes negative and every
+// kernel and memcpy record ends up with start = end = 0. Report raw PTIMER
+// in the correlation unless the registry key RmGb10RawPtimerCorrelation is 0
+// (upstream behaviour). On chips without a software offset this is a no-op.
+//
+static NvU64
+_tmrCorrelationOffsetNs
+(
+    OBJGPU *pGpu,
+    OBJTMR *pTmr
+)
+{
+    NvU32 data = 1;
+
+    if ((osReadRegistryDword(pGpu, "RmGb10RawPtimerCorrelation", &data) == NV_OK) &&
+        (data == 0))
+    {
+        return tmrGetPtimerOffsetNs_HAL(pGpu, pTmr);
+    }
+    return 0;
 }
 
 /*!
@@ -366,7 +394,7 @@
                               status);
                     break;
                 }
-                pParams->samples[i].gpuTime += tmrGetPtimerOffsetNs_HAL(pGpu, pTmr);
+                pParams->samples[i].gpuTime += _tmrCorrelationOffsetNs(pGpu, pTmr);
             }
             break;
         }
@@ -430,7 +458,7 @@
             }
 
             pParams->samples[0].gpuTime = ((((NvU64)gpuTimeHiNew) << 32) |
-                                           gpuTimeLo[closestPairBeginIndex]) + tmrGetPtimerOffsetNs_HAL(pGpu, pTmr);
+                                           gpuTimeLo[closestPairBeginIndex]) + _tmrCorrelationOffsetNs(pGpu, pTmr);
             pParams->samples[0].cpuTime = (cpuTime[closestPairBeginIndex] +
                                            cpuTime[closestPairBeginIndex + 1])/2;
             NV_PRINTF(LEVEL_INFO,

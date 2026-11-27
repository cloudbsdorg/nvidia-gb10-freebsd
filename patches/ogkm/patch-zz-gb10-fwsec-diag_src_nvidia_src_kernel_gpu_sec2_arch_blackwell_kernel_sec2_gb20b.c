--- src/nvidia/src/kernel/gpu/sec2/arch/blackwell/kernel_sec2_gb20b.c.orig
+++ src/nvidia/src/kernel/gpu/sec2/arch/blackwell/kernel_sec2_gb20b.c
@@ -572,6 +572,51 @@
     status = gpuTimeoutCondWait(pGpu, _ksec2WaitBootCond_GB20B, NULL, &timeout);
 
     return status;
+}
+
+/*
+ * FreeBSD GB10 bring-up diagnostic and probe.  Reports which GSP-FMC archive
+ * (debug- or prod-signed) is selected and the fuse value behind the choice.
+ * Registry key RmGb10CotProbe (default 0 = unchanged behaviour) deliberately
+ * damages the chain-of-trust command so that FWSEC's answer shows which of
+ * its checks runs first:
+ *   1 = bogus payload version, 2 = one hash byte flipped,
+ *   3 = GSP-FMC image zeroed in memory, 4 = the other (debug/prod) archive.
+ */
+#define GB10_COT_PROBE_REGKEY "RmGb10CotProbe"
+
+static NvU32
+_ksec2Gb10CotProbe
+(
+    OBJGPU *pGpu
+)
+{
+    NvU32 probe = 0;
+
+    if (osReadRegistryDword(pGpu, GB10_COT_PROBE_REGKEY, &probe) != NV_OK)
+        probe = 0;
+    return probe;
+}
+
+static NvBool
+_ksec2Gb10DebugMode
+(
+    OBJGPU    *pGpu,
+    KernelGsp *pKernelGsp
+)
+{
+    NvBool bDebug = kgspIsDebugModeEnabled_HAL(pGpu, pKernelGsp);
+    NvU32  probe  = _ksec2Gb10CotProbe(pGpu);
+
+    NV_PRINTF(LEVEL_ERROR, "GB10 diag: debug fuse (0x82074c) = 0x%x, debug mode = %d, probe = %u\n",
+              GPU_REG_RD32(pGpu, 0x0082074C), bDebug, probe);
+    if (probe == 4)
+    {
+        bDebug = !bDebug;
+        NV_PRINTF(LEVEL_ERROR, "GB10 probe 4: using the %s-signed GSP-FMC archive instead\n",
+                  bDebug ? "debug" : "prod");
+    }
+    return bDebug;
 }
 
 static const BINDATA_ARCHIVE *
@@ -589,7 +634,7 @@
     {
         NV_PRINTF(LEVEL_NOTICE, "Loading GSP-RM image using SEC2.\n");
 
-        if (kgspIsDebugModeEnabled_HAL(pGpu, pKernelGsp))
+        if (_ksec2Gb10DebugMode(pGpu, pKernelGsp))
         {
             if (pCC != NULL && pCC->getProperty(pCC, PDB_PROP_CONFCOMPUTE_CC_FEATURE_ENABLED))
             {
@@ -835,6 +880,80 @@
 {
     // On GSP-RM, the kgsp code path will check for GSP boot status
     return NV_OK;
+}
+
+/*
+ * FreeBSD GB10 bring-up diagnostic.  Print the boot-status scratch registers
+ * that later driver releases (595.x) print when the chain-of-trust command
+ * fails.  Read-only.  The PSEC and PMC offsets are absolute; the PBUS block
+ * base is not known in this release (595.x takes it from the device info
+ * table), so the classic base 0x1000 is assumed and labelled as such.
+ */
+#define GB10_DIAG_PSEC_COMMON_SCRATCH_GROUP_2(i) (0x00840320 + (i) * 4)
+#define GB10_DIAG_PBUS_SW_SCRATCH(i)             (0x00001000 + 0x400 + (i) * 4)
+
+static void
+_ksec2Gb10DumpBootScratch
+(
+    OBJGPU     *pGpu,
+    const char *pWhen
+)
+{
+    NvU32 head, tail;
+
+    NV_PRINTF(LEVEL_ERROR, "GB10 diag (%s): FWSEC completion (PMC 0x5e0) = 0x%x\n",
+              pWhen, GPU_REG_RD32(pGpu, NV_PMC_SCRATCH_RESET_PLUS_2));
+    NV_PRINTF(LEVEL_ERROR, "GB10 diag (%s): FWSEC error code = 0x%x, offending PC = 0x%x\n",
+              pWhen,
+              GPU_REG_RD32(pGpu, GB10_DIAG_PSEC_COMMON_SCRATCH_GROUP_2(0)),
+              GPU_REG_RD32(pGpu, GB10_DIAG_PSEC_COMMON_SCRATCH_GROUP_2(1)));
+    NV_PRINTF(LEVEL_ERROR, "GB10 diag (%s): FWSEC offending address = 0x%x, additional info = 0x%x\n",
+              pWhen,
+              GPU_REG_RD32(pGpu, GB10_DIAG_PSEC_COMMON_SCRATCH_GROUP_2(2)),
+              GPU_REG_RD32(pGpu, GB10_DIAG_PSEC_COMMON_SCRATCH_GROUP_2(3)));
+
+    head = GPU_REG_RD32(pGpu, NV_PSEC_QUEUE_HEAD(SEC2_EMEM_CHANNEL_RM));
+    tail = GPU_REG_RD32(pGpu, NV_PSEC_QUEUE_TAIL(SEC2_EMEM_CHANNEL_RM));
+    NV_PRINTF(LEVEL_ERROR, "GB10 diag (%s): cmd queue head = 0x%x tail = 0x%x\n",
+              pWhen, head, tail);
+    head = GPU_REG_RD32(pGpu, NV_PSEC_MSGQ_HEAD(SEC2_EMEM_CHANNEL_RM));
+    tail = GPU_REG_RD32(pGpu, NV_PSEC_MSGQ_TAIL(SEC2_EMEM_CHANNEL_RM));
+    NV_PRINTF(LEVEL_ERROR, "GB10 diag (%s): msg queue head = 0x%x tail = 0x%x\n",
+              pWhen, head, tail);
+
+    NV_PRINTF(LEVEL_ERROR, "GB10 diag (%s): assumed-PBUS scratch: [0] FWSEC version = 0x%x, [2] devinit version = 0x%x\n",
+              pWhen,
+              GPU_REG_RD32(pGpu, GB10_DIAG_PBUS_SW_SCRATCH(0)),
+              GPU_REG_RD32(pGpu, GB10_DIAG_PBUS_SW_SCRATCH(2)));
+    NV_PRINTF(LEVEL_ERROR, "GB10 diag (%s): assumed-PBUS scratch: [12] devinit boot status = 0x%x, [54] COT polling status = 0x%x, [52] FRTS completion = 0x%x\n",
+              pWhen,
+              GPU_REG_RD32(pGpu, GB10_DIAG_PBUS_SW_SCRATCH(12)),
+              GPU_REG_RD32(pGpu, GB10_DIAG_PBUS_SW_SCRATCH(54)),
+              GPU_REG_RD32(pGpu, GB10_DIAG_PBUS_SW_SCRATCH(52)));
+    NV_PRINTF(LEVEL_ERROR, "GB10 diag (%s): assumed-PBUS scratch: [15] failing register = 0x%x, [16] devinit PC = 0x%x, [28] PRI error code = 0x%x\n",
+              pWhen,
+              GPU_REG_RD32(pGpu, GB10_DIAG_PBUS_SW_SCRATCH(15)),
+              GPU_REG_RD32(pGpu, GB10_DIAG_PBUS_SW_SCRATCH(16)),
+              GPU_REG_RD32(pGpu, GB10_DIAG_PBUS_SW_SCRATCH(28)));
+
+    /* H-state: is the GSP core already running, is WPR2 already up?  Read-only. */
+    NV_PRINTF(LEVEL_ERROR, "GB10 diag (%s): GSP falcon: HWCFG2 = 0x%x, CPUCTL = 0x%x, OS = 0x%x, ENGINE = 0x%x\n",
+              pWhen, GPU_REG_RD32(pGpu, 0x001100f4), GPU_REG_RD32(pGpu, 0x00110100),
+              GPU_REG_RD32(pGpu, 0x00110080), GPU_REG_RD32(pGpu, 0x001103c0));
+    NV_PRINTF(LEVEL_ERROR, "GB10 diag (%s): GSP falcon: MAILBOX0 = 0x%x, MAILBOX1 = 0x%x, reg 0x110094 = 0x%x\n",
+              pWhen, GPU_REG_RD32(pGpu, 0x00110040), GPU_REG_RD32(pGpu, 0x00110044),
+              GPU_REG_RD32(pGpu, 0x00110094));
+    NV_PRINTF(LEVEL_ERROR, "GB10 diag (%s): GSP RISC-V CPUCTL (0x111388) = 0x%x, PGSP_MAILBOX[0..3] = 0x%x 0x%x 0x%x 0x%x\n",
+              pWhen, GPU_REG_RD32(pGpu, 0x00111388),
+              GPU_REG_RD32(pGpu, 0x00110804), GPU_REG_RD32(pGpu, 0x00110808),
+              GPU_REG_RD32(pGpu, 0x0011080c), GPU_REG_RD32(pGpu, 0x00110810));
+    NV_PRINTF(LEVEL_ERROR, "GB10 diag (%s): GSP queue 0: head = 0x%x tail = 0x%x; WPR2 ADDR_LO (0x1fa824) = 0x%x, ADDR_HI (0x1fa828) = 0x%x\n",
+              pWhen, GPU_REG_RD32(pGpu, 0x00110c00), GPU_REG_RD32(pGpu, 0x00110c04),
+              GPU_REG_RD32(pGpu, 0x001fa824), GPU_REG_RD32(pGpu, 0x001fa828));
+    NV_PRINTF(LEVEL_ERROR, "GB10 diag (%s): SEC2 (assumed bases 0x840000 / 0x841000): HWCFG2 = 0x%x, CPUCTL = 0x%x, RISC-V CPUCTL = 0x%x, MAILBOX0 = 0x%x, MAILBOX1 = 0x%x\n",
+              pWhen, GPU_REG_RD32(pGpu, 0x008400f4), GPU_REG_RD32(pGpu, 0x00840100),
+              GPU_REG_RD32(pGpu, 0x00841388), GPU_REG_RD32(pGpu, 0x00840040),
+              GPU_REG_RD32(pGpu, 0x00840044));
 }
 
 /*!
@@ -856,6 +975,7 @@
     NV_PRINTF(LEVEL_ERROR, "GPU %04x:%02x:%02x\n",
               gpuGetDomain(pGpu), gpuGetBus(pGpu), gpuGetDevice(pGpu));
 
+    _ksec2Gb10DumpBootScratch(pGpu, "after failed COT");
 }
 
 /*!
@@ -1041,6 +1161,102 @@
 
     NV_ASSERT_OR_RETURN(pKernelSec2->pCotPayload != NULL, NV_ERR_INVALID_STATE);
 
+    {
+        NvU32 probe = _ksec2Gb10CotProbe(pGpu);
+
+        NV_PRINTF(LEVEL_ERROR, "GB10 diag: COT payload version=0x%x size=0x%x hash[0]=0x%08x, FMC memdesc size=0x%llx, probe=%u\n",
+                  pKernelSec2->pCotPayload->version, pKernelSec2->pCotPayload->size,
+                  pKernelSec2->pCotPayload->hash384[0],
+                  (pKernelSec2->pGspFmcMemdesc != NULL) ?
+                      memdescGetSize(pKernelSec2->pGspFmcMemdesc) : 0ULL,
+                  probe);
+        if (probe == 1)
+        {
+            pKernelSec2->pCotPayload->version = 0x7f;
+            NV_PRINTF(LEVEL_ERROR, "GB10 probe 1: payload version forced to 0x7f\n");
+        }
+        else if (probe == 2)
+        {
+            pKernelSec2->pCotPayload->hash384[0] ^= 0xff;
+            NV_PRINTF(LEVEL_ERROR, "GB10 probe 2: hash384 byte 0 flipped\n");
+        }
+        else if (probe == 3 && pKernelSec2->pGspFmcMemdesc != NULL)
+        {
+            NvP64 pProbeVa = NULL;
+            NvP64 pProbePriv = NULL;
+            NvU64 probeSize = memdescGetSize(pKernelSec2->pGspFmcMemdesc);
+
+            if (memdescMap(pKernelSec2->pGspFmcMemdesc, 0, probeSize, NV_TRUE,
+                           NV_PROTECT_READ_WRITE, &pProbeVa, &pProbePriv) == NV_OK)
+            {
+                portMemSet(pProbeVa, 0, probeSize);
+                memdescUnmap(pKernelSec2->pGspFmcMemdesc, NV_TRUE, pProbeVa, pProbePriv);
+                NV_PRINTF(LEVEL_ERROR, "GB10 probe 3: GSP-FMC image zeroed (0x%llx bytes)\n", probeSize);
+            }
+            else
+            {
+                NV_PRINTF(LEVEL_ERROR, "GB10 probe 3: could not map the GSP-FMC image; sent unchanged\n");
+            }
+        }
+        else if (probe == 5)
+        {
+            const BINDATA_ARCHIVE *pProbeArchive = _ksec2GetGspUcodeArchive(pGpu, pKernelSec2);
+            PBINDATA_STORAGE pProbeImage = (pProbeArchive == NULL) ? NULL :
+                (PBINDATA_STORAGE)bindataArchiveGetStorage(pProbeArchive, BINDATA_LABEL_UCODE_IMAGE);
+
+            if (pProbeImage != NULL)
+            {
+                pKernelSec2->pCotPayload->frtsSysmemSize = bindataGetBufferSize(pProbeImage);
+                NV_PRINTF(LEVEL_ERROR, "GB10 probe 5: frtsSysmemSize = GSP-FMC image size 0x%x (GB10B style)\n",
+                          pKernelSec2->pCotPayload->frtsSysmemSize);
+            }
+            else
+            {
+                NV_PRINTF(LEVEL_ERROR, "GB10 probe 5: image not found; sent unchanged\n");
+            }
+        }
+#if defined(NVCPU_AARCH64)
+        else if (probe == 6 && pKernelSec2->pGspFmcMemdesc != NULL)
+        {
+            KernelGsp *pProbeGsp = GPU_GET_KERNEL_GSP(pGpu);
+            NvP64 pProbeVa = NULL;
+            NvP64 pProbePriv = NULL;
+            NvU64 probeSize = memdescGetSize(pKernelSec2->pGspFmcMemdesc);
+            NvU64 probeOff;
+
+            if (memdescMap(pKernelSec2->pGspFmcMemdesc, 0, probeSize, NV_TRUE,
+                           NV_PROTECT_READ_WRITE, &pProbeVa, &pProbePriv) == NV_OK)
+            {
+                NvU8 *pProbeBase = (NvU8 *)NvP64_VALUE(pProbeVa);
+
+                for (probeOff = 0; probeOff < probeSize; probeOff += 64)
+                    __asm__ volatile("dc civac, %0" : : "r" (pProbeBase + probeOff) : "memory");
+                __asm__ volatile("dsb sy" : : : "memory");
+                NV_PRINTF(LEVEL_ERROR, "GB10 probe 6: GSP-FMC image cache lines cleaned+invalidated (0x%llx bytes), first word 0x%08x\n",
+                          probeSize, *(NvU32 *)pProbeBase);
+                memdescUnmap(pKernelSec2->pGspFmcMemdesc, NV_TRUE, pProbeVa, pProbePriv);
+            }
+            else
+            {
+                NV_PRINTF(LEVEL_ERROR, "GB10 probe 6: could not map the GSP-FMC image\n");
+            }
+            if (pProbeGsp != NULL && pProbeGsp->pGspFmcArgumentsCached != NULL &&
+                pProbeGsp->pGspFmcArgumentsDescriptor != NULL)
+            {
+                NvU8 *pProbeArgs = (NvU8 *)pProbeGsp->pGspFmcArgumentsCached;
+                NvU64 argsSize = memdescGetSize(pProbeGsp->pGspFmcArgumentsDescriptor);
+
+                for (probeOff = 0; probeOff < argsSize; probeOff += 64)
+                    __asm__ volatile("dc civac, %0" : : "r" (pProbeArgs + probeOff) : "memory");
+                __asm__ volatile("dsb sy" : : : "memory");
+                NV_PRINTF(LEVEL_ERROR, "GB10 probe 6: boot args cache lines cleaned+invalidated (0x%llx bytes)\n", argsSize);
+            }
+        }
+#endif
+    }
+
+    _ksec2Gb10DumpBootScratch(pGpu, "before COT");
+
     status = ksec2SendAndReadMessage(pGpu, pKernelSec2, (NvU8 *)pKernelSec2->pCotPayload,
                                     sizeof(NVDM_PAYLOAD_COT), NVDM_TYPE_COT, NULL, 0);
     if (status != NV_OK)

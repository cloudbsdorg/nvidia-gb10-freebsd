--- src/nvidia-modeset/src/nvkms.c.orig
+++ src/nvidia-modeset/src/nvkms.c
@@ -936,4 +936,24 @@
         }
     }
+}
+
+static void RevokePermissionsInternal(
+    const NvU32 typeBitmask,
+    NVDevEvoRec *pDevEvo,
+    const struct NvKmsPerOpenDev *pOpenDevExclude);
+
+static void
+CbsdDropModesetOwner(struct NvKmsPerOpenDev *pOpenDev,
+                     struct NvKmsPerOpenDev *pOpenDevExclude)
+{
+    NVDevEvoPtr pDevEvo = pOpenDev->pDevEvo;
+
+    FreeSwapGroups(pOpenDev);
+    pDevEvo->modesetOwner = NULL;
+    pDevEvo->modesetOwnerOrSubOwnerChanged = TRUE;
+    RevokePermissionsInternal(NVBIT(NV_KMS_PERMISSIONS_TYPE_FLIPPING) |
+                              NVBIT(NV_KMS_PERMISSIONS_TYPE_MODESET) |
+                              NVBIT(NV_KMS_PERMISSIONS_TYPE_SUB_OWNER),
+                              pDevEvo, pOpenDevExclude);
 }
 
@@ -963,5 +983,11 @@
 
     if (pDevEvo->modesetOwner != NULL) {
-        return FALSE;
+        if ((pDevEvo->modesetOwner == pDevEvo->cbsdConsoleOwner) &&
+            (pOpenDev != pDevEvo->cbsdConsoleOwner)) {
+            pDevEvo->cbsdConsoleYield(pDevEvo->cbsdConsoleArg);
+            CbsdDropModesetOwner(pDevEvo->cbsdConsoleOwner, pOpenDev);
+        } else {
+            return FALSE;
+        }
     }
 
@@ -1102,4 +1128,22 @@
             }
         }
+    }
+}
+
+static void RestoreConsole(NVDevEvoPtr pDevEvo);
+
+static void
+CbsdClearConsoleOwner(NVDevEvoPtr pDevEvo)
+{
+    pDevEvo->cbsdConsoleOwner = NULL;
+    pDevEvo->cbsdConsoleYield = NULL;
+    pDevEvo->cbsdConsoleReclaim = NULL;
+    pDevEvo->cbsdConsoleArg = NULL;
+
+    if (pDevEvo->modesetOwner == NULL) {
+        pDevEvo->handleConsoleHotplugs = TRUE;
+        RestoreConsole(pDevEvo);
+    } else {
+        pDevEvo->handleConsoleHotplugs = FALSE;
     }
 }
@@ -1147,15 +1191,14 @@
     }
 
-    FreeSwapGroups(pOpenDev);
-
-    pDevEvo->modesetOwner = NULL;
-    pDevEvo->modesetOwnerOrSubOwnerChanged = TRUE;
-    pDevEvo->handleConsoleHotplugs = TRUE;
+    CbsdDropModesetOwner(pOpenDev, NULL /* pOpenDevExclude */);
 
-    RestoreConsole(pDevEvo);
-    RevokePermissionsInternal(NVBIT(NV_KMS_PERMISSIONS_TYPE_FLIPPING) |
-                              NVBIT(NV_KMS_PERMISSIONS_TYPE_MODESET) |
-                              NVBIT(NV_KMS_PERMISSIONS_TYPE_SUB_OWNER),
-                              pDevEvo, NULL /* pOpenDevExclude */);
+    if (pOpenDev == pDevEvo->cbsdConsoleOwner) {
+        CbsdClearConsoleOwner(pDevEvo);
+    } else if (pDevEvo->cbsdConsoleOwner != NULL) {
+        pDevEvo->cbsdConsoleReclaim(pDevEvo->cbsdConsoleArg);
+    } else {
+        pDevEvo->handleConsoleHotplugs = TRUE;
+        RestoreConsole(pDevEvo);
+    }
     return TRUE;
 }
@@ -1619,4 +1662,8 @@
                                 struct NvKmsPerOpenDev *pOpenDev)
 {
+    if (pOpenDev->pDevEvo->cbsdConsoleOwner == pOpenDev) {
+        CbsdClearConsoleOwner(pOpenDev->pDevEvo);
+    }
+
     /* Disable all client-owned vblank sync objects that still exist. */
     DisableRemainingVblankSyncObjects(pOpen, pOpenDev);
@@ -4985,5 +5032,50 @@
     return TRUE;
 }
+
+static NvBool CbsdSetConsoleOwner(
+    struct NvKmsPerOpen *pOpen,
+    void *pParamsVoid)
+{
+    const struct NvKmsCbsdSetConsoleOwnerParams *pParams = pParamsVoid;
+    struct NvKmsPerOpenDev *pOpenDev =
+        GetPerOpenDev(pOpen, pParams->request.deviceHandle);
+    NVDevEvoPtr pDevEvo;
+
+    if (pOpenDev == NULL) {
+        return FALSE;
+    }
+
+    if (pOpen->clientType != NVKMS_CLIENT_KERNEL_SPACE) {
+        return FALSE;
+    }
 
+    if ((pParams->request.yield == NULL) !=
+        (pParams->request.reclaim == NULL)) {
+        return FALSE;
+    }
+
+    pDevEvo = pOpenDev->pDevEvo;
+
+    if (pParams->request.yield != NULL) {
+        if (pDevEvo->modesetOwner != pOpenDev) {
+            return FALSE;
+        }
+
+        pDevEvo->cbsdConsoleOwner = pOpenDev;
+        pDevEvo->cbsdConsoleYield = pParams->request.yield;
+        pDevEvo->cbsdConsoleReclaim = pParams->request.reclaim;
+        pDevEvo->cbsdConsoleArg = pParams->request.arg;
+        pDevEvo->handleConsoleHotplugs = FALSE;
+    } else {
+        if (pDevEvo->cbsdConsoleOwner != pOpenDev) {
+            return FALSE;
+        }
+
+        CbsdClearConsoleOwner(pDevEvo);
+    }
+
+    return TRUE;
+}
+
 static NvBool FramebufferConsoleDisabled(
     struct NvKmsPerOpen *pOpen,
@@ -5138,4 +5230,5 @@
         ENTRY(NVKMS_IOCTL_VRR_SIGNAL_SEMAPHORE, VrrSignalSemaphore),
         ENTRY(NVKMS_IOCTL_FRAMEBUFFER_CONSOLE_DISABLED, FramebufferConsoleDisabled),
+        ENTRY(NVKMS_IOCTL_CBSD_SET_CONSOLE_OWNER, CbsdSetConsoleOwner),
     };
 
@@ -6397,7 +6490,12 @@
     NVDevEvoPtr pDevEvo = dataPtr;
 
-    if (pDevEvo->modesetOwner == NULL && pDevEvo->handleConsoleHotplugs) {
+    if (pDevEvo->modesetOwner == NULL &&
+        (pDevEvo->handleConsoleHotplugs || pDevEvo->cbsdConsoleOwner != NULL)) {
         pDevEvo->skipConsoleRestore = FALSE;
-        nvEvoRestoreConsole(pDevEvo, TRUE /* allowMST */);
+        if (pDevEvo->cbsdConsoleOwner != NULL) {
+            pDevEvo->cbsdConsoleReclaim(pDevEvo->cbsdConsoleArg);
+        } else {
+            nvEvoRestoreConsole(pDevEvo, TRUE /* allowMST */);
+        }
     }
 }
@@ -6883,5 +6981,9 @@
                     // restore.
                     pDevEvo->skipConsoleRestore = FALSE;
-                    RestoreConsole(pDevEvo);
+                    if (pDevEvo->cbsdConsoleOwner != NULL) {
+                        pDevEvo->cbsdConsoleReclaim(pDevEvo->cbsdConsoleArg);
+                    } else {
+                        RestoreConsole(pDevEvo);
+                    }
                 }
             }

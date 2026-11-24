--- nvidia/nvidia_os_pci.c.orig
+++ nvidia/nvidia_os_pci.c
@@ -41,13 +41,28 @@
     return (void *) dev;
 }
 
+/*
+ * Highest config-space offset the os_pci_* accessors serve.  The 256-byte
+ * limit is the legacy x86 port-I/O one.  arm64 has only ECAM, where
+ * pci_read_config() reaches the whole 4 KiB, and the RM walks the PCIe
+ * extended capability list from offset 0x100 (chipset_pcie.c): with the
+ * legacy limit it read 0xffffffff there, took 0xfff as the next capability
+ * and tripped its own "offset + sizeof(value) <= 0x1000" assertion, and saw
+ * no extended capability on the GPU or its bridge (GB10 bring-up, BOOT 90+).
+ */
+#if defined(__aarch64__)
+#define NV_PCI_CFG_LIMIT 0x1000
+#else
+#define NV_PCI_CFG_LIMIT 0x100
+#endif
+
 NV_STATUS NV_API_CALL os_pci_read_byte(
     void *handle,
     NvU32 offset,
     NvU8 *value
 )
 {
-    if (offset >= 0x100) {
+    if (offset >= NV_PCI_CFG_LIMIT) {
         *value = 0xff;
         return NV_ERR_NOT_SUPPORTED;
     }
@@ -61,7 +76,7 @@
     NvU16 *value
 )
 {
-    if (offset >= 0x100) {
+    if (offset >= NV_PCI_CFG_LIMIT) {
         *value = 0xffff;
         return NV_ERR_NOT_SUPPORTED;
     }
@@ -75,7 +90,7 @@
     NvU32 *value
 )
 {
-    if (offset >= 0x100) {
+    if (offset >= NV_PCI_CFG_LIMIT) {
         *value = 0xffffffff;
         return NV_ERR_NOT_SUPPORTED;
     }
@@ -89,7 +104,7 @@
     NvU8  value
 )
 {
-    if (offset >= 0x100)
+    if (offset >= NV_PCI_CFG_LIMIT)
         return NV_ERR_NOT_SUPPORTED;
 
     pci_write_config((device_t) handle, offset, value, 1);
@@ -102,7 +117,7 @@
     NvU16 value
 )
 {
-    if (offset >= 0x100)
+    if (offset >= NV_PCI_CFG_LIMIT)
         return NV_ERR_NOT_SUPPORTED;
 
     pci_write_config((device_t) handle, offset, value, 2);
@@ -115,7 +130,7 @@
     NvU32 value
 )
 {
-    if (offset >= 0x100)
+    if (offset >= NV_PCI_CFG_LIMIT)
         return NV_ERR_NOT_SUPPORTED;
 
     pci_write_config((device_t) handle, offset, value, 4);

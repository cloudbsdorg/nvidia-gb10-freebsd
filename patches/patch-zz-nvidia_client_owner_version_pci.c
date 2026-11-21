--- nvidia/nvidia_pci.c.orig
+++ nvidia/nvidia_pci.c
@@ -343,7 +343,8 @@
 #else
 DRIVER_MODULE(nvidia, vgapci, nvidia_pci_driver, nvidia_devclass, nvidia_modevent, 0);
 #endif
-MODULE_VERSION(nvidia, 1);
+/* 2: nvidia-uvm.ko of Track #2373 asks for the client hold exports; an older nvidia-uvm.ko must not load */
+MODULE_VERSION(nvidia, 2);
 
 MODULE_DEPEND(nvidia, mem, 1, 1, 1);
 /* the io(4) device exists only on x86 */

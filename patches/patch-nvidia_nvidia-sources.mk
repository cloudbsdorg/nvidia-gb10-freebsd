--- nvidia/nvidia-sources.mk.orig
+++ nvidia/nvidia-sources.mk
@@ -11,6 +11,7 @@
 NVIDIA_SOURCES += nvidia_os_registry.c
 NVIDIA_SOURCES += nvidia_pci.c
 NVIDIA_SOURCES += nvidia_subr.c
+NVIDIA_SOURCES += nv-uvm-interface.c
 NVIDIA_SOURCES += nvidia_sysctl.c
 NVIDIA_SOURCES += nvidia_modeset_interface.c
 NVIDIA_SOURCES += nv-kthread-q.c

--- nvidia-drm/nvidia-drm-drv.c.orig
+++ nvidia-drm/nvidia-drm-drv.c
@@ -330,8 +330,8 @@
 
 static int nv_drm_disp_cmp (const void *l, const void *r)
 {
-    struct nv_drm_mst_display_info *l_info = (struct nv_drm_mst_display_info *)l;
-    struct nv_drm_mst_display_info *r_info = (struct nv_drm_mst_display_info *)r;
+    const struct nv_drm_mst_display_info *l_info = l;
+    const struct nv_drm_mst_display_info *r_info = r;
 
     return strcmp(l_info->dpAddress, r_info->dpAddress);
 }

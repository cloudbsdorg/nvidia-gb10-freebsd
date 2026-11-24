--- nvidia/nv-freebsd.h.orig
+++ nvidia/nv-freebsd.h
@@ -156,6 +156,7 @@
     vm_object_t object;
     struct {
         NvBool user     : 1;
+        NvBool aliased  : 1;    /* nv_alias_pages(): pmap_mapdev'ed carveout */
     } flags;
     vm_page_t *user_pages;
     void *import_priv;

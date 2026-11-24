--- nvidia/nv-freebsd.h.orig	2026-11-24 03:21:15.416372000 +0000
+++ nvidia/nv-freebsd.h	2026-11-24 03:21:15.452928000 +0000
@@ -157,6 +157,7 @@
     struct {
         NvBool user     : 1;
         NvBool aliased  : 1;    /* nv_alias_pages(): pmap_mapdev'ed carveout */
+        NvBool fict_owned : 1;  /* aliased: we registered its fictitious vm_pages */
     } flags;
     vm_page_t *user_pages;
     void *import_priv;

/* gdb_internal.h - what the parts of the library share.
 *
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 */
#ifndef GDB_INTERNAL_H
#define GDB_INTERNAL_H

#include <sqlite3.h>
#include <stdarg.h>
#include <stddef.h>

#include "gdb.h"

#define GDB_ERR_MAX	512
#define GDB_MAX_STMTS	96
#define GDB_MAX_DATA	256

/* A statement that is prepared once and used again.  The cache is
 * searched by the SQL text, so a statement is never built at runtime:
 * the text is always a constant of this library. */
struct gdb_stmt {
	const char	*sql;
	sqlite3_stmt	*stmt;
};

/* The events that are being built. */
struct gdb_event {
	struct gdb	*db;
	char		 kind[64];
	char		 name[160];
	int		 ndata;
	char		*keys[GDB_MAX_DATA];
	int		 types[GDB_MAX_DATA];	/* 0 int, 1 number, 2 text */
	long long	 ints[GDB_MAX_DATA];
	double		 nums[GDB_MAX_DATA];
	char		*texts[GDB_MAX_DATA];
};

/* A growing text.  Everything the library prints goes through this. */
struct gdb_buf {
	char		*data;
	size_t		 len;
	size_t		 cap;
	int		 failed;
};

/* The database. */
struct gdb {
	sqlite3	*db;
	char		 err[GDB_ERR_MAX];
	int		 in_txn;
	int		 in_batch;
	int		 is_new;
	long long	 current_run;
	char		*schema_dir;
	struct gdb_stmt	 stmts[GDB_MAX_STMTS];
	int		 nstmts;
	/* The properties of the snapshot being taken, and the ones of the
	 * snapshot before it, so a key that came or went is known. */
	long long	*snap_seen;
	int		 nsnap_seen;
	int		 cap_snap_seen;
	long long	*snap_last;
	int		 nsnap_last;
	int		 cap_snap_last;
	/* Whether there is a snapshot before this one to compare it with.
	 * The first snapshot of a run has none: nothing came or went, the
	 * machine is only read for the first time. */
	int		 snap_have_last;
	/* The properties whose value changed in the snapshot being taken:
	 * the ones whose classification has to be worked out again. */
	long long	*snap_changed;
	int		 nsnap_changed;
	int		 cap_snap_changed;
	/* The snapshot that is being taken, so a property event knows
	 * which snapshot saw it. */
	long long	 current_snapshot;
	/* The last source that was looked up, and its row.  A provider
	 * gives its properties grouped by source, so the row of the
	 * source is found once and kept until the source changes. */
	char		 last_source[64];
	long long	 last_source_id;
};

/* gdb_json.c */
void		 gdb_buf_init(struct gdb_buf *buf);
void		 gdb_buf_free(struct gdb_buf *buf);
int		 gdb_buf_add(struct gdb_buf *buf, const char *text);
int		 gdb_buf_addf(struct gdb_buf *buf, const char *fmt, ...);
int		 gdb_buf_add_json(struct gdb_buf *buf, const char *text);
int		 gdb_buf_add_json_num(struct gdb_buf *buf, double value);
char		*gdb_buf_take(struct gdb_buf *buf);

struct gdb_json;
struct gdb_json	*gdb_json_object(void);
struct gdb_json	*gdb_json_array(void);
struct gdb_json	*gdb_json_string(const char *text);
struct gdb_json	*gdb_json_int(long long value);
struct gdb_json	*gdb_json_number(double value);
struct gdb_json	*gdb_json_bool(int value);
struct gdb_json	*gdb_json_null(void);
int		 gdb_json_put(struct gdb_json *parent, const char *key,
		     struct gdb_json *value);
size_t	 gdb_json_count(const struct gdb_json *node);
void		 gdb_json_free(struct gdb_json *node);
char		*gdb_json_render(const struct gdb_json *node);

/* gdb_sha256.c */
void		 gdb_sha256_hex(const void *data, size_t len, char out[65]);

/* gdb_core.c */
sqlite3_stmt	*gdb_prepare(struct gdb *db, const char *sql);
void		 gdb_stmt_done(struct gdb *db, sqlite3_stmt *stmt);
void		 gdb_set_error(struct gdb *db, const char *fmt, ...);
int		 gdb_exec(struct gdb *db, const char *sql);

#endif /* GDB_INTERNAL_H */

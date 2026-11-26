/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * cn_names.h - the shape of a table of names, written once.
 *
 * Two libraries of ours keep a table of names: the fatbin reader's table
 * of error codes (the short name of a code and the text that explains it)
 * and libnvrm's table of reasons (the same two things).  The data of the
 * two tables is different, but the shape of an entry, the way an entry is
 * written and the check that a code is in the table are the same, so they
 * live here, once.  A copy of the shape in two files is a copy of the
 * shape that can drift.
 *
 * Both libraries include this file.  The fatbin reader includes it from
 * its own directory (cnfatbin.c is compiled without an include path of
 * its own, so the header has to sit next to it); libnvrm reaches it with
 * -I${.CURDIR}/../cuda-native/fatbin, the same way lib/libcuda reaches
 * ../cuda-native/sdk/include.
 */

#ifndef CN_NAMES_H
#define CN_NAMES_H

#include <stddef.h>

/*
 * One entry of a table of names: the short name of a code, and the text
 * that explains it.
 */
struct cn_name_entry {
	const char *id;		/* the short name of the code */
	const char *text;	/* the text that explains the code */
};

/*
 * CN_NAME_ENTRY(CODE, ID, TEXT): one entry of a table of names.  The code
 * is the designator, so a table keeps one entry per code and the compiler
 * says so when a code is written twice.
 */
#define CN_NAME_ENTRY(code, id, text) [code] = { (id), (text) }

/*
 * cn_name_code_valid(CODE, COUNT): whether CODE is a code of a table with
 * COUNT entries.  A code that is not in the table has no name and no
 * text, and both libraries answer it the same way.
 */
static inline int
cn_name_code_valid(int code, size_t count)
{
	return (code >= 0 && (size_t)code < count);
}

#endif /* CN_NAMES_H */

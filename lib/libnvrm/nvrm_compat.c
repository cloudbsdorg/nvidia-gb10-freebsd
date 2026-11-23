/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * nvrm_compat.c - the NVRM_1.0 versions of the calls whose answer grew after
 * 1.0.  A program linked against NVRM_1.0 walks nvrm_info_field() up to
 * nvrm_info_nfields(); it must meet only the rows and kinds it knew then, at
 * the indexes it knew, so these two return the first NVRM_NFIELDS_1_0 rows of
 * the table (later rows are appended after them).  New links bind to the
 * default versions in nvrm_fields.c (NVRM_1.2).
 *
 * Compiled only into the shared library (NVRM_SHLIB): a symbol version only
 * exists there, so the static archive and the unit-test builds carry none of
 * these names.  tests/libnvrm/compat_test.c resolves them through dlvsym on the
 * built library.
 */
#include <stddef.h>

#include "nvrm_internal.h"

#ifdef NVRM_SHLIB
unsigned
nvrm_info_nfields_1_0(void)
{
	return (NVRM_NFIELDS_1_0);
}

const nvrm_field *
nvrm_info_field_1_0(unsigned index)
{
	if (index >= NVRM_NFIELDS_1_0 ||
	    NVRM_ADDED_AFTER_1_0(nvrm_fields[index].offset))
		return (NULL);
	return (&nvrm_fields[index]);
}

__asm__(".symver nvrm_info_nfields_1_0, nvrm_info_nfields@NVRM_1.0");
__asm__(".symver nvrm_info_field_1_0, nvrm_info_field@NVRM_1.0");
#else
/* the static archive has no symbol versions: nothing to define here */
typedef int nvrm_compat_shared_only;
#endif

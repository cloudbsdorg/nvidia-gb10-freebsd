/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * nvrm_fake.h - test controls of the fake backend (not installed).
 */
#ifndef _NVRM_FAKE_H_
#define _NVRM_FAKE_H_

#include <stdint.h>

void	nvrm_fake_inject(int prop, int reason);
void	nvrm_fake_inject_value(int prop, uint64_t value);
void	nvrm_fake_inject_tpc_fail(int gpc);
void	nvrm_fake_inject_uuid_fail(int reason);
void	nvrm_fake_inject_str_fail(int prop, int reason);
void	nvrm_fake_inject_classes(const uint32_t *list, unsigned n);
void	nvrm_fake_inject_classes_fail(int reason);
void	nvrm_fake_inject_clear(void);
int	nvrm_fake_fd(void);

#endif

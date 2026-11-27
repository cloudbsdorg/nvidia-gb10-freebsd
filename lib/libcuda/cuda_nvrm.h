/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * cuda_nvrm.h - the libnvrm calls the nvrm provider makes.
 *
 * The provider loads libnvrm when it is first used, so a program that only
 * wants the synthetic devices does not need the native library at all.  The
 * calls are in one table for that reason, and for one more: a test that
 * stands a scripted kernel in front of libnvrm binds its own copy of the
 * calls into the table, and the provider then talks to that copy.
 *
 * The table is the public interface of libnvrm, unchanged: the provider
 * calls the library the way any other program calls it.
 */
#ifndef CUDA_NATIVE_CUDA_NVRM_H_
#define CUDA_NATIVE_CUDA_NVRM_H_

#include <stddef.h>

#include <nvrm/nvrm.h>

typedef struct cuda_nvrm_api {
	int	(*enumerate)(nvrm_ctx **ctxp, const nvrm_enum_opts *opts,
		    char *err, size_t errlen);
	void	(*close)(nvrm_ctx *ctx);
	unsigned (*device_count)(const nvrm_ctx *ctx);
	nvrm_device *(*device_get)(const nvrm_ctx *ctx, unsigned index);
	const nvrm_device_info *(*device_info_get)(const nvrm_device *dev);
	int	(*client_open)(const nvrm_device *dev,
		    const nvrm_open_opts *opts, nvrm_client **clp, char *err,
		    size_t errlen);
	void	(*client_close)(nvrm_client *cl);
	const char *(*client_errmsg)(const nvrm_client *cl);
	int	(*va_reserve)(nvrm_client *cl, const nvrm_va_params *p,
		    uint64_t *va);
	int	(*va_release)(nvrm_client *cl, uint64_t va);
	int	(*mem_alloc)(nvrm_client *cl, const nvrm_mem_params *p,
		    nvrm_mem **memp);
	void	(*mem_free)(nvrm_mem *mem);
	int	(*mem_info_get)(const nvrm_mem *mem, nvrm_mem_info *info);
	int	(*mem_map_gpu)(nvrm_mem *mem, const nvrm_gpu_map_params *p);
	int	(*mem_unmap_gpu)(nvrm_mem *mem, uint64_t va);
	int	(*mem_map_cpu)(nvrm_mem *mem, unsigned prot, void **addr);
	int	(*mem_unmap_cpu)(nvrm_mem *mem);
	int	(*mem_read)(nvrm_mem *mem, uint64_t offset, void *buf,
		    size_t len);
	int	(*mem_write)(nvrm_mem *mem, uint64_t offset, const void *buf,
		    size_t len);
	const char *(*cap_name)(unsigned index);
	const nvrm_version *(*library_version)(void);
} cuda_nvrm_api;

/* Bind the calls of the provider.  The table is the caller's own: the
 * provider uses it and never loads the library again.  A test binds the
 * copy of libnvrm it compiled into itself, so that the scripted kernel it
 * installed is the one the provider talks to. */
void cudaNvrmBindApi(const cuda_nvrm_api *api);

#endif

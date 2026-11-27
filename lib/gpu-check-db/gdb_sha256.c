/* gdb_sha256.c - the hash of a blob.
 *
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * A blob is named by the hash of its bytes, so the same bytes are
 * stored once and a reader can tell that two blobs are the same.  This
 * is the FIPS 180-4 SHA-256.
 */
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "gdb_internal.h"

struct gdb_sha256 {
	uint32_t	state[8];
	uint64_t	bits;
	unsigned char	block[64];
	size_t		used;
};

static const uint32_t gdb_sha256_k[64] = {
	0x428a2f98U, 0x71374491U, 0xb5c0fbcfU, 0xe9b5dba5U,
	0x3956c25bU, 0x59f111f1U, 0x923f82a4U, 0xab1c5ed5U,
	0xd807aa98U, 0x12835b01U, 0x243185beU, 0x550c7dc3U,
	0x72be5d74U, 0x80deb1feU, 0x9bdc06a7U, 0xc19bf174U,
	0xe49b69c1U, 0xefbe4786U, 0x0fc19dc6U, 0x240ca1ccU,
	0x2de92c6fU, 0x4a7484aaU, 0x5cb0a9dcU, 0x76f988daU,
	0x983e5152U, 0xa831c66dU, 0xb00327c8U, 0xbf597fc7U,
	0xc6e00bf3U, 0xd5a79147U, 0x06ca6351U, 0x14292967U,
	0x27b70a85U, 0x2e1b2138U, 0x4d2c6dfcU, 0x53380d13U,
	0x650a7354U, 0x766a0abbU, 0x81c2c92eU, 0x92722c85U,
	0xa2bfe8a1U, 0xa81a664bU, 0xc24b8b70U, 0xc76c51a3U,
	0xd192e819U, 0xd6990624U, 0xf40e3585U, 0x106aa070U,
	0x19a4c116U, 0x1e376c08U, 0x2748774cU, 0x34b0bcb5U,
	0x391c0cb3U, 0x4ed8aa4aU, 0x5b9cca4fU, 0x682e6ff3U,
	0x748f82eeU, 0x78a5636fU, 0x84c87814U, 0x8cc70208U,
	0x90befffaU, 0xa4506cebU, 0xbef9a3f7U, 0xc67178f2U
};

#define ROR(x, n)	(((x) >> (n)) | ((x) << (32 - (n))))

static void
gdb_sha256_block(struct gdb_sha256 *ctx, const unsigned char *block)
{
	uint32_t w[64];
	uint32_t a, b, c, d, e, f, g, h;
	int i;

	for (i = 0; i < 16; i++)
		w[i] = ((uint32_t)block[i * 4] << 24) |
		    ((uint32_t)block[i * 4 + 1] << 16) |
		    ((uint32_t)block[i * 4 + 2] << 8) |
		    (uint32_t)block[i * 4 + 3];
	for (i = 16; i < 64; i++) {
		uint32_t s0 = ROR(w[i - 15], 7) ^ ROR(w[i - 15], 18) ^
		    (w[i - 15] >> 3);
		uint32_t s1 = ROR(w[i - 2], 17) ^ ROR(w[i - 2], 19) ^
		    (w[i - 2] >> 10);

		w[i] = w[i - 16] + s0 + w[i - 7] + s1;
	}
	a = ctx->state[0];
	b = ctx->state[1];
	c = ctx->state[2];
	d = ctx->state[3];
	e = ctx->state[4];
	f = ctx->state[5];
	g = ctx->state[6];
	h = ctx->state[7];
	for (i = 0; i < 64; i++) {
		uint32_t s1 = ROR(e, 6) ^ ROR(e, 11) ^ ROR(e, 25);
		uint32_t ch = (e & f) ^ ((~e) & g);
		uint32_t t1 = h + s1 + ch + gdb_sha256_k[i] + w[i];
		uint32_t s0 = ROR(a, 2) ^ ROR(a, 13) ^ ROR(a, 22);
		uint32_t maj = (a & b) ^ (a & c) ^ (b & c);
		uint32_t t2 = s0 + maj;

		h = g;
		g = f;
		f = e;
		e = d + t1;
		d = c;
		c = b;
		b = a;
		a = t1 + t2;
	}
	ctx->state[0] += a;
	ctx->state[1] += b;
	ctx->state[2] += c;
	ctx->state[3] += d;
	ctx->state[4] += e;
	ctx->state[5] += f;
	ctx->state[6] += g;
	ctx->state[7] += h;
}

static void
gdb_sha256_init(struct gdb_sha256 *ctx)
{
	ctx->state[0] = 0x6a09e667U;
	ctx->state[1] = 0xbb67ae85U;
	ctx->state[2] = 0x3c6ef372U;
	ctx->state[3] = 0xa54ff53aU;
	ctx->state[4] = 0x510e527fU;
	ctx->state[5] = 0x9b05688cU;
	ctx->state[6] = 0x1f83d9abU;
	ctx->state[7] = 0x5be0cd19U;
	ctx->bits = 0;
	ctx->used = 0;
}

static void
gdb_sha256_update(struct gdb_sha256 *ctx, const void *data, size_t len)
{
	const unsigned char *p = data;

	ctx->bits += (uint64_t)len * 8;
	while (len > 0) {
		size_t take = 64 - ctx->used;

		if (take > len)
			take = len;
		memcpy(ctx->block + ctx->used, p, take);
		ctx->used += take;
		p += take;
		len -= take;
		if (ctx->used == 64) {
			gdb_sha256_block(ctx, ctx->block);
			ctx->used = 0;
		}
	}
}

static void
gdb_sha256_final(struct gdb_sha256 *ctx, char out[65])
{
	unsigned char tail[8];
	unsigned char pad[72];
	size_t padlen;
	uint64_t bits = ctx->bits;
	int i;

	for (i = 0; i < 8; i++)
		tail[i] = (unsigned char)(bits >> (56 - i * 8));
	padlen = (ctx->used < 56) ? (56 - ctx->used) : (120 - ctx->used);
	memset(pad, 0, sizeof(pad));
	pad[0] = 0x80;
	gdb_sha256_update(ctx, pad, padlen);
	ctx->bits = bits;
	gdb_sha256_update(ctx, tail, 8);
	for (i = 0; i < 8; i++)
		snprintf(out + i * 8, 9, "%08x", ctx->state[i]);
	out[64] = '\0';
}

void
gdb_sha256_hex(const void *data, size_t len, char out[65])
{
	struct gdb_sha256 ctx;

	gdb_sha256_init(&ctx);
	gdb_sha256_update(&ctx, data, len);
	gdb_sha256_final(&ctx, out);
}

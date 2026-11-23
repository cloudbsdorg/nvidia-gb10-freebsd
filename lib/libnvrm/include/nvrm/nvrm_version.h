/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * <nvrm/nvrm_version.h> - bounded, freestanding version parsing.
 *
 * A version retains its source string and exposes up to six uint32_t parts.
 * Input is at most 255 bytes.  A missing part reads as zero to consumers that
 * use the fixed major/minor/patch slots; nparts records what was present and
 * width records each part's digit count, including leading zeroes.  A suffix
 * begins at '-' or '+' and is retained, including that delimiter.  The parser
 * accepts base 10 or base 16.  An empty or non-numeric string, too many parts,
 * an overflowing part, an overlong suffix, or another malformed input is not
 * available and has reason "version_unparsed".  An unavailable value retains
 * as much of its source string as fits.
 *
 * nvrm_version_find scans a banner from left to right and selects the first
 * whitespace-separated token which starts with a digit and parses in base 10
 * with at least two parts.  nvrm_version_format preserves an accepted parsed
 * string exactly; for a caller-built value with an empty string it uses the
 * parts, widths and suffix.  Thus format(parse(s)) is s, and parsing a
 * formatted caller-built value returns the same parts.  No function allocates
 * or calls libc, so this header is suitable for a FreeBSD kernel module.
 *
 * Parse and find return 0 for an available version and -1 otherwise.  Format
 * returns 0 on success and -1 for an invalid value or insufficient buffer.
 */
#ifndef _NVRM_NVRM_VERSION_H_
#define _NVRM_NVRM_VERSION_H_

#ifdef _KERNEL
#include <sys/types.h>
#include <sys/stdint.h>
#else
#include <stddef.h>
#include <stdint.h>
#endif

#define NVRM_VERSION_STRING_MAX	255
#define NVRM_VERSION_SUFFIX_MAX	63
#define NVRM_VERSION_MAX_PARTS	6

typedef struct nvrm_version {
	char		string[NVRM_VERSION_STRING_MAX + 1];
	uint32_t	parts[NVRM_VERSION_MAX_PARTS];
	uint8_t		width[NVRM_VERSION_MAX_PARTS];
	unsigned	nparts;
	char		suffix[NVRM_VERSION_SUFFIX_MAX + 1];
	int		available;
	const char	*reason;
} nvrm_version;

static inline void
nvrm_version__zero(nvrm_version *v)
{
	size_t i;

	for (i = 0; i < sizeof(*v); i++)
		((unsigned char *)v)[i] = 0;
}

static inline int
nvrm_version__unparsed(nvrm_version *v)
{
	unsigned i;

	v->available = 0;
	v->nparts = 0;
	for (i = 0; i < NVRM_VERSION_MAX_PARTS; i++) {
		v->parts[i] = 0;
		v->width[i] = 0;
	}
	v->suffix[0] = '\0';
	v->reason = "version_unparsed";
	return (-1);
}

static inline int
nvrm_version__digit(char c, unsigned base)
{
	unsigned d;

	if (c >= '0' && c <= '9')
		d = (unsigned)(c - '0');
	else if (c >= 'a' && c <= 'f')
		d = (unsigned)(c - 'a') + 10;
	else if (c >= 'A' && c <= 'F')
		d = (unsigned)(c - 'A') + 10;
	else
		return (-1);
	return (d < base ? (int)d : -1);
}

static inline int
nvrm_version__space(char c)
{
	return (c == ' ' || c == '\t' || c == '\n' || c == '\r' ||
	    c == '\f' || c == '\v');
}

static inline int
nvrm_version_parse(const char *s, unsigned base, nvrm_version *out)
{
	const char *p;
	size_t i;

	if (out == 0)
		return (-1);
	nvrm_version__zero(out);
	if (s == 0)
		return (nvrm_version__unparsed(out));
	for (i = 0; i < NVRM_VERSION_STRING_MAX && s[i] != '\0'; i++)
		out->string[i] = s[i];
	out->string[i] = '\0';
	if (s[i] != '\0' || (base != 10 && base != 16))
		return (nvrm_version__unparsed(out));

	p = s;
	for (;;) {
		uint32_t value = 0;
		unsigned width = 0;
		int d;

		if (out->nparts >= NVRM_VERSION_MAX_PARTS)
			return (nvrm_version__unparsed(out));
		while ((d = nvrm_version__digit(*p, base)) >= 0) {
			if (value > (UINT32_MAX - (uint32_t)d) / base)
				return (nvrm_version__unparsed(out));
			value = value * base + (uint32_t)d;
			width++;
			p++;
		}
		if (width == 0)
			return (nvrm_version__unparsed(out));
		out->parts[out->nparts] = value;
		out->width[out->nparts] = (uint8_t)width;
		out->nparts++;
		if (*p == '.') {
			p++;
			continue;
		}
		if (*p == '-' || *p == '+') {
			i = 0;
			while (p[i] != '\0') {
				if (i >= NVRM_VERSION_SUFFIX_MAX)
					return (nvrm_version__unparsed(out));
				out->suffix[i] = p[i];
				i++;
			}
			out->suffix[i] = '\0';
			break;
		}
		if (*p != '\0')
			return (nvrm_version__unparsed(out));
		break;
	}
	out->available = 1;
	out->reason = 0;
	return (0);
}

static inline int
nvrm_version_find(const char *banner, nvrm_version *out)
{
	const char *p, *start;
	char token[NVRM_VERSION_STRING_MAX + 1];
	size_t len, i;

	if (out == 0)
		return (-1);
	nvrm_version__zero(out);
	if (banner == 0)
		return (nvrm_version__unparsed(out));
	p = banner;
	while (*p != '\0') {
		while (nvrm_version__space(*p))
			p++;
		if (*p == '\0')
			break;
		start = p;
		while (*p != '\0' && !nvrm_version__space(*p))
			p++;
		len = (size_t)(p - start);
		if (len > NVRM_VERSION_STRING_MAX || *start < '0' ||
		    *start > '9')
			continue;
		for (i = 0; i < len; i++)
			token[i] = start[i];
		token[len] = '\0';
		if (nvrm_version_parse(token, 10, out) == 0 &&
		    out->nparts >= 2)
			return (0);
	}
	nvrm_version__zero(out);
	return (nvrm_version__unparsed(out));
}

static inline int
nvrm_version__copy_string(const nvrm_version *v, char *buf, size_t len)
{
	size_t i, n;

	for (n = 0; n < NVRM_VERSION_STRING_MAX && v->string[n] != '\0'; n++)
		;
	if (v->string[n] != '\0' || n >= len)
		return (-1);
	for (i = 0; i <= n; i++)
		buf[i] = v->string[i];
	return (0);
}

static inline int
nvrm_version__measure(const nvrm_version *v, size_t len, size_t *need_out,
    size_t *slen_out)
{
	size_t i, need, slen = 0;

	if (v->nparts == 0 || v->nparts > NVRM_VERSION_MAX_PARTS)
		return (-1);
	while (slen < NVRM_VERSION_SUFFIX_MAX && v->suffix[slen] != '\0')
		slen++;
	if (v->suffix[slen] != '\0')
		return (-1);
	need = 1;
	for (i = 0; i < v->nparts; i++) {
		uint32_t value = v->parts[i];
		unsigned digits = 1;

		while (value >= 10) {
			value /= 10;
			digits++;
		}
		if (v->width[i] < digits)
			return (-1);
		need += v->width[i] + (i != 0 ? 1 : 0);
	}
	need += slen;
	if (need > NVRM_VERSION_STRING_MAX + 1 || need > len)
		return (-1);
	*need_out = need;
	*slen_out = slen;
	return (0);
}

static inline void
nvrm_version__put_part(uint32_t value, unsigned width, char **buf)
{
	char digits[10];
	unsigned nd = 0, pad;
	char *q = *buf;

	if (value == 0)
		digits[nd++] = '0';
	while (value != 0) {
		digits[nd++] = (char)('0' + value % 10);
		value /= 10;
	}
	for (pad = nd; pad < width; pad++)
		*q++ = '0';
	while (nd != 0)
		*q++ = digits[--nd];
	*buf = q;
}

static inline int
nvrm_version_format(const nvrm_version *v, char *buf, size_t len)
{
	size_t i, need, slen;
	char *q;

	if (v == 0 || buf == 0 || !v->available)
		return (-1);
	if (v->string[0] != '\0')
		return (nvrm_version__copy_string(v, buf, len));
	if (nvrm_version__measure(v, len, &need, &slen) != 0)
		return (-1);

	q = buf;
	for (i = 0; i < v->nparts; i++) {
		if (i != 0)
			*q++ = '.';
		nvrm_version__put_part(v->parts[i], v->width[i], &q);
	}
	for (i = 0; i < slen; i++)
		*q++ = v->suffix[i];
	*q = '\0';
	return (0);
}

#endif /* _NVRM_NVRM_VERSION_H_ */

/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-3-Clause
 *
 * gpu_model.c - the loader of a model file.  A model file is data: it says
 * which cards the mock has, what each of them is, what the providers claim
 * and which faults are scripted.  Nothing here knows a vendor: the vendor
 * ids, the device ids and the names are in the file.
 */
#include <ctype.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include "gpu_json.h"
#include "gpu_mock.h"

/* ---- names ---------------------------------------------------------------- */

static const char *const cap_names[GPU_CAP__COUNT] = {
	"dmabuf_export", "ats", "self_hosted", "display_enabled", "soc",
	"coherent_gpu_memory", "os_device_wc"
};

static const char *const generation_names[GPU_GEN__COUNT] = {
	"maxwell", "pascal", "volta", "turing", "ampere", "hopper", "ada",
	"blackwell"
};

const char *
gpu_cap_name(unsigned cap)
{
	return (cap < GPU_CAP__COUNT ? cap_names[cap] : NULL);
}

int
gpu_cap_index(const char *name)
{
	unsigned i;

	if (name == NULL)
		return (-1);
	for (i = 0; i < GPU_CAP__COUNT; i++)
		if (strcmp(cap_names[i], name) == 0)
			return ((int)i);
	return (-1);
}

const char *
gpu_generation_name(unsigned gen)
{
	return (gen < GPU_GEN__COUNT ? generation_names[gen] : NULL);
}

int
gpu_generation_index(const char *name)
{
	unsigned i;

	if (name == NULL)
		return (-1);
	for (i = 0; i < GPU_GEN__COUNT; i++)
		if (strcmp(generation_names[i], name) == 0)
			return ((int)i);
	return (-1);
}

const char *
gpu_decision_name(enum gpu_decision decision)
{
	switch (decision) {
	case GPU_DECISION_SUPPORTED:
		return ("supported");
	case GPU_DECISION_UNSUPPORTED_GENERATION:
		return ("unsupported_generation");
	case GPU_DECISION_UNSUPPORTED_FIRMWARE:
		return ("unsupported_firmware");
	case GPU_DECISION_NOT_CLAIMED:
		return ("not_claimed");
	}
	return ("unknown");
}

/* ---- helpers -------------------------------------------------------------- */

static int
read_file(const char *path, char **bufp, size_t *lenp, char *err,
    size_t errlen)
{
	FILE *f;
	char *buf = NULL;
	size_t len = 0, cap = 0;

	f = fopen(path, "rb");
	if (f == NULL) {
		snprintf(err, errlen, "cannot open %s: %s", path,
		    strerror(errno));
		return (-1);
	}
	for (;;) {
		size_t n;

		if (len + 4096 + 1 > cap) {
			char *grown = realloc(buf, cap ? cap * 2 : 8192);

			if (grown == NULL) {
				free(buf);
				fclose(f);
				snprintf(err, errlen, "out of memory");
				return (-1);
			}
			buf = grown;
			cap = cap ? cap * 2 : 8192;
		}
		n = fread(buf + len, 1, 4096, f);
		len += n;
		if (n < 4096) {
			if (ferror(f)) {
				free(buf);
				fclose(f);
				snprintf(err, errlen, "cannot read %s: %s",
				    path, strerror(errno));
				return (-1);
			}
			break;
		}
	}
	fclose(f);
	buf[len] = '\0';
	*bufp = buf;
	*lenp = len;
	return (0);
}

/* A hexadecimal id as the file writes it: "0x10de". */
static int
parse_id(const char *text, uint64_t *out)
{
	char *end = NULL;
	unsigned long v;

	if (text == NULL || text[0] == '\0')
		return (-1);
	errno = 0;
	v = strtoul(text, &end, 0);
	if (errno != 0 || end == NULL || *end != '\0')
		return (-1);
	*out = (uint64_t)v;
	return (0);
}

static int
want_string(const struct gpu_json *obj, const char *key, char *buf,
    size_t len, char *err, size_t errlen)
{
	const struct gpu_json *v = gpu_json_get(obj, key);

	if (v == NULL) {
		snprintf(err, errlen, "the member \"%s\" is missing", key);
		return (-1);
	}
	if (gpu_json_str(v, buf, len) != 0) {
		snprintf(err, errlen, "the member \"%s\" is not a string", key);
		return (-1);
	}
	return (0);
}

static int
want_int(const struct gpu_json *obj, const char *key, int64_t *out, char *err,
    size_t errlen)
{
	const struct gpu_json *v = gpu_json_get(obj, key);

	if (v == NULL) {
		snprintf(err, errlen, "the member \"%s\" is missing", key);
		return (-1);
	}
	if (gpu_json_int(v, out) != 0) {
		snprintf(err, errlen, "the member \"%s\" is not an integer",
		    key);
		return (-1);
	}
	return (0);
}

static int
want_id(const struct gpu_json *obj, const char *key, uint64_t *out, char *err,
    size_t errlen)
{
	char text[32];
	const struct gpu_json *v = gpu_json_get(obj, key);

	if (v == NULL) {
		snprintf(err, errlen, "the member \"%s\" is missing", key);
		return (-1);
	}
	if (gpu_json_str(v, text, sizeof(text)) != 0) {
		snprintf(err, errlen, "the member \"%s\" is not a string", key);
		return (-1);
	}
	if (parse_id(text, out) != 0) {
		snprintf(err, errlen, "the member \"%s\" is not a number "
		    "(\"%s\")", key, text);
		return (-1);
	}
	return (0);
}

/*
 * The array member of an object: the member itself when the object has one,
 * and nothing when it has not.
 */
static int
want_array(const struct gpu_json *obj, const char *key, const char *what,
    size_t max, const struct gpu_json **arrp, char *err, size_t errlen)
{
	const struct gpu_json *arr = gpu_json_get(obj, key);

	*arrp = NULL;
	if (arr == NULL)
		return (0);
	if (gpu_json_type(arr) != GPU_JSON_ARRAY) {
		snprintf(err, errlen, "\"%s\" is not an array", key);
		return (-1);
	}
	if (gpu_json_count(arr) > max) {
		snprintf(err, errlen, "the model has too many %s", what);
		return (-1);
	}
	*arrp = arr;
	return (0);
}

/*
 * An optional string member of an entry: its text when the member is there,
 * and nothing when it is not.
 */
static int
want_string_opt(const struct gpu_json *obj, const char *key, char *buf,
    size_t len, const char *noun, const char *name, char *err, size_t errlen)
{
	const struct gpu_json *v = gpu_json_get(obj, key);

	if (v == NULL)
		return (0);
	if (gpu_json_str(v, buf, len) != 0) {
		snprintf(err, errlen, "the %s \"%s\" has a \"%s\" that is not "
		    "a string", noun, name, key);
		return (-1);
	}
	return (0);
}

/* An optional number member: its value, when the member is there. */
static int
want_uint_opt(const struct gpu_json *obj, const char *key, uint64_t *out,
    const char *noun, const char *name, char *err, size_t errlen)
{
	const struct gpu_json *v = gpu_json_get(obj, key);
	int64_t n;

	if (v == NULL)
		return (0);
	if (gpu_json_int(v, &n) != 0 || n < 0) {
		snprintf(err, errlen, "the %s \"%s\" has a \"%s\" that is not "
		    "a number", noun, name, key);
		return (-1);
	}
	*out = (uint64_t)n;
	return (0);
}

/*
 * The members of an entry are read with these: each names the member of the
 * model file and where it goes.  The reader of the member says what went
 * wrong; the macro turns that into the error of the entry.
 */
#define WANT_STRING(obj, key, buf)					\
	do {								\
		if (want_string((obj), (key), (buf), sizeof(buf), err,	\
		    errlen) != 0)					\
			return (-1);					\
	} while (0)

#define WANT_INT(obj, key, out)						\
	do {								\
		if (want_int((obj), (key), (out), err, errlen) != 0)	\
			return (-1);					\
	} while (0)

#define WANT_ID(obj, key, out)						\
	do {								\
		if (want_id((obj), (key), (out), err, errlen) != 0)	\
			return (-1);					\
	} while (0)

#define WANT_STRING_OPT(obj, key, buf, noun, who)			\
	do {								\
		if (want_string_opt((obj), (key), (buf), sizeof(buf),	\
		    (noun), (who), err, errlen) != 0)			\
			return (-1);					\
	} while (0)

#define WANT_UINT_OPT(obj, key, out, noun, who)			\
	do {								\
		if (want_uint_opt((obj), (key), (out), (noun), (who), err,	\
		    errlen) != 0)					\
			return (-1);					\
	} while (0)

/* A version member: the string and every part as an integer. */
static int
want_version(const struct gpu_json *obj, const char *key,
    struct gpu_version *out, char *err, size_t errlen)
{
	const struct gpu_json *v = gpu_json_get(obj, key);
	const struct gpu_json *s;
	int64_t major, minor, patch;

	if (v == NULL) {
		snprintf(err, errlen, "the member \"%s\" is missing", key);
		return (-1);
	}
	if (gpu_json_type(v) != GPU_JSON_OBJECT) {
		snprintf(err, errlen, "the member \"%s\" is not a version "
		    "object", key);
		return (-1);
	}
	s = gpu_json_get(v, "string");
	if (s == NULL || gpu_json_str(s, out->string, sizeof(out->string)) != 0) {
		snprintf(err, errlen, "the version \"%s\" has no \"string\"", key);
		return (-1);
	}
	if (want_int(v, "major", &major, err, errlen) != 0 ||
	    want_int(v, "minor", &minor, err, errlen) != 0 ||
	    want_int(v, "patch", &patch, err, errlen) != 0)
		return (-1);
	if (major < 0 || minor < 0 || patch < 0 || major > 0xffff ||
	    minor > 0xffff || patch > 0xffff) {
		snprintf(err, errlen, "the version \"%s\" has a part out of "
		    "range", out->string);
		return (-1);
	}
	out->major = (uint32_t)major;
	out->minor = (uint32_t)minor;
	out->patch = (uint32_t)patch;
	out->available = 1;
	return (0);
}

/* The capability flags of an object: the names it sets and their values. */
static int
read_caps(const struct gpu_json *obj, uint32_t *caps, unsigned *cap_set,
    char *err, size_t errlen)
{
	const struct gpu_json *v = gpu_json_get(obj, "capabilities");
	size_t i;

	if (v == NULL)
		return (0);
	if (gpu_json_type(v) != GPU_JSON_OBJECT) {
		snprintf(err, errlen, "\"capabilities\" is not an object");
		return (-1);
	}
	for (i = 0; i < gpu_json_count(v); i++) {
		const char *name = gpu_json_key(v, i);
		int index, on;

		index = gpu_cap_index(name);
		if (index < 0) {
			snprintf(err, errlen, "\"capabilities\" names the "
			    "unknown flag \"%s\"", name);
			return (-1);
		}
		if (gpu_json_bool(gpu_json_get(v, name), &on) != 0) {
			snprintf(err, errlen, "the capability \"%s\" is not "
			    "a boolean", name);
			return (-1);
		}
		caps[index] = on ? 1u : 0u;
		if (cap_set != NULL)
			cap_set[index] = 1;
	}
	return (0);
}

/*
 * A list of values the model file holds: the ids of a provider, the masks
 * and the numbers of a base.  The values go into the array of the list, and
 * the list says how many of them there are and what they are called.
 */
struct value_list {
	uint64_t	*values;	/* where the values go */
	unsigned	 n;		/* how many there are */
	unsigned	 max;		/* how many fit */
	const char	*noun;		/* what holds them: "provider" */
	const char	*one;		/* the name of one of them */
	const char	*many;		/* the name of them all */
	const char	*name;		/* the name of the holder */
};

/* The list of values of an entry: the values go into the array of the
 * entry, and the list says what they are called. */
#define VALUE_LIST(values, max, noun, one, many, holder)		\
	(struct value_list){ (values), 0, (max), (noun), (one), (many),	\
	    (holder) }

/*
 * An array of entries the model file holds: the providers, the bases, the
 * boards, the cards and the faults.  Every one of them is an array of
 * entries of one kind, read by the reader of that kind, so one loop reads
 * them all.
 */
struct entry_array {
	const char	*key;		/* the member of the model file */
	void		*entries;	/* the entries themselves */
	unsigned	*n;		/* how many there are */
	unsigned	 max;		/* how many fit */
	size_t		 stride;	/* the size of one entry */
	struct gpu_model *model;	/* the model the entries belong to */
	int		(*read)(const struct gpu_json *obj, void *entry,
		    struct gpu_model *model, char *err, size_t errlen);
};

/*
 * The array of one kind of entry: the macro says where the array is in the
 * model and which reader reads its entries.
 */
#define ENTRIES_OF(model, member, reader)				\
	{ #member, model->member, &model->n##member,			\
	  sizeof(model->member) / sizeof(model->member[0]),		\
	  sizeof(model->member[0]), model, reader }

/* The ids of an array: the hexadecimal strings the file writes. */
static int
read_ids(const struct gpu_json *arr, struct value_list *list, char *err,
    size_t errlen)
{
	unsigned j;

	for (j = 0; j < gpu_json_count(arr); j++) {
		char text[32];
		uint64_t id;

		if (gpu_json_str(gpu_json_at(arr, j), text, sizeof(text)) != 0 ||
		    parse_id(text, &id) != 0) {
			snprintf(err, errlen, "the %s \"%s\" has a %s that is "
			    "not a number", list->noun, list->name, list->one);
			return (-1);
		}
		if (list->n >= list->max) {
			snprintf(err, errlen, "the %s \"%s\" has too many %s",
			    list->noun, list->name, list->many);
			return (-1);
		}
		list->values[list->n++] = id;
	}
	return (0);
}

/* The numbers of an array: the classes and the page sizes of a base. */
static int
read_numbers(const struct gpu_json *arr, struct value_list *list, char *err,
    size_t errlen)
{
	unsigned j;

	for (j = 0; j < gpu_json_count(arr); j++) {
		int64_t n;

		if (gpu_json_int(gpu_json_at(arr, j), &n) != 0) {
			snprintf(err, errlen, "the %s \"%s\" has a %s that is "
			    "not a number", list->noun, list->name, list->one);
			return (-1);
		}
		if (list->n >= list->max) {
			snprintf(err, errlen, "the %s \"%s\" has too many %s",
			    list->noun, list->name, list->many);
			return (-1);
		}
		list->values[list->n++] = (uint64_t)n;
	}
	return (0);
}

/* The ids of a list, in the 16 bits the model keeps them in. */
static void
copy_ids(uint16_t *dst, const uint64_t *src, unsigned n)
{
	unsigned i;

	for (i = 0; i < n; i++)
		dst[i] = (uint16_t)src[i];
}

/* ---- the model ------------------------------------------------------------ */

/* The directory of the installed model files. */
#ifndef GPU_MOCK_MODEL_DIR
#define GPU_MOCK_MODEL_DIR	"/usr/local/share/nvidia-gb10-freebsd/models"
#endif
/* The environment variable that names the model directory. */
#define GPU_MOCK_DIR_ENV	"GPU_MOCK_DIR"
/*
 * The model files of the checkout the mock was built in.  The build
 * script generates the header and names the directory; a mock that is
 * built without it (a test that compiles the model loader on its own) has
 * no checkout behind it and uses the installed models.
 */
#if defined(__has_include)
#if __has_include("modeldir.h")
#include "modeldir.h"
#endif
#endif
#ifdef GB10_GPU_MOCK_SOURCE_MODELS
#define SOURCE_MODELS_DIR	GB10_GPU_MOCK_SOURCE_MODELS
#endif

/*
 * The path of a model file: the name as a path when it holds a slash, else
 * the name under the model directory.  The environment directory comes first,
 * so a test and a developer tree can use their own models.  Then the
 * installed directory, then the checkout the mock was built in, so a mock
 * that is run from the tree finds the models of the tree.
 */
int
gpu_model_path(const char *name, char *buf, size_t len)
{
	const char *dir = getenv(GPU_MOCK_DIR_ENV);
	char probe[1024];
	struct stat st;

	if (name == NULL || name[0] == '\0' || buf == NULL || len == 0)
		return (-1);
	if (strchr(name, '/') != NULL) {
		snprintf(buf, len, "%s", name);
		return (0);
	}
	if (dir != NULL && dir[0] != '\0') {
		snprintf(probe, sizeof(probe), "%s/%s.json", dir, name);
		if (stat(probe, &st) == 0) {
			snprintf(buf, len, "%s", probe);
			return (0);
		}
	}
	snprintf(probe, sizeof(probe), "%s/%s.json", GPU_MOCK_MODEL_DIR, name);
	if (stat(probe, &st) == 0) {
		snprintf(buf, len, "%s", probe);
		return (0);
	}
#ifdef SOURCE_MODELS_DIR
	snprintf(probe, sizeof(probe), "%s/%s.json", SOURCE_MODELS_DIR, name);
	if (stat(probe, &st) == 0) {
		snprintf(buf, len, "%s", probe);
		return (0);
	}
#endif
	return (-1);
}

/* The ids a provider claims: the vendor ids and the device ids. */
static int
read_provider_ids(const struct gpu_json *p, struct gpu_provider *pv, char *err,
    size_t errlen)
{
	const struct gpu_json *arr;
	uint64_t values[sizeof(pv->device_ids) / sizeof(pv->device_ids[0])];
	struct value_list list;

	/* The vendor ids: the member is required. */
	arr = gpu_json_get(p, "vendor_ids");
	if (arr == NULL) {
		snprintf(err, errlen, "the provider \"%s\" has no "
		    "\"vendor_ids\"", pv->name);
		return (-1);
	}
	list = VALUE_LIST(values, sizeof(pv->vendor_ids) /
	    sizeof(pv->vendor_ids[0]), "provider", "vendor id", "vendor ids",
	    pv->name);
	if (read_ids(arr, &list, err, errlen) != 0)
		return (-1);
	copy_ids(pv->vendor_ids, values, list.n);
	pv->nvendor_ids = list.n;

	/* The device ids: the member is optional. */
	arr = gpu_json_get(p, "device_ids");
	if (arr == NULL)
		return (0);
	list = VALUE_LIST(values, sizeof(pv->device_ids) /
	    sizeof(pv->device_ids[0]), "provider", "device id", "device ids",
	    pv->name);
	if (read_ids(arr, &list, err, errlen) != 0)
		return (-1);
	copy_ids(pv->device_ids, values, list.n);
	pv->ndevice_ids = list.n;
	return (0);
}

/* The backends a provider drives through. */
static int
read_provider_backends(const struct gpu_json *p, struct gpu_provider *pv,
    char *err, size_t errlen)
{
	const struct gpu_json *arr = gpu_json_get(p, "backends");
	unsigned j;

	if (arr == NULL)
		return (0);
	for (j = 0; j < gpu_json_count(arr); j++) {
		char name[64];

		if (gpu_json_str(gpu_json_at(arr, j), name, sizeof(name)) != 0) {
			snprintf(err, errlen, "the provider \"%s\" has a "
			    "backend that is not a name", pv->name);
			return (-1);
		}
		if (pv->nbackends >=
		    sizeof(pv->backends) / sizeof(pv->backends[0])) {
			snprintf(err, errlen, "the provider \"%s\" has too "
			    "many backends", pv->name);
			return (-1);
		}
		snprintf(pv->backends[pv->nbackends++], sizeof(pv->backends[0]),
		    "%s", name);
	}
	return (0);
}

/* The generations a provider drives, with the firmware of each. */
static int
read_provider_generations(const struct gpu_json *p, struct gpu_provider *pv,
    char *err, size_t errlen)
{
	const struct gpu_json *arr = gpu_json_get(p, "generations");
	unsigned j;

	if (arr == NULL)
		return (0);
	for (j = 0; j < gpu_json_count(arr); j++) {
		const struct gpu_json *g = gpu_json_at(arr, j);
		char name[32];
		int gen;
		int avail = 0;

		if (gpu_json_str(gpu_json_get(g, "name"), name,
		    sizeof(name)) != 0) {
			snprintf(err, errlen, "the provider \"%s\" has a "
			    "generation without a name", pv->name);
			return (-1);
		}
		gen = gpu_generation_index(name);
		if (gen < 0) {
			snprintf(err, errlen, "the provider \"%s\" names the "
			    "unknown generation \"%s\"", pv->name, name);
			return (-1);
		}
		if (gpu_json_bool(gpu_json_get(g, "firmware_available"),
		    &avail) != 0) {
			snprintf(err, errlen, "the generation \"%s\" of the "
			    "provider \"%s\" has no \"firmware_available\"",
			    name, pv->name);
			return (-1);
		}
		if (pv->n_generations >=
		    sizeof(pv->generations) / sizeof(pv->generations[0])) {
			snprintf(err, errlen, "the provider \"%s\" has too "
			    "many generations", pv->name);
			return (-1);
		}
		pv->generations[pv->n_generations].generation = (unsigned)gen;
		snprintf(pv->generations[pv->n_generations].firmware,
		    sizeof(pv->generations[0].firmware), "%s", "");
		if (gpu_json_str(gpu_json_get(g, "firmware"),
		    pv->generations[pv->n_generations].firmware,
		    sizeof(pv->generations[0].firmware)) != 0)
			snprintf(pv->generations[pv->n_generations].firmware,
			    sizeof(pv->generations[0].firmware), "%s", "");
		pv->generations[pv->n_generations].firmware_available = avail;
		pv->n_generations++;
	}
	return (0);
}

/* The generation a provider starts at: the floor of what it drives. */
static int
read_provider_floor(const struct gpu_json *p, struct gpu_provider *pv,
    char *err, size_t errlen)
{
	const struct gpu_json *v = gpu_json_get(p, "min_generation");
	char name[32];
	int gen;

	if (v == NULL)
		return (0);
	if (gpu_json_str(v, name, sizeof(name)) != 0) {
		snprintf(err, errlen, "the provider \"%s\" has a "
		    "\"min_generation\" that is not a name", pv->name);
		return (-1);
	}
	gen = gpu_generation_index(name);
	if (gen < 0) {
		snprintf(err, errlen, "the provider \"%s\" names the unknown "
		    "generation \"%s\"", pv->name, name);
		return (-1);
	}
	pv->min_generation = (unsigned)gen;
	snprintf(pv->min_generation_name, sizeof(pv->min_generation_name),
	    "%s", name);
	return (0);
}

/* One provider of the model. */
static int
read_provider(const struct gpu_json *p, void *entry, struct gpu_model *model,
    char *err, size_t errlen)
{
	struct gpu_provider *pv = entry;
	int64_t score;

	WANT_STRING(p, "name", pv->name);
	WANT_INT(p, "score", &score);
	pv->score = (int)score;
	if (read_provider_ids(p, pv, err, errlen) != 0)
		return (-1);
	if (read_provider_floor(p, pv, err, errlen) != 0)
		return (-1);
	if (read_provider_backends(p, pv, err, errlen) != 0)
		return (-1);
	return (read_provider_generations(p, pv, err, errlen));
}

/* The TPC masks of a base: the masks of each GPC. */
static int
read_base_masks(const struct gpu_json *b, struct gpu_base *base, char *err,
    size_t errlen)
{
	const struct gpu_json *arr = gpu_json_get(b, "tpc_masks");
	struct value_list list;

	if (arr == NULL)
		return (0);
	list = VALUE_LIST(base->tpc_masks, GPU_RM_MAX_GPCS, "base", "TPC mask",
	    "TPC masks", base->name);
	if (read_ids(arr, &list, err, errlen) != 0)
		return (-1);
	base->ntpc_masks = list.n;
	return (0);
}

/*
 * A list of numbers of a base: the classes or the page sizes.  The list
 * says where the numbers go and what they are called.
 */
struct base_list {
	const char	*key;		/* the member of the model file */
	uint64_t	*values;	/* where the numbers go */
	unsigned	 max;		/* how many fit */
	unsigned	*n;		/* how many there are */
	const char	*one;		/* the name of one of them */
	const char	*many;		/* the name of them all */
	const char	*name;		/* the name of the base */
	int		required;	/* the member must be there */
};

/* The numbers of one list of a base. */
static int
read_base_list(const struct gpu_json *b, struct base_list *list, char *err,
    size_t errlen)
{
	const struct gpu_json *arr = gpu_json_get(b, list->key);
	struct value_list values;

	if (arr == NULL) {
		if (!list->required)
			return (0);
		snprintf(err, errlen, "the base \"%s\" has no \"%s\"",
		    list->name, list->key);
		return (-1);
	}
	values = VALUE_LIST(list->values, list->max, "base", list->one,
	    list->many, list->name);
	if (read_numbers(arr, &values, err, errlen) != 0)
		return (-1);
	*list->n = values.n;
	return (0);
}

/* The classes of a base: the classes its cards have. */
static int
read_base_classes(const struct gpu_json *b, struct gpu_base *base, char *err,
    size_t errlen)
{
	struct base_list list = {
		"classes", base->classes, sizeof(base->classes) /
		    sizeof(base->classes[0]), &base->nclasses, "class", "classes",
		base->name, 1
	};

	return (read_base_list(b, &list, err, errlen));
}

/* The page sizes of a base: the sizes its cards map with. */
static int
read_base_pages(const struct gpu_json *b, struct gpu_base *base, char *err,
    size_t errlen)
{
	struct base_list list = {
		"page_sizes", base->page_sizes, sizeof(base->page_sizes) /
		    sizeof(base->page_sizes[0]), &base->npage_sizes, "page size",
		"page sizes", base->name, 0
	};

	return (read_base_list(b, &list, err, errlen));
}

/* The BIOS of a base: its revisions and its firmware version. */
static int
read_base_bios(const struct gpu_json *b, struct gpu_base *base, char *err,
    size_t errlen)
{
	const struct gpu_json *v;

	WANT_UINT_OPT(b, "bios_revision", &base->bios_revision, "base",
	    base->name);
	WANT_UINT_OPT(b, "bios_oem_revision", &base->bios_oem_revision, "base",
	    base->name);
	v = gpu_json_get(b, "firmware_version");
	if (v != NULL &&
	    gpu_json_str(v, base->firmware_version,
	    sizeof(base->firmware_version)) != 0) {
		snprintf(err, errlen, "the base \"%s\" has a "
		    "\"firmware_version\" that is not a string", base->name);
		return (-1);
	}
	return (0);
}

/* One base: the generation every board of it shares. */
static int
read_base(const struct gpu_json *b, void *entry, struct gpu_model *model,
    char *err, size_t errlen)
{
	struct gpu_base *base = entry;
	char name[32];
	uint64_t id;
	int64_t n;
	int gen;

	WANT_STRING(b, "name", base->name);
	WANT_STRING(b, "generation", name);
	gen = gpu_generation_index(name);
	if (gen < 0) {
		snprintf(err, errlen, "the base \"%s\" names the unknown "
		    "generation \"%s\"", base->name, name);
		return (-1);
	}
	base->generation = (unsigned)gen;
	WANT_INT(b, "architecture", &n);
	base->architecture = (uint32_t)n;
	WANT_INT(b, "implementation", &n);
	base->implementation = (uint32_t)n;
	WANT_INT(b, "chip_id", &n);
	base->chip_id = (uint32_t)n;
	if (gpu_json_get(b, "sm_version") != NULL &&
	    want_version(b, "sm_version", &base->sm_version, err, errlen) != 0)
		return (-1);
	WANT_INT(b, "gpc_count", &n);
	base->gpc_count = (unsigned)n;
	WANT_INT(b, "tpc_count", &n);
	base->tpc_count = (unsigned)n;
	/* The enabled units: the masks are the truth, the counts are what
	 * they add up to. */
	if (gpu_json_get(b, "gpc_mask") != NULL) {
		WANT_ID(b, "gpc_mask", &id);
		base->gpc_mask = id;
	}
	if (read_base_masks(b, base, err, errlen) != 0)
		return (-1);
	WANT_INT(b, "sm_per_tpc", &n);
	base->sm_per_tpc = (unsigned)n;
	if (read_base_bios(b, base, err, errlen) != 0)
		return (-1);
	if (read_base_classes(b, base, err, errlen) != 0)
		return (-1);
	if (read_base_pages(b, base, err, errlen) != 0)
		return (-1);
	WANT_INT(b, "max_page_size", &n);
	base->max_page_size = (uint64_t)n;
	if (read_caps(b, base->caps, NULL, err, errlen) != 0)
		return (-1);
	return (0);
}

/* One board: the decorator over a base. */
static int
read_board(const struct gpu_json *b, void *entry, struct gpu_model *model,
    char *err, size_t errlen)
{
	struct gpu_board *board = entry;
	uint64_t id;

	WANT_STRING(b, "name", board->name);
	WANT_STRING(b, "base", board->base);
	WANT_STRING_OPT(b, "model_name", board->model_name, "board",
	    board->name);
	WANT_STRING_OPT(b, "vbios", board->vbios, "board", board->name);
	if (gpu_json_get(b, "subsystem_vendor_id") != NULL) {
		WANT_ID(b, "subsystem_vendor_id", &id);
		board->subsystem_vendor_id = (uint16_t)id;
		board->have_subsystem = 1;
	}
	if (gpu_json_get(b, "subsystem_device_id") != NULL) {
		WANT_ID(b, "subsystem_device_id", &id);
		board->subsystem_device_id = (uint16_t)id;
	}
	WANT_UINT_OPT(b, "vram_bytes", &board->vram_bytes, "board",
	    board->name);
	WANT_UINT_OPT(b, "bar1_bytes", &board->bar1_bytes, "board",
	    board->name);
	if (read_caps(b, board->caps, board->cap_set, err, errlen) != 0)
		return (-1);
	return (0);
}

static const struct gpu_base *
find_base(const struct gpu_model *model, const char *name)
{
	unsigned i;

	for (i = 0; i < model->nbases; i++)
		if (strcmp(model->bases[i].name, name) == 0)
			return (&model->bases[i]);
	return (NULL);
}

static const struct gpu_board *
find_board(const struct gpu_model *model, const char *name)
{
	unsigned i;

	for (i = 0; i < model->nboards; i++)
		if (strcmp(model->boards[i].name, name) == 0)
			return (&model->boards[i]);
	return (NULL);
}

/*
 * The merged view of a card: the base of its generation first, then the
 * overrides of the board that decorates it.  A card of no provider of ours
 * names no board: it has no base and no board.
 */
static int
finalize_card(struct gpu_model *model, struct gpu_card *card, char *err,
    size_t errlen)
{
	unsigned j;

	if (card->board_name[0] == '\0') {
		card->board = NULL;
		card->base = NULL;
		return (0);
	}
	card->board = find_board(model, card->board_name);
	if (card->board == NULL) {
		snprintf(err, errlen, "the card \"%s\" names the unknown board "
		    "\"%s\"", card->name, card->board_name);
		return (-1);
	}
	card->base = find_base(model, card->board->base);
	if (card->base == NULL) {
		snprintf(err, errlen, "the board \"%s\" names the unknown base "
		    "\"%s\"", card->board->name, card->board->base);
		return (-1);
	}
	memcpy(card->caps, card->base->caps, sizeof(card->caps));
	for (j = 0; j < GPU_CAP__COUNT; j++)
		if (card->board->cap_set[j])
			card->caps[j] = card->board->caps[j];
	card->vram_bytes = card->board->vram_bytes;
	card->bar1_bytes = card->board->bar1_bytes;
	card->max_page_size = card->base->max_page_size;
	return (0);
}

/* The ids of a card: the PCI ids and the revision. */
static int
read_card_ids(const struct gpu_json *c, struct gpu_card *card, char *err,
    size_t errlen)
{
	uint64_t id;

	WANT_ID(c, "vendor_id", &id);
	card->vendor_id = (uint16_t)id;
	WANT_ID(c, "device_id", &id);
	card->device_id = (uint16_t)id;
	if (gpu_json_get(c, "subsystem_vendor_id") != NULL) {
		WANT_ID(c, "subsystem_vendor_id", &id);
		card->subsystem_vendor_id = (uint16_t)id;
	}
	if (gpu_json_get(c, "subsystem_device_id") != NULL) {
		WANT_ID(c, "subsystem_device_id", &id);
		card->subsystem_device_id = (uint16_t)id;
	}
	if (gpu_json_get(c, "revision") != NULL) {
		WANT_ID(c, "revision", &id);
		card->revision = (uint16_t)id;
	}
	return (0);
}

/* The PCI address of a card. */
static int
read_card_pci(const struct gpu_json *c, struct gpu_card *card, char *err,
    size_t errlen)
{
	const struct gpu_json *pci = gpu_json_get(c, "pci");
	uint64_t id;
	int64_t n;

	if (pci == NULL) {
		snprintf(err, errlen, "the card \"%s\" has no \"pci\"",
		    card->name);
		return (-1);
	}
	WANT_INT(pci, "domain", &n);
	card->pci_domain = (uint16_t)n;
	WANT_INT(pci, "bus", &n);
	card->pci_bus = (uint16_t)n;
	WANT_INT(pci, "slot", &n);
	card->pci_slot = (uint16_t)n;
	WANT_INT(pci, "function", &n);
	card->pci_function = (uint16_t)n;
	WANT_ID(pci, "class", &id);
	card->pci_class = (uint32_t)id;
	return (0);
}

/*
 * The names of a card: what the tools of the system print for it.  They all
 * are optional, and each of them has a room of its own in the card.
 */
static int
read_card_names(const struct gpu_json *c, struct gpu_card *card, char *err,
    size_t errlen)
{
	struct {
		const char	*key;		/* the member of the model */
		size_t		offset;		/* where it goes in the card */
		size_t		size;		/* the room it has */
	} names[] = {
		{ "selector", offsetof(struct gpu_card, selector),
		    sizeof(card->selector) },
		{ "vendor_name", offsetof(struct gpu_card, vendor_name),
		    sizeof(card->vendor_name) },
		{ "device_name", offsetof(struct gpu_card, device_name),
		    sizeof(card->device_name) },
		{ "class_name", offsetof(struct gpu_card, class_name),
		    sizeof(card->class_name) },
		{ "subclass_name", offsetof(struct gpu_card, subclass_name),
		    sizeof(card->subclass_name) }
	};
	unsigned i;

	for (i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
		char *buf = (char *)card + names[i].offset;

		if (want_string_opt(c, names[i].key, buf, names[i].size, "card",
		    card->name, err, errlen) != 0)
			return (-1);
	}
	return (0);
}

/* The unit and the interrupt of a card. */
static int
read_card_numbers(const struct gpu_json *c, struct gpu_card *card, char *err,
    size_t errlen)
{
	uint64_t v;

	if (gpu_json_get(c, "unit") != NULL) {
		WANT_UINT_OPT(c, "unit", &v, "card", card->name);
		card->unit = (unsigned)v;
		card->have_unity = 1;
	}
	if (gpu_json_get(c, "irq") != NULL) {
		WANT_UINT_OPT(c, "irq", &v, "card", card->name);
		card->irq = (unsigned)v;
	}
	return (0);
}

/* The bars of a card: what pciconf(8) prints for them. */
static int
read_card_bars(const struct gpu_json *c, struct gpu_card *card, char *err,
    size_t errlen)
{
	const struct gpu_json *arr = gpu_json_get(c, "bars");
	uint64_t id;
	int64_t n;
	unsigned j;

	if (arr == NULL)
		return (0);
	for (j = 0; j < gpu_json_count(arr); j++) {
		const struct gpu_json *b = gpu_json_at(arr, j);
		struct gpu_bar *bar = &card->bars[card->nbars];
		const struct gpu_json *v;

		if (card->nbars >= sizeof(card->bars) / sizeof(card->bars[0])) {
			snprintf(err, errlen, "the card \"%s\" has too many "
			    "bars", card->name);
			return (-1);
		}
		memset(bar, 0, sizeof(*bar));
		WANT_INT(b, "index", &n);
		bar->index = (unsigned)n;
		WANT_STRING(b, "type", bar->type);
		WANT_INT(b, "range", &n);
		bar->range = (unsigned)n;
		WANT_ID(b, "base", &id);
		bar->base = id;
		WANT_INT(b, "size", &n);
		bar->size = (uint64_t)n;
		v = gpu_json_get(b, "enabled");
		if (v != NULL) {
			int on = 0;

			if (gpu_json_bool(v, &on) != 0) {
				snprintf(err, errlen, "the bar %u of the "
				    "card \"%s\" has an \"enabled\" that is "
				    "not a boolean", bar->index, card->name);
				return (-1);
			}
			bar->enabled = on;
		}
		card->nbars++;
	}
	return (0);
}

/* One card: the board at a PCI address, with the RM's identity. */
static int
read_card(const struct gpu_json *c, void *entry, struct gpu_model *model,
    char *err, size_t errlen)
{
	struct gpu_card *card = entry;
	int64_t n;

	WANT_STRING(c, "name", card->name);
	/*
	 * A card of a provider of ours names its board (the decorator).  A
	 * card of no provider of ours (an AMD card, a BMC display adapter)
	 * names none: it has no base and no board, and no decision is made
	 * about it.
	 */
	WANT_STRING_OPT(c, "board", card->board_name, "card", card->name);
	WANT_STRING_OPT(c, "provider", card->provider, "card", card->name);
	if (read_card_ids(c, card, err, errlen) != 0)
		return (-1);
	if (read_card_pci(c, card, err, errlen) != 0)
		return (-1);
	if (read_card_names(c, card, err, errlen) != 0)
		return (-1);
	WANT_INT(c, "rm_gpu_id", &n);
	card->rm_gpu_id = (uint32_t)n;
	WANT_STRING(c, "uuid", card->uuid);
	if (read_card_numbers(c, card, err, errlen) != 0)
		return (-1);
	if (read_card_bars(c, card, err, errlen) != 0)
		return (-1);
	/* The merged view: the base first, then the board. */
	if (finalize_card(model, card, err, errlen) != 0)
		return (-1);
	if (!card->have_unity)
		card->unit = model->ncards + 1;
	return (0);
}

/* One fault of the model: the failure it scripts. */
static int
read_fault(const struct gpu_json *f, void *entry, struct gpu_model *model,
    char *err, size_t errlen)
{
	struct gpu_fault *fault = entry;
	char kind[32];
	int64_t n;

	WANT_STRING(f, "kind", kind);
	if (strcmp(kind, "device_lost") == 0)
		fault->kind = GPU_FAULT_DEVICE_LOST;
	else if (strcmp(kind, "alloc_refused") == 0)
		fault->kind = GPU_FAULT_ALLOC_REFUSED;
	else if (strcmp(kind, "ioctl_failed") == 0)
		fault->kind = GPU_FAULT_IOCTL_FAILED;
	else {
		snprintf(err, errlen, "the fault \"%s\" names the unknown kind "
		    "\"%s\"", kind, kind);
		return (-1);
	}
	if (gpu_json_get(f, "card") != NULL)
		WANT_STRING(f, "card", fault->card);
	if (gpu_json_get(f, "object") != NULL)
		WANT_STRING(f, "object", fault->object);
	if (gpu_json_get(f, "nth") != NULL) {
		const struct gpu_json *v = gpu_json_get(f, "nth");

		if (gpu_json_int(v, &n) != 0 || n < 0) {
			snprintf(err, errlen, "the fault \"%s\" has an \"nth\" "
			    "that is not a number", kind);
			return (-1);
		}
		fault->nth = (unsigned)n;
	}
	return (0);
}

/*
 * The entries of one array of the model file: each of them is read by the
 * reader of its kind.
 */
static int
read_entries(const struct gpu_json *root, struct entry_array *a, char *err,
    size_t errlen)
{
	const struct gpu_json *arr;
	size_t i;

	if (want_array(root, a->key, a->key, a->max, &arr, err, errlen) != 0)
		return (-1);
	if (arr == NULL)
		return (0);
	for (i = 0; i < gpu_json_count(arr); i++) {
		void *entry = (char *)a->entries + *a->n * a->stride;

		memset(entry, 0, a->stride);
		if (a->read(gpu_json_at(arr, i), entry, a->model, err, errlen) != 0)
			return (-1);
		(*a->n)++;
	}
	return (0);
}

/*
 * The entries of one kind of the model file: the providers, the bases, the
 * boards, the cards or the faults.
 */
static int
read_kind(const struct gpu_json *root, struct gpu_model *model, const char *key,
    char *err, size_t errlen)
{
	struct entry_array kinds[] = {
		ENTRIES_OF(model, providers, read_provider),
		ENTRIES_OF(model, bases, read_base),
		ENTRIES_OF(model, boards, read_board),
		ENTRIES_OF(model, cards, read_card),
		ENTRIES_OF(model, faults, read_fault)
	};
	unsigned i;

	for (i = 0; i < sizeof(kinds) / sizeof(kinds[0]); i++)
		if (strcmp(kinds[i].key, key) == 0)
			return (read_entries(root, &kinds[i], err, errlen));
	return (0);
}

/*
 * The directory of a path: everything up to the last slash.  An include is
 * named relative to the file that names it.
 */
static void
dir_of(const char *path, char *buf, size_t len)
{
	const char *slash = strrchr(path, '/');
	size_t n;

	if (slash == NULL) {
		snprintf(buf, len, "%s", ".");
		return;
	}
	n = (size_t)(slash - path);
	if (n >= len)
		n = len - 1;
	memcpy(buf, path, n);
	buf[n] = '\0';
}

/*
 * An array of named entries: the providers, the bases and the boards.  The
 * name of an entry is its first member, so one merge serves them all.
 */
struct named_array {
	void		*entries;	/* the entries themselves */
	unsigned	*n;		/* how many there are */
	unsigned	 max;		/* how many fit */
	size_t		 stride;	/* the size of one entry */
	const char	*what;		/* their name */
};

/*
 * The merge of one array of named entries: an entry of the source that the
 * destination does not have yet is appended.  An entry the destination
 * already has is left alone: the first one wins.
 */
static int
merge_named(struct named_array *dst, void *src_entries, unsigned src_n,
    char *err, size_t errlen)
{
	unsigned i;

	for (i = 0; i < src_n; i++) {
		const char *name = (const char *)src_entries + i * dst->stride;
		unsigned j;

		for (j = 0; j < *dst->n; j++) {
			const char *have = (const char *)dst->entries +
			    j * dst->stride;

			if (strcmp(have, name) == 0)
				break;
		}
		if (j < *dst->n)
			continue;
		if (*dst->n >= dst->max) {
			snprintf(err, errlen, "the model has too many %s",
			    dst->what);
			return (-1);
		}
		memcpy((char *)dst->entries + *dst->n * dst->stride, name,
		    dst->stride);
		(*dst->n)++;
	}
	return (0);
}

/*
 * Merge a model into another one.  A provider, a base and a board are
 * merged by name (the first one wins), so the same base is written once and
 * shared by every card that decorates it.  The cards and the faults are
 * appended.
 */
static int
merge_model(struct gpu_model *dst, struct gpu_model *src, char *err,
    size_t errlen)
{
	struct named_array views[] = {
		{ dst->providers, &dst->nproviders,
		  sizeof(dst->providers) / sizeof(dst->providers[0]),
		  sizeof(dst->providers[0]), "providers" },
		{ dst->bases, &dst->nbases,
		  sizeof(dst->bases) / sizeof(dst->bases[0]),
		  sizeof(dst->bases[0]), "bases" },
		{ dst->boards, &dst->nboards,
		  sizeof(dst->boards) / sizeof(dst->boards[0]),
		  sizeof(dst->boards[0]), "boards" }
	};
	void *src_entries[] = { src->providers, src->bases, src->boards };
	unsigned src_counts[] = { src->nproviders, src->nbases, src->nboards };
	unsigned i;

	for (i = 0; i < sizeof(views) / sizeof(views[0]); i++)
		if (merge_named(&views[i], src_entries[i], src_counts[i], err,
		    errlen) != 0)
			return (-1);
	for (i = 0; i < src->ncards; i++) {
		if (dst->ncards >= sizeof(dst->cards) / sizeof(dst->cards[0])) {
			snprintf(err, errlen, "the model has too many cards");
			return (-1);
		}
		dst->cards[dst->ncards++] = src->cards[i];
	}
	for (i = 0; i < src->nfaults; i++) {
		if (dst->nfaults >= sizeof(dst->faults) /
		    sizeof(dst->faults[0])) {
			snprintf(err, errlen, "the model has too many faults");
			return (-1);
		}
		dst->faults[dst->nfaults++] = src->faults[i];
	}
	return (0);
}

/*
 * The includes of a model file: the other model files it is made of.  A
 * model file names them relative to itself.
 */
static int
read_includes(const struct gpu_json *root, const char *path,
    struct gpu_model *model, char *err, size_t errlen)
{
	const struct gpu_json *arr = gpu_json_get(root, "include");
	char dir[1024];
	size_t i;

	if (arr == NULL)
		return (0);
	if (gpu_json_type(arr) != GPU_JSON_ARRAY) {
		snprintf(err, errlen, "\"include\" is not an array");
		return (-1);
	}
	dir_of(path, dir, sizeof(dir));
	for (i = 0; i < gpu_json_count(arr); i++) {
		char name[1024], resolved[2048];
		struct gpu_model sub;

		if (gpu_json_str(gpu_json_at(arr, i), name, sizeof(name)) != 0) {
			snprintf(err, errlen, "an include of \"%s\" is not a "
			    "name", path);
			return (-1);
		}
		if (name[0] == '/')
			snprintf(resolved, sizeof(resolved), "%s", name);
		else
			snprintf(resolved, sizeof(resolved), "%s/%s", dir, name);
		if (gpu_model_load(resolved, &sub, err, errlen) != 0)
			return (-1);
		if (merge_model(model, &sub, err, errlen) != 0) {
			gpu_model_free(&sub);
			return (-1);
		}
		gpu_model_free(&sub);
	}
	return (0);
}

int
gpu_model_load(const char *path, struct gpu_model *model, char *err,
    size_t errlen)
{
	struct gpu_json_arena *arena = NULL;
	struct gpu_json *root;
	char *text = NULL;
	size_t len = 0;
	const struct gpu_json *v;
	char ver[64];

	memset(model, 0, sizeof(*model));
	model->mock = 1;
	if (read_file(path, &text, &len, err, errlen) != 0)
		return (-1);
	root = gpu_json_parse(text, len, &arena, err, errlen);
	free(text);
	if (root == NULL)
		return (-1);
	if (gpu_json_type(root) != GPU_JSON_OBJECT) {
		snprintf(err, errlen, "a model file is one JSON object");
		gpu_json_arena_free(arena);
		return (-1);
	}
	v = gpu_json_get(root, "schema_version");
	if (v == NULL || gpu_json_str(v, ver, sizeof(ver)) != 0) {
		snprintf(err, errlen, "the model file has no "
		    "\"schema_version\"");
		gpu_json_arena_free(arena);
		return (-1);
	}
	if (strcmp(ver, GPU_MODEL_SCHEMA_STRING) != 0) {
		snprintf(err, errlen, "the model file is schema version %s, "
		    "this mock reads %s (%s)", ver, GPU_MODEL_SCHEMA_STRING,
		    GPU_MODEL_SCHEMA);
		gpu_json_arena_free(arena);
		return (-1);
	}
	if (want_string(root, "model", model->name, sizeof(model->name), err,
	    errlen) != 0) {
		gpu_json_arena_free(arena);
		return (-1);
	}
	v = gpu_json_get(root, "description");
	if (v != NULL &&
	    gpu_json_str(v, model->description, sizeof(model->description)) != 0) {
		snprintf(err, errlen, "the model has a \"description\" that is "
		    "not a string");
		gpu_json_arena_free(arena);
		return (-1);
	}
	if (want_version(root, "driver_version", &model->driver_version, err,
	    errlen) != 0) {
		gpu_json_arena_free(arena);
		return (-1);
	}
	if (read_kind(root, model, "providers", err, errlen) != 0 ||
	    read_kind(root, model, "bases", err, errlen) != 0 ||
	    read_kind(root, model, "boards", err, errlen) != 0) {
		gpu_json_arena_free(arena);
		return (-1);
	}
	/* The includes come before the cards: a card may name a board of an
	 * included file. */
	if (read_includes(root, path, model, err, errlen) != 0) {
		gpu_json_arena_free(arena);
		return (-1);
	}
	if (read_kind(root, model, "cards", err, errlen) != 0 ||
	    read_kind(root, model, "faults", err, errlen) != 0) {
		gpu_json_arena_free(arena);
		return (-1);
	}
	/* A card of an included file names a board of the merged model: the
	 * view of every card is made again, now against the whole model. */
	{
		unsigned i;

		for (i = 0; i < model->ncards; i++)
			if (finalize_card(model, &model->cards[i], err,
			    errlen) != 0) {
				gpu_json_arena_free(arena);
				return (-1);
			}
	}
	gpu_json_arena_free(arena);
	return (0);
}

void
gpu_model_free(struct gpu_model *model)
{
	if (model != NULL)
		memset(model, 0, sizeof(*model));
}

const struct gpu_card *
gpu_model_card(const struct gpu_model *model, const char *name)
{
	unsigned i;

	if (model == NULL || name == NULL)
		return (NULL);
	for (i = 0; i < model->ncards; i++)
		if (strcmp(model->cards[i].name, name) == 0)
			return (&model->cards[i]);
	return (NULL);
}

unsigned
gpu_model_nvidia_cards(const struct gpu_model *model,
    const struct gpu_card **cards, unsigned max)
{
	unsigned i, n = 0;

	for (i = 0; i < model->ncards && n < max; i++) {
		const struct gpu_card *c = &model->cards[i];
		unsigned p, v;

		for (p = 0; p < model->nproviders; p++) {
			for (v = 0; v < model->providers[p].nvendor_ids; v++)
				if (model->providers[p].vendor_ids[v] ==
				    c->vendor_id)
					break;
			if (v < model->providers[p].nvendor_ids)
				break;
		}
		if (p < model->nproviders)
			cards[n++] = c;
	}
	return (n);
}

/*
 * The names of the nodes of the model.  The prefix is "nvidia", so the
 * nodes are the ones the real driver publishes; the environment variable
 * GPU_MOCK_PREFIX names them instead.  A prefix that a device name may
 * not carry is refused: the kernel replaces a character it does not know
 * in a device name, and the mock and its ruleset must name the same node.
 *
 * The two nodes that carry a dash in the driver (the modeset node and the
 * uvm node) carry an underscore here: the mechanism of cuse(3) replaces
 * every character of a device name it does not know with an underscore
 * (cuse_str_filter() in the kernel), so the node that exists on disk is
 * the one with the underscore.  The ruleset of the nodes must name the
 * nodes that exist, or the rule never matches them.
 */
int
gpu_model_node_names(const struct gpu_model *model,
    struct gpu_node_names *names)
{
	const struct gpu_card *cards[GPU_RM_MAX_CARDS];
	const char *env;
	char prefix[32];
	unsigned n, i;

	if (model == NULL || names == NULL)
		return (-1);
	env = getenv("GPU_MOCK_PREFIX");
	if (env == NULL || env[0] == '\0')
		env = "nvidia";
	if (strlen(env) >= sizeof(prefix))
		return (-1);
	strlcpy(prefix, env, sizeof(prefix));
	for (i = 0; prefix[i] != '\0'; i++) {
		unsigned char ch = (unsigned char)prefix[i];

		if (!isalnum(ch) && ch != '-' && ch != '_')
			return (-1);
	}
	memset(names, 0, sizeof(*names));
	snprintf(names->control, sizeof(names->control), "%sctl", prefix);
	snprintf(names->modeset, sizeof(names->modeset), "%s_modeset", prefix);
	snprintf(names->uvm, sizeof(names->uvm), "%s_uvm", prefix);
	n = gpu_model_nvidia_cards(model, cards, GPU_RM_MAX_CARDS);
	for (i = 0; i < n && i < GPU_RM_MAX_CARDS; i++)
		snprintf(names->card[i], sizeof(names->card[i]), "%s%u",
		    prefix, i);
	names->ncards = n;
	return (0);
}

/* ---- the decision --------------------------------------------------------- */

static const struct gpu_provider *
provider_for(const struct gpu_model *model, const struct gpu_card *card)
{
	unsigned p, v;

	for (p = 0; p < model->nproviders; p++) {
		for (v = 0; v < model->providers[p].nvendor_ids; v++)
			if (model->providers[p].vendor_ids[v] == card->vendor_id)
				return (&model->providers[p]);
	}
	return (NULL);
}

int
gpu_decide(const struct gpu_model *model, const struct gpu_card *card,
    enum gpu_decision *decision, char *reason, size_t len)
{
	const struct gpu_provider *pv;
	unsigned i;

	if (model == NULL || card == NULL || decision == NULL) {
		if (reason != NULL && len > 0)
			snprintf(reason, len, "no card");
		return (-1);
	}
	pv = provider_for(model, card);
	if (pv == NULL) {
		*decision = GPU_DECISION_NOT_CLAIMED;
		snprintf(reason, len, "no provider claims vendor 0x%04x",
		    card->vendor_id);
		return (0);
	}
	if (card->base == NULL) {
		*decision = GPU_DECISION_NOT_CLAIMED;
		snprintf(reason, len, "the card has no base");
		return (0);
	}
	if (pv->min_generation_name[0] != '\0' &&
	    card->base->generation < pv->min_generation) {
		*decision = GPU_DECISION_UNSUPPORTED_GENERATION;
		snprintf(reason, len, "the %s generation is below the %s floor "
		    "of the provider \"%s\"",
		    gpu_generation_name(card->base->generation),
		    pv->min_generation_name, pv->name);
		return (0);
	}
	for (i = 0; i < pv->n_generations; i++) {
		if (pv->generations[i].generation != card->base->generation)
			continue;
		if (!pv->generations[i].firmware_available) {
			*decision = GPU_DECISION_UNSUPPORTED_FIRMWARE;
			snprintf(reason, len, "the firmware \"%s\" of the %s "
			    "generation is not built",
			    pv->generations[i].firmware,
			    gpu_generation_name(card->base->generation));
			return (0);
		}
	}
	*decision = GPU_DECISION_SUPPORTED;
	snprintf(reason, len, "the provider \"%s\" drives it with %s",
	    pv->name, pv->nbackends > 0 ? pv->backends[0] : "no backend");
	return (0);
}

/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-3-Clause
 *
 * gpu_mock.c - the tool of the mock: the seam's answers, the decision of
 * the model and the daemon behind the CUSE nodes.
 *
 * The model comes from the argument, else from GPU_MOCK, else from the
 * model directory.  With GPU_MOCK set every consumer of the hardware (the
 * decision code, the preflight, the card check, nvrm-info) reads through
 * this tool, so a jail and a CI run see the same cards.
 */
#include <sys/param.h>
#include <sys/stat.h>

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "gpu_mock.h"
#include "gpu_rm.h"

/* The name of the environment variable that names the model. */
#define GPU_MOCK_ENV	"GPU_MOCK"

/* Where the model files live when the name is not a path. */
#define GPU_MOCK_DIR_ENV "GPU_MOCK_DIR"
/* The name of the environment variable that names the nodes of the daemon. */
#define GPU_MOCK_PREFIX_ENV "GPU_MOCK_PREFIX"
/*
 * The number of the devfs ruleset of the mock.  It is not a number the
 * system uses: the jail rules (4), the common rules (7) and the local
 * rules (10) keep theirs.
 */
#define GPU_MOCK_RULESET_NUMBER	63
#ifndef GPU_MOCK_MODEL_DIR
#define GPU_MOCK_MODEL_DIR	"/usr/local/share/nvidia-gb10-freebsd/models"
#endif
static void
usage(FILE *fp)
{
	fprintf(fp,
	    "usage: gpu-mock <command> [argument]\n"
	    "       gpu-mock --help\n"
	    "\n"
	    "commands:\n"
	    "  daemon [model]      publish the CUSE nodes of the model\n"
	    "  pciconf [-l|-lv|-lvb] [model]\n"
	    "                      the mock's pciconf(8) answer\n"
	    "  devinfo [selector] [model]\n"
	    "                      the mock's devinfo(8) answer\n"
	    "  sysctl name [model] the mock's sysctl(8) answer\n"
	    "  decide [model]      the decision of every card of the model\n"
	    "  nodes [model]       the devfs ruleset of the model's nodes\n"
	    "  model [model]       the model as one JSON document\n"
	    "  --help              this message\n"
	    "\n"
	    "The model is a file (data/models/<name>.json), a name under the\n"
	    "model directory, or the %s variable.  Every answer of this tool\n"
	    "is a mock: it never counts as a hardware result.\n"
	    "\n"
	    "The names of the nodes the daemon publishes are the ones the\n"
	    "driver publishes, unless the %s variable names them (a host\n"
	    "where those names are taken, or two mocks side by side).  The\n"
	    "modeset node and the uvm node carry an underscore where the\n"
	    "driver has a dash: cuse(3) replaces a character it does not know\n"
	    "in a device name with an underscore.\n",
	    GPU_MOCK_ENV, GPU_MOCK_PREFIX_ENV);
}

/* ---- the model ------------------------------------------------------------ */

/*
 * The path of a model: the name as a path when it holds a slash, else the
 * name under the model directory.  The helper is in the model loader, so the
 * tool and the seam shim find the same file.
 */
static int
model_path(const char *name, char *buf, size_t len)
{
	return (gpu_model_path(name, buf, len));
}

/* The model the argument, the environment or the default names. */
static int
load_model(const char *name, struct gpu_model *model, char *err, size_t errlen)
{
	char path[1024];
	const char *env;

	if (name == NULL || name[0] == '\0') {
		env = getenv(GPU_MOCK_ENV);
		name = (env != NULL && env[0] != '\0') ? env : NULL;
	}
	if (name == NULL) {
		snprintf(err, errlen, "no model: pass one, or set %s",
		    GPU_MOCK_ENV);
		return (-1);
	}
	if (model_path(name, path, sizeof(path)) != 0) {
		snprintf(err, errlen, "no model file for \"%s\" (looked under "
		    "%s)", name, GPU_MOCK_MODEL_DIR);
		return (-1);
	}
	return (gpu_model_load(path, model, err, errlen));
}

/*
 * The label of every answer of this tool: it says the answer is a mock.
 * It goes to stderr, so the answer on stdout stays machine readable.
 */
static void
label(const struct gpu_model *model)
{
	fprintf(stderr, "gpu-mock: mock answers from the model \"%s\"; "
	    "not a hardware result\n", model->name);
}

/* ---- the JSON output ------------------------------------------------------ */

static void
json_string(FILE *out, const char *s)
{
	const unsigned char *p = (const unsigned char *)s;

	fputc('"', out);
	for (; *p != '\0'; p++) {
		if (*p == '"' || *p == '\\')
			fprintf(out, "\\%c", *p);
		else if (*p == '\n')
			fputs("\\n", out);
		else if (*p == '\t')
			fputs("\\t", out);
		else if (*p < 0x20)
			fprintf(out, "\\u%04x", *p);
		else
			fputc(*p, out);
	}
	fputc('"', out);
}

static void
json_version(FILE *out, const struct gpu_version *v)
{
	fprintf(out, "{\"string\": ");
	json_string(out, v->string);
	fprintf(out, ", \"major\": %u, \"minor\": %u, \"patch\": %u, "
	    "\"available\": %s}", v->major, v->minor, v->patch,
	    v->available ? "true" : "false");
}

/* The document of the model: one JSON object, versioned. */
static void
print_model_json(const struct gpu_model *model, const char *path, FILE *out)
{
	unsigned i, p;

	fprintf(out, "{\n");
	fprintf(out, "  \"schema_version\": {\"string\": \"1.0\", \"major\": 1, "
	    "\"minor\": 0, \"patch\": 0, \"available\": true},\n");
	fprintf(out, "  \"tool\": \"gpu-mock\",\n");
	fprintf(out, "  \"mock\": true,\n");
	fprintf(out, "  \"model\": {\"name\": ");
	json_string(out, model->name);
	fprintf(out, ", \"description\": ");
	json_string(out, model->description);
	fprintf(out, ", \"file\": ");
	json_string(out, path);
	fprintf(out, "},\n");
	fprintf(out, "  \"driver_version\": ");
	json_version(out, &model->driver_version);
	fprintf(out, ",\n");
	fprintf(out, "  \"providers\": [");
	for (p = 0; p < model->nproviders; p++) {
		unsigned v;

		fprintf(out, "%s\n    {\"name\": ", p > 0 ? "," : "");
		json_string(out, model->providers[p].name);
		fprintf(out, ", \"score\": %d, \"vendor_ids\": [",
		    model->providers[p].score);
		for (v = 0; v < model->providers[p].nvendor_ids; v++)
			fprintf(out, "%s\"0x%04x\"",
			    v > 0 ? ", " : "", model->providers[p].vendor_ids[v]);
		fprintf(out, "], \"min_generation\": ");
		json_string(out, model->providers[p].min_generation_name);
		fprintf(out, "}");
	}
	fprintf(out, "\n  ],\n");
	fprintf(out, "  \"cards\": [");
	for (i = 0; i < model->ncards; i++) {
		const struct gpu_card *c = &model->cards[i];
		enum gpu_decision decision;
		char reason[256];

		(void)gpu_decide(model, c, &decision, reason, sizeof(reason));
		fprintf(out, "%s\n    {\"index\": %u, \"name\": ", i > 0 ? "," : "",
		    i);
		json_string(out, c->name);
		fprintf(out, ", \"provider\": ");
		json_string(out, c->provider);
		fprintf(out, ", \"vendor_id\": \"0x%04x\", \"device_id\": "
		    "\"0x%04x\"", c->vendor_id, c->device_id);
		fprintf(out, ", \"generation\": \"%s\"",
		    c->base != NULL ?
		    gpu_generation_name(c->base->generation) : "");
		fprintf(out, ", \"architecture\": %u, \"implementation\": %u",
		    c->base != NULL ? c->base->architecture : 0,
		    c->base != NULL ? c->base->implementation : 0);
		fprintf(out, ", \"vram_bytes\": %llu, \"bar1_bytes\": %llu",
		    (unsigned long long)c->vram_bytes,
		    (unsigned long long)c->bar1_bytes);
		fprintf(out, ", \"sm_version\": ");
		if (c->base != NULL)
			json_version(out, &c->base->sm_version);
		else {
			/* A card of no provider of ours has no SM version:
			 * it is not a card of a generation of ours. */
			struct gpu_version none;

			memset(&none, 0, sizeof(none));
			json_version(out, &none);
		}
		fprintf(out, ", \"uuid\": ");
		json_string(out, c->uuid);
		fprintf(out, ", \"decision\": \"%s\", \"reason\": ",
		    gpu_decision_name(decision));
		json_string(out, reason);
		fprintf(out, "}");
	}
	fprintf(out, "\n  ],\n");
	fprintf(out, "  \"faults\": [");
	for (i = 0; i < model->nfaults; i++) {
		const struct gpu_fault *f = &model->faults[i];
		const char *kind = f->kind == GPU_FAULT_DEVICE_LOST ?
		    "device_lost" : f->kind == GPU_FAULT_ALLOC_REFUSED ?
		    "alloc_refused" : "ioctl_failed";

		fprintf(out, "%s\n    {\"kind\": \"%s\", \"card\": ", i > 0 ?
		    "," : "", kind);
		json_string(out, f->card);
		fprintf(out, "}");
	}
	fprintf(out, "\n  ]\n}\n");
}

/* ---- the commands --------------------------------------------------------- */

static int
print_decide(const struct gpu_model *model, FILE *out)
{
	unsigned i;

	printf("model %s: %u card(s) (mock; not a hardware result)\n",
	    model->name, model->ncards);
	for (i = 0; i < model->ncards; i++) {
		const struct gpu_card *c = &model->cards[i];
		enum gpu_decision decision;
		char reason[256];

		(void)gpu_decide(model, c, &decision, reason, sizeof(reason));
		fprintf(out, "%-24s %-22s %s\n", c->name,
		    gpu_decision_name(decision), reason);
	}
	return (0);
}

/*
 * The devfs ruleset of the model's nodes: the rules a jail that runs the
 * mock's clients needs.  The rules are a sample: the operator puts them in
 * the ruleset of the jail, or applies them with devfs(8).
 */
static int
print_nodes(const struct gpu_model *model, FILE *out)
{
	struct gpu_node_names names;
	unsigned i;

	if (gpu_model_node_names(model, &names) != 0) {
		fprintf(stderr, "gpu-mock: the name of the nodes is not a name a "
		    "device may carry (GPU_MOCK_PREFIX)\n");
		return (1);
	}
	fprintf(out, "# The devfs ruleset of the GPU mock \"%s\": the nodes a\n"
	    "# jail that runs the mock's clients is given.  A mock: the nodes\n"
	    "# answer from the model, never from hardware.\n", model->name);
	fprintf(out, "# The name of the ruleset is gpumock and its number is %d:\n"
	    "# a jail takes it with devfs_ruleset=%d, and the machine of the\n"
	    "# operator with devfs_system_ruleset=\"gpumock\" in rc.conf.\n",
	    GPU_MOCK_RULESET_NUMBER, GPU_MOCK_RULESET_NUMBER);
	fprintf(out, "[gpumock=%d]\n", GPU_MOCK_RULESET_NUMBER);
	fprintf(out, "add path '%s' mode 0660 group video\n", names.control);
	for (i = 0; i < names.ncards; i++)
		fprintf(out, "add path '%s' mode 0660 group video\n",
		    names.card[i]);
	fprintf(out, "add path '%s' mode 0660 group video\n", names.modeset);
	fprintf(out, "add path '%s' mode 0660 group video\n", names.uvm);
	return (0);
}

/*
 * The model a command works on: the one the argument names, loaded and
 * labelled.  Returns -1 when there is no such model: the reason has been
 * printed already.
 */
static int
open_model(const char *name, struct gpu_model *model)
{
	char err[512];

	if (load_model(name, model, err, sizeof(err)) != 0) {
		fprintf(stderr, "gpu-mock: %s\n", err);
		return (-1);
	}
	label(model);
	return (0);
}

/* The daemon: the CUSE nodes of the model. */
static int
cmd_daemon(int argc, char **argv)
{
	struct gpu_model model;
	struct gpu_rm *rm;
	int rc;

	if (open_model(argc > 2 ? argv[2] : NULL, &model) != 0)
		return (1);
	rm = gpu_rm_new(&model);
	if (rm == NULL) {
		fprintf(stderr, "gpu-mock: out of memory\n");
		return (1);
	}
	rc = gpu_daemon_run(&model, rm);
	gpu_rm_free(rm);
	gpu_model_free(&model);
	return (rc);
}

/* The pciconf(8) answer of the mock. */
static int
cmd_pciconf(int argc, char **argv)
{
	struct gpu_model model;
	const char *flags = "";
	const char *name = NULL;

	if (argc > 2 && argv[2][0] == '-') {
		flags = argv[2] + 1;
		if (argc > 3)
			name = argv[3];
	} else if (argc > 2)
		name = argv[2];
	if (open_model(name, &model) != 0)
		return (1);
	gpu_seam_pciconf(&model, flags, stdout);
	gpu_model_free(&model);
	return (0);
}

/* The devinfo(8) answer of the mock. */
static int
cmd_devinfo(int argc, char **argv)
{
	struct gpu_model model;
	const char *selector = NULL;
	const char *name = NULL;

	if (argc > 2 && argv[2][0] != '-') {
		selector = argv[2];
		if (argc > 3)
			name = argv[3];
	} else if (argc > 2)
		name = argv[2];
	if (open_model(name, &model) != 0)
		return (1);
	gpu_seam_devinfo(&model, selector, stdout);
	gpu_model_free(&model);
	return (0);
}

/* The sysctl(8) answer of the mock. */
static int
cmd_sysctl(int argc, char **argv)
{
	struct gpu_model model;
	char value[1024];
	const char *name = NULL;

	if (argc < 3) {
		fprintf(stderr, "gpu-mock: sysctl needs a name\n");
		return (2);
	}
	if (argc > 3)
		name = argv[3];
	if (open_model(name, &model) != 0)
		return (1);
	if (gpu_seam_sysctl(&model, argv[2], value, sizeof(value)) != 0) {
		gpu_model_free(&model);
		return (1);
	}
	printf("%s\n", value);
	gpu_model_free(&model);
	return (0);
}

/* The decision of every card of the model. */
static int
cmd_decide(int argc, char **argv)
{
	struct gpu_model model;

	if (open_model(argc > 2 ? argv[2] : NULL, &model) != 0)
		return (1);
	print_decide(&model, stdout);
	gpu_model_free(&model);
	return (0);
}

/* The devfs ruleset of the model's nodes. */
static int
cmd_nodes(int argc, char **argv)
{
	struct gpu_model model;

	if (open_model(argc > 2 ? argv[2] : NULL, &model) != 0)
		return (1);
	print_nodes(&model, stdout);
	gpu_model_free(&model);
	return (0);
}

/* The model as one JSON document. */
static int
cmd_model(int argc, char **argv)
{
	struct gpu_model model;
	const char *name = argc > 2 ? argv[2] : NULL;
	char path[1024];

	if (open_model(name, &model) != 0)
		return (1);
	if (model_path(name != NULL ? name :
	    (getenv(GPU_MOCK_ENV) != NULL ? getenv(GPU_MOCK_ENV) : ""),
	    path, sizeof(path)) != 0)
		snprintf(path, sizeof(path), "%s", "");
	print_model_json(&model, path, stdout);
	gpu_model_free(&model);
	return (0);
}

/* The commands of the tool and the function of each. */
struct command {
	const char	*name;
	int		(*run)(int argc, char **argv);
};

static const struct command commands[] = {
	{ "daemon", cmd_daemon },
	{ "pciconf", cmd_pciconf },
	{ "devinfo", cmd_devinfo },
	{ "sysctl", cmd_sysctl },
	{ "decide", cmd_decide },
	{ "nodes", cmd_nodes },
	{ "model", cmd_model },
	{ NULL, NULL }
};

int
main(int argc, char **argv)
{
	const struct command *c;

	if (argc < 2) {
		usage(stderr);
		return (2);
	}
	if (strcmp(argv[1], "--help") == 0 || strcmp(argv[1], "-h") == 0) {
		usage(stdout);
		return (0);
	}
	for (c = commands; c->name != NULL; c++)
		if (strcmp(c->name, argv[1]) == 0)
			return (c->run(argc, argv));
	fprintf(stderr, "gpu-mock: unknown command \"%s\"\n", argv[1]);
	usage(stderr);
	return (2);
}

/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-3-Clause
 *
 * gpu_seam.c - the one seam: the fake pciconf, devinfo and hw.nvidia /
 * dev.nvidia answers, all made of the same model.
 *
 * The decision code, the preflight, the card check and nvrm-info read the
 * hardware through this seam and through nothing else.  With GPU_MOCK unset
 * the seam is not there and the real tools answer; with GPU_MOCK set every
 * answer comes from the model file it names.
 *
 * Every answer says it is a mock: the pciconf and devinfo output opens with
 * a marker line no real tool prints, and the version banner of the mock says
 * "GPU MOCK".
 */
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "gpu_mock.h"

/* The marker every answer of the seam opens with. */
#define GPU_MOCK_MARKER \
	"# gpu-mock: mock answers from the model \"%s\"; not hardware\n"

static void
marker(const struct gpu_model *model, FILE *out)
{
	fprintf(out, GPU_MOCK_MARKER, model->name);
}

/* The banner of the mock: it names the version and says it is a mock. */
void
gpu_mock_banner(const struct gpu_model *model, char *buf, size_t len)
{
	snprintf(buf, len, "GPU MOCK %s (mock; not a hardware result)",
	    model->driver_version.string);
}

/* ---- pciconf ------------------------------------------------------------- */

static void
pciconf_card(const struct gpu_card *c, int verbose, int bars, FILE *out)
{
	char selector[64];

	if (c->selector[0] != '\0')
		snprintf(selector, sizeof(selector), "%s", c->selector);
	else
		snprintf(selector, sizeof(selector), "vgapci%u", c->unit);
	fprintf(out, "%s@pci%u:%u:%u:%u:\tclass=0x%06x rev=0x%02x hdr=0x00 "
	    "vendor=0x%04x device=0x%04x subvendor=0x%04x subdevice=0x%04x\n",
	    selector, c->pci_domain, c->pci_bus, c->pci_slot, c->pci_function,
	    c->pci_class, c->revision, c->vendor_id, c->device_id,
	    c->subsystem_vendor_id, c->subsystem_device_id);
	if (!verbose)
		return;
	fprintf(out, "    vendor     = '%s'\n", c->vendor_name);
	fprintf(out, "    device     = '%s'\n", c->device_name);
	fprintf(out, "    class      = %s\n",
	    c->class_name[0] != '\0' ? c->class_name : "display");
	fprintf(out, "    subclass   = %s\n",
	    c->subclass_name[0] != '\0' ? c->subclass_name : "VGA");
	if (!bars)
		return;
	for (unsigned i = 0; i < c->nbars; i++)
		fprintf(out, "    bar   [%x] = type %s, range %u, base 0x%"
		    PRIx64 ", size %" PRIu64 ", %s\n", c->bars[i].index,
		    c->bars[i].type, c->bars[i].range, c->bars[i].base,
		    c->bars[i].size, c->bars[i].enabled ? "enabled" : "disabled");
}

void
gpu_seam_pciconf(const struct gpu_model *model, const char *flags, FILE *out)
{
	int verbose = 0, bars = 0;
	unsigned i;

	if (flags != NULL) {
		if (strchr(flags, 'v') != NULL)
			verbose = 1;
		if (strchr(flags, 'b') != NULL)
			bars = 1;
	}
	marker(model, out);
	for (i = 0; i < model->ncards; i++)
		pciconf_card(&model->cards[i], verbose, bars, out);
}

/* ---- devinfo ------------------------------------------------------------- */

void
gpu_seam_devinfo(const struct gpu_model *model, const char *selector,
    FILE *out)
{
	unsigned i;

	marker(model, out);
	for (i = 0; i < model->ncards; i++) {
		const struct gpu_card *c = &model->cards[i];
		char name[64];

		if (selector != NULL && selector[0] != '\0') {
			if (c->selector[0] != '\0' &&
			    strcmp(c->selector, selector) != 0)
				continue;
		}
		snprintf(name, sizeof(name), "%s",
		    c->selector[0] != '\0' ? c->selector : "vgapci");
		fprintf(out, "%s:\n", name);
		fprintf(out, "    vendor = '%s'\n", c->vendor_name);
		fprintf(out, "    device = '%s'\n", c->device_name);
		fprintf(out, "    class  = %s\n",
		    c->class_name[0] != '\0' ? c->class_name : "display");
		fprintf(out, "    subclass = %s\n",
		    c->subclass_name[0] != '\0' ? c->subclass_name : "VGA");
		fprintf(out, "    pci_bus = %u\n", c->pci_bus);
		fprintf(out, "    pci_slot = %u\n", c->pci_slot);
		fprintf(out, "    pci_function = %u\n", c->pci_function);
		fprintf(out, "    pci_vendor = 0x%04x\n", c->vendor_id);
		fprintf(out, "    pci_device = 0x%04x\n", c->device_id);
	}
}

/* ---- sysctl -------------------------------------------------------------- */

/* The sysctl of one card, or NULL when the name names no card. */
static const struct gpu_card *
card_of_unit(const struct gpu_model *model, unsigned unit)
{
	unsigned i;

	for (i = 0; i < model->ncards; i++)
		if (model->cards[i].unit == unit)
			return (&model->cards[i]);
	return (NULL);
}

/* The unit of a name like "hw.nvidia.gpus.3.uuid", or 0 when there is none. */
static int
split_sysctl(const char *name, const char *prefix, unsigned *unit,
    const char **leaf)
{
	size_t plen = strlen(prefix);
	const char *p;
	char *end = NULL;
	unsigned long v;

	if (strncmp(name, prefix, plen) != 0)
		return (0);
	p = name + plen;
	if (*p < '0' || *p > '9')
		return (0);
	v = strtoul(p, &end, 10);
	if (end == p || *end != '.')
		return (0);
	*unit = (unsigned)v;
	*leaf = end + 1;
	return (1);
}

/*
 * The members of the driver itself: the name names one of them.  Returns 1
 * when the name was one of them, 0 when it was not.
 */
static int
sysctl_driver(const struct gpu_model *model, const char *name, char *buf,
    size_t len)
{
	const struct gpu_version *v = &model->driver_version;

	if (strcmp(name, "hw.nvidia.version") == 0) {
		gpu_mock_banner(model, buf, len);
		return (1);
	}
	if (strcmp(name, "hw.nvidia.version_string") == 0) {
		snprintf(buf, len, "%s", v->string);
		return (1);
	}
	if (strcmp(name, "hw.nvidia.version_major") == 0) {
		snprintf(buf, len, "%u", v->major);
		return (1);
	}
	if (strcmp(name, "hw.nvidia.version_minor") == 0) {
		snprintf(buf, len, "%u", v->minor);
		return (1);
	}
	if (strcmp(name, "hw.nvidia.version_patch") == 0) {
		snprintf(buf, len, "%u", v->patch);
		return (1);
	}
	if (strcmp(name, "hw.nvidia.version_suffix") == 0) {
		snprintf(buf, len, "%s", "");
		return (1);
	}
	if (strcmp(name, "hw.nvidia.version_available") == 0) {
		snprintf(buf, len, "%d", v->available ? 1 : 0);
		return (1);
	}
	if (strcmp(name, "hw.nvidia.altra_device_wc_active") == 0) {
		snprintf(buf, len, "%d", model->mock ? 1 : 0);
		return (1);
	}
	return (0);
}

/*
 * The members of one GPU and of one device: hw.nvidia.gpus.<unit>.<leaf>
 * and dev.nvidia.<unit>.<leaf>.  Returns 1 when the name was one of them,
 * 0 when it was not, and -1 when it was one of them but the mock has no
 * answer for it.
 */
static int
sysctl_card(const struct gpu_model *model, const char *name, char *buf,
    size_t len)
{
	unsigned unit = 0;
	const char *leaf = NULL;
	const struct gpu_card *c;
	int gpu;

	if (split_sysctl(name, "hw.nvidia.gpus.", &unit, &leaf))
		gpu = 1;
	else if (split_sysctl(name, "dev.nvidia.", &unit, &leaf))
		gpu = 0;
	else
		return (0);
	c = card_of_unit(model, unit);
	if (c == NULL)
		return (-1);
	if (gpu) {
		if (strcmp(leaf, "type") == 0)
			snprintf(buf, len, "%s", "PCIe");
		else if (strcmp(leaf, "uuid") == 0)
			snprintf(buf, len, "%s", c->uuid);
		else if (strcmp(leaf, "firmware") == 0)
			snprintf(buf, len, "%s", "N/A");
		else if (strcmp(leaf, "vbios") == 0)
			snprintf(buf, len, "%s", c->board != NULL &&
			    c->board->vbios[0] != '\0' ? c->board->vbios :
			    "??.??.??.??.??");
		else if (strcmp(leaf, "irq") == 0)
			snprintf(buf, len, "%u", c->irq);
		else if (strcmp(leaf, "model") == 0)
			snprintf(buf, len, "%s", c->board != NULL ?
			    c->board->model_name : c->name);
		else
			return (-1);
		return (1);
	}
	if (strcmp(leaf, "uuid") == 0)
		snprintf(buf, len, "%s", c->uuid);
	else if (strcmp(leaf, "pci_bus_id") == 0)
		snprintf(buf, len, "%04x:%02x:%02x.%u", c->pci_domain,
		    c->pci_bus, c->pci_slot, c->pci_function);
	else if (strcmp(leaf, "%location") == 0)
		snprintf(buf, len,
		    "slot=%u function=%u dbsf=pci%u:%u:%u:%u",
		    c->pci_slot, c->pci_function, c->pci_domain,
		    c->pci_bus, c->pci_slot, c->pci_function);
	else
		return (-1);
	return (1);
}

int
gpu_seam_sysctl(const struct gpu_model *model, const char *name, char *buf,
    size_t len)
{
	int rc;

	if (model == NULL || name == NULL || buf == NULL || len == 0)
		return (-1);
	rc = sysctl_driver(model, name, buf, len);
	if (rc > 0)
		return (0);
	if (rc < 0)
		return (-1);
	return (sysctl_card(model, name, buf, len) > 0 ? 0 : -1);
}

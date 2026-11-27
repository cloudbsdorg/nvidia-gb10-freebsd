/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-3-Clause
 *
 * gpu_mock.h - the GPU mock: the model, the seam and the RM engine.
 *
 * The mock has three parts and no kernel module:
 *
 *   the model     one JSON file per card (data/models/), read by gpu_model.c
 *   the seam      fake pciconf, devinfo and hw.nvidia/dev.nvidia answers,
 *                 made of the same model (gpu_seam.c)
 *   the RM engine the RM escape ioctls of libnvrm's rm backend, answered
 *                 from the same model (gpu_rm.c)
 *
 * The daemon (gpu_daemon.c) puts the engine behind CUSE device nodes, so a
 * jail sees the same /dev/nvidiactl a real driver would publish.  Every
 * answer the mock gives is labelled "mock": it never counts as a hardware
 * result.
 */
#ifndef _GPU_MOCK_H_
#define _GPU_MOCK_H_

#include <stdint.h>
#include <stddef.h>
#include <stdio.h>

#include "gpu_rm.h"

/* The schema of a model file: gpu-model.v1. */
#define GPU_MODEL_SCHEMA		"gpu-model.v1"
#define GPU_MODEL_SCHEMA_STRING	"1.0"

/*
 * A version: the string and every part as an integer, so no consumer has to
 * parse a version string to compare it.
 */
struct gpu_version {
	char		string[64];
	uint32_t	major, minor, patch;
	int		available;
};

/*
 * The capability flags, indexed.  The order is part of the code: a new flag
 * is appended, never reordered.  The index is the same one libnvrm uses, so
 * a model file and an nvrm-info document speak about the same flags.
 */
enum gpu_cap {
	GPU_CAP_DMABUF_EXPORT = 0,
	GPU_CAP_ATS,
	GPU_CAP_SELF_HOSTED,
	GPU_CAP_DISPLAY_ENABLED,
	GPU_CAP_SOC,
	GPU_CAP_COHERENT_GPU_MEMORY,
	GPU_CAP_OS_DEVICE_WC,
	GPU_CAP__COUNT
};

/* The name of a capability flag, or NULL when the index is out of range. */
const char *gpu_cap_name(unsigned cap);
/* The index of a capability flag by name, or -1. */
int	gpu_cap_index(const char *name);

/* The generations of the provider record, in the order of their age. */
enum gpu_generation {
	GPU_GEN_MAXWELL = 0,
	GPU_GEN_PASCAL,
	GPU_GEN_VOLTA,
	GPU_GEN_TURING,
	GPU_GEN_AMPERE,
	GPU_GEN_HOPPER,
	GPU_GEN_ADA,
	GPU_GEN_BLACKWELL,
	GPU_GEN__COUNT
};

/* The name of a generation, or NULL. */
const char *gpu_generation_name(unsigned gen);
/* The generation of a name, or -1. */
int	gpu_generation_index(const char *name);

/* A generation: the base every board of that generation shares. */
struct gpu_base {
	char		name[32];		/* the base name */
	unsigned	generation;		/* enum gpu_generation */
	uint32_t	architecture;
	uint32_t	implementation;
	uint32_t	chip_id;
	struct gpu_version sm_version;
	unsigned	gpc_count;		/* the GPCs the card enables */
	unsigned	tpc_count;		/* the TPCs the card enables */
	uint64_t	gpc_mask;		/* the enabled GPCs */
	uint64_t	tpc_masks[GPU_RM_MAX_GPCS];	/* the TPCs of each GPC */
	unsigned	ntpc_masks;
	unsigned	sm_per_tpc;		/* the SMs of one TPC */
	uint64_t	bios_revision;
	uint64_t	bios_oem_revision;
	char		firmware_version[32];
	uint64_t	classes[1024];
	unsigned	nclasses;
	uint64_t	page_sizes[16];
	unsigned	npage_sizes;
	uint64_t	max_page_size;
	uint32_t	caps[GPU_CAP__COUNT];	/* the base's own flags */
};

/* A board: a decorator over a base.  It adds or overrides, never decides. */
struct gpu_board {
	char		name[64];
	char		base[32];		/* the base it decorates */
	char		model_name[96];
	char		vbios[32];
	uint16_t	subsystem_vendor_id;
	uint16_t	subsystem_device_id;
	int		have_subsystem;
	uint64_t	vram_bytes;
	uint64_t	bar1_bytes;
	uint32_t	caps[GPU_CAP__COUNT];	/* the overrides */
	unsigned	cap_set[GPU_CAP__COUNT];	/* which overrides apply */
};

/* One BAR of a card, as pciconf prints it. */
struct gpu_bar {
	unsigned	index;		/* the BAR number, in hex */
	char		type[40];		/* "Memory", "Prefetchable Memory", ... */
	unsigned	range;		/* 32 or 64 */
	uint64_t	base;
	uint64_t	size;
	int		enabled;
};

/* A card on the bus: a board at a PCI address, with the RM's identity. */
struct gpu_card {
	char		name[64];
	char		board_name[64];
	char		provider[64];
	char		selector[64];	/* the pciconf name, e.g. vgapci1 */
	uint16_t	vendor_id;
	uint16_t	device_id;
	uint16_t	subsystem_vendor_id;
	uint16_t	subsystem_device_id;
	uint16_t	revision;
	uint16_t	pci_domain, pci_bus, pci_slot, pci_function;
	uint32_t	pci_class;
	char		vendor_name[96];
	char		device_name[128];
	char		class_name[32];
	char		subclass_name[32];
	uint32_t	rm_gpu_id;
	char		uuid[64];
	unsigned	unit;
	unsigned	irq;
	int		have_unity;
	struct gpu_bar	bars[8];
	unsigned	nbars;
	/* The merged view: the base first, then the board's overrides. */
	const struct gpu_base *base;
	const struct gpu_board *board;
	uint32_t	caps[GPU_CAP__COUNT];
	uint64_t	vram_bytes;
	uint64_t	bar1_bytes;
	uint64_t	max_page_size;
};

/* A provider of the registry: what it claims and what it may drive. */
struct gpu_provider {
	char		name[64];
	int		score;
	uint16_t	vendor_ids[16];
	unsigned	nvendor_ids;
	uint16_t	device_ids[64];
	unsigned	ndevice_ids;
	unsigned	min_generation;	/* enum gpu_generation */
	char		min_generation_name[32];
	unsigned	nbackends;
	char		backends[8][64];
	/* The firmware of each generation this provider drives. */
	struct {
		unsigned	generation;
		char		firmware[64];
		int		firmware_available;
	} generations[GPU_GEN__COUNT];
	unsigned	n_generations;
};

/* A scripted fault of the model. */
enum gpu_fault_kind {
	GPU_FAULT_DEVICE_LOST = 1,	/* the card is gone: the RM refuses it */
	GPU_FAULT_ALLOC_REFUSED,	/* an allocation is refused */
	GPU_FAULT_IOCTL_FAILED		/* the ioctl itself fails */
};

struct gpu_fault {
	enum gpu_fault_kind kind;
	char		card[64];	/* the card it applies to, "" = any */
	char		object[64];	/* the class or the operation, "" = any */
	unsigned	nth;		/* the nth time it fires (0 = every time) */
	unsigned	count;		/* how many times it has fired */
};

/* The model: the whole of one mock. */
struct gpu_model {
	char		name[64];
	char		description[256];
	struct gpu_version driver_version;
	struct gpu_provider providers[8];
	unsigned	nproviders;
	struct gpu_base bases[16];
	unsigned	nbases;
	struct gpu_board boards[16];
	unsigned	nboards;
	struct gpu_card cards[16];
	unsigned	ncards;
	struct gpu_fault faults[16];
	unsigned	nfaults;
	int		mock;		/* always 1: a mock is never hardware */
};

/* ---- the model ----------------------------------------------------------- */

/*
 * The path of a model file: the name as a path when it holds a slash, else
 * the name under the model directory (GPU_MOCK_DIR, else the installed one).
 * Returns 0 when there is no such file.
 */
int	gpu_model_path(const char *name, char *buf, size_t len);

/*
 * Read a model file.  Returns the model, or NULL with *err naming the
 * reason.  The model is copied into the caller's storage (the caller owns
 * it); gpu_model_free() releases what the loader allocated.
 */
int	gpu_model_load(const char *path, struct gpu_model *model, char *err,
	    size_t errlen);

void	gpu_model_free(struct gpu_model *model);

/* The card of a name, or NULL. */
const struct gpu_card *gpu_model_card(const struct gpu_model *model,
	    const char *name);
/* The NVIDIA cards of the model, in order. */
unsigned	gpu_model_nvidia_cards(const struct gpu_model *model,
	    const struct gpu_card **cards, unsigned max);

/* ---- the decision --------------------------------------------------------- */

enum gpu_decision {
	GPU_DECISION_SUPPORTED = 0,
	GPU_DECISION_UNSUPPORTED_GENERATION,	/* below the provider's floor */
	GPU_DECISION_UNSUPPORTED_FIRMWARE,	/* the firmware is not built */
	GPU_DECISION_NOT_CLAIMED			/* no provider claims it */
};

/* The decision for a card, with a one line reason. */
int	gpu_decide(const struct gpu_model *model, const struct gpu_card *card,
	    enum gpu_decision *decision, char *reason, size_t len);

/* The name of a decision state. */
const char *gpu_decision_name(enum gpu_decision decision);

/* ---- the seam ------------------------------------------------------------ */

/*
 * The seam: the fake pciconf, devinfo and sysctl answers.  Every one of
 * them is made of the same model, and every one of them says it is a mock.
 */
void	gpu_seam_pciconf(const struct gpu_model *model, const char *flags,
	    FILE *out);
void	gpu_seam_devinfo(const struct gpu_model *model, const char *selector,
	    FILE *out);
/* The value of a sysctl, or -1 when the mock has none. */
int	gpu_seam_sysctl(const struct gpu_model *model, const char *name,
	    char *buf, size_t len);

/* The banner of the mock: the version it answers with, and the words that
 * say it is a mock. */
void	gpu_mock_banner(const struct gpu_model *model, char *buf, size_t len);

/* The most nodes the daemon publishes. */
#define GPU_MOCK_MAX_NODES	32

/* The length of the name of a node. */
#define GPU_MOCK_NODE_NAME	64

/*
 * The names of the nodes the daemon publishes.  They are the names the
 * real driver publishes: /dev/nvidiactl, one node per card of the model,
 * /dev/nvidia_modeset and /dev/nvidia_uvm.  The two last names carry an
 * underscore where the driver has a dash, because the mechanism of cuse(3)
 * replaces a character it does not know in a device name with an
 * underscore: the node that exists on disk is the one with the underscore,
 * and the ruleset must name it.  The environment variable GPU_MOCK_PREFIX
 * names the nodes instead, for a host where the driver's names are taken
 * (the node of a mock that was killed) or for two mocks side by side.
 */
struct gpu_node_names {
	char		control[GPU_MOCK_NODE_NAME];
	char		card[GPU_RM_MAX_CARDS][GPU_MOCK_NODE_NAME];
	unsigned	ncards;
	char		modeset[GPU_MOCK_NODE_NAME];
	char		uvm[GPU_MOCK_NODE_NAME];
};

/*
 * The names of the nodes of the model.  Returns 0, or -1 when the prefix
 * of the environment is not a name a device may carry.
 */
int	gpu_model_node_names(const struct gpu_model *model,
	    struct gpu_node_names *names);

/* The daemon: publish the CUSE nodes of the model and serve them until it
 * is stopped.  Returns 0 when it stops, 1 when it cannot start. */
int	gpu_daemon_run(const struct gpu_model *model, struct gpu_rm *rm);

#endif /* _GPU_MOCK_H_ */

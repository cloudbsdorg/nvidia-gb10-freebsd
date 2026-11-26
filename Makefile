# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# nvidia-gb10-freebsd: NVIDIA's FreeBSD driver built for arm64 and amd64
# (nvidia.ko, nvidia-modeset.ko, nvidia-drm.ko, the GSP firmware module,
# the optional Linux providers), libnvrm and nvrm-info, the rc.d script
# and the manual pages.  One Makefile for GNU make and bmake (skill
# project-makefile-contract): recipe lines start with a tab, no make
# conditionals, no GNU functions, no bmake modifiers.  Every recipe hands
# its target to scripts/make.sh, which holds the logic in sh(1).
#
# A recipe never runs $(MAKE): make -n would execute such a line, and the
# contract lint dry-runs every required target in an empty directory.
#
# Environment rule: DESTDIR and PREFIX may come from the environment; YES,
# ASSUME_YES and the licence settings never do (only the command line).

REPO_PURPOSE = application
# Where downloads and the build go; empty means ./work in this checkout.
WORK =
# Install root for the user-space files; kernel modules go to /boot/modules.
PREFIX ?= /usr/local
# Staging root for packaging; empty installs onto this system.
DESTDIR ?=
# The kernel sources (sys/) and the FreeBSD source top; empty means
# /usr/src when it matches the running kernel, else a tree that
# make install-prereqs fetched into WORK.
SYSDIR =
BSDSRCTOP =
# The drm-kmod source tree the installed drm.ko was built from; empty means
# the tree make install-prereqs fetched into WORK.
DRMKMODDIR =
YES = 0
ASSUME_YES = 0
# Licences: YES=1 never accepts one.  ACCEPT_NVIDIA_LICENSE=1 accepts
# NVIDIA's driver licence; ACCEPT_ALL_LICENSES=1 every licence the install
# meets.  Without them, a terminal shows the licence and asks.
ACCEPT_NVIDIA_LICENSE = 0
ACCEPT_ALL_LICENSES = 0
# make test-install: the repository the test machine clones, the stock
# FreeBSD it runs, and how the machine is made (tests/install-e2e/README.md)
E2E_REPO_URL =
E2E_REF =
E2E_OS = 16.0-CURRENT
# Empty: scripts/make.sh defaults to the running architecture (hookarch).
E2E_ARCH =
E2E_BACKEND = vmm
E2E_SSH =
JSON = 0
JSONL = 0

DRIVER = sh scripts/make.sh
DRIVER_ENV = MK_WORK="$(WORK)" MK_PREFIX="$(PREFIX)" MK_DESTDIR="$(DESTDIR)" MK_SYSDIR="$(SYSDIR)" MK_BSDSRCTOP="$(BSDSRCTOP)" MK_DRMKMODDIR="$(DRMKMODDIR)" MK_YES="$(YES)" MK_ASSUME_YES="$(ASSUME_YES)" MK_JSON="$(JSON)" MK_JSONL="$(JSONL)" MK_PURPOSE="$(REPO_PURPOSE)" MK_ACCEPT_NVIDIA_LICENSE="$(ACCEPT_NVIDIA_LICENSE)" MK_ACCEPT_ALL_LICENSES="$(ACCEPT_ALL_LICENSES)" MK_E2E_REPO_URL="$(E2E_REPO_URL)" MK_E2E_REF="$(E2E_REF)" MK_E2E_OS="$(E2E_OS)" MK_E2E_ARCH="$(E2E_ARCH)" MK_E2E_BACKEND="$(E2E_BACKEND)" MK_E2E_SSH="$(E2E_SSH)"

help:
	@printf '%s\n' \
		"purpose: $(REPO_PURPOSE)" \
		"NVIDIA's FreeBSD driver for arm64 and amd64, libnvrm and nvrm-info," \
		"for any user on a stock FreeBSD arm64 or amd64 install." \
		"" \
		"Targets (same names on every OS):" \
		"  make help             this message (default)" \
		"  make purpose          print REPO_PURPOSE (for machines)" \
		"  make preflight        what is missing, and whether each GPU is" \
		"                        supported (JSON=1: JSON)" \
		"  make install-prereqs  packages, NVIDIA sources (licence shown)," \
		"                        FreeBSD and drm-kmod sources (deps," \
		"                        install-deps: the same)" \
		"  make configure        loader.conf and rc.conf for boot loading:" \
		"                        shows the change, backs up, asks" \
		"  make build            every module, libnvrm, nvrm-info" \
		"                        (drm.ko: from drm-kmod packages on amd64;" \
		"                        built here on arm64)" \
		"  make test             the repository unit tests" \
		"  make install          prerequisites, build if needed, then install" \
		"  make deinstall        remove what install and configure wrote" \
		"                        (uninstall: the same)" \
		"  make test-install     the stock-install test in fresh VMs" \
		"                        (tests/install-e2e/README.md)" \
		"  make clean            remove the build tree (keeps downloads)" \
		"" \
		"Switches:" \
		"  YES=1, ASSUME_YES=1   do not ask (never accepts a licence)" \
		"  ACCEPT_NVIDIA_LICENSE=1  accept NVIDIA's driver licence" \
		"                        (its terms ask for that before install)" \
		"  ACCEPT_ALL_LICENSES=1    accept every licence the install" \
		"                        meets, and never ask" \
		"  JSON=1                preflight or install prints one JSON object" \
		"  JSONL=1               install prints progress objects, then a summary" \
		"                        (JSONL=1 wins when JSON=1 is also given;" \
		"                        a note on stderr says JSON=1 is ignored)" \
		"                        (the driver gives clean JSON on failure;" \
		"                        BSD make adds its own failure diagnostics)" \
		"  WORK=DIR              downloads and build (default ./work)" \
		"  PREFIX=DIR            install root (default $(PREFIX));" \
		"                        modules go to /boot/modules" \
		"  DESTDIR=DIR           install under DIR instead of /" \
		"  SYSDIR= BSDSRCTOP= DRMKMODDIR=   your own source trees" \
		"  E2E_OS= E2E_ARCH= E2E_BACKEND=vmm|ssh E2E_SSH=user@host" \
		"  E2E_REPO_URL=     the test-install machine and source" \
		"  E2E_REF=          ref to test (default: checkout HEAD)" \
		"" \
		"Environment: DESTDIR and PREFIX may come from the environment;" \
		"YES, ASSUME_YES and the licence settings never do (only the command line)." \
		"" \
		"Run make in this directory as a normal user; steps that" \
		"need root use doas, sudo or su."

.PHONY: help purpose preflight install-prereqs deps install-deps configure build all test install deinstall uninstall test-install clean

purpose:
	@printf '%s\n' "$(REPO_PURPOSE)"

# The --json and --purpose arguments repeat MK_JSON and MK_PURPOSE on
# purpose: the makefile-check hook reads them from this recipe.
preflight:
	@if [ "$(JSON)" = 1 ]; then \
		$(DRIVER_ENV) $(DRIVER) preflight --json --purpose "$(REPO_PURPOSE)"; \
	else \
		$(DRIVER_ENV) $(DRIVER) preflight --purpose "$(REPO_PURPOSE)"; \
	fi

install-prereqs:
	@$(DRIVER_ENV) $(DRIVER) install-prereqs

deps: install-prereqs

install-deps: install-prereqs

# configure: shows the proposed loader.conf and rc.conf change, makes a
# backup of each file it changes (.bak-<UTC time>), and asks to confirm;
# YES=1 or ASSUME_YES=1 applies without asking.  It says "nothing to
# configure" when every setting is already in place.
configure:
	@$(DRIVER_ENV) $(DRIVER) configure

build:
	@$(DRIVER_ENV) $(DRIVER) build

all: build

test:
	@$(DRIVER_ENV) $(DRIVER) test

install:
	@$(DRIVER_ENV) $(DRIVER) install

deinstall:
	@$(DRIVER_ENV) $(DRIVER) deinstall

uninstall: deinstall

test-install:
	@$(DRIVER_ENV) $(DRIVER) test-install

clean:
	@$(DRIVER_ENV) $(DRIVER) clean

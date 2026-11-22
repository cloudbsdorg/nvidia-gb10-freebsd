# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# nvidia-gb10-freebsd: NVIDIA's FreeBSD driver built for arm64 (nvidia.ko,
# nvidia-modeset.ko, nvidia-drm.ko, the GSP firmware module, the optional
# Linux providers), libnvrm and nvrm-info, the rc.d script and the manual
# pages.  One Makefile for GNU make and bmake (skill
# project-makefile-contract): recipe lines start with a tab, no make
# conditionals, no GNU functions, no bmake modifiers.  Every recipe hands
# its target to scripts/make.sh, which holds the logic in sh(1).
#
# A recipe never runs $(MAKE): make -n would execute such a line, and the
# contract lint dry-runs every required target in an empty directory.

REPO_PURPOSE = application
# Where downloads and the build go; empty means ./work in this checkout.
WORK =
# Install root for the user-space files; kernel modules go to /boot/modules.
PREFIX = /usr/local
# Staging root for packaging; empty installs onto this system.
DESTDIR =
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
JSON = 0

DRIVER = sh scripts/make.sh
DRIVER_ENV = MK_WORK="$(WORK)" MK_PREFIX="$(PREFIX)" MK_DESTDIR="$(DESTDIR)" MK_SYSDIR="$(SYSDIR)" MK_BSDSRCTOP="$(BSDSRCTOP)" MK_DRMKMODDIR="$(DRMKMODDIR)" MK_YES="$(YES)" MK_ASSUME_YES="$(ASSUME_YES)" MK_JSON="$(JSON)" MK_PURPOSE="$(REPO_PURPOSE)"

help:
	@printf '%s\n' \
		"purpose: $(REPO_PURPOSE)" \
		"NVIDIA's FreeBSD driver for arm64 (DGX Spark GB10 and other GSP GPUs), libnvrm and nvrm-info." \
		"" \
		"Targets (same names on every OS):" \
		"  make help             this message (default)" \
		"  make purpose          print REPO_PURPOSE (for machines)" \
		"  make preflight        report what is missing (JSON=1 for the --json contract)" \
		"  make install-prereqs  install packages and fetch every source the build needs" \
		"                        (deps and install-deps are the same target)" \
		"  make configure        show the build configuration; nothing to configure on the system" \
		"  make build            fetch the NVIDIA sources if needed, apply the patches, build every module and libnvrm" \
		"  make test             the repository unit tests" \
		"  make install          build if needed, then install (asks first; YES=1 does not ask)" \
		"  make deinstall        remove every file make install wrote (uninstall is the same)" \
		"  make test-install     the clean-install end-to-end run in stock FreeBSD VMs" \
		"  make clean            remove the build tree (keeps downloads)" \
		"" \
		"Switches:" \
		"  YES=1 or ASSUME_YES=1  I am fully aware: install without asking (also accepts the NVIDIA licence)" \
		"  JSON=1                 preflight writes the --json contract" \
		"  WORK=DIR               downloads and build (default ./work)" \
		"  PREFIX=DIR             user-space install root (default $(PREFIX)); modules go to /boot/modules" \
		"  DESTDIR=DIR            stage the install under DIR" \
		"  SYSDIR=DIR BSDSRCTOP=DIR DRMKMODDIR=DIR   use these trees instead of the fetched ones" \
		"" \
		"Run make from the directory that holds this Makefile.  Build as a normal user;" \
		"install steps that need root use doas or sudo when they are installed."

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

# configure: the build has no system configuration to change.  It prints the
# trees and paths the build would use; it writes nothing.
configure:
	@$(DRIVER_ENV) $(DRIVER) configure
	@printf '%s\n' "nothing to configure"

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

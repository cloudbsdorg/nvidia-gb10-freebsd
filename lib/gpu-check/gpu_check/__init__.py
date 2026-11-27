# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# gpu_check - the library of the gpu-check command.
#
# The command (scripts/gpu-check) is the decision core and the command
# line.  This package holds the checks themselves, the probes they run,
# the table they are printed in and the redaction of the report.
#
# Nothing in this package names a vendor.  The vendor knowledge lives in
# two places, and the vendor-free lint of tests/gpu_check_test.sh checks
# that it stays there:
#
#   data/providers/*.json          the records: what a provider claims
#   scripts/adapters/<vendor>.py   the probes: how a card of one vendor is
#                                  opened, read and tested
#
# A check asks the backend for the facts it needs; it never asks which
# vendor it is looking at.
"""The library of the gpu-check command."""

VERSION = "1.1"

# The statuses a check may carry.  There is one vocabulary, and the
# schemas hold the same four.
PASS = "pass"
FAIL = "fail"
NOT_TESTED = "not_tested"
NOT_AVAILABLE = "not_available"

STATUSES = (PASS, FAIL, NOT_TESTED, NOT_AVAILABLE)

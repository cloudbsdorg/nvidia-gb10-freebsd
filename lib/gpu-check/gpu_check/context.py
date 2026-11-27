# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# context.py - what a check is given when it runs.
"""What a check is given when it runs."""


class Context(object):
    """The card, the decision and the machine, as one check sees them.

    The state holds what the checks before this one found: the module
    that was loaded, the index of the card in the resource manager, the
    UUID that was read.  One card has one context, and the checks of
    that card run in the order their dependencies ask for.
    """

    def __init__(self, device, decision, machine, probe, **options):
        """The context of one card.

        The options are the records of the card: provider, family, backend
        and decorator.  They are words and not arguments, so the list of
        them cannot grow into a wall.
        """
        self.device = device
        self.decision = decision
        self.machine = machine
        self.probe = probe
        self.provider = options.get("provider")
        self.family = options.get("family")
        self.backend = options.get("backend")
        self.decorator = options.get("decorator")
        self.arch = options.get("arch", "arm64")
        self.state = {}

    @property
    def refused(self):
        """True when the decision refused this card."""
        return self.decision.get("code") != "supported"

    @property
    def refusal_reason(self):
        """Why the card was refused, in one line."""
        return "the decision refused this card: %s" % self.decision.get("reason", "")

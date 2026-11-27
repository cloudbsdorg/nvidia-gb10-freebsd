# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# registry.py - the checks of the command, and how they are found.
#
# Every check registers itself: it says which id it has, what it is
# called, whether it needs root, whether it needs the driver loaded, and
# which checks must run before it.  The command asks the registry what to
# run; it holds no list of its own.
"""The registry of the checks."""


class Check(object):
    """One check: what it is called, and what it needs to run.

    The id is the name a person types on the command line (--check) and
    the name the rows carry.  It is stable: a check keeps its id when
    its title changes.
    """

    def __init__(self, id, title, run, **options):
        """One check.

        The options are the words of the check: needs_root, needs_load,
        loads, dependencies, default and decision.  They are words and not
        arguments, so the list of them cannot grow into a wall.
        """
        self.id = id
        self.title = title
        self.run = run
        self.needs_root = bool(options.get("needs_root", False))
        self.needs_load = bool(options.get("needs_load", False))
        self.dependencies = tuple(options.get("dependencies", ()))
        self.default = bool(options.get("default", False))
        # A decision check holds the decision of a card: a card that a
        # provider refuses is refused, not a failed check.
        self.decision = bool(options.get("decision", False))
        # A check that loads a module needs root when the run may load.
        # A run that loads nothing (a run that was told the driver is
        # already loaded) needs no root for it: the check only reads the
        # listing of the loaded modules.
        self.loads = bool(options.get("loads", False))

    def __repr__(self):
        return "<check %s>" % self.id


# Every registered check, by id.  The order of the dict is the order the
# checks were registered in, and that is the order the rows are printed
# in.
REGISTRY = {}


def register(check):
    """Add a check to the registry.

    A duplicate id is a programming error and stops the command: two
    checks with one name would make --check ambiguous.
    """
    if check.id in REGISTRY:
        raise ValueError("the check %s is registered twice" % check.id)
    REGISTRY[check.id] = check
    return check


def checks():
    """Every registered check, in the order they were registered."""
    return list(REGISTRY.values())


def get(check_id):
    """The check with this id, or None."""
    return REGISTRY.get(check_id)


def defaults():
    """The checks a run without options runs: the detection and the decision.

    A run without options must not touch the machine: it says what the
    card is and whether the driver serves it, and nothing else.  The
    checks that read or change the machine are asked for by name.
    """
    return [check for check in checks() if check.default]


def decision_check():
    """The check that holds the decision of a card, or None.

    The decision is not a failed check: a card that no provider claims is
    refused, and the exit status says so instead of counting a failure.
    """
    for check in checks():
        if check.decision:
            return check
    return None


def resolve(ids):
    """The checks to run for these ids, and the ids that are unknown.

    Returns (checks, unknown).  The checks are in the order they must
    run in: a check comes after the checks it depends on.  An id that is
    not registered is returned as unknown: the command says so instead of
    running a check whose ground it does not know.
    """
    unknown = []
    wanted = []
    seen = set()

    def add(check_id):
        if check_id in seen:
            return
        check = REGISTRY.get(check_id)
        if check is None:
            if check_id not in unknown:
                unknown.append(check_id)
            return
        seen.add(check_id)
        for dependency in check.dependencies:
            add(dependency)
        wanted.append(check)

    for check_id in ids:
        add(check_id)
    return wanted, unknown


def ordered(checks_wanted):
    """The checks in the order the rows are printed in.

    The order of the registry, not the order they run in: a person reads
    the rows in the order the checks are registered, whatever the
    dependencies were.
    """
    wanted = {check.id for check in checks_wanted}
    return [check for check in checks() if check.id in wanted]


def everything():
    """Every check of the registry, in the order they must run in."""
    return resolve([check.id for check in checks()])[0]


def index_of(check):
    """The number of a check: its place in the registry, from one.

    The number is stable: a check keeps it when another check is added,
    so a row of a report means the same thing in every run.
    """
    for number, one in enumerate(checks(), 1):
        if one.id == check.id:
            return number
    raise KeyError(check.id)

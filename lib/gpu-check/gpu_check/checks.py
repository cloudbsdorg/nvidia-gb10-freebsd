# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# checks.py - the checks of the command, and how they register themselves.
#
# A check says what it is, what it needs (root, the driver loaded) and
# which checks must run before it.  The command asks the registry what to
# run; it holds no list of its own.  Adding a check is adding a function
# and a call to _register: nothing else in the tool changes.
#
# A check is given a context and answers a row: a status and a reason.
# The reason always says why: a check that did not run says what was
# missing (the driver, the root, a decision that refused the card), and a
# check that ran says what it found.
#
# Nothing here names a vendor: the card comes with its identity and its
# decision, and the probes answer the vendor's questions.
"""The checks, and how they register themselves."""

from . import FAIL, NOT_AVAILABLE, NOT_TESTED, PASS
from . import environment
from . import registry


def _result(status, reason, **extra):
    """One row of a check: a status, a reason, and what else it found."""
    row = {"status": status, "reason": reason}
    row.update(extra)
    return row


def _register(check_id, title, run, **options):
    """Register one check and return it."""
    return registry.register(registry.Check(check_id, title, run, **options))


def _identity_line(context):
    """The card in one line: what it is, in the words of the records."""
    device = context.device
    return "vendor %s device %s subsystem %s:%s class %s" % (
        device["vendor"].lower().replace("0x", ""),
        device["device"].lower().replace("0x", ""),
        device["subvendor"].lower().replace("0x", ""),
        device["subdevice"].lower().replace("0x", ""),
        device["class"].lower().replace("0x", ""))


def _generation(context):
    """The generation of the card, or None."""
    family = context.family
    if family is None:
        return None
    entry = family.generation_for(context.device["device"])
    if entry is None:
        return None
    return str(entry.get("name")).upper()


# --- the card ---------------------------------------------------------------

def _detect(context):
    """The card was found and its identity read."""
    generation = _generation(context)
    board = context.decorator.name if context.decorator is not None else "none"
    return _result(PASS, "%s, generation %s, board %s"
                   % (_identity_line(context), generation or "unknown", board))


def _decide(context):
    """The provider was chosen or refused, and why."""
    decision = context.decision
    if decision["code"] == "supported":
        return _result(PASS, "the provider %s chose the backend %s: %s"
                       % (decision["provider"], decision["backend"],
                          decision["reason"]))
    if decision["code"] == "no_provider":
        return _result(NOT_AVAILABLE, decision["reason"])
    return _result(FAIL, "%s: %s" % (decision["reason_code"], decision["reason"]))


# --- the load ---------------------------------------------------------------

def _capture_record(context, name):
    """What a recorded run says about one step of the load, or None."""
    machine = context.machine
    if not getattr(machine, "is_capture", False):
        return None
    entry = machine.capture_entry(context.device["selector"])
    if not isinstance(entry, dict):
        return None
    answer = entry.get(name)
    return answer if isinstance(answer, dict) else None


def _firmware(context):
    """The firmware the card needs was loaded."""
    if context.refused:
        return _result(NOT_TESTED, context.refusal_reason)
    recorded = _capture_record(context, "firmware")
    if recorded is not None:
        status = recorded.get("status") or NOT_TESTED
        reason = recorded.get("reason") or "the recorded run loaded the firmware"
        if status == PASS:
            context.state["firmware"] = PASS
        return _result(status, reason)
    family = context.family
    if family is None or family.firmware is None:
        context.state["firmware"] = NOT_AVAILABLE
        return _result(NOT_AVAILABLE,
                       "the family of this card names no firmware to load")
    module = family.firmware_module
    status, message = context.machine.kldload(module)
    context.state["firmware"] = status
    if status == PASS:
        return _result(PASS, "the firmware %s was loaded (%s)"
                       % (family.firmware["image"], message))
    return _result(status, message)


def _load_modules(context, modules):
    """Load the modules of the backend, in order.

    Returns (loaded, missing, failure).  "missing" holds the modules that
    are not installed: a module that is not there is not a failure, the
    card may be driven without it.  "failure" is None when every module
    loaded or was simply not there; otherwise it is the (status, module,
    message) of the module that did not load.
    """
    loaded = []
    missing = []
    for module in modules:
        status, message = context.machine.kldload(module)
        if status == PASS:
            loaded.append(module)
            continue
        if status == NOT_AVAILABLE:
            # A module that is not installed is not a failure: the card
            # may be driven without it.  The row says which one it was.
            missing.append("%s is not available: %s" % (module, message))
            continue
        # A module that did not load is a failure: nothing that needs the
        # driver may run after it.
        return loaded, missing, (status, module, message)
    return loaded, missing, None


def _recorded_driver(context, recorded):
    """The row of a recorded run that loaded the driver."""
    status = recorded.get("status") or NOT_TESTED
    reason = recorded.get("reason") or "the recorded run loaded the driver"
    modules = recorded.get("modules")
    if status == PASS:
        context.state["driver_modules"] = list(modules) if isinstance(modules, list) else []
    return _result(status, reason)


def _driver_reason(context, loaded, missing):
    """The reason of a row that says the driver modules were loaded."""
    reason = "the driver modules %s were loaded" % "+".join(loaded)
    already = [module for module in loaded
               if module in getattr(context.machine, "already", ())]
    if already:
        reason = "%s (%s was already loaded)" % (reason, ", ".join(already))
    if missing:
        reason = "%s; %s" % (reason, "; ".join(missing))
    return reason


def _driver_loaded(context):
    """The driver modules were loaded."""
    if context.refused:
        return _result(NOT_TESTED, context.refusal_reason)
    recorded = _capture_record(context, "driver")
    if recorded is not None:
        return _recorded_driver(context, recorded)
    if context.state.get("firmware") in (FAIL, NOT_TESTED):
        return _result(NOT_TESTED,
                       "the firmware was not loaded, so the driver was not loaded")
    backend = context.backend
    if backend is None:
        return _result(NOT_AVAILABLE, "the decision names no backend to load")
    if not backend.modules:
        return _result(NOT_AVAILABLE, "the backend %s names no module" % backend.name)
    loaded, missing, failure = _load_modules(context, backend.modules)
    if failure is not None:
        status, module, message = failure
        if loaded:
            return _result(status, "the modules %s were loaded, then %s: %s"
                           % ("+".join(loaded), module, message))
        return _result(status, message)
    if not loaded:
        return _result(NOT_AVAILABLE,
                       "none of the modules %s is %s: %s"
                       % (", ".join(backend.modules),
                          getattr(context.machine, "missing_verb", "installed"),
                          "; ".join(missing)))
    context.state["driver_modules"] = loaded
    return _result(PASS, _driver_reason(context, loaded, missing))


def _device_open(context):
    """The device opened and its identity confirmed."""
    if context.refused:
        return _result(NOT_TESTED, context.refusal_reason)
    if not context.state.get("driver_modules"):
        return _result(NOT_TESTED,
                       "the driver was not loaded, so the device was not opened")
    status, reason = context.probe.device_open(context.device)
    return _result(status, reason)


def _identity(context):
    """The identity of the card, as the resource manager sees it."""
    if context.refused:
        return _result(NOT_TESTED, context.refusal_reason)
    if not context.state.get("driver_modules"):
        return _result(NOT_TESTED,
                       "the driver was not loaded, so the identity was not read")
    status, reason, extra = context.probe.identity(context.device)
    if extra:
        context.state.update(extra)
        if isinstance(extra.get("rm_index"), int):
            context.device["rm_index"] = extra["rm_index"]
    return _result(status, reason, **extra)


# --- the probes -------------------------------------------------------------

def _memory(context):
    """Memory allocated, mapped and copied."""
    if context.refused:
        return _result(NOT_TESTED, context.refusal_reason)
    if not context.state.get("driver_modules"):
        return _result(NOT_TESTED,
                       "the driver was not loaded, so no memory was allocated")
    outcome = context.probe.memory(context.device)
    return _result(outcome["status"], outcome["reason"], steps=outcome.get("steps") or [])


def _channel(context):
    """A channel created, released, measured and cleaned up."""
    if context.refused:
        return _result(NOT_TESTED, context.refusal_reason)
    if not context.state.get("driver_modules"):
        return _result(NOT_TESTED,
                       "the driver was not loaded, so no channel was created")
    outcome = context.probe.channel(context.device)
    return _result(outcome["status"], outcome["reason"], steps=outcome.get("steps") or [])


def _uvm(context):
    """The unified memory interface."""
    if context.refused:
        return _result(NOT_TESTED, context.refusal_reason)
    if not context.state.get("driver_modules"):
        return _result(NOT_TESTED,
                       "the driver was not loaded, so the unified memory "
                       "interface was not tested")
    status, reason = context.probe.uvm(context.device)
    return _result(status, reason)


def _prime(context):
    """The path that imports the display of another card."""
    if context.refused:
        return _result(NOT_TESTED, context.refusal_reason)
    if not context.state.get("driver_modules"):
        return _result(NOT_TESTED,
                       "the driver was not loaded, so the import path was not tested")
    status, reason = context.probe.prime(context.device)
    return _result(status, reason)


def _display(context):
    """The display and the console path."""
    if context.refused:
        return _result(NOT_TESTED, context.refusal_reason)
    if not context.state.get("driver_modules"):
        return _result(NOT_TESTED,
                       "the driver was not loaded, so the display path was not tested")
    status, reason = context.probe.display(context.device)
    return _result(status, reason)


# --- the environment of the machine -----------------------------------------

def _no_linux_layer(context):
    """No module of the Linux layer is loaded.

    A native run drives the card with the native modules only.  The rules
    of the Linux layer are in the library, so the command and the kit read
    the same list.
    """
    listing = context.machine.module_listing()
    facts = environment.environment_facts(listing)
    offenders = facts["linux_layer"]
    if offenders:
        return _result(FAIL, "the loaded modules %s are of the Linux layer"
                       % ", ".join(offenders))
    return _result(PASS, "the loaded modules are native: %s"
                   % (", ".join(facts["modules"]) or "none"))


def _native_modules(context):
    """The modules of this card that are loaded are native.

    The record names the modules of the card.  The ones that are loaded
    must be native: a module of the Linux layer under the name of a native
    one would drive the card the wrong way.
    """
    names = []
    family = context.family
    if family is not None and family.firmware_module:
        names.append(family.firmware_module)
    backend = context.backend
    if backend is not None:
        names.extend(backend.modules)
    if not names:
        return _result(NOT_AVAILABLE, "the record names no module for this card")
    facts = environment.environment_facts(context.machine.module_listing())
    loaded = facts["modules"]
    present = [name for name in names if name in loaded]
    if not present:
        return _result(NOT_AVAILABLE,
                       "none of the modules %s is loaded" % ", ".join(names))
    offenders = [name for name in present if environment.is_linux_layer(name)]
    if offenders:
        return _result(FAIL, "the loaded modules %s are of the Linux layer"
                       % ", ".join(offenders))
    return _result(PASS, "the loaded modules %s are native" % ", ".join(present))


# --- the registry -----------------------------------------------------------

# The order of the registration is the order of the rows: the card first,
# then the load, then the probes, then the environment.
_register("detect", "the card was found and its identity read", _detect,
          default=True)
_register("decide", "the provider was chosen or refused, and why", _decide,
          dependencies=("detect",), default=True, decision=True)
_register("firmware", "the firmware the card needs was loaded", _firmware,
          needs_root=True, needs_load=True, loads=True, dependencies=("decide",))
_register("driver-loaded", "the driver modules were loaded", _driver_loaded,
          needs_root=True, needs_load=True, loads=True, dependencies=("firmware",))
_register("device-open", "the device opened and its identity confirmed",
          _device_open, needs_root=True, needs_load=True,
          dependencies=("driver-loaded",))
_register("identity", "the identity of the card, as the resource manager sees it",
          _identity, needs_root=True, needs_load=True,
          dependencies=("device-open",))
_register("memory", "memory allocated, mapped and copied", _memory,
          needs_root=True, needs_load=True, dependencies=("device-open", "identity"))
_register("channel", "a channel created, released, measured and cleaned up",
          _channel, needs_root=True, needs_load=True,
          dependencies=("device-open", "identity"))
_register("uvm", "the unified memory interface", _uvm,
          needs_load=True, dependencies=("device-open",))
_register("prime", "the path that imports the display of another card", _prime,
          needs_load=True, dependencies=("device-open",))
_register("display", "the display and the console path", _display,
          needs_load=True, dependencies=("driver-loaded",))
_register("no-linux-layer", "no module of the Linux layer is loaded",
          _no_linux_layer)
_register("native-modules", "the modules of this card that are loaded are native",
          _native_modules)

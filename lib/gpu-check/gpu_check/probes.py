# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# probes.py - the probes of the checks: the steps, the driver that runs
# them, and the backends that answer them without a card.
#
# A probe is a list of steps in a fixed order.  The driver runs them one
# after the other; the step after a step that failed was not reached, and
# says so; the steps that always run (the leak checks) run even after a
# failure.  What a step does is the business of the backend:
#
#   FakeBackend     answers from a fake file (a run that proves nothing)
#   CaptureBackend  replays a recorded run
#   the adapter     talks to the card of one vendor
#
# The driver holds the order of the steps and what a failure means; no
# backend holds a list of its own.
"""The probes: the steps of a check, and the driver that runs them."""

from . import FAIL, NOT_TESTED, PASS, STATUSES
from . import redact

# The steps of the memory probe, in the order they run.  The names are
# the names the recorded runs use, so a recorded run and a live run say
# the same thing.
MEMORY_STEPS = (
    "client_open",
    "vaspace",
    "va_reserve",
    "alloc_vram",
    "vram_info",
    "alloc_sysmem",
    "map_gpu_vram",
    "map_cpu_vram",
    "rw_vram",
    "map_gpu_sysmem",
    "map_cpu_sysmem",
    "rw_sysmem",
    "export",
    "second_client",
    "import",
    "read_import",
    "va_release",
    "nothing_left",
    "no_refused_release",
)

# The steps that run even when a step before them failed: the release of
# the address space and the leak checks of the memory probe.  A probe
# that failed halfway still has to say what it left behind.
MEMORY_ALWAYS = ("va_release", "nothing_left", "no_refused_release")

# The steps of the channel probe, in the order they run.
CHANNEL_STEPS = (
    "create",
    "release",
    "latency",
    "stress",
    "isolation",
    "cleanup",
)

# The step that runs even when a step before it failed: the cleanup of
# the channel probe.
CHANNEL_ALWAYS = ("cleanup",)

# The status of a step that was not reached.
NOT_REACHED = "not_reached"

# The key a fake file holds the steps of a probe under.
STEPS_KEY = "%s_steps"

# The reason of a card that a recorded run holds no record of.
NO_CAPTURE_RECORD = "the capture holds no record of the card %s"


def run_steps(names, always, step_function):
    """Run the steps of a probe, in order.

    step_function(name) returns (ok, detail).  The steps after a step
    that failed were not reached, and say so.  The steps in "always" run
    even after a failure: they are the leak checks, and a probe that
    leaves something behind must say so.

    Returns the list of the steps: every step has a name, a status and a
    detail.
    """
    results = []
    failed = False
    for name in names:
        if failed and name not in always:
            results.append({"name": name, "status": NOT_REACHED,
                            "detail": "not reached"})
            continue
        ok, detail = step_function(name)
        results.append({"name": name, "status": PASS if ok else FAIL,
                        "detail": detail})
        if not ok and name not in always:
            failed = True
    return results


def fold(steps):
    """The result of a probe: its status and the reason.

    The reason names the first step that failed: the steps after it were
    not reached, and the first failure is the one that says why.
    """
    failed = [step for step in steps if step["status"] == FAIL]
    if failed:
        first = failed[0]
        return FAIL, "%s: %s" % (first["name"], first["detail"])
    return PASS, "%d steps passed" % len(steps)


def _answer_status(answer, where):
    """The status of an answer, or raise: the vocabulary is one."""
    status = answer.get("status")
    if not isinstance(status, str) or not status:
        raise ValueError("%s has no status" % where)
    return status


# The answers a fake file may hold: the probes of a card and the
# environment of the machine.  A fake file that says nothing about a
# probe did not test it, and the row says so.
FAKE_ANSWERS = ("device_open", "identity", "memory", "channel", "uvm", "prime",
                "display", "environment")


class FakeAnswerError(ValueError):
    """A fake file does not use the documented vocabulary."""


def answer_status(answer, where):
    """The status of an answer, or raise: the vocabulary is one.

    A fake file may say "ok" where the vocabulary says "pass": it is the
    same word, and the row always carries the vocabulary.
    """
    status = answer.get("status")
    if status is None:
        raise FakeAnswerError("%s has no status: it must be one of %s"
                              % (where, ", ".join(STATUSES)))
    if status not in STATUSES and status != "ok":
        raise FakeAnswerError("%s has the status %r: it must be one of %s"
                              % (where, status, ", ".join(STATUSES)))
    return PASS if status == "ok" else status


def check_answers(fake):
    """Every answer of a fake file uses the documented vocabulary.

    Raises FakeAnswerError when it does not: a fake file that says a
    status that means nothing would make a row that means nothing.
    """
    if not isinstance(fake, dict):
        raise FakeAnswerError("the fake file is not an object")
    _check_probe_answers(fake)
    _check_step_answers(fake)
    _check_module_answers(fake)


def _check_probe_answers(fake):
    """The answers of the probes of a fake file."""
    for name in FAKE_ANSWERS:
        answer = fake.get(name)
        if answer is None:
            continue
        if not isinstance(answer, dict):
            raise FakeAnswerError("the fake answer for %s is not an object" % name)
        if "status" in answer:
            answer_status(answer, "the fake answer for %s" % name)
            continue
        for selector, one in answer.items():
            if not isinstance(one, dict):
                raise FakeAnswerError("the fake answer for %s of %s is not an object"
                                      % (name, selector))
            answer_status(one, "the fake answer for %s of %s" % (name, selector))


def _check_step_answers(fake):
    """The answers of the steps of the probes of a fake file.

    The steps of a probe are answers too: a file that says a step has a
    status that means nothing is refused when the file is read, not in
    the middle of a probe.
    """
    for name in FAKE_ANSWERS:
        steps = fake.get(STEPS_KEY % name)
        if steps is None:
            continue
        if not isinstance(steps, dict):
            raise FakeAnswerError("the fake answers for the steps of %s are not an object"
                                  % name)
        for step, one in steps.items():
            if not isinstance(one, dict):
                raise FakeAnswerError("the fake answer for the step %s of %s is not an object"
                                      % (step, name))
            answer_status(one, "the fake answer for the step %s of %s" % (step, name))


def _check_module_answers(fake):
    """The answers of the module loads of a fake file."""
    loads = fake.get("kldload")
    if loads is None:
        return
    if not isinstance(loads, dict):
        raise FakeAnswerError("the fake answers for the module loads are not an object")
    for module, answer in loads.items():
        if not isinstance(answer, dict):
            raise FakeAnswerError("the fake answer for the module %s is not an object"
                                  % module)
        answer_status(answer, "the fake answer for the module %s" % module)


class FakeBackend(object):
    """A backend that answers from a fake file.

    A fake run loads nothing and proves nothing about the machine; it
    exists so the command can be run, and its output tested, without a
    card.

    A fake file may answer a probe as a whole ({"status": ..., "message":
    ...}) and may answer its steps one by one ("memory_steps": {"vaspace":
    {"status": ..., "detail": ...}}).  A step the file does not name
    passes: the file answered the probe, and said nothing about that
    step.
    """

    def __init__(self, fake):
        self.fake = fake if isinstance(fake, dict) else {}

    def _answer(self, kind, device=None):
        answer = self.fake.get(kind)
        if not isinstance(answer, dict):
            return None
        if "status" in answer:
            return answer
        if device is not None:
            for key in (device.get("selector"), device.get("name")):
                one = answer.get(key)
                if isinstance(one, dict):
                    return one
        return None

    def _step_answer(self, kind, name):
        steps = self.fake.get(STEPS_KEY % kind)
        if not isinstance(steps, dict):
            return None
        answer = steps.get(name)
        return answer if isinstance(answer, dict) else None

    def _step(self, kind, name, device=None):
        """One step of a probe: what the fake file says about it."""
        answer = self._step_answer(kind, name)
        if answer is not None:
            status = _answer_status(answer, "the fake answer for the step %s" % name)
            detail = answer.get("detail") or answer.get("message") or ""
            if status in (PASS, "ok"):
                return True, detail or "the fake answered for the step %s" % name
            return False, detail or "the fake did not pass the step %s" % name
        whole = self._answer(kind, device)
        if whole is not None:
            status = _answer_status(whole, "the fake answer for the %s probe" % kind)
            if status not in (PASS, "ok"):
                detail = whole.get("message") or whole.get("detail") or ""
                return False, detail or "the fake did not pass the %s probe" % kind
        return True, "the fake answered for the step %s" % name

    def memory(self, device):
        """The memory probe, answered by the fake."""
        if not self._answers("memory", device):
            return _result(None, [], "memory")
        steps = run_steps(MEMORY_STEPS, MEMORY_ALWAYS,
                          lambda name: self._step("memory", name, device))
        return _result(self._answer("memory", device), steps, "memory")

    def channel(self, device):
        """The channel probe, answered by the fake."""
        if not self._answers("channel", device):
            return _result(None, [], "channel")
        steps = run_steps(CHANNEL_STEPS, CHANNEL_ALWAYS,
                          lambda name: self._step("channel", name, device))
        return _result(self._answer("channel", device), steps, "channel")

    def _answers(self, kind, device):
        """True when the fake file says something about this probe.

        A file that says nothing about a probe does not answer it: the
        probe was not tested, and the row says so.  A file that answers
        the probe but names no step of it answers the steps it names and
        passes the rest.
        """
        if self._answer(kind, device) is not None:
            return True
        steps = self.fake.get(STEPS_KEY % kind)
        return isinstance(steps, dict) and bool(steps)

    def identity(self, device):
        """The identity of the card, answered by the fake."""
        answer = self._answer("identity", device)
        if answer is None:
            return "not_tested", "the fake does not answer the identity", {}
        status = _answer_status(answer, "the fake answer for the identity")
        wrong = _wrong_card(answer, device)
        if wrong is not None:
            return FAIL, wrong, {}
        reason = answer.get("message") or "the identity of the device matches the card"
        extra = {}
        for key in ("rm_index", "uuid_sha256"):
            if key in answer:
                extra[key] = answer[key]
        if "uuid_sha256" not in extra and isinstance(answer.get("uuid"), str):
            hashed = redact.hashed_uuid(answer["uuid"])
            if hashed:
                extra["uuid_sha256"] = hashed
        return status, reason, extra

    def device_open(self, device):
        """Opening the device, answered by the fake."""
        answer = self._answer("device_open", device) or self._answer("identity", device)
        if answer is None:
            return "not_tested", "the fake does not answer the device open"
        status = _answer_status(answer, "the fake answer for the device open")
        wrong = _wrong_card(answer, device)
        if wrong is not None:
            return FAIL, wrong
        reason = answer.get("message") or "the device opened"
        return status, reason

    def uvm(self, device):
        """The unified memory interface, answered by the fake."""
        return self._simple("uvm", device)

    def prime(self, device):
        """The import path, answered by the fake."""
        return self._simple("prime", device)

    def display(self, device):
        """The display path, answered by the fake."""
        return self._simple("display", device)

    def _simple(self, kind, device):
        """A check that the fake answers as a whole."""
        answer = self._answer(kind, device)
        if answer is None:
            return "not_tested", "the fake does not answer the %s check" % kind
        status = _answer_status(answer, "the fake answer for the %s check" % kind)
        reason = answer.get("message") or "the %s check was answered by the fake" % kind
        return status, reason

    def environment(self):
        """The environment of the machine, answered by the fake."""
        answer = self._answer("environment")
        if answer is None:
            return "not_tested", "the fake does not answer the environment", {}
        status = _answer_status(answer, "the fake answer for the environment")
        reason = answer.get("message") or "the environment was answered by the fake"
        facts = answer.get("facts") if isinstance(answer.get("facts"), dict) else {}
        return status, reason, facts


def _wrong_card(answer, device):
    """The reason the fake opened another card, or None.

    The fake may name the card it opened: when it names another card
    than the one of the machine, the identity failed.
    """
    vendor = str(answer.get("pci_vendor", "")).lower()
    devid = str(answer.get("pci_device", "")).lower()
    if not vendor and not devid:
        return None
    same_vendor = not vendor or vendor == device["vendor"].lower()
    same_device = not devid or devid == device["device"].lower()
    if same_vendor and same_device:
        return None
    return ("the device that opened is %s:%s, not the card %s:%s"
            % (vendor or "?", devid or "?",
               device["vendor"].lower(), device["device"].lower()))


class AdapterBackend(object):
    """A backend that asks the adapter of one vendor.

    The adapter holds the knowledge of one vendor; this holds the order
    of the steps and what a failure means.  A step the adapter did not
    answer is a failure: the probe never reports a step it did not run.
    """

    def __init__(self, adapter, prefixes=()):
        self.adapter = adapter
        self.prefixes = list(prefixes)

    def _steps(self, kind, device, index):
        """The steps the adapter answered, or the reason there are none."""
        method = getattr(self.adapter, STEPS_KEY % kind, None)
        if method is None:
            return None, "the adapter of this card has no %s probe" % kind
        try:
            answer = method(device, index, self.prefixes)
        except Exception as exc:  # never a traceback: the row says what failed
            return None, "the %s probe failed: %s: %s" % (kind, type(exc).__name__, exc)
        if not isinstance(answer, dict):
            return None, "the %s probe answered no step" % kind
        return answer, None

    def _run(self, kind, names, always, device, index):
        """The steps of a probe, run in order."""
        answer, error = self._steps(kind, device, index)
        if error is not None:
            return {"status": FAIL, "reason": error, "steps": []}
        steps = answer.get("steps")
        if not isinstance(steps, dict):
            return {"status": FAIL, "reason": "the %s probe answered no step" % kind,
                    "steps": []}

        def step_function(name):
            one = steps.get(name)
            if not isinstance(one, dict):
                return False, "the probe did not answer the step %s" % name
            status = one.get("status")
            if status in (PASS, "ok"):
                return True, one.get("detail") or "the step %s passed" % name
            return False, one.get("detail") or "the step %s failed" % name

        results = run_steps(names, always, step_function)
        status, reason = fold(results)
        return {"status": status, "reason": reason, "steps": results}

    def memory(self, device):
        """The memory probe of the card."""
        index = device.get("rm_index")
        return self._run("memory", MEMORY_STEPS, MEMORY_ALWAYS, device, index)

    def channel(self, device):
        """The channel probe of the card."""
        index = device.get("rm_index")
        return self._run("channel", CHANNEL_STEPS, CHANNEL_ALWAYS, device, index)

    def identity(self, device):
        """The identity of the card, as the adapter reads it."""
        answer = self.adapter.identity(device, self.prefixes)
        status = answer.get("status") or "not_tested"
        return status, answer.get("reason") or "the identity was not read", \
            answer.get("extra") or {}

    def device_open(self, device):
        """Opening the device, as the adapter did it."""
        answer = self.adapter.device_open(device, self.prefixes)
        status = answer.get("status") or "not_tested"
        return status, answer.get("reason") or "the device was not opened"

    def uvm(self, device):
        """The unified memory interface, as the adapter sees it."""
        answer = self.adapter.uvm(device, self.prefixes)
        status = answer.get("status") or "not_tested"
        return status, answer.get("reason") or "the unified memory interface was not tested"

    def prime(self, device):
        """The import path, as the adapter sees it."""
        answer = self.adapter.prime(device, self.prefixes)
        status = answer.get("status") or "not_tested"
        return status, answer.get("reason") or "the import path was not tested"

    def display(self, device):
        """The display path, as the adapter sees it."""
        answer = self.adapter.display(device, self.prefixes)
        status = answer.get("status") or "not_tested"
        return status, answer.get("reason") or "the display path was not tested"



def _result(whole, steps, kind):
    """The result of a probe: the file's answer, or the folded steps.

    A file that says nothing about the probe did not test it: the result
    says so, and the row carries the reason.
    """
    if whole is None and not steps:
        return {"status": NOT_TESTED,
                "reason": "the fake does not answer the %s probe" % kind,
                "steps": []}
    if whole is not None:
        status = _answer_status(whole, "the fake answer for the %s probe" % kind)
        reason = whole.get("message") or whole.get("detail") or ""
        if status in (PASS, "ok"):
            status = PASS
        return {"status": status, "reason": reason or "%d steps passed" % len(steps),
                "steps": steps}
    status, reason = fold(steps)
    return {"status": status, "reason": reason, "steps": steps}


class CaptureBackend(object):
    """A backend that replays a recorded run.

    The capture is a document (schema gpu-check-capture/1) holding, for
    each card of the recorded run, the steps of the probes and the facts
    of the identity.  A recorded run is evidence: the rows of a check
    that ran then are the rows this backend answers now.
    """

    def __init__(self, document):
        self.document = document if isinstance(document, dict) else {}
        self.devices = {}
        for entry in self.document.get("devices") or []:
            if not isinstance(entry, dict):
                continue
            selector = _selector_of(entry)
            if isinstance(selector, str):
                self.devices[selector] = entry

    def _entry(self, device):
        return self.devices.get(device.get("selector"))

    def memory(self, device):
        """The memory probe of the recorded run."""
        entry = self._entry(device)
        if entry is None:
            return {"status": "not_tested",
                    "reason": NO_CAPTURE_RECORD
                              % device.get("selector"),
                    "steps": []}
        steps = _recorded_steps(entry.get("memory"))
        status, reason = fold(steps)
        return {"status": status, "reason": reason, "steps": steps}

    def channel(self, device):
        """The channel probe of the recorded run."""
        entry = self._entry(device)
        if entry is None:
            return {"status": "not_tested",
                    "reason": NO_CAPTURE_RECORD
                              % device.get("selector"),
                    "steps": []}
        steps = _recorded_steps(entry.get("channel"))
        status, reason = fold(steps)
        return {"status": status, "reason": reason, "steps": steps}

    def identity(self, device):
        """The identity of the card, as the recorded run saw it."""
        entry = self._entry(device)
        if entry is None:
            return "not_tested", NO_CAPTURE_RECORD \
                   % device.get("selector"), {}
        identity = entry.get("identity")
        if not isinstance(identity, dict):
            return "not_tested", "the capture holds no identity for the card %s" \
                   % device.get("selector"), {}
        extra = {}
        if isinstance(identity.get("uuid_sha256"), str):
            extra["uuid_sha256"] = identity["uuid_sha256"]
        if isinstance(identity.get("rm_index"), int):
            extra["rm_index"] = identity["rm_index"]
        return PASS, identity.get("reason") or "the identity of the card is recorded", extra

    def device_open(self, device):
        """Opening the device, as the recorded run saw it."""
        entry = self._entry(device)
        if entry is None:
            return "not_tested", NO_CAPTURE_RECORD \
                   % device.get("selector")
        opened = entry.get("device_open")
        if not isinstance(opened, dict):
            return "not_tested", "the capture holds no device open for the card %s" \
                   % device.get("selector")
        status = opened.get("status") or "not_tested"
        return status, opened.get("reason") or "the device opened"

    def uvm(self, device):
        """The unified memory interface, as the recorded run saw it."""
        return self._recorded_fact(device, "uvm", "the unified memory interface")

    def prime(self, device):
        """The import path, as the recorded run saw it."""
        return self._recorded_fact(device, "prime", "the import path")

    def display(self, device):
        """The display path, as the recorded run saw it."""
        return self._recorded_fact(device, "display", "the display path")

    def _recorded_fact(self, device, name, what):
        """One fact of the recorded run of a card."""
        entry = self._entry(device)
        if entry is None:
            return "not_tested", NO_CAPTURE_RECORD \
                   % device.get("selector")
        fact = entry.get(name)
        if not isinstance(fact, dict):
            return "not_tested", "the capture holds no %s for the card %s" \
                   % (what, device.get("selector"))
        status = fact.get("status") or "not_tested"
        return status, fact.get("reason") or ("the %s was recorded" % what)

    def environment(self):
        """The environment of the recorded run."""
        facts = self.document.get("environment")
        if not isinstance(facts, dict):
            return "not_tested", "the capture holds no environment", {}
        status = facts.get("status") or "not_tested"
        return status, facts.get("reason") or "the environment is recorded", facts


def _selector_of(entry):
    """The selector of a card of a capture.

    The card of a capture is nested under "card"; the selector of the
    pciconf address is what names it.
    """
    card = entry.get("card")
    if isinstance(card, dict) and isinstance(card.get("selector"), str):
        return card["selector"]
    selector = entry.get("selector")
    return selector if isinstance(selector, str) else None


def _recorded_steps(record):
    """The steps of a recorded probe."""
    if not isinstance(record, dict):
        return []
    steps = []
    for step in record.get("steps") or []:
        if not isinstance(step, dict):
            continue
        name = step.get("name")
        if not isinstance(name, str):
            continue
        steps.append({"name": name,
                      "status": step.get("status") or NOT_REACHED,
                      "detail": step.get("detail") or ""})
    return steps

#!/usr/bin/env python3
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# gpu_check_unit.py - the unit tests of the library of the gpu-check
# command.
#
# The command is tested from the outside (tests/gpu_check_test.sh drives it
# and reads what it prints).  This file tests the library from the inside:
# the paths a command never takes, because a command never reaches them (a
# registry with two checks of one name, a record without a family, a fake
# answer with a status that means nothing, a home directory that is not one).
# Those paths are the ones that break a machine in the middle of a test
# boot, so they are tested here.
#
# Usage: gpu_check_unit.py <library dir>
# Prints one line per case; exits 1 when a case failed.

import os
import sys

PASSED = 0
FAILED = 0


def ok(name):
    global PASSED
    PASSED += 1
    print("ok   %s" % name)


def bad(name, detail):
    global FAILED
    FAILED += 1
    print("FAIL %s: %s" % (name, detail))


def case(name, function):
    """Run one case; the exception it raises is a failure."""
    try:
        function()
    except Exception as exc:  # a case that raises is a case that failed
        bad(name, "%s: %s" % (type(exc).__name__, exc))
        return
    ok(name)


class Machine(object):
    """A machine that answers what the test says it answers."""

    def __init__(self, listing=(), loads=None, capture=None):
        self.listing = list(listing)
        self.loads = loads or {}
        self.attempted = []
        self.loaded = []
        self.already = []
        self.is_capture = capture is not None
        self.capture = capture

    def module_listing(self):
        return list(self.listing)

    def kldload(self, name):
        self.attempted.append(name)
        answer = self.loads.get(name)
        if answer is None:
            return "not_available", "the module %s is not installed" % name
        status, message = answer
        if status == "pass":
            self.loaded.append(name)
        return status, message

    def capture_entry(self, selector):
        if self.capture is None:
            return None
        return self.capture.get(selector)


class Probe(object):
    """A probe that answers what the test says it answers."""

    def __init__(self, **answers):
        self.answers = answers

    def _answer(self, name, device):
        answer = self.answers.get(name)
        if callable(answer):
            return answer(device)
        return answer

    def device_open(self, device):
        return self._answer("device_open", device)

    def identity(self, device):
        return self._answer("identity", device)

    def memory(self, device):
        return self._answer("memory", device)

    def channel(self, device):
        return self._answer("channel", device)

    def uvm(self, device):
        return self._answer("uvm", device)

    def prime(self, device):
        return self._answer("prime", device)

    def display(self, device):
        return self._answer("display", device)

    def environment(self):
        return self._answer("environment", None)


def device():
    return {"name": "vgapci0", "selector": "pci0:0:2:0", "vendor": "0x10de",
            "device": "0x2d04", "subvendor": "0x1462", "subdevice": "0x5351",
            "class": "0x030000", "revision": "0xa1"}


def context(machine=None, probe=None, decision=None, family=None, backend=None):
    from gpu_check.context import Context

    return Context(device(), decision or {"code": "supported", "reason": "it is served"},
                    machine or Machine(), probe or Probe(), family=family,
                    backend=backend)


def main(argv):
    if len(argv) != 2:
        sys.stderr.write("usage: gpu_check_unit.py <library dir>\n")
        return 2
    sys.path.insert(0, argv[1])
    from gpu_check import FAIL, NOT_AVAILABLE, NOT_TESTED, PASS, checks, probes
    from gpu_check import environment, redact, registry, table

    # --- the registry -------------------------------------------------------

    def duplicate():
        one = registry.Check("unit-duplicate", "a check", None)
        registry.register(one)
        try:
            registry.register(registry.Check("unit-duplicate", "another", None))
        except ValueError as exc:
            assert "registered twice" in str(exc), exc
            return
        raise AssertionError("the second check of one name was accepted")

    case("the registry refuses two checks of one name", duplicate)

    def unknown():
        assert registry.get("no-such-check") is None
        wanted, missing = registry.resolve(["no-such-check", "no-such-check"])
        assert wanted == [], wanted
        assert missing == ["no-such-check"], missing

    case("the registry says which ids it does not know", unknown)

    def order():
        wanted, missing = registry.resolve(["memory"])
        assert missing == [], missing
        ids = [check.id for check in wanted]
        assert ids[-1] == "memory", ids
        assert "identity" in ids and "device-open" in ids, ids
        # the rows are printed in the order of the registry, not in the
        # order they ran in
        printed = [check.id for check in registry.ordered(wanted)]
        assert printed == sorted(printed, key=lambda one: registry.index_of(
            registry.get(one))), printed

    case("the registry runs a check after the ones it depends on", order)

    def index():
        assert registry.index_of(registry.get("detect")) == 1
        try:
            registry.index_of(registry.Check("unit-none", "x", None))
        except KeyError:
            return
        raise AssertionError("the number of a check that is not registered was given")

    case("the registry numbers the checks", index)

    def decision():
        assert registry.decision_check().id == "decide"
        assert registry.defaults(), registry.defaults()

    case("the registry holds the decision check and the default ones", decision)

    # --- the table ----------------------------------------------------------

    def plain():
        rows = [{"name": "detect", "status": PASS, "reason": "the card was found"}]
        text = table.render(rows, colour=False, width=80)
        assert "CHECK" in text and "DETAIL" in text, text
        assert "\033" not in text, text

    case("the table is plain text when the colour is off", plain)

    def coloured():
        rows = [{"name": "detect", "status": FAIL, "reason": "it failed"}]
        text = table.render(rows, colour=True, width=80)
        assert "\033[31m" in text, repr(text)

    case("the table is coloured when the reader is a terminal", coloured)

    def wrap():
        rows = [{"name": "detect", "status": PASS,
                 "reason": "one two three four five six seven eight nine ten"}]
        text = table.render(rows, colour=False, width=40)
        assert len(text.splitlines()) > 1, text

    case("a long detail wraps under its row", wrap)

    def counting():
        assert table.summary([]) == "no checks were run"
        rows = [{"name": "a", "status": PASS, "reason": ""},
                {"name": "b", "status": NOT_TESTED, "reason": ""}]
        assert table.summary(rows) == "1 passed, 1 not tested", table.summary(rows)

    case("the summary counts the rows", counting)

    def colour_rules():
        os.environ["NO_COLOR"] = "1"
        try:
            assert table.use_colour() is False
        finally:
            del os.environ["NO_COLOR"]
        assert table.terminal_width() == table.DEFAULT_WIDTH

    case("NO_COLOR says no and a pipe has the default width", colour_rules)

    # --- the redaction ------------------------------------------------------

    def hashed():
        assert redact.hashed_uuid("GPU-1234") == redact.hashed_uuid("GPU-1234")
        assert redact.hashed_uuid("") is None
        assert redact.hashed_uuid(None) is None
        assert redact.hashed_uuid("GPU-1234").startswith("sha256:")

    case("the UUID is hashed and never printed", hashed)

    def scrubbed():
        assert redact.scrub("") == ""
        assert redact.scrub(None) is None
        assert redact.scrub(42) == 42
        assert "redacted" in redact.scrub("serial: ABCD1234")
        assert redact.scrub("nothing to hide") == "nothing to hide"

    case("the text is scrubbed of the serial numbers", scrubbed)

    def records():
        out = redact.redact({"serial": "ABC", "uuid": "GPU-1", "other": ["x", 1]})
        assert out["serial"] == redact.REDACTED, out
        assert out["uuid"].startswith("sha256:"), out
        assert out["other"] == ["x", 1], out
        # a UUID that cannot be hashed is redacted, not printed
        out = redact.redact({"uuid": None})
        assert out["uuid"] == redact.REDACTED, out

    case("the report holds no serial and no UUID", records)

    def homes():
        old = os.environ.get("HOME")
        os.environ["HOME"] = "not-a-path"
        try:
            assert redact._home() is None
        finally:
            if old is None:
                del os.environ["HOME"]
            else:
                os.environ["HOME"] = old

    case("a home that is not a path is no home", homes)

    # --- the environment ----------------------------------------------------

    def linux_layer():
        assert environment.is_linux_layer("linux") is True
        assert environment.is_linux_layer("linux64elf") is True
        assert environment.is_linux_layer("drm-kmod") is True
        assert environment.is_linux_layer("nvidia") is False
        assert environment.is_linux_layer("kernel") is False
        assert environment.is_linux_layer("") is False
        listing = ["nvidia", "nvidia", "linux", "kernel"]
        assert environment.loaded_modules(listing) == ["nvidia", "linux"]
        # the real listing of kldstat: a module on its own, and a module
        # that came with another one
        text = ("Id Refs Address                Size Name\n"
                " 1  183 0xffff000000000000  1594e28 kernel (/boot/kernel)\n"
                "\tContains modules:\n"
                "\t\t Id Name\n"
                "\t\t295 cubic\n"
                " 5    1 0xffff0005cb800000   993000 nvidia.ko (/boot/nvidia.ko)\n"
                "\tContains modules:\n"
                "\t\t675 nvidia\n")
        names = environment.loaded_modules(text)
        assert "Name" not in names, names
        assert "modules:" not in names, names
        assert "cubic" in names, names
        assert "nvidia" in names, names
        assert "kernel" not in names, names
        facts = environment.environment_facts(text)
        assert facts["linux_layer"] == [], facts

    case("the rules of the Linux layer read one listing", linux_layer)

    # --- the checks ---------------------------------------------------------

    def refused():
        ctx = context(decision={"code": "below_policy", "reason": "too old"})
        assert ctx.refused is True
        row = checks._firmware(ctx)
        assert row["status"] == NOT_TESTED, row
        assert "too old" in row["reason"], row

    case("a refused card is never touched", refused)

    def no_family():
        ctx = context(family=None)
        row = checks._firmware(ctx)
        assert row["status"] == NOT_AVAILABLE, row
        assert "no firmware" in row["reason"], row

    case("a card without a family has no firmware to load", no_family)

    def no_backend():
        ctx = context(backend=None)
        row = checks._driver_loaded(ctx)
        assert row["status"] == NOT_AVAILABLE, row
        assert "no backend" in row["reason"], row

    case("a card without a backend has no driver to load", no_backend)

    def empty_backend():
        class Backend(object):
            name = "rm-open"
            modules = ()

        ctx = context(backend=Backend())
        row = checks._driver_loaded(ctx)
        assert row["status"] == NOT_AVAILABLE, row
        assert "names no module" in row["reason"], row

    case("a backend without modules names no driver", empty_backend)

    def no_driver():
        ctx = context()
        row = checks._memory(ctx)
        assert row["status"] == NOT_TESTED, row
        assert "driver was not loaded" in row["reason"], row

    case("a check that needs the driver says so when it is not loaded", no_driver)

    def native_modules():
        ctx = context(machine=Machine(listing=["nvidia", "linux"]))
        row = checks._no_linux_layer(ctx)
        assert row["status"] == FAIL, row
        assert "Linux layer" in row["reason"], row

    case("a module of the Linux layer fails the check of the environment", native_modules)

    # --- the probes ---------------------------------------------------------

    def fake_answers():
        fake = probes.FakeBackend({"memory": {"status": "pass", "message": "it did"}})
        device_one = device()
        out = fake.memory(device_one)
        assert out["status"] == PASS, out
        assert len(out["steps"]) == len(probes.MEMORY_STEPS), out
        # a fake file that says nothing about a probe did not test it
        out = probes.FakeBackend({}).memory(device_one)
        assert out["status"] == NOT_TESTED, out

    case("the fake backend answers what the file says and nothing else", fake_answers)

    def fake_device_open():
        # A fake file that answers neither the device open nor the identity
        # did not open the device: the row says so.  Every answer of the
        # fake backend has the same shape, so the caller can unpack it.
        fake = probes.FakeBackend({})
        status, reason = fake.device_open(device())
        assert status == NOT_TESTED, status
        assert reason, reason
        ctx = context(probe=fake)
        ctx.state["driver_modules"] = ["nvidia"]
        row = checks._device_open(ctx)
        assert row["status"] == NOT_TESTED, row
        assert row["reason"], row

    case("a fake that does not answer the device open says so", fake_device_open)

    def fake_steps():
        fake = probes.FakeBackend({"memory_steps": {"vaspace": {"status": "fail",
                                                                "detail": "no space"}}})
        out = fake.memory(device())
        assert out["status"] == FAIL, out
        assert out["reason"].startswith("vaspace:"), out
        # the steps after the one that failed were not reached
        reached = [step["status"] for step in out["steps"]]
        assert "not_reached" in reached, out

    case("a step that failed stops the steps after it", fake_steps)

    def bad_answers():
        for bad_one in ({"memory": {"status": "maybe"}},
                        {"memory": "not an object"},
                        {"kldload": {"nvidia": "not an object"}},
                        {"memory_steps": {"vaspace": {"status": "maybe"}}}):
            try:
                probes.check_answers(bad_one)
            except probes.FakeAnswerError:
                continue
            raise AssertionError("the fake file was accepted: %r" % (bad_one,))
        try:
            probes.check_answers("not an object")
        except probes.FakeAnswerError:
            return
        raise AssertionError("a fake file that is not an object was accepted")

    case("a fake file with a status that means nothing is refused", bad_answers)

    def captures():
        document = {"devices": [{"card": {"selector": "pci0:0:2:0"},
                                 "memory": {"steps": [{"name": "client_open",
                                                       "status": "pass",
                                                       "detail": "opened"}]},
                                 "identity": {"rm_index": 0, "reason": "it matched"}}]}
        backend = probes.CaptureBackend(document)
        out = backend.memory(device())
        assert out["status"] == PASS, out
        assert out["reason"] == "1 steps passed", out
        # a capture that holds no record of this card did not test it
        out = backend.memory({"selector": "pci0:0:9:9"})
        assert out["status"] == NOT_TESTED, out
        # a capture without an environment says so
        assert backend.environment()[0] == NOT_TESTED

    case("a recorded run answers with what it recorded", captures)

    def adapter_missing():
        class NoAdapter(object):
            pass

        backend = probes.AdapterBackend(NoAdapter(), [])
        out = backend.memory(device())
        assert out["status"] == FAIL, out
        assert "no memory probe" in out["reason"], out

    case("an adapter without a probe says so", adapter_missing)

    def adapter_failed():
        class Broken(object):
            def memory_steps(self, device, index, prefixes):
                raise RuntimeError("the card fell over")

        backend = probes.AdapterBackend(Broken(), [])
        out = backend.memory(device())
        assert out["status"] == FAIL, out
        assert "the card fell over" in out["reason"], out

    case("a probe that raised says so and never a traceback", adapter_failed)

    print("passed: %d failed: %d" % (PASSED, FAILED))
    return 1 if FAILED else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

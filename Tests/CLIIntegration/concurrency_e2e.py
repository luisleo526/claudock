#!/usr/bin/env python3
"""Parallel launches against one profile registry, driven through the real `claudock` binary.

Supervisors start many `claudock run` processes at the same moment. Launches only read the
registry, so they must share it and wait briefly when another Claudock process is changing
it, instead of failing with "Another profile update is in progress". A profile change made
at the same time must also succeed and leave a valid registry.

Runs in a throwaway home (see claudock_e2e.py) with a fake `claude`. Only subscription
profiles are used, so the check creates no Keychain item; launches merely look up inference
tokens that do not exist. No real profile, credential, shell file, or Claude executable is used.
"""

import fcntl
import json
import os
import sys
import time

from claudock_e2e import Checks, Sandbox, build_cli, preflight


PROFILES = ["alpha", "bravo", "charlie"]
LAUNCHES = 12


def launch_all(sandbox, label):
    launches = []
    for index in range(LAUNCHES):
        name, run_id = PROFILES[index % len(PROFILES)], f"{label}-{index}"
        launches.append((name, run_id, sandbox.spawn("run", name, "--", "--print", run_id, extra={"CLAUDOCK_E2E_RUN_ID": run_id})))
    return launches


def expect_launches(sandbox, checks, launches, folders, label):
    for name, run_id, process in launches:
        _, stderr = process.communicate(timeout=60)
        checks.expect(process.returncode == 0, f"{label}: run {name} ({run_id}) must succeed, got exit {process.returncode}: {stderr!r}")
        record = sandbox.record(run_id)
        checks.expect(record is not None and record["argv"] == ["--print", run_id], f"{label}: the fake claude must run for {run_id}")
        checks.expect(record["env"].get("CLAUDE_CONFIG_DIR") == folders[name], f"{label}: {run_id} must use {name}'s config folder")


def expect_rename(checks, process, label):
    stdout, stderr = process.communicate(timeout=60)
    checks.expect(process.returncode == 0 and stdout.startswith("Renamed to "),
                  f"{label}: a rename alongside the launches must succeed, got exit {process.returncode}: {stderr!r}")


def main():
    preflight()
    cli = build_cli()
    checks = Checks()
    sandbox = None
    failure = None
    try:
        sandbox = Sandbox(cli, "e2e-parallel")
        for name in PROFILES + ["delta"]:
            result = sandbox.run("profile", "add", name)
            checks.expect(result.returncode == 0, f"the parallel sandbox needs profile {name}", result)
        folders = {name: profile["configDirectory"] for name, profile in sandbox.listed().items()}

        # Another Claudock process holds the registry for a moment, as a profile change does.
        lock = os.open(sandbox.registry_path.parent / ".registry-lock", os.O_RDWR)
        try:
            fcntl.flock(lock, fcntl.LOCK_EX)
            launches = launch_all(sandbox, "held")
            rename = sandbox.spawn("profile", "rename", "delta", "echo")
            time.sleep(1.5)
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)
            os.close(lock)
        expect_launches(sandbox, checks, launches, folders, "while the registry is held")
        expect_rename(checks, rename, "while the registry is held")
        checks.done(f"{LAUNCHES} launches and a rename wait for a held registry, then all succeed")

        launches = launch_all(sandbox, "together")
        rename = sandbox.spawn("profile", "rename", "echo", "foxtrot")
        expect_launches(sandbox, checks, launches, folders, "started together")
        expect_rename(checks, rename, "started together")
        checks.done(f"{LAUNCHES} launches and a rename started together all succeed")

        listed = sandbox.listed()
        checks.expect(set(listed) == {"default", "alpha", "bravo", "charlie", "foxtrot"}, f"the registry must hold every profile once, got {sorted(listed)}")
        checks.expect(listed["foxtrot"]["configDirectory"] == folders["delta"], "the renamed profile must keep its config folder")
        state = json.loads(sandbox.registry_path.read_text())
        checks.expect(state["version"] == 1 and len(state["profiles"]) == 5, "profiles.json must stay a valid registry")
        result = sandbox.run("shell", "profile-names")
        checks.expect(result.returncode == 0 and result.stdout.splitlines()[1:] == ["claude-alpha", "claude-bravo", "claude-charlie", "claude-foxtrot"],
                      "the shell emitter must read the final registry", result)
        checks.done("the registry stays valid after parallel launches and renames")
    except AssertionError as error:
        failure = str(error)
    finally:
        leftovers = sandbox.close()[1] if sandbox else []
    receipt = {"passed": len(checks.passed), "checks": checks.passed, "keychain_items_not_deleted": leftovers,
               "scope": "Real claudock binary in a temporary home; subscription profiles only; fake claude."}
    print(json.dumps(receipt, indent=2))
    if failure:
        print("FAILED: " + failure, file=sys.stderr)
    if failure or leftovers:
        sys.exit(1)


if __name__ == "__main__":
    main()

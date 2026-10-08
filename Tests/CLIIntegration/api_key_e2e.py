#!/usr/bin/env python3
"""Console API-key profiles, driven through the real `claudock` binary.

Builds the CLI with SwiftPM and runs it from outside in throwaway homes (see
claudock_e2e.py) against the real login Keychain. Keys are random synthetic
`sk-ant-api03-` values; a fake `claude` records what each launch received.
Every Keychain item the run creates is deleted before exit, also after a failure,
and any item that could not be deleted is reported. Requires macOS, Xcode, and an
unlocked login Keychain. No real profile, credential, shell file, network
endpoint, or Claude executable is used.
"""

import json
import os
import secrets
import signal
import sys

from claudock_e2e import (Checks, Sandbox, TerminalRun, api_key_service, build_cli, credential_service, delete_keychain_item,
                          keychain_item_exists, preflight)


PROMPT = b"Console API key: "
USAGE_HEADER = "PROFILE\tPLAN\tWINDOW\tUSED_PERCENT\tRESETS_UTC\n"
SKIP_LINE = "claudock: {}: skipped; Console API key profiles are billed per token and have no subscription limits.\n"


def synthetic(prefix="sk-ant-api03-"):
    return prefix + secrets.token_urlsafe(48)


def launched_key(sandbox, checks, name):
    result = sandbox.run("run", name)
    record = sandbox.record()
    checks.expect(result.returncode == 0 and record is not None, f"run {name} must launch the fake claude", result)
    return record["env"].get("ANTHROPIC_API_KEY")


def api_key_profile(sandbox, checks):
    first, second = synthetic(), synthetic()

    result = sandbox.run("profile", "add", "console", "--api-key", stdin=first + "\n")
    checks.expect(result.returncode == 0, "profile add NAME --api-key must accept a key on stdin", result)
    console = sandbox.listed()["console"]
    sandbox.track(api_key_service(console))
    checks.expect(first not in result.stdout + result.stderr, "add output must not contain the key")
    checks.expect(first not in sandbox.registry_path.read_text(), "profiles.json must not contain the key")
    checks.expect(keychain_item_exists(api_key_service(console)), "the key must be stored under its Claudock-apikey Keychain service")
    checks.done("add --api-key reads stdin; key only in Keychain")

    checks.expect(console["kind"] == "api-key", f"profile list must show kind api-key, got {console['kind']!r}")
    checks.done("list shows kind api-key")

    conflicts = {"ANTHROPIC_API_KEY": "synthetic-parent-api-key", "ANTHROPIC_AUTH_TOKEN": "synthetic-parent-auth-token",
                 "ANTHROPIC_BASE_URL": "https://example.invalid", "CLAUDE_CODE_OAUTH_TOKEN": "synthetic-parent-oauth-token",
                 "CLAUDE_CONFIG_DIR": "/synthetic/other-profile", "E2E_UNRELATED": "kept"}
    result = sandbox.run("run", "console", "--", "--resume", "abc", extra=conflicts)
    record = sandbox.record()
    checks.expect(result.returncode == 0 and record is not None, "run must exec the fake claude", result)
    environment = record["env"]
    checks.expect(record["argv"] == ["--resume", "abc"], f"argv must be forwarded literally, got {record['argv']!r}")
    checks.expect(environment.get("ANTHROPIC_API_KEY") == first, "ANTHROPIC_API_KEY must be the stored key")
    checks.expect(environment.get("CLAUDE_CONFIG_DIR") == console["configDirectory"], "CLAUDE_CONFIG_DIR must be the profile's config folder")
    for key in ("CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL"):
        checks.expect(key not in environment, f"{key} must be stripped from an API-key launch")
    checks.expect(environment.get("E2E_UNRELATED") == "kept", "unrelated variables must be kept")
    checks.expect(not any(first in argument for argument in record["argv"]), "the key must not appear in argv")
    checks.expect(record["cwd"] == str(sandbox.base), "run must keep the working directory")
    checks.done("run passes ANTHROPIC_API_KEY only through the environment and strips other auth")

    # claude-console shortcuts call `run claude-console`; Open in Terminal and Continue as… call launch-bound.
    for arguments in (("run", "claude-console", "--", "--resume", "abc"),
                      ("launch-bound", sandbox.registry_id("console"), credential_service(console), "run", "--", "--resume", "abc")):
        result = sandbox.run(*arguments, extra=conflicts)
        record = sandbox.record()
        checks.expect(result.returncode == 0 and record is not None, f"{arguments[0]} must launch the API-key profile", result)
        checks.expect(record["argv"] == ["--resume", "abc"] and record["env"].get("ANTHROPIC_API_KEY") == first
                      and record["env"].get("CLAUDE_CONFIG_DIR") == console["configDirectory"]
                      and not {"CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL"} & set(record["env"]),
                      f"{arguments[0]} must launch with only the stored key")
    checks.done("shortcut selectors and app launches use the key the same way")

    result = sandbox.run("profile", "set-key", "console", stdin=second)
    checks.expect(result.returncode == 0, "set-key must replace the key from stdin", result)
    checks.expect(second not in result.stdout + result.stderr, "set-key output must not contain the key")
    checks.expect(launched_key(sandbox, checks, "console") == second, "run must use the replaced key")
    checks.done("set-key replaces the key")

    registry, accounts = sandbox.registry_bytes(), sandbox.accounts()
    rejected = [("an OAuth token", synthetic("sk-ant-oat01-"), "subscription OAuth token"),
                ("an Admin key", synthetic("sk-ant-admin01-"), "Admin API keys cannot run Claude Code"),
                ("empty input", "", None), ("a plain word", "hello", None),
                ("a key with a space", synthetic() + " " + secrets.token_urlsafe(8), None),
                ("a key with a newline", synthetic() + "\n" + secrets.token_urlsafe(8), None)]
    for label, value, message in rejected:
        for arguments in (("profile", "add", "spare", "--api-key"), ("profile", "set-key", "console")):
            result = sandbox.run(*arguments, stdin=value)
            checks.expect(result.returncode != 0, f"{' '.join(arguments)} must reject {label}", result)
            if value:
                checks.expect(value not in result.stdout + result.stderr, f"rejecting {label} must not echo it")
            if message:
                checks.expect(message in result.stderr, f"rejecting {label} must explain why", result)
            checks.expect(sandbox.registry_bytes() == registry and sandbox.accounts() == accounts,
                          f"rejecting {label} must leave the registry and account folders unchanged")
        checks.done(f"rejects {label} without storing it")
    checks.expect(launched_key(sandbox, checks, "console") == second, "rejected input must not replace the stored key")
    checks.expect("spare" not in sandbox.listed(), "rejected add must not create a profile")

    value = synthetic()
    for arguments in (("profile", "add", "spare", "--api-key", value), ("profile", "add", "spare", "--api-key=" + value),
                      ("profile", "add", "spare", "--api-key", "--directory", str(sandbox.base), value),
                      ("profile", "set-key", "console", value)):
        result = sandbox.run(*arguments)
        checks.expect(result.returncode == 2, "a key given as an argument must be a usage error", result)
        checks.expect(value not in result.stdout + result.stderr, "a usage error must not echo the argument")
        checks.expect(sandbox.registry_bytes() == registry and sandbox.accounts() == accounts, "argument keys must store nothing")
    checks.done("never accepts a key as a command-line argument")

    checks.expect(delete_keychain_item(api_key_service(console)), "could not remove the key to simulate a missing item")
    result = sandbox.run("run", "console")
    checks.expect(result.returncode == 1 and "claudock profile set-key console" in result.stderr,
                  "run without a saved key must fail and name set-key", result)
    checks.expect(sandbox.record() is None, "run without a saved key must not launch claude")
    third = synthetic()
    result = sandbox.run("profile", "set-key", "console", stdin=third)
    checks.expect(result.returncode == 0 and launched_key(sandbox, checks, "console") == third, "set-key must restore a missing key", result)
    checks.done("missing key fails before exec and names set-key")

    result = sandbox.run("profile", "login", "console")
    checks.expect(result.returncode == 1 and "set-key" in result.stderr, "profile login must refuse an API-key profile", result)
    checks.expect(sandbox.record() is None, "a refused login must not launch claude")
    # The app's Re-login reaches the CLI as a bound launch with the registry ID and credential service.
    result = sandbox.run("launch-bound", sandbox.registry_id("console"), credential_service(console), "login", "--")
    checks.expect(result.returncode == 1 and sandbox.record() is None, "a sign-in from the app must also be refused", result)
    checks.done("login refused for API-key profiles")
    return console


def subscription_profile(sandbox, checks):
    result = sandbox.run("profile", "add", "work")
    checks.expect(result.returncode == 0, "a subscription profile must still be added", result)
    work = sandbox.listed()["work"]
    sandbox.track(api_key_service(work))
    checks.expect(work["kind"] == "managed", f"a subscription profile keeps kind managed, got {work['kind']!r}")
    result = sandbox.run("run", "work", "--", "--print", "hi", extra={"ANTHROPIC_API_KEY": "synthetic-parent-api-key"})
    record = sandbox.record()
    checks.expect(result.returncode == 0 and record is not None, "a subscription profile must still launch", result)
    checks.expect("ANTHROPIC_API_KEY" not in record["env"], "a subscription launch must not carry ANTHROPIC_API_KEY")
    checks.expect(record["env"].get("CLAUDE_CONFIG_DIR") == work["configDirectory"] and record["argv"] == ["--print", "hi"],
                  "a subscription launch keeps its config folder and arguments")
    checks.done("subscription profile launches without ANTHROPIC_API_KEY")

    result = sandbox.run("profile", "set-key", "work", stdin=synthetic())
    checks.expect(result.returncode == 1, "set-key must refuse a subscription profile", result)
    checks.expect(not keychain_item_exists(api_key_service(work)), "a refused set-key must store nothing")
    checks.done("set-key refuses subscription profiles")


def terminal_prompt(sandbox, checks):
    key = synthetic()
    terminal = TerminalRun(sandbox, "profile", "set-key", "console")
    try:
        checks.expect(terminal.read_until(PROMPT), f"a terminal must show the prompt, got {terminal.output!r}")
        checks.expect(not terminal.echo_enabled(), "echo must be off while the key is typed")
        terminal.send(key.encode() + b"\n")
        status, stdout = terminal.finish()
        checks.expect(status == 0, f"set-key at a terminal must succeed, got {status}")
        checks.expect(key.encode() not in terminal.output and key not in stdout, "the typed key must not be echoed or printed")
        checks.expect(terminal.echo_enabled(), "echo must be restored after the key is read")
    finally:
        terminal.close()
    checks.expect(launched_key(sandbox, checks, "console") == key, "the key typed at the prompt must be saved")
    checks.done("terminal prompt hides input and restores echo")

    terminal = TerminalRun(sandbox, "profile", "set-key", "console")
    try:
        checks.expect(terminal.read_until(PROMPT) and not terminal.echo_enabled(), "the prompt must hide input")
        terminal.process.send_signal(signal.SIGINT)
        status, _ = terminal.finish()
        checks.expect(status == -signal.SIGINT, f"SIGINT must still end the command, got {status}")
        checks.expect(terminal.echo_enabled(), "echo must be restored after SIGINT")
    finally:
        terminal.close()
    checks.expect(launched_key(sandbox, checks, "console") == key, "an interrupted prompt must not change the key")
    checks.done("SIGINT at the prompt restores echo")

    replacement = synthetic()
    terminal = TerminalRun(sandbox, "profile", "set-key", "console")
    try:
        checks.expect(terminal.read_until(PROMPT) and not terminal.echo_enabled(), "the prompt must hide input")
        os.kill(terminal.process.pid, signal.SIGTSTP)
        checks.expect(terminal.wait_for_echo(True), "echo must be restored while the command is stopped")
        os.kill(terminal.process.pid, signal.SIGCONT)
        checks.expect(terminal.read_until(PROMPT, count=2), "the prompt must return after the command continues")
        checks.expect(terminal.wait_for_echo(False), "echo must be off again after the command continues")
        terminal.send(replacement.encode() + b"\n")
        status, _ = terminal.finish()
        checks.expect(status == 0 and terminal.echo_enabled(), f"the resumed prompt must finish and restore echo, got {status}")
        checks.expect(replacement.encode() not in terminal.output, "the resumed prompt must not echo the key")
    finally:
        terminal.close()
    checks.expect(launched_key(sandbox, checks, "console") == replacement, "the key typed after resuming must be saved")
    checks.done("stop and continue at the prompt restore and re-hide echo")


def removal(sandbox, checks, console):
    service = api_key_service(console)
    result = sandbox.run("profile", "remove", "console")
    checks.expect(result.returncode == 0, "profile remove must succeed", result)
    checks.expect(service in result.stdout, "removal must print the key's Keychain service name", result)
    checks.expect("console" not in sandbox.listed(), "the profile must be removed from the registry")
    checks.expect(keychain_item_exists(service), "removal must keep the Keychain item")
    checks.done("remove keeps the Keychain item and prints its service")


def usage_skip(cli, checks, sandboxes):
    sandbox = Sandbox(cli, "e2e-usage")
    sandboxes.append(sandbox)
    result = sandbox.run("profile", "add", "solo", "--api-key", stdin=synthetic())
    checks.expect(result.returncode == 0, "the usage sandbox needs an API-key profile", result)
    profiles = sandbox.listed()
    sandbox.track(api_key_service(profiles["solo"]))
    checks.expect(set(profiles) == {"default", "solo"} and profiles["default"]["kind"] == "needs-import",
                  f"the usage sandbox must hold only the API-key profile and an unresolved default, got {profiles!r}")
    result = sandbox.run("usage")
    checks.expect(SKIP_LINE.format("solo") in result.stderr, "usage must print the API-key skip line", result)
    checks.expect(result.returncode == 0, "an API-key profile must not make usage fail", result)
    checks.expect(result.stdout == USAGE_HEADER, "usage must print no readings for an API-key profile", result)
    checks.done("usage skips API-key profiles without failing")


def help_text(sandbox, checks):
    result = sandbox.run("help")
    for text in ("profile add NAME --api-key", "profile set-key NAME", "standard input"):
        checks.expect(text in result.stdout, f"help must document {text!r}", result)
    checks.done("help documents API-key commands and stdin input")


def main():
    preflight()
    cli = build_cli()
    checks = Checks()
    sandboxes = []
    failure = None
    try:
        sandbox = Sandbox(cli, "e2e-console")
        sandboxes.append(sandbox)
        console = api_key_profile(sandbox, checks)
        subscription_profile(sandbox, checks)
        terminal_prompt(sandbox, checks)
        removal(sandbox, checks, console)
        usage_skip(cli, checks, sandboxes)
        help_text(sandbox, checks)
    except AssertionError as error:
        failure = str(error)
    finally:
        deleted, leftovers = [], []
        for sandbox in sandboxes:
            removed, remaining = sandbox.close()
            deleted += removed
            leftovers += remaining
    receipt = {"passed": len(checks.passed), "checks": checks.passed,
               "keychain_items_deleted_at_teardown": deleted, "keychain_items_not_deleted": leftovers,
               "scope": "Real claudock binary and login Keychain in temporary homes; synthetic keys; fake claude."}
    print(json.dumps(receipt, indent=2))
    if failure:
        print("FAILED: " + failure, file=sys.stderr)
    if failure or leftovers:
        sys.exit(1)


if __name__ == "__main__":
    main()

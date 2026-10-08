#!/usr/bin/env python3
"""Inference tokens set from the CLI, driven through the real `claudock` binary.

Builds the CLI with SwiftPM and runs it from outside in a throwaway home (see
claudock_e2e.py) against the real login Keychain. Tokens are random synthetic
`sk-ant-oat01-` values; a fake `claude` records what each launch received.
Every Keychain item the run creates is deleted before exit, also after a failure,
and any item that could not be deleted is reported. Requires macOS, Xcode, and an
unlocked login Keychain. No real profile, credential, shell file, network
endpoint, or Claude executable is used.
"""

import json
import secrets
import sys

from claudock_e2e import (Checks, Sandbox, TerminalRun, api_key_service, build_cli, inference_service, keychain_item_exists,
                          preflight)


PROMPT = b"Inference token: "
HEADER = "PROFILE\tTOKEN_STATUS\tEXPIRES_UTC\n"


def synthetic(prefix="sk-ant-oat01-"):
    return prefix + secrets.token_urlsafe(48)


def token_rows(sandbox, checks, secret=None):
    result = sandbox.run("profile", "tokens")
    checks.expect(result.returncode == 0 and result.stdout.startswith(HEADER), "profile tokens must list token statuses", result)
    if secret:
        checks.expect(secret not in result.stdout + result.stderr, "profile tokens must not print token material")
    return {fields[0]: fields[1:] for fields in (line.split("\t") for line in result.stdout.splitlines()[1:])}


def launched_token(sandbox, checks, name):
    result = sandbox.run("run", name, "--", "--print", "hi")
    record = sandbox.record()
    checks.expect(result.returncode == 0 and record is not None, f"run {name} must launch the fake claude", result)
    checks.expect(not any(value.startswith("sk-ant-") for value in record["argv"]), "a token must not appear in argv")
    checks.expect("ANTHROPIC_API_KEY" not in record["env"], "a subscription launch must not carry ANTHROPIC_API_KEY")
    return record["env"].get("CLAUDE_CODE_OAUTH_TOKEN")


def tokens_from_stdin(sandbox, checks):
    first = synthetic()
    result = sandbox.run("profile", "set-token", "work", stdin=first + "\n")
    checks.expect(result.returncode == 0, "set-token must accept a token on stdin", result)
    checks.expect(first not in result.stdout + result.stderr, "set-token output must not contain the token")
    checks.expect(keychain_item_exists(inference_service(sandbox.listed()["work"])), "the token must be stored under its Claudock-inference service")
    rows = token_rows(sandbox, checks, first)
    checks.expect(rows.get("work") == ["pasted-unverified", "unknown"], f"a pasted token without expiry is listed as such, got {rows.get('work')!r}")
    checks.expect(rows.get("console") == ["n/a", "-"] and rows.get("default") == ["n/a", "-"],
                  f"API-key and unresolved profiles have no token status, got {rows!r}")
    checks.done("set-token reads stdin; tokens lists pasted-unverified without token material")

    checks.expect(launched_token(sandbox, checks, "work") == first, "run must pass the token as CLAUDE_CODE_OAUTH_TOKEN")
    checks.done("run passes the saved token only through the environment")

    second = synthetic()
    result = sandbox.run("profile", "set-token", "work", "--expires", "2001-01-01T00:00:00Z", stdin=second)
    checks.expect(result.returncode == 0, "set-token must accept a past --expires", result)
    checks.expect(token_rows(sandbox, checks, second).get("work") == ["expired", "2001-01-01T00:00:00Z"], "an expired token is listed with its expiry")
    result = sandbox.run("run", "work")
    checks.expect(result.returncode == 1 and "has expired" in result.stderr, "run must fail on an expired token", result)
    checks.expect("claudock profile set-token work" in result.stderr, "the expired-token message must name set-token", result)
    checks.expect(sandbox.record() is None, "an expired token must not launch claude")
    checks.done("an expired token makes run fail with the expired-token message")

    third = synthetic()
    for expires, listed in (("2099-06-30", "2099-06-30T00:00:00Z"), ("2099-12-31T23:59:59Z", "2099-12-31T23:59:59Z")):
        result = sandbox.run("profile", "set-token", "work", "--expires", expires, stdin="export CLAUDE_CODE_OAUTH_TOKEN='" + third + "'")
        checks.expect(result.returncode == 0, f"set-token must accept --expires {expires} and an export line", result)
        checks.expect(token_rows(sandbox, checks, third).get("work") == ["pasted-unverified", listed], f"--expires {expires} must be recorded")
    checks.expect(launched_token(sandbox, checks, "work") == third, "a future expiry keeps the token usable")
    checks.done("--expires accepts ISO 8601 dates; export lines are accepted")
    return third


def rejections(sandbox, checks, stored):
    before = token_rows(sandbox, checks)
    first, second, third = synthetic("sk-ant-api03-"), synthetic(), synthetic()
    # (label, input, its secret part). A bare prefix is not secret: error messages name it.
    for label, value, secret in (("empty input", "", None), ("a plain word", "hello", None), ("a Console API key", first, first),
                                 ("an empty token", "sk-ant-oat01-", None),
                                 ("a token with a space", second + " " + secrets.token_urlsafe(8), second),
                                 ("an export with a command", "export CLAUDE_CODE_OAUTH_TOKEN=" + third + "; touch never-run", third)):
        result = sandbox.run("profile", "set-token", "work", stdin=value)
        checks.expect(result.returncode != 0, f"set-token must reject {label}", result)
        if secret:
            checks.expect(secret not in result.stdout + result.stderr, f"rejecting {label} must not echo it")
        checks.expect(not (sandbox.base / "never-run").exists(), "token input must never be executed")
        checks.done(f"rejects {label}")
    checks.expect(token_rows(sandbox, checks) == before and launched_token(sandbox, checks, "work") == stored,
                  "rejected input must not change the stored token")

    value = synthetic()
    for arguments in (("profile", "set-token", "work", value), ("profile", "set-token", "work", "--expires", "2099-01-01", value),
                      ("profile", "set-token", "work", "--expires"), ("profile", "set-token", "work", "--expires", "not-a-date"),
                      ("profile", "set-token", "work", "--expires", "2099-13-01"), ("profile", "tokens", "work"),
                      ("profile", "set-token", value), ("run", value)):
        result = sandbox.run(*arguments, stdin=value)
        checks.expect(result.returncode == 2, f"{' '.join(arguments[:4])} must be a usage error", result)
        checks.expect(value not in result.stdout + result.stderr, "a usage error must not echo a token")
    checks.expect(launched_token(sandbox, checks, "work") == stored, "usage errors must not change the stored token")
    checks.done("never accepts a token argument; rejects invalid --expires")

    console = sandbox.listed()["console"]
    result = sandbox.run("profile", "set-token", "console", stdin=synthetic())
    checks.expect(result.returncode == 1 and "Console API key" in result.stderr, "set-token must refuse an API-key profile", result)
    checks.expect(not keychain_item_exists(inference_service(console)), "a refused set-token must store nothing")
    result = sandbox.run("profile", "set-token", "default", stdin=synthetic())
    checks.expect(result.returncode == 1, "set-token must refuse an unresolved profile", result)
    checks.done("set-token refuses API-key and unresolved profiles")


def terminal_prompt(sandbox, checks):
    token = synthetic()
    terminal = TerminalRun(sandbox, "profile", "set-token", "work")
    try:
        checks.expect(terminal.read_until(PROMPT), f"a terminal must show the token prompt, got {terminal.output!r}")
        checks.expect(not terminal.echo_enabled(), "echo must be off while the token is typed")
        terminal.send(token.encode() + b"\n")
        status, stdout = terminal.finish()
        checks.expect(status == 0 and terminal.echo_enabled(), f"set-token at a terminal must succeed and restore echo, got {status}")
        checks.expect(token.encode() not in terminal.output and token not in stdout, "the typed token must not be echoed or printed")
    finally:
        terminal.close()
    checks.expect(launched_token(sandbox, checks, "work") == token, "the token typed at the prompt must be saved")
    checks.done("terminal prompt hides the token")


def help_text(sandbox, checks):
    result = sandbox.run("help")
    for text in ("profile set-token NAME [--expires ISO8601_DATE]", "profile tokens", "claudock run NAME -- setup-token",
                 "pbpaste | claudock profile set-token NAME"):
        checks.expect(text in result.stdout, f"help must document {text!r}", result)
    checks.done("help documents set-token, tokens, and the setup-token flow")


def main():
    preflight()
    cli = build_cli()
    checks = Checks()
    sandboxes = []
    failure = None
    try:
        sandbox = Sandbox(cli, "e2e-tokens")
        sandboxes.append(sandbox)
        result = sandbox.run("profile", "add", "work")
        checks.expect(result.returncode == 0, "the token sandbox needs a subscription profile", result)
        sandbox.track(inference_service(sandbox.listed()["work"]))
        result = sandbox.run("profile", "add", "console", "--api-key", stdin=synthetic("sk-ant-api03-"))
        checks.expect(result.returncode == 0, "the token sandbox needs an API-key profile", result)
        console = sandbox.listed()["console"]
        sandbox.track(api_key_service(console))
        sandbox.track(inference_service(console))
        stored = tokens_from_stdin(sandbox, checks)
        rejections(sandbox, checks, stored)
        terminal_prompt(sandbox, checks)
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
               "scope": "Real claudock binary and login Keychain in a temporary home; synthetic tokens; fake claude."}
    print(json.dumps(receipt, indent=2))
    if failure:
        print("FAILED: " + failure, file=sys.stderr)
    if failure or leftovers:
        sys.exit(1)


if __name__ == "__main__":
    main()

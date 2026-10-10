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
from pathlib import Path
import secrets
import sys
import types

from claudock_e2e import (DEFAULT_PROFILE_SERVICES, Checks, Sandbox, TerminalRun, api_key_service, build_cli, check_removal,
                          clean_up_on_termination, credential_service, delete_keychain_item, inference_service,
                          keychain_item_exists, managed_key_service, preflight, read_policy_preference,
                          refuse_default_profile_item, restore_policy_preference)


PROMPT = b"Inference token: "
HEADER = "PROFILE\tTOKEN_STATUS\tEXPIRES_UTC\n"
# Synthetic logins for a profile's .claude.json. They share an organization, so only the account differs.
ACCOUNT_A = ("11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222")
ACCOUNT_B = ("33333333-3333-4333-8333-333333333333", "22222222-2222-4222-8222-222222222222")


def synthetic(prefix="sk-ant-oat01-"):
    return prefix + secrets.token_urlsafe(48)


def setup_token_hint(name):
    return (f"Sign the browser in to the claude.ai account for {name} first. "
            f"When the token is shown, save it with: pbpaste | claudock profile set-token {name}\n")


def token_required_error(name):
    return (f"claudock: {name} has no valid inference token and Claudock requires one. Create one with "
            f"'claudock profile setup-token {name}', then 'pbpaste | claudock profile set-token {name}'.\n")


def mismatch_error(name):
    return (f"claudock: {name}'s saved inference token belongs to a different account than its current Claude login. "
            f"Sign in with the token's account: claudock profile login {name} — or make a new token: "
            f"claudock profile setup-token {name}, then pbpaste | claudock profile set-token {name}.\n")


def sign_in_as(sandbox, name, account):
    """Records a Claude login for the profile the way Claude Code does: the account in its own .claude.json."""
    directory = Path(sandbox.listed()[name]["configDirectory"]).resolve()
    if sandbox.base not in directory.parents:
        raise AssertionError(f"refusing to write a login outside the sandbox: {directory}")
    (directory / ".claude.json").write_text(json.dumps({"oauthAccount": {"accountUuid": account[0], "organizationUuid": account[1]}}))


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
    checks.expect("claudock profile setup-token work" in result.stderr and "run work -- setup-token" not in result.stderr,
                  "the expired-token message must recommend profile setup-token", result)
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


def require_token_policy(sandbox, checks, api_key):
    result = sandbox.run("profile", "add", "bare")
    checks.expect(result.returncode == 0, "the policy check needs a subscription profile without a token", result)
    bare = sandbox.listed()["bare"]
    sandbox.track(inference_service(bare))
    for arguments in (("require-token",), ("require-token", "maybe"), ("require-token", "on", "extra")):
        result = sandbox.run(*arguments)
        checks.expect(result.returncode == 2, f"{' '.join(arguments)} must be a usage error", result)

    result = sandbox.run("require-token", "on")
    checks.expect(result.returncode == 0, "require-token on must succeed", result)
    checks.expect(read_policy_preference() is True, "require-token on must set the shared preference")
    result = sandbox.run("require-token", "status")
    checks.expect(result.returncode == 0 and result.stdout == "on\n", "require-token status must print on", result)
    checks.done("require-token on sets the shared preference")

    for arguments in (("run", "bare"), ("run", "bare", "--", "--resume", "abc"),
                      ("launch-bound", sandbox.registry_id("bare"), credential_service(bare), "run", "--", "--resume", "abc")):
        result = sandbox.run(*arguments)
        checks.expect(result.returncode == 1 and result.stderr == token_required_error("bare"),
                      f"{arguments[0]} without a token must be refused", result)
        checks.expect(sandbox.record() is None, "a refused launch must not run claude")
    checks.done("policy on: no token refuses run, Open in Terminal, and Continue as…")

    token = synthetic()
    result = sandbox.run("profile", "set-token", "work", stdin=token)
    checks.expect(result.returncode == 0, "set-token must work while the policy is on", result)
    checks.expect(launched_token(sandbox, checks, "work") == token, "policy on: a valid pasted token must be passed")
    checks.done("policy on: a valid token launches with CLAUDE_CODE_OAUTH_TOKEN")

    result = sandbox.run("profile", "set-token", "work", "--expires", "2001-01-01T00:00:00Z", stdin=synthetic())
    checks.expect(result.returncode == 0, "set-token must accept an expired token", result)
    result = sandbox.run("run", "work")
    checks.expect(result.returncode == 1 and result.stderr == token_required_error("work"), "policy on: an expired token must be refused", result)
    checks.expect(sandbox.record() is None, "an expired token must not run claude")
    checks.done("policy on: an expired token is refused")

    for name in ("bare", "work"):
        result = sandbox.run("run", name, "--", "setup-token")
        record = sandbox.record()
        checks.expect(result.returncode == 0 and record is not None and record["argv"] == ["setup-token"],
                      f"setup-token must run for {name} while the policy is on", result)
        checks.expect("CLAUDE_CODE_OAUTH_TOKEN" not in record["env"], "setup-token must run on the profile's own login")
    checks.done("policy on: setup-token runs without a token")

    for arguments in (("profile", "login", "bare"), ("launch-bound", sandbox.registry_id("bare"), credential_service(bare), "login", "--")):
        result = sandbox.run(*arguments)
        record = sandbox.record()
        checks.expect(result.returncode == 0 and record is not None and record["argv"] == ["auth", "login", "--claudeai"],
                      f"{arguments[0]} sign-in must stay available while the policy is on", result)
    checks.done("policy on: sign-in is exempt")

    result = sandbox.run("run", "console")
    record = sandbox.record()
    checks.expect(result.returncode == 0 and record is not None and record["env"].get("ANTHROPIC_API_KEY") == api_key
                  and "CLAUDE_CODE_OAUTH_TOKEN" not in record["env"], "policy on: an API-key profile must launch with its key", result)
    checks.done("policy on: API-key profiles launch with ANTHROPIC_API_KEY")

    result = sandbox.run("profile", "tokens")
    checks.expect(result.returncode == 0 and result.stderr.endswith("require-token: on\n"), "tokens must report the policy", result)

    result = sandbox.run("require-token", "off")
    checks.expect(result.returncode == 0 and not read_policy_preference(), "require-token off must clear the shared preference", result)
    result = sandbox.run("require-token", "status")
    checks.expect(result.returncode == 0 and result.stdout == "off\n", "require-token status must print off", result)
    result = sandbox.run("run", "bare")
    record = sandbox.record()
    checks.expect(result.returncode == 0 and record is not None and "CLAUDE_CODE_OAUTH_TOKEN" not in record["env"],
                  "policy off: a profile without a token must use its own login", result)
    result = sandbox.run("profile", "tokens")
    checks.expect(result.returncode == 0 and result.stderr.endswith("require-token: off\n"), "tokens must report the policy", result)
    checks.done("policy off: no token falls back to the profile's own login")

    # "work" still holds the expired pasted token: setup-token must still create its replacement.
    result = sandbox.run("run", "work", "--", "setup-token")
    record = sandbox.record()
    checks.expect(result.returncode == 0 and record is not None and record["argv"] == ["setup-token"]
                  and "CLAUDE_CODE_OAUTH_TOKEN" not in record["env"],
                  "policy off: setup-token must run on the profile's own login despite an expired token", result)
    checks.done("policy off: an expired token does not block setup-token")


def setup_token_launch(sandbox, checks, name, state, extra=None):
    """`profile setup-token NAME` must hand Claude exactly `setup-token`, on the profile's own login."""
    result = sandbox.run("profile", "setup-token", name, extra=extra)
    record = sandbox.record()
    checks.expect(result.returncode == 0 and record is not None, f"profile setup-token {name} must run claude {state}", result)
    checks.expect(record["argv"] == ["setup-token"], f"claude must get exactly ['setup-token'] {state}, got {record['argv']!r}")
    checks.expect(result.stdout == "" and result.stderr == setup_token_hint(name),
                  f"profile setup-token must print only its hint on stderr {state}", result)
    for key in ("CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"):
        checks.expect(key not in record["env"], f"{key} must not reach setup-token {state}")
    return record


def setup_token_command(sandbox, checks):
    work = sandbox.listed()["work"]
    saved = synthetic()
    result = sandbox.run("profile", "set-token", "work", stdin=saved)
    checks.expect(result.returncode == 0, "the setup-token checks need a saved token", result)
    conflicts = {"ANTHROPIC_API_KEY": "synthetic-parent-api-key", "ANTHROPIC_AUTH_TOKEN": "synthetic-parent-auth-token",
                 "CLAUDE_CODE_OAUTH_TOKEN": "synthetic-parent-oauth-token", "CLAUDE_CONFIG_DIR": "/synthetic/other-profile",
                 "E2E_UNRELATED": "kept"}
    record = setup_token_launch(sandbox, checks, "work", "with a saved token", extra=conflicts)
    checks.expect(record["env"].get("CLAUDE_CONFIG_DIR") == work["configDirectory"],
                  "setup-token must run in the profile's own config folder")
    checks.expect(record["env"].get("E2E_UNRELATED") == "kept" and record["cwd"] == str(sandbox.base),
                  "setup-token must keep unrelated variables and the working directory")
    checks.expect(saved not in json.dumps(record), "the saved token must not reach setup-token")
    checks.expect(launched_token(sandbox, checks, "work") == saved, "setup-token must leave the saved token in place")
    checks.done("profile setup-token runs setup-token on the profile's own login, apart from the saved token")

    result = sandbox.run("profile", "set-token", "work", "--expires", "2001-01-01T00:00:00Z", stdin=synthetic())
    checks.expect(result.returncode == 0, "set-token must accept an expired token", result)
    result = sandbox.run("run", "work")
    checks.expect(result.returncode == 1 and "has expired" in result.stderr and sandbox.record() is None,
                  "run must still refuse the expired token", result)
    setup_token_launch(sandbox, checks, "work", "with an expired saved token")
    checks.done("profile setup-token runs although the saved token has expired")

    result = sandbox.run("profile", "add", "fresh")
    checks.expect(result.returncode == 0, "the policy check needs a subscription profile without a token", result)
    sandbox.track(inference_service(sandbox.listed()["fresh"]))
    result = sandbox.run("require-token", "on")
    checks.expect(result.returncode == 0, "require-token on must succeed", result)
    for name, state in (("work", "with an expired saved token while the policy is on"),
                        ("fresh", "without a token while the policy is on")):
        setup_token_launch(sandbox, checks, name, state)
    result = sandbox.run("run", "fresh")
    checks.expect(result.returncode == 1 and result.stderr == token_required_error("fresh") and sandbox.record() is None,
                  "the policy must still refuse run without a token", result)
    result = sandbox.run("require-token", "off")
    checks.expect(result.returncode == 0 and not read_policy_preference(), "require-token off must clear the shared preference", result)
    checks.done("profile setup-token runs while the policy is on")


def account_mismatch(sandbox, checks):
    """A pasted token remembers the login it was saved under. Once the login moves to another account, launches
    stop with guidance and every way out stays available."""
    work = sandbox.listed()["work"]
    sign_in_as(sandbox, "work", ACCOUNT_A)
    bound = synthetic()
    result = sandbox.run("profile", "set-token", "work", stdin=bound)
    checks.expect(result.returncode == 0, "the mismatch checks need a token saved under account A", result)
    checks.expect(launched_token(sandbox, checks, "work") == bound, "the token must launch while the login still matches")
    sign_in_as(sandbox, "work", ACCOUNT_B)

    for label, arguments in (("run", ("run", "work")), ("run with arguments", ("run", "work", "--", "--resume", "abc")),
                             ("launch-bound", ("launch-bound", sandbox.registry_id("work"), credential_service(work), "run", "--", "--resume", "abc")),
                             ("run with a flag before setup-token", ("run", "work", "--", "--dangerously-skip-permissions", "setup-token"))):
        result = sandbox.run(*arguments)
        checks.expect(result.returncode == 1 and result.stdout == "" and result.stderr == mismatch_error("work"),
                      f"{label} must stop with the account guidance", result)
        checks.expect(sandbox.record() is None, f"{label} must not run claude")
        checks.expect(bound not in result.stdout + result.stderr, f"{label} must not print the token")
    checks.done("run and launch-bound stop with guidance when the token belongs to another account")

    setup_token_launch(sandbox, checks, "work", "when the saved token belongs to another account")
    result = sandbox.run("run", "work", "--", "setup-token")
    record = sandbox.record()
    checks.expect(result.returncode == 0 and record is not None and record["argv"] == ["setup-token"]
                  and "CLAUDE_CODE_OAUTH_TOKEN" not in record["env"], "run NAME -- setup-token must still run", result)
    result = sandbox.run("profile", "login", "work")
    record = sandbox.record()
    checks.expect(result.returncode == 0 and record is not None and record["argv"] == ["auth", "login", "--claudeai"],
                  "profile login must still run", result)
    result = sandbox.run("require-token", "on")
    checks.expect(result.returncode == 0, "require-token on must succeed", result)
    setup_token_launch(sandbox, checks, "work", "when the saved token belongs to another account while the policy is on")
    result = sandbox.run("run", "work")
    checks.expect(result.returncode == 1 and result.stderr == token_required_error("work") and sandbox.record() is None,
                  "with the policy on, a token of another account is refused like any invalid token", result)
    result = sandbox.run("require-token", "off")
    checks.expect(result.returncode == 0 and not read_policy_preference(), "require-token off must clear the shared preference", result)
    checks.done("setup-token, run -- setup-token, and login stay available when the token belongs to another account")

    sign_in_as(sandbox, "work", ACCOUNT_A)
    checks.expect(launched_token(sandbox, checks, "work") == bound, "signing in with the token's account must make the token usable again")
    sign_in_as(sandbox, "work", ACCOUNT_B)
    replacement = synthetic()
    result = sandbox.run("profile", "set-token", "work", stdin=replacement)
    checks.expect(result.returncode == 0, "set-token must replace a token that belongs to another account", result)
    checks.expect(launched_token(sandbox, checks, "work") == replacement, "the replacement token must launch under the current login")
    checks.done("signing in with the token's account, or saving a new token, makes run work again")


def setup_token_rejections(sandbox, checks):
    result = sandbox.run("profile", "setup-token", "console")
    checks.expect(result.returncode == 1 and "Console API key" in result.stderr and "Inference tokens are only for" in result.stderr,
                  "profile setup-token must refuse an API-key profile", result)
    checks.expect(sandbox.record() is None and "Sign the browser in" not in result.stderr, "a refused profile must not run claude or print the hint")
    result = sandbox.run("profile", "setup-token", "default")
    checks.expect(result.returncode == 1 and "cannot be launched safely" in result.stderr and sandbox.record() is None
                  and "Sign the browser in" not in result.stderr, "profile setup-token must refuse an unresolved profile", result)
    checks.done("profile setup-token refuses API-key and unresolved profiles")

    value = synthetic()
    for arguments in (("profile", "setup-token"), ("profile", "setup-token", "work", "extra"),
                      ("profile", "setup-token", "work", "--expires", "2099-01-01"),
                      ("profile", "setup-token", "work", value), ("profile", "setup-token", value)):
        result = sandbox.run(*arguments, stdin=value)
        checks.expect(result.returncode == 2, f"{' '.join(arguments[:4])} must be a usage error", result)
        checks.expect(value not in result.stdout + result.stderr, "a usage error must not echo a token")
        checks.expect(sandbox.record() is None, "a usage error must not run claude")
        if len(arguments) > 3:
            checks.expect("claudock profile setup-token NAME" in result.stderr, "extra arguments must get the setup-token usage", result)
    checks.done("profile setup-token takes only a profile name")


def clear_token(sandbox, checks):
    """`profile clear-token` deletes the saved inference token and nothing else."""
    work = sandbox.listed()["work"]
    login = credential_service(work)
    # Claude Code keeps the profile's login in an item of its own; a synthetic one stands in for it.
    sandbox.create_keychain_item(login)
    token = synthetic()
    result = sandbox.run("profile", "set-token", "work", stdin=token)
    checks.expect(result.returncode == 0 and keychain_item_exists(inference_service(work)), "clear-token needs a saved token to delete", result)

    result = sandbox.run("profile", "clear-token", "work")
    checks.expect(result.returncode == 0 and result.stderr == "", "clear-token must delete the saved token", result)
    checks.expect("work" in result.stdout and inference_service(work) in result.stdout, "clear-token must say what it deleted", result)
    checks.expect(token not in result.stdout + result.stderr, "clear-token must not print the token")
    checks.expect(not keychain_item_exists(inference_service(work)), "the inference-token item must be gone")
    checks.expect(keychain_item_exists(login), "clear-token must leave Claude Code's own login alone")
    rows = token_rows(sandbox, checks, token)
    checks.expect(rows.get("work") == ["none", "-"], f"tokens must show none after clear-token, got {rows.get('work')!r}")
    checks.expect(launched_token(sandbox, checks, "work") is None, "run must use the profile's own login once its token is cleared")
    checks.done("clear-token deletes only the saved inference token; tokens shows none; run uses the profile's own login")

    result = sandbox.run("profile", "clear-token", "work")
    checks.expect(result.returncode == 1 and result.stdout == "" and "No inference token is saved for 'work'" in result.stderr,
                  "clear-token with no saved token must exit 1 and say so", result)
    checks.expect(keychain_item_exists(login), "a clear-token with nothing to delete must leave Claude Code's own login alone")
    checks.done("clear-token with no saved token exits 1 with a clear message")

    saved = synthetic()
    result = sandbox.run("profile", "set-token", "work", stdin=saved)
    checks.expect(result.returncode == 0, "set-token must work again after clear-token", result)
    checks.expect(launched_token(sandbox, checks, "work") == saved, "a token saved after clear-token must launch")
    checks.done("a token can be saved again after clear-token")

    result = sandbox.run("require-token", "on")
    checks.expect(result.returncode == 0, "require-token on must succeed", result)
    result = sandbox.run("profile", "clear-token", "work")
    checks.expect(result.returncode == 0 and "requires an inference token" in result.stdout and saved not in result.stdout + result.stderr,
                  "clear-token must warn that launches are refused while a token is required", result)
    result = sandbox.run("run", "work")
    checks.expect(result.returncode == 1 and result.stderr == token_required_error("work") and sandbox.record() is None,
                  "with require-token on, run must be refused after the token is cleared", result)
    result = sandbox.run("require-token", "off")
    checks.expect(result.returncode == 0 and not read_policy_preference(), "require-token off must clear the shared preference", result)
    checks.done("require-token on: a launch is refused once the token is cleared")

    # Arguments: only a profile name; nothing is deleted by a usage error.
    value = synthetic()
    result = sandbox.run("profile", "set-token", "work", stdin=value)
    checks.expect(result.returncode == 0, "set-token must save the token the usage errors must not delete", result)
    for arguments in (("profile", "clear-token"), ("profile", "clear-token", "work", "extra"),
                      ("profile", "clear-token", "work", "--expires", "2099-01-01"), ("profile", "clear-token", value)):
        result = sandbox.run(*arguments, stdin=value)
        checks.expect(result.returncode == 2, f"{' '.join(arguments[:4])} must be a usage error", result)
        checks.expect(value not in result.stdout + result.stderr, "a usage error must not echo a token")
        if len(arguments) > 3:
            checks.expect("claudock profile clear-token NAME" in result.stderr, "extra arguments must get the clear-token usage", result)
    checks.expect(launched_token(sandbox, checks, "work") == value, "usage errors must not delete the saved token")
    result = sandbox.run("profile", "clear-token", "work")
    checks.expect(result.returncode == 0, "clear-token must delete the token the usage errors left", result)
    checks.done("clear-token takes only a profile name")

    # Claude Code's own login and the other kinds of profile.
    console = sandbox.listed()["console"]
    sandbox.create_keychain_item(inference_service(console))
    result = sandbox.run("profile", "clear-token", "console")
    checks.expect(result.returncode == 1 and "Console API key" in result.stderr and "Inference tokens are only for" in result.stderr,
                  "clear-token must refuse an API-key profile", result)
    checks.expect(keychain_item_exists(inference_service(console)), "a refused clear-token must delete nothing")
    checks.expect(delete_keychain_item(inference_service(console)), "could not remove the synthetic item the refusal check created")
    result = sandbox.run("profile", "clear-token", "default")
    checks.expect(result.returncode == 1 and "Choose a supported Claude subscription profile" in result.stderr,
                  "clear-token must refuse an unresolved profile", result)
    checks.expect(keychain_item_exists(login), "refused clear-token commands must leave Claude Code's own login alone")
    checks.done("clear-token refuses API-key and unresolved profiles")


def removal(sandbox, checks):
    """`profile remove` keeps every credential and lists the Keychain items that exist for the profile."""
    result = sandbox.run("profile", "add", "gone")
    checks.expect(result.returncode == 0, "the removal checks need a subscription profile", result)
    gone = sandbox.listed()["gone"]
    for service in (credential_service(gone), managed_key_service(gone), inference_service(gone), api_key_service(gone)):
        sandbox.track(service)
    # A login Claude Code saved, stood in for by a synthetic item, and a token saved with set-token.
    sandbox.create_keychain_item(credential_service(gone))
    token = synthetic()
    result = sandbox.run("profile", "set-token", "gone", stdin=token)
    checks.expect(result.returncode == 0, "the removal check needs a saved token", result)
    result = check_removal(sandbox, checks, "gone", present={"login", "inference token"})
    checks.expect(token not in result.stdout + result.stderr, "remove must not print the token")
    checks.done("remove lists the login and the inference token that exist, with their delete commands, the folder, and the revoke reminder")

    result = sandbox.run("profile", "add", "nothing")
    checks.expect(result.returncode == 0, "the removal checks need a profile with no Keychain items", result)
    nothing = sandbox.listed()["nothing"]
    for service in (credential_service(nothing), managed_key_service(nothing), inference_service(nothing), api_key_service(nothing)):
        sandbox.track(service)
    result = check_removal(sandbox, checks, "nothing", present=set())
    checks.expect("security" not in result.stdout and "Keychain" not in result.stdout, "remove must name no Keychain item when none exists", result)
    checks.done("remove prints no delete command for a profile that left no Keychain item")

    # A folder name with an apostrophe still gives a line that can be pasted into a shell. (A control character in a
    # folder name is refused when the profile is added, so it cannot be tried here; check.py covers how it is shown.)
    directory = sandbox.base / "Bob's folder"
    directory.mkdir()
    result = sandbox.run("profile", "add", "apostrophe", "--directory", str(directory))
    checks.expect(result.returncode == 0, "the removal checks need a profile whose folder name has an apostrophe", result)
    odd = sandbox.listed()["apostrophe"]
    for service in (credential_service(odd), managed_key_service(odd), inference_service(odd), api_key_service(odd)):
        sandbox.track(service)
    result = check_removal(sandbox, checks, "apostrophe", present=set())
    checks.expect("Config folder: '" + str(directory) + "'" not in result.stdout and "'\\''" in result.stdout,
                  "the apostrophe in the folder name must be escaped for the shell", result)
    checks.done("remove prints the config folder quoted for the shell, an apostrophe in its name included")


def default_profile_items_are_refused(checks):
    """The helpers must never create, track for deletion, or delete the real default profile's Keychain items. Only
    the guard and `track` are exercised, and `track` on a scratch object, not a live sandbox: a missing guard would
    otherwise put a real item on the teardown list."""
    checks.expect(len(set(DEFAULT_PROFILE_SERVICES)) == 4, "the default profile has four distinct Keychain items")
    scratch = types.SimpleNamespace(services=set())
    for service in DEFAULT_PROFILE_SERVICES:
        for refuse in (refuse_default_profile_item, lambda item: Sandbox.track(scratch, item)):
            try:
                refuse(service)
            except ValueError:
                continue
            raise AssertionError(f"the harness must refuse the default profile's Keychain item {service!r}")
    checks.expect(scratch.services == set(), "no default item may be tracked for deletion")
    checks.done("the harness refuses the default profile's Keychain items")


def help_text(sandbox, checks):
    result = sandbox.run("help")
    for text in ("profile set-token NAME [--expires ISO8601_DATE]", "profile tokens", "run NAME -- setup-token",
                 "pbpaste | claudock profile set-token NAME", "require-token on|off|status", "profile clear-token NAME"):
        checks.expect(text in result.stdout, f"help must document {text!r}", result)
    checks.expect(result.stdout.count("claudock profile setup-token NAME") >= 2,
                  "help must list profile setup-token in its usage and in the token flow", result)
    checks.expect("claudock run NAME -- setup-token" not in result.stdout, "help must recommend profile setup-token instead", result)
    checks.done("help documents set-token, tokens, and the setup-token flow")


def main():
    clean_up_on_termination()
    preflight()
    cli = build_cli()
    checks = Checks()
    sandboxes = []
    failure = None
    # The policy lives in the real preferences domain (a temp home cannot isolate it), so restore it.
    original_policy = read_policy_preference()
    try:
        sandbox = Sandbox(cli, "e2e-tokens")
        sandboxes.append(sandbox)
        default_profile_items_are_refused(checks)
        result = sandbox.run("profile", "add", "work")
        checks.expect(result.returncode == 0, "the token sandbox needs a subscription profile", result)
        sandbox.track(inference_service(sandbox.listed()["work"]))
        api_key = synthetic("sk-ant-api03-")
        result = sandbox.run("profile", "add", "console", "--api-key", stdin=api_key)
        checks.expect(result.returncode == 0, "the token sandbox needs an API-key profile", result)
        console = sandbox.listed()["console"]
        sandbox.track(api_key_service(console))
        sandbox.track(inference_service(console))
        stored = tokens_from_stdin(sandbox, checks)
        rejections(sandbox, checks, stored)
        terminal_prompt(sandbox, checks)
        require_token_policy(sandbox, checks, api_key)
        setup_token_command(sandbox, checks)
        account_mismatch(sandbox, checks)
        setup_token_rejections(sandbox, checks)
        clear_token(sandbox, checks)
        removal(sandbox, checks)
        help_text(sandbox, checks)
    except AssertionError as error:
        failure = str(error)
    finally:
        policy_restored = restore_policy_preference(cli, original_policy)
        deleted, leftovers = [], []
        for sandbox in sandboxes:
            removed, remaining = sandbox.close()
            deleted += removed
            leftovers += remaining
    receipt = {"passed": len(checks.passed), "checks": checks.passed,
               "keychain_items_deleted_at_teardown": deleted, "keychain_items_not_deleted": leftovers,
               "require_token_preference": {"original": original_policy, "after_teardown": read_policy_preference(),
                                            "restored": policy_restored},
               "scope": "Real claudock binary and login Keychain in a temporary home; synthetic tokens; fake claude."}
    print(json.dumps(receipt, indent=2))
    if failure:
        print("FAILED: " + failure, file=sys.stderr)
    if failure or leftovers or not policy_restored:
        sys.exit(1)


if __name__ == "__main__":
    main()

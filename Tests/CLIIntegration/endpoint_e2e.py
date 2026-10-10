#!/usr/bin/env python3
"""Third-party endpoint profiles, driven through the real `claudock` binary.

An endpoint profile runs Claude Code against a third-party service that speaks the Anthropic Messages protocol,
such as DeepSeek, with one model pinned into every model slot. These checks build the CLI with SwiftPM and run it
from outside in throwaway homes (see claudock_e2e.py) against the real login Keychain. Keys are random synthetic
values shaped like a DeepSeek key; a fake `claude` records what each launch received, and no request reaches the
endpoint. Every Keychain item the run creates is deleted before exit, also after a failure. Like token_e2e.py, it
turns the shared requireInferenceToken setting on and off through the CLI and restores its original value. No real
profile, credential, shell file, network endpoint, or Claude executable is used.
"""

import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import sys
import tempfile

from claudock_e2e import (PROJECT, Checks, Sandbox, build_cli, check_removal, clean_up_on_termination, credential_service,
                          endpoint_key_service, inference_service, keychain_item_exists, preflight, read_policy_preference,
                          restore_policy_preference)


URL = "https://api.deepseek.com/anthropic"
HOST = "api.deepseek.com"
MODEL = "deepseek-flash"
OTHER_URL = "https://gateway.example.test:8443/v1/anthropic/"
OTHER_MODEL = "deepseek-flash[1m]"
USAGE_HEADER = "PROFILE\tPLAN\tWINDOW\tUSED_PERCENT\tRESETS_UTC\n"
# Every variable a launch clears, read from the source so the expected environment follows it.
CLEARED = set(re.findall(r'"([A-Z_]+)"', (PROJECT / "Sources/UsageCore/LaunchCommand.swift").read_text().split("public static func quote")[0]))
HOSTILE = {"ANTHROPIC_API_KEY": "synthetic-parent-api-key", "ANTHROPIC_AUTH_TOKEN": "synthetic-parent-auth-token",
           "ANTHROPIC_BASE_URL": "https://parent.example.invalid", "ANTHROPIC_MODEL": "claude-opus-5-5",
           "ANTHROPIC_SMALL_FAST_MODEL": "claude-haiku-5-5", "CLAUDE_CODE_SUBAGENT_MODEL": "opus",
           "CLAUDE_CONFIG_DIR": "/synthetic/other-profile", "CLAUDE_CODE_OAUTH_TOKEN": "synthetic-parent-oauth-token",
           "OTEL_EXPORTER_OTLP_ENDPOINT": "https://otel.example.invalid", "OTEL_LOGS_EXPORTER": "otlp",
           "CLAUDE_CODE_ENABLE_TELEMETRY": "1", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "0", "E2E_UNRELATED": "kept"}
LITERAL_ARGUMENTS = ["-p", "a b", "quote'word", "$(touch SHOULD_NOT_EXIST)", "; echo bad"]


def synthetic_key():
    return "sk-" + secrets.token_hex(16)


def endpoint_environment(sandbox, extra, profile, key, url=URL, model=MODEL):
    """What a launch of `profile` must receive: the sandbox's own environment and `extra`, without the cleared and
    telemetry variables, plus the endpoint's."""
    expected = {name: value for name, value in sandbox.environment(extra).items()
                if name not in CLEARED and not name.startswith("OTEL_") and name != "CLAUDE_CODE_ENABLE_TELEMETRY"}
    expected.update({"CLAUDE_CONFIG_DIR": profile["configDirectory"], "ANTHROPIC_BASE_URL": url, "ANTHROPIC_AUTH_TOKEN": key,
                     "ANTHROPIC_MODEL": model, "ANTHROPIC_DEFAULT_OPUS_MODEL": model, "ANTHROPIC_DEFAULT_SONNET_MODEL": model,
                     "ANTHROPIC_DEFAULT_HAIKU_MODEL": model, "ANTHROPIC_DEFAULT_FABLE_MODEL": model, "ANTHROPIC_SMALL_FAST_MODEL": model,
                     "CLAUDE_CODE_SUBAGENT_MODEL": model, "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
                     "DISABLE_NON_ESSENTIAL_MODEL_CALLS": "1"})
    return expected


def recorded_environment(record):
    # macOS gives every process its text encoding; it is not part of what Claudock decides.
    return {name: value for name, value in record["env"].items() if name != "__CF_USER_TEXT_ENCODING"}


def claude_arguments(record):
    """The arguments the user passed: Claudock adds its own `--settings` before them."""
    argv = record["argv"]
    return argv[2:] if argv[:1] == ["--settings"] else argv


def launched_key(sandbox, checks, name, *arguments):
    result = sandbox.run("run", name, *(("--", *arguments) if arguments else ()))
    record = sandbox.record()
    checks.expect(result.returncode == 0 and record is not None, f"run {name} must launch the fake claude", result)
    return record["env"].get("ANTHROPIC_AUTH_TOKEN")


def run_with_file(sandbox, path, *arguments):
    """Runs the CLI with a file as standard input, as `claudock … < FILE` does in a shell."""
    with open(path, "rb") as handle:
        return subprocess.run([str(sandbox.cli), *arguments], cwd=sandbox.base, env=sandbox.environment(), stdin=handle,
                              capture_output=True, text=True, timeout=60)


def everything_printed(result):
    return result.stdout + result.stderr


def add_profiles(sandbox, checks):
    first = synthetic_key()
    result = sandbox.run("profile", "add", "deepseek", "--endpoint", URL, "--model", MODEL, stdin=first + "\n")
    checks.expect(result.returncode == 0, "profile add NAME --endpoint URL --model MODEL must accept a key on stdin", result)
    profile = sandbox.listed()["deepseek"]
    sandbox.track(endpoint_key_service(profile))
    checks.expect(profile["kind"] == "endpoint", f"profile list must show kind endpoint, got {profile['kind']!r}")
    checks.expect(profile["endpoint"] is not None and HOST in profile["endpoint"] and MODEL in profile["endpoint"],
                  f"profile list must show the endpoint's host and model, got {profile['endpoint']!r}")
    checks.expect(first not in everything_printed(result), "add output must not contain the key")
    checks.expect(first not in sandbox.registry_path.read_text(), "profiles.json must not contain the key")
    checks.expect(first not in sandbox.run("profile", "list").stdout, "profile list must not contain the key")
    checks.expect(keychain_item_exists(endpoint_key_service(profile)), "the key must be stored under its Claudock-endpointkey Keychain service")
    registry = json.loads(sandbox.registry_path.read_text())
    stored = next(entry for entry in registry["profiles"] if entry["command"] == "claude-deepseek")
    checks.expect(registry["version"] == 3 and stored["authKind"] == "endpoint" and stored["endpoint"] == {"baseURL": URL, "model": MODEL},
                  f"the registry must be version 3 and hold the endpoint, got version {registry['version']!r}: {stored!r}")
    checks.done("add --endpoint reads a raw key from stdin; key only in Keychain; list shows kind, host, and model")

    # The README's form: a shell key file on standard input, `export NAME="value"`.
    second = synthetic_key()
    with tempfile.TemporaryDirectory(prefix="claudock-e2e-endpoint-file-") as folder:
        key_file = Path(folder) / "40-provider.zsh"
        key_file.write_text(f'export DEEPSEEK_API_KEY="{second}"\n')
        key_file.chmod(0o600)
        result = run_with_file(sandbox, key_file, "profile", "add", "flash", "--endpoint", URL, "--model", MODEL)
    checks.expect(result.returncode == 0, "profile add must accept an export line from a key file on stdin", result)
    flash = sandbox.listed()["flash"]
    sandbox.track(endpoint_key_service(flash))
    checks.expect(second not in everything_printed(result), "add output must not contain the key from the file")
    checks.expect(launched_key(sandbox, checks, "flash") == second, "the launch must use the value of the export line, unquoted")
    checks.done("add --endpoint reads an export NAME=\"value\" key file on stdin")
    return profile, first


def launches(sandbox, checks, profile, key):
    result = sandbox.run("run", "deepseek", "--", *LITERAL_ARGUMENTS, extra=HOSTILE)
    record = sandbox.record()
    checks.expect(result.returncode == 0 and record is not None, "run must exec the fake claude", result)
    checks.expect(claude_arguments(record) == LITERAL_ARGUMENTS, f"arguments must be forwarded literally, got {record['argv']!r}")
    checks.expect(not (sandbox.base / "SHOULD_NOT_EXIST").exists(), "arguments must never pass through a shell")
    expected = endpoint_environment(sandbox, HOSTILE, profile, key)
    actual = recorded_environment(record)
    checks.expect(actual == expected, "run must launch with exactly the endpoint environment: "
                  f"unexpected {sorted(set(actual) - set(expected))!r}, missing {sorted(set(expected) - set(actual))!r}, "
                  f"different {sorted(name for name in set(actual) & set(expected) if actual[name] != expected[name])!r}")
    checks.expect("ANTHROPIC_API_KEY" not in actual and not any(name.startswith("OTEL_") for name in actual),
                  "an endpoint launch carries no ANTHROPIC_API_KEY and no OTEL variable")
    checks.expect(not any(key in argument for argument in record["argv"]), "the key must not appear in argv")
    checks.expect(record["cwd"] == str(sandbox.base), "run must keep the working directory")
    checks.expect(key not in everything_printed(result), "a launch must not print the key")
    checks.done("run sets exactly the endpoint environment over a hostile parent, keeps unrelated variables and literal arguments")

    # claude-deepseek shortcuts call `run claude-deepseek`; Open in Terminal and Continue as… call launch-bound.
    for arguments in (("run", "claude-deepseek", "--", "-p", "x"),
                      ("launch-bound", sandbox.registry_id("deepseek"), credential_service(profile), "run", "--", "-p", "x")):
        result = sandbox.run(*arguments, extra=HOSTILE)
        record = sandbox.record()
        checks.expect(result.returncode == 0 and record is not None, f"{arguments[0]} must launch the endpoint profile", result)
        checks.expect(claude_arguments(record) == ["-p", "x"] and recorded_environment(record) == endpoint_environment(sandbox, HOSTILE, profile, key),
                      f"{arguments[0]} {arguments[1]} must launch with the same endpoint environment", result)
    checks.done("shortcut selectors and app launches set the same endpoint environment")

    for arguments in (("--model", "deepseek-v4-pro"), ("--model=deepseek-v4-pro",), ("--fallback-model", "deepseek-v4-pro"),
                      ("--fallback-model=deepseek-flash,deepseek-v4-pro",), ("-p", "hi", "--model", "opus")):
        result = sandbox.run("run", "deepseek", "--", *arguments)
        checks.expect(result.returncode == 2 and sandbox.record() is None, f"run -- {' '.join(arguments)} must be refused before launch", result)
        checks.expect(MODEL in result.stderr and "deepseek-v4-pro" not in result.stderr, "the refusal names the pinned model, not the refused one", result)
    result = sandbox.run("run", "deepseek", "--", "-p", "hi", "--model", MODEL)
    record = sandbox.record()
    checks.expect(result.returncode == 0 and record is not None and claude_arguments(record) == ["-p", "hi", "--model", MODEL],
                  "the pinned --model must be passed on", result)
    result = sandbox.run("launch-bound", sandbox.registry_id("deepseek"), credential_service(profile), "run", "--", "--model", "deepseek-v4-pro")
    checks.expect(result.returncode == 2 and sandbox.record() is None, "app launches refuse another model too", result)
    checks.done("--model / --model= / --fallback-model of another model refused before launch; the pinned model allowed")

    result = sandbox.run("require-token", "on")
    checks.expect(result.returncode == 0 and read_policy_preference() is True, "require-token on must succeed", result)
    result = sandbox.run("run", "deepseek", "--", "-p", "x")
    record = sandbox.record()
    checks.expect(result.returncode == 0 and record is not None and record["env"].get("ANTHROPIC_AUTH_TOKEN") == key
                  and "CLAUDE_CODE_OAUTH_TOKEN" not in record["env"], "require-token on must not block an endpoint launch", result)
    checks.done("require-token on does not block endpoint profiles")


def rejected_input(sandbox, checks):
    registry, accounts = sandbox.registry_bytes(), sandbox.accounts()
    anthropic = "sk-ant-api03-" + secrets.token_urlsafe(32)
    for label, stdin in (("a raw Anthropic key", anthropic), ("an Anthropic key in an export line", f"export DEEPSEEK_API_KEY={anthropic}\n")):
        for arguments in (("profile", "add", "spare", "--endpoint", URL, "--model", MODEL), ("profile", "set-key", "deepseek")):
            result = sandbox.run(*arguments, stdin=stdin)
            checks.expect(result.returncode == 1 and "third-party endpoint" in result.stderr, f"{' '.join(arguments[:2])} must refuse {label}", result)
            checks.expect(anthropic not in everything_printed(result), f"refusing {label} must not echo it")
            checks.expect(sandbox.registry_bytes() == registry and sandbox.accounts() == accounts, f"refusing {label} must store nothing")
    checks.done("an sk-ant- key is refused for an endpoint profile, without echoing or storing it")

    for label, stdin in (("empty input", ""), ("a key with a space", "sk-abc def"), ("two lines", "export A=sk-one\nexport B=sk-two\n")):
        result = sandbox.run("profile", "add", "spare", "--endpoint", URL, "--model", MODEL, stdin=stdin)
        checks.expect(result.returncode == 1 and sandbox.registry_bytes() == registry and sandbox.accounts() == accounts,
                      f"add must refuse {label} without storing anything", result)
    checks.done("malformed key input refused without storing anything")

    secret = synthetic_key()
    for arguments in (("profile", "add", "spare", "--endpoint", "http://api.deepseek.com/anthropic", "--model", MODEL),
                      ("profile", "add", "spare", "--endpoint", "https://user:" + secret + "@api.deepseek.com", "--model", MODEL),
                      ("profile", "add", "spare", "--endpoint", URL + "?key=" + secret, "--model", MODEL),
                      ("profile", "add", "spare", "--endpoint", URL, "--model", "deepseek flash"),
                      ("profile", "add", "spare", "--endpoint", URL, "--model", "deepseek-flash[2m]"),
                      ("profile", "add", "spare", "--endpoint", URL),
                      ("profile", "add", "spare", "--model", MODEL),
                      ("profile", "add", "spare", "--endpoint", URL, "--model", MODEL, "--api-key"),
                      ("profile", "add", "spare", "--endpoint", URL, "--model", MODEL, "--console"),
                      ("profile", "add", "spare", "--endpoint", URL, "--model", MODEL, secret),
                      ("profile", "add", "spare", "--endpoint", URL, "--model", MODEL, "--directory", str(sandbox.base)),
                      ("profile", "set-endpoint", "deepseek", "--endpoint", "http://api.deepseek.com"),
                      ("profile", "set-endpoint", "deepseek", "--model", "two models"),
                      ("profile", "set-endpoint", "deepseek", secret),
                      ("profile", "set-key", "deepseek", secret)):
        result = sandbox.run(*arguments, stdin=synthetic_key())
        checks.expect(result.returncode == 2, f"{' '.join(arguments[:3])} … must be a usage error", result)
        checks.expect(secret not in everything_printed(result), "a usage error must not echo a secret-looking argument", result)
        checks.expect(sandbox.registry_bytes() == registry and sandbox.accounts() == accounts, "a usage error must change nothing")
    checks.done("http URLs, URLs with credentials or a query, bad model ids, and keys as arguments are usage errors")


def change_endpoint(sandbox, checks, profile, key):
    result = sandbox.run("profile", "set-endpoint", "deepseek", "--endpoint", OTHER_URL)
    checks.expect(result.returncode == 0, "set-endpoint --endpoint must succeed", result)
    other = OTHER_URL.rstrip("/")
    result = sandbox.run("run", "deepseek", "--", "-p", "x")
    record = sandbox.record()
    checks.expect(result.returncode == 0 and record is not None and record["env"]["ANTHROPIC_BASE_URL"] == other
                  and record["env"]["ANTHROPIC_MODEL"] == MODEL and record["env"]["ANTHROPIC_AUTH_TOKEN"] == key,
                  "the next launch must use the new endpoint, the same model, and the same key", result)
    result = sandbox.run("profile", "set-endpoint", "deepseek", "--model", OTHER_MODEL)
    checks.expect(result.returncode == 0, "set-endpoint --model must succeed", result)
    result = sandbox.run("run", "deepseek")
    record = sandbox.record()
    checks.expect(result.returncode == 0 and record is not None and recorded_environment(record) == endpoint_environment(sandbox, None, profile, key, other, OTHER_MODEL),
                  "the next launch must pin the new model in every slot")
    listed = sandbox.listed()["deepseek"]["endpoint"]
    checks.expect("gateway.example.test:8443" in listed and OTHER_MODEL in listed, f"profile list must show the new endpoint, got {listed!r}")
    result = sandbox.run("profile", "set-endpoint", "deepseek", "--endpoint", URL, "--model", MODEL)
    checks.expect(result.returncode == 0 and launched_key(sandbox, checks, "deepseek") == key, "both can change at once, keeping the key", result)
    result = sandbox.run("profile", "set-endpoint", "deepseek")
    checks.expect(result.returncode == 0 and URL in result.stdout and MODEL in result.stdout and key not in everything_printed(result),
                  "set-endpoint without options shows the endpoint, never the key", result)
    checks.done("set-endpoint changes the URL and model without touching the key; the next launch uses them")

    replacement = synthetic_key()
    result = sandbox.run("profile", "set-key", "deepseek", stdin=f"DEEPSEEK_API_KEY='{replacement}'\n")
    checks.expect(result.returncode == 0 and replacement not in everything_printed(result), "set-key must replace the endpoint key from stdin", result)
    checks.expect(launched_key(sandbox, checks, "deepseek") == replacement, "the next launch must use the replaced key")
    checks.done("set-key replaces an endpoint key")
    return replacement


def refusals(sandbox, checks, profile):
    for arguments, reason in ((("profile", "set-credit", "deepseek", "5"), "billed per token by the provider"),
                              (("profile", "set-token", "deepseek"), "Inference tokens are only for"),
                              (("profile", "setup-token", "deepseek"), "Inference tokens are only for"),
                              (("profile", "clear-token", "deepseek"), "Inference tokens are only for"),
                              (("profile", "login", "deepseek"), "set-key"),
                              (("profile", "login", "deepseek", "--console"), "set-key"),
                              (("launch-bound", sandbox.registry_id("deepseek"), credential_service(profile), "login", "--"), "set-key")):
        result = sandbox.run(*arguments, stdin="sk-ant-oat01-" + secrets.token_urlsafe(24))
        checks.expect(result.returncode == 1 and reason in result.stderr and result.stderr.count("\n") == 1 and sandbox.record() is None,
                      f"{' '.join(arguments[:2])} must refuse an endpoint profile with a one-line reason", result)
    checks.expect(not keychain_item_exists(inference_service(profile)), "a refused set-token stores nothing")
    checks.done("set-credit, set-token, setup-token, clear-token, and login refuse endpoint profiles")

    rows = {line.split("\t")[0]: line.split("\t") for line in sandbox.run("profile", "tokens").stdout.splitlines()[1:]}
    checks.expect(rows.get("deepseek") == ["deepseek", "n/a", "-"], f"tokens must list the endpoint profile as n/a, got {rows.get('deepseek')!r}")
    checks.done("profile tokens lists endpoint profiles as n/a")


def usage_and_available(cli, checks, sandboxes):
    sandbox = Sandbox(cli, "e2e-endpoint-usage")
    sandboxes.append(sandbox)
    result = sandbox.run("profile", "add", "solo", "--endpoint", URL, "--model", MODEL, stdin=synthetic_key())
    checks.expect(result.returncode == 0, "the usage sandbox needs an endpoint profile", result)
    sandbox.track(endpoint_key_service(sandbox.listed()["solo"]))
    note = f"solo: third-party endpoint ({HOST}, {MODEL}), billed per token by the provider; no quota to read.\n"
    result = sandbox.run("usage")
    checks.expect(result.returncode == 0 and result.stdout == USAGE_HEADER, "usage must print no row for an endpoint profile and exit 0", result)
    checks.expect(result.stderr.count("solo:") == 1 and "claudock: " + note in result.stderr, "usage must print the endpoint note once", result)
    result = sandbox.run("available")
    checks.expect("solo" not in result.stdout, "available must not list an endpoint profile", result)
    checks.expect(result.stderr.count("solo:") == 1 and HOST in result.stderr and "billed per token by the provider" in result.stderr,
                  "available must print one endpoint note", result)
    checks.done("usage and available print one note for an endpoint profile and no row")


def removal(sandbox, checks):
    check_removal(sandbox, checks, "deepseek", present={"endpoint key"})
    checks.done("remove keeps the endpoint key and prints its delete command, the folder, and the revoke reminder")


def help_text(sandbox, checks):
    result = sandbox.run("help")
    for text in ("profile add NAME --endpoint URL --model MODEL", "profile set-endpoint NAME [--endpoint URL] [--model MODEL]",
                 "Third-party endpoints:", "ANTHROPIC_AUTH_TOKEN", "An Anthropic key (sk-ant-…) is refused"):
        checks.expect(text in result.stdout, f"help must document {text!r}", result)
    checks.done("help documents endpoint profiles")


def main():
    clean_up_on_termination()
    preflight()
    cli = build_cli()
    checks = Checks()
    sandboxes = []
    failure = None
    # The requirement lives in the real preferences domain (a temp home cannot isolate it), so restore it.
    original_policy = read_policy_preference()
    try:
        sandbox = Sandbox(cli, "e2e-endpoint")
        sandboxes.append(sandbox)
        profile, key = add_profiles(sandbox, checks)
        try:
            launches(sandbox, checks, profile, key)
        finally:
            checks.expect(restore_policy_preference(cli, original_policy), "the inference-token requirement must be restored")
        rejected_input(sandbox, checks)
        key = change_endpoint(sandbox, checks, profile, key)
        refusals(sandbox, checks, profile)
        usage_and_available(cli, checks, sandboxes)
        help_text(sandbox, checks)
        removal(sandbox, checks)
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
               "scope": "Real claudock binary and login Keychain in temporary homes; synthetic keys; fake claude; no endpoint contacted."}
    print(json.dumps(receipt, indent=2))
    if failure:
        print("FAILED: " + failure, file=sys.stderr)
    if failure or leftovers or not policy_restored:
        sys.exit(1)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Opt-in live smoke for a third-party endpoint profile: one real request through the installed Claude Code.

Never part of CI or the other checks: it spends the provider's credit. It needs three variables, and takes a fourth:

  CLAUDOCK_LIVE_ENDPOINT_KEY_FILE    a key file, holding the raw key or one `export NAME=value` line
  CLAUDOCK_LIVE_ENDPOINT_URL         the endpoint's https base URL
  CLAUDOCK_LIVE_ENDPOINT_MODEL       the one model to pin
  CLAUDOCK_LIVE_ENDPOINT_BEHAVES_AS  optional: a catalog model for --behaves-as, such as claude-sonnet-4-6

It builds the CLI and adds an endpoint profile in a throwaway home (see claudock_e2e.py), with the key file on
standard input as `claudock profile add … < KEY_FILE` does. `claude` in that home is a wrapper that execs the
installed Claude Code with HOME set to the throwaway home and its auto-updater off, so no real profile, setting, or
login is read. It then runs `claudock run NAME -- -p "Reply with exactly: OK" --output-format json` once: one Claude
Code run against the endpoint, with Claudock's per-launch --settings. It checks the exit status, that the answer
contains OK, and that Claude Code reports usage for the pinned model only. It also reports whether Claude Code warned
that the model is not in its catalog: with JSON output Claude Code only logs that warning, so the run writes Claude
Code's debug log inside the throwaway home, and the check looks for the warning there and prints only yes or no. The
profile's Keychain item and the throwaway home, debug log included, are deleted afterwards, also after a failure.
The key is never printed.
"""

import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import time

from claudock_e2e import REAL_HOME, Checks, Sandbox, build_cli, clean_up_on_termination, endpoint_key_service, preflight


NAME = "live"
PROMPT = "Reply with exactly: OK"
CATALOG_WARNING = "isn't described by this version's model catalog"
UNRECOGNIZED_MODEL = "[claude-code:unrecognized_model]"


def required(name):
    value = os.environ.get(name, "")
    if not value:
        raise SystemExit(f"{name} is not set. This opt-in smoke needs CLAUDOCK_LIVE_ENDPOINT_KEY_FILE, "
                         "CLAUDOCK_LIVE_ENDPOINT_URL, and CLAUDOCK_LIVE_ENDPOINT_MODEL.")
    return value


def key_value(path):
    """The key as Claudock reads it, only to make sure no output repeats it."""
    text = path.read_text().strip()
    match = re.fullmatch(r"(?:export[ \t]+)?[A-Za-z_][A-Za-z0-9_]*=(.*)", text)
    value = match.group(1) if match else text
    return value[1:-1] if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"" else value


def redacted(text, key):
    return text.replace(key, "<key>") if key else text


def install_real_claude(sandbox):
    """Replaces the sandbox's fake claude with a wrapper around the installed one, kept inside the throwaway home."""
    real = (Path(REAL_HOME) / ".local" / "bin" / "claude").resolve()
    if not real.is_file() or not os.access(real, os.X_OK):
        raise SystemExit(f"Claude Code is not installed at {Path(REAL_HOME) / '.local/bin/claude'}.")
    sandbox.fake.write_text("#!/bin/sh\n"
                            f"HOME={shlex.quote(str(sandbox.home))}\nexport HOME\n"
                            "DISABLE_AUTOUPDATER=1\nexport DISABLE_AUTOUPDATER\n"
                            f"exec {shlex.quote(str(real))} \"$@\"\n")
    sandbox.fake.chmod(0o700)
    version = subprocess.run([str(real), "--version"], env={"HOME": str(sandbox.home), "PATH": "/usr/bin:/bin", "DISABLE_AUTOUPDATER": "1"},
                             capture_output=True, text=True, timeout=60).stdout.strip()
    return str(real), version


def main():
    clean_up_on_termination()
    key_file = Path(required("CLAUDOCK_LIVE_ENDPOINT_KEY_FILE")).expanduser()
    url, model = required("CLAUDOCK_LIVE_ENDPOINT_URL"), required("CLAUDOCK_LIVE_ENDPOINT_MODEL")
    behaves_as = os.environ.get("CLAUDOCK_LIVE_ENDPOINT_BEHAVES_AS", "")
    if not key_file.is_file():
        raise SystemExit("CLAUDOCK_LIVE_ENDPOINT_KEY_FILE does not name a readable file.")
    key = key_value(key_file)
    preflight()
    cli = build_cli()
    checks = Checks()
    receipt = {"endpoint": url, "model": model, "behaves_as": behaves_as or None}
    failure = None
    sandbox = Sandbox(cli, "e2e-endpoint-live")
    try:
        receipt["claude"], receipt["claude_version"] = install_real_claude(sandbox)
        with open(key_file, "rb") as handle:
            added = subprocess.run([str(cli), "profile", "add", NAME, "--endpoint", url, "--model", model,
                                    *(("--behaves-as", behaves_as) if behaves_as else ())], cwd=sandbox.base,
                                   env=sandbox.environment(), stdin=handle, capture_output=True, text=True, timeout=60)
        checks.expect(added.returncode == 0, "the endpoint profile must be added from the key file: " + redacted(added.stderr, key))
        sandbox.track(endpoint_key_service(sandbox.listed()[NAME]))
        checks.expect(key not in added.stdout + added.stderr, "adding must not print the key")
        checks.done("profile added with the key file on standard input")

        debug_log = sandbox.base / "claude-debug.log"
        started = time.monotonic()
        result = sandbox.run("run", NAME, "--", "-p", PROMPT, "--output-format", "json", "--debug-file", str(debug_log), timeout=300)
        receipt["seconds"] = round(time.monotonic() - started, 1)
        receipt["exit"] = result.returncode
        checks.expect(key not in result.stdout + result.stderr, "the run must not print the key")
        logged = debug_log.read_text(errors="replace") if debug_log.exists() else ""
        receipt["debug_log_written"] = debug_log.exists()
        receipt["catalog_warning"] = CATALOG_WARNING in result.stdout + result.stderr + logged
        receipt["unrecognized_model_line"] = UNRECOGNIZED_MODEL in result.stdout + result.stderr + logged
        receipt["settings_rejected"] = "Invalid JSON provided to --settings" in result.stderr + logged
        receipt["stderr"] = redacted(result.stderr, key)[-2000:]
        try:
            output = json.loads(result.stdout)
        except ValueError:
            output = None
            receipt["stdout"] = redacted(result.stdout, key)[-2000:]
        if isinstance(output, dict):
            receipt["result"] = output.get("result")
            receipt["is_error"] = output.get("is_error")
            receipt["model_usage"] = sorted(output.get("modelUsage") or {})
            receipt["total_cost_usd"] = output.get("total_cost_usd")
        checks.expect(result.returncode == 0, f"claudock run must exit 0, got {result.returncode}")
        checks.expect(isinstance(output, dict) and "OK" in str(output.get("result")), "the answer must contain OK")
        checks.expect(set(output.get("modelUsage") or {}) == {model}, f"only {model} may be used, got {receipt.get('model_usage')!r}")
        checks.done(f"one -p run answered through {model} only")
    except AssertionError as error:
        failure = str(error)
    finally:
        deleted, leftovers = sandbox.close()
    receipt.update({"passed": len(checks.passed), "checks": checks.passed, "keychain_items_deleted_at_teardown": deleted,
                    "keychain_items_not_deleted": leftovers})
    print(json.dumps(receipt, indent=2, ensure_ascii=False))
    if failure:
        print("FAILED: " + failure, file=sys.stderr)
    if failure or leftovers:
        sys.exit(1)


if __name__ == "__main__":
    main()

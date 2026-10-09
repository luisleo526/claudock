#!/usr/bin/env python3
"""Console-login profiles, driven through the real `claudock` binary.

Claude Code can sign in to an Anthropic Console account itself (`claude auth login --console`): it creates an
API key and keeps it in the login Keychain under "Claude Code-" plus the config folder's hash. These checks
build the CLI with SwiftPM and run it from outside in throwaway homes (see claudock_e2e.py) against the real
login Keychain. The fake `claude auth login --console` creates that item for its CLAUDE_CONFIG_DIR the way
Claude Code 2.1.295 names it, with a random synthetic value, and records the Console organization in the
profile's .claude.json; CLAUDOCK_FAKE_LOGIN=fail makes it exit 1 without the item, and =no-item exit 0
without it. Other launches post OTLP `api_request` events like credit_e2e.py's fake. Every Keychain item a
check or the fake creates is deleted before exit, also after a failure. The default profile's own
"Claude Code" item is never created, read, or deleted, and no real profile, credential, shell file, network
endpoint, or Claude executable is used. Like token_e2e.py, it turns the shared requireInferenceToken
setting on and off through the CLI and restores its original value.
"""

import json
import secrets
import sys

from claudock_e2e import (Checks, api_key_service, build_cli, clean_up_on_termination, credential_service,
                          delete_keychain_item, inference_service, keychain_item_exists, managed_key_service,
                          preflight, read_policy_preference, restore_policy_preference)
from credit_e2e import CREDIT_FAKE, HEADER, TELEMETRY_KEYS, CreditSandbox, finish, set_credit, synthetic_key


ORGANIZATION = "E2E Console Org"
CONFLICTS = {"ANTHROPIC_API_KEY": "synthetic-parent-api-key", "CLAUDE_CODE_OAUTH_TOKEN": "synthetic-parent-oauth-token",
             "ANTHROPIC_AUTH_TOKEN": "synthetic-parent-auth-token", "CLAUDE_CONFIG_DIR": "/synthetic/other-profile",
             "E2E_UNRELATED": "kept"}
INJECTED = {"ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_AUTH_TOKEN"}

# Every launch writes its full record first. `auth login --console` then acts like Claude Code's Console sign-in;
# any other launch with CLAUDOCK_CREDIT_PLAN continues into credit_e2e.py's OTLP-posting fake.
LOGIN_FAKE = r'''
import hashlib, json, os, pwd, re, subprocess, sys, unicodedata
launch = {"argv": sys.argv[1:], "cwd": os.getcwd(), "pid": os.getpid(), "ppid": os.getppid(), "env": dict(os.environ),
          "executable": os.path.realpath(__file__)}
def record():
    with open(__RECORD_FILE__ + ".tmp", "w") as handle:
        json.dump(launch, handle)
    os.replace(__RECORD_FILE__ + ".tmp", __RECORD_FILE__)
record()
if sys.argv[1:] == ["auth", "login", "--console"]:
    config = os.environ.get("CLAUDE_CONFIG_DIR")
    mode = os.environ.get("CLAUDOCK_FAKE_LOGIN", "succeed")
    # Without CLAUDE_CONFIG_DIR the item would be the real default profile's "Claude Code": never touch it.
    if not config or mode == "fail":
        sys.exit(1)
    if mode == "no-item":
        sys.exit(0)
    # As Claude Code 2.1.295 names its /login managed key: "Claude Code-" + sha256(NFC config dir)[:8], account $USER.
    service = "Claude Code-" + hashlib.sha256(unicodedata.normalize("NFC", config).encode()).hexdigest()[:8]
    user = os.environ.get("USER") or pwd.getpwuid(os.getuid()).pw_name
    if not re.fullmatch(r"[a-zA-Z0-9._-]+", user):
        user = "claude-code-user"
    # Listed before it exists, so teardown deletes it whatever happens next.
    with open(__SERVICES_FILE__, "a") as handle:
        handle.write(service + "\n")
    synthetic = "sk-ant-api03-e2e-" + os.urandom(24).hex()
    command = 'add-generic-password -U -a "%s" -s "%s" -X "%s"\n' % (user, service, synthetic.encode().hex())
    saved = subprocess.run(["/usr/bin/security", "-i"], input=command.encode(), stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, timeout=20)
    launch["service"] = service
    record()
    if saved.returncode != 0:
        sys.exit(1)
    # Claude Code also records the Console account in the profile's .claude.json.
    path = os.path.join(config, ".claude.json")
    state = json.load(open(path)) if os.path.exists(path) else {}
    state["oauthAccount"] = {"organizationName": __ORGANIZATION__, "billingType": "prepaid"}
    with open(path + ".tmp", "w") as handle:
        json.dump(state, handle)
    os.replace(path + ".tmp", path)
    sys.exit(0)
if "CLAUDOCK_CREDIT_PLAN" not in os.environ:
    sys.exit(0)
'''


class ConsoleSandbox(CreditSandbox):
    def __init__(self, cli, label):
        super().__init__(cli, label)
        self.services_file = self.base / "fake-keychain-services.txt"
        self.fake.write_text("#!" + sys.executable + "\n"
                             + LOGIN_FAKE.replace("__RECORD_FILE__", repr(str(self.record_path)))
                             .replace("__SERVICES_FILE__", repr(str(self.services_file)))
                             .replace("__ORGANIZATION__", repr(ORGANIZATION))
                             + CREDIT_FAKE)
        self.fake.chmod(0o700)

    def close(self):
        if self.services_file.exists():
            for service in self.services_file.read_text().split("\n"):
                if service:
                    self.track(service)
        return super().close()

    def profile(self, name):
        """The listed profile, with its Keychain items tracked for teardown."""
        profiles = self.listed()
        if name not in profiles:
            raise AssertionError(f"profile {name} must be listed, got {sorted(profiles)!r}")
        profile = profiles[name]
        self.track(managed_key_service(profile))
        self.track(api_key_service(profile))
        self.track(inference_service(profile))
        return profile

    def supervised_run(self, name, args=(), extra=None, steps=()):
        """`claudock run NAME -- ARGS` with a credit plan; returns its status, stderr, the fake's posting record
        (whose ppid shows the supervising claudock), and the full launch record."""
        self.record_path.unlink(missing_ok=True)
        plan, record_path = self.plan(steps=list(steps))
        process = self.launch(name, plan, extra=extra, args=args)
        status, _, stderr = finish(process)
        return status, stderr, process.pid, self.fake_record(record_path), self.record()


def not_signed_in(name):
    return f"claudock: {name} is not signed in to a Console account. Sign in with: claudock profile login {name}\n"


def add_console_profile(checks, sandbox):
    result = sandbox.run("profile", "add", "c1", "--console", extra=CONFLICTS)
    record = sandbox.record()
    checks.expect(result.returncode == 0 and record is not None, "profile add NAME --console must add the profile and sign in", result)
    c1 = sandbox.profile("c1")
    checks.expect(record["argv"] == ["auth", "login", "--console"], f"the sign-in must run `auth login --console`, got {record['argv']!r}")
    checks.expect(c1["kind"] == "console-login", f"profile list must show kind console-login, got {c1['kind']!r}")
    checks.expect(record["env"].get("CLAUDE_CONFIG_DIR") == c1["configDirectory"], "the sign-in must use the new profile's config folder")
    checks.expect(not INJECTED & set(record["env"]) and record["env"].get("E2E_UNRELATED") == "kept",
                  "the sign-in gets no injected or inherited credential and keeps unrelated variables")
    checks.expect(record["cwd"] == str(sandbox.base), "the sign-in runs in the current directory")
    checks.expect(record.get("service") == managed_key_service(c1) and keychain_item_exists(managed_key_service(c1)),
                  "the fake sign-in must have saved the managed key under the profile's Claude Code service")
    checks.expect("claudock profile login c1" in result.stdout, "add must say how to sign in again", result)
    checks.done("profile add NAME --console adds a console-login profile and runs `claude auth login --console` for it")
    return c1


def supervised_run(checks, sandbox, c1):
    set_credit(checks, sandbox, "c1", "50")
    status, stderr, pid, posted, launch = sandbox.supervised_run("c1", args=("x",), extra=CONFLICTS,
                                                                 steps=[{"events": [{"cost": 1.25, "seq": 1}]}])
    checks.expect(status == 0 and posted and posted.get("finished") and launch, f"run c1 must launch the fake and exit 0, got {status}: {stderr!r}")
    checks.expect(launch["argv"] == ["x"], f"argv must be forwarded literally, got {launch['argv']!r}")
    checks.expect(not INJECTED & set(launch["env"]), f"a console-login launch must carry no injected key or token, got {sorted(INJECTED & set(launch['env']))!r}")
    checks.expect(launch["env"].get("CLAUDE_CONFIG_DIR") == c1["configDirectory"], "the launch keeps the profile's config folder")
    checks.expect(launch["env"].get("E2E_UNRELATED") == "kept", "unrelated variables are kept")
    checks.expect(TELEMETRY_KEYS <= set(launch["env"]) and launch["env"]["OTEL_EXPORTER_OTLP_LOGS_ENDPOINT"].startswith("http://127.0.0.1:"),
                  f"the launch must get the loopback OTEL settings, got {sorted(k for k in launch['env'] if k.startswith('OTEL_'))!r}")
    checks.expect(posted["ppid"] == pid, "a console-login launch runs Claude as a child of claudock")
    checks.expect(all(code == 200 for code in posted["statuses"]) and len(posted["statuses"]) == 1, f"the export must be accepted, got {posted['statuses']!r}")
    result, rows = sandbox.usage_rows(checks)
    expected = ["c1", "Console API", "Credit · $48.75 of $50.00 left", "2.50", "-"]
    checks.expect(rows.get("c1") == expected, f"usage must count the posted request, expected {expected!r}, got {rows.get('c1')!r}", result)
    checks.done("run uses Claude Code's own sign-in: no ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN, supervised with OTEL")
    checks.done("a posted api_request counts against the credit set with set-credit")

    # The app's Open in Terminal and Continue as… reach the CLI as a bound launch.
    sandbox.record_path.unlink(missing_ok=True)
    plan, _ = sandbox.plan(steps=[])
    result = sandbox.run("launch-bound", sandbox.registry_id("c1"), credential_service(c1), "run", "--", "--resume", "abc",
                         extra={**CONFLICTS, "CLAUDOCK_CREDIT_PLAN": str(plan)})
    launch = sandbox.record()
    checks.expect(result.returncode == 0 and launch and launch["argv"] == ["--resume", "abc"] and not INJECTED & set(launch["env"])
                  and "OTEL_EXPORTER_OTLP_LOGS_ENDPOINT" in launch["env"], "an app launch of a console-login profile works the same way", result)
    checks.done("app launches (launch-bound) of a console-login profile inject nothing and are supervised")


def missing_sign_in(checks, sandbox):
    result = sandbox.run("profile", "add", "c2", "--console", extra={"CLAUDOCK_FAKE_LOGIN": "fail"})
    record = sandbox.record()
    checks.expect(result.returncode == 1 and record is not None and record["argv"] == ["auth", "login", "--console"],
                  "a failed sign-in after add must return Claude's status", result)
    c2 = sandbox.profile("c2")
    checks.expect(c2["kind"] == "console-login", "the profile must stay after a failed sign-in")
    checks.expect(not keychain_item_exists(managed_key_service(c2)), "a failed sign-in saves no managed key")
    checks.done("a failed sign-in after profile add --console keeps the profile")

    bound = ("launch-bound", sandbox.registry_id("c2"), credential_service(c2), "run", "--")
    for arguments in (("run", "c2", "--", "x"), ("run", "claude-c2"), bound):
        result = sandbox.run(*arguments)
        checks.expect(result.returncode == 1 and result.stdout == "" and result.stderr == not_signed_in("c2"),
                      f"{arguments[0]} without a sign-in must fail with the sign-in message", result)
        checks.expect(sandbox.record() is None, "claude must not run without a Console sign-in")
    checks.done("run without the managed key fails before Claude starts and names profile login")

    result = sandbox.run("profile", "login", "c2", extra=CONFLICTS)
    record = sandbox.record()
    checks.expect(result.returncode == 0 and record is not None and record["argv"] == ["auth", "login", "--console"]
                  and not INJECTED & set(record["env"]), "plain profile login must run the Console sign-in for a console-login profile", result)
    checks.expect(keychain_item_exists(managed_key_service(c2)), "the sign-in must save the managed key")
    status, stderr, _, _, launch = sandbox.supervised_run("c2")
    checks.expect(status == 0 and launch is not None, f"run must work once signed in, got {status}: {stderr!r}")
    checks.done("profile login NAME signs a console-login profile in with --console")

    checks.expect(delete_keychain_item(managed_key_service(c2)), "could not remove the managed key to simulate a sign-out")
    result = sandbox.run("launch-bound", sandbox.registry_id("c2"), credential_service(c2), "login", "--")
    record = sandbox.record()
    checks.expect(result.returncode == 0 and record is not None and record["argv"] == ["auth", "login", "--console"],
                  "the app's Sign in… must run the Console sign-in", result)
    checks.expect(keychain_item_exists(managed_key_service(c2)), "the app's sign-in must save the managed key")
    checks.done("the app's Sign in… (launch-bound login) runs auth login --console")


def switch_api_key_profile(checks, sandbox):
    key = synthetic_key()
    result = sandbox.run("profile", "add", "k1", "--api-key", stdin=key + "\n")
    checks.expect(result.returncode == 0, "the sandbox needs an API-key profile", result)
    k1 = sandbox.profile("k1")
    checks.expect(k1["kind"] == "api-key", f"k1 must be an API-key profile, got {k1['kind']!r}")

    def launched_key():
        status, stderr, _, _, launch = sandbox.supervised_run("k1")
        checks.expect(status == 0 and launch is not None, f"run k1 must launch the fake, got {status}: {stderr!r}")
        return launch["env"].get("ANTHROPIC_API_KEY")

    # The fake exits 1 without a key, or 0 without one: either way the sign-in did not finish.
    for mode in ("fail", "no-item"):
        result = sandbox.run("profile", "login", "k1", "--console", extra={**CONFLICTS, "CLAUDOCK_FAKE_LOGIN": mode})
        record = sandbox.record()
        checks.expect(record is not None and record["argv"] == ["auth", "login", "--console"] and not INJECTED & set(record["env"]),
                      f"profile login --console must run the Console sign-in without the stored key ({mode})", result)
        checks.expect(result.returncode == 1, f"an unfinished sign-in must fail ({mode}), got {result.returncode}", result)
        checks.expect(sandbox.listed()["k1"]["kind"] == "api-key", f"an unfinished sign-in must keep the API-key kind ({mode})")
        checks.expect("k1 still uses its Console API key" in result.stderr, f"an unfinished sign-in must say the key stays in use ({mode})", result)
        checks.expect(launched_key() == key, f"run must still inject the stored key after an unfinished sign-in ({mode})")
    checks.done("profile login NAME --console on an API-key profile keeps the key when sign-in fails or saves nothing")

    result = sandbox.run("profile", "login", "k1", "--console")
    service = api_key_service(k1)
    checks.expect(result.returncode == 0 and sandbox.listed()["k1"]["kind"] == "console-login",
                  "a finished sign-in must switch the profile to console-login", result)
    checks.expect(service in result.stdout and f"security delete-generic-password -s {service}" in result.stdout,
                  "the switch must print the stored key's Keychain service and its delete command", result)
    checks.expect(keychain_item_exists(service), "the switch must keep the stored key in Keychain")
    checks.expect(key not in result.stdout + result.stderr, "the switch must not print the key")
    checks.expect(launched_key() is None, "after the switch, run must not inject the stored key")
    checks.done("a finished Console sign-in switches an API-key profile to console-login; the key stays unused")

    replacement = synthetic_key()
    result = sandbox.run("profile", "set-key", "k1", stdin=replacement)
    checks.expect(result.returncode == 0 and sandbox.listed()["k1"]["kind"] == "api-key", "set-key must switch a console-login profile to api-key", result)
    checks.expect(replacement not in result.stdout + result.stderr, "set-key must not print the key")
    checks.expect(launched_key() == replacement, "after set-key, run must inject the new key")
    checks.done("set-key on a console-login profile switches it to api-key and injects the key again")


def refusals(checks, sandbox, original_policy):
    result = sandbox.run("profile", "add", "sub")
    checks.expect(result.returncode == 0, "the sandbox needs a subscription profile", result)
    sub = sandbox.profile("sub")
    checks.expect(sub["kind"] == "managed", f"sub must be a subscription profile, got {sub['kind']!r}")
    result = sandbox.run("profile", "login", "sub", "--console")
    checks.expect(result.returncode == 1 and "subscription" in result.stderr and sandbox.record() is None,
                  "profile login --console must refuse a subscription profile without running claude", result)
    checks.expect(sandbox.listed()["sub"]["kind"] == "managed", "a refused --console login keeps the subscription kind")
    result = sandbox.run("launch-bound", sandbox.registry_id("sub"), credential_service(sub), "login", "--")
    record = sandbox.record()
    checks.expect(result.returncode == 0 and record is not None and record["argv"] == ["auth", "login", "--claudeai"],
                  "a subscription profile's sign-in is unchanged", result)
    checks.done("profile login --console refuses subscription profiles")

    result = sandbox.run("profile", "setup-token", "c1")
    checks.expect(result.returncode == 1 and "Inference tokens are only for" in result.stderr and sandbox.record() is None,
                  "profile setup-token must refuse a console-login profile", result)
    token = "sk-ant-oat01-" + secrets.token_urlsafe(48)
    result = sandbox.run("profile", "set-token", "c1", stdin=token)
    checks.expect(result.returncode == 1 and "Inference tokens are only for" in result.stderr and token not in result.stdout + result.stderr,
                  "profile set-token must refuse a console-login profile without echoing the token", result)
    checks.expect(not keychain_item_exists(inference_service(sandbox.listed()["c1"])), "a refused set-token stores nothing")
    result = sandbox.run("profile", "tokens")
    rows = {line.split("\t")[0]: line.split("\t") for line in result.stdout.splitlines()[1:]}
    checks.expect(result.returncode == 0 and rows.get("c1") == ["c1", "n/a", "-"], f"tokens must list c1 as n/a, got {rows.get('c1')!r}", result)
    checks.done("setup-token and set-token refuse console-login profiles; tokens lists them as n/a")

    result = sandbox.run("require-token", "on")
    checks.expect(result.returncode == 0 and read_policy_preference() is True, "require-token on must succeed", result)
    try:
        status, stderr, _, _, launch = sandbox.supervised_run("c1", args=("--print", "hi"))
        checks.expect(status == 0 and launch is not None and launch["argv"] == ["--print", "hi"] and not INJECTED & set(launch["env"]),
                      f"require-token on must not block a console-login launch, got {status}: {stderr!r}")
    finally:
        checks.expect(restore_policy_preference(sandbox.cli, original_policy), "the inference-token requirement must be restored")
    checks.done("require-token on does not block console-login profiles")


def usage_and_removal(cli, checks, sandboxes):
    sandbox = ConsoleSandbox(cli, "e2e-console-usage")
    sandboxes.append(sandbox)
    result = sandbox.run("profile", "add", "c3", "--console")
    checks.expect(result.returncode == 0, "the usage sandbox needs a console-login profile", result)
    c3 = sandbox.profile("c3")
    checks.expect(keychain_item_exists(managed_key_service(c3)), "the usage sandbox's profile must be signed in")
    result = sandbox.run("usage")
    skip = (f"claudock: c3: skipped; Console login · {ORGANIZATION} is billed per token and has no subscription limits. "
            "Set its balance with: claudock profile set-credit c3 AMOUNT\n")
    checks.expect(result.returncode == 0 and result.stdout == HEADER and skip in result.stderr,
                  "usage without credit must print the skip line with the Console organization", result)
    checks.done("usage without credit: skip line names the Console organization, no row, exit 0")

    service = managed_key_service(c3)
    result = sandbox.run("profile", "remove", "c3")
    checks.expect(result.returncode == 0 and "c3" not in sandbox.listed(), "profile remove must remove the console-login profile", result)
    checks.expect(f"security delete-generic-password -s '{service}'" in result.stdout,
                  "removal must print Claude Code's managed-key service and how to delete it", result)
    checks.expect(keychain_item_exists(service), "removal must keep Claude Code's managed key")
    checks.done("remove keeps Claude Code's managed key and prints its service")


def arguments(checks, sandbox):
    registry, accounts = sandbox.registry_bytes(), sandbox.accounts()
    for args in (("profile", "add", "x1", "--console", "--api-key"), ("profile", "add", "x1", "--api-key", "--console"),
                 ("profile", "add", "x1", "--console", "--console"), ("profile", "add", "x1", "--console=yes"),
                 ("profile", "add", "x1", "--console", "extra"), ("profile", "login", "c1", "--console", "extra"),
                 ("profile", "login", "c1", "--claudeai"), ("profile", "login", "--console", "c1")):
        result = sandbox.run(*args)
        checks.expect(result.returncode == 2 and sandbox.record() is None, f"{' '.join(args)} must be a usage error", result)
        checks.expect(sandbox.registry_bytes() == registry and sandbox.accounts() == accounts, f"{' '.join(args)} must change nothing")
    result = sandbox.run("profile", "add", "x2", "--directory", str(sandbox.base), "--console")
    checks.expect(result.returncode == 0, "--console must combine with --directory after it", result)
    x2 = sandbox.profile("x2")
    checks.expect(x2["kind"] == "console-login" and x2["configDirectory"] == str(sandbox.base),
                  f"--directory must import the folder as a console-login profile, got {x2!r}")
    checks.done("--console takes no value, excludes --api-key, and combines with --directory")

    result = sandbox.run("help")
    for text in ("profile add NAME --console [--directory ABS_PATH]", "profile login NAME [--console]"):
        checks.expect(text in result.stdout, f"help must document {text!r}", result)
    checks.done("help documents the Console-login commands")


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
        sandbox = ConsoleSandbox(cli, "e2e-console-login")
        sandboxes.append(sandbox)
        c1 = add_console_profile(checks, sandbox)
        supervised_run(checks, sandbox, c1)
        missing_sign_in(checks, sandbox)
        switch_api_key_profile(checks, sandbox)
        refusals(checks, sandbox, original_policy)
        usage_and_removal(cli, checks, sandboxes)
        arguments(checks, sandbox)
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
               "scope": "Real claudock binary and login Keychain in temporary homes; a fake claude whose Console sign-in "
                        "saves a synthetic key the way Claude Code 2.1.295 names it, and that posts OTLP events."}
    print(json.dumps(receipt, indent=2))
    if failure:
        print("FAILED: " + failure, file=sys.stderr)
    if failure or leftovers or not policy_restored:
        sys.exit(1)


if __name__ == "__main__":
    main()

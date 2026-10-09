#!/usr/bin/env python3
"""Console credit for API-key profiles, driven through the real `claudock` binary.

Builds the CLI with SwiftPM and runs it from outside in throwaway homes (see claudock_e2e.py)
against the real login Keychain. API keys are random synthetic values. A fake `claude` reads the
OpenTelemetry settings it was launched with and posts OTLP/HTTP JSON `claude_code.api_request`
events built from otlp_logs_fixture.json, a sanitized export captured from real Claude Code
2.1.295, then optionally writes `.claude.json` the way Claude Code does at exit. The checks read
the result through `claudock usage` and the ledger file. Every Keychain item a check creates is
deleted before it exits, also after a failure. No real profile, credential, shell file, network
endpoint, or Claude executable is used.
"""

import json
import os
from pathlib import Path
import pty
import secrets
import select
import signal
import subprocess
import sys
import time

from claudock_e2e import (Checks, Sandbox, api_key_service, build_cli, clean_up_on_termination, preflight)


FIXTURE = Path(__file__).resolve().parent / "otlp_logs_fixture.json"
HEADER = "PROFILE\tPLAN\tWINDOW\tUSED_PERCENT\tRESETS_UTC\n"
SKIP = ("claudock: {0}: skipped; Console API key profiles are billed per token and have no subscription limits. "
        "Set its balance with: claudock profile set-credit {0} AMOUNT\n")
TELEMETRY_KEYS = {"CLAUDE_CODE_ENABLE_TELEMETRY", "OTEL_LOGS_EXPORTER", "OTEL_EXPORTER_OTLP_PROTOCOL",
                  "OTEL_EXPORTER_OTLP_LOGS_PROTOCOL", "OTEL_EXPORTER_OTLP_LOGS_ENDPOINT", "OTEL_LOGS_EXPORT_INTERVAL"}

# The fake claude. It follows a plan (JSON) named by CLAUDOCK_CREDIT_PLAN, which claudock passes through
# like any unrelated variable, and posts exactly as Claude Code's OTLP exporter does: HTTP/1.1 POSTs of
# application/json to OTEL_EXPORTER_OTLP_LOGS_ENDPOINT over one keep-alive connection.
CREDIT_FAKE = r'''
import copy, http.client, json, os, signal, sys, time, urllib.parse, uuid
plan = json.load(open(os.environ["CLAUDOCK_CREDIT_PLAN"]))
fixture = json.load(open(plan["fixture"]))
records = fixture["resourceLogs"][0]["scopeLogs"][0]["logRecords"]
def name(record):
    return next(a["value"]["stringValue"] for a in record["attributes"] if a["key"] == "event.name")
template = next(r for r in records if name(r) == "api_request")
noise = [r for r in records if name(r) != "api_request"]
started_ms = int(time.time() * 1000)
session = plan.get("session") or str(uuid.uuid4())
state = {"argv": sys.argv[1:], "cwd": os.getcwd(), "pid": os.getpid(), "ppid": os.getppid(), "pgid": os.getpgrp(),
         "executable": os.path.realpath(__file__), "session": session, "started_ms": started_ms,
         "env": {k: v for k, v in os.environ.items() if k.startswith("OTEL_") or k in ("CLAUDE_CODE_ENABLE_TELEMETRY", "CLAUDE_CONFIG_DIR")},
         "api_key_set": bool(os.environ.get("ANTHROPIC_API_KEY")), "statuses": [], "signals": [], "marks": []}
def save():
    temporary = plan["record"] + ".tmp"
    with open(temporary, "w") as handle:
        json.dump(state, handle)
    os.replace(temporary, plan["record"])
save()
received = []
def on_signal(number, frame):
    received.append(number); state["signals"].append(signal.Signals(number).name); save()
for wanted in plan.get("trap", []):
    signal.signal(getattr(signal, wanted), on_signal)
endpoint = os.environ.get("OTEL_EXPORTER_OTLP_LOGS_ENDPOINT")
connection = None
def post(body, headers=None):
    global connection
    target = urllib.parse.urlsplit(endpoint)
    for attempt in range(2):
        try:
            if connection is None:
                connection = http.client.HTTPConnection(target.hostname, target.port, timeout=30)
            connection.request("POST", target.path, body=body, headers={"Content-Type": "application/json", **(headers or {})})
            response = connection.getresponse(); response.read()
            state["statuses"].append(response.status)
            if response.getheader("Connection", "").lower() == "close":
                connection.close(); connection = None
            return
        except (http.client.HTTPException, OSError) as error:
            connection = None
            if attempt:
                state["statuses"].append("error: " + type(error).__name__)
def event(spec):
    record = copy.deepcopy(template)
    at = time.time() + spec.get("offset", 0)
    values = {"session.id": {"stringValue": spec.get("session", session)}, "event.sequence": {"intValue": spec["seq"]},
              "event.timestamp": {"stringValue": time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(at)) + ".%03dZ" % int(at % 1 * 1000)},
              "cost_usd": {"doubleValue": spec["cost"]}, "cost_usd_micros": {"intValue": round(spec["cost"] * 1e6)},
              "request_id": {"stringValue": spec.get("request", "req_e2e_" + uuid.uuid4().hex[:20])},
              "client_request_id": {"stringValue": spec.get("client", str(uuid.uuid4()))}}
    for drop in spec.get("drop", []):
        values.pop(drop, None)
        record["attributes"] = [a for a in record["attributes"] if a["key"] != drop]
    for attribute in record["attributes"]:
        if attribute["key"] in values:
            attribute["value"] = values[attribute["key"]]
    for key, value in spec.get("set", {}).items():
        for attribute in record["attributes"]:
            if attribute["key"] == key:
                attribute["value"] = value
    record["timeUnixNano"] = record["observedTimeUnixNano"] = str(int(at * 1000) * 1000000)
    return record
def batch(records):
    body = copy.deepcopy(fixture)
    body["resourceLogs"][0]["scopeLogs"][0]["logRecords"] = records
    return json.dumps(body).encode()
sent = {}
for step in plan.get("steps", []):
    if "events" in step and endpoint:
        body = batch([event(spec) for spec in step["events"]] + copy.deepcopy(noise))
        sent[step.get("name", len(sent))] = body
        post(body)
    elif "repost" in step and endpoint:
        post(sent[step["repost"]])
    elif "raw" in step and endpoint:
        post(step["raw"].encode())
    elif "oversized" in step and endpoint:
        post(b'{"resourceLogs":[' + b" " * step["oversized"] + b"]}")
    elif "mark" in step:
        state["marks"].append(step["mark"]); save()
    elif "sleep" in step:
        deadline = time.time() + step["sleep"]
        while time.time() < deadline:
            time.sleep(0.05)
    elif "wait_signal" in step:
        deadline = time.time() + 30
        while not received and time.time() < deadline:
            time.sleep(0.02)
    elif "raw_ctrl_z" in step:
        # Like Claude Code in raw mode: Ctrl-Z arrives as a byte, and it stops itself with SIGTSTP.
        import termios, tty
        saved = termios.tcgetattr(0)
        tty.setraw(0)
        state["marks"].append("raw"); save()
        byte = os.read(0, 1)
        termios.tcsetattr(0, termios.TCSADRAIN, saved)
        if byte == b"\x1a":
            state["marks"].append("self-stop"); save()
            os.kill(os.getpid(), signal.SIGTSTP)
            state["marks"].append("resumed"); save()
if "claude_json" in plan:
    spec = plan["claude_json"]
    path = os.path.join(os.environ["CLAUDE_CONFIG_DIR"], ".claude.json")
    current = json.load(open(path)) if os.path.exists(path) else {}
    entry = {"lastCost": spec["lastCost"], "lastSessionId": spec.get("lastSessionId", session),
             "lastStartTime": started_ms + spec.get("startOffsetMs", 3), "lastDuration": 1000, "lastGracefulShutdown": True}
    current.setdefault("projects", {})[os.getcwd()] = {**current.get("projects", {}).get(os.getcwd(), {}), **entry}
    with open(path + ".tmp", "w") as handle:
        json.dump(current, handle)
    os.replace(path + ".tmp", path)
state["finished"] = True
save()
sys.exit(plan.get("exit", 0))
'''


def synthetic_key():
    return "sk-ant-api03-" + secrets.token_urlsafe(48)


class CreditSandbox(Sandbox):
    def __init__(self, cli, label):
        super().__init__(cli, label)
        self.fake.write_text("#!" + sys.executable + "\n" + CREDIT_FAKE)
        self.fake.chmod(0o700)
        self.plans = self.base / "plans"
        self.plans.mkdir()
        self.counter = 0

    @property
    def ledger_path(self):
        return self.registry_path.parent / "api-credit.json"

    def ledger(self):
        return json.loads(self.ledger_path.read_text()) if self.ledger_path.exists() else None

    def account(self, name):
        ledger = self.ledger() or {}
        return (ledger.get("profiles") or {}).get(self.registry_id(name))

    def plan(self, **plan):
        self.counter += 1
        path = self.plans / f"plan-{self.counter}.json"
        plan.setdefault("record", str(self.plans / f"record-{self.counter}.json"))
        plan["fixture"] = str(FIXTURE)
        path.write_text(json.dumps(plan))
        return path, Path(plan["record"])

    def fake_record(self, path):
        if not path.exists():
            return None
        value = json.loads(path.read_text())
        if Path(value["executable"]) != self.fake.resolve():
            raise AssertionError(f"an unexpected claude executable ran: {value['executable']}")
        return value

    def launch(self, name, plan_path, extra=None, args=(), **popen):
        """Starts `claudock run NAME` without waiting, with the plan for its fake."""
        environment = self.environment({"CLAUDOCK_CREDIT_PLAN": str(plan_path), **(extra or {})})
        return subprocess.Popen([str(self.cli), "run", name, "--", *args], cwd=self.base, env=environment,
                                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, **popen)

    def usage_rows(self, checks, expect_exit=0):
        result = self.run("usage")
        checks.expect(result.returncode == expect_exit and result.stdout.startswith(HEADER),
                      f"usage must print its header and exit {expect_exit}", result)
        return result, {line.split("\t")[0]: line.split("\t") for line in result.stdout.splitlines()[1:]}


def wait_for(predicate, timeout=20, interval=0.05):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(interval)
    return predicate()


def finish(process, timeout=60):
    stdout, stderr = process.communicate(timeout=timeout)
    return process.returncode, stdout, stderr


def expect_row(checks, sandbox, name, window, percent):
    result, rows = sandbox.usage_rows(checks)
    expected = [name, "Console API", window, percent, "-"]
    checks.expect(rows.get(name) == expected, f"usage must print {expected!r} for {name}, got {rows.get(name)!r}", result)
    return result


def set_credit(checks, sandbox, name, amount):
    result = sandbox.run("profile", "set-credit", name, amount)
    checks.expect(result.returncode == 0, f"set-credit {name} {amount} must succeed", result)
    return result


def add_api_key_profile(checks, sandbox, name):
    key = synthetic_key()
    result = sandbox.run("profile", "add", name, "--api-key", stdin=key + "\n")
    checks.expect(result.returncode == 0, f"the sandbox needs API-key profile {name}", result)
    sandbox.track(api_key_service(sandbox.listed()[name]))
    return key


def rejections(checks, sandbox):
    before = sandbox.ledger_path.read_bytes() if sandbox.ledger_path.exists() else None
    for amount in ("-1", "-0.01", "abc", "1.234", "1000000.01", "2000000", "1e3", "12,50", "", " 200", "$200", "0x10", "NaN"):
        result = sandbox.run("profile", "set-credit", "console", amount)
        checks.expect(result.returncode == 2 and "set-credit" not in result.stdout, f"set-credit must reject {amount!r} as a usage error", result)
        checks.expect("at most two decimals" in result.stderr, f"rejecting {amount!r} must explain the accepted amounts", result)
    for arguments in (("profile", "set-credit", "console"), ("profile", "set-credit", "console", "1", "2")):
        result = sandbox.run(*arguments)
        checks.expect(result.returncode == 2, f"{' '.join(arguments)} must be a usage error", result)
    result = sandbox.run("profile", "set-credit", "work", "200")
    checks.expect(result.returncode == 1 and "Console API-key profiles" in result.stderr, "set-credit must refuse a subscription profile", result)
    result = sandbox.run("profile", "set-credit", "nosuch", "200")
    checks.expect(result.returncode == 1 and "No profile named 'nosuch'" in result.stderr, "set-credit must refuse an unknown profile", result)
    after = sandbox.ledger_path.read_bytes() if sandbox.ledger_path.exists() else None
    checks.expect(after == before, "rejected set-credit calls must not change the ledger")
    for amount in ("0", "200", "187.42", "1000000", "1000000.00", "0.5"):
        set_credit(checks, sandbox, "console", amount)
    checks.done("set-credit accepts 0 to 1,000,000 with up to two decimals and rejects everything else")


def usage_without_credit(cli, checks, sandboxes):
    sandbox = CreditSandbox(cli, "e2e-credit-unset")
    sandboxes.append(sandbox)
    add_api_key_profile(checks, sandbox, "solo")
    result = sandbox.run("usage")
    checks.expect(result.returncode == 0, "an API-key profile without credit must not make usage fail", result)
    checks.expect(result.stdout == HEADER, "usage must print no row for an API-key profile without credit", result)
    checks.expect(SKIP.format("solo") in result.stderr, "usage must print the skip line with the set-credit hint", result)
    checks.done("usage without credit: skip line with set-credit hint, no row, exit 0")


def first_run(checks, sandbox, key):
    set_credit(checks, sandbox, "console", "200")
    mode = sandbox.ledger_path.stat().st_mode & 0o777
    checks.expect(mode == 0o600, f"the ledger must be private (0600), got {oct(mode)}")
    expect_row(checks, sandbox, "console", "Credit · $200.00 of $200.00 left", "0.00")
    plan, record_path = sandbox.plan(steps=[
        {"name": "first", "events": [{"cost": 0.0123, "seq": 1}, {"cost": 1.5, "seq": 2}]},
        {"repost": "first"},
        {"raw": "this is not json"},
        {"raw": json.dumps({"resourceLogs": "wrong shape"})},
        {"events": [{"cost": 9.0, "seq": 50, "drop": ["cost_usd", "cost_usd_micros"]},
                    {"cost": -3.0, "seq": 51}, {"cost": 7.0, "seq": 52, "set": {"cost_usd": {"stringValue": "seven"}}},
                    {"cost": 8.0, "seq": 53, "drop": ["session.id"]}]},
        {"oversized": 9 * 1024 * 1024},
        {"name": "second", "events": [{"cost": 0.25, "seq": 3}]},
        {"repost": "second"}], exit=0)
    process = sandbox.launch("console", plan, args=("--print", "hi"))
    status, _, stderr = finish(process)
    record = sandbox.fake_record(record_path)
    checks.expect(status == 0 and record and record.get("finished"), f"the API-key run must finish and exit 0, got {status}: {stderr!r}")
    checks.expect(record["argv"] == ["--print", "hi"] and record["cwd"] == str(sandbox.base) and record["api_key_set"],
                  "the supervised launch keeps argv, working directory, and the API key")
    checks.expect(record["ppid"] == process.pid, "an API-key launch runs Claude as a child of claudock")
    checks.expect(record["pgid"] == os.getpgrp(), "the child stays in claudock's process group, the caller's job")
    checks.expect(all(status == 200 for status in record["statuses"]) and len(record["statuses"]) == 8,
                  f"every post, malformed and oversized ones included, must get HTTP 200, got {record['statuses']!r}")
    expect_row(checks, sandbox, "console", "Credit · $198.24 of $200.00 left", "0.88")
    account = sandbox.account("console")
    costs = sorted(request["costUSD"] for request in account["requests"])
    checks.expect(costs == [0.0123, 0.25, 1.5], f"the ledger must keep exactly the three costs at full precision, got {costs!r}")
    checks.expect(account["balanceUSD"] == 200 and not account["adjustments"], "the ledger keeps the balance and no adjustment")
    text = sandbox.ledger_path.read_text()
    checks.expect(key not in text and "<REDACTED>" not in text and "prompt" not in text, "the ledger must not contain the key or prompt fields")
    checks.done("one run's costs 0.0123 + 1.5 + 0.25 leave $198.24 of $200.00 (0.88%), exact to the cent")
    checks.done("duplicate posts are not double counted; malformed, invalid, and oversized bodies are ignored with HTTP 200")

    environment = record["env"]
    endpoint = environment.get("OTEL_EXPORTER_OTLP_LOGS_ENDPOINT", "")
    checks.expect(set(environment) - {"CLAUDE_CONFIG_DIR"} == TELEMETRY_KEYS, f"the child must get exactly the telemetry settings, got {sorted(environment)!r}")
    checks.expect(environment["CLAUDE_CODE_ENABLE_TELEMETRY"] == "1" and environment["OTEL_LOGS_EXPORTER"] == "otlp"
                  and environment["OTEL_EXPORTER_OTLP_PROTOCOL"] == "http/json" and environment["OTEL_EXPORTER_OTLP_LOGS_PROTOCOL"] == "http/json"
                  and endpoint.startswith("http://127.0.0.1:") and endpoint.endswith("/v1/logs")
                  and int(environment["OTEL_LOGS_EXPORT_INTERVAL"]) <= 1000, f"unexpected telemetry settings {environment!r}")
    checks.done("the child gets loopback OTLP/HTTP JSON log export settings")


def inherited_telemetry(checks, sandbox):
    plan, record_path = sandbox.plan(steps=[], exit=0)
    inherited = {"OTEL_EXPORTER_OTLP_LOGS_PROTOCOL": "grpc", "OTEL_EXPORTER_OTLP_ENDPOINT": "http://example.invalid:4318",
                 "OTEL_METRICS_EXPORTER": "otlp", "OTEL_LOGS_EXPORTER": "console", "OTEL_LOG_USER_PROMPTS": "1",
                 "CLAUDE_CODE_ENABLE_TELEMETRY": "0", "OTEL_LOGS_EXPORT_INTERVAL": "60000"}
    status, _, stderr = finish(sandbox.launch("console", plan, extra=inherited))
    environment = (sandbox.fake_record(record_path) or {}).get("env", {})
    checks.expect(status == 0, f"the run must succeed, got {status}: {stderr!r}")
    checks.expect(set(environment) - {"CLAUDE_CONFIG_DIR"} == TELEMETRY_KEYS and environment.get("OTEL_LOGS_EXPORTER") == "otlp"
                  and environment.get("OTEL_EXPORTER_OTLP_LOGS_PROTOCOL") == "http/json" and environment.get("CLAUDE_CODE_ENABLE_TELEMETRY") == "1"
                  and int(environment.get("OTEL_LOGS_EXPORT_INTERVAL", "0")) <= 1000,
                  f"inherited telemetry variables must be replaced, got {environment!r}")
    checks.done("inherited OTEL variables are replaced for API-key launches")


def re_set(checks, sandbox):
    set_credit(checks, sandbox, "console", "150")
    expect_row(checks, sandbox, "console", "Credit · $150.00 of $150.00 left", "0.00")
    checks.expect(sandbox.account("console")["requests"] == [], "re-setting the credit prunes earlier requests")
    plan, _ = sandbox.plan(steps=[{"events": [{"cost": 5.0, "seq": 1, "offset": -120}, {"cost": 2.0, "seq": 2}]}])
    status, _, stderr = finish(sandbox.launch("console", plan))
    checks.expect(status == 0, f"the run must succeed, got {status}: {stderr!r}")
    expect_row(checks, sandbox, "console", "Credit · $148.00 of $150.00 left", "1.33")
    checks.done("after a re-set, events from before the new as-of time are not counted")


def killed_child(checks, sandbox):
    set_credit(checks, sandbox, "console", "100")
    plan, record_path = sandbox.plan(steps=[{"events": [{"cost": 0.5, "seq": 1}]}, {"events": [{"cost": 0.25, "seq": 2}]},
                                            {"mark": "posted"}, {"sleep": 60}])
    process = sandbox.launch("console", plan)
    record = wait_for(lambda: (lambda r: r if r and "posted" in r["marks"] else None)(sandbox.fake_record(record_path)))
    checks.expect(record is not None, "the fake must report its posts")
    started = time.monotonic()
    os.kill(record["pid"], signal.SIGKILL)
    status, _, stderr = finish(process, timeout=30)
    checks.expect(status == 137, f"claudock must exit 137 after its child is killed, got {status}: {stderr!r}")
    checks.expect(time.monotonic() - started < 15, "claudock must exit promptly after its child is killed")
    expect_row(checks, sandbox, "console", "Credit · $99.25 of $100.00 left", "0.75")
    checks.done("a SIGKILLed child: events posted before the kill count, claudock exits 137")


def interrupted(checks, sandbox):
    set_credit(checks, sandbox, "console", "100")
    plan, record_path = sandbox.plan(trap=["SIGINT"], steps=[{"events": [{"cost": 1.0, "seq": 1}]}, {"mark": "ready"},
                                                             {"wait_signal": True}, {"events": [{"cost": 0.5, "seq": 2}]}], exit=3)
    process = sandbox.launch("console", plan, preexec_fn=os.setpgrp)
    record = wait_for(lambda: (lambda r: r if r and "ready" in r["marks"] else None)(sandbox.fake_record(record_path)))
    checks.expect(record is not None, "the fake must get ready")
    os.killpg(process.pid, signal.SIGINT)
    status, _, stderr = finish(process)
    record = sandbox.fake_record(record_path)
    checks.expect(record["signals"] == ["SIGINT"], f"the child must receive the terminal's SIGINT, got {record['signals']!r}")
    checks.expect(status == 3, f"claudock must survive SIGINT and exit with the child's status 3, got {status}: {stderr!r}")
    expect_row(checks, sandbox, "console", "Credit · $98.50 of $100.00 left", "1.50")
    checks.done("SIGINT to the process group reaches the child; claudock stays until it exits and returns its status")


def terminated(checks, sandbox):
    set_credit(checks, sandbox, "console", "100")
    plan, record_path = sandbox.plan(trap=["SIGTERM"], steps=[{"events": [{"cost": 1.0, "seq": 1}]}, {"mark": "ready"},
                                                              {"wait_signal": True}, {"events": [{"cost": 0.25, "seq": 2}]}], exit=143)
    process = sandbox.launch("console", plan)
    checks.expect(wait_for(lambda: (lambda r: r and "ready" in r["marks"])(sandbox.fake_record(record_path))), "the fake must get ready")
    process.send_signal(signal.SIGTERM)
    status, _, stderr = finish(process)
    record = sandbox.fake_record(record_path)
    checks.expect(record["signals"] == ["SIGTERM"] and status == 143, f"SIGTERM must be forwarded and the status returned, got {status} {record['signals']!r}: {stderr!r}")
    expect_row(checks, sandbox, "console", "Credit · $98.75 of $100.00 left", "1.25")
    checks.done("SIGTERM is forwarded to the child; its final events still count")


def parallel(checks, sandbox):
    set_credit(checks, sandbox, "console", "100")
    first, first_record = sandbox.plan(steps=[step for cost, seq in ((0.11, 1), (0.12, 2), (0.13, 3), (0.14, 4))
                                              for step in ({"events": [{"cost": cost, "seq": seq}]}, {"sleep": 0.15})])
    second, second_record = sandbox.plan(steps=[step for cost, seq in ((0.21, 1), (0.22, 2), (0.23, 3), (0.24, 4))
                                                for step in ({"events": [{"cost": cost, "seq": seq}]}, {"sleep": 0.1})])
    processes = [sandbox.launch("console", first), sandbox.launch("console", second)]
    results = [finish(process) for process in processes]
    checks.expect(all(status == 0 for status, _, _ in results), f"both parallel runs must succeed, got {results!r}")
    records = [sandbox.fake_record(first_record), sandbox.fake_record(second_record)]
    checks.expect(records[0]["cwd"] == records[1]["cwd"] and records[0]["session"] != records[1]["session"], "two sessions in one directory")
    checks.expect(len(sandbox.account("console")["requests"]) == 8, "the ledger must hold all eight requests")
    expect_row(checks, sandbox, "console", "Credit · $98.60 of $100.00 left", "1.40")
    checks.done("two API-key runs in parallel in the same directory are both counted exactly")


def cross_check(checks, sandbox):
    set_credit(checks, sandbox, "console", "100")
    plan, record_path = sandbox.plan(steps=[{"events": [{"cost": 0.1, "seq": 1}, {"cost": 0.2, "seq": 2}]}], claude_json={"lastCost": 0.8})
    status, _, stderr = finish(sandbox.launch("console", plan))
    checks.expect(status == 0, f"the run must succeed, got {status}: {stderr!r}")
    session = sandbox.fake_record(record_path)["session"]
    expect_row(checks, sandbox, "console", "Credit · $99.20 of $100.00 left", "0.80")
    adjustments = sandbox.account("console")["adjustments"]
    checks.expect(len(adjustments) == 1 and adjustments[0]["kind"] == "session-total" and adjustments[0]["sessionID"] == session
                  and abs(adjustments[0]["amountUSD"] - 0.5) < 1e-9, f"a larger lastCost must add a session-total adjustment, got {adjustments!r}")
    checks.done("a larger .claude.json lastCost than captured adds a session-total adjustment")

    plan, _ = sandbox.plan(steps=[{"events": [{"cost": 0.3, "seq": 1}]}], claude_json={"lastCost": 0.1})
    status, _, stderr = finish(sandbox.launch("console", plan))
    checks.expect(status == 0, f"the run must succeed, got {status}: {stderr!r}")
    expect_row(checks, sandbox, "console", "Credit · $98.90 of $100.00 left", "1.10")
    checks.expect(len(sandbox.account("console")["adjustments"]) == 1, "a smaller lastCost must not add an adjustment")
    # A resumed session restores its earlier cost and start time; lastStartTime before this run proves it is not this run's alone.
    plan, _ = sandbox.plan(steps=[{"events": [{"cost": 0.1, "seq": 1}]}], claude_json={"lastCost": 0.9, "startOffsetMs": -3_600_000})
    status, _, stderr = finish(sandbox.launch("console", plan))
    checks.expect(status == 0, f"the run must succeed, got {status}: {stderr!r}")
    expect_row(checks, sandbox, "console", "Credit · $98.80 of $100.00 left", "1.20")
    checks.expect(len(sandbox.account("console")["adjustments"]) == 1, "an entry that started before the run must not add an adjustment")
    checks.done("a smaller lastCost, or one from a session started before the run, changes nothing")


def job_control(checks, sandbox):
    """Ctrl-Z while the child reads the terminal in raw mode, as Claude Code does, then fg, in an interactive zsh."""
    set_credit(checks, sandbox, "console", "100")
    plan, record_path = sandbox.plan(steps=[{"events": [{"cost": 0.4, "seq": 1}]}, {"raw_ctrl_z": True},
                                            {"events": [{"cost": 0.1, "seq": 2}]}], exit=0)
    environment = sandbox.environment({"CLAUDOCK_CREDIT_PLAN": str(plan), "PS1": "READY> ", "TERM": "dumb"})
    pid, master = pty.fork()
    if pid == 0:
        os.chdir(sandbox.base)
        os.execve("/bin/zsh", ["/bin/zsh", "-f", "-i"], environment)
    output = bytearray()

    def read_until(needle, timeout=20):
        deadline = time.monotonic() + timeout
        while needle not in output and time.monotonic() < deadline:
            if select.select([master], [], [], 0.1)[0]:
                try:
                    output.extend(os.read(master, 4096))
                except OSError:
                    break
        return needle in output

    def drained(predicate, timeout=20):
        """wait_for that keeps reading the terminal, so zsh never blocks writing to it."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            value = predicate()
            if value:
                return value
            read_until(b"\x00never\x00", timeout=0.05)
        return predicate()

    def state(process_id):
        result = subprocess.run(["/bin/ps", "-o", "stat=", "-p", str(process_id)], capture_output=True, text=True)
        return result.stdout.strip()

    try:
        checks.expect(read_until(b"READY> "), f"zsh must start, got {bytes(output)!r}")
        # zsh's line editor flushes input typed before it takes the terminal; let it settle first.
        read_until(b"\x1b[?2004h", timeout=2)
        time.sleep(0.5)
        os.write(master, f"'{sandbox.cli}' run console\r".encode())
        record = drained(lambda: (lambda r: r if r and "raw" in r["marks"] else None)(sandbox.fake_record(record_path)))
        checks.expect(record is not None, f"the fake must read the terminal in raw mode, got {bytes(output)!r}")
        os.write(master, b"\x1a")
        checks.expect(read_until(b"suspended"), f"zsh must report the job suspended, got {bytes(output)!r}")
        claudock = record["ppid"]
        checks.expect(drained(lambda: state(claudock).startswith("T") and state(record["pid"]).startswith("T")),
                      f"claudock and its child must both be stopped, got {state(claudock)!r} {state(record['pid'])!r}")
        os.write(master, b"fg\r")
        record = drained(lambda: (lambda r: r if r and r.get("finished") else None)(sandbox.fake_record(record_path)))
        checks.expect(record is not None and drained(lambda: state(claudock) == ""), f"after fg the job must finish, got {bytes(output)!r}")
        os.write(master, b"echo EXIT=$?\r")
        checks.expect(read_until(b"EXIT=0"), f"the resumed job must exit with status 0, got {bytes(output)!r}")
        checks.expect(record["marks"] == ["raw", "self-stop", "resumed"] and record.get("finished"), f"the child must resume, got {record!r}")
    finally:
        try:
            os.write(master, b"exit\r")
        except OSError:
            pass
        time.sleep(0.3)
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        os.waitpid(pid, 0)
        os.close(master)
    expect_row(checks, sandbox, "console", "Credit · $99.50 of $100.00 left", "0.50")
    checks.done("Ctrl-Z stops claudock with its child and fg resumes both")


def subscription(cli, checks, sandboxes):
    sandbox = CreditSandbox(cli, "e2e-credit-sub")
    sandboxes.append(sandbox)
    result = sandbox.run("profile", "add", "work")
    checks.expect(result.returncode == 0, "the sandbox needs a subscription profile", result)
    add_api_key_profile(checks, sandbox, "solo")
    plan, record_path = sandbox.plan(steps=[{"events": [{"cost": 1.0, "seq": 1}]}], exit=7)
    result = subprocess.run([str(cli), "run", "work", "--", "--print", "x"], cwd=sandbox.base, capture_output=True, text=True,
                            env=sandbox.environment({"CLAUDOCK_CREDIT_PLAN": str(plan)}))
    record = sandbox.fake_record(record_path)
    checks.expect(result.returncode == 7 and record is not None, "a subscription launch must still run and return its status", result)
    checks.expect(record["ppid"] == os.getpid(), "a subscription launch replaces claudock (execve): its parent is the caller")
    checks.expect(set(record["env"]) == {"CLAUDE_CONFIG_DIR"}, f"a subscription launch gets no telemetry variables, got {record['env']!r}")
    checks.done("subscription profiles still execve and get no OTEL variables")

    result = sandbox.run("usage")
    checks.expect(result.returncode == 1 and result.stdout == HEADER, "a subscription profile without a login still fails usage as before", result)
    lines = result.stderr.splitlines()
    checks.expect(any(line.startswith("claudock: work: ") and "credit" not in line.lower() for line in lines),
                  "the subscription profile's usage line is unchanged", result)
    checks.expect(SKIP.format("solo") in result.stderr, "the API-key profile without credit gets the skip line", result)
    checks.done("subscription rows and errors are unchanged next to API-key profiles")


def help_text(checks, sandbox):
    result = sandbox.run("help")
    for text in ("profile set-credit NAME AMOUNT", "not seen", "authoritative"):
        checks.expect(text in result.stdout, f"help must mention {text!r}", result)
    checks.done("help documents set-credit and what the estimate covers")


def main():
    clean_up_on_termination()
    preflight()
    cli = build_cli()
    checks = Checks()
    sandboxes = []
    failure = None
    try:
        sandbox = CreditSandbox(cli, "e2e-credit")
        sandboxes.append(sandbox)
        key = add_api_key_profile(checks, sandbox, "console")
        result = sandbox.run("profile", "add", "work")
        checks.expect(result.returncode == 0, "the sandbox needs a subscription profile to refuse", result)
        rejections(checks, sandbox)
        result = sandbox.run("profile", "remove", "work")
        checks.expect(result.returncode == 0, "the subscription profile must be removable", result)
        usage_without_credit(cli, checks, sandboxes)
        first_run(checks, sandbox, key)
        inherited_telemetry(checks, sandbox)
        re_set(checks, sandbox)
        killed_child(checks, sandbox)
        interrupted(checks, sandbox)
        terminated(checks, sandbox)
        parallel(checks, sandbox)
        cross_check(checks, sandbox)
        job_control(checks, sandbox)
        subscription(cli, checks, sandboxes)
        help_text(checks, sandbox)
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
               "scope": "Real claudock binary and login Keychain in temporary homes; synthetic keys; fake claude posting "
                        "OTLP events shaped like Claude Code 2.1.295's."}
    print(json.dumps(receipt, indent=2))
    if failure:
        print("FAILED: " + failure, file=sys.stderr)
    if failure or leftovers:
        sys.exit(1)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""`claudock usage` through the shared usage cache, persisted cooldowns, request pacing, and the fetch lock.

Builds a test CLI with SwiftPM and `-D CLAUDOCK_TEST_USAGE_ENDPOINT` in its own scratch directory. Only a build
with that flag reads the CLAUDOCK_TEST_USAGE_ENDPOINT variable, and only for an http URL on 127.0.0.1 (without
one it uses a closed loopback port), so neither a release nor an ordinary debug build can be pointed anywhere
by its environment. A stub server on 127.0.0.1 plays the usage endpoint: it answers each profile's token with
200 or 429 (with an optional Retry-After), and counts and timestamps every request. Every claudock process
also runs under sandbox-exec with outbound network limited to loopback, so even a broken override could not
reach api.anthropic.com.

Profiles live in throwaway homes (see claudock_e2e.py) with synthetic `.credentials.json` files. Their
Keychain services are per-run hashes with no item, so lookups find nothing and fall back to the files: the
login Keychain is searched, never read or written. Time passing is simulated by editing the cache file,
never by sleeping through a cooldown. No real profile, credential, or endpoint is used.
"""

from datetime import datetime, timedelta, timezone
import fcntl
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
import threading
import time

from claudock_e2e import (PROJECT, REAL_HOME, SECURITY, Checks, Sandbox, clean_up_on_termination, credential_service,
                          toolchain_environment)


HEADER = "PROFILE\tPLAN\tWINDOW\tUSED_PERCENT\tRESETS_UTC\n"
# Each sandbox's default profile is left unresolved on purpose (see claudock_e2e.py), so every run prints this.
DEFAULT_SKIP = "claudock: default: skipped; this profile does not support subscription usage.\n"
SESSION_RESET, WEEKLY_RESET = "2031-03-04T05:06:07Z", "2031-03-09T00:00:00Z"
# Claude Code's plan metadata for each profile, and the PLAN column Claudock prints for it.
PLANS = {"alpha": ("max", "default_claude_max_20x", "Max 20×"), "bravo": ("pro", None, "Pro"),
         "charlie": ("max", "default_claude_max_5x", "Max 5×"), "delta": ("team", "default_claude_max_5x", "Team Premium")}
NAMES = ["alpha", "bravo", "charlie"]
SANDBOX_EXEC = "/usr/bin/sandbox-exec"
# Outbound network only to loopback: the stub is reachable, Anthropic is not.
NETWORK_PROFILE = '(version 1)(allow default)(deny network-outbound)(allow network-outbound (remote ip "localhost:*"))'
RATE_LIMITED = "Claude is limiting requests. Refresh will retry after a cooldown."


def build_test_cli():
    """The CLI with the test-only endpoint override, in its own scratch directory so it never replaces the
    ordinary debug binary that the other checks build and run."""
    environment = toolchain_environment()
    command = ["xcrun", "swift", "build", "--product", "claudock", "--scratch-path", str(PROJECT / ".build" / "usage-endpoint-test"),
               "-Xswiftc", "-DCLAUDOCK_TEST_USAGE_ENDPOINT"]
    subprocess.run(command, cwd=PROJECT, env=environment, check=True, stdout=subprocess.DEVNULL)
    directory = subprocess.run(command + ["--show-bin-path"], cwd=PROJECT, env=environment, check=True,
                               capture_output=True, text=True).stdout.strip()
    return Path(directory) / "claudock"


def preflight():
    if sys.platform != "darwin":
        raise SystemExit("These checks need macOS.")
    if not Path(SANDBOX_EXEC).exists():
        raise SystemExit("These checks run claudock under sandbox-exec to keep it off the network; it is missing.")
    # Credential lookups search the login Keychain for per-run services that do not exist.
    if subprocess.run([SECURITY, "default-keychain"], env={**os.environ, "HOME": REAL_HOME}, capture_output=True).returncode != 0:
        raise SystemExit("No default login Keychain is available.")


class Stub:
    """Plays https://api.anthropic.com/api/oauth/usage on 127.0.0.1. Each profile's token gets the answer set for
    that profile; every request is counted and timestamped when it arrives."""

    def __init__(self):
        self.lock = threading.Lock()
        self.tokens, self.answers, self.requests, self.rejected = {}, {}, [], []
        self.delay = 0.0
        stub = self

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                stub.answer(self)

            def log_message(self, *arguments):
                pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    @property
    def url(self):
        return f"http://127.0.0.1:{self.server.server_address[1]}/api/oauth/usage"

    def set(self, name, status=200, session=0.0, weekly=0.0, retry_after=None):
        with self.lock:
            self.answers[name] = {"status": status, "session": session, "weekly": weekly, "retry_after": retry_after}

    def count(self, name=None):
        with self.lock:
            return sum(1 for _, requested in self.requests if name in (None, requested))

    def times(self):
        with self.lock:
            return sorted(arrived for arrived, _ in self.requests)

    def answer(self, handler):
        arrived = time.monotonic()
        authorization = handler.headers.get("Authorization", "")
        with self.lock:
            name = self.tokens.get(authorization[len("Bearer "):]) if authorization.startswith("Bearer ") else None
            if handler.path != "/api/oauth/usage" or name is None or handler.headers.get("anthropic-beta") != "oauth-2025-04-20":
                self.rejected.append(handler.path)
                answer = {"status": 401}
            else:
                self.requests.append((arrived, name))
                answer = dict(self.answers[name])
            delay = self.delay
        time.sleep(delay)
        if answer["status"] == 200:
            body = {"five_hour": {"utilization": answer["session"], "resets_at": SESSION_RESET},
                    "seven_day": {"utilization": answer["weekly"], "resets_at": WEEKLY_RESET}}
        else:
            body = {"type": "error", "error": {"type": "rate_limit_error" if answer["status"] == 429 else "authentication_error"}}
        data = json.dumps(body).encode()
        handler.send_response(answer["status"])
        handler.send_header("Content-Type", "application/json")
        handler.send_header("Content-Length", str(len(data)))
        if answer.get("retry_after") is not None:
            handler.send_header("Retry-After", answer["retry_after"])
        handler.end_headers()
        handler.wfile.write(data)

    def close(self):
        self.server.shutdown()
        self.server.server_close()


class UsageSandbox(Sandbox):
    """A throwaway home whose claudock runs talk only to this sandbox's stub."""

    def __init__(self, cli, label, names):
        self.stub = Stub()
        self.tokens, self.keys = {}, {}
        super().__init__(cli, label)
        for name in names:
            self.add(name)

    def command(self, arguments):
        return [SANDBOX_EXEC, "-p", NETWORK_PROFILE, str(self.cli), *arguments]

    def environment(self, extra=None):
        # The expected HH:MM is formatted in this process's time zone, so claudock gets the same one.
        zone = {"TZ": os.environ["TZ"]} if "TZ" in os.environ else {}
        return super().environment({"CLAUDOCK_TEST_USAGE_ENDPOINT": self.stub.url, **zone, **(extra or {})})

    def run(self, *arguments, stdin="", extra=None, timeout=90):
        return subprocess.run(self.command(arguments), cwd=self.base, env=self.environment(extra), input=stdin,
                              capture_output=True, text=True, timeout=timeout)

    def spawn(self, *arguments, extra=None):
        return subprocess.Popen(self.command(arguments), cwd=self.base, env=self.environment(extra), stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

    def add(self, name):
        """A subscription profile signed in with a synthetic login, as Claude Code's credential file holds it."""
        result = self.run("profile", "add", name)
        if result.returncode != 0:
            raise AssertionError(f"the sandbox needs profile {name}: {result.stderr!r}")
        profile = self.listed()[name]
        subscription, tier, _ = PLANS[name]
        token = "e2e-usage-" + secrets.token_hex(24)
        oauth = {"accessToken": token, "refreshToken": "e2e-refresh-" + secrets.token_hex(24),
                 "expiresAt": int((time.time() + 86_400) * 1000), "scopes": ["user:inference", "user:profile"],
                 "subscriptionType": subscription}
        if tier:
            oauth["rateLimitTier"] = tier
        descriptor = os.open(Path(profile["configDirectory"]) / ".credentials.json", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "w") as handle:
            json.dump({"claudeAiOauth": oauth}, handle)
        self.tokens[name] = token
        self.keys[name] = credential_service(profile)
        with self.stub.lock:
            self.stub.tokens[token] = name
        self.stub.set(name)

    @property
    def cache_path(self):
        return self.registry_path.parent / "usage-cache.json"

    @property
    def lock_path(self):
        return self.registry_path.parent / ".usage-cache-lock"

    def cache(self):
        return json.loads(self.cache_path.read_text())

    def entry(self, name):
        return self.cache()["profiles"].get(self.keys[name])

    def write_cache(self, data):
        temporary = self.cache_path.with_name("usage-cache.e2e.tmp")
        temporary.write_bytes(data)
        temporary.chmod(0o600)
        os.replace(temporary, self.cache_path)

    def edit(self, name, change):
        """Changes one profile's cache entry the way time passing would, for an older reading or an ended cooldown."""
        cache = self.cache()
        change(cache["profiles"][self.keys[name]])
        self.write_cache(json.dumps(cache).encode())

    def usage(self, checks, *arguments, expect_exit=0, timeout=90):
        result = self.run("usage", *arguments, timeout=timeout)
        checks.expect(result.returncode == expect_exit, f"usage {' '.join(arguments)} must exit {expect_exit}", result)
        self.expect_no_tokens(checks, result.stdout + result.stderr, "usage output")
        return result

    def expect_no_tokens(self, checks, text, where):
        checks.expect(not any(token in text for token in self.tokens.values()), f"{where} must not contain an access token")

    def close(self):
        self.stub.close()
        return super().close()


def now():
    return datetime.now(timezone.utc)


def stamp(moment):
    """A time as the cache stores it: ISO 8601 UTC with milliseconds."""
    moment = moment.astimezone(timezone.utc)
    return moment.strftime("%Y-%m-%dT%H:%M:%S.") + f"{moment.microsecond // 1000:03d}Z"


def parse(value):
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def clock(moment):
    """HH:MM in the Mac's time zone, as the stderr note shows a cooldown's end."""
    return moment.astimezone().strftime("%H:%M")


def rows(name, session, weekly):
    plan = PLANS[name][2]
    return (f"{name}\t{plan}\t5-hour session\t{session:.2f}\t{SESSION_RESET}\n"
            f"{name}\t{plan}\tWeekly · all models\t{weekly:.2f}\t{WEEKLY_RESET}\n")


def expect_paced(checks, stub, label):
    times = stub.times()
    gaps = [later - earlier for earlier, later in zip(times, times[1:])]
    checks.expect(all(gap >= 0.5 for gap in gaps), f"{label}: requests must be at least 500 ms apart, got gaps {[round(gap, 3) for gap in gaps]}")
    checks.expect(not stub.rejected, f"{label}: every request must carry a profile's token, got {stub.rejected!r}")
    checks.done(f"{label}: {len(times)} requests, each at least 500 ms after the one before")


def caching(cli, checks, sandboxes):
    sandbox = UsageSandbox(cli, "e2e-usage-cache", NAMES)
    sandboxes.append(sandbox)
    stub = sandbox.stub
    for name, session, weekly in (("alpha", 12.5, 40.25), ("bravo", 3.0, 9.5), ("charlie", 77.75, 50.0)):
        stub.set(name, session=session, weekly=weekly)
    first = sandbox.usage(checks)
    checks.expect(first.stdout == HEADER + rows("alpha", 12.5, 40.25) + rows("bravo", 3.0, 9.5) + rows("charlie", 77.75, 50.0)
                  and first.stderr == DEFAULT_SKIP, "the first usage must print every profile's rows", first)
    checks.expect([stub.count(name) for name in NAMES] == [1, 1, 1], f"the first usage must request each profile once, got {stub.requests!r}")
    checks.expect(sandbox.cache_path.is_file(), f"the first usage must save its readings in {sandbox.cache_path.name}")
    mode = sandbox.cache_path.stat().st_mode & 0o777
    checks.expect(mode == 0o600, f"the usage cache must be private (0600), got {oct(mode)}")
    sandbox.expect_no_tokens(checks, sandbox.cache_path.read_text(), "the usage cache")
    checks.expect(sorted(sandbox.cache()["profiles"]) == sorted(sandbox.keys.values()),
                  f"the cache must key readings by credential service, got {sorted(sandbox.cache()['profiles'])!r}")
    checks.done("a first usage requests each of 3 profiles once, prints their rows, and caches them privately without tokens")

    for name in NAMES:
        stub.set(name, session=99.0, weekly=99.0)
    second = sandbox.usage(checks)
    checks.expect(stub.count() == 3, f"a second usage within the max age must make no request, got {stub.count() - 3}")
    checks.expect(second.stdout == first.stdout and second.stderr == DEFAULT_SKIP, "a second usage must print the same rows", second)
    checks.done("a second usage within the max age makes no request and prints the same rows")

    for name, session, weekly in (("alpha", 21.0, 41.0), ("bravo", 4.0, 10.0), ("charlie", 78.0, 51.0)):
        stub.set(name, session=session, weekly=weekly)
    fresh = sandbox.usage(checks, "--fresh")
    checks.expect([stub.count(name) for name in NAMES] == [2, 2, 2], f"--fresh must request every profile again, got {stub.requests!r}")
    checks.expect(fresh.stdout == HEADER + rows("alpha", 21.0, 41.0) + rows("bravo", 4.0, 10.0) + rows("charlie", 78.0, 51.0)
                  and fresh.stderr == DEFAULT_SKIP, "--fresh must print the new readings", fresh)
    checks.done("--fresh requests every profile again and prints the new readings")

    for name, session, weekly in (("alpha", 22.0, 42.0), ("bravo", 5.0, 11.0), ("charlie", 79.0, 52.0)):
        stub.set(name, session=session, weekly=weekly)
    zero = sandbox.usage(checks, "--max-age", "0")
    checks.expect([stub.count(name) for name in NAMES] == [3, 3, 3], f"--max-age 0 must request every profile again, got {stub.requests!r}")
    checks.expect(zero.stdout == HEADER + rows("alpha", 22.0, 42.0) + rows("bravo", 5.0, 11.0) + rows("charlie", 79.0, 52.0),
                  "--max-age 0 must print the new readings", zero)
    checks.done("--max-age 0 behaves like --fresh")

    sandbox.edit("alpha", lambda entry: entry["reading"].update(fetchedAt=stamp(now() - timedelta(minutes=10))))
    stub.set("alpha", session=23.0, weekly=43.0)
    hour = sandbox.usage(checks, "--max-age", "3600")
    checks.expect(stub.count() == 9 and hour.stdout == zero.stdout, "a 10-minute-old reading is younger than --max-age 3600, so nothing is requested", hour)
    default = sandbox.usage(checks)
    checks.expect(stub.count("alpha") == 4 and stub.count() == 10, f"with the default max age only the 10-minute-old reading is requested again, got {stub.requests!r}")
    checks.expect(default.stdout == HEADER + rows("alpha", 23.0, 43.0) + rows("bravo", 5.0, 11.0) + rows("charlie", 79.0, 52.0)
                  and default.stderr == DEFAULT_SKIP, "the refreshed reading replaces the old one", default)
    checks.done("--max-age 3600 reuses a 10-minute-old reading; the default max age requests only that profile again")
    expect_paced(checks, stub, "caching")


def cooldown(cli, checks, sandboxes):
    sandbox = UsageSandbox(cli, "e2e-usage-cooldown", NAMES)
    sandboxes.append(sandbox)
    stub = sandbox.stub
    for name, session, weekly in (("alpha", 10.0, 20.0), ("bravo", 30.0, 40.0), ("charlie", 50.0, 60.0)):
        stub.set(name, session=session, weekly=weekly)
    sandbox.usage(checks)
    stub.set("alpha", session=11.0, weekly=21.0)
    stub.set("bravo", status=429, retry_after="120")
    stub.set("charlie", session=51.0, weekly=61.0)
    before = now()
    limited = sandbox.usage(checks, "--fresh")
    checks.expect(stub.count("bravo") == 2, f"--fresh must request bravo, which is then rate limited, got {stub.requests!r}")
    entry = sandbox.entry("bravo")
    retry = parse(entry["retryAt"])
    checks.expect(before + timedelta(seconds=120) <= retry <= now() + timedelta(days=1) and entry.get("rateLimits") == 1,
                  f"a 429 with Retry-After: 120 must start a cooldown of at least 120 s, got {entry!r}")
    checks.expect(limited.stdout == HEADER + rows("alpha", 11.0, 21.0) + rows("bravo", 30.0, 40.0) + rows("charlie", 51.0, 61.0),
                  "the rate-limited profile must print its cached rows", limited)
    note = f"claudock: bravo: rate limited until {clock(retry)}; showing reading from 1 min ago.\n"
    checks.expect(limited.stderr == DEFAULT_SKIP + note, f"one stderr note must explain the cached rows: {note!r}", limited)
    checks.done("a 429 with Retry-After: 120 prints that profile's cached rows and one stderr note, exit 0")

    again = sandbox.usage(checks, "--fresh")
    checks.expect([stub.count(name) for name in NAMES] == [3, 2, 3], f"during the cooldown only the other profiles may be requested, got {stub.requests!r}")
    checks.expect(again.stderr == DEFAULT_SKIP + note and rows("bravo", 30.0, 40.0) in again.stdout, "the cached rows and note again", again)
    checks.done("a re-run during the cooldown, even with --fresh, makes no request for the rate-limited profile")

    sandbox.edit("bravo", lambda entry: entry.update(retryAt=stamp(now() - timedelta(seconds=1))))
    stub.set("bravo", session=31.0, weekly=41.0)
    ended = sandbox.usage(checks, "--fresh")
    checks.expect(stub.count("bravo") == 3 and ended.stderr == DEFAULT_SKIP and rows("bravo", 31.0, 41.0) in ended.stdout,
                  "after the cooldown bravo must be requested again and print its new reading", ended)
    entry = sandbox.entry("bravo")
    checks.expect("retryAt" not in entry and entry.get("rateLimits", 0) == 0, f"a success must clear the cooldown, got {entry!r}")
    checks.done("after the cooldown the profile is requested again, and the success clears the cooldown")

    sandbox.add("delta")
    stub.set("delta", status=429)
    started = now()
    failed = sandbox.usage(checks, expect_exit=1)
    finished = now()
    checks.expect(stub.count("delta") == 1 and [stub.count(name) for name in NAMES] == [4, 3, 4],
                  f"only delta, which has no reading, must be requested, got {stub.requests!r}")
    checks.expect(failed.stderr == DEFAULT_SKIP + f"claudock: delta: {RATE_LIMITED}\n", "delta must fail with today's error line", failed)
    checks.expect(failed.stdout == HEADER + rows("alpha", 11.0, 21.0) + rows("bravo", 31.0, 41.0) + rows("charlie", 51.0, 61.0),
                  "the other profiles must still print", failed)
    entry = sandbox.entry("delta")
    retry = parse(entry["retryAt"])
    checks.expect("reading" not in entry and entry.get("rateLimits") == 1
                  and started + timedelta(seconds=60) <= retry <= finished + timedelta(seconds=75),
                  f"a first 429 without Retry-After must back off 60–75 s, got {entry!r}")
    again = sandbox.usage(checks, expect_exit=1)
    checks.expect(stub.count("delta") == 1 and again.stderr == failed.stderr, "during the cooldown delta must not be requested and still fails", again)
    checks.done("a 429 with no cached reading fails that profile with today's message, exit 1, and is not requested again during the cooldown")

    sandbox.edit("delta", lambda entry: entry.update(retryAt=stamp(now() - timedelta(seconds=1))))
    started = now()
    sandbox.usage(checks, expect_exit=1)
    finished = now()
    entry = sandbox.entry("delta")
    retry = parse(entry["retryAt"])
    checks.expect(stub.count("delta") == 2 and entry.get("rateLimits") == 2
                  and started + timedelta(seconds=120) <= retry <= finished + timedelta(seconds=150),
                  f"a second 429 in a row without Retry-After must back off 120–150 s, got {entry!r}")
    checks.done("consecutive 429s without Retry-After back off exponentially: 60–75 s, then 120–150 s")

    until = now() + timedelta(minutes=30)

    def hours_old(entry):
        entry["reading"]["fetchedAt"] = stamp(now() - timedelta(hours=3))
        entry.update(retryAt=stamp(until), rateLimits=1)
    sandbox.edit("bravo", hours_old)
    old = sandbox.usage(checks, expect_exit=1)
    checks.expect(f"claudock: bravo: rate limited until {clock(parse(stamp(until)))}; showing reading from 180 min ago.\n" in old.stderr
                  and stub.count("bravo") == 3, "an hours-old reading's age must still be given in minutes", old)
    checks.done("the note gives an hours-old reading's age in minutes, as for any other")
    expect_paced(checks, stub, "cooldown")


def concurrency(cli, checks, sandboxes):
    sandbox = UsageSandbox(cli, "e2e-usage-parallel", NAMES)
    sandboxes.append(sandbox)
    stub = sandbox.stub
    for name, session, weekly in (("alpha", 1.0, 2.0), ("bravo", 3.0, 4.0), ("charlie", 5.0, 6.0)):
        stub.set(name, session=session, weekly=weekly)
    stub.delay = 0.3
    processes = [sandbox.spawn("usage") for _ in range(10)]
    results = [(process, *process.communicate(timeout=120)) for process in processes]
    expected = HEADER + rows("alpha", 1.0, 2.0) + rows("bravo", 3.0, 4.0) + rows("charlie", 5.0, 6.0)
    for process, stdout, stderr in results:
        checks.expect(process.returncode == 0 and stdout == expected and stderr == DEFAULT_SKIP,
                      f"each of 10 parallel usage runs must exit 0 with every row, got exit {process.returncode}: {stdout!r} {stderr!r}")
    checks.expect(stub.count() <= len(NAMES) and [stub.count(name) for name in NAMES] == [1, 1, 1],
                  f"10 parallel runs must request each profile once in total, got {stub.requests!r}")
    checks.done("10 usage processes started at once make one request per profile in total and all exit 0 with every row")

    # A second run starts after the first has read alpha and asks for a newer one: it waits for the first to finish,
    # then requests alpha itself, at least 500 ms after the first run's last request.
    for name in NAMES:
        sandbox.edit(name, lambda entry: entry["reading"].update(fetchedAt=stamp(now() - timedelta(minutes=10))))
    stub.delay = 0.5
    first = sandbox.spawn("usage")
    deadline = time.monotonic() + 30
    while stub.count() < 5 and time.monotonic() < deadline:
        time.sleep(0.01)
    stub.set("alpha", session=7.0, weekly=8.0)
    second = sandbox.spawn("usage", "--fresh")
    outcomes = [(process, *process.communicate(timeout=120)) for process in (first, second)]
    checks.expect(all(process.returncode == 0 for process, _, _ in outcomes), f"both overlapping runs must succeed, got {outcomes!r}")
    checks.expect(stub.count("alpha") == 3 and rows("alpha", 7.0, 8.0) in outcomes[1][1],
                  f"the run that asked for a newer reading must request alpha after the first run read it, got {stub.requests!r}")
    checks.done("a run that needs a newer reading waits for the running fetch, then requests only what is still too old")
    expect_paced(checks, stub, "concurrency")


def corrupt(cli, checks, sandboxes):
    sandbox = UsageSandbox(cli, "e2e-usage-corrupt", NAMES)
    sandboxes.append(sandbox)
    stub = sandbox.stub
    for name, session, weekly in (("alpha", 1.5, 2.5), ("bravo", 3.5, 4.5), ("charlie", 5.5, 6.5)):
        stub.set(name, session=session, weekly=weekly)
    expected = HEADER + rows("alpha", 1.5, 2.5) + rows("bravo", 3.5, 4.5) + rows("charlie", 5.5, 6.5)
    sandbox.usage(checks)
    checks.expect(sandbox.cache_path.is_file(), f"usage must save its readings in {sandbox.cache_path.name}")
    # Each variant spoils a cache whose readings are seconds old, so a variant that was wrongly used would request less.
    valid = sandbox.cache()
    text = json.dumps(valid).encode()
    variants = [("binary garbage", b"\x00\xff\xfe not json"), ("truncated JSON", text[:-10]),
                ("an unknown version", json.dumps({**valid, "version": 99}).encode()), ("the wrong shape", json.dumps([valid]).encode()),
                ("an oversized file", text[:-1] + b" " * (2 * 1_048_576) + b"}")]
    for label, content in variants:
        sandbox.write_cache(content)
        before = stub.count()
        result = sandbox.usage(checks)
        checks.expect(result.stdout == expected and result.stderr == DEFAULT_SKIP, f"usage must ignore a cache file with {label}", result)
        checks.expect(stub.count() - before == 3, f"with {label} no cached reading is usable, so each profile must be requested")
        cache = sandbox.cache()
        mode = sandbox.cache_path.stat().st_mode & 0o777
        checks.expect(cache.get("version") == 1 and sorted(cache["profiles"]) == sorted(sandbox.keys.values()) and mode == 0o600,
                      f"a cache file with {label} must be replaced by a valid private one, got mode {oct(mode)} and {sorted(cache)!r}")
    checks.done("a garbage, truncated, unknown-version, wrong-shape, or oversized cache is ignored and rebuilt")

    broken = sandbox.cache()
    broken["profiles"][sandbox.keys["alpha"]]["reading"]["windows"][0]["percent"] = -1.0
    sandbox.write_cache(json.dumps(broken).encode())
    count = stub.count("alpha")
    result = sandbox.usage(checks)
    checks.expect(result.stdout == expected and stub.count("alpha") == count + 1, "a cached reading with an impossible value must not be used", result)
    checks.done("a cached reading with an impossible value is ignored and requested again")

    # A symbolic link is never followed: its target is neither read nor written.
    planted = sandbox.cache()
    planted["profiles"][sandbox.keys["alpha"]]["reading"]["windows"][0]["percent"] = 99.0
    target = sandbox.base / "planted-usage-cache.json"
    target.write_text(json.dumps(planted))
    before = target.read_bytes()
    sandbox.cache_path.unlink()
    sandbox.cache_path.symlink_to(target)
    count = stub.count()
    result = sandbox.run("usage", "--max-age", "86400")
    checks.expect(result.returncode == 0 and result.stdout == expected and stub.count() - count == 3,
                  "a symbolic link in place of the cache must be ignored", result)
    checks.expect(not sandbox.cache_path.is_symlink() and sandbox.cache_path.is_file() and target.read_bytes() == before,
                  "the link must be replaced by a regular cache file, leaving its target untouched")
    checks.done("a symbolic link in place of the cache is neither read nor written through")

    # Something that cannot be replaced at all is never fatal.
    sandbox.cache_path.unlink()
    sandbox.cache_path.mkdir()
    for attempt in (1, 2):
        count = stub.count()
        result = sandbox.usage(checks)
        checks.expect(result.stdout == expected and result.stderr == DEFAULT_SKIP and stub.count() - count == 3,
                      f"usage must still work when the cache cannot be written (run {attempt})", result)
    sandbox.cache_path.rmdir()
    checks.done("a cache that cannot be written still leaves usage working")
    expect_paced(checks, stub, "corrupt cache")


def busy(cli, checks, sandboxes):
    sandbox = UsageSandbox(cli, "e2e-usage-busy", NAMES)
    sandboxes.append(sandbox)
    stub = sandbox.stub
    for name, session, weekly in (("alpha", 2.0, 3.0), ("bravo", 4.0, 5.0), ("charlie", 6.0, 7.0)):
        stub.set(name, session=session, weekly=weekly)
    populated = sandbox.usage(checks)
    # Another Claudock process (the app, or a long usage run) holds the fetch lock.
    descriptor = os.open(sandbox.lock_path, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        for name in NAMES:
            stub.set(name, session=50.0, weekly=50.0)
        started = time.monotonic()
        held = sandbox.usage(checks, "--fresh", timeout=120)
        waited = time.monotonic() - started
        checks.expect(stub.count() == 3, f"while another process holds the fetch lock nothing may be requested, got {stub.requests!r}")
        notes = "".join(f"claudock: {name}: another Claudock process is reading usage; showing reading from 1 min ago.\n" for name in NAMES)
        checks.expect(held.stdout == populated.stdout and held.stderr == DEFAULT_SKIP + notes, "cached rows with one note each", held)
        checks.expect(25 <= waited <= 45, f"usage must wait about 30 s for the lock, waited {waited:.1f} s")
        checks.done("a held fetch lock: usage waits about 30 s, then prints the cached rows with a note each, requests nothing, exit 0")

        for name in NAMES:
            sandbox.edit(name, lambda entry: entry["reading"].update(fetchedAt=stamp(now() - timedelta(minutes=10))))
        started = time.monotonic()
        waiting = sandbox.spawn("usage")
        time.sleep(2)

        def landed(entry):
            # What the lock holder saves when its request returns.
            entry["reading"]["fetchedAt"] = stamp(now())
            entry["reading"]["windows"][0]["percent"] = 66.0
        for name in NAMES:
            sandbox.edit(name, landed)
        stdout, stderr = waiting.communicate(timeout=60)
        waited = time.monotonic() - started
        checks.expect(waiting.returncode == 0 and stderr == DEFAULT_SKIP and stub.count() == 3 and waited < 15
                      and stdout.count("\t5-hour session\t66.00\t") == 3,
                      f"readings saved by the lock holder must be used as they land, got exit {waiting.returncode} after {waited:.1f} s: {stdout!r} {stderr!r}")
        checks.done("readings another process saves while usage waits for the lock are printed as they land, without waiting out the lock")

        sandbox.add("delta")
        missing = sandbox.usage(checks, expect_exit=1, timeout=120)
        checks.expect(missing.stderr == DEFAULT_SKIP + "claudock: delta: Another Claudock process is reading usage. Try again in a moment.\n"
                      and stub.count() == 3, "a profile with no reading must fail while the lock stays held", missing)
        checks.done("a held fetch lock and no cached reading: that profile fails, exit 1")
    finally:
        fcntl.flock(descriptor, fcntl.LOCK_UN)
        os.close(descriptor)


def arguments(cli, checks, sandboxes):
    sandbox = UsageSandbox(cli, "e2e-usage-arguments", ["alpha"])
    sandboxes.append(sandbox)
    for extra in (["--max-age"], ["--max-age", "-1"], ["--max-age", "86401"], ["--max-age", "1.5"], ["--max-age", "abc"],
                  ["--max-age", ""], ["--max-age", "+5"], ["--max-age", " 5"], ["--fresh", "--max-age", "5"],
                  ["--max-age", "5", "--fresh"], ["--fresh", "extra"], ["--fresh", "--fresh"], ["--max-age", "5", "--max-age", "6"],
                  ["--stale"]):
        result = sandbox.run("usage", *extra)
        checks.expect(result.returncode == 2 and not result.stdout and "claudock help" in result.stderr,
                      f"usage {extra!r} must be an argument error", result)
    checks.expect(sandbox.stub.count() == 0 and not sandbox.cache_path.exists(), "argument errors must request nothing and write no cache")
    checks.done("malformed --max-age and --fresh arguments exit 2 before any request")
    for extra in (["--max-age", "0"], ["--max-age", "86400"], ["--fresh"], ["--max-age", "007"]):
        result = sandbox.usage(checks, *extra)
        checks.expect(result.stdout == HEADER + rows("alpha", 0.0, 0.0), f"usage {extra!r} must print the rows", result)
    checks.done("--max-age 0 to 86400 and --fresh are accepted")
    result = sandbox.run("help")
    for text in ("usage [--max-age SECONDS | --fresh]", "180", "cooldown"):
        checks.expect(text in result.stdout, f"help must document {text!r}", result)
    checks.done("help documents the usage cache, --max-age, --fresh, and cooldowns")


def main():
    clean_up_on_termination()
    preflight()
    cli = build_test_cli()
    checks = Checks()
    sandboxes, failures = [], []
    try:
        for scenario in (arguments, caching, cooldown, concurrency, corrupt, busy):
            try:
                scenario(cli, checks, sandboxes)
            except Exception as error:  # Each scenario has its own home and stub; report every one that fails.
                failures.append(f"{scenario.__name__}: {type(error).__name__}: {error}")
    finally:
        # The test build would send a real home's tokens to any loopback URL it is given; keep only its build cache.
        cli.unlink(missing_ok=True)
    leftovers = []
    for sandbox in sandboxes:
        leftovers += sandbox.close()[1]
    receipt = {"passed": len(checks.passed), "checks": checks.passed, "failures": failures, "keychain_items_not_deleted": leftovers,
               "scope": "Test build of the real claudock binary (only its usage endpoint differs) under a loopback-only sandbox, "
                        "temporary homes with synthetic credential files, and a stub usage endpoint."}
    print(json.dumps(receipt, indent=2, ensure_ascii=False))
    for failure in failures:
        print("FAILED: " + failure, file=sys.stderr)
    if failures or leftovers:
        sys.exit(1)


if __name__ == "__main__":
    main()

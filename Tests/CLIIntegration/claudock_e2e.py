"""Shared harness for end-to-end checks that drive the real `claudock` binary.

Each Sandbox is a throwaway home. CFFIXED_USER_HOME points Foundation's
NSHomeDirectory() at it, so the registry, account folders, zsh files, and
~/.local/bin/claude all live there. HOME stays the real home on purpose:
/usr/bin/security finds the login Keychain through HOME, while Foundation ignores
HOME (a HOME-only override would reach the real registry). Keychain items get
per-run service names derived from the temporary config paths; Sandbox.close()
deletes every tracked item, also after a failure.

The default `claude` profile uses Claude Code's global "Claude Code-credentials"
Keychain service, whatever its config folder. Each sandbox therefore declares a
CLAUDE_CONFIG_DIR override in its .zshrc, which leaves the default profile
unresolved, so no command can read the real default login or its inference token.

A fake `claude` records its argv, working directory, and environment, and proves
which executable ran. Commands get a minimal environment, so no real secret from
the caller's shell reaches the fake's record.
"""

import hashlib
import json
import os
from pathlib import Path
import pwd
import re
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import termios
import time
import unicodedata


PROJECT = Path(__file__).resolve().parents[2]
PREFERENCES_DOMAIN = "io.github.claudeusage.ClaudeUsage"
SECURITY = "/usr/bin/security"
USER = pwd.getpwuid(os.getuid())
ACCOUNT = USER.pw_name
REAL_HOME = USER.pw_dir


def toolchain_environment():
    environment = dict(os.environ)
    if "DEVELOPER_DIR" not in environment and Path("/Applications/Xcode.app/Contents/Developer").is_dir():
        environment["DEVELOPER_DIR"] = "/Applications/Xcode.app/Contents/Developer"
    return environment


def build_cli():
    environment = toolchain_environment()
    subprocess.run(["xcrun", "swift", "build", "--product", "claudock"], cwd=PROJECT, env=environment, check=True,
                   stdout=subprocess.DEVNULL)
    directory = subprocess.run(["xcrun", "swift", "build", "--show-bin-path"], cwd=PROJECT, env=environment,
                               check=True, capture_output=True, text=True).stdout.strip()
    return Path(directory) / "claudock"


def clean_up_on_termination():
    """tmux kill-session and time-budget kills send SIGHUP or SIGTERM; turn them into an exit so
    teardown (Keychain items, the real preference, temporary homes) still runs."""
    for number in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(number, lambda *_: sys.exit(1))


def preflight():
    if sys.platform != "darwin":
        raise SystemExit("These checks need macOS and its login Keychain.")
    # ClaudeExecutable.find prefers this preference over ~/.local/bin/claude, and
    # CFFIXED_USER_HOME does not redirect preferences. Never risk launching the real Claude.
    configured = subprocess.run(["defaults", "read", PREFERENCES_DOMAIN, "claudeExecutable"], capture_output=True, text=True)
    if configured.returncode == 0 and configured.stdout.strip():
        raise SystemExit("Claudock has a custom Claude executable preference; the fake claude would not run. "
                         "Clear it in Claudock Settings before running these checks.")
    if subprocess.run([SECURITY, "default-keychain"], env={**os.environ, "HOME": REAL_HOME},
                      capture_output=True).returncode != 0:
        raise SystemExit("No default login Keychain is available.")
    # Preferences ignore the temporary home, so a required inference token would refuse the
    # checks' token-less launches. It is also left on if a token check was killed mid-run.
    if read_policy_preference():
        raise SystemExit("Claudock requires inference tokens to launch (requireInferenceToken is on). Turn it off with "
                         "'claudock require-token off' or 'defaults delete io.github.claudeusage.ClaudeUsage requireInferenceToken' "
                         "before running these checks.")


def credential_service(profile):
    if profile["command"] == "claude":
        return "Claude Code-credentials"
    path = unicodedata.normalize("NFC", profile["configDirectory"])
    return "Claude Code-credentials-" + hashlib.sha256(path.encode()).hexdigest()[:8]


def api_key_service(profile):
    return "Claudock-apikey-" + hashlib.sha256(credential_service(profile).encode()).hexdigest()


def endpoint_key_service(profile):
    """Where Claudock keeps a third-party endpoint profile's key."""
    return "Claudock-endpointkey-" + hashlib.sha256(credential_service(profile).encode()).hexdigest()


def managed_key_service(profile):
    """Where Claude Code 2.1.295 keeps the API key that `auth login --console` creates: "Claude Code" plus the
    config folder's hash, as for its credentials. The default profile's unhashed item is real; never use it."""
    if profile["command"] == "claude":
        raise ValueError("the checks never use the default profile's Console sign-in item")
    path = unicodedata.normalize("NFC", profile["configDirectory"])
    return "Claude Code-" + hashlib.sha256(path.encode()).hexdigest()[:8]


def inference_service(profile):
    return "Claudock-inference-" + hashlib.sha256(credential_service(profile).encode()).hexdigest()


POLICY_KEY = "requireInferenceToken"


def read_policy_preference():
    """The real requireInferenceToken preference: True, False, or None when it is not set."""
    result = subprocess.run(["defaults", "read", PREFERENCES_DOMAIN, POLICY_KEY], capture_output=True, text=True)
    if result.returncode != 0:
        return None
    return result.stdout.strip().lower() in ("1", "yes", "true")


def restore_policy_preference(cli, original):
    """Puts the real preference back, through the CLI where it can express the value. Returns True on success."""
    environment = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": REAL_HOME, "USER": ACCOUNT, "LOGNAME": ACCOUNT}
    if original is True:
        subprocess.run([str(cli), "require-token", "on"], env=environment, capture_output=True)
    elif original is None:
        subprocess.run([str(cli), "require-token", "off"], env=environment, capture_output=True)
        if read_policy_preference() is not None:
            subprocess.run(["defaults", "delete", PREFERENCES_DOMAIN, POLICY_KEY], capture_output=True)
    else:
        # The CLI turns the policy off by removing the key; an explicit false predates it.
        subprocess.run(["defaults", "write", PREFERENCES_DOMAIN, POLICY_KEY, "-bool", "false"], capture_output=True)
    return read_policy_preference() == original


def keychain_item_exists(service):
    # Without -w, security prints attributes only, never the secret.
    result = subprocess.run([SECURITY, "find-generic-password", "-a", ACCOUNT, "-s", service],
                            env={**os.environ, "HOME": REAL_HOME}, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if result.returncode not in (0, 44):
        raise RuntimeError(f"Keychain lookup failed with status {result.returncode}")
    return result.returncode == 0


# The real default profile's Keychain items: Claude Code's login and Console key, and Claudock's token and keys, which
# take their names from the login's. No check may create, overwrite, track for deletion, or delete them.
DEFAULT_PROFILE_SERVICES = ("Claude Code", "Claude Code-credentials",
                            "Claudock-inference-" + hashlib.sha256(b"Claude Code-credentials").hexdigest(),
                            "Claudock-apikey-" + hashlib.sha256(b"Claude Code-credentials").hexdigest(),
                            "Claudock-endpointkey-" + hashlib.sha256(b"Claude Code-credentials").hexdigest())


def refuse_default_profile_item(service):
    if service in DEFAULT_PROFILE_SERVICES:
        raise ValueError(f"refusing to touch the default profile's Keychain item {service!r}")


def create_keychain_item(service):
    """Saves a generic-password item with a random synthetic value, the way Claude Code does: `security -i` with the
    value hex-encoded on stdin. The default profile's real items are refused."""
    refuse_default_profile_item(service)
    value = os.urandom(24).hex().encode().hex()
    result = subprocess.run([SECURITY, "-i"], input=f'add-generic-password -U -a "{ACCOUNT}" -s "{service}" -X "{value}"\n'.encode(),
                            env={**os.environ, "HOME": REAL_HOME}, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=20)
    if result.returncode != 0:
        raise RuntimeError(f"Could not create the synthetic Keychain item (status {result.returncode})")


def delete_command(service):
    """The command `claudock profile remove` prints, and the README tells the reader to run, for a Keychain item."""
    return f"security delete-generic-password -s '{service}'"


def printed_delete_services(output):
    """The services whose delete commands `output` shows, in order."""
    return re.findall(r"security delete-generic-password -s '([^'\n]*)'", output)


def delete_keychain_item(service):
    """Returns True once no item with this service remains."""
    refuse_default_profile_item(service)
    for _ in range(3):
        result = subprocess.run([SECURITY, "delete-generic-password", "-a", ACCOUNT, "-s", service],
                                env={**os.environ, "HOME": REAL_HOME}, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if result.returncode == 44:
            return True
        if result.returncode != 0:
            return False
    return not keychain_item_exists(service)


# Parallel launches name their own record with CLAUDOCK_E2E_RUN_ID, which claudock passes through.
FAKE_CLAUDE = '''import json, os, sys
run_id = os.environ.get("CLAUDOCK_E2E_RUN_ID")
path = os.path.join(__RECORD_DIR__, run_id + ".json") if run_id else __RECORD_FILE__
with open(path, "w") as record:
    json.dump({"argv": sys.argv[1:], "cwd": os.getcwd(), "env": dict(os.environ), "executable": os.path.realpath(__file__)}, record)
sys.exit(int(os.environ.get("CLAUDOCK_E2E_EXIT", "0")))
'''


class Sandbox:
    def __init__(self, cli, label):
        # Discovery skips startup files under secret-looking folder names (key, secret,
        # credentials), which would leave the default profile resolved.
        if any(word in label for word in ("key", "secret", "credential")):
            raise ValueError("choose a sandbox label without key, secret, or credential")
        self.cli = cli
        self.base = Path(tempfile.mkdtemp(prefix=f"claudock-{label}-")).resolve()
        self.home = self.base / "home"
        self.home.mkdir()
        (self.home / ".zshrc").write_text('export CLAUDE_CONFIG_DIR="$HOME/.claude-e2e-default"\n')
        self.fake = self.home / ".local" / "bin" / "claude"
        self.fake.parent.mkdir(parents=True)
        self.record_path = self.base / "claude-record.json"
        self.records = self.base / "records"
        self.records.mkdir()
        self.fake.write_text("#!" + sys.executable + "\n" + FAKE_CLAUDE.replace("__RECORD_FILE__", repr(str(self.record_path)))
                             .replace("__RECORD_DIR__", repr(str(self.records))))
        self.fake.chmod(0o700)
        self.services = set()
        default = self.listed().get("default", {})
        if default.get("kind") != "needs-import" or default.get("configDirectory"):
            shutil.rmtree(self.base, ignore_errors=True)
            raise RuntimeError(f"the sandbox default profile must be unresolved, got {default!r}")

    def environment(self, extra=None):
        environment = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": REAL_HOME, "USER": ACCOUNT, "LOGNAME": ACCOUNT,
                       "LANG": "en_US.UTF-8", "TMPDIR": os.environ.get("TMPDIR", "/tmp"), "CFFIXED_USER_HOME": str(self.home)}
        environment.update(extra or {})
        return environment

    def run(self, *arguments, stdin="", extra=None, timeout=60, cwd=None):
        self.record_path.unlink(missing_ok=True)
        return subprocess.run([str(self.cli), *arguments], cwd=cwd or self.base, env=self.environment(extra), input=stdin,
                              capture_output=True, text=True, timeout=timeout)

    def spawn(self, *arguments, extra=None):
        """Starts the CLI without waiting, for parallel launches."""
        return subprocess.Popen([str(self.cli), *arguments], cwd=self.base, env=self.environment(extra), stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

    def record(self, run_id=None):
        path = self.records / (run_id + ".json") if run_id else self.record_path
        if not path.exists():
            return None
        value = json.loads(path.read_text())
        if Path(value["executable"]) != self.fake.resolve():
            raise AssertionError(f"an unexpected claude executable ran: {value['executable']}")
        return value

    @property
    def registry_path(self):
        return self.home / "Library" / "Application Support" / "Claudock" / "profiles.json"

    def registry_bytes(self):
        return self.registry_path.read_bytes() if self.registry_path.exists() else None

    def accounts(self):
        directory = self.registry_path.parent / "accounts"
        return sorted(entry.name for entry in directory.iterdir()) if directory.exists() else []

    def listed(self):
        """Profiles as `claudock profile list` reports them, keyed by display name."""
        result = self.run("profile", "list")
        if result.returncode != 0:
            raise AssertionError(f"profile list failed: {result.stderr!r}")
        rows = [line.split("\t") for line in result.stdout.splitlines()[1:]]
        return {row[0]: {"command": row[1], "kind": row[2], "configDirectory": row[3], "endpoint": row[4] if len(row) > 4 else None}
                for row in rows}

    def registry_id(self, name):
        """The stable identity the app passes to `claudock launch-bound`."""
        profiles = json.loads(self.registry_path.read_text())["profiles"]
        return next(profile["registryID"] for profile in profiles if profile["command"] == "claude-" + name)

    def track(self, service):
        # Teardown deletes what is tracked, so it must never be the real default profile's items.
        refuse_default_profile_item(service)
        self.services.add(service)

    def create_keychain_item(self, service):
        """Tracks the item for teardown, then creates it with a synthetic value."""
        self.track(service)
        create_keychain_item(service)

    def close(self):
        """Deletes tracked Keychain items and the sandbox. Returns the services that existed and were
        deleted, and those that could not be deleted."""
        deleted, remaining = [], []
        for service in sorted(self.services):
            existed = keychain_item_exists(service)
            if not delete_keychain_item(service):
                remaining.append(service)
            elif existed:
                deleted.append(service)
        shutil.rmtree(self.base, ignore_errors=True)
        return deleted, remaining


class TerminalRun:
    """Runs the CLI with a pseudo-terminal as stdin and stderr, like an interactive shell."""

    def __init__(self, sandbox, *arguments):
        self.master, self.slave = os.openpty()
        # Its own process group in this session, so a default SIGTSTP really stops it.
        self.process = subprocess.Popen([str(sandbox.cli), *arguments], cwd=sandbox.base, env=sandbox.environment(),
                                        stdin=self.slave, stdout=subprocess.PIPE, stderr=self.slave, preexec_fn=os.setpgrp)
        self.output = b""

    def read_until(self, needle, count=1, timeout=15):
        deadline = time.monotonic() + timeout
        while self.output.count(needle) < count:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return False
            ready, _, _ = select.select([self.master], [], [], remaining)
            if ready:
                try:
                    self.output += os.read(self.master, 4096)
                except OSError:
                    return self.output.count(needle) >= count
        return True

    def echo_enabled(self):
        return bool(termios.tcgetattr(self.slave)[3] & termios.ECHO)

    def wait_for_echo(self, enabled, timeout=10):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.echo_enabled() == enabled:
                return True
            time.sleep(0.05)
        return self.echo_enabled() == enabled

    def send(self, data):
        os.write(self.master, data)

    def drain(self, timeout):
        """Reads terminal output like a real terminal would, so the CLI never waits on it."""
        while select.select([self.master], [], [], timeout)[0]:
            try:
                chunk = os.read(self.master, 4096)
            except OSError:
                return
            if not chunk:
                return
            self.output += chunk
            timeout = 0

    def finish(self, timeout=30):
        deadline = time.monotonic() + timeout
        while self.process.poll() is None and time.monotonic() < deadline:
            self.drain(0.1)
        if self.process.poll() is None:
            self.process.kill()
        stdout, _ = self.process.communicate()
        self.drain(0.2)
        return self.process.returncode, stdout.decode(errors="replace")

    def unread_input(self):
        """True if typed-ahead input is still queued for whatever reads the terminal next, such as the shell."""
        return bool(select.select([self.slave], [], [], 0.3)[0])

    def close(self):
        if self.process.poll() is None:
            self.process.kill()
            self.process.wait()
        for descriptor in (self.master, self.slave):
            try:
                os.close(descriptor)
            except OSError:
                pass


class Checks:
    def __init__(self):
        self.passed = []

    def expect(self, condition, message, result=None):
        if not condition:
            detail = ""
            if result is not None:
                detail = f"\n  exit {result.returncode}\n  stdout {result.stdout!r}\n  stderr {result.stderr!r}"
            raise AssertionError(message + detail)

    def done(self, name):
        self.passed.append(name)


# The Keychain items `claudock profile remove` can list for a profile, in the order it lists them.
LEFTOVER_ITEMS = (("login", credential_service), ("console key", managed_key_service),
                  ("inference token", inference_service), ("API key", api_key_service), ("endpoint key", endpoint_key_service))


def shell_quoted_folder(path):
    """How `profile remove` shows a config folder: in single quotes, so the line can go into a shell as it is."""
    return "'" + path.replace("'", "'\\''") + "'"


def check_removal(sandbox, checks, name, present):
    """Removes the profile `name` and checks what `profile remove` printed. `present` names the Keychain items that
    exist for the profile, among "login", "console key", "inference token", "API key", and "endpoint key". The output must hold
    exactly their delete commands, in that order, and mention no other service. The profile's config folder, quoted
    for the shell, and the reminder that keys stay valid at Anthropic until revoked come after them. The profile
    goes; every item stays. Returns the result."""
    unknown = set(present) - {kind for kind, _ in LEFTOVER_ITEMS}
    if unknown:
        raise ValueError(f"unknown Keychain items {sorted(unknown)!r}")
    profile = sandbox.listed()[name]
    services = {kind: service(profile) for kind, service in LEFTOVER_ITEMS}
    expected = [services[kind] for kind, _ in LEFTOVER_ITEMS if kind in present]
    result = sandbox.run("profile", "remove", name)
    checks.expect(result.returncode == 0 and result.stderr == "", f"profile remove {name} must succeed without warnings", result)
    lines = result.stdout.splitlines()
    commands = [line.strip() for line in lines]
    checks.expect(lines and lines[0].startswith(f"Removed {name} from Claudock."), "remove must keep its success line first", result)
    checks.expect(printed_delete_services(result.stdout) == expected,
                  f"remove must print delete commands for exactly {expected!r}, in order", result)
    for kind, service in services.items():
        if kind in present:
            checks.expect(delete_command(service) in commands, f"remove must print the exact delete command for the {kind} item on a line of its own", result)
        else:
            checks.expect(service not in result.stdout, f"remove must not mention the {kind} item, which does not exist", result)
    last_command = max((number for number, line in enumerate(lines) if "security delete-generic-password" in line), default=0)
    checks.expect(len(lines) >= 3 and last_command < len(lines) - 2 and lines[-2] == "Config folder: " + shell_quoted_folder(profile["configDirectory"]),
                  "remove must print the config folder, quoted for the shell, after the delete commands", result)
    checks.expect("revoked" in lines[-1] and "Console" in lines[-1] and "claude.ai" in lines[-1],
                  "remove must end by saying that keys stay valid until revoked in the Console or on claude.ai", result)
    checks.expect(name not in sandbox.listed(), f"{name} must be removed from the registry")
    for kind in present:
        checks.expect(keychain_item_exists(services[kind]), f"removal must keep the {kind} item")
    return result
